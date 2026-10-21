param([Parameter(Mandatory = $true)][string]$VoltPath)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('CodeStrikeLspWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodeStrikeLspWindow {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
}
public sealed class CodeStrikeLspCapture {
    private readonly object gate = new object();
    private readonly System.Text.StringBuilder output = new System.Text.StringBuilder();
    private readonly System.Threading.Tasks.Task stdout;
    private readonly System.Threading.Tasks.Task stderr;
    public CodeStrikeLspCapture(System.Diagnostics.Process process) {
        stdout = Drain(process.StandardOutput);
        stderr = Drain(process.StandardError);
    }
    private async System.Threading.Tasks.Task Drain(System.IO.StreamReader reader) {
        string line;
        while ((line = await reader.ReadLineAsync().ConfigureAwait(false)) != null) {
            lock (gate) { output.AppendLine(line); }
        }
    }
    public string Snapshot() { lock (gate) { return output.ToString(); } }
    public bool Wait(int milliseconds) {
        return System.Threading.Tasks.Task.WaitAll(new[] { stdout, stderr }, milliseconds);
    }
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
$sourceUri = ([uri]$source).AbsoluteUri
$expectedSource = "use std::io::Read;`nfn main() { let value: i32 = `"wrong`"; println!(`"{value}`"); }"
$expectedBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($expectedSource)
[System.IO.File]::WriteAllText($source, $expectedSource.Replace('::Read;', '::Re;'))
[System.IO.File]::WriteAllText((Join-Path $workspaceSettings 'settings.toml'), @'
[lapce-rust]
serverPath = "rust-analyzer"
checkOnSave = true
'@)

# The pinned Windows directories crate resolves the Roaming known folder, not
# APPDATA overrides. Seed one temporary binding on the fresh hosted runner.
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'The temporary focus binding requires the fresh hosted CI fixture.' }
$configRoot = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'ArtCraft\CodeStrike\config'
$keymapsPath = Join-Path $configRoot 'keymaps.toml'
if (Test-Path -LiteralPath $keymapsPath) { throw 'The hosted CodeStrike keymap profile was not fresh.' }
New-Item -ItemType Directory -Path $configRoot -Force | Out-Null
$keymapText = "[[keymaps]]`nkey = `"F6`"`ncommand = `"focus_editor`"`n"
[System.IO.File]::WriteAllText($keymapsPath, $keymapText, [System.Text.UTF8Encoding]::new($false))
$keymapHash = (Get-FileHash -LiteralPath $keymapsPath -Algorithm SHA256).Hash
'CODESTRIKE_LSP_FOCUS_BINDING=temporary-f6-focus_editor-on-fresh-hosted-profile'

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
try {
    $process = [System.Diagnostics.Process]::Start($start)
    if ($null -eq $process) { throw 'Windows did not start CodeStrike.' }
} catch {
    Remove-Item -LiteralPath $keymapsPath
    throw
}
$capture = [CodeStrikeLspCapture]::new($process)
$verified = $false

function Get-ReadCompletion([string]$text, [string]$expectedUri) {
    $messages = @($text -split "`n" | ForEach-Object {
        $line = [regex]::Replace($_, '\x1B\[[0-?]*[ -/]*[@-~]', '')
        $startIndex = $line.IndexOf('{"jsonrpc"')
        if ($startIndex -ge 0) {
            try { $line.Substring($startIndex) | ConvertFrom-Json -ErrorAction Stop } catch { }
        }
    })
    $requests = @($messages | Where-Object {
        $_.method -eq 'textDocument/completion' -and $_.params.position.line -eq 0 -and
        $_.params.position.character -eq 15 -and $_.params.textDocument.uri -eq $expectedUri
    })
    foreach ($request in $requests) {
        foreach ($response in @($messages | Where-Object { $null -ne $_.result -and $_.id -eq $request.id })) {
            $items = if ($null -ne $response.result.items) { @($response.result.items) } else { @($response.result) }
            if (@($items | Where-Object label -eq 'Read').Count -gt 0) { return $true }
        }
    }
    return $false
}

