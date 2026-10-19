function Get-CoEChannelMemberEmail([object]$Member) {
    foreach ($property in @("Email", "UserPrincipalName")) {
        if ($Member.PSObject.Properties[$property] -and
            -not [string]::IsNullOrWhiteSpace([string]$Member.$property)) {
            return ([string]$Member.$property).Trim().ToLowerInvariant()
        }
    }
    return ""
}

function Test-CoEProperty([object]$Object, [string]$Name) {
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-CoEProperty([object]$Object, [string]$Name) {
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Assert-CoEMemberIdentity([object]$Identity, [string]$Address) {
    $userType = [string](Get-CoEProperty $Identity "userType")
    if ([string]::IsNullOrWhiteSpace($userType)) {
        throw "Microsoft Graph did not return userType for '$Address'; Member/Guest status could not be verified. Confirm delegated Microsoft Graph User.Read.All has admin consent, then run the installer with -ForceAuthentication for a fresh interactive sign-in. User.ReadBasic.All cannot read userType. This response does not prove the account is a guest."
    }
    if ($userType -ne "Member") {
        throw "'$Address' is not a Member account in the target tenant (userType: '$userType'). Guest and external identities are not allowed for governance."
    }
    if ([string](Get-CoEProperty $Identity "id") -notmatch "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$") {
        throw "Microsoft Graph did not return a valid immutable user ID for '$Address'."
    }
}

function Get-CoEGraphCollection(
    [string]$Url,
    [string]$GraphPathPrefix,
    [object]$Connection,
    [string]$Description
) {
    $results = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $nextPage = $Url

    for ($pageNumber = 1; $pageNumber -le 1000; $pageNumber++) {
        if (-not $seen.Add($nextPage)) {
            throw "Microsoft Graph repeated a page while reading $Description."
        }
        $page = Invoke-PnPGraphMethod -Url $nextPage -Method Get -Connection $Connection -ErrorAction Stop
        if (-not (Test-CoEProperty $page "value")) {
            throw "Microsoft Graph returned an incomplete collection while reading $Description."
        }
        foreach ($entry in @(Get-CoEProperty $page "value")) {
            if ($null -eq $entry) { throw "Microsoft Graph returned an empty member while reading $Description." }
            $results.Add($entry)
        }

        $nextLink = if (Test-CoEProperty $page "@odata.nextLink") {
            [string](Get-CoEProperty $page "@odata.nextLink")
        } else { "" }
        if ([string]::IsNullOrWhiteSpace($nextLink)) { return $results.ToArray() }

        $nextUri = $null
        if (-not [uri]::TryCreate($nextLink, [UriKind]::Absolute, [ref]$nextUri) -or
            $nextUri.Scheme -ne "https" -or
            $nextUri.Host -ne "graph.microsoft.com" -or
            -not $nextUri.AbsolutePath.StartsWith($GraphPathPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Microsoft Graph returned an unexpected continuation URL while reading $Description."
        }
        $nextPage = $nextUri.AbsoluteUri
    }
    throw "Microsoft Graph exceeded the page limit while reading $Description."
}

function Get-CoEHostTeamIdentity([string]$TeamId, [object]$Connection) {
    $tenantId = [string](Get-PnPTenantId -Connection $Connection -ErrorAction Stop)
    if ($tenantId -notmatch "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$") {
        throw "The SharePoint connection did not return a valid tenant ID."
    }
    $token = Get-PnPAccessToken -ResourceTypeName Graph -Decoded -Connection $Connection -ErrorAction Stop
    $tenantClaims = @($token.Claims | Where-Object Type -eq "tid")
    if ($tenantClaims.Count -ne 1 -or [string]$tenantClaims[0].Value -ne $tenantId) {
        throw "The Microsoft Graph connection tenant does not match the SharePoint host tenant."
    }
    $group = Invoke-PnPGraphMethod -Url "v1.0/groups/${TeamId}?`$select=id" -Method Get -Connection $Connection -ErrorAction Stop
    if ([string](Get-CoEProperty $group "id") -ne $TeamId) {
        throw "The host Team group ID could not be verified in the connected tenant."
    }
    [pscustomobject]@{ TeamId = $TeamId; TenantId = $tenantId }
}

function Get-CoEVerifiedGovernanceAccess(
    [string]$TeamId,
    [object]$Channel,
    [object[]]$AllowedIdentities,
    [string]$OwnerUserId,
    [object]$Connection
) {
    $hostIdentity = Get-CoEHostTeamIdentity -TeamId $TeamId -Connection $Connection
    $channelId = [uri]::EscapeDataString([string]$Channel.Id)
    $channelPath = "/v1.0/teams/$TeamId/channels/$channelId"
    $sharedTeams = @(Get-CoEGraphCollection `
        -Url "v1.0/teams/$TeamId/channels/$channelId/sharedWithTeams?`$select=id,tenantId,displayName,isHostTeam" `
        -GraphPathPrefix "$channelPath/sharedWithTeams" `
        -Connection $Connection `
        -Description "shared-Team relationships for '$($Channel.DisplayName)'")
    $members = @(Get-CoEGraphCollection `
        -Url "v1.0/teams/$TeamId/channels/$channelId/allMembers" `
        -GraphPathPrefix "$channelPath/allMembers" `
        -Connection $Connection `
        -Description "effective members for '$($Channel.DisplayName)'")

    $failures = [System.Collections.Generic.List[string]]::new()
    $hostTeams = @($sharedTeams | Where-Object { [string]$_.isHostTeam -ieq "true" })
    $hostTenantId = $hostIdentity.TenantId
    # A channel with no Team-sharing relationships can legitimately return an empty list.
    if ($hostTeams.Count -gt 1 -or
        ($hostTeams.Count -eq 1 -and [string]$hostTeams[0].id -ne $hostIdentity.TeamId)) {
        $failures.Add("The host Team identity could not be verified.")
    }
    if ($hostTeams.Count -eq 1 -and [string]$hostTeams[0].tenantId -ne $hostTenantId) {
        $failures.Add("The returned host Team tenant ID does not match the connected host tenant.")
    }

    $recipientTeams = @($sharedTeams | Where-Object { [string]$_.isHostTeam -ine "true" })
    foreach ($sharedTeam in $recipientTeams) {
        $failures.Add("The channel is shared with another Team: '$($sharedTeam.displayName)' [$($sharedTeam.id)] in tenant '$($sharedTeam.tenantId)'.")
    }

    $allowedById = @{}
    foreach ($identity in $AllowedIdentities) {
        $allowedById[[string]$identity.UserId] = $identity
    }
    $memberById = @{}
    foreach ($member in $members) {
        $userId = [string](Get-CoEProperty $member "userId")
        $tenantId = [string](Get-CoEProperty $member "tenantId")
        $email = Get-CoEChannelMemberEmail $member
        $label = if ($email) { $email } else { [string](Get-CoEProperty $member "displayName") }

        if ($userId -notmatch "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$") {
            $failures.Add("A channel member has no verifiable Entra user ID: '$label'.")
            continue
        }
        if ($memberById.ContainsKey($userId)) {
            $failures.Add("The effective roster returned duplicate identity '$label' [$userId].")
            continue
        }
        $memberById[$userId] = $member

        if (-not $tenantId -or -not $hostTenantId -or $tenantId -ne $hostTenantId) {
            $failures.Add("The channel member '$label' is not verified in the host tenant (tenant ID: '$tenantId').")
        }
        if (-not $allowedById.ContainsKey($userId)) {
            $failures.Add("The channel includes a user outside the approved identity allowlist: '$label' [$userId].")
        }

        $source = [string](Get-CoEProperty $member "@microsoft.graph.originalSourceMembershipUrl")
        if ($source) {
            $sourceUri = $null
            if (-not [uri]::TryCreate($source, [UriKind]::Absolute, [ref]$sourceUri) -or
                $sourceUri.Scheme -ne "https" -or $sourceUri.Host -ne "graph.microsoft.com") {
                $failures.Add("The source of channel access for '$label' could not be verified.")
            } else {
                $sourcePath = [uri]::UnescapeDataString($sourceUri.AbsolutePath)
                $directMembershipPath = "/teams/$TeamId/channels/$([uri]::UnescapeDataString([string]$Channel.Id))/members/"
                if (-not $sourcePath.Contains($directMembershipPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $failures.Add("The channel member '$label' inherits access from another Team or source.")
                }
            }
        }
    }

    if (-not $memberById.ContainsKey($OwnerUserId)) {
        $failures.Add("The configured governance owner is not present in the effective channel roster.")
    }

    [pscustomobject]@{
        Channel            = [string]$Channel.DisplayName
        ChannelId          = [string]$Channel.Id
        Members            = $members
        MemberCount        = $members.Count
        HostTenantId       = $hostTenantId
        SharedWithTeams    = $recipientTeams
        SharedTeamCount    = $recipientTeams.Count
        Failures           = $failures.ToArray()
        Passed             = ($failures.Count -eq 0)
    }
}

function Get-CoEParentSharingCapability([object]$Settings) {
    $mode = "Disabled"
    if (Test-CoEProperty $Settings "CoESiteSharingCapability") {
        $mode = [string](Get-CoEProperty $Settings "CoESiteSharingCapability")
    }
    if ($mode -notin @("Disabled", "ExistingExternalUserSharingOnly", "ExternalUserSharingOnly")) {
        throw "CoESiteSharingCapability must be Disabled, ExistingExternalUserSharingOnly (existing guests), or ExternalUserSharingOnly (new and existing guests). Anonymous sharing is not supported."
    }
    return $mode
}

function Set-CoENonOwnerSharingDisabled([string]$SiteUrl, [object]$Connection) {
    $context = Get-PnPContext -Connection $Connection -ErrorAction Stop
    $tenant = [Microsoft.Online.SharePoint.TenantManagement.Office365Tenant]::new($context)
    # PnP 3.2.0 queues this operation without executing it; submit on the explicit context.
    $tenant.DisableSharingForNonOwnersOfSite($SiteUrl)
    Invoke-PnPQuery -Connection $Connection -ErrorAction Stop
}

function Set-CoESiteSharing(
    [string]$SiteUrl,
    [ValidateSet("Disabled", "ExistingExternalUserSharingOnly", "ExternalUserSharingOnly")]
    [string]$SharingCapability,
    [object]$Connection
) {
    $site = Get-PnPTenantSite -Identity $SiteUrl -Detailed -DisableSharingForNonOwnersStatus -Connection $Connection -ErrorAction Stop
    if ([string]$site.SharingCapability -ne $SharingCapability) {
        Write-Host "Applying site sharing '$SharingCapability' (owners only): $SiteUrl"
        Set-PnPTenantSite -Identity $SiteUrl -SharingCapability $SharingCapability -Connection $Connection -Wait -ErrorAction Stop
    }
    if (-not $site.DisableSharingForNonOwnersStatus) {
        Write-Host "Disabling non-owner sharing: $SiteUrl"
        Set-CoENonOwnerSharingDisabled -SiteUrl $SiteUrl -Connection $Connection
    }
    $site = Get-PnPTenantSite -Identity $SiteUrl -Detailed -DisableSharingForNonOwnersStatus -Connection $Connection -ErrorAction Stop
    if ([string]$site.SharingCapability -ne $SharingCapability) {
        throw "Site sharing for '$SiteUrl' is '$($site.SharingCapability)', not '$SharingCapability'. Review tenant/site restrictions with your administrator; this script does not relax tenant policies. No CoE content should be published."
    }
    if (-not $site.DisableSharingForNonOwnersStatus) {
        throw "Non-owner sharing is not disabled for '$SiteUrl'. No CoE content should be published."
    }
    return $site
}

function Get-CoEOrganizationDomains([string[]]$Domains) {
    $normalized = @($Domains | Where-Object { $_ } |
        ForEach-Object { ([string]$_).Trim().TrimStart("@").ToLowerInvariant() } |
        Select-Object -Unique)
    if ($normalized.Count -eq 0 -or @($normalized | Where-Object { $_ -notmatch "^[a-z0-9.-]+\.[a-z]{2,}$" }).Count -gt 0) {
        throw "OrganizationEmailDomains must contain valid, approved organization domains before the CoE can publish content."
    }
    return $normalized
}

function Get-CoETeamRoster(
    [string]$TeamId,
    [object[]]$Channels,
    [string[]]$OrganizationEmailDomains,
    [object]$Connection
) {
    $domains = @(Get-CoEOrganizationDomains -Domains $OrganizationEmailDomains)
    $general = @($Channels | Where-Object DisplayName -eq "General")
    if ($general.Count -ne 1) { throw "Expected exactly one General channel to verify the parent Team roster." }
    $members = @(Get-PnPTeamsChannelUser -Team $TeamId -Channel $general[0].Id -Connection $Connection -ErrorAction Stop)
    $unverified = @($members | Where-Object { -not (Get-CoEChannelMemberEmail $_) })
    $external = @($members | Where-Object {
        $email = Get-CoEChannelMemberEmail $_
        $email -match "#EXT#" -or
            ($email -match "@([^@]+)$" -and $Matches[1].ToLowerInvariant() -notin $domains)
    })
    [pscustomobject]@{
        Members     = $members
        Count       = $members.Count
        Unverified  = $unverified
        External    = $external
        Passed      = ($unverified.Count -eq 0)
    }
}

function Get-CoEChannelFilesFolder(
    [string]$TeamId,
    [object]$Channel,
    [object]$Connection
) {
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $folder = $null
        try {
            $folder = Get-PnPTeamsChannelFilesFolder -Team $TeamId -Channel $Channel.Id -Connection $Connection -ErrorAction Stop
        } catch {
            $message = $_.Exception.Message
            if ($message -match '401|403|Unauthorized|Forbidden|Access.?Denied|insufficient.*privilege|invalid.?token|authentication' -or
                $message -notmatch 'Timeout|canceled|cancelled|429|TooManyRequests|502|503|504|temporarily|ServiceUnavailable|GatewayTimeout|404|NotFound|Not Found') {
                throw
            }
            if ($attempt -eq 6) { throw }
        }
        if ($folder -and $folder.webUrl) { return $folder }
        if ($attempt -lt 6) { Start-Sleep -Seconds 10 }
    }
    throw "SharePoint files site for '$($Channel.DisplayName)' is not ready."
}

function Get-CoEChannelSiteUrl(
    [string]$TeamId,
    [object]$Channel,
    [string]$ParentSiteUrl,
    [object]$Connection
) {
    $folder = Get-CoEChannelFilesFolder -TeamId $TeamId -Channel $Channel -Connection $Connection
    $folderUri = [uri]$folder.webUrl
    $channelSiteUrl = "$($folderUri.Scheme)://$($folderUri.Host)$($folderUri.AbsolutePath.Substring(0, $folderUri.AbsolutePath.LastIndexOf('/')))"
    if ($channelSiteUrl.TrimEnd("/") -eq $ParentSiteUrl.TrimEnd("/")) {
        throw "The '$($Channel.DisplayName)' channel does not have a separate SharePoint site."
    }
    return $channelSiteUrl
}

function Initialize-CoEGovernanceSecurity(
    [string]$TeamId,
    [object[]]$Channels,
    [string]$SiteUrl,
    [string]$OwnerUPN,
    [string[]]$AdditionalAllowedMembers,
    [string[]]$OrganizationEmailDomains,
    [ValidateSet("Disabled", "ExistingExternalUserSharingOnly", "ExternalUserSharingOnly")]
    [string]$CoESiteSharingCapability = "Disabled",
    [object]$Connection,
    [object]$AdvisoryContext
) {
    $allowed = @($OwnerUPN) + @($AdditionalAllowedMembers)
    $allowed = @($allowed | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().ToLowerInvariant() } | Select-Object -Unique)
    if ([string]::IsNullOrWhiteSpace($OwnerUPN)) { throw "SharedChannelOwnerUPN is required for governance security verification." }

    $allowedIdentities = @()
    foreach ($email in $allowed) {
        if ($email -notmatch "^[^@\s]+@[^@\s]+\.[^@\s]+$" -or $email -match "[<>]") {
            throw "Governance channel allowlist contains an invalid address: '$email'."
        }
        $identity = Invoke-PnPGraphMethod -Url "v1.0/users/$([uri]::EscapeDataString($email))?`$select=id,userPrincipalName,userType" `
            -Method Get -Connection $Connection -ErrorAction Stop
        Assert-CoEMemberIdentity -Identity $identity -Address $email
        $allowedIdentities += [pscustomobject]@{
            Email  = $email
            UserId = [string]$identity.id
        }
    }

    $ownerIdentity = @($allowedIdentities | Where-Object Email -eq $OwnerUPN.Trim().ToLowerInvariant())
    if ($ownerIdentity.Count -ne 1) { throw "The configured governance owner could not be uniquely resolved." }
    $teamRoster = Get-CoETeamRoster -TeamId $TeamId -Channels $Channels `
        -OrganizationEmailDomains $OrganizationEmailDomains -Connection $Connection
    if (-not $teamRoster.Passed) {
        $details = @($teamRoster.Unverified | ForEach-Object {
            $email = Get-CoEChannelMemberEmail $_
            if ($email) { $email } else { "<identity without a returned email>" }
        }) -join ", "
        throw "The parent Team has members without a returned identity: $details. Review them before publishing."
    }

    if ($AdvisoryContext -and $teamRoster.External.Count) {
        $externalEmails = @($teamRoster.External | ForEach-Object { Get-CoEChannelMemberEmail $_ } | Sort-Object -Unique)
        Confirm-CoEAdvisory -Context $AdvisoryContext -Id ParentTeamExternalMembers `
            -Facts (@($TeamId) + $externalEmails + @($OrganizationEmailDomains | Sort-Object -Unique)) `
            -Message "The parent Team contains guest/out-of-domain identities: $($externalEmails -join ', '). PROCEED accepts only this roster advisory; governance membership, tenant identity and sharing checks remain mandatory."
    }
    $null = Set-CoESiteSharing -SiteUrl $SiteUrl -SharingCapability $CoESiteSharingCapability -Connection $Connection

    $results = @()
    foreach ($channelName in @("Leadership Governance", "Program Governance")) {
        $matches = @($Channels | Where-Object DisplayName -eq $channelName)
        if ($matches.Count -ne 1 -or [string]$matches[0].MembershipType -ne "shared") {
            throw "Expected exactly one shared channel named '$channelName'."
        }
        $channel = $matches[0]
        $access = Get-CoEVerifiedGovernanceAccess -TeamId $TeamId -Channel $channel `
            -AllowedIdentities $allowedIdentities -OwnerUserId $ownerIdentity[0].UserId -Connection $Connection
        if (-not $access.Passed) {
            throw "Governance security check failed for '$channelName': $($access.Failures -join ' ') No content should be published."
        }

        $channelSiteUrl = Get-CoEChannelSiteUrl -TeamId $TeamId -Channel $channel -ParentSiteUrl $SiteUrl -Connection $Connection
        $site = Set-CoESiteSharing -SiteUrl $channelSiteUrl -SharingCapability Disabled -Connection $Connection
        $externalUsers = @(Get-PnPExternalUser -SiteUrl $channelSiteUrl -Connection $Connection -ErrorAction Stop)
        if ($externalUsers.Count -gt 0) {
            throw "SharePoint returned $($externalUsers.Count) external-user entry/entries for '$channelName'. Review and remove external access before publishing."
        }
        $results += [pscustomobject]@{
            Channel         = $channelName
            Site            = $channelSiteUrl
            Members         = $access.Members
            MemberCount     = $access.MemberCount
            HostTenantId    = $access.HostTenantId
            SharedTeamCount = $access.SharedTeamCount
            SiteRecord      = $site
        }
    }
    return $results
}

function Write-CoESecurityPosture(
    [string]$SiteUrl,
    [string]$TeamId,
    [string]$ExpectedVisibility,
    [string[]]$OrganizationEmailDomains,
    [string]$OwnerUPN,
    [string[]]$AdditionalAllowedMembers,
    [ValidateSet("Disabled", "ExistingExternalUserSharingOnly", "ExternalUserSharingOnly")]
    [string]$CoESiteSharingCapability = "Disabled",
    [string]$SettingsPath,
    [object]$Connection
) {
    $team = Get-PnPTeamsTeam -Identity $TeamId -Connection $Connection -ErrorAction Stop
    $site = Get-PnPTenantSite -Identity $SiteUrl -Detailed -DisableSharingForNonOwnersStatus -Connection $Connection -ErrorAction Stop
    $channels = @(Get-PnPTeamsChannel -Team $TeamId -Connection $Connection -ErrorAction Stop)
    $teamRoster = Get-CoETeamRoster -TeamId $TeamId -Channels $channels `
        -OrganizationEmailDomains $OrganizationEmailDomains -Connection $Connection
    $governanceSecurity = @()
    $governanceFailures = [System.Collections.Generic.List[string]]::new()
    $allowed = @($OwnerUPN) + @($AdditionalAllowedMembers)
    $allowed = @($allowed | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().ToLowerInvariant() } | Select-Object -Unique)
    $allowedIdentities = @()
    foreach ($email in $allowed) {
        if ($email -notmatch "^[^@\s]+@[^@\s]+\.[^@\s]+$" -or $email -match "[<>]") {
            throw "Governance channel allowlist contains an invalid address: '$email'."
        }
        $identity = Invoke-PnPGraphMethod -Url "v1.0/users/$([uri]::EscapeDataString($email))?`$select=id,userPrincipalName,userType" `
            -Method Get -Connection $Connection -ErrorAction Stop
        Assert-CoEMemberIdentity -Identity $identity -Address $email
        $allowedIdentities += [pscustomobject]@{ Email = $email; UserId = [string]$identity.id }
    }
    $ownerIdentity = @($allowedIdentities | Where-Object Email -eq $OwnerUPN.Trim().ToLowerInvariant())
    if ($ownerIdentity.Count -ne 1) { throw "The configured governance owner could not be uniquely resolved for the final posture check." }

    foreach ($channelName in @("Leadership Governance", "Program Governance")) {
        $channel = @($channels | Where-Object DisplayName -eq $channelName)
        if ($channel.Count -ne 1 -or [string]$channel[0].MembershipType -ne "shared") {
            throw "The final posture check could not find exactly one shared channel named '$channelName'."
        }
        $entry = Get-CoEVerifiedGovernanceAccess -TeamId $TeamId -Channel $channel[0] `
            -AllowedIdentities $allowedIdentities -OwnerUserId $ownerIdentity[0].UserId -Connection $Connection
        $channelSiteUrl = Get-CoEChannelSiteUrl -TeamId $TeamId -Channel $channel[0] -ParentSiteUrl $SiteUrl -Connection $Connection
        $entry | Add-Member -NotePropertyName Site -NotePropertyValue $channelSiteUrl
        $governanceSecurity += $entry
        foreach ($failure in $entry.Failures) { $governanceFailures.Add("$($channelName): $failure") }
    }

    $siteChecks = @([pscustomobject]@{
        Name = "Parent site"; Url = $SiteUrl; Record = $site; ExpectedSharing = $CoESiteSharingCapability; IsGovernance = $false
    })
    foreach ($entry in $governanceSecurity) {
        $governanceSite = Get-PnPTenantSite -Identity $entry.Site -Detailed -DisableSharingForNonOwnersStatus -Connection $Connection -ErrorAction Stop
        $siteChecks += [pscustomobject]@{
            Name = $entry.Channel; Url = $entry.Site; Record = $governanceSite; ExpectedSharing = "Disabled"; IsGovernance = $true
        }
    }
    $externalUserChecks = @()
    foreach ($entry in $siteChecks) {
        $externalUsers = @(Get-PnPExternalUser -SiteUrl $entry.Url -Connection $Connection -ErrorAction Stop)
        $externalUserChecks += [pscustomobject]@{
            Name   = $entry.Name
            Count  = $externalUsers.Count
            IsGovernance = $entry.IsGovernance
            Status = if ($externalUsers.Count -eq 0) { "NONE RETURNED" } elseif ($entry.IsGovernance) { "FAIL" } else { "REVIEW NAMED GUESTS" }
        }
    }

    $teamStatus = if ([string]$team.Visibility -eq $ExpectedVisibility) { "PASS" } else { "FAIL" }
    $siteStatus = @($siteChecks | ForEach-Object {
        [pscustomobject]@{
            Name   = $_.Name
            Url    = $_.Url
            Sharing = [string]$_.Record.SharingCapability
            ExpectedSharing = $_.ExpectedSharing
            NonOwnerSharingDisabled = [bool]$_.Record.DisableSharingForNonOwnersStatus
            Status = if ([string]$_.Record.SharingCapability -eq $_.ExpectedSharing -and $_.Record.DisableSharingForNonOwnersStatus) {
                "PASS"
            } else { "FAIL" }
        }
    })
    $teamRosterStatus = if ($teamRoster.Passed) { "PASS" } else { "FAIL" }
    $failures = [System.Collections.Generic.List[string]]::new()
    if ($teamStatus -ne "PASS") { $failures.Add("Team visibility does not match the required '$ExpectedVisibility' value.") }
    foreach ($check in $siteStatus) {
        if ($check.Status -ne "PASS") { $failures.Add("$($check.Name) sharing does not match '$($check.ExpectedSharing)' with non-owner sharing disabled.") }
    }
    foreach ($check in $externalUserChecks) {
        if ($check.IsGovernance -and $check.Count -gt 0) { $failures.Add("$($check.Name) has external-user entries returned by SharePoint.") }
    }
    if ($teamRosterStatus -ne "PASS") { $failures.Add("The parent Team roster includes members without a returned identity.") }
    foreach ($failure in $governanceFailures) { $failures.Add($failure) }

    Write-Host ""
    Write-Host "COE SECURITY POSTURE (live checks; not a substitute for your organization's security approval)" -ForegroundColor Cyan
    Write-Host ("  Team visibility: {0} [{1}] (required: {2})" -f $team.Visibility, $teamStatus, $ExpectedVisibility)
    Write-Host ("  Parent Team roster: {0} member(s); returned-identity check [{1}]; guest/out-of-domain candidates: {2}" -f $teamRoster.Count, $teamRosterStatus, $teamRoster.External.Count)
    foreach ($member in $teamRoster.External) {
        Write-Host "    REVIEW guest/out-of-domain Team member (membership grants edit, not read-only preview): $(Get-CoEChannelMemberEmail $member)" -ForegroundColor Yellow
    }
    foreach ($check in $siteStatus) {
        $sharingState = if ($check.Sharing -eq "Disabled") { "OFF" } elseif ($check.Sharing -in @("ExistingExternalUserSharingOnly", "ExternalUserSharingOnly", "ExternalUserAndGuestSharing")) { "ON" } else { "UNKNOWN" }
        Write-Host ("  {0} external sharing: {1} ({2}) [{3}]; non-owner sharing disabled: {4}" -f `
            $check.Name, $sharingState, $check.Sharing, $check.Status, $check.NonOwnerSharingDisabled)
        Write-Host "    Site: $($check.Url)"
    }
    foreach ($check in $externalUserChecks) {
        Write-Host ("  {0} external-user entries returned by SharePoint: {1} [{2}]" -f `
            $check.Name, $check.Count, $check.Status)
    }
    foreach ($entry in $governanceSecurity) {
        $status = if ($entry.Passed) { "PASS" } else { "FAIL" }
        Write-Host ("  {0} effective access: {1} member(s), {2} other-Team share(s) [{3}]" -f `
            $entry.Channel, $entry.MemberCount, $entry.SharedTeamCount, $status)
        foreach ($failure in $entry.Failures) { Write-Host "    REVIEW: $failure" -ForegroundColor Yellow }
    }
    Write-Host "  Existing anonymous/specific-people links and item-level grants: NOT ENUMERATED; review SharePoint permissions and sharing reports."
    Write-Host "  Tenant sharing ceiling, Teams/Groups guest policies, Entra B2B/cross-tenant access, sensitivity labels and conditional access: NOT ASSESSED; they can block guest access even when site sharing is ON."
    Write-Host ""
    Write-Host "ADMIN HANDOFF - CUSTOMER SHARING OFF; LAB PREVIEW IS OPT-IN" -ForegroundColor Yellow
    Write-Host "  WHY OFF by default: customer deployments are internal-only. Shipped settings and omitted settings use Disabled; do not enable sharing to complete a customer install."
    Write-Host "  LAB ONLY: a separate lab organization settings file may explicitly use ExistingExternalUserSharingOnly = Existing guests. The kit does not invite guests or grant them access."
    Write-Host "  For approved lab preview, grant Visitors Read access or a Specific people - Can view link to reviewed content. Never add preview guests to the Team or Members group: that grants edit rights."
    Write-Host "  ExternalUserSharingOnly = New and existing guests is an explicit lab option if invitations are approved. Anonymous/Anyone links are never supported."
    Write-Host "  Leadership and Program Governance stay internal-only. Parent Team guests do not get access to those shared channels."
    Write-Host "  Preview access is NOT verified: test sign-in as each intended guest; review the parent site's content and permissions before inviting them."
    Write-Host "  TURN OFF now: SharePoint admin center > Active sites > select '$SiteUrl' > Settings > More sharing settings > Only people in your organization > Save."
    Write-Host "  Or, in an authenticated SharePoint-admin PnP session, run:"
    $quotedSiteUrl = $SiteUrl.Replace("'", "''")
    Write-Host "    Set-PnPTenantSite -Identity '$quotedSiteUrl' -SharingCapability Disabled -Wait"
    Write-Host "    . .\Internal\SecurityPosture.ps1"
    Write-Host "    Set-CoENonOwnerSharingDisabled -SiteUrl '$quotedSiteUrl' -Connection (Get-PnPConnection)"
    Write-Host "  Verify the site's SharingCapability is Disabled. This blocks external SharePoint pages/files, not Teams chat."
    $settingsLabel = if ($SettingsPath) { $SettingsPath } else { "the Deployment-Settings.json used for this organization" }
    Write-Host "  KEEP IT OFF: set `"CoESiteSharingCapability`": `"Disabled`" in $settingsLabel BEFORE the next install/resume/update."
    Write-Host "  Reruns apply that setting; omitting it defaults to Disabled. An explicit lab ON setting can still reverse a portal-only shutdown."
    Write-Host "  End lab preview by removing Visitors grants and Specific people links. If guests were previously added to the Team, remove them under Manage team > Members and guests too; disabling sharing does not delete grants or end Teams chat."
    Write-Host "  No tenant-wide policies are changed. If lab preview is blocked, keep Disabled; do not loosen tenant policy merely to complete installation."
    if ($failures.Count -gt 0) {
        Write-Warning "Security posture checks failed: $($failures -join ' ')"
        throw "CoE security posture verification failed. Resolve the findings above before inviting users or publishing more content."
    }
    Write-Host "  Configuration checks passed. Existing links/grants and tenant cross-tenant policy still require separate review." -ForegroundColor Green
    Write-Host ""
}
