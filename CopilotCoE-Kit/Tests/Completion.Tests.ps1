# Offline regression tests: Windows PowerShell / installed Pester 3; deployment uses PowerShell 7.
Set-StrictMode -Version Latest
$kitRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $kitRoot "Internal\Complete-CopilotCoE.ps1"
$tokens = $null
$parseErrors = $null
$completionAst = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$source = $completionAst.Extent.Text

# Extract only definitions and selected orchestration blocks, never the tenant-connected entry point.
. (Join-Path $kitRoot "Internal\ResourceTabs.ps1")
. (Join-Path $kitRoot "Internal\AdoptionCatalogs.ps1")
. (Join-Path $kitRoot "Internal\GovernanceLinks.ps1")
. (Join-Path $kitRoot "Internal\OrganizationProfile.ps1")
. (Join-Path $kitRoot "Internal\HubExperience.ps1")
foreach ($name in @("Write-ManagedPage", "Test-ManagedPageWritten",
    "Sync-TopTenTab", "Get-CalendarLocalDate", "Get-OrgValue", "Resolve-OrgTokens",
    "Get-ManagedNavigationUrl", "Sync-GuideNavigation", "Sync-ChampionPageNavigation",
    "Escape-Html", "Add-CoECatalogPageView", "Add-CoEUpcomingSessionsWebPart", "Add-CoECalendarLinkTextPart",
    "Add-CoENoSessionsPlaceholder", "Remove-CoENoSessionsPlaceholder", "Confirm-OrgAssets",
    "ConvertTo-CoEStableBreadcrumbText", "Set-CoESectionStripPart", "Disable-CoEPageComments",
    "Convert-MarkdownInline", "Convert-GuideMarkdown", "Get-DocxParagraphs", "ConvertTo-CoEDocxRuns",
    "New-SimpleDocx", "Read-DocxText", "Add-CoEFileWithRetry")) {
    $definition = $completionAst.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Get-CompletionBlock([string]$Prefix) {
    $node = $completionAst.Find({ param($candidate)
        $candidate.Extent.Text.StartsWith($Prefix) -and
        ($candidate -is [System.Management.Automation.Language.ForEachStatementAst] -or
         $candidate -is [System.Management.Automation.Language.IfStatementAst])
    }, $true)
    if (-not $node) { throw "Missing completion block: $Prefix" }
    [scriptblock]::Create($node.Extent.Text)
}
function Get-CompletionStatements([string]$Prefix, [int]$Count) {
    # For a run of standalone statements (not wrapped in one if/foreach), stitch the first $Count
    # CommandAst matches for $Prefix back together in source order into one runnable scriptblock.
    $nodes = @($completionAst.FindAll({ param($candidate)
        $candidate -is [System.Management.Automation.Language.CommandAst] -and $candidate.Extent.Text.StartsWith($Prefix)
    }, $true) | Select-Object -First $Count)
    if ($nodes.Count -ne $Count) { throw "Expected $Count statement(s) starting with: $Prefix" }
    [scriptblock]::Create(($nodes | ForEach-Object { $_.Extent.Text }) -join "`n")
}
$orgUploadBlock = Get-CompletionBlock 'foreach ($orgFile in $orgFiles)'
$topUploadBlock = Get-CompletionBlock 'if ($existingHandout.Count -gt 0 -and $handoutLocal -and $ReplaceOrgAssets)'
$calendarSeedBlock = Get-CompletionBlock 'foreach ($event in $eventSeeds)'
$calendarCleanupBlock = Get-CompletionBlock 'foreach ($item in $existingEvents)'
$contentModeBlock = Get-CompletionBlock 'if ($ContentMode -eq "Demo") {'
$sampleNoticeModeBlock = Get-CompletionBlock 'if ($ContentMode -eq "Customer") {'
$guideDuplicateNoticeBlock = Get-CompletionBlock 'if ($configuredSampleNotice -and ('
$guideDemoOnlyMarkerBlock = Get-CompletionBlock 'if ($ContentMode -eq "Customer" -and $converted.Html -match'
$calendarViewBlock = Get-CompletionBlock 'if (@($calendarViews | Where-Object Title -eq "Upcoming approved sessions")'
$agentPageBlock = Get-CompletionStatements 'Add-CoECatalogPageView $site "CoE-Agent-Showcase"' 2
$longDisplayNameNavWarningBlock = Get-CompletionBlock 'if ($DisplayName.Length -gt 30) {
            # -f binds tighter than + ('

# Stand-ins fail closed even if a regression introduces an unmocked tenant call.
function Get-PnPPage { [CmdletBinding()] param($Identity, $Connection) throw "Unmocked page read" }
function Add-PnPPage { [CmdletBinding()] param($Name, $Title, $LayoutType, $Connection) throw "Unmocked page write" }
function Set-PnPPage { [CmdletBinding()] param($Identity, $Title, $HeaderType, $HeaderLayoutType, [switch]$Publish, $CommentsEnabled, $Connection) throw "Unmocked page write" }
function Set-PnPWeb { [CmdletBinding()] param($CommentsOnSitePagesDisabled, $HorizontalQuickLaunch, $MegaMenuEnabled, $Connection) throw "Unmocked web write" }
function Add-PnPPageTextPart { [CmdletBinding()] param($Page, $Text, $Order, $Section, $Column, $Connection) throw "Unmocked page write" }
function Set-PnPPageTextPart { [CmdletBinding()] param($Page, $InstanceId, $Text, $Connection) throw "Unmocked page write" }
function Add-PnPPageWebPart { [CmdletBinding()] param($Page, $DefaultWebPartType, $WebPartProperties, $Order, $Connection) throw "Unmocked catalog web part" }
function Get-PnPPageComponent { [CmdletBinding()] param($Page, $Connection) throw "Unmocked page component read" }
function Remove-PnPPageComponent { [CmdletBinding()] param($Page, $InstanceId, [switch]$Force, $Connection) throw "Unmocked component write" }
function Get-PnPFile { [CmdletBinding()] param($Url, [switch]$AsListItem, $Connection) throw "Unmocked file read" }
function Get-PnPTeamsTab { [CmdletBinding()] param($Team, $Channel, $Connection) throw "Unmocked tab read" }
function Add-PnPTeamsTab { [CmdletBinding()] param($Team, $Channel, $DisplayName, $Type, $ContentUrl, $EntityId, $WebSiteUrl, $Connection) throw "Unmocked tab write" }
function Remove-PnPTeamsTab { [CmdletBinding()] param($Team, $Channel, $Identity, [switch]$Force, $Connection) throw "Unmocked tab write" }
function Get-PnPNavigationNode { [CmdletBinding()] param($Location, $Connection) throw "Unmocked navigation read" }
function Add-PnPNavigationNode { [CmdletBinding()] param($Location, $Title, $Url, $Parent, $Connection) throw "Unmocked navigation write" }
function Remove-PnPNavigationNode { [CmdletBinding()] param($Identity, [switch]$Force, $Connection) throw "Unmocked navigation write" }
function Get-PnPProperty { [CmdletBinding()] param($ClientObject, $Property, $Connection) throw "Unmocked property read" }
function Get-PnPView { [CmdletBinding()] param($List, $Identity, $Includes, $Connection) throw "Unmocked view read" }
function Resolve-PnPFolder { [CmdletBinding()] param($SiteRelativePath, $Connection) throw "Unmocked folder write" }
function Get-PnPFolderItem { [CmdletBinding()] param($FolderSiteRelativeUrl, $ItemType, $Connection) throw "Unmocked folder read" }
function Add-PnPFile { [CmdletBinding()] param($Path, $Folder, $Connection) throw "Unmocked file write" }
function Remove-PnPFile { [CmdletBinding()] param($SiteRelativeUrl, [switch]$Recycle, [switch]$Force, $Connection) throw "Unmocked file delete" }
function Add-PnPListItem { [CmdletBinding()] param($List, $Values, $Connection) throw "Unmocked list write" }
function Remove-PnPListItem { [CmdletBinding()] param($List, $Identity, [switch]$Recycle, [switch]$Force, $Connection) throw "Unmocked list delete" }
function Set-PnPView { [CmdletBinding()] param($List, $Identity, $Values, $Connection) throw "Unmocked view update" }
function New-TestTab($Id, $Url, $Entity = "", $Name = "Top 10 to try") {
    [pscustomobject]@{ Id = $Id; DisplayName = $Name
        TeamsApp = [pscustomobject]@{ Id = "com.microsoft.teamspace.tab.file.staticviewer.powerpoint" }
        Configuration = [pscustomobject]@{ ContentUrl = $Url; EntityId = $Entity } }
}

Describe "Shared-channel file upload retry" {
    BeforeEach {
        $script:addAttempts = 0
        Mock Resolve-PnPFolder {}
        Mock Start-Sleep {}
        Mock Write-Warning {}
    }
    It "re-resolves the folder and retries a transient NotFound response" {
        Mock Add-PnPFile {
            $script:addAttempts++
            if ($script:addAttempts -eq 1) { throw 'The status code is "NotFound".' }
        }
        Add-CoEFileWithRetry -Path "draft.docx" -Folder "Shared Documents/02-Strategy" `
            -Connection "shared-site" -DelaySeconds 0
        Assert-MockCalled Resolve-PnPFolder -Times 2 -Exactly -Scope It
        Assert-MockCalled Add-PnPFile -Times 2 -Exactly -Scope It
        Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It
    }
    It "never retries a hard access failure" {
        Mock Add-PnPFile { throw "Access denied" }
        {
            Add-CoEFileWithRetry -Path "draft.docx" -Folder "Shared Documents/02-Strategy" `
                -Connection "shared-site" -DelaySeconds 0
        } | Should Throw "Access denied"
        Assert-MockCalled Add-PnPFile -Times 1 -Exactly -Scope It
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
    }
    It "stops after the bounded number of transient attempts" {
        Mock Add-PnPFile { throw "404 Not Found" }
        {
            Add-CoEFileWithRetry -Path "draft.docx" -Folder "Shared Documents/02-Strategy" `
                -Connection "shared-site" -MaxAttempts 3 -DelaySeconds 0
        } | Should Throw "404 Not Found"
        Assert-MockCalled Add-PnPFile -Times 3 -Exactly -Scope It
        Assert-MockCalled Resolve-PnPFolder -Times 3 -Exactly -Scope It
        Assert-MockCalled Start-Sleep -Times 2 -Exactly -Scope It
    }
}

Describe "Managed page completion and preservation" {
    BeforeEach {
        $script:ReplaceManagedPages = $false
        $script:writtenManagedPages = @()
        $script:hubLinks = @()
        $script:reviewedPages = @()
        $script:SiteUrl = "https://example.sharepoint.com/sites/CoE"
        $script:site = [pscustomobject]@{ Url = "https://example.sharepoint.com/sites/CoE" }
        $script:pages = @([pscustomobject]@{ Name = "Existing.aspx"; Controls = @([pscustomobject]@{ InstanceId = "custom" }) })
        $script:auditFolder = $PSScriptRoot
        $script:runId = "offline"
        Mock Write-Host {}
        Mock Get-PnPPage {
            if ($Identity) { $script:pages | Where-Object { $_.Name -eq ($Identity -replace '\.aspx$', '') + ".aspx" } }
            else { $script:pages }
        }
        Mock Add-PnPPage {
            $page = [pscustomobject]@{ Name = "$Name.aspx"; Controls = @() }
            $script:pages += $page
            $page
        }
        Mock Set-PnPPage {}
        Mock Add-PnPPageTextPart {}
        Mock Remove-PnPPageComponent {}
        Mock Get-PnPFile { [pscustomobject]@{ FieldValues = @{ Title = "Customized" } } }
        Mock Set-Content {}
    }
    It "resumes past existing pages and creates missing pages without changing existing content" {
        $kept = Write-ManagedPage $site "Existing" "Kit title" "<h2>Kit title</h2><p>Draft</p>"
        $created = Write-ManagedPage $site "Missing" "New title" "<h2>New title</h2><p>Draft</p>"
        $kept.Name | Should Be "Existing.aspx"
        $created.Name | Should Be "Missing.aspx"
        Assert-MockCalled Add-PnPPage -Times 1 -Exactly -Scope It
        Assert-MockCalled Remove-PnPPageComponent -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-PnPPage -Times 0 -Exactly -Scope It -ParameterFilter { $Identity -eq "Existing" }
        Assert-MockCalled Add-PnPPageTextPart -Times 0 -Exactly -Scope It -ParameterFilter { $Page -eq "Existing" }
        (Test-ManagedPageWritten $site "Existing") | Should Be $false
        (Test-ManagedPageWritten $site "Missing") | Should Be $true
    }
    It "backs up and replaces controls only with explicit page replacement authorization" {
        $script:ReplaceManagedPages = $true
        Write-ManagedPage $site "Existing" "Kit title" "<p>Draft</p>" | Out-Null
        Assert-MockCalled Set-Content -Times 1 -Exactly -Scope It
        Assert-MockCalled Remove-PnPPageComponent -Times 1 -Exactly -Scope It
        Assert-MockCalled Add-PnPPageTextPart -Times 1 -Exactly -Scope It
    }
    It "fails on ambiguous duplicate page identities without mutations" {
        $script:pages += $script:pages[0]
        { Write-ManagedPage $site "Existing" "Title" "<p>Draft</p>" } | Should Throw
        Assert-MockCalled Add-PnPPageTextPart -Times 0 -Exactly -Scope It
    }
    It "scopes written page tracking to each site's URL" {
        $script:writtenManagedPages = @("https://elsewhere.sharepoint.com/sites/CoE|Existing")
        (Test-ManagedPageWritten $site "Existing") | Should Be $false
    }
    It "tracks and backs up pages without relying on a connection Url property" {
        $script:site = [pscustomobject]@{}
        $script:ReplaceManagedPages = $true
        Write-ManagedPage $site "Existing" "Updated title" "<p>Updated</p>" | Out-Null
        (Test-ManagedPageWritten $site "Existing") | Should Be $true
        Assert-MockCalled Set-Content -Times 1 -Exactly -Scope It -ParameterFilter {
            $Path -like "*-sites-CoE-Existing-before.json"
        }
    }
    It "adds a direct Home link to a guide without a mega-menu section" {
        Write-ManagedPage $site "Missing" "New guide" "<p>Guide content</p>" | Out-Null
        Assert-MockCalled Add-PnPPageTextPart -Times 1 -Exactly -Scope It -ParameterFilter {
            $Text -match 'SitePages/TrainingHome.aspx' -and $Text -match 'Guide content'
        }
    }

    It "centralizes the preservation guard inside Add-CoECatalogPageView instead of repeating it per call site" {
        # This guard used to be duplicated at every call site (if (Test-ManagedPageWritten $site "X") { Add-CoECatalogPageView ... }).
        # That duplication is exactly what let a page preserved before its catalog link was ever added stay
        # unrepaired forever: the call site's own copy of the guard skipped the call before the function's
        # internal (correct, self-healing) check ever got a chance to run. The guard must live only inside the
        # shared function now, and call sites must not wrap it in their own Test-ManagedPageWritten check.
        $functionDefinition = $completionAst.Find({ param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Add-CoECatalogPageView"
        }, $true).Extent.Text
        $functionDefinition | Should Match 'Test-ManagedPageWritten \$SiteConnection \$PageName'
        foreach ($page in @("CoE-Success-Stories", "CoE-Training-and-Enablement", "CoE-Agent-Showcase", "Guide-Prompt-Library")) {
            $source.Contains('if (Test-ManagedPageWritten $site "' + $page + '")') | Should Be $false
        }
        $source | Should Match 'Add-CoECatalogPageView \$site "CoE-Success-Stories"'
        $source | Should Match 'Add-CoECatalogPageView \$site "CoE-Training-and-Enablement"'
        $source | Should Match 'Add-CoECatalogPageView \$site "CoE-Agent-Showcase"'
        $source | Should Match 'Add-CoECatalogPageView \$site "Guide-Prompt-Library"'
    }
}

Describe "Captured section strip detection and refresh" {
    It "relabels the vendor-page breadcrumb loop by calling Set-CoESectionStripPart, not an existence check" {
        $repair = $completionAst.Find({ param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Repair-CoEHubPages"
        }, $true).Extent.Text
        $repair | Should Match 'Set-CoESectionStripPart -SiteConnection \$SiteConnection -PageName \$page\.Name -StripHtml'
        $repair | Should Not Match 'Test-CoESectionStripExists'
        # Regression guard for the automatic-variable collision caught alongside $matches: $args is
        # PowerShell's own automatic variable, the same risk class, now renamed in both places it appeared.
        $repair | Should Not Match '\$args\s*='
        $resourceTabs = Get-Content (Join-Path $kitRoot "Internal\ResourceTabs.ps1") -Raw
        $resourceTabs | Should Not Match '\$args\s*='
    }
    It "adds a breadcrumb when none exists" {
        $script:liveControls = @()
        $script:capturedText = $null
        Mock Get-PnPPage { [pscustomobject]@{ Controls = @($script:liveControls) } }
        Mock Add-PnPPageTextPart {
            $script:capturedText = $Text
            $script:liveControls = @($script:liveControls) + [pscustomobject]@{ InstanceId = [guid]::NewGuid(); Text = $Text }
        }
        Mock Remove-PnPPageComponent { throw "should not be called; nothing to remove" }
        Mock Set-PnPPage { }
        Set-CoESectionStripPart -SiteConnection "offline" -PageName "Technical Readiness.aspx" `
            -StripHtml '<p><a href="https://contoso.sharepoint.com/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Training</p>'
        $script:capturedText | Should Match "Home</a> / Training"
        @($script:liveControls).Count | Should Be 1
    }
    It "does not touch a page whose breadcrumb already matches exactly" {
        $script:existingControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = '<p><a href="https://contoso.sharepoint.com/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Training</p>' }
        Mock Get-PnPPage { [pscustomobject]@{ Controls = @($script:existingControl) } }
        Mock Add-PnPPageTextPart { throw "should not be called" }
        Mock Remove-PnPPageComponent { throw "should not be called" }
        Mock Set-PnPPage { throw "should not be called" }
        { Set-CoESectionStripPart -SiteConnection "offline" -PageName "Technical Readiness.aspx" `
            -StripHtml '<p><a href="https://contoso.sharepoint.com/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Training</p>' } | Should Not Throw
    }
    It "replaces a stale breadcrumb from an earlier kit version instead of leaving the old label forever" {
        # Regression test: an earlier kit version's breadcrumb used the internal section Key ("Help &
        # community") instead of the menu's shortened Title ("Help"). A plain existence check ("is there
        # already a breadcrumb-shaped control") used to treat this as already done and never touch it again,
        # even under -RepairCapturedPages, on Adoption, Roles, Technical Readiness and Microsoft Mechanics.
        $script:staleControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = '<p><a href="https://contoso.sharepoint.com/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Help &amp; community</p>' }
        $script:liveControls = @($script:staleControl)
        $script:capturedText = $null
        Mock Get-PnPPage { [pscustomobject]@{ Controls = @($script:liveControls) } }
        Mock Add-PnPPageTextPart {
            $script:capturedText = $Text
            $script:liveControls = @($script:liveControls) + [pscustomobject]@{ InstanceId = [guid]::NewGuid(); Text = $Text }
        }
        Mock Remove-PnPPageComponent { $script:liveControls = @($script:liveControls | Where-Object { $_.InstanceId -ne $InstanceId }) }
        Mock Set-PnPPage { }
        Set-CoESectionStripPart -SiteConnection "offline" -PageName "CoE-Service-Catalog-and-Support.aspx" `
            -StripHtml '<p><a href="https://contoso.sharepoint.com/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Help</p>'
        $script:capturedText | Should Match "Home</a> / Help<"
        @($script:liveControls).Count | Should Be 1
        $script:liveControls[0].Text | Should Match "Home</a> / Help<"
    }
    It "reloads the page before removing a stale breadcrumb, so the stale pre-add canvas never wipes the just-added one" {
        $script:staleControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = '<p><a href="https://contoso.sharepoint.com/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Help &amp; community</p>' }
        $script:liveControls = @($script:staleControl)
        $script:removalPageSnapshots = [System.Collections.Generic.List[object]]::new()
        Mock Get-PnPPage { [pscustomobject]@{ Controls = @($script:liveControls) } }
        Mock Add-PnPPageTextPart {
            $newControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid(); Text = $Text }
            $script:liveControls = @($script:liveControls) + $newControl
        }
        Mock Remove-PnPPageComponent {
            $script:removalPageSnapshots.Add(@($Page.Controls))
            $script:liveControls = @($script:liveControls | Where-Object { $_.InstanceId -ne $InstanceId })
        }
        Mock Set-PnPPage { }
        Set-CoESectionStripPart -SiteConnection "offline" -PageName "CoE-Service-Catalog-and-Support.aspx" `
            -StripHtml '<p><a href="https://contoso.sharepoint.com/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Help</p>'
        $script:removalPageSnapshots.Count | Should Be 1
        ((@($script:removalPageSnapshots[0]) | ForEach-Object Text) -join "|") | Should Match "Home</a> / Help<"
    }
    It "cleans up a leftover duplicate breadcrumb from a previously interrupted run" {
        $script:currentControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = '<p><a href="https://contoso.sharepoint.com/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Help</p>' }
        $script:staleControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = '<p><a href="https://contoso.sharepoint.com/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Help &amp; community</p>' }
        $script:liveControls = @($script:currentControl, $script:staleControl)
        $script:removedIds = [System.Collections.Generic.List[object]]::new()
        Mock Get-PnPPage { [pscustomobject]@{ Controls = @($script:liveControls) } }
        Mock Add-PnPPageTextPart { throw "should not be called; a current block already exists" }
        Mock Remove-PnPPageComponent {
            $script:removedIds.Add($InstanceId)
            $script:liveControls = @($script:liveControls | Where-Object { $_.InstanceId -ne $InstanceId })
        }
        Mock Set-PnPPage { }
        Set-CoESectionStripPart -SiteConnection "offline" -PageName "CoE-Service-Catalog-and-Support.aspx" `
            -StripHtml '<p><a href="https://contoso.sharepoint.com/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Help</p>'
        $script:removedIds | Should Be $script:staleControl.InstanceId
        @($script:liveControls).Count | Should Be 1
        $script:liveControls[0].InstanceId | Should Be $script:currentControl.InstanceId
    }
    # Regression tests for a live-only failure: SharePoint's actual save pipeline for this inline text web
    # part neither preserves the supplied outer <p>...</p> wrapper (it stores a bare inline fragment instead)
    # nor keeps a same-site absolute href (it rewrites https://host/sites/X/Y.aspx down to /sites/X/Y.aspx).
    # None of the mocks above modeled this - they all echo back exactly what was supplied - so none of them
    # could have caught it. Confirmed live on Copilot-on-Microsoft-Mechanics.aspx: three separate repair runs
    # each added another control because an exact comparison against the originally supplied markup never
    # matched what SharePoint actually stored, even though every add itself succeeded.
    It "treats a breadcrumb SharePoint re-saved without the <p> wrapper and with a relative href as already current" {
        $script:existingControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = '<a href="/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Training' }
        Mock Get-PnPPage { [pscustomobject]@{ Controls = @($script:existingControl) } }
        Mock Add-PnPPageTextPart { throw "should not be called" }
        Mock Remove-PnPPageComponent { throw "should not be called" }
        Mock Set-PnPPage { throw "should not be called" }
        { Set-CoESectionStripPart -SiteConnection "offline" -PageName "Technical Readiness.aspx" `
            -StripHtml '<p><a href="https://contoso.sharepoint.com/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Training</p>' } | Should Not Throw
    }
    It "finds a freshly added breadcrumb even though SharePoint stripped its <p> wrapper and relativized its href on save" {
        $script:liveControls = @()
        Mock Get-PnPPage { [pscustomobject]@{ Controls = @($script:liveControls) } }
        Mock Add-PnPPageTextPart {
            # Models SharePoint's real save behavior, not a literal echo of $Text: drops the <p> wrapper and
            # rewrites the same-site absolute href down to a server-relative one.
            $saved = [regex]::Replace($Text, '^<p>(.*)</p>$', '$1')
            $saved = [regex]::Replace($saved, 'href="https?://[^/"]+(/[^"]*)"', 'href="$1"')
            $script:liveControls = @($script:liveControls) + [pscustomobject]@{ InstanceId = [guid]::NewGuid(); Text = $saved }
        }
        Mock Remove-PnPPageComponent { throw "should not be called; nothing to remove" }
        Mock Set-PnPPage { }
        { Set-CoESectionStripPart -SiteConnection "offline" -PageName "Technical Readiness.aspx" `
            -StripHtml '<p><a href="https://contoso.sharepoint.com/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Training</p>' } | Should Not Throw
        @($script:liveControls).Count | Should Be 1
    }
    It "cleans up every duplicate left behind by earlier runs that could not recognize their own re-saved breadcrumb" {
        $script:liveControls = @(
            [pscustomobject]@{ InstanceId = [guid]::NewGuid(); Text = '<a href="/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Training' },
            [pscustomobject]@{ InstanceId = [guid]::NewGuid(); Text = '<a href="/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Training' },
            [pscustomobject]@{ InstanceId = [guid]::NewGuid(); Text = '<a href="/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Training' }
        )
        Mock Get-PnPPage { [pscustomobject]@{ Controls = @($script:liveControls) } }
        Mock Add-PnPPageTextPart { throw "should not be called; already-current matches exist" }
        Mock Remove-PnPPageComponent { $script:liveControls = @($script:liveControls | Where-Object { $_.InstanceId -ne $InstanceId }) }
        Mock Set-PnPPage { }
        Set-CoESectionStripPart -SiteConnection "offline" -PageName "Technical Readiness.aspx" `
            -StripHtml '<p><a href="https://contoso.sharepoint.com/sites/CoE/SitePages/TrainingHome.aspx">Home</a> / Training</p>'
        @($script:liveControls).Count | Should Be 1
    }
}

Describe "Home section and linked cards" {
    BeforeEach {
        $script:welcomeFn = $completionAst.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Set-CoEHomeWelcomeText"
        }, $true)
        . ([scriptblock]::Create($script:welcomeFn.Extent.Text))
    }
    It "relabels the vendor Resources Quick Links instead of clearing Home's sections" {
        $repair = $completionAst.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Repair-CoEHubPages"
        }, $true).Extent.Text
        $repair | Should Not Match '\$homePage\.Sections\.Clear\(\)'
        # Remove-PnPPageComponent is still used, but only to replace the vendor's own Events web part (which
        # cannot express the "approved sessions only" filter), not to clear the whole page.
        $repair | Should Match 'dataProviderId":"Event"'
        $repair | Should Match 'Convert-CoEQuickLinksCanvas \$homeCanvas \$SiteUrl "Resources" "Copilot tools"'
        $repair | Should Match "missing its Hero web part"
        $checker = Get-Content (Join-Path $kitRoot "Test-CoEInstall.ps1") -Raw
        $checker | Should Match "keeps the template's Hero web part"
        $checker | Should Match 'Copilot tools Quick Links replaces the vendor Resources box'
    }
    It "reloads the page before removing, so the stale pre-add canvas never wipes the just-added block" {
        # Regression test for the most likely live-install failure in 3.8.2: Remove-PnPPageComponent saves
        # whatever canvas state its -Page object currently holds. Passing the object loaded at the very top
        # of this function - from before Add-PnPPageTextPart ran - would silently drop the newly added
        # control the moment the remove step saves, because that stale snapshot never knew it existed. This
        # mock models the real cmdlet behavior state-fully (Get-PnPPage always reflects whatever Add/Remove
        # have actually done so far, the same as the live cmdlets do) instead of returning the same static
        # object on every call, which is what let this bug through 3.8.1/3.8.2's mocked tests undetected.
        $script:vendorControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = "<h4>Meet your Copilot champions</h4><p>Champions help colleagues get the most from Copilot and Microsoft 365, with peer-to-peer learning. <a href='x'>Find your department champion</a>.</p>" }
        $script:liveControls = @($script:vendorControl)
        $script:removalPageSnapshots = [System.Collections.Generic.List[object]]::new()
        Mock Get-PnPPage { [pscustomobject]@{ Controls = @($script:liveControls) } }
        Mock Add-PnPPageTextPart {
            $newControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid(); Text = $Text }
            $script:liveControls = @($script:liveControls) + $newControl
        }
        Mock Remove-PnPPageComponent {
            $script:removalPageSnapshots.Add(@($Page.Controls))
            $script:liveControls = @($script:liveControls | Where-Object { $_.InstanceId -ne $InstanceId })
        }
        Mock Set-PnPPage { }
        Set-CoEHomeWelcomeText -SiteConnection "offline" -PageName "TrainingHome" -SiteUrl "https://contoso.sharepoint.com/sites/CoE" `
            -OrgName "Contoso" -OrgNoun "organization" -SampleNotice "DEMO SITE - synthetic data only."
        $script:removalPageSnapshots.Count | Should Be 1
        # The page object actually passed to Remove-PnPPageComponent must already include the freshly added
        # control - proving it was reloaded after the add, not the stale pre-add snapshot that never knew
        # about it (a stale snapshot here would contain only the vendor control, never the new text).
        ((@($script:removalPageSnapshots[0]) | ForEach-Object Text) -join "|") | Should Match "your organization's hub"
        # Exactly one control remains: the vendor's original was removed, the new one kept.
        @($script:liveControls).Count | Should Be 1
        $script:liveControls[0].Text | Should Match "your organization's hub"
    }
    It "cleans up a leftover duplicate from a previously interrupted run instead of leaving it forever" {
        # Regression test: if an earlier run's Add succeeded but its Remove failed (partway failure, or the
        # bug above before it was fixed), Home is left with two matching controls - the vendor's original
        # AND an already-current new one. The next run must still finish the cleanup: it must not stop just
        # because it finds a current block first, the way a naive "take the first match" design would.
        $script:currentControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = "<h2>Welcome to the Contoso Copilot Center of Excellence</h2><p><em>DEMO SITE - synthetic data only.</em></p>" +
                "<p>This site is your organization's hub for adopting Microsoft Copilot responsibly: training, tools, governance and support in one place.</p>" +
                "<p><a href='https://contoso.sharepoint.com/sites/CoE/SitePages/Meet-your-Champions.aspx'>Meet your department champions</a> for peer-to-peer help in your department.</p>" }
        $script:leftoverVendorControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = "<h4>Meet your Copilot champions</h4><p>Champions help colleagues get the most from Copilot and Microsoft 365, with peer-to-peer learning. <a href='x'>Find your department champion</a>.</p>" }
        $script:liveControls = @($script:currentControl, $script:leftoverVendorControl)
        $script:removedIds = [System.Collections.Generic.List[object]]::new()
        Mock Get-PnPPage { [pscustomobject]@{ Controls = @($script:liveControls) } }
        Mock Add-PnPPageTextPart { throw "should not be called; a current block already exists" }
        Mock Remove-PnPPageComponent {
            $script:removedIds.Add($InstanceId)
            $script:liveControls = @($script:liveControls | Where-Object { $_.InstanceId -ne $InstanceId })
        }
        Mock Set-PnPPage { }
        Set-CoEHomeWelcomeText -SiteConnection "offline" -PageName "TrainingHome" -SiteUrl "https://contoso.sharepoint.com/sites/CoE" `
            -OrgName "Contoso" -OrgNoun "organization" -SampleNotice "DEMO SITE - synthetic data only."
        $script:removedIds | Should Be $script:leftoverVendorControl.InstanceId
        @($script:liveControls).Count | Should Be 1
        $script:liveControls[0].InstanceId | Should Be $script:currentControl.InstanceId
    }
    It "treats an HTML-entity-encoded apostrophe in the stored text as already current, not stale" {
        # Regression test: SharePoint can store the control's Text with the apostrophe HTML-entity-encoded
        # (for example &#39;) rather than a literal straight apostrophe. Comparing the raw, still-encoded
        # text against a literal "'" would never match, forcing an unnecessary rewrite (and, before the
        # dedup fix above, a growing pile of duplicates) on every single run against a real SharePoint page -
        # even though offline tests using plain in-memory strings would never reveal this, since nothing
        # HTML-encodes the fixture text to begin with.
        $script:encodedControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = "<h2>Welcome to the Contoso Copilot Center of Excellence</h2><p><em>DEMO SITE - synthetic data only.</em></p>" +
                "<p>This site is your organization&#39;s hub for adopting Microsoft Copilot responsibly: training, tools, governance and support in one place.</p>" +
                "<p><a href='https://contoso.sharepoint.com/sites/CoE/SitePages/Meet-your-Champions.aspx'>Meet your department champions</a> for peer-to-peer help in your department.</p>" }
        Mock Get-PnPPage { [pscustomobject]@{ Controls = @($script:encodedControl) } }
        Mock Remove-PnPPageComponent { throw "should not be called; the entity-encoded text is already current" }
        Mock Add-PnPPageTextPart { throw "should not be called; the entity-encoded text is already current" }
        Mock Set-PnPPage { throw "should not be called; the entity-encoded text is already current" }
        { Set-CoEHomeWelcomeText -SiteConnection "offline" -PageName "TrainingHome" -SiteUrl "https://contoso.sharepoint.com/sites/CoE" `
            -OrgName "Contoso" -OrgNoun "organization" -SampleNotice "DEMO SITE - synthetic data only." } | Should Not Throw
    }
    It "replaces the vendor welcome placeholder with text that actually clears the live placeholder check, landing in the vendor's own Section 4/Column 2" {
        # Regression test for a self-contradiction caught live on a GCC install: Set-CoEHomeWelcomeText's own
        # replacement text must not reintroduce whatever marker phrase Test-CoEInstall.ps1 (or this function's
        # own idempotency check) searches for to confirm the vendor placeholder is gone. Both sides are read
        # from the real source so a future edit to either one that reintroduces the collision fails here,
        # without needing a live site to catch it. Also guards against a confirmed live regression: an earlier
        # hardcoded target of Section 1/Column 1 left Section 4's own second column (the vendor's original
        # "Meet Your Copilot Champions" slot, next to the "Meet a Champion" button Repair-CoEHubPages adds in
        # Column 1) completely empty - the replacement must land in that same Section 4/Column 2 instead.
        $welcomeFn = $script:welcomeFn
        $welcomeFn | Should Not BeNullOrEmpty
        $placeholderMatch = [regex]::Match($welcomeFn.Extent.Text, '\$vendorMarker\s*=\s*"([^"]+)"')
        $placeholderMatch.Success | Should Be $true
        $placeholderMarker = $placeholderMatch.Groups[1].Value

        foreach ($orgNoun in @("organization", "university", "medical center", "agency")) {
            $script:vendorControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
                Text = "<h4>Meet your Copilot champions</h4><p>$placeholderMarker, with peer-to-peer learning. <a href='x'>Find your department champion</a>.</p>" }
            $script:liveControls = @($script:vendorControl)
            $script:capturedText = $null
            $script:capturedArgs = $null
            Mock Get-PnPPage { [pscustomobject]@{ Controls = @($script:liveControls) } }
            Mock Add-PnPPageTextPart {
                $script:capturedText = $Text; $script:capturedArgs = @{ Section = $Section; Column = $Column; Order = $Order }
                $newControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid(); Text = $Text }
                $script:liveControls = @($script:liveControls) + $newControl
            }
            Mock Remove-PnPPageComponent { $script:liveControls = @($script:liveControls | Where-Object { $_.InstanceId -ne $InstanceId }) }
            Mock Set-PnPPage { }
            Set-CoEHomeWelcomeText -SiteConnection "offline" -PageName "TrainingHome" -SiteUrl "https://contoso.sharepoint.com/sites/CoE" `
                -OrgName "Contoso" -OrgNoun $orgNoun -SampleNotice "DEMO SITE - synthetic data only."
            $script:capturedText | Should Match ([regex]::Escape("This site is your $orgNoun's hub"))
            $script:capturedText | Should Not Match ([regex]::Escape($placeholderMarker))
            $script:capturedText | Should Match ([regex]::Escape("DEMO SITE - synthetic data only."))
            $script:capturedArgs.Section | Should Be 4
            $script:capturedArgs.Column | Should Be 2
            @($script:liveControls).Count | Should Be 1
        }

        $checker = Get-Content (Join-Path $kitRoot "Test-CoEInstall.ps1") -Raw
        $checkerMarkerMatch = [regex]::Match($checker, 'notmatch \[regex\]::Escape\("([^"]+)"\)\s*-and\s*\n\s*\(-not \$expectedSampleNotice')
        $checkerMarkerMatch.Success | Should Be $true
        $checkerMarkerMatch.Groups[1].Value | Should Be $placeholderMarker
    }
    It "upgrades a 3.8-or-earlier welcome block that already replaced the vendor marker, instead of leaving it forever" {
        # Regression test for the "done rerunning fixes it" claim caught false on a live gov validation site:
        # once a site has been processed by any version of Set-CoEHomeWelcomeText, the vendor marker this
        # function looks for is gone for good, so without a second detection path, no later version of this
        # function can ever touch that site again - it would keep the old "This site is <noun>'s hub" grammar
        # and the old bottom-of-page position forever, no matter how many times -RepairCapturedPages reruns.
        $script:legacyControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = "<h2>Welcome to the Contoso Copilot Center of Excellence</h2><p><em>Old notice.</em></p>" +
                "<p>This site is organization's hub for adopting Microsoft Copilot responsibly: training, tools, governance and support in one place.</p>" +
                "<p><a href='https://contoso.sharepoint.com/sites/CoE/SitePages/Meet-your-Champions.aspx'>Meet your department champions</a> for peer-to-peer help in your department.</p>" }
        $script:liveControls = @($script:legacyControl)
        $script:capturedText = $null
        $script:capturedArgs = $null
        Mock Get-PnPPage { [pscustomobject]@{ Controls = @($script:liveControls) } }
        Mock Add-PnPPageTextPart {
            $script:capturedText = $Text; $script:capturedArgs = @{ Section = $Section; Column = $Column }
            $newControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid(); Text = $Text }
            $script:liveControls = @($script:liveControls) + $newControl
        }
        Mock Remove-PnPPageComponent { $script:liveControls = @($script:liveControls | Where-Object { $_.InstanceId -ne $InstanceId }) }
        Mock Set-PnPPage { }
        Set-CoEHomeWelcomeText -SiteConnection "offline" -PageName "TrainingHome" -SiteUrl "https://contoso.sharepoint.com/sites/CoE" `
            -OrgName "Contoso" -OrgNoun "organization" -SampleNotice "DEMO SITE - synthetic data only."
        $script:capturedText | Should Match ([regex]::Escape("This site is your organization's hub"))
        $script:capturedArgs.Section | Should Be 4
        $script:capturedArgs.Column | Should Be 2
        @($script:liveControls).Count | Should Be 1
    }
    It "does not touch a page whose welcome block already has the current grammar, notice and position" {
        # A site fully upgraded by this exact version must be left alone on a later rerun - otherwise this
        # function would never reach a fixed point and would keep touching Home on every single run.
        $script:currentControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = "<h2>Welcome to the Contoso Copilot Center of Excellence</h2><p><em>DEMO SITE - synthetic data only.</em></p>" +
                "<p>This site is your organization's hub for adopting Microsoft Copilot responsibly: training, tools, governance and support in one place.</p>" +
                "<p><a href='https://contoso.sharepoint.com/sites/CoE/SitePages/Meet-your-Champions.aspx'>Meet your department champions</a> for peer-to-peer help in your department.</p>" }
        Mock Get-PnPPage { [pscustomobject]@{ Controls = @($script:currentControl) } }
        Mock Remove-PnPPageComponent { throw "should not be called" }
        Mock Add-PnPPageTextPart { throw "should not be called" }
        Mock Set-PnPPage { throw "should not be called" }
        { Set-CoEHomeWelcomeText -SiteConnection "offline" -PageName "TrainingHome" -SiteUrl "https://contoso.sharepoint.com/sites/CoE" `
            -OrgName "Contoso" -OrgNoun "organization" -SampleNotice "DEMO SITE - synthetic data only." } | Should Not Throw
    }
    It "refreshes a previously-upgraded block when the configured SampleNotice has since changed (regression: stale baked-in notice on a validation site)" {
        # Regression test for a live failure: a validation/test site processed by an earlier kit version had
        # its own, older SampleNotice baked into the welcome block ("VALIDATION TEST SITE built by Microsoft
        # engineering..."). Deployment-Settings.json's SampleNotice was later updated. A -RepairCapturedPages
        # rerun must pick up the new notice rather than leaving the old one in place forever.
        $script:staleNoticeControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = "<h2>Welcome to the Contoso Copilot Center of Excellence</h2>" +
                "<p><em>VALIDATION TEST SITE built by Microsoft engineering to confirm Copilot CoE kit 3.7 government behavior. Not an agency site; not official content or policy.</em></p>" +
                "<p>This site is your organization's hub for adopting Microsoft Copilot responsibly: training, tools, governance and support in one place.</p>" +
                "<p><a href='https://contoso.sharepoint.com/sites/CoE/SitePages/Meet-your-Champions.aspx'>Meet your department champions</a> for peer-to-peer help in your department.</p>" }
        $script:liveControls = @($script:staleNoticeControl)
        $script:capturedText = $null
        Mock Get-PnPPage { [pscustomobject]@{ Controls = @($script:liveControls) } }
        Mock Add-PnPPageTextPart {
            $script:capturedText = $Text
            $newControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid(); Text = $Text }
            $script:liveControls = @($script:liveControls) + $newControl
        }
        Mock Remove-PnPPageComponent { $script:liveControls = @($script:liveControls | Where-Object { $_.InstanceId -ne $InstanceId }) }
        Mock Set-PnPPage { }
        Set-CoEHomeWelcomeText -SiteConnection "offline" -PageName "TrainingHome" -SiteUrl "https://contoso.sharepoint.com/sites/CoE" `
            -OrgName "Contoso" -OrgNoun "organization" -SampleNotice "Updated notice for this release."
        $script:capturedText | Should Match ([regex]::Escape("Updated notice for this release."))
        $script:capturedText | Should Not Match ([regex]::Escape("VALIDATION TEST SITE"))
        @($script:liveControls).Count | Should Be 1
    }
    It "leaves an unrelated customer heading alone while still adding our own welcome block (regression: a page with neither the vendor placeholder nor our own block left no welcome text at all)" {
        # Regression guard for a false-positive risk: a bare "...Copilot Center of Excellence</h2>" match
        # (with no further check) could also hit a customer's own unrelated heading. Requiring the block's
        # own champions link alongside the heading text means an unrelated customer control is left alone -
        # it is never matched, so it is never removed. That is different from doing nothing at all: a Home
        # page must always end up with exactly one correct welcome block in Section 4/Column 2 regardless of
        # whatever else is on the page. Confirmed live: a site that had its vendor placeholder AND an earlier
        # misplaced duplicate both removed (leaving zero matches) was left with no welcome text whatsoever
        # until this function stopped returning early on zero matches.
        $script:unrelatedControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = "<h2>Our Local Copilot Center of Excellence</h2><p>Some unrelated customer-authored content with no champions link at all.</p>" }
        $script:liveControls = @($script:unrelatedControl)
        $script:capturedArgs = $null
        Mock Get-PnPPage { [pscustomobject]@{ Controls = @($script:liveControls) } }
        Mock Remove-PnPPageComponent { throw "should not be called; the unrelated control is not ours" }
        Mock Add-PnPPageTextPart {
            $script:capturedArgs = @{ Section = $Section; Column = $Column }
            $newControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
                Text = "<h2>Welcome to the Contoso Copilot Center of Excellence</h2><p><a href='https://contoso.sharepoint.com/sites/CoE/SitePages/Meet-your-Champions.aspx'>x</a></p>" }
            $script:liveControls = @($script:liveControls) + $newControl
        }
        Mock Set-PnPPage {}
        { Set-CoEHomeWelcomeText -SiteConnection "offline" -PageName "TrainingHome" -SiteUrl "https://contoso.sharepoint.com/sites/CoE" `
            -OrgName "Contoso" -OrgNoun "organization" -SampleNotice "DEMO SITE - synthetic data only." } | Should Not Throw
        Assert-MockCalled Add-PnPPageTextPart -Times 1 -Exactly -Scope It
        $script:capturedArgs.Section | Should Be 4
        $script:capturedArgs.Column | Should Be 2
        @($script:liveControls | Where-Object { $_.InstanceId -eq $script:unrelatedControl.InstanceId }).Count | Should Be 1
    }
}

Describe "Upcoming sessions bind to the approved calendar view" {
    BeforeEach {
        $script:SiteUrl = "https://example.sharepoint.com/sites/CoE"
        $script:upcomingPage = [pscustomobject]@{ Controls = @() }
        $script:calendar = [pscustomobject]@{ Id = [guid]::NewGuid() }
        $script:upcomingView = [pscustomobject]@{ Id = [guid]::NewGuid() }
        Mock Get-PnPPage { $script:upcomingPage }
        Mock Add-PnPPageWebPart {
            $script:upcomingPage.Controls += [pscustomobject]@{
                PropertiesJson = ($WebPartProperties | ConvertTo-Json -Compress)
            }
        }
        Mock Get-PnPPageComponent { $script:upcomingPage.Controls }
        Mock Set-PnPPage {}
    }
    It "adds one bound list web part and leaves it alone on retry" {
        Add-CoEUpcomingSessionsWebPart offline "Learning-Series" $calendar $upcomingView
        Add-CoEUpcomingSessionsWebPart offline "Learning-Series" $calendar $upcomingView
        Assert-MockCalled Add-PnPPageWebPart -Times 1 -Exactly -Scope It -ParameterFilter {
            $DefaultWebPartType -eq "List" -and
            $WebPartProperties.selectedViewId -eq $script:upcomingView.Id.ToString() -and
            $WebPartProperties.selectedListId -eq $script:calendar.Id.ToString()
        }
        $upcomingPage.Controls.Count | Should Be 1
        $source | Should Match 'Upcoming approved sessions'
        $source | Should Match 'RowLimit 3'
        $source | Should Match "SampleStatus.*Approved"
    }
    It "rejects duplicate view bindings instead of claiming success" {
        $data = @{ selectedListId = $calendar.Id.ToString(); selectedViewId = $upcomingView.Id.ToString() } |
            ConvertTo-Json -Compress
        $script:upcomingPage.Controls = @(
            [pscustomobject]@{ PropertiesJson = $data },
            [pscustomobject]@{ PropertiesJson = $data })
        { Add-CoEUpcomingSessionsWebPart offline "TrainingHome" $calendar $upcomingView } | Should Throw
        Assert-MockCalled Add-PnPPageWebPart -Times 0 -Exactly -Scope It
    }
}

Describe "See the full training calendar link stays singular across reruns" {
    BeforeEach {
        $script:SiteUrl = "https://example.sharepoint.com/sites/CoE"
        $script:calendarUrl = "$SiteUrl/Lists/CopilotTrainingCalendar/Calendar.aspx"
        # $linkPage.Controls is the flat, page-wide control list (used for text-matching); $linkPage.Sections
        # mirrors the real PnP page's nested Section/Column structure (used for location checks). A helper
        # keeps both in sync as controls are added/removed/moved so tests can set up either shape and trust
        # the other reflects it.
        function script:New-TestPage([int]$Section = 2, [int]$Column = 1, [object[]]$ControlsInThatSlot = @()) {
            $sections = @(for ($s = 1; $s -le [math]::Max($Section, 2); $s++) {
                $cols = @(for ($c = 1; $c -le [math]::Max($Column, 1); $c++) {
                    $slotControls = @()
                    if ($s -eq $Section -and $c -eq $Column) { $slotControls = @($ControlsInThatSlot) }
                    [pscustomobject]@{ Controls = $slotControls }
                })
                [pscustomobject]@{ Columns = $cols }
            })
            $allControls = @($sections | ForEach-Object { $_.Columns } | ForEach-Object { $_.Controls })
            [pscustomobject]@{ Controls = $allControls; Sections = $sections }
        }
        $script:linkPage = New-TestPage
        Mock Get-PnPPage { $script:linkPage }
        Mock Add-PnPPageTextPart {
            $newControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid(); Text = $Text }
            $script:linkPage = New-TestPage -Section $Section -Column $Column -ControlsInThatSlot @($newControl)
        }
        Mock Remove-PnPPageComponent {
            $remainingControls = @($script:linkPage.Controls | Where-Object { $_.InstanceId -ne $InstanceId })
            $script:linkPage = New-TestPage -ControlsInThatSlot $remainingControls
        }
        Mock Set-PnPPage {}
    }
    It "adds exactly one link on first run" {
        Add-CoECalendarLinkTextPart offline "TrainingHome" $calendarUrl -Order 5 -Section 2 -Column 1
        Assert-MockCalled Add-PnPPageTextPart -Times 1 -Exactly -Scope It
        $linkPage.Controls.Count | Should Be 1
    }
    It "recognizes an already-added link even after SharePoint relativizes the saved href (regression: three live duplicates before this fix)" {
        # Regression test for a real live bug: SharePoint relativizes a same-site absolute href on save (the
        # same behavior already root-caused for breadcrumbs - see ConvertTo-CoEStableBreadcrumbText), so
        # matching the control's stored Text against the literal absolute $CalendarUrl never matched once
        # saved, and every one of three live update runs added another copy before this fix. Matching on the
        # fixed link text instead of the href is what makes this idempotent.
        $existingControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = '<p><a href="/sites/CoE/Lists/CopilotTrainingCalendar/Calendar.aspx">See the full training calendar</a></p>' }
        $script:linkPage = New-TestPage -Section 2 -Column 1 -ControlsInThatSlot @($existingControl)
        Add-CoECalendarLinkTextPart offline "TrainingHome" $calendarUrl -Order 5 -Section 2 -Column 1
        Assert-MockCalled Add-PnPPageTextPart -Times 0 -Exactly -Scope It
        $linkPage.Controls.Count | Should Be 1
    }
    It "cleans up pre-existing duplicates down to exactly one, matching the live state found today" {
        $script:linkPage = New-TestPage -Section 2 -Column 1 -ControlsInThatSlot @(
            [pscustomobject]@{ InstanceId = [guid]::NewGuid(); Text = '<p><a href="/a">See the full training calendar</a></p>' },
            [pscustomobject]@{ InstanceId = [guid]::NewGuid(); Text = '<p><a href="/b">See the full training calendar</a></p>' },
            [pscustomobject]@{ InstanceId = [guid]::NewGuid(); Text = '<p><a href="/c">See the full training calendar</a></p>' }
        )
        Add-CoECalendarLinkTextPart offline "TrainingHome" $calendarUrl -Order 5 -Section 2 -Column 1
        Assert-MockCalled Add-PnPPageTextPart -Times 0 -Exactly -Scope It
        Assert-MockCalled Remove-PnPPageComponent -Times 2 -Exactly -Scope It
        $linkPage.Controls.Count | Should Be 1
    }
    It "relocates a control left in the wrong Section/Column by an older version's targeting (upgrade-path regression)" {
        # Regression test for a confirmed gap: matching by text content alone (not location) meant a control
        # added under OLDER code - before this Section/Column targeting existed - was "found" and left in
        # place forever, never moved just because the target changed later. A site updated from 3.8.5 or
        # earlier needs this relocation to actually pick up the current layout, not just a fresh install.
        $misplacedControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = '<p><a href="/old">See the full training calendar</a></p>' }
        $script:linkPage = New-TestPage -Section 1 -Column 1 -ControlsInThatSlot @($misplacedControl)
        Add-CoECalendarLinkTextPart offline "TrainingHome" $calendarUrl -Order 5 -Section 2 -Column 1
        Assert-MockCalled Remove-PnPPageComponent -Times 1 -Exactly -Scope It
        Assert-MockCalled Add-PnPPageTextPart -Times 1 -Exactly -Scope It
        $linkPage.Controls.Count | Should Be 1
        $linkPage.Sections[1].Columns[0].Controls.Count | Should Be 1
        $linkPage.Sections[0].Columns[0].Controls.Count | Should Be 0
    }
    It "leaves a control alone when it is already in the correct Section/Column" {
        $correctControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = '<p><a href="/current">See the full training calendar</a></p>' }
        $script:linkPage = New-TestPage -Section 2 -Column 1 -ControlsInThatSlot @($correctControl)
        Add-CoECalendarLinkTextPart offline "TrainingHome" $calendarUrl -Order 5 -Section 2 -Column 1
        Assert-MockCalled Remove-PnPPageComponent -Times 0 -Exactly -Scope It
        Assert-MockCalled Add-PnPPageTextPart -Times 0 -Exactly -Scope It
        $linkPage.Controls.Count | Should Be 1
    }
}

Describe "Customer-mode 'No sessions scheduled yet' placeholder" {
    BeforeEach {
        $script:SiteUrl = "https://example.sharepoint.com/sites/CoE"
        function script:New-TestPage([int]$Section = 2, [int]$Column = 1, [object[]]$ControlsInThatSlot = @()) {
            $sections = @(for ($s = 1; $s -le [math]::Max($Section, 2); $s++) {
                $cols = @(for ($c = 1; $c -le [math]::Max($Column, 1); $c++) {
                    $slotControls = @()
                    if ($s -eq $Section -and $c -eq $Column) { $slotControls = @($ControlsInThatSlot) }
                    [pscustomobject]@{ Controls = $slotControls }
                })
                [pscustomobject]@{ Columns = $cols }
            })
            $allControls = @($sections | ForEach-Object { $_.Columns } | ForEach-Object { $_.Controls })
            [pscustomobject]@{ Controls = $allControls; Sections = $sections }
        }
        $script:placeholderPage = New-TestPage
        Mock Get-PnPPage { $script:placeholderPage }
        Mock Add-PnPPageTextPart {
            $newControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid(); Text = $Text }
            $script:placeholderPage = New-TestPage -Section $Section -Column $Column -ControlsInThatSlot @($newControl)
        }
        Mock Remove-PnPPageComponent {
            $remainingControls = @($script:placeholderPage.Controls | Where-Object { $_.InstanceId -ne $InstanceId })
            $script:placeholderPage = New-TestPage -ControlsInThatSlot $remainingControls
        }
        Mock Set-PnPPage {}
    }
    It "adds exactly one heading on first run, above where the calendar link goes" {
        # Regression test for a confirmed live gap: Customer mode never shows the live upcoming-sessions
        # List web part (see Remove-CoEUpcomingSessionsWebPart), so without this heading Section 2/Column 1
        # held only a bare "See the full training calendar" link next to the full Copilot tools grid - a
        # live reviewer flagged this as a half-empty-looking section with no context for what the link is.
        Add-CoENoSessionsPlaceholder offline "TrainingHome" -Order 4 -Section 2 -Column 1
        Assert-MockCalled Add-PnPPageTextPart -Times 1 -Exactly -Scope It
        $placeholderPage.Controls.Count | Should Be 1
        $placeholderPage.Controls[0].Text | Should Match "No sessions scheduled yet"
    }
    It "is idempotent: a rerun does not add a second copy" {
        Add-CoENoSessionsPlaceholder offline "TrainingHome" -Order 4 -Section 2 -Column 1
        Add-CoENoSessionsPlaceholder offline "TrainingHome" -Order 4 -Section 2 -Column 1
        Assert-MockCalled Add-PnPPageTextPart -Times 1 -Exactly -Scope It
        $placeholderPage.Controls.Count | Should Be 1
    }
    It "relocates a placeholder left in the wrong Section/Column" {
        $misplacedControl = [pscustomobject]@{ InstanceId = [guid]::NewGuid()
            Text = "<h3>Upcoming sessions</h3><p>No sessions scheduled yet. Check the full calendar for updates.</p>" }
        $script:placeholderPage = New-TestPage -Section 1 -Column 1 -ControlsInThatSlot @($misplacedControl)
        Add-CoENoSessionsPlaceholder offline "TrainingHome" -Order 4 -Section 2 -Column 1
        Assert-MockCalled Remove-PnPPageComponent -Times 1 -Exactly -Scope It
        Assert-MockCalled Add-PnPPageTextPart -Times 1 -Exactly -Scope It
        $placeholderPage.Sections[1].Columns[0].Controls.Count | Should Be 1
        $placeholderPage.Sections[0].Columns[0].Controls.Count | Should Be 0
    }
    It "Remove-CoENoSessionsPlaceholder removes an existing heading and is a no-op when absent" {
        # The Demo-mode counterpart: if a site is ever repaired from Customer into Demo mode, the heading must
        # not linger above the real live calendar web part it was built to stand in for.
        Add-CoENoSessionsPlaceholder offline "TrainingHome" -Order 4 -Section 2 -Column 1
        $placeholderPage.Controls.Count | Should Be 1
        Remove-CoENoSessionsPlaceholder offline "TrainingHome"
        $placeholderPage.Controls.Count | Should Be 0
        Remove-CoENoSessionsPlaceholder offline "TrainingHome"
        $placeholderPage.Controls.Count | Should Be 0
    }
}

Describe "Existing upcoming sessions view" {
    It "updates the view row limit with the UInt32 type required by PnP" {
        $script:calendarViews = @([pscustomobject]@{ Title = "Upcoming approved sessions"; Id = [guid]::NewGuid() })
        $script:calendar = [pscustomobject]@{ Id = [guid]::NewGuid() }
        $script:upcomingQuery = "<Where><Eq><FieldRef Name='SampleStatus'/></Eq></Where>"
        $script:site = "offline"
        Mock Set-PnPView {
            if ($Values.RowLimit -isnot [uint32]) { throw "RowLimit must be UInt32" }
        }
        . $calendarViewBlock
        Assert-MockCalled Set-PnPView -Times 1 -Exactly -Scope It -ParameterFilter {
            $Values.RowLimit -eq 3 -and $Values.RowLimit -is [uint32] -and
            $Values.ViewQuery -eq $script:upcomingQuery
        }
    }
}

Describe "Team identity remains available after tool page generation" {
    It "does not shadow the Microsoft 365 group with grouped tool pages" {
        $source | Should Match 'foreach \(\$toolPageGroup in @\(\$toolsCatalog.tools \| Group-Object page\)\)'
        $source | Should Not Match 'foreach \(\$group in @\(\$toolsCatalog.tools \| Group-Object page\)\)'
        $source | Should Match '\$report.TeamId = \$group.GroupId'
    }
}

Describe "Learning and agent catalog page integration" {
            BeforeEach {
                $script:SiteUrl = "https://example.sharepoint.com/sites/CoE"
                $script:ReplaceManagedPages = $false
                $script:writtenManagedPages = @("$SiteUrl|CoE-Agent-Showcase")
                $script:catalogPage = [pscustomobject]@{ Controls = @(
                    [pscustomobject]@{ Text = "purpose and notice"; Order = 1 },
                    [pscustomobject]@{ Text = "body"; Order = 2 }); Saves = 0 }
                $script:catalogPage | Add-Member ScriptMethod Save { $this.Saves++ }
                $script:catalog = [pscustomobject]@{ List = [pscustomobject]@{ Id = "existing-agent-list" }
                    ListUrl = "$SiteUrl/Lists/CopilotAgentShowcase" }
                $script:featured = [pscustomobject]@{ Id = "featured"; ServerRelativeUrl = "/sites/CoE/Lists/CopilotAgentShowcase/Featured.aspx" }
                $script:published = [pscustomobject]@{ Id = "published"; ServerRelativeUrl = "/sites/CoE/Lists/CopilotAgentShowcase/Published.aspx" }
                $script:orders = @()
                # Add-CoECatalogPageView re-fetches ServerRelativeUrl via Get-PnPView rather than trusting the
                # value already on the view object; read the fixture's current value so tests that mutate it
                # (e.g. to an empty string) still exercise the same behavior.
                Mock Get-PnPView {
                    if ($Identity -eq $script:featured.Id) { [pscustomobject]@{ Id = $script:featured.Id; ServerRelativeUrl = $script:featured.ServerRelativeUrl } }
                    elseif ($Identity -eq $script:published.Id) { [pscustomobject]@{ Id = $script:published.Id; ServerRelativeUrl = $script:published.ServerRelativeUrl } }
                    else { throw "Unexpected view identity '$Identity'" }
                }
                Mock Get-PnPPage { $script:catalogPage }
                Mock Add-PnPPageTextPart {
                    $script:orders += [int]$Order
                    $script:catalogPage.Controls += [pscustomobject]@{ Text = "heading"; Order = [int]$Order }
                }
                Mock Add-PnPPageWebPart {
                    $script:orders += [int]$Order
                    $script:catalogPage.Controls += [pscustomobject]@{ Text = "list"; Order = [int]$Order }
                }
                Mock Set-PnPPage {}
            }
            It "keeps the purpose and notice ahead of Featured and Published and puts details afterward" {
                Add-CoECatalogPageView offline "CoE-Agent-Showcase" $catalog $featured "Featured"
                Add-CoECatalogPageView offline "CoE-Agent-Showcase" $catalog $published "Published" -Order 4
                ($orders -join ",") | Should Be "2,3,4,5"
                $catalogPage.Controls[0].Order | Should Be 1
                $catalogPage.Controls[1].Order | Should Be 6
                $catalogPage.Saves | Should Be 2
                Assert-MockCalled Add-PnPPageWebPart -Times 1 -Exactly -Scope It -ParameterFilter {
                    $WebPartProperties.selectedViewId -eq "featured" -and $Order -eq 3 -and
                    $WebPartProperties.selectedListId -eq "existing-agent-list" -and $WebPartProperties.hideCommandBar -and
                    $WebPartProperties.hideTitle -and -not $WebPartProperties.showTitle
                }
            }
            It "opens the reader view rather than the raw AllItems page" {
                Add-CoECatalogPageView offline "CoE-Agent-Showcase" $catalog $published "Published"
                Assert-MockCalled Add-PnPPageTextPart -Times 1 -Exactly -Scope It -ParameterFilter {
                    $Text -match '/Published\.aspx' -and $Text -notmatch 'AllItems'
                }
            }
            It "fails on missing reader view URLs instead of linking to an unsafe fallback" {
                $published.ServerRelativeUrl = ""
                { Add-CoECatalogPageView offline "CoE-Agent-Showcase" $catalog $published "Published" } | Should Throw
                Assert-MockCalled Add-PnPPageWebPart -Times 0 -Exactly -Scope It
            }
            It "never retrofits a preserved page whose catalog link already exists" {
                $script:writtenManagedPages = @()
                $catalogPage.Controls += [pscustomobject]@{ Order = 3
                    PropertiesJson = (@{ selectedListId = $catalog.List.Id; selectedViewId = $featured.Id } | ConvertTo-Json -Compress) }
                Add-CoECatalogPageView offline "CoE-Agent-Showcase" $catalog $featured "Featured"
                Assert-MockCalled Get-PnPPage -Times 1 -Exactly -Scope It
                Assert-MockCalled Add-PnPPageWebPart -Times 0 -Exactly -Scope It
                Assert-MockCalled Add-PnPPageTextPart -Times 0 -Exactly -Scope It
                Assert-MockCalled Set-PnPPage -Times 0 -Exactly -Scope It
            }
            It "repairs a preserved page whose catalog link is missing (recovers a run that stopped before linking it)" {
                $script:writtenManagedPages = @()
                Add-CoECatalogPageView offline "CoE-Agent-Showcase" $catalog $featured "Featured"
                Assert-MockCalled Get-PnPPage -Times 1 -Exactly -Scope It
                Assert-MockCalled Add-PnPPageWebPart -Times 1 -Exactly -Scope It -ParameterFilter {
                    $WebPartProperties.selectedViewId -eq "featured" -and $WebPartProperties.selectedListId -eq "existing-agent-list"
                }
                Assert-MockCalled Set-PnPPage -Times 1 -Exactly -Scope It
            }
            It "does not repair an unrelated catalog's view and leaves a missing page alone" {
                $script:writtenManagedPages = @()
                Mock Get-PnPPage { $null }
                { Add-CoECatalogPageView offline "CoE-Agent-Showcase" $catalog $featured "Featured" } | Should Not Throw
                Assert-MockCalled Add-PnPPageWebPart -Times 0 -Exactly -Scope It
            }
            It "propagates web part failures rather than claiming a published catalog" {
                Mock Add-PnPPageWebPart { throw "403 Forbidden" }
                { Add-CoECatalogPageView offline "CoE-Agent-Showcase" $catalog $featured "Featured" } | Should Throw
                Assert-MockCalled Set-PnPPage -Times 0 -Exactly -Scope It
            }
            It "preflights reviewer syntax and identities before tenant content mutations" {
                $source.IndexOf('Assert-CoECatalogReviewerUPNs $catalogReviewers') |
                    Should BeLessThan $source.IndexOf('if (-not $Connection)')
                $source.IndexOf('Resolve-CoECatalogReviewers -ReviewerUPNs $catalogReviewers') |
                    Should BeLessThan $source.IndexOf('Set-SiteTimeZone -SiteConnection')
                $source.IndexOf('Assert-CoECatalogPreflight -SiteUrl $SiteUrl') |
                    Should BeLessThan $source.IndexOf('Set-SiteTimeZone -SiteConnection')
                $source | Should Match 'Sync-CoELearningCatalog .*ResolvedReviewers'
                $source | Should Match 'Sync-CoEAgentCatalog .*ResolvedReviewers'
            }
            It "always embeds both views on an empty catalog using count-independent neutral guidance" {
                $script:site = "offline"
                $script:agentCatalog = [pscustomobject]@{ List = $catalog.List; ListUrl = $catalog.ListUrl
                    Views = [pscustomobject]@{ Published = $published; Featured = $featured } }
                & $agentPageBlock
                Assert-MockCalled Add-PnPPageWebPart -Times 2 -Exactly -Scope It
                Assert-MockCalled Add-PnPPageWebPart -Times 1 -Exactly -Scope It -ParameterFilter {
                    $Order -eq 3 -and $WebPartProperties.selectedViewId -eq "featured"
                }
                Assert-MockCalled Add-PnPPageWebPart -Times 1 -Exactly -Scope It -ParameterFilter {
                    $Order -eq 5 -and $WebPartProperties.selectedViewId -eq "published"
                }
                Assert-MockCalled Add-PnPPageTextPart -Times 1 -Exactly -Scope It -ParameterFilter {
                    $Order -eq 2 -and $Text -match "Agents appear here" -and $Text -match "empty"
                }
                $source | Should Not Match 'PublishedCount|FeaturedCount|EmptyMessage'
                $catalogPage.Controls[0].Order | Should Be 1
                $catalogPage.Controls[1].Order | Should Be 6
            }
            It "deep-links every local Practice URL to a rendered named prompt" {
                $markdown = Get-Content -LiteralPath (Join-Path $kitRoot "SeedContent\Guides\07-Prompt-Library.md") -Raw
                $html = (Convert-GuideMarkdown $markdown).Html
                $data = Get-Content -LiteralPath (Join-Path $kitRoot "SeedContent\Learning-Paths.json") -Raw | ConvertFrom-Json
                foreach ($row in $data.items | Where-Object practiceUrl) {
                    $row.practiceUrl | Should Match 'Guide-Prompt-Library.aspx#[a-z0-9-]+$'
                    $fragment = ($row.practiceUrl -split '#')[1]
                    $html | Should Match ('id="' + [regex]::Escape($fragment) + '"')
                    $fragment | Should Be (Get-CoEHeadingAnchor $row.practicePromptTitle)
                }
                $markdown | Should Not Match 'if approved in your library'
            }
            It "does not render configured agent links as a second publication route" {
                $resolver = $completionAst.Find({ param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Resolve-OrgTokens"
                }, $true).Extent.Text
                $resolver | Should Not Match 'Get-OrgValue "Agents"'
                $source | Should Not Match 'AgentStatus = "Published"'
            }
            It "routes configuration choices through the shared advisory preflight before staging content" {
                $source | Should Match 'Invoke-CoEConfigurationAdvisories -Context \$advisoryContext'
                $source.IndexOf('Invoke-CoEConfigurationAdvisories') | Should BeLessThan $source.IndexOf('$stageRoot =')
            }
            It "ships six three-step paths pointing at existing base guides" {
                $data = Get-Content -LiteralPath (Join-Path $kitRoot "SeedContent\Learning-Paths.json") -Raw | ConvertFrom-Json
                $rows = @(ConvertTo-CoELearningSeeds $data.items $SiteUrl)
                $rows.Count | Should Be 18
                @($rows | Group-Object audience).Count | Should Be 6
                foreach ($group in @($rows | Group-Object audience)) { $group.Count | Should Be 3 }
                foreach ($row in $rows) {
                    $row.requirement | Should Be "Recommended"
                    $row.reviewedOn | Should Be ""
                    $page = Split-Path -Leaf $row.resourceUrl
                    if ($page -like "Guide-*") {
                        $slug = $page -replace '^Guide-', '' -replace '\.aspx$', ''
                        @(Get-ChildItem -LiteralPath (Join-Path $kitRoot "SeedContent\Guides") -Filter "*-$slug.md" -File).Count |
                            Should Be 1
                    }
                }
            }
}

Describe "Top 10 exact target reconciliation and failure recovery" {
    BeforeEach {
        $script:targetUrl = "https://example.sharepoint.com/sites/CoE/Shared%20Documents/Ask/New.pptx"
        $script:oldUrl = "https://example.sharepoint.com/sites/CoE/Shared%20Documents/Ask/Old.pptx"
        $script:tabState = @(New-TestTab "old" $oldUrl "old-file")
        $script:syncArgs = @{ Team = "team"; Channel = "ask"; FileUrl = $targetUrl; EntityId = "new-file"
            KnownFileUrls = @($oldUrl); PreviousEntityId = "old-file"; Connection = "offline" }
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Start-Sleep {}
        Mock Get-PnPTeamsTab { $script:tabState }
        Mock Add-PnPTeamsTab {
            $new = New-TestTab "new" $ContentUrl $EntityId $DisplayName
            $script:tabState += $new
            $new
        }
        Mock Remove-PnPTeamsTab { $script:tabState = @($script:tabState | Where-Object Id -ne $Identity) }
    }
    It "does not mistake an identity without a working URL for a bound resource" {
        (Test-TeamsFileTabTarget (New-TestTab "x" "" "new-file") $targetUrl "new-file") | Should Be $false
        (Test-TeamsFileTabTarget (New-TestTab "x" "https://other.example/file" "new-file") $targetUrl "new-file") | Should Be $false
    }
    It "matches an exact encoded file query parameter" {
        $wrapper = "https://office.example/view?file=" + [uri]::EscapeDataString($targetUrl)
        (Test-TeamsFileTabTarget (New-TestTab "x" $wrapper) $targetUrl "") | Should Be $true
    }
    It "does not confuse filename substrings, other site paths, or longer query values" {
        foreach ($url in @($targetUrl + ".backup", $targetUrl.Replace("/sites/CoE/", "/sites/Other/"),
            "https://office.example/view?file=" + [uri]::EscapeDataString($targetUrl + ".backup"))) {
            (Test-TeamsFileTabTarget (New-TestTab "x" $url) $targetUrl "") | Should Be $false
        }
    }
    It "handles missing configuration and null URLs without throwing" {
        (Test-TeamsFileTabTarget ([pscustomobject]@{ Configuration = $null }) $targetUrl "") | Should Be $false
        (Test-TeamsFileTabTarget (New-TestTab "x" $null) $targetUrl "") | Should Be $false
    }
    It "creates and verifies the intended tab before removing the stale kit tab" {
        Mock Remove-PnPTeamsTab {
            @($script:tabState | Where-Object Id -eq "new").Count | Should Be 1
            $script:tabState = @($script:tabState | Where-Object Id -ne $Identity)
        }
        (Sync-TopTenTab @syncArgs).Id | Should Be "new"
        $tabState.Count | Should Be 1
        Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
    }
    It "recovers duplicate tabs on resume without another create, preserving unrelated same-name tabs" {
        $script:tabState += @(New-TestTab "intended" $targetUrl "new-file")
        $script:tabState += @(New-TestTab "duplicate" $targetUrl "new-file")
        $script:tabState += @(New-TestTab "custom" "https://example.org/custom")
        $script:tabState += @(New-TestTab "other-name" $oldUrl "old-file" "Custom training")
        (Sync-TopTenTab @syncArgs).Id | Should Be "intended"
        @($tabState | ForEach-Object Id) -join "," | Should Be "intended,custom,other-name"
        Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "is recoverable when deletion fails after successful creation" {
        Mock Remove-PnPTeamsTab { throw "403 Forbidden" }
        { Sync-TopTenTab @syncArgs } | Should Throw
        $tabState.Count | Should Be 2
        Mock Remove-PnPTeamsTab { $script:tabState = @($script:tabState | Where-Object Id -ne $Identity) }
        (Sync-TopTenTab @syncArgs).Id | Should Be "new"
        Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
    }
    It "does not delete the old tab when creation returns an unverified tab" {
        Mock Add-PnPTeamsTab { New-TestTab "not-saved" $targetUrl "new-file" }
        { Sync-TopTenTab @syncArgs } | Should Throw
        Assert-MockCalled Remove-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "respects a tab intentionally removed by the organization" {
        $script:tabState = @()
        (Sync-TopTenTab @syncArgs) | Should BeNullOrEmpty
        Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "creates the missing Top 10 tab only with explicit install or repair authorization" {
        $script:tabState = @()
        (Sync-TopTenTab @syncArgs -CreateMissing).Id | Should Be "new"
        Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
        $source | Should Match 'CreateMissing:\$EnsureResourceTabs'
    }
    It "creates missing required installer resource tabs" {
        $script:tabState = @()
        $result = Sync-CoEFileTab -Team team -Channel ask -DisplayName "Prompt Ingredients" -Type PDF `
            -FileUrl $targetUrl -EntityId new-file -CreateMissing -Connection offline
        $result.Id | Should Be "new"
        Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
    }
    It "replaces only unbound kit placeholders after verifying the new file tab" {
        $script:tabState = @(New-TestTab "placeholder" "" "")
        $result = Sync-CoEFileTab -Team team -Channel ask -DisplayName "Top 10 to try" -Type PowerPoint `
            -FileUrl $targetUrl -EntityId new-file -RemoveUnboundPlaceholders -Connection offline
        $result.Id | Should Be "new"
        $tabState.Count | Should Be 1
        Assert-MockCalled Remove-PnPTeamsTab -Times 1 -Exactly -Scope It -ParameterFilter { $Identity -eq "placeholder" }
    }
    It "recovers an exact tab created during a timed-out request" {
        Mock Add-PnPTeamsTab {
            $script:tabState += @(New-TestTab "slow" $ContentUrl $EntityId)
            throw "Timeout"
        }
        (Sync-TopTenTab @syncArgs).Id | Should Be "slow"
        Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
    }
    It "does not treat an unrelated same-name tab as a successful timed-out create" {
        Mock Add-PnPTeamsTab { throw "Timeout" }
        { Sync-TopTenTab @syncArgs } | Should Throw
        Assert-MockCalled Add-PnPTeamsTab -Times 4 -Exactly -Scope It
        Assert-MockCalled Remove-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "fails immediately on authentication errors even when the message mentions a timeout" {
        Mock Add-PnPTeamsTab { throw "401 Unauthorized after Timeout" }
        { Sync-TopTenTab @syncArgs } | Should Throw
        Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
    }
    It "does not swallow read authentication failures during retry verification" {
        Mock Add-PnPTeamsTab { throw "Timeout" }
        Mock Get-PnPTeamsTab { throw "403 Forbidden" }
        { Add-TeamsTabWithRetry -Team team -Channel ask -DisplayName "Top 10 to try" `
            -TabArgs @{ Type = "PowerPoint"; ContentUrl = $targetUrl; EntityId = "new-file" } -Connection offline } | Should Throw
        Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
    }
    It "retries general page tabs by their exact URL, not just display name" {
        $script:tabState = @(New-TestTab "custom" "https://example.org/custom" "" "Start here")
        $script:creates = 0
        Mock Add-PnPTeamsTab {
            $script:creates++
            if ($script:creates -eq 1) { throw "503 ServiceUnavailable" }
            New-TestTab "page" $WebSiteUrl "" $DisplayName
        }
        $result = Add-TeamsTabWithRetry -Team team -Channel ask -DisplayName "Start here" `
            -TabArgs @{ Type = "SharePointPageAndList"; WebSiteUrl = $targetUrl } -Connection offline
        $result.Id | Should Be "page"
        Assert-MockCalled Add-PnPTeamsTab -Times 2 -Exactly -Scope It
    }
    It "keeps the current organization deck when declining replacement despite a stale tab appearing first" {
        $script:orgDeckFolder = "C:\OfflineOrg\Assets\Top10"
        $script:askFolder = [pscustomobject]@{ webUrl = "https://example.sharepoint.com/sites/CoE/Shared%20Documents/Ask" }
        $script:currentTop = @(New-TestTab "old" ($askFolder.webUrl + "/Microsoft365Copilot_Top10toTry_Handout.pptx"))
        $script:currentTop += @(New-TestTab "current" $targetUrl)
        Mock Test-Path { $true }
        Mock Get-ChildItem { [pscustomobject]@{ Name = "New.pptx"; FullName = "C:\OfflineOrg\Assets\Top10\New.pptx" } }
        $block = Get-CompletionBlock 'if ($orgDeckFolder -and (Test-Path -LiteralPath $orgDeckFolder) -and $currentTop.Count -gt 0)'
        . $block
        $handoutName | Should Be "New.pptx"
    }
    It "does not adopt an unrelated same-filename organization deck tab on another site" {
        $script:orgDeckFolder = "C:\OfflineOrg\Assets\Top10"
        $script:askFolder = [pscustomobject]@{ webUrl = "https://example.sharepoint.com/sites/CoE/Shared%20Documents/Ask" }
        $script:currentTop = @(New-TestTab "custom" $targetUrl.Replace("/sites/CoE/", "/sites/Other/"))
        $handoutName = "Microsoft365Copilot_Top10toTry_Handout.pptx"
        Mock Test-Path { $true }
        Mock Get-ChildItem { [pscustomobject]@{ Name = "New.pptx"; FullName = "C:\OfflineOrg\Assets\Top10\New.pptx" } }
        $block = Get-CompletionBlock 'if ($orgDeckFolder -and (Test-Path -LiteralPath $orgDeckFolder) -and $currentTop.Count -gt 0)'
        . $block
        $handoutName | Should Be "Microsoft365Copilot_Top10toTry_Handout.pptx"
    }
    It "retains previous managed file provenance even when a full run creates a fresh report" {
        $source | Should Match '\$previousReport = Get-Content -LiteralPath \$previousReportPath'
        $source | Should Match '\$previousTopTen = \$previousReport.TopTen'
        $source | Should Match '\$knownTopUrls \+= \[string\]\$previousTopTen.FileUrl'
    }
}

Describe "Organization asset upload preserves the working file" {
    BeforeEach {
        $script:OrgPath = "C:\OfflineOrg"
        $script:orgSource = "C:\OfflineOrg\Assets\Training"
        $script:section = [pscustomobject]@{ orgAssets = [pscustomobject]@{ category = "Training" } }
        $script:orgFiles = @([pscustomobject]@{ DirectoryName = "C:\OfflineOrg\Assets\Training"; Name = "Existing.pptx"; FullName = "C:\OfflineOrg\Assets\Training\Existing.pptx" })
        $script:channelPath = "Shared Documents/Training"
        $script:assetFolder = "Training Materials"
        $script:site = "offline"
        $script:orgUploaded = @()
        $script:ReplaceOrgAssets = $false
        $script:existingHandout = @([pscustomobject]@{ Name = "Existing.pptx" })
        $script:handoutName = "Existing.pptx"
        $script:handoutLocal = $orgFiles[0].FullName
        $script:askPath = "Shared Documents/Ask"
        Mock Write-Warning {}
        Mock Write-Host {}
        Mock Resolve-PnPFolder {}
        Mock Get-PnPFolderItem { [pscustomobject]@{ Name = "Existing.pptx" } }
        Mock Add-PnPFile {}
        Mock Remove-PnPFile {}
    }
    It "keeps existing organization files without the replacement gate" {
        . $orgUploadBlock
        Assert-MockCalled Add-PnPFile -Times 0 -Exactly -Scope It
        Assert-MockCalled Remove-PnPFile -Times 0 -Exactly -Scope It
    }
    It "overwrites in place with the explicit replacement gate" {
        $script:ReplaceOrgAssets = $true
        . $orgUploadBlock
        Assert-MockCalled Add-PnPFile -Times 1 -Exactly -Scope It
        Assert-MockCalled Remove-PnPFile -Times 0 -Exactly -Scope It
        $orgUploaded.Count | Should Be 1
    }
    It "uploads missing organization assets without requiring replacement authorization" {
        Mock Get-PnPFolderItem {}
        . $orgUploadBlock
        Assert-MockCalled Add-PnPFile -Times 1 -Exactly -Scope It
        Assert-MockCalled Remove-PnPFile -Times 0 -Exactly -Scope It
    }
    It "never recycles the working organization file when upload fails" {
        $script:ReplaceOrgAssets = $true
        Mock Add-PnPFile { throw "Upload failed" }
        { . $orgUploadBlock } | Should Throw
        Assert-MockCalled Remove-PnPFile -Times 0 -Exactly -Scope It
        $orgUploaded.Count | Should Be 0
    }
    It "never recycles the working Top 10 deck when upload fails" {
        $script:ReplaceOrgAssets = $true
        Mock Add-PnPFile { throw "Upload failed" }
        { . $topUploadBlock } | Should Throw
        Assert-MockCalled Remove-PnPFile -Times 0 -Exactly -Scope It
    }
    It "keeps the Top 10 deck when replacement is not authorized" {
        . $topUploadBlock
        Assert-MockCalled Add-PnPFile -Times 0 -Exactly -Scope It
        Assert-MockCalled Remove-PnPFile -Times 0 -Exactly -Scope It
    }
}

Describe "Customer mode refuses to host org asset files named DEMO or SAMPLE" {
    # Regression coverage for a confirmed live risk: a validation org folder's Assets\Agents and Assets\Training
    # held files named Contoso-Agent-Proposals-DEMO-ONLY.txt and Contoso-Demo-Practice-Handout.txt. Test-CoEInstall.ps1's own
    # "DEMO ONLY" Customer-mode check only scans rendered page text, never uploaded file names, so a production
    # run with -AcceptOrgAssets (or an operator typing "Y" without reading the file name closely) would have
    # uploaded a file with "DEMO-ONLY" in its name straight to the customer's live site.
    BeforeEach {
        $script:testRoot = Join-Path ([IO.Path]::GetTempPath()) ("coe-orgassets-" + [guid]::NewGuid().ToString("N"))
        $script:OrgPath = $testRoot
        $assetsFolder = Join-Path $testRoot "Assets\Agents"
        New-Item -ItemType Directory -Path $assetsFolder -Force | Out-Null
        Set-Content (Join-Path $assetsFolder "README.txt") "readme" -Encoding utf8
        Set-Content (Join-Path $assetsFolder "Contoso-Agent-Proposals-DEMO-ONLY.txt") "demo content" -Encoding utf8
        Set-Content (Join-Path $assetsFolder "Contoso-SAMPLE-Agents.txt") "sample content" -Encoding utf8
        Set-Content (Join-Path $assetsFolder "Contoso-Real-Agent-Catalog.txt") "real content" -Encoding utf8
        $script:orgAssetDecisions = @{}
        $script:AcceptOrgAssets = $true
        Mock Write-Host {}
        Mock Write-Warning {}
    }
    AfterEach {
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force } }
    It "drops DEMO- and SAMPLE-named files in Customer mode, keeping the genuinely-named one" {
        $script:ContentMode = "Customer"
        $result = @(Confirm-OrgAssets "Agents" "Host these files?")
        ($result | ForEach-Object Name) | Should Be @("Contoso-Real-Agent-Catalog.txt")
        Assert-MockCalled Write-Warning -Times 2 -Exactly -Scope It
    }
    It "allows DEMO- and SAMPLE-named files through in Demo mode, where seeded samples are expected" {
        $script:ContentMode = "Demo"
        $result = @(Confirm-OrgAssets "Agents" "Host these files?")
        (@($result | ForEach-Object Name) | Sort-Object) | Should Be @(
            "Contoso-Agent-Proposals-DEMO-ONLY.txt", "Contoso-Real-Agent-Catalog.txt", "Contoso-SAMPLE-Agents.txt")
        Assert-MockCalled Write-Warning -Times 0 -Exactly -Scope It
    }
    It "does not flag a legitimate name that merely contains the letters without the whole word (for example 'Demonstration')" {
        Set-Content (Join-Path $testRoot "Assets\Agents\Contoso-Agent-Demonstration-Guide.txt") "real content" -Encoding utf8
        $script:ContentMode = "Customer"
        $result = @(Confirm-OrgAssets "Agents" "Host these files?")
        (@($result | ForEach-Object Name) -contains "Contoso-Agent-Demonstration-Guide.txt") | Should Be $true
    }
}

Describe "Calendar seed and cleanup use offsets from today, not fixed dates" {
    BeforeEach {
        $script:siteTimeZone = [TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time")
        $script:eastern = $siteTimeZone
        $script:site = "offline"
        $script:calendar = [pscustomobject]@{ Id = "calendar" }
        $script:eventsAdded = 0
        $script:eventsSkipped = 0
        $script:eventsRemoved = 0
        # Fixed reference date so offset math is deterministic regardless of when this test runs.
        $script:today = [datetime]"2026-10-14"
        # Cross-midnight session (23:30 ET to 00:30 ET the next day) to prove EndOffsetDays still lets an
        # event span a day boundary even though every shipped sample is same-day (EndOffsetDays omitted).
        $script:eventSeeds = @([pscustomobject]@{ Title = "Late session"; StartOffsetDays = "1"; EndOffsetDays = "2"; StartTimeET = "23:30"
            EndTimeET = "00:30"; Description = "Draft"; Audience = "Staff"; Format = "Online session"; SampleStatus = "DRAFT - DEMONSTRATION" })
        $script:existingEvents = @(@{ Id = 1; Title = "Late session"; EventDate = [datetime]::SpecifyKind([datetime]"2026-10-16T03:30:00", [DateTimeKind]::Utc); SampleStatus = "DRAFT - DEMONSTRATION" })
        # $existingTitles and $seedTitles stand in for the script-level variables the real source computes
        # just before each extracted foreach block (Get-CompletionBlock only captures the foreach statement
        # itself, not the assignment lines immediately before it) - keyed on Title ALONE, not Title +
        # SampleStatus, so an admin flipping a row's live SampleStatus (approving a draft sample) still
        # counts as "this title already exists" on the next run.
        $script:existingTitles = @($script:existingEvents | ForEach-Object { [string]$_["Title"] })
        $script:seedTitles = @($script:eventSeeds | ForEach-Object { [string]$_.Title })
        Mock Add-PnPListItem {}
        Mock Remove-PnPListItem {}
    }
    It "does not duplicate or recycle an already-seeded sample, regardless of its stored date" {
        . $calendarSeedBlock
        . $calendarCleanupBlock
        Assert-MockCalled Add-PnPListItem -Times 0 -Exactly -Scope It
        Assert-MockCalled Remove-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "does not create a duplicate when an admin approves a seeded draft sample (regression: Title+SampleStatus key)" {
        # Regression test for a bug caught by review of 3.8.1: matching on Title + SampleStatus meant that the
        # normal demo workflow - an admin approving a DRAFT sample by changing its live SampleStatus to
        # "Approved" - broke the "already exists" match on the very next run (the CSV still says "DRAFT -
        # DEMONSTRATION", so Title + "DRAFT - DEMONSTRATION" no longer matches any live row), adding a second,
        # duplicate DRAFT copy of a session someone had just approved. Title alone must still match.
        $script:existingEvents = @(@{ Id = 1; Title = "Late session"; EventDate = [datetime]::SpecifyKind([datetime]"2026-10-16T03:30:00", [DateTimeKind]::Utc); SampleStatus = "Approved" })
        $script:existingTitles = @($script:existingEvents | ForEach-Object { [string]$_["Title"] })
        . $calendarSeedBlock
        Assert-MockCalled Add-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "computes the event date from today plus the offset, not a fixed calendar date" {
        $script:existingEvents = @()
        $script:existingTitles = @()
        . $calendarSeedBlock
        Assert-MockCalled Add-PnPListItem -Times 1 -Exactly -Scope It -ParameterFilter {
            # 2026-10-15 23:30 ET (offset +1 day) is 2026-10-16 03:30Z.
            $Values.EventDate.ToString("yyyy-MM-dd HH:mm") -eq "2026-10-16 03:30"
        }
    }
    It "lets EndOffsetDays cross a day boundary while defaulting to StartOffsetDays for same-day samples" {
        $script:existingEvents = @()
        $script:existingTitles = @()
        $script:eventSeeds = @([pscustomobject]@{ Title = "Same-day session"; StartOffsetDays = "5"; StartTimeET = "12:00"
            EndTimeET = "12:45"; Description = "Draft"; Audience = "Staff"; Format = "Online session"; SampleStatus = "Approved" })
        . $calendarSeedBlock
        Assert-MockCalled Add-PnPListItem -Times 1 -Exactly -Scope It -ParameterFilter {
            $Values.EventDate.ToString("yyyy-MM-dd HH:mm") -eq "2026-10-19 16:00" -and
            $Values.EndDate.ToString("yyyy-MM-dd HH:mm") -eq "2026-10-19 16:45"
        }
    }
    It "uses the configured zone rather than the machine's local zone" {
        $script:siteTimeZone = [TimeZoneInfo]::FindSystemTimeZoneById("Tokyo Standard Time")
        (Get-CalendarLocalDate ([datetime]"2026-10-07T18:00:00Z")) | Should Be "2026-10-08"
    }
    It "treats unspecified CSOM dates as UTC" {
        (Get-CalendarLocalDate ([datetime]"2026-10-08T03:30:00")) | Should Be "2026-10-07"
    }
    It "converts machine-local DateTime values through UTC" {
        $utc = [datetime]::SpecifyKind([datetime]"2026-10-08T03:30:00", [DateTimeKind]::Utc)
        (Get-CalendarLocalDate $utc.ToLocalTime()) | Should Be "2026-10-07"
    }
    It "uses DST offsets for summer and winter" {
        (Get-CalendarLocalDate ([datetime]"2026-07-08T04:30:00Z")) | Should Be "2026-07-08"
        (Get-CalendarLocalDate ([datetime]"2026-01-08T04:30:00Z")) | Should Be "2026-01-07"
    }
    It "seeds new titles and retires only obsolete demonstration rows, never Approved ones" {
        $script:existingEvents += @(@{ Id = 2; Title = "Obsolete"; EventDate = [datetime]"2026-10-08T03:30:00Z"; SampleStatus = "DRAFT - DEMONSTRATION" },
            @{ Id = 3; Title = "Approved and kept"; EventDate = [datetime]"2026-10-08T03:30:00Z"; SampleStatus = "Approved" })
        $script:existingEvents = @($script:existingEvents | Where-Object { $_.Id -ne 1 })
        $script:existingTitles = @($script:existingEvents | ForEach-Object { [string]$_["Title"] })
        . $calendarSeedBlock
        . $calendarCleanupBlock
        Assert-MockCalled Add-PnPListItem -Times 1 -Exactly -Scope It -ParameterFilter {
            $Values.EventDate.ToString("yyyy-MM-dd HH:mm") -eq "2026-10-16 03:30"
        }
        # "Obsolete" is DRAFT and no longer in the seed file, so it is removed; "Approved and kept" is never
        # auto-removed regardless of seed membership, and a rerun must not touch it.
        Assert-MockCalled Remove-PnPListItem -Times 1 -Exactly -Scope It -ParameterFilter { $Identity -eq 2 }
        Assert-MockCalled Remove-PnPListItem -Times 0 -Exactly -Scope It -ParameterFilter { $Identity -eq 3 }
    }
    It "never removes a row whose title left the seed file if its live status is Approved (not DRAFT)" {
        # Regression guard specifically for the approval-protects-from-cleanup claim: an org replacing
        # Training-Calendar.csv (so a previously-shipped title vanishes entirely) must not delete a session an
        # admin already approved, even though its title is no longer anywhere in the new seed file.
        $script:eventSeeds = @()
        $script:seedTitles = @()
        $script:existingEvents = @(@{ Id = 9; Title = "Approved and no longer in CSV"; EventDate = [datetime]"2026-10-08T03:30:00Z"; SampleStatus = "Approved" })
        . $calendarCleanupBlock
        Assert-MockCalled Remove-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "ships every sample title prefixed 'SAMPLE - ', matching the Success Stories convention" {
        # Regression guard: Approved samples show up unfiltered in Home's "Upcoming approved sessions" list
        # (Title, EventDate, RegistrationUrl only - no SampleStatus column), so the title prefix is the only
        # signal a viewer actually sees there that a session is a sample, not a real scheduled one.
        foreach ($csvPath in @(
            (Join-Path $kitRoot "SeedContent\Training-Calendar.csv"),
            (Join-Path $kitRoot "ContentPacks\Government-StateLocal\Content\Training-Calendar.csv")
        )) {
            foreach ($row in @(Import-Csv -LiteralPath $csvPath)) {
                $row.Title | Should Match '^SAMPLE - '
            }
        }
    }
    It "ContentMode Demo seeds samples exactly like the unwrapped block did" {
        $script:ContentMode = "Demo"
        $script:existingEvents = @()
        $script:existingTitles = @()
        . $contentModeBlock
        Assert-MockCalled Add-PnPListItem -Times 1 -Exactly -Scope It
        $eventsAdded | Should Be 1
    }
    It "ContentMode Customer never seeds samples, regardless of what the CSV contains" {
        $script:ContentMode = "Customer"
        $script:existingEvents = @()
        $script:existingTitles = @()
        . $contentModeBlock
        Assert-MockCalled Add-PnPListItem -Times 0 -Exactly -Scope It
        $eventsAdded | Should Be 0
    }
    It "ContentMode Customer removes a previously Demo-seeded sample even if an admin had approved it" {
        # The whole point of this mode: an org switching an already-demoed site to Customer mode must not be
        # left with lingering "SAMPLE - " rows just because someone had approved one during the demo. This is
        # deliberately NOT gated on SampleStatus (unlike the Demo-mode cleanup above, which only ever removes
        # still-DRAFT rows) - "SAMPLE - " in the title is the one signal that survives an approval.
        $script:ContentMode = "Customer"
        $script:existingEvents = @(
            @{ Id = 11; Title = "SAMPLE - Copilot basics"; EventDate = [datetime]"2026-10-08T03:30:00Z"; SampleStatus = "Approved" },
            @{ Id = 12; Title = "SAMPLE - Prompt patterns"; EventDate = [datetime]"2026-10-08T03:30:00Z"; SampleStatus = "DRAFT - DEMONSTRATION" },
            @{ Id = 13; Title = "Real org-authored session"; EventDate = [datetime]"2026-10-08T03:30:00Z"; SampleStatus = "Approved" }
        )
        $script:existingTitles = @($script:existingEvents | ForEach-Object { [string]$_["Title"] })
        . $contentModeBlock
        Assert-MockCalled Remove-PnPListItem -Times 1 -Exactly -Scope It -ParameterFilter { $Identity -eq 11 }
        Assert-MockCalled Remove-PnPListItem -Times 1 -Exactly -Scope It -ParameterFilter { $Identity -eq 12 }
        Assert-MockCalled Remove-PnPListItem -Times 0 -Exactly -Scope It -ParameterFilter { $Identity -eq 13 }
        $eventsRemoved | Should Be 2
    }
}

Describe "ContentMode decides the demo disclaimer, failing safe toward Customer" {
    BeforeEach {
        $script:organizationProfile = [pscustomobject]@{ SampleNotice = "" }
    }
    It "defaults to Customer and is rejected by ValidateSet for any other value" {
        $source | Should Match '\[ValidateSet\("Customer", "Demo"\)\]\[string\]\$ContentMode = "Customer"'
    }
    It "Customer mode clears a configured SampleNotice instead of showing it" {
        $ContentMode = "Customer"
        $SampleNotice = "DEMO SITE - synthetic data only."
        . $sampleNoticeModeBlock
        $SampleNotice | Should Be ""
    }
    It "Demo mode throws rather than silently installing with no disclaimer" {
        $ContentMode = "Demo"
        $SampleNotice = ""
        { . $sampleNoticeModeBlock } | Should Throw "non-empty SampleNotice"
    }
    It "Demo mode keeps a configured SampleNotice" {
        $ContentMode = "Demo"
        $SampleNotice = "DEMO SITE - synthetic data only."
        . $sampleNoticeModeBlock
        $SampleNotice | Should Be "DEMO SITE - synthetic data only."
    }
}

Describe "A content override cannot duplicate the kit's own notice text" {
    # Regression test for a real content-authoring mistake: three customer override files each hardcoded their
    # own literal copy of the configured SampleNotice inside the markdown body, on top of the kit's own
    # automatic prepend/append of that same text. In Demo mode that showed the disclaimer twice; in Customer
    # mode (which only clears the kit's own copy, not literal text an org wrote into its own content) it
    # would have shipped verbatim to a real customer. This guard catches that mistake for any org's content,
    # not just one org's specific wording, by comparing the page's own body against whatever SampleNotice was
    # actually configured - captured into $configuredSampleNotice BEFORE Customer mode blanks the live
    # $SampleNotice to "". An earlier version of this guard checked $SampleNotice directly, which meant it
    # could never fire in Customer mode - exactly the one mode where the leak reaches a real customer.
    It "throws when the page body already contains the configured notice text" {
        $configuredSampleNotice = "DEMO SITE - synthetic data only."
        $ContentMode = "Demo"
        $converted = [pscustomobject]@{ Html = "<p>Some content.</p><p><em>DEMO SITE - synthetic data only.</em></p>" }
        $guideFile = [pscustomobject]@{ Name = "00a-Test-Guide.md" }
        { . $guideDuplicateNoticeBlock } | Should Throw "already contains the configured SampleNotice"
    }
    It "still throws in Customer mode, where the live SampleNotice is blanked but configuredSampleNotice is not" {
        $configuredSampleNotice = "DEMO SITE - synthetic data only."
        $ContentMode = "Customer"
        $converted = [pscustomobject]@{ Html = "<p>Some content.</p><p><em>DEMO SITE - synthetic data only.</em></p>" }
        $guideFile = [pscustomobject]@{ Name = "00a-Test-Guide.md" }
        { . $guideDuplicateNoticeBlock } | Should Throw "already contains the configured SampleNotice"
    }
    It "matches the HTML-encoded form of a notice containing an apostrophe or ampersand" {
        $configuredSampleNotice = "DEMO SITE - Contoso's notice & nothing else."
        $ContentMode = "Demo"
        $converted = [pscustomobject]@{ Html = "<p>" + [System.Net.WebUtility]::HtmlEncode("DEMO SITE - Contoso's notice & nothing else.") + "</p>" }
        $guideFile = [pscustomobject]@{ Name = "00a-Test-Guide.md" }
        { . $guideDuplicateNoticeBlock } | Should Throw "already contains the configured SampleNotice"
    }
    It "does not throw when the page body has no overlap with the configured notice" {
        $configuredSampleNotice = "DEMO SITE - synthetic data only."
        $ContentMode = "Demo"
        $converted = [pscustomobject]@{ Html = "<p>Ordinary guide content with no notice text at all.</p>" }
        { . $guideDuplicateNoticeBlock } | Should Not Throw
    }
    It "does not throw when no notice was ever configured (Customer mode, org never set one)" {
        $configuredSampleNotice = ""
        $ContentMode = "Customer"
        $converted = [pscustomobject]@{ Html = "<p>Some content that happens to mention nothing special.</p>" }
        { . $guideDuplicateNoticeBlock } | Should Not Throw
    }
}

Describe "Customer mode also refuses a fixed 'DEMO ONLY' marker regardless of the configured notice wording" {
    # Second, independent layer: an org's hardcoded text might use older or different wording than whatever
    # SampleNotice happens to be configured right now (for example after a notice-text change between kit
    # versions), which would slip past the exact-text match above. This check does not depend on
    # configuredSampleNotice matching at all - only on ContentMode and a fixed, case-insensitive phrase.
    It "throws in Customer mode when the body contains the literal phrase DEMO ONLY" {
        $ContentMode = "Customer"
        $converted = [pscustomobject]@{ Html = "<p>Contoso DEMO ONLY - not an official site.</p>" }
        $guideFile = [pscustomobject]@{ Name = "00a-Test-Guide.md" }
        { . $guideDemoOnlyMarkerBlock } | Should Throw "contains the literal phrase 'DEMO ONLY'"
    }
    It "matches case-insensitively and across a line-wrapped phrase" {
        $ContentMode = "Customer"
        $converted = [pscustomobject]@{ Html = "<p>demo  only - informal note.</p>" }
        $guideFile = [pscustomobject]@{ Name = "00a-Test-Guide.md" }
        { . $guideDemoOnlyMarkerBlock } | Should Throw "contains the literal phrase 'DEMO ONLY'"
    }
    It "does not throw in Demo mode, where this phrase is expected to be present" {
        $ContentMode = "Demo"
        $converted = [pscustomobject]@{ Html = "<p>Contoso DEMO ONLY - not an official site.</p>" }
        { . $guideDemoOnlyMarkerBlock } | Should Not Throw
    }
    It "does not throw in Customer mode for ordinary content with no such phrase" {
        $ContentMode = "Customer"
        $converted = [pscustomobject]@{ Html = "<p>Ordinary guide content with no notice text at all.</p>" }
        { . $guideDemoOnlyMarkerBlock } | Should Not Throw
    }
}

Describe "Long DisplayName navigation warning substitutes real values, not literal placeholders" {
    # Regression test for a confirmed live bug: this line uses string concatenation (+) together with the
    # format operator (-f) in one expression. -f binds TIGHTER than + (verified directly: "a {0}" + "b {1}" -f
    # $x, $y evaluates as "a {0}" + ("b {1}" -f $x, $y), not ("a {0}" + "b {1}") -f $x, $y). An earlier version
    # of this line relied on the second (wrong) grouping, so only the last concatenated fragment ever got
    # formatted - the {0}/{1} placeholders in the first two fragments printed as literal text on every live
    # install with a DisplayName over 30 characters. Confirmed live during a customer's own validation run.
    BeforeEach {
        $script:navWarnings = @()
        Mock Write-Warning { $script:navWarnings += $Message }
    }
    It "substitutes the real DisplayName and length, with no literal {0} or {1} remaining" {
        $DisplayName = "Contoso Copilot CoE v387 Validation"
        . $longDisplayNameNavWarningBlock
        $navWarnings.Count | Should Be 1
        $navWarnings[0] | Should Not Match '\{0\}|\{1\}'
        $navWarnings[0] | Should Match ([regex]::Escape($DisplayName))
        $navWarnings[0] | Should Match ([string]$DisplayName.Length)
    }
    It "does not warn for a DisplayName of 30 characters or fewer" {
        $DisplayName = "Contoso Copilot CoE"
        . $longDisplayNameNavWarningBlock
        $navWarnings.Count | Should Be 0
    }
}

Describe "Guide omission reconciles navigation by URL, preserving pages" {
    BeforeEach {
        $script:SiteUrl = "https://example.sharepoint.com/sites/CoE"
        $script:hubUrl = "$SiteUrl/SitePages/Copilot-Guides.aspx"
        $script:omitted = "$SiteUrl/SitePages/Guide-Old.aspx"
        $script:guideLinks = @([pscustomobject]@{ Title = "Changed title"; Url = "$SiteUrl/SitePages/Guide-Keep.aspx" })
        $script:nodes = @([pscustomobject]@{ Id = 1; Title = "Renamed hub"; Url = "/sites/CoE/SitePages/Copilot-Guides.aspx" },
            [pscustomobject]@{ Id = 2; Title = "Old"; Url = $omitted },
            [pscustomobject]@{ Id = 3; Title = "Old"; Url = "https://example.org/custom" })
        $script:children = @([pscustomobject]@{ Id = 4; Title = "Old"; Url = "/sites/CoE/SitePages/Guide-Old.aspx" },
            [pscustomobject]@{ Id = 5; Title = "Original title"; Url = "/sites/CoE/SitePages/Guide-Keep.aspx" })
        $script:navWrites = 0
        $context = [pscustomobject]@{}
        $context | Add-Member ScriptMethod ExecuteQuery { $script:navWrites++ }
        foreach ($node in $script:children) {
            $node | Add-Member NoteProperty Context $context
            $node | Add-Member ScriptMethod Update {}
        }
        Mock Get-PnPNavigationNode { $script:nodes }
        Mock Get-PnPProperty {
            $ClientObject | Add-Member NoteProperty Children $script:children -Force
            Write-Output -NoEnumerate $script:children
        }
        Mock Remove-PnPNavigationNode {}
        Mock Add-PnPNavigationNode { [pscustomobject]@{ Id = 9; Title = $Title; Url = $Url } }
    }
    It "removes omitted top-level and child links, not unrelated same-title links" {
        Sync-GuideNavigation offline $hubUrl $guideLinks @($omitted)
        Assert-MockCalled Remove-PnPNavigationNode -Times 2 -Exactly -Scope It
        Assert-MockCalled Remove-PnPNavigationNode -Times 0 -Exactly -Scope It -ParameterFilter { $Identity -eq 3 }
        Assert-MockCalled Add-PnPNavigationNode -Times 0 -Exactly -Scope It
    }
    It "does not treat an empty non-enumerated CSOM-style collection as a navigation node" {
        $script:children = @()
        Sync-GuideNavigation offline $hubUrl @() @()
        Assert-MockCalled Add-PnPNavigationNode -Times 0 -Exactly -Scope It
        Assert-MockCalled Remove-PnPNavigationNode -Times 0 -Exactly -Scope It
    }
    It "adds guide links when the loaded child collection is empty" {
        $script:children = @()
        Sync-GuideNavigation offline $hubUrl $guideLinks @()
        Assert-MockCalled Add-PnPNavigationNode -Times 1 -Exactly -Scope It -ParameterFilter {
            $Parent -eq 1 -and $Url -eq $script:guideLinks[0].Url
        }
    }
    It "does not adopt an unrelated same-title hub" {
        $script:nodes = @([pscustomobject]@{ Id = 6; Title = "Copilot guides"; Url = "https://example.org/custom" })
        $script:children = @()
        Sync-GuideNavigation offline $hubUrl $guideLinks @()
        Assert-MockCalled Add-PnPNavigationNode -Times 1 -Exactly -Scope It -ParameterFilter { $Url -eq $script:hubUrl }
    }
    It "updates a renamed guide title by exact URL without adding duplicate navigation" {
        Sync-GuideNavigation offline $hubUrl $guideLinks @()
        $children[1].Title | Should Be "Changed title"
        $navWrites | Should Be 1
        Assert-MockCalled Add-PnPNavigationNode -Times 0 -Exactly -Scope It
    }
    It "does not submit unchanged titles" {
        $script:children[1].Title = "Changed title"
        Sync-GuideNavigation offline $hubUrl $guideLinks @()
        $navWrites | Should Be 0
    }
    It "allows all guides to be omitted without deleting their pages" {
        Sync-GuideNavigation offline $hubUrl @() @($omitted, $guideLinks[0].Url)
        Assert-MockCalled Remove-PnPNavigationNode -Times 3 -Exactly -Scope It
        $source.Contains('if ($guideFiles.Count -eq 0) { throw') | Should Be $false
        $source.Contains('OmittedPagesPreserved = $omittedGuideUrls') | Should Be $true
    }
    It "recognizes encoded server-relative targets but not other sites" {
        (Get-ManagedNavigationUrl "/sites/CoE/SitePages/Guide-A%20B.aspx") | Should Be "$SiteUrl/SitePages/Guide-A B.aspx"
        (Get-ManagedNavigationUrl "/sites/Other/SitePages/Guide-Old.aspx") | Should Not Be (Get-ManagedNavigationUrl $omitted)
    }
}

Describe "Department Champions navigation opens the information page" {
    BeforeEach {
        $script:SiteUrl = "https://example.sharepoint.com/sites/CoE"
        $script:pageUrl = "$SiteUrl/SitePages/Meet-your-Champions.aspx"
        $script:directoryUrl = "$SiteUrl/Lists/DepartmentChampions"
        $script:nodes = @(
            [pscustomobject]@{ Id = 1; Title = "Department Champions"; Url = "/sites/CoE/Lists/DepartmentChampions/By%20department.aspx" },
            [pscustomobject]@{ Id = 2; Title = "Department Champions"; Url = "https://elsewhere.example/sites/Other/Lists/DepartmentChampions/AllItems.aspx" }
        )
        $script:removedNodes = @()
        $script:navUpdates = 0
        $context = [pscustomobject]@{}
        $context | Add-Member ScriptMethod ExecuteQuery { $script:navUpdates++ }
        Mock Get-PnPNavigationNode { $script:nodes }
        Mock Remove-PnPNavigationNode {
            $script:removedNodes += $Identity
            $script:nodes = @($script:nodes | Where-Object Id -ne $Identity)
        }
        Mock Add-PnPNavigationNode {
            $node = [pscustomobject]@{ Id = 3; Title = $Title; Url = $Url }
            $script:nodes += $node
            $node
        }
    }
    It "replaces the auto-added raw-list link with the page link idempotently" {
        Sync-ChampionPageNavigation offline $pageUrl $directoryUrl
        Sync-ChampionPageNavigation offline $pageUrl $directoryUrl

        $removedNodes | Should Be @(1)
        @($nodes | Where-Object { (Get-ManagedNavigationUrl $_.Url) -eq (Get-ManagedNavigationUrl $pageUrl) }).Count | Should Be 1
        @($nodes | Where-Object Id -eq 2).Count | Should Be 1
        Assert-MockCalled Add-PnPNavigationNode -Times 1 -Exactly -Scope It -ParameterFilter {
            $Title -eq "Department Champions" -and $Url -eq $script:pageUrl
        }
    }
    It "renames an existing page link and leaves unrelated navigation untouched" {
        $pageNode = [pscustomobject]@{ Id = 4; Title = "Meet a Champion"; Url = "/sites/CoE/SitePages/Meet-your-Champions.aspx" }
        $pageNode | Add-Member NoteProperty Context $context
        $pageNode | Add-Member ScriptMethod Update {}
        $script:nodes += $pageNode

        Sync-ChampionPageNavigation offline $pageUrl $directoryUrl

        $pageNode.Title | Should Be "Department Champions"
        $navUpdates | Should Be 1
        @($nodes | Where-Object Id -eq 2).Count | Should Be 1
        Assert-MockCalled Add-PnPNavigationNode -Times 0 -Exactly -Scope It
    }
    It "removes the duplicate root page only when the TaskFirst Community menu owns it" {
        $script:nodes += [pscustomobject]@{ Id = 4; Title = "Department Champions"; Url = $pageUrl }
        Sync-ChampionPageNavigation offline $pageUrl $directoryUrl -GroupUnderCommunity

        $removedNodes | Should Be @(1, 4)
        @($nodes | Where-Object Id -eq 2).Count | Should Be 1
        @($nodes | Where-Object { (Get-ManagedNavigationUrl $_.Url) -eq $pageUrl }).Count | Should Be 0
        Assert-MockCalled Add-PnPNavigationNode -Times 0 -Exactly -Scope It
        $source | Should Match '-GroupUnderCommunity:\(\$navOrder -eq "TaskFirst"\)'
    }
    It "keeps the backing list off Quick Launch and wires the page link into completion" {
        $championListStart = $source.IndexOf('$listTitle = "Department Champions"')
        $fieldSpecsStart = $source.IndexOf('$fieldSpecs = @(', $championListStart)
        $championListBlock = $source.Substring($championListStart, $fieldSpecsStart - $championListStart)
        $championListBlock.Contains("-OnQuickLaunch") | Should Be $false
        $source.Contains('Sync-ChampionPageNavigation -SiteConnection $site') | Should Be $true
    }
}

Describe "Optional policy report and organization success videos" {
    BeforeEach {
        Mock Write-Warning {}
    }
    It "removes the stale policy report before generating either governance page" {
        $reset = $source.IndexOf('$report.Remove("PolicyDraft")')
        $loop = $source.LastIndexOf('foreach ($kind in @("program", "leadership"))')
        ($reset -ge 0 -and $reset -lt $loop) | Should Be $true
        $report = [ordered]@{ PolicyDraft = @{ Url = "stale" }; Governance = @() }
        . ([scriptblock]::Create('$report.Remove("PolicyDraft")'))
        ($report.Keys -contains "PolicyDraft") | Should Be $false
    }
    It "saves a successful deployment report only after the final security checks" {
        $source.LastIndexOf('Write-CoESecurityPosture -SiteUrl') |
            Should BeLessThan $source.LastIndexOf('$report | ConvertTo-Json')
        $source | Should Match '\$report.SecurityChecks = .*Passed = \$true'
    }
    It "omitted policy code preserves files and never emits a stale report link" {
        $block = Get-CompletionBlock 'if ([string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($policyPath)))'
        $block.ToString() | Should Match "preserved"
        $block.ToString() | Should Not Match "Remove-PnPFile|PolicyDraft\s*="
        $source | Should Match 'if \(\$kind -eq "leadership" -and \(\$report.Keys -contains "PolicyDraft"\)'
    }
    It "routes success stories through the shared approval-only catalog without deleting customer rows" {
        $source | Should Match 'Sync-CoESuccessStoryCatalog -Connection \$site'
        $source | Should Match '\$storyCatalog.Views.Published'
        $source | Should Not Match '\$storyCleanupBlock|foreach \(\$item in \$existingStoryItems\)'
        # Regression guard for a confirmed live bug: a fresh Customer-mode install still seeded the kit's own
        # illustrative SAMPLE success stories, because the call site never told the catalog function which
        # ContentMode was active. The function itself defaults to Demo, so omitting this parameter here would
        # silently keep seeding SAMPLE rows into every Customer-mode install.
        $source | Should Match '-ContentMode \$ContentMode'
    }
    It "never posts or links the kit mock video regardless of other videos" {
        $source | Should Match 'if \(\$section.channel -eq "Success Stories" -and \$seedFile.Name -like "MOCK-\*"\) \{ continue \}'
        $source | Should Match '\$hostedList -and \$section.channel -ne "Success Stories"'
        $config = Get-Content (Join-Path $kitRoot "SeedContent\Sections\Sections.json") -Raw | ConvertFrom-Json
        @($config.successStories | Where-Object { $_.Status -ne "Submitted" -or $_.Video -or $_.TimeSaved }).Count | Should Be 0
    }
}

Describe "Organization tokens and configured support routes" {
    BeforeEach {
        $script:SiteUrl = "https://example.sharepoint.com/sites/CoE"
        $script:orgSettings = [pscustomobject]@{ OrgName = 'Research & Development "Campus"'; OrgNoun = "organization" }
        $script:orgName = $orgSettings.OrgName
        $script:orgNoun = $orgSettings.OrgNoun
        $script:ShortName = "RDC"
        $script:SupportEmail = "coe@example.edu"
        $script:orgLinks = [pscustomobject]@{}
        $script:supportRoutes = @(Get-CoESupportRoutes $orgLinks $SiteUrl)
    }
    It "preserves JSON escaping even when the organization name ends with a quote" {
        $json = Resolve-OrgTokens '{"name":"{{OrgName}}","noun":"{{OrgNoun}}"}' -Json
        ($json | ConvertFrom-Json).name | Should Be 'Research & Development "Campus"'
        $json | Should Not Match 'Test tenant|CoE33'
    }
    It "turns missing organizational routes into clearly labelled links to setup guidance" {
        $text = Resolve-OrgTokens '{{Link:ServiceDesk|Open a ticket}} {{Link:DataSafetyIncident|Report an incident}}' -Markdown
        $text | Should Match '\[Open a ticket - route not configured\]\(https://example.sharepoint.com/sites/CoE/SitePages/Give-Feedback.aspx#configured-support-routes\)'
        $text | Should Match '\[Report an incident - route not configured\]'
    }
    It "uses the distinct configured incident route instead of substituting the service desk" {
        $script:orgLinks = [pscustomobject]@{ ServiceDesk = "https://help.example.edu/tickets"; DataSafetyIncident = "https://security.example.edu/report" }
        $script:supportRoutes = @(Get-CoESupportRoutes $orgLinks $SiteUrl)
        (Resolve-OrgTokens '{{Link:DataSafetyIncident|Report an incident}}' -Markdown) |
            Should Be '[Report an incident](https://security.example.edu/report)'
    }
    It "keeps publication notices and purpose sentences in a separate introductory part" {
        $source | Should Match '\-Html \$sectionHtml -IntroHtml \$sectionIntro'
        $source | Should Match 'if \(\$IntroHtml\)'
        # PageTitleWebPart renders the title inline instead of Default's large banner, which left a tall empty
        # gap above the body on every tool and guide page.
        $source | Should Match 'HeaderType PageTitleWebPart -Publish'
        $source | Should Not Match 'HeaderType None'
        $source | Should Not Match 'HeaderType Default -HeaderLayoutType NoImage'
    }
    It "wires the same profile and explicit repair switch through all entry points" {
        $source | Should Match 'Get-CoEOrganizationProfile -Settings \$orgSettings -Overrides \$profileOverrides'
        $source | Should Match 'if \(\$RepairCapturedPages\)'
        (Get-Content (Join-Path $kitRoot "02_Install-CopilotCoE.ps1") -Raw) | Should Match '\-RepairCapturedPages:\(!\$ResumeExisting\)'
        (Get-Content (Join-Path $kitRoot "03_Update-CoEContent.ps1") -Raw) | Should Match 'if \(\$RepairCapturedPages\) \{ \$completeArgs.RepairCapturedPages = \$true \}'
    }
}

Describe "Comments are disabled on every kit-managed page" {
    BeforeEach {
        $script:SiteUrl = "https://example.sharepoint.com/sites/CoE"
        $script:disabledPages = @()
        $script:siteWideCall = $null
        Mock Get-PnPPage {
            @(
                [pscustomobject]@{ Name = "TrainingHome.aspx" },
                [pscustomobject]@{ Name = "Tool-Copilot-Studio.aspx" },
                [pscustomobject]@{ Name = "Meet-your-Champions.aspx" }
            )
        }
        Mock Set-PnPPage {
            if ($CommentsEnabled -eq $false) { $script:disabledPages += $Identity }
        }
        Mock Set-PnPWeb {
            if ($CommentsOnSitePagesDisabled -eq $true) { $script:siteWideCall = $true }
        }
    }
    It "turns comments off site-wide so future pages default to off, and for every existing page" {
        Disable-CoEPageComments offline
        $siteWideCall | Should Be $true
        $disabledPages | Should Be @("TrainingHome.aspx", "Tool-Copilot-Studio.aspx", "Meet-your-Champions.aspx")
        Assert-MockCalled Set-PnPWeb -Times 1 -Exactly -Scope It
        Assert-MockCalled Set-PnPPage -Times 3 -Exactly -Scope It
    }
}

Describe "The Department Champions legacy link is fully removed" {
    It "adds Department Champions to the mega-menu migration's legacy-title removal list" {
        $hubSource = Get-Content (Join-Path $kitRoot "Internal\HubExperience.ps1") -Raw
        $hubSource | Should Match '"Give Feedback", "Meet a Champion", "Department Champions",'
        $hubSource | Should Match 'Lists/DepartmentChampions/AllItems\.aspx'
    }
    It "flags a leftover top-level Department Champions node as an old template section" {
        $checker = Get-Content (Join-Path $kitRoot "Test-CoEInstall.ps1") -Raw
        $checker | Should Match '"Learning Series", "Recycle bin", "Department Champions"'
    }
}

Describe "Meet a Champion button uses a distinct icon, not the rotation's first entry" {
    It "pins the Meet a Champion Quick Links icon to 'calendarmirrored', never the Copilot Chat tile's 'editnote'" {
        # Regression test for a live review finding: a reviewer flagged Copilot Chat, Copilot Studio,
        # Governance and Meet a Champion as a cluster of "near-identical note icons" on Home. Meet a Champion
        # previously used (Get-CoEQuickLinksIconNames)[0] - the rotation's first entry, "editnote" - which is
        # also Copilot Chat's fixed icon in the Copilot tools grid two sections up (see Get-CoEToolIconName).
        # A fixed, deliberate icon name here (not a rotation index) keeps this from silently drifting back to
        # a collision if the rotation list itself is ever reordered.
        $completionSource = Get-Content (Join-Path $kitRoot "Internal\Complete-CopilotCoE.ps1") -Raw
        $completionSource | Should Match 'Title = "Meet a Champion"; Description = "Find a Copilot champion near you"\s*\r?\n\s*Url = \$championsLink\[0\]\.Url; Icon = "calendarmirrored"'
        $completionSource | Should Not Match 'Url = \$championsLink\[0\]\.Url; Icon = \(Get-CoEQuickLinksIconNames\)\[0\]'
    }
}

Describe "Governance draft Word documents auto-hyperlink bare URLs" {
    # Regression coverage for a live gap: governance drafts (for example Contoso-Policy-Alignment-DRAFT.txt)
    # are published as hosted Word documents via Write-ManagedDocx/New-SimpleDocx, not markdown-converted HTML
    # pages. New-SimpleDocx previously wrote every paragraph as a single plain <w:r><w:t> run with no hyperlink
    # relationship at all, and Get-DocxParagraphs normalizes markdown link syntax ([label](url)) down to plain
    # "label (url)" text rather than a real link - so a policy URL in either plain-text or markdown-link form
    # rendered as inert, non-clickable text in the resulting document, regardless of source formatting.
    BeforeEach {
        $script:docxPath = Join-Path ([IO.Path]::GetTempPath()) ("coe-test-" + [guid]::NewGuid().ToString("N") + ".docx")
    }
    AfterEach {
        Remove-Item -LiteralPath $script:docxPath -ErrorAction SilentlyContinue
    }
    function Get-CoETestDocxPart([string]$Path, [string]$EntryName) {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $entry = $zip.GetEntry($EntryName)
            $reader = [IO.StreamReader]::new($entry.Open())
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $zip.Dispose() }
    }
    It "keeps the round-tripped visible text identical to the plain-text draft (Write-ManagedDocx's unchanged-draft check still works)" {
        $text = "ILLUSTRATIVE DRAFT`n`nAuthoritative sources:`n  Contoso AI and Generative Technology Use:`n    https://www.it.contoso.edu/ai-and-generative-technology-use"
        New-SimpleDocx -Text $text -Path $script:docxPath -Title "Test"
        $desired = ((Get-DocxParagraphs $text) | ForEach-Object Text) -join "`n"
        $bytes = [IO.File]::ReadAllBytes($script:docxPath)
        $roundTripped = Read-DocxText $bytes
        $roundTripped | Should Be $desired
    }
    It "writes a real external hyperlink relationship for the URL, not just colored inert text" {
        $text = "See the policy:`n  https://www.it.contoso.edu/ai-and-generative-technology-use"
        New-SimpleDocx -Text $text -Path $script:docxPath -Title "Test"
        $document = Get-CoETestDocxPart $script:docxPath "word/document.xml"
        $rels = Get-CoETestDocxPart $script:docxPath "word/_rels/document.xml.rels"
        $document | Should Match '<w:hyperlink r:id="rIdUrl2">'
        $rels | Should Match 'Id="rIdUrl2"[^>]*Type="http://schemas\.openxmlformats\.org/officeDocument/2006/relationships/hyperlink"[^>]*Target="https://www\.it\.contoso\.edu/ai-and-generative-technology-use"[^>]*TargetMode="External"'
    }
    It "gives multiple URLs across multiple paragraphs unique relationship ids that never collide with styles.xml's rId1" {
        $text = "First:`n  https://provost.contoso.edu/content/office-senior-vice-provost/ai-policy`nSecond:`n  https://universitypolicies.contoso.edu/content/data-classification-policy"
        New-SimpleDocx -Text $text -Path $script:docxPath -Title "Test"
        $rels = Get-CoETestDocxPart $script:docxPath "word/_rels/document.xml.rels"
        $rels | Should Match 'Id="rId1"[^>]*Type="http://schemas\.openxmlformats\.org/officeDocument/2006/relationships/styles"'
        $hyperlinkIds = @([regex]::Matches($rels, 'Id="(rIdUrl\d+)"') | ForEach-Object { $_.Groups[1].Value })
        $hyperlinkIds.Count | Should Be 2
        ($hyperlinkIds | Select-Object -Unique).Count | Should Be 2
    }
    It "excludes trailing sentence punctuation from the hyperlink target" {
        $text = "Read the policy (https://provost.contoso.edu/content/office-senior-vice-provost/ai-policy)."
        New-SimpleDocx -Text $text -Path $script:docxPath -Title "Test"
        $rels = Get-CoETestDocxPart $script:docxPath "word/_rels/document.xml.rels"
        $rels | Should Match 'Target="https://provost\.contoso\.edu/content/office-senior-vice-provost/ai-policy"'
        $rels | Should Not Match 'Target="https://provost\.contoso\.edu/content/office-senior-vice-provost/ai-policy\)"'
        $rels | Should Not Match 'Target="https://provost\.contoso\.edu/content/office-senior-vice-provost/ai-policy\."'
    }
    It "leaves a paragraph without a URL as a single plain run, unaffected" {
        $text = "This paragraph has no links at all."
        New-SimpleDocx -Text $text -Path $script:docxPath -Title "Test"
        $document = Get-CoETestDocxPart $script:docxPath "word/document.xml"
        $document | Should Not Match '<w:hyperlink'
        $document | Should Match '<w:r><w:t xml:space="preserve">This paragraph has no links at all\.</w:t></w:r>'
    }
    It "auto-hyperlinks the URL left behind by markdown-link normalization (label (url) form)" {
        # Get-DocxParagraphs converts [label](url) markdown into plain "label (url)" text before New-SimpleDocx
        # ever sees it - confirms the bare URL inside that parenthetical form still gets hyperlinked.
        $text = "[Contoso AI Policy](https://www.it.contoso.edu/ai-and-generative-technology-use)"
        $paragraphs = Get-DocxParagraphs $text
        $paragraphs[0].Text | Should Be "Contoso AI Policy (https://www.it.contoso.edu/ai-and-generative-technology-use)"
        New-SimpleDocx -Text $text -Path $script:docxPath -Title "Test"
        $rels = Get-CoETestDocxPart $script:docxPath "word/_rels/document.xml.rels"
        $rels | Should Match 'Target="https://www\.it\.contoso\.edu/ai-and-generative-technology-use"'
    }
}
