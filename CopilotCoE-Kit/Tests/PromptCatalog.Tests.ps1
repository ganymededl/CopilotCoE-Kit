# Offline Pester 3 regression tests. Every external seam fails closed unless mocked.
Set-StrictMode -Version Latest
$kitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $kitRoot "Internal\SecurityPosture.ps1")
. (Join-Path $kitRoot "Internal\AdoptionCatalogs.ps1")
. (Join-Path $kitRoot "Internal\PromptCatalog.ps1")

function Get-PnPList { [CmdletBinding()] param($Identity, $Includes, $Connection) throw "Unmocked list read" }
function New-PnPList { [CmdletBinding()] param($Title, $Template, $Url, [switch]$EnableVersioning, $Connection) throw "Unmocked list creation" }
function Get-PnPField { [CmdletBinding()] param($List, $Identity, $Connection) throw "Unmocked field read" }
function Add-PnPFieldFromXml { [CmdletBinding()] param($List, $FieldXml, $Connection) throw "Unmocked field write" }
function Get-PnPListItem { [CmdletBinding()] param($List, $Fields, $Includes, $PageSize, $Connection) throw "Unmocked item read" }
function Add-PnPListItem { [CmdletBinding()] param($List, $Values, $Connection) throw "Unmocked item insertion" }
function Get-PnPView { [CmdletBinding()] param($List, $Identity, $Includes, $Connection) throw "Unmocked view read" }
function Add-PnPView { [CmdletBinding()] param($List, $Title, $Fields, $Query, $RowLimit,
    [switch]$Paged, [switch]$SetAsDefault, $Connection) throw "Unmocked view creation" }
function Set-PnPView { [CmdletBinding()] param($List, $Identity, $Fields, $Values, $Connection) throw "Unmocked view update" }
function Get-PnPProperty { [CmdletBinding()] param($ClientObject, $Property, $Connection) throw "Unmocked CSOM property read" }
function Get-PnPContext { [CmdletBinding()] param($Connection) throw "Unmocked CSOM context" }
function Invoke-PnPQuery { [CmdletBinding()] param($Connection) throw "Unmocked CSOM write" }

function New-TestPromptRow([string]$Title = "Summarize this", [string]$Locale = "en-US", [string]$Source = "highered_prompt_library_1_of_3.csv") {
    [pscustomobject]@{ Title = $Title; Description = "Short summary helper"; DisplayPrompt = "Summarize this for me"
        PromptText = "Summarize {{document}} in three bullet points."; Products = "Copilot Chat"
        Department = "Office of Information Technology"; TaskType = "Catch up"; Locale = $Locale; Source = $Source }
}
function New-TestCatalogField([string]$FieldXml) {
    $xml = [xml]$FieldXml
    $field = [pscustomobject]@{ InternalName = [string]$xml.Field.Name; TypeAsString = [string]$xml.Field.Type
        Choices = @($xml.SelectNodes("//CHOICE") | ForEach-Object InnerText); SchemaXml = $FieldXml
        Title = [string]$xml.Field.DisplayName; CustomFormatter = ""; DefaultValue = "" }
    $field | Add-Member ScriptMethod Update {}
    $field
}
function Initialize-TestCatalogMocks {
    $script:lists = @()
    $script:fieldsByList = @{}
    $script:itemsByList = @{}
    $script:viewsByList = @{}
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
    Mock Get-PnPField {
        if (-not $script:aclApproved) { throw "Fields accessed before ACL enforcement" }
        if ($Identity) { $script:fieldsByList[$List] | Where-Object InternalName -eq $Identity }
        else { $script:fieldsByList[$List] }
    }
    Mock Add-PnPFieldFromXml {
        if (-not $script:aclApproved) { throw "Field insertion before ACL enforcement" }
        $field = New-TestCatalogField $FieldXml
        $script:fieldsByList[$List] += $field
        $field
    }
    Mock Get-PnPProperty {}
    Mock Get-PnPListItem { $script:itemsByList[$List] }
    Mock Add-PnPListItem {
        if (-not $script:aclApproved) { throw "Item insertion before ACL enforcement" }
        $item = [pscustomobject]@{ Id = $script:itemsByList[$List].Count + 1; FieldValues = $Values }
        $script:itemsByList[$List] += $item
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
        $view = @($script:viewsByList[$List] | Where-Object Id -eq $Identity)[0]
        if ($null -ne $Fields) { $view.Fields = $Fields }
        if ($Values.ContainsKey("DefaultView") -and $Values.DefaultView) {
            foreach ($old in $script:viewsByList[$List]) { $old.DefaultView = $false }
        }
        foreach ($name in $Values.Keys) { $view | Add-Member NoteProperty $name $Values[$name] -Force }
        $view
    }
}

