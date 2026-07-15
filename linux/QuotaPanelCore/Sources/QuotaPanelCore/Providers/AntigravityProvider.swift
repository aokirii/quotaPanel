import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Antigravity usage/quota. Uses the same Google Cloud Code backend as Gemini,
/// but with Antigravity's own OAuth client. Credentials come from
/// `~/.config/quotapanel/antigravity/oauth_creds.json` or the
/// ANTIGRAVITY_OAUTH_CREDENTIALS_JSON environment variable (inline JSON).
enum AntigravityProvider {
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let loadURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!

    static func fetch() async -> ProviderSnapshot {
        // In-app sign-in (the shared ~/.quotapanel store written by the
        // QuotaPanel front-ends) takes priority over the local file.
        if let stored = CredentialStore.load("antigravity") {
            return await fetchWithStored(stored)
        }
        guard var creds = loadCreds() else {
            return snapshot(.authProblem("Antigravity Google auth not found — sign in from Settings or with Antigravity"))
        }
        let expired = creds.accessToken == nil || (creds.expiryMs ?? 0) < Date().timeIntervalSince1970 * 1000
        if expired {
            guard let clientID = creds.clientID, let clientSecret = creds.clientSecret,
                  let refreshed = await refresh(creds.refreshToken, clientID: clientID, clientSecret: clientSecret) else {
                if creds.accessToken == nil {
                    return snapshot(.authProblem("Antigravity token refresh failed — sign in with Antigravity again"))
                }
                // Fall back to the (possibly stale) access token we already have.
                return await withToken(creds)
            }
            creds.accessToken = refreshed.accessToken
        }
        return await withToken(creds)
    }

    private static func withToken(_ creds: Creds) async -> ProviderSnapshot {
        guard let token = creds.accessToken else {
            return snapshot(.authProblem("No Antigravity access token"))
        }
        let resolved = await loadCodeAssist(token: token, project: creds.projectID)
        return await fetchQuota(token: token, project: resolved.project ?? creds.projectID, plan: resolved.plan)
    }

    // MARK: - In-app credentials

    /// QuotaPanel's own sign-in: refresh through the Antigravity client from
    /// oauth-clients.json and persist renewed tokens back to the store.
    private static func fetchWithStored(_ credentials: StoredCredentials) async -> ProviderSnapshot {
        var stored = credentials
        if stored.isExpired {
            guard let renewed = await GoogleToken.refresh(stored, client: OAuthClients.antigravity) else {
                return snapshot(.authProblem("Antigravity token refresh failed — sign in again from Settings"))
            }
            stored = renewed
            CredentialStore.save(stored, for: "antigravity")
        }
        let resolved = await loadCodeAssist(token: stored.accessToken, project: nil)
        return await fetchQuota(token: stored.accessToken, project: resolved.project, plan: resolved.plan)
    }

    // MARK: - Local credentials

    private struct Creds {
        var accessToken: String?
        var refreshToken: String
        var expiryMs: Double?
        var projectID: String?
        var clientID: String?
        var clientSecret: String?
    }

