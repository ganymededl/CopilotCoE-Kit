# Dot-source after SecurityPosture.ps1. No connection or deployment occurs on import.
function Get-CoEHeadingAnchor([string]$Heading) {
    return ($Heading.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
}

function Get-CoECatalogValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return ,$Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return ,$property.Value }
    return $null
}

function Assert-CoECatalogString($Row, [string]$Name, [string]$Context, [switch]$Required) {
    $value = Get-CoECatalogValue $Row $Name
    if ($value -isnot [string]) { throw "$Context : '$Name' must exist and be a string." }
    if ($Required -and [string]::IsNullOrWhiteSpace($value)) { throw "$Context : '$Name' is required." }
    return $value
}

function Resolve-CoECatalogUrl([string]$Value, [string]$Context, [string]$SiteUrl = "", [switch]$AllowEmpty) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($AllowEmpty) { return "" }
        throw "$Context : a nonempty HTTPS URL is required."
    }
    $value = $Value.Trim()
    if ($value -match '[\\\x00-\x20]' -or $value.StartsWith("//")) {
        throw "$Context : URL must be HTTPS without backslashes, whitespace, or a network-path reference."
    }
    $uri = $null
    if ($value -match '^[A-Za-z][A-Za-z0-9+.-]*:') {
        if (-not [uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) {
            throw "$Context : invalid absolute HTTPS URL."
        }
    } else {
        if (-not $SiteUrl -or -not [uri]::TryCreate([uri]($SiteUrl.TrimEnd("/") + "/"), $value, [ref]$uri)) {
            throw "$Context : invalid HTTPS URL '$Value'."
        }
    }
    if ($uri.Scheme -ne "https" -or -not $uri.Host -or $uri.UserInfo) {
        throw "$Context : URL must use absolute HTTPS and cannot contain credentials."
    }
    return $uri.AbsoluteUri
}

function Assert-CoECatalogSiteUrl([string]$SiteUrl) {
    $resolved = Resolve-CoECatalogUrl $SiteUrl "Catalog site"
    $uri = [uri]$resolved
    if ($uri.Query -or $uri.Fragment) { throw "Catalog SiteUrl must not contain a query or fragment." }
    return $resolved.TrimEnd("/")
}

function Resolve-CoESharePointReturnedUrl([string]$Value, [string]$Context, [string]$SiteUrl) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Context : a nonempty SharePoint URL is required." }
    $site = Assert-CoECatalogSiteUrl $SiteUrl
    $siteUri = [uri]$site
    $value = $Value.Trim()
    if ($value -match '[\\\x00-\x1f]' -or $value.StartsWith("//") -or $value -match '[?#]') {
        throw "$Context : SharePoint URL contains an unsafe path, query, or fragment."
    }
    $uri = $null
    if ([uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) {
        if ($uri.Scheme -ne "https" -or $uri.UserInfo -or $uri.Authority -ne $siteUri.Authority) {
            throw "$Context : SharePoint URL is outside the expected site host."
        }
        $path = [uri]::UnescapeDataString($uri.AbsolutePath)
    } else {
        $path = if ($value.StartsWith("/")) { $value } else { $siteUri.AbsolutePath.TrimEnd("/") + "/" + $value }
    }
    $sitePath = [uri]::UnescapeDataString($siteUri.AbsolutePath).TrimEnd("/") + "/"
    $plainPath = [uri]::UnescapeDataString($path)
    if (-not $plainPath.StartsWith($sitePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context : SharePoint URL is outside the expected site path."
    }
    $encodedPath = "/" + (($plainPath.TrimStart("/") -split "/" | ForEach-Object { [uri]::EscapeDataString($_) }) -join "/")
    return ([uri]::new($siteUri.GetLeftPart([UriPartial]::Authority) + $encodedPath)).AbsoluteUri
}

function ConvertTo-CoECatalogDate([string]$Value, [string]$Context) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Value, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$date)) {
        throw "$Context : date must be a valid ISO yyyy-MM-dd date."
    }
    return $date
}

function ConvertTo-CoELearningSeeds([object[]]$Items, [string]$SiteUrl, [string]$PromptLibraryUrl = "") {
    $site = Assert-CoECatalogSiteUrl $SiteUrl
    $promptUrl = if ($PromptLibraryUrl) { Resolve-CoECatalogUrl $PromptLibraryUrl "PromptLibraryUrl" } else { "" }
    $ids = @{}
    $steps = @{}
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $Items) {
        $context = "Learning seed id='$([string](Get-CoECatalogValue $row 'id'))', path='$([string](Get-CoECatalogValue $row 'path'))'"
        $values = [ordered]@{}
        foreach ($field in @("id", "title", "path", "audience", "product", "resourceUrl", "practicePromptTitle",
            "practiceUrl", "expectedResult", "owner", "reviewedOn", "lmsUrl")) {
            $required = $field -in @("id", "title", "path", "audience", "expectedResult", "resourceUrl")
            $values[$field] = Assert-CoECatalogString $row $field $context -Required:$required
        }
        foreach ($field in @("id", "title", "path", "audience")) { $values[$field] = $values[$field].Trim() }
        foreach ($field in @("step", "minutes")) {
            $number = Get-CoECatalogValue $row $field
            if ($number -isnot [int] -and $number -isnot [long]) {
                throw "$context : '$field' must be an integer."
            }
            if ($number -lt 0 -or ($field -eq "step" -and $number -eq 0)) {
                throw "$context : step must be a positive integer and minutes a nonnegative integer."
            }
            $values[$field] = $number
        }
        $requirement = Assert-CoECatalogString $row "requirement" $context -Required
        $choices = @("Recommended", "Required", "Optional")
        if ($requirement -notin $choices) { throw "$context : requirement must be Recommended, Required, or Optional." }
        $values["requirement"] = @($choices | Where-Object { $_ -eq $requirement })[0]
        if ($ids.ContainsKey($values.id)) { throw "$context : duplicate LearningId '$($values.id)'." }
        $ids[$values.id] = $true
        $stepKey = ConvertTo-Json @($values.path.ToLowerInvariant(), $values.audience.ToLowerInvariant(), $values.step) -Compress
        if ($steps.ContainsKey($stepKey)) { throw "$context : duplicate path + audience + step '$($values.step)'." }
        $steps[$stepKey] = $true
        $values.resourceUrl = Resolve-CoECatalogUrl $values.resourceUrl "$context resourceUrl" $site
        if ($promptUrl -and $values.practiceUrl -imatch '^SitePages/Guide-Prompt-Library\.aspx(?:#[a-z0-9-]+)?$') {
            $values.practiceUrl = $promptUrl
        }
        $values.practiceUrl = Resolve-CoECatalogUrl $values.practiceUrl "$context practiceUrl" $site -AllowEmpty
        $values.lmsUrl = Resolve-CoECatalogUrl $values.lmsUrl "$context lmsUrl" $site -AllowEmpty
        $null = ConvertTo-CoECatalogDate $values.reviewedOn "$context reviewedOn"
        $result.Add([pscustomobject]$values)
    }
    return $result.ToArray()
}

function Read-CoELearningSeeds {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$SiteUrl,
        [string]$PromptLibraryUrl = "")
    $document = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $versionFound = $false
    foreach ($field in @("version", "schemaVersion")) {
        $value = Get-CoECatalogValue $document $field
        if ($null -ne $value) {
            $versionFound = $true
            if (($value -isnot [int] -and $value -isnot [long]) -or $value -ne 1) {
                throw "Learning seed file '$Path': $field must be integer 1."
            }
        }
    }
    $items = Get-CoECatalogValue $document "items"
    if (-not $versionFound -or $items -isnot [array]) {
        throw "Learning seed file '$Path': version/schemaVersion 1 and an items array are required."
    }
    ConvertTo-CoELearningSeeds -Items $items -SiteUrl $SiteUrl -PromptLibraryUrl $PromptLibraryUrl
}