Describe "Org prompt file validation without tenant activity" {
    BeforeEach {
        $script:folder = Join-Path $TestDrive "OrgPrompts"
        if (Test-Path -LiteralPath $script:folder) { Remove-Item -LiteralPath $script:folder -Recurse -Force }
        New-Item -ItemType Directory -Path $script:folder -Force | Out-Null
        $script:header = "Title,Description,Display Prompt,Prompt Text,Products,Department,Task Type,Locale"
    }
    function Write-TestPromptCsv([string]$Name, [string[]]$Rows) {
        Set-Content -LiteralPath (Join-Path $script:folder $Name) -Value (@($script:header) + $Rows) -Encoding UTF8
    }
    It "returns an empty array for a folder that does not exist" {
        @(Read-CoEOrgPromptFiles -Folder (Join-Path $TestDrive "Missing")).Count | Should Be 0
    }
    It "reads a valid row, trims values, and stamps the source file name" {
        Write-TestPromptCsv "a.csv" @('"Summarize this","Short helper","Summarize this for me","Summarize {{doc}}.","Copilot Chat","IT","Catch up","en-US"')
        $rows = @(Read-CoEOrgPromptFiles -Folder $script:folder)
        $rows.Count | Should Be 1
        $rows[0].Title | Should Be "Summarize this"
        $rows[0].TaskType | Should Be "Catch up"
        $rows[0].Source | Should Be "a.csv"
    }
    It "skips README files and empty files without reading their content" {
        Write-TestPromptCsv "README.txt" @("garbage,not,a,real,csv")
        Set-Content -LiteralPath (Join-Path $script:folder "empty.csv") -Value "" -Encoding UTF8
        @(Read-CoEOrgPromptFiles -Folder $script:folder).Count | Should Be 0
    }
    It "rejects a header that does not exactly match the admin center import format" {
        Set-Content -LiteralPath (Join-Path $script:folder "bad.csv") -Value @("Title,Description,Prompt,Products,Department,Task Type,Locale", 'x,x,x,x,x,Ask,en-US') -Encoding UTF8
        { Read-CoEOrgPromptFiles -Folder $script:folder } | Should Throw "the header must be exactly"
    }
    It "rejects more than 100 prompts in one file" {
        $rows = 1..101 | ForEach-Object { "Title $_,,Display $_,Prompt text,Copilot Chat,IT,Ask,en-US" }
        Write-TestPromptCsv "big.csv" $rows
        { Read-CoEOrgPromptFiles -Folder $script:folder } | Should Throw "at most 100 per file"
    }
    It "requires Title, Display Prompt, Prompt Text, Products, Task Type and Locale" {
        Write-TestPromptCsv "a.csv" @(',,Display,Prompt text,Copilot Chat,IT,Ask,en-US')
        { Read-CoEOrgPromptFiles -Folder $script:folder } | Should Throw "'Title' is required"
    }
    It "enforces the admin center character limits" {
        $longTitle = "T" * 36
        Write-TestPromptCsv "a.csv" @("$longTitle,,Display,Prompt text,Copilot Chat,IT,Ask,en-US")
        { Read-CoEOrgPromptFiles -Folder $script:folder } | Should Throw "'Title' is 36 characters"
    }
    It "rejects a Task Type outside the supported admin center list" {
        Write-TestPromptCsv "a.csv" @('Title,,Display,Prompt text,Copilot Chat,IT,Brainstorm,en-US')
        { Read-CoEOrgPromptFiles -Folder $script:folder } | Should Throw "not a supported admin center task type"
    }
    It "rejects a locale that is not in the xx-XX or xxx-XX shape" {
        Write-TestPromptCsv "a.csv" @('Title,,Display,Prompt text,Copilot Chat,IT,Ask,english')
        { Read-CoEOrgPromptFiles -Folder $script:folder } | Should Throw "is not a locale such as en-US"
    }
    It "rejects a duplicate Title plus Locale across files and names the first file" {
        Write-TestPromptCsv "a.csv" @('Shared title,,Display,Prompt text,Copilot Chat,IT,Ask,en-US')
        Write-TestPromptCsv "b.csv" @('Shared title,,Display,Prompt text,Copilot Chat,IT,Ask,en-US')
        { Read-CoEOrgPromptFiles -Folder $script:folder } | Should Throw "OrgPrompts\a.csv"
    }
    It "allows the same title in a different locale" {
        Write-TestPromptCsv "a.csv" @('Shared title,,Display,Prompt text,Copilot Chat,IT,Ask,en-US', 'Shared title,,Display,Prompt text,Copilot Chat,IT,Ask,fr-FR')
        @(Read-CoEOrgPromptFiles -Folder $script:folder).Count | Should Be 2
    }
}

