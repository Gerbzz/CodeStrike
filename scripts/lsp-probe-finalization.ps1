# Preserve a primary acceptance failure while independently attempting evidence.
function Invoke-LspCleanupStep([string]$name, [scriptblock]$action, [System.Collections.Generic.List[string]]$failures) {
    try { & $action } catch {
        $message = "${name}: $_"
        $failures.Add($message)
        Write-Warning $message -WarningAction Continue
    }
}

function Complete-LspCleanup($originalFailure, [System.Collections.Generic.List[string]]$failures) {
    # Never replace a failure already being rethrown by the probe's catch block.
    # Evidence/cleanup loss on an otherwise successful path must fail acceptance.
    if ($null -eq $originalFailure -and $failures.Count -gt 0) {
        throw "Native LSP evidence finalization failed: $($failures -join '; ')"
    }
}
