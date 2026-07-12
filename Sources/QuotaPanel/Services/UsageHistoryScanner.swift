import Foundation

/// Yerel oturum kayıtlarından offline özet (24s/7g/30g), ısı haritası ve pencere
/// bileşimi üretir. Ağır 12 haftalık tarama yalnızca istendiğinde yapılır ve
/// 5 dakika önbelleklenir; cutoff'tan eski dosyalar mtime ile atlanır.
actor UsageHistoryScanner {
    struct Event: Sendable {
        let ts: Date
        let input: Int
        let cache: Int
        let output: Int
    }

    private var cache: [String: (at: Date, activity: ProviderActivity)] = [:]
    private let cacheSeconds: TimeInterval = 300

    // MARK: - Genel API

    func claudeActivity(force: Bool = false) -> ProviderActivity {
        activity(key: "claude", force: force) { cutoff in Self.claudeEvents(since: cutoff) }
    }

    func codexActivity(force: Bool = false) -> ProviderActivity {
        activity(key: "codex", force: force) { cutoff in Self.codexEvents(since: cutoff) }
    }

    /// Son `hours` saatteki bileşim — oturum penceresi çubuğunu bölmek için
    func claudeWindowParts(hours: Double) -> TokenParts {
        Self.sumParts(Self.claudeEvents(since: Date(timeIntervalSinceNow: -hours * 3600)))
    }

    func codexWindowParts(hours: Double) -> TokenParts {
        Self.sumParts(Self.codexEvents(since: Date(timeIntervalSinceNow: -hours * 3600)))
    }

    private func activity(key: String, force: Bool, events: (Date) -> [Event]) -> ProviderActivity {
        if !force, let hit = cache[key], Date().timeIntervalSince(hit.at) < cacheSeconds {
            return hit.activity
        }
        let result = Self.aggregate(events: events(Self.gridStart()))
        cache[key] = (Date(), result)
        return result
    }

    // MARK: - Olay kaynakları

    /// Claude: her usage kaydı için (ts, girdi, önbellek-yazma, çıktı).
    /// Önbellek okumaları hariç.
    nonisolated static func claudeEvents(since cutoff: Date) -> [Event] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
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

    /// Codex: her turun artımlı `last_token_usage` değeri. Önbellekli prompt
    /// token'ları hariç; Codex önbellek-yazma sayısı vermediği için cache 0 kalır.
    nonisolated static func codexEvents(since cutoff: Date) -> [Event] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
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

    /// usage sözlüğünden önbellek-yazma token'ları; yeni biçimde `cache_creation`
    /// altındaki ephemeral alanlar, eskisinde düz `cache_creation_input_tokens`
    nonisolated static func cacheWriteTokens(_ usage: [String: Any]) -> Int {
        if let breakdown = usage["cache_creation"] as? [String: Any] {
            let w5 = breakdown["ephemeral_5m_input_tokens"] as? Int ?? 0
            let w1h = breakdown["ephemeral_1h_input_tokens"] as? Int ?? 0
            if w5 > 0 || w1h > 0 { return w5 + w1h }
        }
        return usage["cache_creation_input_tokens"] as? Int ?? 0
    }

    nonisolated private static func jsonlFiles(under root: URL, modifiedAfter cutoff: Date) -> [URL] {
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

    // MARK: - Toplama

    nonisolated static func sumParts(_ events: [Event]) -> TokenParts {
        var parts = TokenParts()
        for e in events {
            parts.input += e.input
            parts.cache += e.cache
            parts.output += e.output
        }
        return parts
    }

    /// 12 haftalık grid'in başlangıcı: 11 hafta önceki pazartesi (yerel takvim)
    nonisolated static func gridStart(weeks: Int = 12) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let mondayIndex = (cal.component(.weekday, from: today) + 5) % 7
        return cal.date(byAdding: .day, value: -(mondayIndex + 7 * (weeks - 1)), to: today) ?? today
    }

    nonisolated static func aggregate(events: [Event]) -> ProviderActivity {
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

        // Günlük grid: hafta sütunları, her sütun Pzt...Paz
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "d MMM"
        let peak = dailyTotals.values.max() ?? 0
        var grid: [[HeatmapCell?]] = []
        var day = gridStart()
        while day <= today {
            var column: [HeatmapCell?] = []
            for _ in 0..<7 {
                if day <= today {
                    let tokens = dailyTotals[day] ?? 0
                    column.append(HeatmapCell(
                        label: "\(dayFmt.string(from: day)): \(formatTokenCount(tokens))",
                        tokens: tokens,
                        level: level(tokens, peak: peak)
                    ))
                } else {
                    column.append(nil)
                }
                day = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            }
            grid.append(column)
        }

        // Saat punch-card'ı: son 7 gün, en eski üstte
        let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let hourPeak = hourTotals.values.flatMap(\.self).max() ?? 0
        var hourRows: [HeatmapHourRow] = []
        var rowDay = hourStart
        while rowDay <= today {
            let hours = hourTotals[rowDay] ?? Array(repeating: 0, count: 24)
            let name = weekdayNames[(cal.component(.weekday, from: rowDay) + 5) % 7]
            let cells = (0..<24).map { h in
                HeatmapCell(
                    label: "\(dayFmt.string(from: rowDay)) \(h):00 — \(formatTokenCount(hours[h]))",
                    tokens: hours[h],
                    level: level(hours[h], peak: hourPeak)
                )
            }
            hourRows.append(HeatmapHourRow(id: "\(rowDay.timeIntervalSince1970)", dayLabel: name, cells: cells))
            rowDay = cal.date(byAdding: .day, value: 1, to: rowDay) ?? rowDay.addingTimeInterval(86_400)
        }

        return ProviderActivity(
            history: history,
            dailyGrid: grid,
            hourRows: hourRows,
            totalTokens: dailyTotals.values.reduce(0, +)
        )
    }

    /// 0-4 arası yoğunluk: 0 boş, 1-4 zirveye oranla
    nonisolated static func level(_ tokens: Int, peak: Int) -> Int {
        guard peak > 0, tokens > 0 else { return 0 }
        return min(4, 1 + Int(Double(tokens) / Double(peak) * 3.999))
    }
}
