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
        function msg(chat, o) { return Object.assign({ id: key(!!o.fromMe, chat), t: o.t, type: o.type || 'chat', body: o.body || '', ack: o.ack || 0 }, o.extra || {}); }
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
        ];
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
            sendTextMsgToChat: (c, text) => {
              window.__sent.push({ chat: c.id._serialized, text });
              if (window.__mode === 'reject') return Promise.reject(new Error('blocked'));
              if (window.__mode === 'never') return new Promise(() => {});
              deliver(c, msg(c.id._serialized, { t: 999, body: text, fromMe: true }), 50);
              // WhatsApp's own promise settles much later than the message goes out.
              return new Promise((r) => setTimeout(r, 60000));
            },
          },
          WAWebMediaOpaqueData: { createFromData: async (file, type) => ({ file, type }) },
          WAWebPrepRawMedia: {
            prepRawMedia: (data, opts) => ({
              waitForPrep: async () => ({ type: opts.asDocument ? 'document' : 'image' }),
              sendToChat: async ({ chat: c, options }) => {
                window.__sent.push({ chat: c.id._serialized, file: data.file.name, asDocument: opts.asDocument, caption: options.caption || null });
                deliver(c, msg(c.id._serialized, { t: 999, type: opts.asDocument ? 'document' : 'image', fromMe: true, extra: { caption: options.caption, filename: data.file.name } }), 30);
              },
            }),
          },
          WAWebChatLoadMessages: { loadEarlierMsgs: async ({ chat: c }) => { c.msgs.items = c.older.concat(c.msgs.items); c.older = []; } },
        };
        window.require = (name) => { if (!(name in modules)) throw new Error('no module ' + name); return modules[name]; };
        """#

    private func page() async throws -> WKWebView {
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        w.loadHTMLString(
            "<html><body><div id='app'></div></body></html>", baseURL: URL(string: "https://test.example/"))
        for _ in 0..<100 where w.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        _ = try await w.callAsyncJavaScript(Self.fakeWhatsApp, arguments: [:], in: nil, contentWorld: .page)
        _ = try await w.callAsyncJavaScript(WhatsAppBridge.source, arguments: [:], in: nil, contentWorld: .page)
        return w
    }

    /// Calls a bridge function the way `WhatsAppPage.call` does and decodes its answer.
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
        #expect(s["missing"] == .array([]) && s["chats"]?.numberValue == 4)
        _ = try await js(w, "window.require('WAWebSocketModel').Socket.state = 'OPENING'")
        #expect(try await call(w, "state")["connected"]?.boolValue == false)
        // A renamed module is named, so the tools can say Latchkey needs an update.
        _ = try await js(
            w,
            "const r = window.require; window.require = (n) => { if (n === 'WAWebPrepRawMedia') throw new Error('gone'); return r(n); }"
        )
        #expect(try await call(w, "state")["missing"] == .array([.string("WAWebPrepRawMedia")]))
    }

    @Test func chatsAreNewestFirstAndFiltered() async throws {
        let w = try await page()
        let all = try await call(w, "chats", .object(["limit": .number(10)]))
        guard case .array(let list) = all["chats"] else { Issue.record("no chats"); return }
        #expect(list.compactMap { $0["name"]?.stringValue } == ["Family", "Sarah Lee", "Sam Ito", "Sam Ross"])
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
    @Test func linkByPhoneTypesTheNumberAndReadsTheCode() async throws {
        let w = try await page()
        _ = try await js(
            w,
            #"""
            document.body.innerHTML = '<div role="button" id="by-phone"><span>Log in with phone number</span></div>';
            document.getElementById('by-phone').onclick = () => {
              document.body.innerHTML = '<input aria-label="Type your phone number to log in to WhatsApp" value="+1 "><button id="next">Next</button>';
              document.getElementById('next').onclick = () => {
                window.__typed = document.querySelector('input').value;
                setTimeout(() => { document.body.innerHTML = '<div>Enter code on phone</div>' + 'ABCD-EFGH'.split('').map((c) => '<div>' + c + '</div>').join(''); }, 300);
              };
            };
            """#)
        let r = try await call(w, "linkByPhone", .object(["number": .string("+1 (415) 555-0100")]))
        #expect(r["code"]?.stringValue == "ABCD-EFGH")
        #expect(try await js(w, "return window.__typed") as? String == "+14155550100")
        #expect(try await call(w, "linkByPhone", .object(["number": .string("12")]))["error"] != nil)
    }

    /// In Latchkey's page the first press did nothing (WhatsApp Web hadn't set up its handlers).
    @Test func linkByPhonePressesAgainUntilTheFieldShows() async throws {
        let w = try await page()
        _ = try await js(
            w,
            #"""
            document.body.innerHTML = '<div role="button" id="by-phone"><span>Log in with phone number</span></div>';
            let presses = 0;
            document.getElementById('by-phone').onclick = () => {
              if (++presses < 3) return;
              document.body.innerHTML = '<input aria-label="Type your phone number to log in to WhatsApp" value="+1 "><button id="next">Next</button>';
              document.getElementById('next').onclick = () => { document.body.innerHTML = '<p>Enter code</p><p>WXYZ-1234</p><p>more</p>'; };
            };
            """#)
        #expect(
            try await call(w, "linkByPhone", .object(["number": .string("14155550100")]))["code"]?.stringValue
                == "WXYZ-1234")
    }

    @Test func noSuchChatIsAnError() async throws {
        let w = try await page()
        #expect(try await call(w, "send", .object(["chat": .string("x@c.us"), "text": .string("y")]))["error"] != nil)
        #expect(try await call(w, "messages", .object(["chat": .string("x@c.us")]))["none"]?.boolValue == true)
    }
}
