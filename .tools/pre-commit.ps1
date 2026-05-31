# Git pre-commit: fog/grid smoke when related files are staged.
$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Push-Location $repo
try {
    $staged = @(git diff --cached --name-only 2>$null)
    if ($staged.Count -eq 0) {
        exit 0
    }

    $fogPatterns = @(
        "src/Godot/Shaders/FogOverlay.gdshader",
        "src/Godot/Scenes/FogOverlay.tscn",
        "src/Godot/Scripts/Systems/fog-of-war/",
        "src/Godot/Scripts/MainSandbox.gd",
        "src/Godot/Interop/VisibilityModelGd.cs",
        "src/Core/Models/VisibilityModel.cs",
        "tools/fog_smoke.gd",
        "tools/FogSmokeRunner.tscn"
    )

    $gridPatterns = @(
        "src/Godot/Shaders/GridOverlay.gdshader",
        "src/Godot/Scenes/GridOverlay.tscn",
        "src/Godot/Scripts/GridOverlay.gd",
        "src/Godot/Scripts/GridPerfProfile.gd",
        "src/Godot/Scripts/MainSandbox.gd",
        "tools/grid_smoke.gd",
        "tools/GridSmokeRunner.tscn"
    )

    $touchesFog = $false
    foreach ($path in $staged) {
        foreach ($pattern in $fogPatterns) {
            if ($path -eq $pattern -or $path.StartsWith($pattern)) {
                $touchesFog = $true
                break
            }
        }
        if ($touchesFog) { break }
    }

    $touchesGrid = $false
    foreach ($path in $staged) {
        foreach ($pattern in $gridPatterns) {
            if ($path -eq $pattern -or $path.StartsWith($pattern)) {
                $touchesGrid = $true
                break
            }
        }
        if ($touchesGrid) { break }
    }

    if (-not $touchesFog -and -not $touchesGrid) {
        exit 0
    }

    if ($touchesFog) {
        Write-Host "pre-commit: running fog smoke (staged paths touch fog) ..."
        & (Join-Path $PSScriptRoot "run_fog_smoke.ps1")
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    if ($touchesGrid) {
        Write-Host "pre-commit: running grid smoke (staged paths touch grid) ..."
        & (Join-Path $PSScriptRoot "run_grid_smoke.ps1")
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    exit 0
}
finally {
    Pop-Location
}
