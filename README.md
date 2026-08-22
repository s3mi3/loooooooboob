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

### How it works (reverse-engineered from real place files)

These Agar-style Roblox games render cells as **2D GUI circles**, not 3D parts,
so the script reads the on-screen circle Frames directly. It auto-detects the
layout via presets:

**`Agaric`** (ScreenGui `Agaric2D`) — the live game this was tuned to:

```
PlayerGui > Agaric2D > Camera > Canvas > LayerBottom/LayerMain > (entity frames)
```

- Cells = Frames named **`PlayerBlob`** (child `Visual` ImageLabel = colour,
  `NameLabel`/`MassLabel` = text).
- Viruses = ImageLabels named **`Spike`**.
- The `Camera` frame is centred and `UIScale`d, so screen pixels are read from
  **`AbsolutePosition`/`AbsoluteSize`** (with a render-scale fallback via the
  `Camera`'s `UIScale`).

**`Agar2D`** (ScreenGui `Agar2DScreen`) — an alternative template:

- Cells = circle Frames under `Root > World` that have a numeric `ScoreLabel`.
- Viruses = circles coloured RGB `138,207,0`.
- `World` is fullscreen, so the `Position`/`Size` offsets are already screen px.

**`3D`** — fallback for a 3D Agar game: `entity.GetPlayers()` + Workspace parts
via `draw.WorldToScreen`.

Classification is name-based where possible (robust), threats use the on-screen
radius ratio from the `Eat mass ratio` slider (default 125 % → √1.25 radius
ratio), and viruses are tagged `DANGER` when you're big enough to pop one.

### Modes (`General → Mode`)

- **Auto** – try Agaric, then Agar2D, else 3D. *Default.*
- **Agaric** / **Agar2D** / **3D parts** – force a specific preset.

### If your build differs

Presets live in the `PRESETS` table at the top of the script (ScreenGui name,
container path, cell/virus frame names, label paths). **Debug → Dump GUI**
prints the resolved container plus a sample frame's `AbsolutePosition` /
`Position` / `Size` so you can confirm the layout and adjust the preset if a
future update renames things.
