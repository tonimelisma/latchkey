import Foundation
import Testing

@testable import Latchkey

/// Collects what a test's jobs report for the Left Behind list.
final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, Bool)] = []
    var all: [(String, Bool)] { lock.withLock { items } }
    func add(_ text: String, _ notify: Bool) { lock.withLock { items.append((text, notify)) } }
}

/// Spec 004 FR-313 to FR-326: nothing a command leaves stays behind unless Claude asked to keep
/// it, writes go only where they're meant to, and what's left is reported. Real commands and a
/// real sandbox; each test has its own home, scratch folder, and record.
@Suite(.serialized) final class LeftoversTests {
    let reports = Reports()
    let root = FileManager.default.temporaryDirectory.appending(path: "leftovers-\(UUID().uuidString)")
    let setup: ShellSetup
    let jobs: ShellJobs

    init() {
        let r = reports
        setup = .testing(root: root, report: { r.add($0, $1) })
        jobs = ShellJobs(setup: setup)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var home: URL { setup.home }

    /// A process that ignores Ctrl-C, hangup and terminate, left in the background by a command
    /// that then ends at once: what the Chrome processes of 2026-10-25 did.
    static let leaver = "(trap '' HUP INT TERM; exec sleep 300) & echo PID:$!"

    @Test func aFinishedCommandLeavesNothingRunning() async throws {
        let r = try await jobs.run(Self.leaver, folder: nil, wait: .seconds(10))
        let child = try ShellJobTests.pid(in: r.output)
        defer { kill(child, SIGKILL) }
        #expect(r.finished)
        #expect(await ShellJobTests.gone(child), "the background process outlived its command")
        #expect(r.left?.contains("stopped what it left running") == true, "\(r.left ?? "nil")")
        #expect(reports.all.contains { $0.0.contains("stopped what it left running") && !$0.1 })
    }

    @Test func aProcessThatLeftTheTerminalIsStoppedToo() async throws {
        // A new session of its own, as setsid does: the terminal sweep alone misses it.
        let cmd = "perl -MPOSIX -e '$|=1; POSIX::setsid(); print \"PID:$$\\n\"; sleep 300' & sleep 0.5"
        let r = try await jobs.run(cmd, folder: nil, wait: .seconds(10), keepMinutes: 1)
        let child = try ShellJobTests.pid(in: r.output)
        defer { kill(child, SIGKILL) }
        #expect(getsid(child) == child, "it really left the terminal session")
        _ = try await jobs.stop(r.job)
        #expect(await ShellJobTests.gone(child), "a process that left the session survived")
    }

    @Test func aProgramWithFilesInScratchIsStopped() async throws {
        // Left the session and its family at once (no time to be followed), but keeps a file
        // open in the scratch folder, as a browser does with its profile there.
        let cmd =
            "perl -MPOSIX -e 'if (fork) { exit } POSIX::setsid(); open(my $f, \">\", \"$ENV{TMPDIR}/profile\"); $|=1; print \"PID:$$\\n\"; sleep 300' ; sleep 0.3"
        let r = try await jobs.run(cmd, folder: nil, wait: .seconds(10))
        let child = try ShellJobTests.pid(in: r.output)
        defer { kill(child, SIGKILL) }
        #expect(await ShellJobTests.gone(child), "a program using the scratch folder survived: \(r.output)")
    }

    @Test func keptLeftoversLastUntilTheLeaseEnds() async throws {
        let r = try await jobs.run(Self.leaver, folder: nil, wait: .seconds(10), keepMinutes: 5)
        let child = try ShellJobTests.pid(in: r.output)
        defer { kill(child, SIGKILL) }
        #expect(r.finished)
        try await Task.sleep(for: .milliseconds(500))
        #expect(ShellJobTests.alive(child), "kept as asked")
        #expect(r.left?.contains("kept running") == true, "\(r.left ?? "nil")")
        let until = try #require(await jobs.keptUntil(r.job))
        #expect(abs(until.timeIntervalSinceNow - 300) < 30)
        let line = try #require(await jobs.statusLine())
        #expect(line.contains("\(r.job)'s leftovers kept until"), "\(line)")
        await jobs.tidy(now: Date().addingTimeInterval(200))
        #expect(ShellJobTests.alive(child), "not before the lease ends")
        await jobs.tidy(now: Date().addingTimeInterval(400))
        #expect(await ShellJobTests.gone(child))
        #expect(await jobs.keptUntil(r.job) == nil)
        #expect(await jobs.statusLine() == nil)
    }

    @Test func checkingKeepsThemLongerButNotPastADay() async throws {
        let r = try await jobs.run(Self.leaver, folder: nil, wait: .seconds(10), keepMinutes: 1440)
        let child = try ShellJobTests.pid(in: r.output)
        defer { kill(child, SIGKILL) }
        let first = try #require(await jobs.keptUntil(r.job))
        try await Task.sleep(for: .milliseconds(1100))
        _ = try await jobs.check(r.job, wait: .zero)
        let second = try #require(await jobs.keptUntil(r.job))
        #expect(second <= first.addingTimeInterval(0.5), "never past 24 hours after it finished")
        #expect(abs(second.timeIntervalSinceNow - ShellJobs.longestLease) < 30)
        _ = try await jobs.stop(r.job)
        #expect(await ShellJobTests.gone(child), "stopping removes kept leftovers")
    }

    @Test func runningCommandsShowInEveryAnswer() async throws {
        let r = try await jobs.run("sleep 300", folder: nil, wait: .milliseconds(100))
        let line = try #require(await jobs.statusLine())
        #expect(line.hasPrefix("[Shell: \(r.job) running since"), "\(line)")
        _ = try await jobs.stop(r.job)
        #expect(await jobs.statusLine() == nil)
    }

    @Test func scratchFolderIsGivenAndRemoved() async throws {
        let r = try await jobs.run(
            "echo $LATCHKEY_SCRATCH; echo junk > \"$TMPDIR/junk.txt\"; mktemp; echo ok", folder: nil,
            wait: .seconds(10))
        #expect(r.output.contains("ok"), "\(r.output)")
        let scratch = setup.scratchRoot.appending(path: "\(setup.launch)-\(r.job)").path
        #expect(r.output.contains(scratch), "\(r.output)")
        #expect(!FileManager.default.fileExists(atPath: scratch), "scratch is removed when it finishes")
        #expect(r.left?.contains("moved its scratch folder to the Trash") == true)
    }

    @Test func writesOutsideTheFenceFailWithAHint() async throws {
        let outside = root.appending(path: "outside.txt")
        let tool = ShellCapability.operations(jobs: jobs).first { $0.tool.name == "shell_run" }!
        let answer = await tool.handler(.object(["command": .string("echo x > '\(outside.path)'")]))
        #expect(!FileManager.default.fileExists(atPath: outside.path), "a write outside the fence happened")
        #expect(answer.content.jsonText.contains("A write was refused"), "\(answer.content.jsonText)")
        let tmp = "/tmp/latchkey-fence-\(UUID().uuidString)"
        let r = try await jobs.run("echo x > \(tmp)", folder: nil, wait: .seconds(10))
        #expect(r.refusedWrite)
        #expect(!FileManager.default.fileExists(atPath: tmp), "/tmp must be fenced")
    }

    @Test func aBackgroundProcessStaysFenced() async throws {
        let outside = root.appending(path: "later.txt")
        let r = try await jobs.run(
            "(sleep 1; echo x > '\(outside.path)') & echo started", folder: nil, wait: .seconds(10), keepMinutes: 1)
        #expect(r.finished)
        try await Task.sleep(for: .seconds(2))
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        _ = try await jobs.stop(r.job)
    }

    @Test func declaredWritesWorkAndAreListed() async throws {
        let place = root.appending(path: "receipts")
        let r = try await jobs.run(
            "mkdir -p '\(place.path)' && echo pdf > '\(place.path)/r1.pdf' && echo saved", folder: nil,
            wait: .seconds(10), writes: [place.path], why: "save the receipts")
        #expect(r.output.contains("saved"), "\(r.output)")
        #expect(FileManager.default.fileExists(atPath: place.appending(path: "r1.pdf").path))
        #expect(r.left?.contains("kept the new files") == true, "\(r.left ?? "nil")")
        #expect(r.left?.contains("r1.pdf") == true)
        let entry = try #require(reports.all.first { $0.0.contains("r1.pdf") })
        #expect(entry.0.contains("save the receipts"))
        #expect(!entry.1, "results are never notified")
    }

    @Test func downloadsAndTheChosenFolderAreWritable() async throws {
        let work = root.appending(path: "project")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let r = try await jobs.run(
            "echo a > made.txt && echo b > '\(home.path)/Downloads/file.pdf' && echo ok", folder: work.path,
            wait: .seconds(10))
        #expect(r.output.contains("ok"), "\(r.output)")
        #expect(r.left?.contains("~/Downloads/file.pdf") == true, "\(r.left ?? "nil")")
    }

    @Test func theHomeFolderItselfIsNotWritable() async throws {
        let r = try await jobs.run("echo a > '\(home.path)/stray.txt'", folder: home.path, wait: .seconds(10))
        #expect(r.refusedWrite)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "stray.txt").path))
    }

    @Test func tooBroadDeclarationsAreRefused() async {
        for broad in ["~", "/", home.path, "~/Library", home.deletingLastPathComponent().path] {
            await #expect(throws: ShellJobs.Failure.self, "\(broad)") {
                _ = try await jobs.run("true", folder: nil, wait: .seconds(5), writes: [broad])
            }
        }
    }

