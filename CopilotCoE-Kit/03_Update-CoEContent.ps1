#Requires -Version 7.4
<#
.SYNOPSIS
Re-publishes edited starter content to an existing CoE without rebuilding it.

.DESCRIPTION
STEP 3 OF 3 (repeat whenever content changes). Run after 02_Install-CopilotCoE.ps1.
Copy the kit file you want to change from SeedContent into <OrgPath>\Content at the same relative path
(for example Content\Sections\04-Service-Catalog-and-Support.md), edit that copy, then run one of:
    .\03_Update-CoEContent.ps1 -Scope Guides       # SeedContent\Guides\*.md, Copilot-FAQs.md, Give-Feedback.md,
                                                   # and CoE sections, Learning Paths and Agent Showcase catalogs
    .\03_Update-CoEContent.ps1 -Scope Governance   # SeedContent\Governance\*, the AI policy draft, Start here pages
    .\03_Update-CoEContent.ps1 -Scope All          # everything above, plus resources, champions, calendar, Top 10 tab

Settings are read from <OrgPath>\Deployment-Settings.json (or the kit's file when -OrgPath is omitted).
Pass the same -OrgPath you used with 02; organization Content overrides are applied and you are asked
before any new files in <OrgPath>\Assets are hosted (-AcceptOrgAssets answers yes for all). Pages the script manages are replaced with your edited
copy (a before-copy is saved in RevisionAudit). Governance files are replaced only with -ReplaceFiles.
Calendar events and champion rows are ADDED when new; rows already on the site are left as they are,
so edit or delete existing calendar and champion entries directly in SharePoint.
Learning rows are insert-only by LearningId; agent seeds preserve matching rows and publication status.
Both catalogs use native content approval. Existing access is preserved; named reviewers receive
Contribute plus ApproveItems rather than Edit. Drafts are visible to authors and approvers.
Legacy Published/Featured visibility is preserved on migration; pending revisions are not reapproved.
Both agent views are always embedded. Native approval is the only publication gate; Retired is
excluded from discovery and the review queue. There is no additional Published status step.
This does not change agent access, licenses, sharing, or billing.
Use -Scope All -EnsureResourceTabs to restore missing default resource tabs deliberately.
Without that switch, updates preserve a Top 10 tab that an organization intentionally removed.
Use -RepairCapturedPages to deliberately repair the kit's legacy Home, adoption, roles and
Microsoft Mechanics pages. Without it, captured pages and custom Home content are preserved.
Pass -MailNickname <alias> if the organization folder's Deployment-Settings.json still remembers an
earlier alias than the one actually installed (for example after a later 02_Install-CopilotCoE.ps1 run
used a new -MailNickname without updating the settings file) - otherwise this script computes its
target SiteUrl from whatever alias is on file, which can silently point at a retired site.
#>
[CmdletBinding()]
param(
    [ValidateSet("Guides", "Governance", "All")]
    [string]$Scope = "Guides",
    [string]$OrgPath,
    [string]$SettingsPath,
    [string]$OrgName,
    [string]$OrgNoun,
    [string]$ShortName,
    [string]$DisplayName,
    [string]$SampleNotice,
    [string]$MailNickname,
    [switch]$ReplaceFiles,
    [switch]$ReplaceOrgAssets,
    [switch]$AcceptOrgAssets,
    [switch]$EnsureResourceTabs,
    [switch]$RepairCapturedPages,
    [switch]$AllowMissingDataSafetyIncidentRoute,
    [ValidateSet("Customer", "Demo")][string]$ContentMode = "Customer"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Every run keeps a transcript; a terminating error below is caught here so the log is closed and reported.
. (Join-Path $PSScriptRoot "Internal\RunLog.ps1")
$script:CoERunLog = Start-CoERunLog -KitRoot $PSScriptRoot -Script "03_Update-CoEContent" -OrgPath $OrgPath
trap {
    Write-Host ("[{0}] STOPPED: {1}" -f (Get-Date).ToString("HH:mm:ss"), $_.Exception.Message) -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    Stop-CoERunLog -Log $script:CoERunLog -Succeeded $false
    break
}
if ($EnsureResourceTabs -and $Scope -ne "All") {
    throw "-EnsureResourceTabs requires -Scope All."
}
if ($RepairCapturedPages -and $Scope -eq "Governance") {
    throw "-RepairCapturedPages requires -Scope Guides or -Scope All."
}
if ($OrgPath) {
    if (-not (Test-Path -LiteralPath $OrgPath -PathType Container)) { throw "Organization folder not found: $OrgPath" }
    $OrgPath = (Resolve-Path -LiteralPath $OrgPath).Path
    if (-not $SettingsPath) { $SettingsPath = Join-Path $OrgPath "Deployment-Settings.json" }
}
if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot "Deployment-Settings.json" }
if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) { throw "Settings file not found: $SettingsPath" }
$s = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
# -MailNickname lets this script target a DIFFERENT alias than whatever the settings file remembers - the
# same CLI-overrides-settings-file precedence 02_Install-CopilotCoE.ps1 already has for this exact field.
# Confirmed missing live: an organization folder reused across several installs under different aliases
# (02_Install-CopilotCoE.ps1 -MailNickname <newAlias> each time, which never writes that value back into
# Deployment-Settings.json) left this script computing SiteUrl from the FIRST alias ever used, long after
# later installs moved on to new ones - producing a generic SharePoint 404 deep inside catalog preflight,
# not a clear "wrong site" error, because the URL itself was syntactically valid, just for a retired site.
if ($PSBoundParameters.ContainsKey("MailNickname")) { $s | Add-Member -NotePropertyName MailNickname -NotePropertyValue $MailNickname -Force }
. (Join-Path $PSScriptRoot "Internal\OrganizationProfile.ps1")
$null = Get-CoELearningEnvironment -Settings $s
$profileOverrides = @{}
foreach ($name in @("OrgName", "OrgNoun", "ShortName", "DisplayName", "SampleNotice")) {
    if ($PSBoundParameters.ContainsKey($name)) { $profileOverrides[$name] = $PSBoundParameters[$name] }
}
$organizationProfile = Get-CoEOrganizationProfile -Settings $s -Overrides $profileOverrides
foreach ($name in @("Tenant", "AdminFQDN", "SiteFQDN", "PnPClientID", "MailNickname", "SupportEmail")) {
    if (-not $s.PSObject.Properties[$name] -or $s.$name -isnot [string] -or
        [string]::IsNullOrWhiteSpace($s.$name) -or $s.$name -match "[<>]|\{\{|\}\}") {
        throw "Set $name in $SettingsPath before updating content."
    }
}
foreach ($name in @("AdminFQDN", "SiteFQDN")) {
    $s.$name = ([string]$s.$name).Trim() -replace "^https?://", "" -replace "/.*$", ""
}
if ($s.Tenant -notmatch "^[A-Za-z0-9-]+\.onmicrosoft\.com$") { throw "Tenant must look like yourtenant.onmicrosoft.com." }
if ($s.AdminFQDN -notmatch "^[A-Za-z0-9-]+-admin\.sharepoint\.com$") { throw "AdminFQDN must be the SharePoint admin host." }
if ($s.SiteFQDN -notmatch "^[A-Za-z0-9-]+\.sharepoint\.com$") { throw "SiteFQDN must be the SharePoint tenant host." }
if ($s.PnPClientID -notmatch "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$") { throw "PnPClientID must be the app's Application (client) ID GUID." }
if ($s.MailNickname -notmatch "^[A-Za-z0-9_-]{1,64}$") { throw "MailNickname may use letters, numbers, hyphen, and underscore only." }
if ($s.SupportEmail -notmatch "^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$") { throw "SupportEmail must be an email address." }

