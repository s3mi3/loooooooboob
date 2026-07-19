"""FastAPI application: UI API + Roblox HttpService bridge endpoints."""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any, Optional

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import __version__
from .protocol import BridgeResult, Op, PollRequest, PollResponse
from .session import SessionManager

STATIC_DIR = Path(__file__).resolve().parent / "static"


class CommandRequest(BaseModel):
    op: Op
    path: str = ""
    query: str = ""
    property_name: str = ""
    value: Any = None
    limit: int = Field(default=200, ge=1, le=2000)
    session_id: Optional[str] = None
    timeout: float = Field(default=10.0, ge=1.0, le=60.0)


def create_app(manager: SessionManager) -> FastAPI:
    app = FastAPI(
        title="Roblox Dex Explorer",
        version=__version__,
        description="External explorer for your own Roblox game via an in-game bridge script.",
    )
    app.state.manager = manager

    def require_bridge_auth(authorization: Optional[str] = Header(default=None)) -> None:
        if not manager.check_token(authorization):
            raise HTTPException(status_code=401, detail="Invalid bridge token")

    def require_ui_auth(authorization: Optional[str] = Header(default=None)) -> None:
        # Same token protects UI mutating routes when called externally.
        if not manager.check_token(authorization):
            raise HTTPException(status_code=401, detail="Invalid auth token")

    @app.get("/api/health")
    async def health() -> dict[str, Any]:
        sessions = manager.list_sessions()
        connected = sum(1 for s in sessions if s.connected)
        return {
            "ok": True,
            "version": __version__,
            "connected_sessions": connected,
            "sessions": [s.model_dump() for s in sessions],
            "server_time": time.time(),
        }

    @app.get("/api/config")
    async def config() -> dict[str, Any]:
        return {
            "version": __version__,
            "auth_token": manager.auth_token,
            "bridge_poll_path": "/bridge/poll",
            "bridge_result_path": "/bridge/result",
        }

    @app.get("/api/sessions")
    async def sessions(_: None = Depends(require_ui_auth)) -> dict[str, Any]:
        return {"sessions": [s.model_dump() for s in manager.list_sessions()]}

    @app.post("/api/command")
    async def command(
        body: CommandRequest,
        _: None = Depends(require_ui_auth),
    ) -> dict[str, Any]:
        result = await manager.run_command(
            body.op,
            path=body.path,
            query=body.query,
            property_name=body.property_name,
            value=body.value,
            limit=body.limit,
            session_id=body.session_id,
            timeout=body.timeout,
        )
        return result.model_dump()

    @app.post("/bridge/poll", response_model=PollResponse)
    async def bridge_poll(
        body: PollRequest,
        _: None = Depends(require_bridge_auth),
    ) -> PollResponse:
        commands = await manager.poll(body)
        return PollResponse(commands=commands, server_time=time.time())

    @app.post("/bridge/result")
    async def bridge_result(
        body: BridgeResult,
        _: None = Depends(require_bridge_auth),
    ) -> dict[str, Any]:
        matched = await manager.submit_result(body)
        return {"ok": True, "matched": matched}

    @app.get("/")
    async def index() -> FileResponse:
        return FileResponse(STATIC_DIR / "index.html")

    if STATIC_DIR.exists():
        app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

    return app


def build_default_app(token: Optional[str] = None) -> FastAPI:
    manager = SessionManager(auth_token=token or SessionManager.generate_token())
    return create_app(manager)
