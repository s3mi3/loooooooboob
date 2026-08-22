--=====================================================================
--  Agar.io-style Awareness / ESP  —  Project Vector Lua Engine
--  API: https://projectvector.cc/lua
--=====================================================================
--
--  Features
--  --------
--   * Distance indicators  — a line from your cell to every other cell,
--                            plus the distance in studs as text.
--   * Threat indicators    — cells big enough to eat you are highlighted
--                            (uses the classic Agar 1.25x mass rule).
--   * Virus indicators     — viruses are drawn as bright spiky stars so
--                            they are impossible to miss, with an optional
--                            "DANGER"/"SAFE" tag based on your own size.
--   * Split-range circles   — a ring showing how far a cell could reach if
--                            it split, drawn around threats (their kill
--                            reach) and optionally around yourself.
--
--  Everything is toggleable / tunable live from the "AgarESP" menu tab.
--
--  IMPORTANT — read this if something does not show up
--  ---------------------------------------------------
--  Because every Agar-style Roblox game stores its data a little
--  differently, two things are configurable so you can adapt the script
--  to YOUR game without touching the logic:
--
--   1. Cell source (menu -> General -> Source)
--        "Entities"       - uses entity.GetPlayers().  Best when each blob
--                           is a tracked player/bot.  This is the default.
--        "Workspace scan" - scans Workspace for round parts.  Use this if
--                           your game's cells are loose parts and do NOT
--                           show up under Entities.
--
--   2. Virus detection (menu -> Virus)
--        Viruses are found by matching their part Name against a Lua
--        pattern (default "[Vv]irus"), with an optional green-colour
--        fallback.  If viruses don't appear, press "Dump Workspace" in the
--        Debug group, look at the console for the real virus part name,
--        and type a matching pattern into the "Name pattern" box.
--
--  All colours are normalised RGBA tables {r,g,b,a} in the 0..1 range.
--=====================================================================


--=====================================================================
-- CONFIG  (things not exposed in the menu — safe to edit)
--=====================================================================
local CFG = {
    -- Fallback radius (studs) used when a cell's real size can't be read.
    default_radius = 5.0,

    -- How often (ms) the Workspace is scanned for viruses / loose cells.
    scan_interval_ms = 600,

    -- Safety cap so a huge Workspace can never lock the scan thread up.
    scan_result_cap = 400,

    -- When scanning Workspace for CELLS, only parts whose horizontal
    -- radius falls in this range count as cells (filters out tiny pellets
    -- and giant map geometry). Studs.
    scan_cell_min_radius = 1.5,
    scan_cell_max_radius = 400.0,

    -- Star used to draw viruses: outer/inner radius ratio and spike count.
    virus_star_points = 12,
    virus_star_inner  = 0.55,
}


--=====================================================================
-- MENU
--=====================================================================
menu.AddTab("AgarESP", "A")

-- ----- General -----------------------------------------------------
menu.AddGroup("AgarESP", "General")
menu.AddCheckbox("AgarESP", "General", "enabled", "Enabled", true, { key = 0x2D }) -- INSERT toggles
menu.AddCombo("AgarESP", "General", "source", "Cell source", { "Entities", "Workspace scan" }, 0)
menu.AddSliderInt("AgarESP", "General", "max_dist", "Max distance (0 = all)", 0, 5000, 0, "%d studs")

-- ----- Distance ----------------------------------------------------
menu.AddGroup("AgarESP", "Distance")
menu.AddCheckbox("AgarESP", "Distance", "dist_lines", "Lines to cells", true)
menu.AddCheckbox("AgarESP", "Distance", "dist_text",  "Distance numbers", true)
menu.AddCheckbox("AgarESP", "Distance", "size_text",  "Show cell size", false)
menu.AddColorpicker("AgarESP", "Distance", "col_line", "Line colour", { 1, 1, 1, 0.35 })

-- ----- Threat ------------------------------------------------------
menu.AddGroup("AgarESP", "Threat")
menu.AddCheckbox("AgarESP", "Threat", "threat_on", "Highlight threats", true)
menu.AddCheckbox("AgarESP", "Threat", "threat_only", "Only draw threats", false)
menu.AddCheckbox("AgarESP", "Threat", "threat_ring", "Ring around threats", true)
-- Slider is the MASS ratio needed to eat (classic Agar = 125%). The script
-- converts it to a radius ratio internally (radius grows with sqrt of mass).
menu.AddSliderInt("AgarESP", "Threat", "eat_ratio", "Eat mass ratio", 100, 200, 125, "%d%%")
menu.AddColorpicker("AgarESP", "Threat", "col_threat", "Threat colour", { 1, 0.15, 0.15, 1 })
menu.AddColorpicker("AgarESP", "Threat", "col_prey",   "Edible colour",  { 0.3, 1, 0.4, 1 })

