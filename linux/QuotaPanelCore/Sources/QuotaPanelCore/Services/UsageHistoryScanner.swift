import Foundation

/// Produces the offline summary (24h/7d/30d), heatmaps, and window
/// composition from local session logs. Ported from the macOS app; the actor
/// cache is dropped — the daemon computes once per refresh and exits, so
/// nothing outlives a run. Files older than the cutoff are skipped by mtime.
enum UsageHistoryScanner {
    struct Event: Sendable {
        let ts: Date
        let input: Int
        let cache: Int
        let output: Int
    }

    // MARK: - Public API

    static func claudeActivity() -> ProviderActivity {
        aggregate(events: claudeEvents(since: gridStart()))
    }

    static func codexActivity() -> ProviderActivity {
        aggregate(events: codexEvents(since: gridStart()))
    }

    /// Composition over the last `hours` hours — used to split the session window bar
    static func claudeWindowParts(hours: Double) -> TokenParts {
        sumParts(claudeEvents(since: Date(timeIntervalSinceNow: -hours * 3600)))
    }

    static func codexWindowParts(hours: Double) -> TokenParts {
        sumParts(codexEvents(since: Date(timeIntervalSinceNow: -hours * 3600)))
    }

    // MARK: - Event sources

    /// Claude: (ts, input, cache-write, output) per usage record.
    /// Cache reads excluded.
    static func claudeEvents(since cutoff: Date) -> [Event] {
        let root = URL(fileURLWithPath: "\(Paths.home)/.claude/projects")
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var events: [Event] = []
        for url in jsonlFiles(under: root, modifiedAfter: cutoff) {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in raw.split(separator: "\n") {
                guard line.contains("\"usage\"") else { continue }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let message = obj["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let tsStr = obj["timestamp"] as? String,
                      let ts = isoFractional.date(from: tsStr) ?? isoPlain.date(from: tsStr),
                      ts >= cutoff
                else { continue }
                events.append(Event(
                    ts: ts,
                    input: usage["input_tokens"] as? Int ?? 0,
                    cache: cacheWriteTokens(usage),
                    output: usage["output_tokens"] as? Int ?? 0
                ))
            }
        }
        return events
    }

    /// Codex: each turn's incremental `last_token_usage`. Cached prompt tokens
    /// excluded; cache stays 0 since Codex reports no cache-write count.
    static func codexEvents(since cutoff: Date) -> [Event] {
        let root = URL(fileURLWithPath: "\(Paths.home)/.codex/sessions")
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var events: [Event] = []
        for url in jsonlFiles(under: root, modifiedAfter: cutoff) {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in raw.split(separator: "\n") {
                guard line.contains("\"token_count\"") else { continue }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      obj["type"] as? String == "event_msg",
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let lu = info["last_token_usage"] as? [String: Any],
                      let tsStr = obj["timestamp"] as? String,
                      let ts = isoFractional.date(from: tsStr) ?? isoPlain.date(from: tsStr),
                      ts >= cutoff
                else { continue }
                let fresh = (lu["input_tokens"] as? Int ?? 0) - (lu["cached_input_tokens"] as? Int ?? 0)
                let output = (lu["output_tokens"] as? Int ?? 0) + (lu["reasoning_output_tokens"] as? Int ?? 0)
                events.append(Event(ts: ts, input: max(0, fresh), cache: 0, output: output))
            }
        }
        return events
    }

    /// Cache-write tokens from a usage dict; the newer format nests ephemeral
    /// fields under `cache_creation`, the older one has a flat
    /// `cache_creation_input_tokens`
    static func cacheWriteTokens(_ usage: [String: Any]) -> Int {
        if let breakdown = usage["cache_creation"] as? [String: Any] {
            let w5 = breakdown["ephemeral_5m_input_tokens"] as? Int ?? 0
            let w1h = breakdown["ephemeral_1h_input_tokens"] as? Int ?? 0
            if w5 > 0 || w1h > 0 { return w5 + w1h }
        }
        return usage["cache_creation_input_tokens"] as? Int ?? 0
    }

    static func jsonlFiles(under root: URL, modifiedAfter cutoff: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  mtime >= cutoff
            else { continue }
            urls.append(url)
        }
        return urls
    }

