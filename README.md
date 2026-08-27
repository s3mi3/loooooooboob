# Photon tickrate GUI

Simple Photon Lua script that exposes workspace tickrate on a menu.

Docs used: [Photon API](https://photon-4.gitbook.io/api)

## Load

1. Open Photon.
2. Drop `tickrate.lua` into your Photon scripts folder (or paste it into the Lua editor).
3. Run the script.
4. Open the Photon menu. A **Tickrate** window is created at `80, 80`.

## Controls

| Control | What it does |
| --- | --- |
| **Enabled** | When on, applies the slider/preset. When off, restores the tickrate captured at load. |
| **Tickrate** | Slider from `1` to `240`. Roblox default is `60`. |
| **Preset** | `30`, `60`, `90`, `120`, `240`. `120` is 2x the default. |
| **Reset to 60** | Sets the slider and tickrate back to default. |
| **Restore original** | Sets the slider and tickrate back to whatever `get_tickrate()` returned when the script loaded. |

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
```
