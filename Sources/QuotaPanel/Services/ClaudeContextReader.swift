import Foundation

/// Açık Claude Code oturumlarının bağlam penceresi doluluğunu okur.
///
/// Açık oturumlar `~/.claude/sessions/<pid>.json` kayıt defterinden gelir: her
/// canlı süreç kendi kaydını yazar ve temiz çıkışta siler, bu yüzden pid'in
/// yaşadığını doğrulamak yeterli. Kayıt defteri yoksa (eski Claude Code) son
/// 15 dakikada yazılmış jsonl'lara, o da yoksa en yenisine düşülür.
enum ClaudeContextReader {
    static func contexts(maxSessions: Int = 3, activeMinutes: TimeInterval = 15) async -> [ContextSnapshot] {
        await Task.detached(priority: .utility) {
            contextsSync(maxSessions: maxSessions, activeMinutes: activeMinutes)
        }.value
    }

    nonisolated static func contextsSync(maxSessions: Int, activeMinutes: TimeInterval) -> [ContextSnapshot] {
        let home = FileManager.default.homeDirectoryForCurrentUser
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

    /// Kayıt defterindeki canlı oturumların jsonl yolları, en yeni etkinlik önde.
    /// Kayıt dizini yoksa nil (çağıran mtime fallback'ine düşer); boş liste
    /// "defter var ama açık oturum yok" demektir.
    private nonisolated static func registrySessionPaths(home: URL, jsonlByID: [String: URL]) -> [URL]? {
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

    /// Temiz çıkış kaydı sildiği için yalın canlılık kontrolü yeterli;
    /// EPERM "yaşıyor ama başka kullanıcının" demektir
    private nonisolated static func processIsAlive(_ pid: Int) -> Bool {
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// Tek oturumun bağlam okuması: doluluk son mesajın usage'ından, bileşim ise
    /// oturum-kümülatif girdi/önbellek-yazma/çıktı toplamlarından gelir
    private nonisolated static func readContext(url: URL, home: URL) -> ContextSnapshot? {
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
            // Sentetik/boş kayıtlar (ör. limit uyarı mesajları) pencere doluluğunu
            // temsil etmez; "son" işaretçisi yalnızca gerçek usage'a ilerler
            guard windowTokens(usage) > 0 else { continue }
            lastUsage = usage
            lastModel = message["model"] as? String ?? lastModel
            lastCwd = obj["cwd"] as? String ?? lastCwd
        }
        guard let usage = lastUsage else { return nil }

        let used = windowTokens(usage)
        let workCwd = lastCwd.isEmpty ? cwd : lastCwd
        let limit = contextLimit(used: used, model: configuredModel(cwd: cwd.isEmpty ? workCwd : cwd, home: home))

        return ContextSnapshot(
            id: url.path,
            project: workCwd.isEmpty ? "" : URL(fileURLWithPath: workCwd).lastPathComponent,
            model: lastModel,
            used: used,
            limit: limit,
            parts: parts
        )
    }

    /// Bir usage kaydının pencerede kapladığı toplam: girdi + çıktı +
    /// önbellek-yazma + önbellek-okuma
    private nonisolated static func windowTokens(_ usage: [String: Any]) -> Int {
        (usage["input_tokens"] as? Int ?? 0)
            + (usage["output_tokens"] as? Int ?? 0)
            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            + (usage["cache_read_input_tokens"] as? Int ?? 0)
    }

    /// Claude Code'un kendi öncelik sırası: proje ayarları kullanıcı ayarlarını ezer
    private nonisolated static func configuredModel(cwd: String, home: URL) -> String {
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
                  let model = obj["model"] as? String, !model.isEmpty
            else { continue }
            return model
        }
        return ""
    }

    /// '[1m]' beta'sı 1M pencere demek; değilse 200k katmanı, gözlenen kullanım
    /// 200k'yı aşınca 1M'ye yükselir — Claude Code'un sunduğu iki katman
    private nonisolated static func contextLimit(used: Int, model: String) -> Int {
        if model.lowercased().contains("1m") { return 1_000_000 }
        return used > 200_000 ? 1_000_000 : 200_000
    }
}
