# Dot-source from 03 / 04 / Complete. No connection or deployment occurs on import.

function Get-CoESignInArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Tenant,
        [ValidateSet("Interactive", "DeviceLogin")][string]$AuthenticationMode = "DeviceLogin",
        [switch]$ForceAuthentication
    )
    if ($ForceAuthentication -and $AuthenticationMode -ne "Interactive") {
        throw "-ForceAuthentication requires -AuthenticationMode Interactive."
    }
    $arguments = @{
        Url = $Url; ClientId = $ClientId; Tenant = $Tenant
        PersistLogin = $true; ReturnConnection = $true; ErrorAction = "Stop"
    }
    $arguments[$AuthenticationMode] = $true
    if ($ForceAuthentication) { $arguments.ForceAuthentication = $true }
    return $arguments
}

function Get-CoESignInHint([string]$AuthenticationMode) {
    if ($AuthenticationMode -eq "Interactive") {
        return "Reuse cached PnP sign-in if available. If prompted, complete the browser sign-in for the target tenant."
    }
    return "Reuse cached PnP sign-in if available. If prompted, complete one device sign-in for the target tenant. " +
        "If Conditional Access blocks device-code flow, rerun with -AuthenticationMode Interactive."
}

# A SharePoint address is accepted only as https://<configured host>/<one managed path>/<alias>. The managed
# path is usually "sites" but a tenant can use "teams" or another prefix, so it is read, never assumed.
function Test-CoESiteUrlForTarget {
    [CmdletBinding()]
    param([string]$Url, [Parameter(Mandatory)][string]$SiteFqdn, [Parameter(Mandatory)][string]$Alias)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    $uri = $null
    if (-not [uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -ne "https" -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or -not $uri.IsDefaultPort) { return $false }
    if ($uri.Host -ine $SiteFqdn.Trim()) { return $false }
    $segments = @($uri.AbsolutePath.Trim("/") -split "/")
    if ($segments.Count -ne 2 -or [string]::IsNullOrWhiteSpace($segments[0])) { return $false }
    return ($segments[1] -ieq $Alias)
}

function Resolve-CoESiteUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteFqdn,
        [Parameter(Mandatory)][string]$Alias,
        [string]$ExplicitSiteUrl,
        [string]$ReportPath
    )
    $fqdn = $SiteFqdn.Trim().ToLowerInvariant()
    if ($ExplicitSiteUrl) {
        if (-not (Test-CoESiteUrlForTarget -Url $ExplicitSiteUrl -SiteFqdn $fqdn -Alias $Alias)) {
            throw ("-SiteUrl must be https://$fqdn/<managed path>/$Alias with no query, fragment, credentials or port. " +
                "Use the exact address printed by 02_Install-CopilotCoE.ps1.")
        }
        return [pscustomobject]@{ Url = $ExplicitSiteUrl.Trim().TrimEnd("/"); Source = "-SiteUrl" }
    }
    if ($ReportPath -and (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
        try {
            $report = Get-Content -LiteralPath $ReportPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw ("Deployment report '$ReportPath' is not valid JSON. Do not guess which site to update. " +
                "Rerun 03_Update-CoEContent.ps1 with -SiteUrl using the exact address printed by 02_Install-CopilotCoE.ps1. $($_.Exception.Message)")
        }
        $reportedSite = if ($report -and $report.PSObject.Properties["Site"] -and $report.Site -is [string]) {
            ([string]$report.Site).Trim()
        } else { "" }
        if (-not (Test-CoESiteUrlForTarget -Url $reportedSite -SiteFqdn $fqdn -Alias $Alias)) {
            $recorded = if ($reportedSite) { "'$reportedSite'" } else { "no usable Site value" }
            throw ("Deployment report '$ReportPath' records $recorded, not https://$fqdn/<managed path>/$Alias. " +
                "Do not fall back to a guessed /sites/ address when a report identifies another deployment. " +
                "Correct the target settings or rerun 03_Update-CoEContent.ps1 with -SiteUrl using the exact address printed by 02_Install-CopilotCoE.ps1.")
        }
        return [pscustomobject]@{ Url = $reportedSite.TrimEnd("/"); Source = "deployment report" }
    }
    return [pscustomobject]@{ Url = "https://$fqdn/sites/$Alias"; Source = "default /sites/ path" }
}

