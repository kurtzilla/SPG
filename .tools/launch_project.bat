@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================================
rem  Launch Godot headlessly for the language server (LSP), then open Cursor.
rem  Targeting the parent directory (..) because this script is in .tools/
rem ============================================================================

for %%I in ("%~dp0..") do set "REPO=%%~fI"
set "CURSOR_EXE=%LOCALAPPDATA%\Programs\cursor\Cursor.exe"

echo [Launch] Starting Godot headless language server...
rem 'start /b' keeps the window attached silently instead of popping up a command window.
start /b "" godot.exe --editor --headless --path "%REPO%"

rem Brief pause to give the Godot LSP server a head start to open its port
timeout /t 2 /nobreak >nul

if exist "%CURSOR_EXE%" (
    echo [Launch] Starting Cursor...
    start "" "%CURSOR_EXE%" "%REPO%"
) else (
    echo [Launch] Cursor not found in LocalAppData, falling back to PATH environment...
    start "" cursor "%REPO%"
)

endlocal