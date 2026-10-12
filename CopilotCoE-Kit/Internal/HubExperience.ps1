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
        $html += '<p>For a data or safety concern, stop using the affected content. Use an existing approved incident route if you know it; otherwise ask for the correct route without sharing sensitive details. Do not post sensitive details in Teams, general feedback or email.</p>'
    }
    return $html
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
        @{ Title = "Learning paths by role"; Page = "CoE-Training-and-Enablement.aspx"; Image = "SiteAssets/copilot/May2023/57677MS365_future_00030.jpg" },
        @{ Title = "Prompt library by role"; Page = "Guide-Prompt-Library.aspx"; Image = "SiteAssets/copilot/May2023/39837M365Copilot_HeroBanner_WordApp_Prompt_1920x1080.png" },
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

function Convert-CoEHomeHeroCanvas([string]$Canvas, [string]$SiteUrl, [object[]]$Tiles,
    [hashtable]$ImageIds, [string]$FeatureText) {
    $updated = [regex]::Replace($Canvas, 'data-sp-webpartdata="([^"]*)"', {
        param($match)
        $data = [Net.WebUtility]::HtmlDecode($match.Groups[1].Value) | ConvertFrom-Json -AsHashtable
        if ($data["id"] -ne "c4bd7b2f-7b6e-4599-8485-16504575f590") { return $match.Value }
        if ($data["properties"]["content"].Count -ne $Tiles.Count) { throw "Home Hero has an unexpected tile count." }
        $spc = $data["serverProcessedContent"]
        for ($i = 0; $i -lt $Tiles.Count; $i++) {
            $tile = $Tiles[$i]
            if (-not $ImageIds.ContainsKey($tile.Image)) { throw "Home tile image identity was not resolved: $($tile.Image)" }
            $item = $data["properties"]["content"][$i]
            $item["description"] = ""
            $item["alternateText"] = $tile.Title
            $item["openLinkInPlace"] = $true
            $item["imageDisplayOption"] = 3
            $item["isDefaultImage"] = $false
            $item["isDefaultImageLoaded"] = $false
            $item["isCustomImageLoaded"] = $true
            if ($item["type"] -eq "Image") { $item["type"] = "UrlLink" }
            $item["image"]["id"] = [string]$ImageIds[$tile.Image]
            $item["image"]["resolvedUrl"] = "$($SiteUrl.TrimEnd('/'))/$($tile.Image)"
            $item["image"]["imageUrl"] = "$($SiteUrl.TrimEnd('/'))/$($tile.Image)"
            $item["previewImage"]["imageUrl"] = ""
            if ($item["previewImage"].ContainsKey("resolvedUrl")) { $item["previewImage"]["resolvedUrl"] = "" }
            $spc["searchablePlainTexts"]["content[$i].title"] = $tile.Title
            $spc["searchablePlainTexts"]["content[$i].alternateText"] = $tile.Title
            $spc["imageSources"]["content[$i].image.url"] = "$($SiteUrl.TrimEnd('/'))/$($tile.Image)"
            $spc["imageSources"].Remove("content[$i].previewImage.url")
            $spc["links"]["content[$i].link"] = "$($SiteUrl.TrimEnd('/'))/SitePages/$($tile.Page)"
            if ($spc["links"].ContainsKey("content[$i].callToActionLink")) {
                $spc["links"]["content[$i].callToActionLink"] = $spc["links"]["content[$i].link"]
            }
            if ($i -eq 0) {
                $item["featureText"] = $FeatureText
                $spc["searchablePlainTexts"]["content[0].callToActionText"] = "Start here"
            }
        }
        return 'data-sp-webpartdata="' + [Net.WebUtility]::HtmlEncode(($data | ConvertTo-Json -Depth 100 -Compress)) + '"'
    })
    $heroes = @([regex]::Matches($updated, 'data-sp-webpartdata="([^"]*)"') | ForEach-Object {
        $data = [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) | ConvertFrom-Json -AsHashtable
        if ($data["id"] -eq "c4bd7b2f-7b6e-4599-8485-16504575f590") { $data }
    })
    if ($heroes.Count -ne 1) { throw "Expected exactly one Home Hero web part; found $($heroes.Count)." }
    return [regex]::Replace($updated, '<a\b[^>]*data-sp-prop-name="content\[(\d+)\]\.(link|callToActionLink)"[^>]*>', {
        param($match)
        $index = [int]$match.Groups[1].Value
        if ($index -ge $Tiles.Count) { throw "Home Hero anchor index is outside the tile collection." }
        $url = [Net.WebUtility]::HtmlEncode("$($SiteUrl.TrimEnd('/'))/SitePages/$($Tiles[$index].Page)")
        if ($match.Value -notmatch '\bhref="[^"]*"') { throw "Home Hero anchor has no href." }
        return [regex]::Replace($match.Value, '\bhref="[^"]*"', ('href="' + $url + '"'))
    })
}

