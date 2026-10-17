# Offline regression tests: Windows PowerShell / installed Pester 3; deployment uses PowerShell 7.
# Unlike Complete-CopilotCoE.ps1 (fully dot-sourceable, tested in Completion.Tests.ps1), almost all of
# 02_Install-CopilotCoE.ps1 requires a live tenant connection (Connect-PnPOnline, New-PnPTeamsTeam, etc.) from
# its very first executable lines, so it has never had offline execution coverage - only the live Preparation
# gate and text-pattern checks in Preparation.Tests.ps1. This file extracts and executes the few genuinely
# tenant-independent blocks via the same AST-extraction technique Completion.Tests.ps1 uses, starting with the
# one that was live-proven broken.
Set-StrictMode -Version Latest
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
        { . $longDisplayNameWarningBlock } | Should Not Throw
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
