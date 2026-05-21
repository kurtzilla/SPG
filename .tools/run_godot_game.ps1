# Run SPG in Godot 4.3 .NET (game window). Use when F5 debug does not spawn Godot.
param(
    [switch]$DebugServer
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$godot = "C:\Users\Dev\.gdvm\installs\4.3-stable-csharp\Godot_v4.3-stable_mono_win64.exe"
if (-not (Test-Path -LiteralPath $godot)) {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $fromGdvm = gdvm show --csharp 2>&1 | Where-Object { "$_" -match '\.exe$' } | Select-Object -First 1
    $ErrorActionPreference = $prevEap
    if ($fromGdvm) {
        $godot = "$fromGdvm".Trim()
    }
}
if (-not (Test-Path -LiteralPath $godot)) {
    Write-Error "Godot 4.3 C# not found. Install: gdvm install 4.3-stable-csharp"
}

$args = @("--path", $repo)
if ($DebugServer) {
    $args += "--debug-server", "6007"
}

Write-Host "Starting: $godot $($args -join ' ')"
& $godot @args
