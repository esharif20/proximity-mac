lane core: GH-7 GH-2 GH-9 GH-11
lane sensors: GH-3 GH-6 GH-10 GH-12
lane app: GH-4 GH-5 GH-8 GH-13 GH-14
skills core: tdd
skills sensors: write-swift
skills app: write-swift apple-design
seat core: lane-builder (hard logic: the state machine and the parser decide every screen-off)
seat sensors: lane-builder (camera and microphone privacy, IOKit/AVFoundation/Speech debugging)
seat app: lane-builder-standard
review: GH-12 GH-6 GH-2

# Proximity Mac build plan

Repo: github.com/esharif20/proximity-mac (public, MIT). macOS 26+, Swift 6 package, no Xcode on the build Mac (Command Line Tools only).
Issues hold the full acceptance: `gh issue view <n> -R esharif20/proximity-mac`. Commit subjects start `GH-<n>: `.
Tests use Swift Testing (`import Testing`, `@Test`, `#expect`). Always run them through `scripts/test.sh` (it fixes the CLT search path); plain `swift test` fails here.

## Issues, acceptance in one line, verify command
- GH-7 (core) Distance estimate and calibration math, pure property-tested. `scripts/test.sh --filter Distance`
- GH-2 (core) PresenceEngine state machine with the resource-rule property test. `scripts/test.sh --filter PresenceEngine`
- GH-9 (core) TraceReplay and synthetic traces with accuracy gates. `scripts/test.sh --filter TraceReplay`
- GH-11 (core) CommandParser with adversarial transcripts. `scripts/test.sh --filter CommandParser`
- GH-3 (sensors) DisplayControl, IdleSource, plus a hardware spike doc. `scripts/test.sh --filter PresenceSensorsTests`
- GH-6 (sensors) CameraSource: duty-cycled Vision presence with distance. `scripts/test.sh --filter CameraSource`
- GH-10 (sensors) scripts/bench.sh and bench/budget.json. `scripts/bench.sh active 1`
- GH-12 (sensors) VoiceSource (energy gate + SpeechAnalyzer) and MicUsage. `scripts/test.sh --filter Voice`
- GH-4 (app) Menu bar, Settings, Coordinator, bundle.sh, --bench-mode. `swift build && scripts/bundle.sh`
- GH-5 (app) Grace overlay on every screen. `swift build`
- GH-8 (app) Calibration UI and opt-in feature log. `swift build`
- GH-13 (app) Voice wiring and listening indicator. `swift build`
- GH-14 (app) README, launch at login, release workflow. `swift build && scripts/bundle.sh`

## Files each lane owns
- core: `Sources/PresenceCore/**` except `Types.swift`; `Tests/PresenceCoreTests/**` except `ContractTests.swift`.
- sensors: `Sources/PresenceSensors/**`, `Tests/PresenceSensorsTests/**`, `scripts/bench.sh`, `bench/**`, `docs/spikes/**`.
- app: `Sources/ProximityMacApp/**`, `scripts/bundle.sh`, `Resources/**` (Info.plist), `README.md`, `.github/**`.
- Lead only: `Package.swift`, `Sources/PresenceCore/Types.swift`, `Tests/PresenceCoreTests/ContractTests.swift`, `docs/ARCHITECTURE.md`, `GLOSSARY.md`, `docs/adr/**`, `scripts/test.sh`. Need a change there? `hc send` the Lead the exact line.

## Cross-lane dependencies (build against the contract, then `git merge main` once it lands)
- sensors GH-6 calls `Distance.estimate` / `Distance.calibration` (core GH-7, first in its lane).
- app GH-4 runs `PresenceEngine` (core GH-2): until it lands, drive the UI from a fake that returns `[Effect]`, then swap in the engine.
- app uses `DisplayControl`, `IdleSource`, `CameraSource`, `VoiceSource`, `MicUsage` (sensors) only through the protocols in Types.swift. Fakes until they land.
- app GH-13 calls `CommandParser.parse` (core GH-11).

