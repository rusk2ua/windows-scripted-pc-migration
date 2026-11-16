#Requires -Version 5.1
<#
.SYNOPSIS
    Back up station app settings (folders, HKCU registry keys, loose config files).
.DESCRIPTION
    Default is report-only: shows what would be copied and whether any of the
    apps are running. Add -Apply to copy. Run from a NORMAL (non-elevated)
    window as the station user, so %APPDATA% and %LOCALAPPDATA% point at your
    profile. Output: <DataRoot>\<date>_<host>\02-Backup\ with manifest.json.
.EXAMPLE
    .\scripts\02-Backup.ps1
    .\scripts\02-Backup.ps1 -Apply
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Apply,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\ShackMigration.psm1') -Force
$cfg = Import-StationConfig -Path $ConfigPath
$out = New-RunFolder -Config $cfg -Step '02-Backup'
Start-StepLog -Folder $out -Step '02-Backup'
if (-not $Apply) { Write-Log 'Report-only. Add -Apply to copy files.' }
if (Test-IsAdmin) { Write-Log 'This window is elevated. That is fine if you are logged in as the station user; otherwise rerun from a normal window.' 'WARN' }

# --- Resolve what to back up ---------------------------------------------------
$items = @()
foreach ($sf in @($cfg.SettingsFolders)) {
    $paths = @(Resolve-ConfigPaths -Candidates $sf.Candidates)
    if ($paths.Count -eq 0) { Write-Log "Not found: $($sf.Name)  (Candidates: $($sf.Candidates -join '; '))" 'WARN'; continue }
    foreach ($p in $paths) {
        $files = @(Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue)
        $bytes = ($files | Measure-Object Length -Sum).Sum
        if (-not $bytes) { $bytes = 0 }
        $restore = $true
        if ($sf.ContainsKey('Restore')) { $restore = [bool]$sf.Restore }
        $sensitive = $false
        if ($sf.ContainsKey('Sensitive')) { $sensitive = [bool]$sf.Sensitive }
        $items += [pscustomobject]@{
            Name = $sf.Name; Source = $p; PortablePath = (ConvertTo-PortablePath -Path $p)
            Files = $files.Count; Bytes = [long]$bytes; Restore = $restore; Sensitive = $sensitive
            Process = @($sf.Process)
        }
        Write-Log ('{0,-28} {1,6} files {2,8} MB  {3}' -f $sf.Name, $files.Count, [math]::Round($bytes / 1MB, 1), $p) 'PLAN'
    }
}

$loose = @()
foreach ($fp in @($cfg.FilePatterns)) {
    $root = ConvertFrom-PortablePath -Path $fp.Root
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $found = @(Get-ChildItem -LiteralPath $root -Recurse -Depth 4 -File -Filter $fp.Pattern -Force -ErrorAction SilentlyContinue)
    foreach ($f in $found) {
        $loose += [pscustomobject]@{ Name = $fp.Name; Source = $f.FullName; PortablePath = (ConvertTo-PortablePath -Path $f.FullName) }
        Write-Log ('{0,-28} file {1}' -f $fp.Name, $f.FullName) 'PLAN'
    }
    if ($found.Count -eq 0) { Write-Log "No '$($fp.Pattern)' files under $root ($($fp.Name))" 'WARN' }
}

$regs = @()
foreach ($rk in @($cfg.RegistryKeys)) {
    $psPath = 'Registry::' + ($rk.Key -replace '^HKCU', 'HKEY_CURRENT_USER' -replace '^HKLM', 'HKEY_LOCAL_MACHINE')
    if (Test-Path -LiteralPath $psPath) {
        $restoreReg = $false
        if ($rk.ContainsKey('RestoreRegistry')) { $restoreReg = [bool]$rk.RestoreRegistry }
        $regs += [pscustomobject]@{ Name = $rk.Name; Key = $rk.Key; RestoreRegistry = $restoreReg }
        Write-Log ('{0,-28} registry {1}' -f $rk.Name, $rk.Key) 'PLAN'
    }
    else { Write-Log "Registry key not found: $($rk.Key)" 'WARN' }
}

# --- Running apps would give an inconsistent copy (open databases) ------------
$running = @()
foreach ($i in $items) {
    foreach ($pn in $i.Process) {
        if ($pn -and (Get-Process -Name $pn -ErrorAction SilentlyContinue)) { $running += "$pn ($($i.Name))" }
    }
}
$running = @($running | Select-Object -Unique)
if ($running.Count -gt 0) { Write-Log "Running now: $($running -join ', '). Close them before -Apply." 'WARN' }

