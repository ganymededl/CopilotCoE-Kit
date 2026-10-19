Set-StrictMode -Version Latest
$kitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $kitRoot "Internal\AdoptionCatalogs.ps1")
. (Join-Path $kitRoot "Internal\HubExperience.ps1")
. (Join-Path $kitRoot "Internal\OperatorAdvisories.ps1")
. (Join-Path $PSScriptRoot "New-CoETestFixture.ps1")

Describe "Context-bound Stop and Proceed decisions" {
    BeforeEach {
        $settingsFile = Join-Path $TestDrive "Deployment-Settings.json"
        [IO.File]::WriteAllText($settingsFile, "{}")
        $script:context = New-CoEAdvisoryContext -SettingsPath $settingsFile -Tenant "contoso.onmicrosoft.com" `
            -SiteFQDN "contoso.sharepoint.com" -TeamAlias "CopilotCoE"
        if (Test-Path -LiteralPath $context.Path) { Remove-Item -LiteralPath $context.Path }
        $script:advisory = @{ Context = $context; Id = "LabSupportMailbox"; Message = "Lab route"; Facts = @("admin@contoso.onmicrosoft.com") }
        Mock Read-Host { "PROCEED" }
        Mock Write-Host {}
        Mock Write-Warning {}
    }
    It "records Proceed and reuses it without a second prompt" {
        Confirm-CoEAdvisory @advisory
        Confirm-CoEAdvisory @advisory
        Assert-MockCalled Read-Host -Times 1 -Exactly -Scope It
        $saved = Get-Content -LiteralPath $context.Path -Raw | ConvertFrom-Json
        $saved.Decisions[0].Choice | Should Be "PROCEED"
        $saved.Decisions[0].Scope.Tenant | Should Be "contoso.onmicrosoft.com"
    }
    It "persists Stop and does not silently retry it" {
        Mock Read-Host { "STOP" }
        Get-CoETestExceptionMessage { Confirm-CoEAdvisory @advisory } | Should Match "Operator selected STOP"
        Get-CoETestExceptionMessage { Confirm-CoEAdvisory @advisory } | Should Match "Operator selected STOP"
        Assert-MockCalled Read-Host -Times 1 -Exactly -Scope It
    }
    It "defaults an empty answer to Stop" {
        Mock Read-Host { "" }
        Get-CoETestExceptionMessage { Confirm-CoEAdvisory @advisory } | Should Match "Operator selected STOP"
    }
    It "does not interpret an invalid response as approval" {
        Mock Read-Host { "yes" }
        Get-CoETestExceptionMessage { Confirm-CoEAdvisory @advisory } | Should Match "No valid Stop/Proceed"
        Test-Path -LiteralPath $context.Path | Should Be $false
    }
    It "requires a fresh decision for a different mailbox" {
        Confirm-CoEAdvisory @advisory
        $advisory.Facts = @("support@contoso.onmicrosoft.com")
        Confirm-CoEAdvisory @advisory
        Assert-MockCalled Read-Host -Times 2 -Exactly -Scope It
    }
    It "does not transfer choices between tenants sites aliases or advisory types" {
        Confirm-CoEAdvisory @advisory
        $context.Tenant = "another.onmicrosoft.com"
        Confirm-CoEAdvisory @advisory
        $context.SiteFQDN = "another.sharepoint.com"
        Confirm-CoEAdvisory @advisory
        $context.TeamAlias = "another"
        Confirm-CoEAdvisory @advisory
        $advisory.Id = "LongDisplayName"
        Confirm-CoEAdvisory @advisory
        Assert-MockCalled Read-Host -Times 5 -Exactly -Scope It
    }
    It "normalizes ordering so an unchanged roster does not prompt again" {
        $advisory.Id = "ParentTeamExternalMembers"
        $advisory.Facts = @("b@external.example", "a@external.example")
        Confirm-CoEAdvisory @advisory
        $advisory.Facts = @("a@external.example", "b@external.example")
        Confirm-CoEAdvisory @advisory
        Assert-MockCalled Read-Host -Times 1 -Exactly -Scope It
    }
    It "does not record decisions or prompt under WhatIf" {
        $WhatIfPreference = $true
        Confirm-CoEAdvisory @advisory
        Test-Path -LiteralPath $context.Path | Should Be $false
        Assert-MockCalled Read-Host -Times 0 -Exactly -Scope It
    }
    It "fails closed on an invalid decision document" {
        '{"SchemaVersion":9,"Decisions":[]}' | Set-Content -LiteralPath $context.Path
        Get-CoETestExceptionMessage { Confirm-CoEAdvisory @advisory } | Should Match "Invalid advisory decision file"
    }
    It "reuses a mailbox choice across independent install and completion contexts" {
        $settings = [pscustomobject]@{ Links = [pscustomobject]@{
            ServiceDesk = "https://support.example.org/"; TechnologyRequest = "https://support.example.org/request"
            AIGuidelines = "https://policy.example.org/"; DataSafetyIncident = "https://incident.example.org/"
        } }
        $call = @{ Settings = $settings; SupportEmail = "admin@contoso.onmicrosoft.com"
            DisplayName = "Contoso CoE"; SampleNotice = ""; ContentMode = "Customer" }
        Invoke-CoEConfigurationAdvisories @call -Context $context
        $completionContext = New-CoEAdvisoryContext -SettingsPath $settingsFile -Tenant "CONTOSO.onmicrosoft.com" `
            -SiteFQDN "CONTOSO.sharepoint.com" -TeamAlias "COPILOTCOE"
        Invoke-CoEConfigurationAdvisories @call -Context $completionContext
        Assert-MockCalled Read-Host -Times 1 -Exactly -Scope It
        $settings.Links.DataSafetyIncident = "http://unsafe.example.org/"
        Get-CoETestExceptionMessage { Invoke-CoEConfigurationAdvisories @call -Context $completionContext } |
            Should Match 'Links.DataSafetyIncident'
    }
    It "propagates decision write failures instead of approving the run" {
        Mock Set-Content { throw "write denied" }
        Get-CoETestExceptionMessage { Confirm-CoEAdvisory @advisory } | Should Match "write denied"
    }
}

