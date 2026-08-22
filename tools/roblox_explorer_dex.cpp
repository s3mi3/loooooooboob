// ============================================================================
//  Roblox Explorer (Dear ImGui)
//  ---------------------------------------------------------------------------
//  Content-only module: renders inside the main-window ImGui context/frame.
//  Public entry points (called from main UI):
//    - Dex_DrawContent()        -- renders the entire Dex UI inside the caller's
//                                  current ImGui window (call between Begin/End
//                                  or in your own child region).
//    - Dex_IsVisible()          -- whether the dex tab/panel should show.
//    - Dex_SetVisible(bool)     -- show/hide the dex panel.
//    - Dex_Shutdown()           -- stop worker, close the Roblox handle.
//    - ShowRobloxExplorer(HINST)-- back-compat: just flips visibility on.
//    - RbxExplorer_RequestShutdown() -- back-compat alias for Dex_Shutdown().
//
//  Offsets: theo's offsets (offsets.imtheo.lol)
// ============================================================================
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <string>
#include <vector>
#include <atomic>
#include <mutex>
#include <thread>
#include <algorithm>

#include "imgui.h"

#pragma comment(lib, "psapi.lib")

// ---------------------------------------------------------------------------
// Roblox memory helpers
// ---------------------------------------------------------------------------
namespace rbx {

namespace off {
    // theo's offsets - version-ddf602d9cfe44005 (dumped 11/08/2026)
    constexpr uintptr_t FakeDataModel_Ptr    = 0x8B79B58; // 146250584 (RVA from module base)
    constexpr uintptr_t FakeDataModel_RealDM = 0x1D8;     // 472
    // Instance layout (2026 Roblox: Name lives inside a NameContainer object).
    //   NameContainer = *(Instance + 0x70)
    //   name string   = NameContainer + 0x08
    constexpr uintptr_t Inst_NameContainer     = 0x70;  // 112
    constexpr uintptr_t Inst_Name              = 0x08;  // 8   (offset *inside* NameContainer)
    constexpr uintptr_t Inst_ClassDescriptor   = 0x18;  // 24
    constexpr uintptr_t ClassDesc_Name         = 0x08;  // std::string inside descriptor
    constexpr uintptr_t Inst_ChildrenStart     = 0x78;  // 120
    constexpr uintptr_t Inst_ChildrenEndDelta  = 0x08;  // end ptr = ChildrenStart + 8
    constexpr uintptr_t Inst_Parent            = 0x68;  // 104

