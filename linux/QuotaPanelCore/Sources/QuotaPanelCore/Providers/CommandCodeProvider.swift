import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Command Code (commandcode.ai) monthly credit usage. Auth is a better-auth
/// session cookie; supply it via COMMANDCODE_COOKIE (a pasted Cookie header).
enum CommandCodeProvider {
    private static let catalog: [String: (name: String, monthlyUSD: Double)] = [
        "individual-go": ("Go", 10),
        "individual-pro": ("Pro", 30),
        "individual-max": ("Max", 150),
        "individual-ultra": ("Ultra", 300),
    ]

    private struct AuthError: Error { let message: String }

    static func fetch() async -> ProviderSnapshot {
        guard let cookie = ProviderSupport.env(["COMMANDCODE_COOKIE"]) else {
            return snapshot(.authProblem("Command Code session cookie not found — set COMMANDCODE_COOKIE"))
        }
        do {
            guard let credits = try await get("https://api.commandcode.ai/internal/billing/credits", cookie: cookie) else {
                return snapshot(.authProblem("Command Code session is invalid or expired"))
            }
            let sub = try? await get("https://api.commandcode.ai/internal/billing/subscriptions", cookie: cookie)
            return parse(credits: credits, sub: sub ?? nil)
        } catch let e as AuthError {
            return snapshot(.authProblem(e.message))
        } catch {
            return snapshot(.error("Network error: \(error.localizedDescription)"))
        }
    }

    private static func get(_ urlStr: String, cookie: String) async throws -> [String: Any]? {
        var request = URLRequest(url: URL(string: urlStr)!)
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://commandcode.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://commandcode.ai/", forHTTPHeaderField: "Referer")
        request.setValue(ProviderSupport.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTP.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw AuthError(message: "Command Code session is invalid or expired") }
        guard code == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func parse(credits: [String: Any], sub: [String: Any]?) -> ProviderSnapshot {
        var plan: String?
        var total = 0.0
        var reset: Date?
        if let subData = sub?["data"] as? [String: Any] {
            if let planId = subData["planId"] as? String, let entry = catalog[planId] {
                plan = entry.name
                total = entry.monthlyUSD
            }
            reset = ProviderSupport.flexibleDate(subData["currentPeriodEnd"])
        }
        // `monthlyCredits` is the remaining USD balance for the period.
        let remaining = num((credits["credits"] as? [String: Any])?["monthlyCredits"])
            ?? num(credits["monthlyCredits"]) ?? 0
        var windows: [RateWindow] = []
        if total > 0 {
            let used = max(0, min(total, total - remaining))
            windows.append(RateWindow(label: "Monthly credits",
                                      percent: ProviderSupport.clamp(used / total * 100), resetsAt: reset))
        }
        return ProviderSnapshot(provider: .commandcode, status: .ok, windows: windows, planName: plan, updatedAt: Date())
    }

    private static func num(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
    }

    private static func snapshot(_ status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .commandcode, status: status, windows: [], planName: nil, updatedAt: Date())
    }
}
