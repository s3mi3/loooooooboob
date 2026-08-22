// ============================================================================
//  Agaric ESP overlay  (external, ReadProcessMemory + Dear ImGui + DX11)
//  ---------------------------------------------------------------------------
//  A transparent, click-through, always-on-top window that sits over the
//  Roblox client and draws Agar-style awareness cues by reading the game's
//  2D GUI circles straight out of memory - no Lua, no injection.
//
//  It walks:  game > Players > LocalPlayer > PlayerGui > Agaric2D > Camera >
//             Canvas   and collects Frames named "PlayerBlob" (cells) and
//             ImageLabels named "Spike" (viruses), reading each one's
//             AbsolutePosition / AbsoluteSize (real screen px) + Mass/Name.
//
//  Draws: distance lines, threat rings (1.25 mass eat rule), virus stars,
//         and split-range circles.
//
//  Press  INSERT  to toggle the settings window (also toggles click-through).
//
//  Offsets: theo's offsets (offsets.imtheo.lol) version-ddf602d9cfe44005.
//  Build:   see build_msvc.bat  (target: overlay).  Run as Administrator.
// ============================================================================
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <d3d11.h>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cctype>
#include <cmath>
#include <string>
#include <vector>
#include <unordered_map>

#include "imgui.h"
#include "backends/imgui_impl_win32.h"
#include "backends/imgui_impl_dx11.h"

#pragma comment(lib, "psapi.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")

