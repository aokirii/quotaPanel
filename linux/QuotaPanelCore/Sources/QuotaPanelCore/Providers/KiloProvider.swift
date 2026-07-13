import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Kilo (app.kilo.ai) credit usage via its tRPC batch API. Token from
/// KILO_API_KEY or `~/.local/share/kilo/auth.json`.
enum KiloProvider {
    static func fetch() async -> ProviderSnapshot {
        guard let token = loadToken() else {
            return snapshot(.authProblem("Kilo credentials missing — set KILO_API_KEY"))
        }
        let input = #"{"0":{"json":null},"1":{"json":null},"2":{"json":null}}"#
        let encoded = input.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? input
        let urlStr = "https://app.kilo.ai/api/trpc/user.getCreditBlocks,kiloPass.getState,user.getAutoTopUpPaymentMethod?batch=1&input=\(encoded)"
        guard let url = URL(string: urlStr) else { return snapshot(.error("Kilo request URL invalid")) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await HTTP.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return snapshot(.authProblem("Kilo authentication failed — refresh KILO_API_KEY")) }
            guard code == 200 else { return snapshot(.error("Kilo API error: HTTP \(code)")) }
            return parse(data)
        } catch {
            return snapshot(.error("Network error: \(error.localizedDescription)"))
        }
    }

    private static func loadToken() -> String? {
        if let t = ProviderSupport.env(["KILO_API_KEY"]) { return t }
        let path = URL(fileURLWithPath: "\(Paths.dataHome)/kilo/auth.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kilo = json["kilo"] as? [String: Any],
              let access = kilo["access"] as? String, !access.isEmpty else { return nil }
        return access
    }

    private static func parse(_ data: Data) -> ProviderSnapshot {
        let procs = decodeBatch(data)
        var windows: [RateWindow] = []
        var plan: String?
        if let p0 = procs[0], let blocks = p0["creditBlocks"] as? [[String: Any]] {
            var total = 0.0, remaining = 0.0
            for b in blocks {
                total += (num(b["amount_mUsd"]) ?? 0) / 1_000_000
                remaining += (num(b["balance_mUsd"]) ?? 0) / 1_000_000
            }
            let used = total - remaining
            let pct = total > 0 ? ProviderSupport.clamp(used / total * 100) : 100
            windows.append(RateWindow(label: "Credits", percent: pct, resetsAt: nil))
        }
        if let p1 = procs[1], let sub = p1["subscription"] as? [String: Any] {
            plan = (sub["tier"] as? String).map(tierName)
        }
        return ProviderSnapshot(provider: .kilo, status: .ok, windows: windows, planName: plan, updatedAt: Date())
    }

    /// tRPC batch response: array (or index-keyed object) of
    /// { result: { data: { json: ... } } } entries.
    private static func decodeBatch(_ data: Data) -> [Int: [String: Any]] {
        func extract(_ entry: Any) -> [String: Any]? {
            (((entry as? [String: Any])?["result"] as? [String: Any])?["data"] as? [String: Any])?["json"] as? [String: Any]
        }
        var result: [Int: [String: Any]] = [:]
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            for (i, entry) in arr.enumerated() { if let j = extract(entry) { result[i] = j } }
        } else if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in dict { if let i = Int(k), let j = extract(v) { result[i] = j } }
        }
        return result
    }

    private static func tierName(_ t: String) -> String {
        switch t {
        case "tier_19": "Starter"
        case "tier_49": "Pro"
        case "tier_199": "Expert"
        default: t
        }
    }

    private static func num(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
    }

    private static func snapshot(_ status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .kilo, status: status, windows: [], planName: nil, updatedAt: Date())
    }
}
