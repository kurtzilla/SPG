@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem =============================================================================
rem  Start Godot editor for this repo if no matching process is running.
rem  Targeting the parent directory (..) because this script is in .tools/
rem =============================================================================

for %%I in ("%~dp0..") do set "REPO=%%~fI"
set "GODOT_PROJECT=%REPO%"

set "GSTEM="
set "GDVM_GODOT_EXE="

rem Check for gdvm environment tools
for /f "delims=" %%i in ('gdvm show --csharp 2^>nul') do for %%A in ("%%i") do set "GSTEM=%%~nA"
for /f "delims=" %%i in ('gdvm show --csharp 2^>nul') do set "GDVM_GODOT_EXE=%%i"

if defined GSTEM (
    tasklist | findstr /I /C:"!GSTEM!" >nul 2>&1
) else (
    tasklist | findstr /I "Godot_" >nul 2>&1
)

if errorlevel 1 (
    echo [EnsureGodotEditor] No running Godot instance found. Launching editor at root...
    
    if defined GDVM_GODOT_EXE if exist "!GDVM_GODOT_EXE!" (
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '!GDVM_GODOT_EXE!' -ArgumentList '--path','%GODOT_PROJECT%','--editor' | Out-Null"
        goto :done
    )
    
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'godot' -ArgumentList '--path','%GODOT_PROJECT%','--editor' | Out-Null"
) else (
    echo [EnsureGodotEditor] Godot Editor is already running. Skipping launch.
)

:done
endlocal