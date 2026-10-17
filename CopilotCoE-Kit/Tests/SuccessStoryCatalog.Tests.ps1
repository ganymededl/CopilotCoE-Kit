# Offline Windows PowerShell/Pester 3 tests. Unmocked external reads and writes fail closed.
Set-StrictMode -Version Latest
$kitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $kitRoot "Internal\SecurityPosture.ps1")
. (Join-Path $kitRoot "Internal\AdoptionCatalogs.ps1")
. (Join-Path $kitRoot "Internal\SuccessStoryCatalog.ps1")

function Get-PnPList { [CmdletBinding()] param($Identity, $Includes, $Connection) throw "Unmocked list read" }
function New-PnPList { [CmdletBinding()] param($Title, $Template, $Url, [switch]$EnableVersioning, $Connection) throw "Unmocked list creation" }
function Set-PnPList { [CmdletBinding()] param($Identity, $EnableVersioning, $EnableModeration, $DraftVersionVisibility,
    [switch]$BreakRoleInheritance, [switch]$CopyRoleAssignments, [switch]$ClearSubscopes, $Connection) throw "Unmocked list mutation" }
function Get-PnPField { [CmdletBinding()] param($List, $Identity, $Connection) throw "Unmocked field read" }
function Add-PnPFieldFromXml { [CmdletBinding()] param($List, $FieldXml, $Connection) throw "Unmocked field insertion" }
function Set-PnPField { [CmdletBinding()] param($List, $Identity, $Values, $Connection) throw "Unmocked field update" }
function Get-PnPListItem { [CmdletBinding()] param($List, $Fields, $Includes, $PageSize, $Connection) throw "Unmocked item read" }
function Add-PnPListItem { [CmdletBinding()] param($List, $Values, $Connection) throw "Unmocked item insertion" }
function Set-PnPListItem { [CmdletBinding()] param($List, $Identity, $Values, $UpdateType, $Connection) throw "Unmocked item update" }
function Remove-PnPListItem { [CmdletBinding()] param($List, $Identity, [switch]$Force, $Connection) throw "Unmocked item deletion" }
function Get-PnPView { [CmdletBinding()] param($List, $Identity, $Includes, $Connection) throw "Unmocked view read" }
function Add-PnPView { [CmdletBinding()] param($List, $Title, $Fields, $Query, $RowLimit, [switch]$Paged,
    [switch]$SetAsDefault, $Connection) throw "Unmocked view insertion" }
function Set-PnPView { [CmdletBinding()] param($List, $Identity, $Fields, $Values, $Connection) throw "Unmocked view update" }
function Get-PnPProperty { [CmdletBinding()] param($ClientObject, $Property, $Connection) throw "Unmocked CSOM property read" }
function Get-PnPContext { [CmdletBinding()] param($Connection) throw "Unmocked CSOM context" }
function Invoke-PnPQuery { [CmdletBinding()] param($Connection) throw "Unmocked CSOM write" }
function Get-PnPFile { [CmdletBinding()] param($Url, [switch]$AsListItem, $Connection) throw "Unmocked file read" }
function Remove-PnPFile { [CmdletBinding()] param($ServerRelativeUrl, [switch]$Force, $Connection) throw "Unmocked file deletion" }
function Get-PnPWeb { [CmdletBinding()] param($Includes, $Connection) throw "Unmocked web read" }
function New-PnPUser { [CmdletBinding()] param($LoginName, $Connection) throw "Unmocked principal registration" }
function Get-PnPGroup { [CmdletBinding()] param($Identity, $Connection) throw "Unmocked group read" }
function New-PnPGroup { [CmdletBinding()] param($Title, $Description, $Connection) throw "Unmocked group creation" }
function Get-PnPGroupMember { [CmdletBinding()] param($Group, $Connection) throw "Unmocked group member read" }
function Add-PnPGroupMember { [CmdletBinding()] param($LoginName, $Group, $Connection) throw "Unmocked group member write" }
function Set-PnPListPermission { [CmdletBinding()] param($Identity, $Group, $User, $AddRole, $RemoveRole, $Connection) throw "Unmocked list permission write" }
function Get-PnPTenantId { [CmdletBinding()] param($Connection) throw "Unmocked tenant read" }
function Get-PnPAccessToken { [CmdletBinding()] param($ResourceTypeName, [switch]$Decoded, $Connection) throw "Unmocked token read" }
function Invoke-PnPGraphMethod { [CmdletBinding()] param($Url, $Method, $Connection) throw "Unmocked Graph request" }
function Add-PnPRoleDefinition { [CmdletBinding()] param($RoleName, $Clone, $Include, $Description, $Connection) throw "Unmocked role creation" }
function Get-PnPRoleDefinition { [CmdletBinding()] param($Identity, $Connection) throw "Unmocked role read" }

