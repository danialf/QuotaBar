import AppKit
import SwiftUI

/// Shows `content` only while QuotaBar is unlocked.
struct LockGate<Content: View>: View {
    @EnvironmentObject private var store: UsageStore
    var enabled = true
    var compact = false
    var autoUnlock = true
    @ViewBuilder var content: Content

    var body: some View {
        if !enabled || !store.locked {
            content
        } else {
            LockedView(compact: compact, autoUnlock: autoUnlock)
        }
    }
}

struct LockedView: View {
    @EnvironmentObject private var store: UsageStore
    var compact = false
    /// Prompt for Touch ID as soon as this appears. The overlay waits for a click instead,
    /// since it can come up on its own at login.
    var autoUnlock = true
    @State private var attempted = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(spacing: compact ? 10 : 14) {
            Image(systemName: "touchid")
                .font(.system(size: compact ? 34 : 46, weight: .light))
                .foregroundStyle(store.advice?.best?.kind.tint ?? .accentColor)
                .symbolEffect(.pulse, options: .repeating, isActive: store.unlocking && !reduce)
            Text("QuotaBar is locked").font(.system(size: compact ? 14 : 17, weight: .semibold))
            Text("Use Touch ID to see usage and keys.")
                .font(.callout).foregroundStyle(.secondary)
            Button {
                Task { await unlock() }
            } label: {
                Label("Unlock with Touch ID", systemImage: "touchid").frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.unlocking)
            if let error = store.unlockError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(compact ? 22 : 32)
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
        .onAppear {
            store.touch()
            guard autoUnlock, !attempted else { return }
            attempted = true
            Task { await unlock() }
        }
    }

    private func unlock() async {
        await store.unlock()
        // The Touch ID sheet takes focus and closes the dropdown; bring it back once unlocked.
        if compact, autoUnlock, !store.locked { StatusItem.reopen() }
    }
}

enum StatusItem {
    /// Clicks QuotaBar's own status item, re-opening the MenuBarExtra panel.
    @MainActor static func reopen() {
        for window in NSApp.windows where window.className.contains("StatusBarWindow") {
            if let button = find(in: window.contentView) { button.performClick(nil); return }
        }
    }

    /// Closes the MenuBarExtra panel if it is open.
    @MainActor static func closePanel() {
        for window in NSApp.windows where window is NSPanel && window.isVisible && window.className.contains("MenuBarExtra") {
            window.close()
        }
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let b = view as? NSStatusBarButton { return b }
        for sub in view.subviews { if let b = find(in: sub) { return b } }
        return nil
    }
}
