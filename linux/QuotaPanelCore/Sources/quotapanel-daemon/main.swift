import Foundation
import QuotaPanelCore

// quotapanel-daemon — fetches provider quotas and writes status.json for the
// GNOME Shell extension to render.
//
//   quotapanel-daemon --once                 fetch once, write, exit
//   quotapanel-daemon --interval 300         loop, refreshing every 300s
//   quotapanel-daemon --providers claude,codex   restrict to a subset
//   quotapanel-daemon --out /path/status.json    override the output path
//   quotapanel-daemon --stdout               also print the JSON to stdout
//
// With neither --once nor --interval it defaults to a single fetch (--once).

func stderrLine(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func parsePositiveInt(_ s: String?) -> Int? {
    guard let s, let n = Int(s), n > 0 else { return nil }
    return n
}

struct Options {
    var once = true
    var interval: Int?          // seconds; when set, loop
    var providers: [Provider] = Engine.supported
    var outPath = Paths.statusFile
    var alsoStdout = false
}

func parseArguments(_ argv: [String]) -> Options {
    var opts = Options()
    var i = 0
    while i < argv.count {
        let arg = argv[i]
        switch arg {
        case "--once":
            opts.once = true
            opts.interval = nil
        case "--interval":
            i += 1
            if let n = parsePositiveInt(i < argv.count ? argv[i] : nil) {
                opts.interval = n
                opts.once = false
            } else {
                stderrLine("--interval needs a positive number of seconds; ignoring")
            }
        case "--providers":
            i += 1
            let list = (i < argv.count ? argv[i] : "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var resolved: [Provider] = []
            for name in list {
                if let p = Engine.provider(named: name), Engine.supported.contains(p) {
                    resolved.append(p)
                } else {
                    stderrLine("Unknown or unsupported provider '\(name)' — skipping")
                }
            }
            if !resolved.isEmpty { opts.providers = resolved }
        case "--out":
            i += 1
            if i < argv.count { opts.outPath = argv[i] }
        case "--stdout":
            opts.alsoStdout = true
        case "--help", "-h":
            print("""
            quotapanel-daemon — write AI quota status.json for the GNOME extension

            Usage:
              quotapanel-daemon [--once | --interval SECONDS]
                                [--providers a,b,c] [--out PATH] [--stdout]

            Supported providers:
              \(Engine.supported.map(\.rawValue).joined(separator: ", "))
            """)
            exit(0)
        default:
            stderrLine("Unknown argument '\(arg)' — ignoring")
        }
        i += 1
    }
    return opts
}

@discardableResult
func refreshOnce(_ opts: Options) async -> Bool {
    // Local-log scans (Claude/Codex charts, contexts, heatmaps) run alongside
    // the network fetches.
    async let extras = LocalUsage.extras(for: opts.providers)
    let snapshots = await Engine.fetchAll(opts.providers)
    do {
        let file = try StatusJSON.write(snapshots, extras: await extras, to: opts.outPath)
        if opts.alsoStdout, let data = try? StatusJSON.encode(file),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        let okCount = snapshots.filter { if case .ok = $0.status { return true } else { return false } }.count
        stderrLine("Wrote \(snapshots.count) providers (\(okCount) ok) → \(opts.outPath)")
        return true
    } catch {
        stderrLine("Failed to write \(opts.outPath): \(error.localizedDescription)")
        return false
    }
}

// Secrets from ~/.config/quotapanel/env (existing variables win), so runs
// spawned by the extension's Refresh see the same keys as the systemd unit.
EnvFile.loadDefault()

var opts = parseArguments(Array(CommandLine.arguments.dropFirst()))

// Providers disabled in the extension's Settings are skipped unless an
// explicit --providers list was given on the command line.
if !CommandLine.arguments.contains("--providers"), let config = UserConfig.load() {
    opts.providers = config.providerFilter(from: opts.providers)
}

if let interval = opts.interval {
    stderrLine("quotapanel-daemon: refreshing every \(interval)s (\(opts.providers.count) providers)")
    while true {
        await refreshOnce(opts)
        try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
    }
} else {
    let ok = await refreshOnce(opts)
    exit(ok ? 0 : 1)
}
