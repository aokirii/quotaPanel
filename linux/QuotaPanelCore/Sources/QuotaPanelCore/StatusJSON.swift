import Foundation

/// The on-disk contract between the daemon (writer) and the GNOME Shell
/// extension (reader). Kept deliberately flat and self-describing — the
/// extension needs no Swift knowledge and no color map (brandColor travels with
/// each provider). Bump `version` on any breaking change.
public struct StatusFile: Codable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let generatedAt: String
    public let providers: [ProviderStatus]

    public init(version: Int = StatusFile.currentVersion, generatedAt: String, providers: [ProviderStatus]) {
        self.version = version
        self.generatedAt = generatedAt
        self.providers = providers
    }
}

public struct ProviderStatus: Codable, Equatable {
    public let id: String
    public let name: String
    public let shortLabel: String
    public let brandColor: String
    /// One of: "loading" | "ok" | "authProblem" | "error".
    public let status: String
    /// Human-readable detail for authProblem/error (nil when ok/loading).
    public let message: String?
    public let plan: String?
    public let updatedAt: String?
    public let windows: [WindowStatus]
}

public struct WindowStatus: Codable, Equatable {
    public let label: String
    /// Percent USED, 0...100.
    public let percent: Double
    public let resetsAt: String?
}

/// Builds and writes `status.json`.
public enum StatusJSON {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func string(from date: Date?) -> String? {
        date.map { iso.string(from: $0) }
    }

    private static func statusFields(_ status: SnapshotStatus) -> (key: String, message: String?) {
        switch status {
        case .loading: return ("loading", nil)
        case .ok: return ("ok", nil)
        case .authProblem(let m): return ("authProblem", m)
        case .error(let m): return ("error", m)
        }
    }

    public static func makeProviderStatus(_ snapshot: ProviderSnapshot) -> ProviderStatus {
        let (key, message) = statusFields(snapshot.status)
        return ProviderStatus(
            id: snapshot.provider.rawValue,
            name: snapshot.provider.displayName,
            shortLabel: snapshot.provider.shortLabel,
            brandColor: snapshot.provider.brandColorHex,
            status: key,
            message: message,
            plan: snapshot.planName,
            updatedAt: string(from: snapshot.updatedAt),
            windows: snapshot.windows.map {
                WindowStatus(label: $0.label, percent: $0.clampedPercent, resetsAt: string(from: $0.resetsAt))
            }
        )
    }

    public static func make(from snapshots: [ProviderSnapshot], generatedAt: Date = Date()) -> StatusFile {
        StatusFile(
            generatedAt: iso.string(from: generatedAt),
            providers: snapshots.map(makeProviderStatus)
        )
    }

    public static func encode(_ file: StatusFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    /// Encode `snapshots` and write them to `path`. `Data.write(options: .atomic)`
    /// writes to a sibling temp file and renames it into place, so the extension
    /// never observes a half-written file (portable on Linux Foundation, unlike
    /// `FileManager.replaceItemAt`).
    @discardableResult
    public static func write(_ snapshots: [ProviderSnapshot], to path: String = Paths.statusFile,
                             generatedAt: Date = Date()) throws -> StatusFile {
        Paths.ensureAppConfigDir()
        let file = make(from: snapshots, generatedAt: generatedAt)
        let data = try encode(file)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return file
    }
}