## Shared contract (Sources/PresenceCore/Types.swift, commit GH-1)
- Times are monotonic seconds (`Double`, e.g. `ProcessInfo.processInfo.systemUptime`).
- `Observation(source: SourceKind, person: Bool, distanceCm: Double?, facingScreen: Bool?)`. Close = `person && (distanceCm ?? 0) <= settings.deskRadiusCm`.
- `Command`: `.wake`, `.sleep`, `.hold(minutes:)`.
- `Event`: `.enable`, `.disable`, `.idle(seconds:)`, `.observation(_)`, `.command(_)`, `.micBusy(_)`, `.tick`.
- `Effect`: `.screensOff`, `.screensOn`, `.lock`, `.sample(SamplingMode)`, `.listen(Bool)`, `.showGrace(seconds:)`, `.hideGrace`.
- `SamplingMode`: `.off`, `.checking` (about 1/s), `.watching` (about 1 per 2 s).
- `PresenceState`: `.off`, `.present`, `.checking`, `.grace(until:)`, `.away`, `.hold(until: Double?)`.
- `Settings` (Codable, defaults inline), `Calibration(faceWidthPx:imageWidthPx:distanceCm:)`, `TraceLine(t:event:)` (JSONL).
- Seams: `PresenceSource { kind; setMode(_:); onObservation(_:) }`, `DisplayControlling { screensOff(); screensOn(); lock() }`, `IdleReading { secondsSinceInput() }`, `VoiceListening { start(); stop(); onTranscript(_:) }`, `MicUsageReading { micInUseByOtherApp() }`.
- New in lanes (signatures fixed here):
  - `PresenceEngine` (GH-2): `public struct PresenceEngine { public init(settings: Settings); public private(set) var state: PresenceState; public mutating func handle(_ event: Event, at now: Double) -> [Effect]; public mutating func update(settings: Settings) }`
  - `Distance` (GH-7): `public enum Distance { static func estimate(faceWidthPx: Double, imageWidthPx: Double, calibration: Calibration?) -> Double; static func calibration(fromFaceWidths: [Double], imageWidthPx: Double, distanceCm: Double) -> Calibration? }`
  - `CommandParser` (GH-11): `public enum CommandParser { static func parse(_ transcript: String, triggerWord: String) -> Command? }`
  - `TraceReplay` (GH-9): `public struct TraceReport { falseAways: Int; missedAways: Int; maxWakeLatency: Double }`, `public enum TraceReplay { static func run(_ lines: [TraceLine], truth: [(t: Double, atDesk: Bool)], settings: Settings) -> TraceReport }`
  - Sensors (GH-3/6/12): `public final class DisplayControl: DisplayControlling`, `public struct IdleSource: IdleReading`, `public final class CameraSource: PresenceSource` (+ `func calibrate() async -> Calibration?`), `public final class VoiceSource: VoiceListening`, `public struct MicUsage: MicUsageReading`. Each has a public no-argument init.

## Code map
- `Package.swift`: targets PresenceCore, PresenceSensors (depends on Core), ProximityMacApp (executable, depends on both), PresenceCoreTests (resources `Fixtures/`), PresenceSensorsTests.
- `Sources/PresenceCore/Types.swift`: the whole contract above.
- `Sources/PresenceSensors/PresenceSensors.swift`: `@_exported import PresenceCore` only.
- `Sources/ProximityMacApp/ProximityMacApp.swift`: `@main` MenuBarExtra placeholder with Quit.
- `Tests/PresenceCoreTests/ContractTests.swift`: TraceLine JSON round-trip.
- `Tests/PresenceCoreTests/Fixtures/traces/`: synthetic JSONL traces (README says `# synthetic`).
- `scripts/test.sh`: `swift test` wrapper; pass `--filter`.
- `.github/workflows/ci.yml`: macos-26, `swift build` + `scripts/test.sh`.

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
