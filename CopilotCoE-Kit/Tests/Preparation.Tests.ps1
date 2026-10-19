# Run with the installed Pester 3 Windows PowerShell runner; integration uses installed PowerShell 7.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "New-CoETestFixture.ps1")
$kitRoot = Split-Path -Parent $PSScriptRoot
$preparePath = Join-Path $kitRoot "Internal\Prepare-CopilotCoE.ps1"
$packagePath = Join-Path (Split-Path -Parent $kitRoot) "Package-CoE-Kit.ps1"
$sourceRoot = Join-Path (Split-Path -Parent $kitRoot) "SourceOriginal\CopilotCoESite"
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source

function Import-TestFunctions([string]$Path) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Script contains parse errors: $Path" }
    foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
            . ([scriptblock]::Create($statement.Extent.Text.Replace("function ", "function script:")))
        }
    }
}
$hasPackager = Test-Path -LiteralPath $packagePath -PathType Leaf
if ($hasPackager) {
    Import-TestFunctions $packagePath
} else {
    Write-Host "Release extraction: authoring-only packaging checks are explicitly skipped; the packager and approved-image manifest are not shipped."
}
Import-TestFunctions $preparePath
. (Join-Path $kitRoot "Internal\OrganizationProfile.ps1")

function Read-TestPnPDocument([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in @($archive.Entries | Where-Object FullName -like "Files/*.xml")) {
            $reader = [IO.StreamReader]::new($entry.Open())
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            if ($text -match '<pnp:SiteCollection\b') { return [xml]$text }
        }
        throw "The fixture package has no provisioning document."
    } finally { $archive.Dispose() }
}

Describe "Configuration-driven organization naming" {
    It "keeps the actual organization name separate from the hub title" {
        $profile = Get-CoEOrganizationProfile ([pscustomobject]@{
            OrgName = "Beacon College"; DisplayName = "University Copilot CoE"; OrgNoun = ""
        })
        $profile.OrgName | Should Be "Beacon College"
        $profile.DisplayName | Should Be "University Copilot CoE"
        $profile.OrgNoun | Should Be "organization"
        $profile.ShortName | Should Be "BC"
        $profile.SampleNotice | Should Be "Sample starter content for review by Beacon College; not official policy or a production commitment."
    }

    It "allows omitted or blank OrgName to fall back to DisplayName" {
        foreach ($settings in @(@{ DisplayName = "Alpine Research Institute" }, @{ OrgName = " "; DisplayName = "Alpine Research Institute" })) {
            $profile = Get-CoEOrganizationProfile -Settings $settings
            $profile.OrgName | Should Be "Alpine Research Institute"
            $profile.ShortName | Should Be "ARI"
        }
    }
    It "derives a blank hub title and preserves intentional grammar and notice values" {
        $profile = Get-CoEOrganizationProfile -Settings @{
            OrgName = "Beacon College"; OrgNoun = "university"; ShortName = "BC-Lab"
            DisplayName = ""; SampleNotice = "Reviewed laboratory content."
        }
        $profile.DisplayName | Should Be "Beacon College Copilot CoE"
        $profile.OrgNoun | Should Be "university"
        $profile.ShortName | Should Be "BC-Lab"
        $profile.SampleNotice | Should Be "Reviewed laboratory content."
    }
    It "gives explicit CLI values precedence including blank default requests and none" {
        $profile = Get-CoEOrganizationProfile -Settings @{
            OrgName = "Old profile"; OrgNoun = "university"; ShortName = "OLD"; DisplayName = "Old hub"; SampleNotice = "Old notice"
        } -Overrides @{ OrgName = "Beacon College"; OrgNoun = ""; ShortName = ""; DisplayName = ""; SampleNotice = "none" }
        $profile.OrgName | Should Be "Beacon College"
        $profile.OrgNoun | Should Be "organization"
        $profile.ShortName | Should Be "BC"
        $profile.DisplayName | Should Be "Beacon College Copilot CoE"
        $profile.SampleNotice | Should Be ""
    }
    It "rejects missing names, unresolved tokens, placeholders and invalid value types" {
        Get-CoETestExceptionMessage { Get-CoEOrganizationProfile -Settings @{} } |
            Should Match '^Set OrgName'
        foreach ($field in @("OrgName", "OrgNoun", "ShortName", "DisplayName", "SampleNotice")) {
            foreach ($invalid in @("<replace me>", "{{OrgName}}", @("one", "two"), 42)) {
                Get-CoETestExceptionMessage {
                    Get-CoEOrganizationProfile -Settings @{ OrgName = "Beacon College" } -Overrides @{ $field = $invalid }
                } | Should Match "^$field (contains a placeholder|must be a text value)"
            }
        }
        Get-CoETestExceptionMessage { Get-CoEOrganizationProfile -Settings @{ OrgName = "Beacon`nCollege" } } |
            Should Match '^OrgName must be a single-line text value'
    }
}

