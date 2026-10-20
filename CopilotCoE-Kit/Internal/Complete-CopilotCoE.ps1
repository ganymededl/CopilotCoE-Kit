[CmdletBinding(SupportsShouldProcess)]
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
    [ValidateSet("Customer", "Demo")][string]$ContentMode = "Customer",
    [ValidateSet("Interactive", "DeviceLogin")][string]$AuthenticationMode = "DeviceLogin",
    [switch]$ForceAuthentication,
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
. (Join-Path $PSScriptRoot "OperatorAdvisories.ps1")
. (Join-Path $PSScriptRoot "TargetResolution.ps1")
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
# Captured BEFORE ContentMode potentially blanks $SampleNotice below, specifically so the guide/experience
# duplicate-notice guards further down can still compare a page's own body against the notice an org actually
# configured - not against "" (which is always falsy and would never detect anything). This was a real bug:
# the guard's own purpose is to catch hardcoded disclaimer text that would ship VERBATIM to a Customer
# install, which is exactly the one mode where $SampleNotice itself is empty and the un-captured check could
# never fire.
$configuredSampleNotice = $SampleNotice
# ContentMode is the single switch deciding demo vs. customer behavior (disclaimer, sample seeding, and
# cleanup of previously-seeded samples) - see START-HERE.txt. Keeping it one switch instead of several
# independent flags means the disclaimer, the seeded sample rows, and any stale-sample cleanup can never
# drift out of sync with each other. Customer is the default: a forgotten flag must fail safe toward no
# demo content, not toward accidentally shipping sample rows and a disclaimer to a real customer.
if ($ContentMode -eq "Customer") {
    if ($SampleNotice) {
        Write-Warning "ContentMode is Customer; ignoring the configured SampleNotice so no demo disclaimer is shown."
    }
    $SampleNotice = ""
} elseif (-not $SampleNotice) {
    throw "ContentMode Demo requires a non-empty SampleNotice (set it in Deployment-Settings.json or pass " +
        "-SampleNotice) so every demo page clearly shows the disclaimer."
}
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
if (@(Get-OrgValue "HomeTiles" @()).Count) {
    throw "HomeTiles belongs to the old Home layout. Remove it before publishing the 3.7 Home."
}
$learningEnvironment = Get-CoELearningEnvironment -Settings $orgSettings
$developerSetting = Get-OrgValue "EnableDeveloperTrack" $false
if ($developerSetting -isnot [bool]) { throw "EnableDeveloperTrack must be true or false." }
$developerEnabled = [bool]$developerSetting
$advisorySettingsPath = if ($SettingsPath) { $SettingsPath } else { Join-Path $kitRoot "Deployment-Settings.json" }
$advisoryContext = New-CoEAdvisoryContext -SettingsPath $advisorySettingsPath -Tenant $Tenant `
    -SiteFQDN ([uri]$SiteUrl).Host -TeamAlias $TeamAlias
Invoke-CoEConfigurationAdvisories -Context $advisoryContext -Settings $orgSettings `
    -SupportEmail $SupportEmail -DisplayName $DisplayName -SampleNotice $SampleNotice -ContentMode $ContentMode `
    -AllowMissingDataSafetyIncidentRoute:$AllowMissingDataSafetyIncidentRoute
foreach ($route in $supportRoutes | Where-Object { -not $_.Configured }) {
    Write-Warning "Links.$($route.Key) is not configured. Pages will show a setup warning, not a working organizational endpoint."
}
# TimeZone: a Windows time zone ID (Get-TimeZone -ListAvailable), applied to the site's regional settings.
$timeZoneId = [string](Get-OrgValue "TimeZone" "Eastern Standard Time")
try { $siteTimeZone = [TimeZoneInfo]::FindSystemTimeZoneById($timeZoneId) }
catch { throw "TimeZone '$timeZoneId' is not a Windows time zone ID. Use a value from Get-TimeZone -ListAvailable, for example 'Eastern Standard Time'." }
function Set-SiteTimeZone([object]$SiteConnection) {
    $regional = (Get-PnPWeb -Connection $SiteConnection).RegionalSettings
    Get-PnPProperty -ClientObject $regional -Property TimeZones, TimeZone -Connection $SiteConnection | Out-Null
    $match = Find-CoESharePointTimeZone -TimeZone $siteTimeZone -Candidates @($regional.TimeZones) `
        -EnglishName (Get-CoEEnglishTimeZoneName $siteTimeZone.Id)
    if (-not $match) {
        Write-Warning ("No SharePoint time zone matches '$($siteTimeZone.DisplayName)' ($timeZoneId); SharePoint lists zone names in the site's language. " +
            "The site time zone was NOT changed. Set it to the zone for '$timeZoneId' in Site settings > Regional settings before relying on the training calendar.")
        return
    }
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

# Stage the base content, the selected environment pack, then organization-specific overrides.
$stageRoot = Join-Path ([IO.Path]::GetTempPath()) "CopilotCoE-Stage-$runId"
[void][IO.Directory]::CreateDirectory($stageRoot)
Copy-Item -LiteralPath (Join-Path $kitRoot "SeedContent") -Destination $stageRoot -Recurse
foreach ($name in @("CoE-Revision-Content.json", "ResourceLinks.json")) {
    Copy-Item -LiteralPath (Join-Path $kitRoot $name) -Destination $stageRoot
}
$kitSeedRoot = Join-Path $kitRoot "SeedContent"
if ($learningEnvironment -eq "Government") {
    $governmentContent = Join-Path $kitRoot "ContentPacks\Government-StateLocal\Content"
    if (-not (Test-Path -LiteralPath $governmentContent -PathType Container)) {
        throw "Government content pack is missing: $governmentContent"
    }
    $null = @(Copy-CoEContentOverlay $governmentContent $stageRoot $kitSeedRoot)
    Write-Host "Using the 3.7 government content pack."
}
$orgOverrides = @()
if ($OrgPath -and (Test-Path -LiteralPath (Join-Path $OrgPath "Content") -PathType Container)) {
    $contentRoot = Join-Path $OrgPath "Content"
    $orgOverrides = @(Copy-CoEContentOverlay $contentRoot $stageRoot $kitSeedRoot)
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
        # Customer mode must never host a file whose own name flags it as demo/sample content - a live review
        # found files named Contoso-Agent-Proposals-DEMO-ONLY.txt and Contoso-Demo-Practice-Handout.txt sitting in a validation
        # org folder's Assets, which -AcceptOrgAssets would otherwise have uploaded to a real customer site
        # as-is. Test-CoEInstall.ps1's own "DEMO ONLY" Customer-mode check only scans rendered PAGE TEXT, never
        # uploaded file names, so this is the one place that actually has to catch it, before the question is
        # even asked - an operator typing "Y" at the prompt should not be the only thing standing between a
        # leftover validation file and the customer's live site.
        if ($ContentMode -eq "Customer") {
            $flagged = @($files | Where-Object { $_.Name -match '(?i)\b(DEMO|SAMPLE)\b' })
            if ($flagged.Count -gt 0) {
                foreach ($f in $flagged) {
                    Write-Warning "Customer mode: '$($f.Name)' in Assets\$Category looks like demo/sample content (its name contains DEMO or SAMPLE) and was not offered for upload. Remove or rename it if it is real organization content."
                }
                $files = @($files | Where-Object { $_ -notin $flagged })
            }
        }
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
$toolsCatalog = Get-Content -LiteralPath (Join-Path $seedRoot "Experience\Tools.json") -Raw | ConvertFrom-Json
$guidedCatalog = Get-Content -LiteralPath (Join-Path $seedRoot "Experience\Guided-Learning.json") -Raw | ConvertFrom-Json
# The generic kit ships exactly nine tools and seven learning tracks. An org-level content overlay
# (Copy-CoEContentOverlay, already applied above) may fully replace this file to ADD org-specific
# tracks on top of that baseline (for example dedicated healthcare role tracks) - so this is a floor,
# not an exact match. It still catches accidental deletion/corruption of the generic catalog.
if (@($toolsCatalog.tools).Count -lt 9 -or @($guidedCatalog.tracks).Count -lt 7) {
    throw "CoE experience catalog must contain at least nine tools and seven learning tracks."
}
foreach ($catalog in @($toolsCatalog, $guidedCatalog)) {
    $reviewDate = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$catalog.reviewedOn, "yyyy-MM-dd",
        [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$reviewDate) -or
        $reviewDate.Date -gt [datetime]::UtcNow.Date) {
        throw "Experience catalog reviewedOn must be an actual non-future yyyy-MM-dd review date."
    }
}
foreach ($tool in $toolsCatalog.tools) {
    if ($tool.page -notmatch '^Tool-[A-Za-z0-9-]+$') { throw "Invalid tool page name: $($tool.page)" }
    foreach ($key in @("openUrl", "learnUrl", "governmentUrl", "governmentLearnUrl")) {
        $value = [string](Get-CoECatalogValue $tool $key)
        if ($value) { $null = Resolve-CoECatalogUrl $value "Tools.$($tool.title).$key" }
    }
}
$plannedPages = @("TrainingHome.aspx", "Technical Readiness.aspx", "Copilot-on-Microsoft-Mechanics.aspx",
    "Adoption-Best-Practices.aspx", "Meet-your-ProjectTeam.aspx", "Meet-your-Champions.aspx",
    "Copilot-Guides.aspx", "Copilot-FAQs.aspx", "CoE-Service-Catalog-and-Support.aspx",
    "Which-Copilot-Should-I-Use.aspx", "Compare-Copilot-Tools.aspx", "Guided-Learning.aspx",
    "Learning-Series.aspx", "Agent-Lifecycle-and-Approval.aspx", "Where-Agents-Are-Built.aspx",
    "Data-Protection.aspx") +
    @($toolsCatalog.tools | Where-Object { $developerEnabled -or -not (Get-CoECatalogValue $_ "optional") } |
        ForEach-Object { "$($_.page).aspx" }) +
    @(Get-CoEVisibleLearningTracks $guidedCatalog $learningEnvironment $developerEnabled |
        ForEach-Object { "$($_.page).aspx" }) +
    @($sectionConfig.sections | ForEach-Object { "$($_.page).aspx" }) +
    @(Get-ChildItem -LiteralPath (Join-Path $seedRoot "Guides") -Filter "*.md" -File |
        Where-Object { -not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($_.FullName)) } |
        ForEach-Object { "Guide-" + ($_.BaseName -replace '^\d+[a-z]?-', '') + ".aspx" })
