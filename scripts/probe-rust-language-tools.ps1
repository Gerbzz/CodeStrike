param(
    [Parameter(Mandatory = $true)][string]$VoltPath,
    [Parameter(Mandatory = $true)][string]$AnalyzerPath,
    [string]$EvidenceDirectory = (Join-Path $PSScriptRoot '../artifacts/lsp-native')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lsp-probe-finalization.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('CodeStrikeLspWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Threading;
using System.Runtime.InteropServices;
using System.Text;
public static class CodeStrikeLspWindow {
    private static readonly ConcurrentQueue<string> Output = new ConcurrentQueue<string>();
    private static int characters, ended;
    private static int overflow;
    private static void Capture(string line) {
        if (line == null) { Interlocked.Increment(ref ended); return; }
        if (Interlocked.Add(ref characters, line.Length) > 16 * 1024 * 1024) {
            Interlocked.Exchange(ref overflow, 1);
            return;
        }
        Output.Enqueue(line);
    }
    public static void BeginCapture(Process process) {
        Output.Clear(); characters = 0; ended = 0; overflow = 0;
        process.OutputDataReceived += (sender, e) => Capture(e.Data);
        process.ErrorDataReceived += (sender, e) => Capture(e.Data);
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
    }
    public static bool Overflowed() { return Volatile.Read(ref overflow) != 0; }
    public static bool CaptureEnded() { return Volatile.Read(ref ended) == 2; }
    public static int OutputCount() { return Output.Count; }
    public static bool HasOutputLine(string first, string second, int startIndex) {
        int index = 0;
        foreach (string line in Output) {
            if (index++ < startIndex || !line.Contains(first)) continue;
            string plain = System.Text.RegularExpressions.Regex.Replace(line, @"\x1B\[[0-?]*[ -/]*[@-~]", "");
            if (plain.Contains(second)) return true;
        }
        return false;
    }
    public static string CapturedOutput() { return string.Join("\n", Output.ToArray()); }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern uint GetLongPathName(string path, StringBuilder result, uint capacity);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
}
'@
}

$exe = (Resolve-Path 'editor/lapce/target/debug/CodeStrike.exe').Path
$volt = (Resolve-Path -LiteralPath $VoltPath).Path
$analyzer = (Resolve-Path -LiteralPath $AnalyzerPath).Path
$analyzerVersion = @(& $analyzer --version)
if ($LASTEXITCODE -ne 0) { throw 'Selected analyzer version check failed.' }
"CODESTRIKE_LSP_ANALYZER_VERSION=$($analyzerVersion -join ' ')"
"CODESTRIKE_LSP_ANALYZER_PATH=$analyzer"
"CODESTRIKE_LSP_ANALYZER_SHA256=$((Get-FileHash -LiteralPath $analyzer -Algorithm SHA256).Hash)"
# TOML basic strings use JSON-compatible escaping for this absolute Windows path.
$analyzerToml = ConvertTo-Json -InputObject $analyzer -Compress
$root = Join-Path $env:RUNNER_TEMP ('codestrike-rust-lsp-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $root 'fixture'
$appData = Join-Path $root 'appdata'
$localData = Join-Path $root 'localdata'
$src = Join-Path $fixture 'src'
$workspaceSettings = Join-Path $fixture '.codestrike'
New-Item -ItemType Directory -Path $src, $workspaceSettings, $appData, $localData -Force | Out-Null
# Expand Windows 8.3 aliases before constructing workspace/file URIs.
$longPath = [System.Text.StringBuilder]::new(32768)
$length = [CodeStrikeLspWindow]::GetLongPathName($root, $longPath, 32768)
if ($length -eq 0 -or $length -ge 32768) { throw 'Cannot resolve canonical fixture path.' }
$root = $longPath.ToString()
$fixture = Join-Path $root 'fixture'
$appData = Join-Path $root 'appdata'
$localData = Join-Path $root 'localdata'
$src = Join-Path $fixture 'src'
$workspaceSettings = Join-Path $fixture '.codestrike'


[System.IO.File]::WriteAllText((Join-Path $fixture 'Cargo.toml'), @'
[package]
name = "codestrike_lsp_fixture"
version = "0.1.0"
edition = "2021"
'@)
$source = Join-Path $src 'main.rs'
$expectedSource = "use std::io::Read;`nfn main() { let value: i32 = `"wrong`"; println!(`"{value}`"); }"
$expectedBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($expectedSource)
[System.IO.File]::WriteAllText($source, $expectedSource.Replace('::Read;', '::Re;'))
[System.IO.File]::WriteAllText((Join-Path $workspaceSettings 'settings.toml'), @"
[lapce-rust]
serverPath = $analyzerToml
checkOnSave = false
"@)

$evidence = $EvidenceDirectory
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
"CODESTRIKE_LSP_FIXTURE_UTC=$([DateTime]::UtcNow.ToString('o'));workspace=$fixture;source=$source"
"CODESTRIKE_LSP_SOURCE_URI=$(([Uri]$source).AbsoluteUri)"
"CODESTRIKE_LSP_CONFIG=serverPath:$analyzer;checkOnSave:false;CARGO_NET_OFFLINE:true"

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
$start.Environment['RA_LOG'] = 'rust_analyzer=info'
$start.Environment['LAPCE_LOG'] = 'lapce_proxy::plugin=trace,lapce_app=info,lapce_app::completion_observation=debug'
$process = [System.Diagnostics.Process]::Start($start)
if ($null -eq $process) { throw 'Windows did not start CodeStrike.' }
[CodeStrikeLspWindow]::BeginCapture($process)
function Wait-LspOutput([string]$first, [string]$second, [int]$seconds, [int]$startIndex = 0) {
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
    do {
        if ([CodeStrikeLspWindow]::Overflowed()) { throw 'Synthetic LSP trace exceeded 16 MiB.' }
        $process.Refresh()
        if ($process.HasExited) { throw 'CodeStrike exited before LSP readiness.' }
        if ([CodeStrikeLspWindow]::HasOutputLine($first, $second, $startIndex)) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for native LSP readiness: $first / $second"
}

$probeFailure = $null
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

    # Cold compiler/sysroot indexing can outlive a fixed startup sleep. Observe
    # real server readiness before requesting completion; never retry until pass.
    Wait-LspOutput 'textDocument/publishDiagnostics' 'E0308' 120
    $process.Refresh()
    if ($process.HasExited) { throw "CodeStrike exited before the diagnostic capture: $($process.ExitCode)." }

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
    [System.Windows.Forms.SendKeys]::SendWait('^{HOME}')
    [System.Windows.Forms.SendKeys]::SendWait('{END}')
    [System.Windows.Forms.SendKeys]::SendWait('{LEFT 1}')
    $completionOutputStart = [CodeStrikeLspWindow]::OutputCount()
    [System.Windows.Forms.SendKeys]::SendWait('^i')
    'CODESTRIKE_LSP_COMPLETION_KEYS=sent'
    # Enter before the selected row is laid out inserts a newline. Require a
    # fresh native UI layout observation, not just a server completion response.
    Wait-LspOutput 'CodeStrike completion row laid out' 'selected_label="Read"' 60 $completionOutputStart
    'CODESTRIKE_LSP_COMPLETION_UI=selected-read-row-laid-out'

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
                [IO.File]::WriteAllBytes((Join-Path $evidence "completion.jpg"), $stream.ToArray())
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
    # Completion and diagnostics are asynchronous: allow the native publication
    # to reach the proxy before closing its console stream. The E0308 assertion
    # below remains mandatory, and this wait is bounded.
    Start-Sleep -Seconds 30

    if (-not $process.CloseMainWindow() -or -not $process.WaitForExit(15000)) {
        throw 'CodeStrike did not close cleanly after the diagnostic capture.'
    }
    $captureDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not [CodeStrikeLspWindow]::CaptureEnded() -and [DateTime]::UtcNow -lt $captureDeadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not [CodeStrikeLspWindow]::CaptureEnded()) { throw 'CodeStrike console capture did not complete after exit.' }
    if ([CodeStrikeLspWindow]::Overflowed()) { throw 'Synthetic LSP trace exceeded 16 MiB.' }
    $output = [CodeStrikeLspWindow]::CapturedOutput()
    [IO.File]::WriteAllText((Join-Path $evidence 'synthetic-fixture-lsp.log'), $output)
    "CODESTRIKE_LSP_OBSERVATION_END_UTC=$([DateTime]::UtcNow.ToString('o'))"
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
} catch {
    $probeFailure = $_
    throw
} finally {
    $cleanupFailures = [System.Collections.Generic.List[string]]::new()
    # Retain genuine pixels on a readiness timeout as well as the raw trace and
    # saved bytes. Evidence errors must not suppress the original gate failure.
    Invoke-LspCleanupStep 'failure screenshot' {
        $process.Refresh()
        if (-not (Test-Path (Join-Path $evidence 'completion.jpg')) -and -not $process.HasExited) {
            $failureRect = [CodeStrikeLspWindow+Rect]::new()
            if ([CodeStrikeLspWindow]::GetWindowRect($process.MainWindowHandle, [ref]$failureRect)) {
                $failureWidth = $failureRect.Right - $failureRect.Left
                $failureHeight = $failureRect.Bottom - $failureRect.Top
                if ($failureWidth -ge 300 -and $failureHeight -ge 250) {
                    $failureBitmap = [System.Drawing.Bitmap]::new($failureWidth, $failureHeight)
                    $failureGraphics = [System.Drawing.Graphics]::FromImage($failureBitmap)
                    try {
                        $failureGraphics.CopyFromScreen([System.Drawing.Point]::new($failureRect.Left, $failureRect.Top), [System.Drawing.Point]::Empty, $failureBitmap.Size)
                        $failureBitmap.Save((Join-Path $evidence 'failure.png'))
                    } finally {
                        $failureGraphics.Dispose()
                        $failureBitmap.Dispose()
                    }
                }
            }
        }
    } $cleanupFailures
    Invoke-LspCleanupStep 'close native process' {
        $process.Refresh()
        if (-not $process.HasExited) {
            $process.CloseMainWindow() | Out-Null
            $process.WaitForExit(15000) | Out-Null
        }
    } $cleanupFailures
    Invoke-LspCleanupStep 'terminate remaining native process' {
        $process.Refresh()
        if (-not $process.HasExited) {
            $process.Kill($true)
            if (-not $process.WaitForExit(10000)) { throw 'Native process did not terminate.' }
        }
    } $cleanupFailures
    Invoke-LspCleanupStep 'drain console capture' {
        $captureDeadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not [CodeStrikeLspWindow]::CaptureEnded() -and [DateTime]::UtcNow -lt $captureDeadline) {
            Start-Sleep -Milliseconds 100
        }
        if (-not [CodeStrikeLspWindow]::CaptureEnded()) { throw 'Console capture did not end.' }
        if ([CodeStrikeLspWindow]::Overflowed()) { throw 'Synthetic LSP trace exceeded its bound.' }
    } $cleanupFailures
    Invoke-LspCleanupStep 'retain raw trace' {
        [IO.File]::WriteAllText((Join-Path $evidence 'synthetic-fixture-lsp.log'), [CodeStrikeLspWindow]::CapturedOutput())
    } $cleanupFailures
    Invoke-LspCleanupStep 'retain saved source' {
        [IO.File]::WriteAllBytes((Join-Path $evidence 'saved-source.rs'), [IO.File]::ReadAllBytes($source))
    } $cleanupFailures
    Invoke-LspCleanupStep 'dispose process' { $process.Dispose() } $cleanupFailures
    Complete-LspCleanup $probeFailure $cleanupFailures
}
