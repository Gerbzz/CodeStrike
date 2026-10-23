$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rust-toolchain-guard.ps1')

$expected = '8bab26f4f68e0e26f0bb7960be334d5b520ea452'
$wrong = '0000000000000000000000000000000000000000'
$correct = @('rustc 1.97.1', "commit-hash: $expected", 'host: x86_64-pc-windows-msvc')

Assert-RustcCommitHash -CompilerOutput $correct -ExitCode 0 -ExpectedCommit $expected

function Assert-Rejected {
    param([scriptblock]$Case, [string]$Label)
    $rejected = $false
    try { & $Case } catch { $rejected = $true }
    if (-not $rejected) { throw "Guard accepted $Label." }
}

Assert-Rejected -Label 'wrong hash' -Case {
    Assert-RustcCommitHash -CompilerOutput @('rustc 1.97.1', "commit-hash: $wrong") -ExitCode 0 -ExpectedCommit $expected
}
Assert-Rejected -Label 'missing hash' -Case {
    Assert-RustcCommitHash -CompilerOutput @('rustc 1.97.1', 'host: x86_64-pc-windows-msvc') -ExitCode 0 -ExpectedCommit $expected
}
Assert-Rejected -Label 'duplicate hash' -Case {
    Assert-RustcCommitHash -CompilerOutput ($correct + "commit-hash: $expected") -ExitCode 0 -ExpectedCommit $expected
}
Assert-Rejected -Label 'failed rustc process' -Case {
    Assert-RustcCommitHash -CompilerOutput $correct -ExitCode 1 -ExpectedCommit $expected
}

'RUSTC_COMMIT_GUARD_TESTS=passed'
