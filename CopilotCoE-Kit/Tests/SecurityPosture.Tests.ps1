# Run the installed Pester 3 runner in Windows PowerShell; use PowerShell 7 for deployment.
Set-StrictMode -Version Latest
$kitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $kitRoot "Internal\SecurityPosture.ps1")

# Local stand-ins make the tests fail rather than contact a tenant if a mock is missing.
function Get-PnPTenantSite {
    [CmdletBinding()] param($Identity, [switch]$Detailed, [switch]$DisableSharingForNonOwnersStatus, $Connection)
    throw "Unmocked tenant read"
}
function Set-PnPTenantSite {
    [CmdletBinding()] param($Identity, $SharingCapability, [switch]$DisableSharingForNonOwners, $Connection, [switch]$Wait)
    throw "Unmocked tenant write"
}
function Get-PnPTeamsTeam {
    [CmdletBinding()] param($Identity, $Connection)
    throw "Unmocked Team read"
}
function Get-PnPTeamsChannel {
    [CmdletBinding()] param($Team, $Connection)
    throw "Unmocked channel read"
}
function Get-PnPTeamsChannelUser {
    [CmdletBinding()] param($Team, $Channel, $Connection)
    throw "Unmocked roster read"
}
function Get-PnPTeamsChannelFilesFolder {
    [CmdletBinding()] param($Team, $Channel, $Connection)
    throw "Unmocked files-folder read"
}
function Get-PnPExternalUser {
    [CmdletBinding()] param($SiteUrl, $Connection)
    throw "Unmocked external-user read"
}
function Invoke-PnPGraphMethod {
    [CmdletBinding()] param($Url, $Method, $Connection)
    throw "Unmocked Graph request"
}
function Get-PnPTenantId {
    [CmdletBinding()] param($Connection)
    throw "Unmocked tenant identity read"
}
function Get-PnPAccessToken {
    [CmdletBinding()] param($ResourceTypeName, [switch]$Decoded, $Connection)
    throw "Unmocked token identity read"
}

Describe "CoE early install preflight" {
    It "normalizes and deduplicates approved internal domains" {
        @(Get-CoEOrganizationDomains @(" @EXAMPLE.EDU ", "example.edu")) -join "," | Should Be "example.edu"
    }
    It "rejects missing or unfilled domains before provisioning" {
        { Get-CoEOrganizationDomains @() } | Should Throw
        { Get-CoEOrganizationDomains @("<your-domain>") } | Should Throw
    }
    It "checks organization domains and every approved governance identity before creation" {
        $text = Get-Content -LiteralPath (Join-Path $kitRoot "02_Install-CopilotCoE.ps1") -Raw
        $text.IndexOf('Get-CoEOrganizationDomains -Domains') | Should BeLessThan $text.IndexOf('& $prepareScript')
        $text.IndexOf('foreach ($address in $GovernanceAdditionalAllowedMembers)', $text.IndexOf('Assert-CoEMemberIdentity -Identity $ownerIdentity')) |
            Should BeLessThan $text.IndexOf('Invoke-PnPTenantTemplate')
    }
    It "provides fresh interactive authentication without manipulating the shared cache" {
        $text = Get-Content -LiteralPath (Join-Path $kitRoot "02_Install-CopilotCoE.ps1") -Raw
        $text | Should Match '\$AuthenticationMode = "Interactive"'
        $text | Should Match '\$signIn.ForceAuthentication = \$true'
        $text | Should Match 'ForceAuthentication requires -AuthenticationMode Interactive'
        $text | Should Not Match 'Rename-Item.*pnp.msal.cache'
    }
    It "shares recoverable resource-tab handling between install and completion" {
        foreach ($relative in @("02_Install-CopilotCoE.ps1", "Internal\Complete-CopilotCoE.ps1")) {
            (Get-Content -LiteralPath (Join-Path $kitRoot $relative) -Raw) | Should Match 'ResourceTabs.ps1'
        }
    }
}

