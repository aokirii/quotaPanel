import Foundation

/// App-level OAuth *client* identifiers — the public `client_id` / `client_secret`
/// that each upstream CLI ships in its own bundle (gemini-cli, codex). These are
/// intentionally **not** committed to the repository; the daemon reads them at
/// runtime from `~/.config/quotapanel/oauth-clients.json` (or the matching
/// `QUOTAPANEL_<PROVIDER>_CLIENT_ID` / `_CLIENT_SECRET` environment variables).
///
/// When a value is missing the affected provider degrades gracefully — its token
/// refresh fails and the panel asks you to sign in through that provider's CLI.
/// See `oauth-clients.sample.json` at the repo root for the template.
///
/// Expected file shape:
/// ```json
/// {
///   "gemini":      { "clientId": "…", "clientSecret": "…" },
///   "codex":       { "clientId": "…" },
///   "claude":      { "clientId": "…" },
///   "copilot":     { "clientId": "…" },
///   "antigravity": { "clientId": "…", "clientSecret": "…" }
/// }
/// ```
enum OAuthClients {
    struct Client {
        let id: String
        let secret: String
    }

    /// Parsed once from `~/.config/quotapanel/oauth-clients.json`. A missing or
    /// invalid file yields an empty table (each provider then reports it needs a
    /// fresh CLI sign-in).
    private static let table: [String: [String: String]] = {
        let url = URL(fileURLWithPath: "\(Paths.appConfigDir)/oauth-clients.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        else { return [:] }
        return json
    }()

    /// Public client ids the upstream CLIs publish in their own open-source
    /// code — the same values CodexBar hardcodes. Bundled so token refresh (and
    /// the front-ends' in-app sign-in) work out of the box; a value in
    /// oauth-clients.json or the env vars still overrides these.
    ///
    /// NOTE: these belong to the upstream vendors; see README → "OAuth client
    /// configuration". Claude is intentionally NOT bundled (Anthropic restricts
    /// its OAuth to Claude Code / Claude.ai). Antigravity is not bundled either
    /// (its client id/secret come from Antigravity's own credential file).
    private static let builtinDefaults: [String: [String: String]] = [
        "gemini": [
            "clientId": "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com",
            "clientSecret": "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",
        ],
        "codex": ["clientId": "app_EMoamEEZ73f0CkXaXp7hrann"],
        "copilot": ["clientId": "Iv1.b507a08c87ecfe98"],
    ]

    /// Look up one provider's client. Precedence: environment variable →
    /// oauth-clients.json → bundled default.
    static func client(_ key: String) -> Client {
        let entry = table[key] ?? [:]
        let fallback = builtinDefaults[key] ?? [:]
        let env = ProcessInfo.processInfo.environment
        let upper = key.uppercased()
        let id = env["QUOTAPANEL_\(upper)_CLIENT_ID"] ?? entry["clientId"] ?? fallback["clientId"] ?? ""
        let secret = env["QUOTAPANEL_\(upper)_CLIENT_SECRET"] ?? entry["clientSecret"] ?? fallback["clientSecret"] ?? ""
        return Client(id: id, secret: secret)
    }

    static var gemini: Client { client("gemini") }
    static var codex: Client { client("codex") }
    static var claude: Client { client("claude") }
    static var copilot: Client { client("copilot") }
    static var antigravity: Client { client("antigravity") }
}
