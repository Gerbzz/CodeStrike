param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [switch]$WithTestHooks
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$source = (Resolve-Path -LiteralPath $SourcePath).Path
$pin = Join-Path $repo 'third_party/rust-analyzer'
$patch = Join-Path $pin 'reviewed-v12.patch'
$hooks = Join-Path $pin 'test-hooks.patch'
$base = 'a0b58c0fe3e924302c1155e88c4a9454f86280c2'
$patchHash = '2DA3C80CEFFDA7934C6A9186E8C6F424F0ECF0B26D3F75FC843015C9DC3F712A'
$hookHash = '450D849112C3EB0F28F9AD446A320C992412EEB6C51EA1955480B480736062D2'
$lockHash = 'B89F654112D04F4F562061AB717DB444BD4D6387D37A52E13DD93115643235C3'
$expected = @(
    'crates/rust-analyzer/src/diagnostics.rs',
    'crates/rust-analyzer/src/flycheck.rs',
    'crates/rust-analyzer/src/global_state.rs',
    'crates/rust-analyzer/src/handlers/notification.rs',
    'crates/rust-analyzer/src/main_loop.rs',
    'crates/rust-analyzer/src/mem_docs.rs',
    'crates/rust-analyzer/src/op_queue.rs',
    'crates/rust-analyzer/src/reload.rs'
)

function Assert-Exit([string]$step) {
    if ($LASTEXITCODE -ne 0) { throw "$step failed with exit code $LASTEXITCODE" }
}
function Assert-Hash([string]$path, [string]$wanted) {
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($actual -ne $wanted) { throw "SHA256 mismatch for $path`: $actual" }
}

$head = (& git -C $source rev-parse HEAD).Trim()
Assert-Exit 'read source HEAD'
if ($head -ne $base) { throw "Analyzer source HEAD differs from reviewed base: $head" }
$dirty = @(& git -C $source status --porcelain)
Assert-Exit 'read source status'
if ($dirty.Count -ne 0) { throw 'Analyzer source is not clean before applying the reviewed patch.' }
Assert-Hash $patch $patchHash
Assert-Hash $hooks $hookHash
Assert-Hash (Join-Path $source 'Cargo.lock') $lockHash

& git -C $source apply --check -- $patch
Assert-Exit 'check reviewed analyzer patch'
& git -C $source apply -- $patch
Assert-Exit 'apply reviewed analyzer patch'
if ($WithTestHooks) {
    & git -C $source apply --check -- $hooks
    Assert-Exit 'check test-only hook patch'
    & git -C $source apply -- $hooks
    Assert-Exit 'apply test-only hook patch'
}
& git -C $source diff --check
Assert-Exit 'check patched source whitespace'
$changed = @(& git -C $source diff --name-only)
Assert-Exit 'read patched file list'
$actual = @($changed | Sort-Object)
$wanted = @($expected | Sort-Object)
if (($actual -join "`n") -ne ($wanted -join "`n")) {
    throw "Unexpected analyzer source paths: $($changed -join ', ')"
}
"CODESTRIKE_ANALYZER_PIN=base:$base;patch:$patchHash;hooks:$WithTestHooks;files:$($changed.Count)"
