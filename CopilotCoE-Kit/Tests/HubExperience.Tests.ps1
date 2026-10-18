Set-StrictMode -Version Latest
$kitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $kitRoot "Internal\AdoptionCatalogs.ps1")
. (Join-Path $kitRoot "Internal\HubExperience.ps1")
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $kitRoot "Internal\Complete-CopilotCoE.ps1"), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$definition = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-ManagedNavigationUrl"
}, $true)
. ([scriptblock]::Create($definition.Extent.Text))
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source

function Get-PnPNavigationNode { [CmdletBinding()] param($Location, $Connection) throw "Unmocked navigation read" }
function Get-PnPProperty { [CmdletBinding()] param($ClientObject, $Property, $Connection) throw "Unmocked property read" }
function Add-PnPNavigationNode { [CmdletBinding()] param($Location, $Title, $Url, $Parent, $Connection) throw "Unmocked navigation write" }
function Remove-PnPNavigationNode { [CmdletBinding()] param($Identity, [switch]$Force, $Connection) throw "Unmocked navigation removal" }

Describe "Configured support routes" {
    BeforeEach { $script:SiteUrl = "https://example.sharepoint.com/sites/CoE" }
    It "exposes all four missing routes honestly without inventing an incident endpoint" {
        $routes = @(Get-CoESupportRoutes ([pscustomobject]@{}) $SiteUrl)
        $routes.Count | Should Be 4
        @($routes | Where-Object Configured).Count | Should Be 0
        @($routes | Where-Object Url -notmatch 'Give-Feedback.aspx#configured-support-routes$').Count | Should Be 0
        $html = Get-CoESupportRouteHtml $routes
        $html | Should Match 'id="configured-support-routes"'
        $html | Should Match 'Data or safety|data or safety'
        $html | Should Match 'route not configured'
        $html | Should Match 'does not submit an incident report'
    }
    It "encodes configured route queries and keeps ordinary support separate from safety incidents" {
        $routes = @(Get-CoESupportRoutes ([pscustomobject]@{
            ServiceDesk = "https://help.example.edu/?app=copilot&source=coe"
            DataSafetyIncident = "https://security.example.edu/report"
        }) $SiteUrl)
        (Get-CoESupportRouteHtml $routes) | Should Match 'app=copilot&amp;source=coe'
        ($routes | Where-Object Key -eq "DataSafetyIncident").Url | Should Be "https://security.example.edu/report"
    }
    It "rejects malformed, insecure and credential-bearing destinations before publication" {
        foreach ($url in @("http://example.edu/help", "javascript:alert(1)", "https://user:secret@example.edu", "<incident-url>")) {
            { Get-CoESupportRoutes ([pscustomobject]@{ ServiceDesk = $url }) $SiteUrl } | Should Throw
        }
        { Get-CoESupportRoutes ([pscustomobject]@{ ServiceDesk = 12 }) $SiteUrl } | Should Throw
    }
    It "omits a missing incident route only for validation and uses the configured route otherwise" {
        (Get-CoEIncidentRouteUrl @(Get-CoESupportRoutes ([pscustomobject]@{}) $SiteUrl)) |
            Should Be ""
        $routes = @(Get-CoESupportRoutes ([pscustomobject]@{
            DataSafetyIncident = "https://security.example.edu/report"
        }) $SiteUrl)
        (Get-CoEIncidentRouteUrl $routes) | Should Be "https://security.example.edu/report"
        { Get-CoEIncidentRouteUrl @($routes + $routes[-1]) } | Should Throw
    }
}

