param([ValidateSet('Tabs', 'Search', 'Conflict', 'CleanReload', 'Encoding', 'WorkspaceReplace')][string]$Scenario = 'Tabs')

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
    try {
        for ($attempt = 0; $attempt -lt 240; $attempt++) {
            Start-Sleep -Milliseconds 500
            $process.Refresh()
            if ($process.HasExited) { throw "Editor exited during startup: $($process.ExitCode)." }
            if (($attempt % 40) -eq 39) {
                Write-Host "CODESTRIKE_ACCEPTANCE_WINDOW_WAIT=seconds:$(($attempt + 1) / 2);pid:$($process.Id);session:$($process.SessionId);handle:$($process.MainWindowHandle)"
            }
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                Start-Sleep -Seconds 4
                Write-Host "CODESTRIKE_ACCEPTANCE_WINDOW=$Scenario; handle=$($process.MainWindowHandle); title=$($process.MainWindowTitle)"
                return $process
            }
        }
        try { Capture-Candidate 'window_timeout' | Write-Host } catch { Write-Host "CODESTRIKE_ACCEPTANCE_DISPLAY_ERROR=$($_.Exception.Message)" }
        throw 'Editor did not expose a window within 120 seconds.'
    } catch {
        $process.Refresh()
        if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit(10000) | Out-Null }
        $process.Dispose()
        throw
    }
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

function Click-WindowPoint([System.Diagnostics.Process]$process, [double]$relativeX, [double]$relativeY) {
    Focus-Candidate $process
    $rect = [CodeStrikeAcceptanceWindow+Rect]::new()
    if (-not [CodeStrikeAcceptanceWindow]::GetWindowRect($process.MainWindowHandle, [ref]$rect)) {
        throw 'Could not locate editor window for a UI action.'
    }
    $x = $rect.Left + [int](($rect.Right - $rect.Left) * $relativeX)
    $y = $rect.Top + [int](($rect.Bottom - $rect.Top) * $relativeY)
    Write-Host "CODESTRIKE_ACCEPTANCE_CLICK=relative:$relativeX,$relativeY;pixel:$x,$y;rect:$($rect.Left),$($rect.Top),$($rect.Right),$($rect.Bottom)"
    [CodeStrikeAcceptanceWindow]::SetCursorPos($x, $y) | Out-Null
    [CodeStrikeAcceptanceWindow]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [CodeStrikeAcceptanceWindow]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}

