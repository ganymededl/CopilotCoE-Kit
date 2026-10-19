param([string]$LauncherPath)

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "New-CoETestFixture.ps1")
$kitRoot = Split-Path -Parent $PSScriptRoot
$tokens = $null
$parseErrors = $null
$removalAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $kitRoot "04_Remove-CopilotCoE.ps1"), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
function Import-RemovalTestFunction($Ast, [string]$Name) {
    $node = $Ast.Find({ param($candidate)
        $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $Name
    }, $true)
    if (-not $node) { throw "Missing function: $Name" }
    return [scriptblock]::Create($node.Extent.Text)
}
. (Import-RemovalTestFunction $removalAst "Write-CoEPurgeReceipt")
$fixture = Join-Path (Get-Location).Path ("removal-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$null = New-Item -ItemType Directory -Path $fixture
try {
    Describe "Official purge completion receipt" {
        BeforeEach {
            $script:receiptPath = Join-Path $fixture ("org-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + "\CoE-Purge-Receipt.json")
            $script:settings = [pscustomobject]@{
                Tenant = "offline.onmicrosoft.com"; AdminFQDN = "offline-admin.sharepoint.com"
                SiteFQDN = "offline.sharepoint.com"; MailNickname = "OfflineCoE"
            }
            $script:arguments = @{
                ReceiptPath = $receiptPath; Settings = $settings; Alias = "OfflineCoE"
                GroupId = "11111111-1111-1111-1111-111111111111"
                SiteUrl = "https://offline.sharepoint.com/sites/OfflineCoE"
                SiteUrls = @("https://offline.sharepoint.com/sites/OfflineCoE",
                    "https://offline.sharepoint.com/sites/OfflineCoE-Leadership")
                AliasReusable = $true; Purge = $true; ReleaseRoot = (Join-Path $fixture "release")
            }
        }
        It "writes exact tenant, alias, immutable group, site URLs and UTC completion only after purge" {
            Write-CoEPurgeReceipt @arguments | Should Be $receiptPath
            $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
            $receipt.Producer | Should Be "04_Remove-CopilotCoE.ps1"
            $receipt.AliasReusable | Should Be $true
            foreach ($name in @("Tenant", "AdminFQDN", "SiteFQDN", "MailNickname")) {
                $receipt.$name | Should Be $settings.$name
            }
            $receipt.GroupId | Should Be $arguments.GroupId
            $receipt.SiteUrl | Should Be $arguments.SiteUrl
            ($receipt.SiteUrls -join "|") | Should Be (($arguments.SiteUrls | Sort-Object) -join "|")
            (Get-Content -LiteralPath $receiptPath -Raw) | Should Match '"PurgeCompletedAtUtc"\s*:\s*"[^"]+Z"'
            ([guid]$receipt.ReceiptId -ne [guid]::Empty) | Should Be $true
        }
        It "writes nothing for an incomplete purge" {
            $arguments.AliasReusable = $false
            @(Write-CoEPurgeReceipt @arguments).Count | Should Be 0
            (Test-Path -LiteralPath $receiptPath) | Should Be $false
        }
        It "writes nothing for soft deletion" {
            $arguments.Purge = $false
            @(Write-CoEPurgeReceipt @arguments).Count | Should Be 0
            (Test-Path -LiteralPath $receiptPath) | Should Be $false
        }
        It "writes neither a receipt nor its directory under WhatIf" {
            Write-CoEPurgeReceipt @arguments -WhatIf
            (Test-Path -LiteralPath (Split-Path -Parent $receiptPath)) | Should Be $false
        }
        It "rejects a receipt inside the release" {
            $arguments.ReceiptPath = Join-Path $arguments.ReleaseRoot "CoE-Purge-Receipt.json"
            Get-CoETestExceptionMessage { Write-CoEPurgeReceipt @arguments } | Should Match "outside the release"
        }
        It "rejects a missing immutable group ID" {
            $arguments.GroupId = ""
            Get-CoETestExceptionMessage { Write-CoEPurgeReceipt @arguments } | Should Match "immutable"
        }
        It "rejects an alias different from the settings profile" {
            $arguments.Alias = "AnotherCoE"
            Get-CoETestExceptionMessage { Write-CoEPurgeReceipt @arguments } | Should Match "differs"
        }
        It "rejects a site from another tenant" {
            $arguments.SiteUrls += "https://other.sharepoint.com/sites/OfflineCoE"
            Get-CoETestExceptionMessage { Write-CoEPurgeReceipt @arguments } | Should Match "outside"
        }
        It "rejects an incomplete exact URL list" {
            $arguments.SiteUrls = @("https://offline.sharepoint.com/sites/OfflineCoE-Leadership")
            Get-CoETestExceptionMessage { Write-CoEPurgeReceipt @arguments } | Should Match "primary site"
        }
        It "places receipt production inside the AliasReusable and not-WhatIf guard" {
            $gate = $removalAst.Find({ param($candidate)
                $candidate -is [Management.Automation.Language.IfStatementAst] -and
                $candidate.Extent.Text.StartsWith('if ($aliasReusable -and -not $WhatIfPreference)')
            }, $true)
            ($null -ne $gate) | Should Be $true
            $gate.Extent.Text | Should Match "Write-CoEPurgeReceipt"
            $removalAst.Extent.Text | Should Match '\$remainingActiveGroups.Count -eq 0'
            $removalAst.Extent.Text | Should Match "Deleted-site enumeration reached its limit"
        }
    }

    if ($LauncherPath) {
        $launcherAst = [Management.Automation.Language.Parser]::ParseFile(
            $LauncherPath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
        foreach ($name in @("Assert-NeHttpsUrl", "Assert-NeProfile", "Invoke-NeConfigurationAdvisories",
            "Get-NeInstalledSiteUrl", "Get-NeUtcTimestamp",
            "Assert-NePurgeReceipt", "Assert-NePurgeAbsent", "New-NeResetState", "Save-NeResetState")) {
            . (Import-RemovalTestFunction $launcherAst $name)
        }
        # Stub names enable Pester mocks without loading PnP or making tenant connections.
        function Get-PnPMicrosoft365Group { [CmdletBinding()]param($Filter, $Connection) throw "Offline only" }
        function Get-PnPDeletedMicrosoft365Group { [CmdletBinding()]param($Connection) throw "Offline only" }
        function Get-PnPTenantSite { [CmdletBinding()]param($Filter, $Template, $Connection) throw "Offline only" }
        function Get-PnPTenantDeletedSite { [CmdletBinding()]param($Limit, $Connection) throw "Offline only" }
        function Assert-NeExtraction { param($ArchivePath, $Root) throw "Offline extraction stub" }
        function Connect-PnPOnline { throw "No tenant connection is allowed in offline tests" }
        $script:resetEntryBlock = [scriptblock]::Create($launcherAst.Find({ param($candidate)
            $candidate -is [Management.Automation.Language.IfStatementAst] -and
            $candidate.Extent.Text.StartsWith('if ($ResetAfterPurge) {')
        }, $true).Extent.Text)
        function Invoke-NeOfflineReset {
            [CmdletBinding(SupportsShouldProcess)]param()
            $ResetAfterPurge = $true
            . $script:resetEntryBlock
        }

        Describe "Launcher advisory configuration preflight" {
            BeforeEach {
                $script:settings = [pscustomobject]@{
                    Tenant = "offline.onmicrosoft.com"; AdminFQDN = "offline-admin.sharepoint.com"
                    SiteFQDN = "offline.sharepoint.com"; MailNickname = "OfflineCoE"
                    SharedChannelOwnerUPN = "owner@offline.onmicrosoft.com"; SupportEmail = "admin@offline.onmicrosoft.com"
                    OrgName = "Offline"; DisplayName = "Offline CoE"; TimeZone = "UTC"; PnPClientID = ""
                    TeamVisibility = "Private"; CoESiteSharingCapability = "Disabled"
                    LearningEnvironment = "Government"; SampleNotice = "none"
                    OrganizationEmailDomains = @("offline.onmicrosoft.com")
                    Links = [pscustomobject]@{ AboutOrg = "https://example.org/" }
                }
            }
            It "allows missing support route properties while requiring AboutOrg" {
                Assert-NeProfile $settings
            }
            It "allows null, empty or whitespace support routes and valid configured HTTPS routes" {
                foreach ($name in @("ServiceDesk", "TechnologyRequest", "AIGuidelines", "DataSafetyIncident")) {
                    foreach ($value in @($null, "", " ", "https://example.org/support")) {
                        $settings.Links | Add-Member NoteProperty $name $value -Force
                        Assert-NeProfile $settings
                    }
                }
            }
            It "rejects nonstring support routes, including empty and single-element arrays" {
                $cases = @(
                    @{ Value = $false }, @{ Value = 42 }, @{ Value = [pscustomobject]@{} },
                    @{ Value = @() }, @{ Value = @("https://example.org/support") }
                )
                foreach ($name in @("ServiceDesk", "TechnologyRequest", "AIGuidelines", "DataSafetyIncident")) {
                    foreach ($case in $cases) {
                        $settings.Links | Add-Member NoteProperty $name $case.Value -Force
                        Get-CoETestExceptionMessage { Assert-NeProfile $settings } | Should Match ([regex]::Escape("Links.$name"))
                    }
                    $settings.Links.PSObject.Properties.Remove($name)
                }
            }
            It "rejects nonempty malformed support URLs" {
                foreach ($name in @("ServiceDesk", "TechnologyRequest", "AIGuidelines", "DataSafetyIncident")) {
                    foreach ($value in @("http://example.org/", "/support", "not-a-url", "https://<tenant>/support")) {
                        $settings.Links | Add-Member NoteProperty $name $value -Force
                        Get-CoETestExceptionMessage { Assert-NeProfile $settings } | Should Match ([regex]::Escape("Links.$name"))
                    }
                    $settings.Links.PSObject.Properties.Remove($name)
                }
            }
            It "does not make AboutOrg optional" {
                foreach ($value in @($null, "", "http://example.org/")) {
                    $settings.Links.AboutOrg = $value
                    Get-CoETestExceptionMessage { Assert-NeProfile $settings } | Should Match "Links.AboutOrg"
                }
                $settings.Links.PSObject.Properties.Remove("AboutOrg")
                Get-CoETestExceptionMessage { Assert-NeProfile $settings } | Should Match "Links.AboutOrg"
            }
            It "keeps mailbox syntax, tenant identity and organization domains as hard checks" {
                $settings.SupportEmail = "not-an-address"
                Get-CoETestExceptionMessage { Assert-NeProfile $settings } | Should Match "SupportEmail"
                $settings.SupportEmail = "admin@offline.onmicrosoft.com"
                $settings.AdminFQDN = "other-admin.sharepoint.com"
                Get-CoETestExceptionMessage { Assert-NeProfile $settings } | Should Match "AdminFQDN"
                $settings.AdminFQDN = "offline-admin.sharepoint.com"
                $settings.OrganizationEmailDomains = @("https://example.org/")
                Get-CoETestExceptionMessage { Assert-NeProfile $settings } | Should Match "OrganizationEmailDomains"
            }
            It "runs real local advisories and preserves an unattempted state when the operator stops" {
                $org = Join-Path $fixture "advisory-stop"
                $null = New-Item -ItemType Directory -Path $org
                $file = Join-Path $org "Deployment-Settings.json"
                $localState = Join-Path $org "Customer-Walkthrough-State.json"
                $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file
                '{"InstallAttempted":false,"Installed":false}' | Set-Content -LiteralPath $localState
                $before = (Get-FileHash -LiteralPath $localState -Algorithm SHA256).Hash
                Mock Read-Host { "STOP" }
                Get-CoETestExceptionMessage {
                    Invoke-NeConfigurationAdvisories $kitRoot $file $settings
                } | Should Match "Operator selected STOP"
                (Get-FileHash -LiteralPath $localState -Algorithm SHA256).Hash | Should Be $before
                $saved = Get-Content -LiteralPath (Join-Path $org "CoE-Advisory-Decisions.json") -Raw | ConvertFrom-Json
                $saved.Decisions[0].Choice | Should Be "STOP"
                Assert-MockCalled Read-Host -Times 1 -Exactly -Scope It
            }
            It "uses the same decisions on a repeated preflight without treating SampleNotice none as Demo" {
                $org = Join-Path $fixture "advisory-proceed"
                $null = New-Item -ItemType Directory -Path $org
                $file = Join-Path $org "Deployment-Settings.json"
                $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $file
                Mock Read-Host { "PROCEED" }
                Invoke-NeConfigurationAdvisories $kitRoot $file $settings
                Invoke-NeConfigurationAdvisories $kitRoot $file $settings
                $saved = Get-Content -LiteralPath (Join-Path $org "CoE-Advisory-Decisions.json") -Raw | ConvertFrom-Json
                $saved.Decisions.Count | Should Be 2
                ($saved.Decisions.Id | Sort-Object) -join "|" | Should Be "LabSupportMailbox|UnconfiguredSupportRoutes"
                Assert-MockCalled Read-Host -Times 2 -Exactly -Scope It
            }
            It "runs the launcher advisories before CREATE, registration, and the install-attempt latch, never during reset" {
                $source = $launcherAst.Extent.Text
                $call = $source.IndexOf('Invoke-NeConfigurationAdvisories -KitRoot')
                $call | Should BeGreaterThan 0
                $call | Should BeLessThan $source.IndexOf('"CREATE"')
                $call | Should BeLessThan $source.IndexOf('$state.InstallAttempted = $true')
                $call | Should BeLessThan $source.IndexOf('$state.AppRegistrationAttempted = $true')
                $resetEntryBlock.ToString() | Should Not Match "Invoke-NeConfigurationAdvisories|OperatorAdvisories"
            }
        }

        Describe "Launcher failed-attempt reset evidence" {
            BeforeEach {
                $script:settings = [pscustomobject]@{
                    Tenant = "offline.onmicrosoft.com"; AdminFQDN = "offline-admin.sharepoint.com"
                    SiteFQDN = "offline.sharepoint.com"; MailNickname = "OfflineCoE"
                }
                $script:state = [pscustomobject]@{
                    InstallAttempted = $true; Installed = $false; ManualAccepted = $false; UpdateAccepted = $false
                    InstallAttemptedAtUtc = [DateTime]::UtcNow.AddHours(-2).ToString("o")
                    AppRegistrationAttempted = $true; AppClientId = "preserve-app"; InstallRoot = "C:\offline-kit"
                    Version = "old"; ZipSHA256 = "old-hash"; OrganizationExtension = @{ Keep = "yes" }
                }
                $script:receipt = [pscustomobject]@{
                    SchemaVersion = 1; Producer = "04_Remove-CopilotCoE.ps1"
                    ReceiptId = "22222222-2222-2222-2222-222222222222"; AliasReusable = $true
                    Tenant = $settings.Tenant; AdminFQDN = $settings.AdminFQDN; SiteFQDN = $settings.SiteFQDN
                    MailNickname = $settings.MailNickname; GroupId = "11111111-1111-1111-1111-111111111111"
                    SiteUrl = "https://offline.sharepoint.com/sites/OfflineCoE"
                    SiteUrls = @("https://offline.sharepoint.com/sites/OfflineCoE",
                        "https://offline.sharepoint.com/sites/OfflineCoE-Leadership")
                    PurgeCompletedAtUtc = [DateTime]::UtcNow.AddHours(-1).ToString("o")
                }
                $script:legacyTime = [DateTime]::UtcNow.AddHours(-2)
            }
            It "accepts a completed exact-target receipt newer than the attempt" {
                $proof = Assert-NePurgeReceipt $receipt $settings $state $legacyTime
                $proof.GroupId | Should Be $receipt.GroupId
                $proof.SiteUrls.Count | Should Be 2
            }
            It "accepts explicit UTC DateTime values deserialized by PowerShell 7" {
                $receipt.PurgeCompletedAtUtc = [DateTime]::UtcNow.AddHours(-1)
                $state.InstallAttemptedAtUtc = [DateTime]::UtcNow.AddHours(-2)
                (Assert-NePurgeReceipt $receipt $settings $state $legacyTime).SiteUrls.Count | Should Be 2
                $receipt.PurgeCompletedAtUtc = [DateTime]::SpecifyKind($receipt.PurgeCompletedAtUtc, [DateTimeKind]::Unspecified)
                Get-CoETestExceptionMessage { Assert-NePurgeReceipt $receipt $settings $state $legacyTime } | Should Match "UTC timestamp"
            }
            It "rejects every mismatching tenant identity component" {
                foreach ($name in @("Tenant", "AdminFQDN", "SiteFQDN", "MailNickname")) {
                    $original = $receipt.$name
                    $receipt.$name = "different"
                    Get-CoETestExceptionMessage { Assert-NePurgeReceipt $receipt $settings $state $legacyTime } |
                        Should Match "does not match"
                    $receipt.$name = $original
                }
            }
            It "rejects missing fields and a nonboolean completion flag" {
                $receipt.PSObject.Properties.Remove("GroupId")
                Get-CoETestExceptionMessage { Assert-NePurgeReceipt $receipt $settings $state $legacyTime } | Should Match "missing GroupId"
                $receipt | Add-Member NoteProperty GroupId "11111111-1111-1111-1111-111111111111"
                $receipt.AliasReusable = "true"
                Get-CoETestExceptionMessage { Assert-NePurgeReceipt $receipt $settings $state $legacyTime } | Should Match "completed official"
            }
            It "rejects stale evidence when another attempt started after purge" {
                $state.InstallAttemptedAtUtc = [DateTime]::UtcNow.AddMinutes(-10).ToString("o")
                Get-CoETestExceptionMessage { Assert-NePurgeReceipt $receipt $settings $state $legacyTime } | Should Match "after this attempt"
            }
            It "uses the state file write time conservatively for old launchers" {
                $state.PSObject.Properties.Remove("InstallAttemptedAtUtc")
                $proof = Assert-NePurgeReceipt $receipt $settings $state $legacyTime
                $proof.SiteUrls.Count | Should Be 2
                Get-CoETestExceptionMessage {
                    Assert-NePurgeReceipt $receipt $settings $state ([DateTime]::UtcNow)
                } | Should Match "legacy state"
            }
            It "rejects malformed and future timestamps" {
                $receipt.PurgeCompletedAtUtc = "yesterday"
                Get-CoETestExceptionMessage { Assert-NePurgeReceipt $receipt $settings $state $legacyTime } | Should Match "UTC timestamp"
                $receipt.PurgeCompletedAtUtc = [DateTime]::UtcNow.AddHours(1).ToString("o")
                Get-CoETestExceptionMessage { Assert-NePurgeReceipt $receipt $settings $state $legacyTime } | Should Match "future"
            }
            It "rejects completed installs, unattempted installs and consumed receipts" {
                $state.Installed = $true
                Get-CoETestExceptionMessage { Assert-NePurgeReceipt $receipt $settings $state $legacyTime } | Should Match "failed install"
                $state.Installed = $false; $state.InstallAttempted = $false
                Get-CoETestExceptionMessage { Assert-NePurgeReceipt $receipt $settings $state $legacyTime } | Should Match "failed install"
                $state.InstallAttempted = $true
                $state | Add-Member NoteProperty PurgeResetReceiptId $receipt.ReceiptId
                Get-CoETestExceptionMessage { Assert-NePurgeReceipt $receipt $settings $state $legacyTime } | Should Match "already consumed"
            }
            It "rejects incomplete URLs, foreign URLs and recorded site mismatches" {
                $original = $receipt.SiteUrls
                $receipt.SiteUrls = @()
                Get-CoETestExceptionMessage { Assert-NePurgeReceipt $receipt $settings $state $legacyTime } | Should Match "exact site URLs"
                $receipt.SiteUrls = @("https://other.sharepoint.com/sites/OfflineCoE")
                Get-CoETestExceptionMessage { Assert-NePurgeReceipt $receipt $settings $state $legacyTime } | Should Match "outside"
                $receipt.SiteUrls = $original
                $state | Add-Member NoteProperty InstalledSiteUrl "https://offline.sharepoint.com/teams/OfflineCoE"
                Get-CoETestExceptionMessage { Assert-NePurgeReceipt $receipt $settings $state $legacyTime } | Should Match "recorded site"
            }
            It "clears only installation flags, preserves app and extension data and updates pins" {
                $newState = New-NeResetState $state $receipt.ReceiptId "test-version" "test-hash"
                foreach ($name in @("Installed", "InstallAttempted", "ManualAccepted", "UpdateAccepted")) {
                    $newState.$name | Should Be $false
                }
                ($null -eq $newState.InstallAttemptedAtUtc) | Should Be $true
                ($null -eq $newState.InstalledSiteUrl) | Should Be $true
                $newState.AppRegistrationAttempted | Should Be $true
                $newState.AppClientId | Should Be "preserve-app"
                $newState.InstallRoot | Should Be $state.InstallRoot
                $newState.OrganizationExtension.Keep | Should Be "yes"
                $newState.Version | Should Be "test-version"
                $newState.ZipSHA256 | Should Be "test-hash"
                $newState.PurgeResetReceiptId | Should Be $receipt.ReceiptId
                $state.InstallAttempted | Should Be $true
            }
            It "backs up the original state before replacement and consumes the receipt" {
                $org = Join-Path $fixture ("reset-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
                $null = New-Item -ItemType Directory -Path $org
                $stateFile = Join-Path $org "Customer-Walkthrough-State.json"
                $receiptFile = Join-Path $org "CoE-Purge-Receipt.json"
                $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $stateFile
                $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptFile
                $before = (Get-FileHash -LiteralPath $stateFile -Algorithm SHA256).Hash
                $newState = New-NeResetState $state $receipt.ReceiptId "new" "hash"
                Save-NeResetState $stateFile $receiptFile $newState $org
                $backupFile = @(Get-ChildItem -LiteralPath (Join-Path $org "Backups") -Recurse -Filter "Customer-Walkthrough-State.json")
                $backupFile.Count | Should Be 1
                (Get-FileHash -LiteralPath $backupFile[0].FullName -Algorithm SHA256).Hash | Should Be $before
                (Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json).InstallAttempted | Should Be $false
                (Test-Path -LiteralPath $receiptFile) | Should Be $false
                @(Get-ChildItem -LiteralPath (Join-Path $org "Backups") -Recurse -Filter "Consumed-CoE-Purge-Receipt.json").Count | Should Be 1
            }
            It "does not replace state or consume evidence when the backup fails" {
                $org = Join-Path $fixture ("backupfail-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
                $null = New-Item -ItemType Directory -Path $org
                $stateFile = Join-Path $org "Customer-Walkthrough-State.json"
                $receiptFile = Join-Path $org "CoE-Purge-Receipt.json"
                $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $stateFile
                $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptFile
                $before = (Get-FileHash -LiteralPath $stateFile -Algorithm SHA256).Hash
                Mock Copy-Item { throw "backup denied" }
                Get-CoETestExceptionMessage {
                    Save-NeResetState $stateFile $receiptFile (New-NeResetState $state $receipt.ReceiptId "new" "hash") $org
                } | Should Be "backup denied"
                (Get-FileHash -LiteralPath $stateFile -Algorithm SHA256).Hash | Should Be $before
                (Test-Path -LiteralPath $receiptFile) | Should Be $true
            }
        }

        Describe "Read-only live absence verification" {
            BeforeEach {
                $script:settings = [pscustomobject]@{ MailNickname = "OfflineCoE" }
                $script:proof = [pscustomobject]@{
                    GroupId = "11111111-1111-1111-1111-111111111111"
                    SiteUrls = @("https://offline.sharepoint.com/sites/OfflineCoE",
                        "https://offline.sharepoint.com/sites/OfflineCoE-Leadership")
                }
                Mock Get-PnPMicrosoft365Group {}
                Mock Get-PnPDeletedMicrosoft365Group {}
                Mock Get-PnPTenantSite {}
                Mock Get-PnPTenantDeletedSite {}
            }
            It "checks the alias, immutable group ID, channel sites and each exact receipt URL" {
                Assert-NePurgeAbsent $settings $proof "offline"
                Assert-MockCalled Get-PnPMicrosoft365Group -Times 2 -Exactly -Scope It
                Assert-MockCalled Get-PnPDeletedMicrosoft365Group -Times 1 -Exactly -Scope It
                Assert-MockCalled Get-PnPTenantSite -Times 5 -Exactly -Scope It
                Assert-MockCalled Get-PnPTenantDeletedSite -Times 1 -Exactly -Scope It
            }
            It "blocks an active alias group" {
                Mock Get-PnPMicrosoft365Group { [pscustomobject]@{ Id = "active" } }
                Get-CoETestExceptionMessage { Assert-NePurgeAbsent $settings $proof "offline" } | Should Match "active group"
            }
            It "blocks the immutable active group even if its alias changed" {
                Mock Get-PnPMicrosoft365Group {
                    if ($Filter -like "id eq*") { [pscustomobject]@{ Id = "11111111-1111-1111-1111-111111111111" } }
                }
                Get-CoETestExceptionMessage { Assert-NePurgeAbsent $settings $proof "offline" } | Should Match "active group"
            }
            It "blocks a recycled group even if its alias changed" {
                Mock Get-PnPDeletedMicrosoft365Group {
                    [pscustomobject]@{ MailNickname = "Changed"; Id = "11111111-1111-1111-1111-111111111111" }
                }
                Get-CoETestExceptionMessage { Assert-NePurgeAbsent $settings $proof "offline" } | Should Match "Entra recycle bin"
            }
            It "blocks an active channel site at an exact receipt URL" {
                Mock Get-PnPTenantSite {
                    if ($Filter -like "*-Leadership*") {
                        [pscustomobject]@{ Url = "https://offline.sharepoint.com/sites/OfflineCoE-Leadership" }
                    }
                }
                Get-CoETestExceptionMessage { Assert-NePurgeAbsent $settings $proof "offline" } | Should Match "still active"
            }
            It "blocks a recycled exact receipt URL or alias on another managed path" {
                Mock Get-PnPTenantDeletedSite {
                    [pscustomobject]@{ Url = "https://offline.sharepoint.com/teams/OfflineCoE" }
                }
                Get-CoETestExceptionMessage { Assert-NePurgeAbsent $settings $proof "offline" } | Should Match "SharePoint recycle bin"
            }
            It "blocks a recycled channel site at its exact receipt URL" {
                Mock Get-PnPTenantDeletedSite {
                    [pscustomobject]@{ Url = "https://offline.sharepoint.com/sites/OfflineCoE-Leadership" }
                }
                Get-CoETestExceptionMessage { Assert-NePurgeAbsent $settings $proof "offline" } | Should Match "SharePoint recycle bin"
            }
            It "fails closed when identity information is incomplete" {
                Mock Get-PnPDeletedMicrosoft365Group { [pscustomobject]@{ DisplayName = "unknown" } }
                Get-CoETestExceptionMessage { Assert-NePurgeAbsent $settings $proof "offline" } | Should Match "complete identity"
            }
            It "fails closed when deleted-group identity properties are present but empty" {
                Mock Get-PnPDeletedMicrosoft365Group { [pscustomobject]@{ MailNickname = $null; Id = $null } }
                Get-CoETestExceptionMessage { Assert-NePurgeAbsent $settings $proof "offline" } | Should Match "complete identity"
            }
            It "propagates permission or authentication failures instead of treating them as absence" {
                Mock Get-PnPTenantDeletedSite { throw "403 forbidden" }
                Get-CoETestExceptionMessage { Assert-NePurgeAbsent $settings $proof "offline" } | Should Be "403 forbidden"
            }
            It "fails closed if deleted-site enumeration reaches its limit" {
                Mock Get-PnPTenantDeletedSite { 1..100000 | ForEach-Object { [pscustomobject]@{ Url = "https://offline.sharepoint.com/sites/Other" } } }
                Get-CoETestExceptionMessage { Assert-NePurgeAbsent $settings $proof "offline" } | Should Match "reached its limit"
            }
        }

        Describe "Launcher reset orchestration guards" {
            It "keeps a legacy purge without a receipt blocked and unchanged before any connection" {
                $script:OrgPath = Join-Path $fixture "legacy-no-receipt"
                $null = New-Item -ItemType Directory -Path $OrgPath
                $script:InstallRoot = "C:\offline-kit"
                $script:ZipPath = "C:\offline.zip"
                $script:statePath = Join-Path $OrgPath "Customer-Walkthrough-State.json"
                $script:settingsPath = Join-Path $OrgPath "Deployment-Settings.json"
                [pscustomobject]@{
                    InstallRoot = $InstallRoot; InstallAttempted = $true; Installed = $false
                } | ConvertTo-Json | Set-Content -LiteralPath $statePath
                '{}' | Set-Content -LiteralPath $settingsPath
                $before = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
                Mock Assert-NeExtraction {}
                Mock Assert-NeProfile {}
                Mock Connect-PnPOnline { throw "Unexpected connection" }
                Mock Save-NeResetState { throw "Unexpected reset" }
                $message = Get-CoETestExceptionMessage { Invoke-NeOfflineReset }
                $message | Should Match "reset remains blocked"
                $message | Should Match "legacy purge"
                $message | Should Match "do not fabricate a receipt or clear the attempt flag"
                Assert-MockCalled Connect-PnPOnline -Times 0 -Exactly -Scope It
                Assert-MockCalled Save-NeResetState -Times 0 -Exactly -Scope It
                (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash | Should Be $before
                (Test-Path -LiteralPath (Join-Path $OrgPath "CoE-Purge-Receipt.json")) | Should Be $false
                (Test-Path -LiteralPath (Join-Path $OrgPath "Backups")) | Should Be $false
            }
            It "does not connect, write state or consume the receipt under WhatIf" {
                $script:OrgPath = Join-Path $fixture "whatif"
                $null = New-Item -ItemType Directory -Path $OrgPath
                $script:InstallRoot = "C:\offline-kit"
                $script:ZipPath = "C:\offline.zip"
                $script:statePath = Join-Path $OrgPath "Customer-Walkthrough-State.json"
                $script:settingsPath = Join-Path $OrgPath "Deployment-Settings.json"
                $receiptFile = Join-Path $OrgPath "CoE-Purge-Receipt.json"
                [pscustomobject]@{
                    InstallRoot = $InstallRoot; InstallAttempted = $true; Installed = $false
                    InstallAttemptedAtUtc = [DateTime]::UtcNow.AddHours(-2).ToString("o")
                } | ConvertTo-Json | Set-Content -LiteralPath $statePath
                [pscustomobject]@{
                    Tenant = "offline.onmicrosoft.com"; AdminFQDN = "offline-admin.sharepoint.com"
                    SiteFQDN = "offline.sharepoint.com"; MailNickname = "OfflineCoE"
                } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath
                [pscustomobject]@{
                    SchemaVersion = 1; Producer = "04_Remove-CopilotCoE.ps1"
                    ReceiptId = "22222222-2222-2222-2222-222222222222"; AliasReusable = $true
                    Tenant = "offline.onmicrosoft.com"; AdminFQDN = "offline-admin.sharepoint.com"
                    SiteFQDN = "offline.sharepoint.com"; MailNickname = "OfflineCoE"
                    GroupId = "11111111-1111-1111-1111-111111111111"
                    SiteUrl = "https://offline.sharepoint.com/sites/OfflineCoE"
                    SiteUrls = @("https://offline.sharepoint.com/sites/OfflineCoE")
                    PurgeCompletedAtUtc = [DateTime]::UtcNow.AddHours(-1).ToString("o")
                } | ConvertTo-Json | Set-Content -LiteralPath $receiptFile
                $before = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
                Mock Assert-NeExtraction {}
                Mock Assert-NeProfile {}
                Mock Connect-PnPOnline { throw "Unexpected connection" }
                Mock Save-NeResetState { throw "Unexpected state reset" }
                Invoke-NeOfflineReset -WhatIf
                Assert-MockCalled Assert-NeExtraction -Times 1 -Exactly -Scope It
                Assert-MockCalled Connect-PnPOnline -Times 0 -Exactly -Scope It
                Assert-MockCalled Save-NeResetState -Times 0 -Exactly -Scope It
                (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash | Should Be $before
                (Test-Path -LiteralPath $receiptFile) | Should Be $true
                (Test-Path -LiteralPath (Join-Path $OrgPath "Backups")) | Should Be $false
            }
            It "returns before preparation or install and checks extraction before connecting" {
                $branch = $launcherAst.Find({ param($candidate)
                    $candidate -is [Management.Automation.Language.IfStatementAst] -and
                    $candidate.Extent.Text.StartsWith('if ($ResetAfterPurge) {')
                }, $true).Extent.Text
                $branch.IndexOf("Assert-NeExtraction") | Should BeLessThan $branch.IndexOf("Connect-PnPOnline")
                $branch | Should Match 'ShouldProcess'
                $branch | Should Match 'Assert-NePurgeAbsent'
                $branch | Should Match 'return\s*\}$'
                $branch | Should Not Match 'Invoke-NeKitScript|Install-Module|Remove-PnP|New-PnP'
                $launcherAst.Extent.Text.IndexOf('if ((Get-FileHash -LiteralPath $ZipPath') |
                    Should BeLessThan $launcherAst.Extent.Text.IndexOf('if ($ResetAfterPurge) {')
            }
            It "records the UTC attempt timestamp before the install process starts" {
                $source = $launcherAst.Extent.Text
                $source | Should Match 'InstallAttemptedAtUtc \(\[DateTime\]::UtcNow.ToString\("o"\)\)'
                $source.IndexOf('$state | Add-Member NoteProperty InstallAttemptedAtUtc') |
                    Should BeLessThan $source.IndexOf('$null = Invoke-NeKitScript "02_Install-CopilotCoE.ps1"')
                $source | Should Match 'if \(\$state.InstallAttempted\)'
            }
        }
    }
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction Stop
}
