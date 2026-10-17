function Test-TeamsFileTabTarget {
    param($Tab, [string]$FileUrl, [string]$EntityId)
    if ((Get-CoETabAppId $Tab) -eq "3e0a4fec-499b-4138-8e7c-71a9d88a62ed") {
        $modern = Get-CoEModernPowerPointTarget $Tab
        return $modern -and (Test-CoETabUrlEqual $modern.FileUrl $FileUrl) -and
            (-not $EntityId -or $modern.EntityId -eq $EntityId)
    }
    $configuration = $Tab.Configuration
    if (-not $configuration) { return $false }
    $contentUrl = [string]$configuration.ContentUrl
    if (-not $contentUrl) { return $false }
    if ([uri]::UnescapeDataString($contentUrl) -eq [uri]::UnescapeDataString($FileUrl)) { return $true }
    $uri = $null
    if ([uri]::TryCreate($contentUrl, [UriKind]::Absolute, [ref]$uri)) {
        foreach ($part in $uri.Query.TrimStart('?').Split('&')) {
            $pair = $part.Split('=', 2)
            if ($pair.Count -eq 2 -and [uri]::UnescapeDataString([uri]::UnescapeDataString($pair[1])) -eq [uri]::UnescapeDataString($FileUrl)) { return $true }
        }
    }
    return $false
}

function Add-TeamsTabWithRetry {
    param([string]$Team, [string]$Channel, [string]$DisplayName, [hashtable]$TabArgs, [object]$Connection,
        $Specification, [string]$ExpectedEntityId)
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            return Add-PnPTeamsTab -Team $Team -Channel $Channel -DisplayName $DisplayName @TabArgs -Connection $Connection -ErrorAction Stop
        } catch {
            $authFailure = $_.Exception.Message -match "401|403|Unauthorized|Forbidden|Access.?Denied|insufficient.*privilege|invalid.?token|authentication"
            if ($authFailure) { throw }
            if ($_.Exception.Message -match 'needs to be installed|unblocked state|app.*blocked|blocked.*app|app.*policy') {
                throw "Teams refused the '$DisplayName' tab because its app is not installed or allowed in this Team/channel scope. No app policy change or permission expansion was attempted. Review the approved app setup and resume. $($_.Exception.Message)"
            }
            $transient = $_.Exception.Message -match "Timeout|canceled|cancelled|429|TooManyRequests|502|503|504|temporarily|ServiceUnavailable|GatewayTimeout"
            if (-not $transient -or $authFailure) { throw }
            Write-Host "  Teams was slow adding the '$DisplayName' tab (attempt $attempt of 4); checking and retrying..."
            $retryTabs = @(if ($Specification) {
                Get-CoEResourceTabs -Team $Team -Channel $Channel -DisplayName $DisplayName -Connection $Connection
            } else {
                Get-PnPTeamsTab -Team $Team -Channel $Channel -Connection $Connection -ErrorAction Stop
            })
            $existingTab = @($retryTabs |
                Where-Object {
                    if ($_.DisplayName -ne $DisplayName) { return $false }
                    if ($Specification) {
                        return Test-CoEManagedTabTarget -Tab $_ -Specification $Specification -EntityId $ExpectedEntityId
                    }
                    if ($TabArgs.ContainsKey("ContentUrl")) {
                        $expectedEntity = if ($TabArgs.ContainsKey("EntityId")) { $TabArgs.EntityId } else { "" }
                        return Test-TeamsFileTabTarget -Tab $_ -FileUrl $TabArgs.ContentUrl -EntityId $expectedEntity
                    }
                    if ($TabArgs.ContainsKey("WebSiteUrl")) {
                        return Test-TeamsFileTabTarget -Tab $_ -FileUrl $TabArgs.WebSiteUrl
                    }
                    return $true
                }) | Select-Object -First 1
            if ($existingTab) { return $existingTab }
            if ($attempt -eq 4) { throw }
            Start-Sleep -Seconds (20 * $attempt)
        }
    }
}

