import Foundation
import Testing

@testable import Latchkey

@Suite struct TerminalTextTests {
    @Test func removesControlCodes() {
        #expect(TerminalText.clean("\u{1B}[1;32mgreen\u{1B}[0m plain\r\n") == "green plain\n")
        #expect(TerminalText.clean("\u{1B}]0;title\u{07}text") == "text")
        #expect(TerminalText.clean("10%\r50%\r100%\ndone") == "100%\ndone", "progress redraws keep the last")
    }

    @Test func keepsTheEndOfLongOutput() {
        let (text, dropped) = TerminalText.tail(String(repeating: "x", count: 60_000) + "END", limit: 50_000)
        #expect(text.hasSuffix("END"))
        #expect(text.count == 50_000)
        #expect(dropped == 10_003)
    }
}

@Suite(.serialized) struct ShellJobTests {
    let jobs = ShellJobs()

    @Test func runsACommand() async throws {
        let r = try await jobs.run("echo hello; echo oops >&2", folder: nil, wait: .seconds(10))
        #expect(r.finished)
        #expect(r.exitCode == 0)
        #expect(r.output.contains("hello"))
        #expect(r.output.contains("oops"), "errors are shown too")
    }

    @Test func aCommandStartingWithADashIsTheCommand() async throws {
        // Without "--", zsh would read "-v; echo hi" as its own options and run nothing.
        let r = try await jobs.run("-v; echo hi", folder: nil, wait: .seconds(10))
        #expect(r.output.contains("hi"), "\(r.output)")
    }

    @Test func outputOverTheKeptMegabyteIsRead() async throws {
        // Past 1 MB the oldest output is dropped; reading after that crashed the app (scan 2026-10-24).
        let r = try await jobs.run(
            "head -c 2500000 /dev/zero | tr '\\0' a; sleep 1; echo; echo END", folder: nil, wait: .milliseconds(700))
        // Nothing yet is fine while other suites run (2026-10-29); the read past the dropped
        // megabyte is the one below.
        #expect(r.output.isEmpty || r.output.hasSuffix("a") || r.output.contains("END"))
        let later = try await jobs.check(r.job, wait: .seconds(10))
        #expect(later.finished)
        #expect(later.output.contains("END"))
        let again = try await jobs.check(r.job, wait: .zero)
        #expect(again.output.isEmpty, "nothing new")
    }

    @Test func reportsFailure() async throws {
        let r = try await jobs.run("exit 3", folder: nil, wait: .seconds(10))
        #expect(r.exitCode == 3)
    }

