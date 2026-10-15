$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$source = Join-Path $root 'editor\lapce'
$patch = Join-Path $root 'editor\patches\codestrike-lapce.patch'
$logo = Join-Path $root 'assets\branding\CodeStrike.png'
$pinned = 'b012cef466741528f338879fa708355217fc40bd'
$logoSha256 = '0dcdb1c9ce3c0e0189329178498b4ebab9a4663f10ca9912235cef3d833fae76'

if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw 'Lapce submodule is absent. Check out the repository with submodules enabled.'
}
if (-not (Test-Path -LiteralPath $patch -PathType Leaf)) { throw 'Migration patch is absent.' }
if (-not (Test-Path -LiteralPath $logo -PathType Leaf)) { throw 'Approved CodeStrike logo is absent.' }

$actual = (& git -C $source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actual -ne $pinned) { throw "Lapce source is not pinned to $pinned (found $actual)." }
$dirty = & git -C $source status --porcelain
if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'Lapce submodule has unreviewed local changes.' }
$actualLogo = (Get-FileHash -LiteralPath $logo -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualLogo -ne $logoSha256) { throw 'CodeStrike logo differs from the approved provenance hash.' }

& git -C $source apply --check --unidiff-zero -- $patch
if ($LASTEXITCODE -ne 0) { throw 'Migration patch does not apply cleanly to pinned Lapce.' }
& git -C $source apply --unidiff-zero -- $patch
if ($LASTEXITCODE -ne 0) { throw 'Migration patch failed.' }
& git -C $source diff --check
if ($LASTEXITCODE -ne 0) { throw 'Migration patch introduced whitespace errors.' }

Write-Output 'Pinned Lapce source prepared for the CodeStrike editor candidate.'