    // ---- GUI (GuiBase2D / GuiObject) -------------------------------------
    // theo's offsets - version-ddf602d9cfe44005 (dumped 11/08/2026).
    // NOTE: these are a NEWER dump than the instance offsets above
    // (version-d584fb6c...). If AbsoluteSize doesn't match the element's real
    // on-screen pixel size, the Roblox build moved; re-grab from
    // offsets.imtheo.lol (keys: GuiBase2D / GuiObject) or use the "GUI raw
    // floats" scanner in the property panel to find them by eye.
    //
    // AbsolutePosition/AbsoluteSize live on GuiBase2D, the base class of every
    // 2D GUI object, so they are valid for Frame/ImageLabel/TextLabel/etc.
    constexpr uintptr_t Gui_AbsolutePosition   = 0x10C; // 268  Vector2 (screen px, top-left)
    constexpr uintptr_t Gui_AbsoluteSize       = 0x114; // 276  Vector2 (screen px, w/h)
    constexpr uintptr_t Gui_AbsoluteRotation   = 0x0E8; // 232  float
    constexpr uintptr_t Gui_Position           = 0x510; // 1296 UDim2 (Xs,Xo,Ys,Yo)
    constexpr uintptr_t Gui_Size               = 0x530; // 1328 UDim2
    constexpr uintptr_t Gui_Rotation           = 0x0E8; // 232  float
    constexpr uintptr_t Gui_Visible            = 0x5AD; // 1453 bool
    constexpr uintptr_t Gui_ZIndex             = 0x5A4; // 1444 int
    constexpr uintptr_t Gui_LayoutOrder        = 0x580; // 1408 int
    constexpr uintptr_t Gui_BackgroundColor3   = 0x540; // 1344 Color3 (3 floats 0..1)
    constexpr uintptr_t Gui_BackgroundTransp   = 0x54C; // 1356 float
    constexpr uintptr_t Gui_Text               = 0xDF8; // 3576 string (TextLabel/Button/Box)
    constexpr uintptr_t Gui_TextColor3         = 0xEA8; // 3752 Color3
    constexpr uintptr_t Gui_RichText           = 0xB88; // 2952 bool
    constexpr uintptr_t Gui_Image              = 0x988; // 2440 string (ImageLabel/Button)
    constexpr uintptr_t ScreenGui_Enabled      = 0x4C4; // 1220 bool
}

static HANDLE       g_hProc      = NULL;
static uintptr_t    g_moduleBase = 0;
static uintptr_t    g_dataModel  = 0;
static std::string  g_procName   = "RobloxPlayerBeta.exe";

template<typename T>
static inline bool R(uintptr_t a, T& v) {
    if (!g_hProc || !a) return false;
    SIZE_T rd = 0;
    return ReadProcessMemory(g_hProc, (LPCVOID)a, &v, sizeof(T), &rd) && rd == sizeof(T);
}

// Raw N-byte read helper.
static bool rpm_bytes(uintptr_t addr, void* out, size_t n) {
    if (!g_hProc || !addr) return false;
    SIZE_T rd = 0;
    return ReadProcessMemory(g_hProc, (LPCVOID)addr, out, n, &rd) && rd == n;
}

// Read a null-terminated ASCII/UTF-8 C-string of at most `maxLen` bytes.
static std::string rpm_cstring(uintptr_t addr, size_t maxLen = 256) {
    if (!g_hProc || !addr) return {};
    std::string out;
    out.reserve(64);
    char chunk[64];
    while (out.size() < maxLen) {
        SIZE_T rd = 0;
        size_t want = std::min<size_t>(sizeof(chunk), maxLen - out.size());
        if (!ReadProcessMemory(g_hProc, (LPCVOID)(addr + out.size()), chunk, want, &rd) || rd == 0)
            break;
        for (SIZE_T i = 0; i < rd; ++i) {
            if (chunk[i] == 0) return out;
            unsigned char c = (unsigned char)chunk[i];
            if (c < 0x20 && c != '\t' && c != '\n') return {}; // not a printable string
            out.push_back((char)c);
        }
    }
    return out;
}

// Try to interpret a memory region as a std::string using MSVC's SSO layout:
//   { union { char sso[16]; char* ptr; }; size_t size; size_t cap; }  (32 bytes)
// Returns empty on failure. Very defensive - anything that doesn't look sane returns {}.
static std::string try_read_msvc_string_at(uintptr_t addr) {
    if (!g_hProc || !addr) return {};
    uint8_t buf[32] = {};
    if (!rpm_bytes(addr, buf, 32)) return {};
    uint64_t size = 0, cap = 0;
    memcpy(&size, buf + 16, 8);
    memcpy(&cap,  buf + 24, 8);
    if (size == 0 || size > 4096) return {};
    if (cap < size)              return {};        // capacity must be >= size
    if (cap > (1ULL << 32))      return {};        // capacity absurd
    if (cap >= 16) {
        uintptr_t ptr = 0;
        memcpy(&ptr, buf, 8);
        if (!ptr) return {};
        std::string s((size_t)size, '\0');
        SIZE_T rd = 0;
        if (!ReadProcessMemory(g_hProc, (LPCVOID)ptr, s.data(), (SIZE_T)size, &rd) || rd != (SIZE_T)size)
            return {};
        // Validate: must be printable-ish.
        for (char c : s) {
            unsigned char u = (unsigned char)c;
            if (u < 0x20 && u != '\t' && u != '\n') return {};
        }
        return s;
    }
    // SSO
    std::string s((const char*)buf, (size_t)size);
    for (char c : s) {
        unsigned char u = (unsigned char)c;
        if (u < 0x20 && u != '\t' && u != '\n') return {};
    }
    return s;
}

// Multi-strategy string reader. Tries:
//   1) MSVC std::string at addr
//   2) pointer at addr -> MSVC std::string at *addr
//   3) pointer at addr -> null-terminated C-string at *addr
//   4) null-terminated C-string at addr (raw inline)
// First non-empty result wins.
static std::string rpm_string(uintptr_t addr) {
    if (!g_hProc || !addr) return {};
    std::string s;
    s = try_read_msvc_string_at(addr);         if (!s.empty()) return s;
    uintptr_t p = 0;
    if (R(addr, p) && p) {
        s = try_read_msvc_string_at(p);        if (!s.empty()) return s;
        s = rpm_cstring(p, 256);               if (!s.empty()) return s;
    }
    s = rpm_cstring(addr, 256);                if (!s.empty()) return s;
    return {};
}

static DWORD find_pid(const std::string& procName) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W pe = {}; pe.dwSize = sizeof(pe);
    DWORD pid = 0;
    if (Process32FirstW(snap, &pe)) {
        do {
            char cvt[MAX_PATH] = {};
            WideCharToMultiByte(CP_UTF8, 0, pe.szExeFile, -1, cvt, MAX_PATH, NULL, NULL);
            if (_stricmp(cvt, procName.c_str()) == 0) { pid = pe.th32ProcessID; break; }
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return pid;
}

static uintptr_t get_module_base(HANDLE hProc, const std::string& modName) {
    HMODULE mods[1024]; DWORD cb = 0;
    if (!EnumProcessModulesEx(hProc, mods, sizeof(mods), &cb, LIST_MODULES_ALL)) return 0;
    int count = (int)(cb / sizeof(HMODULE));
    wchar_t nameBuf[MAX_PATH];
    char cvt[MAX_PATH];
    for (int i = 0; i < count; ++i) {
        if (GetModuleBaseNameW(hProc, mods[i], nameBuf, MAX_PATH)) {
            WideCharToMultiByte(CP_UTF8, 0, nameBuf, -1, cvt, MAX_PATH, NULL, NULL);
            if (_stricmp(cvt, modName.c_str()) == 0) return (uintptr_t)mods[i];
        }
    }
    return 0;
}

// One-char icon glyph for a class name (uses default ImGui font). Kept ASCII
// so no icon-font dependency is required.
static const char* class_icon(const std::string& cls) {
    if (cls.empty()) return "?";
    // Value types
    if (cls == "IntValue" || cls == "NumberValue" || cls == "DoubleConstrainedValue") return "#";
    if (cls == "StringValue")   return "\"";
    if (cls == "BoolValue")     return "!";
    if (cls == "ObjectValue" || cls == "CFrameValue" || cls == "Vector3Value" ||
        cls == "Color3Value"   || cls == "BrickColorValue" || cls == "RayValue")    return "*";
    // Containers
    if (cls == "Folder" || cls == "Configuration" || cls == "Backpack" ||
        cls == "StarterGear" || cls == "PlayerScripts" || cls == "PlayerGui" ||
        cls == "StarterPlayer" || cls == "StarterPlayerScripts" || cls == "StarterCharacterScripts")
        return "[F]";
    if (cls == "Model")         return "[M]";
    if (cls == "Tool" || cls == "HopperBin") return "[T]";
    // Parts
    if (cls == "Part" || cls == "MeshPart" || cls == "UnionOperation" ||
        cls == "WedgePart" || cls == "TrussPart" || cls == "CornerWedgePart" ||
        cls == "SpawnLocation" || cls == "Seat" || cls == "VehicleSeat" ||
        cls == "BasePart")      return "[P]";
    // Scripts
    if (cls == "Script")        return "S";
    if (cls == "LocalScript")   return "L";
    if (cls == "ModuleScript")  return "M";
    // Characters / players
    if (cls == "Player")        return "P";
    if (cls == "Humanoid")      return "H";
    // Services
    if (cls == "Workspace" || cls == "Players" || cls == "Lighting" ||
        cls == "ReplicatedStorage" || cls == "ReplicatedFirst" ||
        cls == "ServerStorage" || cls == "ServerScriptService" ||
        cls == "StarterPack"   || cls == "SoundService" ||
        cls == "Chat"          || cls == "CoreGui" || cls == "CorePackages")
        return "[S]";
    return "-";
}

static std::string get_name(uintptr_t inst)  {
    // 2026 Roblox: name lives in a separate NameContainer object.
    //   NameContainer = *(Instance + Inst_NameContainer)
    //   name string   = NameContainer + Inst_Name
    uintptr_t container = 0;
    if (!R(inst + off::Inst_NameContainer, container) || !container) return {};
    return rpm_string(container + off::Inst_Name);
}
static std::string get_class(uintptr_t inst) {
    uintptr_t desc = 0;
    if (!R(inst + off::Inst_ClassDescriptor, desc) || !desc) return {};
    return rpm_string(desc + off::ClassDesc_Name);
}

// True if `child` is a real Instance whose Parent points back to `parent`.
// This is the reliable filter that removes control-block / iterator pointers
// which sit next to real children in some Roblox container layouts.
static bool is_real_child(uintptr_t child, uintptr_t parent) {
    if (!child || (child & 0x7) != 0) return false;
    // ClassDescriptor must be non-null for a real Instance.
    uintptr_t desc = 0;
    if (!R(child + off::Inst_ClassDescriptor, desc) || !desc) return false;
    // Parent back-pointer must match.
    uintptr_t p = 0;
    if (!R(child + off::Inst_Parent, p)) return false;
    return p == parent;
}

// Best-effort children reader. Roblox stores children as a std::vector<Instance*>-like
// range of 8-byte pointers between [start, end). Different builds/patterns encode where
// those two pointers live, so we try the common ones in order:
//
//   A) Direct in Instance:  start = *(inst+0x70), end = *(inst+0x78)
//   B) Indirect container:  container = *(inst+0x70), start = *(container+0), end = *(container+8)
//   C) shared_ptr indirect: vec = *(inst+0x78), start = *(vec+0), end = *(vec+8)
//
// We accept the first candidate whose [start, end) contains a plausible small (< 20k) number
// of 8-byte aligned pointers, and whose first few entries dereference to something that could
// be an Instance (readable memory at +0x18). We then filter to REAL children only using the
// Parent back-pointer test - this reliably strips out interleaved control-block pointers.
static std::vector<uintptr_t> get_children(uintptr_t inst) {
    std::vector<uintptr_t> out;
    if (!inst) return out;

    auto looks_like_instance = [](uintptr_t p) -> bool {
        if (!p || (p & 0x7) != 0) return false;
        uintptr_t desc = 0;
        return R(p + off::Inst_ClassDescriptor, desc) && desc != 0;
    };

    auto try_range = [&](uintptr_t start, uintptr_t end) -> bool {
        if (!start || end <= start) return false;
        uintptr_t bytes = end - start;
        if (bytes > (uintptr_t)(8 * 20000)) return false;
        if ((bytes & 0x7) != 0)             return false;
        size_t count = (size_t)(bytes / sizeof(uintptr_t));
        // Sanity check a few entries.
        size_t validated = 0;
        size_t toCheck   = count < 4 ? count : 4;
        for (size_t i = 0; i < toCheck; ++i) {
            uintptr_t child = 0;
            if (!R(start + i * sizeof(uintptr_t), child)) return false;
            if (looks_like_instance(child)) validated++;
        }
        if (toCheck > 0 && validated == 0) return false;

        std::vector<uintptr_t> raw;
        raw.reserve(count);
        for (size_t i = 0; i < count; ++i) {
            uintptr_t child = 0;
            if (!R(start + i * sizeof(uintptr_t), child)) break;
            if (child) raw.push_back(child);
        }
        // Filter to real children (Parent back-pointer must equal inst).
        // Also dedupe (some containers list the same child twice).
        std::vector<uintptr_t> filtered;
        filtered.reserve(raw.size());
        for (uintptr_t c : raw) {
            if (!is_real_child(c, inst)) continue;
            bool dup = false;
            for (uintptr_t e : filtered) if (e == c) { dup = true; break; }
            if (!dup) filtered.push_back(c);
        }
        if (filtered.empty()) return false;
        out = std::move(filtered);
        return true;
    };

    // A) direct start@0x70, end@0x78
    {
        uintptr_t start = 0, end = 0;
        if (R(inst + off::Inst_ChildrenStart, start) &&
            R(inst + off::Inst_ChildrenStart + off::Inst_ChildrenEndDelta, end)) {
            if (try_range(start, end)) return out;
        }
    }
    // B) indirect: container ptr at 0x70, start@container+0, end@container+8
    {
        uintptr_t container = 0;
        if (R(inst + off::Inst_ChildrenStart, container) && container) {
            uintptr_t start = 0, end = 0;
            if (R(container, start) && R(container + 8, end)) {
                if (try_range(start, end)) return out;
            }
        }
    }
    // C) shared_ptr-like: vec ptr at 0x78, start@vec+0, end@vec+8
    {
        uintptr_t vec = 0;
        if (R(inst + off::Inst_ChildrenStart + 8, vec) && vec) {
            uintptr_t start = 0, end = 0;
            if (R(vec, start) && R(vec + 8, end)) {
                if (try_range(start, end)) return out;
            }
        }
    }
    return out;
}

} // namespace rbx

// ---------------------------------------------------------------------------
// UI state
// ---------------------------------------------------------------------------
namespace {

struct Node {
    uintptr_t addr = 0;
    std::string name;
    std::string cls;
    bool loaded = false;        // children have been read
    std::vector<Node> kids;
};

enum class AttachState { Idle, Working, Attached, Failed };

struct UI {
    // Explorer state
    char        procNameBuf[128] = "RobloxPlayerBeta.exe";
    char        filterBuf[128]   = "";      // explorer name/class filter
    Node        root;                   // populated on attach
    uintptr_t   selected = 0;
    std::atomic<bool>  visible{false};  // whether Dex tab/panel is shown

