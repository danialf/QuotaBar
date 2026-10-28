import SwiftUI

/// The full-detail window: every account, API spend and warning.
struct DashboardView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    /// Rendered offscreen by `--snapshot`, where ScrollView draws nothing.
    var snapshotMode = false

    var body: some View {
        LockGate(enabled: !snapshotMode) { details }
            .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 900)
    }

    private var details: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 18).padding(.vertical, 14)
            Divider().opacity(0.6)
            if snapshotMode {
                content.padding(18)
            } else {
                ScrollView { content.padding(18) }
            }
        }
        .background(.background)
        .modifier(Presence(store: store, panel: false))
        .modifier(LiveRefresh(store: store, enabled: !snapshotMode, onScreen: Self.onScreen))
    }

    /// False when the Dashboard is minimised or fully covered; true if its window can't be found.
    private static func onScreen() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("dashboard") == true }) else { return true }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private var content: some View {
        let accounts = Array(store.orderedAccounts.enumerated())
        let base = store.advice == nil ? 0 : 1
        let after = base + accounts.count
        let warnings = store.advice?.warnings ?? []
        let columns = [GridItem(.adaptive(minimum: 340), spacing: 12, alignment: .top)]
        return VStack(alignment: .leading, spacing: 12) {
            if let advice = store.advice {
                AdviceCard(advice: advice).entrance(0)
            }
            if !warnings.isEmpty {
                WarningsCard(warnings: warnings).entrance(base)
            }
            SectionTitle("Now")
            NextResetCard(more: 4, wide: true).entrance(base)
            AgentsCard(fieldHeight: 190, wide: true).entrance(base + 1)
            SectionTitle("Subscriptions")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(accounts, id: \.element.0.id) { i, item in
                    ProviderCard(account: item.0, state: item.1,
                                 rank: store.advice?.ranking.first { $0.id == item.0.id }, order: base + i)
                        .entrance(base + i)
                }
            }
            if !store.apiAccounts.isEmpty {
                SectionTitle("API accounts")
                SpendCard(accounts: store.apiAccounts, spends: store.spends, order: after).entrance(after)
            }
            Text("Bars: fill is usage; the tick marks even pace through the window. Past the tick means you're using it faster than it refills.")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(store.advice?.best?.kind.tint ?? .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("QuotaBar").font(.system(size: 17, weight: .semibold))
                UpdatedLabel()
            }
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: "Refresh", spinning: store.isRefreshing) {
                Task { await store.refresh() }
            }
            IconButton(symbol: "pip", help: "Toggle floating overlay") { Overlay.toggle() }
            IconButton(symbol: "gearshape", help: "Settings") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold)).tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }
}

struct UpdatedLabel: View {
    @EnvironmentObject private var store: UsageStore
    var body: some View {
        // Re-render on a clock so "Updated 2 minutes ago" keeps counting between refreshes.
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            if let last = store.lastRefresh {
                Text("Updated \(last, format: .relative(presentation: .named))")
            } else {
                Text("Loading…")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Motion

private struct PopoverShownKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// True while the view is on screen; flips off after a popover closes so the entrance replays on the next open.
    var popoverShown: Bool {
        get { self[PopoverShownKey.self] }
        set { self[PopoverShownKey.self] = newValue }
    }
}

/// Tracks whether the popover (an NSPanel) or window is showing, drives `popoverShown`,
/// and refreshes stale data on open so a profile you just used shows up straight away.
struct Presence: ViewModifier {
    let store: UsageStore
    let panel: Bool
    @State private var shown = false
    @State private var keyed = false

    func body(content: Content) -> some View {
        content
            .environment(\.popoverShown, shown)
            .onAppear { keyed = true; shown = true; store.touch(); store.refreshIfStale() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard panel, note.object is NSPanel else { return }
                keyed = true
                shown = true
                store.touch()
                store.refreshIfStale()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
                guard panel, note.object is NSPanel else { return }
                keyed = false
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    if !keyed { shown = false }
                }
            }
    }
}

/// While a surface is on screen, refresh every minute instead of the background cadence,
/// so usage you are watching moves as you spend it. Stops when the view goes away.
struct LiveRefresh: ViewModifier {
    let store: UsageStore
    var enabled = true
    let onScreen: @MainActor () -> Bool

    func body(content: Content) -> some View {
        content.task {
            guard enabled else { return }
            let interval: TimeInterval = 60
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, onScreen() else { continue }
                store.refreshIfStale(after: interval - 5, quotasOnly: true)
            }
        }
    }
}

