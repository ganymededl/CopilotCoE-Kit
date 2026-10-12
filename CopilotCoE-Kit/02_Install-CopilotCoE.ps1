#Requires -Version 7.4
<#
.SYNOPSIS
Builds the Copilot Center of Excellence Team and SharePoint site in your tenant.

.DESCRIPTION
STEP 2 OF 3. Run after 01_Register-CoEProvisioningApp.ps1 has saved PnPClientID
and all five app permissions show Granted in Entra.
    .\02_Install-CopilotCoE.ps1 -SeedDemoContent
Reads Deployment-Settings.json (tenant, hosts, owner, names). Any parameter
supplied on the command line overrides the settings file. If PnPClientID is
still empty, the script stops before signing in and nothing is created.
Afterwards, use 03_Update-CoEContent.ps1 to publish edited starter content.
If a run stops partway, fix the cause and re-run with -ResumeExisting; it reuses
the Team and site and preserves existing managed pages. To remove the
CoE completely, use 04_Remove-CopilotCoE.ps1 (preview with -WhatIf first).
If Get-PnPFile reports that the request was canceled because the configured
HttpClient.Timeout of 100 seconds elapsed, do not start a fresh install or
purge the CoE. Confirm the existing Team and site are the intended CoE, then
rerun the same command with -ResumeExisting.
#>
[CmdletBinding()]
param(
    [string]$OrgPath,
    [string]$SettingsPath,
    [string]$AdminFQDN,
    [string]$SiteFQDN,
    [string]$PnPClientID,
    [string]$Tenant,
    [string]$OrgName,
    [string]$OrgNoun,
    [string]$MailNickname,
    [string]$DisplayName,
    [string]$SharedChannelOwnerUPN,
    [string]$ShortName,
    [string]$EnvironmentLabel,
    [string]$SampleNotice,
    [string]$SupportEmail,
    [ValidateSet("Interactive", "DeviceLogin")]
    [string]$AuthenticationMode = "Interactive",
    [switch]$ForceAuthentication,
    [switch]$ResumeExisting,
    [switch]$SeedDemoContent,
    [switch]$ReplaceManagedFiles,
    [switch]$ReplaceOrgAssets,
    [switch]$AcceptOrgAssets,
    [switch]$AllowMissingDataSafetyIncidentRoute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Every run keeps a transcript. A terminating error anywhere below is caught by this trap, so the log is
# closed and its location reported even when the run stops partway; the body itself is not wrapped.
. (Join-Path $PSScriptRoot "Internal\RunLog.ps1")
$script:CoERunLog = Start-CoERunLog -KitRoot $PSScriptRoot -Script "02_Install-CopilotCoE" -OrgPath $OrgPath
trap {
    Write-Host ("[{0}] STOPPED: {1}" -f (Get-Date).ToString("HH:mm:ss"), $_.Exception.Message) -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    Stop-CoERunLog -Log $script:CoERunLog -Succeeded $false
    break
}

# An organization folder carries everything organization-specific: Deployment-Settings.json,
# Content overrides, and Assets to host. The kit itself stays the same for every organization.
if ($OrgPath) {
    if (-not (Test-Path -LiteralPath $OrgPath -PathType Container)) { throw "Organization folder not found: $OrgPath" }
    $OrgPath = (Resolve-Path -LiteralPath $OrgPath).Path
    if (-not $SettingsPath) { $SettingsPath = Join-Path $OrgPath "Deployment-Settings.json" }
    Write-Host "Organization folder: $OrgPath"
} else {
    Write-Host "No -OrgPath given: using the kit's settings file and generic starter content only."
}
if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "Deployment-Settings.json" }
$settings = $null
if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
    $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
    Write-Host "Using settings from $SettingsPath (command-line values override it)."
} elseif ($OrgPath) {
    throw "The organization folder has no Deployment-Settings.json: $SettingsPath"
}
$TeamVisibility = if ($settings -and $settings.PSObject.Properties["TeamVisibility"] -and $settings.TeamVisibility) {
    [string]$settings.TeamVisibility
} else { "Private" }
if ($TeamVisibility -ne "Private") { throw "TeamVisibility must be Private. Public CoE Teams are not supported." }
$OrganizationEmailDomains = @()
if ($settings -and $settings.PSObject.Properties["OrganizationEmailDomains"]) {
    $OrganizationEmailDomains = @($settings.OrganizationEmailDomains | ForEach-Object { [string]$_ })
}
$GovernanceAdditionalAllowedMembers = @()
if ($settings -and $settings.PSObject.Properties["GovernanceAdditionalAllowedMembers"]) {
    $GovernanceAdditionalAllowedMembers = @($settings.GovernanceAdditionalAllowedMembers | ForEach-Object { [string]$_ })
}
$defaults = @{
    MailNickname = "CopilotCoE"
    EnvironmentLabel = "Pilot"
}
foreach ($name in @("AdminFQDN", "SiteFQDN", "PnPClientID", "Tenant", "MailNickname",
        "SharedChannelOwnerUPN", "EnvironmentLabel", "SupportEmail")) {
    if ($PSBoundParameters.ContainsKey($name)) { continue }
    $value = $null
    if ($settings -and $settings.PSObject.Properties[$name]) { $value = [string]$settings.$name }
    if ([string]::IsNullOrWhiteSpace($value) -and $defaults.ContainsKey($name)) { $value = $defaults[$name] }
    Set-Variable -Name $name -Value $value
}
. (Join-Path $PSScriptRoot "Internal\OrganizationProfile.ps1")
$profileOverrides = @{}
foreach ($name in @("OrgName", "OrgNoun", "ShortName", "DisplayName", "SampleNotice")) {
    if ($PSBoundParameters.ContainsKey($name)) { $profileOverrides[$name] = $PSBoundParameters[$name] }
}
$organizationProfile = Get-CoEOrganizationProfile -Settings $settings -Overrides $profileOverrides
foreach ($property in $organizationProfile.PSObject.Properties) {
    Set-Variable -Name $property.Name -Value $property.Value
}
# Preserve the deliberate "none" choice when another script resolves the same profile.
$sampleNoticeArgument = if ($SampleNotice -eq "") { "none" } else { $SampleNotice }

