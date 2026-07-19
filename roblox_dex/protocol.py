"""Shared command protocol between the desktop app and Roblox bridge."""

from __future__ import annotations

from enum import Enum
from typing import Any, Optional

from pydantic import BaseModel, Field


class Op(str, Enum):
    PING = "ping"
    LIST_SERVICES = "list_services"
    GET_CHILDREN = "get_children"
    GET_PROPERTIES = "get_properties"
    GET_DESCENDANTS_COUNT = "get_descendants_count"
    SEARCH = "search"
    SET_PROPERTY = "set_property"
    GET_FULL_NAME = "get_full_name"


class BridgeCommand(BaseModel):
    id: str
    op: Op
    path: str = ""
    query: str = ""
    property_name: str = ""
    value: Any = None
    limit: int = 200


class BridgeResult(BaseModel):
    id: str
    ok: bool = True
    error: Optional[str] = None
    data: Any = None


class PollRequest(BaseModel):
    session_id: str = Field(..., min_length=1, max_length=128)
    place_id: Optional[int] = None
    place_name: Optional[str] = None
    job_id: Optional[str] = None
    studio: bool = False
    player_count: Optional[int] = None


class PollResponse(BaseModel):
    commands: list[BridgeCommand] = Field(default_factory=list)
    server_time: float


class InstanceNode(BaseModel):
    name: str
    class_name: str
    path: str
    child_count: int = 0
    has_children: bool = False


class PropertyValue(BaseModel):
    name: str
    type_name: str
    value: Any
    editable: bool = False
    readonly: bool = False


class SessionInfo(BaseModel):
    session_id: str
    place_id: Optional[int] = None
    place_name: Optional[str] = None
    job_id: Optional[str] = None
    studio: bool = False
    player_count: Optional[int] = None
    last_seen: float
    connected: bool = True