Describe "3.7 page and course content" {
    BeforeEach {
        $script:SiteUrl = "https://example.sharepoint.com/sites/CoE"
        $script:tools = @(Get-Content (Join-Path $kitRoot "SeedContent\Experience\Tools.json") -Raw | ConvertFrom-Json |
            ForEach-Object tools)
        $script:catalog = Get-Content (Join-Path $kitRoot "SeedContent\Experience\Guided-Learning.json") -Raw |
            ConvertFrom-Json
        $script:pages = @("Guide-Start-in-10-Minutes.aspx", "Which-Copilot-Should-I-Use.aspx",
            "Compare-Copilot-Tools.aspx", "Guided-Learning.aspx", "CoE-Training-and-Enablement.aspx", "CoE-Agent-Showcase.aspx",
            "CoE-Governance-and-Responsible-AI.aspx", "CoE-Service-Catalog-and-Support.aspx",
            "Technical Readiness.aspx", "Copilot-on-Microsoft-Mechanics.aspx", "Learning-Series.aspx",
            "Guide-Data-Readiness-for-IT.aspx", "Data-Protection.aspx",
            "Agent-Lifecycle-and-Approval.aspx", "Where-Agents-Are-Built.aspx",
            "Guide-Prompt-Library.aspx", "Guide-Measuring-Impact.aspx",
            "Guide-Teaching-and-Learning.aspx", "Guide-Students-and-AI.aspx") +
            @($script:tools | ForEach-Object { "$($_.page).aspx" })
        $script:links = @(Get-CoEHubLinks $SiteUrl $pages "$SiteUrl/Lists/CopilotTrainingCalendar/Calendar.aspx" `
            "https://security.example/report" $true)
    }
    It "links Home to the site root and shows shortened titles with Training, Agents, Governance and incident routing correct" {
        $homeLink = @($links | Where-Object Key -eq "Home")
        $homeLink.Count | Should Be 1
        $homeLink[0].Url | Should Be "$SiteUrl/SitePages/TrainingHome.aspx"
        $homeLink[0].Parent | Should BeNullOrEmpty
        # The Home tab itself is deliberately not a top-level menu entry - measured in the browser, the Teams
        # group chrome at 1366px leaves too little width for Home plus six full-length section labels, so the
        # Home Key/Url/Page stay available for other callers (breadcrumbs, Repair-CoEHubPages) while only the
        # six sections render as actual menu tabs, with shortened titles that fit the remaining space.
        (@($links | Where-Object { -not $_.Parent -and $_.IsLabel } | ForEach-Object Title) -join ",") |
            Should Be "Start,Tools,Training,Agents,Governance,Help"
        @($links | Where-Object IsLabel | Where-Object Url -ne "http://linkless.header/").Count | Should Be 0
        foreach ($key in @("Readiness", "Mechanics", "Calendar", "Series")) {
            ($links | Where-Object Key -eq $key).Parent | Should Be "Training"
        }
        ($links | Where-Object Key -eq "Protection").Parent | Should Be "Governance"
        ($links | Where-Object Key -eq "Lifecycle").Parent | Should Be "Agents"
        ($links | Where-Object Key -eq "Compare").Parent | Should Be "Tools"
        ($links | Where-Object Key -eq "HelpDesk").Parent | Should Be "Help & community"
        ($links | Where-Object Key -eq "Incident").Parent | Should Be "Help & community"
        ($links | Where-Object Key -eq "Incident").Url | Should Be "https://security.example/report"
        @(Get-CoEHubLinks $SiteUrl $pages "" "" $false | Where-Object Key -eq "Incident").Count | Should Be 0
    }
    It "renders the two introduction links, tool cards, four sections and a calendar empty state" {
        $homeHtml = Get-CoEHomeHtml $links $tools "Sample CoE" "DEMO SITE" $true
        ([regex]::Matches($homeHtml, '<h3><a href="[^"]+">(?:Start in 10 minutes|Which Copilot should I use\?)</a>')).Count | Should Be 2
        $homeHtml | Should Match 'Upcoming sessions'
        $homeHtml | Should Match 'no upcoming sessions are approved'
        $homeHtml | Should Match 'Lists/CopilotTrainingCalendar/Calendar.aspx'
        $homeHtml | Should Match 'Get help, FAQs and champions'
        $homeHtml | Should Not Match 'Get Started Guides|Help center|Request (?:a )?license'
        $homeHtml | Should Not Match 'GCC notes side by side'
        ([regex]::Matches($homeHtml, '<h3><a href="[^"]+">(?:Learn|Agents|Governance|Help &amp; community)</a>')).Count | Should Be 4
    }
    It "varies the Compare all tools card subtitle by site type" {
        $govHtml = Get-CoEHomeHtml $links $tools "Sample CoE" "DEMO SITE" $true Government
        $eduHtml = Get-CoEHomeHtml $links $tools "Sample CoE" "DEMO SITE" $true HigherEducation
        $govHtml | Should Match 'See access, location and GCC notes side by side'
        $eduHtml | Should Match 'See access and where to open each tool side by side'
        $eduHtml | Should Not Match 'GCC notes side by side'
        { Get-CoEHomeHtml $links $tools "Sample CoE" "DEMO SITE" $true "Commercial" } | Should Throw
    }
    It "rejects a Home section that can hide linked card titles" {
        $plain = [pscustomobject]@{ Sections = @([pscustomobject]@{
            Type = "OneColumn"; ZoneEmphasis = 0; Collapsible = $false
        }) }
        (Test-CoEHomePlainSection $plain) | Should Be $true
        $plain.Sections[0].ZoneEmphasis = 2
        (Test-CoEHomePlainSection $plain) | Should Be $false
        $plain.Sections[0].ZoneEmphasis = 0
        $plain.Sections += [pscustomobject]@{ Type = "OneColumn"; ZoneEmphasis = 0; Collapsible = $false }
        (Test-CoEHomePlainSection $plain) | Should Be $false
        $plain.Sections = @()
        (Test-CoEHomePlainSection $plain) | Should Be $false
    }
    It "relabels and resizes a named Quick Links control in place without touching other controls" {
        $seedItem = @{ id = 6; description = ""; altText = ""; thumbnailType = 2
            fabricReactIcon = @{ iconName = "editnote" }
            sourceItem = @{ guids = @{ siteId = "{sitecollectionid}"; webId = "{siteid}"
                    uniqueId = "00000000-0000-0000-0000-000000000000" }; itemType = 2; fileExtension = ""; progId = "" }
            rawPreviewImageMinCanvasWidth = 32767 }
        $quickLinksData = @{ id = "c70391ea-0b10-4ee9-b2b4-006d3fcad0cd"; title = "Quick links"
            properties = @{ layoutId = "Button"; items = @($seedItem, $seedItem) }
            serverProcessedContent = @{ searchablePlainTexts = @{ title = "Resources"
                    "items[0].title" = "Help center"; "items[1].title" = "Get Started Guides" }
                links = @{ "items[0].sourceItem.url" = "https://support.microsoft.com/"
                    "items[1].sourceItem.url" = "https://adoption.microsoft.com/" } } }
        $otherData = @{ id = "20745d7d-8581-4a6c-bf26-68279bc123fc"; title = "Events"
            serverProcessedContent = @{ searchablePlainTexts = @{ title = "Learning Series" } } }
        # A real Hero control has no literal "title" key in searchablePlainTexts (only "content[0].title"
        # style keys) and runs under Set-StrictMode - a live install once threw "The property 'title' cannot
        # be found" here because an earlier version of this function accessed .title without first checking
        # it exists, instead of checking only searchablePlainTexts' own presence.
        $heroData = @{ id = "c4bd7b2f-7b6e-4599-8485-16504575f590"; title = "Hero"
            serverProcessedContent = @{ searchablePlainTexts = @{ "content[0].title" = "Start in 10 minutes" } } }
        $canvas = ('<div><div data-sp-webpartdata="' + [Net.WebUtility]::HtmlEncode(($otherData | ConvertTo-Json -Depth 20 -Compress)) +
            '"></div><div data-sp-webpartdata="' + [Net.WebUtility]::HtmlEncode(($heroData | ConvertTo-Json -Depth 20 -Compress)) +
            '"></div><div data-sp-webpartdata="' + [Net.WebUtility]::HtmlEncode(($quickLinksData | ConvertTo-Json -Depth 20 -Compress)) +
            '"></div></div>')
        $items = @(
            [pscustomobject]@{ Title = "Copilot Chat"; Url = "$SiteUrl/SitePages/Tool-Copilot-Chat.aspx"; Icon = "editnote" },
            [pscustomobject]@{ Title = "Microsoft 365 Copilot"; Url = "$SiteUrl/SitePages/Tool-Microsoft-365-Copilot.aspx"; Icon = "dietplannotebook" },
            [pscustomobject]@{ Title = "Copilot Studio"; Url = "$SiteUrl/SitePages/Tool-Copilot-Studio.aspx"; Icon = "bookanswers" },
            [pscustomobject]@{ Title = "Compare all tools"; Url = "$SiteUrl/SitePages/Compare-Copilot-Tools.aspx"; Icon = "calendarmirrored" })
        $updated = Convert-CoEQuickLinksCanvas $canvas $SiteUrl "Resources" "Copilot tools" $items
        # The untouched Events and Hero controls keep their own shapes and are otherwise unmodified.
        $updated | Should Match 'Learning Series'
        $controls = @([regex]::Matches($updated, 'data-sp-webpartdata="([^"]*)"') | ForEach-Object {
            [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) | ConvertFrom-Json
        })
        $controls.Count | Should Be 3
        $toolsControl = @($controls | Where-Object { $_.serverProcessedContent.searchablePlainTexts.PSObject.Properties["title"] -and
            $_.serverProcessedContent.searchablePlainTexts.title -eq "Copilot tools" })
        $toolsControl.Count | Should Be 1
        @($toolsControl[0].properties.items).Count | Should Be 4
        for ($i = 0; $i -lt 4; $i++) {
            $toolsControl[0].serverProcessedContent.searchablePlainTexts.PSObject.Properties["items[$i].title"].Value | Should Be $items[$i].Title
            $toolsControl[0].serverProcessedContent.links.PSObject.Properties["items[$i].sourceItem.url"].Value | Should Be $items[$i].Url
            $toolsControl[0].properties.items[$i].fabricReactIcon.iconName | Should Be $items[$i].Icon
            $toolsControl[0].properties.items[$i].thumbnailType | Should Be 2
        }
        { Convert-CoEQuickLinksCanvas $canvas $SiteUrl "No Such Title" "X" $items } | Should Throw
    }
    It "builds one Copilot tools Quick Links item per installed tool plus Compare all tools, with a fixed icon per tool" {
        $items = @(Get-CoEToolQuickLinksItems $tools $links $false)
        $items.Count | Should Be (@($tools | Where-Object { -not (Get-CoECatalogValue $_ "optional") }).Count + 1)
        $items[-1].Title | Should Be "Compare all tools"
        $items[-1].Url | Should Be ($links | Where-Object Key -eq "Compare").Url
        (@($items | ForEach-Object Icon | Select-Object -Unique).Count) | Should BeGreaterThan 1
        # Regression guard: a live reviewer flagged Researcher/Analyst sharing one icon and SharePoint
        # agents/Compare all tools sharing another - both pairs sit adjacent in the grid, so a shared icon
        # read as a copy-paste mistake. Icons are assigned per tool title (not a rotation), so these two
        # specific pairs must never collide again, even though the 6-name verified-safe palette (see
        # Get-CoEQuickLinksIconNames) means some non-adjacent reuse elsewhere is still expected.
        ($items | Where-Object Title -eq "Researcher").Icon | Should Not Be (($items | Where-Object Title -eq "Analyst").Icon)
        ($items | Where-Object Title -eq "SharePoint agents").Icon | Should Not Be (($items | Where-Object Title -eq "Compare all tools").Icon)
        $itemsWithDeveloper = @(Get-CoEToolQuickLinksItems $tools $links $true)
        foreach ($title in @($items | ForEach-Object Title)) {
            ($items | Where-Object Title -eq $title).Icon | Should Be (($itemsWithDeveloper | Where-Object Title -eq $title).Icon)
        }
        # Two catalog entries share the developer-tools page (Microsoft Foundry, GitHub Copilot), so enabling
        # the developer track adds both at once.
        $itemsWithDeveloper.Count | Should Be ($items.Count + @($tools | Where-Object { Get-CoECatalogValue $_ "optional" }).Count)
    }
    It "builds four Explore the CoE items pointing at Training, Agents, Governance and Help with a fixed icon per tile" {
        $items = @(Get-CoEExploreQuickLinksItems $links)
        $items.Count | Should Be 4
        ($items | ForEach-Object Title) -join "," | Should Be "Training,Agents,Governance,Help"
        $items[0].Url | Should Be ($links | Where-Object Key -eq "Guided").Url
        $items[1].Url | Should Be ($links | Where-Object Key -eq "Showcase").Url
        $items[2].Url | Should Be ($links | Where-Object Key -eq "Policy").Url
        $items[3].Url | Should Be ($links | Where-Object Key -eq "HelpDesk").Url
        (@($items | ForEach-Object Icon | Select-Object -Unique).Count) | Should BeGreaterThan 1
        # Regression guard: icons used to cycle by tile position, so "Help" got whichever icon happened to
        # land on the fourth slot - a calendar icon, with no relation to "get help".
        ($items | Where-Object Title -eq "Help").Icon | Should Not Be "calendarmirrored"
        # Regression guard: a live reviewer flagged Copilot Chat, Copilot Studio, Governance and Meet a
        # Champion as a cluster of "near-identical note icons" - Governance previously reused Copilot Chat's
        # "editnote" icon from the Copilot tools grid two sections up. See also Get-CoEToolIconName (Copilot
        # Chat/Copilot Studio) and the "Meet a Champion" Quick Links button in Complete-CopilotCoE.ps1.
        ($items | Where-Object Title -eq "Governance").Icon | Should Not Be "editnote"
        { Get-CoEExploreQuickLinksItems @($links | Where-Object Key -ne "Policy") } | Should Throw
    }
    It "renders nine accurate comparison rows and reviewable tool pages" {
        $html = Get-CoEToolComparisonHtml $tools $SiteUrl $false Government
        ([regex]::Matches($html, '<tr>')).Count | Should Be 10
        $html | Should Match 'Azure Government is not GCC'
        $html | Should Match 'Microsoft 365 Copilot remains the paid product'
        $html | Should Not Match 'side panel|Maker license|GitHub Enterprise'
        ($tools | Where-Object title -eq "Copilot Studio").gcc | Should Match 'Available in GCC'
    }
    It "selects government entry and guidance but removes GCC-specific chrome in higher education" {
        $studio = @($tools | Where-Object title -eq "Copilot Studio")
        $chat = @($tools | Where-Object title -eq "Copilot Chat")
        $gov = Get-CoEToolPageHtml $studio Government
        $edu = Get-CoEToolPageHtml $studio HigherEducation
        $gov.Html | Should Match "href='https://learn.microsoft.com/en-us/microsoft-copilot-studio/requirements-licensing-gcc'"
        $gov.Html | Should Not Match "https://copilotstudio.microsoft.com/"
        $gov.Html | Should Match '<strong>GCC:</strong>'
        $edu.Html | Should Match "href='https://learn.microsoft.com/en-us/microsoft-copilot-studio/fundamentals-what-is-copilot-studio'"
        $edu.Html | Should Not Match "gcc.powerva.microsoft.us|requirements-licensing-gcc|<strong>GCC:</strong>"
        (Get-CoEToolPageHtml $chat Government).Html | Should Match 'microsoft-365/copilot/gov-overview'
        (Get-CoEToolPageHtml $chat HigherEducation).Html | Should Match 'https://learn.microsoft.com/en-us/copilot/overview'
        (Get-CoEToolPageHtml $chat HigherEducation).Html | Should Not Match 'gov-overview'
        (Get-CoEToolComparisonHtml $tools $SiteUrl $false HigherEducation) | Should Not Match 'GCC note|Azure Government'
        $gov.Html | Should Not Match '<h2>'
        # The "Open <tool>" action is structured button data (added live as a real Quick Links web part by
        # Add-CoEQuickLinksButtons), not a styled <a> in the HTML - a hand-styled anchor always renders as a
        # plain underlined link, because the modern Text web part strips custom CSS classes on save.
        $gov.Html | Should Not Match 'coe-button|Open Copilot Studio'
        $gov.Buttons.Count | Should Be 1
        $gov.Buttons[0].Title | Should Be "Open Copilot Studio (GCC)"
        $gov.Buttons[0].Url | Should Be "https://gcc.powerva.microsoft.us/"
        $edu.Buttons.Count | Should Be 1
        $edu.Buttons[0].Title | Should Be "Open Copilot Studio"
        $edu.Buttons[0].Url | Should Be "https://copilotstudio.microsoft.com/"
        $researcherAndAnalyst = @($tools | Where-Object page -eq "Tool-Researcher-and-Analyst")
        $shared = Get-CoEToolPageHtml $researcherAndAnalyst HigherEducation
        ([regex]::Matches($shared.Html, '<h2>')).Count | Should Be 2
        $shared.Html | Should Match '<h2>Researcher</h2>'
        $shared.Html | Should Match '<h2>Analyst</h2>'
        $shared.Buttons.Count | Should Be 2
        $shared.Buttons[0].Title | Should Be "Open Researcher"
        $shared.Buttons[1].Title | Should Be "Open Analyst"
    }
    It "labels the documentation link after where it actually goes, not a blanket 'Microsoft Learn' assumption" {
        # Regression test for a confirmed live bug: a reviewer found Researcher, Analyst and SharePoint agents
        # labeled "Microsoft Learn: ... documentation" while their catalog learnUrl actually points to
        # support.microsoft.com - and GitHub Copilot has the same mismatch, pointing at docs.github.com.
        # Get-CoELearnLinkLabel derives the label from the URL's own host, so any future catalog entry whose
        # learnUrl lands on a different host is labeled correctly without another manual fix here.
        (Get-CoELearnLinkLabel "https://learn.microsoft.com/en-us/copilot/overview") | Should Be "Microsoft Learn"
        (Get-CoELearnLinkLabel "https://support.microsoft.com/en-us/microsoft-365-copilot/get-started-with-researcher-in-microsoft-365-copilot") | Should Be "Microsoft Support"
        (Get-CoELearnLinkLabel "https://docs.github.com/en/copilot/how-tos/copilot-on-github/chat-with-copilot/chat-in-github") | Should Be "GitHub Docs"
        $researcherAndAnalyst = @($tools | Where-Object page -eq "Tool-Researcher-and-Analyst")
        $researcherHtml = (Get-CoEToolPageHtml $researcherAndAnalyst HigherEducation).Html
        $researcherHtml | Should Match 'Microsoft Support: Researcher documentation'
        $researcherHtml | Should Match 'Microsoft Support: Analyst documentation'
        $researcherHtml | Should Not Match 'Microsoft Learn: Researcher documentation|Microsoft Learn: Analyst documentation'
        $spAgents = @($tools | Where-Object title -eq "SharePoint agents")
        (Get-CoEToolPageHtml $spAgents HigherEducation).Html | Should Match 'Microsoft Support: SharePoint agents documentation'
        $githubCopilot = @($tools | Where-Object title -eq "GitHub Copilot")
        (Get-CoEToolPageHtml $githubCopilot HigherEducation).Html | Should Match 'GitHub Docs: GitHub Copilot documentation'
        $chat = @($tools | Where-Object title -eq "Copilot Chat")
        (Get-CoEToolPageHtml $chat HigherEducation).Html | Should Match 'Microsoft Learn: Copilot Chat documentation'
    }
    It "uses a full-width header for the seven section labels on a Teams site, falling back to Standard not Compact" {
        $install = Get-Content (Join-Path $kitRoot "02_Install-CopilotCoE.ps1") -Raw
        $complete = Get-Content (Join-Path $kitRoot "Internal\Complete-CopilotCoE.ps1") -Raw
        $checker = Get-Content (Join-Path $kitRoot "Test-CoEInstall.ps1") -Raw
        $install | Should Match '(?s)Set-PnPWebHeader\s+.*?-SiteLogoUrl.*?-HeaderLayout Extended'
        $install | Should Match '(?s)-HeaderLayout Extended.*?catch\s*\{.*?-HeaderLayout Standard'
        $install | Should Not Match '-HeaderLayout Compact'
        $complete | Should Match 'Set-PnPWebHeader -HeaderLayout Extended -Connection \$site'
        $complete | Should Match '(?s)-HeaderLayout Extended -Connection \$site.*?catch\s*\{.*?-HeaderLayout Standard -Connection \$site'
        $complete | Should Not Match '-HeaderLayout Compact'
        $checker | Should Match 'full-width header shows section labels on a separate row'
        $checker | Should Not Match '"Extended", "Compact"'
        $checker | Should Match 'if \(\[string\]\$header\.HeaderLayout -eq "Extended"\)'
        $checker | Should Match 'Add-Warning "3 Navigation"'
    }
    It "warns instead of auto-passing when the header is not Extended, and never fails the run for it" {
        $checker = Get-Content (Join-Path $kitRoot "Test-CoEInstall.ps1") -Raw
        $checker | Should Match '\$failed = @\(\$results \| Where-Object Result -eq "FAIL"\)'
        $checker | Should Match '\$warned = @\(\$results \| Where-Object Result -eq "WARN"\)'
        $checker | Should Match 'DisplayName\.Length -gt 30'
    }
    It "checks the live site for the new breadcrumb, not the removed 'In this section' strip" {
        # Regression guard: a live 917 install caught this once already (Test-CoEInstall.ps1 still matched the
        # literal text removed from Get-CoESectionStripHtml, so every section/tool page failed "4 Content" even
        # though the generated HTML was correct). Keep both live checks in sync with the current HTML shape.
        $checker = Get-Content (Join-Path $kitRoot "Test-CoEInstall.ps1") -Raw
        $checker | Should Not Match "'In this section:'"
        $checker | Should Match "has a Home and section route.*\n.*'>Home</a> /'"
        $checker | Should Match "has a Home and section breadcrumb.*\n.*'>Home</a> /'"
    }
    It "shows four government, six higher-ed and optional developer Learn tracks" {
        $gov = Get-CoEGuidedLearningHtml $catalog $SiteUrl Government $false $pages
        $edu = Get-CoEGuidedLearningHtml $catalog $SiteUrl HigherEducation $false $pages
        $dev = Get-CoEGuidedLearningHtml $catalog $SiteUrl Government $true $pages
        ([regex]::Matches($gov.Html, '<h2>')).Count | Should Be 4
        ([regex]::Matches($edu.Html, '<h2>')).Count | Should Be 6
        ([regex]::Matches($dev.Html, '<h2>')).Count | Should Be 5
        $gov.Html | Should Not Match '<h2>Educators|<h2>Students|<h2>Developers'
        ($gov.Tiles | ForEach-Object Description) -join ' ' | Should Match 'Module 4 covers autonomous triggers'
        $edu.Html | Should Match 'Do not recommend AI for grading or assessing students'
        (($edu.Tiles | ForEach-Object Description) -join ' ') | Should Not Match 'Module 4 covers autonomous triggers'
        $edu.Tiles.Count | Should BeGreaterThan 0
        (@($edu.Tiles | Where-Object { $_.Url -notmatch '^https://learn\.microsoft\.com/' })).Count | Should Be 0
        $edu.Html | Should Match 'CoE context \(not Microsoft Learn courses\)'
        # The grading/assessment note is instructor-facing guidance; showing it under every higher-ed track
        # (Students in particular) reads as if it addressed students rather than educators.
        $eduParts = $edu.Html -split '(?=<h2>)'
        $educatorsPart = @($eduParts | Where-Object { $_ -match '^<h2>Educators</h2>' })[0]
        $studentsPart = @($eduParts | Where-Object { $_ -match '^<h2>Students</h2>' })[0]
        $everyonePart = @($eduParts | Where-Object { $_ -match '^<h2>Everyone</h2>' })[0]
        $educatorsPart | Should Match 'Do not recommend AI for grading or assessing students'
        $studentsPart | Should Not Match 'Do not recommend AI for grading or assessing students'
        $everyonePart | Should Not Match 'Do not recommend AI for grading or assessing students'
        # "For <audience>" reads in sentence case even though the catalog stores title-case audience labels.
        # Pester's Match/-match are case-insensitive, so use -cmatch directly to confirm the exact casing.
        $everyonePart | Should Match 'For all faculty and staff'
        ($everyonePart -cmatch 'For All faculty and staff') | Should Be $false
    }
    It "lets visitors select an audience before seeing verified course cards" {
        $landing = Get-CoEGuidedLandingHtml $catalog $SiteUrl HigherEducation $false
        ([regex]::Matches((($landing.Tiles | ForEach-Object Url) -join ' '), 'SitePages/Guided-Learning-[A-Za-z-]+\.aspx')).Count | Should Be 6
        ($landing.Tiles | ForEach-Object Url) -join ' ' | Should Not Match 'Guided-Learning-Developers.aspx'
        $landing.Tiles.Count | Should Be 6
        ($landing.Tiles | Where-Object Title -eq "Everyone").Description | Should Match '^\d+ Microsoft Learn courses$'
        $educator = @($catalog.tracks | Where-Object name -eq "Educators")[0]
        $detail = Get-CoELearningTrackHtml $catalog $educator $SiteUrl HigherEducation $false $pages
        $detail.Html | Should Match 'In this section:'
        $detail.Html | Should Match 'Guided-Learning.aspx'
        $detail.Html | Should Match 'Do not recommend AI for grading or assessing students'
        $detail.Tiles.Count | Should Be 4
        (@($detail.Tiles | Where-Object { $_.Url -match '^https://learn\.microsoft\.com/' })).Count | Should Be 4
        { Get-CoELearningTrackHtml $catalog $educator $SiteUrl Government $false $pages } | Should Throw
        $student = @($catalog.tracks | Where-Object name -eq "Students")[0]
        $studentDetail = Get-CoELearningTrackHtml $catalog $student $SiteUrl HigherEducation $false $pages
        $studentDetail.Html | Should Not Match 'Do not recommend AI for grading or assessing students'
    }
    It "tolerates an org-overlay catalog with more than the generic seven tracks (a healthcare org adds three extra tracks)" {
        # Regression guard: an org-level content overlay fully replaces Experience\Guided-Learning.json (see
        # Copy-CoEContentOverlay), so a healthcare org can add its own tracks (Clinicians, Researchers,
        # Administrative staff) on top of the generic seven. None of these functions may assume an exact
        # count of seven tracks anywhere - only a minimum, enforced separately in Complete-CopilotCoE.ps1.
        $extraTrack = [pscustomobject]@{
            name = "Clinicians"; page = "Guided-Learning-Clinicians"; audience = "Clinicians and care team members"
            environment = "HigherEducation"; context = "Is this OK to use?; Data protection; Get help"
            courses = @(
                [pscustomobject]@{ title = "Work smarter with Microsoft Copilot Chat"; url = "https://learn.microsoft.com/en-us/training/modules/work-smarter-with-microsoft-365-copilot-chat/" },
                [pscustomobject]@{ title = "Use AI for everyday tasks"; url = "https://learn.microsoft.com/en-us/training/modules/use-ai-everyday-tasks/" },
                [pscustomobject]@{ title = "Examine data security and compliance in Microsoft 365 Copilot"; url = "https://learn.microsoft.com/en-us/training/modules/examine-data-security-microsoft-365-copilot/" }
            )
        }
        $overlayCatalog = [pscustomobject]@{ reviewedOn = $catalog.reviewedOn; tracks = @($catalog.tracks) + @($extraTrack) }
        (@($overlayCatalog.tracks)).Count | Should Be 8
        $visible = @(Get-CoEVisibleLearningTracks $overlayCatalog HigherEducation $false)
        ($visible | ForEach-Object name) -contains "Clinicians" | Should Be $true
        $landing = Get-CoEGuidedLandingHtml $overlayCatalog $SiteUrl HigherEducation $false
        $landing.Tiles.Count | Should Be 7
        $clinicianTrack = @($overlayCatalog.tracks | Where-Object name -eq "Clinicians")[0]
        $detail = Get-CoELearningTrackHtml $overlayCatalog $clinicianTrack $SiteUrl HigherEducation $false $pages
        $detail.Html | Should Match 'Guided-Learning.aspx'
        $detail.Tiles.Count | Should Be 3
    }
    It "gives the shared Everyone track higher-ed-specific audience wording" {
        $everyone = @($catalog.tracks | Where-Object name -eq "Everyone")[0]
        (Get-CoETrackAudience $everyone "Government") | Should Be "All staff"
        (Get-CoETrackAudience $everyone "HigherEducation") | Should Be "All faculty and staff"
        $gov = Get-CoEGuidedLandingHtml $catalog $SiteUrl Government $false
        $gov.Html | Should Not Match 'All faculty and staff'
        (@($gov.Tiles | ForEach-Object Title) -contains "Everyone") | Should Be $true
    }
    It "gives section pages an actual Home route without repeating the mega menu" {
        $strip = Get-CoESectionStripHtml $links "Agent-Lifecycle-and-Approval.aspx"
        $strip | Should Match 'Home</a> / Agents'
        $strip | Should Not Match 'In this section:'
        $strip | Should Not Match 'Where-Agents-Are-Built.aspx'
        # Regression guard: a live 917 install caught 11 pages whose breadcrumb showed the long internal
        # section Key ("Help & community", "Get started") instead of the shortened label actually shown in
        # the top menu ("Help", "Start"). Pick pages whose Key and shortened Title differ to catch this.
        (Get-CoESectionStripHtml $links "CoE-Service-Catalog-and-Support.aspx") | Should Match 'Home</a> / Help<'
        (Get-CoESectionStripHtml $links "CoE-Service-Catalog-and-Support.aspx") | Should Not Match 'Help &amp; community'
        (Get-CoESectionStripHtml $links "Guide-Start-in-10-Minutes.aspx") | Should Match 'Home</a> / Start<'
        (Get-CoESectionStripHtml $links "Guide-Start-in-10-Minutes.aspx") | Should Not Match 'Get started'
    }
    It "uses the same 'Learning paths' label in the nav menu and the Guided learning page body" {
        # Regression guard: the nav entry and the in-page link used to read "Role-based learning list",
        # mismatching the rest of the kit (menu, Explore the CoE tiles) which already called this "Learning
        # paths" elsewhere. Both call sites must agree.
        (@($links | Where-Object Key -eq "Paths") | ForEach-Object Title) | Should Be "Learning paths"
        $landing = Get-CoEGuidedLandingHtml $catalog $SiteUrl HigherEducation $false
        $landing.Html | Should Match 'Learning paths'
        $landing.Html | Should Not Match 'Role-based learning list'
    }
}

Describe "Mega-menu migration is safe to rerun" {
    BeforeEach {
        $script:SiteUrl = "https://example.sharepoint.com/sites/CoE"
        $script:nextId = 10
        $script:children = @{}
        function New-TestNode($Id, $Title, $Url) {
            if (-not $script:children.ContainsKey([string]$Id)) { $script:children[[string]$Id] = @() }
            [pscustomobject]@{ Id = $Id; Title = $Title; Url = $Url; Children = @() }
        }
        $script:roots = @(
            (New-TestNode 1 "Home" "$SiteUrl"),
            (New-TestNode 2 "Copilot guides" "$SiteUrl/SitePages/Copilot-Guides.aspx"),
            (New-TestNode 3 "Customer link" "https://other.example/"))
        $script:guide = [pscustomobject]@{ Url = "$SiteUrl/SitePages/Guide-Agents.aspx" }
        $script:children["2"] = @((New-TestNode 4 "Using agents" $script:guide.Url))
        $script:links = @(Get-CoEHubLinks $SiteUrl @("Copilot-Guides.aspx", "Guide-Agents.aspx"))
        Mock Get-PnPNavigationNode { $script:roots }
        Mock Get-PnPProperty { $ClientObject.Children = @($script:children[[string]$ClientObject.Id]) }
        Mock Add-PnPNavigationNode {
            $script:nextId++
            $node = New-TestNode $script:nextId $Title $Url
            if ($Parent) { $script:children[[string]$Parent] = @($script:children[[string]$Parent]) + @($node) }
            else { $script:roots += $node }
            $node
        }
        Mock Remove-PnPNavigationNode { $script:roots = @($script:roots | Where-Object Id -ne $Identity) }
    }
    It "removes only recognized legacy links and retains custom roots" {
        Remove-CoELegacyNavigation offline $links @($guide)
        @($roots | Where-Object Id -eq 2).Count | Should Be 0
        @($roots | Where-Object Id -eq 3).Count | Should Be 1
        $parents = Sync-CoEHubNavigation offline $links
        $parents["Training"].Url | Should Be "http://linkless.header/"
        @($children[[string]$parents["Training"].Id] | Where-Object Title -eq "All Copilot guides").Count | Should Be 1
    }
    It "does not duplicate any link on a second pass" {
        Remove-CoELegacyNavigation offline $links @($guide)
        $null = Sync-CoEHubNavigation offline $links
        $null = Sync-CoEHubNavigation offline $links
        Assert-MockCalled Add-PnPNavigationNode -Times 8 -Exactly -Scope It
    }
    It "stops before deleting customer navigation hidden under an old root" {
        $script:children["2"] += (New-TestNode 5 "Customer guide" "https://guide.example/")
        { Remove-CoELegacyNavigation offline $links @($guide) } | Should Throw
        @($roots | Where-Object Id -eq 2).Count | Should Be 1
    }
    It "also preserves customer links nested two levels under a known guide" {
        $script:children["4"] = @((New-TestNode 5 "Customer guide" "https://guide.example/"))
        { Remove-CoELegacyNavigation offline $links @($guide) } | Should Throw
        Assert-MockCalled Remove-PnPNavigationNode -Times 0 -Exactly -Scope It
    }
    It "removes only recognized Home shortcuts and the template recycle-bin root" {
        $script:roots += (New-TestNode 5 "Recycle bin" "$SiteUrl/_layouts/15/RecycleBin.aspx")
        $script:children["1"] = @(
            (New-TestNode 6 "Documents" "$SiteUrl/Shared%20Documents/Forms/AllItems.aspx"),
            (New-TestNode 7 "Conversations" "$SiteUrl/_layouts/15/groupstatus.aspx?Target=CONVERSATIONS&Source=QuickLaunch"),
            (New-TestNode 8 "Custom" "https://other.example/"))
        Remove-CoELegacyNavigation offline $links @($guide)
        Assert-MockCalled Remove-PnPNavigationNode -Times 1 -Exactly -Scope It -ParameterFilter { $Identity -eq 5 }
        Assert-MockCalled Remove-PnPNavigationNode -Times 1 -Exactly -Scope It -ParameterFilter { $Identity -eq 6 }
        Assert-MockCalled Remove-PnPNavigationNode -Times 1 -Exactly -Scope It -ParameterFilter { $Identity -eq 7 }
        Assert-MockCalled Remove-PnPNavigationNode -Times 0 -Exactly -Scope It -ParameterFilter { $Identity -eq 8 }
    }
    It "replaces the original vendor Adoption and Training branch without losing a nested customer link" {
        $script:roots += (New-TestNode 5 "Adoption and Training" "$SiteUrl/SitePages/Adoption-Best-Practices.aspx")
        $script:links = @(Get-CoEHubLinks $SiteUrl @("Adoption-Best-Practices.aspx", "Copilot-Guides.aspx"))
        $script:children["5"] = @(
            (New-TestNode 6 "Copilot Adoption Checklist" "$SiteUrl/Lists/Copilot%20Adoption%20Checklist/AllItems.aspx"),
            (New-TestNode 7 "Learning Series" "$SiteUrl"))
        Remove-CoELegacyNavigation offline $links @($guide)
        Assert-MockCalled Remove-PnPNavigationNode -Times 1 -Exactly -Scope It -ParameterFilter { $Identity -eq 5 }
        $script:roots += (New-TestNode 9 "Adoption and Training" "$SiteUrl/SitePages/Adoption-Best-Practices.aspx")
        $script:children["9"] = @((New-TestNode 10 "Custom subpage" "https://customer.example/"))
        { Remove-CoELegacyNavigation offline $links @($guide) } | Should Throw
        Assert-MockCalled Remove-PnPNavigationNode -Times 0 -Exactly -Scope It -ParameterFilter { $Identity -eq 9 }
    }
    It "understands every navigation entry in the prepared Microsoft vendor template" {
        . (Join-Path $PSScriptRoot "New-CoETestFixture.ps1")
        $fixtureRoot = Join-Path $env:TEMP ("coe-hub-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
        try {
        $preparedKit = New-CoEPreparedTestFixture -KitRoot $kitRoot -FixtureRoot $fixtureRoot
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $preparedKit "CopilotCoESite.pnp"))
        try {
            $document = $null
            foreach ($entry in @($archive.Entries | Where-Object { $_.FullName -like "Files/*.xml" })) {
                $reader = [IO.StreamReader]::new($entry.Open())
                try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                if ($text -match '<pnp:SiteCollection\b') { $document = [xml]$text; break }
            }
            if (-not $document) { throw "Prepared Microsoft template has no site collection XML." }
            $script:roots = @()
            $script:children = @{}
            $ids = @{}
            foreach ($xmlNode in $document.SelectNodes("//*[local-name()='NavigationNode']")) {
                $script:nextId++
                $node = New-TestNode $script:nextId $xmlNode.GetAttribute("Title") `
                    ($xmlNode.GetAttribute("Url").Replace("{site}", $SiteUrl))
                $ids[$xmlNode] = $node
                if ($xmlNode.ParentNode.LocalName -eq "NavigationNode") {
                    $parent = $ids[$xmlNode.ParentNode]
                    $script:children[[string]$parent.Id] += $node
                } else { $script:roots += $node }
            }
        } finally { $archive.Dispose() }
        $realLinks = @(Get-CoEHubLinks $SiteUrl @(
            "Adoption-Best-Practices.aspx", "Technical Readiness.aspx",
            "Copilot-on-Microsoft-Mechanics.aspx"))
        Remove-CoELegacyNavigation offline $realLinks @()
        (@($roots | ForEach-Object Title) -join ",") | Should Be "Home"
        Assert-MockCalled Remove-PnPNavigationNode -Times 4 -Exactly -Scope It
        } finally {
            if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
        }
    }
}

