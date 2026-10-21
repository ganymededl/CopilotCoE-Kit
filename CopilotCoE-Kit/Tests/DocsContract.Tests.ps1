# Offline contract tests: Windows PowerShell / installed Pester 3; deployment uses PowerShell 7.
# Every switch a shipped document or message tells an administrator to use must exist on the script that
# the text names. This is the structural guard for the 3.8.18 defects: START-HERE recommended
# 03_Update-CoEContent.ps1 -ReplaceManagedPages (no such parameter) and a shared message told 03 users to
# use -ReplaceManagedFiles (the 03 switch is -ReplaceFiles).
Set-StrictMode -Version Latest
$kitRoot = Split-Path -Parent $PSScriptRoot

$entryScripts = @("01_Register-CoEProvisioningApp.ps1", "02_Install-CopilotCoE.ps1", "03_Update-CoEContent.ps1",
    "04_Remove-CopilotCoE.ps1", "Test-CoEInstall.ps1", "Test-CoELiveRegression.ps1")
$commonParameters = @("Verbose", "Debug", "ErrorAction", "WarningAction", "InformationAction", "ErrorVariable",
    "WarningVariable", "InformationVariable", "OutVariable", "OutBuffer", "PipelineVariable", "ProgressAction")

function Get-ScriptParameterNames([string]$Path) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Script contains parse errors: $Path" }
    $names = @{}
    foreach ($name in $commonParameters) { $names[$name] = $true }
    if ($ast.ParamBlock) {
        foreach ($parameter in $ast.ParamBlock.Parameters) {
            $names[$parameter.Name.VariablePath.UserPath] = $true
            foreach ($attribute in $parameter.Attributes) {
                if ($attribute.TypeName.Name -eq "Alias") {
                    foreach ($argument in $attribute.PositionalArguments) { $names[[string]$argument.Value] = $true }
                }
            }
        }
        foreach ($attribute in $ast.ParamBlock.Attributes) {
            if ($attribute.TypeName.Name -eq "CmdletBinding") {
                foreach ($named in $attribute.NamedArguments) {
                    if ($named.ArgumentName -eq "SupportsShouldProcess") { $names["WhatIf"] = $true; $names["Confirm"] = $true }
                }
            }
        }
    }
    return $names
}

$parameterMap = @{}
foreach ($script in $entryScripts) { $parameterMap[$script] = Get-ScriptParameterNames (Join-Path $kitRoot $script) }
$scriptPattern = '(0[1-4]_[A-Za-z]+-[A-Za-z]+\.ps1|Test-CoELiveRegression\.ps1|Test-CoEInstall\.ps1)'

function ConvertTo-PlainDocumentText([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path)
    if ($Path -like "*.html") {
        $text = [regex]::Replace($text, '(?s)<(script|style)\b.*?</\1>', '')
        $text = [regex]::Replace($text, '<img\b[^>]*>', '')
        $text = [regex]::Replace($text, '<[^>]+>', '')
        $text = [System.Net.WebUtility]::HtmlDecode($text)
    }
    return $text
}

# Returns one record per switch that a document line attaches to a named kit script. A PowerShell backtick at
# the end of a line continues the command on the next line.
function Get-DocumentedSwitchUses([string]$Text, [string]$Source) {
    $lines = $Text -split "`r?`n"
    $joined = New-Object System.Collections.Generic.List[object]
    $index = 0
    while ($index -lt $lines.Count) {
        $line = $lines[$index]
        $first = $index + 1
        while ($line.TrimEnd().EndsWith('`') -and ($index + 1) -lt $lines.Count) {
            $index++
            $line = $line.TrimEnd().TrimEnd('`') + " " + $lines[$index].Trim()
        }
        $joined.Add([pscustomobject]@{ Number = $first; Text = $line })
        $index++
    }
    foreach ($entry in $joined) {
        $matches = [regex]::Matches($entry.Text, $scriptPattern)
        for ($i = 0; $i -lt $matches.Count; $i++) {
            $start = $matches[$i].Index + $matches[$i].Length
            $end = if ($i + 1 -lt $matches.Count) { $matches[$i + 1].Index } else { $entry.Text.Length }
            $segment = $entry.Text.Substring($start, $end - $start)
            foreach ($switch in [regex]::Matches($segment, '(?<![\w\-])-([A-Za-z][A-Za-z0-9]+)\b')) {
                [pscustomobject]@{
                    Source = $Source; Line = $entry.Number; Script = $matches[$i].Value
                    Switch = $switch.Groups[1].Value; Context = $entry.Text.Trim()
                }
            }
        }
    }
}

function Get-InvalidSwitchUses($Uses) {
    foreach ($use in $Uses) {
        if (-not $parameterMap[$use.Script].ContainsKey($use.Switch)) {
            "{0}:{1} {2} has no parameter -{3}  [{4}]" -f $use.Source, $use.Line, $use.Script, $use.Switch, $use.Context
        }
    }
}

