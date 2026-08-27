-- Photon Agaric awareness overlay
-- API: https://photon-4.gitbook.io/api
--
-- Vanilla players do not get this. Photon reads Agaric2D GUI frames
-- (PlayerBlob / Spike) and draws mass, eat/threat, merge timer, and
-- optional auto-feed. No shop abilities and no FireServer.

local MENU_NAME = "Agaric ESP"
local SCAN_CAP = 900
local EAT_RATIO = 1.25
local SPLIT_REACH = 6.0
local VK_W = 0x57

local COL_THREAT = color(1, 0.2, 0.2, 0.95)
local COL_PREY = color(0.25, 1, 0.4, 0.95)
local COL_NEUTRAL = color(1, 1, 1, 0.35)
local COL_SELF = color(0.4, 0.8, 1, 0.9)
local COL_VIRUS = color(0.54, 0.81, 0.05, 0.95)
local COL_MERGE = color(1, 0.82, 0.35, 1)
local COL_READY = color(0.45, 1, 0.55, 1)

local function valid(inst)
    return inst ~= nil and type(inst.isvalid) == "function" and inst:isvalid()
end

local function child(parent, name)
    if not valid(parent) then
        return nil
    end
    local inst = parent:find_first_child(name)
    if valid(inst) then
        return inst
    end
    return nil
end

local function descendant(parent, name)
    if not valid(parent) then
        return nil
    end
    local inst = parent:find_first_descendant(name)
    if valid(inst) then
        return inst
    end
    return nil
end

local function contains(hay, needle)
    if hay == nil or needle == nil then
        return false
    end
    return string.find(tostring(hay), tostring(needle), 1, true) ~= nil
end

local function label_text(inst, name)
    local lab = child(inst, name)
    if not valid(lab) or type(lab.get_label_text) ~= "function" then
        return nil
    end
    local ok, text = pcall(function()
        return lab:get_label_text()
    end)
    if ok then
        return text
    end
    return nil
end

local function parse_mass(text)
    if text == nil then
        return nil
    end
    local n = tonumber(tostring(text):match("[%d%.]+"))
    if n == nil then
        return nil
    end
    return n * 10
end

local function player_gui()
    local players = game:get_service("Players")
    if not valid(players) then
        return nil
    end
    local lp = players.local_player
    if not valid(lp) then
        return nil
    end
    local pg = child(lp, "PlayerGui")
    if valid(pg) then
        return pg
    end
    pg = lp:find_first_child_class("PlayerGui")
    if valid(pg) then
        return pg
    end
    return nil
end

local function local_player()
    local players = game:get_service("Players")
    if not valid(players) then
        return nil
    end
    local lp = players.local_player
    if valid(lp) then
        return lp
    end
    return nil
end

local function agaric_root(pg)
    local root = child(pg, "Agaric2D")
    if valid(root) then
        return root
    end
    return descendant(pg, "Agaric2D")
end

local function geom(inst)
    if not valid(inst) then
        return nil
    end
    local pos = inst.gui_position
    local size = inst.gui_size
    if pos == nil or size == nil then
        return nil
    end
    local w = size.x
    local h = size.y
    if w < 6 or h < 6 then
        return nil
    end
    local cx = pos.x + w * 0.5
    local cy = pos.y + h * 0.5
    local r = w
    if h < r then
        r = h
    end
    r = r * 0.5
    return {
        x = cx,
        y = cy,
        r = r,
        pos = vector2(cx, cy)
    }
end

local function blob_owner(blob)
    local owner = nil
    pcall(function()
        owner = blob:get_attribute("OwnerUid", attribute_type.STRING)
    end)
    if owner ~= nil and owner ~= "" then
        return tostring(owner)
    end
    return nil
end

local function is_mine(blob, lp)
    if not valid(lp) then
        return false
    end
    local owner = blob_owner(blob)
    if owner ~= nil then
        return owner == tostring(lp.userid)
    end
    local name = label_text(blob, "NameLabel")
    if name == nil then
        return false
    end
    if contains(name, lp.name) then
        return true
    end
    if lp.display_name ~= nil and contains(name, lp.display_name) then
        return true
    end
    return false
end

local function natural_delay(mass)
    if mass == nil or mass <= 0 then
        return 2
    end
    local d = 1.96 + (mass * 0.00204)
    if d < 2 then
        d = 2
    end
    if d > 6 then
        d = 6
    end
    return d
end

local function fmt1(n)
    local i = math.floor(n * 10 + 0.5)
    local whole = math.floor(i / 10)
    local frac = i - whole * 10
    return tostring(whole) .. "." .. tostring(frac)
end

-- Menu
local menu = gui.create(MENU_NAME, false)
menu:set_pos(460, 80)
menu:set_size(340, 300)

local status = menu:add_label("Waiting for Agaric2D...")
local enabled = menu:add_checkbox("Enabled", true)
local show_mass = menu:add_checkbox("Show mass", true)
local show_names = menu:add_checkbox("Show names", false)
local show_threat = menu:add_checkbox("Threat / prey rings", true)
local show_virus = menu:add_checkbox("Mark viruses", true)
local show_reach = menu:add_checkbox("My split reach", true)
local show_merge = menu:add_checkbox("My merge timer", true)
local auto_feed = menu:add_checkbox("Auto-feed (W)", false)
local feed_hz = menu:add_slider("Feed rate (Hz)", 4, 20, 12)

local last_scan = 0
local cache = { cells = {}, viruses = {}, own = {}, own_count = 0, own_mass = 0, cx = 0, cy = 0, cr = 0 }
local last_own_count = 0
local split_at = 0
local last_feed = 0