    private static func loadCreds() -> Creds? {
        let json: [String: Any]?
        if let inline = ProviderSupport.env(["ANTIGRAVITY_OAUTH_CREDENTIALS_JSON"]),
           let data = inline.data(using: .utf8) {
            json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else {
            let url = URL(fileURLWithPath: "\(Paths.appConfigDir)/antigravity/oauth_creds.json")
            json = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        guard let json, let refresh = json["refresh_token"] as? String, !refresh.isEmpty else { return nil }
        return Creds(
            accessToken: json["access_token"] as? String,
            refreshToken: refresh,
            expiryMs: (json["expiry_date"] as? NSNumber)?.doubleValue,
            projectID: (json["project_id"] as? String) ?? (json["project"] as? String),
            clientID: json["client_id"] as? String,
            clientSecret: json["client_secret"] as? String
        )
    }

    // MARK: - Token refresh

    private struct Refreshed { let accessToken: String }

    private static func refresh(_ refreshToken: String, clientID: String, clientSecret: String) async -> Refreshed? {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            "client_id=\(clientID)",
            "client_secret=\(clientSecret)",
            "refresh_token=\(refreshToken)",
            "grant_type=refresh_token",
        ].joined(separator: "&").data(using: .utf8)
        guard let (data, response) = try? await HTTP.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty else { return nil }
        return Refreshed(accessToken: token)
    }

    // MARK: - Cloud Code API

    private struct Resolved { var project: String?; var plan: String? }

    private static func loadCodeAssist(token: String, project: String?) async -> Resolved {
        var request = URLRequest(url: loadURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"],
        ])
        guard let (data, response) = try? await HTTP.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Resolved(project: project, plan: nil)
        }
        var resolved = Resolved(project: project, plan: nil)
        if let p = json["cloudaicompanionProject"] as? String { resolved.project = p }
        else if let obj = json["cloudaicompanionProject"] as? [String: Any] {
            resolved.project = (obj["id"] as? String) ?? (obj["projectId"] as? String)
        }
        resolved.plan = planName(json)
        return resolved
    }

    private static func fetchQuota(token: String, project: String?, plan: String?) async -> ProviderSnapshot {
        var request = URLRequest(url: quotaURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: project.map { ["project": $0] } ?? [:])
        do {
            let (data, response) = try await HTTP.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return parseQuota(data: data, plan: plan)
            case 401, 403: return snapshot(.authProblem("Antigravity authorization failed (\(code)) — sign in again"))
            default: return snapshot(.error("Antigravity API error: HTTP \(code)"), plan: plan)
            }
        } catch {
            return snapshot(.error("Network error: \(error.localizedDescription)"))
        }
    }

    /// Buckets are per model with a remaining fraction (0…1). Group by model,
    /// keeping the worst (lowest remaining) bucket in each as its window.
    private static func parseQuota(data: Data, plan: String?) -> ProviderSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = json["buckets"] as? [[String: Any]] else {
            return snapshot(.error("Could not parse Antigravity quota"), plan: plan)
        }
        struct Family { var label: String; var worst: Double; var reset: Date? }
        var families: [String: Family] = [:]
        var order: [String] = []
        for bucket in buckets {
            guard let model = bucket["modelId"] as? String else { continue }
            let fraction = (bucket["remainingFraction"] as? NSNumber)?.doubleValue ?? 1
            let reset = ProviderSupport.flexibleDate(bucket["resetTime"])
            let (key, label) = family(for: model)
            if var existing = families[key] {
                if fraction < existing.worst { existing.worst = fraction; existing.reset = reset }
                families[key] = existing
            } else {
                families[key] = Family(label: label, worst: fraction, reset: reset)
                order.append(key)
            }
        }
        let windows = order.compactMap { families[$0] }
            .map { RateWindow(label: $0.label, percent: ProviderSupport.clamp(100 - $0.worst * 100), resetsAt: $0.reset) }
        guard !windows.isEmpty else { return snapshot(.error("No quota data in Antigravity response"), plan: plan) }
        return ProviderSnapshot(provider: .antigravity, status: .ok, windows: windows, planName: plan, updatedAt: Date())
    }

    private static func family(for model: String) -> (key: String, label: String) {
        let m = model.lowercased()
        if m.contains("gemini"), m.contains("flash-lite") || m.contains("flash-8b") { return ("gemini-lite", "Gemini Flash-Lite") }
        if m.contains("gemini"), m.contains("flash") { return ("gemini-flash", "Gemini Flash") }
        if m.contains("gemini") { return ("gemini-pro", "Gemini Pro") }
        if m.contains("claude") { return ("claude", "Claude") }
        if m.contains("gpt") || m.contains("openai") { return ("gpt", "GPT") }
        return (m, model)
    }

    private static func planName(_ json: [String: Any]) -> String? {
        if let info = json["planInfo"] as? [String: Any], let type = info["planType"] as? String {
            return mapTier(type)
        }
        if let tier = json["currentTier"] as? [String: Any], let id = tier["id"] as? String {
            return mapTier(id)
        }
        return nil
    }

    private static func mapTier(_ id: String) -> String {
        switch id {
        case "standard-tier": "Paid"
        case "free-tier": "Free"
        case "legacy-tier": "Legacy"
        default: id
        }
    }

    private static func snapshot(_ status: SnapshotStatus, plan: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(provider: .antigravity, status: status, windows: [], planName: plan, updatedAt: Date())
    }
}