// ---------------------------------------------------------------------------
// Roblox memory access (version-ddf602d9cfe44005)
// ---------------------------------------------------------------------------
namespace rbx {
namespace off {
    constexpr uintptr_t FakeDataModel_Ptr    = 0x8B79B58; // 146250584 (RVA)
    constexpr uintptr_t FakeDataModel_RealDM = 0x1D8;     // 472
    constexpr uintptr_t Inst_NameContainer   = 0x70;      // 112
    constexpr uintptr_t Inst_Name            = 0x08;      // inside NameContainer
    constexpr uintptr_t Inst_ClassDescriptor = 0x18;      // 24
    constexpr uintptr_t ClassDesc_Name       = 0x08;
    constexpr uintptr_t Inst_ChildrenStart   = 0x78;      // 120
    constexpr uintptr_t Inst_Parent          = 0x68;      // 104
    constexpr uintptr_t Players_LocalPlayer  = 0x130;     // 304 (on Players service)
    constexpr uintptr_t Player_DisplayName   = 0x138;     // 312 (on Player)
    // GuiBase2D / GuiObject
    constexpr uintptr_t Gui_AbsolutePosition = 0x10C;     // Vector2
    constexpr uintptr_t Gui_AbsoluteSize     = 0x114;     // Vector2
    constexpr uintptr_t Gui_Visible          = 0x5AD;     // bool
    constexpr uintptr_t Gui_Text             = 0xDF8;     // string (Text*)
}

static HANDLE    g_hProc = nullptr;
static uintptr_t g_base  = 0;
static uintptr_t g_dm    = 0;
static const char* PROC  = "RobloxPlayerBeta.exe";

struct V2 { float x, y; };

template<typename T> static inline bool R(uintptr_t a, T& v) {
    if (!g_hProc || !a) return false;
    SIZE_T rd = 0;
    return ReadProcessMemory(g_hProc, (LPCVOID)a, &v, sizeof(T), &rd) && rd == sizeof(T);
}
static bool rbytes(uintptr_t a, void* o, size_t n) {
    if (!g_hProc || !a) return false; SIZE_T rd = 0;
    return ReadProcessMemory(g_hProc, (LPCVOID)a, o, n, &rd) && rd == n;
}
// MSVC std::string (SSO) reader.
static std::string rstr(uintptr_t addr) {
    if (!g_hProc || !addr) return {};
    uint8_t buf[32] = {};
    if (!rbytes(addr, buf, 32)) return {};
    uint64_t size = 0, cap = 0;
    memcpy(&size, buf + 16, 8); memcpy(&cap, buf + 24, 8);
    if (size == 0 || size > 4096 || cap < size) return {};
    std::string s;
    if (cap >= 16) {
        uintptr_t p = 0; memcpy(&p, buf, 8);
        if (!p) return {};
        s.assign((size_t)size, '\0');
        SIZE_T rd = 0;
        if (!ReadProcessMemory(g_hProc, (LPCVOID)p, s.data(), (SIZE_T)size, &rd) || rd != (SIZE_T)size) return {};
    } else {
        s.assign((const char*)buf, (size_t)size);
    }
    for (char c : s) { unsigned char u = (unsigned char)c; if (u < 0x20 && u != '\t' && u != '\n') return {}; }
    return s;
}
// string property: try inline std::string, else pointer -> std::string.
static std::string rstr_prop(uintptr_t addr) {
    std::string s = rstr(addr); if (!s.empty()) return s;
    uintptr_t p = 0; if (R(addr, p) && p) { s = rstr(p); if (!s.empty()) return s; }
    return {};
}

static std::string get_name(uintptr_t inst) {
    uintptr_t c = 0;
    if (!R(inst + off::Inst_NameContainer, c) || !c) return {};
    return rstr(c + off::Inst_Name);
}
static std::string get_class(uintptr_t inst) {
    uintptr_t d = 0;
    if (!R(inst + off::Inst_ClassDescriptor, d) || !d) return {};
    return rstr(d + off::ClassDesc_Name);
}
static bool is_real_child(uintptr_t child, uintptr_t parent) {
    if (!child || (child & 0x7) != 0) return false;
    uintptr_t d = 0; if (!R(child + off::Inst_ClassDescriptor, d) || !d) return false;
    uintptr_t p = 0; if (!R(child + off::Inst_Parent, p)) return false;
    return p == parent;
}
static std::vector<uintptr_t> get_children(uintptr_t inst) {
    std::vector<uintptr_t> out;
    if (!inst) return out;
    auto try_range = [&](uintptr_t start, uintptr_t end) -> bool {
        if (!start || end <= start) return false;
        uintptr_t bytes = end - start;
        if (bytes > (uintptr_t)(8 * 20000) || (bytes & 0x7)) return false;
        size_t count = (size_t)(bytes / 8);
        std::vector<uintptr_t> filtered;
        for (size_t i = 0; i < count; ++i) {
            uintptr_t child = 0;
            if (!R(start + i * 8, child)) break;
            if (child && is_real_child(child, inst)) {
                bool dup = false;
                for (uintptr_t e : filtered) if (e == child) { dup = true; break; }
                if (!dup) filtered.push_back(child);
            }
        }
        if (filtered.empty()) return false;
        out = std::move(filtered); return true;
    };
    uintptr_t a = 0, b = 0;
    if (R(inst + off::Inst_ChildrenStart, a) && R(inst + off::Inst_ChildrenStart + 8, b))
        if (try_range(a, b)) return out;
    uintptr_t cont = 0;
    if (R(inst + off::Inst_ChildrenStart, cont) && cont) {
        uintptr_t s = 0, e = 0;
        if (R(cont, s) && R(cont + 8, e) && try_range(s, e)) return out;
    }
    return out;
}
static uintptr_t find_child(uintptr_t parent, const char* name) {
    if (!parent) return 0;
    for (uintptr_t c : get_children(parent)) if (get_name(c) == name) return c;
    return 0;
}

static bool attach() {
    if (g_hProc) return true;
    // find pid
    DWORD pid = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap != INVALID_HANDLE_VALUE) {
        PROCESSENTRY32W pe = {}; pe.dwSize = sizeof(pe);
        if (Process32FirstW(snap, &pe)) do {
            char cvt[MAX_PATH] = {};
            WideCharToMultiByte(CP_UTF8, 0, pe.szExeFile, -1, cvt, MAX_PATH, 0, 0);
            if (_stricmp(cvt, PROC) == 0) { pid = pe.th32ProcessID; break; }
        } while (Process32NextW(snap, &pe));
        CloseHandle(snap);
    }
    if (!pid) return false;
    g_hProc = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!g_hProc) return false;
    // module base
    HMODULE mods[1024]; DWORD cb = 0;
    if (EnumProcessModulesEx(g_hProc, mods, sizeof(mods), &cb, LIST_MODULES_ALL)) {
        wchar_t nb[MAX_PATH]; char cvt[MAX_PATH];
        for (int i = 0; i < (int)(cb / sizeof(HMODULE)); ++i) {
            if (GetModuleBaseNameW(g_hProc, mods[i], nb, MAX_PATH)) {
                WideCharToMultiByte(CP_UTF8, 0, nb, -1, cvt, MAX_PATH, 0, 0);
                if (_stricmp(cvt, PROC) == 0) { g_base = (uintptr_t)mods[i]; break; }
            }
        }
    }
    if (!g_base) return false;
    uintptr_t fake = 0;
    if (!R(g_base + off::FakeDataModel_Ptr, fake) || !fake) return false;
    if (!R(fake + off::FakeDataModel_RealDM, g_dm) || !g_dm) return false;
    return true;
}
static void detach() {
    if (g_hProc) { CloseHandle(g_hProc); g_hProc = nullptr; }
    g_base = 0; g_dm = 0;
}
static bool alive() {
    if (!g_hProc) return false;
    DWORD code = 0;
    return GetExitCodeProcess(g_hProc, &code) && code == STILL_ACTIVE;
}
} // namespace rbx

// ---------------------------------------------------------------------------
// ESP state
// ---------------------------------------------------------------------------
struct Cell { float x, y, r; double mass; std::string name; bool own; };
struct Virus { float x, y, r; };

