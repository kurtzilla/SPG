$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "C:\Users\Dev\.gdvm\installs\4.6.3-stable-csharp\Godot_v4.6.3-stable_mono_win64.exe"
$psi.Arguments = "--path `"$PSScriptRoot\..`" --editor"
$psi.WindowStyle = "Minimized"
[System.Diagnostics.Process]::Start($psi)