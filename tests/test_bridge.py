"""Protocol and session tests for Roblox Dex Explorer."""

from __future__ import annotations

import asyncio

import pytest
from httpx import ASGITransport, AsyncClient

from roblox_dex.protocol import BridgeResult, Op
from roblox_dex.server import create_app
from roblox_dex.session import SessionManager


@pytest.fixture
def manager() -> SessionManager:
    return SessionManager(auth_token="test-token-123", stale_after=5.0)


@pytest.fixture
def app(manager: SessionManager):
    return create_app(manager)


@pytest.mark.asyncio
async def test_health_and_config(app, manager: SessionManager):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        health = await client.get("/api/health")
        assert health.status_code == 200
        assert health.json()["ok"] is True

        cfg = await client.get("/api/config")
        assert cfg.json()["auth_token"] == manager.auth_token


@pytest.mark.asyncio
async def test_bridge_auth_required(app):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        res = await client.post(
            "/bridge/poll",
            json={"session_id": "s1"},
        )
        assert res.status_code == 401


@pytest.mark.asyncio
async def test_command_roundtrip(app, manager: SessionManager):
    transport = ASGITransport(app=app)
    headers = {"Authorization": "Bearer test-token-123"}

    async def bridge_worker():
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            for _ in range(50):
                poll = await client.post(
                    "/bridge/poll",
                    headers=headers,
                    json={
                        "session_id": "studio-1",
                        "place_id": 123,
                        "place_name": "TestPlace",
                        "studio": True,
                        "player_count": 1,
                    },
                )
                assert poll.status_code == 200
                commands = poll.json()["commands"]
                for cmd in commands:
                    assert cmd["op"] == "list_services"
                    result = BridgeResult(
                        id=cmd["id"],
                        ok=True,
                        data={
                            "services": [
                                {
                                    "name": "Workspace",
                                    "class_name": "Workspace",
                                    "path": "game.Workspace",
                                    "child_count": 2,
                                    "has_children": True,
                                }
                            ]
                        },
                    )
                    posted = await client.post(
                        "/bridge/result",
                        headers=headers,
                        json=result.model_dump(),
                    )
                    assert posted.status_code == 200
                await asyncio.sleep(0.05)

    worker = asyncio.create_task(bridge_worker())
    try:
        # Give the bridge a moment to register
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            await client.post(
                "/bridge/poll",
                headers=headers,
                json={
                    "session_id": "studio-1",
                    "place_id": 123,
                    "place_name": "TestPlace",
                    "studio": True,
                },
            )

            result = await manager.run_command(Op.LIST_SERVICES, session_id="studio-1", timeout=5)
            assert result.ok is True
            assert result.data["services"][0]["name"] == "Workspace"
    finally:
        worker.cancel()
        with pytest.raises(asyncio.CancelledError):
            await worker


@pytest.mark.asyncio
async def test_ui_command_endpoint(app, manager: SessionManager):
    transport = ASGITransport(app=app)
    headers = {"Authorization": "Bearer test-token-123"}

    async def respond():
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            while True:
                poll = await client.post(
                    "/bridge/poll",
                    headers=headers,
                    json={"session_id": "s2", "place_name": "Demo", "studio": True},
                )
                for cmd in poll.json()["commands"]:
                    await client.post(
                        "/bridge/result",
                        headers=headers,
                        json={
                            "id": cmd["id"],
                            "ok": True,
                            "data": {"children": []},
                        },
                    )
                await asyncio.sleep(0.05)

    task = asyncio.create_task(respond())
    try:
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            # Register session
            await client.post(
                "/bridge/poll",
                headers=headers,
                json={"session_id": "s2", "place_name": "Demo", "studio": True},
            )
            res = await client.post(
                "/api/command",
                headers=headers,
                json={"op": "get_children", "path": "game.Workspace", "session_id": "s2"},
            )
            assert res.status_code == 200
            body = res.json()
            assert body["ok"] is True
            assert body["data"]["children"] == []
    finally:
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task


@pytest.mark.asyncio
async def test_no_session_returns_error(manager: SessionManager):
    result = await manager.run_command(Op.PING, timeout=0.2)
    assert result.ok is False
    assert "bridge" in result.error.lower()
