# Photon Lua API (tickrate + GUI)

Source: https://photon-4.gitbook.io/api

Photon Lua currently includes `math`, `table`, and `coroutine`.

## Workspace tickrate

From [game](https://photon-4.gitbook.io/api/documentation/roblox/game.md):

```lua
get_tickrate()           -- float, workspace tickrate
set_tickrate(value)      -- void

get_gravity()            -- float, workspace gravity
set_gravity(value)       -- void, normal gravity is 196.2
```

Example from the docs:

```lua
local current_tickrate = get_tickrate()
local current_gravity = get_gravity()
print(current_tickrate, current_gravity)

set_tickrate(120) -- 2 times faster, origin 60 fps
set_gravity(0)
```

## GUI

From [software/gui](https://photon-4.gitbook.io/api/documentation/software/gui.md):

```lua
gui.create(name, force_open) -> menu
gui.remove(name)

menu:set_pos(x, y)
menu:set_size(x, y)

menu:add_button(name, callback) -> button_struct
menu:add_textbox(name) -> textbox_struct
menu:add_slider(name, min, max, initial_value) -> slider_struct
menu:add_combo(name, options, initial_index) -> combo_struct
menu:add_multicombo(name, options, initial_selected) -> combo_struct
menu:add_checkbox(name, initial_value) -> checkbox_struct
menu:add_label(text) -> label_struct
menu:add_keybind(id, keycode) -> keybind_struct
menu:add_color(name, color) -> color_struct

struct:change_callback(callback)   -- every widget except button
struct:get_value()                 -- checkbox bool, slider float, combo int
struct:get_text()                  -- combo / textbox
struct:get_color()                 -- color widget
struct:get_state()                 -- keybind only
label:set_label(text)

ui.setvalue(menu, label, value)    -- slider float, checkbox bool, combo int, textbox string
ui.getvalue(menu, label)
```

## Log

From [software/log](https://photon-4.gitbook.io/api/documentation/software/log.md):

```lua
log.add(message, color)
print(...)
log.clear()
log.notification(message, type)    -- type: "info", "warning", "success"
```

## Render

Must be called from `hook.add("render", ...)`.

```lua
render.add_line(p1, p2, color, thickness)
render.add_circle(pos, radius, color)
render.add_circle_filled(pos, radius, color)
render.add_ngon(pos, radius, color, segments, thickness)
render.add_text(pos, text, color, size, outline)
```

## Input and hooks

```lua
input.simulate_press(vk)
input.simulate_press_down(vk)
input.simulate_press_up(vk)
input.simulate_mouse_click(MOUSE1)
input.get_mouse_position()
input.set_mouse_position(vector2)
hook.add(name, id, fn)
hook.remove(name, id)
menu_active()
is_gamefocused()
get_unixtime()
```

## Types

From [type](https://photon-4.gitbook.io/api/type.md):

```lua
color(r, g, b, a)    -- each channel 0-1
vector2(x, y)
vector3(x, y, z)
```