$incidentLink = Get-CoEIncidentRouteUrl $supportRoutes
$calendarPageUrl = "$($SiteUrl.TrimEnd('/'))/Lists/CopilotTrainingCalendar/Calendar.aspx"
$script:hubLinks = @(Get-CoEHubLinks $SiteUrl $plannedPages $calendarPageUrl $incidentLink $developerEnabled)
$null = Get-CoEGuidedLearningHtml $guidedCatalog $SiteUrl $learningEnvironment $developerEnabled $plannedPages
$guidedLandingPage = Get-CoEGuidedLandingHtml $guidedCatalog $SiteUrl $learningEnvironment $developerEnabled
$comparisonHtml = Get-CoEToolComparisonHtml $toolsCatalog.tools $SiteUrl $developerEnabled $learningEnvironment
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
    Write-Host (Get-CoESignInHint $AuthenticationMode)
    $signInArguments = Get-CoESignInArguments -Url $AdminUrl -ClientId ([string]$ClientId) -Tenant $Tenant `
        -AuthenticationMode $AuthenticationMode -ForceAuthentication:$ForceAuthentication
    $Connection = Connect-PnPOnline @signInArguments
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
    -OrganizationEmailDomains $organizationEmailDomains -AdvisoryContext $advisoryContext -Connection $Connection)
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

function Add-CoEUpcomingSessionsWebPart($SiteConnection, [string]$PageName, $Calendar, $View,
    [int]$Order = 4, [int]$Section = 0, [int]$Column = 0) {
    $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
    $bound = @($page.Controls | Where-Object { $_.PSObject.Properties["PropertiesJson"] -and
        ([string]$_.PropertiesJson) -match [regex]::Escape($Calendar.Id.ToString()) -and
        ([string]$_.PropertiesJson) -match [regex]::Escape($View.Id.ToString()) })
    if ($bound.Count -gt 1) { throw "$PageName has duplicate upcoming-session web parts." }
    if (-not $bound.Count) {
        $addArgs = @{ Page = $page; DefaultWebPartType = "List"; Order = $Order
            Connection = $SiteConnection; ErrorAction = "Stop"
            WebPartProperties = @{
                selectedListId = $Calendar.Id.ToString()
                selectedListUrl = "$(([uri]$SiteUrl).AbsolutePath.TrimEnd('/'))/Lists/CopilotTrainingCalendar"
                selectedViewId = $View.Id.ToString()
                hideCommandBar = $true; isDocumentLibrary = $false; hideTitle = $false; showTitle = $true
            } }
        # On TrainingHome specifically, land this in Section 2/Column 1 - the exact column the vendor's own
        # Events web part occupied before Repair-CoEHubPages removes it (see that function's own comment).
        # Without an explicit target, Add-PnPPageWebPart appends to whatever section/column it picks by
        # default, which left that column empty on a live install while the calendar rendered somewhere else
        # entirely - confirmed against the vendor template's TwoColumn Section 2 (Events in Column 1, the
        # "Resources"/Copilot tools Quick Links in Column 2).
        if ($Section -gt 0) { $addArgs.Section = $Section }
        if ($Column -gt 0) { $addArgs.Column = $Column }
        Add-PnPPageWebPart @addArgs | Out-Null
        Set-PnPPage -Identity $PageName -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
    }
    $saved = @(Get-PnPPageComponent -Page "$PageName.aspx" -Connection $SiteConnection |
        Where-Object { $_.PSObject.Properties["PropertiesJson"] -and
            ([string]$_.PropertiesJson) -match [regex]::Escape($Calendar.Id.ToString()) -and
            ([string]$_.PropertiesJson) -match [regex]::Escape($View.Id.ToString()) })
    if ($saved.Count -ne 1) { throw "$PageName is not bound to the upcoming sessions view." }
}

# Removes the upcoming-sessions List web part from a page if present - the Customer-mode counterpart to
# Add-CoEUpcomingSessionsWebPart. SharePoint's modern List web part reserves blank vertical space up to its
# configured row count regardless of how many rows actually match the view's filter (confirmed live: with
# only 2 of 3 possible rows matching, the web part still reserved space well past both rows before the
# "See full list" link) - with zero real sessions yet (the common state right after a true customer install),
# that would read as a broken or empty-looking Home page rather than a working one. A no-op if already absent.
function Remove-CoEUpcomingSessionsWebPart($SiteConnection, [string]$PageName, $Calendar, $View) {
    $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
    $bound = @($page.Controls | Where-Object { $_.PSObject.Properties["PropertiesJson"] -and
        ([string]$_.PropertiesJson) -match [regex]::Escape($Calendar.Id.ToString()) -and
        ([string]$_.PropertiesJson) -match [regex]::Escape($View.Id.ToString()) })
    if (-not $bound.Count) { return }
    foreach ($control in $bound) {
        $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
        Remove-PnPPageComponent -Page $page -InstanceId $control.InstanceId -Force -Connection $SiteConnection -ErrorAction Stop | Out-Null
    }
    Set-PnPPage -Identity $PageName -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
}

# Adds a short "Upcoming sessions / No sessions scheduled yet" heading in Customer mode's Section 2/Column 1 -
# the column the live List web part would otherwise occupy (see Remove-CoEUpcomingSessionsWebPart). Without
# this, that column held only the bare "See the full training calendar" link next to the full Copilot tools
# grid, which a live reviewer flagged as a half-empty-looking section with no context for what the link even
# is - START-HERE.txt also still claimed Home "always" has a live upcoming-sessions view, which was no longer
# true for Customer mode. Idempotent and relocatable on the same fixed-text-match pattern as
# Add-CoECalendarLinkTextPart.
function Add-CoENoSessionsPlaceholder($SiteConnection, [string]$PageName, [int]$Order, [int]$Section, [int]$Column) {
    $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
    $marker = "No sessions scheduled yet"
    $existing = @($page.Controls | Where-Object { $_.PSObject.Properties["Text"] -and
        ([string]$_.Text) -match [regex]::Escape($marker) })
    if ($existing.Count) {
        $keeperId = $existing[0].InstanceId
        foreach ($extra in @($existing | Where-Object InstanceId -ne $keeperId)) {
            $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
            Remove-PnPPageComponent -Page $page -InstanceId $extra.InstanceId -Force -Connection $SiteConnection -ErrorAction Stop | Out-Null
        }
        if ($existing.Count -gt 1) {
            Set-PnPPage -Identity $PageName -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
        }
        $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
        $actualSection = $null
        $actualColumn = $null
        for ($s = 0; $s -lt $page.Sections.Count; $s++) {
            for ($c = 0; $c -lt $page.Sections[$s].Columns.Count; $c++) {
                if (@($page.Sections[$s].Columns[$c].Controls | Where-Object InstanceId -eq $keeperId).Count) {
                    $actualSection = $s + 1
                    $actualColumn = $c + 1
                }
            }
        }
        if ($actualSection -ne $Section -or $actualColumn -ne $Column) {
            Remove-PnPPageComponent -Page $page -InstanceId $keeperId -Force -Connection $SiteConnection -ErrorAction Stop | Out-Null
            Set-PnPPage -Identity $PageName -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
            $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
        } else {
            return
        }
    }
    $text = "<h3>Upcoming sessions</h3><p>$marker. Check the full calendar for updates.</p>"
    Add-PnPPageTextPart -Page $page -Text $text -Section $Section -Column $Column -Order $Order `
        -Connection $SiteConnection -ErrorAction Stop | Out-Null
    Set-PnPPage -Identity $PageName -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
}

# Demo-mode counterpart: removes the Customer-mode placeholder if a site is ever repaired from Customer into
# Demo mode, so the heading never sits above the real live calendar web part it was built to stand in for.
function Remove-CoENoSessionsPlaceholder($SiteConnection, [string]$PageName) {
    $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
    $marker = "No sessions scheduled yet"
    $existing = @($page.Controls | Where-Object { $_.PSObject.Properties["Text"] -and
        ([string]$_.Text) -match [regex]::Escape($marker) })
    if (-not $existing.Count) { return }
    foreach ($control in $existing) {
        $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
        Remove-PnPPageComponent -Page $page -InstanceId $control.InstanceId -Force -Connection $SiteConnection -ErrorAction Stop | Out-Null
    }
    Set-PnPPage -Identity $PageName -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
}

# Adds a one-line "See the full training calendar" link directly under the upcoming-sessions web part, so the
# link sits next to the content it describes instead of being stranded elsewhere on the page. Idempotent: a
# text control whose link already points at the calendar page is left alone on a repeat call.
function Add-CoECalendarLinkTextPart($SiteConnection, [string]$PageName, [string]$CalendarUrl,
    [int]$Order, [int]$Section, [int]$Column) {
    $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
    # Match on the fixed link text, not the href: SharePoint relativizes a same-site absolute href on save
    # (confirmed earlier for breadcrumbs - see ConvertTo-CoEStableBreadcrumbText), so a literal match against
    # the originally-submitted absolute $CalendarUrl never finds the control once it has actually been saved,
    # and every rerun adds another copy. Confirmed live: three duplicates had already accumulated before this
    # fix, one per update run today.
    $marker = "See the full training calendar"
    $existing = @($page.Controls | Where-Object { $_.PSObject.Properties["Text"] -and
        ([string]$_.Text) -match [regex]::Escape($marker) })
    if ($existing.Count) {
        $keeperId = $existing[0].InstanceId
        foreach ($extra in @($existing | Where-Object InstanceId -ne $keeperId)) {
            $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
            Remove-PnPPageComponent -Page $page -InstanceId $extra.InstanceId -Force -Connection $SiteConnection -ErrorAction Stop | Out-Null
        }
        if ($existing.Count -gt 1) {
            Set-PnPPage -Identity $PageName -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
        }
        # Matching by text (not location) means a control added under OLDER code - before this Section/Column
        # targeting existed, or under a different targeting bug - is "found" and kept in place forever, never
        # moved just because this function's own target changed later. Confirmed live: the Home-welcome-text
        # fix hit the identical failure mode. Any site updated from 3.8.5 or earlier needs this relocation to
        # actually pick up the current layout, not just a fresh install.
        $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
        $actualSection = $null
        $actualColumn = $null
        for ($s = 0; $s -lt $page.Sections.Count; $s++) {
            for ($c = 0; $c -lt $page.Sections[$s].Columns.Count; $c++) {
                if (@($page.Sections[$s].Columns[$c].Controls | Where-Object InstanceId -eq $keeperId).Count) {
                    $actualSection = $s + 1
                    $actualColumn = $c + 1
                }
            }
        }
        if ($actualSection -ne $Section -or $actualColumn -ne $Column) {
            Remove-PnPPageComponent -Page $page -InstanceId $keeperId -Force -Connection $SiteConnection -ErrorAction Stop | Out-Null
            Set-PnPPage -Identity $PageName -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
            # Cheap insurance, not strictly required: re-fetch rather than reuse the pre-removal $page object
            # for the Add-PnPPageTextPart call below, so that call never depends on a client-side page object
            # staying accurate after a server-side mutation it didn't itself make.
            $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
        } else {
            return
        }
    }
    $text = "<p><a href=`"$(Escape-Html $CalendarUrl)`">$marker</a></p>"
    Add-PnPPageTextPart -Page $page -Text $text -Section $Section -Column $Column -Order $Order `
        -Connection $SiteConnection -ErrorAction Stop | Out-Null
    Set-PnPPage -Identity $PageName -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
}


# a Text web part always renders as a plain underlined link, because the modern Text web part strips custom
# CSS classes on save. A single- or multi-item Quick Links web part in Button layout is the automatable way to
# get real buttons; "description" is the field shown, so the label is under direct control rather than
# depending on SharePoint's own (unreliable, for an external product URL) title resolution. Idempotency is
# keyed on the first item's URL: safe to call again on an already-repaired page without creating duplicates.
# Items with a Description (for example a course count subtitle) get "Title - Description" as the one visible
# line of text; buttonLayoutOptions.linesOfText below lets a longer combined label wrap onto a second line.
function Add-CoEQuickLinksButtons($SiteConnection, [string]$PageName, [string]$Label, [object[]]$Items,
    [int]$Order, [int]$Section = 0, [int]$Column = 0) {
    $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
    $bound = @($page.Controls | Where-Object { $_.PSObject.Properties["PropertiesJson"] -and
        ([string]$_.PropertiesJson) -match [regex]::Escape($Items[0].Url) })
    if ($bound.Count -gt 1) { throw "$PageName has duplicate '$Label' Quick Links tiles." }
    if (-not $bound.Count) {
        $payloadItems = @()
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $text = if ($Items[$i].PSObject.Properties["Description"] -and $Items[$i].Description) {
                "$($Items[$i].Title) - $($Items[$i].Description)"
            } else { $Items[$i].Title }
            $payloadItems += @{ id = $i + 1; description = $text; altText = $text; thumbnailType = 2
                fabricReactIcon = @{ iconName = $Items[$i].Icon }
                sourceItem = @{ url = $Items[$i].Url; itemType = 2; fileExtension = ""; progId = "" } }
        }
        $addArgs = @{ Page = $page; DefaultWebPartType = "QuickLinks"; Order = $Order
            Connection = $SiteConnection; ErrorAction = "Stop"
            WebPartProperties = @{ layoutId = "Button"
                buttonLayoutOptions = @{ showDescription = $true; buttonTreatment = 3; iconPositionType = 2
                    textAlignmentVertical = 2; textAlignmentHorizontal = 2; linesOfText = 2 }
                items = $payloadItems } }
        if ($Section -gt 0) { $addArgs.Section = $Section }
        if ($Column -gt 0) { $addArgs.Column = $Column }
        Add-PnPPageWebPart @addArgs | Out-Null
        Set-PnPPage -Identity $PageName -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
    }
    $saved = @(Get-PnPPageComponent -Page "$PageName.aspx" -Connection $SiteConnection |
        Where-Object { $_.PSObject.Properties["PropertiesJson"] -and ([string]$_.PropertiesJson) -match [regex]::Escape($Items[0].Url) })
    if ($saved.Count -ne 1) { throw "$PageName is not showing the '$Label' Quick Links tiles." }
    foreach ($item in $Items) {
        $data = [Net.WebUtility]::HtmlDecode([string]$saved[0].PropertiesJson) | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not ($data -and @($data.items | Where-Object { $_.sourceItem.url -eq $item.Url }).Count)) {
            throw "$PageName's '$Label' Quick Links tiles are missing the entry for '$($item.Title)'."
        }
    }
}

