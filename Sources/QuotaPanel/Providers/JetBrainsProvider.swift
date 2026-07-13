import Foundation

/// JetBrains AI Assistant quota. Read from the IDE's local config XML — no
/// network and no auth. Picks the most recently modified quota file across all
/// installed JetBrains IDEs (and Android Studio).
enum JetBrainsProvider {
    static func fetch() async -> ProviderSnapshot {
        guard let xmlURL = await Task.detached(priority: .utility, operation: { latestQuotaFile() }).value else {
            return snapshot(.error("No JetBrains IDE with AI Assistant detected"))
        }
        guard let xml = try? String(contentsOf: xmlURL, encoding: .utf8) else {
            return snapshot(.error("Could not read JetBrains quota file"))
        }
        return parse(xml)
    }

    private static func latestQuotaFile() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent("Library/Application Support/JetBrains"),
            home.appendingPathComponent("Library/Application Support/Google"),
        ]
        var candidates: [URL] = []
        for dir in roots {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for ideDir in entries {
                let f = ideDir.appendingPathComponent("options/AIAssistantQuotaManager2.xml")
                if fm.fileExists(atPath: f.path) { candidates.append(f) }
            }
        }
        return candidates.max(by: { modDate($0) < modDate($1) })
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func parse(_ xml: String) -> ProviderSnapshot {
        guard let quotaRaw = attributeValue(xml, option: "quotaInfo"),
              let qdata = htmlDecode(quotaRaw).data(using: .utf8),
              let quota = try? JSONSerialization.jsonObject(with: qdata) as? [String: Any] else {
            return snapshot(.error("No JetBrains quota information found"))
        }
        // `type` is the license state (e.g. "Available", "Unknown"), not a plan
        // name. "Unknown" means no active AI Assistant license — i.e. not signed
        // in — so it must not be shown as a plan or as a healthy "ok".
        let type = (quota["type"] as? String)?.trimmingCharacters(in: .whitespaces)
        let current = num(quota["current"]) ?? 0
        let maximum = num(quota["maximum"]) ?? 0
        var reset: Date?
        if let refillRaw = attributeValue(xml, option: "nextRefill"),
           let rdata = htmlDecode(refillRaw).data(using: .utf8),
           let refill = try? JSONSerialization.jsonObject(with: rdata) as? [String: Any] {
            reset = ProviderSupport.flexibleDate(refill["next"])
        }
        if reset == nil { reset = ProviderSupport.flexibleDate(quota["until"]) }
        var windows: [RateWindow] = []
        if maximum > 0 {
            windows.append(RateWindow(label: "Current",
                                      percent: ProviderSupport.clamp(current / maximum * 100), resetsAt: reset))
        }
        guard !windows.isEmpty else {
            if type == nil || type?.isEmpty == true || type == "Unknown" {
                return snapshot(.authProblem("JetBrains AI Assistant not signed in — open your IDE and sign in"))
            }
            return snapshot(.error("No JetBrains quota data available (state: \(type ?? "?"))"))
        }
        // Only surface a meaningful license state as the plan label.
        let plan = (type == "Unknown") ? nil : type
        return ProviderSnapshot(provider: .jetbrains, status: .ok, windows: windows, planName: plan, updatedAt: Date())
    }

    private static func attributeValue(_ xml: String, option: String) -> String? {
        ProviderSupport.firstMatch("<option[^>]*name=\"\(option)\"[^>]*value=\"([^\"]*)\"", xml)
    }

    private static func htmlDecode(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&") // decode last to avoid double-unescaping
    }

    private static func num(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init)
    }

    private static func snapshot(_ status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .jetbrains, status: status, windows: [], planName: nil, updatedAt: Date())
    }
}