struct Config {
    bool enabled       = true;
    // Distance: 0=All, 1=Threats only, 2=Off  (default Threats to cut clutter)
    int   line_mode    = 1;
    int   label_mode   = 1;
    float max_dist     = 0;      // px cull for lines/labels (0 = no cull)
    // Threat
    bool  threat_on    = true;
    bool  threat_ring  = true;
    bool  threat_offscreen = true;
    bool  proximity_alert  = true;
    float eat_ratio    = 1.25f;  // mass ratio needed to eat
    // Virus
    bool  virus_on     = true;
    bool  virus_tag    = true;
    bool  virus_offscreen = true;
    float virus_min_px = 14.0f;  // viruses never drawn smaller than this
    // Offense
    bool  eat_targets  = true;   // mark prey you could split-eat
    // Split range
    bool  split_self    = true;
    bool  split_threats = true;
    float split_mult    = 6.0f;  // reach = radius * split_mult (px)
    // Merge timer
    bool  merge_on      = true;
    float merge_seconds = 15.0f; // recombine time (calibrate to your game)
    int   split_key     = VK_SPACE;
    // Input macro (experimental; input simulation only, no memory writes)
    bool  macro_eject   = false; // while hold_key is down, tap eject_key at eject_hz
    int   hold_key      = 'W';   // key you hold to trigger the macro
    int   eject_key     = 'W';   // key the macro taps (the game's eject/feed key)
    int   eject_hz      = 15;    // taps per second
    // Display
    float ui_scale      = 1.0f;
    bool  auto_scale    = true;  // scale markers/text with your on-screen size
    ImVec4 col_line   = ImVec4(1, 1, 1, 0.30f);
    ImVec4 col_threat = ImVec4(1, 0.15f, 0.15f, 1);
    ImVec4 col_prey   = ImVec4(0.30f, 1, 0.40f, 1);
    ImVec4 col_virus  = ImVec4(0.54f, 0.81f, 0, 1);
    ImVec4 col_split  = ImVec4(1, 0.55f, 0.10f, 0.6f);
    ImVec4 col_target = ImVec4(0.2f, 0.9f, 1, 1);
} g_cfg;

static char   g_ownName[128] = "";     // optional manual override
static int    g_prevOwn   = 0;         // merge-timer: previous own-cell count
static double g_lastSplit = -1e9;      // merge-timer: time of last split

// Walk Canvas subtree collecting PlayerBlob / Spike frames.
static void walk(uintptr_t node, int depth, std::vector<uintptr_t>& blobs, std::vector<uintptr_t>& spikes) {
    if (depth <= 0 || node == 0) return;
    if (blobs.size() + spikes.size() > 4000) return;
    for (uintptr_t c : rbx::get_children(node)) {
        std::string nm = rbx::get_name(c);
        if (nm == "PlayerBlob") blobs.push_back(c);
        else if (nm == "Spike") spikes.push_back(c);
        walk(c, depth - 1, blobs, spikes);
    }
}

static std::string strip_rich(std::string s) {
    std::string o; o.reserve(s.size());
    bool tag = false;
    for (char c : s) { if (c == '<') tag = true; else if (c == '>') tag = false; else if (!tag) o.push_back(c); }
    return o;
}
// Normalise a name for matching: drop rich-text, drop bracketed clan tags
// like "[WRST]"/"(x)", drop spaces, lowercase.
static std::string norm_name(std::string s) {
    s = strip_rich(s);
    std::string o; bool br = false;
    for (char c : s) {
        if (c == '[' || c == '(' || c == '{') br = true;
        else if (c == ']' || c == ')' || c == '}') br = false;
        else if (!br && c != ' ') o.push_back((char)tolower((unsigned char)c));
    }
    return o;
}
static double parse_mass(const std::string& s) {
    if (s.empty()) return 0;
    double n = 0; double mul = 1; std::string digits;
    for (char c : s) if ((c >= '0' && c <= '9') || c == '.') digits.push_back(c);
    if (!digits.empty()) n = atof(digits.c_str());
    char last = s.back();
    if (last == 'k' || last == 'K') mul = 1e3;
    else if (last == 'm' || last == 'M') mul = 1e6;
    else if (last == 'b' || last == 'B') mul = 1e9;
    return n * mul;
}

