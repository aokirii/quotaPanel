import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Codex (OpenAI) usage data: read from the `chatgpt.com/backend-api/wham/usage`
/// endpoint using the token in `~/.codex/auth.json`.
///
/// Linux port: the macOS app also supports an in-app OAuth sign-in stored in its
/// own CredentialStore; on Linux that flow is deferred, so credentials come only
/// from the codex CLI's `auth.json`. Refreshed tokens are kept in memory (the
/// CLI owns auth.json and concurrent writes could corrupt it).
enum CodexProvider {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    /// The Codex CLI's public OAuth client ID (the app that produces auth.json).
    /// Loaded at runtime from ~/.config/quotapanel/oauth-clients.json — never committed.
    private static var clientID: String { OAuthClients.codex.id }

    struct Credentials {
        let accessToken: String
        let accountId: String?
        let expiresAt: Date?
        let refreshToken: String?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 60
        }
    }

    /// Refreshed tokens are kept in memory only; auth.json is never written.
    private actor RefreshedTokens {
        private var accessToken: String?
        private var expiresAt: Date?

        func valid() -> (token: String, expiresAt: Date?)? {
            guard let accessToken else { return nil }
            if let expiresAt, expiresAt.timeIntervalSinceNow < 60 { return nil }
            return (accessToken, expiresAt)
        }
        func store(token: String, expiresAt: Date?) {
            accessToken = token
            self.expiresAt = expiresAt
        }
        func clear() {
            accessToken = nil
            expiresAt = nil
        }
    }
    private static let refreshed = RefreshedTokens()

    static func loadCredentials() -> Credentials? {
        let url = URL(fileURLWithPath: "\(Paths.home)/.codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty
        else { return nil }

        return Credentials(
            accessToken: token,
            accountId: tokens["account_id"] as? String,
            expiresAt: jwtExpiry(token),
            refreshToken: tokens["refresh_token"] as? String
        )
    }

    static func fetch() async -> ProviderSnapshot {
        // In-app sign-in (the shared ~/.quotapanel store written by the
        // QuotaPanel front-ends) takes priority over the CLI's auth.json.
        if var stored = CredentialStore.load("codex") {
            if stored.isExpired, let renewed = await refreshStored(stored) {
                stored = renewed
                CredentialStore.save(stored, for: "codex")
            }
            if !stored.isExpired {
                let creds = Credentials(
                    accessToken: stored.accessToken,
                    accountId: stored.accountId,
                    expiresAt: stored.expiresAt,
                    refreshToken: stored.refreshToken
                )
                return await fetchUsage(creds, canRetryAuth: true)
            }
            // dead in-app token: fall through to the CLI credentials
        }
        guard var creds = loadCredentials() else {
            return snapshot(.authProblem("No credentials — sign in from Settings or run `codex` once"))
        }

        if creds.isExpired {
            if let cached = await refreshed.valid() {
                creds = Credentials(
                    accessToken: cached.token,
                    accountId: creds.accountId,
                    expiresAt: cached.expiresAt,
                    refreshToken: creds.refreshToken
                )
            } else if let renewed = await refreshAccessToken(creds) {
                creds = renewed
            } else {
                return snapshot(.authProblem("Token expired and refresh failed — run `codex` once"))
            }
        }
        return await fetchUsage(creds, canRetryAuth: true)
    }

    private static func fetchUsage(_ creds: Credentials, canRetryAuth: Bool) async -> ProviderSnapshot {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 30
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaPanel", forHTTPHeaderField: "User-Agent")
        if let accountId = creds.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await HTTP.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200...299:
                return parse(data: data)
            case 401, 403:
                if canRetryAuth, let renewed = await refreshAccessToken(creds) {
                    return await fetchUsage(renewed, canRetryAuth: false)
                }
                await refreshed.clear()
                return snapshot(.authProblem("Unauthorized (\(code)) — sign in again"))
            case 429:
                return snapshot(.error("OpenAI rate limit (429) — will retry shortly"))
            default:
                return snapshot(.error("Codex API error: HTTP \(code)"))
            }
        } catch {
            return snapshot(.error("Network error: \(error.localizedDescription)"))
        }
    }

    /// refresh_token flow for the in-app credentials; unlike auth.json the
    /// ~/.quotapanel store is ours, so the caller persists the result back.
    private static func refreshStored(_ creds: StoredCredentials) async -> StoredCredentials? {
        guard let refreshToken = creds.refreshToken, !refreshToken.isEmpty else { return nil }

        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = payload

        guard let (data, response) = try? await HTTP.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty
        else { return nil }

        var renewed = creds
        renewed.accessToken = token
        if let fresh = json["refresh_token"] as? String, !fresh.isEmpty { renewed.refreshToken = fresh }
        if let idToken = json["id_token"] as? String, !idToken.isEmpty { renewed.idToken = idToken }
        if let seconds = json["expires_in"] as? Double { renewed.expiresAt = Date(timeIntervalSinceNow: seconds) }
        return renewed
    }

    /// refresh_token flow via auth.openai.com; on success the new token is
    /// cached in memory only.
    private static func refreshAccessToken(_ creds: Credentials) async -> Credentials? {
        guard let refreshToken = creds.refreshToken, !refreshToken.isEmpty else { return nil }

        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = payload

        do {
            let (data, response) = try await HTTP.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String, !token.isEmpty
            else { return nil }

            let expires: Date?
            if let seconds = json["expires_in"] as? Double {
                expires = Date(timeIntervalSinceNow: seconds)
            } else {
                expires = jwtExpiry(token)
            }
            let newRefreshToken = (json["refresh_token"] as? String) ?? refreshToken
            await refreshed.store(token: token, expiresAt: expires)
            return Credentials(
                accessToken: token,
                accountId: creds.accountId,
                expiresAt: expires,
                refreshToken: newRefreshToken
            )
        } catch {
            return nil
        }
    }

    // MARK: - Response parsing

    private struct UsageResponse: Decodable {
        struct Window: Decodable {
            let usedPercent: Double?
            let resetAt: Double?
            let limitWindowSeconds: Double?
            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case resetAt = "reset_at"
                case limitWindowSeconds = "limit_window_seconds"
            }
        }
        struct RateLimit: Decodable {
            let primaryWindow: Window?
            let secondaryWindow: Window?
            enum CodingKeys: String, CodingKey {
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
            }
        }
        let planType: String?
        let rateLimit: RateLimit?
        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
        }
    }

    static func parse(data: Data) -> ProviderSnapshot {
        guard let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            return snapshot(.error("Could not parse Codex response"))
        }

        var windows: [RateWindow] = []
        if let w = usage.rateLimit?.primaryWindow, let p = w.usedPercent {
            windows.append(RateWindow(label: windowLabel(w, fallback: "Session (5h)"), percent: p, resetsAt: resetDate(w)))
        }
        if let w = usage.rateLimit?.secondaryWindow, let p = w.usedPercent {
            windows.append(RateWindow(label: windowLabel(w, fallback: "Weekly"), percent: p, resetsAt: resetDate(w)))
        }
        guard !windows.isEmpty else {
            return snapshot(.error("No limit data in Codex response"), plan: planName(usage.planType))
        }
        return ProviderSnapshot(provider: .codex, status: .ok, windows: windows, planName: planName(usage.planType), updatedAt: Date())
    }

    private static func windowLabel(_ window: UsageResponse.Window, fallback: String) -> String {
        guard let seconds = window.limitWindowSeconds else { return fallback }
        let hours = seconds / 3600
        if hours <= 12 { return "Session (\(Int(hours.rounded()))h)" }
        let days = Int((hours / 24).rounded())
        return days >= 6 ? "Weekly" : "\(days)-day"
    }

    private static func resetDate(_ window: UsageResponse.Window) -> Date? {
        guard let ts = window.resetAt, ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    private static func planName(_ plan: String?) -> String? {
        guard let plan else { return nil }
        switch plan {
        case "plus": return "ChatGPT Plus"
        case "pro": return "ChatGPT Pro"
        case "free": return "ChatGPT Free"
        case "team": return "ChatGPT Team"
        default: return "ChatGPT \(plan.capitalized)"
        }
    }

    private static func snapshot(_ status: SnapshotStatus, plan: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(provider: .codex, status: status, windows: [], planName: plan, updatedAt: Date())
    }

    /// Reads the exp claim from a JWT payload (no signature check needed, expiry only)
    private static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
