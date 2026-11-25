import Foundation
import Testing
import WebKit

@testable import Latchkey

/// Spec 014 FR-1443 to FR-1447, FR-1454: this Mac's part of a problem report, and the page record
/// of Latchkey's own browser (memory only, from a world the page can't see).
@MainActor @Suite struct ReportPartTests {
    let base = URL(string: "https://test.example/")!

    /// Waits up to 10 s for the record to hold an event of each kind.
    private func waitFor(_ kinds: Set<String>, in b: LockedBrowser) async throws -> [PageRecord.Event] {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let seen = Set(b.record.events.map(\.kind))
            if kinds.isSubset(of: seen) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return b.record.events
    }

    /// FR-1446: errors and failed promises are recorded, the page sees no trace of the recorder,
    /// and the record is gone once the page closes.
    @Test func thePageIsRecordedFromAWorldItCantSee() async throws {
        let b = LockedBrowser()
        _ = try await b.open(
            html: """
                <p>Shop</p>
                <script>
                  setTimeout(() => { throw new Error('checkout script broke') }, 10);
                  Promise.reject(new Error('fulfilment call refused'));
                </script>
                """, base: base)
        let events = try await waitFor(["error", "rejection", "load"], in: b)
        #expect(
            events.contains { $0.kind == "error" && ($0.text ?? "").contains("checkout script broke") }, "\(events)")
        #expect(events.contains { $0.kind == "rejection" }, "its reason may be the page's own, unreadable here")
        #expect(events.contains { $0.kind == "load" })
        // The page's own world has no handler, and none of its functions were replaced.
        #expect(
            try await b.run("String(!!(window.webkit && window.webkit.messageHandlers.latchkeyRecord))") == "false")
        #expect(try await b.run("String(console.error).includes('[native code]')") == "true")
        b.discard()
        #expect(b.record.events.isEmpty, "gone with the page")
    }

    /// FR-1447: the page as it is; every field's value blanked, hidden fields too; cookie names
    /// only; whether it draws.
    @Test func thePageIsDescribedWithItsFieldsBlanked() async throws {
        let b = LockedBrowser()
        defer { b.discard() }
        _ = try await b.open(
            html: """
                <form><input type="hidden" name="csrf" value="tok-12345-secret">
                <input id="u" value="preset-value-9"><textarea id="t">draft text 77</textarea>
                <button type="submit">Check out</button></form>
                <meta name="csrf-token" content="meta-tok-66"><div contenteditable="true">note 31</div>
                <script>window.__STATE = {token: 'inline-tok-55'}</script>
                """, base: base)
        _ = try await b.run("document.getElementById('u').value = 'typed-4242'; 1")
        guard case .object(let page) = await b.describe(name: "pk4m2", macLocked: true, displayAsleep: false) else {
            Issue.record("not an object")
            return
        }
        let text = JSONValue.object(page).jsonText
        #expect(page["name"] == .string("pk4m2"))
        #expect(page["where"] == .string("own"))
        #expect(page["address"] == .string("https://test.example/"))
        #expect(text.contains("Check out"), "the page's own words stay")
        for secret in [
            "tok-12345-secret", "preset-value-9", "typed-4242", "draft text 77", "meta-tok-66", "note 31",
            "inline-tok-55",
        ] {
            #expect(!text.contains(secret), "\(secret) is blanked")
        }
        guard case .object(let drawing)? = page["drawing"] else {
            Issue.record("no drawing state: \(text.prefix(500))")
            return
        }
        #expect(drawing["mac_locked"] == .bool(true))
        #expect(drawing["visibility"] != nil)
        #expect(page["record"] != nil)
        #expect(page["cookies"] != nil)
    }

    /// Request addresses keep their query's names, never its values.
    @Test func addressesLoseTheirQueryValues() {
        #expect(
            PageRecord.shownAddress("https://shop.example/api/checkout?token=abc123&cart=9#x")
                == "https://shop.example/api/checkout?token=%E2%80%A6&cart=%E2%80%A6"
                || PageRecord.shownAddress("https://shop.example/api/checkout?token=abc123&cart=9#x")
                    == "https://shop.example/api/checkout?token=…&cart=…")
        #expect(!PageRecord.shownAddress("https://user:pw@shop.example/a?x=1").contains("pw"))
    }

    /// The record keeps the newest events only.
    @Test func theRecordIsBounded() {
        let r = PageRecord()
        for i in 0..<(PageRecord.limit + 20) { r.add(PageRecord.Event(time: "t", kind: "request", text: "\(i)")) }
        #expect(r.events.count == PageRecord.limit)
        #expect(r.events.last?.text == "\(PageRecord.limit + 19)")
        #expect(r.dropped == 20)
    }

    /// FR-1444: the part holds the span's public log lines (never a private one), this Mac's copy
    /// of the chat's calls (never another chat's), and the pages; it fits the size asked.
    @Test func thePartHoldsTheLogTheCallsAndThePages() async throws {
        let now = Date()
        let entries: ReportPart.Entries = { _, _ in
            [
                Activity.event(.connection, "Connected to the relay"),
                Activity.event(.connection, "Connected to relay.example.net", systemLog: false),
                Activity(
                    at: now, tool: "browser_act", arguments: "{}", result: #"[{"type":"text","text":"clicked e5"}]"#,
                    isError: false, durationMS: 120, callID: "call_A"),
                Activity(
                    at: now, tool: "files_read", arguments: "{}", result: #"[{"type":"text","text":"another chat"}]"#,
                    isError: false, durationMS: 3, callID: "call_B"),
            ]
        }
        let args = JSONValue.object([
            "report": .string("fb_X"), "since": .number(0), "until": .number(now.timeIntervalSince1970 * 1000 + 1000),
            "call_ids": .array([.string("call_A")]), "pages": .array([.string("pk4m2"), .string("gone1")]),
            "max_bytes": .number(100_000),
        ])
        let result = await ReportPart.answer(args, entries: entries) { names in
            ReportPart.Described(
                pages: [.object(["name": .string(names[0]), "source": .string("<html>cart</html>")])],
                notes: ["page gone1 isn't open any more"])
        }
        #expect(!result.isError)
        guard case .array(let items) = result.content, case .string(let text)? = items.first?["text"] else {
            Issue.record("no text")
            return
        }
        let part = try JSONDecoder().decode(ReportPart.Part.self, from: Data(text.utf8))
        #expect(part.log.map(\.text) == ["Connected to the relay"], "only the public line")
        #expect(part.calls.map(\.callID) == ["call_A"])
        #expect(text.contains("clicked e5") && !text.contains("another chat") && !text.contains("relay.example.net"))
        #expect(part.pages.count == 1 && part.notes.contains("page gone1 isn't open any more"))

        let small = ReportPart.fit(part, maxBytes: 200)
        #expect(small != nil && small!.utf8.count <= 200)
    }

    /// Security review 2026-11-25: the Mac gives a part only while it shares reports itself.
    @Test func noPartUnlessThisMacShares() {
        #expect(ReportPart.refusal(sharing: true, blocked: false, paused: false) == nil)
        #expect(ReportPart.refusal(sharing: false, blocked: false, paused: false)?.isError == true)
        #expect(ReportPart.refusal(sharing: true, blocked: true, paused: false)?.isError == true)
        #expect(ReportPart.refusal(sharing: true, blocked: false, paused: true)?.isError == true)
    }

    /// FR-1443: announced in hello, so only a relay that knows the request asks; the relay's name
    /// for the tool (agentproto.ReportPartTool).
    @Test func theFeatureIsAnnounced() {
        #expect(Hello.supportedFeatures.contains("report_part"))
        #expect(ReportPart.tool == "latchkey_report_part")
    }

    /// FR-1454: the setting says plainly what a report holds and what is left out.
    @Test func theSettingSaysWhatAReportHolds() {
        let t = SharingText.explanation
        let said = [
            "tool calls", "logs", "web pages", "screenshot", "Passwords, codes, and cookie values", "turn this off",
        ]
        for words in said {
            #expect(t.contains(words), "\(words)")
        }
    }
}
