from __future__ import annotations

import asyncio
import logging
import os
import signal
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from enum import StrEnum

import httpx

from .config import Config

logger = logging.getLogger(__name__)


class State(StrEnum):
    IDLE = "idle"
    STARTING = "starting"
    READY = "ready"
    PAUSED = "paused"
    STOPPING = "stopping"


@dataclass(frozen=True)
class SupervisorStats:
    state: State
    pid: int | None
    last_activity: float | None
    in_flight: int
    starts: int
    stops: int


class Supervisor:
    """Manages the lifecycle of a single upstream process.

    - ``ensure_ready`` starts the process if not running (single-flight under a lock).
    - ``request_slot`` is an async context manager that increments an in-flight
      counter and stamps activity; the idle loop defers shutdown while in_flight > 0.
    - ``stop`` SIGTERMs the process, with a grace period before SIGKILL.
    """

    def __init__(self, config: Config) -> None:
        self._config = config
        self._state: State = State.IDLE
        self._process: asyncio.subprocess.Process | None = None
        self._lifecycle_lock = asyncio.Lock()
        self._in_flight = 0
        self._last_activity = time.monotonic()
        self._idle_task: asyncio.Task[None] | None = None
        self._starts = 0
        self._stops = 0

    def stats(self) -> SupervisorStats:
        return SupervisorStats(
            state=self._state,
            pid=self._process.pid if self._process is not None else None,
            last_activity=self._last_activity,
            in_flight=self._in_flight,
            starts=self._starts,
            stops=self._stops,
        )

    async def ensure_ready(self) -> None:
        """Block until upstream is ready. Single-flight: concurrent callers await the same boot.

        Fast path: if paused, SIGCONT resumes the process. Slow path: cold start.
        """
        async with self._lifecycle_lock:
            if self._state == State.PAUSED and self._resume_paused():
                return
            if self._is_healthy():
                return
            await self._clear_dead_process()
            await self._start_locked()

    def _resume_paused(self) -> bool:
        proc = self._process
        if proc is None or proc.returncode is not None:
            return False
        try:
            proc.send_signal(signal.SIGCONT)
        except ProcessLookupError:
            return False
        self._state = State.READY
        self._last_activity = time.monotonic()
        logger.info("Resumed upstream from pause (pid=%s)", proc.pid)
        return True

    def _is_healthy(self) -> bool:
        return (
            self._state == State.READY
            and self._process is not None
            and self._process.returncode is None
        )

    async def _clear_dead_process(self) -> None:
        if self._process is None:
            return
        if self._process.returncode is not None:
            logger.info("Detected exited upstream (rc=%s); clearing", self._process.returncode)
            self._process = None
            self._state = State.IDLE

    async def _start_locked(self) -> None:
        cmd = self._config.upstream_cmd
        if not cmd:
            raise RuntimeError("upstream_cmd is empty; cannot start upstream")
        self._state = State.STARTING
        env = {**os.environ, **self._config.upstream_env}
        logger.info("Starting upstream: %s", " ".join(cmd))
        self._process = await asyncio.create_subprocess_exec(
            *cmd,
            env=env,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        self._starts += 1
        try:
            await self._wait_for_healthy()
        except BaseException:
            await self._kill_process()
            self._state = State.IDLE
            raise
        self._last_activity = time.monotonic()
        self._state = State.READY
        logger.info("Upstream ready (pid=%s)", self._process.pid)

    async def _wait_for_healthy(self) -> None:
        url = (
            f"http://{self._config.upstream_host}:{self._config.upstream_port}"
            f"{self._config.health_probe_path}"
        )
        loop = asyncio.get_event_loop()
        deadline = loop.time() + self._config.startup_timeout_seconds
        async with httpx.AsyncClient(timeout=2.0) as client:
            while loop.time() < deadline:
                if self._process is None or self._process.returncode is not None:
                    rc = self._process.returncode if self._process else None
                    raise RuntimeError(f"Upstream exited during startup (rc={rc})")
                try:
                    resp = await client.get(url)
                    if resp.status_code < 500:
                        return
                except httpx.TransportError:
                    pass
                await asyncio.sleep(0.25)
        raise TimeoutError(
            f"Upstream did not become healthy in {self._config.startup_timeout_seconds}s"
        )

    @asynccontextmanager
    async def request_slot(self) -> AsyncIterator[None]:
        """Mark a request as in-flight; defers idle shutdown until exit."""
        self._in_flight += 1
        self._last_activity = time.monotonic()
        try:
            yield
        finally:
            self._in_flight -= 1
            self._last_activity = time.monotonic()

    async def start_idle_watcher(self) -> None:
        if self._idle_task is not None and not self._idle_task.done():
            return
        self._idle_task = asyncio.create_task(self._idle_loop(), name="siesta-idle-loop")

    async def _idle_loop(self) -> None:
        interval = self._config.idle_check_interval_seconds
        pause_after = self._config.pause_after_seconds
        idle_timeout = self._config.idle_timeout_seconds
        pause_enabled = pause_after is not None and pause_after < idle_timeout
        try:
            while True:
                await asyncio.sleep(interval)
                if self._in_flight > 0:
                    continue
                idle_for = time.monotonic() - self._last_activity
                state = self._state
                if state == State.READY:
                    if idle_for >= idle_timeout:
                        logger.info("Idle for %.1fs; unloading upstream", idle_for)
                        try:
                            await self.stop()
                        except Exception:
                            logger.exception("Error while unloading idle upstream")
                    elif pause_enabled and pause_after is not None and idle_for >= pause_after:
                        try:
                            await self._pause_process(idle_for)
                        except Exception:
                            logger.exception("Error while pausing upstream")
                elif state == State.PAUSED:
                    if idle_for >= idle_timeout:
                        logger.info("Paused %.1fs; unloading upstream", idle_for)
                        try:
                            await self.stop()
                        except Exception:
                            logger.exception("Error while unloading paused upstream")
        except asyncio.CancelledError:
            raise

    async def _pause_process(self, idle_for: float) -> None:
        async with self._lifecycle_lock:
            if self._state != State.READY:
                return
            proc = self._process
            if proc is None or proc.returncode is not None:
                return
            try:
                proc.send_signal(signal.SIGSTOP)
            except ProcessLookupError:
                return
            self._state = State.PAUSED
            logger.info("Paused upstream (pid=%s) after %.1fs idle", proc.pid, idle_for)

    async def shutdown(self) -> None:
        """Stop the idle watcher and the upstream process."""
        if self._idle_task is not None:
            self._idle_task.cancel()
            try:
                await self._idle_task
            except (asyncio.CancelledError, Exception):
                pass
            self._idle_task = None
        await self.stop()

    async def stop(self) -> None:
        async with self._lifecycle_lock:
            if self._state in (State.IDLE, State.STOPPING):
                return
            was_paused = self._state == State.PAUSED
            self._state = State.STOPPING
            await self._kill_process(was_paused=was_paused)
            self._state = State.IDLE
            self._stops += 1

    async def _kill_process(self, *, was_paused: bool = False) -> None:
        proc = self._process
        if proc is None:
            return
        if proc.returncode is not None:
            self._process = None
            return
        try:
            # Resume first if paused, otherwise SIGTERM is queued but never handled.
            if was_paused:
                try:
                    proc.send_signal(signal.SIGCONT)
                except ProcessLookupError:
                    self._process = None
                    return
            proc.send_signal(signal.SIGTERM)
            try:
                await asyncio.wait_for(proc.wait(), timeout=self._config.shutdown_grace_seconds)
            except TimeoutError:
                logger.warning("SIGTERM grace expired; sending SIGKILL to pid=%s", proc.pid)
                proc.kill()
                await proc.wait()
        finally:
            self._process = None
