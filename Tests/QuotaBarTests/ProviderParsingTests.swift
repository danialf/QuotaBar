import XCTest
@testable import QuotaBar

/// Response shapes as documented for each undocumented quota endpoint.
final class ProviderParsingTests: XCTestCase {
    func json(_ s: String) throws -> [String: Any] { try J.object(Data(s.utf8)) }

    func testKimiCountsGiveWeeklyAndSessionWindows() throws {
        let snap = try KimiProvider.parse(json("""
        {"usage": {"limit": "2048", "used": "214", "remaining": "1834", "resetTime": "2026-01-09T15:23:13.716839300Z"},
         "limits": [{"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
                     "detail": {"limit": "200", "used": "139", "remaining": "61", "resetTime": "2026-01-06T13:33:02.717479433Z"}}],
         "user": {"membership": {"level": "LEVEL_MODERATO"}}}
        """))
        XCTAssertEqual(snap.plan, "Moderato")
        XCTAssertEqual(snap.windows.map(\.label), ["Session · 5h", "Weekly"])
        XCTAssertEqual(snap.windows[0].usedPercent, 69.5, accuracy: 0.01)
        XCTAssertEqual(snap.windows[1].usedPercent, 214.0 / 2048 * 100, accuracy: 0.01)
        XCTAssertNotNil(snap.windows[1].resetsAt)
    }

    func testKimiRatioPoolsWinOverCounts() throws {
        let snap = try KimiProvider.parse(json("""
        {"usages": {"limit_5h": {"used_ratio": 0.25, "reset_time": "2026-01-06T13:33:02Z"},
                    "limit_7d": {"used_ratio": 0.5, "reset_time": "2026-01-09T15:23:13Z"},
                    "limit_month_total": {"used_ratio": 0.1, "reset_time": "2026-02-01T00:00:00Z"}},
         "usage": {"limit": "100", "used": "99"}}
        """))
        XCTAssertEqual(snap.windows.map(\.label), ["Session · 5h", "Weekly", "Monthly"])
        XCTAssertEqual(snap.windows.map(\.usedPercent), [25, 50, 10])
    }

    func testMiniMaxUsageCountIsWhatsLeft() throws {
        // 1500 prompts per 5 hours with 1200 left means 20% used, not 80%.
        let snap = try MiniMaxProvider.parse(json("""
        {"model_remains": [
           {"model_name": "MiniMax-M2", "current_interval_total_count": 1500, "current_interval_usage_count": 1200,
            "start_time": 1767700000000, "end_time": 1767718000000, "remains_time": 9000000},
           {"model_name": "speech-hd", "current_interval_total_count": 10, "current_interval_usage_count": 0,
            "start_time": 1767700000000, "end_time": 1767718000000}],
         "base_resp": {"status_code": 0, "status_msg": "success"}}
        """))
        XCTAssertEqual(snap.windows.count, 1, "speech quota is not the coding quota")
        XCTAssertEqual(snap.windows[0].label, "Session · 5h")
        XCTAssertEqual(snap.windows[0].usedPercent, 20, accuracy: 0.01)
        XCTAssertEqual(snap.windows[0].detail, "300 of 1500 prompts")
    }

    func testMiniMaxReportsAPIErrors() throws {
        XCTAssertThrowsError(try MiniMaxProvider.parse(json("""
        {"base_resp": {"status_code": 1004, "status_msg": "cookie is missing, log in again"}}
        """)))
    }

    func testMiniMaxWeeklyPercentWindow() throws {
        let snap = try MiniMaxProvider.parse(json("""
        {"data": {"model_remains": [
           {"model_name": "general", "current_interval_remaining_percent": 90, "start_time": 1767700000000, "end_time": 1767718000000,
            "current_weekly_remaining_percent": 40, "weekly_start_time": 1767225600000, "weekly_end_time": 1767830400000}],
          "current_subscribe_title": "Plus"}}
        """))
        XCTAssertEqual(snap.plan, "Plus")
        XCTAssertEqual(snap.windows.map(\.label), ["Session · 5h", "Weekly"])
        XCTAssertEqual(snap.windows.map(\.usedPercent), [10, 60])
    }

    func testGrokCreditsPercentAndPeriod() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-27T00:00:00Z")!
        let snap = try GrokProvider.parse(json("""
        {"config": {"creditUsagePercent": 37.5, "subscriptionTier": "SUBSCRIPTION_TIER_SUPER_GROK_HEAVY",
                    "currentPeriod": {"start": "2026-10-24T00:00:00Z", "end": "2026-10-31T00:00:00Z"}}}
        """), now: now)
        XCTAssertEqual(snap.plan, "SuperGrok Heavy")
        XCTAssertEqual(snap.windows.first?.label, "Credits · weekly")
        XCTAssertEqual(snap.windows.first?.usedPercent, 37.5)
        XCTAssertNil(snap.note)
    }

    func testGrokMissingPercentInActivePeriodIsZero() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-27T00:00:00Z")!
        let snap = try GrokProvider.parse(json("""
        {"config": {"currentPeriod": {"start": "2026-10-24T00:00:00Z", "end": "2026-10-31T00:00:00Z"}}}
        """), now: now)
        XCTAssertEqual(snap.windows.first?.usedPercent, 0)
        XCTAssertNotNil(snap.note)
    }

    func testCursorPercentFieldsAreAlreadyPercentages() throws {
        let snap = try CursorProvider.parse(json("""
        {"billingCycleStart": "2026-10-22T14:13:40.170Z", "billingCycleEnd": "2026-11-22T14:13:40.170Z", "membershipType": "pro",
         "individualUsage": {"plan": {"used": 720, "limit": 2000, "totalPercentUsed": 0.36, "autoPercentUsed": 0.2, "apiPercentUsed": 0.5},
                             "onDemand": {"enabled": true, "used": 1250, "limit": 5000}}}
        """))
        XCTAssertEqual(snap.plan, "Pro")
        let included = try XCTUnwrap(snap.windows.first { $0.label == "Included · monthly" })
        XCTAssertEqual(included.usedPercent, 0.36, accuracy: 0.001)
        XCTAssertEqual(included.detail, "$7.20 of $20.00")
        XCTAssertEqual(snap.quotas.map(\.label), ["Included · monthly"], "Auto/named split and on-demand are not caps")
        XCTAssertEqual(snap.windows.first { $0.label == "On-demand" }?.creditText, "$12.50 of $50.00 on-demand")
    }
}