    @Test func usesTheFolderAndLoginPath() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = try await jobs.run("pwd; echo $PATH; echo $TERM", folder: dir.path, wait: .seconds(10))
        #expect(r.output.contains(dir.lastPathComponent))
        #expect(r.output.contains("/usr/bin"))
        #expect(r.output.contains("dumb"))
    }

    @Test func longCommandsBecomeJobs() async throws {
        let r = try await jobs.run("sleep 1.5; echo done", folder: nil, wait: .milliseconds(300))
        #expect(!r.finished)
        let later = try await jobs.check(r.job, wait: .seconds(10))
        #expect(later.finished)
        #expect(later.output.contains("done"))
        #expect(later.exitCode == 0)
    }

    @Test func answersPrompts() async throws {
        let r = try await jobs.run(
            "printf 'Name? '; read -r name; echo \"got $name\"", folder: nil, wait: .milliseconds(800))
        #expect(!r.finished)
        #expect(r.output.contains("Name?"))
        try await jobs.send(r.job, text: "Toni", enter: true)
        let after = try await jobs.check(r.job, wait: .seconds(10))
        #expect(after.output.contains("got Toni"))
        #expect(after.finished)
    }

    @Test func stopsAStuckCommand() async throws {
        let r = try await jobs.run("sleep 100", folder: nil, wait: .milliseconds(300))
        let start = Date()
        let stopped = try await jobs.stop(r.job)
        #expect(stopped.finished)
        #expect(Date().timeIntervalSince(start) < 8)
        #expect(await jobs.list().first { $0.job == r.job }?.finished == true)
    }

    /// Reads "PID:<n>" from a job's output.
    static func pid(in output: String) throws -> pid_t {
        let match = try #require(output.firstMatch(of: /PID:(\d+)/), "no PID in the output: \(output)")
        return try #require(pid_t(match.output.1))
    }

    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// True once the process is gone. A killed process stays visible for a moment, until the
    /// system has cleared it away, so this looks for up to 5 s (1 s wasn't enough while suites
    /// run side by side, 2026-10-29); it returns as soon as the process is gone.
    static func gone(_ pid: pid_t) async -> Bool {
        for _ in 0..<250 where alive(pid) { try? await Task.sleep(for: .milliseconds(20)) }
        return !alive(pid)
    }

    /// Starts `stubborn` and returns once its background process has printed its id, however
    /// busy the Mac (up to 5 s; a fixed 0.6 s wait failed while suites ran side by side).
    static func startStubborn(_ jobs: ShellJobs) async throws -> (job: String, child: pid_t) {
        let r = try await jobs.run(stubborn, folder: nil, wait: .milliseconds(200))
        var out = r.output
        let deadline = ContinuousClock.now + .seconds(5)
        while out.firstMatch(of: /PID:(\d+)/) == nil, ContinuousClock.now < deadline {
            out += try await jobs.check(r.job, wait: .milliseconds(200)).output
        }
        return (r.job, try pid(in: out))
    }

    /// A command that leaves a process in the background that ignores Ctrl-C, hangup and
    /// terminate, and then waits: only stopping the whole terminal session ends it.
    static let stubborn = LeftoversTests.leaver + "; sleep 300"

    @Test func stoppingAJobStopsEverythingItStarted() async throws {
        let (job, child) = try await Self.startStubborn(jobs)
        defer { kill(child, SIGKILL) }
        #expect(Self.alive(child))
        let stopped = try await jobs.stop(job)
        #expect(stopped.finished)
        #expect(await Self.gone(child), "a process the command left in the background survived")
    }

    /// FR-309, FR-310: quitting, or turning Shell off, stops every running command with all it
    /// started.
    @Test func stopAllStopsJobsAndEverythingTheyStarted() async throws {
        let (job, child) = try await Self.startStubborn(jobs)
        let other = try await jobs.run("sleep 300", folder: nil, wait: .milliseconds(100))
        defer { kill(child, SIGKILL) }
        let start = Date()
        await jobs.stopAll()
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(await Self.gone(child))
        let list = await jobs.list()
        #expect(list.first { $0.job == job }?.finished == true)
        #expect(list.first { $0.job == other.job }?.finished == true)
    }

    /// Finding 6: running commands are capped, so Claude can't pile them up without end.
    @Test func runningJobsAreCapped() async throws {
        let few = ShellJobs(maxRunning: 2)
        let a = try await few.run("sleep 300", folder: nil, wait: .milliseconds(100))
        _ = try await few.run("sleep 300", folder: nil, wait: .milliseconds(100))
        do {
            _ = try await few.run("echo third", folder: nil, wait: .seconds(5))
            Issue.record("a third command ran")
        } catch let f as ShellJobs.Failure {
            #expect(f.message.contains("2 commands are already running"), "\(f.message)")
            #expect(f.message.contains("stop"), "says what to do")
        }
        _ = try await few.stop(a.job)
        let again = try await few.run("echo fourth", folder: nil, wait: .seconds(10))
        #expect(again.output.contains("fourth"), "room again after one stopped")
        await few.stopAll()
        #expect(ShellJobs.maxRunning == 32)
    }

    @Test func unknownJobIsAnError() async {
        await #expect(throws: ShellJobs.Failure.self) { try await jobs.check("nope", wait: .zero) }
    }
}

@Suite struct ShellToolTests {
    @Test func toolsAndHints() {
        let t = Dictionary(
            uniqueKeysWithValues: ShellCapability.operations(jobs: ShellJobs()).map { ($0.tool.name, $0.tool) })
        #expect(Set(t.keys) == ["shell_run", "shell_check", "shell_send", "shell_stop", "shell_jobs"])
        #expect(t["shell_run"]?.annotations?.destructiveHint == true)
        #expect(t["shell_run"]?.annotations?.openWorldHint == true)
        #expect(t["shell_check"]?.annotations?.readOnlyHint == true)
        #expect(t["shell_jobs"]?.annotations?.readOnlyHint == true)
    }