    @Test func permanentPlacesNeedDeclaring() async throws {
        let library = home.appending(path: "Library")
        try FileManager.default.createDirectory(
            at: library.appending(path: "LaunchAgents"), withIntermediateDirectories: true)
        let support = library.appending(path: "Application Support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let r = try await jobs.run(
            "echo a > LaunchAgents/x.plist; echo b > 'Application Support/other.txt' && echo ok", folder: library.path,
            wait: .seconds(10), writes: [support.path], why: "test")
        #expect(r.output.contains("ok"), "an ordinary declared write works: \(r.output)")
        #expect(!FileManager.default.fileExists(atPath: library.appending(path: "LaunchAgents/x.plist").path))
        let inside = try await jobs.run(
            "echo a > LaunchAgents/y.plist", folder: library.path, wait: .seconds(10),
            writes: [library.appending(path: "LaunchAgents/../Fonts").path])
        #expect(!FileManager.default.fileExists(atPath: library.appending(path: "LaunchAgents/y.plist").path))
        _ = inside
        let rc = home.appending(path: ".zshrc")
        let d = try await jobs.run(
            "echo 'export X=1' >> '\(rc.path)' && echo ok", folder: nil, wait: .seconds(10), writes: [rc.path],
            why: "add X")
        #expect(d.output.contains("ok"), "\(d.output)")
        #expect(d.left?.contains("permanent change") == true, "\(d.left ?? "nil")")
    }

