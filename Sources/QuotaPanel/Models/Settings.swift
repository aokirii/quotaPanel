import Foundation
import Observation

/// UserDefaults destekli kullanıcı ayarları
@MainActor
@Observable
final class Settings {
    static let maxAlertThresholds = 6

    /// Yenileme aralığı, saniye (30 sn adımlarla ayarlanır)
    var refreshSeconds: Int {
        didSet { UserDefaults.standard.set(refreshSeconds, forKey: "refreshSeconds") }
    }
    /// Doluluk uyarı eşikleri (%). Boş liste bildirimleri kapatır.
    var alertThresholds: [Double] {
        didSet { UserDefaults.standard.set(alertThresholds, forKey: "alertThresholds") }
    }
    var claudeEnabled: Bool {
        didSet { UserDefaults.standard.set(claudeEnabled, forKey: "claudeEnabled") }
    }
    var codexEnabled: Bool {
        didSet { UserDefaults.standard.set(codexEnabled, forKey: "codexEnabled") }
    }
    /// Menü çubuğunda yüzde metni gösterilsin mi (kapalıysa sadece ikon)
    var showPercentInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showPercentInMenuBar, forKey: "showPercentInMenuBar") }
    }

    init() {
        let d = UserDefaults.standard
        // Eski kurulumlardan geçiş: refreshMinutes → refreshSeconds,
        // warnThreshold/criticalThreshold çifti → eşik listesi
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
        self.claudeEnabled = d.object(forKey: "claudeEnabled") as? Bool ?? true
        self.codexEnabled = d.object(forKey: "codexEnabled") as? Bool ?? true
        self.showPercentInMenuBar = d.object(forKey: "showPercentInMenuBar") as? Bool ?? true
    }

    /// "30 s", "5 min", "1.5 min" biçiminde aralık etiketi
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
        provider == .claude ? claudeEnabled : codexEnabled
    }
}
