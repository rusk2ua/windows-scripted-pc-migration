#Requires -Version 5.1
# Unit tests for the pure functions in scripts\lib\ShackMigration.psm1.
# No Pester needed. Runs on Windows PowerShell 5.1 and PowerShell 7 (also on Linux/macOS).
#   powershell -NoProfile -File .\tests\Run-Tests.ps1

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\lib\ShackMigration.psm1') -Force

$script:pass = 0
$script:fail = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ("$Expected" -ceq "$Actual") { $script:pass++ }
    else { $script:fail++; Write-Host "FAIL: $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red }
}
function Assert-True { param([bool]$Value, [string]$Name) Assert-Equal $true $Value $Name }

# --- Get-ComNumber -------------------------------------------------------------------
Assert-Equal 4 (Get-ComNumber 'Silicon Labs CP210x USB to UART Bridge (COM4)') 'COM from friendly name'
Assert-Equal 13 (Get-ComNumber 'COM13') 'COM from PortName'
Assert-Equal 22 (Get-ComNumber 'COM22') 'two-digit COM'
Assert-Equal '' (Get-ComNumber 'USB Audio CODEC') 'no COM'
Assert-Equal '' (Get-ComNumber $null) 'null input'

# --- Get-DeviceIdentity (real IDs from a station inventory) ------------------------------
$a = Get-DeviceIdentity 'USB\VID_10C4&PID_EA60\IC-7610_12001938_A'
Assert-Equal '10C4' $a.Vid 'Icom VID'
Assert-Equal 'EA60' $a.Pid 'Icom PID'
Assert-Equal 'IC-7610_12001938_A' $a.Serial 'Icom serial'
Assert-Equal 'IC-7610_12001938' $a.Group 'Icom group strips _A'
Assert-Equal '10C4:EA60:IC-7610_12001938_A' $a.Key 'Icom key'
$b = Get-DeviceIdentity 'USB\VID_10C4&PID_EA60\IC-7610_12001938_B'
Assert-Equal $a.Group $b.Group 'A and B ports share a group'
Assert-True ($a.Key -ne $b.Key) 'A and B ports have different keys'
$c = Get-DeviceIdentity 'USB\VID_1A86&PID_7523\7&1C18D6E6&0&4'
Assert-Equal $false $c.HasSerial 'CH340 has no serial'
Assert-Equal '' $c.Key 'CH340 has no key'
Assert-Equal '1A86' $c.Vid 'CH340 VID'
$d = Get-DeviceIdentity 'USB\VID_08BB&PID_2901&MI_00\9&F24853E&0&0000'
Assert-Equal '00' $d.Interface 'codec interface'
Assert-Equal $false $d.HasSerial 'interface child has no serial'
$e = Get-DeviceIdentity 'FTDIBUS\VID_0403+PID_6001+A50285BIA\0000'
Assert-Equal 'A50285BIA' $e.Serial 'FTDI serial'
Assert-Equal '0403:6001:A50285BIA' $e.Key 'FTDI key'
$f = Get-DeviceIdentity 'USB\VID_0C26&PID_0029\12001938'
Assert-Equal '12001938' $f.Serial 'numeric serial'

# --- Split-EndpointName / Get-EndpointFlow --------------------------------------------
$s = Split-EndpointName 'Microphone (6- USB Audio CODEC )'
Assert-Equal 'Microphone' $s.Name 'endpoint name'
Assert-Equal '6- USB Audio CODEC' $s.Device 'endpoint device'
$s2 = Split-EndpointName 'C27F398 (monitor 2) (Intel(R) Display Audio)'
Assert-Equal 'C27F398 (monitor 2)' $s2.Name 'nested parens name'
Assert-Equal 'Render' (Get-EndpointFlow 'SWD\MMDEVAPI\{0.0.0.00000000}.{2255FC88-ADEC-46F5-8AFA-5503977B7188}') 'render flow'
Assert-Equal 'Capture' (Get-EndpointFlow 'SWD\MMDEVAPI\{0.0.1.00000000}.{7D31D170-9B60-4D0A-8B1A-8168AB77B21F}') 'capture flow'