function New-CoEStoryTestSeed([string]$Title = "SAMPLE - Drafting a rubric") {
    [pscustomobject]@{ Title = $Title; Audience = "Faculty"; Task = "Draft a rubric, then check the criteria."
        TimeSaved = ""; Video = ""; Status = "Submitted" }
}
function New-CoEStoryTestItem([int]$Id, [string]$Title, [string]$Status = "Published", [int]$Moderation = 0, $Video = $null) {
    [pscustomobject]@{ Id = $Id; HasUniqueRoleAssignments = $false
        FieldValues = @{ Title = $Title; Audience = "Staff"; StoryTask = "Customer story"
            TimeSaved = "Customer-measured result"; StoryStatus = $Status; "_ModerationStatus" = $Moderation; StoryVideo = $Video } }
}
function Test-CoEStoryPredicate([System.Xml.XmlNode]$Node, [hashtable]$Values) {
    $children = @($Node.ChildNodes | Where-Object NodeType -eq Element)
    switch ($Node.Name) {
        "And" { return (Test-CoEStoryPredicate $children[0] $Values) -and (Test-CoEStoryPredicate $children[1] $Values) }
        "Or" { return (Test-CoEStoryPredicate $children[0] $Values) -or (Test-CoEStoryPredicate $children[1] $Values) }
        "IsNull" { return $null -eq $Values[$Node.FieldRef.Name] }
        "Eq" { return $null -ne $Values[$Node.FieldRef.Name] -and $Values[$Node.FieldRef.Name] -eq $Node.Value.InnerText }
        "Neq" { return $null -ne $Values[$Node.FieldRef.Name] -and $Values[$Node.FieldRef.Name] -ne $Node.Value.InnerText }
        default { throw "Unsupported test CAML operator '$($Node.Name)'." }
    }
}
function Initialize-CoEStoryTestMocks {
    $script:storyLists = @()
    $script:storyFields = @{}
    $script:storyItems = @{}
    $script:storyViews = @{}
    $script:storyAssignments = @()
    $script:storyGroupExists = $false
    $script:storyGroupMembers = @()
    $script:storyRoleExists = $false
    $script:storyContext = [pscustomobject]@{ Web = [pscustomobject]@{} }
    $script:storyContext | Add-Member ScriptMethod Load { param($Object) }
    $script:storyContext.Web | Add-Member ScriptMethod GetList {
        param($Url)
        @($script:storyLists | Where-Object { $_.RootFolder.ServerRelativeUrl -eq $Url })[0]
    }
    Mock Get-PnPContext { $script:storyContext }
    Mock Invoke-PnPQuery {}
    Mock Get-PnPList {
        $found = if ($Identity) { @($script:storyLists | Where-Object { $_.Id -eq $Identity }) } else { @($script:storyLists) }
        foreach ($list in $found) {
            $assignments = @($script:storyAssignments | ForEach-Object {
                [pscustomobject]@{ Member = [pscustomobject]@{ Id = $_.PrincipalId }
                    RoleDefinitionBindings = @($_.RoleIds | ForEach-Object { [pscustomobject]@{ Name = $_ } }) } })
            $list | Add-Member NoteProperty RoleAssignments $assignments -Force
            $list
        }
    }
    Mock New-PnPList {
        if ($Connection -ne "offline" -or $Template -ne "GenericList" -or -not $EnableVersioning) { throw "Unexpected list creation" }
        $list = [pscustomobject]@{ Id = "stories"; Title = $Title; BaseTemplate = 100; EnableVersioning = $true
            EnableModeration = $false; DraftVersionVisibility = "Reader"; HasUniqueRoleAssignments = $false
            RootFolder = [pscustomobject]@{ ServerRelativeUrl = "/sites/CoE/$Url" } }
        $script:storyLists += $list
        $titleField = [pscustomobject]@{ InternalName = "Title"; TypeAsString = "Text"; Choices = @(); Title = "Title"; CustomFormatter = ""; DefaultValue = "" }
        $titleField | Add-Member ScriptMethod Update {}
        $script:storyFields[$list.Id] = @($titleField)
        $script:storyItems[$list.Id] = @()
        $script:storyViews[$list.Id] = @([pscustomobject]@{ Id = "all"; Title = "All Items"; ViewQuery = ""
            DefaultView = $true; Fields = @("LinkTitle"); CustomFormatter = ""
            ServerRelativeUrl = "/sites/CoE/$Url/AllItems.aspx" })
        $script:storyViews[$list.Id][0] | Add-Member ScriptMethod Update {}
    }
    Mock Set-PnPList {
        $list = @($script:storyLists | Where-Object Id -eq $Identity)[0]
        if ($BreakRoleInheritance) {
            if (-not $CopyRoleAssignments -or $ClearSubscopes) { throw "ACL widening or reset" }
            $list.HasUniqueRoleAssignments = $true
            # Real SharePoint does not copy Limited Access entries when inheritance is broken.
            $script:storyAssignments = @($script:storyAssignments | Where-Object { $_.RoleIds -notcontains "Limited Access" })
        } else {
            if ($EnableVersioning -ne $true -or $EnableModeration -ne $true -or $DraftVersionVisibility -ne "Approver") {
                throw "Unsafe content approval settings"
            }
            $list.EnableVersioning = $true
            $list.EnableModeration = $true
            $list.DraftVersionVisibility = "Approver"
        }
    }
    Mock Get-PnPListItem { $script:storyItems[$List] }
    Mock Get-PnPField {
        if ($Identity) { $script:storyFields[$List] | Where-Object InternalName -eq $Identity }
        else { $script:storyFields[$List] }
    }
    Mock Get-PnPProperty {}
    Mock Add-PnPFieldFromXml {
        if (-not $script:storyLists[0].EnableModeration) { throw "Field insertion before moderation" }
        $xml = [xml]$FieldXml
        $field = [pscustomobject]@{ InternalName = [string]$xml.Field.Name; TypeAsString = [string]$xml.Field.Type
            Choices = @($xml.SelectNodes("//CHOICE") | ForEach-Object InnerText); SchemaXml = $FieldXml
            Title = [string]$xml.Field.DisplayName; CustomFormatter = ""; DefaultValue = "" }
        $field | Add-Member ScriptMethod Update {}
        $script:storyFields[$List] += $field
        $field
    }
    Mock Set-PnPField {
        $field = @($script:storyFields[$List] | Where-Object InternalName -eq $Identity)[0]
        foreach ($key in $Values.Keys) {
            if ($key -notin @("Choices", "DefaultValue")) { throw "Unexpected field alteration '$key'" }
            $field | Add-Member NoteProperty $key $Values[$key] -Force
        }
    }
    Mock New-CoECatalogUrlValue { [pscustomobject]@{ Url = $Url; Description = $Description } }
    Mock Add-PnPListItem {
        if (-not $script:storyLists[0].EnableModeration -or $Values.StoryStatus -ne "Submitted" -or $Values["_ModerationStatus"] -ne 2) {
            throw "Unsafe story insertion"
        }
        $id = 1
        if ($script:storyItems[$List].Count) { $id = 1 + ($script:storyItems[$List] | Measure-Object Id -Maximum).Maximum }
        $item = [pscustomobject]@{ Id = [int]$id; FieldValues = $Values.Clone(); HasUniqueRoleAssignments = $false }
        $script:storyItems[$List] += $item
        $item
    }
    Mock Set-PnPListItem {
        if ($UpdateType -ne "SystemUpdate" -or $Values.Count -ne 1 -or -not $Values.ContainsKey("_ModerationStatus")) {
            throw "Unexpected customer content/version alteration"
        }
        $item = @($script:storyItems[$List] | Where-Object Id -eq $Identity)[0]
        $item.FieldValues["_ModerationStatus"] = $Values["_ModerationStatus"]
        $item
    }
    Mock Get-PnPView {
        if ($Identity) { $script:storyViews[$List] | Where-Object Id -eq $Identity }
        else { $script:storyViews[$List] }
    }
    Mock Add-PnPView {
        $view = [pscustomobject]@{ Id = "view-$Title"; Title = $Title; Fields = $Fields; ViewQuery = $Query
            DefaultView = [bool]$SetAsDefault; CustomFormatter = ""
            ServerRelativeUrl = "/sites/CoE/Lists/CopilotSuccessStories/$Title.aspx" }
        $view | Add-Member ScriptMethod Update {}
        if ($SetAsDefault) { foreach ($old in $script:storyViews[$List]) { $old.DefaultView = $false } }
        $script:storyViews[$List] += $view
        $view
    }
    Mock Set-PnPView {
        $view = @($script:storyViews[$List] | Where-Object Id -eq $Identity)[0]
        if ($null -ne $Fields) { $view.Fields = $Fields }
        if ($Values.ContainsKey("RowLimit") -and $Values.RowLimit -isnot [uint32]) { throw "RowLimit must be UInt32" }
        if ($Values.ContainsKey("DefaultView") -and $Values.DefaultView) {
            foreach ($old in $script:storyViews[$List]) { $old.DefaultView = $false }
        }
        foreach ($key in $Values.Keys) { $view | Add-Member NoteProperty $key $Values[$key] -Force }
        $view
    }
    Mock Write-Host {}
    Mock Start-Sleep {}
    Mock Test-CoECatalogReviewRole { $true }
    Mock Get-PnPRoleDefinition {
        if ($Identity -eq "Contribute") { return [pscustomobject]@{ Name = "Contribute"; BasePermissions = $null } }
        if ($Identity -eq "CoE Catalog Reviewer" -and $script:storyRoleExists) { return [pscustomobject]@{ Name = "CoE Catalog Reviewer"; BasePermissions = $null } }
    }
    Mock Add-PnPRoleDefinition { $script:storyRoleExists = $true }
    Mock Get-PnPGroup { if ($script:storyGroupExists) { [pscustomobject]@{ Id = 30; Title = "CoE Catalog Reviewers" } } }
    Mock New-PnPGroup { $script:storyGroupExists = $true; [pscustomobject]@{ Id = 30; Title = $Title } }
    Mock Get-PnPGroupMember { @($script:storyGroupMembers | ForEach-Object { [pscustomobject]@{ LoginName = $_ } }) }
    Mock Add-PnPGroupMember { $script:storyGroupMembers += $LoginName }
    Mock Get-PnPWeb { [pscustomobject]@{ AssociatedOwnerGroup = [pscustomobject]@{ Id = 10 } } }
    Mock Set-PnPListPermission {
        $script:storyAssignments = @($script:storyAssignments | Where-Object PrincipalId -ne 30) +
            [pscustomobject]@{ PrincipalId = 30; Principal = $Group; RoleIds = @($AddRole) }
    }
}

