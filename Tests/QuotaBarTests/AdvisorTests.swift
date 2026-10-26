import XCTest
@testable import QuotaBar

final class AdvisorTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func window(_ label: String, used: Double, resetIn: TimeInterval, length: TimeInterval) -> UsageWindow {
        UsageWindow(label: label, usedPercent: used, resetsAt: now.addingTimeInterval(resetIn), duration: length)
    }

    func account(_ p: ProviderID) -> Account { Account(id: p.rawValue, kind: p, label: p.shortName) }

    func snap(_ p: ProviderID, session: Double, weekly: Double, weeklyResetIn: TimeInterval) -> ProviderSnapshot {
        ProviderSnapshot(account: account(p), plan: nil, windows: [
            window("Session · 5h", used: session, resetIn: 3600, length: 5 * 3600),
            window("Weekly", used: weekly, resetIn: weeklyResetIn, length: 7 * 86400),
        ])
    }

    func testPrefersCapacityAboutToExpire() {
        let claude = snap(.claude, session: 10, weekly: 40, weeklyResetIn: 12 * 3600)   // 60% left, resets soon
        let codex = snap(.codex, session: 10, weekly: 30, weeklyResetIn: 6 * 86400)     // 70% left, plenty of time
        XCTAssertEqual(Advisor.evaluate([claude, codex], spends: [], now: now).best?.kind, .claude)
    }

    func testCappedProviderIsNeverRecommended() {
        let claude = snap(.claude, session: 100, weekly: 20, weeklyResetIn: 86400)
        let zai = snap(.zai, session: 50, weekly: 50, weeklyResetIn: 3 * 86400)
        let advice = Advisor.evaluate([claude, zai], spends: [], now: now)
        XCTAssertEqual(advice.best?.kind, .zai)
        XCTAssertEqual(advice.ranking.first { $0.account.kind == .claude }?.status, .blocked)
    }

    func testAllCappedReportsSoonestReturn() {
        let a = snap(.claude, session: 100, weekly: 50, weeklyResetIn: 86400)
        let advice = Advisor.evaluate([a], spends: [], now: now)
        XCTAssertNil(advice.best)
        XCTAssertTrue(advice.detail.contains("1h"), advice.detail)
    }

    func testWarnsWhenBurnRateHitsCapBeforeReset() {
        // 3.5 days into the week with 80% used: runs out ~0.9 days later, 2.6 days early.
        let codex = snap(.codex, session: 10, weekly: 80, weeklyResetIn: 3.5 * 86400)
        let claude = snap(.claude, session: 0, weekly: 0, weeklyResetIn: 3 * 86400)
        let advice = Advisor.evaluate([codex, claude], spends: [], now: now)
        XCTAssertTrue(advice.warnings.contains { $0.account == "codex" && $0.text.contains("Claude") })
    }

    func testCreditWindowNeverCaps() {
        var claude = snap(.claude, session: 20, weekly: 30, weeklyResetIn: 3 * 86400)
        claude.windows.append(UsageWindow(label: "Usage credit", usedPercent: 100, resetsAt: nil, duration: nil, creditText: "$250 of $250"))
        XCTAssertEqual(Advisor.evaluate([claude], spends: [], now: now).best?.kind, .claude)
    }

    func testAPIPickPrefersRemainingCredit() {
        let a = APIAccount(name: "Main", credit: 100, creditAsOf: now)
        let b = APIAccount(name: "GG", credit: 50, creditAsOf: now)
        let spends = [SpendSnapshot(account: a, monthToDate: 90, sinceCredit: 90),
                      SpendSnapshot(account: b, monthToDate: 5, sinceCredit: 5)]
        XCTAssertEqual(Advisor.evaluate([], spends: spends, now: now).apiPick?.account.name, "GG")
    }

    func testSavedReadingRollsPastReset() {
        var s = snap(.claude, session: 90, weekly: 60, weeklyResetIn: -3600) // weekly reset an hour ago
        s.windows[0] = window("Session · 5h", used: 90, resetIn: -60, length: 5 * 3600)
        let rolled = s.rolledForward(now: now)
        XCTAssertEqual(rolled.windows.map(\.usedPercent), [0, 0])
        XCTAssertGreaterThan(rolled.windows[1].resetsAt!, now)
    }

    func testKeyHintNeverContainsTheMiddleOfTheKey() {
        let key = "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-wxyz"
        let hint = KeyHint.make(key)
        XCTAssertEqual(hint, "sk-ant-api03-ABC…wxyz")
        XCTAssertFalse(hint.contains("MNOP"))
    }

    func testMonthlyAllowanceResetDates() {
        let cal = Calendar(identifier: .gregorian)
        let oct26 = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12))!
        var a = APIAccount(name: "GG", credit: 100)
        a.creditMode = .monthly
        a.resetDay = 7
        XCTAssertEqual(cal.dateComponents([.month, .day], from: a.creditStart(now: oct26)!), DateComponents(month: 10, day: 7))
        XCTAssertEqual(cal.dateComponents([.month, .day], from: a.creditResets(now: oct26)!), DateComponents(month: 11, day: 7))
        a.resetDay = 28 // later this month: the period started last month
        XCTAssertEqual(cal.dateComponents([.month, .day], from: a.creditStart(now: oct26)!), DateComponents(month: 9, day: 28))
    }

    func testAPIPickPrefersCreditThatResetsSooner() {
        var soon = APIAccount(name: "Soon", credit: 40)
        soon.creditMode = .monthly
        soon.resetDay = Calendar(identifier: .gregorian).component(.day, from: Date().addingTimeInterval(2 * 86400)) % 28 + 1
        var later = APIAccount(name: "Later", credit: 60, creditAsOf: Date())
        later.creditExpires = Date().addingTimeInterval(300 * 86400)
        let spends = [SpendSnapshot(account: soon, monthToDate: 0, sinceCredit: 0),
                      SpendSnapshot(account: later, monthToDate: 0, sinceCredit: 0)]
        XCTAssertEqual(Advisor.evaluate([], spends: spends).apiPick?.account.name, "Soon")
    }

    func testSideAllowanceIsNotTheLongWindow() {
        // GLM: weekly tokens 63% used, monthly web-search calls 1% used.
        let glm = ProviderSnapshot(account: account(.zai), plan: "Max", windows: [
            window("Tokens · 5h", used: 27, resetIn: 3600, length: 5 * 3600),
            window("Tokens · weekly", used: 63, resetIn: 3 * 86400, length: 7 * 86400),
            UsageWindow(label: "Web search & tools · monthly", usedPercent: 1, resetsAt: now.addingTimeInterval(20 * 86400),
                        duration: 30 * 86400, auxiliary: true),
        ])
        XCTAssertEqual(glm.longest?.label, "Tokens · weekly")
        XCTAssertEqual(glm.bottleneck?.usedPercent, 63)
        XCTAssertTrue(Advisor.evaluate([glm], spends: [], now: now).detail.contains("37%"))
    }

    func testDateParsingHandlesMicroseconds() {
        XCTAssertNotNil(J.date("2026-10-26T12:00:00.123456+00:00"))
        XCTAssertNotNil(J.date(1_800_000_000_000))
    }
}
