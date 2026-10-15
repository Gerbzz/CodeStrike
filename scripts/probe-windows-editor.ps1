param([switch]$Startup, [switch]$File)

$ErrorActionPreference = 'Stop'

$exe = (Resolve-Path 'editor/lapce/target/debug/CodeStrike.exe').Path
$fixture = Join-Path $env:RUNNER_TEMP 'codestrike-editor-fixture'
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$sourceFile = Join-Path $fixture 'main.rs'
[System.IO.File]::WriteAllText($sourceFile, ('fn main() { println!("CodeStrike fixture"); }' + "`n"))
[System.IO.File]::WriteAllText((Join-Path $fixture 'notes.txt'), "alpha`nbeta`n")

$start = [System.Diagnostics.ProcessStartInfo]::new($exe)
$start.Arguments = if ($Startup) {
    '--wait --new'
} elseif ($File) {
    '--wait --new "' + $sourceFile + '"'
} else {
    '--wait --new "' + $fixture + '"'
}
$start.UseShellExecute = $false
$editor = [System.Diagnostics.Process]::Start($start)
if ($null -eq $editor) { throw 'Windows did not start the editor process.' }

try {
    $windowReady = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Seconds 1
        $editor.Refresh()
        if ($editor.HasExited) { throw "Editor exited during startup with code $($editor.ExitCode)." }
        if ($editor.MainWindowHandle -ne [IntPtr]::Zero) {
            $windowReady = $true
            break
        }
    }
    if (-not $windowReady) { throw 'No editor window appeared within 30 seconds.' }
    $mode = if ($Startup) { 'startup' } elseif ($File) { 'file' } else { 'folder' }
    "CODESTRIKE_GUI_PROBE=$mode-window-ready; title=$($editor.MainWindowTitle); handle=$($editor.MainWindowHandle)"

    Start-Sleep -Seconds 3
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if (-not ('CodeStrikeWindowProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodeStrikeWindowProbe {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
}
'@
    }
    [CodeStrikeWindowProbe]::ShowWindow($editor.MainWindowHandle, 9) | Out-Null
    $foreground = [CodeStrikeWindowProbe]::SetForegroundWindow($editor.MainWindowHandle)
    "CODESTRIKE_GUI_FOREGROUND=$foreground"
    Start-Sleep -Seconds 2
    if ($File) {
        if (-not $foreground) { throw 'Editor window could not receive keyboard focus.' }
        $rect = [CodeStrikeWindowProbe+Rect]::new()
        if (-not [CodeStrikeWindowProbe]::GetWindowRect($editor.MainWindowHandle, [ref]$rect)) {
            throw 'Could not locate editor window for file interaction.'
        }
        $x = $rect.Left + [int](($rect.Right - $rect.Left) * 0.68)
        $y = $rect.Top + [int](($rect.Bottom - $rect.Top) * 0.23)
        [CodeStrikeWindowProbe]::SetCursorPos($x, $y) | Out-Null
        [CodeStrikeWindowProbe]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
        [CodeStrikeWindowProbe]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
        [System.Windows.Forms.SendKeys]::SendWait('^{END}')
        [System.Windows.Forms.SendKeys]::SendWait('codestrike_ci_saved')
        [System.Windows.Forms.SendKeys]::SendWait('^s')
        Start-Sleep -Seconds 2
        if (-not ([System.IO.File]::ReadAllText($sourceFile).Contains('codestrike_ci_saved'))) {
            throw 'Keyboard edit/save did not reach the opened fixture file.'
        }
        'CODESTRIKE_GUI_FILE_SAVE=passed'
    }
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $width = [Math]::Min(960, $bounds.Width)
        $height = [int][Math]::Round($bounds.Height * $width / $bounds.Width)
        $thumbnail = [System.Drawing.Bitmap]::new($bitmap, $width, $height)
        try {
            $stream = [System.IO.MemoryStream]::new()
            try {
                $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                    Where-Object MimeType -eq 'image/jpeg' | Select-Object -First 1
                $parameters = [System.Drawing.Imaging.EncoderParameters]::new(1)
                $parameters.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new(
                    [System.Drawing.Imaging.Encoder]::Quality, [int64]45)
                $thumbnail.Save($stream, $codec, $parameters)
                if ($stream.Length -gt 350KB) { throw 'Screenshot exceeded the bounded log size.' }
                "CODESTRIKE_SCREENSHOT_${mode}_BASE64=$([Convert]::ToBase64String($stream.ToArray()))"
            } finally { $stream.Dispose() }
        } finally { $thumbnail.Dispose() }
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
} finally {
    $editor.Refresh()
    if (-not $editor.HasExited) { $editor.Kill($true); $editor.WaitForExit(10000) | Out-Null }
    $editor.Dispose()
}
