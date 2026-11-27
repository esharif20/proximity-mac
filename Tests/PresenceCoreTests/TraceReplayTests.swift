import Foundation
import PresenceCore
import Testing

private struct Label: Decodable { var t: Double; var atDesk: Bool }

private func jsonLines<T: Decodable>(_ name: String, as: T.Type) throws -> [T] {
    let dir = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    let text = try String(contentsOf: dir.appending(path: "traces/\(name)"), encoding: .utf8)
    return try text.split(separator: "\n")
        .filter { !$0.hasPrefix("#") && !$0.isEmpty }
        .map { try JSONDecoder().decode(T.self, from: Data($0.utf8)) }
}

private func replay(_ name: String, _ settings: Settings = Settings()) throws -> TraceReport {
    let lines = try jsonLines("\(name).jsonl", as: TraceLine.self)
    let truth = try jsonLines("\(name).truth.jsonl", as: Label.self).map { (t: $0.t, atDesk: $0.atDesk) }
    return TraceReplay.run(lines, truth: truth, settings: settings)
}

@Suite struct TraceReplayTests {
    static let atDesk = ["reading", "video", "walk_behind"]
    static let leaving = ["walk_to_bed", "coming_back", "voice_hold_from_bed"]

    @Test(arguments: atDesk) func atDeskTracesNeverGoAway(name: String) throws {
        let r = try replay(name)
        #expect(r.falseAways == 0)
    }

    @Test(arguments: leaving) func leavingTracesGoAwayInTimeAndNeverFalsely(name: String) throws {
        let r = try replay(name)
        #expect(r.missedAways == 0)
        #expect(r.falseAways == 0)
    }

    @Test func comingBackWakesWithinThreeSeconds() throws {
        #expect(try replay("coming_back").maxWakeLatency <= 3)
    }

    // The gates must be able to fail, or they prove nothing.

    @Test func aCameraThatKeepsSeeingAFaceMissesTheAway() throws {
        let face = Event.observation(Observation(source: .camera, person: true, distanceCm: 60))
        let lines = try jsonLines("walk_to_bed.jsonl", as: TraceLine.self).map { line in
            if case .observation = line.event { return TraceLine(t: line.t, event: face) }
            return line
        }
        let r = TraceReplay.run(lines, truth: [(t: 0, atDesk: true), (t: 25, atDesk: false)], settings: Settings())
        #expect(r.missedAways == 1)
    }

    @Test func aTinyDeskRadiusGoesAwayFalselyWhileReading() throws {
        var s = Settings()
        s.deskRadiusCm = 10
        #expect(try replay("reading", s).falseAways > 0)
    }

    @Test func wakeLatencyCountsFromTheFirstCloseSighting() {
        let face = Observation(source: .camera, person: true, distanceCm: 60)
        // Said at the desk, so the face at 10 s does not wake; typing at 15 s does.
        let lines = [TraceLine(t: 0, event: .idle(seconds: 5)), TraceLine(t: 1, event: .command(.sleep)),
                     TraceLine(t: 10, event: .observation(face)), TraceLine(t: 12, event: .idle(seconds: 17)),
                     TraceLine(t: 15, event: .idle(seconds: 0))]
        let truth = [(t: 0.0, atDesk: false), (t: 10.0, atDesk: true)]
        #expect(TraceReplay.run(lines, truth: truth, settings: Settings()).maxWakeLatency == 5)
    }
}
