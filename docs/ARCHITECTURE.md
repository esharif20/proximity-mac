# Architecture

Proximity Mac is one Swift package with three targets. The rule is simple: sensors observe, the engine decides, the app acts.

```
PresenceSensors  --Observation/idle/transcript-->  PresenceEngine  --Effect-->  ProximityMacApp
(camera, idle,                                     (PresenceCore,             (menu bar, overlay,
 mic, speech, displays)                             pure, traced)              runs effects)
```

## PresenceCore (pure, Foundation only)
- `Types.swift`: the contract. `Observation`, `Command`, `Event`, `Effect`, `PresenceState`, `Settings`, `TraceLine` and the seams `PresenceSource`, `DisplayControlling`, `IdleReading`, `VoiceListening`, `MicUsageReading`.
- `PresenceEngine`: the state machine `off → present → checking → grace → away`, plus `hold`. It takes one `Event` at a monotonic time and returns `[Effect]`. It owns every timing rule: wake on the first close sighting, Away only after continuous absence, then the Grace countdown.
- `CommandParser`: turns a transcript into a `Command` when it starts with the Trigger word.
- `Distance`: estimates distance in cm from face width in pixels, with or without a `Calibration`.
- `TraceReplay`: replays JSONL traces through the engine and reports false-away, missed-away and wake latency.

## PresenceSensors (adapters)
- `CameraSource`: an AVFoundation capture at low resolution, run only while sampling, with Vision face landmarks and upper-body detection. It reports an `Observation` with distance and facing.
- `IdleSource`: reads `HIDIdleTime` from IOKit.
- `DisplayControl`: turns screens off and on and locks.
- `VoiceSource`: an energy gate, then SpeechAnalyzer on-device, producing transcripts.
- `MicUsage`: detects whether another app holds the microphone.

## ProximityMacApp
The `MenuBarExtra` toggle and status, Settings, the Grace overlay on every screen, and the `Coordinator`. The `Coordinator` polls idle time once a second, feeds events to the engine, executes effects and owns the feature log (opt-in, numbers only).

## Resource rule
While input is recent, the only work is one idle-time read per second. The camera, microphone and Vision run only when an `Effect` asks for them, and `scripts/bench.sh` checks the per-mode budget in `bench/budget.json`.

## Privacy rule
There is no network code. Frames and audio never leave memory. Logs and traces hold numbers only.
