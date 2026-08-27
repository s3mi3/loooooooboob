# Photon Agaric scripts

Photon Lua, [API](https://photon-4.gitbook.io/api).

Windows use `force_open = true` so they show **without** opening the Photon menu. A loaded script also draws a top-left watermark:

- `agaric esp on`
- `tickrate script on`
- `merge script on`

| Script | What you should see |
| --- | --- |
| `awareness.lua` | Watermark + circles on cells after you spawn. Status: `Agaric2D missing` until in a match, then `blobs N`. |
| `tickrate.lua` | Watermark. Will not speed Agaric. |
| `instant_merge.lua` | Watermark. Set hotbar slot, **Merge now**. Needs Merge equipped. |

No window and no watermark means Photon errored before `gui.create` — check the Photon log.

Watermark but no circles means you are not in a match, or `gui_position` is not on those frames (status will say).