Describe "Channel files provisioning" {
    BeforeEach {
        $script:folderArgs = @{
            TeamId = "team-id"
            Channel = [pscustomobject]@{ Id = "channel-id"; DisplayName = "Program Governance" }
            Connection = "offline"
        }
        Mock Start-Sleep {}
    }
    It "retries a transient 404 and keeps the exact Team and channel identity" {
        $script:reads = 0
        Mock Get-PnPTeamsChannelFilesFolder {
            if ($Team -ne "team-id" -or $Channel -ne "channel-id") { throw "Wrong channel identity" }
            $script:reads++
            if ($script:reads -eq 1) { throw "Not Found (404): Site isn't available" }
            [pscustomobject]@{ webUrl = "https://example.sharepoint.com/sites/Program/Shared%20Documents" }
        }
        (Get-CoEChannelFilesFolder @script:folderArgs).webUrl | Should Match "/Program/"
        Assert-MockCalled Get-PnPTeamsChannelFilesFolder -Times 2 -Exactly -Scope It
        Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It
    }
    It "does not retry authorization failures or unrelated errors" {
        foreach ($errorText in @("403 Forbidden Timeout", "Unexpected validation failure")) {
            Mock Get-PnPTeamsChannelFilesFolder { throw $errorText }
            { Get-CoEChannelFilesFolder @script:folderArgs } | Should Throw
        }
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
        Assert-MockCalled Get-PnPTeamsChannelFilesFolder -Times 2 -Exactly -Scope It
    }
    It "propagates a 404 after the bounded attempts" {
        Mock Get-PnPTeamsChannelFilesFolder { throw "Not Found (404): Site isn't available" }
        { Get-CoEChannelFilesFolder @script:folderArgs } | Should Throw "Not Found"
        Assert-MockCalled Get-PnPTeamsChannelFilesFolder -Times 6 -Exactly -Scope It
        Assert-MockCalled Start-Sleep -Times 5 -Exactly -Scope It
    }
    It "uses the same folder resolver for standard and governance content" {
        $text = Get-Content -LiteralPath (Join-Path $kitRoot "Internal\Complete-CopilotCoE.ps1") -Raw
        $text | Should Match '\$channelFolder = Get-CoEChannelFilesFolder'
        $text | Should Match '\$folder = Get-CoEChannelFilesFolder'
    }
}

