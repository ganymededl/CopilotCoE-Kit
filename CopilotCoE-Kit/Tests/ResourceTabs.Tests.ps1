# Offline tests for the installed Pester 3.4 Windows PowerShell runner.
Set-StrictMode -Version Latest
$kitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $kitRoot "Internal\ResourceTabs.ps1")

if (-not ("OfflineCoEResourceTab" -as [type])) {
    Add-Type -TypeDefinition @'
public class OfflineCoETabConfiguration {
    public string EntityId { get; set; }
    public string ContentUrl { get; set; }
    public string WebsiteUrl { get; set; }
    public string RemoveUrl { get; set; }
}
public class OfflineCoETabApp {
    public string Id { get; set; }
    public string ExternalId { get; set; }
    public string DistributionMethod { get; set; }
    public string DisplayName { get; set; }
}
public class OfflineCoEResourceTab {
    public string Id { get; set; }
    public string DisplayName { get; set; }
    public string TeamsAppId { get; set; }
    public OfflineCoETabApp TeamsApp { get; set; }
    public OfflineCoETabConfiguration Configuration { get; set; }
}
public class OfflineCoEChannel {
    public string Id { get; set; }
    public string DisplayName { get; set; }
    public string MembershipType { get; set; }
    public string Description { get; set; }
}
public class OfflineCoEDriveItem {
    public string Id { get; set; }
    public string WebUrl { get; set; }
}
public class OfflineCoEFile {
    public System.Guid UniqueId { get; set; }
    public string ServerRelativeUrl { get; set; }
}
public class OfflineCoEPageText { public string Text { get; set; } }
public class OfflineCoEResourcePage {
    public string Name { get; set; }
    public string PageTitle { get; set; }
    public System.Collections.Generic.List<OfflineCoEPageText> Controls { get; set; }
}
'@
}

function Get-PnPTeamsChannel { [CmdletBinding()]param($Team, $Connection) throw "Unexpected channel read" }
function Add-PnPTeamsChannel { [CmdletBinding()]param($Team, $DisplayName, $Description, $ChannelType, $Connection) throw "Unexpected channel create" }
function Get-PnPTeamsTab { [CmdletBinding()]param($Team, $Channel, $Identity, $Connection) throw "Unexpected tab read" }
function Add-PnPTeamsTab {
    [CmdletBinding()]param($Team, $Channel, $DisplayName, $Type, $ContentUrl, $EntityId, $WebsiteUrl, $Connection)
    throw "Unexpected tab create"
}
function Remove-PnPTeamsTab { [CmdletBinding()]param($Team, $Channel, $Identity, [switch]$Force, $Connection) throw "Unexpected tab removal" }
function Get-PnPTeamsChannelFilesFolder { [CmdletBinding()]param($Team, $Channel, $Connection) throw "Unexpected folder read" }
function Get-PnPFile { [CmdletBinding()]param($Url, [switch]$AsFileObject, [switch]$AsListItem, $Connection) throw "Unexpected file read" }
function Get-PnPProperty { [CmdletBinding()]param($ClientObject, $Property, $Connection) throw "Unexpected property load" }
function Get-PnPWeb { [CmdletBinding()]param($Connection) throw "Unexpected web read" }
function Invoke-PnPGraphMethod {
    [CmdletBinding()]param($Url, $Method, $Content, $ContentType, [switch]$Raw, $Connection)
    throw "Unexpected Graph call"
}
function Get-PnPPage { [CmdletBinding()]param($Identity, $Connection) throw "Unexpected page read" }
function Add-PnPPage { [CmdletBinding()]param($Name, $Title, $LayoutType, $ContentType, $Connection) throw "Unexpected page create" }
function Add-PnPPageTextPart { [CmdletBinding()]param($Page, $Text, $Connection) throw "Unexpected page content write" }
function Set-PnPPage { [CmdletBinding()]param($Identity, $Title, [switch]$Publish, $Connection) throw "Unexpected page publish" }

function New-ResourceChannel([string]$Id, [string]$Name, [string]$Membership = "standard") {
    $channel = New-Object OfflineCoEChannel
    $channel.Id = $Id
    $channel.DisplayName = $Name
    $channel.MembershipType = $Membership
    return $channel
}

function New-ResourceTab([string]$Id, [string]$Type, [string]$Url, [string]$Entity = "", [string]$Name = "Managed") {
    $tab = New-Object OfflineCoEResourceTab
    $tab.Id = $Id
    $tab.DisplayName = $Name
    $tab.TeamsApp = New-Object OfflineCoETabApp
    $tab.TeamsApp.Id = Get-CoETabAppIdForType $Type
    $tab.Configuration = New-Object OfflineCoETabConfiguration
    $tab.Configuration.EntityId = $Entity
    $tab.Configuration.ContentUrl = $Url
    $tab.Configuration.WebsiteUrl = $Url
    if ($Type -eq "SharePointPageAndList" -and $Url) {
        $site = $Url.Substring(0, $Url.IndexOf("/SitePages/"))
        $tab.Configuration.ContentUrl = "$site/_layouts/15/teamslogon.aspx?spfx=true&dest=" + [uri]::EscapeDataString($Url)
    }
    return $tab
}

function New-ResourceSpec([string]$Type = "WebSite") {
    $url = if ($Type -eq "SharePointPageAndList") {
        "https://neutral.sharepoint.com/teams/CoE/SitePages/Meet-your-Champions.aspx"
    } elseif ($Type -eq "WebSite") {
        "https://learn.microsoft.com/en-us/microsoft-365/copilot/copilot-prompt-gallery"
    } else {
        "https://neutral.sharepoint.com/teams/CoE/Shared%20Documents/Prompt/Resource.pptx"
    }
    $probe = New-ResourceTab probe $Type $url
    return [pscustomobject]@{
        DisplayName = "Managed"; Type = $Type; TeamsAppId = Get-CoETabAppIdForType $Type
        TemplateAppId = $(if ($Type -eq "SharePointPageAndList") { "0ae35b36-0fd7-422e-805b-d53af1579093" } else { Get-CoETabAppIdForType $Type })
        ContentUrl = $probe.Configuration.ContentUrl; WebsiteUrl = $url
    }
}

function New-ModernResourceTab([string]$Url, [string]$FileId, [string]$Name = "Managed") {
    $payload = @{ fileType = "pptx"; objectUrl = [uri]::EscapeDataString([uri]::EscapeDataString($Url))
        fileId = $FileId; isPinnedTab = $true } | ConvertTo-Json -Compress
    $file = @{ type = "pptx"; objectId = $FileId; objectUrl = $Url; websiteUrl = $null
        serviceName = "teams"; providerMetadata = "" } | ConvertTo-Json -Compress
    return [pscustomobject]@{
        id = "44444444-4444-4444-4444-444444444444"; displayName = $Name
        teamsApp = [pscustomobject]@{ id = "3e0a4fec-499b-4138-8e7c-71a9d88a62ed"; externalId = $null
            displayName = "PowerPoint"; distributionMethod = "store" }
        configuration = [pscustomobject]@{
            entityId = "2"; contentUrl = "https://m365.cloud.microsoft/launch/PowerPoint/officeunihost/teams?auth=2&flight=officeunihost&subEntityId=" + [uri]::EscapeDataString($payload)
            websiteUrl = $null; objectId = $FileId; file = $file
        }
    }
}

Describe "Prepared resource specifications" {
    BeforeEach {
        $script:parameters = @{ fqdn = "neutral.sharepoint.com"; inclusionPath = "teams"; mailNickname = "CoE"
            displayName = 'Research & Development'; groupid = "11111111-1111-1111-1111-111111111111" }
        $script:templatePath = Join-Path $kitRoot "TeamTemplate-CoE.xml"
        $script:siteUrl = "https://neutral.sharepoint.com/teams/CoE"
    }
    It "derives all three channels and eight resource destinations without captured runtime IDs" {
        $specs = @(Get-CoEStandardChannelSpec -Path $templatePath -Parameters $parameters -SiteUrl $siteUrl)
        $specs.Count | Should Be 3
        @($specs | ForEach-Object { $_.Tabs }).Count | Should Be 8
        @($specs | Where-Object { $_.PSObject.Properties["Id"] }).Count | Should Be 0
        $tabs = @($specs | ForEach-Object { $_.Tabs })
        @($tabs | Where-Object { $_.ContentUrl -match '[{}]' -or $_.WebsiteUrl -match '[{}]' }).Count | Should Be 0
        ($tabs | Where-Object DisplayName -eq "Meet your Champions").TeamsAppId | Should Be "2a527703-1f6f-4559-a332-d8a7d288cd88"
        ($tabs | Where-Object DisplayName -eq "Top 10 to try").ContentUrl | Should Be "$siteUrl/Shared%20Documents/Ask%20Us%20Anything%20%F0%9F%93%A2/Microsoft365Copilot_Top10toTry_Handout.pptx"
    }
    It "expands both PnP token forms without interpreting replacement metacharacters" {
        (Expand-CoETeamTemplateValue '{parameter:displayName} {fqdn}' $parameters) | Should Be 'Research & Development neutral.sharepoint.com'
        { Expand-CoETeamTemplateValue '{parameter:unknown}' $parameters } | Should Throw
        { Expand-CoETeamTemplateValue '{fqdn}' @{} } | Should Throw
    }
    It "fails closed when the configured resource site is not the verified runtime site" {
        { Get-CoEStandardChannelSpec -Path $templatePath -Parameters $parameters -SiteUrl ($siteUrl + "-other") } | Should Throw
    }
    It "rejects canonical paths escaping the site despite a matching string prefix" {
        (Test-CoEUrlInSite "$siteUrl/../Other/file.pdf" $siteUrl) | Should Be $false
        (Test-CoEUrlInSite "$siteUrl-other/file.pdf" $siteUrl) | Should Be $false
    }
    It "rejects duplicate names, unsupported apps, wrong membership and inconsistent destinations" {
        $fixture = Join-Path $PSScriptRoot (".resource-template-" + [guid]::NewGuid().ToString("N") + ".xml")
        try {
            foreach ($change in @("duplicate", "app", "membership", "url", "wrapper", "token")) {
                $document = [xml](Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8)
                $channel = $document.SelectSingleNode("//*[local-name()='Channel']")
                $tab = $channel.SelectSingleNode(".//*[local-name()='Tab']")
                $configuration = $tab.SelectSingleNode("./*[local-name()='Configuration']")
                switch ($change) {
                    "duplicate" { [void]$channel.ParentNode.AppendChild($channel.CloneNode($true)) }
                    "app" { $tab.SetAttribute("TeamsAppId", "unrecognized-app") }
                    "membership" { $channel.SetAttribute("MembershipType", "Shared") }
                    "url" { $configuration.SetAttribute("WebsiteUrl", "https://unrelated.example/custom") }
                    "wrapper" {
                        $page = $document.SelectSingleNode("//*[local-name()='Tab'][@DisplayName='Meet your Champions']/*[local-name()='Configuration']")
                        $page.SetAttribute("ContentUrl", "https://unrelated.example/?dest=" + [uri]::EscapeDataString("$siteUrl/SitePages/Meet-your-Champions.aspx"))
                    }
                    "token" { $configuration.SetAttribute("ContentUrl", "https://{parameter:unknown}/resource") }
                }
                $document.Save($fixture)
                { Get-CoEStandardChannelSpec -Path $fixture -Parameters $parameters -SiteUrl $siteUrl } | Should Throw
            }
        } finally {
            if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Force }
        }
    }
}

