# Offline tests: Windows PowerShell / installed Pester 3; deployment uses PowerShell 7.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "New-CoETestFixture.ps1")
$kitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $kitRoot "Internal\AdoptionCatalogs.ps1")
. (Join-Path $kitRoot "Internal\HubExperience.ps1")
. (Join-Path $kitRoot "Internal\OperatorAdvisories.ps1")
. (Join-Path $kitRoot "Internal\TenantPreflight.ps1")

# A stand-in so a missing mock fails closed instead of reaching a tenant.
function Invoke-PnPGraphMethod {
    [CmdletBinding()] param($Url, $Method, $Connection, $AdditionalHeaders)
    throw "Unmocked Graph request: $Url"
}

$globalAdmin = "62e90394-69f5-4237-9190-012177145e10"
$userAdmin = "fe930be7-5e62-47db-91af-98c3a49a38b1"
$teamsAdmin = "69091246-20e8-4a56-aa4d-066075b2a7a8"

function New-PolicyResponse([string]$PrefixSuffix, [string]$Blocked = "", [string]$Template = "Group.Unified") {
    @{ value = @(@{ displayName = $Template; values = @(
        @{ name = "PrefixSuffixNamingRequirement"; value = $PrefixSuffix },
        @{ name = "CustomBlockedWordsList"; value = $Blocked }) }) }
}

Describe "Reading the group naming policy" {
    It "parses the prefix/suffix and blocked words of the Microsoft 365 group template" {
        Mock Invoke-PnPGraphMethod { New-PolicyResponse "GRP_[GroupName]_Eng" "Payroll,CEO" }
        $policy = Get-CoEGroupNamingPolicy -Connection "offline"
        $policy.Verified | Should Be $true
        $policy.PrefixSuffix | Should Be "GRP_[GroupName]_Eng"
        $policy.BlockedWords | Should Be "Payroll,CEO"
    }
    It "treats a tenant with no policy as verified and empty" {
        Mock Invoke-PnPGraphMethod { @{ value = @() } }
        $policy = Get-CoEGroupNamingPolicy -Connection "offline"
        $policy.Verified | Should Be $true
        $policy.PrefixSuffix | Should Be ""
    }
    It "ignores settings that belong to another template" {
        Mock Invoke-PnPGraphMethod { New-PolicyResponse "SHOULD-NOT-APPLY" "" "Application" }
        (Get-CoEGroupNamingPolicy -Connection "offline").PrefixSuffix | Should Be ""
    }
    It "reports unverified rather than failing when the read is denied" {
        Mock Invoke-PnPGraphMethod { throw "Forbidden (403)" }
        $policy = Get-CoEGroupNamingPolicy -Connection "offline"
        $policy.Verified | Should Be $false
        $policy.Detail | Should Match "403"
    }
}

Describe "Identifying the signed-in operator" {
    It "finds an exempt role" {
        Mock Invoke-PnPGraphMethod { @{ id = "u1"; userPrincipalName = "ops@example.org" } } -ParameterFilter { $Url -like "v1.0/me?*" }
        Mock Invoke-PnPGraphMethod { @{ value = @(@{ roleTemplateId = $teamsAdmin }, @{ roleTemplateId = $userAdmin }) } } -ParameterFilter { $Url -like "*directoryRole*" }
        $operator = Get-CoEOperatorIdentity -Connection "offline"
        $operator.ExemptRole | Should Be "User Administrator"
        $operator.RolesVerified | Should Be $true
    }
    It "does not treat Teams or SharePoint administrators as exempt" {
        Mock Invoke-PnPGraphMethod { @{ id = "u1"; userPrincipalName = "ops@example.org" } } -ParameterFilter { $Url -like "v1.0/me?*" }
        Mock Invoke-PnPGraphMethod { @{ value = @(@{ roleTemplateId = $teamsAdmin }, @{ roleTemplateId = "f28a1f50-f6e7-4571-818b-6a12f2af6b6c" }) } } -ParameterFilter { $Url -like "*directoryRole*" }
        (Get-CoEOperatorIdentity -Connection "offline").ExemptRole | Should Be ""
    }
    It "marks the roles unverified when they cannot be read" {
        Mock Invoke-PnPGraphMethod { @{ id = "u1"; userPrincipalName = "ops@example.org" } } -ParameterFilter { $Url -like "v1.0/me?*" }
        Mock Invoke-PnPGraphMethod { throw "Forbidden" } -ParameterFilter { $Url -like "*directoryRole*" }
        $operator = Get-CoEOperatorIdentity -Connection "offline"
        $operator.RolesVerified | Should Be $false
        $operator.ExemptRole | Should Be ""
    }
}

