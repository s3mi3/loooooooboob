#!/usr/bin/env python3
"""Simulate a Roblox game bridge for UI demos without Studio."""

from __future__ import annotations

import argparse
import time
import uuid

import httpx

TREE = {
    "game": [
        ("Workspace", "Workspace"),
        ("Players", "Players"),
        ("ReplicatedStorage", "ReplicatedStorage"),
        ("ServerScriptService", "ServerScriptService"),
        ("Lighting", "Lighting"),
    ],
    "game.Workspace": [
        ("Baseplate", "Part"),
        ("SpawnLocation", "SpawnLocation"),
        ("Obby", "Model"),
    ],
    "game.Workspace.Obby": [
        ("Stage1", "Folder"),
        ("Stage2", "Folder"),
        ("KillBrick", "Part"),
    ],
    "game.Players": [],
    "game.ReplicatedStorage": [
        ("Remotes", "Folder"),
        ("Modules", "Folder"),
    ],
    "game.ReplicatedStorage.Remotes": [
        ("PurchaseItem", "RemoteEvent"),
        ("GetInventory", "RemoteFunction"),
    ],
    "game.ServerScriptService": [
        ("DexBridge", "Script"),
        ("GameManager", "Script"),
    ],
    "game.Lighting": [],
}


def node(name: str, class_name: str, path: str) -> dict:
    kids = TREE.get(path, [])
    return {
        "name": name,
        "class_name": class_name,
        "path": path,
        "child_count": len(kids),
        "has_children": len(kids) > 0,
    }


def handle(cmd: dict) -> dict:
    op = cmd["op"]
    path = cmd.get("path") or "game"
    if op == "ping":
        return {"pong": True, "studio": True}
    if op == "list_services":
        services = [node(n, c, f"game.{n}") for n, c in TREE["game"]]
        return {"services": services}
    if op == "get_children":
        children = [node(n, c, f"{path}.{n}" if path != "game" else f"game.{n}") for n, c in TREE.get(path, [])]
        # Fix paths for root-level services already correct
        if path == "game":
            children = [node(n, c, f"game.{n}") for n, c in TREE["game"]]
        return {"children": children}
    if op == "get_properties":
        name = path.split(".")[-1]
        class_name = "Instance"
        for entries in TREE.values():
            for n, c in entries:
                if n == name:
                    class_name = c
        return {
            "path": path,
            "class_name": class_name,
            "properties": [
                {"name": "Name", "type_name": "string", "value": name, "editable": True, "readonly": False},
                {"name": "ClassName", "type_name": "string", "value": class_name, "editable": False, "readonly": True},
                {"name": "Parent", "type_name": "Instance", "value": ".".join(path.split(".")[:-1]) or "game", "editable": False, "readonly": True},
                {"name": "Anchored", "type_name": "boolean", "value": True, "editable": True, "readonly": False},
                {"name": "Transparency", "type_name": "number", "value": 0, "editable": True, "readonly": False},
            ],
        }
    if op == "search":
        q = (cmd.get("query") or "").lower()
        matches = []
        for parent, entries in TREE.items():
            for n, c in entries:
                p = f"{parent}.{n}" if parent != "game" else f"game.{n}"
                if parent == "game":
                    p = f"game.{n}"
                if q in n.lower() or q in c.lower():
                    matches.append(node(n, c, p))
        return {"matches": matches[: cmd.get("limit", 80)], "query": cmd.get("query")}
    if op == "set_property":
        return {"path": path, "property_name": cmd.get("property_name"), "value": cmd.get("value")}
    return {"ok": True}


def main() -> None:
    parser = argparse.ArgumentParser(description="Mock Roblox Dex bridge")
    parser.add_argument("--base", default="http://127.0.0.1:3847")
    parser.add_argument("--token", required=True)
    args = parser.parse_args()
    session_id = uuid.uuid4().hex
    headers = {"Authorization": f"Bearer {args.token}"}
    print(f"Mock bridge session {session_id} → {args.base}")
    with httpx.Client(timeout=10.0) as client:
        while True:
            poll = client.post(
                f"{args.base}/bridge/poll",
                headers=headers,
                json={
                    "session_id": session_id,
                    "place_id": 0,
                    "place_name": "MockPlace",
                    "studio": True,
                    "player_count": 1,
                },
            )
            poll.raise_for_status()
            for cmd in poll.json().get("commands", []):
                data = handle(cmd)
                client.post(
                    f"{args.base}/bridge/result",
                    headers=headers,
                    json={"id": cmd["id"], "ok": True, "data": data},
                )
            time.sleep(0.25)


if __name__ == "__main__":
    main()