Describe "The contract checker itself" {
    It "flags the exact 3.8.18 START-HERE defect" {
        $uses = @(Get-DocumentedSwitchUses '.\03_Update-CoEContent.ps1 -OrgPath <folder> -Scope All -ReplaceManagedPages' "sample")
        @(Get-InvalidSwitchUses $uses).Count | Should Be 1
        (@(Get-InvalidSwitchUses $uses))[0] | Should Match "ReplaceManagedPages"
    }
    It "accepts the real switches, joins backtick continuations and understands aliases" {
        $text = ".\02_Install-CopilotCoE.ps1 ``" + "`n  -OrgPath `$org ``" + "`n  -ContentMode Customer -SeedDemoContent -PublishContent"
        $uses = @(Get-DocumentedSwitchUses $text "sample")
        @($uses | ForEach-Object Switch) -join "," | Should Be "OrgPath,ContentMode,SeedDemoContent,PublishContent"
        @(Get-InvalidSwitchUses $uses).Count | Should Be 0
    }
    It "ties each switch to the nearest preceding script on the same line" {
        $uses = @(Get-DocumentedSwitchUses 'Run 02_Install-CopilotCoE.ps1 -ResumeExisting, then 03_Update-CoEContent.ps1 -Scope All -ReplaceFiles' "sample")
        (@($uses | Where-Object Script -eq "02_Install-CopilotCoE.ps1" | ForEach-Object Switch)) -join "," | Should Be "ResumeExisting"
        (@($uses | Where-Object Script -eq "03_Update-CoEContent.ps1" | ForEach-Object Switch)) -join "," | Should Be "Scope,ReplaceFiles"
        @(Get-InvalidSwitchUses $uses).Count | Should Be 0
    }
    It "does not treat hyphenated words as switches" {
        $uses = @(Get-DocumentedSwitchUses '03_Update-CoEContent.ps1 -Scope Guides   # Copilot-FAQs.md and follow-up' "sample")
        (@($uses | ForEach-Object Switch)) -join "," | Should Be "Scope"
    }
}

Describe "Shipped documents only use switches that exist" {
    $documents = New-Object System.Collections.Generic.List[string]
    foreach ($relative in @("START-HERE.txt", "01_Admin-Quickstart.html", "Org-Template\README.txt")) {
        $path = Join-Path $kitRoot $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) { $documents.Add($path) }
    }
    foreach ($pack in @(Get-ChildItem -LiteralPath (Join-Path $kitRoot "ContentPacks") -Directory -ErrorAction SilentlyContinue)) {
        foreach ($readme in @(Get-ChildItem -LiteralPath $pack.FullName -File -Filter "README*.txt")) { $documents.Add($readme.FullName) }
    }
    It "finds the documents to check" {
        ($documents | ForEach-Object { Split-Path -Leaf $_ }) -contains "START-HERE.txt" | Should Be $true
        ($documents | ForEach-Object { Split-Path -Leaf $_ }) -contains "01_Admin-Quickstart.html" | Should Be $true
    }
    foreach ($document in $documents) {
        $name = Split-Path -Leaf $document
        It "$name names only real parameters for each script" {
            $uses = @(Get-DocumentedSwitchUses (ConvertTo-PlainDocumentText $document) $name)
            $uses.Count | Should BeGreaterThan 0
            (@(Get-InvalidSwitchUses $uses) -join "`n") | Should BeNullOrEmpty
        }
    }
    It "does not tell anyone that an ordinary 03 run preserves managed pages" {
        $text = ConvertTo-PlainDocumentText (Join-Path $kitRoot "START-HERE.txt")
        $text | Should Not Match 'preserved on every later run unless you pass -ReplaceManagedPages'
        $text | Should Not Match 'an ordinary rerun intentionally leaves\s+an already-existing page alone'
    }
    It "keeps the admin quickstart on the published end-to-end sequence" {
        $text = ConvertTo-PlainDocumentText (Join-Path $kitRoot "01_Admin-Quickstart.html")
        $text | Should Match 'Get-FileHash\s+-LiteralPath\s+\$zip\s+-Algorithm\s+SHA256'
        $text | Should Match 'Expand-Archive\s+-LiteralPath\s+\$zip\s+-DestinationPath\s+\$installRoot'
        $text | Should Match 'ContentPacks\\Government-StateLocal'
        $text | Should Match 'Assert-CoEStructuredOrganizationContent\s+-OrgPath\s+\$orgPath'
        $text | Should Match '01_Register-CoEProvisioningApp\.ps1\s+-OrgPath\s+\$orgPath\s+-Interactive'
        $text | Should Match '02_Install-CopilotCoE\.ps1[\s\S]*?-ContentMode\s+Customer[\s\S]*?-SeedDemoContent'
        @([regex]::Matches($text, 'Test-CoEInstall\.ps1[\s\S]*?-ContentMode\s+Customer')).Count |
            Should BeGreaterThan 1
        $text | Should Match '03_Update-CoEContent\.ps1[\s\S]*?-Scope\s+All[\s\S]*?-RepairCapturedPages[\s\S]*?-AuthenticationMode\s+Interactive[\s\S]*?-ContentMode\s+Customer'
    }
    It "distinguishes GitHub source archives from a hash-matched implementation asset" {
        $text = ConvertTo-PlainDocumentText (Join-Path $kitRoot "01_Admin-Quickstart.html")
        $text | Should Match 'Copilot-CoE-Implementation-Kit\.zip'
        $text | Should Match 'Source code \(zip\)'
        $text | Should Match '\.sha256 receipt'
        $html = Get-Content -LiteralPath (Join-Path $kitRoot "01_Admin-Quickstart.html") -Raw
        $html | Should Match 'releases/download/v3\.8\.21/Copilot-CoE-Implementation-Kit\.zip'
        $html | Should Match 'Copilot-CoE-Implementation-Kit\.zip\.sha256'
    }
    It "documents the settings that bind a deployment to its tenant and alias" {
        $text = ConvertTo-PlainDocumentText (Join-Path $kitRoot "01_Admin-Quickstart.html")
        foreach ($field in @("Tenant", "AdminFQDN", "SiteFQDN", "PnPClientID", "SharedChannelOwnerUPN",
                "MailNickname", "OrganizationEmailDomains", "CatalogReviewerUPNs", "LearningEnvironment",
                "GuidesIntro", "StoryAudiences", "ScenarioLibraryUrl")) {
            $text | Should Match ([regex]::Escape($field))
        }
        $text | Should Match 'Never copy a client ID across tenants'
        $text | Should Match 'Controls the Team alias and SharePoint site path'
    }
    It "explains the non-blocking naming-policy permission warning without waiving manual review" {
        $text = ConvertTo-PlainDocumentText (Join-Path $kitRoot "01_Admin-Quickstart.html")
        $text | Should Match 'Directory\.Read\.All'
        $text | Should Match 'Insufficient privileges'
        $text | Should Match 'non-blocking'
        $text | Should Match 'does not prove that no naming policy exists'
        $text | Should Match 'confirm the policy manually'
        $text | Should Match 'Do not grant Directory\.Read\.All solely to remove it'
    }
}