Describe "Explicit learning environment" {
    It "accepts only a declared government or higher-education setting" {
        (Get-CoELearningEnvironment @{ LearningEnvironment = "Government" }) | Should Be "Government"
        (Get-CoELearningEnvironment ([pscustomobject]@{ LearningEnvironment = "HigherEducation" })) |
            Should Be "HigherEducation"
        foreach ($invalid in @($null, @{}, @{ LearningEnvironment = "" },
            @{ LearningEnvironment = "government" }, @{ LearningEnvironment = "HigherEd" },
            @{ LearningEnvironment = 1 })) {
            Get-CoETestExceptionMessage { Get-CoELearningEnvironment $invalid } |
                Should Match '^Set LearningEnvironment to Government or HigherEducation'
        }
    }
    It "requires the setting before both installation and content updates can sign in" {
        foreach ($file in @("02_Install-CopilotCoE.ps1", "03_Update-CoEContent.ps1", "Test-CoEInstall.ps1")) {
            (Get-Content (Join-Path $kitRoot $file) -Raw) |
                Should Match 'Get-CoELearningEnvironment -Settings \$(settings|s)'
        }
    }
    It "layers the government pack before org-specific overrides without copying notes" {
        $source = Get-Content (Join-Path $kitRoot "Internal\Complete-CopilotCoE.ps1") -Raw
        $source | Should Match 'if \(\$learningEnvironment -eq "Government"\)'
        $source | Should Match 'ContentPacks\\Government-StateLocal\\Content'
        $source.IndexOf('Copy-CoEContentOverlay $governmentContent') |
            Should BeLessThan $source.IndexOf('Copy-CoEContentOverlay $contentRoot')
        $temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
        try {
            $stage = Join-Path $temp "stage"
            $seed = Join-Path $temp "kit"
            $government = Join-Path $temp "government"
            $org = Join-Path $temp "org"
            foreach ($dir in @("$stage\SeedContent\Guides", "$seed\Guides", "$government\Guides", "$org\Guides")) {
                $null = New-Item -ItemType Directory -Path $dir -Force
            }
            Set-Content "$seed\Guides\Guide.md" "higher ed"
            Set-Content "$government\Guides\Guide.md" "government"
            Set-Content "$government\Guides\Another.md" "government only"
            Set-Content "$government\README.txt" "notes are not deployed"
            Set-Content "$org\Guides\Guide.md" "agency"
            $null = @(Copy-CoEContentOverlay $government $stage $seed)
            $overrides = @(Copy-CoEContentOverlay $org $stage $seed)
            (Get-Content "$stage\SeedContent\Guides\Guide.md" -Raw).Trim() | Should Be "agency"
            (Get-Content "$stage\SeedContent\Guides\Another.md" -Raw).Trim() | Should Be "government only"
            (Test-Path "$stage\SeedContent\README.txt") | Should Be $false
            $overrides | Should Be "Guides\Guide.md"
        } finally {
            if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
        }
    }
    It "keeps the government pack's own data-classification scheme internally consistent" {
        # The government pack teaches Low/Moderate/High (see ContentPacks\Government-StateLocal\Content\Experience\Data-Protection.md).
        # Any government-pack content file that instead uses the default pack's Public/Internal/Confidential vocabulary
        # contradicts that page on the same deployed site. Regression guard for the 11-Champions-Toolkit.md and
        # 00b-Is-This-OK.md mismatches.
        $govContentRoot = Join-Path $kitRoot "ContentPacks\Government-StateLocal\Content"
        $offenders = @(Get-ChildItem $govContentRoot -Recurse -File -Include "*.md", "*.txt" | Where-Object {
            $text = Get-Content $_.FullName -Raw
            # "Public records" is a correct, distinct open-records-law term, not a classification tag; exclude it.
            ($text -replace 'Public records', '') -match '\bInternal OK\b|\bConfidential:|\bPublic:'
        })
        $offenders.Count | Should Be 0
    }
    It "keeps the default pack's own data-classification scheme internally consistent" {
        # The default/SeedContent pack teaches Public/Internal/Confidential (see SeedContent\Experience\Data-Protection.md).
        # A default-pack content file using the government pack's Low/Moderate/High vocabulary would be the reverse mismatch.
        $defaultRoot = Join-Path $kitRoot "SeedContent"
        $offenders = @(Get-ChildItem $defaultRoot -Recurse -File -Include "*.md", "*.txt" | Where-Object {
            $text = Get-Content $_.FullName -Raw
            $text -match '\bModerate OK\b|\bModerate \(not public\)|\bHigh \(protected|\bLow \(public\)'
        })
        $offenders.Count | Should Be 0
    }
    It "does not hard-code a stale kit version number in the government pack's own docs" {
        # Regression guard: the government pack's README and Deployment-Settings.json _instructions still said
        # "3.7" and told admins to keep their copy's "version" equal to "3.7" after the kit moved to 3.8/3.8.1 -
        # CoE-Revision-Content.json (the actual source of truth read by the installer) already said the new
        # number. A kit version bump must not require touching every content pack's prose by hand, so this
        # checks for the absence of a hard-coded prior version instead of asserting one fixed "current" string.
        $kitVersion = (Get-Content (Join-Path $kitRoot "CoE-Revision-Content.json") -Raw | ConvertFrom-Json).version
        $govRoot = Join-Path $kitRoot "ContentPacks\Government-StateLocal"
        $staleVersionPattern = '\b3\.7\b'
        foreach ($file in @(Get-ChildItem $govRoot -Recurse -File -Include "*.txt", "*.json" |
            Where-Object { $_.Name -notmatch '^CoE-Revision-Content\.json$' })) {
            $text = Get-Content $file.FullName -Raw
            if ($text -match $staleVersionPattern) {
                throw "$($file.FullName) hard-codes a stale kit version ('3.7'); current kit version is '$kitVersion'."
            }
        }
    }
}

if ($hasPackager) {
Describe "Neutral package profiles" {
    BeforeEach { $script:settings = Get-Content (Join-Path $kitRoot "Deployment-Settings.json") -Raw | ConvertFrom-Json }
    It "accepts both neutral source profiles" {
        Assert-CoENeutralSettings $script:settings "base"
        Assert-CoENeutralSettings (Get-Content (Join-Path $kitRoot "Org-Template\Deployment-Settings.json") -Raw | ConvertFrom-Json) "org"
        Assert-CoEGovernmentNeutralSettings (Get-Content (Join-Path $kitRoot "ContentPacks\Government-StateLocal\Deployment-Settings.json") -Raw | ConvertFrom-Json) "government"
    }
    It "rejects any customer tenant rather than just known lab tenants" {
        $script:settings.Tenant = "unrelated-customer.onmicrosoft.com"
        Get-CoETestExceptionMessage { Assert-CoENeutralSettings $script:settings "test" } |
            Should Match '^Non-neutral profile field Tenant'
    }
    It "rejects populated client IDs and organization-specific links" {
        $script:settings.PnPClientID = [guid]::NewGuid().ToString()
        Get-CoETestExceptionMessage { Assert-CoENeutralSettings $script:settings "test" } |
            Should Match '^Non-neutral profile field PnPClientID'
        $script:settings.PnPClientID = ""
        $script:settings.Links.ServiceDesk = "https://customer.example/help"
        Get-CoETestExceptionMessage { Assert-CoENeutralSettings $script:settings "test" } |
            Should Match '^Non-neutral organization content'
    }
    It "rejects names, support contacts, domains, members and extra profile fields" {
        foreach ($field in @("OrgName", "OrgNoun", "SupportEmail", "OrganizationEmailDomains", "GovernanceAdditionalAllowedMembers")) {
            $value = $script:settings.$field
            $script:settings.$field = "arbitrary-customer.example"
            Get-CoETestExceptionMessage { Assert-CoENeutralSettings $script:settings "test" } |
                Should Match '^(Non-neutral profile field|Non-neutral organization content|Non-neutral domain, member, or navigation defaults)'
            $script:settings.$field = $value
        }
        $script:settings | Add-Member NoteProperty CustomerProfile "private"
        Get-CoETestExceptionMessage { Assert-CoENeutralSettings $script:settings "test" } |
            Should Match '^Unrecognized profile field'
    }
    It "requires actual placeholder text rather than empty organization objects" {
        $script:settings.OrgName = @()
        Get-CoETestExceptionMessage { Assert-CoENeutralSettings $script:settings "test" } |
            Should Match '^Expected an organization placeholder'
    }
    It "accepts the optional empty incident route and optional blank grammar label" {
        $script:settings.OrgNoun | Should Be ""
        $script:settings.NavigationOrder | Should Be "TaskFirst"
        Assert-CoENeutralSettings $script:settings "defaults"
        $script:settings.Links.PSObject.Properties.Remove("DataSafetyIncident")
        Assert-CoENeutralSettings $script:settings "without incident route"
    }
    It "rejects unknown nested values and populated incident routes" {
        $script:settings.Links.DataSafetyIncident = "https://customer.example/report"
        Get-CoETestExceptionMessage { Assert-CoENeutralSettings $script:settings "test" } |
            Should Match '^Non-neutral organization content'
        $script:settings.Links.DataSafetyIncident = ""
        $script:settings.Links | Add-Member NoteProperty UnknownLink ""
        Get-CoETestExceptionMessage { Assert-CoENeutralSettings $script:settings "test" } |
            Should Match '^Unexpected or populated link field'
    }
    It "rejects LocalOutputPath without LocalOnly before building" {
        Get-CoETestExceptionMessage {
            & $packagePath -KitVersion "0.0.1-test" -LocalOutputPath (Join-Path $PSScriptRoot "should-not-exist")
        } | Should Match '^-LocalOutputPath requires -LocalOnly'
    }
}

} else {
    Describe "Neutral package profiles (authoring source only)" {
        It "requires the unshipped Package-CoE-Kit.ps1" -Skip {}
    }
}