private struct Entrance: ViewModifier {
    let index: Int
    @Environment(\.popoverShown) private var shown
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        let visible = shown || reduce
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 8)
            .animation(visible && !reduce ? .smooth(duration: 0.5).delay(Double(index) * 0.05) : nil, value: shown)
    }
}

extension View {
    func entrance(_ index: Int) -> some View { modifier(Entrance(index: index)) }
}

/// Drives a displayed value from 0 on open (after `delay`), springs between values on refresh,
/// and reports `settled` once the fill has landed so secondary marks can follow.
private struct Revealed<Content: View>: View {
    let value: Double
    var delay = 0.0
    @ViewBuilder var content: (_ value: Double, _ settled: Bool) -> Content
    @Environment(\.popoverShown) private var shown
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var display = 0.0
    @State private var settled = false

    var body: some View {
        content(display, settled)
            .onAppear(perform: enter)
            .onChange(of: shown) { enter() }
            .onChange(of: value) { update() }
    }

    private func enter() {
        guard shown else {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { display = 0; settled = false }
            return
        }
        if reduce { display = value; settled = true; return }
        withAnimation(.smooth(duration: 0.9).delay(delay)) { display = value }
        withAnimation(.smooth(duration: 0.4).delay(delay + 0.7)) { settled = true }
    }

    private func update() {
        guard shown else { return }
        if reduce { display = value } else { withAnimation(.spring(duration: 0.7, bounce: 0.12)) { display = value } }
    }
}

struct SkeletonBar: View {
    var height: CGFloat = 7
    var width: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var sweep = false

    var body: some View {
        Capsule().fill(.primary.opacity(0.08))
            .overlay {
                if !reduce {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Color.primary.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.5)
                            .offset(x: sweep ? geo.size.width : -geo.size.width * 0.5)
                    }
                }
            }
            .clipShape(Capsule())
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .onAppear {
                guard !reduce else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { sweep = true }
            }
    }
}

// MARK: - Cards

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.07)))
    }
}

/// Base for the ambient loops. They run as Core Animation on the render server, so they cost
/// nothing per frame here: an endless SwiftUI phaseAnimator re-evaluates and re-lays-out the
/// whole window every frame, which held an open Dashboard at ~50% CPU.
private class AmbientLayerView: NSView {
    private var laidOutSize = CGSize.zero

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Decoration only: clicks and hover go to the card underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize, bounds.width > 0, bounds.height > 0 else { return }
        laidOutSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        withAppearance { resized(); applyColors() }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withAppearance(applyColors)
    }

    /// Re-adds the loop after a detach strips it, e.g. when the popover closes and reopens.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, laidOutSize != .zero else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        withAppearance(resized)
        CATransaction.commit()
    }

    func withAppearance(_ body: () -> Void) { effectiveAppearance.performAsCurrentDrawingAppearance(body) }

    func setUp() {}
    /// Lays out the layers for the new size and (re)starts the loop.
    func resized() {}
    func applyColors() {}
}

private struct AdviceGlow: NSViewRepresentable {
    let tint: Color

    func makeNSView(context: Context) -> AdviceGlowView { AdviceGlowView() }
    func updateNSView(_ view: AdviceGlowView, context: Context) { view.tint = NSColor(tint) }
}

/// A soft radial wash that drifts from the top-leading corner to the bottom-trailing one and back, 4s each way.
private final class AdviceGlowView: AmbientLayerView {
    private let glow = CAGradientLayer()
    private let border = CALayer()
    var tint = NSColor.clear { didSet { if tint != oldValue { restyle() } } }

    override func setUp() {
        glow.type = .radial
        for l in [glow, border] {
            l.cornerRadius = 12
            l.cornerCurve = .continuous
            l.masksToBounds = true
            layer?.addSublayer(l)
        }
        border.borderWidth = 1
    }

    /// Recolouring restarts the loop, since the animations hold their colours.
    private func restyle() {
        guard bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        withAppearance(resized)
        CATransaction.commit()
    }

