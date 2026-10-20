# Offline regression tests: Windows PowerShell / installed Pester 3; deployment uses PowerShell 7.
# Unlike Complete-CopilotCoE.ps1 (fully dot-sourceable, tested in Completion.Tests.ps1), almost all of
# 02_Install-CopilotCoE.ps1 requires a live tenant connection (Connect-PnPOnline, New-PnPTeamsTeam, etc.) from
# its very first executable lines, so it has never had offline execution coverage - only the live Preparation
# gate and text-pattern checks in Preparation.Tests.ps1. This file extracts and executes the few genuinely
# tenant-independent blocks via the same AST-extraction technique Completion.Tests.ps1 uses, starting with the
# one that was live-proven broken.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "New-CoETestFixture.ps1")
$kitRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $kitRoot "02_Install-CopilotCoE.ps1"
$tokens = $null
$parseErrors = $null
$installAst = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

function Get-InstallBlock([string]$Prefix) {
    $node = $installAst.Find({ param($candidate)
        $candidate.Extent.Text.StartsWith($Prefix) -and
        ($candidate -is [System.Management.Automation.Language.IfStatementAst])
    }, $true)
    if (-not $node) { throw "Missing install block: $Prefix" }
    [scriptblock]::Create($node.Extent.Text)
}
$longDisplayNameWarningBlock = Get-InstallBlock 'if ($DisplayName.Length -gt 30) {'
$welcomePostGuard = Get-InstallBlock 'if ($PublishWelcomeToChannels -and -not $ResumeExisting) {'
$welcomePostBlock = Get-InstallBlock 'if ($ResumeExisting -and -not $PublishWelcomeToChannels) {'

Describe "Exception assertion scope" {
    It "evaluates test-local values before the Pester assertion" {
        $message = "intended test-local failure"
        Get-CoETestExceptionMessage { throw $message } | Should Be $message
    }
    It "rejects an action that completes without an exception" {
        Get-CoETestExceptionMessage {
            Get-CoETestExceptionMessage { "ordinary output" }
        } | Should Be "Expected the test action to throw, but it completed successfully."
    }
}

Describe "Long DisplayName warning does not crash the install" {
    # Regression test for a confirmed live bug: Write-Warning "a " + "b" + "c" (a bare cmdlet call followed by
    # unparenthesized string concatenation) is NOT valid in PowerShell's command-argument parsing mode - "+"
    # and each subsequent string are read as additional POSITIONAL ARGUMENTS to Write-Warning, not operands of
    # a concatenation expression, so the whole statement fails with "A positional parameter cannot be found
    # that accepts argument '+'." This branch was only ever reachable live with a DisplayName longer than 30
    # characters, which no live install before this one happened to use - so the bug shipped undetected through
    # 3.8.7's "closes out the review" claim and only surfaced on a customer's own validation run.
    BeforeEach {
        $script:warnings = @()
        Mock Write-Warning { $script:warnings += $Message }
    }

    It "does not throw for a DisplayName longer than 30 characters" {
        $DisplayName = "Contoso Copilot CoE v387 Validation"
        . $longDisplayNameWarningBlock
    }
    It "warns with the site title and its character count" {
        $DisplayName = "Contoso Copilot CoE v387 Validation"
        . $longDisplayNameWarningBlock
        $warnings.Count | Should Be 1
        $warnings[0] | Should Match ([regex]::Escape($DisplayName))
        $warnings[0] | Should Match ([string]$DisplayName.Length)
    }
    It "does not warn for a DisplayName of 30 characters or fewer" {
        $DisplayName = "Contoso Copilot CoE"
        . $longDisplayNameWarningBlock
        $warnings.Count | Should Be 0
    }
}

function Publish-CoEStandardChannelMessages {
    [CmdletBinding()]param($Team, $Channels, $Specifications, [string[]]$SelectedChannelNames, $Connection)
    throw "Unexpected welcome post"
}

