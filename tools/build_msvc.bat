@echo off
REM ==========================================================================
REM  Build the Roblox tools with MSVC.
REM  Run from the "x64 Native Tools Command Prompt for VS" (targets x64).
REM
REM  Usage:   build_msvc.bat            -> builds both (esp overlay + dex)
REM           build_msvc.bat overlay    -> just the ESP overlay (agaric_esp.exe)
REM           build_msvc.bat dex        -> just the explorer   (dex.exe)
REM
REM  Set IMGUI to your Dear ImGui checkout (folder with imgui.cpp + backends\).
REM  Grab it from https://github.com/ocornut/imgui
REM ==========================================================================
setlocal
if "%IMGUI%"=="" set "IMGUI=C:\imgui"
set "TARGET=%1"
if "%TARGET%"=="" set "TARGET=all"

if not exist "%IMGUI%\imgui.cpp" (
  echo [!] ImGui not found at "%IMGUI%".
  echo     Set it first, e.g.:  set IMGUI=C:\path\to\imgui
  exit /b 1
)

set "IMGUI_SRC=%IMGUI%\imgui.cpp %IMGUI%\imgui_draw.cpp %IMGUI%\imgui_tables.cpp %IMGUI%\imgui_widgets.cpp %IMGUI%\backends\imgui_impl_win32.cpp %IMGUI%\backends\imgui_impl_dx11.cpp"
set "COMMON=/nologo /std:c++17 /EHsc /O2 /MD /I"%IMGUI%" /I"%IMGUI%\backends""
set "LIBS=/link d3d11.lib dxgi.lib d3dcompiler.lib psapi.lib user32.lib gdi32.lib"

if /I "%TARGET%"=="all"     goto :overlay
if /I "%TARGET%"=="overlay" goto :overlay
if /I "%TARGET%"=="dex"     goto :dex
echo Unknown target "%TARGET%" (use: overlay ^| dex ^| all) & exit /b 1

:overlay
echo === Building agaric_esp.exe (ESP overlay) ===
cl %COMMON% agaric_esp_overlay.cpp %IMGUI_SRC% /Fe:agaric_esp.exe %LIBS%
if errorlevel 1 exit /b 1
if /I "%TARGET%"=="overlay" goto :done

:dex
echo === Building dex.exe (explorer) ===
cl %COMMON% dex_standalone_main.cpp roblox_explorer_dex.cpp %IMGUI_SRC% /Fe:dex.exe %LIBS%
if errorlevel 1 exit /b 1

:done
echo.
echo [OK] Build complete. Run the .exe as Administrator.
endlocal
