# Dot-source after OperatorAdvisories.ps1. No connection or deployment occurs on import. Every Graph read here is
# best-effort and read-only: when a read is denied the check reports "unverified" and never blocks on its own.

# Directory role template IDs that Microsoft documents as exempt from the Microsoft 365 group naming policy.
$script:CoEGroupNamingExemptRoles = @{
    "62e90394-69f5-4237-9190-012177145e10" = "Global Administrator"
    "fe930be7-5e62-47db-91af-98c3a49a38b1" = "User Administrator"
}

function Get-CoEGroupNamingPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Connection)
    try {
        $response = Invoke-PnPGraphMethod -Url "v1.0/groupSettings" -Method Get -Connection $Connection -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Verified = $false; PrefixSuffix = ""; BlockedWords = ""; Detail = $_.Exception.Message }
    }
    $prefixSuffix = ""
    $blocked = ""
    foreach ($setting in @($response.value)) {
        if ($setting.displayName -cne "Group.Unified") { continue }
        foreach ($entry in @($setting.values)) {
            if ($entry.name -ceq "PrefixSuffixNamingRequirement") { $prefixSuffix = [string]$entry.value }
            if ($entry.name -ceq "CustomBlockedWordsList") { $blocked = [string]$entry.value }
        }
    }
    [pscustomobject]@{ Verified = $true; PrefixSuffix = $prefixSuffix.Trim(); BlockedWords = $blocked.Trim(); Detail = "" }
}

function Get-CoEOperatorIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Connection)
    $me = Invoke-PnPGraphMethod -Url "v1.0/me?`$select=id,userPrincipalName" -Method Get -Connection $Connection -ErrorAction Stop
    $exemptRole = ""
    $rolesVerified = $true
    try {
        $roles = Invoke-PnPGraphMethod -Url "v1.0/me/memberOf/microsoft.graph.directoryRole?`$select=roleTemplateId,displayName" `
            -Method Get -Connection $Connection -ErrorAction Stop
        foreach ($role in @($roles.value)) {
            if ($script:CoEGroupNamingExemptRoles.ContainsKey([string]$role.roleTemplateId)) {
                $exemptRole = $script:CoEGroupNamingExemptRoles[[string]$role.roleTemplateId]
                break
            }
        }
    } catch {
        $rolesVerified = $false
    }
    [pscustomobject]@{
        Id = [string]$me.id; UserPrincipalName = [string]$me.userPrincipalName
        ExemptRole = $exemptRole; RolesVerified = $rolesVerified
    }
}

function Get-CoEAliasNotFoundMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][string]$Alias,
        [string]$DisplayName,
        [string]$LookupError
    )
    $found = @()
    $searched = $true
    try {
        $term = if ($DisplayName) { $DisplayName } else { $Alias }
        $query = [uri]::EscapeDataString('"displayName:' + $term.Replace('"', '') + '"')
        $result = Invoke-PnPGraphMethod -Url "v1.0/groups?`$search=$query&`$select=id,displayName,mailNickname&`$top=10" -Method Get `
            -Connection $Connection -AdditionalHeaders @{ ConsistencyLevel = "eventual" } -ErrorAction Stop
        $found = @($result.value | ForEach-Object { "'$($_.displayName)' (alias $($_.mailNickname), id $($_.id))" })
    } catch {
        $searched = $false
    }
    $listing = if (-not $searched) { "The tenant could not be searched for it." }
        elseif ($found.Count) { "Groups matching the display name: " + ($found -join "; ") + "." }
        else { "No group matching the display name was found." }
    $detail = if ($LookupError) { " Lookup error: $LookupError" } else { "" }
    return ("The provisioning template completed, but no Microsoft 365 group has the alias '$Alias'. The Team and its SharePoint site may already exist. " +
        "Do NOT run 02_Install-CopilotCoE.ps1 again until you have checked Entra > Groups: a second run creates another Team. " +
        "A group naming policy that adds a prefix or suffix to aliases is the usual cause (only Global Administrator and User Administrator are exempt). " +
        $listing + $detail)
}

function Invoke-CoETenantPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][object]$AdvisoryContext,
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][string]$OwnerUserId,
        [Parameter(Mandatory)][string]$OwnerUserPrincipalName
    )
    $operator = $null
    try { $operator = Get-CoEOperatorIdentity -Connection $Connection } catch {
        Write-Warning "Could not identify the signed-in account ($($_.Exception.Message)); the owner and naming-policy preflight checks were skipped."
        return
    }

    $policy = Get-CoEGroupNamingPolicy -Connection $Connection
    if (-not $policy.Verified) {
        Write-Warning ("The group naming policy could not be read ($($policy.Detail)). If your organization applies a prefix or suffix to Microsoft 365 " +
            "group aliases, run this script as a Global Administrator or User Administrator; otherwise the Team cannot be found by alias '$Alias'.")
    } elseif ($policy.PrefixSuffix) {
        if ($operator.ExemptRole) {
            Write-Host "Group naming policy '$($policy.PrefixSuffix)' exists; $($operator.UserPrincipalName) holds $($operator.ExemptRole), which is exempt."
        } else {
            $roleNote = if ($operator.RolesVerified) { "does not hold an exempt role" } else { "has roles that could not be verified" }
            Confirm-CoEAdvisory -Context $AdvisoryContext -Id GroupNamingPolicy -Level Warn `
                -Facts @(
                    "alias=$(([string]$Alias).Trim().ToLowerInvariant())",
                    "policy=$($policy.PrefixSuffix)",
                    "operator=$(([string]$operator.UserPrincipalName).Trim().ToLowerInvariant())",
                    "rolesVerified=$([bool]$operator.RolesVerified)"
                ) `
                -Message ("A Microsoft Entra group naming policy ('$($policy.PrefixSuffix)') is applied to Microsoft 365 group names AND aliases. " +
                    "$($operator.UserPrincipalName) $roleNote (only Global Administrator and User Administrator are exempt). The installer finds the Team it creates " +
                    "by the exact alias '$Alias'; with a prefix or suffix it would create the Team and site and then fail to find them, and a second run would create another. " +
                    "STOP, then run as an exempt administrator or have the policy changed. PROCEED only if you have confirmed the alias will not be modified.")
        }
    }

    if ($operator.Id -and $OwnerUserId -and $operator.Id -ine $OwnerUserId) {
        Confirm-CoEAdvisory -Context $AdvisoryContext -Id OwnerDiffersFromOperator -Level Warn `
            -Facts @(
                "owner=$(([string]$OwnerUserPrincipalName).Trim().ToLowerInvariant())",
                "operator=$(([string]$operator.UserPrincipalName).Trim().ToLowerInvariant())"
            ) `
            -Message ("SharedChannelOwnerUPN is $OwnerUserPrincipalName but this installation runs as $($operator.UserPrincipalName). The governance shared channels are owned " +
                "by $OwnerUserPrincipalName and, by design, no other administrator is added to them. A lab install run as a Global Administrator with a different owner completed and wrote every " +
                "governance document. An operator without Global Administrator rights has not been tested and may be unable to write the channels' files, which would stop the run partway. " +
                "STOP and sign in as the owner or a Global Administrator, or PROCEED if you accept that risk and will test on a throwaway alias first.")
    }
}
