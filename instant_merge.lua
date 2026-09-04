-- Instant merge: taps hotbar 1-0 for the Merge ability.
-- Needs Merge equipped. force_open so the window is visible.

local MENU = "Instant Merge"
local KEYS = { 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x30 }

pcall(function()
    gui.remove(MENU)
end)
pcall(function()
    hook.remove("render", "instant_merge")
end)

local menu = gui.create(MENU, true)
menu:set_pos(40, 520)
menu:set_size(300, 180)

local status = menu:add_label("loaded — pick slot, then Merge now")
local enabled = menu:add_checkbox("Auto while split (needs Merge)", false)
local slot = menu:add_slider("Hotbar slot", 1, 10, 1)

local last_tap = 0

local function tap()
    local n = slot:get_value()
    if type(n) ~= "number" then
        n = 1
    end
    n = math.floor(n + 0.5)
    if n < 1 then
        n = 1
    end
    if n > 10 then
        n = 10
    end
    input.simulate_press(KEYS[n])
    last_tap = get_tickcount()
    status:set_label("tapped slot " .. tostring(n))
end

menu:add_button("Merge now", function()
    local pass, err = pcall(tap)
    if not pass then
        status:set_label("error: " .. tostring(err))
    end
end)

hook.add("render", "instant_merge", function()
    pcall(function()
        render.add_text(vector2(12, 64), "merge script on", color(0.9, 0.7, 0.3, 1), 13, true)
        if not enabled:get_value() then
            return
        end
        local now = get_tickcount()
        if now - last_tap < 200 then
            return
        end
        local focused = true
        pcall(function()
            focused = is_gamefocused()
        end)
        if focused then
            tap()
        end
    end)
end)

log.add("Instant Merge force-open. Equip Merge, set the slot, press Merge now.", color(0.4, 0.8, 1, 1))
log.notification("Instant Merge loaded", "success")
