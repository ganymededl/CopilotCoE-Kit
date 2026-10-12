# Copilot Prompt Library catalog (kit 3.6).
# Source files use the Microsoft 365 admin center "Copilot > Prompts > Import" CSV format, unchanged:
#   Title, Description, Display Prompt, Prompt Text, Products, Department, Task Type, Locale
# The kit reads them and writes list rows. It never rewrites the files and never resolves the {{placeholders}}
# inside prompts (they are for the person using the prompt).

$script:CoEPromptColumns = @("Title", "Description", "Display Prompt", "Prompt Text", "Products", "Department", "Task Type", "Locale")
$script:CoEPromptTaskTypes = @("Analyze", "Ask", "Assist", "Catch up", "Code", "Create", "Design", "Edit", "Execute",
    "Find", "Learn", "Prepare", "Schedule", "Understand")

function Read-CoEOrgPromptFiles {
    <#
    .SYNOPSIS
    Reads every *.csv in a folder (the staged SeedContent\OrgPrompts) and returns validated prompt rows.
    .NOTES
    Empty files are skipped: an empty file in <OrgPath>\Content\OrgPrompts with a base file's name removes that
    base file. Limits follow Microsoft Learn "Organizational prompts for Microsoft Copilot": Title 35,
    Display Prompt 132, Prompt Text 8,000, Description 200, Department 120 characters, 100 prompts per file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Folder)
    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return $rows.ToArray() }
    $keys = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Folder -File -Filter "*.csv" | Where-Object Name -notlike "README*" | Sort-Object Name)) {
        $raw = [IO.File]::ReadAllText($file.FullName)
        if ([string]::IsNullOrWhiteSpace($raw.TrimStart([char]0xFEFF))) { continue }
        $context = "OrgPrompts\$($file.Name)"
        $headerLine = ($raw.TrimStart([char]0xFEFF) -split "\r?\n", 2)[0]
        # Admin center column names contain no commas or quotes, so a plain split reads the header exactly.
        $header = @($headerLine -split "," | ForEach-Object { $_.Trim().Trim('"') })
        if (($header -join "|") -cne ($script:CoEPromptColumns -join "|")) {
            throw "$context : the header must be exactly '$($script:CoEPromptColumns -join ',')' (the admin center import format)."
        }
        $items = @($raw.TrimStart([char]0xFEFF) | ConvertFrom-Csv)
        if ($items.Count -gt 100) { throw "$context : $($items.Count) prompts; the admin center imports at most 100 per file." }
        $line = 1
        foreach ($item in $items) {
            $line++
            $where = "$context row $line"
            $values = [ordered]@{}
            foreach ($column in $script:CoEPromptColumns) { $values[$column] = ([string]$item.$column).Trim() }
            foreach ($required in @("Title", "Display Prompt", "Prompt Text", "Products", "Task Type", "Locale")) {
                if (-not $values[$required]) { throw "$where : '$required' is required." }
            }
            $limits = @{ "Title" = 35; "Display Prompt" = 132; "Prompt Text" = 8000; "Description" = 200; "Department" = 120 }
            foreach ($column in $limits.Keys) {
                if ($values[$column].Length -gt $limits[$column]) {
                    throw "$where : '$column' is $($values[$column].Length) characters; the admin center limit is $($limits[$column])."
                }
            }
            if ($values["Task Type"] -cnotin $script:CoEPromptTaskTypes) {
                throw "$where : Task Type '$($values["Task Type"])' is not a supported admin center task type."
            }
            if ($values["Locale"] -notmatch '^[a-z]{2,3}-[A-Z]{2}$') { throw "$where : Locale '$($values["Locale"])' is not a locale such as en-US." }
            $key = ($values["Title"] + "|" + $values["Locale"]).ToLowerInvariant()
            if ($keys.ContainsKey($key)) {
                throw "$where : the title '$($values["Title"])' ($($values["Locale"])) is already used in $($keys[$key]). Titles must be unique."
            }
            $keys[$key] = $context
            $rows.Add([pscustomobject]@{
                Title = $values["Title"]; Description = $values["Description"]; DisplayPrompt = $values["Display Prompt"]
                PromptText = $values["Prompt Text"]; Products = $values["Products"]; Department = $values["Department"]
                TaskType = $values["Task Type"]; Locale = $values["Locale"]; Source = $file.Name })
        }
    }
    return $rows.ToArray()
}

