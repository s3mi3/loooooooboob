--=====================================================================
--  Agar.io-style Awareness / ESP  —  Project Vector Lua Engine
--  API: https://projectvector.cc/lua
--=====================================================================
--
--  Features
--   * Distance indicators  — line from your cell to every other cell + number.
--   * Threat indicators    — cells big enough to eat you are highlighted
--                            (classic 1.25x mass eat rule -> radius ratio).
--   * Virus indicators     — viruses drawn as bright spiky stars, DANGER/SAFE
--                            tagged by your size.
--   * Split-range circles   — ring showing how far a cell could reach on a
--                            split (their kill zone) + optionally your own.
--
--  Everything is toggleable / tunable live from the "AgarESP" menu tab.
--  INSERT toggles the overlay.
--
--  ------------------------------------------------------------------
--  GAME PRESETS (auto-detected)
--  ------------------------------------------------------------------
--  These Agar-style Roblox games render cells as 2D GUI circles, not 3D
--  parts, so the script reads the on-screen circle Frames directly.  Two
--  layouts are recognised automatically, plus a 3D fallback:
--
--   * "Agaric"  (ScreenGui "Agaric2D")  <- reverse-engineered from a live
--        dump.  Cells   = Frames named "PlayerBlob" (child "Visual" holds the
--                         colour, "NameLabel"/"MassLabel" hold text).
--        Viruses = ImageLabels named "Spike".
--        Circles live under  Agaric2D > Camera > Canvas > LayerBottom/LayerMain.
--        The Camera frame is centred and UIScale'd, so screen pixels are read
--        from AbsolutePosition/AbsoluteSize (with a render-scale fallback).
--
--   * "Agar2D"  (ScreenGui "Agar2DScreen") <- an alternative template.
--        Cells   = circle Frames under Root > World with a numeric ScoreLabel.
--        Viruses = circles coloured RGB 138,207,0.
--
--   * "3D"      fallback: entity.GetPlayers() + Workspace parts via
--        draw.WorldToScreen (for a 3D Agar game).
--
--  Pick a preset explicitly in  General -> Mode, or leave it on Auto.
--  Debug -> "Dump GUI" prints the container tree plus a sample circle's
--  AbsolutePosition / Position / Size so you can confirm the layout.
--
--  All colours are normalised RGBA {r,g,b,a} in 0..1.
--=====================================================================


--=====================================================================
-- PRESETS
--=====================================================================
local PRESETS = {
    agaric = {
        screen         = "Agaric2D",
        container_path = { "Camera", "Canvas" }, -- scan its descendants
        scale_frame    = "Camera",               -- holds the UIScale (render-scale fallback)
        scan_descendants = true,
        cell_by_name   = "PlayerBlob",
        virus_by_name  = "Spike",
        mass_label     = { "MassLabel" },
        name_label     = { "NameLabel" },
        geom           = "absolute",             -- AbsolutePosition, else render-scale
    },
    agar2d = {
        screen         = "Agar2DScreen",
        container_path = { "Root", "World" },     -- direct children are the circles
        scan_descendants = false,
        cell_by_name   = nil,                     -- cell = has a numeric ScoreLabel
        virus_by_color = { 138 / 255, 207 / 255, 0 / 255 },
        mass_label     = { "LabelStack", "ScoreLabel" },
        name_label     = { "LabelStack", "NameLabel" },
        geom           = "offset",                -- World is fullscreen: offset = px
    },
}


