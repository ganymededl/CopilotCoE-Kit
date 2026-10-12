[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AdminUrl,
    [Parameter(Mandatory)][string]$SiteUrl,
    [Parameter(Mandatory)][guid]$ClientId,
    [Parameter(Mandatory)][string]$Tenant,
    [Parameter(Mandatory)][string]$TeamAlias,
    [switch]$ReplaceManagedPages,
    [switch]$ReplaceManagedFiles,
    [switch]$GovernanceOnly,
    [switch]$GuidesOnly,
    [string]$SampleNotice,
    [string]$ShortName,
    [string]$OrgName,
    [string]$OrgNoun,
    [string]$DisplayName,
    [string]$SupportEmail = "copilot-coe@example.edu",
    [string]$SettingsPath,
    [string]$OrgPath,
    [switch]$AcceptOrgAssets,
    [switch]$ReplaceOrgAssets,
    [switch]$EnsureResourceTabs,
    [switch]$RepairCapturedPages,
    [switch]$AllowMissingDataSafetyIncidentRoute,
    [object]$Connection
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$kitRoot = Split-Path -Parent $PSScriptRoot  # helper lives in Internal\; data files are one level up
if ($GovernanceOnly -and $GuidesOnly) { throw "Choose either -GovernanceOnly or -GuidesOnly, not both." }
if ($RepairCapturedPages -and $GovernanceOnly) { throw "-RepairCapturedPages cannot be used with -GovernanceOnly." }
Import-Module PnP.PowerShell -RequiredVersion 3.2.0
. (Join-Path $PSScriptRoot "SecurityPosture.ps1")
. (Join-Path $PSScriptRoot "ResourceTabs.ps1")
. (Join-Path $PSScriptRoot "AdoptionCatalogs.ps1")
. (Join-Path $PSScriptRoot "SuccessStoryCatalog.ps1")
. (Join-Path $PSScriptRoot "PromptCatalog.ps1")
. (Join-Path $PSScriptRoot "OrganizationProfile.ps1")
. (Join-Path $PSScriptRoot "HubExperience.ps1")
. (Join-Path $PSScriptRoot "GovernanceLinks.ps1")
$runId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N'))"

# Organization profile: names, links, and support address from the org's Deployment-Settings.json.
$orgSettings = $null
if ($SettingsPath -and (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
    $orgSettings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
}
function Get-OrgValue([string]$Name, $Default) {
    if ($orgSettings -and $orgSettings.PSObject.Properties[$Name] -and $null -ne $orgSettings.$Name -and
        -not ($orgSettings.$Name -is [string] -and [string]::IsNullOrWhiteSpace($orgSettings.$Name))) { return $orgSettings.$Name }
    return $Default
}
$profileOverrides = @{}
foreach ($name in @("OrgName", "OrgNoun", "ShortName", "DisplayName", "SampleNotice")) {
    if ($PSBoundParameters.ContainsKey($name)) { $profileOverrides[$name] = $PSBoundParameters[$name] }
}
$organizationProfile = Get-CoEOrganizationProfile -Settings $orgSettings -Overrides $profileOverrides
$orgName = $organizationProfile.OrgName
$orgNoun = $organizationProfile.OrgNoun
$ShortName = $organizationProfile.ShortName
$DisplayName = $organizationProfile.DisplayName
$SampleNotice = $organizationProfile.SampleNotice
if (-not $PSBoundParameters.ContainsKey("SupportEmail")) { $SupportEmail = [string](Get-OrgValue "SupportEmail" "") }
if ($SupportEmail -notmatch '^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$') { throw "Configure SupportEmail before publishing content." }
$teamVisibility = [string](Get-OrgValue "TeamVisibility" "Private")
$coeSiteSharingCapability = Get-CoEParentSharingCapability -Settings $orgSettings
if ($teamVisibility -ne "Private") {
    throw "TeamVisibility must be Private. Public Teams are not supported."
}
$organizationEmailDomains = @(Get-OrgValue "OrganizationEmailDomains" @())
$governanceAdditionalAllowedMembers = @(Get-OrgValue "GovernanceAdditionalAllowedMembers" @())
$orgLinks = Get-OrgValue "Links" ([pscustomobject]@{})
$supportRoutes = @(Get-CoESupportRoutes $orgLinks $SiteUrl)
$navOrder = [string](Get-OrgValue "NavigationOrder" "TaskFirst")
if ($navOrder -notin @("TaskFirst", "AToZ", "AsBuilt")) { throw "NavigationOrder must be TaskFirst, AToZ or AsBuilt." }
if (-not $AllowMissingDataSafetyIncidentRoute -and
    @($supportRoutes | Where-Object { $_.Key -eq "DataSafetyIncident" -and -not $_.Configured }).Count) {
    throw "Links.DataSafetyIncident must be configured before publishing reader-facing content. For validation-only builds, rerun with -AllowMissingDataSafetyIncidentRoute."
}
foreach ($route in $supportRoutes | Where-Object { -not $_.Configured }) {
    Write-Warning "Links.$($route.Key) is not configured. Pages will show a setup warning, not a working organizational endpoint."
}
# TimeZone: a Windows time zone ID (Get-TimeZone -ListAvailable), applied to the site's regional settings.
$timeZoneId = [string](Get-OrgValue "TimeZone" "Eastern Standard Time")
try { $siteTimeZone = [TimeZoneInfo]::FindSystemTimeZoneById($timeZoneId) }
catch { throw "TimeZone '$timeZoneId' is not a Windows time zone ID. Use a value from Get-TimeZone -ListAvailable, for example 'Eastern Standard Time'." }
function Set-SiteTimeZone([object]$SiteConnection) {
    $normalize = { param($text) ($text -replace '&', 'and' -replace '[^A-Za-z0-9]', '').ToLowerInvariant() }
    $regional = (Get-PnPWeb -Connection $SiteConnection).RegionalSettings
    Get-PnPProperty -ClientObject $regional -Property TimeZones, TimeZone -Connection $SiteConnection | Out-Null
    $wanted = & $normalize $siteTimeZone.DisplayName
    $match = @($regional.TimeZones | Where-Object { (& $normalize $_.Description) -eq $wanted }) | Select-Object -First 1
    if (-not $match) { throw "No SharePoint time zone matches '$($siteTimeZone.DisplayName)'. Set the site time zone in Site settings > Regional settings." }
    if ($regional.TimeZone.Id -ne $match.Id) {
        $regional.TimeZone = $match
        $regional.Update()
        # Execute on the object's own CSOM context; Invoke-PnPQuery can run a different context and silently send nothing.
        $regional.Context.ExecuteQuery()
        $check = (Get-PnPWeb -Connection $SiteConnection).RegionalSettings
        Get-PnPProperty -ClientObject $check -Property TimeZone -Connection $SiteConnection | Out-Null
        if ($check.TimeZone.Id -ne $match.Id) {
            Write-Warning "The site time zone is still '$($check.TimeZone.Description)'. Set it to '$($match.Description)' in Site settings > Regional settings."
        }
        else { Write-Host "Set the site time zone to $($match.Description) (verified)." }
    }
}
if ($OrgPath) {
    if (-not (Test-Path -LiteralPath $OrgPath -PathType Container)) { throw "Organization folder not found: $OrgPath" }
    $OrgPath = (Resolve-Path -LiteralPath $OrgPath).Path
}

# Stage the kit content, overlay <OrgPath>\Content, and fill in organization tokens.
$stageRoot = Join-Path ([IO.Path]::GetTempPath()) "CopilotCoE-Stage-$runId"
[void][IO.Directory]::CreateDirectory($stageRoot)
Copy-Item -LiteralPath (Join-Path $kitRoot "SeedContent") -Destination $stageRoot -Recurse
foreach ($name in @("CoE-Revision-Content.json", "ResourceLinks.json")) {
    Copy-Item -LiteralPath (Join-Path $kitRoot $name) -Destination $stageRoot
}
$orgOverrides = @()
if ($OrgPath -and (Test-Path -LiteralPath (Join-Path $OrgPath "Content") -PathType Container)) {
    $contentRoot = Join-Path $OrgPath "Content"
    # README* files are notes for the CoE team and are skipped, unless they replace a kit file at the same path
    # (for example Sections\Files\Success Stories\Videos\README-Video-Submission-Checklist.txt).
    $kitSeedRoot = Join-Path $kitRoot "SeedContent"
    foreach ($file in @(Get-ChildItem -LiteralPath $contentRoot -File -Recurse | Where-Object {
            $_.Name -notlike "README*" -or
            (Test-Path -LiteralPath (Join-Path $kitSeedRoot $_.FullName.Substring($contentRoot.Length).TrimStart("\")) -PathType Leaf) })) {
        $relative = $file.FullName.Substring($contentRoot.Length).TrimStart("\")
        $target = if ($relative -in @("CoE-Revision-Content.json", "ResourceLinks.json")) {
            Join-Path $stageRoot ($relative -replace "^ResourceLinks\.json$", "ResourceLinks.json")
        } else { Join-Path (Join-Path $stageRoot "SeedContent") $relative }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        $orgOverrides += $relative
    }
    if ($orgOverrides.Count -gt 0) { Write-Host "Using $($orgOverrides.Count) organization content override(s): $($orgOverrides -join ', ')" }
}
function Resolve-OrgTokens([string]$Text, [switch]$Json, [switch]$Markdown) {
    $values = [ordered]@{ OrgNameUpper = $orgName.ToUpperInvariant(); OrgNounUpper = $orgNoun.ToUpperInvariant()
        OrgName = $orgName; OrgNoun = $orgNoun; OrgShort = $ShortName; SupportEmail = $SupportEmail }
    foreach ($key in $values.Keys) {
        $value = [string]$values[$key]
        if ($Json) {
            $encoded = ConvertTo-Json $value -Compress
            $value = $encoded.Substring(1, $encoded.Length - 2)
        }
        $Text = $Text.Replace("{{$key}}", $value)
    }
    if (-not $Markdown) { return $Text }
    $Text = [regex]::Replace($Text, '\{\{MailTo:([^}]+)\}\}', {
        param($m) "mailto:$($SupportEmail)?subject=$([uri]::EscapeDataString($m.Groups[1].Value))"
    })
    # Fallback guidance that only applies when a support route has not been supplied.
    $Text = [regex]::Replace($Text, '\{\{IfRouteMissing:([A-Za-z0-9]+)\|([^}]*)\}\}', {
        param($m)
        $route = @($supportRoutes | Where-Object Key -eq $m.Groups[1].Value) | Select-Object -First 1
        if ($route -and $route.Configured) { return "" }
        return $m.Groups[2].Value
    })
    $Text = [regex]::Replace($Text, '\{\{Link:([A-Za-z0-9]+)\|([^}]+)\}\}', {
        param($m)
        $key = $m.Groups[1].Value
        $route = @($supportRoutes | Where-Object Key -eq $key) | Select-Object -First 1
        if ($route) {
            $label = $m.Groups[2].Value + $(if ($route.Configured) { "" } else { " - route not configured" })
            return "[$label]($($route.Url))"
        }
        $value = [string](Get-CoECatalogValue $orgLinks $key)
        $url = Resolve-CoECatalogUrl $value "Links.$key" -AllowEmpty
        if ($url) { "[$($m.Groups[2].Value)]($url)" } else { "$($m.Groups[2].Value) (not configured)" }
    })
    $Text = [regex]::Replace($Text, '\{\{AgentList\}\}', {
        param($m)
        ""
    })
    return [regex]::Replace($Text, '\{\{LinkList:([A-Za-z0-9]+)\}\}', {
        param($m)
        $items = @(@(Get-OrgValue $m.Groups[1].Value @()) | Where-Object { $_ -and $_.PSObject.Properties["url"] -and $_.url -match '^https?://' })
        if ($items.Count -eq 0) { return "" }
        ($items | ForEach-Object { "- [$($_.label)]($($_.url))" }) -join "`n"
    })
}
# Org prompt CSVs are copied as they are: their {{placeholders}} belong to the person using the prompt.
foreach ($file in @(Get-ChildItem -LiteralPath $stageRoot -File -Recurse | Where-Object {
        $_.Extension -in @(".md", ".txt", ".csv", ".json") -and $_.FullName -notmatch '[\\/]OrgPrompts[\\/]' })) {
    $raw = [IO.File]::ReadAllText($file.FullName)
    $resolved = Resolve-OrgTokens $raw -Json:($file.Extension -eq ".json") -Markdown:($file.Extension -eq ".md")
    if ($resolved -ne $raw) { [IO.File]::WriteAllText($file.FullName, $resolved, [Text.UTF8Encoding]::new($false)) }
}

# Organization assets: list what is in <OrgPath>\Assets\<category> and ask before hosting it.
$orgAssetDecisions = @{}
function Confirm-OrgAssets([string]$Category, [string]$Question) {
    if ($orgAssetDecisions.ContainsKey($Category)) { return $orgAssetDecisions[$Category] }
    $accepted = @()
    $folder = if ($OrgPath) { Join-Path $OrgPath "Assets\$Category" } else { $null }
    if ($folder -and (Test-Path -LiteralPath $folder -PathType Container)) {
        $files = @(Get-ChildItem -LiteralPath $folder -File -Recurse |
            Where-Object { $_.Name -notlike "README*" -and $_.Name -notlike "~$*" -and $_.Name -notin @("desktop.ini", "Thumbs.db") })
        if ($files.Count -gt 0) {
            Write-Host ""
            Write-Host "Organization files found in Assets\$Category :" -ForegroundColor Cyan
            foreach ($f in $files) { Write-Host ("  - {0} ({1:N0} KB)" -f $f.FullName.Substring($folder.Length + 1), [math]::Ceiling($f.Length / 1KB)) }
            if ($AcceptOrgAssets) {
                Write-Host "  $Question Yes (-AcceptOrgAssets)."
                $accepted = $files
            } else {
                $answer = Read-Host "  $Question [Y]es / [N]o"
                if ($answer -match '^\s*(y|yes)\s*$') { $accepted = $files } else { Write-Host "  Skipped. Nothing from Assets\$Category was uploaded." }
            }
        }
    }
    $orgAssetDecisions[$Category] = $accepted
    return $accepted
}

$copy = Get-Content (Join-Path $stageRoot "CoE-Revision-Content.json") -Raw | ConvertFrom-Json
# The deployment report belongs to the organization folder, so several CoEs can be built from one kit.
# Without -OrgPath, or for a report written by an older kit, the kit folder copy is used.
$legacyReportPath = Join-Path $kitRoot "CoE-Revision-Report.json"
$reportPath = if ($OrgPath) { Join-Path $OrgPath "CoE-Revision-Report.json" } else { $legacyReportPath }
$previousTopTen = $null
$previousReportPath = if (Test-Path -LiteralPath $reportPath -PathType Leaf) { $reportPath } else { $legacyReportPath }
if (-not $GovernanceOnly -and -not $GuidesOnly -and (Test-Path -LiteralPath $previousReportPath -PathType Leaf)) {
    $previousReport = Get-Content -LiteralPath $previousReportPath -Raw | ConvertFrom-Json -AsHashtable
    if ($previousReport.ContainsKey("Site") -and $previousReport.Site.TrimEnd("/") -eq $SiteUrl.TrimEnd("/") -and
        $previousReport.ContainsKey("TopTen")) { $previousTopTen = $previousReport.TopTen }
}
if ($GovernanceOnly -or $GuidesOnly) {
    $readPath = $reportPath
    if (-not (Test-Path -LiteralPath $readPath -PathType Leaf) -and (Test-Path -LiteralPath $legacyReportPath -PathType Leaf)) {
        $readPath = $legacyReportPath
    }
    if (-not (Test-Path -LiteralPath $readPath -PathType Leaf)) {
        throw "A partial (-GovernanceOnly or -GuidesOnly) run requires the existing deployment report."
    }
    $report = Get-Content $readPath -Raw | ConvertFrom-Json -AsHashtable
    if ($report.Site.TrimEnd("/") -ne $SiteUrl.TrimEnd("/")) {
        throw "The existing deployment report does not match the supplied site."
    }
    $report.Version = $copy.version
    if ($GovernanceOnly) { $report.Governance = @() }
} else {
    $report = [ordered]@{ Site = $SiteUrl; Version = $copy.version; Governance = @() }
}
$report.Organization = @{ Name = $orgName; DisplayName = $DisplayName; Noun = $orgNoun; Short = $ShortName
    OrgPath = $OrgPath; ContentOverrides = $orgOverrides }
$report.SupportRoutes = @($supportRoutes | Select-Object Key,Configured,Url)
$auditFolder = Join-Path $kitRoot "RevisionAudit"
[void][System.IO.Directory]::CreateDirectory($auditFolder)
$seedRoot = Join-Path $stageRoot "SeedContent"
$sectionConfig = Get-Content -LiteralPath (Join-Path $seedRoot "Sections\Sections.json") -Raw | ConvertFrom-Json
$catalogReviewers = @(Get-OrgValue "CatalogReviewerUPNs" @())
$learningSeeds = @()
$agentSeeds = @()
# PromptLibrary: "On" (default) builds the Copilot Prompt Library list from SeedContent\OrgPrompts\*.csv
# (the environment's base prompts plus <OrgPath>\Content\OrgPrompts); "Off" leaves the list out.
$promptLibraryMode = [string](Get-OrgValue "PromptLibrary" "On")
if ($promptLibraryMode -notin @("On", "Off")) { throw "PromptLibrary must be On or Off." }
$promptSeeds = @()
if (-not $GovernanceOnly) {
    $null = Assert-CoECatalogReviewerUPNs $catalogReviewers
    if ($promptLibraryMode -eq "On") {
        $promptSeeds = @(Read-CoEOrgPromptFiles -Folder (Join-Path $seedRoot "OrgPrompts"))
        $promptFiles = @($promptSeeds | ForEach-Object Source | Select-Object -Unique)
        Write-Host "Prompt library: $($promptSeeds.Count) prompt(s) from $($promptFiles.Count) file(s): $($promptFiles -join ', ')"
    }
    if (@($sectionConfig.sections | Where-Object page -eq "CoE-Training-and-Enablement").Count -eq 1) {
        $promptLibraryUrl = if ($orgLinks.PSObject.Properties["PromptLibrary"]) { [string]$orgLinks.PromptLibrary } else { "" }
        $learningSeeds = @(Read-CoELearningSeeds -Path (Join-Path $seedRoot "Learning-Paths.json") `
            -SiteUrl $SiteUrl -PromptLibraryUrl $promptLibraryUrl)
        $lmsUrl = if ($orgLinks.PSObject.Properties["LearningSystem"]) { [string]$orgLinks.LearningSystem } else { "" }
        if ($lmsUrl) {
            $lmsUrl = Resolve-CoECatalogUrl $lmsUrl "Links.LearningSystem"
            foreach ($seed in $learningSeeds) { if (-not $seed.lmsUrl) { $seed.lmsUrl = $lmsUrl } }
        }
        $availableGuidePages = @(Get-ChildItem -LiteralPath (Join-Path $seedRoot "Guides") -Filter "*.md" -File |
            Where-Object { -not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($_.FullName)) } |
            ForEach-Object { "Guide-" + ($_.BaseName -replace '^\d+[a-z]?-', '') + ".aspx" })
        $promptGuide = Get-Content -LiteralPath (Join-Path $seedRoot "Guides\07-Prompt-Library.md") -Raw -ErrorAction Stop
        $promptAnchors = @([regex]::Matches($promptGuide, '(?m)^#{2,3} (.+)$') | ForEach-Object {
            Get-CoEHeadingAnchor $_.Groups[1].Value.Trim()
        })
        foreach ($seed in $learningSeeds) {
            foreach ($url in @($seed.resourceUrl, $seed.practiceUrl)) {
                if (-not $url) { continue }
                $relative = ([uri]$url).AbsolutePath
                $prefix = ([uri]$SiteUrl).AbsolutePath.TrimEnd("/") + "/SitePages/"
                if (([uri]$url).Host -eq ([uri]$SiteUrl).Host -and $relative.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $pageName = [uri]::UnescapeDataString($relative.Substring($prefix.Length))
                    if ($pageName -like "Guide-*" -and $pageName -notin $availableGuidePages) {
                        throw "Learning step '$($seed.id)' links to omitted guide '$pageName'. Update Content\Learning-Paths.json before publishing."
                    }
                    $fragment = [uri]::UnescapeDataString(([uri]$url).Fragment.TrimStart('#'))
                    if ($pageName -eq "Guide-Prompt-Library.aspx" -and $fragment -and $fragment -notin $promptAnchors) {
                        throw "Learning step '$($seed.id)' links to missing prompt '$fragment'. Update the learning seed or prompt-guide override before publishing."
                    }
                }
            }
        }
    }
    if (@($sectionConfig.sections | Where-Object page -eq "CoE-Agent-Showcase").Count -eq 1) {
        $agentSeeds = @(ConvertTo-CoEAgentSeeds -Items @(Get-OrgValue "Agents" @()))
    }
}
foreach ($kind in @("program", "leadership")) {
    foreach ($relativePath in @("Governance\$kind\START-HERE.txt") + @($copy.$kind.sections | ForEach-Object file)) {
        $seedFile = Join-Path $seedRoot $relativePath
        if (-not (Test-Path -LiteralPath $seedFile -PathType Leaf)) {
            throw "Required governance draft is missing: $seedFile"
        }
    }
}

if (-not $Connection) {
    Write-Host "Reuse cached PnP sign-in if available. If prompted, complete one device sign-in for the target tenant."
    $Connection = Connect-PnPOnline -Url $AdminUrl -DeviceLogin -ClientId $ClientId `
        -Tenant $Tenant -PersistLogin -ReturnConnection
}
$site = Connect-PnPOnline -Url $SiteUrl -Connection $Connection -ReturnConnection
if (-not $GovernanceOnly) {
    # Resolve the entire reviewer roster before regional settings, pages or catalog permissions change.
    Assert-CoECatalogPreflight -SiteUrl $SiteUrl -Connection $site
    $resolvedCatalogReviewers = @(Resolve-CoECatalogReviewers -ReviewerUPNs $catalogReviewers -Connection $site)
}
# Set the time zone before loading any site objects: the regional-settings update can leave
# previously loaded SharePoint objects bound to a stale context ("used in a different context").
Set-SiteTimeZone -SiteConnection $site
$group = Get-PnPMicrosoft365Group -Identity $TeamAlias -IncludeSiteUrl -Connection $Connection
if (-not $group -or $group.SiteUrl.TrimEnd("/") -ne $SiteUrl.TrimEnd("/")) {
    throw "The Team alias does not match the supplied SharePoint site. No repair has been applied."
}
$team = Get-PnPTeamsTeam -Identity $group.GroupId -Connection $Connection
if ($team.Visibility -ne "Private") { throw "Team visibility is '$($team.Visibility)', not the required Private setting." }
$channels = @(Get-PnPTeamsChannel -Team $group.GroupId -Connection $Connection)
$governanceSecurity = @(Initialize-CoEGovernanceSecurity -TeamId $group.GroupId -Channels $channels `
    -CoESiteSharingCapability $coeSiteSharingCapability `
    -SiteUrl $SiteUrl -OwnerUPN ([string](Get-OrgValue "SharedChannelOwnerUPN" "")) `
    -AdditionalAllowedMembers $governanceAdditionalAllowedMembers `
    -OrganizationEmailDomains $organizationEmailDomains -Connection $Connection)
$ask = @($channels | Where-Object DisplayName -like "Ask Us Anything*")
if ($ask.Count -ne 1) { throw "Expected one Ask Us Anything channel." }
$askChannelUrl = "https://teams.microsoft.com/l/channel/$([uri]::EscapeDataString($ask[0].Id))/Ask%20Us%20Anything?groupId=$($group.GroupId)"
$resourceLinks = Get-Content (Join-Path $stageRoot "ResourceLinks.json") -Raw | ConvertFrom-Json

function Escape-Html([string]$Text) { [System.Net.WebUtility]::HtmlEncode($Text) }

function Add-CoECatalogPageView {
    param([object]$SiteConnection, [string]$PageName, [object]$Catalog, [object]$View, [string]$Heading,
        [int]$Order = 2, [string]$IntroText = "")
    $page = $null
    if (-not (Test-ManagedPageWritten $SiteConnection $PageName)) {
        # The page's own prose was preserved (not rewritten) this run, which normally means its catalog link
        # was already added in an earlier, fully-completed run. But a run that stopped before reaching this
        # step can leave a preserved page with no catalog link at all. Check the live page instead of
        # assuming: repair the link only if it is verifiably missing, so a normal resume never re-adds a link
        # that is already there (same PropertiesJson/selectedListId/selectedViewId check Test-CoEInstall uses).
        $page = Get-PnPPage -Identity $PageName -Connection $SiteConnection -ErrorAction SilentlyContinue
        if (-not $page) { return }
        $alreadyBound = @($page.Controls | Where-Object {
            if (-not $_.PSObject.Properties["PropertiesJson"]) { return $false }
            try { $props = [string]$_.PropertiesJson | ConvertFrom-Json } catch { return $false }
            [string]$props.selectedListId -eq $Catalog.List.Id.ToString() -and [string]$props.selectedViewId -eq $View.Id.ToString()
        })
        if ($alreadyBound.Count -ge 1) { return }
    }
    # Re-fetch the view right before use instead of trusting $View.ServerRelativeUrl: by this point other
    # views on the same list have been created/updated (each Sync-CoECatalogView call re-lists every view on
    # the list), and that earlier property load is not reliably still present on this object.
    $freshView = Get-PnPView -List $Catalog.List.Id -Identity $View.Id -Includes ServerRelativeUrl `
        -Connection $SiteConnection -ErrorAction Stop
    $viewUrl = Resolve-CoESharePointReturnedUrl ([string](Get-CoECatalogValue $freshView "ServerRelativeUrl")) "$Heading view" $SiteUrl
    if (-not $page) { $page = Get-PnPPage -Identity $PageName -Connection $SiteConnection -ErrorAction Stop }
    # PnP keeps duplicate Order values; make room before the cmdlets reload and save the page.
    foreach ($control in $page.Controls) {
        if ($control.Order -ge $Order) { $control.Order += 2 }
    }
    $page.Save() | Out-Null
    $text = "<h2>$(Escape-Html $Heading)</h2>"
    if ($IntroText) { $text += "<p>$(Escape-Html $IntroText)</p>" }
    $text += "<p>Select a name for full details. <a href=`"$(Escape-Html $viewUrl)`">Open the list</a>.</p>"
    Add-PnPPageTextPart -Page $page -Text $text -Order $Order -Connection $SiteConnection -ErrorAction Stop | Out-Null
    Add-PnPPageWebPart -Page $page -DefaultWebPartType List -WebPartProperties @{
        selectedListId = $Catalog.List.Id.ToString(); selectedListUrl = ([uri]$Catalog.ListUrl).AbsolutePath
        selectedViewId = $View.Id.ToString(); hideCommandBar = $true; isDocumentLibrary = $false
        hideTitle = $true; showTitle = $false
    } -Order ($Order + 1) -Connection $SiteConnection -ErrorAction Stop | Out-Null
    Set-PnPPage -Identity $PageName -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
}

# Drops the {{HostedFiles}} line, an introducing "...:" line just above it, and a "## heading" left with no content.
function Remove-EmptyHostedFiles([string]$Markdown) {
    $lines = [System.Collections.Generic.List[string]]::new([string[]]($Markdown -split "\r?\n"))
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i].Trim() -ne "{{HostedFiles}}") { continue }
        $lines.RemoveAt($i)
        $j = $i - 1
        while ($j -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$j])) { $j-- }
        if ($j -ge 0 -and $lines[$j].TrimEnd().EndsWith(":") -and $lines[$j] -notmatch '^#') { $lines.RemoveAt($j) }
    }
    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^## ') {
            $k = $i + 1
            while ($k -lt $lines.Count -and [string]::IsNullOrWhiteSpace($lines[$k])) { $k++ }
            if ($k -ge $lines.Count -or $lines[$k] -match '^## ') { $i = $k - 1; continue }
        }
        $out.Add($lines[$i])
    }
    return ($out -join "`n")
}

function Convert-MarkdownInline([string]$Text) {
    $encoded = Escape-Html $Text
    $encoded = [regex]::Replace($encoded, '\[([^\]]+)\]\(((?:https?://|mailto:)[^)]+)\)', '<a href="$2">$1</a>')
    # [label](Page-Name.aspx) links to a page in this site's SitePages library.
    $encoded = [regex]::Replace($encoded, '\[([^\]]+)\]\(([A-Za-z0-9][A-Za-z0-9-]*\.aspx)\)', {
        param($m) "<a href=`"$($SiteUrl.TrimEnd('/'))/SitePages/$($m.Groups[2].Value)`">$($m.Groups[1].Value)</a>"
    })
    return [regex]::Replace($encoded, '\*\*(.+?)\*\*', '<strong>$1</strong>')
}

# Small Markdown subset used by SeedContent pages: # title, > summary, ##/### headings,
# - bullets, 1. numbered items, | tables |, links, bold, and paragraphs.
function Convert-GuideMarkdown([string]$Text) {
    $title = $null; $summary = $null; $html = [System.Text.StringBuilder]::new()
    $list = $null; $tableRows = [System.Collections.Generic.List[string[]]]::new()
    $flushList = { if ($list) { [void]$html.Append("</$list>"); $list = $null } }
    $flushTable = {
        if ($tableRows.Count -gt 0) {
            [void]$html.Append("<table><thead><tr>")
            foreach ($cell in $tableRows[0]) { [void]$html.Append("<th>$(Convert-MarkdownInline $cell)</th>") }
            [void]$html.Append("</tr></thead><tbody>")
            for ($r = 1; $r -lt $tableRows.Count; $r++) {
                [void]$html.Append("<tr>")
                foreach ($cell in $tableRows[$r]) { [void]$html.Append("<td>$(Convert-MarkdownInline $cell)</td>") }
                [void]$html.Append("</tr>")
            }
            [void]$html.Append("</tbody></table>")
            $tableRows.Clear()
        }
    }
    foreach ($raw in ($Text -split "\r?\n")) {
        $line = $raw.TrimEnd()
        if ($line.StartsWith("|")) {
            . $flushList
            $cells = @($line.Trim("|").Split("|") | ForEach-Object { $_.Trim() })
            if (-not ($cells -join "" -match '^[-:\s]+$')) { $tableRows.Add([string[]]$cells) }
            continue
        }
        . $flushTable
        if ([string]::IsNullOrWhiteSpace($line)) { . $flushList; continue }
        if ($line -match '^# (.+)$' -and -not $title) { $title = $Matches[1].Trim(); continue }
        if ($line -match '^> (.+)$' -and -not $summary) { $summary = $Matches[1].Trim(); continue }
        if ($line -match '^(#{2,3}) (.+)$') {
            . $flushList
            $level = if ($Matches[1] -eq "###") { 4 } else { 3 }
            $heading = $Matches[2]
            $anchor = Get-CoEHeadingAnchor $heading
            [void]$html.Append("<h$level id=`"$anchor`">$(Convert-MarkdownInline $heading)</h$level>")
            continue
        }
        if ($line -match '^\s*[-*] (.+)$') {
            if ($list -ne "ul") { . $flushList; [void]$html.Append("<ul>"); $list = "ul" }
            [void]$html.Append("<li>$(Convert-MarkdownInline $Matches[1])</li>"); continue
        }
        if ($line -match '^\s*\d+\. (.+)$') {
            if ($list -ne "ol") { . $flushList; [void]$html.Append("<ol>"); $list = "ol" }
            [void]$html.Append("<li>$(Convert-MarkdownInline $Matches[1])</li>"); continue
        }
        . $flushList
        [void]$html.Append("<p>$(Convert-MarkdownInline $line)</p>")
    }
    . $flushTable
    if ($list) { [void]$html.Append("</$list>") }
    return [pscustomobject]@{ Title = $title; Summary = $summary; Html = $html.ToString() }
}

$writtenManagedPages = @()
function Write-ManagedPage {
    param([object]$SiteConnection, [string]$Name, [string]$Title, [string]$Html, [string]$IntroHtml = "")
    $existing = @(Get-PnPPage -Connection $SiteConnection | Where-Object Name -eq "$Name.aspx")
    if ($existing.Count -gt 1) { throw "Duplicate page identity: $Name" }
    if ($existing.Count -eq 1) {
        if (-not $ReplaceManagedPages) {
            Write-Host "Preserved existing page $Name. Use -ReplaceManagedPages only after reviewing it."
            return $existing[0]
        }
        $page = Get-PnPPage -Identity "$Name.aspx" -Connection $SiteConnection
        $item = Get-PnPFile -Url "SitePages/$Name.aspx" -AsListItem -Connection $SiteConnection
        $siteKey = ([uri]$SiteUrl).AbsolutePath.Trim("/").Replace("/", "-")
        $item.FieldValues | ConvertTo-Json -Depth 20 |
            Set-Content (Join-Path $auditFolder "$runId-$siteKey-$Name-before.json") -Encoding utf8
        foreach ($control in @($page.Controls)) {
            Remove-PnPPageComponent -Page $page -InstanceId $control.InstanceId -Force -Connection $SiteConnection
        }
        Set-PnPPage -Identity $Name -Title $Title -Connection $SiteConnection | Out-Null
    } else {
        $page = Add-PnPPage -Name $Name -Title $Title -LayoutType Article -Connection $SiteConnection
    }
    $Html = $Html.Replace("<p><em></em></p>", "")  # SampleNotice "none"
    # SharePoint already shows the page title above the content, so drop a leading duplicate heading.
    $Html = [regex]::Replace($Html, '^\s*<h2>.*?</h2>', '')
    if ($IntroHtml) {
        Add-PnPPageTextPart -Page $Name -Text ($IntroHtml.Replace("<p><em></em></p>", "")) -Order 1 -Connection $SiteConnection | Out-Null
    }
    Add-PnPPageTextPart -Page $Name -Text $Html -Order $(if ($IntroHtml) { 2 } else { 1 }) -Connection $SiteConnection | Out-Null
    Set-PnPPage -Identity $Name -HeaderType Default -HeaderLayoutType NoImage -Publish -Connection $SiteConnection | Out-Null
    $script:writtenManagedPages += "$($SiteUrl.TrimEnd('/'))|$Name"
    return Get-PnPPage -Identity $Name -Connection $SiteConnection
}

function Repair-CoEHubPages($SiteConnection, [object[]]$Links) {
    $tilesJson = ""
    $configuredTiles = Get-OrgValue "HomeTiles" @()
    if (@($configuredTiles).Count) { $tilesJson = ConvertTo-Json @($configuredTiles) -Depth 8 -Compress }
    $tiles = @(Get-CoEHomeTiles $tilesJson)
    $pages = @(Get-PnPPage -Connection $SiteConnection -ErrorAction Stop)
    foreach ($tile in $tiles) {
        if ($tile.Page -notin @($pages | ForEach-Object Name)) {
            throw "Home tile '$($tile.Title)' targets an omitted or missing page '$($tile.Page)'. Configure HomeTiles before repairing Home."
        }
    }
    $imageIds = @{}
    foreach ($image in @($tiles | ForEach-Object Image | Select-Object -Unique)) {
        $file = Get-PnPFile -Url $image -AsFileObject -Connection $SiteConnection -ErrorAction Stop
        Get-PnPProperty -ClientObject $file -Property UniqueId -Connection $SiteConnection -ErrorAction Stop | Out-Null
        if (-not $file.UniqueId -or $file.UniqueId -eq [guid]::Empty) { throw "Home image '$image' has no real file identity." }
        $imageIds[$image] = $file.UniqueId.ToString()
    }
    $homePage = Get-PnPPage -Identity "TrainingHome.aspx" -Connection $SiteConnection -ErrorAction Stop
    $before = Get-PnPFile -Url "SitePages/TrainingHome.aspx" -AsListItem -Connection $SiteConnection -ErrorAction Stop
    $before.FieldValues | ConvertTo-Json -Depth 100 |
        Set-Content (Join-Path $auditFolder "$runId-Home-hub-before.json") -Encoding utf8
    $taskHtml = '<h2 id="coe-home-tasks">Explore Copilot</h2><p>Choose a next step, or see examples from your community.</p>'
    # Home is the landing page, so it carries the same sample/demo notice as every other CoE page.
    if ($SampleNotice) { $taskHtml += "<p><em>$(Escape-Html $SampleNotice)</em></p>" }
    $taskHtml += '<ul>'
    foreach ($link in $Links | Where-Object Key -in @("Start", "Learn", "Prompts", "Agents", "Stories", "Guides", "Governance", "Help", "Champions")) {
        $taskHtml += "<li><a href=`"$(Escape-Html $link.Url)`">$(Escape-Html $link.Title)</a></li>"
    }
    $taskHtml += '</ul>'
    $taskControls = @($homePage.Controls | Where-Object { $_.PSObject.Properties["Text"] -and $_.Text -match 'id="coe-home-tasks"' })
    if ($taskControls.Count -gt 1) { throw "Home contains duplicate managed Explore Copilot blocks." }
    foreach ($control in $homePage.Controls) {
        if (-not $control.PSObject.Properties["Text"]) { continue }
        $control.Text = [regex]::Replace($control.Text, '<a\b[^>]*>\s*Find your department champion\s*</a>', (
            '<a href="' + (Escape-Html "$($SiteUrl.TrimEnd('/'))/SitePages/Meet-your-Champions.aspx") + '">Find your department champion</a>'))
    }
    if ($taskControls.Count) { $taskControls[0].Text = $taskHtml }
    $homePage.Save() | Out-Null
    if (-not $taskControls.Count) {
        Add-PnPPageTextPart -Page "TrainingHome.aspx" -Text $taskHtml -Order 2 -Connection $SiteConnection -ErrorAction Stop | Out-Null
    }
    $item = Get-PnPFile -Url "SitePages/TrainingHome.aspx" -AsListItem -Connection $SiteConnection -ErrorAction Stop
    $canvas = Convert-CoEHomeHeroCanvas -Canvas ([string]$item["CanvasContent1"]) -SiteUrl $SiteUrl `
        -Tiles $tiles -ImageIds $imageIds -FeatureText $DisplayName
    Set-PnPListItem -List "Site Pages" -Identity $item.Id -Values @{ CanvasContent1 = $canvas } `
        -Connection $SiteConnection -ErrorAction Stop | Out-Null
    Set-PnPPage -Identity "TrainingHome.aspx" -HeaderType Default -HeaderLayoutType NoImage -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
    $saved = Get-PnPFile -Url "SitePages/TrainingHome.aspx" -AsListItem -Connection $SiteConnection -ErrorAction Stop
    $savedCanvas = [string]$saved["CanvasContent1"]
    if ($savedCanvas -notmatch 'coe-home-tasks' -or $savedCanvas -notmatch 'href="[^"]*/SitePages/Meet-your-Champions\.aspx"[^>]*>Find your department champion') {
        throw "Home's task links or champion link did not persist."
    }
    $heroes = @([regex]::Matches($savedCanvas, 'data-sp-webpartdata="([^"]*)"') | ForEach-Object {
        $data = [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) | ConvertFrom-Json -AsHashtable
        if ($data["id"] -eq "c4bd7b2f-7b6e-4599-8485-16504575f590") { $data }
    })
    if ($heroes.Count -ne 1) { throw "Home Hero could not be read back." }
    for ($i = 0; $i -lt $tiles.Count; $i++) {
        $expectedUrl = "$($SiteUrl.TrimEnd('/'))/SitePages/$($tiles[$i].Page)"
        $dataUrl = $heroes[0]["serverProcessedContent"]["links"]["content[$i].link"]
        if (-not (Test-CoESameSitePageUrl $dataUrl $expectedUrl $SiteUrl)) { throw "Home Hero '$($tiles[$i].Title)' has the wrong saved destination." }
        $anchors = [regex]::Matches($savedCanvas, '<a\b[^>]*data-sp-prop-name="content\[' + $i + '\]\.link"[^>]*>')
        if ($anchors.Count -ne 1 -or $anchors[0].Value -notmatch '\bhref="([^"]*)"') {
            throw "Home Hero '$($tiles[$i].Title)' has no unique rendered link."
        }
        # SharePoint rewrites a saved absolute link to a server-relative href when it renders the page.
        if (-not (Test-CoESameSitePageUrl ([Net.WebUtility]::HtmlDecode($Matches[1])) $expectedUrl $SiteUrl)) {
            throw "Home Hero '$($tiles[$i].Title)' renders the wrong destination."
        }
    }

    foreach ($page in $pages | Where-Object Name -in @("Adoption-Best-Practices.aspx", "Meet-your-ProjectTeam.aspx",
        "Technical Readiness.aspx", "Copilot-on-Microsoft-Mechanics.aspx")) {
        $args = @{ Identity = $page.Name; HeaderType = "Default"; HeaderLayoutType = "NoImage"
            Publish = $true; Connection = $SiteConnection; ErrorAction = "Stop" }
        if ($page.Name -eq "Adoption-Best-Practices.aspx") { $args.Title = "Copilot CoE adoption guide" }
        if ($page.Name -eq "Meet-your-ProjectTeam.aspx") { $args.Title = "CoE roles and contacts" }
        Set-PnPPage @args | Out-Null
    }
    if ("Copilot-on-Microsoft-Mechanics.aspx" -in @($pages | ForEach-Object Name)) {
        $mechanics = '<p>Use Microsoft''s official hubs for current Copilot demonstrations and technical explanations. Video availability depends on your organization''s media policies and the publisher.</p><ul>' +
            '<li><a href="https://www.microsoft.com/mechanics">Microsoft Mechanics</a></li>' +
            '<li><a href="https://techcommunity.microsoft.com/category/microsoftmechanics">Microsoft Mechanics video hub</a></li></ul>'
        $null = Write-ManagedPage $SiteConnection "Copilot-on-Microsoft-Mechanics" "Microsoft Mechanics resources" $mechanics
    }
    return [pscustomobject]@{ HomeLinks = @($Links | Select-Object Title,Url); HeroTiles = $tiles
        LegacyPagesPreserved = @($pages | Where-Object Name -eq "News-and-Updates.aspx" | ForEach-Object Name) }
}

function Test-ManagedPageWritten([object]$SiteConnection, [string]$Name) {
    if ($ReplaceManagedPages) { return $true }
    return "$($SiteUrl.TrimEnd('/'))|$Name" -in $writtenManagedPages
}

# Governance drafts are kept as plain text in the kit (easy to edit and override) and published as Word
# documents with descriptive names. The builder needs no Word or Office installation.
function ConvertTo-DocxFileName([string]$Title) {
    $small = @("a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to", "with")
    $words = @(($Title -replace "[^A-Za-z0-9]+", " ").Trim() -split "\s+" | Where-Object { $_ })
    $out = for ($i = 0; $i -lt $words.Count; $i++) {
        $w = $words[$i]
        if ($w -cmatch "[A-Z]") { $w } elseif ($i -gt 0 -and $w -in $small) { $w } else { $w.Substring(0, 1).ToUpperInvariant() + $w.Substring(1) }
    }
    return (($out -join "-") + ".docx")
}
function Get-DocxParagraphs([string]$Text) {
    $paragraphs = @()
    foreach ($line in ($Text.TrimStart([char]0xFEFF) -split "\r?\n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        $style = "Normal"
        if ($t -match '^#\s+(.+)$') { $style = "Heading1"; $t = $Matches[1] }
        elseif ($t -match '^#{2,6}\s+(.+)$') { $style = "Heading2"; $t = $Matches[1] }
        elseif ($t -match '^[-*]\s+(.+)$') { $t = [string][char]0x2022 + " " + $Matches[1] }
        elseif ($t.Length -le 120 -and $t -cmatch '[A-Z]' -and $t -cnotmatch '[a-z]') { $style = "Heading1" }
        elseif ($t.Length -le 80 -and $t -cmatch '^[A-Z0-9]' -and $t -notmatch '[.:;,!?)"]$' -and @($t -split '\s+').Count -le 10) { $style = "Heading2" }
        $t = $t -replace '\*\*(.+?)\*\*', '$1' -replace '(?<![\w*])\*(?!\s)(.+?)\*(?!\w)', '$1' -replace '\[([^\]]+)\]\(([^)]+)\)', '$1 ($2)'
        $paragraphs += [pscustomobject]@{ Style = $style; Text = $t }
    }
    return $paragraphs
}
function New-SimpleDocx([string]$Text, [string]$Path, [string]$Title) {
    $esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
    $body = foreach ($p in (Get-DocxParagraphs $Text)) {
        $pPr = if ($p.Style -ne "Normal") { "<w:pPr><w:pStyle w:val=`"$($p.Style)`"/></w:pPr>" } else { "" }
        "<w:p>$pPr<w:r><w:t xml:space=`"preserve`">$(& $esc $p.Text)</w:t></w:r></w:p>"
    }
    $w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    $parts = [ordered]@{
        "[Content_Types].xml" = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Types xmlns=`"http://schemas.openxmlformats.org/package/2006/content-types`"><Default Extension=`"rels`" ContentType=`"application/vnd.openxmlformats-package.relationships+xml`"/><Default Extension=`"xml`" ContentType=`"application/xml`"/><Override PartName=`"/word/document.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml`"/><Override PartName=`"/word/styles.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml`"/><Override PartName=`"/docProps/core.xml`" ContentType=`"application/vnd.openxmlformats-package.core-properties+xml`"/></Types>"
        "_rels/.rels" = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Relationships xmlns=`"http://schemas.openxmlformats.org/package/2006/relationships`"><Relationship Id=`"rId1`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument`" Target=`"word/document.xml`"/><Relationship Id=`"rId2`" Type=`"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties`" Target=`"docProps/core.xml`"/></Relationships>"
        "word/_rels/document.xml.rels" = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Relationships xmlns=`"http://schemas.openxmlformats.org/package/2006/relationships`"><Relationship Id=`"rId1`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles`" Target=`"styles.xml`"/></Relationships>"
        "word/styles.xml" = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><w:styles xmlns:w=`"$w`"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=`"Calibri`" w:hAnsi=`"Calibri`" w:cs=`"Calibri`"/><w:sz w:val=`"22`"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=`"160`" w:line=`"276`" w:lineRule=`"auto`"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type=`"paragraph`" w:default=`"1`" w:styleId=`"Normal`"><w:name w:val=`"Normal`"/></w:style><w:style w:type=`"paragraph`" w:styleId=`"Heading1`"><w:name w:val=`"heading 1`"/><w:basedOn w:val=`"Normal`"/><w:next w:val=`"Normal`"/><w:pPr><w:keepNext/><w:spacing w:before=`"240`" w:after=`"120`"/><w:outlineLvl w:val=`"0`"/></w:pPr><w:rPr><w:b/><w:color w:val=`"1F3864`"/><w:sz w:val=`"28`"/></w:rPr></w:style><w:style w:type=`"paragraph`" w:styleId=`"Heading2`"><w:name w:val=`"heading 2`"/><w:basedOn w:val=`"Normal`"/><w:next w:val=`"Normal`"/><w:pPr><w:keepNext/><w:spacing w:before=`"200`" w:after=`"80`"/><w:outlineLvl w:val=`"1`"/></w:pPr><w:rPr><w:b/><w:color w:val=`"2F5496`"/><w:sz w:val=`"24`"/></w:rPr></w:style></w:styles>"
        "docProps/core.xml" = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><cp:coreProperties xmlns:cp=`"http://schemas.openxmlformats.org/package/2006/metadata/core-properties`" xmlns:dc=`"http://purl.org/dc/elements/1.1/`"><dc:title>$(& $esc $Title)</dc:title></cp:coreProperties>"
        "word/document.xml" = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><w:document xmlns:w=`"$w`"><w:body>$($body -join '')<w:sectPr><w:pgSz w:w=`"12240`" w:h=`"15840`"/><w:pgMar w:top=`"1440`" w:right=`"1440`" w:bottom=`"1440`" w:left=`"1440`" w:header=`"720`" w:footer=`"720`" w:gutter=`"0`"/></w:sectPr></w:body></w:document>"
    }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $parts.Keys) {
            $entry = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write($parts[$name]) } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
}
function Read-DocxText([byte[]]$Bytes) {
    Add-Type -AssemblyName System.IO.Compression
    $zip = [IO.Compression.ZipArchive]::new([IO.MemoryStream]::new($Bytes), [IO.Compression.ZipArchiveMode]::Read)
    try {
        $entry = $zip.GetEntry("word/document.xml")
        if (-not $entry) { return $null }
        $reader = [IO.StreamReader]::new($entry.Open()); try { $xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
    $lines = foreach ($p in [regex]::Matches($xml, '<w:p[ >].*?</w:p>', 'Singleline')) {
        $t = -join ([regex]::Matches($p.Value, '<w:t[^>]*>(.*?)</w:t>', 'Singleline') | ForEach-Object { $_.Groups[1].Value })
        if ($t) { [System.Net.WebUtility]::HtmlDecode($t) }
    }
    return ($lines -join "`n")
}
# Publishes a staged text draft as a Word document. Replaces a changed document only with -ReplaceManagedFiles,
# and removes the older plain-text copy of the same draft (for example Sample-guidance.txt) when it is replaced.
function Write-ManagedDocx {
    param([object]$SiteConnection, [string]$Folder, [string]$LocalPath, [string]$FileName, [string]$Title, [string]$AuditKey, [string[]]$LegacyNames, [switch]$RemoveStaleDrafts)
    $desiredText = ((Get-DocxParagraphs (Get-Content -LiteralPath $LocalPath -Raw)) | ForEach-Object Text) -join "`n"
    $existing = @(Get-PnPFolderItem -FolderSiteRelativeUrl $Folder -ItemType File -Connection $SiteConnection |
        Where-Object Name -eq $FileName)
    $write = $true
    if ($existing.Count -eq 1) {
        $before = Read-DocxText ((Get-PnPFile -Url "$Folder/$FileName" -AsMemoryStream -Connection $SiteConnection).ToArray())
        if ($before -eq $desiredText) { $write = $false }
        elseif (-not $ReplaceManagedFiles) {
            throw "Managed file $Folder/$FileName differs from the draft. Review it and use -ReplaceManagedFiles to authorize replacement."
        }
        else { $before | Set-Content (Join-Path $auditFolder "$runId-$AuditKey-$FileName-before.txt") -Encoding utf8 }
    }
    if ($write) {
        $temp = Join-Path ([IO.Path]::GetTempPath()) ("coe-" + [guid]::NewGuid().ToString("N"))
        [void][IO.Directory]::CreateDirectory($temp)
        $docxPath = Join-Path $temp $FileName
        try {
            New-SimpleDocx -Text (Get-Content -LiteralPath $LocalPath -Raw) -Path $docxPath -Title $Title
            Add-PnPFile -Path $docxPath -Folder $Folder -Connection $SiteConnection | Out-Null
        } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
        $saved = Read-DocxText ((Get-PnPFile -Url "$Folder/$FileName" -AsMemoryStream -Connection $SiteConnection).ToArray())
        if ($saved -ne $desiredText) { throw "Managed governance document does not match the reviewed draft: $Folder/$FileName" }
    }
    foreach ($legacy in @($LegacyNames | Where-Object { $_ -and $_ -ne $FileName })) {
        $old = @(Get-PnPFolderItem -FolderSiteRelativeUrl $Folder -ItemType File -Connection $SiteConnection | Where-Object Name -eq $legacy)
        if ($old.Count -eq 0) { continue }
        if (-not $ReplaceManagedFiles) {
            Write-Warning "Kept the older copy $Folder/$legacy next to $FileName. Run again with -ReplaceFiles to remove it."
            continue
        }
        Get-PnPFile -Url "$Folder/$legacy" -AsString -Connection $SiteConnection |
            Set-Content (Join-Path $auditFolder "$runId-$AuditKey-$legacy-before.txt") -Encoding utf8
        Remove-PnPFile -SiteRelativeUrl "$Folder/$legacy" -Recycle -Force -Connection $SiteConnection
    }
    # A renamed draft (its title changed in CoE-Revision-Content.json) leaves the earlier kit-generated document
    # behind. With -ReplaceFiles, remove other .docx files in this folder that are kit drafts: they start with
    # the "ILLUSTRATIVE DRAFT FOR" line. Documents an organization added itself are never touched.
    if ($RemoveStaleDrafts -and $ReplaceManagedFiles) {
        foreach ($other in @(Get-PnPFolderItem -FolderSiteRelativeUrl $Folder -ItemType File -Connection $SiteConnection |
                Where-Object { $_.Name -like "*.docx" -and $_.Name -ne $FileName -and $_.Name -ne "Start-Here.docx" })) {
            $otherText = Read-DocxText ((Get-PnPFile -Url "$Folder/$($other.Name)" -AsMemoryStream -Connection $SiteConnection).ToArray())
            if ($otherText -and $otherText.StartsWith("ILLUSTRATIVE DRAFT FOR") -and $other.Name -notlike "Proposed-*-AI-Governance-Policy-DRAFT.docx") {
                $otherText | Set-Content (Join-Path $auditFolder "$runId-$AuditKey-$($other.Name)-before.txt") -Encoding utf8
                Remove-PnPFile -SiteRelativeUrl "$Folder/$($other.Name)" -Recycle -Force -Connection $SiteConnection
            }
        }
    }
    return "$Folder/$FileName"
}

function Sync-TopTenTab {
    param([string]$Team, [string]$Channel, [string]$FileUrl, [string]$EntityId,
        [string[]]$KnownFileUrls, [string]$PreviousEntityId, [switch]$CreateMissing, [object]$Connection)
    Sync-CoEFileTab -Team $Team -Channel $Channel -DisplayName "Top 10 to try" -Type PowerPoint `
        -FileUrl $FileUrl -EntityId $EntityId -KnownFileUrls $KnownFileUrls -PreviousEntityId $PreviousEntityId `
        -CreateMissing:$CreateMissing -VerifyIdentity -RemoveUnboundPlaceholders -Connection $Connection
}

function Get-CalendarLocalDate($StoredDate) {
    if (-not $StoredDate) { return "" }
    $utc = [datetime]$StoredDate
    if ($utc.Kind -eq [DateTimeKind]::Local) { $utc = $utc.ToUniversalTime() }
    else { $utc = [datetime]::SpecifyKind($utc, [DateTimeKind]::Utc) }
    return [TimeZoneInfo]::ConvertTimeFromUtc($utc, $siteTimeZone).ToString("yyyy-MM-dd")
}

function Get-ManagedNavigationUrl([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return "" }
    $absolute = [uri]::new([uri]($SiteUrl.TrimEnd('/') + '/'), $Url)
    return [uri]::UnescapeDataString($absolute.AbsoluteUri).TrimEnd('/')
}

function Sync-GuideNavigation {
    param($SiteConnection, [string]$HubUrl, [object[]]$GuideLinks, [string[]]$OmittedUrls)
    $nodes = @(Get-PnPNavigationNode -Location QuickLaunch -Connection $SiteConnection -ErrorAction Stop)
    $hub = @($nodes | Where-Object { (Get-ManagedNavigationUrl $_.Url) -eq (Get-ManagedNavigationUrl $HubUrl) }) | Select-Object -First 1
    if (-not $hub) {
        $hub = Add-PnPNavigationNode -Location QuickLaunch -Title "Copilot guides" -Url $HubUrl -Connection $SiteConnection
    }
    Get-PnPProperty -ClientObject $hub -Property Children -Connection $SiteConnection -ErrorAction Stop | Out-Null
    # Get-PnPProperty returns the CSOM collection as one object, not individual navigation nodes.
    $children = @(foreach ($child in $hub.Children) { $child })
    $omitted = @($OmittedUrls | ForEach-Object { Get-ManagedNavigationUrl $_ })
    foreach ($node in @($nodes) + @($children)) {
        if ((Get-ManagedNavigationUrl $node.Url) -in $omitted) {
            Remove-PnPNavigationNode -Identity $node.Id -Force -Connection $SiteConnection -ErrorAction Stop
        }
    }
    foreach ($guide in $GuideLinks) {
        $matching = @($children | Where-Object { (Get-ManagedNavigationUrl $_.Url) -eq (Get-ManagedNavigationUrl $guide.Url) })
        if ($matching.Count -eq 0) {
            Add-PnPNavigationNode -Location QuickLaunch -Title $guide.Title -Url $guide.Url -Parent $hub.Id -Connection $SiteConnection | Out-Null
        } else {
            foreach ($node in $matching) {
                if ($node.Title -ne $guide.Title) {
                    $node.Title = $guide.Title
                    $node.Update()
                    $node.Context.ExecuteQuery()
                }
            }
        }
    }
}

function Sync-ChampionPageNavigation {
    param($SiteConnection, [string]$PageUrl, [string]$DirectoryUrl)
    $directoryUri = [uri](Get-ManagedNavigationUrl $DirectoryUrl)
    $directoryPath = [uri]::UnescapeDataString($directoryUri.AbsolutePath).TrimEnd('/')
    $nodes = @(Get-PnPNavigationNode -Location QuickLaunch -Connection $SiteConnection -ErrorAction Stop)
    foreach ($node in $nodes) {
        $managedUrl = Get-ManagedNavigationUrl $node.Url
        if ([string]::IsNullOrWhiteSpace($managedUrl)) { continue }
        $nodeUri = [uri]$managedUrl
        $nodePath = [uri]::UnescapeDataString($nodeUri.AbsolutePath).TrimEnd('/')
        if ($nodeUri.Authority -eq $directoryUri.Authority -and
            ($nodePath -eq $directoryPath -or $nodePath.StartsWith("$directoryPath/", [StringComparison]::OrdinalIgnoreCase))) {
            Remove-PnPNavigationNode -Identity $node.Id -Force -Connection $SiteConnection -ErrorAction Stop
        }
    }

    $pageTarget = Get-ManagedNavigationUrl $PageUrl
    $pageNodes = @(Get-PnPNavigationNode -Location QuickLaunch -Connection $SiteConnection -ErrorAction Stop |
        Where-Object { (Get-ManagedNavigationUrl $_.Url) -eq $pageTarget })
    if ($pageNodes.Count -eq 0) {
        Add-PnPNavigationNode -Location QuickLaunch -Title "Department Champions" -Url $PageUrl `
            -Connection $SiteConnection -ErrorAction Stop | Out-Null
        return
    }

    $primary = $pageNodes[0]
    if ($primary.Title -ne "Department Champions") {
        $primary.Title = "Department Champions"
        $primary.Update()
        $primary.Context.ExecuteQuery()
    }
    foreach ($duplicate in @($pageNodes | Select-Object -Skip 1)) {
        Remove-PnPNavigationNode -Identity $duplicate.Id -Force -Connection $SiteConnection -ErrorAction Stop
    }
}

function Write-ManagedSeedFile {
    param([object]$SiteConnection, [string]$Folder, [string]$LocalPath, [string]$AuditKey)
    $name = Split-Path -Leaf $LocalPath
    $desired = Get-Content -LiteralPath $LocalPath -Raw
    $existing = @(Get-PnPFolderItem -FolderSiteRelativeUrl $Folder -ItemType File -Connection $SiteConnection |
        Where-Object Name -eq $name)
    if ($existing.Count -gt 1) { throw "Duplicate managed governance file: $Folder/$name" }
    if ($existing.Count -eq 1) {
        $before = Get-PnPFile -Url "$Folder/$name" -AsString -Connection $SiteConnection
        if ([string]::Equals($before.TrimStart([char]0xFEFF), $desired.TrimStart([char]0xFEFF), [StringComparison]::Ordinal)) {
            return
        }
        if (-not $ReplaceManagedFiles) {
            throw "Managed file $Folder/$name differs from the draft. Review it and use -ReplaceManagedFiles to authorize replacement."
        }
        $before | Set-Content (Join-Path $auditFolder "$runId-$AuditKey-$name-before.txt") -Encoding utf8
    }
    Add-PnPFile -Path $LocalPath -Folder $Folder -Connection $SiteConnection | Out-Null
    $saved = Get-PnPFile -Url "$Folder/$name" -AsString -Connection $SiteConnection
    if (-not [string]::Equals($saved.TrimStart([char]0xFEFF), $desired.TrimStart([char]0xFEFF), [StringComparison]::Ordinal)) {
        throw "Managed governance file does not match the reviewed draft: $Folder/$name"
    }
}

if (-not $GovernanceOnly -and -not $GuidesOnly) {
# A new group site gets a default Home.aspx; the CoE's home page is TrainingHome, so the default page only
# adds a blank "Home" entry to Site pages. Remove it once TrainingHome is confirmed as the home page.
$welcomePage = [string](Get-PnPHomePage -Connection $site)
if ($welcomePage -match 'TrainingHome\.aspx$' -and @(Get-PnPPage -Connection $site | Where-Object Name -eq "Home.aspx").Count -eq 1) {
    Remove-PnPPage -Identity "Home" -Recycle -Force -Connection $site
}
# Keep the original layout and other readiness resources; edit only the approved controls.
$readiness = Get-PnPPage -Identity "Technical Readiness.aspx" -Connection $site
$readinessItem = Get-PnPFile -Url "SitePages/Technical Readiness.aspx" -AsListItem -Connection $site
$readinessItem.FieldValues | ConvertTo-Json -Depth 20 |
    Set-Content (Join-Path $auditFolder "$runId-Readiness-before.json") -Encoding utf8
$oldForum = "https://techcommunity.microsoft.com/t5/microsoft-365-copilot/bd-p/Microsoft365Copilot"
$oldForumCount = 0
$eapCount = 0
foreach ($control in @($readiness.Controls)) {
    if ($control.GetType().Name -ne "PageWebPart") { continue }
    $raw = $control.ServerProcessedContent.GetRawText()
    if ($raw -match "Early Access Program|m365-early-access-program") {
        Remove-PnPPageComponent -Page $readiness -InstanceId $control.InstanceId -Force -Connection $site
        $eapCount++
    } elseif ($raw.Contains($oldForum)) {
        $oldForumCount++
    }
}
[void]$readiness.Save()
$savedReadiness = Get-PnPFile -Url "SitePages/Technical Readiness.aspx" -AsListItem -Connection $site
$canvas = [string]$savedReadiness["CanvasContent1"]
if ($canvas.Contains($oldForum)) {
    Set-PnPListItem -List "Site Pages" -Identity $savedReadiness.Id `
        -Values @{ CanvasContent1 = $canvas.Replace($oldForum, $copy.repairs.forum) } -Connection $site | Out-Null
}
$readinessFile = Get-PnPFile -Url "SitePages/Technical Readiness.aspx" -AsFileObject -Connection $site
$readinessFile.Publish("Remove Early Access Program and update the Copilot community link")
Invoke-PnPQuery -Connection $site
$publishedReadiness = Get-PnPListItem -List "Site Pages" -Id $savedReadiness.Id -Connection $site
if ([string]$publishedReadiness["CanvasContent1"] -match "Early Access Program|m365-early-access-program" -or
    ([string]$publishedReadiness["CanvasContent1"]).Contains($oldForum)) {
    throw "The published Technical Readiness page still contains an obsolete resource."
}
$report.Readiness = @{ RemovedEapControls = $eapCount; ReplacedForumControls = $oldForumCount }

# Replace the vendor learning-page buttons that all pointed to the generic home.
$training = Get-PnPFile -Url "SitePages/TrainingHome.aspx" -AsListItem -Connection $site
$training.FieldValues | ConvertTo-Json -Depth 20 |
    Set-Content (Join-Path $auditFolder "$runId-TrainingHome-before.json") -Encoding utf8
$trainingCanvas = [string]$training["CanvasContent1"]
$newTrainingCanvas = [regex]::Replace($trainingCanvas, 'data-sp-webpartdata="([^"]*)"', {
    param($match)
    $jsonText = [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
    $data = $jsonText | ConvertFrom-Json -AsHashtable
    if ($data.ContainsKey("serverProcessedContent") -and
        $data["serverProcessedContent"].ContainsKey("searchablePlainTexts") -and
        $data["serverProcessedContent"]["searchablePlainTexts"]["title"] -eq "Resources") {
        foreach ($resource in $resourceLinks) {
            $url = $resource.url.Replace("{site}", $SiteUrl.TrimEnd("/")).Replace("{ask-channel-url}", $askChannelUrl)
            $itemIndex = [int]$resource.index
            if ($itemIndex -ge $data["properties"]["items"].Count) {
                throw "Resource card index $itemIndex is outside the SharePoint Quick Links control."
            }
            $data["properties"]["items"][$itemIndex]["sourceItem"]["url"] = $url
            if (([uri]$url).Host -ne ([uri]$SiteUrl).Host) {
                # Placeholder site identities override external URLs when PnP saves Quick Links.
                $data["properties"]["items"][$itemIndex]["sourceItem"].Remove("guids")
                $data["properties"]["items"][$itemIndex]["sourceItem"]["itemType"] = 2
            }
            $data["serverProcessedContent"]["links"]["items[$itemIndex].sourceItem.url"] = $url
        }
        return 'data-sp-webpartdata="' + [System.Net.WebUtility]::HtmlEncode(($data | ConvertTo-Json -Depth 30 -Compress)) + '"'
    }
    return $match.Value
})
if ($newTrainingCanvas -eq $trainingCanvas -and -not $trainingCanvas.Contains("Meet-your-Champions.aspx")) {
    throw "Training resource control was not located; no success-shaped resource fallback is allowed."
}
if ($newTrainingCanvas -ne $trainingCanvas) {
    Set-PnPListItem -List "Site Pages" -Identity $training.Id -Values @{CanvasContent1=$newTrainingCanvas} -Connection $site | Out-Null
    $trainingFile = Get-PnPFile -Url "SitePages/TrainingHome.aspx" -AsFileObject -Connection $site
    $trainingFile.Publish("Replace generic home placeholders with purposeful Copilot resources")
    Invoke-PnPQuery -Connection $site
}
$savedTraining = Get-PnPListItem -List "Site Pages" -Id $training.Id -Connection $site
$savedCanvas = [string]$savedTraining["CanvasContent1"]
$resourceControls = @([regex]::Matches($savedCanvas, 'data-sp-webpartdata="([^"]*)"') | ForEach-Object {
    $jsonText = [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value)
    $candidate = $jsonText | ConvertFrom-Json -AsHashtable
    if ($candidate.ContainsKey("serverProcessedContent") -and
        $candidate["serverProcessedContent"].ContainsKey("searchablePlainTexts") -and
        $candidate["serverProcessedContent"]["searchablePlainTexts"]["title"] -eq "Resources") { $candidate }
})
if ($resourceControls.Count -ne 1) { throw "Expected exactly one published Resources Quick Links control." }
$resourceComponents = @(Get-PnPPageComponent -Page "TrainingHome.aspx" -Connection $site |
    Where-Object { $_.InstanceId.ToString() -eq $resourceControls[0]["instanceId"] })
if ($resourceComponents.Count -ne 1) {
    throw "Expected one editable Resources Quick Links component; found $($resourceComponents.Count)."
}
$resourceProperties = $resourceControls[0]["properties"] | ConvertTo-Json -Depth 30 -Compress
Set-PnPPageWebPart -Page "TrainingHome.aspx" -Identity $resourceComponents[0].InstanceId `
    -PropertiesJson $resourceProperties -Connection $site | Out-Null
Set-PnPPage -Identity "TrainingHome.aspx" -Publish -Connection $site | Out-Null
$verifiedComponent = @(Get-PnPPageComponent -Page "TrainingHome.aspx" -Connection $site |
    Where-Object InstanceId -eq $resourceComponents[0].InstanceId)
if ($verifiedComponent.Count -ne 1) { throw "The Resources web part disappeared after the update." }
$verifiedTraining = Get-PnPFile -Url "SitePages/TrainingHome.aspx" -AsListItem -Connection $site
$verifiedControls = @([regex]::Matches([string]$verifiedTraining["CanvasContent1"], 'data-sp-webpartdata="([^"]*)"') | ForEach-Object {
    $candidate = [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value) | ConvertFrom-Json -AsHashtable
    if ($candidate["instanceId"] -eq $resourceComponents[0].InstanceId.ToString()) { $candidate }
})
if ($verifiedControls.Count -ne 1) { throw "Could not read the saved Resources link metadata." }
foreach ($resource in $resourceLinks) {
    $itemIndex = [int]$resource.index
    $expectedUrl = $resource.url.Replace("{site}", $SiteUrl.TrimEnd("/")).Replace("{ask-channel-url}", $askChannelUrl)
    $actualUrl = $verifiedControls[0]["serverProcessedContent"]["links"]["items[$itemIndex].sourceItem.url"]
    if ([uri]::new([uri]$SiteUrl, $actualUrl).AbsoluteUri -ne $expectedUrl) {
        throw "The published Resources card '$($resource.label)' does not contain its intended destination."
    }
    $anchorPattern = '<a data-sp-prop-name="items\[' + $itemIndex + '\]\.sourceItem\.url" href="([^"]*)"'
    $anchors = [regex]::Matches([string]$verifiedTraining["CanvasContent1"], $anchorPattern)
    if ($anchors.Count -ne 1 -or
        [uri]::new([uri]$SiteUrl, [System.Net.WebUtility]::HtmlDecode($anchors[0].Groups[1].Value)).AbsoluteUri -ne $expectedUrl) {
        throw "The rendered-link anchor for '$($resource.label)' does not match its intended destination."
    }
}
$report.LearningResources = @($resourceLinks | ForEach-Object {
    @{Label=$_.label; Url=$_.url.Replace("{site}", $SiteUrl.TrimEnd("/")).Replace("{ask-channel-url}", $askChannelUrl)}
})

$listTitle = "Department Champions"
$list = @(Get-PnPList -Connection $site | Where-Object Title -eq $listTitle)
if ($list.Count -eq 0) {
    $directory = New-PnPList -Title $listTitle -Template GenericList -Url "Lists/DepartmentChampions" `
        -EnableVersioning -Connection $site
} elseif ($list.Count -eq 1) {
    $directory = $list[0]
} else { throw "Duplicate champions lists." }
Set-PnPField -List $directory -Identity Title -Values @{Title = "Department"} -Connection $site
$fieldSpecs = @(
    @{ Name = "PrimaryChampion"; Title = "Primary champion"; Type = "User" },
    @{ Name = "BackupChampion"; Title = "Backup champion"; Type = "User" },
    @{ Name = "ContactLink"; Title = "Contact or Teams link"; Type = "URL" },
    @{ Name = "Expertise"; Title = "Expertise"; Type = "Note" },
    @{ Name = "ProfileSummary"; Title = "Champion profile summary"; Type = "Note" },
    @{ Name = "ProfilePhoto"; Title = "Approved profile photo link"; Type = "URL" },
    @{ Name = "OfficeHours"; Title = "Office hours"; Type = "Text" },
    @{ Name = "AppointmentStatus"; Title = "Appointment status"; Type = "Choice" },
    @{ Name = "DirectoryOwner"; Title = "Directory owner"; Type = "User" },
    @{ Name = "LastVerified"; Title = "Last verified"; Type = "DateTime" }
)
$existingFields = @(Get-PnPField -List $directory -Connection $site | ForEach-Object InternalName)
foreach ($f in $fieldSpecs) {
    if ($f.Name -in $existingFields) { continue }
    if ($f.Type -eq "Choice") {
        Add-PnPFieldFromXml -List $directory -FieldXml '<Field Type="Choice" DisplayName="Appointment status" Name="AppointmentStatus" StaticName="AppointmentStatus" Format="Dropdown"><Default>Not assigned</Default><CHOICES><CHOICE>Not assigned</CHOICE><CHOICE>Active</CHOICE><CHOICE>On leave</CHOICE><CHOICE>Needs review</CHOICE></CHOICES></Field>' -Connection $site | Out-Null
    } else {
        Add-PnPField -List $directory -DisplayName $f.Title -InternalName $f.Name -Type $f.Type `
            -AddToDefaultView -Connection $site | Out-Null
    }
}
Set-PnPList -Identity $directory -Description $copy.champions.maintenance -EnableVersioning $true `
    -EnableAttachments $false -Connection $site | Out-Null

$views = @(Get-PnPView -List $directory -Connection $site)
$view = @($views | Where-Object Title -eq "By department")
if ($view.Count -eq 0) {
    $directoryView = Add-PnPView -List $directory -Title "By department" `
        -Fields @("Title","PrimaryChampion","BackupChampion","ContactLink","Expertise","ProfileSummary","ProfilePhoto","OfficeHours","AppointmentStatus","DirectoryOwner","LastVerified") `
        -Query '<OrderBy><FieldRef Name="Title" Ascending="TRUE"/></OrderBy>' -RowLimit 30 -Paged -SetAsDefault -Connection $site
} else { $directoryView = $view[0] }
$rows = @(Get-PnPListItem -List $directory -PageSize 100 -Connection $site)
# ChampionDepartments in the organization settings replaces the kit's generic sample rows with the
# organization's real units (each still "Not assigned" until a champion is appointed).
$championRows = @($copy.champions.sampleRows)
$orgDepartments = @(@(Get-OrgValue "ChampionDepartments" @()) | Where-Object {
    $_ -and -not ($_ -is [string] -and $_ -match '[<>]') -and -not ($_ -isnot [string] -and [string]$_.department -match '^\s*$|[<>]') })
if ($orgDepartments.Count -gt 0) {
    $championRows = @($orgDepartments | Where-Object { $_ } | ForEach-Object {
        if ($_ -is [string]) { [pscustomobject]@{ department = $_; expertise = ""; status = "Not assigned" } }
        else { [pscustomobject]@{ department = [string]$_.department
            expertise = $(if ($_.PSObject.Properties["expertise"]) { [string]$_.expertise } else { "" }); status = "Not assigned" } }
    })
}
foreach ($sample in $championRows) {
    if ($sample.department -in @($rows | ForEach-Object { $_["Title"] })) { continue }
    $values = @{ Title = $sample.department; AppointmentStatus = $sample.status }
    if ($sample.expertise) { $values.Expertise = $sample.expertise }
    Add-PnPListItem -List $directory -Values $values -Connection $site | Out-Null
}

# Public users can consult the directory; list owners maintain appointments.
if (-not (Get-PnPProperty -ClientObject $directory -Property HasUniqueRoleAssignments -Connection $site)) {
    Set-PnPList -Identity $directory -BreakRoleInheritance -CopyRoleAssignments -Connection $site | Out-Null
}
$memberGroup = Get-PnPGroup -AssociatedMemberGroup -Connection $site
$assignments = Get-PnPProperty -ClientObject $directory -Property RoleAssignments -Connection $site
foreach ($assignment in $assignments) {
    $principal = Get-PnPProperty -ClientObject $assignment -Property Member -Connection $site
    if ($principal.Id -ne $memberGroup.Id) { continue }
    $roles = Get-PnPProperty -ClientObject $assignment -Property RoleDefinitionBindings -Connection $site
    foreach ($role in @($roles)) {
        if ($role.Name -ne "Read") {
            Set-PnPListPermission -Identity $directory -Group $memberGroup -RemoveRole $role.Name -Connection $site
        }
    }
}
Set-PnPListPermission -Identity $directory -Group $memberGroup -AddRole "Read" -Connection $site

$directoryUrl = "$($SiteUrl.TrimEnd('/'))/Lists/DepartmentChampions/AllItems.aspx"
# Champion profiles come only from the organization (champions.profiles in its CoE-Revision-Content.json override),
# each published with the person's consent, and only when the photo lives in this tenant. The kit ships none.
$profilesForSite = @(if ($copy.champions.PSObject.Properties["profiles"]) {
    $copy.champions.profiles | Where-Object { $_ -and $_.PSObject.Properties["photoUrl"] -and $_.photoUrl -and
        ([uri]$_.photoUrl).Host -eq ([uri]$SiteUrl).Host }
})
$championHtml = "<h2>$(Escape-Html $copy.champions.title)</h2><p><em>$(Escape-Html $SampleNotice)</em></p><p>$(Escape-Html $copy.champions.intro)</p>"
if ($profilesForSite.Count -gt 0) {
    $championHtml += "<h3>Champion profiles</h3><p>Each profile is published with the person's permission. Contact links open their directory accounts.</p>"
} else {
    $championHtml += "<h3>Champion profiles</h3><p>No locally approved profiles have been supplied. Department assignments remain as shown in the directory.</p>"
}
foreach ($profile in $profilesForSite) {
    $contactUrl = "mailto:$($profile.email)"
    $label = if ($profile.PSObject.Properties["label"] -and $profile.label) { "<p>$(Escape-Html $profile.label)</p>" } else { "" }
    $championHtml += "<h4><img src='$(Escape-Html $profile.photoUrl)' alt='Profile photo of $(Escape-Html $profile.name)' width='72' height='72' /> " +
        "$(Escape-Html $profile.name)</h4><p><strong>$(Escape-Html $profile.title)</strong> | $(Escape-Html $profile.department)</p>" +
        "$label<p>$(Escape-Html $profile.summary)</p>" +
        "<p><a href='$(Escape-Html $contactUrl)'>Email $(Escape-Html $profile.name)</a></p>"
}
$championHtml +=
    "<p><a href='$directoryUrl'>Open the department directory: filter Department to find your primary and backup champion</a></p>"
# An organization guide named <NN>-Champions-Toolkit.md is linked here for the champions themselves.
$toolkitGuide = @(Get-ChildItem -LiteralPath (Join-Path $seedRoot "Guides") -Filter "*-Champions-Toolkit.md" -File -ErrorAction SilentlyContinue |
    Where-Object { -not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($_.FullName)) }) | Select-Object -First 1
if ($toolkitGuide) {
    $toolkitUrl = "$($SiteUrl.TrimEnd('/'))/SitePages/Guide-$($toolkitGuide.BaseName -replace '^\d+[a-z]?-', '').aspx"
    $championHtml += "<h3>For champions</h3><p><a href='$toolkitUrl'>Champions toolkit</a>: your monthly rhythm, a 10-minute demo script, prompts of the week, and where to send questions you shouldn't answer.</p>"
}
$championHtml +=
    "<h3>Keeping the directory accurate</h3><p>$(Escape-Html $copy.champions.maintenance)</p>"
$championPage = Write-ManagedPage -SiteConnection $site -Name "Meet-your-Champions" `
    -Title $copy.champions.title -Html $championHtml
if (Test-ManagedPageWritten $site "Meet-your-Champions") {
Add-PnPPageWebPart -Page $championPage -DefaultWebPartType List -WebPartProperties @{
    selectedListId = $directory.Id.ToString()
    selectedListUrl = "$(([uri]$SiteUrl).AbsolutePath.TrimEnd('/'))/Lists/DepartmentChampions"
    selectedViewId = $directoryView.Id.ToString()
    hideCommandBar = $false
    hideTitle = $true
    showTitle = $false
    isDocumentLibrary = $false
} -Connection $site | Out-Null
Set-PnPPage -Identity "Meet-your-Champions" -Publish -Connection $site | Out-Null
}
$report.Champions = @{ Directory = $directoryUrl; ViewId = $directoryView.Id; SampleRows = $championRows.Count; DemoProfiles = $profilesForSite.Count }
Sync-ChampionPageNavigation -SiteConnection $site `
    -PageUrl "$($SiteUrl.TrimEnd('/'))/SitePages/Meet-your-Champions.aspx" `
    -DirectoryUrl "$($SiteUrl.TrimEnd('/'))/Lists/DepartmentChampions"

$askChannel = @($channels | Where-Object DisplayName -like "Ask Us Anything*")
if ($askChannel.Count -ne 1) { throw "Expected one Ask Us Anything standard channel." }

# Seed an Events-template list so the calendar has editable records and a calendar view.
# The site time zone was set right after connecting; seed times are read in that same zone.
$calendarTitle = "Copilot Training Calendar"
$calendarLists = @(Get-PnPList -Connection $site | Where-Object Title -eq $calendarTitle)
if ($calendarLists.Count -gt 1) { throw "Duplicate training calendar lists." }
if ($calendarLists.Count -eq 0) {
    $calendar = New-PnPList -Title $calendarTitle -Template Events -Url "Lists/CopilotTrainingCalendar" `
        -EnableVersioning -OnQuickLaunch -Connection $site
} else {
    $calendar = $calendarLists[0]
}
$calendarFields = @(Get-PnPField -List $calendar -Connection $site | ForEach-Object InternalName)
foreach ($requiredField in @("EventDate", "EndDate", "Description", "Location")) {
    if ($requiredField -notin $calendarFields) {
        throw "The existing training calendar is missing the Events field '$requiredField'."
    }
}
foreach ($field in @(
    @{ Name = "Audience"; Title = "Audience"; Type = "Text" },
    @{ Name = "Format"; Title = "Format"; Type = "Choice" },
    @{ Name = "SampleStatus"; Title = "Sample status"; Type = "Choice" }
)) {
    if ($field.Name -in $calendarFields) { continue }
    if ($field.Name -eq "Format") {
        Add-PnPField -List $calendar -DisplayName $field.Title -InternalName $field.Name -Type Choice `
            -Choices @("Online session", "In-person session", "Hybrid") -AddToDefaultView -Connection $site | Out-Null
    } elseif ($field.Name -eq "SampleStatus") {
        Add-PnPField -List $calendar -DisplayName $field.Title -InternalName $field.Name -Type Choice `
            -Choices @("DRAFT - DEMONSTRATION", "Approved", "Cancelled") -AddToDefaultView -Connection $site | Out-Null
    } else {
        Add-PnPField -List $calendar -DisplayName $field.Title -InternalName $field.Name -Type Text `
            -AddToDefaultView -Connection $site | Out-Null
    }
}
$calendarViews = @(Get-PnPView -List $calendar -Connection $site)
if (@($calendarViews | Where-Object Title -eq "Calendar").Count -eq 0) {
    Add-PnPView -List $calendar -Title "Calendar" -Fields @("Title", "EventDate", "EndDate", "Location", "Audience", "SampleStatus") `
        -ViewType Calendar -SetAsDefault -Paged -Connection $site | Out-Null
}
$eventSeedPath = Join-Path $seedRoot "Training-Calendar.csv"
if (-not (Test-Path -LiteralPath $eventSeedPath -PathType Leaf)) {
    throw "The training calendar seed file is missing: $eventSeedPath"
}
$eventSeeds = @(Import-Csv -LiteralPath $eventSeedPath)
# Re-read the list on the site connection so later item writes and the web part binding share one context.
$calendar = Get-PnPList -Identity "Lists/CopilotTrainingCalendar" -Connection $site
if (-not $calendar) { throw "The training calendar list could not be re-read after setup." }
$existingEvents = @(Get-PnPListItem -List $calendar -PageSize 100 -Connection $site)
$eastern = $siteTimeZone
$eventsAdded = 0
foreach ($event in $eventSeeds) {
    $startLocal = [datetime]::ParseExact("$($event.StartDate) $($event.StartTimeET)", "yyyy-MM-dd HH:mm", `
        [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
    $endLocal = [datetime]::ParseExact("$($event.EndDate) $($event.EndTimeET)", "yyyy-MM-dd HH:mm", `
        [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
    if ($endLocal -le $startLocal) { throw "Training event has an invalid time range: $($event.Title)" }
    $startUtc = [TimeZoneInfo]::ConvertTimeToUtc($startLocal, $eastern)
    $endUtc = [TimeZoneInfo]::ConvertTimeToUtc($endLocal, $eastern)
    $alreadySeeded = @($existingEvents | Where-Object {
        $storedDate = $_["EventDate"]
        $_["Title"] -eq $event.Title -and $storedDate -and (Get-CalendarLocalDate $storedDate) -eq $event.StartDate
    }).Count -gt 0
    if ($alreadySeeded) { continue }
    Add-PnPListItem -List $calendar.Id -Values @{
        Title = $event.Title
        EventDate = $startUtc
        EndDate = $endUtc
        Description = $event.Description
        Location = "Not assigned - sample only"
        Audience = $event.Audience
        Format = $event.Format
        SampleStatus = $event.SampleStatus
    } -Connection $site | Out-Null
    $eventsAdded++
}
# Remove kit sample sessions that are no longer in the seed file (for example after an organization
# replaces Training-Calendar.csv). Only rows still marked as samples are touched; real sessions are kept.
$seedKeys = @($eventSeeds | ForEach-Object { "$($_.Title)|$($_.StartDate)" })
foreach ($item in $existingEvents) {
    $storedDate = $item["EventDate"]
    $key = "$($item["Title"])|$(Get-CalendarLocalDate $storedDate)"
    if ([string]$item["SampleStatus"] -eq "DRAFT - DEMONSTRATION" -and $key -notin $seedKeys) {
        Remove-PnPListItem -List $calendar.Id -Identity $item.Id -Recycle -Force -Connection $site | Out-Null
    }
}
$calendarUrl = "$($SiteUrl.TrimEnd('/'))/Lists/CopilotTrainingCalendar/Calendar.aspx"
# The "Learning Series" heading lives in the web part's server-processed content, not PropertiesJson,
# so match the Events web part (WebPartId 20745d7d-...) and require that TrainingHome has exactly one.
$learningComponents = @(Get-PnPPageComponent -Page "TrainingHome.aspx" -Connection $site |
    Where-Object { $_.GetType().Name -eq "PageWebPart" -and
        ("$($_.WebPartId)" -eq "20745d7d-8581-4a6c-bf26-68279bc123fc" -or $_.Title -eq "Events") })
if ($learningComponents.Count -ne 1) {
    throw "Expected one Events (Learning Series) web part on TrainingHome; found $($learningComponents.Count)."
}
$learningProperties = $learningComponents[0].PropertiesJson | ConvertFrom-Json -AsHashtable
$learningProperties["selectedListId"] = $calendar.Id.ToString()
Set-PnPPageWebPart -Page "TrainingHome.aspx" -Identity $learningComponents[0].InstanceId `
    -PropertiesJson ($learningProperties | ConvertTo-Json -Depth 30 -Compress) -Connection $site | Out-Null
Set-PnPPage -Identity "TrainingHome.aspx" -Publish -Connection $site | Out-Null
$savedLearning = @(Get-PnPPageComponent -Page "TrainingHome.aspx" -Connection $site |
    Where-Object InstanceId -eq $learningComponents[0].InstanceId)
if ($savedLearning.Count -ne 1 -or
    ($savedLearning[0].PropertiesJson | ConvertFrom-Json).selectedListId -ne $calendar.Id.ToString()) {
    throw "Learning Series is not bound to the seeded training calendar."
}
$report.TrainingCalendar = @{ Url = $calendarUrl; ListUrl = "$($SiteUrl.TrimEnd('/'))/Lists/CopilotTrainingCalendar/AllItems.aspx"; SampleEvents = $eventSeeds.Count; Added = $eventsAdded }
}

if (-not $GovernanceOnly) {

$faqPath = Join-Path $seedRoot "Copilot-FAQs.md"
if (-not (Test-Path -LiteralPath $faqPath -PathType Leaf)) { throw "The FAQ seed file is missing: $faqPath" }
$faqHtml = "<h2>Microsoft Copilot: starter FAQs</h2><p><em>$(Escape-Html $SampleNotice)</em></p>" +
    (Convert-GuideMarkdown -Text (Get-Content -LiteralPath $faqPath -Raw)).Html
$null = Write-ManagedPage -SiteConnection $site -Name "Copilot-FAQs" -Title "Microsoft Copilot FAQs" -Html $faqHtml
$faqUrl = "$($SiteUrl.TrimEnd('/'))/SitePages/Copilot-FAQs.aspx"

# Give Feedback page text: SeedContent\Give-Feedback.md (organizations override it with <OrgPath>\Content\Give-Feedback.md).
$feedbackPath = Join-Path $seedRoot "Give-Feedback.md"
if (-not (Test-Path -LiteralPath $feedbackPath -PathType Leaf)) { throw "The Give Feedback seed file is missing: $feedbackPath" }
$feedback = Convert-GuideMarkdown -Text (Get-Content -LiteralPath $feedbackPath -Raw).Replace("{{AskChannelUrl}}", $askChannelUrl)
if (-not $feedback.Title) { throw "Give-Feedback.md must start with a '# Title' line." }
$feedbackHtml = "<h2>$(Escape-Html $feedback.Title)</h2><p><em>$(Escape-Html $SampleNotice)</em></p>" +
    $(if ($feedback.Summary) { "<p>$(Convert-MarkdownInline $feedback.Summary)</p>" } else { "" }) + $feedback.Html +
    (Get-CoESupportRouteHtml $supportRoutes)
$null = Write-ManagedPage -SiteConnection $site -Name "Give-Feedback" -Title "Give Copilot Feedback" -Html $feedbackHtml
$feedbackUrl = "$($SiteUrl.TrimEnd('/'))/SitePages/Give-Feedback.aspx"
$report.FAQ = @{ Url = $faqUrl; Source = "SeedContent/Copilot-FAQs.md"; Questions = ([regex]::Matches((Get-Content -LiteralPath $faqPath -Raw), '(?m)^## ')).Count }
$report.Feedback = @{ Url = $feedbackUrl; ChannelUrl = $askChannelUrl; SubmissionsCreated = 0 }

# Copilot guides: one SharePoint page per SeedContent\Guides\*.md file, plus a hub page and navigation.
# An empty file at <OrgPath>\Content\Guides\<name>.md removes that kit guide from the hub and the build.
$allGuideFiles = @(Get-ChildItem -LiteralPath (Join-Path $seedRoot "Guides") -Filter "*.md" -File | Sort-Object Name)
$omittedGuideUrls = @($allGuideFiles | Where-Object { [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($_.FullName)) } |
    ForEach-Object { "$($SiteUrl.TrimEnd('/'))/SitePages/Guide-$($_.BaseName -replace '^\d+[a-z]?-', '').aspx" })
$guideFiles = @($allGuideFiles |
    Where-Object { -not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($_.FullName)) })
$guideLinks = @()
foreach ($guideFile in $guideFiles) {
    $converted = Convert-GuideMarkdown -Text (Get-Content -LiteralPath $guideFile.FullName -Raw)
    if (-not $converted.Title) { throw "Guide $($guideFile.Name) must start with a '# Title' line." }
    $pageName = "Guide-" + ($guideFile.BaseName -replace '^\d+[a-z]?-', '')
    $guideHtml = "<h2>$(Escape-Html $converted.Title)</h2><p><em>$(Escape-Html $SampleNotice)</em></p>" + $converted.Html +
        "<p><a href='$($SiteUrl.TrimEnd('/'))/SitePages/Copilot-Guides.aspx'>Back to all Copilot guides</a></p>"
    $null = Write-ManagedPage -SiteConnection $site -Name $pageName -Title $converted.Title -Html $guideHtml
    $guideLinks += [pscustomobject]@{ Title = $converted.Title; Summary = $converted.Summary
        Url = "$($SiteUrl.TrimEnd('/'))/SitePages/$pageName.aspx"; Source = "SeedContent/Guides/$($guideFile.Name)" }
}
$guidesIntro = [string](Get-OrgValue "GuidesIntro" "Practical guidance for faculty, staff, students, and IT. Start with the guide that matches your role.")
$hubHtml = "<h2>Copilot guides</h2><p>$(Escape-Html $guidesIntro)</p>" +
    "<p><em>$(Escape-Html $SampleNotice)</em></p>"
foreach ($guide in $guideLinks) {
    $hubHtml += "<h3><a href='$(Escape-Html $guide.Url)'>$(Escape-Html $guide.Title)</a></h3><p>$(Convert-MarkdownInline $guide.Summary)</p>"
}
$hubHtml += "<h3>Related</h3><p><a href='$faqUrl'>Copilot FAQs</a> | <a href='$feedbackUrl'>Give feedback or report a concern</a></p>"
$null = Write-ManagedPage -SiteConnection $site -Name "Copilot-Guides" -Title "Copilot guides" -Html $hubHtml
$hubUrl = "$($SiteUrl.TrimEnd('/'))/SitePages/Copilot-Guides.aspx"

Sync-GuideNavigation -SiteConnection $site -HubUrl $hubUrl -GuideLinks $guideLinks -OmittedUrls $omittedGuideUrls
if ($omittedGuideUrls.Count -gt 0) {
    Write-Warning "Omitted guides were removed from managed navigation. Existing guide pages are preserved; review and retire them manually if authorized."
    if (-not (Test-ManagedPageWritten $site "Copilot-Guides")) {
        Write-Warning "The existing guide hub was preserved and may still link to omitted guides. Review it before using -ReplaceManagedPages."
    }
}
$generalChannel = @($channels | Where-Object DisplayName -eq "General")
if ($generalChannel.Count -eq 1) {
    $generalTabs = @(Get-PnPTeamsTab -Team $group.GroupId -Channel $generalChannel[0].Id -Connection $Connection)
    if ("Copilot guides" -notin @($generalTabs | ForEach-Object DisplayName)) {
        Add-TeamsTabWithRetry -Team $group.GroupId -Channel $generalChannel[0].Id -DisplayName "Copilot guides" `
            -TabArgs @{ Type = "SharePointPageAndList"; WebSiteUrl = $hubUrl } -Connection $Connection | Out-Null
    }
}
$report.Guides = @{ Hub = $hubUrl; Pages = @($guideLinks | Select-Object Title, Url, Source); OmittedPagesPreserved = $omittedGuideUrls }

# CoE sections: per section a page, a standard channel with a Start here tab, a navigation
# link, and the seed files under SeedContent\Sections\Files\<channel>. Existing files are
# kept unless -ReplaceManagedFiles is used; existing list rows are never changed.
$sectionRoot = Join-Path $seedRoot "Sections"
$sectionConfig = Get-Content -LiteralPath (Join-Path $sectionRoot "Sections.json") -Raw | ConvertFrom-Json
if ($SupportEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw "SupportEmail must be an email address: $SupportEmail" }
$sectionResults = @()
$hasOrgStoryVideos = $false
$storiesFolderUrl = $null
$channelPathStories = $null
$storyVideoUrls = @{}
$quickLaunch = @(Get-PnPNavigationNode -Location QuickLaunch -Connection $site)
foreach ($section in $sectionConfig.sections) {
    $mdPath = Join-Path $sectionRoot $section.file
    if (-not (Test-Path -LiteralPath $mdPath -PathType Leaf)) { throw "Section page source is missing: $mdPath" }
    $markdown = Get-Content -LiteralPath $mdPath -Raw
    $sectionUrl = "$($SiteUrl.TrimEnd('/'))/SitePages/$($section.page).aspx"

    $channel = @($channels | Where-Object DisplayName -eq $section.channel)
    if ($channel.Count -eq 0) {
        Write-CoEStep "Create standard channel" $section.channel
        $null = Add-PnPTeamsChannel -Team $group.GroupId -DisplayName $section.channel `
            -Description $section.description -ChannelType Standard -Connection $Connection
        # Teams lists a new channel after a delay; poll for it rather than trusting one immediate read.
        $waited = Wait-CoEStandardChannel -Team $group.GroupId -DisplayName $section.channel -Connection $Connection
        $channels = @($waited.Channels)
        $channel = @($waited.Channel)
    }
    if ($channel.Count -ne 1 -or $channel[0].MembershipType -ne "standard") {
        throw "Expected one standard channel named '$($section.channel)' but found $($channel.Count) ($(@($channel | ForEach-Object MembershipType) -join ', '))."
    }

    # A new channel's Files folder is provisioned on first request and can take a moment.
    $channelFolder = $null
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            $channelFolder = Get-PnPTeamsChannelFilesFolder -Team $group.GroupId -Channel $channel[0].Id -Connection $Connection
        } catch {
            if ($attempt -eq 6) { throw }
        }
        if ($channelFolder -and $channelFolder.webUrl) { break }
        Start-Sleep -Seconds 10
    }
    if (-not $channelFolder -or -not $channelFolder.webUrl) { throw "The Files folder for '$($section.channel)' was not provisioned." }
    $channelPath = [uri]::UnescapeDataString(([uri]$channelFolder.webUrl).AbsolutePath).Substring(([uri]$SiteUrl).AbsolutePath.Length).TrimStart("/")
    $filesRoot = Join-Path (Join-Path $sectionRoot "Files") $section.channel
    $uploaded = 0
    $assetFolder = $null
    $orgFiles = @()
    if ($section.PSObject.Properties["orgAssets"] -and $section.orgAssets) {
        $assetFolder = $section.orgAssets.folder
        $orgFiles = @(Confirm-OrgAssets $section.orgAssets.category $section.orgAssets.question)
    }
    if ($section.channel -eq "Success Stories" -and $assetFolder) {
        Resolve-PnPFolder -SiteRelativePath "$channelPath/$assetFolder" -Connection $site | Out-Null
        $existingVideos = @(Get-PnPFolderItem -FolderSiteRelativeUrl "$channelPath/$assetFolder" -ItemType File -Recursive -Connection $site |
            Where-Object { $_.Name -notlike "MOCK-*" -and $_.Name -match '\.(mp4|mov|m4v|webm|wmv)$' })
        $hasOrgStoryVideos = $existingVideos.Count -gt 0 -or
            @($orgFiles | Where-Object { $_.Name -notlike "MOCK-*" -and $_.Extension -match '^\.(mp4|mov|m4v|webm|wmv)$' }).Count -gt 0
    }
    if (Test-Path -LiteralPath $filesRoot -PathType Container) {
        foreach ($seedFile in @(Get-ChildItem -LiteralPath $filesRoot -File -Recurse)) {
            $relativeDir = $seedFile.DirectoryName.Substring($filesRoot.Length).Trim("\").Replace("\", "/")
            $target = if ($relativeDir) { "$channelPath/$relativeDir" } else { $channelPath }
            # README files are owner instructions (see the owner launch checklist), not end-user content:
            # never post them, and remove copies an earlier kit version posted.
            if ($seedFile.Name -like "README*") {
                $stale = @(try { Get-PnPFolderItem -FolderSiteRelativeUrl $target -ItemType File -Connection $site |
                    Where-Object Name -eq $seedFile.Name } catch { })
                foreach ($file in $stale) { Remove-PnPFile -SiteRelativeUrl "$target/$($file.Name)" -Recycle -Force -Connection $site }
                continue
            }
            # Organization files replace the kit's sample files in the same folder.
            if ($orgFiles.Count -gt 0 -and $relativeDir -eq $assetFolder) { continue }
            if ($section.channel -eq "Success Stories" -and $seedFile.Name -like "MOCK-*") { continue }
            Resolve-PnPFolder -SiteRelativePath $target -Connection $site | Out-Null
            $present = @(Get-PnPFolderItem -FolderSiteRelativeUrl $target -ItemType File -Connection $site |
                Where-Object Name -eq $seedFile.Name)
            if ($present.Count -eq 0 -or $ReplaceManagedFiles) {
                Add-PnPFile -Path $seedFile.FullName -Folder $target -Connection $site | Out-Null
                $uploaded++
            }
        }
    }
    $orgUploaded = @()
    if ($orgFiles.Count -gt 0) {
        $orgSource = Join-Path $OrgPath "Assets\$($section.orgAssets.category)"
        foreach ($orgFile in $orgFiles) {
            $relativeDir = $orgFile.DirectoryName.Substring($orgSource.Length).Trim("\").Replace("\", "/")
            $target = "$channelPath/$assetFolder" + $(if ($relativeDir) { "/$relativeDir" } else { "" })
            Resolve-PnPFolder -SiteRelativePath $target -Connection $site | Out-Null
            $existing = @(Get-PnPFolderItem -FolderSiteRelativeUrl $target -ItemType File -Connection $site |
                Where-Object Name -eq $orgFile.Name)
            if ($existing.Count -gt 0 -and -not $ReplaceOrgAssets) {
                Write-Warning "Kept existing organization asset '$($orgFile.Name)'. Re-run with -ReplaceOrgAssets only after reviewing the existing file."
                continue
            }
            # Overwrite in place: an upload failure must not recycle the working file first.
            Add-PnPFile -Path $orgFile.FullName -Folder $target -Connection $site -ErrorAction Stop | Out-Null
            $orgUploaded += $orgFile.Name
        }
        Write-Host "  Hosted $($orgUploaded.Count) organization file(s) in $($section.channel) > $assetFolder."
    }
    if ($section.channel -eq "Success Stories") { $storiesFolderUrl = $channelFolder.webUrl.TrimEnd("/"); $channelPathStories = $channelPath }

    # {{HostedFiles}} lists what is now in the section's organization folder, with links.
    # With nothing hosted yet, the placeholder (and a heading left with no content) is dropped from the page.
    $hostedList = $null
    if ($assetFolder) {
        $siteOrigin = ([uri]$SiteUrl).GetLeftPart([UriPartial]::Authority)
        $hosted = @(Get-PnPFolderItem -FolderSiteRelativeUrl "$channelPath/$assetFolder" -ItemType File -Recursive -Connection $site -ErrorAction Stop |
                Where-Object { $_.Name -notlike "README*" -and
                    -not ($section.channel -eq "Success Stories" -and $_.Name -like "MOCK-*") } | Sort-Object Name)
        if ($hosted.Count -gt 0) {
            $hostedList = ($hosted | ForEach-Object {
                $encoded = ($_.ServerRelativeUrl -split "/" | ForEach-Object { [uri]::EscapeDataString($_) }) -join "/"
                "- [$($_.Name -replace '[\[\]]', '')]($siteOrigin$encoded)"
            }) -join "`n"
        }
        if ($section.channel -eq "Success Stories") {
            $prefix = [uri]::UnescapeDataString(([uri]$SiteUrl).AbsolutePath.TrimEnd('/') + "/" + $channelPath.Trim('/')) + "/"
            foreach ($file in $hosted) {
                $path = [uri]::UnescapeDataString($file.ServerRelativeUrl)
                if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "A success-story video is outside its managed channel folder."
                }
                $encoded = ($file.ServerRelativeUrl -split "/" | ForEach-Object { [uri]::EscapeDataString($_) }) -join "/"
                $storyVideoUrls[$path.Substring($prefix.Length)] = "$siteOrigin$encoded"
            }
        }
    }
    $markdown = if ($hostedList -and $section.channel -ne "Success Stories") {
        $markdown.Replace("{{HostedFiles}}", $hostedList)
    } else { Remove-EmptyHostedFiles $markdown }
    $converted = Convert-GuideMarkdown -Text $markdown
    if (-not $converted.Title) { throw "Section $($section.file) must start with a '# Title' line." }

    $sectionIntro = "<p>$(Convert-MarkdownInline $converted.Summary)</p><p><em>$(Escape-Html $SampleNotice)</em></p>"
    $sectionHtml = $converted.Html
    if ($section.channel -ne "Success Stories") {
        $sectionHtml += "<p><a href='$(Escape-Html $channelFolder.webUrl)'>Open the $(Escape-Html $section.channel) files</a></p>"
    }
    if ($section.page -eq "CoE-Service-Catalog-and-Support") { $sectionHtml += Get-CoESupportRouteHtml $supportRoutes }
    $null = Write-ManagedPage -SiteConnection $site -Name $section.page -Title $converted.Title `
        -Html $sectionHtml -IntroHtml $sectionIntro

    if ((Get-ManagedNavigationUrl $sectionUrl) -notin @($quickLaunch | ForEach-Object { Get-ManagedNavigationUrl $_.Url })) {
        Add-PnPNavigationNode -Location QuickLaunch -Title $converted.Title -Url $sectionUrl -Connection $site | Out-Null
    }
    $tabs = @(Get-PnPTeamsTab -Team $group.GroupId -Channel $channel[0].Id -Connection $Connection)
    if ("Start here" -notin @($tabs | ForEach-Object DisplayName)) {
        Add-TeamsTabWithRetry -Team $group.GroupId -Channel $channel[0].Id -DisplayName "Start here" `
            -TabArgs @{ Type = "SharePointPageAndList"; WebSiteUrl = $sectionUrl } -Connection $Connection | Out-Null
    }
    $sectionResults += @{ Title = $converted.Title; Page = $sectionUrl; Channel = $section.channel
        ChannelId = $channel[0].Id; Files = $channelFolder.webUrl; FilesUploaded = $uploaded; OrgFilesHosted = $orgUploaded; Source = "SeedContent/Sections/$($section.file)" }
}

$report.Sections = @{ SupportEmail = $SupportEmail; Pages = $sectionResults }
if (@($sectionConfig.sections | Where-Object page -eq "CoE-Success-Stories").Count -eq 1) {
    Write-CoEStep "START Success Stories catalog" $SiteUrl
    $storyCatalog = Sync-CoESuccessStoryCatalog -Connection $site -SiteUrl $SiteUrl `
        -Seeds @($sectionConfig.successStories) -ResolvedReviewers $resolvedCatalogReviewers `
        -StoriesFolderUrl ([string]$storiesFolderUrl) -StoryVideoUrls $storyVideoUrls `
        -Audiences @(Get-OrgValue "StoryAudiences" @("Faculty", "Staff", "Student") | ForEach-Object { [string]$_ })
    Add-CoECatalogPageView $site "CoE-Success-Stories" $storyCatalog $storyCatalog.Views.Published "Approved success stories" `
        -IntroText "Stories appear here after the CoE team reviews them. An empty list means none have been approved yet."
    $report.Sections.SuccessStoriesList = $storyCatalog.ReaderViewUrl
    $report.SuccessStories = @{ Added = $storyCatalog.Added; Preserved = $storyCatalog.Preserved; Migrated = $storyCatalog.Migrated
        Diagnostics = $storyCatalog.Diagnostics; PublicationGate = "Native approval only; Retired and mock videos excluded." }
    Write-CoEStep "DONE Success Stories catalog" "added $($storyCatalog.Added), preserved $($storyCatalog.Preserved)"
}
if (@($sectionConfig.sections | Where-Object page -eq "CoE-Training-and-Enablement").Count -eq 1) {
    Write-CoEStep "START Learning Paths catalog" $SiteUrl
    $learningCatalog = Sync-CoELearningCatalog -Connection $site -SiteUrl $SiteUrl -Seeds $learningSeeds -ResolvedReviewers $resolvedCatalogReviewers
    Add-CoECatalogPageView $site "CoE-Training-and-Enablement" $learningCatalog $learningCatalog.Views.Page "Learning paths by role" `
        -IntroText "Choose your role, open Learn, then try Practice. Select a step's name for the full instructions."
    $report.LearningPaths = @{ List = $learningCatalog.ListUrl; Added = $learningCatalog.Added; Preserved = $learningCatalog.Preserved
        Views = @{ Page = $learningCatalog.Views.Page.Id; ByAudience = $learningCatalog.Views.ByAudience.Id; ByPath = $learningCatalog.Views.ByPath.Id; Required = $learningCatalog.Views.Required.Id }
        Source = "SeedContent/Learning-Paths.json"; CompletionTracking = $false
        ReaderViewUrl = $learningCatalog.ReaderViewUrl; Diagnostics = $learningCatalog.Diagnostics }
    foreach ($message in $learningCatalog.Diagnostics.Messages) { Write-Warning $message }
    Write-CoEStep "DONE Learning Paths catalog" "added $($learningCatalog.Added), preserved $($learningCatalog.Preserved)"
}
if (@($sectionConfig.sections | Where-Object page -eq "CoE-Agent-Showcase").Count -eq 1) {
    Write-CoEStep "START Agent Showcase catalog" $SiteUrl
    $agentCatalog = Sync-CoEAgentCatalog -Connection $site -SiteUrl $SiteUrl -AgentSeeds $agentSeeds -ResolvedReviewers $resolvedCatalogReviewers
    Add-CoECatalogPageView $site "CoE-Agent-Showcase" $agentCatalog $agentCatalog.Views.Featured "Featured agents" `
        -IntroText "Agents appear here after the CoE team reviews them; Featured shows the team's picks. An empty list means none have been approved yet."
    Add-CoECatalogPageView $site "CoE-Agent-Showcase" $agentCatalog $agentCatalog.Views.Published "All approved agents" -Order 4
    $report.Sections.AgentShowcaseList = $agentCatalog.ListUrl
    $report.AgentCatalog = @{ List = $agentCatalog.ListUrl; Added = $agentCatalog.Added; Preserved = $agentCatalog.Preserved; Migrated = $agentCatalog.Migrated
        Views = @{ Published = $agentCatalog.Views.Published.Id; Featured = $agentCatalog.Views.Featured.Id; Review = $agentCatalog.Views.Review.Id }
        NewSeedDefault = "Submitted"; ConfigurationIsInsertOnly = $true
        Editing = "Native content approval; existing access preserved; named reviewers have Contribute plus ApproveItems."
        DraftVisibility = "Approvers and authors"; PublicationGate = "Native approval only; Retired excluded."
        ReviewerPermissionLevel = "CoE Catalog Reviewer (site-collection scoped)" }
    Write-CoEStep "DONE Agent Showcase catalog" "added $($agentCatalog.Added), preserved $($agentCatalog.Preserved)"
}
if ($promptLibraryMode -eq "On") {
    Write-CoEStep "START Prompt Library catalog" $SiteUrl
    $promptCatalog = Sync-CoEPromptCatalog -Connection $site -SiteUrl $SiteUrl -Prompts $promptSeeds -ResolvedReviewers $resolvedCatalogReviewers
    Add-CoECatalogPageView $site "Guide-Prompt-Library" $promptCatalog $promptCatalog.Views.Prompts "Organization prompt library" -Order 3 `
        -IntroText ("Prompts published for the $orgName community, grouped by department. Copy a prompt into Copilot and replace each " +
            "{{placeholder}} with your own details. Copilot work prompts use your work email and files and need a Microsoft 365 Copilot license.")
    $report.PromptLibrary = @{ List = $promptCatalog.ListUrl; Added = $promptCatalog.Added; Preserved = $promptCatalog.Preserved
        Files = @($promptSeeds | ForEach-Object Source | Select-Object -Unique); ReaderViewUrl = $promptCatalog.ReaderViewUrl
        PublicationGate = "Prompts from OrgPrompts files are inserted approved; prompts added on the site need CoE approval." }
    Write-CoEStep "DONE Prompt Library catalog" "added $($promptCatalog.Added), preserved $($promptCatalog.Preserved)"
}

$availablePages = @(Get-PnPPage -Connection $site -ErrorAction Stop | ForEach-Object Name)
$omittedNames = @($omittedGuideUrls | ForEach-Object { [uri]::UnescapeDataString(([uri]$_).Segments[-1]) })
$availablePages = @($availablePages | Where-Object { $_ -notin $omittedNames })
$calendarLink = if ($report.Keys -contains "TrainingCalendar") { [string]$report.TrainingCalendar.Url } else { "" }
$hubLinks = @(Get-CoEHubLinks $SiteUrl $availablePages $calendarLink)
if ($RepairCapturedPages) {
    Write-CoEStep "START Home page and hub repair" $SiteUrl
    $report.HubExperience = Repair-CoEHubPages -SiteConnection $site -Links $hubLinks
    Write-CoEStep "DONE Home page and hub repair"
}

# Task-first groups only managed destinations; explicit alphabetical and existing-order choices remain supported.
# SharePoint's "Recent" node links to the site root, so it shows as the current page on Home; the CoE does not use it.
foreach ($recent in @(Get-PnPNavigationNode -Location QuickLaunch -Connection $site | Where-Object Title -eq "Recent")) {
    Remove-PnPNavigationNode -Identity $recent.Id -Force -Connection $site
}
if ($navOrder -eq "TaskFirst") {
    Write-CoEStep "START Task-first navigation" $SiteUrl
    $managedParents = Sync-CoEHubNavigation -Connection $site -Links $hubLinks
    foreach ($node in @(Get-PnPNavigationNode -Location QuickLaunch -Connection $site -ErrorAction Stop)) {
        $url = Get-ManagedNavigationUrl $node.Url
        if ($node.Title -eq "Learning Series" -and $url -in @($SiteUrl.TrimEnd('/'), "$($SiteUrl.TrimEnd('/'))/SitePages/TrainingHome.aspx") -or
            $url -eq "$($SiteUrl.TrimEnd('/'))/SitePages/News-and-Updates.aspx" -or
            ($node.Title -in @("Copilot Training Calendar", "Training calendar") -and
                $url -like "$($SiteUrl.TrimEnd('/'))/Lists/CopilotTrainingCalendar*")) {
            Remove-PnPNavigationNode -Identity $node.Id -Force -Connection $site -ErrorAction Stop
        }
    }
}
if ($navOrder -in @("TaskFirst", "AToZ")) {
    $pinFirst = @(Get-OrgValue "NavigationPinFirst" @("Home") | ForEach-Object { [string]$_ })
    $topNodes = @(Get-PnPNavigationNode -Location QuickLaunch -Connection $site)
    $firstNodes = @(foreach ($title in $pinFirst) { $topNodes | Where-Object Title -eq $title })
    $lastNodes = @(foreach ($title in @("Site contents")) { $topNodes | Where-Object Title -eq $title })
    $pinnedIds = @($firstNodes + $lastNodes | ForEach-Object Id)
    $middle = @($topNodes | Where-Object { $_.Id -notin $pinnedIds })
    if ($navOrder -eq "TaskFirst") {
        $taskIds = @(foreach ($key in @("Start", "Learn", "Prompts", "Agents", "Help", "Governance")) {
            if ($managedParents.ContainsKey($key)) { $managedParents[$key].Id }
        })
        $ordered = @(foreach ($id in $taskIds) { $middle | Where-Object Id -eq $id })
        $middle = @($ordered + @($middle | Where-Object { $_.Id -notin $taskIds }))
    } else { $middle = @($middle | Sort-Object Title) }
    $desiredNodes = @($firstNodes + $middle + $lastNodes)
    if ((@($desiredNodes | ForEach-Object Id) -join ",") -ne (@($topNodes | ForEach-Object Id) -join ",")) {
        for ($i = 1; $i -lt $desiredNodes.Count; $i++) {
            Invoke-PnPSPRestMethod -Method Post -Url "/_api/web/navigation/QuickLaunch/MoveAfter" `
                -Content @{ nodeId = $desiredNodes[$i].Id; previousNodeId = $desiredNodes[$i - 1].Id } -Connection $site | Out-Null
        }
    }
    $report.Navigation = @{ Order = $navOrder; Links = @($desiredNodes | ForEach-Object Title) }
    if ($navOrder -eq "TaskFirst") { Write-CoEStep "DONE Task-first navigation" ($desiredNodes.Count.ToString() + " top-level link(s)") }
}
}