foreach ($required in @("Tenant", "AdminFQDN", "SiteFQDN", "SharedChannelOwnerUPN", "SupportEmail", "EnvironmentLabel")) {
    $value = Get-Variable -Name $required -ValueOnly
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match "[<>]|\{\{|\}\}") {
        throw "Set $required in $SettingsPath (or pass -$required). Replace every <placeholder> with your organization's value."
    }
}
if ($Tenant -notmatch "^[A-Za-z0-9-]+\.onmicrosoft\.com$") { throw "Tenant must look like yourtenant.onmicrosoft.com." }
if ($MailNickname -notmatch "^[A-Za-z0-9_-]{1,64}$") { throw "MailNickname may use letters, numbers, hyphen, and underscore only." }
if ($DisplayName.Length -gt 256) { throw "DisplayName must be 256 characters or fewer." }
if ($SharedChannelOwnerUPN -notmatch "^[^@\s]+@[^@\s]+\.[^@\s]+$") { throw "SharedChannelOwnerUPN must be a sign-in address." }
if ($SupportEmail -notmatch "^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$") { throw "SupportEmail must be an email address (the CoE help desk mailbox)." }
if (-not $AllowMissingDataSafetyIncidentRoute) {
    $dataSafetyIncidentRoute = ""
    if ($settings -and $settings.PSObject.Properties["Links"] -and $settings.Links -and
        $settings.Links.PSObject.Properties["DataSafetyIncident"]) {
        if ($settings.Links.DataSafetyIncident -isnot [string]) { throw "Links.DataSafetyIncident must be an absolute HTTPS URL." }
        $dataSafetyIncidentRoute = $settings.Links.DataSafetyIncident.Trim()
    }
    $incidentUri = $null
    if ([string]::IsNullOrWhiteSpace($dataSafetyIncidentRoute) -or
        $dataSafetyIncidentRoute -match "[<>]|\{\{|\}\}" -or
        -not [uri]::TryCreate($dataSafetyIncidentRoute, [UriKind]::Absolute, [ref]$incidentUri) -or
        $incidentUri.Scheme -ne "https" -or -not $incidentUri.Host -or $incidentUri.UserInfo) {
        throw "Links.DataSafetyIncident must be configured as an absolute HTTPS URL before install creates tenant resources. For validation-only builds, rerun with -AllowMissingDataSafetyIncidentRoute."
    }
}

# Accept pasted URLs: strip any https:// prefix, path, and trailing slash so only the host name remains.
$AdminFQDN = ($AdminFQDN.Trim() -replace "^https?://", "" -replace "/.*$", "").ToLowerInvariant()
$SiteFQDN = ($SiteFQDN.Trim() -replace "^https?://", "" -replace "/.*$", "").ToLowerInvariant()

if ($AdminFQDN -notmatch "^[A-Za-z0-9-]+-admin\.sharepoint\.com$") {
    throw "AdminFQDN must be the SharePoint admin host, for example tenant-admin.sharepoint.com."
}
if ($SiteFQDN -notmatch "^[A-Za-z0-9-]+\.sharepoint\.com$") {
    throw "SiteFQDN must be the SharePoint tenant host, for example tenant.sharepoint.com."
}

Import-Module PnP.PowerShell -RequiredVersion 3.2.0 -ErrorAction Stop
. (Join-Path $PSScriptRoot "Internal\SecurityPosture.ps1")
. (Join-Path $PSScriptRoot "Internal\ResourceTabs.ps1")
$CoESiteSharingCapability = Get-CoEParentSharingCapability -Settings $settings
$OrganizationEmailDomains = @(Get-CoEOrganizationDomains -Domains $OrganizationEmailDomains)
if ($ForceAuthentication -and $AuthenticationMode -ne "Interactive") {
    throw "-ForceAuthentication requires -AuthenticationMode Interactive."
}
foreach ($address in $GovernanceAdditionalAllowedMembers) {
    if ($address -notmatch "^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$") {
        throw "GovernanceAdditionalAllowedMembers contains an invalid sign-in address: '$address'. Nothing was created."
    }
}