--=====================================================================
-- CONFIG (safe to edit)
--=====================================================================
local CFG = {
    virus_tolerance   = 0.16,   -- colour match tolerance for Agar2D viruses
    min_cell_px       = 8.0,    -- ignore circles smaller than this (food/pellets)
    scan_cap          = 800,    -- max frames inspected per frame

    -- Split reach as a multiple of a cell's on-screen radius (used when the
    -- exact world scale isn't known). reach_px = radius_px * split_radius_mult.
    split_radius_mult_default = 6.0,

    -- 3D fallback:
    radius_scale      = 0.632,  -- world radius = radius_scale * sqrt(mass)
    split_impulse     = 700.0,
    split_exp         = 0.28,
    split_min_scale   = 0.22,
    initial_mass      = 10000.0,
    boost_decay       = 1.9,
    default_radius_3d = 5.0,
    scan_interval_ms  = 600,
    scan_result_cap   = 400,

    virus_star_points = 12,
    virus_star_inner  = 0.55,
}


--=====================================================================
-- MENU
--=====================================================================
menu.AddTab("AgarESP", "A")

menu.AddGroup("AgarESP", "General")
menu.AddCheckbox("AgarESP", "General", "enabled", "Enabled", true, { key = 0x2D })
menu.AddCombo("AgarESP", "General", "mode", "Mode", { "Auto", "Agaric", "Agar2D", "3D parts" }, 0)
menu.AddInput("AgarESP", "General", "own_name", "Your name (blank = auto)", "")

menu.AddGroup("AgarESP", "Distance")
menu.AddCheckbox("AgarESP", "Distance", "dist_lines", "Lines to cells", true)
menu.AddCheckbox("AgarESP", "Distance", "dist_text",  "Distance numbers", true)
menu.AddCheckbox("AgarESP", "Distance", "mass_text",  "Show mass", false)
menu.AddColorpicker("AgarESP", "Distance", "col_line", "Line colour", { 1, 1, 1, 0.35 })

menu.AddGroup("AgarESP", "Threat")
menu.AddCheckbox("AgarESP", "Threat", "threat_on", "Highlight threats", true)
menu.AddCheckbox("AgarESP", "Threat", "threat_only", "Only draw threats", false)
menu.AddCheckbox("AgarESP", "Threat", "threat_ring", "Ring around threats", true)
menu.AddSliderInt("AgarESP", "Threat", "eat_ratio", "Eat mass ratio", 100, 200, 125, "%d%%")
menu.AddColorpicker("AgarESP", "Threat", "col_threat", "Threat colour", { 1, 0.15, 0.15, 1 })
menu.AddColorpicker("AgarESP", "Threat", "col_prey",   "Edible colour",  { 0.3, 1, 0.4, 1 })

menu.AddGroup("AgarESP", "Virus")
menu.AddCheckbox("AgarESP", "Virus", "virus_on", "Show viruses", true)
menu.AddCheckbox("AgarESP", "Virus", "virus_tag", "DANGER / SAFE tag", true)
menu.AddColorpicker("AgarESP", "Virus", "col_virus", "Virus colour", { 0.54, 0.81, 0, 1 })

menu.AddGroup("AgarESP", "Split range")
menu.AddCheckbox("AgarESP", "Split range", "split_self",    "My split reach", true)
menu.AddCheckbox("AgarESP", "Split range", "split_threats", "Threat split reach", true)
menu.AddSliderFloat("AgarESP", "Split range", "split_mult", "Reach x radius", 1.0, 15.0, 6.0, "%.1f")
menu.AddColorpicker("AgarESP", "Split range", "col_split", "Reach colour", { 1, 0.55, 0.1, 0.5 })

