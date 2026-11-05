import Foundation
import Testing
import WebKit

@testable import Latchkey

/// Spec 012 plan D2: the bridge, run in a real WebKit page against a stand-in of WhatsApp Web's
/// modules (no network). The stand-in behaves as WhatsApp Web did in the tests of 2026-11-02 and
/// 2026-11-03: message ids have no `_serialized`, a text send's promise can settle long after the
/// message is out, and media goes through prepRawMedia.
@MainActor @Suite(.serialized) struct WhatsAppBridgeTests {
    /// WhatsApp Web, pretended: three chats, a contact lookup, and sending that adds messages.
    static let fakeWhatsApp = #"""
        const wid = (s) => { const [user, server] = s.split('@'); return { user, server, _serialized: s }; };
        let seq = 0;
        const key = (fromMe, chat) => { const id = 'K' + (++seq); return { fromMe, remote: chat, id, toString() { return fromMe + '_' + chat + '_' + id; } }; };
        const collection = (items) => ({ items, getModelsArray() { return this.items; }, get length() { return this.items.length; } });
        function msg(chat, o) {
          const m = Object.assign({ id: key(!!o.fromMe, chat), t: o.t, type: o.type || 'chat', body: o.body || '', ack: o.ack || 0 }, o.extra || {});
          return m;
        }
        function chat(id, name, t, unread, msgs) {
          const c = { id: wid(id), formattedTitle: name, t, unreadCount: unread, contact: { name }, older: [] };
          c.msgs = collection(msgs.map((m) => msg(id, m)));
          return c;
        }
        const chats = [
          chat('15550001111@c.us', 'Sarah Lee', 300, 0, [{ t: 290, body: 'see you at six' }, { t: 300, body: 'ok', fromMe: true, ack: 3 }]),
          chat('120363000@g.us', 'Family', 500, 2, [{ t: 450, body: 'dinner saturday?', extra: { author: wid('15550002222@c.us') } }, { t: 500, body: 'yes', extra: { author: wid('15550003333@c.us') } }]),
          chat('99900011122233@lid', 'Sam Ito', 100, 0, [{ t: 100, body: 'hi' }]),
          chat('15550004444@c.us', 'Sam Ross', 90, 0, []),
          chat('15559990000@c.us', 'Toni (You)', 80, 0, [{ t: 80, body: 'note to self', fromMe: true, ack: 3 }]),
        ];
        window.__reactions = [];
        window.__deleted = [];
        chats[1].older = [msg('120363000@g.us', { t: 400, body: 'older one' })];
        const contacts = { '15550002222@c.us': { name: 'Mum' }, '15550003333@c.us': { pushname: 'Dad' } };
        window.__sent = [];
        window.__mode = 'normal';
        function deliver(c, m, after) { setTimeout(() => { m.ack = 1; }, after); c.msgs.items.push(m); }
        const modules = {
          WAWebCollections: { Chat: { getModelsArray: () => chats }, Contact: { get: (w) => contacts[w._serialized] } },
          WAWebSocketModel: { Socket: { state: 'CONNECTED' } },
          WAWebWidFactory: { createWid: wid },
          WAWebFindChatAction: { findOrCreateLatestChat: async (w) => { const c = chat(w._serialized, '+' + w.user, 0, 0, []); chats.push(c); return { chat: c }; } },
          WAWebSendTextMsgChatAction: {
            sendTextMsgToChat: (c, text, opts) => {
              window.__sent.push({ chat: c.id._serialized, text, quoted: (opts && opts.quotedMsg && opts.quotedMsg.id.id) || null });
              if (window.__mode === 'reject') return Promise.reject(new Error('blocked'));
              if (window.__mode === 'never') return new Promise(() => {});
              deliver(c, msg(c.id._serialized, { t: 999, body: text, fromMe: true, extra: opts && opts.quotedMsg ? { quotedStanzaID: opts.quotedMsg.id.id } : {} }), 50);
              // WhatsApp's own promise settles much later than the message goes out.
              return new Promise((r) => setTimeout(r, 60000));
            },
          },
          WAWebMediaOpaqueData: { createFromData: async (file, type) => ({ file, type }) },
          WAWebPrepRawMedia: {
            prepRawMedia: (data, opts) => ({
              waitForPrep: async () => ({ type: opts.asDocument ? 'document' : 'image' }),
              sendToChat: async ({ chat: c, options }) => {
                window.__sent.push({ chat: c.id._serialized, file: data.file.name, asDocument: opts.asDocument, caption: options.caption || null, quoted: options.quotedMsg ? options.quotedMsg.id.id : null });
                deliver(c, msg(c.id._serialized, { t: 999, type: opts.asDocument ? 'document' : 'image', fromMe: true, extra: { caption: options.caption, filename: data.file.name } }), 30);
              },
            }),
          },
          WAWebSendReactionMsgAction: { sendReactionToMsg: async (m, emoji) => { window.__reactions.push({ key: m.id.id, emoji }); } },
          WAWebMsgActionCapability: { canSenderRevokeMsg: (m) => m.t > 200 },
          WAWebCmd: {
            Cmd: {
              sendDeleteMsgs: (c, { list }) => { window.__deleted.push({ how: 'me', key: list[0].id.id }); setTimeout(() => { c.msgs.items = c.msgs.items.filter((x) => x !== list[0]); }, 30); },
              sendRevokeMsgs: (c, { list }) => { window.__deleted.push({ how: 'everyone', key: list[0].id.id }); setTimeout(() => { list[0].type = 'revoked'; }, 30); },
            },
          },
          WAWebUserPrefsMeUser: { getMaybeMePnUser: () => wid('15559990000@c.us'), getMaybeMeLidUser: () => null },
          WAWebChatLoadMessages: { loadEarlierMsgs: async ({ chat: c }) => { c.msgs.items = c.older.concat(c.msgs.items); c.older = []; } },
        };
        window.require = (name) => { if (!(name in modules)) throw new Error('no module ' + name); return modules[name]; };
        """#

    private func page() async throws -> WKWebView {
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        try await PageLoad.load(
            "<html><body><div id='app'></div></body></html>", base: URL(string: "https://test.example/")!, in: w)
        _ = try await w.callAsyncJavaScript(Self.fakeWhatsApp, arguments: [:], in: nil, contentWorld: .page)
        _ = try await w.callAsyncJavaScript(WhatsAppBridge.source, arguments: [:], in: nil, contentWorld: .page)
        return w
    }

    /// Calls a bridge function directly and decodes its answer.
    private func call(_ w: WKWebView, _ name: String, _ args: JSONValue = .object([:])) async throws -> JSONValue {
        let r = try await w.callAsyncJavaScript(
            "return JSON.stringify(await window.__latchkey[name](JSON.parse(args)));",
            arguments: ["name": name, "args": args.jsonText], in: nil, contentWorld: .page)
        return try JSONDecoder().decode(JSONValue.self, from: Data((r as? String ?? "null").utf8))
    }

    private func js(_ w: WKWebView, _ code: String) async throws -> Any? {
        try await w.callAsyncJavaScript(code, arguments: [:], in: nil, contentWorld: .page)
    }

    @Test func stateSaysConnectedAndWhatIsMissing() async throws {
        let w = try await page()
        let s = try await call(w, "state")
        #expect(s["connected"]?.boolValue == true && s["loaded"]?.boolValue == true)
        #expect(s["missing"] == .array([]) && s["chats"]?.numberValue == 5)
        _ = try await js(w, "window.require('WAWebSocketModel').Socket.state = 'OPENING'")
        #expect(try await call(w, "state")["connected"]?.boolValue == false)
        // A renamed module is named, so the tools can say Latchkey needs an update.
        _ = try await js(
            w,
            "const r = window.require; window.require = (n) => { if (n === 'WAWebPrepRawMedia') throw new Error('gone'); return r(n); }"
        )
        #expect(try await call(w, "state")["missing"] == .array([.string("WAWebPrepRawMedia")]))
    }

    /// The screen with the link code is a log-in screen too, so nothing takes it for a page
    /// that is stuck loading (2026-11-04).
    @Test func theCodeScreenIsALogInScreen() async throws {
        let w = try await page()
        _ = try await js(w, "document.body.innerHTML = '<div>Enter code on phone</div><div>A</div>'")
        #expect(try await call(w, "state")["loginScreen"]?.boolValue == true)
        // With the chats showing, a message saying the same words is just a message.
        _ = try await js(w, "document.body.innerHTML = '<div id=\"pane-side\"></div><div>Log in with QR code</div>'")
        #expect(try await call(w, "state")["loginScreen"]?.boolValue == false)
    }

    /// Plan D1: the scripts Safari runs, in a page at WhatsApp Web's address: the start script puts
    /// the bridge in and starts a function, the poll script takes its answer once.
    @Test func safariStartsAFunctionAndCollectsItsAnswer() async throws {
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        try await PageLoad.load(
            "<html><body><div id='app'></div></body></html>", base: URL(string: "https://web.whatsapp.com/")!, in: w)
        _ = try await w.callAsyncJavaScript(Self.fakeWhatsApp, arguments: [:], in: nil, contentWorld: .page)
        let started = try await w.evaluateJavaScript(
            SafariWhatsApp.start("resolve", .object(["to": .string("Sarah")]), id: "t1"))
        #expect(started as? String == "started")
        var out = ""
        for _ in 0..<50 where out.isEmpty {
            out = try await w.evaluateJavaScript(SafariWhatsApp.poll(id: "t1")) as? String ?? ""
            if out.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        }
        let answer = try SafariWhatsApp.answer(out)
        #expect(answer["match"]?["name"]?.stringValue == "Sarah Lee")
        #expect(try await w.evaluateJavaScript(SafariWhatsApp.poll(id: "t1")) as? String == "", "taken once")
        // The bridge stays in the tab for the next call; a missing function says so.
        #expect(try await w.evaluateJavaScript("window.__latchkey.version") as? Int == WhatsAppBridge.version)
        let none = try await w.evaluateJavaScript(SafariWhatsApp.start("nope", .object([:]), id: "t2"))
        #expect(none as? String == "failed: no such function")
        #expect(SafariWhatsApp.state(from: try await call(w, "state")) == .connected)
    }

    /// Messages and files go only to WhatsApp Web: anywhere else the start script does nothing.
    @Test func safariRefusesAPageThatIsntWhatsAppWeb() async throws {
        let w = try await page()  // at test.example
        _ = try await js(w, "window.__latchkey = undefined")
        let r = try await w.evaluateJavaScript(
            SafariWhatsApp.start(
                "send", .object(["chat": .string("15550001111@c.us"), "text": .string("hi")]), id: "x"))
        #expect(r as? String == "failed: the tab is not WhatsApp Web")
        #expect(try await js(w, "return window.__sent.length") as? Int == 0)
        #expect(try await js(w, "return typeof window.__latchkey") as? String == "undefined")
    }

    /// A tab still loading (its address WhatsApp Web's, its page not yet) is waited for, not taken
    /// as a failure (2026-11-04: a tab Latchkey had just opened was given up on at once).
    @Test func aTabStillLoadingIsWaitedFor() async {
        final class Runner: ScriptRunner, @unchecked Sendable {
            var answers: [Result<String, ScriptError>]
            init(_ a: [Result<String, ScriptError>]) { answers = a }
            func run(_ script: String, _ args: [String]) async throws -> String {
                try answers.removeFirst().get()
            }
        }
        let runner = Runner([
            .failure(.failed("execution error: LATCHKEY_NOT_STARTED failed: the tab is not WhatsApp Web (-2700)")),
            .success(#"OK{"connected":true,"chats":3,"missing":[],"chatList":true,"loginScreen":false}"#),
        ])
        let tab = SafariWhatsApp(runner: { _ in runner }, locked: { false })
        #expect(await tab.ready(wait: .seconds(5)) == .connected)
    }

    @Test func theAnswerSaysTimedOutFailedOrTheValue() throws {
        #expect(throws: WhatsAppPageError.timedOut) { try SafariWhatsApp.answer("") }
        #expect(throws: WhatsAppPageError.failed("boom")) { try SafariWhatsApp.answer("ERboom") }
        #expect(try SafariWhatsApp.answer(#"OK{"a":1}"#)["a"]?.numberValue == 1)
    }

    /// The screen's words come back only while no chats show, so no message text leaves.
    @Test func screenTellsALoadingPageButNeverChats() async throws {
        let w = try await page()
        _ = try await js(w, "document.body.innerHTML = '<div>Loading your chats</div><div>45%</div>'")
        #expect(try await call(w, "screen")["text"] == .string("Loading your chats 45%"))
        _ = try await js(w, "document.body.innerHTML = '<div id=\"pane-side\">Sarah: see you</div>'")
        #expect(try await call(w, "screen")["text"] == .string(""))
    }

    @Test func chatsAreNewestFirstAndFiltered() async throws {
        let w = try await page()
        let all = try await call(w, "chats", .object(["limit": .number(10)]))
        guard case .array(let list) = all["chats"] else { Issue.record("no chats"); return }
        #expect(
            list.compactMap { $0["name"]?.stringValue } == ["Family", "Sarah Lee", "Sam Ito", "Sam Ross", "Toni (You)"])
        #expect(list[0]["group"]?.boolValue == true && list[1]["group"]?.boolValue == false)
        #expect(try await call(w, "chats", .object(["unread": .bool(true)]))["total"]?.numberValue == 1)
        #expect(try await call(w, "chats", .object(["query": .string("sam")]))["total"]?.numberValue == 2)
        #expect(try await call(w, "chats", .object(["query": .string("555 0001")]))["total"]?.numberValue == 1)
    }

    @Test func resolveFindsOneOrSaysWhichOrNone() async throws {
        let w = try await page()
        #expect(try await call(w, "resolve", .object(["to": .string("family")]))["match"]?["group"]?.boolValue == true)
        #expect(
            try await call(w, "resolve", .object(["to": .string("sarah")]))["match"]?["name"]?.stringValue
                == "Sarah Lee")
        // The desktop app's ids say @s.whatsapp.net for WhatsApp Web's @c.us.
        let desktop = try await call(w, "resolve", .object(["to": .string("15550001111@s.whatsapp.net")]))
        #expect(desktop["match"]?["id"]?.stringValue == "15550001111@c.us")
        guard case .array(let several) = try await call(w, "resolve", .object(["to": .string("Sam")]))["candidates"]
        else {
            Issue.record("no candidates")
            return
        }
        #expect(several.count == 2)
        #expect(try await call(w, "resolve", .object(["to": .string("Nobody")]))["none"]?.boolValue == true)
        // A number with no chat yet gets one from WhatsApp's own lookup.
        let new = try await call(w, "resolve", .object(["to": .string("+1 (555) 000-9999")]))
        #expect(new["match"]?["id"]?.stringValue == "15550009999@c.us")
        #expect(
            try await call(w, "resolve", .object(["to": .string("+15550001111")]))["match"]?["name"]?.stringValue
                == "Sarah Lee")
    }

    @Test func messagesAreNewestFirstWithSendersAndLoadOlder() async throws {
        let w = try await page()
        let r = try await call(w, "messages", .object(["chat": .string("120363000@g.us"), "limit": .number(10)]))
        guard case .array(let m) = r["messages"] else { Issue.record("no messages"); return }
        #expect(m.compactMap { $0["text"]?.stringValue } == ["yes", "dinner saturday?", "older one"])
        #expect(m[0]["sender"]?.stringValue == "Dad" && m[1]["sender"]?.stringValue == "Mum")
        #expect(m[0]["id"]?.stringValue?.contains("_120363000@g.us_") == true, "a message id is its key's text")
        let before = try await call(
            w, "messages", .object(["chat": .string("120363000@g.us"), "before": .number(500)]))
        guard case .array(let b) = before["messages"] else { Issue.record("no messages"); return }
        #expect(b.count == 2)
    }

    @Test func searchFindsTextAcrossChats() async throws {
        let w = try await page()
        let r = try await call(w, "search", .object(["query": .string("SIX")]))
        #expect(r["total"]?.numberValue == 1)
        guard case .array(let m) = r["messages"] else { Issue.record("no messages"); return }
        #expect(m.first?["chat"]?.stringValue == "Sarah Lee")
    }

    /// WhatsApp's own promise settled ~38 s after the message was out (2026-11-03): the message in
    /// the chat is the answer.
    @Test func textIsConfirmedByTheMessageNotThePromise() async throws {
        let w = try await page()
        let start = Date()
        let r = try await call(w, "send", .object(["chat": .string("15550001111@c.us"), "text": .string("on my way")]))
        #expect(Date().timeIntervalSince(start) < 3)
        guard case .array(let results) = r["results"] else { Issue.record("no results"); return }
        #expect(results.first?["sent"]?.boolValue == true && results.first?["ack"]?.numberValue == 1)
        #expect(r["incomplete"] == nil)
    }

    @Test func aRefusedSendSaysSoAtOnce() async throws {
        let w = try await page()
        _ = try await js(w, "window.__mode = 'reject'")
        let start = Date()
        let r = try await call(w, "send", .object(["chat": .string("15550001111@c.us"), "text": .string("x")]))
        #expect(r["error"]?.stringValue == "blocked")
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func anUnconfirmedSendIsIncomplete() async throws {
        let w = try await page()
        _ = try await js(w, "window.__mode = 'never'")
        let r = try await call(
            w, "send", .object(["chat": .string("15550001111@c.us"), "text": .string("x"), "timeoutMs": .number(500)]))
        #expect(r["incomplete"]?.boolValue == true)
    }

    @Test func photosGoAsPhotosFilesAsDocumentsCaptionOnTheFirst() async throws {
        let w = try await page()
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let r = try await call(
            w, "send",
            .object([
                "chat": .string("120363000@g.us"), "text": .string("the plan"),
                "files": .array([
                    .object(["name": .string("a.png"), "type": .string("image/png"), "base64": .string(png)]),
                    .object(["name": .string("b.pdf"), "type": .string("application/pdf"), "base64": .string(png)]),
                ]),
            ]))
        guard case .array(let results) = r["results"] else { Issue.record("no results"); return }
        #expect(results.count == 2 && results.allSatisfy { $0["sent"]?.boolValue == true })
        let sent = try await js(w, "return JSON.stringify(window.__sent)") as? String ?? ""
        let calls = try JSONDecoder().decode(JSONValue.self, from: Data(sent.utf8))
        guard case .array(let c) = calls else { Issue.record("no calls"); return }
        #expect(c[0]["asDocument"]?.boolValue == false && c[0]["caption"]?.stringValue == "the plan")
        #expect(c[1]["asDocument"]?.boolValue == true && c[1]["caption"] == .null)
        #expect(c.count == 2, "the text went as a caption, not a message of its own")
    }

    /// WhatsApp Web's log-in by phone number as it looked on 2026-11-02: a link, a number field
    /// starting "+1 ", Next, and the code one character per line.
    @Test func noSuchChatIsAnError() async throws {
        let w = try await page()
        #expect(try await call(w, "send", .object(["chat": .string("x@c.us"), "text": .string("y")]))["error"] != nil)
        #expect(try await call(w, "messages", .object(["chat": .string("x@c.us")]))["none"]?.boolValue == true)
    }

    /// FR-1240: every message carries its key, the id Claude passes to reply, react, or delete.
    @Test func messagesCarryTheirKey() async throws {
        let w = try await page()
        let r = try await call(w, "messages", .object(["chat": .string("15550001111@c.us")]))
        guard case .array(let m) = r["messages"] else { Issue.record("no messages"); return }
        #expect(!m.isEmpty && m.allSatisfy { ($0["key"]?.stringValue ?? "").hasPrefix("K") })
    }

    /// FR-1241: a reply quotes the message and says whether WhatsApp shows the quote.
    @Test func aReplyQuotesTheMessage() async throws {
        let w = try await page()
        let msgs = try await call(w, "messages", .object(["chat": .string("15550001111@c.us")]))
        guard case .array(let list) = msgs["messages"], let key = list.last?["key"]?.stringValue else {
            Issue.record("no key")
            return
        }
        let r = try await call(
            w, "send", .object(["chat": .string("15550001111@c.us"), "text": .string("yes"), "replyTo": .string(key)]))
        guard case .array(let results) = r["results"] else { Issue.record("no results"); return }
        #expect(results.first?["quoted"]?.boolValue == true && results.first?["sent"]?.boolValue == true)
        #expect(try await js(w, "return window.__sent[0].quoted") as? String == key)
        let none = try await call(
            w, "send", .object(["chat": .string("15550001111@c.us"), "text": .string("x"), "replyTo": .string("K999")]))
        #expect(none["error"]?.stringValue?.contains("not in this chat") == true)
        #expect(try await js(w, "return window.__sent.length") as? Int == 1, "nothing sent without the message")
    }

    /// FR-1242: a reaction goes on the message by its key, also on an older one loaded from WhatsApp.
    @Test func reactingFindsTheMessageAndReacts() async throws {
        let w = try await page()
        let older = try await js(
            w, "return window.require('WAWebCollections').Chat.getModelsArray()[1].older[0].id.id")
        let key = try #require(older as? String)
        let r = try await call(
            w, "react", .object(["chat": .string("120363000@g.us"), "message": .string(key), "emoji": .string("👍")]))
        #expect(r["done"]?.boolValue == true && r["message"]?["text"]?.stringValue == "older one")
        #expect(try await js(w, "return window.__reactions[0].emoji") as? String == "👍")
        let gone = try await call(
            w, "react", .object(["chat": .string("120363000@g.us"), "message": .string("K999"), "emoji": .string("")]))
        #expect(gone["error"]?.stringValue == "no such message in this chat")
    }

    /// FR-1243: deleting for the Owner removes it; for everyone only the Owner's own, while allowed.
    @Test func deletingForMeAndForEveryone() async throws {
        let w = try await page()
        let keys = try await js(
            w, "return window.require('WAWebCollections').Chat.getModelsArray()[0].msgs.items.map((m) => m.id.id)")
        let k = try #require(keys as? [String])
        let chat = JSONValue.string("15550001111@c.us")
        let theirs = try await call(
            w, "remove", .object(["chat": chat, "message": .string(k[0]), "everyone": .bool(true)]))
        #expect(theirs["refused"]?.stringValue?.contains("only your own") == true)
        let mine = try await call(
            w, "remove", .object(["chat": chat, "message": .string(k[1]), "everyone": .bool(true)]))
        #expect(mine["done"]?.boolValue == true)
        let me = try await call(w, "remove", .object(["chat": chat, "message": .string(k[0])]))
        #expect(me["done"]?.boolValue == true)
        let how = try await js(w, "return window.__deleted.map((d) => d.how)") as? [String]
        #expect(how == ["everyone", "me"])
        // Too old for everyone: WhatsApp's own check says no, and nothing is sent.
        let own = try #require(
            try await js(w, "return window.require('WAWebCollections').Chat.getModelsArray()[4].msgs.items[0].id.id")
                as? String)
        let old = try await call(
            w, "remove",
            .object(["chat": .string("15559990000@c.us"), "message": .string(own), "everyone": .bool(true)]))
        #expect(old["refused"]?.stringValue?.contains("too old") == true)
    }

    /// FR-1244: "me" is the Owner's own chat, by WhatsApp Web's own idea of who is logged in.
    @Test func meIsTheOwnersOwnChat() async throws {
        let w = try await page()
        let r = try await call(w, "resolve", .object(["to": .string("me")]))
        #expect(r["match"]?["id"]?.stringValue == "15559990000@c.us")
    }

    /// A rename of a module that only reactions use is named there, and the rest keeps working.
    @Test func aMissingExtraModuleIsNamedOnlyWhereUsed() async throws {
        let w = try await page()
        _ = try await js(
            w,
            "const r = window.require; window.require = (n) => { if (n === 'WAWebSendReactionMsgAction') throw new Error('gone'); return r(n); }"
        )
        #expect(try await call(w, "state")["missing"] == .array([]))
        let key = try #require(
            try await js(w, "return window.require('WAWebCollections').Chat.getModelsArray()[0].msgs.items[0].id.id")
                as? String)
        await #expect(throws: (any Error).self) {
            _ = try await call(
                w, "react",
                .object(["chat": .string("15550001111@c.us"), "message": .string(key), "emoji": .string("x")]))
        }
    }
}

