#Requires -Version 7.4
<#
.SYNOPSIS
Read-only check of a finished Copilot CoE site. Changes nothing. Exits non-zero if any check fails.

.DESCRIPTION
Run this after 02_Install-CopilotCoE.ps1 finishes (and after any 03_Update-CoEContent.ps1 run):
    .\Test-CoEInstall.ps1 -OrgPath C:\CoE-Orgs\Contoso -SiteUrl https://contoso.sharepoint.com/sites/CopilotCoE

An install is only complete when this prints "ALL CHECKS PASSED" and exits with code 0.

Checks
  1  Every CoE page exists
  2  Home has five tiles and each tile opens an existing CoE page
  3  Navigation order is Home, Start, Learn, Prompts, Agents, Get help, Governance (Site contents last), with
     no duplicate Microsoft Mechanics link
  4  The catalogs (three, or four with the Prompt Library) have content approval on, drafts visible to approvers only, the reviewer group holding
     the reviewer permission level, and the site Owners still holding Full Control
  5  The reader views exist and the "Open the list" links on the catalog pages open (HTTP 200)
  6  The four support routes appear as links, or as a clear "not configured" notice when the route is empty
#>
[CmdletBinding()]
param(
    [string]$OrgPath,
    [string]$SettingsPath,
    [Parameter(Mandatory)][string]$SiteUrl,
    [switch]$AllowUnconfiguredRoutes
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
$SiteUrl = $SiteUrl.TrimEnd("/")
$siteUri = [uri]$SiteUrl

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Check, [string]$Item, [bool]$Ok, [string]$Detail = "") {
    $results.Add([pscustomobject]@{ Check = $Check; Item = $Item; Result = $(if ($Ok) { "PASS" } else { "FAIL" }); Detail = $Detail })
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

Invoke-Section "1 Pages" {
    $expected = @("TrainingHome.aspx", "Copilot-Guides.aspx", "CoE-Training-and-Enablement.aspx", "CoE-Success-Stories.aspx",
        "CoE-Governance-and-Responsible-AI.aspx", "CoE-Service-Catalog-and-Support.aspx", "CoE-Feedback-and-Roadmap.aspx",
        "CoE-Agent-Showcase.aspx", "Meet-your-Champions.aspx", "Give-Feedback.aspx", "Copilot-FAQs.aspx",
        "Guide-Start-in-10-Minutes.aspx", "Guide-Prompt-Library.aspx", "Technical Readiness.aspx",
        "Adoption-Best-Practices.aspx", "Copilot-on-Microsoft-Mechanics.aspx", "Meet-your-ProjectTeam.aspx")
    foreach ($name in $expected) { Add-Result "1 Pages" $name ($name -in $pages) $(if ($name -notin $pages) { "page is missing" } else { "" }) }
    Add-Result "1 Pages" "News-and-Updates.aspx is absent" ("News-and-Updates.aspx" -notin $pages) ""
}

Invoke-Section "2 Home" {
    $item = Get-PnPFile -Url "SitePages/TrainingHome.aspx" -AsListItem -Connection $site -ErrorAction Stop
    $canvas = [string]$item["CanvasContent1"]
    $hero = $null
    foreach ($m in [regex]::Matches($canvas, 'data-sp-webpartdata="([^"]*)"')) {
        $data = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) | ConvertFrom-Json -AsHashtable
        if ($data["id"] -eq "c4bd7b2f-7b6e-4599-8485-16504575f590") { $hero = $data }
    }
    if (-not $hero) { Add-Result "2 Home" "Hero web part" $false "no Hero web part on Home"; return }
    $tiles = @($hero["properties"]["content"])
    Add-Result "2 Home" "five tiles" ($tiles.Count -eq 5) "found $($tiles.Count)"
    $links = $hero["serverProcessedContent"]["links"]
    for ($i = 0; $i -lt $tiles.Count; $i++) {
        $target = [string]$links["content[$i].link"]
        $page = [uri]::UnescapeDataString(($target -split "/")[-1])
        $title = [string]$hero["serverProcessedContent"]["searchablePlainTexts"]["content[$i].title"]
        # Tile links are stored server-relative; either form is fine as long as it stays inside this site.
        $insideSite = $target.StartsWith($siteUri.AbsolutePath + "/", [StringComparison]::OrdinalIgnoreCase) -or
            $target.StartsWith($SiteUrl, [StringComparison]::OrdinalIgnoreCase)
        $ok = $insideSite -and $page -in $pages
        Add-Result "2 Home" "tile $($i + 1): $title" $ok $(if ($ok) { $page } else { "target '$target' is not an existing CoE page" })
    }
    $images = @($tiles | ForEach-Object { [string]$_["image"]["resolvedUrl"] } | Select-Object -Unique)
    Add-Result "2 Home" "tile images are distinct" ($images.Count -eq 5) "$($images.Count) distinct of 5"
}

