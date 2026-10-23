# Offline tests: Windows PowerShell / installed Pester 3; deployment uses PowerShell 7.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "New-CoETestFixture.ps1")
$kitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $kitRoot "Internal\ProvisioningApp.ps1")

$tenant = "t.onmicrosoft.com"
$clientId = "11111111-2222-3333-4444-555555555555"

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
