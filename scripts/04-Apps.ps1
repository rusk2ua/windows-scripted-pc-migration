#Requires -Version 5.1
<#
.SYNOPSIS
    Install station apps with winget, pin the ones that must not change, and
    produce a checklist of apps and drivers that need a manual install.
.DESCRIPTION
    Default is report-only. With -Apply:
      - from an ELEVATED window it installs Scope='machine' apps and adds pins;
      - from a NORMAL window it installs Scope='user' apps (Slack, Python, Arduino IDE...).
    Per-user apps are never installed or upgraded from an elevated window.
.EXAMPLE
    .\scripts\04-Apps.ps1
    .\scripts\04-Apps.ps1 -Apply
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\ShackMigration.psm1') -Force
$cfg = Import-StationConfig -Path $ConfigPath
$out = New-RunFolder -Config $cfg -Step '04-Apps'
Start-StepLog -Folder $out -Step '04-Apps'
$admin = Test-IsAdmin
if (-not $Apply) { Write-Log 'Report-only. Add -Apply to install.' }

$haveWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
if (-not $haveWinget) { Write-Log 'winget not found. Install "App Installer" from the Microsoft Store first.' 'ERROR' }

function Test-WingetInstalled {
    param([string]$Id)
    $o = & winget list --id $Id -e --accept-source-agreements 2>$null | Out-String
    return ($LASTEXITCODE -eq 0 -and $o -match [regex]::Escape($Id))
}

$rows = @()
$userCommands = @()
if ($haveWinget) {
    foreach ($app in @($cfg.WingetApps)) {
        $scope = 'machine'
        if ($app.ContainsKey('Scope') -and $app.Scope) { $scope = [string]$app.Scope }
        $pin = $false
        if ($app.ContainsKey('Pin')) { $pin = [bool]$app.Pin }
        $installed = Test-WingetInstalled -Id $app.Id
        $status = 'Installed'
        if (-not $installed) { $status = 'Missing' }
        Write-Log ('{0,-40} {1,-8} {2}{3}' -f $app.Id, $scope, $status, $(if ($pin) { '  (pin)' } else { '' })) 'PLAN'

        if ($Apply -and -not $installed) {
            if ($scope -eq 'user' -and $admin) {
                $userCommands += "winget install --id $($app.Id) -e --scope user --accept-package-agreements --accept-source-agreements"
                $status = 'Skipped (user scope - run from a normal window)'
            }
            elseif ($scope -eq 'machine' -and -not $admin) {
                $status = 'Skipped (machine scope - run elevated)'
            }
            else {
                Write-Log "Installing $($app.Id) ($scope)" 'ACTION'
                & winget install --id $app.Id -e --scope $scope --silent --accept-package-agreements --accept-source-agreements
                $noScope = ($LASTEXITCODE -eq -1978335216)
                if ($noScope -and $admin) {
                    # 0x8A150010 = no installer for that scope. From an elevated window the only other
                    # option is a per-user install, which must not run elevated. Hand it to a normal window.
                    Write-Log "$($app.Id) has no machine-wide installer. Install it from a NORMAL window and set Scope = 'user' in your config." 'WARN'
                    $userCommands += "winget install --id $($app.Id) -e --accept-package-agreements --accept-source-agreements"
                    $status = 'Skipped (per-user only - run from a normal window)'
                }
                elseif ($noScope) {
                    # Normal window asked for user scope but the package is machine-only (e.g. an MSI). Let winget choose; it will ask for elevation.
                    Write-Log "$($app.Id) has no per-user installer; retrying without --scope (expect an admin prompt). Set Scope = 'machine' in your config." 'WARN'
                    & winget install --id $app.Id -e --silent --accept-package-agreements --accept-source-agreements
                }
                if ($status -like 'Skipped*') { }
                elseif ($LASTEXITCODE -eq 0) { $status = 'Installed now' }
                else { $status = "Install failed (exit $LASTEXITCODE)"; Write-Log "$($app.Id): install failed, exit $LASTEXITCODE" 'ERROR' }
            }
        }
        if ($Apply -and $pin -and ($status -like 'Installed*')) {
            & winget pin add --id $app.Id --blocking --accept-source-agreements 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Log "Pinned $($app.Id)" 'ACTION' }
            else { Write-Log "Pin for $($app.Id) not added (exit $LASTEXITCODE; may already exist)" 'WARN' }
        }
        $rows += [pscustomobject]@{ Id = $app.Id; Scope = $scope; Pin = $pin; Status = $status }
    }
    & winget pin list 2>$null | Out-File (Join-Path $out 'winget-pins.txt') -Encoding UTF8
}
$rows | Export-Csv (Join-Path $out 'winget-apps.csv') -NoTypeInformation
$skippedMachine = @($rows | Where-Object { $_.Status -like 'Skipped (machine*' })
if ($skippedMachine.Count -gt 0) {
    Write-Log "$($skippedMachine.Count) machine-scope app(s) were NOT installed because this window is not elevated. Open an elevated window (Start-Process powershell -Verb RunAs) and run -Apply again." 'WARN'
}
elseif (-not $Apply -and -not $admin -and @($rows | Where-Object { $_.Scope -eq 'machine' -and $_.Status -eq 'Missing' }).Count -gt 0) {
    Write-Log 'This window is not elevated: -Apply here installs only user-scope apps. Machine-scope apps need an elevated window.' 'WARN'
}

# --- Manual installs checklist -----------------------------------------------
$progs = Get-InstalledPrograms
$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Manual installs - $env:COMPUTERNAME  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))")
$md.Add('')
$md.Add('Install in this order: drivers first, then apps. Tick each box as you go.')
$md.Add('')
$missing = 0
foreach ($m in @($cfg.ManualApps)) {
    $hit = $progs | Where-Object { $_.Name -like $m.Match } | Select-Object -First 1
    $box = '[ ]'
    $ver = ''
    if ($hit) { $box = '[x]'; $ver = " - found $($hit.Name) $($hit.Version)" } else { $missing++ }
    $src = ''
    if ($m.ContainsKey('Source') -and $m.Source) { $src = " - $($m.Source)" }
    $note = ''
    if ($m.ContainsKey('Note') -and $m.Note) { $note = " - $($m.Note)" }
    $md.Add("- $box **$($m.Name)**$ver$src$note")
}
$md | Set-Content (Join-Path $out 'manual-installs.md') -Encoding UTF8
Write-Log "Manual installs: $missing of $(@($cfg.ManualApps).Count) not found yet. Checklist: $out\manual-installs.md"

if ($userCommands.Count -gt 0) {
    $f = Join-Path $out 'run-in-normal-window.txt'
    $userCommands | Set-Content $f -Encoding UTF8
    Write-Log 'Per-user apps were skipped in this elevated window. Open a NORMAL PowerShell window and run:' 'WARN'
    $userCommands | ForEach-Object { Write-Host "  $_" }
    Write-Log "(also saved to $f)"
}
Write-Log 'Done.' 'OK'
