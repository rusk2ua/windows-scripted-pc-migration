#Requires -Version 5.1
<#
.SYNOPSIS
    Report-only inventory of a station PC. Changes nothing.
.DESCRIPTION
    Run on the OLD PC before migrating, and again on the NEW PC at any time.
    Writes to <DataRoot>\<date>_<host>\01-Inventory\. Run it elevated for the
    most complete driver and service detail; a normal window also works.
.EXAMPLE
    .\scripts\01-Inventory.ps1
#>
[CmdletBinding()]
param([string]$ConfigPath)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\ShackMigration.psm1') -Force
$cfg = Import-StationConfig -Path $ConfigPath
$out = New-RunFolder -Config $cfg -Step '01-Inventory'
Start-StepLog -Folder $out -Step '01-Inventory'
Write-Log 'Report-only. Nothing on this PC is changed.'

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add("# Inventory: $env:COMPUTERNAME  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))")
$summary.Add('')

function Invoke-Section {
    param([string]$Name, [scriptblock]$Block)
    Write-Log "$Name..."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { & $Block; Write-Log ('{0} ({1:N0} s)' -f $Name, $sw.Elapsed.TotalSeconds) 'OK' }
    catch { Write-Log "$Name failed: $($_.Exception.Message)" 'WARN' }
}

# --- System -----------------------------------------------------------------
Invoke-Section 'System' {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $disp = $null
    if ($cv.PSObject.Properties['DisplayVersion']) { $disp = $cv.DisplayVersion }
    $disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Select-Object FriendlyName, MediaType, BusType, @{n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } }, HealthStatus)
    $sys = [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        OS           = $os.Caption
        Version      = $os.Version
        Build        = $os.BuildNumber
        DisplayVersion = $disp
        Manufacturer = $cs.Manufacturer
        Model        = $cs.Model
        CPU          = $cpu.Name
        RamGB        = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        BIOS         = '{0} {1}' -f $bios.Manufacturer, $bios.SMBIOSBIOSVersion
        Disks        = $disks
    }
    Save-Json -Object $sys -Path (Join-Path $out 'system.json')
    $summary.Add("- **System:** $($sys.Manufacturer) $($sys.Model), $($sys.CPU), $($sys.RamGB) GB, $($sys.OS) $disp (build $($sys.Build))")
}

# --- Station devices (COM ports + audio, grouped by radio) -------------------
$map = $null
Invoke-Section 'Serial ports and audio endpoints' {
    $labels = Read-Labels -Config $cfg
    $script:map = Get-StationDeviceMap -Labels $labels
    $map = $script:map
    Save-Json -Object $map -Path (Join-Path $out 'station-devices.json')
    $map.Ports | Select-Object Com, FriendlyName, Group, Label, Serial, InstanceId, Parent |
        Sort-Object Com | Export-Csv (Join-Path $out 'com-ports.csv') -NoTypeInformation
    $map.Audio | Select-Object Flow, FriendlyName, Group, Label, FunctionDevice, InstanceId |
        Sort-Object Group, Flow | Export-Csv (Join-Path $out 'audio-endpoints.csv') -NoTypeInformation
    $map.SerialComm.GetEnumerator() | Sort-Object Value |
        ForEach-Object { '{0,-28} {1}' -f $_.Key, $_.Value } | Set-Content (Join-Path $out 'serialcomm.txt') -Encoding UTF8

    $summary.Add('')
    $summary.Add('## COM ports')
    $summary.Add('')
    $summary.Add('| COM | Device | Radio/group | Label | Serial |')
    $summary.Add('|---|---|---|---|---|')
    foreach ($p in ($map.Ports | Sort-Object Com)) {
        $summary.Add("| COM$($p.Com) | $($p.FriendlyName) | $($p.Group) | $($p.Label) | $($p.Serial) |")
    }
    $virtual = @($map.SerialComm.GetEnumerator() | Where-Object { $_.Key -match 'VSPE|com0com|CNC|VSP' })
    if ($virtual.Count -gt 0) {
        $summary.Add('')
        $summary.Add("Virtual ports (recreate on the new PC from your saved config): $((@($virtual | ForEach-Object { $_.Value }) | Sort-Object) -join ', ')")
    }
    $noSerial = @($map.Ports | Where-Object { -not $_.Serial -and -not $_.Label })
    if ($noSerial.Count -gt 0) {
        $summary.Add('')
        $summary.Add('**Ports with no serial number and no label** (capture them with 05-PortMap.ps1 -Capture -Label "<name>"):')
        foreach ($p in $noSerial) { $summary.Add("- COM$($p.Com) $($p.FriendlyName)") }
    }
    $summary.Add('')
    $summary.Add('## Audio endpoints')
    $summary.Add('')
    $summary.Add('| Flow | Endpoint | Radio/group |')
    $summary.Add('|---|---|---|')
    foreach ($a in ($map.Audio | Sort-Object Group, Flow)) {
        $summary.Add("| $($a.Flow) | $($a.FriendlyName) | $($a.Group) |")
    }
}

