import XCTest
@testable import QuotaBar

final class AgentTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Next reset

    func snap(_ id: String, _ windows: [(used: Double, resetIn: TimeInterval)]) -> ProviderSnapshot {
        ProviderSnapshot(account: Account(id: id, kind: .claude, label: id), plan: nil, windows: windows.enumerated().map { i, w in
            UsageWindow(label: "W\(i)", usedPercent: w.used, resetsAt: now.addingTimeInterval(w.resetIn), duration: 7 * 86400)
        })
    }

    func testSoonestResetThatFreesSomethingComesFirst() {
        let a = snap("a", [(0, 600), (40, 7200)])     // the 10-minute reset frees nothing
        let b = snap("b", [(10, 3600), (5, -60)])     // already past: not upcoming
        let order = ResetSchedule.upcoming([a, b], now: now).map(\.id)
        XCTAssertEqual(order, ["b.W0", "a.W1"])
    }

    func testSessionWindowsAreLeftOut() {
        var a = snap("a", [(30, 7200)])
        a.windows.insert(UsageWindow(label: "Session", usedPercent: 50, resetsAt: now.addingTimeInterval(600), duration: 5 * 3600), at: 0)
        XCTAssertEqual(ResetSchedule.upcoming([a], now: now).map(\.window.label), ["W0"])
    }

    func testFallsBackToAllWindowsWhenNothingIsUsed() {
        let a = snap("a", [(0, 600), (0, 7200)])
        XCTAssertEqual(ResetSchedule.upcoming([a], now: now).first?.id, "a.W0")
    }

    func testResetsWithinAMinuteShareAStop() {
        let a = snap("a", [(10, 7200), (20, 86400)])
        let b = snap("b", [(30, 7230)])
        let stops = ResetSchedule.stops(ResetSchedule.upcoming([a, b], now: now))
        XCTAssertEqual(stops.map { $0.entries.map(\.id) }, [["a.W0", "b.W0"], ["a.W1"]])
    }

    // MARK: Bubbles

    func testPackedBubblesNeverOverlap() {
        let radii: [Double] = [30, 22, 22, 14, 14, 14, 10, 10, 31, 8]
        let centers = BubblePacker.pack(radii, gap: 2)
        XCTAssertEqual(centers.count, radii.count)
        for i in radii.indices {
            for j in radii.indices where j > i {
                let d = hypot(centers[i].x - centers[j].x, centers[i].y - centers[j].y)
                XCTAssertGreaterThanOrEqual(d, radii[i] + radii[j] + 1.99, "\(i) and \(j) overlap")
            }
        }
        XCTAssertEqual(centers[8], .zero, "the largest sits in the middle")
    }

    // MARK: Projects

    func testWorktreesFoldIntoTheirRepository() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "qb-agents-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: home) }
        let repo = "\(home)/Projects/app"
        try fm.createDirectory(atPath: "\(repo)/.git/worktrees/fix", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: "\(repo)/src/deep", withIntermediateDirectories: true)
        let tree = "\(home)/worktrees/fix"
        try fm.createDirectory(atPath: tree, withIntermediateDirectories: true)
        try "gitdir: \(repo)/.git/worktrees/fix\n".write(toFile: "\(tree)/.git", atomically: true, encoding: .utf8)
        let loose = "\(home)/scratch"
        try fm.createDirectory(atPath: loose, withIntermediateDirectories: true)

        XCTAssertEqual(AgentScanner.findRoot(repo, home: home), .init(repo: repo, place: nil))
        XCTAssertEqual(AgentScanner.findRoot("\(repo)/src/deep", home: home), .init(repo: repo, place: "deep"))
        XCTAssertEqual(AgentScanner.findRoot(tree, home: home), .init(repo: repo, place: "fix"))
        XCTAssertEqual(AgentScanner.findRoot(loose, home: home), .init(repo: loose, place: nil))
        XCTAssertNil(AgentScanner.findRoot(home, home: home), "home isn't a project")
        XCTAssertNil(AgentScanner.findRoot("/", home: home))
    }

    // MARK: Process arguments

    func testParsesArgumentsAndEnvironment() throws {
        var buf = withUnsafeBytes(of: Int32(2)) { Array($0) }
        for part in ["/usr/local/bin/node", "", "", "node", "/x/claude-code/cli.js",
                     "CLAUDE_CONFIG_DIR=/Users/u/.claude-2", "ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic", ""] {
            buf += Array(part.utf8) + [0]
        }
        let parsed = try XCTUnwrap(AgentScanner.parseProcArgs(buf))
        XCTAssertEqual(parsed.args, ["node", "/x/claude-code/cli.js"])
        XCTAssertEqual(parsed.env["CLAUDE_CONFIG_DIR"], "/Users/u/.claude-2")
        XCTAssertEqual(AgentScanner.routedProvider(env: parsed.env), .zai)
    }
}
