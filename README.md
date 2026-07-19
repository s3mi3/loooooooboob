# Roblox Dex Explorer

External Dex-style explorer for **your own** Roblox place. Browse the DataModel tree, inspect properties, search instances, and edit safe values — from a desktop app, not from an injected GUI.

This is **not** an exploit. It does not read Roblox process memory, inject DLLs, or attach to games you do not control. A bridge script you place in ServerScriptService polls your local app over HttpService.

## Features

- Instance tree (services → children), expand on demand
- Property inspector with safe inline edits
- Name / class search
- Path copy
- Auth-token gated bridge
- Works in Roblox Studio Play (localhost). Live servers need a tunnel to your machine.

## Quick start

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python main.py
```

The UI opens at [http://127.0.0.1:3847](http://127.0.0.1:3847). Copy the auth token from the terminal or the Setup panel.

### Wire up your place

1. In Roblox Studio, open **your** place.
2. Create a **Script** under `ServerScriptService`.
3. Paste the contents of [`roblox/DexBridge.server.lua`](roblox/DexBridge.server.lua).
4. Set `AUTH_TOKEN` to the token from the app.
5. Leave `BRIDGE_BASE` as `http://127.0.0.1:3847` for Studio.
6. **Game Settings → Security → Allow HTTP requests**.
7. Press **Play**. The status pill should turn online.

### Try the UI without Studio

```bash
# terminal 1
python main.py --no-browser

# terminal 2 (use the token printed by main.py)
python tools/mock_bridge.py --token YOUR_TOKEN
```

## How it works

```
Dex Explorer UI  --commands-->  Local FastAPI session queue
                                      ^
                                      | poll / result
                                      v
                               DexBridge Script (your place)
```

Roblox cannot accept inbound HTTP, so the bridge **polls** the local app, runs explorer commands (`list_services`, `get_children`, `get_properties`, `search`, `set_property`), and posts results back.

## CLI

```bash
python main.py --host 127.0.0.1 --port 3847
python main.py --token 'your-secret' --no-browser
```

Token persistence: `~/.roblox-dex-token` (or `ROBLOX_DEX_TOKEN`).

## Security

- Bind to `127.0.0.1` by default.
- Bridge and UI command routes require the shared bearer token.
- Property writes are limited to a safe allowlist in the Lua bridge.
- Only add the bridge script to places you own or have permission to modify.
- Remove or disable the script before publishing if you do not want HTTP polling in production.

## Live games

Studio can reach `127.0.0.1`. A published server cannot. To inspect a live server you control, expose the app with a tunnel (ngrok, Cloudflare Tunnel, etc.) and set `BRIDGE_BASE` to that HTTPS URL. Keep the token secret.

## Tests

```bash
pip install -r requirements.txt
pytest -q
```

## Project layout

| Path | Purpose |
|------|---------|
| `main.py` | App entrypoint |
| `roblox_dex/` | FastAPI server, session queue, UI |
| `roblox/DexBridge.server.lua` | In-game bridge |
| `tools/mock_bridge.py` | Local fake game for UI testing |
| `tests/` | Protocol / API tests |
