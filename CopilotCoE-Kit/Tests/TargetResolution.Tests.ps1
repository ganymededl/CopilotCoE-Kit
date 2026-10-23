# Offline tests: Windows PowerShell / installed Pester 3; deployment uses PowerShell 7.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "New-CoETestFixture.ps1")
$kitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $kitRoot "Internal\TargetResolution.ps1")

Describe "Sign-in arguments for 03 and 04" {
    It "keeps device-code sign-in as the default so existing runs behave the same" {
        $arguments = Get-CoESignInArguments -Url "https://t-admin.sharepoint.com/" -ClientId "id" -Tenant "t.onmicrosoft.com"
        $arguments.DeviceLogin | Should Be $true
        $arguments.ContainsKey("Interactive") | Should Be $false
        $arguments.ContainsKey("ForceAuthentication") | Should Be $false
        $arguments.PersistLogin | Should Be $true
        $arguments.ReturnConnection | Should Be $true
        $arguments.ErrorAction | Should Be "Stop"
    }
    It "supports interactive sign-in for tenants that block device-code flow" {
        $arguments = Get-CoESignInArguments -Url "u" -ClientId "id" -Tenant "t" -AuthenticationMode Interactive
        $arguments.Interactive | Should Be $true
        $arguments.ContainsKey("DeviceLogin") | Should Be $false
    }
    It "adds a fresh sign-in only for interactive mode" {
        (Get-CoESignInArguments -Url "u" -ClientId "id" -Tenant "t" -AuthenticationMode Interactive -ForceAuthentication).ForceAuthentication |
            Should Be $true
        Get-CoETestExceptionMessage { Get-CoESignInArguments -Url "u" -ClientId "id" -Tenant "t" -ForceAuthentication } |
            Should Match "requires -AuthenticationMode Interactive"
    }
    It "rejects an unknown mode" {
        { Get-CoESignInArguments -Url "u" -ClientId "id" -Tenant "t" -AuthenticationMode Certificate } | Should Throw
    }
    It "tells a device-code user how to recover when Conditional Access blocks the flow" {
        Get-CoESignInHint "DeviceLogin" | Should Match "AuthenticationMode Interactive"
        Get-CoESignInHint "Interactive" | Should Not Match "device"
    }
}

Describe "Update and remove entry points expose and forward the sign-in options" {
    BeforeEach {
        $script:update = Get-Content -LiteralPath (Join-Path $kitRoot "03_Update-CoEContent.ps1") -Raw
        $script:remove = Get-Content -LiteralPath (Join-Path $kitRoot "04_Remove-CopilotCoE.ps1") -Raw
        $script:complete = Get-Content -LiteralPath (Join-Path $kitRoot "Internal\Complete-CopilotCoE.ps1") -Raw
    }
    It "03 accepts the options, validates them early and forwards them" {
        $update | Should Match '\[string\]\$AuthenticationMode = "DeviceLogin"'
        $update | Should Match '\[switch\]\$ForceAuthentication'
        $update | Should Match '\[string\]\$SiteUrl'
        $update | Should Match 'AuthenticationMode\s+=\s+\$AuthenticationMode'
        $update | Should Match 'ForceAuthentication\s+=\s+\[bool\]\$ForceAuthentication'
        $update.IndexOf('-ForceAuthentication requires') | Should BeLessThan $update.IndexOf('Get-Content -LiteralPath $SettingsPath')
    }
    It "04 accepts the options and no longer hard-codes device-code sign-in" {
        $remove | Should Match '\[string\]\$AuthenticationMode = "DeviceLogin"'
        $remove | Should Match 'Get-CoESignInArguments'
        $remove | Should Not Match 'Connect-PnPOnline\s+-Url[^\r\n]*-DeviceLogin'
    }
    It "the completion helper uses the shared arguments instead of a hard-coded device login" {
        $complete | Should Match 'Get-CoESignInArguments'
        $complete | Should Not Match 'Connect-PnPOnline\s+-Url\s+\$AdminUrl\s+-DeviceLogin'
    }
    It "03 no longer assumes the /sites/ managed path" {
        $update | Should Not Match '"https://\$\(\$s\.SiteFQDN\)/sites/'
        $update | Should Match 'Resolve-CoESiteUrl'
    }
}