    // Attach progress (owned by worker; read by UI thread)
    std::atomic<AttachState> attachState{AttachState::Idle};
    std::mutex               progressMtx;
    std::string              progressText;
    std::atomic<float>       progressFrac{0.0f};
    std::atomic<int>         progressCur{0};
    std::atomic<int>         progressTot{0};
    std::string              lastError;

    std::thread              worker;   // attach worker
};

static UI g;

static void set_progress(const char* text, float frac, int cur = 0, int tot = 0) {
    {
        std::lock_guard<std::mutex> lk(g.progressMtx);
        g.progressText = text ? text : "";
    }
    g.progressFrac.store(frac);
    g.progressCur.store(cur);
    g.progressTot.store(tot);
}

// ---------------------------------------------------------------------------
// Attach worker
// ---------------------------------------------------------------------------
static void attach_worker() {
    g.attachState.store(AttachState::Working);
    g.lastError.clear();

    if (rbx::g_hProc) { CloseHandle(rbx::g_hProc); rbx::g_hProc = nullptr; }
    rbx::g_moduleBase = 0;
    rbx::g_dataModel  = 0;
    rbx::g_procName   = g.procNameBuf;

    set_progress("Searching for process...", 0.05f);
    DWORD pid = rbx::find_pid(rbx::g_procName);
    if (!pid) { g.lastError = "Process '" + rbx::g_procName + "' not found."; g.attachState.store(AttachState::Failed); return; }

    set_progress("Opening process handle...", 0.15f);
    // PROCESS_QUERY_LIMITED_INFORMATION is much less likely to be flagged by
    // Roblox's Hyperion anti-cheat than PROCESS_QUERY_INFORMATION - the process
    // window would sometimes go white when the fuller flag was granted.
    rbx::g_hProc = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!rbx::g_hProc) {
        // Fall back to the fuller flag on older systems that don't accept the
        // limited variant. This should not normally be needed on Win8.1+.
        rbx::g_hProc = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, FALSE, pid);
    }
    if (!rbx::g_hProc) { g.lastError = "OpenProcess failed (need to run as admin?)"; g.attachState.store(AttachState::Failed); return; }

