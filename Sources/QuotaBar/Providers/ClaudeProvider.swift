import CryptoKit
import Foundation

/// Claude subscription limits, using the OAuth logins Claude Code already keeps on this Mac.
/// Tokens are read but never refreshed here: rotating one would sign that profile out.
struct ClaudeProvider {
    let account: Account

    /// The shell command that opens this profile, by the ~/.claudeX → `claudeX` convention.
    private var command: String {
        account.configDir.map { String(($0 as NSString).lastPathComponent.dropFirst()) } ?? "claude"
    }

    func fetch() async throws -> ProviderSnapshot {
        let creds = try Self.credentials(configDir: account.configDir, command: command)
        if let exp = creds.expiresAt, exp < .now {
            throw ProviderError("Login idle since \(exp.formatted(.relative(presentation: .named))) — run `\(command)` once to refresh it")
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let obj = try J.object(try await HTTP.get(req))

        var windows = Self.limitsList(obj)
        if windows.isEmpty { windows = Self.legacyWindows(obj) }
        windows += Self.creditWindows(obj)

        var note: String?
        if let extra = obj["extra_usage"] as? [String: Any], (extra["is_enabled"] as? Bool) == true,
           let used = J.num(extra["used_credits"]), let limit = J.num(extra["monthly_limit"]), limit > 0 {
            note = "Extra usage: \(Fmt.money(used / 100)) of \(Fmt.money(limit / 100)) this month"
        }

        guard !windows.isEmpty else { throw ProviderError("No usage windows in response") }
        return ProviderSnapshot(account: account, plan: creds.plan, windows: windows, note: note)
    }

    /// The current shape: a flat `limits` list with kind/group/percent/scope.
    private static func limitsList(_ obj: [String: Any]) -> [UsageWindow] {
        (obj["limits"] as? [[String: Any]] ?? []).compactMap { l in
            guard let used = J.num(l["percent"]) else { return nil }
            let kind = l["kind"] as? String ?? ""
            let group = l["group"] as? String ?? ""
            let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            if kind == "weekly_scoped", used == 0, (l["is_active"] as? Bool) != true { return nil }
            let label = switch kind {
            case "session": "Session · 5h"
            case "weekly_all": "Weekly · all models"
            case "weekly_scoped": "Weekly · \(model ?? "scoped")"
            default: kind.replacingOccurrences(of: "_", with: " ").capitalized
            }
            let duration: TimeInterval? = group == "session" ? 5 * 3600 : group == "weekly" ? 7 * 86400 : nil
            return UsageWindow(label: label, usedPercent: used, resetsAt: J.date(l["resets_at"]), duration: duration)
        }
    }

    private static func legacyWindows(_ obj: [String: Any]) -> [UsageWindow] {
        let week: TimeInterval = 7 * 86400
        let keys: [(String, String, TimeInterval)] = [
            ("five_hour", "Session · 5h", 5 * 3600), ("seven_day", "Weekly · all models", week),
            ("seven_day_opus", "Weekly · Opus", week), ("seven_day_sonnet", "Weekly · Sonnet", week),
        ]
        return keys.compactMap { key, label, duration -> UsageWindow? in
                guard let w = obj[key] as? [String: Any], let used = J.num(w["utilization"]) else { return nil }
                return UsageWindow(label: label, usedPercent: used, resetsAt: J.date(w["resets_at"]), duration: duration)
            }
    }

    /// Any top-level entry with a dollar limit (the response uses codenames for these).
    private static func creditWindows(_ obj: [String: Any]) -> [UsageWindow] {
        obj.values.compactMap { $0 as? [String: Any] }.compactMap { w in
            guard let limit = J.num(w["limit_dollars"]), limit > 0 else { return nil }
            let used = J.num(w["used_dollars"]) ?? 0
            return UsageWindow(label: "Usage credit", usedPercent: J.num(w["utilization"]) ?? used / limit * 100,
                               resetsAt: J.date(w["resets_at"]), duration: nil,
                               creditText: "\(Fmt.money(used)) of \(Fmt.money(limit))")
        }
        .sorted { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
    }

    // MARK: Credentials & discovery

    private struct Credentials { let token: String; let expiresAt: Date?; let plan: String? }

    /// Claude Code names the Keychain item after the config dir: a plain name for the
    /// default, and "-<first 8 hex of sha256(path)>" for any CLAUDE_CONFIG_DIR.
    static func keychainService(configDir: String?) -> String? {
        let base = "Claude Code-credentials"
        guard let dir = configDir else { return base }
        let hash = SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        let hashed = "\(base)-\(hash)"
        if Shell.run("/usr/bin/security", ["find-generic-password", "-s", hashed]) != nil { return hashed }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return dir == "\(home)/.claude" ? base : nil
    }

    private static func credentials(configDir: String?, command: String) throws -> Credentials {
        var raw = keychainService(configDir: configDir).flatMap { Shell.run("/usr/bin/security", ["find-generic-password", "-s", $0, "-w"]) }
        if raw == nil {
            let dir = configDir ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude").path
            raw = try? String(contentsOfFile: "\(dir)/.credentials.json", encoding: .utf8)
        }
        guard let raw, let root = try? J.object(Data(raw.utf8)),
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw ProviderError("Not signed in — run `\(command)` and log in")
        }
        return Credentials(token: token, expiresAt: J.date(oauth["expiresAt"]), plan: planName(oauth))
    }

    private static func planName(_ oauth: [String: Any]) -> String? {
        // The tier names the usage multiplier, not the plan: a Team premium seat also has a
        // "max_5x" tier. Name the plan from the subscription and add the multiplier.
        let tier = (oauth["rateLimitTier"] as? String ?? "").lowercased()
        let sub = (oauth["subscriptionType"] as? String ?? "").lowercased()
        let multiplier = tier.contains("20x") ? "20×" : tier.contains("5x") ? "5×" : nil
        switch sub {
        case "max": return "Max \(multiplier ?? "")".trimmingCharacters(in: .whitespaces)
        case "": return multiplier.map { "Max \($0)" }
        default: return [sub.capitalized, multiplier].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Every `~/.claude*` directory that has a Claude Code login. Labels come from the
    /// `claude-title-prefix "Label: "` wrappers in ~/.zshrc when present.
    static func discover() -> [Account] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let labels = zshrcLabels(home: home)
        let dirs = ((try? fm.contentsOfDirectory(atPath: home)) ?? [])
            .filter { $0.hasPrefix(".claude") && !$0.contains(".json") }
            .map { "\(home)/\($0)" }
            .filter { var isDir: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue }
            .filter { keychainService(configDir: $0) != nil || fm.fileExists(atPath: "\($0)/.credentials.json") }
            .sorted { a, b in a.hasSuffix("/.claude") || (!b.hasSuffix("/.claude") && a < b) }

        return dirs.map { dir in
            let name = (dir as NSString).lastPathComponent
            let fallback = name == ".claude" ? "Main" : String(name.dropFirst(".claude".count)).trimmingCharacters(in: CharacterSet(charactersIn: "-_")).uppercased()
            return Account(id: "claude:\(name)", kind: .claude, label: labels[dir] ?? fallback,
                           detail: email(configDir: dir, home: home), configDir: dir)
        }
    }

    private static func zshrcLabels(home: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: "\(home)/.zshrc", encoding: .utf8),
              let re = try? NSRegularExpression(pattern: #"CLAUDE_CONFIG_DIR=(\S+)\s+claude-title-prefix\s+"([^":]+)"#) else { return [:] }
        var out: [String: String] = [:]
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let d = Range(m.range(at: 1), in: text), let l = Range(m.range(at: 2), in: text) else { continue }
            let dir = text[d].replacingOccurrences(of: "~", with: home).replacingOccurrences(of: "$HOME", with: home)
            out[dir] = text[l].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    private static func email(configDir: String, home: String) -> String? {
        for path in ["\(configDir)/.claude.json", "\(home)/.claude.json"] {
            if let data = FileManager.default.contents(atPath: path), let obj = try? J.object(data),
               let email = (obj["oauthAccount"] as? [String: Any])?["emailAddress"] as? String {
                return email
            }
            if !configDir.hasSuffix("/.claude") { break }
        }
        return nil
    }
}