if (@($items | Where-Object Sensitive).Count -gt 0) {
    Write-Log 'Some items hold certificates or credentials (marked Sensitive). Keep the backup folder private.' 'WARN'
}

$totalMB = [math]::Round((($items | Measure-Object Bytes -Sum).Sum) / 1MB, 1)
Write-Log "Total: $(@($items).Count) folders, $(@($loose).Count) files, $(@($regs).Count) registry keys, $totalMB MB"

if (-not $Apply) { Write-Log 'Report complete. Nothing was copied.' 'OK'; return }

if ($running.Count -gt 0 -and -not $Force) { throw 'Close the running apps listed above (or add -Force to copy anyway).' }

# --- Copy -----------------------------------------------------------------------
$filesRoot = Join-Path $out 'files'
New-Item -ItemType Directory -Force -Path $filesRoot | Out-Null
$manifest = [ordered]@{
    ComputerName = $env:COMPUTERNAME; UserName = $env:USERNAME; Created = (Get-Date).ToString('s')
    ToolVersion = (Get-ToolVersion); Folders = @(); Files = @(); Registry = @()
}
$n = 0
foreach ($i in $items) {
    $n++
    $rel = 'files\{0:D2}_{1}' -f $n, (Get-SafeName $i.Name)
    $dest = Join-Path $out $rel
    Write-Log "Copying $($i.Source)" 'ACTION'
    & robocopy.exe $i.Source $dest /E /COPY:DAT /DCOPY:T /R:1 /W:1 /XJ /NFL /NDL /NP /NJH /NJS | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { Write-Log "robocopy failed (exit $rc) for $($i.Source)" 'ERROR' }
    $manifest.Folders += [pscustomobject]@{
        Name = $i.Name; PortablePath = $i.PortablePath; OriginalPath = $i.Source; BackupPath = $rel
        Files = $i.Files; Bytes = $i.Bytes; Restore = $i.Restore; Sensitive = $i.Sensitive; Process = $i.Process; RobocopyExit = $rc
    }
}
$looseRoot = Join-Path $out 'loose'
foreach ($l in $loose) {
    New-Item -ItemType Directory -Force -Path $looseRoot | Out-Null
    $leaf = Split-Path -Leaf $l.Source
    $destName = $leaf
    $k = 1
    while (Test-Path -LiteralPath (Join-Path $looseRoot $destName)) { $k++; $destName = '{0}_{1}' -f $k, $leaf }
    Copy-Item -LiteralPath $l.Source -Destination (Join-Path $looseRoot $destName)
    $manifest.Files += [pscustomobject]@{ Name = $l.Name; PortablePath = $l.PortablePath; BackupPath = "loose\$destName" }
    Write-Log "Copied $($l.Source)" 'ACTION'
}
$regRoot = Join-Path $out 'registry'
foreach ($r in $regs) {
    New-Item -ItemType Directory -Force -Path $regRoot | Out-Null
    $file = Join-Path $regRoot ((Get-SafeName $r.Name) + '.reg')
    & reg.exe export $r.Key $file /y | Out-Null
    $manifest.Registry += [pscustomobject]@{ Name = $r.Name; Key = $r.Key; BackupPath = 'registry\' + (Split-Path -Leaf $file); RestoreRegistry = $r.RestoreRegistry; RegExit = $LASTEXITCODE }
    Write-Log "Exported $($r.Key)" 'ACTION'
}

Write-Log 'Hashing backup (SHA256)...'
Get-ChildItem -LiteralPath $out -Recurse -File |
    Where-Object { $_.Name -notin @('hashes.csv', 'run.log', 'manifest.json') } |
    ForEach-Object {
        $h = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
        [pscustomobject]@{ RelativePath = $_.FullName.Substring($out.Length + 1); Bytes = $_.Length; SHA256 = $h.Hash }
    } | Export-Csv (Join-Path $out 'hashes.csv') -NoTypeInformation

Save-Json -Object $manifest -Path (Join-Path $out 'manifest.json')
Write-Log "Backup complete: $out" 'OK'
Write-Log 'Next: copy the whole DataRoot folder to the new PC (USB stick or network share).'
