import Foundation

/// Platform-aware filesystem locations. The macOS app anchors everything on
/// `~/Library/...`; on Linux the equivalents live under the XDG base dirs, and
/// on Windows under the profile's AppData folders. Windows APIs accept `/` as
/// a separator, so paths are interpolated with `/` on every platform.
public enum Paths {
    /// The user's home directory. Prefers the platform env var (what login
    /// shells / the session set) and falls back to Foundation's resolver.
    public static var home: String {
        #if os(Windows)
        if let h = ProcessInfo.processInfo.environment["USERPROFILE"], !h.isEmpty { return h }
        #else
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return h }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// `$XDG_CONFIG_HOME` or `~/.config`; `%APPDATA%` on Windows.
    public static var configHome: String {
        #if os(Windows)
        if let a = ProcessInfo.processInfo.environment["APPDATA"], !a.isEmpty { return a }
        return "\(home)/AppData/Roaming"
        #else
        if let x = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !x.isEmpty { return x }
        return "\(home)/.config"
        #endif
    }

    /// `$XDG_DATA_HOME` or `~/.local/share`; `%LOCALAPPDATA%` on Windows.
    public static var dataHome: String {
        #if os(Windows)
        if let l = ProcessInfo.processInfo.environment["LOCALAPPDATA"], !l.isEmpty { return l }
        return "\(home)/AppData/Local"
        #else
        if let x = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !x.isEmpty { return x }
        return "\(home)/.local/share"
        #endif
    }

    /// Where the daemon writes its output and reads its config:
    /// `~/.config/quotapanel/` (Linux) or `%APPDATA%/quotapanel/` (Windows).
    public static var appConfigDir: String { "\(configHome)/quotapanel" }

    /// The status snapshot the UI shell (GNOME extension / Windows tray) reads.
    public static var statusFile: String { "\(appConfigDir)/status.json" }

    /// Optional user config (enabled providers, poll interval) written by the
    /// UI shell's settings.
    public static var configFile: String { "\(appConfigDir)/config.json" }

    /// Create `appConfigDir` if missing (0700 where POSIX permissions exist).
    /// Best-effort.
    public static func ensureAppConfigDir() {
        #if os(Windows)
        try? FileManager.default.createDirectory(
            atPath: appConfigDir,
            withIntermediateDirectories: true
        )
        #else
        try? FileManager.default.createDirectory(
            atPath: appConfigDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #endif
    }
}
