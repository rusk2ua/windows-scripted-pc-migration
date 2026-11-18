# windows-scripted-pc-migration

PowerShell scripts that move a Windows ham-radio station PC to new hardware.
The new PC ends up with the **same COM port numbers**, **named audio devices**,
the **same app settings** and **station-duty Windows settings**. You can
repeat the process to build an identical spare.

Version **2026.11.16** · Windows PowerShell 5.1 (built into Windows 10/11) · MIT licence

## Why

A station PC talks to radios, keyers, FSK interfaces and rotators over a dozen
USB serial ports and several identical USB audio codecs. On a new PC every one of
them comes up on a different COM number. The codecs become "5-/6-/7- USB Audio
CODEC" in whatever order they were plugged in, and every program's port settings break.
These scripts record the old layout, rebuild it on the new PC and check the result.

## Safety model

- **Report first.** Every script only reports unless you add `-Apply`.
- **Everything logged.** Each run writes to `C:\ShackMigration\<date>_<host>\<step>\`
  (configurable). Changes are recorded with their previous values.
- **Undo.** `03-Build`, `05-PortMap` and `06-Restore` take `-Undo`.
- **Right privilege for each job.** Machine settings need an elevated window.
  Per-user settings and per-user apps run from a normal window and are never
  installed or upgraded from an elevated one.
- **The old PC is never modified.** On the old PC you only run inventory,
  label capture and backup.

## Scripts

| Script | Run on | Window | What it does |
|---|---|---|---|
| `01-Inventory.ps1` | both | elevated | COM ports (with USB serials), audio endpoints grouped by radio, USB tree, programs, services, tasks, startup, drivers, power, time, network |
| `02-Backup.ps1` | old | normal | Copies app settings folders, HKCU keys and loose files (e.g. `.vspe`) with a SHA256 manifest |
| `03-Build.ps1` | new | elevated | Never sleep, USB selective suspend off, PCIe power saving off, Fast Startup off, no USB device power-off, drivers excluded from Windows Update, feature version pinned, no auto-reboot while logged on |
| `04-Apps.ps1` | new | both | winget installs split by scope, pins for loggers, checklist of manual installs |
| `05-PortMap.ps1` | both | elevated for `-Apply` | Matches old and new ports (by USB serial, or by a label you capture), renumbers COM ports, tells you what to rename each audio device to |
| `06-Restore.ps1` | new | normal | Restores settings to the right paths for this PC; keeps any existing copy |
| `07-Verify.ps1` | both | elevated | Health check: COM ports, audio names, services, power, update policy, clock offset, disk health, recent USB/disk/power errors |

How the ports are matched:

- **USB serial number.** Icom radios report one, e.g.
  `USB\VID_10C4&PID_EA60\IC-7610_12345678_A`, so they match automatically.
- **Label you capture.** CH340 Arduino clones and similar adapters have no
  serial; Windows ties their COM number to the USB port. Run
  `05-PortMap.ps1 -Capture -Label "<name>"` on both PCs. The script records
  what appears when you replug the device.

## Quick start

```powershell
git clone https://github.com/rusk2ua/windows-scripted-pc-migration "$HOME\Documents\windows-scripted-pc-migration"
cd "$HOME\Documents\windows-scripted-pc-migration"
Copy-Item .\config\station.example.psd1 .\config\station.psd1
notepad .\config\station.psd1
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\01-Inventory.ps1
```

Then follow **[docs/runbook.md](docs/runbook.md)** phase by phase, and finish
with **[docs/on-air-checklist.md](docs/on-air-checklist.md)**.

`config\station.psd1` is git-ignored. It names your radios and labels, lists
the settings folders to carry over, and holds your app list.

## What has and hasn't been tested

- **Tested:** the pure logic is covered by `tests\Run-Tests.ps1` (74 checks,
  passing under PowerShell 7.4): device identity parsing, COM bitmap
  arithmetic including swaps, port-plan matching and conflicts, and path
  mapping between PCs. All scripts parse cleanly.
- **Not yet run on Windows hardware.** Device discovery, audio-to-radio grouping
  and COM renumbering need a real first run. Start with the report modes
  (they change nothing) and check the output before any `-Apply`.
- Audio devices are renamed by hand. Windows protects those registry keys, so
  the script tells you the names to use instead of changing them.
- English-language Windows is assumed where `powercfg` and `w32tm` output is parsed.

Run the tests:

```powershell
powershell -NoProfile -File .\tests\Run-Tests.ps1
```

## Related

- [windows-scripted-cleanup](https://github.com/rusk2ua/windows-scripted-cleanup):
  audit and bloat/telemetry cleanup for the same station PCs. Run it during
  Phase 1 of the runbook.

## Licence

MIT. See [LICENSE](LICENSE).
