param([Parameter(Mandatory = $true)][string]$VoltPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'trace-rust-lsp-fixture.ps1')
Add-Type -AssemblyName System.Windows.Forms
if (-not ('CodeStrikePrerequisiteCapture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
public static class CodeStrikePrerequisiteCapture {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
    private static readonly ConcurrentQueue<string> Output = new ConcurrentQueue<string>();
    public static void Clear() { string line; while (Output.TryDequeue(out line)) { } }
    public static void Begin(Process process) {
        process.OutputDataReceived += (sender, e) => { if (e.Data != null) Output.Enqueue(e.Data); };
        process.ErrorDataReceived += (sender, e) => { if (e.Data != null) Output.Enqueue(e.Data); };
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
    }
    public static bool HasDiagnostic(string code) {
        foreach (string line in Output)
            if (line.Contains("textDocument/publishDiagnostics") && line.Contains(code)) return true;
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
    public static string Text() { return string.Join("\n", Output.ToArray()); }
}
'@
}

$exe = (Resolve-Path 'editor/lapce/target/debug/CodeStrike.exe').Path
$volt = (Resolve-Path -LiteralPath $VoltPath).Path
$root = Join-Path $env:RUNNER_TEMP ('codestrike-ra-prerequisites-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $root 'fixture'
$src = Join-Path $fixture 'src'
$settings = Join-Path $fixture '.codestrike'
New-Item -ItemType Directory -Path $src, $settings -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $fixture 'Cargo.toml'), @'
[package]
name = "codestrike_lsp_fixture"
version = "0.1.0"
edition = "2021"
'@)
$source = Join-Path $src 'main.rs'
$fixtureText = "use std::io::Read;`nfn main() { let value: i32 = `"wrong`"; println!(`"{value}`"); }"
$refreshText = $fixtureText + "`n//diagnostic_refresh"
$refreshBytesHex = [Convert]::ToHexString([System.Text.UTF8Encoding]::new($false).GetBytes($refreshText))