-- ----- Virus -------------------------------------------------------
menu.AddGroup("AgarESP", "Virus")
menu.AddCheckbox("AgarESP", "Virus", "virus_on", "Show viruses", true)
menu.AddCheckbox("AgarESP", "Virus", "virus_bycolor", "Also match by green colour", true)
menu.AddCheckbox("AgarESP", "Virus", "virus_tag", "DANGER / SAFE tag", true)
menu.AddInput("AgarESP", "Virus", "virus_pat", "Name pattern", "[Vv]irus")
menu.AddInput("AgarESP", "Virus", "scan_root", "Scan container (blank = all)", "")
menu.AddColorpicker("AgarESP", "Virus", "col_virus", "Virus colour", { 0.3, 1, 0.2, 1 })

-- ----- Split range -------------------------------------------------
menu.AddGroup("AgarESP", "Split range")
menu.AddCheckbox("AgarESP", "Split range", "split_self",    "My split reach", true)
menu.AddCheckbox("AgarESP", "Split range", "split_threats", "Threat split reach", true)
-- Split reach (studs) = radius * mult + bonus.  Tune to your game's physics.
menu.AddSliderFloat("AgarESP", "Split range", "split_mult",  "Reach x radius", 0.0, 20.0, 6.0, "%.1f")
menu.AddSliderInt("AgarESP",   "Split range", "split_bonus", "Reach bonus",    0, 500, 40, "%d studs")
menu.AddColorpicker("AgarESP", "Split range", "col_split", "Reach colour", { 1, 0.55, 0.1, 0.5 })

-- ----- Debug -------------------------------------------------------
menu.AddGroup("AgarESP", "Debug")
menu.AddButton("AgarESP", "Debug", "dump_ws", "Dump Workspace", function()
    local root = game.Workspace
    print("=== Workspace children (name : class) ===")
    local n = 0
    for _, c in ipairs(root:GetChildren()) do
        print(("%-28s : %s"):format(tostring(c.Name), tostring(c.ClassName)))
        n = n + 1
    end
    print(("=== %d children.  Players cached: %d ==="):format(n, entity.GetPlayerCount()))
end)


--=====================================================================
-- SMALL HELPERS
--=====================================================================

-- Read a colour component from either {R,G,B} keyed or [1..3] indexed table.
local function comp(col, key, idx)
    if col == nil then return 0 end
    local v = col[key]
    if v == nil then v = col[idx] end
    return v or 0
end

-- Horizontal (X/Z plane) radius of a BasePart, in studs.
local function part_radius(p)
    if not p then return nil end
    local s = p.Size
    if not s then return nil end
    local x = s.X or s.x or 0
    local z = s.Z or s.z or 0
    local r = math.max(x, z) * 0.5
    if r > 0 then return r end
    return nil
end

-- Largest blob radius of a character model, in studs (covers split pieces).
local function character_radius(char)
    if not char or not utility.IsValid(char) then return nil end
    local best = 0
    for _, c in ipairs(char:GetChildren()) do
        if c:IsA("BasePart") then
            local r = part_radius(c)
            if r and r > best then best = r end
        end
    end
    if best == 0 then
        -- Nested rigs: fall back to a (capped) descendant scan.
        local descs = char:GetDescendants()
        local count = 0
        for _, c in ipairs(descs) do
            if c:IsA("BasePart") then
                local r = part_radius(c)
                if r and r > best then best = r end
                count = count + 1
                if count > 64 then break end
            end
        end
    end
    if best > 0 then return best end
    return nil
end

-- Pixels-per-stud at a given world position, by projecting a 20-stud probe.
-- Returns scale, and the projected screen position of `pos` (sx, sy, ok).
local function pixels_per_stud(pos)
    local ax, ay, aok = draw.WorldToScreen(pos.X, pos.Y, pos.Z)
    if not aok then return nil, ax, ay, false end
    -- Probe along +X, then +Z as a fallback (top-down cameras can flatten one axis).
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

-- Draw a spiky star (used for viruses) centred at (cx,cy).
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