Describe "Durable standard channel provisioning" {
    BeforeEach {
        $script:specs = @(Get-CoEStandardChannelSpec -Path (Join-Path $kitRoot "TeamTemplate-CoE.xml") `
            -Parameters @{ fqdn = "neutral.sharepoint.com"; inclusionPath = "teams"; mailNickname = "CoE" } `
            -SiteUrl "https://neutral.sharepoint.com/teams/CoE")
        $script:channelState = @(New-ResourceChannel general "General")
        $script:channelCreates = 0
        Mock Write-Host {}
        Mock Start-Sleep {}
        Mock Get-PnPTeamsChannel {
            if ($Team -ne "runtime-team" -or $Connection -ne "offline") { throw "Wrong read identity" }
            $script:channelState
        }
        Mock Add-PnPTeamsChannel { throw "Unexpected create" }
    }
    It "creates missing standard channels using runtime IDs and accepts void writes idempotently" {
        Mock Add-PnPTeamsChannel {
            if ($Team -ne "runtime-team" -or $ChannelType -ne "Standard" -or $Connection -ne "offline") { throw "Wrong channel create identity/type" }
            $script:channelCreates++
            $script:channelState += @(New-ResourceChannel ("runtime-" + $script:channelCreates) $DisplayName)
        }
        $result = @(Ensure-CoEStandardChannels -Team runtime-team -Specifications $specs -Connection offline)
        $result.Count | Should Be 3
        $result[0].Id | Should Be "runtime-1"
        $result[1].Id | Should Be "runtime-2"
        @(Ensure-CoEStandardChannels -Team runtime-team -Specifications $specs -Connection offline).Count | Should Be 3
        Assert-MockCalled Add-PnPTeamsChannel -Times 2 -Exactly -Scope It
    }
    It "repairs the silently omitted Ask channel without re-applying messages or inviting members" {
        $script:channelState += @(New-ResourceChannel prompt "Share Your Prompt")
        Mock Add-PnPTeamsChannel { $script:channelState += @(New-ResourceChannel ask $DisplayName) }
        $result = @(Ensure-CoEStandardChannels -Team runtime-team -Specifications $specs -Connection offline)
        ($result | Where-Object Id -eq ask).DisplayName | Should Be $specs[1].DisplayName
        Assert-MockCalled Add-PnPTeamsChannel -Times 1 -Exactly -Scope It -ParameterFilter { $ChannelType -eq "Standard" }
    }
    It "rejects wrong types, duplicate names, missing IDs, reused IDs and near-name matches before any write" {
        foreach ($problem in @("private", "duplicate", "empty", "reused", "case")) {
            $script:channelState = @(New-ResourceChannel general "General")
            switch ($problem) {
                "private" { $script:channelState += @(New-ResourceChannel prompt "Share Your Prompt" private) }
                "duplicate" { $script:channelState += @(New-ResourceChannel g2 "General") }
                "empty" { $script:channelState = @(New-ResourceChannel "" "General") }
                "reused" { $script:channelState += @(New-ResourceChannel general "Share Your Prompt") }
                "case" { $script:channelState = @(New-ResourceChannel general "general") }
            }
            { Ensure-CoEStandardChannels -Team runtime-team -Specifications $specs -Connection offline } | Should Throw
        }
        Assert-MockCalled Add-PnPTeamsChannel -Times 0 -Exactly -Scope It
    }
    It "re-reads an ambiguous successful create rather than duplicating it" {
        Mock Add-PnPTeamsChannel {
            $script:channelCreates++
            $script:channelState += @(New-ResourceChannel ("runtime-" + $script:channelCreates) $DisplayName)
            throw "Timeout after server accepted create"
        }
        @(Ensure-CoEStandardChannels -Team runtime-team -Specifications $specs -Connection offline).Count | Should Be 3
        Assert-MockCalled Add-PnPTeamsChannel -Times 2 -Exactly -Scope It
    }
    It "rejects a conflicting nonstandard channel rather than treating name equality as success" {
        Mock Add-PnPTeamsChannel {
            $script:channelState += @(New-ResourceChannel conflicting $DisplayName shared)
            throw "409 Conflict"
        }
        { Ensure-CoEStandardChannels -Team runtime-team -Specifications $specs -Connection offline } | Should Throw
        Assert-MockCalled Add-PnPTeamsChannel -Times 1 -Exactly -Scope It
    }
    It "bounds retries when ambiguous requests never produce a channel" {
        Mock Add-PnPTeamsChannel { throw "503 ServiceUnavailable" }
        { Ensure-CoEStandardChannels -Team runtime-team -Specifications $specs -Connection offline } | Should Throw
        Assert-MockCalled Add-PnPTeamsChannel -Times 4 -Exactly -Scope It
    }
    It "does not trust a returned channel that was not persisted" {
        Mock Add-PnPTeamsChannel { New-ResourceChannel unsaved $DisplayName }
        { Ensure-CoEStandardChannels -Team runtime-team -Specifications $specs -Connection offline } | Should Throw
        Assert-MockCalled Add-PnPTeamsChannel -Times 1 -Exactly -Scope It
    }
    It "denies failed writes and read failures without retrying permission failures" {
        Mock Add-PnPTeamsChannel { throw "403 Forbidden after Timeout" }
        { Ensure-CoEStandardChannels -Team runtime-team -Specifications $specs -Connection offline } | Should Throw
        Assert-MockCalled Add-PnPTeamsChannel -Times 1 -Exactly -Scope It
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
    }
    It "propagates a denied reconciliation read following an ambiguous create" {
        $script:reads = 0
        Mock Get-PnPTeamsChannel {
            $script:reads++
            if ($script:reads -gt 1) { throw "401 Unauthorized" }
            $script:channelState
        }
        Mock Add-PnPTeamsChannel { throw "Timeout" }
        { Ensure-CoEStandardChannels -Team runtime-team -Specifications $specs -Connection offline } | Should Throw
        Assert-MockCalled Add-PnPTeamsChannel -Times 1 -Exactly -Scope It
    }
    It "verifies eventual visibility and detects an ID changed during final verification" {
        $script:channelState = @($specs | ForEach-Object { New-ResourceChannel $_.DisplayName $_.DisplayName })
        $script:reads = 0
        Mock Get-PnPTeamsChannel {
            $script:reads++
            if ($script:reads -gt 1) { $script:channelState[0].Id = "changed-id" }
            @($script:channelState | ForEach-Object { New-ResourceChannel $_.Id $_.DisplayName })
        }
        { Ensure-CoEStandardChannels -Team runtime-team -Specifications $specs -Connection offline } | Should Throw
        Assert-MockCalled Add-PnPTeamsChannel -Times 0 -Exactly -Scope It
    }
    It "waits for a successful void create to become visible without another write" {
        $script:channelState = @()
        $script:reads = 0
        $script:pendingChannel = $null
        Mock Get-PnPTeamsChannel {
            $script:reads++
            if ($script:pendingChannel -and $script:reads -ge 3) {
                $script:channelState = @($script:pendingChannel)
                $script:pendingChannel = $null
            }
            $script:channelState
        }
        Mock Add-PnPTeamsChannel { $script:pendingChannel = New-ResourceChannel runtime $DisplayName }
        @(Ensure-CoEStandardChannels -Team runtime-team -Specifications @($specs[0]) -Connection offline).Count | Should Be 1
        Assert-MockCalled Add-PnPTeamsChannel -Times 1 -Exactly -Scope It
        Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It
    }
}

