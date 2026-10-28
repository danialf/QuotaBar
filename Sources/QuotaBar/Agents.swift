import Darwin
import SwiftUI

/// A coding-agent CLI recognised in the process table.
enum AgentKind: String, CaseIterable, Codable {
    case claude, codex, cursor, kimi, grok, gemini, opencode, aider, amp, droid, qwen, crush, goose

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor Agent"
        case .kimi: "Kimi"
        case .grok: "Grok"
        case .gemini: "Gemini"
        case .opencode: "OpenCode"
        case .aider: "Aider"
        case .amp: "Amp"
        case .droid: "Droid"
        case .qwen: "Qwen Code"
        case .crush: "Crush"
        case .goose: "Goose"
        }
    }

    /// The subscription it spends by default, when QuotaBar tracks one.
    var provider: ProviderID? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .cursor: .cursor
        case .kimi: .kimi
        case .grok: .grok
        default: nil
        }
    }

    var tint: Color {
        if let provider { return provider.tint }
        return switch self {
        case .gemini: Color(red: 0.26, green: 0.52, blue: 0.96)
        case .opencode: Color(red: 0.55, green: 0.58, blue: 0.62)
        default: Color(red: 0.48, green: 0.55, blue: 0.60)
        }
    }

    /// Executable names (the basename of argv[0] or of the binary).
    fileprivate static let executables: [String: AgentKind] = [
        "claude": .claude, "codex": .codex, "cursor-agent": .cursor, "kimi": .kimi, "grok": .grok,
        "gemini": .gemini, "opencode": .opencode, "aider": .aider, "amp": .amp, "droid": .droid,
        "qwen": .qwen, "crush": .crush, "goose": .goose,
    ]

    /// Script paths that mark an interpreter (node, bun, python) as running an agent.
    fileprivate static let scripts: [(String, AgentKind)] = [
        ("claude-code", .claude), ("@openai/codex", .codex), ("gemini-cli", .gemini), ("/aider", .aider),
        ("@sourcegraph/amp", .amp), ("qwen-code", .qwen), ("opencode-ai", .opencode),
    ]
}

/// One running agent and the project it is working in.
struct AgentSession: Identifiable, Hashable {
    var id: Int32 { pid }
    let pid: Int32
    let kind: AgentKind
    /// Which subscription it bills: the agent's own, or the one its base URL points at.
    let provider: ProviderID?
    /// The Claude account by config dir ("claude:.claude-2"), when it could be told.
    let accountID: String?
    /// Main repository root (worktrees fold into their repository).
    let projectPath: String
    let project: String
    /// The worktree or subfolder it sits in, when not the repository root.
    let place: String?
    let started: Date
    /// Smoothed CPU of the agent and everything it started, in cores.
    var cpu: Double
    /// Live processes it started (shells, builds, tests).
    var children: Int

    /// An agent streaming a reply or running a tool keeps its tree busy; an idle prompt sits near zero.
    var isWorking: Bool { cpu >= AgentSession.workingCPU }
    static let workingCPU = 0.03
}

/// A project with the agents in it, for the bubble field.
struct AgentProject: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let sessions: [AgentSession]

    var working: Int { sessions.filter(\.isWorking).count }
    var cpu: Double { sessions.reduce(0) { $0 + $1.cpu } }
    /// Bubble area: each agent counts, and busy ones count more.
    var weight: Double { Double(sessions.count) + 3 * min(cpu, 4) }
    /// The provider most of its agents run on.
    var tint: Color {
        let kinds = Dictionary(grouping: sessions, by: { $0.provider.map(\.tint) ?? $0.kind.tint })
        return kinds.max { $0.value.count < $1.value.count }?.key ?? .secondary
    }

    static func group(_ sessions: [AgentSession]) -> [AgentProject] {
        Dictionary(grouping: sessions, by: \.projectPath)
            .map { AgentProject(path: $0.key, name: $0.value[0].project, sessions: $0.value.sorted { $0.started < $1.started }) }
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.name < $1.name }
    }
}

// MARK: - Scanning

