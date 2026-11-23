import AppKit
import WebKit

/// One page of Claude's in Latchkey's own browser (spec 005 FR-420, FR-444, Toni 2026-11-02 and
/// 2026-11-15): an off-screen WebKit view, first made for while the Mac is locked (Safari stops
/// answering scripts then, seen live 2026-11-01), and since 2026-11-15 used for every page Claude
/// opens, locked or not, so a page's dialog can wait for Claude's answer instead of freezing a
/// background Safari tab (FR-448). It holds Safari's cookies, read from Safari's file into a
/// store that lives only in memory, and taken again with every page Claude opens (FR-441), so
/// the Owner's signed-in sites work; it is discarded, cookies and all, when Claude closes it or
/// leaves it unused (`OwnPages`). It runs the same page scripts as Safari (`PageScripts`), so
/// Claude's answers look the same; it has one page and no tabs.
@MainActor
final class LockedBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var web: WKWebView?
    /// The window the view is in, never on screen (`holder`). It holds the view, so it goes when
    /// this browser goes, discarded or not: else the view lives on and WebKit calls back into a
    /// browser that is gone (a crash in the tests, 2026-11-22).
    private var holderWindow: NSWindow?

    isolated deinit {
        web?.navigationDelegate = nil
        web?.uiDelegate = nil
        holderWindow?.orderOut(nil)
        holderWindow?.contentView = nil
    }
    /// The page's name, as Claude passes it (FR-445); set by `OwnPages`.
    var name = ""
    /// What the page's own dialogs said since the last answer, told to Claude with the next
    /// page: alerts (dismissed), dialogs answered by what Claude gave in advance, and held ones
    /// that got Cancel (FR-449). Latchkey never says OK on its own (2026-11-02).
    private(set) var dialogs: [String] = []
    /// What Claude answered in advance with its action (FR-432, FR-450): good during the action
    /// and until `presetUntil`.
    private var dialogAnswer = DialogAnswer()
    private var presetUntil: ContinuousClock.Instant?
    /// A confirm or prompt waiting for Claude's answer (FR-448).
    struct Held {
        let id = UUID()
        let kind: String
        let message: String
        let defaultText: String
        let reply: @MainActor (Bool, String?) -> Void
    }
    private(set) var held: Held?
    /// Set when the page is a file this browser doesn't show (a PDF, an archive): its address and
    /// type. An off-screen view can't show a PDF, and its load never finished (live check
    /// 2026-11-15: a PDF's address timed out), so the load is stopped at once and the file is
    /// saved with browser_act download instead (FR-452).
    private(set) var file: (address: String, type: String)?
    /// Scripts of Latchkey's waiting on the page: answered with the held dialog when one comes,
    /// since the page can't finish them until it is answered.
    private var waiters: [UUID: (Result<String, Error>) -> Void] = [:]
    /// How long a held dialog waits for Claude (FR-449), and how long an answer Claude gave in
    /// advance lasts after its action (FR-450); tests shorten them.
    private let holdLimit: Duration
    private let presetWindow: Duration
    private var droppedDialogs = 0
    /// True while Claude's own click, typing, or script runs: only then may the page open a new
    /// window (security review 2026-11-02: a page's own pop-up can't take Claude's page away).
    private var acting = false
    private var finished: CheckedContinuation<Bool, Never>?
    /// Where a load failed, for the answer.
    private var failure: String?

    static let loadLimit: Duration = .seconds(20)

    /// The view's size, and whether the page's own scripts run: not in a copy drawn for a
    /// picture (FR-439), whose page is the markup of a page that already ran them.
    private let size: CGSize
    private let pageScripts: Bool
    /// Safari's cookies as they are now (tests give their own).
    private let cookies: @Sendable () -> [SafariCookies.Cookie]
    /// The cookie store, shared by all of Claude's pages (`OwnPages`), in memory only (FR-421);
    /// nil: one of this page's own.
    private let store: WKWebsiteDataStore?
    /// Logs each copy of Safari's cookies (FR-453); Claude's pages share one (`OwnPages`).
    private let watch: CookieWatch?
    private let fileAge: @Sendable () -> TimeInterval?
    /// Whether Safari's cookies may be copied now: while the Mac is locked only, for Claude's
    /// pages (FR-456: a copy that renews a rotating sign-in signs Safari out). Tests: always.
    private let mayCopy: @MainActor () -> Bool
    /// Latchkey's own sign-ins (spec 013 FR-1350): no copy of Safari's cookies for a site
    /// Latchkey signs in to itself, nor of a cookie that would reach one. Nil: none (tests).
    private let sessions: OwnSessions?
    /// Waited for before the first page: Latchkey's kept sign-ins going into the store (FR-1353).
    private let ready: @MainActor () async -> Void
    /// The sites whose Safari cookies this page has taken (by host), so a page going back and forth
    /// doesn't take them again.
    private var taken: Set<String> = []

    init(
        size: CGSize = CGSize(width: 1280, height: 900), pageScripts: Bool = true,
        cookies: @escaping @Sendable () -> [SafariCookies.Cookie] = SafariCookies.current,
        store: WKWebsiteDataStore? = nil, watch: CookieWatch? = nil,
        fileAge: @escaping @Sendable () -> TimeInterval? = { nil },
        mayCopy: @escaping @MainActor () -> Bool = { true }, sessions: OwnSessions? = nil,
        ready: @escaping @MainActor () async -> Void = {}, holdLimit: Duration = .seconds(300),
        presetWindow: Duration = .seconds(5)
    ) {
        self.mayCopy = mayCopy
        self.sessions = sessions
        self.ready = ready
        self.watch = watch
        self.fileAge = fileAge
        self.size = size
        self.pageScripts = pageScripts
        self.cookies = cookies
        self.store = store
        self.holdLimit = holdLimit
        self.presetWindow = presetWindow
    }

    /// Takes Safari's cookies for a site again, as they are now (FR-441): Safari's cookies whose
    /// domain covers `host` (the page's own when nil). With `overwrite`, each one this browser
    /// lacks or holds with another value is set, so Safari's copy wins, also for a cookie the site
    /// took away here; without, only those it lacks. What only this browser holds stays. Answers
    /// how many it set. Only one site's (2026-11-15): copying all of Safari's 3,500 cookies took
    /// over 100 seconds, so every new page timed out.
    @discardableResult
    func takeSafarisCookies(for host: String? = nil, overwrite: Bool = true) async -> Int {
        guard let web, let site = (host ?? web.url?.host())?.lowercased(), !site.isEmpty else { return 0 }
        guard mayCopy(), sessions?.isOwn(site) != true else { return 0 }  // FR-1350
        taken.insert(site)
        let wanted = cookies().filter { Self.covers($0.domain, site) && sessions?.reaches($0.domain) != true }
        let set = await Self.copy(
            wanted, into: web.configuration.websiteDataStore.httpCookieStore, overwrite: overwrite)
        watch?.copied(site: site, set: set, fileAge: fileAge())
        return set.count
    }

    /// Whether a cookie for `domain` goes to `host`, as browsers decide: the same host, or a host
    /// under it ("example.com" and ".example.com" cover "www.example.com").
    static func covers(_ domain: String, _ host: String) -> Bool {
        var d = domain.lowercased()
        if d.hasPrefix(".") { d.removeFirst() }
        return !d.isEmpty && (host == d || host.hasSuffix("." + d))
    }

    /// The cookie stores something was written to (`copy`).
    private static var written: Set<ObjectIdentifier> = []

    /// Per store, the domains a copy of Safari's cookies went to (each cookie's domain, bare): no
    /// cookie of those sites is kept as Latchkey's own sign-in from that store, also once a site
    /// becomes one Latchkey signs in to itself, and also under a name the site gave a copied
    /// session later, until the store's cookies are wiped (spec 013 FR-1353; security reviews
    /// 2026-11-21).
    private static var copiedDomains: [ObjectIdentifier: Set<String>] = [:]

    static func copied(in store: WKHTTPCookieStore) -> Set<String> { copiedDomains[ObjectIdentifier(store)] ?? [] }

    /// The store's copies of `these` domains are gone (wiped at unlock); nil: the store is gone.
    static func forgetCopied(in store: WKHTTPCookieStore, these: Set<String>? = nil) {
        let id = ObjectIdentifier(store)
        guard let these else {
            copiedDomains[id] = nil
            return
        }
        copiedDomains[id]?.subtract(these)
    }

    /// What the store holds is asked for first; with no answer in 2 s (WebKit doesn't answer for
    /// a store not yet in use, seen live 2026-11-14), every one is set, which changes nothing a
    /// page can see. The cookies are set all at once, not one after another.
    private static func copy(_ cookies: [SafariCookies.Cookie], into store: WKHTTPCookieStore, overwrite: Bool)
        async -> [HTTPCookie]
    {
        guard !cookies.isEmpty else { return [] }
        func key(_ c: HTTPCookie) -> String { "\(c.domain)\t\(c.path)\t\(c.name)" }
        var held: [String: String] = [:]
        // A store nothing was written to holds nothing: not asked (WebKit wouldn't answer).
        if written.contains(ObjectIdentifier(store)), let now = await holding(store) {
            for c in now { held[key(c)] = c.value }
        }
        written.insert(ObjectIdentifier(store))
        let offered = cookies.compactMap(SafariCookies.httpCookie)
        copiedDomains[ObjectIdentifier(store), default: []].formUnion(offered.map { OwnSessions.bare($0.domain) })
        let todo = offered.filter {
            let here = held[key($0)]
            return overwrite ? here != $0.value : here == nil
        }
        guard !todo.isEmpty else { return [] }
        final class Left { var count: Int; init(_ n: Int) { count = n } }
        let left = Left(todo.count)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            for cookie in todo {
                store.setCookie(cookie) {
                    left.count -= 1
                    if left.count == 0 { done.resume() }
                }
            }
        }
        return todo
    }

    /// What the store holds, or nil when WebKit doesn't say within 2 s.
    static func holding(_ store: WKHTTPCookieStore) async -> [HTTPCookie]? {
        final class Once { var done = false }
        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<[HTTPCookie]?, Never>) in
            store.getAllCookies { cookies in
                MainActor.assumeIsolated {
                    guard !once.done else { return }
                    once.done = true
                    c.resume(returning: cookies)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !once.done else { return }
                once.done = true
                c.resume(returning: nil)
            }
        }
    }

    /// Whether this page has Safari's sign-ins now (they are copied only while that is allowed).
    var signedInFromSafari: Bool { mayCopy() }

    /// The site of the page Latchkey signs in to itself, if it is one (FR-1355).
    var ownSite: String? { web?.url?.host().flatMap { sessions?.ownSite($0) } }

    /// Sets Latchkey's kept sign-ins into a store (`OwnPages`, FR-1353), noting it was written to.
    static func set(_ cookies: [HTTPCookie], into store: WKHTTPCookieStore) async {
        guard !cookies.isEmpty else { return }
        written.insert(ObjectIdentifier(store))
        for c in cookies { await store.setCookie(c) }
    }

    /// The sites taken are forgotten, so their cookies are taken again when next allowed
    /// (FR-458: the copies were dropped).
    func forgetTaken() { taken = [] }

    /// FR-442: Safari's cookies again, then the page Claude is on loaded again.
    func signInAgain() async throws -> PageScripts.Page {
        guard web != nil else { throw SafariBrowser.Failure.noWindow }
        await takeSafarisCookies()
        try await navigate { $0.reload() }
        return try await page(offset: 0)
    }

    /// The view, made on first use; Safari's cookies come per site, as pages go there.
    private func view() async -> WKWebView {
        if let web { return web }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store ?? .nonPersistent()  // memory only: nothing written to disk
        config.defaultWebpagePreferences.allowsContentJavaScript = pageScripts
        let w = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        w.navigationDelegate = self
        w.uiDelegate = self
        // Sites see Safari, as they do in the Owner's Safari: some refuse an app's own web view
        // (Google's sign-in, for one).
        w.customUserAgent = Self.safariUserAgent
        holderWindow = Self.holder(for: w)
        web = w
        return w
    }

    /// A window for the view that never comes on screen: far off every screen, see-through,
    /// never taking the mouse or the keyboard, in no window list, behind every other window, never
    /// brought forward (Constitution IV). Without a window WebKit counts every page hidden and
    /// holds back its animation frames, so pages that draw themselves on one never appear
    /// (Chase's sign-in steps, 2026-11-22: blank, its components never started); and an
    /// off-screen window would count as covered, so WebKit's check for that is off for this view
    /// (its own setting, as Safari has for its tabs; no public name). Spec 005 FR-467.
    static func holder(for view: WKWebView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: view.frame.width, height: view.frame.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.sharingType = .none  // never listed by screen sharing or recording
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.contentView = view
        // Called directly: key-value coding has no such key and throws (2026-11-22, a hang in the
        // tests). Only the window ordered in with this off makes the page visible (tried: no
        // window, a window not ordered in, and the check left on all leave it hidden).
        let occlusion = Selector(("_setWindowOcclusionDetectionEnabled:"))
        if let method = class_getInstanceMethod(Swift.type(of: view), occlusion) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(method_getImplementation(method), to: Setter.self)(view, occlusion, false)
        }
        window.orderBack(nil)
        return window
    }

    /// The window a page is told it is in, in the screen's coordinates (origin at the bottom
    /// left): a browser window at the top left of the main screen's free area, as big as the page
    /// plus a toolbar (Safari's is 90 points). WebKit asks the app for it, as it asks Safari; an
    /// app that doesn't answer gets a 0×0 window at no place on the screen, which sites'
    /// protection against bots reads as a robot (Citi turned the sign-in away after its code,
    /// 2026-11-22; Toni: "change the background tab to be more real so this legitimate use case
    /// can work"). Nothing comes on screen: there is no window.
    static func windowFrame(page: CGSize, screen: CGRect?) -> CGRect {
        let free = screen ?? CGRect(x: 0, y: 0, width: 1512, height: 949)
        let height = page.height + 90
        return CGRect(x: free.minX, y: free.maxY - height, width: page.width, height: height)
    }

    /// Where the never-shown window says it is: at the top left of the main screen's free area,
    /// as a browser window usually is.
    static func windowFrame(_ size: CGSize) -> NSRect {
        let free = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 949)
        return NSRect(
            x: free.minX, y: max(free.minY, free.maxY - size.height - 28), width: size.width, height: size.height)
    }

    /// Safari's own user agent, built from its installed version.
    nonisolated static let safariUserAgent: String = {
        let info =
            NSDictionary(
                contentsOfFile: "/Applications/Safari.app/Contents/Info.plist") as? [String: Any]
        let safari = (info?["CFBundleShortVersionString"] as? String) ?? "18.0"
        return
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safari) Safari/605.1.15"
    }()

    /// Takes the dialogs noted since the last call.
    func takeDialogs() -> [String] {
        defer {
            dialogs = []
            droppedDialogs = 0
        }
        return dialogs + (droppedDialogs > 0 ? ["…and \(droppedDialogs) more."] : [])
    }

    /// At most 5 notes (security review 2026-11-02: a page could flood Claude), worded as in
    /// Safari (`PageScripts.dialogNote`).
    private func note(_ kind: String, _ message: String, _ answer: String?) {
        guard dialogs.count < 5 else {
            droppedDialogs += 1
            return
        }
        dialogs.append(PageScripts.dialogNote(kind: kind, message: message, answer: answer))
    }

    // MARK: the page's dialogs and new windows

    nonisolated func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        MainActor.assumeIsolated {
            note("alert", message, nil)
            completionHandler()
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            // FR-450: what Claude answered in advance; else the dialog waits for Claude (FR-448).
            if let ok = preset.confirm {
                note("confirm", message, ok ? "ok" : "cancel")
                completionHandler(ok)
                return
            }
            hold("confirm", message, "") { ok, _ in completionHandler(ok) }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        MainActor.assumeIsolated {
            let given = preset
            if given.text != nil || given.confirm == false {
                let text = given.confirm == false ? nil : given.text
                note("prompt", prompt, text ?? "")
                completionHandler(text)
                return
            }
            hold("prompt", prompt, defaultText ?? "") { ok, text in completionHandler(ok ? text : nil) }
        }
    }

    /// What Claude answered in advance, while it counts: during its action and for a moment after
    /// (FR-450); none otherwise.
    private var preset: DialogAnswer {
        if acting { return dialogAnswer }
        if let until = presetUntil, ContinuousClock.now < until { return dialogAnswer }
        return DialogAnswer()
    }

    /// Keeps a dialog for Claude (FR-448): the scripts waiting on the page are told at once, and
    /// the dialog gets Cancel when Claude hasn't answered within the limit (FR-449).
    private func hold(
        _ kind: String, _ message: String, _ defaultText: String, reply: @escaping @MainActor (Bool, String?) -> Void
    ) {
        if let old = held {  // a page shows one at a time; should another come, the old one is let go
            held = nil
            old.reply(false, nil)
        }
        let h = Held(kind: kind, message: message, defaultText: defaultText, reply: reply)
        held = h
        let told = SafariBrowser.Failure.dialogHeld(page: name, kind: kind, message: message)
        let waiting = waiters
        waiters = [:]
        for w in waiting.values { w(.failure(told)) }
        let limit = holdLimit
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: limit)
            guard let self, self.held?.id == h.id else { return }
            self.cancelHeld(why: "after 5 minutes without Claude's answer")
        }
    }

    /// Gives a held dialog Cancel (a prompt: no text) and notes it for Claude (FR-449).
    private func cancelHeld(why: String) {
        guard let h = held else { return }
        held = nil
        note(h.kind, h.message, h.kind == "confirm" ? "cancel" : "")
        if let last = dialogs.indices.last, dialogs[last].hasSuffix(".") {
            dialogs[last] = String(dialogs[last].dropLast()) + ", \(why)."
        }
        h.reply(false, nil)
    }

    /// Claude's answer to the held dialog (FR-448): OK or Cancel, and for a prompt its text (or
    /// the page's own suggestion). Then the page as it is once it settled.
    func answerDialog(ok: Bool, text: String?) async throws -> PageScripts.Page {
        guard let h = held else {
            throw SafariBrowser.Failure.failed(
                "No dialog is waiting in page \"\(name)\". Read the page with browser_read to see it as it is.")
        }
        let before = web?.url?.absoluteString
        held = nil
        h.reply(ok, h.kind == "prompt" ? (text ?? h.defaultText) : nil)
        await settle(from: before, atMost: .seconds(2))
        return try await page(offset: 0)
    }

    /// WebKit's question for the page's window (`windowFrame`). WebKit's own name for it, which
    /// it asks of any delegate that answers it (WKUIDelegatePrivate); there is no public one.
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    nonisolated func pageWindow(_ webView: WKWebView, completion: @escaping @MainActor @Sendable (CGRect) -> Void) {
        MainActor.assumeIsolated {
            completion(Self.windowFrame(page: webView.frame.size, screen: NSScreen.main?.visibleFrame))
        }
    }

    /// A link that opens a new window or tab (target=_blank, window.open) opens here instead:
    /// this browser has one page.
    nonisolated func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        MainActor.assumeIsolated {
            guard let url = navigationAction.request.url else { return }
            if acting, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                (navigationAction.request.httpMethod ?? "GET") == "GET"
            {
                webView.load(navigationAction.request)
            } else {
                note("The page tried to open a new window at", url.host() ?? "?", " (ignored).")
            }
        }
        return nil
    }

    /// Drops the page and its cookies (Claude closed it, or left it unused). A held dialog gets
    /// Cancel first, so the page's script isn't left waiting.
    func discard() {
        if let h = held {
            held = nil
            h.reply(false, nil)
        }
        let waiting = waiters
        waiters = [:]
        for w in waiting.values { w(.failure(SafariBrowser.Failure.noWindow)) }
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.uiDelegate = nil
        web = nil
        holderWindow?.orderOut(nil)
        holderWindow?.contentView = nil
        holderWindow = nil
        dialogs = []
        finished?.resume(returning: false)
        finished = nil
    }

    // MARK: navigation

    /// A page going to a site whose Safari cookies it hasn't taken (a click, a redirect, a frame)
    /// takes those it lacks first, never replacing what the site set here during the visit
    /// (FR-441: swapping a cookie under a form could break its own token).
    nonisolated func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            let url = navigationAction.request.url
            guard mayCopy(), let host = url?.host()?.lowercased(), !host.isEmpty, !taken.contains(host),
                ["http", "https"].contains(url?.scheme?.lowercased() ?? ""), sessions?.isOwn(host) != true
            else {
                decisionHandler(.allow)
                return
            }
            taken.insert(host)
            Task { @MainActor [weak self] in
                await self?.takeSafarisCookies(for: host, overwrite: false)
                decisionHandler(.allow)
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            let type = navigationResponse.response.mimeType ?? ""
            if navigationResponse.isForMainFrame, let url = navigationResponse.response.url,
                !navigationResponse.canShowMIMEType || type == "application/pdf"
            {
                file = (url.absoluteString, type)
                decisionHandler(.cancel)
                done(true)
                return
            }
            decisionHandler(.allow)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { if isCurrent(navigation) { done(true) } }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { if isCurrent(navigation) { failed(error) } }
    }

    /// Whether WebKit's news is of the load Latchkey waits for: a late word of an earlier load (a
    /// file whose load was stopped, seen with the suites side by side) must not end or fail the
    /// next one. A load WebKit gave no navigation for counts as the current one.
    private func isCurrent(_ navigation: WKNavigation?) -> Bool {
        current == nil || navigation == nil || navigation === current
    }

    /// "Cancelled" (-999) is a page replaced by the next one, or back served from memory (seen live
    /// 2026-11-02: back said -999 and showed the page): not a failure.
    private func failed(_ error: any Error) {
        // A file's load was stopped on purpose (FR-452), and a cancelled one (-999) is a page
        // replaced by the next one, or back served from memory: not failures.
        let e = error as NSError
        // WebKit stops a load it won't show itself too (102, "Frame load interrupted"), at times
        // before the response check above has run (seen with the suites side by side): a file.
        if file == nil, e.code == 102, ["WebKitErrorDomain", WKError.errorDomain].contains(e.domain) {
            let address = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? web?.url?.absoluteString
            if let address { file = (address, "") }
        }
        if file != nil || e.code == NSURLErrorCancelled {
            done(true)
            return
        }
        failure = error.localizedDescription
        done(false)
    }

    nonisolated func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        MainActor.assumeIsolated { if isCurrent(navigation) { failed(error) } }
    }

    private func done(_ ok: Bool) {
        finished?.resume(returning: ok)
        finished = nil
    }

    /// The load `navigate` waits for, as WebKit named it.
    private var current: WKNavigation?

    /// Runs `start`, then waits for the page it loads to finish, at most `loadLimit`.
    private func navigate(_ start: (WKWebView) -> WKNavigation?) async throws {
        let w = await view()
        cancelHeld(why: "before the page was replaced")  // FR-449
        failure = nil
        file = nil
        finished?.resume(returning: false)
        let before = w.url
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            finished = c
            current = nil
            current = start(w)
            // A page that changes without loading (history.pushState, back within one page) never
            // says it finished: done once its address changed and nothing loads (2026-11-02).
            Task { @MainActor [weak self] in
                let deadline = ContinuousClock.now + Self.loadLimit
                while ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, self.finished != nil else { return }
                    if w.url != before, !w.isLoading {
                        self.done(true)
                        return
                    }
                }
                self?.done(false)
            }
        }
        if !ok, let failure {
            throw SafariBrowser.Failure.failed("The page didn't load: \(failure)")
        }
    }

    /// After a click or a form: waits up to 5 s for the address to change and the page to
    /// finish, or for a dialog the page holds for Claude (FR-448).
    private func settle(from address: String?, atMost: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + atMost
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            guard let w = web, held == nil else { return }
            if w.url?.absoluteString != address, !w.isLoading { return }
            // No new page after a second: the action changed this one; `quiet` waits for it.
            if !w.isLoading, ContinuousClock.now > deadline - atMost + .seconds(1) { return }
        }
    }

    /// Runs a script in the page, as text (`text` turns its value into text). A page holding a
    /// dialog runs no script until the dialog is answered: one that would start is refused, and
    /// one running when a dialog comes is answered with the dialog (its late result is dropped).
    private func evaluate(
        _ code: String, async: Bool = false, world: WKContentWorld = .page,
        text: @escaping @MainActor @Sendable (Any?) -> String
    ) async throws -> String {
        if let h = held { throw SafariBrowser.Failure.dialogHeld(page: name, kind: h.kind, message: h.message) }
        if let file { throw SafariBrowser.Failure.failed(Self.fileNote(name, file)) }
        let w = await view()
        let id = UUID()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            waiters[id] = { c.resume(with: $0) }
            // The reply is taken as WebKit delivers it, in order with the page's dialogs: a dialog
            // the page shows right after the script finished doesn't take the script's result.
            if async {
                // An async function body: WebKit awaits its promise (scripts with await).
                w.callAsyncJavaScript(code, arguments: [:], in: nil, in: .page) { [weak self] result in
                    guard let self, let waiter = self.waiters.removeValue(forKey: id) else { return }
                    switch result {
                    case .success(let value): waiter(.success(text(value)))
                    case .failure(let error): waiter(.failure(error))
                    }
                }
            } else if world == .page {
                w.evaluateJavaScript(code) { [weak self] value, error in
                    guard let self, let waiter = self.waiters.removeValue(forKey: id) else { return }
                    waiter(error.map { .failure($0) } ?? .success(text(value)))
                }
            } else {
                // A world of Latchkey's own: the page's scripts can't change what this one uses
                // (spec 013: a sign-in's checks and filling, security review 2026-11-21).
                w.evaluateJavaScript(code, in: nil, in: world) { [weak self] result in
                    guard let self, let waiter = self.waiters.removeValue(forKey: id) else { return }
                    switch result {
                    case .success(let value): waiter(.success(text(value)))
                    case .failure(let error): waiter(.failure(error))
                    }
                }
            }
        }
    }

    /// Spec 013: the world sign-in scripts run in, apart from the page's own.
    static let signInWorld = WKContentWorld.world(name: "latchkey-sign-in")

    private func script(_ code: String, world: WKContentWorld = .page) async throws -> String {
        do {
            return try await evaluate(code, world: world) { value in
                if let s = value as? String { return s }
                if let n = value as? NSNumber { return n.stringValue }
                return value.map { "\($0)" } ?? ""
            }
        } catch let f as SafariBrowser.Failure {
            throw f
        } catch {
            throw SafariBrowser.Failure.failed("The page's script failed: \(PageScripts.failure(error))")
        }
    }

    /// Claude's action starts: its answers in advance count until it ends (FR-432).
    private func begin(_ answer: DialogAnswer) {
        acting = true
        dialogAnswer = answer
        presetUntil = nil
    }

    /// Claude's action ended: its answers in advance count for a moment more (FR-450).
    private func end() {
        acting = false
        presetUntil = dialogAnswer.given ? ContinuousClock.now + presetWindow : nil
    }

    private func page(offset: Int) async throws -> PageScripts.Page {
        if let file {  // FR-452: nothing to read; the answer says what it is (`fileNote`)
            let name = URL(string: file.address)?.lastPathComponent ?? ""
            return PageScripts.Page(title: name, url: file.address, total: 0, text: "", elements: [])
        }
        if offset == 0 { await PageScripts.quiet { try await script(PageScripts.changes) } }
        do { return try PageScripts.decode(try await script(PageScripts.read(offset: offset))) } catch is DecodingError
        {
            throw SafariBrowser.Failure.failed("The page didn't answer as expected.")
        }
    }

    // MARK: what Claude does

    func open(_ url: String) async throws -> PageScripts.Page {
        let address = try SafariBrowser.normalize(url)
        guard let u = URL(string: address) else { throw SafariBrowser.Failure.failed("That address isn't valid.") }
        _ = await view()
        await ready()  // FR-1353: Latchkey's kept sign-ins are in the store first
        await takeSafarisCookies(for: u.host())  // FR-441: Safari's copy wins
        try await navigate { $0.load(URLRequest(url: u)) }
        var p = try await page(offset: 0)
        // A slow site still loading after the limit answered with an empty page and no word of
        // why (bugzilla.samba.org, regression run 2026-11-16).
        if file == nil, p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, web?.isLoading == true {
            p.text =
                "(The page is still loading after \(Self.loadLimit.components.seconds) seconds: read it again in a moment with browser_read and this page's name.)"
        }
        return p
    }

    /// A page from text, at `base` (tests: the real WebKit view, no network).
    func open(html: String, base: URL) async throws -> PageScripts.Page {
        _ = await view()
        await ready()
        await takeSafarisCookies(for: base.host())
        try await navigate { $0.loadHTMLString(html, baseURL: base) }
        return try await page(offset: 0)
    }

    func read(offset: Int) async throws -> PageScripts.Page {
        guard web != nil else { throw SafariBrowser.Failure.noWindow }
        return try await page(offset: offset)
    }

    func click(_ ref: String, answer: DialogAnswer = DialogAnswer()) async throws -> PageScripts.Page {
        begin(answer)
        defer { end() }
        guard let w = web else { throw SafariBrowser.Failure.noWindow }
        let before = w.url?.absoluteString
        let answer = try await script(PageScripts.click(ref))
        let lines = answer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        try check(lines.first ?? "", ref: ref)
        await settle(from: before)
        // A link a script clicks doesn't always navigate in a view of Latchkey's own (seen live):
        // go to its address, as a click would.
        if w.url?.absoluteString == before, lines.count > 1,
            let data = lines[1].data(using: .utf8), let href = try? JSONDecoder().decode(String.self, from: data),
            let target = URL(string: href), ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
            href != before
        {
            try await navigate { $0.load(URLRequest(url: target)) }
        }
        return try await page(offset: 0)
    }

    func type(_ ref: String, text: String, submit: Bool, answer: DialogAnswer = DialogAnswer()) async throws
        -> PageScripts.Page
    {
        begin(answer)
        defer { end() }
        guard let w = web else { throw SafariBrowser.Failure.noWindow }
        let before = w.url?.absoluteString
        try check(
            (try await script(PageScripts.type(ref, text: text, submit: submit))).split(separator: "\n").first.map(
                String.init) ?? "", ref: ref, option: text)
        if submit { await settle(from: before) }
        return try await page(offset: 0)
    }

    func back() async throws -> PageScripts.Page {
        guard let w = web else { throw SafariBrowser.Failure.noWindow }
        let before = w.url
        if w.canGoBack {
            try await navigate { $0.goBack() }
        } else {
            // WebKit's own list may not have an entry the page made (history.pushState): the
            // page's history goes back then.
            _ = try? await w.evaluateJavaScript("history.back(); 1")
            await settle(from: before?.absoluteString)
            guard w.url != before else { throw SafariBrowser.Failure.failed("There's no page to go back to.") }
        }
        return try await page(offset: 0)
    }

    func run(_ code: String, answer: DialogAnswer = DialogAnswer()) async throws -> String {
        begin(answer)
        defer { end() }
        guard let w = web else { throw SafariBrowser.Failure.noWindow }
        let before = w.url?.absoluteString
        do {
            let shown: @MainActor @Sendable (Any?) -> String = { value in
                if let s = value as? String { return s }
                if let v = value, JSONSerialization.isValidJSONObject(v),
                    let data = try? JSONSerialization.data(withJSONObject: v)
                {
                    return String(decoding: data, as: UTF8.self)
                }
                return value.map { "\($0)" } ?? "undefined"
            }
            if !PageScripts.usesAwait(code), !PageScripts.returnsOutsideFunction(code) {
                // Given to WebKit as it is: a page's Content Security Policy forbids the eval that
                // Safari's wrapper uses (seen live on GitHub), but not a script the app itself runs.
                return try await evaluate(code, text: shown)
            }
            // One body, chosen by the syntax check, run once (security review 2026-11-23: a page
            // could throw a SyntaxError from its own code and have Claude's run again).
            let body = PageScripts.asyncBodies(code).first ?? code
            return try await evaluate(PageScripts.asyncFunction(body), async: true, text: shown)
        } catch let f as SafariBrowser.Failure {
            throw f
        } catch {
            // A script that sends the page elsewhere ends with the page it ran in (seen live).
            await settle(from: before)
            if let now = w.url?.absoluteString, now != before { return "The page went to \(now)." }
            throw SafariBrowser.Failure.failed("Error: \(PageScripts.failure(error))")
        }
    }

    /// One of the action scripts of 2026-11-04 (`PageActions.swift`), as in Safari: what it did,
    /// and the page after it. `mayNavigate`: Claude's own action, which may open a page (as a
    /// click), so the answer waits for it.
    private func act(
        _ code: String, ref: String, mayNavigate: Bool, answer: DialogAnswer, world: WKContentWorld = .page
    ) async throws
        -> (detail: String, page: PageScripts.Page)
    {
        begin(answer)
        defer { end() }
        guard let w = web else { throw SafariBrowser.Failure.noWindow }
        let before = w.url?.absoluteString
        let detail = try SafariBrowser.detail(try await script(code, world: world), ref: ref)
        if mayNavigate { await settle(from: before) }
        return (detail, try await page(offset: 0))
    }

    /// A sign-in script (spec 013, `SignInScripts.swift`), in Latchkey's own world: what it
    /// answered, the page after it, and the page's address as WebKit has it (never as the page's
    /// script says).
    func signInScript(_ code: String, navigates: Bool) async throws
        -> (detail: String, page: PageScripts.Page, address: String)
    {
        let r = try await act(code, ref: "", mayNavigate: navigates, answer: DialogAnswer(), world: Self.signInWorld)
        return (r.detail, r.page, web?.url?.absoluteString ?? "")
    }

    func press(_ keys: [PageScripts.Key], ref: String?, answer: DialogAnswer = DialogAnswer()) async throws
        -> (detail: String, page: PageScripts.Page)
    {
        try await act(PageScripts.keys(keys, ref: ref), ref: ref ?? "", mayNavigate: true, answer: answer)
    }

    func hover(_ ref: String) async throws -> (detail: String, page: PageScripts.Page) {
        try await act(PageScripts.hover(ref), ref: ref, mayNavigate: false, answer: DialogAnswer())
    }

    func scroll(_ ref: String?, direction: String, amount: Int?) async throws
        -> (detail: String, page: PageScripts.Page)
    {
        try await act(
            PageScripts.scroll(ref, direction: direction, amount: amount), ref: ref ?? "", mayNavigate: false,
            answer: DialogAnswer())
    }

    func choose(_ ref: String, options: [String], answer: DialogAnswer = DialogAnswer()) async throws
        -> (detail: String, page: PageScripts.Page)
    {
        try await act(PageScripts.choose(ref, options: options), ref: ref, mayNavigate: true, answer: answer)
    }

    func attach(_ ref: String, files: [PageScripts.Attachment], answer: DialogAnswer = DialogAnswer()) async throws
        -> (detail: String, page: PageScripts.Page)
    {
        try await act(PageScripts.attach(ref, files: files), ref: ref, mayNavigate: true, answer: answer)
    }

    /// A file fetched in the page, as in Safari (FR-438). A page that is itself a file (FR-452) has
    /// no page to fetch it: Latchkey fetches its address itself, with Safari's cookies.
    func fetchFile(ref: String?, url: String?, maxBytes: Int, wait: Duration = .seconds(20)) async throws
        -> (address: String, suggested: String, fetched: PageScripts.Fetched)
    {
        guard web != nil else { throw SafariBrowser.Failure.noWindow }
        if let file, ref == nil, url == nil {
            return (
                file.address, URL(string: file.address)?.lastPathComponent ?? "",
                PageScripts.Fetched(state: "failed", error: "a file, not a page")
            )
        }
        let start = try PageScripts.DownloadStart.decode(
            try SafariBrowser.detail(
                try await script(PageScripts.startDownload(ref: ref, url: url, limit: maxBytes)), ref: ref ?? ""))
        let deadline = ContinuousClock.now + wait
        while ContinuousClock.now < deadline {
            let f = try PageScripts.Fetched.decode(try await script(PageScripts.takeDownload))
            if f.state != "running" { return (start.address, start.suggested, f) }
            try await Task.sleep(for: .milliseconds(100))
        }
        return (start.address, start.suggested, PageScripts.Fetched(state: "failed", error: BrowserDownloads.tooLong))
    }

    /// The address of the page, for saving it when the page can't fetch it itself.
    var address: String? { file?.address ?? web?.url?.absoluteString }

    /// What Claude is told of a page that is a file (FR-452).
    static func fileNote(_ page: String, _ file: (address: String, type: String)) -> String {
        "Page \"\(page)\" is a file (\(file.type.isEmpty ? "not a web page" : file.type)), which Latchkey's own browser doesn't show: save it to the Mac's Downloads folder with browser_act action download and page \"\(page)\" (no ref or url), then read it with files_read."
    }

    /// The note for this page when it is a file (FR-452).
    var fileNoteIfAny: String? { file.map { Self.fileNote(name, $0) } }

    /// A picture drawn from a copy of a page (FR-439): the copy is loaded, without its scripts,
    /// in a view of Latchkey's own as big as the page's window, signed in with Safari's cookies
    /// so its pictures load as in the page, scrolled where the page was, and drawn.
    static func draw(_ copy: PageScripts.PictureCopy) async throws -> PreparedImage {
        let width = min(max(copy.width, 320), 2560)
        let height = min(max(copy.height, 240), 1600)
        let b = LockedBrowser(
            size: CGSize(width: width, height: height), pageScripts: false, mayCopy: { SystemScreen().isLocked() })
        defer { b.discard() }
        guard let base = URL(string: copy.url), ["http", "https"].contains(base.scheme?.lowercased() ?? "") else {
            throw SafariBrowser.Failure.failed("Latchkey can't draw this page (\(copy.url.prefix(60))).")
        }
        let w = await b.view()
        try await b.navigate { $0.loadHTMLString(copy.html, baseURL: base) }
        _ = try? await w.evaluateJavaScript("window.scrollTo(\(Int(copy.x)), \(Int(copy.y))); 1")
        try? await Task.sleep(for: .milliseconds(150))
        return try await b.screenshot()
    }

    /// The page as a picture.
    func screenshot() async throws -> PreparedImage {
        guard let w = web else { throw SafariBrowser.Failure.noWindow }
        let image = try await w.takeSnapshot(configuration: WKSnapshotConfiguration())
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { throw SafariBrowser.Failure.failed("The page couldn't be drawn.") }
        return try ImagePrep.prepare(data: png)
    }

    /// The one page, as Safari's tab list shows tabs.
    func tabs() -> (current: Int, tabs: [(Int, String, String)]) {
        guard let w = web else { return (0, []) }
        return (1, [(1, w.title ?? "", w.url?.absoluteString ?? "")])
    }

    private func check(_ answer: String, ref: String, option: String = "") throws {
        switch answer {
        case "ok": return
        case "missing": throw SafariBrowser.Failure.elementMissing(ref)
        case "nooption": throw SafariBrowser.Failure.noOption(option)
        default: throw SafariBrowser.Failure.failed("The page answered: \(answer)")
        }
    }
}
