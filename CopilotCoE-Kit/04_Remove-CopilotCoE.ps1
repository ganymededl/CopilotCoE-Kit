#Requires -Version 7.4
<#
.SYNOPSIS
Removes the Copilot CoE that 02_Install-CopilotCoE.ps1 built (undo).

.DESCRIPTION
OPTIONAL CLEAN-UP STEP. Removes everything the kit created in the tenant:
  - the Microsoft 365 group and its Team (all channels, tabs, and conversations)
  - the connected SharePoint site (pages, lists, files, navigation)
  - its site-collection permission levels, including CoE Catalog Reviewer (with the site)
  - the Leadership Governance and Program Governance shared-channel sites
The kit changes no tenant-wide settings, so nothing else needs to be reverted.
CoE Catalog Reviewer is not tenant-wide. Its definition is removed with the site, retained
with a soft-deleted site for restoration, and permanently removed by site purge. Do not
delete it separately before a soft delete; that would alter permissions on a restored site.

Always preview first. -WhatIf lists exact validated tenant resources and changes no tenant resources.
It may create or refresh the local PnP sign-in cache:
    .\04_Remove-CopilotCoE.ps1 -WhatIf
Remove (soft delete; restorable for 30 days from the admin centers):
    .\04_Remove-CopilotCoE.ps1
Remove and purge from the recycle bins so the same alias can be rebuilt at once:
    .\04_Remove-CopilotCoE.ps1 -Purge

You must type the Team alias to confirm; -Purge also requires typing each exact site URL shown in the plan.
-Purge cannot be undone and uses only URLs tied to the saved CoE identity.
Sign-in uses a device code by default and reuses a cached sign-in while it is valid. If Conditional Access blocks
device-code flow, use -AuthenticationMode Interactive (add -ForceAuthentication for a fresh interactive sign-in).
The sign-in app from 01_Register-CoEProvisioningApp.ps1 is kept so you can rebuild;
delete it in Entra admin center when you no longer need it (steps are printed at the end).
Only a completed, verified -Purge writes CoE-Purge-Receipt.json beside external
organization settings. Settings inside the release use LocalAppData\CopilotCoE\PurgeReceipts
instead, never the release kit. -WhatIf and incomplete/soft deletes write no receipt.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$OrgPath,
    [string]$SettingsPath,
    [string]$MailNickname,
    [switch]$Purge,
    [int]$WaitMinutes = 15,
    [ValidateSet("Interactive", "DeviceLogin")]
    [string]$AuthenticationMode = "DeviceLogin",
    [switch]$ForceAuthentication
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module PnP.PowerShell -RequiredVersion 3.2.0 -ErrorAction Stop
. (Join-Path $PSScriptRoot "Internal\TargetResolution.ps1")
if ($ForceAuthentication -and $AuthenticationMode -ne "Interactive") {
    throw "-ForceAuthentication requires -AuthenticationMode Interactive."
}
if ($OrgPath) {
    if (-not (Test-Path -LiteralPath $OrgPath -PathType Container)) { throw "Organization folder not found: $OrgPath" }
    if (-not $SettingsPath) { $SettingsPath = Join-Path (Resolve-Path -LiteralPath $OrgPath).Path "Deployment-Settings.json" }
}
if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "Deployment-Settings.json" }

if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) { throw "Settings file not found: $SettingsPath" }
$s = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
foreach ($name in @("Tenant", "AdminFQDN", "SiteFQDN", "PnPClientID")) {
    if ([string]::IsNullOrWhiteSpace([string]$s.$name) -or [string]$s.$name -match "[<>]") {
        throw "Set $name in $SettingsPath before removing the CoE."
    }
}
if (-not $MailNickname) { $MailNickname = [string]$s.MailNickname }
if ($MailNickname -notmatch "^[A-Za-z0-9_-]{1,64}$") { throw "MailNickname is missing or invalid: '$MailNickname'." }
$adminFqdn = ([string]$s.AdminFQDN).Trim() -replace "^https?://", "" -replace "/.*$", ""
$siteFqdn = ([string]$s.SiteFQDN).Trim() -replace "^https?://", "" -replace "/.*$", ""
if ($siteFqdn -notmatch "^[A-Za-z0-9.-]+\.sharepoint\.com$") { throw "SiteFQDN must be the configured SharePoint tenant host in $SettingsPath." }
$siteFqdn = $siteFqdn.ToLowerInvariant()
function Test-ConfiguredTenantSiteUrl([string]$Url) {
    [uri]::IsWellFormedUriString($Url, [UriKind]::Absolute) -and
        ([uri]$Url).Scheme -eq "https" -and ([uri]$Url).Host.ToLowerInvariant() -eq $siteFqdn
}