function ConvertTo-CoEAgentSeeds([object[]]$Items) {
    $urls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $titles = @{}
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $Items) {
        $context = "Agent seed '$([string](Get-CoECatalogValue $row 'name'))'"
        $values = [ordered]@{}
        foreach ($field in @("name", "url")) {
            $values[$field] = Assert-CoECatalogString $row $field $context
        }
        foreach ($field in @("description", "audience", "examplePrompt", "owner")) {
            $value = Get-CoECatalogValue $row $field
            $values[$field] = if ($null -eq $value) { "" } else { Assert-CoECatalogString $row $field $context }
        }
        $values.name = $values.name.Trim()
        if (-not $values.url.Trim() -and $values.name -match '^<[^<>]+>$') { continue }
        $values.url = Resolve-CoECatalogUrl $values.url "$context url"
        if (-not $values.name -or $values.name -match '<[^<>]*>') {
            throw "$context : a real, non-placeholder name is required for a launch URL."
        }
        if (-not $urls.Add($values.url) -or $titles.ContainsKey($values.name)) {
            throw "$context : duplicate seed launch URL or title; resolve the ambiguity before deployment."
        }
        $titles[$values.name] = $true
        foreach ($field in @("product", "sources", "connections", "access", "allowedData", "backupOwner",
            "support", "reviewedOn", "nextReview")) {
            $value = Get-CoECatalogValue $row $field
            if ($null -ne $value) { $values[$field] = Assert-CoECatalogString $row $field $context }
        }
        $status = Get-CoECatalogValue $row "status"
        if ($null -eq $status) { $status = "Submitted" }
        if ($status -isnot [string] -or $status -notin @("Submitted", "Published", "Retired", "In review", "Rejected")) {
            throw "$context : invalid status. Customer review is required before publication."
        }
        $values.status = @("Submitted", "Published", "Retired", "In review", "Rejected") |
            Where-Object { $_ -eq $status } | Select-Object -First 1
        $featured = Get-CoECatalogValue $row "featured"
        if ($null -eq $featured) { $featured = $false }
        if ($featured -isnot [bool]) { throw "$context : featured must be a JSON boolean." }
        $values.featured = $featured
        $reviewed = ConvertTo-CoECatalogDate ([string]$values["reviewedOn"]) "$context reviewedOn"
        $next = ConvertTo-CoECatalogDate ([string]$values["nextReview"]) "$context nextReview"
        if ($values.status -eq "Published") {
            foreach ($required in @("owner", "sources", "access", "allowedData", "reviewedOn")) {
                if ([string]::IsNullOrWhiteSpace([string]$values[$required])) {
                    throw "$context : Published requires '$required' from customer review; starter metadata is not customer approval."
                }
            }
            if ($reviewed -gt (Get-Date).Date -or ($null -ne $next -and $next -lt $reviewed)) {
                throw "$context : customer review date cannot be future and nextReview cannot precede reviewedOn."
            }
        }
        $result.Add([pscustomobject]$values)
    }
    return $result.ToArray()
}

function Get-CoECatalogList([string]$Title, [string]$RelativeUrl, [string]$SiteUrl, $Connection) {
    $listUrl = $SiteUrl.TrimEnd("/") + "/" + $RelativeUrl
    $serverUrl = ([uri]$listUrl).AbsolutePath
    $lists = @(Get-PnPList -Includes RootFolder,BaseTemplate,EnableVersioning,EnableModeration,DraftVersionVisibility -Connection $Connection -ErrorAction Stop)
    $matches = @($lists | Where-Object {
        $_.Title -eq $Title -or $_.RootFolder.ServerRelativeUrl.TrimEnd("/") -eq $serverUrl
    })
    if ($matches.Count -gt 1) { throw "Catalog '$Title' has duplicate title/URL identities; no extra list will be created." }
    $created = $matches.Count -eq 0
    if ($created) {
        New-PnPList -Title $Title -Template GenericList -Url $RelativeUrl -EnableVersioning `
            -Connection $Connection -ErrorAction Stop | Out-Null
        # The cmdlet returns no object, and cached list lookups can miss this new list.
        $context = Get-PnPContext -Connection $Connection -ErrorAction Stop
        $list = $context.Web.GetList($serverUrl)
        $context.Load($list)
        $context.Load($list.RootFolder)
        Invoke-PnPQuery -Connection $Connection -ErrorAction Stop | Out-Null
        if (-not $list -or -not $list.Id) { throw "Catalog '$Title' creation did not return a list ID." }
    } else {
        $list = $matches[0]
        if ($list.BaseTemplate -ne 100 -or $list.RootFolder.ServerRelativeUrl.TrimEnd("/") -ne $serverUrl) {
            throw "Catalog '$Title' must be a native GenericList at '$RelativeUrl'; existing list was not replaced."
        }
        Assert-CoECatalogItemInheritance $list $Connection
    }
    [pscustomobject]@{ List = $list; Created = $created; ListUrl = $listUrl }
}

function Sync-CoECatalogFields($List, [hashtable]$Definitions, $Connection) {
    $fields = @(Get-PnPField -List $List.Id -Connection $Connection -ErrorAction Stop)
    foreach ($name in @($Definitions.Keys | Sort-Object { $Definitions[$_].Type -eq "Calculated" }, { $_ })) {
        $definition = $Definitions[$name]
        $matches = @($fields | Where-Object InternalName -eq $name)
        if ($matches.Count -gt 1) { throw "Catalog field '$name' is ambiguous." }
        if ($matches.Count) {
            if ($matches[0].TypeAsString -ne $definition.Type) {
                throw "Existing catalog field '$name' has type '$($matches[0].TypeAsString)', expected '$($definition.Type)'; no type conversion is performed."
            }
        } else {
            $extra = ""
            if ($definition.Type -eq "Note") { $extra = ' RichText="FALSE" NumLines="6"' }
            if ($definition.Type -eq "DateTime") { $extra = ' Format="DateOnly"' }
            $body = ""
            if ($definition.Type -eq "Choice") {
                $body = "<CHOICES>" + (($definition.Choices | ForEach-Object {
                    "<CHOICE>$([Security.SecurityElement]::Escape($_))</CHOICE>"
                }) -join "") + "</CHOICES>"
            }
            if ($definition.Type -eq "Calculated") {
                $extra = ' ResultType="Text" ReadOnly="TRUE"'
                $body = "<Formula>$([Security.SecurityElement]::Escape($definition.Formula))</Formula><FieldRefs>" +
                    (($definition.FieldRefs | ForEach-Object { '<FieldRef Name="' + $_ + '"/>' }) -join "") + "</FieldRefs>"
            }
            if ($definition.Type -eq "Boolean") { $body = "<Default>0</Default>" }
            $displayName = if ($definition.ContainsKey("Title")) { $definition.Title } else { $name }
            if ($definition.ContainsKey("Default")) { $body += "<Default>$($definition.Default)</Default>" }
            $xml = '<Field Type="' + $definition.Type + '" Name="' + $name + '" StaticName="' + $name +
                '" DisplayName="' + [Security.SecurityElement]::Escape($displayName) + '"' + $extra + '>' + $body + '</Field>'
            Add-PnPFieldFromXml -List $List.Id -FieldXml $xml -Connection $Connection -ErrorAction Stop | Out-Null
            $name
        }
        if ($definition.ContainsKey("Presentation")) {
            Set-CoECatalogFieldPresentation $List $name $definition.Presentation $Connection
        }
    }
}

function Set-CoECatalogFieldPresentation($List, [string]$Name, [hashtable]$Presentation, $Connection) {
    $field = Get-PnPField -List $List.Id -Identity $Name -Connection $Connection -ErrorAction Stop
    if (-not $field) { throw "Catalog field '$Name' could not be read for presentation update." }
    $changed = $false
    foreach ($property in @($Presentation.Keys)) {
        switch ($property) {
            "Title" {
                $value = [string]$Presentation[$property]
                if ($field.Title -cne $value) { $field.Title = $value; $changed = $true }
            }
            "CustomFormatter" {
                $value = [string]$Presentation[$property]
                $null = $value | ConvertFrom-Json -ErrorAction Stop
                if ([string](Get-CoECatalogValue $field "CustomFormatter") -cne $value) {
                    $field.CustomFormatter = $value
                    $changed = $true
                }
            }
            "DefaultValue" {
                $value = [string]$Presentation[$property]
                if ([string](Get-CoECatalogValue $field "DefaultValue") -cne $value) {
                    $field.DefaultValue = $value
                    $changed = $true
                }
            }
            default { throw "Unsupported catalog field presentation property '$property' for '$Name'." }
        }
    }
    if ($changed) {
        $field.Update()
        Invoke-PnPQuery -Connection $Connection -ErrorAction Stop | Out-Null
    }
    $confirmed = Get-PnPField -List $List.Id -Identity $Name -Connection $Connection -ErrorAction Stop
    if (-not $confirmed) { throw "Catalog field '$Name' presentation update could not be read back." }
    foreach ($property in @($Presentation.Keys)) {
        $expected = [string]$Presentation[$property]
        $actual = [string](Get-CoECatalogValue $confirmed $property)
        if ($actual -cne $expected) {
            throw "Catalog field '$Name' presentation property '$property' was not applied."
        }
    }
}

function Sync-CoECatalogView($List, [string]$Title, [string[]]$Fields, [string]$Query,
    $Connection, [switch]$SetAsDefault, [hashtable]$Presentation = @{}) {
    $matches = @(Get-PnPView -List $List.Id -Connection $Connection -ErrorAction Stop | Where-Object Title -eq $Title)
    if ($matches.Count -gt 1) { throw "Catalog view '$Title' is ambiguous." }
    if ($matches.Count) {
        $view = $matches[0]
    } else {
        $view = Add-PnPView -List $List.Id -Title $Title -Fields $Fields -Query $Query -RowLimit 100 -Paged `
            -SetAsDefault:$SetAsDefault -Connection $Connection -ErrorAction Stop
        if (-not $view -or -not $view.Id) { throw "Catalog view '$Title' creation did not return a view ID." }
    }
    $values = @{ ViewQuery = $Query; RowLimit = [uint32]100; Paged = $true }
    if ($SetAsDefault) { $values.DefaultView = $true }
    $view = Set-PnPView -List $List.Id -Identity $view.Id -Fields $Fields -Values $values `
        -Connection $Connection -ErrorAction Stop -WarningAction SilentlyContinue
    if (-not $view -or -not $view.Id) { throw "Catalog view '$Title' update did not return a view ID." }
    if ($Presentation.Count) { Set-CoECatalogViewPresentation $List $view.Id $Title $Presentation $Connection }
    $confirmed = @(Get-PnPView -List $List.Id -Identity $view.Id -Includes ViewQuery,DefaultView,ServerRelativeUrl,CustomFormatter,ViewFields `
        -Connection $Connection -ErrorAction Stop)
    if ($confirmed.Count -ne 1 -or $confirmed[0].Id -ne $view.Id) { throw "Catalog view '$Title' could not be read back by its original ID." }
    $view = $confirmed[0]
    if (-not (Test-CoECatalogViewQueryEqual $view.ViewQuery $Query) -or ($SetAsDefault -and -not $view.DefaultView)) {
        throw "Catalog view '$Title' query/default setting was not applied."
    }
    if ($Presentation.ContainsKey("CustomFormatter") -and $view.CustomFormatter -ne $Presentation.CustomFormatter) {
        throw "Catalog view '$Title' formatting was not applied."
    }
    return $view
}

