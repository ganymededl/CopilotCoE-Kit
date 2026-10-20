#Requires -Version 7.4
<#
.SYNOPSIS
Read-only check of a finished Copilot CoE site. Changes nothing. Exits non-zero if any check fails.

.DESCRIPTION
Run this after 02_Install-CopilotCoE.ps1 finishes (and after any 03_Update-CoEContent.ps1 run):
    .\Test-CoEInstall.ps1 -OrgPath C:\CoE-Orgs\Contoso -SiteUrl https://contoso.sharepoint.com/sites/CopilotCoE

Pass -ContentMode Customer (matching whatever mode the install itself used) to additionally assert that no
demo-only content shipped: zero SAMPLE-prefixed rows in the four seeded lists, no "DEMO ONLY" text on any
page, and no default or configured sample/demo notice phrase on any page, the site description, the Team
description, or the Team welcome post. -ContentMode is not persisted anywhere on the site itself, so this
script cannot infer it automatically - omit it to skip those checks (as every call site before 3.8.7 did).

An install is only complete when this prints "ALL CHECKS PASSED" and exits with code 0.

Checks
  1  Every CoE page exists
  2  Home has the two start links, tool cards and an upcoming-sessions list bound to the calendar
  3  The Teams site uses horizontal mega-menu labels; Training, Agents and Governance contain the right links
  4  Tool and learning pages reflect the declared environment; dates, Home links and courses are present
  5  The catalogs (three, or four with the Prompt Library) have content approval on, drafts visible to approvers only, the reviewer group holding
     the reviewer permission level, and the site Owners still holding Full Control
  6  The reader views exist and the "Open the list" links on the catalog pages open (HTTP 200)
  7  The four support routes appear as links, or as a clear "not configured" notice when the route is empty
  8  (-ContentMode Customer only) No SAMPLE-prefixed rows in Training Calendar, Agent Showcase, Department
     Champions or Success Stories; no "DEMO ONLY" text and no sample/demo notice phrase on any Site Page
     (captured pages included), the site description, the Team description, or the Team welcome post
#>
[CmdletBinding()]
param(
    [string]$OrgPath,
    [string]$SettingsPath,
    [Parameter(Mandatory)][string]$SiteUrl,
    [switch]$AllowUnconfiguredRoutes,
    [ValidateSet("Demo", "Customer")][string]$ContentMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module PnP.PowerShell -RequiredVersion 3.2.0 -ErrorAction Stop

if (-not $SettingsPath) {
    if ($OrgPath) { $SettingsPath = Join-Path $OrgPath "Deployment-Settings.json" }
    else { $SettingsPath = Join-Path $PSScriptRoot "Deployment-Settings.json" }
}
if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) { throw "Settings file not found: $SettingsPath" }
$s = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot "Internal\OrganizationProfile.ps1")
. (Join-Path $PSScriptRoot "Internal\HubExperience.ps1")
. (Join-Path $PSScriptRoot "Internal\OperatorAdvisories.ps1")
$environment = Get-CoELearningEnvironment -Settings $s
$configuredNotice = (Get-CoEOrganizationProfile -Settings $s).SampleNotice
if ($ContentMode -eq "Demo" -and -not $configuredNotice) {
    throw "ContentMode Demo requires a non-empty SampleNotice; 'none' disables the notice."
}
$expectedSampleNotice = if ($ContentMode -eq "Customer") { "" } else { $configuredNotice }
$SiteUrl = $SiteUrl.TrimEnd("/")

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Check, [string]$Item, [bool]$Ok, [string]$Detail = "") {
    $results.Add([pscustomobject]@{ Check = $Check; Item = $Item; Result = $(if ($Ok) { "PASS" } else { "FAIL" }); Detail = $Detail })
}
function Add-Warning([string]$Check, [string]$Item, [string]$Detail = "") {
    # A WARN needs the manual evidence named in its detail, not necessarily a site screenshot.
    $results.Add([pscustomobject]@{ Check = $Check; Item = $Item; Result = "WARN"; Detail = $Detail })
}
function Invoke-Section([string]$Check, [scriptblock]$Body) {
    try { & $Body }
    catch { Add-Result $Check "check could not run" $false $_.Exception.Message }
}

