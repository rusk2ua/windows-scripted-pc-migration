# Station config for windows-scripted-pc-migration.
# Copy this file to config\station.psd1 and edit it. station.psd1 is git-ignored.
# Paths may use these tokens so they work on both PCs:
#   %LOCALAPPDATA%  %APPDATA%  %DOCUMENTS%  %PROGRAMDATA%
#   %PROGRAMFILES%  %PROGRAMFILES(X86)%  %USERPROFILE%  %SYSTEMDRIVE%
# Wildcards (*) are allowed in Candidates.

@{
    # Where every script writes its reports, backups and logs.
    # Copy this whole folder from the old PC to the new PC before running 05/06.
    DataRoot = 'C:\ShackMigration'

    # Computer name of the OLD PC (as shown in its 01-Inventory SUMMARY.md).
    # 05-PortMap and 06-Restore read only that PC's inventory and backup, so
    # renaming the new PC part-way through cannot confuse them.
    OldComputerName = ''

    # ---------------------------------------------------------------------
    # Radios with serial-numbered USB ports (Icom shows them as e.g.
    # USB\VID_10C4&PID_EA60\IC-7610_12345678_A). Group = serial without _A/_B.
    # Name is used to suggest audio device names: "<Name> RX" and "<Name> TX".
    # ---------------------------------------------------------------------
    Radios = @(
        @{ Group = 'IC-7610_12345678'; Name = '7610-L' }
        @{ Group = 'IC-9700_12345679'; Name = '9700' }
    )
    # Set both to '' to give RX and TX the same name (e.g. 'IC-9700').
    AudioSuffixCapture = 'RX'
    AudioSuffixRender  = 'TX'

    # Devices WITHOUT a serial number (CH340 Arduino clones, some FTDI and
    # Prolific adapters). Windows ties their COM number to the physical port,
    # so capture each one by name on both PCs with:
    #   .\scripts\05-PortMap.ps1 -Capture -Label "<name>"
    Labels = @(
        'Keyer Nano'
        'FSK interface 1'
    )

    # ---------------------------------------------------------------------
    # Settings folders to back up (02) and restore (06).
    # Process: stop these before backup/restore. Restore = $false means
    # back up only. Sensitive = $true means the backup holds keys/passwords.
    # ExcludeDirs: folder names to skip anywhere inside (e.g. WSJT-X 'save' wav files).
    # ExcludeFiles: file patterns to skip (e.g. '*.wav').
    # ---------------------------------------------------------------------
    SettingsFolders = @(
        @{ Name = 'N1MM Logger+'; Candidates = @('%DOCUMENTS%\N1MM Logger+'); Process = @('N1MMLogger.net'); Restore = $true }
        @{ Name = 'WSJT-X'; Candidates = @('%LOCALAPPDATA%\WSJT-X*'); Process = @('wsjtx', 'jt9'); Restore = $true; ExcludeDirs = @('save') }
        @{ Name = 'TrustedQSL'; Candidates = @('%APPDATA%\TrustedQSL'); Process = @('tqsl'); Restore = $true; Sensitive = $true }
        @{ Name = 'AnyDesk user settings'; Candidates = @('%APPDATA%\AnyDesk'); Process = @(); Restore = $false; Sensitive = $true }
    )

    # HKCU registry keys to export (02). RestoreRegistry = $true imports them in 06.
    RegistryKeys = @(
        @{ Name = 'VB6 program settings'; Key = 'HKCU\Software\VB and VBA Program Settings'; RestoreRegistry = $false }
    )

    # Extra file patterns to sweep into the backup (searched recursively, depth-limited).
    FilePatterns = @(
        @{ Name = 'VSPE configs'; Root = '%DOCUMENTS%'; Pattern = '*.vspe' }
    )

    # ---------------------------------------------------------------------
    # Windows settings for station duty (03-Build.ps1).
    # ---------------------------------------------------------------------
    Build = @{
        NeverSleep                      = $true
        DisableUsbSelectiveSuspend      = $true
        DisablePcieLinkPowerManagement  = $true
        DisableFastStartup              = $true
        DisableUsbDevicePowerOff        = $true
        ExcludeDriversFromWindowsUpdate = $true
        PinFeatureUpdate                = $true
        NoAutoRebootWithLoggedOnUsers   = $true
        AUOptions                       = 3
        ActiveHoursStart                = 6
        ActiveHoursEnd                  = 23
    }

    # ---------------------------------------------------------------------
    # Apps (04-Apps.ps1). Scope 'machine' installs from an elevated window;
    # Scope 'user' installs from a NORMAL window (never elevated).
    # Pin = $true blocks winget upgrades until you remove the pin.
    # ---------------------------------------------------------------------
    WingetApps = @(
        @{ Id = 'Git.Git'; Scope = 'machine' }
        @{ Id = 'Notepad++.Notepad++'; Scope = 'machine' }
        @{ Id = 'AnyDesk.AnyDesk'; Scope = 'machine' }
    )

    # Installed by hand. Match = DisplayName wildcard used to check whether it is installed.
    ManualApps = @(
        @{ Name = 'N1MM Logger+'; Match = 'N1MM Logger+*'; Source = 'https://n1mmwp.hamdocs.com/'; Note = 'Install, then restore settings with 06' }
        @{ Name = 'WSJT-X'; Match = 'WSJT-X*'; Source = 'https://wsjt.sourceforge.io/'; Note = '' }
    )

    # ---------------------------------------------------------------------
    # Verification (07-Verify.ps1)
    # ---------------------------------------------------------------------
    Verify = @{
        Services         = @('W32Time')
        NtpServer        = 'time.windows.com'
        ClockWarnSeconds = 0.2
        ClockFailSeconds = 1.0
        MinFreePercent   = 15
        EventLogDays     = 7
    }
}
