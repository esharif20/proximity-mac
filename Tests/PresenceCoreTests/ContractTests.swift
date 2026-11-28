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

@Test func settingsSavedBeforeANewFieldKeepTheirValues() throws {
    let old = #"{"graceSeconds": 20, "triggerWord": "monitor"}"#.data(using: .utf8)!
    let settings = try JSONDecoder().decode(Settings.self, from: old)
    #expect(settings.graceSeconds == 20)
    #expect(settings.triggerWord == "monitor")
    #expect(settings.stopWatchingAfterMinutes == 15)
}

@Test func settingsRoundTripThroughJSON() throws {
    var settings = Settings()
    settings.stopWatchingAfterMinutes = 5
    settings.calibration = Calibration(faceWidthPx: 120, imageWidthPx: 640)
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(Settings.self, from: data) == settings)
}

@Test func ownerFeaturesAreOffByDefaultAndSurviveOldSettings() throws {
    let old = #"{"graceSeconds": 20}"#.data(using: .utf8)!
    let settings = try JSONDecoder().decode(Settings.self, from: old)
    #expect(settings.onlyWakeForMe == false)
    #expect(settings.voiceNeedsMe == false)
    #expect(settings.setupDone == false)
    #expect(Observation(source: .camera, person: true).owner == nil)
}
