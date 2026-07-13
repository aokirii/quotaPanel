import Foundation

/// App-level OAuth *client* identifiers — the public `client_id` / `client_secret`
/// that each upstream CLI ships in its own bundle (e.g. gemini-cli, codex, Claude
/// Code). These are intentionally **not** committed to the repository; QuotaPanel
/// reads them at runtime from `~/.quotapanel/oauth-clients.json` (or the matching
/// `QUOTAPANEL_<PROVIDER>_CLIENT_ID` / `_CLIENT_SECRET` environment variables).
///
/// When a value is missing the affected provider degrades gracefully — its own
/// sign-in / token refresh simply fails and the panel asks you to sign in through
/// that provider's CLI. See README → "OAuth client configuration".
///
/// Expected file shape:
/// ```json
/// {
///   "gemini": { "clientId": "…", "clientSecret": "…" },
///   "codex":  { "clientId": "…" },
///   "claude": { "clientId": "…" }
/// }
/// ```
enum OAuthClients {
    struct Client {
        let id: String
        let secret: String
    }

    /// Parsed once from `~/.quotapanel/oauth-clients.json`. Missing/invalid file
    /// yields an empty table (every provider then reports "sign in again").
    private static let table: [String: [String: String]] = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".quotapanel/oauth-clients.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        else { return [:] }
        return json
    }()

    /// Look up one provider's client, environment variables taking precedence
    /// over the JSON file so CI or advanced users can override without a file.
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
