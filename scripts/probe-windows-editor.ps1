param([switch]$Startup)

$ErrorActionPreference = 'Stop'

$exe = (Resolve-Path 'editor/lapce/target/debug/CodeStrike.exe').Path
$fixture = Join-Path $env:RUNNER_TEMP 'codestrike-editor-fixture'
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $fixture 'main.rs'), ('fn main() { println!("CodeStrike fixture"); }' + "`n"))
[System.IO.File]::WriteAllText((Join-Path $fixture 'notes.txt'), "alpha`nbeta`n")

$start = [System.Diagnostics.ProcessStartInfo]::new($exe)
$start.Arguments = if ($Startup) { '--wait --new' } else { '--wait --new "' + $fixture + '"' }
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
    if ($editor.MainWindowTitle -notlike '*CodeStrike*') {
        throw "Unexpected window title: $($editor.MainWindowTitle)"
    }
    $mode = if ($Startup) { 'startup' } else { 'folder' }
    "CODESTRIKE_GUI_PROBE=$mode-window-ready; title=$($editor.MainWindowTitle)"

    Start-Sleep -Seconds 3
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
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
