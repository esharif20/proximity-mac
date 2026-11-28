lane engine: GH-52 GH-53 GH-54
lane camera: GH-55
lane monitors: GH-56 GH-57
lane ble: GH-58 GH-59 (retired)
lane ddc: GH-65
seat ddc: lane-builder (private IOKit DDC, monitors must never get stuck off)
skills ddc: write-swift
skills engine: write-swift tdd
skills camera: write-swift
skills monitors: write-swift apple-design emil-design-eng
skills ble: write-swift apple-design emil-design-eng
seat engine: lane-builder (the state machine decides every Screens Off)
seat camera: lane-builder (Vision pipeline, budget)
seat monitors: lane-builder (displays must never get stuck dark)
seat ble: lane-builder-standard
review: GH-56 GH-52 GH-54

# Proximity Mac M7 plan: Monitors Off, still-at-desk, films, phone link, Why

The person is away for about 2 hours; build all of it. Decisions: ADR 0005 (Monitors Off, built-in may stay on), memory budget 150 MB with the camera on (bench/budget.json updated). Bug to fix first: sitting at the desk looking at a phone started the grace countdown (GH-52 engine, GH-55 camera).
PR flow as before: one branch and PR per lane, `lane <l> ready <sha>` to the Lead. Never turn the person's screens off while testing (no pmset displaysleepnow, no gamma changes on the live displays outside a unit test that restores them at once).

## Issues, verify command
- GH-52 (engine) Motion during grace returns to checking (max 3 in a row), `reason`. `scripts/test.sh --filter PresenceEngine && scripts/test.sh --filter TraceReplay`
- GH-53 (engine) Media playing keeps screens on, MediaUsage sensor. `scripts/test.sh --filter PresenceEngine && scripts/test.sh --filter MediaUsage`
- GH-54 (engine) Phone link fusion. `scripts/test.sh --filter PresenceEngine`
- GH-55 (camera) Full body chain on every Checking pass, Observation.motion. `scripts/test.sh --filter CameraSource && scripts/test.sh --filter MotionGate`
- GH-56 (monitors) Monitors Off: externals dark, built-in on, restore on every way out. `swift build && scripts/test.sh --filter PresenceSensorsTests`
- GH-57 (monitors) Away screen and glow, Why line, wiring (MediaUsage, BLESource, keepBuiltInOn). `swift build && scripts/bundle.sh && scripts/bench.sh active 1`
- GH-58 (ble) BLESource. `scripts/test.sh --filter BLESource`
- GH-59 (ble) Setup step and Settings for phone, Monitors Off, films; README. `swift build`

## Files each lane owns
- engine: `Sources/PresenceCore/PresenceEngine.swift`, `Sources/PresenceCore/TraceReplay.swift`, `Tests/PresenceCoreTests/PresenceEngineTests.swift`, `Tests/PresenceCoreTests/TraceReplayTests.swift`, `Tests/PresenceCoreTests/Fixtures/**`, `Sources/PresenceSensors/MediaUsage.swift`, `Tests/PresenceSensorsTests/MediaUsageTests.swift`.
- camera: `Sources/PresenceSensors/CameraSource.swift`, `BodyAndHands.swift`, `MotionGate.swift`, `Sources/PresenceCore/Distance.swift`, `Tests/PresenceSensorsTests/CameraSourceTests.swift`, `MotionGateTests.swift`, `BodyAndHandsTests.swift` (or wherever those tests live now), `Tests/PresenceCoreTests/DistanceTests.swift`, `docs/spikes/camera-cost.md`, `docs/spikes/display-and-camera.md`, `scripts/bench.sh`, `bench/**`.
- monitors: `Sources/PresenceSensors/DisplayControl.swift`, `Tests/PresenceSensorsTests/PresenceSensorsTests.swift`, `Sources/ProximityMacApp/**` except `Setup/**` and `SettingsView.swift`, `Resources/**`, `scripts/bundle.sh`.
- ble: `Sources/PresenceSensors/BLESource.swift`, `Tests/PresenceSensorsTests/BLESourceTests.swift`, `docs/spikes/ble.md`, `Sources/ProximityMacApp/Setup/**`, `Sources/ProximityMacApp/SettingsView.swift`, `README.md`.
- camera also owns `Sources/ProximityMacApp/MenuBarIcon.swift` (drop the Checking pulse).
- ddc (GH-65): `Sources/PresenceSensors/DisplayControl.swift`, `Sources/PresenceSensors/DDC.swift`, DDC and display tests, `Sources/ProximityMacApp/MonitorsOff.swift`, `Coordinator.swift`, `SettingsView.swift`, `README.md`, `docs/spikes/ddc.md`. The camera lane keeps only camera files and bench.
- Lead only: `Sources/PresenceCore/Types.swift`, `Tests/PresenceCoreTests/ContractTests.swift`, `GLOSSARY.md`, `docs/adr/**`, `docs/ARCHITECTURE.md`, `scripts/test.sh`, `Package.swift`.

