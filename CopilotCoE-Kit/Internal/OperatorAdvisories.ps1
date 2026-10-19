function New-CoEAdvisoryContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SettingsPath,
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][string]$SiteFQDN,
        [Parameter(Mandatory)][string]$TeamAlias
    )
    $settingsFile = (Resolve-Path -LiteralPath $SettingsPath -ErrorAction Stop).ProviderPath
    [pscustomobject]@{
        Path = Join-Path (Split-Path -Parent $settingsFile) "CoE-Advisory-Decisions.json"
        Tenant = $Tenant.Trim().ToLowerInvariant()
        SiteFQDN = $SiteFQDN.Trim().ToLowerInvariant()
        TeamAlias = $TeamAlias.Trim().ToLowerInvariant()
    }
}

function Get-CoEAdvisoryKey {
    param([object]$Context, [string]$Id, [string[]]$Facts)
    $scope = [ordered]@{
        Tenant = $Context.Tenant; SiteFQDN = $Context.SiteFQDN; TeamAlias = $Context.TeamAlias
        Id = $Id; Facts = @($Facts | Sort-Object -Unique)
    } | ConvertTo-Json -Depth 5 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($scope))).Replace("-", "") }
    finally { $sha.Dispose() }
    [pscustomobject]@{ Fingerprint = $fingerprint; Scope = $scope | ConvertFrom-Json }
}

function Read-CoEAdvisoryDecisions {
    param([object]$Context)
    if (-not (Test-Path -LiteralPath $Context.Path -PathType Leaf)) { return @() }
    $saved = Get-Content -LiteralPath $Context.Path -Raw -ErrorAction Stop | ConvertFrom-Json
    if (-not $saved.PSObject.Properties["SchemaVersion"] -or $saved.SchemaVersion -ne 1 -or
        -not $saved.PSObject.Properties["Decisions"] -or $saved.Decisions -isnot [array]) {
        throw "Invalid advisory decision file: $($Context.Path). Review it before continuing."
    }
    foreach ($decision in $saved.Decisions) {
        if (-not $decision -or -not $decision.PSObject.Properties["Fingerprint"] -or
            $decision.Fingerprint -notmatch '^[0-9A-F]{64}$' -or
            -not $decision.PSObject.Properties["Choice"] -or $decision.Choice -cnotin @("STOP", "PROCEED") -or
            -not $decision.PSObject.Properties["Id"]) {
            throw "Invalid advisory decision in $($Context.Path). Review it before continuing."
        }
        $decision
    }
}

function Test-CoELabSupportMailbox {
    param([string]$SupportEmail, [string]$Tenant)
    if ($SupportEmail -notmatch '^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$') {
        throw "SupportEmail must be an email address before publishing content."
    }
    $domain = ($SupportEmail -split "@")[-1]
    $localPart = ($SupportEmail -split "@")[0]
    return ($domain -match '\.onmicrosoft\.com$' -and ($localPart -ieq "admin" -or $domain -ieq $Tenant))
}

function Get-CoELabSupportMailboxReview {
    param([object]$Context, [string]$SupportEmail)
    $labLooking = Test-CoELabSupportMailbox -SupportEmail $SupportEmail -Tenant $Context.Tenant
    $savedProceed = $false
    foreach ($decision in @(Read-CoEAdvisoryDecisions -Context $Context)) {
        if ($decision.Id -ne "LabSupportMailbox" -or $decision.Choice -ne "PROCEED") { continue }
        if (-not $decision.PSObject.Properties["Scope"] -or -not $decision.Scope) {
            throw "LabSupportMailbox decision has no target scope in $($Context.Path)."
        }
        foreach ($name in @("Tenant", "SiteFQDN", "TeamAlias", "Id", "Facts")) {
            if (-not $decision.Scope.PSObject.Properties[$name]) {
                throw "LabSupportMailbox decision is missing scope $name in $($Context.Path)."
            }
        }
        $scope = $decision.Scope
        if ($scope.Id -cne "LabSupportMailbox" -or $scope.Facts -isnot [array] -or $scope.Facts.Count -ne 1 -or
            $scope.Facts[0] -isnot [string]) {
            throw "Invalid LabSupportMailbox scope in $($Context.Path)."
        }
        foreach ($name in @("Tenant", "SiteFQDN", "TeamAlias")) {
            if ($scope.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($scope.$name)) {
                throw "Invalid LabSupportMailbox target in $($Context.Path)."
            }
        }
        $key = Get-CoEAdvisoryKey -Context $scope -Id LabSupportMailbox -Facts $scope.Facts
        if ($key.Fingerprint -cne $decision.Fingerprint) {
            throw "LabSupportMailbox scope does not match its fingerprint in $($Context.Path)."
        }
        if ($scope.Tenant -ieq $Context.Tenant -and $scope.SiteFQDN -ieq $Context.SiteFQDN -and
            $scope.TeamAlias -ieq $Context.TeamAlias) {
            $savedProceed = $true
        }
    }
    [pscustomobject]@{
        LabLooking = $labLooking
        SavedProceed = $savedProceed
        RequiresReview = ($labLooking -or $savedProceed)
    }
}