# Removes the vendor's placeholder web part identified by its generic type Title (for example "Image"), so a
# real Quick Links control can take its place in the same section. A no-op if already removed on a retry.
function Remove-CoEPlaceholderWebPart($SiteConnection, [string]$PageName, [string]$Title) {
    $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
    foreach ($control in @($page.Controls | Where-Object { $_.PSObject.Properties["Title"] -and $_.Title -eq $Title })) {
        Remove-PnPPageComponent -Page $page -InstanceId $control.InstanceId -Force -Connection $SiteConnection -ErrorAction Stop | Out-Null
    }
}

# Home's neutral (no-background) section ships from the vendor template with a generic "Meet your Copilot
# champions" placeholder text block that is never organization-specific - no sample notice, no welcome copy -
# and it sits in the last section of the page, below the Hero, Training Calendar, Copilot tools and Explore
# the CoE tiles, where visitors are unlikely to see it. Called only from Repair-CoEHubPages, itself gated
# behind -RepairCapturedPages (a fresh, non-resumed install always passes it; 03_Update-CoEContent.ps1 only
# passes it through when explicitly requested) - never on an ordinary content-update rerun. START-HERE.txt
# already documents -RepairCapturedPages as deliberately rebuilding Home's controls, so this function is
# allowed to overwrite an already-created welcome block's content the same way the rest of Repair-CoEHubPages
# unconditionally rebuilds the Copilot tools and Explore the CoE controls every time -RepairCapturedPages
# runs; it must still be idempotent within that scope (two -RepairCapturedPages runs back to back must
# change nothing on Home the second time, and must never leave more than one welcome block behind).
function Set-CoEHomeWelcomeText($SiteConnection, [string]$PageName, [string]$SiteUrl, [string]$OrgName,
    [string]$OrgNoun, [string]$SampleNotice) {
    $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
    $vendorMarker = "Champions help colleagues get the most from Copilot and Microsoft 365"
    # Narrowed to require BOTH the heading text AND this block's own champions link, not the heading text
    # alone - a bare "...Copilot Center of Excellence</h2>" match could also hit an unrelated heading a
    # customer happened to write elsewhere on the page; requiring both together is specific enough that an
    # unrelated customer control is very unlikely to match by coincidence.
    $ownHeadingMarker = "Copilot Center of Excellence</h2>"
    $ownLinkMarker = "Meet-your-Champions.aspx"
    # Named $matchedControls, not $matches: $matches is PowerShell's own automatic variable, overwritten by
    # every -match operator call (including the ones used below to decide which matched control is already
    # current) - using that name here previously corrupted this exact list mid-function, with no offline
    # test catching it because the corruption only showed up once real multi-step control logic ran.
    $matchedControls = @($page.Controls | Where-Object { $_.PSObject.Properties["Text"] -and
        ([string]$_.Text -match [regex]::Escape($vendorMarker) -or
            ([string]$_.Text -match [regex]::Escape($ownHeadingMarker) -and [string]$_.Text -match [regex]::Escape($ownLinkMarker))) })
    # Deliberately does NOT return early when nothing matches: a fresh install always has the vendor's own
    # placeholder to match against, but a site that already had both the vendor placeholder AND an earlier
    # replacement manually removed (confirmed live: a one-time cleanup of a misplaced duplicate left exactly
    # this state) has zero matches - and must still end up with exactly one correct welcome block, the same
    # as every other case below, not silently none at all.
    $noticeHtml = if ($SampleNotice) { "<p><em>$(Escape-Html $SampleNotice)</em></p>" } else { "" }
    $championsUrl = "$($SiteUrl.TrimEnd('/'))/SitePages/Meet-your-Champions.aspx"
    $welcomeHtml = "<h2>Welcome to the $(Escape-Html $OrgName) Copilot Center of Excellence</h2>" +
        $noticeHtml +
        "<p>This site is your $(Escape-Html $OrgNoun)'s hub for adopting Microsoft Copilot responsibly: training, tools, governance and support in one place.</p>" +
        "<p><a href='$championsUrl'>Meet your department champions</a> for peer-to-peer help in your department.</p>"
    # HTML-decode before comparing: SharePoint's stored Text can come back with characters like the
    # apostrophe entity-encoded (for example &#39;), which would never match a literal straight apostrophe -
    # comparing against plain (non-HTML-escaped) $OrgNoun/$SampleNotice after decoding avoids depending on
    # guessing which exact entity SharePoint happens to pick.
    $current = @($matchedControls | Where-Object {
        $decoded = [Net.WebUtility]::HtmlDecode([string]$_.Text)
        $decoded -match [regex]::Escape("This site is your $OrgNoun" + "'s hub") -and
            (-not $SampleNotice -or $decoded -match [regex]::Escape($SampleNotice))
    })
    # Keep exactly one control: an existing current one if there is one, otherwise a freshly added one. Every
    # OTHER matched control (the vendor's original text, an older pre-upgrade block, or a leftover duplicate
    # from a previously interrupted run) is removed below. Collecting every match up front - instead of
    # taking only the first one found - means a site left with two matching controls by an earlier failed
    # run is cleaned back up to exactly one on this run, instead of staying that way forever.
    if ($current.Count -ge 1) {
        $keeperId = $current[0].InstanceId
    } else {
        $priorIds = @($matchedControls | ForEach-Object InstanceId)
        # Lands in the vendor's own Section 4/Column 2 - the exact slot the original "Meet Your Copilot
        # Champions" placeholder text occupied (per the .pnp template: Section 4 is TwoColumnRight, Column 1
        # the stock photo Repair-CoEHubPages replaces with a "Meet a Champion" Quick Links button, Column 2
        # this text). Not Section 1/Column 1 - confirmed live that an earlier hardcoded target there is why
        # Section 4's second column sat completely empty instead of holding this replacement text.
        Add-PnPPageTextPart -Page "$PageName.aspx" -Text $welcomeHtml -Section 4 -Column 2 -Order 2 -Connection $SiteConnection -ErrorAction Stop | Out-Null
        Set-PnPPage -Identity "$PageName.aspx" -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
        # Reload before identifying the new control (and again before each removal below): Remove-
        # PnPPageComponent saves whatever canvas state its -Page object currently holds, so passing the
        # object loaded at the very top of this function - from before the add above - would silently drop
        # the control just added, because that stale snapshot never knew it existed. Every use of $page from
        # this point on is a fresh reload, taken immediately before the call that consumes it.
        # Retry the reload a few times before concluding the add genuinely failed: ordinary SharePoint Online
        # publish/index propagation lag can make an immediate Get-PnPPage still return the pre-publish version
        # of the page, not a logic error - confirmed live after several back-to-back page edits within the
        # same run (Repair-CoEHubPages performs this welcome-text add plus the Hero, Quick Links and Explore
        # tile edits earlier, then up to four more page saves for breadcrumbs - see Set-CoESectionStripPart).
        $added = $null
        for ($attempt = 1; $attempt -le 5 -and -not $added; $attempt++) {
            if ($attempt -gt 1) { Start-Sleep -Seconds 2 }
            $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
            $added = @($page.Controls | Where-Object { $_.PSObject.Properties["Text"] -and
                [string]$_.Text -match [regex]::Escape($ownHeadingMarker) -and [string]$_.Text -match [regex]::Escape($ownLinkMarker) -and
                $_.InstanceId -notin $priorIds }) | Select-Object -First 1
        }
        if (-not $added) { throw "Home's new welcome block was not found after being added." }
        $keeperId = $added.InstanceId
    }
    foreach ($old in @($matchedControls | Where-Object { $_.InstanceId -ne $keeperId })) {
        $page = Get-PnPPage -Identity "$PageName.aspx" -Connection $SiteConnection -ErrorAction Stop
        Remove-PnPPageComponent -Page $page -InstanceId $old.InstanceId -Force -Connection $SiteConnection -ErrorAction Stop | Out-Null
        Set-PnPPage -Identity "$PageName.aspx" -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
    }
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
            Write-Host "Preserved existing page $Name. Review it; 03_Update-CoEContent.ps1 replaces managed pages and saves a before-copy in RevisionAudit."
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
    if ([object]::ReferenceEquals($SiteConnection, $site)) {
        $strip = Get-CoESectionStripHtml $script:hubLinks "$Name.aspx"
        if (-not $strip) {
            $strip = "<p><a href='$($SiteUrl.TrimEnd('/'))/SitePages/TrainingHome.aspx'>Home</a></p>"
        }
        $Html = $strip + $Html
        # Scoped to Tool-* and Compare-Copilot-Tools only: these are the only pages whose content (tool
        # access/licensing facts) genuinely goes stale and needs a "confirm current state" caveat. Every
        # other page (Guided-Learning and its tracks, Data-Protection, Agent-Lifecycle, etc.) previously
        # carried the identical sentence too, reading as boilerplate repeated on nearly every page instead of
        # a meaningful, page-specific caveat.
        if ($Name -like "Tool-*" -or $Name -eq "Compare-Copilot-Tools") {
            $Html += "<p>Last checked: $(Escape-Html $toolsCatalog.reviewedOn). Confirm your tenant's current features and policies.</p>"
        }
    }
    if ($IntroHtml) {
        Add-PnPPageTextPart -Page $Name -Text ($IntroHtml.Replace("<p><em></em></p>", "")) -Order 1 -Connection $SiteConnection | Out-Null
    }
    Add-PnPPageTextPart -Page $Name -Text $Html -Order $(if ($IntroHtml) { 2 } else { 1 }) -Connection $SiteConnection | Out-Null
    # PageTitleWebPart renders the title inline with the content instead of Default's large banner area, which
    # left a tall empty gap above the body on every tool and guide page.
    Set-PnPPage -Identity $Name -HeaderType PageTitleWebPart -Publish -Connection $SiteConnection | Out-Null
    $script:writtenManagedPages += "$($SiteUrl.TrimEnd('/'))|$Name"
    return Get-PnPPage -Identity $Name -Connection $SiteConnection
}

# Adds (or refreshes) a captured content page's "Home / Section" breadcrumb. A plain existence check ("is
# there already a breadcrumb-shaped control") is not enough once a page can be repaired more than once
# across kit versions: an earlier kit version's breadcrumb used the internal section Key instead of the
# menu's shortened Title (see Get-CoESectionStripHtml's own history), so its text already matched the
# generic ">Home</a> /" shape even though the label itself was stale - "a breadcrumb exists" was being used
# as a stand-in for "the breadcrumb is current", which silently kept the old label on Adoption, Roles,
# Technical Readiness and Microsoft Mechanics forever on any site repaired more than once. Collects every
# matching control (not just whether one exists), keeps exactly one whose normalized text matches the
# current expected HTML, and removes every other match - the same pattern, and the same reload-before-remove
# safeguard, as Set-CoEHomeWelcomeText.
#
# A plain exact-text comparison is not enough either: confirmed live, SharePoint's save pipeline for this
# inline text web part neither preserves the supplied outer <p>...</p> wrapper (it stores a bare inline
# fragment instead) nor keeps a same-site absolute href (it rewrites https://host/sites/X/Y.aspx down to
# /sites/X/Y.aspx). Three separate repair runs against Copilot-on-Microsoft-Mechanics.aspx each added another
# control because an exact comparison against the originally supplied markup never matched what SharePoint
# actually stored, even though every add itself succeeded - leaving three duplicate breadcrumbs behind, one
# per run. ConvertTo-CoEStableBreadcrumbText normalizes both sides the same way before comparing.
function ConvertTo-CoEStableBreadcrumbText([string]$Html) {
    $decoded = [Net.WebUtility]::HtmlDecode($Html).Trim()
    $decoded = [regex]::Replace($decoded, '^<p>(.*)</p>$', '$1')
    return [regex]::Replace($decoded, 'href="https?://[^/"]+(/[^"]*)"', 'href="$1"')
}

