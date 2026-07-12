import Foundation

/// input / cache-write / output token composition. Cache *reads* are
/// deliberately excluded: they re-count the same history every turn and
/// would drown out everything else.
struct TokenParts: Equatable, Sendable {
    var input = 0
    var cache = 0
    var output = 0

    var total: Int { input + cache + output }

    /// Each part's share of the total (0...1); all zero when the total is zero
    var fractions: (input: Double, cache: Double, output: Double) {
        let t = Double(max(total, 1))
        return (Double(input) / t, Double(cache) / t, Double(output) / t)
    }
}

/// Context-window fill of one open session
struct ContextSnapshot: Identifiable, Equatable, Sendable {
    /// Path of the session's jsonl file
    let id: String
    /// Short label derived from the session's working directory
    let project: String
    let model: String
    let used: Int
    let limit: Int
    /// Session-cumulative composition (what filled the window)
    let parts: TokenParts
    /// Reasoning effort (low/medium/high/xhigh/max); from the global setting
    /// for Claude, from the session's turn_context for Codex
    var effort: String?
    /// Session mode badge (e.g. Codex "plan")
    var mode: String?

    var percent: Double {
        limit > 0 ? Double(used) / Double(limit) * 100 : 0
    }

    /// "Fable 5 · XHigh" — model, effort, and mode on one line
    var detailLabel: String {
        var parts = [Self.prettyModel(model)]
        if let effort { parts.append(Self.prettyEffort(effort)) }
        if let mode { parts.append(mode) }
        return parts.joined(separator: " · ")
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
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "XHigh"
        case "max": "Max"
        default: effort
        }
    }
}

/// Offline summary: one period's total and composition
struct HistoryBucket: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let parts: TokenParts
}

struct HeatmapCell: Equatable, Sendable {
    let label: String
    let tokens: Int
    /// 0 (empty) ... 4 (busiest)
    let level: Int
}

struct HeatmapHourRow: Identifiable, Equatable, Sendable {
    let id: String
    let dayLabel: String
    let cells: [HeatmapCell]
}

/// One provider's offline + heatmap data (computed on demand)
struct ProviderActivity: Equatable, Sendable {
    let history: [HistoryBucket]
    /// GitHub-style daily grid: week columns × 7 days (Mon...Sun); future days nil
    let dailyGrid: [[HeatmapCell?]]
    let hourRows: [HeatmapHourRow]
    let totalTokens: Int
}

/// Compact token count like 1.2M / 45.3K
func formatTokenCount(_ value: Int) -> String {
    switch value {
    case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
    case 1_000...: String(format: "%.1fK", Double(value) / 1_000)
    default: "\(value)"
    }
}

/// Percent label: one decimal when fractional (3.1), no decimal when whole (32)
func formatPercent(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    return rounded == rounded.rounded()
        ? String(Int(rounded))
        : String(format: "%.1f", rounded)
}