Describe "Insert-only Copilot Prompt Library catalog" {
    BeforeEach {
        Initialize-TestCatalogMocks
        $script:promptArgs = @{ Connection = "offline"; SiteUrl = "https://example.sharepoint.com/sites/CoE"
            Prompts = @(New-TestPromptRow); ResolvedReviewers = @() }
    }
    It "creates one versioned list, the 8 custom fields, and all 5 views with Prompts as the default" {
        $result = Sync-CoEPromptCatalog @promptArgs
        $result.List.Id | Should Be "list-1"
        $result.Added | Should Be 1
        $result.Preserved | Should Be 0
        $result.ListUrl | Should Be "https://example.sharepoint.com/sites/CoE/Lists/CopilotPromptLibrary"
        $fieldsByList["list-1"].Count | Should Be 9
        @($fieldsByList["list-1"] | Where-Object InternalName -eq PromptTaskType)[0].Choices -join "," |
            Should Be ($script:CoEPromptTaskTypes -join ",")
        $result.Views.Prompts.DefaultView | Should Be $true
        $result.Views.ByTaskType.DefaultView | Should Be $false
        $result.Views.Prompts.ViewQuery | Should Match 'PromptDepartment'
        $result.Views.ByTaskType.ViewQuery | Should Match 'PromptTaskType'
        $result.Views.CopilotWork.ViewQuery | Should Match 'Copilot work'
        $result.Views.Review.ViewQuery | Should Match 'Type="ModStat">2'
        ($result.Views.Management.Fields -contains "_ModerationStatus") | Should Be $true
        $result.ReaderViewUrl | Should Be "https://example.sharepoint.com/sites/CoE/Lists/CopilotPromptLibrary/Prompts.aspx"
        Assert-MockCalled Set-CoECatalogReviewPermissions -Times 1 -Exactly -Scope It
        Assert-MockCalled Add-PnPFieldFromXml -Times 8 -Exactly -Scope It
        Assert-MockCalled Add-PnPView -Times 5 -Exactly -Scope It
    }
    It "inserts new prompts approved and marks every row inserted approved, not pending" {
        Sync-CoEPromptCatalog @promptArgs | Out-Null
        $itemsByList["list-1"][0].FieldValues["_ModerationStatus"] | Should Be 0
    }
    It "is insert-only by Title plus Locale: a rerun with the same prompt preserves it and adds nothing" {
        $first = Sync-CoEPromptCatalog @promptArgs
        $itemsByList["list-1"][0].FieldValues.PromptText = "Customer-edited prompt text stays untouched"
        $second = Sync-CoEPromptCatalog @promptArgs
        $second.List.Id | Should Be $first.List.Id
        $second.Added | Should Be 0
        $second.Preserved | Should Be 1
        $itemsByList["list-1"][0].FieldValues.PromptText | Should Be "Customer-edited prompt text stays untouched"
        Assert-MockCalled New-PnPList -Times 1 -Exactly -Scope It
        Assert-MockCalled Add-PnPListItem -Times 1 -Exactly -Scope It
    }
    It "treats the same title in a different locale as a new, separate prompt" {
        Sync-CoEPromptCatalog @promptArgs | Out-Null
        $script:promptArgs.Prompts = @(New-TestPromptRow -Locale "fr-FR")
        (Sync-CoEPromptCatalog @promptArgs).Added | Should Be 1
        $itemsByList["list-1"].Count | Should Be 2
    }
    It "propagates permission failures before any field, item or view is touched" {
        Mock Set-CoECatalogReviewPermissions { throw "403 ACL denied" }
        { Sync-CoEPromptCatalog @promptArgs } | Should Throw "403 ACL denied"
        Assert-MockCalled Add-PnPFieldFromXml -Times 0 -Exactly -Scope It
        Assert-MockCalled Add-PnPListItem -Times 0 -Exactly -Scope It
        Assert-MockCalled Add-PnPView -Times 0 -Exactly -Scope It
    }
    It "permits an opt-out with zero prompts while still securing the catalog and creating its views" {
        $script:promptArgs.Prompts = @()
        $result = Sync-CoEPromptCatalog @promptArgs
        $result.Added | Should Be 0
        Assert-MockCalled Add-PnPListItem -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-CoECatalogReviewPermissions -Times 1 -Exactly -Scope It
        Assert-MockCalled Add-PnPView -Times 5 -Exactly -Scope It
    }
    It "fails duplicate list identities without creating a second list" {
        Sync-CoEPromptCatalog @promptArgs | Out-Null
        $script:lists += $lists[0]
        { Sync-CoEPromptCatalog @promptArgs } | Should Throw "duplicate"
        Assert-MockCalled New-PnPList -Times 1 -Exactly -Scope It
    }
}
