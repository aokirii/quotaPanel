import Foundation

/// Droid (Factory AI) usage/quota via the API-key path: resolve a
/// `FACTORY_API_KEY` (env or `~/.factory/.env`) and read the billing/usage
/// endpoints the web app uses. Token-rate-limit accounts report per-window
/// percentages; legacy accounts report a used ratio.
enum DroidProvider {
    private static let limitsURL = URL(string: "https://api.factory.ai/api/billing/limits")!
    private static let authURL = URL(string: "https://app.factory.ai/api/app/auth/me")!
    private static let usageURL = URL(string: "https://app.factory.ai/api/organization/subscription/usage?useCache=true")!

    static func fetch() async -> ProviderSnapshot {
        guard let key = loadAPIKey() else {
            return snapshot(.authProblem("No Factory API key — set FACTORY_API_KEY or add it to ~/.factory/.env"))
        }
        if let rateLimited = await fetchBillingLimits(key: key) {
            return rateLimited
        }
        return await fetchLegacyUsage(key: key)
    }

    // MARK: - Credentials

    /// FACTORY_API_KEY from the environment, else parsed from ~/.factory/.env
    static func loadAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["FACTORY_API_KEY"], !env.isEmpty {
            return env
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".factory/.env")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard line.hasPrefix("FACTORY_API_KEY") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func request(_ url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://app.factory.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://app.factory.ai/", forHTTPHeaderField: "Referer")
        request.setValue("web-app", forHTTPHeaderField: "x-factory-client")
        return request
    }

    // MARK: - Token-rate-limit accounts

    private static func fetchBillingLimits(key: String) async -> ProviderSnapshot? {
        guard let (data, response) = try? await URLSession.shared.data(for: request(limitsURL, key: key)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["usesTokenRateLimitsBilling"] as? Bool == true,
              let limits = json["limits"] as? [String: Any],
              let standard = limits["standard"] as? [String: Any]
        else { return nil }

        let windows: [RateWindow] = [
            ("fiveHour", "Session (5h)"),
            ("weekly", "Weekly"),
            ("monthly", "Monthly"),
        ].compactMap { spec in
            guard let pool = standard[spec.0] as? [String: Any] else { return nil }
            let used = (pool["usedPercent"] as? Double) ?? 0
            return RateWindow(label: spec.1, percent: max(0, min(100, used)), resetsAt: resetAt(pool))
        }
        guard !windows.isEmpty else { return nil }
        return ProviderSnapshot(provider: .droid, status: .ok, windows: windows, planName: "Factory", updatedAt: Date())
    }

    private static func resetAt(_ window: [String: Any]) -> Date? {
        if let seconds = window["secondsRemaining"] as? Double, seconds > 0 {
            return Date(timeIntervalSinceNow: seconds)
        }
        if let end = flexibleDate(window["windowEnd"]), end > Date() {
            return end
        }
        return nil
    }

    // MARK: - Legacy token-usage accounts

    private static func fetchLegacyUsage(key: String) async -> ProviderSnapshot {
        let plan = await fetchPlan(key: key)

        guard let (data, response) = try? await URLSession.shared.data(for: request(usageURL, key: key)) else {
            return snapshot(.error("Network error contacting Factory"), plan: plan)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200:
            break
        case 401, 403:
            return snapshot(.authProblem("Factory authorization failed (\(code)) — check your API key"))
        default:
            return snapshot(.error("Factory API error: HTTP \(code)"), plan: plan)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any]
        else { return snapshot(.error("Could not parse Factory usage"), plan: plan) }

        let reset = (usage["endDate"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        var windows: [RateWindow] = []
        if let standard = usage["standard"] as? [String: Any], let percent = usagePercent(standard) {
            windows.append(RateWindow(label: "Standard", percent: percent, resetsAt: reset))
        }
        if let premium = usage["premium"] as? [String: Any], let percent = usagePercent(premium) {
            windows.append(RateWindow(label: "Premium", percent: percent, resetsAt: reset))
        }
        guard !windows.isEmpty else {
            return ProviderSnapshot(provider: .droid, status: .ok, windows: [], planName: plan, updatedAt: Date())
        }
        return ProviderSnapshot(provider: .droid, status: .ok, windows: windows, planName: plan, updatedAt: Date())
    }

    private static func fetchPlan(key: String) async -> String? {
        guard let (data, response) = try? await URLSession.shared.data(for: request(authURL, key: key)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let org = json["organization"] as? [String: Any]
        else { return nil }

        var parts: [String] = []
        if let sub = org["subscription"] as? [String: Any] {
            if let tier = sub["factoryTier"] as? String, !tier.isEmpty {
                parts.append("Factory \(tier.prefix(1).uppercased() + tier.dropFirst())")
            }
            if let orb = sub["orbSubscription"] as? [String: Any],
               let plan = (orb["plan"] as? [String: Any])?["name"] as? String,
               !plan.isEmpty, !plan.lowercased().contains("factory") {
                parts.append(plan)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Prefer usedRatio (0…1); fall back to userTokens / totalAllowance
    private static func usagePercent(_ pool: [String: Any]) -> Double? {
        if let ratio = pool["usedRatio"] as? Double {
            return max(0, min(100, ratio * 100))
        }
        let used = (pool["userTokens"] as? Double) ?? (pool["userTokens"] as? NSNumber)?.doubleValue
        let allowance = (pool["totalAllowance"] as? Double) ?? (pool["totalAllowance"] as? NSNumber)?.doubleValue
        guard let used, let allowance, allowance > 0 else { return nil }
        return max(0, min(100, used / allowance * 100))
    }

    private static func flexibleDate(_ value: Any?) -> Date? {
        if let number = (value as? NSNumber)?.doubleValue, number > 0 {
            return Date(timeIntervalSince1970: number > 1_000_000_000_000 ? number / 1000 : number)
        }
        if let string = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: string) { return date }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: string)
        }
        return nil
    }

    private static func snapshot(_ status: SnapshotStatus, plan: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(provider: .droid, status: status, windows: [], planName: plan, updatedAt: Date())
    }
}
