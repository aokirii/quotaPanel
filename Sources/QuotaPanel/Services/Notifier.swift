import Foundation
import UserNotifications

/// Limit eşiği aşıldığında ve limit sıfırlandığında macOS bildirimi gönderir.
/// Aynı pencere döngüsü içinde aynı eşik için tekrar bildirim atmaz.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var authorized = false
    /// "provider|window" → bildirilen en yüksek eşik
    private var notifiedThreshold: [String: Double] = [:]

    /// Bildirimler yalnızca .app paketinden çalışır; çıplak binary'de
    /// UNUserNotificationCenter çöker, o yüzden kontrol şart.
    static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func setup() {
        guard Self.isSupported else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    func check(snapshot: ProviderSnapshot, thresholds: [Double]) {
        guard Self.isSupported, authorized, case .ok = snapshot.status, !thresholds.isEmpty else { return }

        for window in snapshot.windows {
            let key = "\(snapshot.provider.rawValue)|\(window.label)"
            let percent = window.clampedPercent
            let previous = notifiedThreshold[key]

            // Sıfırlanma: daha önce uyarı verilmişti, şimdi belirgin şekilde düştü
            if let prev = previous, prev >= (thresholds.min() ?? 0), percent < 10 {
                notifiedThreshold[key] = nil
                send(
                    title: "\(snapshot.provider.displayName) limit reset",
                    body: "\(window.label) is available again."
                )
                continue
            }

            if let crossed = Self.newlyCrossedThreshold(percent: percent, previous: previous, thresholds: thresholds) {
                notifiedThreshold[key] = crossed
                send(
                    title: "\(snapshot.provider.displayName): \(formatPercent(percent))% used",
                    body: "\(window.label) crossed the \(Int(crossed))% threshold." + resetSuffix(window)
                )
            }
        }
    }

    /// Aşılan en yüksek eşik, daha önce bildirilenden yüksekse onu döndürür.
    /// Bir yenilemede birden çok eşik birden aşılırsa tek (en yüksek) bildirim atılır.
    nonisolated static func newlyCrossedThreshold(percent: Double, previous: Double?, thresholds: [Double]) -> Double? {
        guard let crossed = thresholds.filter({ percent >= $0 }).max(),
              crossed > previous ?? 0
        else { return nil }
        return crossed
    }

    private func resetSuffix(_ window: RateWindow) -> String {
        guard let resetsAt = window.resetsAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return " Resets \(formatter.localizedString(for: resetsAt, relativeTo: Date()))."
    }

    private func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // Uygulama önplandayken de banner göster
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
