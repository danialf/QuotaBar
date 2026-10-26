import SwiftUI

enum ProviderID: String, CaseIterable, Identifiable, Codable {
    case claude, codex, zai

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "ChatGPT · Codex"
        case .zai: "GLM · Z.ai"
        }
    }

    var shortName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .zai: "GLM"
        }
    }

    /// Single letter shown in the menu bar.
    var glyph: String {
        switch self {
        case .claude: "C"
        case .codex: "G"
        case .zai: "Z"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "circle.hexagongrid.fill"
        case .zai: "z.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.06, green: 0.64, blue: 0.50)
        case .zai: Color(red: 0.36, green: 0.42, blue: 0.98)
        }
    }
}

/// One signed-in subscription. Claude can have several (one per CLAUDE_CONFIG_DIR).
struct Account: Identifiable, Hashable, Codable {
    let id: String
    let kind: ProviderID
    let label: String
    var detail: String?
    var configDir: String?

    var title: String { kind == .claude ? "Claude · \(label)" : kind.name }
    var shortName: String { kind == .claude ? "Claude \(label)" : kind.shortName }

    /// Up to two characters for the menu bar: C1, C2, CP, CG, G, Z.
    var glyph: String {
        guard kind == .claude else { return kind.glyph }
        if let digit = label.last(where: \.isNumber) { return "C\(digit)" }
        return "C" + (label.first.map { String($0).uppercased() } ?? "")
    }

    static let codex = Account(id: "codex", kind: .codex, label: "ChatGPT")
    static let zai = Account(id: "zai", kind: .zai, label: "GLM")
}

/// One rate-limit window (5-hour session, weekly, monthly…).
struct UsageWindow: Identifiable, Hashable, Codable {
    var id: String { label }
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    let duration: TimeInterval?
    /// Dollar-denominated allowance (e.g. Claude Code credit). Shown, but never treated as a cap.
    var creditText: String? = nil
    /// A side allowance (e.g. GLM's monthly web-search calls) that doesn't stop the main work
    /// when spent: shown, but never chosen as the session/long window or a cap.
    var auxiliary = false
    /// Extra context under the bar, e.g. "45 of 4000 calls".
    var detail: String? = nil

    var isCredit: Bool { creditText != nil }
    var remaining: Double { max(0, 100 - usedPercent) }

    /// How far through the window we are, 0…1. Needs both reset time and length.
    func elapsedFraction(now: Date = .now) -> Double? {
        guard let resetsAt, let duration, duration > 0 else { return nil }
        let start = resetsAt.addingTimeInterval(-duration)
        return min(1, max(0, now.timeIntervalSince(start) / duration))
    }

    func timeToReset(now: Date = .now) -> TimeInterval? {
        resetsAt.map { max(0, $0.timeIntervalSince(now)) }
    }
}

struct ProviderSnapshot: Identifiable, Codable {
    var id: String { account.id }
    var account: Account
    var provider: ProviderID { account.kind }
    var plan: String?
    var windows: [UsageWindow]
    var note: String?
    var updatedAt: Date = .now
    /// Set when this is a saved reading shown because the live fetch failed.
    var staleReason: String?
    /// Limit resets the plan hands out on top of its windows (Codex's reset credits).
    var resets: ResetCredits?

    struct ResetCredits: Codable, Hashable {
        /// Resets held in total.
        let available: Int
        /// Of those, how many apply to a limit you could reset right now.
        let usableNow: Int
    }

    /// A saved reading brought forward to `now`: any window whose reset has passed since
    /// is treated as fresh, since nothing could have been used without a live login.
    func rolledForward(now: Date = .now) -> ProviderSnapshot {
        var copy = self
        copy.windows = windows.map { w in
            guard let reset = w.resetsAt, reset < now else { return w }
            var next: Date? = nil
            if let d = w.duration, d > 0 {
                var r = reset
                while r < now { r = r.addingTimeInterval(d) }
                next = r
            }
            return UsageWindow(label: w.label, usedPercent: 0, resetsAt: next, duration: w.duration,
                               creditText: w.isCredit ? nil : w.creditText, auxiliary: w.auxiliary, detail: w.detail)
        }
        return copy
    }

