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
