// ============================================================================
//  Standalone host for roblox_explorer_dex.cpp
//  Dear ImGui + Win32 + DirectX11 (based on the official ImGui example).
//  Builds a window that renders the Dex explorer content each frame.
//
//  Build (x64 Native Tools Command Prompt for VS) -- see build_msvc.bat:
//    cl /nologo /std:c++17 /EHsc /O2 /MD ^
//       /I"C:\imgui" /I"C:\imgui\backends" ^
//       dex_standalone_main.cpp roblox_explorer_dex.cpp ^
//       "C:\imgui\imgui.cpp" "C:\imgui\imgui_draw.cpp" ^
//       "C:\imgui\imgui_tables.cpp" "C:\imgui\imgui_widgets.cpp" ^
//       "C:\imgui\backends\imgui_impl_win32.cpp" ^
//       "C:\imgui\backends\imgui_impl_dx11.cpp" ^
//       /Fe:dex.exe ^
//       /link d3d11.lib dxgi.lib d3dcompiler.lib psapi.lib user32.lib gdi32.lib
//
//  Run as Administrator (ReadProcessMemory on Roblox needs it).
// ============================================================================
#include "imgui.h"
#include "backends/imgui_impl_win32.h"
#include "backends/imgui_impl_dx11.h"
#include <d3d11.h>
#include <tchar.h>

// Entry points implemented in roblox_explorer_dex.cpp
void Dex_DrawContent();
void Dex_SetVisible(bool);
void Dex_Shutdown();

// ---- D3D globals -----------------------------------------------------------
static ID3D11Device*            g_pd3dDevice        = nullptr;
static ID3D11DeviceContext*     g_pd3dDeviceContext = nullptr;
static IDXGISwapChain*          g_pSwapChain        = nullptr;
static ID3D11RenderTargetView*  g_mainRTV           = nullptr;

void CreateRenderTarget() {
    ID3D11Texture2D* pBack = nullptr;
    g_pSwapChain->GetBuffer(0, IID_PPV_ARGS(&pBack));
    if (pBack) { g_pd3dDevice->CreateRenderTargetView(pBack, nullptr, &g_mainRTV); pBack->Release(); }
}
void CleanupRenderTarget() { if (g_mainRTV) { g_mainRTV->Release(); g_mainRTV = nullptr; } }

bool CreateDeviceD3D(HWND hWnd) {
    DXGI_SWAP_CHAIN_DESC sd = {};
    sd.BufferCount = 2;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferDesc.RefreshRate.Numerator = 60;
    sd.BufferDesc.RefreshRate.Denominator = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hWnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    UINT flags = 0;
    D3D_FEATURE_LEVEL fl;
    const D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0 };
    if (D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
            levels, 2, D3D11_SDK_VERSION, &sd, &g_pSwapChain, &g_pd3dDevice, &fl,
            &g_pd3dDeviceContext) != S_OK)
        return false;
    CreateRenderTarget();
    return true;
}
void CleanupDeviceD3D() {
    CleanupRenderTarget();
    if (g_pSwapChain)        { g_pSwapChain->Release();        g_pSwapChain = nullptr; }
    if (g_pd3dDeviceContext) { g_pd3dDeviceContext->Release(); g_pd3dDeviceContext = nullptr; }
    if (g_pd3dDevice)        { g_pd3dDevice->Release();        g_pd3dDevice = nullptr; }
}

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND, UINT, WPARAM, LPARAM);

LRESULT WINAPI WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (ImGui_ImplWin32_WndProcHandler(hWnd, msg, wParam, lParam)) return true;
    switch (msg) {
    case WM_SIZE:
        if (g_pd3dDevice && wParam != SIZE_MINIMIZED) {
            CleanupRenderTarget();
            g_pSwapChain->ResizeBuffers(0, (UINT)LOWORD(lParam), (UINT)HIWORD(lParam),
                                        DXGI_FORMAT_UNKNOWN, 0);
            CreateRenderTarget();
        }
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProc(hWnd, msg, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE, LPSTR, int) {
    WNDCLASSEXW wc = { sizeof(wc), CS_CLASSDC, WndProc, 0, 0, hInst, nullptr, nullptr,
                       nullptr, nullptr, L"DexHost", nullptr };
    RegisterClassExW(&wc);
    HWND hwnd = CreateWindowW(wc.lpszClassName, L"Roblox Dex Explorer", WS_OVERLAPPEDWINDOW,
                              100, 100, 1100, 720, nullptr, nullptr, wc.hInstance, nullptr);

    if (!CreateDeviceD3D(hwnd)) { CleanupDeviceD3D(); UnregisterClassW(wc.lpszClassName, wc.hInstance); return 1; }
    ShowWindow(hwnd, SW_SHOWDEFAULT);
    UpdateWindow(hwnd);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::GetIO().ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    ImGui::StyleColorsDark();
    ImGui_ImplWin32_Init(hwnd);
    ImGui_ImplDX11_Init(g_pd3dDevice, g_pd3dDeviceContext);

    Dex_SetVisible(true);

    bool running = true;
    while (running) {
        MSG msg;
        while (PeekMessage(&msg, nullptr, 0U, 0U, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
            if (msg.message == WM_QUIT) running = false;
        }
        if (!running) break;

        ImGui_ImplDX11_NewFrame();
        ImGui_ImplWin32_NewFrame();
        ImGui::NewFrame();

        // Host the Dex content inside a docked/fullscreen window.
        const ImGuiViewport* vp = ImGui::GetMainViewport();
        ImGui::SetNextWindowPos(vp->WorkPos);
        ImGui::SetNextWindowSize(vp->WorkSize);
        ImGui::Begin("Roblox Dex", nullptr,
                     ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                     ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoBringToFrontOnFocus);
        Dex_DrawContent();
        ImGui::End();

        ImGui::Render();
        const float clear[4] = { 0.08f, 0.09f, 0.11f, 1.0f };
        g_pd3dDeviceContext->OMSetRenderTargets(1, &g_mainRTV, nullptr);
        g_pd3dDeviceContext->ClearRenderTargetView(g_mainRTV, clear);
        ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
        g_pSwapChain->Present(1, 0); // vsync
    }

    Dex_Shutdown();
    ImGui_ImplDX11_Shutdown();
    ImGui_ImplWin32_Shutdown();
    ImGui::DestroyContext();
    CleanupDeviceD3D();
    DestroyWindow(hwnd);
    UnregisterClassW(wc.lpszClassName, wc.hInstance);
    return 0;
}
