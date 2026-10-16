param([Parameter(Mandatory = $true)][string]$VoltPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'trace-rust-lsp-fixture.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('CodeStrikeLspWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
public static class CodeStrikeLspWindow {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
    private static readonly ConcurrentQueue<string> Output = new ConcurrentQueue<string>();
    public static void BeginCapture(Process process) {
        process.OutputDataReceived += (sender, e) => { if (e.Data != null) Output.Enqueue(e.Data); };
        process.ErrorDataReceived += (sender, e) => { if (e.Data != null) Output.Enqueue(e.Data); };
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
    }
    public static bool HasOutput(string text) {
        foreach (string line in Output) if (line.Contains(text)) return true;
        return false;
    }
    public static bool HasOutputLine(string first, string second) {
        foreach (string line in Output) if (line.Contains(first) && line.Contains(second)) return true;
        return false;
    }
    public static bool HasDiagnosticAtVersion(string code, int minimumVersion) {
        foreach (string line in Output) {
            if (!line.Contains("textDocument/publishDiagnostics") || !line.Contains(code)) continue;
            Match match = Regex.Match(line, "\"version\":([0-9]+)");
            if (match.Success && int.Parse(match.Groups[1].Value) >= minimumVersion) return true;
        }
        return false;
    }
    public static string CapturedOutput() { return string.Join("\n", Output.ToArray()); }
}
'@
}

