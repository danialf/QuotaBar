import Foundation

/// Weekly (or longer) quota about to reset with some of it unspent. Subscription quota is
/// use-it-or-lose-it: whatever is left when the window resets is gone. The alert escalates as
/// the reset nears: a warning inside 72 hours, a bolder one inside 48, an alert inside 24.
enum ExpiryAlerts {
    enum Level: Int, Comparable {
        case warning = 1, urgent, critical

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        /// The level for a reset `timeLeft` seconds away; nil when it is 72 hours or more.
        init?(timeLeft: TimeInterval) {
            switch timeLeft {
            case ..<(24 * 3600): self = .critical
            case ..<(48 * 3600): self = .urgent
            case ..<(72 * 3600): self = .warning
            default: return nil
            }
        }

        /// The threshold this level starts at.
        var hours: Int {
            switch self {
            case .warning: 72
            case .urgent: 48
            case .critical: 24
            }
        }

        var word: String { self == .critical ? "Alert" : "Warning" }
    }

    struct Alert: Identifiable {
        var id: String { "\(account.id).\(window.label)" }
        let account: Account
        let window: UsageWindow
        let resetsAt: Date
        let level: Level
        /// From a saved reading: the reset time holds, the unspent share may not.
        var stale = false
        /// Percent of the window still unspent: what the reset will throw away.
        var unused: Double { window.remaining }
    }

    /// Only windows a week or longer: shorter ones are always this close to resetting.
    static let minimumWindow: TimeInterval = 6 * 86400
    /// Below this much unspent there is nothing worth burning.
    static let minimumUnused: Double = 2

    /// Every alert due now, soonest reset first. Windows of one account that reset together
    /// (Claude's all-models and per-model weeks) make one alert, for the one with least left:
    /// that is all you can actually burn.
    static func evaluate(_ snapshots: [ProviderSnapshot], now: Date = .now) -> [Alert] {
        snapshots.flatMap { snap in
            // The tightest window per reset time; a sibling with more left can't be burned past it.
            var binding: [UsageWindow] = []
            for w in snap.quotas.sorted(by: { $0.remaining < $1.remaining }) {
                guard let r = w.resetsAt, let d = w.duration, d >= minimumWindow,
                      !binding.contains(where: { abs($0.resetsAt!.timeIntervalSince(r)) < 60 }) else { continue }
                binding.append(w)
            }
            return binding.compactMap { w -> Alert? in
                guard let r = w.resetsAt, r > now, w.remaining >= minimumUnused,
                      let level = Level(timeLeft: r.timeIntervalSince(now)) else { return nil }
                return Alert(account: snap.account, window: w, resetsAt: r, level: level, stale: snap.staleReason != nil)
            }
        }
        .sorted { $0.resetsAt < $1.resetsAt }
    }
}
