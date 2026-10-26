import Foundation
import SQLite3

/// Cursor plan usage, using the login the Cursor app keeps in its state database.
/// The database is opened read-only and the token is never refreshed here; Cursor does that itself.
struct CursorProvider {
    static let database = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")

    static var hasLogin: Bool { FileManager.default.fileExists(atPath: database.path) }

    func fetch() async throws -> ProviderSnapshot {
        guard let token = Self.accessToken() else { throw ProviderError("Sign in to the Cursor app to track Cursor") }
        let claims = Self.claims(token)
        if let exp = J.num(claims["exp"]), Date(timeIntervalSince1970: exp) < .now {
            throw ProviderError("Cursor login expired — open Cursor once to refresh it")
        }
        // The JWT subject is "provider|user_…"; cursor.com wants "<user id>::<token>" as its session cookie.
        guard let user = (claims["sub"] as? String)?.split(separator: "|").last else {
            throw ProviderError("Cursor login has no user ID — sign in to Cursor again")
        }
        var req = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        req.setValue("WorkosCursorSessionToken=\(user)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
        req.httpShouldHandleCookies = false
        let obj = try J.object(try await HTTP.get(req))
        Diagnostics.save("cursor-usage.json", obj)
        return try Self.parse(obj)
    }

    static func parse(_ obj: [String: Any]) throws -> ProviderSnapshot {
        let start = J.date(obj["billingCycleStart"]), end = J.date(obj["billingCycleEnd"])
        let duration = start.flatMap { s in end.map { $0.timeIntervalSince(s) } }
        let individual = obj["individualUsage"] as? [String: Any] ?? [:]
        let plan = individual["plan"] as? [String: Any]
        // Team and enterprise members get a personal cap instead of a plan block.
        let cap = plan ?? individual["overall"] as? [String: Any]
            ?? (obj["teamUsage"] as? [String: Any])?["pooled"] as? [String: Any]

        var windows: [UsageWindow] = []
        let usedCents = J.num(cap?["used"]), limitCents = J.num(cap?["limit"])
        // Percent fields are already percentages, even below 1 (0.36 means 0.36%).
        if let used = J.num(plan?["totalPercentUsed"]) ?? usedCents.flatMap({ u in limitCents.flatMap { $0 > 0 ? u / $0 * 100 : nil } }) {
            let money = usedCents.flatMap { u in limitCents.map { "\(Fmt.money(u / 100)) of \(Fmt.money($0 / 100))" } }
            windows.append(UsageWindow(label: "Included · monthly", usedPercent: min(100, used), resetsAt: end, duration: duration, detail: money))
        }
        // The split between Auto and named models: shown, but the included total is what runs out.
        for (key, label) in [("autoPercentUsed", "Auto"), ("apiPercentUsed", "Named models")] {
            if let p = J.num(plan?[key]) {
                windows.append(UsageWindow(label: label, usedPercent: min(100, p), resetsAt: end, duration: duration, auxiliary: true))
            }
        }
        if let onDemand = individual["onDemand"] as? [String: Any], (onDemand["enabled"] as? Bool) == true,
           let used = J.num(onDemand["used"]) {
            let limit = J.num(onDemand["limit"])
            let text = limit.map { "\(Fmt.money(used / 100)) of \(Fmt.money($0 / 100)) on-demand" } ?? "\(Fmt.money(used / 100)) on-demand"
            windows.append(UsageWindow(label: "On-demand", usedPercent: limit.map { $0 > 0 ? min(100, used / $0 * 100) : 0 } ?? 0,
                                       resetsAt: end, duration: duration, creditText: text))
        }
        guard !windows.isEmpty else { throw ProviderError("Cursor returned no plan usage") }
        let membership = (obj["membershipType"] as? String).map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
        return ProviderSnapshot(account: .cursor, plan: membership, windows: windows)
    }

    private static func accessToken() -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let value: String?
        if sqlite3_column_type(stmt, 0) == SQLITE_TEXT, let text = sqlite3_column_text(stmt, 0) {
            value = String(cString: text)
        } else if let blob = sqlite3_column_blob(stmt, 0) {
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
            // Older builds stored it as UTF-16LE.
            value = data.contains(0) ? String(data: data, encoding: .utf16LittleEndian) : String(data: data, encoding: .utf8)
        } else {
            value = nil
        }
        return value?.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\""))).nilIfEmpty
    }

    private static func claims(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return [:] }
        return (try? J.object(data)) ?? [:]
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