// Read all cells + viruses for this frame.
static void read_world(std::vector<Cell>& cells, std::vector<Virus>& viruses) {
    uintptr_t players = rbx::find_child(rbx::g_dm, "Players");
    if (!players) return;
    uintptr_t lp = 0;
    rbx::R(players + rbx::off::Players_LocalPlayer, lp);
    if (!lp) return;

    // Match own cells by the local player's name. Prefer a manual override,
    // then DisplayName, then username. Normalised (clan tags/spaces stripped).
    std::string myRaw = g_ownName[0] ? std::string(g_ownName) : rbx::rstr_prop(lp + rbx::off::Player_DisplayName);
    if (myRaw.empty()) myRaw = rbx::get_name(lp);
    std::string myN = norm_name(myRaw);

    uintptr_t pg     = rbx::find_child(lp, "PlayerGui");
    uintptr_t screen = rbx::find_child(pg, "Agaric2D");
    uintptr_t camera = rbx::find_child(screen, "Camera");
    uintptr_t canvas = rbx::find_child(camera, "Canvas");
    if (!canvas) return;

    std::vector<uintptr_t> blobs, spikes;
    walk(canvas, 5, blobs, spikes);

    cells.reserve(blobs.size());
    for (uintptr_t f : blobs) {
        uint8_t vis = 1; rbx::R(f + rbx::off::Gui_Visible, vis);
        if (!vis) continue;
        rbx::V2 ap{}, as{};
        if (!rbx::R(f + rbx::off::Gui_AbsolutePosition, ap)) continue;
        if (!rbx::R(f + rbx::off::Gui_AbsoluteSize, as)) continue;
        float d = as.x > as.y ? as.x : as.y;
        if (d < 3) continue;
        Cell c;
        c.x = ap.x + as.x * 0.5f;
        c.y = ap.y + as.y * 0.5f;
        c.r = d * 0.5f;
        uintptr_t ml = rbx::find_child(f, "MassLabel");
        uintptr_t nl = rbx::find_child(f, "NameLabel");
        c.mass = ml ? parse_mass(rbx::rstr_prop(ml + rbx::off::Gui_Text)) : 0;
        c.name = nl ? strip_rich(rbx::rstr_prop(nl + rbx::off::Gui_Text)) : std::string();
        c.own  = (!myN.empty() && norm_name(c.name) == myN);
        cells.push_back(std::move(c));
    }

    viruses.reserve(spikes.size());
    for (uintptr_t f : spikes) {
        uint8_t vis = 1; rbx::R(f + rbx::off::Gui_Visible, vis);
        if (!vis) continue;
        rbx::V2 ap{}, as{};
        if (!rbx::R(f + rbx::off::Gui_AbsolutePosition, ap)) continue;
        if (!rbx::R(f + rbx::off::Gui_AbsoluteSize, as)) continue;
        float d = as.x > as.y ? as.x : as.y;
        Virus v{ ap.x + as.x * 0.5f, ap.y + as.y * 0.5f, d * 0.5f };
        viruses.push_back(v);
    }
}

// ---------------------------------------------------------------------------
// Rendering (ImGui background draw list, overlay-local = client px)
// ---------------------------------------------------------------------------
static void draw_star(ImDrawList* dl, float cx, float cy, float rout, ImU32 col, float th) {
    const int pts = 12; ImVec2 poly[pts * 2];
    for (int i = 0; i < pts * 2; ++i) {
        float ang = (float)i / (pts * 2) * 6.2831853f - 1.5707963f;
        float rr = (i & 1) ? rout * 0.55f : rout;
        poly[i] = ImVec2(cx + cosf(ang) * rr, cy + sinf(ang) * rr);
    }
    dl->AddPolyline(poly, pts * 2, col, ImDrawFlags_Closed, th);
}

// Centred text, scaled by ui_scale.
static void dtext(ImDrawList* dl, float cx, float top, const char* s, ImU32 col, float sc) {
    ImVec2 ts = ImGui::CalcTextSize(s);
    dl->AddText(ImGui::GetFont(), 14.0f * sc, ImVec2(cx - ts.x * sc * 0.5f, top), col, s);
}

// Arrow at the screen edge pointing toward an off-screen target.
static void offscreen_arrow(ImDrawList* dl, float tx, float ty, float ow, float oh,
                            ImU32 col, float sc, float dist) {
    float m = 26.0f * sc, cx = ow * 0.5f, cy = oh * 0.5f;
    float dx = tx - cx, dy = ty - cy;
    float len = sqrtf(dx * dx + dy * dy);
    if (len < 1.0f) return;
    dx /= len; dy /= len;
    float minX = m, maxX = ow - m, minY = m, maxY = oh - m;
    float tX = (dx > 0) ? (maxX - cx) / dx : (dx < 0 ? (minX - cx) / dx : 1e18f);
    float tY = (dy > 0) ? (maxY - cy) / dy : (dy < 0 ? (minY - cy) / dy : 1e18f);
    float t = tX < tY ? tX : tY;
    float px = cx + dx * t, py = cy + dy * t;
    float s = 11.0f * sc, perpx = -dy, perpy = dx;
    ImVec2 tip(px + dx * s, py + dy * s);
    ImVec2 b1(px + perpx * s * 0.7f, py + perpy * s * 0.7f);
    ImVec2 b2(px - perpx * s * 0.7f, py - perpy * s * 0.7f);
    dl->AddTriangleFilled(tip, b1, b2, col);
    if (dist > 0) {
        char buf[16]; snprintf(buf, sizeof(buf), "%d", (int)(dist + 0.5f));
        dtext(dl, px - dx * 14 * sc, py - dy * 14 * sc - 7 * sc, buf, col, sc);
    }
}

static inline bool on_screen(float x, float y, float ow, float oh) {
    return x >= 0 && x <= ow && y >= 0 && y <= oh;
}

