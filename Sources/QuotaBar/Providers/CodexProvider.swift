import Foundation

/// ChatGPT plan limits as seen by Codex. Live data comes from the same endpoint Codex's
/// `/status` uses; when that fails, the latest rate-limit event in the session logs is used.
struct CodexProvider {
    private var codexHome: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"] { return URL(fileURLWithPath: env) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    }

    func fetch() async throws -> ProviderSnapshot {
        do {
            return try await fetchLive()
        } catch {
            if var snap = try? fromSessionLogs() {
                snap.note = "From last Codex session (\(snap.updatedAt.formatted(.relative(presentation: .named))))"
                return snap
            }
            throw error
        }
    }

    private func fetchLive() async throws -> ProviderSnapshot {
        let authURL = codexHome.appending(path: "auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? J.object(data),
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else {
            throw ProviderError("Codex isn't signed in with ChatGPT — run `codex login`")
        }

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let account = tokens["account_id"] as? String {
            req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let obj = try J.object(try await HTTP.get(req))
        let limits = obj["rate_limit"] as? [String: Any] ?? [:]

        let windows = [limits["primary_window"], limits["secondary_window"]].compactMap { liveWindow($0 as? [String: Any]) }
        guard !windows.isEmpty else { throw ProviderError("No usage windows in response") }

        var note: String?
        if let credits = obj["credits"] as? [String: Any], (credits["has_credits"] as? Bool) == true,
           let balance = J.num(credits["balance"]) {
            note = "Credits balance: \(Int(balance))"
        }
        var account = Account.codex
        account.detail = obj["email"] as? String
        Diagnostics.save("codex-usage.json", obj.filter { !["email", "user_id", "account_id"].contains($0.key) })
        var snap = ProviderSnapshot(account: account, plan: Self.planName(obj["plan_type"] as? String), windows: windows, note: note)
        if let r = obj["rate_limit_reset_credits"] as? [String: Any], let available = J.num(r["available_count"]) {
            snap.resets = .init(available: Int(available), usableNow: Int(J.num(r["applicable_available_count"]) ?? 0))
        }
        return snap
    }

    private func liveWindow(_ w: [String: Any]?) -> UsageWindow? {
        guard let w, let used = J.num(w["used_percent"]) else { return nil }
        let seconds = J.num(w["limit_window_seconds"])
        let reset = J.date(w["reset_at"]) ?? J.num(w["reset_after_seconds"]).map { Date().addingTimeInterval($0) }
        return UsageWindow(label: Fmt.windowLabel(seconds), usedPercent: used, resetsAt: reset, duration: seconds)
    }

    private func fromSessionLogs() throws -> ProviderSnapshot {
        let root = codexHome.appending(path: "sessions")
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }) ?? []
        let newest = files.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        guard let newest, let text = try? String(contentsOf: newest, encoding: .utf8) else {
            throw ProviderError("No Codex sessions found")
        }

        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let obj = try? J.object(Data(line.utf8)),
                  let payload = obj["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            let stamp = J.date(obj["timestamp"]) ?? .now
            let windows = [limits["primary"], limits["secondary"]].compactMap { any -> UsageWindow? in
                guard let w = any as? [String: Any], let used = J.num(w["used_percent"]) else { return nil }
                let seconds = J.num(w["window_minutes"]).map { $0 * 60 }
                let reset = J.date(w["resets_at"]) ?? J.num(w["resets_in_seconds"]).map { stamp.addingTimeInterval($0) }
                return UsageWindow(label: Fmt.windowLabel(seconds), usedPercent: used, resetsAt: reset, duration: seconds)
            }
            if !windows.isEmpty {
                return ProviderSnapshot(account: .codex, plan: nil, windows: windows, updatedAt: stamp)
            }
        }
        throw ProviderError("No rate-limit events in Codex logs")
    }

    private static func planName(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case nil: nil
        case "prolite": "Pro Lite"
        case let s?: s.capitalized
        }
    }
}
