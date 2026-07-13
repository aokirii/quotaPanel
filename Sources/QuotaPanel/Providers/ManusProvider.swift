import Foundation

/// Manus (manus.im) credit balance. The session id is provided via env
/// (MANUS_SESSION_TOKEN / MANUS_SESSION_ID / MANUS_COOKIE) and sent as a bearer.
enum ManusProvider {
    private static let url = URL(string: "https://api.manus.im/user.v1.UserService/GetAvailableCredits")!

    static func fetch() async -> ProviderSnapshot {
        guard let token = resolveToken() else {
            return snapshot(.authProblem("No Manus session token — set MANUS_SESSION_TOKEN"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = "{}".data(using: .utf8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://manus.im", forHTTPHeaderField: "Origin")
        request.setValue("https://manus.im/", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(ProviderSupport.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return snapshot(.authProblem("Manus session token is invalid")) }
            guard code == 200 else { return snapshot(.error("Manus API error: HTTP \(code)")) }
            return parse(data)
        } catch {
            return snapshot(.error("Network error: \(error.localizedDescription)"))
        }
    }

    private static func resolveToken() -> String? {
        guard let raw = ProviderSupport.env(["MANUS_SESSION_TOKEN", "MANUS_SESSION_ID", "MANUS_COOKIE"]) else { return nil }
        // A bare token has no cookie punctuation; otherwise pull session_id out.
        if !raw.contains("=") && !raw.contains(";") { return raw }
        for pair in raw.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0].lowercased() == "session_id" { return kv[1] }
        }
        return nil
    }

    private static func parse(_ data: Data) -> ProviderSnapshot {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return snapshot(.error("Could not parse Manus response"))
        }
        for key in ["data", "result", "response", "availableCredits"] {
            if let inner = json[key] as? [String: Any] { json = inner; break }
        }
        var windows: [RateWindow] = []
        if let monthly = num(json["proMonthlyCredits"]), monthly > 0 {
            let used = monthly - (num(json["periodicCredits"]) ?? 0)
            windows.append(RateWindow(label: "Monthly credits",
                                      percent: ProviderSupport.clamp(used / monthly * 100), resetsAt: nil))
        }
        if let maxRefresh = num(json["maxRefreshCredits"]), maxRefresh > 0 {
            let used = maxRefresh - (num(json["refreshCredits"]) ?? 0)
            windows.append(RateWindow(label: "Daily refresh",
                                      percent: ProviderSupport.clamp(used / maxRefresh * 100),
                                      resetsAt: ProviderSupport.flexibleDate(json["nextRefreshTime"])))
        }
        return ProviderSnapshot(provider: .manus, status: .ok, windows: windows, planName: nil, updatedAt: Date())
    }

    private static func num(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
    }

    private static func snapshot(_ status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .manus, status: status, windows: [], planName: nil, updatedAt: Date())
    }
}