function Set-CoECatalogViewPresentation($List, $ViewId, [string]$Title, [hashtable]$Presentation, $Connection) {
    $view = Get-PnPView -List $List.Id -Identity $ViewId -Includes CustomFormatter -Connection $Connection -ErrorAction Stop
    if (-not $view -or $view.Id -ne $ViewId) { throw "Catalog view '$Title' presentation update could not be read by ID." }
    $changed = $false
    foreach ($property in @($Presentation.Keys)) {
        switch ($property) {
            "CustomFormatter" {
                $value = [string]$Presentation[$property]
                $null = $value | ConvertFrom-Json -ErrorAction Stop
                if ([string](Get-CoECatalogValue $view "CustomFormatter") -cne $value) {
                    $view.CustomFormatter = $value
                    $changed = $true
                }
            }
            default { throw "Unsupported catalog view presentation property '$property' for '$Title'." }
        }
    }
    if ($changed) {
        $view.Update()
        Invoke-PnPQuery -Connection $Connection -ErrorAction Stop | Out-Null
    }
}

function Get-CoECatalogLinkFormatter([string]$Label) {
    return (@{
        '$schema' = "https://developer.microsoft.com/json-schemas/sp/v2/column-formatting.schema.json"
        elmType = "a"; txtContent = $Label
        attributes = @{ href = "@currentField"; title = "@currentField.desc"; target = "_blank"; rel = "noopener noreferrer" }
        style = @{ display = "=if(@currentField == '', 'none', 'inline-block')"; "white-space" = "nowrap"; "padding" = "6px 4px" }
    } | ConvertTo-Json -Depth 8 -Compress)
}

function Get-CoELearningViewFormatter([switch]$Compact) {
    $format = @{
        '$schema' = "https://developer.microsoft.com/json-schemas/sp/v2/row-formatting.schema.json"
        groupProps = @{ headerFormatter = @{
            elmType = "div"; style = @{ "font-weight" = "600"; "padding" = "8px 4px"; "white-space" = "normal" }
            txtContent = "=if(@group.columnDisplayName == 'Audience order', substring(@group.fieldData, 3, 258), @group.fieldData)"
        } }
    }
    if ($Compact) {
        $children = @(
            @{ elmType = "span"; txtContent = "='Step ' + toString([`$LearningStep])"
                style = @{ "min-width" = "60px"; "padding" = "6px 4px" } },
            @{ elmType = "button"; txtContent = '[$Title]'; customRowAction = @{ action = "defaultClick" }
                attributes = @{ class = "ms-fontColor-themePrimary"; title = '[$Title]' }
                style = @{ flex = "1"; "min-width" = "160px"; "white-space" = "normal"; "text-align" = "left"
                    border = "none"; background = "transparent"; cursor = "pointer"; padding = "6px 4px" } }
        )
        foreach ($entry in @(@{ Name = "LearningResource"; Label = "Learn" }, @{ Name = "LearningPractice"; Label = "Practice" })) {
            $reference = '[$' + $entry.Name + ']'
            $children += @{
                elmType = "a"; txtContent = $entry.Label
                attributes = @{ href = $reference; target = "_blank"; rel = "noopener noreferrer"; "aria-label" = $entry.Label }
                style = @{ display = "=if($reference == '', 'none', 'inline-block')"; "min-width" = "64px"
                    "white-space" = "nowrap"; padding = "6px 4px" }
            }
        }
        $format.hideColumnHeader = $true
        $format.rowFormatter = @{ elmType = "div"; style = @{ display = "flex"; "flex-wrap" = "wrap"
            width = "100%"; "align-items" = "center"; padding = "4px 0" }; children = $children }
    }
    return ($format | ConvertTo-Json -Depth 12 -Compress)
}

function Test-CoECatalogViewQueryEqual([string]$Actual, [string]$Expected) {
    if ($Actual -eq $Expected) { return $true }
    try {
        $actualXml = [xml]("<Query>$Actual</Query>")
        $expectedXml = [xml]("<Query>$Expected</Query>")
        return $actualXml.OuterXml -eq $expectedXml.OuterXml
    } catch {
        return $false
    }
}

