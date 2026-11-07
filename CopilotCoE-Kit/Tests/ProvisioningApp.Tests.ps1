# Offline tests: Windows PowerShell / installed Pester 3; deployment uses PowerShell 7.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "New-CoETestFixture.ps1")
$kitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $kitRoot "Internal\ProvisioningApp.ps1")

$tenant = "t.onmicrosoft.com"
$clientId = "11111111-2222-3333-4444-555555555555"
function Get-PnPAccessToken {
    [CmdletBinding()]
    param([switch]$ListPermissionScopes, [string]$ResourceTypeName, $Connection)
    throw "Unexpected token inspection"
}
function New-CoETestAccessToken([string[]]$Scopes) {
    $json = @{ scp = ($Scopes -join " ") } | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd("=").Replace("+", "-").Replace("/", "_")
    return "header.$payload.signature"
}

Describe "Provisioning app public-client prerequisite" {
    BeforeEach {
        Mock Write-Host {}
        Mock Invoke-RestMethod { [pscustomobject]@{ device_code = "discarded-probe-code" } }
    }
    It "proves the configured app can start a public-client authorization flow" {
        Assert-CoEProvisioningAppPublicClient -Tenant $tenant -ClientId $clientId
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly -Scope It -ParameterFilter {
            $Uri -eq "https://login.microsoftonline.com/t.onmicrosoft.com/oauth2/v2.0/devicecode" -and
                $Method -eq "Post" -and $Body.client_id -eq $clientId -and $Body.scope -match "openid"
        }
    }
    It "stops with the exact Entra setting when public client flow is disabled" {
        Mock Invoke-RestMethod { throw "AADSTS7000218: request must contain client_assertion or client_secret" }
        $message = Get-CoETestExceptionMessage {
            Assert-CoEProvisioningAppPublicClient -Tenant $tenant -ClientId $clientId
        }
        $message | Should Match "Allow public client flows"
        $message | Should Match "Nothing was created or changed"
    }
    It "distinguishes an app ID from another tenant" {
        Mock Invoke-RestMethod { throw "AADSTS700016: Application with identifier was not found in the directory" }
        Get-CoETestExceptionMessage {
            Assert-CoEProvisioningAppPublicClient -Tenant $tenant -ClientId $clientId
        } | Should Match "was not found in tenant.*01_Register-CoEProvisioningApp"
    }
    It "warns and continues when the endpoint cannot verify the setting" {
        Mock Invoke-RestMethod { throw "The remote name could not be resolved" }
        Mock Write-Warning {}
        { Assert-CoEProvisioningAppPublicClient -Tenant $tenant -ClientId $clientId } | Should Not Throw
        Assert-MockCalled Write-Warning -Times 1 -Exactly -Scope It -ParameterFilter {
            $Message -match "Could not verify" -and $Message -match "Allow public client flows"
        }
    }
    It "warns and continues when a policy blocks the probe request" {
        Mock Invoke-RestMethod { throw "AADSTS53003: Access has been blocked by Conditional Access policies." }
        Mock Write-Warning {}
        { Assert-CoEProvisioningAppPublicClient -Tenant $tenant -ClientId $clientId } | Should Not Throw
        Assert-MockCalled Write-Warning -Times 1 -Exactly -Scope It
    }
    It "warns and continues on an unexpected success response" {
        Mock Invoke-RestMethod { [pscustomobject]@{ message = "no device code" } }
        Mock Write-Warning {}
        { Assert-CoEProvisioningAppPublicClient -Tenant $tenant -ClientId $clientId } | Should Not Throw
        Assert-MockCalled Write-Warning -Times 1 -Exactly -Scope It -ParameterFilter { $Message -match "unexpected response" }
    }
}

