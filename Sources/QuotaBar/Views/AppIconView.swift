import AppKit
import SwiftUI

/// The app icon: a three-segment gauge in the services' colours on a dark squircle.
/// `QuotaBar --make-icon <dir>` renders it as an .iconset for `iconutil`.
struct AppIconView: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                // Apple's grid: 824pt artwork centred on a 1024pt canvas.
                RoundedRectangle(cornerRadius: s * 0.1807, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.17, blue: 0.22), Color(red: 0.05, green: 0.05, blue: 0.08)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: s * 0.1807, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom),
                                          lineWidth: s * 0.006)
                    )
                    .frame(width: s * 0.805, height: s * 0.805)
                    .shadow(color: .black.opacity(0.35), radius: s * 0.02, y: s * 0.012)

                gauge(size: s * 0.56)
                    .offset(y: s * 0.035)
            }
            .frame(width: s, height: s)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func gauge(size: CGFloat) -> some View {
        let line = size * 0.12
        let segments: [(Color, Double, Double)] = [
            // Round caps reach ~0.02 past each end, so leave clear gaps between segments.
            (ProviderID.claude.tint, 0.020, 0.185),
            (ProviderID.codex.tint, 0.245, 0.410),
            (ProviderID.zai.tint, 0.470, 0.635),
        ]
        return ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .trim(from: segments[i].1, to: segments[i].2)
                    .stroke(segments[i].0.gradient, style: StrokeStyle(lineWidth: line, lineCap: .round))
            }
            Capsule()
                .fill(.white)
                .frame(width: size * 0.05, height: size * 0.40)
                .offset(y: -size * 0.17)
                .rotationEffect(.degrees(250)) // up and to the right, into the green-blue zone
                .shadow(color: .black.opacity(0.4), radius: size * 0.02)
            Circle().fill(.white).frame(width: size * 0.15, height: size * 0.15)
            Circle().fill(Color(red: 0.1, green: 0.1, blue: 0.14)).frame(width: size * 0.06, height: size * 0.06)
        }
        .rotationEffect(.degrees(-208)) // open at the bottom
        .frame(width: size, height: size)
    }

    @MainActor static func writeIconset(to dir: String) {
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let r = ImageRenderer(content: AppIconView().frame(width: CGFloat(points), height: CGFloat(points)))
                r.scale = CGFloat(scale)
                guard let cg = r.cgImage else { continue }
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
                try? data?.write(to: url.appending(path: name))
            }
        }
        print("wrote \(dir)")
    }
}