Describe "Install welcome-post orchestration" {
    BeforeEach {
        $script:coeGroup = [pscustomobject]@{ GroupId = "runtime-team" }
        $script:standardChannelSpecs = @(
            [pscustomobject]@{ DisplayName = "General" },
            [pscustomobject]@{ DisplayName = "Share Your Prompt" }
        )
        $script:standardChannels = @("verified-General", "verified-Share")
        $script:adminConnection = "offline"
        Mock Publish-CoEStandardChannelMessages {}
        Mock Write-Warning {}
    }

    It "posts every prepared standard channel after a fresh install" {
        $ResumeExisting = $false
        $PublishWelcomeToChannels = @()
        . $welcomePostBlock
        Assert-MockCalled Publish-CoEStandardChannelMessages -Times 1 -Exactly -Scope It -ParameterFilter {
            $Team -eq "runtime-team" -and $SelectedChannelNames.Count -eq 2 -and
            $SelectedChannelNames[0] -eq "General" -and $SelectedChannelNames[1] -eq "Share Your Prompt"
        }
    }
    It "does not duplicate any post during an ordinary resume" {
        $ResumeExisting = $true
        $PublishWelcomeToChannels = @()
        . $welcomePostBlock
        Assert-MockCalled Publish-CoEStandardChannelMessages -Times 0 -Exactly -Scope It
        Assert-MockCalled Write-Warning -Times 1 -Exactly -Scope It
    }
    It "accepts only explicitly selected missing channels on resume" {
        $ResumeExisting = $true
        $PublishWelcomeToChannels = @("General")
        . $welcomePostGuard
        . $welcomePostBlock
        Assert-MockCalled Publish-CoEStandardChannelMessages -Times 1 -Exactly -Scope It -ParameterFilter {
            $SelectedChannelNames.Count -eq 1 -and $SelectedChannelNames[0] -eq "General"
        }
    }
    It "rejects an explicit repost flag before a fresh install creates resources" {
        $ResumeExisting = $false
        $PublishWelcomeToChannels = @("General")
        Get-CoETestExceptionMessage { . $welcomePostGuard } |
            Should Match '^-PublishWelcomeToChannels is only for a resumed install'
        Assert-MockCalled Publish-CoEStandardChannelMessages -Times 0 -Exactly -Scope It
    }
}

$checkerPath = Join-Path $kitRoot "Test-CoEInstall.ps1"
$checkerTokens = $null
$checkerErrors = $null
$checkerAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $checkerPath, [ref]$checkerTokens, [ref]$checkerErrors)
if ($checkerErrors.Count) { throw ($checkerErrors | Out-String) }
$noticeAssignments = @($checkerAst.FindAll({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -in @("configuredNotice", "expectedSampleNotice", "defaultNoticePhrase", "noticeTerms")
}, $true))
if ($noticeAssignments.Count -ne 4) { throw "Expected the checker's four notice policy assignments." }
$noticePolicyBlock = [scriptblock]::Create(($noticeAssignments | ForEach-Object { $_.Extent.Text }) -join "`n")
$homeNoticeCheck = $checkerAst.Find({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    $node.Extent.Text.StartsWith('Add-Result "2 Home" "welcome text replaces the vendor placeholder')
}, $true)
if (-not $homeNoticeCheck) { throw "Missing Home notice validation." }
$homeNoticeBlock = [scriptblock]::Create($homeNoticeCheck.Extent.Text)
$demoNoticeGuard = $checkerAst.Find({ param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.StartsWith('if ($ContentMode -eq "Demo" -and -not $configuredNotice)')
}, $true)
if (-not $demoNoticeGuard) { throw "Missing Demo-mode notice validation." }
$demoNoticeGuardBlock = [scriptblock]::Create($demoNoticeGuard.Extent.Text)
. (Join-Path $kitRoot "Internal\OrganizationProfile.ps1")
function Add-Result([string]$Check, [string]$Item, [bool]$Ok, [string]$Detail = "") {
    $script:lastNoticeResult = $Ok
}

