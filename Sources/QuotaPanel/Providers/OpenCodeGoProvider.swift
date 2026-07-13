import Foundation

/// OpenCode Go usage computed locally. Confirms the login marker, then sums
/// assistant-message cost from the local OpenCode SQLite DB against fixed USD
/// limits. No network call.
enum OpenCodeGoProvider {
    private static let sessionLimit = 12.0
    private static let weeklyLimit = 30.0
    private static let monthlyLimit = 60.0

    static func fetch() async -> ProviderSnapshot {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode")
        let auth = dir.appendingPathComponent("auth.json")
        guard let adata = try? Data(contentsOf: auth),
              let json = try? JSONSerialization.jsonObject(with: adata) as? [String: Any],
              let go = json["opencode-go"] as? [String: Any],
              let key = go["key"] as? String, !key.isEmpty else {
            return snapshot(.authProblem("OpenCode Go not detected — log in with OpenCode Go first"))
        }
        let db = dir.appendingPathComponent("opencode.db")
        guard FileManager.default.fileExists(atPath: db.path) else {
            return snapshot(.ok) // authenticated, but no usage recorded yet
        }
        let now = Date()
        let sessionStart = now.addingTimeInterval(-5 * 3600)
        let weekStart = weekStartUTC(now)
        let monthStart = monthStartUTC(now)
        let costs = await Task.detached(priority: .utility) { () -> (Double, Double, Double) in
            (cost(db: db, since: sessionStart),
             cost(db: db, since: weekStart),
             cost(db: db, since: monthStart))
        }.value
        let windows = [
            RateWindow(label: "Session (5h)", percent: ProviderSupport.clamp(costs.0 / sessionLimit * 100),
                       resetsAt: sessionStart.addingTimeInterval(5 * 3600)),
            RateWindow(label: "Weekly", percent: ProviderSupport.clamp(costs.1 / weeklyLimit * 100), resetsAt: nil),
            RateWindow(label: "Monthly", percent: ProviderSupport.clamp(costs.2 / monthlyLimit * 100), resetsAt: nil),
        ]
        return ProviderSnapshot(provider: .opencodego, status: .ok, windows: windows, planName: nil, updatedAt: Date())
    }

    private static func cost(db: URL, since: Date) -> Double {
        let sinceMs = Int(since.timeIntervalSince1970 * 1000)
        let sql = """
        SELECT COALESCE(SUM(CAST(json_extract(data,'$.cost') AS REAL)),0) FROM message \
        WHERE json_extract(data,'$.providerID')='opencode-go' \
        AND json_extract(data,'$.role')='assistant' \
        AND CAST(json_extract(data,'$.time.created') AS INTEGER) >= \(sinceMs);
        """
        return ProviderSupport.sqliteValue(db: db, sql: sql).flatMap(Double.init) ?? 0
    }

    private static func weekStartUTC(_ date: Date) -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    private static func monthStartUTC(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.dateInterval(of: .month, for: date)?.start ?? date
    }

    private static func snapshot(_ status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .opencodego, status: status, windows: [], planName: nil, updatedAt: Date())
    }
}