## M7 contract (Types.swift, scaffold commit)
- `Observation.rssi: Double?` (ble only), `Observation.motion: Bool?` (camera); init params default nil.
- `Event.mediaPlaying(Bool)`. The engine currently ignores it (`case .tick, .enable, .disable, .mediaPlaying: break`); GH-53 implements it.
- `public enum PresenceReason: String { turnedOff, typing, seenClose, ownerSeen, phoneNear, mediaPlaying, command, holdCommand, checking, nobodySeen, phoneLeft, sleepCommand, stoppedWatching }`; `PresenceEngine.reason: PresenceReason { get }` (GH-52).
- `public struct PhoneLink { identifier: String; name: String; nearRssi: Double; farRssi: Double }`; `Settings.phone: PhoneLink?`, `Settings.keepBuiltInOn = true`, `Settings.respectMediaPlaying = true`.
- `public protocol MediaReading: Sendable { func mediaPlaying() -> Bool }`; `public struct MediaUsage: MediaReading { public init() }` (GH-53).
- `public final class BLESource: PresenceSource { public init(); public var identifier: String?; public func scan(seconds: Double) async -> [FoundDevice] }`, `public struct FoundDevice: Sendable, Identifiable, Equatable { id: String; name: String; rssi: Double }` (GH-58).
- `DisplayControl.keepBuiltInOn: Bool` (GH-56).
- Info.plist already has `NSBluetoothAlwaysUsageDescription`.
- Cross-lane: the monitors lane wires MediaUsage, BLESource and reason into the Coordinator against these names; until they land, stub them in the app only behind the same names and delete the stub after `git merge main`. The ble lane's Settings toggles bind to `coordinator.settings.keepBuiltInOn` / `.respectMediaPlaying` / `.phone`, which exist already.

## Code map (M7)
- `Sources/PresenceCore/PresenceEngine.swift`: `react(to:at:)` (observation branch, commands, `.tick, .enable, .disable, .mediaPlaying` no-op), `userIsBack`, `backAtDesk`, `startChecking`, `goAway`, `startHold`, `advanceDeadlines`, `updateListening`, effect setters at the end.
- `Sources/PresenceSensors/CameraSource.swift`: `handle(_ sampleBuffer:)` (motion gate, VisionSchedule, owner check, `withoutFace` chain face > body pose > body box > hands), `deskRadiusCm`, `darkBrightness` 0.08.
- `Sources/PresenceSensors/DisplayControl.swift`: `Actions` (sleepDisplays via pmset, declareUserActivity, lockSession), `screensOff` 23, `screensOn` 24, `lock` 25.
- `Sources/ProximityMacApp/`: `Coordinator.swift` (`settings` didSet pushes calibration and deskRadiusCm to the camera, `send`, `perform(effect)`, `tick` 1 s), `Seams.swift`, `KeepAwake.swift` (`set(_:)` PreventUserIdleSystemSleep), `GraceOverlay.swift` (per-screen panels: copy its pattern for black windows), `ProximityMacApp.swift` (MenuBarExtra, MenuContent), `StatusText.swift`, `MenuBarIcon.swift`, `Setup/` (SetupModel, SetupView, RoomMap, VisionOverlay), `SettingsView.swift`.

## M5 contract (still current)