function Set-CoELearningCatalogForm($List, [string[]]$FieldOrder, $Connection) {
    foreach ($name in @("LearningId", "LearningAudienceOrder")) {
        $field = Get-PnPField -List $List.Id -Identity $name -Connection $Connection -ErrorAction Stop
        if (-not $field) { throw "Learning form field '$name' was not found." }
        $field.SetShowInDisplayForm($false)
        $field.SetShowInEditForm($false)
        $field.SetShowInNewForm($false)
        $field.Update()
    }
    $types = @(Get-PnPContentType -List $List.Id -Includes FieldLinks -Connection $Connection -ErrorAction Stop |
        Where-Object { @($_.FieldLinks | ForEach-Object Name) -contains "LearningId" })
    if (-not $types.Count) { throw "Learning catalog has no list content type containing LearningId; form order was not applied." }
    foreach ($type in $types) {
        $names = @($type.FieldLinks | ForEach-Object Name)
        foreach ($name in $FieldOrder) {
            if ($name -notin $names) { throw "Learning content type '$($type.Name)' is missing form field '$name'." }
        }
        # Keep customer/system fields after the learning fields instead of removing their links.
        $type.FieldLinks.Reorder([string[]](@($FieldOrder) + @($names | Where-Object { $_ -notin $FieldOrder })))
        $type.Update($false)
    }
    Invoke-PnPQuery -Connection $Connection -ErrorAction Stop | Out-Null
}

function Get-CoECatalogMetadataDiagnostics($List, [string]$OwnerField, [string]$ReviewField, $Connection) {
    $items = @(Get-PnPListItem -List $List.Id -Fields $OwnerField,$ReviewField -PageSize 500 -Connection $Connection -ErrorAction Stop)
    $unassigned = @($items | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.FieldValues[$OwnerField]) })
    $unreviewed = @($items | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.FieldValues[$ReviewField]) })
    $messages = @()
    if ($unassigned.Count) { $messages += "$($unassigned.Count) catalog item(s) have no assigned content owner; ask the customer to assign actual owners." }
    if ($unreviewed.Count) { $messages += "$($unreviewed.Count) catalog item(s) have no recorded review date; record dates only after an actual review." }
    [pscustomobject]@{ UnassignedOwnerCount = $unassigned.Count; MissingReviewCount = $unreviewed.Count; Messages = $messages }
}