$completeArgs = @{
    AdminUrl            = "https://$($s.AdminFQDN)"
    SiteUrl             = "https://$($s.SiteFQDN)/sites/$($s.MailNickname)"
    ClientId            = $s.PnPClientID
    Tenant              = $s.Tenant
    TeamAlias           = $s.MailNickname
    ReplaceManagedPages = $true
    ReplaceManagedFiles = [bool]$ReplaceFiles
    ReplaceOrgAssets    = [bool]$ReplaceOrgAssets
    SampleNotice        = $(if ($organizationProfile.SampleNotice -eq "") { "none" } else { $organizationProfile.SampleNotice })
    ShortName           = $organizationProfile.ShortName
    OrgName             = $organizationProfile.OrgName
    OrgNoun             = $organizationProfile.OrgNoun
    DisplayName         = $organizationProfile.DisplayName
    SupportEmail        = [string]$s.SupportEmail
    SettingsPath        = $SettingsPath
    AcceptOrgAssets     = [bool]$AcceptOrgAssets
    EnsureResourceTabs  = [bool]$EnsureResourceTabs
    AllowMissingDataSafetyIncidentRoute = [bool]$AllowMissingDataSafetyIncidentRoute
    ContentMode         = $ContentMode
}
if ($OrgPath) { $completeArgs.OrgPath = $OrgPath }
if ($RepairCapturedPages) { $completeArgs.RepairCapturedPages = $true }
if ($Scope -eq "Guides") { $completeArgs.GuidesOnly = $true }
if ($Scope -eq "Governance") { $completeArgs.GovernanceOnly = $true }

Write-Host "Publishing content update ($Scope). A live security posture report follows."
& (Join-Path $PSScriptRoot "Internal\Complete-CopilotCoE.ps1") @completeArgs
Stop-CoERunLog -Log $script:CoERunLog -Succeeded $true