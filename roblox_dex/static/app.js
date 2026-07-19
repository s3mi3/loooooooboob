const state = {
  token: "",
  sessionId: null,
  selectedPath: null,
  expanded: new Set(["game"]),
  childrenCache: new Map(),
  connected: false,
};

const el = {
  connectionPill: document.getElementById("connection-pill"),
  connectionText: document.getElementById("connection-text"),
  tree: document.getElementById("tree"),
  treeEmpty: document.getElementById("tree-empty"),
  treeMeta: document.getElementById("tree-meta"),
  props: document.getElementById("props"),
  propsEmpty: document.getElementById("props-empty"),
  propsMeta: document.getElementById("props-meta"),
  selectedPath: document.getElementById("selected-path"),
  btnCopyPath: document.getElementById("btn-copy-path"),
  btnRefresh: document.getElementById("btn-refresh"),
  btnCopyToken: document.getElementById("btn-copy-token"),
  authToken: document.getElementById("auth-token"),
  bridgeUrl: document.getElementById("bridge-url"),
  searchInput: document.getElementById("search-input"),
  sessionList: document.getElementById("session-list"),
  log: document.getElementById("log"),
};

const CLASS_COLORS = {
  Workspace: "#6ec1ff",
  Players: "#f0c35a",
  ReplicatedStorage: "#9bdf8a",
  ServerStorage: "#7ec8a3",
  ServerScriptService: "#e08b6c",
  StarterGui: "#c79bff",
  StarterPlayer: "#86c5d8",
  Lighting: "#f2e28a",
  SoundService: "#d28ad8",
  Part: "#a8b4c0",
  MeshPart: "#a8b4c0",
  Model: "#7eb6ff",
  Folder: "#d2b48c",
  LocalScript: "#79d2c8",
  Script: "#79a8d2",
  ModuleScript: "#8f9ad2",
  RemoteEvent: "#e07a7a",
  RemoteFunction: "#e0a07a",
  BindableEvent: "#c9a06a",
  Humanoid: "#ef9aa8",
  default: "#8b9aab",
};

function log(message, kind = "") {
  const line = document.createElement("div");
  if (kind) line.className = kind;
  const ts = new Date().toLocaleTimeString();
  line.textContent = `[${ts}] ${message}`;
  el.log.prepend(line);
}

async function api(path, options = {}) {
  const headers = {
    "Content-Type": "application/json",
    ...(options.headers || {}),
  };
  if (state.token) headers.Authorization = `Bearer ${state.token}`;
  const res = await fetch(path, { ...options, headers });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(text || res.statusText);
  }
  return res.json();
}

async function runCommand(body) {
  return api("/api/command", {
    method: "POST",
    body: JSON.stringify({
      session_id: state.sessionId,
      ...body,
    }),
  });
}

function setConnected(online, label) {
  state.connected = online;
  el.connectionPill.classList.toggle("online", online);
  el.connectionPill.classList.toggle("offline", !online);
  el.connectionText.textContent = label;
  el.treeEmpty.hidden = online;
}

function colorFor(className) {
  return CLASS_COLORS[className] || CLASS_COLORS.default;
}

async function loadConfig() {
  const cfg = await api("/api/config");
  state.token = cfg.auth_token;
  el.authToken.value = cfg.auth_token;
  el.bridgeUrl.value = `${location.origin}/bridge/poll`;
}

