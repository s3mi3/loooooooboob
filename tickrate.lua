-- Photon tickrate GUI
-- API: https://photon-4.gitbook.io/api
--
-- get_tickrate() -> number     workspace tickrate (default 60)
-- set_tickrate(value)          120 = 2x, origin 60

local MENU_NAME = "Tickrate"
local DEFAULT_TICKRATE = 60
local MIN_TICKRATE = 1
local MAX_TICKRATE = 240
local PRESETS = { "30", "60", "90", "120", "240" }

if type(get_tickrate) ~= "function" or type(set_tickrate) ~= "function" then
    log.notification("Tickrate API is not available in this Photon build", "warning")
    return
end

local function round(n)
    return math.floor((n or 0) + 0.5)
end

local function clamp(n, lo, hi)
    if n < lo then
        return lo
    end
    if n > hi then
        return hi
    end
    return n
end

local function sanitize(n)
    return clamp(round(n), MIN_TICKRATE, MAX_TICKRATE)
end

local function preset_index_for(rate)
    local as_text = tostring(sanitize(rate))
    for i = 1, #PRESETS do
        if PRESETS[i] == as_text then
            return i - 1
        end
    end
    return nil
end

local original = sanitize(get_tickrate())
local last_applied = original
local last_notify_at = 0

local menu = gui.create(MENU_NAME, false)
menu:set_pos(80, 80)
menu:set_size(340, 250)

local status = menu:add_label("")
local enabled = menu:add_checkbox("Enabled", true)
local slider = menu:add_slider("Tickrate", MIN_TICKRATE, MAX_TICKRATE, original)
local presets = menu:add_combo("Preset", PRESETS, preset_index_for(original) or 1)

local function read_slider()
    return sanitize(slider:get_value())
end

local function set_status(rate, on)
    if on then
        status:set_label("Current: " .. tostring(rate) .. "  (default is 60)")
    else
        status:set_label("Current: " .. tostring(round(get_tickrate())) .. "  (disabled)")
    end
end

local function notify(message, kind)
    local now = get_tickcount()
    if now - last_notify_at < 250 then
        return
    end
    last_notify_at = now
    log.notification(message, kind or "info")
end

local function apply(rate, silent)
    rate = sanitize(rate)
    set_tickrate(rate)
    last_applied = round(get_tickrate())
    set_status(last_applied, true)
    if not silent then
        notify("Tickrate set to " .. tostring(last_applied), "success")
    end
end

local function restore(silent)
    set_tickrate(original)
    set_status(round(get_tickrate()), false)
    if not silent then
        notify("Tickrate restored to " .. tostring(original), "info")
    end
end

local function sync_widgets(rate)
    ui.setvalue(MENU_NAME, "Tickrate", rate)
    local idx = preset_index_for(rate)
    if idx ~= nil then
        ui.setvalue(MENU_NAME, "Preset", idx)
    end
end

enabled:change_callback(function()
    if enabled:get_value() then
        apply(read_slider(), false)
    else
        restore(false)
    end
end)

slider:change_callback(function()
    if enabled:get_value() then
        apply(read_slider(), true)
    end
end)

presets:change_callback(function()
    local rate = tonumber(presets:get_text())
    if not rate then
        return
    end
    ui.setvalue(MENU_NAME, "Tickrate", rate)
    if enabled:get_value() then
        apply(rate, false)
    end
end)

menu:add_button("Reset to 60", function()
    sync_widgets(DEFAULT_TICKRATE)
    if enabled:get_value() then
        apply(DEFAULT_TICKRATE, false)
    end
end)

menu:add_button("Restore original", function()
    sync_widgets(original)
    if enabled:get_value() then
        apply(original, false)
    else
        restore(false)
    end
end)

set_status(original, true)
log.add("Tickrate GUI loaded. Original rate: " .. tostring(original), color(0.4, 0.8, 1, 1))
