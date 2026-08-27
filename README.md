# Photon Agaric scripts

Photon Lua, [API](https://photon-4.gitbook.io/api).

Windows use `force_open = true`. **Insert** hides the ESP window; merge cooldown stays on screen.

| Script | What you should see |
| --- | --- |
| `awareness.lua` | Small **ESP** window: Name box, ESP toggle, Hide (Insert). Circles on cells. `MERGE Xs` / `CAN MERGE` at the top of the screen when split. |
| `tickrate.lua` | Load test only. Will not speed Agaric. |
| `instant_merge.lua` | Taps hotbar 1–10. Needs Merge equipped. |

No window and no watermark means Photon errored before `gui.create` — check the Photon log.

Watermark but no circles means you are not in a match, or `gui_position` is not on those frames (status will say).
