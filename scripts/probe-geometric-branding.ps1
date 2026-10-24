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
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr window, int x, int y, int w, int h, bool repaint);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr window, ref Point point);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr window, System.Text.StringBuilder name, int count);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", EntryPoint = "GetClassLongPtrW")] public static extern IntPtr GetClassLongPtrW(IntPtr window, int index);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll")] public static extern bool FreeLibrary(IntPtr module);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr LoadImageW(IntPtr module, IntPtr name, uint type, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll", EntryPoint = "LoadImageW", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr LoadIconFile(IntPtr module, string path, uint type, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool DrawIconEx(IntPtr dc, int x, int y, IntPtr icon, int width, int height, uint step, IntPtr brush, uint flags);
    public delegate bool EnumWindowProc(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowProc callback, IntPtr parameter);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr window, System.Text.StringBuilder text, int count);
    public sealed class WindowDetails {
        public IntPtr Handle;
        public uint ProcessId;
        public string Title;
        public string WindowClass;
        public bool Visible;
        public int Width;
        public int Height;
    }
    public static WindowDetails[] ProcessWindows(uint processId) {
        var windows = new System.Collections.Generic.List<WindowDetails>();
        EnumWindows((window, parameter) => {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != processId) return true;
            var title = new System.Text.StringBuilder(512);
            var windowClass = new System.Text.StringBuilder(256);
            GetWindowTextW(window, title, title.Capacity);
            GetClassNameW(window, windowClass, windowClass.Capacity);
            Rect rect;
            GetClientRect(window, out rect);
            windows.Add(new WindowDetails {
                Handle = window, ProcessId = owner, Title = title.ToString(), WindowClass = windowClass.ToString(),
                Visible = IsWindowVisible(window), Width = rect.Right - rect.Left, Height = rect.Bottom - rect.Top
            });
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }
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
$editorWindow = [IntPtr]::Zero

function Get-IconPixelProof([IntPtr]$handle, [int]$width, [int]$height) {
    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::White)
        $dc = $graphics.GetHdc()
        try {
            if (-not [CodeStrikeBrandingWindow]::DrawIconEx($dc, 0, 0, $handle, $width, $height, 0, [IntPtr]::Zero, 3)) {
                throw 'Could not render the native icon for exact pixel comparison.'
            }
        } finally { $graphics.ReleaseHdc($dc) }
        $stream = [System.IO.MemoryStream]::new()
        $writer = [System.IO.BinaryWriter]::new($stream)
        try {
            for ($y = 0; $y -lt $height; $y++) {
                for ($x = 0; $x -lt $width; $x++) { $writer.Write($bitmap.GetPixel($x, $y).ToArgb()) }
            }
            $writer.Flush()
            return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($stream.ToArray()))
        } finally { $writer.Dispose(); $stream.Dispose() }
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