# SharePoint lists its time zones with names in the site's language and Windows localizes TimeZoneInfo.DisplayName,
# so the comparison ignores case, punctuation and "&" versus "and". Both the machine's own name and the English name
# are tried. There is deliberately no offset-only fallback: a zone with the same UTC offset but different daylight
# rules would silently shift calendar times. No match means no change and a clear warning.
function ConvertTo-CoEComparableText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    return ([regex]::Replace(($Text -replace '&', 'and'), '[^\p{L}\p{N}]', '')).ToLowerInvariant()
}

function Get-CoEEnglishTimeZoneName([string]$TimeZoneId) {
    $original = [System.Globalization.CultureInfo]::CurrentUICulture
    try {
        [System.Globalization.CultureInfo]::CurrentUICulture = [System.Globalization.CultureInfo]::GetCultureInfo("en-US")
        [TimeZoneInfo]::ClearCachedData()
        return [string]([TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)).DisplayName
    } catch {
        return ""
    } finally {
        [System.Globalization.CultureInfo]::CurrentUICulture = $original
        [TimeZoneInfo]::ClearCachedData()
    }
}

function Find-CoESharePointTimeZone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][TimeZoneInfo]$TimeZone,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates,
        [string]$EnglishName
    )
    $names = @(@($TimeZone.DisplayName, $EnglishName) | Where-Object { $_ } |
        ForEach-Object { ConvertTo-CoEComparableText $_ } | Select-Object -Unique)
    foreach ($name in $names) {
        $hits = @($Candidates | Where-Object { (ConvertTo-CoEComparableText ([string]$_.Description)) -ceq $name })
        if ($hits.Count -ge 1) { return $hits[0] }
    }
    return $null
}

# An update must act on the Team its deployment report was written for. A report is a hashtable or object with
# an optional TeamId. No report (first update from a new computer) or an older report without TeamId is allowed
# with a warning; a different TeamId means the alias or site address was reused and nothing may be changed.
function Assert-CoEDeploymentTeamBinding {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Report,
        [Parameter(Mandatory)][string]$TeamId,
        [Parameter(Mandatory)][string]$Alias
    )
    if ($null -eq $Report) { return }
    $savedTeamId = ""
    if ($Report -is [System.Collections.IDictionary]) {
        if ($Report.Contains("TeamId")) { $savedTeamId = [string]$Report["TeamId"] }
    } elseif ($Report.PSObject.Properties["TeamId"]) {
        $savedTeamId = [string]$Report.TeamId
    }
    if ([string]::IsNullOrWhiteSpace($savedTeamId)) {
        Write-Warning ("The deployment report has no TeamId (written by an older kit). This update is bound by alias and site address only; " +
            "it will record TeamId $TeamId when it completes.")
        return
    }
    if ($savedTeamId.Trim() -ine $TeamId.Trim()) {
        throw ("The deployment report in this organization folder was written for Team $savedTeamId, but alias '$Alias' now resolves to " +
            "Team $TeamId at the same site address. The alias or site was reused after the original deployment. Nothing was changed. " +
            "Confirm which Team this organization folder should manage; do not edit the report to force a match.")
    }
}

# Live regression writes lists and permissions. Only a dedicated throwaway site qualifies: the exact configured
# host, one managed path, an alias that starts with CoEScratch or CoE-Scratch, and never the organization's own alias.
function Test-CoEScratchSiteUrl {
    [CmdletBinding()]
    param([string]$Url, [Parameter(Mandatory)][string]$SiteFqdn, [string]$ProtectedAlias)
    if ([string]::IsNullOrWhiteSpace($Url) -or [string]::IsNullOrWhiteSpace($SiteFqdn)) { return $false }
    $uri = $null
    if (-not [uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -ne "https" -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or -not $uri.IsDefaultPort) { return $false }
    if ($uri.Host -ine $SiteFqdn.Trim()) { return $false }
    $segments = @($uri.AbsolutePath.Trim("/") -split "/")
    if ($segments.Count -ne 2 -or [string]::IsNullOrWhiteSpace($segments[0])) { return $false }
    $alias = [uri]::UnescapeDataString($segments[1])
    if ($alias -notmatch '^(?i)CoE-?Scratch[A-Za-z0-9_-]*$') { return $false }
    if ($ProtectedAlias -and $alias -ieq $ProtectedAlias.Trim()) { return $false }
    return $true
}
