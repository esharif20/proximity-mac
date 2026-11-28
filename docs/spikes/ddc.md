# Spike: real monitor standby over DDC/CI

During Away, Monitors Off covers the external monitors with a black window and zero gamma. The person can still see the monitors are on, because the backlight stays lit. This spike asks whether the app can put the monitors into real standby while the MacBook screen stays on, with no password on return.

Result: not on the person's monitors. DDC standby is not shipped. Monitors Off keeps the black window and zero gamma, and `keepBuiltInOn = false` (display sleep for every display) stays the way to get dark monitors.

## Setup

- MacBook Pro M1 Pro, built-in panel (display 1).
- Two identical XWU-CBA 2560x1440 monitors (vendor 8950, model 25333, serial 1, the same EDID UUID) behind a CalDigit TS3 Plus. One is rotated to portrait.
- DDC goes through the private `IOAVServiceCreateWithService`, `IOAVServiceWriteI2C` and `IOAVServiceReadI2C` calls that MonitorControl and m1ddc use. All three resolve with `dlsym` on this macOS.

## Matching monitors to displays

The two monitors share an EDID, so the EDID UUID cannot tell them apart. The display pipe can:

- Each external `DCPAVServiceProxy` with `Location = External` sits under `.../dispextN:dcpav-service-epic:0/DCPAVServiceProxy`.
- `CoreDisplay_DisplayCreateInfoDictionary(displayID)["IODisplayLocation"]` gives `.../dispextN@.../AppleCLCD2`.

On this Mac, display 2 is `dispext1` and display 3 is `dispext0`.

## What the monitors do

| Test | Monitor | Result |
| --- | --- | --- |
| Read VCP 0xD6 (power) | both | Replies `01`, maximum `05`. Reads work through the dock. |
| Brightness (0x10) 73 to 72 and back | dispext1 | Both writes land and read back. Writes work through the dock. |
| Write 0xD6 = 4 (DPM off), read back for 8 s, write 1 | dispext1 | Ignored: read-back stays 1, display stays online. |
| Write 0xD6 = 5 (hard off), read back for 6 s, write 1 | dispext1 | Read-back 5 for 6 s, display stays online. Then DDC stops answering (the read buffer holds the request bytes). 20 writes of 1 over 25 s: no reply. |
| `pmset displaysleepnow`, 10 s, `IOPMAssertionDeclareUserActivity` | both | dispext1 answers DDC again and reads 1. Both monitors confirmed on. |

So the only power value these monitors act on is 5, and 5 also turns off their DDC. From then on, only a display sleep and wake (the DisplayPort link coming back) or the power button can wake them. Value 4, the one that should keep DDC alive, does nothing. Values 2 and 3 were not tried, so no second monitor could get stuck.

Neither monitor dropped out of the display list in any test, so no window moved.

## Disconnecting the display instead

The other route is to disable the external display in software (SkyLight `SLSConfigureDisplayEnabled`, as BetterDisplay does) so the monitor loses its signal and goes to standby by itself, then to enable it again. Pass means the display comes back and every window returns to its old bounds.

This could not be tested. The session was locked (`CGSSessionScreenIsLocked = 1`) and every display was asleep (`CGDisplayIsAsleep` for all three), so the active display list was empty and the lock screen hid the windows. Disable and enable on display 3 ran without errors, changed nothing, and left both monitors reading 1. A valid run needs an unlocked, awake session with windows on the monitor. Do that run with the person at the desk.

## If a monitor is left off

If a monitor is off and does not wake: let the displays sleep and wake (close and open the lid, or wait for display sleep and move the mouse), or press the monitor's power button.