Describe "Waiting for a freshly created standard channel to appear" {
    BeforeEach {
        $script:reads = 0
        $script:visibleAfter = 1
        $script:listed = @()
        Mock Write-Host {}
        Mock Start-Sleep {}
        Mock Get-PnPTeamsChannel {
            $script:reads++
            if ($script:reads -ge $script:visibleAfter) { return @($script:listed) }
            return @(New-ResourceChannel general "General")
        }
    }
    It "returns at once when the channel is already listed" {
        $script:listed = @(New-ResourceChannel c1 "Service Catalog and Support")
        $result = Wait-CoEStandardChannel -Team t -DisplayName "Service Catalog and Support" -Connection offline
        $result.Channel.Id | Should Be "c1"
        $reads | Should Be 1
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
    }
    It "waits through Teams' listing delay instead of failing on the first read" {
        # The failure seen on a clean install: the channel was created but missing from the next listing.
        $script:listed = @(New-ResourceChannel c1 "Service Catalog and Support")
        $script:visibleAfter = 5
        $result = Wait-CoEStandardChannel -Team t -DisplayName "Service Catalog and Support" -Connection offline
        $result.Channel.Id | Should Be "c1"
        $reads | Should Be 5
        Assert-MockCalled Start-Sleep -Times 4 -Exactly -Scope It
    }
    It "gives up with a message that says the channel never appeared, not a vague expectation" {
        $script:visibleAfter = 999
        { Wait-CoEStandardChannel -Team t -DisplayName "Agent Showcase" -Connection offline -Checks 3 } |
            Should Throw "did not appear in Teams"
        $reads | Should Be 3
    }
    It "rejects duplicates and a channel of the wrong type with a specific reason" {
        $script:listed = @((New-ResourceChannel c1 "Agent Showcase"), (New-ResourceChannel c2 "Agent Showcase"))
        { Wait-CoEStandardChannel -Team t -DisplayName "Agent Showcase" -Connection offline } | Should Throw "Ambiguous channel"
        $script:listed = @(New-ResourceChannel c3 "Agent Showcase" "shared")
        { Wait-CoEStandardChannel -Team t -DisplayName "Agent Showcase" -Connection offline -Checks 2 } | Should Throw "not a standard channel"
    }
    It "is used by the section loop instead of a single immediate re-read" {
        $source = Get-Content -LiteralPath (Join-Path $kitRoot "Internal\Complete-CopilotCoE.ps1") -Raw
        $source | Should Match 'Wait-CoEStandardChannel -Team \$group\.GroupId -DisplayName \$section\.channel'
    }
}