# --- ComDB bitmap ---------------------------------------------------------------------
$db = New-Object byte[] 32
$db = Set-ComDbBit -Bytes $db -Port 1 -InUse $true
Assert-Equal 1 $db[0] 'COM1 is bit 0 of byte 0'
$db = Set-ComDbBit -Bytes $db -Port 8 -InUse $true
Assert-Equal 129 $db[0] 'COM8 is bit 7 of byte 0'
$db = Set-ComDbBit -Bytes $db -Port 9 -InUse $true
Assert-Equal 1 $db[1] 'COM9 is bit 0 of byte 1'
$db = Set-ComDbBit -Bytes $db -Port 1 -InUse $false
Assert-Equal 128 $db[0] 'clear COM1 keeps COM8'
Assert-True (Test-ComDbBit -Bytes $db -Port 8) 'COM8 reserved'
Assert-True (-not (Test-ComDbBit -Bytes $db -Port 2)) 'COM2 free'
$short = [byte[]]@(0x01)
$grown = Set-ComDbBit -Bytes $short -Port 200 -InUse $true
Assert-Equal 32 $grown.Length 'short ComDB grows to 32 bytes'
Assert-True (Test-ComDbBit -Bytes $grown -Port 200) 'COM200 set'
Assert-True (Test-ComDbBit -Bytes $grown -Port 1) 'existing bit kept when growing'
# swap COM3 <-> COM5 must leave both reserved
$sw = New-Object byte[] 32
$sw = Set-ComDbBit -Bytes $sw -Port 3 -InUse $true
$sw = Set-ComDbBit -Bytes $sw -Port 5 -InUse $true
$moves = @([pscustomobject]@{ From = 3; To = 5 }, [pscustomobject]@{ From = 5; To = 3 })
$sw2 = Get-NewComDb -Current $sw -Moves $moves
Assert-True ((Test-ComDbBit $sw2 3) -and (Test-ComDbBit $sw2 5)) 'swap keeps both bits'
$mv = Get-NewComDb -Current $sw -Moves @([pscustomobject]@{ From = 5; To = 7 })
Assert-True ((-not (Test-ComDbBit $mv 5)) -and (Test-ComDbBit $mv 7) -and (Test-ComDbBit $mv 3)) 'move clears old, sets new, keeps others'
$threw = $false
try { Set-ComDbBit -Bytes $db -Port 0 -InUse $true | Out-Null } catch { $threw = $true }
Assert-True $threw 'COM0 rejected'

# --- Portable paths -------------------------------------------------------------------
$roots = @(
    [pscustomobject]@{ Token = '%LOCALAPPDATA%'; Path = 'C:\Users\op\AppData\Local' },
    [pscustomobject]@{ Token = '%APPDATA%'; Path = 'C:\Users\op\AppData\Roaming' },
    [pscustomobject]@{ Token = '%DOCUMENTS%'; Path = 'C:\Users\op\Documents' },
    [pscustomobject]@{ Token = '%PROGRAMFILES(X86)%'; Path = 'C:\Program Files (x86)' },
    [pscustomobject]@{ Token = '%PROGRAMFILES%'; Path = 'C:\Program Files' },
    [pscustomobject]@{ Token = '%USERPROFILE%'; Path = 'C:\Users\op' }
)
Assert-Equal '%LOCALAPPDATA%\WSJT-X - IC7610' (ConvertTo-PortablePath 'C:\Users\op\AppData\Local\WSJT-X - IC7610' $roots) 'to portable localappdata'
Assert-Equal '%DOCUMENTS%\N1MM Logger+' (ConvertTo-PortablePath 'C:\Users\op\Documents\N1MM Logger+' $roots) 'documents beats userprofile'
Assert-Equal '%PROGRAMFILES(X86)%\PstRotator' (ConvertTo-PortablePath 'C:\Program Files (x86)\PstRotator' $roots) 'x86 beats program files'
Assert-Equal '%PROGRAMFILES%\Foo' (ConvertTo-PortablePath 'C:\Program Files\Foo' $roots) 'program files'
Assert-Equal 'C:\Users\op2\x' (ConvertTo-PortablePath 'C:\Users\op2\x' $roots) 'no false prefix match'
$roots2 = @(
    [pscustomobject]@{ Token = '%LOCALAPPDATA%'; Path = 'C:\Users\rus\AppData\Local' },
    [pscustomobject]@{ Token = '%DOCUMENTS%'; Path = 'D:\Docs' },
    [pscustomobject]@{ Token = '%PROGRAMFILES(X86)%'; Path = 'C:\Program Files (x86)' },
    [pscustomobject]@{ Token = '%PROGRAMFILES%'; Path = 'C:\Program Files' }
)
Assert-Equal 'C:\Users\rus\AppData\Local\WSJT-X - IC7610' (ConvertFrom-PortablePath '%LOCALAPPDATA%\WSJT-X - IC7610' $roots2) 'from portable to another user'
Assert-Equal 'D:\Docs\N1MM Logger+' (ConvertFrom-PortablePath '%DOCUMENTS%\N1MM Logger+' $roots2) 'documents relocated'
Assert-Equal 'C:\Program Files (x86)\X' (ConvertFrom-PortablePath '%PROGRAMFILES(X86)%\X' $roots2) 'x86 token'
Assert-Equal 'C:\Program Files\X' (ConvertFrom-PortablePath '%PROGRAMFILES%\X' $roots2) 'program files token'

