# Exercise the exact native probe capture implementation, without starting an app.
$ErrorActionPreference = 'Stop'
$script = Get-Content -Raw (Join-Path $PSScriptRoot '../probe-rust-language-tools.ps1')
$match = [regex]::Match($script, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $match.Success) { throw 'Native capture implementation not found.' }
Add-Type -TypeDefinition $match.Groups[1].Value
$capture = [CodeStrikeLspWindow].GetMethod('Capture', [Reflection.BindingFlags]'NonPublic,Static')
function Add-Line([string]$line) { $capture.Invoke($null, @($line)) | Out-Null }
function Assert([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
$marker = 'CodeStrike completion row laid out'
$selected = 'selected_label="Read"'
Add-Line 'read from lsp: {"label":"Read"}'
Assert (-not [CodeStrikeLspWindow]::HasOutputLine($marker, $selected, 0)) 'LSP response alone authorized Enter.'
Add-Line "$marker selected_label=`"Ready`""
Assert (-not [CodeStrikeLspWindow]::HasOutputLine($marker, $selected, 0)) 'Wrong selected label authorized Enter.'
$escape = [char]27
$rendered = "$marker ${escape}[3mselected_label${escape}[0m=${escape}[0m`"Read`" width=200 height=20"
Add-Line $rendered
Assert ([CodeStrikeLspWindow]::HasOutputLine($marker, $selected, 0)) 'Real laid-out selected Read was not detected through ANSI fields.'
$boundary = [CodeStrikeLspWindow]::OutputCount()
Assert (-not [CodeStrikeLspWindow]::HasOutputLine($marker, $selected, $boundary)) 'Stale UI observation authorized a new request.'
Add-Line $rendered
Assert ([CodeStrikeLspWindow]::HasOutputLine($marker, $selected, $boundary)) 'Fresh UI observation was not detected.'
Assert ([CodeStrikeLspWindow]::CapturedOutput().Contains($rendered)) 'Raw trace was changed by readiness parsing.'
Add-Line ('x' * (16 * 1024 * 1024))
Assert ([CodeStrikeLspWindow]::Overflowed()) 'Trace bound did not fail closed.'
'CODESTRIKE_LSP_READINESS_CAPTURE_TESTS=7-passed'
