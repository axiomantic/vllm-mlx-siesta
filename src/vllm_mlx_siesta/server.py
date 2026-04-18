from __future__ import annotations

import logging

import uvicorn

from .config import Config
from .proxy import create_app


def run(config: Config) -> None:
    logging.basicConfig(
        level=config.log_level.upper(),
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    app = create_app(config)
    uvicorn.run(
        app,
        host=config.listen_host,
        port=config.listen_port,
        log_level=config.log_level.lower(),
    )
