[CmdletBinding()]
param(
    [string]$DisplayName,
    [string]$ShortName,
    [string]$EnvironmentLabel = "Pilot",
    [string]$SampleNotice,
    [string]$OrgName,
    [string]$OrgNoun,
    [string]$HomeTilesJson = "",
    # Teams "Scenario Library" tab destination; default is the education scenarios.
    [string]$ScenarioLibraryUrl = "https://adoption.microsoft.com/en-us/scenario-library/education/"
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "OrganizationProfile.ps1")
. (Join-Path $PSScriptRoot "AdoptionCatalogs.ps1")
. (Join-Path $PSScriptRoot "HubExperience.ps1")
$organizationProfile = Get-CoEOrganizationProfile -Settings $null -Overrides $PSBoundParameters
foreach ($property in $organizationProfile.PSObject.Properties) {
    Set-Variable -Name $property.Name -Value $property.Value
}
if ([string]::IsNullOrWhiteSpace($EnvironmentLabel) -or $EnvironmentLabel -match '<[^<>]+>|\{\{|\}\}|[\x00-\x1f]') {
    throw "EnvironmentLabel must be configured single-line text without placeholders."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

$buildFolder = Split-Path -Parent $PSScriptRoot  # helper lives in Internal\
$projectBuildFolder = Split-Path -Parent $buildFolder
$sourceFolder = Join-Path $projectBuildFolder "SourceOriginal\CopilotCoESite"
$sourcePackage = Join-Path $sourceFolder "CopilotCoESite.pnp"
$sourceTeamTemplate = Join-Path $sourceFolder "TeamTemplate.xml"
$stage = Join-Path $buildFolder (".prepare-" + [guid]::NewGuid().ToString("N"))
$packageOutput = Join-Path $stage "CopilotCoESite.pnp"
$teamTemplateOutput = Join-Path $stage "TeamTemplate-CoE.xml"
$resourceLinks = Get-Content (Join-Path $buildFolder "ResourceLinks.json") -Raw | ConvertFrom-Json

function Convert-CoECapturedAssetUrls([string]$Text) {
    # Captured authenticated-cache URLs expire and can carry authentication material.
    $pattern = '(?i)(https?://[^/"''\s<>\\]+)/_vti_bin/afdcache\.ashx/authitem([^?"''\s<>\\]+)(?:\?[^"''\s<>\\]*)?'
    $result = [regex]::Replace($Text, $pattern, '$1$2')
    if ($result -match '(?i)afdcache\.ashx/authitem') {
        throw "An unrecognized captured authenticated-cache URL remains in the template."
    }
    return $result
}

function Convert-CoEReplacementValue($Value, [string]$OldText, [string]$NewText) {
    if ($Value -is [string]) {
        $replacement = if ($Value -match '<[A-Za-z/]') { [Net.WebUtility]::HtmlEncode($NewText) } else { $NewText }
        return $Value.Replace($OldText, $replacement)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) { $Value[$key] = Convert-CoEReplacementValue $Value[$key] $OldText $NewText }
    } elseif ($Value -is [array]) {
        for ($i = 0; $i -lt $Value.Count; $i++) { $Value[$i] = Convert-CoEReplacementValue $Value[$i] $OldText $NewText }
        return ,$Value
    }
    return $Value
}

function Set-CoEXmlTextReplacement([xml]$Document, [string]$OldText, [string]$NewText) {
    foreach ($node in @($Document.SelectNodes('//@*|//text()'))) {
        if (-not $node.Value -or -not $node.Value.Contains($OldText)) { continue }
        if ($node.Value.TrimStart() -match '^[\{\[]') {
            $data = $node.Value | ConvertFrom-Json -AsHashtable
            $data = Convert-CoEReplacementValue $data $OldText $NewText
            $node.Value = ($data | ConvertTo-Json -Depth 100 -Compress).Replace(">", "\u003e")
        } else {
            $node.Value = Convert-CoEReplacementValue $node.Value $OldText $NewText
        }
    }
}

