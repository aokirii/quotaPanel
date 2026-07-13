import Foundation

/// Windsurf (Codeium) plan/quota. Reads the editor's locally cached plan info
/// from its SQLite state DB — no network call or auth needed.
enum WindsurfProvider {
    static func fetch() async -> ProviderSnapshot {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Windsurf/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: db.path) else {
            return snapshot(.authProblem("Windsurf not found — launch Windsurf and sign in first"))
        }
        let sql = "SELECT value FROM ItemTable WHERE key='windsurf.settings.cachedPlanInfo' LIMIT 1;"
        guard let raw = await Task.detached(priority: .utility, operation: {
            ProviderSupport.sqliteValue(db: db, sql: sql)
        }).value else {
            return snapshot(.authProblem("No plan data in Windsurf — sign in to Windsurf first"))
        }
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return snapshot(.error("Could not parse Windsurf plan data"))
        }
        return parse(json)
    }

    private static func parse(_ json: [String: Any]) -> ProviderSnapshot {
        let plan = json["planName"] as? String
        var windows: [RateWindow] = []
        if let q = json["quotaUsage"] as? [String: Any] {
            if let dr = num(q["dailyRemainingPercent"]) {
                windows.append(RateWindow(label: "Daily",
                                          percent: ProviderSupport.clamp(100 - dr),
                                          resetsAt: ProviderSupport.flexibleDate(q["dailyResetAtUnix"])))
            }
            if let wr = num(q["weeklyRemainingPercent"]) {
                windows.append(RateWindow(label: "Weekly",
                                          percent: ProviderSupport.clamp(100 - wr),
                                          resetsAt: ProviderSupport.flexibleDate(q["weeklyResetAtUnix"])))
            }
        }
        return ProviderSnapshot(provider: .windsurf, status: .ok, windows: windows, planName: plan, updatedAt: Date())
    }

    private static func num(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
    }

    private static func snapshot(_ status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .windsurf, status: status, windows: [], planName: nil, updatedAt: Date())
    }
}