if ([string]::IsNullOrWhiteSpace($PnPClientID)) {
    throw "PnPClientID is empty in $SettingsPath. Run .\01_Register-CoEProvisioningApp.ps1 first as an approved consent approver with required admin authority, confirm all five permissions show Granted in Entra, then run this script again. Nothing was created."
}
if ($PnPClientID -notmatch "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$") {
    throw "PnPClientID must be the app's Application (client) ID GUID."
}

$prepareScript = Join-Path $PSScriptRoot "Internal\Prepare-CopilotCoE.ps1"
# Optional HomeTiles in Deployment-Settings.json: five { "title", "page" [, "image"] } entries for the home page hero.
$homeTilesJson = ""
if ($settings -and $settings.PSObject.Properties["HomeTiles"] -and $settings.HomeTiles) {
    $homeTilesJson = ConvertTo-Json @($settings.HomeTiles) -Depth 5 -Compress
}
$prepareArgs = @{ DisplayName = $DisplayName; ShortName = $ShortName; EnvironmentLabel = $EnvironmentLabel
    SampleNotice = $sampleNoticeArgument; OrgName = $OrgName; OrgNoun = $OrgNoun; HomeTilesJson = $homeTilesJson }
# Optional ScenarioLibraryUrl: the Teams Scenario Library tab (default: education scenarios).
if ($settings -and $settings.PSObject.Properties["ScenarioLibraryUrl"] -and $settings.ScenarioLibraryUrl) {
    $scenarioUri = $null
    if (-not [uri]::TryCreate([string]$settings.ScenarioLibraryUrl, [UriKind]::Absolute, [ref]$scenarioUri) -or
        $scenarioUri.Scheme -ne "https") {
        throw "ScenarioLibraryUrl must be an absolute HTTPS URL. Nothing was created."
    }
    $prepareArgs.ScenarioLibraryUrl = $scenarioUri.AbsoluteUri
}
& $prepareScript @prepareArgs | Out-Null

$pnpPackage = Join-Path $PSScriptRoot "CopilotCoESite.pnp"
$teamTemplate = Join-Path $PSScriptRoot "TeamTemplate-CoE.xml"
$sourceFolder = Join-Path (Split-Path -Parent $PSScriptRoot) "SourceOriginal\CopilotCoESite"
$adminUrl = "https://$AdminFQDN/"

foreach ($path in @($pnpPackage, $teamTemplate)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required CoE build artifact was not generated: $path"
    }
}

Write-Host "Connecting to the specified tenant administrator endpoint using $AuthenticationMode sign-in."
$signIn = @{
    Url = $adminUrl; ClientId = $PnPClientID; Tenant = $Tenant
    PersistLogin = $true; ReturnConnection = $true; ErrorAction = "Stop"
}
$signIn[$AuthenticationMode] = $true
if ($ForceAuthentication) { $signIn.ForceAuthentication = $true }
$adminConnection = Connect-PnPOnline @signIn

# Read-only preflight: shared-channel creation looks up the owner in Microsoft Graph. That needs the
# delegated User.Read.All permission to read Member/Guest account type for other users.
try {
    $ownerIdentity = Invoke-PnPGraphMethod -Url "v1.0/users/$([uri]::EscapeDataString($SharedChannelOwnerUPN))?`$select=id,userPrincipalName,userType,mail" `
        -Method Get -Connection $adminConnection -ErrorAction Stop
} catch {
    throw ("Cannot look up SharedChannelOwnerUPN '$SharedChannelOwnerUPN' in Microsoft Graph: $($_.Exception.Message) " +
        "If it says 'Insufficient privileges', add the delegated Microsoft Graph permission User.Read.All to the " +
        "'Copilot CoE Provisioning (PnP)' app in Entra, grant admin consent, then re-run with -ForceAuthentication for a fresh interactive sign-in. " +
        "Otherwise check that the owner account exists. Nothing was changed.")
}
Assert-CoEMemberIdentity -Identity $ownerIdentity -Address $SharedChannelOwnerUPN
foreach ($address in $GovernanceAdditionalAllowedMembers) {
    $identity = Invoke-PnPGraphMethod -Url "v1.0/users/$([uri]::EscapeDataString($address))?`$select=id,userPrincipalName,userType" `
        -Method Get -Connection $adminConnection -ErrorAction Stop
    Assert-CoEMemberIdentity -Identity $identity -Address $address
}

$matchingGroups = @(Get-PnPMicrosoft365Group `
    -Filter "mailNickname eq '$MailNickname'" `
    -IncludeSiteUrl `
    -Connection $adminConnection `
    -ErrorAction Stop)
if ($matchingGroups.Count -gt 1) { throw "Multiple groups match alias '$MailNickname'." }
$activeGroup = if ($matchingGroups.Count -eq 1) { $matchingGroups[0] } else { $null }