    @Test func runToolReportsAndNotifies() async {
        let run = ShellCapability.operations(jobs: ShellJobs()).first { $0.tool.name == "shell_run" }!
        let r = await run.handler(.object(["command": .string("echo hi")]))
        #expect(!r.isError)
        #expect(r.content.jsonText.contains("hi"))
        #expect(r.content.jsonText.contains("exit status 0"))
        #expect(r.activity == "Claude ran: echo hi")
    }

    @Test func shellIsOnOrOff() {
        let cap = ShellCapability.make()
        #expect(cap.levels == [.off, .readWrite])
        #expect(cap.title(for: .readWrite) == "On")
        #expect(cap.entries(at: .readOnly).isEmpty)
    }
}

/// Builds inside the fence (spec 004 FR-333, FR-334; feedback report 2026-11-21): macOS won't
/// start a sandbox inside another, so SwiftPM's, Xcode's, and the Swift compiler's own sandboxes
/// failed with "sandbox_apply: Operation not permitted" and no Xcode project could build through
/// Shell. Latchkey turns those inner sandboxes off; the fence still applies.
@Suite struct FencedBuildTests {
    /// The app's fence, with the user's own temporary and cache folders writable: build tools
    /// save their files through them (atomic saves, xcrun's cache), as in the app.
    let jobs: ShellJobs = {
        var setup = ShellSetup.testing()
        setup.systemTemp = ShellSetup.app.systemTemp
        return ShellJobs(setup: setup)
    }()

