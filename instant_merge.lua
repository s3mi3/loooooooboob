-- Photon instant-merge for Agaric
-- API: https://photon-4.gitbook.io/api
-- Place dump: PlayerBlob GUI under Agaric2D, Merge ability on Input_Action
--
-- Natural recombine is server-side:
--   delay = clamp(1.96 + mass * 0.00204, 2, 6) seconds
--   then cells pull together (SelfMergeOverlap 0.35)
-- Photon cannot FireServer, so this taps the equipped Merge ability
-- the same way the game does: Slot1-10 -> Input_Action("Merge").

local MENU_NAME = "Instant Merge"
local MERGE_IMAGE = "105142089333769"
local SCAN_CAP = 900

local SLOT_KEYS = {
    [1] = 0x31, [2] = 0x32, [3] = 0x33, [4] = 0x34, [5] = 0x35,
    [6] = 0x36, [7] = 0x37, [8] = 0x38, [9] = 0x39, [10] = 0x30
}

local SLOT_OPTIONS = {
    "Auto", "Slot 1", "Slot 2", "Slot 3", "Slot 4", "Slot 5",
    "Slot 6", "Slot 7", "Slot 8", "Slot 9", "Slot 10"
}

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

local function texture_of(inst)
    if not valid(inst) or type(inst.get_texture) ~= "function" then
        return nil
    end
    local ok, tex = pcall(function()
        return inst:get_texture()
    end)
    if ok then
        return tex
    end
    return nil
end

local function is_merge_texture(tex)
    return contains(tex, MERGE_IMAGE)
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

local function slot_bar(pg)
    local gui = child(pg, "Gui")
    if not valid(gui) then
        gui = descendant(pg, "Bottom1ScreenGui")
        if valid(gui) then
            return gui
        end
        return nil
    end
    local abilities = child(gui, "Abilities")
    if not valid(abilities) then
        return nil
    end
    return child(abilities, "Bottom1ScreenGui")
end

local function slot_looks_like_merge(slot)
    if is_merge_texture(texture_of(slot)) then
        return true
    end
    local kids = slot:get_children()
    if type(kids) ~= "table" then
        return false
    end
    for _, kid in pairs(kids) do
        if valid(kid) and is_merge_texture(texture_of(kid)) then
            return true
        end
        if valid(kid) and kid.name == "Cooldown" then
            -- ignore
        end
    end
    return false
end