Describe "Checker follows resolved notice and content mode" {
    BeforeEach {
        $script:s = [pscustomobject]@{ OrgName = "Contoso"; DisplayName = "Contoso CoE"; SampleNotice = "none" }
        $script:ContentMode = "Customer"
        $script:canvas = "<h2>Welcome to the Contoso Copilot Center of Excellence</h2><p>None have been approved yet.</p>"
        $script:lastNoticeResult = $null
    }
    It "does not require or ban the none sentinel as literal reader text" {
        . $noticePolicyBlock
        $configuredNotice | Should Be ""
        $expectedSampleNotice | Should Be ""
        ($noticeTerms -contains "none") | Should Be $false
        @($noticeTerms | Where-Object { $canvas -match [regex]::Escape($_) }).Count | Should Be 0
        . $homeNoticeBlock
        $lastNoticeResult | Should Be $true
    }
    It "resolves whitespace and case variants of the none sentinel" {
        foreach ($value in @(" NONE ", "None")) {
            $s.SampleNotice = $value
            . $noticePolicyBlock
            $configuredNotice | Should Be ""
            $expectedSampleNotice | Should Be ""
        }
    }
    It "suppresses a configured notice in Customer mode but still detects a leak" {
        $s.SampleNotice = "DEMO SITE - synthetic data only."
        . $noticePolicyBlock
        $expectedSampleNotice | Should Be ""
        ($noticeTerms -contains $s.SampleNotice) | Should Be $true
        $canvas = "<p>DEMO SITE - synthetic data only.</p>"
        @($noticeTerms | Where-Object { $canvas -match [regex]::Escape($_) }).Count | Should Be 1
    }
    It "does not confuse a custom notice containing the word none with the sentinel" {
        $s.SampleNotice = "None of this is official policy."
        . $noticePolicyBlock
        $configuredNotice | Should Be $s.SampleNotice
        ($noticeTerms -contains $s.SampleNotice) | Should Be $true
    }
    It "keeps the default disclaimer forbidden when a Customer profile leaves SampleNotice blank" {
        $s.SampleNotice = ""
        . $noticePolicyBlock
        $expectedSampleNotice | Should Be ""
        $configuredNotice | Should Match "^Sample starter content for review by Contoso"
        $canvas = "<p>Sample starter content for review by Contoso; not official policy.</p>"
        @($noticeTerms | Where-Object { $canvas -match [regex]::Escape($_) }).Count | Should BeGreaterThan 0
    }
    It "requires a configured Demo notice on Home instead of silently skipping it" {
        $ContentMode = "Demo"
        $s.SampleNotice = "DEMO SITE - synthetic data only."
        . $noticePolicyBlock
        . $homeNoticeBlock
        $lastNoticeResult | Should Be $false
        $canvas += "<p>DEMO SITE - synthetic data only.</p>"
        . $homeNoticeBlock
        $lastNoticeResult | Should Be $true
    }
    It "still rejects the original vendor placeholder with notices suppressed" {
        . $noticePolicyBlock
        $canvas = "<p>Champions help colleagues get the most from Copilot and Microsoft 365</p>"
        . $homeNoticeBlock
        $lastNoticeResult | Should Be $false
    }
    It "preserves configured notice checks when ContentMode is omitted" {
        $ContentMode = ""
        $s.SampleNotice = "Reviewed sample notice."
        . $noticePolicyBlock
        $expectedSampleNotice | Should Be $s.SampleNotice
    }
    It "uses the same effective notice for the additional page checks" {
        $checker = Get-Content -LiteralPath $checkerPath -Raw
        $checker | Should Match 'if \(\$expectedSampleNotice\) \{'
        $checker | Should Not Match '\$s\.SampleNotice'
    }
    It "covers none blank and custom notices in both modes without weakening Demo requirements" {
        foreach ($mode in @("Customer", "Demo")) {
            foreach ($value in @("none", "", "Reviewed internal sample notice.")) {
                $ContentMode = $mode
                $s.SampleNotice = $value
                . $noticePolicyBlock
                if ($mode -eq "Demo" -and $value -eq "none") {
                    Get-CoETestExceptionMessage { . $demoNoticeGuardBlock } | Should Match "non-empty SampleNotice"
                } else {
                    . $demoNoticeGuardBlock
                    if ($mode -eq "Customer") {
                        $expectedSampleNotice | Should Be ""
                    } else {
                        $expectedSampleNotice | Should Not BeNullOrEmpty
                        $canvas = "<p>$expectedSampleNotice</p>"
                        . $homeNoticeBlock
                        $lastNoticeResult | Should Be $true
                    }
                }
                ($noticeTerms -contains "none") | Should Be $false
            }
        }
    }
}

$mailboxSection = $checkerAst.Find({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    $node.Extent.Text.StartsWith('Invoke-Section "8 Customer mode" {')
}, $true)
if (-not $mailboxSection) { throw "Missing Customer-mode mailbox review." }
$mailboxSectionBlock = [scriptblock]::Create($mailboxSection.Extent.Text)
. (Join-Path $kitRoot "Internal\OperatorAdvisories.ps1")
function Invoke-Section([string]$Check, [scriptblock]$Body) { & $Body }
function Add-Warning([string]$Check, [string]$Item, [string]$Detail = "") {
    $script:mailboxWarning = $Detail
}