/// Reads the process table with libproc: no subprocesses, and only this user's processes.
enum AgentScanner {
    struct Proc {
        let pid: Int32
        let ppid: Int32
        let path: String
        let started: Date
    }

    struct Found {
        var session: AgentSession
        /// Total CPU time of the agent's tree so far, in seconds.
        let cpuTime: Double
    }

    static func scan(roots: inout [String: Root?]) -> [Found] {
        let procs = allProcesses()
        var children: [Int32: [Int32]] = [:]
        for p in procs.values { children[p.ppid, default: []].append(p.pid) }

        var agents: [(Proc, AgentKind)] = procs.values.compactMap { p in identify(p).map { (p, $0) } }
        // A helper an agent started (an MCP server, a sub-agent) belongs to the outer one.
        let agentPIDs = Set(agents.map(\.0.pid))
        agents.removeAll { hasAncestor($0.0, in: agentPIDs, procs: procs) }

        return agents.compactMap { p, kind in
            let tree = descendants(of: p.pid, children: children)
            let env = arguments(p.pid)?.env ?? [:]
            // The agent's own folder, else where its tools run (a desktop app's server sits at /).
            let cwds = ([p.pid] + tree).compactMap(cwd)
            guard let root = (cwds.first.flatMap { resolve($0, roots: &roots) })
                    ?? mostCommon(cwds.dropFirst().compactMap { resolve($0, roots: &roots) }) else { return nil }
            let provider = routedProvider(env: env) ?? kind.provider
            let account = provider == .claude && kind == .claude
                ? "claude:" + ((env["CLAUDE_CONFIG_DIR"].map { ($0 as NSString).lastPathComponent }) ?? ".claude")
                : nil
            let session = AgentSession(pid: p.pid, kind: kind, provider: provider, accountID: account,
                                       projectPath: root.repo, project: (root.repo as NSString).lastPathComponent,
                                       place: root.place, started: p.started, cpu: 0, children: tree.count)
            let cpuTime = ([p.pid] + tree).reduce(0) { $0 + cpuSeconds($1) }
            return Found(session: session, cpuTime: cpuTime)
        }
    }

    private static func identify(_ p: Proc) -> AgentKind? {
        let base = (p.path as NSString).lastPathComponent
        if let kind = AgentKind.executables[base] { return kind }
        // Claude Code's native build runs as ~/.local/share/claude/versions/<version>.
        if p.path.contains("/claude/versions/") { return .claude }
        guard ["node", "bun", "deno", "python", "python3"].contains(where: { base.hasPrefix($0) }),
              let args = arguments(p.pid)?.args else { return nil }
        if let first = args.first, let kind = AgentKind.executables[(first as NSString).lastPathComponent] { return kind }
        for arg in args.dropFirst().prefix(3) {
            if let (_, kind) = AgentKind.scripts.first(where: { arg.contains($0.0) }) { return kind }
        }
        return nil
    }

    /// Claude Code pointed at another vendor's Anthropic-compatible endpoint spends that plan.
    static func routedProvider(env: [String: String]) -> ProviderID? {
        guard let url = env["ANTHROPIC_BASE_URL"]?.lowercased() else { return nil }
        if url.contains("z.ai") || url.contains("bigmodel") { return .zai }
        if url.contains("minimax") { return .minimax }
        if url.contains("kimi") || url.contains("moonshot") { return .kimi }
        return nil
    }

    private static func hasAncestor(_ p: Proc, in set: Set<Int32>, procs: [Int32: Proc]) -> Bool {
        var ppid = p.ppid
        var hops = 0
        while ppid > 1, hops < 64, let parent = procs[ppid] {
            if set.contains(ppid) { return true }
            ppid = parent.ppid
            hops += 1
        }
        return false
    }

    private static func descendants(of pid: Int32, children: [Int32: [Int32]]) -> [Int32] {
        var out: [Int32] = []
        var queue = children[pid] ?? []
        while let next = queue.popLast(), out.count < 512 {
            out.append(next)
            queue += children[next] ?? []
        }
        return out
    }

    private static func mostCommon(_ roots: [Root]) -> Root? {
        Dictionary(grouping: roots, by: \.repo).max { $0.value.count < $1.value.count }?.value.first
    }

