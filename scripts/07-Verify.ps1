#Requires -Version 5.1
<#
.SYNOPSIS
    Station health check. Read-only. Run after each phase, after Windows
    updates, and any time the station acts up.
.DESCRIPTION
    Checks COM ports and audio names against <DataRoot>\station-map.json,
    services, power/USB settings, update policy, clock offset, disk health,
    free space and recent hardware errors. Writes VERIFY.md and an on-air
    checklist. Exit code: 0 = all pass, 1 = warnings, 2 = failures.
.EXAMPLE
    .\scripts\07-Verify.ps1
#>
[CmdletBinding()]
param([string]$ConfigPath, [switch]$SkipClock)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\ShackMigration.psm1') -Force
$cfg = Import-StationConfig -Path $ConfigPath
$out = New-RunFolder -Config $cfg -Step '07-Verify'
Start-StepLog -Folder $out -Step '07-Verify'

$v = @{}
if ($cfg.ContainsKey('Verify') -and $cfg.Verify) { $v = $cfg.Verify }
function Get-V { param([string]$Name, $Default) if ($v.ContainsKey($Name)) { return $v[$Name] } return $Default }

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Area, [string]$Check, [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')][string]$State, [string]$Detail = '')
    $results.Add([pscustomobject]@{ Area = $Area; Check = $Check; State = $State; Detail = $Detail })
    $lvl = 'OK'
    if ($State -eq 'WARN') { $lvl = 'WARN' } elseif ($State -eq 'FAIL') { $lvl = 'ERROR' } elseif ($State -eq 'INFO') { $lvl = 'INFO' }
    Write-Log ('{0,-4} {1,-10} {2}  {3}' -f $State, $Area, $Check, $Detail) $lvl
}

