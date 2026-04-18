from __future__ import annotations

from collections.abc import Callable

import httpx
import pytest

from vllm_mlx_siesta.config import Config
from vllm_mlx_siesta.proxy import create_app
from vllm_mlx_siesta.supervisor import Supervisor


def _client(config: Config, sup: Supervisor) -> httpx.AsyncClient:
    app = create_app(config, sup)
    transport = httpx.ASGITransport(app=app)
    return httpx.AsyncClient(transport=transport, base_url="http://test")


@pytest.mark.asyncio
async def test_healthz_reports_idle_before_requests(
    config_factory: Callable[..., Config],
) -> None:
    config = config_factory()
    sup = Supervisor(config)
    try:
        async with _client(config, sup) as client:
            resp = await client.get("/healthz")
            assert resp.status_code == 200
            data = resp.json()
            assert data["state"] == "idle"
            assert data["in_flight"] == 0
    finally:
        await sup.shutdown()


@pytest.mark.asyncio
async def test_proxy_forwards_get(config_factory: Callable[..., Config]) -> None:
    config = config_factory()
    sup = Supervisor(config)
    try:
        async with _client(config, sup) as client:
            resp = await client.get("/hello")
            assert resp.status_code == 200
            assert resp.text == "hello world"
            assert sup.stats().state.value == "ready"
    finally:
        await sup.shutdown()


@pytest.mark.asyncio
async def test_proxy_forwards_post_body(config_factory: Callable[..., Config]) -> None:
    config = config_factory()
    sup = Supervisor(config)
    try:
        async with _client(config, sup) as client:
            resp = await client.post("/echo", content=b"hello siesta")
            assert resp.status_code == 200
            payload = resp.json()
            assert payload["echo"] == "hello siesta"
            assert payload["path"] == "/echo"
    finally:
        await sup.shutdown()


@pytest.mark.asyncio
async def test_proxy_activity_increments_last_activity(
    config_factory: Callable[..., Config],
) -> None:
    config = config_factory()
    sup = Supervisor(config)
    try:
        before = sup.stats().last_activity
        async with _client(config, sup) as client:
            resp = await client.get("/hello")
            assert resp.status_code == 200
        after = sup.stats().last_activity
        assert after is not None
        assert before is not None
        assert after >= before
    finally:
        await sup.shutdown()


@pytest.mark.asyncio
async def test_proxy_503_when_upstream_cannot_start() -> None:
    config = Config(upstream_cmd=["/nonexistent/bin/does-not-exist"])
    sup = Supervisor(config)
    try:
        async with _client(config, sup) as client:
            resp = await client.get("/anything")
            assert resp.status_code == 503
            assert resp.headers.get("retry-after") == "5"
            assert resp.json()["error"]["type"] == "upstream_unavailable"
    finally:
        await sup.shutdown()