Describe "CoE guest preview policy" {
    BeforeEach {
        $script:parent = "https://example.sharepoint.com/sites/CoE"
        $script:teamId = "11111111-1111-1111-1111-111111111111"
        $script:tenantId = "22222222-2222-2222-2222-222222222222"
        $script:ownerId = "33333333-3333-3333-3333-333333333333"
        $script:owner = "owner@example.edu"
        $script:siteModes = @{
            $script:parent = "ExistingExternalUserSharingOnly"
            "https://example.sharepoint.com/sites/Leadership" = "Disabled"
            "https://example.sharepoint.com/sites/Program" = "Disabled"
        }
        $script:nonOwnerDisabled = @{
            $script:parent = $true
            "https://example.sharepoint.com/sites/Leadership" = $true
            "https://example.sharepoint.com/sites/Program" = $true
        }
        $script:channels = @(
            [pscustomobject]@{ Id = "general"; DisplayName = "General"; MembershipType = "standard" }
            [pscustomobject]@{ Id = "leadership"; DisplayName = "Leadership Governance"; MembershipType = "shared" }
            [pscustomobject]@{ Id = "program"; DisplayName = "Program Governance"; MembershipType = "shared" }
        )
        $script:common = @{
            SiteUrl = $script:parent
            TeamId = $script:teamId
            OwnerUPN = $script:owner
            OrganizationEmailDomains = @("example.edu")
            AdditionalAllowedMembers = @()
            Connection = "offline"
        }
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Get-PnPTenantSite {
            if (-not $script:siteModes.ContainsKey($Identity)) { throw "Unexpected site '$Identity'" }
            [pscustomobject]@{ SharingCapability = $script:siteModes[$Identity]; DisableSharingForNonOwnersStatus = $script:nonOwnerDisabled[$Identity] }
        }
        Mock Set-PnPTenantSite { $script:siteModes[$Identity] = $SharingCapability }
        Mock Set-CoENonOwnerSharingDisabled { $script:nonOwnerDisabled[$SiteUrl] = $true }
        Mock Get-PnPTenantId { $script:tenantId }
        Mock Get-PnPAccessToken {
            [pscustomobject]@{ Claims = @([pscustomobject]@{ Type = "tid"; Value = $script:tenantId }) }
        }
        Mock Get-PnPTeamsTeam { [pscustomobject]@{ Visibility = "Private" } }
        Mock Get-PnPTeamsChannel { $script:channels }
        Mock Get-PnPTeamsChannelUser {
            @([pscustomobject]@{ Email = $script:owner }, [pscustomobject]@{ Email = "preview@external.edu" })
        }
        Mock Get-PnPTeamsChannelFilesFolder {
            [pscustomobject]@{ webUrl = "https://example.sharepoint.com/sites/$Channel/Shared%20Documents" }
        }
        Mock Get-PnPExternalUser {
            if ($SiteUrl -eq $script:parent) { [pscustomobject]@{ Email = "preview@external.edu" } }
        }
        Mock Invoke-PnPGraphMethod { throw "Unexpected Graph URL '$Url'" }
        Mock Invoke-PnPGraphMethod {
            [pscustomobject]@{ id = $script:ownerId; userPrincipalName = $script:owner; userType = "Member" }
        } -ParameterFilter { $Url -like "v1.0/users/*" }
        Mock Invoke-PnPGraphMethod {
            [pscustomobject]@{ id = $script:teamId }
        } -ParameterFilter { $Url -like "v1.0/groups/*" }
        Mock Invoke-PnPGraphMethod {
            @{ value = @(@{ id = $script:teamId; tenantId = $script:tenantId; isHostTeam = $true; displayName = "CoE" }) }
        } -ParameterFilter { $Url -like "*/sharedWithTeams*" }
        Mock Invoke-PnPGraphMethod {
            @{ value = @(@{ userId = $script:ownerId; tenantId = $script:tenantId; Email = $script:owner }) }
        } -ParameterFilter { $Url -like "*/allMembers" }
    }

    It "defaults missing settings to internal-only customer access" {
        (Get-CoEParentSharingCapability $null) | Should Be "Disabled"
        (Get-CoEParentSharingCapability ([pscustomobject]@{})) | Should Be "Disabled"
    }
    It "reports null account type as an unreadable identity, not a guest" {
        $identity = [pscustomobject]@{ id = $script:ownerId; userType = $null }
        { Assert-CoEMemberIdentity -Identity $identity -Address $script:owner } | Should Throw "User.Read.All"
    }
    It "reports missing account type with permission guidance" {
        $identity = [pscustomobject]@{ id = $script:ownerId }
        { Assert-CoEMemberIdentity -Identity $identity -Address $script:owner } | Should Throw "User.ReadBasic.All cannot read userType"
    }
    It "still rejects a confirmed guest identity" {
        $identity = [pscustomobject]@{ id = $script:ownerId; userType = "Guest" }
        { Assert-CoEMemberIdentity -Identity $identity -Address $script:owner } | Should Throw "not a Member account"
    }
    It "rejects a Member identity without an immutable user ID" {
        $identity = [pscustomobject]@{ userType = "Member" }
        { Assert-CoEMemberIdentity -Identity $identity -Address $script:owner } | Should Throw "valid immutable user ID"
    }
    It "requests the permission required to read other users' account type" {
        $text = Get-Content -LiteralPath (Join-Path $kitRoot "01_Register-CoEProvisioningApp.ps1") -Raw
        $text | Should Match 'GraphDelegatePermissions\s*=\s*@\([^)]*"User.Read.All"'
        $text | Should Not Match '"User.ReadBasic.All"'
    }
    It "sets member-sharing restrictions on WebSettings rather than SiteCollection" {
        $text = Get-Content -LiteralPath (Join-Path $kitRoot "Internal\Prepare-CopilotCoE.ps1") -Raw
        $text | Should Match '\$webSettings\.SetAttribute\("MembersCanShare", "false"\)'
        $text | Should Match '\$siteCollection\.RemoveAttribute\("MembersCanShare"\)'
        $text | Should Not Match '\$siteCollection\.SetAttribute\("MembersCanShare"'
        $text | Should Match 'Read-PnPTenantTemplate -Path \$packageOutput -ErrorAction Stop'
    }
    It "honors each supported explicit setting" {
        foreach ($mode in @("Disabled", "ExistingExternalUserSharingOnly", "ExternalUserSharingOnly")) {
            (Get-CoEParentSharingCapability ([pscustomobject]@{ CoESiteSharingCapability = $mode })) | Should Be $mode
        }
    }
    It "rejects anonymous sharing, typos and explicit empty settings" {
        foreach ($mode in @("ExternalUserAndGuestSharing", "Anyone", "", $null)) {
            { Get-CoEParentSharingCapability ([pscustomobject]@{ CoESiteSharingCapability = $mode }) } | Should Throw
        }
    }
    It "does not rewrite a site already matching the policy" {
        $null = Set-CoESiteSharing -SiteUrl $script:parent -SharingCapability ExistingExternalUserSharingOnly -Connection offline
        Assert-MockCalled Set-PnPTenantSite -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-CoENonOwnerSharingDisabled -Times 0 -Exactly -Scope It
    }
    It "applies existing guests without allowing anonymous or non-owner sharing" {
        $script:siteModes[$script:parent] = "Disabled"
        $script:nonOwnerDisabled[$script:parent] = $false
        $site = Set-CoESiteSharing -SiteUrl $script:parent -SharingCapability ExistingExternalUserSharingOnly -Connection offline
        $site.SharingCapability | Should Be "ExistingExternalUserSharingOnly"
        Assert-MockCalled Set-PnPTenantSite -Times 1 -Exactly -Scope It -ParameterFilter {
            $SharingCapability -eq "ExistingExternalUserSharingOnly" -and -not $DisableSharingForNonOwners -and $Wait
        }
        Assert-MockCalled Set-CoENonOwnerSharingDisabled -Times 1 -Exactly -Scope It -ParameterFilter { $SiteUrl -eq $script:parent }
        $site.DisableSharingForNonOwnersStatus | Should Be $true
    }
    It "repairs non-owner sharing without changing an already matching sharing mode" {
        $script:nonOwnerDisabled[$script:parent] = $false
        $site = Set-CoESiteSharing -SiteUrl $script:parent -SharingCapability ExistingExternalUserSharingOnly -Connection offline
        $site.DisableSharingForNonOwnersStatus | Should Be $true
        Assert-MockCalled Set-PnPTenantSite -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-CoENonOwnerSharingDisabled -Times 1 -Exactly -Scope It
    }
    It "propagates owner-only sharing write failures" {
        $script:nonOwnerDisabled[$script:parent] = $false
        Mock Set-CoENonOwnerSharingDisabled { throw "Sharing write failed" }
        { Set-CoESiteSharing -SiteUrl $script:parent -SharingCapability ExistingExternalUserSharingOnly -Connection offline } | Should Throw "Sharing write failed"
    }
    It "explicitly submits the CSOM owner-only restriction on the requested connection" {
        $text = Get-Content -LiteralPath (Join-Path $kitRoot "Internal\SecurityPosture.ps1") -Raw
        $text | Should Match '(?s)function Set-CoENonOwnerSharingDisabled.*?Get-PnPContext -Connection \$Connection.*?DisableSharingForNonOwnersOfSite\(\$SiteUrl\).*?Invoke-PnPQuery -Connection \$Connection -ErrorAction Stop'
    }
    It "stops if a site refuses the requested sharing mode" {
        $script:siteModes[$script:parent] = "Disabled"
        Mock Set-PnPTenantSite {}
        { Set-CoESiteSharing -SiteUrl $script:parent -SharingCapability ExistingExternalUserSharingOnly -Connection offline } | Should Throw
    }
    It "stops if non-owner sharing remains enabled" {
        Mock Get-PnPTenantSite {
            [pscustomobject]@{ SharingCapability = "ExistingExternalUserSharingOnly"; DisableSharingForNonOwnersStatus = $false }
        }
        { Set-CoESiteSharing -SiteUrl $script:parent -SharingCapability ExistingExternalUserSharingOnly -Connection offline } | Should Throw
    }
    It "allows named parent Team guests but reports them for review" {
        $roster = Get-CoETeamRoster -TeamId $script:teamId -Channels $script:channels -OrganizationEmailDomains example.edu -Connection offline
        $roster.Passed | Should Be $true
        $roster.External.Count | Should Be 1
        $results = @(Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels -CoESiteSharingCapability ExistingExternalUserSharingOnly)
        $results.Count | Should Be 2
        $script:siteModes[$script:parent] | Should Be "ExistingExternalUserSharingOnly"
        $script:siteModes["https://example.sharepoint.com/sites/Leadership"] | Should Be "Disabled"
    }
    It "still rejects parent members with no returned identity" {
        Mock Get-PnPTeamsChannelUser { [pscustomobject]@{ DisplayName = "Unknown" } }
        { Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels } | Should Throw
    }
    It "keeps Disabled on repeated runs even when guests remain Team members" {
        $null = Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels -CoESiteSharingCapability Disabled
        $null = Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels -CoESiteSharingCapability Disabled
        $script:siteModes[$script:parent] | Should Be "Disabled"
        Assert-MockCalled Set-PnPTenantSite -Times 1 -Exactly -Scope It -ParameterFilter { $SharingCapability -eq "Disabled" }
    }
    It "supports the explicit new-and-existing-guests setting without opening governance" {
        $null = Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels -CoESiteSharingCapability ExternalUserSharingOnly
        $script:siteModes[$script:parent] | Should Be "ExternalUserSharingOnly"
        $script:siteModes["https://example.sharepoint.com/sites/Leadership"] | Should Be "Disabled"
        $script:siteModes["https://example.sharepoint.com/sites/Program"] | Should Be "Disabled"
    }
    It "defaults initialization to Disabled and never raises an internal-only site on rerun" {
        $null = Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels
        $null = Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels
        $script:siteModes[$script:parent] | Should Be "Disabled"
        Assert-MockCalled Set-PnPTenantSite -Times 1 -Exactly -Scope It -ParameterFilter { $SharingCapability -eq "Disabled" }
        Assert-MockCalled Set-PnPTenantSite -Times 0 -Exactly -Scope It -ParameterFilter { $SharingCapability -ne "Disabled" }
    }
    It "rejects a guest identity in the governance allowlist" {
        Mock Invoke-PnPGraphMethod {
            [pscustomobject]@{ id = $script:ownerId; userPrincipalName = $script:owner; userType = "Guest" }
        } -ParameterFilter { $Url -like "v1.0/users/*" }
        { Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels } | Should Throw "not a Member account"
    }
    It "rejects unapproved effective governance members" {
        Mock Invoke-PnPGraphMethod {
            @{ value = @(
                @{ userId = $script:ownerId; tenantId = $script:tenantId; Email = $script:owner }
                @{ userId = "44444444-4444-4444-4444-444444444444"; tenantId = $script:tenantId; Email = "unapproved@example.edu" }
            ) }
        } -ParameterFilter { $Url -like "*/allMembers" }
        { Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels } | Should Throw "outside the approved identity allowlist"
    }
    It "rejects external-user entries on governance sites" {
        Mock Get-PnPExternalUser { [pscustomobject]@{ Email = "preview@external.edu" } }
        { Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels } | Should Throw "external-user"
    }
    It "rejects cross-tenant governance membership even with an allowlisted user ID" {
        Mock Invoke-PnPGraphMethod {
            @{ value = @(@{ userId = $script:ownerId; tenantId = "55555555-5555-5555-5555-555555555555"; Email = $script:owner }) }
        } -ParameterFilter { $Url -like "*/allMembers" }
        { Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels } | Should Throw "not verified in the host tenant"
    }
    It "verifies an unshared channel even when sharedWithTeams omits the host" {
        Mock Invoke-PnPGraphMethod { @{ value = @() } } -ParameterFilter { $Url -like "*/sharedWithTeams*" }
        $results = @(Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels)
        $results.Count | Should Be 2
        $results[0].SharedTeamCount | Should Be 0
        $results[0].HostTenantId | Should Be $script:tenantId
    }
    It "still rejects a foreign member when the sharedWithTeams list is empty" {
        Mock Invoke-PnPGraphMethod { @{ value = @() } } -ParameterFilter { $Url -like "*/sharedWithTeams*" }
        Mock Invoke-PnPGraphMethod {
            @{ value = @(@{ userId = $script:ownerId; tenantId = "55555555-5555-5555-5555-555555555555"; Email = $script:owner }) }
        } -ParameterFilter { $Url -like "*/allMembers" }
        { Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels } | Should Throw "not verified in the host tenant"
    }
    It "rejects mismatched Graph and SharePoint connection tenants" {
        Mock Get-PnPAccessToken {
            [pscustomobject]@{ Claims = @([pscustomobject]@{ Type = "tid"; Value = "55555555-5555-5555-5555-555555555555" }) }
        }
        { Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels } | Should Throw "connection tenant does not match"
    }
    It "rejects an unverified host group ID" {
        Mock Invoke-PnPGraphMethod { [pscustomobject]@{ id = "55555555-5555-5555-5555-555555555555" } } -ParameterFilter { $Url -like "v1.0/groups/*" }
        { Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels } | Should Throw "host Team group ID"
    }
    It "rejects a returned host relationship with a different tenant" {
        Mock Invoke-PnPGraphMethod {
            @{ value = @(@{ id = $script:teamId; tenantId = "55555555-5555-5555-5555-555555555555"; isHostTeam = $true; displayName = "CoE" }) }
        } -ParameterFilter { $Url -like "*/sharedWithTeams*" }
        { Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels } | Should Throw "returned host Team tenant ID"
    }
    It "rejects governance channels shared with another Team" {
        Mock Invoke-PnPGraphMethod {
            @{ value = @(
                @{ id = $script:teamId; tenantId = $script:tenantId; isHostTeam = $true; displayName = "CoE" }
                @{ id = "66666666-6666-6666-6666-666666666666"; tenantId = $script:tenantId; isHostTeam = $false; displayName = "Other" }
            ) }
        } -ParameterFilter { $Url -like "*/sharedWithTeams*" }
        { Initialize-CoEGovernanceSecurity @script:common -Channels $script:channels } | Should Throw "shared with another Team"
    }
    It "resolves governance site URLs in the final report and prints WHY and durable shutdown steps" {
        Write-CoESecurityPosture @script:common -ExpectedVisibility Private -CoESiteSharingCapability ExistingExternalUserSharingOnly -SettingsPath "C:\Org\Deployment-Settings.json"
        Assert-MockCalled Get-PnPTenantSite -Times 1 -Exactly -Scope It -ParameterFilter { $Identity -eq "https://example.sharepoint.com/sites/leadership" }
        Assert-MockCalled Get-PnPTenantSite -Times 1 -Exactly -Scope It -ParameterFilter { $Identity -eq "https://example.sharepoint.com/sites/program" }
        Assert-MockCalled Write-Host -Times 1 -Scope It -ParameterFilter { "$Object" -like "*Parent site external sharing: ON (ExistingExternalUserSharingOnly)*" }
        Assert-MockCalled Write-Host -Times 1 -Scope It -ParameterFilter { "$Object" -like "*Leadership Governance external sharing: OFF (Disabled)*" }
        Assert-MockCalled Write-Host -Times 1 -Scope It -ParameterFilter { "$Object" -like "*WHY OFF by default:*" }
        Assert-MockCalled Write-Host -Times 1 -Scope It -ParameterFilter { "$Object" -like "*Never add preview guests to the Team*" }
        Assert-MockCalled Write-Host -Times 1 -Scope It -ParameterFilter { "$Object" -like "*TURN OFF now:*Only people in your organization*" }
        Assert-MockCalled Write-Host -Times 1 -Scope It -ParameterFilter { "$Object" -like "*KEEP IT OFF:*C:\Org\Deployment-Settings.json*" }
        Assert-MockCalled Write-Host -Times 1 -Scope It -ParameterFilter { "$Object" -like "*Set-PnPTenantSite*SharingCapability Disabled*" }
        Assert-MockCalled Write-Host -Times 1 -Scope It -ParameterFilter { "$Object" -like "*Reruns apply that setting*" }
        Assert-MockCalled Set-PnPTenantSite -Times 0 -Exactly -Scope It
    }
    It "prints OFF accurately when an admin has disabled parent-site sharing" {
        $script:siteModes[$script:parent] = "Disabled"
        Write-CoESecurityPosture @script:common -ExpectedVisibility Private
        Assert-MockCalled Write-Host -Times 1 -Scope It -ParameterFilter { "$Object" -like "*Parent site external sharing: OFF (Disabled)*" }
        Assert-MockCalled Write-Host -Times 1 -Scope It -ParameterFilter { "$Object" -like "*omitting it defaults to Disabled*" }
    }
    It "fails the final report on governance external users" {
        Mock Get-PnPExternalUser { [pscustomobject]@{ Email = "preview@external.edu" } }
        { Write-CoESecurityPosture @script:common -ExpectedVisibility Private -CoESiteSharingCapability ExistingExternalUserSharingOnly } | Should Throw
    }
    It "fails the final report on anonymous site sharing but still prints shutdown guidance" {
        $script:siteModes[$script:parent] = "ExternalUserAndGuestSharing"
        { Write-CoESecurityPosture @script:common -ExpectedVisibility Private } | Should Throw
        Assert-MockCalled Write-Host -Times 1 -Scope It -ParameterFilter { "$Object" -like "*TURN OFF now:*" }
    }
    It "fails the final report when the Team is public" {
        Mock Get-PnPTeamsTeam { [pscustomobject]@{ Visibility = "Public" } }
        { Write-CoESecurityPosture @script:common -ExpectedVisibility Private -CoESiteSharingCapability ExistingExternalUserSharingOnly } | Should Throw "security posture verification failed"
    }
    It "accepts singleton Graph collections and follows pagination" {
        Mock Invoke-PnPGraphMethod {
            if ($Url -eq "v1.0/test") {
                return @{ value = @{ id = "first" }; "@odata.nextLink" = "https://graph.microsoft.com/v1.0/test?skip=1" }
            }
            return @{ value = @(@{ id = "second" }) }
        }
        $items = @(Get-CoEGraphCollection -Url "v1.0/test" -GraphPathPrefix "/v1.0/test" -Connection offline -Description test)
        $items.Count | Should Be 2
        $items[1].id | Should Be "second"
    }
    It "rejects Graph responses missing a collection" {
        Mock Invoke-PnPGraphMethod { @{ unexpected = @() } }
        { Get-CoEGraphCollection -Url "v1.0/test" -GraphPathPrefix "/v1.0/test" -Connection offline -Description test } | Should Throw
    }
    It "ships the same private/internal-only defaults in both template settings files" {
        foreach ($relative in @("Deployment-Settings.json", "Org-Template\Deployment-Settings.json")) {
            $settings = Get-Content -LiteralPath (Join-Path $kitRoot $relative) -Raw | ConvertFrom-Json
            $settings.TeamVisibility | Should Be "Private"
            $settings.CoESiteSharingCapability | Should Be "Disabled"
        }
    }
    It "wires the selected sharing mode through install, completion and final reporting" {
        foreach ($relative in @("02_Install-CopilotCoE.ps1", "Internal\Complete-CopilotCoE.ps1")) {
            $text = Get-Content -LiteralPath (Join-Path $kitRoot $relative) -Raw
            $text | Should Match 'Get-CoEParentSharingCapability'
            $text | Should Match '(?s)Initialize-CoEGovernanceSecurity.*?-CoESiteSharingCapability'
            $text | Should Match '(?s)Write-CoESecurityPosture.*?-CoESiteSharingCapability.*?-SettingsPath'
            $text | Should Not Match 'Set-CoESiteSharingDisabled'
            $tokens = $null
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
            $errors.Count | Should Be 0
        }
    }
}
