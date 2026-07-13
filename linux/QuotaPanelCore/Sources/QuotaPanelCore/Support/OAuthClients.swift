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
///   "gemini": { "clientId": "…", "clientSecret": "…" },
///   "codex":  { "clientId": "…" }
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

    /// Look up one provider's client, environment variables taking precedence
    /// over the JSON file so a systemd unit or advanced user can override it.
    static func client(_ key: String) -> Client {
        let entry = table[key] ?? [:]
        let env = ProcessInfo.processInfo.environment
        let upper = key.uppercased()
        let id = env["QUOTAPANEL_\(upper)_CLIENT_ID"] ?? entry["clientId"] ?? ""
        let secret = env["QUOTAPANEL_\(upper)_CLIENT_SECRET"] ?? entry["clientSecret"] ?? ""
        return Client(id: id, secret: secret)
    }

    static var gemini: Client { client("gemini") }
    static var codex: Client { client("codex") }
    static var claude: Client { client("claude") }
}
