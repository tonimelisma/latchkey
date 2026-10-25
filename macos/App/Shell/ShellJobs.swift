import Foundation

/// Commands Claude runs (spec 004 plan D2, D3). Each runs in its own terminal session made by the
/// system's `script`, so prompts and Ctrl-C behave as in Terminal; Latchkey talks to it through
/// pipes and never forks itself.
actor ShellJobs {
    struct Snapshot: Sendable {
        var job: String
        var command: String
        /// Cleaned output since the previous answer about this job.
        var output: String
        /// Characters of that output left out to stay within the limit.
        var dropped: Int
        var finished: Bool
        var exitCode: Int32?
    }

    struct Summary: Sendable {
        var job: String
        var command: String
        var started: Date
        var finished: Bool
        var exitCode: Int32?
    }

    struct Failure: Error { var message: String }

    static let maxWait: Duration = .seconds(30)
    static let outputLimit = 50_000
    static let keptBytes = 1_000_000

    private final class Job: @unchecked Sendable {
        let id: String
        let command: String
        let started = Date()
        let process: Process
        let input: FileHandle
        private let lock = NSLock()
        private var bytes = Data()
        private var trimmed = 0
        private var mark = 0
        private(set) var ended: Date?
        private var sessionLeader: pid_t?

        init(id: String, command: String, process: Process, input: FileHandle) {
            self.id = id
            self.command = command
            self.process = process
            self.input = input
        }

        func append(_ d: Data) {
            lock.withLock {
                bytes.append(d)
                if bytes.count > ShellJobs.keptBytes {  // keep the last 1 MB
                    // removeSubrange, not removeFirst: on Data, removeFirst re-slices, so the
                    // indices stop starting at 0 and the memory is never freed.
                    let cut = bytes.count - ShellJobs.keptBytes
                    bytes.removeSubrange(bytes.startIndex..<bytes.startIndex + cut)
                    trimmed += cut
                }
            }
        }

        /// The command's terminal session: `script` starts the shell as the leader of a new one,
        /// and everything the command starts stays in it unless it deliberately leaves. Found
        /// while `script` runs and remembered, since its child is no longer its child once it
        /// has exited.
        func session() -> pid_t? {
            lock.withLock {
                if sessionLeader == nil {
                    sessionLeader = Processes.sessionLeader(under: process.processIdentifier)
                }
                return sessionLeader
            }
        }

        /// Sends `signal` to every process in the command's session and to `script` itself.
        func signalAll(_ signal: Int32) {
            if let leader = session() { Processes.members(ofSession: leader).forEach { kill($0, signal) } }
            if process.isRunning { kill(process.processIdentifier, signal) }
        }

        /// True while any process of the command's session is left.
        var hasProcesses: Bool {
            process.isRunning || (session().map { !Processes.members(ofSession: $0).isEmpty } ?? false)
        }

        func finish() { lock.withLock { ended = Date() } }
        var isFinished: Bool { lock.withLock { ended != nil } }

        /// Output since the last call, and moves the mark.
        func takeNew() -> Data {
            lock.withLock {
                let start = max(mark - trimmed, 0)
                let d = bytes.count > start ? Data(bytes[(bytes.startIndex + start)...]) : Data()
                mark = trimmed + bytes.count
                return d
            }
        }
    }

    static let maxRunning = 32

    private var jobs: [String: Job] = [:]
    private var counter = 0
    private let maxRunning: Int

    init(maxRunning: Int = ShellJobs.maxRunning) { self.maxRunning = maxRunning }

    func run(_ command: String, folder: String?, wait: Duration) async throws -> Snapshot {
        cleanup()
        let running = jobs.values.filter { !$0.isFinished }.count
        guard running < maxRunning else {
            throw Failure(
                message:
                    "\(running) commands are already running, the most Latchkey runs at once. Wait for one to finish or stop one (shell_run with job and stop); shell_check lists them."
            )
        }
        counter += 1
        let id = "job\(counter)"
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/script")
        // "--": a command starting with "-" is the command, not more options for zsh.
        p.arguments = ["-q", "/dev/null", "/bin/zsh", "-l", "-c", "--", command]
        let dir = folder.map { ($0 as NSString).expandingTildeInPath } ?? URL.homeDirectory.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw Failure(message: "There's no folder at \(dir).")
        }
        p.currentDirectoryURL = URL(filePath: dir)
        var env = ProcessInfo.processInfo.environment
        for (k, v) in ["TERM": "dumb", "NO_COLOR": "1", "PAGER": "cat", "GIT_PAGER": "cat"] { env[k] = v }
        p.environment = env
        let stdin = Pipe()
        let stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stdout
        let job = Job(id: id, command: command, process: p, input: stdin.fileHandleForWriting)
        stdout.fileHandleForReading.readabilityHandler = { @Sendable h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { job.append(d) }
        }
        p.terminationHandler = { @Sendable _ in
            // Let the last output arrive before the job counts as finished.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { job.finish() }
        }
        try p.run()
        jobs[id] = job
        Task.detached {  // note the session as soon as `script` has started the shell
            for _ in 0..<100 where job.session() == nil && !job.isFinished {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        return try await snapshot(job, waiting: min(wait, Self.maxWait))
    }

    func check(_ id: String, wait: Duration) async throws -> Snapshot {
        try await snapshot(try job(id), waiting: min(wait, Self.maxWait))
    }

    func send(_ id: String, text: String, enter: Bool) async throws {
        let job = try job(id)
        guard !job.isFinished else { throw Failure(message: "\(id) has already finished.") }
        try job.input.write(contentsOf: Data((text + (enter ? "\n" : "")).utf8))
    }

    /// Ctrl-C, then after 3 s everything in the command's terminal session is asked to end, then
    /// killed (plan D3): the shell, what it started, and what those started, so nothing the
    /// command left in the background survives it.
    func stop(_ id: String) async throws -> Snapshot {
        let job = try job(id)
        if !job.isFinished {
            _ = job.session()
            try? job.input.write(contentsOf: Data([0x03]))
            _ = await waitForEnd(job, .seconds(3), evenIfCancelled: true)
            await end(job)
        }
        return try await snapshot(job, waiting: .zero)
    }

    /// Ends whatever is left of a job: terminate, then kill after a second.
    private func end(_ job: Job) async {
        guard job.hasProcesses else { return }
        job.signalAll(SIGTERM)
        if !(await gone(job, within: .seconds(1))) {
            job.signalAll(SIGKILL)
            _ = await gone(job, within: .seconds(2))
        }
        _ = await waitForEnd(job, .seconds(2), evenIfCancelled: true)
    }

    private func gone(_ job: Job, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while job.hasProcesses, ContinuousClock.now < deadline { await Self.pause(.milliseconds(25)) }
        return !job.hasProcesses
    }

    func list() -> [Summary] {
        cleanup()
        return jobs.values.sorted { $0.started < $1.started }.map {
            Summary(
                job: $0.id, command: $0.command, started: $0.started, finished: $0.isFinished,
                exitCode: $0.isFinished ? $0.process.terminationStatus : nil)
        }
    }

    /// FR-309, FR-310: called when Latchkey quits and when the Owner turns Shell off. Every
    /// running command ends with everything it started, all at the same time.
    func stopAll() async {
        let running = jobs.values.filter { !$0.isFinished }
        await withTaskGroup(of: Void.self) { group in
            for job in running { group.addTask { await self.end(job) } }
        }
    }

    // MARK: helpers

    private func job(_ id: String) throws -> Job {
        guard let job = jobs[id] else {
            throw Failure(
                message: "There's no job \(id). Jobs are kept for 10 minutes after they finish; see shell_check.")
        }
        return job
    }

    /// Waits for the job to end, at most `limit`. A caller that was cancelled (the relay gave up,
    /// or the Owner turned Shell off) stops waiting at once; stopping a job waits regardless.
    private func waitForEnd(_ job: Job, _ limit: Duration, evenIfCancelled: Bool = false) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !job.isFinished, ContinuousClock.now < deadline {
            if Task.isCancelled {
                if !evenIfCancelled { break }
                await Self.pause(.milliseconds(50))
            } else {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return job.isFinished
    }

    /// A sleep that a cancelled task still sleeps.
    private static func pause(_ time: Duration) async {
        await Task.detached { try? await Task.sleep(for: time) }.value
    }

    private func snapshot(_ job: Job, waiting: Duration) async throws -> Snapshot {
        _ = await waitForEnd(job, waiting)
        let raw = String(decoding: job.takeNew(), as: UTF8.self)
        let (text, dropped) = TerminalText.tail(TerminalText.clean(raw), limit: Self.outputLimit)
        let finished = job.isFinished
        return Snapshot(
            job: job.id, command: job.command, output: text, dropped: dropped, finished: finished,
            exitCode: finished ? job.process.terminationStatus : nil)
    }

    /// Finished jobs stay 10 minutes; at most 20 are kept. Running ones are capped in `run`.
    private func cleanup() {
        let now = Date()
        for (id, job) in jobs { if let end = job.ended, now.timeIntervalSince(end) > 600 { jobs[id] = nil } }
        let done = jobs.values.filter(\.isFinished).sorted { $0.started < $1.started }
        for job in done.dropLast(20) { jobs[job.id] = nil }
    }
}

/// The processes of a command's terminal session.
enum Processes {
    static func all() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(max(Int(n), 0))).filter { $0 > 0 }
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// The child of `script` that leads a session of its own (the shell on the terminal `script`
    /// made). Nil until `script` has started it. Never this app's own session.
    static func sessionLeader(under script: pid_t) -> pid_t? {
        all().first { parent(of: $0) == script && getsid($0) == $0 && $0 != getsid(0) }
    }

    static func members(ofSession leader: pid_t) -> [pid_t] {
        guard leader > 1, leader != getsid(0) else { return [] }
        return all().filter { getsid($0) == leader }
    }
}

/// What a terminal shows, as plain text (plan D4).
enum TerminalText {
    private static let patterns = [
        #"\x{1B}\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)"#,  // window titles and other OSC sequences
        #"\x{1B}\[[0-9;?]*[ -/]*[@-~]"#,  // colors, cursor movement
        #"\x{1B}[()][A-Za-z0-9]"#, #"\x{1B}[=>78]"#,
        #"\^D\x{08}\x{08}"#,  // script's echo of end-of-input
        #"[\x{00}-\x{07}\x{0B}\x{0E}-\x{1A}\x{1C}-\x{1F}\x{7F}]"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n")
        for p in patterns {
            t = p.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        t = t.replacingOccurrences(of: "\u{08}", with: "")
        // A carriage return redraws the line: keep what was drawn last.
        return t.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(separator: "\r").last.map(String.init) ?? ""
        }.joined(separator: "\n")
    }

    /// The last `limit` characters, and how many were left out.
    static func tail(_ s: String, limit: Int) -> (String, Int) {
        guard s.count > limit else { return (s, 0) }
        return (String(s.suffix(limit)), s.count - limit)
    }
}
