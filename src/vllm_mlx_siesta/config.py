from __future__ import annotations

import tomllib
from pathlib import Path
from typing import Any

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Config(BaseSettings):
    """Runtime configuration for vllm-mlx-siesta.

    Resolved from defaults, optional TOML file, env vars (``SIESTA_*``),
    then CLI overrides in ``__main__``.
    """

    model_config = SettingsConfigDict(env_prefix="SIESTA_", extra="forbid")

    listen_host: str = "127.0.0.1"
    listen_port: int = 8080

    upstream_host: str = "127.0.0.1"
    upstream_port: int = 8000
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
    startup_timeout_seconds: float = 120.0
    shutdown_grace_seconds: float = 10.0

    health_probe_path: str = "/v1/models"
    log_level: str = "INFO"

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
