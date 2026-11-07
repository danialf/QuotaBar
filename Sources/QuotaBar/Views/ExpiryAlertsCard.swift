import SwiftUI

/// Unspent weekly (or longer) quota about to reset, soonest first. Sits at the top of every
/// surface so a full reset is never missed: a warning inside 72 hours, bolder inside 48,
/// a red alert inside 24.
struct ExpiryAlertsCard: View {
    let alerts: [ExpiryAlerts.Alert]
    /// One line per alert, for the floating overlay.
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 6 : 8) {
            ForEach(alerts) { ExpiryAlertRow(alert: $0, compact: compact) }
        }
    }
}

private struct ExpiryAlertRow: View {
    let alert: ExpiryAlerts.Alert
    let compact: Bool

    private var level: ExpiryAlerts.Level { alert.level }

    private var tint: Color {
        switch level {
        case .warning: .yellow
        case .urgent: .orange
        case .critical: .red
        }
    }

    private var symbol: String {
        switch level {
        case .warning: "clock.badge.exclamationmark"
        case .urgent: "exclamationmark.triangle.fill"
        case .critical: "alarm.waves.left.and.right.fill"
        }
    }

    private var headlineWeight: Font.Weight {
        switch level {
        case .warning: .medium
        case .urgent: .bold
        case .critical: .heavy
        }
    }

    private var name: String { "\(alert.account.shortName) \(alert.window.label.lowercased())" }

    var body: some View {
        // Re-render on a clock so the countdown moves between refreshes.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let left = max(0, alert.resetsAt.timeIntervalSince(context.date))
            Group {
                if compact { line(left: left) } else { full(left: left) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(level.word): \(name) resets in \(Fmt.duration(left)), \(Fmt.percent(alert.unused)) unused")
        }
    }

    private func line(left: TimeInterval) -> some View {
        Label {
            (Text("\(name) resets in \(Fmt.duration(left))").fontWeight(headlineWeight)
                + Text(" · \(Fmt.percent(alert.unused)) unused").foregroundStyle(.secondary))
                .lineLimit(1)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func full(left: TimeInterval) -> some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                Circle().fill(tint.opacity(level == .critical ? 0.95 : 0.2))
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(level == .critical ? .white : tint)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(level.word.uppercased()) · RESETS IN \(Fmt.duration(left).uppercased())")
                    .font(.system(size: 9.5, weight: level == .warning ? .semibold : .heavy)).tracking(0.8)
                    .foregroundStyle(level == .warning ? .secondary : tint)
                Text("\(alert.account.title) \(alert.window.label.lowercased()) resets \(alert.resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                    .font(.system(size: level == .critical ? 15 : 14, weight: headlineWeight))
                    .fixedSize(horizontal: false, vertical: true)
                Text(advice)
                    .font(.callout.weight(level == .critical ? .semibold : .regular))
                    .foregroundStyle(level == .critical ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: alert.account.kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(alert.account.kind.tint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(background)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(borderOpacity), lineWidth: borderWidth))
    }

    private var advice: String {
        let unused = Fmt.percent(alert.unused)
        let saved = alert.stale ? " (saved reading — run it once to confirm)" : ""
        switch level {
        case .warning: return "\(unused) still unused\(saved). Plan to burn it before the reset."
        case .urgent: return "\(unused) still unused\(saved) — under 48 hours to spend it."
        case .critical: return "\(unused) unused\(saved) will be lost in under 24 hours. Burn it now."
        }
    }

    private var background: Double {
        switch level {
        case .warning: 0.07
        case .urgent: 0.12
        case .critical: 0.17
        }
    }

    private var borderOpacity: Double {
        switch level {
        case .warning: 0.35
        case .urgent: 0.6
        case .critical: 0.9
        }
    }

    private var borderWidth: CGFloat {
        switch level {
        case .warning: 1
        case .urgent: 1.5
        case .critical: 2
        }
    }
}
