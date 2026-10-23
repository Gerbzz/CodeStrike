# CodeStrike has one editor: our preserved, pinned Lapce source and patch.
# Preparation refuses dirty upstream source rather than resetting user work.
param([switch]$Prepared, [switch]$Release)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $Prepared) { & (Join-Path $PSScriptRoot 'prepare-lapce.ps1') }
$argsForCargo = @('build', '--manifest-path', (Join-Path $root 'editor/lapce/Cargo.toml'), '--locked', '--bin', 'lapce')
if ($Release) { $argsForCargo += '--release' }
& cargo @argsForCargo
if ($LASTEXITCODE -ne 0) { throw 'Lapce-based CodeStrike build failed.' }
$profile = if ($Release) { 'release' } else { 'debug' }
Write-Output "Built Lapce-based CodeStrike: $root/editor/lapce/target/$profile/lapce.exe"
