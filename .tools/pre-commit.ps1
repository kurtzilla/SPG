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
        $atomic = @(
            "src/Godot/Shaders/FogOverlay.gdshader",
            "src/Godot/Scripts/Systems/fog-of-war/FogOverlay.gd",
            "src/Godot/Scenes/FogOverlay.tscn"
        )
        $atomicStaged = @($staged | Where-Object { $_ -in $atomic })
        if ($atomicStaged.Count -gt 0 -and $atomicStaged.Count -lt $atomic.Count) {
            $missing = @($atomic | Where-Object { $_ -notin $staged })
            Write-Host ""
            Write-Host "WARNING: Partial fog commit ($($atomicStaged.Count)/$($atomic.Count) atomic files)." -ForegroundColor Yellow
            Write-Host "  Missing: $($missing -join ', ')" -ForegroundColor Yellow
            Write-Host "  Commit all fog atomic files together, or set FOG_SKIP_ATOMIC=1 to bypass." -ForegroundColor Yellow
            Write-Host ""
            if ($env:FOG_SKIP_ATOMIC -ne "1") {
                exit 1
            }
        }

        Write-Host "pre-commit: running fog smoke (staged paths touch fog) ..."
        & (Join-Path $PSScriptRoot "run_fog_smoke.ps1")
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    if ($touchesGrid) {
        $gridAtomic = @(
            "src/Godot/Shaders/GridOverlay.gdshader",
            "src/Godot/Scripts/GridOverlay.gd",
            "src/Godot/Scenes/GridOverlay.tscn"
        )
        $gridAtomicStaged = @($staged | Where-Object { $_ -in $gridAtomic })
        if ($gridAtomicStaged.Count -gt 0 -and $gridAtomicStaged.Count -lt $gridAtomic.Count) {
            $missing = @($gridAtomic | Where-Object { $_ -notin $staged })
            Write-Host ""
            Write-Host "WARNING: Partial grid commit ($($gridAtomicStaged.Count)/$($gridAtomic.Count) atomic files)." -ForegroundColor Yellow
            Write-Host "  Missing: $($missing -join ', ')" -ForegroundColor Yellow
            Write-Host "  Commit all grid atomic files together, or set GRID_SKIP_ATOMIC=1 to bypass." -ForegroundColor Yellow
            Write-Host ""
            if ($env:GRID_SKIP_ATOMIC -ne "1") {
                exit 1
            }
        }

        Write-Host "pre-commit: running grid smoke (staged paths touch grid) ..."
        & (Join-Path $PSScriptRoot "run_grid_smoke.ps1")
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    exit 0
}
finally {
    Pop-Location
}
