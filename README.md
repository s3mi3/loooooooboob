# Roblox Debug Explorer

An in-game hierarchy and property inspector for **games you develop**. It draws a
live Explorer-style window on top of your running experience so you can browse the
DataModel, read instance properties, and search for objects **while reproducing a
bug on the client** — the situation where Studio's own Explorer isn't practical
because you need to be in the live session.

It is a plain `LocalScript`. It runs inside Roblox's normal Luau sandbox and only
reads what any game script is allowed to read. There is **no external process, no
memory reading, and no injection** — it is conceptually the same as Studio's
Explorer, just embedded in your own place. Add it to a game you control; it is not
a tool for inspecting other people's games.

## Features

- **Hierarchy tree** starting at `game`, with expand/collapse and lazy walking.
- **Properties panel** with a curated, per-class property list read safely at
  runtime. Instance-valued properties are clickable and jump to that object.
- **Search** by name or class name across the whole client DataModel.
- **3D highlight** of the selected part/model via a `Highlight`.
- **Live auto-refresh** of the selected instance's properties (default every 0.5s),
  so values you're watching update as the game runs.
- **Draggable window**, on-screen toggle button, and a keyboard toggle
  (default: <kbd>Right Ctrl</kbd>).

## Install

### Option A — Rojo (recommended)

This repo is a [Rojo](https://rojo.space/) project. With Rojo installed:

```bash
rojo serve
```

Then connect from the Roblox Studio Rojo plugin. It syncs the script to
`StarterPlayer > StarterPlayerScripts > DebugExplorer`. Publish/play and it's active.

### Option B — Manual (no tooling)

1. In Studio, under **StarterPlayer > StarterPlayerScripts**, insert a **LocalScript**
   named `DebugExplorer`.
2. Copy the contents of [`src/DebugExplorer.client.lua`](src/DebugExplorer.client.lua)
   into it.
3. Play the game.

## Usage

- Press <kbd>Right Ctrl</kbd> (or click the **Explorer** button, bottom-left) to
  toggle the window.
- Click the arrows to expand nodes; click a row to select it and view its properties.
- Type in the search box to filter by name or class across the whole client tree.
- Drag the title bar to reposition the window.

## Configuration

Edit the `CONFIG` table at the top of `src/DebugExplorer.client.lua`:

| Key | Default | Meaning |
| --- | --- | --- |
| `ToggleKey` | `Enum.KeyCode.RightControl` | Key that shows/hides the window |
| `StartOpen` | `false` | Open automatically on join |
| `WindowSize` | `760 x 470` | Initial window size in pixels |
| `AutoRefresh` | `true` | Keep selected properties live |
| `RefreshInterval` | `0.5` | Seconds between property refreshes |
| `MaxChildrenPerNode` | `300` | Cap children rendered under one node |
| `MaxSearchResults` | `300` | Cap search results |

## Limitations (by design and by platform rules)

- **Client-only.** It shows what the client can see. Server-only containers such as
  `ServerScriptService` and `ServerStorage` are not replicated to clients and will
  not appear. To inspect the server DataModel, use Studio **Team Test** and switch
  the view to **Current: Server**.
- **No script source.** A regular runtime script cannot read `Script.Source`
  (it's protected outside of Studio plugins), so source is intentionally not shown.
- **Curated properties.** Luau has no general runtime reflection for arbitrary
  instances, so properties come from a maintained per-class list in the script.
  Add entries to `PROPERTY_GROUPS` if you need more.

## Development

Syntax is checked with the official Luau CLI:

```bash
luau-compile --binary src/DebugExplorer.client.lua   # parse/compile check
luau-analyze src/DebugExplorer.client.lua            # static analysis
```

`luau-analyze` reports Roblox globals (`game`, `Enum`, `Instance`, `task`, …) as
unknown because it runs without Roblox's type definitions; those resolve at runtime
inside Roblox.
