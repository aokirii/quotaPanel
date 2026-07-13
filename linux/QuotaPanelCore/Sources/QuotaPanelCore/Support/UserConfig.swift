import Foundation

/// User settings shared between the GNOME extension (writer, via its in-panel
/// Settings page) and the daemon (reader). Lives at
/// `~/.config/quotapanel/config.json`. Every field is optional so old or
/// partial files keep working; unknown keys are ignored.
public struct UserConfig: Codable, Equatable {
    /// Enabled providers by rawValue; nil means "all supported".
    public var enabledProviders: [String]?
    /// Auto-refresh cadence used by the extension when it spawns the daemon.
    public var refreshSeconds: Int?
    /// Usage alert thresholds (%). An empty list disables notifications.
    public var alertThresholds: [Double]?
    /// Whether the top-bar button shows the percent text next to the icon.
    public var showPercentInTopBar: Bool?

    public init() {}

    public static func load(path: String = Paths.configFile) -> UserConfig? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(UserConfig.self, from: data)
    }

    /// The provider set the daemon should fetch by default: the enabled ones,
    /// falling back to all supported when unset/empty/unreadable.
    public func providerFilter(from supported: [Provider]) -> [Provider] {
        guard let names = enabledProviders, !names.isEmpty else { return supported }
        let enabled = Set(names.map { $0.lowercased() })
        let filtered = supported.filter { enabled.contains($0.rawValue) }
        return filtered.isEmpty ? supported : filtered
    }
}
