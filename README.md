# Proximity Mac

A macOS menu bar app that turns your screens off when you walk away from the desk and back on when you sit down again. It watches with the built-in camera, listens for a few spoken Commands, and does everything on the Mac.

Screens Off means every display, built-in and external, goes dark while the Mac stays awake and your session stays exactly as you left it. It never puts the Mac into System Sleep, so it can still see you come back and hear "Screen, wake up".

## How it works

- While you are typing or using the mouse, the app reads idle time once a second and nothing else runs.
- After a while without input, it checks the camera about once a second. If it sees you within the Desk radius (1.2 m by default), you are Present and the camera goes off again.
- If nobody is seen for long enough, a Grace countdown appears on every screen: "Screens off in 10 s". Move the mouse or say "Screen, keep it on" to cancel it.
- When the countdown ends, Away: Screens Off, and the camera checks about every 2 seconds for you to come back. Sitting down again turns the screens back on.
- Commands start with the Trigger word ("Screen" by default):
  - "Screen, wake up" turns the screens on.
  - "Screen, go to sleep" means Screens Off now.
  - "Screen, keep it on for 10 minutes" holds the screens on for that long.

## Privacy

- No network. The app contains no network code and sends nothing anywhere.
- Nothing stored. Camera frames and audio stay in memory and are dropped right away. Speech is recognised on the Mac, and only the parsed Command is kept.
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

Each mode has a CPU and memory limit in `bench/budget.json`, and `scripts/bench.sh <mode>` measures the built app against it (the app pins itself in a mode with `--bench-mode`).

| Mode | What runs |
| --- | --- |
| active | One idle-time read per second. Camera and microphone off. |
| checking | Camera and Vision about once a second. |
| away | Camera and Vision about once every 2 seconds. Screens Off. |
| listening | Microphone energy gate, then on-device speech only when there is sound. |

See `docs/ARCHITECTURE.md` for how the parts fit together.

## License

MIT
