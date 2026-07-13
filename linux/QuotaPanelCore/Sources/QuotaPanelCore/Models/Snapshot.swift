import Foundation

/// One rate-limit window: e.g. the 5-hour session or the weekly window.
/// Ported verbatim from the macOS model (Foundation-only, already portable).
public struct RateWindow: Identifiable, Equatable, Sendable {
    public var id: String { label }
    public let label: String
    /// Fill percentage, 0...100 (percent USED).
    public let percent: Double
    public let resetsAt: Date?

    public init(label: String, percent: Double, resetsAt: Date?) {
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
    }

    public var clampedPercent: Double { min(max(percent, 0), 100) }
}

public enum SnapshotStatus: Equatable, Sendable {
    case loading
    case ok
    /// Credentials missing or expired; the user is told how to sign in.
    case authProblem(String)
    case error(String)
}

public struct ProviderSnapshot: Equatable, Sendable {
    public let provider: Provider
    public var status: SnapshotStatus
    public var windows: [RateWindow]
    public var planName: String?
    public var updatedAt: Date?

    public init(provider: Provider, status: SnapshotStatus, windows: [RateWindow], planName: String?, updatedAt: Date?) {
        self.provider = provider
        self.status = status
        self.windows = windows
        self.planName = planName
        self.updatedAt = updatedAt
    }

    public static func initial(provider: Provider) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, status: .loading, windows: [], planName: nil, updatedAt: nil)
    }

    /// Fullest window, used for the compact label.
    public var worstWindow: RateWindow? {
        windows.max(by: { $0.percent < $1.percent })
    }
}