$results = [ordered]@{}
foreach ($case in @('default', 'disabled', 'default_recheck')) {
    [System.IO.File]::WriteAllText($source, $fixtureText)
    if ($case -eq 'disabled') {
        $settingsText = @'
[lapce-rust]
serverPath = "rust-analyzer"
checkOnSave = false
cargo = { buildScripts = { enable = false } }
procMacro = { enable = false }
'@
    } else {
        $settingsText = @'
[lapce-rust]
serverPath = "rust-analyzer"
checkOnSave = false
'@
    }
    [System.IO.File]::WriteAllText((Join-Path $settings 'settings.toml'), $settingsText)
    $appData = Join-Path $root "$case-appdata"
    $localData = Join-Path $root "$case-localdata"
    New-Item -ItemType Directory -Path $appData, $localData -Force | Out-Null

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
    $start.Environment['RA_LOG'] = 'rust_analyzer=info'
    [CodeStrikePrerequisiteCapture]::Clear()
    $process = [System.Diagnostics.Process]::Start($start)
    if ($null -eq $process) { throw "Windows did not start CodeStrike for $case." }
    [CodeStrikePrerequisiteCapture]::Begin($process)
    try {
        $foundWindow = $false
        for ($attempt = 0; $attempt -lt 120; $attempt++) {
            Start-Sleep -Seconds 1
            $process.Refresh()
            if ($process.HasExited) { throw "CodeStrike exited during $case startup: $($process.ExitCode)." }
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) { $foundWindow = $true; break }
        }
        if (-not $foundWindow) { throw "CodeStrike exposed no window for $case within 120 seconds." }
        $initialE0308 = $false
        for ($attempt = 0; $attempt -lt 45; $attempt++) {
            if ([CodeStrikePrerequisiteCapture]::HasDiagnostic('E0308')) { $initialE0308 = $true; break }
            Start-Sleep -Seconds 1
            $process.Refresh()
            if ($process.HasExited) { throw "CodeStrike exited during $case diagnostics: $($process.ExitCode)." }
        }
        "CODESTRIKE_RA_PREREQ_INITIAL=$case;e0308:$initialE0308;wait_seconds:$attempt"

        [CodeStrikePrerequisiteCapture]::ShowWindow($process.MainWindowHandle, 9) | Out-Null
        if (-not [CodeStrikePrerequisiteCapture]::SetForegroundWindow($process.MainWindowHandle)) {
            throw "CodeStrike could not receive focus for the $case refresh edit."
        }
        $rect = [CodeStrikePrerequisiteCapture+Rect]::new()
        if (-not [CodeStrikePrerequisiteCapture]::GetWindowRect($process.MainWindowHandle, [ref]$rect)) {
            throw "CodeStrike window bounds were unavailable for $case."
        }
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
        if ($width -lt 300 -or $height -lt 250) { throw "Implausible CodeStrike window bounds for $case." }
        [CodeStrikePrerequisiteCapture]::SetCursorPos($rect.Left + [int]($width * 0.6), $rect.Top + [int]($height * 0.2)) | Out-Null
        [CodeStrikePrerequisiteCapture]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
        [CodeStrikePrerequisiteCapture]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
        [System.Windows.Forms.SendKeys]::SendWait('^{END}')
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}//diagnostic_refresh')
        [System.Windows.Forms.SendKeys]::SendWait('^s')
        $saved = $false
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            Start-Sleep -Milliseconds 500
            if ([Convert]::ToHexString([System.IO.File]::ReadAllBytes($source)) -eq $refreshBytesHex) {
                $saved = $true
                break
            }
        }
        if (-not $saved) { throw "The $case refresh edit did not save exact bytes." }
        "CODESTRIKE_RA_PREREQ_EDIT=$case;saved-exact-utf8-bytes"
        $afterEditE0308 = $false
        for ($attempt = 0; $attempt -lt 75; $attempt++) {
            if ([CodeStrikePrerequisiteCapture]::HasDiagnosticAtVersion('E0308', 2)) { $afterEditE0308 = $true; break }
            Start-Sleep -Seconds 1
            $process.Refresh()
            if ($process.HasExited) { throw "CodeStrike exited during $case post-edit diagnostics: $($process.ExitCode)." }
        }
        $results[$case] = [ordered]@{ initial = $initialE0308; afterEdit = $afterEditE0308 }
        "CODESTRIKE_RA_PREREQ_RESULT=$case;initial:$initialE0308;after_edit:$afterEditE0308;wait_seconds:$attempt"
    } finally {
        $process.Refresh()
        if (-not $process.HasExited) {
            if (-not $process.CloseMainWindow() -or -not $process.WaitForExit(15000)) {
                $process.Kill($true)
                $process.WaitForExit(10000) | Out-Null
            }
        }
        $process.WaitForExit()
        $output = [CodeStrikePrerequisiteCapture]::Text()
        $process.Dispose()
        Write-CodeStrikeRustDocumentTrace -Output $output -FixtureSource $source -TracePath (Join-Path $root "$case-lsp-document-trace.jsonl") -Prefix "CODESTRIKE_RA_PREREQ_DOCUMENT_$case"
        $initLine = @($output -split "`n" | Where-Object { $_.Contains('write to lsp: {') -and $_.Contains('"method":"initialize"') } | Select-Object -First 1)
        if ($initLine.Count -eq 0) { throw "No initialize options were captured for $case." }
        $initMatch = [regex]::Match($initLine[0], 'write to lsp: (\{.*\})')
        if (-not $initMatch.Success) { throw "No initialize payload was captured for $case." }
        $init = $initMatch.Groups[1].Value | ConvertFrom-Json
        $buildScripts = $init.params.initializationOptions.cargo.buildScripts.enable
        $procMacro = $init.params.initializationOptions.procMacro.enable
        "CODESTRIKE_RA_PREREQ_OPTIONS=$case;serverPath:$($init.params.initializationOptions.serverPath);buildScripts:$buildScripts;procMacro:$procMacro;checkOnSave:$($init.params.initializationOptions.checkOnSave)"
        if ($init.params.initializationOptions.serverPath -ne 'rust-analyzer') {
            throw "The $case case used a different language server."
        }
        if ($case -eq 'disabled' -and ($buildScripts -ne $false -or $procMacro -ne $false)) {
            throw 'The disabled fixture options were not sent to rust-analyzer.'
        }
        if ($case -ne 'disabled' -and ($null -ne $buildScripts -or $null -ne $procMacro)) {
            throw "The $case case unexpectedly overrode prerequisite defaults."
        }
        $progressLines = @($output -split "`n" | Where-Object {
            $_ -match 'Building compile-time deps|Loading proc-macros|invalid config|config error'
        } | Select-Object -Last 16)
        if ($progressLines.Count -eq 0) { "CODESTRIKE_RA_PREREQ_PROGRESS=$case;not-exposed-in-captured-stream" }
        foreach ($progressLine in $progressLines) {
            "CODESTRIKE_RA_PREREQ_PROGRESS=$case;$($progressLine.Substring(0, [Math]::Min($progressLine.Length, 300)))"
        }
        if ([Convert]::ToHexString([System.IO.File]::ReadAllBytes($source)) -ne $refreshBytesHex) {
            throw "The $case fixture did not retain exact refresh bytes."
        }
    }
}
"CODESTRIKE_RA_PREREQ_COMPARISON=default:$($results.default.initial)/$($results.default.afterEdit);disabled:$($results.disabled.initial)/$($results.disabled.afterEdit);default_recheck:$($results.default_recheck.initial)/$($results.default_recheck.afterEdit)"