    @Test func newProjectsGetGitsSampleHooks() async throws {
        let projects = home.appending(path: "Downloads")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let elsewhere = home.appending(path: "Documents/q/.git")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let r = try await jobs.run(
            "git init -q p && ls p/.git/hooks | grep -c sample; mv p/.git/hooks/pre-commit.sample p/.git/hooks/pre-commit; mkdir ../Documents/q/.git/hooks",
            folder: projects.path, wait: .seconds(10))
        #expect(r.refusedWrite, "a sample renamed into a hook is refused: \(r.output)")
        let hooks = projects.appending(path: "p/.git/hooks")
        #expect(FileManager.default.fileExists(atPath: hooks.appending(path: "pre-commit.sample").path), "\(r.output)")
        #expect(!FileManager.default.fileExists(atPath: hooks.appending(path: "pre-commit").path))
        #expect(
            !FileManager.default.fileExists(atPath: elsewhere.appending(path: "hooks").path),
            "outside the allowed folders, no hooks folder either")
        let gone = try await jobs.run(
            "rm p/.git/hooks/pre-commit.sample && rm -rf p && echo gone", folder: projects.path, wait: .seconds(10))
        #expect(gone.output.contains("gone"), "a new project can be deleted again: \(gone.output)")
    }

    @Test func sshAndGitHooksNeedDeclaring() async throws {
        let ssh = home.appending(path: ".ssh")
        let repo = home.appending(path: "project")
        let hooks = repo.appending(path: ".git/hooks")
        for folder in [ssh, hooks] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let r = try await jobs.run(
            "echo a > .git/hooks/pre-commit; echo d > .Git/Hooks/post-commit; mkdir -p .git/modules/m/hooks; echo e > .git/modules/m/hooks/pre-push; echo b > '\(ssh.path)/config'; echo c > .git/HEAD && echo ok",
            folder: repo.path, wait: .seconds(10),
            writes: [repo.path])
        #expect(r.output.contains("ok"), "the rest of the project is writable: \(r.output)")
        #expect(r.refusedWrite)
        for hook in ["pre-commit", "post-commit", "../modules/m/hooks/pre-push"] {
            #expect(!FileManager.default.fileExists(atPath: hooks.appending(path: hook).path), "\(hook)")
        }
        #expect(!FileManager.default.fileExists(atPath: ssh.appending(path: "config").path))
        let d = try await jobs.run(
            "echo a > .git/hooks/pre-commit && echo b > '\(ssh.path)/config' && echo ok", folder: repo.path,
            wait: .seconds(10), writes: [hooks.path, ssh.appending(path: "config").path], why: "test")
        #expect(d.output.contains("ok"), "\(d.output)")
        #expect(d.left?.contains("permanent change") == true, "\(d.left ?? "nil")")
    }

    @Test func latchkeysOwnFilesAreNeverWritable() async throws {
        let own = root.appending(path: "own")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        var s = setup
        s.own = OwnFiles(folders: [own], settingsFolders: [], settingsPrefixes: [])
        let guarded = ShellJobs(setup: s)
        let r = try await guarded.run(
            "echo x > '\(own.path)/log'", folder: nil, wait: .seconds(10), writes: [own.path], why: "try")
        #expect(r.refusedWrite)
        #expect(!FileManager.default.fileExists(atPath: own.appending(path: "log").path))
    }

    @Test func leftoversOfAnEarlierRunAreRemovedAtStart() async throws {
        let earlier = "0ddba111"
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sleep")
        p.arguments = ["300"]
        try p.run()
        let pid = p.processIdentifier
        defer { kill(pid, SIGKILL) }
        let mine = Process()
        mine.executableURL = URL(filePath: "/bin/sleep")
        mine.arguments = ["300"]
        try mine.run()
        defer { kill(mine.processIdentifier, SIGKILL) }
        try FileManager.default.createDirectory(at: setup.scratchRoot, withIntermediateDirectories: true)
        let id = try #require(Processes.id(of: pid))
        // A record with a process id whose start time doesn't match is someone else's now.
        let reused = Processes.ID(pid: mine.processIdentifier, start: 1)
        try Data("\(id.line)\n\(reused.line)".utf8).write(to: setup.scratchRoot.appending(path: "\(earlier)-job1.pids"))
        let folder = setup.scratchRoot.appending(path: "\(earlier)-job1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: "f"))
        await jobs.recoverEarlier()
        #expect(await ShellJobTests.gone(pid))
        #expect(mine.isRunning, "a process id now used by another process is left alone")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(reports.all.contains { $0.0.contains("before Latchkey last quit") })
    }

    /// Live check 2026-10-27: stopping a kept job says what was removed.
    @Test func stoppingAKeptJobSaysWhatItRemoved() async throws {
        let r = try await jobs.run(Self.leaver, folder: nil, wait: .seconds(10), keepMinutes: 5)
        let child = try ShellJobTests.pid(in: r.output)
        defer { kill(child, SIGKILL) }
        #expect(r.left?.contains("kept running") == true)
        let stopped = try await jobs.stop(r.job)
        #expect(stopped.left?.contains("stopped what it left running") == true, "\(stopped.left ?? "nil")")
        #expect(await ShellJobTests.gone(child))
    }

    /// A job stopped the moment it started leaves no shell behind (a test left one waiting on its
    /// closed terminal, 2026-10-27).
    @Test func aJobStoppedAtOnceLeavesNoShell() async throws {
        for _ in 0..<5 {
            let r = try await jobs.run("sleep 300", folder: nil, wait: .zero)
            _ = try await jobs.stop(r.job)
        }
        try await Task.sleep(for: .milliseconds(300))
        let strays = Processes.all().filter { pid in
            Processes.paths(of: pid).contains { $0.hasPrefix(OwnFiles.real(root).path) }
        }
        #expect(strays.isEmpty, "\(strays.map(Processes.name(of:)))")
    }

    @Test func stopAllRemovesKeptLeftoversToo() async throws {
        let r = try await jobs.run(Self.leaver, folder: nil, wait: .seconds(10), keepMinutes: 60)
        let child = try ShellJobTests.pid(in: r.output)
        defer { kill(child, SIGKILL) }
        await jobs.stopAll()
        #expect(await ShellJobTests.gone(child))
    }

    @Test func unexplainedChangesOnlyWhileACommandIsLive() async throws {
        let agent = home.appending(path: "Library/LaunchAgents/x.plist")
        #expect(await !jobs.unexplained(agent), "no command live: it was the owner")
        let r = try await jobs.run("sleep 300", folder: nil, wait: .milliseconds(100))
        #expect(await jobs.unexplained(agent))
        _ = try await jobs.stop(r.job)
        let d = try await jobs.run(
            "sleep 300", folder: nil, wait: .milliseconds(100), writes: [agent.path], why: "install an agent")
        #expect(await !jobs.unexplained(agent), "declared")
        _ = try await jobs.stop(d.job)
    }

    /// Security review 2026-10-27: a command can't write into the folder of other jobs' scratch
    /// folders and process records, which Latchkey acts on at start.
    @Test func theJobsFolderIsOffLimitsButOwnScratchIsNot() async throws {
        let fake = setup.scratchRoot.appending(path: "deadbeef-job1.pids")
        let r = try await jobs.run(
            "echo '1 1' > '\(fake.path)'; echo ok > \"$LATCHKEY_SCRATCH/mine\" && echo wrote", folder: nil,
            wait: .seconds(10))
        #expect(!FileManager.default.fileExists(atPath: fake.path))
        #expect(r.output.contains("wrote"), "\(r.output)")
    }

    @Test func onlyLatchkeysOwnNamesAreActedOnAtStart() async throws {
        try FileManager.default.createDirectory(at: setup.scratchRoot, withIntermediateDirectories: true)
        let precious = root.appending(path: "precious")
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: setup.scratchRoot.appending(path: "deadbeef-job2"), withDestinationURL: precious)
        let odd = setup.scratchRoot.appending(path: "not-a-job")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: odd.appending(path: "f"))
        await jobs.recoverEarlier()
        #expect(FileManager.default.fileExists(atPath: precious.path), "a link is never followed")
        #expect(FileManager.default.fileExists(atPath: odd.path), "only names Latchkey gives")
    }

    @Test func theLibraryFolderAsTheCommandsFolderIsNotWritable() async throws {
        let library = home.appending(path: "Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let r = try await jobs.run("echo x > stray.txt", folder: library.path, wait: .seconds(10))
        #expect(r.refusedWrite)
    }

    /// Live check 2026-10-27: ordinary tools work inside the fence.
    @Test func everydayToolsWorkInsideTheFence() async throws {
        let r = try await jobs.run(
            "ps -o pid= -p $$ >/dev/null && echo PS-OK; top -l 1 -n 0 | head -1 | grep -q Processes && echo TOP-OK; echo $HOMEBREW_TEMP; env -u TMPDIR /bin/bash -c 'cat <<<HEREDOC-OK'",
            folder: nil, wait: .seconds(20))
        #expect(r.output.contains("PS-OK"), "\(r.output)")
        #expect(r.output.contains("TOP-OK"), "\(r.output)")
        #expect(r.output.contains(setup.scratchRoot.path), "Homebrew's temporary folder is the scratch folder")
        #expect(r.output.contains("HEREDOC-OK"), "bash here-documents without TMPDIR, as in Homebrew: \(r.output)")
    }

    @Test func leaseOutOfRangeIsRefused() async {
        await #expect(throws: ShellJobs.Failure.self) {
            _ = try await jobs.run("true", folder: nil, wait: .seconds(5), keepMinutes: 1441)
        }
    }
}

