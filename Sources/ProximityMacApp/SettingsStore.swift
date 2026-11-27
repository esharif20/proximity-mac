import Foundation
import PresenceCore

/// `Settings` as one JSON value in UserDefaults, so a new field with a default never breaks old data.
struct SettingsStore {
    private let defaults: UserDefaults
    private let settingsKey = "settings"
    private let enabledKey = "enabled"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> Settings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return settings
    }

    func save(_ settings: Settings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: settingsKey)
    }

    /// The menu toggle survives relaunch; a fresh install starts on.
    var enabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: enabledKey) }
    }
}
