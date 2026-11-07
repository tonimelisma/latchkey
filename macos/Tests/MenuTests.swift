import Contacts
import Foundation
import Testing

@testable import Latchkey

/// The menu bar icon, the activity lines, and Pause (spec 001 FR-600 to FR-604, spec 002 FR-131;
/// Toni, 2026-10-26).
@Suite(.serialized) struct MenuTests {
    static func icon(
        _ status: ConnectionStatus, paused: Bool = false, setup: Bool = false, busy: Bool = false
    ) -> MenuIcon {
        MenuIcon(status: status, paused: paused, needsSetup: setup, busy: busy)
    }

    /// Reachable or not is the key's shape; never a color.
    @Test func theKeyIsSolidOnlyWhileClaudeCanReachTheMac() {
        #expect(Self.icon(.connected).symbol == "key.fill")
        #expect(Self.icon(.connected).mark == nil)
        for status: ConnectionStatus in [
            .notPaired, .connecting, .waiting(until: Date()), .signInAgain, .revoked, .replaced, .updateRequired,
            .suspended,
        ] {
            #expect(Self.icon(status).symbol == "key.slash", "\(status)")
        }
    }

    /// One mark at most: pause, then "!", then the working dot.
    @Test func oneMarkInOrderOfPrecedence() {
        #expect(Self.icon(.connected, busy: true).mark == "circle.fill")
        #expect(Self.icon(.connected, setup: true, busy: true).mark == "exclamationmark")
        #expect(Self.icon(.connected, paused: true, setup: true, busy: true).mark == "pause.fill")
        #expect(Self.icon(.waiting(until: Date()), paused: true).mark == "pause.fill", "paused while offline")
        #expect(Self.icon(.notPaired, busy: true).mark == nil, "no working dot without a connection")
    }

    @Test func theSpokenDescriptionSaysTheSame() {
        #expect(Self.icon(.connected).spoken == "Latchkey: Claude can reach this Mac")
        #expect(Self.icon(.connecting).spoken == "Latchkey: Claude can’t reach this Mac")
        #expect(Self.icon(.connected, paused: true).spoken == "Latchkey: paused")
        #expect(Self.icon(.connected, setup: true).spoken == "Latchkey: Claude can reach this Mac, setup unfinished")
        #expect(Self.icon(.connected, busy: true).spoken == "Latchkey: Claude can reach this Mac, working")
    }

    static func entry(_ tool: String, _ args: String, failed: Bool = false) -> Activity {
        Activity(
            at: Date(timeIntervalSince1970: 0), tool: tool, arguments: args, result: "{}", isError: failed,
            durationMS: 1)
    }