function Sync-CoEFileTab {
    param([string]$Team, [string]$Channel, [string]$DisplayName, [string]$Type,
        [string]$FileUrl, [string]$EntityId, [string[]]$KnownFileUrls,
        [string]$PreviousEntityId, [switch]$CreateMissing, [switch]$RemoveUnboundPlaceholders, [object]$Connection,
        [switch]$VerifyIdentity)
    $specification = $null
    if ($VerifyIdentity) {
        $specification = [pscustomobject]@{
            Type = $Type; TeamsAppId = Get-CoETabAppIdForType $Type
            DisplayName = $DisplayName; ContentUrl = $FileUrl; WebsiteUrl = $FileUrl
        }
    }
    $tabs = @(if ($VerifyIdentity) {
        Get-CoEResourceTabs -Team $Team -Channel $Channel -DisplayName $DisplayName -Connection $Connection
    } else {
        Get-PnPTeamsTab -Team $Team -Channel $Channel -Connection $Connection -ErrorAction Stop |
            Where-Object DisplayName -eq $DisplayName
    })
    if ($tabs.Count -eq 0 -and -not $CreateMissing) {
        Write-Host "No '$DisplayName' tab; kept the resource in channel files without adding a tab."
        return $null
    }
    $intended = @($tabs | Where-Object {
        if ($VerifyIdentity) { Test-CoEManagedTabTarget $_ $specification $EntityId }
        else { Test-TeamsFileTabTarget $_ $FileUrl $EntityId }
    })
    if ($intended.Count -eq 0) {
        Add-TeamsTabWithRetry -Team $Team -Channel $Channel -DisplayName $DisplayName `
            -TabArgs @{ Type = $Type; ContentUrl = $FileUrl; EntityId = $EntityId } -Connection $Connection `
            -Specification $specification -ExpectedEntityId $EntityId | Out-Null
    }
    # Verify the replacement before removing anything; an interrupted replacement is recoverable.
    $tabs = @(if ($VerifyIdentity) {
        Get-CoEResourceTabs -Team $Team -Channel $Channel -DisplayName $DisplayName -Connection $Connection
    } else {
        Get-PnPTeamsTab -Team $Team -Channel $Channel -Connection $Connection -ErrorAction Stop |
            Where-Object DisplayName -eq $DisplayName
    })
    $intended = @($tabs | Where-Object {
        if (-not $_.Id) { return $false }
        if ($VerifyIdentity) { Test-CoEManagedTabTarget $_ $specification $EntityId }
        else { Test-TeamsFileTabTarget $_ $FileUrl $EntityId }
    })
    if ($intended.Count -eq 0) { throw "The intended '$DisplayName' tab could not be verified; all existing tabs were retained." }
    $keep = $intended[0]
    foreach ($tab in $tabs) {
        if ($tab.Id -eq $keep.Id) { continue }
        $contentUrl = if ($tab.Configuration) { [string]$tab.Configuration.ContentUrl } else { "" }
        $managed = if ($VerifyIdentity) { Test-CoETabUrlEqual $contentUrl $FileUrl }
            else { Test-TeamsFileTabTarget $tab $FileUrl $EntityId }
        if ($VerifyIdentity -and (Test-CoEManagedTabTarget $tab $specification $EntityId)) { $managed = $true }
        if ($RemoveUnboundPlaceholders -and $tab.Configuration -and
            -not $tab.Configuration.ContentUrl -and -not $tab.Configuration.EntityId) { $managed = $true }
        foreach ($knownUrl in $KnownFileUrls) {
            if (-not $knownUrl) { continue }
            $knownTarget = if ($VerifyIdentity) { Test-CoETabUrlEqual $contentUrl $knownUrl }
                else { Test-TeamsFileTabTarget $tab $knownUrl $PreviousEntityId }
            if ($knownTarget) { $managed = $true }
        }
        if ($VerifyIdentity -and -not (Test-CoETabAppForSpecification $tab $specification)) { $managed = $false }
        if ($managed) {
            Remove-PnPTeamsTab -Team $Team -Channel $Channel -Identity $tab.Id -Force -Connection $Connection -ErrorAction Stop | Out-Null
        } else {
            Write-Warning "Preserved unrelated same-name '$DisplayName' tab '$($tab.Id)'."
        }
    }
    if ($VerifyIdentity) {
        $remaining = @(Get-CoEResourceTabs -Team $Team -Channel $Channel -DisplayName $DisplayName -Connection $Connection)
        $verified = @($remaining | Where-Object {
            $_.Id -eq $keep.Id -and (Test-CoEManagedTabTarget $_ $specification $EntityId)
        })
        if ($verified.Count -ne 1 -or @($remaining | Where-Object {
            $_.DisplayName -eq $DisplayName -and (Test-CoEManagedTabTarget $_ $specification $EntityId)
        }).Count -ne 1) { throw "The '$DisplayName' file tab identity or duplicate cleanup could not be verified." }
    }
    return $keep
}

function Get-CoETabAppIdForType {
    param([string]$Type)
    switch ($Type) {
        "WebSite" { return "com.microsoft.teamspace.tab.web" }
        "PDF" { return "com.microsoft.teamspace.tab.file.staticviewer.pdf" }
        "PowerPoint" { return "com.microsoft.teamspace.tab.file.staticviewer.powerpoint" }
        "SharePointPageAndList" { return "2a527703-1f6f-4559-a332-d8a7d288cd88" }
        default { throw "Unsupported managed resource tab type '$Type'." }
    }
}

function Get-CoETabAppId {
    param($Tab)
    if ($Tab.PSObject.Properties["TeamsApp"] -and $Tab.TeamsApp) {
        # ExternalId is the manifest identity; Id can instead be a tenant catalog identity.
        if ($Tab.TeamsApp.PSObject.Properties["ExternalId"] -and $Tab.TeamsApp.ExternalId) {
            return [string]$Tab.TeamsApp.ExternalId
        }
        if ($Tab.TeamsApp.Id) { return [string]$Tab.TeamsApp.Id }
        return ""
    }
    if ($Tab.PSObject.Properties["TeamsAppId"]) { return [string]$Tab.TeamsAppId }
    return ""
}

function Test-CoETabAppForSpecification {
    param($Tab, $Specification)
    $appId = Get-CoETabAppId $Tab
    return $appId -eq $Specification.TeamsAppId -or
        ($Specification.Type -eq "PowerPoint" -and $appId -eq "3e0a4fec-499b-4138-8e7c-71a9d88a62ed")
}

function Get-CoEResourceProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ($key -eq $Name) { return $Object[$key] }
        }
    } elseif ($Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $null
}

function Convert-CoEModernObjectUrl {
    param([string]$Url)
    for ($i = 0; $i -lt 2 -and $Url -match '^https?%(?:25)?3[aA]'; $i++) {
        $Url = [uri]::UnescapeDataString($Url)
    }
    $uri = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne "https" -or $uri.UserInfo) { return "" }
    return $Url
}

