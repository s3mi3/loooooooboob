-- Agaric ESP for Photon
-- Type your in-game blob nick (not the Roblox / Photon name).
-- Insert hides the panel. Merge cooldown stays on Photon's watermark
-- and as a large banner at the top of the screen.

local MENU = "ESP"
local SCAN_CAP = 900
local SCAN_MS = 80
local WIN_X, WIN_Y = 16, 16
local WIN_W, WIN_H = 340, 210
local BANNER_SIZE = 32
local ARROW_MAX = 6
local EAT_RATIO = 1.25

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

local function lower(s)
    if s == nil then
        return nil
    end
    s = tostring(s)
    if string and string.lower then
        return string.lower(s)
    end
    return s
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

-- Do not walk into PlayerBlob/Spike (labels) or tiny food frames.
local function walk_entities(root, fn)
    local n = 0
    local function rec(inst, depth)
        if n >= SCAN_CAP or depth > 8 or not ok(inst) then
            return
        end
        local nm = inst.name
        if nm == "PlayerBlob" or nm == "Spike" then
            n = n + 1
            fn(inst, nm)
            return
        end
        n = n + 1
        if nm ~= "Agaric2D" and nm ~= "Camera" and nm ~= "Canvas" then
            local pass, size = pcall(function()
                return inst.gui_size
            end)
            if pass and size ~= nil and size.x ~= nil and size.x < 8 and size.y ~= nil and size.y < 8 then
                return
            end
        end
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

local function blob_id(inst)
    local id = nil
    pcall(function()
        id = inst.identity
    end)
    if id ~= nil then
        return "i" .. tostring(id)
    end
    pcall(function()
        id = inst.address
    end)
    if id ~= nil then
        return "a" .. tostring(id)
    end
    return nil
end

local function owner_of(blob)
    local owner = nil
    pcall(function()
        owner = blob:get_attribute("OwnerUid", 6)
    end)
    if owner ~= nil and tostring(owner) ~= "" then
        return tostring(owner)
    end
    return nil
end

local function dist2(ax, ay, bx, by)
    local dx = ax - bx
    local dy = ay - by
    return dx * dx + dy * dy
end

local function offscreen(x, y, sw, sh)
    local edge = 40
    return x < edge or y < edge or x > sw - edge or y > sh - edge
end

local function edge_point(x, y, sw, sh)
    local pad_l, pad_r, pad_t, pad_b = 30, 30, 56, 30
    local cx = sw * 0.5
    local cy = sh * 0.5
    local dx = x - cx
    local dy = y - cy
    if dx == 0 and dy == 0 then
        return sw - pad_r, cy, 1, 0
    end
    local tx = 1e9
    local ty = 1e9
    if dx > 0.0001 then
        tx = (sw - pad_r - cx) / dx
    elseif dx < -0.0001 then
        tx = (pad_l - cx) / dx
    end
    if dy > 0.0001 then
        ty = (sh - pad_b - cy) / dy
    elseif dy < -0.0001 then
        ty = (pad_t - cy) / dy
    end
    local t = tx
    if ty < t then
        t = ty
    end
    if t < 0 then
        t = 0
    end
    return cx + dx * t, cy + dy * t, dx, dy
end

local function draw_threat_arrow(ax, ay, dx, dy, label, col)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.001 then
        dx, dy, len = 1, 0, 1
    end
    dx = dx / len
    dy = dy / len
    local px = -dy
    local py = dx
    local tip = vector2(ax + dx * 14, ay + dy * 14)
    local b1 = vector2(ax - dx * 9 + px * 8, ay - dy * 9 + py * 8)
    local b2 = vector2(ax - dx * 9 - px * 8, ay - dy * 9 - py * 8)
    pcall(function()
        render.add_triangle_filled(tip, b1, b2, col)
    end)
    pcall(function()
        render.add_triangle(tip, b1, b2, col, 2)
    end)
    local tx = ax - dx * 22 - #label * 4
    local ty = ay - dy * 22 - 8
    render.add_text(vector2(tx, ty), label, col, 16, true)
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
local watermark = "type nick"
local last_status = ""
local own_state = {}
local cached = {
    canvas = nil,
    blobs = {},
    spikes = {},
    scan_at = 0,
    canvas_at = 0
}

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
local function is_mine(label, owner, player, who)
    if who ~= nil then
        return label ~= nil and has(label, who)
    end
    if not player then
        return false
    end
    local uid = tostring(player.userid)
    if owner ~= nil and owner == uid then
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
    if text == last_status then
        return
    end
    last_status = text
    pcall(function()
        status:set_label(text)
    end)