Describe "Tenant preflight before anything is created" {
    BeforeEach {
        $script:context = [pscustomobject]@{ Tenant = "t.onmicrosoft.com"; SiteFQDN = "t.sharepoint.com"; TeamAlias = "coe" }
        $script:operator = [pscustomobject]@{ Id = "op-id"; UserPrincipalName = "ops@t.onmicrosoft.com"; ExemptRole = ""; RolesVerified = $true }
        $script:policy = [pscustomobject]@{ Verified = $true; PrefixSuffix = ""; BlockedWords = ""; Detail = "" }
        Mock Get-CoEOperatorIdentity { $script:operator }
        Mock Get-CoEGroupNamingPolicy { $script:policy }
        Mock Confirm-CoEAdvisory {}
        Mock Write-Warning {}
        Mock Write-Host {}
        $script:call = @{ Connection = "offline"; AdvisoryContext = $context; Alias = "CoE"; OwnerUserId = "op-id"; OwnerUserPrincipalName = "ops@t.onmicrosoft.com" }
    }
    It "stays silent for the validated case: no policy and the owner is the operator" {
        Invoke-CoETenantPreflight @call
        Assert-MockCalled Confirm-CoEAdvisory -Times 0 -Exactly -Scope It
    }
    It "asks before creating anything when an alias-rewriting policy applies to a non-exempt operator" {
        $script:policy.PrefixSuffix = "GRP_[GroupName]"
        Invoke-CoETenantPreflight @call
        Assert-MockCalled Confirm-CoEAdvisory -Times 1 -Exactly -Scope It -ParameterFilter {
            $Id -eq "GroupNamingPolicy" -and $Message -match "names AND aliases" -and
                "policy=GRP_[GroupName]" -in $Facts -and "operator=ops@t.onmicrosoft.com" -in $Facts
        }
    }
    It "does not ask when the operator holds an exempt role" {
        $script:policy.PrefixSuffix = "GRP_[GroupName]"
        $script:operator.ExemptRole = "Global Administrator"
        Invoke-CoETenantPreflight @call
        Assert-MockCalled Confirm-CoEAdvisory -Times 0 -Exactly -Scope It
    }
    It "says so plainly when it could not verify the operator's roles" {
        $script:policy.PrefixSuffix = "GRP_[GroupName]"
        $script:operator.RolesVerified = $false
        Invoke-CoETenantPreflight @call
        Assert-MockCalled Confirm-CoEAdvisory -Times 1 -Exactly -Scope It -ParameterFilter { $Message -match "could not be verified" }
    }
    It "only warns when the policy itself cannot be read, so a missing permission never blocks an install" {
        $script:policy.Verified = $false
        $script:policy.Detail = "403"
        Invoke-CoETenantPreflight @call
        Assert-MockCalled Confirm-CoEAdvisory -Times 0 -Exactly -Scope It
        Assert-MockCalled Write-Warning -Times 1 -Exactly -Scope It -ParameterFilter { $Message -match "naming policy could not be read" }
    }
    It "does not treat a blocked-word list alone as an alias rewrite" {
        $script:policy.BlockedWords = "Payroll"
        Invoke-CoETenantPreflight @call
        Assert-MockCalled Confirm-CoEAdvisory -Times 0 -Exactly -Scope It
    }
    It "asks when the governance owner is a different account from the one running the install" {
        $call.OwnerUserId = "someone-else"
        $call.OwnerUserPrincipalName = "owner@t.onmicrosoft.com"
        Invoke-CoETenantPreflight @call
        Assert-MockCalled Confirm-CoEAdvisory -Times 1 -Exactly -Scope It -ParameterFilter {
            $Id -eq "OwnerDiffersFromOperator" -and $Message -match "no other administrator is added" -and
                "owner=owner@t.onmicrosoft.com" -in $Facts -and "operator=ops@t.onmicrosoft.com" -in $Facts
        }
    }
    It "does not reuse an approval when the owner and operator roles are reversed" {
        $first = Get-CoEAdvisoryKey -Context $context -Id OwnerDiffersFromOperator `
            -Facts @("owner=alice@t.onmicrosoft.com", "operator=bob@t.onmicrosoft.com")
        $reversed = Get-CoEAdvisoryKey -Context $context -Id OwnerDiffersFromOperator `
            -Facts @("owner=bob@t.onmicrosoft.com", "operator=alice@t.onmicrosoft.com")
        $first.Fingerprint | Should Not Be $reversed.Fingerprint
    }
    It "compares account IDs case-insensitively" {
        $script:operator.Id = "ABC-123"
        $call.OwnerUserId = "abc-123"
        Invoke-CoETenantPreflight @call
        Assert-MockCalled Confirm-CoEAdvisory -Times 0 -Exactly -Scope It
    }
    It "skips with a warning, without prompting, when the operator cannot be identified" {
        Mock Get-CoEOperatorIdentity { throw "Forbidden" }
        Invoke-CoETenantPreflight @call
        Assert-MockCalled Confirm-CoEAdvisory -Times 0 -Exactly -Scope It
        Assert-MockCalled Write-Warning -Times 1 -Exactly -Scope It -ParameterFilter { $Message -match "skipped" }
    }
    It "lets a declined advisory stop the run" {
        $script:policy.PrefixSuffix = "GRP_[GroupName]"
        Mock Confirm-CoEAdvisory { throw "Operator selected STOP" }
        Get-CoETestExceptionMessage { Invoke-CoETenantPreflight @call } | Should Match "Operator selected STOP"
    }
}