Write-Host "Connecting to the SharePoint admin endpoint. $(Get-CoESignInHint $AuthenticationMode)"
$signInArguments = Get-CoESignInArguments -Url "https://$adminFqdn/" -ClientId ([string]$s.PnPClientID) `
    -Tenant ([string]$s.Tenant) -AuthenticationMode $AuthenticationMode -ForceAuthentication:$ForceAuthentication
$admin = Connect-PnPOnline @signInArguments

function Get-AliasSites([object]$Connection, [string]$Alias) {
    @(Get-PnPTenantSite -Filter "Url -like '*/$Alias'" -Connection $Connection |
        Where-Object { ([uri]$_.Url).Segments[-1].TrimEnd("/") -eq $Alias })
}
# Only URLs captured from this CoE's verified deployment identity are eligible for permanent deletion.
$script:coeGroupIds = @()
$script:authorizedDeletedSiteUrls = @()
function Get-ChannelSites([object]$Connection, [string]$Alias) {
    if ($script:coeGroupIds.Count -eq 0) { return @() }
    @(foreach ($template in @("TEAMCHANNEL#1", "TEAMCHANNEL#0")) {
        Get-PnPTenantSite -Template $template -Connection $Connection | Where-Object {
            [string]$_.RelatedGroupId -in $script:coeGroupIds
        }
    })
}
function Get-DeletedAliasSites([object]$Connection, [string]$Alias, [string[]]$ReviewedSiteUrls) {
    $known = @($ReviewedSiteUrls | ForEach-Object { ([string]$_).TrimEnd("/") } | Select-Object -Unique)
    if ($known.Count -eq 0) { return @() }
    @(Get-PnPTenantDeletedSite -Limit 100000 -Connection $Connection |
        Where-Object { ([string]$_.Url).TrimEnd("/") -in $known })
}
function Get-DeletedGroup([object]$Connection, [string]$Alias, [string]$GroupId) {
    # Enumerate rather than treating an identity lookup's not-found/auth errors as absence.
    $matches = @(foreach ($candidate in @(Get-PnPDeletedMicrosoft365Group -Connection $Connection -ErrorAction Stop)) {
        $candidateId = [guid]::Empty
        if (-not $candidate.PSObject.Properties["MailNickname"] -or -not $candidate.PSObject.Properties["Id"] -or
            [string]::IsNullOrWhiteSpace([string]$candidate.MailNickname) -or
            -not [guid]::TryParse([string]$candidate.Id, [ref]$candidateId) -or $candidateId -eq [guid]::Empty) {
            throw "Deleted-group enumeration returned incomplete identity information. Absence is unproven."
        }
        if ($candidate.MailNickname -ieq $Alias -or [string]$candidate.Id -in $script:coeGroupIds -or
            ($GroupId -and [string]$candidate.Id -ieq $GroupId)) { $candidate }
    })
    if ($matches.Count -gt 1) { throw "Multiple deleted groups match the alias or saved immutable ID. Review manually." }
    $matches
}
function Test-CoESite([object]$Connection, [string]$Url, [object]$TenantSite) {
    $siteConnection = Connect-PnPOnline -Url $Url -Connection $Connection -ReturnConnection -ErrorAction Stop
    $markers = @(Get-PnPPage -Connection $siteConnection -ErrorAction Stop |
        Where-Object { $_.Name -in @("TrainingHome.aspx", "Copilot-Guides.aspx", "CoE-Service-Catalog-and-Support.aspx") })
    $markerList = @(Get-PnPList -Connection $siteConnection -ErrorAction Stop |
        Where-Object Title -in @("Copilot Adoption Checklist", "Department Champions"))
    return ($markers.Count -gt 0 -or $markerList.Count -gt 0)
}

function Write-CoEPurgeReceipt {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ReceiptPath, $Settings, [string]$Alias, [string]$GroupId,
        [string]$SiteUrl, [string[]]$SiteUrls, [bool]$AliasReusable, [switch]$Purge,
        [string]$ReleaseRoot
    )
    if (-not $Purge -or -not $AliasReusable) { return }
    $fullPath = [IO.Path]::GetFullPath($ReceiptPath)
    $release = [IO.Path]::GetFullPath($ReleaseRoot).TrimEnd("\")
    if ($fullPath -ieq $release -or $fullPath.StartsWith($release + "\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Purge receipts must be stored outside the release kit."
    }
    $id = [guid]::Empty
    if (-not [guid]::TryParse($GroupId, [ref]$id) -or $id -eq [guid]::Empty) {
        throw "No immutable CoE group ID is available for a purge receipt."
    }
    if ($Alias -ine [string]$Settings.MailNickname) {
        throw "The removed alias differs from settings MailNickname. No reset receipt can be issued for this profile."
    }
    $urls = @($SiteUrls | ForEach-Object { $_.TrimEnd("/") } | Sort-Object -Unique)
    if (-not $SiteUrl -or $SiteUrl.TrimEnd("/") -notin $urls -or $urls.Count -eq 0) {
        throw "The exact primary site and all reviewed site URLs are required for a purge receipt."
    }
    foreach ($url in $urls) {
        if (-not [uri]::IsWellFormedUriString($url, [UriKind]::Absolute)) { throw "Invalid receipt site URL: $url" }
        $uri = [uri]$url
        if ($uri.Scheme -ne "https" -or $uri.Host -ine ([string]$Settings.SiteFQDN).Trim() -or
            $uri.UserInfo -or $uri.Query -or $uri.Fragment -or -not $uri.IsDefaultPort) {
            throw "Receipt site URL is outside the exact configured tenant: $url"
        }
    }
    $receipt = [ordered]@{
        SchemaVersion = 1
        Producer = "04_Remove-CopilotCoE.ps1"
        ReceiptId = [guid]::NewGuid().ToString()
        AliasReusable = $true
        Tenant = ([string]$Settings.Tenant).Trim()
        AdminFQDN = ([string]$Settings.AdminFQDN).Trim() -replace "^https?://", "" -replace "/.*$", ""
        SiteFQDN = ([string]$Settings.SiteFQDN).Trim() -replace "^https?://", "" -replace "/.*$", ""
        MailNickname = $Alias
        GroupId = $id.ToString()
        SiteUrl = $SiteUrl.TrimEnd("/")
        SiteUrls = $urls
        PurgeCompletedAtUtc = [DateTime]::UtcNow.ToString("o")
    }
    if ($PSCmdlet.ShouldProcess($fullPath, "Write the completed identity-bound purge receipt")) {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $fullPath) -Force -ErrorAction Stop
        $pending = "$fullPath.$([guid]::NewGuid()).pending"
        try {
            $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pending -Encoding utf8 -ErrorAction Stop
            Move-Item -LiteralPath $pending -Destination $fullPath -Force -ErrorAction Stop
        } finally {
            if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -ErrorAction Stop }
        }
        return $fullPath
    }
}

$groups = @(Get-PnPMicrosoft365Group -Filter "mailNickname eq '$MailNickname'" -IncludeSiteUrl -Connection $admin)
if ($groups.Count -gt 1) { throw "Multiple groups use alias '$MailNickname'. Remove the correct one manually." }
$group = if ($groups.Count -eq 1) { $groups[0] } else { $null }
$siteUrl = if ($group -and $group.SiteUrl) { $group.SiteUrl.TrimEnd("/") } else { $null }
$deletedGroupAtStart = if ($group) { $null } else { Get-DeletedGroup -Connection $admin -Alias $MailNickname }
$deletedGroupId = if ($deletedGroupAtStart -and $deletedGroupAtStart.PSObject.Properties["Id"]) {
    [string]$deletedGroupAtStart.Id
} elseif ($deletedGroupAtStart -and $deletedGroupAtStart.PSObject.Properties["GroupId"]) {
    [string]$deletedGroupAtStart.GroupId
} else { "" }
$script:coeGroupIds = @(if ($group -and $group.GroupId) { [string]$group.GroupId })
$settingsDirectory = Split-Path -Parent (Resolve-Path -LiteralPath $SettingsPath).Path
$reportPath = Join-Path $settingsDirectory "CoE-Revision-Report.json"
$removalManifestPath = Join-Path $settingsDirectory "CoE-Removal-Manifest.json"
$deploymentReport = if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
    Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
} else { $null }
$existingManifest = if (Test-Path -LiteralPath $removalManifestPath -PathType Leaf) {
    Get-Content -LiteralPath $removalManifestPath -Raw | ConvertFrom-Json
} else { $null }
$manifestTeamId = if ($existingManifest -and $existingManifest.PSObject.Properties["TeamId"]) { [string]$existingManifest.TeamId } else { "" }
$reportTeamId = if ($deploymentReport -and $deploymentReport.PSObject.Properties["TeamId"]) { [string]$deploymentReport.TeamId } else { "" }
$manifestAlias = if ($existingManifest -and $existingManifest.PSObject.Properties["Alias"]) { [string]$existingManifest.Alias } else { "" }
$manifestSite = if ($existingManifest -and $existingManifest.PSObject.Properties["SiteUrl"]) { [string]$existingManifest.SiteUrl } else { "" }
$reportSite = if ($deploymentReport -and $deploymentReport.PSObject.Properties["Site"]) { [string]$deploymentReport.Site } else { "" }
$manifestChannelUrls = @(if ($existingManifest -and $existingManifest.PSObject.Properties["ChannelSiteUrls"]) {
    $existingManifest.ChannelSiteUrls | ForEach-Object { ([string]$_).TrimEnd("/").ToLowerInvariant() } | Sort-Object -Unique
})
$reportChannelUrls = @(if ($deploymentReport -and $deploymentReport.PSObject.Properties["Governance"]) {
    $deploymentReport.Governance | ForEach-Object { ([string]$_.Site).TrimEnd("/").ToLowerInvariant() } | Sort-Object -Unique
})
$savedTeamId = if ($manifestTeamId) { $manifestTeamId } else { $reportTeamId }
$savedManifestConsistent = $existingManifest -and $deploymentReport -and
    $manifestAlias -eq $MailNickname -and
    $manifestTeamId -and $manifestTeamId -eq $reportTeamId -and
    (Test-ConfiguredTenantSiteUrl $manifestSite) -and
    $manifestSite.TrimEnd("/") -eq $reportSite.TrimEnd("/") -and
    (($manifestChannelUrls -join "|") -eq ($reportChannelUrls -join "|")) -and
    @($reportChannelUrls | Where-Object { -not (Test-ConfiguredTenantSiteUrl $_) }).Count -eq 0 -and
    $savedTeamId -match "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
$reportMatchesKnownGroup = $group -and $reportTeamId -and $reportTeamId -eq [string]$group.GroupId -and
    (Test-ConfiguredTenantSiteUrl $reportSite) -and
    $reportSite.TrimEnd("/") -eq $siteUrl.TrimEnd("/")
if ($group -and $savedTeamId -and $savedTeamId -ne [string]$group.GroupId) {
    throw "The saved CoE Team ID does not match the active group for alias '$MailNickname'. Resolve the identity conflict manually; nothing was removed."
}
$identityMatches = if ($group) {
    [bool]($reportMatchesKnownGroup -or ($savedManifestConsistent -and $savedTeamId -eq [string]$group.GroupId))
} elseif ($deletedGroupAtStart) {
    [bool]($savedManifestConsistent -and $savedTeamId -eq $deletedGroupId)
} else {
    [bool]$savedManifestConsistent
}
if ($deletedGroupAtStart -and -not $identityMatches) {
    throw "The deleted group ID '$deletedGroupId' is not verified by a consistent CoE identity record. No channel sites or recycled sites were selected."
}
if (-not $group -and $deletedGroupAtStart -and $identityMatches) {
    $script:coeGroupIds = @($deletedGroupId)
}
if ($group) {
    if (-not $siteUrl) { throw "Group '$MailNickname' has no SharePoint site yet; remove it manually after review." }
    if (-not (Test-ConfiguredTenantSiteUrl $siteUrl)) {
        throw "The active Team site '$siteUrl' is outside configured tenant host '$siteFqdn'. Nothing was removed."
    }
    if (-not (Test-CoESite -Connection $admin -Url $siteUrl)) {
        throw "The site $siteUrl does not contain the CoE pages or lists. It was not built by this kit, so nothing was removed."
    }
}
$channelSites = @(Get-ChannelSites -Connection $admin -Alias $MailNickname)
foreach ($channelSite in $channelSites) {
    if (-not (Test-ConfiguredTenantSiteUrl ([string]$channelSite.Url))) {
        throw "The related shared-channel site '$($channelSite.Url)' is outside configured tenant host '$siteFqdn'. Nothing was removed."
    }
}
if ($identityMatches) {
    $script:authorizedDeletedSiteUrls += $reportSite
    if ($deploymentReport.PSObject.Properties["Governance"]) {
        $script:authorizedDeletedSiteUrls += @($deploymentReport.Governance | ForEach-Object { $_.Site })
    }
}
if ($group -and $siteUrl) {
    $script:authorizedDeletedSiteUrls += $siteUrl
    $script:authorizedDeletedSiteUrls += @($channelSites | ForEach-Object { $_.Url })
}
$script:authorizedDeletedSiteUrls = @($script:authorizedDeletedSiteUrls | Where-Object {
    $_ -and (Test-ConfiguredTenantSiteUrl ([string]$_))
} | ForEach-Object { ([string]$_).TrimEnd("/") } | Sort-Object -Unique)
if ($savedTeamId -and -not $identityMatches) {
    Write-Warning "No saved CoE identity matched the live resource. Only the live group and its currently related, marker-verified sites can be removed; no saved recycled-site URLs are authorized."
}

# A site whose group is gone is eligible only when its exact URL is in a consistent CoE identity record.
$orphanSites = @()
if (-not $group -and -not $deletedGroupAtStart) {
    foreach ($candidate in @(Get-AliasSites -Connection $admin -Alias $MailNickname)) {
        if ($candidate.Url.TrimEnd("/") -in $script:authorizedDeletedSiteUrls -and
            (Test-CoESite -Connection $admin -Url $candidate.Url -TenantSite $candidate)) {
            $orphanSites += $candidate
        } else {
            Write-Warning "Skipping $($candidate.Url): it is not identity-authorized by a consistent CoE manifest/report or lacks CoE markers."
        }
    }
}

$deletedSitesBeforeRemoval = @()
if ($Purge) {
    $deletedSitesBeforeRemoval = @(Get-DeletedAliasSites -Connection $admin -Alias $MailNickname `
        -ReviewedSiteUrls $script:authorizedDeletedSiteUrls)
}
$reviewedPurgeSiteUrls = @($script:authorizedDeletedSiteUrls |
    ForEach-Object { ([string]$_).TrimEnd("/") } | Sort-Object -Unique)
