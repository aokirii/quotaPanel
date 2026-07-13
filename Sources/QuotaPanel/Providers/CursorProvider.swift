import Foundation

/// Cursor usage/quota: the Cursor app stores a session JWT in its SQLite state
/// DB. We read it (read-only), synthesize the WorkOS session cookie the web
/// dashboard uses, and call `cursor.com/api/usage-summary`.
enum CursorProvider {
    private static let usageURL = URL(string: "https://cursor.com/api/usage-summary")!

    static func fetch() async -> ProviderSnapshot {
        guard let token = await Task.detached(priority: .utility, operation: { readAccessToken() }).value else {
            return snapshot(.authProblem("Not signed in to Cursor — sign in from the Cursor app"))
        }
        guard let userID = jwtSubject(token) else {
            return snapshot(.error("Could not read the Cursor session token"))
        }

        // The dashboard authenticates with a cookie, not a bearer header:
        // WorkosCursorSessionToken=<userID>::<JWT>  (":: " url-encoded)
        let cookie = "WorkosCursorSessionToken=\(userID)%3A%3A\(token)"
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 30
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaPanel", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                return parse(data: data)
            case 401, 403:
                return snapshot(.authProblem("Cursor session expired — sign in again from the Cursor app"))
            default:
                return snapshot(.error("Cursor API error: HTTP \(code)"))
            }
        } catch {
            return snapshot(.error("Network error: \(error.localizedDescription)"))
        }
    }

    /// Reads `cursorAuth/accessToken` from Cursor's state DB via the sqlite3 CLI
    /// opened immutable, so we never contend with Cursor's own writes.
    static func readAccessToken() -> String? {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        let sql = "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken' LIMIT 1;"
        guard let out = run("/usr/bin/sqlite3", ["file:\(db.path)?immutable=1", sql]) else { return nil }
        let token = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// userID = last "|"-separated segment of the JWT `sub` claim
    private static func jwtSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String
        else { return nil }
        return sub.split(separator: "|").last.map(String.init) ?? sub
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Response parsing

    static func parse(data: Data) -> ProviderSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return snapshot(.error("Could not parse Cursor response"))
        }

        let plan = (json["membershipType"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let reset = flexibleDate(json["billingCycleEnd"])

        // Overall plan usage lives under individualUsage.plan.totalPercentUsed
        var percent: Double?
        if let individual = json["individualUsage"] as? [String: Any],
           let planUsage = individual["plan"] as? [String: Any] {
            percent = (planUsage["totalPercentUsed"] as? Double)
                ?? (planUsage["totalPercentUsed"] as? NSNumber)?.doubleValue
        }
        if percent == nil {
            percent = (json["totalPercentUsed"] as? Double)
                ?? (json["totalPercentUsed"] as? NSNumber)?.doubleValue
        }

        guard let used = percent else {
            // Signed in but no usage meter (e.g. free tier) — show plan only
            return ProviderSnapshot(provider: .cursor, status: .ok, windows: [], planName: plan, updatedAt: Date())
        }
        let window = RateWindow(label: "Usage", percent: used, resetsAt: reset)
        return ProviderSnapshot(provider: .cursor, status: .ok, windows: [window], planName: plan, updatedAt: Date())
    }

    /// billingCycleEnd may be ISO-8601, epoch seconds, or epoch milliseconds
    private static func flexibleDate(_ value: Any?) -> Date? {
        if let string = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: string) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: string) { return date }
            if let number = Double(string) { return epochDate(number) }
            return nil
        }
        if let number = (value as? NSNumber)?.doubleValue { return epochDate(number) }
        return nil
    }

    private static func epochDate(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        // Values past ~1e12 are milliseconds
        return Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
    }

    private static func snapshot(_ status: SnapshotStatus, plan: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(provider: .cursor, status: status, windows: [], planName: plan, updatedAt: Date())
    }
}
