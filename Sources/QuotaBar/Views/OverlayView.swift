import AppKit
import SwiftUI

/// A small always-on-top panel you can drag anywhere: one line per account, or every card when expanded.
/// It stays put across Spaces and full-screen apps, and remembers where you left it.
@MainActor enum Overlay {
    /// Handed over by the menu bar label, like `WindowOpener.open`.
    static var store: UsageStore?
    private static var panel: OverlayPanel?

    static var isShown: Bool { panel?.isVisible == true }

    static func toggle() { isShown ? hide() : show() }

    static func show() {
        guard let store else { return }
        if panel == nil {
            let p = OverlayPanel()
            let host = NSHostingController(rootView: OverlayView().environmentObject(store))
            host.sizingOptions = .preferredContentSize
            p.contentViewController = host
            host.view.layoutSubtreeIfNeeded()
            if !p.setFrameUsingName(OverlayPanel.autosaveName), let screen = NSScreen.main {
                // First run: top-right corner, clear of the menu bar.
                let v = screen.visibleFrame
                p.setFrameTopLeftPoint(NSPoint(x: v.maxX - p.frame.width - 16, y: v.maxY - 16))
            }
            p.setFrameAutosaveName(OverlayPanel.autosaveName)
            panel = p
        }
        // A saved spot can be off screen after a display is unplugged or rearranged.
        if let p = panel { p.setFrame(p.fittedOnScreen(p.frame), display: false) }
        panel?.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: Prefs.overlayShown)
    }

    /// Drags the panel by the pointer's movement since `start`; SwiftUI content swallows the
    /// mouse-down that `isMovableByWindowBackground` relies on, so dragging goes through here.
    static func drag(from start: inout (mouse: NSPoint, origin: NSPoint)?) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if start == nil { start = (mouse, panel.frame.origin) }
        guard let s = start else { return }
        panel.setFrameOrigin(NSPoint(x: s.origin.x + mouse.x - s.mouse.x, y: s.origin.y + mouse.y - s.mouse.y))
    }

    /// Settles the panel fully onto whichever screen it was dropped on.
    static func endDrag() {
        guard let panel else { return }
        panel.setFrame(panel.fittedOnScreen(panel.frame), display: true, animate: true)
    }

    static func hide() {
        panel?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: Prefs.overlayShown)
    }

    /// False when the overlay is hidden or covered (e.g. by a full-screen app on another Space).
    static func onScreen() -> Bool {
        guard let panel else { return false }
        return panel.isVisible && panel.occlusionState.contains(.visible)
    }
}

/// Borderless and non-activating, so clicking it never steals focus from the app you're working in.
final class OverlayPanel: NSPanel {
    static let autosaveName = "QuotaBarOverlay"

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }

    /// Content resizes keep the top edge fixed, so expanding grows downward from where you put it,
    /// then the result is kept on screen.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var r = frameRect
        if frameRect.size != frame.size, frame.height > 0 {
            r.origin.y = frame.maxY - r.height
            r = fittedOnScreen(r)
        }
        super.setFrame(r, display: flag)
        invalidateShadow()
    }

    /// `rect` moved inside the visible area of the screen it overlaps most, top edge first when too tall.
    func fittedOnScreen(_ rect: NSRect) -> NSRect {
        let area = { (s: NSScreen) -> CGFloat in let i = s.visibleFrame.intersection(rect); return i.isNull ? 0 : i.width * i.height }
        guard let screen = NSScreen.screens.max(by: { area($0) < area($1) }).flatMap({ area($0) > 0 ? $0 : nil }) ?? NSScreen.main else { return rect }
        let v = screen.visibleFrame
        var r = rect
        r.origin.x = min(max(r.minX, v.minX), v.maxX - r.width)
        r.origin.y = max(min(r.minY, v.maxY - r.height), v.minY)
        if r.height > v.height { r.origin.y = v.maxY - r.height }
        return r
    }
}

struct OverlayView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.overlayExpanded) private var expanded = false
    @State private var contentHeight: CGFloat = 0
    @State private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 10) {
            header
            LockGate(compact: true, autoUnlock: false) {
                if expanded { full } else { compact }
            }
        }
        .padding(12)
        .frame(width: expanded ? 380 : 340)
        .background(BehindWindowBlur(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1)))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { _ in Overlay.drag(from: &dragStart) }
            .onEnded { _ in dragStart = nil; Overlay.endDrag() })
        // See-through while you work; solid again under the pointer.
        .opacity(hovering || dragStart != nil ? 1 : 0.72)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .animation(.smooth(duration: 0.25), value: expanded)
        .modifier(LiveRefresh(store: store, onScreen: Overlay.onScreen))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(store.advice?.best?.kind.tint ?? .secondary).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(store.locked ? "QuotaBar" : store.advice?.headline ?? "QuotaBar")
                    .font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                UpdatedLabel()
            }
            Spacer(minLength: 4)
            IconButton(symbol: "arrow.clockwise", help: "Refresh", spinning: store.isRefreshing) {
                Task { await store.refresh() }
            }
            IconButton(symbol: expanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                       help: expanded ? "Show summary" : "Show full details") { expanded.toggle() }
            IconButton(symbol: "rectangle.grid.2x2", help: "Open Dashboard") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            IconButton(symbol: "xmark", help: "Hide overlay") { Overlay.hide() }
        }
    }

    @ViewBuilder private var compact: some View {
        let accounts = store.orderedAccounts
        VStack(spacing: 8) {
            ForEach(Array(accounts.enumerated()), id: \.element.0.id) { i, item in
                if i > 0 { Divider().opacity(0.5) }
                AccountLine(account: item.0, state: item.1,
                            status: store.advice?.ranking.first { $0.id == item.0.id }?.status)
            }
            if accounts.isEmpty {
                Text("No accounts yet. Sign in to Claude Code or Codex.").font(.caption).foregroundStyle(.secondary)
            }
            if let first = store.advice?.warnings.first {
                Label(first.text, systemImage: "exclamationmark.circle.fill")
                    .font(.caption).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .symbolRenderingMode(.multicolor)
            }
        }
    }

    /// Every card from the Dashboard, scrolling once it would pass most of the screen's height.
    private var full: some View {
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) * 0.75
        return ScrollView {
            fullContent
                .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        }
        .scrollIndicators(.automatic)
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
    }

    private var fullContent: some View {
        let warnings = store.advice?.warnings ?? []
        let accounts = Array(store.orderedAccounts.enumerated())
        return VStack(alignment: .leading, spacing: 10) {
            if let advice = store.advice { AdviceCard(advice: advice) }
            if !warnings.isEmpty { WarningsCard(warnings: warnings) }
            ForEach(accounts, id: \.element.0.id) { i, item in
                ProviderCard(account: item.0, state: item.1,
                             rank: store.advice?.ranking.first { $0.id == item.0.id }, order: i)
            }
            if !store.apiAccounts.isEmpty {
                SpendCard(accounts: store.apiAccounts, spends: store.spends, order: accounts.count)
            }
        }
    }
}

/// Blurs whatever is behind the window. SwiftUI materials only blend with the window's own contents.
private struct BehindWindowBlur: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
