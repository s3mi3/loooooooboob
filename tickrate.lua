-- Photon client FPS / tickrate
-- API: https://photon-4.gitbook.io/api
--
-- Agaric does not use Workspace physics. Photon's set_tickrate() only
-- changes Heartbeat, so it does nothing in this game.
--
-- The loop that actually runs Agaric (ClientPrediction, World_Move,
-- Input_Target) is RunService.RenderStepped, which follows the Roblox
-- TaskScheduler FPS cap: FFlag TaskSchedulerTargetFps.

local MENU_NAME = "Tickrate"
local DEFAULT_FPS = 60
local MIN_FPS = 30
local MAX_FPS = 360
local PRESETS = { "60", "90", "120", "144", "240", "360" }
local REAPPLY_MS = 400

local FPS_FLAGS = {
    "TaskSchedulerTargetFps",
    "DFIntTaskSchedulerTargetFps",
    "FIntTaskSchedulerTargetFps"
}

local LIMIT_FLAGS = {
    "TaskSchedulerLimitTargetFpsTo2402",
    "DFFlagTaskSchedulerLimitTargetFpsTo2402"
}

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
    return clamp(round(n), MIN_FPS, MAX_FPS)
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

local function flag_int(name)
    if type(get_fflag_value) ~= "function" then
        return nil
    end
    local v = get_fflag_value(name)
    if type(v) == "number" then
        return v
    end
    return nil
end

local function flag_bool(name)
    if type(get_fflag_bool) ~= "function" then
        return nil
    end
    return get_fflag_bool(name)
end

local found_fps_flag = nil
local found_limit_flag = nil
local original_fps = DEFAULT_FPS
local original_limit = nil

for i = 1, #FPS_FLAGS do
    local v = flag_int(FPS_FLAGS[i])
    if v ~= nil then
        found_fps_flag = FPS_FLAGS[i]
        original_fps = sanitize(v)
        break
    end
end

for i = 1, #LIMIT_FLAGS do
    local v = flag_bool(LIMIT_FLAGS[i])
    if v ~= nil then
        found_limit_flag = LIMIT_FLAGS[i]
        original_limit = v
        break
    end
end

local function write_fps(rate)
    local ok = false
    if type(set_fflag_value) == "function" then
        if found_fps_flag ~= nil then
            set_fflag_value(found_fps_flag, rate)
            ok = true
        else
            for i = 1, #FPS_FLAGS do
                pcall(function()
                    set_fflag_value(FPS_FLAGS[i], rate)
                end)
            end
            ok = true
        end
    end
    if type(set_fflag_bool) == "function" then
        local uncap = rate > 240
        if found_limit_flag ~= nil then
            set_fflag_bool(found_limit_flag, not uncap and original_limit or false)
        else
            for i = 1, #LIMIT_FLAGS do
                pcall(function()
                    set_fflag_bool(LIMIT_FLAGS[i], not uncap)
                end)
            end
        end
    end
    if type(set_tickrate) == "function" then
        pcall(function()
            set_tickrate(rate)
        end)
    end
    return ok
end

local function live_fps()
    if type(get_fps) == "function" then
        local fps = get_fps()
        if type(fps) == "number" then
            return round(fps)
        end
    end
    return nil
end

local menu = gui.create(MENU_NAME, false)
menu:set_pos(80, 80)
menu:set_size(360, 280)

local status = menu:add_label("")
local hint = menu:add_label("Agaric uses RenderStepped, not Workspace tickrate.")
local enabled = menu:add_checkbox("Enabled", false)
local slider = menu:add_slider("Client FPS cap", MIN_FPS, MAX_FPS, original_fps)
local presets = menu:add_combo("Preset", PRESETS, preset_index_for(original_fps) or 0)

local last_applied = original_fps
local last_notify_at = 0
local last_reapply = 0

local function read_slider()
    return sanitize(slider:get_value())
end

local function set_status(target, on)
    local live = live_fps()
    local line = "Target " .. tostring(target)
    if live ~= nil then
        line = line .. "  |  live FPS " .. tostring(live)
    end
    if found_fps_flag ~= nil then
        line = line .. "  |  " .. found_fps_flag
    else
        line = line .. "  |  writing all FPS flag names"
    end
    if not on then
        line = line .. "  (off)"
    end
    status:set_label(line)
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
    write_fps(rate)
    last_applied = rate
    set_status(rate, true)
    if not silent then
        notify("Client FPS cap " .. tostring(rate), "success")
    end
end

local function restore(silent)
    write_fps(original_fps)
    if found_limit_flag ~= nil and original_limit ~= nil and type(set_fflag_bool) == "function" then
        set_fflag_bool(found_limit_flag, original_limit)
    end
    set_status(original_fps, false)
    if not silent then
        notify("FPS cap restored to " .. tostring(original_fps), "info")
    end
end

local function sync_widgets(rate)
    ui.setvalue(MENU_NAME, "Client FPS cap", rate)
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
    ui.setvalue(MENU_NAME, "Client FPS cap", rate)
    if enabled:get_value() then
        apply(rate, false)
    end
end)

menu:add_button("Reset to 60", function()
    sync_widgets(DEFAULT_FPS)
    if enabled:get_value() then
        apply(DEFAULT_FPS, false)
    end
end)

menu:add_button("Restore original", function()
    sync_widgets(original_fps)
    if enabled:get_value() then
        apply(original_fps, false)
    else
        restore(false)
    end
end)

set_status(original_fps, false)
if found_fps_flag ~= nil then
    log.add("Tickrate: using FFlag " .. found_fps_flag .. " (workspace set_tickrate is a no-op in Agaric)", color(0.4, 0.8, 1, 1))
else
    log.add("Tickrate: no FPS FFlag found yet; will try all known names when enabled.", color(1, 0.8, 0.3, 1))
end

hook.add("render", "tickrate_reapply", function()
    local now = get_tickcount()
    if now - last_reapply < REAPPLY_MS then
        return
    end
    last_reapply = now
    if enabled:get_value() then
        write_fps(last_applied)
        set_status(last_applied, true)
    else
        set_status(original_fps, false)
    end
end)