# --- COM ports and audio ----------------------------------------------------------
$labels = Read-Labels -Config $cfg
$now = Get-StationDeviceMap -Labels $labels
$mapFile = Join-Path $cfg.DataRoot 'station-map.json'
if (Test-Path -LiteralPath $mapFile) {
    $map = Read-Json -Path $mapFile
    foreach ($p in @($map.Ports)) {
        $hit = $null
        if ($p.Key) { $hit = $now.Ports | Where-Object { $_.Key -eq $p.Key } | Select-Object -First 1 }
        if (-not $hit -and $p.Label) { $hit = $now.Ports | Where-Object { $_.Label -eq $p.Label } | Select-Object -First 1 }
        if (-not $hit) { Add-Result 'COM' $p.Device 'FAIL' "missing (expected COM$($p.Com))"; continue }
        if ([int]$hit.Com -eq [int]$p.Com) {
            $st = 'PASS'
            $d = "COM$($hit.Com)"
            if ($hit.Status -and $hit.Status -ne 'OK') { $st = 'WARN'; $d = "$d, device status $($hit.Status)" }
            Add-Result 'COM' $p.Device $st $d
        }
        else { Add-Result 'COM' $p.Device 'FAIL' "on COM$($hit.Com), expected COM$($p.Com) (rerun 05-PortMap)" }
    }
    foreach ($vp in @($map.VirtualPorts)) {
        $sc = @($now.SerialComm.Values | Where-Object { (Get-ComNumber $_) -eq [int]$vp.Com })
        if ($sc.Count -gt 0) { Add-Result 'COM' "virtual COM$($vp.Com)" 'PASS' '' }
        else { Add-Result 'COM' "virtual COM$($vp.Com)" 'WARN' 'not present - load your VSPE config' }
    }
    foreach ($a in @($map.Audio)) {
        $hit = $now.Audio | Where-Object { $_.EndpointName -eq $a.Name -and $_.Flow -eq $a.Flow } | Select-Object -First 1
        if ($hit) { Add-Result 'Audio' $a.Name 'PASS' $hit.FriendlyName }
        else { Add-Result 'Audio' $a.Name 'WARN' "no $($a.Flow) device named '$($a.Name)' (rename in mmsys.cpl, or radio off/unplugged)" }
    }
}
else {
    Add-Result 'COM' 'station-map.json' 'WARN' 'not found - run 05-PortMap.ps1 first. Listing what is present:'
    foreach ($p in ($now.Ports | Sort-Object Com)) { Add-Result 'COM' $p.FriendlyName 'INFO' "group=$($p.Group) label=$($p.Label)" }
}
$problemPorts = @(Get-PnpDevice -Class Ports -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Error' })
foreach ($pp in $problemPorts) { Add-Result 'COM' $pp.FriendlyName 'FAIL' 'device in error state (driver?)' }

# --- Services ---------------------------------------------------------------------
foreach ($s in @(Get-V 'Services' @('W32Time'))) {
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    if (-not $svc) { Add-Result 'Service' $s 'FAIL' 'not installed' }
    elseif ($svc.Status -ne 'Running') { Add-Result 'Service' $s 'FAIL' "status $($svc.Status)" }
    else { Add-Result 'Service' $s 'PASS' 'running' }
}

# --- Power / USB ------------------------------------------------------------------
$pt = Get-PowerSettingTable
$checks = @(
    @{ Key = 'UsbSuspend'; Want = 0; Name = 'USB selective suspend off' },
    @{ Key = 'StandbyIdle'; Want = 0; Name = 'Never sleep' },
    @{ Key = 'HibernateIdle'; Want = 0; Name = 'Never hibernate' },
    @{ Key = 'PcieAspm'; Want = 0; Name = 'PCIe link power mgmt off' }
)
foreach ($c in $checks) {
    $s = $pt[$c.Key]
    $val = Get-PowerIndex -SubGroup $s.Sub -Setting $s.Setting
    if ($null -eq $val) { Add-Result 'Power' $c.Name 'INFO' 'setting not exposed on this PC' }
    elseif ($val -eq $c.Want) { Add-Result 'Power' $c.Name 'PASS' '' }
    else { Add-Result 'Power' $c.Name 'WARN' "value $val (run 03-Build)" }
}
$fs = Get-RegistryValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled'
if ($fs.Exists -and [int]$fs.Value -eq 0) { Add-Result 'Power' 'Fast Startup off' 'PASS' '' } else { Add-Result 'Power' 'Fast Startup off' 'WARN' 'Fast Startup is on (run 03-Build)' }

# --- Windows Update policy and pending reboot ---------------------------------------
$wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$drv = Get-RegistryValueState -Path $wu -Name 'ExcludeWUDriversInQualityUpdate'
if ($drv.Exists -and [int]$drv.Value -eq 1) { Add-Result 'Updates' 'Drivers excluded from Windows Update' 'PASS' '' }
else { Add-Result 'Updates' 'Drivers excluded from Windows Update' 'WARN' 'Windows Update may replace CP210x/CH340 drivers' }
$trv = Get-RegistryValueState -Path $wu -Name 'TargetReleaseVersionInfo'
if ($trv.Exists) { Add-Result 'Updates' 'Feature update pinned' 'PASS' $trv.Value } else { Add-Result 'Updates' 'Feature update pinned' 'INFO' 'not pinned' }
$reboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
if ($reboot) { Add-Result 'Updates' 'Pending reboot' 'WARN' 'a reboot is pending - do it before operating' } else { Add-Result 'Updates' 'Pending reboot' 'PASS' 'none' }

# --- Clock -------------------------------------------------------------------------
if (-not $SkipClock) {
    $ntp = Get-V 'NtpServer' 'time.windows.com'
    $warn = [double](Get-V 'ClockWarnSeconds' 0.2)
    $fail = [double](Get-V 'ClockFailSeconds' 1.0)
    $lines = @(& w32tm.exe /stripchart /computer:$ntp /samples:3 /dataonly 2>&1)
    $offsets = @()
    foreach ($l in $lines) {
        if ($l -match ',\s*([+-]?\d+(?:[\.,]\d+)?)s') { $offsets += [double]($Matches[1] -replace ',', '.') }
    }
    if ($offsets.Count -eq 0) { Add-Result 'Clock' "Offset vs $ntp" 'WARN' 'could not measure (network/firewall?)' }
    else {
        $off = ($offsets | Measure-Object -Average).Average
        $abs = [math]::Abs($off)
        $st = 'PASS'
        if ($abs -ge $fail) { $st = 'FAIL' } elseif ($abs -ge $warn) { $st = 'WARN' }
        Add-Result 'Clock' "Offset vs $ntp" $st ('{0:+0.000;-0.000} s' -f $off)
    }
}

# --- Storage -----------------------------------------------------------------------
foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
    $st = 'PASS'
    if ($d.HealthStatus -ne 'Healthy') { $st = 'FAIL' }
    $detail = "$($d.MediaType) $($d.BusType) $([math]::Round($d.Size / 1GB)) GB, $($d.HealthStatus)"
    try {
        $rc = Get-StorageReliabilityCounter -PhysicalDisk $d -ErrorAction Stop
        if ($null -ne $rc.Wear) { $detail += ", wear $($rc.Wear)%"; if ($rc.Wear -ge 80) { $st = 'WARN' } }
        if ($null -ne $rc.Temperature -and $rc.Temperature -gt 0) { $detail += ", $($rc.Temperature) C" }
    }
    catch { }
    Add-Result 'Disk' $d.FriendlyName $st $detail
}
$minFree = [double](Get-V 'MinFreePercent' 15)
$c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
if ($c) {
    $pct = [math]::Round(100 * $c.FreeSpace / $c.Size, 1)
    $st = 'PASS'
    if ($pct -lt $minFree) { $st = 'WARN' }
    Add-Result 'Disk' "$($env:SystemDrive) free space" $st "$pct %"
}

