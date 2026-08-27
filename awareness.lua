-- Agaric ESP for Photon
-- Open this window even when the Photon menu is closed (force_open).
-- Draws a watermark immediately so you can tell the render hook is alive.

local MENU = "Agaric ESP"
local VK_W = 0x57
local SCAN_CAP = 800

pcall(function()
    gui.remove(MENU)
end)
pcall(function()
    hook.remove("render", "agaric_esp")
end)

local function ok(inst)
    if inst == nil then
        return false
    end
    local pass, alive = pcall(function()
        return inst:isvalid()
    end)
    return pass and alive == true
end

local function child(parent, name)
    if not ok(parent) then
        return nil
    end
    local pass, inst = pcall(function()
        return parent:find_first_child(name)
    end)
    if pass and ok(inst) then
        return inst
    end
    return nil
end

local function desc(parent, name)
    if not ok(parent) then
        return nil
    end
    local pass, inst = pcall(function()
        return parent:find_first_descendant(name)
    end)
    if pass and ok(inst) then
        return inst
    end
    return nil
end

local function text_of(inst)
    if not ok(inst) then
        return nil
    end
    local pass, t = pcall(function()
        return inst:get_label_text()
    end)
    if pass and t ~= nil and t ~= "" then
        return tostring(t)
    end
    return nil
end

local function digits(s)
    if s == nil then
        return nil
    end
    local out = ""
    local str = tostring(s)
    local i = 1
    while i <= #str do
        local ch = str:sub(i, i)
        if (ch >= "0" and ch <= "9") or ch == "." then
            out = out .. ch
        elseif out ~= "" then
            break
        end
        i = i + 1
    end
    if out == "" then
        return nil
    end
    return tonumber(out)
end

local function has(hay, needle)
    if hay == nil or needle == nil then
        return false
    end
    hay = tostring(hay)
    needle = tostring(needle)
    local n = #needle
    if n == 0 then
        return true
    end
    local i = 1
    while i + n - 1 <= #hay do
        if hay:sub(i, i + n - 1) == needle then
            return true
        end
        i = i + 1
    end
    return false
end

local function geom(inst)
    local pass, pos, size = pcall(function()
        return inst.gui_position, inst.gui_size
    end)
    if not pass or pos == nil or size == nil then
        return nil
    end
    local w, h = pos.x, pos.y
    -- size may be vector2
    local sx, sy = size.x, size.y
    if sx == nil or sy == nil or sx < 8 or sy < 8 then
        return nil
    end
    return pos.x + sx * 0.5, pos.y + sy * 0.5, (sx < sy and sx or sy) * 0.5
end

local function round_or(n)
    if type(n) ~= "number" then
        return 0
    end
    return math.floor(n + 0.5)
end

local last_err = "ok"
local found_gui = false
local blob_n = 0
local spike_n = 0
local own_n = 0
local last_feed = 0

local menu = gui.create(MENU, true)
menu:set_pos(40, 40)
menu:set_size(320, 220)

local status = menu:add_label("booting")
local enabled = menu:add_checkbox("Draw overlay", true)
local auto_feed = menu:add_checkbox("Auto-feed W", false)

status:set_label("window ok — open Photon log if overlay is missing")

local function lp()
    local players = game:get_service("Players")
    if not ok(players) then
        return nil
    end
    local p = players.local_player
    if ok(p) then
        return p
    end
    return nil
end

local function pgui()
    local p = lp()
    if not p then
        return nil
    end
    local g = child(p, "PlayerGui")
    if g then
        return g
    end
    local pass, cls = pcall(function()
        return p:find_first_child_class("PlayerGui")
    end)
    if pass and ok(cls) then
        return cls
    end
    return nil
end

local function mine(blob, player)
    if not player then
        return false
    end
    local uid = tostring(player.userid)
    local owner = nil
    pcall(function()
        owner = blob:get_attribute("OwnerUid", 6)
    end)
    if owner ~= nil and tostring(owner) == uid then
        return true
    end
    local name = text_of(child(blob, "NameLabel"))
    if name == nil then
        return false
    end
    if has(name, player.name) then
        return true
    end
    if player.display_name ~= nil and has(name, player.display_name) then
        return true
    end
    return false
