#Requires -Version 5.1
<#
.SYNOPSIS
    Restore app settings from a 02-Backup run onto this PC.
.DESCRIPTION
    Default is report-only: shows what would be restored and what would be
    replaced. -Apply restores; anything already at a target is renamed to
    <name>.pre-restore-<time> first. -Undo puts those back.
    Install the apps (04) BEFORE restoring, and run from a NORMAL window as
    the station user. Items marked Restore=$false in the backup are skipped.
.EXAMPLE
    .\scripts\06-Restore.ps1
    .\scripts\06-Restore.ps1 -Apply
    .\scripts\06-Restore.ps1 -Apply -Only 'N1MM Logger+','WSJT-X'
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$BackupFolder,
    [string[]]$Only,
    [switch]$Apply,
    [switch]$Undo,
    [string]$UndoFolder,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\ShackMigration.psm1') -Force
$cfg = Import-StationConfig -Path $ConfigPath
$step = '06-Restore'
if ($Undo) { $step = '06-Restore-Undo' }
$out = New-RunFolder -Config $cfg -Step $step
Start-StepLog -Folder $out -Step $step
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# ===========================================================================
# Undo
# ===========================================================================
if ($Undo) {
    if (-not $UndoFolder) { $UndoFolder = Find-LatestRunFolder -Config $cfg -Step '06-Restore' -MustContain 'changes.json' -HostName $env:COMPUTERNAME }
    if (-not $UndoFolder) { throw 'No applied 06-Restore run found on this PC.' }
    $log = @(Read-Json -Path (Join-Path $UndoFolder 'changes.json'))
    [Array]::Reverse($log)
    foreach ($c in $log) {
        try {
            if ($c.Kind -eq 'Folder' -or $c.Kind -eq 'File') {
                if (Test-Path -LiteralPath $c.Target) { Remove-Item -LiteralPath $c.Target -Recurse -Force }
                if ($c.SavedAs -and (Test-Path -LiteralPath $c.SavedAs)) { Rename-Item -LiteralPath $c.SavedAs -NewName (Split-Path -Leaf $c.Target) }
                Write-Log "Reverted $($c.Target)" 'OK'
            }
            elseif ($c.Kind -eq 'Registry' -and $c.SavedAs) {
                & reg.exe import $c.SavedAs | Out-Null
                Write-Log "Re-imported previous $($c.Key)" 'OK'
            }
        }
        catch { Write-Log "Could not revert $($c.Target)$($c.Key): $($_.Exception.Message)" 'ERROR' }
    }
    Write-Log 'Undo complete.' 'OK'
    return
}

# ===========================================================================
# Find the backup
# ===========================================================================
if (-not $BackupFolder) {
    $BackupFolder = Find-LatestRunFolder -Config $cfg -Step '02-Backup' -MustContain 'manifest.json' -OtherHost
    if (-not $BackupFolder) { $BackupFolder = Find-LatestRunFolder -Config $cfg -Step '02-Backup' -MustContain 'manifest.json' }
}
if (-not $BackupFolder) { throw "No 02-Backup with manifest.json under $($cfg.DataRoot). Pass -BackupFolder." }
$man = Read-Json -Path (Join-Path $BackupFolder 'manifest.json')
Write-Log "Backup: $BackupFolder (from $($man.ComputerName), user $($man.UserName), $($man.Created))"
if ($man.UserName -ne $env:USERNAME) { Write-Log "Backup was made as '$($man.UserName)'; you are '$env:USERNAME'. Paths are mapped to YOUR profile." 'WARN' }
if (Test-IsAdmin) { Write-Log 'This window is elevated. Use a normal window unless the station user is also the admin you are logged in as.' 'WARN' }