$admin = Connect-PnPOnline -Url ("https://" + $s.AdminFQDN) -ClientId $s.PnPClientID -Tenant $s.Tenant `
    -Interactive -PersistLogin -ReturnConnection -ErrorAction Stop
$site = Connect-PnPOnline -Url $SiteUrl -Connection $admin -ReturnConnection -ErrorAction Stop

# A signed-in REST call with a SharePoint-audience token. Page URLs reject bearer tokens (they need a browser
# session), but the REST API accepts them, and a 200 here proves the view or list can be addressed by a reader.
function Test-CoERestOpens([string]$RelativeApi) {
    try {
        $token = Get-PnPAccessToken -ResourceTypeName SharePoint -Connection $site -ErrorAction Stop
        $response = Invoke-WebRequest -Uri ($SiteUrl + "/_api/" + $RelativeApi) `
            -Headers @{ Authorization = "Bearer $token"; Accept = "application/json;odata=nometadata" } `
            -Method Get -SkipHttpErrorCheck -TimeoutSec 60 -ErrorAction Stop
        return [int]$response.StatusCode
    } catch { return 0 }
}

$pages = @(Get-PnPPage -Connection $site -ErrorAction Stop | ForEach-Object Name)
# PromptLibrary "Off" in the settings means the Copilot Prompt Library list is not expected.
$promptLibraryOn = -not ($s.PSObject.Properties["PromptLibrary"] -and [string]$s.PromptLibrary -eq "Off")
$catalogNames = @("Copilot Agent Showcase", "Copilot Learning Paths", "Copilot Success Stories")
if ($promptLibraryOn) { $catalogNames += "Copilot Prompt Library" }
$learningCatalog = Get-Content (Join-Path $PSScriptRoot "SeedContent\Experience\Guided-Learning.json") -Raw |
    ConvertFrom-Json
Invoke-Section "1 Pages" {
    $expected = @("TrainingHome.aspx", "Copilot-Guides.aspx", "CoE-Training-and-Enablement.aspx", "CoE-Success-Stories.aspx",
        "CoE-Governance-and-Responsible-AI.aspx", "CoE-Service-Catalog-and-Support.aspx", "CoE-Feedback-and-Roadmap.aspx",
        "CoE-Agent-Showcase.aspx", "Meet-your-Champions.aspx", "Give-Feedback.aspx", "Copilot-FAQs.aspx",
        "Guide-Start-in-10-Minutes.aspx", "Guide-Prompt-Library.aspx", "Technical Readiness.aspx",
        "Adoption-Best-Practices.aspx", "Copilot-on-Microsoft-Mechanics.aspx", "Meet-your-ProjectTeam.aspx",
        "Which-Copilot-Should-I-Use.aspx", "Compare-Copilot-Tools.aspx", "Guided-Learning.aspx",
        "Learning-Series.aspx", "Agent-Lifecycle-and-Approval.aspx", "Where-Agents-Are-Built.aspx",
        "Data-Protection.aspx", "Tool-Copilot-Chat.aspx", "Tool-Microsoft-365-Copilot.aspx",
        "Tool-Researcher-and-Analyst.aspx", "Tool-Copilot-Cowork.aspx", "Tool-Copilot-Studio.aspx",
        "Tool-SharePoint-Agents.aspx")
    if ($s.PSObject.Properties["EnableDeveloperTrack"] -and $s.EnableDeveloperTrack) {
        $expected += "Tool-Developer-Copilots.aspx"
    }
    foreach ($track in $learningCatalog.tracks) {
        if ($track.PSObject.Properties["environment"] -and $track.environment -ne $environment) { continue }
        if ($track.PSObject.Properties["optional"] -and $track.optional -and
            -not ($s.PSObject.Properties["EnableDeveloperTrack"] -and $s.EnableDeveloperTrack)) { continue }
        $expected += "$($track.page).aspx"
    }
    foreach ($name in $expected) { Add-Result "1 Pages" $name ($name -in $pages) $(if ($name -notin $pages) { "page is missing" } else { "" }) }
    Add-Result "1 Pages" "News-and-Updates.aspx is absent" ("News-and-Updates.aspx" -notin $pages) ""
}

Invoke-Section "2 Home" {
    $item = Get-PnPFile -Url "SitePages/TrainingHome.aspx" -AsListItem -Connection $site -ErrorAction Stop
    $rawCanvas = [string]$item["CanvasContent1"]
    $canvas = [Net.WebUtility]::HtmlDecode($rawCanvas)
    # Home keeps the vendor template's own Hero (purple, retargeted to the CoE's tiles before provisioning)
    # and section backgrounds - Repair-CoEHubPages no longer clears the page down to one plain section. The
    # vendor's own Events web part is the one exception: it binds to the generic default "Events" list and
    # cannot express "approved sessions only", so it's replaced with the same correctly-bound List web part
    # used elsewhere, and only the "Resources" Quick Links control is relabelled into "Copilot tools" in place.
    Add-Result "2 Home" "keeps the template's Hero web part" ($canvas -match 'c4bd7b2f-7b6e-4599-8485-16504575f590') ""
    # Hero tile hrefs are set pre-provisioning by Prepare-CopilotCoE.ps1, which writes each tile's page URL
    # directly into the Hero web part's serverProcessedContent.links["content[i].link"] (and
    # callToActionLink, for tile 0) before the site is provisioned from the .pnp template - confirmed working
    # on live 917 and GCC installs (every tile's link opens the right page). An earlier note here claimed
    # Hero tiles never have working navigation on any site, reasoning from a different, unused function
    # (Convert-CoEHomeHeroCanvas, which rewrote anchor hrefs post-provisioning and was never called); that
    # claim was wrong and has been removed. See CHANGE-LIST-3.8.1.
    $heroJson = $null
    foreach ($m in [regex]::Matches($rawCanvas, 'data-sp-webpartdata="([^"]*)"')) {
        $candidate = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($candidate -and $candidate.id -eq "c4bd7b2f-7b6e-4599-8485-16504575f590") { $heroJson = $candidate }
    }
    $heroTiles = @(Get-CoEHomeTiles)
    foreach ($i in 0..($heroTiles.Count - 1)) {
        $tile = $heroTiles[$i]
        $expectedUrl = "$($SiteUrl.TrimEnd('/'))/SitePages/$($tile.Page)"
        $actualUrl = if ($heroJson) {
            [string]$heroJson.serverProcessedContent.links.("content[$i].link")
        } else { "" }
        Add-Result "2 Home" "Hero tile '$($tile.Title)' links to $($tile.Page)" `
            (Test-CoESameSitePageUrl $actualUrl $expectedUrl $SiteUrl) "found: $actualUrl"
    }
    # The Hero's 5 tile labels, confirmed against its alternateText fields.
    foreach ($label in @("Start in 10 minutes", "Which Copilot should I use?", "Guided learning", "Agent Showcase", "Get help")) {
        Add-Result "2 Home" "Hero tile '$label' label is correct" ($canvas -match [regex]::Escape($label)) ""
    }
    Add-Result "2 Home" "Copilot tools Quick Links replaces the vendor Resources box" `
        ($canvas -match [regex]::Escape("Copilot tools") -and $canvas -notmatch [regex]::Escape("Get Started Guides") -and
            $canvas -notmatch [regex]::Escape("Help center")) ""
    $vendorEventsControls = @([regex]::Matches($rawCanvas, 'data-sp-webpartdata="([^"]*)"') | ForEach-Object {
        $data = [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($data -and $data.PSObject.Properties["properties"] -and
            $data.properties.PSObject.Properties["dataProviderId"] -and $data.properties.dataProviderId -eq "Event") { $data }
    })
    Add-Result "2 Home" "vendor Events web part was replaced, not left pointing at the default calendar" `
        ($vendorEventsControls.Count -eq 0) "found $($vendorEventsControls.Count)"
    $vendorImageControls = @([regex]::Matches($rawCanvas, 'data-sp-webpartdata="([^"]*)"') | ForEach-Object {
        $data = [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($data -and $data.PSObject.Properties["title"] -and $data.title -eq "Image") { $data }
    })
    Add-Result "2 Home" "vendor placeholder Image web part was replaced by Explore the CoE tiles" `
        ($vendorImageControls.Count -eq 0) "found $($vendorImageControls.Count)"
    $exploreControls = @([regex]::Matches($rawCanvas, 'data-sp-webpartdata="([^"]*)"') | ForEach-Object {
        $data = [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($data -and $data.PSObject.Properties["properties"] -and $data.properties.PSObject.Properties["layoutId"] -and
            $data.properties.layoutId -eq "Button" -and $data.properties.PSObject.Properties["items"] -and
            @($data.properties.items | ForEach-Object description) -join "|" -match "^Training") { $data }
    })
    Add-Result "2 Home" "Explore the CoE Quick Links has Training, Agents, Governance and Help & community tiles" `
        ($exploreControls.Count -eq 1 -and @($exploreControls[0].properties.items).Count -eq 4) "found $($exploreControls.Count)"
    $exploreLabels = @(if ($exploreControls.Count -eq 1) { $exploreControls[0].properties.items | ForEach-Object description })
    Add-Result "2 Home" "Explore the CoE tile label matches the shortened Help menu heading, not Help & community" `
        ($exploreLabels -contains "Help") "found labels: $($exploreLabels -join ', ')"
    Add-Result "2 Home" "welcome text replaces the vendor placeholder with the organization's sample notice" `
        ($canvas -notmatch [regex]::Escape("Champions help colleagues get the most from Copilot and Microsoft 365") -and
            (-not $expectedSampleNotice -or $canvas -match [regex]::Escape($expectedSampleNotice))) `
        "Expected notice for this content mode: '$expectedSampleNotice'"
    $resolvedOrgNoun = (Get-CoEOrganizationProfile -Settings $s).OrgNoun
    Add-Result "2 Home" "welcome sentence reads 'your <noun>'s hub', not '<noun>'s hub'" `
        ($canvas -match [regex]::Escape("This site is your $resolvedOrgNoun")) "OrgNoun: '$resolvedOrgNoun'"
    # Confirms the welcome block replaces the vendor placeholder in its OWN original slot - Section 4/Column 2,
    # the last section of the page, next to the "Meet a Champion" button in Column 1 (see
    # Set-CoEHomeWelcomeText's own comment on why that specific location, not Section 1). An earlier version
    # of this same assertion required the opposite (welcome block before Copilot tools, directly under the
    # Hero) based on a wrong assumption about where the vendor's own placeholder lived; corrected after
    # confirming the real Section/Column layout directly against a live site's PnP page-section model.
    $welcomeIndex = $canvas.IndexOf("Copilot Center of Excellence")
    $toolsIndex = $canvas.IndexOf("Copilot tools")
    Add-Result "2 Home" "welcome block renders in the last section, after Copilot tools" `
        ($welcomeIndex -ge 0 -and $toolsIndex -ge 0 -and $welcomeIndex -gt $toolsIndex) `
        "welcome at $welcomeIndex, Copilot tools at $toolsIndex"
    # Regression guard: an interrupted run (Add succeeds, Remove fails) could previously leave two matching
    # welcome blocks on Home permanently, since the next run would find the current one first and stop
    # without ever cleaning up the older duplicate. Count every occurrence of the welcome heading in the raw
    # canvas, not just whether one exists.
    $welcomeHeadingCount = ([regex]::Matches($canvas, [regex]::Escape("Copilot Center of Excellence</h2>"))).Count
    Add-Result "2 Home" "Home has exactly one welcome block, not a leftover duplicate" `
        ($welcomeHeadingCount -eq 1) "found $welcomeHeadingCount"
    foreach ($destination in @("Copilot Chat", "Microsoft 365 Copilot", "Researcher", "Analyst", "Copilot Cowork",
        "Copilot Studio", "SharePoint agents", "Compare all tools")) {
        Add-Result "2 Home" "$destination is on Home" ($canvas -match [regex]::Escape($destination)) ""
    }
    $calendar = Get-PnPList -Identity "Lists/CopilotTrainingCalendar" -Connection $site -ErrorAction Stop
    $view = Get-PnPView -List $calendar -Identity "Upcoming approved sessions" -Includes ViewQuery,RowLimit `
        -Connection $site -ErrorAction Stop
    Add-Result "2 Home" "future approved sessions only" `
        ($view.ViewQuery -match "SampleStatus" -and $view.ViewQuery -match "Approved" -and
            $view.ViewQuery -match "EventDate" -and $view.ViewQuery -match "Today" -and [int]$view.RowLimit -eq 3) ""
    foreach ($pageName in @("Learning-Series", "CoE-Training-and-Enablement")) {
        $page = Get-PnPPage -Identity $pageName -Connection $site -ErrorAction Stop
        $bound = @($page.Controls | Where-Object { $_.PSObject.Properties["PropertiesJson"] -and
            ([string]$_.PropertiesJson) -match [regex]::Escape($calendar.Id.ToString()) -and
            ([string]$_.PropertiesJson) -match [regex]::Escape($view.Id.ToString()) })
        Add-Result "2 Home" "$pageName reads upcoming sessions view" ($bound.Count -eq 1) "found $($bound.Count)"
    }
    # TrainingHome's own calendar web part is intentionally mode-dependent (see Remove-CoEUpcomingSessionsWebPart):
    # Demo installs keep it, Customer installs omit it (keeping only the "See the full training calendar" link)
    # so a real install with zero or few real sessions doesn't reserve blank space for a mostly-empty list.
    # ContentMode isn't persisted in Deployment-Settings.json (it's a CLI-only switch), so this can't assert
    # which state is "correct" for this specific site - it only guards against the one thing that's always
    # wrong regardless of mode: more than one bound copy.
    $homePage = Get-PnPPage -Identity "TrainingHome" -Connection $site -ErrorAction Stop
    $homeBound = @($homePage.Controls | Where-Object { $_.PSObject.Properties["PropertiesJson"] -and
        ([string]$_.PropertiesJson) -match [regex]::Escape($calendar.Id.ToString()) -and
        ([string]$_.PropertiesJson) -match [regex]::Escape($view.Id.ToString()) })
    Add-Result "2 Home" "TrainingHome never has more than one calendar web part" ($homeBound.Count -le 1) "found $($homeBound.Count)"
    $homeLinks = @($homePage.Controls | Where-Object { $_.PSObject.Properties["Text"] -and
        ([string]$_.Text) -match [regex]::Escape("See the full training calendar") })
    Add-Result "2 Home" "TrainingHome has exactly one 'See the full training calendar' link" ($homeLinks.Count -eq 1) "found $($homeLinks.Count)"
    # Any Approved sample row that reaches Home's "Upcoming approved sessions" list must be visibly marked as
    # a sample - the view shows only Title, EventDate and RegistrationUrl (no SampleStatus column), so the
    # title prefix is the one piece of context a viewer actually sees there. Without it, Home shows invented
    # sessions that look like real, scheduled training.
    $approvedSamples = @(Get-PnPListItem -List $calendar -Connection $site -ErrorAction Stop |
        Where-Object { [string]$_["SampleStatus"] -eq "Approved" })
    foreach ($sample in $approvedSamples) {
        Add-Result "2 Home" "Approved sample '$($sample["Title"])' is visibly marked as a sample" `
            ([string]$sample["Title"] -imatch '^SAMPLE - ') ""
    }
}

