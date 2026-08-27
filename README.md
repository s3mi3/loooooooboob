# Photon Agaric scripts

Photon Lua scripts for Agaric, using the [Photon API](https://photon-4.gitbook.io/api).

| Script | Window | What it does |
| --- | --- | --- |
| `tickrate.lua` | **Tickrate** | Client FPS cap via TaskScheduler FFlag (Workspace tickrate is a no-op in Agaric) |
| `awareness.lua` | **Agaric ESP** | Mass / threat / virus / merge timer overlay + auto-feed |
| `instant_merge.lua` | **Instant Merge** | Auto-taps the paid Merge ability (needs it equipped) |

## Load

1. Open Photon.
2. Drop the `.lua` file into your Photon scripts folder (or paste it into the Lua editor).
3. Run the script.
4. Open the Photon menu.

`tickrate.lua`, `awareness.lua`, and `instant_merge.lua` can run at the same time.

## Tickrate (`tickrate.lua`)

This will not make you faster in Agaric. Movement is server-side and `ClientPrediction` uses frame **delta time**, so more FPS just draws more often.

`set_tickrate()` and FFlags did nothing at runtime. The script now tries the external method: write TaskScheduler **MaxFPS** in memory (`game_baseaddress` + known RVAs, double at `+0xB0` / `+0x1B0`).

1. Run it and open Photon's log.
2. Click **Probe**. You want a line like `using ts+0xB0 kind=fps`.
3. If Probe says MaxFPS not found, this Roblox build's RVA is stale and Photon cannot unlock FPS until the pointer is updated.
4. If Probe finds it, enable the slider and watch **live FPS**. If live FPS rises, the cap worked — you still will not move at 2×.

| Control | What it does |
| --- | --- |
| **Enabled** | Starts off. Writes MaxFPS while on. |
| **Client FPS cap** | `30`–`360`. |
| **Probe** | Dumps base, FFlags, and each RVA/offset into the Photon log. |

## Agaric ESP (`awareness.lua`)

This is the Photon-only stuff other players do not get. It does not buy or skip shop abilities.

Reads `PlayerGui.Agaric2D` frames the client already drew, then overlays:

| Control | What it does |
| --- | --- |
| **Enabled** | Master draw toggle. |
| **Show mass** | Score on every other cell (dump: displayed score = mass / 10). |
| **Show names** | `NameLabel` text. |
| **Threat / prey rings** | Red if they can eat you (1.25× mass), green if you can eat them. |
| **Mark viruses** | `Spike` frames tagged POP / SAFE vs your size. |
| **My split reach** | Circle at ~6× your radius (split kill zone). |
| **My merge timer** | After you split, countdown using `GetMergeDelay` (2–6s). `CAN MERGE` when the wait is over. |
| **Auto-feed (W)** | Taps W at the chosen Hz. Same key everyone has; Photon just hits it faster and steadier. |

Photon still cannot move cells on the server or grant Merge/Speed. Tickrate + this overlay are the real unpaid edge.

## Instant Merge (`instant_merge.lua`)

Agaric merge is server-side. Photon cannot `FireServer`, so this script presses the same hotbar slot the game uses for the Merge ability (`Input_Action("Merge")`).

**You need the Merge ability equipped** in slot 1–10.

| Control | What it does |
| --- | --- |
| **Enabled** | While split (2+ of your `PlayerBlob`s), tap Merge at the chosen rate. |
| **Click HUD instead of key** | Clicks the slot button instead of simulating `1`–`0`. |
| **Merge slot** | `Auto` finds the Merge image (`105142089333769`). Or pick Slot 1–10. |
| **Tap rate** | Taps per second while split and off cooldown. |
| **Merge now** | One-shot tap (button, or the keybind, default **G**). |

Status line shows the resolved slot, your cell count, the natural recombine estimate (`2`–`6`s from `GetMergeDelay`), and `AbilityCooldown_Merge` if present.

Place notes: `docs/agaric-merge.md`

## Photon API used

```lua
get_tickrate()          -- float, workspace tickrate
set_tickrate(value)     -- void

gui.create(name, force_open)
menu:set_pos(x, y)
menu:set_size(x, y)
menu:add_label(text)
menu:add_checkbox(name, initial)
menu:add_slider(name, min, max, initial)
menu:add_combo(name, options, initial_index)
menu:add_button(name, callback)
struct:change_callback(fn)
struct:get_value()
struct:get_text()
ui.setvalue(menu, label, value)

log.add(message, color)
log.notification(message, type)
get_tickcount()
get_unixtime()
menu_active()
is_gamefocused()

input.simulate_press(vk)
input.simulate_mouse_click(MOUSE1)
input.get_mouse_position()
input.set_mouse_position(vector2)

hook.add("render", id, fn)
render.add_circle / add_ngon / add_text

instance:isvalid()
instance:get_children() / get_descendants()
instance:get_attribute(name, attribute_type)
instance.gui_position / gui_size
```
