import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Devin (app.devin.ai) usage. Supply a bearer token via DEVIN_BEARER_TOKEN and
/// the organization via DEVIN_ORGANIZATION. (The browser auto-import path is not
/// available without a cookie-decryption library.)
enum DevinProvider {
    static func fetch() async -> ProviderSnapshot {
        guard let token = ProviderSupport.env(["DEVIN_BEARER_TOKEN", "DEVIN_AUTHORIZATION"]).map(stripBearer) else {
            return snapshot(.authProblem("No Devin token — set DEVIN_BEARER_TOKEN"))
        }
        guard let org = ProviderSupport.env(["DEVIN_ORGANIZATION", "DEVIN_ORG"]) else {
            return snapshot(.authProblem("No Devin organization — set DEVIN_ORGANIZATION"))
        }
        for path in ["\(org)", "org/\(org)", "organizations/\(org)"] {
            var request = URLRequest(url: URL(string: "https://app.devin.ai/api/\(path)/billing/quota/usage")!)
            request.timeoutInterval = 30
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(ProviderSupport.chromeUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(org, forHTTPHeaderField: "x-cog-org-id")
            guard let (data, response) = try? await HTTP.data(for: request) else { continue }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return parse(data) }
            if code == 401 || code == 403 { return snapshot(.authProblem("Devin token is invalid or expired")) }
        }
        return snapshot(.error("Devin usage not found for organization \(org)"))
    }

    private static func stripBearer(_ s: String) -> String {
        var t = s
        if t.lowercased().hasPrefix("authorization:") { t = String(t.dropFirst("authorization:".count)) }
        t = t.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("bearer ") { t = String(t.dropFirst("bearer ".count)) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func parse(_ data: Data) -> ProviderSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return snapshot(.error("Could not parse Devin response"))
        }
        let plan = (json["plan_name"] as? String) ?? (json["planName"] as? String) ?? (json["tier"] as? String)
        var windows: [RateWindow] = []
        if let d = pctValue(json["daily_percentage"]) {
            windows.append(RateWindow(label: "Daily", percent: d, resetsAt: ProviderSupport.flexibleDate(json["daily_reset_at"])))
        }
        if let w = pctValue(json["weekly_percentage"]) {
            windows.append(RateWindow(label: "Weekly", percent: w, resetsAt: ProviderSupport.flexibleDate(json["weekly_reset_at"])))
        }
        return ProviderSnapshot(provider: .devin, status: .ok, windows: windows, planName: plan?.capitalized, updatedAt: Date())
    }

    private static func pctValue(_ v: Any?) -> Double? {
        guard let n = (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) else { return nil }
        return ProviderSupport.clamp(n <= 1.0 ? n * 100 : n)
    }

    private static func snapshot(_ status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .devin, status: status, windows: [], planName: nil, updatedAt: Date())
    }
}
