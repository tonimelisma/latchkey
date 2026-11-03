import AppKit
import OSLog
import SwiftUI
import WebKit

/// Where Latchkey's own WhatsApp device stands (spec 012 plan D1, D4).
enum WhatsAppPageState: Equatable, Sendable {
    /// No page: WhatsApp is off, or was never linked on this Mac.
    case notStarted
    /// The page is loading, or WhatsApp Web hasn't set itself up yet.
    case loading
    /// WhatsApp Web shows its log-in screen: Latchkey isn't a linked device (any more).
    case notLinked
    /// Linked, but not connected to WhatsApp right now.
    case connecting
    case connected
    /// WhatsApp Web no longer has functions Latchkey uses (an update renamed them).
    case changed([String])
}

enum WhatsAppPageError: Error, Equatable {
    case timedOut
    case failed(String)
}

/// What the WhatsApp tools need from the page; `LiveWhatsAppPage` is the real one, tests use a
/// stand-in.
protocol WhatsAppPageAPI: Sendable {
    /// Calls `window.__latchkey.<function>(args)` in the page and returns its answer.
    func call(_ function: String, _ args: JSONValue, timeout: Duration) async throws -> JSONValue
    /// Starts the page if needed and waits up to `wait` for WhatsApp to be connected, reloading a
    /// stuck page once (plan D4). Returns the state it ended in.
    func ready(wait: Duration) async -> WhatsAppPageState
    /// Starts the page whether or not it was linked, and waits up to `wait` for the log-in screen
    /// or a connection (linking by code, FR-1201).
    func startForLinking(wait: Duration) async -> WhatsAppPageState
}

/// The real page, reached from the tools' background tasks.
struct LiveWhatsAppPage: WhatsAppPageAPI {
    func call(_ function: String, _ args: JSONValue, timeout: Duration) async throws -> JSONValue {
        try await WhatsAppPage.shared.call(function, args, timeout: timeout)
    }

    func ready(wait: Duration) async -> WhatsAppPageState {
        await WhatsAppPage.shared.ready(wait: wait)
    }

    func startForLinking(wait: Duration) async -> WhatsAppPageState {
        await WhatsAppPage.shared.startForLinking(wait: wait)
    }
}

/// Latchkey's own linked WhatsApp device: WhatsApp Web in a web view that is never on screen,
/// except in the linking window (plan D1, D3). Its data lives in a website data store of its own.
@MainActor
final class WhatsAppPage: NSObject, WKNavigationDelegate {
    static let shared = WhatsAppPage()
    static let url = URL(string: "https://web.whatsapp.com/")!
    /// The page's website data store; fixed, so the link survives restarts (FR-1202).
    static let storeID = UUID(uuidString: "6F1C2A4E-8B3D-4E51-9A7C-1D2E3F405162")!
    static let log = Logger(subsystem: AppIdentity.current.logSubsystem, category: "whatsapp")

    private var web: WKWebView?
    private var watchdog: Timer?
    private var linkWindow: NSWindow?
    /// Since when the page has been linked but not connected (plan D4).
    private var unconnectedSince: Date?
    private var loadedAt = Date.distantPast
    /// True once the page has been connected; a later log-in screen means WhatsApp unlinked it.
    private var wasLinked = false

    private(set) var state: WhatsAppPageState = .notStarted {
        didSet { if state != oldValue { onChange?(state) } }
    }
    /// Called on every change of state (the Settings row, the linking window).
    var onChange: ((WhatsAppPageState) -> Void)?

    // MARK: lifecycle

    /// Whether Latchkey's device was linked on this Mac and not unlinked since. Kept by Latchkey:
    /// asking WebKit (`allDataStoreIdentifiers`) before any web view exists crashes the app
    /// (0.8.101 at every start, 2026-11-03).
    static let linkedKey = "whatsappLinked"
    static func hasStore() async -> Bool { UserDefaults.standard.bool(forKey: linkedKey) }
    private static func setLinked(_ on: Bool) { UserDefaults.standard.set(on, forKey: linkedKey) }

