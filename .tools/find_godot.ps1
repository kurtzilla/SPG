# Resolve Godot 4 .NET executable for SPG tooling (grid-smoke, run game, etc.).
function Get-SpgGodotExe {
    $repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $settingsPath = Join-Path $repo ".vscode\settings.json"

    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $raw = Get-Content -LiteralPath $settingsPath -Raw
            if ($raw -match '"godotTools\.editorPath\.godot4"\s*:\s*"([^"]+)"') {
                $fromSettings = $Matches[1] -replace '\\\\', '\'
                if ($fromSettings -and (Test-Path -LiteralPath $fromSettings)) {
                    return (Resolve-Path -LiteralPath $fromSettings).Path
                }
            }
        }
        catch {
            Write-Warning "Could not read Godot path from $settingsPath`: $_"
        }
    }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $fromGdvm = gdvm show --csharp 2>&1 | Where-Object { "$_" -match '\.exe$' } | Select-Object -First 1
    $ErrorActionPreference = $prevEap
    if ($fromGdvm) {
        $candidate = "$fromGdvm".Trim()
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}
