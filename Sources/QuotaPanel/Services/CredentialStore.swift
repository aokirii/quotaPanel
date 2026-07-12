import Foundation

/// Credentials obtained via QuotaPanel's own sign-in
struct StoredCredentials: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var accountId: String?
    var expiresAt: Date?
    var plan: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }
}

/// Local store for in-app sign-ins: `~/.quotapanel/credentials.json`.
/// Lives entirely outside the project directory (can never end up in the
/// repo) and is readable only by the user (dir 0700, file 0600). The CLIs'
/// own credential files (`~/.claude`, `~/.codex`) are never written.
enum CredentialStore {
    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".quotapanel/credentials.json")
    }

    /// Store left over from the app's old name (KotaBar); moved on first access
    private static var legacyFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kotabar/credentials.json")
    }

    static func load(_ provider: Provider) -> StoredCredentials? {
        migrateLegacyStoreIfNeeded()
        return loadAll()[provider.rawValue]
    }

    private static func migrateLegacyStoreIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path),
              fm.fileExists(atPath: legacyFileURL.path)
        else { return }
        try? fm.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fm.moveItem(at: legacyFileURL, to: fileURL)
        try? fm.removeItem(at: legacyFileURL.deletingLastPathComponent())
    }

    static func save(_ credentials: StoredCredentials, for provider: Provider) {
        var all = loadAll()
        all[provider.rawValue] = credentials
        writeAll(all)
    }

    static func delete(_ provider: Provider) {
        var all = loadAll()
        all.removeValue(forKey: provider.rawValue)
        if all.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
        } else {
            writeAll(all)
        }
    }

    private static func loadAll() -> [String: StoredCredentials] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: StoredCredentials].self, from: data)) ?? [:]
    }

    private static func writeAll(_ all: [String: StoredCredentials]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