static void render_esp(float ow, float oh) {
    if (!g_cfg.enabled) return;
    std::vector<Cell> cells; std::vector<Virus> viruses;
    read_world(cells, viruses);

    // "me": largest name-matched own cell. If none matched, fall back to the
    // cell nearest the exact screen centre (the camera is centred on you) --
    // pure distance, NOT weighted by size, so a big nearby enemy isn't chosen.
    Cell* me = nullptr;
    int ownCount = 0;
    for (auto& c : cells) if (c.own) { ownCount++; if (!me || c.r > me->r) me = &c; }
    if (!me && !cells.empty()) {
        float best = 1e18f, ccx = ow * 0.5f, ccy = oh * 0.5f;
        for (auto& c : cells) {
            float dx = c.x - ccx, dy = c.y - ccy, d = dx * dx + dy * dy;
            if (d < best) { best = d; me = &c; }
        }
    }

    float ax = me ? me->x : ow * 0.5f;
    float ay = me ? me->y : oh * 0.5f;
    float myr = me ? me->r : 0.0f;
    float rratio = sqrtf(g_cfg.eat_ratio);
    float sc = g_cfg.ui_scale;
    // Auto-scale ESP element sizes with your on-screen radius so they stay
    // proportional as you grow and the camera zooms.
    if (g_cfg.auto_scale && myr > 0) {
        float k = myr / 40.0f;
        if (k < 0.7f) k = 0.7f; else if (k > 2.2f) k = 2.2f;
        sc *= k;
    }

    // ---- Merge timer bookkeeping (client-side estimate) ------------------
    double now = ImGui::GetTime();
    static bool prevSplitKey = false;
    bool splitKey = (GetAsyncKeyState(g_cfg.split_key) & 0x8000) != 0;
    if ((splitKey && !prevSplitKey) || ownCount > g_prevOwn) g_lastSplit = now;
    prevSplitKey = splitKey;
    g_prevOwn = ownCount;

    ImDrawList* dl = ImGui::GetBackgroundDrawList();
    const ImU32 cLine   = ImGui::GetColorU32(g_cfg.col_line);
    const ImU32 cThreat = ImGui::GetColorU32(g_cfg.col_threat);
    const ImU32 cPrey   = ImGui::GetColorU32(g_cfg.col_prey);
    const ImU32 cVirus  = ImGui::GetColorU32(g_cfg.col_virus);
    const ImU32 cSplit  = ImGui::GetColorU32(g_cfg.col_split);
    const ImU32 cTarget = ImGui::GetColorU32(g_cfg.col_target);

    if (g_cfg.split_self && myr > 0)
        dl->AddCircle(ImVec2(ax, ay), myr * g_cfg.split_mult, cSplit, 48, 1.5f * sc);

    bool inDanger = false;

    for (auto& c : cells) {
        if (c.own) continue;
        float dx = c.x - ax, dy = c.y - ay;
        float dist = sqrtf(dx * dx + dy * dy);
        bool threat = g_cfg.threat_on && myr > 0 && (c.r >= myr * rratio);

        // A threat whose split could reach you == active danger.
        if (threat && me && dist <= c.r * g_cfg.split_mult + myr) inDanger = true;

        if (!on_screen(c.x, c.y, ow, oh)) {
            if (threat && g_cfg.threat_offscreen) offscreen_arrow(dl, c.x, c.y, ow, oh, cThreat, sc, dist);
            continue;
        }

        bool farCull = (g_cfg.max_dist > 0 && dist > g_cfg.max_dist);
        ImU32 col = threat ? cThreat : cPrey;

        bool drawLine = (g_cfg.line_mode == 0) || (g_cfg.line_mode == 1 && threat);
        if (drawLine && !farCull) dl->AddLine(ImVec2(ax, ay), ImVec2(c.x, c.y), cLine, 1.0f);

        if (threat) {
            if (g_cfg.threat_ring)   dl->AddCircle(ImVec2(c.x, c.y), c.r > 6 ? c.r : 6, cThreat, 32, 2.0f * sc);
            if (g_cfg.split_threats) dl->AddCircle(ImVec2(c.x, c.y), c.r * g_cfg.split_mult, cSplit, 40, 1.0f);
        } else if (g_cfg.eat_targets && me && c.r <= myr / rratio && dist <= myr * g_cfg.split_mult) {
            // Prey you could reach and eat with a split.
            dl->AddCircle(ImVec2(c.x, c.y), (c.r > 5 ? c.r : 5) + 3 * sc, cTarget, 20, 2.0f * sc);
        }
        dl->AddCircleFilled(ImVec2(c.x, c.y), 2.5f * sc, col, 10);

        bool drawLabel = (g_cfg.label_mode == 0) || (g_cfg.label_mode == 1 && threat);
        if (drawLabel && !farCull) {
            char buf[24]; snprintf(buf, sizeof(buf), "%d", (int)(dist + 0.5f));
            dtext(dl, c.x, c.y - 16 * sc, buf, col, sc);
        }
    }

    if (g_cfg.virus_on) {
        for (auto& v : viruses) {
            bool danger = myr > 0 && myr >= v.r * rratio; // big enough to be popped
            if (!on_screen(v.x, v.y, ow, oh)) {
                if (g_cfg.virus_offscreen) offscreen_arrow(dl, v.x, v.y, ow, oh, cVirus, sc, 0);
                continue;
            }
            float rr = v.r > g_cfg.virus_min_px ? v.r : g_cfg.virus_min_px; rr *= sc;
            draw_star(dl, v.x, v.y, rr, cVirus, 2.0f * sc);
            dl->AddCircleFilled(ImVec2(v.x, v.y), 2.5f * sc, cVirus, 8);
            if (g_cfg.virus_tag) {
                const char* t = danger ? "DANGER" : "SAFE";
                ImU32 tc = danger ? IM_COL32(255, 50, 50, 255) : IM_COL32(150, 230, 150, 255);
                dtext(dl, v.x, v.y - rr - 14 * sc, t, tc, sc);
            }
        }
    }

    // ---- Merge timer readout (above your cell) ---------------------------
    if (g_cfg.merge_on && me && ownCount > 1) {
        double rem = g_cfg.merge_seconds - (now - g_lastSplit);
        char buf[32];
        ImU32 tc;
        if (rem > 0) { snprintf(buf, sizeof(buf), "MERGE %.1fs", rem); tc = IM_COL32(255, 210, 90, 255); }
        else         { snprintf(buf, sizeof(buf), "CAN MERGE");        tc = IM_COL32(120, 255, 120, 255); }
        dtext(dl, ax, ay + myr + 4 * sc, buf, tc, sc);
    }

    // ---- Split-danger proximity alert ------------------------------------
    if (g_cfg.proximity_alert && inDanger) {
        dl->AddRect(ImVec2(2, 2), ImVec2(ow - 2, oh - 2), IM_COL32(255, 40, 40, 220), 0, 0, 4.0f);
        dtext(dl, ow * 0.5f, 8, "!! SPLIT DANGER !!", IM_COL32(255, 60, 60, 255), sc * 1.3f);
    }
}

