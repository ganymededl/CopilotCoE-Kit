function Get-CoEOrganizationProfile {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Settings,
        [hashtable]$Overrides = @{}
    )

    $values = @{}
    foreach ($name in @("OrgName", "OrgNoun", "ShortName", "DisplayName", "SampleNotice")) {
        $value = $null
        if ($Overrides.ContainsKey($name)) {
            $value = $Overrides[$name]
        } elseif ($Settings -is [System.Collections.IDictionary] -and $Settings.Contains($name)) {
            $value = $Settings[$name]
        } elseif ($null -ne $Settings -and $Settings.PSObject.Properties[$name]) {
            $value = $Settings.$name
        }

        if ($null -ne $value -and $value -isnot [string]) {
            throw "$name must be a text value in Deployment-Settings.json or on the command line."
        }
        $values[$name] = if ($null -eq $value) { "" } else { $value }
        if ($values[$name] -match '<[^<>]+>|\{\{|\}\}' -or $values[$name] -match '[\x00-\x08\x0b\x0c\x0e-\x1f]') {
            throw "$name contains a placeholder, unresolved token, or invalid control character. Configure it before signing in."
        }
        if ($name -ne "SampleNotice" -and $values[$name] -match '[\r\n\t]') {
            throw "$name must be a single-line text value."
        }
    }

    if ([string]::IsNullOrWhiteSpace($values.OrgName)) { $values.OrgName = $values.DisplayName }
    if ([string]::IsNullOrWhiteSpace($values.OrgName)) {
        throw "Set OrgName (or DisplayName when OrgName is omitted) before signing in."
    }
    if ([string]::IsNullOrWhiteSpace($values.OrgNoun)) { $values.OrgNoun = "organization" }
    if ($values.OrgNoun.Trim() -ieq "Test tenant") {
        throw "OrgNoun must describe the organization in reader-facing sentences; use a value such as 'university' or leave it blank for 'organization'."
    }
    if ([string]::IsNullOrWhiteSpace($values.DisplayName)) { $values.DisplayName = "$($values.OrgName) Copilot CoE" }
    if ($values.DisplayName.Length -gt 256) { throw "DisplayName must be 256 characters or fewer." }
    if ([string]::IsNullOrWhiteSpace($values.ShortName)) {
        $values.ShortName = -join @($values.OrgName -split "\s+" |
            Where-Object { $_ -match "^[A-Za-z]" -and $_ -notin @("of", "the", "and", "for") } |
            ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() })
        if ([string]::IsNullOrWhiteSpace($values.ShortName)) { $values.ShortName = "CoE" }
    }
    if ([string]::IsNullOrWhiteSpace($values.SampleNotice)) {
        $values.SampleNotice = "Sample starter content for review by $($values.OrgName); not official policy or a production commitment."
    } elseif ($values.SampleNotice.Trim() -eq "none") {
        $values.SampleNotice = ""
    }

    return [pscustomobject][ordered]@{
        OrgName = $values.OrgName
        OrgNoun = $values.OrgNoun
        ShortName = $values.ShortName
        DisplayName = $values.DisplayName
        SampleNotice = $values.SampleNotice
    }
}

function Get-CoELearningEnvironment {
    param([AllowNull()][object]$Settings)

    $value = $null
    if ($Settings -is [System.Collections.IDictionary] -and $Settings.Contains("LearningEnvironment")) {
        $value = $Settings["LearningEnvironment"]
    } elseif ($null -ne $Settings -and $Settings.PSObject.Properties["LearningEnvironment"]) {
        $value = $Settings.LearningEnvironment
    }
    if ($value -isnot [string] -or $value -cnotin @("Government", "HigherEducation")) {
        throw "Set LearningEnvironment to Government or HigherEducation in Deployment-Settings.json before installing or publishing."
    }
    return $value
}

function Copy-CoEContentOverlay {
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)][string]$KitSeedRoot
    )

    $overrides = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $ContentRoot -File -Recurse | Where-Object {
        $_.Name -notlike "README*" -or
        (Test-Path -LiteralPath (Join-Path $KitSeedRoot $_.FullName.Substring($ContentRoot.Length).TrimStart("\")) -PathType Leaf)
    })) {
        $relative = $file.FullName.Substring($ContentRoot.Length).TrimStart("\")
        $target = if ($relative -in @("CoE-Revision-Content.json", "ResourceLinks.json")) {
            Join-Path $StageRoot $relative
        } else {
            Join-Path (Join-Path $StageRoot "SeedContent") $relative
        }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        $overrides += $relative
    }
    return $overrides
}
