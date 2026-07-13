import Foundation

/// Amp (ampcode.com) free-tier usage. Uses an API key from the environment
/// (AMP_API_KEY); falls back to the `amp` CLI if present.
enum AmpProvider {
    private static let url = URL(string: "https://ampcode.com/api/internal?userDisplayBalanceInfo")!

    static func fetch() async -> ProviderSnapshot {
        if let key = ProviderSupport.env(["AMP_API_KEY"]) {
            return await fetchAPI(key: key)
        }
        if let cli = ProviderSupport.which("amp"),
           let out = await Task.detached(priority: .utility, operation: {
               ProviderSupport.run(cli, ["usage"], extraEnv: ["NO_COLOR": "1"], timeout: 15)
           }).value {
            return parseText(ProviderSupport.stripANSI(out))
        }
        return snapshot(.authProblem("Amp access token not configured — set AMP_API_KEY"))
    }

    private static func fetchAPI(key: String) async -> ProviderSnapshot {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["method": "userDisplayBalanceInfo", "params": [:]])
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return snapshot(.authProblem("Amp access token is invalid or expired")) }
            guard code == 200 else { return snapshot(.error("Amp API error: HTTP \(code)")) }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return snapshot(.error("Could not parse Amp response"))
            }
            if let err = json["error"] as? [String: Any], (err["code"] as? String) == "auth-required" {
                return snapshot(.authProblem("Amp access token is invalid or expired"))
            }
            let text = ((json["result"] as? [String: Any])?["displayText"] as? String) ?? ""
            return parseText(ProviderSupport.stripANSI(text))
        } catch {
            return snapshot(.error("Network error: \(error.localizedDescription)"))
        }
    }

    private static func parseText(_ text: String) -> ProviderSnapshot {
        // Dollar form: "Amp Free: $3.20 / $10.00 remaining"
        if let remStr = ProviderSupport.firstMatch(#"Amp Free:\s*\$([0-9.]+)"#, text),
           let quotaStr = ProviderSupport.firstMatch(#"Amp Free:\s*\$[0-9.]+\s*/\s*\$([0-9.]+)"#, text),
           let remaining = Double(remStr), let quota = Double(quotaStr), quota > 0 {
            let used = ProviderSupport.clamp((quota - remaining) / quota * 100)
            let w = RateWindow(label: "Amp Free", percent: used, resetsAt: nil)
            return ProviderSnapshot(provider: .amp, status: .ok, windows: [w], planName: nil, updatedAt: Date())
        }
        // Percent form: "Amp Free: 40% remaining today"
        if let pctStr = ProviderSupport.firstMatch(#"Amp Free:\s*([0-9.]+)%\s*remaining"#, text),
           let pct = Double(pctStr) {
            let w = RateWindow(label: "Amp Free", percent: ProviderSupport.clamp(100 - pct), resetsAt: nil)
            return ProviderSnapshot(provider: .amp, status: .ok, windows: [w], planName: nil, updatedAt: Date())
        }
        // Signed in but nothing quantifiable to show.
        return snapshot(.ok)
    }

    private static func snapshot(_ status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .amp, status: status, windows: [], planName: nil, updatedAt: Date())
    }
}