Invoke-Section "3 Navigation" {
    $nodes = @(Get-PnPNavigationNode -Location QuickLaunch -Connection $site -ErrorAction Stop)
    $titles = @($nodes | ForEach-Object Title)
    $want = @("Home", "Start", "Learn", "Prompts", "Agents", "Get help", "Governance")
    $actual = @($titles | Where-Object { $_ -in $want })
    Add-Result "3 Navigation" "order of task groups" (($actual -join ",") -eq ($want -join ",")) "found: $($titles -join ', ')"
    if ("Site contents" -in $titles) { Add-Result "3 Navigation" "Site contents is last" ($titles[-1] -eq "Site contents") "last is '$($titles[-1])'" }
    $mechanics = 0
    foreach ($node in $nodes) {
        Get-PnPProperty -ClientObject $node -Property Children -Connection $site | Out-Null
        $mechanics += @($node.Children | Where-Object { $_.Title -match 'Mechanics' }).Count
        if ($node.Title -match 'Mechanics') { $mechanics++ }
    }
    Add-Result "3 Navigation" "exactly one Microsoft Mechanics link" ($mechanics -eq 1) "found $mechanics"
}

Invoke-Section "4 Catalogs" {
    $owners = (Get-PnPWeb -Includes AssociatedOwnerGroup -Connection $site).AssociatedOwnerGroup
    $group = Get-PnPGroup -Identity "CoE Catalog Reviewers" -Connection $site -ErrorAction SilentlyContinue
    $wantReviewer = @($s.CatalogReviewerUPNs).Count -gt 0
    if ($wantReviewer) {
        Add-Result "4 Catalogs" "reviewer group exists" ($null -ne $group) ""
        if ($group) {
            $members = @(Get-PnPGroupMember -Group "CoE Catalog Reviewers" -Connection $site | ForEach-Object { ([string]$_.LoginName).ToLowerInvariant() })
            foreach ($upn in @($s.CatalogReviewerUPNs)) {
                Add-Result "4 Catalogs" "reviewer $upn is in the group" (@($members | Where-Object { $_ -like "*$($upn.ToLowerInvariant())" }).Count -gt 0) ""
            }
        }
    }
    foreach ($name in $catalogNames) {
        $list = Get-PnPList -Identity $name -Includes EnableVersioning,EnableModeration,DraftVersionVisibility,HasUniqueRoleAssignments,RoleAssignments -Connection $site -ErrorAction SilentlyContinue
        if (-not $list) { Add-Result "4 Catalogs" $name $false "list is missing"; continue }
        Add-Result "4 Catalogs" "$name content approval on" ([bool]$list.EnableModeration) ""
        Add-Result "4 Catalogs" "$name versioning on" ([bool]$list.EnableVersioning) ""
        Add-Result "4 Catalogs" "$name drafts visible to approvers only" ([string]$list.DraftVersionVisibility -eq "Approver") "is $($list.DraftVersionVisibility)"
        $ctx = Get-PnPContext -Connection $site; $ctx.Load($list.RoleAssignments); Invoke-PnPQuery -Connection $site
        $held = @{}
        foreach ($ra in $list.RoleAssignments) {
            Get-PnPProperty -ClientObject $ra -Property Member,RoleDefinitionBindings -Connection $site | Out-Null
            $held[[int]$ra.Member.Id] = @($ra.RoleDefinitionBindings | ForEach-Object Name)
        }
        Add-Result "4 Catalogs" "$name site Owners keep Full Control" ("Full Control" -in @($held[[int]$owners.Id])) ""
        if ($wantReviewer -and $group) {
            Add-Result "4 Catalogs" "$name reviewer group holds the reviewer role" ("CoE Catalog Reviewer" -in @($held[[int]$group.Id])) ""
        }
    }
}

