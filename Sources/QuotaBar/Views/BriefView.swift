import SwiftUI

/// The menu-bar dropdown: the recommendation and one line per account. Everything else
/// lives in the dashboard window.
struct BriefView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    var snapshotMode = false

    var body: some View {
        LockGate(enabled: !snapshotMode, compact: true) { brief }
            .frame(width: 380)
            .modifier(Presence(store: store, panel: !snapshotMode))
    }

    @ViewBuilder private var brief: some View {
        let accounts = store.orderedAccounts
        let warnings = store.advice?.warnings ?? []
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("QuotaBar").font(.system(size: 14, weight: .semibold))
                UpdatedLabel()
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh", spinning: store.isRefreshing) {
                    Task { await store.refresh() }
                }
            }
            if let advice = store.advice {
                AdviceCard(advice: advice).entrance(0)
            }
            Card {
                ForEach(Array(accounts.enumerated()), id: \.element.0.id) { i, item in
                    if i > 0 { Divider().opacity(0.5) }
                    AccountLine(account: item.0, state: item.1,
                                status: store.advice?.ranking.first { $0.id == item.0.id }?.status,
                                delay: 0.12 + 0.05 * Double(i))
                }
                if accounts.isEmpty {
                    Text("No accounts yet. Sign in to Claude Code or Codex.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Divider().opacity(0.5)
                    PulseLine()
                }
            }
            .entrance(1)
            if !warnings.isEmpty {
                Button(action: openDashboard) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(warnings.count == 1 ? warnings[0].text : "\(warnings.count) warnings — \(warnings[0].text)")
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .entrance(2)
            }
            HStack(spacing: 8) {
                Button(action: openDashboard) {
                    Label("Open Dashboard", systemImage: "rectangle.grid.2x2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(store.advice?.best?.kind.tint ?? .accentColor)
                IconButton(symbol: "gearshape", help: "Settings") {
                    StatusItem.closePanel()
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                IconButton(symbol: "pip", help: "Toggle floating overlay") {
                    StatusItem.closePanel()
                    Overlay.toggle()
                }
                IconButton(symbol: "lock", help: "Lock QuotaBar") { store.lock() }
                IconButton(symbol: "power", help: "Quit QuotaBar") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
    }

    private func openDashboard() {
        StatusItem.closePanel()
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// One account as a single row: name, plan, and its short and long windows side by side.
struct AccountLine: View {
    let account: Account
    let state: ProviderState
    let status: Advisor.Status?
    var delay = 0.0

    var body: some View {
        let tint = account.kind.tint
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: account.kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(account.kind == .claude ? account.label : account.kind.shortName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    if state.snapshot?.staleReason != nil {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 9)).foregroundStyle(.orange)
                            .help(state.snapshot?.staleReason ?? "")
                    }
                }
                Text(subtitle).font(.caption2).foregroundStyle(isError ? .orange : .secondary).lineLimit(1)
            }
            .frame(width: 92, alignment: .leading)

            switch state {
            case .ok(let snap):
                let short = snap.shortest, long = snap.longest
                if let short { Meter(window: short, tint: tint, delay: delay) }
                if let long, long.id != short?.id {
                    Meter(window: long, tint: tint, delay: delay + 0.06)
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            case .loading:
                SkeletonBar(height: 6)
            case .failed(let msg):
                Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .disabled:
                EmptyView()
            }

            Circle().fill(dotColor).frame(width: 6, height: 6)
                .help(status.map { $0 == .go ? "Available" : $0 == .caution ? "Low" : "Capped" } ?? "")
        }
        .padding(.vertical, 1)
    }

    private var isError: Bool {
        if case .failed = state { return true }
        return false
    }

    private var subtitle: String {
        switch state {
        case .failed: return "Needs attention"
        case .loading: return "Loading…"
        default: return state.snapshot?.plan ?? account.kind.shortName
        }
    }

    private var dotColor: Color {
        switch status {
        case .go?: .green
        case .caution?: .orange
        case .blocked?: .red
        case nil: .secondary.opacity(0.4)
        }
    }
}

private struct Meter: View {
    let window: UsageWindow
    let tint: Color
    var delay = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(tag).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(Fmt.percent(window.usedPercent))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(UsageColor.color(window.usedPercent, tint: tint))
            }
            QuotaProgress(used: window.usedPercent, pace: window.elapsedFraction().map { $0 * 100 }, tint: tint, delay: delay)
            Text(window.timeToReset().map { "↻ \(Fmt.duration($0))" } ?? " ")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .help("\(window.label): \(Fmt.percent(window.usedPercent)) used")
    }

    private var tag: String {
        guard let d = window.duration else { return window.label }
        if d <= 6 * 3600 { return "5h" }
        if d <= 8 * 86400 { return window.label.contains("·") && !window.label.contains("all") ? window.label.replacingOccurrences(of: "Weekly · ", with: "Wk ") : "Week" }
        return "Month"
    }
}
