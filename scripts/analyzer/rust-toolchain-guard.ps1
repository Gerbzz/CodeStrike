function Assert-RustcCommitHash {
    param(
        [Parameter(Mandatory = $true)][string[]]$CompilerOutput,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedCommit
    )

    if ($ExitCode -ne 0) { throw "rustc -vV exited with code $ExitCode." }
    $commitLines = @($CompilerOutput | Where-Object { $_ -cmatch '^commit-hash:' })
    $expectedLine = "commit-hash: $ExpectedCommit"
    if ($commitLines.Count -ne 1 -or $commitLines[0] -cne $expectedLine) {
        throw "rustc -vV must contain exactly one '$expectedLine' line."
    }
}
