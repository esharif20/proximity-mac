# Proximity Mac

A macOS menu bar app that turns your screens off when you walk away from the desk and back on when you sit down again. It watches with the built-in camera, listens for a few spoken Commands, and does everything on the Mac.

Screens Off means every display, built-in and external, goes dark while the Mac stays awake and your session stays exactly as you left it. It never puts the Mac into System Sleep, so it can still see you come back and hear "Screen, wake up".

While Proximity Mac is on, it also stops the Mac from going into idle System Sleep, so overnight jobs keep running with the screens off. The displays can still sleep on their own schedule. Turn Proximity Mac off or quit it and the Mac sleeps as usual again. You can see this in `pmset -g assertions` as "Proximity Mac keeps the Mac awake".

## How it works

- While you are typing or using the mouse, the app reads idle time once a second and nothing else runs.
- After a while without input, it checks the camera about once a second. If it sees you within the Desk radius (1.2 m by default), you are Present and the camera goes off again.
- If nobody is seen for long enough, a Grace countdown appears on every screen: "Screens off in 10 s". Move the mouse or say "Screen, keep it on" to cancel it.
- When the countdown ends, Away: Screens Off, and the camera checks about every 2 seconds for you to come back. Sitting down again turns the screens back on.
- After 15 minutes Away (Settings, "Stop watching after"), the camera turns off for the night. From then on, touching the keyboard or mouse, or saying "Screen, wake up" or "Screen, keep it on", brings the screens back.
- Commands start with the Trigger word ("Screen" by default):
  - "Screen, wake up" turns the screens on.
  - "Screen, go to sleep" means Screens Off now.
  - "Screen, keep it on for 10 minutes" holds the screens on for that long.

## Setup

Setup opens on first launch, and any time from the menu with "Run Setup…". It shows the camera's view with what the app sees drawn on top: face points, the distance in cm, head pose, hands and upper body. Nothing from the camera is saved.

1. Allow the camera and microphone.
2. Sit normally while it calibrates distance.
3. Lean back, then stand behind your chair. A map of the room shows where you count as at the desk, and sets the Desk radius from it. You can adjust it with a slider.
4. Look at each monitor, to see that you still count while looking away from the camera.
5. Go to your bed. It should say "Not counted"; if not, Setup offers to shrink the radius.
6. Optionally enrol your face as the Owner (see below). Skip keeps it off.
7. Say "Screen, wake up" to test a Command.

## Only wake for me

Without this, anyone who comes close to the desk while you are Away turns the screens back on. If you enrol your face in Setup, you become the Owner and two switches in Settings > Owner turn on:

- "Only wake for me": only your face wakes the screens from Away. Before Away, anyone close still counts, so someone else can never cause Screens Off.
- "Voice commands need my face": a Command counts only if the camera saw your face in the last 30 minutes. If you speak while Away and haven't been seen, the camera starts watching again, so the next Command can count.

Typing or moving the mouse always wakes the screens. Both switches are off until you enrol, and off by default. "Re-enrol my face" runs the enrolment again, and "Delete my face signature" removes it and turns both switches off.

Face recognition uses SFace from OpenCV Zoo, run on the Mac with Core ML. It runs only when a switch is on and the camera already sees a face. A webcam has no depth sensor, so this is not Face ID: a photo of you might pass. It keeps family walking past from waking the screens. It won't stop an attacker.

## The menu bar icon

A small monitor shows the state at a glance:

| Icon | State |
| --- | --- |
| Screen lit, with a dot | Present |
| The dot pulses | Checking |
| The screen drains | Grace countdown |
| Outline only | Away, Screens Off |
| A pin | Hold |
| Sound waves beside it | Listening for a Command |
| Struck through | Off |

With Reduce Motion on, nothing pulses and changes are instant.

## Privacy

- No network. The app contains no network code and sends nothing anywhere.
- Nothing stored. Camera frames and audio stay in memory and are dropped right away. Speech is recognised on the Mac, and only the parsed Command is kept.
- The Face signature is opt-in. Enrolling saves 128-number face embeddings (a mean and up to three pose clusters) as one item in your login Keychain, never a picture or a frame. It is never synced to iCloud, and "Delete my face signature" in Settings removes it. Because builds are ad-hoc signed, the Keychain can't mark the item as this Mac only, so a Time Machine restore or Migration Assistant can copy it to another Mac along with the rest of your login keychain.
- The feature log is opt-in and off by default. When on, it writes timed events to `~/Library/Application Support/ProximityMac/traces/`, as numbers only: idle seconds, whether a person was seen, distance and the Command. It never holds images, sound or words. "That was wrong" in the menu adds a marker so a bad decision can be replayed.

## Install

1. Download the zip from [Releases](https://github.com/esharif20/proximity-mac/releases) and move `Proximity Mac.app` to Applications.
2. The app isn't notarized, so macOS blocks the first launch. Open it once, then go to System Settings > Privacy & Security and click "Open Anyway". You only do this once.
3. Allow Camera, Microphone and Speech Recognition when asked.

Requires macOS 26 or later.

## Permissions

| Permission | Why |
| --- | --- |
| Camera | To see whether you are at the desk. It runs only while checking or Away. |
| Microphone | To hear Commands after a while without input. It never listens while another app uses the microphone, for example during a call. |
| Speech Recognition | To turn speech into a Command on the Mac. |

Launch at login is a toggle in Settings.

## Build from source

You need the Command Line Tools for Swift 6. Xcode isn't needed.

```sh
swift build
scripts/test.sh                 # all tests
scripts/test.sh --filter PresenceEngine
scripts/bundle.sh               # builds dist/Proximity Mac.app
```

`scripts/bundle.sh` signs ad-hoc by default. macOS treats every ad-hoc build as a new app and asks for Camera and Microphone again. To keep the permissions across rebuilds, make a self-signed code signing certificate once in Keychain Access (Certificate Assistant > Create a Certificate, type Code Signing) and build with it:

```sh
SIGN_IDENTITY="Proximity Mac Dev" scripts/bundle.sh
```

## Resource budget

Measured on the developer's Mac with `scripts/bench.sh <mode>` on a release build. The app pins itself in a mode with `--bench-mode`. The figures are in `bench/baseline.json`. CPU is the average share of one core and memory is the physical footprint.

| Mode | What runs | CPU | Memory |
| --- | --- | --- | --- |
| active | One idle-time read per second. Camera and microphone off. | 0.05% | 19 MB |
| listening | Microphone energy gate, then on-device speech only when there is sound. | 0.57% | 22 MB |
| checking | Camera and Vision about once a second. | 4.8% while the camera is on | 126 MB |
| away | Camera and Vision about once every 2 seconds. Screens Off. | 4.4% while the camera is on | 126 MB |
| reading at the desk | You sit still without typing: a check finds you, the camera goes off, it checks again a minute later. | 0.94% averaged over 10 min | 60 MB peak |

Most of the time is spent in active, so the app usually costs next to nothing. The camera modes cost more because of the camera, not because of the app. A bare capture session on the built-in camera, with no Vision and no app, already uses about 2.9% CPU and 110 MB. That floor comes from macOS delivering frames at the camera's minimum of 15 per second. Vision on one frame a second adds about 1%. Starting and stopping the camera between samples costs more than leaving it running, so the camera stays on only while a check needs it. After 15 minutes Away it turns off completely. `docs/spikes/camera-cost.md` has the measurements.

See `docs/ARCHITECTURE.md` for how the parts fit together.

## License

MIT. The bundled SFace model (OpenCV Zoo) is Apache-2.0; see `NOTICE`. `scripts/convert-sface.sh` rebuilds it from the original ONNX file.
