"""In-memory session + command queue for the Roblox bridge."""

from __future__ import annotations

import asyncio
import secrets
import time
import uuid
from typing import Any, Optional

from .protocol import (
    BridgeCommand,
    BridgeResult,
    Op,
    PollRequest,
    SessionInfo,
)


class PendingCommand:
    def __init__(self, command: BridgeCommand) -> None:
        self.command = command
        self.created_at = time.time()
        self.future: asyncio.Future[BridgeResult] = asyncio.get_running_loop().create_future()


class BridgeSession:
    def __init__(self, info: SessionInfo) -> None:
        self.info = info
        self.queue: list[PendingCommand] = []
        self.lock = asyncio.Lock()

    def touch(self, poll: PollRequest) -> None:
        self.info.last_seen = time.time()
        self.info.connected = True
        self.info.place_id = poll.place_id
        self.info.place_name = poll.place_name
        self.info.job_id = poll.job_id
        self.info.studio = poll.studio
        self.info.player_count = poll.player_count

    async def enqueue(self, command: BridgeCommand) -> PendingCommand:
        pending = PendingCommand(command)
        async with self.lock:
            self.queue.append(pending)
        return pending

    async def take(self, max_commands: int = 8) -> list[BridgeCommand]:
        async with self.lock:
            # Drop timed-out waiters so the Lua bridge never gets stale work.
            alive: list[PendingCommand] = []
            now = time.time()
            for item in self.queue:
                if item.future.done():
                    continue
                if now - item.created_at > 30:
                    if not item.future.done():
                        item.future.set_result(
                            BridgeResult(
                                id=item.command.id,
                                ok=False,
                                error="Command timed out before the game picked it up",
                            )
                        )
                    continue
                alive.append(item)
            taken = alive[:max_commands]
            self.queue = alive[max_commands:]
            return [item.command for item in taken]

    async def resolve(self, result: BridgeResult) -> bool:
        async with self.lock:
            for item in self.queue:
                if item.command.id == result.id and not item.future.done():
                    item.future.set_result(result)
                    self.queue.remove(item)
                    return True
        # Also check recently taken commands via a side map
        return False


class SessionManager:
    """Tracks connected game bridges and pending UI commands."""

    def __init__(self, auth_token: str, stale_after: float = 8.0) -> None:
        self.auth_token = auth_token
        self.stale_after = stale_after
        self.sessions: dict[str, BridgeSession] = {}
        self._pending_by_id: dict[str, PendingCommand] = {}
        self._lock = asyncio.Lock()

    @staticmethod
    def generate_token() -> str:
        return secrets.token_urlsafe(24)

    def check_token(self, provided: Optional[str]) -> bool:
        if not provided:
            return False
        token = provided.removeprefix("Bearer ").strip()
        return secrets.compare_digest(token, self.auth_token)

    async def poll(self, poll: PollRequest) -> list[BridgeCommand]:
        async with self._lock:
            session = self.sessions.get(poll.session_id)
            if session is None:
                session = BridgeSession(
                    SessionInfo(
                        session_id=poll.session_id,
                        last_seen=time.time(),
                    )
                )
                self.sessions[poll.session_id] = session
            session.touch(poll)
        return await session.take()

    async def submit_result(self, result: BridgeResult) -> bool:
        pending = self._pending_by_id.pop(result.id, None)
        if pending is None:
            # Fall back to scanning sessions (race with take())
            async with self._lock:
                sessions = list(self.sessions.values())
            for session in sessions:
                if await session.resolve(result):
                    return True
            return False
        if not pending.future.done():
            pending.future.set_result(result)
        return True

    async def run_command(
        self,
        op: Op,
        *,
        path: str = "",
        query: str = "",
        property_name: str = "",
        value: Any = None,
        limit: int = 200,
        session_id: Optional[str] = None,
        timeout: float = 10.0,
    ) -> BridgeResult:
        session = await self._resolve_session(session_id)
        if session is None:
            return BridgeResult(
                id="none",
                ok=False,
                error="No Roblox bridge is connected. Start Play in Studio with the bridge script.",
            )

        command = BridgeCommand(
            id=uuid.uuid4().hex,
            op=op,
            path=path,
            query=query,
            property_name=property_name,
            value=value,
            limit=limit,
        )
        pending = await session.enqueue(command)
        self._pending_by_id[command.id] = pending

        try:
            return await asyncio.wait_for(pending.future, timeout=timeout)
        except asyncio.TimeoutError:
            self._pending_by_id.pop(command.id, None)
            return BridgeResult(
                id=command.id,
                ok=False,
                error="Timed out waiting for the Roblox bridge. Is the game still running?",
            )

    async def _resolve_session(self, session_id: Optional[str]) -> Optional[BridgeSession]:
        async with self._lock:
            self._mark_stale_locked()
            if session_id:
                return self.sessions.get(session_id)
            # Prefer the most recently seen live session
            live = [
                s
                for s in self.sessions.values()
                if s.info.connected and (time.time() - s.info.last_seen) <= self.stale_after
            ]
            if not live:
                return None
            live.sort(key=lambda s: s.info.last_seen, reverse=True)
            return live[0]

    def list_sessions(self) -> list[SessionInfo]:
        self._mark_stale_locked_sync()
        return [s.info.model_copy() for s in self.sessions.values()]

    def _mark_stale_locked(self) -> None:
        now = time.time()
        for session in self.sessions.values():
            session.info.connected = (now - session.info.last_seen) <= self.stale_after

    def _mark_stale_locked_sync(self) -> None:
        now = time.time()
        for session in self.sessions.values():
            session.info.connected = (now - session.info.last_seen) <= self.stale_after
