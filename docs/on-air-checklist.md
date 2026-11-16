# On-air checklist

The scripts check what Windows can see. This list covers what only RF and
your ears can prove. Do it per radio, into a dummy load where appropriate.

## Per radio

- [ ] CAT: the logger follows band/frequency/mode changes made on the radio, and the reverse
- [ ] PTT from the logger (and from WSJT-X if it keys this radio)
- [ ] CW keying through the SO2R box / WinKeyer emulation, both radios, at operating speed
- [ ] FSK keying through each FSK interface (RTTY, both radios)
- [ ] RX audio into WSJT-X/JTDX/MSHV: levels sensible, decodes appear
- [ ] TX audio: clean, correct level, no ALC overshoot (dummy load)
- [ ] Second COM port on each Icom (if used), e.g. for a second program
- [ ] I/Q or spectrum software (if used)

## Station-wide

- [ ] Rotator: turn, stop and position readback from the rotator software and the logger
- [ ] Amplifier control/telemetry software (if used)
- [ ] Virtual serial ports carry data between the programs that share a radio
- [ ] Clock offset under 0.2 s (`07-Verify.ps1`), FT8 decodes on time
- [ ] Remote: connect from another device; key CW, hear RX audio, see telemetry
- [ ] Contest logger: full SO2R workflow for 15 minutes without a glitch

## RF immunity

- [ ] Full power on every band into the real antennas. Watch for USB
      disconnect sounds, COM ports vanishing, frozen audio or a PC lockup
- [ ] Listen on the low bands with the PC on, then off. Note any new noise from the PC or its power supply
- [ ] Rerun `07-Verify.ps1`. "Hardware/USB/disk errors" and "Unexpected shutdowns" must be clean

## Power loss

- [ ] Pull the PC's AC power for 30 s, restore it, and touch nothing
- [ ] PC boots by itself (BIOS setting)
- [ ] Remote access works before anyone signs in locally
- [ ] Station services (remote keyer, rotator server, time sync) come back on their own