// ---------------------------------------------------------------------------
// Overlay window + D3D11
// ---------------------------------------------------------------------------
static ID3D11Device*           g_dev = nullptr;
static ID3D11DeviceContext*    g_ctx = nullptr;
static IDXGISwapChain*         g_sc  = nullptr;
static ID3D11RenderTargetView* g_rtv = nullptr;
static HWND                    g_hwnd = nullptr;
static bool                    g_menuOpen = false;   // INSERT-toggled settings/interaction

static void CreateRTV() {
    ID3D11Texture2D* bb = nullptr;
    g_sc->GetBuffer(0, IID_PPV_ARGS(&bb));
    if (bb) { g_dev->CreateRenderTargetView(bb, nullptr, &g_rtv); bb->Release(); }
}
static void CleanRTV() { if (g_rtv) { g_rtv->Release(); g_rtv = nullptr; } }
static bool CreateDevice(HWND hWnd, int w, int h) {
    DXGI_SWAP_CHAIN_DESC sd = {};
    sd.BufferCount = 2;
    sd.BufferDesc.Width = w; sd.BufferDesc.Height = h;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hWnd; sd.SampleDesc.Count = 1; sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    D3D_FEATURE_LEVEL fl;
    const D3D_FEATURE_LEVEL lv[] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0 };
    if (D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, lv, 2,
            D3D11_SDK_VERSION, &sd, &g_sc, &g_dev, &fl, &g_ctx) != S_OK) return false;
    CreateRTV(); return true;
}
static void CleanDevice() {
    CleanRTV();
    if (g_sc)  { g_sc->Release();  g_sc = nullptr; }
    if (g_ctx) { g_ctx->Release(); g_ctx = nullptr; }
    if (g_dev) { g_dev->Release(); g_dev = nullptr; }
}

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND, UINT, WPARAM, LPARAM);
static LRESULT WINAPI WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (ImGui_ImplWin32_WndProcHandler(h, m, w, l)) return true;
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProc(h, m, w, l);
}

// Find the Roblox top-level window (largest visible window of the process).
struct FindWin { DWORD pid; HWND best; int area; };
static BOOL CALLBACK enumProc(HWND h, LPARAM lp) {
    FindWin* f = (FindWin*)lp;
    DWORD pid = 0; GetWindowThreadProcessId(h, &pid);
    if (pid != f->pid || !IsWindowVisible(h)) return TRUE;
    RECT r; if (!GetClientRect(h, &r)) return TRUE;
    int a = (r.right - r.left) * (r.bottom - r.top);
    if (a > f->area) { f->area = a; f->best = h; }
    return TRUE;
}
static HWND find_roblox_window() {
    DWORD pid = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap != INVALID_HANDLE_VALUE) {
        PROCESSENTRY32W pe = {}; pe.dwSize = sizeof(pe);
        if (Process32FirstW(snap, &pe)) do {
            char cvt[MAX_PATH] = {};
            WideCharToMultiByte(CP_UTF8, 0, pe.szExeFile, -1, cvt, MAX_PATH, 0, 0);
            if (_stricmp(cvt, rbx::PROC) == 0) { pid = pe.th32ProcessID; break; }
        } while (Process32NextW(snap, &pe));
        CloseHandle(snap);
    }
    if (!pid) return nullptr;
    FindWin f{ pid, nullptr, 0 };
    EnumWindows(enumProc, (LPARAM)&f);
    return f.best;
}