if (-not $GovernanceOnly -and -not $GuidesOnly) {

$askFolder = Get-PnPTeamsChannelFilesFolder -Team $group.GroupId -Channel $askChannel[0].Id -Connection $Connection
$askPath = [uri]::UnescapeDataString(([uri]$askFolder.webUrl).AbsolutePath).Substring(([uri]$SiteUrl).AbsolutePath.Length).TrimStart("/")
$handoutName = "Microsoft365Copilot_Top10toTry_Handout.pptx"
$handoutLocal = Join-Path $kitRoot $handoutName
$top10Decks = @(Confirm-OrgAssets "Top10" "Use this deck for the 'Top 10 to try' tab in Ask Us Anything instead of Microsoft's handout?" |
    Where-Object Extension -eq ".pptx")
if ($top10Decks.Count -gt 1) { throw "Assets\Top10 must contain exactly one .pptx deck; found $($top10Decks.Count)." }
if ($top10Decks.Count -eq 1) {
    $handoutName = $top10Decks[0].Name
    $handoutLocal = $top10Decks[0].FullName
} else {
    # Answering No keeps the organization deck the tab already shows; it does not switch back to Microsoft's handout.
    $orgDeckFolder = if ($OrgPath) { Join-Path $OrgPath "Assets\Top10" } else { $null }
    $currentTop = @(Get-PnPTeamsTab -Team $group.GroupId -Channel $askChannel[0].Id -Connection $Connection |
        Where-Object DisplayName -eq "Top 10 to try")
    if ($orgDeckFolder -and (Test-Path -LiteralPath $orgDeckFolder) -and $currentTop.Count -gt 0) {
        $inPlaceDecks = @(Get-ChildItem -LiteralPath $orgDeckFolder -Filter "*.pptx" -File | Where-Object {
            $candidateUrl = "$($askFolder.webUrl.TrimEnd('/'))/$([uri]::EscapeDataString($_.Name))"
            @($currentTop | Where-Object { Test-TeamsFileTabTarget $_ $candidateUrl "" }).Count -gt 0
        })
        if ($inPlaceDecks.Count -gt 1) { throw "Multiple existing organization Top 10 decks are tabbed. Review them before selecting a replacement." }
        $inPlace = $inPlaceDecks | Select-Object -First 1
        if ($inPlace) {
            $handoutName = $inPlace.Name
            $handoutLocal = $inPlace.FullName
            Write-Host "  Kept the current 'Top 10 to try' deck: $handoutName"
        }
    }
    if ($handoutLocal -and -not (Test-Path -LiteralPath $handoutLocal)) {
        Invoke-WebRequest -Uri "https://adoption.microsoft.com/files/copilot/$handoutName" -OutFile $handoutLocal
    }
}
$existingHandout = @(Get-PnPFolderItem -FolderSiteRelativeUrl $askPath -ItemType File -Connection $site |
    Where-Object Name -eq $handoutName)
if ($existingHandout.Count -gt 0 -and $handoutLocal -and $ReplaceOrgAssets) {
    Add-PnPFile -Path $handoutLocal -Folder $askPath -Connection $site -ErrorAction Stop | Out-Null
} elseif ($existingHandout.Count -gt 0) {
    Write-Host "Kept existing Top 10 file '$handoutName'; use -ReplaceOrgAssets only after reviewing it."
} elseif ($handoutLocal) {
    Add-PnPFile -Path $handoutLocal -Folder $askPath -Connection $site | Out-Null
}
$handoutUrl = "$($askFolder.webUrl.TrimEnd('/'))/$([uri]::EscapeDataString($handoutName))"
$handout = Get-PnPFile -Url ([uri]::UnescapeDataString(([uri]$handoutUrl).AbsolutePath)) -AsFileObject -Connection $site
Get-PnPProperty -ClientObject $handout -Property UniqueId -Connection $site | Out-Null
$knownTopUrls = @("$($askFolder.webUrl.TrimEnd('/'))/Microsoft365Copilot_Top10toTry_Handout.pptx")
$previousTopEntity = ""
if ($previousTopTen) {
    $knownTopUrls += [string]$previousTopTen.FileUrl
    $previousTopEntity = [string]$previousTopTen.SourceDocId
}
$topTab = Sync-TopTenTab -Team $group.GroupId -Channel $askChannel[0].Id -FileUrl $handoutUrl `
    -EntityId $handout.UniqueId.ToString() -KnownFileUrls $knownTopUrls -PreviousEntityId $previousTopEntity `
    -CreateMissing:$EnsureResourceTabs -Connection $Connection
$report.TopTen = @{ FileUrl = $handoutUrl; SourceDocId = $handout.UniqueId; TabId = $(if ($topTab) { $topTab.Id } else { $null }) }
}

