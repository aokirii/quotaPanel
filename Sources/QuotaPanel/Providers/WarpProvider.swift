import Foundation

/// Warp terminal AI request limits via its GraphQL API. Needs a Warp API key
/// in the environment (WARP_API_KEY or WARP_TOKEN).
enum WarpProvider {
    private static let url = URL(string: "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo")!
    private static let query = """
    query GetRequestLimitInfo($requestContext: RequestContext!) { \
    user(requestContext: $requestContext) { __typename ... on UserOutput { user { \
    requestLimitInfo { isUnlimited nextRefreshTime requestLimit requestsUsedSinceLastRefresh } } } } }
    """

    static func fetch() async -> ProviderSnapshot {
        guard let key = ProviderSupport.env(["WARP_API_KEY", "WARP_TOKEN"]) else {
            return snapshot(.authProblem("Missing Warp API key — set WARP_API_KEY"))
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let body: [String: Any] = [
            "query": query,
            "operationName": "GetRequestLimitInfo",
            "variables": ["requestContext": [
                "clientContext": [:],
                "osContext": ["category": "macOS", "name": "macOS", "version": osString],
            ]],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("warp-app", forHTTPHeaderField: "x-warp-client-id")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-category")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-name")
        request.setValue(osString, forHTTPHeaderField: "x-warp-os-version")
        request.setValue("Warp/1.0", forHTTPHeaderField: "User-Agent") // required, else 429
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return snapshot(.authProblem("Warp API key is invalid or expired")) }
            guard code == 200 else { return snapshot(.error("Warp API error: HTTP \(code)")) }
            return parse(data)
        } catch {
            return snapshot(.error("Network error: \(error.localizedDescription)"))
        }
    }

    private static func parse(_ data: Data) -> ProviderSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return snapshot(.error("Could not parse Warp response"))
        }
        // GraphQL surfaces errors in a top-level array even on HTTP 200.
        if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
            return snapshot(.error((first["message"] as? String) ?? "Warp API error"))
        }
        guard let dataObj = json["data"] as? [String: Any],
              let userOut = dataObj["user"] as? [String: Any],
              let inner = userOut["user"] as? [String: Any],
              let info = inner["requestLimitInfo"] as? [String: Any] else {
            return snapshot(.error("Warp returned no usage data"))
        }
        if booly(info["isUnlimited"]) {
            let w = RateWindow(label: "Credits", percent: 0, resetsAt: nil)
            return ProviderSnapshot(provider: .warp, status: .ok, windows: [w], planName: "Unlimited", updatedAt: Date())
        }
        let used = num(info["requestsUsedSinceLastRefresh"]) ?? 0
        let limit = num(info["requestLimit"]) ?? 0
        let percent = limit > 0 ? ProviderSupport.clamp(used / limit * 100) : 0
        let w = RateWindow(label: "Credits", percent: percent,
                           resetsAt: ProviderSupport.flexibleDate(info["nextRefreshTime"]))
        return ProviderSnapshot(provider: .warp, status: .ok, windows: [w], planName: nil, updatedAt: Date())
    }

    private static func booly(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return s == "true" || s == "1" }
        return false
    }

    private static func num(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
    }

    private static func snapshot(_ status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .warp, status: status, windows: [], planName: nil, updatedAt: Date())
    }
}
