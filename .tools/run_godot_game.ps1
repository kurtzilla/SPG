# Run SPG in Godot 4.3 .NET (game window). Use when F5 debug does not spawn Godot.
param(
    [switch]$DebugServer
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $PSScriptRoot "find_godot.ps1")

$godot = Get-SpgGodotExe
if (-not $godot) {
    Write-Error "Godot 4 C# not found. Set godotTools.editorPath.godot4 in .vscode/settings.json or install via gdvm."
}

$args = @("--path", $repo)
if ($DebugServer) {
    $args += "--debug-server", "6007"
}

Write-Host "Starting: $godot $($args -join ' ')"
& $godot @args
