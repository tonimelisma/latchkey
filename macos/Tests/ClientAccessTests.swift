import Foundation
import Testing

@testable import Latchkey

/// The Claude apps with access to this Mac (FR-190 to FR-192): the `clients` and `revoke_client`
/// messages, and the list's state in the app, without AppKit.
@Suite struct ClientAccessTests {
    static let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    static let english = Locale(identifier: "en_US")
    static let utc = TimeZone(identifier: "UTC")!

    static func entry(
        _ id: String, name: String = "Claude", host: String = "claude.ai", redirect: String = "claude.ai",
        approved: Date = t0, lastUsed: Date? = nil
    ) -> ClientEntry {
        ClientEntry(id: id, name: name, host: host, redirect: redirect, approvedAt: approved, lastUsedAt: lastUsed)
    }

    static func decode(_ json: String) throws -> AgentMessage { try AgentMessage.decode(Data(json.utf8)) }

    static func clientsJSON(_ entries: String) -> String { #"{"type":"clients","clients":[\#(entries)]}"# }

    static let oneEntry =
        #"{"id":"a-1_B","name":"Claude","host":"claude.ai","redirect":"claude.ai","approved_at":"2026-10-24T18:30:00Z","last_used_at":null}"#

    // MARK: messages

    @Test func clientsMessageDecodes() throws {
        let message = try AgentMessage.decode(Data(contentsOf: Fixtures.file("valid/clients.json")))
        guard case .clients(let update) = message else { Issue.record("not clients"); return }
        #expect(update.clients.map(\.id) == ["apr_7Hq2-x_9", "apr_c0de"])
        let first = try #require(update.clients.first)
        #expect(first.name == "Claude")
        #expect(first.host == "claude.ai")
        #expect(first.redirect == "claude.ai")
        #expect(first.approvedAt == ISO8601DateFormatter().date(from: "2026-10-24T18:30:00Z"))
        #expect(first.lastUsedAt == ISO8601DateFormatter().date(from: "2026-10-25T07:15:00Z"))
        #expect(update.clients[1].redirect == ClientEntry.thisComputer)
        #expect(update.clients[1].lastUsedAt == nil)
    }

    @Test func neverUsedEncodesAsNull() throws {
        let data = try AgentMessage.clients(ClientsUpdate(clients: [Self.entry("a")])).encode()
        let object = try jsonObject(data) as! [String: Any]
        let first = (object["clients"] as! [[String: Any]])[0]
        #expect(first["last_used_at"] is NSNull)
    }

    @Test func fiftyEntriesAreAcceptedAndFiftyOneRejected() throws {
        func list(_ n: Int) -> String {
            Self.clientsJSON(
                (0..<n).map { Self.oneEntry.replacingOccurrences(of: "a-1_B", with: "id\($0)") }.joined(separator: ","))
        }
        guard case .clients(let update) = try Self.decode(list(50)) else { Issue.record("not clients"); return }
        #expect(update.clients.count == 50)
        #expect(throws: ProtocolError.self) { try Self.decode(list(51)) }
    }

    @Test(arguments: [
        "", "has space", "slash/x", "dot.x", "ümlaut", String(repeating: "a", count: 65),
    ])
    func idsOutsideTheShapeAreRejected(_ id: String) {
        let json = Self.clientsJSON(Self.oneEntry.replacingOccurrences(of: "a-1_B", with: id))
        #expect(throws: ProtocolError.self) { try Self.decode(json) }
    }

    @Test func aSixtyFourCharacterIDIsAccepted() throws {
        let id = String(repeating: "Z", count: 64)
        _ = try Self.decode(Self.clientsJSON(Self.oneEntry.replacingOccurrences(of: "a-1_B", with: id)))
    }

    @Test(arguments: ["id", "name", "host", "redirect", "approved_at"])
    func aMissingFieldIsRejected(_ field: String) throws {
        var object = try JSONSerialization.jsonObject(with: Data(Self.oneEntry.utf8)) as! [String: Any]
        object.removeValue(forKey: field)
        let entry = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        #expect(throws: ProtocolError.self) { try Self.decode(Self.clientsJSON(entry)) }
    }

    @Test func aRepeatedIDIsRejected() {
        #expect(throws: ProtocolError.self) { try Self.decode(Self.clientsJSON(Self.oneEntry + "," + Self.oneEntry)) }
    }

    @Test func revokeClientEncodesExactly() throws {
        let data = try AgentMessage.revokeClient(RevokeClient(id: "apr_7Hq2-x_9")).encode()
        #expect(
            try jsonObject(data) == jsonObject(Data(#"{"type":"revoke_client","id":"apr_7Hq2-x_9"}"#.utf8)))
    }

    /// FR-192: the app asks for the list by naming the feature in hello.
    @Test func helloCarriesTheClientsFeature() throws {
        let hello = Hello.make(
            deviceID: "dev_1", signature: "sig", appVersion: "0.8.10", osVersion: "26.1", tools: [], state: .sample)
        #expect(hello.features == ["clients", "audit"])
        let object = try jsonObject(AgentMessage.hello(hello).encode()) as! [String: Any]
        #expect(object["features"] as? [String] == ["clients", "audit"])
    }

    @Test func helloWithoutFeaturesStillDecodes() throws {
        let message = try AgentMessage.decode(Data(contentsOf: Fixtures.file("valid/hello.json")))
        guard case .hello(let hello) = message else { Issue.record("not hello"); return }
        #expect(hello.features == nil)
    }

    // MARK: list state

    /// An older relay never sends a list: the app then shows nothing, not "nobody has access".
    @Test func nothingIsShownBeforeAListArrives() {
        let access = ClientAccess()
        #expect(access.entries == nil)
        #expect(!access.isKnown)
        #expect(access.menuEntries.isEmpty)
        #expect(!access.hasMore)
    }

    @Test func anEmptyListIsKnownAndEmpty() {
        var access = ClientAccess()
        _ = access.received([], now: Self.t0)
        #expect(access.isKnown)
        #expect(access.entries == [])
    }

    @Test func eachListReplacesTheOneBefore() {
        var access = ClientAccess()
        _ = access.received([Self.entry("a"), Self.entry("b")], now: Self.t0)
        _ = access.received([Self.entry("c")], now: Self.t0)
        #expect(access.entries?.map(\.id) == ["c"])
    }

    @Test func theMenuShowsTheNewestFewAndOffersTheRest() {
        var access = ClientAccess()
        _ = access.received((0..<5).map { Self.entry("e\($0)") }, now: Self.t0)
        #expect(access.menuEntries.count == 5)
        #expect(!access.hasMore)
        _ = access.received((0..<7).map { Self.entry("e\($0)") }, now: Self.t0)
        #expect(access.menuEntries.map(\.id) == ["e0", "e1", "e2", "e3", "e4"])
        #expect(access.hasMore)
    }

    /// FR-191: one click sends exactly one revoke_client; a second click while it is in flight
    /// sends nothing.
    @Test func aRemovalSendsExactlyOneRevoke() {
        var access = ClientAccess()
        _ = access.received([Self.entry("a"), Self.entry("b")], now: Self.t0)
        #expect(access.beginRemoval("a", now: Self.t0) == RevokeClient(id: "a"))
        #expect(access.isRemoving("a"))
        #expect(!access.isRemoving("b"))
        #expect(access.beginRemoval("a", now: Self.t0.addingTimeInterval(1)) == nil)
        #expect(access.entries?.map(\.id) == ["a", "b"], "the entry stays listed, as being removed")
    }

    @Test func anUnknownEntryOrNoListSendsNothing() {
        var access = ClientAccess()
        #expect(access.beginRemoval("a", now: Self.t0) == nil)
        _ = access.received([Self.entry("a")], now: Self.t0)
        #expect(access.beginRemoval("zzz", now: Self.t0) == nil)
    }

    @Test func aNewListWithoutTheEntryFinishesTheRemoval() {
        var access = ClientAccess()
        let a = Self.entry("a")
        _ = access.received([a, Self.entry("b")], now: Self.t0)
        _ = access.beginRemoval("a", now: Self.t0)
        let outcomes = access.received([Self.entry("b")], now: Self.t0.addingTimeInterval(1))
        #expect(outcomes == [.removed(a)])
        #expect(!access.isRemoving("a"))
        #expect(access.failure == nil)
        #expect(access.entries?.map(\.id) == ["b"])
        #expect(access.expire(now: Self.t0.addingTimeInterval(60)).isEmpty, "nothing left to time out")
    }

    /// A list sent for another reason (someone was approved elsewhere) can cross the removal on
    /// the wire: the entry is still in it, and the removal keeps waiting for its own answer.
    @Test func aListThatStillHasTheEntryKeepsWaitingUntilTheDeadline() {
        var access = ClientAccess()
        let a = Self.entry("a")
        _ = access.received([a], now: Self.t0)
        _ = access.beginRemoval("a", now: Self.t0)
        #expect(access.received([Self.entry("new"), a], now: Self.t0.addingTimeInterval(1)).isEmpty)
        #expect(access.isRemoving("a"))
        #expect(access.received([Self.entry("new")], now: Self.t0.addingTimeInterval(2)) == [.removed(a)])
    }

    @Test func theEntryIsRestoredWhenNoListArrivesInTime() {
        var access = ClientAccess()
        let a = Self.entry("a")
        _ = access.received([a], now: Self.t0)
        _ = access.beginRemoval("a", now: Self.t0)
        #expect(access.expire(now: Self.t0.addingTimeInterval(ClientAccess.removalTimeout - 0.5)).isEmpty)
        #expect(access.isRemoving("a"))
        let outcomes = access.expire(now: Self.t0.addingTimeInterval(ClientAccess.removalTimeout))
        #expect(outcomes == [.failed(a, .noAnswer)])
        #expect(!access.isRemoving("a"))
        #expect(access.entries == [a], "restored")
        #expect(access.failure == "Couldn’t remove “Claude”. The relay didn’t answer. Try again.")
        #expect(access.beginRemoval("a", now: Self.t0.addingTimeInterval(10)) == RevokeClient(id: "a"), "can retry")
        #expect(access.failure == nil, "a new try clears the old message")
    }

    @Test func aRevokeThatCouldNotBeSentFailsAtOnce() {
        var access = ClientAccess()
        let a = Self.entry("a")
        _ = access.received([a], now: Self.t0)
        _ = access.beginRemoval("a", now: Self.t0)
        #expect(access.notSent("a") == [.failed(a, .disconnected)])
        #expect(!access.isRemoving("a"))
    }

    /// After a disconnect the list can't be trusted: it is hidden, and removals in flight fail.
    @Test func aDisconnectFailsRemovalsAndHidesTheList() {
        var access = ClientAccess()
        let a = Self.entry("a")
        _ = access.received([a, Self.entry("b")], now: Self.t0)
        _ = access.beginRemoval("a", now: Self.t0)
        #expect(access.disconnected() == [.failed(a, .disconnected)])
        #expect(!access.isKnown)
        #expect(access.entries == nil)
        #expect(!access.isRemoving("a"))
        #expect(
            access.failure
                == "Couldn’t remove “Claude”. This Mac lost its connection to the relay. Try again when it’s connected."
        )
        // The next connection's list is the truth again, and the entry is back in it.
        #expect(access.received([a, Self.entry("b")], now: Self.t0.addingTimeInterval(30)).isEmpty)
        #expect(access.entries?.map(\.id) == ["a", "b"])
        #expect(!access.isRemoving("a"))
    }

    @Test func aDisconnectWithNothingInFlightSaysNothing() {
        var access = ClientAccess()
        _ = access.received([Self.entry("a")], now: Self.t0)
        #expect(access.disconnected().isEmpty)
        #expect(access.failure == nil)
    }

    @Test func aFailureMessageGoesWhenTheEntryIsGone() {
        var access = ClientAccess()
        _ = access.received([Self.entry("a")], now: Self.t0)
        _ = access.beginRemoval("a", now: Self.t0)
        _ = access.expire(now: Self.t0.addingTimeInterval(60))
        #expect(access.failure != nil)
        _ = access.received([], now: Self.t0.addingTimeInterval(61))  // the late answer, or removed elsewhere
        #expect(access.failure == nil)
    }

    // MARK: wording

    @Test func aHostedAppSaysWhereItIsFrom() {
        let e = Self.entry("a")
        #expect(e.title == "Claude — claude.ai")
        #expect(e.originLine == "From claude.ai")
        #expect(e.scopeLine == "Covers Claude on the web, desktop, and phone")
        #expect(!e.isLocalProgram)
    }

    @Test func anotherHostMakesNoClaimAboutClaudesApps() {
        let e = Self.entry("a", name: "Other", host: "example.com", redirect: "example.com")
        #expect(e.title == "Other — example.com")
        #expect(e.scopeLine == nil)
    }

    @Test func aThisComputerEntrySaysItIsAProgramOnAComputer() {
        let e = Self.entry("a", name: "Claude Code", host: "claude.ai", redirect: ClientEntry.thisComputer)
        #expect(e.isLocalProgram)
        #expect(e.title == "Claude Code — on a computer")
        #expect(e.originLine == "A program on a computer, such as Claude Code")
        #expect(e.scopeLine == "One sign-in; each sign-in is listed separately")
    }

    @Test func longOrOddTextIsCutAndFlattened() {
        let long = Self.entry("a", name: String(repeating: "N", count: 200), host: String(repeating: "h", count: 300))
        #expect(long.displayName.count == ClientEntry.nameLimit)
        #expect(long.displayName.hasSuffix("…"))
        #expect(long.displayHost.count == ClientEntry.hostLimit)
        let odd = Self.entry("a", name: "  Cl\nau\u{0007}de\t[x](http://evil) **b**  ", host: "")
        #expect(odd.displayName == "Cl au de [x](http://evil) **b**", "shown as it is, on one line")
        #expect(Self.entry("a", name: " \n ").displayName == "Unnamed App")
        #expect(odd.title == "Cl au de [x](http://evil) **b**")
        #expect(odd.originLine == "From an unknown address")
    }

    @Test func timesAreInTheUsersLocale() {
        let approved = ISO8601DateFormatter().date(from: "2026-10-24T18:30:00Z")!
        let e = Self.entry("a", approved: approved, lastUsed: approved.addingTimeInterval(3600))
        // macOS puts a narrow no-break space before "PM".
        let approvedLine = e.approvedLine(locale: Self.english, timeZone: Self.utc)
            .replacingOccurrences(of: "\u{202F}", with: " ")
        #expect(approvedLine == "Approved Oct 24, 2026 at 6:30 PM")
        let now = approved.addingTimeInterval(3 * 3600)
        #expect(e.lastUsedLine(now: now, locale: Self.english) == "Last used 2 hours ago")
        #expect(Self.entry("b").lastUsedLine(now: now, locale: Self.english) == "Not used yet")
        // A clock a little behind the relay's must not say "in 5 seconds".
        let ahead = Self.entry("c", lastUsed: now.addingTimeInterval(5))
        #expect(ahead.lastUsedLine(now: now, locale: Self.english) == "Last used just now")
        let finnish = e.lastUsedLine(now: now, locale: Locale(identifier: "fi_FI"))
        #expect(finnish.contains("2 tuntia sitten"))
    }

    @Test func theConfirmationSaysWhatHappens() {
        let hosted = RemovalConfirmation(Self.entry("a"))
        #expect(hosted.title == "Remove access for “Claude”?")
        #expect(
            hosted.message
                == "Claude will stop working on this Mac from “Claude” (claude.ai) until you approve it again on Latchkey’s Allow page. This covers Claude on the web, desktop, and phone."
        )
        let local = RemovalConfirmation(Self.entry("b", name: "Claude Code", redirect: ClientEntry.thisComputer))
        #expect(
            local.message
                == "Claude will stop working on this Mac from “Claude Code” (a program on a computer) until you approve it again on Latchkey’s Allow page."
        )
    }

    /// FR-191: the removal is written to the Mac's activity log.
    @Test func outcomesBecomeActivityLogEntries() {
        let a = Self.entry("a")
        let done = RemovalOutcome.removed(a).activity(at: Self.t0)
        #expect(done.tool == "remove_access")
        #expect(done.arguments == "Claude — claude.ai")
        #expect(done.result == "Removed from this Mac’s menu. It no longer has access.")
        #expect(!done.isError)
        let failed = RemovalOutcome.failed(a, .noAnswer).activity(at: Self.t0)
        #expect(failed.isError)
        #expect(failed.result == "Couldn’t remove “Claude”. The relay didn’t answer. Try again.")
    }
}