Describe "Captured asset URLs and legacy message normalization" {
    It "restores direct asset paths without captured authentication query values" {
        $url = 'https://{fqdn}/_vti_bin/afdcache.ashx/authitem{site}/SiteAssets/image.jpg?cache=value&authkey=synthetic'
        (Convert-CoECapturedAssetUrls $url) | Should Be 'https://{fqdn}{site}/SiteAssets/image.jpg'
        (Convert-CoECapturedAssetUrls 'https://example.test/image.jpg?size=large') | Should Be 'https://example.test/image.jpg?size=large'
    }
    It "rejects an unknown authenticated cache URL without echoing its values" {
        Get-CoETestExceptionMessage {
            Convert-CoECapturedAssetUrls 'https://example.test/_vti_bin/afdcache.ashx/authitem?authkey=synthetic'
        } | Should Match '^An unrecognized captured authenticated-cache URL remains'
    }
    It "escapes only control characters inside JSON strings" {
        $json = "{`n`"body`":{`"content`":`"first`nsecond`tline`",`"contentType`":`"html`"}}"
        $normalized = Convert-CoELegacyMessageJson $json
        $normalized.Contains('\u000a') | Should Be $true
        ($normalized | ConvertFrom-Json).body.content | Should Be "first`nsecond`tline"
    }
}