Describe "Success-story seed preflight" {
    BeforeEach {
        Initialize-CoEStoryTestMocks
        $script:storyArgs = @{ Connection = "offline"; SiteUrl = "https://example.sharepoint.com/sites/CoE"
            Seeds = @(New-CoEStoryTestSeed); ResolvedReviewers = @() }
    }
    It "rejects an incomplete later row before even creating a list" {
        $invalid = New-CoEStoryTestSeed "Other story"
        $invalid.PSObject.Properties.Remove("Task")
        $storyArgs.Seeds += $invalid
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "Task"
        Assert-MockCalled New-PnPList -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-PnPList -Times 0 -Exactly -Scope It
        Assert-MockCalled Add-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "rejects duplicate case-insensitive trimmed seed titles before writes" {
        $storyArgs.Seeds += New-CoEStoryTestSeed " sample - DRAFTING A RUBRIC "
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "duplicate title"
        Assert-MockCalled New-PnPList -Times 0 -Exactly -Scope It
    }
    It "validates all metadata rather than accepting malformed optional values" {
        foreach ($change in @(@{ Audience = "Everyone" }, @{ Status = "Approved" }, @{ TimeSaved = 42 },
            @{ Video = $true }, @{ Title = "" }, @{ Task = "" }, @{ Title = ("x" * 256) })) {
            $storyArgs.Seeds = @(New-CoEStoryTestSeed)
            foreach ($key in $change.Keys) { $storyArgs.Seeds[0].$key = $change[$key] }
            { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw
        }
        Assert-MockCalled New-PnPList -Times 0 -Exactly -Scope It
    }
    It "permits absent optional metadata and empty seed collections" {
        $row = [pscustomobject]@{ Title = "Customer proposal"; Audience = "Staff"; Task = "Review a draft." }
        $storyArgs.Seeds = @($row)
        (Sync-CoESuccessStoryCatalog @storyArgs).Added | Should Be 1
        $storyArgs.Seeds = @()
        (Sync-CoESuccessStoryCatalog @storyArgs).Added | Should Be 0
        $storyItems.stories.Count | Should Be 1
    }
    It "rejects invalid video paths and unsafe mapped URLs without tenant writes" {
        foreach ($path in @("../video.mp4", "Videos/../video.mp4", "/video.mp4", "//server/video.mp4",
            "Videos\video.mp4", "https://example.org/video.mp4", "Videos/%2e%2e/video.mp4", "Videos/video.mp4?x=1")) {
            $storyArgs.Seeds[0].Video = $path
            { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "relative asset path"
        }
        $storyArgs.Seeds[0].Video = ""
        foreach ($url in @("http://example.org/video.mp4", "javascript:alert(1)", "Videos/video.mp4",
            "https://user:password@example.org/video.mp4", "https://example.org/has space.mp4")) {
            $storyArgs.StoryVideoUrls = @{ "Videos/video.mp4" = $url }
            { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw
        }
        Assert-MockCalled New-PnPList -Times 0 -Exactly -Scope It
    }
    It "rejects mock mappings and validates unused mappings before mutation" {
        $storyArgs.StoryVideoUrls = @{ "Videos/video.mp4" = "https://example.org/Videos/%4dOCK-demo.mp4" }
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "MOCK-"
        $storyArgs.StoryVideoUrls = @{ "Videos/MOCK-demo.mp4" = "https://example.org/real.mp4" }
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "MOCK-"
        $storyArgs.StoryVideoUrls = @{ "../unused.mp4" = "https://example.org/real.mp4" }
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw
        Assert-MockCalled New-PnPList -Times 0 -Exactly -Scope It
    }
    It "validates site, folder, and pre-resolved principals before mutation" {
        $storyArgs.SiteUrl = "http://example.org/sites/CoE"
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw
        $storyArgs.SiteUrl = "https://example.sharepoint.com/sites/CoE"
        $storyArgs.StoriesFolderUrl = "https://example.org/folder?secret=1"
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "StoriesFolderUrl"
        $storyArgs.Remove("StoriesFolderUrl")
        $storyArgs.ResolvedReviewers = @([pscustomobject]@{ Id = 0; LoginName = "reviewer@example.org" })
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "preflight"
        $storyArgs.ResolvedReviewers = @([pscustomobject]@{ Id = 20; LoginName = "reviewer@example.org" }) * 2
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "duplicate principal"
        Assert-MockCalled New-PnPList -Times 0 -Exactly -Scope It
    }
}

Describe "Approval-only success-story catalog" {
    BeforeEach {
        Initialize-CoEStoryTestMocks
        $script:storyArgs = @{ Connection = "offline"; SiteUrl = "https://example.sharepoint.com/sites/CoE"
            Seeds = @(New-CoEStoryTestSeed); ResolvedReviewers = @() }
    }
    It "creates native approval, versioning, approver-only drafts, and compact default Published" {
        $result = Sync-CoESuccessStoryCatalog @storyArgs
        $result.Added | Should Be 1
        $result.Preserved | Should Be 0
        $result.Migrated | Should Be 0
        $result.List.EnableModeration | Should Be $true
        $result.List.EnableVersioning | Should Be $true
        $result.List.DraftVersionVisibility | Should Be "Approver"
        $result.Views.Published.DefaultView | Should Be $true
        ($result.Views.Published.Fields -join ",") | Should Be "Title,Audience,StoryTask,TimeSaved,StoryVideo"
        $result.ListUrl | Should Be "https://example.sharepoint.com/sites/CoE/Lists/CopilotSuccessStories"
        $result.ReaderViewUrl | Should Be "https://example.sharepoint.com/sites/CoE/Lists/CopilotSuccessStories/Published.aspx"
        $storyItems.stories[0].FieldValues.StoryStatus | Should Be "Submitted"
        $storyItems.stories[0].FieldValues["_ModerationStatus"] | Should Be 2
        Assert-MockCalled Set-PnPList -Times 1 -Exactly -Scope It -ParameterFilter {
            $EnableModeration -eq $true -and $EnableVersioning -eq $true -and $DraftVersionVisibility -eq "Approver"
        }
    }
    It "never approves configured Published or Retired seeds and removes invented sample time" {
        $sample = New-CoEStoryTestSeed
        $sample.Status = "Published"
        $sample.TimeSaved = "Invented 30 minutes"
        $real = New-CoEStoryTestSeed "A proposed measured outcome"
        $real.Status = "Retired"
        $real.TimeSaved = "User-supplied measurement, pending review"
        $storyArgs.Seeds = @($sample, $real)
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        foreach ($item in $storyItems.stories) {
            $item.FieldValues.StoryStatus | Should Be "Submitted"
            $item.FieldValues["_ModerationStatus"] | Should Be 2
        }
        $storyItems.stories[0].FieldValues.TimeSaved | Should Be ""
        $storyItems.stories[1].FieldValues.TimeSaved | Should Be $real.TimeSaved
    }
    It "inserts the four actual kit seeds as drafts without videos or measured savings" {
        $document = Get-Content -LiteralPath (Join-Path $kitRoot "SeedContent\Sections\Sections.json") -Raw | ConvertFrom-Json
        $storyArgs.Seeds = @($document.successStories)
        (Sync-CoESuccessStoryCatalog @storyArgs).Added | Should Be 4
        foreach ($item in $storyItems.stories) {
            $item.FieldValues.StoryStatus | Should Be "Submitted"
            $item.FieldValues["_ModerationStatus"] | Should Be 2
            $item.FieldValues.TimeSaved | Should Be ""
            $item.FieldValues.ContainsKey("StoryVideo") | Should Be $false
        }
    }
    It "never guesses an asset URL or probes files when a mapping is absent" {
        $storyArgs.Seeds[0].Video = "Videos/real video.mp4"
        $storyArgs.StoriesFolderUrl = "https://example.sharepoint.com/sites/CoE/Shared%20Documents/Success%20Stories"
        $result = Sync-CoESuccessStoryCatalog @storyArgs
        $storyItems.stories[0].FieldValues.ContainsKey("StoryVideo") | Should Be $false
        $result.Diagnostics.UnresolvedSeedVideoCount | Should Be 1
    }
    It "uses only the verified URL supplied by the parent for a pending video" {
        $storyArgs.Seeds[0].Video = "Videos/real video.mp4"
        $storyArgs.StoryVideoUrls = @{ "Videos/real video.mp4" = "https://example.sharepoint.com/sites/CoE/Assets/verified.mp4" }
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        $storyItems.stories[0].FieldValues.StoryVideo.Url | Should Be $storyArgs.StoryVideoUrls["Videos/real video.mp4"]
        $storyItems.stories[0].FieldValues["_ModerationStatus"] | Should Be 2
    }
    It "keeps an empty catalog empty rather than manufacturing customer stories" {
        $storyArgs.Seeds = @()
        (Sync-CoESuccessStoryCatalog @storyArgs).Added | Should Be 0
        $storyItems.stories.Count | Should Be 0
        Assert-MockCalled Add-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "ContentMode Customer never seeds a SAMPLE-titled story, defaulting to Demo mode seeding it" {
        # Regression test for a confirmed live bug: before this function took a ContentMode parameter at all,
        # a brand-new Customer-mode install still ended up with the kit's own illustrative SAMPLE success
        # stories, because nothing here ever looked at ContentMode. Default (omitted) stays Demo so every
        # pre-existing call site and test above keeps seeding exactly as before.
        $storyArgs.Seeds = @((New-CoEStoryTestSeed "SAMPLE - Drafting a rubric"), (New-CoEStoryTestSeed "A proposed measured outcome"))
        $storyArgs.ContentMode = "Customer"
        $result = Sync-CoESuccessStoryCatalog @storyArgs
        $result.Added | Should Be 1
        $storyItems.stories.Count | Should Be 1
        $storyItems.stories[0].FieldValues.Title | Should Be "A proposed measured outcome"
    }
    It "ContentMode Customer with only SAMPLE-titled seeds adds nothing" {
        $storyArgs.Seeds = @(New-CoEStoryTestSeed)
        $storyArgs.ContentMode = "Customer"
        (Sync-CoESuccessStoryCatalog @storyArgs).Added | Should Be 0
        $storyItems.stories.Count | Should Be 0
        Assert-MockCalled Add-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "ContentMode Customer does not touch a SAMPLE row a prior Demo-mode run already added" {
        # This catalog's own established invariant (unlike the Training Calendar) is that nothing here ever
        # auto-deletes existing content - sample or not - so a mode switch on the same site must leave an
        # already-seeded SAMPLE row exactly as a Demo-mode run left it, for an admin to review and remove
        # deliberately like any other Review item. In Customer mode the SAMPLE title is filtered out of the
        # seed list entirely before the add/preserve loop runs, so it is reported as neither Added nor
        # Preserved - simply left alone - but the row itself must still be untouched on the live list.
        $storyArgs.ContentMode = "Demo"
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        $storyItems.stories.Count | Should Be 1
        $storyArgs.ContentMode = "Customer"
        $result = Sync-CoESuccessStoryCatalog @storyArgs
        $result.Added | Should Be 0
        $result.Preserved | Should Be 0
        $storyItems.stories.Count | Should Be 1
        $storyItems.stories[0].FieldValues.Title | Should Be $storyArgs.Seeds[0].Title
    }
    It "preserves seeded titles and all customer edits on repeated synchronization" {
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        $row = $storyItems.stories[0].FieldValues
        $row.StoryTask = "Organization-edited outcome"
        $row.TimeSaved = "Verified savings"
        $row.StoryVideo = [pscustomobject]@{ Url = "https://example.org/real.mp4" }
        $row.StoryStatus = "Published"
        $row["_ModerationStatus"] = 2
        $row.CustomerEvidence = "Private custom metadata"
        $before = ConvertTo-Json $row -Depth 5 -Compress
        $storyArgs.Seeds[0].Task = "Changed starter text"
        $result = Sync-CoESuccessStoryCatalog @storyArgs
        $result.Added | Should Be 0
        $result.Preserved | Should Be 1
        $result.Migrated | Should Be 0
        (ConvertTo-Json $row -Depth 5 -Compress) | Should Be $before
        Assert-MockCalled Set-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "does not reapprove any previously moderated revisions, including a pending retirement" {
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        $storyArgs.Seeds = @()
        $script:storyItems.stories = @(
            (New-CoEStoryTestItem 1 "Approved story" "Published" 0),
            (New-CoEStoryTestItem 2 "Pending revision" "Published" 2),
            (New-CoEStoryTestItem 3 "Rejected revision" "Published" 1),
            (New-CoEStoryTestItem 4 "Pending retirement" "Retired" 2),
            (New-CoEStoryTestItem 5 "SAMPLE - Already moderated" "Published" 2)
        )
        $before = ConvertTo-Json $storyItems.stories -Depth 5 -Compress
        (Sync-CoESuccessStoryCatalog @storyArgs).Migrated | Should Be 0
        (ConvertTo-Json $storyItems.stories -Depth 5 -Compress) | Should Be $before
        Assert-MockCalled Set-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "migrates only authentic legacy Published stories and preserves sample content for review" {
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        $storyLists[0].EnableModeration = $false
        $storyArgs.Seeds = @()
        $script:storyItems.stories = @(
            (New-CoEStoryTestItem 1 "Customer publication"),
            (New-CoEStoryTestItem 2 "Customer submission" "Submitted"),
            (New-CoEStoryTestItem 3 "Customer retirement" "Retired"),
            (New-CoEStoryTestItem 4 "SAMPLE - Old invented outcome"),
            (New-CoEStoryTestItem 5 "Old mock evidence" "Published" 0 ([pscustomobject]@{ Url = "https://example.org/Videos/MOCK-demo.mp4" })),
            (New-CoEStoryTestItem 6 "Unknown legacy state" "")
        )
        $sampleBefore = $storyItems.stories[3].FieldValues.Clone()
        $result = Sync-CoESuccessStoryCatalog @storyArgs
        $result.Migrated | Should Be 6
        (($storyItems.stories | ForEach-Object { $_.FieldValues["_ModerationStatus"] }) -join ",") | Should Be "0,2,1,2,2,2"
        $storyItems.stories[3].FieldValues.Count | Should Be $sampleBefore.Count
        foreach ($key in @($sampleBefore.Keys | Where-Object { $_ -ne "_ModerationStatus" })) {
            $storyItems.stories[3].FieldValues[$key] | Should Be $sampleBefore[$key]
        }
        $result.Diagnostics.SampleItemIds | Should Be 4
        $result.Diagnostics.MockVideoItemIds | Should Be 5
        $storyItems.stories.Count | Should Be 6
        (Sync-CoESuccessStoryCatalog @storyArgs).Migrated | Should Be 0
        Assert-MockCalled Set-PnPListItem -Times 6 -Exactly -Scope It
    }
    It "rejects ambiguous existing titles without inserting or migrating any rows" {
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        $storyLists[0].EnableModeration = $false
        $script:storyItems.stories += New-CoEStoryTestItem 2 " sample - DRAFTING A RUBRIC "
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "duplicate title"
        Assert-MockCalled Add-PnPListItem -Times 1 -Exactly -Scope It
        Assert-MockCalled Set-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "preserves custom fields, statuses, and documentation views" {
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        $script:storyFields.stories += [pscustomobject]@{ InternalName = "CustomEvidence"; TypeAsString = "Note"; Choices = @() }
        $status = @($storyFields.stories | Where-Object InternalName -eq StoryStatus)[0]
        $status.Choices = @("Published", "Customer hold")
        $script:storyViews.stories += [pscustomobject]@{ Id = "docs"; Title = "Internal documentation"; ViewQuery = "Custom documentation"
            DefaultView = $false; Fields = @("CustomEvidence"); CustomFormatter = ""; ServerRelativeUrl = "/sites/CoE/Lists/CopilotSuccessStories/Docs.aspx" }
        $storyItems.stories[0].FieldValues.StoryStatus = "Customer hold"
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        ($status.Choices -join ",") | Should Be "Published,Customer hold,Submitted,Retired"
        $status.DefaultValue | Should Be "Submitted"
        @($storyFields.stories | Where-Object InternalName -eq CustomEvidence).Count | Should Be 1
        @($storyViews.stories | Where-Object Id -eq docs)[0].ViewQuery | Should Be "Custom documentation"
        $storyItems.stories[0].FieldValues.StoryStatus | Should Be "Customer hold"
    }
    It "refuses unsafe existing field types rather than deleting or converting them" {
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        @($storyFields.stories | Where-Object InternalName -eq StoryVideo)[0].TypeAsString = "Text"
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "expected 'URL'"
        Assert-MockCalled Set-PnPListItem -Times 0 -Exactly -Scope It
    }
}

Describe "Success-story reader and reviewer views" {
    BeforeEach {
        Initialize-CoEStoryTestMocks
        $script:storyArgs = @{ Connection = "offline"; SiteUrl = "https://example.sharepoint.com/sites/CoE"
            Seeds = @(); ResolvedReviewers = @() }
    }
    It "gives reviewers a non-default maintenance view for pending retirement approvals" {
        $result = Sync-CoESuccessStoryCatalog @storyArgs
        $result.Views.Management.ViewQuery | Should Not Match 'Where|StoryStatus|_ModerationStatus'
        $result.Views.Management.Fields -contains "_ModerationStatus" | Should Be $true
        $result.Views.Management.DefaultView | Should Be $false
    }
    It "uses native approval alone, not legacy Published status, and allows null statuses" {
        $result = Sync-CoESuccessStoryCatalog @storyArgs
        $published = [xml]("<Query>" + $result.Views.Published.ViewQuery + "</Query>")
        $review = [xml]("<Query>" + $result.Views.Review.ViewQuery + "</Query>")
        $published.SelectSingleNode("//Value[@Type='ModStat']").InnerText | Should Be "0"
        foreach ($status in @("Submitted", "Published", "Customer hold", "", $null)) {
            foreach ($state in @(0, 1, 2)) {
                $values = @{ StoryStatus = $status; "_ModerationStatus" = $state }
                Test-CoEStoryPredicate $published.Query.Where.FirstChild $values | Should Be ($state -eq 0)
                Test-CoEStoryPredicate $review.Query.Where.FirstChild $values | Should Be ($state -eq 2)
            }
        }
    }
    It "excludes Retired from reader and review views in every native moderation state" {
        $result = Sync-CoESuccessStoryCatalog @storyArgs
        foreach ($view in @($result.Views.Published, $result.Views.Review)) {
            $query = [xml]("<Query>" + $view.ViewQuery + "</Query>")
            foreach ($state in @(0, 1, 2)) {
                Test-CoEStoryPredicate $query.Query.Where.FirstChild @{ StoryStatus = "Retired"; "_ModerationStatus" = $state } | Should Be $false
            }
        }
    }
    It "leaves a pending retirement to native last-approved-version behavior" {
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        $script:storyItems.stories = @(New-CoEStoryTestItem 1 "Retirement awaiting review" "Retired" 2)
        $result = Sync-CoESuccessStoryCatalog @storyArgs
        $query = [xml]("<Query>" + $result.Views.Published.ViewQuery + "</Query>")
        $lastApprovedVersion = @{ StoryStatus = "Published"; "_ModerationStatus" = 0; StoryVideo = $null }
        Test-CoEStoryPredicate $query.Query.Where.FirstChild $lastApprovedVersion | Should Be $true
        Test-CoEStoryPredicate $query.Query.Where.FirstChild $storyItems.stories[0].FieldValues | Should Be $false
        $storyItems.stories[0].FieldValues["_ModerationStatus"] | Should Be 2
        Assert-MockCalled Set-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "restores the actual default view on existing lists without touching pending edits" {
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        foreach ($view in $storyViews.stories) { $view.DefaultView = $view.Title -eq "All Items" }
        $script:storyItems.stories = @(New-CoEStoryTestItem 1 "Pending publication" "Published" 2)
        $result = Sync-CoESuccessStoryCatalog @storyArgs
        $result.Views.Published.DefaultView | Should Be $true
        @($storyViews.stories | Where-Object DefaultView).Count | Should Be 1
        $storyItems.stories[0].FieldValues["_ModerationStatus"] | Should Be 2
        Assert-MockCalled Set-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "excludes every known mock URL even if already approved, keeping real and null videos" {
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        $mock1 = "https://example.org/Videos/MOCK-demo.mp4?a=1&b=2"
        $mock2 = "https://example.org/Videos/%4dOCK-other.mp4"
        $real = "https://example.org/Videos/Customer-demo.mp4"
        $script:storyItems.stories = @(
            (New-CoEStoryTestItem 1 "Legacy mock" "Published" 0 ([pscustomobject]@{ Url = $mock1 })),
            (New-CoEStoryTestItem 2 "Encoded mock" "Published" 0 "$mock2, Watch the video"),
            (New-CoEStoryTestItem 3 "Customer evidence" "Published" 0 ([pscustomobject]@{ Url = $real }))
        )
        $before = ConvertTo-Json $storyItems.stories -Depth 5 -Compress
        $result = Sync-CoESuccessStoryCatalog @storyArgs
        $query = [xml]("<Query>" + $result.Views.Published.ViewQuery + "</Query>")
        foreach ($url in @($mock1, $mock2)) {
            Test-CoEStoryPredicate $query.Query.Where.FirstChild @{ StoryStatus = "Published"; "_ModerationStatus" = 0; StoryVideo = $url } | Should Be $false
        }
        foreach ($url in @($real, $null, "")) {
            Test-CoEStoryPredicate $query.Query.Where.FirstChild @{ StoryStatus = "Published"; "_ModerationStatus" = 0; StoryVideo = $url } | Should Be $true
        }
        (ConvertTo-Json $storyItems.stories -Depth 5 -Compress) | Should Be $before
        Assert-MockCalled Set-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "fails explicitly when query/default readback does not match, before seeding" {
        Mock Set-PnPView {
            @($script:storyViews[$List] | Where-Object Id -eq $Identity)[0].DefaultView = $false
            @($script:storyViews[$List] | Where-Object Id -eq $Identity)[0]
        }
        $storyArgs.Seeds = @(New-CoEStoryTestSeed)
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "query/default"
        Assert-MockCalled Add-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "retains known mock exclusions across pending URL edits and seeds the legacy kit exclusion" {
        $storyArgs.StoriesFolderUrl = "https://example.sharepoint.com/sites/CoE/Shared%20Documents/Success%20Stories"
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        $legacyKitMock = $storyArgs.StoriesFolderUrl + "/Videos/MOCK-Success-Story-Lab-Rubric.mp4"
        $mock = "https://example.org/Videos/MOCK-customer-legacy.mp4"
        $script:storyItems.stories = @(New-CoEStoryTestItem 1 "Mock video replacement" "Published" 0 ([pscustomobject]@{ Url = $mock }))
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        $storyItems.stories[0].FieldValues.StoryVideo = [pscustomobject]@{ Url = "https://example.org/Videos/real.mp4" }
        $storyItems.stories[0].FieldValues["_ModerationStatus"] = 2
        $result = Sync-CoESuccessStoryCatalog @storyArgs
        $query = [xml]("<Query>" + $result.Views.Published.ViewQuery + "</Query>")
        foreach ($url in @($mock, $legacyKitMock)) {
            Test-CoEStoryPredicate $query.Query.Where.FirstChild @{ StoryStatus = "Published"; "_ModerationStatus" = 0; StoryVideo = $url } | Should Be $false
        }
        Assert-MockCalled Set-PnPListItem -Times 0 -Exactly -Scope It
    }
}

Describe "Success-story permission and write failures" {
    BeforeEach {
        Initialize-CoEStoryTestMocks
        $script:storyArgs = @{ Connection = "offline"; SiteUrl = "https://example.sharepoint.com/sites/CoE"
            Seeds = @(New-CoEStoryTestSeed); ResolvedReviewers = @() }
    }
    It "grants the reviewer group while preserving owner, member, and reader access" {
        $script:storyAssignments = @(
            [pscustomobject]@{ PrincipalId = 10; Principal = "Owners"; RoleIds = @("Full Control") },
            [pscustomobject]@{ PrincipalId = 11; Principal = "Members"; RoleIds = @("Edit") },
            [pscustomobject]@{ PrincipalId = 12; Principal = "Visitors"; RoleIds = @("Read") },
            [pscustomobject]@{ PrincipalId = 20; Principal = "Reviewer"; RoleIds = @("Limited Access") }
        )
        $storyArgs.ResolvedReviewers = @([pscustomobject]@{ Id = 20; LoginName = "i:0#.f|membership|reviewer@example.org" })
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        (($storyAssignments | Where-Object PrincipalId -eq 10).RoleIds -join ",") | Should Be "Full Control"
        (($storyAssignments | Where-Object PrincipalId -eq 11).RoleIds -join ",") | Should Be "Edit"
        (($storyAssignments | Where-Object PrincipalId -eq 12).RoleIds -join ",") | Should Be "Read"
        @($storyAssignments | Where-Object PrincipalId -eq 20).Count | Should Be 0
        (($storyAssignments | Where-Object PrincipalId -eq 30).RoleIds -join ",") | Should Be "CoE Catalog Reviewer"
        $storyGroupMembers -join "," | Should Be "i:0#.f|membership|reviewer@example.org"
        $storyLists[0].HasUniqueRoleAssignments | Should Be $true
        Assert-MockCalled Set-PnPList -Times 1 -Exactly -Scope It -ParameterFilter { $BreakRoleInheritance -and $CopyRoleAssignments -and -not $ClearSubscopes }
        Assert-MockCalled Set-PnPListPermission -Times 1 -Exactly -Scope It -ParameterFilter { $Group -eq "CoE Catalog Reviewers" -and -not $User }
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        Assert-MockCalled Add-PnPGroupMember -Times 1 -Exactly -Scope It
        Assert-MockCalled New-PnPGroup -Times 1 -Exactly -Scope It
    }
    It "does not break inheritance merely to enable approval when there are no reviewers" {
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        $storyLists[0].HasUniqueRoleAssignments | Should Be $false
        Assert-MockCalled Set-PnPList -Times 0 -Exactly -Scope It -ParameterFilter { $BreakRoleInheritance }
        Assert-MockCalled New-PnPGroup -Times 0 -Exactly -Scope It
    }
    It "fails before field/item writes if final reviewer permissions are not verified" {
        $storyArgs.ResolvedReviewers = @([pscustomobject]@{ Id = 20; LoginName = "reviewer@example.org" })
        Mock Set-PnPListPermission {}
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "could not be verified"
        Assert-MockCalled Add-PnPFieldFromXml -Times 0 -Exactly -Scope It
        Assert-MockCalled Add-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "refuses item-specific permissions and never resets or widens them" {
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        $storyItems.stories[0].HasUniqueRoleAssignments = $true
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "unique permissions"
        Assert-MockCalled Set-PnPList -Times 1 -Exactly -Scope It
        Assert-MockCalled Set-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "does not report success when native moderation readback fails" {
        Mock Set-PnPList {}
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "content approval settings"
        Assert-MockCalled Add-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "does not swallow insertion failures or return a successful result" {
        Mock Add-PnPListItem { throw "Access denied on insertion" }
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "Access denied"
    }
    It "requires an insertion ID and verifies that new stories really remain pending" {
        Mock Add-PnPListItem {}
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "item ID"
        Mock Add-PnPListItem {
            $item = New-CoEStoryTestItem 1 "Unsafe approval" "Published" 0
            $script:storyItems.stories += $item
            $item
        }
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "could not be verified"
    }
    It "does not swallow a legacy migration failure" {
        Sync-CoESuccessStoryCatalog @storyArgs | Out-Null
        $storyLists[0].EnableModeration = $false
        Mock Set-PnPListItem { throw "Migration denied" }
        { Sync-CoESuccessStoryCatalog @storyArgs } | Should Throw "Migration denied"
    }
}