function Convert-CoELegacyMessageJson([string]$Text) {
    # Repair only unescaped control characters inside legacy JSON strings, not JSON structure.
    $builder = [Text.StringBuilder]::new()
    $insideString = $false
    $escaped = $false
    foreach ($character in $Text.ToCharArray()) {
        if ($insideString -and -not $escaped -and [int]$character -lt 32) {
            [void]$builder.Append(('\u{0:x4}' -f [int]$character))
            continue
        }
        [void]$builder.Append($character)
        if ($escaped) { $escaped = $false; continue }
        if ($insideString -and $character -eq '\') { $escaped = $true; continue }
        if ($character -eq '"') { $insideString = -not $insideString }
    }
    return $builder.ToString()
}

function Set-CoETemplateBannerDefaults([xml]$Document, [System.Xml.XmlNamespaceManager]$Namespaces) {
    $asset = "SiteAssets/copilot/May2023/4772M365Copilot_Abstract_Light_3840x2160.jpg"
    if (-not $Document.SelectSingleNode("//pnp:File[@Src=`"$asset`"]", $Namespaces)) {
        throw "The safe banner asset is missing from the captured template: $asset"
    }
    $url = "https://{fqdn}{site}/$asset"
    foreach ($header in @($Document.SelectNodes("//pnp:ClientSidePage/pnp:Header[@Type='Custom']", $Namespaces))) {
        # Captured previews and the stock title image can resolve to guidFile=00000000 after provisioning.
        $header.SetAttribute("ServerRelativeImageUrl", $url)
        $header.SetAttribute("TopicHeader", "")
        $header.SetAttribute("AlternativeText", "")
        foreach ($attribute in @("TranslateX", "TranslateY")) { $header.RemoveAttribute($attribute) }
    }
    foreach ($page in @($Document.SelectNodes("//pnp:ClientSidePage", $Namespaces))) {
        if ($page.GetAttribute("ThumbnailUrl") -match '(?i)preview\.ashx|guidFile=00000000') {
            $page.SetAttribute("ThumbnailUrl", $url)
        }
    }
}

foreach ($path in @($sourcePackage, $sourceTeamTemplate)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required source file was not found: $path"
    }
}

[void][IO.Directory]::CreateDirectory($stage)
try {
Copy-Item -LiteralPath $sourcePackage -Destination $packageOutput -Force
$archive = [System.IO.Compression.ZipFile]::Open(
    $packageOutput,
    [System.IO.Compression.ZipArchiveMode]::Update
)

try {
    $mapEntry = $archive.GetEntry("ProvisioningTemplate/files-map.xml")
    if (-not $mapEntry) {
        throw "The PnP package does not contain ProvisioningTemplate/files-map.xml."
    }

    $mapStream = $mapEntry.Open()
    try {
        $mapReader = [System.IO.StreamReader]::new($mapStream)
        try {
            $mapXml = $mapReader.ReadToEnd()
        }
        finally {
            $mapReader.Dispose()
        }
    }
    finally {
        $mapStream.Dispose()
    }

    $orphanAssetKeys = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $orphanAssetMatches = @(
        [regex]::Matches(
            $mapXml,
            '<x:String x:Key="([^"]+)">([^<]*SitePages/(?:Early-Adopter-Program-Updates|News-and-Updates)/[^<]*)</x:String>'
        )
    )
    foreach ($assetMatch in $orphanAssetMatches) {
        $assetKey = $assetMatch.Groups[1].Value
        [void]$orphanAssetKeys.Add($assetKey)
        $assetEntry = $archive.GetEntry("Files/$assetKey")
        if ($assetEntry) {
            $assetEntry.Delete()
        }
        $mapXml = $mapXml.Replace($assetMatch.Value, "")
    }
    if ($orphanAssetMatches.Count -gt 0) {
        $mapEntry.Delete()
        $updatedMapEntry = $archive.CreateEntry(
            "ProvisioningTemplate/files-map.xml",
            [System.IO.Compression.CompressionLevel]::Optimal
        )
        $updatedMapStream = $updatedMapEntry.Open()
        try {
            $mapBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($mapXml)
            $updatedMapStream.Write($mapBytes, 0, $mapBytes.Length)
        }
        finally {
            $updatedMapStream.Dispose()
        }
    }

    if ($orphanAssetKeys.Count -gt 0) {
        $relationshipsEntry = $archive.GetEntry("_rels/files.origin.rels")
        if (-not $relationshipsEntry) {
            throw "The PnP package does not contain _rels/files.origin.rels."
        }

        $relationshipsStream = $relationshipsEntry.Open()
        try {
            $relationshipsReader = [System.IO.StreamReader]::new($relationshipsStream)
            try {
                $relationshipsXml = $relationshipsReader.ReadToEnd()
            }
            finally {
                $relationshipsReader.Dispose()
            }
        }
        finally {
            $relationshipsStream.Dispose()
        }

        $relationshipsDocument = [System.Xml.XmlDocument]::new()
        $relationshipsDocument.PreserveWhitespace = $true
        $relationshipsDocument.LoadXml($relationshipsXml)
        $relationshipsNamespaceManager = [System.Xml.XmlNamespaceManager]::new(
            $relationshipsDocument.NameTable
        )
        $relationshipsNamespaceManager.AddNamespace(
            "rel",
            "http://schemas.openxmlformats.org/package/2006/relationships"
        )

        $removedRelationships = 0
        foreach ($relationship in @(
            $relationshipsDocument.SelectNodes(
                "/rel:Relationships/rel:Relationship",
                $relationshipsNamespaceManager
            )
        )) {
            $target = $relationship.GetAttribute("Target").TrimStart("/")
            if ($target.StartsWith("Files/", [System.StringComparison]::OrdinalIgnoreCase) -and
                $orphanAssetKeys.Contains($target.Substring("Files/".Length))) {
                [void]$relationship.ParentNode.RemoveChild($relationship)
                $removedRelationships++
            }
        }

        if ($removedRelationships -ne $orphanAssetKeys.Count) {
            throw "Expected to remove $($orphanAssetKeys.Count) orphan asset relationships; removed $removedRelationships."
        }

        $relationshipsWriterSettings = [System.Xml.XmlWriterSettings]::new()
        $relationshipsWriterSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
        $relationshipsWriterSettings.Indent = $false
        $relationshipsMemoryStream = [System.IO.MemoryStream]::new()
        $relationshipsWriter = [System.Xml.XmlWriter]::Create(
            $relationshipsMemoryStream,
            $relationshipsWriterSettings
        )
        try {
            $relationshipsDocument.Save($relationshipsWriter)
            $relationshipsWriter.Flush()
            $updatedRelationshipsBytes = $relationshipsMemoryStream.ToArray()
        }
        finally {
            $relationshipsWriter.Dispose()
            $relationshipsMemoryStream.Dispose()
        }

        $relationshipsEntry.Delete()
        $updatedRelationshipsEntry = $archive.CreateEntry(
            "_rels/files.origin.rels",
            [System.IO.Compression.CompressionLevel]::Optimal
        )
        $updatedRelationshipsStream = $updatedRelationshipsEntry.Open()
        try {
            $updatedRelationshipsStream.Write(
                $updatedRelationshipsBytes,
                0,
                $updatedRelationshipsBytes.Length
            )
        }
        finally {
            $updatedRelationshipsStream.Dispose()
        }
    }

    $templateMapMatch = [regex]::Match(
        $mapXml,
        '<x:String x:Key="([^"]+)">CopilotCoESite\.xml</x:String>'
    )
    if (-not $templateMapMatch.Success) {
        throw "Could not locate the CopilotCoESite.xml mapping in the PnP package."
    }

    $templateEntryName = "Files/$($templateMapMatch.Groups[1].Value)"
    $templateEntry = $archive.GetEntry($templateEntryName)
    if (-not $templateEntry) {
        throw "The mapped PnP template file was not found: $templateEntryName"
    }

    $templateStream = $templateEntry.Open()
    try {
        $templateReader = [System.IO.StreamReader]::new($templateStream)
        try {
            $templateXml = $templateReader.ReadToEnd()
        }
        finally {
            $templateReader.Dispose()
        }
    }
    finally {
        $templateStream.Dispose()
    }

    $templateXml = $templateXml.Replace(
        "Adoption Checklist for EAP",
        "Copilot Adoption Checklist"
    )
    $templateXml = $templateXml.Replace(
        "Adoption%20Checklist%20for%20EAP",
        "Copilot%20Adoption%20Checklist"
    )
    $templateXml = $templateXml.Replace(
        "Select early adopter program users",
        "Select pilot participants"
    )
    $templateXml = $templateXml.Replace(
        "Select employees who will use new capabilities and share feedback.",
        "Select a small pilot group for structured, non-sensitive testing and feedback."
    )
    $templateXml = $templateXml.Replace(
        "Onboard executives to Executive Customer Advisory Board",
        "Schedule leadership feedback review"
    )
    $templateXml = $templateXml.Replace(
        "Invite executive level staff to thought leadership series",
        "Review pilot outcomes, risks, and next steps with leadership."
    )
    $templateXml = $templateXml.Replace(
        "Microsoft feedback sessions",
        "Copilot product feedback review"
    )
    $templateXml = $templateXml.Replace(
        "Participate in Microsoft led feedback sessions",
        "Review product updates and share feedback through approved channels."
    )
    $templateXml = $templateXml.Replace(
        "If your organization has YouTube blocked the embedded videos below will not render. Please reach out to your Microsoft account team for assistance.",
        "Embedded video availability depends on your tenant's media policies and user access."
    )
    $templateXml = $templateXml.Replace(
        'http://linkless.header/',
        '{site}/SitePages/Adoption-Best-Practices.aspx'
    )
    $templateXml = $templateXml.Replace(
        'https://techcommunity.microsoft.com/t5/microsoft-365-copilot/bd-p/Microsoft365Copilot',
        'https://techcommunity.microsoft.com/category/microsoft-copilot/discussions/microsoft-copilot'
    )
    # Keep the stable page address; replace the captured embeds below with official landing-page links.
    $templateXml = $templateXml.Replace(
        "AI,-Copilot-and-ChatGPT-on-Microsoft-Mechanics.aspx",
        "Copilot-on-Microsoft-Mechanics.aspx"
    )

    $siteDescription = "$DisplayName. $SampleNotice"
    $xmlDocument = [System.Xml.XmlDocument]::new()
    $xmlDocument.PreserveWhitespace = $true
    $xmlDocument.LoadXml($templateXml)
    Set-CoEXmlTextReplacement $xmlDocument "Microsoft 365 Copilot EAP Announcements" "$ShortName Copilot CoE Updates"
    Set-CoEXmlTextReplacement $xmlDocument "Some features discussed may require additional licensing and are not a part of the initial Copilot Early Adopter Program." "Some features shown may require additional licensing and may not be available in every tenant; confirm licensing and availability before relying on them."
    Set-CoEXmlTextReplacement $xmlDocument "Copilot Early Adopter Program" "$ShortName Copilot CoE - $EnvironmentLabel"
    Set-CoEXmlTextReplacement $xmlDocument "CONTOSO TRAINING" "$ShortName COPILOT COE - $($EnvironmentLabel.ToUpperInvariant())"
    foreach ($node in @($xmlDocument.SelectNodes('//@*|//text()'))) {
        if ($node.Value) { $node.Value = Convert-CoECapturedAssetUrls $node.Value }
    }

    $namespaceManager = [System.Xml.XmlNamespaceManager]::new($xmlDocument.NameTable)
    $namespaceManager.AddNamespace(
        "pnp",
        "http://schemas.dev.office.com/PnP/2022/09/ProvisioningSchema"
    )

    $provisioning = $xmlDocument.SelectSingleNode("/pnp:Provisioning", $namespaceManager)
    if (-not $provisioning) {
        throw "The PnP provisioning document root was not found."
    }
    $provisioning.SetAttribute("DisplayName", $DisplayName)
    $provisioning.SetAttribute("Description", "$ShortName Copilot CoE - $EnvironmentLabel")

    $siteCollection = $xmlDocument.SelectSingleNode(
        "//pnp:SiteCollection",
        $namespaceManager
    )
    if (-not $siteCollection) {
        throw "The PnP package does not contain a site collection definition."
    }
    $siteCollection.SetAttribute("IsPublic", "false")
    $siteCollection.RemoveAttribute("MembersCanShare")
    if ($siteCollection.GetAttribute("IsPublic") -ne "false") {
        throw "The parent site template must create a private group."
    }
    $siteCollection.SetAttribute("Description", $siteDescription)

    # New Team sites block custom script, and PnP writes list property bags without a
    # NoScript check, which fails with E_ACCESSDENIED. The source entry (Site Assets
    # IsAttachmentLibrary) is a captured system value, so drop list property bags.
    foreach ($listPropertyBag in @($xmlDocument.SelectNodes(
        "//pnp:ListInstance/pnp:PropertyBagEntries",
        $namespaceManager
    ))) {
        [void]$listPropertyBag.ParentNode.RemoveChild($listPropertyBag)
    }
    if ($xmlDocument.SelectNodes("//pnp:ListInstance/pnp:PropertyBagEntries", $namespaceManager).Count -gt 0) {
        throw "List property bag entries remain in the CoE PnP template; they fail on sites that block custom script."
    }

    # The same NoScript block rejects any write to the site's master page, even the default
    # seattle.master that new Team sites already use. Drop the master page and alternate CSS
    # settings; the welcome page, navigation, and other web settings still apply.
    foreach ($webSettings in @($xmlDocument.SelectNodes("//pnp:WebSettings", $namespaceManager))) {
        $webSettings.SetAttribute("MembersCanShare", "false")
        foreach ($attribute in @("MasterPageUrl", "CustomMasterPageUrl", "AlternateCSS")) {
            if ($webSettings.HasAttribute($attribute)) { $webSettings.RemoveAttribute($attribute) }
        }
        # Keep the site's navigation on the left, where the CoE guidance and the A-to-Z sort expect it.
        $webSettings.SetAttribute("HorizontalQuickLaunch", "false")
    }
    if ($xmlDocument.SelectNodes("//pnp:WebSettings", $namespaceManager).Count -eq 0 -or
        $xmlDocument.SelectNodes("//pnp:WebSettings[not(@MembersCanShare='false')]", $namespaceManager).Count -gt 0) {
        throw "The web settings template must prevent members from sharing."
    }
    if ($xmlDocument.SelectNodes("//pnp:WebSettings[@MasterPageUrl or @CustomMasterPageUrl or @AlternateCSS]", $namespaceManager).Count -gt 0) {
        throw "Master page settings remain in the CoE PnP template; they fail on sites that block custom script."
    }
    # The site header handler is also rejected on these sites (E_ACCESSDENIED); the header keeps
    # SharePoint's default layout and the installer sets the logo separately.
    foreach ($siteHeader in @($xmlDocument.SelectNodes("//pnp:ProvisioningTemplate/pnp:Header", $namespaceManager))) {
        [void]$siteHeader.ParentNode.RemoveChild($siteHeader)
    }

    $checklist = $xmlDocument.SelectSingleNode(
        '//pnp:ListInstance[@Title="Copilot Adoption Checklist"]',
        $namespaceManager
    )
    if (-not $checklist) {
        throw "The rebranded Copilot Adoption Checklist was not found."
    }
    $checklist.SetAttribute(
        "Description",
        "Sample planning actions. $SampleNotice Review and adapt before production use."
    )

    foreach ($row in $checklist.SelectNodes(".//pnp:DataRow", $namespaceManager)) {
        $values = @{}
        foreach ($value in $row.SelectNodes("./pnp:DataValue", $namespaceManager)) {
            $values[$value.GetAttribute("FieldName")] = $value
        }

        if ($values.ContainsKey("Title")) {
            switch ($values["Title"].InnerText) {
                "Identify Technology Adoption Team members" {
                    $values["Title"].InnerText = "Confirm $ShortName CoE roles and accountable owners"
                }
                "Participate in Art of the Possible workshop" {
                    $values["Title"].InnerText = "Prioritize Copilot scenarios with stakeholders"
                }
                "Install Copilot Center of Excellence Teams template" {
                    $values["Title"].InnerText = "Validate the Teams and SharePoint CoE template"
                }
                "Complete technical readiness work" {
                    $values["Title"].InnerText = "Review licensing, security, and service readiness"
                }
                "Deploy licenses" {
                    $values["Title"].InnerText = "Confirm licensing and feature availability"
                }
                "Send welcome email and invite into Copilot COE Team" {
                    $values["Title"].InnerText = "Publish CoE onboarding guidance"
                }
                "Schedule Learning Series activities" {
                    $values["Title"].InnerText = "Plan learning sessions and office hours"
                }
                "Schedule feedback roundtables" {
                    $values["Title"].InnerText = "Plan user feedback reviews"
                }
                "Review Adoption Score reporting" {
                    $values["Title"].InnerText = "Define adoption measures and reporting cadence"
                }
                "Copilot product feedback review" {
                    $values["Title"].InnerText = "Review product updates and feedback channels"
                }
                "Nominate success stories" {
                    $values["Title"].InnerText = "Document approved, non-sensitive success stories"
                }
                "Conduct service health review" {
                    $values["Title"].InnerText = "Review service health and support themes"
                }
                "Train Copilot Champion Team" {
                    $values["Title"].InnerText = "Prepare and support the Copilot champion network"
                }
            }
        }
    }

    $adoptionPage = $xmlDocument.SelectSingleNode(
        '//pnp:ClientSidePage[@PageName="Adoption-Best-Practices.aspx"]',
        $namespaceManager
    )
    if ($adoptionPage) {
        $adoptionPage.SetAttribute("Title", "Copilot CoE Adoption Guide")
    }
    $rolesPage = $xmlDocument.SelectSingleNode(
        '//pnp:ClientSidePage[@PageName="Meet-your-ProjectTeam.aspx"]',
        $namespaceManager
    )
    if ($rolesPage) {
        $rolesPage.SetAttribute("Title", "CoE roles and contacts")
    }

    $pagesToRemove = @(
        $xmlDocument.SelectNodes(
            '//pnp:ClientSidePage[@PageName="Copilot-Capabilities.aspx" or @PageName="Early-Adopter-Program-Updates.aspx" or @PageName="News-and-Updates.aspx"]',
            $namespaceManager
        )
    )
    foreach ($page in $pagesToRemove) {
        [void]$page.ParentNode.RemoveChild($page)
    }

    # Legacy template content that dated the site or showed empty placeholders to end users.
    # The blog-updates page only held an empty News web part for this site's own (unused) news.
    foreach ($page in @($xmlDocument.SelectNodes('//pnp:ClientSidePage[@PageName="Microsoft-365-Copilot-Blog-Updates.aspx"]', $namespaceManager))) {
        [void]$page.ParentNode.RemoveChild($page)
    }
    # The two 2023 sample events; the kit seeds its own training calendar instead.
    foreach ($rows in @($xmlDocument.SelectNodes('//pnp:ListInstance[@Title="Events"]/pnp:DataRows', $namespaceManager))) {
        [void]$rows.ParentNode.RemoveChild($rows)
    }
    function Set-TemplateText([string]$PageName, [string]$Contains, [string]$Html) {
        $page = $xmlDocument.SelectSingleNode("//pnp:ClientSidePage[@PageName=`"$PageName`"]", $namespaceManager)
        if (-not $page) { throw "Template page not found: $PageName" }
        $property = @($page.SelectNodes('.//pnp:CanvasControl[@WebPartType="Text"]//pnp:CanvasControlProperty[@Key="Text"]', $namespaceManager) |
            Where-Object { $_.GetAttribute("Value").Contains($Contains) })
        if ($property.Count -ne 1) { throw "Expected one text block containing '$Contains' on $PageName; found $($property.Count)." }
        $property[0].SetAttribute("Value", $Html)
    }
    $orgHtml = [System.Net.WebUtility]::HtmlEncode($OrgName)
    $nounHtml = [System.Net.WebUtility]::HtmlEncode($OrgNoun)
    Set-TemplateText "TrainingHome.aspx" "Meet Your Copilot Champions" (
        "<h4>Meet your Copilot champions</h4><p>Champions help colleagues get the most from Copilot and Microsoft 365, " +
        "with peer-to-peer learning in the context of everyday work. <a href=`"https://{fqdn}{site}/SitePages/Meet-your-Champions.aspx`">Find your department champion</a>.</p>")
    Set-TemplateText "Adoption-Best-Practices.aspx" "Use the Microsoft 365 Adoption Framework" (
        "<p><strong>How the CoE drives Copilot adoption at $orgHtml</strong></p><p>This guide adapts Microsoft's adoption approach to $orgHtml. " +
        "Copilot Chat is available now; the CoE's job is to help people use it safely and well within the $nounHtml's AI guidelines, " +
        "through champions, the Learning Series, and honest feedback. The checklist below is the CoE's working plan, and its owners update it as each step is completed.</p>")
    Set-TemplateText "Adoption-Best-Practices.aspx" "Use our resources to stay up to date" (
        "<span class=`"fontSizeMediumPlus`">Use these resources to stay up to date on Microsoft Copilot. New capabilities are released regularly, so the CoE reviews them every month.</span>")
    Set-TemplateText "Adoption-Best-Practices.aspx" "Listening to the people using the new capabilities" (
        "<span class=`"fontSizeMediumPlus`">Listening to the people who use Copilot shows how it works in real tasks. " +
        "The CoE gathers that feedback through Ask Us Anything and the feedback page, and passes product suggestions to Microsoft through approved channels.</span>")
    Set-TemplateText "Technical Readiness.aspx" "Review these resources to get your tenant ready" (
        "Review these resources to prepare the tenant for Microsoft Copilot. They cover the data, privacy, and security capabilities of Microsoft 365 and Copilot, " +
        "and Microsoft updates them as new capabilities become available. Use them alongside the <a href=`"https://adoption.microsoft.com/copilot/`">Microsoft Copilot adoption hub</a>.")

    $mechanicsPage = $xmlDocument.SelectSingleNode('//pnp:ClientSidePage[@PageName="Copilot-on-Microsoft-Mechanics.aspx"]', $namespaceManager)
    if ($mechanicsPage) {
        $textControls = @($mechanicsPage.SelectNodes('.//pnp:CanvasControl[@WebPartType="Text"]', $namespaceManager))
        if ($textControls.Count -eq 0) { throw "The Microsoft Mechanics page has no text control for official resource links." }
        $text = $textControls[0].SelectSingleNode('pnp:CanvasControlProperties/pnp:CanvasControlProperty[@Key="Text"]', $namespaceManager)
        $text.SetAttribute("Value", (
            "<h3>Microsoft Mechanics resources</h3><p>Use Microsoft's official hubs for current Copilot demonstrations and technical explanations. " +
            "Video availability depends on your organization's media policies and the publisher.</p><ul>" +
            "<li><a href=`"https://www.microsoft.com/mechanics`">Microsoft Mechanics</a></li>" +
            "<li><a href=`"https://techcommunity.microsoft.com/category/microsoftmechanics`">Microsoft Mechanics video hub</a></li></ul>"))
        foreach ($control in @($mechanicsPage.SelectNodes('.//pnp:CanvasControl', $namespaceManager))) {
            if ($control -ne $textControls[0]) { [void]$control.ParentNode.RemoveChild($control) }
        }
        foreach ($section in @($mechanicsPage.SelectNodes('pnp:Sections/pnp:Section[not(pnp:Controls/pnp:CanvasControl)]', $namespaceManager))) {
            [void]$section.ParentNode.RemoveChild($section)
        }
    }
    Set-CoETemplateBannerDefaults $xmlDocument $namespaceManager

    $trainingHome = $xmlDocument.SelectSingleNode('//pnp:ClientSidePage[@PageName="TrainingHome.aspx"]', $namespaceManager)
    # The home page's News web part showed SharePoint's empty "Create a news post" cards.
    foreach ($news in @($trainingHome.SelectNodes('.//pnp:CanvasControl[@WebPartType="News"]', $namespaceManager))) {
        [void]$news.ParentNode.RemoveChild($news)
    }
    # Hero tiles: point at the CoE's own pages and use still images instead of the May 2023 product GIFs.
    $heroControl = $trainingHome.SelectSingleNode('.//pnp:CanvasControl[@WebPartType="Hero"]', $namespaceManager)
    $hero = $heroControl.GetAttribute("JsonControlData") | ConvertFrom-Json -AsHashtable
    $heroTiles = @(Get-CoEHomeTiles -CustomTilesJson $HomeTilesJson)
    if ($hero["properties"]["content"].Count -ne $heroTiles.Count) { throw "The Hero web part no longer has $($heroTiles.Count) tiles." }
    $spc = $hero["serverProcessedContent"]
    for ($i = 0; $i -lt $heroTiles.Count; $i++) {
        $tile = $heroTiles[$i]
        $item = $hero["properties"]["content"][$i]
        $pageUrl = "{site}/SitePages/$($tile.Page)"
        $item["description"] = ""
        $item["alternateText"] = $tile.Title
        # Same-site pages open in place (the Hero web part opens a new tab unless openLinkInPlace is set).
        $item["openLinkInPlace"] = $true
        # Source tiles 4-5 were colour blocks (imageDisplayOption 1), so their images never showed.
        $item["imageDisplayOption"] = 3
        $item["isDefaultImage"] = $false
        $item["isDefaultImageLoaded"] = $false
        $item["isCustomImageLoaded"] = $true
        if ($item["type"] -eq "Image") { $item["type"] = "UrlLink" }
        if ($i -gt 0) {
            $item["image"]["widthFactor"] = 0.25
            $item["image"]["minCanvasWidth"] = 640
        }
        $item["image"]["id"] = "{fileuniqueid:$($tile.Image)}"
        $item["image"]["resolvedUrl"] = "https://{fqdn}{site}/$($tile.Image)"
        $item["image"]["imageUrl"] = "https://{fqdn}{site}/$($tile.Image)"
        $item["previewImage"]["imageUrl"] = ""
        if ($item["previewImage"].ContainsKey("resolvedUrl")) { $item["previewImage"]["resolvedUrl"] = "" }
        $spc["searchablePlainTexts"]["content[$i].title"] = $tile.Title
        $spc["searchablePlainTexts"]["content[$i].alternateText"] = $tile.Title
        $spc["imageSources"]["content[$i].image.url"] = "{site}/$($tile.Image)"
        $spc["imageSources"].Remove("content[$i].previewImage.url")
        $spc["links"]["content[$i].link"] = $pageUrl
        if ($spc["links"].Contains("content[$i].callToActionLink")) { $spc["links"]["content[$i].callToActionLink"] = $pageUrl }
        # The first tile's call to action came from the source template ("See the capabilities"); keep it on-message.
        if ($i -eq 0 -and $spc["searchablePlainTexts"].Contains("content[0].callToActionText")) { $spc["searchablePlainTexts"]["content[0].callToActionText"] = "Start here" }
    }
    $heroControl.SetAttribute("JsonControlData", ($hero | ConvertTo-Json -Depth 30 -Compress))

    # Template wording that still used the old product name or addressed "your" organization.
    $wordingFixes = [ordered]@{
        "View our Microsoft Mechanics Video Series for Microsoft 365 Copilot" = "View the Microsoft Mechanics video series on Microsoft Copilot"
        "Microsoft 365 Copilot Forum" = "Microsoft Copilot Forum"
        "are critical to your success." = "are critical to the $nounHtml's success."
        "Understand the key capabilities of Microsoft 365 Copilot" = "Understand the key capabilities of Microsoft Copilot"
        "new scenarios for Microsoft 365 Copilot capabilities" = "new scenarios for Microsoft Copilot capabilities"
        # Vendor's own Technical Readiness.aspx link - a redirecting URL, not the final one the kit's own
        # Copilot-FAQs.md and 06-Stay-Current.md guides already use for the identical destination. Found by
        # searching the vendor .pnp template contents directly (03_Build\SourceOriginal\CopilotCoESite\
        # CopilotCoESite.pnp -> Files\*.xml), not just kit source text, after an earlier link sweep missed it.
        "https://learn.microsoft.com/en-us/deployoffice/privacy/microsoft-365-copilot" = "https://learn.microsoft.com/en-us/microsoft-365/copilot/microsoft-365-copilot-privacy"
    }
    $wordingHits = @{}
    foreach ($node in @($xmlDocument.SelectNodes('//@*|//text()'))) {
        $value = $node.Value
        if (-not $value) { continue }
        $updated = $value
        foreach ($fix in $wordingFixes.GetEnumerator()) {
            if ($updated.Contains($fix.Key)) {
                $updated = $updated.Replace($fix.Key, $fix.Value)
                $wordingHits[$fix.Key] = $true
            }
        }
        if ($updated -ne $value) { $node.Value = $updated }
    }
    foreach ($key in $wordingFixes.Keys) {
        if (-not $wordingHits.ContainsKey($key)) { Write-Warning "Template wording not found (source changed?): $key" }
    }
    foreach ($control in @($xmlDocument.SelectNodes("//pnp:CanvasControl", $namespaceManager))) {
        if ($control.GetAttribute("JsonControlData") -match "Early Access Program|m365-early-access-program") {
            [void]$control.ParentNode.RemoveChild($control)
            continue
        }
        if ($control.GetAttribute("WebPartType") -eq "QuickLinks" -and $control.HasAttribute("JsonControlData")) {
            $data = $control.GetAttribute("JsonControlData") | ConvertFrom-Json -AsHashtable
            if ($data["serverProcessedContent"]["searchablePlainTexts"]["title"] -eq "Resources") {
                foreach ($resource in $resourceLinks) {
                    $url = $resource.url
                    if ($url -eq "{ask-channel-url}") {
                        $url = "{site}/SitePages/Meet-your-ProjectTeam.aspx"
                    }
                    $data.serverProcessedContent.links["items[$($resource.index)].sourceItem.url"] = $url
                }
                $control.SetAttribute("JsonControlData", ($data | ConvertTo-Json -Depth 30 -Compress))
            }
        }
    }

    $orphanPageAssets = @(
        $xmlDocument.SelectNodes(
            '//pnp:File[contains(@Src, "SitePages/Early-Adopter-Program-Updates/") or contains(@Src, "SitePages/News-and-Updates/")]',
            $namespaceManager
        )
    )
    foreach ($asset in $orphanPageAssets) {
        [void]$asset.ParentNode.RemoveChild($asset)
    }

    foreach ($folder in @(
        $xmlDocument.SelectNodes(
            '//pnp:Folder[@Name="Early-Adopter-Program-Updates" or @Name="News-and-Updates"]',
            $namespaceManager
        )
    )) {
        [void]$folder.ParentNode.RemoveChild($folder)
    }

    $navigationNodes = @(
        $xmlDocument.SelectNodes("//pnp:NavigationNode", $namespaceManager)
    )
    foreach ($node in $navigationNodes) {
        $title = $node.GetAttribute("Title")
        $url = $node.GetAttribute("Url")
        # "News and Updates" only leads to an empty News web part until the CoE posts news.
        if ($title -match "Early Adopter|Copilot Capabilities" -or $title -in @("Recent", "News and Updates") -or
            $url -match "Early-Adopter-Program-Updates|News-and-Updates\.aspx|Copilot-Capabilities\.aspx|Microsoft-365-Copilot-Blog-Updates\.aspx") {
            [void]$node.ParentNode.RemoveChild($node)
            continue
        }
        if ($url -eq "{site}/SitePages/Adoption-Best-Practices.aspx") {
            $node.SetAttribute("IsExternal", "false")
        }
    }

    $manifest = @($xmlDocument.SelectNodes("//pnp:File", $namespaceManager) | ForEach-Object {
        $leaf = $_.SelectSingleNode('pnp:Properties/pnp:Property[@Key="FileLeafRef"]', $namespaceManager)
        $name = if ($leaf) { $leaf.GetAttribute("Value") } else { $_.GetAttribute("Src").Split("/")[-1] }
        "$($_.GetAttribute('Folder').TrimEnd('/'))/$name"
    })
    $manifest | ConvertTo-Json | Set-Content (Join-Path $stage "SiteAssetManifest.json") -Encoding utf8

    $xmlWriterSettings = [System.Xml.XmlWriterSettings]::new()
    $xmlWriterSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $xmlWriterSettings.Indent = $false
    $xmlWriterSettings.OmitXmlDeclaration = $true
    $stringBuilder = [System.Text.StringBuilder]::new()
    $stringWriter = [System.IO.StringWriter]::new($stringBuilder)
    $xmlWriter = [System.Xml.XmlWriter]::Create($stringWriter, $xmlWriterSettings)
    try {
        $xmlDocument.Save($xmlWriter)
        $xmlWriter.Flush()
        $updatedTemplateXml = $stringBuilder.ToString()
    }
    finally {
        $xmlWriter.Dispose()
        $stringWriter.Dispose()
    }

    $remainingMarkers = @(@(
        "EAP",
        "Early Adopter",
        "Early Access Program",
        "m365-early-access-program",
        "Contoso",
        "linkless.header"
    ) | Where-Object { $updatedTemplateXml -match [regex]::Escape($_) })
    # A marker that is part of the institution's own values (for example ShortName "Contoso") is expected output, not a leftover.
    $configuredText = "$OrgName|$OrgNoun|$DisplayName|$ShortName|$EnvironmentLabel|$SampleNotice"
    $remainingMarkers = @($remainingMarkers | Where-Object {
        if ($configuredText -match [regex]::Escape($_)) {
            Write-Warning "Skipping leftover check for '$_' because it appears in your Deployment-Settings values."
            $false
        } else { $true }
    })
    if ($remainingMarkers.Count -gt 0) {
        foreach ($marker in $remainingMarkers) {
            foreach ($match in [regex]::Matches($updatedTemplateXml, [regex]::Escape($marker))) {
                $start = [Math]::Max(0, $match.Index - 160)
                $length = [Math]::Min(360, $updatedTemplateXml.Length - $start)
                Write-Host "$marker context: $($updatedTemplateXml.Substring($start, $length))"
            }
        }
        throw "The CoE PnP template still contains these source placeholders: $($remainingMarkers -join ', ')."
    }

    $templateEntry.Delete()
    $newTemplateEntry = $archive.CreateEntry(
        $templateEntryName,
        [System.IO.Compression.CompressionLevel]::Optimal
    )
    $newTemplateStream = $newTemplateEntry.Open()
    try {
        $templateBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($updatedTemplateXml)
        $newTemplateStream.Write($templateBytes, 0, $templateBytes.Length)
    }
    finally {
        $newTemplateStream.Dispose()
    }
}
finally {
    $archive.Dispose()
}

Import-Module PnP.PowerShell -RequiredVersion 3.2.0 -ErrorAction Stop
$null = Read-PnPTenantTemplate -Path $packageOutput -ErrorAction Stop

$teamTemplateXml = Get-Content -LiteralPath $sourceTeamTemplate -Raw -Encoding UTF8
$teamTemplateXml = $teamTemplateXml.Replace(
    "https://copilot.cloud.microsoft/en-US/prompts/all",
    "https://learn.microsoft.com/en-us/microsoft-365/copilot/copilot-prompt-gallery"
)
$teamTemplateXml = $teamTemplateXml.Replace(
    "https://aka.ms/CopilotLab",
    "https://learn.microsoft.com/en-us/microsoft-365/copilot/copilot-prompt-gallery"
)
$teamTemplateXml = $teamTemplateXml.Replace(
    "https://adoption.microsoft.com/en-us/copilot-scenario-library/",
    $ScenarioLibraryUrl
)
$teamTemplateXml = $teamTemplateXml.Replace(
    "https://www.microsoft.com/en-au/microsoft-365/roadmap?filters=Microsoft%20Copilot%20for%20Microsoft%20365",
    "https://learn.microsoft.com/en-us/microsoft-365/admin/manage/roadmap?view=o365-worldwide"
)
$teamTemplateXml = $teamTemplateXml.Replace(
    "https://techcommunity.microsoft.com/t5/copilot-for-microsoft-365/your-path-to-value-with-copilot-for-microsoft-365/ba-p/4078744",
    "https://techcommunity.microsoft.com/blog/microsoft-copilot-blog/your-path-to-value-with-copilot-for-microsoft-365/4078744"
)
$teamTemplateXml = $teamTemplateXml.Replace(
    ">Copilot Lab</a>",
    ">Copilot Prompt Gallery Guide</a>"
)

$teamDocument = [System.Xml.XmlDocument]::new()
$teamDocument.PreserveWhitespace = $true
$teamDocument.LoadXml($teamTemplateXml)
$teamNamespaceManager = [System.Xml.XmlNamespaceManager]::new($teamDocument.NameTable)
$teamNamespaceManager.AddNamespace(
    "pnp",
    "http://schemas.dev.office.com/PnP/2022/09/ProvisioningSchema"
)
foreach ($message in @($teamDocument.SelectNodes("//pnp:Message", $teamNamespaceManager))) {
    $payload = (Convert-CoELegacyMessageJson $message.InnerText) | ConvertFrom-Json -AsHashtable
    if (-not $payload.ContainsKey("body") -or $payload.body.contentType -notin @("html", "text") -or
        $payload.body.content -isnot [string]) {
        throw "A Teams message must contain a valid body contentType and string content."
    }
    $welcome = "Welcome to the Microsoft 365 Center of Excellence team.  This template was configured for your use as you deploy, configure and use Microsoft 365 Copilot features.  It leverages best practices from the Microsoft 365 Adoption Framework and can be tailored to your own best practices and team culture."
    $newWelcome = "Welcome to the $DisplayName. Use this Team to learn Copilot, share safe prompts, and ask questions. $SampleNotice"
    if ($payload.body.contentType -eq "html") { $newWelcome = [Net.WebUtility]::HtmlEncode($newWelcome) }
    $payload.body.content = $payload.body.content.Replace($welcome, $newWelcome)
    $json = $payload | ConvertTo-Json -Depth 100 -Compress
    # Escaping '>' avoids the CDATA terminator even in arbitrary organization text.
    $json = $json.Replace(">", "\u003e")
    $null = $json | ConvertFrom-Json
    $message.RemoveAll()
    [void]$message.AppendChild($teamDocument.CreateCDataSection($json))
}

$team = $teamDocument.SelectSingleNode("//pnp:Team", $teamNamespaceManager)
if (-not $team) {
    throw "The Microsoft Team definition was not found in the source TeamTemplate.xml."
}
$teamDocument.DocumentElement.SetAttribute(
    "DisplayName",
    $DisplayName
)
$teamDocument.DocumentElement.SetAttribute("Description", $siteDescription)
$team.SetAttribute("Visibility", "Private")
$team.SetAttribute("Description", $siteDescription)

foreach ($channel in @(
    $team.SelectNodes(
        './pnp:Channels/pnp:Channel[@MembershipType="Private"]',
        $teamNamespaceManager
    )
)) {
    [void]$channel.ParentNode.RemoveChild($channel)
}

foreach ($tab in $teamDocument.SelectNodes("//pnp:Tab", $teamNamespaceManager)) {
    $tabName = $tab.GetAttribute("DisplayName")
    $configuration = $tab.SelectSingleNode("pnp:Configuration", $teamNamespaceManager)
    if (-not $configuration) {
        continue
    }

    if ($tabName -eq "Prompt Lab" -or $tabName -eq "Copilot Lab") {
        $tab.SetAttribute("DisplayName", "Copilot Prompt Gallery Guide")
        $promptGuide = "https://learn.microsoft.com/en-us/microsoft-365/copilot/copilot-prompt-gallery"
        $configuration.SetAttribute("ContentUrl", $promptGuide)
        $configuration.SetAttribute("WebsiteUrl", $promptGuide)
    }
    elseif ($tabName -eq "Top 10 to try") {
        $topTen = "https://{parameter:fqdn}/{parameter:inclusionPath}/{parameter:mailNickname}/Shared%20Documents/Ask%20Us%20Anything%20%F0%9F%93%A2/Microsoft365Copilot_Top10toTry_Handout.pptx"
        $tab.SetAttribute(
            "TeamsAppId",
            "com.microsoft.teamspace.tab.file.staticviewer.powerpoint"
        )
        $configuration.SetAttribute("ContentUrl", $topTen)
        $configuration.SetAttribute("WebsiteUrl", $topTen)
    }
    elseif ($tabName -eq "Scenario Library") {
        # Default opens the education scenarios; ScenarioLibraryUrl in Deployment-Settings.json overrides it.
        $scenarioLibrary = $ScenarioLibraryUrl
        $configuration.SetAttribute("ContentUrl", $scenarioLibrary)
        $configuration.SetAttribute("WebsiteUrl", $scenarioLibrary)
    }
    elseif ($tabName -eq "Copilot Roadmap") {
        $roadmapGuide = "https://learn.microsoft.com/en-us/microsoft-365/admin/manage/roadmap?view=o365-worldwide"
        $tab.SetAttribute("DisplayName", "AI at Work Roadmap Guide")
        $configuration.SetAttribute("ContentUrl", $roadmapGuide)
        $configuration.SetAttribute("WebsiteUrl", $roadmapGuide)
    }
}

$teamWriterSettings = [System.Xml.XmlWriterSettings]::new()
$teamWriterSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
$teamWriterSettings.Indent = $false
$teamWriterSettings.OmitXmlDeclaration = $true
$teamStringBuilder = [System.Text.StringBuilder]::new()
$teamStringWriter = [System.IO.StringWriter]::new($teamStringBuilder)
$teamXmlWriter = [System.Xml.XmlWriter]::Create($teamStringWriter, $teamWriterSettings)
try {
    $teamDocument.Save($teamXmlWriter)
    $teamXmlWriter.Flush()
    $updatedTeamXml = $teamStringBuilder.ToString()
}
finally {
    $teamXmlWriter.Dispose()
    $teamStringWriter.Dispose()
}

if ($team.GetAttribute("Visibility") -ne "Private") {
    throw "The generated CoE Team template must keep the Team private."
}
if ($updatedTeamXml -match 'MembershipType="Private"|copilot\.cloud\.microsoft/en-US/prompts/all|http://linkless\.header') {
    throw "The generated CoE Team template still contains a private channel or an invalid placeholder link."
}

[System.IO.File]::WriteAllText(
    $teamTemplateOutput,
    $updatedTeamXml,
    [System.Text.UTF8Encoding]::new($false)
)
$null = Read-PnPTenantTemplate -Path $teamTemplateOutput -ErrorAction Stop

foreach ($name in @("CopilotCoESite.pnp", "TeamTemplate-CoE.xml", "SiteAssetManifest.json")) {
    Move-Item -LiteralPath (Join-Path $stage $name) -Destination (Join-Path $buildFolder $name) -Force
}

[pscustomobject]@{
    PackageTemplate = Join-Path $buildFolder "CopilotCoESite.pnp"
    TeamTemplate    = Join-Path $buildFolder "TeamTemplate-CoE.xml"
    TeamVisibility  = "Private"
    StandardChannels = "General; Share Your Prompt; Ask Us Anything"
}
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
