import Foundation

/// CrossModel (crossmodel.ai) wallet balance. It has no quota cap, so we show
/// the remaining balance as the plan label rather than a usage bar.
enum CrossModelProvider {
    static func fetch() async -> ProviderSnapshot {
        guard let key = ProviderSupport.env(["CROSSMODEL_API_KEY"]) else {
            return snapshot(.authProblem("CrossModel API token not configured — set CROSSMODEL_API_KEY"))
        }
        let base = ProviderSupport.env(["CROSSMODEL_API_URL"]) ?? "https://api.crossmodel.ai/v1"
        var request = URLRequest(url: URL(string: "\(base)/credits")!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return snapshot(.authProblem("Invalid CrossModel API credentials")) }
            guard code == 200 else { return snapshot(.error("CrossModel API error: HTTP \(code)")) }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return snapshot(.error("Could not parse CrossModel response"))
            }
            let currency = (json["currency"] as? String)?.uppercased() ?? "USD"
            let balance = (num(json["balance_micro"]) ?? 0) / 1_000_000
            let plan = String(format: "%@ %.2f balance", currency, balance)
            return ProviderSnapshot(provider: .crossmodel, status: .ok, windows: [], planName: plan, updatedAt: Date())
        } catch {
            return snapshot(.error("Network error: \(error.localizedDescription)"))
        }
    }

    private static func num(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
    }

    private static func snapshot(_ status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .crossmodel, status: status, windows: [], planName: nil, updatedAt: Date())
    }
}
