import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Claude Code usage data: read from the `api.anthropic.com/api/oauth/usage`
/// endpoint using the OAuth token the Claude CLI leaves on disk.
///
/// Linux port: the macOS app also supports an in-app OAuth sign-in stored in its
/// own CredentialStore (with refresh); on Linux that flow is deferred, so the
/// token comes only from the CLI's `~/.claude/.credentials.json` (a plain file
/// on Linux — there is no Keychain). The file is read-only; we never write it.
enum ClaudeProvider {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let fallbackVersion = "2.1.0"

    // `claude --version` output detected once and cached (for the User-Agent)
    private static let detectedVersion: String = detectClaudeVersion()

    struct Credentials {
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 60
        }
    }

    /// Read the CLI's OAuth blob from `~/.claude/.credentials.json`.
    static func loadCredentials() -> Credentials? {
        let url = URL(fileURLWithPath: "\(Paths.home)/.claude/.credentials.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }

        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expires = Date(timeIntervalSince1970: ms / 1000)
        }
        return Credentials(
            accessToken: token,
            expiresAt: expires,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }

    static func fetch() async -> ProviderSnapshot {
        guard let creds = loadCredentials() else {
            return snapshot(.authProblem("No credentials — run `claude` once to sign in"))
        }
        if creds.isExpired {
            return snapshot(.authProblem("CLI token expired — run `claude` once to refresh"), plan: planName(creds.subscriptionType))
        }
        return await fetchUsage(token: creds.accessToken, plan: planName(creds.subscriptionType))
    }

    private static func fetchUsage(token: String, plan: String?) async -> ProviderSnapshot {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(detectedVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await HTTP.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                return parse(data: data, plan: plan)
            case 401:
                return snapshot(.authProblem("Unauthorized (401) — run `claude` once to refresh"))
            case 429:
                return snapshot(.error("Anthropic rate limit (429) — will retry shortly"))
            default:
                return snapshot(.error("Claude API error: HTTP \(code)"))
            }
        } catch {
            return snapshot(.error("Network error: \(error.localizedDescription)"))
        }
    }

    // MARK: - Response parsing

    private struct UsageResponse: Decodable {
        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?
            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct ModelRef: Decodable {
                    let displayName: String?
                    enum CodingKeys: String, CodingKey { case displayName = "display_name" }
                }
                let model: ModelRef?
            }
            let kind: String?
            let percent: Double?
            let resetsAt: String?
            let scope: Scope?
            enum CodingKeys: String, CodingKey {
                case kind, percent, scope
                case resetsAt = "resets_at"
            }
        }
        let fiveHour: Window?
        let sevenDay: Window?
        let limits: [Limit]?
        enum CodingKeys: String, CodingKey {
            case limits
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    static func parse(data: Data, plan: String?) -> ProviderSnapshot {
        guard let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            return snapshot(.error("Could not parse Claude response"), plan: plan)
        }

        var windows: [RateWindow] = []
        if let limits = usage.limits, !limits.isEmpty {
            for limit in limits {
                guard let percent = limit.percent else { continue }
                windows.append(RateWindow(
                    label: label(forKind: limit.kind, modelName: limit.scope?.model?.displayName),
                    percent: percent,
                    resetsAt: parseISO(limit.resetsAt)
                ))
            }
        }
        if windows.isEmpty {
            if let w = usage.fiveHour, let p = w.utilization {
                windows.append(RateWindow(label: "Session (5h)", percent: p, resetsAt: parseISO(w.resetsAt)))
            }
            if let w = usage.sevenDay, let p = w.utilization {
                windows.append(RateWindow(label: "Weekly", percent: p, resetsAt: parseISO(w.resetsAt)))
            }
        }
        guard !windows.isEmpty else {
            return snapshot(.error("No limit data in Claude response"), plan: plan)
        }
        return ProviderSnapshot(provider: .claude, status: .ok, windows: windows, planName: plan, updatedAt: Date())
    }

    private static func label(forKind kind: String?, modelName: String?) -> String {
        switch kind {
        case "session": return "Session (5h)"
        case "weekly_all": return "Weekly (overall)"
        case "weekly_scoped": return "Weekly (\(modelName ?? "model"))"
        default: return kind ?? "Limit"
        }
    }

    private static func planName(_ subscription: String?) -> String? {
        switch subscription {
        case "pro": return "Claude Pro"
        case "max": return "Claude Max"
        case let other?: return "Claude \(other.capitalized)"
        case nil: return nil
        }
    }

    private static func parseISO(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func snapshot(_ status: SnapshotStatus, plan: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(provider: .claude, status: status, windows: [], planName: plan, updatedAt: Date())
    }

    /// Detect the installed CLI version for the User-Agent. Uses the resolved
    /// `claude` binary (XDG install dirs + $PATH) and a plain regex so it stays
    /// portable across Swift toolchains.
    private static func detectClaudeVersion() -> String {
        guard let bin = ProviderSupport.which("claude") else { return fallbackVersion }
        guard let text = ProviderSupport.run(bin, ["--version"], timeout: 5) else { return fallbackVersion }
        return ProviderSupport.firstMatch("([0-9]+\\.[0-9]+\\.[0-9]+)", text) ?? fallbackVersion
    }
}
