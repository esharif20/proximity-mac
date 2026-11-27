import PresenceCore
import Testing

@Suite struct CommandParserTests {
    private func parse(_ s: String) -> Command? { CommandParser.parse(s, triggerWord: "screen") }

    @Test(arguments: ["Screen, wake up", "screen wake up.", "Hey screen, turn on!", "SCREEN TURN ON", "screen, please wake up"])
    func wakes(_ s: String) { #expect(parse(s) == .wake) }

    @Test(arguments: ["Screen, go to sleep", "screen sleep", "Hey, Screen: turn off.", "screen go to sleep please"])
    func sleeps(_ s: String) { #expect(parse(s) == .sleep) }

    @Test func holds() {
        #expect(parse("Screen, keep it on for ten minutes") == .hold(minutes: 10))
        #expect(parse("screen for 10 min") == .hold(minutes: 10))
        #expect(parse("Screen, half an hour") == .hold(minutes: 30))
        #expect(parse("screen keep it on for an hour") == .hold(minutes: 60))
        #expect(parse("screen keep it on for twenty five minutes") == .hold(minutes: 25))
        #expect(parse("screen keep it on for 2 hours") == .hold(minutes: 120))
        #expect(parse("screen for a minute") == .hold(minutes: 1))
    }

    @Test func holdsAreClamped() {
        #expect(parse("screen keep it on for 5 hours") == .hold(minutes: 240))
    }

    @Test func usesTheConfiguredTriggerWord() {
        #expect(CommandParser.parse("Monitor, wake up", triggerWord: "Monitor") == .wake)
        #expect(CommandParser.parse("screen wake up", triggerWord: "monitor") == nil)
    }

    @Test(arguments: [
        "wake up",
        "go to sleep",
        "the screen is going to sleep",
        "my screen, wake up",
        "I said screen wake up",
        "screen don't go to sleep",
        "screen, do not turn off",
        "screen never sleep",
        "screen not now, wake up",
        "screen keep it on for 99999 minutes",
        "screen keep it on for 0 minutes",
        "screen keep it on for 1000 hours",
        "screen turn off the lights",
        "screen wake up and go to sleep",
        "screensaver wake up",
        "hey hey screen wake up",
        "screen",
        "",
        "   ,,, ",
        "screen for minutes",
    ])
    func rejects(_ s: String) { #expect(parse(s) == nil, "\(s)") }

    @Test func emptyTriggerWordMatchesNothing() {
        #expect(CommandParser.parse("wake up", triggerWord: "") == nil)
        #expect(CommandParser.parse("wake up", triggerWord: " ,") == nil)
    }
}