    // MARK: Projects

    struct Root: Hashable {
        /// The main repository (or the folder itself when it isn't in one).
        let repo: String
        /// The worktree or folder inside it, when that's not the repository root.
        let place: String?
    }

    /// The repository a folder belongs to; nil for home, / and system folders, which aren't projects.
    static func resolve(_ dir: String, roots: inout [String: Root?], home: String = NSHomeDirectory()) -> Root? {
        if let cached = roots[dir] { return cached }
        let root = findRoot(dir, home: home)
        roots[dir] = root
        return root
    }

    static func findRoot(_ dir: String, home: String, fileManager fm: FileManager = .default) -> Root? {
        guard dir.hasPrefix(home + "/"), dir != home else { return nil }
        var current = dir
        while current.count > home.count {
            let git = current + "/.git"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git, isDirectory: &isDir) {
                let place = current == dir ? nil : (dir as NSString).lastPathComponent
                guard !isDir.boolValue, let main = worktreeMain(gitFile: git) else { return Root(repo: current, place: place) }
                // A linked worktree: group it with its repository, named after the worktree.
                return Root(repo: main, place: (current as NSString).lastPathComponent)
            }
            current = (current as NSString).deletingLastPathComponent
        }
        // Not in a repository: the folder itself is the project.
        return Root(repo: dir, place: nil)
    }

    /// `gitdir: /repo/.git/worktrees/name` → /repo. Submodules point into `.git/modules` and stay their own project.
    private static func worktreeMain(gitFile: String) -> String? {
        guard let text = try? String(contentsOfFile: gitFile, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard let range = gitdir.range(of: "/.git/worktrees/") else { return nil }
        return String(gitdir[..<range.lowerBound])
    }

    // MARK: libproc

    private static func allProcesses() -> [Int32: Proc] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        let uid = getuid()
        var out: [Int32: Proc] = [:]
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { continue }
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            out[pid] = Proc(pid: pid, ppid: Int32(info.pbi_ppid), path: String(cString: buf),
                            started: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)))
        }
        return out
    }

    private static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    private static let ticksToSeconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

    private static func cpuSeconds(_ pid: Int32) -> Double {
        var usage = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard ok == 0 else { return 0 }
        return Double(usage.ri_user_time + usage.ri_system_time) * ticksToSeconds
    }

    /// argv and environment, from KERN_PROCARGS2: argc, the exec path, padding, argv, then env.
    static func arguments(_ pid: Int32) -> (args: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        return parseProcArgs(Array(buf.prefix(size)))
    }

    static func parseProcArgs(_ buf: [UInt8]) -> (args: [String], env: [String: String])? {
        guard buf.count > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        while i < buf.count, buf[i] != 0 { i += 1 }
        while i < buf.count, buf[i] == 0 { i += 1 }
        func next() -> String? {
            guard i < buf.count else { return nil }
            let start = i
            while i < buf.count, buf[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: buf[start..<i], as: UTF8.self)
        }
        var args: [String] = []
        for _ in 0..<argc { guard let s = next() else { break }; args.append(s) }
        var env: [String: String] = [:]
        while let s = next(), !s.isEmpty {
            guard let eq = s.firstIndex(of: "=") else { continue }
            env[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        return (args, env)
    }
}

// MARK: - Monitor

/// Rescans every few seconds while a view that shows agents is on screen, and not otherwise.
@MainActor
final class AgentMonitor: ObservableObject {
    static let shared = AgentMonitor()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var projects: [AgentProject] = []
    @Published private(set) var scanned = false

    private var watchers = 0
    private var loop: Task<Void, Never>?
    private var lastScan: Date?
    private var lastCPUTime: [Int32: Double] = [:]
    private var smoothed: [Int32: Double] = [:]
    private var roots: [String: AgentScanner.Root?] = [:]
    private static let interval: TimeInterval = 3

    /// Keeps scanning for as long as the calling task (a view's `.task`) lives.
    func watch() async {
        watchers += 1
        if loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.scanNow()
                    try? await Task.sleep(for: .seconds(Self.interval))
                }
            }
        }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        watchers -= 1
        if watchers == 0 { loop?.cancel(); loop = nil }
    }

    func scanNow() async {
        var roots = self.roots
        let (found, newRoots) = await Task.detached(priority: .utility) { () -> ([AgentScanner.Found], [String: AgentScanner.Root?]) in
            let found = AgentScanner.scan(roots: &roots)
            return (found, roots)
        }.value
        // Folders can become repositories; don't remember answers forever.
        self.roots = newRoots.count > 400 ? [:] : newRoots

        let now = Date.now
        let elapsed = lastScan.map { now.timeIntervalSince($0) } ?? 0
        var cpuTimes: [Int32: Double] = [:]
        var next: [Int32: Double] = [:]
        let list = found.map { f -> AgentSession in
            var s = f.session
            cpuTimes[s.pid] = f.cpuTime
            if elapsed > 0.5, let previous = lastCPUTime[s.pid] {
                // Children that exited take their time with them; a dip isn't negative work.
                let rate = max(0, f.cpuTime - previous) / elapsed
                s.cpu = smoothed[s.pid].map { 0.5 * $0 + 0.5 * rate } ?? rate
            }
            next[s.pid] = s.cpu
            return s
        }
        lastCPUTime = cpuTimes
        smoothed = next
        lastScan = now
        sessions = list.sorted { $0.started < $1.started }
        projects = AgentProject.group(list)
        scanned = true
    }
}