function Set-CoEAgentAllItemsFilter($List, [string]$NotRetired, $Connection) {
    # The native list view is identified by its page file, AllItems.aspx: SharePoint names it that way in every
    # display language, while the title ("All Items") is localized. Neither BaseViewId nor ModerationType can be
    # used: every standard view reports BaseViewId 1, including the ones this kit creates and the two
    # "My submissions" / "Approve/reject Items" views SharePoint adds when content approval is enabled.
    $views = @(Get-PnPView -List $List.Id -Includes ServerRelativeUrl,ViewQuery -Connection $Connection -ErrorAction Stop |
        Where-Object { ([string](Get-CoECatalogValue $_ "ServerRelativeUrl") -split "/")[-1] -ieq "AllItems.aspx" })
    if ($views.Count -gt 1) { throw "Catalog '$($List.Title)' has ambiguous native All Items views." }
    foreach ($view in $views) {
        $query = [xml]("<Query>" + $view.ViewQuery + "</Query>")
        $where = $query.DocumentElement.SelectSingleNode("Where")
        $predicate = ([xml]("<Where>" + $NotRetired + "</Where>")).DocumentElement.FirstChild.OuterXml
        if (-not $where) {
            $where = $query.CreateElement("Where")
            $null = $query.DocumentElement.PrependChild($where)
            $where.InnerXml = $predicate
        } elseif ($where.InnerXml -ne $predicate -and
            -not ($where.FirstChild.Name -eq "And" -and $where.FirstChild.LastChild.OuterXml -eq $predicate)) {
            $where.InnerXml = "<And>" + $where.InnerXml + $predicate + "</And>"
        }
        $updated = Set-PnPView -List $List.Id -Identity $view.Id -Values @{ ViewQuery = $query.DocumentElement.InnerXml } `
            -Connection $Connection -ErrorAction Stop -WarningAction SilentlyContinue
        if (-not $updated -or -not $updated.Id) { throw "Catalog All Items filter update did not return a view ID." }
        $confirmed = @(Get-PnPView -List $List.Id -Identity $updated.Id -Includes ViewQuery,ViewFields -Connection $Connection -ErrorAction Stop)
        if ($confirmed.Count -ne 1 -or $confirmed[0].Id -ne $view.Id -or
            -not (Test-CoECatalogViewQueryEqual $confirmed[0].ViewQuery $query.DocumentElement.InnerXml)) {
            throw "Catalog All Items retirement filter was not applied."
        }
        $confirmed[0]
    }
}

function New-CoECatalogUrlValue([string]$Url, [string]$Description) {
    $value = [Microsoft.SharePoint.Client.FieldUrlValue]::new()
    $value.Url = $Url
    $value.Description = $Description
    return $value
}

function Get-CoECatalogLaunchUrl($Value) {
    if ($null -eq $Value) { return "" }
    if ($Value -is [string]) { return (($Value -split ',\s+', 2)[0]).Trim() }
    return [string](Get-CoECatalogValue $Value "Url")
}

function Get-CoECatalogNormalizedLaunchUrl($Value) {
    $url = Get-CoECatalogLaunchUrl $Value
    $uri = $null
    if ($url -and [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) { return $uri.AbsoluteUri }
    # Legacy customer links are comparison data, not new seeds; never repair or launch them.
    return $url.Trim()
}

# Audience groups appear in the order the learning seeds first use them (higher-ed default:
# Faculty, Staff, Students, Champions, IT, Agent makers). SharePoint allows at most 19 nested IFs. The formula is set when
# the list is created; an existing list keeps its formula (new audiences then sort last).
function Get-CoELearningAudienceFormula([string[]]$Audiences) {
    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($audience in @($Audiences)) {
        $name = ([string]$audience).Trim()
        if ($name -and -not $ordered.Contains($name)) { $ordered.Add($name) }
    }
    if ($ordered.Count -eq 0) {
        foreach ($name in @("Faculty", "Staff", "Students", "Champions", "IT", "Agent makers")) { $ordered.Add($name) }
    }
    if ($ordered.Count -gt 18) { throw "Learning paths support at most 18 audiences; found $($ordered.Count)." }
    # Unknown audiences sort after the listed ones (higher-ed default yields the original "07|" formula).
    $formula = '"' + ('{0:D2}' -f ($ordered.Count + 1)) + '|"'
    for ($i = $ordered.Count - 1; $i -ge 0; $i--) {
        $label = $ordered[$i].Replace('"', '""')
        $formula = 'IF([Audience]="' + $label + '","' + ('{0:D2}' -f ($i + 1)) + '|",' + $formula + ')'
    }
    return '=' + $formula + '&[Audience]'
}

function Sync-CoELearningCatalog {
    <#
    .SYNOPSIS
    Inserts reviewable starter learning metadata; requirement is not approval or completion tracking.
    .NOTES
    Preserved counts seed IDs already present. Existing rows, including rows without LearningId, are never edited.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][string]$SiteUrl,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Seeds, [string[]]$ReviewerUPNs = @(),
        [AllowEmptyCollection()][object[]]$ResolvedReviewers)
    $site = Assert-CoECatalogSiteUrl $SiteUrl
    $validated = @(ConvertTo-CoELearningSeeds -Items $Seeds -SiteUrl $site)
    if (-not $PSBoundParameters.ContainsKey("ResolvedReviewers")) { Assert-CoECatalogPreflight $site $Connection }
    $reviewers = @(if ($PSBoundParameters.ContainsKey("ResolvedReviewers")) { $ResolvedReviewers } else {
        Resolve-CoECatalogReviewers $ReviewerUPNs $Connection
    })
    $catalog = Get-CoECatalogList "Copilot Learning Paths" "Lists/CopilotLearningPaths" $site $Connection
    $list = $catalog.List
    $wasModerated = -not $catalog.Created -and $list.EnableModeration
    Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection $Connection
    $definitions = @{}
    foreach ($name in @("LearningId", "LearningPath", "LearningAudience", "LearningProduct",
        "LearningPracticeTitle", "LearningOwner")) { $definitions[$name] = @{ Type = "Text" } }
    foreach ($name in @("LearningStep", "LearningMinutes")) { $definitions[$name] = @{ Type = "Number" } }
    foreach ($name in @("LearningResource", "LearningPractice", "LearningLms")) { $definitions[$name] = @{ Type = "URL" } }
    $definitions.LearningRequirement = @{ Type = "Choice"; Choices = @("Recommended", "Required", "Optional"); Default = "Recommended" }
    $definitions.LearningExpectedResult = @{ Type = "Note" }
    $definitions.LearningReviewedOn = @{ Type = "DateTime" }
    # A calculated grouping value orders existing rows and future edits without changing audience labels or item versions.
    $definitions.LearningAudienceOrder = @{ Type = "Calculated"; Title = "Audience order"; FieldRefs = @("LearningAudience")
        Formula = Get-CoELearningAudienceFormula @($validated | ForEach-Object { $_.audience })
        Presentation = @{ Title = "Audience order" } }
    $definitions.LearningResource.Presentation = @{ CustomFormatter = Get-CoECatalogLinkFormatter "Learn" }
    $definitions.LearningPractice.Presentation = @{ CustomFormatter = Get-CoECatalogLinkFormatter "Practice" }
    $titles = @{
        LearningId = "Learning ID"; LearningPath = "Path"; LearningAudience = "Audience"
        LearningStep = "Step"; LearningMinutes = "Practice time (minutes)"; LearningRequirement = "Requirement"
        LearningProduct = "Product and access needed"; LearningResource = "Learn"; LearningPracticeTitle = "Practice task or prompt"
        LearningPractice = "Practice"; LearningExpectedResult = "What good looks like"; LearningOwner = "Content owner"
        LearningReviewedOn = "Last reviewed"; LearningLms = "Learning system"
    }
    foreach ($name in $titles.Keys) {
        $definitions[$name].Title = $titles[$name]
        if (-not $definitions[$name].ContainsKey("Presentation")) { $definitions[$name].Presentation = @{} }
        $definitions[$name].Presentation.Title = $titles[$name]
    }
    Sync-CoECatalogFields $list $definitions $Connection | Out-Null
    $formFields = @("Title", "LearningAudience", "LearningPath", "LearningStep", "LearningResource", "LearningPractice",
        "LearningExpectedResult", "LearningMinutes", "LearningProduct", "LearningRequirement", "LearningOwner",
        "LearningReviewedOn", "LearningLms", "LearningPracticeTitle")
    Set-CoELearningCatalogForm $list $formFields $Connection
    $existing = @(Get-PnPListItem -List $list.Id -Fields LearningId -PageSize 500 -Connection $Connection -ErrorAction Stop)
    $ids = @{}
    foreach ($item in $existing) {
        $id = [string]$item.FieldValues["LearningId"]
        if (-not $id.Trim()) { continue }
        $id = $id.Trim()
        if ($ids.ContainsKey($id)) { throw "Catalog '$($list.Title)' has duplicate LearningId '$id'; no seeds were inserted." }
        $ids[$id] = $true
    }
    if (-not $wasModerated) {
        foreach ($item in $existing) {
            Set-PnPListItem -List $list.Id -Identity $item.Id -Values @{ "_ModerationStatus" = 0 } `
                -UpdateType SystemUpdate -Connection $Connection -ErrorAction Stop | Out-Null
        }
    }
    $added = 0
    $preserved = 0
    foreach ($seed in $validated) {
        if ($ids.ContainsKey($seed.id)) { $preserved++; continue }
        $values = @{
            Title = $seed.title; LearningId = $seed.id; LearningPath = $seed.path
            LearningAudience = $seed.audience; LearningStep = $seed.step; LearningMinutes = $seed.minutes
            LearningRequirement = $seed.requirement; LearningProduct = $seed.product
            LearningResource = New-CoECatalogUrlValue $seed.resourceUrl "Learn"
            LearningPracticeTitle = $seed.practicePromptTitle; LearningExpectedResult = $seed.expectedResult
            LearningOwner = $seed.owner; "_ModerationStatus" = 0
        }
        if ($seed.practiceUrl) { $values.LearningPractice = New-CoECatalogUrlValue $seed.practiceUrl "Practice" }
        if ($seed.lmsUrl) { $values.LearningLms = New-CoECatalogUrlValue $seed.lmsUrl "LMS" }
        if (-not [string]::IsNullOrWhiteSpace($seed.reviewedOn)) {
            $values.LearningReviewedOn = ConvertTo-CoECatalogDate $seed.reviewedOn $seed.id
        }
        Add-PnPListItem -List $list.Id -Values $values -Connection $Connection -ErrorAction Stop | Out-Null
        $ids[$seed.id] = $true
        $added++
    }
    $viewFields = @("Title", "LearningPath", "LearningAudience", "LearningStep", "LearningMinutes", "LearningRequirement",
        "LearningProduct", "LearningResource", "LearningPracticeTitle", "LearningPractice", "LearningExpectedResult",
        "LearningOwner", "LearningReviewedOn", "LearningLms")
    $order = '<OrderBy><FieldRef Name="LearningStep" Ascending="TRUE"/><FieldRef Name="Title" Ascending="TRUE"/></OrderBy>'
    $pageFields = @("Title", "LearningStep", "LearningResource", "LearningPractice")
    $groupFormatting = @{ CustomFormatter = Get-CoELearningViewFormatter }
    $pageView = Sync-CoECatalogView $list "Learning steps" $pageFields `
        ('<Where><Eq><FieldRef Name="_ModerationStatus"/><Value Type="ModStat">0</Value></Eq></Where>' +
        '<GroupBy Collapse="FALSE"><FieldRef Name="LearningAudienceOrder" Ascending="TRUE"/><FieldRef Name="LearningPath" Ascending="TRUE"/></GroupBy>' + $order) `
        $Connection -SetAsDefault -Presentation @{ CustomFormatter = Get-CoELearningViewFormatter -Compact }
    $audience = Sync-CoECatalogView $list "By audience" $viewFields `
        ('<GroupBy Collapse="TRUE"><FieldRef Name="LearningAudienceOrder" Ascending="TRUE"/><FieldRef Name="LearningPath" Ascending="TRUE"/></GroupBy>' + $order) `
        $Connection -Presentation $groupFormatting
    $path = Sync-CoECatalogView $list "By path" $viewFields `
        ('<GroupBy Collapse="TRUE"><FieldRef Name="LearningPath" Ascending="TRUE"/><FieldRef Name="LearningAudienceOrder" Ascending="TRUE"/></GroupBy>' + $order) `
        $Connection -Presentation $groupFormatting
    $required = Sync-CoECatalogView $list "Required" $viewFields `
        ('<Where><Eq><FieldRef Name="LearningRequirement"/><Value Type="Choice">Required</Value></Eq></Where>' + $order) $Connection
    [pscustomobject]@{ List = $list; Views = [pscustomobject]@{ Page = $pageView; ByAudience = $audience; ByPath = $path; Required = $required }
        Added = $added; Preserved = $preserved; ListUrl = $catalog.ListUrl; FormFields = $formFields
        ReaderViewUrl = Resolve-CoESharePointReturnedUrl $pageView.ServerRelativeUrl "Learning reader view" $site
        Diagnostics = Get-CoECatalogMetadataDiagnostics $list "LearningOwner" "LearningReviewedOn" $Connection }
}

function Sync-CoEAgentCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][string]$SiteUrl,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AgentSeeds, [string[]]$ReviewerUPNs = @(),
        [AllowEmptyCollection()][object[]]$ResolvedReviewers)
    $site = Assert-CoECatalogSiteUrl $SiteUrl
    $validated = @(ConvertTo-CoEAgentSeeds $AgentSeeds)
    if (-not $PSBoundParameters.ContainsKey("ResolvedReviewers")) { Assert-CoECatalogPreflight $site $Connection }
    $reviewers = @(if ($PSBoundParameters.ContainsKey("ResolvedReviewers")) { $ResolvedReviewers } else {
        Resolve-CoECatalogReviewers $ReviewerUPNs $Connection
    })
    $catalog = Get-CoECatalogList "Copilot Agent Showcase" "Lists/CopilotAgentShowcase" $site $Connection
    $list = $catalog.List
    $wasModerated = -not $catalog.Created -and $list.EnableModeration
    Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection $Connection
    $definitions = @{}
    foreach ($name in @("AgentAudience", "AgentOwner", "AgentProduct", "AgentBackupOwner", "AgentSupport")) {
        $definitions[$name] = @{ Type = "Text" }
    }
    foreach ($name in @("AgentDescription", "AgentPrompt", "AgentSources", "AgentConnections", "AgentAccess", "AgentAllowedData")) {
        $definitions[$name] = @{ Type = "Note" }
    }
    foreach ($name in @("AgentReviewedOn", "AgentNextReview")) { $definitions[$name] = @{ Type = "DateTime" } }
    $definitions.AgentLink = @{ Type = "URL" }
    $definitions.AgentFeatured = @{ Type = "Boolean" }
    $definitions.AgentStatus = @{ Type = "Choice"; Choices = @("Submitted", "Published", "Retired", "In review", "Rejected"); Default = "Submitted" }
    $titles = @{
        AgentStatus = "Status"; AgentDescription = "What it does"; AgentAudience = "Who it is for"
        AgentLink = "Open agent"; AgentOwner = "Owner"; AgentPrompt = "Example prompt"; AgentProduct = "Agent type or product"
        AgentSources = "Knowledge sources"; AgentConnections = "Connectors and actions"; AgentAccess = "Access and billing requirements"
        AgentAllowedData = "Allowed data guidance"; AgentBackupOwner = "Backup owner"; AgentSupport = "Support contact"
        AgentReviewedOn = "Last reviewed"; AgentNextReview = "Next review"; AgentFeatured = "Featured"
    }
    foreach ($name in $titles.Keys) { $definitions[$name].Title = $titles[$name] }
    $addedFields = @(Sync-CoECatalogFields $list $definitions $Connection)
    $statusField = Get-PnPField -List $list.Id -Identity AgentStatus -Connection $Connection -ErrorAction Stop
    $null = Get-PnPProperty -ClientObject $statusField -Property Choices -Connection $Connection -ErrorAction Stop
    $choices = @($statusField.Choices)
    $merged = @($choices)
    foreach ($choice in $definitions.AgentStatus.Choices) {
        if ($choice -notin $merged) { $merged += $choice }
    }
    if ($merged.Count -ne $choices.Count) {
        Set-PnPField -List $list.Id -Identity AgentStatus -Values @{ Choices = [string[]]$merged } `
            -Connection $Connection -ErrorAction Stop | Out-Null
    }
    $existing = @(Get-PnPListItem -List $list.Id -Fields Title,AgentLink,AgentStatus,AgentFeatured,_ModerationStatus `
        -PageSize 500 -Connection $Connection -ErrorAction Stop)
    $plan = @()
    $matchedItemIds = @{}
    foreach ($seed in $validated) {
        $matches = @($existing | Where-Object {
            $normalized = Get-CoECatalogNormalizedLaunchUrl $_.FieldValues["AgentLink"]
            ([string]$_.FieldValues["Title"]).Trim() -ieq $seed.name -or
                [string]::Equals($normalized, $seed.url, [StringComparison]::Ordinal)
        })
        if ($matches.Count -gt 1) {
            throw "Agent seed '$($seed.name)' has ambiguous existing title/launch URL matches; existing agents were not overwritten."
        }
        if ($matches.Count -eq 1) {
            $itemId = [string]$matches[0].Id
            if ($matchedItemIds.ContainsKey($itemId)) {
                throw "Agent seed '$($seed.name)' ambiguously matches item '$itemId' already matched by '$($matchedItemIds[$itemId])'; resolve the configured titles and launch URLs."
            }
            $matchedItemIds[$itemId] = $seed.name
        }
        $plan += [pscustomobject]@{ Seed = $seed; Preserve = ($matches.Count -eq 1) }
    }
    $migrated = 0
    foreach ($item in $existing) {
        $status = [string]$item.FieldValues["AgentStatus"]
        $changes = @{}
        if ($status -eq "Featured") {
            $changes.AgentStatus = "Published"
            $changes.AgentFeatured = $true
        } elseif ("AgentFeatured" -in $addedFields -and $status -eq "Published" -and
            $matchedItemIds.ContainsKey([string]$item.Id)) {
            # Older kits featured configured agents separately from their published list rows.
            $changes.AgentFeatured = $true
        }
        if (-not $wasModerated) {
            $changes["_ModerationStatus"] = if ($status -in @("Published", "Featured")) { 0 }
                elseif ($status -in @("Retired", "Rejected")) { 1 } else { 2 }
        }
        if ($changes.Count) {
            Set-PnPListItem -List $list.Id -Identity $item.Id -Values $changes -UpdateType SystemUpdate `
                -Connection $Connection -ErrorAction Stop | Out-Null
            $migrated++
        }
    }
    $added = 0
    $preserved = 0
    $metadata = @{
        product = "AgentProduct"; sources = "AgentSources"; connections = "AgentConnections"
        access = "AgentAccess"; allowedData = "AgentAllowedData"; backupOwner = "AgentBackupOwner"; support = "AgentSupport"
    }
    foreach ($entry in $plan) {
        if ($entry.Preserve) { $preserved++; continue }
        $seed = $entry.Seed
        $values = @{ Title = $seed.name; AgentDescription = $seed.description; AgentAudience = $seed.audience
            AgentPrompt = $seed.examplePrompt; AgentOwner = $seed.owner
            AgentLink = New-CoECatalogUrlValue $seed.url $seed.name; AgentStatus = $seed.status; AgentFeatured = $seed.featured
            "_ModerationStatus" = $(if ($seed.status -eq "Published") { 0 }
                elseif ($seed.status -in @("Retired", "Rejected")) { 1 } else { 2 }) }
        foreach ($name in $metadata.Keys) {
            $value = Get-CoECatalogValue $seed $name
            if ($null -ne $value) { $values[$metadata[$name]] = $value }
        }
        foreach ($name in @("reviewedOn", "nextReview")) {
            $value = [string](Get-CoECatalogValue $seed $name)
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $field = if ($name -eq "reviewedOn") { "AgentReviewedOn" } else { "AgentNextReview" }
                $values[$field] = ConvertTo-CoECatalogDate $value "Agent '$($seed.name)' $name"
            }
        }
        Add-PnPListItem -List $list.Id -Values $values -Connection $Connection -ErrorAction Stop | Out-Null
        $added++
    }
    $fields = @("Title", "AgentDescription", "AgentAudience", "AgentProduct", "AgentLink", "AgentOwner",
        "AgentSources", "AgentConnections", "AgentAccess", "AgentAllowedData", "AgentBackupOwner", "AgentSupport",
        "AgentReviewedOn", "AgentNextReview", "AgentStatus", "AgentFeatured", "AgentPrompt")
    $notRetired = '<Or><IsNull><FieldRef Name="AgentStatus"/></IsNull>' +
        '<Neq><FieldRef Name="AgentStatus"/><Value Type="Choice">Retired</Value></Neq></Or>'
    $allItems = Set-CoEAgentAllItemsFilter $list $notRetired $Connection
    $publishedFilter = '<And><Eq><FieldRef Name="_ModerationStatus"/><Value Type="ModStat">0</Value></Eq>' +
        $notRetired + '</And>'
    $pageFields = @("Title", "AgentDescription", "AgentAudience", "AgentLink", "AgentOwner")
    $order = '<OrderBy><FieldRef Name="Title" Ascending="TRUE"/></OrderBy>'
    $published = Sync-CoECatalogView $list "Published" $pageFields `
        ('<Where>' + $publishedFilter + '</Where><GroupBy Collapse="FALSE"><FieldRef Name="AgentAudience"/></GroupBy>' + $order) `
        $Connection -SetAsDefault
    $featured = Sync-CoECatalogView $list "Featured" $pageFields `
        ('<Where><And>' + $publishedFilter + '<Eq><FieldRef Name="AgentFeatured"/><Value Type="Boolean">1</Value></Eq></And></Where>' + $order) $Connection
    $review = Sync-CoECatalogView $list "Review" $fields `
        ('<Where><And><Eq><FieldRef Name="_ModerationStatus"/><Value Type="ModStat">2</Value></Eq>' +
        $notRetired + '</And></Where>' + $order) $Connection
    $details = Sync-CoECatalogView $list "Agent details" $fields ('<Where>' + $notRetired + '</Where>' + $order) $Connection
    $management = Sync-CoECatalogView $list "Manage all entries" @($fields + @("_ModerationStatus")) $order $Connection
    [pscustomobject]@{ List = $list; Views = [pscustomobject]@{ Published = $published; Featured = $featured; Review = $review
        AllItems = $allItems; Management = $management }
        Added = $added; Preserved = $preserved; Migrated = $migrated; ListUrl = $catalog.ListUrl; DetailsView = $details
        ReaderViewUrl = Resolve-CoESharePointReturnedUrl $published.ServerRelativeUrl "Agent reader view" $site
        Diagnostics = Get-CoECatalogMetadataDiagnostics $list "AgentOwner" "AgentReviewedOn" $Connection }
}

