import Foundation

/// Shared helpers for the providers, ported from the macOS app. Identical
/// signatures so the provider fetchers compile unchanged — with two Linux
/// differences: `home` resolves via XDG/`$HOME`, and the Keychain lookups are
/// dropped (no Security framework). Providers that relied on the Keychain
/// (claude's fallback, zed) use file/env sources on Linux instead.
enum ProviderSupport {
    static var home: String { Paths.home }

    /// A desktop-Chrome User-Agent, expected by several cookie/session endpoints.
    static let chromeUserAgent =
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    /// Trim whitespace and strip one pair of surrounding quotes.
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, let f = s.first, let l = s.last, f == l, f == "\"" || f == "'" {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    /// First non-empty environment variable from `names`, cleaned.
    static func env(_ names: [String]) -> String? {
        let e = ProcessInfo.processInfo.environment
        for name in names {
            if let v = e[name].map(clean), !v.isEmpty { return v }
        }
        return nil
    }

    static func clamp(_ value: Double, _ lo: Double = 0, _ hi: Double = 100) -> Double {
        min(max(value, lo), hi)
    }

    // MARK: - Subprocess

    /// Resolve a CLI by name across the usual install dirs plus $PATH.
    static func which(_ name: String) -> String? {
        let extras = ["/usr/local/bin", "/usr/bin", "\(home)/.local/bin", "\(home)/bin"]
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in extras + path {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Run a command with a hard timeout. Returns stdout (or nil on
    /// launch failure/timeout). Intended for small outputs only.
    @discardableResult
    static func run(_ path: String, _ args: [String], extraEnv: [String: String] = [:], timeout: TimeInterval = 15) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if !extraEnv.isEmpty {
            var e = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { e[k] = v }
            process.environment = e
        }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// Absolute path to the sqlite3 CLI, resolved once (Linux distros vary
    /// between /usr/bin and /usr/local/bin).
    static let sqlite3Path: String? = which("sqlite3")

    /// Read a single value from a SQLite DB opened immutable, via the sqlite3
    /// CLI — never contends with the owning app's writes.
    static func sqliteValue(db: URL, sql: String) -> String? {
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        guard let sqlite = sqlite3Path else { return nil }
        guard let out = run(sqlite, ["file:\(db.path)?immutable=1", sql], timeout: 5) else { return nil }
        let value = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - Dates & text

    /// Parse ISO-8601 (with/without fractional seconds) or epoch seconds/ms.
    static func flexibleDate(_ value: Any?) -> Date? {
        if let s = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) { return d }
            if let n = Double(s) { return epochDate(n) }
            return nil
        }
        if let n = (value as? NSNumber)?.doubleValue { return epochDate(n) }
        return nil
    }

    static func epochDate(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        // Anything past ~1e11 is milliseconds
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }

    /// Strip ANSI escape sequences from CLI output.
    static func stripANSI(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\u{1B}\\[[0-9;?]*[ -/]*[@-~]") else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    /// First capture group of `pattern` in `text`.
    static func firstMatch(_ pattern: String, _ text: String, options: NSRegularExpression.Options = []) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
