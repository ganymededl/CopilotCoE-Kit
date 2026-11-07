# Dot-source from entry scripts before PnP authentication. The probe requests a device code but does not
# authenticate a user, grant consent, or change the app or tenant. It stops only on the two answers that prove a
# misconfiguration (public client flows disabled; app not in this tenant). Anything else is a warning, because a
# blocked or unreachable probe endpoint must not stop tenants whose policies restrict device-code requests.

function Assert-CoEProvisioningAppPublicClient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][string]$ClientId
    )

    if ($Tenant -notmatch "^[A-Za-z0-9-]+\.onmicrosoft\.com$") {
        throw "Tenant must look like yourtenant.onmicrosoft.com before the provisioning app can be checked."
    }
    if ($ClientId -notmatch "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$") {
        throw "PnPClientID must be the app's Application (client) ID GUID before the provisioning app can be checked."
    }

    $endpoint = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/devicecode"
    try {
        $response = Invoke-RestMethod -Uri $endpoint -Method Post -ContentType "application/x-www-form-urlencoded" `
            -Body @{ client_id = $ClientId; scope = "openid offline_access" } -TimeoutSec 30 -ErrorAction Stop
    } catch {
        $details = @()
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $details += [string]$_.ErrorDetails.Message }
        if ($_.Exception -and $_.Exception.Message) { $details += [string]$_.Exception.Message }
        $detail = (@($details | Select-Object -Unique) -join " ").Trim()

        if ($detail -match "AADSTS7000218|client_assertion|client_secret") {
            throw ("PnPClientID '$ClientId' is not enabled for public client authentication in tenant '$Tenant'. " +
                "In Entra admin center, open App registrations > All applications > the app > Authentication > Settings, " +
                "set 'Allow public client flows' to Yes, and save. This is required by the CoE PnP sign-in path. " +
                "Nothing was created or changed. Entra response: $detail")
        }
        if ($detail -match "AADSTS700016|Application with identifier.+was not found") {
            throw ("PnPClientID '$ClientId' was not found in tenant '$Tenant'. Copy the Application (client) ID from the " +
                "approved provisioning app in that tenant, or run 01_Register-CoEProvisioningApp.ps1 there. " +
                "Nothing was created or changed. Entra response: $detail")
        }
        # Any other response (network or proxy failure, a Conditional Access or authentication-flow policy, a
        # transient Entra error) does not prove the app is misconfigured. Warn and continue: every caller signs
        # in before it creates or changes anything, so a genuinely misconfigured app still stops at sign-in.
        Write-Warning ("Could not verify that PnPClientID '$ClientId' allows public client authentication in tenant " +
            "'$Tenant'; continuing to sign-in. If sign-in then fails with AADSTS7000218, open Entra admin center > " +
            "App registrations > All applications > the app > Authentication > Settings, set 'Allow public client flows' " +
            "to Yes, save, and rerun. Entra response: $detail")
        return
    }

    $deviceCode = if ($response -is [System.Collections.IDictionary] -and $response.Contains("device_code")) {
        [string]$response["device_code"]
    } elseif ($response -and $response.PSObject.Properties["device_code"]) {
        [string]$response.device_code
    } else { "" }
    if ([string]::IsNullOrWhiteSpace($deviceCode)) {
        Write-Warning ("Entra returned an unexpected response while checking public client authentication for PnPClientID " +
            "'$ClientId'; continuing to sign-in. If sign-in fails with AADSTS7000218, set 'Allow public client flows' to Yes " +
            "on the app's Authentication page in Entra admin center and rerun.")
        return
    }
    Write-Host "Provisioning app prerequisite passed: Entra accepted the public-client authentication probe."
}

function Get-CoEAccessTokenScopes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("Graph", "SharePoint")][string]$ResourceTypeName,
        [Parameter(Mandatory)][object]$Connection
    )
    $token = [string](Get-PnPAccessToken -ResourceTypeName $ResourceTypeName -Connection $Connection -ErrorAction Stop)
    $parts = @($token.Split("."))
    if ($parts.Count -lt 2 -or [string]::IsNullOrWhiteSpace($parts[1])) {
        throw "The $ResourceTypeName access token is not a JWT."
    }
    $payload = $parts[1].Replace("-", "+").Replace("_", "/")
    switch ($payload.Length % 4) {
        2 { $payload += "==" }
        3 { $payload += "=" }
        0 { }
        default { throw "The $ResourceTypeName access token payload has invalid base64url length." }
    }
    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        $claims = $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "The $ResourceTypeName access token payload could not be decoded. $($_.Exception.Message)"
    }
    if (-not $claims.PSObject.Properties["scp"] -or [string]::IsNullOrWhiteSpace([string]$claims.scp)) {
        throw "The $ResourceTypeName access token has no delegated scp claim."
    }
    return @(([string]$claims.scp -split '\s+') | Where-Object { $_ })
}

function Assert-CoEProvisioningAppConsent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Connection)

    $requiredGraph = @("Group.ReadWrite.All", "ChannelMember.ReadWrite.All", "User.Read", "User.Read.All",
        "TeamsAppInstallation.ReadWriteForTeam")
    $requiredSharePoint = @("AllSites.FullControl")
    try {
        $graphScopes = @(Get-CoEAccessTokenScopes -ResourceTypeName Graph -Connection $Connection)
        $sharePointScopes = @(Get-CoEAccessTokenScopes -ResourceTypeName SharePoint -Connection $Connection)
    } catch {
        throw "The provisioning app's granted delegated scopes could not be inspected after sign-in. Re-run 01_Register-CoEProvisioningApp.ps1 guidance and confirm all six permissions have admin consent. $($_.Exception.Message)"
    }

    $missingGraph = @($requiredGraph | Where-Object { $_ -notin $graphScopes })
    $missingSharePoint = @($requiredSharePoint | Where-Object { $_ -notin $sharePointScopes })
    if ($missingGraph.Count -or $missingSharePoint.Count) {
        $missing = @($missingGraph + $missingSharePoint) -join ", "
        throw "The signed-in provisioning app token is missing required delegated scope(s): $missing. In Entra admin center, update the existing app's API permissions, grant admin consent again, clear the persisted sign-in, and rerun with -ForceAuthentication. Nothing was created or changed."
    }
    Write-Host "Provisioning app consent prerequisite passed: all six delegated scopes are present."
}
