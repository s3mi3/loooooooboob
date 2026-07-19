"""CLI entry: python -m roblox_dex"""

from __future__ import annotations

import argparse
import os
import sys
import webbrowser
from pathlib import Path

import uvicorn

from .session import SessionManager
from .server import create_app


def _load_or_create_token(path: Path) -> str:
    if path.exists():
        token = path.read_text(encoding="utf-8").strip()
        if token:
            return token
    token = SessionManager.generate_token()
    path.write_text(token + "\n", encoding="utf-8")
    return token


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Roblox Dex Explorer — inspect your own game from an external app",
    )
    parser.add_argument("--host", default="127.0.0.1", help="Bind address (default 127.0.0.1)")
    parser.add_argument("--port", type=int, default=3847, help="Port (default 3847)")
    parser.add_argument(
        "--token",
        default=os.environ.get("ROBLOX_DEX_TOKEN"),
        help="Shared auth token (or set ROBLOX_DEX_TOKEN)",
    )
    parser.add_argument(
        "--token-file",
        type=Path,
        default=Path.home() / ".roblox-dex-token",
        help="Where to persist a generated token",
    )
    parser.add_argument("--no-browser", action="store_true", help="Do not open the UI")
    parser.add_argument("--reload", action="store_true", help="Dev auto-reload")
    args = parser.parse_args(argv)

    token = args.token or _load_or_create_token(args.token_file)
    manager = SessionManager(auth_token=token)
    app = create_app(manager)

    url = f"http://{args.host}:{args.port}"
    print("=" * 60)
    print("  Roblox Dex Explorer")
    print("=" * 60)
    print(f"  UI:     {url}")
    print(f"  Token:  {token}")
    print(f"  Bridge: {url}/bridge/poll")
    print()
    print("  1. Put roblox/DexBridge.server.lua in ServerScriptService")
    print("  2. Set BRIDGE_URL and AUTH_TOKEN in that script")
    print("  3. Enable HttpService.HttpEnabled in Studio")
    print("  4. Press Play — the explorer will connect")
    print("=" * 60)

    if not args.no_browser:
        # Slight delay so uvicorn is listening
        def _open() -> None:
            webbrowser.open(url)

        import threading

        threading.Timer(0.8, _open).start()

    uvicorn.run(app, host=args.host, port=args.port, reload=args.reload, log_level="info")
    return 0


if __name__ == "__main__":
    sys.exit(main())