# Verify hashes before touching anything
$hashFile = Join-Path $BackupFolder 'hashes.csv'
if (Test-Path -LiteralPath $hashFile) {
    $bad = 0
    foreach ($h in (Import-Csv $hashFile)) {
        $f = Join-Path $BackupFolder $h.RelativePath
        if (-not (Test-Path -LiteralPath $f)) { $bad++; continue }
        if ((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash -ne $h.SHA256) { $bad++ }
    }
    if ($bad -gt 0) {
        Write-Log "$bad file(s) in the backup are missing or changed since backup." 'ERROR'
        if (-not $Force) { throw 'Backup failed its hash check. Re-copy it from the old PC, or use -Force.' }
    }
    else { Write-Log 'Backup hash check passed.' 'OK' }
}

function Test-Selected { param([string]$Name) return (-not $Only -or ($Only -contains $Name)) }

$changes = New-Object System.Collections.Generic.List[object]
$running = @()

# --- Folders -------------------------------------------------------------------
foreach ($f in @($man.Folders)) {
    if (-not (Test-Selected $f.Name)) { continue }
    if (-not $f.Restore) { Write-Log "Skip (backup only): $($f.Name)"; continue }
    $target = ConvertFrom-PortablePath -Path $f.PortablePath
    $src = Join-Path $BackupFolder $f.BackupPath
    $exists = Test-Path -LiteralPath $target
    $what = 'new'
    if ($exists) { $what = 'REPLACES existing (kept as .pre-restore)' }
    Write-Log ('{0,-28} -> {1}  [{2}]' -f $f.Name, $target, $what) 'PLAN'
    foreach ($pn in @($f.Process)) { if ($pn -and (Get-Process -Name $pn -ErrorAction SilentlyContinue)) { $running += $pn } }
    if (-not $Apply) { continue }
    if ($running.Count -gt 0) { continue }
    $saved = $null
    if ($exists) {
        $saved = '{0}.pre-restore-{1}' -f $target, $stamp
        Rename-Item -LiteralPath $target -NewName (Split-Path -Leaf $saved)
    }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    & robocopy.exe $src $target /E /COPY:DAT /DCOPY:T /R:1 /W:1 /XJ /NFL /NDL /NP /NJH /NJS | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { Write-Log "robocopy exit $rc restoring $($f.Name)" 'ERROR' } else { Write-Log "Restored $($f.Name)" 'ACTION' }
    $changes.Add([pscustomobject]@{ Kind = 'Folder'; Name = $f.Name; Target = $target; SavedAs = $saved; RobocopyExit = $rc })
}

# --- Loose files ---------------------------------------------------------------
foreach ($l in @($man.Files)) {
    if (-not (Test-Selected $l.Name)) { continue }
    $target = ConvertFrom-PortablePath -Path $l.PortablePath
    Write-Log ('{0,-28} -> {1}' -f $l.Name, $target) 'PLAN'
    if (-not $Apply) { continue }
    $saved = $null
    if (Test-Path -LiteralPath $target) {
        $saved = '{0}.pre-restore-{1}' -f $target, $stamp
        Rename-Item -LiteralPath $target -NewName (Split-Path -Leaf $saved)
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath (Join-Path $BackupFolder $l.BackupPath) -Destination $target
    $changes.Add([pscustomobject]@{ Kind = 'File'; Name = $l.Name; Target = $target; SavedAs = $saved })
    Write-Log "Restored $target" 'ACTION'
}

# --- Registry ------------------------------------------------------------------
foreach ($r in @($man.Registry)) {
    if (-not (Test-Selected $r.Name)) { continue }
    if (-not $r.RestoreRegistry) { Write-Log "Skip registry (RestoreRegistry is off): $($r.Key)"; continue }
    if ($r.Key -notmatch '^HKCU') { Write-Log "Skip non-HKCU key $($r.Key)" 'WARN'; continue }
    Write-Log ('{0,-28} -> import {1}' -f $r.Name, $r.Key) 'PLAN'
    if (-not $Apply) { continue }
    $saved = Join-Path $out ((Get-SafeName $r.Name) + '.before.reg')
    & reg.exe export $r.Key $saved /y 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $saved = $null }
    & reg.exe import (Join-Path $BackupFolder $r.BackupPath) | Out-Null
    $changes.Add([pscustomobject]@{ Kind = 'Registry'; Name = $r.Name; Key = $r.Key; SavedAs = $saved; RegExit = $LASTEXITCODE })
    Write-Log "Imported $($r.Key)" 'ACTION'
}

$running = @($running | Select-Object -Unique)
if ($running.Count -gt 0) {
    Write-Log "Close these first: $($running -join ', ')" 'WARN'
    if ($Apply) { Write-Log 'Folders for running apps were NOT restored. Close them and rerun with -Only <name>.' 'ERROR' }
}

if (-not $Apply) { Write-Log 'Report complete. Rerun with -Apply to restore.' 'OK'; return }
Save-Json -Object $changes.ToArray() -Path (Join-Path $out 'changes.json')
Write-Log "Restored $($changes.Count) item(s). Undo with: .\scripts\06-Restore.ps1 -Undo" 'OK'
Write-Log 'Open each app and re-select COM ports and audio devices if they differ (see 05 PORTMAP.md).'
