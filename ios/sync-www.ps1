$ErrorActionPreference = "Stop"
$src = Join-Path $PSScriptRoot "..\app\src\main\assets"
$dst = Join-Path $PSScriptRoot "TaxiAndFlyClient\www"
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
New-Item -ItemType Directory -Path $dst | Out-Null
Get-ChildItem $src -File | Where-Object { $_.Name -notlike "*.bak*" } | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $dst $_.Name) -Force
}
Write-Output "Synced www from Android assets -> $dst"
Get-ChildItem $dst | Select-Object Name, Length