end

hook.add("render", "agaric_esp", function()
    local pass, err = pcall(function()
        local screen = get_screen_size()
        if enabled:get_value() then
            render.add_text(vector2(12, 12), "agaric esp on", color(0.4, 1, 0.6, 1), 14, true)
        end

        if not enabled:get_value() then
            status:set_label("overlay off")
            return
        end

        local pg = pgui()
        if not pg then
            found_gui = false
            status:set_label("no PlayerGui yet")
            return
        end

        local root = child(pg, "Agaric2D")
        if not root then
            root = desc(pg, "Agaric2D")
        end
        if not root then
            found_gui = false
            status:set_label("PlayerGui ok, Agaric2D missing (spawn in)")
            return
        end
        found_gui = true

        local canvas = desc(root, "Canvas")
        if not canvas then
            canvas = root
        end

        local list = nil
        pcall(function()
            list = canvas:get_descendants()
        end)
        if type(list) ~= "table" then
            status:set_label("Agaric2D found, get_descendants failed")
            return
        end

        local player = lp()
        blob_n = 0
        spike_n = 0
        own_n = 0
        local scanned = 0
        local biggest = 0
        local mx, my, mr = 0, 0, 0

        for _, inst in pairs(list) do
            scanned = scanned + 1
            if scanned > SCAN_CAP then
                break
            end
            if ok(inst) then
                local nm = inst.name
                if nm == "Spike" or nm == "PlayerBlob" then
                    local x, y, r = geom(inst)
                    if x ~= nil then
                        if nm == "Spike" then
                            spike_n = spike_n + 1
                            render.add_circle(vector2(x, y), r, color(0.55, 0.85, 0.1, 0.95))
                        else
                            blob_n = blob_n + 1
                            local mass = digits(text_of(child(inst, "MassLabel")))
                            local is_own = mine(inst, player)
                            local col = color(1, 1, 1, 0.45)
                            if is_own then
                                own_n = own_n + 1
                                col = color(0.35, 0.8, 1, 0.95)
                                if mass ~= nil and mass >= biggest then
                                    biggest = mass
                                    mx, my, mr = x, y, r
                                end
                            elseif mass ~= nil and biggest > 0 then
                                if mass * 10 >= biggest * 10 * 1.25 then
                                    col = color(1, 0.2, 0.2, 0.95)
                                elseif biggest * 10 >= mass * 10 * 1.25 then
                                    col = color(0.2, 1, 0.35, 0.95)
                                end
                            end
                            render.add_circle(vector2(x, y), r, col)
                            if mass ~= nil then
                                render.add_text(vector2(x - 10, y + r + 2), tostring(mass), col, 12, true)
                            end
                        end
                    end
                end
            end
        end

        local line = "Agaric2D  blobs " .. tostring(blob_n) .. "  yours " .. tostring(own_n) .. "  spikes " .. tostring(spike_n)
        if screen ~= nil then
            line = line .. "  scr " .. tostring(round_or(screen.x)) .. "x" .. tostring(round_or(screen.y))
        end
        status:set_label(line)
        last_err = "ok"

        if auto_feed:get_value() then
            local now = get_tickcount()
            local focused = true
            pcall(function()
                focused = is_gamefocused() and not menu_active()
            end)
            if focused and now - last_feed > 80 then
                input.simulate_press(VK_W)
                last_feed = now
            end
        end
    end)

    if not pass then
        last_err = tostring(err)
        pcall(function()
            status:set_label("error: " .. last_err)
            render.add_text(vector2(12, 28), last_err, color(1, 0.3, 0.3, 1), 13, true)
        end)
    end
end)

log.add("Agaric ESP: window is force-open. You should see 'agaric esp on' at the top-left.", color(0.4, 0.8, 1, 1))
log.notification("Agaric ESP loaded", "success")
