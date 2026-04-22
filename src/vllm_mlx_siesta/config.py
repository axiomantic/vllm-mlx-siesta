from __future__ import annotations

import tomllib
from pathlib import Path
from typing import Any

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Config(BaseSettings):
    """Runtime configuration for vllm-mlx-siesta.

    Resolved from defaults, optional TOML file, env vars (``SIESTA_*``),
    then CLI overrides in ``__main__``.
    """

    model_config = SettingsConfigDict(env_prefix="SIESTA_", extra="forbid")

    listen_host: str = "127.0.0.1"
    # 11435 slots in next to Ollama's conventional 11434 so the OpenAI-compatible
    # endpoint is in the same mental ballpark as other local LLM servers, and
    # avoids 8080's collisions with proxies, dev servers, and admin UIs.
    listen_port: int = 11435

    upstream_host: str = "127.0.0.1"
    # Internal-only; sequential with listen_port. Avoids 8000's ubiquity.
    upstream_port: int = 11436
    # Convenience: if set and ``upstream_cmd`` is empty, siesta synthesizes
    # ``["vllm-mlx", "serve", "--model", <model>, "--host", <host>, "--port", <port>]``.
    model: str | None = None
    # Explicit command takes precedence over the synthesized one from ``model``.
    upstream_cmd: list[str] = Field(default_factory=list)
    upstream_env: dict[str, str] = Field(default_factory=dict)

    # Hybrid idle lifecycle:
    #   pause_after_seconds idle  -> SIGSTOP (fast SIGCONT resume; RAM not freed)
    #   idle_timeout_seconds idle -> SIGTERM (RAM freed; cold-start on next request)
    # Set pause_after_seconds to None (or >= idle_timeout_seconds) to disable the
    # pause step and unload directly.
    pause_after_seconds: float | None = 60.0
    idle_timeout_seconds: float = 600.0
    idle_check_interval_seconds: float = 10.0
    # Generous default: cold-starting a 30B-class MLX model from a cold fs cache
    # regularly takes 2-4 minutes (download + metal init + weight mmap).
    startup_timeout_seconds: float = 300.0
    # SIGTERM -> SIGKILL grace. Needs to cover vllm-mlx finishing in-flight
    # streams AND Metal releasing allocator state -- 10s was too tight and left
    # orphan processes holding GBs of weights when LaunchAgent reloads raced
    # ahead of cleanup.
    shutdown_grace_seconds: float = 60.0

    # Cap concurrent in-flight requests forwarded to the upstream. Two problems
    # stack on top of each other with MLX continuous batching: per-request
    # latency collapses as the decode bandwidth gets split across the batch
    # (solo 2-3s vs 20-80s at three concurrent on our test box), and the
    # Metal allocator can abort the whole vllm-mlx process with an
    # uncatchable command-buffer error once contention spikes.
    # Serializing at the proxy avoids both. Bump it only if you've tested
    # that your model + memory budget stays stable under concurrent load.
    max_concurrent_upstream: int = 1

    health_probe_path: str = "/v1/models"
    log_level: str = "INFO"

    @field_validator("max_concurrent_upstream")
    @classmethod
    def _validate_concurrency(cls, v: int) -> int:
        if v < 1:
            raise ValueError("max_concurrent_upstream must be >= 1")
        return v

    @model_validator(mode="after")
    def _synthesize_upstream_cmd(self) -> Config:
        if not self.upstream_cmd and self.model:
            # vllm-mlx takes the model as a positional arg (see its cli.py).
            self.upstream_cmd = [
                "vllm-mlx",
                "serve",
                self.model,
                "--host",
                self.upstream_host,
                "--port",
                str(self.upstream_port),
            ]
        return self

    @classmethod
    def from_toml(cls, path: Path) -> Config:
        data: dict[str, Any] = tomllib.loads(path.read_text())
        return cls(**data)