// Send a virtual-key press to the foreground window (Roblox).
static void tap_key(WORD vk) {
    INPUT in[2] = {};
    in[0].type = INPUT_KEYBOARD; in[0].ki.wVk = vk;
    in[1].type = INPUT_KEYBOARD; in[1].ki.wVk = vk; in[1].ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(2, in, sizeof(INPUT));
}

// Auto-eject: while hold_key is held, tap eject_key at eject_hz.
// Skipped while the settings menu is open so it never fights your typing.
static void run_macros(bool menuOpen) {
    if (!g_cfg.macro_eject || menuOpen) return;
    if (!(GetAsyncKeyState(g_cfg.hold_key) & 0x8000)) return;
    static ULONGLONG lastMs = 0;
    ULONGLONG now = GetTickCount64();
    int hz = g_cfg.eject_hz < 1 ? 1 : g_cfg.eject_hz;
    if (now - lastMs >= (ULONGLONG)(1000 / hz)) {
        lastMs = now;
        tap_key((WORD)g_cfg.eject_key);
    }
}

// Menu open  = interactive (mouse + keyboard reach ImGui, window focused).
// Menu closed = click-through, non-activating (input passes to Roblox).
static void apply_menu_state() {
    LONG ex = GetWindowLong(g_hwnd, GWL_EXSTYLE);
    if (g_menuOpen) {
        ex &= ~WS_EX_TRANSPARENT;
        ex &= ~WS_EX_NOACTIVATE;
        SetWindowLong(g_hwnd, GWL_EXSTYLE, ex);
        SetForegroundWindow(g_hwnd);
        SetActiveWindow(g_hwnd);
        SetFocus(g_hwnd);
    } else {
        ex |= WS_EX_TRANSPARENT;
        ex |= WS_EX_NOACTIVATE;
        SetWindowLong(g_hwnd, GWL_EXSTYLE, ex);
    }
}

