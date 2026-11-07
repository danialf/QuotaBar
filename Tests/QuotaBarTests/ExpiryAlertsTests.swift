import XCTest
@testable import QuotaBar

final class ExpiryAlertsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3600

    func snap(_ p: ProviderID, used: Double, resetIn: TimeInterval, length: TimeInterval = 7 * 86400) -> ProviderSnapshot {
        ProviderSnapshot(account: Account(id: p.rawValue, kind: p, label: p.shortName), planCode: nil, windows: [
            UsageWindow(label: "Session · 5h", usedPercent: 10, resetsAt: now.addingTimeInterval(hour), duration: 5 * hour),
            UsageWindow(label: "Weekly", usedPercent: used, resetsAt: now.addingTimeInterval(resetIn), duration: length),
        ])
    }

    func level(resetIn: TimeInterval) -> ExpiryAlerts.Level? {
        ExpiryAlerts.evaluate([snap(.codex, used: 40, resetIn: resetIn)], now: now).first?.level
    }

    func testLevelsEscalateAt72_48_24Hours() {
        XCTAssertNil(level(resetIn: 73 * hour))
        XCTAssertNil(level(resetIn: 72 * hour))
        XCTAssertEqual(level(resetIn: 71.9 * hour), .warning)
        XCTAssertEqual(level(resetIn: 48.1 * hour), .warning)
        XCTAssertEqual(level(resetIn: 47.9 * hour), .urgent)
        XCTAssertEqual(level(resetIn: 24.1 * hour), .urgent)
        XCTAssertEqual(level(resetIn: 23.9 * hour), .critical)
        XCTAssertEqual(level(resetIn: 60), .critical)
        XCTAssertNil(level(resetIn: -60))
    }

    func testSessionWindowsNeverAlert() {
        // The 5-hour session always resets within a day; only the weekly window may alert.
        let alerts = ExpiryAlerts.evaluate([snap(.codex, used: 40, resetIn: 5 * 86400)], now: now)
        XCTAssertTrue(alerts.isEmpty)
    }

    func testNothingLeftToBurnDoesNotAlert() {
        XCTAssertTrue(ExpiryAlerts.evaluate([snap(.codex, used: 99, resetIn: 10 * hour)], now: now).isEmpty)
        XCTAssertEqual(ExpiryAlerts.evaluate([snap(.codex, used: 0, resetIn: 10 * hour)], now: now).first?.unused, 100)
    }

    func testMonthlyWindowsAlertToo() {
        let alerts = ExpiryAlerts.evaluate([snap(.kimi, used: 20, resetIn: 30 * hour, length: 30 * 86400)], now: now)
        XCTAssertEqual(alerts.first?.level, .urgent)
    }

    func testSoonestResetFirst() {
        let alerts = ExpiryAlerts.evaluate([
            snap(.claude, used: 10, resetIn: 60 * hour),
            snap(.codex, used: 10, resetIn: 5 * hour),
        ], now: now)
        XCTAssertEqual(alerts.map(\.account.kind), [.codex, .claude])
    }

    func testWindowsResettingTogetherMakeOneAlertForTheTightest() {
        let reset = now.addingTimeInterval(18 * hour)
        let snap = ProviderSnapshot(account: Account(id: "max03", kind: .claude, label: "Max03"), planCode: nil, windows: [
            UsageWindow(label: "Weekly · all models", usedPercent: 71, resetsAt: reset, duration: 7 * 86400),
            UsageWindow(label: "Weekly · Fable", usedPercent: 3, resetsAt: reset, duration: 7 * 86400),
        ])
        let alerts = ExpiryAlerts.evaluate([snap], now: now)
        XCTAssertEqual(alerts.map(\.window.label), ["Weekly · all models"])
        XCTAssertEqual(alerts.first?.unused, 29)
    }

    func testSpentWindowSilencesItsSiblings() {
        // All-models is capped, so the Fable week's headroom can't be used either.
        let reset = now.addingTimeInterval(18 * hour)
        let snap = ProviderSnapshot(account: Account(id: "max03", kind: .claude, label: "Max03"), planCode: nil, windows: [
            UsageWindow(label: "Weekly · all models", usedPercent: 100, resetsAt: reset, duration: 7 * 86400),
            UsageWindow(label: "Weekly · Fable", usedPercent: 3, resetsAt: reset, duration: 7 * 86400),
        ])
        XCTAssertTrue(ExpiryAlerts.evaluate([snap], now: now).isEmpty)
    }

    func testSavedReadingIsFlagged() {
        var s = snap(.claude, used: 0, resetIn: 30 * hour)
        s.staleReason = "Login idle"
        XCTAssertEqual(ExpiryAlerts.evaluate([s], now: now).first?.stale, true)
    }
}