@Suite struct LeftoversWordingTests {
    @Test func nothingLeftSaysSo() {
        let r = Leftovers.describe(
            job: "job1", command: "true", stopped: [], stuck: [], scratch: false, kept: .init(files: [], more: 0),
            permanent: [], why: nil, home: URL(filePath: "/Users/x"))
        #expect(r.answer == "[Left behind: nothing]")
        #expect(r.entry == nil)
    }

    @Test func listsAtMostTwentyFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "found-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()
        for i in 0..<25 { try Data().write(to: dir.appending(path: "f\(i)")) }
        let found = Leftovers.results(since: start, in: [dir])
        #expect(found.files.count == 20)
        #expect(found.more == 5)
    }

    @Test func showBindsLeftBehindToItsCategory() {
        var q = ActivityQuery()
        q.show = .leftBehind
        #expect(q.kind == .event)
        #expect(q.tool == "leftovers")
        #expect(q.show == .leftBehind)
        #expect(q.toolChoice == nil, "the Tool filter shows All Tools, not a blank")
        q.toolChoice = "shell_run"
        #expect(q.show == .leftBehind, "and can't undo Left Behind")
        q.show = .events
        #expect(q.tool == nil)
        #expect(ActivityFormat.eventTitle("leftovers") == "Left Behind")
    }

    @Test func toolResultsCanCarryAJobsLine() {
        var r = ToolResult.text("hi")
        r.appendText("[Shell: job1 running since 10:00]")
        #expect(r.content.jsonText.contains("\\n[Shell: job1 running"), "on a line of its own")
        #expect(r.content.jsonText.contains("hi"))
    }

    @Test func shellRunDescribesTheFence() throws {
        let run = try #require(ShellCapability.tools(jobs: ShellJobs()).first { $0.tool.name == "shell_run" })
        let text = run.tool.description ?? ""
        #expect(text.contains("LATCHKEY_SCRATCH"))
        #expect(text.contains("keep_minutes"))
        let props = run.tool.inputSchema["properties"]
        #expect(props?["writes"] != nil)
        #expect(props?["keep_minutes"] != nil)
        #expect(props?["why"] != nil)
    }
}