static void settings_window() {
    ImGui::SetNextWindowBgAlpha(0.85f);
    ImGui::Begin("Agaric ESP  (INSERT to hide)", nullptr, ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::Checkbox("Enabled", &g_cfg.enabled);
    ImGui::InputText("Your name (blank=auto)", g_ownName, sizeof(g_ownName));

    ImGui::SeparatorText("Distance / clutter");
    ImGui::Combo("Lines",  &g_cfg.line_mode,  "All\0Threats only\0Off\0");
    ImGui::Combo("Labels", &g_cfg.label_mode, "All\0Threats only\0Off\0");
    ImGui::SliderFloat("Max distance (px, 0=all)", &g_cfg.max_dist, 0.0f, 2000.0f, "%.0f");
    ImGui::ColorEdit4("Line col", &g_cfg.col_line.x, ImGuiColorEditFlags_NoInputs);

    ImGui::SeparatorText("Threat");
    ImGui::Checkbox("Highlight", &g_cfg.threat_on); ImGui::SameLine();
    ImGui::Checkbox("Ring", &g_cfg.threat_ring); ImGui::SameLine();
    ImGui::Checkbox("Off-screen arrows##t", &g_cfg.threat_offscreen);
    ImGui::Checkbox("Split-danger alert", &g_cfg.proximity_alert);
    ImGui::SliderFloat("Eat mass ratio", &g_cfg.eat_ratio, 1.0f, 2.0f, "%.2f");
    ImGui::ColorEdit4("Threat col", &g_cfg.col_threat.x, ImGuiColorEditFlags_NoInputs); ImGui::SameLine();
    ImGui::ColorEdit4("Prey col", &g_cfg.col_prey.x, ImGuiColorEditFlags_NoInputs);

    ImGui::SeparatorText("Virus");
    ImGui::Checkbox("Show", &g_cfg.virus_on); ImGui::SameLine();
    ImGui::Checkbox("Tag", &g_cfg.virus_tag); ImGui::SameLine();
    ImGui::Checkbox("Off-screen arrows##v", &g_cfg.virus_offscreen);
    ImGui::SliderFloat("Min size (px)", &g_cfg.virus_min_px, 6.0f, 40.0f, "%.0f");
    ImGui::ColorEdit4("Virus col", &g_cfg.col_virus.x, ImGuiColorEditFlags_NoInputs);

    ImGui::SeparatorText("Offense");
    ImGui::Checkbox("Mark split-eat targets", &g_cfg.eat_targets);
    ImGui::ColorEdit4("Target col", &g_cfg.col_target.x, ImGuiColorEditFlags_NoInputs);

    ImGui::SeparatorText("Split range");
    ImGui::Checkbox("My reach", &g_cfg.split_self); ImGui::SameLine();
    ImGui::Checkbox("Threat reach", &g_cfg.split_threats);
    ImGui::SliderFloat("Reach x radius", &g_cfg.split_mult, 1.0f, 15.0f, "%.1f");
    ImGui::ColorEdit4("Reach col", &g_cfg.col_split.x, ImGuiColorEditFlags_NoInputs);

    ImGui::SeparatorText("Merge timer");
    ImGui::Checkbox("Show merge timer", &g_cfg.merge_on);
    ImGui::SliderFloat("Merge time (s)", &g_cfg.merge_seconds, 1.0f, 60.0f, "%.1f");
    ImGui::Text("(starts on Space / when your cell count rises)");

    ImGui::SeparatorText("Auto-eject macro (experimental)");
    ImGui::Checkbox("Enable auto-eject (hold W)", &g_cfg.macro_eject);
    ImGui::SliderInt("Eject rate (Hz)", &g_cfg.eject_hz, 3, 30, "%d");
    ImGui::Text("Taps '%c' while '%c' held. Server may cap the rate.",
                (char)g_cfg.eject_key, (char)g_cfg.hold_key);

    ImGui::SeparatorText("Display");
    ImGui::Checkbox("Auto-scale with my size", &g_cfg.auto_scale);
    ImGui::SliderFloat("UI scale", &g_cfg.ui_scale, 0.6f, 2.5f, "%.2f");

    ImGui::Separator();
    ImGui::TextDisabled(rbx::g_dm ? "attached  DM=0x%llX" : "waiting for Roblox...",
                        (unsigned long long)rbx::g_dm);
    ImGui::End();
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE, LPSTR, int) {
    WNDCLASSEXW wc = { sizeof(wc), CS_HREDRAW | CS_VREDRAW, WndProc, 0, 0, hInst, nullptr,
                       nullptr, nullptr, nullptr, L"AgaricEsp", nullptr };
    RegisterClassExW(&wc);
    g_hwnd = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        wc.lpszClassName, L"AgaricEsp", WS_POPUP, 0, 0, 800, 600, nullptr, nullptr, hInst, nullptr);
    // Color-key black -> transparent.
    SetLayeredWindowAttributes(g_hwnd, RGB(0, 0, 0), 0, LWA_COLORKEY);

    if (!CreateDevice(g_hwnd, 800, 600)) { CleanDevice(); return 1; }
    ShowWindow(g_hwnd, SW_SHOWNOACTIVATE);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::StyleColorsDark();
    ImGui_ImplWin32_Init(g_hwnd);
    ImGui_ImplDX11_Init(g_dev, g_ctx);

    int curW = 800, curH = 600;
    bool prevInsert = false;
    bool running = true;
    while (running) {
        MSG msg;
        while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg); DispatchMessage(&msg);
            if (msg.message == WM_QUIT) running = false;
        }
        if (!running) break;

        // INSERT toggles interactive settings / click-through.
        bool insDown = (GetAsyncKeyState(VK_INSERT) & 0x8000) != 0;
        if (insDown && !prevInsert) { g_menuOpen = !g_menuOpen; apply_menu_state(); }
        prevInsert = insDown;

        run_macros(g_menuOpen);

        // (Re)attach to Roblox as needed.
        if (!rbx::alive()) rbx::detach();
        if (!rbx::g_dm) rbx::attach();

        // Align overlay to the Roblox client area.
        HWND rbw = find_roblox_window();
        int ow = curW, oh = curH;
        if (rbw) {
            RECT cr; POINT tl = { 0, 0 };
            if (GetClientRect(rbw, &cr) && ClientToScreen(rbw, &tl)) {
                ow = cr.right - cr.left; oh = cr.bottom - cr.top;
                if (ow < 1) ow = 1; if (oh < 1) oh = 1;
                SetWindowPos(g_hwnd, HWND_TOPMOST, tl.x, tl.y, ow, oh, SWP_NOACTIVATE);
                if (ow != curW || oh != curH) {
                    CleanRTV();
                    g_sc->ResizeBuffers(0, ow, oh, DXGI_FORMAT_UNKNOWN, 0);
                    CreateRTV();
                    curW = ow; curH = oh;
                }
            }
        }

        ImGui_ImplDX11_NewFrame();
        ImGui_ImplWin32_NewFrame();
        ImGui::NewFrame();

        if (rbx::g_dm) render_esp((float)curW, (float)curH);
        if (g_menuOpen) settings_window();

        ImGui::Render();
        const float clear[4] = { 0, 0, 0, 0 }; // black = color-keyed transparent
        g_ctx->OMSetRenderTargets(1, &g_rtv, nullptr);
        g_ctx->ClearRenderTargetView(g_rtv, clear);
        ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
        g_sc->Present(1, 0);
    }

    rbx::detach();
    ImGui_ImplDX11_Shutdown();
    ImGui_ImplWin32_Shutdown();
    ImGui::DestroyContext();
    CleanDevice();
    DestroyWindow(g_hwnd);
    UnregisterClassW(wc.lpszClassName, hInst);
    return 0;
}
