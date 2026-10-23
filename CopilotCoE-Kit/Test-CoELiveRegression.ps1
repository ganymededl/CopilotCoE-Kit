#Requires -Version 7.4
<#
.SYNOPSIS
Live regression for SharePoint behaviours that offline mocks cannot reproduce. Run against a SCRATCH site only.

.DESCRIPTION
Each check drives the kit's real functions against real SharePoint, with no mocks. Every one corresponds to a
failure that was found during live installs and that the offline tests passed straight through:

  R1  Server-relative view addresses contain spaces ("Learning steps.aspx") and must resolve.
  R2  CustomFormatter / DefaultValue must apply and read back without a PnP conversion warning.
  R3  SharePoint stores view CAML in a different form than it was sent; an unchanged view must be accepted.
  R4  Reviewer grants on the 2nd and 3rd catalog when the reviewer holds only Limited Access at site level.
  R5  Rerunning the three catalog synchronizers must change no catalog rows, views, fields, permissions or
      reviewer membership. This is not a full 02/03 rerun test; prove that with a second 03 run and
      Test-CoEInstall on an internal test site.
  R6  The connected-site comparison must accept the live connection.
  R7  The resume page list must match the packaged template.

The target site is only written to by this script. It must not be a production or customer site. Without
-AllowAnySite it refuses any URL that is not exactly https://<SiteFQDN from the settings file>/<managed path>/<alias>
with an alias that starts with "CoEScratch" or "CoE-Scratch" (for example CoEScratch1), or whose alias is the
settings file's own MailNickname.

.EXAMPLE
.\Test-CoELiveRegression.ps1 -SettingsPath C:\CoE-Orgs\Test\Deployment-Settings.json `
    -SiteUrl https://tenant.sharepoint.com/sites/CoEScratch1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SettingsPath,
    [Parameter(Mandatory)][string]$SiteUrl,
    [switch]$AllowAnySite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$kitRoot = $PSScriptRoot
Import-Module PnP.PowerShell -RequiredVersion 3.2.0 -ErrorAction Stop

$s = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
. (Join-Path $kitRoot "Internal\TargetResolution.ps1")
if (-not $AllowAnySite -and -not (Test-CoEScratchSiteUrl -Url $SiteUrl -SiteFqdn ([string]$s.SiteFQDN) -ProtectedAlias ([string]$s.MailNickname))) {
    throw ("Refusing to write to '$SiteUrl'. Use a throwaway site at https://$($s.SiteFQDN)/<managed path>/CoEScratch<n> " +
        "(not the configured CoE alias), or pass -AllowAnySite deliberately.")
}
$SiteUrl = $SiteUrl.TrimEnd("/")

. (Join-Path $kitRoot "Internal\SecurityPosture.ps1")
. (Join-Path $kitRoot "Internal\ResourceTabs.ps1")
. (Join-Path $kitRoot "Internal\AdoptionCatalogs.ps1")
. (Join-Path $kitRoot "Internal\SuccessStoryCatalog.ps1")
. (Join-Path $kitRoot "Internal\ProvisioningApp.ps1")

$results = [System.Collections.Generic.List[object]]::new()
function Invoke-Check([string]$Id, [string]$Name, [scriptblock]$Body) {
    $warnings = @()
    try {
        $output = & $Body 3>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.WarningRecord]) { $warnings += $_.Message } else { $_ }
        }
        $unexpected = @($warnings | Where-Object { $_ -notmatch 'SAMPLE - story|no assigned content owner|no recorded review date|MOCK-' })
        if ($unexpected.Count) { throw "Unexpected PnP warning: $($unexpected[0])" }
        $results.Add([pscustomobject]@{ Id = $Id; Check = $Name; Result = "PASS"; Detail = [string]($output | Select-Object -Last 1) })
    } catch {
        $results.Add([pscustomobject]@{ Id = $Id; Check = $Name; Result = "FAIL"; Detail = $_.Exception.Message })
    }
}

Assert-CoEProvisioningAppPublicClient -Tenant ([string]$s.Tenant) -ClientId ([string]$s.PnPClientID)
$admin = Connect-PnPOnline -Url ("https://" + $s.AdminFQDN) -ClientId $s.PnPClientID -Tenant $s.Tenant `
    -Interactive -PersistLogin -ReturnConnection -ErrorAction Stop
