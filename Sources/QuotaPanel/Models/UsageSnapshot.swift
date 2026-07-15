import Foundation

enum Provider: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex
    case cursor
    case gemini
    case copilot
    case droid
    // Coding-tool tier providers ported from CodexBar
    case windsurf
    case zed
    case warp
    case amp
    case augment
    case kilo
    case kiro
    case opencode
    case opencodego
    case antigravity
    case devin
    case jetbrains
    case qoder
    case commandcode
    case crossmodel
    case manus
    case codebuff

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .gemini: "Gemini"
        case .copilot: "Copilot"
        case .droid: "Droid"
        case .windsurf: "Windsurf"
        case .zed: "Zed"
        case .warp: "Warp"
        case .amp: "Amp"
        case .augment: "Augment"
        case .kilo: "Kilo"
        case .kiro: "Kiro"
        case .opencode: "OpenCode"
        case .opencodego: "OpenCode Go"
        case .antigravity: "Antigravity"
        case .devin: "Devin"
        case .jetbrains: "JetBrains AI"
        case .qoder: "Qoder"
        case .commandcode: "Command Code"
        case .crossmodel: "CrossModel"
        case .manus: "Manus"
        case .codebuff: "Codebuff"
        }
    }

    /// Short name used in the compact menu bar label and icon fallback
    var shortLabel: String {
        switch self {
        case .claude: "C"
        case .codex: "X"
        case .cursor: "Cu"
        case .gemini: "G"
        case .copilot: "Co"
        case .droid: "D"
        case .windsurf: "W"
        case .zed: "Z"
        case .warp: "Wa"
        case .amp: "A"
        case .augment: "Au"
        case .kilo: "K"
        case .kiro: "Ki"
        case .opencode: "O"
        case .opencodego: "Og"
        case .antigravity: "Ag"
        case .devin: "De"
        case .jetbrains: "J"
        case .qoder: "Q"
        case .commandcode: "Cc"
        case .crossmodel: "Cm"
        case .manus: "M"
        case .codebuff: "Cb"
        }
    }

    /// Providers with local session logs get charts, Summary/Heatmap views,
    /// and context bars; the rest only show live rate windows
    var hasLocalLogs: Bool {
        self == .claude || self == .codex
    }

    /// Providers with an in-app OAuth sign-in flow (Settings → Accounts):
    /// Claude/Codex/Gemini/Antigravity via OAuth callbacks, Copilot via the
    /// GitHub device flow. The remaining providers have no public OAuth
    /// client, so their credentials can only be detected from the CLI/editor.
    var supportsInAppSignIn: Bool {
        switch self {
        case .claude, .codex, .gemini, .copilot, .antigravity: true
        default: false
        }
    }

    /// Whether the provider's tool has left credentials on this machine —
    /// used only to pick sensible default toggles on first launch
    var hasLocalCredentials: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [String]
        switch self {
        case .claude: candidates = ["\(home)/.claude"]
        case .codex: candidates = ["\(home)/.codex/auth.json"]
        case .cursor: candidates = ["\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"]
        case .gemini: candidates = ["\(home)/.gemini/oauth_creds.json"]
        case .copilot: candidates = [
            "\(home)/.config/github-copilot/apps.json",
            "\(home)/.config/github-copilot/hosts.json",
        ]
        case .droid:
            // Match the fetcher's credential sources: FACTORY_API_KEY env or
            // ~/.factory/.env (auth.json is the CLI's OAuth fallback)
            if ProcessInfo.processInfo.environment["FACTORY_API_KEY"]?.isEmpty == false { return true }
            candidates = ["\(home)/.factory/.env", "\(home)/.factory/auth.json"]
        // Coding-tool tier: env token, CLI, or a local state file — each mirrors
        // the matching provider's own credential lookup.
        case .windsurf:
            candidates = ["\(home)/Library/Application Support/Windsurf/User/globalStorage/state.vscdb"]
        case .zed:
            return false // credentials live in the Keychain; don't probe it at launch
        case .warp:
            return ProviderSupport.env(["WARP_API_KEY", "WARP_TOKEN"]) != nil
        case .amp:
            return ProviderSupport.env(["AMP_API_KEY"]) != nil || ProviderSupport.which("amp") != nil
        case .augment:
            return ProviderSupport.which("auggie") != nil
        case .kilo:
            if ProviderSupport.env(["KILO_API_KEY"]) != nil { return true }
            candidates = ["\(home)/.local/share/kilo/auth.json"]
        case .kiro:
            return ProviderSupport.which("kiro-cli") != nil
        case .opencode:
            return ProviderSupport.env(["OPENCODE_COOKIE"]) != nil
        case .opencodego:
            candidates = ["\(home)/.local/share/opencode/auth.json"]
        case .antigravity:
            if ProviderSupport.env(["ANTIGRAVITY_OAUTH_CREDENTIALS_JSON"]) != nil { return true }
            candidates = ["\(home)/.quotapanel/antigravity/oauth_creds.json"]
        case .devin:
            return ProviderSupport.env(["DEVIN_BEARER_TOKEN", "DEVIN_AUTHORIZATION"]) != nil
        case .jetbrains:
            candidates = ["\(home)/Library/Application Support/JetBrains"]
        case .qoder:
            return ProviderSupport.env(["QODER_COOKIE"]) != nil
        case .commandcode:
            return ProviderSupport.env(["COMMANDCODE_COOKIE"]) != nil
        case .crossmodel:
            return ProviderSupport.env(["CROSSMODEL_API_KEY"]) != nil
        case .manus:
            return ProviderSupport.env(["MANUS_SESSION_TOKEN", "MANUS_SESSION_ID", "MANUS_COOKIE"]) != nil
        case .codebuff:
            if ProviderSupport.env(["CODEBUFF_API_KEY"]) != nil { return true }
            candidates = ["\(home)/.config/manicode/credentials.json"]
        }
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }
}

/// One rate-limit window: e.g. the 5-hour session or the weekly window
struct RateWindow: Identifiable, Equatable {
    var id: String { label }
    let label: String
    /// Fill percentage, 0...100
    let percent: Double
    let resetsAt: Date?

    var clampedPercent: Double { min(max(percent, 0), 100) }
}

enum SnapshotStatus: Equatable {
    case loading
    case ok
    /// Credentials missing or expired; the user is told how to sign in
    case authProblem(String)
    case error(String)
}

struct ProviderSnapshot: Equatable {
    let provider: Provider
    var status: SnapshotStatus
    var windows: [RateWindow]
    var planName: String?
    var updatedAt: Date?

    static func initial(provider: Provider) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, status: .loading, windows: [], planName: nil, updatedAt: nil)
    }

    /// Fullest window, used as a fallback when there is no session window
    var worstWindow: RateWindow? {
        windows.max(by: { $0.percent < $1.percent })
    }

    /// The 5-hour session window if the provider exposes one (Claude, Codex,
    /// Droid, OpenCode, OpenCode Go). Matched by label so small differences in
    /// wording ("Session (5h)", "Session (7h)", "5-hour") all resolve here.
    var sessionWindow: RateWindow? {
        windows.first { window in
            let label = window.label.lowercased()
            return label.hasPrefix("session") || label.contains("5-hour") || label.contains("5h")
        }
    }

    /// Window shown in the menu bar: the 5-hour session window when the provider
    /// has one, otherwise the fullest window so providers without a session
    /// window still show a meaningful percentage.
    var menuBarWindow: RateWindow? {
        sessionWindow ?? worstWindow
    }
}
