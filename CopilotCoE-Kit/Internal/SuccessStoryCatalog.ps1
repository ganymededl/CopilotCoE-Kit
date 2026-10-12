# Dot-source after AdoptionCatalogs.ps1. Importing this helper performs no deployment or authentication.
function Assert-CoEStoryVideoPath([string]$Path, [string]$Context) {
    $decoded = [uri]::UnescapeDataString($Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '^[A-Za-z][A-Za-z0-9+.-]*:' -or
        $decoded -match '^[\\/]|[\\?#\x00-\x1f]' -or
        @($decoded.Split('/') | Where-Object { $_ -in @("", ".", "..") }).Count) {
        throw "$Context : Video must be a relative asset path without traversal, query, fragment, or backslashes."
    }
    return $Path
}

function Test-CoEStoryMockVideo([string]$Url) {
    $decoded = [uri]::UnescapeDataString(($Url -split '[?#]', 2)[0])
    return $decoded -imatch '(^|[/\\])MOCK-[^/\\]*$'
}

function Assert-CoEStoryAudiences([string[]]$Audiences) {
    $clean = @(@($Audiences) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($clean.Count -eq 0) { throw "StoryAudiences must list at least one audience." }
    foreach ($name in $clean) {
        if ($name.Length -gt 255 -or $name -match '[\x00-\x1f<>]') { throw "StoryAudiences value '$name' is not a valid choice." }
    }
    return $clean
}

function ConvertTo-CoESuccessStorySeeds {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Seeds, [string]$StoriesFolderUrl = "",
        [hashtable]$StoryVideoUrls = @{}, [string[]]$Audiences = @("Faculty", "Staff", "Student"))
    $Audiences = @(Assert-CoEStoryAudiences $Audiences)
    if ($StoriesFolderUrl) {
        $null = Resolve-CoECatalogUrl $StoriesFolderUrl "StoriesFolderUrl"
        $folder = [uri]$StoriesFolderUrl
        if ($folder.Query -or $folder.Fragment) { throw "StoriesFolderUrl must not contain a query or fragment." }
    }
    if ($null -eq $StoryVideoUrls) { throw "StoryVideoUrls must be a hashtable, not null." }
    $videoUrls = @{}
    foreach ($key in $StoryVideoUrls.Keys) {
        if ($key -isnot [string]) { throw "StoryVideoUrls keys must be relative asset path strings." }
        $path = Assert-CoEStoryVideoPath $key "StoryVideoUrls key '$key'"
        $url = $StoryVideoUrls[$key]
        if ($url -isnot [string]) { throw "StoryVideoUrls '$key' must be an absolute HTTPS URL string." }
        $url = Resolve-CoECatalogUrl $url "StoryVideoUrls '$key'"
        if ((Test-CoEStoryMockVideo $path) -or (Test-CoEStoryMockVideo $url)) {
            throw "StoryVideoUrls '$key' references a MOCK- video; mock assets are not publishable story evidence."
        }
        $videoUrls[$path] = $url
    }
    $titles = @{}
    foreach ($row in $Seeds) {
        $context = "Success-story seed '$([string](Get-CoECatalogValue $row 'Title'))'"
        $values = @{}
        foreach ($name in @("Title", "Audience", "Task")) {
            $values[$name] = Assert-CoECatalogString $row $name $context -Required
        }
        foreach ($name in @("TimeSaved", "Video", "Status")) {
            $value = Get-CoECatalogValue $row $name
            $values[$name] = if ($null -eq $value) { "" } else { Assert-CoECatalogString $row $name $context }
        }
        $values.Title = $values.Title.Trim()
        $values.Audience = $values.Audience.Trim()
        if ($values.Title.Length -gt 255 -or $values.TimeSaved.Length -gt 255) {
            throw "$context : Title and TimeSaved must not exceed 255 characters."
        }
        if ($values.Task.Length -gt 63999 -or @($values.Values | Where-Object { $_ -match '[\x00-\x08\x0b\x0c\x0e-\x1f]' }).Count) {
            throw "$context : metadata exceeds the task field limit or contains unsupported control characters."
        }
        if ($values.Audience -notin $Audiences) {
            throw "$context : Audience must be one of: $($Audiences -join ', ') (StoryAudiences in Deployment-Settings.json)."
        }
        $values.Audience = $Audiences | Where-Object { $_ -eq $values.Audience } | Select-Object -First 1
        if ($values.Status -and $values.Status -notin @("Submitted", "Published", "Retired")) {
            throw "$context : Status must be Submitted, Published, or Retired; native approval controls publication."
        }
        if ($titles.ContainsKey($values.Title)) { throw "$context : duplicate title; no seeds were inserted." }
        $titles[$values.Title] = $true
        $video = ""
        if ($values.Video) {
            $path = Assert-CoEStoryVideoPath $values.Video $context
            if ($videoUrls.ContainsKey($path)) { $video = $videoUrls[$path] }
        }
        # Starter scenarios are not measured outcomes. Never resurrect their old invented savings.
        $timeSaved = if ($values.Title -imatch '^SAMPLE - ') { "" } else { $values.TimeSaved }
        $itemValues = @{ Title = $values.Title; Audience = $values.Audience; StoryTask = $values.Task
            TimeSaved = $timeSaved; StoryStatus = "Submitted"; "_ModerationStatus" = 2 }
        if ($video) { $itemValues.StoryVideo = New-CoECatalogUrlValue $video "Watch the video" }
        [pscustomobject]@{ Title = $values.Title; Values = $itemValues
            UnresolvedVideo = [bool]($values.Video -and -not $video) }
    }
}

