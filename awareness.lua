-- Small Agaric ESP for Photon
-- Name box, ESP toggle, Insert hides the window. Merge cooldown stays on screen.

local MENU = "ESP"
local SCAN_CAP = 800
local WIN_X, WIN_Y = 16, 16
local WIN_W, WIN_H = 188, 92

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

local menu = gui.create(MENU, true)
menu:set_pos(WIN_X, WIN_Y)
menu:set_size(WIN_W, WIN_H)

local namebox = menu:add_textbox("Name")
local enabled = menu:add_checkbox("ESP", true)
local hidebind = menu:add_keybind("Hide", 0x2D)

local hidden = false
local prev_hide = false
local name_seeded = false
local last_own = 0
local split_at = 0

local function typed_name()
    local t = nil
    pcall(function()
        t = namebox:get_text()
    end)
    if t ~= nil then
        t = tostring(t)
        if t ~= "" then
            return t
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

local function mine(blob, player, who)
    local label = text_of(child(blob, "NameLabel"))
    if who ~= nil and label ~= nil and has(label, who) then
        return true
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
    if label == nil then
        return false
    end
    if has(label, player.name) then
        return true
    end
    if player.display_name ~= nil and has(label, player.display_name) then
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

local function draw_merge(text, col, x, y)
    local sx, sy = 40, 8
    pcall(function()
        local s = get_screen_size()
        sx = s.x * 0.5 - 36
        sy = 10
    end)
    render.add_text(vector2(sx, sy), text, col, 18, true)
    if x ~= nil then
        render.add_text(vector2(x - 28, y - 22), text, col, 14, true)
    end
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
        if not name_seeded and player ~= nil then
            local seed = player.name
            if seed == nil or seed == "" then
                seed = player.display_name
            end
            if seed ~= nil and seed ~= "" then
                pcall(function()
                    ui.setvalue(MENU, "Name", tostring(seed))
                end)
                name_seeded = true
            end
        end

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

        local own_n = 0
        local biggest = 0
        local ox, oy, orad = nil, nil, nil
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
                    own_n = own_n + 1
                    if score ~= nil and score >= biggest then
                        biggest = score
                        ox, oy, orad = x, y, r
                    elseif ox == nil then
                        ox, oy, orad = x, y, r
                    end
                else
                    others[#others + 1] = { x = x, y = y, r = r, score = score }
                end
            end)
        end

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
                render.add_circle(vector2(s.x, s.y), s.r, color(0.55, 0.85, 0.1, 0.9))
                i = i + 1
            end
            i = 1
            while i <= #others do
                local c = others[i]
                local col = color(1, 1, 1, 0.4)
                if c.score ~= nil and biggest > 0 then
                    if c.score >= biggest * 1.25 then
                        col = color(1, 0.22, 0.22, 0.95)
                    elseif biggest >= c.score * 1.25 then
                        col = color(0.25, 1, 0.35, 0.95)
                    end
                end
                render.add_circle(vector2(c.x, c.y), c.r, col)
                if c.score ~= nil then
                    render.add_text(vector2(c.x - 10, c.y + c.r + 1), tostring(c.score), col, 12, true)
                end
                i = i + 1
            end
            if ox ~= nil then
                render.add_circle(vector2(ox, oy), orad, color(0.35, 0.85, 1, 0.95))
            end
        end

        if own_n > 1 and split_at > 0 then
            local delay = merge_delay(biggest)
            local left = delay - (now - split_at) / 1000
            local col = color(1, 0.82, 0.35, 1)
            local text = "CAN MERGE"
            if left > 0 then
                text = "MERGE " .. fmt1(left) .. "s"
            else
                col = color(0.4, 1, 0.5, 1)
            end
            draw_merge(text, col, ox, oy)
        end
    end)

    if not pass then
        pcall(function()
            render.add_text(vector2(12, 8), tostring(err), color(1, 0.3, 0.3, 1), 13, true)
        end)
    end
end)

log.add("ESP: type your in-game name. Insert hides the window. Merge timer stays on screen.", color(0.4, 0.8, 1, 1))
log.notification("ESP loaded", "success")
