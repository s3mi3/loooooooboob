@echo off
REM ==========================================================================
REM  Build the standalone Roblox Dex explorer with MSVC.
REM  Run this from the "x64 Native Tools Command Prompt for VS" (targets x64).
REM
REM  Set IMGUI to your Dear ImGui checkout (the folder with imgui.cpp and a
REM  backends\ subfolder). Grab it from https://github.com/ocornut/imgui
REM ==========================================================================
setlocal
if "%IMGUI%"=="" set "IMGUI=C:\imgui"

if not exist "%IMGUI%\imgui.cpp" (
  echo [!] ImGui not found at "%IMGUI%".
  echo     Set it first, e.g.:  set IMGUI=C:\path\to\imgui
  exit /b 1
)

cl /nologo /std:c++17 /EHsc /O2 /MD ^
   /I"%IMGUI%" /I"%IMGUI%\backends" ^
   dex_standalone_main.cpp roblox_explorer_dex.cpp ^
   "%IMGUI%\imgui.cpp" "%IMGUI%\imgui_draw.cpp" ^
   "%IMGUI%\imgui_tables.cpp" "%IMGUI%\imgui_widgets.cpp" ^
   "%IMGUI%\backends\imgui_impl_win32.cpp" ^
   "%IMGUI%\backends\imgui_impl_dx11.cpp" ^
   /Fe:dex.exe ^
   /link d3d11.lib dxgi.lib d3dcompiler.lib psapi.lib user32.lib gdi32.lib

if %errorlevel%==0 (
  echo.
  echo [OK] Built dex.exe  -- right-click ^> Run as administrator.
)
endlocal
