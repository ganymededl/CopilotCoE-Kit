# Offline Pester 3 regression tests. Every external seam fails closed unless mocked.
Set-StrictMode -Version Latest
$kitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $kitRoot "Internal\SecurityPosture.ps1")
. (Join-Path $kitRoot "Internal\AdoptionCatalogs.ps1")

function Get-PnPList { [CmdletBinding()] param($Identity, $Includes, $Connection) throw "Unmocked list read" }
function New-PnPList { [CmdletBinding()] param($Title, $Template, $Url, [switch]$EnableVersioning, $Connection) throw "Unmocked list creation" }
function Set-PnPList { [CmdletBinding()] param($Identity, $EnableVersioning, $EnableModeration, $DraftVersionVisibility, [switch]$BreakRoleInheritance,
    [switch]$CopyRoleAssignments, [switch]$ClearSubscopes, $Connection) throw "Unmocked list mutation" }
function Get-PnPField { [CmdletBinding()] param($List, $Identity, $Connection) throw "Unmocked field read" }
function Get-PnPContentType { [CmdletBinding()] param($List, $Includes, $Connection) throw "Unmocked content type read" }
function Add-PnPFieldFromXml { [CmdletBinding()] param($List, $FieldXml, $Connection) throw "Unmocked field write" }
function Set-PnPField { [CmdletBinding()] param($List, $Identity, $Values, $Connection) throw "Unmocked field update" }
function Get-PnPListItem { [CmdletBinding()] param($List, $Fields, $Includes, $PageSize, $Connection) throw "Unmocked item read" }
function Add-PnPListItem { [CmdletBinding()] param($List, $Values, $Connection) throw "Unmocked item insertion" }
function Set-PnPListItem { [CmdletBinding()] param($List, $Identity, $Values, $UpdateType, $Connection) throw "Unmocked item update" }
function Add-PnPRoleDefinition { [CmdletBinding()] param($RoleName, $Clone, $Include, $Description, $Connection) throw "Unmocked role creation" }
function Get-PnPRoleDefinition { [CmdletBinding()] param($Identity, $Connection) throw "Unmocked role read" }
function Get-PnPView { [CmdletBinding()] param($List, $Identity, $Includes, $Connection) throw "Unmocked view read" }
function Add-PnPView { [CmdletBinding()] param($List, $Title, $Fields, $Query, $RowLimit,
    [switch]$Paged, [switch]$SetAsDefault, $Connection) throw "Unmocked view creation" }
function Set-PnPView { [CmdletBinding()] param($List, $Identity, $Fields, $Values, $Connection) throw "Unmocked view update" }
function Get-PnPProperty { [CmdletBinding()] param($ClientObject, $Property, $Connection) throw "Unmocked CSOM property read" }
function Get-PnPWeb { [CmdletBinding()] param($Includes, $Connection) throw "Unmocked web read" }
function Get-PnPContext { [CmdletBinding()] param($Connection) throw "Unmocked CSOM context" }
function Invoke-PnPQuery { [CmdletBinding()] param($Connection) throw "Unmocked CSOM write" }
function Get-PnPTenantId { [CmdletBinding()] param($Connection) throw "Unmocked tenant read" }
function Get-PnPAccessToken { [CmdletBinding()] param($ResourceTypeName, [switch]$Decoded, $Connection) throw "Unmocked token read" }
function Invoke-PnPGraphMethod { [CmdletBinding()] param($Url, $Method, $Connection) throw "Unmocked Graph read" }
function New-PnPUser { [CmdletBinding()] param($LoginName, $Connection) throw "Unmocked principal registration" }
function Get-PnPGroup { [CmdletBinding()] param($Identity, $Connection) throw "Unmocked group read" }
function New-PnPGroup { [CmdletBinding()] param($Title, $Description, $Connection) throw "Unmocked group creation" }
function Get-PnPGroupMember { [CmdletBinding()] param($Group, $Connection) throw "Unmocked group member read" }
function Add-PnPGroupMember { [CmdletBinding()] param($LoginName, $Group, $Connection) throw "Unmocked group member write" }
function Set-PnPListPermission { [CmdletBinding()] param($Identity, $Group, $User, $AddRole, $RemoveRole, $Connection) throw "Unmocked list permission write" }

function New-TestLearningSeed {
    [pscustomobject]@{ id = "staff-01"; title = "Start safely"; path = "Everyday work"; audience = "Staff"
        step = 1; minutes = 10; requirement = "Recommended"; product = "Copilot Chat"
        resourceUrl = "SitePages/Guide-Start-in-10-Minutes.aspx"; practicePromptTitle = "Editor's Review"
        practiceUrl = "SitePages/Guide-Prompt-Library.aspx"; expectedResult = "Review a grounded draft."
        owner = ""; reviewedOn = ""; lmsUrl = "" }
}
function New-TestAgentSeed {
    [pscustomobject]@{ name = "Staff helper"; description = "Reviewed assistance"; audience = "Staff"
        examplePrompt = "Summarize guidance."; owner = ""; url = "https://agents.example.org/launch?agent=1" }
}
function New-TestPublishedSeed {
    $seed = New-TestAgentSeed
    $seed.owner = "owner@example.org"
    $seed | Add-Member NoteProperty status "Published"
    $seed | Add-Member NoteProperty sources "Approved guidance library"
    $seed | Add-Member NoteProperty access "Staff only"
    $seed | Add-Member NoteProperty allowedData "Non-sensitive organizational guidance"
    $seed | Add-Member NoteProperty reviewedOn "2020-01-01"
    $seed | Add-Member NoteProperty nextReview "2020-12-31"
    $seed
}
function Test-CatalogViewPredicate([System.Xml.XmlNode]$Node, [hashtable]$Values) {
    $children = @($Node.ChildNodes | Where-Object NodeType -eq Element)
    switch ($Node.Name) {
        "And" { return (Test-CatalogViewPredicate $children[0] $Values) -and (Test-CatalogViewPredicate $children[1] $Values) }
        "Or" { return (Test-CatalogViewPredicate $children[0] $Values) -or (Test-CatalogViewPredicate $children[1] $Values) }
        "IsNull" { return $null -eq $Values[$Node.FieldRef.Name] }
        "Eq" { return $null -ne $Values[$Node.FieldRef.Name] -and $Values[$Node.FieldRef.Name] -eq $Node.Value.InnerText }
        "Neq" { return $null -ne $Values[$Node.FieldRef.Name] -and $Values[$Node.FieldRef.Name] -ne $Node.Value.InnerText }
        default { throw "Unsupported test CAML operator '$($Node.Name)'." }
    }
}
function New-TestCatalogField([string]$FieldXml) {
    $xml = [xml]$FieldXml
    $field = [pscustomobject]@{ InternalName = [string]$xml.Field.Name; TypeAsString = [string]$xml.Field.Type
        Choices = @($xml.SelectNodes("//CHOICE") | ForEach-Object InnerText); SchemaXml = $FieldXml
        Title = [string]$xml.Field.DisplayName; CustomFormatter = ""; DefaultValue = ""; Hidden = $false
        ShowInDisplayForm = $true; ShowInEditForm = $true; ShowInNewForm = $true }
    $field | Add-Member ScriptMethod SetShowInDisplayForm { param([bool]$Show) $this.ShowInDisplayForm = $Show }
    $field | Add-Member ScriptMethod SetShowInEditForm { param([bool]$Show) $this.ShowInEditForm = $Show }
    $field | Add-Member ScriptMethod SetShowInNewForm { param([bool]$Show) $this.ShowInNewForm = $Show }
    $field | Add-Member ScriptMethod Update {}
    $field
}
function Initialize-TestCatalogMocks {
    $script:lists = @()
    $script:fieldsByList = @{}
    $script:itemsByList = @{}
    $script:viewsByList = @{}
    $script:formOrderByList = @{}
    $script:nextViewId = 0
    $script:aclApproved = $false
    $script:catalogContext = [pscustomobject]@{ Web = [pscustomobject]@{} }
    $script:catalogContext | Add-Member ScriptMethod Load { param($Object) }
    $script:catalogContext.Web | Add-Member ScriptMethod GetList {
        param($Url)
        return @($script:lists | Where-Object { $_.RootFolder.ServerRelativeUrl -eq $Url })[0]
    }
    Mock Get-PnPContext { $script:catalogContext }
    Mock Invoke-PnPQuery {}
    Mock Resolve-CoECatalogReviewers {}
    Mock Assert-CoECatalogItemInheritance {}
    Mock Set-CoECatalogReviewPermissions {
        $script:aclApproved = $true
        @($script:lists | Where-Object Id -eq $List.Id)[0].EnableModeration = $true
    }
    Mock Get-PnPList {
        if ($Identity) { @($script:lists | Where-Object {
            $_.Id -eq $Identity -or $_.RootFolder.ServerRelativeUrl -eq $Identity
        }) } else { $script:lists }
    }
    Mock New-PnPList {
        $list = [pscustomobject]@{ Id = "list-$($script:lists.Count + 1)"; Title = $Title; BaseTemplate = 100
            EnableVersioning = [bool]$EnableVersioning; EnableModeration = $false; DraftVersionVisibility = "Reader"
            RootFolder = [pscustomobject]@{ ServerRelativeUrl = "/sites/CoE/$Url" } }
        $script:lists += $list
        $script:fieldsByList[$list.Id] = @(New-TestCatalogField '<Field Name="Title" Type="Text" DisplayName="Title"/>')
        $script:itemsByList[$list.Id] = @()
        $script:viewsByList[$list.Id] = @([pscustomobject]@{ Id = "all"; Title = "All Items"
            ViewQuery = ""; Fields = @("Title"); DefaultView = $true; BaseViewId = "1"
            ServerRelativeUrl = "/sites/CoE/$Url/AllItems.aspx"; CustomFormatter = "" })
        $script:viewsByList[$list.Id][0] | Add-Member ScriptMethod Update {}
    }
    Mock Set-PnPList {
        if ($null -ne $EnableVersioning) {
            @($script:lists | Where-Object Id -eq $Identity)[0].EnableVersioning = [bool]$EnableVersioning
        } else { throw "Unexpected ACL call in catalog-only test" }
    }
    Mock Get-PnPField {
        if (-not $script:aclApproved) { throw "Fields accessed before ACL enforcement" }
        if ($Identity) { $script:fieldsByList[$List] | Where-Object InternalName -eq $Identity }
        else { $script:fieldsByList[$List] }
    }
    Mock Add-PnPFieldFromXml {
        if (-not $script:aclApproved) { throw "Field insertion before ACL enforcement" }
        $field = New-TestCatalogField $FieldXml
        if ($field.TypeAsString -eq "Calculated") {
            $source = @($script:fieldsByList[$List] | Where-Object InternalName -eq LearningAudience)
            if ($source.Count -ne 1 -or $source[0].Title -ne "Audience") { throw "Calculated audience field created before its named source" }
        }
        $script:fieldsByList[$List] += $field
        $field
    }
    Mock Set-PnPField {
        $field = @($script:fieldsByList[$List] | Where-Object InternalName -eq $Identity)[0]
        foreach ($name in $Values.Keys) {
            if ($name -notin @("Choices", "Title", "CustomFormatter", "Formula")) { throw "Unsupported field property '$name'" }
            $field | Add-Member NoteProperty $name $Values[$name] -Force
        }
    }
    Mock Get-PnPContentType {
        $links = [System.Collections.ArrayList]::new()
        foreach ($field in $script:fieldsByList[$List]) { $null = $links.Add([pscustomobject]@{ Name = $field.InternalName }) }
        Add-Member -InputObject $links -MemberType NoteProperty -Name ListId -Value $List
        Add-Member -InputObject $links -MemberType ScriptMethod -Name Reorder -Value {
            param([string[]]$Order)
            $script:formOrderByList[$this.ListId] = $Order
        }
        $type = [pscustomobject]@{ Name = "Item"; FieldLinks = $links }
        $type | Add-Member ScriptMethod Update { param([bool]$UpdateChildren) }
        $type
    }
    Mock Get-PnPProperty {}
    Mock Get-PnPListItem { $script:itemsByList[$List] }
    Mock New-CoECatalogUrlValue { [pscustomobject]@{ Url = $Url; Description = $Description } }
    Mock Add-PnPListItem {
        if (-not $script:aclApproved) { throw "Item insertion before ACL enforcement" }
        $item = [pscustomobject]@{ Id = $script:itemsByList[$List].Count + 1; FieldValues = $Values }
        $script:itemsByList[$List] += $item
        $item
    }
    Mock Set-PnPListItem {
        $item = @($script:itemsByList[$List] | Where-Object Id -eq $Identity)[0]
        foreach ($name in $Values.Keys) { $item.FieldValues[$name] = $Values[$name] }
        $item
    }
    Mock Get-PnPView {
        if ($Identity) { $script:viewsByList[$List] | Where-Object Id -eq $Identity }
        else { $script:viewsByList[$List] }
    }
    Mock Add-PnPView {
        if (-not $script:aclApproved) { throw "View presentation before ACL enforcement" }
        if ($SetAsDefault) { foreach ($old in $script:viewsByList[$List]) { $old.DefaultView = $false } }
        $script:nextViewId++
        $view = [pscustomobject]@{ Id = "view-$script:nextViewId"; Title = $Title
            Fields = $Fields; ViewQuery = $Query; DefaultView = [bool]$SetAsDefault; CustomFormatter = ""
            BaseViewId = "1"
            ServerRelativeUrl = "$(@($script:lists | Where-Object Id -eq $List)[0].RootFolder.ServerRelativeUrl)/$([uri]::EscapeDataString($Title)).aspx" }
        $view | Add-Member ScriptMethod Update {}
        $script:viewsByList[$List] += $view
        $view
    }
    Mock Set-PnPView {
        if ($Values.ContainsKey("RowLimit") -and $Values.RowLimit -isnot [uint32]) { throw "CSOM RowLimit requires UInt32." }
        $view = @($script:viewsByList[$List] | Where-Object Id -eq $Identity)[0]
        if ($null -ne $Fields) { $view.Fields = $Fields }
        if ($Values.ContainsKey("DefaultView") -and $Values.DefaultView) {
            foreach ($old in $script:viewsByList[$List]) { $old.DefaultView = $false }
        }
        foreach ($name in $Values.Keys) { $view | Add-Member NoteProperty $name $Values[$name] -Force }
        $view
    }
}