function Set-CoESectionStripPart($SiteConnection, [string]$PageName, [string]$StripHtml) {
    if (-not $StripHtml) { return }
    $page = Get-PnPPage -Identity $PageName -Connection $SiteConnection -ErrorAction Stop
    $matchedControls = @($page.Controls | Where-Object { $_.PSObject.Properties["Text"] -and [string]$_.Text -match '>Home</a> /' })
    $decodedStrip = ConvertTo-CoEStableBreadcrumbText $StripHtml
    $current = @($matchedControls | Where-Object { (ConvertTo-CoEStableBreadcrumbText ([string]$_.Text)) -eq $decodedStrip })
    # Exactly one matched control, and it is already current: truly nothing to do. Any other shape - zero
    # current (stale or missing), or more than one even though all are "current" (duplicates left behind by
    # an earlier run that mistakenly added another copy of an already-matching breadcrumb, confirmed live) -
    # falls through to pick or create a single keeper and prune every other matched control below.
    if ($current.Count -eq 1 -and $matchedControls.Count -eq 1) { return }
    if ($current.Count -ge 1) {
        $keeperId = $current[0].InstanceId
    } else {
        $priorIds = @($matchedControls | ForEach-Object InstanceId)
        Add-PnPPageTextPart -Page $PageName -Text $StripHtml -Order 1 -Connection $SiteConnection -ErrorAction Stop | Out-Null
        Set-PnPPage -Identity $PageName -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
        # Reload before identifying the new control (and again before each removal below) - see
        # Set-CoEHomeWelcomeText's own comment on why a stale pre-add page object must never be reused here.
        $page = Get-PnPPage -Identity $PageName -Connection $SiteConnection -ErrorAction Stop
        $added = @($page.Controls | Where-Object { $_.PSObject.Properties["Text"] -and
            (ConvertTo-CoEStableBreadcrumbText ([string]$_.Text)) -eq $decodedStrip -and $_.InstanceId -notin $priorIds }) | Select-Object -First 1
        if (-not $added) { throw "$PageName's new breadcrumb was not found after being added." }
        $keeperId = $added.InstanceId
    }
    foreach ($old in @($matchedControls | Where-Object { $_.InstanceId -ne $keeperId })) {
        $page = Get-PnPPage -Identity $PageName -Connection $SiteConnection -ErrorAction Stop
        Remove-PnPPageComponent -Page $page -InstanceId $old.InstanceId -Force -Connection $SiteConnection -ErrorAction Stop | Out-Null
        Set-PnPPage -Identity $PageName -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
    }
}

function Disable-CoEPageComments($SiteConnection) {
    # Comments are a SharePoint page default; this is a dedicated kit-managed site, so turn them off everywhere.
    # The site-wide setting covers pages the CoE team creates later; the per-page pass covers pages that
    # already exist today (the site-wide setting only changes the default for new pages, not existing ones).
    Set-PnPWeb -CommentsOnSitePagesDisabled:$true -Connection $SiteConnection -ErrorAction Stop
    foreach ($page in @(Get-PnPPage -Connection $SiteConnection -ErrorAction Stop)) {
        Set-PnPPage -Identity $page.Name -CommentsEnabled:$false -Connection $SiteConnection -ErrorAction Stop | Out-Null
    }
}

