@echo off
setlocal EnableExtensions

for %%I in ("%~dp0..") do set "REPO=%%~fI"

set "GODOT_EXE="
for /f "delims=" %%i in ('gdvm show --csharp 2^>nul') do set "GODOT_EXE=%%i"

if not defined GODOT_EXE (
    echo [open_godot_csharp_editor] gdvm not found or no 4.3 C# install. Install: gdvm install 4.3-stable-csharp
    exit /b 1
)

if not exist "%GODOT_EXE%" (
    echo [open_godot_csharp_editor] Missing: %GODOT_EXE%
    exit /b 1
)

echo [open_godot_csharp_editor] %GODOT_EXE%
start "" "%GODOT_EXE%" --path "%REPO%" --editor
endlocal