    /// A small package with a SwiftUI view: building it compiles the manifest (SwiftPM's sandbox)
    /// and expands `@State` (the compiler's macro plugin, run in a sandbox of its own).
    private func package() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "fenced-build-\(UUID().uuidString)")
        let sources = dir.appending(path: "Sources/P")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "P", platforms: [.macOS(.v14)], products: [.library(name: "P", targets: ["P"])],
            targets: [.target(name: "P")])
        """.write(to: dir.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try """
        import SwiftUI
        public struct Counter: View {
            @State private var count = 0
            public init() {}
            public var body: some View { Button("\\(count)") { count += 1 } }
        }
        """.write(to: sources.appending(path: "Counter.swift"), atomically: true, encoding: .utf8)
        return dir
    }

    /// Runs `command` in `folder` and waits for it to finish, however long a build takes.
    private func finished(
        _ command: String, in folder: URL, uses: Set<Fence.Use> = []
    ) async throws -> (output: String, exit: Int32?, refusedWrite: Bool) {
        // SwiftPM's cache in the real home, which the app's fence allows (a test's home is its own).
        let cache = OwnFiles.real(URL.homeDirectory).appending(path: "Library/Caches/org.swift.swiftpm").path
        var r = try await jobs.run(
            command, folder: folder.path, wait: .seconds(30), writes: [cache], why: "SwiftPM's cache", uses: uses)
        var output = r.output
        var refused = r.refusedWrite
        for _ in 0..<20 where !r.finished {
            r = try await jobs.check(r.job, wait: .seconds(30))
            output += r.output
            refused = refused || r.refusedWrite
        }
        #expect(r.finished, "still running: \(output)")
        return (output, r.exitCode, refused)
    }

    @Test func swiftBuildsAPackageInsideTheFence() async throws {
        let dir = try package()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await finished("swift build 2>&1", in: dir)
        #expect(r.exit == 0, "\(r.output)")
        #expect(!r.output.contains("sandbox_apply"), "\(r.output)")
        #expect(!r.refusedWrite, "\(r.output)")
    }

    @Test func swiftPackageCommandsReadTheManifest() async throws {
        let dir = try package()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await finished("swift package describe 2>&1", in: dir)
        #expect(r.exit == 0, "\(r.output)")
        #expect(r.output.contains("Name: P"), "\(r.output)")
    }

    /// Xcode tells a package folder by macOS's file types (LaunchServices), so a package needs
    /// `open` declared; a project (`.xcodeproj`) doesn't (live check of Latchkey's own build).
    @Test func xcodebuildBuildsAPackageInsideTheFence() async throws {
        let dir = try package()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await finished(
            "xcodebuild -scheme P -destination platform=macOS -derivedDataPath dd build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20",
            in: dir, uses: [.open])
        #expect(r.output.contains("** BUILD SUCCEEDED **"), "\(r.output)")
        #expect(!r.output.contains("sandbox_apply"), "\(r.output)")
    }

    /// `make`, scripts, and other shells find the same `xcodebuild` and `swift`, and Xcode's own
    /// build settings come from the environment, so builds a project's own scripts start work too.
    @Test func buildToolsAreFoundFromScriptsToo() async throws {
        let r = try await jobs.run(
            "sh -c 'command -v xcodebuild; command -v swift'; cat \"$XCODE_XCCONFIG_FILE\"; xcodebuild -version | head -1",
            folder: nil, wait: .seconds(30))
        #expect(r.finished)
        let lines = r.output.split(separator: "\n").map(String.init)
        #expect(lines.count >= 2, "\(r.output)")
        #expect(lines.prefix(2).allSatisfy { $0.contains("/.latchkey/bin/") }, "Latchkey's own, first: \(r.output)")
        #expect(r.output.contains("SWIFTC_DISABLE_SANDBOX = YES"))
        #expect(r.output.contains("ENABLE_USER_SCRIPT_SANDBOXING = NO"))
        #expect(r.output.contains("DISABLE_TASK_SANDBOXING = YES"), "Core ML model compiles run in a task sandbox")
        #expect(r.output.contains("Xcode "), "the real xcodebuild still answers: \(r.output)")
    }

    /// Each job has Xcode's asset-catalog daemon (ibtoold) to itself (FR-333, 2026-11-21): the
    /// daemon outlives the build, keeps the fence of the job that started it, and every later
    /// asset-catalog build that found it, in any job or outside Latchkey, failed to write.
    @Test func eachJobHasItsOwnAssetCatalogDaemon() async throws {
        let a = try await jobs.run("echo \"[$IBCLIServerForcedRegistryName]\"", folder: nil, wait: .seconds(10))
        let b = try await jobs.run("echo \"[$IBCLIServerForcedRegistryName]\"", folder: nil, wait: .seconds(10))
        let name = { (o: String) in o.split(separator: "\n").first { $0.hasPrefix("[") }.map(String.init) ?? "" }
        #expect(name(a.output).count > 2, "\(a.output)")
        #expect(name(a.output) != name(b.output), "\(a.output) / \(b.output)")
    }

    /// Tests outside the fence (FR-335; Toni, 2026-11-21: "Test step outside fence"): a test app
    /// LaunchServices opens for a sandboxed xcodebuild gets none of Xcode's test settings, so it
    /// never connects ("The test runner hung before establishing connection"). Only Latchkey's
    /// own launcher leaves the fence, only with open, and the command can't replace it.
    @Test func onlyTheTestLauncherLeavesTheFenceAndOnlyWithOpen() {
        let setup = ShellSetup.testing()
        let launcher = URL(filePath: "/Applications/Latchkey.app/Contents/MacOS/LatchkeyXcodeTests")
        let scratch = setup.scratchRoot.appending(path: "x-job1")
        func profile(_ uses: Set<Fence.Use>) -> String {
            Fence.profile(
                scratch: scratch, folder: setup.home, declared: [], home: setup.home, own: setup.own, uses: uses,
                testLauncher: launcher)
        }
        let out = "(allow process-exec (literal \"\(launcher.path)\") (with no-sandbox))"
        #expect(profile([.open]).contains(out))
        #expect(profile([.open]).contains("(deny file-write* (subpath \"/Applications/Latchkey.app\"))"))
        #expect(!profile([]).contains("LatchkeyXcodeTests\") (with no-sandbox)"))
    }

    /// The job's `xcodebuild`: `test` builds inside the fence (`build-for-testing`), then hands
    /// the test step (`test-without-building`) to the launcher; without open, tests are refused
    /// with how to declare it; everything else goes to the real tool as before.
    @Test func xcodebuildTestBuildsInsideAndTestsThroughTheLauncher() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xcodebuild-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        func script(_ url: URL, _ text: String) throws {
            try Data(("#!/bin/sh\n" + text + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try script(real.appending(path: "xcodebuild"), #"echo "real $*"; [ -z "$FAIL" ]"#)
        let launcher = dir.appending(path: "launcher")
        try script(launcher, #"echo "launcher $*""#)
        func run(_ args: String, launcher: URL?, env: String = "") throws -> (out: String, status: Int32) {
            let scratch = dir.appending(path: "s-\(UUID().uuidString)")
            try Fence.Builds.write(in: scratch, testLauncher: launcher)
            let p = Process()
            p.executableURL = URL(filePath: "/bin/sh")
            let bin = Fence.Builds.bin(in: scratch).path
            p.arguments = ["-c", "\(env) PATH='\(bin):\(real.path):/usr/bin:/bin' xcodebuild \(args) 2>&1"]
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run()
            p.waitUntilExit()
            return (
                String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), p.terminationStatus
            )
        }
        let flags = "-IDEPackageSupportDisableManifestSandbox=YES -IDEPackageSupportDisablePluginExecutionSandbox=YES"
        let test = try run("-scheme 'My App' test -quiet", launcher: launcher)
        #expect(test.status == 0, "\(test.out)")
        #expect(
            test.out
                == "real \(flags) -scheme My App build-for-testing -quiet\nlauncher -scheme My App test-without-building -quiet\n"
        )
        let only = try run("-scheme S test-without-building", launcher: launcher)
        #expect(only.out == "launcher -scheme S test-without-building\n")
        let failed = try run("-scheme S test", launcher: launcher, env: "FAIL=1")
        #expect(failed.status != 0)
        #expect(!failed.out.contains("launcher"), "no tests after a failed build: \(failed.out)")
        let build = try run("-scheme S build", launcher: launcher)
        #expect(build.out == "real \(flags) -scheme S build\n")
        let closed = try run("-scheme S test", launcher: nil)
        #expect(closed.status == 64)
        #expect(closed.out.contains(#"uses: ["open"]"#), "\(closed.out)")
        #expect(!closed.out.contains("real "), "nothing built: \(closed.out)")
    }

    /// The launcher runs `xcodebuild test-without-building` and nothing else, with Apple's own
    /// xcodebuild whatever the command's environment says (it runs outside the fence).
    @Test func theLauncherRunsOnlyTheTestStep() throws {
        let launcher = try #require(Fence.Builds.testLauncher, "the launcher is in the app")
        func run(_ args: [String], env: [String: String] = [:]) throws -> (out: String, status: Int32) {
            let p = Process()
            p.executableURL = launcher
            p.arguments = args
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            p.waitUntilExit()
            return (
                String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), p.terminationStatus
            )
        }
        for args in [
            ["build"], ["-scheme", "S"], ["test"], ["test-without-building", "archive"],
            ["test-without-building", "-exportArchive"],
        ] {
            let r = try run(args)
            #expect(r.status == 64, "\(args): \(r.out)")
            #expect(r.out.contains("test-without-building"), "\(args): \(r.out)")
        }
        // A made-up developer folder would pick another xcodebuild: it is dropped.
        let r = try run(["test-without-building", "-version"], env: ["DEVELOPER_DIR": "/nonexistent"])
        #expect(r.status == 0, "\(r.out)")
        #expect(r.out.contains("Xcode "), "\(r.out)")
    }

    /// A program that still tries a sandbox of its own is told as such, not as a refused write.
    @Test func aNestedSandboxIsToldApart() {
        let refused = Fence.refusals(in: "sandbox-exec: sandbox_apply: Operation not permitted\n")
        #expect(!refused.write)
        #expect(refused.nestedSandbox)
        let write = Fence.refusals(in: "touch: /etc/x: Operation not permitted\n")
        #expect(write.write)
        #expect(!write.nestedSandbox)
    }

    /// An app icon made in Icon Composer needs macOS's file types, so the answer says to declare
    /// open (building Otos through Latchkey, 2026-11-21).
    @Test func anIconComposerIconAsksForOpen() {
        let refused = Fence.refusals(
            in: "error: Failed to create a catalog from the Icon Studio document: /x/Otos.icon\n")
        #expect(refused.handoff)
        #expect(Fence.handoffHint.contains("Icon Composer"))
    }

    @Test func theAnswerExplainsANestedSandbox() async throws {
        let run = try #require(ShellCapability.operations(jobs: jobs).first { $0.tool.name == "shell_run" })
        let r = await run.handler(
            .object(["command": .string("/usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true")]))
        let text = r.content.jsonText
        #expect(text.contains("sandbox of its own"), "\(text)")
        #expect(!text.contains("A write was refused"), "\(text)")
    }
}
