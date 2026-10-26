import Foundation

/// MiniMax Coding / Token Plan limits, read with the plan's API key (`sk-cp-…`).
struct MiniMaxProvider {
    let apiKey: String?
    let china: Bool

    func fetch() async throws -> ProviderSnapshot {
        guard let apiKey else { throw ProviderError("Add your MiniMax Coding Plan key in Settings → Accounts") }
        let host = china ? "https://api.minimaxi.com" : "https://api.minimax.io"
        // MiniMax renamed the route to token_plan; older keys still answer only on coding_plan.
        var lastError: Error = ProviderError("MiniMax rejected the request")
        for path in ["/v1/token_plan/remains", "/v1/api/openplatform/coding_plan/remains"] {
            var req = URLRequest(url: URL(string: host + path)!)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            do {
                let obj = try J.object(try await HTTP.get(req))
                Diagnostics.save("minimax-remains.json", obj)
                return try Self.parse(obj)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func parse(_ obj: [String: Any], now: Date = .now) throws -> ProviderSnapshot {
        let data = obj["data"] as? [String: Any] ?? obj
        let status = (data["base_resp"] ?? obj["base_resp"]) as? [String: Any]
        if let code = J.num(status?["status_code"]), code != 0 {
            throw ProviderError("MiniMax: \(status?["status_msg"] as? String ?? "error \(Int(code))") — check the key and region")
        }
        // Speech, image and video models have their own allowances; only text generation is the coding quota.
        let models = (data["model_remains"] as? [[String: Any]] ?? []).filter { isText($0["model_name"] as? String) }

        var windows: [String: UsageWindow] = [:]
        for m in models {
            let parts = [window(m, prefix: "current_interval", start: "start_time", end: "end_time", remains: "remains_time", now: now),
                         window(m, prefix: "current_weekly", start: "weekly_start_time", end: "weekly_end_time", remains: "weekly_remains_time", now: now)]
            // Several text models can share a pool; keep the most-used reading of each window.
            for w in parts.compactMap({ $0 }) where w.usedPercent >= (windows[w.label]?.usedPercent ?? -1) {
                windows[w.label] = w
            }
        }
        guard !windows.isEmpty else { throw ProviderError("No coding-plan quota on this MiniMax key") }
        let plan = ["current_subscribe_title", "plan_name", "combo_title", "current_plan_title"]
            .compactMap { (data[$0] as? String)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return ProviderSnapshot(account: .minimax, plan: plan,
                                windows: windows.values.sorted { ($0.duration ?? 0) < ($1.duration ?? 0) })
    }

    private static func isText(_ name: String?) -> Bool {
        guard let lower = name?.lowercased() else { return false }
        return lower == "general" || lower.contains("minimax-m") || lower.hasPrefix("m2.")
    }

    /// Note `…_usage_count` is what is *left*, not what was used.
    private static func window(_ m: [String: Any], prefix: String, start: String, end: String, remains: String, now: Date) -> UsageWindow? {
        let total = J.num(m["\(prefix)_total_count"]) ?? 0
        let left = J.num(m["\(prefix)_usage_count"]) ?? 0
        let used: Double
        if let leftPercent = J.num(m["\(prefix)_remaining_percent"]) {
            // Status 3 with nothing allotted marks a window the plan doesn't include.
            if J.num(m["\(prefix)_status"]) == 3, total == 0 { return nil }
            used = 100 - leftPercent
        } else {
            guard total > 0 else { return nil }
            used = (total - left) / total * 100
        }
        let startDate = J.date(m[start]), endDate = J.date(m[end])
        let duration = startDate.flatMap { s in endDate.map { $0.timeIntervalSince(s) } }.flatMap { $0 > 0 ? $0 : nil }
        // remains_time is milliseconds (sometimes seconds) until reset.
        let reset = endDate ?? J.num(m[remains]).map { now.addingTimeInterval($0 > 1_000_000 ? $0 / 1000 : $0) }
        let label = prefix == "current_weekly" ? "Weekly" : Fmt.windowLabel(duration)
        return UsageWindow(label: label, usedPercent: min(100, max(0, used)), resetsAt: reset, duration: duration,
                           detail: total > 0 ? "\(Int(total - left)) of \(Int(total)) prompts" : nil)
    }
}