Describe "Learning seed validation without tenant activity" {
    BeforeEach {
        $script:seed = New-TestLearningSeed
        $script:document = @{ version = 1; items = @($script:seed) }
        Mock Get-Content { ConvertTo-Json $script:document -Depth 8 }
    }
    It "resolves site-relative URLs beneath the site rather than its parent" {
        $rows = @(Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.sharepoint.com/sites/CoE)
        $rows.Count | Should Be 1
        $rows[0].resourceUrl | Should Be "https://example.sharepoint.com/sites/CoE/SitePages/Guide-Start-in-10-Minutes.aspx"
        $rows[0].practiceUrl | Should Be "https://example.sharepoint.com/sites/CoE/SitePages/Guide-Prompt-Library.aspx"
        $rows[0].practicePromptTitle | Should Be "Editor's Review"
        $rows[0].owner | Should Be ""
        $rows[0].reviewedOn | Should Be ""
    }
    It "overrides only the designated relative prompt-library URL" {
        $args = @{ Path = "offline.json"; SiteUrl = "https://example.sharepoint.com/sites/CoE/"
            PromptLibraryUrl = "https://org.example.org/prompts" }
        @(Read-CoELearningSeeds @args)[0].practiceUrl | Should Be "https://org.example.org/prompts"
        $script:seed.practiceUrl = "SitePages/Guide-Prompt-Library.aspx#clear-communication"
        @(Read-CoELearningSeeds @args)[0].practiceUrl | Should Be "https://org.example.org/prompts"
        $script:seed.practiceUrl = "https://org.example.org/practice?resource=2"
        @(Read-CoELearningSeeds @args)[0].practiceUrl | Should Be $seed.practiceUrl
        $script:seed.practiceUrl = ""
        @(Read-CoELearningSeeds @args)[0].practiceUrl | Should Be ""
    }
    It "resolves server-relative paths as HTTPS without treating them as file URLs" {
        $script:seed.resourceUrl = "/sites/CoE/SitePages/Start.aspx"
        @(Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org/sites/CoE)[0].resourceUrl |
            Should Be "https://example.org/sites/CoE/SitePages/Start.aspx"
    }
    It "permits an explicit empty items array and schemaVersion alias" {
        $script:document = @{ schemaVersion = 1; items = @() }
        @(Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org/sites/CoE).Count | Should Be 0
    }
    It "rejects missing, conflicting, or noninteger schema versions and nonarray items" {
        foreach ($doc in @(@{ items = @($seed) }, @{ version = 2; items = @($seed) },
            @{ version = "1"; items = @($seed) }, @{ version = 1; schemaVersion = 2; items = @($seed) },
            @{ version = 1; items = $seed })) {
            $script:document = $doc
            { Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org/sites/CoE } | Should Throw
        }
    }
    It "requires every string field including optional empty strings" {
        $script:seed.PSObject.Properties.Remove("owner")
        { Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org } | Should Throw "owner"
        $script:seed = New-TestLearningSeed
        $script:seed.expectedResult = " "
        $script:document.items = @($script:seed)
        { Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org } | Should Throw "id='staff-01', path='Everyday work'"
    }
    It "rejects HTTP, javascript, credentials, network paths, and invalid optional URLs" {
        foreach ($url in @("http://example.org/x", "javascript:alert(1)", "https://user:password@example.org/x",
            "//example.org/x", "https:\example.org\x", "")) {
            $script:seed.resourceUrl = $url
            { Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org/sites/CoE } | Should Throw
        }
        $script:seed.resourceUrl = "SitePages/start.aspx"
        $script:seed.lmsUrl = "http://org.example.org/lms"
        { Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org } | Should Throw "lmsUrl"
        $script:seed.lmsUrl = ""
        { Read-CoELearningSeeds -Path offline.json -SiteUrl http://example.org } | Should Throw
        { Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org -PromptLibraryUrl javascript:bad } | Should Throw
    }
    It "rejects case-insensitive duplicate IDs and duplicate path audience steps" {
        $other = New-TestLearningSeed
        $other.id = "STAFF-01"
        $other.step = 2
        $script:document.items = @($seed, $other)
        { Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org } | Should Throw "duplicate LearningId"
        $other.id = "staff-02"
        $other.step = 1
        $other.path = "EVERYDAY WORK"
        { Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org } | Should Throw "path + audience + step"
    }
    It "rejects numeric strings, fractional or negative minutes, zero steps, and unknown requirements" {
        foreach ($number in @("1", 1.5, 0, -1, $true)) {
            $script:seed.step = $number
            { Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org } | Should Throw
        }
        $script:seed.step = 1
        foreach ($number in @("10", 2.5, -1)) {
            $script:seed.minutes = $number
            { Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org } | Should Throw
        }
        $script:seed.minutes = 0
        $script:seed.requirement = "Mandatory"
        { Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org } | Should Throw "requirement"
    }
    It "rejects impossible or non-ISO reviewed dates and preserves legitimate dates" {
        foreach ($date in @("2026-02-30", "10/09/2026", "2026-1-01", "2026-01-01T00:00:00Z")) {
            $script:seed.reviewedOn = $date
            { Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org } | Should Throw "reviewedOn"
        }
        $script:seed.reviewedOn = "2020-02-29"
        @(Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org)[0].reviewedOn | Should Be "2020-02-29"
    }
    It "does not emit a partially validated batch and accepts large integral steps" {
        $script:seed.step = [long]2147483648
        @(Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org)[0].step | Should Be 2147483648
        $other = New-TestLearningSeed
        $other.id = "staff-02"
        $other.step = 0
        $script:document.items = @($seed, $other)
        $script:emitted = @()
        { Read-CoELearningSeeds -Path offline.json -SiteUrl https://example.org |
            ForEach-Object { $script:emitted += $_ } } | Should Throw
        $script:emitted.Count | Should Be 0
    }
}

Describe "Insert-only native learning catalog" {
    BeforeEach {
        Initialize-TestCatalogMocks
        $script:learningArgs = @{ Connection = "offline"; SiteUrl = "https://example.sharepoint.com/sites/CoE"
            Seeds = @(New-TestLearningSeed); ReviewerUPNs = @("reviewer@example.org") }
    }
    It "creates one versioned list, all typed fields, grouped views, and no fake date" {
        $result = Sync-CoELearningCatalog @learningArgs
        $result.List.Id | Should Be "list-1"
        $result.Added | Should Be 1
        $result.ListUrl | Should Be "https://example.sharepoint.com/sites/CoE/Lists/CopilotLearningPaths"
        $fieldsByList["list-1"].Count | Should Be 16
        @($fieldsByList["list-1"] | Where-Object InternalName -eq LearningRequirement)[0].Choices -join "," |
            Should Be "Recommended,Required,Optional"
        $itemsByList["list-1"][0].FieldValues.ContainsKey("LearningReviewedOn") | Should Be $false
        $result.Views.Page.DefaultView | Should Be $true
        $result.Views.ByAudience.DefaultView | Should Be $false
        ([xml]@($fieldsByList["list-1"] | Where-Object InternalName -eq "LearningRequirement")[0].SchemaXml).Field.Default |
            Should Be "Recommended"
        ([xml]@($fieldsByList["list-1"] | Where-Object InternalName -eq "LearningPractice")[0].SchemaXml).Field.DisplayName |
            Should Be "Practice"
        $xml = [xml]("<Query>" + $result.Views.ByAudience.ViewQuery + "</Query>")
        $xml.Query.GroupBy.FieldRef[0].Name | Should Be "LearningAudienceOrder"
        $xml.Query.GroupBy.FieldRef[1].Name | Should Be "LearningPath"
        $xml.Query.OrderBy.FieldRef[0].Name | Should Be "LearningStep"
        $xml.Query.OrderBy.FieldRef[1].Name | Should Be "Title"
        $result.Views.Required.ViewQuery | Should Match 'Value Type="Choice">Required'
        Assert-MockCalled Set-CoECatalogReviewPermissions -Times 1 -Exactly -Scope It
    }

    It "preserves edited existing rows, list IDs, and unrelated views on reruns" {
        $first = Sync-CoELearningCatalog @learningArgs
        $itemsByList["list-1"][0].FieldValues.Title = "Customer-edited lesson"
        $itemsByList["list-1"][0].FieldValues.LearningExpectedResult = "Customer expected result"
        $script:viewsByList["list-1"] += [pscustomobject]@{ Id = "custom"; Title = "Custom"; Fields = @("Title")
            ViewQuery = "custom"; DefaultView = $false }
        $second = Sync-CoELearningCatalog @learningArgs
        $second.List.Id | Should Be $first.List.Id
        $second.Added | Should Be 0
        $second.Preserved | Should Be 1
        $itemsByList["list-1"][0].FieldValues.Title | Should Be "Customer-edited lesson"
        $itemsByList["list-1"][0].FieldValues.LearningExpectedResult | Should Be "Customer expected result"
        @($viewsByList["list-1"] | Where-Object Title -eq Custom)[0].ViewQuery | Should Be "custom"
        Assert-MockCalled New-PnPList -Times 1 -Exactly -Scope It
        Assert-MockCalled Add-PnPFieldFromXml -Times 15 -Exactly -Scope It
        Assert-MockCalled Add-PnPListItem -Times 1 -Exactly -Scope It
        Assert-MockCalled Add-PnPView -Times 4 -Exactly -Scope It
    }
    It "adds only missing fields and explicitly restores Learning steps as the existing-list default" {
        Sync-CoELearningCatalog @learningArgs | Out-Null
        $script:fieldsByList["list-1"] = @($fieldsByList["list-1"] | Where-Object InternalName -ne LearningLms)
        $script:viewsByList["list-1"] = @($viewsByList["list-1"] | Where-Object Title -ne "By audience")
        foreach ($view in $viewsByList["list-1"]) { $view.DefaultView = $view.Title -eq "All Items" }
        (Sync-CoELearningCatalog @learningArgs).Views.ByAudience.DefaultView | Should Be $false
        @($viewsByList["list-1"] | Where-Object Title -eq "Learning steps")[0].DefaultView | Should Be $true
        @($viewsByList["list-1"] | Where-Object Title -eq "All Items")[0].DefaultView | Should Be $false
        Assert-MockCalled Add-PnPFieldFromXml -Times 2 -Exactly -Scope It -ParameterFilter { $FieldXml -match 'Name="LearningLms"' }
    }
    It "inserts by ID rather than title and preserves rows without starter IDs" {
        Sync-CoELearningCatalog @learningArgs | Out-Null
        $script:itemsByList["list-1"] += [pscustomobject]@{ Id = 2; FieldValues = @{ Title = "Start safely" } }
        $script:learningArgs.Seeds[0].id = "staff-02"
        (Sync-CoELearningCatalog @learningArgs).Added | Should Be 1
        $itemsByList["list-1"].Count | Should Be 3
    }
    It "fails duplicate existing IDs before any new inserts" {
        Sync-CoELearningCatalog @learningArgs | Out-Null
        $script:itemsByList["list-1"] += [pscustomobject]@{ Id = 2; FieldValues = @{ LearningId = "STAFF-01" } }
        { Sync-CoELearningCatalog @learningArgs } | Should Throw "duplicate LearningId"
        Assert-MockCalled Add-PnPListItem -Times 1 -Exactly -Scope It
    }
    It "rejects invalid rows before list mutation and propagates permission failures before fields or views" {
        $learningArgs.Seeds[0].resourceUrl = "http://example.org"
        { Sync-CoELearningCatalog @learningArgs } | Should Throw
        Assert-MockCalled Get-PnPList -Times 0 -Exactly -Scope It
        $learningArgs.Seeds = @(New-TestLearningSeed)
        Mock Set-CoECatalogReviewPermissions { throw "403 ACL denied" }
        { Sync-CoELearningCatalog @learningArgs } | Should Throw "403 ACL denied"
        Assert-MockCalled Add-PnPListItem -Times 0 -Exactly -Scope It
        Assert-MockCalled Add-PnPView -Times 0 -Exactly -Scope It
        Assert-MockCalled Get-PnPField -Times 0 -Exactly -Scope It
    }
    It "fails duplicate list identities and incompatible field types without replacement" {
        Sync-CoELearningCatalog @learningArgs | Out-Null
        $script:lists += $lists[0]
        { Sync-CoELearningCatalog @learningArgs } | Should Throw "duplicate"
        $script:lists = @($lists[0])
        @($fieldsByList["list-1"] | Where-Object InternalName -eq LearningId)[0].TypeAsString = "Number"
        { Sync-CoELearningCatalog @learningArgs } | Should Throw "no type conversion"
        Assert-MockCalled New-PnPList -Times 1 -Exactly -Scope It
    }
    It "permits an opt-out with zero rows while still securing the catalog" {
        $script:learningArgs.Seeds = @()
        (Sync-CoELearningCatalog @learningArgs).Added | Should Be 0
        Assert-MockCalled Add-PnPListItem -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-CoECatalogReviewPermissions -Times 1 -Exactly -Scope It
    }
}

Describe "Catalog reviewer preflight before new list creation" {
    BeforeEach { Initialize-TestCatalogMocks }
    It "does not create a learning list when reviewer resolution fails" {
        Mock Resolve-CoECatalogReviewers { throw "Reviewer not approved" }
        { Sync-CoELearningCatalog -Connection offline -SiteUrl https://example.org/sites/CoE `
            -Seeds @(New-TestLearningSeed) -ReviewerUPNs @("reviewer@example.org") } | Should Throw "Reviewer not approved"
        Assert-MockCalled New-PnPList -Times 0 -Exactly -Scope It
    }
    It "does not create an agent list when reviewer resolution fails" {
        Mock Resolve-CoECatalogReviewers { throw "Reviewer not approved" }
        { Sync-CoEAgentCatalog -Connection offline -SiteUrl https://example.org/sites/CoE `
            -AgentSeeds @(New-TestAgentSeed) -ReviewerUPNs @("reviewer@example.org") } | Should Throw "Reviewer not approved"
        Assert-MockCalled New-PnPList -Times 0 -Exactly -Scope It
    }
    It "accepts legacy optional agent description fields without inventing approval" {
        $seed = [pscustomobject]@{ name = "Internal guidance"; url = "https://agents.example.org/guidance" }
        $rows = @(ConvertTo-CoEAgentSeeds @($seed))
        $rows[0].status | Should Be "Submitted"
        $rows[0].featured | Should Be $false
        $rows[0].description | Should Be ""
        $rows[0].owner | Should Be ""
    }
}

Describe "Learning reader layout and upgrade-compatible audience order" {
    BeforeEach {
        Initialize-TestCatalogMocks
        $script:learningArgs = @{ Connection = "offline"; SiteUrl = "https://example.sharepoint.com/sites/CoE"
            Seeds = @(New-TestLearningSeed); ResolvedReviewers = @() }
    }
    It "derives audience ranks from supplied seeds and groups on that key, not alphabetically" {
        $result = Sync-CoELearningCatalog @learningArgs
        $field = @($fieldsByList["list-1"] | Where-Object InternalName -eq LearningAudienceOrder)[0]
        $schema = [xml]$field.SchemaXml
        $schema.Field.Type | Should Be "Calculated"
        $schema.Field.ResultType | Should Be "Text"
        $schema.Field.FieldRefs.FieldRef.Name | Should Be "LearningAudience"
        $formula = [string]$schema.Field.Formula
        $ranks = [regex]::Matches($formula, 'IF\(\[Audience\]="([^"]+)","([0-9]{2}\|)",')
        $ranks.Count | Should Be 1
        $ranks[0].Groups[1].Value | Should Be "Staff"
        $ranks[0].Groups[2].Value | Should Be "01|"
        $formula | Should Match '"02\|"\)&\[Audience\]$'
        foreach ($view in @($result.Views.Page, $result.Views.ByAudience, $result.Views.ByPath)) {
            $query = [xml]("<Query>" + $view.ViewQuery + "</Query>")
            @($query.Query.GroupBy.FieldRef | Where-Object Name -eq LearningAudienceOrder).Count | Should Be 1
            $format = $view.CustomFormatter | ConvertFrom-Json
            $format.groupProps.headerFormatter.txtContent | Should Match 'substring\(@group.fieldData, 3, 258\)'
        }
        $itemsByList["list-1"][0].FieldValues.LearningAudience | Should Be "Staff"
        $itemsByList["list-1"][0].FieldValues.ContainsKey("LearningAudienceOrder") | Should Be $false
    }
    It "adds a missing calculated key on existing lists without rewriting any learning row" {
        Sync-CoELearningCatalog @learningArgs | Out-Null
        $script:fieldsByList["list-1"] = @($fieldsByList["list-1"] | Where-Object InternalName -ne LearningAudienceOrder)
        $itemsByList["list-1"][0].FieldValues.LearningAudience = "Customer audience"
        $before = $itemsByList["list-1"][0].FieldValues | ConvertTo-Json -Depth 8 -Compress
        $result = Sync-CoELearningCatalog @learningArgs
        $result.Preserved | Should Be 1
        ($itemsByList["list-1"][0].FieldValues | ConvertTo-Json -Depth 8 -Compress) | Should Be $before
        @($fieldsByList["list-1"] | Where-Object InternalName -eq LearningAudienceOrder).Count | Should Be 1
        Assert-MockCalled Set-PnPListItem -Times 0 -Exactly -Scope It
        Assert-MockCalled Add-PnPFieldFromXml -Times 2 -Exactly -Scope It -ParameterFilter { $FieldXml -match 'Name="LearningAudienceOrder"' }
    }
    It "uses short Learn and Practice descriptions and responsive rows with clickable lesson details" {
        $result = Sync-CoELearningCatalog @learningArgs
        $values = $itemsByList["list-1"][0].FieldValues
        $values.LearningResource.Description | Should Be "Learn"
        $values.LearningPractice.Description | Should Be "Practice"
        $values.LearningPracticeTitle | Should Be "Editor's Review"
        $format = $result.Views.Page.CustomFormatter | ConvertFrom-Json
        $format.hideColumnHeader | Should Be $true
        $format.rowFormatter.style.'flex-wrap' | Should Be "wrap"
        $format.rowFormatter.children[0].txtContent | Should Be "='Step ' + toString([`$LearningStep])"
        $format.rowFormatter.children[1].customRowAction.action | Should Be "defaultClick"
        $format.rowFormatter.children[1].style.'white-space' | Should Be "normal"
        $format.rowFormatter.children[2].txtContent | Should Be "Learn"
        $format.rowFormatter.children[2].attributes.href | Should Be '[$LearningResource]'
        $format.rowFormatter.children[3].txtContent | Should Be "Practice"
        $format.rowFormatter.children[3].attributes.href | Should Be '[$LearningPractice]'
        $format.rowFormatter.children[3].style.'white-space' | Should Be "nowrap"
        $result.ReaderViewUrl | Should Be "https://example.sharepoint.com/sites/CoE/Lists/CopilotLearningPaths/Learning%20steps.aspx"
    }
    It "formats existing hyperlinks without replacing customer descriptions, URLs, owners or dates" {
        Sync-CoELearningCatalog @learningArgs | Out-Null
        $values = $itemsByList["list-1"][0].FieldValues
        $values.LearningResource = [pscustomobject]@{ Url = "https://customer.example.org/learn"; Description = "Customer lesson title" }
        $values.LearningPractice = [pscustomobject]@{ Url = "https://customer.example.org/practice"; Description = "Customer practice title" }
        $values.LearningOwner = "Customer assigned owner"
        $values.LearningReviewedOn = [datetime]"2020-01-01"
        $before = $values | ConvertTo-Json -Depth 8 -Compress
        $result = Sync-CoELearningCatalog @learningArgs
        ($values | ConvertTo-Json -Depth 8 -Compress) | Should Be $before
        foreach ($entry in @(@{ Name = "LearningResource"; Label = "Learn" }, @{ Name = "LearningPractice"; Label = "Practice" })) {
            $field = @($fieldsByList["list-1"] | Where-Object InternalName -eq $entry.Name)[0]
            $format = $field.CustomFormatter | ConvertFrom-Json
            $format.txtContent | Should Be $entry.Label
            $format.attributes.href | Should Be "@currentField"
            $format.attributes.title | Should Be "@currentField.desc"
            $format.style.'white-space' | Should Be "nowrap"
        }
        $result.Diagnostics.UnassignedOwnerCount | Should Be 0
        $result.Diagnostics.MissingReviewCount | Should Be 0
        Assert-MockCalled Set-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "orders details fields and hides only internal fields from forms while keeping customer fields and key access" {
        Sync-CoELearningCatalog @learningArgs | Out-Null
        $script:fieldsByList["list-1"] += New-TestCatalogField '<Field Name="CustomerNote" Type="Text" DisplayName="Customer note"/>'
        $result = Sync-CoELearningCatalog @learningArgs
        $result.FormFields -join "," | Should Be ("Title,LearningAudience,LearningPath,LearningStep,LearningResource,LearningPractice," +
            "LearningExpectedResult,LearningMinutes,LearningProduct,LearningRequirement,LearningOwner,LearningReviewedOn,LearningLms,LearningPracticeTitle")
        $formOrderByList["list-1"][0..13] -join "," | Should Be ($result.FormFields -join ",")
        $formOrderByList["list-1"] -contains "CustomerNote" | Should Be $true
        foreach ($name in @("LearningId", "LearningAudienceOrder")) {
            $field = @($fieldsByList["list-1"] | Where-Object InternalName -eq $name)[0]
            $field.ShowInDisplayForm | Should Be $false
            $field.ShowInEditForm | Should Be $false
            $field.ShowInNewForm | Should Be $false
            $field.Hidden | Should Be $false
            $formOrderByList["list-1"] -contains $name | Should Be $true
        }
        @($fieldsByList["list-1"] | Where-Object InternalName -eq LearningOwner)[0].ShowInEditForm | Should Be $true
        $itemsByList["list-1"][0].FieldValues.LearningId | Should Be "staff-01"
    }
    It "reports actual missing owner and review metadata without substituting the current user or date" {
        $result = Sync-CoELearningCatalog @learningArgs
        $result.Diagnostics.UnassignedOwnerCount | Should Be 1
        $result.Diagnostics.MissingReviewCount | Should Be 1
        $result.Diagnostics.Messages.Count | Should Be 2
        $result.Diagnostics.Messages[0] | Should Match 'actual owners'
        $result.Diagnostics.Messages[1] | Should Match 'actual review'
        $itemsByList["list-1"][0].FieldValues.LearningOwner | Should Be ""
        $itemsByList["list-1"][0].FieldValues.ContainsKey("LearningReviewedOn") | Should Be $false
        $script:learningArgs.Seeds = @()
        $script:itemsByList["list-1"] = @()
        $empty = Sync-CoELearningCatalog @learningArgs
        $empty.Diagnostics.UnassignedOwnerCount | Should Be 0
        $empty.Diagnostics.MissingReviewCount | Should Be 0
        $empty.Diagnostics.Messages.Count | Should Be 0
    }
    It "fails explicitly when a field formatter or form schema cannot be configured" {
        $field = New-TestCatalogField '<Field Name="LearningPractice" Type="URL" DisplayName="Practice"/>'
        Mock Get-PnPField { $field }
        Mock Invoke-PnPQuery { throw "403 formatting denied" }
        { Set-CoECatalogFieldPresentation ([pscustomobject]@{ Id = "list-1" }) "LearningPractice" `
            @{ CustomFormatter = Get-CoECatalogLinkFormatter "Practice" } offline } | Should Throw "403 formatting denied"
    }
    It "fails rather than claiming form order when required content type fields are missing" {
        Mock Get-PnPContentType { [pscustomobject]@{ Name = "Incomplete item"; FieldLinks = @([pscustomobject]@{ Name = "LearningId" }) } }
        { Sync-CoELearningCatalog @learningArgs } | Should Throw "missing form field"
        Assert-MockCalled Add-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "fails rather than returning a reader URL when a default-view write is ignored" {
        Sync-CoELearningCatalog @learningArgs | Out-Null
        foreach ($view in $viewsByList["list-1"]) { $view.DefaultView = $view.Title -eq "All Items" }
        Mock Set-PnPView { @($script:viewsByList[$List] | Where-Object Id -eq $Identity)[0] }
        { Sync-CoELearningCatalog @learningArgs } | Should Throw "default setting was not applied"
    }
}

Describe "Native approval, compact views and legacy migration" {
    BeforeEach {
        Initialize-TestCatalogMocks
        $script:migrationArgs = @{ Connection = "offline"; SiteUrl = "https://example.sharepoint.com/sites/CoE"
            AgentSeeds = @(New-TestAgentSeed); ResolvedReviewers = @() }
    }
    It "reuses pre-resolved reviewers without Graph resolution in either catalog" {
        Sync-CoEAgentCatalog @migrationArgs | Out-Null
        Sync-CoELearningCatalog -Connection offline -SiteUrl $migrationArgs.SiteUrl -Seeds @(New-TestLearningSeed) -ResolvedReviewers @() | Out-Null
        Assert-MockCalled Resolve-CoECatalogReviewers -Times 0 -Exactly -Scope It
    }
    It "keeps a new proposal pending while reviewed published seeds are approved" {
        $migrationArgs.AgentSeeds = @((New-TestAgentSeed), (New-TestPublishedSeed))
        $migrationArgs.AgentSeeds[1].name = "Reviewed helper"
        $migrationArgs.AgentSeeds[1].url = "https://agents.example.org/reviewed"
        $result = Sync-CoEAgentCatalog @migrationArgs
        $itemsByList["list-1"][0].FieldValues["_ModerationStatus"] | Should Be 2
        $itemsByList["list-1"][1].FieldValues["_ModerationStatus"] | Should Be 0
        $result.Views.Published.ViewQuery | Should Match '_ModerationStatus'
    }
    It "makes starter learning visible without fabricating review dates and retains four compact page fields" {
        $result = Sync-CoELearningCatalog -Connection offline -SiteUrl $migrationArgs.SiteUrl -Seeds @(New-TestLearningSeed) -ResolvedReviewers @()
        $itemsByList["list-1"][0].FieldValues["_ModerationStatus"] | Should Be 0
        $result.Views.Page.Fields -join "," | Should Be "Title,LearningStep,LearningResource,LearningPractice"
        $result.Views.Page.ViewQuery | Should Match 'Collapse="FALSE"'
    }
    It "migrates legacy featured status and configured highlights without replacing links or customer metadata" {
        Sync-CoEAgentCatalog @migrationArgs | Out-Null
        $script:lists[0].EnableModeration = $false
        $script:fieldsByList["list-1"] = @($fieldsByList["list-1"] | Where-Object InternalName -ne AgentFeatured)
        $itemsByList["list-1"][0].FieldValues.AgentStatus = "Published"
        $itemsByList["list-1"][0].FieldValues.AgentSources = "Customer source"
        $script:itemsByList["list-1"] += [pscustomobject]@{ Id = 2; FieldValues = @{
            Title = "Legacy highlight"; AgentLink = "https://legacy.example.org/agent"; AgentStatus = "Featured" } }
        $result = Sync-CoEAgentCatalog @migrationArgs
        $itemsByList["list-1"][0].FieldValues["_ModerationStatus"] | Should Be 0
        $itemsByList["list-1"][1].FieldValues.AgentFeatured | Should Be $true
        $itemsByList["list-1"][1].FieldValues["_ModerationStatus"] | Should Be 0
        $result.Migrated | Should Be 2
        $itemsByList["list-1"][0].FieldValues.AgentSources | Should Be "Customer source"
        $itemsByList["list-1"][0].FieldValues.AgentFeatured | Should Be $true
        $itemsByList["list-1"][1].FieldValues.AgentStatus | Should Be "Published"
        $itemsByList["list-1"][1].FieldValues.AgentLink | Should Be "https://legacy.example.org/agent"
        (Sync-CoEAgentCatalog @migrationArgs).Migrated | Should Be 0
    }
    It "does not reapprove a pending or rejected customer revision on reruns" {
        $migrationArgs.AgentSeeds = @(New-TestPublishedSeed)
        Sync-CoEAgentCatalog @migrationArgs | Out-Null
        foreach ($status in @(2, 1)) {
            $itemsByList["list-1"][0].FieldValues["_ModerationStatus"] = $status
            Sync-CoEAgentCatalog @migrationArgs | Out-Null
            $itemsByList["list-1"][0].FieldValues["_ModerationStatus"] | Should Be $status
        }
        Assert-MockCalled Set-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "makes legacy submissions pending when approval is first enabled" {
        Sync-CoEAgentCatalog @migrationArgs | Out-Null
        $script:lists[0].EnableModeration = $false
        $itemsByList["list-1"][0].FieldValues["_ModerationStatus"] = 0
        Sync-CoEAgentCatalog @migrationArgs | Out-Null
        $itemsByList["list-1"][0].FieldValues["_ModerationStatus"] | Should Be 2
    }
    It "checks existing item permissions before enabling versioning or adding fields" {
        Sync-CoEAgentCatalog @migrationArgs | Out-Null
        $script:lists[0].EnableVersioning = $false
        Mock Assert-CoECatalogItemInheritance { throw "Unique item permissions" }
        { Sync-CoEAgentCatalog @migrationArgs } | Should Throw "Unique item"
        Assert-MockCalled Set-PnPList -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-CoECatalogReviewPermissions -Times 1 -Exactly -Scope It
    }
    It "checks both catalogs in the early read-only preflight" {
        Sync-CoEAgentCatalog @migrationArgs | Out-Null
        Sync-CoELearningCatalog -Connection offline -SiteUrl $migrationArgs.SiteUrl -Seeds @() -ResolvedReviewers @() | Out-Null
        Mock Assert-CoECatalogItemInheritance {
            if ($List.Title -eq "Copilot Agent Showcase") { throw "Agent item permissions need review" }
        }
        { Assert-CoECatalogPreflight -SiteUrl $migrationArgs.SiteUrl -Connection offline } | Should Throw "need review"
        Assert-MockCalled Set-PnPList -Times 0 -Exactly -Scope It
    }
    It "uses approval alone for publication across legacy statuses including blank values" {
        $result = Sync-CoEAgentCatalog @migrationArgs
        $published = [xml]("<Query>" + $result.Views.Published.ViewQuery + "</Query>")
        $featured = [xml]("<Query>" + $result.Views.Featured.ViewQuery + "</Query>")
        $review = [xml]("<Query>" + $result.Views.Review.ViewQuery + "</Query>")
        foreach ($status in @("Submitted", "Published", "In review", "Rejected", "Customer hold", "", $null)) {
            $values = @{ AgentStatus = $status; "_ModerationStatus" = 0; AgentFeatured = 1 }
            Test-CatalogViewPredicate $published.Query.Where.FirstChild $values | Should Be $true
            Test-CatalogViewPredicate $featured.Query.Where.FirstChild $values | Should Be $true
            Test-CatalogViewPredicate $review.Query.Where.FirstChild $values | Should Be $false
            $values["_ModerationStatus"] = 2
            Test-CatalogViewPredicate $published.Query.Where.FirstChild $values | Should Be $false
            Test-CatalogViewPredicate $review.Query.Where.FirstChild $values | Should Be $true
        }
    }
    It "supports approval and later feature selection without regenerating views" {
        $result = Sync-CoEAgentCatalog @migrationArgs
        $published = [xml]("<Query>" + $result.Views.Published.ViewQuery + "</Query>")
        $featured = [xml]("<Query>" + $result.Views.Featured.ViewQuery + "</Query>")
        $values = @{ AgentStatus = "Submitted"; "_ModerationStatus" = 2; AgentFeatured = 0 }
        Test-CatalogViewPredicate $published.Query.Where.FirstChild $values | Should Be $false
        $values["_ModerationStatus"] = 0
        Test-CatalogViewPredicate $published.Query.Where.FirstChild $values | Should Be $true
        Test-CatalogViewPredicate $featured.Query.Where.FirstChild $values | Should Be $false
        $values.AgentFeatured = 1
        Test-CatalogViewPredicate $featured.Query.Where.FirstChild $values | Should Be $true
    }
    It "excludes Retired from both reader views and the review queue in every approval state" {
        $result = Sync-CoEAgentCatalog @migrationArgs
        foreach ($state in @(0, 1, 2)) {
            foreach ($view in @($result.Views.Published, $result.Views.Featured, $result.Views.Review, $result.Views.AllItems, $result.DetailsView)) {
                $query = [xml]("<Query>" + $view.ViewQuery + "</Query>")
                Test-CatalogViewPredicate $query.Query.Where.FirstChild @{
                    AgentStatus = "Retired"; "_ModerationStatus" = $state; AgentFeatured = 1
                } | Should Be $false
            }
        }
    }
    It "migrates legacy Retired and Rejected rows to rejected rather than pending" {
        Sync-CoEAgentCatalog @migrationArgs | Out-Null
        $script:lists[0].EnableModeration = $false
        $itemsByList["list-1"][0].FieldValues.AgentStatus = "Retired"
        $script:itemsByList["list-1"] += [pscustomobject]@{ Id = 2; FieldValues = @{
            Title = "Rejected helper"; AgentLink = "https://agents.example.org/rejected"; AgentStatus = "Rejected" } }
        Sync-CoEAgentCatalog @migrationArgs | Out-Null
        $itemsByList["list-1"][0].FieldValues["_ModerationStatus"] | Should Be 1
        $itemsByList["list-1"][1].FieldValues["_ModerationStatus"] | Should Be 1
        $itemsByList["list-1"][0].FieldValues.AgentStatus | Should Be "Retired"
    }
    It "does not approve newly configured Retired or Rejected seeds" {
        foreach ($status in @("Retired", "Rejected")) {
            $seed = New-TestAgentSeed
            $seed | Add-Member NoteProperty status $status
            $seed.name = "$status helper"
            $seed.url = "https://agents.example.org/$status"
            $migrationArgs.AgentSeeds = @($seed)
            Sync-CoEAgentCatalog @migrationArgs | Out-Null
        }
        foreach ($item in $itemsByList["list-1"]) { $item.FieldValues["_ModerationStatus"] | Should Be 1 }
    }
    It "restores Published as the actual default on existing lists without approving pending edits" {
        Sync-CoEAgentCatalog @migrationArgs | Out-Null
        foreach ($view in $viewsByList["list-1"]) { $view.DefaultView = $view.Title -eq "All Items" }
        $itemsByList["list-1"][0].FieldValues["_ModerationStatus"] = 2
        $result = Sync-CoEAgentCatalog @migrationArgs
        $result.Views.Published.DefaultView | Should Be $true
        $result.Views.AllItems.DefaultView | Should Be $false
        $result.ReaderViewUrl | Should Be "https://example.sharepoint.com/sites/CoE/Lists/CopilotAgentShowcase/Published.aspx"
        $itemsByList["list-1"][0].FieldValues["_ModerationStatus"] | Should Be 2
        $result.Diagnostics.UnassignedOwnerCount | Should Be 1
        $result.Diagnostics.MissingReviewCount | Should Be 1
        Assert-MockCalled Set-PnPListItem -Times 0 -Exactly -Scope It
    }
    It "retains a management view so reviewers can approve pending retirement without changing reader filters" {
        $result = Sync-CoEAgentCatalog @migrationArgs
        $result.Views.Management.ViewQuery | Should Not Match 'AgentStatus|_ModerationStatus|Where'
        $result.Views.Management.Fields -contains "_ModerationStatus" | Should Be $true
        $result.Views.Management.DefaultView | Should Be $false
        $result.Views.Published.ViewQuery | Should Match 'Retired'
    }
    It "preserves All Items columns and existing query context while hiding retirement idempotently" {
        Sync-CoEAgentCatalog @migrationArgs | Out-Null
        $all = @($viewsByList["list-1"] | Where-Object Id -eq all)[0]
        $all.Title = "Localized items"
        $all.Fields = @("Title", "AgentPrompt")
        $all.ViewQuery = '<Where><Eq><FieldRef Name="AgentAudience"/><Value Type="Text">Staff</Value></Eq></Where>' +
            '<OrderBy><FieldRef Name="Title" Ascending="FALSE"/></OrderBy>'
        $result = Sync-CoEAgentCatalog @migrationArgs
        $result.Views.AllItems.Fields -join "," | Should Be "Title,AgentPrompt"
        $query = [xml]("<Query>" + $result.Views.AllItems.ViewQuery + "</Query>")
        Test-CatalogViewPredicate $query.Query.Where.FirstChild @{ AgentStatus = "Retired"; AgentAudience = "Staff" } | Should Be $false
        Test-CatalogViewPredicate $query.Query.Where.FirstChild @{ AgentStatus = "Submitted"; AgentAudience = "Staff" } | Should Be $true
        Test-CatalogViewPredicate $query.Query.Where.FirstChild @{ AgentStatus = "Published"; AgentAudience = "Students" } | Should Be $false
        $query.Query.OrderBy.FieldRef.Ascending | Should Be "FALSE"
        $before = $result.Views.AllItems.ViewQuery
        (Sync-CoEAgentCatalog @migrationArgs).Views.AllItems.ViewQuery | Should Be $before
    }
}

Describe "Agent seeds and existing showcase preservation" {
    BeforeEach {
        Initialize-TestCatalogMocks
        $script:agentArgs = @{ Connection = "offline"; SiteUrl = "https://example.sharepoint.com/sites/CoE"
            AgentSeeds = @(New-TestAgentSeed); ReviewerUPNs = @() }
    }
    It "defaults to Submitted and unfeatured and skips neutral placeholders" {
        $neutral = New-TestAgentSeed
        $neutral.name = "<Agent name>"
        $neutral.url = ""
        $agentArgs.AgentSeeds += $neutral
        $result = Sync-CoEAgentCatalog @agentArgs
        $result.Added | Should Be 1
        $values = $itemsByList["list-1"][0].FieldValues
        $values.AgentStatus | Should Be "Submitted"
        $values.AgentFeatured | Should Be $false
        $values.ContainsKey("AgentReviewedOn") | Should Be $false
        $values.AgentLink.Url | Should Be "https://agents.example.org/launch?agent=1"
        $values.AgentLink.Description | Should Be "Staff helper"
        @($fieldsByList["list-1"] | Where-Object InternalName -eq AgentFeatured)[0].SchemaXml | Should Match '<Default>0</Default>'
        $fieldsByList["list-1"].Count | Should Be 17
    }
    It "accepts explicit customer-reviewed Published seeds and inserts every supplied metadata value" {
        $seed = New-TestPublishedSeed
        $seed | Add-Member NoteProperty featured $true
        foreach ($name in @("product", "connections", "backupOwner", "support")) { $seed | Add-Member NoteProperty $name "$name value" }
        $agentArgs.AgentSeeds = @($seed)
        (Sync-CoEAgentCatalog @agentArgs).Added | Should Be 1
        $values = $itemsByList["list-1"][0].FieldValues
        $values.AgentStatus | Should Be "Published"
        $values.AgentFeatured | Should Be $true
        $values.AgentSources | Should Be $seed.sources
        $values.AgentAccess | Should Be $seed.access
        $values.AgentAllowedData | Should Be $seed.allowedData
        $values.AgentProduct | Should Be "product value"
        $values.AgentConnections | Should Be "connections value"
        $values.AgentBackupOwner | Should Be "backupOwner value"
        $values.AgentSupport | Should Be "support value"
        $values.AgentReviewedOn.ToString("yyyy-MM-dd") | Should Be "2020-01-01"
        $values.AgentNextReview.ToString("yyyy-MM-dd") | Should Be "2020-12-31"
    }
    It "rejects unreviewed publication rather than silently substituting approval" {
        foreach ($field in @("owner", "sources", "access", "allowedData", "reviewedOn")) {
            $seed = New-TestPublishedSeed
            $seed.$field = ""
            $agentArgs.AgentSeeds = @($seed)
            { Sync-CoEAgentCatalog @agentArgs } | Should Throw "customer review"
        }
        Assert-MockCalled Get-PnPList -Times 0 -Exactly -Scope It
    }
    It "rejects bad dates, future publication review, reversed review dates, and nonboolean feature flags" {
        foreach ($date in @("2026-02-30", "01/02/2026", "2026-1-02")) {
            $seed = New-TestPublishedSeed
            $seed.reviewedOn = $date
            $agentArgs.AgentSeeds = @($seed)
            { Sync-CoEAgentCatalog @agentArgs } | Should Throw "date"
        }
        $seed = New-TestPublishedSeed
        $seed.reviewedOn = "2099-01-01"
        $agentArgs.AgentSeeds = @($seed)
        { Sync-CoEAgentCatalog @agentArgs } | Should Throw "customer review date"
        $seed.reviewedOn = "2020-01-01"
        $seed.nextReview = "2019-12-31"
        { Sync-CoEAgentCatalog @agentArgs } | Should Throw "nextReview"
        $seed.nextReview = "impossible"
        { Sync-CoEAgentCatalog @agentArgs } | Should Throw "nextReview"
        $seed.nextReview = ""
        $seed | Add-Member NoteProperty featured "false"
        { Sync-CoEAgentCatalog @agentArgs } | Should Throw "boolean"
        Assert-MockCalled New-PnPList -Times 0 -Exactly -Scope It
    }
    It "validates all URLs and names before creating or altering a list" {
        foreach ($url in @("http://example.org", "javascript:x", "https://user:pass@example.org", "SitePages/agent.aspx", "")) {
            $seed = New-TestAgentSeed
            $seed.url = $url
            $agentArgs.AgentSeeds = @((New-TestAgentSeed), $seed)
            { Sync-CoEAgentCatalog @agentArgs } | Should Throw
        }
        $seed.url = "https://org.example.org/new"
        $seed.name = "<Agent name>"
        $agentArgs.AgentSeeds = @($seed)
        { Sync-CoEAgentCatalog @agentArgs } | Should Throw "non-placeholder"
        $seed.name = ""
        { Sync-CoEAgentCatalog @agentArgs } | Should Throw
        Assert-MockCalled Get-PnPList -Times 0 -Exactly -Scope It
    }
    It "rejects duplicate configured titles or launch URLs before mutations" {
        $seed = New-TestAgentSeed
        $seed.url = "https://org.example.org/new"
        $agentArgs.AgentSeeds += $seed
        { Sync-CoEAgentCatalog @agentArgs } | Should Throw "duplicate seed"
        $seed.name = "Other title"
        $seed.url = $agentArgs.AgentSeeds[0].url
        { Sync-CoEAgentCatalog @agentArgs } | Should Throw "duplicate seed"
        Assert-MockCalled New-PnPList -Times 0 -Exactly -Scope It
    }
    It "preserves Published status, URL, feature flag and all fields on insert-only reruns" {
        $agentArgs.AgentSeeds = @(New-TestPublishedSeed)
        $first = Sync-CoEAgentCatalog @agentArgs
        $values = $itemsByList["list-1"][0].FieldValues
        $values.Title = "Customer title"
        $values.AgentSources = "Customer-edited sources"
        $values.AgentFeatured = $true
        $agentArgs.AgentSeeds = @(New-TestAgentSeed)
        $second = Sync-CoEAgentCatalog @agentArgs
        $second.List.Id | Should Be $first.List.Id
        $second.Added | Should Be 0
        $second.Preserved | Should Be 1
        $values.AgentStatus | Should Be "Published"
        $values.AgentLink.Url | Should Be $agentArgs.AgentSeeds[0].url
        $values.AgentSources | Should Be "Customer-edited sources"
        $values.AgentFeatured | Should Be $true
        $values.Title | Should Be "Customer title"
        Assert-MockCalled New-PnPList -Times 1 -Exactly -Scope It
        Assert-MockCalled Add-PnPFieldFromXml -Times 16 -Exactly -Scope It
        Assert-MockCalled Add-PnPListItem -Times 1 -Exactly -Scope It
    }
    It "matches normalized URL objects or URL strings and preserves a different existing title link" {
        Sync-CoEAgentCatalog @agentArgs | Out-Null
        $values = $itemsByList["list-1"][0].FieldValues
        $values.Title = "Different title"
        $values.AgentLink = "https://AGENTS.example.org:443/launch?agent=1, Customer link"
        (Sync-CoEAgentCatalog @agentArgs).Preserved | Should Be 1
        $values.Title = "Staff helper"
        $values.AgentLink = [pscustomobject]@{ Url = "https://customer.example.org/published"; Description = "Original" }
        $values.AgentStatus = "Published"
        (Sync-CoEAgentCatalog @agentArgs).Preserved | Should Be 1
        $values.AgentLink.Url | Should Be "https://customer.example.org/published"
        $values.AgentStatus | Should Be "Published"
    }
    It "does not reject or repair unrelated legacy customer links during an upgrade" {
        Sync-CoEAgentCatalog @agentArgs | Out-Null
        $itemsByList["list-1"][0].FieldValues.AgentLink = "http://legacy.example.org/agent"
        $itemsByList["list-1"][0].FieldValues.AgentStatus = "Published"
        (Sync-CoEAgentCatalog @agentArgs).Preserved | Should Be 1
        $itemsByList["list-1"][0].FieldValues.AgentLink | Should Be "http://legacy.example.org/agent"
    }
    It "fails ambiguous same-title different-link matches before inserting any new seeds" {
        Sync-CoEAgentCatalog @agentArgs | Out-Null
        $script:itemsByList["list-1"] += [pscustomobject]@{ Id = 2; FieldValues = @{ Title = "Staff helper"
            AgentLink = [pscustomobject]@{ Url = "https://org.example.org/other" } } }
        $new = New-TestAgentSeed
        $new.name = "New helper"
        $new.url = "https://org.example.org/new"
        $agentArgs.AgentSeeds = @($new, (New-TestAgentSeed))
        { Sync-CoEAgentCatalog @agentArgs } | Should Throw "ambiguous"
        Assert-MockCalled Add-PnPListItem -Times 1 -Exactly -Scope It
    }
    It "fails ambiguous same-link different-title matches and normalizes title whitespace" {
        Sync-CoEAgentCatalog @agentArgs | Out-Null
        $values = $itemsByList["list-1"][0].FieldValues
        $values.Title = " Staff helper "
        $values.AgentLink = "https://org.example.org/customer"
        (Sync-CoEAgentCatalog @agentArgs).Preserved | Should Be 1
        $values.AgentLink = $agentArgs.AgentSeeds[0].url
        $script:itemsByList["list-1"] += [pscustomobject]@{ Id = 2; FieldValues = @{ Title = "Other title"
            AgentLink = [pscustomobject]@{ Url = $agentArgs.AgentSeeds[0].url; Description = "Existing" } } }
        { Sync-CoEAgentCatalog @agentArgs } | Should Throw "ambiguous"
        Assert-MockCalled Add-PnPListItem -Times 1 -Exactly -Scope It
    }
    It "fails when different seeds cross-match one existing item by title and URL" {
        Sync-CoEAgentCatalog @agentArgs | Out-Null
        $other = New-TestAgentSeed
        $other.name = "Other helper"
        $other.url = "https://org.example.org/other"
        $itemsByList["list-1"][0].FieldValues.AgentLink = $other.url
        $agentArgs.AgentSeeds += $other
        { Sync-CoEAgentCatalog @agentArgs } | Should Throw "ambiguously matches item"
        Assert-MockCalled Add-PnPListItem -Times 1 -Exactly -Scope It
    }
    It "extends status choices without discarding customer choices or editing existing row statuses" {
        Sync-CoEAgentCatalog @agentArgs | Out-Null
        $field = @($fieldsByList["list-1"] | Where-Object InternalName -eq AgentStatus)[0]
        $field.Choices = @("Submitted", "Published", "Retired", "Customer hold")
        $itemsByList["list-1"][0].FieldValues.AgentStatus = "Customer hold"
        Sync-CoEAgentCatalog @agentArgs | Out-Null
        $field.Choices -join "," | Should Be "Submitted,Published,Retired,Customer hold,In review,Rejected"
        $itemsByList["list-1"][0].FieldValues.AgentStatus | Should Be "Customer hold"
        Sync-CoEAgentCatalog @agentArgs | Out-Null
        Assert-MockCalled Set-PnPField -Times 1 -Exactly -Scope It
    }
    It "uses approval and non-retirement CAML plus Featured and keeps All Items" {
        $result = Sync-CoEAgentCatalog @agentArgs
        $featured = [xml]("<Query>" + $result.Views.Featured.ViewQuery + "</Query>")
        $featured.Query.Where.And.And.Eq.FieldRef.Name | Should Be "_ModerationStatus"
        $featured.Query.Where.And.And.Eq.Value.Type | Should Be "ModStat"
        $featured.Query.Where.And.And.Eq.Value.InnerText | Should Be "0"
        $featured.Query.Where.And.And.Or.Neq.FieldRef.Name | Should Be "AgentStatus"
        $featured.Query.Where.And.And.Or.Neq.Value.InnerText | Should Be "Retired"
        $featured.Query.Where.And.And.Or.IsNull.FieldRef.Name | Should Be "AgentStatus"
        $featured.Query.Where.And.Eq.FieldRef.Name | Should Be "AgentFeatured"
        $featured.Query.Where.And.Eq.Value.Type | Should Be "Boolean"
        $featured.Query.Where.And.Eq.Value.InnerText | Should Be "1"
        $result.Views.Published.ViewQuery | Should Not Match 'Type="Choice">Published'
        $result.Views.Review.ViewQuery | Should Match 'Type="ModStat">2'
        $result.Views.Review.ViewQuery | Should Not Match 'Submitted|In review'
        foreach ($name in @("AgentOwner", "AgentReviewedOn", "AgentNextReview", "AgentStatus")) {
            $result.Views.Review.Fields -contains $name | Should Be $true
        }
        @($viewsByList["list-1"] | Where-Object Title -eq "All Items").Count | Should Be 1
        @($viewsByList["list-1"] | Where-Object Title -eq "All Items")[0].DefaultView | Should Be $false
        $result.Views.Published.DefaultView | Should Be $true
        $result.Views.Published.Fields.Count | Should Be 5
        $result.DetailsView.Fields.Count | Should Be 17
    }
    It "changes only the native AllItems view when approval and the kit add more views that also report BaseViewId 1" {
        Sync-CoEAgentCatalog @agentArgs | Out-Null
        foreach ($title in "My submissions", "Approve/reject Items") {
        $extra = [pscustomobject]@{ Id = "mod-$title"; Title = $title; ViewQuery = "<Where><Eq><FieldRef Name=`"Author`"/><Value Type=`"Integer`"><UserID/></Value></Eq></Where>"
                Fields = @("Title"); DefaultView = $false; BaseViewId = "1"; CustomFormatter = ""
                ModerationType = $(if ($title -eq "My submissions") { "Contributor" } else { "Moderator" })
                ServerRelativeUrl = "/sites/CoE/Lists/CopilotAgentShowcase/$title.aspx" }
            $extra | Add-Member ScriptMethod Update {}
            $script:viewsByList["list-1"] += $extra
        }
        $others = { @($viewsByList["list-1"] | Where-Object { $_.ServerRelativeUrl -notmatch 'AllItems\.aspx$' } | ForEach-Object { "$($_.Title)=$($_.ViewQuery)" }) }
        $before = & $others
        # A rerun must find exactly one native view even though every standard view reports BaseViewId 1.
        { Sync-CoEAgentCatalog @agentArgs } | Should Not Throw
        $after = & $others
        ($after -join "|") | Should Be ($before -join "|")
        @($viewsByList["list-1"] | Where-Object { $_.BaseViewId -eq "1" }).Count | Should BeGreaterThan 3
    }
}

Describe "Catalog view query readback normalization" {
    It "accepts SharePoint-normalized CAML formatting but rejects different filters" {
        $expected = '<Where><And><Eq><FieldRef Name="_ModerationStatus"/><Value Type="ModStat">0</Value></Eq><Or><IsNull><FieldRef Name="StoryStatus"/></IsNull><Neq><FieldRef Name="StoryStatus"/><Value Type="Choice">Retired</Value></Neq></Or></And></Where><OrderBy><FieldRef Name="Title" Ascending="TRUE"/></OrderBy>'
        $normalized = '<Where><And><Eq><FieldRef Name="_ModerationStatus" /><Value Type="ModStat">0</Value></Eq><Or><IsNull><FieldRef Name="StoryStatus" /></IsNull><Neq><FieldRef Name="StoryStatus" /><Value Type="Choice">Retired</Value></Neq></Or></And></Where><OrderBy><FieldRef Name="Title" Ascending="TRUE" /></OrderBy>'
        $different = $normalized.Replace('Retired', 'Rejected')
        (Test-CoECatalogViewQueryEqual $normalized $expected) | Should Be $true
        (Test-CoECatalogViewQueryEqual $different $expected) | Should Be $false
    }
    It "accepts SharePoint-returned server-relative view URLs with literal spaces" {
        $url = Resolve-CoESharePointReturnedUrl "/sites/CoE/Lists/CopilotLearningPaths/Learning steps.aspx" `
            "Learning reader view" "https://example.sharepoint.com/sites/CoE"
        $url | Should Be "https://example.sharepoint.com/sites/CoE/Lists/CopilotLearningPaths/Learning%20steps.aspx"
        { Resolve-CoESharePointReturnedUrl "/sites/Other/Lists/CopilotLearningPaths/Learning steps.aspx" `
            "Learning reader view" "https://example.sharepoint.com/sites/CoE" } | Should Throw
    }
}

