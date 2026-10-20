param([Parameter(Mandatory = $true)][string]$VoltPath)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('CodeStrikeMissingServerWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class CodeStrikeMissingServerWindow {
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
    public static string CapturedOutput() { return string.Join("\n", Output.ToArray()); }
}
'@
}

$exe = (Resolve-Path 'editor/lapce/target/debug/CodeStrike.exe').Path
$volt = (Resolve-Path -LiteralPath $VoltPath).Path
$root = Join-Path $env:RUNNER_TEMP ('codestrike-missing-ra-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $root 'fixture'
$src = Join-Path $fixture 'src'
$settings = Join-Path $fixture '.codestrike'
$appData = Join-Path $root 'appdata'
$localData = Join-Path $root 'localdata'
New-Item -ItemType Directory -Path $src, $settings, $appData, $localData -Force | Out-Null
$missingServer = 'codestrike_missing_rust_analyzer_' + [guid]::NewGuid().ToString('N') + '.exe'
if (Get-Command $missingServer -ErrorAction SilentlyContinue) { throw 'Missing server fixture unexpectedly exists.' }

[System.IO.File]::WriteAllText((Join-Path $fixture 'Cargo.toml'), @'
[package]
name = "codestrike_missing_ra_fixture"
version = "0.1.0"
edition = "2021"
'@)
$source = Join-Path $src 'main.rs'
$originalText = "fn main() { println!(`"local fixture`" ); }`n"
[System.IO.File]::WriteAllText($source, $originalText)
$originalHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
[System.IO.File]::WriteAllText((Join-Path $settings 'settings.toml'), @"
[lapce-rust]
serverPath = "$missingServer"
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
[CodeStrikeMissingServerWindow]::BeginCapture($process)

try {
    $foundWindow = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        Start-Sleep -Seconds 1
        $process.Refresh()
        if ($process.HasExited) { throw "CodeStrike exited while the local server was unavailable: $($process.ExitCode)." }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            $foundWindow = $true
            break
        }
    }
    if (-not $foundWindow) { throw 'CodeStrike did not expose a window within 120 seconds.' }
    "CODESTRIKE_MISSING_RA_WINDOW=opened;pid:$($process.Id)"
    $failureMessage = 'Local language server unavailable. Check its path in workspace settings.'
    $reported = $false
    for ($attempt = 0; $attempt -lt 90; $attempt++) {
        if ([CodeStrikeMissingServerWindow]::HasOutput($failureMessage)) {
            $reported = $true
            break
        }
        Start-Sleep -Seconds 1
        $process.Refresh()
        if ($process.HasExited) { throw 'CodeStrike exited before reporting the language-server failure.' }
    }
    if (-not $reported) { throw 'The local language-server failure was not reported within 90 seconds.' }
    Start-Sleep -Seconds 3
    $process.Refresh()
    if ($process.HasExited) { throw 'CodeStrike exited after the language server failed to start.' }

    [CodeStrikeMissingServerWindow]::ShowWindow($process.MainWindowHandle, 9) | Out-Null
    if (-not [CodeStrikeMissingServerWindow]::SetForegroundWindow($process.MainWindowHandle)) {
        throw 'CodeStrike could not receive focus with an unavailable language server.'
    }
    $rect = [CodeStrikeMissingServerWindow+Rect]::new()
    if (-not [CodeStrikeMissingServerWindow]::GetWindowRect($process.MainWindowHandle, [ref]$rect)) {
        throw 'CodeStrike window bounds were unavailable.'
    }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -lt 300 -or $height -lt 250) { throw 'CodeStrike window bounds were implausible.' }
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if ($rect.Left -lt $screen.Left -or $rect.Top -lt $screen.Top -or
        $rect.Right -gt $screen.Right -or $rect.Bottom -gt $screen.Bottom) {
        throw 'CodeStrike window extends beyond the capture screen.'
    }
    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen([System.Drawing.Point]::new($rect.Left, $rect.Top), [System.Drawing.Point]::Empty, $bitmap.Size)
        $stream = [System.IO.MemoryStream]::new()
        try {
            $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                Where-Object MimeType -eq 'image/jpeg' | Select-Object -First 1
            $parameters = [System.Drawing.Imaging.EncoderParameters]::new(1)
            $parameters.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new(
                [System.Drawing.Imaging.Encoder]::Quality, [int64]45)
            $bitmap.Save($stream, $codec, $parameters)
            if ($stream.Length -gt 350KB) { throw 'Missing-server screenshot exceeded its capture size bound.' }
            $screenshotPath = Join-Path $env:RUNNER_TEMP 'codestrike-missing-ra.jpg'
            [System.IO.File]::WriteAllBytes($screenshotPath, $stream.ToArray())
            $screenshotHash = (Get-FileHash -LiteralPath $screenshotPath -Algorithm SHA256).Hash
            "CODESTRIKE_MISSING_RA_SCREENSHOT=file:$([System.IO.Path]::GetFileName($screenshotPath));sha256:$screenshotHash;bytes:$($stream.Length)"
        } finally { $stream.Dispose() }
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }

    [CodeStrikeMissingServerWindow]::SetCursorPos($rect.Left + [int]($width * 0.4), $rect.Top + [int]($height * 0.2)) | Out-Null
    [CodeStrikeMissingServerWindow]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [CodeStrikeMissingServerWindow]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    [System.Windows.Forms.SendKeys]::SendWait('^i')
    Start-Sleep -Seconds 2
    [System.Windows.Forms.SendKeys]::SendWait('^s')
    Start-Sleep -Seconds 2
    $afterHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    if ($afterHash -ne $originalHash) { throw 'The unavailable language server caused an unexpected source-file change.' }
    'CODESTRIKE_MISSING_RA_SOURCE=unchanged-after-completion-and-save'

    if (-not $process.CloseMainWindow() -or -not $process.WaitForExit(15000)) {
        throw 'CodeStrike did not close cleanly with an unavailable language server.'
    }
    $process.WaitForExit()
    $output = [CodeStrikeMissingServerWindow]::CapturedOutput()
    if (-not $output.Contains($failureMessage)) {
        throw 'The local-server failure was not reported by the proxy.'
    }
    $failureLine = @($output -split "`n" | Where-Object { $_.Contains($failureMessage) } | Select-Object -Last 1)
    $failureLine | ForEach-Object { Write-Host "CODESTRIKE_MISSING_RA_ERROR_LOG=$($_.Substring(0, [Math]::Min($_.Length, 450)))" }
    if ($output.Contains('"method":"initialize"')) {
        throw 'The missing language server unexpectedly received an initialize request.'
    }
    if (Get-ChildItem -LiteralPath $volt -Filter '*.gz' -ErrorAction SilentlyContinue) {
        throw 'The explicit server path unexpectedly acquired an archive.'
    }
    'CODESTRIKE_MISSING_RA=reported-error-source-unchanged-no-download'
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
