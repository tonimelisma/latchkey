import Foundation
import WebKit

/// A running record of one page in Latchkey's own browser, for problem reports (spec 014
/// FR-1446; Toni, 2026-11-25: "Always record, memory only", "Hidden world"): the last `limit`
/// page loads, requests, uncaught errors and failed promises, blocked content, and visibility
/// changes. In memory only, never written to disk, gone with its page, and sent only inside a
/// report (`ReportPart`). It records from a content world of its own, which the page can't see or
/// reach: no function of the page is replaced, so recording never changes how a site behaves.
@MainActor
final class PageRecord {
    nonisolated static let limit = 300
    /// The longest text one event keeps (an error's stack, an address).
    nonisolated static let maxText = 2000

    struct Event: Codable, Sendable, Equatable {
        var time: String
        var kind: String  // load, response, request, error, rejection, blocked, visibility
        var address: String?
        var method: String?
        var status: Int?
        var type: String?
        var ms: Int?
        var bytes: Int?
        var text: String?
    }

    private(set) var events: [Event] = []
    /// How many older events made room for newer ones.
    private(set) var dropped = 0
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    func add(_ e: Event) {
        var e = e
        e.address = e.address.map { Self.shownAddress($0) }
        e.text = e.text.map { String($0.prefix(Self.maxText)) }
        e.type = e.type.map { String($0.prefix(40)) }
        e.method = e.method.map { String($0.prefix(16)) }
        events.append(e)
        if events.count > Self.limit {
            dropped += events.count - Self.limit
            events.removeFirst(events.count - Self.limit)
        }
    }

    /// The page closed: nothing stays (FR-1446).
    func clear() {
        events = []
        dropped = 0
    }

    func time() -> String { Self.iso.string(from: now()) }

    /// A moment as the report writes it (UTC, milliseconds).
    nonisolated static func iso8601(_ d: Date) -> String { iso.string(from: d) }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// A request's address with its query values left out (names kept), so sign-in links, tokens
    /// and ids in addresses don't go into a report; cut to `maxText` (plan.md D7, research.md).
    nonisolated static func shownAddress(_ address: String) -> String {
        guard var c = URLComponents(string: address) else { return String(address.prefix(maxText)) }
        if let items = c.queryItems, !items.isEmpty {
            c.queryItems = items.map { URLQueryItem(name: $0.name, value: $0.value == nil ? nil : "…") }
        }
        c.fragment = nil
        c.user = nil
        c.password = nil
        return String((c.string ?? address).prefix(maxText))
    }

    // MARK: the hidden world

    /// The world the recorder runs in, apart from the page's own.
    static let world = WKContentWorld.world(name: "latchkey-record")
    nonisolated static let handlerName = "latchkeyRecord"

    /// Watches the page from the hidden world: resource timing entries (requests), errors,
    /// failed promises, blocked content, visibility. Nothing here touches the page's own objects.
    nonisolated static let recorder = """
        (() => {
          const post = (e) => { try { window.webkit.messageHandlers.\(handlerName).postMessage(e); } catch (_) {} };
          const cut = (s) => { s = String(s == null ? '' : s); return s.length > \(maxText) ? s.slice(0, \(maxText)) : s; };
          try {
            new PerformanceObserver((list) => {
              for (const r of list.getEntries()) {
                post({kind: 'request', address: cut(r.name), type: cut(r.initiatorType), status: r.responseStatus || 0,
                      ms: Math.round(r.duration) || 0, bytes: r.transferSize || 0});
              }
            }).observe({type: 'resource', buffered: true});
          } catch (_) {}
          addEventListener('error', (e) => {
            if (e instanceof ErrorEvent) {
              post({kind: 'error', text: cut(e.message), address: cut(e.filename), type: 'line ' + (e.lineno || 0)});
            } else if (e.target && e.target !== window) {
              const t = e.target;
              post({kind: 'error', text: 'failed to load', type: cut(t.tagName || ''), address: cut(t.currentSrc || t.src || t.href || '')});
            }
          }, true);
          addEventListener('unhandledrejection', (e) => {
            // The reason is the page's own value, which another world may not be able to read.
            let t = '';
            try { const r = e.reason; t = r && r.stack ? r.stack : (r && r.message) || (r == null ? '' : r); } catch (_) {}
            post({kind: 'rejection', text: cut(t || 'a promise failed (its reason is the page\\'s own)')});
          });
          document.addEventListener('securitypolicyviolation', (e) => {
            post({kind: 'blocked', text: cut(e.violatedDirective), address: cut(e.blockedURI)});
          });
          document.addEventListener('visibilitychange', () => post({kind: 'visibility', text: document.visibilityState}));
        })();
        """