Describe "Read-only lab mailbox acceptance review" {
    BeforeEach {
        $settingsFile = Join-Path $TestDrive "mailbox-settings.json"
        [IO.File]::WriteAllText($settingsFile, "{}")
        $script:context = New-CoEAdvisoryContext -SettingsPath $settingsFile -Tenant "contoso.onmicrosoft.com" `
            -SiteFQDN "contoso.sharepoint.com" -TeamAlias "CopilotCoE"
        if (Test-Path -LiteralPath $context.Path) { Remove-Item -LiteralPath $context.Path }
        Mock Read-Host { throw "Read-only review must never prompt" }
    }
    It "detects admin mailboxes on other lab domains and all mailboxes on this tenant's domain" {
        foreach ($mailbox in @("admin@other.onmicrosoft.com", "coe@contoso.onmicrosoft.com")) {
            $review = Get-CoELabSupportMailboxReview -Context $context -SupportEmail $mailbox
            $review.LabLooking | Should Be $true
            $review.RequiresReview | Should Be $true
        }
        Test-Path -LiteralPath $context.Path | Should Be $false
    }
    It "does not call a real support mailbox verified or reviewed" {
        $review = Get-CoELabSupportMailboxReview -Context $context -SupportEmail "support@example.org"
        $review.LabLooking | Should Be $false
        $review.SavedProceed | Should Be $false
        $review.RequiresReview | Should Be $false
    }
    It "flags a saved target approval even after the address is replaced and never alters the file" {
        $key = Get-CoEAdvisoryKey -Context $context -Id LabSupportMailbox -Facts @("admin@contoso.onmicrosoft.com")
        $document = @{ SchemaVersion = 1; Decisions = @(@{ Id = "LabSupportMailbox"; Fingerprint = $key.Fingerprint; Choice = "PROCEED"; Scope = $key.Scope }) }
        [IO.File]::WriteAllText($context.Path, ($document | ConvertTo-Json -Depth 10))
        $hash = (Get-FileHash -LiteralPath $context.Path).Hash
        $review = Get-CoELabSupportMailboxReview -Context $context -SupportEmail "support@example.org"
        $review.LabLooking | Should Be $false
        $review.SavedProceed | Should Be $true
        $review.RequiresReview | Should Be $true
        (Get-FileHash -LiteralPath $context.Path).Hash | Should Be $hash
        Assert-MockCalled Read-Host -Times 0 -Exactly -Scope It
    }
    It "does not transfer approvals from a different tenant host or alias" {
        foreach ($field in @("Tenant", "SiteFQDN", "TeamAlias")) {
            $other = [pscustomobject]@{ Tenant = $context.Tenant; SiteFQDN = $context.SiteFQDN; TeamAlias = $context.TeamAlias }
            $other.$field = "other"
            $key = Get-CoEAdvisoryKey -Context $other -Id LabSupportMailbox -Facts @("admin@contoso.onmicrosoft.com")
            $document = @{ SchemaVersion = 1; Decisions = @(@{ Id = "LabSupportMailbox"; Fingerprint = $key.Fingerprint; Choice = "PROCEED"; Scope = $key.Scope }) }
            [IO.File]::WriteAllText($context.Path, ($document | ConvertTo-Json -Depth 10))
            (Get-CoELabSupportMailboxReview -Context $context -SupportEmail "support@example.org").RequiresReview | Should Be $false
        }
    }
    It "ignores a saved STOP or a different advisory rather than calling it a mailbox approval" {
        foreach ($case in @(@{ Id = "LabSupportMailbox"; Choice = "STOP" }, @{ Id = "LongDisplayName"; Choice = "PROCEED" })) {
            $key = Get-CoEAdvisoryKey -Context $context -Id $case.Id -Facts @("a title")
            $document = @{ SchemaVersion = 1; Decisions = @(@{ Id = $case.Id; Fingerprint = $key.Fingerprint; Choice = $case.Choice; Scope = $key.Scope }) }
            [IO.File]::WriteAllText($context.Path, ($document | ConvertTo-Json -Depth 10))
            (Get-CoELabSupportMailboxReview -Context $context -SupportEmail "support@example.org").RequiresReview | Should Be $false
        }
    }
    It "reports invalid saved state instead of silently passing the review" {
        [IO.File]::WriteAllText($context.Path, '{"SchemaVersion":1,"Decisions":null}')
        Get-CoETestExceptionMessage { Get-CoELabSupportMailboxReview -Context $context -SupportEmail "support@example.org" } |
            Should Match "Invalid advisory decision file"
    }
    It "rejects a scope whose fingerprint no longer agrees" {
        $key = Get-CoEAdvisoryKey -Context $context -Id LabSupportMailbox -Facts @("admin@contoso.onmicrosoft.com")
        $key.Scope.TeamAlias = "changed"
        $document = @{ SchemaVersion = 1; Decisions = @(@{ Id = "LabSupportMailbox"; Fingerprint = $key.Fingerprint; Choice = "PROCEED"; Scope = $key.Scope }) }
        [IO.File]::WriteAllText($context.Path, ($document | ConvertTo-Json -Depth 10))
        Get-CoETestExceptionMessage { Get-CoELabSupportMailboxReview -Context $context -SupportEmail "support@example.org" } |
            Should Match "does not match its fingerprint"
    }
    It "keeps the original persisted fingerprint format" {
        $facts = @("admin@contoso.onmicrosoft.com")
        $json = [ordered]@{ Tenant = $context.Tenant; SiteFQDN = $context.SiteFQDN; TeamAlias = $context.TeamAlias
            Id = "LabSupportMailbox"; Facts = $facts } | ConvertTo-Json -Depth 5 -Compress
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $original = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json))).Replace("-", "") }
        finally { $sha.Dispose() }
        (Get-CoEAdvisoryKey -Context $context -Id LabSupportMailbox -Facts $facts).Fingerprint | Should Be $original
    }
}

Describe "Configuration policy advisories and hard input errors" {
    BeforeEach {
        $script:context = [pscustomobject]@{ Tenant = "contoso.onmicrosoft.com"; SiteFQDN = "contoso.sharepoint.com"; TeamAlias = "coe" }
        $script:settings = [pscustomobject]@{ Links = [pscustomobject]@{
            ServiceDesk = "https://support.example.org/"; TechnologyRequest = "https://support.example.org/request"
            AIGuidelines = "https://policy.example.org/"; DataSafetyIncident = "https://incident.example.org/"
        } }
        $script:arguments = @{ Context = $context; Settings = $settings; SupportEmail = "coe@example.org"
            DisplayName = "Contoso CoE"; SampleNotice = ""; ContentMode = "Customer" }
        Mock Confirm-CoEAdvisory {}
    }
    It "requires an explicit choice for an admin lab mailbox in Customer mode" {
        $arguments.SupportEmail = "admin@contoso.onmicrosoft.com"
        Invoke-CoEConfigurationAdvisories @arguments
        Assert-MockCalled Confirm-CoEAdvisory -Times 1 -Exactly -Scope It -ParameterFilter { $Id -eq "LabSupportMailbox" }
    }
    It "also detects a non-admin mailbox on the configured tenant domain" {
        $arguments.SupportEmail = "coe@contoso.onmicrosoft.com"
        Invoke-CoEConfigurationAdvisories @arguments
        Assert-MockCalled Confirm-CoEAdvisory -Times 1 -Exactly -Scope It -ParameterFilter { $Id -eq "LabSupportMailbox" }
    }
    It "does not flag a real organizational support mailbox" {
        Invoke-CoEConfigurationAdvisories @arguments
        Assert-MockCalled Confirm-CoEAdvisory -Times 0 -Exactly -Scope It
    }
    It "does not flag a lab mailbox in explicit Demo mode" {
        $arguments.SupportEmail = "admin@contoso.onmicrosoft.com"
        $arguments.ContentMode = "Demo"
        Invoke-CoEConfigurationAdvisories @arguments
        Assert-MockCalled Confirm-CoEAdvisory -Times 0 -Exactly -Scope It
    }
    It "stops when the operator declines the mailbox advisory" {
        Mock Confirm-CoEAdvisory { throw "Operator selected STOP" }
        $arguments.SupportEmail = "admin@contoso.onmicrosoft.com"
        Get-CoETestExceptionMessage { Invoke-CoEConfigurationAdvisories @arguments } | Should Match "Operator selected STOP"
    }
    It "keeps malformed email syntax a hard stop" {
        $arguments.SupportEmail = "<fill-me>"
        Get-CoETestExceptionMessage { Invoke-CoEConfigurationAdvisories @arguments } | Should Match "must be an email"
        Assert-MockCalled Confirm-CoEAdvisory -Times 0 -Exactly -Scope It
    }
    It "asks before continuing with a missing incident route" {
        $settings.Links.DataSafetyIncident = ""
        Invoke-CoEConfigurationAdvisories @arguments
        Assert-MockCalled Confirm-CoEAdvisory -Times 1 -Exactly -Scope It -ParameterFilter {
            $Id -eq "UnconfiguredSupportRoutes" -and "DataSafetyIncident" -in $Facts
        }
    }
    It "retains the explicit legacy missing-incident override but not for other routes" {
        $settings.Links.DataSafetyIncident = ""
        $settings.Links.ServiceDesk = ""
        Invoke-CoEConfigurationAdvisories @arguments -AllowMissingDataSafetyIncidentRoute
        Assert-MockCalled Confirm-CoEAdvisory -Times 1 -Exactly -Scope It -ParameterFilter {
            $Id -eq "UnconfiguredSupportRoutes" -and $Facts.Count -eq 1 -and $Facts[0] -eq "ServiceDesk"
        }
    }
    It "keeps malformed route values as hard stops even with the legacy override" {
        foreach ($invalid in @("http://unsafe.example.org/", "javascript:alert(1)", "<replace-me>", @("https://one.example.org/"))) {
            $settings.Links.DataSafetyIncident = $invalid
            Get-CoETestExceptionMessage { Invoke-CoEConfigurationAdvisories @arguments -AllowMissingDataSafetyIncidentRoute } |
                Should Match 'Links.DataSafetyIncident'
        }
        Assert-MockCalled Confirm-CoEAdvisory -Times 0 -Exactly -Scope It
    }
    It "asks about the default sample notice only in Demo mode" {
        $arguments.SampleNotice = "Sample starter content for review by Contoso; not official policy."
        $arguments.ContentMode = "Demo"
        Invoke-CoEConfigurationAdvisories @arguments
        Assert-MockCalled Confirm-CoEAdvisory -Times 1 -Exactly -Scope It -ParameterFilter { $Id -eq "DefaultSampleNotice" }
    }
    It "asks about titles longer than 30 characters" {
        $arguments.DisplayName = "Contoso Copilot Center of Excellence"
        Invoke-CoEConfigurationAdvisories @arguments
        Assert-MockCalled Confirm-CoEAdvisory -Times 1 -Exactly -Scope It -ParameterFilter { $Id -eq "LongDisplayName" }
    }
    It "runs install advisory checks before preparation sign-in and resource creation" {
        $install = Get-Content -LiteralPath (Join-Path $kitRoot "02_Install-CopilotCoE.ps1") -Raw
        $install.IndexOf('Invoke-CoEConfigurationAdvisories') | Should BeLessThan $install.IndexOf('& $prepareScript')
        $install.IndexOf('Invoke-CoEConfigurationAdvisories') | Should BeLessThan $install.IndexOf('$adminConnection = Connect-PnPOnline')
    }
}
