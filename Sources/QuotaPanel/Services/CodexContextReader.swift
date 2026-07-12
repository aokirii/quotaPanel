import Foundation

/// Açık Codex oturumlarının bağlam doluluğunu rollout kayıtlarından okur.
///
/// Codex'te açık-oturum kayıt defteri yok; canlılık sinyali çalışan bir
/// interaktif `codex` süreci. Süreç yoksa çubuk gösterilmez (bayat oturuma
/// düşülmez). Süreç listesi okunamazsa son 15 dakikada yazılmış rollout'lara,
/// o da yoksa en yenisine düşülür.
enum CodexContextReader {
    static func contexts(maxSessions: Int = 3, activeMinutes: TimeInterval = 15) async -> [ContextSnapshot] {
        await Task.detached(priority: .utility) {
            contextsSync(maxSessions: maxSessions, activeMinutes: activeMinutes)
        }.value
    }

    nonisolated static func contextsSync(maxSessions: Int, activeMinutes: TimeInterval) -> [ContextSnapshot] {
        if codexRunning() == false { return [] }

        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
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

    /// true: interaktif codex çalışıyor; false: çalışmıyor; nil: söylenemiyor
    private nonisolated static func codexRunning() -> Bool? {
        guard let pidsOut = run("/usr/bin/pgrep", ["-f", "codex"]) else { return nil }
        for pid in pidsOut.split(separator: "\n").map(String.init) where Int(pid) != nil {
            guard let command = run("/bin/ps", ["-o", "command=", "-p", pid]) else { continue }
            if argvIsCodexTUI(command.split(separator: " ").map(String.init)) { return true }
        }
        return false
    }

    /// İnteraktif Codex CLI'ı (TUI) tanır; `codex app-server` gibi yardımcı
    /// süreçler açık oturum sayılmaz
    private nonisolated static func argvIsCodexTUI(_ argv: [String]) -> Bool {
        guard !argv.isEmpty, !argv.contains("app-server") else { return false }
        if URL(fileURLWithPath: argv[0]).lastPathComponent == "codex" { return true }
        return argv.dropFirst().contains { $0 == "codex" || $0.hasSuffix("/codex") }
    }

    private nonisolated static func run(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Tek rollout'un bağlam okuması: doluluk son turun `total_tokens` değeri /
    /// kayıttaki `model_context_window`; bileşim tur-artımlı girdi/çıktı
    /// toplamları (önbellekli prompt okumaları hariç, Codex önbellek-yazma vermez)
    private nonisolated static func readContext(url: URL) -> ContextSnapshot? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var cwd = ""
        var model = ""
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
            id: url.path,
            project: cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent,
            model: model,
            used: usage["total_tokens"] as? Int ?? 0,
            limit: window,
            parts: parts
        )
    }
}