    override func resized() {
        glow.frame = bounds
        border.frame = bounds
        // Unit space, origin bottom-left; endPoint sets a 230pt radius, as the SwiftUI version had.
        let rx = 230 / bounds.width, ry = 230 / bounds.height
        let from = CGPoint(x: 0, y: 1), to = CGPoint(x: 1, y: 0)
        let dim = [tint.withAlphaComponent(0.05).cgColor, tint.withAlphaComponent(0).cgColor]
        let lit = [tint.withAlphaComponent(0.2).cgColor, tint.withAlphaComponent(0).cgColor]
        glow.startPoint = from
        glow.endPoint = CGPoint(x: from.x + rx, y: from.y + ry)
        glow.colors = dim
        border.borderColor = tint.withAlphaComponent(0).cgColor

        func loop(_ key: String, _ a: Any, _ b: Any) -> CABasicAnimation {
            let anim = CABasicAnimation(keyPath: key)
            anim.fromValue = a; anim.toValue = b
            anim.duration = 4
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return anim
        }
        glow.add(loop("startPoint", from, to), forKey: "start")
        glow.add(loop("endPoint", CGPoint(x: from.x + rx, y: from.y + ry), CGPoint(x: to.x + rx, y: to.y + ry)), forKey: "end")
        glow.add(loop("colors", dim, lit), forKey: "colors")
        border.add(loop("borderColor", tint.withAlphaComponent(0).cgColor, tint.withAlphaComponent(0.22).cgColor), forKey: "border")
    }
}

struct AdviceCard: View {
    let advice: Advisor.Advice
    @Environment(\.popoverShown) private var shown
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let tint = advice.best?.kind.tint ?? .secondary
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                Circle().fill(tint.opacity(0.18))
                Image(systemName: advice.best?.kind.symbol ?? "hourglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("RECOMMENDED").font(.system(size: 9.5, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                Text(advice.headline).font(.system(size: 14, weight: .semibold))
                    .id(advice.headline).transition(.opacity)
                Text(advice.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .id(advice.detail).transition(.opacity)
                if advice.ranking.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(Array(advice.ranking.enumerated()), id: \.element.id) { i, r in
                            if i > 0 { Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(.tertiary) }
                            Text(r.account.kind == .claude ? r.account.label : r.account.kind.shortName)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(r.status == .blocked ? .tertiary : .secondary)
                                .strikethrough(r.status == .blocked)
                        }
                    }
                    .padding(.top, 2)
                }
                if let pick = advice.apiPick {
                    HStack(spacing: 5) {
                        Image(systemName: "key.horizontal.fill").font(.system(size: 9)).foregroundStyle(pick.account.vendor.provider.tint)
                        Text("Cursor / API key: ").foregroundStyle(.secondary) + Text(pick.account.name).fontWeight(.semibold)
                            + Text(" · \(pick.reason)").foregroundStyle(.secondary)
                        if pick.account.keyHint != nil { KeyCopyButton(account: pick.account, compact: true) }
                    }
                    .font(.caption2)
                    .padding(.top, 3)
                    .id(pick.account.id).transition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
                if shown && !reduce { AdviceGlow(tint: tint).transition(.opacity) }
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.25)))
        .animation(.smooth(duration: 0.5), value: "\(advice.best?.id ?? "")|\(advice.apiPick?.account.id ?? "")|\(advice.headline)|\(advice.detail)")
        .animation(.easeInOut(duration: 1), value: shown && !reduce)
    }
}

struct ProviderCard: View {
    let account: Account
    let state: ProviderState
    let rank: Advisor.Ranked?
    var order = 0

    private var kind: Int {
        switch state {
        case .disabled: 0
        case .loading: 1
        case .failed: 2
        case .ok: 3
        }
    }

    private var provider: ProviderID { account.kind }

    var body: some View {
        Card {
            HStack(spacing: 8) {
                Image(systemName: provider.symbol).foregroundStyle(provider.tint).font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(account.title).font(.system(size: 13, weight: .semibold))
                    if let detail = account.detail ?? state.snapshot?.account.detail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                if let plan = state.snapshot?.plan {
                    Text(plan)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(provider.tint.opacity(0.15)))
                        .foregroundStyle(provider.tint)
                }
                Spacer()
                if let rank { StatusDot(status: rank.status) }
            }
            Group {
                switch state {
                case .disabled:
                    EmptyView()
                case .loading:
                    VStack(alignment: .leading, spacing: 10) {
                        SkeletonBar()
                        SkeletonBar(height: 5, width: 96)
                    }
                    .padding(.vertical, 2.5)
                    .transition(.opacity)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                case .ok(let snap):
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(snap.windows.enumerated()), id: \.element.id) { i, w in
                            WindowRow(window: w, tint: provider.tint, delay: 0.05 * Double(order) + 0.15 + 0.08 * Double(i))
                        }
                        if let note = snap.note {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let resets = snap.resets, resets.available > 0 {
                            Label(resets.text, systemImage: "arrow.counterclockwise.circle")
                                .font(.caption2).foregroundStyle(resets.usableNow > 0 ? provider.tint : .secondary)
                        }
                        if let reason = snap.staleReason {
                            Label {
                                Text("Last reading \(snap.updatedAt, format: .relative(presentation: .named)). \(reason)")
                            } icon: {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                            .font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.35), value: kind)
        }
    }
}

private struct PulseRing: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> PulseRingView { PulseRingView() }
    func updateNSView(_ view: PulseRingView, context: Context) { view.color = NSColor(color) }
}

