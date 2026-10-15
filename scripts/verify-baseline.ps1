param(
    [string]$Manifest = (Join-Path $PSScriptRoot '..\docs\migration\BASELINE.sha256')
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$failures = @()

foreach ($line in Get-Content -LiteralPath $Manifest) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
    $parts = $line -split "`t", 2
    if ($parts.Count -ne 2 -or $parts[0] -notmatch '^[0-9a-f]{64}$') {
        throw "Invalid manifest line: $line"
    }
    $path = Join-Path $repoRoot ($parts[1].Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures += "Missing: $($parts[1])"
        continue
    }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $parts[0]) { $failures += "Changed: $($parts[1])" }
}

if ($failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
Write-Output 'Original CodeStrike tracked files match the migration baseline.'