Describe "Checker preserves the mailbox manual-review gate" {
    BeforeEach {
        $script:s = [pscustomobject]@{ Tenant = "contoso.onmicrosoft.com"; MailNickname = "CoE"; SupportEmail = "support@example.org" }
        $script:SiteUrl = "https://contoso.sharepoint.com/sites/CoE"
        $script:SettingsPath = "unused-offline-path"
        $script:mailboxWarning = ""
        Mock New-CoEAdvisoryContext { "offline-context" }
        Mock Get-CoELabSupportMailboxReview { [pscustomobject]@{ RequiresReview = $false; LabLooking = $false; SavedProceed = $false } }
    }
    It "emits WARN when the mailbox is lab-looking even without a saved approval" {
        Mock Get-CoELabSupportMailboxReview { [pscustomobject]@{ RequiresReview = $true; LabLooking = $true; SavedProceed = $false } }
        . $mailboxSectionBlock
        $mailboxWarning | Should Match 'lab-looking mailbox: True'
        $mailboxWarning | Should Match 'not production acceptance'
    }
    It "emits WARN when a saved approval exists even after the address changes" {
        Mock Get-CoELabSupportMailboxReview { [pscustomobject]@{ RequiresReview = $true; LabLooking = $false; SavedProceed = $true } }
        . $mailboxSectionBlock
        $mailboxWarning | Should Match 'LabSupportMailbox PROCEED: True'
    }
    It "does not warn or claim mailbox delivery was tested for an ordinary address" {
        . $mailboxSectionBlock
        $mailboxWarning | Should Be ""
    }
    It "runs this review only inside Customer mode" {
        $parent = $mailboxSection.Parent
        $found = $false
        while ($parent) {
            if ($parent -is [Management.Automation.Language.IfStatementAst] -and
                $parent.Clauses[0].Item1.Extent.Text -eq '$ContentMode -eq "Customer"') { $found = $true; break }
            $parent = $parent.Parent
        }
        $found | Should Be $true
    }
}

$manualReviewAsts = @($checkerAst.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.StartsWith('if ($warned.Count) {')
}, $true))
if ($manualReviewAsts.Count -ne 2) { throw "Expected the checker warning and summary blocks." }
$manualReviewBlock = [scriptblock]::Create(($manualReviewAsts | ForEach-Object { $_.Extent.Text }) -join "`n")

Describe "Checker warning summary" {
    BeforeEach {
        $script:results = @(1, 2, 3)
        $script:summary = "ALL CHECKS PASSED (3)"
        $script:warned = @()
        Mock Write-Host {}
    }
    It "requires review of a Teams warning without demanding an unrelated site screenshot" {
        $script:warned = @([pscustomobject]@{
            Check = "8 Customer mode"; Item = "Team welcome post"; Detail = "Message read requires ChannelMessage.Read.All"
        })
        . $manualReviewBlock
        $summary | Should Match "MANUAL REVIEW REQUIRED \(1 WARN\)"
        $manualReviewAsts[0].Extent.Text | Should Match "need manual review"
        $manualReviewAsts[0].Extent.Text | Should Not Match "1366px screenshot"
    }
    It "leaves the existing exact success prefix unchanged when there is no warning" {
        . $manualReviewBlock
        $summary | Should Be "ALL CHECKS PASSED (3)"
    }
    It "documents both Navigation screenshot warnings separately from Teams review" {
        foreach ($name in @("01_Admin-Quickstart.html", "START-HERE.txt")) {
            $text = Get-Content -LiteralPath (Join-Path $kitRoot $name) -Raw
            $text | Should Match 'header-layout or long-title/menu-overflow'
            $text | Should Match '1366px'
            $text | Should Match 'ChannelMessage.Read.All'
            $text | Should Not Match 'screenshot only for a header-layout'
        }
    }

    It "documents direct-script recovery separately from launcher reset" {
        foreach ($name in @("01_Admin-Quickstart.html", "START-HERE.txt")) {
            $text = Get-Content -LiteralPath (Join-Path $kitRoot $name) -Raw
            $text | Should Match '(?i)no reset (is )?required'
            $text | Should Match 'Customer-Walkthrough-State.json'
            $text | Should Match 'ResetAfterPurge'
            $text | Should Match 'AliasReusable'
            $text | Should Match '\-Purge \-WhatIf'
            $text | Should Match '(?i)not.*(prerequisite|required).*02_Install|receipt is not required'
        }
    }

    It "reports a found route notice on PASS instead of printing the failure sentence" {
        $checker = Get-Content -LiteralPath $checkerPath -Raw
        $checker | Should Match '\$detail = if \(\$notice\) \{ "not-configured notice found" \}'
        $checker | Should Match 'elseif \(\$AllowUnconfiguredRoutes\) \{ "notice absent; accepted only because -AllowUnconfiguredRoutes was supplied" \}'
        $checker | Should Not Match 'Add-Result "7 Routes"[^\r\n]*\$notice[^\r\n]*"route is empty and the page does not say so"'
    }
    It "documents separate checking and the mailbox review gate without inferring GCC acceptance" {
        foreach ($name in @("01_Admin-Quickstart.html", "START-HERE.txt")) {
            $text = Get-Content -LiteralPath (Join-Path $kitRoot $name) -Raw
            $text | Should Match '(?i)does not automatically run'
            $text | Should Match 'LabSupportMailbox'
            $text | Should Match '(?i)monitoring'
            $text | Should Match '(?i)not GCC Moderate acceptance'
        }
    }
}
