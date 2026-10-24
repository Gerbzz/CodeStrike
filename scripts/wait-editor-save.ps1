# Observe the one native save asynchronously; never send keys or mutate the file.
function Wait-EditorSavedSource([string]$Path, [string]$Marker, [int]$TimeoutMilliseconds = 10000) {
    if ($TimeoutMilliseconds -le 0) { throw 'Save observation timeout must be positive.' }
    $elapsed = [Diagnostics.Stopwatch]::StartNew()
    $observations = 0
    do {
        $source = [IO.File]::ReadAllText($Path)
        $observations++
        if ($source.Contains($Marker) -or $elapsed.ElapsedMilliseconds -ge $TimeoutMilliseconds) { break }
        Start-Sleep -Milliseconds 100
    } while ($true)
    [pscustomobject]@{
        Source = $source
        Observations = $observations
        ElapsedMilliseconds = $elapsed.ElapsedMilliseconds
    }
}