/// A ring that grows and fades every 2.2s.
private final class PulseRingView: AmbientLayerView {
    private let ring = CAShapeLayer()
    var color = NSColor.clear { didSet { if color != oldValue { applyColors() } } }

    override func setUp() {
        ring.fillColor = nil
        ring.lineWidth = 1.2
        layer?.addSublayer(ring)
    }

    override func resized() {
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.6, dy: 0.6), transform: nil)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1; scale.toValue = 2.8
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.5; fade.toValue = 0
        let pulse = CAAnimationGroup()
        pulse.animations = [scale, fade]
        pulse.duration = 2.2
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulse.repeatCount = .infinity
        ring.opacity = 0
        ring.add(pulse, forKey: "pulse")
    }

    override func applyColors() { ring.strokeColor = color.cgColor }
}

struct StatusDot: View {
    let status: Advisor.Status
    @Environment(\.popoverShown) private var shown
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let (color, text): (Color, String) = switch status {
        case .go: (.green, "Available")
        case .caution: (.orange, "Low")
        case .blocked: (.red, "Capped")
        }
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
                .overlay { if status == .go && shown && !reduce { PulseRing(color: color) } }
            Text(text).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
        }
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let tint: Color
    var delay = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.caption.weight(.medium))
                Spacer()
                Revealed(value: window.usedPercent, delay: delay) { shown, _ in
                    Text(Fmt.percent(shown))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(UsageColor.color(window.usedPercent, tint: tint))
                        .contentTransition(.numericText(value: shown))
                }
            }
            QuotaProgress(used: window.usedPercent, pace: window.elapsedFraction().map { $0 * 100 }, tint: tint, delay: delay)
            HStack {
                if let credit = window.creditText ?? window.detail {
                    Text(credit)
                }
                if let t = window.timeToReset() {
                    Text(window.isCredit ? "· renews in \(Fmt.duration(t))" : "Resets in \(Fmt.duration(t))")
                } else if !window.isCredit {
                    Text("Reset time unknown")
                }
                Spacer()
                if let pace = window.elapsedFraction().map({ $0 * 100 }) {
                    let delta = window.usedPercent - pace
                    Text(abs(delta) < 5 ? "On pace" : delta > 0 ? "\(Fmt.percent(delta)) ahead of pace" : "\(Fmt.percent(-delta)) to spare")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

enum UsageColor {
    static func color(_ used: Double, tint: Color) -> Color {
        used >= 90 ? .red : used >= 75 ? .orange : tint
    }
}

struct QuotaProgress: View {
    let used: Double
    let pace: Double?
    let tint: Color
    var delay = 0.0

    var body: some View {
        Revealed(value: used, delay: delay) { shown, settled in
            GeometryReader { geo in
                let w = geo.size.width
                let color = UsageColor.color(used, tint: tint)
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(shown > 0 ? 6 : 0, w * min(1, shown / 100)))
                    if let pace {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.primary.opacity(0.55))
                            .frame(width: 2, height: 12)
                            .offset(x: min(w - 2, max(0, w * pace / 100 - 1)))
                            .animation(.smooth(duration: 0.5), value: pace)
                            .offset(x: settled ? 0 : -10)
                            .opacity(settled ? 1 : 0)
                    }
                }
            }
        }
        .frame(height: 7)
        .padding(.vertical, 2.5)
    }
}

struct SpendCard: View {
    let accounts: [APIAccount]
    let spends: [String: SpendState]
    var order = 0

    var body: some View {
        Card {
            HStack(spacing: 8) {
                Image(systemName: "key.horizontal").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text("API accounts · \(Date.now.formatted(.dateTime.month(.wide)))").font(.system(size: 13, weight: .semibold))
            }
            ForEach(Array(accounts.enumerated()), id: \.element.id) { i, account in
                if i > 0 { Divider().opacity(0.5) }
                row(account)
            }
        }
    }