$receiptGroupId = if ($group) { [string]$group.GroupId } else { $savedTeamId }
$receiptSiteUrl = if ($group) { $siteUrl } else { $reportSite }
if ($Purge -and $reviewedPurgeSiteUrls.Count -eq 0) {
    throw "No exact, identity-verified site URLs are available for purge. Nothing was removed."
}

Write-Host ""
Write-Host "COPILOT COE REMOVAL PLAN (alias: $MailNickname)"
if ($group) {
    Write-Host "  Team / Microsoft 365 group : $($group.DisplayName)  [$($group.GroupId)]"
    Write-Host "  SharePoint site            : $siteUrl"
} elseif ($deletedGroupAtStart) {
    Write-Host "  Group already deleted (in the Entra recycle bin); SharePoint is still removing its site."
} else {
    Write-Host "  No active group uses this alias."
}
foreach ($orphanSite in $orphanSites) { Write-Host "  Orphaned site (no group)   : $($orphanSite.Url)  -> deleted directly" }
foreach ($channelSite in $channelSites) {
    $how = if ($group) { "" } else { "  -> deleted directly (its Team no longer exists)" }
    Write-Host "  Shared-channel site        : $($channelSite.Url)$how"
}
if ($Purge) {
    Write-Host "  Exact site URLs eligible for permanent purge (the same frozen list is used for execution):"
    foreach ($url in $reviewedPurgeSiteUrls) { Write-Host "    $url" }
    foreach ($site in $deletedSitesBeforeRemoval) { Write-Host "    Already recycled: $($site.Url)" }
} else {
    Write-Host "  Deleted items stay restorable for 30 days. Add -Purge to free the alias for an immediate rebuild."
}
Write-Host "  Not changed: tenant-wide sharing policy, the sign-in app, and files in this kit folder."
Write-Host "  CoE Catalog Reviewer: site-collection scoped; removed with its site, retained for soft-delete restoration."
Write-Host "  Permanent site purge also removes the permission level; no tenant-wide role cleanup is needed."
Write-Host ""