end

local function pack_blob(inst)
    local namel = child(inst, "NameLabel")
    return {
        inst = inst,
        mass = child(inst, "MassLabel"),
        namel = namel,
        id = blob_id(inst),
        owner = owner_of(inst),
        label = text_of(namel),
        x = 0,
        y = 0,
        r = 12,
        score = nil
    }
end

local function find_canvas()
    local pg = pgui()
    if not pg then
        return nil
    end
    local root = child(pg, "Agaric2D")
    if not root then
        root = desc(pg, "Agaric2D")
    end
    if not root then
        return nil
    end
    local canvas = desc(root, "Canvas")
    if not canvas then
        canvas = child(root, "Camera")
    end
    if not canvas then
        canvas = root
    end
    return canvas
end

local function collect_direct(parent, blobs, spikes)
    if not ok(parent) then
        return
    end
    each(kids_of(parent), function(inst)
        local nm = inst.name
        if nm == "PlayerBlob" then
            blobs[#blobs + 1] = pack_blob(inst)
        elseif nm == "Spike" then
            spikes[#spikes + 1] = { inst = inst, x = 0, y = 0, r = 8 }
        elseif nm == "Canvas" or nm == "Camera" then
            collect_direct(inst, blobs, spikes)
        end
    end)
end

local function rescan(canvas)
    local blobs = {}
    local spikes = {}
    collect_direct(canvas, blobs, spikes)
    if #blobs == 0 and #spikes == 0 then
        walk_entities(canvas, function(inst, nm)
            if nm == "Spike" then
                spikes[#spikes + 1] = { inst = inst, x = 0, y = 0, r = 8 }
            else
                blobs[#blobs + 1] = pack_blob(inst)
            end
        end)
    end
    cached.blobs = blobs
    cached.spikes = spikes
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

local function track_own(curr, now)
    local ncurr = #curr
    if ncurr <= 1 then
        own_state = {}
        return curr
    end
    local used = {}
    local nxt = {}
    local i = 1
    while i <= ncurr do
        local c = curr[i]
        local bj = 0
        local best = nil
        local j = 1
        while j <= #own_state do
            if not used[j] then
                local p = own_state[j]
                local same = c.id ~= nil and p.id ~= nil and c.id == p.id
                local d = dist2(c.x, c.y, p.x, p.y)
                local lim = c.r * 5
                if lim < 140 then
                    lim = 140
                end
                if same or d < lim * lim then
                    local cost = d
                    if same then
                        cost = -1
                    end
                    if best == nil or cost < best then
                        best = cost
                        bj = j
                    end
                end
            end
            j = j + 1
        end
        local born = now
        local oldscore = nil
        local isnew = true
        if bj > 0 then
            used[bj] = true
            born = own_state[bj].born
            oldscore = own_state[bj].score
            isnew = false
        end
        nxt[i] = {
            x = c.x,
            y = c.y,
            r = c.r,
            score = c.score,
            id = c.id,
            born = born,
            oldscore = oldscore,
            isnew = isnew
        }
        i = i + 1
    end
    local anynew = false
    i = 1
    while i <= #nxt do
        if nxt[i].isnew then
            anynew = true
        end
        i = i + 1
    end
    if anynew then
        i = 1
        while i <= #nxt do
            local o = nxt[i]
            if not o.isnew and o.oldscore ~= nil and o.score ~= nil and o.score < o.oldscore * 0.72 then
                o.born = now
            end
            i = i + 1
        end
    end
    own_state = nxt
    return nxt
end

local function piece_left(piece, now)
    if piece == nil or piece.born == nil then
        return 0
    end
    local delay = merge_delay(piece.score)
    local left = delay - (now - piece.born) / 1000
    if left < 0 then
        return 0
    end
    return left
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
        local now = get_tickcount()
        local sw, sh = screen()

        if cached.canvas == nil or not ok(cached.canvas) or now - cached.canvas_at > 1000 then
            cached.canvas = find_canvas()
            cached.canvas_at = now
            cached.scan_at = 0
        end
        if cached.canvas ~= nil and now - cached.scan_at >= SCAN_MS then
            rescan(cached.canvas)
            cached.scan_at = now
        end

        local own = {}
        local biggest = 0
        local smallest = nil
        local spikes = {}
        local others = {}
        local counts = {}

        local si = 1
        while si <= #cached.spikes do
            local s = cached.spikes[si]
            local x, y, r = geom(s.inst)
            if x ~= nil then
                s.x, s.y, s.r = x, y, r
                spikes[#spikes + 1] = s
            elseif s.r > 0 and s.x ~= nil then
                spikes[#spikes + 1] = s
            end
            si = si + 1
        end

        local bi = 1
        while bi <= #cached.blobs do
            local e = cached.blobs[bi]
            local x, y, r = geom(e.inst)
            if x ~= nil then
                e.x, e.y, e.r = x, y, r
                e.ready = true
            end
            if e.ready == true then
                    e.score = digits(text_of(e.mass))
                    if is_mine(e.label, e.owner, player, who) then
                        own[#own + 1] = {
                            x = e.x,
                            y = e.y,
                            r = e.r,
                            score = e.score,
                            id = e.id
                        }
                        if e.score ~= nil and e.score > biggest then
                            biggest = e.score
                        end
                        if e.score ~= nil and (smallest == nil or e.score < smallest) then
                            smallest = e.score
                        end
                    else
                        local gk = nil
                        if e.label ~= nil then
                            gk = lower(e.label)
                        elseif e.owner ~= nil then
                            gk = "u" .. e.owner
                        end
                        if gk ~= nil then
                            if counts[gk] == nil then
                                counts[gk] = 0
                            end
                            counts[gk] = counts[gk] + 1
                        end
                        others[#others + 1] = {
                            x = e.x,
                            y = e.y,
                            r = e.r,
                            score = e.score,
                            gk = gk
                        }
                    end
                end
            bi = bi + 1
        end

        local tracked = track_own(own, now)
        local own_n = #own

        if esp_on then
            local i = 1
            while i <= #spikes do
                local s = spikes[i]
                render.add_circle(vector2(s.x, s.y), s.r, color(1, 0.08, 0.08, 1))
                i = i + 1
            end
            local count_on = {}
            i = 1
            while i <= #others do
                local c = others[i]
                if c.gk ~= nil and counts[c.gk] ~= nil and counts[c.gk] >= 2 then
                    local b = count_on[c.gk]
                    if b == nil then
                        count_on[c.gk] = i
                    else
                        local o = others[b]
                        local cs = c.score or 0
                        local os = o.score or 0
                        if cs > os or (cs == os and c.r > o.r) then
                            count_on[c.gk] = i
                        end
                    end
                end
                i = i + 1
            end
            i = 1
            while i <= #others do
                local c = others[i]
                local col = color(1, 1, 1, 0.4)
                if c.score ~= nil and biggest > 0 then
                    if c.score >= biggest * EAT_RATIO then
                        col = color(1, 0.22, 0.22, 0.95)
                    elseif biggest >= c.score * EAT_RATIO then
                        col = color(0.25, 1, 0.35, 0.95)
                    end
                end
                render.add_circle(vector2(c.x, c.y), c.r, col)
                if c.score ~= nil then
                    render.add_text(vector2(c.x - 10, c.y + c.r + 1), tostring(c.score), col, 12, true)
                end
                if c.gk ~= nil and count_on[c.gk] == i then
                    local tag = "x" .. tostring(counts[c.gk])
                    render.add_text(vector2(c.x - #tag * 5, c.y - c.r - 18), tag, color(1, 1, 1, 1), 16, true)
                end
                i = i + 1
            end
            i = 1
            local ox, oy, orad = nil, nil, nil
            while i <= own_n do
                local m = own[i]
                if ox == nil then
                    ox, oy, orad = m.x, m.y, m.r
                end
                if m.score ~= nil and m.score >= biggest then
                    ox, oy, orad = m.x, m.y, m.r
                end
                i = i + 1
            end
            if ox ~= nil then
                render.add_circle(vector2(ox, oy), orad, color(0.35, 0.85, 1, 0.95))
            end

            local prey = smallest
            if prey == nil or prey <= 0 then
                prey = biggest
            end
            local threats = {}
            i = 1
            while i <= #others do
                local c = others[i]
                if c.score ~= nil and prey ~= nil and prey > 0 and c.score >= prey * EAT_RATIO then
                    if offscreen(c.x, c.y, sw, sh) then
                        threats[#threats + 1] = c
                    end
                end
                i = i + 1
            end
            i = 1
            while i <= #threats do
                local j = i + 1
                while j <= #threats do
                    local a = threats[i].score or 0
                    local b = threats[j].score or 0
                    if b > a then
                        local tmp = threats[i]
                        threats[i] = threats[j]
                        threats[j] = tmp
                    end
                    j = j + 1
                end
                i = i + 1
            end
            local shown = {}
            i = 1
            local drawn = 0
            while i <= #threats and drawn < ARROW_MAX do
                local c = threats[i]
                local gk = c.gk or tostring(i)
                if shown[gk] == nil then
                    shown[gk] = true
                    local ax, ay, dx, dy = edge_point(c.x, c.y, sw, sh)
                    local label = tostring(c.score or "?")
                    local n = 0
                    if c.gk ~= nil and counts[c.gk] ~= nil then
                        n = counts[c.gk]
                    end
                    if n >= 2 then
                        label = label .. " x" .. tostring(n)
                    end
                    draw_threat_arrow(ax, ay, dx, dy, label, color(1, 0.2, 0.2, 1))
                    drawn = drawn + 1
                end
                i = i + 1
            end
        end

        local max_left = 0
        if own_n > 1 then
            local i = 1
            while i <= #tracked do
                local p = tracked[i]
                local left = piece_left(p, now)
                if left > max_left then
                    max_left = left
                end
                if left > 0 then
                    local t = fmt1(left) .. "s"
                    render.add_text(vector2(p.x - #t * 5, p.y - p.r - 20), t, color(1, 0.85, 0.3, 1), 16, true)
                end
                i = i + 1
            end
        end

        if own_n == 0 then
            if who == nil then
                set_status("type nick")
            else
                set_status("no cells")
            end
        elseif own_n == 1 then
            set_status("1 cell")
        elseif max_left > 0 then
            local banner = "MERGE " .. fmt1(max_left) .. "s"
            set_status(banner)
            draw_banner(banner, color(1, 0.82, 0.3, 1))
        else
            set_status("CAN MERGE")
            draw_banner("CAN MERGE", color(0.35, 1, 0.45, 1))
        end
    end)

    if not pass then
        pcall(function()
            render.add_text(vector2(12, 8), tostring(err), color(1, 0.3, 0.3, 1), 18, true)
        end)
    end
end)

log.add("ESP: per-piece merge, off-screen threats, cell count on others. Insert hides the panel.", color(0.4, 0.8, 1, 1))
log.notification("ESP loaded", "success")
