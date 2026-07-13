import Foundation

/// XDG-aware filesystem locations. The macOS app anchors everything on
/// `~/Library/...`; on Linux the equivalents live under the XDG base dirs.
public enum Paths {
    /// The user's home directory. Prefers `$HOME` (what login shells and the
    /// GNOME session set) and falls back to Foundation's resolver.
    public static var home: String {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return h }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// `$XDG_CONFIG_HOME` or `~/.config`.
    public static var configHome: String {
        if let x = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !x.isEmpty { return x }
        return "\(home)/.config"
    }

    /// `$XDG_DATA_HOME` or `~/.local/share`.
    public static var dataHome: String {
        if let x = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !x.isEmpty { return x }
        return "\(home)/.local/share"
    }

    /// Where the daemon writes its output and reads its config:
    /// `~/.config/quotapanel/`.
    public static var appConfigDir: String { "\(configHome)/quotapanel" }

    /// The status snapshot the GNOME extension reads.
    public static var statusFile: String { "\(appConfigDir)/status.json" }

    /// Optional user config (enabled providers, poll interval) written by the
    /// extension's preferences in a later phase.
    public static var configFile: String { "\(appConfigDir)/config.json" }

    /// Create `appConfigDir` if missing (0700). Best-effort.
    public static func ensureAppConfigDir() {
        try? FileManager.default.createDirectory(
            atPath: appConfigDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
