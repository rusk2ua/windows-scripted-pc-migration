#Requires -Version 5.1
# Shared helpers for windows-scripted-pc-migration.
# Written for Windows PowerShell 5.1 (the version built into Windows 10/11).
# Keep this file ASCII-only: 5.1 reads BOM-less files as ANSI.

Set-StrictMode -Version 2.0

$script:ToolVersion = '2026.11.16'
$script:LogFile = $null

function Get-ToolVersion { return $script:ToolVersion }

function Get-RepoRoot {
    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------

function Test-IsAdmin {
    if ($env:OS -ne 'Windows_NT') { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    param([string]$Why = 'this step changes machine-wide settings')
    if (-not (Test-IsAdmin)) {
        throw "Run this from an elevated PowerShell window ($Why)."
    }
}

# ---------------------------------------------------------------------------
# Config and run folders
# ---------------------------------------------------------------------------

function Import-StationConfig {
    param([string]$Path)
    if (-not $Path) {
        $Path = Join-Path (Get-RepoRoot) 'config\station.psd1'
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Warning 'config\station.psd1 not found. Using config\station.example.psd1. Copy it to station.psd1 and edit it for your station.'
            $Path = Join-Path (Get-RepoRoot) 'config\station.example.psd1'
        }
    }
    $cfg = Import-PowerShellDataFile -Path $Path
    $cfg['_Path'] = $Path
    if (-not $cfg.ContainsKey('DataRoot') -or -not $cfg.DataRoot) { $cfg['DataRoot'] = 'C:\ShackMigration' }
    return $cfg
}

function Get-HostFolder {
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    return (Join-Path $Config.DataRoot ('{0}_{1}' -f (Get-Date -Format 'yyyy-MM-dd'), $env:COMPUTERNAME))
}

function New-RunFolder {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Step
    )
    $base = Get-HostFolder -Config $Config
    $dir = Join-Path $base $Step
    if (Test-Path -LiteralPath $dir) {
        $dir = Join-Path $base ('{0}_{1}' -f $Step, (Get-Date -Format 'HHmmss'))
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function Find-LatestRunFolder {
    # Newest folder named like <date>_<host>\<Step>* that contains $MustContain.
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Step,
        [string]$MustContain,
        [string]$HostName,
        [switch]$OtherHost
    )
    if (-not (Test-Path -LiteralPath $Config.DataRoot)) { return $null }
    $hostDirs = Get-ChildItem -LiteralPath $Config.DataRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_(.+)$' }
    $candidates = @()
    foreach ($h in $hostDirs) {
        $null = $h.Name -match '^\d{4}-\d{2}-\d{2}_(.+)$'
        $hn = $Matches[1]
        if ($HostName -and $hn -ne $HostName) { continue }
        if ($OtherHost -and $hn -eq $env:COMPUTERNAME) { continue }
        $candidates += @(Get-ChildItem -LiteralPath $h.FullName -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$Step*" } |
            Where-Object { -not $MustContain -or (Test-Path -LiteralPath (Join-Path $_.FullName $MustContain)) })
    }
    if ($candidates.Count -eq 0) { return $null }
    return ($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Start-StepLog {
    param([Parameter(Mandatory = $true)][string]$Folder, [Parameter(Mandatory = $true)][string]$Step)
    $script:LogFile = Join-Path $Folder 'run.log'
    Write-Log ('{0}  v{1}  host={2}  user={3}  admin={4}' -f $Step, $script:ToolVersion, $env:COMPUTERNAME, $env:USERNAME, (Test-IsAdmin))
    Write-Log "Output folder: $Folder"
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'ACTION', 'PLAN')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
    $color = 'Gray'
    switch ($Level) {
        'WARN'   { $color = 'Yellow' }
        'ERROR'  { $color = 'Red' }
        'OK'     { $color = 'Green' }
        'ACTION' { $color = 'Cyan' }
        'PLAN'   { $color = 'White' }
    }
    Write-Host $line -ForegroundColor $color
}

function Save-Json {
    param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Path)
    $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-Json {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# Portable paths: %LOCALAPPDATA%\WSJT-X on one PC -> same place on another
# ---------------------------------------------------------------------------

function Get-KnownRoots {
    $docs = $null
    try { $docs = [Environment]::GetFolderPath('MyDocuments') } catch { }
    $pairs = @(
        @('%LOCALAPPDATA%', $env:LOCALAPPDATA),
        @('%APPDATA%', $env:APPDATA),
        @('%DOCUMENTS%', $docs),
        @('%PROGRAMDATA%', $env:ProgramData),
        @('%PROGRAMFILES(X86)%', ${env:ProgramFiles(x86)}),
        @('%PROGRAMFILES%', $env:ProgramFiles),
        @('%USERPROFILE%', $env:USERPROFILE),
        @('%SYSTEMDRIVE%', $env:SystemDrive)
    )
    $list = @()
    foreach ($p in $pairs) {
        if ($p[1]) { $list += [pscustomobject]@{ Token = $p[0]; Path = ([string]$p[1]).TrimEnd('\') } }
    }
    return $list
}

function ConvertTo-PortablePath {
    param([Parameter(Mandatory = $true)][string]$Path, [object[]]$Roots)
    if (-not $Roots) { $Roots = Get-KnownRoots }
    foreach ($r in $Roots) {
        if ($Path -ieq $r.Path) { return $r.Token }
        if ($Path.StartsWith($r.Path + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $r.Token + $Path.Substring($r.Path.Length)
        }
    }
    return $Path
}

function ConvertFrom-PortablePath {
    param([Parameter(Mandatory = $true)][string]$Path, [object[]]$Roots)
    if (-not $Roots) { $Roots = Get-KnownRoots }
    foreach ($r in $Roots) {
        if ($Path.StartsWith($r.Token, [StringComparison]::OrdinalIgnoreCase)) {
            return $r.Path + $Path.Substring($r.Token.Length)
        }
    }
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Resolve-ConfigPaths {
    # Expands tokens and wildcards; returns only paths that exist.
    param([string[]]$Candidates, [object[]]$Roots)
    $found = @()
    foreach ($c in $Candidates) {
        if (-not $c) { continue }
        $expanded = ConvertFrom-PortablePath -Path $c -Roots $Roots
        if ($expanded -match '[\*\?]') {
            $found += @(Get-Item -Path $expanded -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        }
        elseif (Test-Path -LiteralPath $expanded) {
            $found += (Get-Item -LiteralPath $expanded -Force).FullName
        }
    }
    return @($found | Select-Object -Unique)
}

function Get-SafeName {
    param([Parameter(Mandatory = $true)][string]$Name)
    return ($Name -replace '[^A-Za-z0-9\-\.]+', '_').Trim('_')
}

# ---------------------------------------------------------------------------
# Device identity (pure functions - unit tested)
# ---------------------------------------------------------------------------

function Get-ComNumber {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($Text -and $Text -match '\bCOM(\d{1,3})\b') { return [int]$Matches[1] }
    return $null
}

function Get-DeviceIdentity {
    # USB\VID_10C4&PID_EA60\IC-7610_12001938_A  -> serial IC-7610_12001938_A, group IC-7610_12001938
    # USB\VID_1A86&PID_7523\7&1C18D6E6&0&4      -> no serial (Windows-generated, depends on port)
    # FTDIBUS\VID_0403+PID_6001+A1B2C3D4A\0000   -> serial A1B2C3D4A
    param([Parameter(Mandatory = $true)][string]$InstanceId)
    $parts = $InstanceId -split '\\'
    $enum = $parts[0].ToUpper()
    $hw = ''
    $inst = ''
    if ($parts.Count -gt 1) { $hw = $parts[1] }
    if ($parts.Count -gt 2) { $inst = ($parts[2..($parts.Count - 1)] -join '\') }
    $vid = $null; $productId = $null; $mi = $null; $serial = $null
    if ($hw -match 'VID_([0-9A-Fa-f]{4})') { $vid = $Matches[1].ToUpper() }
    if ($hw -match 'PID_([0-9A-Fa-f]{4})') { $productId = $Matches[1].ToUpper() }
    if ($hw -match 'MI_([0-9A-Fa-f]{2})') { $mi = $Matches[1].ToUpper() }
    if ($enum -eq 'FTDIBUS') {
        if ($hw -match 'PID_[0-9A-Fa-f]{4}\+([^\\+]+)') { $serial = $Matches[1] }
    }
    elseif ($enum -eq 'USB' -and $inst -and ($inst -notmatch '&') -and (-not $mi)) {
        $serial = $inst
    }
    $key = $null
    $group = $null
    if ($serial) {
        $key = '{0}:{1}:{2}' -f $vid, $productId, $serial
        if ($mi) { $key = '{0}:MI_{1}' -f $key, $mi }
        $group = ($serial -replace '_[A-Z]$', '')
    }
    return [pscustomobject]@{
        InstanceId = $InstanceId
        Enumerator = $enum
        Vid        = $vid
        Pid        = $productId
        Interface  = $mi
        Serial     = $serial
        HasSerial  = [bool]$serial
        Key        = $key
        Group      = $group
    }
}

function Split-EndpointName {
    # "Microphone (6- USB Audio CODEC )" -> Name "Microphone", Device "6- USB Audio CODEC"
    param([AllowNull()][AllowEmptyString()][string]$FriendlyName)
    # Device part is the LAST parenthesised group; it may itself contain one level, e.g. Intel(R).
    if ($FriendlyName -and $FriendlyName -match '^(.*) \(([^()]*(?:\([^()]*\)[^()]*)*)\)\s*$') {
        return [pscustomobject]@{ Name = $Matches[1].Trim(); Device = $Matches[2].Trim() }
    }
    return [pscustomobject]@{ Name = $FriendlyName; Device = '' }
}

function Get-EndpointFlow {
    param([Parameter(Mandatory = $true)][string]$InstanceId)
    if ($InstanceId -match '\{0\.0\.0\.') { return 'Render' }
    if ($InstanceId -match '\{0\.0\.1\.') { return 'Capture' }
    return 'Unknown'
}

# ---------------------------------------------------------------------------
# COM Name Arbiter bitmap (pure - unit tested)
# ---------------------------------------------------------------------------

function Test-ComDbBit {
    param([byte[]]$Bytes, [Parameter(Mandatory = $true)][int]$Port)
    if (-not $Bytes) { return $false }
    $i = [int][Math]::Floor(($Port - 1) / 8)
    if ($i -ge $Bytes.Length) { return $false }
    return [bool]($Bytes[$i] -band (1 -shl (($Port - 1) % 8)))
}

function Set-ComDbBit {
    param([byte[]]$Bytes, [Parameter(Mandatory = $true)][int]$Port, [Parameter(Mandatory = $true)][bool]$InUse)
    if ($Port -lt 1 -or $Port -gt 256) { throw "COM$Port is out of range (1-256)" }
    if (-not $Bytes) { $Bytes = New-Object byte[] 32 }
    $copy = New-Object byte[] ([Math]::Max(32, $Bytes.Length))
    [Array]::Copy($Bytes, $copy, $Bytes.Length)
    $i = [int][Math]::Floor(($Port - 1) / 8)
    $mask = [int](1 -shl (($Port - 1) % 8))
    if ($InUse) { $copy[$i] = [byte]($copy[$i] -bor $mask) }
    else { $copy[$i] = [byte]($copy[$i] -band (0xFF -bxor $mask)) }
    return , $copy
}

function Get-NewComDb {
    # Clear every "from" bit first, then set every "to" bit, so swaps keep both bits set.
    param([byte[]]$Current, [object[]]$Moves)
    $db = $Current
    foreach ($m in $Moves) { $db = Set-ComDbBit -Bytes $db -Port ([int]$m.From) -InUse $false }
    foreach ($m in $Moves) { $db = Set-ComDbBit -Bytes $db -Port ([int]$m.To) -InUse $true }
    return , $db
}

# ---------------------------------------------------------------------------
# Port plan (pure - unit tested)
# ---------------------------------------------------------------------------

function New-PortPlan {
    # OldPorts / NewPorts: objects with InstanceId, Com, Key, Vid, Pid, Interface, Label, FriendlyName.
    # SerialCommNew: hashtable device-name -> 'COMn' for the new PC (includes virtual ports).
    param(
        [object[]]$OldPorts,
        [object[]]$NewPorts,
        [hashtable]$SerialCommNew
    )
    if (-not $OldPorts) { $OldPorts = @() }
    if (-not $NewPorts) { $NewPorts = @() }
    if (-not $SerialCommNew) { $SerialCommNew = @{} }
    $used = @{}
    $rows = @()
    foreach ($old in ($OldPorts | Sort-Object Com)) {
        $match = $null
        $basis = ''
        if ($old.Key) {
            $match = $NewPorts | Where-Object { $_.Key -eq $old.Key -and -not $used.ContainsKey($_.InstanceId) } | Select-Object -First 1
            if ($match) { $basis = 'serial' }
        }
        if (-not $match -and $old.Label) {
            $match = $NewPorts | Where-Object {
                $_.Label -eq $old.Label -and $_.Vid -eq $old.Vid -and $_.Pid -eq $old.Pid -and
                $_.Interface -eq $old.Interface -and -not $used.ContainsKey($_.InstanceId)
            } | Sort-Object InstanceId | Select-Object -First 1
            if ($match) { $basis = 'label' }
        }
        $name = $old.FriendlyName
        if ($old.Label) { $name = '{0} [{1}]' -f $old.FriendlyName, $old.Label }
        if (-not $match) {
            $hint = 'no serial number: run 05-PortMap.ps1 -Capture -Label "<name>" on BOTH PCs'
            if ($old.Key) { $hint = 'device not plugged into this PC yet' }
            $rows += [pscustomobject]@{
                Device = $name; OldCom = $old.Com; NewCom = $null; TargetCom = $old.Com
                Basis = ''; Action = 'Unmatched'; Note = $hint
                OldInstanceId = $old.InstanceId; NewInstanceId = $null; Key = $old.Key; Label = $old.Label
            }
            continue
        }
        $used[$match.InstanceId] = $true
        $action = 'OK'
        if ([int]$match.Com -ne [int]$old.Com) { $action = 'Renumber' }
        $rows += [pscustomobject]@{
            Device = $name; OldCom = $old.Com; NewCom = $match.Com; TargetCom = $old.Com
            Basis = $basis; Action = $action; Note = ''
            OldInstanceId = $old.InstanceId; NewInstanceId = $match.InstanceId; Key = $old.Key; Label = $old.Label
        }
    }
    # Conflicts: a target COM held by something that is not itself being moved away.
    $moving = @{}
    foreach ($r in $rows) { if ($r.Action -eq 'Renumber') { $moving[[int]$r.NewCom] = $true } }
    $targets = @{}
    foreach ($r in $rows) { if ($r.Action -eq 'Renumber') { $targets[[int]$r.TargetCom] = $true } }
    $holders = @{}
    foreach ($p in $NewPorts) { if ($p.Com) { $holders[[int]$p.Com] = $p.FriendlyName } }
    foreach ($k in $SerialCommNew.Keys) {
        $n = Get-ComNumber $SerialCommNew[$k]
        if ($n -and -not $holders.ContainsKey($n)) { $holders[$n] = $k }
    }
    foreach ($r in $rows) {
        if ($r.Action -ne 'Renumber') { continue }
        $t = [int]$r.TargetCom
        if ($holders.ContainsKey($t) -and -not $moving.ContainsKey($t)) {
            $r.Action = 'Conflict'
            $r.Note = "COM$t is held by '$($holders[$t])' on this PC"
        }
    }
    # Devices on the new PC that the old PC never had.
    foreach ($p in $NewPorts) {
        if (-not $used.ContainsKey($p.InstanceId)) {
            $note = 'not on the old PC'
            if ($targets.ContainsKey([int]$p.Com)) { $note = "not on the old PC and sits on COM$($p.Com), which another device needs" }
            $rows += [pscustomobject]@{
                Device = $p.FriendlyName; OldCom = $null; NewCom = $p.Com; TargetCom = $null
                Basis = ''; Action = 'NewOnly'; Note = $note
                OldInstanceId = $null; NewInstanceId = $p.InstanceId; Key = $p.Key; Label = $p.Label
            }
        }
    }
    return $rows
}

# ---------------------------------------------------------------------------
# Live device discovery (Windows only)
# ---------------------------------------------------------------------------

function Get-DeviceParent {
    param([Parameter(Mandatory = $true)][string]$InstanceId)
    try {
        $p = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop
        if ($p -and $p.Data) { return [string]$p.Data }
    }
    catch { }
    return $null
}

function Get-DeviceAncestors {
    param([Parameter(Mandatory = $true)][string]$InstanceId, [int]$Max = 12)
    $chain = @()
    $cur = $InstanceId
    for ($i = 0; $i -lt $Max; $i++) {
        $p = Get-DeviceParent -InstanceId $cur
        if (-not $p -or $p -like 'HTREE\ROOT*') { break }
        $chain += $p
        $cur = $p
    }
    return $chain
}

function Get-DeviceLocationPath {
    param([Parameter(Mandatory = $true)][string]$InstanceId)
    try {
        $p = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_LocationPaths' -ErrorAction Stop
        if ($p -and $p.Data) { return (@($p.Data) -join ' | ') }
    }
    catch { }
    return $null
}

function Get-PortNameFromRegistry {
    param([Parameter(Mandatory = $true)][string]$InstanceId)
    $k = "HKLM:\SYSTEM\CurrentControlSet\Enum\$InstanceId\Device Parameters"
    try { return [string](Get-ItemProperty -LiteralPath $k -Name PortName -ErrorAction Stop).PortName } catch { return $null }
}

function Get-SerialCommMap {
    $map = @{}
    $k = 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM'
    if (Test-Path -LiteralPath $k) {
        $item = Get-ItemProperty -LiteralPath $k
        foreach ($p in $item.PSObject.Properties) {
            if ($p.Name -notlike 'PS*') { $map[$p.Name] = [string]$p.Value }
        }
    }
    return $map
}

function Get-EndpointFunctionDevice {
    # Finds the USB audio function behind a Windows audio endpoint (best effort, three methods).
    param([Parameter(Mandatory = $true)][string]$EndpointInstanceId)
    $rx = '(USB\\VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4}[^\s\}\x00]*)'
    $parent = Get-DeviceParent -InstanceId $EndpointInstanceId
    if ($parent -and $parent -match '^USB\\') { return $parent.ToUpper() }
    try {
        $props = Get-PnpDeviceProperty -InstanceId $EndpointInstanceId -ErrorAction Stop
        foreach ($p in $props) {
            foreach ($v in @($p.Data)) {
                if ($v -is [string] -and $v -match $rx) { return $Matches[1].ToUpper() }
            }
        }
    }
    catch { }
    if ($EndpointInstanceId -match '\}\.(\{[0-9A-Fa-f\-]+\})$') {
        $guid = $Matches[1]
        foreach ($flow in @('Render', 'Capture')) {
            $k = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$flow\$guid\Properties"
            if (Test-Path -LiteralPath $k) {
                $item = Get-ItemProperty -LiteralPath $k
                foreach ($prop in $item.PSObject.Properties) {
                    $v = $prop.Value
                    if ($v -is [string] -and $v -match $rx) { return $Matches[1].ToUpper() }
                }
            }
        }
    }
    return $parent
}

function Get-LabelFilePath {
    param([Parameter(Mandatory = $true)][hashtable]$Config, [string]$HostName = $env:COMPUTERNAME)
    return (Join-Path (Join-Path $Config.DataRoot 'labels') "$HostName.json")
}

function Read-Labels {
    # Returns hashtable InstanceId -> Label for one host.
    param([Parameter(Mandatory = $true)][hashtable]$Config, [string]$HostName = $env:COMPUTERNAME)
    $result = @{}
    $f = Get-LabelFilePath -Config $Config -HostName $HostName
    if (-not (Test-Path -LiteralPath $f)) { return $result }
    $data = Read-Json -Path $f
    foreach ($entry in @($data.Captures)) {
        foreach ($d in @($entry.Devices)) { $result[[string]$d.InstanceId] = [string]$entry.Label }
    }
    return $result
}

function Get-StationDeviceMap {
    # Snapshot of serial ports and audio endpoints, grouped by radio where possible.
    param([hashtable]$Labels)
    if (-not $Labels) { $Labels = @{} }
    $ports = @()
    foreach ($d in @(Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue)) {
        $id = Get-DeviceIdentity -InstanceId $d.InstanceId
        $portName = Get-PortNameFromRegistry -InstanceId $d.InstanceId
        $com = Get-ComNumber $portName
        if (-not $com) { $com = Get-ComNumber $d.FriendlyName }
        $anc = @(Get-DeviceAncestors -InstanceId $d.InstanceId)
        $parent = $null
        if ($anc.Count -gt 0) { $parent = $anc[0] }
        $label = $null
        if ($Labels.ContainsKey($d.InstanceId)) { $label = $Labels[$d.InstanceId] }
        $ports += [pscustomobject]@{
            Kind = 'Port'; InstanceId = $d.InstanceId; FriendlyName = $d.FriendlyName; Status = [string]$d.Status
            Com = $com; Vid = $id.Vid; Pid = $id.Pid; Interface = $id.Interface; Serial = $id.Serial
            Key = $id.Key; Group = $id.Group; Label = $label; Parent = $parent; Ancestors = $anc
            LocationPath = (Get-DeviceLocationPath -InstanceId $d.InstanceId)
        }
    }
    $audio = @()
    foreach ($e in @(Get-PnpDevice -PresentOnly -Class AudioEndpoint -ErrorAction SilentlyContinue)) {
        $func = Get-EndpointFunctionDevice -EndpointInstanceId $e.InstanceId
        $chain = @()
        if ($func) { $chain = @($func) + @(Get-DeviceAncestors -InstanceId $func) }
        $group = $null
        foreach ($p in $ports) {
            if ($p.Group -and $p.Parent -and ($chain -contains $p.Parent)) { $group = $p.Group; break }
        }
        $split = Split-EndpointName -FriendlyName $e.FriendlyName
        $label = $null
        if ($Labels.ContainsKey($e.InstanceId)) { $label = $Labels[$e.InstanceId] }
        if (-not $group -and $label) {
            # A labelled endpoint shares its label with any labelled port.
            $group = "label:$label"
        }
        $audio += [pscustomobject]@{
            Kind = 'Audio'; InstanceId = $e.InstanceId; FriendlyName = $e.FriendlyName; Status = [string]$e.Status
            Flow = (Get-EndpointFlow -InstanceId $e.InstanceId); EndpointName = $split.Name; DeviceName = $split.Device
            FunctionDevice = $func; Group = $group; Label = $label
        }
    }
    return [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        Captured     = (Get-Date).ToString('s')
        ToolVersion  = $script:ToolVersion
        SerialComm   = (Get-SerialCommMap)
        Ports        = $ports
        Audio        = $audio
    }
}

# ---------------------------------------------------------------------------
# Installed programs (registry - faster and more complete than winget list)
# ---------------------------------------------------------------------------

function Get-InstalledPrograms {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $out = @()
    foreach ($k in $keys) {
        $scope = 'Machine'
        if ($k -like 'HKCU:*') { $scope = 'User' }
        foreach ($i in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)) {
            $dn = $null
            if ($i.PSObject.Properties['DisplayName']) { $dn = $i.DisplayName }
            if (-not $dn) { continue }
            $ver = $null; $pub = $null; $loc = $null
            if ($i.PSObject.Properties['DisplayVersion']) { $ver = $i.DisplayVersion }
            if ($i.PSObject.Properties['Publisher']) { $pub = $i.Publisher }
            if ($i.PSObject.Properties['InstallLocation']) { $loc = $i.InstallLocation }
            $out += [pscustomobject]@{ Name = $dn; Version = $ver; Publisher = $pub; Scope = $scope; InstallLocation = $loc }
        }
    }
    return ($out | Sort-Object Name -Unique)
}

# ---------------------------------------------------------------------------
# Registry and power helpers with before/after capture
# ---------------------------------------------------------------------------

function Get-RegistryValueState {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Exists = $false; Value = $null; Type = $null } }
    $key = Get-Item -LiteralPath $Path
    $names = @($key.GetValueNames())
    if ($names -notcontains $Name) { return [pscustomobject]@{ Exists = $false; Value = $null; Type = $null } }
    $val = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
    $kind = [string]$key.GetValueKind($Name)
    return [pscustomobject]@{ Exists = $true; Value = $val; Type = $kind }
}

function Set-RegistryValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [ValidateSet('DWord', 'String', 'QWord', 'Binary', 'ExpandString', 'MultiString')][string]$Type = 'DWord'
    )
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Get-PowerIndex {
    # Returns the AC index of a power setting on the active scheme, or $null.
    param([Parameter(Mandatory = $true)][string]$SubGroup, [Parameter(Mandatory = $true)][string]$Setting)
    $text = & powercfg.exe /query SCHEME_CURRENT $SubGroup $Setting 2>$null
    foreach ($line in @($text)) {
        if ($line -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') {
            return [Convert]::ToInt32($Matches[1], 16)
        }
    }
    return $null
}

function Set-PowerIndex {
    param([Parameter(Mandatory = $true)][string]$SubGroup, [Parameter(Mandatory = $true)][string]$Setting, [Parameter(Mandatory = $true)][int]$Value)
    & powercfg.exe /setacvalueindex SCHEME_CURRENT $SubGroup $Setting $Value | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
}

# Power setting GUIDs (documented by Microsoft; same on Windows 10 and 11)
$script:PowerSettings = @{
    StandbyIdle   = @{ Sub = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; Label = 'Sleep after (seconds)' }
    HibernateIdle = @{ Sub = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting = '9d7815a6-7ee4-497e-8888-515a05f02364'; Label = 'Hibernate after (seconds)' }
    UsbSuspend    = @{ Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Label = 'USB selective suspend (1=on)' }
    PcieAspm      = @{ Sub = '501a4d13-42af-4429-9fd1-a8218c268e20'; Setting = 'ee12f906-d277-404b-b6da-e5fa1a576df5'; Label = 'PCIe link state power mgmt (0=off)' }
    DiskIdle      = @{ Sub = '0012ee47-9041-4b5d-9b77-535fba8b1442'; Setting = '6738e2c4-e8a5-4a42-b16a-e040e769756e'; Label = 'Turn off disk after (seconds)' }
}

function Get-PowerSettingTable { return $script:PowerSettings }

Export-ModuleMember -Function * -Variable @()
