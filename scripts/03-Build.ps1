#Requires -Version 5.1
<#
.SYNOPSIS
    Windows settings for station duty: no sleep, no USB power saving, controlled updates.
.DESCRIPTION
    Default is report-only (current vs. wanted). -Apply makes the changes and
    logs every before/after value to changes.json. -Undo reverses the newest
    applied run (or the one given with -UndoFolder).
    Run elevated. Run Windows Update to completion (including drivers) BEFORE
    -Apply, because this script stops Windows Update from installing drivers.
.EXAMPLE
    .\scripts\03-Build.ps1
    .\scripts\03-Build.ps1 -Apply
    .\scripts\03-Build.ps1 -Undo
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Apply,
    [switch]$Undo,
    [string]$UndoFolder
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\ShackMigration.psm1') -Force
$cfg = Import-StationConfig -Path $ConfigPath
$b = $cfg.Build
$stepName = '03-Build'
if ($Undo) { $stepName = '03-Build-Undo' }
$out = New-RunFolder -Config $cfg -Step $stepName
Start-StepLog -Folder $out -Step $stepName
if ($Apply -or $Undo) { Assert-Admin }

function Get-Opt { param([string]$Name, $Default) if ($b -and $b.ContainsKey($Name)) { return $b[$Name] } return $Default }

# ===========================================================================
# Undo
# ===========================================================================
if ($Undo) {
    if (-not $UndoFolder) { $UndoFolder = Find-LatestRunFolder -Config $cfg -Step '03-Build' -MustContain 'changes.json' -HostName $env:COMPUTERNAME }
    if (-not $UndoFolder) { throw 'No applied 03-Build run (changes.json) found on this PC.' }
    $log = Read-Json -Path (Join-Path $UndoFolder 'changes.json')
    Write-Log "Reversing $(@($log).Count) changes from $UndoFolder" 'ACTION'
    $items = @($log)
    [Array]::Reverse($items)
    foreach ($c in $items) {
        try {
            switch ($c.Kind) {
                'Registry' {
                    if ($c.Before.Exists) {
                        $val = $c.Before.Value
                        $type = [string]$c.Before.Type
                        if ($type -eq 'DWord') { $val = [int]$val }
                        Set-RegistryValue -Path $c.Path -Name $c.Name -Value $val -Type $type
                    }
                    elseif (Test-Path -LiteralPath $c.Path) {
                        Remove-ItemProperty -LiteralPath $c.Path -Name $c.Name -ErrorAction SilentlyContinue
                    }
                }
                'Power' { if ($null -ne $c.Before) { Set-PowerIndex -SubGroup $c.Sub -Setting $c.Setting -Value ([int]$c.Before) } }
                'DevicePower' {
                    $inst = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Stop |
                        Where-Object { $_.InstanceName -eq $c.InstanceName }
                    if ($inst) { Set-CimInstance -InputObject $inst -Property @{ Enable = [bool]$c.Before } }
                }
            }
            Write-Log "Restored: $($c.Description)" 'OK'
        }
        catch { Write-Log "Could not restore $($c.Description): $($_.Exception.Message)" 'ERROR' }
    }
    Copy-Item -LiteralPath (Join-Path $UndoFolder 'changes.json') -Destination (Join-Path $out 'reversed-changes.json')
    Write-Log 'Undo complete. Reboot to be sure every setting takes effect.' 'OK'
    return
}

# ===========================================================================
# Build the list of wanted settings
# ===========================================================================
$wanted = New-Object System.Collections.Generic.List[object]

function Add-Reg {
    param([string]$Description, [string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    $wanted.Add([pscustomobject]@{ Kind = 'Registry'; Description = $Description; Path = $Path; Name = $Name; Value = $Value; Type = $Type })
}
function Add-Power {
    param([string]$Description, [string]$Key, [int]$Value)
    $s = (Get-PowerSettingTable)[$Key]
    $wanted.Add([pscustomobject]@{ Kind = 'Power'; Description = $Description; Sub = $s.Sub; Setting = $s.Setting; Value = $Value })
}

if (Get-Opt 'NeverSleep' $true) {
    Add-Power 'Never sleep (AC)' 'StandbyIdle' 0
    Add-Power 'Never hibernate (AC)' 'HibernateIdle' 0
    Add-Power 'Never turn off disk (AC)' 'DiskIdle' 0
}
if (Get-Opt 'DisableUsbSelectiveSuspend' $true) { Add-Power 'USB selective suspend off' 'UsbSuspend' 0 }
if (Get-Opt 'DisablePcieLinkPowerManagement' $true) { Add-Power 'PCIe link state power management off' 'PcieAspm' 0 }
if (Get-Opt 'DisableFastStartup' $true) {
    Add-Reg 'Fast Startup off (clean boots, devices re-enumerate)' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
}

$wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$au = "$wu\AU"
if (Get-Opt 'ExcludeDriversFromWindowsUpdate' $true) {
    Add-Reg 'Windows Update does not replace drivers (CP210x, CH340, chipset)' $wu 'ExcludeWUDriversInQualityUpdate' 1
}
if (Get-Opt 'PinFeatureUpdate' $true) {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $disp = $null
    if ($cv.PSObject.Properties['DisplayVersion']) { $disp = $cv.DisplayVersion }
    $build = [int]$cv.CurrentBuildNumber
    $product = 'Windows 10'
    if ($build -ge 22000) { $product = 'Windows 11' }
    if ($disp) {
        Add-Reg "Stay on $product $disp until you change it (security updates continue)" $wu 'TargetReleaseVersion' 1
        Add-Reg "Feature update product: $product" $wu 'ProductVersion' $product 'String'
        Add-Reg "Feature update version: $disp" $wu 'TargetReleaseVersionInfo' $disp 'String'
    }
    else { Write-Log 'Could not read DisplayVersion; skipping feature-update pin.' 'WARN' }
}
if (Get-Opt 'NoAutoRebootWithLoggedOnUsers' $true) {
    Add-Reg 'No automatic restart while you are logged on' $au 'NoAutoRebootWithLoggedOnUsers' 1
}
$auOpt = Get-Opt 'AUOptions' $null
if ($null -ne $auOpt) { Add-Reg "Automatic Updates mode $auOpt (3 = download automatically, you choose when to install)" $au 'AUOptions' ([int]$auOpt) }
$ahs = Get-Opt 'ActiveHoursStart' $null
$ahe = Get-Opt 'ActiveHoursEnd' $null
if ($null -ne $ahs -and $null -ne $ahe) {
    $ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    Add-Reg "Active hours start ${ahs}:00" $ux 'ActiveHoursStart' ([int]$ahs)
    Add-Reg "Active hours end ${ahe}:00" $ux 'ActiveHoursEnd' ([int]$ahe)
}

# "Allow the computer to turn off this device to save power" for USB devices and the wired NIC
$devPower = @()
if (Get-Opt 'DisableUsbDevicePowerOff' $true) {
    try {
        $nicIds = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { $_.PnPDeviceID })
        $devPower = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Stop | Where-Object {
                $n = $_.InstanceName
                ($n -match '^USB\\') -or ($nicIds | Where-Object { $_ -and $n.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })
            })
    }
    catch { Write-Log "Could not read device power settings: $($_.Exception.Message)" 'WARN' }
}