# --- All USB devices with parents (for troubleshooting hub layout) ----------
Invoke-Section 'USB device tree' {
    $usb = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match '^(USB|FTDIBUS|USBSTOR)\\' })
    Write-Log "  $($usb.Count) USB device(s)"
    $rows = foreach ($d in $usb) {
        [pscustomobject]@{
            Class        = $d.Class
            FriendlyName = $d.FriendlyName
            Status       = [string]$d.Status
            InstanceId   = $d.InstanceId
            Parent       = (Get-DeviceParent -InstanceId $d.InstanceId)
        }
    }
    $rows | Sort-Object Parent, InstanceId | Export-Csv (Join-Path $out 'usb-devices.csv') -NoTypeInformation
}

# --- Programs ---------------------------------------------------------------
Invoke-Section 'Installed programs' {
    $progs = Get-InstalledPrograms
    $progs | Export-Csv (Join-Path $out 'installed-programs.csv') -NoTypeInformation
    $summary.Add('')
    $summary.Add("- **Installed programs:** $(@($progs).Count) (installed-programs.csv)")
    $manual = @($cfg.ManualApps)
    if ($manual.Count -gt 0) {
        $missing = @()
        foreach ($m in $manual) {
            if (-not ($progs | Where-Object { $_.Name -like $m.Match })) { $missing += $m.Name }
        }
        if ($missing.Count -gt 0) { $summary.Add("- Manual apps from config NOT found here: $($missing -join ', ')") }
    }
}

Invoke-Section 'winget list/export' {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        & winget list --accept-source-agreements 2>$null | Out-File (Join-Path $out 'winget-list.txt') -Encoding UTF8
        & winget export -o (Join-Path $out 'winget-export.json') --accept-source-agreements 2>$null | Out-Null
    }
    else { Write-Log 'winget not found' 'WARN' }
}

# --- Services, tasks, startup -----------------------------------------------
Invoke-Section 'Non-Microsoft services' {
    Get-CimInstance Win32_Service |
        Where-Object { $_.PathName -and $_.PathName -notmatch '\\Windows\\' } |
        Select-Object Name, DisplayName, StartMode, State, StartName, PathName |
        Sort-Object Name | Export-Csv (Join-Path $out 'services.csv') -NoTypeInformation
}

Invoke-Section 'Non-Microsoft scheduled tasks' {
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskPath -notlike '\Microsoft\*' } |
        Select-Object TaskPath, TaskName, State,
            @{n = 'Actions'; e = { (@($_.Actions) | ForEach-Object { '{0} {1}' -f $_.Execute, $_.Arguments }) -join ' ; ' } } |
        Export-Csv (Join-Path $out 'scheduled-tasks.csv') -NoTypeInformation
}