if (-not $group -and $orphanSites.Count -eq 0 -and $channelSites.Count -eq 0 -and
    (-not $Purge -or ($script:authorizedDeletedSiteUrls.Count -eq 0 -and -not $deletedGroupAtStart))) {
    if ($Purge -and $deletedGroupAtStart) {
        Write-Warning "The deleted group has no matching deployment/removal identity manifest. Nothing was purged."
    } else {
        Write-Host "Nothing to remove or identity-authorized purge for alias '$MailNickname'."
    }
    return
}
if (-not $PSCmdlet.ShouldProcess("alias '$MailNickname'", "Remove the Copilot CoE Team, site, and channel sites")) { return }
$typed = Read-Host "Type the alias '$MailNickname' to confirm removal"
if ($typed -cne $MailNickname) { throw "Confirmation did not match. Nothing was removed." }

if ($group -and $siteUrl) {
    if ($Purge) {
        Write-Host "Type every exact site URL below, one at a time, to authorize only those URLs for permanent purge."
        foreach ($url in $reviewedPurgeSiteUrls) {
            $siteConfirmation = Read-Host "Confirm exact URL: $url"
            if ($siteConfirmation -cne $url) {
                throw "Exact URL confirmation did not match. No group, site, or purge action was performed."
            }
        }
    }
    [ordered]@{
        Alias = $MailNickname
        TeamId = [string]$group.GroupId
        SiteUrl = $siteUrl
        ChannelSiteUrls = @($channelSites | ForEach-Object { $_.Url.TrimEnd("/") })
        CapturedAtUtc = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $removalManifestPath -Encoding utf8
} elseif ($Purge) {
    Write-Host "Type every exact site URL below, one at a time, to authorize only those URLs for permanent purge."
    foreach ($url in $reviewedPurgeSiteUrls) {
        $siteConfirmation = Read-Host "Confirm exact URL: $url"
        if ($siteConfirmation -cne $url) {
            throw "Exact URL confirmation did not match. No site or purge action was performed."
        }
    }
}

if ($group) {
    Write-Host "Deleting the Microsoft 365 group (this removes the Team and starts site deletion)..."
    Remove-PnPMicrosoft365Group -Identity $group.GroupId -Connection $admin -ErrorAction Stop
}
foreach ($orphanSite in $orphanSites) {
    Write-Host "Deleting orphaned site $($orphanSite.Url) (its group no longer exists)..."
    Remove-PnPTenantSite -Url $orphanSite.Url -Force -Connection $admin -ErrorAction Stop
}
# Channel sites left behind by an earlier removal block their names, so the next build gets "...2" addresses.
function Remove-ChannelSitesDirectly([string[]]$ReviewedSiteUrls) {
    $reviewed = @($ReviewedSiteUrls | ForEach-Object { ([string]$_).TrimEnd("/").ToLowerInvariant() })
    foreach ($channelSite in @(Get-ChannelSites -Connection $admin -Alias $MailNickname)) {
        $normalizedUrl = ([string]$channelSite.Url).TrimEnd("/").ToLowerInvariant()
        if ($normalizedUrl -notin $reviewed) {
            Write-Warning "Skipping shared-channel site '$($channelSite.Url)': it was not in the reviewed target list."
            continue
        }
        Write-Host "Deleting reviewed shared-channel site $($channelSite.Url) (its Team no longer exists)..."
        Remove-PnPTenantSite -Url $channelSite.Url -Force -Connection $admin -ErrorAction Stop
    }
}
if (-not $group) { Remove-ChannelSitesDirectly -ReviewedSiteUrls @($channelSites | ForEach-Object Url) }

# Teams removes shared-channel sites with the Team; wait for that before reporting.
$deadline = (Get-Date).AddMinutes($WaitMinutes)
do {
    $aliasSites = @(Get-AliasSites -Connection $admin -Alias $MailNickname)
    $activeChannelSites = @(Get-ChannelSites -Connection $admin -Alias $MailNickname)
    # Once the Team's own site is gone, delete channel sites that Teams has not removed yet.
    if ($group -and $aliasSites.Count -eq 0 -and $activeChannelSites.Count -gt 0) {
        Remove-ChannelSitesDirectly -ReviewedSiteUrls @($channelSites | ForEach-Object Url)
        $activeChannelSites = @(Get-ChannelSites -Connection $admin -Alias $MailNickname)
    }
    $activeSites = $aliasSites + $activeChannelSites
    if ($activeSites.Count -eq 0) { break }
    Write-Host "  Waiting for $($activeSites.Count) site(s) to leave the active site list..."
    Start-Sleep -Seconds 30
} while ((Get-Date) -lt $deadline)

$purged = @()
if ($Purge) {
    $deletedGroup = $null
    do {
        $deletedGroup = Get-DeletedGroup -Connection $admin -Alias $MailNickname
        if ($deletedGroup -or -not $group) { break }
        Start-Sleep -Seconds 20
    } while ((Get-Date) -lt $deadline)
    # Purging the group while its site is still active orphans the site, so wait for the site first.
    $sitesBeforeGroupPurge = @(Get-AliasSites -Connection $admin -Alias $MailNickname) + @(Get-ChannelSites -Connection $admin -Alias $MailNickname)
    if ($deletedGroup -and $sitesBeforeGroupPurge.Count -gt 0) {
        Write-Warning "Kept the deleted group in the Entra recycle bin because its site is still active. Run this script again with -Purge later."
        $deletedGroup = $null
    }
    $deletedGroupId = if ($deletedGroup -and $deletedGroup.PSObject.Properties["Id"]) { [string]$deletedGroup.Id } else { "" }
    $groupIdentityVerified = $group -and [string]$group.GroupId -eq $deletedGroupId
    $groupIdentityVerified = $groupIdentityVerified -or ($identityMatches -and $savedTeamId -eq $deletedGroupId)
    if ($deletedGroup -and $groupIdentityVerified) {
        Remove-PnPDeletedMicrosoft365Group -Identity $deletedGroup -Connection $admin -ErrorAction Stop
        $purged += "group $MailNickname"
    } elseif ($deletedGroup) {
        Write-Warning "The deleted group's immutable ID is not verified by this CoE's deployment identity; it was not permanently deleted."
    }
    do {
        $deletedSites = @(Get-DeletedAliasSites -Connection $admin -Alias $MailNickname `
            -ReviewedSiteUrls $reviewedPurgeSiteUrls)
        foreach ($deletedSite in $deletedSites) {
            Remove-PnPTenantDeletedSite -Identity $deletedSite.Url -Force -Connection $admin -ErrorAction Stop
            $purged += $deletedSite.Url
        }
        $stillActive = @(Get-AliasSites -Connection $admin -Alias $MailNickname) + @(Get-ChannelSites -Connection $admin -Alias $MailNickname)
        if ($stillActive.Count -eq 0) { break }
        Start-Sleep -Seconds 30
    } while ((Get-Date) -lt $deadline)
}

$remainingActive = @(Get-AliasSites -Connection $admin -Alias $MailNickname) + @(Get-ChannelSites -Connection $admin -Alias $MailNickname)
if ($Purge) {
    foreach ($url in $reviewedPurgeSiteUrls) {
        $literal = $url.Replace("'", "''")
        $remainingActive += @(Get-PnPTenantSite -Filter "Url -eq '$literal'" -Connection $admin -ErrorAction Stop)
    }
    foreach ($template in @("TEAMCHANNEL#1", "TEAMCHANNEL#0")) {
        $remainingActive += @(Get-PnPTenantSite -Template $template -Connection $admin -ErrorAction Stop |
            Where-Object { [string]$_.RelatedGroupId -ieq $receiptGroupId })
    }
}
$remainingDeleted = @(Get-DeletedAliasSites -Connection $admin -Alias $MailNickname `
    -ReviewedSiteUrls $reviewedPurgeSiteUrls)
$remainingDeletedGroup = if ($Purge) { Get-DeletedGroup -Connection $admin -Alias $MailNickname -GroupId $receiptGroupId } else { $null }
$matchingDeletedSites = @(if ($Purge) {
    $allDeletedSites = @(Get-PnPTenantDeletedSite -Limit 100000 -Connection $admin -ErrorAction Stop)
    if ($allDeletedSites.Count -ge 100000) { throw "Deleted-site enumeration reached its limit. Purge completion is unproven; no receipt was written." }
    $allDeletedSites | Where-Object { ([uri]$_.Url).Segments[-1].TrimEnd("/") -eq $MailNickname }
})
$unknownDeletedSites = @($matchingDeletedSites |
    Where-Object { ([string]$_.Url).TrimEnd("/") -notin $script:authorizedDeletedSiteUrls })
if ($unknownDeletedSites.Count -gt 0) {
    Write-Warning "Unverified recycled site(s) use this exact alias and were not purged: $(($unknownDeletedSites | ForEach-Object Url) -join '; '). Review manually."
}
$remainingActiveGroups = @(if ($Purge) {
    Get-PnPMicrosoft365Group -Filter "mailNickname eq '$MailNickname'" -Connection $admin -ErrorAction Stop
    Get-PnPMicrosoft365Group -Filter "id eq '$receiptGroupId'" -Connection $admin -ErrorAction Stop
})
$aliasReusable = $Purge -and $remainingActiveGroups.Count -eq 0 -and $remainingActive.Count -eq 0 -and $remainingDeleted.Count -eq 0 -and
    $unknownDeletedSites.Count -eq 0 -and -not $remainingDeletedGroup
$purgeReceiptPath = $null
if ($aliasReusable -and -not $WhatIfPreference) {
    $releaseRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $receiptDirectory = $settingsDirectory
    if ($settingsDirectory -ieq $releaseRoot -or
        $settingsDirectory.StartsWith($releaseRoot + "\", [StringComparison]::OrdinalIgnoreCase)) {
        $receiptDirectory = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "CopilotCoE\PurgeReceipts\$([guid]::NewGuid())"
    }
    $purgeReceiptPath = Write-CoEPurgeReceipt -ReceiptPath (Join-Path $receiptDirectory "CoE-Purge-Receipt.json") `
        -Settings $s -Alias $MailNickname -GroupId $receiptGroupId -SiteUrl $receiptSiteUrl `
        -SiteUrls $reviewedPurgeSiteUrls -AliasReusable $aliasReusable -Purge:$Purge -ReleaseRoot $releaseRoot
    if ($purgeReceiptPath) { Write-Host "Completed purge receipt (keep private): $purgeReceiptPath" }
    if (Test-Path -LiteralPath $removalManifestPath) { Remove-Item -LiteralPath $removalManifestPath -Force }
    if (Test-Path -LiteralPath $reportPath) { Remove-Item -LiteralPath $reportPath -Force }
}
Write-Host ""
if ($remainingActive.Count -gt 0) {
    Write-Warning "Still active after $WaitMinutes minutes: $(($remainingActive | ForEach-Object Url) -join '; '). Microsoft 365 may need more time. Run this script again later with the same switches."
}
if ($Purge -and $remainingDeleted.Count -gt 0) {
    Write-Warning "Still in the SharePoint recycle bin: $(($remainingDeleted | ForEach-Object Url) -join '; '). Run this script again with -Purge later."
}
Write-Host "To also remove the sign-in app: Entra admin center > App registrations > All applications >"
Write-Host "  'Copilot CoE Provisioning (PnP)' ($($s.PnPClientID)) > Delete. Then clear PnPClientID in $SettingsPath."
if (-not $Purge) {
    Write-Host "CoE identity reports were preserved for a future identity-verified purge."
}

[pscustomobject]@{
    Alias            = $MailNickname
    GroupDeleted     = [bool]$group
    SitesStillActive = @($remainingActive | ForEach-Object Url) -join "; "
    Purged           = $purged -join "; "
    InRecycleBin     = if ($Purge) { @($remainingDeleted | ForEach-Object Url) -join "; " } else { "Restorable for 30 days (group and sites)" }
    AliasReusable    = $aliasReusable
    PurgeReceiptPath = $purgeReceiptPath
}
