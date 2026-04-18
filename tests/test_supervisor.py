from __future__ import annotations

import asyncio
import os
import signal
import time
from collections.abc import Callable

import pytest

from vllm_mlx_siesta.config import Config
from vllm_mlx_siesta.supervisor import State, Supervisor


async def _wait_for_state(sup: Supervisor, target: State, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if sup.stats().state == target:
            return
        await asyncio.sleep(0.05)
    raise AssertionError(
        f"Supervisor did not reach state {target} in {timeout}s (got {sup.stats().state})"
    )


@pytest.mark.asyncio
async def test_start_then_stop(config_factory: Callable[..., Config]) -> None:
    sup = Supervisor(config_factory())
    try:
        assert sup.stats().state == State.IDLE
        await sup.ensure_ready()
        stats = sup.stats()
        assert stats.state == State.READY
        assert stats.pid is not None
        assert stats.starts == 1
        await sup.stop()
        stats_after = sup.stats()
        assert stats_after.state == State.IDLE
        assert stats_after.stops == 1
    finally:
        await sup.shutdown()


@pytest.mark.asyncio
async def test_idle_unload_after_timeout(config_factory: Callable[..., Config]) -> None:
    sup = Supervisor(config_factory(idle_timeout_seconds=0.3, idle_check_interval_seconds=0.05))
    try:
        await sup.start_idle_watcher()
        await sup.ensure_ready()
        assert sup.stats().state == State.READY
        await _wait_for_state(sup, State.IDLE, timeout=3.0)
    finally:
        await sup.shutdown()


@pytest.mark.asyncio
async def test_in_flight_defers_shutdown(config_factory: Callable[..., Config]) -> None:
    sup = Supervisor(config_factory(idle_timeout_seconds=0.2, idle_check_interval_seconds=0.05))
    try:
        await sup.start_idle_watcher()
        await sup.ensure_ready()
        async with sup.request_slot():
            await asyncio.sleep(0.6)
            assert sup.stats().state == State.READY
        await _wait_for_state(sup, State.IDLE, timeout=3.0)
    finally:
        await sup.shutdown()


@pytest.mark.asyncio
async def test_single_flight_startup(config_factory: Callable[..., Config]) -> None:
    sup = Supervisor(config_factory())
    try:
        await asyncio.gather(*[sup.ensure_ready() for _ in range(5)])
        assert sup.stats().starts == 1
        assert sup.stats().state == State.READY
    finally:
        await sup.shutdown()


@pytest.mark.asyncio
async def test_crash_recovery(config_factory: Callable[..., Config]) -> None:
    sup = Supervisor(config_factory())
    try:
        await sup.ensure_ready()
        first_pid = sup.stats().pid
        assert first_pid is not None
        os.kill(first_pid, signal.SIGKILL)
        # Let asyncio's child watcher reap the exit.
        for _ in range(50):
            await asyncio.sleep(0.05)
            if sup._process is None or sup._process.returncode is not None:  # noqa: SLF001
                break
        await sup.ensure_ready()
        assert sup.stats().state == State.READY
        assert sup.stats().pid != first_pid
        assert sup.stats().starts == 2
    finally:
        await sup.shutdown()


@pytest.mark.asyncio
async def test_ensure_ready_raises_without_cmd() -> None:
    sup = Supervisor(Config(upstream_cmd=[]))
    with pytest.raises(RuntimeError, match="upstream_cmd"):
        await sup.ensure_ready()


@pytest.mark.asyncio
async def test_pauses_before_unloading(config_factory: Callable[..., Config]) -> None:
    sup = Supervisor(
        config_factory(
            pause_after_seconds=0.2,
            idle_timeout_seconds=5.0,
            idle_check_interval_seconds=0.05,
        )
    )
    try:
        await sup.start_idle_watcher()
        await sup.ensure_ready()
        await _wait_for_state(sup, State.PAUSED, timeout=3.0)
        # Still alive, not unloaded yet.
        assert sup.stats().pid is not None
        assert sup.stats().stops == 0
    finally:
        await sup.shutdown()


@pytest.mark.asyncio
async def test_ensure_ready_resumes_paused(config_factory: Callable[..., Config]) -> None:
    sup = Supervisor(
        config_factory(
            pause_after_seconds=0.2,
            idle_timeout_seconds=10.0,
            idle_check_interval_seconds=0.05,
        )
    )
    try:
        await sup.start_idle_watcher()
        await sup.ensure_ready()
        first_pid = sup.stats().pid
        await _wait_for_state(sup, State.PAUSED, timeout=3.0)
        await sup.ensure_ready()
        assert sup.stats().state == State.READY
        # Same process: we resumed, not re-spawned.
        assert sup.stats().pid == first_pid
        assert sup.stats().starts == 1
    finally:
        await sup.shutdown()


@pytest.mark.asyncio
async def test_paused_then_unloaded(config_factory: Callable[..., Config]) -> None:
    sup = Supervisor(
        config_factory(
            pause_after_seconds=0.1,
            idle_timeout_seconds=0.4,
            idle_check_interval_seconds=0.05,
        )
    )
    try:
        await sup.start_idle_watcher()
        await sup.ensure_ready()
        await _wait_for_state(sup, State.IDLE, timeout=3.0)
        assert sup.stats().stops == 1
    finally:
        await sup.shutdown()


@pytest.mark.asyncio
async def test_pause_disabled_when_none(config_factory: Callable[..., Config]) -> None:
    sup = Supervisor(
        config_factory(
            pause_after_seconds=None,
            idle_timeout_seconds=0.3,
            idle_check_interval_seconds=0.05,
        )
    )
    try:
        await sup.start_idle_watcher()
        await sup.ensure_ready()
        await _wait_for_state(sup, State.IDLE, timeout=3.0)
        # Never paused along the way; went straight READY -> IDLE.
        assert sup.stats().stops == 1
    finally:
        await sup.shutdown()
