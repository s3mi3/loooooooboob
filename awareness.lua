-- Agaric ESP for Photon
-- Type your in-game blob nick (not the Roblox / Photon name).
-- Insert hides the panel. Merge cooldown stays on Photon's watermark
-- and as a large banner at the top of the screen.

local MENU = "ESP"
local SCAN_CAP = 800
local WIN_X, WIN_Y = 16, 16
local WIN_W, WIN_H = 340, 210
local BANNER_SIZE = 32
local MASS_SIZE = 18

pcall(function()
    gui.remove(MENU)
end)
pcall(function()
    hook.remove("render", "agaric_esp")
end)
pcall(function()
    hook.remove("append_watermark", "agaric_merge")
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
    if string and string.lower then
        hay = string.lower(hay)
        needle = string.lower(needle)
    end
    local n = #needle
    if n == 0 then
        return false
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
    local sx, sy = size.x, size.y
    if sx == nil or sy == nil or sx < 8 or sy < 8 then
        return nil
    end
    return pos.x + sx * 0.5, pos.y + sy * 0.5, (sx < sy and sx or sy) * 0.5
end

local function kids_of(inst)
    local list = nil
    pcall(function()
        list = inst:get_children()
    end)
    if list == nil then
        pcall(function()
            list = inst:GetChildren()
        end)
    end
    return list
end

local function each(list, fn)
    if list == nil then
        return
    end
    local n = 0
    pcall(function()
        n = #list
    end)
    if n > 0 then
        local i = 1
        while i <= n do
            fn(list[i])
            i = i + 1
        end
        return
    end
    local used = false
    pcall(function()
        for _, v in pairs(list) do
            used = true
            fn(v)
        end
    end)
    if used then
        return
    end
    local i = 0
    while i < 400 do
        local v = nil
        pcall(function()
            v = list[i]
        end)
        if v == nil then
            if i > 0 then
                break
            end
        else
            fn(v)
        end
        i = i + 1
    end
end

local function walk(root, fn)
    local n = 0
    local function rec(inst, depth)
        if n >= SCAN_CAP or depth > 14 or not ok(inst) then
            return
        end
        n = n + 1
        fn(inst)
        each(kids_of(inst), function(ch)
            rec(ch, depth + 1)
        end)
    end
    rec(root, 0)
    return n
end

local function merge_delay(score)
    local mass = (score or 0) * 10
    local d = 1.96 + mass * 0.00204
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
    local w = math.floor(i / 10)
    local f = i - w * 10
    return tostring(w) .. "." .. tostring(f)
end

local function screen()
    local sx, sy = 1920, 1080
    pcall(function()
        local s = get_screen_size()
        if s ~= nil and s.x ~= nil then
            sx, sy = s.x, s.y
        end
    end)
    return sx, sy
end

local menu = gui.create(MENU, true)
menu:set_pos(WIN_X, WIN_Y)
menu:set_size(WIN_W, WIN_H)

local namebox = menu:add_textbox("In-game name")
local enabled = menu:add_checkbox("ESP", true)
local hidebind = menu:add_keybind("Hide", 0x2D)
local status = menu:add_label("type blob nick, not Roblox name")

local hidden = false
local prev_hide = false
local last_own = 0
local split_at = 0
local watermark = "type nick"

hook.add("append_watermark", "agaric_merge", function()
    return watermark
end)

local function typed_name()
    local t = nil
    pcall(function()
        t = namebox:get_text()
    end)
    if t ~= nil then
        t = tostring(t)
        local i, j = 1, #t
        while i <= j and t:sub(i, i) == " " do
            i = i + 1
        end
        while j >= i and t:sub(j, j) == " " do
            j = j - 1
        end
        if j >= i then
            return t:sub(i, j)
        end
    end
    return nil
end

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

-- Typed nick is the blob NameLabel (e.g. "Superman zohan8"), not Photon/Roblox name.
-- OwnerUid is used only when the box is empty.
local function mine(blob, player, who)
    local label = text_of(child(blob, "NameLabel"))
    if who ~= nil then
        return label ~= nil and has(label, who)
    end
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
    return false
end

local function set_hidden(on)
    hidden = on
    if hidden then
        menu:set_pos(-800, -800)
        menu:set_size(1, 1)
    else
        menu:set_pos(WIN_X, WIN_Y)
        menu:set_size(WIN_W, WIN_H)
    end
end

local function set_status(text)
    watermark = text
    pcall(function()
        status:set_label(text)
    end)
end

local function draw_banner(text, col)
    local sw = screen()
    local tw = #text * BANNER_SIZE * 0.58
    local x = (sw - tw) * 0.5
    if x < 12 then
        x = 12
    end
    local y = 10
    pcall(function()
        render.add_rect_filled(
            vector2(x - 20, y - 6),
            vector2(x + tw + 20, y + BANNER_SIZE + 10),
            color(0, 0, 0, 0.7),
            8
        )
    end)
    render.add_text(vector2(x, y), text, col, BANNER_SIZE, true)
end

hook.add("render", "agaric_esp", function()
    local pass, err = pcall(function()
        local down = false
        pcall(function()
            down = hidebind:get_state()
        end)
        if down and not prev_hide then
            set_hidden(not hidden)
        end
        prev_hide = down

        local player = lp()
        local who = typed_name()
        local esp_on = enabled:get_value()
        local pg = pgui()
        local root = nil
        if pg then
            root = child(pg, "Agaric2D")
            if not root then
                root = desc(pg, "Agaric2D")
            end
        end

        local own = {}
        local biggest = 0
        local spikes = {}
        local others = {}

        if root then
            local canvas = desc(root, "Canvas")
            if not canvas then
                canvas = child(root, "Camera")
            end
            if not canvas then
                canvas = root
            end
            walk(canvas, function(inst)
                local nm = inst.name
                if nm ~= "Spike" and nm ~= "PlayerBlob" then
                    return
                end
                local x, y, r = geom(inst)
                if x == nil then
                    return
                end
                if nm == "Spike" then
                    spikes[#spikes + 1] = { x = x, y = y, r = r }
                    return
                end
                local score = digits(text_of(child(inst, "MassLabel")))
                if mine(inst, player, who) then
                    own[#own + 1] = { x = x, y = y, r = r, score = score }
                    if score ~= nil and score > biggest then
                        biggest = score
                    end
                else
                    others[#others + 1] = { x = x, y = y, r = r, score = score }
                end
            end)
        end

        local own_n = #own
        local now = get_tickcount()
        if own_n > last_own then
            split_at = now
        end
        if own_n <= 1 then
            split_at = 0
        end
        last_own = own_n

        if esp_on then
            local i = 1
            while i <= #spikes do
                local s = spikes[i]
                local pos = vector2(s.x, s.y)
                -- viruses: thick red rings (not green)
                render.add_ngon(pos, s.r, color(1, 0.08, 0.08, 1), 20, 5)
                render.add_ngon(pos, s.r + 6, color(1, 0.2, 0.12, 0.9), 20, 2)
                i = i + 1
            end
            i = 1
            while i <= #others do
                local c = others[i]
                local col = color(1, 1, 1, 0.45)
                if c.score ~= nil and biggest > 0 then
                    if c.score >= biggest * 1.25 then
                        col = color(1, 0.22, 0.22, 0.95)
                    elseif biggest >= c.score * 1.25 then
                        col = color(0.25, 1, 0.35, 0.95)
                    end
                end
                render.add_ngon(vector2(c.x, c.y), c.r, col, 24, 3)
                if c.score ~= nil then
                    local t = tostring(c.score)
                    render.add_text(vector2(c.x - #t * 5, c.y + c.r + 2), t, col, MASS_SIZE, true)
                end
                i = i + 1
            end
        end

        local i = 1
        while i <= own_n do
            local m = own[i]
            render.add_ngon(vector2(m.x, m.y), m.r + 4, color(0.2, 1, 0.4, 1), 28, 4)
            i = i + 1
        end

        local banner = "TYPE IN-GAME NAME"
        local col = color(1, 0.85, 0.35, 1)
        if own_n == 0 then
            if who == nil then
                banner = "TYPE IN-GAME NAME"
                set_status("type nick")
            else
                banner = "NO CELLS"
                col = color(1, 0.45, 0.35, 1)
                set_status("no cells")
            end
        elseif own_n == 1 then
            banner = "1 CELL"
            col = color(0.85, 0.85, 0.85, 1)
            set_status("1 cell")
        elseif split_at > 0 then
            local left = merge_delay(biggest) - (now - split_at) / 1000
            if left > 0 then
                banner = "MERGE " .. fmt1(left) .. "s"
                col = color(1, 0.82, 0.3, 1)
            else
                banner = "CAN MERGE"
                col = color(0.35, 1, 0.45, 1)
            end
            set_status(banner)
        else
            banner = tostring(own_n) .. " CELLS"
            col = color(0.7, 0.9, 1, 1)
            set_status(banner)
        end

        draw_banner(banner, col)
    end)

    if not pass then
        pcall(function()
            render.add_text(vector2(12, 8), tostring(err), color(1, 0.3, 0.3, 1), 18, true)
        end)
    end
end)

log.add("ESP: type your in-game nick. Insert hides the panel. Merge cooldown is on Photon's watermark and the top banner.", color(0.4, 0.8, 1, 1))
log.notification("ESP loaded", "success")