Describe "Which SharePoint address an update targets" {
    BeforeEach {
        $script:report = Join-Path $TestDrive "CoE-Revision-Report.json"
        if (Test-Path -LiteralPath $report) { Remove-Item -LiteralPath $report }
    }
    It "accepts a /sites/ or /teams/ address on the configured host for the same alias" {
        foreach ($url in @("https://tenant.sharepoint.com/sites/CoE", "https://TENANT.sharepoint.com/teams/coe", "https://tenant.sharepoint.com/sites/CoE/")) {
            Test-CoESiteUrlForTarget -Url $url -SiteFqdn "tenant.sharepoint.com" -Alias "CoE" | Should Be $true
        }
    }
    It "rejects another host, alias, scheme, query, fragment, port, credentials or path shape" {
        foreach ($url in @("https://other.sharepoint.com/sites/CoE", "https://tenant.sharepoint.com/sites/Other", "http://tenant.sharepoint.com/sites/CoE",
                "https://tenant.sharepoint.com/sites/CoE?x=1", "https://tenant.sharepoint.com/sites/CoE#f", "https://tenant.sharepoint.com:8443/sites/CoE",
                "https://user@tenant.sharepoint.com/sites/CoE", "https://tenant.sharepoint.com/CoE", "https://tenant.sharepoint.com/sites/a/CoE",
                "https://tenant.sharepoint.com/", "", "not a url")) {
            Test-CoESiteUrlForTarget -Url $url -SiteFqdn "tenant.sharepoint.com" -Alias "CoE" | Should Be $false
        }
    }
    It "defaults to /sites/ when there is no report and no override" {
        $result = Resolve-CoESiteUrl -SiteFqdn "Tenant.SharePoint.com" -Alias "CoE" -ReportPath $report
        $result.Url | Should Be "https://tenant.sharepoint.com/sites/CoE"
        $result.Source | Should Match "default"
    }
    It "reads a /teams/ site from the deployment report instead of assuming /sites/" {
        [IO.File]::WriteAllText($report, '{"Site":"https://tenant.sharepoint.com/teams/CoE/"}')
        $result = Resolve-CoESiteUrl -SiteFqdn "tenant.sharepoint.com" -Alias "CoE" -ReportPath $report
        $result.Url | Should Be "https://tenant.sharepoint.com/teams/CoE"
        $result.Source | Should Be "deployment report"
    }
    It "stops instead of guessing when a report names a different alias or host" {
        [IO.File]::WriteAllText($report, '{"Site":"https://tenant.sharepoint.com/teams/OldAlias"}')
        Get-CoETestExceptionMessage {
            Resolve-CoESiteUrl -SiteFqdn "tenant.sharepoint.com" -Alias "CoE" -ReportPath $report
        } | Should Match "not https://tenant.sharepoint.com/<managed path>/CoE"
        [IO.File]::WriteAllText($report, '{"Site":"https://elsewhere.sharepoint.com/sites/CoE"}')
        Get-CoETestExceptionMessage {
            Resolve-CoESiteUrl -SiteFqdn "tenant.sharepoint.com" -Alias "CoE" -ReportPath $report
        } | Should Match "Do not fall back"
    }
    It "stops when a report has no usable Site value" {
        [IO.File]::WriteAllText($report, '{"Version":"3.8"}')
        Get-CoETestExceptionMessage {
            Resolve-CoESiteUrl -SiteFqdn "tenant.sharepoint.com" -Alias "CoE" -ReportPath $report
        } | Should Match "no usable Site value"
        [IO.File]::WriteAllText($report, '{"Site":42}')
        Get-CoETestExceptionMessage {
            Resolve-CoESiteUrl -SiteFqdn "tenant.sharepoint.com" -Alias "CoE" -ReportPath $report
        } | Should Match "no usable Site value"
    }
    It "stops with recovery guidance when the report is malformed" {
        [IO.File]::WriteAllText($report, '{"Site":')
        Get-CoETestExceptionMessage {
            Resolve-CoESiteUrl -SiteFqdn "tenant.sharepoint.com" -Alias "CoE" -ReportPath $report
        } | Should Match "not valid JSON.*-SiteUrl"
    }
    It "lets an explicit -SiteUrl win over the report and validates it" {
        [IO.File]::WriteAllText($report, '{"Site":"https://tenant.sharepoint.com/sites/CoE"}')
        $result = Resolve-CoESiteUrl -SiteFqdn "tenant.sharepoint.com" -Alias "CoE" -ReportPath $report `
            -ExplicitSiteUrl "https://tenant.sharepoint.com/teams/CoE"
        $result.Url | Should Be "https://tenant.sharepoint.com/teams/CoE"
        Get-CoETestExceptionMessage {
            Resolve-CoESiteUrl -SiteFqdn "tenant.sharepoint.com" -Alias "CoE" -ExplicitSiteUrl "https://other.sharepoint.com/sites/CoE"
        } | Should Match "must be https://tenant.sharepoint.com/"
    }
}

Describe "Matching a SharePoint time zone when names are localized" {
    BeforeEach {
        $script:german = [TimeZoneInfo]::CreateCustomTimeZone("TestZone", [TimeSpan]::FromHours(-6),
            "(UTC-06:00) Zentrale Zeit (USA und Kanada)", "Zentrale Normalzeit")
    }
    It "matches the machine's own display name despite punctuation and ampersands" {
        $zone = [TimeZoneInfo]::CreateCustomTimeZone("T1", [TimeSpan]::FromHours(-6), "(UTC-06:00) Central Time (US & Canada)", "std")
        $candidates = @([pscustomobject]@{ Id = 11; Description = "(UTC-06:00) Central Time (US and Canada)" })
        (Find-CoESharePointTimeZone -TimeZone $zone -Candidates $candidates).Id | Should Be 11
    }
    It "falls back to the English name when the machine name is localized" {
        $candidates = @([pscustomobject]@{ Id = 11; Description = "(UTC-06:00) Central Time (US & Canada)" })
        (Find-CoESharePointTimeZone -TimeZone $german -Candidates $candidates -EnglishName "(UTC-06:00) Central Time (US & Canada)").Id | Should Be 11
    }
    It "matches a site whose zone names are in the machine's language, including accented letters" {
        $candidates = @([pscustomobject]@{ Id = 7; Description = "(UTC-06:00) Zentrale Zeit (USA und Kanada)" })
        (Find-CoESharePointTimeZone -TimeZone $german -Candidates $candidates -EnglishName "(UTC-06:00) Central Time (US & Canada)").Id | Should Be 7
        $accented = [TimeZoneInfo]::CreateCustomTimeZone("T2", [TimeSpan]::FromHours(1), "(UTC+01:00) Mitteleuropäische Zeit", "std")
        (Find-CoESharePointTimeZone -TimeZone $accented -Candidates @([pscustomobject]@{ Id = 3; Description = "(UTC+01:00) Mitteleuropäische Zeit" })).Id | Should Be 3
    }
    It "never guesses from the UTC offset alone" {
        $candidates = @(
            [pscustomobject]@{ Id = 1; Description = "(UTC-06:00) Mexico City" },
            [pscustomobject]@{ Id = 2; Description = "(UTC-06:00) Saskatchewan" })
        $null -eq (Find-CoESharePointTimeZone -TimeZone $german -Candidates $candidates -EnglishName "(UTC-06:00) Central Time (US & Canada)") | Should Be $true
    }
    It "returns nothing for an empty list" {
        $null -eq (Find-CoESharePointTimeZone -TimeZone $german -Candidates @()) | Should Be $true
    }
    It "reads the English name without leaving the UI culture changed" {
        $before = [System.Globalization.CultureInfo]::CurrentUICulture.Name
        (Get-CoEEnglishTimeZoneName "Eastern Standard Time") | Should Not BeNullOrEmpty
        [System.Globalization.CultureInfo]::CurrentUICulture.Name | Should Be $before
        (Get-CoEEnglishTimeZoneName "No Such Zone") | Should BeNullOrEmpty
    }
    It "warns and leaves the site unchanged instead of stopping an install on a no-match" {
        $source = Get-Content -LiteralPath (Join-Path $kitRoot "Internal\Complete-CopilotCoE.ps1") -Raw
        $source | Should Not Match 'throw "No SharePoint time zone matches'
        $source | Should Match 'The site time zone was NOT changed'
    }
}

Describe "Language-independent SharePoint identifiers" {
    It "addresses the Site Page content type by ID and the pages library by URL" {
        $install = Get-Content -LiteralPath (Join-Path $kitRoot "02_Install-CopilotCoE.ps1") -Raw
        $complete = Get-Content -LiteralPath (Join-Path $kitRoot "Internal\Complete-CopilotCoE.ps1") -Raw
        $install | Should Match '0x0101009D1CB255DA76424F860D91F20E6C4118'
        $install | Should Not Match '-Identity "Site Page"'
        $install | Should Not Match '-ContentType "Site Page"'
        $complete | Should Not Match '-List "Site Pages"'
        $complete | Should Match '-List "SitePages"'
    }
}

Describe "Updates are bound to the Team recorded in the deployment report" {
    $teamA = "11111111-1111-1111-1111-111111111111"
    $teamB = "22222222-2222-2222-2222-222222222222"
    It "accepts the same Team ID from a hashtable report" {
        { Assert-CoEDeploymentTeamBinding -Report @{ Site = "https://t.sharepoint.com/sites/CoE"; TeamId = $teamA } -TeamId $teamA -Alias "CoE" } |
            Should Not Throw
    }
    It "accepts the same Team ID from an object report regardless of case" {
        { Assert-CoEDeploymentTeamBinding -Report ([pscustomobject]@{ TeamId = $teamA.ToUpperInvariant() }) -TeamId $teamA -Alias "CoE" } |
            Should Not Throw
    }
    It "refuses a different Team ID before anything is changed" {
        $message = Get-CoETestExceptionMessage {
            Assert-CoEDeploymentTeamBinding -Report @{ TeamId = $teamA } -TeamId $teamB -Alias "CoE"
        }
        $message | Should Match "written for Team $teamA"
        $message | Should Match "resolves to Team $teamB"
        $message | Should Match "Nothing was changed"
    }
    It "warns but continues for an older report without TeamId" {
        Mock Write-Warning {}
        { Assert-CoEDeploymentTeamBinding -Report @{ Site = "https://t.sharepoint.com/sites/CoE" } -TeamId $teamA -Alias "CoE" } |
            Should Not Throw
        Assert-MockCalled Write-Warning -Times 1 -Exactly -Scope It -ParameterFilter { $Message -match "no TeamId" }
    }
    It "does nothing when there is no report" {
        Mock Write-Warning {}
        { Assert-CoEDeploymentTeamBinding -Report $null -TeamId $teamA -Alias "CoE" } | Should Not Throw
        Assert-MockCalled Write-Warning -Times 0 -Exactly -Scope It
    }
}

Describe "Completion verifies the target Team before any tenant write" {
    $complete = Get-Content -LiteralPath (Join-Path $kitRoot "Internal\Complete-CopilotCoE.ps1") -Raw
    $install = Get-Content -LiteralPath (Join-Path $kitRoot "02_Install-CopilotCoE.ps1") -Raw
    $update = Get-Content -LiteralPath (Join-Path $kitRoot "03_Update-CoEContent.ps1") -Raw
    $groupCheck = $complete.IndexOf('$group = Get-PnPMicrosoft365Group -Identity $TeamAlias')
    $binding = $complete.IndexOf('Assert-CoEDeploymentTeamBinding -Report $priorReportForSite')
    It "looks up the Team once and binds it before reviewers, time zone or pages are touched" {
        $groupCheck | Should BeGreaterThan -1
        ([regex]::Matches($complete, [regex]::Escape('$group = Get-PnPMicrosoft365Group -Identity $TeamAlias'))).Count | Should Be 1
        $binding | Should BeGreaterThan $groupCheck
        $binding | Should BeLessThan $complete.IndexOf('Resolve-CoECatalogReviewers -ReviewerUPNs $catalogReviewers')
        $binding | Should BeLessThan $complete.IndexOf('Set-SiteTimeZone -SiteConnection $site')
        $binding | Should BeLessThan $complete.IndexOf('Initialize-CoEGovernanceSecurity')
    }
    It "skips the report binding only for the installer, which created or resumed the Team itself" {
        $install | Should Match '-ContentMode \$ContentMode -NewDeployment'
        $update | Should Not Match 'NewDeployment'
    }
}

Describe "Live regression only writes to a dedicated scratch site" {
    $fqdn = "contoso.sharepoint.com"
    It "accepts a scratch alias on the configured host under any one managed path" {
        Test-CoEScratchSiteUrl -Url "https://contoso.sharepoint.com/sites/CoEScratch1" -SiteFqdn $fqdn -ProtectedAlias "CopilotCoE" | Should Be $true
        Test-CoEScratchSiteUrl -Url "https://contoso.sharepoint.com/teams/coe-scratch-a/" -SiteFqdn $fqdn | Should Be $true
    }
    foreach ($case in @(
            @{ Name = "a production site that merely contains Scratch"; Url = "https://contoso.sharepoint.com/sites/FinanceScratchpad" },
            @{ Name = "Scratch only in the query string"; Url = "https://contoso.sharepoint.com/sites/CopilotCoE?x=Scratch" },
            @{ Name = "Scratch only in the fragment"; Url = "https://contoso.sharepoint.com/sites/CopilotCoE#CoEScratch" },
            @{ Name = "another tenant host"; Url = "https://fabrikam.sharepoint.com/sites/CoEScratch1" },
            @{ Name = "a subsite below a scratch site"; Url = "https://contoso.sharepoint.com/sites/CoEScratch1/Finance" },
            @{ Name = "a non-HTTPS address"; Url = "http://contoso.sharepoint.com/sites/CoEScratch1" },
            @{ Name = "embedded credentials"; Url = "https://user@contoso.sharepoint.com/sites/CoEScratch1" },
            @{ Name = "the root site"; Url = "https://contoso.sharepoint.com/" },
            @{ Name = "an empty address"; Url = "" }
        )) {
        It "refuses $($case.Name)" {
            Test-CoEScratchSiteUrl -Url $case.Url -SiteFqdn $fqdn -ProtectedAlias "CopilotCoE" | Should Be $false
        }
    }
    It "refuses the organization's own configured alias even if it looks like a scratch name" {
        Test-CoEScratchSiteUrl -Url "https://contoso.sharepoint.com/sites/CoEScratch1" -SiteFqdn $fqdn -ProtectedAlias "coescratch1" | Should Be $false
    }
    It "checks the guard before signing in or writing anything" {
        $live = Get-Content -LiteralPath (Join-Path $kitRoot "Test-CoELiveRegression.ps1") -Raw
        $guard = $live.IndexOf("Test-CoEScratchSiteUrl -Url")
        $guard | Should BeGreaterThan -1
        $guard | Should BeLessThan $live.IndexOf("Connect-PnPOnline")
        $guard | Should BeLessThan $live.IndexOf("New-PnPList")
        $live | Should Not Match "-notmatch 'Scratch'"
    }
    It "states R5 as a synchronizer rerun check, not a full-run idempotency test" {
        $live = Get-Content -LiteralPath (Join-Path $kitRoot "Test-CoELiveRegression.ps1") -Raw
        $live | Should Not Match "A second full run must change nothing"
        $live | Should Match "Get-CoECatalogSnapshot"
        $live | Should Match 'Compare-Object -ReferenceObject \$before -DifferenceObject \$after'
    }
}