Already in `Types.swift` (scaffold commit): `Observation.owner: Bool?` (init param `owner: Bool? = nil`), `Settings.onlyWakeForMe = false`, `voiceNeedsMe = false`, `voiceAfterSeenMinutes = 30`, `setupDone = false` (decoded with defaults).
New in lanes (signatures fixed here):
- `PresenceEngine.lastIgnoredCommand: Command? { get }` (GH-34).
- `public struct FaceSignature: Codable, Sendable, Equatable { public var vectors: [[Float]]; public var threshold: Float }` (GH-35, FaceRecognizer.swift).
- `public final class FaceRecognizer: Sendable { public init(); public func embedding(of pixels: CVPixelBuffer, face: VNFaceObservation) -> [Float]?; public static func signature(from embeddings: [[Float]]) -> FaceSignature?; public static func matches(_ embedding: [Float], _ signature: FaceSignature) -> Bool }` (GH-35).
- `public struct FaceSignatureStore: Sendable { public init(); public func load() -> FaceSignature?; public func save(_ signature: FaceSignature) throws; public func delete() }` (GH-35).
- `CameraSource.setOwner(_ signature: FaceSignature?)` (GH-36).
- `public final class VisionLab: Sendable { public init(); public func start(_ onFrame: @escaping @Sendable (LabFrame) -> Void); public func stop(); public func calibrate(seconds: Double = 3) async -> Calibration?; public func enrolOwner(samples: Int = 20, progress: @escaping @Sendable (Int) -> Void) async -> FaceSignature? }` (GH-37).
- `public struct LabFrame: Sendable { public var image: CGImage; public var face: LabFace?; public var hands: [LabHand]; public var body: CGRect?; public var visionMs: Double; public var fps: Double }`, `public struct LabFace: Sendable { public var box: CGRect; public var landmarks: [CGPoint]; public var yawDeg, pitchDeg, rollDeg, distanceCm, horizontalAngleDeg: Double }`, `public struct LabHand: Sendable { public var joints: [CGPoint]; public var isLeft: Bool }`. Points normalised 0..1, origin top-left, mirrored like a selfie view (GH-37).
- `VoiceSource.onLevel(_ handler: @escaping @Sendable (Float) -> Void)`, RMS 0..1 per buffer (GH-38).
- Only one camera session at a time: the app calls `Coordinator.setPreviewing(true)` (CameraSource to `.off`) before `VisionLab.start`, and `false` after `stop`.

## Code map
- `Sources/PresenceCore/Types.swift`: the contract above plus the v1 contract (Event, Effect, PresenceState, Settings, seams).
- `Sources/PresenceCore/PresenceEngine.swift`: `handle(_:at:)` 35, `react(to:at:)` 61 (observation branch 68 to 80, commands 81 to 90), `userIsBack` 109, `backAtDesk` 119, `goAway` 132, `advanceDeadlines` 155.
- `Sources/PresenceCore/Distance.swift`: `estimate` 14, `calibration(fromFaceWidths:imageWidthPx:distanceCm:)` 28. `CommandParser.parse` CommandParser.swift:22.
- `Sources/PresenceSensors/CameraSource.swift`: `setMode` 49, `calibrate` 62, `reconcile` 97, `makeSession` 115, `handle(sampleBuffer)` 188, `observation(...)` 230, `FrameThrottle` 261, `largestFace` 309, `widestUpperBody` 320. Capture is 640x480 420v, about 15 fps sensor rate.
- `Sources/PresenceSensors/VoiceSource.swift`: `onTranscript` 58, `start` 62, `stop` 72. EnergyGate.swift gates the recogniser.
- `Sources/ProximityMacApp/ProximityMacApp.swift`: `@main` MenuBarExtra (label at 13 to 15 uses `StatusText.symbol`), Settings `Window(id: "settings")`, `MenuContent`.
- `Sources/ProximityMacApp/Coordinator.swift`: `@Observable`, `settings` 36, `send` 125, `setPreviewing` 144, `calibrate` 150, `heard` 159, `tick` 186, `perform` 210. Seams.swift: `Seams.live` (camera, display, idle, voice, mic).
- `Sources/ProximityMacApp/SettingsView.swift`: Form sections Presence 15, Distance 28 (calibrate button 33), Wake up 38, Voice 48, Feature log 53.
- `StatusText.swift`: `line`, `symbol` 17, `command`. `GraceOverlay.swift`: per-screen countdown window.

structure:
- Sensors observe, the engine decides, the app acts. No timing or presence rule lives outside `PresenceEngine`; adapters report facts and the Coordinator only executes `Effect`s.
- One adapter per file in `Sources/PresenceSensors/`, each behind a protocol from Types.swift, with no shared mutable globals.
- `PresenceCore` imports Foundation only (no AVFoundation, Vision, IOKit, AppKit), so it stays testable with traces.
- No speculative seams. A protocol exists only where Types.swift names it.
- No network APIs anywhere (URLSession and friends). Never write a frame, an audio buffer or a transcript to disk or a log.

prose:
- Commit subjects are `GH-<n>: <what changed>` in the imperative, with a short body saying why. End with the Co-Authored-By line from the builder's instructions.
- PR bodies are exactly `## Why`, `## What`, `## Verification`, with the real command output status (pass/fail counts), not claims.
- README and docs use the GLOSSARY words: Screens Off (never "sleep" for it), Present, Away, Hold, Command, Trigger word.
- Code comments say why, not what. Use no em dashes, no "seamlessly/robust/leverage", and no emojis.
- User-facing strings are plain and short: "Screens off in 8 s", "Listening", "Held for 9 min".