function Click-WindowOffset([System.Diagnostics.Process]$process, [int]$offsetX, [int]$offsetY) {
    Focus-Candidate $process
    $rect = [CodeStrikeAcceptanceWindow+Rect]::new()
    if (-not [CodeStrikeAcceptanceWindow]::GetWindowRect($process.MainWindowHandle, [ref]$rect)) {
        throw 'Could not locate editor window for a search hit.'
    }
    $x = $rect.Left + $offsetX
    $y = $rect.Top + $offsetY
    Write-Host "CODESTRIKE_ACCEPTANCE_CLICK=offset:$offsetX,$offsetY;pixel:$x,$y;rect:$($rect.Left),$($rect.Top),$($rect.Right),$($rect.Bottom)"
    [CodeStrikeAcceptanceWindow]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 100
    [CodeStrikeAcceptanceWindow]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 50
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
                if ($stream.Length -gt 350KB) { throw 'Screenshot exceeded the capture size bound.' }
                $screenshotPath = Join-Path $root "screenshot-$name.jpg"
                [System.IO.File]::WriteAllBytes($screenshotPath, $stream.ToArray())
                $screenshotHash = (Get-FileHash -LiteralPath $screenshotPath -Algorithm SHA256).Hash
                "CODESTRIKE_ACCEPTANCE_SCREENSHOT_${name}=file:$([System.IO.Path]::GetFileName($screenshotPath));sha256:$screenshotHash;bytes:$($stream.Length)"
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

function Wait-FileBytes([string]$path, [byte[]]$expected) {
    $expectedHex = [Convert]::ToHexString($expected)
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if ([Convert]::ToHexString([System.IO.File]::ReadAllBytes($path)) -ceq $expectedHex) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
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
    } elseif ($Scenario -eq 'Search') {
        $path = Join-Path $fixture 'main.rs'
        $other = Join-Path $fixture 'other.rs'
        $needle = 'codestrike_search_needle'
        [System.IO.File]::WriteAllText($path, "let $needle = 1;`nlet copy = $needle;`n")
        $expectedNavigation = "let café = nav_$needle;`n"
        [System.IO.File]::WriteAllText($other, "let café = $needle;`n")
        $editor = Start-Candidate @($fixture, $path)
        Click-Editor $editor
        [System.Windows.Forms.SendKeys]::SendWait('^+f')
        [System.Windows.Forms.SendKeys]::SendWait($needle)
        Start-Sleep -Seconds 3
        Capture-Candidate 'workspace_search'
        Click-WindowOffset $editor 425 460
        Start-Sleep -Seconds 2
        Capture-Candidate 'workspace_hit_click'
        Focus-Candidate $editor
        [System.Windows.Forms.SendKeys]::SendWait('nav_')
        [System.Windows.Forms.SendKeys]::SendWait('^s')
        $navigationPassed = $false
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            if ([System.IO.File]::ReadAllText($other) -ceq $expectedNavigation) {
                $navigationPassed = $true
                break
            }
            Start-Sleep -Milliseconds 500
        }
        if (-not $navigationPassed) {
            Capture-Candidate 'navigation_failure'
            Write-Host 'CODESTRIKE_ACCEPTANCE_SEARCH_NAVIGATION=failed'
        } else {
            Capture-Candidate 'workspace_hit_opened'
            Write-Host 'CODESTRIKE_ACCEPTANCE_SEARCH_NAVIGATION=passed'
        }
        Close-Candidate $editor
        $editor = $null

        $editor = Start-Candidate @($fixture, $path)
        Click-Editor $editor
        [System.Windows.Forms.SendKeys]::SendWait('^f')
        [System.Windows.Forms.SendKeys]::SendWait($needle)
        Start-Sleep -Seconds 2
        Capture-Candidate 'file_find'
        [System.Windows.Forms.SendKeys]::SendWait('{TAB}')
        Start-Sleep -Milliseconds 500
        Capture-Candidate 'replace_toggled'
        [System.Windows.Forms.SendKeys]::SendWait('codestrike_replaced')
        Capture-Candidate 'replace_ready'
        # The hosted desktop screenshot is scaled; use the full-resolution
        # window offset at the center of the Replace All icon.
        Click-WindowOffset $editor 627 142
        [System.Windows.Forms.SendKeys]::SendWait('^s')
        Start-Sleep -Seconds 2
        $replaced = [System.IO.File]::ReadAllText($path)
        $otherContent = [System.IO.File]::ReadAllText($other)
        if ($replaced.Contains($needle) -or
            ($replaced.Split([string[]]@('codestrike_replaced'), [StringSplitOptions]::None).Count - 1) -ne 2 -or
            -not $otherContent.Contains($needle)) {
            Capture-Candidate 'replace_failure'
            throw 'Per-file Replace All did not change exactly two matches in main.rs while leaving other.rs intact.'
        }
        Capture-Candidate 'replace_applied'
        'CODESTRIKE_ACCEPTANCE_PER_FILE_REPLACE=passed'
        if (-not $navigationPassed) { throw 'The workspace search hit did not place the caret at the exact UTF-8 byte column in other.rs.' }
    } elseif ($Scenario -eq 'WorkspaceReplace') {
        $first = Join-Path $fixture 'one.rs'
        $second = Join-Path $fixture 'two.rs'
        $ignored = Join-Path $fixture 'ignored.rs'
        $unsupported = Join-Path $fixture 'unsupported.rs'
        $readOnly = Join-Path $fixture 'read_only.rs'
        $needle = 'codestrike_workspace_needle'
        $replacement = 'codestrike_workspace_replaced'
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $firstOriginal = [byte[]]([byte[]]@(0xef, 0xbb, 0xbf) + $utf8.GetBytes("let café = $needle;" + [char]13 + [char]10))
        $secondOriginal = $utf8.GetBytes("let α = $needle;" + [char]10)
        $firstApplied = [byte[]]([byte[]]@(0xef, 0xbb, 0xbf) + $utf8.GetBytes("let café = $replacement;" + [char]13 + [char]10))
        $secondApplied = $utf8.GetBytes("let α = $replacement;" + [char]10)
        $unsupportedOriginal = [byte[]]([byte[]]@(0xff) + $utf8.GetBytes($needle))
        [System.IO.File]::WriteAllBytes($first, $firstOriginal)
        [System.IO.File]::WriteAllBytes($second, $secondOriginal)
        [System.IO.File]::WriteAllText((Join-Path $fixture '.gitignore'), 'ignored.rs')
        [System.IO.File]::WriteAllText($ignored, $needle)
        [System.IO.File]::WriteAllBytes($unsupported, $unsupportedOriginal)
        [System.IO.File]::WriteAllText($readOnly, $needle)
        [System.IO.File]::SetAttributes($readOnly, [System.IO.FileAttributes]::ReadOnly)
        $editor = Start-Candidate @($fixture, $first)
        Click-Editor $editor
        [System.Windows.Forms.SendKeys]::SendWait('^+f')
        [System.Windows.Forms.SendKeys]::SendWait($needle)
        Start-Sleep -Seconds 2
        Click-WindowOffset $editor 360 330
        Start-Sleep -Seconds 1
        Capture-Candidate 'workspace_replace_open'
        # Opening the disclosure requests native focus for Replace. The
        # subsequent exact-byte Apply assertion also proves that this input,
        # rather than the search query, received the replacement string.
        [System.Windows.Forms.SendKeys]::SendWait($replacement)
        Capture-Candidate 'workspace_replace_ready'
        # Captures are resized to 960 px from the runner's 1024 px screen;
        # the button row at capture y=393 is window y=419, not y=400.
        Click-WindowOffset $editor 330 420
        Start-Sleep -Seconds 2
        Capture-Candidate 'workspace_replace_preview'
        if (-not (Wait-FileBytes $first $firstOriginal) -or -not (Wait-FileBytes $second $secondOriginal)) {
            throw 'Preview changed a file before explicit Apply.'
        }
        $external = $utf8.GetBytes("external $needle" + [char]10)
        [System.IO.File]::WriteAllBytes($second, $external)
        Click-WindowOffset $editor 430 420
        Start-Sleep -Seconds 1
        if (-not (Wait-FileBytes $first $firstOriginal) -or -not (Wait-FileBytes $second $external)) {
            throw 'Apply overwrote a file changed after preview.'
        }
        Capture-Candidate 'workspace_replace_apply_conflict'
        [System.IO.File]::WriteAllBytes($second, $secondOriginal)
        Click-WindowOffset $editor 330 420
        Start-Sleep -Seconds 1
        Click-WindowOffset $editor 430 420
        if (-not (Wait-FileBytes $first $firstApplied) -or -not (Wait-FileBytes $second $secondApplied)) {
            Capture-Candidate 'workspace_replace_apply_failure'
            throw 'Explicit Apply did not replace both supported files while preserving BOM and newlines.'
        }
        if ([System.IO.File]::ReadAllText($ignored) -cne $needle -or
            [System.IO.File]::ReadAllText($readOnly) -cne $needle -or
            -not (Wait-FileBytes $unsupported $unsupportedOriginal)) {
            throw 'Ignored, read-only or unsupported file changed during workspace replacement.'
        }
        Capture-Candidate 'workspace_replace_applied'
        $newer = $utf8.GetBytes("newer user edit" + [char]10)
        [System.IO.File]::WriteAllBytes($first, $newer)
        Click-WindowOffset $editor 530 420
        Start-Sleep -Seconds 1
        if (-not (Wait-FileBytes $first $newer) -or -not (Wait-FileBytes $second $secondApplied)) {
            throw 'Checked Undo overwrote a newer edit.'
        }
        Capture-Candidate 'workspace_replace_undo_conflict'
        [System.IO.File]::WriteAllBytes($first, $firstApplied)
        Click-WindowOffset $editor 530 420
        if (-not (Wait-FileBytes $first $firstOriginal) -or -not (Wait-FileBytes $second $secondOriginal)) {
            Capture-Candidate 'workspace_replace_undo_failure'
            throw 'Checked Undo did not restore both original files.'
        }
        Capture-Candidate 'workspace_replace_undone'
        'CODESTRIKE_ACCEPTANCE_WORKSPACE_REPLACE=preview-conflict-apply-undo-passed'
    } elseif ($Scenario -eq 'Encoding') {
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $supported = @(
            @{ Name = 'utf8_lf'; Text = "let π = 1;`n"; Preamble = [byte[]]@() },
            @{ Name = 'bom_crlf'; Text = "let café = 1;`r`n"; Preamble = [byte[]]@(0xef, 0xbb, 0xbf) }
        )
        foreach ($case in $supported) {
            $path = Join-Path $fixture ($case.Name + '.txt')
            $expected = [byte[]]($case.Preamble + $utf8.GetBytes($case.Text))
            [System.IO.File]::WriteAllBytes($path, $expected)
            foreach ($round in 1..2) {
                $editor = Start-Candidate @($fixture, $path)
                Click-Editor $editor
                [System.Windows.Forms.SendKeys]::SendWait('^{END}')
                $marker = "codestrike_$($case.Name)_$round"
                [System.Windows.Forms.SendKeys]::SendWait($marker)
                [System.Windows.Forms.SendKeys]::SendWait('^s')
                $expected = [byte[]]($expected + [System.Text.Encoding]::ASCII.GetBytes($marker))
                if (-not (Wait-FileBytes $path $expected)) {
                    Capture-Candidate "encoding_$($case.Name)_failure"
                    throw "Saving $($case.Name) round $round changed its original UTF-8/BOM/newline bytes or missed the selected file."
                }
                if ($round -eq 2) { Capture-Candidate "encoding_$($case.Name)_reopened" }
                Close-Candidate $editor
                $editor = $null
            }
            "CODESTRIKE_ACCEPTANCE_ENCODING=$($case.Name);saved-and-reopened"
        }

        $unsupported = @(
            @{ Name = 'latin1'; Bytes = [byte[]]@(0x63, 0x61, 0x66, 0xe9, 0x0d, 0x0a) },
            @{ Name = 'utf16'; Bytes = [byte[]]@(0xff, 0xfe, 0x41, 0x00, 0x0d, 0x00) },
            @{ Name = 'binary'; Bytes = [byte[]]@(0x61, 0x62, 0x00, 0x63) }
        )
        foreach ($case in $unsupported) {
            $path = Join-Path $fixture ($case.Name + '.txt')
            [System.IO.File]::WriteAllBytes($path, $case.Bytes)
            $editor = Start-Candidate @($fixture, $path)
            Click-Editor $editor
            [System.Windows.Forms.SendKeys]::SendWait('^{END}')
            [System.Windows.Forms.SendKeys]::SendWait('codestrike_must_not_write')
            [System.Windows.Forms.SendKeys]::SendWait('^s')
            Start-Sleep -Seconds 1
            if (-not (Wait-FileBytes $path $case.Bytes)) {
                Capture-Candidate "encoding_$($case.Name)_failure"
                throw "Unsupported $($case.Name) bytes were overwritten."
            }
            if ($case.Name -eq 'utf16') { Capture-Candidate 'encoding_unsupported_read_only' }
            Close-Candidate $editor
            $editor = $null
            "CODESTRIKE_ACCEPTANCE_ENCODING=$($case.Name);bytes-preserved"
        }
    } elseif ($Scenario -eq 'CleanReload') {
        $path = Join-Path $fixture 'clean_reload.rs'
        [System.IO.File]::WriteAllText($path, "// original`n")
        $editor = Start-Candidate @($fixture, $path)
        Start-Sleep -Seconds 2
        $external = "// external_version`n"
        [System.IO.File]::WriteAllText($path, $external)
        Start-Sleep -Seconds 8
        Capture-Candidate 'clean_reload_external'
        Click-Editor $editor
        [System.Windows.Forms.SendKeys]::SendWait('^{END}')
        [System.Windows.Forms.SendKeys]::SendWait('// local_after_reload')
        [System.Windows.Forms.SendKeys]::SendWait('^s')
        $expected = [System.Text.Encoding]::UTF8.GetBytes($external + '// local_after_reload')
        if (-not (Wait-FileBytes $path $expected)) {
            Capture-Candidate 'clean_reload_save_failure'
            $logRoots = @(
                $localData,
                (Join-Path $env:LOCALAPPDATA 'ArtCraft\CodeStrike'),
                (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ArtCraft\CodeStrike')
            ) | Select-Object -Unique
            $logs = @($logRoots | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
                Get-ChildItem -LiteralPath $_ -Recurse -File -Filter 'lapce*.log' -ErrorAction SilentlyContinue
            })
            "CODESTRIKE_CLEAN_RELOAD_LOG_COUNT=$($logs.Count)"
            foreach ($log in $logs) {
                "CODESTRIKE_CLEAN_RELOAD_LOG=$($log.FullName)"
                Get-Content -LiteralPath $log.FullName | Select-String -Pattern 'CodeStrike watcher|open_file_changed|Clean file reload|Failed to re-read' | Select-Object -Last 60 | ForEach-Object { $_.Line.Substring(0, [Math]::Min($_.Line.Length, 350)) }
            }
            throw 'Save after a clean external reload did not preserve the new disk text and local edit.'
        }
        Capture-Candidate 'clean_reload_saved'
        'CODESTRIKE_ACCEPTANCE_CLEAN_RELOAD=external-reload-and-save-passed'
    } elseif ($Scenario -eq 'Conflict') {
        $path = Join-Path $fixture 'conflict.rs'
        [System.IO.File]::WriteAllText($path, "// original`n")
        $editor = Start-Candidate @($fixture, $path)
        Click-Editor $editor
        [System.Windows.Forms.SendKeys]::SendWait('^{END}')
        [System.Windows.Forms.SendKeys]::SendWait('codestrike_local_unsaved')
        Start-Sleep -Milliseconds 500
        $external = "// external_wins`n"
        [System.IO.File]::WriteAllText($path, $external)
        Start-Sleep -Seconds 1
        Focus-Candidate $editor
        [System.Windows.Forms.SendKeys]::SendWait('^s')
        Start-Sleep -Seconds 2
        if ([System.IO.File]::ReadAllText($path) -cne $external) {
            throw 'GUI save overwrote an external change.'
        }
        Capture-Candidate 'conflict'
        'CODESTRIKE_ACCEPTANCE_GUI_CONFLICT=external-bytes-preserved'
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
