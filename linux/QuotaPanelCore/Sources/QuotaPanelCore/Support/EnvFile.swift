import Foundation

#if canImport(Glibc)
import Glibc
#endif
#if canImport(WinSDK)
import WinSDK
#endif

/// Loads `KEY=value` lines from `~/.config/quotapanel/env` into the process
/// environment. This is the same file the README points the systemd unit's
/// `EnvironmentFile` at — loading it in the daemon too means extension-spawned
/// ("Refresh") runs see the same secrets. Existing variables always win.
public enum EnvFile {
    public static var defaultPath: String { "\(Paths.appConfigDir)/env" }

    public static func loadDefault() {
        load(path: defaultPath)
    }

    public static func load(path: String) {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eq = trimmed.firstIndex(of: "=")
            else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // Strip one level of quoting, as systemd's EnvironmentFile does
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            setIfUnset(key, value)
        }
    }

    /// `setenv(key, value, 0)` semantics on every platform: never overwrites
    /// a variable that is already set.
    private static func setIfUnset(_ key: String, _ value: String) {
        #if os(Windows)
        guard ProcessInfo.processInfo.environment[key] == nil else { return }
        key.withCString(encodedAs: UTF16.self) { k in
            value.withCString(encodedAs: UTF16.self) { v in
                _ = SetEnvironmentVariableW(k, v)
            }
        }
        #else
        setenv(key, value, 0)
        #endif
    }
}
