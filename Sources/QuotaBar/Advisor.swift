import Foundation

/// Decides which subscription to lean on right now.
///
/// The idea: subscription quota is use-it-or-lose-it. Capacity in a long window (weekly,
/// monthly) that is about to reset is worth more than capacity that will still be there
/// for days, so it is weighted by how far through its window we are. A session window
/// that is nearly spent makes a provider a poor choice for the next hour even if its
/// weekly quota is healthy. A hit cap removes it entirely.
enum Advisor {
    enum Status { case go, caution, blocked }

    struct Ranked: Identifiable {
        var id: String { account.id }
        let account: Account
        let score: Double
        let status: Status
        let note: String
    }

    struct Warning: Identifiable {
        let id = UUID()
        let account: String?
        let text: String
    }

    struct Advice {
        let best: Account?
        let headline: String
        let detail: String
        let ranking: [Ranked]
        let warnings: [Warning]
        /// Which API organisation to put in Cursor (or anything else that takes a raw key).
        var apiPick: (account: APIAccount, reason: String)?
    }

    static func evaluate(_ snaps: [ProviderSnapshot], spends: [SpendSnapshot], now: Date = .now) -> Advice {
        let order = snaps.map(\.account.id)
        let ranking = snaps.map { s in
            let r = rank(s, now: now)
            guard s.staleReason != nil, r.status != .blocked else { return r }
            return Ranked(account: r.account, score: r.score, status: r.status, note: r.note + " (saved reading — log in to confirm)")
        }
            .sorted { $0.score != $1.score ? $0.score > $1.score : order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! }

        let usable = ranking.filter { $0.status != .blocked }
        var warnings: [Warning] = []

        for snap in snaps {
            for w in snap.quotas {
                guard let ttc = timeToCap(w, now: now), let ttr = w.timeToReset(now: now), ttc < ttr * 0.92 else { continue }
                let alt = usable.first { $0.id != snap.id }?.account
                let tail = alt.map { " Shift work to \($0.shortName)." } ?? ""
                warnings.append(Warning(account: snap.id,
                    text: "\(snap.account.shortName) \(w.label.lowercased()) runs out in ~\(Fmt.duration(ttc)), \(Fmt.duration(ttr - ttc)) before it resets.\(tail)"))
            }
        }
        for s in spends {
            let name = s.account.name
            if let left = s.remainingCredit, left > 0, let reset = s.account.creditResets(), s.account.creditMode == .monthly,
               let start = s.account.creditStart(), now.timeIntervalSince(start) > 86400 {
                let rate = (s.sinceCredit ?? 0) / now.timeIntervalSince(start)
                if rate > 0, left / rate < reset.timeIntervalSince(now) * 0.92 {
                    warnings.append(Warning(account: s.id, text: "\(name) allowance runs out in ~\(Fmt.duration(left / rate)), before it resets in \(Fmt.duration(reset.timeIntervalSince(now)))."))
                }
            }
            if let left = s.remainingCredit, left < 5 {
                warnings.append(Warning(account: s.id, text: left <= 0 ? "\(name) API credit is used up." : "\(name) API credit is low: \(Fmt.money(left)) left."))
            }
            guard let budget = s.budget else { continue }
            if s.monthToDate >= budget {
                warnings.append(Warning(account: s.id, text: "\(name) API is over budget: \(Fmt.money(s.monthToDate)) of \(Fmt.money(budget))."))
            } else if s.projected(now: now) > budget * 1.05 {
                warnings.append(Warning(account: s.id, text: "\(name) API on pace for \(Fmt.money(s.projected(now: now))) this month (budget \(Fmt.money(budget)))."))
            }
        }
        let pick = apiPick(spends)

        if let top = usable.first {
            return Advice(best: top.account, headline: "Use \(top.account.shortName) now", detail: top.note, ranking: ranking, warnings: warnings, apiPick: pick)
        }
        if ranking.isEmpty {
            return Advice(best: nil, headline: "No accounts connected", detail: "Sign in to Claude Code or Codex, or add a Z.ai key in Settings.", ranking: [], warnings: warnings, apiPick: pick)
        }
        let soonest = snaps.compactMap { s in s.quotas.filter { $0.usedPercent >= 98 }.compactMap { $0.timeToReset(now: now) }.max().map { (s.account, $0) } }
            .min { $0.1 < $1.1 }
        let detail = soonest.map { "\($0.0.shortName) is back first, in \(Fmt.duration($0.1))." } ?? "Wait for the next reset."
        return Advice(best: nil, headline: "Every plan is capped", detail: detail, ranking: ranking, warnings: warnings, apiPick: pick)
    }

