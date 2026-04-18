from __future__ import annotations

import socket
import sys
from collections.abc import Callable
from pathlib import Path

import pytest

from vllm_mlx_siesta.config import Config

FAKE_UPSTREAM_SCRIPT = """
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, status: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        if self.path == "/v1/models":
            self._send_json(200, {"data": [{"id": "test-model"}]})
            return
        if self.path == "/hello":
            body = b"hello world"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body_in = self.rfile.read(length) if length else b""
        self._send_json(200, {"path": self.path, "echo": body_in.decode("utf-8", "replace")})

    def log_message(self, *args, **kwargs):  # noqa: D401
        pass


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
"""


def _free_port() -> int:
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])
    finally:
        s.close()


@pytest.fixture
def fake_upstream_script(tmp_path: Path) -> Path:
    path = tmp_path / "fake_upstream.py"
    path.write_text(FAKE_UPSTREAM_SCRIPT)
    return path


@pytest.fixture
def upstream_port() -> int:
    return _free_port()


@pytest.fixture
def config_factory(fake_upstream_script: Path, upstream_port: int) -> Callable[..., Config]:
    def _make(**overrides: object) -> Config:
        defaults: dict[str, object] = {
            "upstream_host": "127.0.0.1",
            "upstream_port": upstream_port,
            "upstream_cmd": [
                sys.executable,
                str(fake_upstream_script),
                str(upstream_port),
            ],
            "idle_timeout_seconds": 1.0,
            "idle_check_interval_seconds": 0.1,
            "startup_timeout_seconds": 10.0,
            "shutdown_grace_seconds": 1.0,
        }
        defaults.update(overrides)
        return Config(**defaults)  # type: ignore[arg-type]

    return _make