function Confirm-CoEAdvisory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][ValidateSet("LabSupportMailbox", "UnconfiguredSupportRoutes",
            "DefaultSampleNotice", "LongDisplayName", "ParentTeamExternalMembers", "HeaderLayout")]
        [string]$Id,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string[]]$Facts,
        [ValidateSet("Info", "Warn")][string]$Level = "Warn"
    )
    $description = "ADVISORY [$Id]: $Message"
    if ($Level -eq "Info") { Write-Host $description } else { Write-Warning $description }
    if ($WhatIfPreference) {
        Write-Host "WhatIf: Stop/Proceed decision would be requested; no decision was recorded."
        return
    }
    $key = Get-CoEAdvisoryKey -Context $Context -Id $Id -Facts $Facts
    $fingerprint = $key.Fingerprint
    $decisions = @(Read-CoEAdvisoryDecisions -Context $Context)
    $matches = @($decisions | Where-Object Fingerprint -eq $fingerprint)
    if ($matches.Count -gt 1) { throw "Duplicate advisory decisions in $($Context.Path)." }
    if ($matches.Count -eq 1) {
        $choice = $matches[0].Choice
        Write-Host "Using saved $choice for $Id. Decision file: $($Context.Path)"
    } else {
        $choice = (Read-Host "STOP ends this run; PROCEED accepts only this advisory. Type STOP or PROCEED [STOP]").Trim().ToUpperInvariant()
        if (-not $choice) { $choice = "STOP" }
        if ($choice -notin @("STOP", "PROCEED")) { throw "No valid Stop/Proceed choice was recorded for $Id. Stopped." }
        $decisions += [pscustomobject]@{
            Id = $Id; Fingerprint = $fingerprint; Choice = $choice
            RecordedAtUtc = [datetime]::UtcNow.ToString("o")
            Scope = $key.Scope
        }
        @{ SchemaVersion = 1; Decisions = @($decisions) } | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $Context.Path -Encoding utf8 -ErrorAction Stop
    }
    if ($choice -ne "PROCEED") {
        throw "Operator selected STOP for $Id. Correct the configuration or remove its saved decision from $($Context.Path) to choose again."
    }
}

function Invoke-CoEConfigurationAdvisories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [AllowNull()][object]$Settings,
        [Parameter(Mandatory)][string]$SupportEmail,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SampleNotice,
        [ValidateSet("Customer", "Demo")][string]$ContentMode = "Customer",
        [switch]$AllowMissingDataSafetyIncidentRoute
    )
    if ($SupportEmail -notmatch '^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$') {
        throw "SupportEmail must be an email address before publishing content."
    }
    $links = Get-CoECatalogValue $Settings "Links"
    $routes = @(Get-CoESupportRoutes $links "https://$($Context.SiteFQDN)/sites/$($Context.TeamAlias)")
    $missing = @($routes | Where-Object {
        -not $_.Configured -and -not ($AllowMissingDataSafetyIncidentRoute -and $_.Key -eq "DataSafetyIncident")
    } | ForEach-Object Key)
    if ($ContentMode -eq "Customer" -and (Test-CoELabSupportMailbox -SupportEmail $SupportEmail -Tenant $Context.Tenant)) {
        Confirm-CoEAdvisory -Context $Context -Id LabSupportMailbox -Facts @($SupportEmail.ToLowerInvariant()) `
            -Message "SupportEmail '$SupportEmail' looks like a lab/demo mailbox, not a confirmed organizational support route. PROCEED keeps this address; it does not verify delivery or monitoring. Replace it before production." -Level Info
    }
    if ($missing.Count) {
        Confirm-CoEAdvisory -Context $Context -Id UnconfiguredSupportRoutes -Facts $missing `
            -Message "Unconfigured support routes: $($missing -join ', '). PROCEED publishes explicit 'route not configured' notices, not working endpoints. Configure approved routes before production." -Level Info
    }
    if ($ContentMode -eq "Demo" -and $SampleNotice.StartsWith("Sample starter content for review by ")) {
        Confirm-CoEAdvisory -Context $Context -Id DefaultSampleNotice -Facts @($SampleNotice) `
            -Message "Demo mode uses the default sample notice. PROCEED keeps the visible disclaimer; this is not official organizational policy." -Level Info
    }
    if ($DisplayName.Length -gt 30) {
        Confirm-CoEAdvisory -Context $Context -Id LongDisplayName -Facts @($DisplayName) `
            -Message "The title '$DisplayName' is $($DisplayName.Length) characters and may crowd navigation. PROCEED still requires a 1366px screenshot before acceptance."
    }
}
