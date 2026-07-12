import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var claude: ProviderSnapshot = .initial(provider: .claude)
    var codex: ProviderSnapshot = .initial(provider: .codex)
    var claudeDaily: [DailyStat] = []
    var codexDaily: [DailyStat] = []
    var claudeContexts: [ContextSnapshot] = []
    var codexContexts: [ContextSnapshot] = []
    /// Last-5-hours composition used to split the session window bar
    var claudeSessionParts: TokenParts?
    var codexSessionParts: TokenParts?
    /// Data for the Summary and Heatmap views; computed when first opened
    var claudeActivity: ProviderActivity?
    var codexActivity: ProviderActivity?
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

        // API calls and local log scans run in parallel
        async let claudeSnapshot = settings.claudeEnabled ? ClaudeProvider.fetch() : nil
        async let codexSnapshot = settings.codexEnabled ? CodexProvider.fetch() : nil
        async let claudeStats = settings.claudeEnabled ? claudeScanner.dailyStats() : []
        async let codexStats = settings.codexEnabled ? codexScanner.dailyStats() : []
        async let claudeCtx = settings.claudeEnabled ? ClaudeContextReader.contexts() : []
        async let codexCtx = settings.codexEnabled ? CodexContextReader.contexts() : []
        async let claudeParts = settings.claudeEnabled ? historyScanner.claudeWindowParts(hours: 5) : TokenParts()
        async let codexParts = settings.codexEnabled ? historyScanner.codexWindowParts(hours: 5) : TokenParts()

        if let snapshot = await claudeSnapshot {
            claude = snapshot
            notifier.check(snapshot: snapshot, thresholds: settings.alertThresholds)
        }
        if let snapshot = await codexSnapshot {
            codex = snapshot
            notifier.check(snapshot: snapshot, thresholds: settings.alertThresholds)
        }
        claudeDaily = await claudeStats
        codexDaily = await codexStats
        claudeContexts = await claudeCtx
        codexContexts = await codexCtx
        claudeSessionParts = await claudeParts
        codexSessionParts = await codexParts
    }

    /// Prepares Summary/Heatmap data (the scanner caches for 5 minutes)
    func loadActivity(force: Bool = false) async {
        if settings.claudeEnabled {
            claudeActivity = await historyScanner.claudeActivity(force: force)
        }
        if settings.codexEnabled {
            codexActivity = await historyScanner.codexActivity(force: force)
        }
    }

    /// Providers shown in the strip; if all are disabled, every provider is
    /// listed so the panel stays reachable
    var availableProviders: [Provider] {
        let enabled = Provider.allCases.filter { settings.isEnabled($0) }
        return enabled.isEmpty ? Provider.allCases : enabled
    }

    func snapshot(for provider: Provider) -> ProviderSnapshot {
        provider == .claude ? claude : codex
    }

    func activity(for provider: Provider) -> ProviderActivity? {
        provider == .claude ? claudeActivity : codexActivity
    }

    func contexts(for provider: Provider) -> [ContextSnapshot] {
        provider == .claude ? claudeContexts : codexContexts
    }

    func sessionParts(for provider: Provider) -> TokenParts? {
        provider == .claude ? claudeSessionParts : codexSessionParts
    }

    // MARK: - Aggregate totals

    var claudeCostToday: Double {
        let today = Calendar.current.startOfDay(for: Date())
        return claudeDaily.first(where: { $0.day == today })?.costUSD ?? 0
    }

    var claudeCostThisMonth: Double {
        let calendar = Calendar.current
        let now = Date()
        return claudeDaily
            .filter { calendar.isDate($0.day, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.costUSD }
    }

    var codexTokensToday: Int {
        let today = Calendar.current.startOfDay(for: Date())
        return codexDaily.first(where: { $0.day == today })?.tokens ?? 0
    }
}
