import Foundation

/// SuperGrok credits, using the login xAI's `grok` CLI keeps in ~/.grok/auth.json.
/// The token is read but never refreshed; `grok` renews it (it lasts about a week).
struct GrokProvider {
    static var authFile: URL {
        if let home = ProcessInfo.processInfo.environment["GROK_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appending(path: "auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".grok/auth.json")
    }

    static var hasLogin: Bool { FileManager.default.fileExists(atPath: authFile.path) }

    func fetch() async throws -> ProviderSnapshot {
        let entry = try Self.credentials()
        guard let token = entry["key"] as? String else { throw ProviderError("Run `grok login` to track Grok") }
        if let exp = J.date(entry["expires_at"]), exp < .now {
            throw ProviderError("Grok login expired \(exp.formatted(.relative(presentation: .named))) — run `grok` once to refresh it")
        }
        var req = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        let obj = try J.object(try await HTTP.get(req))
        Diagnostics.save("grok-billing.json", obj)
        return try Self.parse(obj)
    }

    static func parse(_ obj: [String: Any], now: Date = .now) throws -> ProviderSnapshot {
        guard let config = obj["config"] as? [String: Any] else { throw ProviderError("Grok returned no billing data") }
        let period = config["currentPeriod"] as? [String: Any]
        let end = J.date(period?["end"]) ?? J.date(config["billingPeriodEnd"])
        let start = period?["end"] != nil ? J.date(period?["start"]) : J.date(config["billingPeriodStart"])
        let duration = start.flatMap { s in end.map { $0.timeIntervalSince(s) } }.flatMap { $0 > 0 ? $0 : nil }

        let cap = J.num((config["onDemandCap"] as? [String: Any])?["val"])
        let spent = J.num((config["onDemandUsed"] as? [String: Any])?["val"])
        var used = J.num(config["creditUsagePercent"]) ?? cap.flatMap { c in spent.flatMap { c > 0 ? $0 / c * 100 : nil } }
        var note: String?
        // Proto3 JSON drops a zero, so an active period with no percentage means nothing used yet.
        if used == nil, let start, let end, start <= now, now < end {
            used = 0
            note = "No usage reported yet this period"
        }
        guard let used else { throw ProviderError("Grok didn't report credit usage") }
        let label = duration.map { Fmt.windowLabel($0) == "Weekly" ? "Credits · weekly" : "Credits · \(Fmt.windowLabel($0).lowercased())" } ?? "Credits"
        let window = UsageWindow(label: label, usedPercent: min(100, max(0, used)), resetsAt: end, duration: duration)
        let tier = (config["subscriptionTier"] ?? obj["subscriptionTier"]) as? String
        var snap = ProviderSnapshot(account: .grok, plan: tier.map(Self.planName), windows: [window])
        snap.note = note
        return snap
    }

    /// auth.json maps a scope URL to its login; prefer SuperGrok's OIDC scope over the legacy session.
    private static func credentials() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: authFile) else { throw ProviderError("Run `grok login` to track Grok") }
        let root = try J.object(data)
        let entries = root.compactMap { scope, value -> (String, [String: Any])? in
            guard let e = value as? [String: Any], (e["key"] as? String)?.isEmpty == false else { return nil }
            return (scope, e)
        }
        guard let pick = entries.first(where: { $0.0.hasPrefix("https://auth.x.ai::") }) ?? entries.first(where: { $0.0.contains("/sign-in") }) else {
            throw ProviderError("No Grok login in ~/.grok/auth.json — run `grok login`")
        }
        return pick.1
    }

    /// "SUBSCRIPTION_TIER_SUPER_GROK_HEAVY" → "SuperGrok Heavy".
    private static func planName(_ tier: String) -> String {
        let words = tier.replacingOccurrences(of: "SUBSCRIPTION_TIER_", with: "").split(separator: "_").map { $0.capitalized }
        return words.joined(separator: " ").replacingOccurrences(of: "Super Grok", with: "SuperGrok")
    }
}
