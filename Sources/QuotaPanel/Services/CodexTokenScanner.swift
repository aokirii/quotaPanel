import Foundation

/// `~/.codex/sessions/YYYY/MM/DD/*.jsonl` oturum kayıtlarından günlük token
/// toplamı çıkarır. Her dosyanın SON `token_count` olayındaki
/// `total_token_usage.total_tokens` o oturumun toplamıdır; gün, dizin yolundan okunur.
actor CodexTokenScanner {
    private struct FileCacheEntry {
        let mtime: Date
        let size: Int
        let day: Date?
        let tokens: Int
    }

    private var fileCache: [String: FileCacheEntry] = [:]
    private let lookbackDays = 35

    func dailyStats() -> [DailyStat] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        let cutoff = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? .distantPast

        var byDay: [Date: Int] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return [] }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let day = Self.dayFromPath(url), day >= cutoff else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = values.contentModificationDate,
                  let size = values.fileSize
            else { continue }

            let key = url.path
            let entry: FileCacheEntry
            if let cached = fileCache[key], cached.mtime == mtime, cached.size == size {
                entry = cached
            } else {
                let tokens = Self.parseSessionTotal(url: url)
                entry = FileCacheEntry(mtime: mtime, size: size, day: day, tokens: tokens)
                fileCache[key] = entry
            }
            if entry.tokens > 0, let day = entry.day {
                byDay[day, default: 0] += entry.tokens
            }
        }

        return byDay
            .map { DailyStat(day: $0.key, costUSD: 0, tokens: $0.value) }
            .sorted { $0.day < $1.day }
    }

    /// .../sessions/2026/07/12/rollout-*.jsonl → 12 Tem 2026 (yerel gün başlangıcı)
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
