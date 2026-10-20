# Local-only validation for structured organization overrides. Dot-sourcing and calling this helper never connects
# to Microsoft 365. Entry scripts call it before importing PnP.PowerShell or opening a tenant connection.

function Assert-CoETrainingCalendarOverride {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $headerLine = [string](Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop)
    $headers = @(($headerLine.TrimStart([char]0xFEFF) -split ",") | ForEach-Object { $_.Trim().Trim('"') })
    $required = @("Title", "StartOffsetDays", "StartTimeET", "EndTimeET", "Audience", "Format",
        "Description", "SampleStatus", "RegistrationUrl")

    if ("StartDate" -in $headers -or "EndDate" -in $headers -or "StartOffsetDays" -notin $headers) {
        throw ("$Path uses the obsolete fixed-date Training-Calendar.csv schema. Before signing in or creating tenant resources, " +
            "replace StartDate/EndDate with StartOffsetDays (days from the run date); EndOffsetDays is optional and defaults to " +
            "StartOffsetDays. Use the current ContentPacks\\Government-StateLocal\\Content\\Training-Calendar.csv or " +
            "SeedContent\\Training-Calendar.csv as the column template.")
    }
    $missing = @($required | Where-Object { $_ -notin $headers })
    if ($missing.Count) { throw "$Path is missing required column(s): $($missing -join ', ')." }

    $rows = @(Import-Csv -LiteralPath $Path -ErrorAction Stop)
    $seen = @{}
    foreach ($row in $rows) {
        $title = ([string]$row.Title).Trim()
        if (-not $title) { throw "$Path has a row with no Title." }
        if ($seen.ContainsKey($title.ToLowerInvariant())) { throw "$Path has duplicate Title '$title'." }
        $seen[$title.ToLowerInvariant()] = $true

        $startOffset = 0
        if (-not [int]::TryParse(([string]$row.StartOffsetDays).Trim(), [ref]$startOffset) -or $startOffset -lt 0) {
            throw "$Path has invalid StartOffsetDays '$($row.StartOffsetDays)' for '$title'. Use a non-negative whole number."
        }
        $endOffset = $startOffset
        if ($row.PSObject.Properties["EndOffsetDays"] -and -not [string]::IsNullOrWhiteSpace([string]$row.EndOffsetDays)) {
            if (-not [int]::TryParse(([string]$row.EndOffsetDays).Trim(), [ref]$endOffset) -or $endOffset -lt $startOffset) {
                throw "$Path has invalid EndOffsetDays '$($row.EndOffsetDays)' for '$title'. It must be at least StartOffsetDays."
            }
        }

        $startTime = [datetime]::MinValue
        $endTime = [datetime]::MinValue
        if (-not [datetime]::TryParseExact(([string]$row.StartTimeET).Trim(), "HH:mm",
                [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$startTime)) {
            throw "$Path has invalid StartTimeET '$($row.StartTimeET)' for '$title'. Use HH:mm."
        }
        if (-not [datetime]::TryParseExact(([string]$row.EndTimeET).Trim(), "HH:mm",
                [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$endTime)) {
            throw "$Path has invalid EndTimeET '$($row.EndTimeET)' for '$title'. Use HH:mm."
        }
        if ($endOffset -eq $startOffset -and $endTime.TimeOfDay -le $startTime.TimeOfDay) {
            throw "$Path has an invalid same-day time range for '$title'."
        }
    }
}

function Assert-CoEStructuredOrganizationContent {
    [CmdletBinding()]
    param([string]$OrgPath)

    if ([string]::IsNullOrWhiteSpace($OrgPath)) { return }
    $calendar = Join-Path $OrgPath "Content\Training-Calendar.csv"
    Assert-CoETrainingCalendarOverride -Path $calendar
    if (Test-Path -LiteralPath $calendar -PathType Leaf) {
        Write-Host "Structured organization content preflight passed: $calendar"
    }
}
