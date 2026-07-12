import Foundation
import UserNotifications

/// Sends macOS notifications when a threshold is crossed and when a limit
/// resets. Never repeats the same threshold within one window cycle.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var authorized = false
    /// "provider|window" → highest threshold notified so far
    private var notifiedThreshold: [String: Double] = [:]

    /// Notifications only work from a .app bundle; UNUserNotificationCenter
    /// crashes in a bare binary, hence the check.
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

            // Reset: a warning was sent earlier and usage has now clearly dropped
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

    /// Returns the highest crossed threshold if it exceeds the one already
    /// notified. Crossing several thresholds in one refresh yields a single
    /// (highest) notification.
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

    // Show the banner while the app is in the foreground too
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