if ($ResumeExisting) {
    if (-not $activeGroup -or -not $activeGroup.GroupId) {
        throw "Resume mode requires the existing Microsoft 365 group '$MailNickname'; none was found."
    }

    $coeGroup = $activeGroup
    Write-Host "Resume mode: using the existing Team and SharePoint site without recreating either resource."
}
else {
    if ($activeGroup) {
        throw "An active Microsoft 365 group already uses alias '$MailNickname'. Use -ResumeExisting only after confirming it is the intended CoE lab Team."
    }

    $deletedGroup = Get-PnPDeletedMicrosoft365Group `
        -Identity $MailNickname `
        -Connection $adminConnection `
        -ErrorAction Stop
    if ($deletedGroup) {
        throw "A deleted Microsoft 365 group uses alias '$MailNickname'. Review it manually before retrying; this script never purges deleted groups."
    }

    $activeSites = @(
        Get-PnPTenantSite `
            -Filter "Url -like '*/$MailNickname'" `
            -Connection $adminConnection `
            -ErrorAction Stop |
            Where-Object { ([uri]$_.Url).Segments[-1].TrimEnd("/") -eq $MailNickname }
    )
    if ($activeSites.Count -gt 0) {
        $urls = ($activeSites | ForEach-Object { $_.Url }) -join "; "
        throw "An active SharePoint site already uses alias '$MailNickname': $urls. No changes were made."
    }

    $deletedSites = @(
        Get-PnPTenantDeletedSite `
            -Limit 100000 `
            -Connection $adminConnection `
            -ErrorAction Stop |
            Where-Object { ([uri]$_.Url).Segments[-1].TrimEnd("/") -eq $MailNickname }
    )
    if ($deletedSites.Count -gt 0) {
        $urls = ($deletedSites | ForEach-Object { $_.Url }) -join "; "
        throw "A deleted SharePoint site uses alias '$MailNickname': $urls. Review it manually before continuing; this script never purges deleted sites."
    }

    Write-Host "Read-only preflight passed. Creating the $TeamVisibility $ShortName Copilot CoE Team and its SharePoint site."
    Invoke-PnPTenantTemplate `
        -Path $pnpPackage `
        -Parameters @{
            displayName = $DisplayName
            mailNickname = $MailNickname
        } `
        -Connection $adminConnection `
        -ErrorAction Stop

    $coeGroup = Get-PnPMicrosoft365Group `
        -Identity $MailNickname `
        -IncludeSiteUrl `
        -Connection $adminConnection `
        -ErrorAction Stop
    if (-not $coeGroup -or -not $coeGroup.GroupId) {
        throw "The provisioning template completed without returning the expected Microsoft 365 group."
    }
}

$coeSites = @(
    Get-PnPTenantSite `
        -Filter "Url -like '*/$MailNickname'" `
        -Connection $adminConnection `
        -ErrorAction Stop |
        Where-Object { ([uri]$_.Url).Segments[-1].TrimEnd("/") -eq $MailNickname }
)
if ($coeSites.Count -ne 1) {
    throw "Expected one new SharePoint site for '$MailNickname'; found $($coeSites.Count). Review the tenant before continuing."
}
$coeUrl = $coeSites[0].Url
$null = Set-CoESiteSharing -SiteUrl $coeUrl -SharingCapability $CoESiteSharingCapability -Connection $adminConnection

Set-PnPTeamsTeam `
    -Identity $MailNickname `
    -Visibility $TeamVisibility `
    -Description "$DisplayName. $SampleNotice" `
    -Connection $adminConnection `
    -ErrorAction Stop

if ($ResumeExisting -and $coeSites.Count -ne 1) {
    throw "Resume mode requires exactly one existing SharePoint site for '$MailNickname'; found $($coeSites.Count)."
}

Write-Host "Reusing the approved administrator sign-in for the SharePoint site connection."
$siteConnection = Connect-PnPOnline `
    -Url $coeUrl `
    -Connection $adminConnection `
    -ReturnConnection `
    -ErrorAction Stop

$segments = ([uri]$coeUrl).Segments
$inclusionPath = $segments[$segments.Length - 2].TrimEnd("/")
$coePath = "$inclusionPath/$MailNickname"
Set-PnPWebHeader `
    -SiteLogoUrl "/$coePath/SiteAssets/copilot/copilotlogo_transp.png" `
    -Connection $siteConnection `
    -ErrorAction Stop

