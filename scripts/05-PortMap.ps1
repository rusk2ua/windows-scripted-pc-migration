#Requires -Version 5.1
<#
.SYNOPSIS
    Give every station serial port on the new PC the same COM number it had
    on the old PC, and tell you which audio device belongs to which radio.
.DESCRIPTION
    Modes:
      (default)        Report: compare the old PC's inventory with this PC.
      -Capture -Label  Name a device that has no USB serial number (CH340 clones,
                       some FTDI/Prolific adapters). You unplug and replug it and
                       the script records which COM port(s) and audio endpoints
                       appeared. Do this on BOTH PCs with the same label.
      -Apply           Renumber COM ports per the plan (elevated).
      -Undo            Reverse the newest -Apply on this PC (elevated).
    Devices with a USB serial number (Icom radios: IC-7610_12345678_A) match
    automatically. Copy DataRoot from the old PC first so its 01-Inventory and
    labels are available.
.EXAMPLE
    .\scripts\05-PortMap.ps1 -Capture -Label "Keyer Nano"
    .\scripts\05-PortMap.ps1
    .\scripts\05-PortMap.ps1 -Apply
#>
[CmdletBinding(DefaultParameterSetName = 'Report')]
param(
    [string]$ConfigPath,
    [Parameter(ParameterSetName = 'Capture', Mandatory = $true)][switch]$Capture,
    [Parameter(ParameterSetName = 'Capture', Mandatory = $true)][string]$Label,
    [Parameter(ParameterSetName = 'Report')][string]$OldInventory,
    [Parameter(ParameterSetName = 'Report')][switch]$Apply,
    [Parameter(ParameterSetName = 'Undo', Mandatory = $true)][switch]$Undo,
    [Parameter(ParameterSetName = 'Undo')][string]$UndoFolder
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\ShackMigration.psm1') -Force
$cfg = Import-StationConfig -Path $ConfigPath

$arbPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\COM Name Arbiter'

function Set-DeviceEnabled {
    param([string]$InstanceId, [bool]$Enabled)
    if ($Enabled) { Enable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop }
    else { Disable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop }
}

function Set-FriendlyComName {
    param([string]$InstanceId, [int]$From, [int]$To)
    $k = "HKLM:\SYSTEM\CurrentControlSet\Enum\$InstanceId"
    try {
        $fn = (Get-ItemProperty -LiteralPath $k -Name FriendlyName -ErrorAction Stop).FriendlyName
        $new = $fn -replace "\(COM$From\)", "(COM$To)"
        if ($new -ne $fn) { Set-ItemProperty -LiteralPath $k -Name FriendlyName -Value $new -ErrorAction Stop }
    }
    catch { Write-Log "Friendly name not updated for $InstanceId (cosmetic; Device Manager refreshes it after a replug)" 'WARN' }
}

# ===========================================================================
# Capture
# ===========================================================================
if ($Capture) {
    $out = New-RunFolder -Config $cfg -Step '05-PortMap-Capture'
    Start-StepLog -Folder $out -Step '05-PortMap-Capture'
    if (@($cfg.Labels) -notcontains $Label) { Write-Log "'$Label' is not in Labels in your config. That is allowed; use the same spelling on both PCs." 'WARN' }

    function Get-PresentIds { @(Get-PnpDevice -PresentOnly -Class Ports, AudioEndpoint -ErrorAction SilentlyContinue | ForEach-Object { $_.InstanceId }) }

    Write-Host ''
    Read-Host "Unplug the USB cable for '$Label' now, wait 5 seconds, then press Enter"
    Start-Sleep -Seconds 2
    $before = Get-PresentIds
    Read-Host "Plug '$Label' back in (into the hub port it will live on), then press Enter"
    Write-Log 'Waiting for Windows to finish installing the device...'
    $last = ''
    $stable = 0
    $newIds = @()
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $now = Get-PresentIds
        $newIds = @($now | Where-Object { $before -notcontains $_ })
        $sig = ($newIds | Sort-Object) -join '|'
        if ($newIds.Count -gt 0 -and $sig -eq $last) { $stable++ } else { $stable = 0 }
        $last = $sig
        if ($stable -ge 3) { break }
    }
    if ($newIds.Count -eq 0) { throw "No new COM port or audio device appeared for '$Label'. Check the cable and driver, then try again." }

    $devices = @()
    foreach ($id in $newIds) {
        $d = Get-PnpDevice -InstanceId $id
        $entry = [ordered]@{ InstanceId = $id; Class = $d.Class; FriendlyName = $d.FriendlyName }
        if ($d.Class -eq 'Ports') {
            $com = Get-ComNumber (Get-PortNameFromRegistry -InstanceId $id)
            if (-not $com) { $com = Get-ComNumber $d.FriendlyName }
            $entry['Com'] = $com
        }
        else { $entry['Flow'] = Get-EndpointFlow -InstanceId $id }
        $devices += [pscustomobject]$entry
        Write-Log ("  {0}  {1}" -f $d.Class, $d.FriendlyName) 'OK'
    }

    $labelFile = Get-LabelFilePath -Config $cfg
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $labelFile) | Out-Null
    $captures = @()
    if (Test-Path -LiteralPath $labelFile) {
        $captures = @((Read-Json -Path $labelFile).Captures | Where-Object { $_.Label -ne $Label })
    }
    $captures += [pscustomobject]@{ Label = $Label; Captured = (Get-Date).ToString('s'); Devices = $devices }
    Save-Json -Object ([pscustomobject]@{ ComputerName = $env:COMPUTERNAME; Captures = $captures }) -Path $labelFile
    Write-Log "Saved '$Label' ($($devices.Count) device(s)) to $labelFile" 'OK'
    return
}

