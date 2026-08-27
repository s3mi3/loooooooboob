# Photon Agaric scripts

Photon Lua scripts for Agaric, using the [Photon API](https://photon-4.gitbook.io/api).

| Script | Window | What it does |
| --- | --- | --- |
| `tickrate.lua` | **Tickrate** | Slider / presets for `set_tickrate` |
| `instant_merge.lua` | **Instant Merge** | Auto-taps the equipped **Merge** ability when you are split |

## Load

1. Open Photon.
2. Drop the `.lua` file into your Photon scripts folder (or paste it into the Lua editor).
3. Run the script.
4. Open the Photon menu.

`tickrate.lua` and `instant_merge.lua` can run at the same time.

## Tickrate (`tickrate.lua`)

| Control | What it does |
| --- | --- |
| **Enabled** | When on, applies the slider/preset. When off, restores the tickrate captured at load. |
| **Tickrate** | Slider from `1` to `240`. Roblox default is `60`. |
| **Preset** | `30`, `60`, `90`, `120`, `240`. `120` is 2x the default. |
| **Reset to 60** | Sets the slider and tickrate back to default. |
| **Restore original** | Sets the slider and tickrate back to whatever `get_tickrate()` returned when the script loaded. |

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

instance:isvalid()
instance:get_children() / get_descendants()
instance:get_attribute(name, attribute_type)
instance.gui_position / gui_size
```