    set_progress("Resolving module base...", 0.30f);
    rbx::g_moduleBase = rbx::get_module_base(rbx::g_hProc, rbx::g_procName);
    if (!rbx::g_moduleBase) { g.lastError = "Module '" + rbx::g_procName + "' not loaded in process."; g.attachState.store(AttachState::Failed); return; }

    set_progress("Reading FakeDataModel pointer...", 0.50f);
    uintptr_t fakeDM = 0;
    if (!rbx::R(rbx::g_moduleBase + rbx::off::FakeDataModel_Ptr, fakeDM) || !fakeDM) {
        g.lastError = "FakeDataModel pointer null - offsets outdated.";
        g.attachState.store(AttachState::Failed); return;
    }

    set_progress("Reading DataModel...", 0.70f);
    if (!rbx::R(fakeDM + rbx::off::FakeDataModel_RealDM, rbx::g_dataModel) || !rbx::g_dataModel) {
        g.lastError = "DataModel null - offsets outdated.";
        g.attachState.store(AttachState::Failed); return;
    }

    set_progress("Loading root services...", 0.85f);
    Node r{};
    r.addr = rbx::g_dataModel;
    r.name = rbx::get_name(r.addr);
    r.cls  = rbx::get_class(r.addr);
    auto kids = rbx::get_children(r.addr);
    int total = (int)kids.size();
    r.kids.reserve(total);
    for (int i = 0; i < total; ++i) {
        Node c{};
        c.addr = kids[i];
        c.name = rbx::get_name(c.addr);
        c.cls  = rbx::get_class(c.addr);
        r.kids.push_back(std::move(c));
        set_progress("Loading services...", 0.85f + 0.15f * (float)(i+1)/(float)(total ? total : 1), i+1, total);
    }
    r.loaded = true;

    // Publish to UI
    g.root = std::move(r);
    g.selected = 0;
    set_progress("Attached.", 1.0f);
    g.attachState.store(AttachState::Attached);
}

static void kick_attach() {
    if (g.attachState.load() == AttachState::Working) return;
    if (g.worker.joinable()) g.worker.join();
    g.worker = std::thread(attach_worker);
}

// ---------------------------------------------------------------------------
// Lazy child load (synchronous - fast enough for one node)
// ---------------------------------------------------------------------------
static void ensure_loaded(Node& n) {
    if (n.loaded || !n.addr) return;
    auto kids = rbx::get_children(n.addr);
    n.kids.reserve(kids.size());
    for (uintptr_t k : kids) {
        Node c{};
        c.addr = k;
        c.name = rbx::get_name(k);
        c.cls  = rbx::get_class(k);
        n.kids.push_back(std::move(c));
    }
    n.loaded = true;
}

// ---------------------------------------------------------------------------
// Property panel (class-aware). Reads live values on each frame.
// ---------------------------------------------------------------------------
struct V3 { float x, y, z; };
struct V2 { float x, y; };
struct C3 { float r, g, b; };
struct UD2 { float xs; int32_t xo; float ys; int32_t yo; }; // UDim2 in memory

// Forward decl — defined further down in this file.
static void set_clipboard_text(const std::string& s);

// Emit one table row. `off` is the offset string ("0xEC", or "" for meta rows).
// The offset cell is a clickable ImGui::Selectable that copies its text to
// the clipboard so you can paste offsets straight into code / notes.
static void row(const char* n, const char* off, const char* v) {
    ImGui::TableNextRow();
    ImGui::TableSetColumnIndex(0); ImGui::TextUnformatted(n);

    ImGui::TableSetColumnIndex(1);
    if (off && *off) {
        ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.60f, 0.78f, 1.00f, 1.0f));
        // Unique id per row so multiple rows with the same offset text don't collide.
        char lbl[48]; snprintf(lbl, sizeof(lbl), "%s##%s", off, n);
        if (ImGui::Selectable(lbl, false, ImGuiSelectableFlags_DontClosePopups))
            set_clipboard_text(off);
        ImGui::PopStyleColor();
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip("Click to copy \"%s\"", off);
    } else {
        ImGui::TextDisabled("-");
    }

    ImGui::TableSetColumnIndex(2); ImGui::TextUnformatted(v);
}

// Format an offset (as unsigned integer) into "0x%X".
static inline void fmt_off(char* buf, size_t n, uintptr_t off) {
    snprintf(buf, n, "0x%llX", (unsigned long long)off);
}

static void rowF(const char* n, uintptr_t base, uintptr_t off) {
    float v; if (!rbx::R(base + off, v)) return;
    char b[64]; snprintf(b, 64, "%.4f", v);
    char o[16]; fmt_off(o, sizeof(o), off);
    row(n, o, b);
}
static void rowD(const char* n, uintptr_t base, uintptr_t off) {
    double v; if (!rbx::R(base + off, v)) return;
    char b[64]; snprintf(b, 64, "%.6f", v);
    char o[16]; fmt_off(o, sizeof(o), off);
    row(n, o, b);
}
static void rowI(const char* n, uintptr_t base, uintptr_t off) {
    int32_t v; if (!rbx::R(base + off, v)) return;
    char b[32]; snprintf(b, 32, "%d", v);
    char o[16]; fmt_off(o, sizeof(o), off);
    row(n, o, b);
}
static void rowB(const char* n, uintptr_t base, uintptr_t off) {
    uint8_t v; if (!rbx::R(base + off, v)) return;
    char o[16]; fmt_off(o, sizeof(o), off);
    row(n, o, v ? "true" : "false");
}
static void rowV3(const char* n, uintptr_t base, uintptr_t off) {
    V3 v; if (!rbx::R(base + off, v)) return;
    char b[96]; snprintf(b, 96, "%.3f, %.3f, %.3f", v.x, v.y, v.z);
    char o[16]; fmt_off(o, sizeof(o), off);
    row(n, o, b);
}
static void rowV2(const char* n, uintptr_t base, uintptr_t off) {
    V2 v; if (!rbx::R(base + off, v)) return;
    char b[64]; snprintf(b, 64, "%.1f, %.1f", v.x, v.y);
    char o[16]; fmt_off(o, sizeof(o), off);
    row(n, o, b);
}
static void rowColor3(const char* n, uintptr_t base, uintptr_t off) {
    C3 c; if (!rbx::R(base + off, c)) return;
    char b[96]; snprintf(b, 96, "%.3f, %.3f, %.3f  (rgb %d,%d,%d)",
        c.r, c.g, c.b, (int)(c.r * 255 + 0.5f), (int)(c.g * 255 + 0.5f), (int)(c.b * 255 + 0.5f));
    char o[16]; fmt_off(o, sizeof(o), off);
    row(n, o, b);
}
static void rowUDim2(const char* n, uintptr_t base, uintptr_t off) {
    UD2 u; if (!rbx::R(base + off, u)) return;
    char b[96]; snprintf(b, 96, "{%.3f, %d}, {%.3f, %d}", u.xs, u.xo, u.ys, u.yo);
    char o[16]; fmt_off(o, sizeof(o), off);
    row(n, o, b);
}
static void rowAddr(const char* n, uintptr_t base, uintptr_t off) {
    uintptr_t v; if (!rbx::R(base + off, v)) return;
    char b[32]; snprintf(b, 32, "0x%llX", (unsigned long long)v);
    char o[16]; fmt_off(o, sizeof(o), off);
    row(n, o, b);
}
static void rowStr(const char* n, uintptr_t base, uintptr_t off) {
    std::string s = rbx::rpm_string(base + off);
    char o[16]; fmt_off(o, sizeof(o), off);
    row(n, o, s.c_str());
}

