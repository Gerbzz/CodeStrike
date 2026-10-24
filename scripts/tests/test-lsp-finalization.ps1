$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../lsp-probe-finalization.ps1')
$failures = [System.Collections.Generic.List[string]]::new()
$script:evidenceRetained = $false
$observed = $null
$primary = $null
try {
    try { throw 'original exact UTF-8 assertion' } catch {
        $primary = $_
        throw
    } finally {
        Invoke-LspCleanupStep 'unavailable process' { throw 'Refresh failed' } $failures
        Invoke-LspCleanupStep 'unavailable trace path' { throw 'WriteAllText failed' } $failures
        Invoke-LspCleanupStep 'remaining source evidence' { $script:evidenceRetained = $true } $failures
        Complete-LspCleanup $primary $failures
    }
} catch { $observed = $_ }
if ($observed.Exception.Message -ne 'original exact UTF-8 assertion') { throw 'Cleanup masked the original failure.' }
if (-not $script:evidenceRetained -or $failures.Count -ne 2) { throw 'One failed evidence step skipped subsequent evidence.' }
$unexpectedSuccess = $true
try { Complete-LspCleanup $null $failures } catch { $unexpectedSuccess = $false }
if ($unexpectedSuccess) { throw 'Lost evidence incorrectly passed an otherwise successful probe.' }
Complete-LspCleanup $null ([System.Collections.Generic.List[string]]::new())
'CODESTRIKE_LSP_FINALIZATION_TESTS=4-passed'