function Repair-CoEHubPages($SiteConnection, [object[]]$Links, [string]$Environment) {
    $pages = @(Get-PnPPage -Connection $SiteConnection -ErrorAction Stop)
    foreach ($link in $Links | Where-Object { $_.Page -and $_.Page -ne "TrainingHome.aspx" }) {
        if ($link.Page -notin @($pages | ForEach-Object Name)) {
            throw "Home and menu link '$($link.Title)' targets a missing page '$($link.Page)'."
        }
    }
    $before = Get-PnPFile -Url "SitePages/TrainingHome.aspx" -AsListItem -Connection $SiteConnection -ErrorAction Stop
    $before.FieldValues | ConvertTo-Json -Depth 100 |
        Set-Content (Join-Path $auditFolder "$runId-Home-hub-before.json") -Encoding utf8
    # The Hero (purple, retargeted to the CoE's own tiles before this site was provisioned - see
    # Prepare-CopilotCoE.ps1) and every section background are the vendor template's own web parts; keep
    # them exactly as provisioned instead of clearing the page. The vendor's own Events web part is the one
    # exception: it binds to the generic default "Events" list and has no way to express the "approved
    # sessions only" filter the kit's calendar view carries, so it is replaced (not retargeted) with the same
    # correctly-bound List web part already used on Learning-Series and CoE-Training-and-Enablement. The
    # "Resources" Quick Links control is still generic and gets relabelled into "Copilot tools" here, in
    # place - everything else on Home is left untouched.
    $homePageObject = Get-PnPPage -Identity "TrainingHome.aspx" -Connection $SiteConnection -ErrorAction Stop
    $eventsControls = @($homePageObject.Controls | Where-Object { $_.PSObject.Properties["PropertiesJson"] -and
        ([string]$_.PropertiesJson) -match '"dataProviderId":"Event"' })
    if ($eventsControls.Count -gt 1) { throw "Home has more than one Events web part; review it before repairing." }
    foreach ($control in $eventsControls) {
        Remove-PnPPageComponent -Page $homePageObject -InstanceId $control.InstanceId -Force `
            -Connection $SiteConnection -ErrorAction Stop | Out-Null
    }
    # Named "Home", not $DisplayName: the page Title and the site's own title (also $DisplayName) combine in
    # the browser tab as "{page title} - {site title}" - setting both to the identical string produced a
    # tab reading "CoE Content Demo - CoE Content Demo", confirmed live.
    Set-PnPPage -Identity "TrainingHome.aspx" -Title "Home" -Publish -Connection $SiteConnection -ErrorAction Stop | Out-Null
    $before = Get-PnPFile -Url "SitePages/TrainingHome.aspx" -AsListItem -Connection $SiteConnection -ErrorAction Stop
    $homeCanvas = [string]$before["CanvasContent1"]
    if ($homeCanvas -notmatch 'c4bd7b2f-7b6e-4599-8485-16504575f590') {
        throw "Home is missing its Hero web part; it may not have been provisioned from the 3.7 template."
    }
    $toolItems = @(Get-CoEToolQuickLinksItems $toolsCatalog.tools $Links $developerEnabled)
    $newHomeCanvas = Convert-CoEQuickLinksCanvas $homeCanvas $SiteUrl "Resources" "Copilot tools" $toolItems
    if ($newHomeCanvas -ne $homeCanvas) {
        Set-PnPListItem -List "SitePages" -Identity $before.Id -Values @{ CanvasContent1 = $newHomeCanvas } -Connection $SiteConnection | Out-Null
        $homeFile = Get-PnPFile -Url "SitePages/TrainingHome.aspx" -AsFileObject -Connection $SiteConnection
        $homeFile.Publish("Relabel the vendor Resources Quick Links as Copilot tools")
        Invoke-PnPQuery -Connection $SiteConnection
    }
    $saved = Get-PnPListItem -List "SitePages" -Id $before.Id -Connection $SiteConnection -ErrorAction Stop
    $savedCanvas = [string]$saved["CanvasContent1"]
    if ($savedCanvas -notmatch 'c4bd7b2f-7b6e-4599-8485-16504575f590') { throw "Home lost its Hero web part." }
    if ($savedCanvas -notmatch [regex]::Escape("Copilot tools")) { throw "Home did not retain the Copilot tools Quick Links." }
    # Parse the saved control's JSON rather than substring-searching the raw canvas: SharePoint encodes ":"
    # in saved URLs as the numeric entity &#58; (so "https://" becomes "https&#58;//"), which HtmlEncode()
    # never produces - a naive raw-text search for the plain URL would never match even when it's present.
    $savedToolsControls = @([regex]::Matches($savedCanvas, 'data-sp-webpartdata="([^"]*)"') | ForEach-Object {
        $candidate = [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($candidate -and $candidate.PSObject.Properties["serverProcessedContent"] -and
            $candidate.serverProcessedContent.PSObject.Properties["searchablePlainTexts"] -and
            $candidate.serverProcessedContent.searchablePlainTexts.PSObject.Properties["title"] -and
            $candidate.serverProcessedContent.searchablePlainTexts.title -eq "Copilot tools") { $candidate }
    })
    if ($savedToolsControls.Count -ne 1) { throw "Expected exactly one saved 'Copilot tools' Quick Links control; found $($savedToolsControls.Count)." }
    $savedUrls = @($savedToolsControls[0].properties.items | ForEach-Object sourceItem | ForEach-Object url)
    foreach ($item in $toolItems) {
        if ($item.Url -notin $savedUrls) {
            throw "Home's Copilot tools Quick Links is missing the link for '$($item.Title)'."
        }
    }
    # "Explore the CoE": replaces the vendor's placeholder Image web part in the same purple section with a
    # Quick Links tile per major area (Training, Agents, Governance, Help & community).
    $exploreItems = @(Get-CoEExploreQuickLinksItems $Links)
    Remove-CoEPlaceholderWebPart -SiteConnection $SiteConnection -PageName "TrainingHome" -Title "Image"
    Add-CoEQuickLinksButtons -SiteConnection $SiteConnection -PageName "TrainingHome" -Label "Explore the CoE" `
        -Items $exploreItems -Order 1 -Section 3 -Column 1
    # Home's neutral section still ships the vendor's generic "Meet your Copilot champions" placeholder text -
    # replace it with the organization's own sample notice and welcome copy. Only reached here under
    # -RepairCapturedPages (see Set-CoEHomeWelcomeText's own header comment); a true no-op if the block
    # already matches the current grammar, notice and position - a repeat -RepairCapturedPages run changes
    # nothing further on Home.
    Set-CoEHomeWelcomeText -SiteConnection $SiteConnection -PageName "TrainingHome" -SiteUrl $SiteUrl `
        -OrgName $orgName -OrgNoun $orgNoun -SampleNotice $SampleNotice
    # Home's final (neutral-background) section ships from the vendor template as a generic stock photo
    # (Column 1, "Smiling woman holding a tablet") next to the champions text Set-CoEHomeWelcomeText already
    # replaces (Column 2). The photo is never organization-specific and was never retargeted like every other
    # vendor placeholder on this page - replace it with a real Quick Links CTA to the champions directory
    # instead of leaving a generic image (or an empty column) at the bottom of the page.
    $championsLink = @($Links | Where-Object Key -eq "Champions")
    if ($championsLink.Count -eq 1) {
        Remove-CoEPlaceholderWebPart -SiteConnection $SiteConnection -PageName "TrainingHome" -Title "Image"
        # "calendarmirrored", not (Get-CoEQuickLinksIconNames)[0] ("editnote") - a live reviewer flagged
        # Copilot Chat/Copilot Studio/Governance/Meet a Champion as a cluster of near-identical note icons;
        # "editnote" is already Copilot Chat's icon two sections up (see Get-CoEToolIconName), so Meet a
        # Champion needs its own distinct icon, not the rotation's first entry.
        Add-CoEQuickLinksButtons -SiteConnection $SiteConnection -PageName "TrainingHome" -Label "Meet a champion" `
            -Items @([pscustomobject]@{ Title = "Meet a Champion"; Description = "Find a Copilot champion near you"
                Url = $championsLink[0].Url; Icon = "calendarmirrored" }) -Order 1 -Section 4 -Column 1
    }
    if ("Copilot-on-Microsoft-Mechanics.aspx" -in @($pages | ForEach-Object Name)) {
        $mechanics = '<p>Use Microsoft''s official hubs for current Copilot demonstrations and technical explanations. Video availability depends on your organization''s media policies and the publisher.</p><ul>' +
            '<li><a href="https://www.microsoft.com/mechanics">Microsoft Mechanics</a></li>' +
            '<li><a href="https://techcommunity.microsoft.com/category/microsoftmechanics">Microsoft Mechanics video hub</a></li></ul>'
        $null = Write-ManagedPage $SiteConnection "Copilot-on-Microsoft-Mechanics" "Microsoft Mechanics resources" $mechanics
    }
    foreach ($page in $pages | Where-Object Name -in @("Adoption-Best-Practices.aspx", "Meet-your-ProjectTeam.aspx",
        "Technical Readiness.aspx", "Copilot-on-Microsoft-Mechanics.aspx")) {
        # Named $pageArgs, not $args: $args is PowerShell's own automatic variable (the non-declared argument
        # list available inside any function/script), the same class of mistake as the $matches collision
        # caught earlier in Set-CoEHomeWelcomeText. Harmless today only because nothing downstream reads the
        # real $args in this scope, but worth never relying on that.
        $pageArgs = @{ Identity = $page.Name; HeaderType = "PageTitleWebPart"
            Publish = $true; Connection = $SiteConnection; ErrorAction = "Stop" }
        if ($page.Name -eq "Adoption-Best-Practices.aspx") { $pageArgs.Title = "Copilot CoE adoption guide" }
        if ($page.Name -eq "Meet-your-ProjectTeam.aspx") { $pageArgs.Title = "CoE roles and contacts" }
        Set-PnPPage @pageArgs | Out-Null
        # These four vendor-captured pages have no kit-authored body for Write-ManagedPage to attach a sample
        # notice to - only their title and breadcrumb are kit-managed. Appending the notice to the same
        # breadcrumb control (right after the title, the same relative position every kit-generated page uses)
        # closes a confirmed gap: these four pages never showed the organization's sample/demo notice at all,
        # unlike every other kit-managed page. Set-CoESectionStripPart's existing idempotent single-block
        # machinery (shape match, normalized compare, dedupe) applies unchanged - the notice is just more text
        # in the same managed control, not a second one.
        # Regression guard: Copilot-on-Microsoft-Mechanics.aspx gets its body rewritten by Write-ManagedPage
        # just above (the Mechanics links block), which rebuilds its own fresh breadcrumb strip with no
        # notice - this loop must run AFTER that rewrite for all four pages, Mechanics included, or its own
        # notice gets silently wiped the moment it's added. Confirmed missing live before this reorder.
        $strip = Get-CoESectionStripHtml $Links $page.Name
        if ($strip -and $SampleNotice) { $strip += "<p><em>$(Escape-Html $SampleNotice)</em></p>" }
        Set-CoESectionStripPart -SiteConnection $SiteConnection -PageName $page.Name -StripHtml $strip
    }
    return [pscustomobject]@{ HomeLinks = @($Links | Select-Object Title,Url)
        CalendarSource = "Lists/CopilotTrainingCalendar"; LegacyTemplatePreserved = $true }
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
# Splits a paragraph's text into runs, auto-hyperlinking any bare http(s) URL so policy references (for
# example an organization's own AI-policy links in governance drafts) are clickable in the hosted Word document
# instead of inert plain text - confirmed live: New-SimpleDocx previously wrote every paragraph as a single
# plain <w:r><w:t> run with no hyperlink relationship at all, and Get-DocxParagraphs normalizes markdown link
# syntax ([label](url)) down to plain "label (url)" text rather than a real link, so neither the source
# content format nor the DOCX writer made these URLs clickable. The hyperlink's visible text is the URL
# itself, not a shortened label: Read-DocxText extracts only visible <w:t> text regardless of whether it
# sits inside a <w:hyperlink>, so Write-ManagedDocx's round-trip "has this changed" comparison against the
# plain-text draft still sees byte-identical content and correctly no-ops on an unchanged draft.
function ConvertTo-CoEDocxRuns([string]$Text, $RelCounter, [System.Collections.Generic.List[string]]$Relationships) {
    $esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
    $runsXml = [System.Text.StringBuilder]::new()
    $lastIndex = 0
    $matchCount = 0
    foreach ($m in [regex]::Matches($Text, 'https?://[^\s<>"()]+')) {
        $url = $m.Value
        $length = $m.Length
        # Exclude a single trailing sentence-ending punctuation character from the link target, so a bare URL
        # at the end of a sentence does not pull in the period as part of the destination. Parentheses are
        # excluded from the match itself (not trimmed here): the "label (url)" form markdown-link
        # normalization produces wraps the URL in literal parens, and a closing paren is common enough in
        # ordinary prose around a URL that it must never be treated as part of the address.
        if ($length -gt 1 -and $url[-1] -in '.,;:!?') { $url = $url.Substring(0, $length - 1); $length-- }
        if (-not $url) { continue }
        $matchCount++
        if ($m.Index -gt $lastIndex) {
            $plain = $Text.Substring($lastIndex, $m.Index - $lastIndex)
            [void]$runsXml.Append("<w:r><w:t xml:space=`"preserve`">$(& $esc $plain)</w:t></w:r>")
        }
        $relId = "rIdUrl$($RelCounter.Value)"
        $RelCounter.Value++
        $Relationships.Add("<Relationship Id=`"$relId`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink`" Target=`"$(& $esc $url)`" TargetMode=`"External`"/>")
        [void]$runsXml.Append("<w:hyperlink r:id=`"$relId`"><w:r><w:rPr><w:rStyle w:val=`"Hyperlink`"/></w:rPr><w:t xml:space=`"preserve`">$(& $esc $url)</w:t></w:r></w:hyperlink>")
        $lastIndex = $m.Index + $length
    }
    if ($lastIndex -lt $Text.Length) {
        $plain = $Text.Substring($lastIndex)
        [void]$runsXml.Append("<w:r><w:t xml:space=`"preserve`">$(& $esc $plain)</w:t></w:r>")
    }
    if ($matchCount -eq 0) {
        # No URLs: a single run, exactly the prior behavior (including for an empty/blank paragraph).
        return "<w:r><w:t xml:space=`"preserve`">$(& $esc $Text)</w:t></w:r>"
    }
    return $runsXml.ToString()
}
function New-SimpleDocx([string]$Text, [string]$Path, [string]$Title) {
    $esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
    # rId1 is reserved for styles.xml below; hyperlink relationships start at rId2.
    $relCounter = [pscustomobject]@{ Value = 2 }
    $hyperlinkRels = [System.Collections.Generic.List[string]]::new()
    $body = foreach ($p in (Get-DocxParagraphs $Text)) {
        $pPr = if ($p.Style -ne "Normal") { "<w:pPr><w:pStyle w:val=`"$($p.Style)`"/></w:pPr>" } else { "" }
        $runs = ConvertTo-CoEDocxRuns $p.Text $relCounter $hyperlinkRels
        "<w:p>$pPr$runs</w:p>"
    }
    $w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    $r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    $parts = [ordered]@{
        "[Content_Types].xml" = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Types xmlns=`"http://schemas.openxmlformats.org/package/2006/content-types`"><Default Extension=`"rels`" ContentType=`"application/vnd.openxmlformats-package.relationships+xml`"/><Default Extension=`"xml`" ContentType=`"application/xml`"/><Override PartName=`"/word/document.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml`"/><Override PartName=`"/word/styles.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml`"/><Override PartName=`"/docProps/core.xml`" ContentType=`"application/vnd.openxmlformats-package.core-properties+xml`"/></Types>"
        "_rels/.rels" = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Relationships xmlns=`"http://schemas.openxmlformats.org/package/2006/relationships`"><Relationship Id=`"rId1`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument`" Target=`"word/document.xml`"/><Relationship Id=`"rId2`" Type=`"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties`" Target=`"docProps/core.xml`"/></Relationships>"
        "word/_rels/document.xml.rels" = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><Relationships xmlns=`"http://schemas.openxmlformats.org/package/2006/relationships`"><Relationship Id=`"rId1`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles`" Target=`"styles.xml`"/>$($hyperlinkRels -join '')</Relationships>"
        "word/styles.xml" = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><w:styles xmlns:w=`"$w`"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=`"Calibri`" w:hAnsi=`"Calibri`" w:cs=`"Calibri`"/><w:sz w:val=`"22`"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=`"160`" w:line=`"276`" w:lineRule=`"auto`"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type=`"paragraph`" w:default=`"1`" w:styleId=`"Normal`"><w:name w:val=`"Normal`"/></w:style><w:style w:type=`"paragraph`" w:styleId=`"Heading1`"><w:name w:val=`"heading 1`"/><w:basedOn w:val=`"Normal`"/><w:next w:val=`"Normal`"/><w:pPr><w:keepNext/><w:spacing w:before=`"240`" w:after=`"120`"/><w:outlineLvl w:val=`"0`"/></w:pPr><w:rPr><w:b/><w:color w:val=`"1F3864`"/><w:sz w:val=`"28`"/></w:rPr></w:style><w:style w:type=`"paragraph`" w:styleId=`"Heading2`"><w:name w:val=`"heading 2`"/><w:basedOn w:val=`"Normal`"/><w:next w:val=`"Normal`"/><w:pPr><w:keepNext/><w:spacing w:before=`"200`" w:after=`"80`"/><w:outlineLvl w:val=`"1`"/></w:pPr><w:rPr><w:b/><w:color w:val=`"2F5496`"/><w:sz w:val=`"24`"/></w:rPr></w:style><w:style w:type=`"character`" w:styleId=`"Hyperlink`"><w:name w:val=`"Hyperlink`"/><w:rPr><w:color w:val=`"0563C1`"/><w:u w:val=`"single`"/></w:rPr></w:style></w:styles>"
        "docProps/core.xml" = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><cp:coreProperties xmlns:cp=`"http://schemas.openxmlformats.org/package/2006/metadata/core-properties`" xmlns:dc=`"http://purl.org/dc/elements/1.1/`"><dc:title>$(& $esc $Title)</dc:title></cp:coreProperties>"
        "word/document.xml" = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><w:document xmlns:w=`"$w`" xmlns:r=`"$r`"><w:body>$($body -join '')<w:sectPr><w:pgSz w:w=`"12240`" w:h=`"15840`"/><w:pgMar w:top=`"1440`" w:right=`"1440`" w:bottom=`"1440`" w:left=`"1440`" w:header=`"720`" w:footer=`"720`" w:gutter=`"0`"/></w:sectPr></w:body></w:document>"
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
function Add-CoEFileWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][object]$Connection,
        [int]$MaxAttempts = 6,
        [int]$DelaySeconds = 10
    )
    if ($MaxAttempts -lt 1) { throw "MaxAttempts must be at least 1." }
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            # A newly created shared-channel site can return its filesFolder before the next child folder is
            # consistently addressable by Add-PnPFile. Re-resolve on every attempt so a transient 404 cannot
            # strand a fresh build after its parent Team and site already exist.
            Resolve-PnPFolder -SiteRelativePath $Folder -Connection $Connection -ErrorAction Stop | Out-Null
            Add-PnPFile -Path $Path -Folder $Folder -Connection $Connection -ErrorAction Stop | Out-Null
            return
        } catch {
            $message = $_.Exception.Message
            $transient = $message -match '404|NotFound|Not Found|429|TooManyRequests|Timeout|canceled|cancelled|502|503|504|temporarily|ServiceUnavailable|GatewayTimeout'
            if (-not $transient -or $attempt -eq $MaxAttempts) { throw }
            Write-Warning "SharePoint folder '$Folder' is not ready for upload (attempt $attempt of $MaxAttempts): $message"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
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
            throw "Managed file $Folder/$FileName differs from the draft. Review it, then rerun with 03_Update-CoEContent.ps1 -ReplaceFiles (02_Install-CopilotCoE.ps1 uses -ReplaceManagedFiles) to authorize replacement."
        }
        else { $before | Set-Content (Join-Path $auditFolder "$runId-$AuditKey-$FileName-before.txt") -Encoding utf8 }
    }
    if ($write) {
        $temp = Join-Path ([IO.Path]::GetTempPath()) ("coe-" + [guid]::NewGuid().ToString("N"))
        [void][IO.Directory]::CreateDirectory($temp)
        $docxPath = Join-Path $temp $FileName
        try {
            New-SimpleDocx -Text (Get-Content -LiteralPath $LocalPath -Raw) -Path $docxPath -Title $Title
            Add-CoEFileWithRetry -Path $docxPath -Folder $Folder -Connection $SiteConnection
        } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
        $saved = Read-DocxText ((Get-PnPFile -Url "$Folder/$FileName" -AsMemoryStream -Connection $SiteConnection).ToArray())
        if ($saved -ne $desiredText) { throw "Managed governance document does not match the reviewed draft: $Folder/$FileName" }
    }
    foreach ($legacy in @($LegacyNames | Where-Object { $_ -and $_ -ne $FileName })) {
        $old = @(Get-PnPFolderItem -FolderSiteRelativeUrl $Folder -ItemType File -Connection $SiteConnection | Where-Object Name -eq $legacy)
        if ($old.Count -eq 0) { continue }
        if (-not $ReplaceManagedFiles) {
            Write-Warning "Kept the older copy $Folder/$legacy next to $FileName. Run 03_Update-CoEContent.ps1 -ReplaceFiles to remove it."
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
    param($SiteConnection, [string]$PageUrl, [string]$DirectoryUrl, [switch]$GroupUnderCommunity)
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
    if ($GroupUnderCommunity) {
        foreach ($node in @(Get-PnPNavigationNode -Location QuickLaunch -Connection $SiteConnection -ErrorAction Stop |
            Where-Object { (Get-ManagedNavigationUrl $_.Url) -eq $pageTarget })) {
            Remove-PnPNavigationNode -Identity $node.Id -Force -Connection $SiteConnection -ErrorAction Stop
        }
        return
    }
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
            throw "Managed file $Folder/$name differs from the draft. Review it, then rerun with 03_Update-CoEContent.ps1 -ReplaceFiles (02_Install-CopilotCoE.ps1 uses -ReplaceManagedFiles) to authorize replacement."
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
    Set-PnPListItem -List "SitePages" -Identity $savedReadiness.Id `
        -Values @{ CanvasContent1 = $canvas.Replace($oldForum, $copy.repairs.forum) } -Connection $site | Out-Null
}
$readinessFile = Get-PnPFile -Url "SitePages/Technical Readiness.aspx" -AsFileObject -Connection $site
$readinessFile.Publish("Remove Early Access Program and update the Copilot community link")
Invoke-PnPQuery -Connection $site
$publishedReadiness = Get-PnPListItem -List "SitePages" -Id $savedReadiness.Id -Connection $site
if ([string]$publishedReadiness["CanvasContent1"] -match "Early Access Program|m365-early-access-program" -or
    ([string]$publishedReadiness["CanvasContent1"]).Contains($oldForum)) {
    throw "The published Technical Readiness page still contains an obsolete resource."
}
$report.Readiness = @{ RemovedEapControls = $eapCount; ReplacedForumControls = $oldForumCount }

# The vendor "Resources" Quick Links control on Home is now relabelled into "Copilot tools" by
# Repair-CoEHubPages (further down, guarded by -RepairCapturedPages), which replaces both its title and
# items - a strict superset of what this block used to do (retarget item URLs only, keeping the vendor's
# generic titles). Keeping both would mean this block throws on every re-run once Repair-CoEHubPages has
# already renamed "Resources" away, since there would be nothing left named "Resources" to find.
$report.LearningResources = @()

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
    -DirectoryUrl "$($SiteUrl.TrimEnd('/'))/Lists/DepartmentChampions" `
    -GroupUnderCommunity:($navOrder -eq "TaskFirst")

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
    @{ Name = "SampleStatus"; Title = "Sample status"; Type = "Choice" },
    @{ Name = "RegistrationUrl"; Title = "Registration link"; Type = "URL" }
)) {
    if ($field.Name -in $calendarFields) { continue }
    if ($field.Name -eq "Format") {
        Add-PnPField -List $calendar -DisplayName $field.Title -InternalName $field.Name -Type Choice `
            -Choices @("Online session", "In-person session", "Hybrid") -AddToDefaultView -Connection $site | Out-Null
    } elseif ($field.Name -eq "SampleStatus") {
        Add-PnPField -List $calendar -DisplayName $field.Title -InternalName $field.Name -Type Choice `
            -Choices @("DRAFT - DEMONSTRATION", "Approved", "Cancelled") -AddToDefaultView -Connection $site | Out-Null
    } else {
        Add-PnPField -List $calendar -DisplayName $field.Title -InternalName $field.Name -Type $field.Type `
            -AddToDefaultView -Connection $site | Out-Null
    }
}
$calendarViews = @(Get-PnPView -List $calendar -Connection $site)
if (@($calendarViews | Where-Object Title -eq "Calendar").Count -eq 0) {
    Add-PnPView -List $calendar -Title "Calendar" -Fields @("Title", "EventDate", "EndDate", "Location", "Audience", "SampleStatus") `
        -ViewType Calendar -SetAsDefault -Paged -Connection $site | Out-Null
}
$upcomingQuery = "<Where><And><Eq><FieldRef Name='SampleStatus'/><Value Type='Choice'>Approved</Value></Eq>" +
    "<Geq><FieldRef Name='EventDate'/><Value Type='DateTime' IncludeTimeValue='TRUE'><Today/></Value></Geq></And></Where>" +
    "<OrderBy><FieldRef Name='EventDate' Ascending='TRUE'/></OrderBy>"
# RegistrationUrl starts out of the view: whether to show it at all is decided after seeding below, once the
# actual upcoming data is known, rather than always reserving a column that is empty for every demo sample.
if (@($calendarViews | Where-Object Title -eq "Upcoming approved sessions").Count -eq 0) {
    Add-PnPView -List $calendar -Title "Upcoming approved sessions" -Fields @("Title", "EventDate") `
        -Query $upcomingQuery -RowLimit 3 -Connection $site -ErrorAction Stop | Out-Null
} else {
    $existingUpcoming = @($calendarViews | Where-Object Title -eq "Upcoming approved sessions")
    if ($existingUpcoming.Count -ne 1) { throw "Duplicate upcoming sessions views." }
    Set-PnPView -List $calendar -Identity $existingUpcoming[0].Id -Values @{
        ViewQuery = $upcomingQuery; RowLimit = [uint32]3
    } -Connection $site -ErrorAction Stop | Out-Null
}
$eventSeedPath = Join-Path $seedRoot "Training-Calendar.csv"
if (-not (Test-Path -LiteralPath $eventSeedPath -PathType Leaf)) {
    throw "The training calendar seed file is missing: $eventSeedPath"
}
$eventSeeds = @(Import-Csv -LiteralPath $eventSeedPath)
# Validate the schema explicitly before using it: an organization's own Content\Training-Calendar.csv
# override, authored before the kit moved from fixed StartDate/EndDate columns to StartOffsetDays/
# EndOffsetDays (3.8.1), would otherwise fail deep inside the loop below with a bare, unhelpful "property
# cannot be found" error - confirmed live on a real install, where the override predated the schema change
# and was never migrated alongside the kit's own SeedContent and Government pack copies. Fails once, clearly,
# for every bad row at once, with the exact fix named, instead of stopping on the first row encountered.
$missingOffsetRows = @($eventSeeds | Where-Object { -not $_.PSObject.Properties["StartOffsetDays"] -or [string]$_.StartOffsetDays -eq "" })
if ($missingOffsetRows.Count) {
    throw "$eventSeedPath uses the old Training-Calendar.csv schema (StartDate/EndDate fixed dates). Since " +
        "kit 3.8.1 it needs a StartOffsetDays column (days from the day this script runs; EndOffsetDays is " +
        "optional and defaults to StartOffsetDays) instead. Affected row(s): $(($missingOffsetRows | ForEach-Object Title) -join ', '). " +
        "Update this file to the new schema (see the kit's own SeedContent\Training-Calendar.csv for the " +
        "current column layout) before re-running."
}
# Re-read the list on the site connection so later item writes and the web part binding share one context.
$calendar = Get-PnPList -Identity "Lists/CopilotTrainingCalendar" -Connection $site
if (-not $calendar) { throw "The training calendar list could not be re-read after setup." }
$existingEvents = @(Get-PnPListItem -List $calendar -PageSize 100 -Connection $site)
$eastern = $siteTimeZone
$eventsAdded = 0
$eventsSkipped = 0
$eventsRemoved = 0
# Sample dates are StartOffsetDays from "today" (the day this runs), not fixed calendar dates, so the
# training calendar never runs dry weeks after install - see CHANGE-LIST-3.8.1. The "already exists" check
# below is keyed on Title ALONE, not Title + SampleStatus: an admin approving a seeded DRAFT sample (the
# normal demo workflow - flipping its SampleStatus from "DRAFT - DEMONSTRATION" to "Approved" on the live
# list) must still count as "this title already exists" on the next run, or the kit would add a second,
# duplicate DRAFT copy of a session someone just approved - the Title + SampleStatus key used in 3.8.1
# could never match again once the live status changed, which is exactly what that scenario does. A sample
# row's stored EventDate is never recalculated or touched again once created (so dates don't drift forward
# every time 03_Update-CoEContent.ps1 happens to run); only titles genuinely new to the CSV get a fresh date
# computed relative to that later run.
$today = (Get-Date).Date
$existingTitles = @($existingEvents | ForEach-Object { [string]$_["Title"] })
if ($ContentMode -eq "Demo") {
    # Sample dates are StartOffsetDays from "today" (the day this runs), not fixed calendar dates, so the
    # training calendar never runs dry weeks after install - see CHANGE-LIST-3.8.1. The "already exists" check
    # below is keyed on Title ALONE, not Title + SampleStatus: an admin approving a seeded DRAFT sample (the
    # normal demo workflow - flipping its SampleStatus from "DRAFT - DEMONSTRATION" to "Approved" on the live
    # list) must still count as "this title already exists" on the next run, or the kit would add a second,
    # duplicate DRAFT copy of a session someone just approved - the Title + SampleStatus key used in 3.8.1
    # could never match again once the live status changed, which is exactly what that scenario does. A sample
    # row's stored EventDate is never recalculated or touched again once created (so dates don't drift forward
    # every time 03_Update-CoEContent.ps1 happens to run); only titles genuinely new to the CSV get a fresh date
    # computed relative to that later run.
    foreach ($event in $eventSeeds) {
        $startDate = $today.AddDays([int]$event.StartOffsetDays).ToString("yyyy-MM-dd")
        # EndOffsetDays defaults to StartOffsetDays (same-day session, true for every shipped sample); an
        # organization can still author a session that crosses midnight by giving EndOffsetDays its own value.
        $endOffset = if ($event.PSObject.Properties["EndOffsetDays"] -and [string]$event.EndOffsetDays -ne "") {
            [int]$event.EndOffsetDays
        } else { [int]$event.StartOffsetDays }
        $endDate = $today.AddDays($endOffset).ToString("yyyy-MM-dd")
        $startLocal = [datetime]::ParseExact("$startDate $($event.StartTimeET)", "yyyy-MM-dd HH:mm", `
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
        $endLocal = [datetime]::ParseExact("$endDate $($event.EndTimeET)", "yyyy-MM-dd HH:mm", `
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
        if ($endLocal -le $startLocal) { throw "Training event has an invalid time range: $($event.Title)" }
        $startUtc = [TimeZoneInfo]::ConvertTimeToUtc($startLocal, $eastern)
        $endUtc = [TimeZoneInfo]::ConvertTimeToUtc($endLocal, $eastern)
        if ($event.Title -in $existingTitles) { $eventsSkipped++; continue }
        $eventValues = @{
            Title = $event.Title
            EventDate = $startUtc
            EndDate = $endUtc
            Description = $event.Description
            Location = "Not assigned - sample only"
            Audience = $event.Audience
            Format = $event.Format
            SampleStatus = $event.SampleStatus
        }
        $registrationUrl = [string](Get-CoECatalogValue $event "RegistrationUrl")
        if ($registrationUrl) {
            $destination = Resolve-CoECatalogUrl $registrationUrl "Training calendar registration link"
            $registration = [Microsoft.SharePoint.Client.FieldUrlValue]::new()
            $registration.Url = $destination
            $registration.Description = "Register or join"
            $eventValues.RegistrationUrl = $registration
        }
        Add-PnPListItem -List $calendar.Id -Values $eventValues -Connection $site | Out-Null
        $eventsAdded++
    }
    # Remove kit sample sessions that are no longer in the seed file (for example after an organization
    # replaces Training-Calendar.csv). Keyed on Title alone, matching the "already exists" check above. Only
    # rows whose LIVE SampleStatus is still literally "DRAFT - DEMONSTRATION" are ever auto-removed - an admin
    # who approved a sample (flipping its live status to "Approved") has it protected from this cleanup by that
    # status check regardless of whether its title is still in the CSV, so approving a session never risks it
    # being auto-deleted later.
    $seedTitles = @($eventSeeds | ForEach-Object { [string]$_.Title })
    foreach ($item in $existingEvents) {
        if ([string]$item["SampleStatus"] -eq "DRAFT - DEMONSTRATION" -and [string]$item["Title"] -notin $seedTitles) {
            Remove-PnPListItem -List $calendar.Id -Identity $item.Id -Recycle -Force -Connection $site | Out-Null
            $eventsRemoved++
        }
    }
} else {
    # Customer mode never seeds the kit's own sample sessions, and cleans up any that a prior Demo-mode run
    # (or a Demo-to-Customer switch on the same site) left behind - approved or not. "SAMPLE - " is the
    # established kit-wide title prefix for every shipped sample (see CHANGE-LIST-3.8.2), so this removal is
    # not tied to the SampleStatus approval workflow and catches a sample regardless of its live status.
    # Add-PnPListItem/Remove-PnPListItem already support -WhatIf natively (PnP.PowerShell cmdlets implement
    # SupportsShouldProcess themselves); invoking this script with -WhatIf propagates automatically via
    # $WhatIfPreference without needing a manual ShouldProcess wrapper here.
    foreach ($item in $existingEvents) {
        if ([string]$item["Title"] -like "SAMPLE - *") {
            Remove-PnPListItem -List $calendar.Id -Identity $item.Id -Recycle -Force -Connection $site | Out-Null
            $eventsRemoved++
        }
    }
}
Write-CoEStep "Training calendar ($ContentMode)" "added $eventsAdded, skipped $eventsSkipped, removed $eventsRemoved"
# Decide whether "Upcoming approved sessions" shows the Registration link column at all: showing an always-
# empty column (every shipped demo sample leaves RegistrationUrl blank) reads as a broken field, not a
# feature nobody used yet. Re-evaluated on every run from the actual current data, not decided once at
# install time, so a real registration link added later (or removed) is reflected the next time this runs.
$upcomingEvents = @(Get-PnPListItem -List $calendar -Query "<View><Query>$upcomingQuery</Query></View>" -Connection $site)
$hasRegistrationLinks = [bool](@($upcomingEvents | Where-Object {
    $value = $_["RegistrationUrl"]
    $value -and [string]$value.Url
}).Count)
$upcomingFields = @("Title", "EventDate") + $(if ($hasRegistrationLinks) { @("RegistrationUrl") } else { @() })
$upcomingViewForFields = @(Get-PnPView -List $calendar -Connection $site | Where-Object Title -eq "Upcoming approved sessions")
if ($upcomingViewForFields.Count -ne 1) { throw "Duplicate or missing upcoming sessions view when setting its fields." }
Set-PnPView -List $calendar -Identity $upcomingViewForFields[0].Id -Fields $upcomingFields -Connection $site `
    -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
$calendarUrl = "$($SiteUrl.TrimEnd('/'))/Lists/CopilotTrainingCalendar/Calendar.aspx"
# The vendor's own Events web part on Home is removed and replaced by a correctly-bound List web part in
# Repair-CoEHubPages (it binds to the generic default "Events" list and cannot express "approved sessions
# only"), so there is nothing to retarget here.
$report.TrainingCalendar = @{ Url = $calendarUrl; ListUrl = "$($SiteUrl.TrimEnd('/'))/Lists/CopilotTrainingCalendar/AllItems.aspx"
    ContentMode = $ContentMode; SampleEvents = $eventSeeds.Count; Added = $eventsAdded; Skipped = $eventsSkipped; Removed = $eventsRemoved }
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
    # The kit already prepends $SampleNotice to every guide below - a content override that also hardcodes
    # that same text inside its own markdown body would show the notice twice in Demo mode, and would leak
    # straight to a Customer install (ContentMode only clears the kit's own prepended copy, not literal text
    # an org baked into its own content). Confirmed live: three organization override files had exactly this mistake.
    # Checked against $configuredSampleNotice (the notice as configured, before Customer mode blanks the live
    # $SampleNotice to "") so this guard still fires in Customer mode - the one mode where a hardcoded line
    # would actually reach a real customer verbatim, not just show twice. Also checks the HTML-encoded form,
    # since Convert-GuideMarkdown HTML-encodes the body text (turning a literal ' or & into an entity), so a
    # notice containing either character would otherwise never match the raw-text regex.
    if ($configuredSampleNotice -and ($converted.Html -match [regex]::Escape($configuredSampleNotice) -or
        $converted.Html -match [regex]::Escape([System.Net.WebUtility]::HtmlEncode($configuredSampleNotice)))) {
        throw "Guide $($guideFile.Name) already contains the configured SampleNotice text in its own body - " +
            "remove it there. The kit always prepends the notice itself; a content override should never " +
            "also hardcode it, or Demo mode shows it twice and Customer mode ships it verbatim."
    }
    # A second, fixed-marker check that does not depend on an exact match against whatever SampleNotice
    # happens to be configured right now: an org's hardcoded text could use older or different wording than
    # the current configured notice (for example after a notice-text change between kit versions), which
    # would slip past the check above. In Customer mode specifically - the mode where this text would reach
    # a real customer - also refuse any page whose body contains the literal phrase "DEMO ONLY" regardless of
    # the configured notice's exact wording.
    if ($ContentMode -eq "Customer" -and $converted.Html -match '(?i)\bDEMO\s+ONLY\b') {
        throw "Guide $($guideFile.Name) contains the literal phrase 'DEMO ONLY' in its own body, and " +
            "ContentMode is Customer - remove it before a customer install. This check does not depend on " +
            "the configured SampleNotice text matching exactly."
    }
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

if ($navOrder -ne "TaskFirst") {
    Sync-GuideNavigation -SiteConnection $site -HubUrl $hubUrl -GuideLinks $guideLinks -OmittedUrls $omittedGuideUrls
}
if ($omittedGuideUrls.Count -gt 0) {
    Write-Warning "Omitted guides were removed from managed navigation. Existing guide pages are preserved; review and retire them manually if authorized."
    if (-not (Test-ManagedPageWritten $site "Copilot-Guides")) {
        Write-Warning "The existing guide hub was preserved and may still link to omitted guides. Review it; 03_Update-CoEContent.ps1 replaces managed pages."
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

    $channelFolder = Get-CoEChannelFilesFolder -TeamId $group.GroupId -Channel $channel[0] -Connection $Connection
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

$experienceRoot = Join-Path $seedRoot "Experience"
foreach ($name in @("Which-Copilot-Should-I-Use", "Agent-Lifecycle-and-Approval",
    "Where-Agents-Are-Built", "Data-Protection")) {
    $source = Join-Path $experienceRoot "$name.md"
    $converted = Convert-GuideMarkdown (Get-Content -LiteralPath $source -Raw -ErrorAction Stop)
    if (-not $converted.Title) { throw "Experience page $name needs a title." }
    # Same guard as the guide-page loop above: the kit always appends $SampleNotice itself, so a content
    # override hardcoding that same text would show it twice in Demo mode and leak verbatim to Customer.
    # Uses $configuredSampleNotice (not the live, Customer-mode-blanked $SampleNotice) and checks both the
    # raw and HTML-encoded form - see the guide-loop comment above for why both are needed.
    if ($configuredSampleNotice -and ($converted.Html -match [regex]::Escape($configuredSampleNotice) -or
        $converted.Html -match [regex]::Escape([System.Net.WebUtility]::HtmlEncode($configuredSampleNotice)))) {
        throw "Experience page $name already contains the configured SampleNotice text in its own body - " +
            "remove it there. The kit always appends the notice itself."
    }
    # Second, fixed-marker check independent of the configured notice's exact wording - see the guide-loop
    # comment above for why this is needed in addition to the configured-notice match.
    if ($ContentMode -eq "Customer" -and $converted.Html -match '(?i)\bDEMO\s+ONLY\b') {
        throw "Experience page $name contains the literal phrase 'DEMO ONLY' in its own body, and " +
            "ContentMode is Customer - remove it before a customer install."
    }
    $body = $(if ($converted.Summary) { "<p>$(Convert-MarkdownInline $converted.Summary)</p>" } else { "" }) +
        $converted.Html + "<p><em>$(Escape-Html $SampleNotice)</em></p>"
    $null = Write-ManagedPage -SiteConnection $site -Name $name -Title $converted.Title -Html $body
}
$null = Write-ManagedPage -SiteConnection $site -Name "Compare-Copilot-Tools" -Title "Compare all Copilot tools" `
    -Html ($(if ($SampleNotice) { "<p><em>$(Escape-Html $SampleNotice)</em></p>" } else { "" }) + $comparisonHtml)
foreach ($toolPageGroup in @($toolsCatalog.tools | Group-Object page)) {
    if ($toolPageGroup.Name -eq "Tool-Developer-Copilots" -and -not $developerEnabled) { continue }
    $title = switch ($toolPageGroup.Name) {
        "Tool-Researcher-and-Analyst" { "Researcher and Analyst" }
        "Tool-Developer-Copilots" { "Microsoft Foundry and GitHub Copilot" }
        default { [string]$toolPageGroup.Group[0].title }
    }
    $toolPage = Get-CoEToolPageHtml $toolPageGroup.Group $learningEnvironment
    $body = $(if ($SampleNotice) { "<p><em>$(Escape-Html $SampleNotice)</em></p>" } else { "" }) + $toolPage.Html +
        "<p><a href='$($SiteUrl.TrimEnd('/'))/SitePages/Compare-Copilot-Tools.aspx'>Compare all tools</a></p>"
    $null = Write-ManagedPage -SiteConnection $site -Name $toolPageGroup.Name -Title $title -Html $body
    $buttonOrder = 2
    foreach ($button in $toolPage.Buttons) {
        Add-CoEQuickLinksButtons -SiteConnection $site -PageName $toolPageGroup.Name -Label $button.Title `
            -Items @($button) -Order $buttonOrder
        $buttonOrder++
    }
}
$null = Write-ManagedPage -SiteConnection $site -Name "Guided-Learning" -Title "Guided learning" `
    -Html ($(if ($SampleNotice) { "<p><em>$(Escape-Html $SampleNotice)</em></p>" } else { "" }) + $guidedLandingPage.Html)
if ($guidedLandingPage.Tiles.Count) {
    Add-CoEQuickLinksButtons -SiteConnection $site -PageName "Guided-Learning" -Label "Audience tiles" `
        -Items $guidedLandingPage.Tiles -Order 2
}
foreach ($track in @(Get-CoEVisibleLearningTracks $guidedCatalog $learningEnvironment $developerEnabled)) {
    $trackPage = Get-CoELearningTrackHtml $guidedCatalog $track $SiteUrl $learningEnvironment `
        $developerEnabled $plannedPages
    $null = Write-ManagedPage -SiteConnection $site -Name $track.page -Title "$($track.name) guided learning" `
        -Html ($(if ($SampleNotice) { "<p><em>$(Escape-Html $SampleNotice)</em></p>" } else { "" }) + $trackPage.Html)
    if ($trackPage.Tiles.Count) {
        Add-CoEQuickLinksButtons -SiteConnection $site -PageName $track.page -Label "Course tiles" `
            -Items $trackPage.Tiles -Order 2
    }
}
$seriesHtml = $(if ($SampleNotice) { "<p><em>$(Escape-Html $SampleNotice)</em></p>" } else { "" }) +
    "<p>Live sessions below come from the Copilot Training Calendar. Only upcoming approved sessions appear. " +
    "If the list is empty, no sessions are approved for display yet.</p><p><a href='$(Escape-Html $calendarPageUrl)'>" +
    "Open the full Training calendar</a></p>"
$null = Write-ManagedPage -SiteConnection $site -Name "Learning-Series" -Title "Learning series" -Html $seriesHtml
$report.Experience = @{ ReviewedOn = $toolsCatalog.reviewedOn; Environment = $learningEnvironment
    DeveloperTrack = $developerEnabled; ToolCount = @($toolsCatalog.tools).Count
    LearningTracks = @(Get-CoEVisibleLearningTracks $guidedCatalog $learningEnvironment $developerEnabled |
        ForEach-Object name) }

if (@($sectionConfig.sections | Where-Object page -eq "CoE-Success-Stories").Count -eq 1) {
    Write-CoEStep "START Success Stories catalog" $SiteUrl
    $storyCatalog = Sync-CoESuccessStoryCatalog -Connection $site -SiteUrl $SiteUrl `
        -Seeds @($sectionConfig.successStories) -ResolvedReviewers $resolvedCatalogReviewers `
        -StoriesFolderUrl ([string]$storiesFolderUrl) -StoryVideoUrls $storyVideoUrls `
        -Audiences @(Get-OrgValue "StoryAudiences" @("Faculty", "Staff", "Student") | ForEach-Object { [string]$_ }) `
        -ContentMode $ContentMode
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
    Add-CoECatalogPageView $site "CoE-Training-and-Enablement" $learningCatalog $learningCatalog.Views.Page "Learning paths" `
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
$hubLinks = @(Get-CoEHubLinks $SiteUrl $availablePages $calendarLink $incidentLink $developerEnabled)
if ($RepairCapturedPages) {
    Write-CoEStep "START Home page and hub repair" $SiteUrl
    $report.HubExperience = Repair-CoEHubPages -SiteConnection $site -Links $hubLinks -Environment $learningEnvironment
    Write-CoEStep "DONE Home page and hub repair"
}
$calendar = Get-PnPList -Identity "Lists/CopilotTrainingCalendar" -Connection $site -ErrorAction Stop
$upcomingView = Get-PnPView -List $calendar -Identity "Upcoming approved sessions" -Includes ServerRelativeUrl `
    -Connection $site -ErrorAction Stop
foreach ($pageName in @("Learning-Series", "CoE-Training-and-Enablement")) {
    Add-CoEUpcomingSessionsWebPart $site $pageName $calendar $upcomingView
}
if ($RepairCapturedPages) {
    # Repair-CoEHubPages already removed the vendor's own Events web part (bound to the generic default
    # "Events" list, with no way to express "approved sessions only") from Home above, so it's always safe
    # to add the correctly-bound List web part here. Section 2/Column 1 is exactly where that vendor Events
    # web part lived (see Add-CoEUpcomingSessionsWebPart's own comment) - without this, the column it
    # vacated stayed empty while the calendar rendered elsewhere on the page.
    # Customer mode omits the web part itself (see Remove-CoEUpcomingSessionsWebPart's own comment: it
    # reserves blank space up to its row count regardless of real content, which reads as broken with zero
    # or few real sessions) and adds a "No sessions scheduled yet" heading plus the "See the full training
    # calendar" link instead, so the column never reads as a bare, unexplained link (see
    # Add-CoENoSessionsPlaceholder); Demo mode keeps the live list, accepted there since sample rows are
    # expected, and removes any leftover placeholder from an earlier Customer-mode install.
    if ($ContentMode -eq "Demo") {
        Add-CoEUpcomingSessionsWebPart $site "TrainingHome" $calendar $upcomingView -Section 2 -Column 1
        Remove-CoENoSessionsPlaceholder $site "TrainingHome"
    } else {
        Remove-CoEUpcomingSessionsWebPart $site "TrainingHome" $calendar $upcomingView
        Add-CoENoSessionsPlaceholder $site "TrainingHome" -Order 4 -Section 2 -Column 1
    }
    Add-CoECalendarLinkTextPart $site "TrainingHome" $calendarUrl -Order 5 -Section 2 -Column 1
} else {
    $homeCanvas = [string](Get-PnPFile -Url "SitePages/TrainingHome.aspx" -AsListItem -Connection $site)["CanvasContent1"]
    if ($homeCanvas -match 'Which Copilot should I use\?' -and $homeCanvas -match 'Upcoming sessions') {
        if ($ContentMode -eq "Demo") {
            Add-CoEUpcomingSessionsWebPart $site "TrainingHome" $calendar $upcomingView -Section 2 -Column 1
            Remove-CoENoSessionsPlaceholder $site "TrainingHome"
        } else {
            Remove-CoEUpcomingSessionsWebPart $site "TrainingHome" $calendar $upcomingView
            Add-CoENoSessionsPlaceholder $site "TrainingHome" -Order 4 -Section 2 -Column 1
        }
        Add-CoECalendarLinkTextPart $site "TrainingHome" $calendarUrl -Order 5 -Section 2 -Column 1
    } else {
        Write-Warning "Home was preserved and still needs the 3.7 layout. Run 03_Update-CoEContent.ps1 -Scope All -RepairCapturedPages before accepting this site."
    }
}

# Task-first groups only managed destinations; explicit alphabetical and existing-order choices remain supported.
# SharePoint's "Recent" node links to the site root, so it shows as the current page on Home; the CoE does not use it.
foreach ($recent in @(Get-PnPNavigationNode -Location QuickLaunch -Connection $site | Where-Object Title -eq "Recent")) {
    Remove-PnPNavigationNode -Identity $recent.Id -Force -Connection $site
}
if ($navOrder -eq "TaskFirst") {
    Write-CoEStep "START horizontal mega-menu navigation" $SiteUrl
    Remove-CoELegacyNavigation -Connection $site -Links $hubLinks -GuideLinks $guideLinks
    $managedParents = Sync-CoEHubNavigation -Connection $site -Links $hubLinks
}
if ($navOrder -in @("TaskFirst", "AToZ")) {
    $pinFirst = @(Get-OrgValue "NavigationPinFirst" @("Home") | ForEach-Object { [string]$_ })
    $topNodes = @(Get-PnPNavigationNode -Location QuickLaunch -Connection $site)
    $firstNodes = @(foreach ($title in $pinFirst) { $topNodes | Where-Object Title -eq $title })
    $lastNodes = @(foreach ($title in @("Site contents")) { $topNodes | Where-Object Title -eq $title })
    $pinnedIds = @($firstNodes + $lastNodes | ForEach-Object Id)
    $middle = @($topNodes | Where-Object { $_.Id -notin $pinnedIds })
    if ($navOrder -eq "TaskFirst") {
        $taskIds = @(foreach ($key in @("Get started", "Tools", "Training", "Agents",
            "Governance", "Help & community")) {
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
    if ($navOrder -eq "TaskFirst") {
        Set-PnPWeb -HorizontalQuickLaunch:$true -MegaMenuEnabled:$true -Connection $site -ErrorAction Stop
        if ($DisplayName.Length -gt 30) {
            # -f binds tighter than + (confirmed live: an earlier version of this line applied -f only to the
            # last concatenated fragment, so {0}/{1} in the first two fragments were never substituted and
            # printed as literal text) - wrap the full concatenation in its own parens before formatting it.
            Write-Warning (("The site title '{0}' is {1} characters. Titles longer than about 30 characters make " +
                "the Teams group chrome and site title more likely to crowd the mega-menu row off screen at " +
                "1366px even on a header layout that usually has room; confirm with a screenshot.") -f $DisplayName, $DisplayName.Length)
        }
        # Extended gives the title its own full-width row, separate from the Teams group chrome, so all seven
        # mega-menu sections stay visible at 1366px. Standard is the fallback if this site doesn't offer Extended
        # (it kept every section but Help visible at 1366px in review); Compact is NOT used as a fallback - an
        # earlier review already found its header hides the menu behind "..." on these same sites.
        $appliedHeaderLayout = "Extended"
        try {
            Set-PnPWebHeader -HeaderLayout Extended -Connection $site -ErrorAction Stop
        } catch {
            Write-Warning "Extended header layout is not available on this site; falling back to Standard. $_"
            Set-PnPWebHeader -HeaderLayout Standard -Connection $site -ErrorAction Stop
            $appliedHeaderLayout = "Standard"
            Confirm-CoEAdvisory -Context $advisoryContext -Id HeaderLayout -Facts @("Standard") `
                -Message "Extended header layout is unavailable; Standard is applied. PROCEED still requires a 1366px screenshot to confirm navigation is usable."
        }
        $navWeb = Get-PnPWeb -Includes HorizontalQuickLaunch,MegaMenuEnabled -Connection $site -ErrorAction Stop
        $navHeader = Get-PnPWebHeader -Connection $site -ErrorAction Stop
        if (-not $navWeb.HorizontalQuickLaunch -or -not $navWeb.MegaMenuEnabled -or
            [string]$navHeader.HeaderLayout -ne $appliedHeaderLayout) {
            throw "The Teams-connected site's horizontal mega menu and $appliedHeaderLayout header were not enabled."
        }
        # Confirmed live: SharePoint can add its own "Recycle bin" Quick Launch node as a side effect of the
        # Set-PnPWeb call above, after Remove-CoELegacyNavigation's own removal pass already ran further up
        # this script - leaving "Recycle bin" visible in the published horizontal mega menu despite that
        # earlier cleanup. Run the same removal again now that mega-menu enablement (the thing that adds it)
        # has actually happened.
        Remove-CoELegacyRecycleBinNode -Connection $site -Links $hubLinks -GuideLinks $guideLinks
        $report.Navigation.Layout = "HorizontalMegaMenu"
        $report.Navigation.HeaderLayout = $appliedHeaderLayout
        Write-CoEStep "DONE horizontal mega-menu navigation" ($desiredNodes.Count.ToString() + " top-level link(s)")
    }
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
    $folder = Get-CoEChannelFilesFolder -TeamId $group.GroupId -Channel $channel[0] -Connection $Connection
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
Disable-CoEPageComments -SiteConnection $site
Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-CoESecurityPosture -SiteUrl $SiteUrl -TeamId $group.GroupId -ExpectedVisibility $teamVisibility `
    -CoESiteSharingCapability $coeSiteSharingCapability -SettingsPath $SettingsPath `
    -OrganizationEmailDomains $organizationEmailDomains `
    -OwnerUPN ([string](Get-OrgValue "SharedChannelOwnerUPN" "")) `
    -AdditionalAllowedMembers $governanceAdditionalAllowedMembers -Connection $Connection
$report.SecurityChecks = @{ Passed = $true; VerifiedAt = [datetime]::UtcNow.ToString("o") }
$report | ConvertTo-Json -Depth 15 | Set-Content $reportPath -Encoding utf8
Write-Host "Content completion and security configuration checks passed. Browser acceptance checks are still required; this script does not claim Teams rendering."
