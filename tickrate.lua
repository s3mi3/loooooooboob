-- Photon client FPS cap
-- API: https://photon-4.gitbook.io/api
--
-- Agaric will not get faster from this. ClientPrediction uses RenderStepped
-- delta time and the server owns speed. Tickrate / FPS only changes how
-- often the client draws and sends input.
--
-- Photon's set_tickrate() is Workspace Heartbeat (no-op here).
-- Runtime FFlags often do not stick. Externals write TaskScheduler MaxFPS.

local MENU_NAME = "Tickrate"
local DEFAULT_FPS = 60
local MIN_FPS = 30
local MAX_FPS = 360
local PRESETS = { "60", "90", "120", "144", "240", "360" }
local REAPPLY_MS = 250

-- Pointer RVAs (module base + RVA). Stale across Roblox updates.
local TS_PTR_RVAS = {
    0x89E0618, -- jonah dumper version-17d504d2c9544583
    0x88B64C8, -- photon overlay / offsets site
    0x7B68F00,
    0x6829508
}

local FPS_OFFS = { 0xB0, 0x1B0, 0xA8, 0xC0, 0x108 }

local FPS_FLAGS = {
    "TaskSchedulerTargetFps",
    "DFIntTaskSchedulerTargetFps",
    "FIntTaskSchedulerTargetFps"
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

local function as_addr(v)
    if type(v) == "number" then
        return v
    end
    if v == nil then
        return nil
    end
    if type(v) == "table" or type(v) == "userdata" then
        if v.address ~= nil then
            local n = tonumber(v.address)
            if n then
                return n
            end
        end
        if v.identity ~= nil then
            local n = tonumber(v.identity)
            if n then
                return n
            end
        end
    end
    return tonumber(tostring(v))
end

local function looks_ptr(p)
    return type(p) == "number" and p > 0x10000 and p < 0x7FFFFFFFFFFF
end

local function read_ptr(addr)
    if type(memory) ~= "table" then
        return nil
    end
    if type(memory.read_pointer) == "function" then
        local ok, v = pcall(function()
            return memory.read_pointer(addr)
        end)
        if ok then
            return as_addr(v)
        end
    end
    if type(memory.read) == "function" and MEMORY_TYPE ~= nil then
        local ok, v = pcall(function()
            return memory.read(addr, MEMORY_TYPE.ptr)
        end)
        if ok then
            return as_addr(v)
        end
    end
    return nil
end

local function read_f64(addr)
    if type(memory) ~= "table" or type(memory.read) ~= "function" or MEMORY_TYPE == nil then
        return nil
    end
    local ok, v = pcall(function()
        return memory.read(addr, MEMORY_TYPE.double)
    end)
    if ok and type(v) == "number" then
        return v
    end
    return nil
end

local function write_f64(addr, value)
    if type(memory) ~= "table" or type(memory.write) ~= "function" or MEMORY_TYPE == nil then
        return false
    end
    local ok = pcall(function()
        memory.write(addr, MEMORY_TYPE.double, value)
    end)
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

local function module_base()
    if type(game_baseaddress) ~= "function" then
        return nil
    end
    local ok, v = pcall(game_baseaddress)
    if not ok then
        return nil
    end
    return as_addr(v)
end

-- hit = { ts, off, addr, kind }  kind = "fps" | "delay"
local hit = nil
local original_raw = nil

local function classify(raw)
    if type(raw) ~= "number" then
        return nil
    end
    if raw > 20 and raw < 1000 then
        return "fps"
    end
    if raw > 0.0005 and raw < 0.05 then
        return "delay"
    end
    return nil
end

local function discover()
    hit = nil
    original_raw = nil
    local base = module_base()
    if not looks_ptr(base) then
        return nil, "no module base"
    end
    for i = 1, #TS_PTR_RVAS do
        local ts = read_ptr(base + TS_PTR_RVAS[i])
        if looks_ptr(ts) then
            for j = 1, #FPS_OFFS do
                local addr = ts + FPS_OFFS[j]
                local raw = read_f64(addr)
                local kind = classify(raw)
                if kind ~= nil then
                    hit = {
                        ts = ts,
                        off = FPS_OFFS[j],
                        addr = addr,
                        kind = kind,
                        rva = TS_PTR_RVAS[i]
                    }
                    original_raw = raw
                    return hit, nil
                end
            end
        end
    end
    return nil, "no TaskScheduler MaxFPS (Roblox update; RVA stale)"
end

local function raw_for_rate(rate, kind)
    if kind == "delay" then
        return 1 / rate
    end
    return rate
end

local function write_cap(rate)
    rate = sanitize(rate)
    local wrote_mem = false
    if hit ~= nil then
        wrote_mem = write_f64(hit.addr, raw_for_rate(rate, hit.kind))
    end
    if type(set_fflag_value) == "function" then
        for i = 1, #FPS_FLAGS do
            pcall(function()
                set_fflag_value(FPS_FLAGS[i], rate)
            end)
        end
    end
    if type(set_tickrate) == "function" then
        pcall(function()
            set_tickrate(rate)
        end)
    end
    return wrote_mem
end

local function restore_cap()
    if hit ~= nil and original_raw ~= nil then
        write_f64(hit.addr, original_raw)
    elseif hit ~= nil then
        write_f64(hit.addr, raw_for_rate(DEFAULT_FPS, hit.kind))
    end
    if type(set_fflag_value) == "function" then
        for i = 1, #FPS_FLAGS do
            pcall(function()
                set_fflag_value(FPS_FLAGS[i], DEFAULT_FPS)
            end)
        end
    end
    if type(set_tickrate) == "function" then
        pcall(function()
            set_tickrate(DEFAULT_FPS)
        end)
    end
end

local function probe_log()
    local base = module_base()
    log.add("---- tickrate probe ----", color(0.4, 0.8, 1, 1))
    log.add("base=" .. tostring(base) .. "  liveFPS=" .. tostring(live_fps()) .. "  get_tickrate=" .. tostring(type(get_tickrate) == "function" and get_tickrate() or "n/a"), color(0.8, 0.8, 0.8, 1))
    for i = 1, #FPS_FLAGS do
        local v = nil
        if type(get_fflag_value) == "function" then
            v = get_fflag_value(FPS_FLAGS[i])
        end
        log.add("fflag " .. FPS_FLAGS[i] .. " = " .. tostring(v), color(0.8, 0.8, 0.8, 1))
    end
    if looks_ptr(base) then
        for i = 1, #TS_PTR_RVAS do
            local ts = read_ptr(base + TS_PTR_RVAS[i])
            local line = string.format("RVA 0x%X -> ts=%s", TS_PTR_RVAS[i], tostring(ts))
            if looks_ptr(ts) then
                for j = 1, #FPS_OFFS do
                    local raw = read_f64(ts + FPS_OFFS[j])
                    line = line .. string.format("  +0x%X=%s", FPS_OFFS[j], tostring(raw))
                end
            end
            log.add(line, color(0.8, 0.8, 0.8, 1))
        end
    end
    if hit ~= nil then
        log.add(string.format("using ts+0x%X kind=%s rva=0x%X raw=%s", hit.off, hit.kind, hit.rva, tostring(original_raw)), color(0.4, 1, 0.5, 1))
    else
        log.add("TaskScheduler MaxFPS not found. FPS unlock cannot write memory on this build.", color(1, 0.4, 0.4, 1))
    end
end

discover()

local menu = gui.create(MENU_NAME, false)
menu:set_pos(80, 80)
menu:set_size(380, 300)

local status = menu:add_label("")
local hint = menu:add_label("Will not speed Agaric. Server owns movement.")
local enabled = menu:add_checkbox("Enabled", false)
local slider = menu:add_slider("Client FPS cap", MIN_FPS, MAX_FPS, DEFAULT_FPS)
local presets = menu:add_combo("Preset", PRESETS, 0)

local last_applied = DEFAULT_FPS
local last_reapply = 0
local last_notify = 0

local function notify(msg, kind)
    local now = get_tickcount()
    if now - last_notify < 250 then
        return
    end
    last_notify = now
    log.notification(msg, kind or "info")
end

local function set_status(on)
    local live = live_fps()
    local line
    if hit == nil then
        line = "MaxFPS not found  |  live " .. tostring(live)
    else
        line = string.format("mem ts+0x%X %s  |  target %d  |  live %s", hit.off, hit.kind, last_applied, tostring(live))
    end
    if not on then
        line = line .. "  (off)"
    end
    status:set_label(line)
end

local function apply(rate, silent)
    rate = sanitize(rate)
    last_applied = rate
    if hit == nil then
        discover()
    end
    local ok = write_cap(rate)
    set_status(true)
    if not silent then
        if hit == nil then
            notify("No TaskScheduler MaxFPS on this Roblox build", "warning")
        elseif ok then
            notify("Wrote FPS cap " .. tostring(rate) .. " (will not speed Agaric)", "success")
        else
            notify("Memory write failed", "warning")
        end
    end
end

local function restore(silent)
    restore_cap()
    last_applied = DEFAULT_FPS
    set_status(false)
    if not silent then
        notify("FPS cap restored", "info")
    end
end

enabled:change_callback(function()
    if enabled:get_value() then
        apply(sanitize(slider:get_value()), false)
    else
        restore(false)
    end
end)

slider:change_callback(function()
    if enabled:get_value() then
        apply(sanitize(slider:get_value()), true)
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

menu:add_button("Probe (check Photon log)", function()
    discover()
    probe_log()
    set_status(enabled:get_value())
end)

menu:add_button("Reset to 60", function()
    ui.setvalue(MENU_NAME, "Client FPS cap", DEFAULT_FPS)
    ui.setvalue(MENU_NAME, "Preset", 0)
    if enabled:get_value() then
        apply(DEFAULT_FPS, false)
    end
end)

set_status(false)
probe_log()

hook.add("render", "tickrate_reapply", function()
    local now = get_tickcount()
    if now - last_reapply < REAPPLY_MS then
        return
    end
    last_reapply = now
    if enabled:get_value() then
        if hit == nil then
            discover()
        end
        write_cap(last_applied)
        set_status(true)
    else
        set_status(false)
    end
end)
