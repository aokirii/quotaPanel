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

    /// Menü çubuğundaki kompakt etikette kullanılan kısa ad
    var shortLabel: String {
        switch self {
        case .claude: "C"
        case .codex: "X"
        }
    }
}

/// Tek bir limit penceresi: ör. "5 saatlik oturum" veya "haftalık"
struct RateWindow: Identifiable, Equatable {
    var id: String { label }
    let label: String
    /// 0...100 arası doluluk yüzdesi
    let percent: Double
    let resetsAt: Date?

    var clampedPercent: Double { min(max(percent, 0), 100) }
}

enum SnapshotStatus: Equatable {
    case loading
    case ok
    /// Kimlik bilgisi yok ya da süresi dolmuş; kullanıcıya CLI'ı çalıştırması söylenir
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

    /// Menü çubuğu etiketi için en dolu pencere
    var worstWindow: RateWindow? {
        windows.max(by: { $0.percent < $1.percent })
    }
}
