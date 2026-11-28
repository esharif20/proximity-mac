# Done

Proximity Mac v1 is on main: a menu-bar app that turns every screen off when you leave the desk and back on when you return. It keeps the Mac awake throughout and can be controlled by voice.

## Issues and their commits on main
- GH-1 scaffold, contract, docs, CI: c16dbce
- GH-2 PresenceEngine, including the three review fixes: a6e4ea6
- GH-3 display control, idle time, hardware spike: e59e63e
- GH-4 menu bar, Settings, Coordinator, bundle, keep-awake: d4d3626
- GH-5 grace overlay: ff572e4
- GH-6 CameraSource, including the review fixes: 1fbee02
- GH-7 distance and calibration math: 44b6aec
- GH-8 calibration UI and opt-in feature log: bc001ca
- GH-9 trace evaluation and accuracy gates: 5b84520
- GH-10 resource benchmark and budget: 46bb9b4
- GH-11 CommandParser: 8d1fcbf
- GH-12 VoiceSource and MicUsage, including the review fixes and the speech-daemon fix: 0649b7d
- GH-13 voice wiring: 6c0d57f
- GH-14 README, launch at login, release workflow: f2e5120
- GH-25 camera cost cut (native 420v, face rectangles): 152f4c5
- GH-28 stop watching after 15 minutes Away: 2063d30
- GH-29 camera-on budget and the reading benchmark: 8cfa87d
- GH-30 stop-watching setting, reading bench mode, README numbers: bdfe04d

## Measured (M1 Pro, release build, bench/baseline.json)
- Active use: 0.05% CPU, 19 MB. The camera and mic are off.
- Listening in a silent room: 0.57% CPU, 22 MB.
- Checking and away, while the camera is on: 4.8% and 4.4% CPU, 126 MB. A bare camera session alone costs 2.9%.
- Reading at the desk, a 10-minute average: 0.94% CPU.
- Wakeups per second are unmeasured, because powermetrics needs sudo.

## Not done
- The camera-frames-while-screens-off row of docs/spikes/display-and-camera.md was never filled in. The app still needs a real walk-to-bed test.
- Hardware sensors (radar, BLE) are "see for later", per the product owner.

## M5: Setup, Owner, icon (2026-11-28)
- GH-34 engine Owner gating (only wake for me, voice needs me), review fix: 6b578fd, 804e7b5
- GH-35 SFace Core ML model, FaceRecognizer, FaceSignatureStore, review fixes: e27e8e7, ed517b7
- GH-36 CameraSource fills Observation.owner from a 3-frame match: 6f0a259 (about 5 ms per frame, model load about 1 s once)
- GH-37 VisionLab live face, hand and body analysis, review fixes: c6354a1, 2ab80bb
- GH-38 VoiceSource.onLevel: 45e9588
- GH-39 menu-bar icon: e949341
- GH-40 Setup window: 89cf1d4
- GH-41 Owner wiring, Settings Owner section, README: b6604e0, ff7c0c1, 56e6385
- Not done: the Setup window and icon were not checked by eye (screen capture is black for agents), and recognition accuracy was not measured with real faces. The active bench read 0.35% on a busy Mac for both v1 and M5, so it needs a rerun on a quiet Mac.