Assert-Equal 'N1MM_Logger' (Get-SafeName 'N1MM Logger+') 'safe name'

# --- Test-BackupExcluded ----------------------------------------------------------------
$root = 'C:\Users\op\AppData\Local\WSJT-X'
Assert-True (Test-BackupExcluded "$root\save\260101_120000.wav" $root @('save') @()) 'file in save excluded'
Assert-True (Test-BackupExcluded "$root\save\sub\x.wav" $root @('save') @()) 'nested file in save excluded'
Assert-True (-not (Test-BackupExcluded "$root\WSJT-X.ini" $root @('save') @())) 'ini kept'
Assert-True (-not (Test-BackupExcluded "$root\save.ini" $root @('save') @())) 'file named like the dir is kept'
Assert-True (Test-BackupExcluded "$root\ALL.TXT" $root @() @('ALL.TXT')) 'file pattern excluded'
Assert-True (Test-BackupExcluded "$root\x\a.wav" $root @() @('*.wav')) 'wildcard file pattern'
Assert-True (-not (Test-BackupExcluded "$root\x\a.wav" $root @() @())) 'nothing excluded by default'
Assert-True (-not (Test-BackupExcluded "$root\saved\a.txt" $root @('save') @())) 'saved is not save'

# --- New-PortPlan -----------------------------------------------------------------------
function New-P {
    param($Id, $Com, $Label = $null, $Name = 'dev')
    $i = Get-DeviceIdentity $Id
    [pscustomobject]@{ InstanceId = $Id; Com = $Com; Key = $i.Key; Vid = $i.Vid; Pid = $i.Pid; Interface = $i.Interface; Label = $Label; FriendlyName = "$Name (COM$Com)" }
}
$old = @(
    (New-P 'USB\VID_10C4&PID_EA60\IC-7610_12001938_A' 8 $null '7610 A'),
    (New-P 'USB\VID_10C4&PID_EA60\IC-7610_12001938_B' 7 $null '7610 B'),
    (New-P 'USB\VID_10C4&PID_EA60\IC-9700_12001419_A' 4 $null '9700 A'),
    (New-P 'USB\VID_1A86&PID_7523\7&1C18D6E6&0&4' 10 'Keyer Nano' 'CH340'),
    (New-P 'USB\VID_1A86&PID_7523\6&3AB6A6DF&0&2' 11 $null 'CH340')
)
$new = @(
    (New-P 'USB\VID_10C4&PID_EA60\IC-7610_12001938_A' 3 $null '7610 A'),
    (New-P 'USB\VID_10C4&PID_EA60\IC-7610_12001938_B' 4 $null '7610 B'),
    (New-P 'USB\VID_10C4&PID_EA60\IC-9700_12001419_A' 8 $null '9700 A'),
    (New-P 'USB\VID_1A86&PID_7523\5&AAAA&0&1' 5 'Keyer Nano' 'CH340'),
    (New-P 'USB\VID_1A86&PID_7523\5&BBBB&0&2' 6 $null 'CH340')
)
$plan = @(New-PortPlan -OldPorts $old -NewPorts $new -SerialCommNew @{ '\Device\Silabser0' = 'COM3'; '\Device\VSPE_SERIAL9' = 'COM9' })
function Get-Row { param($Plan, $Like) $Plan | Where-Object { $_.Device -like $Like } | Select-Object -First 1 }
$r = Get-Row $plan '7610 A*'
Assert-Equal 'Renumber' $r.Action '7610 A renumber'
Assert-Equal 'serial' $r.Basis '7610 A matched by serial'
Assert-Equal 8 $r.TargetCom '7610 A target COM8'
$r = Get-Row $plan '9700 A*'
Assert-Equal 'Renumber' $r.Action '9700 renumber into a COM another moving device frees (no conflict)'
$r = Get-Row $plan '*Keyer Nano*'
Assert-Equal 'label' $r.Basis 'Nano matched by label'
Assert-Equal 10 $r.TargetCom 'Nano target COM10'
$r = @($plan | Where-Object { $_.Action -eq 'Unmatched' })
Assert-Equal 1 $r.Count 'unlabelled CH340 unmatched'
Assert-True ($r[0].Note -like '*-Capture*') 'unmatched note tells you to capture'
$r = @($plan | Where-Object { $_.Action -eq 'NewOnly' })
Assert-Equal 1 $r.Count 'one new-only device'
Assert-True ($r[0].Note -like '*another device needs*' -or $r[0].Note -eq 'not on the old PC') 'new-only note'

