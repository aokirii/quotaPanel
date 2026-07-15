import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GitHub Copilot usage/quota: read the GitHub OAuth token the Copilot editor
/// extension leaves in `~/.config/github-copilot/{apps,hosts}.json` and call
/// the `api.github.com/copilot_internal/user` quota endpoint directly.
///
/// Ported from the macOS app verbatim except for XDG-safe paths and the
/// portable `HTTP.data(for:)` networking wrapper.
enum CopilotProvider {
    private static let usageURL = URL(string: "https://api.github.com/copilot_internal/user")!

    static func fetch() async -> ProviderSnapshot {
        guard let token = loadToken() else {
            return snapshot(.authProblem("No Copilot credentials — sign in from Settings or in your editor"))
        }

        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 30
        // GitHub's Copilot endpoint wants the "token" scheme, not "Bearer"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")

        do {
            let (data, response) = try await HTTP.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                return parse(data: data)
            case 401, 403:
                return snapshot(.authProblem("Unauthorized (\(code)) — reauthorize GitHub Copilot in your editor"))
            case 429:
                return snapshot(.error("GitHub rate limit (429) — will retry shortly"))
            default:
                return snapshot(.error("Copilot API error: HTTP \(code)"))
            }
        } catch {
            return snapshot(.error("Network error: \(error.localizedDescription)"))
        }
    }

    /// The GitHub OAuth token. A QuotaPanel front-end's own sign-in (the
    /// GitHub device flow) takes priority; otherwise the first
    /// `github.com[:appId]` entry's `oauth_token` from the editor's config.
    /// apps.json keys look like "github.com:Iv23…"; the older hosts.json uses
    /// a bare "github.com".
    static func loadToken() -> String? {
        if let stored = CredentialStore.load("copilot"), !stored.accessToken.isEmpty {
            return stored.accessToken
        }
        // configHome covers Linux (~/.config); on Windows Copilot's CLI/editors
        // write under %LOCALAPPDATA% (= dataHome), so probe both.
        var files: [URL] = []
        for dir in ["\(Paths.configHome)/github-copilot", "\(Paths.dataHome)/github-copilot"] {
            files.append(URL(fileURLWithPath: "\(dir)/apps.json"))
            files.append(URL(fileURLWithPath: "\(dir)/hosts.json"))
        }
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for (key, value) in root where key == "github.com" || key.hasPrefix("github.com:") {
                if let entry = value as? [String: Any],
                   let token = entry["oauth_token"] as? String, !token.isEmpty {
                    return token
                }
            }
        }
        return nil
    }

    // MARK: - Response parsing

    private struct UserResponse: Decodable {
        let copilotPlan: String?
        let quotaResetDate: String?
        let quotaResetDateUTC: String?
        let quotaSnapshots: [String: Quota]?

        struct Quota: Decodable {
            let percentRemaining: Double?
            let remaining: Double?
            let entitlement: Double?
            let unlimited: Bool?
            let hasQuota: Bool?
            enum CodingKeys: String, CodingKey {
                case percentRemaining = "percent_remaining"
                case remaining, entitlement, unlimited
                case hasQuota = "has_quota"
            }
        }
        enum CodingKeys: String, CodingKey {
            case copilotPlan = "copilot_plan"
            case quotaResetDate = "quota_reset_date"
            case quotaResetDateUTC = "quota_reset_date_utc"
            case quotaSnapshots = "quota_snapshots"
        }
    }

    /// GitHub returns a zero-shaped placeholder (entitlement/remaining both 0,
    /// often has_quota:false) for meters that don't apply to the account —
    /// e.g. premium interactions on token-based-billing plans. Those must not
    /// render as a misleading 100%-full bar.
    private static func isPlaceholder(_ q: UserResponse.Quota) -> Bool {
        if q.unlimited == true { return false }
        if q.hasQuota == false { return true }
        let entitlement = q.entitlement ?? 0
        let remaining = q.remaining ?? 0
        return entitlement == 0 && remaining == 0
    }

    static func parse(data: Data) -> ProviderSnapshot {
        guard let user = try? JSONDecoder().decode(UserResponse.self, from: data) else {
            return snapshot(.error("Could not parse Copilot response"))
        }
        let plan = user.copilotPlan.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let reset = parseReset(user.quotaResetDateUTC) ?? parseReset(user.quotaResetDate)

        // Priority order for the meters worth showing
        let ordered: [(id: String, label: String)] = [
            ("premium_interactions", "Premium"),
            ("chat", "Chat"),
            ("completions", "Completions"),
        ]
        var windows: [RateWindow] = []
        for entry in ordered {
            guard let q = user.quotaSnapshots?[entry.id], !isPlaceholder(q) else { continue }
            let percentUsed: Double
            if q.unlimited == true {
                percentUsed = 0
            } else if let remaining = q.percentRemaining {
                percentUsed = max(0, 100 - remaining)
            } else {
                continue
            }
            windows.append(RateWindow(label: entry.label, percent: percentUsed, resetsAt: reset))
        }

        guard !windows.isEmpty else {
            // All meters were placeholders (token-based billing) — show plan only
            return ProviderSnapshot(provider: .copilot, status: .ok, windows: [], planName: plan, updatedAt: Date())
        }
        return ProviderSnapshot(provider: .copilot, status: .ok, windows: windows, planName: plan, updatedAt: Date())
    }

    private static func parseReset(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = TimeZone(identifier: "UTC")
        return day.date(from: string)
    }

    private static func snapshot(_ status: SnapshotStatus, plan: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(provider: .copilot, status: status, windows: [], planName: plan, updatedAt: Date())
    }
}