static void draw_props(uintptr_t inst, const std::string& className) {
    if (!inst) { ImGui::TextDisabled("(no selection)"); return; }
    if (!ImGui::BeginTable("props", 3, ImGuiTableFlags_Borders | ImGuiTableFlags_RowBg |
                                       ImGuiTableFlags_Resizable | ImGuiTableFlags_ScrollY)) return;
    ImGui::TableSetupColumn("Property", ImGuiTableColumnFlags_WidthFixed, 180.0f);
    ImGui::TableSetupColumn("Offset",   ImGuiTableColumnFlags_WidthFixed, 70.0f);
    ImGui::TableSetupColumn("Value",    ImGuiTableColumnFlags_WidthStretch);
    ImGui::TableSetupScrollFreeze(0, 1);
    ImGui::TableHeadersRow();

    char b[64];
    snprintf(b, 64, "0x%llX", (unsigned long long)inst); row("Address", "", b);
    {
        // Name lives inside NameContainer now, so show the NameContainer offset
        // as the "primary" offset shown on the row.
        char o[16]; snprintf(o, 16, "0x%llX", (unsigned long long)rbx::off::Inst_NameContainer);
        row("Name", o, rbx::get_name(inst).c_str());
    }
    {
        char o[16]; snprintf(o, 16, "0x%llX", (unsigned long long)rbx::off::Inst_ClassDescriptor);
        row("ClassName", o, className.c_str());
    }
    rowAddr("Parent", inst, rbx::off::Inst_Parent);

    auto is = [&](const char* s){ return className == s; };
    auto isPart = [&](){
        return is("Part") || is("MeshPart") || is("UnionOperation") || is("WedgePart") ||
               is("TrussPart") || is("CornerWedgePart") || is("SpawnLocation") ||
               is("Seat") || is("VehicleSeat") || is("BasePart");
    };

    if (isPart()) {
        rowF("Reflectance",   inst, 0x10c);
        rowF("Transparency",  inst, 0x130);
        rowB("CastShadow",    inst, 0x135);
        rowB("Locked",        inst, 0x136);
        rowB("Massless",      inst, 0x137);
        rowI("Shape",         inst, 0x1b9);
        uintptr_t prim = 0;
        if (rbx::R(inst + 0x188, prim) && prim) {
            snprintf(b, 64, "0x%llX", (unsigned long long)prim); row("Primitive", "0x188", b);
            rowV3("Position",               prim, 0xec);
            rowV3("AssemblyLinearVelocity", prim, 0xf8);
            rowV3("AssemblyAngularVelocity",prim, 0x104);
            rowV3("Size",                   prim, 0x1bc);
            uint8_t flags = 0;
            if (rbx::R(prim + 0x1b6, flags)) {
                row("Anchored",   "0x1B6:b1", (flags & 0x02) ? "true" : "false");
                row("CanCollide", "0x1B6:b3", (flags & 0x08) ? "true" : "false");
                row("CanTouch",   "0x1B6:b4", (flags & 0x10) ? "true" : "false");
                row("CanQuery",   "0x1B6:b5", (flags & 0x20) ? "true" : "false");
            }
        }
    }
    if (is("Camera")) {
        rowV3 ("Position",      inst, 0xfc);
        rowI  ("CameraType",    inst, 0x138);
        rowF  ("FieldOfView",   inst, 0x140);
        rowAddr("CameraSubject",inst, 0xc8);
        float vx=0, vy=0;
        if (rbx::R(inst + 0x2cc, vx) && rbx::R(inst + 0x2cc + 4, vy)) {
            snprintf(b, 64, "%.1f, %.1f", vx, vy); row("ViewportSize", "0x2CC", b);
        }
    }
    if (is("Humanoid")) {
        rowF ("Health",           inst, 0x190);
        rowF ("MaxHealth",        inst, 0x1a8);
        rowF ("WalkSpeed",        inst, 0x1d0);
        rowF ("JumpPower",        inst, 0x1a4);
        rowF ("JumpHeight",       inst, 0x1a0);
        rowF ("HipHeight",        inst, 0x194);
        rowF ("MaxSlopeAngle",    inst, 0x1ac);
        rowB ("AutoJumpEnabled",  inst, 0x1d4);
        rowB ("AutoRotate",       inst, 0x1d5);
        rowB ("PlatformStand",    inst, 0x1dc);
        rowB ("Sit",              inst, 0x1dd);
        rowB ("UseJumpPower",     inst, 0x1e0);
        rowB ("Jump",             inst, 0x1da);
        rowI ("HumanoidState",    inst, 0x898);
        rowV3("MoveDirection",    inst, 0x140);
        rowV3("TargetPoint",      inst, 0x14c);
        rowV3("MoveToPoint",      inst, 0x164);
        rowV3("CameraOffset",     inst, 0x128);
        rowAddr("HumanoidRootPart",inst,0x478);
        rowAddr("SeatPart",       inst, 0x108);
        rowStr("DisplayName",     inst, 0xb8);
    }
    if (is("Player")) {
        rowStr ("DisplayName",           inst, 0x138);
        rowI   ("UserId",                inst, 0x300);
        rowI   ("AccountAge",            inst, 0x35c);
        rowI   ("CameraMode",            inst, 0x370);
        rowI   ("TeamColor",             inst, 0x3b0);
        rowF   ("MinZoomDistance",       inst, 0x36c);
        rowF   ("HealthDisplayDistance", inst, 0x394);
        rowF   ("NameDisplayDistance",   inst, 0x3a4);
        rowAddr("Character",             inst, 0x298);
        rowAddr("Team",                  inst, 0x2d8);
    }
    if (is("Model"))    { rowF("Scale", inst, 0x144); rowAddr("PrimaryPart", inst, 0x258); }
    if (is("Workspace")){ rowAddr("CurrentCamera", inst, 0x498); rowD("DistributedGameTime", inst, 0x4b8); rowF("Gravity", inst, 0x9c0); }
    if (is("Lighting")) {
        rowF ("Brightness",           inst, 0x110);
        rowF ("ClockTime",            inst, 0x1a8);
        rowF ("GeographicLatitude",   inst, 0x180);
        rowF ("ExposureCompensation", inst, 0x11c);
        rowF ("FogEnd",               inst, 0x124);
        rowF ("FogStart",             inst, 0x128);
        rowB ("GlobalShadows",        inst, 0x138);
        rowV3("LightDirection",       inst, 0x158);
        rowV3("SunPosition",          inst, 0x168);
        rowV3("MoonPosition",         inst, 0x174);
    }
    if (is("Atmosphere")) {
        rowF("Density", inst, 0xd0); rowF("Glare", inst, 0xd4);
        rowF("Haze",    inst, 0xd8); rowF("Offset",inst, 0xdc);
    }
    if (is("Sound")) {
        rowStr("SoundId",             inst, 0xc8);
        rowF ("PlaybackSpeed",        inst, 0x11c);
        rowF ("Volume",               inst, 0x130);
        rowF ("RollOffMaxDistance",   inst, 0x120);
        rowF ("RollOffMinDistance",   inst, 0x124);
        rowB ("Looped",               inst, 0x13d);
        rowB ("IsPlaying",            inst, 0x140);
    }
    if (is("Tool")) {
        rowV3("Grip",                 inst, 0x4ac);
        rowB ("CanBeDropped",         inst, 0x4b8);
        rowB ("Enabled",              inst, 0x4b9);
        rowB ("ManualActivationOnly", inst, 0x4ba);
        rowB ("RequiresHandle",       inst, 0x4bb);
    }
    if (is("LocalScript") || is("Script") || is("ModuleScript")) {
        uintptr_t bcOff = is("ModuleScript") ? 0x138 : 0x190;
        uintptr_t bc = 0;
        if (rbx::R(inst + bcOff, bc) && bc) {
            char bcOffStr[16]; snprintf(bcOffStr, 16, "0x%llX", (unsigned long long)bcOff);
            snprintf(b, 64, "0x%llX", (unsigned long long)bc); row("ByteCode", bcOffStr, b);
            uintptr_t ptr = 0, sz = 0;
            if (rbx::R(bc + 0x10, ptr)) { snprintf(b, 64, "0x%llX", (unsigned long long)ptr); row("ByteCode.Ptr",  "0x10", b); }
            if (rbx::R(bc + 0x20, sz))  { snprintf(b, 64, "%llu",   (unsigned long long)sz ); row("ByteCode.Size", "0x20", b); }
        }
    }
    if (is("ProximityPrompt")) {
        rowStr("ActionText",             inst, 0xb0);
        rowStr("ObjectText",             inst, 0xd0);
        rowF  ("HoldDuration",           inst, 0x120);
        rowI  ("KeyCode",                inst, 0x124);
        rowF  ("MaxActivationDistance",  inst, 0x128);
        rowB  ("Enabled",                inst, 0x136);
        rowB  ("RequiresLineOfSight",    inst, 0x137);
    }
    if (is("ClickDetector"))  { rowF("MaxActivationDistance", inst, 0xe8); rowStr("MouseIcon", inst, 0xc8); }
    if (is("Attachment"))     { rowV3("Position", inst, 0xc4); }

    // ---- GUI objects (Frame/ImageLabel/TextLabel/...) --------------------
    // AbsolutePosition / AbsoluteSize are what you want for 2D ESP: they are
    // the element's real screen rectangle in pixels (top-left + w/h).
    auto isGui = [&](){
        return is("Frame") || is("ScrollingFrame") || is("CanvasGroup") ||
               is("TextLabel") || is("TextButton") || is("TextBox") ||
               is("ImageLabel") || is("ImageButton") ||
               is("ViewportFrame") || is("VideoFrame");
    };
    if (isGui()) {
        rowV2   ("AbsolutePosition",     inst, rbx::off::Gui_AbsolutePosition);
        rowV2   ("AbsoluteSize",         inst, rbx::off::Gui_AbsoluteSize);
        rowF    ("AbsoluteRotation",     inst, rbx::off::Gui_AbsoluteRotation);
        rowUDim2("Position",             inst, rbx::off::Gui_Position);
        rowUDim2("Size",                 inst, rbx::off::Gui_Size);
        rowB    ("Visible",              inst, rbx::off::Gui_Visible);
        rowI    ("ZIndex",               inst, rbx::off::Gui_ZIndex);
        rowI    ("LayoutOrder",          inst, rbx::off::Gui_LayoutOrder);
        rowColor3("BackgroundColor3",    inst, rbx::off::Gui_BackgroundColor3);
        rowF    ("BackgroundTransparency", inst, rbx::off::Gui_BackgroundTransp);
        if (is("TextLabel") || is("TextButton") || is("TextBox")) {
            rowStr   ("Text",       inst, rbx::off::Gui_Text);
            rowColor3("TextColor3", inst, rbx::off::Gui_TextColor3);
        }
        if (is("ImageLabel") || is("ImageButton")) {
            rowStr("Image", inst, rbx::off::Gui_Image);
        }

        // Offset-finder: if AbsoluteSize above is wrong for your build, one of
        // these raw floats is the real width/height (match it to the element's
        // on-screen pixel size), and the pair just before it is AbsolutePosition.
        for (uintptr_t o = 0x100; o <= 0x11C; o += 4) {
            float f; if (!rbx::R(inst + o, f)) continue;
            char nm[24]; snprintf(nm, sizeof(nm), "scan f");
            char ob[16]; fmt_off(ob, sizeof(ob), o);
            char vb[32]; snprintf(vb, sizeof(vb), "%.2f", f);
            row(nm, ob, vb);
        }
    }
    if (is("ScreenGui") || is("SurfaceGui") || is("BillboardGui"))
        rowB("Enabled", inst, rbx::off::ScreenGui_Enabled);

    // ValueBase types (IntValue/StringValue/BoolValue/etc.) - Roblox stores the
    // typed value at Misc::Value = 0xb8 per theo's offsets.
    {
        constexpr uintptr_t VAL = 0xb8;
        if (is("IntValue"))         rowI  ("Value", inst, VAL);
        if (is("NumberValue"))      rowD  ("Value", inst, VAL);
        if (is("DoubleConstrainedValue")) rowD("Value", inst, VAL);
        if (is("StringValue"))      rowStr("Value", inst, VAL);
        if (is("BoolValue"))        rowB  ("Value", inst, VAL);
        if (is("ObjectValue"))      rowAddr("Value", inst, VAL);
        if (is("Vector3Value"))     rowV3 ("Value", inst, VAL);
        if (is("Color3Value"))      rowV3 ("Value", inst, VAL); // 3 floats
        if (is("BrickColorValue"))  rowI  ("Value", inst, VAL); // color number id
        if (is("CFrameValue")) {
            // CFrame = position (3 floats) + 3x3 rotation matrix (9 floats)
            rowV3("Position", inst, VAL);
        }
        if (is("RayValue")) {
            rowV3("Origin",    inst, VAL);
            rowV3("Direction", inst, VAL + 12);
        }
    }
    if (is("Terrain")) {
        rowF("GrassLength",       inst, 0x188);
        rowF("WaterReflectance",  inst, 0x190);
        rowF("WaterTransparency", inst, 0x194);
        rowF("WaterWaveSize",     inst, 0x198);
        rowF("WaterWaveSpeed",    inst, 0x19c);
    }
    if (is("BloomEffect") || is("BlurEffect") || is("ColorCorrectionEffect") ||
        is("ColorGradingEffect") || is("DepthOfFieldEffect") || is("SunRaysEffect")) {
        rowB("Enabled",        inst, 0xb0);
        rowF("Size/Intensity", inst, 0xb8);
    }

    ImGui::EndTable();
}