$exe = (Resolve-Path 'editor/lapce/target/debug/CodeStrike.exe').Path
$volt = (Resolve-Path -LiteralPath $VoltPath).Path
$root = Join-Path $env:RUNNER_TEMP ('codestrike-rust-lsp-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $root 'fixture'
$appData = Join-Path $root 'appdata'
$localData = Join-Path $root 'localdata'
$src = Join-Path $fixture 'src'
$workspaceSettings = Join-Path $fixture '.codestrike'
New-Item -ItemType Directory -Path $src, $workspaceSettings, $appData, $localData -Force | Out-Null

[System.IO.File]::WriteAllText((Join-Path $fixture 'Cargo.toml'), @'
[package]
name = "codestrike_lsp_fixture"
version = "0.1.0"
edition = "2021"
'@)
$source = Join-Path $src 'main.rs'
$initialSource = "use std::io::Read;`nfn main() { let value: i32 = `"wrong`"; println!(`"{value}`"); }"
$expectedSource = $initialSource + "`n//diagnostic_refresh"
$expectedBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($expectedSource)
$incompleteBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($expectedSource.Replace('::Read;', '::Re;'))
[System.IO.File]::WriteAllText($source, $initialSource)
[System.IO.File]::WriteAllText((Join-Path $workspaceSettings 'settings.toml'), @'
[lapce-rust]
serverPath = "rust-analyzer"
checkOnSave = false
'@)

$start = [System.Diagnostics.ProcessStartInfo]::new($exe)
$start.ArgumentList.Add('--wait')
$start.ArgumentList.Add('--new')
$start.ArgumentList.Add('--plugin-path')
$start.ArgumentList.Add($volt)
$start.ArgumentList.Add($fixture)
$start.ArgumentList.Add($source)
$start.UseShellExecute = $false
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.Environment['APPDATA'] = $appData
$start.Environment['LOCALAPPDATA'] = $localData
$start.Environment['CARGO_NET_OFFLINE'] = 'true'
$start.Environment['LAPCE_LOG'] = 'lapce_proxy::plugin=debug,lapce_app=info'
$process = [System.Diagnostics.Process]::Start($start)
if ($null -eq $process) { throw 'Windows did not start CodeStrike.' }
[CodeStrikeLspWindow]::BeginCapture($process)

try {
    $foundWindow = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        Start-Sleep -Seconds 1
        $process.Refresh()
        if ($process.HasExited) { throw "CodeStrike exited during LSP startup: $($process.ExitCode)." }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            $foundWindow = $true
            break
        }
    }
    if (-not $foundWindow) { throw 'CodeStrike did not expose a window within 120 seconds.' }
    "CODESTRIKE_LSP_WINDOW=opened;pid:$($process.Id)"

    # Record the initial-open behavior separately; an edit must not hide a gap.
    $initialDiagnosticReady = $false
    for ($attempt = 0; $attempt -lt 45; $attempt++) {
        if ([CodeStrikeLspWindow]::HasOutputLine('textDocument/publishDiagnostics', 'E0308')) {
            $initialDiagnosticReady = $true
            break
        }
        Start-Sleep -Seconds 1
        $process.Refresh()
        if ($process.HasExited) { throw "CodeStrike exited before rust-analyzer diagnostics: $($process.ExitCode)." }
    }
    "CODESTRIKE_LSP_INITIAL_OPEN_DIAGNOSTIC=$initialDiagnosticReady;wait_seconds=$attempt"

    [CodeStrikeLspWindow]::ShowWindow($process.MainWindowHandle, 9) | Out-Null
    if (-not [CodeStrikeLspWindow]::SetForegroundWindow($process.MainWindowHandle)) {
        throw 'CodeStrike could not receive focus for completion.'
    }
    $rect = [CodeStrikeLspWindow+Rect]::new()
    if (-not [CodeStrikeLspWindow]::GetWindowRect($process.MainWindowHandle, [ref]$rect)) {
        throw 'CodeStrike window bounds were unavailable.'
    }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -lt 300 -or $height -lt 250) { throw 'CodeStrike window bounds were implausible.' }
    [CodeStrikeLspWindow]::SetCursorPos($rect.Left + [int]($width * 0.6), $rect.Top + [int]($height * 0.2)) | Out-Null
    [CodeStrikeLspWindow]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [CodeStrikeLspWindow]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    [System.Windows.Forms.SendKeys]::SendWait('^{END}')
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}//diagnostic_refresh')
    [System.Windows.Forms.SendKeys]::SendWait('^s')
    $refreshSaved = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Milliseconds 500
        if ([Convert]::ToHexString([System.IO.File]::ReadAllBytes($source)) -eq [Convert]::ToHexString($expectedBytes)) {
            $refreshSaved = $true
            break
        }
    }
    if (-not $refreshSaved) { throw 'The GUI did not persist the diagnostic-refresh edit.' }
    'CODESTRIKE_LSP_DIAGNOSTIC_REFRESH=saved-exact-utf8-bytes'
    $diagnosticReady = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        if ([CodeStrikeLspWindow]::HasDiagnosticAtVersion('E0308', 2)) {
            $diagnosticReady = $true
            break
        }
        Start-Sleep -Seconds 1
        $process.Refresh()
        if ($process.HasExited) { throw 'CodeStrike exited before diagnostics after the GUI edit.' }
    }
    if (-not $diagnosticReady) {
        Write-CodeStrikeRustDocumentTrace -Output ([CodeStrikeLspWindow]::CapturedOutput()) -FixtureSource $source -TracePath (Join-Path $root 'standard-lsp-document-trace.jsonl') -Prefix 'CODESTRIKE_LSP_DOCUMENT'
        Write-CodeStrikeRustFixtureTrace -Output ([CodeStrikeLspWindow]::CapturedOutput()) -Prefix 'CODESTRIKE_LSP_AFTER_EDIT_PROTOCOL'
        throw 'No E0308 diagnostic appeared after the persisted GUI edit within 120 seconds.'
    }
    "CODESTRIKE_LSP_AFTER_EDIT_DIAGNOSTIC=e0308-reported;wait_seconds=$attempt"
    [System.Windows.Forms.SendKeys]::SendWait('^{HOME}')
    [System.Windows.Forms.SendKeys]::SendWait('{END}')
    # Persist Re first so a failed completion/save cannot pass on original bytes.
    [System.Windows.Forms.SendKeys]::SendWait('{LEFT}')
    [System.Windows.Forms.SendKeys]::SendWait('{BACKSPACE 2}')
    [System.Windows.Forms.SendKeys]::SendWait('^s')
    $incompleteSaved = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Milliseconds 500
        $actual = [System.IO.File]::ReadAllBytes($source)
        if ([Convert]::ToHexString($actual) -eq [Convert]::ToHexString($incompleteBytes)) {
            $incompleteSaved = $true
            break
        }
    }
    if (-not $incompleteSaved) { throw 'The GUI did not persist the incomplete Re fixture before completion.' }
    'CODESTRIKE_LSP_INTERMEDIATE_EDIT=re-saved-exact-utf8-bytes'
    [System.Windows.Forms.SendKeys]::SendWait('^i')
    $completionReady = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if ([CodeStrikeLspWindow]::HasOutput('"label":"Read"')) {
            $completionReady = $true
            break
        }
        Start-Sleep -Seconds 1
        $process.Refresh()
        if ($process.HasExited) { throw 'CodeStrike exited before Rust completion arrived.' }
    }
    if (-not $completionReady) { throw 'No Read completion arrived within 30 seconds.' }
    Start-Sleep -Seconds 2
    'CODESTRIKE_LSP_COMPLETION_KEYS=sent'

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if ($rect.Left -lt $screen.Left -or $rect.Top -lt $screen.Top -or
        $rect.Right -gt $screen.Right -or $rect.Bottom -gt $screen.Bottom) {
        throw 'CodeStrike window extends beyond the capture screen.'
    }
    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen([System.Drawing.Point]::new($rect.Left, $rect.Top), [System.Drawing.Point]::Empty, $bitmap.Size)
        $small = [System.Drawing.Bitmap]::new($bitmap)
        try {
            $stream = [System.IO.MemoryStream]::new()
            try {
                $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                    Where-Object MimeType -eq 'image/jpeg' | Select-Object -First 1
                $parameters = [System.Drawing.Imaging.EncoderParameters]::new(1)
                $parameters.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new(
                    [System.Drawing.Imaging.Encoder]::Quality, [int64]45)
                $small.Save($stream, $codec, $parameters)
                if ($stream.Length -gt 350KB) { throw 'LSP screenshot exceeded its log bound.' }
                "CODESTRIKE_LSP_SCREENSHOT_BASE64=$([Convert]::ToBase64String($stream.ToArray()))"
            } finally { $stream.Dispose() }
        } finally { $small.Dispose() }
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }

    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.SendKeys]::SendWait('^s')
    $savedExpectedBytes = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Milliseconds 500
        $savedBytes = [System.IO.File]::ReadAllBytes($source)
        if ($savedBytes.Length -eq $expectedBytes.Length) {
            $savedExpectedBytes = $true
            for ($index = 0; $index -lt $expectedBytes.Length; $index++) {
                if ($savedBytes[$index] -ne $expectedBytes[$index]) {
                    $savedExpectedBytes = $false
                    break
                }
            }
            if ($savedExpectedBytes) { break }
        }
    }
    if (-not $savedExpectedBytes) {
        $actualHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        throw "Completion selection did not save the expected UTF-8 bytes; actual SHA-256: $actualHash"
    }
    'CODESTRIKE_LSP_COMPLETION_INSERTION=read-saved-exact-utf8-bytes'

    if (-not $process.CloseMainWindow() -or -not $process.WaitForExit(15000)) {
        throw 'CodeStrike did not close cleanly after the diagnostic capture.'
    }
    $process.WaitForExit()
    $output = [CodeStrikeLspWindow]::CapturedOutput()
    if (-not $output.Contains('"method":"initialize"')) {
        throw 'No rust-analyzer initialize request was found in the CodeStrike console stream.'
    }
    $diagnosticLines = @($output -split "`n" |
        Where-Object { $_.Contains('textDocument/publishDiagnostics') -and $_.Contains('E0308') })
    if ($diagnosticLines.Count -eq 0) {
        $debugLines = @($output -split "`n" |
            Where-Object { $_ -match 'rust-analyzer|lapce-rust|publishDiagnostics|ERROR' } |
            Select-Object -Last 20)
        $debugLines | ForEach-Object { Write-Host "CODESTRIKE_LSP_DIAGNOSTIC_LOG=$($_.Substring(0, [Math]::Min($_.Length, 450)))" }
        throw 'No rust-analyzer E0308 diagnostic was observed for the real Rust fixture.'
    }
    'CODESTRIKE_LSP_DIAGNOSTICS=rust-analyzer-e0308-passed'
    if (-not $output.Contains('"method":"textDocument/completion"') -or
        -not $output.Contains('"label":"Read"')) {
        $completionLines = @($output -split "`n" |
            Where-Object { $_ -match 'textDocument/completion|"label":"Read"' } |
            Select-Object -Last 8)
        $completionLines | ForEach-Object { Write-Host "CODESTRIKE_LSP_COMPLETION_LOG=$($_.Substring(0, [Math]::Min($_.Length, 450)))" }
        throw 'CodeStrike did not receive the expected Rust Read completion.'
    }
    'CODESTRIKE_LSP_COMPLETION=rust-read-passed'
    if (-not $initialDiagnosticReady) {
        Write-CodeStrikeRustDocumentTrace -Output $output -FixtureSource $source -TracePath (Join-Path $root 'standard-lsp-document-trace.jsonl') -Prefix 'CODESTRIKE_LSP_DOCUMENT'
        Write-CodeStrikeRustFixtureTrace -Output $output -Prefix 'CODESTRIKE_LSP_INITIAL_OPEN_PROTOCOL'
        throw 'Initial-open E0308 was absent even though later edited-document checks passed.'
    }
} finally {
    $process.Refresh()
    if (-not $process.HasExited) {
        if (-not $process.CloseMainWindow() -or -not $process.WaitForExit(15000)) {
            $process.Kill($true)
            $process.WaitForExit(10000) | Out-Null
        }
    }
    $process.Dispose()
}
