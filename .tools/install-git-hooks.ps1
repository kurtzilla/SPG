# Install SPG git hooks (pre-commit grid smoke). Run once per clone.
$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$hooksDir = Join-Path $repo ".git\hooks"
if (-not (Test-Path -LiteralPath $hooksDir)) {
    Write-Error "Not a git repo: .git/hooks missing"
}

$hookPath = Join-Path $hooksDir "pre-commit"
$preCommitPs1 = (Join-Path $repo ".tools/pre-commit.ps1") -replace '\\', '/'
$hookLines = @(
    "#!/bin/sh",
    "# SPG pre-commit - grid smoke when related files staged",
    "exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$preCommitPs1`""
)
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($hookPath, ($hookLines -join "`n") + "`n", $utf8NoBom)
Write-Host "Installed: $hookPath"
Write-Host "Grid smoke runs on commit when staged paths touch those systems."