function Save-LspCapture([string]$marker) {
    [uint32]$windowProcessId = 0
    [CodeStrikeLspWindow]::GetWindowThreadProcessId($process.MainWindowHandle, [ref]$windowProcessId) | Out-Null
    if ($windowProcessId -ne $process.Id -or [CodeStrikeLspWindow]::GetForegroundWindow() -ne $process.MainWindowHandle) {
        throw 'The isolated CodeStrike process is not the foreground window for its scoped LSP capture.'
    }
    $rect = [CodeStrikeLspWindow+Rect]::new()
    if (-not [CodeStrikeLspWindow]::GetWindowRect($process.MainWindowHandle, [ref]$rect)) { throw 'LSP capture bounds unavailable.' }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if ($width -lt 300 -or $height -lt 250 -or $rect.Left -lt $screen.Left -or $rect.Top -lt $screen.Top -or
        $rect.Right -gt $screen.Right -or $rect.Bottom -gt $screen.Bottom) { throw 'LSP capture bounds are outside the isolated app screen.' }
    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen([System.Drawing.Point]::new($rect.Left, $rect.Top), [System.Drawing.Point]::Empty, $bitmap.Size)
        $stream = [System.IO.MemoryStream]::new()
        try {
            $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg' | Select-Object -First 1
            $parameters = [System.Drawing.Imaging.EncoderParameters]::new(1)
            $parameters.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, [int64]45)
            $bitmap.Save($stream, $codec, $parameters)
            if ($stream.Length -gt 350KB) { throw 'LSP screenshot exceeded its log bound.' }
            Write-Host "${marker}=$([Convert]::ToBase64String($stream.ToArray()))"
        } finally { $stream.Dispose() }
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

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

    # The local proxy writes LSP traffic to its console stream, not the app log.
    # Leave enough time for a fresh rust-analyzer crate graph before closing.
    Start-Sleep -Seconds 45
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
    [System.Windows.Forms.SendKeys]::SendWait('{F6}')
    Start-Sleep -Milliseconds 200
    [System.Windows.Forms.SendKeys]::SendWait('^{HOME}')
    Start-Sleep -Milliseconds 100
    [System.Windows.Forms.SendKeys]::SendWait('{END}')
    Start-Sleep -Milliseconds 100
    [System.Windows.Forms.SendKeys]::SendWait('{LEFT 1}')
    Start-Sleep -Milliseconds 100
    $completionStart = $capture.Snapshot().Length
    [System.Windows.Forms.SendKeys]::SendWait('^ ')
    $completionReady = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) { throw 'CodeStrike exited while waiting for the real Read completion.' }
        if (Get-ReadCompletion ($capture.Snapshot().Substring($completionStart)) $sourceUri) { $completionReady = $true; break }
    }
    if (-not $completionReady) { throw 'The focused editor did not receive a matching Read completion response at the fixture caret.' }
    Start-Sleep -Milliseconds 500
    'CODESTRIKE_LSP_COMPLETION_READY=request-position-0-15-matched-response-read'
    'CODESTRIKE_LSP_COMPLETION_KEYS=sent'

    Save-LspCapture 'CODESTRIKE_LSP_SCREENSHOT_BASE64'

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

    $diagnosticReady = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $diagnosticReady = @($capture.Snapshot() -split "`n" | Where-Object {
            $_.Contains('textDocument/publishDiagnostics') -and $_.Contains('E0308') -and $_ -match [regex]::Escape('"uri":"' + $sourceUri + '"')
        }).Count -gt 0
        if ($diagnosticReady) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $diagnosticReady) { throw 'No rust-analyzer E0308 diagnostic arrived for the saved Rust fixture.' }

    if (-not $process.CloseMainWindow() -or -not $process.WaitForExit(15000)) {
        throw 'CodeStrike did not close cleanly after the diagnostic capture.'
    }
    if (-not $capture.Wait(10000)) {
        throw 'CodeStrike console capture did not complete after exit.'
    }
    $output = $capture.Snapshot()
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
    $verified = $true
} catch {
    $failure = $_
    $process.Refresh()
    if (-not $process.HasExited) {
        try {
            if ([CodeStrikeLspWindow]::SetForegroundWindow($process.MainWindowHandle)) {
                Start-Sleep -Milliseconds 250
                Save-LspCapture 'CODESTRIKE_LSP_FAILURE_SCREENSHOT_BASE64'
            }
        } catch { Write-Host "CODESTRIKE_LSP_FAILURE_CAPTURE_ERROR=$($_.Exception.Message)" }
    }
    throw $failure
} finally {
    $process.Refresh()
    if (-not $process.HasExited) {
        if (-not $process.CloseMainWindow() -or -not $process.WaitForExit(15000)) {
            $process.Kill($true)
            $process.WaitForExit(10000) | Out-Null
        }
    }
    if (-not $verified -and $capture.Wait(10000)) {
        $failureOutput = $capture.Snapshot()
        $failureLines = @($failureOutput -split "`n" | Where-Object {
            $_ -match 'initialization_options|textDocument/completion|"label":"Read"|publishDiagnostics|ERROR'
        } | Select-Object -Last 20)
        $failureLines | ForEach-Object { Write-Host "CODESTRIKE_LSP_FAILURE_LOG=$($_.Substring(0, [Math]::Min($_.Length, 450)))" }
        $observedE0308 = @($failureOutput -split "`n" | Where-Object { $_.Contains('publishDiagnostics') -and $_.Contains('E0308') }).Count -gt 0
        Write-Host "CODESTRIKE_LSP_FAILURE_DIAGNOSTIC_OBSERVED=$observedE0308"
    }
    $process.Dispose()
    if ((Get-FileHash -LiteralPath $keymapsPath -Algorithm SHA256).Hash -ne $keymapHash) {
        throw 'The temporary focus binding changed unexpectedly; it was preserved for diagnosis.'
    }
    Remove-Item -LiteralPath $keymapsPath
}
