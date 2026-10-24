# Explicit source-build route. Never installs a server or changes user settings.
param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$TargetDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rust-toolchain-guard.ps1')
$compiler = @(& rustc +1.97.1 -vV)
$compilerExit = $LASTEXITCODE
Assert-RustcCommitHash -CompilerOutput $compiler -ExitCode $compilerExit -ExpectedCommit '8bab26f4f68e0e26f0bb7960be334d5b520ea452'
& (Join-Path $PSScriptRoot 'prepare-reviewed-source.ps1') -SourcePath $SourcePath
$manifest = Join-Path (Resolve-Path -LiteralPath $SourcePath).Path 'Cargo.toml'
$target = [IO.Path]::GetFullPath($TargetDirectory)
$previousRelease = $env:CFG_RELEASE
$previousChannel = $env:CFG_RELEASE_CHANNEL
try {
    $env:CFG_RELEASE = '1.99.0'
    $env:CFG_RELEASE_CHANNEL = 'stable'
    & cargo +1.97.1 fetch --locked --manifest-path $manifest
    if ($LASTEXITCODE -ne 0) { throw 'Reviewed analyzer dependency fetch failed.' }
    & cargo +1.97.1 build --locked --offline --manifest-path $manifest --target-dir $target -p rust-analyzer --bin rust-analyzer
    if ($LASTEXITCODE -ne 0) { throw 'Reviewed analyzer build failed.' }
    & cargo +1.97.1 test --locked --offline --manifest-path $manifest --target-dir $target -p rust-analyzer --lib
    if ($LASTEXITCODE -ne 0) { throw 'Reviewed analyzer library regressions failed.' }
    $binary = Join-Path $target 'debug/rust-analyzer.exe'
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw 'Reviewed Windows analyzer binary missing.' }
    & $binary --version
    if ($LASTEXITCODE -ne 0) { throw 'Reviewed analyzer version check failed.' }
    "CODESTRIKE_REVIEWED_ANALYZER_PATH=$binary"
    "CODESTRIKE_REVIEWED_ANALYZER_SHA256=$((Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash)"
} finally {
    $env:CFG_RELEASE = $previousRelease
    $env:CFG_RELEASE_CHANNEL = $previousChannel
}
