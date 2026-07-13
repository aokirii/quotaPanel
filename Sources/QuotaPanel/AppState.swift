import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    /// Live rate-limit snapshot per provider
    var snapshotsByProvider: [Provider: ProviderSnapshot] = [:]
    /// Daily cost/token stats — only providers with local logs populate this
    var dailyByProvider: [Provider: [DailyStat]] = [:]
    /// Open-session context bars — local-log providers only
    var contextsByProvider: [Provider: [ContextSnapshot]] = [:]
    /// Last-5-hours composition used to split the session window bar
    var sessionPartsByProvider: [Provider: TokenParts] = [:]
    /// Data for the Summary and Heatmap views; computed when first opened
    var activitiesByProvider: [Provider: ProviderActivity] = [:]

    var lastRefresh: Date?
    var isRefreshing = false
    /// Provider currently open in the panel; the menu bar icon mirrors it
    var selectedProvider: Provider {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: "selectedProvider") }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: "selectedProvider")
        self.selectedProvider = raw.flatMap(Provider.init(rawValue:)) ?? .claude
    }

    let settings = Settings()
    let notifier = Notifier()
    let auth = AuthManager()

    private let claudeScanner = ClaudeCostScanner()
    private let codexScanner = CodexTokenScanner()
    private let historyScanner = UsageHistoryScanner()
    private var pollTask: Task<Void, Never>?

    func start() {
        // Called from the menu bar label's onAppear; repeat calls are no-ops
        guard pollTask == nil else { return }
        notifier.setup()
        auth.onCredentialsChanged = { [weak self] in await self?.refreshAll() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAll()
                let seconds = max(30, self.settings.refreshSeconds)
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = Date()
        }

        let active = Provider.allCases.filter { settings.isEnabled($0) }

        // Local log scans (Claude/Codex) run alongside the network fetches
        async let localScans: Void = refreshLocalLogs(active: active)

        // Every enabled provider's usage endpoint is fetched concurrently
        await withTaskGroup(of: (Provider, ProviderSnapshot).self) { group in
            for provider in active {
                group.addTask { (provider, await Self.fetchSnapshot(provider)) }
            }
            for await (provider, snapshot) in group {
                snapshotsByProvider[provider] = snapshot
                notifier.check(snapshot: snapshot, thresholds: settings.alertThresholds)
            }
        }
        await localScans
    }

    /// Dispatches to the right provider fetcher. Nonisolated so the network work
    /// runs off the main actor.
    nonisolated private static func fetchSnapshot(_ provider: Provider) async -> ProviderSnapshot {
        switch provider {
        case .claude: await ClaudeProvider.fetch()
        case .codex: await CodexProvider.fetch()
        case .cursor: await CursorProvider.fetch()
        case .gemini: await GeminiProvider.fetch()
        case .copilot: await CopilotProvider.fetch()
        case .droid: await DroidProvider.fetch()
        case .windsurf: await WindsurfProvider.fetch()
        case .zed: await ZedProvider.fetch()
        case .warp: await WarpProvider.fetch()
        case .amp: await AmpProvider.fetch()
        case .augment: await AugmentProvider.fetch()
        case .kilo: await KiloProvider.fetch()
        case .kiro: await KiroProvider.fetch()
        case .opencode: await OpenCodeProvider.fetch()
        case .opencodego: await OpenCodeGoProvider.fetch()
        case .antigravity: await AntigravityProvider.fetch()
        case .devin: await DevinProvider.fetch()
        case .jetbrains: await JetBrainsProvider.fetch()
        case .qoder: await QoderProvider.fetch()
        case .commandcode: await CommandCodeProvider.fetch()
        case .crossmodel: await CrossModelProvider.fetch()
        case .manus: await ManusProvider.fetch()
        case .codebuff: await CodebuffProvider.fetch()
        }
    }

    /// Cost/token charts, context bars and session composition come from local
    /// session logs, which only Claude Code and Codex write.
    private func refreshLocalLogs(active: [Provider]) async {
        async let claudeStats = active.contains(.claude) ? claudeScanner.dailyStats() : []
        async let codexStats = active.contains(.codex) ? codexScanner.dailyStats() : []
        async let claudeCtx = active.contains(.claude) ? ClaudeContextReader.contexts() : []
        async let codexCtx = active.contains(.codex) ? CodexContextReader.contexts() : []
        async let claudeParts = active.contains(.claude) ? historyScanner.claudeWindowParts(hours: 5) : TokenParts()
        async let codexParts = active.contains(.codex) ? historyScanner.codexWindowParts(hours: 5) : TokenParts()

        dailyByProvider[.claude] = await claudeStats
        dailyByProvider[.codex] = await codexStats
        contextsByProvider[.claude] = await claudeCtx
        contextsByProvider[.codex] = await codexCtx
        sessionPartsByProvider[.claude] = await claudeParts
        sessionPartsByProvider[.codex] = await codexParts
    }

    /// Prepares Summary/Heatmap data (the scanner caches for 5 minutes)
    func loadActivity(force: Bool = false) async {
        if settings.isEnabled(.claude) {
            activitiesByProvider[.claude] = await historyScanner.claudeActivity(force: force)
        }
        if settings.isEnabled(.codex) {
            activitiesByProvider[.codex] = await historyScanner.codexActivity(force: force)
        }
    }

    /// Providers shown in the strip; if all are disabled, every provider is
    /// listed so the panel stays reachable
    var availableProviders: [Provider] {
        let enabled = Provider.allCases.filter { settings.isEnabled($0) }
        return enabled.isEmpty ? Provider.allCases : enabled
    }

    func snapshot(for provider: Provider) -> ProviderSnapshot {
        snapshotsByProvider[provider] ?? .initial(provider: provider)
    }

    func activity(for provider: Provider) -> ProviderActivity? {
        activitiesByProvider[provider]
    }

    func contexts(for provider: Provider) -> [ContextSnapshot] {
        contextsByProvider[provider] ?? []
    }

    func sessionParts(for provider: Provider) -> TokenParts? {
        sessionPartsByProvider[provider]
    }

    func daily(for provider: Provider) -> [DailyStat] {
        dailyByProvider[provider] ?? []
    }

    // MARK: - Aggregate totals

    func costToday(for provider: Provider) -> Double {
        let today = Calendar.current.startOfDay(for: Date())
        return daily(for: provider).first(where: { $0.day == today })?.costUSD ?? 0
    }

    func costThisMonth(for provider: Provider) -> Double {
        let calendar = Calendar.current
        let now = Date()
        return daily(for: provider)
            .filter { calendar.isDate($0.day, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.costUSD }
    }

    func tokensToday(for provider: Provider) -> Int {
        let today = Calendar.current.startOfDay(for: Date())
        return daily(for: provider).first(where: { $0.day == today })?.tokens ?? 0
    }
}