Invoke-Section "3 Navigation" {
    $nodes = @(Get-PnPNavigationNode -Location QuickLaunch -Connection $site -ErrorAction Stop)
    $titles = @($nodes | ForEach-Object Title)
    # The separate "Home" tab was removed (measured in the browser: the Teams group chrome to the right of the
    # menu row at 1366px leaves too little width for Home plus six full section labels). The site logo/title
    # and every page's own "Home / Section" breadcrumb are the ways back to Home now; shortened labels (Start,
    # Tools, Training, Agents, Governance, Help) are what actually fit the remaining space.
    $want = @("Start", "Tools", "Training", "Agents", "Governance", "Help")
    $actual = @($titles | Where-Object { $_ -in $want })
    Add-Result "3 Navigation" "section order" (($actual -join ",") -eq ($want -join ",")) "found: $($titles -join ', ')"
    Add-Result "3 Navigation" "no separate Home tab" (@($titles | Where-Object { $_ -eq "Home" }).Count -eq 0) `
        "the site logo/title and each page's Home breadcrumb are the way back to Home, not a menu tab"
    $oldRoots = @($nodes | Where-Object Title -in @("Learn", "Prompts", "Get help",
        "Training and Enablement", "Technical Resources", "Learning Series", "Recycle bin", "Department Champions",
        "Get started", "Copilot tools", "Community", "Help & community"))
    Add-Result "3 Navigation" "no old template sections" ($oldRoots.Count -eq 0) `
        $(if ($oldRoots.Count) { (@($oldRoots | ForEach-Object Title) -join ", ") } else { "" })
    if ("Site contents" -in $titles) { Add-Result "3 Navigation" "Site contents is last" ($titles[-1] -eq "Site contents") "last is '$($titles[-1])'" }
    $web = Get-PnPWeb -Includes HorizontalQuickLaunch,MegaMenuEnabled -Connection $site
    Add-Result "3 Navigation" "horizontal mega menu on Teams site" ($web.HorizontalQuickLaunch -and $web.MegaMenuEnabled) ""
    $header = Get-PnPWebHeader -Connection $site -ErrorAction Stop
    if ([string]$header.HeaderLayout -eq "Extended") {
        Add-Result "3 Navigation" "full-width header shows section labels on a separate row" $true "found: Extended"
    } else {
        # Standard and Compact are both properties PnP can confirm were *set*, but neither can be confirmed to
        # actually show every mega-menu section at 1366px from this property alone - Compact is a known-bad
        # layout on these sites, and even Standard has only been visually confirmed to keep six of seven
        # sections. Only Extended auto-passes; anything else requires a screenshot before this install is accepted.
        Add-Warning "3 Navigation" "full-width header shows section labels on a separate row" `
            "found: $([string]$header.HeaderLayout) - Extended could not be applied; confirm with a 1366px screenshot before accepting this install"
    }
    if ($s.DisplayName.Length -gt 30) {
        Add-Warning "3 Navigation" "site title is short enough to avoid menu overflow" `
            "title is $($s.DisplayName.Length) characters: '$($s.DisplayName)' - longer titles make the menu more likely to be hidden behind `"...`"; confirm with a screenshot"
    }
    Add-Result "3 Navigation" "no duplicate top-level Department Champions" `
        (@($nodes | Where-Object { $_.Title -eq "Department Champions" -and
            [string]$_.Url -match 'Meet-your-Champions\.aspx$' }).Count -eq 0) ""
    foreach ($node in $nodes) {
        Get-PnPProperty -ClientObject $node -Property Children -Connection $site | Out-Null
        if ($node.Title -in $want) {
            Add-Result "3 Navigation" "$($node.Title) is a non-linking header" `
                ([string]$node.Url -match 'linkless\.header') [string]$node.Url
        }
        $mustHave = switch ($node.Title) {
            "Training" { @("Technical readiness", "Microsoft Mechanics", "Training calendar", "Learning series", "Guided learning") }
            "Agents" { @("Agent Showcase", "Agent lifecycle and approval", "Where agents are built") }
            "Governance" { @("Data protection", "Data readiness for IT", "Measuring impact") }
            default { @() }
        }
        foreach ($name in $mustHave) {
            Add-Result "3 Navigation" "$($node.Title) / $name" `
                (@($node.Children | Where-Object Title -eq $name).Count -eq 1) ""
        }
    }
    $series = @($nodes | Where-Object Title -eq "Training" | ForEach-Object Children |
        Where-Object Title -eq "Learning series")
    Add-Result "3 Navigation" "Learning series targets its page" `
        ($series.Count -eq 1 -and ([string]$series[0].Url) -match 'Learning-Series.aspx$') ""
    if ($s.Links.DataSafetyIncident) {
        $help = @($nodes | Where-Object Title -eq "Help")
        Add-Result "3 Navigation" "incident link uses configured route" `
            ($help.Count -eq 1 -and @($help[0].Children | Where-Object {
                $_.Title -eq "Report a data or safety incident" -and $_.Url -eq $s.Links.DataSafetyIncident
            }).Count -eq 1) ""
    }
}

