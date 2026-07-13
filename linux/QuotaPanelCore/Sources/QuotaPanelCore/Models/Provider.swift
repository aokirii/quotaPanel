import Foundation

/// The provider catalog, kept identical to the macOS app so snapshots line up.
/// On Linux four providers (cursor, windsurf, jetbrains, zed) still need
/// platform-specific credential paths/secret sources and are excluded from
/// `Engine.supported` until they are ported — but the cases stay here so the
/// model matches the macOS side one-to-one.
public enum Provider: String, CaseIterable, Identifiable, Codable, Sendable {
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

    public var id: String { rawValue }

    public var displayName: String {
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

    /// Short name used in compact labels / icon fallbacks.
    public var shortLabel: String {
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

    /// Brand color as a `#rrggbb` string, mirroring the macOS `brandColor`
    /// swatch. Emitted in status.json so the GNOME extension needs no color map.
    public var brandColorHex: String {
        switch self {
        case .claude: "#d97757"
        case .codex: "#10a37f"
        case .cursor: "#737887"
        case .gemini: "#4285f4"
        case .copilot: "#8250df"
        case .droid: "#cc5933"
        case .windsurf: "#34e8bb"
        case .zed: "#084eff"
        case .warp: "#938bb4"
        case .amp: "#dc2626"
        case .augment: "#6366f1"
        case .kilo: "#f27027"
        case .kiro: "#ff9900"
        case .opencode: "#3b82f6"
        case .opencodego: "#3b82f6"
        case .antigravity: "#60ba7e"
        case .devin: "#46b482"
        case .jetbrains: "#ff3399"
        case .qoder: "#10b981"
        case .commandcode: "#6b7380"
        case .crossmodel: "#7c3aed"
        case .manus: "#34322d"
        case .codebuff: "#44ff00"
        }
    }

    /// Providers with local session logs get charts, Summary/Heatmap views,
    /// and context bars; the rest only show live rate windows
    public var hasLocalLogs: Bool {
        self == .claude || self == .codex
    }

    /// Whether the provider's tool has left credentials on this machine.
    /// Linux-adapted: XDG paths instead of `~/Library`, no Keychain probe.
    public var hasLocalCredentials: Bool {
        let home = Paths.home
        let candidates: [String]
        switch self {
        case .claude:
            // On Linux the Claude CLI stores its OAuth blob as a plain file.
            candidates = ["\(home)/.claude/.credentials.json", "\(home)/.claude"]
        case .codex: candidates = ["\(home)/.codex/auth.json"]
        case .gemini: candidates = ["\(home)/.gemini/oauth_creds.json"]
        case .copilot: candidates = [
            "\(Paths.configHome)/github-copilot/apps.json",
            "\(Paths.configHome)/github-copilot/hosts.json",
        ]
        case .droid:
            if ProcessInfo.processInfo.environment["FACTORY_API_KEY"]?.isEmpty == false { return true }
            candidates = ["\(home)/.factory/.env", "\(home)/.factory/auth.json"]
        case .warp:
            return ProviderSupport.env(["WARP_API_KEY", "WARP_TOKEN"]) != nil
        case .amp:
            return ProviderSupport.env(["AMP_API_KEY"]) != nil || ProviderSupport.which("amp") != nil
        case .augment:
            return ProviderSupport.which("auggie") != nil
        case .kilo:
            if ProviderSupport.env(["KILO_API_KEY"]) != nil { return true }
            candidates = ["\(Paths.dataHome)/kilo/auth.json"]
        case .kiro:
            return ProviderSupport.which("kiro-cli") != nil
        case .opencode:
            return ProviderSupport.env(["OPENCODE_COOKIE"]) != nil
        case .opencodego:
            candidates = ["\(Paths.dataHome)/opencode/auth.json"]
        case .antigravity:
            if ProviderSupport.env(["ANTIGRAVITY_OAUTH_CREDENTIALS_JSON"]) != nil { return true }
            candidates = ["\(Paths.appConfigDir)/antigravity/oauth_creds.json"]
        case .devin:
            return ProviderSupport.env(["DEVIN_BEARER_TOKEN", "DEVIN_AUTHORIZATION"]) != nil
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
            candidates = ["\(Paths.configHome)/manicode/credentials.json"]
        // Not yet ported to Linux (macOS `~/Library` paths or Keychain).
        case .cursor, .windsurf, .jetbrains, .zed:
            return false
        }
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }
}
