import Foundation

/// Gathers everything derived from local session logs (Claude Code and Codex
/// only): session-window composition, open-session context bars, daily
/// cost/token stats, and the Summary/Heatmap activity. Mirrors the macOS
/// app's `refreshLocalLogs` + `loadActivity`, but computed in one pass since
/// the daemon writes a complete status.json per run.
public enum LocalUsage {
    /// The 5-hour session window drives the composition split, same as macOS.
    static let sessionWindowHours = 5.0

    public static func extras(for providers: [Provider]) async -> [Provider: ProviderExtras] {
        await withTaskGroup(of: (Provider, ProviderExtras).self) { group in
            for provider in providers where provider.hasLocalLogs {
                group.addTask { (provider, gather(provider)) }
            }
            var result: [Provider: ProviderExtras] = [:]
            for await (provider, extras) in group { result[provider] = extras }
            return result
        }
    }

    private static func gather(_ provider: Provider) -> ProviderExtras {
        var extras = ProviderExtras()
        switch provider {
        case .claude:
            extras.sessionParts = UsageHistoryScanner.claudeWindowParts(hours: sessionWindowHours)
            extras.contexts = ClaudeContextReader.contexts()
            extras.daily = ClaudeCostScanner.dailyStats()
            extras.activity = UsageHistoryScanner.claudeActivity()
        case .codex:
            extras.sessionParts = UsageHistoryScanner.codexWindowParts(hours: sessionWindowHours)
            extras.contexts = CodexContextReader.contexts()
            extras.daily = CodexTokenScanner.dailyStats()
            extras.activity = UsageHistoryScanner.codexActivity()
        default:
            break
        }
        return extras
    }
}