Describe "Verified managed resource tabs" {
    BeforeEach {
        $script:spec = New-ResourceSpec
        $script:tabState = @()
        $script:tabCreates = 0
        $script:sync = @{ Team = "runtime-team"; Channel = "runtime-channel"; Specification = $spec
            EntityId = "22222222-2222-2222-2222-222222222222"; Connection = "offline" }
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Start-Sleep {}
        Mock Get-PnPTeamsTab {
            if ($Team -ne "runtime-team" -or $Channel -ne "runtime-channel" -or $Connection -ne "offline") { throw "Wrong tab read identity" }
            $script:tabState
        }
        Mock Add-PnPTeamsTab {
            if ($Team -ne "runtime-team" -or $Channel -ne "runtime-channel" -or $Connection -ne "offline") { throw "Wrong tab create identity" }
            $script:tabCreates++
            $url = if ($Type -eq "SharePointPageAndList") {
                if ($ContentUrl -or -not $WebsiteUrl) { throw "Wrong page dynamic parameters" }
                $WebsiteUrl
            } else {
                if (-not $ContentUrl -or $WebsiteUrl) { throw "Wrong web/file dynamic parameters" }
                if ($Type -in @("PDF", "PowerPoint") -and -not $EntityId) { throw "Missing file dynamic identity" }
                $ContentUrl
            }
            $script:tabState += @(New-ResourceTab ("created-" + $script:tabCreates) $Type $url $EntityId $DisplayName)
        }
        Mock Remove-PnPTeamsTab {
            if ($Team -ne "runtime-team" -or $Channel -ne "runtime-channel" -or $Connection -ne "offline" -or -not $Force -or -not $Identity) { throw "Wrong tab remove identity" }
            $script:tabState = @($script:tabState | Where-Object Id -ne $Identity)
        }
    }
    It "creates and verifies website, PDF, PowerPoint and SharePoint page tabs with void responses" {
        foreach ($type in @("WebSite", "PDF", "PowerPoint", "SharePointPageAndList")) {
            $script:spec = New-ResourceSpec $type
            $sync.Specification = $spec
            $script:tabState = @()
            $result = Sync-CoEManagedResourceTab @sync
            (Test-CoEManagedTabTarget $result $spec $sync.EntityId) | Should Be $true
            (Sync-CoEManagedResourceTab @sync).Id | Should Be $result.Id
        }
        Assert-MockCalled Add-PnPTeamsTab -Times 4 -Exactly -Scope It
        Assert-MockCalled Remove-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "replaces captured file identities only after verifying the uploaded file identity" {
        $script:spec = New-ResourceSpec PDF
        $sync.Specification = $spec
        $script:tabState = @(New-ResourceTab captured PDF $spec.ContentUrl "old-tenant-file")
        Mock Remove-PnPTeamsTab {
            @($script:tabState | Where-Object { Test-CoEManagedTabTarget $_ $spec $sync.EntityId }).Count | Should Be 1
            $script:tabState = @($script:tabState | Where-Object Id -ne $Identity)
        }
        (Sync-CoEManagedResourceTab @sync).Id | Should Be "created-1"
        $tabState.Count | Should Be 1
        Assert-MockCalled Remove-PnPTeamsTab -Times 1 -Exactly -Scope It -ParameterFilter { $Identity -eq "captured" }
    }
    It "does not accept missing file identity or an app of the wrong type as a verified destination" {
        $script:spec = New-ResourceSpec PDF
        $sync.Specification = $spec
        $script:tabState = @(New-ResourceTab wrong-app WebSite $spec.ContentUrl)
        $script:tabState += @(New-ResourceTab unbound PDF "" "")
        $script:tabState += @(New-ResourceTab custom PDF "https://unrelated.example/custom" "")
        $script:tabState += @(New-ResourceTab wrapper PDF ("https://unrelated.example/?file=" + [uri]::EscapeDataString($spec.ContentUrl)) $sync.EntityId)
        (Sync-CoEManagedResourceTab @sync).Id | Should Be "created-1"
        @($tabState | ForEach-Object Id) -join "," | Should Be "wrong-app,custom,wrapper,created-1"
        Assert-MockCalled Write-Warning -Times 3 -Exactly -Scope It
        $sync.EntityId = ""
        { Sync-CoEManagedResourceTab @sync } | Should Throw
    }

    It "preserves unrelated same-name web and page tabs, even with the intended URL hidden in an unrelated wrapper" {
        foreach ($type in @("WebSite", "SharePointPageAndList")) {
            $script:spec = New-ResourceSpec $type
            $sync.Specification = $spec
            $custom = New-ResourceTab custom $type $spec.WebsiteUrl
            $custom.Configuration.ContentUrl = "https://unrelated.example/?dest=" + [uri]::EscapeDataString($spec.WebsiteUrl)
            $script:tabState = @($custom)
            (Sync-CoEManagedResourceTab @sync).Id | Should Not Be "custom"
            @($tabState | Where-Object Id -eq custom).Count | Should Be 1
        }
        Assert-MockCalled Remove-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "rejects a website with the right content but a wrong external destination" {
        $tab = New-ResourceTab wrong WebSite $spec.ContentUrl
        $tab.Configuration.WebsiteUrl = "https://unrelated.example/custom"
        (Test-CoEManagedTabTarget $tab $spec "") | Should Be $false
    }
    It "rejects ambiguous or missing tab IDs before creating or removing tabs" {
        foreach ($type in @("WebSite", "PDF")) {
            $script:spec = New-ResourceSpec $type
            $sync.Specification = $spec
            $script:tabState = @(New-ResourceTab "" $type $spec.WebsiteUrl $sync.EntityId)
            { Sync-CoEManagedResourceTab @sync } | Should Throw
            $script:tabState = @(New-ResourceTab repeated $type $spec.WebsiteUrl $sync.EntityId)
            $script:tabState += @(New-ResourceTab repeated $type $spec.WebsiteUrl $sync.EntityId)
            { Sync-CoEManagedResourceTab @sync } | Should Throw
        }
        Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
        Assert-MockCalled Remove-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "rejects actor-specific or changed SharePoint login wrappers" {
        $script:spec = New-ResourceSpec SharePointPageAndList
        foreach ($change in @("actor", "spfx", "duplicate")) {
            $tab = New-ResourceTab page SharePointPageAndList $spec.WebsiteUrl
            switch ($change) {
                "actor" { $tab.Configuration.ContentUrl += "&actor=someone" }
                "spfx" { $tab.Configuration.ContentUrl = $tab.Configuration.ContentUrl.Replace("spfx=true", "spfx=false") }
                "duplicate" { $tab.Configuration.ContentUrl += "&dest=" + [uri]::EscapeDataString($spec.WebsiteUrl) }
            }
            (Test-CoEManagedTabTarget $tab $spec "") | Should Be $false
        }
    }
    It "preserves a tab without configuration rather than inferring management from its name" {
        $script:spec = New-ResourceSpec PDF
        $sync.Specification = $spec
        $tab = New-ResourceTab custom PDF ""
        $tab.Configuration = $null
        $script:tabState = @($tab)
        (Sync-CoEManagedResourceTab @sync).Id | Should Be "created-1"
        @($tabState | Where-Object Id -eq custom).Count | Should Be 1
        Assert-MockCalled Remove-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "replaces only the known captured SharePoint app and preserves other app types" {
        $script:spec = New-ResourceSpec SharePointPageAndList
        $sync.Specification = $spec
        $captured = New-ResourceTab captured SharePointPageAndList $spec.WebsiteUrl
        $captured.TeamsApp.Id = $spec.TemplateAppId
        $custom = New-ResourceTab custom WebSite $spec.WebsiteUrl
        $script:tabState = @($captured, $custom)
        (Sync-CoEManagedResourceTab @sync).Id | Should Be "created-1"
        @($tabState | ForEach-Object Id) -join "," | Should Be "custom,created-1"
        Assert-MockCalled Remove-PnPTeamsTab -Times 1 -Exactly -Scope It -ParameterFilter { $Identity -eq "captured" }
    }
    It "cleans exact duplicates without re-creating and preserves custom same-name tabs" {
        foreach ($type in @("WebSite", "PDF", "SharePointPageAndList")) {
            $script:spec = New-ResourceSpec $type
            $sync.Specification = $spec
            $script:tabState = @(New-ResourceTab keep $type $spec.WebsiteUrl $sync.EntityId)
            $script:tabState += @(New-ResourceTab duplicate $type $spec.WebsiteUrl $sync.EntityId)
            $script:tabState += @(New-ResourceTab custom WebSite "https://unrelated.example/custom")
            (Sync-CoEManagedResourceTab @sync).Id | Should Be "keep"
            @($tabState | ForEach-Object Id) -join "," | Should Be "keep,custom"
        }
        Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "recovers a deletion denied after a verified replacement without another create on resume" {
        $script:spec = New-ResourceSpec PowerPoint
        $sync.Specification = $spec
        $script:tabState = @(New-ResourceTab captured PowerPoint $spec.ContentUrl "captured-file")
        Mock Remove-PnPTeamsTab { throw "403 Forbidden" }
        { Sync-CoEManagedResourceTab @sync } | Should Throw
        $tabState.Count | Should Be 2
        Mock Remove-PnPTeamsTab { $script:tabState = @($script:tabState | Where-Object Id -ne $Identity) }
        (Sync-CoEManagedResourceTab @sync).Id | Should Be "created-1"
        Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
    }
    It "does not delete any tab when a successful create is unpersisted or has the wrong destination" {
        $script:spec = New-ResourceSpec PDF
        $sync.Specification = $spec
        $script:tabState = @(New-ResourceTab captured PDF $spec.ContentUrl "captured-file")
        Mock Add-PnPTeamsTab { New-ResourceTab not-persisted PDF $ContentUrl $EntityId }
        { Sync-CoEManagedResourceTab @sync } | Should Throw
        Mock Add-PnPTeamsTab { $script:tabState += @(New-ResourceTab wrong PDF "https://unrelated.example/file" $EntityId) }
        { Sync-CoEManagedResourceTab @sync } | Should Throw
        Assert-MockCalled Remove-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "does not swallow denied writes or retry them even when the error mentions a timeout" {
        Mock Add-PnPTeamsTab { throw "403 Forbidden after Timeout" }
        { Sync-CoEManagedResourceTab @sync } | Should Throw
        Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
        Assert-MockCalled Remove-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "recovers an exact ambiguous create and does not mistake the wrong type for success" {
        $script:spec = New-ResourceSpec PDF
        $sync.Specification = $spec
        Mock Add-PnPTeamsTab {
            $script:tabCreates++
            $script:tabState += @(New-ResourceTab exact PDF $ContentUrl $EntityId $DisplayName)
            throw "503 ServiceUnavailable"
        }
        (Sync-CoEManagedResourceTab @sync).Id | Should Be "exact"
        Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
        $script:tabState = @(New-ResourceTab custom WebSite $spec.ContentUrl "" $spec.DisplayName)
        Mock Add-PnPTeamsTab { throw "Timeout" }
        { Sync-CoEManagedResourceTab @sync } | Should Throw
        Assert-MockCalled Add-PnPTeamsTab -Times 5 -Exactly -Scope It
    }
    It "detects duplicate cleanup that returns void without deleting the duplicate" {
        $script:tabState = @(New-ResourceTab keep WebSite $spec.ContentUrl)
        $script:tabState += @(New-ResourceTab duplicate WebSite $spec.ContentUrl)
        Mock Remove-PnPTeamsTab {}
        { Sync-CoEManagedResourceTab @sync } | Should Throw
        Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "propagates read failures during ambiguous-write verification" {
        $script:reads = 0
        Mock Get-PnPTeamsTab {
            $script:reads++
            if ($script:reads -gt 1) { throw "403 Forbidden" }
            $script:tabState
        }
        Mock Add-PnPTeamsTab { throw "Timeout" }
        { Sync-CoEManagedResourceTab @sync } | Should Throw
        Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
    }
}

Describe "Uploaded file identity verification" {
    BeforeEach {
        $script:fileArgs = @{ FileUrl = "https://neutral.sharepoint.com/teams/CoE/Shared%20Documents/Prompt/Resource.pdf"
            SiteUrl = "https://neutral.sharepoint.com/teams/CoE"; Connection = "offline" }
        $script:file = New-Object OfflineCoEFile
        $script:file.UniqueId = [guid]"33333333-3333-3333-3333-333333333333"
        $script:file.ServerRelativeUrl = "/teams/CoE/Shared Documents/Prompt/Resource.pdf"
        Mock Get-PnPFile {
            if ($Url -ne "/teams/CoE/Shared Documents/Prompt/Resource.pdf" -or -not $AsFileObject -or $Connection -ne "offline") {
                throw "Wrong managed file identity"
            }
            $script:file
        }
        Mock Get-PnPProperty {
            if ($ClientObject -ne $script:file -or @($Property).Count -ne 2 -or
                "UniqueId" -notin $Property -or "ServerRelativeUrl" -notin $Property -or $Connection -ne "offline") {
                throw "Wrong property request"
            }
        }
    }
    It "uses typed uploaded GUID properties and supports a void property load" {
        (Get-CoEManagedFileIdentity @fileArgs) | Should Be "33333333-3333-3333-3333-333333333333"
        Assert-MockCalled Get-PnPProperty -Times 1 -Exactly -Scope It
    }
    It "rejects an empty identity or a returned file from the wrong site" {
        $script:file.UniqueId = [guid]::Empty
        { Get-CoEManagedFileIdentity @fileArgs } | Should Throw
        $script:file.UniqueId = [guid]"33333333-3333-3333-3333-333333333333"
        $script:file.ServerRelativeUrl = "/teams/Other/Shared Documents/Prompt/Resource.pdf"
        { Get-CoEManagedFileIdentity @fileArgs } | Should Throw
    }
    It "fails closed on read or property permission errors" {
        Mock Get-PnPProperty { throw "403 Forbidden" }
        { Get-CoEManagedFileIdentity @fileArgs } | Should Throw
        Mock Get-PnPFile { throw "401 Unauthorized" }
        { Get-CoEManagedFileIdentity @fileArgs } | Should Throw
    }
}

Describe "Expanded Teams app identity reconciliation" {
    BeforeEach {
        $script:spec = New-ResourceSpec WebSite
        $script:sync = @{ Team = "runtime-team"; Channel = "runtime-channel"; Specification = $spec
            EntityId = "22222222-2222-2222-2222-222222222222"; Connection = "offline" }
        $script:appTabs = @{}
        $script:tabId = "44444444-4444-4444-4444-444444444444"
        $script:catalogId = "55555555-5555-5555-5555-555555555555"
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Start-Sleep {}
        Mock Get-PnPTeamsTab {
            if ($Team -ne "runtime-team" -or $Channel -ne "runtime-channel" -or $Connection -ne "offline") { throw "Wrong expanded-tab scope" }
            if ($Identity) {
                if (-not $script:appTabs.ContainsKey([string]$Identity)) { throw "Unknown tab identity" }
                return $script:appTabs[[string]$Identity]
            }
            foreach ($expanded in $script:appTabs.Values) {
                $summary = New-Object OfflineCoEResourceTab
                $summary.Id = $expanded.Id
                $summary.DisplayName = $expanded.DisplayName
                $summary.Configuration = $expanded.Configuration
                # The real PnP collection read does not expand TeamsApp.
                $summary
            }
        }
        Mock Add-PnPTeamsTab { throw "Unexpected tab create" }
        Mock Remove-PnPTeamsTab { throw "Unexpected tab remove" }
        Mock Invoke-PnPGraphMethod {
            if ($Method -ne "Get" -or -not $Raw -or $Connection -ne "offline") { throw "Unexpected expanded read" }
            $prefix = "v1.0/teams/runtime-team/channels/runtime-channel/tabs/"
            if (-not $Url.StartsWith($prefix) -or -not $Url.EndsWith('?'+ '$expand=teamsApp')) { throw "Wrong expanded-tab scope" }
            $id = $Url.Substring($prefix.Length).Split('?')[0]
            if (-not $script:appTabs.ContainsKey($id)) { throw "Unknown expanded-tab identity" }
            $script:appTabs[$id] | ConvertTo-Json -Depth 15 -Compress
        }
    }
    It "hydrates a valid list tab by its exact runtime GUID before comparing the store app identity" {
        $script:appTabs[$tabId] = New-ResourceTab $tabId WebSite $spec.ContentUrl
        (Sync-CoEManagedResourceTab @sync).Id | Should Be $tabId
        Assert-MockCalled Invoke-PnPGraphMethod -Times 3 -Exactly -Scope It -ParameterFilter { $Url -match $script:tabId }
        Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
        Assert-MockCalled Remove-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "compares the expanded manifest ExternalId rather than a tenant catalog GUID for all supported types" {
        foreach ($type in @("WebSite", "PDF", "PowerPoint", "SharePointPageAndList")) {
            $script:spec = New-ResourceSpec $type
            $sync.Specification = $spec
            $tab = New-ResourceTab $tabId $type $spec.WebsiteUrl $sync.EntityId
            $tab.TeamsApp.Id = $catalogId
            $tab.TeamsApp.ExternalId = $spec.TeamsAppId
            $tab.TeamsApp.DistributionMethod = "organization"
            $script:appTabs = @{ $tabId = $tab }
            (Get-CoETabAppId $tab) | Should Be $spec.TeamsAppId
            (Sync-CoEManagedResourceTab @sync).Id | Should Be $tabId
        }
        Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
        Assert-MockCalled Remove-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "does not confuse an unrelated app name, catalog GUID, or stale flat TeamsAppId with the manifest identity" {
        $tab = New-ResourceTab $tabId WebSite $spec.ContentUrl
        $tab.TeamsApp.Id = $catalogId
        $tab.TeamsApp.ExternalId = "unrelated-manifest"
        $tab.TeamsApp.DisplayName = "Website"
        $tab.TeamsAppId = $spec.TeamsAppId
        (Get-CoETabAppId $tab) | Should Be "unrelated-manifest"
        (Test-CoEManagedTabTarget $tab $spec "") | Should Be $false
        $script:appTabs[$tabId] = $tab
        Mock Add-PnPTeamsTab { throw "App is blocked by app policy" }
        { Sync-CoEManagedResourceTab @sync } | Should Throw "No app policy change"
        Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
        Assert-MockCalled Remove-PnPTeamsTab -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
    }
    It "fails closed before any write when the expanded app is absent or runtime identity changed" {
        foreach ($problem in @("no-app", "no-id", "wrong-id", "wrong-name", "multiple", "no-result")) {
            $tab = New-ResourceTab $tabId WebSite $spec.ContentUrl
            $script:appTabs[$tabId] = $tab
            Mock Get-PnPTeamsTab {
                $summary = New-Object OfflineCoEResourceTab
                $summary.Id = $script:tabId
                $summary.DisplayName = "Managed"
                return $summary
            }
            Mock Invoke-PnPGraphMethod {
                switch ($problem) {
                    "no-app" { $tab.TeamsApp = $null }
                    "no-id" { $tab.TeamsApp.Id = "" }
                    "wrong-id" { $tab.Id = "66666666-6666-6666-6666-666666666666" }
                    "wrong-name" { $tab.DisplayName = "Different resource" }
                    "multiple" { return (@($tab, $tab) | ConvertTo-Json -Depth 15 -Compress) }
                    "no-result" { return $null }
                }
                return ($tab | ConvertTo-Json -Depth 15 -Compress)
            }
            { Sync-CoEManagedResourceTab @sync } | Should Throw
        }
        Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
        Assert-MockCalled Remove-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "rejects a nonguid unexpanded tab instead of letting the cmdlet choose by name" {
        Mock Get-PnPTeamsTab { [pscustomobject]@{ Id = "not-a-runtime-guid"; DisplayName = "Managed"; TeamsApp = $null } }
        { Sync-CoEManagedResourceTab @sync } | Should Throw "valid runtime tab GUID"
        Assert-MockCalled Get-PnPTeamsTab -Times 0 -Exactly -Scope It -ParameterFilter { $Identity }
        Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "propagates expansion authorization failures without creating a replacement" {
        $script:appTabs[$tabId] = New-ResourceTab $tabId WebSite $spec.ContentUrl
        Mock Invoke-PnPGraphMethod { throw "403 Forbidden" }
        { Sync-CoEManagedResourceTab @sync } | Should Throw "403 Forbidden"
        Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
    It "hydrates tabs when recovering a timed-out create and verifies the manifest identity before succeeding" {
        Mock Add-PnPTeamsTab {
            $tab = New-ResourceTab $script:tabId WebSite $ContentUrl "" $DisplayName
            $tab.TeamsApp.Id = $script:catalogId
            $tab.TeamsApp.ExternalId = $script:spec.TeamsAppId
            $script:appTabs[$script:tabId] = $tab
            throw "Timeout"
        }
        (Sync-CoEManagedResourceTab @sync).Id | Should Be $tabId
        Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
    }
    It "does not hydrate unrelated tab names while verifying a managed resource" {
        $script:appTabs[$tabId] = New-ResourceTab $tabId WebSite $spec.ContentUrl
        $customId = "66666666-6666-6666-6666-666666666666"
        $script:appTabs[$customId] = New-ResourceTab $customId WebSite "https://unrelated.example/custom" "" "Custom"
        (Sync-CoEManagedResourceTab @sync).Id | Should Be $tabId
        Assert-MockCalled Invoke-PnPGraphMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Url -match $customId }
    }
    It "surfaces app-scope policy denial without retries even if the message also mentions Timeout" {
        Mock Add-PnPTeamsTab { throw "App com.microsoft.teamspace.tab.web is blocked by app policy; Timeout" }
        { Sync-CoEManagedResourceTab @sync } | Should Throw "No app policy change"
        Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
        Assert-MockCalled Remove-PnPTeamsTab -Times 0 -Exactly -Scope It
    }
}

    Describe "Migrated modern PowerPoint tab destinations" {
        BeforeEach {
            $script:spec = New-ResourceSpec PowerPoint
            $script:fileId = "22222222-2222-2222-2222-222222222222"
            $script:modern = New-ModernResourceTab $spec.ContentUrl $fileId
            $script:modernState = @($modern)
            $script:sync = @{ Team = "runtime-team"; Channel = "19:runtime@thread.tacv2"; Specification = $spec
                EntityId = $fileId; Connection = "offline" }
            Mock Write-Warning {}
            Mock Start-Sleep {}
            Mock Get-PnPTeamsTab {
                foreach ($tab in $script:modernState) {
                    $summary = New-Object OfflineCoEResourceTab
                    $summary.Id = $tab.Id
                    $summary.DisplayName = $tab.DisplayName
                    $summary.Configuration = New-Object OfflineCoETabConfiguration
                    $summary.Configuration.ContentUrl = $tab.Configuration.ContentUrl
                    $summary.Configuration.EntityId = "2"
                    $summary
                }
            }
            Mock Invoke-PnPGraphMethod {
                if ($Method -ne "Get" -or -not $Raw -or $Connection -ne "offline" -or
                    $Url -notmatch '^v1\.0/teams/runtime-team/channels/19%3Aruntime%40thread\.tacv2/tabs/[0-9a-f-]+\?\$expand=teamsApp$') {
                    throw "Wrong raw expansion scope"
                }
                $id = $Url.Split('/')[-1].Split('?')[0]
                $tab = @($script:modernState | Where-Object Id -eq $id)
                if ($tab.Count -ne 1) { throw "Ambiguous raw tab" }
                $tab[0] | ConvertTo-Json -Depth 20 -Compress
            }
            Mock Add-PnPTeamsTab { throw "Unexpected tab replacement" }
            Mock Remove-PnPTeamsTab { throw "Unexpected tab removal" }
        }
        It "retains the verified migrated tab with double-encoded objectUrl and real file GUID, not entityId 2" {
            (Get-CoEModernPowerPointTarget $modern).FileUrl | Should Be $spec.ContentUrl
            (Test-CoEManagedTabTarget $modern $spec $fileId) | Should Be $true
            (Test-TeamsFileTabTarget $modern $spec.ContentUrl $fileId) | Should Be $true
            (Sync-CoEManagedResourceTab @sync).Id | Should Be $modern.Id
            (Sync-CoEManagedResourceTab @sync).Id | Should Be $modern.Id
            Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
            Assert-MockCalled Remove-PnPTeamsTab -Times 0 -Exactly -Scope It
        }
        It "does not accept a different uploaded GUID or a same filename in another site" {
            (Test-CoEManagedTabTarget $modern $spec "33333333-3333-3333-3333-333333333333") | Should Be $false
            $other = New-ModernResourceTab ($spec.ContentUrl.Replace("/teams/CoE/", "/teams/Other/")) $fileId
            (Test-CoEManagedTabTarget $other $spec $fileId) | Should Be $false
            (Test-TeamsFileTabTarget $other $spec.ContentUrl $fileId) | Should Be $false
        }
        It "rejects conflicting modern object/file metadata and an unrelated modern app" {
            foreach ($problem in @("objectId", "fileId", "fileUrl", "fileType", "fileJson", "app")) {
                $tab = New-ModernResourceTab $spec.ContentUrl $fileId
                switch ($problem) {
                    "objectId" { $tab.Configuration.objectId = "33333333-3333-3333-3333-333333333333" }
                    "fileId" { $tab.Configuration.file = '{"type":"pptx","objectId":"33333333-3333-3333-3333-333333333333","objectUrl":"https://unrelated.example/file"}' }
                    "fileUrl" { $tab.Configuration.file = (@{type="pptx";objectId=$fileId;objectUrl="https://unrelated.example/file"} | ConvertTo-Json -Compress) }
                    "fileType" { $tab.Configuration.file = (@{type="docx";objectId=$fileId;objectUrl=$spec.ContentUrl} | ConvertTo-Json -Compress) }
                    "fileJson" { $tab.Configuration.file = 'not JSON' }
                    "app" { $tab.TeamsApp.id = "unrelated-app" }
                }
                (Test-CoEManagedTabTarget $tab $spec $fileId) | Should Be $false
            }
        }
        It "rejects malformed JSON, duplicate subentities, wrong hosts, and a non-pinned modern payload" {
            foreach ($problem in @("json", "duplicate", "host", "path", "payload")) {
                $tab = New-ModernResourceTab $spec.ContentUrl $fileId
                switch ($problem) {
                    "json" { $tab.Configuration.contentUrl = "https://m365.cloud.microsoft/launch/PowerPoint/officeunihost/teams?subEntityId=notjson" }
                    "duplicate" { $tab.Configuration.contentUrl += "&subEntityId=other" }
                    "host" { $tab.Configuration.contentUrl = $tab.Configuration.contentUrl.Replace("m365.cloud.microsoft", "unrelated.example") }
                    "path" { $tab.Configuration.contentUrl = $tab.Configuration.contentUrl.Replace("/PowerPoint/", "/Word/") }
                    "payload" {
                        $json = @{fileType="pptx";fileId=$fileId;objectUrl=$spec.ContentUrl;isPinnedTab=$false} | ConvertTo-Json -Compress
                        $tab.Configuration.contentUrl = "https://m365.cloud.microsoft/launch/PowerPoint/officeunihost/teams?subEntityId=" + [uri]::EscapeDataString($json)
                    }
                }
                (Test-CoEManagedTabTarget $tab $spec $fileId) | Should Be $false
            }
        }
        It "cleans exact modern duplicate tabs without replacing a working migrated tab" {
            $duplicate = New-ModernResourceTab $spec.ContentUrl $fileId
            $duplicate.id = "55555555-5555-5555-5555-555555555555"
            $script:modernState += $duplicate
            Mock Remove-PnPTeamsTab { $script:modernState = @($script:modernState | Where-Object Id -ne $Identity) }
            (Sync-CoEManagedResourceTab @sync).Id | Should Be $modern.Id
            $modernState.Count | Should Be 1
            Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
            Assert-MockCalled Remove-PnPTeamsTab -Times 1 -Exactly -Scope It -ParameterFilter { $Identity -eq $duplicate.id }
        }
        It "requires raw re-expansion even when PnP has typed modern app metadata but omitted file fields" {
            Mock Get-PnPTeamsTab {
                $typed = New-ResourceTab $modern.Id PowerPoint $spec.ContentUrl "2"
                $typed.TeamsApp.Id = $modern.TeamsApp.id
                $typed.Configuration.ContentUrl = $modern.Configuration.contentUrl
                $typed
            }
            (Sync-CoEManagedResourceTab @sync).Id | Should Be $modern.Id
            Assert-MockCalled Invoke-PnPGraphMethod -Times 3 -Exactly -Scope It
            Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
        }
    }

    Describe "Read-only Team app capability verification" {
        BeforeEach {
            $script:teamId = "11111111-1111-1111-1111-111111111111"
            $script:connection = [pscustomobject]@{ AzureEnvironment = "USGovernmentHigh" }
            $script:installedApps = @()
            $script:appArgs = @{ Team = $teamId; Connection = $connection }
            Mock Write-Host {}
            Mock Start-Sleep {}
            Mock Invoke-PnPGraphMethod {
                if ($Connection -ne $script:connection) { throw "Wrong app connection" }
                if ($Method -ne "Get" -or $Url -ne "v1.0/teams/$($script:teamId)/installedApps?`$expand=teamsApp" -or -not $Raw) {
                    throw "Unexpected app mutation or wrong read scope"
                }
                return (@{value=@($script:installedApps)} | ConvertTo-Json -Depth 15 -Compress)
            }
            Mock Add-PnPTeamsTab { throw "Unexpected tab add" }
        }
        It "returns an empty capability collection without trying to install any app" {
            @(Get-CoETeamResourceApps @appArgs).Count | Should Be 0
            Assert-MockCalled Invoke-PnPGraphMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Method -ne "Get" }
        }
        It "does not install a permanent Website app after a missing-app error" {
            Mock Add-PnPTeamsTab { throw "App needs to be installed to the scope and be in an unblocked state" }
            { Add-TeamsTabWithRetry -Team $teamId -Channel channel -DisplayName Managed -TabArgs @{Type="WebSite";ContentUrl="https://learn.microsoft.com/resource"} `
                -Connection $connection } | Should Throw "No app policy change"
            Assert-MockCalled Invoke-PnPGraphMethod -Times 0 -Exactly -Scope It
            Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
        }
        It "compares expanded app ExternalId rather than the installation ID and never grants resource-specific consent" {
            $script:installedApps = @([pscustomobject]@{id="com.microsoft.teamspace.tab.web"
                teamsApp=[pscustomobject]@{id="55555555-5555-5555-5555-555555555555";externalId="com.microsoft.teamspace.tab.web";distributionMethod="organization"}})
            $apps = @(Get-CoETeamResourceApps @appArgs)
            (Find-CoEResourceAppInstallation $apps "com.microsoft.teamspace.tab.web").id | Should Be "com.microsoft.teamspace.tab.web"
            Assert-MockCalled Invoke-PnPGraphMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq "Post" }
        }
        It "does not mistake an installation ID for the app identity" {
            $script:installedApps = @([pscustomobject]@{id="com.microsoft.teamspace.tab.web";teamsApp=[pscustomobject]@{id="unrelated-app";externalId=$null}})
            $apps = @(Get-CoETeamResourceApps @appArgs)
            (Find-CoEResourceAppInstallation $apps "com.microsoft.teamspace.tab.web") | Should BeNullOrEmpty
            Assert-MockCalled Invoke-PnPGraphMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq "Post" }
        }
        It "does not attempt app installation for authorization or explicit policy denials" {
            foreach ($message in @("403 Forbidden: App needs to be installed", "App is blocked by policy and needs to be installed")) {
                Mock Add-PnPTeamsTab { throw $message }
                { Add-TeamsTabWithRetry -Team $teamId -Channel channel -DisplayName Managed -TabArgs @{Type="WebSite";ContentUrl="https://learn.microsoft.com/resource"} `
                    -Connection $connection } | Should Throw
            }
            Assert-MockCalled Invoke-PnPGraphMethod -Times 0 -Exactly -Scope It
            Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
        }
        It "propagates denied app reads without requesting additional consent" {
            Mock Invoke-PnPGraphMethod { throw "403 Forbidden App policy Timeout" }
            { Get-CoETeamResourceApps @appArgs } | Should Throw
            Assert-MockCalled Invoke-PnPGraphMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq "Post" }
            Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
        }
        It "rejects malformed or unexpanded installation metadata" {
            foreach ($metadata in @('{}','{"value":null}','{"value":{}}','{"value":[{"id":"installation","teamsApp":null}]}')) {
                Mock Invoke-PnPGraphMethod { return $metadata }
                { Get-CoETeamResourceApps @appArgs } | Should Throw
            }
            Assert-MockCalled Invoke-PnPGraphMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq "Post" }
        }
        It "rejects nonruntime Team names and unverified Graph endpoints" {
            { Get-CoETeamResourceApps -Team tenant-alias -Connection $connection } | Should Throw
            { Get-CoETeamResourceApps -Team $teamId -Connection ([pscustomobject]@{AzureEnvironment="Custom"}) } | Should Throw
            Assert-MockCalled Invoke-PnPGraphMethod -Times 0 -Exactly -Scope It
        }
        It "follows only same-Team Graph paging and finds an existing app beyond the first page" {
            Mock Invoke-PnPGraphMethod {
                if ($Url.StartsWith("v1.0/")) {
                    return (@{value=@();'@odata.nextLink'="https://graph.microsoft.us/v1.0/teams/$($script:teamId)/installedApps?`$skiptoken=page2"} | ConvertTo-Json -Compress)
                }
                if ($Url -ne "https://graph.microsoft.us/v1.0/teams/$($script:teamId)/installedApps?`$skiptoken=page2") { throw "Wrong next page scope" }
                return '{"value":[{"id":"installation","teamsApp":{"id":"com.microsoft.teamspace.tab.web"}}]}'
            }
            $apps = @(Get-CoETeamResourceApps @appArgs)
            (Find-CoEResourceAppInstallation $apps "com.microsoft.teamspace.tab.web").id | Should Be "installation"
            Assert-MockCalled Invoke-PnPGraphMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq "Post" }
        }
        It "rejects paging to another host or Team without following it" {
            foreach ($url in @("https://unrelated.example/v1.0/teams/$teamId/installedApps?page=2",
                "https://graph.microsoft.us/v1.0/teams/22222222-2222-2222-2222-222222222222/installedApps?page=2")) {
                Mock Invoke-PnPGraphMethod { return (@{value=@();'@odata.nextLink'=$url} | ConvertTo-Json -Compress) }
                { Get-CoETeamResourceApps @appArgs } | Should Throw "outside the verified Team scope"
            }
            Assert-MockCalled Invoke-PnPGraphMethod -Times 2 -Exactly -Scope It
        }
        It "uses the public cloud setting rather than an inaccessible or spoofed GraphEndPoint property" {
            (Get-CoEResourceGraphHost ([pscustomobject]@{AzureEnvironment="Production";GraphEndPoint="unrelated.example"})) | Should Be "graph.microsoft.com"
            (Get-CoEResourceGraphHost ([pscustomobject]@{AzureEnvironment="USGovernmentHigh"})) | Should Be "graph.microsoft.us"
            { Get-CoEResourceGraphHost ([pscustomobject]@{GraphEndPoint="graph.microsoft.com"}) } | Should Throw
            { Get-CoEResourceGraphHost ([pscustomobject]@{AzureEnvironment="Custom"}) } | Should Throw
        }
    }
    Describe "Capability-based official resource link pages" {
        BeforeEach {
            $script:spec = New-ResourceSpec WebSite
            $script:pages = @{}
            $script:pageVersions = @{}
            $script:denyText = $false
            $script:denyPublish = $false
            $script:pageName = Get-CoEResourcePageName $spec.WebsiteUrl
            $script:siteConnection = [pscustomobject]@{ Url = "https://neutral.sharepoint.com/teams/CoE" }
            $script:pageArgs = @{ SiteUrl = "https://neutral.sharepoint.com/teams/CoE"; DisplayName = $spec.DisplayName
                ResourceUrl = $spec.WebsiteUrl; Connection = $siteConnection }
            $script:tabState = @()
            $script:sharePointApp = [pscustomobject]@{id="installed-sharepoint";teamsApp=[pscustomobject]@{id="2a527703-1f6f-4559-a332-d8a7d288cd88";externalId=$null}}
            $script:capabilityArgs = @{ Team="runtime-team";Channel="runtime-channel";Specification=$spec
                InstalledApps=@($sharePointApp);SiteUrl=$pageArgs.SiteUrl;SiteConnection=$siteConnection;Connection="offline" }
            Mock Write-Host {}
            Mock Write-Warning {}
            Mock Start-Sleep {}
            Mock Invoke-PnPGraphMethod { throw "No app installs or Graph calls expected" }
            Mock Get-PnPTeamsTab { $script:tabState }
            Mock Get-PnPWeb {
                if ($Connection -ne $script:siteConnection) { throw "Wrong web connection" }
                [pscustomobject]@{ Url = $script:pageArgs.SiteUrl }
            }
            Mock Get-PnPPage {
                if ($Connection -ne $script:siteConnection) { throw "Wrong page connection" }
                if ($Identity) {
                    if (-not $script:pages.ContainsKey([string]$Identity)) { throw "Missing page" }
                    return $script:pages[[string]$Identity]
                }
                $script:pages.Values
            }
            Mock Add-PnPPage {
                if ($Connection -ne $script:siteConnection -or $LayoutType -ne "Article" -or $ContentType -or
                    $Name -ne $script:pageName -or $Title -ne (Get-CoEResourcePagePendingTitle $script:spec.WebsiteUrl) -or $script:pages.ContainsKey([string]$Name)) {
                    throw "Unexpected page creation or overwrite"
                }
                $page = New-Object OfflineCoEResourcePage
                $page.Name = $Name
                $page.PageTitle = $Title
                $page.Controls = New-Object 'System.Collections.Generic.List[OfflineCoEPageText]'
                $script:pages[[string]$Name] = $page
                $script:pageVersions[[string]$Name] = @{ "_UIVersionString"="0.1"; "_ModerationStatus"=0 }
            }
            Mock Add-PnPPageTextPart {
                if ($script:denyText) { throw "403 Forbidden" }
                if ($Connection -ne $script:siteConnection -or $Page.Name -ne $script:pageName -or $Page.Controls.Count) { throw "Unexpected page content overwrite" }
                $textPart = New-Object OfflineCoEPageText
                $textPart.Text = $Text
                $Page.Controls.Add($textPart)
            }
            Mock Get-PnPFile {
                if ($Connection -ne $script:siteConnection -or -not $AsListItem -or $AsFileObject -or
                    $Url -ne "/teams/CoE/SitePages/$($script:pageName)") { throw "Wrong page version identity" }
                [pscustomobject]@{ FieldValues=$script:pageVersions[$script:pageName] }
            }
            Mock Set-PnPPage {
                if ($script:denyPublish) { throw "503 ServiceUnavailable" }
                if ($Connection -ne $script:siteConnection -or -not $Publish -or $Identity -ne $script:pageName -or $Title -ne $script:spec.DisplayName) { throw "Wrong publish identity" }
                $script:pages[[string]$Identity].PageTitle = $Title
                $script:pageVersions[[string]$Identity]["_UIVersionString"] = "1.0"
            }
            Mock Add-PnPTeamsTab {
                if ($Type -ne "SharePointPageAndList" -or -not $WebsiteUrl -or $ContentUrl -or $DisplayName -ne "Managed" -or
                    $Team -ne "runtime-team" -or $Channel -ne "runtime-channel") { throw "Wrong fallback tab parameters" }
                $script:tabState += @(New-ResourceTab "created" SharePointPageAndList $WebsiteUrl "" $DisplayName)
            }
            Mock Remove-PnPTeamsTab { throw "Unexpected unrelated tab removal" }
        }
        It "creates a deterministic private-parent resource page with the exact official external link and verifies publication" {
            $url = Ensure-CoEResourceLinkPage @pageArgs
            $url | Should Be "$($pageArgs.SiteUrl)/SitePages/$pageName"
            $html = $pages[$pageName].Controls[0].Text
            $html.Contains('target="_blank"') | Should Be $true
            $html.Contains('data-interception="off"') | Should Be $true
            $html.Contains($spec.WebsiteUrl) | Should Be $true
            (Test-CoEResourcePage $pages[$pageName] $spec.DisplayName $spec.WebsiteUrl) | Should Be $true
            (Ensure-CoEResourceLinkPage @pageArgs) | Should Be $url
            Assert-MockCalled Add-PnPPage -Times 1 -Exactly -Scope It
            Assert-MockCalled Add-PnPPageTextPart -Times 1 -Exactly -Scope It
            Assert-MockCalled Set-PnPPage -Times 1 -Exactly -Scope It
            Assert-MockCalled Invoke-PnPGraphMethod -Times 0 -Exactly -Scope It
        }
        It "uses the installed SharePoint app when Website is absent, keeps labels, and records the original URL" {
            $effective = Resolve-CoEResourceTabCapability @capabilityArgs
            $effective.DisplayName | Should Be $spec.DisplayName
            $effective.Type | Should Be "SharePointPageAndList"
            $effective.OriginalUrl | Should Be $spec.WebsiteUrl
            $effective.ResourcePageUrl | Should Be "$($pageArgs.SiteUrl)/SitePages/$pageName"
            $effective.ProvisioningMode | Should Be "SharePointResourceLink"
            (Sync-CoEManagedResourceTab -Team runtime-team -Channel runtime-channel -Specification $effective -Connection offline).Id | Should Be created
            $again = Resolve-CoEResourceTabCapability @capabilityArgs
            (Sync-CoEManagedResourceTab -Team runtime-team -Channel runtime-channel -Specification $again -Connection offline).Id | Should Be created
            Assert-MockCalled Add-PnPPage -Times 1 -Exactly -Scope It
            Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
            Assert-MockCalled Invoke-PnPGraphMethod -Times 0 -Exactly -Scope It
            Assert-MockCalled Write-Host -Times 2 -Exactly -Scope It
        }
        It "reuses the same guide page across standard channels without reposting or republishing" {
            $first = Resolve-CoEResourceTabCapability @capabilityArgs
            $capabilityArgs.Channel = "another-standard-channel"
            $second = Resolve-CoEResourceTabCapability @capabilityArgs
            $second.ResourcePageUrl | Should Be $first.ResourcePageUrl
            Assert-MockCalled Add-PnPPage -Times 1 -Exactly -Scope It
            Assert-MockCalled Set-PnPPage -Times 1 -Exactly -Scope It
        }
        It "preserves an already valid legacy Website tab even without a listed Website installation" {
            $script:tabState = @(New-ResourceTab legacy WebSite $spec.ContentUrl)
            (Resolve-CoEResourceTabCapability @capabilityArgs).Type | Should Be "WebSite"
            Assert-MockCalled Add-PnPPage -Times 0 -Exactly -Scope It
        }
        It "uses Website when its installed capability exists rather than silently choosing a fallback after a denial" {
            $capabilityArgs.InstalledApps = @($sharePointApp,[pscustomobject]@{id="website";teamsApp=[pscustomobject]@{id=$spec.TeamsAppId;externalId=$null}})
            $effective = Resolve-CoEResourceTabCapability @capabilityArgs
            $effective.Type | Should Be "WebSite"
            Mock Add-PnPTeamsTab { throw "403 Forbidden policy denial" }
            { Sync-CoEManagedResourceTab -Team runtime-team -Channel runtime-channel -Specification $effective -Connection offline } | Should Throw "403 Forbidden"
            Assert-MockCalled Add-PnPPage -Times 0 -Exactly -Scope It
        }
        It "preserves a verified resource-link choice when Website later becomes available" {
            $effective = Resolve-CoEResourceTabCapability @capabilityArgs
            Sync-CoEManagedResourceTab -Team runtime-team -Channel runtime-channel -Specification $effective -Connection offline | Out-Null
            $capabilityArgs.InstalledApps = @($sharePointApp,[pscustomobject]@{id="website";teamsApp=[pscustomobject]@{id=$spec.TeamsAppId;externalId=$null}})
            (Resolve-CoEResourceTabCapability @capabilityArgs).Type | Should Be "SharePointPageAndList"
            Assert-MockCalled Add-PnPTeamsTab -Times 1 -Exactly -Scope It
            Assert-MockCalled Add-PnPPage -Times 1 -Exactly -Scope It
            Assert-MockCalled Set-PnPPage -Times 1 -Exactly -Scope It
        }
        It "fails closed when neither app is available or capability identities are ambiguous" {
            $capabilityArgs.InstalledApps = @()
            { Resolve-CoEResourceTabCapability @capabilityArgs } | Should Throw "Neither the legacy Website"
            $capabilityArgs.InstalledApps = @($sharePointApp,$sharePointApp)
            { Resolve-CoEResourceTabCapability @capabilityArgs } | Should Throw
            Assert-MockCalled Add-PnPPage -Times 0 -Exactly -Scope It
            Assert-MockCalled Invoke-PnPGraphMethod -Times 0 -Exactly -Scope It
        }
        It "does not overwrite an existing custom or wrong-destination resource page" {
            Ensure-CoEResourceLinkPage @pageArgs | Out-Null
            $pages[$pageName].Controls[0].Text = '<p>Custom training notes</p><a href="https://unrelated.example" target="_blank">Custom</a>'
            { Ensure-CoEResourceLinkPage @pageArgs } | Should Throw "existing page was preserved"
            Assert-MockCalled Add-PnPPageTextPart -Times 1 -Exactly -Scope It
            Assert-MockCalled Add-PnPPage -Times 1 -Exactly -Scope It
        }
        It "rejects duplicate matching page identities before any page or tab write" {
            $page = [pscustomobject]@{Name=$pageName;PageTitle=$spec.DisplayName;Controls=@()}
            Mock Get-PnPPage { @($page,$page) }
            { Resolve-CoEResourceTabCapability @capabilityArgs } | Should Throw "Ambiguous resource page"
            Assert-MockCalled Add-PnPPage -Times 0 -Exactly -Scope It
            Assert-MockCalled Add-PnPPageTextPart -Times 0 -Exactly -Scope It
            Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
        }
        It "rejects extra custom controls without rewriting the page" {
            Ensure-CoEResourceLinkPage @pageArgs | Out-Null
            $text = New-Object OfflineCoEPageText
            $text.Text = "<p>Custom notes</p>"
            $pages[$pageName].Controls.Add($text)
            { Ensure-CoEResourceLinkPage @pageArgs } | Should Throw "existing page was preserved"
            Assert-MockCalled Add-PnPPageTextPart -Times 1 -Exactly -Scope It
        }
        It "rejects custom extra controls, changed interception, event handlers and wrong external URLs" {
            Ensure-CoEResourceLinkPage @pageArgs | Out-Null
            $original = $pages[$pageName].Controls[0].Text
            foreach ($problem in @("target","interception","url","handler","text","script","comment")) {
                $pages[$pageName].Controls[0].Text = switch ($problem) {
                    "target" { $original.Replace('target="_blank"','target="_self"') }
                    "interception" { $original.Replace('data-interception="off"','data-interception="on"') }
                    "url" { $original.Replace($spec.WebsiteUrl, "https://unrelated.example") }
                    "handler" { $original.Replace('<a href=', '<a onclick="custom()" href=') }
                    "text" { $original + "<p>Custom content</p>" }
                    "script" { $original.Replace("<h2>Managed</h2>","<script>Managed</script>") }
                    "comment" { $original + "<!-- custom -->" }
                }
                (Test-CoEResourcePage $pages[$pageName] $spec.DisplayName $spec.WebsiteUrl) | Should Be $false
            }
        }
        It "does not create tabs when page creation is denied" {
            Mock Add-PnPPage { throw "403 Forbidden" }
            { Resolve-CoEResourceTabCapability @capabilityArgs } | Should Throw "403 Forbidden"
            Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
            Assert-MockCalled Add-PnPPageTextPart -Times 0 -Exactly -Scope It
        }
        It "does not trust a returned page that was not persisted" {
            Mock Add-PnPPage { [pscustomobject]@{Name=$Name;PageTitle=$Title;Controls=@()} }
            { Ensure-CoEResourceLinkPage @pageArgs } | Should Throw "Missing page"
            Assert-MockCalled Add-PnPPageTextPart -Times 0 -Exactly -Scope It
            Assert-MockCalled Set-PnPPage -Times 0 -Exactly -Scope It
        }
        It "propagates page-read denials before creating pages or tabs" {
            Mock Get-PnPPage { throw "403 Forbidden" }
            { Resolve-CoEResourceTabCapability @capabilityArgs } | Should Throw "403 Forbidden"
            Assert-MockCalled Add-PnPPage -Times 0 -Exactly -Scope It
            Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
        }
        It "does not create tabs when page content writes are denied" {
            Mock Add-PnPPageTextPart { throw "403 Forbidden" }
            { Resolve-CoEResourceTabCapability @capabilityArgs } | Should Throw "403 Forbidden"
            Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
            Assert-MockCalled Set-PnPPage -Times 0 -Exactly -Scope It
        }
        It "does not create tabs when page publishing is denied" {
            Mock Set-PnPPage { throw "403 Forbidden" }
            { Resolve-CoEResourceTabCapability @capabilityArgs } | Should Throw "403 Forbidden"
            Assert-MockCalled Add-PnPTeamsTab -Times 0 -Exactly -Scope It
        }
        It "recovers the exact managed empty draft after interruption without overwriting custom pages" {
            $script:denyText = $true
            { Ensure-CoEResourceLinkPage @pageArgs } | Should Throw
            $pages[$pageName].PageTitle | Should Be (Get-CoEResourcePagePendingTitle $spec.WebsiteUrl)
            $script:denyText = $false
            Ensure-CoEResourceLinkPage @pageArgs | Should Be "$($pageArgs.SiteUrl)/SitePages/$pageName"
            Assert-MockCalled Add-PnPPage -Times 1 -Exactly -Scope It
            Assert-MockCalled Set-PnPPage -Times 1 -Exactly -Scope It
        }
        It "recovers exact saved pending content without duplicating the text after interruption" {
            $script:denyPublish = $true
            { Ensure-CoEResourceLinkPage @pageArgs } | Should Throw
            $script:denyPublish = $false
            Ensure-CoEResourceLinkPage @pageArgs | Out-Null
            Assert-MockCalled Add-PnPPage -Times 1 -Exactly -Scope It
            Assert-MockCalled Add-PnPPageTextPart -Times 1 -Exactly -Scope It
        }
        It "refuses empty published pages and pending pages with custom content" {
            Ensure-CoEResourceLinkPage @pageArgs | Out-Null
            $pages[$pageName].PageTitle = Get-CoEResourcePagePendingTitle $spec.WebsiteUrl
            $pages[$pageName].Controls.Clear()
            { Ensure-CoEResourceLinkPage @pageArgs } | Should Throw "published version"
            $pageVersions[$pageName]["_UIVersionString"] = "0.2"
            $text = New-Object OfflineCoEPageText
            $text.Text = "<p>Custom notes</p>"
            $pages[$pageName].Controls.Add($text)
            { Ensure-CoEResourceLinkPage @pageArgs } | Should Throw "conflicting content"
            Assert-MockCalled Add-PnPPageTextPart -Times 1 -Exactly -Scope It
        }
        It "refuses custom empty pages without the precise pending ownership marker" {
            Ensure-CoEResourceLinkPage @pageArgs | Out-Null
            $pages[$pageName].Controls.Clear()
            $pageVersions[$pageName]["_UIVersionString"] = "0.2"
            { Ensure-CoEResourceLinkPage @pageArgs } | Should Throw "existing page was preserved"
            Assert-MockCalled Add-PnPPageTextPart -Times 1 -Exactly -Scope It
        }
        It "verifies persisted content and major version rather than trusting void write or publish responses" {
            Mock Add-PnPPageTextPart {}
            { Ensure-CoEResourceLinkPage @pageArgs } | Should Throw "saved official link"
            Assert-MockCalled Set-PnPPage -Times 0 -Exactly -Scope It
        }
        It "rejects an unpublished or pending-approval page without approving it or changing its permissions" {
            Ensure-CoEResourceLinkPage @pageArgs | Out-Null
            $pageVersions[$pageName]["_ModerationStatus"] = 2
            { Ensure-CoEResourceLinkPage @pageArgs } | Should Throw "published link/version"
            $pageVersions[$pageName]["_ModerationStatus"] = 0
            $pageVersions[$pageName]["_UIVersionString"] = "1.1"
            Mock Set-PnPPage {}
            { Ensure-CoEResourceLinkPage @pageArgs } | Should Throw "published link/version"
        }
        It "rejects a wrong parent-site connection or a non-HTTPS resource before creating anything" {
            $pageArgs.Connection = [pscustomobject]@{ Url="https://neutral.sharepoint.com/sites/Other" }
            Mock Get-PnPWeb { [pscustomobject]@{ Url = "https://neutral.sharepoint.com/sites/Other" } }
            { Ensure-CoEResourceLinkPage @pageArgs } | Should Throw "private parent CoE site"
            $pageArgs.Connection = $siteConnection
            $pageArgs.ResourceUrl = "http://learn.microsoft.com/resource"
            { Ensure-CoEResourceLinkPage @pageArgs } | Should Throw "absolute HTTPS"
            Assert-MockCalled Add-PnPPage -Times 0 -Exactly -Scope It
        }
        It "accepts a site connection whose PnP connection object omits or carries a stale Url after verifying the current web" {
            $siteConnection.PSObject.Properties.Remove("Url")
            Ensure-CoEResourceLinkPage @pageArgs | Should Be "$($pageArgs.SiteUrl)/SitePages/$pageName"
            Assert-MockCalled Get-PnPWeb -Times 1 -Exactly -Scope It
            Assert-MockCalled Add-PnPPage -Times 1 -Exactly -Scope It
        }
        It "does not mistake a missing persisted page version for a successful create" {
            Mock Get-PnPFile { [pscustomobject]@{FieldValues=@{}} }
            { Ensure-CoEResourceLinkPage @pageArgs } | Should Throw "persisted version"
            Assert-MockCalled Add-PnPPageTextPart -Times 0 -Exactly -Scope It
            Assert-MockCalled Set-PnPPage -Times 0 -Exactly -Scope It
        }
        It "fails closed when an exact page file read returns nothing" {
            Mock Get-PnPFile {}
            { Ensure-CoEResourceLinkPage @pageArgs } | Should Throw "persisted version"
            Assert-MockCalled Add-PnPPageTextPart -Times 0 -Exactly -Scope It
        }
        It "retains unrelated same-name tabs while adding the verified resource-link page tab" {
            $script:tabState = @(New-ResourceTab custom WebSite "https://unrelated.example/custom")
            $effective = Resolve-CoEResourceTabCapability @capabilityArgs
            (Sync-CoEManagedResourceTab -Team runtime-team -Channel runtime-channel -Specification $effective -Connection offline).Id | Should Be created
            @($tabState | Where-Object Id -eq custom).Count | Should Be 1
            Assert-MockCalled Remove-PnPTeamsTab -Times 0 -Exactly -Scope It
        }
        It "escapes XML and HTML metacharacters without changing the official destination" {
            $html = Get-CoEResourcePageHtml 'Guide & <review> "quotes"' 'https://learn.microsoft.com/resource?first=1&second=2'
            $page = [pscustomobject]@{PageTitle='Guide & <review> "quotes"';Controls=@([pscustomobject]@{Text=$html})}
            (Test-CoEResourcePage $page 'Guide & <review> "quotes"' 'https://learn.microsoft.com/resource?first=1&second=2') | Should Be $true
            (Get-CoEResourcePageName $spec.WebsiteUrl) | Should Be $pageName
            (Get-CoEResourcePageName ($spec.WebsiteUrl + "-other")) | Should Not Be $pageName
        }
    }
Describe "Channel folder destination verification" {
    BeforeEach {
        $script:folderArgs = @{ Team = "runtime-team"; Channel = "runtime-channel"
            SiteUrl = "https://neutral.sharepoint.com/teams/CoE"
            ExpectedFolderUrl = "https://neutral.sharepoint.com/teams/CoE/Shared%20Documents/Prompt"; Connection = "offline" }
        Mock Start-Sleep {}
        Mock Get-PnPTeamsChannelFilesFolder { throw "Unexpected read" }
    }
    It "verifies an eventual runtime folder rather than creating a name-based replacement" {
        $script:reads = 0
        Mock Get-PnPTeamsChannelFilesFolder {
            if ($Team -ne "runtime-team" -or $Channel -ne "runtime-channel" -or $Connection -ne "offline") { throw "Wrong folder identity" }
            $script:reads++
            if ($script:reads -eq 1) { return $null }
            $folder = New-Object OfflineCoEDriveItem
            $folder.Id = "runtime-folder"
            $folder.WebUrl = "https://neutral.sharepoint.com/teams/CoE/Shared Documents/Prompt"
            return $folder
        }
        (Get-CoEStandardChannelFilesFolder @folderArgs).Id | Should Be "runtime-folder"
        Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It
    }
    It "rejects a same-name folder in another site immediately" {
        Mock Get-PnPTeamsChannelFilesFolder {
            $folder = New-Object OfflineCoEDriveItem
            $folder.WebUrl = "https://neutral.sharepoint.com/teams/Other/Shared Documents/Prompt"
            return $folder
        }
        { Get-CoEStandardChannelFilesFolder @folderArgs } | Should Throw
        Assert-MockCalled Get-PnPTeamsChannelFilesFolder -Times 1 -Exactly -Scope It
    }
    It "does not retry authorization failures or unclassified folder errors" {
        foreach ($errorText in @("403 Forbidden Timeout", "Unexpected service validation error")) {
            Mock Get-PnPTeamsChannelFilesFolder { throw $errorText }
            { Get-CoEStandardChannelFilesFolder @folderArgs } | Should Throw
        }
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
        Assert-MockCalled Get-PnPTeamsChannelFilesFolder -Times 2 -Exactly -Scope It
    }
}
