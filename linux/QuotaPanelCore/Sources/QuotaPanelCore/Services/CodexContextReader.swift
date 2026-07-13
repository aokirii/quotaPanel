import Foundation

/// Reads the context fill of open Codex sessions from rollout logs.
///
/// Codex has no open-session registry; the liveness signal is a running
/// interactive `codex` process. No process → no bars (no stale fallback).
/// If the process list can't be read, falls back to rollouts written in the
/// last 15 minutes, then the newest. Ported from the macOS app; pgrep/ps are
/// resolved through /usr/bin/env since their location differs per distro.
enum CodexContextReader {
    static func contexts(maxSessions: Int = 3, activeMinutes: TimeInterval = 15) -> [ContextSnapshot] {
        if codexRunning() == false { return [] }

        let root = URL(fileURLWithPath: "\(Paths.home)/.codex/sessions")
        var files: [(mtime: Date, url: URL)] = []
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { continue }
                files.append((mtime, url))
            }
        }
        guard !files.isEmpty else { return [] }
        files.sort { $0.mtime > $1.mtime }

        let cutoff = Date(timeIntervalSinceNow: -activeMinutes * 60)
        let recent = files.filter { $0.mtime >= cutoff }.map(\.url)
        let paths = recent.isEmpty ? [files[0].url] : recent

        return paths.prefix(maxSessions).compactMap { readContext(url: $0) }
    }

    /// true: an interactive codex is running; false: none; nil: can't tell
    private static func codexRunning() -> Bool? {
        guard let pidsOut = run(["pgrep", "-f", "codex"]) else { return nil }
        for pid in pidsOut.split(separator: "\n").map(String.init) where Int(pid) != nil {
            guard let command = run(["ps", "-o", "command=", "-p", pid]) else { continue }
            if argvIsCodexTUI(command.split(separator: " ").map(String.init)) { return true }
        }
        return false
    }

    /// Recognizes the interactive Codex CLI (TUI); helpers like
    /// `codex app-server` don't count as open sessions
    private static func argvIsCodexTUI(_ argv: [String]) -> Bool {
        guard !argv.isEmpty, !argv.contains("app-server") else { return false }
        if URL(fileURLWithPath: argv[0]).lastPathComponent == "codex" { return true }
        return argv.dropFirst().contains { $0 == "codex" || $0.hasSuffix("/codex") }
    }

    private static func run(_ argv: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Context reading for one rollout: fill is the last turn's `total_tokens`
    /// against the log's `model_context_window`; composition is per-turn
    /// incremental input/output (cached prompt reads excluded; Codex reports
    /// no cache-write count)
    private static func readContext(url: URL) -> ContextSnapshot? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var cwd = ""
        var model = ""
        var effort: String?
        var collaborationMode: String?
        var window = 0
        var parts = TokenParts()
        var lastUsage: [String: Any]?

        for line in raw.split(separator: "\n") {
            let interesting = line.contains("\"token_count\"")
                || line.contains("\"session_meta\"")
                || line.contains("\"turn_context\"")
            guard interesting,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any]
            else { continue }

            switch obj["type"] as? String {
            case "session_meta":
                cwd = payload["cwd"] as? String ?? cwd
            case "turn_context":
                model = payload["model"] as? String ?? model
                cwd = payload["cwd"] as? String ?? cwd
                effort = payload["effort"] as? String ?? effort
                if let collab = payload["collaboration_mode"] as? [String: Any] {
                    collaborationMode = collab["mode"] as? String ?? collaborationMode
                }
            case "event_msg" where payload["type"] as? String == "token_count":
                guard let info = payload["info"] as? [String: Any],
                      let lu = info["last_token_usage"] as? [String: Any]
                else { continue }
                lastUsage = lu
                window = info["model_context_window"] as? Int ?? window
                let fresh = (lu["input_tokens"] as? Int ?? 0) - (lu["cached_input_tokens"] as? Int ?? 0)
                parts.input += max(0, fresh)
                parts.output += (lu["output_tokens"] as? Int ?? 0) + (lu["reasoning_output_tokens"] as? Int ?? 0)
            default:
                break
            }
        }
        guard let usage = lastUsage, window > 0 else { return nil }

        return ContextSnapshot(
            project: cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent,
            model: model,
            used: usage["total_tokens"] as? Int ?? 0,
            limit: window,
            parts: parts,
            effort: effort,
            // "default" carries no information; only special modes like plan are shown
            mode: collaborationMode.flatMap { $0 == "default" ? nil : $0 }
        )
    }
}
