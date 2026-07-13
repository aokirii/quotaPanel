import Foundation

/// Scans `~/.claude/projects/**/*.jsonl` and derives estimated daily cost.
///
/// Ported from the macOS app minus the incremental file cache (the daemon
/// computes once per refresh and exits). Dedup stays: the same `message.id`
/// can appear in multiple files/lines (session continuation/forking); the
/// last one seen wins.
enum ClaudeCostScanner {
    struct MessageStat: Sendable {
        let day: Date
        let costUSD: Double
        let tokens: Int
    }

    static let lookbackDays = 35

    static func dailyStats() -> [DailyStat] {
        let root = URL(fileURLWithPath: "\(Paths.home)/.claude/projects")
        let cutoff = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? .distantPast

        var merged: [String: MessageStat] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { continue }
            // If the file last changed before the cutoff, every message in it is older too
            guard mtime >= cutoff else { continue }
            merged.merge(parseFile(url: url, cutoff: cutoff)) { _, new in new }
        }

        var byDay: [Date: (cost: Double, tokens: Int)] = [:]
        for stat in merged.values {
            byDay[stat.day, default: (0, 0)].cost += stat.costUSD
            byDay[stat.day]!.tokens += stat.tokens
        }
        return byDay
            .map { DailyStat(day: $0.key, costUSD: $0.value.cost, tokens: $0.value.tokens) }
            .sorted { $0.day < $1.day }
    }

    private static func parseFile(url: URL, cutoff: Date) -> [String: MessageStat] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let calendar = Calendar.current

        var result: [String: MessageStat] = [:]
        for line in raw.split(separator: "\n") {
            // Cheap filter before JSON decoding
            guard line.contains("\"assistant\""), line.contains("\"usage\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let id = message["id"] as? String,
                  let model = message["model"] as? String,
                  let usage = message["usage"] as? [String: Any],
                  let timestampStr = obj["timestamp"] as? String,
                  let timestamp = isoFractional.date(from: timestampStr) ?? isoPlain.date(from: timestampStr),
                  timestamp >= cutoff
            else { continue }

            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0

            // With a cache_creation breakdown use the 5m/1h split, else count the total as 5m
            var cacheWrite5m = 0
            var cacheWrite1h = 0
            if let breakdown = usage["cache_creation"] as? [String: Any] {
                cacheWrite5m = breakdown["ephemeral_5m_input_tokens"] as? Int ?? 0
                cacheWrite1h = breakdown["ephemeral_1h_input_tokens"] as? Int ?? 0
            }
            if cacheWrite5m == 0 && cacheWrite1h == 0 {
                cacheWrite5m = usage["cache_creation_input_tokens"] as? Int ?? 0
            }

            let cost = Pricing.cost(
                model: model,
                inputTokens: input,
                outputTokens: output,
                cacheWrite5m: cacheWrite5m,
                cacheWrite1h: cacheWrite1h,
                cacheRead: cacheRead
            )
            let tokens = input + output + cacheWrite5m + cacheWrite1h + cacheRead
            result[id] = MessageStat(day: calendar.startOfDay(for: timestamp), costUSD: cost, tokens: tokens)
        }
        return result
    }
}
