# Migration runbook

Moving a Windows station PC (radios, keyers, rotator, FSK interfaces, virtual
ports) to new hardware without losing COM numbers, audio routing or app
settings. Every script is report-only unless you add `-Apply`.

Conventions below:

- **Elevated** = PowerShell opened with *Run as administrator*.
- **Normal** = ordinary PowerShell window, logged in as the station user.
- Allow the scripts in each new window first:
  `Set-ExecutionPolicy -Scope Process Bypass`

---

## Phase 0 - Old PC (nothing here changes the old PC)

1. Clone the repo and add your config:

   ```powershell
   git clone https://github.com/rusk2ua/windows-scripted-pc-migration "$HOME\Documents\windows-scripted-pc-migration"
   cd "$HOME\Documents\windows-scripted-pc-migration"
   Copy-Item .\config\station.example.psd1 .\config\station.psd1
   notepad .\config\station.psd1
   ```

2. **Inventory** (elevated):
   `.\scripts\01-Inventory.ps1`
   Read `SUMMARY.md` in the output folder. It lists every COM port, which
   radio each audio device belongs to, and any ports that have no serial number.

3. **Name the devices that have no serial number** (normal or elevated).
   CH340-based Arduinos and similar adapters get a COM number that depends
   on the USB port, so they cannot be matched automatically. For each one:

   ```powershell
   .\scripts\05-PortMap.ps1 -Capture -Label "Keyer Nano"
   ```

   Unplug it when asked, press Enter, plug it back in, press Enter. Use the
   same labels on the new PC. Run `01-Inventory.ps1` once more afterwards so
   the inventory carries the labels.

4. **Save virtual-port configs.** In VSPE: *File > Save as* into Documents
   (`*.vspe`). The backup picks these up.

5. **Back up settings** (normal window, station apps closed):

   ```powershell
   .\scripts\02-Backup.ps1
   .\scripts\02-Backup.ps1 -Apply
   ```

   Extra step for LoTW: in TQSL, also save each callsign certificate as a
   `.p12` file to a USB stick.

6. **Image the old drive** (Veeam Agent Free, Rescuezilla or similar). Then
   leave the old PC intact as your fallback for a few weeks.

7. Copy the whole `C:\ShackMigration` folder to a USB stick.

---

## Phase 1 - Build the new PC (radios unplugged)

1. **BIOS:** set *power on after AC loss* to On. Disable ErP/deep sleep if
   offered. Update firmware only if the vendor lists a fix you need.
2. **Optional:** replace the factory SSD with a known-brand NVMe.
3. **Clean Windows install** from Microsoft's media. Use a local account if
   Setup offers one.
4. **Windows Update until nothing is left**, including *Optional updates >
   Driver updates*. Install chipset/graphics drivers from the CPU vendor if
   Windows does not supply them. Do this BEFORE step 7, which stops Windows
   Update from installing drivers.
5. Copy `C:\ShackMigration` from the stick to the same path. Clone the repo and
   copy in your `station.psd1`. Set `OldComputerName` in it to the old PC's name.
   If you rename the new PC, do it now, before running any script.
6. Baseline inventory (elevated): `.\scripts\01-Inventory.ps1`
7. **Station settings** (elevated):

   ```powershell
   .\scripts\03-Build.ps1
   .\scripts\03-Build.ps1 -Apply
   Restart-Computer
   ```

   Undo at any time with `.\scripts\03-Build.ps1 -Undo`.

8. Run [windows-scripted-cleanup](https://github.com/rusk2ua/windows-scripted-cleanup)
   for telemetry and bloat.
9. **Drivers by hand first**: Silicon Labs CP210x (the Icom USB driver), WCH
   CH340, VB-CABLE, VSPE. Then apps:

   ```powershell
   .\scripts\04-Apps.ps1
   .\scripts\04-Apps.ps1 -Apply
   ```

   Run `-Apply` once elevated (machine apps and pins) and once in a normal
   window (per-user apps). Work through `manual-installs.md` in the output
   folder for everything winget does not carry.

---

## Phase 2 - Bring the station across, one radio at a time

For each radio (and its keyer/FSK/rotator devices):

1. Plug it into the port/hub position it will keep permanently.
2. For each device with no serial number, capture it with the same label you
   used on the old PC: `.\scripts\05-PortMap.ps1 -Capture -Label "Keyer Nano"`
3. Report: `.\scripts\05-PortMap.ps1`, then read `PORTMAP.md`.
   - **Renumber**: will be fixed by `-Apply`.
   - **Unmatched**: plug it in, or capture its label on both PCs.
   - **Conflict**: something else holds the target COM. Move it, or remove a
     stale VSPE pair, then rerun.
4. Close all station apps, then (elevated): `.\scripts\05-PortMap.ps1 -Apply`
   Undo: `.\scripts\05-PortMap.ps1 -Undo`
5. **Rename audio devices** as listed in `PORTMAP.md` (`mmsys.cpl`; Playback =
   TX, Recording = RX). Windows numbers identical USB codecs ("5- USB Audio
   CODEC") by plug order. Named devices stay put.
6. Load your `.vspe` file in VSPE so the virtual ports come back on the same numbers.

When all radios are across:

7. **Restore settings** (normal window, apps closed):

   ```powershell
   .\scripts\06-Restore.ps1
   .\scripts\06-Restore.ps1 -Apply
   ```

   Existing folders are kept as `*.pre-restore-<time>`. Undo with `-Undo`.
8. Open each app. Re-select audio devices by their new names. COM numbers
   already match the old PC.
9. Check: `.\scripts\07-Verify.ps1`

---

## Phase 3 - Prove it on the air

Work through [on-air-checklist.md](on-air-checklist.md): CAT, keying, FSK,
audio, rotator and remote access on every radio. Then full power on every band, and
a pulled-plug power-loss test. Run `07-Verify.ps1` after the RF test.
It reports any USB, disk or unexpected-shutdown errors logged during it.

---

## Phase 4 - Cut over and build the spare

1. Switch over in a quiet week, not a contest weekend. Keep the old PC
   untouched for 2-4 weeks.
2. Image the finished new PC. That image is your known-good restore point.
3. Build the spare PC with the same runbook and the same `station.psd1`. The
   COM numbers then match, so a swap means moving cables only.
4. Run `07-Verify.ps1` after Windows updates and any time something acts up.

## Remote-access notes

- **AnyDesk:** the new PC gets a new AnyDesk ID. The backup keeps the old
  settings but does not restore them (`Restore = $false`), so the two PCs
  never share an ID. Set unattended access again and update your address book.
- **Tailscale / Splashtop / Sophos:** sign in fresh on the new PC.
- After the power-loss test, confirm remote access works **before** you sign in locally.
