import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Gemini CLI usage/quota: read the personal OAuth tokens the `gemini` CLI
/// stores in `~/.gemini/oauth_creds.json`, refresh them against Google's OAuth
/// endpoint if expired, then read per-model quota from the private Cloud Code
/// API (the same one the CLI uses).
///
/// Ported from the macOS app verbatim except for: XDG-safe paths and the
/// portable `HTTP.data(for:)` networking wrapper.
enum GeminiProvider {
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let loadURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    /// gemini-cli's public OAuth client (ships in the CLI bundle). Loaded at
    /// runtime from ~/.config/quotapanel/oauth-clients.json — never committed.
    private static var clientID: String { OAuthClients.gemini.id }
    private static var clientSecret: String { OAuthClients.gemini.secret }

    static func fetch() async -> ProviderSnapshot {
        guard var creds = loadCreds() else {
            return snapshot(.authProblem("No Gemini credentials — run `gemini` and sign in once"))
        }
        if let type = selectedAuthType(), type == "api-key" || type == "vertex-ai" {
            return snapshot(.error("Gemini \(type) auth isn't supported — sign in with a personal Google account"))
        }

        // Refresh when there's no access token or it has expired (expiry_date is ms)
        if creds.accessToken == nil || (creds.expiryMs ?? 0) < Date().timeIntervalSince1970 * 1000 {
            guard let refreshed = await refresh(creds.refreshToken) else {
                return snapshot(.authProblem("Gemini token refresh failed — run `gemini` and sign in again"))
            }
            creds.accessToken = refreshed.accessToken
            creds.idToken = refreshed.idToken ?? creds.idToken
        }
        guard let token = creds.accessToken else {
            return snapshot(.authProblem("No Gemini access token"))
        }

        let resolved = await loadCodeAssist(token: token)
        return await fetchQuota(token: token, project: resolved.project, plan: planName(resolved, idToken: creds.idToken))
    }

    // MARK: - Local credentials

    private struct Creds {
        var accessToken: String?
        var refreshToken: String
        var idToken: String?
        var expiryMs: Double?
    }

    private static func loadCreds() -> Creds? {
        let url = URL(fileURLWithPath: "\(Paths.home)/.gemini/oauth_creds.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refresh = json["refresh_token"] as? String, !refresh.isEmpty
        else { return nil }
        return Creds(
            accessToken: json["access_token"] as? String,
            refreshToken: refresh,
            idToken: json["id_token"] as? String,
            expiryMs: json["expiry_date"] as? Double
        )
    }

    /// `security.auth.selectedType` from settings.json gates which auth modes we
    /// support (only personal OAuth; api-key/vertex-ai are out of scope).
    private static func selectedAuthType() -> String? {
        let url = URL(fileURLWithPath: "\(Paths.home)/.gemini/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let security = json["security"] as? [String: Any],
              let auth = security["auth"] as? [String: Any]
        else { return nil }
        return auth["selectedType"] as? String
    }

    // MARK: - Token refresh

    private struct Refreshed { let accessToken: String; let idToken: String? }

    private static func refresh(_ refreshToken: String) async -> Refreshed? {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id=\(clientID)",
            "client_secret=\(clientSecret)",
            "refresh_token=\(refreshToken)",
            "grant_type=refresh_token",
        ].joined(separator: "&")
        request.httpBody = form.data(using: .utf8)

        do {
            let (data, response) = try await HTTP.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String, !token.isEmpty
            else { return nil }
            return Refreshed(accessToken: token, idToken: json["id_token"] as? String)
        } catch {
            return nil
        }
    }

    // MARK: - Cloud Code API

    private struct Resolved {
        var project: String?
        var tierID: String?
        var paidTierName: String?
    }

    /// Resolves the GCP project id and subscription tier; tolerant of a missing
    /// project (the quota call accepts an empty project).
    private static func loadCodeAssist(token: String) async -> Resolved {
        var request = URLRequest(url: loadURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"],
        ])

        guard let (data, response) = try? await HTTP.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Resolved() }

        var resolved = Resolved()
        if let project = json["cloudaicompanionProject"] as? String {
            resolved.project = project
        } else if let obj = json["cloudaicompanionProject"] as? [String: Any] {
            resolved.project = (obj["id"] as? String) ?? (obj["projectId"] as? String)
        }
        if let tier = json["currentTier"] as? [String: Any] {
            resolved.tierID = tier["id"] as? String
        }
        if let paid = json["paidTier"] as? [String: Any] {
            resolved.paidTierName = paid["name"] as? String
        }
        return resolved
    }

    private static func fetchQuota(token: String, project: String?, plan: String?) async -> ProviderSnapshot {
        var request = URLRequest(url: quotaURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = project.map { ["project": $0] } ?? [:]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await HTTP.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                return parseQuota(data: data, plan: plan)
            case 401, 403:
                return snapshot(.authProblem("Gemini authorization failed (\(code)) — sign in again"))
            default:
                return snapshot(.error("Gemini API error: HTTP \(code)"), plan: plan)
            }
        } catch {
            return snapshot(.error("Network error: \(error.localizedDescription)"))
        }
    }

    /// Buckets are per model+tokenType with a remaining fraction (0…1). Group
    /// them into Pro / Flash / Flash-Lite families, keeping the worst (lowest
    /// remaining) bucket in each as its 24-hour window.
    static func parseQuota(data: Data, plan: String?) -> ProviderSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = json["buckets"] as? [[String: Any]]
        else { return snapshot(.error("Could not parse Gemini quota"), plan: plan) }

        struct Family { var label: String; var order: Int; var worst: Double; var reset: Date? }
        var families: [String: Family] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        for bucket in buckets {
            guard let model = bucket["modelId"] as? String else { continue }
            let fraction = (bucket["remainingFraction"] as? Double) ?? 1
            let reset = (bucket["resetTime"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            let (key, label, order): (String, String, Int)
            if model.contains("flash-lite") || model.contains("flash-8b") {
                (key, label, order) = ("lite", "Flash-Lite", 2)
            } else if model.contains("flash") {
                (key, label, order) = ("flash", "Flash", 1)
            } else {
                (key, label, order) = ("pro", "Pro", 0)
            }
            if var existing = families[key] {
                if fraction < existing.worst { existing.worst = fraction; existing.reset = reset }
                families[key] = existing
            } else {
                families[key] = Family(label: label, order: order, worst: fraction, reset: reset)
            }
        }

        let windows = families.values
            .sorted { $0.order < $1.order }
            .map { RateWindow(label: $0.label, percent: max(0, 100 - $0.worst * 100), resetsAt: $0.reset) }

        guard !windows.isEmpty else {
            return snapshot(.error("No quota data in Gemini response"), plan: plan)
        }
        return ProviderSnapshot(provider: .gemini, status: .ok, windows: windows, planName: plan, updatedAt: Date())
    }

    private static func planName(_ resolved: Resolved, idToken: String?) -> String? {
        if let paid = resolved.paidTierName, !paid.isEmpty { return paid }
        switch resolved.tierID {
        case "standard-tier": return "Paid"
        case "legacy-tier": return "Legacy"
        case "free-tier":
            return jwtClaim("hd", in: idToken) != nil ? "Workspace" : "Free"
        default:
            return nil
        }
    }

    private static func jwtClaim(_ name: String, in token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json[name] as? String
    }

    private static func snapshot(_ status: SnapshotStatus, plan: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(provider: .gemini, status: status, windows: [], planName: plan, updatedAt: Date())
    }
}
