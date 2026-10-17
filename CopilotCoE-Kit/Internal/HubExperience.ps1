function Get-CoESupportRoutes($Links, [string]$SiteUrl) {
    $labels = [ordered]@{
        ServiceDesk = "IT service desk"
        TechnologyRequest = "Technology request process"
        AIGuidelines = "AI guidelines"
        DataSafetyIncident = "Report a data or safety incident"
    }
    foreach ($key in $labels.Keys) {
        $value = Get-CoECatalogValue $Links $key
        if ($null -ne $value -and $value -isnot [string]) { throw "Links.$key must be a text URL." }
        $url = Resolve-CoECatalogUrl ([string]$value) "Links.$key" -AllowEmpty
        [pscustomobject]@{ Key = $key; Label = $labels[$key]; Configured = [bool]$url
            Url = $(if ($url) { $url } else { "$($SiteUrl.TrimEnd('/'))/SitePages/Give-Feedback.aspx#configured-support-routes" }) }
    }
}

function Get-CoESupportRouteHtml([object[]]$Routes) {
    $html = '<h3 id="configured-support-routes">Support and incident routes</h3><ul>'
    foreach ($route in $Routes) {
        $label = [Net.WebUtility]::HtmlEncode($route.Label)
        if ($route.Configured) {
            $html += "<li><a href=`"$([Net.WebUtility]::HtmlEncode($route.Url))`">$label</a></li>"
        } else {
            $html += "<li><strong>$label - route not configured.</strong> The organization has not supplied this destination.</li>"
        }
    }
    $html += '</ul>'
    # Fallback guidance is only useful when a route is missing; with every route configured it is noise.
    if (@($Routes | Where-Object { -not $_.Configured }).Count) {
        $html += '<p>For a data or safety concern, stop using the affected content. Use an existing approved incident route if you know it; otherwise ask for the correct route without sharing sensitive details. Do not post sensitive details in Teams, general feedback or email. This page does not submit an incident report.</p>'
    }
    return $html
}

function Get-CoEIncidentRouteUrl([object[]]$Routes) {
    $matches = @($Routes | Where-Object { $_.Key -eq "DataSafetyIncident" -and $_.Configured })
    if ($matches.Count -gt 1) { throw "More than one configured data/safety incident route was found." }
    if ($matches.Count -eq 0) { return "" }
    return [string]$matches[0].Url
}

# SharePoint saves a link as an absolute address but renders its anchor as a server-relative path, so the same
# destination legitimately appears in both forms. Two addresses are the same page when they resolve to the same
# path on the site host. A different page, host or site still compares unequal.
function Test-CoESameSitePageUrl([string]$Actual, [string]$Expected, [string]$SiteUrl) {
    if ([string]::IsNullOrWhiteSpace($Actual) -or [string]::IsNullOrWhiteSpace($Expected)) { return $false }
    $base = [uri]($SiteUrl.TrimEnd("/") + "/")
    $resolve = {
        param([string]$Value)
        $uri = $null
        if (-not [uri]::TryCreate($Value.Trim(), [UriKind]::RelativeOrAbsolute, [ref]$uri)) { return $null }
        if (-not $uri.IsAbsoluteUri) {
            if (-not $Value.StartsWith("/")) { return $null }
            $uri = [uri]::new($base, $Value)
        }
        if ($uri.Scheme -ne "https") { return $null }
        return "$($uri.Authority.ToLowerInvariant())$([uri]::UnescapeDataString($uri.AbsolutePath).ToLowerInvariant())"
    }
    $left = & $resolve $Actual
    $right = & $resolve $Expected
    return ($null -ne $left -and $left -ceq $right)
}

function Get-CoEHomeTiles([string]$CustomTilesJson = "") {
    $tiles = @(
        @{ Title = "Start in 10 minutes"; Page = "Guide-Start-in-10-Minutes.aspx"; Image = "SiteAssets/copilot/May2023/4772M365Copilot_Abstract_Light_3840x2160.jpg" },
        @{ Title = "Which Copilot should I use?"; Page = "Which-Copilot-Should-I-Use.aspx"; Image = "SiteAssets/copilot/May2023/57677MS365_future_00030.jpg" },
        @{ Title = "Guided learning"; Page = "Guided-Learning.aspx"; Image = "SiteAssets/copilot/May2023/39837M365Copilot_HeroBanner_WordApp_Prompt_1920x1080.png" },
        @{ Title = "Agent Showcase"; Page = "CoE-Agent-Showcase.aspx"; Image = "SiteAssets/_SiteTemplates/training00001/training-006.jpg" },
        @{ Title = "Get help"; Page = "CoE-Service-Catalog-and-Support.aspx"; Image = "SiteAssets/_SiteTemplates/training00001/training-002.jpg" }
    )
    if ($CustomTilesJson) {
        $parsed = $CustomTilesJson | ConvertFrom-Json
        $custom = @($parsed)
        if ($custom.Count -ne $tiles.Count) { throw "HomeTiles must list exactly $($tiles.Count) tiles." }
        for ($i = 0; $i -lt $custom.Count; $i++) {
            $title = [string](Get-CoECatalogValue $custom[$i] "title")
            $page = [string](Get-CoECatalogValue $custom[$i] "page")
            if (-not $title -or $page -notmatch '^[A-Za-z0-9-]+\.aspx$') {
                throw "HomeTiles entry $($i + 1) needs a title and a site page name."
            }
            $tiles[$i].Title = $title
            $tiles[$i].Page = $page
            $image = [string](Get-CoECatalogValue $custom[$i] "image")
            if ($image) {
                if ($image -notmatch '^SiteAssets/[A-Za-z0-9_./%-]+$' -or $image -match '(^|/)\.\.(/|$)') {
                    throw "HomeTiles image must be a file under this site's SiteAssets library."
                }
                $tiles[$i].Image = $image
            }
        }
    }
    return $tiles
}

# Fluent icon names already proven to render in this template's own Quick Links control (its six vendor-default
# items use exactly these, lower-case, matching the icon registry this template version ships with) - reused
# here instead of guessing new icon names that could silently fail to render for an unverified name.
function Get-CoEQuickLinksIconNames() {
    return @("editnote", "dietplannotebook", "bookanswers", "calendarmirrored", "library", "mail")
}

# Fixed, deliberate icon per catalog tool - not a rotation through Get-CoEQuickLinksIconNames, which used to
# assign whichever icon a tool's position happened to land on (so Copilot Studio could get the "mail" icon
# just because of where it sits in the catalog). Falls back to the first icon only for a genuinely unknown
# tool title, so a brand-new catalog entry degrades safely instead of throwing on day one.
# Only 6 icon names are proven safe (see Get-CoEQuickLinksIconNames), so with 8 always-visible grid items
# plus 2 optional developer-track items, some reuse is unavoidable. Deliberately spread the reuse so the
# pairs a live reviewer actually spotted as confusingly identical (Researcher/Analyst sitting side by side;
# SharePoint agents/Compare all tools, also adjacent) now use different icons. Remaining reuse only pairs
# items that are NOT next to each other in the grid (Microsoft 365 Copilot <-> SharePoint agents;
# Researcher <-> Compare all tools), which is a much smaller visual problem than two adjacent tiles matching.
function Get-CoEToolIconName([string]$Title) {
    $icons = @{
        "Copilot Chat" = "editnote"; "Microsoft 365 Copilot" = "dietplannotebook"
        "Researcher" = "bookanswers"; "Analyst" = "calendarmirrored"; "Copilot Cowork" = "library"
        "Copilot Studio" = "mail"; "SharePoint agents" = "dietplannotebook"
        "Microsoft Foundry" = "calendarmirrored"; "GitHub Copilot" = "mail"
        "Compare all tools" = "bookanswers"
    }
    if ($icons.ContainsKey($Title)) { return $icons[$Title] }
    return (Get-CoEQuickLinksIconNames)[0]
}

# Builds the (Title, Url, Icon) item list for the Home "Copilot tools" Quick Links control: one entry per
# installed tool (in catalog order, skipping the optional developer track unless enabled) plus a final
# "Compare all tools" entry. Each tool gets a fixed icon from Get-CoEToolIconName, not a rotating one.
function Get-CoEToolQuickLinksItems([object[]]$Tools, [object[]]$Links, [bool]$DeveloperEnabled) {
    $items = @()
    foreach ($tool in $Tools) {
        if ((Get-CoECatalogValue $tool "optional") -and -not $DeveloperEnabled) { continue }
        $link = @($Links | Where-Object Page -eq "$($tool.page).aspx" | Select-Object -First 1)
        if (-not $link.Count) { throw "Copilot tools Quick Links has no installed page for: $($tool.title)" }
        $items += [pscustomobject]@{ Title = $tool.title; Url = $link[0].Url; Icon = Get-CoEToolIconName $tool.title }
    }
    $compareLink = @($Links | Where-Object Key -eq "Compare")
    if ($compareLink.Count -ne 1) { throw "Copilot tools Quick Links needs the Compare all tools destination." }
    $items += [pscustomobject]@{ Title = "Compare all tools"; Url = $compareLink[0].Url; Icon = Get-CoEToolIconName "Compare all tools" }
    return $items
}

# Builds the (Title, Url, Icon) item list for the Home "Explore the CoE" Quick Links control: one tile per
# major section (Training, Agents, Governance, Help & community), replacing the vendor's placeholder Image
# web part in the same purple section. Each tile gets a fixed, sensible icon, not a rotating one (a rotation
# previously put a calendar icon on "Help" by coincidence of catalog order, not by design).
# Governance uses "dietplannotebook", not "editnote" - "editnote" is already the Copilot Chat tile's icon
# two sections up, and a live reviewer flagged Copilot Chat/Copilot Studio/Governance/Meet a Champion as
# a cluster of "near-identical note icons"; spreading these four across different icon names (see also
# Get-CoEToolIconName and the "Meet a Champion" Quick Links button below) fixes that without inventing an
# unverified new icon name.
function Get-CoEExploreQuickLinksItems([object[]]$Links) {
    # Tile labels must match the shortened top-nav section titles (Sync-CoEHubNavigation /
    # Get-CoEHubLinks $sectionTitles), not the longer internal section Key - "Help", not "Help & community".
    $map = @(
        @("Training", "Guided", "bookanswers"),
        @("Agents", "Showcase", "library"),
        @("Governance", "Policy", "dietplannotebook"),
        @("Help", "HelpDesk", "mail")
    )
    $items = @()
    foreach ($entry in $map) {
        $link = @($Links | Where-Object Key -eq $entry[1])
        if ($link.Count -ne 1) { throw "Explore the CoE Quick Links needs the '$($entry[0])' destination." }
        $items += [pscustomobject]@{ Title = $entry[0]; Url = $link[0].Url; Icon = $entry[2] }
    }
    return $items
}

# Rewrites a named Quick Links web part's title and items in place inside a live page's raw canvas JSON.
# Item 0 supplies the structural template (thumbnailType,
# rawPreviewImageMinCanvasWidth, ...) every item - including ones beyond the original count - is cloned from.
# Guids are only stripped for items that point off-site; same-site items keep them, matching the only other
# place this kit edits a Quick Links item (the legacy Resources-link retarget in Complete-CopilotCoE.ps1).
# Uses plain ConvertFrom-Json (PSCustomObject), not -AsHashtable: -AsHashtable needs PowerShell 7+, but the
# kit's own offline Pester harness runs under Windows PowerShell 5.1, so this stays testable there too.
function Convert-CoEQuickLinksCanvas([string]$Canvas, [string]$SiteUrl, [string]$FromTitle, [string]$ToTitle,
    [object[]]$Items) {
    $updated = [regex]::Replace($Canvas, 'data-sp-webpartdata="([^"]*)"', {
        param($match)
        $data = [Net.WebUtility]::HtmlDecode($match.Groups[1].Value) | ConvertFrom-Json
        $spc = $data.serverProcessedContent
        if (-not ($spc -and $spc.PSObject.Properties["searchablePlainTexts"] -and
                $spc.searchablePlainTexts.PSObject.Properties["title"] -and
                $spc.searchablePlainTexts.title -eq $FromTitle)) { return $match.Value }
        if (-not @($data.properties.items).Count) { throw "Quick Links control '$FromTitle' has no items to use as a template." }
        $templateJson = $data.properties.items[0] | ConvertTo-Json -Depth 30
        $plain = $spc.searchablePlainTexts
        $links = $spc.links
        foreach ($prop in @($plain.PSObject.Properties | Where-Object { $_.Name -match '^items\[\d+\]\.' })) {
            $plain.PSObject.Properties.Remove($prop.Name)
        }
        foreach ($prop in @($links.PSObject.Properties | Where-Object { $_.Name -match '^items\[\d+\]\.' })) {
            $links.PSObject.Properties.Remove($prop.Name)
        }
        $newItems = @()
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item = $templateJson | ConvertFrom-Json
            $item.id = $i + 1
            $item.description = ""
            $item | Add-Member -NotePropertyName fabricReactIcon -NotePropertyValue ([pscustomobject]@{ iconName = $Items[$i].Icon }) -Force
            $item.sourceItem | Add-Member -NotePropertyName url -NotePropertyValue $Items[$i].Url -Force
            if (([uri]$Items[$i].Url).Host -ne ([uri]$SiteUrl).Host) {
                $item.sourceItem.PSObject.Properties.Remove("guids")
                $item.sourceItem.itemType = 2
            }
            $newItems += $item
            $plain | Add-Member -NotePropertyName "items[$i].title" -NotePropertyValue $Items[$i].Title -Force
            $links | Add-Member -NotePropertyName "items[$i].sourceItem.url" -NotePropertyValue $Items[$i].Url -Force
        }
        $data.properties.items = $newItems
        $plain.title = $ToTitle
        return 'data-sp-webpartdata="' + [Net.WebUtility]::HtmlEncode(($data | ConvertTo-Json -Depth 30 -Compress)) + '"'
    })
    $matches = @([regex]::Matches($updated, 'data-sp-webpartdata="([^"]*)"') | ForEach-Object {
        $data = [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) | ConvertFrom-Json
        $spc = $data.serverProcessedContent
        if ($spc -and $spc.PSObject.Properties["searchablePlainTexts"] -and
            $spc.searchablePlainTexts.PSObject.Properties["title"] -and
            $spc.searchablePlainTexts.title -eq $ToTitle) { $data }
    })
    if ($matches.Count -ne 1) { throw "Expected exactly one '$ToTitle' Quick Links control after the update; found $($matches.Count)." }
    return $updated
}

function Get-CoEHubLinks([string]$SiteUrl, [string[]]$AvailablePages, [string]$CalendarUrl = "",
    [string]$IncidentUrl = "", [bool]$DeveloperEnabled = $false) {
    $root = $SiteUrl.TrimEnd("/")
    [pscustomobject]@{ Key = "Home"; Title = "Home"; Page = "TrainingHome.aspx"; Parent = ""
        Url = "$root/SitePages/TrainingHome.aspx"; IsLabel = $false }
    # Section Key stays the stable internal identifier used elsewhere (Parent references, Repair-CoEHubPages,
    # Test-CoEInstall); only the Title shown in the menu is shortened. Measured in the browser at 1366px: the
    # Teams group chrome (Private group / Added to favorites / member count) to the right of the menu row
    # leaves only ~610px, too little for the old full-length labels (Get started, Copilot tools, Help & community)
    # plus Home. Shortened titles plus dropping the separate Home tab (see Sync-CoEHubNavigation) are both
    # required to fit six sections in that space.
    $sectionTitles = [ordered]@{
        "Get started" = "Start"; "Tools" = "Tools"; "Training" = "Training"
        "Agents" = "Agents"; "Governance" = "Governance"; "Help & community" = "Help"
    }
    foreach ($section in $sectionTitles.Keys) {
        [pscustomobject]@{ Key = $section; Title = $sectionTitles[$section]; Page = ""; Parent = ""
            Url = "http://linkless.header/"; IsLabel = $true }
    }
    $entries = @(
        @("Start", "Start in 10 minutes", "Guide-Start-in-10-Minutes.aspx", "Get started"),
        @("Which", "Which Copilot should I use?", "Which-Copilot-Should-I-Use.aspx", "Get started"),
        @("SafeUse", "Is this OK to use?", "Guide-Is-This-OK.aspx", "Get started"),
        @("Who", "Who gets what", "Guide-Who-Gets-What.aspx", "Get started"),
        @("Compare", "Compare all tools", "Compare-Copilot-Tools.aspx", "Tools"),
        @("Chat", "Copilot Chat", "Tool-Copilot-Chat.aspx", "Tools"),
        @("Work", "Microsoft 365 Copilot", "Tool-Microsoft-365-Copilot.aspx", "Tools"),
        @("Research", "Researcher and Analyst", "Tool-Researcher-and-Analyst.aspx", "Tools"),
        @("Cowork", "Copilot Cowork", "Tool-Copilot-Cowork.aspx", "Tools"),
        @("Studio", "Copilot Studio", "Tool-Copilot-Studio.aspx", "Tools"),
        @("SPAgents", "SharePoint agents", "Tool-SharePoint-Agents.aspx", "Tools"),
        @("Developers", "Foundry and GitHub Copilot", "Tool-Developer-Copilots.aspx", "Tools"),
        @("Guided", "Guided learning", "Guided-Learning.aspx", "Training"),
        @("Paths", "Learning paths", "CoE-Training-and-Enablement.aspx", "Training"),
        @("Series", "Learning series", "Learning-Series.aspx", "Training"),
        @("Prompts", "Prompt library", "Guide-Prompt-Library.aspx", "Training"),
        @("Readiness", "Technical readiness", "Technical Readiness.aspx", "Training"),
        @("Mechanics", "Microsoft Mechanics", "Copilot-on-Microsoft-Mechanics.aspx", "Training"),
        @("Guides", "All Copilot guides", "Copilot-Guides.aspx", "Training"),
        @("Showcase", "Agent Showcase", "CoE-Agent-Showcase.aspx", "Agents"),
        @("AgentGuide", "Using and building agents", "Guide-Agents.aspx", "Agents"),
        @("Lifecycle", "Agent lifecycle and approval", "Agent-Lifecycle-and-Approval.aspx", "Agents"),
        @("Environments", "Where agents are built", "Where-Agents-Are-Built.aspx", "Agents"),
        @("Policy", "Responsible AI and policy", "CoE-Governance-and-Responsible-AI.aspx", "Governance"),
        @("Protection", "Data protection", "Data-Protection.aspx", "Governance"),
        @("DataReadiness", "Data readiness for IT", "Guide-Data-Readiness-for-IT.aspx", "Governance"),
        @("Impact", "Measuring impact", "Guide-Measuring-Impact.aspx", "Governance"),
        @("Planning", "Adoption plan", "Adoption-Best-Practices.aspx", "Governance"),
        @("Roles", "Roles and contacts", "Meet-your-ProjectTeam.aspx", "Governance"),
        @("Stories", "Success stories", "CoE-Success-Stories.aspx", "Help & community"),
        @("Champions", "Department champions", "Meet-your-Champions.aspx", "Help & community"),
        @("Toolkit", "Champions toolkit", "Guide-Champions-Toolkit.aspx", "Help & community"),
        @("HelpDesk", "Service catalog and support", "CoE-Service-Catalog-and-Support.aspx", "Help & community"),
        @("FAQ", "FAQs", "Copilot-FAQs.aspx", "Help & community"),
        @("Concerns", "Questions and concerns about AI", "Guide-Concerns-and-Myths.aspx", "Help & community"),
        @("Roadmap", "Feedback and roadmap", "CoE-Feedback-and-Roadmap.aspx", "Help & community")
    )
    foreach ($item in $entries) {
        if ($item[2] -notin $AvailablePages -or ($item[0] -eq "Developers" -and -not $DeveloperEnabled)) { continue }
        [pscustomobject]@{ Key = $item[0]; Title = $item[1]; Page = $item[2]; Parent = $item[3]
            Url = "$root/SitePages/$([uri]::EscapeDataString($item[2]))"; IsLabel = $false }
    }
    if ($CalendarUrl) {
        [pscustomobject]@{ Key = "Calendar"; Title = "Training calendar"; Page = ""; Parent = "Training"
            Url = Resolve-CoECatalogUrl $CalendarUrl "Training calendar"; IsLabel = $false }
    }
    if ($IncidentUrl) {
        [pscustomobject]@{ Key = "Incident"; Title = "Report a data or safety incident"; Page = ""; Parent = "Help & community"
            Url = Resolve-CoECatalogUrl $IncidentUrl "Links.DataSafetyIncident"; IsLabel = $false }
    }
}

function Get-CoESectionStripHtml([object[]]$Links, [string]$Page) {
    $current = @($Links | Where-Object { $_.Page -eq $Page -and $_.Parent })
    if (-not $current.Count) { return "" }
    $section = $current[0].Parent
    $homeLink = @($Links | Where-Object Key -eq "Home")
    if ($homeLink.Count -ne 1) { throw "Home link is missing from CoE navigation." }
    # The section label control (IsLabel = $true, Key = the internal section name) carries the shortened
    # Title actually shown in the top menu (for example "Help", not "Help & community" - see Get-CoEHubLinks
    # $sectionTitles). Using the raw internal Key here instead produced a breadcrumb that disagreed with the
    # menu heading on every page in the Help & community and Get started sections.
    $sectionLabel = @($Links | Where-Object { $_.Key -eq $section -and $_.IsLabel })
    if ($sectionLabel.Count -ne 1) { throw "No top-nav label found for section '$section'." }
    # The horizontal mega menu already lists every page in this section, so the breadcrumb only needs
    # "Home / Section" - a second "In this section:" row of pipe-separated links just repeats the menu.
    return '<p><a href="' + [Net.WebUtility]::HtmlEncode($homeLink[0].Url) +
        '">Home</a> / ' + [Net.WebUtility]::HtmlEncode($sectionLabel[0].Title) + '</p>'
}

function Test-CoEHomePlainSection($Page) {
    $sections = @($Page.Sections)
    return ($sections.Count -eq 1 -and [string]$sections[0].Type -eq "OneColumn" -and
        [int]$sections[0].ZoneEmphasis -eq 0 -and -not $sections[0].Collapsible)
}

function Get-CoEHomeHtml([object[]]$Links, [object[]]$Tools, [string]$SiteTitle, [string]$Notice,
    [bool]$DeveloperEnabled, [string]$Environment = "HigherEducation") {
    if ($Environment -notin @("Government", "HigherEducation")) {
        throw "LearningEnvironment must be Government or HigherEducation."
    }
    $byKey = @{}
    foreach ($link in $Links) { $byKey[$link.Key] = $link }
    foreach ($required in @("Start", "Which", "Compare", "Guided", "Showcase", "Policy", "HelpDesk", "Calendar")) {
        if (-not $byKey.ContainsKey($required)) { throw "Home requires the missing CoE destination '$required'." }
    }
    $h = { param($value) [Net.WebUtility]::HtmlEncode([string]$value) }
    $html = "<h2>Welcome to $(& $h $SiteTitle)</h2><p>Find the right Copilot tool, start safely, explore approved agents and learn what's coming up.</p>"
    if ($Notice) { $html += "<p><em>$(& $h $Notice)</em></p>" }
    $html += "<h2>Start here</h2><table><tr>"
    foreach ($item in @(@("Start", "Start in 10 minutes", "Get started with one safe task"),
        @("Which", "Which Copilot should I use?", "Find the right experience for your task"))) {
        $html += '<td><h3><a href="' + (& $h $byKey[$item[0]].Url) + '">' + (& $h $item[1]) +
            '</a></h3><p>' + (& $h $item[2]) + '</p></td>'
    }
    $html += "</tr></table><h2>Copilot tools</h2><table>"
    $cards = @()
    foreach ($tool in $Tools) {
        if ((Get-CoECatalogValue $tool "optional") -and -not $DeveloperEnabled) { continue }
        $link = @($Links | Where-Object Page -eq "$($tool.page).aspx" | Select-Object -First 1)
        if (-not $link.Count) { throw "Home tool card has no installed page: $($tool.title)" }
        $cards += [pscustomobject]@{ Title = $tool.title; Summary = $tool.bestFor; Url = $link[0].Url }
    }
    $compareSummary = if ($Environment -eq "Government") {
        "See access, location and GCC notes side by side"
    } else {
        "See access and where to open each tool side by side"
    }
    $cards += [pscustomobject]@{ Title = "Compare all tools"; Summary = $compareSummary
        Url = $byKey["Compare"].Url }
    for ($index = 0; $index -lt $cards.Count; $index++) {
        if ($index % 3 -eq 0) { $html += '<tr>' }
        $card = $cards[$index]
        $html += '<td><h3><a href="' + (& $h $card.Url) + '">' + (& $h $card.Title) +
            '</a></h3><p>' + (& $h $card.Summary) + '</p></td>'
        if ($index % 3 -eq 2) { $html += '</tr>' }
    }
    if ($cards.Count % 3) {
        for ($pad = $cards.Count % 3; $pad -lt 3; $pad++) { $html += '<td></td>' }
        $html += '</tr>'
    }
    $html += '</table>'
    $html += '<h2>Explore the CoE</h2><table><tr>'
    foreach ($block in @(@("Guided", "Learn", "Courses and training"),
        @("Showcase", "Agents", "Showcase and review"),
        @("Policy", "Governance", "Responsible use and data protection"),
        @("HelpDesk", "Help & community", "Get help, FAQs and champions"))) {
        $html += '<td><h3><a href="' + (& $h $byKey[$block[0]].Url) + '">' + (& $h $block[1]) +
            '</a></h3><p>' + (& $h $block[2]) + '</p></td>'
    }
    $html += '</tr></table><h2>Upcoming sessions</h2><p>The next approved sessions appear below from the Copilot Training Calendar. ' +
        'If the list is empty, no upcoming sessions are approved for display.</p><p><a href="' +
        (& $h $byKey["Calendar"].Url) + '">Open the full Training calendar</a></p>'
    return $html
}

# A tool page's "learn more" link must be labeled after where it actually goes, not after a generic
# "Microsoft Learn" assumption - a live reviewer caught Researcher, Analyst and SharePoint agents labeled
# "Microsoft Learn: ... documentation" while their catalog learnUrl actually points to support.microsoft.com
# (GitHub Copilot has the same problem pointing at docs.github.com). Driven by the URL's own host, not a
# per-tool exception list, so any future catalog entry whose learnUrl lands on a different host is labeled
# correctly on day one instead of needing another manual fix here.
function Get-CoELearnLinkLabel([string]$Url) {
    $host_ = try { ([uri]$Url).Host } catch { "" }
    if ($host_ -eq "support.microsoft.com") { return "Microsoft Support" }
    if ($host_ -like "*.github.com" -or $host_ -eq "github.com") { return "GitHub Docs" }
    return "Microsoft Learn"
}

function Get-CoEToolUrl($Tool, [ValidateSet("openUrl", "learnUrl")][string]$Key, [string]$Environment) {
    if ($Environment -notin @("Government", "HigherEducation")) {
        throw "LearningEnvironment must be Government or HigherEducation."
    }
    $governmentKey = if ($Key -eq "openUrl") { "governmentUrl" } else { "governmentLearnUrl" }
    $url = if ($Environment -eq "Government") { [string](Get-CoECatalogValue $Tool $governmentKey) } else { "" }
    if (-not $url) { $url = [string](Get-CoECatalogValue $Tool $Key) }
    if (-not $url) { throw "Tool '$($Tool.title)' has no $Key for $Environment." }
    return $url
}

function Get-CoEToolPageHtml([object[]]$Tools, [string]$Environment) {
    $h = { param($value) [Net.WebUtility]::HtmlEncode([string]$value) }
    # A single-tool page's own title already matches the heading SharePoint shows above the content (with a
    # visible gap between them), so skip the redundant in-body heading there. Shared multi-tool pages (for
    # example Researcher and Analyst) use a combined page title, so each tool still needs its own heading.
    $showHeadings = (@($Tools).Count -gt 1)
    $body = ""
    $buttons = @()
    foreach ($tool in $Tools) {
        $openUrl = Get-CoEToolUrl $tool openUrl $Environment
        $learnUrl = Get-CoEToolUrl $tool learnUrl $Environment
        if ($showHeadings) { $body += "<h2>$(& $h $tool.title)</h2>" }
        # Three-bullet "when to use" structure (best for / access / where), not a single run-on sentence -
        # the same underlying Tools.json fields as before, just laid out so a thin page reads as a real page
        # instead of a terse paragraph. No new claims: every bullet is a field already in the catalog.
        $body += "<p>$(& $h $tool.description)</p><ul>" +
            "<li><strong>Best for:</strong> $(& $h $tool.bestFor)</li>" +
            "<li><strong>Access:</strong> $(& $h $tool.access)</li>" +
            "<li><strong>Where:</strong> $(& $h $tool.where)</li>"
        if ($Environment -eq "Government") { $body += "<li><strong>GCC:</strong> $(& $h $tool.gcc)</li>" }
        $body += "</ul>"
        $envSuffix = if ($Environment -eq "Government") { " (GCC)" } else { "" }
        # The "Open <tool>" action needs to be a real SharePoint button, not a styled <a>: modern Text web
        # parts strip custom CSS classes on save, so a hand-styled anchor always renders as a plain underlined
        # link regardless of the class attribute. A genuine button requires a separate web part (added by the
        # caller via Add-CoEQuickLinksButtons); this function only returns what that button needs to say and link to.
        # Link text names the actual destination ("Microsoft Learn: <tool> documentation"), not the generic
        # "Microsoft guidance" every tool page previously repeated - screen readers announce link text out of
        # context, so identical text pointing to different destinations is an accessibility problem. The
        # "Microsoft Learn" / "Microsoft Support" / "GitHub Docs" prefix is derived from the URL itself (see
        # Get-CoELearnLinkLabel) so the label can never drift from where the link actually goes.
        $learnLabel = Get-CoELearnLinkLabel $learnUrl
        $body += "<p><a href='$(& $h $learnUrl)' style='font-size:smaller'>$(& $h $learnLabel): $(& $h $tool.title) documentation</a></p>"
        $buttons += [pscustomobject]@{ Title = "Open $($tool.title)$envSuffix"; Url = $openUrl
            Icon = (Get-CoEQuickLinksIconNames)[$buttons.Count % (Get-CoEQuickLinksIconNames).Count] }
    }
    return [pscustomobject]@{ Html = $body; Buttons = $buttons }
}

function Get-CoEToolComparisonHtml([object[]]$Tools, [string]$SiteUrl, [bool]$DeveloperEnabled,
    [string]$Environment) {
    $h = { param($value) [Net.WebUtility]::HtmlEncode([string]$value) }
    if ($Environment -notin @("Government", "HigherEducation")) {
        throw "LearningEnvironment must be Government or HigherEducation."
    }
    $html = "<p>The Microsoft Copilot app is an interface. Microsoft 365 Copilot remains the paid product and license. " +
        "Availability depends on your tenant and cloud; a public feature listing does not assign a license.</p>" +
        "<table><tr><th>Tool</th><th>Best for</th><th>Access</th><th>Where to open it</th>"
    if ($Environment -eq "Government") { $html += "<th>GCC note</th>" }
    $html += "</tr>"
    foreach ($tool in $Tools) {
        $link = if ((Get-CoECatalogValue $tool "optional") -and -not $DeveloperEnabled) {
            Get-CoEToolUrl $tool learnUrl $Environment
        }
            else { "$($SiteUrl.TrimEnd('/'))/SitePages/$($tool.page).aspx" }
        $html += '<tr><td><a href="' + (& $h $link) + '">' + (& $h $tool.title) + '</a></td><td>' +
            (& $h $tool.bestFor) + '</td><td>' + (& $h $tool.access) + '</td><td>' +
            (& $h $tool.where) + '</td>'
        if ($Environment -eq "Government") { $html += '<td>' + (& $h $tool.gcc) + '</td>' }
        $html += '</tr>'
    }
    return $html + '</table>'
}

function Get-CoEVisibleLearningTracks($Catalog, [string]$Environment, [bool]$DeveloperEnabled) {
    if ($Environment -notin @("Government", "HigherEducation")) { throw "LearningEnvironment must be Government or HigherEducation." }
    foreach ($track in $Catalog.tracks) {
        $targetEnvironment = Get-CoECatalogValue $track "environment"
        if ($targetEnvironment -and $targetEnvironment -ne $Environment) { continue }
        if ((Get-CoECatalogValue $track "optional") -and -not $DeveloperEnabled) { continue }
        if ($track.page -notmatch '^Guided-Learning-[A-Za-z0-9-]+$') {
            throw "Learning track '$($track.name)' has an invalid page name."
        }
        if (@($track.courses).Count -lt 3 -or @($track.courses).Count -gt 5) {
            throw "Learning track '$($track.name)' must have three to five Microsoft Learn courses."
        }
        $track
    }
}

function Get-CoETrackAudience($Track, [string]$Environment) {
    # Some tracks (for example "Everyone") are shown in both environments but need higher-ed-specific
    # wording, especially when another track (Students) already covers part of that audience separately.
    if ($Environment -eq "HigherEducation" -and (Get-CoECatalogValue $Track "higherEducationAudience")) {
        return [string](Get-CoECatalogValue $Track "higherEducationAudience")
    }
    return [string]$Track.audience
}

# Audience strings (for example "All faculty and staff") are written in title case for standalone card
# headings; mid-sentence uses like "For <audience>" need a lowercase first letter to read correctly.
function ConvertTo-CoESentenceCaseAudience([string]$Audience) {
    if ([string]::IsNullOrEmpty($Audience)) { return $Audience }
    return $Audience.Substring(0, 1).ToLowerInvariant() + $Audience.Substring(1)
}

function Get-CoEGuidedLandingHtml($Catalog, [string]$SiteUrl, [string]$Environment, [bool]$DeveloperEnabled) {
    $h = { param($value) [Net.WebUtility]::HtmlEncode([string]$value) }
    $html = '<p>Choose your audience, then open Microsoft Learn course cards. ' +
        'Your organization decides which experiences and training apply. Courses are not completion records.</p>' +
        '<p>For local practice and guidance, open <a href="' +
        (& $h "$($SiteUrl.TrimEnd('/'))/SitePages/CoE-Training-and-Enablement.aspx") +
        '">Learning paths</a> after a course.</p>'
    $icons = Get-CoEQuickLinksIconNames
    $tiles = @()
    foreach ($track in @(Get-CoEVisibleLearningTracks $Catalog $Environment $DeveloperEnabled)) {
        $tiles += [pscustomobject]@{ Title = $track.name
            Description = "$(@($track.courses).Count) Microsoft Learn courses"
            Url = "$($SiteUrl.TrimEnd('/'))/SitePages/$($track.page).aspx"
            Icon = $icons[$tiles.Count % $icons.Count] }
    }
    return [pscustomobject]@{ Html = $html; Tiles = $tiles }
}

function Get-CoEGuidedLearningHtml($Catalog, [string]$SiteUrl, [string]$Environment, [bool]$DeveloperEnabled,
    [string[]]$AvailablePages) {
    $h = { param($value) [Net.WebUtility]::HtmlEncode([string]$value) }
    $context = @{
        "Start in 10 minutes" = "Guide-Start-in-10-Minutes.aspx"; "Is this OK to use?" = "Guide-Is-This-OK.aspx"
        "Prompt library" = "Guide-Prompt-Library.aspx"; "Measuring impact" = "Guide-Measuring-Impact.aspx"
        "Roles and contacts" = "Meet-your-ProjectTeam.aspx"; "Where agents are built" = "Where-Agents-Are-Built.aspx"
        "Agent lifecycle and approval" = "Agent-Lifecycle-and-Approval.aspx"; "Agent Showcase" = "CoE-Agent-Showcase.aspx"
        "Data readiness for IT" = "Guide-Data-Readiness-for-IT.aspx"; "Data protection" = "Data-Protection.aspx"
        "Technical readiness" = "Technical Readiness.aspx"; "Teaching and learning" = "Guide-Teaching-and-Learning.aspx"
        "Students and AI" = "Guide-Students-and-AI.aspx"; "Get help" = "CoE-Service-Catalog-and-Support.aspx"
        "Developer tools" = "Tool-Developer-Copilots.aspx"
    }
    $html = '<p>Choose your audience, then open the Microsoft Learn courses. These are course links, not completion records. ' +
        'Your organization decides which experiences, data and training apply. Local CoE guides are linked separately below each track.</p>'
    $icons = Get-CoEQuickLinksIconNames
    $tiles = @()
    foreach ($track in @(Get-CoEVisibleLearningTracks $Catalog $Environment $DeveloperEnabled)) {
        $html += '<h2>' + (& $h $track.name) + '</h2><p>For ' +
            (& $h (ConvertTo-CoESentenceCaseAudience (Get-CoETrackAudience $track $Environment))) +
            '</p>'
        foreach ($course in $track.courses) {
            $uri = $null
            if (-not [uri]::TryCreate([string]$course.url, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -ne "https" -or $uri.Host -ne "learn.microsoft.com" -or
                $uri.AbsolutePath -notmatch '/training/(modules|paths)/') {
                throw "Learning track '$($track.name)' has an unverified-format Microsoft Learn URL: $($course.url)"
            }
            $description = "Microsoft Learn course"
            if ($Environment -eq "Government" -and (Get-CoECatalogValue $course "governmentNote")) {
                $description = [string](Get-CoECatalogValue $course "governmentNote")
            }
            $tiles += [pscustomobject]@{ Title = $course.title; Description = $description
                Url = $uri.AbsoluteUri; Icon = $icons[$tiles.Count % $icons.Count] }
        }
        $html += '<p>CoE context (not Microsoft Learn courses): '
        $local = @()
        foreach ($name in ($track.context -split ';\s*')) {
            if (-not $context.ContainsKey($name)) { throw "Unknown CoE learning context page: $name" }
            $page = $context[$name]
            if ($page -notin $AvailablePages) { continue }
            $local += '<a href="' + (& $h "$($SiteUrl.TrimEnd('/'))/SitePages/$([uri]::EscapeDataString($page))") +
                '">' + (& $h $name) + '</a>'
        }
        $html += ($local -join " | ") + '</p>'
        # Grading/assessment guidance is specific to the Educators audience; showing it on every higher-ed
        # track (notably Students) reads as if it were addressed to students rather than to instructors.
        if ($Environment -eq "HigherEducation" -and $track.name -eq "Educators") {
            $html += '<p><strong>Do not recommend AI for grading or assessing students.</strong> Check course rules and local policy.</p>'
        }
    }
    return [pscustomobject]@{ Html = $html; Tiles = $tiles }
}

function Get-CoELearningTrackHtml($Catalog, $Track, [string]$SiteUrl, [string]$Environment,
    [bool]$DeveloperEnabled, [string[]]$AvailablePages) {
    $h = { param($value) [Net.WebUtility]::HtmlEncode([string]$value) }
    $available = @(Get-CoEVisibleLearningTracks $Catalog $Environment $DeveloperEnabled)
    if ($Track.page -notin @($available | ForEach-Object page)) {
        throw "Learning track '$($Track.name)' is not enabled for this deployment."
    }
    $html = '<p><strong>In this section:</strong> <a href="' +
        (& $h "$($SiteUrl.TrimEnd('/'))/SitePages/Guided-Learning.aspx") + '">Guided learning</a>'
    foreach ($sibling in $available) {
        $label = & $h $sibling.name
        $html += $(if ($sibling.page -eq $Track.page) { " | <strong>$label</strong>" }
            else { ' | <a href="' + (& $h "$($SiteUrl.TrimEnd('/'))/SitePages/$($sibling.page).aspx") +
                '">' + $label + '</a>' })
    }
    $html += '</p>'
    $inner = Get-CoEGuidedLearningHtml ([pscustomobject]@{ tracks = @($Track) }) $SiteUrl `
        $Environment $DeveloperEnabled $AvailablePages
    return [pscustomobject]@{ Html = $html + $inner.Html; Tiles = $inner.Tiles }
}

function Copy-CoENavigationChildren($Source, $Target, $Connection) {
    Get-PnPProperty -ClientObject $Source -Property Children -Connection $Connection -ErrorAction Stop | Out-Null
    Get-PnPProperty -ClientObject $Target -Property Children -Connection $Connection -ErrorAction Stop | Out-Null
    $children = @(foreach ($child in $Target.Children) { $child })
    foreach ($child in $Source.Children) {
        if ($Source.Title -eq "Technical Resources" -and $child.Title -in @("Mechanics Videos", "Responsible AI")) {
            continue
        }
        $matches = @($children | Where-Object { $_.Title -eq $child.Title -and
            (Get-ManagedNavigationUrl $_.Url) -eq (Get-ManagedNavigationUrl $child.Url) })
        if ($matches.Count -gt 1) { throw "Duplicate child navigation '$($child.Title)' requires review." }
        $copy = if ($matches.Count) { $matches[0] } else {
            Add-PnPNavigationNode -Location QuickLaunch -Parent $Target.Id -Title $child.Title -Url $child.Url `
                -Connection $Connection -ErrorAction Stop
        }
        Copy-CoENavigationChildren $child $copy $Connection
    }
}

function Sync-CoEHubNavigation($Connection, [object[]]$Links) {
    $parents = @{}
    $homeLink = @($Links | Where-Object Key -eq "Home")
    if ($homeLink.Count -ne 1) { throw "A single Home destination is required." }
    $siteRoot = $homeLink[0].Url -replace '/SitePages/TrainingHome\.aspx$', ''
    foreach ($link in $Links | Where-Object { -not $_.Parent }) {
        # Home is reached through the site logo/title and the "Home / Section" breadcrumb on every page, not
        # its own tab - measured in the browser, the Teams group chrome (Private group / Added to favorites /
        # member count) to the right of the menu row leaves only ~610px at 1366px, too little for Home plus
        # six shortened section labels. Dropping the Home tab (not the Home data used by other functions here)
        # is the fallback this was measured against.
        if ($link.Key -eq "Home") { continue }
        $rootNodes = @(Get-PnPNavigationNode -Location QuickLaunch -Connection $Connection -ErrorAction Stop)
        $existing = @($rootNodes | Where-Object Title -eq $link.Title)
        if ($existing.Count -gt 1) { throw "Duplicate top-level navigation '$($link.Title)' requires review." }
        if ($existing.Count) {
            $url = Get-ManagedNavigationUrl $existing[0].Url
            $expected = Get-ManagedNavigationUrl $link.Url
            if ($url -ne $expected) {
                throw "Navigation '$($link.Title)' points elsewhere. Review before replacing it with a linkless section."
            }
        }
        $node = if ($existing.Count) { $existing[0] } else {
            Add-PnPNavigationNode -Location QuickLaunch -Title $link.Title -Url $link.Url `
                -Connection $Connection -ErrorAction Stop
        }
        $parents[$link.Key] = $node
    }
    foreach ($link in $Links | Where-Object Parent) {
        if (-not $parents.ContainsKey($link.Parent)) { throw "Mega-menu section '$($link.Parent)' is missing." }
        $parent = $parents[$link.Parent]
        Get-PnPProperty -ClientObject $parent -Property Children -Connection $Connection -ErrorAction Stop | Out-Null
        $children = @(foreach ($child in $parent.Children) { $child })
        $target = Get-ManagedNavigationUrl $link.Url
        $existing = @($children | Where-Object { (Get-ManagedNavigationUrl $_.Url) -eq $target })
        if ($existing.Count -gt 1) { throw "Duplicate mega-menu destination '$($link.Title)' requires review." }
        if ($existing.Count -and $existing[0].Title -ne $link.Title) {
            $replacement = Add-PnPNavigationNode -Location QuickLaunch -Parent $parent.Id -Title $link.Title `
                -Url $link.Url -Connection $Connection -ErrorAction Stop
            Copy-CoENavigationChildren $existing[0] $replacement $Connection
            Remove-PnPNavigationNode -Identity $existing[0].Id -Force -Connection $Connection -ErrorAction Stop
            $parents[$link.Key] = $replacement
        } elseif ($existing.Count) {
            $parents[$link.Key] = $existing[0]
        } else {
            $parents[$link.Key] = Add-PnPNavigationNode -Location QuickLaunch -Parent $parent.Id `
                -Title $link.Title -Url $link.Url -Connection $Connection -ErrorAction Stop
        }
    }
    return $parents
}

function Test-CoEKnownLegacyBranch($Node, $Connection, [string[]]$Managed) {
    Get-PnPProperty -ClientObject $Node -Property Children -Connection $Connection -ErrorAction Stop | Out-Null
    foreach ($child in $Node.Children) {
        $childUrl = Get-ManagedNavigationUrl $child.Url
        if ($childUrl -notin $Managed -and
            -not ($child.Title -eq "Responsible AI" -and ([uri]$childUrl).Host -eq "www.microsoft.com")) {
            return $false
        }
        if (-not (Test-CoEKnownLegacyBranch $child $Connection $Managed)) { return $false }
    }
    return $true
}

function Remove-CoELegacyRecycleBinNode($Connection, [object[]]$Links, [object[]]$GuideLinks, [object[]]$LoadedNodes) {
    # SharePoint can add a "Recycle bin" node to Quick Launch as a side effect of Set-PnPWeb
    # -HorizontalQuickLaunch:$true -MegaMenuEnabled:$true, which runs AFTER Remove-CoELegacyNavigation's own
    # removal pass in Complete-CopilotCoE.ps1 - confirmed live: the node reappeared in the horizontal mega
    # menu even though removal had already run moments earlier, because it did not exist yet at that point
    # in the sequence. Call this a second time immediately after mega-menu enablement, not just once before
    # it, to catch that case. $LoadedNodes lets a caller that already has the Quick Launch node list (as
    # Remove-CoELegacyNavigation does) skip a redundant Get-PnPNavigationNode round trip.
    $siteRoot = (@($Links | Where-Object Key -eq "Home")[0].Url -replace '/SitePages/TrainingHome\.aspx$', '')
    $managed = @(@($Links | Where-Object { -not $_.IsLabel } | ForEach-Object { Get-ManagedNavigationUrl $_.Url }) +
        @($GuideLinks | ForEach-Object { Get-ManagedNavigationUrl $_.Url }) +
        @((Get-ManagedNavigationUrl $siteRoot), (Get-ManagedNavigationUrl "$siteRoot/SitePages/News-and-Updates.aspx"),
            (Get-ManagedNavigationUrl "$siteRoot/SitePages/Give-Feedback.aspx"),
            (Get-ManagedNavigationUrl "$siteRoot/Lists/Copilot%20Adoption%20Checklist/AllItems.aspx"),
            (Get-ManagedNavigationUrl "$siteRoot/Lists/DepartmentChampions/AllItems.aspx")))
    $roots = if ($LoadedNodes) { $LoadedNodes } else { @(Get-PnPNavigationNode -Location QuickLaunch -Connection $Connection -ErrorAction Stop) }
    foreach ($node in $roots | Where-Object Title -eq "Recycle bin") {
        $url = [uri](Get-ManagedNavigationUrl $node.Url)
        if ($url.Host -eq ([uri]$siteRoot).Host -and $url.AbsolutePath -match '/_layouts/15/RecycleBin\.aspx$' -and
            (Test-CoEKnownLegacyBranch $node $Connection $managed)) {
            Remove-PnPNavigationNode -Identity $node.Id -Force -Connection $Connection -ErrorAction Stop
        }
    }
}

function Remove-CoELegacyNavigation($Connection, [object[]]$Links, [object[]]$GuideLinks) {
    $siteRoot = (@($Links | Where-Object Key -eq "Home")[0].Url -replace '/SitePages/TrainingHome\.aspx$', '')
    $managed = @(@($Links | Where-Object { -not $_.IsLabel } | ForEach-Object { Get-ManagedNavigationUrl $_.Url }) +
        @($GuideLinks | ForEach-Object { Get-ManagedNavigationUrl $_.Url }) +
        @((Get-ManagedNavigationUrl $siteRoot), (Get-ManagedNavigationUrl "$siteRoot/SitePages/News-and-Updates.aspx"),
            (Get-ManagedNavigationUrl "$siteRoot/SitePages/Give-Feedback.aspx"),
            (Get-ManagedNavigationUrl "$siteRoot/Lists/Copilot%20Adoption%20Checklist/AllItems.aspx"),
            (Get-ManagedNavigationUrl "$siteRoot/Lists/DepartmentChampions/AllItems.aspx")))
    $legacyTitles = @("Training and Enablement", "Copilot guides", "Success Stories", "Governance",
        "Governance and Responsible AI", "Service Catalog and Support", "Feedback and Roadmap",
        "Agent Showcase", "Agents", "Technical Resources", "Adoption Planning", "Adoption and Training",
        "Learn", "Start",
        "Prompts", "Get help", "Learning Series", "Resources", "Help center", "Get Started Guides",
        "Give Feedback", "Meet a Champion", "Department Champions", "Copilot Training Calendar", "Training calendar",
        "Copilot tools", "Community", "Help", "Get started", "Help & community")
    # Label-header URLs (the shared http://linkless.header/ placeholder) are deliberately excluded from $managed
    # above, since a label has no real destination of its own. A renamed or merged header (Copilot tools -> Tools;
    # Get started -> Start; Community/Help -> Help & community -> Help) is still that same placeholder URL, so
    # it needs its own allowance here to be recognized as a removable legacy node once its title is no longer
    # part of the current link set. Like the pre-existing "Agents"/"Governance" entries above, a currently-valid
    # section title in this list is deleted and recreated fresh on every run rather than reused; Sync-CoEHubNavigation
    # recreates it immediately after, and Test-CoEKnownLegacyBranch still blocks removal if a customer added content.
    $linklessHeader = Get-ManagedNavigationUrl "http://linkless.header/"
    foreach ($node in @(Get-PnPNavigationNode -Location QuickLaunch -Connection $Connection -ErrorAction Stop)) {
        if ($node.Title -notin $legacyTitles -and $node.Title -notmatch '^Request (?:a )?license$' -and
            (Get-ManagedNavigationUrl $node.Url) -ne
                (Get-ManagedNavigationUrl "$siteRoot/SitePages/News-and-Updates.aspx")) { continue }
        $url = Get-ManagedNavigationUrl $node.Url
        if ($url -notin $managed -and $url -ne $linklessHeader) { continue }
        if (-not (Test-CoEKnownLegacyBranch $node $Connection $managed)) {
            throw "Legacy '$($node.Title)' contains customer navigation. Move it explicitly before replacing the menu."
        }
        Remove-PnPNavigationNode -Identity $node.Id -Force -Connection $Connection -ErrorAction Stop
    }
    $roots = @(Get-PnPNavigationNode -Location QuickLaunch -Connection $Connection -ErrorAction Stop)
    Remove-CoELegacyRecycleBinNode -Connection $Connection -Links $Links -GuideLinks $GuideLinks -LoadedNodes $roots
    # Prune SharePoint's auto-added "Documents"/"Conversations" shortcuts from a prior install's "Home" tab
    # BEFORE that tab itself is removed below - those shortcuts are only reachable as children of "Home", so
    # once the tab is gone there is nothing left to walk and a leftover shortcut could never be cleaned up.
    foreach ($node in $roots | Where-Object Title -eq "Home") {
        Get-PnPProperty -ClientObject $node -Property Children -Connection $Connection -ErrorAction Stop | Out-Null
        foreach ($child in @($node.Children)) {
            $childUrl = [uri](Get-ManagedNavigationUrl $child.Url)
            $document = $child.Title -eq "Documents" -and $childUrl.Host -eq ([uri]$siteRoot).Host -and
                [uri]::UnescapeDataString($childUrl.AbsolutePath) -match '/Shared Documents(/|$)'
            $conversation = $child.Title -eq "Conversations" -and
                ($childUrl.Host -match '(^|\.)outlook\.office(365)?\.com$|(^|\.)teams\.microsoft\.com$' -or
                    ($childUrl.Host -eq ([uri]$siteRoot).Host -and
                        $childUrl.AbsolutePath -match '/_layouts/15/groupstatus\.aspx$' -and
                        $childUrl.Query -match '(^[?&])Target=CONVERSATIONS(&|$)'))
            if (($document -or $conversation) -and (Test-CoEKnownLegacyBranch $child $Connection $managed)) {
                Remove-PnPNavigationNode -Identity $child.Id -Force -Connection $Connection -ErrorAction Stop
            }
        }
    }
    # The Home tab itself is retired as a deliberate layout choice (not a stale template artifact): a prior
    # install's real "Home" root tab (pointing at TrainingHome.aspx itself, not the linkless placeholder) is
    # removed once Sync-CoEHubNavigation stops recreating it, keeping the site logo/title and the per-page
    # "Home / Section" breadcrumb as the only ways back to Home. Runs last so the shortcut cleanup above
    # still has the tab's Children available to inspect. Unlike the legacy-title branches above, this does
    # NOT throw when real content remains under Home (for example an organization's own link placed there) -
    # dropping a menu tab is a cosmetic preference, not grounds to block an update over unrelated content, and
    # Sync-CoEHubNavigation no longer repopulates "Home" either way, so a left-behind tab is simply inert.
    $homeManagedUrl = Get-ManagedNavigationUrl $siteRoot
    foreach ($node in @($roots | Where-Object { $_.Title -eq "Home" -and (Get-ManagedNavigationUrl $_.Url) -eq $homeManagedUrl })) {
        Get-PnPProperty -ClientObject $node -Property Children -Connection $Connection -ErrorAction Stop | Out-Null
        if (@($node.Children).Count -eq 0) {
            Remove-PnPNavigationNode -Identity $node.Id -Force -Connection $Connection -ErrorAction Stop
        }
    }
}
