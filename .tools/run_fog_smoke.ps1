# Headless fog regression gate (~5s). Exit 0 = pass, 1 = fail.
$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $PSScriptRoot "find_godot.ps1")

$godot = Get-SpgGodotExe
if (-not $godot) {
    Write-Error "Godot mono not found. Install Godot 4 C# or add 'godot' to PATH."
}

Write-Host "FOG_SMOKE: building C# ..."
Push-Location $repo
try {
    dotnet build (Join-Path $repo "SPG.sln") -c Debug -v q
    if ($LASTEXITCODE -ne 0) {
        Write-Error "dotnet build failed before fog smoke"
    }

    Write-Host "FOG_SMOKE: $godot --headless res://tools/FogSmokeRunner.tscn"
    & $godot --headless --path $repo res://tools/FogSmokeRunner.tscn
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