function Sync-CoEPromptCatalog {
    <#
    .SYNOPSIS
    Creates or updates the Copilot Prompt Library list and inserts prompts that are not there yet.
    .NOTES
    Insert-only, keyed by Title + Locale: existing rows (and edits made to them) are never changed or removed.
    Prompts from the environment's base files and the organization's own files are inserted approved, because
    publishing them is the organization's decision. Prompts people add on the site wait for CoE approval.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][string]$SiteUrl,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Prompts,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ResolvedReviewers)
    $site = Assert-CoECatalogSiteUrl $SiteUrl
    $catalog = Get-CoECatalogList "Copilot Prompt Library" "Lists/CopilotPromptLibrary" $site $Connection
    $list = $catalog.List
    Set-CoECatalogReviewPermissions -List $list -ResolvedReviewers $ResolvedReviewers -Connection $Connection
    $definitions = @{
        PromptDisplay = @{ Type = "Text"; Title = "Display prompt" }
        PromptText = @{ Type = "Note"; Title = "Prompt" }
        PromptDescription = @{ Type = "Note"; Title = "Description" }
        PromptProducts = @{ Type = "Text"; Title = "Products" }
        PromptDepartment = @{ Type = "Text"; Title = "Department" }
        PromptTaskType = @{ Type = "Choice"; Title = "Task type"; Choices = $script:CoEPromptTaskTypes }
        PromptLocale = @{ Type = "Text"; Title = "Locale" }
        PromptSource = @{ Type = "Text"; Title = "Source file" }
    }
    foreach ($name in @($definitions.Keys)) { $definitions[$name].Presentation = @{ Title = $definitions[$name].Title } }
    Sync-CoECatalogFields $list $definitions $Connection | Out-Null
    $existing = @(Get-PnPListItem -List $list.Id -Fields Title,PromptLocale -PageSize 500 -Connection $Connection -ErrorAction Stop)
    $keys = @{}
    foreach ($item in $existing) {
        $key = ([string]$item.FieldValues["Title"] + "|" + [string]$item.FieldValues["PromptLocale"]).ToLowerInvariant()
        $keys[$key] = $true
    }
    $added = 0
    $preserved = 0
    foreach ($prompt in $Prompts) {
        $key = ($prompt.Title + "|" + $prompt.Locale).ToLowerInvariant()
        if ($keys.ContainsKey($key)) { $preserved++; continue }
        $values = @{
            Title = $prompt.Title; PromptDisplay = $prompt.DisplayPrompt; PromptText = $prompt.PromptText
            PromptDescription = $prompt.Description; PromptProducts = $prompt.Products; PromptDepartment = $prompt.Department
            PromptTaskType = $prompt.TaskType; PromptLocale = $prompt.Locale; PromptSource = $prompt.Source
            "_ModerationStatus" = 0
        }
        Add-PnPListItem -List $list.Id -Values $values -Connection $Connection -ErrorAction Stop | Out-Null
        $keys[$key] = $true
        $added++
        if ($added % 25 -eq 0) { Write-CoEStep "Prompts added" "$added of $($Prompts.Count - $preserved)" }
    }
    $approved = '<Eq><FieldRef Name="_ModerationStatus"/><Value Type="ModStat">0</Value></Eq>'
    $order = '<OrderBy><FieldRef Name="Title" Ascending="TRUE"/></OrderBy>'
    $readerFields = @("Title", "PromptDisplay", "PromptText", "PromptTaskType", "PromptProducts")
    $allFields = @("Title", "PromptDisplay", "PromptText", "PromptDescription", "PromptProducts", "PromptDepartment",
        "PromptTaskType", "PromptLocale", "PromptSource")
    $prompts = Sync-CoECatalogView $list "Prompts" $readerFields `
        ('<Where>' + $approved + '</Where><GroupBy Collapse="TRUE"><FieldRef Name="PromptDepartment" Ascending="TRUE"/></GroupBy>' + $order) `
        $Connection -SetAsDefault
    $byTask = Sync-CoECatalogView $list "By task type" $readerFields `
        ('<Where>' + $approved + '</Where><GroupBy Collapse="TRUE"><FieldRef Name="PromptTaskType" Ascending="TRUE"/></GroupBy>' + $order) `
        $Connection
    $work = Sync-CoECatalogView $list "Copilot work (license needed)" $readerFields `
        ('<Where><And>' + $approved + '<Contains><FieldRef Name="PromptProducts"/><Value Type="Text">Copilot work</Value></Contains></And></Where>' + $order) `
        $Connection
    $review = Sync-CoECatalogView $list "Review" $allFields `
        ('<Where><Eq><FieldRef Name="_ModerationStatus"/><Value Type="ModStat">2</Value></Eq></Where>' + $order) $Connection
    $management = Sync-CoECatalogView $list "Manage all entries" @($allFields + @("_ModerationStatus")) $order $Connection
    [pscustomobject]@{ List = $list; ListUrl = $catalog.ListUrl; Added = $added; Preserved = $preserved
        Views = [pscustomobject]@{ Prompts = $prompts; ByTaskType = $byTask; CopilotWork = $work; Review = $review; Management = $management }
        ReaderViewUrl = Resolve-CoESharePointReturnedUrl $prompts.ServerRelativeUrl "Prompt reader view" $site }
}