if (-not $GuidesOnly) {
$report.Remove("PolicyDraft")
foreach ($kind in @("program", "leadership")) {
    $content = $copy.$kind
    $channelName = if ($kind -eq "program") { "Program Governance" } else { "Leadership Governance" }
    $channel = @($channels | Where-Object DisplayName -eq $channelName)
    if ($channel.Count -ne 1 -or $channel[0].MembershipType -ne "shared") {
        throw "Expected the approved shared channel: $channelName"
    }
    $folder = Get-PnPTeamsChannelFilesFolder -Team $group.GroupId -Channel $channel[0].Id -Connection $Connection
    $folderUri = [uri]$folder.webUrl
    $channelSiteUrl = "$($folderUri.Scheme)://$($folderUri.Host)$($folderUri.AbsolutePath.Substring(0,$folderUri.AbsolutePath.LastIndexOf('/')))"
    if ($channelSiteUrl.TrimEnd("/") -eq $SiteUrl.TrimEnd("/")) {
        throw "Restricted governance files must not be written to the public parent site."
    }
    $sharedSite = Connect-PnPOnline -Url $channelSiteUrl -Connection $Connection -ReturnConnection
    $libraryPath = [uri]::UnescapeDataString($folderUri.AbsolutePath).Substring(([uri]$channelSiteUrl).AbsolutePath.Length).TrimStart("/")
    $html = "<h2>$(Escape-Html $content.title)</h2><p>$(Escape-Html $content.intro)</p>"
    foreach ($groupTitle in $content.groups) {
        $html += "<h3>$(Escape-Html $groupTitle)</h3>"
        foreach ($section in @($content.sections | Where-Object group -eq $groupTitle)) {
            $target = "$libraryPath/$($section.folder)"
            Resolve-PnPFolder -SiteRelativePath $target -Connection $sharedSite | Out-Null
            $docName = ConvertTo-DocxFileName $section.title
            Write-ManagedDocx -SiteConnection $sharedSite -Folder $target -LocalPath (Join-Path $seedRoot $section.file) `
                -FileName $docName -Title $section.title -AuditKey "$kind-$($section.folder)" `
                -LegacyNames @(Split-Path -Leaf $section.file) -RemoveStaleDrafts | Out-Null
            $sectionUrl = Get-CoEWordBrowserUrl -Connection $sharedSite -SiteUrl $channelSiteUrl `
                -FilePath "$target/$docName"
            $html += "<h4>$(New-CoEWordBrowserAnchor -Url $sectionUrl -Label $section.title)</h4><p>$(Escape-Html $section.text)</p>"
            if ($kind -eq "leadership" -and $section.folder -eq "03-Policy-and-Risk-Decisions") {
                $policyName = "Higher-Ed-AI-Governance-Framework-DRAFT.md"
                $policyPath = Join-Path $seedRoot $policyName
                if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
                    throw "The organization-wide AI governance policy draft is missing: $policyPath"
                }
                # An empty organization override (Content\Higher-Ed-AI-Governance-Framework-DRAFT.md) leaves the policy draft out.
                if ([string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($policyPath))) {
                    Write-Warning "Policy draft omitted from this update and report. Existing policy files are preserved; retire them manually only if authorized."
                    continue
                }
                $policyDoc = "Proposed-$orgNoun-wide-AI-Governance-Policy-DRAFT.docx" -replace "[^A-Za-z0-9.-]", "-"
                Write-ManagedDocx -SiteConnection $sharedSite -Folder $target -LocalPath $policyPath `
                    -FileName $policyDoc -Title "Proposed $orgNoun-wide AI Governance Policy (draft)" -AuditKey "$kind-policy" `
                    -LegacyNames @($policyName) | Out-Null
                $policyUrl = Get-CoEWordBrowserUrl -Connection $sharedSite -SiteUrl $channelSiteUrl `
                    -FilePath "$target/$policyDoc"
                $report.PolicyDraft = @{ Url = $policyUrl; Status = "Illustrative draft - not approved $orgName policy"; Location = "$channelName/$($section.folder)" }
            }
        }
    }
    if ($kind -eq "leadership" -and ($report.Keys -contains "PolicyDraft") -and $report["PolicyDraft"]) {
        $html += "<p><strong>Illustrative draft only - not approved $(Escape-Html $orgName) policy.</strong> " +
            "$(New-CoEWordBrowserAnchor -Url $report.PolicyDraft.Url -Label "Open the proposed $orgNoun-wide AI Governance Policy")</p>"
    }
    # Owner-only launch checklist: the setup steps that must never appear on the public CoE pages.
    if ($kind -eq "program" -and $content.PSObject.Properties["ownerChecklist"]) {
        $html += "<h3>$(Escape-Html $content.ownerChecklist.title)</h3><p>$(Escape-Html $content.ownerChecklist.intro)</p><ol>"
        $stagedGuides = Join-Path $stageRoot "SeedContent\Guides"
        foreach ($item in $content.ownerChecklist.items) {
            # Items tied to an optional guide (ifGuide = guide name without prefix) appear only when that guide exists.
            if ($item.PSObject.Properties["ifGuide"] -and $item.ifGuide -and
                -not (Get-ChildItem -LiteralPath $stagedGuides -Filter "*-$($item.ifGuide).md" -File -ErrorAction SilentlyContinue |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($_.FullName)) })) { continue }
            $html +=  "<li><strong>$(Escape-Html $item.where):</strong> $(Escape-Html $item.action)</li>"
        }
        $html += "</ol>"
    }
    Write-ManagedDocx -SiteConnection $sharedSite -Folder $libraryPath `
        -LocalPath (Join-Path $seedRoot "Governance\$kind\START-HERE.txt") -FileName "Start-Here.docx" `
        -Title "$channelName - Start here" -AuditKey "$kind-start" -LegacyNames @("START-HERE.txt") | Out-Null
    $governancePage = Write-ManagedPage -SiteConnection $sharedSite -Name "CoE-Governance-Start-Here" -Title $content.title -Html $html
    $pageUrl = "$channelSiteUrl/SitePages/CoE-Governance-Start-Here.aspx"
    # "Open in SharePoint" from the channel lands on the site's home page; make that the Start here page.
    if ([string](Get-PnPHomePage -Connection $sharedSite) -ne "SitePages/CoE-Governance-Start-Here.aspx") {
        Set-PnPHomePage -RootFolderRelativeUrl "SitePages/CoE-Governance-Start-Here.aspx" -Connection $sharedSite
    }
    $existingTabs = @(Get-PnPTeamsTab -Team $group.GroupId -Channel $channel[0].Id -Connection $Connection)
    if ("Start here" -notin @($existingTabs | ForEach-Object DisplayName)) {
        Add-TeamsTabWithRetry -Team $group.GroupId -Channel $channel[0].Id -DisplayName "Start here" `
            -TabArgs @{ Type = "SharePointPageAndList"; WebSiteUrl = $pageUrl } -Connection $Connection | Out-Null
    }
    $securityEntry = @($governanceSecurity | Where-Object Channel -eq $channelName) | Select-Object -First 1
    if (-not $securityEntry) { throw "The security preflight did not validate '$channelName'." }
    $report.Governance += @{
        Channel = $channelName
        ChannelId = $channel[0].Id
        Site = $channelSiteUrl
        Page = $pageUrl
        Library = $folder.webUrl
        Sections = $content.sections.Count
        Members = @($securityEntry.Members | Select-Object userId,tenantId,Email,displayName,Roles)
    }
}

}

$report.TeamId = $group.GroupId
$report.Channels = @($channels | Select-Object Id,DisplayName,MembershipType)
$general = @($channels | Where-Object DisplayName -eq "General")[0]
$report.TeamUrl = "https://teams.microsoft.com/l/team/$([uri]::EscapeDataString($general.Id))/conversations?groupId=$($group.GroupId)"
Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-CoESecurityPosture -SiteUrl $SiteUrl -TeamId $group.GroupId -ExpectedVisibility $teamVisibility `
    -CoESiteSharingCapability $coeSiteSharingCapability -SettingsPath $SettingsPath `
    -OrganizationEmailDomains $organizationEmailDomains `
    -OwnerUPN ([string](Get-OrgValue "SharedChannelOwnerUPN" "")) `
    -AdditionalAllowedMembers $governanceAdditionalAllowedMembers -Connection $Connection
$report.SecurityChecks = @{ Passed = $true; VerifiedAt = [datetime]::UtcNow.ToString("o") }
$report | ConvertTo-Json -Depth 15 | Set-Content $reportPath -Encoding utf8
Write-Host "Content completion and security configuration checks passed. Browser acceptance checks are still required; this script does not claim Teams rendering."