Invoke-Section "4 Content" {
    $reviewDate = [string](Get-Content (Join-Path $PSScriptRoot "SeedContent\Experience\Tools.json") -Raw |
        ConvertFrom-Json | ForEach-Object reviewedOn)
    $checkedPages = @("Compare-Copilot-Tools.aspx") + @($pages | Where-Object { $_ -like "Tool-*.aspx" })
    foreach ($name in $checkedPages) {
        if ($name -notin $pages) { continue }
        $item = Get-PnPFile -Url "SitePages/$name" -AsListItem -Connection $site -ErrorAction Stop
        $canvas = [Net.WebUtility]::HtmlDecode([string]$item["CanvasContent1"])
        Add-Result "4 Content" "$name has a Home and section route" `
            ($canvas -match '>Home</a> /') ""
        Add-Result "4 Content" "$name has a reviewed date" `
            ($canvas -match "Last checked:\s*$([regex]::Escape($reviewDate))") ""
    }
    foreach ($name in @("CoE-Training-and-Enablement.aspx", "CoE-Success-Stories.aspx",
        "CoE-Governance-and-Responsible-AI.aspx", "CoE-Agent-Showcase.aspx",
        "CoE-Service-Catalog-and-Support.aspx", "Guided-Learning.aspx",
        "Copilot-Guides.aspx", "Technical Readiness.aspx", "Copilot-on-Microsoft-Mechanics.aspx",
        "Adoption-Best-Practices.aspx", "Meet-your-ProjectTeam.aspx")) {
        if ($name -notin $pages) { continue }
        $item = Get-PnPFile -Url "SitePages/$name" -AsListItem -Connection $site -ErrorAction Stop
        $canvas = [Net.WebUtility]::HtmlDecode([string]$item["CanvasContent1"])
        Add-Result "4 Content" "$name has a Home and section breadcrumb" `
            ($canvas -match '>Home</a> /') ""
        # Regression guard: the breadcrumb used to print the long internal section Key ("Help & community",
        # "Get started") instead of the shortened label actually shown in the top menu ("Help", "Start").
        $breadcrumbMatch = [regex]::Match($canvas, '>Home</a> / ([^<]+)<')
        if ($breadcrumbMatch.Success) {
            $breadcrumbText = [Net.WebUtility]::HtmlDecode($breadcrumbMatch.Groups[1].Value)
            Add-Result "4 Content" "$name breadcrumb matches a top-menu heading, not the long internal section name" `
                ($breadcrumbText -in @("Start", "Tools", "Training", "Agents", "Governance", "Help")) `
                "found: '$breadcrumbText'"
        }
    }
    foreach ($name in @("CoE-Training-and-Enablement.aspx", "Guided-Learning.aspx")) {
        if ($name -notin $pages) { continue }
        $item = Get-PnPFile -Url "SitePages/$name" -AsListItem -Connection $site -ErrorAction Stop
        $canvas = [Net.WebUtility]::HtmlDecode([string]$item["CanvasContent1"])
        Add-Result "4 Content" "$name uses 'Learning paths', not the vendor's 'Role-based learning list'" `
            ($canvas -notmatch [regex]::Escape("Role-based learning list")) ""
    }
    # Regression guard: Compare-Copilot-Tools, every Tool-* page, Guided-Learning and its per-track pages,
    # Learning-Series, and the four vendor-captured pages (Adoption-Best-Practices, Meet-your-ProjectTeam,
    # Technical Readiness, Copilot-on-Microsoft-Mechanics) never showed the organization's configured sample
    # notice at all, unlike every other kit-managed page - confirmed live on a validation site.
    if ($expectedSampleNotice) {
        $noticeCheckedPages = @("Compare-Copilot-Tools.aspx", "Guided-Learning.aspx", "Learning-Series.aspx",
            "Adoption-Best-Practices.aspx", "Meet-your-ProjectTeam.aspx", "Technical Readiness.aspx",
            "Copilot-on-Microsoft-Mechanics.aspx") +
            @($pages | Where-Object { $_ -like "Tool-*.aspx" -or $_ -like "Guided-Learning-*.aspx" })
        foreach ($name in $noticeCheckedPages) {
            if ($name -notin $pages) { continue }
            $item = Get-PnPFile -Url "SitePages/$name" -AsListItem -Connection $site -ErrorAction Stop
            $canvas = [Net.WebUtility]::HtmlDecode([string]$item["CanvasContent1"])
            Add-Result "4 Content" "$name shows the configured sample notice" `
                ($canvas -match [regex]::Escape($expectedSampleNotice)) ""
        }
    }
    . (Join-Path $PSScriptRoot "Internal\AdoptionCatalogs.ps1")
    . (Join-Path $PSScriptRoot "Internal\HubExperience.ps1")
    $toolCatalog = Get-Content (Join-Path $PSScriptRoot "SeedContent\Experience\Tools.json") -Raw |
        ConvertFrom-Json
    $compare = Get-PnPFile -Url "SitePages/Compare-Copilot-Tools.aspx" -AsListItem -Connection $site -ErrorAction Stop
    $comparisonText = [Net.WebUtility]::HtmlDecode([string]$compare["CanvasContent1"])
    Add-Result "4 Content" "comparison GCC column matches environment" `
        (($environment -eq "Government") -eq $comparisonText.Contains("GCC note")) ""
    foreach ($tool in $toolCatalog.tools) {
        $name = "$($tool.page).aspx"
        if ($name -notin $pages) { continue }
        $item = Get-PnPFile -Url "SitePages/$name" -AsListItem -Connection $site -ErrorAction Stop
        $rawCanvas = [string]$item["CanvasContent1"]
        $text = [Net.WebUtility]::HtmlDecode($rawCanvas)
        $openUrl = Get-CoEToolUrl $tool openUrl $environment
        $learnUrl = Get-CoEToolUrl $tool learnUrl $environment
        $otherEnvironment = if ($environment -eq "Government") { "HigherEducation" } else { "Government" }
        $otherOpen = Get-CoEToolUrl $tool openUrl $otherEnvironment
        $otherLearn = Get-CoEToolUrl $tool learnUrl $otherEnvironment
        Add-Result "4 Content" "$($tool.title) opens the $environment entry and guidance" `
            ($text.Contains($openUrl) -and $text.Contains($learnUrl) -and
                ($openUrl -eq $otherOpen -or -not $text.Contains($otherOpen)) -and
                ($learnUrl -eq $otherLearn -or -not $text.Contains($otherLearn)) -and
                ($environment -eq "Government" -or -not $text.Contains("<strong>GCC:</strong>"))) ""
        # The "Open <tool>" action must be a real Quick Links web part in Button layout, not a styled <a> -
        # a hand-styled anchor in a Text web part always renders as a plain underlined link, because the
        # modern Text web part strips custom CSS classes on save. Checking only for the label text (as an
        # earlier version of this check did) passes even when the control is just a plain link. Matched
        # against the raw (not HTML-decoded) canvas: decoding first would unescape the JSON's own quotes and
        # break the attribute boundary this regex relies on.
        $openButtons = @([regex]::Matches($rawCanvas, 'data-sp-webpartdata="([^"]*)"') | ForEach-Object {
            $data = [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($data -and $data.PSObject.Properties["properties"] -and
                $data.properties.PSObject.Properties["layoutId"] -and $data.properties.layoutId -eq "Button" -and
                $data.properties.PSObject.Properties["items"] -and
                @($data.properties.items | Where-Object { $_.PSObject.Properties["sourceItem"] -and
                    $_.sourceItem.PSObject.Properties["url"] -and $_.sourceItem.url -eq $openUrl }).Count) { $data }
        })
        Add-Result "4 Content" "$($tool.title) Open button is a real Quick Links button, not a styled link" `
            ($openButtons.Count -eq 1) "found $($openButtons.Count)"
    }
    $learning = Get-PnPFile -Url "SitePages/Guided-Learning.aspx" -AsListItem -Connection $site -ErrorAction Stop
    $learningRawCanvas = [string]$learning["CanvasContent1"]
    $learningCanvas = [Net.WebUtility]::HtmlDecode($learningRawCanvas)
    Add-Result "4 Content" "Guided learning hub has no HTML table (audience tiles, not rows)" `
        ($learningCanvas -notmatch '<table>') ""
    $audienceTileControls = @([regex]::Matches($learningRawCanvas, 'data-sp-webpartdata="([^"]*)"') | ForEach-Object {
        $data = [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($data -and $data.PSObject.Properties["properties"] -and $data.properties.PSObject.Properties["layoutId"] -and
            $data.properties.layoutId -eq "Button") { $data }
    })
    Add-Result "4 Content" "Guided learning hub has a real Quick Links audience-tile web part" `
        ($audienceTileControls.Count -eq 1) "found $($audienceTileControls.Count)"
    foreach ($track in $learningCatalog.tracks) {
        if ($track.PSObject.Properties["environment"] -and $track.environment -ne $environment) { continue }
        if ($track.PSObject.Properties["optional"] -and $track.optional -and
            -not ($s.PSObject.Properties["EnableDeveloperTrack"] -and $s.EnableDeveloperTrack)) { continue }
        Add-Result "4 Content" "$($track.name) is selectable from Guided learning" `
            ($learningCanvas.Contains("$($track.page).aspx")) ""
        Add-Result "4 Content" "$($track.name) tile shows its Microsoft Learn course count" `
            ($learningCanvas -match [regex]::Escape("$($track.name) - $(@($track.courses).Count) Microsoft Learn courses")) ""
        $trackItem = Get-PnPFile -Url "SitePages/$($track.page).aspx" -AsListItem -Connection $site -ErrorAction Stop
        $trackRawCanvas = [string]$trackItem["CanvasContent1"]
        $trackCanvas = [Net.WebUtility]::HtmlDecode($trackRawCanvas)
        Add-Result "4 Content" "$($track.name) has the Home route" `
            ($trackCanvas -match 'SitePages/TrainingHome.aspx') ""
        Add-Result "4 Content" "$($track.name) course list has no HTML table (course tiles, not rows)" `
            ($trackCanvas -notmatch '<table>') ""
        $courseTileControls = @([regex]::Matches($trackRawCanvas, 'data-sp-webpartdata="([^"]*)"') | ForEach-Object {
            $data = [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($data -and $data.PSObject.Properties["properties"] -and $data.properties.PSObject.Properties["layoutId"] -and
                $data.properties.layoutId -eq "Button") { $data }
        })
        Add-Result "4 Content" "$($track.name) has a real Quick Links course-tile web part" `
            ($courseTileControls.Count -eq 1 -and @($courseTileControls[0].properties.items).Count -eq @($track.courses).Count) `
            "found $($courseTileControls.Count)"
        foreach ($course in $track.courses) {
            Add-Result "4 Content" "$($track.name) / $($course.title) links to Learn" `
                ($trackCanvas.Contains([string]$course.url)) ""
        }
    }
    foreach ($name in @("TrainingHome.aspx", "CoE-Service-Catalog-and-Support.aspx",
        "Guide-Who-Gets-What.aspx")) {
        if ($name -notin $pages) { continue }
        $item = Get-PnPFile -Url "SitePages/$name" -AsListItem -Connection $site -ErrorAction Stop
        Add-Result "4 Content" "$name has no license request call-to-action" `
            ([string]$item["CanvasContent1"] -notmatch 'Request (?:a |your )?(?:Copilot )?license') ""
    }
}

Invoke-Section "5 Catalogs" {
    $owners = (Get-PnPWeb -Includes AssociatedOwnerGroup -Connection $site).AssociatedOwnerGroup
    $group = Get-PnPGroup -Identity "CoE Catalog Reviewers" -Connection $site -ErrorAction SilentlyContinue
    $wantReviewer = @($s.CatalogReviewerUPNs).Count -gt 0
    if ($wantReviewer) {
        Add-Result "5 Catalogs" "reviewer group exists" ($null -ne $group) ""
        if ($group) {
            $members = @(Get-PnPGroupMember -Group "CoE Catalog Reviewers" -Connection $site | ForEach-Object { ([string]$_.LoginName).ToLowerInvariant() })
            foreach ($upn in @($s.CatalogReviewerUPNs)) {
                Add-Result "5 Catalogs" "reviewer $upn is in the group" (@($members | Where-Object { $_ -like "*$($upn.ToLowerInvariant())" }).Count -gt 0) ""
            }
        }
    }
    foreach ($name in $catalogNames) {
        $list = Get-PnPList -Identity $name -Includes EnableVersioning,EnableModeration,DraftVersionVisibility,HasUniqueRoleAssignments,RoleAssignments -Connection $site -ErrorAction SilentlyContinue
        if (-not $list) { Add-Result "5 Catalogs" $name $false "list is missing"; continue }
        Add-Result "5 Catalogs" "$name content approval on" ([bool]$list.EnableModeration) ""
        Add-Result "5 Catalogs" "$name versioning on" ([bool]$list.EnableVersioning) ""
        Add-Result "5 Catalogs" "$name drafts visible to approvers only" ([string]$list.DraftVersionVisibility -eq "Approver") "is $($list.DraftVersionVisibility)"
        $ctx = Get-PnPContext -Connection $site; $ctx.Load($list.RoleAssignments); Invoke-PnPQuery -Connection $site
        $held = @{}
        foreach ($ra in $list.RoleAssignments) {
            Get-PnPProperty -ClientObject $ra -Property Member,RoleDefinitionBindings -Connection $site | Out-Null
            $held[[int]$ra.Member.Id] = @($ra.RoleDefinitionBindings | ForEach-Object Name)
        }
        Add-Result "5 Catalogs" "$name site Owners keep Full Control" ("Full Control" -in @($held[[int]$owners.Id])) ""
        if ($wantReviewer -and $group) {
            Add-Result "5 Catalogs" "$name reviewer group holds the reviewer role" ("CoE Catalog Reviewer" -in @($held[[int]$group.Id])) ""
        }
    }
}

Invoke-Section "6 Reader views and links" {
    $expectedViews = @{
        "Copilot Agent Showcase" = @("Published", "Featured", "Review")
        "Copilot Learning Paths" = @("Learning steps", "By audience", "By path", "Required")
        "Copilot Success Stories" = @("Published", "Review") }
    if ($promptLibraryOn) { $expectedViews["Copilot Prompt Library"] = @("Prompts", "By task type", "Copilot work (license needed)", "Review") }
    foreach ($name in $expectedViews.Keys) {
        $list = Get-PnPList -Identity $name -Connection $site -ErrorAction SilentlyContinue
        if (-not $list) { continue }
        $views = @(Get-PnPView -List $list.Id -Includes ServerRelativeUrl,DefaultView -Connection $site)
        foreach ($title in $expectedViews[$name]) {
            $view = @($views | Where-Object Title -eq $title)
            Add-Result "6 Views" "$name / $title exists" ($view.Count -eq 1) ""
            if ($view.Count -eq 1) {
                $api = "web/lists/getbyid('$($list.Id)')/views/getbyid('$($view[0].Id)')?`$select=Title"
                $code = Test-CoERestOpens $api
                Add-Result "6 Views" "$name / $title can be opened" ($code -eq 200) "HTTP $code"
            }
        }
    }
    # Each catalog page must carry a list web part bound to its catalog and an "Open the list" link to a real view.
    $pageLists = [ordered]@{
        "CoE-Agent-Showcase"          = "Copilot Agent Showcase"
        "CoE-Training-and-Enablement" = "Copilot Learning Paths"
        "CoE-Success-Stories"         = "Copilot Success Stories" }
    if ($promptLibraryOn -and "Guide-Prompt-Library.aspx" -in $pages) { $pageLists["Guide-Prompt-Library"] = "Copilot Prompt Library" }
    foreach ($pageName in $pageLists.Keys) {
        $list = Get-PnPList -Identity $pageLists[$pageName] -Connection $site -ErrorAction SilentlyContinue
        $page = Get-PnPPage -Identity $pageName -Connection $site -ErrorAction SilentlyContinue
        if (-not $page -or -not $list) { Add-Result "6 Links" "$pageName catalog section" $false "page or list is missing"; continue }
        $bound = @($page.Controls | Where-Object {
            $_.PSObject.Properties["PropertiesJson"] -and ([string]$_.PropertiesJson) -match [regex]::Escape($list.Id.ToString()) })
        Add-Result "6 Links" "$pageName shows the $($pageLists[$pageName]) list" ($bound.Count -ge 1) $(if (-not $bound.Count) { "no list web part is bound to the catalog" } else { "$($bound.Count) list web part(s)" })
        $textControls = @($page.Controls | Where-Object { $_.PSObject.Properties["Text"] })
        # SharePoint saves a same-site link as a server-relative path, so resolve every link against the site first.
        $siteBase = [uri]($SiteUrl + "/")
        $hrefs = @($textControls | ForEach-Object {
            [regex]::Matches([string]$_.Text, '<a[^>]*href="([^"]+\.aspx)"[^>]*>\s*Open the list') |
                ForEach-Object { [uri]::new($siteBase, [Net.WebUtility]::HtmlDecode($_.Groups[1].Value)).AbsolutePath } } | Select-Object -Unique)
        Add-Result "6 Links" "$pageName has an Open the list link" ($hrefs.Count -ge 1) $(if (-not $hrefs.Count) { "no link found" } else { "" })
        $listViews = @(Get-PnPView -List $list.Id -Includes ServerRelativeUrl -Connection $site)
        $shownViewIds = @($bound | ForEach-Object { try { ([string]$_.PropertiesJson | ConvertFrom-Json).selectedViewId } catch { $null } } |
            Where-Object { $_ } | ForEach-Object { $_.ToString().ToLowerInvariant() })
        foreach ($path in $hrefs) {
            $viewFile = [uri]::UnescapeDataString(($path -split "/")[-1])
            $match = @($listViews | Where-Object { [uri]::UnescapeDataString([string]$_.ServerRelativeUrl) -ieq [uri]::UnescapeDataString($path) })
            $code = 0
            if ($match.Count -eq 1) { $code = Test-CoERestOpens "web/lists/getbyid('$($list.Id)')/views/getbyid('$($match[0].Id)')?`$select=Title" }
            Add-Result "6 Links" "$pageName -> $viewFile" ($code -eq 200) $(if ($match.Count -ne 1) { "link does not match any view of the catalog" } else { "HTTP $code" })
            if ($match.Count -eq 1) {
                $displayed = $match[0].Id.ToString().ToLowerInvariant() -in $shownViewIds
                Add-Result "6 Links" "$pageName -> $viewFile is a view the page displays" $displayed `
                    $(if ($displayed) { "" } else { "the link opens a different view than the list on the page" })
            }
        }
    }
}

if ($promptLibraryOn) {
    Invoke-Section "5 Catalogs" {
        $list = Get-PnPList -Identity "Copilot Prompt Library" -Connection $site -ErrorAction SilentlyContinue
        if ($list) {
            $items = @(Get-PnPListItem -List $list.Id -Fields Title,PromptText,_ModerationStatus -PageSize 500 -Connection $site)
            $approved = @($items | Where-Object { [int]$_.FieldValues["_ModerationStatus"] -eq 0 })
            Add-Result "5 Catalogs" "Copilot Prompt Library has approved prompts" ($approved.Count -gt 0) "$($approved.Count) approved of $($items.Count)"
        }
    }
}

Invoke-Section "7 Support routes" {
    $item = Get-PnPFile -Url "SitePages/Give-Feedback.aspx" -AsListItem -Connection $site -ErrorAction Stop
    $text = [string]$item["CanvasContent1"]
    $routes = [ordered]@{ ServiceDesk = "IT service desk"; TechnologyRequest = "Technology request process"
        AIGuidelines = "AI guidelines"; DataSafetyIncident = "Report a data or safety incident" }
    foreach ($key in $routes.Keys) {
        $label = [regex]::Escape($routes[$key])
        $configured = ($s.Links.PSObject.Properties[$key] -and -not [string]::IsNullOrWhiteSpace([string]$s.Links.$key))
        $match = [regex]::Match($text, '<a[^>]*href="([^"]+)"[^>]*>\s*' + $label)
        $notice = $text -match ($label + '[^<]*route not configured')
        if ($configured) {
            # SharePoint stores ":" as "&#58;" inside page text, so compare the decoded target to the setting.
            $target = if ($match.Success) { [Net.WebUtility]::HtmlDecode($match.Groups[1].Value) } else { "" }
            $expected = ([string]$s.Links.$key).Trim()
            $ok = $match.Success -and ($target.TrimEnd("/") -ieq $expected.TrimEnd("/"))
            Add-Result "7 Routes" "$key links to the configured address" $ok $(if (-not $match.Success) { "no link labelled '$($routes[$key])'" } elseif (-not $ok) { "links to '$target', expected '$expected'" } else { $target })
        } else {
            $ok = ($notice -or $AllowUnconfiguredRoutes)
            $detail = if ($notice) { "not-configured notice found" }
                elseif ($AllowUnconfiguredRoutes) { "notice absent; accepted only because -AllowUnconfiguredRoutes was supplied" }
                else { "route is empty and the page does not say so" }
            Add-Result "7 Routes" "$key is clearly marked not configured" $ok $detail
        }
    }
}

if ($ContentMode -eq "Customer") {
    Invoke-Section "8 Customer mode" {
        $advisoryContext = New-CoEAdvisoryContext -SettingsPath $SettingsPath -Tenant $s.Tenant `
            -SiteFQDN ([uri]$SiteUrl).Host -TeamAlias $s.MailNickname
        $mailboxReview = Get-CoELabSupportMailboxReview -Context $advisoryContext -SupportEmail $s.SupportEmail
        if ($mailboxReview.RequiresReview) {
            Add-Warning "8 Customer mode" "support mailbox needs organizational review" `
                ("SupportEmail: '$($s.SupportEmail)'; lab-looking mailbox: $($mailboxReview.LabLooking); " +
                 "saved target-scoped LabSupportMailbox PROCEED: $($mailboxReview.SavedProceed). " +
                 "A lab exception is not production acceptance or proof this mailbox is monitored. " +
                 "Confirm the support owner and monitoring; replace lab routes before production and review obsolete saved approvals.")
        } else {
            Add-Result "8 Customer mode" "support mailbox has no detected lab exception" $true `
                "No lab mailbox pattern or saved target-scoped PROCEED; delivery and monitoring are not verified by this check."
        }
    }
    # These checks would have caught a confirmed live bug automatically: a fresh Customer-mode install still
    # seeded 5 kit/org SAMPLE success stories because the Success Stories catalog had no ContentMode
    # awareness at all. Only runs when the caller explicitly states which mode the install used - ContentMode
    # itself is a CLI-only switch, never persisted in Deployment-Settings.json, so this script has no way to
    # infer it on its own (see the parameter help above).
    foreach ($listName in @("Copilot Training Calendar", "Copilot Agent Showcase", "Department Champions", "Copilot Success Stories")) {
        try {
            $listItems = @(Get-PnPListItem -List $listName -PageSize 500 -Connection $site -ErrorAction Stop)
            $sampleItems = @($listItems | Where-Object { ([string]$_.FieldValues["Title"]) -like "SAMPLE *" })
            Add-Result "8 Customer mode" "$listName has no SAMPLE-prefixed rows" ($sampleItems.Count -eq 0) `
                "found $($sampleItems.Count): $(($sampleItems | ForEach-Object { [string]$_.FieldValues['Title'] }) -join '; ')"
        } catch {
            Add-Result "8 Customer mode" "$listName has no SAMPLE-prefixed rows" $false "list could not be read: $($_.Exception.Message)"
        }
    }
    # Must-fix from a recapture critique: a Customer-mode install still showed the literal default
    # SampleNotice filler text ("Sample starter content for review by <OrgName>; not official policy or a
    # production commitment.") on its Team description, Team welcome post, and CoE roles and contacts page,
    # because 02_Install-CopilotCoE.ps1 passed the organization-profile-resolved (defaulted) SampleNotice to
    # Prepare-CopilotCoE.ps1 and used it directly in its own template text regardless of -ContentMode. Checks
    # both the generic default phrase and whatever notice text is actually configured in Deployment-
    # Settings.json, since Customer mode must suppress a custom configured notice just as much as the default.
    $defaultNoticePhrase = "Sample starter content for review by"
    $noticeTerms = @($defaultNoticePhrase) + $(if ($configuredNotice) { @($configuredNotice) } else { @() })

    $demoOnlyPages = @()
    $noticePages = @()
    foreach ($pageName in $pages) {
        try {
            $pg = Get-PnPPage -Identity $pageName -Connection $site -ErrorAction Stop
            $pageText = ($pg.Controls | ForEach-Object { if ($_.PSObject.Properties["Text"]) { [string]$_.Text } }) -join " "
            if ($pageText -match '(?i)\bDEMO\s+ONLY\b') { $demoOnlyPages += $pageName }
            if (@($noticeTerms | Where-Object { $pageText -match [regex]::Escape($_) }).Count) { $noticePages += $pageName }
        } catch { $demoOnlyPages += "$pageName (could not be read)" }
    }
    Add-Result "8 Customer mode" "no page contains the literal phrase 'DEMO ONLY'" ($demoOnlyPages.Count -eq 0) `
        "found on: $($demoOnlyPages -join ', ')"
    Add-Result "8 Customer mode" "no page contains a sample/demo notice phrase (captured pages included)" ($noticePages.Count -eq 0) `
        "found on: $($noticePages -join ', ')"

    $webDescription = [string](Get-PnPWeb -Includes Description -Connection $site).Description
    $descriptionHits = @($noticeTerms | Where-Object { $webDescription -match [regex]::Escape($_) })
    Add-Result "8 Customer mode" "Site description has no sample/demo notice phrase" ($descriptionHits.Count -eq 0) `
        "found: $($descriptionHits -join '; ')"

    try {
        $team = Get-PnPTeamsTeam -Identity $s.MailNickname -Connection $admin -ErrorAction Stop
        $teamDescription = [string]$team.description
        $teamHits = @($noticeTerms | Where-Object { $teamDescription -match [regex]::Escape($_) })
        Add-Result "8 Customer mode" "Team description has no sample/demo notice phrase" ($teamHits.Count -eq 0) `
            "found: $($teamHits -join '; ')"
    } catch {
        Add-Result "8 Customer mode" "Team description has no sample/demo notice phrase" $false `
            "could not be read: $($_.Exception.Message)"
    }
    try {
        $primaryChannel = Get-PnPTeamsPrimaryChannel -Team $s.MailNickname -Connection $admin -ErrorAction Stop
        $welcomeMessages = @(Get-PnPTeamsChannelMessage -Team $s.MailNickname -Channel $primaryChannel.Id -Connection $admin -ErrorAction Stop)
        $welcomeHits = @()
        foreach ($welcomeMessage in $welcomeMessages) {
            $messageText = [string]$welcomeMessage.Body.Content
            $welcomeHits += @($noticeTerms | Where-Object { $messageText -match [regex]::Escape($_) })
        }
        Add-Result "8 Customer mode" "Team welcome post has no sample/demo notice phrase" ($welcomeHits.Count -eq 0) `
            "found: $(($welcomeHits | Select-Object -Unique) -join '; ')"
    } catch {
        # Reading channel messages needs Graph ChannelMessage.Read.All, which this kit's provisioning app does
        # not request (adding it means re-consenting the app in every tenant that already uses it). Confirmed
        # live: the call fails with 403 Forbidden naming that exact missing scope. Warn instead of failing the
        # whole run on a permission gap the installer itself cannot fix; any other error still warns the same
        # way, since this check was never able to run either way and a silent pass would be worse than a WARN.
        Add-Warning "8 Customer mode" "Team welcome post has no sample/demo notice phrase" `
            "could not be read (likely missing Graph ChannelMessage.Read.All on the provisioning app): $($_.Exception.Message)"
    }
    # Must-fix from a live review: Customer mode never shows the live upcoming-sessions calendar web part
    # (see Remove-CoEUpcomingSessionsWebPart), which previously left Home's Section 2/Column 1 as a bare,
    # unexplained "See the full training calendar" link next to the full Copilot tools grid. Confirms both
    # halves of the fix: the web part is genuinely gone (not just "at most one", which the mode-agnostic
    # check above already allows for Demo installs) and the "No sessions scheduled yet" heading is present.
    $homePage = Get-PnPPage -Identity "TrainingHome" -Connection $site -ErrorAction Stop
    $calendar = Get-PnPList -Identity "Lists/CopilotTrainingCalendar" -Connection $site -ErrorAction Stop
    $view = Get-PnPView -List $calendar -Identity "Upcoming approved sessions" -Connection $site -ErrorAction Stop
    $homeCalendarWebPart = @($homePage.Controls | Where-Object { $_.PSObject.Properties["PropertiesJson"] -and
        ([string]$_.PropertiesJson) -match [regex]::Escape($calendar.Id.ToString()) -and
        ([string]$_.PropertiesJson) -match [regex]::Escape($view.Id.ToString()) })
    Add-Result "8 Customer mode" "TrainingHome has no live upcoming-sessions web part" ($homeCalendarWebPart.Count -eq 0) `
        "found $($homeCalendarWebPart.Count)"
    $noSessionsHeading = @($homePage.Controls | Where-Object { $_.PSObject.Properties["Text"] -and
        ([string]$_.Text) -match [regex]::Escape("No sessions scheduled yet") })
    Add-Result "8 Customer mode" "TrainingHome shows a 'No sessions scheduled yet' heading" ($noSessionsHeading.Count -eq 1) `
        "found $($noSessionsHeading.Count)"
}

$results | Format-Table Check, Item, Result, Detail -AutoSize -Wrap
$failed = @($results | Where-Object Result -eq "FAIL")
$warned = @($results | Where-Object Result -eq "WARN")
Write-Host ""
if ($failed.Count) {
    Write-Host ("CHECKS FAILED: {0} of {1}" -f $failed.Count, $results.Count) -ForegroundColor Red
    $failed | ForEach-Object { Write-Host ("  FAIL  {0} - {1}  {2}" -f $_.Check, $_.Item, $_.Detail) -ForegroundColor Red }
    exit 1
}
if ($warned.Count) {
    Write-Host ("{0} check(s) need manual review before this install is accepted:" -f $warned.Count) -ForegroundColor Yellow
    $warned | ForEach-Object { Write-Host ("  WARN  {0} - {1}  {2}" -f $_.Check, $_.Item, $_.Detail) -ForegroundColor Yellow }
}
$summary = "ALL CHECKS PASSED ($($results.Count))"
if ($warned.Count) { $summary += " - MANUAL REVIEW REQUIRED ($($warned.Count) WARN)" }
Write-Host $summary -ForegroundColor Green
exit 0