Describe "Reviewer group permission model" {
    BeforeEach {
        $script:list = [pscustomobject]@{ Id = "original-list"; Title = "Catalog" }
        $script:groupId = 11
        $script:ownersId = 3
        $script:reviewers = @([pscustomobject]@{ Id = 10; LoginName = "i:0#.f|membership|reviewer@example.org" })
        $script:state = [pscustomobject]@{
            Unique = $false; Moderation = $false; Versioning = $false; Draft = "Reader"
            GroupExists = $false; Members = @(); RoleExists = $false
            Assignments = @(
                [pscustomobject]@{ Id = 3; Roles = @("Full Control") },
                [pscustomobject]@{ Id = 5; Roles = @("Edit") },
                [pscustomobject]@{ Id = 4; Roles = @("Read") },
                [pscustomobject]@{ Id = 10; Roles = @("Limited Access") }) }
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:contributor = [pscustomobject]@{ Name = "Contribute"; BasePermissions = $null }
        Mock Write-Host {}
        Mock Start-Sleep {}
        Mock Resolve-CoECatalogReviewers { $script:reviewers }
        Mock Assert-CoECatalogItemInheritance {}
        Mock Get-PnPProperty {}
        Mock Get-PnPContext { $c = [pscustomobject]@{}; $c | Add-Member ScriptMethod Load { param($o) }; $c }
        Mock Invoke-PnPQuery {}
        Mock Test-CoECatalogReviewRole { $true }
        Mock Get-PnPRoleDefinition {
            if ($Identity -eq "Contribute") { return $script:contributor }
            if ($Identity -eq "CoE Catalog Reviewer" -and $script:state.RoleExists) { return [pscustomobject]@{ Name = "CoE Catalog Reviewer"; BasePermissions = $null } }
        }
        Mock Add-PnPRoleDefinition { $script:calls.Add("role:create"); $script:state.RoleExists = $true }
        Mock Get-PnPGroup { if ($script:state.GroupExists) { [pscustomobject]@{ Id = $script:groupId; Title = "CoE Catalog Reviewers" } } }
        Mock New-PnPGroup { $script:calls.Add("group:create"); $script:state.GroupExists = $true; [pscustomobject]@{ Id = $script:groupId; Title = $Title } }
        Mock Get-PnPGroupMember { @($script:state.Members | ForEach-Object { [pscustomobject]@{ LoginName = $_ } }) }
        Mock Add-PnPGroupMember { $script:calls.Add("group:add:$LoginName"); $script:state.Members += $LoginName }
        Mock Get-PnPWeb { [pscustomobject]@{ AssociatedOwnerGroup = [pscustomobject]@{ Id = $script:ownersId } } }
        Mock Get-PnPList {
            $assignments = @($script:state.Assignments | ForEach-Object {
                [pscustomobject]@{ Member = [pscustomobject]@{ Id = $_.Id }
                    RoleDefinitionBindings = @($_.Roles | ForEach-Object { [pscustomobject]@{ Name = $_ } }) } })
            [pscustomobject]@{ Id = "original-list"; HasUniqueRoleAssignments = $script:state.Unique; RoleAssignments = $assignments
                EnableVersioning = $script:state.Versioning; EnableModeration = $script:state.Moderation
                DraftVersionVisibility = $script:state.Draft }
        }
        Mock Set-PnPList {
            if ($BreakRoleInheritance) {
                if (-not $CopyRoleAssignments -or $ClearSubscopes) { throw "Unsafe inheritance operation" }
                $script:calls.Add("list:break")
                $script:state.Unique = $true
                # SharePoint does not copy Limited Access entries when inheritance is broken.
                $script:state.Assignments = @($script:state.Assignments | Where-Object { $_.Roles -notcontains "Limited Access" })
            } else {
                $script:calls.Add("list:approval")
                $script:state.Versioning = $EnableVersioning; $script:state.Moderation = $EnableModeration
                $script:state.Draft = [string]$DraftVersionVisibility
            }
        }
        Mock Set-PnPListPermission {
            $script:calls.Add("perm:$Group`:$AddRole")
            if (-not $script:state.Unique) { throw "Permission written to an inheriting list" }
            $script:state.Assignments = @($script:state.Assignments | Where-Object { $_.Id -ne $script:groupId }) +
                [pscustomobject]@{ Id = $script:groupId; Roles = @($AddRole) }
        }
    }
    It "grants the reviewer group, not an inherited principal, and survives Limited Access being dropped on copy" {
        Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline
        $state.Unique | Should Be $true
        @($state.Assignments | Where-Object Id -eq 10).Count | Should Be 0
        (@($state.Assignments | Where-Object Id -eq $groupId)[0].Roles -join ",") | Should Be "CoE Catalog Reviewer"
        (@($state.Assignments | Where-Object Id -eq $ownersId)[0].Roles -join ",") | Should Be "Full Control"
        ($calls -join "|") | Should Match "list:break"
        ($calls -join "|") | Should Match "perm:CoE Catalog Reviewers:CoE Catalog Reviewer"
        $state.Moderation | Should Be $true
        $state.Draft | Should Be "Approver"
    }
    It "never reads or updates a principal from the inherited snapshot" {
        Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline
        Assert-MockCalled Set-PnPListPermission -Times 1 -Exactly -Scope It -ParameterFilter { $Group -eq "CoE Catalog Reviewers" -and -not $User }
        Get-Command Get-CoECatalogAclSnapshot -ErrorAction SilentlyContinue | Should BeNullOrEmpty
        Get-Command Set-CoECatalogRoleBindings -ErrorAction SilentlyContinue | Should BeNullOrEmpty
        Get-Command Get-CoECatalogPermissionPlan -ErrorAction SilentlyContinue | Should BeNullOrEmpty
    }
    It "creates the permission level, group and membership once and does nothing on a rerun" {
        Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline
        $first = @($calls | Where-Object { $_ -match '^(role|group)' })
        $first.Count | Should Be 3
        $calls.Clear()
        Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline
        @($calls | Where-Object { $_ -match '^(role|group)' }).Count | Should Be 0
        ($calls -join "|") | Should Not Match "list:break"
    }
    It "reuses one group and one permission level across all three catalogs" {
        1..3 | ForEach-Object {
            Set-CoECatalogReviewPermissions -List ([pscustomobject]@{ Id = "original-list"; Title = "Catalog $_" }) -ResolvedReviewers $reviewers -Connection offline
            $state.Unique = $false
            $state.Assignments = @([pscustomobject]@{ Id = 3; Roles = @("Full Control") }, [pscustomobject]@{ Id = 10; Roles = @("Limited Access") })
        }
        @($calls | Where-Object { $_ -eq "group:create" }).Count | Should Be 1
        @($calls | Where-Object { $_ -eq "role:create" }).Count | Should Be 1
        @($calls | Where-Object { $_ -like "perm:*" }).Count | Should Be 3
    }
    It "adds only reviewers who are not already in the group" {
        $state.GroupExists = $true
        $state.RoleExists = $true
        $state.Members = @("i:0#.f|membership|reviewer@example.org")
        Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline
        Assert-MockCalled Add-PnPGroupMember -Times 0 -Exactly -Scope It
        $script:reviewers = @($reviewers) + [pscustomobject]@{ Id = 11; LoginName = "i:0#.f|membership|second@example.org" }
        $state.Unique = $false
        Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline
        Assert-MockCalled Add-PnPGroupMember -Times 1 -Exactly -Scope It -ParameterFilter { $LoginName -like "*second@example.org" }
    }
    It "does not break inheritance again when the list already has its own permissions" {
        $state.Unique = $true
        $state.Assignments = @([pscustomobject]@{ Id = 3; Roles = @("Full Control") })
        Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline
        Assert-MockCalled Set-PnPList -Times 0 -Exactly -Scope It -ParameterFilter { $BreakRoleInheritance }
    }
    It "does not touch permissions when no reviewers are configured but still enables approval" {
        Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers @() -Connection offline
        Assert-MockCalled Set-PnPListPermission -Times 0 -Exactly -Scope It
        Assert-MockCalled New-PnPGroup -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-PnPList -Times 0 -Exactly -Scope It -ParameterFilter { $BreakRoleInheritance }
        $state.Moderation | Should Be $true
    }
    It "resolves reviewers itself only when none were pre-resolved" {
        Set-CoECatalogReviewPermissions -List $list -ReviewerUPNs reviewer@example.org -Connection offline
        Assert-MockCalled Resolve-CoECatalogReviewers -Times 1 -Exactly -Scope It
        $state.Unique = $false
        Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline
        Assert-MockCalled Resolve-CoECatalogReviewers -Times 1 -Exactly -Scope It
    }
    It "fails before any change when reviewer resolution or item permissions fail" {
        Mock Resolve-CoECatalogReviewers { throw "Guest rejected" }
        { Set-CoECatalogReviewPermissions -List $list -ReviewerUPNs guest@example.org -Connection offline } | Should Throw "Guest rejected"
        Assert-MockCalled Set-PnPList -Times 0 -Exactly -Scope It
        Mock Assert-CoECatalogItemInheritance { throw "Unique item permissions require administrator review" }
        { Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline } | Should Throw "administrator review"
        Assert-MockCalled Set-PnPList -Times 0 -Exactly -Scope It
        Assert-MockCalled New-PnPGroup -Times 0 -Exactly -Scope It
    }
    It "refuses an existing reviewer permission level with unexpected permissions" {
        $state.RoleExists = $true
        Mock Test-CoECatalogReviewRole { $false }
        { Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline } | Should Throw "exactly Contribute"
        Assert-MockCalled Add-PnPRoleDefinition -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-PnPListPermission -Times 0 -Exactly -Scope It
    }
    It "propagates group, inheritance and grant errors without success claims" {
        Mock New-PnPGroup { throw "403 group denied" }
        { Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline } | Should Throw "403 group denied"
        Assert-MockCalled Set-PnPList -Times 0 -Exactly -Scope It
        $state.GroupExists = $true
        Mock Set-PnPList { throw "403 break denied" }
        { Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline } | Should Throw "403 break denied"
        Assert-MockCalled Set-PnPListPermission -Times 0 -Exactly -Scope It
    }
    It "fails verification when the grant is ignored" {
        Mock Set-PnPListPermission {}
        { Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline } | Should Throw "could not be verified"
        $state.Moderation | Should Be $false
    }
    It "fails verification when the site Owners lose Full Control" {
        Mock Set-PnPListPermission {
            $script:state.Assignments = @([pscustomobject]@{ Id = $script:groupId; Roles = @("CoE Catalog Reviewer") })
        }
        { Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline } | Should Throw "Owners must keep Full Control"
    }
    It "retries the read-back while SharePoint propagates the grant" {
        $script:reads = 0
        $good = $null
        Mock Set-PnPListPermission {
            $script:state.Assignments = @($script:state.Assignments | Where-Object { $_.Id -ne $script:groupId }) +
                [pscustomobject]@{ Id = $script:groupId; Roles = @($AddRole) }
        }
        Mock Get-PnPList {
            $script:reads++
            $roles = $script:state.Assignments
            if ($script:reads -le 3) { $roles = @($roles | Where-Object { $_.Id -ne $script:groupId }) }
            $assignments = @($roles | ForEach-Object {
                [pscustomobject]@{ Member = [pscustomobject]@{ Id = $_.Id }
                    RoleDefinitionBindings = @($_.Roles | ForEach-Object { [pscustomobject]@{ Name = $_ } }) } })
            [pscustomobject]@{ Id = "original-list"; HasUniqueRoleAssignments = $script:state.Unique; RoleAssignments = $assignments
                EnableVersioning = $true; EnableModeration = $true; DraftVersionVisibility = "Approver" }
        }
        Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline
        Assert-MockCalled Start-Sleep -Times 1 -Scope It
    }
    It "fails rather than seeding when content approval settings are ignored" {
        $state.Unique = $true
        Mock Get-PnPList {
            [pscustomobject]@{ Id = "original-list"; HasUniqueRoleAssignments = $true; RoleAssignments = @(
                [pscustomobject]@{ Member = [pscustomobject]@{ Id = 3 }; RoleDefinitionBindings = @([pscustomobject]@{ Name = "Full Control" }) },
                [pscustomobject]@{ Member = [pscustomobject]@{ Id = $script:groupId }; RoleDefinitionBindings = @([pscustomobject]@{ Name = "CoE Catalog Reviewer" }) })
                EnableVersioning = $true; EnableModeration = $false; DraftVersionVisibility = "Reader" }
        }
        { Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline } | Should Throw "content approval settings"
    }
    It "rejects a returned different list ID" {
        Mock Get-PnPList { [pscustomobject]@{ Id = "wrong"; HasUniqueRoleAssignments = $false } }
        { Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $reviewers -Connection offline } | Should Throw "original list ID"
    }
}

