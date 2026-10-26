import Foundation

/// Kimi Code (Kimi For Coding) membership limits, read with a Kimi Code API key.
/// The endpoint has two shapes: older request counts, and newer ratio pools. Both are read.
struct KimiProvider {
    let apiKey: String?
    let international: Bool

    func fetch() async throws -> ProviderSnapshot {
        guard let apiKey else { throw ProviderError("Add your Kimi Code API key in Settings → Accounts") }
        let host = international ? "https://api.kimi.ai" : "https://api.kimi.com"
        var req = URLRequest(url: URL(string: "\(host)/coding/v1/usages")!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let obj = try J.object(try await HTTP.get(req))
        Diagnostics.save("kimi-usage.json", obj)
        return try Self.parse(obj)
    }

    static func parse(_ obj: [String: Any]) throws -> ProviderSnapshot {
        var windows = Self.ratioPools(obj["usages"] as? [String: Any] ?? [:])
        if windows.isEmpty { windows = Self.countWindows(obj) }
        guard !windows.isEmpty else { throw ProviderError("No Kimi Code quota on this key — check the key and region") }
        let level = ((obj["user"] as? [String: Any])?["membership"] as? [String: Any])?["level"] as? String
        return ProviderSnapshot(account: .kimi, plan: level.map(Self.planName),
                                windows: windows.sorted { ($0.duration ?? 0) < ($1.duration ?? 0) })
    }

    /// `limit_5h` / `limit_7d` / `limit_month_total`, each a used ratio and a reset time.
    private static func ratioPools(_ pools: [String: Any]) -> [UsageWindow] {
        let spans: [(String, TimeInterval)] = [("limit_5h", 5 * 3600), ("limit_7d", 7 * 86400), ("limit_month_total", 30 * 86400)]
        return spans.compactMap { key, duration in
            guard let pool = pools[key] as? [String: Any], let ratio = J.num(pool["used_ratio"]) else { return nil }
            // Documented as 0…1; tolerate a percentage in case it changes.
            let used = ratio <= 1 ? ratio * 100 : ratio
            return UsageWindow(label: Fmt.windowLabel(duration), usedPercent: min(100, used),
                               resetsAt: J.date(pool["reset_time"]), duration: duration)
        }
    }

    /// The weekly request allowance under `usage`, plus rate-limit windows under `limits`.
    private static func countWindows(_ obj: [String: Any]) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        if let usage = obj["usage"] as? [String: Any], let w = window(usage, duration: 7 * 86400) {
            windows.append(w)
        }
        for limit in obj["limits"] as? [[String: Any]] ?? [] {
            guard let detail = limit["detail"] as? [String: Any],
                  let duration = Self.duration(limit["window"] as? [String: Any]),
                  let w = window(detail, duration: duration) else { continue }
            windows.append(w)
        }
        return windows
    }

    private static func window(_ detail: [String: Any], duration: TimeInterval) -> UsageWindow? {
        guard let limit = J.num(detail["limit"]), limit > 0 else { return nil }
        let used = J.num(detail["used"]) ?? J.num(detail["remaining"]).map { limit - $0 } ?? 0
        return UsageWindow(label: Fmt.windowLabel(duration), usedPercent: min(100, max(0, used / limit * 100)),
                           resetsAt: J.date(detail["resetTime"] ?? detail["reset_time"]), duration: duration,
                           detail: "\(Int(used)) of \(Int(limit)) requests")
    }

    private static func duration(_ window: [String: Any]?) -> TimeInterval? {
        guard let window, let n = J.num(window["duration"]) else { return nil }
        switch window["timeUnit"] as? String {
        case "TIME_UNIT_SECOND": return n
        case "TIME_UNIT_MINUTE": return n * 60
        case "TIME_UNIT_HOUR": return n * 3600
        case "TIME_UNIT_DAY": return n * 86400
        default: return nil
        }
    }

    /// "LEVEL_ALLEGRETTO" → "Allegretto".
    private static func planName(_ level: String) -> String {
        level.replacingOccurrences(of: "LEVEL_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }
}
