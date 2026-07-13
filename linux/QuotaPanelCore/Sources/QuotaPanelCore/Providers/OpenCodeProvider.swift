import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenCode (opencode.ai) subscription usage via its server RPC. Auth is a
/// browser session cookie; supply it via OPENCODE_COOKIE (a pasted header that
/// contains the `auth` cookie).
enum OpenCodeProvider {
    private static let workspaceRPC = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let usageRPC = "7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4"

    private struct AuthError: Error { let message: String }

    static func fetch() async -> ProviderSnapshot {
        guard let cookie = ProviderSupport.env(["OPENCODE_COOKIE"]) else {
            return snapshot(.authProblem("No OpenCode session cookie — set OPENCODE_COOKIE"))
        }
        do {
            guard let workspace = try await workspaceID(cookie: cookie) else {
                return snapshot(.authProblem("OpenCode session cookie is invalid or expired"))
            }
            guard let usage = try await usage(workspace: workspace, cookie: cookie) else {
                return snapshot(.error("OpenCode returned no usage data"))
            }
            return parse(usage)
        } catch let e as AuthError {
            return snapshot(.authProblem(e.message))
        } catch {
            return snapshot(.error("Network error: \(error.localizedDescription)"))
        }
    }

    private static func workspaceID(cookie: String) async throws -> String? {
        let url = URL(string: "https://opencode.ai/_server?id=\(workspaceRPC)")!
        let json = try await rpc(url, cookie: cookie, referer: "https://opencode.ai")
        return findWorkspace(json)
    }

    private static func usage(workspace: String, cookie: String) async throws -> [String: Any]? {
        let args = "[\"\(workspace)\"]".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let url = URL(string: "https://opencode.ai/_server?id=\(usageRPC)&args=\(args)")!
        let json = try await rpc(url, cookie: cookie, referer: "https://opencode.ai/workspace/\(workspace)/billing")
        return json as? [String: Any]
    }

    private static func rpc(_ url: URL, cookie: String, referer: String) async throws -> Any {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(workspaceRPC, forHTTPHeaderField: "X-Server-Id")
        request.setValue("server-fn:\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        request.setValue(ProviderSupport.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://opencode.ai", forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await HTTP.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw AuthError(message: "OpenCode session cookie is invalid or expired") }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Recursively find the first "wrk_"-prefixed identifier in the RPC payload.
    private static func findWorkspace(_ obj: Any) -> String? {
        if let s = obj as? String { return s.hasPrefix("wrk_") ? s : nil }
        if let arr = obj as? [Any] {
            for e in arr { if let w = findWorkspace(e) { return w } }
        }
        if let dict = obj as? [String: Any] {
            for (_, v) in dict { if let w = findWorkspace(v) { return w } }
        }
        return nil
    }

    private static func parse(_ json: [String: Any]) -> ProviderSnapshot {
        var windows: [RateWindow] = []
        if let w = windowFrom(json["rollingUsage"], label: "5-hour") { windows.append(w) }
        if let w = windowFrom(json["weeklyUsage"], label: "Weekly") { windows.append(w) }
        return ProviderSnapshot(provider: .opencode, status: .ok, windows: windows, planName: nil, updatedAt: Date())
    }

    private static func windowFrom(_ obj: Any?, label: String) -> RateWindow? {
        guard let u = obj as? [String: Any] else { return nil }
        var pct = num(u["usagePercent"]) ?? num(u["usedPercent"]) ?? num(u["percentUsed"])
        if pct == nil, let used = num(u["used"]), let limit = num(u["limit"]), limit > 0 {
            pct = used / limit * 100
        }
        guard var p = pct else { return nil }
        if p <= 1.0 { p *= 100 }
        var reset: Date?
        if let secs = num(u["resetInSec"]) { reset = Date().addingTimeInterval(secs) }
        else { reset = ProviderSupport.flexibleDate(u["resetAt"]) }
        return RateWindow(label: label, percent: ProviderSupport.clamp(p), resetsAt: reset)
    }

    private static func num(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
    }

    private static func snapshot(_ status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .opencode, status: status, windows: [], planName: nil, updatedAt: Date())
    }
}