function Sync-CoESuccessStoryCatalog {
    <#
    .SYNOPSIS
    Maintains an approval-only success-story catalog without overwriting customer stories.
    .NOTES
    Dot-source after SecurityPosture.ps1 and AdoptionCatalogs.ps1. ResolvedReviewers must come
    from the parent's preflight Resolve-CoECatalogReviewers call (an empty array is permitted).
    StoryVideoUrls maps relative seed paths to preflight-verified existing absolute HTTPS
    assets. Missing mappings omit videos; StoriesFolderUrl never fabricates a video link.
    All seeds are validated before mutation and inserted Submitted/pending, regardless of
    configured Status. SAMPLE titles receive no measured TimeSaved claim.
    Only a previously unmoderated list is migrated: authentic Published -> approved,
    Retired -> rejected, everything else (including old SAMPLE/MOCK stories) -> pending.
    Existing fields, content, status, assets, and moderated item versions are preserved.
    Native pending retirement edits retain SharePoint's last-approved-version behavior.
    Preserved counts seed titles already present; Migrated counts legacy moderation writes.
    Review warnings do not authorize removing old sample rows or editing customer evidence.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][string]$SiteUrl,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Seeds,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ResolvedReviewers,
        [string]$StoriesFolderUrl = "", [hashtable]$StoryVideoUrls = @{},
        [string[]]$Audiences = @("Faculty", "Staff", "Student"))
    $site = Assert-CoECatalogSiteUrl $SiteUrl
    $Audiences = @(Assert-CoEStoryAudiences $Audiences)
    $validated = @(ConvertTo-CoESuccessStorySeeds -Seeds $Seeds -StoriesFolderUrl $StoriesFolderUrl `
        -StoryVideoUrls $StoryVideoUrls -Audiences $Audiences)
    $reviewerIds = @{}
    foreach ($reviewer in $ResolvedReviewers) {
        $id = Get-CoECatalogValue $reviewer "Id"
        $login = Get-CoECatalogValue $reviewer "LoginName"
        if ($id -isnot [int] -or $id -le 0 -or $login -isnot [string] -or [string]::IsNullOrWhiteSpace($login)) {
            throw "Success-story reviewers must be preflight-resolved SharePoint principals with a positive integer Id and LoginName."
        }
        if ($reviewerIds.ContainsKey($id)) { throw "Success-story reviewers contain duplicate principal '$id'." }
        $reviewerIds[$id] = $true
    }
    $catalog = Get-CoECatalogList "Copilot Success Stories" "Lists/CopilotSuccessStories" $site $Connection
    $list = $catalog.List
    $wasModerated = -not $catalog.Created -and $list.EnableModeration
    Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $ResolvedReviewers -Connection $Connection
    $definitions = @{
        # Missing choices are added to an existing list below; existing choices are never removed.
        Audience = @{ Type = "Choice"; Title = "Audience"; Choices = $Audiences }
        StoryStatus = @{ Type = "Choice"; Title = "Status"; Choices = @("Submitted", "Published", "Retired")
            Default = "Submitted"; Presentation = @{ DefaultValue = "Submitted" } }
        StoryTask = @{ Type = "Note"; Title = "Task" }
        TimeSaved = @{ Type = "Text"; Title = "Time saved" }
        StoryVideo = @{ Type = "URL"; Title = "Video" }
    }
    Sync-CoECatalogFields $list $definitions $Connection | Out-Null
    foreach ($name in @("Audience", "StoryStatus")) {
        $field = Get-PnPField -List $list.Id -Identity $name -Connection $Connection -ErrorAction Stop
        if (-not $field) { throw "Success-story field '$name' could not be read back." }
        $null = Get-PnPProperty -ClientObject $field -Property Choices -Connection $Connection -ErrorAction Stop
        $choices = @($field.Choices)
        $merged = @($choices)
        foreach ($choice in $definitions[$name].Choices) {
            if ($choice -notin $merged) { $merged += $choice }
        }
        if ($merged.Count -ne $choices.Count) {
            Set-PnPField -List $list.Id -Identity $name -Values @{ Choices = [string[]]$merged } `
                -Connection $Connection -ErrorAction Stop -WarningAction Stop | Out-Null
        }
    }
    $existing = @(Get-PnPListItem -List $list.Id -Fields Title,Audience,StoryTask,TimeSaved,StoryVideo,StoryStatus,_ModerationStatus `
        -PageSize 500 -Connection $Connection -ErrorAction Stop)
    $byTitle = @{}
    $mockUrls = @{}
    $samples = @()
    $mockItems = @()
    $migration = @()
    foreach ($item in $existing) {
        $title = ([string]$item.FieldValues["Title"]).Trim()
        if ($title) {
            if ($byTitle.ContainsKey($title)) { throw "Success-story catalog has duplicate title '$title'; no item changes were made." }
            $byTitle[$title] = $item
        }
        $sample = $title -imatch '^SAMPLE - '
        if ($sample) { $samples += $item.Id }
        $url = Get-CoECatalogLaunchUrl $item.FieldValues["StoryVideo"]
        $mock = Test-CoEStoryMockVideo $url
        if ($mock) { $mockUrls[$url] = $true; $mockItems += $item.Id }
        if (-not $wasModerated) {
            $status = [string]$item.FieldValues["StoryStatus"]
            $moderation = if ($status -eq "Retired") { 1 }
                elseif ($status -eq "Published" -and $title -and -not $sample -and -not $mock) { 0 } else { 2 }
            $migration += [pscustomobject]@{ Id = $item.Id; Moderation = $moderation }
        }
    }
    if ($StoriesFolderUrl) {
        $knownMock = Resolve-CoECatalogUrl ($StoriesFolderUrl.TrimEnd("/") + "/Videos/MOCK-Success-Story-Lab-Rubric.mp4") "Legacy kit mock exclusion"
        $mockUrls[$knownMock] = $true
    }
    # Keep earlier mock exclusions when a pending customer edit replaces its URL; readers
    # can still see that item's last approved version until the replacement is approved.
    foreach ($oldView in @(Get-PnPView -List $list.Id -Includes ViewQuery -Connection $Connection -ErrorAction Stop |
        Where-Object Title -eq "Published")) {
        $oldQuery = [xml]("<Query>" + $oldView.ViewQuery + "</Query>")
        foreach ($node in @($oldQuery.SelectNodes("//Neq[FieldRef/@Name='StoryVideo']/Value[@Type='URL']"))) {
            if (Test-CoEStoryMockVideo $node.InnerText) { $mockUrls[$node.InnerText] = $true }
        }
    }
    $messages = @()
    if ($samples.Count) {
        $messages += "$($samples.Count) existing SAMPLE - story row(s) require customer review; retained without deleting or rewriting their content."
    }
    if ($mockItems.Count) {
        $messages += "$($mockItems.Count) story row(s) reference MOCK- video assets and are excluded from Published; review is required, assets and rows were not deleted."
    }
    $unresolved = @($validated | Where-Object UnresolvedVideo)
    if ($unresolved.Count) {
        $messages += "$($unresolved.Count) seed video(s) lack a preflight-verified asset mapping; their new drafts will have no video."
    }
    foreach ($message in $messages) { Write-Warning $message }
    $notRetired = '<Or><IsNull><FieldRef Name="StoryStatus"/></IsNull>' +
        '<Neq><FieldRef Name="StoryStatus"/><Value Type="Choice">Retired</Value></Neq></Or>'
    $publishedFilter = '<And><Eq><FieldRef Name="_ModerationStatus"/><Value Type="ModStat">0</Value></Eq>' +
        $notRetired + '</And>'
    # CAML has no NotContains operator. Exclude each known mock URL, including legacy rows,
    # without clearing any stored link or suppressing unrelated real videos.
    foreach ($url in @($mockUrls.Keys | Sort-Object)) {
        $notMock = '<Or><IsNull><FieldRef Name="StoryVideo"/></IsNull>' +
            '<Neq><FieldRef Name="StoryVideo"/><Value Type="URL">' +
            [Security.SecurityElement]::Escape($url) + '</Value></Neq></Or>'
        $publishedFilter = '<And>' + $publishedFilter + $notMock + '</And>'
    }
    $readerFields = @("Title", "Audience", "StoryTask", "TimeSaved", "StoryVideo")
    $order = '<OrderBy><FieldRef Name="Title" Ascending="TRUE"/></OrderBy>'
    $published = Sync-CoECatalogView $list "Published" $readerFields `
        ('<Where>' + $publishedFilter + '</Where>' + $order) $Connection -SetAsDefault
    $review = Sync-CoECatalogView $list "Review" @($readerFields + @("StoryStatus", "_ModerationStatus")) `
        ('<Where><And><Eq><FieldRef Name="_ModerationStatus"/><Value Type="ModStat">2</Value></Eq>' +
        $notRetired + '</And></Where>' + $order) $Connection
    $management = Sync-CoECatalogView $list "Manage all entries" @($readerFields + @("StoryStatus", "_ModerationStatus")) $order $Connection
    $readerUrl = Resolve-CoESharePointReturnedUrl $published.ServerRelativeUrl "Success-story reader view" $site
    $expected = @{}
    $migrated = 0
    # Quarantine drafts/retirements first; migration never approves starter or mock evidence.
    foreach ($entry in @($migration | Sort-Object { $_.Moderation -eq 0 })) {
        $updated = Set-PnPListItem -List $list.Id -Identity $entry.Id -Values @{ "_ModerationStatus" = $entry.Moderation } `
            -UpdateType SystemUpdate -Connection $Connection -ErrorAction Stop -WarningAction Stop
        if (-not $updated -or $updated.Id -ne $entry.Id) { throw "Success-story legacy item '$($entry.Id)' migration did not return its original ID." }
        $expected[[string]$entry.Id] = [pscustomobject]@{ Moderation = $entry.Moderation; Seed = $false }
        $migrated++
    }
    $added = 0
    $preserved = 0
    foreach ($seed in $validated) {
        if ($byTitle.ContainsKey($seed.Title)) { $preserved++; continue }
        $item = Add-PnPListItem -List $list.Id -Values $seed.Values -Connection $Connection -ErrorAction Stop -WarningAction Stop
        if (-not $item -or -not $item.Id) { throw "Success-story seed '$($seed.Title)' insertion did not return an item ID." }
        $expected[[string]$item.Id] = [pscustomobject]@{ Moderation = 2; Seed = $true }
        $added++
    }
    if ($expected.Count) {
        $confirmed = @(Get-PnPListItem -List $list.Id -Fields StoryStatus,_ModerationStatus -PageSize 500 `
            -Connection $Connection -ErrorAction Stop)
        foreach ($id in $expected.Keys) {
            $matches = @($confirmed | Where-Object { [string]$_.Id -eq $id })
            if ($matches.Count -ne 1 -or $null -eq $matches[0].FieldValues["_ModerationStatus"] -or
                [int]$matches[0].FieldValues["_ModerationStatus"] -ne $expected[$id].Moderation -or
                ($expected[$id].Seed -and $matches[0].FieldValues["StoryStatus"] -ne "Submitted")) {
                throw "Success-story item '$id' moderation/status could not be verified; do not report publication success."
            }
        }
    }
    $currentList = Get-PnPList -Identity $list.Id -Includes RootFolder,EnableVersioning,EnableModeration,DraftVersionVisibility `
        -Connection $Connection -ErrorAction Stop
    if (-not $currentList -or $currentList.Id -ne $list.Id -or -not $currentList.EnableVersioning -or
        -not $currentList.EnableModeration -or [string]$currentList.DraftVersionVisibility -ne "Approver") {
        throw "Success-story catalog final content approval settings could not be verified."
    }
    [pscustomobject]@{ List = $currentList; ListUrl = $catalog.ListUrl; ReaderViewUrl = $readerUrl
        Views = [pscustomobject]@{ Published = $published; Review = $review; Management = $management }
        Added = $added; Preserved = $preserved; Migrated = $migrated
        Diagnostics = [pscustomobject]@{ SampleItemIds = $samples; MockVideoItemIds = $mockItems
            UnresolvedSeedVideoCount = $unresolved.Count; Messages = $messages } }
}
