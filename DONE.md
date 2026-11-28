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

## M6: robust detection (2026-11-28)
- GH-46 motion-gated vision, brightness per Observation, review fix: 637ad10, 518006e
- GH-47 body pose, body box, then hands within min(150 cm, Desk radius), review fixes: e0374d7, 4698c2d, plus the Desk radius wiring on main
- GH-48 slowest frame rate while watching (the built-in camera stays at 15 fps), darkBrightness 0.08 untuned: 509e942
- GH-49 the macOS lock delay in Setup and Settings, "Too dark to see you": 9c26845
- Away bench 3.46% CPU, 141 MB: over the 130 MB memory budget, waiting on the person's decision.

## M7: Monitors Off, presence without a face, films, phone link, Why (2026-11-28)
- GH-52 motion during the countdown returns to checking (at most 3 in a row with nobody seen), `reason`: 8119520, review fix in f5cbb6b
- GH-53 a playing video or presentation keeps screens on, MediaUsage: a6bf8cf
- GH-54 phone link fusion: f5cbb6b, review fixes f26f797
- GH-55 person segmentation as the first pass when no face is found, Observation.motion: 183f60c to d975f06
- GH-56 Monitors Off (external displays black, built-in on, restore on every way out), mirror-mode fix: e1561ee, a9347fb
- GH-57 Away screen with glow, the Why line, wiring: d966073, 3d53df7
- GH-58 BLESource: c1f5669
- GH-59 Setup phone step, Settings for the phone, Monitors Off and films, README: ec7e6f4
- Bench: away 4.48% CPU / 133 MB. Checking measured 10.56% / 151.5 MB on a busy Mac (main without GH-55 measured 11.57%); the cause is being profiled.
- Not live-tested: Monitors Off on the real displays, the glow, the phone link with a real phone, recognition with a real face.
