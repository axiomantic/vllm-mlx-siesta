from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse

from .config import Config
from .supervisor import Supervisor

logger = logging.getLogger(__name__)

HOP_BY_HOP_REQUEST_HEADERS = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailers",
        "transfer-encoding",
        "upgrade",
        "host",
        "content-length",
    }
)

HOP_BY_HOP_RESPONSE_HEADERS = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailers",
        "transfer-encoding",
        "upgrade",
    }
)


def create_app(config: Config, supervisor: Supervisor | None = None) -> FastAPI:
    sup = supervisor if supervisor is not None else Supervisor(config)

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        await sup.start_idle_watcher()
        try:
            yield
        finally:
            await sup.shutdown()

    app = FastAPI(
        title="vllm-mlx-siesta",
        description="Idle-timeout reverse proxy for vllm-mlx",
        lifespan=lifespan,
    )
    app.state.supervisor = sup
    app.state.config = config

    @app.get("/healthz")
    async def healthz() -> dict[str, object]:
        stats = sup.stats()
        return {
            "state": stats.state.value,
            "pid": stats.pid,
            "in_flight": stats.in_flight,
            "last_activity": stats.last_activity,
            "starts": stats.starts,
            "stops": stats.stops,
        }

    @app.api_route(
        "/{path:path}",
        methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"],
    )
    async def proxy(path: str, request: Request) -> Response:
        return await _forward(request, sup, config, path)

    return app


async def _forward(request: Request, sup: Supervisor, config: Config, path: str) -> Response:
    try:
        await sup.ensure_ready()
    except Exception as e:
        logger.exception("Cold-start failed")
        return JSONResponse(
            status_code=503,
            headers={"Retry-After": "5"},
            content={
                "error": {"type": "upstream_unavailable", "message": str(e)},
            },
        )

    upstream_url = f"http://{config.upstream_host}:{config.upstream_port}/{path}"
    if request.url.query:
        upstream_url = f"{upstream_url}?{request.url.query}"

    request_headers = {
        k: v for k, v in request.headers.items() if k.lower() not in HOP_BY_HOP_REQUEST_HEADERS
    }
    body = await request.body()

    slot = sup.request_slot()
    await slot.__aenter__()
    released = False

    async def release_slot() -> None:
        nonlocal released
        if not released:
            released = True
            await slot.__aexit__(None, None, None)

    client = httpx.AsyncClient(timeout=None)
    try:
        req = client.build_request(
            request.method, upstream_url, headers=request_headers, content=body
        )
        upstream_resp = await client.send(req, stream=True)
    except Exception:
        await client.aclose()
        await release_slot()
        raise

    response_headers = {
        k: v
        for k, v in upstream_resp.headers.items()
        if k.lower() not in HOP_BY_HOP_RESPONSE_HEADERS
    }

    async def body_iter() -> AsyncIterator[bytes]:
        try:
            async for chunk in upstream_resp.aiter_raw():
                yield chunk
        finally:
            await upstream_resp.aclose()
            await client.aclose()
            await release_slot()

    return StreamingResponse(
        body_iter(),
        status_code=upstream_resp.status_code,
        headers=response_headers,
    )
