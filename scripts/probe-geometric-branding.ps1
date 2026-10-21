$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodeStrikeBrandingWindow {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr window, int x, int y, int w, int h, bool repaint);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr window, ref Point point);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
}
'@

$exe = (Resolve-Path 'editor/lapce/target/debug/CodeStrike.exe').Path
$isolated = Join-Path $env:RUNNER_TEMP ('codestrike-branding-' + [guid]::NewGuid().ToString('N'))
$output = Join-Path $env:RUNNER_TEMP 'codestrike-branding-evidence'
New-Item -ItemType Directory -Path $isolated, $output, (Join-Path $isolated 'appdata'), (Join-Path $isolated 'localdata') -Force | Out-Null
$start = [System.Diagnostics.ProcessStartInfo]::new($exe)
$start.Arguments = '--wait --new'
$start.UseShellExecute = $false
$start.Environment['APPDATA'] = Join-Path $isolated 'appdata'
$start.Environment['LOCALAPPDATA'] = Join-Path $isolated 'localdata'
$process = [System.Diagnostics.Process]::Start($start)
if ($null -eq $process) { throw 'Native CodeStrike process did not start.' }
$captures = @()

function Save-AppCapture([string]$name) {
    $rect = [CodeStrikeBrandingWindow+Rect]::new()
    $origin = [CodeStrikeBrandingWindow+Point]::new()
    if (-not [CodeStrikeBrandingWindow]::GetClientRect($process.MainWindowHandle, [ref]$rect)) { throw 'Client bounds unavailable.' }
    if (-not [CodeStrikeBrandingWindow]::ClientToScreen($process.MainWindowHandle, [ref]$origin)) { throw 'Client position unavailable.' }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -lt 600 -or $height -lt 400) { throw 'Native client is unexpectedly small.' }
    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($origin.X, $origin.Y, 0, 0, $bitmap.Size)
        $png = Join-Path $output ($name + '.png')
        $bitmap.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
        $preview = [System.IO.MemoryStream]::new()
        try {
            $bitmap.Save($preview, [System.Drawing.Imaging.ImageFormat]::Jpeg)
            if ($preview.Length -gt 500KB) { throw 'App preview exceeds log bound.' }
            Write-Host "CODESTRIKE_BRANDING_${name}_BASE64=$([Convert]::ToBase64String($preview.ToArray()))"
        } finally { $preview.Dispose() }
        return @{ name = $name; width = $width; height = $height; sha256 = (Get-FileHash -LiteralPath $png -Algorithm SHA256).Hash }
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

try {
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        Start-Sleep -Seconds 1
        $process.Refresh()
        if ($process.HasExited) { throw "Native process exited: $($process.ExitCode)" }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) { break }
    }
    if ($process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'Native window did not appear.' }
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $width = [Math]::Min(1000, $screen.Width - 40)
    $height = [Math]::Min(720, $screen.Height - 80)
    if (-not [CodeStrikeBrandingWindow]::MoveWindow($process.MainWindowHandle, 20, 20, $width, $height, $true)) { throw 'Could not position native window.' }
    if (-not [CodeStrikeBrandingWindow]::SetForegroundWindow($process.MainWindowHandle)) { throw 'Native window did not receive focus.' }
    Start-Sleep -Seconds 5
    $smallIcon = [CodeStrikeBrandingWindow]::SendMessageW($process.MainWindowHandle, 0x7f, [IntPtr]::Zero, [IntPtr]::Zero)
    if ($smallIcon -eq [IntPtr]::Zero) { throw 'Selected Lapce window has no small application icon.' }
    $captures += Save-AppCapture 'startup'
    [System.Windows.Forms.SendKeys]::SendWait('{F1}')
    Start-Sleep -Milliseconds 700
    [System.Windows.Forms.SendKeys]::SendWait('About CodeStrike')
    Start-Sleep -Milliseconds 700
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Start-Sleep -Seconds 3
    $captures += Save-AppCapture 'about'
    $proof = @{ head = (& git rev-parse HEAD).Trim(); executable = $exe; executableSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash; processId = $process.Id; windowTitle = $process.MainWindowTitle; nativeWindowSmallIconSet = $true; taskbarAppearanceVerified = $false; captures = $captures }
    $proof | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'native-proof.json') -Encoding utf8
    Write-Host ('CODESTRIKE_BRANDING_PROOF=' + ($proof | ConvertTo-Json -Depth 5 -Compress))
} finally {
    $process.Refresh()
    if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit(10000) | Out-Null }
    $process.Dispose()
}
