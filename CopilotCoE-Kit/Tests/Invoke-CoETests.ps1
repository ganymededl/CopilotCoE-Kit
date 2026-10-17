<#
.SYNOPSIS
One-command gate for the kit's offline Pester suites. Exits 1 if any suite fails or does not finish.

.DESCRIPTION
Each suite runs in its own Windows PowerShell 5.1 process with Pester 3.4, because the suites define script-scope
fakes for the same SharePoint commands and leak into each other when they share one process.

These suites replace SharePoint with simulated responses, so a pass proves the kit's own logic only. A build is
accepted after one clean 02_Install and a passing Test-CoEInstall.ps1 on the live site, not after this gate alone.

    .\Tests\Invoke-CoETests.ps1                              # every suite
    .\Tests\Invoke-CoETests.ps1 -Suite AdoptionCatalogs      # one suite
#>
[CmdletBinding()]
param([string[]]$Suite)

$ErrorActionPreference = "Stop"
$files = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*.Tests.ps1" -File | Sort-Object Name)
if ($Suite) { $files = @($files | Where-Object { ($_.Name -replace '\.Tests\.ps1$', '') -in $Suite }) }
if (-not $files.Count) { throw "No test suites found." }
$windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $windowsPowerShell)) { throw "Windows PowerShell 5.1 was not found: $windowsPowerShell" }

$rows = foreach ($file in $files) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $command = "Import-Module Pester -RequiredVersion 3.4.0; `$r = Invoke-Pester -Path '$($file.FullName)' -PassThru -Quiet; " +
        "'RESULT|{0}|{1}|{2}' -f `$r.PassedCount, `$r.FailedCount, `$r.TotalCount"
    $output = @(& $windowsPowerShell -NoProfile -NonInteractive -Command $command 2>&1 | ForEach-Object { "$_" })
    $result = @($output | Where-Object { $_ -like "RESULT|*" }) | Select-Object -Last 1
    $name = $file.Name -replace '\.Tests\.ps1$', ''
    if ($result) {
        $parts = $result.Split("|")
        [pscustomobject]@{ Suite = $name; Passed = [int]$parts[1]; Failed = [int]$parts[2]; Total = [int]$parts[3]
            Seconds = [math]::Round($clock.Elapsed.TotalSeconds); Note = "" }
    } else {
        [pscustomobject]@{ Suite = $name; Passed = 0; Failed = 1; Total = 0; Seconds = [math]::Round($clock.Elapsed.TotalSeconds)
            Note = "suite did not finish: " + ((@($output | Select-Object -Last 3)) -join " ") }
    }
}

$rows | Format-Table Suite, Passed, Failed, Total, Seconds, Note -AutoSize -Wrap
$passed = ($rows | Measure-Object Passed -Sum).Sum
$failed = ($rows | Measure-Object Failed -Sum).Sum
Write-Host ("{0} passed, {1} failed across {2} suite(s)" -f $passed, $failed, $rows.Count)
if ($failed -gt 0) { exit 1 }
Write-Host "ALL OFFLINE SUITES PASSED"