function Save-AppCapture([string]$name) {
    if ([CodeStrikeBrandingWindow]::GetForegroundWindow() -ne $editorWindow) { throw 'The selected editor is not the foreground window for its scoped capture.' }
    $rect = [CodeStrikeBrandingWindow+Rect]::new()
    $origin = [CodeStrikeBrandingWindow+Point]::new()
    if (-not [CodeStrikeBrandingWindow]::GetClientRect($editorWindow, [ref]$rect)) { throw 'Client bounds unavailable.' }
    if (-not [CodeStrikeBrandingWindow]::ClientToScreen($editorWindow, [ref]$origin)) { throw 'Client position unavailable.' }
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
        $candidates = @([CodeStrikeBrandingWindow]::ProcessWindows($process.Id))
        $editor = @($candidates | Where-Object {
            $_.Visible -and $_.Title -like '*CodeStrike*' -and $_.WindowClass -ne 'ConsoleWindowClass' -and
            $_.Width -ge 600 -and $_.Height -ge 400
        })
        if ($editor.Count -eq 1) { $editorWindow = $editor[0].Handle; break }
    }
    Write-Host ('CODESTRIKE_BRANDING_WINDOW_CANDIDATES=' + ($candidates | Select-Object ProcessId, Title, WindowClass, Visible, Width, Height | ConvertTo-Json -Compress))
    $candidates | Select-Object ProcessId, Title, WindowClass, Visible, Width, Height | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'window-candidates.json') -Encoding utf8
    if ($editorWindow -eq [IntPtr]::Zero) { throw 'A unique CodeStrike editor window owned by the launched process did not appear.' }
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $width = [Math]::Min(1000, $screen.Width - 40)
    $height = [Math]::Min(720, $screen.Height - 80)
    if (-not [CodeStrikeBrandingWindow]::MoveWindow($editorWindow, 20, 20, $width, $height, $true)) { throw 'Could not position native window.' }
    if (-not [CodeStrikeBrandingWindow]::SetForegroundWindow($editorWindow)) { throw 'Native window did not receive focus.' }
    Start-Sleep -Seconds 5
    $windowClass = [System.Text.StringBuilder]::new(256)
    [CodeStrikeBrandingWindow]::GetClassNameW($editorWindow, $windowClass, $windowClass.Capacity) | Out-Null
    [uint32]$windowProcessId = 0
    [CodeStrikeBrandingWindow]::GetWindowThreadProcessId($editorWindow, [ref]$windowProcessId) | Out-Null
    if ($windowProcessId -ne $process.Id) { throw 'Selected editor window no longer belongs to the launched process.' }
    $smallIcon = [CodeStrikeBrandingWindow]::SendMessageW($editorWindow, 0x7f, [IntPtr]::Zero, [IntPtr]::Zero)
    $windowDiagnostic = @{
        launchedProcessId = $process.Id; windowProcessId = $windowProcessId
        handle = $editorWindow.ToInt64(); title = $editor[0].Title; windowClass = $windowClass.ToString()
        smallIcon = $smallIcon.ToInt64()
        small2Icon = ([CodeStrikeBrandingWindow]::SendMessageW($editorWindow, 0x7f, [IntPtr]::new(2), [IntPtr]::Zero)).ToInt64()
        bigIcon = ([CodeStrikeBrandingWindow]::SendMessageW($editorWindow, 0x7f, [IntPtr]::new(1), [IntPtr]::Zero)).ToInt64()
        classSmallIcon = ([CodeStrikeBrandingWindow]::GetClassLongPtrW($editorWindow, -34)).ToInt64()
        classBigIcon = ([CodeStrikeBrandingWindow]::GetClassLongPtrW($editorWindow, -14)).ToInt64()
    }
    Write-Host ('CODESTRIKE_BRANDING_WINDOW_DIAGNOSTIC=' + ($windowDiagnostic | ConvertTo-Json -Compress))
    $windowDiagnostic | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'window-diagnostic.json') -Encoding utf8
    $resourceModule = [CodeStrikeBrandingWindow]::LoadLibraryExW($exe, [IntPtr]::Zero, 0x22)
    $resourceModuleError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($resourceModule -ne [IntPtr]::Zero) {
        try {
            $resourceIcon = [CodeStrikeBrandingWindow]::LoadImageW($resourceModule, [IntPtr]::new(1), 1, 0, 0, 0x40)
            $resourceIconError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-Host "CODESTRIKE_BRANDING_RESOURCE_DIAGNOSTIC=loaded:$($resourceIcon -ne [IntPtr]::Zero);error:$resourceIconError"
            if ($resourceIcon -ne [IntPtr]::Zero) { [CodeStrikeBrandingWindow]::DestroyIcon($resourceIcon) | Out-Null }
        } finally { [CodeStrikeBrandingWindow]::FreeLibrary($resourceModule) | Out-Null }
    } else {
        Write-Host "CODESTRIKE_BRANDING_RESOURCE_DIAGNOSTIC=module-load-failed;error:$resourceModuleError"
    }
    if ($smallIcon -eq [IntPtr]::Zero) { throw 'Selected Lapce window has no small application icon.' }
    $nativeIcon = [System.Drawing.Icon]::FromHandle($smallIcon)
    $iconWidth = $nativeIcon.Width
    $iconHeight = $nativeIcon.Height
    $nativeIcon.Dispose()
    $reviewedIco = (Resolve-Path 'assets/branding/CodeStrike-geometric.ico').Path
    $reviewedIcon = [CodeStrikeBrandingWindow]::LoadIconFile([IntPtr]::Zero, $reviewedIco, 1, $iconWidth, $iconHeight, 0x10)
    if ($reviewedIcon -eq [IntPtr]::Zero) { throw 'Windows could not load the reviewed icon for pixel comparison.' }
    try {
        $actualPixels = Get-IconPixelProof $smallIcon $iconWidth $iconHeight
        $reviewedPixels = Get-IconPixelProof $reviewedIcon $iconWidth $iconHeight
        Write-Host "CODESTRIKE_BRANDING_ICON_PIXELS=size:${iconWidth}x${iconHeight};actual:$actualPixels;reviewed:$reviewedPixels"
        if ($actualPixels -ne $reviewedPixels) { throw 'The selected native window icon pixels differ from the reviewed ICO.' }
    } finally { [CodeStrikeBrandingWindow]::DestroyIcon($reviewedIcon) | Out-Null }
    $captures += Save-AppCapture 'startup'
    [System.Windows.Forms.SendKeys]::SendWait('{F1}')
    Start-Sleep -Milliseconds 700
    [System.Windows.Forms.SendKeys]::SendWait('About CodeStrike')
    Start-Sleep -Milliseconds 700
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Start-Sleep -Seconds 3
    $captures += Save-AppCapture 'about'
    $proof = @{ head = (& git rev-parse HEAD).Trim(); executable = $exe; executableSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash; processId = $process.Id; windowTitle = $editor[0].Title; nativeWindowSmallIconSet = $true; nativeWindowIconPixelsMatch = $true; taskbarAppearanceVerified = $false; captures = $captures }
    $proof | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'native-proof.json') -Encoding utf8
    Write-Host ('CODESTRIKE_BRANDING_PROOF=' + ($proof | ConvertTo-Json -Depth 5 -Compress))
} catch {
    $failure = $_
    $failureProof = @{ head = (& git rev-parse HEAD).Trim(); verified = $false; failure = $failure.Exception.Message }
    if ($editorWindow -ne [IntPtr]::Zero -and -not $process.HasExited) {
        try {
            if ([CodeStrikeBrandingWindow]::SetForegroundWindow($editorWindow)) {
                Start-Sleep -Milliseconds 250
                $failureCapture = Save-AppCapture 'failed-native-window'
                $failureProof.capture = $failureCapture
            }
        } catch { Write-Host "CODESTRIKE_BRANDING_FAILURE_CAPTURE_ERROR=$($_.Exception.Message)" }
    }
    $failureProof | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'failed-native-proof.json') -Encoding utf8
    throw $failure
} finally {
    $process.Refresh()
    if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit(10000) | Out-Null }
    $process.Dispose()
}