// ---------------------------------------------------------------------------
// Clipboard + path helpers
// ---------------------------------------------------------------------------
static void set_clipboard_text(const std::string& s) {
    if (!OpenClipboard(NULL)) return;
    EmptyClipboard();
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, s.size() + 1);
    if (h) {
        void* dst = GlobalLock(h);
        if (dst) { memcpy(dst, s.data(), s.size() + 1); GlobalUnlock(h); }
        SetClipboardData(CF_TEXT, h);
    }
    CloseClipboard();
}

// Returns true if `name` is a valid Lua identifier (dotted access is safe).
static bool is_lua_ident(const std::string& name) {
    if (name.empty()) return false;
    char c = name[0];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_')) return false;
    for (size_t i = 1; i < name.size(); ++i) {
        char ch = name[i];
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
              (ch >= '0' && ch <= '9') || ch == '_')) return false;
    }
    return true;
}

// Append one path segment. `parent` is like "game.Workspace" or "".
// If the child name is a valid Lua identifier we use dotted access, otherwise
// we use `:FindFirstChild("name")` for safety with special chars/reserved words.
static std::string append_path_segment(const std::string& parent, const std::string& childName) {
    if (parent.empty()) return childName; // typically "game"
    if (is_lua_ident(childName)) return parent + "." + childName;
    // Escape any quotes and backslashes in the name.
    std::string esc; esc.reserve(childName.size() + 2);
    for (char c : childName) {
        if (c == '\\' || c == '"') esc.push_back('\\');
        esc.push_back(c);
    }
    return parent + ":FindFirstChild(\"" + esc + "\")";
}