function Assert-CoECatalogReviewerUPNs([string[]]$ReviewerUPNs) {
    $ReviewerUPNs | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_) -or $_.Trim() -notmatch '^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$') {
            throw "Catalog reviewer UPN '$_' is invalid."
        }
        $_.Trim().ToLowerInvariant()
    } | Select-Object -Unique
}

function Resolve-CoECatalogReviewers([string[]]$ReviewerUPNs, $Connection) {
    $addresses = @(Assert-CoECatalogReviewerUPNs $ReviewerUPNs)
    if (-not $addresses.Count) { return }
    $tenantId = [string](Get-PnPTenantId -Connection $Connection -ErrorAction Stop)
    $token = Get-PnPAccessToken -ResourceTypeName Graph -Decoded -Connection $Connection -ErrorAction Stop
    $claims = @($token.Claims | Where-Object Type -eq "tid")
    if ($tenantId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or
        $claims.Count -ne 1 -or $claims[0].Value -ne $tenantId) {
        throw "Catalog reviewer Graph token does not match the SharePoint tenant."
    }
    $identities = @()
    $identityIds = @{}
    foreach ($address in $addresses) {
        $identity = Invoke-PnPGraphMethod -Url "v1.0/users/$([uri]::EscapeDataString($address))?`$select=id,userPrincipalName,userType" `
            -Method Get -Connection $Connection -ErrorAction Stop
        Assert-CoEMemberIdentity -Identity $identity -Address $address
        $identityId = [string](Get-CoECatalogValue $identity "id")
        if ($identityIds.ContainsKey($identityId)) { throw "Catalog reviewers resolved to a duplicate immutable Member identity." }
        $identityIds[$identityId] = $true
        $upn = [string](Get-CoECatalogValue $identity "userPrincipalName")
        if ($upn -ine $address) { throw "Catalog reviewer '$address' did not resolve to the exact in-tenant Member UPN." }
        $identities += $upn
    }
    # EnsureUser registers verified existing Members in the site; it does not invite or grant access.
    foreach ($upn in $identities) {
        $user = New-PnPUser -LoginName $upn -Connection $Connection -ErrorAction Stop
        if (-not $user -or $user.Id -le 0 -or $user.LoginName -notmatch ('(^|\|)' + [regex]::Escape($upn) + '$')) {
            throw "Catalog reviewer '$upn' could not be verified as a SharePoint principal."
        }
        [pscustomobject]@{ Id = [int]$user.Id; LoginName = $user.LoginName }
    }
}

$script:CoEReviewerGroupName = "CoE Catalog Reviewers"
$script:CoEReviewerRoleName = "CoE Catalog Reviewer"

function Write-CoEStep([string]$Step, [string]$Detail = "") {
    $stamp = (Get-Date).ToString("HH:mm:ss")
    Write-Host ("[{0}] {1}{2}" -f $stamp, $Step, $(if ($Detail) { " - $Detail" } else { "" }))
}

function Test-CoECatalogReviewRole($Role, $Contributor) {
    foreach ($name in [enum]::GetNames([Microsoft.SharePoint.Client.PermissionKind])) {
        if ($name -in @("EmptyMask", "FullMask")) { continue }
        $kind = [enum]::Parse([Microsoft.SharePoint.Client.PermissionKind], $name)
        $expected = $name -eq "ApproveItems" -or $Contributor.BasePermissions.Has($kind)
        if ($Role.BasePermissions.Has($kind) -ne $expected) { return $false }
    }
    return $true
}

# Creates the "CoE Catalog Reviewer" permission level (Contribute + ApproveItems) only when it is missing,
# and refuses to continue if an existing level with that name has any other permission set.
function Initialize-CoECatalogReviewerRole($Connection) {
    $contributor = Get-PnPRoleDefinition -Identity "Contribute" -Connection $Connection -ErrorAction Stop
    $null = Get-PnPProperty -ClientObject $contributor -Property BasePermissions -Connection $Connection -ErrorAction Stop
    $role = Get-PnPRoleDefinition -Identity $script:CoEReviewerRoleName -Connection $Connection -ErrorAction SilentlyContinue
    if (-not $role) {
        Write-CoEStep "Create permission level" $script:CoEReviewerRoleName
        Add-PnPRoleDefinition -RoleName $script:CoEReviewerRoleName -Clone $contributor -Include ApproveItems `
            -Description "Contribute plus content approval for CoE catalogs; no list or permission management." `
            -Connection $Connection -ErrorAction Stop | Out-Null
        $role = Get-PnPRoleDefinition -Identity $script:CoEReviewerRoleName -Connection $Connection -ErrorAction Stop
    }
    $null = Get-PnPProperty -ClientObject $role -Property BasePermissions -Connection $Connection -ErrorAction Stop
    if (-not (Test-CoECatalogReviewRole $role $contributor)) {
        throw "Permission level '$($script:CoEReviewerRoleName)' must be exactly Contribute plus ApproveItems; the existing level was not changed."
    }
}

# Creates the SharePoint group once and adds each verified reviewer. Adding an existing member is a no-op,
# so reruns never change anything. Owners can manage reviewers directly in SharePoint afterwards.
function Initialize-CoECatalogReviewerGroup([object[]]$Reviewers, $Connection) {
    $group = Get-PnPGroup -Identity $script:CoEReviewerGroupName -Connection $Connection -ErrorAction SilentlyContinue
    if (-not $group) {
        Write-CoEStep "Create SharePoint group" $script:CoEReviewerGroupName
        $group = New-PnPGroup -Title $script:CoEReviewerGroupName `
            -Description "Reviews and approves CoE catalog entries (Agent Showcase, Learning Paths, Success Stories)." `
            -Connection $Connection -ErrorAction Stop
    }
    if (-not $group -or $group.Id -le 0) { throw "The '$($script:CoEReviewerGroupName)' group could not be verified." }
    $members = @(Get-PnPGroupMember -Group $script:CoEReviewerGroupName -Connection $Connection -ErrorAction Stop |
        ForEach-Object { [string]$_.LoginName })
    foreach ($reviewer in $Reviewers) {
        $login = [string](Get-CoECatalogValue $reviewer "LoginName")
        if ([string]::IsNullOrWhiteSpace($login)) { throw "A catalog reviewer has no verified SharePoint login." }
        if ($login -in $members) { continue }
        Write-CoEStep "Add reviewer to group" $login
        Add-PnPGroupMember -LoginName $login -Group $script:CoEReviewerGroupName -Connection $Connection -ErrorAction Stop
    }
    return $group
}

function Assert-CoECatalogItemInheritance($List, $Connection) {
    foreach ($item in @(Get-PnPListItem -List $List.Id -Fields ID -Includes HasUniqueRoleAssignments `
        -PageSize 500 -Connection $Connection -ErrorAction Stop)) {
        if ($item.HasUniqueRoleAssignments) {
            throw "Catalog '$($List.Title)' item '$($item.Id)' has unique permissions. Administrator review is required before changing the catalog; item ACLs are not reset or widened."
        }
    }
}

