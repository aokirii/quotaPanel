import Foundation

/// Daily statistic for charts and totals
struct DailyStat: Identifiable, Equatable, Sendable {
    /// Start of day in the local calendar
    let day: Date
    /// Estimated USD cost for Claude; 0 for Codex
    let costUSD: Double
    /// Total tokens (input + output + cache)
    let tokens: Int

    var id: Date { day }
}
