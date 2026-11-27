import Foundation
import PresenceCore
import Testing

@Test func traceLineRoundTripsThroughJSON() throws {
    let line = TraceLine(t: 12.5, event: .observation(Observation(source: .camera, person: true, distanceCm: 70)))
    let data = try JSONEncoder().encode(line)
    #expect(try JSONDecoder().decode(TraceLine.self, from: data) == line)
}

@Test func defaultSettingsNeverLock() {
    #expect(Settings().lockWhenAway == false)
}
