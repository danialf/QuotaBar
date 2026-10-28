import SwiftUI

/// Opens SwiftUI windows from AppKit callbacks (Dock clicks), which have no `openWindow`.
/// The menu bar label is always alive, so it hands its action over on appear.
@MainActor enum WindowOpener {
    static var open: OpenWindowAction?

    static func show(_ id: String) {
        open?(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var headless: Bool {
        CommandLine.arguments.contains { ["--dump", "--snapshot", "--make-icon", "--agents"].contains($0) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.register()
        // Info.plist says LSUIElement (menu-bar only); the Dock icon is opt-out at runtime.
        NSApp.setActivationPolicy(!Self.headless && UserDefaults.standard.bool(forKey: Prefs.showInDock) ? .regular : .accessory)
        if let i = CommandLine.arguments.firstIndex(of: "--make-icon"), i + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[i + 1]
            Task { @MainActor in AppIconView.writeIconset(to: dir); exit(0) }
        }
        if CommandLine.arguments.contains("--dump") { Task { await Self.dump(); exit(0) } }
        if CommandLine.arguments.contains("--agents") { Task { await Self.agents(); exit(0) } }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            Task { await Self.snapshot(to: path); exit(0) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.headless, UserDefaults.standard.bool(forKey: Prefs.showInDock) else { return }
        // Opened by hand (Finder, Dock, Spotlight) the app comes up active; as a login item it
        // doesn't, and then shouldn't put a window, or a Touch ID prompt, in front of you.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if NSApp.isActive { Task { @MainActor in WindowOpener.show("dashboard") } }
        }
    }

    /// Clicking the Dock icon with no window open shows the Dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Task { @MainActor in WindowOpener.show("dashboard") } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// `QuotaBar --snapshot out.png`: render the popover offscreen after one refresh.
    @MainActor private static func snapshot(to path: String) async {
        let store = UsageStore()
        await store.refresh()
        // Two scans, so CPU has an interval to measure over.
        await AgentMonitor.shared.scanNow()
        try? await Task.sleep(for: .seconds(2))
        await AgentMonitor.shared.scanNow()
        let views: [(String, AnyView)] = [
            ("brief", AnyView(BriefView(snapshotMode: true))),
            ("dashboard", AnyView(DashboardView(snapshotMode: true).frame(width: 820))),
        ] + SettingsView.Pane.allCases.map { ("settings-\($0.rawValue)", AnyView(SettingsView(snapshotMode: true, pane: $0).frame(width: 900))) }
        for (name, base) in views {
            let scheme = ColorScheme.dark
            let view = base.environmentObject(store)
                .environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let cg = r.cgImage else { print("render failed"); continue }
            let out = path.replacingOccurrences(of: ".png", with: "-\(name).png")
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            print("wrote \(out) \(cg.width)x\(cg.height)")
        }
    }

    /// `QuotaBar --agents`: scan running agents twice, 3s apart, and print them by project.
    @MainActor private static func agents() async {
        let monitor = AgentMonitor.shared
        let start = Date.now
        await monitor.scanNow()
        print("scan took \(Int(Date.now.timeIntervalSince(start) * 1000))ms")
        try? await Task.sleep(for: .seconds(3))
        let again = Date.now
        await monitor.scanNow()
        print("rescan took \(Int(Date.now.timeIntervalSince(again) * 1000))ms")
        for p in monitor.projects {
            print("\(p.name)  [\(p.path)]  \(p.working)/\(p.sessions.count) working")
            for s in p.sessions {
                let cpu = String(format: "%.1f%%", s.cpu * 100)
                print("   \(s.kind.name) pid \(s.pid)  \(s.provider?.shortName ?? "-")  \(s.accountID ?? "")  \(s.place ?? "")  cpu \(cpu)  children \(s.children)  up \(Fmt.duration(Date.now.timeIntervalSince(s.started)))")
            }
        }
    }

    /// `QuotaBar --dump`: fetch everything once and print it, for checking sources from a terminal.
    @MainActor private static func dump() async {
        let store = UsageStore()
        await store.refresh()
        for (a, state) in store.orderedAccounts {
            print("\(a.title)  [\(a.detail ?? "-")]  \(state.snapshot?.plan ?? "")")
            switch state {
            case .ok(let s):
                for w in s.windows {
                    let reset = w.timeToReset().map { "resets in \(Fmt.duration($0))" } ?? ""
                    print("   \(w.label): \(Fmt.percent(w.usedPercent)) \(w.creditText ?? "") \(reset)")
                }
                if let note = s.note { print("   note: \(note)") }
                if let r = s.resets { print("   resets: \(r.text)") }
            case .failed(let msg): print("   error: \(msg)")
            default: print("   (no data)")
            }
        }
        for s in store.okSpends { print("API \(s.account.name): \(Fmt.money(s.monthToDate)) this month") }
        if let advice = store.advice {
            print("\n→ \(advice.headline): \(advice.detail)")
            for r in advice.ranking { print("   \(r.account.shortName) score \(Int(r.score)) — \(r.note)") }
            for w in advice.warnings { print("   ⚠ \(w.text)") }
        }
    }
}

@main
struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            BriefView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(image: store.menuBarImage, store: store)
        }
        .menuBarExtraStyle(.window)

        Window("QuotaBar", id: "dashboard") {
            DashboardView()
                .environmentObject(store)
        }
        .defaultSize(width: 820, height: 900)
        .defaultLaunchBehavior(.suppressed)
        .commands { AppCommands(store: store) }

        Window("QuotaBar Settings", id: "settings") {
            SettingsView()
                .environmentObject(store)
        }
        .defaultSize(width: 900, height: 700)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

private struct MenuBarLabel: View {
    let image: NSImage
    let store: UsageStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: image)
            .onAppear {
                WindowOpener.open = openWindow
                Overlay.store = store
                if !AppDelegate.headless, UserDefaults.standard.bool(forKey: Prefs.overlayShown) { Overlay.show() }
            }
    }
}

/// Menu bar commands while QuotaBar is the active app (Dock mode).
private struct AppCommands: Commands {
    let store: UsageStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "settings") }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Usage") {
            Button("Dashboard") { openWindow(id: "dashboard") }.keyboardShortcut("1")
            Button("Floating Overlay") { Overlay.toggle() }.keyboardShortcut("2")
            Button("Refresh") { Task { await store.refresh() } }.keyboardShortcut("r")
            Divider()
            Button("Lock QuotaBar") { store.lock() }.keyboardShortcut("l", modifiers: [.command, .control])
        }
    }
}