Describe "Offline preparation and packaging integration" {
    # Windows PowerShell's Copy-Item cannot reliably copy this tree to a deeply nested extraction path.
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ("coe-prep-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
    try {
        $fixtureBuild = Join-Path $fixture "03_Build"
        $fixtureKit = Join-Path $fixtureBuild "CopilotCoE-Kit"
        [void][IO.Directory]::CreateDirectory($fixtureBuild)
        [void][IO.Directory]::CreateDirectory($fixtureKit)
        $runtimeNames = @("RevisionAudit", "Backups", "CoE-Revision-Report.json", "CoE-Removal-Manifest.json",
            "CoE-Purge-Receipt.json", "CoE-Advisory-Decisions.json", "Customer-Walkthrough-State.json")
        foreach ($entry in Get-ChildItem -LiteralPath $kitRoot -Force) {
            if ($entry.Name -notin $runtimeNames -and $entry.Name -notlike ".prepare-*") {
                Copy-Item -LiteralPath $entry.FullName -Destination $fixtureKit -Recurse -Force -ErrorAction Stop
            }
        }
        $fixtureSources = Join-Path $fixtureBuild "SourceOriginal\CopilotCoESite"
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $fixtureSources))
        Copy-Item -LiteralPath $sourceRoot -Destination $fixtureSources -Recurse -Force -ErrorAction Stop
        $fixturePrepare = Join-Path $fixtureKit "Internal\Prepare-CopilotCoE.ps1"
        $fixturePackage = Join-Path $fixtureBuild "Package-CoE-Kit.ps1"
        if ($hasPackager) {
            $packageCode = (Get-Content $packagePath -Raw).Replace(
                '$masterRoot   = Split-Path -Parent $PSScriptRoot', ('$masterRoot   = "' + $fixture + '"'))
            Set-Content -LiteralPath $fixturePackage -Value $packageCode -Encoding UTF8
            Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $packagePath) "ApprovedQuickstartImages.json") `
                -Destination (Join-Path $fixtureBuild "ApprovedQuickstartImages.json") -Force -ErrorAction Stop
        }
        $delivery = Join-Path $fixture "Delivery"

        It "stages source assets without deployment audit or identity records" {
            foreach ($name in $runtimeNames) {
                Test-Path -LiteralPath (Join-Path $fixtureKit $name) | Should Be $false
            }
        }

        It "generates schema-valid templates and valid message JSON for XML/JSON/HTML metacharacters" {
            $command = "& '$($fixturePrepare.Replace("'", "''"))' -ShortName 'R&D `"CoE`" ]]>' -DisplayName 'Research & Development `"CoE`" ]]>' -OrgName 'Research & Development' -OrgNoun 'R&D' -SampleNotice 'Review `"quotes`", < & policy.'"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $output = & $pwsh -NoProfile -EncodedCommand $encoded 2>&1
            if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
            $team = [xml](Get-Content (Join-Path $fixtureKit "TeamTemplate-CoE.xml") -Raw)
            $team.DocumentElement.GetAttribute("DisplayName") | Should Be 'Research & Development "CoE" ]]>'
            $messages = @($team.SelectNodes("//*[local-name()='Message']"))
            ($messages.Count -gt 0) | Should Be $true
            foreach ($message in $messages) {
                $message.InnerText | ConvertFrom-Json | Should Not BeNullOrEmpty
                (Convert-CoELegacyMessageJson $message.InnerText) | Should Be $message.InnerText
            }
            $bodies = @($messages | ForEach-Object { ($_.InnerText | ConvertFrom-Json).body.content })
            (@($bodies | Where-Object { $_.Contains('Research &amp; Development &quot;CoE&quot; ]]&gt;') }).Count -gt 0) | Should Be $true
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $generated = [IO.Compression.ZipFile]::OpenRead((Join-Path $fixtureKit "CopilotCoESite.pnp"))
            try {
                foreach ($entry in @($generated.Entries | Where-Object FullName -like "Files/*.xml")) {
                    $reader = [IO.StreamReader]::new($entry.Open())
                    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    if ($text -notmatch '<pnp:SiteCollection\b') { continue }
                    $document = [xml]$text
                    foreach ($attribute in $document.SelectNodes("//@JsonControlData")) {
                        $attribute.Value | ConvertFrom-Json | Should Not BeNullOrEmpty
                    }
                    ($text -match '(?i)afdcache\.ashx/authitem') | Should Be $false
                }
            } finally { $generated.Dispose() }
            @(Get-ChildItem $fixtureKit -Directory -Filter ".prepare-*").Count | Should Be 0
        }
        It "applies fresh-template corrections for two independent organizations without leaking prior names" {
                $sourceHash = (Get-FileHash (Join-Path $sourceRoot "CopilotCoESite.pnp")).Hash
                foreach ($org in @("Alpine Research Institute", "Beacon College")) {
                    $output = & $pwsh -NoProfile -File $fixturePrepare -OrgName $org -EnvironmentLabel "Test" 2>&1
                    if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
                    $document = Read-TestPnPDocument (Join-Path $fixtureKit "CopilotCoESite.pnp")
                    $ns = [Xml.XmlNamespaceManager]::new($document.NameTable)
                    $ns.AddNamespace("pnp", $document.DocumentElement.NamespaceURI)
                    $document.DocumentElement.GetAttribute("DisplayName") | Should Be "$org Copilot CoE"
                    $otherOrg = if ($org -eq "Beacon College") { "Alpine Research Institute" } else { "Beacon College" }
                    $document.OuterXml.Contains($otherOrg) | Should Be $false
                    $document.OuterXml.Contains('Research &amp; Development') | Should Be $false
                    $document.OuterXml.Contains('{{OrgName}}') | Should Be $false
                    $document.OuterXml.Contains('{{OrgNoun}}') | Should Be $false
                    $homePage = $document.SelectSingleNode('//pnp:ClientSidePage[@PageName="TrainingHome.aspx"]', $ns)
                    $championText = @($homePage.SelectNodes('.//pnp:CanvasControlProperty[@Key="Text"]', $ns) | Where-Object { $_.Value -match "Find your department champion" })
                    $championText.Count | Should Be 1
                    $championText[0].Value.Contains('href="https://{fqdn}{site}/SitePages/Meet-your-Champions.aspx"') | Should Be $true
                    $hero = $homePage.SelectSingleNode('.//pnp:CanvasControl[@WebPartType="Hero"]', $ns).JsonControlData | ConvertFrom-Json
                    $expected = @(
                        @("Start in 10 minutes", "Guide-Start-in-10-Minutes.aspx"),
                        @("Which Copilot should I use?", "Which-Copilot-Should-I-Use.aspx"),
                        @("Guided learning", "Guided-Learning.aspx"),
                        @("Agent Showcase", "CoE-Agent-Showcase.aspx"),
                        @("Get help", "CoE-Service-Catalog-and-Support.aspx")
                    )
                    for ($i = 0; $i -lt 5; $i++) {
                        $hero.serverProcessedContent.searchablePlainTexts.("content[$i].title") | Should Be $expected[$i][0]
                        $hero.serverProcessedContent.links.("content[$i].link") | Should Be ("{site}/SitePages/" + $expected[$i][1])
                        $hero.properties.content[$i].openLinkInPlace | Should Be $true
                    }
                    ($hero.properties.content[1].image.imageUrl -match "HeroBanner_Prompt") | Should Be $false
                    $document.SelectNodes('//pnp:ClientSidePage[@PageName="News-and-Updates.aspx"]', $ns).Count | Should Be 0
                    $document.SelectSingleNode('//pnp:ClientSidePage[@PageName="Adoption-Best-Practices.aspx"]', $ns).Title | Should Be "Copilot CoE Adoption Guide"
                    foreach ($header in $document.SelectNodes('//pnp:ClientSidePage/pnp:Header[@Type="Custom"]', $ns)) {
                        $header.ServerRelativeImageUrl | Should Be "https://{fqdn}{site}/SiteAssets/copilot/May2023/4772M365Copilot_Abstract_Light_3840x2160.jpg"
                    }
                    ($document.OuterXml -match '(?i)guidFile=00000000|visualtemplatetitleimage|preview\.ashx') | Should Be $false
                    $mechanics = $document.SelectSingleNode('//pnp:ClientSidePage[@PageName="Copilot-on-Microsoft-Mechanics.aspx"]', $ns)
                    $mechanics.SelectNodes('.//pnp:CanvasControl', $ns).Count | Should Be 1
                    $mechanics.OuterXml.Contains("https://www.microsoft.com/mechanics") | Should Be $true
                    $mechanics.OuterXml.Contains("https://techcommunity.microsoft.com/category/microsoftmechanics") | Should Be $true
                    ($mechanics.OuterXml -match "embedCode|iframe") | Should Be $false
                }
                (Get-FileHash (Join-Path $sourceRoot "CopilotCoESite.pnp")).Hash | Should Be $sourceHash
            }
            It "retains all five configured HomeTiles and the none notice choice" {
                $tiles = @(1..5 | ForEach-Object { @{ title = "Custom tile $_"; page = "Custom-Page-$_.aspx" } }) | ConvertTo-Json -Compress
                $command = "& '$($fixturePrepare.Replace("'", "''"))' -OrgName 'Beacon College' -SampleNotice 'none' -HomeTilesJson '$($tiles.Replace("'", "''"))'"
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
                $output = & $pwsh -NoProfile -EncodedCommand $encoded 2>&1
                if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
                $document = Read-TestPnPDocument (Join-Path $fixtureKit "CopilotCoESite.pnp")
                $ns = [Xml.XmlNamespaceManager]::new($document.NameTable)
                $ns.AddNamespace("pnp", $document.DocumentElement.NamespaceURI)
                $hero = $document.SelectSingleNode('//pnp:ClientSidePage[@PageName="TrainingHome.aspx"]//pnp:CanvasControl[@WebPartType="Hero"]', $ns).JsonControlData | ConvertFrom-Json
                for ($i = 0; $i -lt 5; $i++) {
                    $hero.serverProcessedContent.searchablePlainTexts.("content[$i].title") | Should Be "Custom tile $($i + 1)"
                }
                $document.OuterXml.Contains("Sample starter content for review by Beacon College") | Should Be $false
            }
        It "rejects unresolved naming in both entry points before any sign-in" {
            $invalidSettings = Join-Path $fixture "invalid-profile.json"
            @{ OrgName = "{{OrgName}}"; DisplayName = "Configured hub"; LearningEnvironment = "HigherEducation" } |
                ConvertTo-Json | Set-Content -LiteralPath $invalidSettings -Encoding UTF8
            foreach ($script in @("02_Install-CopilotCoE.ps1", "03_Update-CoEContent.ps1")) {
                $output = & $pwsh -NoProfile -File (Join-Path $fixtureKit $script) -SettingsPath $invalidSettings 2>&1
                ($LASTEXITCODE -ne 0) | Should Be $true
                ($output -join "`n") | Should Match "OrgName contains a placeholder"
                (($output -join "`n") -match "Connecting to|Publishing content update") | Should Be $false
            }
        }
        It "rejects an omitted learning environment before either entry point signs in" {
            $settingsPath = Join-Path $fixture "missing-environment.json"
            @{ OrgName = "Offline test"; DisplayName = "Offline CoE" } |
                ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
            foreach ($script in @("02_Install-CopilotCoE.ps1", "03_Update-CoEContent.ps1")) {
                $output = & $pwsh -NoProfile -File (Join-Path $fixtureKit $script) -SettingsPath $settingsPath 2>&1
                ($LASTEXITCODE -ne 0) | Should Be $true
                ($output -join "`n") | Should Match "Set LearningEnvironment to Government or HigherEducation"
                ($output -join "`n") | Should Not Match "Connecting to|Publishing content update"
            }
        }
        It "requires an interactive advisory choice for missing routes before installer sign-in or resource creation" {
            $invalidSettings = Join-Path $fixture "missing-incident-route.json"
            @{
                Tenant = "offline-fixture.onmicrosoft.com"; AdminFQDN = "offline-fixture-admin.sharepoint.com"
                SiteFQDN = "offline-fixture.sharepoint.com"; PnPClientID = [guid]::NewGuid().ToString()
                SharedChannelOwnerUPN = "owner@example.test"; SupportEmail = "support@example.test"
                MailNickname = "CopilotCoE"; DisplayName = "Offline CoE"; OrgName = "Offline University"; OrgNoun = ""
                OrganizationEmailDomains = @("example.test")
                EnvironmentLabel = "Test"; LearningEnvironment = "HigherEducation"; Links = @{ DataSafetyIncident = "" }
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $invalidSettings -Encoding UTF8
            $output = & $pwsh -NoProfile -NonInteractive -File (Join-Path $fixtureKit "02_Install-CopilotCoE.ps1") `
                -SettingsPath $invalidSettings 2>&1
            ($LASTEXITCODE -ne 0) | Should Be $true
            ($output -join "`n") | Should Match 'ADVISORY \[UnconfiguredSupportRoutes\].*DataSafetyIncident'
            (($output -join "`n") -match "Connecting to|New-PnP|Apply-PnP") | Should Be $false
        }
        It "ships every script that the numbered scripts and internal helpers load" -Skip:(-not $hasPackager) {
            # A helper that is dot-sourced but not packaged fails on the customer's first run with
            # "file not found" - no offline test of the helper itself can see that.
            $packager = Get-Content -LiteralPath $packagePath -Raw
            $copyList = [regex]::Match($packager, '(?s)foreach \(\$name in @\((.*?)\)\) \{\s*Copy-Item \(Join-Path \$kitRoot \$name\)').Groups[1].Value
            $shipped = @([regex]::Matches($copyList, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value.Replace("\", "/") })
            $shipped.Count | Should BeGreaterThan 10
            $missing = @()
            foreach ($script in Get-ChildItem -LiteralPath $kitRoot -File -Filter "*.ps1" | Where-Object Name -match '^(0\d_|Test-CoE)') {
                $shipped -contains $script.Name | Should Be $true
            }
            $sources = @(Get-ChildItem -LiteralPath $kitRoot -File -Filter "*.ps1" | Where-Object Name -match '^0\d_') +
                @(Get-ChildItem -LiteralPath (Join-Path $kitRoot "Internal") -File -Filter "*.ps1")
            foreach ($source in $sources) {
                foreach ($m in [regex]::Matches((Get-Content -LiteralPath $source.FullName -Raw),
                    '\.\s+\(Join-Path \$PSScriptRoot "((?:Internal\\)?[A-Za-z0-9\-]+\.ps1)"\)')) {
                    $dep = $m.Groups[1].Value.Replace("\", "/")
                    $relative = if ($dep -like "Internal/*") { $dep } elseif ($source.DirectoryName -like "*Internal") { "Internal/$dep" } else { $dep }
                    if ($shipped -notcontains $relative) { $missing += "$($source.Name) loads $relative" }
                }
            }
            ($missing -join "; ") | Should BeNullOrEmpty
        }
        It "keeps resume required pages aligned to the packaged site template" {
            $installSource = Get-Content -LiteralPath (Join-Path $fixtureKit "02_Install-CopilotCoE.ps1") -Raw
            $installSource | Should Not Match '"News-and-Updates\.aspx"'
            $document = Read-TestPnPDocument (Join-Path $fixtureKit "CopilotCoESite.pnp")
            $ns = [Xml.XmlNamespaceManager]::new($document.NameTable)
            $ns.AddNamespace("pnp", $document.DocumentElement.NamespaceURI)
            $pageNames = @($document.SelectNodes('//pnp:ClientSidePage', $ns) | ForEach-Object { $_.PageName })
            foreach ($requiredPage in @(
                "Adoption-Best-Practices.aspx",
                "Copilot-on-Microsoft-Mechanics.aspx",
                "Meet-your-Champions.aspx",
                "Technical Readiness.aspx",
                "TrainingHome.aspx"
            )) {
                ($pageNames -contains $requiredPage) | Should Be $true
            }
            ($pageNames -contains "News-and-Updates.aspx") | Should Be $false
        }
        It "retargets the vendor template's own deployoffice privacy link to the kit's final URL" {
            # Regression guard: an earlier link sweep searched only kit source text (SeedContent, ContentPacks)
            # and concluded this URL "could not be found anywhere", when it actually lives inside the vendor
            # .pnp template itself (03_Build\SourceOriginal\CopilotCoESite\CopilotCoESite.pnp), live on
            # Technical Readiness.aspx. Confirms the old URL is really in the vendor template (so this guard
            # stays meaningful if the vendor ever changes it) and that Prepare-CopilotCoE.ps1's own
            # $wordingFixes sweep retargets it to the same final URL the kit's own guides already use.
            $vendorDocument = Read-TestPnPDocument (Join-Path $sourceRoot "CopilotCoESite.pnp")
            $vendorDocument.OuterXml | Should Match ([regex]::Escape("https://learn.microsoft.com/en-us/deployoffice/privacy/microsoft-365-copilot"))
            $prepareSource = Get-Content -LiteralPath $preparePath -Raw
            $prepareSource | Should Match ([regex]::Escape('"https://learn.microsoft.com/en-us/deployoffice/privacy/microsoft-365-copilot" = "https://learn.microsoft.com/en-us/microsoft-365/copilot/microsoft-365-copilot-privacy"'))
        }
        It "forwards consistent update profiles through an offline completion stub without editing settings" {
            $completion = Join-Path $fixtureKit "Internal\Complete-CopilotCoE.ps1"
            $original = [IO.File]::ReadAllBytes($completion)
            $stub = @'
[CmdletBinding()]
param(
    [string]$AdminUrl, [string]$SiteUrl, [string]$ClientId, [string]$Tenant, [string]$TeamAlias,
    [switch]$ReplaceManagedPages, [switch]$ReplaceManagedFiles, [switch]$ReplaceOrgAssets,
    [string]$OrgName, [string]$OrgNoun, [string]$ShortName, [string]$DisplayName, [string]$SampleNotice,
    [string]$SupportEmail, [string]$SettingsPath, [string]$OrgPath, [switch]$AcceptOrgAssets,
    [switch]$EnsureResourceTabs, [switch]$GuidesOnly, [switch]$GovernanceOnly, [switch]$RepairCapturedPages,
    [switch]$AllowMissingDataSafetyIncidentRoute, [string]$ContentMode
)
. (Join-Path $PSScriptRoot "OrganizationProfile.ps1")
$settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
$profile = Get-CoEOrganizationProfile -Settings $settings -Overrides $PSBoundParameters
$profile | Add-Member NoteProperty RepairCapturedPages ([bool]$RepairCapturedPages)
$profile | Add-Member NoteProperty SiteUrl $SiteUrl
$profile | Add-Member NoteProperty TeamAlias $TeamAlias
$profile | ConvertTo-Json -Compress
'@
            try {
                [IO.File]::WriteAllText($completion, $stub)
                $settingsPath = Join-Path $fixture "update-profile.json"
                $settings = @{
                    Tenant = "offline-fixture.onmicrosoft.com"; AdminFQDN = "offline-fixture-admin.sharepoint.com"
                    SiteFQDN = "offline-fixture.sharepoint.com"; PnPClientID = [guid]::NewGuid().ToString()
                    MailNickname = "CopilotCoE"; SupportEmail = "support@example.test"
                    OrgName = ""; DisplayName = "Alpine Research Institute"; OrgNoun = ""; ShortName = ""; SampleNotice = ""
                    LearningEnvironment = "HigherEducation"
                }
                $settings | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
                $hash = (Get-FileHash $settingsPath).Hash
                $update = Join-Path $fixtureKit "03_Update-CoEContent.ps1"
                $output = & $pwsh -NoProfile -File $update -SettingsPath $settingsPath 2>&1
                if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
                $profile = @($output | Where-Object { $_ -like "{*" })[0] | ConvertFrom-Json
                $profile.OrgName | Should Be "Alpine Research Institute"
                $profile.ShortName | Should Be "ARI"
                $profile.OrgNoun | Should Be "organization"
                $profile.SampleNotice | Should Match "review by Alpine Research Institute;"
                $profile.RepairCapturedPages | Should Be $false
                $profile.SiteUrl | Should Be "https://offline-fixture.sharepoint.com/sites/CopilotCoE"
                $profile.TeamAlias | Should Be "CopilotCoE"
                $output = & $pwsh -NoProfile -File $update -SettingsPath $settingsPath -OrgName "Beacon College" `
                    -DisplayName "University Copilot CoE" -OrgNoun "university" -SampleNotice "none" -RepairCapturedPages 2>&1
                if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
                $profile = @($output | Where-Object { $_ -like "{*" })[0] | ConvertFrom-Json
                $profile.OrgName | Should Be "Beacon College"
                $profile.DisplayName | Should Be "University Copilot CoE"
                $profile.ShortName | Should Be "BC"
                $profile.OrgNoun | Should Be "university"
                $profile.SampleNotice | Should Be ""
                $profile.RepairCapturedPages | Should Be $true
                (Get-FileHash $settingsPath).Hash | Should Be $hash
                # Regression test for a live failure: an organization folder reused across several installs
                # under different aliases (02_Install-CopilotCoE.ps1 -MailNickname <newAlias> each time, which
                # never writes that value back into Deployment-Settings.json) left this script computing
                # SiteUrl from the FIRST alias ever used - a retired site, producing a generic SharePoint 404
                # deep inside catalog preflight instead of a clear "wrong site" error. -MailNickname must
                # override the settings file's value, the same precedence 02_Install-CopilotCoE.ps1 already
                # has for this exact field, and must never be written back to the settings file on disk.
                $output = & $pwsh -NoProfile -File $update -SettingsPath $settingsPath -MailNickname "ContosoCoEContentDemo" 2>&1
                if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
                $profile = @($output | Where-Object { $_ -like "{*" })[0] | ConvertFrom-Json
                $profile.SiteUrl | Should Be "https://offline-fixture.sharepoint.com/sites/ContosoCoEContentDemo"
                $profile.TeamAlias | Should Be "ContosoCoEContentDemo"
                (Get-FileHash $settingsPath).Hash | Should Be $hash
                $output = & $pwsh -NoProfile -File $update -SettingsPath $settingsPath -OrgNoun "Test tenant" 2>&1
                ($LASTEXITCODE -ne 0) | Should Be $true
                ($output -join "`n") | Should Match "OrgNoun must describe the organization"
                $output = & $pwsh -NoProfile -File $update -SettingsPath $settingsPath -RepairCapturedPages -Scope Governance 2>&1
                ($LASTEXITCODE -ne 0) | Should Be $true
                ($output -join "`n") | Should Match "RepairCapturedPages requires"
            } finally { [IO.File]::WriteAllBytes($completion, $original) }
        }
        It "leaves previous generated artifacts unchanged and cleans only its own stage on validation failure" {
            $prior = [IO.File]::ReadAllBytes((Join-Path $fixtureKit "CopilotCoESite.pnp"))
            $otherStage = Join-Path $fixtureKit ".prepare-other"
            [void][IO.Directory]::CreateDirectory($otherStage)
            $output = & $pwsh -NoProfile -File $fixturePrepare -OrgName "Beacon College" -HomeTilesJson '[]' 2>&1
            ($LASTEXITCODE -ne 0) | Should Be $true
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fixtureKit "CopilotCoESite.pnp"))) | Should Be ([Convert]::ToBase64String($prior))
            (Test-Path $otherStage) | Should Be $true
            @(Get-ChildItem $fixtureKit -Directory -Filter ".prepare-*" | Where-Object Name -ne ".prepare-other").Count | Should Be 0
        }
        It "packages only neutral profiles and removes captured URLs from the nested PnP template" -Skip:(-not $hasPackager) {
            $runtimeAudit = Join-Path $fixtureKit "RevisionAudit"
            [void][IO.Directory]::CreateDirectory($runtimeAudit)
            $auditCanary = Join-Path $runtimeAudit "synthetic-before-copy.json"
            [IO.File]::WriteAllText($auditCanary, '{"SyntheticAuditMarker":"PRIVATE-TEST-ONLY"}')
            $output = & $pwsh -NoProfile -File $fixturePackage -KitVersion "0.0.1-test" -LocalOnly -LocalOutputPath $delivery 2>&1
            if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $delivery "Copilot-CoE-Implementation-Kit.zip"))
            try {
                @($zip.Entries | Where-Object { $_.FullName -match '(^|[\\/])RevisionAudit([\\/]|$)|CoE-Revision-Report' }).Count |
                    Should Be 0
                (Test-Path -LiteralPath $auditCanary) | Should Be $true
                foreach ($path in @("03_Build/CopilotCoE-Kit/Deployment-Settings.json", "03_Build/CopilotCoE-Kit/Org-Template/Deployment-Settings.json")) {
                    $reader = [IO.StreamReader]::new($zip.GetEntry($path).Open())
                    try { Assert-CoENeutralSettings ($reader.ReadToEnd() | ConvertFrom-Json) $path } finally { $reader.Dispose() }
                }
                $govPath = "03_Build/CopilotCoE-Kit/ContentPacks/Government-StateLocal/Deployment-Settings.json"
                $govReader = [IO.StreamReader]::new($zip.GetEntry($govPath).Open())
                try { Assert-CoEGovernmentNeutralSettings ($govReader.ReadToEnd() | ConvertFrom-Json) $govPath } finally { $govReader.Dispose() }
                ($null -ne $zip.GetEntry("03_Build/CopilotCoE-Kit/SeedContent/Experience/Guided-Learning.json")) | Should Be $true
                ($null -ne $zip.GetEntry("03_Build/CopilotCoE-Kit/SeedContent/Experience/Tools.json")) | Should Be $true
                ($null -ne $zip.GetEntry("03_Build/CopilotCoE-Kit/Internal/OrganizationProfile.ps1")) | Should Be $true
                # Regression guard: the 3.8 ZIP shipped zero *.Tests.ps1 files, so "442 of 443 offline Pester
                # tests pass" in a change list could not be independently checked by anyone else. Every
                # offline test file present in the source kit must land in the package too.
                foreach ($testFile in Get-ChildItem -LiteralPath (Join-Path $kitRoot "Tests") -File -Filter "*.Tests.ps1") {
                    ($null -ne $zip.GetEntry("03_Build/CopilotCoE-Kit/Tests/$($testFile.Name)")) | Should Be $true
                }
                # Built from concatenated fragments, not literal constants: Tests\ now ships inside the
                # customer ZIP (see the shipped-test-file guard above), and a literal real lab-tenant
                # identifier sitting in this file's own source text would itself be a leak the moment this
                # file is packaged, even though it's only ever used defensively, to scan OTHER files for it.
                $labTenantM365 = "m365cpi781" + "16917"
                $labTenantDiax = "diax3823" + "2937"
                # The lab-tenant-ID scan covers EVERY text-like entry, including Tests\ and .html - a real
                # secret leak is a leak regardless of folder or extension. Confirmed live: 3.8.6 shipped the
                # lab tenant's hostname 13 times in 01_Admin-Quickstart.html (an extension this scan never
                # checked) and 8 more times in Tests\Completion.Tests.ps1 (a folder this scan always excluded).
                foreach ($entry in @($zip.Entries | Where-Object { $_.FullName -match '\.(json|txt|ps1|xml|md|csv|html)$' })) {
                    $reader = [IO.StreamReader]::new($entry.Open())
                    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    ($text -match "$labTenantDiax|$labTenantM365") | Should Be $false
                }
                # The fictional-org-name scan stays narrower and excludes Tests\: those files legitimately use
                # "Beacon College" and similar fixture org names to exercise the neutral-profile validators
                # themselves, same as this very file does - that is not leaked customer data, unlike the same
                # string appearing in shipped kit content or configuration.
                foreach ($entry in @($zip.Entries | Where-Object { $_.FullName -match '\.(json|txt|ps1|xml|md|csv)$' -and $_.FullName -notmatch '/Tests/' })) {
                    $reader = [IO.StreamReader]::new($entry.Open())
                    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    ($text -match "Alpine Research Institute|Beacon College|Research &amp; Development") | Should Be $false
                }
                ($null -ne $zip.GetEntry("VERSION.txt")) | Should Be $true
                $versionReader = [IO.StreamReader]::new($zip.GetEntry("VERSION.txt").Open())
                try { $versionText = $versionReader.ReadToEnd() } finally { $versionReader.Dispose() }
                $versionText | Should Match "0\.0\.1-test"
                $nestedPath = Join-Path $fixture "packaged.pnp"
                [IO.Compression.ZipFileExtensions]::ExtractToFile($zip.GetEntry("03_Build/SourceOriginal/CopilotCoESite/CopilotCoESite.pnp"), $nestedPath, $true)
                $nested = [IO.Compression.ZipFile]::OpenRead($nestedPath)
                try {
                    foreach ($entry in @($nested.Entries | Where-Object FullName -like "Files/*.xml")) {
                        $reader = [IO.StreamReader]::new($entry.Open())
                        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                        ($text -match '(?i)afdcache\.ashx/authitem') | Should Be $false
                    }
                } finally { $nested.Dispose() }
            } finally { $zip.Dispose() }
        }
        It "rejects a customer-branded screenshot that is not in the approved-image manifest" -Skip:(-not $hasPackager) {
            # A screenshot's customer branding lives in its rendered pixels, not in any text pattern the other
            # packaging scans search, so this is the one guard that must be exercised directly: inject a
            # synthetic, unapproved embedded image into a private copy of the real guide and confirm packaging
            # refuses it. The real kitRoot/01_Admin-Quickstart.html itself is never modified by this test.
            $quickstartPath = Join-Path $fixtureKit "01_Admin-Quickstart.html"
            $original = Get-Content -LiteralPath $quickstartPath -Raw
            try {
                # A minimal valid 1x1 PNG, guaranteed not to be in ApprovedQuickstartImages.json.
                $syntheticPng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
                $imagePattern = [regex]'(<img\b[^>]*\bsrc="data:image/png;base64,)[^"]+(")'
                $injected = $imagePattern.Replace($original, ('${1}' + $syntheticPng + '$2'), 1)
                ($injected -ne $original) | Should Be $true
                Set-Content -LiteralPath $quickstartPath -Value $injected -Encoding utf8 -NoNewline
                $output = & $pwsh -NoProfile -File $fixturePackage -KitVersion "0.0.1-test" -LocalOnly -LocalOutputPath $delivery 2>&1
                ($LASTEXITCODE -ne 0) | Should Be $true
                ($output -join "`n") | Should Match "Unapproved embedded screenshot"
            } finally {
                Set-Content -LiteralPath $quickstartPath -Value $original -Encoding utf8 -NoNewline
            }
        }
        It "still approves an embedded screenshot that uses single-quoted attribute syntax" -Skip:(-not $hasPackager) {
            # The image gate used to only recognize <img src="data:image/..."> with double quotes specifically;
            # confirm the broadened, quote-agnostic detection still approves an already-reviewed image whose
            # container happens to use single quotes, so a future refactor cannot silently narrow this back down.
            $quickstartPath = Join-Path $fixtureKit "01_Admin-Quickstart.html"
            $original = Get-Content -LiteralPath $quickstartPath -Raw
            try {
                $pattern = [regex]'<img\b([^>]*?)\bsrc="(data:image/[a-zA-Z0-9.+-]+;base64,[^"]+)"([^>]*>)'
                $evaluator = [Text.RegularExpressions.MatchEvaluator]{ param($m) "<img$($m.Groups[1].Value)src='$($m.Groups[2].Value)'$($m.Groups[3].Value)" }
                $singleQuoted = $pattern.Replace($original, $evaluator, 1)
                ($singleQuoted -ne $original) | Should Be $true
                ($singleQuoted -match "src='data:image/") | Should Be $true
                Set-Content -LiteralPath $quickstartPath -Value $singleQuoted -Encoding utf8 -NoNewline
                $output = & $pwsh -NoProfile -File $fixturePackage -KitVersion "0.0.1-test" -LocalOnly -LocalOutputPath $delivery 2>&1
                if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
            } finally {
                Set-Content -LiteralPath $quickstartPath -Value $original -Encoding utf8 -NoNewline
            }
        }
        It "rejects an external, non-data-URI image reference embedded in the guide" -Skip:(-not $hasPackager) {
            # This guide ships as a single offline HTML file; an external http(s) image reference would both
            # break once distributed and let the recipient's browser silently call out to that host. Confirm
            # the gate rejects one even though its hash could never appear in the approved-image manifest.
            $quickstartPath = Join-Path $fixtureKit "01_Admin-Quickstart.html"
            $original = Get-Content -LiteralPath $quickstartPath -Raw
            try {
                $injected = '<img src="https://evil.example.com/track.png">' + $original
                Set-Content -LiteralPath $quickstartPath -Value $injected -Encoding utf8 -NoNewline
                $output = & $pwsh -NoProfile -File $fixturePackage -KitVersion "0.0.1-test" -LocalOnly -LocalOutputPath $delivery 2>&1
                ($LASTEXITCODE -ne 0) | Should Be $true
                ($output -join "`n") | Should Match "Non-data-URI image reference"
            } finally {
                Set-Content -LiteralPath $quickstartPath -Value $original -Encoding utf8 -NoNewline
            }
        }
        It "rejects a leak-disclosing or maintainer-only phrase shipped in the guide" -Skip:(-not $hasPackager) {
            # A prior fix replaced removed images with a maintainer note that itself disclosed another
            # customer's prior exposure ("Screenshot pending re-capture... showed one customer's organization
            # name... could not ship in a kit used by other organizations"). Confirm that specific phrasing -
            # or close variants of it - can never ship again without failing the build.
            $quickstartPath = Join-Path $fixtureKit "01_Admin-Quickstart.html"
            $original = Get-Content -LiteralPath $quickstartPath -Raw
            try {
                $injected = $original + "<!-- Screenshot pending re-capture. -->"
                Set-Content -LiteralPath $quickstartPath -Value $injected -Encoding utf8 -NoNewline
                $output = & $pwsh -NoProfile -File $fixturePackage -KitVersion "0.0.1-test" -LocalOnly -LocalOutputPath $delivery 2>&1
                ($LASTEXITCODE -ne 0) | Should Be $true
                ($output -join "`n") | Should Match "Leak-disclosing or maintainer-only phrase"
            } finally {
                Set-Content -LiteralPath $quickstartPath -Value $original -Encoding utf8 -NoNewline
            }
        }
        It "rejects the package when the root and kit-build copies of the guide diverge" -Skip:(-not $hasPackager) {
            # The ZIP ships the guide at two paths, normally produced from the same source and copied
            # sequentially (see Package-CoE-Kit.ps1), so they are identical today by construction and this
            # cannot be triggered by editing fixtureKit's guide alone. Exercise the real identity-assertion
            # logic by running a private copy of the packaging script whose root-level copy step is rewritten
            # to pull from a deliberately different (but still gate-valid) file; $fixturePackage and the real
            # kit are both left untouched.
            $divergentGuide = Join-Path $fixtureBuild "divergent-guide.html"
            $realGuideText = Get-Content -LiteralPath (Join-Path $fixtureKit "01_Admin-Quickstart.html") -Raw
            Set-Content -LiteralPath $divergentGuide -Value ($realGuideText + "<!-- divergent build -->") -Encoding utf8 -NoNewline
            $divergentPackage = Join-Path $fixtureBuild "Package-CoE-Kit-divergent.ps1"
            $searchText = 'Copy-Item (Join-Path $kitBuild "01_Admin-Quickstart.html") (Join-Path $stage "01_Admin-Quickstart.html") -Force'
            $replaceText = 'Copy-Item -LiteralPath "' + $divergentGuide.Replace("'", "''") + '" -Destination (Join-Path $stage "01_Admin-Quickstart.html") -Force'
            $fixturePackageCode = Get-Content -LiteralPath $fixturePackage -Raw
            ($fixturePackageCode -match [regex]::Escape($searchText)) | Should Be $true
            $divergentCode = $fixturePackageCode.Replace($searchText, $replaceText)
            ($divergentCode -ne $fixturePackageCode) | Should Be $true
            Set-Content -LiteralPath $divergentPackage -Value $divergentCode -Encoding UTF8
            $output = & $pwsh -NoProfile -File $divergentPackage -KitVersion "0.0.1-test" -LocalOnly -LocalOutputPath $delivery 2>&1
            ($LASTEXITCODE -ne 0) | Should Be $true
            ($output -join "`n") | Should Match "not byte-identical"
        }
        It "rejects additional customer profiles and preserves unrelated staging paths" -Skip:(-not $hasPackager) {
            $otherStage = Join-Path $fixtureBuild "DeliveryKit-other"
            [void][IO.Directory]::CreateDirectory($otherStage)
            $profile = Join-Path $fixtureKit "Org-Template\Test-Customer.json"
            Set-Content $profile '{"Tenant":"arbitrary-customer.onmicrosoft.com"}'
            $output = & $pwsh -NoProfile -File $fixturePackage -KitVersion "0.0.1-test" -LocalOnly -LocalOutputPath $delivery 2>&1
            ($LASTEXITCODE -ne 0) | Should Be $true
            (Test-Path $otherStage) | Should Be $true
            @(Get-ChildItem $fixtureBuild -Directory -Filter "DeliveryKit-*" | Where-Object Name -ne "DeliveryKit-other").Count | Should Be 0
            @(Get-ChildItem $fixtureBuild -File -Filter "*.pending").Count | Should Be 0
            Remove-Item -LiteralPath $profile
            $profile = Join-Path $fixtureKit "SeedContent\unknown-profile.json"
            Set-Content $profile '{"Tenant":"arbitrary-customer.onmicrosoft.com"}'
            $output = & $pwsh -NoProfile -File $fixturePackage -KitVersion "0.0.1-test" -LocalOnly -LocalOutputPath $delivery 2>&1
            ($LASTEXITCODE -ne 0) | Should Be $true
            @(Get-ChildItem $fixtureBuild -Directory -Filter "DeliveryKit-*" | Where-Object Name -ne "DeliveryKit-other").Count | Should Be 0
            @(Get-ChildItem $fixtureBuild -File -Filter "*.pending").Count | Should Be 0
        }
    } finally {
        if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    }
}
