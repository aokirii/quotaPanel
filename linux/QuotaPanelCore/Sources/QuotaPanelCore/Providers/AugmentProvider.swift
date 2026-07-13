import Foundation

/// Augment Code credit usage via the `auggie` CLI (no API-key path exists).
enum AugmentProvider {
    static func fetch() async -> ProviderSnapshot {
        guard let cli = ProviderSupport.which("auggie") else {
            return snapshot(.authProblem("Augment CLI not found — install auggie and run 'auggie login'"))
        }
        guard let raw = await Task.detached(priority: .utility, operation: {
            ProviderSupport.run(cli, ["account", "status"], extraEnv: ["NO_COLOR": "1"], timeout: 20)
        }).value else {
            return snapshot(.error("Could not run auggie"))
        }
        let text = ProviderSupport.stripANSI(raw)
        let lower = text.lowercased()
        if lower.contains("auggie login") || lower.contains("authentication failed") || lower.contains("not authenticated") {
            return snapshot(.authProblem("Not authenticated — run 'auggie login'"))
        }
        return parse(text)
    }

    private static func parse(_ text: String) -> ProviderSnapshot {
        let remaining = ProviderSupport.firstMatch(#"([0-9,]+)\s+credits\s+remaining"#, text).flatMap(number)
        let perMonth = ProviderSupport.firstMatch(#"([0-9,]+)\s+credits\s*/\s*month"#, text).flatMap(number)
        var windows: [RateWindow] = []
        var plan: String?
        if let total = perMonth, total > 0 {
            let used = max(0, total - (remaining ?? total))
            windows.append(RateWindow(label: "Credits", percent: ProviderSupport.clamp(used / total * 100), resetsAt: nil))
            plan = "\(Int(total)) credits/month"
        }
        return ProviderSnapshot(provider: .augment, status: .ok, windows: windows, planName: plan, updatedAt: Date())
    }

    private static func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ""))
    }

    private static func snapshot(_ status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .augment, status: status, windows: [], planName: nil, updatedAt: Date())
    }
}
