import Foundation

/// The on-disk contract between the daemon (writer) and the GNOME Shell
/// extension (reader). Kept deliberately flat and self-describing — the
/// extension needs no Swift knowledge and no color map (brandColor travels with
/// each provider). Bump `version` on any breaking change.
///
/// v2 adds the local-log extras (Claude/Codex only), all optional so a v1
/// reader keeps working: `sessionParts`, `contexts`, `daily`, `summary`,
/// `heatmap`.
public struct StatusFile: Codable, Equatable {
    public static let currentVersion = 2

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
    // v2 — local-log extras, only present for providers with session logs.
    /// Last-5-hours composition used to split the session window bar.
    public let sessionParts: PartsStatus?
    /// Open sessions' context-window fill.
    public let contexts: [ContextStatus]?
    /// Daily cost/token stats for the 14-day chart (up to ~35 days back).
    public let daily: [DailyStatus]?
    /// Offline summary: 24h / 7d / 30d totals with composition.
    public let summary: [SummaryBucketStatus]?
    /// Daily 12-week grid + hour-of-day punch card.
    public let heatmap: HeatmapStatus?
}

public struct WindowStatus: Codable, Equatable {
    public let label: String
    /// Percent USED, 0...100.
    public let percent: Double
    public let resetsAt: String?
}

/// input / cache-write / output raw token counts; the reader derives fractions.
public struct PartsStatus: Codable, Equatable {
    public let input: Int
    public let cache: Int
    public let output: Int

    init(_ parts: TokenParts) {
        self.input = parts.input
        self.cache = parts.cache
        self.output = parts.output
    }
}

public struct ContextStatus: Codable, Equatable {
    /// Short label from the session's working directory ("" when unknown).
    public let project: String
    /// "Fable 5 · XHigh" — preformatted model/effort/mode line ("" when unknown).
    public let detail: String
    public let used: Int
    public let limit: Int
    public let percent: Double
    public let parts: PartsStatus
}

public struct DailyStatus: Codable, Equatable {
    /// Local calendar day, "yyyy-MM-dd".
    public let day: String
    public let costUSD: Double
    public let tokens: Int
}

public struct SummaryBucketStatus: Codable, Equatable {
    public let id: String
    public let label: String
    public let parts: PartsStatus
}

/// One heatmap cell, keys kept short (t = tokens, l = level 0...4) since the
/// two grids carry a few hundred of these.
public struct HeatCellStatus: Codable, Equatable {
    public let t: Int
    public let l: Int
}

public struct HourRowStatus: Codable, Equatable {
    /// "Mon" ... "Sun"
    public let day: String
    public let cells: [HeatCellStatus]
}

public struct HeatmapStatus: Codable, Equatable {
    public let totalTokens: Int
    /// Week columns × 7 days (Mon...Sun); future days null.
    public let dailyGrid: [[HeatCellStatus?]]
    public let hourRows: [HourRowStatus]
}

/// Builds and writes `status.json`.
public enum StatusJSON {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
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

    public static func makeProviderStatus(_ snapshot: ProviderSnapshot,
                                          extras: ProviderExtras? = nil) -> ProviderStatus {
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
            },
            sessionParts: extras?.sessionParts.map(PartsStatus.init),
            contexts: extras.map { e in
                e.contexts.map { c in
                    ContextStatus(project: c.project, detail: c.model.isEmpty ? "" : c.detailLabel,
                                  used: c.used, limit: c.limit, percent: c.percent,
                                  parts: PartsStatus(c.parts))
                }
            },
            daily: extras.map { e in
                e.daily.map { DailyStatus(day: dayFormatter.string(from: $0.day), costUSD: $0.costUSD, tokens: $0.tokens) }
            },
            summary: extras?.activity.map { a in
                a.history.map { SummaryBucketStatus(id: $0.id, label: $0.label, parts: PartsStatus($0.parts)) }
            },
            heatmap: extras?.activity.map { a in
                HeatmapStatus(
                    totalTokens: a.totalTokens,
                    dailyGrid: a.dailyGrid.map { column in
                        column.map { cell in cell.map { HeatCellStatus(t: $0.tokens, l: $0.level) } }
                    },
                    hourRows: a.hourRows.map { row in
                        HourRowStatus(day: row.dayLabel, cells: row.cells.map { HeatCellStatus(t: $0.tokens, l: $0.level) })
                    }
                )
            }
        )
    }

    public static func make(from snapshots: [ProviderSnapshot],
                            extras: [Provider: ProviderExtras] = [:],
                            generatedAt: Date = Date()) -> StatusFile {
        StatusFile(
            generatedAt: iso.string(from: generatedAt),
            providers: snapshots.map { makeProviderStatus($0, extras: extras[$0.provider]) }
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
    public static func write(_ snapshots: [ProviderSnapshot],
                             extras: [Provider: ProviderExtras] = [:],
                             to path: String = Paths.statusFile,
                             generatedAt: Date = Date()) throws -> StatusFile {
        Paths.ensureAppConfigDir()
        let file = make(from: snapshots, extras: extras, generatedAt: generatedAt)
        let data = try encode(file)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return file
    }
}
