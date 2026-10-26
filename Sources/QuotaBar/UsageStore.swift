import AppKit
import SwiftUI
import UserNotifications

enum Prefs {
    static let refreshMinutes = "refreshMinutes"
    static let menuBarStyle = "menuBarStyle"
    static let menuBarAll = "menuBarAllAccounts"
    static let zaiChina = "zaiChina"
    static let notify = "notifyThresholds"
    static let notifyRanking = "notifyRanking"
    static let zaiKey = "zai.apiKey"
    static let relockMinutes = "relockMinutes"
    static let showInDock = "showInDock"
    static let overlayShown = "overlayShown"
    static let overlayExpanded = "overlayExpanded"
    static func enabled(_ id: String) -> String { "enabled.\(id)" }
    static func enabled(_ p: ProviderID) -> String { "enabled.\(p.rawValue)" }

    static func register() {
        var defaults: [String: Any] = [refreshMinutes: 5, menuBarStyle: MenuBarStyle.bars.rawValue,
                                       menuBarAll: false, zaiChina: false, notify: true, notifyRanking: true, relockMinutes: 30, showInDock: true]
        for p in ProviderID.allCases { defaults[enabled(p)] = true }
        UserDefaults.standard.register(defaults: defaults)
    }

    /// Per-account switch; unset means on.
    static func isEnabled(_ account: Account) -> Bool {
        let d = UserDefaults.standard
        guard d.bool(forKey: enabled(account.kind)) else { return false }
        return d.object(forKey: enabled(account.id)) as? Bool ?? true
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case bars, percent, icon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bars: "Mini bars"
        case .percent: "Percentages"
        case .icon: "Icon only"
        }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var states: [String: ProviderState] = [:]
    @Published private(set) var apiAccounts: [APIAccount] = APIAccount.load()
    @Published private(set) var spends: [String: SpendState] = [:]
    @Published private(set) var advice: Advisor.Advice?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    /// Last refresh that also rescanned Claude profiles and fetched API spend.
    private var lastFullRefresh: Date?
    /// The dropdown, Dashboard and Settings show only a lock screen until Touch ID.
    @Published private(set) var locked = true
    @Published private(set) var unlocking = false
    @Published var unlockError: String?
    @Published private(set) var menuBarImage = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "QuotaBar")!

    private var loop: Task<Void, Never>?
    private var notifiedBands: [String: Int] = [:]
    /// Windows already warned about running out early, keyed by window and reset hour.
    private var notifiedPace: Set<String> = []
    private var lastResets: [String: ProviderSnapshot.ResetCredits] = [:]
    /// The pick last announced (nil until the first refresh), and a new one waiting to hold.
    private var announcedBest: String??
    private var pendingBest: String?
    private var lastStatus: [String: Advisor.Status] = [:]
    private var defaultsObserver: NSObjectProtocol?
    private var lockObservers: [NSObjectProtocol] = []
    /// Admin and Z.ai keys, decrypted once per launch by the first unlock and kept only in memory.
    private var sessionSecrets: [String: String]?
    private var lastActive = Date.now
    private var refreshSoonTask: Task<Void, Never>?

    private var defaults: UserDefaults { .standard }
    private static let cacheKey = "snapshotCache"
    private var cache: [String: ProviderSnapshot] = {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ProviderSnapshot].self, from: data)) ?? [:]
    }()

    init() {
        Prefs.register()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.renderMenuBar()
                self?.applyDockPolicy()
            }
        }
        Vault.migrateFromKeychain(names: [Prefs.zaiKey] + apiAccounts.map(\.keychainKey))
        // Keys sealed by earlier builds couldn't be migrated; drop hints that point at nothing.
        let fixed = apiAccounts.map { a -> APIAccount in
            var a = a
            if a.keyHint != nil, !Vault.has(a.vaultName) { a.keyHint = nil }
            return a
        }
        if fixed != apiAccounts { saveAPIAccounts(fixed) }
        observeLockEvents()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        renderMenuBar()
        startLoop()
    }

    func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let minutes = max(1, UserDefaults.standard.integer(forKey: Prefs.refreshMinutes))
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
    }

    // MARK: Lock

    func unlock() async {
        guard locked, !unlocking else { return }
        unlocking = true
        defer { unlocking = false }
        do {
            let context = try await Vault.authenticate(reason: "unlock QuotaBar")
            if sessionSecrets == nil {
                var secrets: [String: String] = [:]
                for name in [Prefs.zaiKey] + apiAccounts.map(\.keychainKey) where Vault.has(name) {
                    secrets[name] = try? Vault.open(name, context: context)
                }
                sessionSecrets = secrets
            }
            unlockError = nil
            locked = false
            lastActive = .now
            await refresh()
        } catch {
            unlockError = error.localizedDescription
        }
    }

    func lock() { locked = true }

    /// Called whenever a QuotaBar surface is shown; re-locks after a long idle stretch.
    func touch() {
        let minutes = defaults.integer(forKey: Prefs.relockMinutes)
        if !locked, minutes > 0, Date.now.timeIntervalSince(lastActive) > Double(minutes) * 60 { locked = true }
        lastActive = .now
    }

    /// A secret for background work: nil until the first unlock of this launch.
    func secret(_ name: String) -> String? { sessionSecrets?[name] }

    /// Saves a secret typed in Settings: sealed at rest, and usable now without another prompt.
    func storeSecret(_ name: String, _ value: String?) throws {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty {
            Vault.remove(name)
            sessionSecrets?[name] = nil
        } else {
            try Vault.seal(value, as: name)
            sessionSecrets?[name] = value
        }
    }

    private func observeLockEvents() {
        let lockNow: (Notification) -> Void = { [weak self] _ in Task { @MainActor in self?.lock() } }
        lockObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lockNow))
        lockObservers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: lockNow))
    }

    /// Coalesces bursts of Settings edits into one refresh.
    func refreshSoon() {
        refreshSoonTask?.cancel()
        refreshSoonTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func saveAPIAccounts(_ list: [APIAccount]) {
        APIAccount.save(list)
        apiAccounts = list
        spends = spends.filter { id, _ in list.contains { $0.id == id } }
    }

    /// Called when the popover opens, so a profile you just logged into shows up right away.
    func refreshIfStale(after seconds: TimeInterval = 60, quotasOnly: Bool = false) {
        guard !isRefreshing, (lastRefresh.map { Date.now.timeIntervalSince($0) > seconds } ?? true) else { return }
        Task { await refresh(quotasOnly: quotasOnly) }
    }

    /// `quotasOnly` skips the profile scan and API spend, which barely move minute to minute, for
    /// the live ticks while a surface is watched. It still does everything if the last full
    /// refresh is older than the background interval, so a skipped loop tick can't starve spend.
    func refresh(quotasOnly: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let interval = Double(max(1, defaults.integer(forKey: Prefs.refreshMinutes)) * 60)
        let full = !quotasOnly || accounts.isEmpty || (lastFullRefresh.map { Date.now.timeIntervalSince($0) >= interval } ?? true)

        if full {
            let claude = await Task.detached { ClaudeProvider.discover() }.value
            accounts = claude + [.codex, .zai]
        }
        for a in accounts where states[a.id] == nil { states[a.id] = .loading }

        let zaiKey = secret(Prefs.zaiKey)
        let zaiLocked = sessionSecrets == nil && Vault.has(Prefs.zaiKey)
        let china = defaults.bool(forKey: Prefs.zaiChina)
        let enabled = accounts.filter(Prefs.isEnabled)
        for a in accounts where !enabled.contains(a) { states[a.id] = .disabled }

        await withTaskGroup(of: (Account, ProviderState).self) { group in
            for a in enabled {
                group.addTask {
                    do {
                        if a.kind == .zai, zaiLocked { throw ProviderError("Unlock QuotaBar with Touch ID to load") }
                        let snap: ProviderSnapshot = switch a.kind {
                        case .claude: try await ClaudeProvider(account: a).fetch()
                        case .codex: try await CodexProvider().fetch()
                        case .zai: try await ZaiProvider(apiKey: zaiKey, china: china).fetch()
                        }
                        return (a, .ok(snap))
                    } catch {
                        return (a, .failed(error.localizedDescription))
                    }
                }
            }
            for await (a, state) in group {
                switch state {
                case .ok(let snap):
                    cache[a.id] = snap
                    states[a.id] = state
                case .failed(let msg):
                    // Fall back to the last good reading (this session's, or saved from an earlier
                    // one), brought forward past any resets, and say why it is stale.
                    if var old = states[a.id]?.snapshot.flatMap({ $0.staleReason == nil ? $0 : nil }) ?? cache[a.id] {
                        old = old.rolledForward()
                        old.staleReason = msg
                        states[a.id] = .ok(old)
                    } else {
                        states[a.id] = state
                    }
                default:
                    states[a.id] = state
                }
            }
            defaults.set(try? JSONEncoder().encode(cache), forKey: Self.cacheKey)
        }

        if full { await refreshSpends() }

        lastRefresh = .now
        if full { lastFullRefresh = .now }
        recompute()
        notifyThresholds()
        notifyRanking()
    }

    private func refreshSpends() async {
        let jobs = apiAccounts.compactMap { a in secret(a.keychainKey).map { SpendProvider(account: a, adminKey: $0) } }
        var newSpends: [String: SpendState] = [:]
        if sessionSecrets == nil {
            for a in apiAccounts where Vault.has(a.keychainKey) { newSpends[a.id] = .failed("Unlock QuotaBar with Touch ID to load") }
        }
        await withTaskGroup(of: (String, SpendState).self) { group in
            for job in jobs {
                group.addTask {
                    do { return (job.account.id, .ok(try await job.fetch())) }
                    catch { return (job.account.id, .failed(error.localizedDescription)) }
                }
            }
            for await (id, state) in group { newSpends[id] = state }
        }
        spends = newSpends
    }

    var orderedAccounts: [(Account, ProviderState)] {
        accounts.compactMap { a in
            guard let s = states[a.id] else { return nil }
            if case .disabled = s { return nil }
            return (a, s)
        }
    }

    var okSpends: [SpendSnapshot] {
        apiAccounts.compactMap { a in
            if case .ok(let v) = spends[a.id] { return v }
            return nil
        }
    }

    private func recompute() {
        advice = Advisor.evaluate(accounts.compactMap { states[$0.id]?.snapshot }, spends: okSpends)
        renderMenuBar()
    }

    // MARK: Menu bar

    /// All accounts, or (default) the best-ranked account of each service so the item stays narrow.
    private var menuBarAccounts: [(Account, ProviderState)] {
        let all = orderedAccounts
        guard !defaults.bool(forKey: Prefs.menuBarAll) else { return all }
        let rankOrder = advice?.ranking.map(\.id) ?? []
        return ProviderID.allCases.compactMap { kind in
            all.filter { $0.0.kind == kind }
                .min { (rankOrder.firstIndex(of: $0.0.id) ?? .max) < (rankOrder.firstIndex(of: $1.0.id) ?? .max) }
        }
    }

    var menuBarItems: [MenuBarGlyph.Item] {
        menuBarAccounts.map { a, state in
            MenuBarGlyph.Item(glyph: a.glyph, session: state.snapshot?.shortest?.usedPercent,
                              long: state.snapshot?.longest?.usedPercent, peak: state.snapshot?.bottleneck?.usedPercent,
                              recommended: advice?.best == a)
        }
    }

    /// Shows or hides the Dock icon to match the setting, keeping any open window in front.
    func applyDockPolicy() {
        guard NSApp != nil, !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) else { return }
        let want: NSApplication.ActivationPolicy = defaults.bool(forKey: Prefs.showInDock) ? .regular : .accessory
        guard NSApp.activationPolicy() != want else { return }
        NSApp.setActivationPolicy(want)
        if want == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    func renderMenuBar() {
        let style = MenuBarStyle(rawValue: defaults.string(forKey: Prefs.menuBarStyle) ?? "") ?? .bars
        let items = menuBarItems
        let renderer = ImageRenderer(content: MenuBarGlyph(items: items, style: style))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        if let image = renderer.nsImage {
            image.isTemplate = true
            menuBarImage = image
        }
    }

    // MARK: Notifications

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private func post(_ id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func switchHint(from a: Account) -> String {
        advice?.best.flatMap { $0 != a ? " Switch to \($0.shortName)." : nil } ?? ""
    }

    private func notifyThresholds() {
        guard defaults.bool(forKey: Prefs.notify), canNotify else { return }
        for (a, state) in orderedAccounts {
            guard let snap = state.snapshot else { continue }
            for w in snap.quotas {
                let key = "\(a.id).\(w.label)"
                let band = w.usedPercent >= 95 ? 2 : w.usedPercent >= 80 ? 1 : 0
                let previous = notifiedBands[key] ?? 0
                notifiedBands[key] = band
                let reset = w.timeToReset().map { " Resets in \(Fmt.duration($0))." } ?? ""
                if band > previous {
                    post(key, title: "\(a.shortName) · \(w.label)", body: "\(Fmt.percent(w.usedPercent)) used.\(reset)\(switchHint(from: a))")
                    continue
                }
                // Below the bands but burning fast enough to hit the cap before the reset: once per window cycle.
                guard band == 0, snap.staleReason == nil, let resetsAt = w.resetsAt,
                      let ttc = Advisor.timeToCap(w, now: .now), let ttr = w.timeToReset(), ttc < ttr * 0.92 else { continue }
                let paceKey = "\(key).pace.\(Int(resetsAt.timeIntervalSince1970 / 3600))"
                guard notifiedPace.insert(paceKey).inserted else { continue }
                post(paceKey, title: "\(a.shortName) · \(w.label) on pace to run out",
                     body: "At this rate it runs out in ~\(Fmt.duration(ttc)), \(Fmt.duration(ttr - ttc)) before it resets.\(switchHint(from: a))")
            }
            if let r = snap.resets {
                let old = lastResets[a.id]
                lastResets[a.id] = r
                if r.usableNow > 0, (old?.usableNow ?? 0) == 0 {
                    post("\(a.id).resets.usable", title: "\(a.shortName) limit reset available",
                         body: "You're capped and have \(r.usableNow == 1 ? "a reset" : "\(r.usableNow) resets") you can use now.")
                } else if let old, r.available > old.available {
                    post("\(a.id).resets", title: "\(a.shortName) gained a limit reset", body: "\(r.text).")
                }
            }
        }
    }

    /// Announces a change of the account to use next, and accounts hitting or coming back from a cap.
    /// A new pick must hold for two refreshes, unless the old one stopped being a clean "go",
    /// so two near-equal accounts trading places don't notify every few minutes.
    private func notifyRanking() {
        guard let advice else { return }
        let statuses = Dictionary(advice.ranking.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        defer { lastStatus = statuses }
        let best = advice.best?.id
        guard let announced = announcedBest else { announcedBest = .some(best); return }
        guard defaults.bool(forKey: Prefs.notifyRanking), canNotify else { announcedBest = .some(best); return }

        let names = Dictionary(advice.ranking.map { ($0.id, $0.account.shortName) }, uniquingKeysWith: { a, _ in a })
        for r in advice.ranking {
            guard let was = lastStatus[r.id], was != r.status, was == .blocked || r.status == .blocked else { continue }
            let back = r.status != .blocked
            post("\(r.id).status", title: back ? "\(r.account.shortName) is available again" : "\(r.account.shortName) is capped",
                 body: r.note)
        }

        guard best != announced else { pendingBest = nil; return }
        let oldDegraded = announced.map { statuses[$0] != .go } ?? true
        if !oldDegraded, pendingBest != best {
            pendingBest = best
            return
        }
        pendingBest = nil
        announcedBest = .some(best)
        let order = advice.ranking.filter { $0.status != .blocked }.map(\.account.shortName).joined(separator: " → ")
        let title = advice.best.map { "Use \($0.shortName) now" } ?? advice.headline
        let from = announced.flatMap { names[$0] }.map { "Was \($0). " } ?? ""
        post("ranking", title: title, body: "\(from)\(advice.detail)\(order.isEmpty ? "" : "\nOrder: \(order)")")
    }
}