Describe "The failure when the created Team cannot be found by alias" {
    It "tells the administrator not to rerun and lists the group that was actually created" {
        Mock Invoke-PnPGraphMethod { @{ value = @(@{ id = "g1"; displayName = "GRP_ Coe"; mailNickname = "GRP_coe" }) } }
        $message = Get-CoEAliasNotFoundMessage -Connection "offline" -Alias "coe" -DisplayName "Coe" -LookupError ""
        $message | Should Match "Do NOT run 02_Install-CopilotCoE.ps1 again"
        $message | Should Match "naming policy"
        $message | Should Match "GRP_coe"
        $message | Should Match "g1"
    }
    It "still gives the guidance when nothing matches or the search is denied" {
        Mock Invoke-PnPGraphMethod { @{ value = @() } }
        (Get-CoEAliasNotFoundMessage -Connection "offline" -Alias "coe" -DisplayName "Coe") | Should Match "No group matching"
        Mock Invoke-PnPGraphMethod { throw "Forbidden" }
        $message = Get-CoEAliasNotFoundMessage -Connection "offline" -Alias "coe" -DisplayName "Coe" -LookupError "not found"
        $message | Should Match "could not be searched"
        $message | Should Match "Lookup error: not found"
        $message | Should Match "Do NOT run"
    }
}

Describe "Install wiring" {
    BeforeEach { $script:install = Get-Content -LiteralPath (Join-Path $kitRoot "02_Install-CopilotCoE.ps1") -Raw }
    It "runs the preflight after identity checks and before any group lookup or template" {
        $preflight = $install.IndexOf("Invoke-CoETenantPreflight")
        $preflight | Should BeGreaterThan $install.IndexOf("Assert-CoEMemberIdentity -Identity `$ownerIdentity")
        $preflight | Should BeLessThan $install.IndexOf("Get-PnPMicrosoft365Group ``")
        $preflight | Should BeLessThan $install.IndexOf("Invoke-PnPTenantTemplate")
    }
    It "no longer reports a missing group with the old generic message" {
        $install | Should Not Match 'completed without returning the expected Microsoft 365 group\.'
        $install | Should Match 'Get-CoEAliasNotFoundMessage'
    }
    It "loads the helper" {
        $install | Should Match 'Internal\\TenantPreflight\.ps1'
    }
    It "accepts the two new advisory identities" {
        $context = [pscustomobject]@{ Path = (Join-Path $TestDrive "d.json"); Tenant = "t"; SiteFQDN = "s"; TeamAlias = "a" }
        Mock Read-Host { "PROCEED" }
        Mock Write-Host {}
        Mock Write-Warning {}
        foreach ($id in @("GroupNamingPolicy", "OwnerDiffersFromOperator")) {
            Confirm-CoEAdvisory -Context $context -Id $id -Message "m" -Facts @($id)
        }
        (Get-Content -LiteralPath $context.Path -Raw | ConvertFrom-Json).Decisions.Count | Should Be 2
    }
}
