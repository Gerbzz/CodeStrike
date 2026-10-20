Add-Type -AssemblyName System.Drawing

if (-not ('CodeStrikeFocus' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class CodeStrikeFocus {
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint attach, uint attachTo, bool enable);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr window);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern void SwitchToThisWindow(IntPtr window, bool alternateTab);
    [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    public static uint ForegroundProcess() {
        uint pid;
        GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        return pid;
    }
    public static bool Focus(IntPtr window) {
        uint targetPid;
        GetWindowThreadProcessId(window, out targetPid);
        ShowWindow(window, 9);
        if (SetForegroundWindow(window)) {
            Thread.Sleep(200);
            if (ForegroundProcess() == targetPid) return true;
        }
        uint foregroundPid;
        uint foregroundThread = GetWindowThreadProcessId(GetForegroundWindow(), out foregroundPid);
        uint currentThread = GetCurrentThreadId();
        bool attached = foregroundThread != 0 && foregroundThread != currentThread
            && AttachThreadInput(currentThread, foregroundThread, true);
        try {
            BringWindowToTop(window);
            SetForegroundWindow(window);
        } finally {
            if (attached) AttachThreadInput(currentThread, foregroundThread, false);
        }
        Thread.Sleep(200);
        if (ForegroundProcess() == targetPid) return true;
        // A synthetic ALT key grants this UI automation thread a foreground turn.
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
        SetForegroundWindow(window);
        Thread.Sleep(200);
        if (ForegroundProcess() == targetPid) return true;
        SwitchToThisWindow(window, true);
        Thread.Sleep(200);
        return ForegroundProcess() == targetPid;
    }
}
'@
}

function Save-CodeWindowScreenshot($windowRect, [string]$path) {
    $width = [int]($windowRect.Right - $windowRect.Left)
    $height = [int]($windowRect.Bottom - $windowRect.Top)
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    if ($width -lt 300 -or $height -lt 250 -or
        $windowRect.Left -lt $screen.Left -or $windowRect.Top -lt $screen.Top -or
        $windowRect.Right -gt $screen.Right -or $windowRect.Bottom -gt $screen.Bottom) {
        throw 'CodeStrike window is outside the capture screen.'
    }
    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($windowRect.Left, $windowRect.Top, 0, 0, $bitmap.Size)
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    "CODESTRIKE_PRIVATE_SCREENSHOT=$path;sha256:$((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash)"
}
