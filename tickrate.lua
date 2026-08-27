-- Photon tickrate window
-- force_open so the window shows without opening the Photon menu.
-- Agaric will not move faster from this. The window exists so you can
-- confirm the script actually loaded.

local MENU = "Tickrate"

pcall(function()
    gui.remove(MENU)
end)
pcall(function()
    hook.remove("render", "tickrate_ui")
end)

local function round(n)
    if type(n) ~= "number" then
        return 0
    end
    return math.floor(n + 0.5)
end

local menu = gui.create(MENU, true)
menu:set_pos(40, 280)
menu:set_size(320, 210)

local status = menu:add_label("loaded")
local enabled = menu:add_checkbox("Apply", false)
local slider = menu:add_slider("Value", 30, 240, 60)

local function live()
    local fps, tr = nil, nil
    pcall(function()
        fps = get_fps()
    end)
    pcall(function()
        tr = get_tickrate()
    end)
    return fps, tr
end

local function apply(v)
    v = round(v)
    pcall(function()
        set_tickrate(v)
    end)
    pcall(function()
        set_fflag_value("TaskSchedulerTargetFps", v)
    end)
    pcall(function()
        set_fflag_value("DFIntTaskSchedulerTargetFps", v)
    end)
end

local function paint()
    local fps, tr = live()
    local line = "fps " .. tostring(round(fps)) .. "  heartbeat " .. tostring(tr)
    if enabled:get_value() then
        line = line .. "  apply " .. tostring(round(slider:get_value()))
    else
        line = line .. "  (off)"
    end
    status:set_label(line)
end

enabled:change_callback(function()
    if enabled:get_value() then
        apply(slider:get_value())
    end
    paint()
end)

slider:change_callback(function()
    if enabled:get_value() then
        apply(slider:get_value())
    end
    paint()
end)

menu:add_button("Apply once", function()
    apply(slider:get_value())
    paint()
    log.notification("set_tickrate / fflag wrote " .. tostring(round(slider:get_value())), "info")
end)

paint()
log.add("Tickrate window force-open. Agaric speed will not change; this only proves the script runs.", color(0.4, 0.8, 1, 1))
log.notification("Tickrate loaded", "success")

hook.add("render", "tickrate_ui", function()
    local pass, err = pcall(function()
        if enabled:get_value() then
            apply(slider:get_value())
        end
        paint()
        render.add_text(vector2(12, 48), "tickrate script on", color(0.8, 0.8, 0.3, 1), 13, true)
    end)
    if not pass then
        pcall(function()
            status:set_label("error: " .. tostring(err))
        end)
    end
end)
