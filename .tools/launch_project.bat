@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================================
rem  Ensure Godot editor is running for this root project, then open Cursor.
rem  Targeting the parent directory (..) because this script is in .tools/
rem ============================================================================

for %%I in ("%~dp0..") do set "REPO=%%~fI"
set "CURSOR_EXE=%LOCALAPPDATA%\Programs\cursor\Cursor.exe"

rem Call EnsureGodotEditor out of the same .tools folder
call "%~dp0ensure_godot_editor.bat"

rem Brief pause to give the Godot LSP server a head start to open port 6008
timeout /t 2 /nobreak >nul

if exist "%CURSOR_EXE%" (
    echo [Launch] Starting Cursor...
    start "" "%CURSOR_EXE%" "%REPO%"
) else (
    echo [Launch] Cursor not found in LocalAppData, falling back to PATH environment...
    start "" cursor "%REPO%"
)

endlocal