    var quotas: [UsageWindow] { windows.filter { !$0.isCredit && !$0.auxiliary } }
    var shortest: UsageWindow? { quotas.min { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) } }
    var longest: UsageWindow? { quotas.max { ($0.duration ?? 0) < ($1.duration ?? 0) } }
    /// The most-used window: the one that will stop you first.
    var bottleneck: UsageWindow? { quotas.max { $0.usedPercent < $1.usedPercent } }
}

enum ProviderState {
    case disabled
    case loading
    case ok(ProviderSnapshot)
    case failed(String)

    var snapshot: ProviderSnapshot? {
        if case .ok(let s) = self { return s }
        return nil
    }
}

enum APIVendor: String, CaseIterable, Identifiable, Codable {
    case anthropic, openai
    var id: String { rawValue }
    var name: String { self == .anthropic ? "Anthropic" : "OpenAI" }
    var provider: ProviderID { self == .anthropic ? .claude : .codex }
}

/// A pay-as-you-go API organisation (e.g. a key you paste into Cursor). Reading cost needs
/// that organisation's admin key, kept in the Keychain under `keychainKey`.
struct APIAccount: Identifiable, Hashable, Codable {
    var id = UUID().uuidString
    var name = ""
    var vendor = APIVendor.anthropic
    var budget: Double?
    /// Prepaid: balance as shown in the console on `creditAsOf`. Monthly: the allowance per period.
    var credit: Double?
    var creditAsOf: Date?
    var creditMode = CreditMode.prepaid
    /// Monthly allowance renews on this day of the month (1–28).
    var resetDay: Int?
    /// Prepaid credit that lapses on this date.
    var creditExpires: Date?

    enum CreditMode: String, Codable, CaseIterable, Identifiable {
        case prepaid, monthly
        var id: String { rawValue }
        var title: String { self == .prepaid ? "Prepaid balance" : "Monthly allowance" }
    }

    /// Start of the spend window the credit is measured against.
    func creditStart(now: Date = .now) -> Date? {
        guard let credit, credit > 0 else { return nil }
        switch creditMode {
        case .prepaid: return creditAsOf
        case .monthly: return Self.lastReset(day: resetDay ?? 1, now: now)
        }
    }

    /// When the credit next renews (monthly) or lapses (prepaid with an expiry).
    func creditResets(now: Date = .now) -> Date? {
        switch creditMode {
        case .prepaid: return creditExpires
        case .monthly:
            let last = Self.lastReset(day: resetDay ?? 1, now: now)
            return Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: last)
        }
    }

    static func lastReset(day: Int, now: Date) -> Date {
        let cal = Calendar(identifier: .gregorian)
        var c = cal.dateComponents([.year, .month], from: now)
        c.day = min(max(day, 1), 28)
        let thisMonth = cal.date(from: c)!
        return thisMonth <= now ? thisMonth : cal.date(byAdding: .month, value: -1, to: thisMonth)!
    }

    /// Display-only hint of the stored API key ("sk-ant-api03-R2D…igAA"); the key itself is in the Vault.
    var keyHint: String?

    /// The organisation admin key, readable without a prompt so spend can refresh in the background.
    var keychainKey: String { "api.\(id)" }
    /// The API key itself, sealed by the Secure Enclave; reading it needs Touch ID.
    var vaultName: String { "vault.api.\(id)" }

    init(id: String = UUID().uuidString, name: String = "", vendor: APIVendor = .anthropic, budget: Double? = nil,
         credit: Double? = nil, creditAsOf: Date? = nil, keyHint: String? = nil) {
        self.id = id; self.name = name; self.vendor = vendor; self.budget = budget
        self.credit = credit; self.creditAsOf = creditAsOf; self.keyHint = keyHint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        vendor = try c.decodeIfPresent(APIVendor.self, forKey: .vendor) ?? .anthropic
        budget = try c.decodeIfPresent(Double.self, forKey: .budget)
        credit = try c.decodeIfPresent(Double.self, forKey: .credit)
        creditAsOf = try c.decodeIfPresent(Date.self, forKey: .creditAsOf)
        creditMode = try c.decodeIfPresent(CreditMode.self, forKey: .creditMode) ?? .prepaid
        resetDay = try c.decodeIfPresent(Int.self, forKey: .resetDay)
        creditExpires = try c.decodeIfPresent(Date.self, forKey: .creditExpires)
        keyHint = try c.decodeIfPresent(String.self, forKey: .keyHint)
    }

    static let storeKey = "apiAccounts"

    static func load() -> [APIAccount] {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return [] }
        return (try? JSONDecoder().decode([APIAccount].self, from: data)) ?? []
    }

    static func save(_ accounts: [APIAccount]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: storeKey)
    }
}

