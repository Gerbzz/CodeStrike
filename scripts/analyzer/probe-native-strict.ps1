param(
    [Parameter(Mandatory = $true)][string]$VoltPath,
    [Parameter(Mandatory = $true)][string]$AnalyzerPath,
    [switch]$PreflightOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'trace-rust-lsp-fixture.ps1')
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $PSScriptRoot 'capture-code-window.ps1')
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
    public static string CapturedOutput() { return string.Join("\n", Output.ToArray()); }
}
'@
}
if (-not ('CodeStrikeFocusV9' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class CodeStrikeFocusV9 {
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint current, uint other, bool attach);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr SetActiveWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr SetFocus(IntPtr window);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr window);
    public static bool Focus(IntPtr window) {
        uint targetPid, foregroundPid;
        uint targetThread = GetWindowThreadProcessId(window, out targetPid);
        uint foregroundThread = GetWindowThreadProcessId(GetForegroundWindow(), out foregroundPid);
        uint currentThread = GetCurrentThreadId();
        bool targetAttached = targetThread != 0 && targetThread != currentThread
            && AttachThreadInput(currentThread, targetThread, true);
        bool foregroundAttached = foregroundThread != 0 && foregroundThread != currentThread
            && foregroundThread != targetThread && AttachThreadInput(currentThread, foregroundThread, true);
        try {
            BringWindowToTop(window);
            SetActiveWindow(window);
            SetFocus(window);
            SetForegroundWindow(window);
            Thread.Sleep(300);
            uint actualPid;
            GetWindowThreadProcessId(GetForegroundWindow(), out actualPid);
            return actualPid == targetPid;
        } finally {
            if (foregroundAttached) AttachThreadInput(currentThread, foregroundThread, false);
            if (targetAttached) AttachThreadInput(currentThread, targetThread, false);
        }
    }
}
'@
}
if (-not ('CodeStrikeWindowState' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class CodeStrikeWindowState {
    [DllImport("user32.dll", SetLastError=true)] public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetLastActivePopup(IntPtr window);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll", SetLastError=true)] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr window, StringBuilder text, int capacity);
    public static string Title(IntPtr window) { var text = new StringBuilder(256); GetWindowText(window, text, text.Capacity); return text.ToString(); }
}
'@
}
if (-not ('CodeStrikeFocusReport' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class CodeStrikeFocusReport {
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", SetLastError=true)] private static extern IntPtr OpenProcess(uint access, bool inherit, uint process);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool AttachThreadInput(uint current, uint other, bool attach);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool SetForegroundWindow(IntPtr window);
    public static string TryAndDescribe(IntPtr target) {
        uint targetPid, foregroundPid, actualPid;
        uint targetTid = GetWindowThreadProcessId(target, out targetPid);
        uint foregroundTid = GetWindowThreadProcessId(GetForegroundWindow(), out foregroundPid);
        uint currentTid = GetCurrentThreadId();
        IntPtr process = OpenProcess(0x1000, false, foregroundPid);
        int processError = process == IntPtr.Zero ? Marshal.GetLastWin32Error() : 0;
        if (process != IntPtr.Zero) CloseHandle(process);
        bool joinedForeground = foregroundTid != 0 && AttachThreadInput(currentTid, foregroundTid, true);
        int foregroundAttachError = joinedForeground ? 0 : Marshal.GetLastWin32Error();
        bool joinedTarget = targetTid != 0 && AttachThreadInput(currentTid, targetTid, true);
        int targetAttachError = joinedTarget ? 0 : Marshal.GetLastWin32Error();
        bool set = SetForegroundWindow(target);
        int setError = set ? 0 : Marshal.GetLastWin32Error();
        Thread.Sleep(250);
        GetWindowThreadProcessId(GetForegroundWindow(), out actualPid);
        if (joinedTarget) AttachThreadInput(currentTid, targetTid, false);
        if (joinedForeground) AttachThreadInput(currentTid, foregroundTid, false);
        return $"targetPid={targetPid};targetTid={targetTid};foregroundPid={foregroundPid};foregroundTid={foregroundTid};currentTid={currentTid};openForegroundProcessError={processError};joinedForeground={joinedForeground};foregroundAttachError={foregroundAttachError};joinedTarget={joinedTarget};targetAttachError={targetAttachError};setForeground={set};setError={setError};actualPid={actualPid}";
    }
}
'@
}
function Get-Fixture-GateState([string]$fixtureSource, [string]$tracePath) {
    Write-CodeStrikeRustDocumentTrace -Output ([CodeStrikeLspWindow]::CapturedOutput()) -FixtureSource $fixtureSource -TracePath $tracePath -Prefix 'CODESTRIKE_LSP_GATE_TRACE' *> $null
    $records = @(Get-Content -LiteralPath $tracePath | ForEach-Object { $_ | ConvertFrom-Json })
    if ($records.Count -eq 0) { throw 'Fixture protocol trace was empty.' }
    $summary = $records[-1]
    if ($summary.skippedEvents -ne 0) { throw 'Fixture protocol trace exceeded its event bound.' }
    return [pscustomobject]@{
        Summary = $summary
        Diagnostics = @($records | Where-Object { $_.method -eq 'textDocument/publishDiagnostics' })
    }
}
function Wait-Fixture-Diagnostic([string]$fixtureSource, [string]$tracePath,
    [int]$afterVersion, [bool]$expectE0308, [string]$stage) {
    $expectedVersion = $null
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        $state = Get-Fixture-GateState $fixtureSource $tracePath
        $version = $state.Summary.lastVersion
        if ($null -ne $version -and [int]$version -gt $afterVersion -and $state.Summary.matchesDisk) {
            if ($null -eq $expectedVersion) {
                $expectedVersion = [int]$version
                Write-Host "CODESTRIKE_LSP_GATE_VERSION=$stage;$expectedVersion"
            } elseif ([int]$version -ne $expectedVersion) {
                throw "Fixture document version advanced during $stage after the exact version was latched."
            }
            $matching = @($state.Diagnostics | Where-Object { $null -ne $_.version -and [int]$_.version -eq $expectedVersion })
            if ($matching.Count -gt 0) {
                $latest = $matching[-1]
                $hasE0308 = @($latest.codes) -contains 'E0308'
                $errors = [int]$latest.errors
                if (($expectE0308 -and $hasE0308) -or
                    (-not $expectE0308 -and -not $hasE0308 -and $errors -eq 0)) {
                    Write-Host "CODESTRIKE_LSP_GATE_DIAGNOSTIC=$stage;version:$expectedVersion;errors:$errors;e0308:$hasE0308"
                    return $expectedVersion
                }
            }
        }
        Start-Sleep -Seconds 1
    }
    Write-CodeStrikeRustDocumentTrace -Output ([CodeStrikeLspWindow]::CapturedOutput()) -FixtureSource $fixtureSource -TracePath $tracePath -Prefix 'CODESTRIKE_LSP_DOCUMENT'
    Write-CodeStrikeRustFixtureTrace -Output ([CodeStrikeLspWindow]::CapturedOutput()) -Prefix 'CODESTRIKE_LSP_GATE_PROTOCOL'
    throw "No exact-version diagnostic reached the expected state for $stage within 120 seconds."
}

$exe = (Resolve-Path 'editor/lapce/target/debug/CodeStrike.exe').Path
$volt = (Resolve-Path -LiteralPath $VoltPath).Path
$analyzer = (Resolve-Path -LiteralPath $AnalyzerPath).Path
$serverPath = $analyzer.Replace('\', '/')
"CODESTRIKE_APP_SHA256=$((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash)"
"CODESTRIKE_ANALYZER_SHA256=$((Get-FileHash -LiteralPath $analyzer -Algorithm SHA256).Hash)"
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
$validSource = $initialSource.Replace('"wrong"', '7')
$expectedSource = $initialSource
$validBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($validSource)
$expectedBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($expectedSource)
$incompleteBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($expectedSource.Replace('::Read;', '::Re;'))
[System.IO.File]::WriteAllText($source, $initialSource)
[System.IO.File]::WriteAllText((Join-Path $workspaceSettings 'settings.toml'), @"
[lapce-rust]
serverPath = "$serverPath"
checkOnSave = false
"@)

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
    $captured = [CodeStrikeLspWindow]::CapturedOutput()
    "CODESTRIKE_LSP_CAPTURED_CHARS=$($captured.Length)"
    @($captured -split "`n" | Where-Object { $_ -match 'rust-analyzer|lapce-rust|plugin|server|error' } |
        Select-Object -Last 16) | ForEach-Object {
        "CODESTRIKE_LSP_PREFLIGHT_LOG=$($_.Substring(0, [Math]::Min($_.Length, 240)))"
    }
    Write-CodeStrikeRustFixtureTrace -Output $captured -Prefix 'CODESTRIKE_LSP_PREFOCUS_PROTOCOL'
    $foregroundPid = [CodeStrikeFocus]::ForegroundProcess()
    $foregroundProcess = Get-Process -Id $foregroundPid -ErrorAction SilentlyContinue
    "CODESTRIKE_LSP_PREFOCUS_FOREGROUND=$foregroundPid;$($foregroundProcess.ProcessName);session:$($foregroundProcess.SessionId)"
    "CODESTRIKE_LSP_APP_SESSION=$($process.SessionId)"
    "CODESTRIKE_LSP_WINDOW_TITLE=$($process.MainWindowTitle)"
    $window = $process.MainWindowHandle
    $popup = [CodeStrikeWindowState]::GetLastActivePopup($window)
    $owner = [CodeStrikeWindowState]::GetWindow($window, 4)
    $windowPid = [uint32]0
    $windowTid = [CodeStrikeWindowState]::GetWindowThreadProcessId($window, [ref]$windowPid)
    "CODESTRIKE_PREFLIGHT_WINDOW=handle:$($window.ToInt64());pid:$windowPid;tid:$windowTid;isWindow:$([CodeStrikeWindowState]::IsWindow($window));visible:$([CodeStrikeWindowState]::IsWindowVisible($window));enabled:$([CodeStrikeWindowState]::IsWindowEnabled($window));owner:$($owner.ToInt64());popup:$($popup.ToInt64());popupTitle:$([CodeStrikeWindowState]::Title($popup))"
    if ($PreflightOnly) {
        'CODESTRIKE_PREFLIGHT=observation-only;waiting-20s'
        Start-Sleep -Seconds 20
        return
    }

    [CodeStrikeLspWindow]::ShowWindow($process.MainWindowHandle, 9) | Out-Null
    if (-not [CodeStrikeFocus]::Focus($process.MainWindowHandle) -and
        -not [CodeStrikeFocusV9]::Focus($process.MainWindowHandle)) {
        "CODESTRIKE_LSP_FOCUS_DETAILS=$([CodeStrikeFocusReport]::TryAndDescribe($process.MainWindowHandle))"
        Write-CodeStrikeRustFixtureTrace -Output ([CodeStrikeLspWindow]::CapturedOutput()) -Prefix 'CODESTRIKE_LSP_FOCUS_FAILURE_PROTOCOL'
        throw "CodeStrike could not receive focus; foreground PID $([CodeStrikeFocus]::ForegroundProcess())."
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
    Save-CodeWindowScreenshot $rect (Join-Path $root 'initial-code-window.png')
    $tracePath = Join-Path $root 'standard-lsp-document-trace.jsonl'
    $initialState = Get-Fixture-GateState $source $tracePath
    $initialVersion = if ($null -eq $initialState.Summary.lastVersion) { 0 } else { [int]$initialState.Summary.lastVersion }

    Set-Clipboard -Value $validSource
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    [System.Windows.Forms.SendKeys]::SendWait('^s')
    $validSaved = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Milliseconds 500
        if ([Convert]::ToHexString([System.IO.File]::ReadAllBytes($source)) -eq [Convert]::ToHexString($validBytes)) {
            $validSaved = $true
            break
        }
    }
    if (-not $validSaved) { throw 'GUI did not persist exact valid Rust fixture bytes.' }
    'CODESTRIKE_LSP_VALID_EDIT=saved-exact-utf8-bytes'
    $validVersion = Wait-Fixture-Diagnostic $source $tracePath $initialVersion $false 'valid'
    Save-CodeWindowScreenshot $rect (Join-Path $root 'valid-code-window.png')

    Set-Clipboard -Value $expectedSource
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    [System.Windows.Forms.SendKeys]::SendWait('^s')
    $restoredSaved = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        Start-Sleep -Milliseconds 500
        if ([Convert]::ToHexString([System.IO.File]::ReadAllBytes($source)) -eq [Convert]::ToHexString($expectedBytes)) {
            $restoredSaved = $true
            break
        }
    }
    if (-not $restoredSaved) { throw 'GUI did not persist exact restored invalid Rust fixture bytes.' }
    'CODESTRIKE_LSP_RESTORED_EDIT=saved-exact-utf8-bytes'
    $invalidVersion = Wait-Fixture-Diagnostic $source $tracePath $validVersion $true 'restored-invalid'
    "CODESTRIKE_LSP_INVALID_RESTORED=version:$invalidVersion"
    Save-CodeWindowScreenshot $rect (Join-Path $root 'restored-code-window.png')

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

    'CODESTRIKE_LSP_COMPLETION_POPUP=read-label-observed-in-protocol'
    Save-CodeWindowScreenshot $rect (Join-Path $root 'completion-popup-code-window.png')

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
