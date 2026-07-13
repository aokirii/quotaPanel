import Foundation

/// Derives daily token totals from `~/.codex/sessions/YYYY/MM/DD/*.jsonl`
/// rollout logs. The LAST `token_count` event's `total_token_usage.total_tokens`
/// is that session's total; the day comes from the directory path.
/// Ported from the macOS app minus the file cache (one-shot daemon runs).
enum CodexTokenScanner {
    static let lookbackDays = 35

    static func dailyStats() -> [DailyStat] {
        let root = URL(fileURLWithPath: "\(Paths.home)/.codex/sessions")
        let cutoff = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? .distantPast

        var byDay: [Date: Int] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let day = dayFromPath(url), day >= cutoff else { continue }
            let tokens = parseSessionTotal(url: url)
            if tokens > 0 {
                byDay[day, default: 0] += tokens
            }
        }

        return byDay
            .map { DailyStat(day: $0.key, costUSD: 0, tokens: $0.value) }
            .sorted { $0.day < $1.day }
    }

    /// .../sessions/2026/07/12/rollout-*.jsonl → Jul 12 2026 (local start of day)
    private static func dayFromPath(_ url: URL) -> Date? {
        let parts = url.pathComponents
        guard parts.count >= 4 else { return nil }
        let dayStr = parts[parts.count - 2]
        let monthStr = parts[parts.count - 3]
        let yearStr = parts[parts.count - 4]
        guard let year = Int(yearStr), let month = Int(monthStr), let day = Int(dayStr),
              year > 2000, (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func parseSessionTotal(url: URL) -> Int {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        var lastTotal = 0
        for line in raw.split(separator: "\n") {
            guard line.contains("\"token_count\""), line.contains("total_token_usage") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any],
                  let tokens = total["total_tokens"] as? Int
            else { continue }
            lastTotal = tokens
        }
        return lastTotal
    }
}