// MARK: - Next reset

/// Weekly (and longer) windows in reset order, soonest first: the moment real quota comes back.
/// Session windows are left out; they roll over every few hours and say little about the week.
enum ResetSchedule {
    struct Entry: Identifiable {
        var id: String { "\(account.id).\(window.label)" }
        let account: Account
        let window: UsageWindow
        let resetsAt: Date
    }

    static let minimumWindow: TimeInterval = 86400

    /// Only windows with something used: a reset that frees nothing isn't worth waiting for.
    /// Falls back to every window when nothing has been used yet.
    static func upcoming(_ snapshots: [ProviderSnapshot], now: Date = .now) -> [Entry] {
        let all = snapshots.flatMap { snap in
            snap.quotas.compactMap { w -> Entry? in
                guard let r = w.resetsAt, r > now, let d = w.duration, d >= minimumWindow else { return nil }
                return Entry(account: snap.account, window: w, resetsAt: r)
            }
        }
        .sorted { $0.resetsAt < $1.resetsAt }
        let used = all.filter { $0.window.usedPercent >= 1 }
        return used.isEmpty ? all : used
    }
}

// MARK: - Bubble packing

/// Packs circles of the given radii around the origin without overlap, largest in the middle.
enum BubblePacker {
    /// Centres in the same order as `radii`.
    static func pack(_ radii: [Double], gap: Double = 4) -> [CGPoint] {
        let order = radii.indices.sorted { radii[$0] > radii[$1] }
        var placed: [(center: CGPoint, r: Double)] = []
        var centers = [CGPoint](repeating: .zero, count: radii.count)
        for i in order {
            let r = radii[i]
            guard !placed.isEmpty else {
                placed.append((.zero, r))
                continue
            }
            var best: CGPoint?
            var bestDistance = Double.infinity
            // Try spots touching each placed circle; keep the free one nearest the middle.
            for p in placed {
                let d = p.r + r + gap
                for step in 0..<36 {
                    let a = Double(step) * .pi / 18
                    let c = CGPoint(x: p.center.x + d * cos(a), y: p.center.y + d * sin(a))
                    let fits = placed.allSatisfy { q in hypot(c.x - q.center.x, c.y - q.center.y) >= q.r + r + gap - 0.01 }
                    let distance = hypot(c.x, c.y * 1.25)
                    if fits, distance < bestDistance { best = c; bestDistance = distance }
                }
            }
            let c = best ?? CGPoint(x: placed.map { $0.center.x + $0.r }.max()! + r + gap, y: 0)
            placed.append((c, r))
            centers[i] = c
        }
        if let first = order.first { centers[first] = .zero }
        return centers
    }
}