    /// Puts the recorder into a page's configuration, before its view is made.
    func install(in config: WKWebViewConfiguration) {
        let content = config.userContentController
        content.addUserScript(
            WKUserScript(source: Self.recorder, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
        content.add(Handler(self), contentWorld: Self.world, name: Self.handlerName)
    }

    /// One message from the recorder; anything not of its shape is dropped.
    func received(_ body: Any) {
        guard let o = body as? [String: Any], let kind = o["kind"] as? String,
            ["request", "error", "rejection", "blocked", "visibility"].contains(kind)
        else { return }
        func int(_ k: String) -> Int? {
            guard let n = o[k] as? NSNumber else { return nil }
            let d = n.doubleValue
            return d.isFinite && abs(d) < 1e12 ? Int(d) : nil
        }
        let status = int("status")
        add(
            Event(
                time: time(), kind: kind, address: o["address"] as? String, status: status == 0 ? nil : status,
                type: o["type"] as? String, ms: int("ms"), bytes: int("bytes"), text: o["text"] as? String))
    }

    /// A page load the browser starts (from its navigation delegate): its method and address.
    func loading(_ request: URLRequest, mainFrame: Bool) {
        add(
            Event(
                time: time(), kind: "load", address: request.url?.absoluteString, method: request.httpMethod,
                type: mainFrame ? "page" : "frame"))
    }

    /// A page load's answer: its status.
    func answered(_ response: URLResponse, mainFrame: Bool) {
        add(
            Event(
                time: time(), kind: "response", address: response.url?.absoluteString,
                status: (response as? HTTPURLResponse)?.statusCode, type: mainFrame ? "page" : "frame",
                text: response.mimeType))
    }

    /// Hands the recorder's messages to the record; holds it weakly (the content controller
    /// holds this handler for as long as the view lives).
    private final class Handler: NSObject, WKScriptMessageHandler {
        weak var record: PageRecord?
        init(_ record: PageRecord) { self.record = record }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // Only the recorder's own world can post here: the handler is added to that world alone,
            // so the page's world has no such handler.
            MainActor.assumeIsolated { record?.received(message.body) }
        }
    }

    // MARK: the snapshot (FR-1447)

    /// The page as it is, read in the hidden world: address, title, source with every field's
    /// value blanked (hidden fields too; button labels stay), visibility, focus, sizes.
    nonisolated static let snapshot = snapshotScript(requests: false)

    /// The same for a Safari tab, read with one script, with the page's own list of requests
    /// (its resource timing entries), as no recorder runs there (FR-1447).
    nonisolated static let safariSnapshot = snapshotScript(requests: true)

    nonisolated private static func snapshotScript(requests: Bool) -> String {
        let list =
            requests
            ? "requests: performance.getEntriesByType('resource').slice(-\(limit)).map((r) => ({address: r.name, "
                + "type: r.initiatorType, status: r.responseStatus || 0, ms: Math.round(r.duration) || 0, "
                + "bytes: r.transferSize || 0})),"
            : ""
        return """
        (() => {
          let source = '';
          const root = document.documentElement;
          if (root) {
            const c = root.cloneNode(true);
            for (const el of c.querySelectorAll('input')) {
              const t = (el.getAttribute('type') || '').toLowerCase();
              if (!['submit', 'button', 'reset', 'image'].includes(t)) el.setAttribute('value', '');
            }
            for (const el of c.querySelectorAll('textarea')) el.textContent = '';
            for (const el of c.querySelectorAll('[contenteditable]')) el.textContent = '';
            // Inline scripts and data blocks hold a page's state (tokens, the account's details): their
            // bodies go, their addresses stay. Token-like attributes and meta values are blanked.
            for (const el of c.querySelectorAll('script:not([src])')) el.textContent = '';
            for (const el of c.querySelectorAll('meta[content]')) {
              if (/csrf|token|nonce|session|key/i.test(el.getAttribute('name') || el.getAttribute('property') || '')) {
                el.setAttribute('content', '');
              }
            }
            for (const el of c.querySelectorAll('*')) {
              for (const a of Array.from(el.attributes)) {
                if (/csrf|token|nonce|secret|session/i.test(a.name)) el.setAttribute(a.name, '');
              }
            }
            source = '<!doctype html>\\n' + c.outerHTML;
          }
          return JSON.stringify({address: location.href, title: document.title, source: source, \(list)
            visibility: document.visibilityState, hidden: document.hidden, focus: document.hasFocus(),
            window: innerWidth + 'x' + innerHeight, screen: screen.width + 'x' + screen.height});
        })()
        """
    }

    /// Counts the animation frames the page draws in half a second (an async function body).
    nonisolated static let frames = """
        return await new Promise((done) => {
          let n = 0; const t0 = performance.now();
          const f = () => { n++; if (performance.now() - t0 < 500) requestAnimationFrame(f); };
          requestAnimationFrame(f);
          setTimeout(() => done(n), 600);
        });
        """

    /// The longest page source a report holds; the relay cuts more when a report is too large.
    nonisolated static let maxSource = 1_500_000
}