function Get-CoEHubLinks([string]$SiteUrl, [string[]]$AvailablePages, [string]$CalendarUrl = "") {
    $entries = @(
        @{ Key = "Start"; Title = "Start"; Page = "Guide-Start-in-10-Minutes.aspx"; Parent = "" },
        @{ Key = "Learn"; Title = "Learn"; Page = "CoE-Training-and-Enablement.aspx"; Parent = "" },
        @{ Key = "Prompts"; Title = "Prompts"; Page = "Guide-Prompt-Library.aspx"; Parent = "" },
        @{ Key = "Agents"; Title = "Agents"; Page = "CoE-Agent-Showcase.aspx"; Parent = "" },
        @{ Key = "Help"; Title = "Get help"; Page = "CoE-Service-Catalog-and-Support.aspx"; Parent = "" },
        @{ Key = "Governance"; Title = "Governance"; Page = "CoE-Governance-and-Responsible-AI.aspx"; Parent = "" },
        @{ Key = "Guides"; Title = "All Copilot guides"; Page = "Copilot-Guides.aspx"; Parent = "Learn" },
        @{ Key = "Stories"; Title = "Success stories"; Page = "CoE-Success-Stories.aspx"; Parent = "Learn" },
        @{ Key = "Planning"; Title = "Adoption planning"; Page = "Adoption-Best-Practices.aspx"; Parent = "Learn" },
        @{ Key = "Mechanics"; Title = "Microsoft Mechanics"; Page = "Copilot-on-Microsoft-Mechanics.aspx"; Parent = "Learn" },
        @{ Key = "Champions"; Title = "Department champions"; Page = "Meet-your-Champions.aspx"; Parent = "Help" },
        @{ Key = "FAQ"; Title = "FAQs"; Page = "Copilot-FAQs.aspx"; Parent = "Help" },
        @{ Key = "Feedback"; Title = "Feedback and incident routes"; Page = "Give-Feedback.aspx"; Parent = "Help" },
        @{ Key = "Roadmap"; Title = "Feedback and roadmap"; Page = "CoE-Feedback-and-Roadmap.aspx"; Parent = "Help" },
        @{ Key = "Readiness"; Title = "Technical readiness"; Page = "Technical Readiness.aspx"; Parent = "Governance" },
        @{ Key = "Roles"; Title = "Roles and contacts"; Page = "Meet-your-ProjectTeam.aspx"; Parent = "Governance" }
    )
    foreach ($entry in $entries) {
        if ($entry.Page -notin $AvailablePages) { continue }
        [pscustomobject]@{ Key = $entry.Key; Title = $entry.Title; Page = $entry.Page; Parent = $entry.Parent
            Url = "$($SiteUrl.TrimEnd('/'))/SitePages/$([uri]::EscapeDataString($entry.Page))" }
    }
    if ($CalendarUrl) {
        [pscustomobject]@{ Key = "Calendar"; Title = "Training calendar"; Page = ""; Parent = "Learn"
            Url = Resolve-CoECatalogUrl $CalendarUrl "Training calendar" }
    }
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
    foreach ($link in $Links) {
        $rootNodes = @(Get-PnPNavigationNode -Location QuickLaunch -Connection $Connection -ErrorAction Stop)
        $matches = @($rootNodes | Where-Object { (Get-ManagedNavigationUrl $_.Url) -eq (Get-ManagedNavigationUrl $link.Url) })
        if ($link.Parent -and $parents.ContainsKey($link.Parent)) {
            $parent = $parents[$link.Parent]
            Get-PnPProperty -ClientObject $parent -Property Children -Connection $Connection -ErrorAction Stop | Out-Null
            $children = @(foreach ($child in $parent.Children) { $child })
            $existing = @($children | Where-Object { (Get-ManagedNavigationUrl $_.Url) -eq (Get-ManagedNavigationUrl $link.Url) })
        } else {
            if ($link.Parent) {
                Write-Warning "Navigation group '$($link.Parent)' has no configured page; '$($link.Title)' will remain a top-level link."
            }
            $parent = $null
            $existing = $matches
        }
        if ($existing.Count -gt 1) { throw "Duplicate managed navigation '$($link.Title)' requires review." }
        $node = if ($existing.Count) { $existing[0] } else {
            $args = @{ Location = "QuickLaunch"; Title = $link.Title; Url = $link.Url; Connection = $Connection; ErrorAction = "Stop" }
            if ($parent) { $args.Parent = $parent.Id }
            Add-PnPNavigationNode @args
        }
        if ($node.Title -ne $link.Title) {
            # Renaming a Quick Launch node also renames the linked SharePoint page and leaves it as an
            # unpublished draft (verified live). Replace the node instead so page titles and publishing
            # state stay unchanged; top-level order is restored by the navigation ordering step.
            $replacementArgs = @{ Location = "QuickLaunch"; Title = $link.Title; Url = $link.Url
                Connection = $Connection; ErrorAction = "Stop" }
            if ($parent) { $replacementArgs.Parent = $parent.Id }
            $replacement = Add-PnPNavigationNode @replacementArgs
            Copy-CoENavigationChildren $node $replacement $Connection
            Remove-PnPNavigationNode -Identity $node.Id -Force -Connection $Connection -ErrorAction Stop
            $replacedId = $node.Id
            $matches = @($matches | Where-Object { $_.Id -ne $replacedId })
            $node = $replacement
        }
        $parents[$link.Key] = $node
        if ($parent) {
            foreach ($old in $matches) {
                Copy-CoENavigationChildren $old $node $Connection
                Remove-PnPNavigationNode -Identity $old.Id -Force -Connection $Connection -ErrorAction Stop
            }
        }
    }
    return $parents
}