local function scan()
    local pg = player_gui()
    local lp = local_player()
    local root = agaric_root(pg)
    local out = { cells = {}, viruses = {}, own = {}, own_count = 0, own_mass = 0, cx = 0, cy = 0, cr = 0 }
    if not valid(root) or not valid(lp) then
        return out
    end

    local canvas = descendant(root, "Canvas")
    if not valid(canvas) then
        canvas = root
    end
    local list = canvas:get_descendants()
    if type(list) ~= "table" then
        return out
    end

    local scanned = 0
    local ox, oy, om = 0, 0, 0
    for _, inst in pairs(list) do
        scanned = scanned + 1
        if scanned > SCAN_CAP then
            break
        end
        if valid(inst) then
            local g = geom(inst)
            if g ~= nil then
                if inst.name == "Spike" then
                    out.viruses[#out.viruses + 1] = g
                elseif inst.name == "PlayerBlob" then
                    local mass = parse_mass(label_text(inst, "MassLabel"))
                    local name = label_text(inst, "NameLabel")
                    local mine = is_mine(inst, lp)
                    local cell = {
                        x = g.x,
                        y = g.y,
                        r = g.r,
                        pos = g.pos,
                        mass = mass or 0,
                        name = name,
                        mine = mine
                    }
                    out.cells[#out.cells + 1] = cell
                    if mine then
                        out.own[#out.own + 1] = cell
                        out.own_count = out.own_count + 1
                        if cell.mass >= om then
                            om = cell.mass
                            out.own_mass = cell.mass
                            out.cx = cell.x
                            out.cy = cell.y
                            out.cr = cell.r
                        end
                        ox = ox + cell.x
                        oy = oy + cell.y
                    end
                end
            end
        end
    end

    if out.own_count > 1 then
        out.cx = ox / out.own_count
        out.cy = oy / out.own_count
    end
    return out
end

hook.add("render", "agaric_esp", function()
    if not enabled:get_value() then
        return
    end

    local now = get_tickcount()
    if now - last_scan >= 50 then
        cache = scan()
        last_scan = now
        if cache.own_count > last_own_count then
            split_at = now
        end
        last_own_count = cache.own_count
    end

    local me_mass = cache.own_mass
    local have_me = cache.own_count > 0

    if show_virus:get_value() then
        for i = 1, #cache.viruses do
            local v = cache.viruses[i]
            render.add_ngon(v.pos, v.r, COL_VIRUS, 8, 2)
            local tag = "VIRUS"
            if have_me and me_mass > 0 and v.r > 0 then
                -- spikes pop you if you are large; small cells are safe
                if cache.cr > v.r * 0.85 then
                    tag = "POP"
                else
                    tag = "SAFE"
                end
            end
            render.add_text(vector2(v.x - 16, v.y - v.r - 14), tag, COL_VIRUS, 12, true)
        end
    end

    for i = 1, #cache.cells do
        local c = cache.cells[i]
        if c.mine then
            render.add_circle(c.pos, c.r, COL_SELF)
        else
            local col = COL_NEUTRAL
            local tag = nil
            if show_threat:get_value() and have_me and me_mass > 0 and c.mass > 0 then
                if c.mass >= me_mass * EAT_RATIO then
                    col = COL_THREAT
                    tag = "EATS YOU"
                elseif me_mass >= c.mass * EAT_RATIO then
                    col = COL_PREY
                    tag = "EDIBLE"
                end
            end
            render.add_circle(c.pos, c.r + 1, col)
            local y = c.y + c.r + 2
            if show_names:get_value() and c.name ~= nil and c.name ~= "" then
                render.add_text(vector2(c.x - 20, y), tostring(c.name), col, 12, true)
                y = y + 12
            end
            if show_mass:get_value() and c.mass > 0 then
                render.add_text(vector2(c.x - 12, y), tostring(math.floor(c.mass / 10)), col, 13, true)
                y = y + 12
            end
            if tag ~= nil then
                render.add_text(vector2(c.x - 22, y), tag, col, 12, true)
            end
        end
    end

    if have_me and show_reach:get_value() and cache.cr > 0 then
        render.add_circle(vector2(cache.cx, cache.cy), cache.cr * SPLIT_REACH, color(1, 0.55, 0.15, 0.45))
    end

    local merge_txt = "1 cell"
    if show_merge:get_value() and cache.own_count > 1 then
        local delay = natural_delay(cache.own_mass)
        local elapsed = (now - split_at) / 1000
        local left = delay - elapsed
        local col = COL_MERGE
        if left <= 0 then
            merge_txt = "CAN MERGE"
            col = COL_READY
        else
            merge_txt = "MERGE " .. fmt1(left) .. "s"
        end
        render.add_text(vector2(cache.cx - 28, cache.cy - cache.cr - 18), merge_txt, col, 14, true)
    end

    local line = "cells " .. tostring(cache.own_count)
    if have_me then
        line = line .. "  |  mass " .. tostring(math.floor(me_mass / 10))
        line = line .. "  |  others " .. tostring(#cache.cells - cache.own_count)
    else
        line = "not in world (spawn first)"
    end
    if cache.own_count > 1 then
        line = line .. "  |  " .. merge_txt
    end
    status:set_label(line)

    if auto_feed:get_value() and is_gamefocused() and not menu_active() then
        local hz = feed_hz:get_value()
        if type(hz) ~= "number" or hz < 1 then
            hz = 8
        end
        if now - last_feed >= (1000 / hz) then
            input.simulate_press(VK_W)
            last_feed = now
        end
    end
end)

log.add("Agaric ESP loaded. This is Photon-only: mass/threat rings, merge timer, auto-feed.", color(0.4, 0.8, 1, 1))
log.notification("Agaric ESP ready", "info")
