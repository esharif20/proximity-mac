lane detect: GH-46 GH-47 GH-48
lane app: GH-49
skills detect: write-swift tdd
skills app: write-swift apple-design emil-design-eng
seat detect: lane-builder (camera pipeline, Vision, hard detection logic)
seat app: lane-builder-standard
review: GH-46 GH-47

# Proximity Mac M6 plan: robust detection

The person's first real test: standing at the desk and waving while Away did not wake the screens, and on return macOS asked for Touch ID (its own 5-minute lock delay). M6 makes detection faster and wider (motion gate, body pose, hands, low light) and explains the lock delay.
Repo, PR flow and prose rules as before: one branch and PR per lane, `lane <l> ready <sha>` to the Lead.

## Issues, verify command
- GH-46 (detect) Motion-gated vision, brightness per Observation. `scripts/test.sh --filter CameraSource && scripts/test.sh --filter MotionGate`
- GH-47 (detect) Body pose for standing, hands for waving. `scripts/test.sh --filter CameraSource && scripts/test.sh --filter Distance`
- GH-48 (detect) Low light: longer exposure while watching, `CameraSource.darkBrightness`. `scripts/test.sh --filter CameraSource`
- GH-49 (app) Lock delay step in Setup and Settings, "Too dark to see you", README. `swift build && scripts/bundle.sh`

## Files each lane owns
- detect: `Sources/PresenceSensors/**`, `Sources/PresenceCore/Distance.swift`, `Tests/PresenceSensorsTests/**`, `Tests/PresenceCoreTests/DistanceTests.swift`, `docs/spikes/**`, `scripts/bench.sh`, `bench/**`.
- app: `Sources/ProximityMacApp/**`, `README.md`, `Resources/**`, `scripts/bundle.sh`, `docs/design/**`.
- Lead only: `Sources/PresenceCore/Types.swift`, `Tests/PresenceCoreTests/ContractTests.swift`, `GLOSSARY.md`, `docs/adr/**`, `docs/ARCHITECTURE.md`, `scripts/test.sh`.

## New contract (M6)
- `Observation.brightness: Double?` (0..1 mean frame brightness, init param `brightness: Double? = nil`), already in Types.swift.
- `public static let darkBrightness: Double` on `CameraSource` (GH-48); the app uses 0.08 until it lands.
- The engine is unchanged: hands and bodies arrive as ordinary close Observations with `owner: nil`.

## Code map (M6)
- `Sources/PresenceSensors/CameraSource.swift`: `handle(_ sampleBuffer:)` about line 203 (throttle, owner check, face then body fallback), `observation(face:bodyWidthPx:imageWidthPx:calibration:)`, `FrameThrottle`, `sensorFrameRate` about 193, `makeSession`, `VisionPass.largestFace` / `widestUpperBody` at the end.
- `Sources/PresenceCore/Distance.swift`: `estimate` 14, `calibration` 28.
- `Sources/ProximityMacApp/Setup/`: SetupModel.swift (steps), SetupView.swift, RoomMap.swift, VisionOverlay.swift. `SettingsView.swift` Owner and Presence sections. `Coordinator.swift` holds `lastDistanceCm` from observations.

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
