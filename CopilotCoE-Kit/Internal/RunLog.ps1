# Shared run logging for the numbered scripts. Dot-source it; importing it does nothing.
# Every run writes a full transcript so a failure always leaves a log that explains where it stopped.

function Start-CoERunLog {
    param(
        [Parameter(Mandatory)][string]$KitRoot,
        [Parameter(Mandatory)][string]$Script,
        [string]$OrgPath = ""
    )
    $runId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    # The audit folder belongs to the organization folder when there is one, so runs for different
    # organizations never share a log folder; otherwise it falls back to the kit's own RevisionAudit.
    $base = if ($OrgPath -and (Test-Path -LiteralPath $OrgPath -PathType Container)) { $OrgPath } else { $KitRoot }
    $folder = Join-Path $base "RevisionAudit"
    [void][IO.Directory]::CreateDirectory($folder)
    $path = Join-Path $folder "$runId-transcript.txt"
    $started = $false
    try {
        Start-Transcript -LiteralPath $path -IncludeInvocationHeader | Out-Null
        $started = $true
    } catch {
        # A transcript may already be running (for example under a host that records its own); keep going.
        Write-Warning "Run log could not be started: $($_.Exception.Message)"
    }
    Write-Host "Run log: $path"
    [pscustomobject]@{ RunId = $runId; Path = $path; Started = $started; Script = $Script
        StartedAt = Get-Date }
}

function Stop-CoERunLog {
    param([Parameter(Mandatory)]$Log, [bool]$Succeeded)
    $elapsed = [int]((Get-Date) - $Log.StartedAt).TotalSeconds
    Write-Host ("{0} {1} in {2}s. Run log: {3}" -f $Log.Script, $(if ($Succeeded) { "finished" } else { "FAILED" }), $elapsed, $Log.Path)
    if ($Log.Started) {
        try { Stop-Transcript | Out-Null } catch { Write-Warning "Run log could not be closed cleanly: $($_.Exception.Message)" }
    }
}