Invoke-Section 'Startup items' {
    $rows = @()
    foreach ($k in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')) {
        if (Test-Path -LiteralPath $k) {
            $item = Get-ItemProperty -LiteralPath $k
            foreach ($p in $item.PSObject.Properties) {
                if ($p.Name -notlike 'PS*') { $rows += [pscustomobject]@{ Where = $k; Name = $p.Name; Command = [string]$p.Value } }
            }
        }
    }
    foreach ($dir in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            foreach ($f in Get-ChildItem -LiteralPath $dir -File) { $rows += [pscustomobject]@{ Where = $dir; Name = $f.Name; Command = $f.FullName } }
        }
    }
    $rows | Export-Csv (Join-Path $out 'startup.csv') -NoTypeInformation
}

# --- Drivers, power, time, network -------------------------------------------
Invoke-Section 'Third-party drivers' {
    & pnputil.exe /enum-drivers 2>&1 | Out-File (Join-Path $out 'drivers.txt') -Encoding UTF8
}

Invoke-Section 'Power settings' {
    $rows = @()
    $tbl = Get-PowerSettingTable
    foreach ($name in $tbl.Keys) {
        $s = $tbl[$name]
        $rows += [pscustomobject]@{ Setting = $name; Label = $s.Label; ACValue = (Get-PowerIndex -SubGroup $s.Sub -Setting $s.Setting) }
    }
    $rows | Export-Csv (Join-Path $out 'power.csv') -NoTypeInformation
    & powercfg.exe /getactivescheme 2>&1 | Out-File (Join-Path $out 'power.txt') -Encoding UTF8
    $fs = Get-RegistryValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled'
    "Fast Startup (HiberbootEnabled) = $($fs.Value)" | Add-Content (Join-Path $out 'power.txt')
}

Invoke-Section 'Time sync' {
    $f = Join-Path $out 'time.txt'
    '== w32tm /query /status ==' | Out-File $f -Encoding UTF8
    & w32tm.exe /query /status 2>&1 | Out-File $f -Append -Encoding UTF8
    '== w32tm /query /configuration ==' | Out-File $f -Append -Encoding UTF8
    & w32tm.exe /query /configuration 2>&1 | Out-File $f -Append -Encoding UTF8
}

Invoke-Section 'Network' {
    $f = Join-Path $out 'network.txt'
    Get-NetAdapter -ErrorAction SilentlyContinue | Format-Table -AutoSize Name, InterfaceDescription, Status, LinkSpeed, MacAddress | Out-String -Width 200 | Out-File $f -Encoding UTF8
    Get-NetIPConfiguration -ErrorAction SilentlyContinue | Out-String -Width 200 | Out-File $f -Append -Encoding UTF8
    Get-SmbMapping -ErrorAction SilentlyContinue | Out-String -Width 200 | Out-File $f -Append -Encoding UTF8
}

# --- Settings folders the config knows about --------------------------------
Invoke-Section 'Settings folders from config' {
    $rows = @()
    foreach ($sf in @($cfg.SettingsFolders)) {
        $paths = @(Resolve-ConfigPaths -Candidates $sf.Candidates)
        if ($paths.Count -eq 0) {
            $rows += [pscustomobject]@{ Name = $sf.Name; Path = '(not found)'; Files = 0; SizeMB = 0 }
            continue
        }
        foreach ($p in $paths) {
            $files = @(Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue)
            $bytes = ($files | Measure-Object Length -Sum).Sum
            if (-not $bytes) { $bytes = 0 }
            $rows += [pscustomobject]@{ Name = $sf.Name; Path = $p; Files = $files.Count; SizeMB = [math]::Round($bytes / 1MB, 1) }
        }
    }
    $rows | Export-Csv (Join-Path $out 'settings-folders.csv') -NoTypeInformation
    $missing = @($rows | Where-Object { $_.Path -eq '(not found)' } | ForEach-Object { $_.Name })
    $summary.Add('')
    $summary.Add("- **Settings folders found:** $(@($rows | Where-Object { $_.Path -ne '(not found)' }).Count) (settings-folders.csv)")
    if ($missing.Count -gt 0) { $summary.Add("- Settings folders NOT found (fix Candidates in config): $($missing -join ', ')") }
}

$summary | Set-Content (Join-Path $out 'SUMMARY.md') -Encoding UTF8
Write-Log "Done. Start with SUMMARY.md in $out" 'OK'