    // MARK: - Aggregation

    static func sumParts(_ events: [Event]) -> TokenParts {
        var parts = TokenParts()
        for e in events {
            parts.input += e.input
            parts.cache += e.cache
            parts.output += e.output
        }
        return parts
    }

    /// Start of the 12-week grid: the Monday 11 weeks back (local calendar)
    static func gridStart(weeks: Int = 12) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let mondayIndex = (cal.component(.weekday, from: today) + 5) % 7
        return cal.date(byAdding: .day, value: -(mondayIndex + 7 * (weeks - 1)), to: today) ?? today
    }

    static func aggregate(events: [Event]) -> ProviderActivity {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)

        var buckets: [String: TokenParts] = ["daily": .init(), "weekly": .init(), "monthly": .init()]
        let bounds: [(String, Date)] = [
            ("daily", now.addingTimeInterval(-86_400)),
            ("weekly", now.addingTimeInterval(-7 * 86_400)),
            ("monthly", now.addingTimeInterval(-30 * 86_400)),
        ]
        var dailyTotals: [Date: Int] = [:]
        var hourTotals: [Date: [Int]] = [:]
        let hourStart = cal.date(byAdding: .day, value: -6, to: today) ?? today

        for e in events {
            for (key, cut) in bounds where e.ts >= cut {
                buckets[key]?.input += e.input
                buckets[key]?.cache += e.cache
                buckets[key]?.output += e.output
            }
            let total = e.input + e.cache + e.output
            let day = cal.startOfDay(for: e.ts)
            dailyTotals[day, default: 0] += total
            if day >= hourStart {
                var hours = hourTotals[day] ?? Array(repeating: 0, count: 24)
                hours[cal.component(.hour, from: e.ts)] += total
                hourTotals[day] = hours
            }
        }

        let history = [
            HistoryBucket(id: "daily", label: "Daily · 24 h", parts: buckets["daily"] ?? .init()),
            HistoryBucket(id: "weekly", label: "Weekly · 7 days", parts: buckets["weekly"] ?? .init()),
            HistoryBucket(id: "monthly", label: "Monthly · 30 days", parts: buckets["monthly"] ?? .init()),
        ]

        // Daily grid: week columns, each Mon...Sun
        let peak = dailyTotals.values.max() ?? 0
        var grid: [[HeatmapCell?]] = []
        var day = gridStart()
        while day <= today {
            var column: [HeatmapCell?] = []
            for _ in 0..<7 {
                if day <= today {
                    let tokens = dailyTotals[day] ?? 0
                    column.append(HeatmapCell(tokens: tokens, level: level(tokens, peak: peak)))
                } else {
                    column.append(nil)
                }
                day = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            }
            grid.append(column)
        }

        // Hour punch card: last 7 days, oldest on top
        let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let hourPeak = hourTotals.values.flatMap(\.self).max() ?? 0
        var hourRows: [HeatmapHourRow] = []
        var rowDay = hourStart
        while rowDay <= today {
            let hours = hourTotals[rowDay] ?? Array(repeating: 0, count: 24)
            let name = weekdayNames[(cal.component(.weekday, from: rowDay) + 5) % 7]
            let cells = (0..<24).map { h in
                HeatmapCell(tokens: hours[h], level: level(hours[h], peak: hourPeak))
            }
            hourRows.append(HeatmapHourRow(dayLabel: name, cells: cells))
            rowDay = cal.date(byAdding: .day, value: 1, to: rowDay) ?? rowDay.addingTimeInterval(86_400)
        }

        return ProviderActivity(
            history: history,
            dailyGrid: grid,
            hourRows: hourRows,
            totalTokens: dailyTotals.values.reduce(0, +)
        )
    }

    /// Intensity 0-4: 0 empty, 1-4 relative to the peak
    static func level(_ tokens: Int, peak: Int) -> Int {
        guard peak > 0, tokens > 0 else { return 0 }
        return min(4, 1 + Int(Double(tokens) / Double(peak) * 3.999))
    }
}
