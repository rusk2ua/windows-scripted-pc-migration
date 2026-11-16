# Changelog

Date-based versions (YYYY.MM.DD).

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
