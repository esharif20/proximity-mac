import Foundation

/// Turns a transcript into a Command. Strict on purpose: a false match turns the screens off
/// or keeps them on, so anything unusual is ignored rather than guessed.
public enum CommandParser {
    static let maxHoldMinutes = 240
    /// Beyond a day the number was misheard, not meant.
    static let absurdMinutes = 24 * 60

    static let wake: Set<[String]> = [["wake", "up"], ["turn", "on"]]
    static let sleep: Set<[String]> = [["go", "to", "sleep"], ["sleep"], ["turn", "off"]]
    static let holdPrefixes: [[String]] = [["keep", "it", "on", "for"], ["keep", "on", "for"], ["stay", "on", "for"], ["for"], []]
    static let negations: Set<String> = ["dont", "not", "never", "no", "stop"]

    static let units: [String: Int] = ["one": 1, "a": 1, "an": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19]
    static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90]

    public static func parse(_ transcript: String, triggerWord: String) -> Command? {
        let trigger = words(triggerWord)
        guard !trigger.isEmpty else { return nil }
        var rest = words(transcript)
        if rest.first == "hey" { rest.removeFirst() }
        guard rest.starts(with: trigger) else { return nil }
        rest.removeFirst(trigger.count)
        rest.removeAll { $0 == "please" }
        guard !rest.contains(where: negations.contains) else { return nil }

        if wake.contains(rest) { return .wake }
        if sleep.contains(rest) { return .sleep }
        for prefix in holdPrefixes where rest.starts(with: prefix) {
            if let minutes = duration(Array(rest.dropFirst(prefix.count))) {
                guard minutes >= 1, minutes <= absurdMinutes else { return nil }
                return .hold(minutes: min(minutes, maxHoldMinutes))
            }
        }
        return nil
    }

    /// Lowercase words with punctuation dropped; apostrophes vanish so "don't" reads as "dont".
    static func words(_ s: String) -> [String] {
        let joined = s.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        return joined.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Minutes for a whole phrase such as "ten minutes", "2 hours" or "half an hour"; nil if anything is left over.
    static func duration(_ w: [String]) -> Int? {
        if w == ["half", "an", "hour"] { return 30 }
        guard w.count >= 2, let unit = w.last else { return nil }
        let perUnit: Int
        switch unit {
        case "min", "mins", "minute", "minutes": perUnit = 1
        case "hour", "hours", "hr", "hrs": perUnit = 60
        default: return nil
        }
        guard let n = number(Array(w.dropLast())) else { return nil }
        let (total, overflow) = n.multipliedReportingOverflow(by: perUnit)
        return overflow ? nil : total
    }

    static func number(_ w: [String]) -> Int? {
        if w.count == 1, let n = Int(w[0]) { return n }
        if w.count == 1 { return units[w[0]] ?? tens[w[0]] }
        if w.count == 2, let t = tens[w[0]], let u = units[w[1]], u < 10, w[1] != "a", w[1] != "an" { return t + u }
        return nil
    }
}
