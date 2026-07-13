import Foundation
import Observation

/// User settings backed by UserDefaults
@MainActor
@Observable
final class Settings {
    static let maxAlertThresholds = 6

    /// Refresh interval in seconds (adjusted in 30 s steps)
    var refreshSeconds: Int {
        didSet { UserDefaults.standard.set(refreshSeconds, forKey: "refreshSeconds") }
    }
    /// Usage alert thresholds (%). An empty list disables notifications.
    var alertThresholds: [Double] {
        didSet { UserDefaults.standard.set(alertThresholds, forKey: "alertThresholds") }
    }
    /// Enabled providers by rawValue; defaults to providers whose tools have
    /// left credentials on this machine
    var enabledProviders: Set<String> {
        didSet { UserDefaults.standard.set(Array(enabledProviders).sorted(), forKey: "enabledProviders") }
    }
    /// Whether to show the percent text in the menu bar (icon only when off)
    var showPercentInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showPercentInMenuBar, forKey: "showPercentInMenuBar") }
    }

    init() {
        let d = UserDefaults.standard
        // Migration from older installs: refreshMinutes → refreshSeconds,
        // warnThreshold/criticalThreshold pair → threshold list
        if let seconds = d.object(forKey: "refreshSeconds") as? Int {
            self.refreshSeconds = seconds
        } else if let minutes = d.object(forKey: "refreshMinutes") as? Int {
            self.refreshSeconds = minutes * 60
        } else {
            self.refreshSeconds = 300
        }
        if let list = d.object(forKey: "alertThresholds") as? [Double] {
            self.alertThresholds = list
        } else {
            let warn = d.object(forKey: "warnThreshold") as? Double ?? 80
            let critical = d.object(forKey: "criticalThreshold") as? Double ?? 95
            self.alertThresholds = warn == critical ? [warn] : [warn, critical].sorted()
        }
        if let list = d.object(forKey: "enabledProviders") as? [String] {
            self.enabledProviders = Set(list)
        } else {
            // Migration from the two-provider era + auto-detection for the rest
            var initial = Set<String>()
            if d.object(forKey: "claudeEnabled") as? Bool ?? true { initial.insert(Provider.claude.rawValue) }
            if d.object(forKey: "codexEnabled") as? Bool ?? true { initial.insert(Provider.codex.rawValue) }
            for provider in Provider.allCases where provider.hasLocalCredentials {
                initial.insert(provider.rawValue)
            }
            self.enabledProviders = initial
        }
        self.showPercentInMenuBar = d.object(forKey: "showPercentInMenuBar") as? Bool ?? true
    }

    /// Interval label like "30 s", "5 min", "1.5 min"
    var refreshLabel: String {
        if refreshSeconds < 60 { return "\(refreshSeconds) s" }
        if refreshSeconds % 60 == 0 { return "\(refreshSeconds / 60) min" }
        return String(format: "%.1f min", Double(refreshSeconds) / 60)
    }

    func addAlertThreshold() {
        guard alertThresholds.count < Self.maxAlertThresholds else { return }
        var candidate = min(99, (alertThresholds.max() ?? 45) + 10)
        while alertThresholds.contains(candidate), candidate > 5 {
            candidate -= 5
        }
        alertThresholds.append(candidate)
        alertThresholds.sort()
    }

    func removeAlertThreshold(at index: Int) {
        guard alertThresholds.indices.contains(index) else { return }
        alertThresholds.remove(at: index)
    }

    func isEnabled(_ provider: Provider) -> Bool {
        enabledProviders.contains(provider.rawValue)
    }

    func setEnabled(_ provider: Provider, _ enabled: Bool) {
        if enabled {
            enabledProviders.insert(provider.rawValue)
        } else {
            enabledProviders.remove(provider.rawValue)
        }
    }
}
