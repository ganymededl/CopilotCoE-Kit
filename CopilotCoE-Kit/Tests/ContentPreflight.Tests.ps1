# Offline tests: Windows PowerShell / installed Pester 3; deployment uses PowerShell 7.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "New-CoETestFixture.ps1")
$kitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $kitRoot "Internal\ContentPreflight.ps1")

function Write-Calendar([string]$Path, [string]$Header, [string[]]$Rows) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllLines($Path, @($Header) + $Rows)
}

Describe "Structured organization content preflight" {
    BeforeEach {
        $script:org = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $script:calendar = Join-Path $org "Content\Training-Calendar.csv"
        $script:header = "Title,StartOffsetDays,StartTimeET,EndTimeET,Audience,Format,Description,SampleStatus,RegistrationUrl"
        $script:row = '"Session one",5,12:00,12:45,"Staff","Online","Description","DRAFT - DEMONSTRATION",'
    }
    It "does nothing when no organization calendar override exists" {
        { Assert-CoEStructuredOrganizationContent -OrgPath $org } | Should Not Throw
        { Assert-CoEStructuredOrganizationContent -OrgPath "" } | Should Not Throw
    }
    It "accepts the current offset schema before any tenant work" {
        Write-Calendar $calendar $header @($row)
        { Assert-CoEStructuredOrganizationContent -OrgPath $org } | Should Not Throw
    }
    It "rejects the obsolete fixed-date schema with pre-sign-in recovery guidance" {
        Write-Calendar $calendar "Title,StartDate,StartTimeET,EndDate,EndTimeET,Audience,Format,Description,SampleStatus,RegistrationUrl" @(
            '"Old session",2026-10-21,12:00,2026-10-21,12:45,"Staff","Online","Description","DRAFT - DEMONSTRATION",')
        Get-CoETestExceptionMessage { Assert-CoEStructuredOrganizationContent -OrgPath $org } |
            Should Match "obsolete fixed-date.*Before signing in.*StartOffsetDays"
    }
    It "rejects malformed offsets, times and duplicate titles locally" {
        Write-Calendar $calendar $header @($row, $row)
        Get-CoETestExceptionMessage { Assert-CoEStructuredOrganizationContent -OrgPath $org } | Should Match "duplicate Title"
        Write-Calendar $calendar $header @($row.Replace(",5,", ",tomorrow,"))
        Get-CoETestExceptionMessage { Assert-CoEStructuredOrganizationContent -OrgPath $org } | Should Match "invalid StartOffsetDays"
        Write-Calendar $calendar $header @($row.Replace(",12:45,", ",11:45,"))
        Get-CoETestExceptionMessage { Assert-CoEStructuredOrganizationContent -OrgPath $org } | Should Match "invalid same-day time range"
    }
    It "permits a next-day end time only with a valid EndOffsetDays column" {
        $headerWithEnd = "Title,StartOffsetDays,EndOffsetDays,StartTimeET,EndTimeET,Audience,Format,Description,SampleStatus,RegistrationUrl"
        $crossDay = '"Late session",5,6,23:30,00:30,"Staff","Online","Description","DRAFT - DEMONSTRATION",'
        Write-Calendar $calendar $headerWithEnd @($crossDay)
        { Assert-CoEStructuredOrganizationContent -OrgPath $org } | Should Not Throw
    }
}

Describe "Entry-point wiring" {
    It "runs 02 preflight before importing PnP or connecting" {
        $source = Get-Content -LiteralPath (Join-Path $kitRoot "02_Install-CopilotCoE.ps1") -Raw
        $call = $source.IndexOf("Assert-CoEStructuredOrganizationContent")
        $call | Should BeGreaterThan -1
        $call | Should BeLessThan $source.IndexOf("Import-Module PnP.PowerShell")
        $call | Should BeLessThan $source.IndexOf("Connect-PnPOnline")
    }
    It "runs 03 preflight before invoking the tenant-connected completion helper" {
        $source = Get-Content -LiteralPath (Join-Path $kitRoot "03_Update-CoEContent.ps1") -Raw
        $call = $source.IndexOf("Assert-CoEStructuredOrganizationContent")
        $call | Should BeGreaterThan -1
        $call | Should BeLessThan $source.IndexOf("& (Join-Path `$PSScriptRoot ""Internal\Complete-CopilotCoE.ps1"")")
    }
}
