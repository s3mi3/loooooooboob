/*
 * BetterSnap — Deleted Message Logger (v13)
 * -----------------------------------------------------------
 * Two independent capture paths:
 *
 *   IN-CHAT (you are viewing the conversation)
 *     Every 500ms, walk the chat pane for "message-ish" elements,
 *     snapshot their text + media, and when Snapchat's tombstone
 *     count goes UP, log whatever disappeared in that tick.
 *
 *   OFF-CHAT (you are NOT viewing the conversation)  <-- v13 focus
 *     Watch the conversation list ("sidebar"). For every row we
 *     continuously cache (friendName -> latest preview text). Three
 *     signals then detect a deletion in that row:
 *       (A) characterData flips  — a preview text node whose value
 *           changes in-place into a "deleted a chat" phrase. We read
 *           the OLD value directly, so we recover the prior preview.
 *       (B) childList re-mounts  — React swaps the whole row; we keep
 *           a short rolling buffer of removed text and pair it with the
 *           tombstone that appears in the same/next tick.
 *       (C) periodic row scan    — fallback that compares each row's
 *           current text against the cached preview and logs on flip.
 *
 * Off-chat we can only recover what the sidebar actually rendered
 * (usually the last preview line); full media generally isn't in the
 * DOM until you open the chat, so those entries may be text-only.
 */
