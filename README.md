# BetterSnap — Deleted Message Logger

A Chrome/Chromium extension that logs Snapchat chats/snaps that get **deleted**, so you can still see what was there.

It works in two situations:

1. **In-chat** — you have the conversation open and the other person deletes a message.
2. **Off-chat** — a message is deleted in a conversation you are **not** currently viewing. This is detected from the conversation list ("sidebar").

## Install (unpacked)

1. Go to `chrome://extensions`.
2. Enable **Developer mode** (top-right).
3. Click **Load unpacked** and select this folder (the one containing `manifest.json`).
4. Open [web.snapchat.com](https://web.snapchat.com) and log in.

You'll see a small **"Deleted"** pill in the bottom-right of the page. Click it (or press `Ctrl+Shift+L`) to open the log panel where you can view, **Export** (JSON), or **Clear** captured messages.

## How off-chat detection works

When someone deletes a message in a chat you aren't viewing, the message content is usually **not in the page** — the app only renders a short preview line in the sidebar row. So off-chat we recover the **last preview text** the row showed before it flipped to Snapchat's *"deleted a chat/snap"* tombstone.

The detector anchors everything to a **conversation-row model** and uses three overlapping signals so it survives Snapchat's React re-rendering:

- **(A) In-place text flip** — a `characterData` observer with `characterDataOldValue`. When a preview text node changes into a deletion phrase, we read the *old* value directly.
- **(B) Row re-mount** — a `childList` observer keeps a short rolling buffer of removed row text and pairs it with the tombstone that appears in the same/next tick.
- **(C) Periodic scan** — every second we cache `friendName → latest preview` for each row, and log the cached preview when a row flips to a tombstone.

Each captured entry records the friend/row name as its `context`. Entries are de-duplicated per conversation within a 6s window.

### Limitations (off-chat)

- Off-chat entries are generally **text-only**. Full media (images/videos) usually isn't downloaded until you open the chat, so it can't be recovered afterward. If the row only showed a status like `New Chat`, the recovered preview may be empty and the entry is logged as a deletion event without content.
- Detection relies on Snapchat's UI text/markup. If Snapchat changes its markup or wording, row/name parsing may need tuning (see below).

## Debugging / tuning

Snapchat's DOM is obfuscated and changes over time. Two tools help you verify the sidebar parsing against the live page:

- Toggle **Debug: ON** in the panel (or set `localStorage.bettersnap_dml_debug = '1'`) to log detection activity to the console.
- Run `__bettersnap_diagnoseSidebar()` in the page console to print every conversation row the detector sees, along with the friend name, preview, and whether it currently reads as a tombstone. Use this to confirm rows/names are parsed correctly, or to adjust the selectors/regexes in `content.js` if Snapchat changes its UI:
  - `ROW_SELECTOR` — how conversation rows are found.
  - `SIDEBAR_DELETED_RE` — the deletion phrase.
  - `looksLikeFriendName` / `getRowFriendName` — how the row's friend name is extracted.

## Files

- `manifest.json` — MV3 manifest (content script on `web.snapchat.com`, `storage` permission).
- `content.js` — all capture, detection, storage, and UI logic.
