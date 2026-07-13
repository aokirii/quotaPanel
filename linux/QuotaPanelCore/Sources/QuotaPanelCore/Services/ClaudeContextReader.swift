import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// Reads the context-window fill of open Claude Code sessions.
///
/// Open sessions come from the `~/.claude/sessions/<pid>.json` registry: every
/// live process writes its own entry and removes it on clean exit, so checking
/// that the pid is alive is enough. Without a registry (older Claude Code) it
/// falls back to jsonl files written in the last 15 minutes, then the newest.
/// Ported from the macOS app; `kill(pid, 0)` liveness works identically here.
enum ClaudeContextReader {
    static func contexts(maxSessions: Int = 3, activeMinutes: TimeInterval = 15) -> [ContextSnapshot] {
        let home = URL(fileURLWithPath: Paths.home)
        let projectsRoot = home.appendingPathComponent(".claude/projects")

        var files: [(mtime: Date, url: URL)] = []
        var byID: [String: URL] = [:]
        if let enumerator = FileManager.default.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { continue }
                files.append((mtime, url))
                byID[url.deletingPathExtension().lastPathComponent] = url
            }
        }
        guard !files.isEmpty else { return [] }
        files.sort { $0.mtime > $1.mtime }

        var paths = registrySessionPaths(home: home, jsonlByID: byID)
        if paths == nil {
            let cutoff = Date(timeIntervalSinceNow: -activeMinutes * 60)
            let recent = files.filter { $0.mtime >= cutoff }.map(\.url)
            paths = recent.isEmpty ? [files[0].url] : recent
        }

        return (paths ?? []).prefix(maxSessions).compactMap { readContext(url: $0, home: home) }
    }

    /// jsonl paths of live sessions in the registry, most recent activity first.
    /// nil when the registry directory is missing (caller falls back to mtime);
    /// an empty list means "registry exists but no open sessions".
    private static func registrySessionPaths(home: URL, jsonlByID: [String: URL]) -> [URL]? {
        let dir = home.appendingPathComponent(".claude/sessions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }

        var entries: [(order: Double, url: URL)] = []
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let reg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = reg["pid"] as? Int,
                  let sessionID = reg["sessionId"] as? String,
                  let url = jsonlByID[sessionID],
                  processIsAlive(pid)
            else { continue }
            let order = (reg["statusUpdatedAt"] as? Double) ?? (reg["startedAt"] as? Double) ?? 0
            entries.append((order, url))
        }
        return entries.sorted { $0.order > $1.order }.map(\.url)
    }

    /// A plain liveness check suffices since clean exits remove the entry;
    /// EPERM means "alive but owned by another user"
    private static func processIsAlive(_ pid: Int) -> Bool {
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// Context reading for one session: fill comes from the last message's
    /// usage, composition from session-cumulative input/cache-write/output totals
    private static func readContext(url: URL, home: URL) -> ContextSnapshot? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var cwd = ""
        var parts = TokenParts()
        var lastUsage: [String: Any]?
        var lastModel = ""
        var lastCwd = ""

        for line in raw.split(separator: "\n") {
            let hasUsage = line.contains("\"usage\"")
            guard hasUsage || (cwd.isEmpty && line.contains("\"cwd\"")) else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if cwd.isEmpty, let c = obj["cwd"] as? String { cwd = c }
            guard let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            parts.input += usage["input_tokens"] as? Int ?? 0
            parts.cache += UsageHistoryScanner.cacheWriteTokens(usage)
            parts.output += usage["output_tokens"] as? Int ?? 0
            // Synthetic/empty records (e.g. limit warnings) don't represent window
            // fill; the "last" pointer only advances on real usage
            guard windowTokens(usage) > 0 else { continue }
            lastUsage = usage
            lastModel = message["model"] as? String ?? lastModel
            lastCwd = obj["cwd"] as? String ?? lastCwd
        }
        guard let usage = lastUsage else { return nil }

        let used = windowTokens(usage)
        let workCwd = lastCwd.isEmpty ? cwd : lastCwd
        let settingsCwd = cwd.isEmpty ? workCwd : cwd
        let limit = contextLimit(used: used, model: configuredModel(cwd: settingsCwd, home: home))

        return ContextSnapshot(
            project: workCwd.isEmpty ? "" : URL(fileURLWithPath: workCwd).lastPathComponent,
            model: lastModel,
            used: used,
            limit: limit,
            parts: parts,
            effort: configuredEffort(cwd: settingsCwd, home: home),
            // mode deliberately empty: Claude Code doesn't record modes like
            // ultracode anywhere structured; text search gives false positives
            mode: nil
        )
    }

    /// Total window occupancy of one usage record: input + output +
    /// cache-write + cache-read
    private static func windowTokens(_ usage: [String: Any]) -> Int {
        (usage["input_tokens"] as? Int ?? 0)
            + (usage["output_tokens"] as? Int ?? 0)
            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            + (usage["cache_read_input_tokens"] as? Int ?? 0)
    }

    /// Claude Code's own precedence: project settings override user settings
    private static func configuredModel(cwd: String, home: URL) -> String {
        settingsValue("model", cwd: cwd, home: home) ?? ""
    }

    /// Reasoning effort (`effortLevel`); Claude Code stores this in settings,
    /// not per session
    private static func configuredEffort(cwd: String, home: URL) -> String? {
        settingsValue("effortLevel", cwd: cwd, home: home)
    }

    private static func settingsValue(_ key: String, cwd: String, home: URL) -> String? {
        var candidates: [URL] = []
        if !cwd.isEmpty {
            let base = URL(fileURLWithPath: cwd).appendingPathComponent(".claude")
            candidates.append(base.appendingPathComponent("settings.local.json"))
            candidates.append(base.appendingPathComponent("settings.json"))
        }
        candidates.append(home.appendingPathComponent(".claude/settings.json"))
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = obj[key] as? String, !value.isEmpty
            else { continue }
            return value
        }
        return nil
    }

    /// The '[1m]' beta means a 1M window; otherwise the 200k tier, upgraded
    /// to 1M once observed usage exceeds 200k — the two tiers Claude Code offers
    private static func contextLimit(used: Int, model: String) -> Int {
        if model.lowercased().contains("1m") { return 1_000_000 }
        return used > 200_000 ? 1_000_000 : 200_000
    }
}