    func start() {
        guard web == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeID)
        // A hidden page's timers are otherwise slowed tenfold (research: 3.4 s of steps took 30 s).
        config.preferences.inactiveSchedulingPolicy = .none
        config.userContentController.addUserScript(
            WKUserScript(
                source: WhatsAppBridge.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 860), configuration: config)
        w.navigationDelegate = self
        w.customUserAgent = LockedBrowser.safariUserAgent
        web = w
        load()
        state = .loading
        watchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in await WhatsAppPage.shared.check() }
        }
        EventLog.shared.record(.app, "WhatsApp: started Latchkey's linked device")
    }

    /// Closes the page; its data stays, so it starts linked next time.
    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        closeLinkWindow()
        web?.stopLoading()
        web = nil
        unconnectedSince = nil
        state = .notStarted
    }

    /// Logs the device out through WhatsApp Web (which removes it from the phone's Linked
    /// Devices) and deletes its data (FR-1203).
    func unlink() async {
        if web != nil, state == .connected || state == .connecting {
            _ = try? await call("logout", .object([:]), timeout: .seconds(10))
            try? await Task.sleep(for: .seconds(2))
        }
        stop()
        wasLinked = false
        Self.setLinked(false)
        // WebKit must be set up (a web view made) before a store can be removed; see linkedKey.
        let starter = WKWebView(frame: .zero)
        try? await WKWebsiteDataStore.remove(forIdentifier: Self.storeID)
        _ = starter
        EventLog.shared.record(.app, "WhatsApp: unlinked Latchkey's device and deleted its data")
    }

    private func load() {
        loadedAt = Date()
        unconnectedSince = nil
        web?.load(URLRequest(url: Self.url))
    }

    // MARK: state

    /// Reads the page's state, and reloads a page that has been unconnected for a minute.
    func check() async {
        guard web != nil else { return }
        let next = await readState()
        let now = Date()
        switch next {
        case .connected:
            wasLinked = true
            Self.setLinked(true)
            unconnectedSince = nil
        case .connecting:
            if unconnectedSince == nil { unconnectedSince = now }
            if let since = unconnectedSince, now.timeIntervalSince(since) >= 60 {
                EventLog.shared.record(.app, "WhatsApp: not connected for a minute; reloading the page")
                load()
            }
        case .loading:
            if now.timeIntervalSince(loadedAt) >= 90 { load() }
        case .notLinked:
            if wasLinked {
                wasLinked = false
                Self.setLinked(false)
                EventLog.shared.record(.app, "WhatsApp: the page shows the log-in screen; the device was unlinked")
                Notifier.post(
                    "WhatsApp unlinked Latchkey. To use WhatsApp from Claude again, link it in Latchkey's Settings → Capabilities."
                )
            }
            if linkWindow == nil { unconnectedSince = nil }
            // A link code nobody entered: after 10 minutes the page goes (nothing runs unlinked).
            if !UserDefaults.standard.bool(forKey: Self.linkedKey), linkWindow == nil,
                now.timeIntervalSince(loadedAt) >= 600
            {
                Task { await self.unlink() }
            }
        case .notStarted, .changed:
            break
        }
        state = next
        if next == .connected, linkWindow != nil { closeLinkWindow() }
    }

    private func readState() async -> WhatsAppPageState {
        guard let answer = try? await call("state", .object([:]), timeout: .seconds(5)) else { return .loading }
        // On the log-in screen WhatsApp Web hasn't loaded its modules yet (2026-11-03: every one
        // looked missing), so only a page showing its chats can say a module is gone.
        if answer["loginScreen"]?.boolValue == true { return .notLinked }
        if answer["chatList"]?.boolValue == true, case .array(let gone) = answer["missing"], !gone.isEmpty {
            return .changed(gone.compactMap(\.stringValue))
        }
        if answer["connected"]?.boolValue == true { return .connected }
        if (answer["chats"]?.numberValue ?? 0) > 0 { return .connecting }
        return .loading
    }

    /// Starts the page if it isn't running and waits for a connection (plan D4).
    func ready(wait: Duration) async -> WhatsAppPageState {
        if web == nil {
            guard await Self.hasStore() else { return .notLinked }
            start()
        }
        let end = ContinuousClock.now + wait
        var reloaded = false
        while true {
            let s = await readState()
            state = s
            switch s {
            case .connected:
                wasLinked = true
                Self.setLinked(true)
                return s
            case .notLinked, .changed: return s
            case .connecting where !reloaded:
                reloaded = true
                load()
            default: break
            }
            if ContinuousClock.now >= end || Task.isCancelled { return s }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    func startForLinking(wait: Duration) async -> WhatsAppPageState {
        start()
        let end = ContinuousClock.now + wait
        while true {
            let s = await readState()
            state = s
            switch s {
            case .notLinked, .connected, .changed: return s
            default: break
            }
            if ContinuousClock.now >= end || Task.isCancelled { return s }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: calling the bridge

    func call(_ function: String, _ args: JSONValue, timeout: Duration) async throws -> JSONValue {
        guard let web else { throw WhatsAppPageError.failed("the page isn't running") }
        let body = """
            if (!window.__latchkey) return JSON.stringify({ __notLoaded: true });
            return JSON.stringify(await window.__latchkey[name](JSON.parse(args)));
            """
        let argsText = args.jsonText
        // WebKit can hold a call for ever (seen overnight while WhatsApp was disconnected), and it
        // can't be cancelled, so the answer or the timeout, whichever comes first, is the answer.
        let once = FirstAnswer()
        let text: String? = try await withCheckedThrowingContinuation { cont in
            Task { @MainActor in
                do {
                    let r = try await web.callAsyncJavaScript(
                        body, arguments: ["name": function, "args": argsText], in: nil, contentWorld: .page)
                    if once.claim() { cont.resume(returning: r as? String) }
                } catch {
                    if once.claim() { cont.resume(throwing: WhatsAppPageError.failed(error.localizedDescription)) }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if once.claim() { cont.resume(throwing: WhatsAppPageError.timedOut) }
            }
        }
        guard let text, let data = text.data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { throw WhatsAppPageError.failed("the page gave no answer") }
        if value["__notLoaded"]?.boolValue == true { throw WhatsAppPageError.failed("WhatsApp Web is still loading") }
        return value
    }

    // MARK: linking (plan D3)

    /// Shows the page in a window so the Owner can scan its QR code or use a code instead.
    func showForLinking() {
        start()
        if let linkWindow {
            linkWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard let web else { return }
        let content = NSHostingController(rootView: WhatsAppLinkView(web: web))
        let window = NSWindow(contentViewController: content)
        window.title = "Link WhatsApp"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 1000, height: 820))
        window.isReleasedWhenClosed = false
        window.center()
        linkWindow = window
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { WhatsAppPage.shared.linkWindowClosed() }
        }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func closeLinkWindow() {
        linkWindow?.close()
    }

    private func linkWindowClosed() {
        linkWindow?.contentViewController = nil
        linkWindow = nil  // WindowPresence returns the app to the menu bar
        // Linking abandoned: no page runs for a device that isn't linked.
        if state != .connected, state != .connecting {
            Task { await self.unlink() }
        }
    }

    // MARK: WKNavigationDelegate

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            EventLog.shared.record(.app, "WhatsApp: the page's web process ended; reloading")
            load()
        }
    }
}

/// The first of several racers to claim it gets to answer.
@MainActor
private final class FirstAnswer {
    private var done = false
    func claim() -> Bool {
        defer { done = true }
        return !done
    }
}

/// The linking window: the warning (FR-1232), the steps, and WhatsApp Web's own log-in screen.
struct WhatsAppLinkView: View {
    let web: WKWebView

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Link WhatsApp to Latchkey").font(.title2.bold())
            Text(
                "On your phone, open WhatsApp → Settings → Linked Devices → Link a Device, then scan the code below. Away from this Mac? Choose “Log in with phone number” below and type the code it shows into your phone."
            )
            Text(
                "WhatsApp’s terms forbid automated messaging. Latchkey sends only what you ask Claude to send, but WhatsApp could still limit or ban your account, though that is unlikely for personal use."
            )
            .foregroundStyle(.secondary)
            WebViewHost(web: web).frame(minWidth: 900, minHeight: 640)
        }
        .padding(16)
    }
}

/// Puts an existing web view into SwiftUI.
struct WebViewHost: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