# ===========================================================================
# Undo
# ===========================================================================
if ($Undo) {
    Assert-Admin
    $out = New-RunFolder -Config $cfg -Step '05-PortMap-Undo'
    Start-StepLog -Folder $out -Step '05-PortMap-Undo'
    if (-not $UndoFolder) { $UndoFolder = Find-LatestRunFolder -Config $cfg -Step '05-PortMap' -MustContain 'changes.json' -HostName $env:COMPUTERNAME }
    if (-not $UndoFolder) { throw 'No applied 05-PortMap run (changes.json) found on this PC.' }
    $log = Read-Json -Path (Join-Path $UndoFolder 'changes.json')
    Write-Log "Reversing $(@($log.Moves).Count) COM change(s) from $UndoFolder" 'ACTION'
    foreach ($m in @($log.Moves)) { try { Set-DeviceEnabled -InstanceId $m.InstanceId -Enabled $false } catch { Write-Log "Disable failed: $($m.Device): $($_.Exception.Message)" 'WARN' } }
    foreach ($m in @($log.Moves)) {
        Set-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Enum\$($m.InstanceId)\Device Parameters" -Name PortName -Value "COM$($m.From)"
        Set-FriendlyComName -InstanceId $m.InstanceId -From ([int]$m.To) -To ([int]$m.From)
        Write-Log "$($m.Device): COM$($m.To) -> COM$($m.From)" 'ACTION'
    }
    if ($log.ComDbBefore) {
        Set-ItemProperty -LiteralPath $arbPath -Name ComDB -Value ([Convert]::FromBase64String($log.ComDbBefore)) -Type Binary
    }
    foreach ($m in @($log.Moves)) { try { Set-DeviceEnabled -InstanceId $m.InstanceId -Enabled $true } catch { Write-Log "Enable failed: $($m.Device): $($_.Exception.Message). Unplug and replug it." 'ERROR' } }
    Write-Log 'Undo complete.' 'OK'
    return
}

# ===========================================================================
# Report (and optionally Apply)
# ===========================================================================
$out = New-RunFolder -Config $cfg -Step '05-PortMap'
Start-StepLog -Folder $out -Step '05-PortMap'
if ($Apply) { Assert-Admin }

if (-not $OldInventory) {
    if ($cfg.ContainsKey('OldComputerName') -and $cfg.OldComputerName) {
        $oldFolder = Find-LatestRunFolder -Config $cfg -Step '01-Inventory' -MustContain 'station-devices.json' -HostName $cfg.OldComputerName
        if (-not $oldFolder) { throw "No 01-Inventory from $($cfg.OldComputerName) under $($cfg.DataRoot). Check OldComputerName in your config, or pass -OldInventory." }
    }
    else {
        $oldFolder = Find-LatestRunFolder -Config $cfg -Step '01-Inventory' -MustContain 'station-devices.json' -OtherHost
        if (-not $oldFolder) { throw "No 01-Inventory from another PC under $($cfg.DataRoot). Run 01-Inventory.ps1 on the old PC and copy DataRoot here, or pass -OldInventory <path to station-devices.json>." }
        Write-Log 'OldComputerName is not set in your config; using the newest inventory from any other PC name. Set it to be sure.' 'WARN'
    }
    $OldInventory = Join-Path $oldFolder 'station-devices.json'
}
$old = Read-Json -Path $OldInventory
Write-Log "Old PC: $($old.ComputerName) (inventory $($old.Captured)) from $OldInventory"

