# Apply the existing reviewed geometric identity after the preserved donor/format overlays.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$source = Join-Path $root 'editor/lapce'
$patch = Join-Path $root 'editor/patches/codestrike-geometric-overlay.patch'
$assets = @{
    'CodeStrike-geometric.png' = 'bc52e0a0ff2ee6553f6d8bf9c91e92d044cf742532db8611320ecd0a621a1c80'
    'CodeStrike-geometric.svg' = '27e871c8413625fcbe85897c3a2708b8f0c1ba8b35ec0b24c9e149b48109a384'
    'CodeStrike-geometric-mono.svg' = '7d71e82a717abcb52514cf8bb2bcb913af076af46d40ebe21d373620143fc8c5'
    'CodeStrike-geometric.ico' = '8a4d0e28a801bcf6c552d739ee0c67aec99de5e3265e8aa2a51829d4d3f84d79'
}
foreach ($name in $assets.Keys) {
    $path = Join-Path $root "assets/branding/$name"
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $assets[$name]) {
        throw "Reviewed geometric asset differs: $name"
    }
}
& git -C $source apply --check -- $patch
if ($LASTEXITCODE -ne 0) {
    & git -C $source apply --reverse --check -- $patch
    if ($LASTEXITCODE -ne 0) { throw 'Geometric overlay does not match prepared Lapce source.' }
    Write-Output 'Lapce geometric overlay already present.'
    exit 0
}
& git -C $source apply -- $patch
if ($LASTEXITCODE -ne 0) { throw 'Lapce geometric overlay failed.' }