@Suite struct PermanentWatchTests {
    /// FR-325: a new launch agent and a changed shell startup file are noticed.
    @Test func noticesLaunchAgentsAndStartupFiles() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
        let agents = home.appending(path: "Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let seen = Reports()
        let watch = PermanentWatch(home: home) { seen.add($0.lastPathComponent, false) }
        try await Task.sleep(for: .milliseconds(300))
        try Data("x".utf8).write(to: agents.appending(path: "com.example.agent.plist"))
        try Data("export X=1".utf8).write(to: home.appending(path: ".zshrc"))
        try Data("x".utf8).write(to: home.appending(path: "notes.txt"))
        for _ in 0..<40 where seen.all.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        let names = Set(seen.all.map(\.0))
        #expect(names.contains("com.example.agent.plist"), "\(names)")
        #expect(names.contains(".zshrc"), "\(names)")
        #expect(!names.contains("notes.txt"), "ordinary files aren't watched")
        _ = watch
    }
}

@Suite struct IdleBrowserTests {
    /// FR-411: Claude's Safari window closes after 30 minutes unused, and only that window.
    @Test func closesClaudesWindowWhenIdle() async throws {
        let runner = RecordingRunner(answers: ["42", "{}"])
        let browser = SafariBrowser(scripts: runner, settleLimit: .milliseconds(50))
        _ = try? await browser.open("https://example.com", newTab: false)
        #expect(await !browser.closeIfIdle(after: 1800), "just used")
        #expect(await browser.closeIfIdle(after: 1800, now: Date().addingTimeInterval(1900)))
        let last = try #require(runner.calls.last)
        #expect(last.0 == SafariBrowser.Script.close)
        #expect(last.1 == ["42"])
        #expect(await !browser.closeIfIdle(after: 0), "no window any more")
    }
}

/// Answers scripts in order, repeating the last answer, and remembers each call.
final class RecordingRunner: ScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String]
    private var made: [(String, [String])] = []
    var calls: [(String, [String])] { lock.withLock { made } }
    init(answers: [String]) { self.answers = answers }
    func run(_ script: String, _ args: [String]) async throws -> String {
        lock.withLock {
            made.append((script, args))
            return answers.count > 1 ? answers.removeFirst() : answers.first ?? ""
        }
    }
}
