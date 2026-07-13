import Foundation

/// The fetch engine: maps each supported provider to its fetcher and runs a set
/// of them concurrently. Only the providers ported to Linux appear in
/// `supported`; the four macOS-only ones (cursor, windsurf, jetbrains, zed) are
/// intentionally excluded until they are ported, so the daemon compiles and runs
/// incrementally.
public enum Engine {
    /// Providers with a working Linux fetcher, in display order.
    public static let supported: [Provider] = [
        .claude, .codex, .gemini, .copilot, .droid,
        .warp, .amp, .augment, .kilo, .kiro,
        .opencode, .opencodego, .antigravity, .devin,
        .qoder, .commandcode, .crossmodel, .manus, .codebuff,
    ]

    /// Resolve a provider name (case-insensitive rawValue) to a `Provider`.
    public static func provider(named name: String) -> Provider? {
        Provider(rawValue: name.lowercased())
    }

    /// Fetch a single provider. Unsupported providers return an error snapshot
    /// rather than crashing, so the caller can pass any provider safely.
    public static func fetch(_ provider: Provider) async -> ProviderSnapshot {
        switch provider {
        case .claude: return await ClaudeProvider.fetch()
        case .codex: return await CodexProvider.fetch()
        case .gemini: return await GeminiProvider.fetch()
        case .copilot: return await CopilotProvider.fetch()
        case .droid: return await DroidProvider.fetch()
        case .warp: return await WarpProvider.fetch()
        case .amp: return await AmpProvider.fetch()
        case .augment: return await AugmentProvider.fetch()
        case .kilo: return await KiloProvider.fetch()
        case .kiro: return await KiroProvider.fetch()
        case .opencode: return await OpenCodeProvider.fetch()
        case .opencodego: return await OpenCodeGoProvider.fetch()
        case .antigravity: return await AntigravityProvider.fetch()
        case .devin: return await DevinProvider.fetch()
        case .qoder: return await QoderProvider.fetch()
        case .commandcode: return await CommandCodeProvider.fetch()
        case .crossmodel: return await CrossModelProvider.fetch()
        case .manus: return await ManusProvider.fetch()
        case .codebuff: return await CodebuffProvider.fetch()
        case .cursor, .windsurf, .jetbrains, .zed:
            return ProviderSnapshot(provider: provider, status: .error("Not supported on Linux yet"),
                                    windows: [], planName: nil, updatedAt: Date())
        }
    }

    /// Fetch several providers concurrently, returning results in the same order
    /// as `providers` (not completion order).
    public static func fetchAll(_ providers: [Provider] = supported) async -> [ProviderSnapshot] {
        await withTaskGroup(of: (Int, ProviderSnapshot).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { (index, await fetch(provider)) }
            }
            var byIndex: [Int: ProviderSnapshot] = [:]
            for await (index, snapshot) in group { byIndex[index] = snapshot }
            return providers.indices.compactMap { byIndex[$0] }
        }
    }
}