$site = Connect-PnPOnline -Url $SiteUrl -Connection $admin -ReturnConnection -ErrorAction Stop
$reviewerUpns = @($s.CatalogReviewerUPNs)
if (-not $reviewerUpns.Count) { throw "Set CatalogReviewerUPNs in the settings file: R4 needs a real reviewer." }
$reviewers = @(Resolve-CoECatalogReviewers -ReviewerUPNs $reviewerUpns -Connection $site)

# Earlier runs leave Limited Access for the reviewer on the site, which is the failing precondition for R4.
$sitePrep = "CoE Regression Prep"
if (-not (Get-PnPList -Identity $sitePrep -Connection $site -ErrorAction SilentlyContinue)) {
    New-PnPList -Title $sitePrep -Template GenericList -Url "Lists/CoERegressionPrep" -Connection $site | Out-Null
    Set-PnPList -Identity $sitePrep -BreakRoleInheritance -CopyRoleAssignments -Connection $site | Out-Null
    Set-PnPListPermission -Identity $sitePrep -User $reviewers[0].LoginName -AddRole "Contribute" -Connection $site
}

$seed = [pscustomobject]@{ Title = "SAMPLE - Regression story"; Audience = "Faculty"; Task = "Regression only."
    TimeSaved = ""; Video = ""; Status = "Submitted" }
$learningSeeds = @(Read-CoELearningSeeds -Path (Join-Path $kitRoot "SeedContent\Learning-Paths.json") -SiteUrl $SiteUrl)
$agentSeed = @([pscustomobject]@{ name = "<Agent name>"; url = ""; description = ""; audience = ""; examplePrompt = ""; owner = "" })

$script:stories = $null; $script:learning = $null; $script:agents = $null
Invoke-Check "R4" "Three catalogs plus a Limited-Access reviewer complete without a principal error" {
    $script:stories = Sync-CoESuccessStoryCatalog -Connection $site -SiteUrl $SiteUrl -Seeds @($seed) -ResolvedReviewers $reviewers
    $script:learning = Sync-CoELearningCatalog -Connection $site -SiteUrl $SiteUrl -Seeds $learningSeeds -ResolvedReviewers $reviewers
    $script:agents = Sync-CoEAgentCatalog -Connection $site -SiteUrl $SiteUrl -AgentSeeds $agentSeed -ResolvedReviewers $reviewers
    "stories + learning + agents synced"
}

Invoke-Check "R4b" "Reviewer group holds the reviewer role and Owners keep Full Control on every catalog" {
    $owners = (Get-PnPWeb -Includes AssociatedOwnerGroup -Connection $site).AssociatedOwnerGroup
    $group = Get-PnPGroup -Identity "CoE Catalog Reviewers" -Connection $site
    foreach ($name in "Copilot Success Stories", "Copilot Learning Paths", "Copilot Agent Showcase") {
        $list = Get-PnPList -Identity $name -Includes HasUniqueRoleAssignments,EnableModeration,DraftVersionVisibility,RoleAssignments -Connection $site
        $ctx = Get-PnPContext -Connection $site; $ctx.Load($list.RoleAssignments); Invoke-PnPQuery -Connection $site
        $held = @{}
        foreach ($ra in $list.RoleAssignments) {
            Get-PnPProperty -ClientObject $ra -Property Member,RoleDefinitionBindings -Connection $site | Out-Null
            $held[[int]$ra.Member.Id] = @($ra.RoleDefinitionBindings | ForEach-Object Name)
        }
        if (-not $list.HasUniqueRoleAssignments) { throw "$name still inherits permissions." }
        if ("CoE Catalog Reviewer" -notin @($held[[int]$group.Id])) { throw "${name}: reviewer group missing the reviewer role." }
        if ("Full Control" -notin @($held[[int]$owners.Id])) { throw "${name}: Owners lost Full Control." }
        if (-not $list.EnableModeration -or [string]$list.DraftVersionVisibility -ne "Approver") { throw "${name}: content approval/draft visibility wrong." }
    }
    "3 catalogs verified"
}

