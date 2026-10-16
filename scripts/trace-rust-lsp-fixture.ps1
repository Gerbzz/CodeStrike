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

function Get-CodeStrikeFixtureOffset {
    param([string]$Text, $Position)

    $offset = 0
    for ($line = 0; $line -lt [int]$Position.line; $line++) {
        $newline = $Text.IndexOf("`n", $offset)
        if ($newline -lt 0) { throw 'LSP edit referred to a missing fixture line.' }
        $offset = $newline + 1
    }
    $offset += [int]$Position.character
    if ($offset -gt $Text.Length) { throw 'LSP edit referred past the fixture text.' }
    return $offset
}

function Write-CodeStrikeRustDocumentTrace {
    param([string]$Output, [string]$FixtureSource, [string]$TracePath, [string]$Prefix, [switch]$IncludeCompletions)

    # This helper is used only with the generated Rust fixture. Refuse to
    # record text for any other URI, including user files opened by accident.
    $sourcePath = [System.IO.Path]::GetFullPath($FixtureSource)
    $records = [System.Collections.Generic.List[string]]::new()
    $document = $null
    $version = $null
    $skipped = 0
    $completionIds = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($line in ($Output -split "`n")) {
        if ($line -notmatch '(write|read) (?:to|from) lsp: (\{.*\})') { continue }
        $json = $Matches[2] -replace '\x1b\[[0-9;]*m', ''
        try { $message = $json | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $method = [string]$message.method
        if ($IncludeCompletions -and -not $method -and $null -ne $message.id -and
            $completionIds.Contains([int]$message.id)) {
            $resultKind = if ($null -ne $message.error) { 'error' } elseif ($null -eq $message.result) { 'null' } else { 'result' }
            $items = if ($null -ne $message.result.items) { @($message.result.items) } elseif ($message.result -is [array]) { @($message.result) } else { @() }
            $record = [ordered]@{ method = 'textDocument/completion-response'; id = $message.id; kind = $resultKind; items = $items.Count; readLabel = $json.Contains('"label":"Read"'); error = $message.error }
            if ($records.Count -lt 100) { $records.Add(($record | ConvertTo-Json -Compress -Depth 8)) } else { $skipped++ }
            continue
        }
        if ($method -eq 'initialize') {
            $record = [ordered]@{ method = $method; rootUri = $message.params.rootUri; options = $message.params.initializationOptions }
            if ($records.Count -lt 100) { $records.Add(($record | ConvertTo-Json -Compress -Depth 8)) } else { $skipped++ }
            continue
        }
        if ($method -eq 'rust-analyzer/serverStatus') {
            $record = [ordered]@{ method = $method; health = $message.params.health; quiescent = $message.params.quiescent }
            if ($records.Count -lt 100) { $records.Add(($record | ConvertTo-Json -Compress -Depth 8)) } else { $skipped++ }
            continue
        }
        if ($method -notin @('textDocument/didOpen', 'textDocument/didChange', 'textDocument/publishDiagnostics', 'textDocument/completion')) { continue }
        if ($method -eq 'textDocument/completion' -and -not $IncludeCompletions) { continue }
        $uri = if ($method -eq 'textDocument/publishDiagnostics') { [string]$message.params.uri } else { [string]$message.params.textDocument.uri }
        try { $messagePath = [System.Uri]::new($uri).LocalPath } catch { continue }
        if (-not [string]::Equals($sourcePath, [System.IO.Path]::GetFullPath($messagePath), [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        if ($method -eq 'textDocument/didOpen') {
            $document = [string]$message.params.textDocument.text
            $version = [int]$message.params.textDocument.version
            $record = [ordered]@{ method = $method; uri = $uri; version = $version; text = $document }
        } elseif ($method -eq 'textDocument/didChange') {
            $version = [int]$message.params.textDocument.version
            foreach ($change in @($message.params.contentChanges)) {
                $inserted = [string]$change.text
                if ($null -eq $change.range) {
                    $document = $inserted
                } else {
                    $start = Get-CodeStrikeFixtureOffset -Text $document -Position $change.range.start
                    $end = Get-CodeStrikeFixtureOffset -Text $document -Position $change.range.end
                    if ($end -lt $start) { throw 'LSP edit reversed a fixture range.' }
                    $document = $document.Substring(0, $start) + $inserted + $document.Substring($end)
                }
                $record = [ordered]@{ method = $method; uri = $uri; version = $version; range = $change.range; text = $inserted }
                $record['documentSha256'] = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($document)))
                if ($records.Count -lt 100) { $records.Add(($record | ConvertTo-Json -Compress -Depth 8)) } else { $skipped++ }
            }
            continue
        } elseif ($method -eq 'textDocument/completion') {
            $completionIds.Add([int]$message.id) | Out-Null
            $record = [ordered]@{ method = $method; uri = $uri; id = $message.id; position = $message.params.position }
        } else {
            $codes = @($message.params.diagnostics | ForEach-Object code)
            $record = [ordered]@{ method = $method; uri = $uri; version = $message.params.version; codes = $codes }
        }
        if ($records.Count -lt 100) { $records.Add(($record | ConvertTo-Json -Compress -Depth 8)) } else { $skipped++ }
    }

    $diskBytes = [System.IO.File]::ReadAllBytes($sourcePath)
    $documentBytes = if ($null -eq $document) { [byte[]]@() } else { [System.Text.Encoding]::UTF8.GetBytes($document) }
    $match = [Convert]::ToHexString($diskBytes) -eq [Convert]::ToHexString($documentBytes)
    $summary = [ordered]@{
        lastVersion = $version
        matchesDisk = $match
        diskSha256 = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($diskBytes))
        documentSha256 = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($documentBytes))
        skippedEvents = $skipped
    } | ConvertTo-Json -Compress
    $records.Add($summary)
    [System.IO.File]::WriteAllLines($TracePath, $records.ToArray(), [System.Text.UTF8Encoding]::new($false))
    "${Prefix}_PATH=$TracePath"
    foreach ($record in $records) { Write-Host "$Prefix=$record" }
}
