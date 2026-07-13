import Foundation

/// Kiro usage via the `kiro-cli` tool. Shells out and scrapes the ANSI output.
enum KiroProvider {
    static func fetch() async -> ProviderSnapshot {
        guard let cli = ProviderSupport.which("kiro-cli") else {
            return snapshot(.authProblem("kiro-cli not found — install it from https://kiro.dev"))
        }
        let env = ["TERM": "xterm-256color"]
        if let who = await Task.detached(priority: .utility, operation: {
            ProviderSupport.run(cli, ["whoami"], extraEnv: env, timeout: 5)
        }).value {
            let w = ProviderSupport.stripANSI(who).lowercased()
            if w.contains("not logged in") || w.contains("login required") || w.contains("kiro-cli login") {
                return snapshot(.authProblem("Not logged in to Kiro — run 'kiro-cli login'"))
            }
        }
        guard let raw = await Task.detached(priority: .utility, operation: {
            ProviderSupport.run(cli, ["chat", "--no-interactive", "/usage"], extraEnv: env, timeout: 20)
        }).value else {
            return snapshot(.error("Could not read Kiro usage"))
        }
        return parse(ProviderSupport.stripANSI(raw))
    }

    private static func parse(_ text: String) -> ProviderSnapshot {
        var plan = ProviderSupport.firstMatch(#"Plan:\s*(.+)"#, text)?.trimmingCharacters(in: .whitespaces)
        if plan == nil { plan = ProviderSupport.firstMatch(#"\|[ \t]*(KIRO[ \t]+\w+)"#, text) }
        var windows: [RateWindow] = []
        let reset = ProviderSupport.firstMatch(#"resets on\s+([0-9/-]+)"#, text).flatMap(parseResetDate)
        if let pctStr = ProviderSupport.firstMatch(#"(\d+)%"#, text), let pct = Double(pctStr) {
            windows.append(RateWindow(label: "Credits", percent: ProviderSupport.clamp(pct), resetsAt: reset))
        } else if let usedStr = ProviderSupport.firstMatch(#"\(([0-9.]+) of \d+ covered"#, text),
                  let totalStr = ProviderSupport.firstMatch(#"\([0-9.]+ of (\d+) covered"#, text),
                  let used = Double(usedStr), let total = Double(totalStr), total > 0 {
            windows.append(RateWindow(label: "Credits", percent: ProviderSupport.clamp(used / total * 100), resetsAt: reset))
        }
        if windows.isEmpty && plan == nil {
            return snapshot(.error("Could not parse Kiro usage"))
        }
        return ProviderSnapshot(provider: .kiro, status: .ok, windows: windows, planName: plan, updatedAt: Date())
    }

    private static func parseResetDate(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["yyyy-MM-dd", "MM/dd", "M/d"] {
            fmt.dateFormat = pattern
            if let d = fmt.date(from: s) { return d }
        }
        return nil
    }

    private static func snapshot(_ status: SnapshotStatus) -> ProviderSnapshot {
        ProviderSnapshot(provider: .kiro, status: status, windows: [], planName: nil, updatedAt: Date())
    }
}