# One read of the list's role assignments: the reviewer group must hold the reviewer role and the associated
# site Owners group must still hold Full Control. Retries cover SharePoint's propagation delay.
function Assert-CoECatalogReviewerAccess($List, [int]$GroupId, [int]$OwnersGroupId, $Connection) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $current = Get-PnPList -Identity $List.Id -Includes HasUniqueRoleAssignments,RoleAssignments `
            -Connection $Connection -ErrorAction Stop
        $context = Get-PnPContext -Connection $Connection -ErrorAction Stop
        $context.Load($current.RoleAssignments)
        Invoke-PnPQuery -Connection $Connection -ErrorAction Stop | Out-Null
        $reviewerOk = $false
        $ownersOk = $false
        foreach ($assignment in $current.RoleAssignments) {
            $null = Get-PnPProperty -ClientObject $assignment -Property Member,RoleDefinitionBindings -Connection $Connection -ErrorAction Stop
            $roles = @($assignment.RoleDefinitionBindings | ForEach-Object { [string]$_.Name })
            if ([int]$assignment.Member.Id -eq $GroupId -and $script:CoEReviewerRoleName -in $roles) { $reviewerOk = $true }
            if ([int]$assignment.Member.Id -eq $OwnersGroupId -and "Full Control" -in $roles) { $ownersOk = $true }
        }
        if ($current.HasUniqueRoleAssignments -and $reviewerOk -and $ownersOk) { return }
        if ($attempt -lt 3) { Start-Sleep -Seconds (5 * $attempt) }
    }
    throw "Catalog '$($List.Title)' reviewer access could not be verified: the '$($script:CoEReviewerGroupName)' group must hold '$($script:CoEReviewerRoleName)' and the site Owners must keep Full Control; do not seed or present catalog views."
}

function Set-CoECatalogReviewPermissions {
    <#
    .SYNOPSIS
    Enables native content approval and gives the CoE Catalog Reviewers group Contribute plus ApproveItems.
    .NOTES
    Reviewers are added to one SharePoint group and that group is granted the reviewer permission level on
    each catalog list. No principal read from an inherited permission snapshot is ever updated: breaking
    inheritance does not copy Limited Access entries, so such principals no longer exist on the list.
    Existing grants for other principals are left exactly as SharePoint copied them. Former reviewer removal
    is an administrator decision made in SharePoint by editing the group.
    A list item with its own unique permissions stops the run before any change.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$List, [string[]]$ReviewerUPNs = @(), [Parameter(Mandatory)]$Connection,
        [AllowEmptyCollection()][object[]]$ResolvedReviewers)
    Assert-CoECatalogItemInheritance $List $Connection
    $reviewers = @(if ($PSBoundParameters.ContainsKey("ResolvedReviewers")) { $ResolvedReviewers } else {
        Resolve-CoECatalogReviewers $ReviewerUPNs $Connection
    })
    if ($reviewers.Count) {
        Write-CoEStep "Grant reviewer access" $List.Title
        Initialize-CoECatalogReviewerRole $Connection
        $group = Initialize-CoECatalogReviewerGroup $reviewers $Connection
        $web = Get-PnPWeb -Includes AssociatedOwnerGroup -Connection $Connection -ErrorAction Stop
        $owners = $web.AssociatedOwnerGroup
        if (-not $owners -or $owners.Id -le 0) { throw "The associated site Owners group could not be verified." }
        $current = Get-PnPList -Identity $List.Id -Includes HasUniqueRoleAssignments -Connection $Connection -ErrorAction Stop
        if (-not $current -or $current.Id -ne $List.Id) { throw "Catalog permission read did not return the original list ID." }
        if (-not $current.HasUniqueRoleAssignments) {
            Write-CoEStep "Break inheritance (copy existing grants)" $List.Title
            Set-PnPList -Identity $List.Id -BreakRoleInheritance -CopyRoleAssignments -Connection $Connection -ErrorAction Stop | Out-Null
        }
        Set-PnPListPermission -Identity $List.Id -Group $script:CoEReviewerGroupName -AddRole $script:CoEReviewerRoleName `
            -Connection $Connection -ErrorAction Stop | Out-Null
        Assert-CoECatalogReviewerAccess $List ([int]$group.Id) ([int]$owners.Id) $Connection
    }
    Write-CoEStep "Enable content approval" $List.Title
    Set-PnPList -Identity $List.Id -EnableVersioning $true -EnableModeration $true -DraftVersionVisibility Approver `
        -Connection $Connection -ErrorAction Stop | Out-Null
    $verified = Get-PnPList -Identity $List.Id -Includes EnableVersioning,EnableModeration,DraftVersionVisibility `
        -Connection $Connection -ErrorAction Stop
    if (-not $verified -or $verified.Id -ne $List.Id -or -not $verified.EnableVersioning -or
        -not $verified.EnableModeration -or [string]$verified.DraftVersionVisibility -ne "Approver") {
        throw "Catalog '$($List.Title)' content approval settings could not be verified."
    }
    Assert-CoECatalogItemInheritance $List $Connection
}

function Assert-CoECatalogPreflight([string]$SiteUrl, $Connection) {
    $lists = @(Get-PnPList -Includes RootFolder,BaseTemplate -Connection $Connection -ErrorAction Stop)
    foreach ($definition in @(
        @{ Title = "Copilot Learning Paths"; Url = "CopilotLearningPaths" },
        @{ Title = "Copilot Agent Showcase"; Url = "CopilotAgentShowcase" })) {
        $path = ([uri]($SiteUrl.TrimEnd("/") + "/Lists/" + $definition.Url)).AbsolutePath
        $matches = @($lists | Where-Object {
            $_.Title -eq $definition.Title -or $_.RootFolder.ServerRelativeUrl.TrimEnd("/") -eq $path
        })
        if ($matches.Count -gt 1) { throw "Catalog '$($definition.Title)' has duplicate or ambiguous list identities." }
        if ($matches.Count) {
            if ($matches[0].BaseTemplate -ne 100 -or $matches[0].RootFolder.ServerRelativeUrl.TrimEnd("/") -ne $path) {
                throw "Catalog '$($definition.Title)' is not the expected native list."
            }
            Assert-CoECatalogItemInheritance $matches[0] $Connection
        }
    }
}
