# Changelog

Date-based versions (YYYY.MM.DD).

## 2026.11.18

- Audio endpoint names are read from the MMDevices registry (what Sound settings writes). `Get-PnpDevice` kept showing the old "N- USB Audio CODEC" names after a rename, so 07-Verify warned about correctly renamed devices.

## 2026.11.17

- `04-Apps`: warns when machine-scope apps are skipped because the window is not elevated (previously silent).
- `04-Apps`: when winget reports no installer for the requested scope (0x8A150010): from a normal window, retry without `--scope` (machine-only packages such as ArduinoSA.CLI); from an elevated window, never fall back to a per-user install - print the normal-window command instead (per-user-only packages such as K-Software.DXLog.net).
- New config setting `OldComputerName`: 05-PortMap and 06-Restore read only that PC's inventory/backup. Without it, renaming the new PC part-way through made its own earlier inventory look like the "old PC".

- Fix: `03-Build -Apply` and `06-Restore -Apply` applied their changes but failed to write `changes.json` ("Argument types do not match"), so `-Undo` had nothing to read. `Save-Json` now takes the list directly. Regression test added.

## 2026.11.16.2

- `02-Backup`: per-folder `ExcludeDirs` / `ExcludeFiles` (passed to robocopy and honoured in the size report). Example config skips the WSJT-X `save` folders, which held ~40 GB of .wav files on the first real run.
- `02-Backup`: a wildcard that matches a file (not a folder) is now backed up as a loose file instead of failing in robocopy.
- `02-Backup`: reports free space on the DataRoot drive and flags it when the backup would not fit.

## 2026.11.16 (fix 1)

- Device discovery uses cfgmgr32 for parent lookups instead of WMI. On the first real run, 01-Inventory stalled for 20+ minutes on a PC with many USB devices.
- Audio endpoints resolve through the MMDevices registry first; the slow all-properties WMI scan is now a last resort.
- 01-Inventory logs each section as it starts, with elapsed time, and device counts.

## 2026.11.16

First release.

- `01-Inventory`: COM ports with USB serials, audio endpoints grouped by radio, USB tree, programs, services, tasks, startup, drivers, power, time, network, settings-folder discovery.
- `02-Backup`: settings folders, HKCU registry keys and loose files, with SHA256 manifest; refuses to copy while listed apps are running.
- `03-Build`: station-duty power, USB and Windows Update settings with full undo.
- `04-Apps`: winget installs split by machine/user scope, pins, manual-install checklist.
- `05-PortMap`: label capture for serial-less devices, port plan with conflict detection, COM renumbering (disable, rewrite PortName and ComDB, re-enable) with undo, audio rename plan.
- `06-Restore`: hash-checked restore to per-PC paths, keeps existing copies, undo.
- `07-Verify`: station health check with exit codes.
- Unit tests for the pure functions (62 checks).
