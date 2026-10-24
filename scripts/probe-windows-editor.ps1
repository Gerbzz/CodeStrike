param([switch]$Startup, [switch]$File)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('CodeStrikeWindowProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodeStrikeWindowProbe {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    private delegate bool EnumWindowsCallback(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    public static IntPtr FindEditorWindow(uint processId) {
        IntPtr selected = IntPtr.Zero;
        long largestArea = 0;
        EnumWindows((window, parameter) => {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            Rect rect;
            if (owner == processId && IsWindowVisible(window) && GetWindowRect(window, out rect)) {
                int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
                long area = (long)width * height;
                // Exclude hidden/helper windows (the observed helper was 16 x 16).
                if (width >= 400 && height >= 250 && area > largestArea) {
                    selected = window;
                    largestArea = area;
                }
            }
            return true;
        }, IntPtr.Zero);
        return selected;
    }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
}
'@
}

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
    $window = [IntPtr]::Zero
    $windowReady = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        Start-Sleep -Seconds 1
        $editor.Refresh()
        if ($editor.HasExited) { throw "Editor exited during startup with code $($editor.ExitCode)." }
        if (($attempt % 20) -eq 19) {
            "CODESTRIKE_WINDOW_WAIT=seconds:$($attempt + 1);pid:$($editor.Id);session:$($editor.SessionId);handle:$($window)"
        }
        $window = [CodeStrikeWindowProbe]::FindEditorWindow([uint32]$editor.Id)
        if ($window -ne [IntPtr]::Zero) {
            $windowReady = $true
            break
        }
    }
    if (-not $windowReady) { throw 'No editor window appeared within 120 seconds.' }
    $mode = if ($Startup) { 'startup' } elseif ($File) { 'file' } else { 'folder' }
    "CODESTRIKE_GUI_PROBE=$mode-window-ready; pid=$($editor.Id); handle=$window"

    Start-Sleep -Seconds 3
    function Set-EditorForeground {
        param([IntPtr]$window, [int]$processId)
        $focus = New-Object -ComObject WScript.Shell
        $foreground = $false
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            [CodeStrikeWindowProbe]::ShowWindow($window, 9) | Out-Null
            $focus.AppActivate($processId) | Out-Null
            [CodeStrikeWindowProbe]::SetForegroundWindow($window) | Out-Null
            Start-Sleep -Milliseconds 250
            if ([CodeStrikeWindowProbe]::GetForegroundWindow() -eq $window) {
                $foreground = $true
                break
            }
        }
        if (-not $foreground) { throw 'Editor did not own foreground; refusing an occluded capture.' }
    }
    Set-EditorForeground -window $window -processId $editor.Id
    "CODESTRIKE_GUI_FOREGROUND=True;window=$window"
    Start-Sleep -Seconds 2
    if ($File) {
        $rect = [CodeStrikeWindowProbe+Rect]::new()
        if (-not [CodeStrikeWindowProbe]::GetWindowRect($window, [ref]$rect)) {
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
        $savedSource = [System.IO.File]::ReadAllText($sourceFile)
        $fileSavePassed = $savedSource.Contains('codestrike_ci_saved')
        if ($fileSavePassed) { 'CODESTRIKE_GUI_FILE_SAVE=passed' }
        else {
            # Preserve synthetic source and app pixels before the unchanged gate fails.
            "CODESTRIKE_GUI_FILE_SAVE_SOURCE=$($savedSource | ConvertTo-Json -Compress)"
            "CODESTRIKE_GUI_FILE_SAVE_FOREGROUND=$([CodeStrikeWindowProbe]::GetForegroundWindow());expected=$window"
        }
    }
    Set-EditorForeground -window $window -processId $editor.Id
    $rect = [CodeStrikeWindowProbe+Rect]::new()
    if (-not [CodeStrikeWindowProbe]::GetWindowRect($window, [ref]$rect)) {
        throw 'Cannot locate the editor for an app-only capture.'
    }
    if ([CodeStrikeWindowProbe]::GetForegroundWindow() -ne $window) {
        throw 'Editor lost foreground before capture.'
    }
    if (($rect.Right-$rect.Left) -lt 400 -or ($rect.Bottom-$rect.Top) -lt 250) {
        throw 'Refusing a helper-sized window capture.'
    }
    "CODESTRIKE_GUI_CAPTURE_RECT=$($rect.Left),$($rect.Top),$($rect.Right),$($rect.Bottom);window=$window"
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if ($rect.Left -lt $screen.Left -or $rect.Top -lt $screen.Top -or
        $rect.Right -gt $screen.Right -or $rect.Bottom -gt $screen.Bottom) {
        throw 'Editor capture rectangle is off-screen.'
    }
    $bounds = [System.Drawing.Rectangle]::new($rect.Left, $rect.Top, $rect.Right-$rect.Left, $rect.Bottom-$rect.Top)
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
                $evidence = Join-Path $PSScriptRoot '../artifacts/lapce-native'
                New-Item -ItemType Directory -Force -Path $evidence | Out-Null
                [IO.File]::WriteAllBytes((Join-Path $evidence "$mode.jpg"), $stream.ToArray())
                "CODESTRIKE_SCREENSHOT_${mode}_BASE64=$([Convert]::ToBase64String($stream.ToArray()))"
            } finally { $stream.Dispose() }
        } finally { $thumbnail.Dispose() }
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    if ($File -and -not $fileSavePassed) {
        throw 'Keyboard edit/save did not reach the opened fixture file.'
    }
} finally {
    $editor.Refresh()
    if (-not $editor.HasExited) { $editor.Kill($true); $editor.WaitForExit(10000) | Out-Null }
    $editor.Dispose()
}