if ($ResumeExisting) {
    $requiredPageNames = @(
        "Adoption-Best-Practices.aspx",
        "Copilot-on-Microsoft-Mechanics.aspx",
        "Meet-your-Champions.aspx",
        "Technical Readiness.aspx",
        "TrainingHome.aspx"
    )
    $existingPageNames = @(
        Get-PnPPage -Connection $siteConnection -ErrorAction Stop |
            ForEach-Object { $_.Name }
    )
    $missingPageNames = @(
        $requiredPageNames | Where-Object { $_ -notin $existingPageNames }
    )
    $presentPageNames = @($requiredPageNames | Where-Object { $_ -in $existingPageNames })
    if ($presentPageNames.Count -eq 0) {
        # A site with none of the CoE pages means the first site-package run stopped
        # part-way; finish it. Partially customized sites are never overwritten.
        Write-Host "The existing site has none of the CoE pages, so the first site-package run did not finish. Applying the site package to complete it."
        Invoke-PnPSiteTemplate `
            -Path $pnpPackage `
            -TemplateId "CopilotCoETemplate" `
            -Parameters @{
                displayName = $DisplayName
                mailNickname = $MailNickname
            } `
            -Connection $siteConnection `
            -ErrorAction Stop
        $existingPageNames = @(
            Get-PnPPage -Connection $siteConnection -ErrorAction Stop |
                ForEach-Object { $_.Name }
        )
        $missingPageNames = @(
            $requiredPageNames | Where-Object { $_ -notin $existingPageNames }
        )
    }
    if ($missingPageNames.Count -gt 0) {
        throw "The existing site is missing required CoE pages: $($missingPageNames -join ', ')."
    }

    $checklist = Get-PnPList `
        -Identity "Copilot Adoption Checklist" `
        -Connection $siteConnection `
        -ErrorAction Stop
    $checklistRows = @(
        Get-PnPListItem `
            -List $checklist `
            -PageSize 50 `
            -Connection $siteConnection `
            -ErrorAction Stop
    )
    if ($checklistRows.Count -lt 16) {
        throw "The existing Copilot Adoption Checklist has only $($checklistRows.Count) rows; expected at least 16."
    }

    $siteAssetFiles = @(
        Get-PnPFolderItem `
            -FolderSiteRelativeUrl "SiteAssets" `
            -Recursive `
            -ItemType File `
            -Connection $siteConnection `
            -ErrorAction Stop
    )
    $assetManifest = @(Get-Content (Join-Path $PSScriptRoot "SiteAssetManifest.json") -Raw | ConvertFrom-Json)
    $siteRelativePrefix = ([uri]$coeUrl).AbsolutePath.TrimEnd("/") + "/"
    $actualAssetPaths = @($siteAssetFiles | ForEach-Object {
        [uri]::UnescapeDataString($_.ServerRelativeUrl).Substring($siteRelativePrefix.Length)
    })
    $missingAssets = @($assetManifest | Where-Object { $_ -notin $actualAssetPaths })
    if ($missingAssets.Count -gt 0) {
        throw "The existing site is missing exact packaged assets: $($missingAssets -join ', '). Resume does not overwrite the site template; repair these files explicitly."
    }
    Write-Host "Resume preflight passed: CoE pages, checklist data, and packaged Site Assets are present; skipping the already-applied site package."
}

$teamParameters = @{
    groupid = $coeGroup.GroupId
    displayName = $DisplayName
    inclusionPath = $inclusionPath
    mailNickname = $MailNickname
    fqdn = ([uri]$coeUrl).Host
}
$standardChannelSpecs = @(Get-CoEStandardChannelSpec -Path $teamTemplate -Parameters $teamParameters -SiteUrl $coeUrl)
if (-not $ResumeExisting) {
    # Apply Team settings only. Captured channel/tab IDs and welcome posts are not deployment identities.
    $settingsTemplate = [xml](Get-Content -LiteralPath $teamTemplate -Raw -Encoding UTF8)
    foreach ($node in @($settingsTemplate.SelectNodes("//*[local-name()='Team']/*[local-name()='Channels']"))) {
        [void]$node.ParentNode.RemoveChild($node)
    }
    Invoke-PnPTenantTemplate `
        -Template (Read-PnPTenantTemplate -Xml $settingsTemplate.OuterXml -ErrorAction Stop) `
        -Parameters $teamParameters `
        -Connection $adminConnection `
        -ErrorAction Stop
}
$standardChannels = @(Ensure-CoEStandardChannels -Team $coeGroup.GroupId -Specifications $standardChannelSpecs -Connection $adminConnection)
$resourceApps = @(Get-CoETeamResourceApps -Team $coeGroup.GroupId -Connection $adminConnection)
$resourceTabChoices = @()

# Use verified runtime channel IDs for folders and tabs, including after a partial template run.
$promptChannel = Get-CoEVerifiedStandardChannel $standardChannels "Share Your Prompt"
$promptSpec = @($standardChannelSpecs | Where-Object DisplayName -eq "Share Your Prompt")[0]
$promptFileSpec = @($promptSpec.Tabs | Where-Object Type -eq "PDF")[0]
$promptFolderUrl = $promptFileSpec.ContentUrl.Substring(0, $promptFileSpec.ContentUrl.LastIndexOf('/'))
$promptFolder = Get-CoEStandardChannelFilesFolder -Team $coeGroup.GroupId -Channel $promptChannel.Id `
    -SiteUrl $coeUrl -ExpectedFolderUrl $promptFolderUrl -Connection $siteConnection
$promptPath = [uri]::UnescapeDataString(([uri]$promptFolder.webUrl).AbsolutePath).Substring(([uri]$coeUrl).AbsolutePath.Length).TrimStart("/")
Resolve-PnPFolder -SiteRelativePath $promptPath -Connection $siteConnection -ErrorAction Stop | Out-Null

$existingPromptFiles = @(
    Get-PnPFolderItem `
        -FolderSiteRelativeUrl $promptPath `
        -ItemType File `
        -Connection $siteConnection `
        -ErrorAction Stop |
        ForEach-Object { $_.Name }
)

$shareYourPromptFiles = @(
    "Prompt-dos-and-donts-one-pager.pdf",
    "Prompt-ingredients-one-pager.pdf",
    "ScenarioUseCaseTemplate.pptx"
)
foreach ($fileName in $shareYourPromptFiles) {
    $filePath = Join-Path (Join-Path $sourceFolder "ShareYourPrompt") $fileName
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw "A required prompt resource was not found: $filePath"
    }
    if ($fileName -notin $existingPromptFiles) {
        Add-PnPFile `
            -Path $filePath `
            -Folder $promptPath `
            -Connection $siteConnection `
            -ErrorAction Stop | Out-Null
    }
}

foreach ($channelSpec in $standardChannelSpecs) {
    $channel = Get-CoEVerifiedStandardChannel $standardChannels $channelSpec.DisplayName
    foreach ($tabSpec in $channelSpec.Tabs) {
        # Completion selects and preserves organization Top 10 decks; do not reset that selection on resume.
        if ($SeedDemoContent -and $tabSpec.DisplayName -eq "Top 10 to try") { continue }
        $effectiveTabSpec = Resolve-CoEResourceTabCapability -Team $coeGroup.GroupId -Channel $channel.Id `
            -Specification $tabSpec -InstalledApps $resourceApps -SiteUrl $coeUrl `
            -SiteConnection $siteConnection -Connection $adminConnection
        $fileId = ""
        if ($tabSpec.Type -in @("PDF", "PowerPoint")) {
            if ($tabSpec.DisplayName -eq "Top 10 to try") {
                $askFolderUrl = $tabSpec.ContentUrl.Substring(0, $tabSpec.ContentUrl.LastIndexOf('/'))
                $askFolder = Get-CoEStandardChannelFilesFolder -Team $coeGroup.GroupId -Channel $channel.Id `
                    -SiteUrl $coeUrl -ExpectedFolderUrl $askFolderUrl -Connection $siteConnection
                $askPath = [uri]::UnescapeDataString(([uri]$askFolder.webUrl).AbsolutePath).Substring(([uri]$coeUrl).AbsolutePath.Length).TrimStart("/")
                $handoutName = [uri]::UnescapeDataString(([uri]$tabSpec.ContentUrl).Segments[-1])
                $existingHandout = @(Get-PnPFolderItem -FolderSiteRelativeUrl $askPath -ItemType File -Connection $siteConnection -ErrorAction Stop |
                    Where-Object Name -eq $handoutName)
                if (-not $existingHandout.Count) {
                    Add-PnPFile -Path (Join-Path $PSScriptRoot $handoutName) -Folder $askPath -Connection $siteConnection -ErrorAction Stop | Out-Null
                }
            }
            $fileId = Get-CoEManagedFileIdentity -FileUrl $tabSpec.ContentUrl -SiteUrl $coeUrl -Connection $siteConnection
        }
        Sync-CoEManagedResourceTab -Team $coeGroup.GroupId -Channel $channel.Id -Specification $effectiveTabSpec `
            -EntityId $fileId -Connection $adminConnection | Out-Null
        $resourceTabChoices += [pscustomobject]@{
            Channel = $channelSpec.DisplayName; Tab = $tabSpec.DisplayName; OriginalUrl = $tabSpec.WebsiteUrl
            TabUrl = $effectiveTabSpec.WebsiteUrl; Type = $effectiveTabSpec.Type
            ProvisioningMode = $(if ($effectiveTabSpec.Type -ne $tabSpec.Type) { "SharePointResourceLink" } else { "NativeResourceTab" })
            ResourcePageUrl = Get-CoEResourceProperty $effectiveTabSpec "ResourcePageUrl"
        }
        Write-Host "Verified '$($channelSpec.DisplayName) / $($tabSpec.DisplayName)' at $($effectiveTabSpec.WebsiteUrl)"
    }
}

$channels = @(
    Get-PnPTeamsChannel `
        -Team $coeGroup.GroupId `
        -Connection $adminConnection `
        -ErrorAction Stop
)
# Teams requires a shared channel's owner to be an owner of the parent Team, in Teams' own roster.
# Add the group membership first, then ownership: adding membership after ownership can leave Teams'
# roster showing the account as an ordinary member even though the Microsoft 365 group lists it as an
# owner (Graph then rejects the channel with InvalidUsersInCreateChannelRequest).
$groupMembers = @(Get-PnPMicrosoft365GroupMember -Identity $coeGroup.GroupId -Connection $adminConnection -ErrorAction Stop |
    ForEach-Object { $_.UserPrincipalName })
if ($SharedChannelOwnerUPN -notin $groupMembers) {
    Add-PnPMicrosoft365GroupMember -Identity $coeGroup.GroupId -Users $SharedChannelOwnerUPN -Connection $adminConnection -ErrorAction Stop
}
$teamOwners = @(Get-PnPTeamsUser -Team $coeGroup.GroupId -Role Owner -Connection $adminConnection -ErrorAction Stop |
    ForEach-Object { $_.UserPrincipalName })
if ($SharedChannelOwnerUPN -notin $teamOwners) {
    Write-Host "Adding $SharedChannelOwnerUPN as a Team owner (required to own the governance shared channels)."
    Add-PnPTeamsUser -Team $coeGroup.GroupId -User $SharedChannelOwnerUPN -Role Owner -Connection $adminConnection -ErrorAction Stop
}
# Confirm the role in Teams' roster (the General channel's member list), and re-apply ownership if it lags.
$generalChannel = @($channels | Where-Object DisplayName -eq "General") | Select-Object -First 1
if ($generalChannel) {
    $rosterOwner = $false
    for ($check = 1; $check -le 12 -and -not $rosterOwner; $check++) {
        $rosterEntry = @(Get-PnPTeamsChannelUser -Team $coeGroup.GroupId -Channel $generalChannel.Id -Connection $adminConnection -ErrorAction Stop |
            Where-Object { $_.Email -eq $SharedChannelOwnerUPN }) | Select-Object -First 1
        $rosterOwner = $rosterEntry -and (@($rosterEntry.Roles) -contains "owner")
        if (-not $rosterOwner) {
            if ($check -eq 3) {
                Write-Host "  Teams lists $SharedChannelOwnerUPN as a member, not an owner; re-applying ownership."
                Remove-PnPMicrosoft365GroupOwner -Identity $coeGroup.GroupId -Users $SharedChannelOwnerUPN -Connection $adminConnection -ErrorAction Stop
                Start-Sleep -Seconds 15
                Add-PnPMicrosoft365GroupOwner -Identity $coeGroup.GroupId -Users $SharedChannelOwnerUPN -Connection $adminConnection -ErrorAction Stop
            }
            Start-Sleep -Seconds 20
        }
    }
    if (-not $rosterOwner) {
        throw "Teams does not list $SharedChannelOwnerUPN as a Team owner. No governance channel was created; correct ownership and resume."
    }
}
foreach ($sharedChannel in @(
    @{
        DisplayName = "Leadership Governance"
        Description = "Restricted workroom for AI policy, risk, and resource decisions. Add members only after their identities and access are approved."
    },
    @{
        DisplayName = "Program Governance"
        Description = "Restricted workroom for CoE delivery, readiness, training, and support. Add members only after their identities and access are approved."
    }
)) {
    $existingChannel = @(
        $channels | Where-Object {
            $_.DisplayName -eq $sharedChannel.DisplayName
        }
    ) | Select-Object -First 1
    if ($existingChannel) {
        if ($existingChannel.MembershipType -ne "shared") {
            throw "The channel '$($sharedChannel.DisplayName)' already exists but is not shared; no channel was changed."
        }
        continue
    }

    # Wait for the approved owner's role to propagate; never substitute a different administrator.
    $maxAttempts = 6
    $created = $false
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Add-PnPTeamsChannel `
                -Team $coeGroup.GroupId `
                -DisplayName $sharedChannel.DisplayName `
                -Description $sharedChannel.Description `
                -ChannelType Shared `
                -OwnerUPN $SharedChannelOwnerUPN `
                -Connection $adminConnection `
                -ErrorAction Stop | Out-Null
            $created = $true
            break
        } catch {
            if ($_.Exception.Message -notmatch "must be a team owner") { throw }
            if ($attempt -lt $maxAttempts) {
                Write-Host "  Waiting for Team ownership to take effect before creating '$($sharedChannel.DisplayName)' (attempt $attempt of $maxAttempts)..."
                Start-Sleep -Seconds 30
            }
        }
    }
    if (-not $created) {
        throw "Teams did not accept the approved owner for '$($sharedChannel.DisplayName)'. No fallback administrator was added; correct ownership and resume."
    }
}

$sitePageContentType = Get-PnPContentType `
    -Identity "Site Page" `
    -Includes FieldLinks `
    -Connection $siteConnection `
    -ErrorAction Stop
$sitePageContentType.ReadOnly = $false
$sitePageContentType.Update($true)
Invoke-PnPQuery -Connection $siteConnection -ErrorAction Stop

$linkedFieldNames = @($sitePageContentType.FieldLinks | ForEach-Object { $_.Name })
foreach ($fieldName in @("Hash", "NewsSource")) {
    if ($fieldName -notin $linkedFieldNames) {
        Add-PnPFieldToContentType `
            -Field $fieldName `
            -ContentType "Site Page" `
            -UpdateChildren $true `
            -Connection $siteConnection `
            -ErrorAction Stop
    }
}

$noticeHtml = [System.Net.WebUtility]::HtmlEncode($SampleNotice)
$projectTeamHtml = @"
<h2>CoE roles and contacts</h2>
<p>$noticeHtml</p>
<h3>Roles to confirm before a production rollout</h3>
<ul>
<li>Executive sponsor and decision owner</li>
<li>CoE program owner and Teams/SharePoint owner</li>
<li>Microsoft 365 and Copilot service administrators</li>
<li>Security, privacy, accessibility, and records stakeholders</li>
<li>Champions for each department or unit</li>
<li>Service desk, training, and feedback contacts</li>
</ul>
<p>Named contacts for each role are listed here once they are confirmed. Until then, ask in the Ask Us Anything channel or use the Service Catalog and Support page.</p>
"@

$projectTeamPage = @(Get-PnPPage -Connection $siteConnection -ErrorAction Stop |
    Where-Object Name -eq "Meet-your-ProjectTeam.aspx") | Select-Object -First 1
if (-not $projectTeamPage) {
    $projectTeamPage = Add-PnPPage `
        -Name "Meet-your-ProjectTeam" `
        -Title "CoE roles and contacts" `
        -ContentType "Site Page" `
        -Connection $siteConnection `
        -ErrorAction Stop

    Add-PnPPageTextPart `
        -Page $projectTeamPage `
        -Text $projectTeamHtml `
        -Connection $siteConnection `
        -ErrorAction Stop | Out-Null
    Set-PnPPage `
        -Identity "Meet-your-ProjectTeam" `
        -Publish `
        -Connection $siteConnection `
        -ErrorAction Stop | Out-Null
}

$finalChannels = @(
    Get-PnPTeamsChannel `
        -Team $coeGroup.GroupId `
        -Connection $adminConnection `
        -ErrorAction Stop
)
foreach ($channel in $standardChannels) {
    if (-not (Get-CoEVerifiedStandardChannel $finalChannels $channel.DisplayName $channel.Id)) {
        throw "The expected standard channel '$($channel.DisplayName)' disappeared."
    }
}
$requiredChannels = @(
    "General",
    "Share Your Prompt",
    "Ask Us Anything 📢",
    "Leadership Governance",
    "Program Governance"
)
$missingChannels = @(
    $requiredChannels | Where-Object {
        $_ -notin @($finalChannels | ForEach-Object { $_.DisplayName })
    }
)
if ($missingChannels.Count -gt 0) {
    throw "The Team is missing expected channels: $($missingChannels -join ', ')."
}

$finalTeam = Get-PnPTeamsTeam `
    -Identity $MailNickname `
    -Connection $adminConnection `
    -ErrorAction Stop
if ($finalTeam.Visibility -ne $TeamVisibility) {
    throw "The Team visibility is '$($finalTeam.Visibility)', not the explicitly configured '$TeamVisibility'."
}
$governanceSecurity = @(Initialize-CoEGovernanceSecurity -TeamId $coeGroup.GroupId -Channels $finalChannels `
    -SiteUrl $coeUrl -OwnerUPN $SharedChannelOwnerUPN -AdditionalAllowedMembers $GovernanceAdditionalAllowedMembers `
    -CoESiteSharingCapability $CoESiteSharingCapability `
    -OrganizationEmailDomains $OrganizationEmailDomains `
    -Connection $adminConnection)

$summaryChannels = @(
    Get-PnPTeamsChannel -Team $coeGroup.GroupId -Connection $adminConnection -ErrorAction Stop |
        Where-Object { $_.MembershipType -eq "standard" } |
        ForEach-Object { $_.DisplayName -replace '\s*📢$', '' }
)
$installSummary = [pscustomobject]@{
    TeamName         = $DisplayName
    TeamAlias        = $MailNickname
    TeamVisibility   = $finalTeam.Visibility
    SharePointSite   = $coeUrl
    StandardChannels = $summaryChannels -join "; "
    SharedChannels   = "Leadership Governance; Program Governance (allowlisted members verified)"
    ResourceTabs     = $resourceTabChoices
}
$installSummary
if ($SeedDemoContent) {
    & (Join-Path $PSScriptRoot "Internal\Complete-CopilotCoE.ps1") `
        -AdminUrl $adminUrl -SiteUrl $coeUrl -ClientId $PnPClientID -Tenant $Tenant `
        -TeamAlias $MailNickname -Connection $adminConnection `
        -EnsureResourceTabs `
        -ReplaceManagedPages:(-not $ResumeExisting) -ReplaceManagedFiles:$ReplaceManagedFiles `
        -ReplaceOrgAssets:$ReplaceOrgAssets -SampleNotice $sampleNoticeArgument -ShortName $ShortName -SupportEmail $SupportEmail `
        -OrgName $OrgName -OrgNoun $OrgNoun -DisplayName $DisplayName `
        -RepairCapturedPages:(!$ResumeExisting) `
        -AllowMissingDataSafetyIncidentRoute:$AllowMissingDataSafetyIncidentRoute `
        -SettingsPath $SettingsPath -OrgPath $OrgPath -AcceptOrgAssets:$AcceptOrgAssets
} else {
    Write-CoESecurityPosture -SiteUrl $coeUrl -TeamId $coeGroup.GroupId -ExpectedVisibility $TeamVisibility `
        -CoESiteSharingCapability $CoESiteSharingCapability -SettingsPath $SettingsPath `
        -OrganizationEmailDomains $OrganizationEmailDomains -OwnerUPN $SharedChannelOwnerUPN `
        -AdditionalAllowedMembers $GovernanceAdditionalAllowedMembers -Connection $adminConnection
}
Write-Host "Next: verify the site with .\Test-CoEInstall.ps1 -OrgPath <your organization folder> -SiteUrl $coeUrl"
Stop-CoERunLog -Log $script:CoERunLog -Succeeded $true