    /// Prefer prepaid credit (it is already paid for), most remaining first; otherwise the
    /// organisation with the most budget headroom left this month.
    private static func apiPick(_ spends: [SpendSnapshot]) -> (account: APIAccount, reason: String)? {
        // Credit that resets or expires soonest is the credit you lose: weigh what is left by
        // how little time there is to spend it.
        func urgency(_ s: SpendSnapshot) -> Double {
            let left = s.remainingCredit ?? 0
            guard let reset = s.account.creditResets() else { return left / 60 }
            return left / max(1, reset.timeIntervalSinceNow / 86400)
        }
        if let best = spends.filter({ ($0.remainingCredit ?? 0) > 0 }).max(by: { urgency($0) < urgency($1) }) {
            let left = Fmt.money(best.remainingCredit!)
            if let reset = best.account.creditResets() {
                let verb = best.account.creditMode == .monthly ? "resets" : "expires"
                return (best.account, "\(left) credit left, \(verb) in \(Fmt.duration(max(0, reset.timeIntervalSinceNow)))")
            }
            return (best.account, "\(left) credit left")
        }
        if let best = spends.filter({ s in s.budget.map { s.monthToDate < $0 } ?? false }).max(by: { $0.budget! - $0.monthToDate < $1.budget! - $1.monthToDate }) {
            return (best.account, "\(Fmt.money(best.budget! - best.monthToDate)) of budget left this month")
        }
        return nil
    }

    private static func rank(_ snap: ProviderSnapshot, now: Date) -> Ranked {
        guard let short = snap.shortest, let long = snap.longest else {
            return Ranked(account: snap.account, score: 0, status: .blocked, note: "No data")
        }
        if let capped = snap.quotas.filter({ $0.usedPercent >= 98 }).max(by: { ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast) }) {
            let back = capped.timeToReset(now: now).map { "back in \(Fmt.duration($0))" } ?? "waiting for reset"
            return Ranked(account: snap.account, score: 0, status: .blocked, note: "\(capped.label) limit hit — \(back)")
        }

        let elapsed = long.elapsedFraction(now: now) ?? 0.5
        var score = long.remaining * (0.5 + elapsed) + short.remaining * 0.35
        let resetText = long.timeToReset(now: now).map { "resets in \(Fmt.duration($0))" } ?? "no reset time"

        if short.id != long.id, short.remaining < 15 {
            score *= 0.35
            let back = short.timeToReset(now: now).map { " — refills in \(Fmt.duration($0))" } ?? ""
            return Ranked(account: snap.account, score: score, status: .caution, note: "Session almost spent (\(Fmt.percent(short.remaining)) left)\(back)")
        }
        if long.remaining < 15 {
            score *= 0.5
            return Ranked(account: snap.account, score: score, status: .caution, note: "Only \(Fmt.percent(long.remaining)) of \(long.label.lowercased()) left, \(resetText)")
        }
        let note: String
        if elapsed > 0.55, long.remaining > 35 {
            note = "\(Fmt.percent(long.remaining)) of \(long.label.lowercased()) unused and it \(resetText). Use it or lose it."
        } else if short.id != long.id {
            note = "\(Fmt.percent(short.remaining)) of session and \(Fmt.percent(long.remaining)) of \(long.label.lowercased()) left."
        } else {
            note = "\(Fmt.percent(long.remaining)) left, \(resetText)."
        }
        return Ranked(account: snap.account, score: score, status: .go, note: note)
    }

    /// Time until the window hits 100% at the current average burn rate, if meaningful.
    static func timeToCap(_ w: UsageWindow, now: Date) -> TimeInterval? {
        guard let f = w.elapsedFraction(now: now), let d = w.duration, f > 0.25, w.usedPercent > 5, w.usedPercent < 98 else { return nil }
        let rate = w.usedPercent / (f * d) // percent per second
        return (100 - w.usedPercent) / rate
    }
}
