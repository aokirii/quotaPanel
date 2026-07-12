import Foundation

enum Provider: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// Short name used in the compact menu bar label
    var shortLabel: String {
        switch self {
        case .claude: "C"
        case .codex: "X"
        }
    }
}

/// One rate-limit window: e.g. the 5-hour session or the weekly window
struct RateWindow: Identifiable, Equatable {
    var id: String { label }
    let label: String
    /// Fill percentage, 0...100
    let percent: Double
    let resetsAt: Date?

    var clampedPercent: Double { min(max(percent, 0), 100) }
}

enum SnapshotStatus: Equatable {
    case loading
    case ok
    /// Credentials missing or expired; the user is told how to sign in
    case authProblem(String)
    case error(String)
}

struct ProviderSnapshot: Equatable {
    let provider: Provider
    var status: SnapshotStatus
    var windows: [RateWindow]
    var planName: String?
    var updatedAt: Date?

    static func initial(provider: Provider) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, status: .loading, windows: [], planName: nil, updatedAt: nil)
    }

    /// Fullest window, used for the menu bar label
    var worstWindow: RateWindow? {
        windows.max(by: { $0.percent < $1.percent })
    }
}
