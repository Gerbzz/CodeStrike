function Write-CodeStrikeRustFixtureTrace {
    param([string]$Output, [string]$Prefix)

    # Only the disposable CI fixture is opened by these probes. Emit compact
    # protocol metadata on failure; do not dump document text or full logs.
    $entries = [System.Collections.Generic.Queue[string]]::new()
    foreach ($line in ($Output -split "`n")) {
        if ($line -notmatch '(write|read) (?:to|from) lsp: (\{.*\})') { continue }
        $direction = if ($Matches[1] -eq 'write') { 'client' } else { 'server' }
        $json = $Matches[2] -replace '\x1b\[[0-9;]*m', ''
        try { $message = $json | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $method = [string]$message.method
        if (-not $method -and $null -ne $message.id -and $json.Contains('"label"')) {
            $entries.Enqueue("$direction response id=$($message.id);readLabel=$($json.Contains('"label":"Read"'))")
            if ($entries.Count -gt 60) { $entries.Dequeue() | Out-Null }
            continue
        }
        $detail = switch ($method) {
            'initialize' {
                $folders = @($message.params.workspaceFolders | ForEach-Object uri) -join ','
                "root=$($message.params.rootUri);folders=$folders;checkOnSave=$($message.params.initializationOptions.checkOnSave)"
            }
            'textDocument/didOpen' {
                $doc = $message.params.textDocument
                "uri=$($doc.uri);version=$($doc.version);language=$($doc.languageId);chars=$($doc.text.Length)"
            }
            'textDocument/didChange' {
                $doc = $message.params.textDocument
                "uri=$($doc.uri);version=$($doc.version);changes=$(@($message.params.contentChanges).Count)"
            }
            'textDocument/didSave' { "uri=$($message.params.textDocument.uri)" }
            'textDocument/completion' {
                "uri=$($message.params.textDocument.uri);line=$($message.params.position.line);character=$($message.params.position.character);id=$($message.id)"
            }
            'textDocument/publishDiagnostics' {
                $codes = @($message.params.diagnostics | ForEach-Object code) -join ','
                "uri=$($message.params.uri);version=$($message.params.version);count=$(@($message.params.diagnostics).Count);codes=$codes"
            }
            'rust-analyzer/serverStatus' { "health=$($message.params.health);quiescent=$($message.params.quiescent)" }
            'window/logMessage' {
                $messageText = [string]$message.params.message
                "type=$($message.params.type);message=$($messageText.Substring(0, [Math]::Min($messageText.Length, 160)))"
            }
            default { $null }
        }
        if ($null -eq $detail) { continue }
        $entries.Enqueue("$direction $method $detail")
        if ($entries.Count -gt 60) { $entries.Dequeue() | Out-Null }
    }
    foreach ($entry in $entries) { Write-Host "$Prefix=$entry" }
    if ($entries.Count -eq 0) { Write-Host "$Prefix=no-matching-protocol-lines" }
}
