# Photon Agaric scripts

Photon Lua, [API](https://photon-4.gitbook.io/api).

Windows use `force_open = true`. **Insert** hides the ESP window.

| Script | What you should see |
| --- | --- |
| `awareness.lua` | **ESP** window (name box, ESP toggle, Hide). Type your **in-game blob nick**, not the Roblox / Photon name. Viruses get **red** rings. Each of your pieces shows its own merge time; the top banner is the slowest piece. Other players show `xN` cell count. Off-screen players who can eat you get an edge arrow (mass + cell count). Insert hides the panel; merge watermark/banner stay. |
| `tickrate.lua` | Load test only. Will not speed Agaric. |
| `instant_merge.lua` | Taps hotbar 1–10. Needs Merge equipped. |

No window and no watermark means Photon errored before `gui.create` — check the Photon log.

Watermark but no circles means you are not in a match, or `gui_position` is not on those frames.
