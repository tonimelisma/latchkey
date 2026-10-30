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

    /// Every approval is listed, set up or not; only the ones the levels need count as missing,
    /// and they match what setup asks for (FR-606).
    @Test func approvalsList() {
        var facts = ApprovalFacts(
            helper: false, fullDiskAccess: false, notes: .notAsked, messages: .denied, safari: .notAsked,
            contacts: .notDetermined, safariJavaScript: nil, screenRecording: false, accessibility: false,
            level: { _ in .off })
        let all = Approval.list(facts)
        #expect(
            all.map(\.id) == [
                "helper", "disk", "notes", "messages", "contacts", "calendars", "reminders", "location", "safari",
                "safariJS", "screen", "accessibility",
            ])
        #expect(all.filter { $0.state == .missing }.map(\.id) == ["helper"], "everything off needs only keep-awake")

        facts.level = { [CapabilityRegistry.notes: .readWrite, CapabilityRegistry.messages: .readOnly][$0] ?? .off }
        facts.fullDiskAccess = true
        let some = Approval.list(facts)
        #expect(some.filter { $0.state == .missing }.map(\.id) == ["helper", "notes", "contacts"])
        #expect(some.first { $0.id == "disk" }?.state == .allowed)
        #expect(some.first { $0.id == "messages" }?.state == .notNeeded, "reading messages needs no control")

        facts.contacts = .denied
        #expect(Approval.list(facts).first { $0.id == "contacts" }?.state == .optional, "names are optional")
        facts.level = { _ in .off }
        facts.screenRecording = true
        #expect(Approval.list(facts).first { $0.id == "screen" }?.state == .allowed, "allowed shows even if unused")

        // Spec 007: the Contacts capability needs Contacts; Calendar, Reminders, Location their own.
        facts.level = {
            [
                CapabilityRegistry.contacts: .readOnly, CapabilityRegistry.calendar: .readWrite,
                CapabilityRegistry.location: .readWrite,
            ][$0] ?? .off
        }
        facts.calendars = true
        facts.location = .servicesOff
        let personal = Approval.list(facts)
        #expect(personal.first { $0.id == "contacts" }?.state == .missing, "denied is no longer optional")
        #expect(personal.first { $0.id == "calendars" }?.state == .allowed)
        #expect(personal.first { $0.id == "reminders" }?.state == .notNeeded)
        #expect(personal.first { $0.id == "location" }?.state == .missing)
        #expect(personal.first { $0.id == "location" }?.purpose.contains("Location Services are off") == true)
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
