import Foundation

// Offline-usage models ported from the macOS app (Foundation-only). These feed
// the Summary/Heatmap views, the session-window composition, the context bars,
// and the cost chart — all derived from local session logs (Claude/Codex only).

/// input / cache-write / output token composition. Cache *reads* are
/// deliberately excluded: they re-count the same history every turn and
/// would drown out everything else.
public struct TokenParts: Equatable, Sendable {
    public var input = 0
    public var cache = 0
    public var output = 0

    public init() {}

    public var total: Int { input + cache + output }
}

/// Context-window fill of one open session
public struct ContextSnapshot: Equatable, Sendable {
    /// Short label derived from the session's working directory
    public let project: String
    public let model: String
    public let used: Int
    public let limit: Int
    /// Session-cumulative composition (what filled the window)
    public let parts: TokenParts
    /// Reasoning effort (low/medium/high/xhigh/max)
    public let effort: String?
    /// Session mode badge (e.g. Codex "plan")
    public let mode: String?

    public var percent: Double {
        limit > 0 ? Double(used) / Double(limit) * 100 : 0
    }

    /// "Fable 5 · XHigh" — model, effort, and mode on one line
    public var detailLabel: String {
        var pieces = [Self.prettyModel(model)]
        if let effort { pieces.append(Self.prettyEffort(effort)) }
        if let mode { pieces.append(mode) }
        return pieces.joined(separator: " · ")
    }

    /// claude-fable-5 → "Fable 5", claude-opus-4-8 → "Opus 4.8", gpt-5.5 → "GPT-5.5"
    static func prettyModel(_ id: String) -> String {
        if id.hasPrefix("gpt") { return id.uppercased() }
        var pieces = id.split(separator: "-").map(String.init)
        if pieces.first == "claude" { pieces.removeFirst() }
        guard let family = pieces.first else { return id }
        let version = pieces.dropFirst().joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }

    static func prettyEffort(_ effort: String) -> String {
        switch effort.lowercased() {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "XHigh"
        case "max": return "Max"
        default: return effort
        }
    }
}

/// Offline summary: one period's total and composition
public struct HistoryBucket: Equatable, Sendable {
    public let id: String
    public let label: String
    public let parts: TokenParts
}

public struct HeatmapCell: Equatable, Sendable {
    public let tokens: Int
    /// 0 (empty) ... 4 (busiest)
    public let level: Int
}

public struct HeatmapHourRow: Equatable, Sendable {
    public let dayLabel: String
    public let cells: [HeatmapCell]
}

/// One provider's offline + heatmap data (computed on demand)
public struct ProviderActivity: Equatable, Sendable {
    public let history: [HistoryBucket]
    /// GitHub-style daily grid: week columns × 7 days (Mon...Sun); future days nil
    public let dailyGrid: [[HeatmapCell?]]
    public let hourRows: [HeatmapHourRow]
    public let totalTokens: Int
}

/// Daily statistic for charts and totals
public struct DailyStat: Equatable, Sendable {
    /// Start of day in the local calendar
    public let day: Date
    /// Estimated USD cost for Claude; 0 for Codex
    public let costUSD: Double
    /// Total tokens (input + output + cache)
    public let tokens: Int
}

/// Everything derived from one provider's local logs, gathered per refresh
public struct ProviderExtras: Sendable {
    public var sessionParts: TokenParts?
    public var contexts: [ContextSnapshot] = []
    public var daily: [DailyStat] = []
    public var activity: ProviderActivity?

    public init() {}
}