$oldLabels = Read-Labels -Config $cfg -HostName $old.ComputerName
$oldPorts = @($old.Ports)
foreach ($p in $oldPorts) {
    if ($oldLabels.ContainsKey([string]$p.InstanceId)) { $p.Label = $oldLabels[[string]$p.InstanceId] }
}
$oldAudio = @($old.Audio)
foreach ($a in $oldAudio) {
    if ($oldLabels.ContainsKey([string]$a.InstanceId)) {
        $a.Label = $oldLabels[[string]$a.InstanceId]
        if (-not $a.Group) { $a.Group = "label:$($a.Label)" }
    }
}

$curLabels = Read-Labels -Config $cfg
$cur = Get-StationDeviceMap -Labels $curLabels
Save-Json -Object $cur -Path (Join-Path $out 'station-devices-now.json')

$plan = @(New-PortPlan -OldPorts $oldPorts -NewPorts @($cur.Ports) -SerialCommNew $cur.SerialComm)
$plan | Select-Object Action, Device, OldCom, NewCom, TargetCom, Basis, Note, Key, Label, OldInstanceId, NewInstanceId |
    Export-Csv (Join-Path $out 'port-plan.csv') -NoTypeInformation

# Virtual ports on the old PC (VSPE etc.)
$oldVirtual = @()
foreach ($prop in $old.SerialComm.PSObject.Properties) {
    if ($prop.Name -match 'VSPE|com0com|CNC|VSP') { $oldVirtual += [pscustomobject]@{ Device = $prop.Name; Com = (Get-ComNumber $prop.Value) } }
}

# --- Audio mapping ------------------------------------------------------------
$radioNames = @{}
foreach ($r in @($cfg.Radios)) { $radioNames[[string]$r.Group] = [string]$r.Name }
$capSuffix = 'RX'; $renSuffix = 'TX'
if ($cfg.ContainsKey('AudioSuffixCapture')) { $capSuffix = $cfg.AudioSuffixCapture }
if ($cfg.ContainsKey('AudioSuffixRender')) { $renSuffix = $cfg.AudioSuffixRender }

$audioRows = @()
$groups = @(@($oldAudio) + @($cur.Audio) | Where-Object { $_.Group } | ForEach-Object { [string]$_.Group } | Select-Object -Unique)
foreach ($g in $groups) {
    $base = $g
    if ($radioNames.ContainsKey($g)) { $base = $radioNames[$g] }
    elseif ($g -like 'label:*') { $base = $g.Substring(6) }
    foreach ($flow in @('Capture', 'Render')) {
        $o = @($oldAudio | Where-Object { $_.Group -eq $g -and $_.Flow -eq $flow })
        $n = @($cur.Audio | Where-Object { $_.Group -eq $g -and $_.Flow -eq $flow })
        if ($o.Count -eq 0 -and $n.Count -eq 0) { continue }
        $suffix = $renSuffix
        if ($flow -eq 'Capture') { $suffix = $capSuffix }
        $suggest = "$base $suffix"
        $newName = $null
        if ($n.Count -gt 0) { $newName = $n[0].FriendlyName }
        $state = 'Rename'
        if (-not $newName) { $state = 'Not plugged in' }
        elseif ($n[0].EndpointName -eq $suggest) { $state = 'OK' }
        $audioRows += [pscustomobject]@{
            Group = $g; Flow = $flow; OldName = (@($o | ForEach-Object { $_.FriendlyName }) -join '; ')
            NewName = $newName; SuggestedName = $suggest; State = $state
        }
    }
}
$audioRows | Export-Csv (Join-Path $out 'audio-plan.csv') -NoTypeInformation

