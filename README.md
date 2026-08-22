# loooooooboob

## `agario_awareness.lua`

An awareness / ESP overlay for an Agar.io-style Roblox game, written for the
[Project Vector Lua engine](https://projectvector.cc/lua).

### What it draws

| Feature | Description |
| --- | --- |
| **Distance indicators** | A line from your cell to every other cell, plus the distance (studs) as text. |
| **Threat indicators** | Cells big enough to eat you are highlighted in red (classic Agar 1.25× mass rule, tunable). Edible cells are green. |
| **Virus indicators** | Viruses are drawn as bright spiky stars with an optional `DANGER`/`SAFE` tag based on your size. |
| **Split-range indicators** | A ring showing how far a cell could reach if it split — drawn around threats (their kill reach) and optionally around you. |

Everything is toggled/tuned live from the **AgarESP** menu tab. Press **INSERT**
to toggle the whole overlay.

### Install

Load `agario_awareness.lua` in the Project Vector script console / autoload
folder. On load you'll get a toast and a new **AgarESP** tab.

### Adapting it to your game

Agar-style games store data differently, so two things are configurable:

1. **Cell source** (`General → Source`)
   - `Entities` – uses `entity.GetPlayers()`. Best when each blob is a tracked
     player/bot. **Default.**
   - `Workspace scan` – scans Workspace for round parts. Use this if your
     cells are loose parts that don't show up under Entities.

2. **Virus detection** (`Virus` group) – viruses are matched by part **name
   pattern** (default `[Vv]irus`) with an optional green-colour fallback. If
   viruses don't appear, press **Debug → Dump Workspace**, read the real virus
   part name from the console, and set the **Name pattern** accordingly. You can
   also narrow the scan to one container with **Scan container**.

Split-reach distance is `radius × mult + bonus` (both sliders under
**Split range**) — tune these to match your game's split physics.