Describe "Messages in kit scripts name switches the caller can use" {
    # A shared helper is reached from both 02 and 03, so a switch it names must exist on the entry script
    # that produced the message, or the message must name that script.
    $verbs = '(?:use|using|with|pass|add|supply|supplying|rerun with|run again with)'
    $shared = @("-GovernanceOnly", "-GuidesOnly")
    $files = @(Get-ChildItem -LiteralPath $kitRoot -Recurse -File -Filter "*.ps1" |
        Where-Object { $_.FullName -notmatch '\\(Tests|RevisionAudit|Backups)\\' })
    It "finds the scripts to check" { $files.Count | Should BeGreaterThan 10 }
    It "never recommends a switch that the named or calling script lacks" {
        $problems = New-Object System.Collections.Generic.List[string]
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($kitRoot.Length + 1)
            $isEntry = $entryScripts -contains $file.Name
            $lineNumber = 0
            foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
                $lineNumber++
                if ($line.TrimStart().StartsWith("#")) { continue }
                foreach ($match in [regex]::Matches($line, "\b(?i:$verbs)\s+(-[A-Z][A-Za-z]+)")) {
                    $switch = $match.Groups[1].Value
                    if ($shared -contains $switch) { continue }
                    $bare = $switch.TrimStart("-")
                    $named = $null
                    foreach ($candidate in [regex]::Matches($line, $scriptPattern)) {
                        if ($candidate.Index -lt $match.Index) { $named = $candidate }
                    }
                    if ($named) {
                        if (-not $parameterMap[$named.Value].ContainsKey($bare)) {
                            $problems.Add("${relative}:$lineNumber names $($named.Value) but it has no -$bare")
                        }
                    } elseif ($isEntry) {
                        if (-not $parameterMap[$file.Name].ContainsKey($bare)) {
                            $problems.Add("${relative}:$lineNumber recommends -$bare, which $($file.Name) does not accept")
                        }
                    } elseif (-not ($parameterMap["02_Install-CopilotCoE.ps1"].ContainsKey($bare) -and
                            $parameterMap["03_Update-CoEContent.ps1"].ContainsKey($bare))) {
                        $problems.Add("${relative}:$lineNumber recommends -$bare, which 02 and 03 do not both accept, without naming a script")
                    }
                }
            }
        }
        ($problems -join "`n") | Should BeNullOrEmpty
    }
    It "pairs every entry script named in a script message with parameters that script has" {
        $problems = New-Object System.Collections.Generic.List[string]
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($kitRoot.Length + 1)
            $text = (@([System.IO.File]::ReadAllLines($file.FullName) | Where-Object {
                -not $_.TrimStart().StartsWith("#") -and $_ -notmatch 'Join-Path|Get-Content|Select-String|-match|-replace' })) -join "`n"
            foreach ($problem in @(Get-InvalidSwitchUses @(Get-DocumentedSwitchUses $text $relative))) { $problems.Add($problem) }
        }
        ($problems -join "`n") | Should BeNullOrEmpty
    }
}
