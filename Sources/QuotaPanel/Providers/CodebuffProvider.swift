import Foundation

/// Codebuff (codebuff.com) credit usage. Token from CODEBUFF_API_KEY or
/// ~/.config/manicode/credentials.json.
enum CodebuffProvider {
    private static let base = "https://www.codebuff.com"

    static func fetch() async -> ProviderSnapshot {
        let (token, fromFile) = loadToken()
        guard let token else {
            return snapshot(.authProblem("Codebuff API token not configured — set CODEBUFF_API_KEY"))
        }
        var request = URLRequest(url: URL(string: "\(base)/api/v1/usage")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["fingerprintId": "codexbar-usage"])
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return snapshot(.authProblem("Codebuff session expired — sign in again")) }
            guard code == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return snapshot(.error("Codebuff API error: HTTP \(code)"))
            }
            var windows: [RateWindow] = []
            let used = num(json["usage"]) ?? num(json["used"]) ?? 0
            let total = num(json["quota"]) ?? num(json["limit"])
                ?? (used + (num(json["remainingBalance"]) ?? num(json["remaining"]) ?? 0))
            let reset = ProviderSupport.flexibleDate(json["next_quota_reset"])
            if total > 0 {
                windows.append(RateWindow(label: "Credits", percent: ProviderSupport.clamp(used / total * 100), resetsAt: reset))
            } else if used > 0 {
                windows.append(RateWindow(label: "Credits", percent: 100, resetsAt: reset))
            }
            var plan: String?
            if fromFile, let sub = await fetchSubscription(token: token) {
                plan = (sub["tier"] as? String)?.capitalized
                if let wl = num(sub["weeklyLimit"]), wl > 0 {
                    let wu = num(sub["weeklyUsed"]) ?? 0
                    windows.append(RateWindow(label: "Weekly",
                                              percent: ProviderSupport.clamp(wu / wl * 100),
                                              resetsAt: ProviderSupport.flexibleDate(sub["weeklyResetsAt"])))
                }
            }
            return ProviderSnapshot(provider: .codebuff, status: .ok, windows: windows, planName: plan, updatedAt: Date())
        } catch {
            return snapshot(.error("Network error: \(error.localizedDescription)"))
        }
    }

    private static func fetchSubscription(token: String) async -> [String: Any]? {
        var request = URLRequest(url: URL(string: "\(base)/api/user/subscription")!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let sub = json["subscription"] as? [String: Any] else { return json }
        var merged = json
        for (k, v) in sub { merged[k] = v }
        if let rl = json["rateLimit"] as? [String: Any] {
            merged["weeklyUsed"] = rl["weeklyUsed"] ?? rl["used"]
            merged["weeklyLimit"] = rl["weeklyLimit"] ?? rl["limit"]
            merged["weeklyResetsAt"] = rl["weeklyResetsAt"]
        }
        return merged
    }

    private static func loadToken() -> (String?, Bool) {
        if let t = ProviderSupport.env(["CODEBUFF_API_KEY"]) { return (t, false) }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/manicode/credentials.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, false) }
        let token = ((json["default"] as? [String: Any])?["authToken"] as? String) ?? (json["authToken"] as? String)
        return (token.map(ProviderSupport.clean), token != nil)
    }

    private static func num(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
    }

    private static func snapshot(_ status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .codebuff, status: status, windows: [], planName: nil, updatedAt: Date())
    }
}
