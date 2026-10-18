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
}