// ---------------------------------------------------------------------------
// Filter helpers
// ---------------------------------------------------------------------------
static bool str_contains_ci(const std::string& hay, const char* needle) {
    if (!needle || !*needle) return true;
    if (hay.empty()) return false;
    size_t nlen = strlen(needle);
    if (nlen > hay.size()) return false;
    for (size_t i = 0; i + nlen <= hay.size(); ++i) {
        size_t k = 0;
        for (; k < nlen; ++k) {
            char a = hay[i + k], b = needle[k];
            if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
            if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
            if (a != b) break;
        }
        if (k == nlen) return true;
    }
    return false;
}

static bool node_self_matches(const Node& n) {
    return str_contains_ci(n.name, g.filterBuf) || str_contains_ci(n.cls, g.filterBuf);
}

// Recursively check whether a node or any of its already-loaded descendants
// matches the current filter. If the subtree hasn't been loaded yet we return
// true (we don't know, so let the user expand and see).
static bool subtree_matches(const Node& n) {
    if (g.filterBuf[0] == 0) return true;
    if (node_self_matches(n)) return true;
    if (!n.loaded) return true;
    for (const auto& c : n.kids) if (subtree_matches(c)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Tree rendering (recursive)
// ---------------------------------------------------------------------------
// `parentPath` is the Lua-style path of `n`'s parent (e.g. "game.Workspace").
// For the DataModel root we pass "" and use "game" as its display path.
static void draw_node(Node& n, const std::string& parentPath) {
    ImGuiTreeNodeFlags flags = ImGuiTreeNodeFlags_OpenOnArrow | ImGuiTreeNodeFlags_OpenOnDoubleClick |
                               ImGuiTreeNodeFlags_SpanAvailWidth;
    if (g.selected == n.addr) flags |= ImGuiTreeNodeFlags_Selected;

    // Build this node's path (root becomes "game").
    std::string myPath;
    if (parentPath.empty()) myPath = "game";
    else                    myPath = append_path_segment(parentPath, n.name.empty() ? n.cls : n.name);

    char label[512];
    // Display name: prefer the Instance's Name; if empty, fall back to ClassName.
    const std::string& disp = !n.name.empty() ? n.name : n.cls;
    const char* dispPtr = disp.empty() ? "Instance" : disp.c_str();
    bool showClsSuffix = !n.name.empty() && !n.cls.empty() && n.name != n.cls;
    const char* icon = rbx::class_icon(n.cls);
    if (showClsSuffix)
        snprintf(label, sizeof(label), "%s  %s  \xe2\x80\xa2  %s##%llx",
                 icon, dispPtr, n.cls.c_str(), (unsigned long long)n.addr);
    else
        snprintf(label, sizeof(label), "%s  %s##%llx",
                 icon, dispPtr, (unsigned long long)n.addr);

    // When actively searching (2+ chars), auto-expand any node whose subtree
    // matches. This lets the user find deep entries without manual clicking.
    bool searching = g.filterBuf[0] && g.filterBuf[1];
    if (searching && subtree_matches(n) && !node_self_matches(n)) {
        ImGui::SetNextItemOpen(true, ImGuiCond_Always);
    }

    bool open = ImGui::TreeNodeEx(label, flags);
    if (ImGui::IsItemClicked() && !ImGui::IsItemToggledOpen()) g.selected = n.addr;

    if (ImGui::BeginPopupContextItem()) {
        char b[64]; snprintf(b, 64, "0x%llX", (unsigned long long)n.addr);
        if (ImGui::MenuItem("Copy path"))     set_clipboard_text(myPath);
        if (ImGui::MenuItem("Copy name"))     set_clipboard_text(n.name);
        if (ImGui::MenuItem("Copy class"))    set_clipboard_text(n.cls);
        if (ImGui::MenuItem("Copy address"))  set_clipboard_text(b);
        ImGui::Separator();
        if (ImGui::MenuItem("Re-read name/class")) {
            n.name = rbx::get_name(n.addr);
            n.cls  = rbx::get_class(n.addr);
        }
        if (ImGui::MenuItem("Set as selection")) g.selected = n.addr;
        ImGui::Separator();
        ImGui::TextDisabled("%s", myPath.c_str());
        ImGui::TextDisabled("%s", b);
        ImGui::EndPopup();
    }
    if (open) {
        ensure_loaded(n);
        for (auto& c : n.kids) {
            if (g.filterBuf[0] && !subtree_matches(c)) continue;
            draw_node(c, myPath);
        }
        ImGui::TreePop();
    }
}

// Look up node in tree for the currently selected address (walks lazily).
static const Node* find_selected(const Node& n, uintptr_t addr) {
    if (n.addr == addr) return &n;
    for (const auto& c : n.kids) {
        const Node* r = find_selected(c, addr);
        if (r) return r;
    }
    return nullptr;
}

// ---------------------------------------------------------------------------
// Frame (content-only: caller owns ImGui window)
// ---------------------------------------------------------------------------
static void draw_dex_content() {
    // ---- Top toolbar ----
    ImGui::AlignTextToFramePadding(); ImGui::TextUnformatted("Process:");
    ImGui::SameLine();
    ImGui::SetNextItemWidth(240);
    ImGui::InputText("##proc", g.procNameBuf, sizeof(g.procNameBuf));
    ImGui::SameLine();
    bool busy = g.attachState.load() == AttachState::Working;
    if (busy) ImGui::BeginDisabled();
    if (ImGui::Button("Attach", ImVec2(90, 0))) kick_attach();
    ImGui::SameLine();
    if (ImGui::Button("Refresh", ImVec2(90, 0))) kick_attach();
    if (busy) ImGui::EndDisabled();
    ImGui::SameLine();

    // Auto-poll: while attached, check every ~1s that the process is still alive.
    if (g.attachState.load() == AttachState::Attached && rbx::g_hProc) {
        static double lastPoll = 0.0;
        double now = ImGui::GetTime();
        if (now - lastPoll > 1.0) {
            lastPoll = now;
            DWORD code = 0;
            if (!GetExitCodeProcess(rbx::g_hProc, &code) || code != STILL_ACTIVE) {
                CloseHandle(rbx::g_hProc); rbx::g_hProc = nullptr;
                rbx::g_moduleBase = 0; rbx::g_dataModel = 0;
                g.root = Node{}; g.selected = 0;
                g.lastError = "Roblox process exited. Click Attach when it's running again.";
                g.attachState.store(AttachState::Failed);
            }
        }
    }

    switch (g.attachState.load()) {
        case AttachState::Idle:     ImGui::TextDisabled("Not attached"); break;
        case AttachState::Working:  ImGui::TextColored(ImVec4(1,0.8f,0.3f,1), "Working..."); break;
        case AttachState::Attached: ImGui::TextColored(ImVec4(0.4f,1,0.5f,1),
            "Attached  base=0x%llX  DataModel=0x%llX",
            (unsigned long long)rbx::g_moduleBase, (unsigned long long)rbx::g_dataModel); break;
        case AttachState::Failed:   ImGui::TextColored(ImVec4(1,0.4f,0.4f,1), "%s", g.lastError.c_str()); break;
    }

    ImGui::Separator();

    // ---- Split panes ----
    ImVec2 avail = ImGui::GetContentRegionAvail();
    float leftW = avail.x * 0.42f;

    ImGui::BeginChild("##tree", ImVec2(leftW, avail.y), true);
    // Explorer search (Studio-like search box)
    ImGui::AlignTextToFramePadding(); ImGui::TextUnformatted("Search:");
    ImGui::SameLine();
    ImGui::SetNextItemWidth(-40);
    ImGui::InputTextWithHint("##dex_filter", "name or class - subtree auto-expands",
                             g.filterBuf, sizeof(g.filterBuf));
    ImGui::SameLine();
    if (ImGui::Button("X##clr", ImVec2(28, 0))) g.filterBuf[0] = 0;
    ImGui::Separator();
    if (g.root.addr) {
        // Show child count under the root header
        if (g.root.loaded)
            ImGui::TextDisabled("%zu services", g.root.kids.size());
        draw_node(g.root, std::string());
    }
    else ImGui::TextDisabled("Attach to a Roblox process to browse the DataModel.");
    ImGui::EndChild();

    ImGui::SameLine();

    ImGui::BeginChild("##props", ImVec2(0, avail.y), true);
    if (g.selected) {
        // Look up class name from the cached tree if present, else read live.
        std::string cls;
        const Node* n = g.root.addr ? find_selected(g.root, g.selected) : nullptr;
        cls = n ? n->cls : rbx::get_class(g.selected);
        draw_props(g.selected, cls);
    } else {
        ImGui::TextDisabled("Select an instance in the tree.");
    }
    ImGui::EndChild();
}

static void draw_progress_modal() {
    if (g.attachState.load() != AttachState::Working) return;
    ImVec2 center = ImGui::GetMainViewport()->GetCenter();
    ImGui::SetNextWindowPos(center, ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(460, 0));
    ImGui::Begin("Loading##dexmodal", nullptr,
        ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoCollapse |
        ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::TextColored(ImVec4(0.7f,0.85f,1,1), "Attaching to Roblox");
    ImGui::Separator();

    std::string t;
    { std::lock_guard<std::mutex> lk(g.progressMtx); t = g.progressText; }
    ImGui::TextUnformatted(t.c_str());

    float f = g.progressFrac.load();
    int   cur = g.progressCur.load(), tot = g.progressTot.load();
    char overlay[64];
    if (tot > 0) snprintf(overlay, 64, "%d / %d  (%.0f%%)", cur, tot, f * 100.0f);
    else         snprintf(overlay, 64, "%.0f%%", f * 100.0f);
    ImGui::ProgressBar(f, ImVec2(-1, 0), overlay);

    // Little spinner (rotating dots)
    static const char* dots[] = { "|", "/", "-", "\\" };
    int step = (int)(ImGui::GetTime() * 8.0) & 3;
    ImGui::SameLine(); ImGui::TextDisabled("%s", dots[step]);
    ImGui::End();
}

} // anonymous namespace

// ---------------------------------------------------------------------------
// Public entry points (called from main UI)
// ---------------------------------------------------------------------------
void Dex_DrawContent() {
    draw_dex_content();
    draw_progress_modal();
}

bool Dex_IsVisible()          { return g.visible.load(); }
void Dex_SetVisible(bool v)   { g.visible.store(v); }

void Dex_Shutdown() {
    // Signal worker to finish (nothing to signal really; wait for it) and close handle
    if (g.worker.joinable()) g.worker.join();
    if (rbx::g_hProc) { CloseHandle(rbx::g_hProc); rbx::g_hProc = nullptr; }
    rbx::g_moduleBase = 0;
    rbx::g_dataModel  = 0;
}

// Back-compat entry points (kept so old call sites still link/build)
void ShowRobloxExplorer(HINSTANCE /*hInst*/) { g.visible.store(true); }
void RbxExplorer_RequestShutdown()           { Dex_Shutdown(); }