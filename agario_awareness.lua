--=====================================================================
--  Agar.io-style Awareness / ESP  —  Project Vector Lua Engine
--  API: https://projectvector.cc/lua
--=====================================================================
--
--  Features
--  --------
--   * Distance indicators  — a line from your cell to every other cell,
--                            with the distance shown as text.
--   * Threat indicators    — cells big enough to eat you are highlighted
--                            (uses the game's real 1.25x mass eat rule).
--   * Virus indicators     — viruses are drawn as bright spiky stars so
--                            they are impossible to miss, tagged DANGER
--                            when you're big enough for one to pop you.
--   * Split-range circles   — a ring showing how far a cell could reach if
--                            it split (their kill zone), and optionally
--                            your own split reach.
--
--  Everything is toggleable / tunable live from the "AgarESP" menu tab.
--
--  ------------------------------------------------------------------
--  HOW IT WORKS  (important — this was tuned to a real game file)
--  ------------------------------------------------------------------
--  The reference game ("Agar2D") is a *2D* Roblox game: cells are NOT
--  3D parts, they are circular GUI Frames drawn into a ScreenGui. So the
--  script reads those on-screen circles directly:
--
--      PlayerGui > Agar2DScreen > Root > World > (circle Frames)
--
--  Each cell circle is a Frame whose:
--    * Position offset  = its centre on screen (px)        [AnchorPoint .5]
--    * Size offset      = its diameter on screen (px)
--    * BackgroundColor3 = its colour  (viruses = 138,207,0)
--    * child LabelStack.ScoreLabel.Text = its exact mass
--    * child LabelStack.NameLabel.Text  = the player's name
--
--  From mass we recover the world scale (radius = 0.632*sqrt(mass)) which
--  lets distances/rings be shown in real studs and the split reach be the
--  game-accurate  0.632*sqrt(mass) + 700*clamp((10000/mass)^0.28,.22,1)/1.9.
--
--  MODE (menu -> General -> Mode)
--    Auto      - use 2D GUI mode if the ScreenGui is found, else 3D. Default.
--    2D GUI    - force the GUI-circle reader described above.
--    3D parts  - fallback for a 3D Agar game: reads entity.GetPlayers()
--                and Workspace parts via draw.WorldToScreen.
--
--  If your game differs, the tunables (ScreenGui name, virus colour, eat
--  ratio, split constants) are all in the menu, and Debug -> "Dump GUI"
--  prints the circle tree + a raw Position/Size sample to the console so
--  you can see exactly what your build looks like.
--
--  All colours are normalised RGBA {r,g,b,a} in the 0..1 range.
--=====================================================================


--=====================================================================
-- CONFIG  (game-derived constants; safe to edit)
--=====================================================================
local CFG = {
    -- Where the 2D cells live.  Path is walked from PlayerGui.
    gui_screen   = "Agar2DScreen",
    gui_path     = { "Root", "World" },   -- container that holds cell frames

    -- Cell size math:  radius(studs) = RADIUS_SCALE * sqrt(mass)
    radius_scale = 0.632,

    -- Split physics (from the game's Config/GameService):
    --   splitImpulse = SPLIT_IMPULSE * clamp((INITIAL_MASS/mass)^EXP, MINSCALE, 1)
    --   reach(studs) = radius + splitImpulse / BOOST_DECAY
    split_impulse    = 700.0,
    split_exp        = 0.28,
    split_min_scale  = 0.22,
    initial_mass     = 10000.0,
    boost_decay      = 1.9,

    -- A circle counts as a virus if its colour is within this distance of
    -- the virus colour (per channel, 0..1).
    virus_color      = { 138 / 255, 207 / 255, 0 / 255 },
    virus_tolerance  = 0.16,

    -- On-screen diameter (px) below which a circle is treated as
    -- food/ejected/coin and ignored.
    min_cell_px      = 10.0,

    -- Safety cap on how many GUI circles we inspect per frame.
    scan_cap         = 600,

    -- 3D fallback: fallback radius (studs) when a cell's size can't be read.
    default_radius_3d = 5.0,
    scan_interval_ms  = 600,
    scan_result_cap   = 400,

    -- Star used to draw viruses.
    virus_star_points = 12,
    virus_star_inner  = 0.55,
}


--=====================================================================
-- MENU
--=====================================================================
menu.AddTab("AgarESP", "A")

-- ----- General -----------------------------------------------------
menu.AddGroup("AgarESP", "General")
menu.AddCheckbox("AgarESP", "General", "enabled", "Enabled", true, { key = 0x2D }) -- INSERT
menu.AddCombo("AgarESP", "General", "mode", "Mode", { "Auto", "2D GUI", "3D parts" }, 0)
menu.AddInput("AgarESP", "General", "own_name", "Your name (blank = auto)", "")
menu.AddCombo("AgarESP", "General", "dist_unit", "Distance unit", { "Studs", "Pixels" }, 0)

-- ----- Distance ----------------------------------------------------
menu.AddGroup("AgarESP", "Distance")
menu.AddCheckbox("AgarESP", "Distance", "dist_lines", "Lines to cells", true)
menu.AddCheckbox("AgarESP", "Distance", "dist_text",  "Distance numbers", true)
menu.AddCheckbox("AgarESP", "Distance", "mass_text",  "Show mass", false)
menu.AddColorpicker("AgarESP", "Distance", "col_line", "Line colour", { 1, 1, 1, 0.35 })

-- ----- Threat ------------------------------------------------------
menu.AddGroup("AgarESP", "Threat")
menu.AddCheckbox("AgarESP", "Threat", "threat_on", "Highlight threats", true)
menu.AddCheckbox("AgarESP", "Threat", "threat_only", "Only draw threats", false)
menu.AddCheckbox("AgarESP", "Threat", "threat_ring", "Ring around threats", true)
-- MASS ratio needed to eat (game default = 125%). Converted to a radius ratio.
menu.AddSliderInt("AgarESP", "Threat", "eat_ratio", "Eat mass ratio", 100, 200, 125, "%d%%")
menu.AddColorpicker("AgarESP", "Threat", "col_threat", "Threat colour", { 1, 0.15, 0.15, 1 })
menu.AddColorpicker("AgarESP", "Threat", "col_prey",   "Edible colour",  { 0.3, 1, 0.4, 1 })

-- ----- Virus -------------------------------------------------------
menu.AddGroup("AgarESP", "Virus")
menu.AddCheckbox("AgarESP", "Virus", "virus_on", "Show viruses", true)
menu.AddCheckbox("AgarESP", "Virus", "virus_tag", "DANGER / SAFE tag", true)
menu.AddColorpicker("AgarESP", "Virus", "col_virus", "Virus colour", { 0.54, 0.81, 0, 1 })

-- ----- Split range -------------------------------------------------
menu.AddGroup("AgarESP", "Split range")
menu.AddCheckbox("AgarESP", "Split range", "split_self",    "My split reach", true)
menu.AddCheckbox("AgarESP", "Split range", "split_threats", "Threat split reach", true)
-- Scales the game-accurate reach in case your build's physics differ.
menu.AddSliderFloat("AgarESP", "Split range", "split_scale", "Reach scale", 0.25, 3.0, 1.0, "%.2f")
menu.AddColorpicker("AgarESP", "Split range", "col_split", "Reach colour", { 1, 0.55, 0.1, 0.5 })

-- ----- Debug -------------------------------------------------------
menu.AddGroup("AgarESP", "Debug")
menu.AddButton("AgarESP", "Debug", "dump_gui", "Dump GUI", function()
    local root = _G.__agaresp_world
    if not root or not utility.IsValid(root) then
        print("[AgarESP] World container not found. Current mode is not 2D or ScreenGui name is wrong.")
        print("[AgarESP] Looking for PlayerGui -> " .. CFG.gui_screen .. " -> " .. table.concat(CFG.gui_path, " -> "))
        return
    end
    local kids = root:GetChildren()
    print(("[AgarESP] World has %d children. Sample (first 12):"):format(#kids))
    for i = 1, math.min(#kids, 12) do
        local f = kids[i]
        local okp, p = pcall(function() return f.Position end)
        local oks, s = pcall(function() return f.Size end)
        print(("  %-14s vis=%s pos=%s size=%s"):format(
            tostring(f.Name), tostring(f.Visible), tostring(okp and p), tostring(oks and s)))
    end
end)


--=====================================================================
-- SMALL HELPERS
--=====================================================================

-- Read a colour component from {R,G,B}/{r,g,b} keyed OR [1..3] indexed.
local function comp(col, key1, key2, idx)
    if col == nil then return 0 end
    local v = col[key1]
    if v == nil then v = col[key2] end
    if v == nil then v = col[idx] end
    return v or 0
end

-- Extract offset X/Y (and, if present, screen X/Y) from a UDim2-ish table.
-- Handles {sx,ox,sy,oy}, {X={Scale,Offset},Y=..}, {x={scale,offset},..}.
local function udim2_offsets(t)
    if type(t) ~= "table" then return nil end
    -- Flat array {scaleX, offsetX, scaleY, offsetY}
    if type(t[2]) == "number" and type(t[4]) == "number" then
        return t[2], t[4]
    end
    local X = t.X or t.x
    local Y = t.Y or t.y
    if type(X) == "table" and type(Y) == "table" then
        local ox = X.Offset or X.offset or X[2]
        local oy = Y.Offset or Y.offset or Y[2]
        if ox and oy then return ox, oy end
    end
    return nil
end

-- Return centre (cx,cy) and diameter (d) of a circle Frame, in screen px.
-- Tries AbsolutePosition/AbsoluteSize first, then Position/Size offsets.
local function circle_geom(frame)
    local okA, ap = pcall(function() return frame.AbsolutePosition end)
    local okB, asz = pcall(function() return frame.AbsoluteSize end)
    if okA and okB and type(ap) == "table" and type(asz) == "table" then
        local ax = ap.X or ap.x or ap[1]
        local ay = ap.Y or ap.y or ap[2]
        local aw = asz.X or asz.x or asz[1]
        local ah = asz.Y or asz.y or asz[2]
        if ax and aw then
            return ax + aw * 0.5, ay + ah * 0.5, math.max(aw, ah)
        end
    end
    -- UDim2 fallback (World is fullscreen from 0,0 so offset == screen px).
    local okP, pos = pcall(function() return frame.Position end)
    local okS, size = pcall(function() return frame.Size end)
    if okP and okS then
        local px, py = udim2_offsets(pos)
        local sw, sh = udim2_offsets(size)
        if px and sw then
            -- AnchorPoint is 0.5, so the position offset IS the centre.
            return px, py, math.max(sw, sh)
        end
    end
    return nil
end

local function child_text(frame, stack, label)
    local ok, txt = pcall(function()
        local ls = frame:FindFirstChild(stack)
        if not ls then return nil end
        local l = ls:FindFirstChild(label)
        if not l then return nil end
        return l.Text
    end)
    if ok then return txt end
    return nil
end

local function draw_star(cx, cy, r_out, col, thick)
    local pts = {}
    local n = CFG.virus_star_points * 2
    local r_in = r_out * CFG.virus_star_inner
    for i = 0, n - 1 do
        local ang = (i / n) * math.pi * 2.0 - math.pi * 0.5
        local rr = (i % 2 == 0) and r_out or r_in
        pts[#pts + 1] = { cx + math.cos(ang) * rr, cy + math.sin(ang) * rr }
    end
    draw.PolyClosed(pts, col, thick or 2.0)
end

local function text_centered(cx, y, str, col, size)
    local tw = draw.GetTextSize(str, size)
    draw.Text(cx - tw * 0.5, y, str, col, size)
end

local function mass_to_radius(mass)
    return CFG.radius_scale * math.sqrt(math.max(mass, 1))
end

-- Game-accurate split reach in studs for a cell of the given mass.
local function split_reach_studs(mass)
    local scale = (CFG.initial_mass / math.max(mass, 1)) ^ CFG.split_exp
    if scale < CFG.split_min_scale then scale = CFG.split_min_scale end
    if scale > 1 then scale = 1 end
    local impulse = CFG.split_impulse * scale
    return mass_to_radius(mass) + impulse / CFG.boost_decay
end


--=====================================================================
-- 2D GUI MODE  — read on-screen cell circles
--=====================================================================

-- Locate & cache the World container (PlayerGui > ScreenGui > path...).
local function get_world_container()
    local cached = _G.__agaresp_world
    if cached and utility.IsValid(cached) then return cached end

    local lp = game.LocalPlayer
    if not lp then return nil end
    local pg = lp:FindFirstChild("PlayerGui")
    if not pg then return nil end
    local node = pg:FindFirstChild(CFG.gui_screen)
    if not node then return nil end
    for _, seg in ipairs(CFG.gui_path) do
        node = node:FindFirstChild(seg)
        if not node then return nil end
    end
    _G.__agaresp_world = node
    return node
end

local function local_name()
    local override = menu.Get("own_name")
    if override and #override > 0 then return override end
    local lp = game.LocalPlayer
    if lp then
        local ok, dn = pcall(function() return lp.DisplayName end)
        if ok and dn and #dn > 0 then return dn end
        return lp.Name
    end
    return nil
end

local function is_virus_color(col)
    local r = comp(col, "R", "r", 1)
    local g = comp(col, "G", "g", 2)
    local b = comp(col, "B", "b", 3)
    local vc = CFG.virus_color
    local tol = CFG.virus_tolerance
    return math.abs(r - vc[1]) <= tol
        and math.abs(g - vc[2]) <= tol
        and math.abs(b - vc[3]) <= tol
end

-- Collect the visible on-screen entities. Returns cells[], viruses[], me.
local function scan_gui(world, sw, sh)
    local cells, viruses = {}, {}
    local me = nil
    local myname = local_name()

    local kids = world:GetChildren()
    local limit = math.min(#kids, CFG.scan_cap)
    for i = 1, limit do
        local f = kids[i]
        local vis = false
        local okv, v = pcall(function() return f.Visible end)
        if okv then vis = v end
        if vis then
            local cx, cy, d = circle_geom(f)
            if cx and d and d >= CFG.min_cell_px
                and cx > -d and cx < sw + d and cy > -d and cy < sh + d then
                local okc, col = pcall(function() return f.BackgroundColor3 end)
                col = okc and col or nil

                if menu.Get("virus_on") and col and is_virus_color(col) then
                    viruses[#viruses + 1] = { x = cx, y = cy, r = d * 0.5 }
                else
                    local score = child_text(f, "LabelStack", "ScoreLabel")
                    local mass = score and tonumber((tostring(score):gsub("%D", ""))) or nil
                    if mass and mass > 0 then
                        local nm = child_text(f, "LabelStack", "NameLabel")
                        local cell = { x = cx, y = cy, r = d * 0.5, mass = mass, name = nm }
                        local mine = myname and nm and (tostring(nm) == myname)
                        cell.is_own = mine or false
                        cells[#cells + 1] = cell
                        if mine then
                            if not me or cell.r > me.r then me = cell end
                        end
                    end
                end
            end
        end
    end

    -- Fallback: if we couldn't name-match ourselves, assume the largest
    -- cell nearest the screen centre is us (the camera follows you).
    if not me and #cells > 0 then
        local bestScore = -1
        local ccx, ccy = sw * 0.5, sh * 0.5
        for _, c in ipairs(cells) do
            local dx, dy = c.x - ccx, c.y - ccy
            local closeness = c.r - math.sqrt(dx * dx + dy * dy) * 0.15
            if closeness > bestScore then bestScore = closeness; me = c end
        end
        if me then me.is_own = true end
    end
    return cells, viruses, me
end

local function render_2d(world)
    local sw, sh = draw.GetScreenSize()
    local cells, viruses, me = scan_gui(world, sw, sh)

    local anchor_x = me and me.x or sw * 0.5
    local anchor_y = me and me.y or sh * 0.5
    local my_r = me and me.r or nil

    -- world scale (studs per pixel), recovered from our own mass if known.
    local px_per_stud = nil
    if me and me.mass then
        local wr = mass_to_radius(me.mass)
        if wr > 0 and me.r > 0 then px_per_stud = me.r / wr end
    end

    local do_lines   = menu.Get("dist_lines")
    local do_dist    = menu.Get("dist_text")
    local do_mass    = menu.Get("mass_text")
    local unit_studs = (menu.Get("dist_unit") == 0)
    local col_line   = menu.GetColor("col_line")

    local threat_on   = menu.Get("threat_on")
    local threat_only = menu.Get("threat_only")
    local threat_ring = menu.Get("threat_ring")
    local col_threat  = menu.GetColor("col_threat")
    local col_prey    = menu.GetColor("col_prey")
    local radius_ratio = math.sqrt(menu.Get("eat_ratio") / 100.0)

    local split_self    = menu.Get("split_self")
    local split_threats = menu.Get("split_threats")
    local split_scale   = menu.Get("split_scale")
    local col_split     = menu.GetColor("col_split")

    -- My own split reach ring.
    if split_self and me and me.mass and px_per_stud then
        local reach_px = split_reach_studs(me.mass) * px_per_stud * split_scale
        draw.Circle(anchor_x, anchor_y, reach_px, col_split, 48, 1.5)
    end

    for _, c in ipairs(cells) do
        if not c.is_own then
            local is_threat = threat_on and my_r and (c.r >= my_r * radius_ratio)
            if not (threat_only and not is_threat) then
                local main_col = is_threat and col_threat or col_prey

                if do_lines then
                    draw.Line(anchor_x, anchor_y, c.x, c.y, col_line, 1.0)
                end

                if is_threat then
                    if threat_ring then
                        draw.Circle(c.x, c.y, math.max(c.r, 6), col_threat, 32, 2.0)
                    end
                    if split_threats and px_per_stud then
                        local reach_px = split_reach_studs(c.mass) * px_per_stud * split_scale
                        draw.Circle(c.x, c.y, reach_px, col_split, 40, 1.0)
                    end
                end

                draw.CircleFilled(c.x, c.y, 2.5, main_col, 10)

                local ty = c.y - 16
                if do_mass then
                    text_centered(c.x, ty, tostring(c.mass), main_col, 12)
                    ty = ty - 13
                end
                if do_dist then
                    local dpx = math.sqrt((c.x - anchor_x) ^ 2 + (c.y - anchor_y) ^ 2)
                    local shown
                    if unit_studs and px_per_stud and px_per_stud > 0 then
                        shown = ("%d"):format(math.floor(dpx / px_per_stud + 0.5))
                    else
                        shown = ("%dpx"):format(math.floor(dpx + 0.5))
                    end
                    text_centered(c.x, ty, shown, main_col, 13)
                end
            end
        end
    end

    if menu.Get("virus_on") then
        local col_virus = menu.GetColor("col_virus")
        local virus_tag = menu.Get("virus_tag")
        for _, v in ipairs(viruses) do
            draw_star(v.x, v.y, math.max(v.r, 10), col_virus, 2.0)
            draw.CircleFilled(v.x, v.y, 2.5, col_virus, 8)
            if virus_tag and my_r then
                -- A virus pops you only if you're big enough to eat it.
                local danger = my_r >= v.r * radius_ratio
                local tag = danger and "DANGER" or "SAFE"
                local tc  = danger and { 1, 0.2, 0.2, 1 } or { 0.6, 0.9, 0.6, 1 }
                text_centered(v.x, v.y - math.max(v.r, 10) - 14, tag, tc, 12)
            end
        end
    end
end


--=====================================================================
-- 3D FALLBACK MODE  — entity.GetPlayers() + Workspace parts
--   (for a 3D Agar game; unused by the 2D reference build)
--=====================================================================
local virus_cache_3d = {}

local function part_radius_3d(p)
    if not p then return nil end
    local s = p.Size
    if not s then return nil end
    local x = s.X or s.x or 0
    local z = s.Z or s.z or 0
    local r = math.max(x, z) * 0.5
    if r > 0 then return r end
    return nil
end

local function character_radius_3d(char)
    if not char or not utility.IsValid(char) then return nil end
    local best = 0
    for _, c in ipairs(char:GetChildren()) do
        if c:IsA("BasePart") then
            local r = part_radius_3d(c)
            if r and r > best then best = r end
        end
    end
    if best > 0 then return best end
    return nil
end

local function pixels_per_stud_3d(pos)
    local ax, ay, aok = draw.WorldToScreen(pos.X, pos.Y, pos.Z)
    if not aok then return nil, ax, ay, false end
    for _, probe in ipairs({ { 20, 0, 0 }, { 0, 0, 20 } }) do
        local bx, by, bok = draw.WorldToScreen(pos.X + probe[1], pos.Y + probe[2], pos.Z + probe[3])
        if bok then
            local dx, dy = bx - ax, by - ay
            local d = math.sqrt(dx * dx + dy * dy)
            if d > 0.001 then return d / 20.0, ax, ay, true end
        end
    end
    return nil, ax, ay, true
end

local function scan_viruses_3d()
    if not menu.Get("enabled") or menu.Get("mode") == 1 then return end
    if not menu.Get("virus_on") then virus_cache_3d = {}; return end
    local root = game.Workspace
    if not root or not utility.IsValid(root) then return end
    local out = {}
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("BasePart") then
            local okc, col = pcall(function() return d.Color end)
            local nm = d.Name or ""
            local match = string.find(nm, "[Vv]irus") ~= nil
            if not match and okc and col then
                local r = comp(col, "R", "r", 1); local g = comp(col, "G", "g", 2); local b = comp(col, "B", "b", 3)
                if g > 0.5 and r < 0.6 and b < 0.5 then match = true end
            end
            if match then
                out[#out + 1] = d
                if #out >= CFG.scan_result_cap then break end
            end
        end
    end
    virus_cache_3d = out
end
thread.Create(scan_viruses_3d, CFG.scan_interval_ms)

local function render_3d()
    local lp = entity.GetLocalPlayer()
    if not lp then return end
    local my_pos = lp.Position
    if not my_pos then return end
    local my_radius = character_radius_3d(lp.Character) or CFG.default_radius_3d

    local scale, my_sx, my_sy, my_ok = pixels_per_stud_3d(my_pos)
    if not my_ok then
        local sw, sh = draw.GetScreenSize()
        my_sx, my_sy = sw * 0.5, sh * 0.5
    end

    local do_lines = menu.Get("dist_lines")
    local do_dist  = menu.Get("dist_text")
    local col_line = menu.GetColor("col_line")
    local threat_on = menu.Get("threat_on")
    local threat_only = menu.Get("threat_only")
    local threat_ring = menu.Get("threat_ring")
    local col_threat = menu.GetColor("col_threat")
    local col_prey = menu.GetColor("col_prey")
    local radius_ratio = math.sqrt(menu.Get("eat_ratio") / 100.0)
    local split_self = menu.Get("split_self")
    local split_threats = menu.Get("split_threats")
    local split_scale = menu.Get("split_scale")
    local col_split = menu.GetColor("col_split")

    if split_self and scale then
        local reach = split_reach_studs(my_radius * my_radius / (CFG.radius_scale * CFG.radius_scale))
        draw.Circle(my_sx, my_sy, reach * scale * split_scale, col_split, 48, 1.5)
    end

    for _, p in ipairs(entity.GetPlayers()) do
        if not p.IsLocal then
            local pos = p.Position
            if pos then
                local dx, dz = pos.X - my_pos.X, pos.Z - my_pos.Z
                local dist = math.sqrt(dx * dx + dz * dz)
                local sx, sy, ok = draw.WorldToScreen(pos.X, pos.Y, pos.Z)
                if ok then
                    local r = character_radius_3d(p.Character) or CFG.default_radius_3d
                    local is_threat = threat_on and (r >= my_radius * radius_ratio)
                    if not (threat_only and not is_threat) then
                        local main_col = is_threat and col_threat or col_prey
                        if do_lines then draw.Line(my_sx, my_sy, sx, sy, col_line, 1.0) end
                        if is_threat then
                            if threat_ring and scale then
                                draw.Circle(sx, sy, math.max(r * scale, 6), col_threat, 32, 2.0)
                            end
                            if split_threats and scale then
                                local mass = r * r / (CFG.radius_scale * CFG.radius_scale)
                                draw.Circle(sx, sy, split_reach_studs(mass) * scale * split_scale, col_split, 40, 1.0)
                            end
                        end
                        draw.CircleFilled(sx, sy, 2.5, main_col, 10)
                        if do_dist then
                            text_centered(sx, sy - 16, ("%d"):format(math.floor(dist + 0.5)), main_col, 13)
                        end
                    end
                end
            end
        end
    end

    if menu.Get("virus_on") then
        local col_virus = menu.GetColor("col_virus")
        local virus_tag = menu.Get("virus_tag")
        for _, v in ipairs(virus_cache_3d) do
            if utility.IsValid(v) then
                local pos = v.Position
                if pos then
                    local sx, sy, ok = draw.WorldToScreen(pos.X, pos.Y, pos.Z)
                    if ok then
                        local vr = part_radius_3d(v)
                        local rpx = (vr and scale) and math.max(vr * scale, 10) or 14
                        draw_star(sx, sy, rpx, col_virus, 2.0)
                        draw.CircleFilled(sx, sy, 2.5, col_virus, 8)
                        if virus_tag then
                            local danger = vr and (my_radius >= vr * radius_ratio)
                            local tag = danger and "DANGER" or "SAFE"
                            local tc = danger and { 1, 0.2, 0.2, 1 } or { 0.6, 0.9, 0.6, 1 }
                            text_centered(sx, sy - rpx - 14, tag, tc, 12)
                        end
                    end
                end
            end
        end
    end
end


--=====================================================================
-- FRAME ENTRY
--=====================================================================
OnFrame = function()
    if not menu.Get("enabled") then return end

    local mode = menu.Get("mode")   -- 0 Auto, 1 2D, 2 3D
    if mode == 2 then
        render_3d()
        return
    end

    local world = get_world_container()
    if world then
        render_2d(world)
    elseif mode == 0 then
        render_3d()   -- Auto: no GUI found, fall back to 3D
    end
end

notify.Success("Agar Awareness loaded", "AgarESP tab · INSERT toggles", 4)
