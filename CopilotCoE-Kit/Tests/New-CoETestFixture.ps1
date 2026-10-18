function Get-CoETestExceptionMessage {
    param([Parameter(Mandatory)][scriptblock]$Action)

    # Execute in the test's call stack, before Pester 3 crosses its module boundary.
    try {
        & $Action | Out-Null
    } catch {
        return $_.Exception.Message
    }
    throw "Expected the test action to throw, but it completed successfully."
}

function New-CoEPreparedTestFixture {
    param(
        [Parameter(Mandatory)][string]$KitRoot,
        [Parameter(Mandatory)][string]$FixtureRoot
    )
    if (Test-Path -LiteralPath $FixtureRoot) { throw "Test fixture already exists: $FixtureRoot" }
    $build = Join-Path $FixtureRoot "03_Build"
    $kit = Join-Path $build "CopilotCoE-Kit"
    [void][IO.Directory]::CreateDirectory((Join-Path $kit "Internal"))
    [void][IO.Directory]::CreateDirectory((Join-Path $build "SourceOriginal"))
    foreach ($name in @("Prepare-CopilotCoE.ps1", "OrganizationProfile.ps1", "AdoptionCatalogs.ps1", "HubExperience.ps1")) {
        Copy-Item -LiteralPath (Join-Path $KitRoot "Internal\$name") -Destination (Join-Path $kit "Internal\$name") -ErrorAction Stop
    }
    Copy-Item -LiteralPath (Join-Path $KitRoot "ResourceLinks.json") -Destination $kit -ErrorAction Stop
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $KitRoot) "SourceOriginal\CopilotCoESite") `
        -Destination (Join-Path $build "SourceOriginal\CopilotCoESite") -Recurse -ErrorAction Stop
    $output = & pwsh -NoProfile -File (Join-Path $kit "Internal\Prepare-CopilotCoE.ps1") `
        -OrgName "Offline Organization" -SampleNotice "none" 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
    return $kit
}