struct SpendSnapshot: Identifiable {
    var id: String { account.id }
    let account: APIAccount
    let monthToDate: Double
    /// Spend since `account.creditStart()`, when a credit balance is tracked.
    let sinceCredit: Double?
    /// The stored API key as the admin API knows it, when it could be matched.
    var key: KeyUsage? = nil
    var keyError: String? = nil

    struct KeyUsage {
        let name: String
        let status: String
        let inputTokens: Double
        let outputTokens: Double
    }

    var budget: Double? { account.budget.flatMap { $0 > 0 ? $0 : nil } }

    var remainingCredit: Double? {
        guard let credit = account.credit, credit > 0 else { return nil }
        return credit - (sinceCredit ?? 0)
    }

    /// Linear projection to the end of the calendar month.
    func projected(now: Date = .now) -> Double {
        let cal = Calendar(identifier: .gregorian)
        guard let interval = cal.dateInterval(of: .month, for: now) else { return monthToDate }
        let fraction = now.timeIntervalSince(interval.start) / interval.duration
        return fraction > 0.02 ? monthToDate / fraction : monthToDate
    }
}

enum SpendState {
    case ok(SpendSnapshot)
    case failed(String)
}

struct ProviderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Formatting

enum Fmt {
    static func duration(_ t: TimeInterval) -> String {
        let minutes = Int(t / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h"
    }

    static func percent(_ p: Double) -> String { "\(Int(p.rounded()))%" }

    static func tokens(_ v: Double) -> String {
        switch v {
        case 1_000_000...: String(format: "%.1fM", v / 1_000_000)
        case 1_000...: String(format: "%.0fk", v / 1_000)
        default: String(Int(v))
        }
    }

    static func money(_ v: Double) -> String {
        v.formatted(.currency(code: "USD").precision(.fractionLength(v >= 100 ? 0 : 2)))
    }
}

/// Loose JSON helpers: the usage endpoints are undocumented and change shape.
enum J {
    static func num(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    static func date(_ any: Any?) -> Date? {
        if let n = num(any) {
            // Seconds or milliseconds since epoch.
            return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
        }
        guard let s = any as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return f.date(from: trimmed)
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("Unexpected response format")
        }
        return obj
    }
}

enum HTTP {
    static func get(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("QuotaBar/1.0", forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError("No HTTP response") }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw ProviderError("Not authorised (\(http.statusCode)) — sign in again")
        case 429: throw ProviderError("Rate limited by the provider — will retry")
        default:
            let body = String(data: data.prefix(160), encoding: .utf8) ?? ""
            throw ProviderError("HTTP \(http.statusCode) \(body)")
        }
    }
}

/// Last raw responses from the undocumented quota endpoints, for diagnosing parsing.
/// Only response bodies are written (usage numbers), never request headers or keys.
enum Diagnostics {
    static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "QuotaBar/diagnostics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func save(_ name: String, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: directory.appending(path: name), options: .atomic)
    }
}

extension ProviderSnapshot.ResetCredits {
    var text: String {
        let noun = available == 1 ? "limit reset" : "limit resets"
        return usableNow > 0 ? "\(available) \(noun) available — \(usableNow) usable now" : "\(available) \(noun) available"
    }
}
