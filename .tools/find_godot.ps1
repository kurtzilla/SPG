# Resolve Godot 4 mono executable for SPG tooling.
$ErrorActionPreference = "Stop"

function Get-SpgGodotExe {
    $cmd = Get-Command godot -ErrorAction SilentlyContinue
    if ($cmd -and (Test-Path -LiteralPath $cmd.Source)) {
        return $cmd.Source
    }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $fromGdvm = gdvm show --csharp 2>&1 | Where-Object { "$_" -match '\.exe$' } | Select-Object -First 1
    $ErrorActionPreference = $prevEap
    if ($fromGdvm) {
        $path = "$fromGdvm".Trim()
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    $gdvmRoot = Join-Path $env:USERPROFILE ".gdvm\installs"
    if (Test-Path -LiteralPath $gdvmRoot) {
        $candidates = Get-ChildItem -LiteralPath $gdvmRoot -Recurse -Filter "Godot*_mono_win64.exe" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        if ($candidates) {
            return $candidates[0].FullName
        }
    }

    return $null
}