async function refreshSessions() {
  try {
    const data = await api("/api/sessions");
    const sessions = data.sessions || [];
    const live = sessions.filter((s) => s.connected);
    el.sessionList.innerHTML = "";

    if (live.length === 0) {
      setConnected(false, "Waiting for game…");
      el.treeMeta.textContent = "";
      return false;
    }

    const primary = live.sort((a, b) => b.last_seen - a.last_seen)[0];
    state.sessionId = primary.session_id;
    const place = primary.place_name || `Place ${primary.place_id ?? "?"}`;
    const mode = primary.studio ? "Studio" : "Live";
    setConnected(true, `${place} · ${mode}`);
    el.treeMeta.textContent = `${live.length} session${live.length === 1 ? "" : "s"}`;

    for (const s of live) {
      const card = document.createElement("button");
      card.type = "button";
      card.className = "session-card";
      card.innerHTML = `<strong>${escapeHtml(s.place_name || "Untitled place")}</strong>
        <span class="muted">${s.studio ? "Studio" : "Server"} · id ${s.place_id ?? "?"} · players ${s.player_count ?? "?"}</span>`;
      card.addEventListener("click", async () => {
        state.sessionId = s.session_id;
        state.childrenCache.clear();
        await bootstrapTree();
        log(`Switched to session ${s.session_id.slice(0, 8)}…`, "ok");
      });
      el.sessionList.appendChild(card);
    }
    return true;
  } catch (err) {
    setConnected(false, "API error");
    log(String(err.message || err), "err");
    return false;
  }
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

async function getChildren(path) {
  if (state.childrenCache.has(path)) {
    return state.childrenCache.get(path);
  }
  const result = await runCommand({ op: "get_children", path });
  if (!result.ok) throw new Error(result.error || "get_children failed");
  const nodes = result.data?.children || [];
  state.childrenCache.set(path, nodes);
  return nodes;
}

async function bootstrapTree() {
  if (!state.connected) {
    el.tree.innerHTML = "";
    return;
  }
  state.childrenCache.clear();
  const result = await runCommand({ op: "list_services" });
  if (!result.ok) {
    log(result.error || "list_services failed", "err");
    return;
  }
  const services = result.data?.services || [];
  state.childrenCache.set("game", services);
  state.expanded.add("game");
  renderTree();
  if (!state.selectedPath && services[0]) {
    await selectNode(services[0]);
  }
}

function renderTree() {
  el.tree.innerHTML = "";
  const root = document.createElement("div");
  root.className = "tree-node";
  root.appendChild(
    renderRow({
      name: "game",
      class_name: "DataModel",
      path: "game",
      has_children: true,
      child_count: (state.childrenCache.get("game") || []).length,
    }, 0)
  );
  const kids = document.createElement("div");
  kids.className = "tree-children";
  kids.appendChild(renderChildren("game"));
  root.appendChild(kids);
  el.tree.appendChild(root);
}

function renderChildren(path) {
  const frag = document.createDocumentFragment();
  const nodes = state.childrenCache.get(path) || [];
  for (const node of nodes) {
    frag.appendChild(renderNode(node));
  }
  return frag;
}

function renderNode(node) {
  const wrap = document.createElement("div");
  wrap.className = "tree-node";
  wrap.dataset.path = node.path;
  wrap.appendChild(renderRow(node));
  if (state.expanded.has(node.path) && node.has_children) {
    const kids = document.createElement("div");
    kids.className = "tree-children";
    if (state.childrenCache.has(node.path)) {
      kids.appendChild(renderChildren(node.path));
    } else {
      kids.innerHTML = `<div class="muted" style="padding:0.25rem 0.5rem">Loading…</div>`;
      getChildren(node.path)
        .then(() => renderTree())
        .catch((err) => log(String(err.message || err), "err"));
    }
    wrap.appendChild(kids);
  }
  return wrap;
}

function renderRow(node) {
  const row = document.createElement("div");
  row.className = "tree-row" + (state.selectedPath === node.path ? " selected" : "");
  row.setAttribute("role", "treeitem");
  row.tabIndex = 0;

  const twist = document.createElement("button");
  twist.type = "button";
  twist.className = "twist" + (node.has_children ? "" : " hidden");
  twist.textContent = state.expanded.has(node.path) ? "▼" : "▶";
  twist.addEventListener("click", async (ev) => {
    ev.stopPropagation();
    if (state.expanded.has(node.path)) {
      state.expanded.delete(node.path);
    } else {
      state.expanded.add(node.path);
      try {
        await getChildren(node.path);
      } catch (err) {
        log(String(err.message || err), "err");
      }
    }
    renderTree();
  });

  const dot = document.createElement("span");
  dot.className = "class-dot";
  dot.style.background = colorFor(node.class_name);

  const label = document.createElement("span");
  label.textContent = node.name;

  const cls = document.createElement("span");
  cls.className = "class-name";
  cls.textContent = node.class_name;

  row.append(twist, dot, label, cls);
  row.addEventListener("click", () => selectNode(node));
  row.addEventListener("keydown", (ev) => {
    if (ev.key === "Enter" || ev.key === " ") {
      ev.preventDefault();
      selectNode(node);
    }
  });
  return row;
}

async function selectNode(node) {
  state.selectedPath = node.path;
  el.selectedPath.textContent = node.path;
  el.btnCopyPath.disabled = false;
  el.propsMeta.textContent = node.class_name;
  renderTree();
  el.propsEmpty.hidden = true;
  el.props.innerHTML = `<div class="muted" style="padding:0.75rem">Loading properties…</div>`;

  try {
    const result = await runCommand({ op: "get_properties", path: node.path });
    if (!result.ok) throw new Error(result.error || "get_properties failed");
    renderProperties(result.data?.properties || []);
  } catch (err) {
    el.props.innerHTML = `<div class="empty-state">${escapeHtml(err.message || err)}</div>`;
    log(String(err.message || err), "err");
  }
}

function renderProperties(properties) {
  if (!properties.length) {
    el.props.innerHTML = `<div class="empty-state subtle">No readable properties.</div>`;
    return;
  }
  const table = document.createElement("table");
  table.className = "props-table";
  table.innerHTML = `<thead><tr><th>Name</th><th>Type</th><th>Value</th></tr></thead>`;
  const tbody = document.createElement("tbody");

  for (const prop of properties) {
    const tr = document.createElement("tr");
    const valueCell = document.createElement("td");
    valueCell.className = "prop-value";

    if (prop.editable && !prop.readonly) {
      const input = document.createElement("input");
      input.value = formatValue(prop.value);
      input.title = "Press Enter to apply";
      input.addEventListener("keydown", async (ev) => {
        if (ev.key !== "Enter") return;
        ev.preventDefault();
        await setProperty(prop.name, coerceValue(input.value, prop.type_name, prop.value));
      });
      valueCell.appendChild(input);
    } else {
      valueCell.textContent = formatValue(prop.value);
    }

    tr.innerHTML = `
      <td class="prop-name">${escapeHtml(prop.name)}</td>
      <td class="prop-type">${escapeHtml(prop.type_name)}</td>
    `;
    tr.appendChild(valueCell);
    tbody.appendChild(tr);
  }
  table.appendChild(tbody);
  el.props.innerHTML = "";
  el.props.appendChild(table);
}

function formatValue(value) {
  if (value === null || value === undefined) return "nil";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

function coerceValue(raw, typeName, original) {
  const t = (typeName || "").toLowerCase();
  if (t === "boolean" || typeof original === "boolean") {
    return ["true", "1", "yes", "on"].includes(raw.toLowerCase());
  }
  if (t === "number" || t === "int" || t === "float" || typeof original === "number") {
    const n = Number(raw);
    if (Number.isNaN(n)) throw new Error("Invalid number");
    return n;
  }
  if (t.includes("vector3")) {
    const parts = raw.replace(/[^\d.\s,-]/g, "").split(/[,\s]+/).filter(Boolean).map(Number);
    if (parts.length !== 3 || parts.some(Number.isNaN)) throw new Error("Vector3 needs 3 numbers");
    return { x: parts[0], y: parts[1], z: parts[2], __type: "Vector3" };
  }
  if (t.includes("color3")) {
    const parts = raw.replace(/[^\d.\s,-]/g, "").split(/[,\s]+/).filter(Boolean).map(Number);
    if (parts.length !== 3 || parts.some(Number.isNaN)) throw new Error("Color3 needs 3 numbers");
    return { r: parts[0], g: parts[1], b: parts[2], __type: "Color3" };
  }
  return raw;
}

async function setProperty(propertyName, value) {
  try {
    const result = await runCommand({
      op: "set_property",
      path: state.selectedPath,
      property_name: propertyName,
      value,
    });
    if (!result.ok) throw new Error(result.error || "set_property failed");
    log(`Set ${propertyName} on ${state.selectedPath}`, "ok");
    state.childrenCache.clear();
    await selectNode({ path: state.selectedPath, class_name: el.propsMeta.textContent, name: "" });
  } catch (err) {
    log(String(err.message || err), "err");
  }
}

let searchTimer = null;
el.searchInput.addEventListener("input", () => {
  clearTimeout(searchTimer);
  const query = el.searchInput.value.trim();
  searchTimer = setTimeout(async () => {
    if (!query) {
      if (state.connected) await bootstrapTree();
      return;
    }
    if (!state.connected) return;
    try {
      const result = await runCommand({ op: "search", query, limit: 80 });
      if (!result.ok) throw new Error(result.error || "search failed");
      const matches = result.data?.matches || [];
      el.tree.innerHTML = "";
      const header = document.createElement("div");
      header.className = "muted";
      header.style.padding = "0.4rem 0.55rem";
      header.textContent = `${matches.length} match${matches.length === 1 ? "" : "es"}`;
      el.tree.appendChild(header);
      for (const node of matches) {
        el.tree.appendChild(renderNode({ ...node, has_children: false }));
      }
    } catch (err) {
      log(String(err.message || err), "err");
    }
  }, 280);
});

el.btnRefresh.addEventListener("click", async () => {
  state.childrenCache.clear();
  const online = await refreshSessions();
  if (online) await bootstrapTree();
  log("Refreshed", "ok");
});

el.btnCopyPath.addEventListener("click", async () => {
  if (!state.selectedPath) return;
  await navigator.clipboard.writeText(state.selectedPath);
  log("Path copied", "ok");
});

el.btnCopyToken.addEventListener("click", async () => {
  await navigator.clipboard.writeText(el.authToken.value);
  log("Token copied", "ok");
});

async function tick() {
  const wasConnected = state.connected;
  const online = await refreshSessions();
  if (online && !wasConnected) {
    log("Bridge connected", "ok");
    await bootstrapTree();
  }
  if (!online && wasConnected) {
    log("Bridge disconnected", "err");
    el.tree.innerHTML = "";
  }
}

async function init() {
  try {
    await loadConfig();
    await tick();
    setInterval(tick, 2000);
  } catch (err) {
    log(String(err.message || err), "err");
  }
}

init();