Invoke-Section "5 Reader views and links" {
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
            Add-Result "5 Views" "$name / $title exists" ($view.Count -eq 1) ""
            if ($view.Count -eq 1) {
                $api = "web/lists/getbyid('$($list.Id)')/views/getbyid('$($view[0].Id)')?`$select=Title"
                $code = Test-CoERestOpens $api
                Add-Result "5 Views" "$name / $title can be opened" ($code -eq 200) "HTTP $code"
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
        if (-not $page -or -not $list) { Add-Result "5 Links" "$pageName catalog section" $false "page or list is missing"; continue }
        $bound = @($page.Controls | Where-Object {
            $_.PSObject.Properties["PropertiesJson"] -and ([string]$_.PropertiesJson) -match [regex]::Escape($list.Id.ToString()) })
        Add-Result "5 Links" "$pageName shows the $($pageLists[$pageName]) list" ($bound.Count -ge 1) $(if (-not $bound.Count) { "no list web part is bound to the catalog" } else { "$($bound.Count) list web part(s)" })
        $textControls = @($page.Controls | Where-Object { $_.PSObject.Properties["Text"] })
        # SharePoint saves a same-site link as a server-relative path, so resolve every link against the site first.
        $siteBase = [uri]($SiteUrl + "/")
        $hrefs = @($textControls | ForEach-Object {
            [regex]::Matches([string]$_.Text, '<a[^>]*href="([^"]+\.aspx)"[^>]*>\s*Open the list') |
                ForEach-Object { [uri]::new($siteBase, [Net.WebUtility]::HtmlDecode($_.Groups[1].Value)).AbsolutePath } } | Select-Object -Unique)
        Add-Result "5 Links" "$pageName has an Open the list link" ($hrefs.Count -ge 1) $(if (-not $hrefs.Count) { "no link found" } else { "" })
        $listViews = @(Get-PnPView -List $list.Id -Includes ServerRelativeUrl -Connection $site)
        $shownViewIds = @($bound | ForEach-Object { try { ([string]$_.PropertiesJson | ConvertFrom-Json).selectedViewId } catch { $null } } |
            Where-Object { $_ } | ForEach-Object { $_.ToString().ToLowerInvariant() })
        foreach ($path in $hrefs) {
            $viewFile = [uri]::UnescapeDataString(($path -split "/")[-1])
            $match = @($listViews | Where-Object { [uri]::UnescapeDataString([string]$_.ServerRelativeUrl) -ieq [uri]::UnescapeDataString($path) })
            $code = 0
            if ($match.Count -eq 1) { $code = Test-CoERestOpens "web/lists/getbyid('$($list.Id)')/views/getbyid('$($match[0].Id)')?`$select=Title" }
            Add-Result "5 Links" "$pageName -> $viewFile" ($code -eq 200) $(if ($match.Count -ne 1) { "link does not match any view of the catalog" } else { "HTTP $code" })
            if ($match.Count -eq 1) {
                $displayed = $match[0].Id.ToString().ToLowerInvariant() -in $shownViewIds
                Add-Result "5 Links" "$pageName -> $viewFile is a view the page displays" $displayed `
                    $(if ($displayed) { "" } else { "the link opens a different view than the list on the page" })
            }
        }
    }
}

if ($promptLibraryOn) {
    Invoke-Section "4 Catalogs" {
        $list = Get-PnPList -Identity "Copilot Prompt Library" -Connection $site -ErrorAction SilentlyContinue
        if ($list) {
            $items = @(Get-PnPListItem -List $list.Id -Fields Title,PromptText,_ModerationStatus -PageSize 500 -Connection $site)
            $approved = @($items | Where-Object { [int]$_.FieldValues["_ModerationStatus"] -eq 0 })
            Add-Result "4 Catalogs" "Copilot Prompt Library has approved prompts" ($approved.Count -gt 0) "$($approved.Count) approved of $($items.Count)"
        }
    }
}

Invoke-Section "6 Support routes" {
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
            Add-Result "6 Routes" "$key links to the configured address" $ok $(if (-not $match.Success) { "no link labelled '$($routes[$key])'" } elseif (-not $ok) { "links to '$target', expected '$expected'" } else { $target })
        } else {
            Add-Result "6 Routes" "$key is clearly marked not configured" ($notice -or $AllowUnconfiguredRoutes) "route is empty and the page does not say so"
        }
    }
}

$results | Format-Table Check, Item, Result, Detail -AutoSize -Wrap
$failed = @($results | Where-Object Result -ne "PASS")
Write-Host ""
if ($failed.Count) {
    Write-Host ("CHECKS FAILED: {0} of {1}" -f $failed.Count, $results.Count) -ForegroundColor Red
    $failed | ForEach-Object { Write-Host ("  FAIL  {0} - {1}  {2}" -f $_.Check, $_.Item, $_.Detail) -ForegroundColor Red }
    exit 1
}
Write-Host ("ALL CHECKS PASSED ({0})" -f $results.Count) -ForegroundColor Green
exit 0
