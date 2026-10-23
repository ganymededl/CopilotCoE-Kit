#Requires -Version 7.4
<#
.SYNOPSIS
Creates the Entra ID app registration that the CoE installer uses to sign in.

.DESCRIPTION
Run once per tenant as an approved consent approver authorized to register the
application and grant tenant-wide admin consent. Use just-in-time privileged
access and remove the elevated role after setup.

The app is single-tenant, public-client (no secret or certificate), uses the
http://localhost redirect for interactive/device sign-in, and requests only the
delegated permissions the installer needs:
  Microsoft Graph : Group.ReadWrite.All, ChannelMember.ReadWrite.All, User.Read,
                    User.Read.All (verifies governance users' Member/Guest account type)
  SharePoint      : AllSites.FullControl
Delegated means the app can only do what the signed-in administrator can do.

STEP 1 OF 3. Run this first, then 02_Install-CopilotCoE.ps1.
    .\01_Register-CoEProvisioningApp.ps1
The tenant is read from Deployment-Settings.json (or pass -Tenant). When it
finishes, the Application (client) ID is printed and written to PnPClientID in
Deployment-Settings.json, so you do not copy it by hand.
#>
[CmdletBinding()]
param(
    [string]$Tenant,

    [ValidateLength(3, 120)]
    [string]$ApplicationName = "Copilot CoE Provisioning (PnP)",

    [string]$OrgPath,
    [string]$SettingsPath,

    # Device-code sign-in is the default because it works with MFA and Conditional Access
    # prompts in any browser. Use -Interactive to sign in through a pop-up browser instead.
    [switch]$Interactive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module PnP.PowerShell -RequiredVersion 3.2.0 -ErrorAction Stop
. (Join-Path $PSScriptRoot "Internal\ProvisioningApp.ps1")
if ($OrgPath) {
    if (-not (Test-Path -LiteralPath $OrgPath -PathType Container)) { throw "Organization folder not found: $OrgPath" }
    if (-not $SettingsPath) { $SettingsPath = Join-Path (Resolve-Path -LiteralPath $OrgPath).Path "Deployment-Settings.json" }
}
if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "Deployment-Settings.json" }

if ($SettingsPath -and -not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
    throw "Settings file not found: $SettingsPath"
}
if ([string]::IsNullOrWhiteSpace($Tenant) -and $SettingsPath) {
    $Tenant = [string](Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json).Tenant
}
if ($Tenant -notmatch "^[A-Za-z0-9-]+\.onmicrosoft\.com$") {
    throw "Set Tenant in $SettingsPath (or pass -Tenant) to your yourtenant.onmicrosoft.com domain before registering the app."
}

Write-Host "Registering '$ApplicationName' in $Tenant."
Write-Host "Sign in as the approved consent approver, using just-in-time admin access, then accept the admin-consent prompt for the listed permissions."
$registration = @{
    ApplicationName               = $ApplicationName
    Tenant                        = $Tenant
    GraphDelegatePermissions      = @("Group.ReadWrite.All", "ChannelMember.ReadWrite.All", "User.Read", "User.Read.All")
    SharePointDelegatePermissions = @("AllSites.FullControl")
}
if (-not $Interactive) { $registration.DeviceLogin = $true }
$output = @(Register-PnPEntraIDAppForInteractiveLogin @registration)

$guidPattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
$clientId = $null
foreach ($item in $output) {
    $candidates = @($item.PSObject.Properties | Where-Object { [string]$_.Value -match $guidPattern })
    $preferred = @($candidates | Where-Object Name -match "ClientId|AppId")
    $pick = if ($preferred.Count -gt 0) { $preferred[0] } elseif ($candidates.Count -eq 1) { $candidates[0] } else { $null }
    if ($pick) { $clientId = [string]$pick.Value; break }
}
if (-not $clientId) {
    Write-Host "Open Entra admin center > App registrations > All applications > '$ApplicationName' and copy the Application (client) ID."
    $clientId = (Read-Host "Paste the Application (client) ID").Trim()
}
if ($clientId -notmatch $guidPattern) {
    throw "'$clientId' is not an Application (client) ID GUID. Re-run after copying it from Entra admin center."
}

# Admin consent is not always completed during registration. Confirm it explicitly.
$consentUrl = "https://login.microsoftonline.com/$Tenant/adminconsent?client_id=$clientId"
Write-Host ""
Write-Host "CONFIRM ADMIN CONSENT (required once):"
Write-Host "  Entra admin center > App registrations > $ApplicationName > API permissions."
Write-Host "  If any permission shows 'Not granted', select 'Grant admin consent for <your organization>' and Yes."
Write-Host "  Or open this link as an approved consent approver with admin-consent authority: $consentUrl"
Write-Host "All five permissions must show 'Granted' before running .\02_Install-CopilotCoE.ps1."

if ($SettingsPath) {
    $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
    $settings.PnPClientID = $clientId
    $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $SettingsPath -Encoding utf8
    Write-Host "Saved PnPClientID to $SettingsPath"
}

Assert-CoEProvisioningAppPublicClient -Tenant $Tenant -ClientId $clientId

[pscustomobject]@{
    ApplicationName = $ApplicationName
    Tenant          = $Tenant
    ClientId        = $clientId
    AdminConsentUrl = $consentUrl
    NextStep        = "Confirm Allow public client flows is Yes and all five permissions show Granted, then run .\02_Install-CopilotCoE.ps1 -SeedDemoContent."
}
