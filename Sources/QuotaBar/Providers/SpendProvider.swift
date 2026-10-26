import Foundation

/// Pay-as-you-go API spend for one organisation. Both vendors only expose cost through an
/// organisation admin key (sk-ant-admin… / OpenAI admin key); ordinary API keys can't read it.
struct SpendProvider {
    let account: APIAccount
    let adminKey: String

    func fetch() async throws -> SpendSnapshot {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let monthStart = cal.dateInterval(of: .month, for: .now)!.start
        let creditStart = account.creditStart().map { cal.startOfDay(for: $0) }
        let from = min(monthStart, creditStart ?? monthStart)

        let buckets = switch account.vendor {
        case .anthropic: try await anthropic(from: from)
        case .openai: try await openai(from: from)
        }
        let month = buckets.filter { $0.start >= monthStart }.reduce(0) { $0 + $1.amount }
        let since = creditStart.map { s in buckets.filter { $0.start >= s }.reduce(0) { $0 + $1.amount } }
        var snap = SpendSnapshot(account: account, monthToDate: month, sinceCredit: since)
        if account.vendor == .anthropic, let hint = account.keyHint {
            do { snap.key = try await anthropicKeyUsage(hint: hint, from: monthStart) }
            catch { snap.keyError = error.localizedDescription }
        }
        return snap
    }

    /// Finds the stored key among the organisation's keys by its hint, then sums its tokens this month.
    private func anthropicKeyUsage(hint: String, from start: Date) async throws -> SpendSnapshot.KeyUsage {
        let parts = hint.components(separatedBy: "…")
        guard parts.count == 2 else { throw ProviderError("Bad key hint") }
        var match: [String: Any]?
        var after: String?
        repeat {
            var c = URLComponents(string: "https://api.anthropic.com/v1/organizations/api_keys")!
            c.queryItems = [URLQueryItem(name: "limit", value: "100")] + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
            let obj = try J.object(try await HTTP.get(adminRequest(c.url!)))
            let keys = obj["data"] as? [[String: Any]] ?? []
            match = keys.first { k in
                // The API's hint looks like "sk-ant-api03-R2D...igAA"; ours keeps 16 leading chars.
                let theirs = (k["partial_key_hint"] as? String ?? "").replacingOccurrences(of: "...", with: "…").components(separatedBy: "…")
                guard theirs.count == 2, theirs[1] == parts[1] else { return false }
                return parts[0].hasPrefix(theirs[0]) || theirs[0].hasPrefix(parts[0])
            }
            after = match == nil && (obj["has_more"] as? Bool) == true ? obj["last_id"] as? String : nil
        } while after != nil
        guard let key = match, let id = key["id"] as? String else {
            throw ProviderError("Key not found in this organisation — is the admin key from the same org?")
        }

        var input = 0.0, output = 0.0
        var page: String?
        repeat {
            var c = URLComponents(string: "https://api.anthropic.com/v1/organizations/usage_report/messages")!
            c.queryItems = [
                URLQueryItem(name: "starting_at", value: start.formatted(.iso8601)),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31"),
                URLQueryItem(name: "api_key_ids[]", value: id),
            ] + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
            let obj = try J.object(try await HTTP.get(adminRequest(c.url!)))
            for bucket in obj["data"] as? [[String: Any]] ?? [] {
                for r in bucket["results"] as? [[String: Any]] ?? [] {
                    let cache = r["cache_creation"] as? [String: Any] ?? [:]
                    input += (J.num(r["uncached_input_tokens"]) ?? 0) + (J.num(r["cache_read_input_tokens"]) ?? 0)
                        + (J.num(cache["ephemeral_5m_input_tokens"]) ?? 0) + (J.num(cache["ephemeral_1h_input_tokens"]) ?? 0)
                    output += J.num(r["output_tokens"]) ?? 0
                }
            }
            page = (obj["has_more"] as? Bool) == true ? obj["next_page"] as? String : nil
        } while page != nil
        return .init(name: key["name"] as? String ?? "API key", status: key["status"] as? String ?? "", inputTokens: input, outputTokens: output)
    }

    private func adminRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(adminKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return req
    }

    private struct Bucket { let start: Date; let amount: Double }

    private func anthropic(from start: Date) async throws -> [Bucket] {
        var out: [Bucket] = []
        var page: String?
        repeat {
            var c = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
            c.queryItems = [
                URLQueryItem(name: "starting_at", value: start.formatted(.iso8601)),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31"),
            ] + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
            var req = URLRequest(url: c.url!)
            req.setValue(adminKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let obj = try J.object(try await HTTP.get(req))
            for bucket in obj["data"] as? [[String: Any]] ?? [] {
                let cents = (bucket["results"] as? [[String: Any]] ?? []).reduce(0) { $0 + (J.num($1["amount"]) ?? 0) }
                out.append(Bucket(start: J.date(bucket["starting_at"]) ?? start, amount: cents / 100)) // reported in cents
            }
            page = (obj["has_more"] as? Bool) == true ? obj["next_page"] as? String : nil
        } while page != nil
        return out
    }

    private func openai(from start: Date) async throws -> [Bucket] {
        var out: [Bucket] = []
        var page: String?
        repeat {
            var c = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
            c.queryItems = [
                URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31"),
            ] + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
            var req = URLRequest(url: c.url!)
            req.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
            let obj = try J.object(try await HTTP.get(req))
            for bucket in obj["data"] as? [[String: Any]] ?? [] {
                let dollars = (bucket["results"] as? [[String: Any]] ?? []).reduce(0) { $0 + (J.num(($1["amount"] as? [String: Any])?["value"]) ?? 0) }
                out.append(Bucket(start: J.date(bucket["start_time"]) ?? start, amount: dollars))
            }
            page = (obj["has_more"] as? Bool) == true ? obj["next_page"] as? String : nil
        } while page != nil
        return out
    }
}
