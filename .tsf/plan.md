lane recognition: GH-34 GH-35 GH-41(Settings + README part)
lane vision: GH-37 GH-38 GH-36
lane app: GH-39 GH-40 GH-41
skills recognition: write-swift tdd
skills vision: write-swift
skills app: write-swift apple-design emil-design-eng (person asked for both: read ~/.claude/skills/apple-design/SKILL.md and ~/.claude/skills/emil-design-eng/SKILL.md)
seat recognition: lane-builder (biometric data in the Keychain, face alignment maths, engine gating)
seat vision: lane-builder-standard
seat app: lane-builder-standard
review: GH-35 GH-34 GH-37

# Proximity Mac M5 plan: Setup, Owner, icon

Repo: github.com/esharif20/proximity-mac. macOS 26+, Swift 6 package. Xcode is now selected, so `swift test` works; `scripts/test.sh` still works too.
Issues hold the full acceptance: `gh issue view <n> -R esharif20/proximity-mac`. Commit subjects start `GH-<n>: `. Decisions: ADR 0004 (docs/adr/0004-opt-in-face-signature.md), GLOSSARY Setup / Owner / Face signature.
Each lane is one branch and one PR: after the first green commit `git push -u origin lane/<l>` and `gh pr create --base main --head lane/<l>`; body `## Why`, `## What`, `## Verification` with real check output. End each issue with a `lane <l> ready <sha>` or `blocked` line to the Lead.

## Issues, verify command
- GH-34 (recognition) Engine owner gating, voice needs me. `scripts/test.sh --filter PresenceEngine`
- GH-35 (recognition) SFace Core ML model, FaceRecognizer, FaceSignatureStore. `scripts/test.sh --filter FaceRecognizer`
- GH-36 (vision) CameraSource fills Observation.owner (3-frame match). `scripts/test.sh --filter CameraSource`
- GH-37 (vision) VisionLab live analysis, calibrate, enrolOwner. `scripts/test.sh --filter VisionLab`
- GH-38 (vision) VoiceSource.onLevel. `scripts/test.sh --filter Voice`
- GH-39 (app) Menu-bar icon. `swift build && scripts/bench.sh active 1`
- GH-40 (app) Setup window, layout spec in docs/design/setup.md first. `swift build`
- GH-41 (app) Owner wiring, Settings, README. `swift build && scripts/bundle.sh`

## Files each lane owns
- recognition: `Sources/PresenceCore/PresenceEngine.swift`, `Tests/PresenceCoreTests/PresenceEngineTests.swift`, `Sources/PresenceSensors/FaceRecognizer.swift`, `Sources/PresenceSensors/FaceSignatureStore.swift`, `Sources/PresenceSensors/Resources/**`, `Tests/PresenceSensorsTests/FaceRecognizerTests.swift`, `scripts/convert-sface.sh`, `NOTICE`, `Package.swift` (the PresenceSensors resources line only), and for GH-41: `Sources/ProximityMacApp/SettingsView.swift`, `README.md`.
- vision: `Sources/PresenceSensors/CameraSource.swift`, `Tests/PresenceSensorsTests/CameraSourceTests.swift`, `docs/spikes/camera-cost.md` (GH-36, moved from recognition), `Sources/PresenceSensors/VisionLab.swift`, `Tests/PresenceSensorsTests/VisionLabTests.swift`, `Sources/PresenceSensors/VoiceSource.swift`, `Tests/PresenceSensorsTests/VoiceTests.swift`.
- app: `Sources/ProximityMacApp/**` except SettingsView.swift, `docs/design/**`, `Resources/**`, `scripts/bundle.sh`.
- Lead only: `Sources/PresenceCore/Types.swift`, `Tests/PresenceCoreTests/ContractTests.swift`, `GLOSSARY.md`, `docs/adr/**`, `docs/ARCHITECTURE.md`, `scripts/test.sh`. Need a change there? `hc send` the Lead the exact line.

## Cross-lane dependencies (build against the contract, `git merge main` once it lands)
- vision GH-37 `enrolOwner` calls `FaceRecognizer.embedding` / `.signature` (GH-35): stub behind the same signatures until it lands.
- app GH-40 uses `VisionLab`, `LabFrame`, `VoiceSource.onLevel`: drive the UI from a fake frame source until vision lands.
- GH-41 split: the app lane adds to Coordinator `var hasFaceSignature: Bool { get }`, `func deleteFaceSignature()` (deletes, turns both switches off), `func openSetup()` and the owner wiring (`camera.setOwner`); the recognition lane builds the SettingsView Owner section and README against those names.
- app GH-41 uses `FaceSignatureStore`, `CameraSource.setOwner`, `PresenceEngine.lastIgnoredCommand` (recognition).

## Shared contract
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
