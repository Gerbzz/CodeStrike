param([ValidateSet('Tabs', 'Search', 'Conflict')][string]$Scenario = 'Tabs')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('CodeStrikeAcceptanceWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodeStrikeAcceptanceWindow {
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
$root = Join-Path $env:RUNNER_TEMP ('codestrike-acceptance-' + $Scenario.ToLowerInvariant() + '-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $root 'fixture'
$appData = Join-Path $root 'appdata'
$localData = Join-Path $root 'localdata'
New-Item -ItemType Directory -Path $fixture, $appData, $localData -Force | Out-Null

function Start-Candidate([string[]]$paths) {
    $start = [System.Diagnostics.ProcessStartInfo]::new($exe)
    $start.Arguments = '--wait --new' + (($paths | ForEach-Object { ' "' + $_ + '"' }) -join '')
    $start.UseShellExecute = $false
    $start.Environment['APPDATA'] = $appData
    $start.Environment['LOCALAPPDATA'] = $localData
    $process = [System.Diagnostics.Process]::Start($start)
    if ($null -eq $process) { throw 'Windows did not start the editor.' }
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) { throw "Editor exited during startup: $($process.ExitCode)." }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            Start-Sleep -Seconds 4
            Write-Host "CODESTRIKE_ACCEPTANCE_WINDOW=$Scenario; handle=$($process.MainWindowHandle); title=$($process.MainWindowTitle)"
            return $process
        }
    }
    throw 'Editor did not expose a window within 20 seconds.'
}

function Focus-Candidate([System.Diagnostics.Process]$process) {
    $process.Refresh()
    if ($process.HasExited) { throw 'Editor exited before interaction.' }
    [CodeStrikeAcceptanceWindow]::ShowWindow($process.MainWindowHandle, 9) | Out-Null
    if (-not [CodeStrikeAcceptanceWindow]::SetForegroundWindow($process.MainWindowHandle)) {
        throw 'Editor window could not receive keyboard focus.'
    }
    Start-Sleep -Milliseconds 500
}

function Click-Editor([System.Diagnostics.Process]$process) {
    Focus-Candidate $process
    $rect = [CodeStrikeAcceptanceWindow+Rect]::new()
    if (-not [CodeStrikeAcceptanceWindow]::GetWindowRect($process.MainWindowHandle, [ref]$rect)) {
        throw 'Could not locate editor window.'
    }
    $x = $rect.Left + [int](($rect.Right - $rect.Left) * 0.68)
    $y = $rect.Top + [int](($rect.Bottom - $rect.Top) * 0.23)
    [CodeStrikeAcceptanceWindow]::SetCursorPos($x, $y) | Out-Null
    [CodeStrikeAcceptanceWindow]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [CodeStrikeAcceptanceWindow]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}

function Capture-Candidate([string]$name) {
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
                "CODESTRIKE_ACCEPTANCE_SCREENSHOT_${name}_BASE64=$([Convert]::ToBase64String($stream.ToArray()))"
            } finally { $stream.Dispose() }
        } finally { $thumbnail.Dispose() }
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Find-MarkerPath([string[]]$paths, [string]$marker) {
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $found = @($paths | Where-Object { [System.IO.File]::ReadAllText($_).Contains($marker) })
        if ($found.Count -gt 0) { return $found }
        Start-Sleep -Milliseconds 500
    }
    return @()
}

function Edit-Three-Tabs([System.Diagnostics.Process]$process, [string[]]$paths, [string]$prefix) {
    Click-Editor $process
    $changed = @()
    for ($index = 0; $index -lt 3; $index++) {
        $marker = "codestrike_${prefix}_$index"
        [System.Windows.Forms.SendKeys]::SendWait('^{END}')
        [System.Windows.Forms.SendKeys]::SendWait($marker)
        [System.Windows.Forms.SendKeys]::SendWait('^s')
        $matches = @(Find-MarkerPath $paths $marker)
        if ($matches.Count -ne 1) {
            throw "Tab $index did not save $marker to exactly one fixture file; matches=$($matches.Count)."
        }
        if ($changed -contains $matches[0]) {
            throw "Ctrl+Tab revisited $($matches[0]) before all three files were edited."
        }
        $changed += $matches[0]
        "CODESTRIKE_ACCEPTANCE_TAB_EDIT=$prefix;$index;$([IO.Path]::GetFileName($matches[0]))"
        [System.Windows.Forms.SendKeys]::SendWait('^{TAB}')
        Start-Sleep -Milliseconds 500
    }
    if ($changed.Count -ne 3) { throw 'Did not edit three distinct tabs.' }
}

function Close-Candidate([System.Diagnostics.Process]$process) {
    if ($null -ne $process) {
        $process.Refresh()
        if (-not $process.HasExited) {
            Focus-Candidate $process
            if (-not $process.CloseMainWindow()) { throw 'Window rejected graceful close.' }
            if (-not $process.WaitForExit(15000)) { throw 'Editor did not exit after graceful close.' }
        }
        $process.Dispose()
    }
}

$editor = $null
try {
    if ($Scenario -eq 'Tabs') {
        $paths = @('one.rs', 'two.rs', 'three.rs') | ForEach-Object { Join-Path $fixture $_ }
        foreach ($path in $paths) {
            [System.IO.File]::WriteAllText($path, "// $([IO.Path]::GetFileName($path))`n")
        }
        $editor = Start-Candidate (@($fixture) + $paths)
        Edit-Three-Tabs $editor $paths 'first'
        Capture-Candidate 'tabs'
        Close-Candidate $editor
        $editor = $null

        $editor = Start-Candidate @()
        Edit-Three-Tabs $editor $paths 'reopened'
        Capture-Candidate 'reopened'
        'CODESTRIKE_ACCEPTANCE_TABS_AND_REOPEN=passed'
    } else {
        throw "Scenario $Scenario has no assertions yet."
    }
} finally {
    if ($null -ne $editor) {
        $editor.Refresh()
        if (-not $editor.HasExited) { $editor.Kill($true); $editor.WaitForExit(10000) | Out-Null }
        $editor.Dispose()
    }
}