Describe "Catalog item permission guard" {
    It "stops on unique item permissions without resetting or widening them" {
        Mock Get-PnPListItem { @([pscustomobject]@{ Id = 1; HasUniqueRoleAssignments = $true }) }
        { Assert-CoECatalogItemInheritance ([pscustomobject]@{ Id = "list"; Title = "Catalog" }) offline } |
            Should Throw "item '1' has unique permissions"
    }
    It "passes when every item inherits its list permissions" {
        Mock Get-PnPListItem { @([pscustomobject]@{ Id = 1; HasUniqueRoleAssignments = $false }) }
        { Assert-CoECatalogItemInheritance ([pscustomobject]@{ Id = "list"; Title = "Catalog" }) offline } | Should Not Throw
    }
}

Describe "Verified in-tenant Member reviewer resolution" {
    BeforeEach {
        $script:tenant = "11111111-1111-1111-1111-111111111111"
        Mock Get-PnPTenantId { $script:tenant }
        Mock Get-PnPAccessToken { [pscustomobject]@{ Claims = @([pscustomobject]@{ Type = "tid"; Value = $script:tenant }) } }
        Mock Invoke-PnPGraphMethod {
            $upn = [uri]::UnescapeDataString(($Url -split 'users/')[1].Split("?")[0])
            [pscustomobject]@{ id = "22222222-2222-2222-2222-222222222222"; userType = "Member"; userPrincipalName = $upn }
        }
        Mock New-PnPUser { [pscustomobject]@{ Id = 20; LoginName = "i:0#.f|membership|$LoginName" } }
    }
    It "resolves every Member before registering principals and deduplicates case-insensitive UPNs" {
        $users = @(Resolve-CoECatalogReviewers @("REVIEWER@example.org", "reviewer@example.org") offline)
        $users.Count | Should Be 1
        Assert-MockCalled Invoke-PnPGraphMethod -Times 1 -Exactly -Scope It
        Assert-MockCalled New-PnPUser -Times 1 -Exactly -Scope It
    }
    It "rejects guests, unresolved identities, missing userType and bad immutable IDs without registering users" {
        foreach ($identity in @(
            [pscustomobject]@{ id = "22222222-2222-2222-2222-222222222222"; userType = "Guest"; userPrincipalName = "reviewer@example.org" },
            [pscustomobject]@{ id = "bad"; userType = "Member"; userPrincipalName = "reviewer@example.org" },
            [pscustomobject]@{ id = "22222222-2222-2222-2222-222222222222"; userPrincipalName = "reviewer@example.org" })) {
            $script:identity = $identity
            Mock Invoke-PnPGraphMethod { $script:identity }
            { Resolve-CoECatalogReviewers @("reviewer@example.org") offline } | Should Throw
        }
        Mock Invoke-PnPGraphMethod { throw "404 not found" }
        { Resolve-CoECatalogReviewers @("reviewer@example.org") offline } | Should Throw "404"
        Assert-MockCalled New-PnPUser -Times 0 -Exactly -Scope It
    }
    It "checks the full roster before registering even the first reviewer" {
        Mock Invoke-PnPGraphMethod {
            if ($Url -match "guest") { throw "Guest rejected" }
            [pscustomobject]@{ id = "22222222-2222-2222-2222-222222222222"; userType = "Member"; userPrincipalName = "reviewer@example.org" }
        }
        { Resolve-CoECatalogReviewers @("reviewer@example.org", "guest@example.org") offline } | Should Throw
        Assert-MockCalled New-PnPUser -Times 0 -Exactly -Scope It
    }
    It "rejects tenant-token mismatches and invalid addresses" {
        Mock Get-PnPAccessToken { [pscustomobject]@{ Claims = @([pscustomobject]@{ Type = "tid"; Value = "33333333-3333-3333-3333-333333333333" }) } }
        { Resolve-CoECatalogReviewers @("reviewer@example.org") offline } | Should Throw "tenant"
        { Resolve-CoECatalogReviewers @("not-an-address") offline } | Should Throw "UPN"
        Assert-MockCalled New-PnPUser -Times 0 -Exactly -Scope It
    }
    It "rejects unexpected Graph UPNs and unverifiable SharePoint principals" {
        Mock Invoke-PnPGraphMethod { [pscustomobject]@{ id = "22222222-2222-2222-2222-222222222222"
            userType = "Member"; userPrincipalName = "other@example.org" } }
        { Resolve-CoECatalogReviewers @("reviewer@example.org") offline } | Should Throw "exact"
        Mock Invoke-PnPGraphMethod { [pscustomobject]@{ id = "22222222-2222-2222-2222-222222222222"
            userType = "Member"; userPrincipalName = "reviewer@example.org" } }
        Mock New-PnPUser { [pscustomobject]@{ Id = 20; LoginName = "i:0#.f|membership|other@example.org" } }
        { Resolve-CoECatalogReviewers @("reviewer@example.org") offline } | Should Throw "principal"
    }
}
