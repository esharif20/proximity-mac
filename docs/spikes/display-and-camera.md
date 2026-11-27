# Spike: Screens Off and the camera

Three questions decide whether Screens Off works on this Mac before anything is built on it:

1. Does Screens Off power off every display, the built-in one and each external display on the dock, whatever the panel type?
2. Does an `AVCaptureSession` still deliver frames while the screens are off, so the person coming back is noticed?
3. How long does each display take to show a picture again after `screensOn()`?

## How Screens Off is done

- Off: `pmset displaysleepnow`. It puts every display to sleep, docked externals included, and leaves the Mac awake. It is never System Sleep (ADR 0001).
- On: `IOPMAssertionDeclareUserActivity(kIOPMUserActiveLocal)`, the supported way to wake displays without fake input.
- Lock: `SACLockScreenImmediate` from login.framework, the same call as the menu bar Lock Screen item. Only used when `lockWhenAway` is on.

"Power off" here means the display enters its own standby: no backlight and, on most monitors, the power LED turns amber or off. Whether a given monitor reaches standby depends on how it reacts to the signal going away over the dock (DisplayPort or HDMI), not on whether it is OLED. Some monitors instead show a "no signal" box for a few seconds and then sleep; some never sleep if their own auto-standby setting is off. That is why every display is checked separately.

## Runnable check

Run this on the Mac with the dock and all monitors connected. It needs nothing beyond the Command Line Tools.

```sh
# 1. List what macOS sees, so every display is accounted for.
system_profiler SPDisplaysDataType | grep -E '^\s{8}[^ ].*:$|Resolution|Connection Type'

# 2. Screens Off for 15 s, then wake. Watch each monitor and note what it does.
pmset displaysleepnow; sleep 15; caffeinate -u -t 1

# 3. Wake latency: time from the wake call until displays report awake again.
pmset displaysleepnow; sleep 10
caffeinate -u -t 1
# Note the seconds until each monitor shows a picture; the OS-side wake is immediate,
# the panel's own wake is what the person feels.
```

Camera while screens are off (needs camera permission for Terminal):

```sh
cat > /tmp/camcheck.swift <<'SWIFT'
import AVFoundation
final class D: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var n = 0
    func captureOutput(_ o: AVCaptureOutput, didOutput b: CMSampleBuffer, from c: AVCaptureConnection) { n += 1 }
}
let s = AVCaptureSession(); s.sessionPreset = .vga640x480
let dev = AVCaptureDevice.default(for: .video)!
s.addInput(try! AVCaptureDeviceInput(device: dev))
let out = AVCaptureVideoDataOutput(); let d = D()
out.setSampleBufferDelegate(d, queue: DispatchQueue(label: "cam")); s.addOutput(out)
s.startRunning()
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["displaysleepnow"]
sleep(2); d.n = 0; try! p.run(); sleep(10)
print("frames while screens off: \(d.n)")   // a count only; no frame is kept
s.stopRunning()
SWIFT
swift /tmp/camcheck.swift
```

## Results

Run on the person's MacBook with two external displays on the dock (neither is OLED).

| Display | Connection | Goes to standby on Screens Off | Woke on `screensOn()` |
| ------- | ---------- | ------------------------------ | --------------------- |
| Built-in | internal | yes | yes |
| External 1 | dock | yes | yes |
| External 2 | dock | yes | yes |

`pmset displaysleepnow` turned off all three and the Mac stayed awake. Per-display time to picture was not timed; all woke without trouble.

Camera frames delivered during 10 s of Screens Off: pending (expect about 300 at 30 fps; 0 means the camera pauses and the Away watch needs another plan).

## If a display does not go to standby

- Turn on the monitor's own auto-standby or "power saving" setting in its on-screen menu.
- Check that the dock does not keep the link alive (some docks send a black signal instead of none).
- If neither helps, the fallback is DDC/CI power-off per display, which would need its own ADR.