    @ViewBuilder private func row(_ account: APIAccount) -> some View {
        let tint = account.vendor.provider.tint
        let snap: SpendSnapshot? = if case .ok(let s)? = spends[account.id] { s } else { nil }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(account.name.isEmpty ? "Unnamed" : account.name).font(.caption.weight(.semibold))
                Text(account.vendor.name).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if let s = snap {
                    Text(Fmt.money(s.monthToDate)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                    if let b = s.budget { Text("/ \(Fmt.money(b))").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let hint = account.keyHint {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(hint).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    if let k = snap?.key {
                        Text("· \(Fmt.tokens(k.inputTokens)) in / \(Fmt.tokens(k.outputTokens)) out this month")
                            .font(.caption2).foregroundStyle(.secondary)
                        if k.status != "active", !k.status.isEmpty {
                            Text(k.status).font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    KeyCopyButton(account: account)
                }
                if let err = snap?.keyError {
                    Text(err).font(.caption2).foregroundStyle(.orange)
                }
            }
            switch spends[account.id] {
            case nil:
                Text(!Vault.has(account.keychainKey) ? "Add the organisation's admin key in Settings to track spend and credit." : "Loading…")
                    .font(.caption2).foregroundStyle(.secondary)
            case .failed(let msg)?:
                Label(msg, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .ok(let s)?:
                if let credit = account.credit, credit > 0, let left = s.remainingCredit {
                    QuotaProgress(used: (credit - left) / credit * 100, pace: nil, tint: tint, delay: 0.05 * Double(order) + 0.15)
                    let reset = account.creditResets().map { r in
                        " · \(account.creditMode == .monthly ? "resets" : "expires") \(r.formatted(.dateTime.month(.abbreviated).day())) (\(Fmt.duration(max(0, r.timeIntervalSinceNow))))"
                    } ?? ""
                    Text("\(Fmt.money(max(0, left))) of \(Fmt.money(credit)) left\(reset)")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let b = s.budget {
                    let month = Calendar(identifier: .gregorian).dateInterval(of: .month, for: .now)!
                    QuotaProgress(used: s.monthToDate / b * 100,
                                  pace: Date.now.timeIntervalSince(month.start) / month.duration * 100,
                                  tint: tint, delay: 0.05 * Double(order) + 0.15)
                    Text("Projected month end: \(Fmt.money(s.projected()))").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Projected month end: \(Fmt.money(s.projected()))").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Reveals a vaulted API key after Touch ID and puts it on the clipboard for 90 seconds.
struct KeyCopyButton: View {
    let account: APIAccount
    var compact = false
    @State private var state: Phase = .idle
    enum Phase { case idle, copied, failed }

    var body: some View {
        Button {
            Task {
                do {
                    let key = try await Vault.open(account.vaultName, reason: "copy the \(account.name) API key")
                    Vault.copyToClipboard(key)
                    state = .copied
                } catch {
                    state = .failed
                }
                try? await Task.sleep(for: .seconds(2.5))
                state = .idle
            }
        } label: {
            Label(label, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.system(size: compact ? 10 : 11, weight: .medium))
                .padding(.horizontal, compact ? 6 : 8).padding(.vertical, compact ? 2 : 3)
                .background(Capsule().fill(.primary.opacity(0.07)))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help("Copy the key after Touch ID; the clipboard clears after 90 seconds")
        .animation(.smooth(duration: 0.25), value: state)
    }

    private var label: String {
        switch state {
        case .idle: compact ? "Copy" : "Copy key"
        case .copied: "Copied"
        case .failed: "Cancelled"
        }
    }

    private var icon: String {
        switch state {
        case .idle: "touchid"
        case .copied: "checkmark"
        case .failed: "xmark"
        }
    }
}

struct WarningsCard: View {
    let warnings: [Advisor.Warning]
    var body: some View {
        Card {
            ForEach(warnings) { w in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.caption)
                    Text(w.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var spinning = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var hover = false
    @State private var angle = 0.0

    var body: some View {
        Button(action: action) {
            glyph
                .font(.system(size: 12, weight: .semibold))
                .opacity(spinning && reduce ? 0.45 : 1)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.primary.opacity(hover ? 0.1 : 0.05)))
                .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }

    /// Whole turns only on macOS 14, so the glyph always comes to rest at 0 instead of snapping back.
    @ViewBuilder private var glyph: some View {
        let image = Image(systemName: symbol)
        if #available(macOS 15, *) {
            image.symbolEffect(.rotate, isActive: spinning && !reduce)
        } else {
            image.rotationEffect(.degrees(angle))
                .task(id: spinning && !reduce) {
                    guard spinning, !reduce else { return }
                    while !Task.isCancelled {
                        withAnimation(.linear(duration: 0.9)) { angle += 360 }
                        try? await Task.sleep(for: .milliseconds(900))
                    }
                }
        }
    }
}
