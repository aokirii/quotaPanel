import Foundation

/// Zed editor subscription usage. Reads the accessToken from the Keychain
/// (stored by the Zed app), then calls the Zed cloud API.
enum ZedProvider {
    private static let usageURL = URL(string: "https://cloud.zed.dev/client/users/me")!

    static func fetch() async -> ProviderSnapshot {
        guard let cred = await Task.detached(priority: .utility, operation: {
            ProviderSupport.keychainCredential(host: "zed.dev", serviceURLs: ["https://zed.dev", "zed.dev"])
        }).value else {
            return snapshot(.authProblem("Not signed in to Zed — sign in from the Zed app with GitHub"))
        }
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 30
        // Zed uses "<userID> <accessToken>" (space-separated, no "Bearer").
        request.setValue("\(cred.account) \(cred.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return parse(data)
            case 401, 403: return snapshot(.authProblem("Zed credentials expired — sign in to Zed again"))
            default: return snapshot(.error("Zed cloud API error: HTTP \(code)"))
            }
        } catch {
            return snapshot(.error("Network error: \(error.localizedDescription)"))
        }
    }

    private static func parse(_ data: Data) -> ProviderSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = json["plan"] as? [String: Any] else {
            return snapshot(.error("Could not parse Zed response"))
        }
        let planName = (plan["plan_v3"] as? String).map(zedPlanName)
        var windows: [RateWindow] = []
        // Edit predictions used/limit (limit may be an Int or the string "unlimited").
        if let usage = plan["usage"] as? [String: Any],
           let ep = usage["edit_predictions"] as? [String: Any],
           let used = num(ep["used"]), let limit = num(ep["limit"]), limit > 0 {
            windows.append(RateWindow(label: "Edit predictions",
                                      percent: ProviderSupport.clamp(used / limit * 100),
                                      resetsAt: nil))
        }
        // Billing cycle shown as elapsed time-progress toward the period end.
        if let period = plan["subscription_period"] as? [String: Any],
           let start = ProviderSupport.flexibleDate(period["started_at"]),
           let end = ProviderSupport.flexibleDate(period["ended_at"]), end > start {
            let frac = Date().timeIntervalSince(start) / end.timeIntervalSince(start)
            windows.append(RateWindow(label: "Billing cycle",
                                      percent: ProviderSupport.clamp(frac * 100),
                                      resetsAt: end))
        }
        return ProviderSnapshot(provider: .zed, status: .ok, windows: windows, planName: planName, updatedAt: Date())
    }

    private static func zedPlanName(_ v: String) -> String {
        switch v {
        case "zed_free": "Zed Free"
        case "zed_pro": "Zed Pro"
        case "zed_pro_trial": "Zed Pro Trial"
        case "zed_student": "Zed Student"
        case "zed_business": "Zed Business"
        default: v.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func num(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
    }

    private static func snapshot(_ status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .zed, status: status, windows: [], planName: nil, updatedAt: Date())
    }
}