'use strict';
(() => {
  if (window.__bettersnap_dml_loaded) return;
  window.__bettersnap_dml_loaded = true;

  const TAG          = '[BetterSnap DML]';
  const STORAGE_KEY  = 'bettersnap_deleted_log';
  const DEBUG_KEY    = 'bettersnap_dml_debug';
  const MAX_LOG      = 500;
  const MAX_TEXT_LEN = 4000;
  const POLL_MS      = 500;
  const MEDIA_CAP    = 200;

  // The gold signal: Snapchat's own tombstone text.
  const TOMBSTONE = /(DELETED A (?:CHAT|SNAP|MESSAGE))|(\bmessage deleted\b)/i;
  const isTombstone = (t) => !!t && TOMBSTONE.test(t);

  let DEBUG = false;
  try { DEBUG = localStorage.getItem(DEBUG_KEY) === '1'; } catch (_) {}
  const dbg = (...a) => { if (DEBUG) console.log(TAG, ...a); };

  /* ---------- media cache (fetch → dataURL) ---------- */

  const mediaCache = new Map(); // src -> dataURL | null (pending)
  const mediaOrder = [];
  const isBitmoji = (s) => /bitmoji\.snapchat\.com|images\.bitmoji\.com/i.test(s || '');
  const isTinyIcon = (el) => {
    if (!(el instanceof Element)) return false;
    const r = el.getBoundingClientRect();
    return r.width < 60 && r.height < 60; // avatars, emoji icons
  };

  async function cacheMedia(src) {
    if (!src || mediaCache.has(src)) return;
    if (!/^blob:|^https?:|^data:/.test(src)) return;
    if (isBitmoji(src)) return;
    mediaCache.set(src, null);
    mediaOrder.push(src);
    while (mediaOrder.length > MEDIA_CAP) {
      const evict = mediaOrder.shift();
      mediaCache.delete(evict);
    }
    try {
      const resp = await fetch(src);
      const blob = await resp.blob();
      if (blob.size > 15_000_000) { mediaCache.delete(src); return; }
      const dataUri = await new Promise((res, rej) => {
        const r = new FileReader();
        r.onload = () => res(r.result); r.onerror = rej;
        r.readAsDataURL(blob);
      });
      if (typeof dataUri === 'string') mediaCache.set(src, dataUri);
    } catch (_) { mediaCache.delete(src); }
  }

  function scanAllMedia(root) {
    if (!(root instanceof Element) && root !== document) return;
    const scope = root === document ? document.body : root;
    if (!scope) return;
    scope.querySelectorAll('img, video, source').forEach((n) => {
      if (n.tagName !== 'SOURCE' && isTinyIcon(n)) return;
      const src = n.currentSrc || n.src;
      if (src) cacheMedia(src);
    });
  }

  /* ---------- storage ---------- */

  function loadList(cb) {
    try {
      chrome.storage.local.get([STORAGE_KEY], (res) => {
        cb(Array.isArray(res[STORAGE_KEY]) ? res[STORAGE_KEY] : []);
      });
    } catch (_) {
      try {
        const raw = localStorage.getItem(STORAGE_KEY);
        cb(raw ? JSON.parse(raw) : []);
      } catch (__) { cb([]); }
    }
  }
  function saveList(list, cb) {
    try { chrome.storage.local.set({ [STORAGE_KEY]: list }, () => cb && cb()); }
    catch (_) {
      try { localStorage.setItem(STORAGE_KEY, JSON.stringify(list)); } catch (__) {}
      cb && cb();
    }
  }
  function saveEntry(entry) {
    dbg('SAVED', entry);
    loadList((list) => {
      // Dedupe: same text + same context within 6s.
      const dup = list.find((e) =>
        e.text === entry.text &&
        (e.context || '') === (entry.context || '') &&
        Math.abs((e.timestamp || 0) - entry.timestamp) < 6000);
      if (dup) return;
      list.push(entry);
      while (list.length > MAX_LOG) list.shift();
      saveList(list, () => bumpBadge(list.length));
    });
  }

  /* ---------- context ---------- */

  function conversationLabel() {
    const cands = ['header h1', 'header h2', '[role="banner"] h1', '[role="banner"] h2'];
    for (const sel of cands) {
      const el = document.querySelector(sel);
      const t = el && (el.textContent || '').trim();
      if (t) return t.slice(0, 120);
    }
    return '';
  }

  /* ---------- candidate discovery ---------- */

  function collectMedia(el) {
    const out = [];
    if (!(el instanceof Element)) return out;
    el.querySelectorAll('img, video').forEach((n) => {
      if (isTinyIcon(n)) return;
      let src = n.currentSrc || n.src;
      if (!src && n.tagName === 'VIDEO') {
        const s = n.querySelector('source');
        if (s) src = s.src;
      }
      if (src && !isBitmoji(src)) out.push({ kind: n.tagName.toLowerCase(), src });
    });
    return out;
  }

  const TIMESTAMP_RE = /\b\d{1,2}:\d{2}(?:\s?(?:AM|PM))?\b/i;

  /**
   * Get an element's OWN direct text (concatenated text nodes, not descendants).
   */
  function ownText(el) {
    let s = '';
    for (const n of el.childNodes) {
      if (n.nodeType === 3) s += n.nodeValue;
    }
    return s.trim();
  }

  const EXCLUDE_SELECTOR =
    '#bettersnap-dml-panel, #bettersnap-dml-pill, ' +
    '[role="menu"], [role="dialog"], [role="tooltip"], [role="listbox"]';

  /**
   * Count how many tombstones are currently visible in the DOM.
   * Uses raw text search on document.body to be robust across DOM shapes.
   */
  function countTombstones() {
    const body = document.body;
    if (!body) return 0;
    const text = body.innerText || body.textContent || '';
    const m = text.match(/DELETED A (?:CHAT|SNAP|MESSAGE)/gi);
    return m ? m.length : 0;
  }

  /**
   * Find "message text" candidates: elements whose OWN direct text is
   * non-trivial (not just a timestamp, not a tombstone, not menu text).
   * These are the actual message bubbles' text spans.
   */
  function findMessageTexts() {
    const out = [];
    if (!document.body) return out;
    // Walk all elements. Cheap enough for a chat page.
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT, null);
    for (let el = walker.nextNode(); el; el = walker.nextNode()) {
      if (el.closest && el.closest(EXCLUDE_SELECTOR)) continue;
      const t = ownText(el);
      if (!t) continue;
      if (t.length < 1 || t.length > 500) continue;
      if (isTombstone(t)) continue;
      // Strip timestamps — a pure timestamp span isn't a message.
      const stripped = t.replace(TIMESTAMP_RE, '').trim();
      if (!stripped) continue;
      // Skip common UI text.
      if (/^(Send a chat|Reply|Copy Text|Save in Chat|Report)$/i.test(stripped)) continue;
      out.push({ el, text: t });
    }
    return out;
  }

  /**
   * Find media candidates (img/video) that are inside chat area.
   */
  function findMediaEls() {
    const out = [];
    if (!document.body) return out;
    document.body.querySelectorAll('img, video').forEach((n) => {
      if (n.closest(EXCLUDE_SELECTOR)) return;
      if (isTinyIcon(n)) return;
      let src = n.currentSrc || n.src;
      if (!src && n.tagName === 'VIDEO') {
        const s = n.querySelector('source'); if (s) src = s.src;
      }
      if (!src || isBitmoji(src)) return;
      out.push({ kind: n.tagName.toLowerCase(), src });
    });
    return out;
  }

  /* ---------- snapshot + detect (diff between polls) ---------- */

  // Each poll produces:
  //   - a Set of message text signatures currently visible
  //   - a list of media srcs currently visible
  //   - the total tombstone count
  // When tombstone count goes UP, whatever disappeared in that tick was deleted.

  /** @type {string[]} */
  let prevTexts = [];
  /** @type {{kind:string,src:string}[]} */
  let prevMedia = [];
  let prevTombstoneCount = 0;
  let firstTick = true;

  function pollTick() {
    if (!document.body) return;

    const tombstoneCount = countTombstones();
    const msgs = findMessageTexts();
    const currentTexts = msgs.map((m) => m.text);
    const currentMedia = findMediaEls();

    if (firstTick) {
      firstTick = false;
      prevTexts = currentTexts;
      prevMedia = currentMedia;
      prevTombstoneCount = tombstoneCount;
      dbg('baseline:', currentTexts.length, 'msgs,',
          currentMedia.length, 'media,', tombstoneCount, 'tombstones');
      return;
    }

    const tombstoneDelta = tombstoneCount - prevTombstoneCount;

    if (tombstoneDelta > 0) {
      dbg('tombstone delta:', tombstoneDelta);

      // Which texts disappeared? Use a multiset diff.
      const curCounts = new Map();
      for (const t of currentTexts) curCounts.set(t, (curCounts.get(t) || 0) + 1);
      const missingTexts = [];
      for (const t of prevTexts) {
        const c = curCounts.get(t) || 0;
        if (c > 0) curCounts.set(t, c - 1);
        else missingTexts.push(t);
      }

      // Which media disappeared?
      const curSrcs = new Set(currentMedia.map((m) => m.src));
      const missingMedia = prevMedia.filter((m) => !curSrcs.has(m.src));

      dbg('missing texts:', missingTexts, 'missing media:', missingMedia);

      // If we found the same number of missing items as tombstones added,
      // pair them up. Otherwise log what we have.
      if (missingTexts.length || missingMedia.length) {
        // Simplest strategy: log each missing text as its own entry, and
        // attach any missing media to the first one (best-effort).
        if (missingTexts.length === 0 && missingMedia.length) {
          logDeletion({
            text: '', media: missingMedia,
            tombstone: 'DELETED',
          });
        } else {
          for (let i = 0; i < missingTexts.length; i++) {
            logDeletion({
              text: missingTexts[i],
              media: i === 0 ? missingMedia : [],
              tombstone: 'DELETED',
            });
          }
        }
      }
      // If nothing was tracked as missing (e.g. we only just started
      // observing this chat), we can't recover the content.
    }

    prevTexts = currentTexts;
    prevMedia = currentMedia;
    prevTombstoneCount = tombstoneCount;
  }

  function logDeletion({ text, media, tombstone, context }) {
    const hydrated = (media || []).map((m) => ({
      kind: m.kind, src: m.src, data: mediaCache.get(m.src) || null,
    }));
    saveEntry({
      timestamp: Date.now(),
      text:      (text || '').slice(0, MAX_TEXT_LEN),
      context:   context || conversationLabel(),
      url:       location.href,
      tombstone,
      media:     hydrated,
    });
  }

  // Reset baseline whenever the conversation changes.
  let lastUrl = location.href;
  let lastContext = '';
  setInterval(() => {
    const ctx = conversationLabel();
    if (location.href !== lastUrl || ctx !== lastContext) {
      lastUrl = location.href;
      lastContext = ctx;
      firstTick = true;
      prevTexts = [];
      prevMedia = [];
      prevTombstoneCount = 0;
      dbg('conversation changed → baseline reset (ctx:', ctx, ')');
    }
  }, 1000);

  // Media caching observer runs always so we grab blobs before deletion.
  const mediaObserver = new MutationObserver((mutations) => {
    for (const m of mutations) {
      if (m.type === 'childList') {
        m.addedNodes.forEach((n) => n.nodeType === 1 && scanAllMedia(n));
      } else if (m.type === 'attributes' && m.attributeName === 'src') {
        const el = m.target;
        if (el instanceof Element && (el.tagName === 'IMG' || el.tagName === 'VIDEO')) {
          const src = el.currentSrc || el.src;
          if (src && !isTinyIcon(el)) cacheMedia(src);
        }
      }
    }
  });

  /* ---------- sidebar / chat-list watcher ------------------------------
   * Catches deletions in chats you're NOT currently viewing.
   *
   * v13 rewrite: everything is anchored to a "conversation row" model so
   * the three detection signals (characterData / childList / periodic scan)
   * agree on which friend a deletion belongs to and what the prior preview
   * was.
   */

  const SIDEBAR_DELETED_RE =
    /\b(?:deleted\s+(?:a|the|this)\s+(?:chat|snap|message)|(?:chat|message|snap)\s+deleted)\b/i;

  const extractDeletionPhrase = (text) => {
    const m = (text || '').match(SIDEBAR_DELETED_RE);
    return (m ? m[0] : 'DELETED').slice(0, 200);
  };

  // friend name -> { preview, ts, deleted }
  const friendPreviewCache = new Map();
  const FRIEND_CACHE_MAX = 500;
  function trimFriendCache() {
    while (friendPreviewCache.size > FRIEND_CACHE_MAX) {
      friendPreviewCache.delete(friendPreviewCache.keys().next().value);
    }
  }

  // friend name -> last-log timestamp (dedupe)
  const lastSidebarLogAt = new Map();
  const SIDEBAR_DEDUPE_MS = 6000;

  function looksLikeFriendName(t) {
    if (!t) return false;
    if (t.length > 40) return false;
    if (TIMESTAMP_RE.test(t)) return false;
    if (SIDEBAR_DELETED_RE.test(t)) return false;
    // Reject common non-name preview/status words.
    if (/^(New Chat|New Snap|Received|Delivered|Opened|Sent|Me|You|Tap to|Reply)$/i.test(t)) {
      return false;
    }
    // Very permissive: letters/digits/spaces/underscore/dot/dash only.
    return /^[A-Za-z0-9 ._\-]{1,40}$/.test(t);
  }

  /* --- conversation-row model ------------------------------------------- */

  // Elements that tend to wrap a single conversation-list row on web.snapchat.
  const ROW_SELECTOR =
    'a[href], [role="listitem"], [role="option"], [role="row"], [role="button"], li';

  /**
   * Given any element inside the sidebar, find the element that represents
   * the whole conversation row it belongs to.
   */
  function findConversationRow(el) {
    if (!(el instanceof Element)) return null;
    const row = el.closest(ROW_SELECTOR);
    if (row && !(row.closest && row.closest(EXCLUDE_SELECTOR))) return row;
    // Fallback: climb a few levels so callers still get a container.
    let node = el;
    for (let i = 0; i < 5 && node.parentElement; i++) node = node.parentElement;
    return node;
  }

  /**
   * Extract the friend / display name for a conversation row. Tries the most
   * reliable sources first (accessibility labels, avatar alt) before falling
   * back to the first short "name-looking" text.
   */
  function getRowFriendName(row, excludeEl) {
    if (!(row instanceof Element)) return '';

    // 1. aria-label on the row (or a labelled descendant). Snapchat often
    //    labels rows like "Alice, New Chat, 2h".
    const labelled = row.matches('[aria-label]') ? row : row.querySelector('[aria-label]');
    if (labelled) {
      const first = (labelled.getAttribute('aria-label') || '').split(/[,·|]/)[0].trim();
      if (looksLikeFriendName(first)) return first;
    }

    // 2. Avatar alt text is frequently the display name.
    const avatar = row.querySelector('img[alt]');
    if (avatar) {
      const alt = (avatar.getAttribute('alt') || '').trim();
      if (looksLikeFriendName(alt)) return alt;
    }

    // 3. First short, name-shaped own-text among descendants.
    const kids = row.querySelectorAll('*');
    for (const c of kids) {
      if (excludeEl && (c === excludeEl || c.contains(excludeEl))) continue;
      const t = ownText(c);
      if (looksLikeFriendName(t)) return t;
    }
    return '';
  }

  /**
   * Backwards-compatible helper used by the mutation observers: resolve the
   * friend name for the row that owns `el`.
   */
  function findRowFriendName(el) {
    const row = findConversationRow(el);
    return row ? getRowFriendName(row, el) : '';
  }

  /**
   * The row's current preview/status line (the text that flips to a
   * tombstone when a message is deleted). Excludes the friend name,
   * pure timestamps, and deletion phrases.
   */
  function getRowPreviewText(row) {
    if (!(row instanceof Element)) return '';
    const friend = getRowFriendName(row);
    let best = '';
    const kids = row.querySelectorAll('*');
    for (const c of kids) {
      const t = ownText(c);
      if (!t || t.length > 200) continue;
      if (t === friend) continue;
      if (SIDEBAR_DELETED_RE.test(t)) continue;
      // Drop pure-timestamp fragments.
      if (t.replace(TIMESTAMP_RE, '').trim() === '') continue;
      // Preview is usually the last content line in the row.
      best = t;
    }
    return best;
  }

  function collectConversationRows() {
    const rows = [];
    const seen = new Set();
    if (!document.body) return rows;
    document.body.querySelectorAll(ROW_SELECTOR).forEach((el) => {
      if (el.closest && el.closest(EXCLUDE_SELECTOR)) return;
      if (seen.has(el)) return;
      const txt = (el.textContent || '').trim();
      if (!txt || txt.length > 300) return;
      seen.add(el);
      rows.push(el);
    });
    return rows;
  }

  function logSidebarDeletion(friend, prevText, tombstoneText) {
    if (!friend) friend = '(unknown chat)';
    const now = Date.now();
    const last = lastSidebarLogAt.get(friend) || 0;
    if (now - last < SIDEBAR_DEDUPE_MS) return;
    lastSidebarLogAt.set(friend, now);
    logDeletion({
      text: prevText || '(deleted — content not available off-chat)',
      media: [],
      tombstone: (tombstoneText || 'DELETED').slice(0, 200),
      context: friend,
    });
    dbg('SIDEBAR DELETION:', friend, '←', prevText);
  }

  /* --- (A) characterData observer --------------------------------------- */

  const textNodeObserver = new MutationObserver((mutations) => {
    for (const m of mutations) {
      if (m.type !== 'characterData') continue;
      const node = m.target;
      const oldValue = m.oldValue || '';
      const newValue = (node.nodeValue || '');
      if (oldValue === newValue) continue;
      const oldIsDel = SIDEBAR_DELETED_RE.test(oldValue);
      const newIsDel = SIDEBAR_DELETED_RE.test(newValue);
      if (newIsDel && !oldIsDel) {
        const parent = node.parentElement;
        if (!parent) continue;
        if (parent.closest && parent.closest(EXCLUDE_SELECTOR)) continue;
        const row = findConversationRow(parent);
        const friend = row ? getRowFriendName(row, parent) : '';
        const openCtx = conversationLabel();
        if (friend && friend === openCtx && isInsideOpenChatPane(parent)) continue;
        // Prefer the old text node value; fall back to the cached preview.
        let prev = oldValue.trim();
        if (!prev || SIDEBAR_DELETED_RE.test(prev)) {
          const cached = friend && friendPreviewCache.get(friend);
          if (cached && cached.preview) prev = cached.preview;
        }
        logSidebarDeletion(friend, prev, newValue.trim());
        if (friend) friendPreviewCache.set(friend, { preview: '', ts: Date.now(), deleted: true });
      }
    }
  });

  /* --- (A2) childList observer: react re-mount detector ------------------
   * When a tombstone text appears anywhere, look at what was REMOVED from
   * that mutation's parent element in the same batch. That removed subtree
   * contained the deleted message content.
   *
   * Also: remember a rolling window of recently-removed elements' text so
   * we can associate them with a tombstone that arrives a few ticks later.
   */

  // Rolling buffer of recent removals: { text, friend, ts }
  const recentRemovals = [];
  const RECENT_MAX = 200;
  const RECENT_TTL_MS = 4000;

  function pushRemoval(text, friend) {
    if (!text) return;
    if (SIDEBAR_DELETED_RE.test(text)) return;
    recentRemovals.push({ text: text.trim(), friend: friend || '', ts: Date.now() });
    while (recentRemovals.length > RECENT_MAX) recentRemovals.shift();
  }

  function matchRemovalForTombstone(parent) {
    const now = Date.now();
    // Prefer the newest removal from the same friend row, else newest overall.
    const parentFriend = findRowFriendName(parent);
    for (let i = recentRemovals.length - 1; i >= 0; i--) {
      const r = recentRemovals[i];
      if (now - r.ts > RECENT_TTL_MS) continue;
      if (parentFriend && r.friend && parentFriend === r.friend) {
        recentRemovals.splice(i, 1);
        return { text: r.text, friend: parentFriend };
      }
    }
    for (let i = recentRemovals.length - 1; i >= 0; i--) {
      const r = recentRemovals[i];
      if (now - r.ts > RECENT_TTL_MS) continue;
      recentRemovals.splice(i, 1);
      return { text: r.text, friend: parentFriend || r.friend || '' };
    }
    return { text: '', friend: parentFriend };
  }

  const childObserver = new MutationObserver((mutations) => {
    for (const m of mutations) {
      if (m.type !== 'childList') continue;

      // Record every removed subtree's text for later association.
      if (m.removedNodes && m.removedNodes.length) {
        const parentFriend = m.target instanceof Element
          ? findRowFriendName(m.target) : '';
        m.removedNodes.forEach((n) => {
          if (!(n instanceof Element)) return;
          if (n.closest && n.closest(EXCLUDE_SELECTOR)) return;
          const walker = document.createTreeWalker(n, NodeFilter.SHOW_ELEMENT, null);
          let node = n;
          do {
            const t = ownText(node);
            if (t && t.length < 300 && !TIMESTAMP_RE.test(t)) {
              pushRemoval(t, parentFriend);
            }
          } while ((node = walker.nextNode()));
        });
      }

      // Look for added tombstones.
      if (m.addedNodes && m.addedNodes.length) {
        m.addedNodes.forEach((n) => {
          if (!(n instanceof Element)) {
            if (n.nodeType === 3 && SIDEBAR_DELETED_RE.test(n.nodeValue || '')) {
              handleAddedTombstone(m.target, (n.nodeValue || '').trim());
            }
            return;
          }
          if (n.closest && n.closest(EXCLUDE_SELECTOR)) return;
          const tombText = findTombstoneTextIn(n);
          if (tombText) handleAddedTombstone(n, tombText);
        });
      }
    }
  });

  function findTombstoneTextIn(root) {
    if (!(root instanceof Element)) return '';
    if (SIDEBAR_DELETED_RE.test(ownText(root))) return ownText(root);
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, null);
    let el;
    while ((el = walker.nextNode())) {
      const t = ownText(el);
      if (t && SIDEBAR_DELETED_RE.test(t)) return t;
    }
    return '';
  }

  function handleAddedTombstone(anchor, tombText) {
    const parent = anchor instanceof Element ? anchor : anchor.parentElement;
    if (!parent) return;
    const row = findConversationRow(parent);
    const friend = row ? getRowFriendName(row, parent) : findRowFriendName(parent);
    const openCtx = conversationLabel();
    // Skip if this is the currently open chat (main pollTick handles it).
    if (friend && friend === openCtx && isInsideOpenChatPane(parent)) return;

    // Best previous text: a matched removal, else the cached preview.
    let { text: prevText } = matchRemovalForTombstone(parent);
    if (!prevText && friend) {
      const cached = friendPreviewCache.get(friend);
      if (cached && cached.preview) prevText = cached.preview;
    }
    logSidebarDeletion(friend, prevText, tombText);
    if (friend) friendPreviewCache.set(friend, { preview: '', ts: Date.now(), deleted: true });
  }

  function isInsideOpenChatPane(el) {
    const composer =
      document.querySelector('textarea, [contenteditable="true"], [role="textbox"]');
    if (!composer) return false;
    let scope = composer.parentElement;
    for (let i = 0; i < 12 && scope; i++, scope = scope.parentElement) {
      if (scope.scrollHeight > scope.clientHeight + 100) break;
    }
    return !!(scope && scope.contains(el));
  }

  /* --- (C) periodic sidebar harvest / fallback --------------------------- */

  function sidebarTick() {
    if (!document.body) return;
    const rows = collectConversationRows();
    let flipsThisTick = 0;
    const openCtx = conversationLabel();

    for (const row of rows) {
      const friend = getRowFriendName(row);
      if (!friend) continue;

      const rowText = row.textContent || '';
      const isTomb = SIDEBAR_DELETED_RE.test(rowText);
      const cached = friendPreviewCache.get(friend);

      if (isTomb) {
        // A tombstone is visible for this row right now.
        if (cached && cached.deleted) continue; // already logged this one
        if (friend === openCtx && isInsideOpenChatPane(row)) continue;
        const prev = cached && cached.preview && !SIDEBAR_DELETED_RE.test(cached.preview)
          ? cached.preview : '';
        logSidebarDeletion(friend, prev, extractDeletionPhrase(rowText));
        friendPreviewCache.set(friend, { preview: '', ts: Date.now(), deleted: true });
        flipsThisTick++;
      } else {
        // Normal preview text — cache it (and clear any "deleted" flag).
        const preview = getRowPreviewText(row);
        if (preview) {
          friendPreviewCache.set(friend, { preview, ts: Date.now(), deleted: false });
        } else if (cached && cached.deleted) {
          // Row recovered but has no readable preview; reset the flag.
          friendPreviewCache.set(friend, { preview: '', ts: Date.now(), deleted: false });
        }
      }
    }

    trimFriendCache();

    if (DEBUG && (Date.now() % 5000) < 1000) {
      dbg('sidebarTick: scanned', rows.length, 'rows, flips:', flipsThisTick,
          ', tracked friends:', friendPreviewCache.size);
    }
  }

  /**
   * Diagnostic helper. Run `__bettersnap_diagnoseSidebar()` in the page
   * console to see which rows/friends/previews the detector currently sees —
   * handy for confirming off-chat capture works against Snapchat's live DOM.
   */
  window.__bettersnap_diagnoseSidebar = () => {
    const rows = collectConversationRows();
    console.log(TAG, 'diagnose: found', rows.length, 'candidate rows');
    rows.forEach((r, i) => {
      console.log(TAG, '#' + i,
        '\n  friend :', getRowFriendName(r) || '(none)',
        '\n  preview:', getRowPreviewText(r) || '(none)',
        '\n  tomb?  :', SIDEBAR_DELETED_RE.test(r.textContent || ''),
        '\n  text   :', (r.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 140));
    });
    return rows.length;
  };

  function start() {
    if (!document.body) { requestAnimationFrame(start); return; }
    mediaObserver.observe(document.body, {
      subtree: true, childList: true,
      attributes: true, attributeFilter: ['src'],
    });
    textNodeObserver.observe(document.body, {
      subtree: true,
      characterData: true,
      characterDataOldValue: true,
    });
    childObserver.observe(document.body, {
      subtree: true,
      childList: true,
    });
    scanAllMedia(document);
    installUI();
    setInterval(pollTick, POLL_MS);
    setInterval(sidebarTick, 1000);
    console.log(`${TAG} v13 running (debug=${DEBUG}). Off-chat detection active. ` +
                `Run __bettersnap_diagnoseSidebar() to inspect sidebar parsing.`);
  }

  /* ---------- UI ---------- */

  function bumpBadge(count) {
    const pill = document.getElementById('bettersnap-dml-pill');
    if (pill) pill.querySelector('.bs-dml-count').textContent = String(count);
  }

  function installUI() {
    if (document.getElementById('bettersnap-dml-pill')) return;
    const pill = document.createElement('div');
    pill.id = 'bettersnap-dml-pill';
    pill.innerHTML =
      '<span class="bs-dml-dot"></span>' +
      '<span class="bs-dml-label">Deleted</span>' +
      '<span class="bs-dml-count">0</span>';
    Object.assign(pill.style, {
      position: 'fixed', right: '16px', bottom: '16px',
      zIndex: '2147483646', background: 'rgba(20,20,20,.92)',
      color: '#fffc00',
      font: '600 12px -apple-system,Segoe UI,Roboto,sans-serif',
      padding: '8px 12px', borderRadius: '999px', cursor: 'pointer',
      display: 'flex', gap: '8px', alignItems: 'center',
      boxShadow: '0 4px 16px rgba(0,0,0,.4)', userSelect: 'none',
    });
    pill.querySelector('.bs-dml-dot').style.cssText =
      'width:8px;height:8px;border-radius:50%;background:#fffc00;box-shadow:0 0 8px #fffc00;';
    pill.addEventListener('click', togglePanel);
    document.body.appendChild(pill);

    loadList((list) => bumpBadge(list.length));

    window.addEventListener('keydown', (e) => {
      if (e.ctrlKey && e.shiftKey && (e.key === 'L' || e.key === 'l')) {
        e.preventDefault(); togglePanel();
      }
    });
  }

  function togglePanel() {
    const existing = document.getElementById('bettersnap-dml-panel');
    if (existing) { existing.remove(); return; }
    loadList(renderPanel);
  }

  function renderPanel(list) {
    const panel = document.createElement('div');
    panel.id = 'bettersnap-dml-panel';
    Object.assign(panel.style, {
      position: 'fixed', right: '16px', bottom: '60px',
      width: '420px', maxHeight: '75vh', overflow: 'auto',
      zIndex: '2147483647',
      background: '#1a1a1a', color: '#eee',
      font: '13px -apple-system,Segoe UI,Roboto,sans-serif',
      borderRadius: '12px', padding: '12px',
      boxShadow: '0 8px 32px rgba(0,0,0,.6)',
      border: '1px solid #333',
    });

    const header = document.createElement('div');
    header.style.cssText =
      'display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;gap:6px;';
    const title = document.createElement('div');
    title.style.cssText = 'font-weight:700;color:#fffc00;';
    title.textContent = 'Deleted messages (' + list.length + ')';
    header.appendChild(title);

    const btnRow = document.createElement('div');
    btnRow.style.cssText = 'display:flex;gap:6px;flex-wrap:wrap;';

    const debugBtn = document.createElement('button');
    debugBtn.textContent = DEBUG ? 'Debug: ON' : 'Debug: OFF';
    styleSmallBtn(debugBtn);
    debugBtn.style.background = DEBUG ? '#4a3a00' : '#2a2a2a';
    debugBtn.onclick = () => {
      DEBUG = !DEBUG;
      try { localStorage.setItem(DEBUG_KEY, DEBUG ? '1' : '0'); } catch (_) {}
      debugBtn.textContent = DEBUG ? 'Debug: ON' : 'Debug: OFF';
      debugBtn.style.background = DEBUG ? '#4a3a00' : '#2a2a2a';
    };

    const exportBtn = document.createElement('button');
    exportBtn.textContent = 'Export';
    styleSmallBtn(exportBtn);
    exportBtn.onclick = () => downloadJson(list);

    const clearBtn = document.createElement('button');
    clearBtn.textContent = 'Clear';
    styleSmallBtn(clearBtn);
    clearBtn.onclick = () => { saveList([], () => { bumpBadge(0); panel.remove(); }); };

    btnRow.appendChild(debugBtn);
    btnRow.appendChild(exportBtn);
    btnRow.appendChild(clearBtn);
    header.appendChild(btnRow);
    panel.appendChild(header);

    const info = document.createElement('div');
    info.style.cssText = 'font-size:11px;opacity:.6;margin-bottom:8px;line-height:1.5;';
    info.textContent = 'Auto-detects Snapchat "DELETED A CHAT/SNAP" tombstones, ' +
      'in the open chat and in the sidebar for chats you are not viewing. No setup required.';
    panel.appendChild(info);

    if (!list.length) {
      const empty = document.createElement('div');
      empty.textContent = 'No deleted messages captured yet.';
      empty.style.cssText = 'opacity:.7;padding:12px 0;';
      panel.appendChild(empty);
    } else {
      for (let i = list.length - 1; i >= 0; i--) {
        panel.appendChild(renderEntry(list[i]));
      }
    }
    document.body.appendChild(panel);
  }

  function styleSmallBtn(b) {
    b.style.cssText =
      'background:#2a2a2a;color:#eee;border:1px solid #444;' +
      'padding:4px 10px;border-radius:6px;cursor:pointer;font-size:12px;';
  }

  function renderEntry(entry) {
    const row = document.createElement('div');
    row.style.cssText =
      'padding:8px 10px;margin-bottom:6px;background:#222;' +
      'border-left:3px solid #fffc00;border-radius:6px;word-break:break-word;';
    const d = new Date(entry.timestamp);
    const meta = document.createElement('div');
    meta.style.cssText = 'font-size:11px;opacity:.6;margin-bottom:4px;';
    meta.textContent = d.toLocaleString() + (entry.context ? ' — ' + entry.context : '');
    const body = document.createElement('div');
    body.textContent = entry.text || '(media only)';
    row.appendChild(meta);
    row.appendChild(body);

    if (entry.tombstone) {
      const tomb = document.createElement('div');
      tomb.style.cssText = 'font-size:11px;opacity:.5;margin-top:4px;font-style:italic;';
      tomb.textContent = 'Tombstone: ' + entry.tombstone;
      row.appendChild(tomb);
    }
    if (entry.media && entry.media.length) {
      const mediaBox = document.createElement('div');
      mediaBox.style.cssText = 'display:flex;flex-wrap:wrap;gap:4px;margin-top:6px;';
      entry.media.forEach((m) => {
        if (m.kind === 'img') {
          const img = document.createElement('img');
          img.src = m.data || m.src;
          img.style.cssText = 'max-width:120px;max-height:120px;border-radius:4px;cursor:pointer;';
          img.onclick = () => window.open(img.src, '_blank');
          mediaBox.appendChild(img);
        } else if (m.kind === 'video') {
          const vid = document.createElement('video');
          vid.src = m.data || m.src;
          vid.controls = true;
          vid.style.cssText = 'max-width:200px;max-height:200px;border-radius:4px;';
          mediaBox.appendChild(vid);
        }
      });
      row.appendChild(mediaBox);
    }
    return row;
  }

  function downloadJson(list) {
    const blob = new Blob([JSON.stringify(list, null, 2)], { type: 'application/json' });
    const url  = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'bettersnap-deleted-' + Date.now() + '.json';
    document.body.appendChild(a); a.click();
    setTimeout(() => { URL.revokeObjectURL(url); a.remove(); }, 100);
  }

  /* ---------- boot ---------- */
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, { once: true });
  } else {
    start();
  }
})();
