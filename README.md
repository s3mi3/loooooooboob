# loooooooboob

## `agario_awareness.lua`

An awareness / ESP overlay for an Agar.io-style Roblox game, written for the
[Project Vector Lua engine](https://projectvector.cc/lua).

### What it draws

| Feature | Description |
| --- | --- |
| **Distance indicators** | A line from your cell to every other cell, plus the distance (studs or pixels) as text. |
| **Threat indicators** | Cells big enough to eat you are highlighted red (edible cells green), using the game's real 1.25× mass eat rule. |
| **Virus indicators** | Viruses are drawn as bright spiky stars, tagged `DANGER`/`SAFE` based on your size. |
| **Split-range indicators** | A ring showing how far a cell could reach if it split — around threats (their kill zone) and optionally you. The reach uses the game's actual split physics. |

Toggle/tune everything live from the **AgarESP** menu tab. **INSERT** toggles
the overlay.

### How it works (this was tuned to a real place file)

The reference game (**Agar2D**) is a **2D** Roblox game — cells are *not* 3D
parts, they're circular GUI `Frame`s drawn into a ScreenGui:

```
PlayerGui > Agar2DScreen > Root > World > (circle Frames)
```

So the script reads the on-screen circles directly. Each cell circle exposes:

- `Position` offset → its centre on screen (px)
- `Size` offset → its diameter on screen (px)
- `BackgroundColor3` → its colour (viruses are RGB `138,207,0`)
- `LabelStack.ScoreLabel.Text` → its exact mass
- `LabelStack.NameLabel.Text` → the player's name

From mass the script recovers the world scale (`radius = 0.632·√mass`), so
distances and rings can be shown in real studs and the split reach is the
game-accurate `0.632·√mass + 700·clamp((10000/mass)^0.28, 0.22, 1) / 1.9`.

### Modes (`General → Mode`)

- **Auto** – use 2D GUI mode if the ScreenGui is found, else 3D. *Default.*
- **2D GUI** – force the GUI-circle reader.
- **3D parts** – fallback for a 3D Agar game: reads `entity.GetPlayers()` and
  Workspace parts via `draw.WorldToScreen`.

### If your build differs

Every tunable (ScreenGui name via the `CFG` block, virus colour, eat ratio,
split reach scale, your name) is adjustable. **Debug → Dump GUI** prints the
circle tree plus a raw `Position`/`Size` sample to the console so you can see
exactly how your build is laid out and adjust `CFG.gui_screen` / `CFG.gui_path`
if the names differ.