# --- Proposed station map (used by 07-Verify) -----------------------------------
$stationMap = [pscustomobject]@{
    Created      = (Get-Date).ToString('s')
    OldComputer  = $old.ComputerName
    Ports        = @($plan | Where-Object { $_.Action -in @('OK', 'Renumber') } |
            ForEach-Object { [pscustomobject]@{ Device = $_.Device; Key = $_.Key; Label = $_.Label; Com = $_.TargetCom } })
    Audio        = @($audioRows | ForEach-Object { [pscustomobject]@{ Group = $_.Group; Flow = $_.Flow; Name = $_.SuggestedName } })
    VirtualPorts = @($oldVirtual)
}
Save-Json -Object $stationMap -Path (Join-Path $out 'station-map.proposed.json')

# --- Report ---------------------------------------------------------------------
$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Port map: $($old.ComputerName) -> $env:COMPUTERNAME  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))")
$md.Add('')
$md.Add('## COM ports')
$md.Add('')
$md.Add('| Action | Device | Old | Now | Target | Matched by | Note |')
$md.Add('|---|---|---|---|---|---|---|')
foreach ($r in ($plan | Sort-Object @{e = { switch ($_.Action) { 'Conflict' { 0 } 'Unmatched' { 1 } 'Renumber' { 2 } 'OK' { 3 } default { 4 } } } }, TargetCom)) {
    $oc = ''; if ($r.OldCom) { $oc = "COM$($r.OldCom)" }
    $nc = ''; if ($r.NewCom) { $nc = "COM$($r.NewCom)" }
    $tc = ''; if ($r.TargetCom) { $tc = "COM$($r.TargetCom)" }
    $md.Add("| $($r.Action) | $($r.Device) | $oc | $nc | $tc | $($r.Basis) | $($r.Note) |")
    $lvl = 'PLAN'
    if ($r.Action -in @('Conflict', 'Unmatched')) { $lvl = 'WARN' }
    if ($r.Action -eq 'OK') { $lvl = 'OK' }
    Write-Log ('{0,-9} {1,-60} {2,-6} -> {3,-6} {4}' -f $r.Action, $r.Device, $nc, $tc, $r.Note) $lvl
}
if ($oldVirtual.Count -gt 0) {
    $md.Add('')
    $md.Add('## Virtual ports on the old PC')
    $md.Add('')
    $md.Add('Recreate these in VSPE (load your saved .vspe file) AFTER the physical ports are renumbered:')
    foreach ($v in ($oldVirtual | Sort-Object Com)) {
        $md.Add("- COM$($v.Com) ($($v.Device))")
        $taken = @($cur.Ports | Where-Object { $_.Com -eq $v.Com })
        if ($taken.Count -gt 0) { Write-Log "COM$($v.Com) was a virtual port on the old PC but $($taken[0].FriendlyName) holds it here" 'WARN' }
    }
}
$md.Add('')
$md.Add('## Audio devices')
$md.Add('')
$md.Add('Rename in Control Panel > Sound (mmsys.cpl): Playback tab for TX, Recording tab for RX.')
$md.Add('Select the device > Properties > type the new name. Then pick the new names in N1MM+, WSJT-X, etc.')
$md.Add('')
$md.Add('| Radio | Flow | Old PC name | Name now | Rename to | State |')
$md.Add('|---|---|---|---|---|---|')
foreach ($a in ($audioRows | Sort-Object Group, Flow)) {
    $md.Add("| $($a.Group) | $($a.Flow) | $($a.OldName) | $($a.NewName) | $($a.SuggestedName) | $($a.State) |")
}
$ungrouped = @($cur.Audio | Where-Object { -not $_.Group -and $_.FriendlyName -match 'USB' })
if ($ungrouped.Count -gt 0) {
    $md.Add('')
    $md.Add('USB audio endpoints that could not be tied to a radio (capture them with -Capture -Label if they matter):')
    foreach ($u in $ungrouped) { $md.Add("- $($u.Flow): $($u.FriendlyName)") }
}
$missingLabels = @()
$oldLabelNames = @($oldLabels.Values | Select-Object -Unique)
$curLabelNames = @($curLabels.Values | Select-Object -Unique)
foreach ($l in @($cfg.Labels)) {
    $where = @()
    if ($oldLabelNames -notcontains $l) { $where += $old.ComputerName }
    if ($curLabelNames -notcontains $l) { $where += $env:COMPUTERNAME }
    if ($where.Count -gt 0) { $missingLabels += "- '$l' not captured on: $($where -join ', ')" }
}
if ($missingLabels.Count -gt 0) {
    $md.Add('')
    $md.Add('## Labels still to capture')
    $md.Add('')
    foreach ($m in $missingLabels) { $md.Add($m); Write-Log $m 'WARN' }
}
$md | Set-Content (Join-Path $out 'PORTMAP.md') -Encoding UTF8

