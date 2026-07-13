import Foundation
import Observation
import UserNotifications
#if canImport(AppKit)
import AppKit
#endif

/// User-facing notification permission state, surfaced in Settings so a silent
/// denial by macOS is visible instead of failing quietly.
enum NotificationPermission {
    case unknown        // not checked yet
    case unsupported    // not running from a .app bundle
    case notDetermined  // the system prompt hasn't been answered yet
    case denied         // blocked — must be enabled in System Settings
    case authorized
    case provisional    // quiet delivery only

    /// Whether the system will actually deliver a notification in this state.
    var isDelivering: Bool { self == .authorized || self == .provisional }
}

/// Sends macOS notifications when a threshold is crossed and when a limit
/// resets. Never repeats the same threshold within one window cycle.
@MainActor
@Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// "provider|window" → highest threshold notified so far
    private var notifiedThreshold: [String: Double] = [:]

    /// Live permission state; read by Settings to show status and guidance.
    private(set) var permission: NotificationPermission = .unknown
    /// Last authorization/delivery error reported by the system, if any.
    private(set) var lastError: String?

    /// Notifications only work from a .app bundle; UNUserNotificationCenter
    /// crashes in a bare binary, hence the check.
    static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private var authorized: Bool { permission.isDelivering }

    func setup() {
        guard Self.isSupported else { permission = .unsupported; return }
        UNUserNotificationCenter.current().delegate = self
        requestAuthorization()
    }

    /// Asks the system for permission. Shows the prompt while the status is
    /// still `notDetermined`; once denied, macOS won't prompt again and the
    /// user must enable it in System Settings instead.
    func requestAuthorization() {
        guard Self.isSupported else { permission = .unsupported; return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.lastError = error.localizedDescription }
                await self?.refreshStatus()
            }
        }
    }

    /// Re-reads the system authorization status into `permission`. Called after
    /// the initial request and whenever Settings appears, so a permission the
    /// user grants in System Settings is picked up without a relaunch.
    func refreshStatus() async {
        guard Self.isSupported else { permission = .unsupported; return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        permission = Self.map(settings.authorizationStatus)
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationPermission {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .authorized
        @unknown default: .unknown
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

    /// Posts a test notification so the user can confirm end-to-end delivery.
    func sendTest() {
        send(
            title: "QuotaPanel test",
            body: "Notifications are working — you'll be alerted at your thresholds."
        )
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
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }
    }

    #if canImport(AppKit)
    /// Opens System Settings → Notifications so the user can enable delivery
    /// when macOS has denied (or never prompted for) permission.
    func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
    #endif

    // Show the banner while the app is in the foreground too
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