# A comparable snapshot of everything the catalog synchronizers own: rows (with modification time, version
# and approval state), views (with their query), fields, list permissions and reviewer group membership.
function Get-CoECatalogSnapshot {
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($name in "Copilot Success Stories", "Copilot Learning Paths", "Copilot Agent Showcase") {
        $list = Get-PnPList -Identity $name -Includes RoleAssignments,HasUniqueRoleAssignments,EnableModeration,DraftVersionVisibility -Connection $site
        $lines.Add("$name|unique=$($list.HasUniqueRoleAssignments)|moderation=$($list.EnableModeration)|drafts=$($list.DraftVersionVisibility)")
        foreach ($item in @(Get-PnPListItem -List $list.Id -PageSize 500 -Fields "Title","Modified","_UIVersionString","_ModerationStatus" -Connection $site)) {
            $lines.Add("$name|item|$($item.Id)|$($item['Title'])|$($item['Modified'])|$($item['_UIVersionString'])|$($item['_ModerationStatus'])")
        }
        foreach ($view in @(Get-PnPView -List $list.Id -Includes ViewQuery,DefaultView,RowLimit -Connection $site)) {
            $lines.Add("$name|view|$($view.Title)|default=$($view.DefaultView)|rows=$($view.RowLimit)|$($view.ViewQuery)")
        }
        foreach ($field in @(Get-PnPField -List $list.Id -Connection $site | Where-Object { -not $_.Hidden })) {
            $lines.Add("$name|field|$($field.InternalName)|$($field.TypeAsString)|$($field.DefaultValue)")
        }
        $ctx = Get-PnPContext -Connection $site; $ctx.Load($list.RoleAssignments); Invoke-PnPQuery -Connection $site
        foreach ($ra in $list.RoleAssignments) {
            Get-PnPProperty -ClientObject $ra -Property Member,RoleDefinitionBindings -Connection $site | Out-Null
            $lines.Add("$name|role|$($ra.Member.Id)|" + ((@($ra.RoleDefinitionBindings | ForEach-Object Name) | Sort-Object) -join ","))
        }
    }
    foreach ($member in @(Get-PnPGroupMember -Group "CoE Catalog Reviewers" -Connection $site)) { $lines.Add("reviewer|$($member.LoginName)") }
    return @($lines | Sort-Object)
}