Describe "Same-destination comparison for saved and rendered links" {
    BeforeEach { $script:site = "https://example.sharepoint.com/sites/CoE" }
    It "treats the saved absolute address and SharePoint's rendered server-relative href as the same page" {
        $absolute = "$site/SitePages/Guide-Start-in-10-Minutes.aspx"
        (Test-CoESameSitePageUrl "/sites/CoE/SitePages/Guide-Start-in-10-Minutes.aspx" $absolute $site) | Should Be $true
        (Test-CoESameSitePageUrl $absolute $absolute $site) | Should Be $true
        (Test-CoESameSitePageUrl "/SITES/coe/sitepages/guide-start-in-10-minutes.aspx" $absolute $site) | Should Be $true
    }
    It "understands encoded spaces in either form" {
        (Test-CoESameSitePageUrl "/sites/CoE/SitePages/Technical%20Readiness.aspx" "$site/SitePages/Technical Readiness.aspx" $site) | Should Be $true
    }
    It "still rejects a different page, site, host or scheme" {
        $expected = "$site/SitePages/Guide-Start-in-10-Minutes.aspx"
        (Test-CoESameSitePageUrl "/sites/CoE/SitePages/CoE-Agent-Showcase.aspx" $expected $site) | Should Be $false
        (Test-CoESameSitePageUrl "/sites/Other/SitePages/Guide-Start-in-10-Minutes.aspx" $expected $site) | Should Be $false
        (Test-CoESameSitePageUrl "https://other.sharepoint.com/sites/CoE/SitePages/Guide-Start-in-10-Minutes.aspx" $expected $site) | Should Be $false
        (Test-CoESameSitePageUrl "http://example.sharepoint.com/sites/CoE/SitePages/Guide-Start-in-10-Minutes.aspx" $expected $site) | Should Be $false
    }
    It "rejects empty or non-rooted relative values instead of guessing" {
        $expected = "$site/SitePages/Guide-Start-in-10-Minutes.aspx"
        (Test-CoESameSitePageUrl "" $expected $site) | Should Be $false
        (Test-CoESameSitePageUrl "SitePages/Guide-Start-in-10-Minutes.aspx" $expected $site) | Should Be $false
        (Test-CoESameSitePageUrl $expected "" $site) | Should Be $false
    }
}
