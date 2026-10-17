# Static guard: PowerShell automatic variables that are read-only or constant cannot be assigned. Assigning
# one throws only when that line runs, so a bug in a rarely run path (a fresh-install-only repair, for example)
# can survive every offline test and every resume run and then fail on the first real install.
# This scans every kit script with the real parser, so it cannot be fooled by text that merely mentions a name.
Set-StrictMode -Version Latest
$kitRoot = Split-Path -Parent $PSScriptRoot

# Verified with Set-Variable against pwsh 7: every name here refuses assignment (ReadOnly or Constant).
$script:ProtectedNames = @("HOME", "PID", "PSHOME", "PSVersionTable", "PSEdition", "ShellId", "Host", "true", "false",
    "IsWindows", "IsLinux", "IsMacOS", "IsCoreCLR", "Error", "ExecutionContext")

function Get-ProtectedAssignments([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Cannot parse $Path" }
    $assignments = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] }, $true)
    foreach ($assignment in $assignments) {
        $targets = @($assignment.Left.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] }, $true))
        if ($assignment.Left -is [Management.Automation.Language.VariableExpressionAst]) { $targets = @($assignment.Left) }
        foreach ($target in $targets) {
            # Skip "$script:x" style prefixes by comparing the bare name, and member access like $x.Home.
            if ($assignment.Left -isnot [Management.Automation.Language.VariableExpressionAst] -and
                $assignment.Left -isnot [Management.Automation.Language.ConvertExpressionAst]) { continue }
            $name = $target.VariablePath.UserPath -replace '^(script|global|local|private):', ''
            if ($name -in $script:ProtectedNames) {
                [pscustomobject]@{ File = [IO.Path]::GetFileName($Path); Line = $assignment.Extent.StartLineNumber
                    Variable = "`$$name"; Text = $assignment.Extent.Text.Split("`n")[0].Trim() }
            }
        }
    }
}

Describe "Read-only automatic variables are never assigned" {
    It "lists only names that PowerShell really refuses to assign" {
        # Run in PowerShell 7, where the kit runs; Windows PowerShell 5.1 differs for the Is* variables.
        $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
        $list = ($script:ProtectedNames | ForEach-Object { "'$_'" }) -join ","
        $code = "foreach(`$n in $list){ `$ok=`$true; try { Set-Variable -Name `$n -Value 0 -Scope Local -ErrorAction Stop } catch { `$ok=`$false }; if(`$ok){ `$n } }"
        $assignable = @(& $pwsh -NoProfile -Command $code)
        ($assignable -join ",") | Should BeNullOrEmpty
    }
    It "detects the original defect: assigning to `$home" {
        $probe = Join-Path ([IO.Path]::GetTempPath()) ("probe-" + [guid]::NewGuid().ToString("N") + ".ps1")
        try {
            Set-Content -LiteralPath $probe -Value '$home = Get-PnPPage -Identity "TrainingHome.aspx"; $homePage = 1; $x.Home = 2'
            $found = @(Get-ProtectedAssignments $probe)
            $found.Count | Should Be 1
            $found[0].Variable | Should Be '$HOME'
        } finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    }
    It "finds no assignment to a read-only automatic variable in any kit script" {
        $scripts = @(Get-ChildItem -LiteralPath $kitRoot -Recurse -File -Filter "*.ps1" |
            Where-Object { $_.FullName -notmatch '\\(Tests|RevisionAudit|\.prepare-|\.preparation-tests-)' })
        $scripts.Count | Should BeGreaterThan 8
        $hits = @($scripts | ForEach-Object { Get-ProtectedAssignments $_.FullName })
        (($hits | ForEach-Object { "$($_.File):$($_.Line) $($_.Variable)  $($_.Text)" }) -join "`n") | Should BeNullOrEmpty
    }
}
