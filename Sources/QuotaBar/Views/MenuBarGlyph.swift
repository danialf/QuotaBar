import SwiftUI

/// Rendered to a template NSImage for the status item, so it follows the menu bar's
/// light/dark appearance. Only opacity carries meaning here.
struct MenuBarGlyph: View {
    struct Item {
        let glyph: String
        let session: Double?
        let long: Double?
        let peak: Double?
        let recommended: Bool
    }

    let items: [Item]
    let style: MenuBarStyle
    /// Black for the template image; Settings previews it in the primary colour.
    var color: Color = .black

    var body: some View {
        Group {
            if items.isEmpty || style == .icon {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 14, weight: .medium))
            } else if style == .percent {
                HStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { i in
                        let item = items[i]
                        Text("\(item.glyph) \(item.peak.map { Fmt.percent($0) } ?? "–")")
                            .fontWeight(item.recommended ? .bold : .medium)
                    }
                }
                .font(.system(size: 12).monospacedDigit())
            } else {
                HStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { i in bars(items[i]) }
                }
            }
        }
        .foregroundStyle(color)
        .frame(height: 18)
        .padding(.horizontal, 1)
    }

    private func bars(_ item: Item) -> some View {
        HStack(spacing: 2.5) {
            Text(item.glyph)
                .font(.system(size: item.glyph.count > 1 ? 9.5 : 10.5, weight: item.recommended ? .heavy : .semibold, design: .rounded))
            VStack(spacing: 2.5) {
                bar(item.session)
                bar(item.long)
            }
        }
    }

    private func bar(_ used: Double?) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.25).opacity(0.28)
            RoundedRectangle(cornerRadius: 1.25)
                .frame(width: 18 * min(1, max(0, (used ?? 0) / 100)))
        }
        .frame(width: 18, height: 4)
    }
}
