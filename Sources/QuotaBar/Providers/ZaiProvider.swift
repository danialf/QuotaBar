import Foundation

/// GLM Coding Plan quotas from Z.ai (or BigModel for the China region).
struct ZaiProvider {
    let apiKey: String?
    let china: Bool

    func fetch() async throws -> ProviderSnapshot {
        guard let apiKey else { throw ProviderError("Add your Z.ai API key in Settings → Accounts") }
        let host = china ? "https://open.bigmodel.cn" : "https://api.z.ai"
        // The monitor endpoint has accepted both forms over time; try Bearer, then the raw key.
        var obj: [String: Any] = [:]
        var lastError: Error = ProviderError("Z.ai rejected the request")
        for auth in ["Bearer \(apiKey)", apiKey] {
            var req = URLRequest(url: URL(string: "\(host)/api/monitor/usage/quota/limit")!)
            req.setValue(auth, forHTTPHeaderField: "Authorization")
            do {
                let o = try J.object(try await HTTP.get(req))
                if let success = o["success"] as? Bool, !success {
                    lastError = ProviderError("Z.ai: \(o["msg"] as? String ?? "rejected") — check the key and region in Settings")
                    continue
                }
                obj = o
                Diagnostics.save("zai-quota.json", o)
                break
            } catch {
                lastError = error
            }
        }
        if obj.isEmpty { throw lastError }
        let data = obj["data"] as? [String: Any] ?? [:]
        let limits = data["limits"] as? [[String: Any]] ?? []

        let windows: [UsageWindow] = limits.compactMap { l in
            let used = J.num(l["percentage"]) ?? {
                guard let cur = J.num(l["currentValue"]), let cap = J.num(l["usage"]), cap > 0 else { return nil }
                return cur / cap * 100
            }()
            guard let used else { return nil }
            let duration = Self.duration(unit: J.num(l["unit"]), number: J.num(l["number"]))
            // TOKENS_LIMIT windows are the coding quota; TIME_LIMIT counts web-search/reader
            // tool calls, a side allowance that doesn't block coding when it runs out.
            let tools = (l["type"] as? String) == "TIME_LIMIT"
            let span = duration.map { $0 >= 27 * 86400 ? "monthly" : $0 >= 6 * 86400 ? "weekly" : Fmt.duration($0) } ?? ""
            var label = tools ? "Web search & tools" : "Tokens"
            if !span.isEmpty { label += " · \(span)" }
            let calls = tools ? J.num(l["currentValue"]).flatMap { cur in J.num(l["usage"]).map { "\(Int(cur)) of \(Int($0)) calls" } } : nil
            return UsageWindow(label: label, usedPercent: used, resetsAt: J.date(l["nextResetTime"]), duration: duration,
                               creditText: nil, auxiliary: tools, detail: calls)
        }
        guard !windows.isEmpty else { throw ProviderError("No coding-plan quota on this key") }
        let plan = (data["level"] as? String)?.capitalized
        return ProviderSnapshot(account: .zai, plan: plan, windows: windows.sorted { ($0.auxiliary ? 1 : 0, $0.duration ?? 0) < ($1.auxiliary ? 1 : 0, $1.duration ?? 0) })
    }

    /// Z.ai encodes window length as a unit code plus a count.
    private static func duration(unit: Double?, number: Double?) -> TimeInterval? {
        guard let unit, let n = number else { return nil }
        switch Int(unit) {
        case 1: return n * 60
        case 3: return n * 3600
        case 4: return n * 86400
        case 5: return n * 30 * 86400
        case 6: return n * 7 * 86400
        default: return nil
        }
    }
}
