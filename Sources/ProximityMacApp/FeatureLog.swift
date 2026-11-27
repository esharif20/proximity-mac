import Foundation
import PresenceCore

/// The opt-in feature log: one JSONL file per day of `TraceLine`s, numbers only, so a wrong
/// decision can be replayed later. Nothing here can hold a frame, audio or a transcript, because
/// `Event` carries none.
final class FeatureLog {
    private let directory: URL
    private var handle: FileHandle?
    private var day: String?
    private let encoder = JSONEncoder()
    private let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format
    }()

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "ProximityMac/traces")) {
        self.directory = directory
        encoder.outputFormatting = .sortedKeys
    }

    func append(_ line: TraceLine) {
        write(try? encoder.encode(line))
    }

    /// A marker line beside the trace lines: `{"marker":"wrong","t":...}`.
    func markWrong(at t: Double) {
        write(try? encoder.encode(Marker(t: t, marker: "wrong")))
    }

    func close() {
        try? handle?.close()
        handle = nil
        day = nil
    }

    private func write(_ data: Data?) {
        guard let data, let handle = openToday() else { return }
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    private func openToday() -> FileHandle? {
        let today = dayFormat.string(from: .now)
        if today == day, let handle { return handle }
        close()
        let file = directory.appending(path: "\(today).jsonl")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let opened = try FileHandle(forWritingTo: file)
            try opened.seekToEnd()
            handle = opened
            day = today
            return opened
        } catch {
            return nil
        }
    }

    private struct Marker: Encodable {
        var t: Double
        var marker: String
    }
}
