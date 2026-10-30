import SwiftUI

// MARK: - Next reset

/// The upcoming resets as a countdown ring, a left-to-right timeline, or both, per Settings.
struct NextResetCard: View {
    @EnvironmentObject private var store: UsageStore
    @AppStorage(Prefs.resetView) private var style = ResetViewStyle.both.rawValue
    var more = 3
    /// Ring and timeline side by side rather than stacked, with wider timeline stops.
    var wide = false

    var body: some View {
        let style = ResetViewStyle(rawValue: style) ?? .both
        if style != .none {
            // Re-render on a clock so the countdowns move between refreshes.
            TimelineView(.periodic(from: .now, by: 20)) { context in
                let entries = ResetSchedule.upcoming(store.orderedAccounts.compactMap { $0.1.snapshot }, now: context.date)
                Card {
                    if let first = entries.first {
                        switch style {
                        case .ring:
                            ringWithList(first, rest: Array(entries.dropFirst().prefix(more)), now: context.date)
                        case .timeline:
                            timeline(entries, now: context.date)
                        default:
                            let layout = wide ? AnyLayout(HStackLayout(alignment: .center, spacing: 18)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                            layout {
                                ringHeader(first, now: context.date).frame(maxWidth: wide ? 300 : .infinity)
                                Divider().opacity(0.5)
                                timeline(entries, now: context.date)
                            }
                        }
                    } else {
                        Label("No reset scheduled", systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func ringHeader(_ first: ResetSchedule.Entry, now: Date) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ResetRing(entry: first, now: now)
            VStack(alignment: .leading, spacing: 3) {
                Text("NEXT RESET").font(.system(size: 9.5, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                Text("\(first.account.shortName) · \(first.window.label)")
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text("Frees \(Fmt.percent(first.window.usedPercent)) at \(first.resetsAt, format: .dateTime.hour().minute())")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func ringWithList(_ first: ResetSchedule.Entry, rest: [ResetSchedule.Entry], now: Date) -> some View {
        let layout = wide ? AnyLayout(HStackLayout(alignment: .center, spacing: 18)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        return layout {
            ringHeader(first, now: now).frame(maxWidth: wide ? 340 : .infinity)
            if !rest.isEmpty {
                Divider().opacity(0.5)
                VStack(spacing: 5) {
                    ForEach(rest) { e in ResetRow(entry: e, now: now) }
                }
            }
        }
    }

    private func timeline(_ entries: [ResetSchedule.Entry], now: Date) -> some View {
        let stops = ResetSchedule.stops(entries)
        // As many stops as fit the width, soonest first.
        return ViewThatFits(in: .horizontal) {
            ForEach((1...max(1, min(more + 1, stops.count))).reversed(), id: \.self) { n in
                ResetTimeline(stops: Array(stops.prefix(n)), now: now, stopWidth: wide ? 112 : 88)
            }
        }
    }
}

private struct ResetRing: View {
    let entry: ResetSchedule.Entry
    let now: Date

    var body: some View {
        let tint = entry.account.kind.tint
        let elapsed = entry.window.elapsedFraction(now: now) ?? 0
        ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.01, elapsed))
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.6), value: elapsed)
            VStack(spacing: 0) {
                Text(Fmt.duration(entry.resetsAt.timeIntervalSince(now)))
                    .font(.system(size: 13.5, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("to go").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
        }
        .frame(width: 66, height: 66)
        .help("\(Int((elapsed * 100).rounded()))% through this window")
    }
}

private struct ResetRow: View {
    let entry: ResetSchedule.Entry
    let now: Date

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(entry.account.kind.tint).frame(width: 6, height: 6)
            Text(entry.account.shortName).font(.caption.weight(.medium)).lineLimit(1)
            Text(entry.window.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(Fmt.percent(entry.window.usedPercent)).font(.caption).monospacedDigit()
                .foregroundStyle(entry.window.usedPercent >= 95 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            Text("in \(Fmt.duration(entry.resetsAt.timeIntervalSince(now)))")
                .font(.caption.weight(.medium)).monospacedDigit()
                .frame(minWidth: 62, alignment: .trailing)
        }
    }
}

private struct ResetTimeline: View {
    let stops: [ResetSchedule.Stop]
    let now: Date
    let stopWidth: CGFloat

    /// Height of the date/time labels above the line; the line runs through the dots just below.
    private let head: CGFloat = 30
    private let dot: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            NowStop(now: now, head: head, dot: dot).frame(width: stopWidth * 0.6)
            ForEach(Array(stops.enumerated()), id: \.element.id) { i, stop in
                Gap(seconds: stop.resetsAt.timeIntervalSince(i == 0 ? now : stops[i - 1].resetsAt), head: head, dot: dot)
                ResetStop(stop: stop, now: now, first: i == 0, head: head, dot: dot).frame(width: stopWidth)
            }
            Gap(seconds: nil, head: head, dot: dot).frame(maxWidth: 22)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The stretch of line between two stops, labelled with how long it is.
private struct Gap: View {
    let seconds: TimeInterval?
    let head: CGFloat
    let dot: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Text(seconds.map { "+\(Fmt.duration($0))" } ?? " ")
                .font(.system(size: 9.5, weight: .medium)).monospacedDigit().foregroundStyle(.tertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(height: head, alignment: .bottom).padding(.bottom, 2)
            ZStack(alignment: .trailing) {
                Rectangle().fill(.primary.opacity(0.18)).frame(height: 2)
                if seconds == nil {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.primary.opacity(0.25))
                }
            }
            .frame(height: dot)
        }
        .frame(minWidth: 16, maxWidth: .infinity)
    }
}

private struct NowStop: View {
    let now: Date
    let head: CGFloat
    let dot: CGFloat

    var body: some View {
        VStack(spacing: 2) {
            VStack(spacing: 0) {
                Text("Now").font(.system(size: 11, weight: .semibold))
                Text(now, format: .dateTime.hour().minute()).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(height: head, alignment: .bottom)
            Lane(dot: dot) {
                Circle().fill(.primary.opacity(0.7)).frame(width: dot * 0.7, height: dot * 0.7)
            }
            Text(now, format: .dateTime.weekday(.abbreviated).day()).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct ResetStop: View {
    let stop: ResetSchedule.Stop
    let now: Date
    let first: Bool
    let head: CGFloat
    let dot: CGFloat

    var body: some View {
        let tint = stop.entries[0].account.kind.tint
        VStack(spacing: 2) {
            VStack(spacing: 0) {
                Text(stop.resetsAt, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Text(stop.resetsAt, format: .dateTime.hour().minute())
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(height: head, alignment: .bottom)
            Lane(dot: dot) {
                ZStack {
                    if first { Circle().fill(tint.opacity(0.25)).frame(width: dot + 6, height: dot + 6) }
                    Circle().fill(tint).frame(width: dot, height: dot)
                    Circle().strokeBorder(.background, lineWidth: 2).frame(width: dot, height: dot)
                }
            }
            Text("in \(Fmt.duration(stop.resetsAt.timeIntervalSince(now)))")
                .font(.system(size: 10.5, weight: first ? .bold : .semibold)).monospacedDigit()
                .foregroundStyle(first ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
            VStack(spacing: 1) {
                ForEach(stop.entries.prefix(3)) { e in
                    VStack(spacing: 0) {
                        Text(e.account.shortName).font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(e.account.kind.tint)
                        Text("\(e.window.label) · \(Fmt.percent(e.window.usedPercent))")
                            .font(.system(size: 9.5)).monospacedDigit()
                            .foregroundStyle(e.window.usedPercent >= 95 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                    .lineLimit(1).minimumScaleFactor(0.75)
                }
                if stop.entries.count > 3 {
                    Text("+\(stop.entries.count - 3) more").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 2)
        .help(stop.entries.map { "\($0.account.shortName) · \($0.window.label): frees \(Fmt.percent($0.window.usedPercent))" }.joined(separator: "\n"))
    }
}

/// A stop's dot on the line, with the line running through it so the timeline reads as one stroke.
private struct Lane<Marker: View>: View {
    let dot: CGFloat
    @ViewBuilder var marker: Marker

    var body: some View {
        ZStack {
            Rectangle().fill(.primary.opacity(0.18)).frame(height: 2)
            marker
        }
        .frame(height: dot)
    }
}

// MARK: - Agents

/// Which agents are running, in which projects, and how the work is spread across them.
struct AgentsCard: View {
    @EnvironmentObject private var store: UsageStore
    @ObservedObject private var monitor = AgentMonitor.shared
    var fieldHeight: CGFloat = 200
    /// The project list beside the bubbles rather than under them.
    var wide = false

    var body: some View {
        let projects = monitor.projects
        let working = monitor.sessions.filter(\.isWorking).count
        Card {
            HStack(spacing: 6) {
                Image(systemName: "circle.hexagongrid").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Text("Agents").font(.system(size: 13, weight: .semibold))
                Spacer()
                if monitor.scanned, !monitor.sessions.isEmpty {
                    Text("\(working) working · \(monitor.sessions.count) running · \(projects.count) \(projects.count == 1 ? "project" : "projects")")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if !monitor.scanned {
                SkeletonBar().padding(.vertical, 2)
            } else if projects.isEmpty {
                Text("No coding agents running.").font(.caption).foregroundStyle(.secondary)
            } else {
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 18)) : AnyLayout(VStackLayout(spacing: 10))
                layout {
                    BubbleField(projects: projects).frame(height: fieldHeight).frame(maxWidth: wide ? 340 : .infinity)
                    VStack(spacing: 8) {
                        ForEach(projects) { p in ProjectRow(project: p, accounts: store.accounts) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .task { await monitor.watch() }
    }
}

/// One bubble per project: area follows how many agents are there and how hard they are working.
/// Dots on the rim are the agents, solid while working and hollow while waiting at a prompt.
struct BubbleField: View {
    let projects: [AgentProject]

    var body: some View {
        GeometryReader { geo in
            let layout = Self.layout(projects, in: geo.size)
            ZStack {
                ForEach(layout, id: \.project.id) { item in
                    ProjectBubble(project: item.project, radius: item.radius)
                        .position(item.center)
                }
            }
            .animation(.smooth(duration: 0.6), value: layout.map(\.radius))
        }
    }

    struct Placed {
        let project: AgentProject
        let center: CGPoint
        let radius: CGFloat
    }

    static func layout(_ projects: [AgentProject], in size: CGSize) -> [Placed] {
        guard !projects.isEmpty, size.width > 0, size.height > 0 else { return [] }
        // sqrt keeps area proportional to weight; the +1 keeps a lone idle agent's bubble big enough to name.
        let radii = projects.map { 10 * sqrt(1 + $0.weight) }
        let centers = BubblePacker.pack(radii, gap: 1.5)
        let minX = zip(centers, radii).map { $0.x - $1 }.min()!, maxX = zip(centers, radii).map { $0.x + $1 }.max()!
        let minY = zip(centers, radii).map { $0.y - $1 }.min()!, maxY = zip(centers, radii).map { $0.y + $1 }.max()!
        let pad: CGFloat = 4
        // Fit the cluster, but don't blow a lone small bubble up to fill the field.
        let scale = min((size.width - 2 * pad) / (maxX - minX), (size.height - 2 * pad) / (maxY - minY), 4.2)
        let mid = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        return projects.indices.map { i in
            Placed(project: projects[i],
                   center: CGPoint(x: size.width / 2 + (centers[i].x - mid.x) * scale, y: size.height / 2 + (centers[i].y - mid.y) * scale),
                   radius: radii[i] * scale)
        }
    }
}

private struct ProjectBubble: View {
    let project: AgentProject
    let radius: CGFloat

    var body: some View {
        let tint = project.tint
        let busy = project.working > 0
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(busy ? 0.42 : 0.16), tint.opacity(busy ? 0.18 : 0.06)],
                                     center: .center, startRadius: 0, endRadius: radius))
            Circle().strokeBorder(tint.opacity(busy ? 0.75 : 0.3), lineWidth: busy ? 1.5 : 1)
            ForEach(Array(project.sessions.enumerated()), id: \.element.id) { i, s in
                let angle = -Double.pi / 2 + Double(i) * 2 * .pi / Double(max(project.sessions.count, 1))
                let dot = min(9, max(5, radius * 0.14))
                let r = radius - dot / 2 - 4
                AgentDot(session: s, size: dot)
                    .offset(x: r * cos(angle), y: r * sin(angle))
            }
            if radius >= 22 {
                VStack(spacing: 1) {
                    Text(project.name)
                        .font(.system(size: min(13, max(9.5, radius * 0.24)), weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(busy ? "\(project.working)/\(project.sessions.count) working" : "\(project.sessions.count) idle")
                        .font(.system(size: min(10.5, max(8, radius * 0.17))))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(width: radius * 1.5)
            } else {
                Text("\(project.sessions.count)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
            }
        }
        .frame(width: radius * 2, height: radius * 2)
        .help("\(project.name) — \(project.path)")
    }
}

private struct AgentDot: View {
    let session: AgentSession
    let size: CGFloat

    var body: some View {
        let tint = session.provider?.tint ?? session.kind.tint
        Circle()
            .fill(session.isWorking ? tint : .clear)
            .overlay(Circle().strokeBorder(tint, lineWidth: 1.5))
            .frame(width: size, height: size)
    }
}

private struct ProjectRow: View {
    let project: AgentProject
    let accounts: [Account]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(project.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .frame(width: 96, alignment: .leading)
                .help(project.path)
            FlowLayout(spacing: 5) {
                ForEach(project.sessions) { s in AgentChip(session: s, accounts: accounts) }
            }
        }
    }
}

private struct AgentChip: View {
    let session: AgentSession
    let accounts: [Account]

    var body: some View {
        let tint = session.provider?.tint ?? session.kind.tint
        HStack(spacing: 4) {
            AgentDot(session: session, size: 6)
            Text(label).font(.caption2.weight(.medium)).lineLimit(1)
            if let place = session.place {
                Text(place).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Text(Fmt.duration(Date.now.timeIntervalSince(session.started)))
                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.horizontal, 6).padding(.vertical, 2.5)
        .background(Capsule().fill(tint.opacity(session.isWorking ? 0.16 : 0.07)))
        .help(help)
    }

    private var label: String {
        if let id = session.accountID, let account = accounts.first(where: { $0.id == id }) { return account.shortName }
        if let provider = session.provider, provider != session.kind.provider { return "\(session.kind.name) → \(provider.shortName)" }
        return session.kind.name
    }

    private var help: String {
        let state = session.isWorking ? "Working (\(Int((session.cpu * 100).rounded()))% CPU)" : "Idle"
        let kids = session.children > 0 ? " · \(session.children) child process\(session.children == 1 ? "" : "es")" : ""
        return "\(session.kind.name) · pid \(session.pid) · \(state)\(kids)"
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.items.isEmpty {
                rows.append(current)
                current = ([i], size.width, size.height)
            } else {
                current = (current.items + [i], needed, max(current.height, size.height))
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - One-line summary

/// "Claude 2 · Session resets in 1h 12m · 3 working in 2 projects", for the overlay and dropdown.
struct PulseLine: View {
    @EnvironmentObject private var store: UsageStore
    @ObservedObject private var monitor = AgentMonitor.shared
    var showAgents = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            let next = ResetSchedule.upcoming(store.orderedAccounts.compactMap { $0.1.snapshot }, now: context.date).first
            HStack(spacing: 6) {
                if let next {
                    Image(systemName: "arrow.counterclockwise.circle.fill").foregroundStyle(next.account.kind.tint)
                    (Text("\(next.account.shortName) \(next.window.label.lowercased()) resets in ")
                        + Text(Fmt.duration(next.resetsAt.timeIntervalSince(context.date))).fontWeight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if showAgents, monitor.scanned, !monitor.sessions.isEmpty {
                    let working = monitor.sessions.filter(\.isWorking).count
                    Circle().fill(working > 0 ? Color.green : Color.secondary).frame(width: 6, height: 6)
                    Text("\(working)/\(monitor.sessions.count) agents").foregroundStyle(.secondary).monospacedDigit()
                        .help(monitor.projects.map { "\($0.name): \($0.working)/\($0.sessions.count)" }.joined(separator: "\n"))
                }
            }
            .font(.caption)
        }
        .task { if showAgents { await monitor.watch() } }
    }
}