# conflict: target held by a device that is NOT moving
$old2 = @((New-P 'USB\VID_10C4&PID_EA60\IC-9700_12001419_B' 6 $null '9700 B'))
$new2 = @(
    (New-P 'USB\VID_10C4&PID_EA60\IC-9700_12001419_B' 3 $null '9700 B'),
    (New-P 'USB\VID_1A86&PID_7523\5&CCCC&0&1' 6 $null 'stranger')
)
$plan2 = @(New-PortPlan -OldPorts $old2 -NewPorts $new2)
Assert-Equal 'Conflict' (Get-Row $plan2 '9700 B*').Action 'conflict with non-moving holder'

# conflict with a virtual port on the new PC
$old3 = @((New-P 'USB\VID_10C4&PID_EA60\IC-9700_12001419_B' 9 $null '9700 B'))
$new3 = @((New-P 'USB\VID_10C4&PID_EA60\IC-9700_12001419_B' 3 $null '9700 B'))
$plan3 = @(New-PortPlan -OldPorts $old3 -NewPorts $new3 -SerialCommNew @{ '\Device\VSPE_SERIAL9' = 'COM9' })
Assert-Equal 'Conflict' (Get-Row $plan3 '9700 B*').Action 'conflict with virtual port'

# already correct
$plan4 = @(New-PortPlan -OldPorts $old3 -NewPorts @((New-P 'USB\VID_10C4&PID_EA60\IC-9700_12001419_B' 9 $null '9700 B')))
Assert-Equal 'OK' (Get-Row $plan4 '9700 B*').Action 'already on target'

# two unlabelled-but-labelled identical devices map in a stable order
$old5 = @((New-P 'USB\VID_1A86&PID_7523\7&1&0&1' 10 'FSK' 'a'), (New-P 'USB\VID_1A86&PID_7523\7&1&0&2' 13 'FSK2' 'b'))
$new5 = @((New-P 'USB\VID_1A86&PID_7523\5&9&0&2' 4 'FSK2' 'b'), (New-P 'USB\VID_1A86&PID_7523\5&9&0&1' 5 'FSK' 'a'))
$plan5 = @(New-PortPlan -OldPorts $old5 -NewPorts $new5)
Assert-Equal 'USB\VID_1A86&PID_7523\5&9&0&1' (Get-Row $plan5 'a*').NewInstanceId 'label FSK picks its own device'
Assert-Equal 'USB\VID_1A86&PID_7523\5&9&0&2' (Get-Row $plan5 'b*').NewInstanceId 'label FSK2 picks its own device'

# --- Save-Json regression: a List[object] change log must save (03-Build bug, 2026-11-17) ---
$tmp = [IO.Path]::GetTempFileName()
$list = New-Object System.Collections.Generic.List[object]
$list.Add([pscustomobject]@{ Kind = 'Registry'; Before = [pscustomobject]@{ Exists = $false; Value = $null; Type = $null }; After = 1 })
$list.Add([pscustomobject]@{ Kind = 'Power'; Before = 1; After = 0 })
$threw = $false
try { Save-Json -Object $list.ToArray() -Path $tmp } catch { $threw = $true }
Assert-True (-not $threw) 'Save-Json accepts List.ToArray()'
Assert-Equal 2 (@(Read-Json -Path $tmp)).Count 'change log round-trips both items'
$threw = $false
try { Save-Json -Object $list -Path $tmp } catch { $threw = $true }
Assert-True (-not $threw) 'Save-Json accepts a List directly'
$one = New-Object System.Collections.Generic.List[object]
$one.Add([pscustomobject]@{ Kind = 'Power' })
Save-Json -Object $one.ToArray() -Path $tmp
Assert-True ((Get-Content -LiteralPath $tmp -Raw).TrimStart().StartsWith('[')) 'single-item log is still a JSON array'
Remove-Item -LiteralPath $tmp -Force

Write-Host ''
if ($script:fail -gt 0) { Write-Host "$script:pass passed, $script:fail FAILED" -ForegroundColor Red; exit 1 }
Write-Host "$script:pass passed, 0 failed" -ForegroundColor Green
exit 0
