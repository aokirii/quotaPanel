import Foundation

/// Credentials obtained via a QuotaPanel front-end's own sign-in (the macOS
/// app or the Windows tray). Shape matches the macOS `StoredCredentials` so
/// every QuotaPanel component reads and writes the same file.
public struct StoredCredentials: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var accountId: String?
    public var expiresAt: Date?
    public var plan: String?

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }

    public init(accessToken: String, refreshToken: String? = nil, idToken: String? = nil,
                accountId: String? = nil, expiresAt: Date? = nil, plan: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
        self.expiresAt = expiresAt
        self.plan = plan
    }
}

/// Read/write access to `~/.quotapanel/credentials.json` — the store the
/// QuotaPanel front-ends fill via in-app sign-in. The daemon prefers these
/// over the CLIs' own files and persists refreshed tokens back here (unlike
/// the CLI files, which are never written).
public enum CredentialStore {
    static var filePath: String { "\(Paths.home)/.quotapanel/credentials.json" }

    public static func load(_ key: String) -> StoredCredentials? {
        loadAll()[key]
    }

    public static func save(_ credentials: StoredCredentials, for key: String) {
        var all = loadAll()
        all[key] = credentials
        writeAll(all)
    }

    public static func delete(_ key: String) {
        var all = loadAll()
        all.removeValue(forKey: key)
        writeAll(all)
    }

    private static func loadAll() -> [String: StoredCredentials] {
        guard let data = FileManager.default.contents(atPath: filePath) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: StoredCredentials].self, from: data)) ?? [:]
    }

    private static func writeAll(_ all: [String: StoredCredentials]) {
        let dir = "\(Paths.home)/.quotapanel"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        #if !os(Windows)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath)
        #endif
    }
}