-- Centered text convenience.
local function text_centered(cx, y, str, col, size)
    local tw = draw.GetTextSize(str, size)
    draw.Text(cx - tw * 0.5, y, str, col, size)
end


--=====================================================================
-- WORKSPACE SCAN  (viruses always; loose cells when source == scan)
--   Runs on its own throttled thread so OnFrame stays cheap.
--=====================================================================
local virus_cache = {}   -- array of BasePart instances
local cell_cache  = {}   -- array of BasePart instances (scan-mode cells)

local function resolve_scan_root()
    local name = menu.Get("scan_root")
    if name and #name > 0 then
        local found = game.Workspace:FindFirstChild(name, true)
        if found and utility.IsValid(found) then return found end
    end
    return game.Workspace
end

local function looks_like_virus(part, name_pat, by_color)
    local nm = part.Name or ""
    if name_pat and #name_pat > 0 and string.find(nm, name_pat) then
        return true
    end
    if by_color then
        local col = part.Color
        if col then
            local r = comp(col, "R", 1)
            local g = comp(col, "G", 2)
            local b = comp(col, "B", 3)
            if g > 0.5 and r < 0.55 and b < 0.55 then return true end
        end
    end
    return false
end

local function do_scan()
    if not menu.Get("enabled") then return end

    local want_cells   = (menu.Get("source") == 1)
    local want_viruses = menu.Get("virus_on")
    if not want_cells and not want_viruses then
        virus_cache, cell_cache = {}, {}
        return
    end

    local root = resolve_scan_root()
    if not root or not utility.IsValid(root) then return end

    local name_pat  = menu.Get("virus_pat")
    local by_color  = menu.Get("virus_bycolor")

    local viruses, cells = {}, {}
    local descs = root:GetDescendants()
    for _, d in ipairs(descs) do
        if d:IsA("BasePart") then
            if want_viruses and looks_like_virus(d, name_pat, by_color) then
                viruses[#viruses + 1] = d
                if #viruses >= CFG.scan_result_cap then break end
            elseif want_cells then
                local r = part_radius(d)
                if r and r >= CFG.scan_cell_min_radius and r <= CFG.scan_cell_max_radius then
                    cells[#cells + 1] = d
                    if #cells >= CFG.scan_result_cap then break end
                end
            end
        end
    end
    virus_cache = viruses
    cell_cache  = cells
end

-- Create the scan thread ONCE at the top level (never inside OnFrame).
thread.Create(do_scan, CFG.scan_interval_ms)


--=====================================================================
-- CELL LIST for the current frame
--   Returns { {pos=Vector3, radius=studs, name=string, is_own=bool}, ... }
--   plus the local player's world position and radius.
--=====================================================================
local function gather_cells(local_char)
    local out = {}
    local source = menu.Get("source")

    if source == 0 then
        -- Entities: one entry per tracked player/bot cell.
        for _, p in ipairs(entity.GetPlayers()) do
            if not p.IsLocal then
                local pos = p.Position
                if pos then
                    out[#out + 1] = {
                        pos    = pos,
                        radius = character_radius(p.Character) or CFG.default_radius,
                        name   = p.Name,
                        is_own = false,
                    }
                end
            end
        end
    else
        -- Workspace scan: loose cell parts (own cells flagged via ancestry).
        for _, part in ipairs(cell_cache) do
            if utility.IsValid(part) then
                local pos = part.Position
                if pos then
                    local own = local_char and utility.IsValid(local_char)
                        and part:IsDescendantOf(local_char) or false
                    out[#out + 1] = {
                        pos    = pos,
                        radius = part_radius(part) or CFG.default_radius,
                        name   = part.Name,
                        is_own = own,
                    }
                end
            end
        end
    end
    return out
end


--=====================================================================
-- RENDER
--=====================================================================
OnFrame = function()
    if not menu.Get("enabled") then return end

    local lp = entity.GetLocalPlayer()
    if not lp then return end

    local my_pos  = lp.Position
    local my_char = lp.Character
    if not my_pos then return end

    local my_radius = character_radius(my_char) or CFG.default_radius

    -- Pixels-per-stud + our own screen anchor (fallback to screen centre).
    local scale, my_sx, my_sy, my_ok = pixels_per_stud(my_pos)
    if not my_ok then
        local sw, sh = draw.GetScreenSize()
        my_sx, my_sy = sw * 0.5, sh * 0.5
    end

    -- Config pulled once per frame.
    local do_lines   = menu.Get("dist_lines")
    local do_dist    = menu.Get("dist_text")
    local do_size    = menu.Get("size_text")
    local col_line   = menu.GetColor("col_line")

    local threat_on   = menu.Get("threat_on")
    local threat_only = menu.Get("threat_only")
    local threat_ring = menu.Get("threat_ring")
    local col_threat  = menu.GetColor("col_threat")
    local col_prey    = menu.GetColor("col_prey")
    -- mass ratio -> radius ratio (radius ∝ sqrt(mass))
    local radius_ratio = math.sqrt(menu.Get("eat_ratio") / 100.0)

    local split_self    = menu.Get("split_self")
    local split_threats = menu.Get("split_threats")
    local split_mult    = menu.Get("split_mult")
    local split_bonus   = menu.Get("split_bonus")
    local col_split     = menu.GetColor("col_split")

    local max_dist = menu.Get("max_dist")

    ------------------------------------------------------------------
    -- Your own split-reach ring
    ------------------------------------------------------------------
    if split_self and scale then
        local reach = my_radius * split_mult + split_bonus
        draw.Circle(my_sx, my_sy, reach * scale, col_split, 48, 1.5)
    end

    ------------------------------------------------------------------
    -- Cells
    ------------------------------------------------------------------
    local cells = gather_cells(my_char)
    for _, cell in ipairs(cells) do
        if not cell.is_own then
            local pos = cell.pos
            local dx, dz = pos.X - my_pos.X, pos.Z - my_pos.Z
            local dist = math.sqrt(dx * dx + dz * dz)

            local pass_dist = (max_dist <= 0) or (dist <= max_dist)
            if pass_dist then
                local sx, sy, ok = draw.WorldToScreen(pos.X, pos.Y, pos.Z)
                if ok then
                    -- Threat test.
                    local is_threat = threat_on
                        and cell.radius >= (my_radius * radius_ratio)

                    if not (threat_only and not is_threat) then
                        local main_col = is_threat and col_threat or col_prey

                        -- Distance line.
                        if do_lines then
                            draw.Line(my_sx, my_sy, sx, sy, col_line, 1.0)
                        end

                        -- Threat / prey ring + split reach.
                        if is_threat then
                            if threat_ring and scale then
                                draw.Circle(sx, sy, math.max(cell.radius * scale, 6), col_threat, 32, 2.0)
                            end
                            if split_threats and scale then
                                local reach = cell.radius * split_mult + split_bonus
                                draw.Circle(sx, sy, reach * scale, col_split, 40, 1.0)
                            end
                        end

                        -- Marker dot so tiny/faraway cells stay visible.
                        draw.CircleFilled(sx, sy, 2.5, main_col, 10)

                        -- Text stack above the cell.
                        local ty = sy - 16
                        if do_size then
                            text_centered(sx, ty, ("r%d"):format(math.floor(cell.radius + 0.5)), main_col, 12)
                            ty = ty - 13
                        end
                        if do_dist then
                            text_centered(sx, ty, ("%d"):format(math.floor(dist + 0.5)), main_col, 13)
                        end
                    end
                end
            end
        end
    end

    ------------------------------------------------------------------
    -- Viruses
    ------------------------------------------------------------------
    if menu.Get("virus_on") then
        local col_virus = menu.GetColor("col_virus")
        local virus_tag = menu.Get("virus_tag")
        for _, v in ipairs(virus_cache) do
            if utility.IsValid(v) then
                local pos = v.Position
                if pos then
                    local sx, sy, ok = draw.WorldToScreen(pos.X, pos.Y, pos.Z)
                    if ok then
                        local vr = part_radius(v)
                        local rpx = (vr and scale) and math.max(vr * scale, 10) or 14
                        draw_star(sx, sy, rpx, col_virus, 2.0)
                        draw.CircleFilled(sx, sy, 2.5, col_virus, 8)

                        if virus_tag then
                            -- A virus can split you only if you're big enough to eat it.
                            local danger = vr and (my_radius >= vr * radius_ratio)
                            local tag = danger and "DANGER" or "SAFE"
                            local tc  = danger and { 1, 0.2, 0.2, 1 } or { 0.6, 0.9, 0.6, 1 }
                            text_centered(sx, sy - rpx - 14, tag, tc, 12)
                        end
                    end
                end
            end
        end
    end
end

notify.Success("Agar Awareness loaded", "Toggle with INSERT — see AgarESP tab", 4)