function Get-CoEModernPowerPointTarget {
    param($Tab)
    if ((Get-CoETabAppId $Tab) -ne "3e0a4fec-499b-4138-8e7c-71a9d88a62ed" -or -not $Tab.Configuration) { return $null }
    $configuration = $Tab.Configuration
    $uri = $null
    if (-not [uri]::TryCreate([string]$configuration.ContentUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne "https" -or $uri.Authority -ne "m365.cloud.microsoft" -or $uri.UserInfo -or $uri.Fragment -or
        $uri.AbsolutePath -cne "/launch/PowerPoint/officeunihost/teams") { return $null }
    $subEntityParts = @($uri.Query.TrimStart('?').Split('&') | Where-Object { $_ -cmatch '^subEntityId=' })
    if ($subEntityParts.Count -ne 1) { return $null }
    $json = $subEntityParts[0].Substring("subEntityId=".Length)
    for ($i = 0; $i -lt 2 -and -not $json.TrimStart().StartsWith('{'); $i++) { $json = [uri]::UnescapeDataString($json) }
    try { $payload = $json | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ((Get-CoEResourceProperty $payload "fileType") -cne "pptx" -or
        (Get-CoEResourceProperty $payload "isPinnedTab") -isnot [bool] -or -not $payload.isPinnedTab) { return $null }
    $fileId = [guid]::Empty
    if (-not [guid]::TryParse([string](Get-CoEResourceProperty $payload "fileId"), [ref]$fileId) -or $fileId -eq [guid]::Empty) { return $null }
    $fileUrl = Convert-CoEModernObjectUrl ([string](Get-CoEResourceProperty $payload "objectUrl"))
    if (-not $fileUrl) { return $null }
    $objectId = Get-CoEResourceProperty $configuration "objectId"
    if ($objectId -and [string]$objectId -ne $fileId.ToString()) { return $null }
    $file = Get-CoEResourceProperty $configuration "file"
    if ($file) {
        if ($file -is [string]) {
            try { $file = $file | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
        }
        if ((Get-CoEResourceProperty $file "type") -cne "pptx" -or
            [string](Get-CoEResourceProperty $file "objectId") -ne $fileId.ToString() -or
            -not (Test-CoETabUrlEqual (Convert-CoEModernObjectUrl ([string](Get-CoEResourceProperty $file "objectUrl"))) $fileUrl)) { return $null }
    }
    return [pscustomobject]@{ FileUrl = $fileUrl; EntityId = $fileId.ToString() }
}

function Get-CoEResourceTabs {
    param([string]$Team, [string]$Channel, [string]$DisplayName, [object]$Connection)
    $tabs = @(Get-PnPTeamsTab -Team $Team -Channel $Channel -Connection $Connection -ErrorAction Stop |
        Where-Object DisplayName -eq $DisplayName)
    Assert-CoETabIdentities $tabs
    foreach ($tab in $tabs) {
        # Raw expansion preserves modern Office objectId/file metadata omitted by PnP's typed model.
        if (-not $tab.PSObject.Properties["TeamsApp"] -or -not $tab.TeamsApp -or -not $tab.TeamsApp.Id -or
            (Get-CoETabAppId $tab) -eq "3e0a4fec-499b-4138-8e7c-71a9d88a62ed") {
            $runtimeId = [guid]::Empty
            if (-not [guid]::TryParse([string]$tab.Id, [ref]$runtimeId)) {
                throw "Cannot expand the '$DisplayName' tab's app without a valid runtime tab GUID; no tab was changed."
            }
            $url = "v1.0/teams/$([uri]::EscapeDataString($Team))/channels/$([uri]::EscapeDataString($Channel))/tabs/$($tab.Id)?`$expand=teamsApp"
            $expanded = @(Invoke-PnPGraphMethod -Url $url -Method Get -Raw -Connection $Connection -ErrorAction Stop |
                ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
            if ($expanded.Count -ne 1 -or $expanded[0].Id -ne $tab.Id -or $expanded[0].DisplayName -cne $tab.DisplayName -or
                -not $expanded[0].PSObject.Properties["TeamsApp"] -or -not $expanded[0].TeamsApp -or -not $expanded[0].TeamsApp.Id) {
                throw "The '$DisplayName' tab's expanded app/runtime identity could not be verified; no tab was changed."
            }
            $tab = $expanded[0]
        }
        if (-not (Get-CoETabAppId $tab)) {
            throw "The '$DisplayName' tab has no verifiable app identity; no tab was changed."
        }
        $tab
    }
}

function Test-CoETabUrlEqual {
    param([string]$Actual, [string]$Expected)
    if (-not $Actual -or -not $Expected) { return $false }
    return [string]::Equals([uri]::UnescapeDataString($Actual), [uri]::UnescapeDataString($Expected),
        [StringComparison]::Ordinal)
}

function Test-CoEUrlInSite {
    param([string]$Url, [string]$SiteUrl)
    $uri = $null
    $site = [uri]$SiteUrl
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne "https" -or
        $uri.UserInfo -or $uri.Authority -ne $site.Authority) { return $false }
    $path = [uri]::UnescapeDataString($uri.AbsolutePath)
    $prefix = [uri]::UnescapeDataString($site.AbsolutePath).TrimEnd('/') + '/'
    return $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-CoEManagedTabTarget {
    param($Tab, $Specification, [string]$EntityId)
    if (-not $Tab.Id -or -not (Test-CoETabAppForSpecification $Tab $Specification) -or -not $Tab.Configuration) { return $false }
    if ($Specification.PSObject.Properties["DisplayName"] -and $Tab.DisplayName -cne $Specification.DisplayName) { return $false }
    $configuration = $Tab.Configuration
    if ($Specification.Type -eq "PowerPoint" -and (Get-CoETabAppId $Tab) -eq "3e0a4fec-499b-4138-8e7c-71a9d88a62ed") {
        $modern = Get-CoEModernPowerPointTarget $Tab
        return $modern -and $EntityId -and $modern.EntityId -eq $EntityId -and
            (Test-CoETabUrlEqual $modern.FileUrl $Specification.ContentUrl)
    }
    if ($Specification.Type -eq "SharePointPageAndList") {
        $contentUri = $null
        $websiteUri = [uri]$Specification.WebsiteUrl
        if (-not (Test-CoETabUrlEqual $configuration.WebsiteUrl $Specification.WebsiteUrl) -or
            -not [uri]::TryCreate([string]$configuration.ContentUrl, [UriKind]::Absolute, [ref]$contentUri) -or
            $contentUri.Authority -ne $websiteUri.Authority -or $contentUri.Scheme -ne "https" -or
            $contentUri.UserInfo -or $contentUri.Fragment) { return $false }
        $pageIndex = $websiteUri.AbsolutePath.IndexOf("/SitePages/", [StringComparison]::OrdinalIgnoreCase)
        if ($pageIndex -lt 0) { return $false }
        $sitePath = $websiteUri.AbsolutePath.Substring(0, $pageIndex)
        if ($contentUri.AbsolutePath -ne "$sitePath/_layouts/15/teamslogon.aspx") { return $false }
        $queryParts = @($contentUri.Query.TrimStart('?').Split('&'))
        $destinations = @($queryParts | Where-Object { $_ -cmatch '^dest=' })
        return $queryParts.Count -eq 2 -and @($queryParts | Where-Object { $_ -ceq 'spfx=true' }).Count -eq 1 -and $destinations.Count -eq 1 -and
            (Test-CoETabUrlEqual ([uri]::UnescapeDataString($destinations[0].Substring(5))) $Specification.WebsiteUrl)
    }
    if (-not (Test-CoETabUrlEqual $configuration.ContentUrl $Specification.ContentUrl)) { return $false }
    if ($Specification.Type -eq "WebSite") {
        return Test-CoETabUrlEqual $configuration.WebsiteUrl $Specification.WebsiteUrl
    }
    # File viewers must use the uploaded file identity, not the captured source tenant's identity.
    return $EntityId -and [string]::Equals([string]$configuration.EntityId, $EntityId, [StringComparison]::OrdinalIgnoreCase)
}

function Expand-CoETeamTemplateValue {
    param([string]$Value, [hashtable]$Parameters)
    $expanded = [regex]::Replace($Value, '\{(?:parameter:)?([^{}]+)\}', {
        param($match)
        $key = $match.Groups[1].Value
        if (-not $Parameters.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$Parameters[$key])) {
            throw "Unresolved Team template parameter '$key'."
        }
        return [string]$Parameters[$key]
    })
    if ($expanded -match '[{}]') { throw "Unresolved Team template value." }
    return $expanded
}

function Get-CoEStandardChannelSpec {
    param([string]$Path, [hashtable]$Parameters, [string]$SiteUrl)
    $document = [xml](Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop)
    $teams = @($document.SelectNodes("//*[local-name()='Teams']/*[local-name()='Team']"))
    if ($teams.Count -ne 1) { throw "Expected one Team in the prepared Team template." }
    $specifications = @()
    foreach ($channel in $teams[0].SelectNodes("./*[local-name()='Channels']/*[local-name()='Channel']")) {
        $membershipType = $channel.GetAttribute("MembershipType")
        if ($membershipType -and $membershipType -ne "Standard") { throw "The resource template may contain only standard channels." }
        $name = Expand-CoETeamTemplateValue $channel.GetAttribute("DisplayName") $Parameters
        if (-not $name -or @($specifications | Where-Object DisplayName -eq $name).Count) { throw "Duplicate or empty standard channel name in the template." }
        $tabs = @()
        foreach ($tab in $channel.SelectNodes("./*[local-name()='Tabs']/*[local-name()='Tab']")) {
            $tabName = Expand-CoETeamTemplateValue $tab.GetAttribute("DisplayName") $Parameters
            if (-not $tabName -or @($tabs | Where-Object DisplayName -eq $tabName).Count -or $tab.GetAttribute("Remove") -eq "true") {
                throw "Invalid or duplicate managed resource tab in '$name'."
            }
            $configuration = $tab.SelectSingleNode("./*[local-name()='Configuration']")
            if (-not $configuration) { throw "Missing configuration for '$name / $tabName'." }
            $appId = $tab.GetAttribute("TeamsAppId")
            $type = switch ($appId) {
                "com.microsoft.teamspace.tab.web" { "WebSite" }
                "com.microsoft.teamspace.tab.file.staticviewer.pdf" { "PDF" }
                "com.microsoft.teamspace.tab.file.staticviewer.powerpoint" { "PowerPoint" }
                "0ae35b36-0fd7-422e-805b-d53af1579093" { "SharePointPageAndList" }
                "2a527703-1f6f-4559-a332-d8a7d288cd88" { "SharePointPageAndList" }
                default { throw "Unsupported packaged Teams app '$appId' for '$tabName'." }
            }
            $contentUrl = Expand-CoETeamTemplateValue $configuration.GetAttribute("ContentUrl") $Parameters
            $websiteUrl = Expand-CoETeamTemplateValue $configuration.GetAttribute("WebsiteUrl") $Parameters
            foreach ($url in @($contentUrl, $websiteUrl)) {
                $uri = $null
                if (-not [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne "https" -or $uri.UserInfo) {
                    throw "Invalid HTTPS destination for '$name / $tabName'."
                }
            }
            if ($type -ne "WebSite" -and -not (Test-CoEUrlInSite $websiteUrl $SiteUrl)) {
                throw "The '$tabName' destination is outside the verified CoE site."
            }
            if ($type -ne "SharePointPageAndList" -and -not (Test-CoETabUrlEqual $contentUrl $websiteUrl)) {
                throw "The '$tabName' content and website destinations disagree."
            }
            if ($type -eq "SharePointPageAndList") {
                $probe = [pscustomobject]@{ Id = "validation"; TeamsAppId = Get-CoETabAppIdForType $type
                    Configuration = [pscustomobject]@{ ContentUrl = $contentUrl; WebsiteUrl = $websiteUrl } }
                $probeSpec = [pscustomobject]@{ Type = $type; TeamsAppId = Get-CoETabAppIdForType $type; WebsiteUrl = $websiteUrl }
                if (-not (Test-CoEManagedTabTarget $probe $probeSpec "")) { throw "The '$tabName' SharePoint wrapper has a wrong destination." }
            }
            $tabs += [pscustomobject]@{
                DisplayName = $tabName; Type = $type; TeamsAppId = Get-CoETabAppIdForType $type
                TemplateAppId = $appId; ContentUrl = $contentUrl; WebsiteUrl = $websiteUrl
            }
        }
        $specifications += [pscustomobject]@{
            DisplayName = $name; Description = Expand-CoETeamTemplateValue $channel.GetAttribute("Description") $Parameters
            Tabs = $tabs
        }
    }
    if (-not $specifications.Count) { throw "No standard channels in the prepared Team template." }
    return $specifications
}

function Get-CoEVerifiedStandardChannel {
    param([object[]]$Channels, [string]$DisplayName, [string]$ExpectedId)
    $matching = @($Channels | Where-Object DisplayName -eq $DisplayName)
    if ($matching.Count -gt 1) { throw "Ambiguous standard channel '$DisplayName'; multiple names match." }
    if ($matching.Count -eq 0) { return $null }
    $channel = $matching[0]
    if ($channel.DisplayName -cne $DisplayName -or $channel.MembershipType -ne "standard" -or -not $channel.Id -or
        @($Channels | Where-Object Id -eq $channel.Id).Count -ne 1 -or ($ExpectedId -and $channel.Id -ne $ExpectedId)) {
        throw "The '$DisplayName' channel name, standard membership type, or runtime ID could not be verified."
    }
    return $channel
}

# Teams is eventually consistent: a channel that was just created can be missing from the very next listing.
# Poll for it instead of trusting one read, and say exactly what was seen, because "expected one channel"
# for a channel that does exist a moment later is a misleading failure.
function Wait-CoEStandardChannel {
    param([string]$Team, [string]$DisplayName, [object]$Connection, [int]$Checks = 12, [int]$DelaySeconds = 10)
    $seen = @()
    for ($check = 1; $check -le $Checks; $check++) {
        $channels = @(Get-PnPTeamsChannel -Team $Team -Connection $Connection -ErrorAction Stop)
        $seen = @($channels | Where-Object DisplayName -eq $DisplayName)
        if ($seen.Count -eq 1 -and $seen[0].MembershipType -eq "standard") { return [pscustomobject]@{ Channel = $seen[0]; Channels = $channels } }
        if ($seen.Count -gt 1) { throw "Ambiguous channel '$DisplayName': $($seen.Count) channels share that name." }
        if ($check -lt $Checks) { Start-Sleep -Seconds $DelaySeconds }
    }
    if ($seen.Count -eq 1) { throw "Channel '$DisplayName' exists but is '$($seen[0].MembershipType)', not a standard channel." }
    throw "Channel '$DisplayName' did not appear in Teams within $($Checks * $DelaySeconds) seconds of being created."
}

function Ensure-CoEStandardChannels {
    param([string]$Team, [object[]]$Specifications, [object]$Connection)
    $channels = @(Get-PnPTeamsChannel -Team $Team -Connection $Connection -ErrorAction Stop)
    # Validate every existing expected identity before creating any missing channel.
    foreach ($spec in $Specifications) {
        Get-CoEVerifiedStandardChannel $channels $spec.DisplayName | Out-Null
    }
    $verified = @()
    foreach ($spec in $Specifications) {
        $channel = Get-CoEVerifiedStandardChannel $channels $spec.DisplayName
        for ($attempt = 1; -not $channel -and $attempt -le 4; $attempt++) {
            $failure = $null
            try {
                Add-PnPTeamsChannel -Team $Team -DisplayName $spec.DisplayName -Description $spec.Description `
                    -ChannelType Standard -Connection $Connection -ErrorAction Stop | Out-Null
            } catch {
                if ($_.Exception.Message -match '401|403|Unauthorized|Forbidden|Access.?Denied|insufficient.*privilege|invalid.?token|authentication' -or
                    $_.Exception.Message -notmatch 'Timeout|canceled|cancelled|429|TooManyRequests|502|503|504|temporarily|ServiceUnavailable|GatewayTimeout|409|Conflict|already exists') { throw }
                $failure = $_
            }
            for ($check = 1; $check -le 6 -and -not $channel; $check++) {
                $channels = @(Get-PnPTeamsChannel -Team $Team -Connection $Connection -ErrorAction Stop)
                $channel = Get-CoEVerifiedStandardChannel $channels $spec.DisplayName
                if (-not $channel -and $check -lt 6) { Start-Sleep -Seconds 10 }
            }
            if (-not $channel -and -not $failure) { throw "Teams accepted '$($spec.DisplayName)' but its standard channel identity could not be verified. Resume after checking Teams." }
            if (-not $channel -and $attempt -eq 4) { throw $failure }
        }
        $verified += $channel
    }
    $channels = @(Get-PnPTeamsChannel -Team $Team -Connection $Connection -ErrorAction Stop)
    foreach ($channel in $verified) {
        $final = Get-CoEVerifiedStandardChannel $channels $channel.DisplayName $channel.Id
        if (-not $final) { throw "The verified standard channel '$($channel.DisplayName)' disappeared." }
        $final
    }
}

function Sync-CoEManagedResourceTab {
    param([string]$Team, [string]$Channel, $Specification, [string]$EntityId, [object]$Connection)
    if ($Specification.Type -in @("PDF", "PowerPoint")) {
        if (-not $EntityId) { throw "A verified uploaded file identity is required for '$($Specification.DisplayName)'." }
        return Sync-CoEFileTab -Team $Team -Channel $Channel -DisplayName $Specification.DisplayName `
            -Type $Specification.Type -FileUrl $Specification.ContentUrl -EntityId $EntityId `
            -KnownFileUrls @($Specification.ContentUrl) -CreateMissing -RemoveUnboundPlaceholders `
            -VerifyIdentity -Connection $Connection
    }
    $tabs = @(Get-CoEResourceTabs -Team $Team -Channel $Channel -DisplayName $Specification.DisplayName -Connection $Connection)
    $intended = @($tabs | Where-Object { Test-CoEManagedTabTarget $_ $Specification "" })
    if (-not $intended.Count) {
        # Named $tabArgs, not $args: $args is PowerShell's own automatic variable (the non-declared argument
        # list available inside any function/script) - the same class of mistake caught and fixed in
        # Complete-CopilotCoE.ps1's page-header loop. Harmless here too (nothing downstream reads the real
        # $args in this scope), but renamed for the same reason: never shadow an automatic variable.
        $tabArgs = @{ Type = $Specification.Type }
        if ($Specification.Type -eq "WebSite") { $tabArgs.ContentUrl = $Specification.ContentUrl }
        elseif ($Specification.Type -eq "SharePointPageAndList") { $tabArgs.WebsiteUrl = $Specification.WebsiteUrl }
        else { throw "Unsupported managed resource tab type '$($Specification.Type)'." }
        Add-TeamsTabWithRetry -Team $Team -Channel $Channel -DisplayName $Specification.DisplayName `
            -TabArgs $tabArgs -Specification $Specification -Connection $Connection | Out-Null
    }
    $tabs = @(Get-CoEResourceTabs -Team $Team -Channel $Channel -DisplayName $Specification.DisplayName -Connection $Connection)
    $intended = @($tabs | Where-Object { Test-CoEManagedTabTarget $_ $Specification "" })
    if (-not $intended.Count) { throw "The '$($Specification.DisplayName)' app and destination could not be verified; existing tabs were retained." }
    $keep = $intended[0]
    foreach ($tab in $tabs) {
        if ($tab.Id -eq $keep.Id) { continue }
        $managed = Test-CoEManagedTabTarget $tab $Specification ""
        # The captured SharePoint app is a known kit placeholder, not the current PnP page app.
        if ($Specification.Type -eq "SharePointPageAndList" -and (Get-CoETabAppId $tab) -eq $Specification.TemplateAppId -and
            $tab.Configuration -and (Test-CoETabUrlEqual $tab.Configuration.ContentUrl $Specification.ContentUrl) -and
            (Test-CoETabUrlEqual $tab.Configuration.WebsiteUrl $Specification.WebsiteUrl)) { $managed = $true }
        if ($managed) {
            Remove-PnPTeamsTab -Team $Team -Channel $Channel -Identity $tab.Id -Force -Connection $Connection -ErrorAction Stop | Out-Null
        } else {
            Write-Warning "Preserved unrelated same-name '$($Specification.DisplayName)' tab '$($tab.Id)'; it is not the managed destination."
        }
    }
    $remaining = @(Get-CoEResourceTabs -Team $Team -Channel $Channel -DisplayName $Specification.DisplayName -Connection $Connection)
    $intended = @($remaining | Where-Object { Test-CoEManagedTabTarget $_ $Specification "" })
    if ($intended.Count -ne 1 -or $intended[0].Id -ne $keep.Id) { throw "The '$($Specification.DisplayName)' tab identity or duplicate cleanup could not be verified." }
    return $intended[0]
}

function Assert-CoETabIdentities {
    param([object[]]$Tabs)
    foreach ($tab in $Tabs) {
        if (-not $tab.Id -or @($Tabs | Where-Object Id -eq $tab.Id).Count -ne 1) {
            throw "An existing same-name resource tab has a missing or ambiguous runtime ID; no tab was removed."
        }
    }
}

function Get-CoEStandardChannelFilesFolder {
    param([string]$Team, [string]$Channel, [string]$SiteUrl, [string]$ExpectedFolderUrl, [object]$Connection)
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $folder = $null
        try {
            $folder = Get-PnPTeamsChannelFilesFolder -Team $Team -Channel $Channel -Connection $Connection -ErrorAction Stop
        } catch {
            if ($_.Exception.Message -match '401|403|Unauthorized|Forbidden|Access.?Denied|insufficient.*privilege|invalid.?token|authentication' -or
                $_.Exception.Message -notmatch 'Timeout|canceled|cancelled|429|TooManyRequests|502|503|504|temporarily|ServiceUnavailable|GatewayTimeout|404|NotFound') { throw }
            if ($attempt -eq 6) { throw }
        }
        if ($folder) {
            $url = [string]$folder.webUrl
            if (-not (Test-CoEUrlInSite $url $SiteUrl) -or
                -not (Test-CoETabUrlEqual $url.TrimEnd('/') $ExpectedFolderUrl.TrimEnd('/'))) {
                throw "The standard channel files folder is not the expected resource destination in the verified CoE site."
            }
            return $folder
        }
        if ($attempt -lt 6) { Start-Sleep -Seconds 10 }
    }
    throw "The standard channel files folder could not be verified."
}

function Get-CoEManagedFileIdentity {
    param([string]$FileUrl, [string]$SiteUrl, [object]$Connection)
    if (-not (Test-CoEUrlInSite $FileUrl $SiteUrl)) { throw "The managed file destination is outside the verified CoE site." }
    $path = [uri]::UnescapeDataString(([uri]$FileUrl).AbsolutePath)
    $file = Get-PnPFile -Url $path -AsFileObject -Connection $Connection -ErrorAction Stop
    if (-not $file) { throw "The managed file could not be read at its expected destination." }
    Get-PnPProperty -ClientObject $file -Property UniqueId, ServerRelativeUrl -Connection $Connection -ErrorAction Stop | Out-Null
    $fileId = [guid]::Empty
    if (-not [guid]::TryParse([string]$file.UniqueId, [ref]$fileId) -or $fileId -eq [guid]::Empty -or
        -not [string]::Equals([uri]::UnescapeDataString([string]$file.ServerRelativeUrl), $path, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The managed file ID and server-relative destination could not be verified."
    }
    return $fileId.ToString()
}

function Get-CoEResourceGraphHost {
    param($Connection)
    # GraphEndPoint is internal in PnP 3.2.0; these public AzureEnvironment mappings match AuthenticationManager.
    switch ([string](Get-CoEResourceProperty $Connection "AzureEnvironment")) {
        "Production" { return "graph.microsoft.com" }
        "USGovernment" { return "graph.microsoft.com" }
        "USGovernmentHigh" { return "graph.microsoft.us" }
        "USGovernmentDoD" { return "dod-graph.microsoft.us" }
        "China" { return "microsoftgraph.chinacloudapi.cn" }
        "Germany" { return "graph.microsoft.de" }
        default { throw "The connection's Microsoft Graph cloud could not be verified; no app was installed." }
    }
}

function Get-CoETeamResourceApps {
    param([string]$Team, [object]$Connection)
    $teamId = [guid]::Empty
    if (-not [guid]::TryParse($Team, [ref]$teamId) -or $teamId -eq [guid]::Empty) { throw "App capability verification requires a runtime Team GUID." }
    $graphHost = Get-CoEResourceGraphHost $Connection
    $path = "v1.0/teams/$Team/installedApps"
    $next = "$path`?`$expand=teamsApp"
    $visited = @()
    for ($page = 1; $page -le 20; $page++) {
        if ($next -in $visited) { throw "A repeated installed-apps page was returned; no app was installed." }
        $visited += $next
        $response = Invoke-PnPGraphMethod -Url $next -Method Get -Raw -Connection $Connection -ErrorAction Stop
        if (-not $response) { throw "The Team installed-apps response was empty; no app was installed." }
        $data = $response | ConvertFrom-Json -ErrorAction Stop
        if (-not $data.PSObject.Properties["value"] -or $data.value -isnot [array]) {
            throw "The Team installed-apps response was not a collection; no app was installed."
        }
        foreach ($installation in $data.value) {
            if (-not $installation.id -or -not $installation.PSObject.Properties["teamsApp"] -or
                -not $installation.teamsApp -or -not $installation.teamsApp.id) {
                throw "A Team installation has no expanded app identity; no app was installed."
            }
            $installation
        }
        $next = [string](Get-CoEResourceProperty $data "@odata.nextLink")
        if (-not $next) { return }
        $nextUri = $null
        if (-not [uri]::TryCreate($next, [UriKind]::Absolute, [ref]$nextUri) -or $nextUri.Scheme -ne "https" -or
            $nextUri.Authority -ne $graphHost -or $nextUri.AbsolutePath -ne "/$path" -or $nextUri.UserInfo -or $nextUri.Fragment) {
            throw "The installed-apps continuation is outside the verified Team scope; no app was installed."
        }
    }
    throw "Installed-apps pagination exceeded the verification limit; no app was installed."
}

function Find-CoEResourceAppInstallation {
    param([object[]]$Installations, [string]$AppId)
    $matching = @($Installations | Where-Object {
        (Get-CoETabAppId ([pscustomobject]@{ TeamsApp = $_.teamsApp })) -eq $AppId
    })
    if ($matching.Count -gt 1) { throw "Multiple Team app installations match '$AppId'; no app was installed." }
    if ($matching.Count) { return $matching[0] }
    return $null
}

function Get-CoEResourcePageName {
    param([string]$ResourceUrl)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ResourceUrl))
        return "Resource-" + ([BitConverter]::ToString($hash).Replace("-", "").Substring(0, 24).ToLowerInvariant()) + ".aspx"
    } finally { $sha.Dispose() }
}

function Get-CoEResourcePageHtml {
    param([string]$DisplayName, [string]$ResourceUrl)
    $title = [Net.WebUtility]::HtmlEncode($DisplayName)
    $url = [Net.WebUtility]::HtmlEncode($ResourceUrl)
    return "<h2>$title</h2><p>Copilot CoE resource link. The official resource opens in a new browser tab.</p><p><a href=`"$url`" target=`"_blank`" rel=`"noopener noreferrer`" data-interception=`"off`">Open official resource</a></p>"
}

function Get-CoEResourcePagePendingTitle {
    param([string]$ResourceUrl)
    return "Copilot CoE managed resource pending: $(Get-CoEResourcePageName $ResourceUrl)"
}

function Test-CoEResourcePage {
    param($Page, [string]$DisplayName, [string]$ResourceUrl, [switch]$AllowPendingTitle)
    if (-not $Page -or @($Page.Controls).Count -ne 1 -or
        ($Page.PageTitle -cne $DisplayName -and
            (-not $AllowPendingTitle -or $Page.PageTitle -cne (Get-CoEResourcePagePendingTitle $ResourceUrl)))) { return $false }
    $text = [string](Get-CoEResourceProperty $Page.Controls[0] "Text")
    if (-not $text) { return $false }
    $actual = [Xml.XmlDocument]::new()
    $actual.XmlResolver = $null
    $expected = [Xml.XmlDocument]::new()
    $expected.XmlResolver = $null
    try {
        $actual.LoadXml("<div>$text</div>")
        $expected.LoadXml("<div>$(Get-CoEResourcePageHtml $DisplayName $ResourceUrl)</div>")
    } catch { return $false }
    $anchors = @($actual.SelectNodes("//a"))
    if ($anchors.Count -ne 1 -or @($actual.SelectNodes("//*")).Count -ne 5 -or
        $actual.DocumentElement.InnerText -cne $expected.DocumentElement.InnerText -or
        @($actual.SelectNodes("//comment() | //processing-instruction()")).Count -or
        @($actual.SelectNodes("/div/h2 | /div/p")).Count -ne 3 -or
        @($actual.SelectNodes("/div/*[1][self::h2] | /div/*[2][self::p] | /div/*[3][self::p]/a")).Count -ne 3) { return $false }
    foreach ($path in @("/div/h2", "/div/p[1]", "/div/p[2]")) {
        if ($actual.SelectSingleNode($path).InnerText -cne $expected.SelectSingleNode($path).InnerText) { return $false }
    }
    $anchor = $anchors[0]
    if ($anchor.GetAttribute("href") -cne $ResourceUrl -or
        $anchor.GetAttribute("target") -cne "_blank" -or $anchor.GetAttribute("data-interception") -cne "off" -or
        $anchor.GetAttribute("rel") -cne "noopener noreferrer") { return $false }
    foreach ($attribute in $actual.SelectNodes("//@*")) {
        if ($attribute.OwnerElement -ne $anchor -or $attribute.Name -notin @("href", "target", "rel", "data-interception")) { return $false }
    }
    return $true
}

function Ensure-CoEResourceLinkPage {
    param([string]$SiteUrl, [string]$DisplayName, [string]$ResourceUrl, [object]$Connection)
    $uri = $null
    if (-not [uri]::TryCreate($ResourceUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne "https" -or $uri.UserInfo) {
        throw "The official resource link must be an absolute HTTPS URL."
    }
    $site = $null
    $connectedSite = [string](Get-CoEResourceProperty $Connection "Url")
    if (-not (Test-CoETabUrlEqual $connectedSite.TrimEnd('/') $SiteUrl.TrimEnd('/'))) {
        $web = Get-PnPWeb -Connection $Connection -ErrorAction Stop
        $connectedSite = [string](Get-CoEResourceProperty $web "Url")
    }
    if (-not [uri]::TryCreate($SiteUrl, [UriKind]::Absolute, [ref]$site) -or $site.Scheme -ne "https" -or
        $site.UserInfo -or $site.Query -or $site.Fragment -or
        -not (Test-CoETabUrlEqual $connectedSite.TrimEnd('/') $SiteUrl.TrimEnd('/'))) {
        throw "The resource page connection must match the verified private parent CoE site."
    }
    $name = Get-CoEResourcePageName $ResourceUrl
    $pendingTitle = Get-CoEResourcePagePendingTitle $ResourceUrl
    $pageUrl = $SiteUrl.TrimEnd('/') + "/SitePages/$name"
    $existing = @(Get-PnPPage -Connection $Connection -ErrorAction Stop | Where-Object Name -eq $name)
    if ($existing.Count -gt 1) { throw "Ambiguous resource page '$name'; no existing page was changed." }
    if ($existing.Count) {
        $page = Get-PnPPage -Identity $name -Connection $Connection -ErrorAction Stop
        if (-not $page -or $page.Name -cne $name -or
            ($page.PageTitle -cne $pendingTitle -and -not (Test-CoEResourcePage $page $DisplayName $ResourceUrl))) {
            throw "Resource page '$name' conflicts with the expected official link; the existing page was preserved."
        }
    } else {
        # A deterministic pending title identifies only our empty/draft page after an interrupted creation.
        Add-PnPPage -Name $name -Title $pendingTitle -LayoutType Article -Connection $Connection -ErrorAction Stop | Out-Null
        $page = Get-PnPPage -Identity $name -Connection $Connection -ErrorAction Stop
        if (-not $page -or $page.Name -cne $name -or $page.PageTitle -cne $pendingTitle -or @($page.Controls).Count) {
            throw "The new resource page identity or empty content could not be verified; no page was overwritten."
        }
    }
    $pageItem = Get-PnPFile -Url ([uri]$pageUrl).AbsolutePath -AsListItem -Connection $Connection -ErrorAction Stop
    $version = [string](Get-CoEResourceProperty (Get-CoEResourceProperty $pageItem "FieldValues") "_UIVersionString")
    if (-not $pageItem -or $version -notmatch '^\d+\.\d+$') {
        throw "The resource page's persisted version could not be verified; no page was overwritten."
    }
    if ($page.PageTitle -ceq $pendingTitle) {
        if ($version -notmatch '^0\.\d+$' -or
            (@($page.Controls).Count -and -not (Test-CoEResourcePage $page $DisplayName $ResourceUrl -AllowPendingTitle))) {
            throw "The pending resource page contains conflicting content or a published version; the existing page was preserved."
        }
    }
    if ($page.PageTitle -ceq $pendingTitle -and -not @($page.Controls).Count) {
        Add-PnPPageTextPart -Page $page -Text (Get-CoEResourcePageHtml $DisplayName $ResourceUrl) `
            -Connection $Connection -ErrorAction Stop | Out-Null
        $page = Get-PnPPage -Identity $name -Connection $Connection -ErrorAction Stop
        if ($page.Name -cne $name -or -not (Test-CoEResourcePage $page $DisplayName $ResourceUrl -AllowPendingTitle)) {
            throw "The resource page's saved official link could not be verified; no tab was created."
        }
    }
    if ($version -notmatch '^[1-9]\d*\.0$' -or $page.PageTitle -ceq $pendingTitle) {
        Set-PnPPage -Identity $name -Title $DisplayName -Publish -Connection $Connection -ErrorAction Stop | Out-Null
        $page = Get-PnPPage -Identity $name -Connection $Connection -ErrorAction Stop
        $pageItem = Get-PnPFile -Url ([uri]$pageUrl).AbsolutePath -AsListItem -Connection $Connection -ErrorAction Stop
    }
    $version = [string](Get-CoEResourceProperty $pageItem.FieldValues "_UIVersionString")
    $moderation = Get-CoEResourceProperty $pageItem.FieldValues "_ModerationStatus"
    if ($page.Name -cne $name -or -not (Test-CoEResourcePage $page $DisplayName $ResourceUrl) -or $version -notmatch '^[1-9]\d*\.0$' -or
        ($null -ne $moderation -and [int]$moderation -ne 0)) { throw "The resource page's published link/version could not be verified; no tab was created." }
    return $pageUrl
}

function Resolve-CoEResourceTabCapability {
    param([string]$Team, [string]$Channel, $Specification, [object[]]$InstalledApps,
        [string]$SiteUrl, [object]$SiteConnection, [object]$Connection)
    if ($Specification.Type -ne "WebSite") { return $Specification }
    $tabs = @(Get-CoEResourceTabs -Team $Team -Channel $Channel -DisplayName $Specification.DisplayName -Connection $Connection)
    $validLegacy = @($tabs | Where-Object { Test-CoEManagedTabTarget $_ $Specification "" })
    if ($validLegacy.Count) { return $Specification }
    $sharePointId = Get-CoETabAppIdForType "SharePointPageAndList"
    $pageUrl = "$($SiteUrl.TrimEnd('/'))/SitePages/$(Get-CoEResourcePageName $Specification.WebsiteUrl)"
    $contentUrl = "$($SiteUrl.TrimEnd('/'))/_layouts/15/teamslogon.aspx?spfx=true&dest=$([uri]::EscapeDataString($pageUrl))"
    $pageSpecification = [pscustomobject]@{
        DisplayName = $Specification.DisplayName; Type = "SharePointPageAndList"; TeamsAppId = $sharePointId
        TemplateAppId = $sharePointId; ContentUrl = $contentUrl; WebsiteUrl = $pageUrl
        OriginalUrl = $Specification.WebsiteUrl; ResourcePageUrl = $pageUrl; ProvisioningMode = "SharePointResourceLink"
    }
    $validResourcePage = @($tabs | Where-Object { Test-CoEManagedTabTarget $_ $pageSpecification "" })
    if (-not $validResourcePage.Count) {
        if (Find-CoEResourceAppInstallation $InstalledApps $Specification.TeamsAppId) { return $Specification }
        if (-not (Find-CoEResourceAppInstallation $InstalledApps $sharePointId)) {
            throw "Neither the legacy Website nor the supported SharePoint resource-page app is available in this Team. No app was installed or policy changed."
        }
    }
    Ensure-CoEResourceLinkPage -SiteUrl $SiteUrl -DisplayName $Specification.DisplayName `
        -ResourceUrl $Specification.WebsiteUrl -Connection $SiteConnection | Out-Null
    Write-Host "Resource-link capability: '$($Specification.DisplayName)' intentionally uses a supported SharePoint page; official destination: $($Specification.WebsiteUrl)"
    return $pageSpecification
}