Describe "Public-client preflight wiring" {
    $register = Get-Content -LiteralPath (Join-Path $kitRoot "01_Register-CoEProvisioningApp.ps1") -Raw
    $install = Get-Content -LiteralPath (Join-Path $kitRoot "02_Install-CopilotCoE.ps1") -Raw
    $remove = Get-Content -LiteralPath (Join-Path $kitRoot "04_Remove-CopilotCoE.ps1") -Raw
    $checker = Get-Content -LiteralPath (Join-Path $kitRoot "Test-CoEInstall.ps1") -Raw
    $live = Get-Content -LiteralPath (Join-Path $kitRoot "Test-CoELiveRegression.ps1") -Raw
    $complete = Get-Content -LiteralPath (Join-Path $kitRoot "Internal\Complete-CopilotCoE.ps1") -Raw

    It "checks the app created by 01 after saving its ID" {
        $register.IndexOf("Assert-CoEProvisioningAppPublicClient") |
            Should BeGreaterThan $register.IndexOf("Saved PnPClientID")
    }
    It "declares the Teams app installation delegated scope and six-permission guidance" {
        $register | Should Match '"TeamsAppInstallation\.ReadWriteForTeam"'
        $register | Should Not Match 'TeamsAppInstallation\.ReadWriteForTeam\.All'
        $register | Should Match "All six permissions"
        $register | Should Match "grant admin consent again"
        $install | Should Match "all six app permissions"
    }
    It "checks granted token scopes immediately after the installer signs in" {
        $install.IndexOf("Assert-CoEProvisioningAppConsent -Connection `$adminConnection") |
            Should BeGreaterThan $install.IndexOf("`$adminConnection = Connect-PnPOnline")
        $install.IndexOf("Assert-CoEProvisioningAppConsent -Connection `$adminConnection") |
            Should BeLessThan $install.IndexOf("v1.0/users/")
    }
    foreach ($entry in @(
            @{ Name = "02 installer"; Text = $install },
            @{ Name = "04 remover"; Text = $remove },
            @{ Name = "site checker"; Text = $checker },
            @{ Name = "live regression"; Text = $live },
            @{ Name = "03 completion path"; Text = $complete }
        )) {
        It "$($entry.Name) checks public-client flow before PnP sign-in" {
            $entry.Text.IndexOf("Assert-CoEProvisioningAppPublicClient") | Should BeGreaterThan -1
            $entry.Text.IndexOf("Assert-CoEProvisioningAppPublicClient") |
                Should BeLessThan $entry.Text.IndexOf("Connect-PnPOnline")
        }
    }
}

Describe "Provisioning app consent prerequisite" {
    BeforeEach {
        Mock Write-Host {}
        Mock Get-PnPAccessToken {
            if ($ResourceTypeName -eq "Graph") {
                return New-CoETestAccessToken @("Group.ReadWrite.All", "ChannelMember.ReadWrite.All", "User.Read",
                    "User.Read.All", "TeamsAppInstallation.ReadWriteForTeam")
            }
            if ($ResourceTypeName -eq "SharePoint") { return New-CoETestAccessToken @("AllSites.FullControl") }
            throw "Unexpected resource"
        }
    }
    It "accepts all five Graph scopes and the SharePoint scope" {
        { Assert-CoEProvisioningAppConsent -Connection offline } | Should Not Throw
        Assert-MockCalled Get-PnPAccessToken -Times 1 -Exactly -Scope It -ParameterFilter {
            $ResourceTypeName -eq "Graph" -and $Connection -eq "offline"
        }
        Assert-MockCalled Get-PnPAccessToken -Times 1 -Exactly -Scope It -ParameterFilter {
            $ResourceTypeName -eq "SharePoint" -and $Connection -eq "offline"
        }
    }
    It "fails fast with re-consent guidance when the Teams scope is absent" {
        Mock Get-PnPAccessToken {
            if ($ResourceTypeName -eq "Graph") {
                return New-CoETestAccessToken @("Group.ReadWrite.All", "ChannelMember.ReadWrite.All", "User.Read", "User.Read.All")
            }
            return New-CoETestAccessToken @("AllSites.FullControl")
        }
        $message = Get-CoETestExceptionMessage { Assert-CoEProvisioningAppConsent -Connection offline }
        $message | Should Match "TeamsAppInstallation.ReadWriteForTeam"
        $message | Should Match "grant admin consent again"
        $message | Should Match "Nothing was created or changed"
    }
    It "fails closed when token scopes cannot be inspected" {
        Mock Get-PnPAccessToken { throw "token cache unavailable" }
        Get-CoETestExceptionMessage { Assert-CoEProvisioningAppConsent -Connection offline } |
            Should Match "could not be inspected.*all six permissions"
    }
    It "fails closed when a token has no delegated scope claim" {
        Mock Get-PnPAccessToken { return "header.e30.signature" }
        Get-CoETestExceptionMessage { Assert-CoEProvisioningAppConsent -Connection offline } |
            Should Match "no delegated scp claim"
    }
}