# ===========================================================================
# Report / apply
# ===========================================================================
$changes = New-Object System.Collections.Generic.List[object]
$pending = 0

foreach ($w in $wanted) {
    if ($w.Kind -eq 'Registry') {
        $before = Get-RegistryValueState -Path $w.Path -Name $w.Name
        $same = $before.Exists -and ([string]$before.Value -eq [string]$w.Value)
        if ($same) { Write-Log "Already set: $($w.Description)" 'OK'; continue }
        $pending++
        Write-Log ('{0}  [{1}\{2}: {3} -> {4}]' -f $w.Description, $w.Path, $w.Name, $(if ($before.Exists) { $before.Value } else { '(none)' }), $w.Value) 'PLAN'
        if ($Apply) {
            try {
                Set-RegistryValue -Path $w.Path -Name $w.Name -Value $w.Value -Type $w.Type
                $changes.Add([pscustomobject]@{ Kind = 'Registry'; Description = $w.Description; Path = $w.Path; Name = $w.Name; Before = $before; After = $w.Value })
                Write-Log "Set: $($w.Description)" 'ACTION'
            }
            catch { Write-Log "Failed: $($w.Description): $($_.Exception.Message)" 'ERROR' }
        }
    }
    elseif ($w.Kind -eq 'Power') {
        $before = Get-PowerIndex -SubGroup $w.Sub -Setting $w.Setting
        if ($null -eq $before) { Write-Log "Power setting not available on this PC: $($w.Description)" 'WARN'; continue }
        if ([int]$before -eq [int]$w.Value) { Write-Log "Already set: $($w.Description)" 'OK'; continue }
        $pending++
        Write-Log "$($w.Description)  [$before -> $($w.Value)]" 'PLAN'
        if ($Apply) {
            try {
                Set-PowerIndex -SubGroup $w.Sub -Setting $w.Setting -Value $w.Value
                $changes.Add([pscustomobject]@{ Kind = 'Power'; Description = $w.Description; Sub = $w.Sub; Setting = $w.Setting; Before = $before; After = $w.Value })
                Write-Log "Set: $($w.Description)" 'ACTION'
            }
            catch { Write-Log "Failed: $($w.Description): $($_.Exception.Message)" 'ERROR' }
        }
    }
}

foreach ($d in $devPower) {
    if (-not $d.Enable) { continue }
    $pending++
    $desc = "Do not power off device: $($d.InstanceName)"
    Write-Log $desc 'PLAN'
    if ($Apply) {
        try {
            Set-CimInstance -InputObject $d -Property @{ Enable = $false }
            $changes.Add([pscustomobject]@{ Kind = 'DevicePower'; Description = $desc; InstanceName = $d.InstanceName; Before = $true; After = $false })
            Write-Log "Set: $desc" 'ACTION'
        }
        catch { Write-Log "Failed: $desc : $($_.Exception.Message)" 'ERROR' }
    }
}

Write-Log ''
Write-Log 'Not scriptable from Windows - do these by hand (see docs\runbook.md):' 'WARN'
Write-Log '  BIOS: power on after AC loss = On; disable deep sleep / ErP if offered.'
Write-Log '  Run windows-scripted-cleanup for telemetry and bloat removal.'

if (-not $Apply) {
    Write-Log "Report complete. $pending setting(s) would change. Rerun with -Apply." 'OK'
    return
}
Save-Json -Object @($changes) -Path (Join-Path $out 'changes.json')
Write-Log "Applied $($changes.Count) change(s). Log: $out\changes.json. Undo with: .\scripts\03-Build.ps1 -Undo" 'OK'
Write-Log 'Reboot now so Fast Startup and device power settings take effect.' 'WARN'