local function visible_slots(bar)
    local found = {}
    if not valid(bar) then
        return found
    end
    for i = 1, 10 do
        local slot = child(bar, "Slot" .. i)
        if valid(slot) then
            found[#found + 1] = { index = i, inst = slot }
        end
    end
    return found
end

local function resolve_slot(bar, combo_index)
    local slots = visible_slots(bar)
    if combo_index ~= nil and combo_index > 0 then
        local want = combo_index
        for i = 1, #slots do
            if slots[i].index == want then
                return slots[i]
            end
        end
        local named = child(bar, "Slot" .. want)
        if valid(named) then
            return { index = want, inst = named }
        end
        return nil
    end

    for i = 1, #slots do
        if slot_looks_like_merge(slots[i].inst) then
            return slots[i]
        end
    end

    if #slots == 1 then
        return slots[1]
    end
    return nil
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

local function blob_name(blob)
    local label = child(blob, "NameLabel")
    if not valid(label) or type(label.get_label_text) ~= "function" then
        return nil
    end
    local ok, text = pcall(function()
        return label:get_label_text()
    end)
    if ok then
        return text
    end
    return nil
end

local function blob_mass(blob)
    local label = child(blob, "MassLabel")
    if not valid(label) or type(label.get_label_text) ~= "function" then
        return nil
    end
    local ok, text = pcall(function()
        return label:get_label_text()
    end)
    if not ok or text == nil then
        return nil
    end
    local n = tonumber(tostring(text):match("[%d%.]+"))
    if n then
        return n * 10
    end
    return nil
end

local function name_matches(blob_text, lp)
    if blob_text == nil or not valid(lp) then
        return false
    end
    local raw = tostring(blob_text)
    if contains(raw, lp.name) then
        return true
    end
    if lp.display_name ~= nil and contains(raw, lp.display_name) then
        return true
    end
    return false
end

local function own_cells(pg, lp)
    local count = 0
    local biggest = 0
    if not valid(pg) or not valid(lp) then
        return count, biggest
    end

    local root = child(pg, "Agaric2D")
    if not valid(root) then
        root = descendant(pg, "Agaric2D")
    end
    if not valid(root) then
        return count, biggest
    end

    local canvas = descendant(root, "Canvas")
    if not valid(canvas) then
        canvas = root
    end

    local list = canvas:get_descendants()
    if type(list) ~= "table" then
        return count, biggest
    end

    local uid = tostring(lp.userid)
    local scanned = 0
    for _, inst in pairs(list) do
        scanned = scanned + 1
        if scanned > SCAN_CAP then
            break
        end
        if valid(inst) and inst.name == "PlayerBlob" then
            local owner = blob_owner(inst)
            local mine = false
            if owner ~= nil then
                mine = owner == uid
            else
                mine = name_matches(blob_name(inst), lp)
            end
            if mine then
                count = count + 1
                local mass = blob_mass(inst)
                if mass ~= nil and mass > biggest then
                    biggest = mass
                end
            end
        end
    end
    return count, biggest
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

local function cooldown_left(lp)
    if not valid(lp) then
        return 0
    end
    local until_t = nil
    pcall(function()
        until_t = lp:get_attribute("AbilityCooldown_Merge", attribute_type.NUMBER)
    end)
    if type(until_t) ~= "number" or until_t <= 0 then
        return 0
    end
    local now = get_unixtime()
    if type(now) ~= "number" then
        return 0
    end
    local left = until_t - now
    if left < 0 then
        return 0
    end
    return left
end

local function tap_key(vk)
    if type(input.simulate_press) == "function" then
        input.simulate_press(vk)
        return
    end
    input.simulate_press_down(vk)
    input.simulate_press_up(vk)
end

local function tap_slot(slot, click_hud)
    if slot == nil then
        return false
    end
    if click_hud and valid(slot.inst) then
        local pos = slot.inst.gui_position
        local size = slot.inst.gui_size
        if pos ~= nil and size ~= nil then
            local old = input.get_mouse_position()
            input.set_mouse_position(vector2(pos.x + size.x * 0.5, pos.y + size.y * 0.5))
            if type(input.simulate_mouse_click) == "function" then
                input.simulate_mouse_click(MOUSE1)
            else
                input.simulate_mouse_down(MOUSE1)
                input.simulate_mouse_up(MOUSE1)
            end
            input.set_mouse_position(old)
            return true
        end
    end
    local vk = SLOT_KEYS[slot.index]
    if vk == nil then
        return false
    end
    tap_key(vk)
    return true
end

-- Menu
local menu = gui.create(MENU_NAME, false)
menu:set_pos(80, 350)
menu:set_size(360, 280)

local status = menu:add_label("Waiting for Agaric...")
local enabled = menu:add_checkbox("Enabled", false)
local click_hud = menu:add_checkbox("Click HUD instead of key", false)
local slot_combo = menu:add_combo("Merge slot", SLOT_OPTIONS, 0)
local rate = menu:add_slider("Tap rate (Hz)", 1, 12, 4)
local bind = menu:add_keybind("Merge now", 0x47) -- G

local cached_slot = nil
local last_scan = 0
local last_tap = 0
local last_status = 0
local last_cell_scan = 0
local cached_cells = 0
local cached_mass = 0

local function combo_slot_index()
    local idx = slot_combo:get_value()
    if type(idx) ~= "number" or idx <= 0 then
        return 0
    end
    return idx
end

local function refresh_slot(pg, force)
    local now = get_tickcount()
    if not force and now - last_scan < 400 then
        return cached_slot
    end
    last_scan = now
    cached_slot = resolve_slot(slot_bar(pg), combo_slot_index())
    return cached_slot
end

local function do_merge(reason)
    if menu_active() or not is_gamefocused() then
        return false
    end
    local pg = player_gui()
    local slot = refresh_slot(pg, false)
    if slot == nil then
        log.notification("Equip Merge in a hotbar slot (or pick the slot)", "warning")
        return false
    end
    local ok = tap_slot(slot, click_hud:get_value())
    if ok then
        last_tap = get_tickcount()
        log.add("Instant merge (" .. tostring(reason) .. ") slot " .. tostring(slot.index), color(0.5, 1, 0.6, 1))
    end
    return ok
end

menu:add_button("Merge now", function()
    do_merge("button")
end)

slot_combo:change_callback(function()
    cached_slot = nil
    last_scan = 0
end)

local prev_bind = false
hook.add("render", "instant_merge", function()
    local bind_down = bind:get_state()
    if bind_down and not prev_bind then
        do_merge("keybind")
    end
    prev_bind = bind_down

    local now = get_tickcount()
    local pg = player_gui()
    local lp = local_player()
    if now - last_cell_scan >= 80 then
        cached_cells, cached_mass = own_cells(pg, lp)
        last_cell_scan = now
    end
    local cells, mass = cached_cells, cached_mass
    local slot = refresh_slot(pg, false)
    local cd = cooldown_left(lp)
    local delay = natural_delay(mass)

    if now - last_status > 200 then
        last_status = now
        local slot_txt = "no slot"
        if slot ~= nil then
            slot_txt = "Slot " .. tostring(slot.index)
        end
        local line = slot_txt .. "  |  cells " .. tostring(cells)
        if cells > 1 then
            line = line .. string.format("  |  natural ~%.1fs", delay)
        end
        if cd > 0.05 then
            line = line .. string.format("  |  cd %.1fs", cd)
        end
        status:set_label(line)
    end

    if not enabled:get_value() then
        return
    end
    if cells < 2 then
        return
    end
    if cd > 0.08 then
        return
    end
    if menu_active() or not is_gamefocused() then
        return
    end

    local hz = rate:get_value()
    if type(hz) ~= "number" or hz < 1 then
        hz = 1
    end
    local interval = 1000 / hz
    if now - last_tap < interval then
        return
    end
    if slot == nil then
        return
    end
    tap_slot(slot, click_hud:get_value())
    last_tap = now
end)

log.add("Instant Merge loaded. Equip the Merge ability, then enable the toggle when split.", color(0.4, 0.8, 1, 1))
log.notification("Instant Merge GUI ready", "info")