menu.AddGroup("AgarESP", "Debug")
menu.AddButton("AgarESP", "Debug", "dump_gui", "Dump GUI", function()
    local ctx = _G.__agaresp_ctx
    if not ctx or not ctx.container or not utility.IsValid(ctx.container) then
        print("[AgarESP] No 2D container resolved. Detected preset: " .. tostring(_G.__agaresp_preset_name))
        print("[AgarESP] If your game is 2D, check the ScreenGui name in PRESETS.")
        return
    end
    local root = ctx.container
    local kids = ctx.preset.scan_descendants and root:GetDescendants() or root:GetChildren()
    print(("[AgarESP] preset=%s container=%s children/desc=%d"):format(
        tostring(_G.__agaresp_preset_name), tostring(root.Name), #kids))
    local shown = 0
    for _, f in ipairs(kids) do
        if shown >= 10 then break end
        local okC, cls = pcall(function() return f.ClassName end)
        if okC and (cls == "Frame" or cls == "ImageLabel") then
            local okA, ap = pcall(function() return f.AbsolutePosition end)
            local okS, asz = pcall(function() return f.AbsoluteSize end)
            local okP, pos = pcall(function() return f.Position end)
            print(("  %-12s cls=%-10s abs=%s absSize=%s pos=%s"):format(
                tostring(f.Name), tostring(cls),
                tostring(okA and ap), tostring(okS and asz), tostring(okP and pos)))
            shown = shown + 1
        end
    end
end)


--=====================================================================
-- SMALL HELPERS
--=====================================================================
local function comp(col, k1, k2, idx)
    if col == nil then return 0 end
    local v = col[k1]; if v == nil then v = col[k2] end; if v == nil then v = col[idx] end
    return v or 0
end

local function udim2_offsets(t)
    if type(t) ~= "table" then return nil end
    if type(t[2]) == "number" and type(t[4]) == "number" then return t[2], t[4] end
    local X = t.X or t.x; local Y = t.Y or t.y
    if type(X) == "table" and type(Y) == "table" then
        local ox = X.Offset or X.offset or X[2]
        local oy = Y.Offset or Y.offset or Y[2]
        if ox and oy then return ox, oy end
    end
    return nil
end

local function vec2_xy(v)
    if type(v) ~= "table" then return nil end
    local x = v.X or v.x or v[1]
    local y = v.Y or v.y or v[2]
    if x and y then return x, y end
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

-- Read a label's text via a child path, stripping RichText tags.
local function label_text(frame, path)
    local ok, txt = pcall(function()
        local n = frame
        for _, seg in ipairs(path) do
            n = n:FindFirstChild(seg)
            if not n then return nil end
        end
        return n.Text
    end)
    if not ok or not txt then return nil end
    return (tostring(txt):gsub("<[^>]->", ""))
end

-- Parse a mass label like "1234", "12.3K", "4.5M" -> number.
local function parse_mass(s)
    if not s then return nil end
    s = tostring(s):gsub("%s", ""):gsub(",", "")
    local num, suf = s:match("([%d%.]+)([KkMmBb]?)")
    if not num then return nil end
    local n = tonumber(num)
    if not n then return nil end
    suf = suf:lower()
    if suf == "k" then n = n * 1e3 elseif suf == "m" then n = n * 1e6 elseif suf == "b" then n = n * 1e9 end
    return n
end


--=====================================================================
-- 2D GUI READER (preset-driven)
--=====================================================================

-- Resolve & cache the container (+ optional scale frame) for a preset.
local function resolve_container(preset, preset_name)
    local ctx = _G.__agaresp_ctx
    if ctx and ctx.preset == preset and ctx.container and utility.IsValid(ctx.container) then
        return ctx
    end
    local lp = game.LocalPlayer
    if not lp then return nil end
    local pg = lp:FindFirstChild("PlayerGui")
    if not pg then return nil end
    local node = pg:FindFirstChild(preset.screen)
    if not node then return nil end

    local scale_frame = nil
    for _, seg in ipairs(preset.container_path) do
        node = node:FindFirstChild(seg)
        if not node then return nil end
        if preset.scale_frame and seg == preset.scale_frame then scale_frame = node end
    end

    ctx = { preset = preset, container = node, scale_frame = scale_frame }
    _G.__agaresp_ctx = ctx
    _G.__agaresp_preset_name = preset_name
    return ctx
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

-- Read the render-scale (UIScale.Scale) from the preset's scale frame.
local function read_uiscale(ctx)
    if not ctx.scale_frame then return nil end
    local ok, s = pcall(function()
        local us = ctx.scale_frame:FindFirstChildOfClass("UIScale")
        return us and us.Scale or nil
    end)
    if ok and type(s) == "number" and s > 0 then return s end
    return nil
end

-- Screen centre/diameter of a circle frame per the preset geometry.
local function circle_geom(frame, preset, uiscale, scx, scy)
    if preset.geom == "offset" then
        local okP, pos = pcall(function() return frame.Position end)
        local okS, size = pcall(function() return frame.Size end)
        if okP and okS then
            local px, py = udim2_offsets(pos)
            local sw, sh = udim2_offsets(size)
            if px and sw then return px, py, math.max(sw, sh) end
        end
        return nil
    end

    -- geom == "absolute": AbsolutePosition/AbsoluteSize first.
    local okA, ap = pcall(function() return frame.AbsolutePosition end)
    local okB, asz = pcall(function() return frame.AbsoluteSize end)
    if okA and okB then
        local ax, ay = vec2_xy(ap)
        local aw, ah = vec2_xy(asz)
        if ax and aw and (aw ~= 0 or ah ~= 0) then
            return ax + aw * 0.5, ay + ah * 0.5, math.max(aw, ah)
        end
    end
    -- Render-scale fallback: screen = centre + offset*uiscale.
    if uiscale then
        local okP, pos = pcall(function() return frame.Position end)
        local okS, size = pcall(function() return frame.Size end)
        if okP and okS then
            local px, py = udim2_offsets(pos)
            local sw, sh = udim2_offsets(size)
            if px and sw then
                return scx + px * uiscale, scy + py * uiscale, math.max(sw, sh) * uiscale
            end
        end
    end
    return nil
end

local function is_virus_color(col, target)
    local r = comp(col, "R", "r", 1); local g = comp(col, "G", "g", 2); local b = comp(col, "B", "b", 3)
    return math.abs(r - target[1]) <= CFG.virus_tolerance
        and math.abs(g - target[2]) <= CFG.virus_tolerance
        and math.abs(b - target[3]) <= CFG.virus_tolerance
end

local function scan_2d(ctx, sw, sh)
    local preset = ctx.preset
    local cells, viruses, me = {}, {}, nil
    local myname = local_name()
    local uiscale = (preset.geom == "absolute") and read_uiscale(ctx) or nil
    local scx, scy = sw * 0.5, sh * 0.5

    local kids = preset.scan_descendants and ctx.container:GetDescendants() or ctx.container:GetChildren()
    local limit = math.min(#kids, CFG.scan_cap)
    for i = 1, limit do
        local f = kids[i]
        local okN, fname = pcall(function() return f.Name end)
        fname = okN and fname or ""

        -- Fast name-based classification when the preset defines it.
        local is_virus = (preset.virus_by_name and fname == preset.virus_by_name) or false
        local is_cell  = (preset.cell_by_name  and fname == preset.cell_by_name) or false

        -- For presets that don't name their circles, use visibility + score/colour.
        local consider = is_virus or is_cell or (not preset.cell_by_name)
        if consider then
            local vis = true
            local okv, v = pcall(function() return f.Visible end)
            if okv then vis = v end
            if vis then
                local cx, cy, d = circle_geom(f, preset, uiscale, scx, scy)
                if cx and d and d >= CFG.min_cell_px
                    and cx > -d and cx < sw + d and cy > -d and cy < sh + d then

                    if not is_cell and not is_virus and preset.virus_by_color then
                        local okc, col = pcall(function() return f.BackgroundColor3 end)
                        if okc and col and is_virus_color(col, preset.virus_by_color) then
                            is_virus = true
                        end
                    end

                    if menu.Get("virus_on") and is_virus then
                        viruses[#viruses + 1] = { x = cx, y = cy, r = d * 0.5 }
                    else
                        local massStr = label_text(f, preset.mass_label)
                        local mass = parse_mass(massStr)
                        -- Named-cell presets accept the cell even without a mass;
                        -- unnamed presets require a numeric score to qualify.
                        if is_cell or (mass and mass > 0) then
                            local nm = label_text(f, preset.name_label)
                            local cell = { x = cx, y = cy, r = d * 0.5, mass = mass, name = nm }
                            local mine = myname and nm and (tostring(nm) == myname)
                            cell.is_own = mine or false
                            cells[#cells + 1] = cell
                            if mine and (not me or cell.r > me.r) then me = cell end
                        end
                    end
                end
            end
        end
    end

    -- Fallback "you" = largest cell nearest screen centre (camera follows you).
    if not me and #cells > 0 then
        local best = -1e9
        for _, c in ipairs(cells) do
            local dx, dy = c.x - scx, c.y - scy
            local score = c.r - math.sqrt(dx * dx + dy * dy) * 0.15
            if score > best then best = score; me = c end
        end
        if me then me.is_own = true end
    end
    return cells, viruses, me
end

local function render_2d(ctx)
    local sw, sh = draw.GetScreenSize()
    local cells, viruses, me = scan_2d(ctx, sw, sh)

    local ax = me and me.x or sw * 0.5
    local ay = me and me.y or sh * 0.5
    local my_r = me and me.r or nil

    -- studs-per-pixel (only when the preset gives real mass -> world radius)
    local px_per_stud = nil
    if me and me.mass then
        local wr = CFG.radius_scale * math.sqrt(math.max(me.mass, 1))
        if wr > 0 and me.r > 0 then px_per_stud = me.r / wr end
    end

    local do_lines = menu.Get("dist_lines")
    local do_dist  = menu.Get("dist_text")
    local do_mass  = menu.Get("mass_text")
    local col_line = menu.GetColor("col_line")
    local threat_on = menu.Get("threat_on")
    local threat_only = menu.Get("threat_only")
    local threat_ring = menu.Get("threat_ring")
    local col_threat = menu.GetColor("col_threat")
    local col_prey = menu.GetColor("col_prey")
    local radius_ratio = math.sqrt(menu.Get("eat_ratio") / 100.0)
    local split_self = menu.Get("split_self")
    local split_threats = menu.Get("split_threats")
    local split_mult = menu.Get("split_mult")
    local col_split = menu.GetColor("col_split")

    if split_self and my_r then
        draw.Circle(ax, ay, my_r * split_mult, col_split, 48, 1.5)
    end

    for _, c in ipairs(cells) do
        if not c.is_own then
            local is_threat = threat_on and my_r and (c.r >= my_r * radius_ratio)
            if not (threat_only and not is_threat) then
                local main_col = is_threat and col_threat or col_prey
                if do_lines then draw.Line(ax, ay, c.x, c.y, col_line, 1.0) end
                if is_threat then
                    if threat_ring then draw.Circle(c.x, c.y, math.max(c.r, 6), col_threat, 32, 2.0) end
                    if split_threats then draw.Circle(c.x, c.y, c.r * split_mult, col_split, 40, 1.0) end
                end
                draw.CircleFilled(c.x, c.y, 2.5, main_col, 10)
                local ty = c.y - 16
                if do_mass and c.mass then
                    text_centered(c.x, ty, tostring(math.floor(c.mass + 0.5)), main_col, 12); ty = ty - 13
                end
                if do_dist then
                    local dpx = math.sqrt((c.x - ax) ^ 2 + (c.y - ay) ^ 2)
                    local shown
                    if px_per_stud and px_per_stud > 0 then
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
                local danger = my_r >= v.r * radius_ratio
                local tag = danger and "DANGER" or "SAFE"
                local tc = danger and { 1, 0.2, 0.2, 1 } or { 0.6, 0.9, 0.6, 1 }
                text_centered(v.x, v.y - math.max(v.r, 10) - 14, tag, tc, 12)
            end
        end
    end
end


--=====================================================================
-- 3D FALLBACK  (entity.GetPlayers + Workspace parts)
--=====================================================================
local virus_cache_3d = {}

local function part_radius_3d(p)
    if not p then return nil end
    local s = p.Size
    if not s then return nil end
    local x = s.X or s.x or 0; local z = s.Z or s.z or 0
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

local function split_reach_studs_3d(mass)
    local scale = (CFG.initial_mass / math.max(mass, 1)) ^ CFG.split_exp
    if scale < CFG.split_min_scale then scale = CFG.split_min_scale end
    if scale > 1 then scale = 1 end
    return CFG.radius_scale * math.sqrt(math.max(mass, 1)) + CFG.split_impulse * scale / CFG.boost_decay
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
    if not menu.Get("enabled") or menu.Get("mode") ~= 3 and menu.Get("mode") ~= 0 then return end
    if not menu.Get("virus_on") then virus_cache_3d = {}; return end
    local root = game.Workspace
    if not root or not utility.IsValid(root) then return end
    local out = {}
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("BasePart") then
            local nm = d.Name or ""
            local match = string.find(nm, "[Vv]irus") ~= nil
            if not match then
                local okc, col = pcall(function() return d.Color end)
                if okc and col then
                    local r = comp(col, "R", "r", 1); local g = comp(col, "G", "g", 2); local b = comp(col, "B", "b", 3)
                    if g > 0.5 and r < 0.6 and b < 0.5 then match = true end
                end
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
    if not my_ok then local sw, sh = draw.GetScreenSize(); my_sx, my_sy = sw * 0.5, sh * 0.5 end

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
    local col_split = menu.GetColor("col_split")

    if split_self and scale then
        local mass = my_radius * my_radius / (CFG.radius_scale * CFG.radius_scale)
        draw.Circle(my_sx, my_sy, split_reach_studs_3d(mass) * scale, col_split, 48, 1.5)
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
                            if threat_ring and scale then draw.Circle(sx, sy, math.max(r * scale, 6), col_threat, 32, 2.0) end
                            if split_threats and scale then
                                local mass = r * r / (CFG.radius_scale * CFG.radius_scale)
                                draw.Circle(sx, sy, split_reach_studs_3d(mass) * scale, col_split, 40, 1.0)
                            end
                        end
                        draw.CircleFilled(sx, sy, 2.5, main_col, 10)
                        if do_dist then text_centered(sx, sy - 16, ("%d"):format(math.floor(dist + 0.5)), main_col, 13) end
                    end
                end
            end
        end
    end

    if menu.Get("virus_on") then
        local col_virus = menu.GetColor("col_virus")
        local virus_tag = menu.Get("virus_tag")
        for _, vv in ipairs(virus_cache_3d) do
            if utility.IsValid(vv) then
                local pos = vv.Position
                if pos then
                    local sx, sy, ok = draw.WorldToScreen(pos.X, pos.Y, pos.Z)
                    if ok then
                        local vr = part_radius_3d(vv)
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
    local mode = menu.Get("mode")  -- 0 Auto, 1 Agaric, 2 Agar2D, 3 3D

    if mode == 3 then render_3d(); return end

    if mode == 1 then
        local ctx = resolve_container(PRESETS.agaric, "agaric")
        if ctx then render_2d(ctx) end
        return
    elseif mode == 2 then
        local ctx = resolve_container(PRESETS.agar2d, "agar2d")
        if ctx then render_2d(ctx) end
        return
    end

    -- Auto: try Agaric, then Agar2D, else 3D.
    local ctx = resolve_container(PRESETS.agaric, "agaric")
    if ctx then render_2d(ctx); return end
    ctx = resolve_container(PRESETS.agar2d, "agar2d")
    if ctx then render_2d(ctx); return end
    render_3d()
end

notify.Success("Agar Awareness loaded", "AgarESP tab · INSERT toggles", 4)
