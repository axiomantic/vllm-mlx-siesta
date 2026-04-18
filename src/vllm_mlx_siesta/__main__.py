from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .config import Config
from .server import run

_OVERRIDE_FIELDS = (
    "listen_host",
    "listen_port",
    "upstream_host",
    "upstream_port",
    "upstream_cmd",
    "pause_after_seconds",
    "idle_timeout_seconds",
    "idle_check_interval_seconds",
    "startup_timeout_seconds",
    "shutdown_grace_seconds",
    "health_probe_path",
    "log_level",
)


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="vllm-mlx-siesta",
        description="Idle-timeout reverse proxy for vllm-mlx on macOS Apple Silicon.",
    )
    p.add_argument("--config", type=Path, help="Path to TOML config file")
    p.add_argument("--listen-host", dest="listen_host")
    p.add_argument("--listen-port", dest="listen_port", type=int)
    p.add_argument("--upstream-host", dest="upstream_host")
    p.add_argument("--upstream-port", dest="upstream_port", type=int)
    p.add_argument(
        "--upstream-cmd",
        dest="upstream_cmd",
        nargs="+",
        help="Command + args to launch the upstream vllm-mlx process",
    )
    p.add_argument(
        "--pause-after-seconds",
        dest="pause_after_seconds",
        type=float,
        help="SIGSTOP the upstream after this many seconds idle (None/0 disables pause step)",
    )
    p.add_argument("--idle-timeout-seconds", dest="idle_timeout_seconds", type=float)
    p.add_argument("--idle-check-interval-seconds", dest="idle_check_interval_seconds", type=float)
    p.add_argument("--startup-timeout-seconds", dest="startup_timeout_seconds", type=float)
    p.add_argument("--shutdown-grace-seconds", dest="shutdown_grace_seconds", type=float)
    p.add_argument("--health-probe-path", dest="health_probe_path")
    p.add_argument("--log-level", dest="log_level")
    return p


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    config = Config.from_toml(args.config) if args.config else Config()
    overrides: dict[str, object] = {}
    for field in _OVERRIDE_FIELDS:
        value = getattr(args, field, None)
        if value is None:
            continue
        if field == "pause_after_seconds" and value == 0:
            overrides[field] = None
        else:
            overrides[field] = value
    if overrides:
        config = config.model_copy(update=overrides)

    if not config.upstream_cmd:
        print(
            "error: upstream_cmd is required (set via --upstream-cmd, SIESTA_UPSTREAM_CMD, "
            "or upstream_cmd in the TOML config)",
            file=sys.stderr,
        )
        return 2

    run(config)
    return 0


if __name__ == "__main__":
    sys.exit(main())
