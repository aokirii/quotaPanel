import Foundation

/// Qoder (qoder.com) big-model credit usage. Auth is a browser session cookie;
/// supply it via the QODER_COOKIE environment variable (a pasted Cookie header).
enum QoderProvider {
    static func fetch() async -> ProviderSnapshot {
        guard let cookie = ProviderSupport.env(["QODER_COOKIE"]) else {
            return snapshot(.authProblem("Qoder session cookie not found — set QODER_COOKIE"))
        }
        let host = cookie.contains("qoder.com.cn") ? "https://qoder.com.cn" : "https://qoder.com"
        var request = URLRequest(url: URL(string: "\(host)/api/v2/me/usages/big_model_credits")!)
        request.timeoutInterval = 30
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(ProviderSupport.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(host, forHTTPHeaderField: "Origin")
        request.setValue("\(host)/account/usage", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("2.5.35", forHTTPHeaderField: "Bx-V")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return snapshot(.authProblem("Qoder session is invalid or expired")) }
            guard code == 200 else { return snapshot(.error("Qoder API error: HTTP \(code)")) }
            return parse(data)
        } catch {
            return snapshot(.error("Network error: \(error.localizedDescription)"))
        }
    }

    private static func parse(_ data: Data) -> ProviderSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return snapshot(.error("Could not parse Qoder response"))
        }
        var used = 0.0, limit = 0.0
        var directPercent: Double?
        var reset: Date?
        for key in ["totalQuota", "total_quota", "sharedQuota", "shared_quota"] {
            guard let s = quotaSummary(json, key) else { continue }
            used += num(s["used_value"] ?? s["usedValue"]) ?? 0
            limit += num(s["limit_value"] ?? s["limitValue"]) ?? 0
            if directPercent == nil { directPercent = num(s["usage_percentage"] ?? s["usagePercentage"]) }
            if reset == nil { reset = ProviderSupport.flexibleDate(s["next_reset_at"] ?? s["nextResetAt"]) }
        }
        let percent: Double
        if limit > 0 { percent = ProviderSupport.clamp(used / limit * 100) }
        else if let dp = directPercent { percent = ProviderSupport.clamp(dp) }
        else { percent = 100 }
        let w = RateWindow(label: "Credits", percent: percent, resetsAt: reset)
        return ProviderSnapshot(provider: .qoder, status: .ok, windows: [w], planName: nil, updatedAt: Date())
    }

    private static func quotaSummary(_ json: [String: Any], _ key: String) -> [String: Any]? {
        guard let quota = json[key] as? [String: Any] else { return nil }
        return (quota["quotaSummary"] as? [String: Any]) ?? (quota["quota_summary"] as? [String: Any])
    }

    private static func num(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
    }

    private static func snapshot(_ status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .qoder, status: status, windows: [], planName: nil, updatedAt: Date())
    }
}
