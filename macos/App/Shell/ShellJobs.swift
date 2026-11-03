import Foundation

/// Commands Claude runs (spec 004 plan D2, D3). Each runs in its own terminal session made by the
/// system's `script`, so prompts and Ctrl-C behave as in Terminal; Latchkey talks to it through
/// pipes and never forks itself. Since 2026-10-27 nothing a command leaves stays behind unless
/// Claude asked to keep it for a while (plan D6 to D12): its processes are followed and
/// stopped when it finishes, it writes only inside a fence, and its scratch folder goes to the
/// Trash.
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
        /// What the job left (FR-321), once, in the first answer after its leftovers were dealt
        /// with or kept.
        var left: String?
        /// True when the output shows a write the fence refused (FR-320).
        var refusedWrite = false
        /// True when it shows a refused open or script (FR-328).
        var refusedHandoff = false
        /// True when it shows a refused change of settings (FR-329).
        var refusedSettings = false
        /// What the self-check at start found broken (FR-330); nil when all is well.
        var fenceWarning: String?
    }

    struct Summary: Sendable {
        var job: String
        var command: String
        var started: Date
        var finished: Bool
        var exitCode: Int32?
        /// When a finished job's kept leftovers are removed; nil when nothing is kept.
        var keptUntil: Date?
    }

    struct Failure: Error { var message: String }

    static let maxWait: Duration = .seconds(30)
    static let outputLimit = 50_000
    static let keptBytes = 1_000_000
    /// The longest a job's leftovers are kept after the command finished (FR-314).
    static let longestLease: TimeInterval = 24 * 3600

    private final class Job: @unchecked Sendable {
        let id: String
        let command: String
        let started = Date()
        let process: Process
        let input: FileHandle
        let scratch: URL
        /// The mark the job's fence carries, and the file beside it it may read (FR-327).
        let mark: URL
        let control: URL
        let declared: [URL]
        let why: String?
        let keepMinutes: Int
        private let lock = NSLock()
        private var bytes = Data()
        private var trimmed = 0
        private var mark0 = 0
        private(set) var ended: Date?
        private var sessionLeader: pid_t?
        /// Actor-isolated state (only touched by ShellJobs).
        var leaseEnd: Date?
        var sweep: Task<Void, Never>?
        var swept = false
        var left: String?
        /// Whether the answer said the leftovers are kept, and what was removed in the end.
        var keptShown = false
        var leftShown = false

        init(
            id: String, command: String, process: Process, input: FileHandle, scratch: URL,
            declared: [URL], why: String?, keepMinutes: Int
        ) {
            self.id = id
            self.command = command
            self.process = process
            self.input = input
            self.scratch = scratch
            self.mark = Fence.mark(of: scratch)
            self.control = Fence.control(of: scratch)
            self.declared = declared
            self.why = why
            self.keepMinutes = keepMinutes
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

        /// The job's processes seen so far, by process id and start time (plan D6).
        private var known: Set<Processes.ID> = []

        /// Adds what `track` found; true when something new was added.
        func learn(_ ids: Set<Processes.ID>) -> Bool {
            lock.withLock {
                let before = known.count
                known.formUnion(ids)
                return known.count != before
            }
        }

        var knownIDs: Set<Processes.ID> { lock.withLock { known } }

        /// Every process of the job still running (plan D6): its terminal session, the
        /// processes followed while it ran (also those that left the session), and, when
        /// `scratchUsers`, any started since the job began that has a file open, or its working
        /// folder, in the job's scratch folder. Also any process carrying the job's mark, however
        /// it left (FR-327).
        func members(scratchUsers: Bool = false) -> [pid_t] {
            var pids = Set(session().map { Processes.members(ofSession: $0) } ?? [])
            pids.formUnion(Processes.marked(by: mark, control: control))
            pids.formUnion(knownIDs.filter(Processes.alive).map(\.pid))
            if scratchUsers { pids.formUnion(Processes.using(scratch, startedAfter: started)) }
            if process.isRunning { pids.insert(process.processIdentifier) }
            pids.remove(getpid())
            return Array(pids)
        }

        /// Sends `signal` to every process of the job.
        func signalAll(_ signal: Int32) { members().forEach { kill($0, signal) } }

        /// True while any process of the job is left.
        var hasProcesses: Bool { !members().isEmpty }

        func finish() { lock.withLock { ended = Date() } }
        var isFinished: Bool { lock.withLock { ended != nil } }

        /// Output since the last call, and moves the mark.
        func takeNew() -> Data {
            lock.withLock {
                let start = max(mark0 - trimmed, 0)
                let d = bytes.count > start ? Data(bytes[(bytes.startIndex + start)...]) : Data()
                mark0 = trimmed + bytes.count
                return d
            }
        }
    }

    static let maxRunning = 32

    private var jobs: [String: Job] = [:]
    private var counter = 0
    private let maxRunning: Int
    let setup: ShellSetup

    init(maxRunning: Int = ShellJobs.maxRunning, setup: ShellSetup = .standard) {
        self.maxRunning = maxRunning
        self.setup = setup
    }

    /// `open` in a command opens apps, files, and links behind the app the Owner is using
    /// (`open -g`), so Claude's work doesn't take the front (Toni, 2026-11-02: "Background");
    /// `/usr/bin/open` brings it to the front when the Owner wants to see it.
    static let openInBackground = "open() { /usr/bin/open -g \"$@\"; }\n"

    func run(
        _ command: String, folder: String?, wait: Duration, writes: [String] = [], why: String? = nil,
        keepMinutes: Int = 0, uses: Set<Fence.Use> = []
    ) async throws -> Snapshot {
        cleanup()
        let running = jobs.values.filter { !$0.isFinished }.count
        guard running < maxRunning else {
            throw Failure(
                message:
                    "\(running) commands are already running, the most Latchkey runs at once. Wait for one to finish or stop one (shell_run with job and stop); shell_check lists them."
            )
        }
        guard (0...1440).contains(keepMinutes) else {
            throw Failure(message: "keep_minutes is from 0 to 1440 (24 hours).")
        }
        let dir = folder.map { ($0 as NSString).expandingTildeInPath } ?? setup.home.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw Failure(message: "There's no folder at \(dir).")
        }
        let declared = try Fence.declared(writes, home: setup.home)
        counter += 1
        let id = "job\(counter)"
        let scratch = setup.scratchRoot.appending(path: "\(setup.launch)-\(id)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let mark = Fence.mark(of: scratch)
        try Data().write(to: mark)
        try Data().write(to: Fence.control(of: scratch))
        let fence = Fence.profile(
            scratch: scratch, folder: URL(filePath: dir), declared: declared, home: setup.home, own: setup.own,
            uses: uses, mark: mark, systemTemp: setup.systemTemp)
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/script")
        // "--": a command starting with "-" is the command, not more options for zsh.
        p.arguments = [
            "-q", "/dev/null", "/usr/bin/sandbox-exec", "-p", fence, "/bin/zsh", "-l", "-c", "--",
            uses.contains(.open) ? Self.openInBackground + command : command,
        ]
        p.currentDirectoryURL = URL(filePath: dir)
        var env = ProcessInfo.processInfo.environment
        for (k, v) in [
            "TERM": "dumb", "NO_COLOR": "1", "PAGER": "cat", "GIT_PAGER": "cat",
            "TMPDIR": scratch.path + "/", "LATCHKEY_SCRATCH": scratch.path,
            // Homebrew's own temporary folder is /private/tmp unless told (live check 2026-10-27).
            "HOMEBREW_TEMP": scratch.path,
        ] { env[k] = v }
        p.environment = env
        let stdin = Pipe()
        let stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stdout
        let job = Job(
            id: id, command: command, process: p, input: stdin.fileHandleForWriting, scratch: scratch,
            declared: declared, why: why, keepMinutes: keepMinutes)
        stdout.fileHandleForReading.readabilityHandler = { @Sendable h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { job.append(d) }
        }
        p.terminationHandler = { @Sendable [jobs = self] _ in
            // Let the last output arrive before the job counts as finished.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                job.finish()
                Task { await jobs.commandEnded(id) }
            }
        }
        try p.run()
        jobs[id] = job
        follow()
        Task.detached {  // note the session as soon as `script` has started the shell
            for _ in 0..<100 where job.session() == nil && !job.isFinished {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        return try await snapshot(job, waiting: min(wait, Self.maxWait))
    }

    func check(_ id: String, wait: Duration) async throws -> Snapshot {
        let job = try job(id)
        renew(job)
        return try await snapshot(job, waiting: min(wait, Self.maxWait))
    }

    func send(_ id: String, text: String, enter: Bool) async throws {
        let job = try job(id)
        guard !job.isFinished else { throw Failure(message: "\(id) has already finished.") }
        try job.input.write(contentsOf: Data((text + (enter ? "\n" : "")).utf8))
    }

    /// Ctrl-C, then after 3 s everything in the command's terminal session is asked to end, then
    /// killed (plan D3): the shell, what it started, and what those started, so nothing the
    /// command left in the background survives it. A stopped job's leftovers are removed too,
    /// whatever its lease.
    func stop(_ id: String) async throws -> Snapshot {
        let job = try job(id)
        if !job.isFinished {
            // Ctrl-C reaches only a shell that has started: sent before, it was lost, and every
            // stop right after a start waited out the 3 s (2026-10-29).
            let deadline = ContinuousClock.now + .seconds(2)
            while job.session() == nil, job.process.isRunning, ContinuousClock.now < deadline {
                await Self.pause(.milliseconds(20))
            }
            try? job.input.write(contentsOf: Data([0x03]))
            _ = await waitForEnd(job, .seconds(3), evenIfCancelled: true)
            await end(job)
        }
        await sweep(job)
        return try await snapshot(job, waiting: .zero)
    }

    /// What `end` did: the processes it signalled, by name, as they were named then, and those
    /// still there after it.
    struct Ended {
        var signalled: [pid_t: String] = [:]
        var stuck: [pid_t] = []
    }

    /// Ends whatever is left of a job: terminate, then kill after a second. The names are taken
    /// when the processes are signalled, so one found at the last moment is reported too (a
    /// snapshot taken before missed it under load, 2026-10-29).
    @discardableResult
    private func end(_ job: Job) async -> Ended {
        // Know the job's shell before anything is signalled: ending `script` first would orphan a
        // shell still starting, which then waits forever on its closed terminal (a test left one
        // on 2026-10-27).
        let deadline = ContinuousClock.now + .seconds(2)
        while job.session() == nil, job.process.isRunning, ContinuousClock.now < deadline {
            await Self.pause(.milliseconds(20))
        }
        track()
        var ended = Ended()
        func signal(_ sig: Int32) {
            for pid in job.members() {
                if ended.signalled[pid] == nil { ended.signalled[pid] = Processes.name(of: pid) }
                kill(pid, sig)
            }
        }
        guard job.hasProcesses else { return ended }
        signal(SIGTERM)
        if !(await gone(job, within: .seconds(1))) {
            signal(SIGKILL)
            _ = await gone(job, within: .seconds(2))
        }
        _ = await waitForEnd(job, .seconds(2), evenIfCancelled: true)
        ended.stuck = job.members()
        return ended
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
                exitCode: $0.isFinished ? $0.process.terminationStatus : nil,
                keptUntil: $0.swept ? nil : $0.leaseEnd)
        }
    }

    /// FR-309, FR-310, FR-326: called when Latchkey quits and when the Owner turns Shell off.
    /// Every running command ends with everything it started, all at the same time, and kept
    /// leftovers are removed.
    func stopAll() async {
        let running = jobs.values.filter { !$0.isFinished }
        await withTaskGroup(of: Void.self) { group in
            for job in running { group.addTask { _ = await self.end(job) } }
        }
        for job in jobs.values where !job.swept { await sweep(job) }
    }

    // MARK: leftovers (plan D6 to D12)

    /// The command has exited: with no lease, its leftovers go at once (FR-313); otherwise the
    /// lease starts (FR-314).
    private func commandEnded(_ id: String) async {
        guard let job = jobs[id], !job.swept else { return }
        track()
        if job.keepMinutes == 0 {
            await sweep(job)
        } else if job.leaseEnd == nil {
            renew(job)
        }
    }

    /// Checking a finished job with a lease starts its time again, never past 24 hours after
    /// the command finished.
    private func renew(_ job: Job) {
        guard job.keepMinutes > 0, !job.swept, let ended = job.ended else { return }
        let wanted = Date().addingTimeInterval(TimeInterval(job.keepMinutes) * 60)
        job.leaseEnd = min(wanted, ended.addingTimeInterval(Self.longestLease))
    }

    /// When the kept leftovers of the job are removed, if any are kept.
    func keptUntil(_ id: String) -> Date? {
        guard let job = jobs[id], !job.swept else { return nil }
        return job.leaseEnd
    }

    /// Called every minute: removes the leftovers whose lease has ended (FR-314).
    func tidy(now: Date = Date()) async {
        for job in jobs.values where !job.swept {
            if let end = job.leaseEnd, end <= now { await sweep(job) }
        }
        cleanup()
    }

    /// Stops what the job left running, moves its scratch folder to the Trash, and records what
    /// it left (FR-313, FR-316, FR-321, FR-323). Runs once; a second caller waits for the first.
    private func sweep(_ job: Job) async {
        if let running = job.sweep {
            await running.value
            return
        }
        let task = Task { await self.removeLeftovers(job) }
        job.sweep = task
        await task.value
    }

    private func removeLeftovers(_ job: Job) async {
        track()
        let found0 = job.members(scratchUsers: true)
        _ = job.learn(Set(found0.compactMap(Processes.id(of:))))
        var names = Dictionary(found0.map { ($0, Processes.name(of: $0)) }) { a, _ in a }
        let ended = await end(job)
        names.merge(ended.signalled) { first, _ in first }
        let stuck = ended.stuck
        // Latchkey's own `script` and the command's shell are left out by process id, not by
        // name: a background subshell is named zsh until it starts its program, and was left
        // out of what was stopped (a test caught it, 2026-10-29).
        let own: Set<pid_t> = [job.process.processIdentifier, job.session() ?? -1]
        let stopped = names.filter { !stuck.contains($0.key) && !own.contains($0.key) }.values
        let scratchUsed = Self.hasContents(job.scratch)
        if scratchUsed {
            setup.remove(job.scratch)
        } else {
            try? FileManager.default.removeItem(at: job.scratch)
        }
        let found = Leftovers.results(since: job.started, in: job.declared + [setup.home.appending(path: "Downloads")])
        let permanent = job.declared.filter { Fence.isPermanent($0, home: setup.home) }
        let report = Leftovers.describe(
            job: job.id, command: job.command, stopped: stopped.sorted(), stuck: stuck.map(Processes.name(of:)),
            scratch: scratchUsed, kept: found, permanent: permanent, why: job.why, home: setup.home)
        job.swept = true
        job.leaseEnd = nil
        try? FileManager.default.removeItem(at: Self.record(of: job, in: setup))
        try? FileManager.default.removeItem(at: job.mark)
        try? FileManager.default.removeItem(at: job.control)
        job.left = report.answer
        if let entry = report.entry { setup.report(entry, false) }
        if !stuck.isEmpty {
            setup.report(
                "A process of a command Claude ran couldn't be stopped: \(stuck.map(Processes.name(of:)).joined(separator: ", ")) (\(job.id): \(Leftovers.clip(job.command)))",
                true)
        }
    }

    /// The scratch folders and process records of earlier starts: only real files and folders
    /// (no links) named as Latchkey names them, `<launch>-job<n>`, and the same with `.pids`,
    /// `.mark`, or `.open`.
    private static func earlierEntries(in root: URL, launch: String) -> [URL] {
        let fm = FileManager.default
        let pattern = /^[0-9a-f]{8}-job[0-9]+(\.pids|\.mark|\.open)?$/
        return ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [])
            .filter { url in
                let name = url.lastPathComponent
                guard name.wholeMatch(of: pattern) != nil, !name.hasPrefix(launch + "-") else { return false }
                return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
            }
    }

    private static func hasContents(_ dir: URL) -> Bool {
        !((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty
    }

    /// At start (FR-324): stops the processes that jobs of an earlier run of this app left (from
    /// the record each job keeps beside its scratch folder), and moves the scratch folders of
    /// earlier runs to the Trash.
    func recoverEarlier() async {
        let fm = FileManager.default
        let entries = Self.earlierEntries(in: setup.scratchRoot, launch: setup.launch)
        let records = entries.filter { $0.pathExtension == "pids" }
        var earlier: [Processes.ID] = []
        for record in records {
            let text = (try? String(contentsOf: record, encoding: .utf8)) ?? ""
            earlier += text.split(separator: "\n").compactMap(Processes.ID.init(line:)).filter(Processes.alive)
            try? fm.removeItem(at: record)
        }
        // Processes carrying an earlier job's mark, which its record may have missed (FR-327).
        let seen = Set(earlier)
        for mark in entries where mark.pathExtension == "mark" {
            let control = Fence.control(of: mark.deletingPathExtension())
            earlier += Processes.marked(by: mark, control: control).compactMap(Processes.id(of:))
                .filter { !seen.contains($0) }
        }
        var stopped: [String] = []
        if !earlier.isEmpty {
            stopped = earlier.map { Processes.name(of: $0.pid) }
            earlier.forEach { kill($0.pid, SIGTERM) }
            try? await Task.sleep(for: .seconds(1))
            earlier.filter(Processes.alive).forEach { kill($0.pid, SIGKILL) }
        }
        var trashed = 0
        for file in entries where ["mark", "open"].contains(file.pathExtension) { try? fm.removeItem(at: file) }
        for folder in entries where !["pids", "mark", "open"].contains(folder.pathExtension) {
            if Self.hasContents(folder) {
                setup.remove(folder)
                trashed += 1
            } else {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        guard !stopped.isEmpty || trashed > 0 else { return }
        var parts: [String] = []
        if !stopped.isEmpty { parts.append("stopped \(stopped.sorted().joined(separator: ", "))") }
        if trashed > 0 { parts.append("moved \(trashed) scratch folder\(trashed == 1 ? "" : "s") to the Trash") }
        setup.report("Left from Shell commands before Latchkey last quit: " + parts.joined(separator: "; "), false)
    }

    /// What the last self-check found broken (FR-330).
    private(set) var fenceWarning: String?

    /// At start (FR-330): a throwaway program in a fence of its own must be refused a write and
    /// be found by its mark, since both rest on macOS features Apple could change (research.md).
    /// When either fails, Shell keeps running; every answer says so, and the Owner is notified
    /// once per kind of failure. Returns the warning, nil when all is well.
    @discardableResult
    func selfCheck(
        marked: @Sendable (URL, URL) -> [pid_t] = Processes.marked(by:control:)
    ) async -> String? {
        let fm = FileManager.default
        let probe = setup.scratchRoot.appending(path: "\(setup.launch)-check", directoryHint: .isDirectory)
        let mark = Fence.mark(of: probe)
        let control = Fence.control(of: probe)
        let outside = probe.appending(path: "outside")
        defer {
            for url in [probe, mark, control] { try? fm.removeItem(at: url) }
        }
        var broken: [String] = []
        do {
            try fm.createDirectory(at: probe, withIntermediateDirectories: true)
            try Data().write(to: mark)
            try Data().write(to: control)
            let quoted = { (u: URL) in "\"" + OwnFiles.real(u).path + "\"" }
            let p = Process()
            p.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
            p.arguments = [
                "-p",
                "(version 1)(allow default)(deny file-write* (literal \(quoted(outside))))(deny file-read* (literal \(quoted(mark))))",
                "/bin/sh", "-c", "echo x > \"$1\" 2>/dev/null; exec sleep 30", "check", outside.path,
            ]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            var found = false
            // A busy Mac at login can take seconds to start a program (a test run under load did).
            let deadline = ContinuousClock.now + .seconds(10)
            while p.isRunning, ContinuousClock.now < deadline {
                if Processes.name(of: p.processIdentifier) == "sleep" {
                    found = marked(mark, control).contains(p.processIdentifier)
                    break
                }
                await Self.pause(.milliseconds(20))
            }
            if !p.isRunning { broken.append("macOS's sandbox didn't start a program") }
            if fm.fileExists(atPath: outside.path) { broken.append("macOS's sandbox didn't refuse a write") }
            if p.isRunning, !found { broken.append("a program in a fence couldn't be found by its mark") }
            await Self.end(p)
        } catch {
            broken.append("the check couldn't run (\(error.localizedDescription))")
        }
        guard !broken.isEmpty else {
            fenceWarning = nil
            return nil
        }
        let warning =
            "[Warning: Latchkey's check of the Shell fence failed at start (\(broken.joined(separator: "; "))), probably after a macOS update. Commands run, but writes may not be fenced and what they leave running may not all be stopped. Tell the Mac's owner.]"
        if warning != fenceWarning {
            setup.report("Shell's fence check failed: \(broken.joined(separator: "; ")). Commands still run.", true)
        }
        fenceWarning = warning
        return warning
    }

    /// Ends a program without blocking a thread: blocking one in Swift's shared pool (as
    /// `waitUntilExit` did in the self-check) stalls every task waiting for a thread; the test
    /// suite hung that way (2026-10-29). Killed, then looked at every 10 ms for up to 2 s.
    static func end(_ p: Process) async {
        guard p.isRunning else { return }
        kill(p.processIdentifier, SIGKILL)
        let deadline = ContinuousClock.now + .seconds(2)
        while p.isRunning, ContinuousClock.now < deadline { await pause(.milliseconds(10)) }
    }

    private var follower: Task<Void, Never>?

    /// Follows the running jobs' processes every half second while any runs (plan D6), so a
    /// process that leaves the terminal session is still known as the job's.
    private func follow() {
        guard follower == nil else { return }
        follower = Task {
            while !Task.isCancelled {
                self.track()
                guard self.jobs.values.contains(where: { !$0.isFinished }) else { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            self.follower = nil
        }
    }

    /// Adds to each live job every process whose parent is one of its processes, until nothing
    /// new turns up, and keeps the list beside the job's scratch folder for a later start
    /// (FR-324).
    private func track() {
        let live = jobs.values.filter { !$0.swept }
        guard !live.isEmpty else { return }
        let table = Processes.table()
        for job in live {
            var family = Set(job.members())
            var grew = true
            while grew {
                grew = false
                for (pid, info) in table where !family.contains(pid) && family.contains(info.parent) {
                    family.insert(pid)
                    grew = true
                }
            }
            let ids = Set(family.compactMap { pid in table[pid].map { Processes.ID(pid: pid, start: $0.start) } })
            if job.learn(ids) {
                let lines = job.knownIDs.map(\.line).sorted().joined(separator: "\n")
                try? Data(lines.utf8).write(to: Self.record(of: job, in: setup), options: .atomic)
            }
        }
    }

    private static func record(of job: Job, in setup: ShellSetup) -> URL {
        job.scratch.deletingLastPathComponent().appending(path: job.scratch.lastPathComponent + ".pids")
    }

    /// The line every tool answer ends with while a command runs or its leftovers are kept
    /// (FR-322); nil when there is none.
    func statusLine(now: Date = Date()) -> String? {
        let time = Leftovers.clock
        let live = jobs.values.sorted { $0.started < $1.started }.compactMap { job -> String? in
            if !job.isFinished { return "\(job.id) running since \(job.started.formatted(time))" }
            if !job.swept, let end = job.leaseEnd {
                return "\(job.id)'s leftovers kept until \(end.formatted(time)) (check \(job.id) to keep them longer)"
            }
            return nil
        }
        guard !live.isEmpty else { return nil }
        return "[Shell: " + live.joined(separator: "; ") + "]"
    }

    /// True when `path` changed while a command ran or was kept and no live command declared
    /// it (FR-325).
    func unexplained(_ path: URL) -> Bool {
        let live = jobs.values.filter { !$0.isFinished || (!$0.swept && $0.leaseEnd != nil) }
        guard !live.isEmpty else { return false }
        let parts = OwnFiles.parts(path)
        return !live.contains { job in job.declared.contains { parts.starts(with: OwnFiles.parts($0)) } }
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
        let finished = job.isFinished
        if finished {
            if job.keepMinutes == 0 { await sweep(job) } else if job.leaseEnd == nil { renew(job) }
        }
        let raw = String(decoding: job.takeNew(), as: UTF8.self)
        let (text, dropped) = TerminalText.tail(TerminalText.clean(raw), limit: Self.outputLimit)
        let refused = Fence.refusals(in: text)
        var left: String?
        if finished {
            if let done = job.left, !job.leftShown {
                left = done
                job.leftShown = true
            } else if job.left == nil, let end = job.leaseEnd, !job.keptShown {
                left = Leftovers.kept(until: end, job: job.id)
                job.keptShown = true
            }
        }
        return Snapshot(
            job: job.id, command: job.command, output: text, dropped: dropped, finished: finished,
            exitCode: finished ? job.process.terminationStatus : nil, left: left,
            refusedWrite: refused.write, refusedHandoff: refused.handoff, refusedSettings: refused.settings,
            fenceWarning: fenceWarning)
    }

    /// Finished jobs stay 10 minutes; at most 20 are kept. Running ones are capped in `run`. A
    /// job whose leftovers are kept stays as long as they are.
    private func cleanup() {
        let now = Date()
        func held(_ job: Job) -> Bool { !job.swept && job.keepMinutes > 0 }
        for (id, job) in jobs where !held(job) {
            if let end = job.ended, now.timeIntervalSince(end) > 600 { jobs[id] = nil }
        }
        let done = jobs.values.filter { $0.isFinished && !held($0) }.sorted { $0.started < $1.started }
        for job in done.dropLast(20) { jobs[job.id] = nil }
    }
}

/// Where a Shell command lives and what it may touch (plan D6, D8, D9), and where its leftovers
/// are reported. Tests get their own, so they never touch the real Trash, Downloads, or log.
struct ShellSetup: Sendable {
    /// This start of the app; records and scratch folders of other starts are earlier leftovers.
    var launch: String
    var home: URL
    var scratchRoot: URL
    /// The user's own temporary and cache folders under /private/var/folders, which system
    /// frameworks write to. Tests leave it out: their own files live there.
    var systemTemp: URL?
    var own: OwnFiles
    /// Moves a folder to the Trash.
    var remove: @Sendable (URL) -> Void
    /// Records a Left Behind entry; `true` also notifies the Owner (FR-325).
    var report: @Sendable (String, Bool) -> Void

    /// The app's setup; under tests, a fresh one each time, so runners in tests that run side by
    /// side never share a folder or job names (2026-10-29).
    static var standard: ShellSetup {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ? .testing() : .app
    }

    static let app = ShellSetup(
        launch: newLaunch(), home: URL.homeDirectory,
        scratchRoot: URL.cachesDirectory.appending(
            path: "\(AppIdentity.current.supportFolderName)/Jobs", directoryHint: .isDirectory),
        systemTemp: OwnFiles.real(URL(filePath: NSTemporaryDirectory())).deletingLastPathComponent(),
        own: .standard,
        remove: { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        report: { text, notify in
            EventLog.shared.record(.leftovers, text, systemLog: false)
            if notify { Notifier.post(text) }
        })

    /// A test's own setup: a home and scratch folder of its own; removal deletes; reports go
    /// nowhere unless the test collects them.
    static func testing(
        root: URL = FileManager.default.temporaryDirectory.appending(path: "shell-test-\(UUID().uuidString)"),
        report: @escaping @Sendable (String, Bool) -> Void = { _, _ in }
    ) -> ShellSetup {
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: home.appending(path: "Downloads"), withIntermediateDirectories: true)
        return ShellSetup(
            launch: newLaunch(), home: OwnFiles.real(home),
            scratchRoot: OwnFiles.real(root).appending(path: "Jobs", directoryHint: .isDirectory), systemTemp: nil,
            own: OwnFiles(folders: [], settingsFolders: [], settingsPrefixes: []),
            remove: { try? FileManager.default.removeItem(at: $0) }, report: report)
    }

    static func newLaunch() -> String { String(UUID().uuidString.prefix(8)).lowercased() }
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
    /// A process by id and start time, so a process id the system has since given to another
    /// process is never mistaken for it.
    struct ID: Hashable, Sendable {
        var pid: pid_t
        var start: UInt64

        var line: String { "\(pid) \(start)" }

        init(pid: pid_t, start: UInt64) {
            self.pid = pid
            self.start = start
        }

        init?(line: Substring) {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let pid = pid_t(parts[0]), let start = UInt64(parts[1]) else { return nil }
            self.init(pid: pid, start: start)
        }
    }

    /// Parent and start time (microseconds) of a process the Owner can see.
    static func info(_ pid: pid_t) -> (parent: pid_t, start: UInt64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (pid_t(info.pbi_ppid), info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }

    static func id(of pid: pid_t) -> ID? { info(pid).map { ID(pid: pid, start: $0.start) } }

    static func alive(_ id: ID) -> Bool { info(id.pid)?.start == id.start }

    /// Every process with its parent and start time.
    static func table() -> [pid_t: (parent: pid_t, start: UInt64)] {
        var out: [pid_t: (parent: pid_t, start: UInt64)] = [:]
        for pid in all() { if let i = info(pid) { out[pid] = i } }
        return out
    }

    /// Processes started after `date` whose working folder, or one of whose open files, is in
    /// `folder`: a program the command started that left its terminal and its family, such as
    /// a browser with its profile in the scratch folder.
    static func using(_ folder: URL, startedAfter date: Date) -> [pid_t] {
        let prefix = OwnFiles.real(folder).path + "/"
        let since = UInt64(max(date.timeIntervalSince1970 - 1, 0) * 1_000_000)
        let me = getpid()
        return all().filter { pid in
            guard pid != me, let i = info(pid), i.start >= since else { return false }
            return paths(of: pid).contains { ($0 + "/").hasPrefix(prefix) }
        }
    }

    /// The working folder and the paths of the open files of a process.
    static func paths(of pid: pid_t) -> [String] {
        var out: [String] = []
        var cwd = proc_vnodepathinfo()
        let cwdSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &cwd, cwdSize) == cwdSize {
            out.append(
                withUnsafeBytes(of: cwd.pvi_cdir.vip_path) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
                })
        }
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return out }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 8)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard got > 0 else { return out }
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var vnode = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size) == size else { continue }
            out.append(
                withUnsafeBytes(of: vnode.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            )
        }
        return out
    }

    /// Every sandboxed process whose sandbox refuses reading `mark` but not `control` (an empty
    /// file beside it): a job's processes, wherever they went (FR-327). Another sandbox that
    /// keeps a process out of Latchkey's folder, or away from files, refuses both.
    static func marked(by mark: URL, control: URL) -> [pid_t] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: mark.path), fm.fileExists(atPath: control.path) else { return [] }
        let me = getpid()
        return all().filter { pid in
            pid != me && latchkey_is_sandboxed(pid) != 0 && latchkey_sandbox_denies_read(pid, mark.path) != 0
                && latchkey_sandbox_denies_read(pid, control.path) == 0
        }
    }

    static func name(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0
            ? String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : "process \(pid)"
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
