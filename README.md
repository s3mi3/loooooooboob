# Photon Agaric scripts

Photon Lua, [API](https://photon-4.gitbook.io/api).

Windows use `force_open = true`. **Insert** hides the ESP window.

| Script | What you should see |
| --- | --- |
| `awareness.lua` | **ESP** window (name box, ESP toggle, Hide). Type your **in-game blob nick**, not the Roblox / Photon name. Viruses get **red** rings. Merge cooldown is appended to Photon's top-right watermark (`photon v6.9 \| …`) and drawn as a large `MERGE Xs` / `CAN MERGE` banner at the top of the screen. Insert hides the panel; the watermark and banner stay. |
| `tickrate.lua` | Load test only. Will not speed Agaric. |
| `instant_merge.lua` | Taps hotbar 1–10. Needs Merge equipped. |

No window and no watermark means Photon errored before `gui.create` — check the Photon log.

Watermark but no circles means you are not in a match, or `gui_position` is not on those frames.