# --- Recent hardware trouble in the System log ----------------------------------------
$days = [int](Get-V 'EventLogDays' 7)
$since = (Get-Date).AddDays(-$days)
try {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $since } -ErrorAction Stop)
}
catch { $ev = @() }
$kp41 = @($ev | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41 })
if ($kp41.Count -gt 0) { Add-Result 'Events' 'Unexpected shutdowns' 'FAIL' "$($kp41.Count) in $days days (Kernel-Power 41: power loss, crash or RF lockup)" }
else { Add-Result 'Events' 'Unexpected shutdowns' 'PASS' "none in $days days" }
$hw = @($ev | Where-Object { $_.ProviderName -match 'WHEA|disk|Ntfs|stornvme|USBHUB|USBXHCI|Kernel-PnP' })
if ($hw.Count -gt 0) {
    $top = ($hw | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 4 | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
    Add-Result 'Events' 'Hardware/USB/disk errors' 'WARN' $top
    $hw | Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message | Export-Csv (Join-Path $out 'hardware-events.csv') -NoTypeInformation
}
else { Add-Result 'Events' 'Hardware/USB/disk errors' 'PASS' "none in $days days" }

# --- Write report -------------------------------------------------------------------
$fails = @($results | Where-Object State -eq 'FAIL').Count
$warns = @($results | Where-Object State -eq 'WARN').Count
$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Station verify: $env:COMPUTERNAME  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))")
$md.Add('')
$md.Add("**$fails fail, $warns warn**")
$md.Add('')
$md.Add('| State | Area | Check | Detail |')
$md.Add('|---|---|---|---|')
foreach ($r in $results) { $md.Add("| $($r.State) | $($r.Area) | $($r.Check) | $($r.Detail) |") }
$md | Set-Content (Join-Path $out 'VERIFY.md') -Encoding UTF8
$results | Export-Csv (Join-Path $out 'verify.csv') -NoTypeInformation
$checklist = Join-Path (Get-RepoRoot) 'docs\on-air-checklist.md'
if (Test-Path -LiteralPath $checklist) { Copy-Item -LiteralPath $checklist -Destination (Join-Path $out 'on-air-checklist.md') }

Write-Log "Result: $fails fail, $warns warn. Report: $out\VERIFY.md" $(if ($fails) { 'ERROR' } elseif ($warns) { 'WARN' } else { 'OK' })
Write-Log 'Scripts cannot key a transmitter. Finish with docs\on-air-checklist.md.'
if ($fails) { exit 2 } elseif ($warns) { exit 1 } else { exit 0 }