    /// Each line names the capability and what was acted on, not just the tool (FR-131).
    @Test func activityLinesNameWhatWasActedOn() {
        let time = Date(timeIntervalSince1970: 0).formatted(date: .omitted, time: .shortened)
        #expect(
            ActivityFormat.title(Self.entry("shell_run", #"{"command":"git status"}"#)) == "\(time)  Shell: git status")
        #expect(
            ActivityFormat.title(Self.entry("files_read", #"{"path":"~/notes.txt"}"#, failed: true))
                == "\(time)  Files: ~/notes.txt (failed)")
        #expect(
            ActivityFormat.title(Self.entry("browser_read", #"{"url":"https://example.com"}"#))
                == "\(time)  Browser: https://example.com")
        #expect(ActivityFormat.title(Self.entry("shell_check", "{}")) == "\(time)  Shell: check", "no target")
        let long = String(repeating: "a", count: 100)
        let title = ActivityFormat.title(Self.entry("shell_run", #"{"command":"\#(long)"}"#))
        #expect(title.hasSuffix("…") && title.count <= time.count + 2 + "Shell: ".count + 40)
        #expect(
            ActivityFormat.title(Self.entry("shell_run", #"{"command":"a\nb"}"#)) == "\(time)  Shell: a b",
            "one line")
        #expect(ActivityFormat.title(Self.entry("revoke_client", "not json")) == "\(time)  revoke client")
    }

    /// The newest five in the menu; the rest only in the Activity window (FR-131).
    @Test func fiveShown() {
        let all = (0..<10).map { Self.entry("shell_run", #"{"command":"c\#($0)"}"#) }
        let shown = ActivityFormat.menuItems(all)
        #expect(shown.map(\.arguments) == all.prefix(5).map(\.arguments))
        #expect(ActivityFormat.menuItems(Array(all.prefix(2))).count == 2)
    }

    /// Every approval is listed and every one not allowed is missing, whatever the levels: all are
    /// asked for at first run, so none is asked during use (FR-606, FR-623, Toni 2026-10-31).
    @Test func approvalsList() {
        var facts = ApprovalFacts(
            helper: false, fullDiskAccess: false, notes: .notAsked, messages: .denied, safari: .notAsked,
            contacts: .notDetermined, safariJavaScript: nil, screenRecording: false, accessibility: false)
        let all = Approval.list(facts)
        let ids = [
            "helper", "disk", "notifications", "notes", "messages", "contacts", "calendars", "reminders",
            "location", "localNetwork", "safari", "safariJS", "screen", "screenAccess", "accessibility",
        ]
        #expect(all.map(\.id) == ids)
        #expect(
            all.filter { $0.state == .missing }.map(\.id) == ids.filter { $0 != "localNetwork" },
            "everything is needed; Local Network is still being checked")

        facts = ApprovalFacts(
            helper: true, fullDiskAccess: true, notes: .allowed, messages: .allowed, safari: .allowed,
            contacts: .authorized, calendars: true, reminders: true, location: .allowed, safariJavaScript: true,
            screenRecording: true, accessibility: true, notifications: .allowed, localNetwork: true, screenAccess: true)
        #expect(Approval.list(facts).allSatisfy { $0.state == .allowed })

        // A refusal is missing too: setup's button then opens System Settings.
        facts.contacts = .denied
        facts.notifications = .denied
        facts.localNetwork = false
        #expect(
            Approval.list(facts).filter { $0.state == .missing }.map(\.id) == [
                "notifications", "contacts", "localNetwork",
            ])

        // macOS's second screen question counts only once Screen Recording itself is allowed.
        facts.screenAccess = false
        #expect(Approval.list(facts).first { $0.id == "screenAccess" }?.state == .missing)
        facts.notifications = .unknown
        #expect(Approval.list(facts).first { $0.id == "notifications" }?.state == .checking)
        facts.location = .servicesOff
        let off = Approval.list(facts).first { $0.id == "location" }
        #expect(off?.state == .missing)
        #expect(off?.purpose.contains("Location Services are off") == true)
    }

    /// DNS-SD's "policy denied" is how a Bonjour search says Local Network isn't allowed.
    @Test func localNetworkRefusalIsRecognised() {
        #expect(LocalNetwork.denied(.dns(-65570)))
        #expect(!LocalNetwork.denied(.dns(-65537)))
        #expect(!LocalNetwork.denied(.posix(.ECONNREFUSED)))
    }

    /// Pausing stops every running call with the pause answer, and every shell command (FR-603).
    @Test func pausingStopsRunningCallsAndShellCommands() async throws {
        let (gate, _) = AsyncStream.makeStream(of: Void.self)
        let read = LevelChangeTests.slow("files_read", readOnly: true, gate)
        let calls = RunningCalls()
        let answers = LevelChangeTests.Answers([:])
        await calls.start(
            LevelChangeTests.call("r1", "files_read"), run: { _ in await read.handler(.object([:])) },
            answer: { id, r in answers.mutate { $0[id] = r } })
        let jobs = ShellJobs()
        let (_, child) = try await ShellJobTests.startStubborn(jobs)

        await Pause.stopWork(
            calls: { reason in await calls.stop(reason) { id, r in answers.mutate { $0[id] = r } } }, shell: jobs)

        let answer = answers.value["r1"]
        #expect(answer?.isError == true)
        #expect(answer?.content.jsonText.contains("paused Latchkey") == true)
        #expect(await LevelChangeTests.until { await jobs.list().allSatisfy(\.finished) })
        #expect(await ShellJobTests.gone(child))
    }

    /// A call that arrives while paused is refused at once, and says nothing was done (FR-602).
    @Test func aCallWhilePausedIsRefusedAtOnce() {
        #expect(Pause.refused.isError)
        #expect(Pause.refused.content.jsonText.contains("paused Latchkey on this Mac"))
        #expect(Pause.refused.content.jsonText.contains("Nothing was done"))
        #expect(Pause.stopped.contains("may not have finished"))
    }

    /// Paused lasts across restarts (FR-604): stored, and read back.
    @Test func pausedIsStored() {
        let defaults = UserDefaults(suiteName: "MenuTests-\(UUID())")!
        #expect(Pause.isPaused(defaults) == false)
        Pause.set(true, defaults)
        #expect(Pause.isPaused(defaults))
        Pause.set(false, defaults)
        #expect(Pause.isPaused(defaults) == false)
    }
}
