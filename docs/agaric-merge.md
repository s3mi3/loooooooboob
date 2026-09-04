# Agaric merge (from place dump)

Source dump: `https://files.catbox.moe/kmnvpp.rbxlx` (UniversalSynSaveInstance).

## How merge works

Split / feed / freeze go through `ReplicatedStorage.Gameplay.Network.Input_Action`.

The **Merge** shop ability (`GameDatabase.Items.Merge`, 30000 gold) is bound the same way:

1. Equip it in `Equipped.Abilities` `Slot1`–`Slot10`.
2. HUD clones `Gui.Abilities.Bottom1ScreenGui.TemplateButton` as `SlotN` with image `rbxassetid://105142089333769`.
3. Pressing that slot (keys `1`–`0`, or clicking the button) runs `Input_Action:FireServer("Merge")`.

Photon has no `FireServer`, so `instant_merge.lua` taps that slot with `input.simulate_press` (or a HUD click).

## Natural recombine (no ability)

From `Gameplay.Config`:

```lua
MassFromRadius(r) = r * r
GetMergeDelay(radius) = clamp(1.96 + MassFromRadius(radius) * 0.00204, 2, 6)
```

Mode settings (classic defaults):

- `MergeDelayMultiplier = 1`
- `MergeDelay = 0` (use formula)
- `MergePullSpeed = 1000`
- `SelfMergeOverlap = 0.35`

`FastMerge` official mode sets `DelayMultiplier = 0.08`.

Cooldown for the ability is `LocalPlayer` attribute `AbilityCooldown_Merge` (server timestamp).

## Client layout used by the script

- Cells: `PlayerGui.Agaric2D` frames named `PlayerBlob` (`NameLabel`, `MassLabel`, attribute `OwnerUid`)
- Hotbar: `PlayerGui.Gui.Abilities.Bottom1ScreenGui.Slot1` … `Slot10`