Invoke-Check "R5" "Rerunning the catalog synchronizers changes no catalog state" {
    $before = @(Get-CoECatalogSnapshot)
    Sync-CoESuccessStoryCatalog -Connection $site -SiteUrl $SiteUrl -Seeds @($seed) -ResolvedReviewers $reviewers | Out-Null
    Sync-CoELearningCatalog -Connection $site -SiteUrl $SiteUrl -Seeds $learningSeeds -ResolvedReviewers $reviewers | Out-Null
    Sync-CoEAgentCatalog -Connection $site -SiteUrl $SiteUrl -AgentSeeds $agentSeed -ResolvedReviewers $reviewers | Out-Null
    $after = @(Get-CoECatalogSnapshot)
    $changes = @(Compare-Object -ReferenceObject $before -DifferenceObject $after)
    if ($changes.Count) {
        $sample = @($changes | Select-Object -First 5 | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join "; "
        throw "Rerun changed $($changes.Count) catalog state line(s): $sample"
    }
    "rerun left $($before.Count) catalog state lines unchanged"
}

Invoke-Check "R1" "A SharePoint-returned view address containing a space resolves" {
    if (-not $script:learning) { throw "Learning catalog was not created (see R4)." }
    $view = Get-PnPView -List "Copilot Learning Paths" -Identity "Learning steps" -Includes ServerRelativeUrl -Connection $site
    if ($view.ServerRelativeUrl -notmatch ' ') { throw "Expected a space in '$($view.ServerRelativeUrl)'." }
    $url = Resolve-CoESharePointReturnedUrl $view.ServerRelativeUrl "Learning reader view" $SiteUrl
    if ($url -notmatch '%20' -or $url -match ' ') { throw "Not encoded: $url" }
    $url
}

Invoke-Check "R2" "Column formatter, view formatter and default value apply and read back" {
    $list = Get-PnPList -Identity "Copilot Learning Paths" -Connection $site
    $field = Get-PnPField -List $list.Id -Identity "LearningPractice" -Connection $site
    if ([string]$field.CustomFormatter -notmatch '"txtContent":"Practice"') { throw "Column formatter not stored." }
    $view = Get-PnPView -List $list.Id -Identity "Learning steps" -Includes CustomFormatter -Connection $site
    if ([string]$view.CustomFormatter -notmatch 'rowFormatter') { throw "View formatter not stored." }
    $story = Get-PnPField -List "Copilot Success Stories" -Identity "StoryStatus" -Connection $site
    if ([string]$story.DefaultValue -ne "Submitted") { throw "StoryStatus default is '$($story.DefaultValue)'." }
    "formatters and default stored"
}

Invoke-Check "R3" "View CAML stored by SharePoint is accepted as equal to the one sent" {
    $view = Get-PnPView -List "Copilot Success Stories" -Identity "Published" -Includes ViewQuery -Connection $site
    if ($view.ViewQuery -notmatch ' />') { throw "SharePoint no longer reformats CAML; this check needs a rethink." }
    $sent = $view.ViewQuery -replace ' />', '/>'
    if (-not (Test-CoECatalogViewQueryEqual $view.ViewQuery $sent)) { throw "Equivalent CAML was reported as different." }
    if (Test-CoECatalogViewQueryEqual $view.ViewQuery ($sent -replace 'Retired', 'Rejected')) { throw "Different CAML was reported as equal." }
    "equivalent CAML accepted, different CAML rejected"
}

Invoke-Check "R6" "The live connection is accepted as the verified parent site" {
    $connected = [string](Get-CoEResourceProperty $site "Url")
    $web = Get-PnPWeb -Connection $site
    if (-not (Test-CoETabUrlEqual ([string]$web.Url).TrimEnd('/') $SiteUrl)) { throw "Web URL '$($web.Url)' does not match '$SiteUrl'." }
    "connection url='$connected' web url='$($web.Url)'"
}

Invoke-Check "R7" "Resume page list matches the template the installer actually generates" {
    $install = Get-Content -LiteralPath (Join-Path $kitRoot "02_Install-CopilotCoE.ps1") -Raw
    if ($install -match '"News-and-Updates\.aspx"') { throw "02_Install still requires News-and-Updates.aspx." }
    # Prepare rewrites the raw template (renames the Mechanics page, drops News-and-Updates), so test its output.
    # Work in a throwaway copy so this regression never dirties the kit it runs from.
    $work = Join-Path ([IO.Path]::GetTempPath()) ("coe-regression-" + [guid]::NewGuid().ToString("N"))
    $kitCopy = Join-Path $work "03_Build\CopilotCoE-Kit"
    try {
        New-Item -ItemType Directory -Force -Path $kitCopy, (Join-Path $work "03_Build\SourceOriginal\CopilotCoESite") | Out-Null
        # Copy only what Prepare reads; the kit folder itself can hold a large previously generated package.
        Copy-Item -LiteralPath (Join-Path $kitRoot "Internal") -Destination $kitCopy -Recurse -Force
        foreach ($name in "ResourceLinks.json", "SiteAssetManifest.json", "CoE-Revision-Content.json") {
            Copy-Item -LiteralPath (Join-Path $kitRoot $name) -Destination $kitCopy -Force -ErrorAction SilentlyContinue
        }
        $source = Join-Path (Split-Path -Parent $kitRoot) "SourceOriginal\CopilotCoESite"
        Copy-Item -Path (Join-Path $source "*") -Destination (Join-Path $work "03_Build\SourceOriginal\CopilotCoESite") -Recurse -Force
        & pwsh -NoProfile -File (Join-Path $kitCopy "Internal\Prepare-CopilotCoE.ps1") `
            -DisplayName "Regression" -OrgName "Regression Org" -ShortName "RG" -EnvironmentLabel "Test" `
            -SampleNotice "none" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Prepare-CopilotCoE.ps1 failed with exit code $LASTEXITCODE." }
        $generated = Join-Path $kitCopy "CopilotCoESite.pnp"
        if (-not (Test-Path -LiteralPath $generated)) { throw "Prepare did not generate CopilotCoESite.pnp." }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($generated)
        try {
            $names = @()
            foreach ($e in $zip.Entries | Where-Object FullName -like "Files/*.xml") {
                $r = [IO.StreamReader]::new($e.Open()); try { $t = $r.ReadToEnd() } finally { $r.Dispose() }
                if ($t -match '<pnp:SiteCollection\b') { $names = @([regex]::Matches($t, 'PageName="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) }
            }
        } finally { $zip.Dispose() }
    } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($required in "Adoption-Best-Practices.aspx", "Copilot-on-Microsoft-Mechanics.aspx", "Meet-your-Champions.aspx", "Technical Readiness.aspx", "TrainingHome.aspx") {
        if ($required -notin $names) { throw "Generated template is missing $required." }
    }
    if ("News-and-Updates.aspx" -in $names) { throw "Generated template still contains News-and-Updates.aspx." }
    "generated template has all required pages and no News-and-Updates"
}

$results | Format-Table Id, Check, Result, Detail -AutoSize -Wrap
$failed = @($results | Where-Object Result -ne "PASS").Count
Write-Host ("LIVE REGRESSION: {0} passed, {1} failed" -f ($results.Count - $failed), $failed)
if ($failed) { exit 1 }
