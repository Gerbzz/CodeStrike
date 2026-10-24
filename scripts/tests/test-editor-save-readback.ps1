$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../wait-editor-save.ps1')
Add-Type -TypeDefinition @'
using System.IO;
using System.Threading.Tasks;
public static class DelayedFixtureWrite {
    public static Task Start(string path, string content, int milliseconds) {
        return Task.Run(async () => { await Task.Delay(milliseconds); string temporary = path + ".delayed"; File.WriteAllText(temporary, content); File.Move(temporary, path, true); });
    }
}
'@
$root = Join-Path ([IO.Path]::GetTempPath()) ('codestrike-save-readback-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$path = Join-Path $root 'fixture.rs'
$marker = 'codestrike_ci_saved'
try {
    [IO.File]::WriteAllText($path, 'original')
    $writer = [DelayedFixtureWrite]::Start($path, "original`n$marker", 1000)
    $result = Wait-EditorSavedSource -Path $path -Marker $marker -TimeoutMilliseconds 5000
    $writer.Wait()
    if (-not $result.Source.Contains($marker) -or $result.Observations -lt 2) { throw 'Delayed save was not observed.' }
    if ($result.ElapsedMilliseconds -ge 5000) { throw 'Successful save consumed the timeout.' }

    [IO.File]::WriteAllText($path, 'original')
    $result = Wait-EditorSavedSource -Path $path -Marker $marker -TimeoutMilliseconds 300
    if ($result.Source -cne 'original' -or $result.ElapsedMilliseconds -lt 300) { throw 'Never-written timeout lost the original failure.' }

    [IO.File]::WriteAllText($path, 'wrong bytes; no saved marker')
    $before = [IO.File]::ReadAllBytes($path)
    $result = Wait-EditorSavedSource -Path $path -Marker $marker -TimeoutMilliseconds 300
    if ($result.Source.Contains($marker)) { throw 'Wrong saved content passed.' }
    if ([Convert]::ToHexString($before) -cne [Convert]::ToHexString([IO.File]::ReadAllBytes($path))) { throw 'Readback polling wrote source.' }
    $helper = Get-Content -Raw (Join-Path $PSScriptRoot '../wait-editor-save.ps1')
    if ($helper -match 'SendKeys|SendWait|WriteAll|Set-Content') { throw 'Readback helper injects input or writes source.' }
    'CODESTRIKE_SAVE_READBACK_TESTS=delayed-success,never-written-timeout,wrong-content,no-extra-input-passed'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