$moves = @($plan | Where-Object { $_.Action -eq 'Renumber' } |
        ForEach-Object { [pscustomobject]@{ Device = $_.Device; InstanceId = $_.NewInstanceId; From = [int]$_.NewCom; To = [int]$_.TargetCom } })
$problems = @($plan | Where-Object { $_.Action -in @('Conflict', 'Unmatched') }).Count

if (-not $Apply) {
    Write-Log "Report: $($moves.Count) port(s) to renumber, $problems problem row(s). Details: $out\PORTMAP.md" 'OK'
    if ($moves.Count -eq 0 -and $problems -eq 0) {
        Save-Json -Object $stationMap -Path (Join-Path $cfg.DataRoot 'station-map.json')
        Write-Log "Nothing to change. Saved $($cfg.DataRoot)\station-map.json for 07-Verify." 'OK'
    }
    else { Write-Log 'Close all station apps, then rerun elevated with -Apply.' }
    return
}

# ===========================================================================
# Apply
# ===========================================================================
if ($moves.Count -eq 0) {
    Save-Json -Object $stationMap -Path (Join-Path $cfg.DataRoot 'station-map.json')
    Write-Log 'No ports need renumbering. Saved station-map.json.' 'OK'
    return
}
if ($problems -gt 0) { Write-Log "$problems conflict/unmatched row(s) are skipped; the rest will be applied." 'WARN' }

$dbBefore = $null
try { $dbBefore = [byte[]](Get-ItemProperty -LiteralPath $arbPath -Name ComDB -ErrorAction Stop).ComDB } catch { $dbBefore = New-Object byte[] 32 }
$log = [pscustomobject]@{
    Created     = (Get-Date).ToString('s')
    ComDbBefore = [Convert]::ToBase64String($dbBefore)
    Moves       = $moves
}
Save-Json -Object $log -Path (Join-Path $out 'changes.json')

Write-Log 'Disabling the ports being renumbered...' 'ACTION'
foreach ($m in $moves) { Set-DeviceEnabled -InstanceId $m.InstanceId -Enabled $false }
try {
    foreach ($m in $moves) {
        Set-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Enum\$($m.InstanceId)\Device Parameters" -Name PortName -Value "COM$($m.To)"
        Set-FriendlyComName -InstanceId $m.InstanceId -From $m.From -To $m.To
        Write-Log "$($m.Device): COM$($m.From) -> COM$($m.To)" 'ACTION'
    }
    $dbAfter = Get-NewComDb -Current $dbBefore -Moves $moves
    Set-ItemProperty -LiteralPath $arbPath -Name ComDB -Value ([byte[]]$dbAfter) -Type Binary
}
finally {
    Write-Log 'Re-enabling ports...' 'ACTION'
    foreach ($m in $moves) {
        try { Set-DeviceEnabled -InstanceId $m.InstanceId -Enabled $true }
        catch { Write-Log "Enable failed for $($m.Device): $($_.Exception.Message). Unplug and replug it." 'ERROR' }
    }
}

Start-Sleep -Seconds 3
$after = Get-StationDeviceMap -Labels $curLabels
$bad = 0
foreach ($m in $moves) {
    $p = $after.Ports | Where-Object { $_.InstanceId -eq $m.InstanceId } | Select-Object -First 1
    if ($p -and [int]$p.Com -eq $m.To) { Write-Log "Verified $($m.Device) on COM$($m.To)" 'OK' }
    else { $bad++; Write-Log "$($m.Device) is not on COM$($m.To) yet. Unplug/replug it or reboot, then run 07-Verify." 'WARN' }
}
Save-Json -Object $stationMap -Path (Join-Path $cfg.DataRoot 'station-map.json')
Write-Log "Applied. $($moves.Count - $bad) of $($moves.Count) verified. Undo with: .\scripts\05-PortMap.ps1 -Undo" 'OK'
Write-Log 'Next: rename audio devices per PORTMAP.md, then load your VSPE config if you use virtual ports.'
