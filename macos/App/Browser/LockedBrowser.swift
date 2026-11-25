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
final class LockedBrowser: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private var web: WKWebView? {
        didSet { leftovers.web = web }
    }
    /// The window the view is in, never on screen (`holder`). It holds the view, so it goes when
    /// this browser goes, discarded or not: else the view lives on and WebKit calls back into a
    /// browser that is gone (a crash in the tests, 2026-11-22).
    private var holderWindow: NSWindow? {
        didSet { leftovers.window = holderWindow }
    }
    /// Tidies the view and its window away on the main thread when this browser goes, from
    /// whichever thread lets go of it last. An `isolated deinit` did this until 2026-11-23, and
    /// crashed on macOS 26 when a browser was let go off the main thread (a failed page load in
    /// browser_open; seen in CI on GitHub's macOS 26 runner).
    private let leftovers = Leftovers()
    /// The page's running record for problem reports, memory only, gone with the page (spec 014
    /// FR-1446).
    let record = PageRecord()

    private final class Leftovers: @unchecked Sendable {
        var web: WKWebView?
        var window: NSWindow?

        deinit {
            nonisolated(unsafe) let web = web
            nonisolated(unsafe) let window = window
            guard web != nil || window != nil else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    web?.navigationDelegate = nil
                    web?.uiDelegate = nil
                    window?.orderOut(nil)
                    window?.contentView = nil
                }
            }
        }
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

    /// Spec 005 FR-475: where the files the page offers to save go (the Owner's Downloads; tests
    /// give their own folder).
    private let downloadsFolder: URL
    /// FR-476: how long after Claude's action a save the page starts still counts as Claude's (a
    /// click's save can start just after the click returned, as a dialog can, FR-450).
    private let downloadWindow: Duration
    private var actedUntil: ContinuousClock.Instant?
    /// When Claude's last action began: an answer waits only for saves started since (FR-477).
    private var actionBegan = ContinuousClock.now
    /// One save running: WebKit writes it to a staging file of Latchkey's own (a hidden name
    /// nobody else uses), moved to a free name in Downloads once complete, so a failed or stopped
    /// save never removes a file someone else put there (security review 2026-11-24).
    struct Saving {
        let download: WKDownload
        var staging: URL?
        var name = ""
        let started: ContinuousClock.Instant
    }
    private var saving: [ObjectIdentifier: Saving] = [:]
    /// Saves started in this action's window, and those refused past the most (FR-476).
    private var savesInWindow = 0
    private var savesRefused = 0
    static let savesPerAction = 5
    /// Set when the response check turned the current load into a save: WebKit then ends that
    /// load with "frame load interrupted" (102), which is not a page that is a file (FR-452).
    private var loadBecameSave = false
    /// What Claude is told of saves with the next answer (FR-477), at most 5 (as dialogs: a page
    /// could flood Claude).
    private var savedNotes: [String] = []

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
        presetWindow: Duration = .seconds(5), downloads: URL = BrowserDownloads.downloads,
        downloadWindow: Duration = .seconds(5)
    ) {
        self.downloadsFolder = downloads
        self.downloadWindow = downloadWindow
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
        if pageScripts { record.install(in: config) }  // the hidden world's recorder (spec 014 FR-1446)
        // FR-485: counts the trusted events the page took, in Latchkey's input world.
        config.userContentController.addUserScript(RealInput.userScript)
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
        let window = HolderWindow(
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
        // The view takes the keys of its window (FR-480); the window counts as key only while
        // Claude acts (`HolderWindow.active`, FR-483), and never really becomes key.
        window.makeFirstResponder(view)
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
    /// app that doesn't answer gets a 0×0 window at no place on the screen. That 0×0 window made
    /// Citi end the sign-in after its code (2026-11-22), a Latchkey bug fixed by answering the
    /// window frame (Toni: "change the background tab to be more real so this legitimate use case
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
                "No dialog is waiting in page \"\(name)\". Read the page with browser_look to see it as it is.")
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
        // A save running when the page closes stops; its staging file goes (FR-475).
        let running = saving.values
        saving = [:]
        for r in running { Self.stop(r) }
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
        record.clear()  // nothing of the page stays (spec 014 FR-1446)
    }

    // MARK: problem reports (spec 014 FR-1447)

    /// The page as it is, for a problem report: read in the hidden world, so the page can't see it
    /// or answer for it; every field's value blanked; the record; the site's cookie names, never
    /// a value; whether it draws; a screenshot. Each step has its own limit: a page that doesn't
    /// answer leaves its part out, with a note.
    /// `step`: the limit of each read (tests on a busy runner give more).
    func describe(name: String, macLocked: Bool, displayAsleep: Bool, step: Duration = .seconds(3)) async -> JSONValue {
        var o: [String: JSONValue] = ["name": .string(name), "where": .string("own")]
        var notes: [String] = []
        guard let w = web else {
            o["note"] = .string("the page has no view (closed or never loaded)")
            return .object(o)
        }
        o["address"] = .string(PageRecord.shownAddress(w.url?.absoluteString ?? ""))
        o["title"] = .string(w.title ?? "")
        if held != nil { notes.append("the page holds a dialog for Claude, so its scripts can't run") }
        if held == nil, pageScripts {
            let snap: String? = await Deadline.first(within: step) { @MainActor @Sendable [weak self] in
                await self?.hidden(PageRecord.snapshot, async: false)
            }
            if let snap, case .object(let page)? = try? JSONDecoder().decode(JSONValue.self, from: Data(snap.utf8)) {
                var drawing: [String: JSONValue] = [:]
                for k in ["visibility", "hidden", "focus", "window", "screen"] { drawing[k] = page[k] }
                o["drawing"] = .object(drawing)
                if case .string(let src)? = page["source"] {
                    o["source"] = .string(String(src.prefix(PageRecord.maxSource)))
                    o["source_cut"] = .bool(src.count > PageRecord.maxSource)
                }
                if let t = page["title"] { o["title"] = t }
            } else {
                notes.append("the page's source couldn't be read within \(step)")
            }
            let frames: Int? = await Deadline.first(within: step) { @MainActor @Sendable [weak self] in
                await self?.hidden(PageRecord.frames, async: true).flatMap { Int($0) }
            }
            if case .object(var d)? = o["drawing"] {
                d["frames_half_second"] = frames.map { .number(Double($0)) } ?? .null
                o["drawing"] = .object(d)
            }
        }
        var d: [String: JSONValue] = [:]
        if case .object(let drawn)? = o["drawing"] { d = drawn }
        d["mac_locked"] = .bool(macLocked)
        d["display_asleep"] = .bool(displayAsleep)
        d["window_on_screen"] = .bool(false)  // Latchkey's own window never comes on screen (FR-467)
        o["drawing"] = .object(d)
        if let host = w.url?.host()?.lowercased() {
            let all = await Self.holding(w.configuration.websiteDataStore.httpCookieStore) ?? []
            let names = Set(all.filter { Self.covers($0.domain, host) }.map(\.name)).sorted()
            o["cookies"] = .array(names.map { .string($0) })
        }
        o["record"] = .array(
            record.events.map { e in
                (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(e))) ?? .null
            })
        o["record_dropped"] = .number(Double(record.dropped))
        if held == nil {
            let shot: PreparedImage? = await Deadline.first(within: step) { @MainActor @Sendable [weak self] in
                try? await self?.screenshot()
            }
            if let shot {
                o["screenshot"] = .object([
                    "mimeType": .string(shot.mimeType), "data": .string(shot.data.base64EncodedString()),
                ])
            } else {
                notes.append("no screenshot within \(step)")
            }
        }
        if !notes.isEmpty { o["notes"] = .array(notes.map { .string($0) }) }
        return .object(o)
    }

    /// Runs a script of the report's in the hidden world (`PageRecord.world`) and gives its value
    /// as text; nil when it failed. Not `evaluate`: nothing here waits on Claude's dialogs.
    private func hidden(_ code: String, async: Bool) async -> String? {
        guard let w = web else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let text: @MainActor @Sendable (Result<Any, any Error>) -> Void = { result in
                switch result {
                case .success(let v as String): c.resume(returning: v)
                case .success(let v as NSNumber): c.resume(returning: v.stringValue)
                default: c.resume(returning: nil)
                }
            }
            if async {
                w.callAsyncJavaScript(code, arguments: [:], in: nil, in: PageRecord.world) { text($0) }
            } else {
                w.evaluateJavaScript(code, in: nil, in: PageRecord.world) { text($0) }
            }
        }
    }

    // MARK: files the page saves (FR-475 to FR-477)

    nonisolated func webView(
        _ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload
    ) {
        MainActor.assumeIsolated { started(download) }
    }

    nonisolated func webView(
        _ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload
    ) {
        MainActor.assumeIsolated { started(download) }
    }

    /// FR-476: a save may come from the page itself or a frame of the page's own host, never a
    /// frame of another site in it (security review 2026-11-24).
    nonisolated static func isOwnFrame(main: Bool, frameHost: String, pageHost: String?) -> Bool {
        if main { return true }
        guard let pageHost, !pageHost.isEmpty else { return false }
        return frameHost.lowercased() == pageHost.lowercased()
    }

    /// FR-476: at most `savesPerAction` saves per action of Claude's (a page could start
    /// hundreds); the rest are refused and counted for Claude. Each action of Claude's starts a
    /// new count (`begin`).
    func takeSaveSlot() -> Bool {
        guard savesInWindow < Self.savesPerAction else {
            savesRefused += 1
            return false
        }
        savesInWindow += 1
        return true
    }

    private func started(_ download: WKDownload) {
        download.delegate = self
        saving[ObjectIdentifier(download)] = Saving(download: download, started: ContinuousClock.now)
        watchSize(download)
    }

    /// WebKit writes the save to a staging file of Latchkey's own in Downloads (a hidden name
    /// with a fresh UUID, so nobody else's file); it gets its own name when complete.
    nonisolated func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        MainActor.assumeIsolated {
            let id = ObjectIdentifier(download)
            guard saving[id] != nil else { return completionHandler(nil) }
            let name = BrowserDownloads.name(
                disposition: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition"),
                suggested: suggestedFilename, address: response.url?.absoluteString ?? "", type: response.mimeType)
            if response.expectedContentLength > Int64(BrowserDownloads.directLimit) {
                saving[id] = nil
                saved(
                    "The page offered \(Self.quoted(name)) (\(BrowserDownloads.size(Int(response.expectedContentLength)))) to save; Latchkey saves at most \(BrowserDownloads.size(BrowserDownloads.directLimit)), so nothing was saved."
                )
                return completionHandler(nil)
            }
            do {
                try FileManager.default.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)
            } catch {
                saving[id] = nil
                saved("Latchkey couldn't save \(Self.quoted(name)): \(downloadsFolder.path) can't be written.")
                return completionHandler(nil)
            }
            BrowserDownloads.sweepStaging(in: downloadsFolder, keeping: Set(saving.values.compactMap(\.staging)))
            let staging = BrowserDownloads.stagingFile(in: downloadsFolder)
            saving[id]?.staging = staging
            saving[id]?.name = name
            completionHandler(staging)
        }
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        MainActor.assumeIsolated {
            guard let r = saving.removeValue(forKey: ObjectIdentifier(download)), let staging = r.staging else {
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? Int) ?? 0
            do {
                // To a free name, never over another file (FR-438), marked as from the web.
                let file = try BrowserDownloads.move(
                    staging, name: r.name, from: download.originalRequest?.url?.absoluteString ?? "",
                    in: downloadsFolder)
                saved(
                    "Saved \(Self.quoted(file.lastPathComponent)) (\(BrowserDownloads.size(size))), which the page offered to save, to \(file.path). Read it with files_read and that path; it is marked as downloaded from the web, as Safari marks downloads."
                )
            } catch {
                try? FileManager.default.removeItem(at: staging)
                saved(
                    "The page's file \(Self.quoted(r.name)) arrived but couldn't be put in \(downloadsFolder.path); nothing was saved."
                )
            }
        }
    }

    nonisolated func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        MainActor.assumeIsolated {
            guard let r = saving.removeValue(forKey: ObjectIdentifier(download)) else { return }
            if let f = r.staging { try? FileManager.default.removeItem(at: f) }
            saved(
                "The page's file \(r.name.isEmpty ? "" : Self.quoted(r.name) + " ")couldn't be saved (\(error.localizedDescription)). Nothing was saved."
            )
        }
    }

    /// Stops a save and removes its staging file, also once WebKit has stopped writing it.
    private static func stop(_ r: Saving) {
        let staging = r.staging
        r.download.cancel { _ in
            if let staging { try? FileManager.default.removeItem(at: staging) }
        }
        if let staging { try? FileManager.default.removeItem(at: staging) }
    }

    /// Stops a save that grows past the most Latchkey saves (a stream with no length given), or
    /// the saves running together past it, and one still running after 10 minutes
    /// (Constitution II: nothing runs without a deadline).
    private func watchSize(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        Task { @MainActor [weak self] in
            while let self, let r = self.saving[id] {
                let total = self.saving.values.reduce(Int64(0)) { $0 + $1.download.progress.completedUnitCount }
                let tooBig = total > Int64(BrowserDownloads.directLimit)
                let tooLong = ContinuousClock.now - r.started > .seconds(600)
                if tooBig || tooLong {
                    self.saving[id] = nil
                    Self.stop(r)
                    self.saved(
                        "The page's file\(r.name.isEmpty ? "" : " " + Self.quoted(r.name)) was stopped: "
                            + (tooBig
                                ? "the page's saves grew past \(BrowserDownloads.size(BrowserDownloads.directLimit)), the most Latchkey saves."
                                : "it was still arriving after 10 minutes.") + " Nothing was saved.")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Waits, up to `atMost`, for the saves started during Claude's last action to end, so the
    /// answer can say what was saved (FR-477); a save still running is told as such.
    func savesEnded(atMost: Duration = .seconds(20)) async {
        let deadline = ContinuousClock.now + atMost
        while saving.values.contains(where: { $0.started >= actionBegan }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Whether a response is sent to be saved (`Content-Disposition: attachment`).
    nonisolated static func isAttachment(_ response: URLResponse) -> Bool {
        guard let d = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") else {
            return false
        }
        return d.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment")
    }

    /// An address for a note: a blob's or data address says only what it is; a web address is
    /// quoted and short (the website's text, not Latchkey's).
    nonisolated static func shown(_ url: URL?) -> String {
        guard let url else { return "no address" }
        switch url.scheme?.lowercased() {
        case "blob": return "a file the page made"
        case "data": return "a file in the page"
        default: return "the address " + quoted(url.absoluteString)
        }
    }

    /// A name or address the website chose, in Latchkey's notes: quoted, one line, at most 80
    /// characters (security review 2026-11-24: a file name could read as Latchkey talking).
    nonisolated static func quoted(_ text: String) -> String {
        let line = text.map { $0.isNewline || $0 == "«" || $0 == "»" ? " " : $0 }
        let short = line.count > 80 ? String(line.prefix(79)) + "…" : String(line)
        return "«" + short + "»"
    }

    private func saved(_ line: String) {
        if savedNotes.count < 5 { savedNotes.append(line) }
    }

    /// The notes of saves since the last answer (FR-477), told once: what was saved, what was
    /// refused, and what is still arriving.
    func takeSaved() -> [String] {
        defer {
            savedNotes = []
            savesRefused = 0
        }
        var out = savedNotes
        if savesRefused > 0 {
            out.append(
                "The page tried to save \(savesRefused) more file\(savesRefused == 1 ? "" : "s") in one action of Claude's; Latchkey saves at most \(Self.savesPerAction) per action, so those weren't saved."
            )
        }
        for r in saving.values {
            let got = Int(r.download.progress.completedUnitCount)
            out.append(
                "Still saving\(r.name.isEmpty ? "" : " " + Self.quoted(r.name)) (\(BrowserDownloads.size(got)) so far); a later answer says when it is in Downloads."
            )
        }
        return out
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
            record.loading(navigationAction.request, mainFrame: navigationAction.targetFrame?.isMainFrame ?? true)
            let url = navigationAction.request.url
            // FR-475, FR-476: a link the page marks to save (`download`, often a blob of its own)
            // is saved, as Safari saves it, and the page stays; without this WebKit went to the
            // file's address, which ended Claude's script (problem report 2026-11-24).
            if navigationAction.shouldPerformDownload {
                // Only the page's own frames, not another site's frame in it (security review).
                let source = navigationAction.sourceFrame
                let ownFrame = Self.isOwnFrame(
                    main: source.isMainFrame, frameHost: source.securityOrigin.host, pageHost: webView.url?.host())
                if !mayDownload || !ownFrame {
                    saved(
                        "The page tried to save a file (\(Self.shown(url))) "
                            + (ownFrame ? "on its own, not during Claude's action" : "from a frame of another site")
                            + ": nothing was saved, and the page stayed.")
                    decisionHandler(.cancel)
                } else if takeSaveSlot() {
                    decisionHandler(.download)
                } else {
                    decisionHandler(.cancel)
                }
                return
            }
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
            record.answered(navigationResponse.response, mainFrame: navigationResponse.isForMainFrame)
            let type = navigationResponse.response.mimeType ?? ""
            // FR-475: during Claude's own action, a file the server sends to save (an attachment)
            // or that no page shows (an archive) is saved, as Safari saves it; a PDF stays a page
            // that is a file (FR-452), as Safari shows it.
            if navigationResponse.isForMainFrame, mayDownload, type != "application/pdf",
                !navigationResponse.canShowMIMEType || Self.isAttachment(navigationResponse.response)
            {
                if takeSaveSlot() {
                    loadBecameSave = true
                    decisionHandler(.download)
                } else {
                    decisionHandler(.cancel)
                }
                return
            }
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
        // A load the response check turned into a save (FR-475) ends with 102: the page stayed.
        if loadBecameSave, e.code == 102 {
            loadBecameSave = false
            done(true)
            return
        }
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
        actionBegan = ContinuousClock.now
        savesInWindow = 0
    }

    /// Claude's action ended: its answers in advance count for a moment more (FR-450).
    private func end() {
        acting = false
        presetUntil = dialogAnswer.given ? ContinuousClock.now + presetWindow : nil
        actedUntil = ContinuousClock.now + downloadWindow
    }

    /// FR-476: whether a save the page starts now is Claude's: during Claude's own action, or the
    /// moment after it. A page saves nothing on its own (security: a page could fill Downloads).
    private var mayDownload: Bool {
        acting || actedUntil.map { ContinuousClock.now < $0 } == true
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
        actedUntil = nil  // FR-476: a page opened isn't Claude's action on the last one
        _ = await view()
        await ready()  // FR-1353: Latchkey's kept sign-ins are in the store first
        await takeSafarisCookies(for: u.host())  // FR-441: Safari's copy wins
        try await navigate { $0.load(URLRequest(url: u)) }
        var p = try await page(offset: 0)
        // A slow site still loading after the limit answered with an empty page and no word of
        // why (bugzilla.samba.org, regression run 2026-11-16).
        if file == nil, p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, web?.isLoading == true {
            p.text =
                "(The page is still loading after \(Self.loadLimit.components.seconds) seconds: read it again in a moment with browser_look and this page's name.)"
        }
        return p
    }

    /// A page from text, at `base` (tests: the real WebKit view, no network).
    func open(html: String, base: URL) async throws -> PageScripts.Page {
        actedUntil = nil  // FR-476: a page opened isn't Claude's action on the last one
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
        // FR-478: a real mouse's click; the browser itself follows a link or sends a form.
        try await active { _ = try await self.mouseClick(ref, w) }
        await settle(from: before)
        return try await page(offset: 0)
    }

    func type(_ ref: String, text: String, submit: Bool, answer: DialogAnswer = DialogAnswer()) async throws
        -> PageScripts.Page
    {
        begin(answer)
        defer { end() }
        guard let w = web else { throw SafariBrowser.Failure.noWindow }
        let before = w.url?.absoluteString
        // Typed into a password or code field: kept to be blanked in a problem report (spec 014
        // FR-1448), asked in the hidden world before typing.
        // Not while the page holds a dialog or is a file (the script would wait, and typing must
        // fail at once as before), and at most 2 s. Fails closed: anything but "no" keeps the
        // text to blank (security review 2026-11-25).
        if held == nil, file == nil {
            let answer: String? = await Deadline.first(within: .seconds(2)) { @MainActor @Sendable [weak self] in
                await self?.hidden(PageRecord.secretField(ref), async: false)
            }
            if answer != "no" { record.typedSecret(text) }
        } else {
            record.typedSecret(text)
        }
        let at = try await spot(ref)
        if at.kind == "select" || at.refuse == "colour" || at.dateField == true {
            // FR-484: a list takes the option as its menu's choice gives it, a colour or date
            // field the value as its panel or calendar gives it (input, change).
            try check(
                (try await script(PageScripts.type(ref, text: text, submit: false))).split(separator: "\n").first.map(
                    String.init) ?? "", ref: ref, option: text)
            return try await page(offset: 0)
        }
        // FR-480: click the field, Select All when it holds something, then a key per character;
        // submit presses Enter.
        try await active {
            try await self.focusField(ref, at, w)
            if at.filled == true {
                _ = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: w, from: nil)
                if text.isEmpty, let back = RealInput.stroke(for: try PageScripts.Key("Backspace")) {
                    await RealInput.press(back, in: w)
                }
            }
            _ = await RealInput.type(text, in: w)
            if submit, let enter = RealInput.stroke(for: try PageScripts.Key("Enter")) {
                await RealInput.press(enter, in: w)
            }
        }
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

    /// FR-481: real keys, in the field Claude names (clicked) or a button or link it names (the
    /// focus moved there as Tab would), else where the focus is. Answers the keys pressed (JSON)
    /// and the page.
    func press(_ keys: [PageScripts.Key], ref: String?, answer: DialogAnswer = DialogAnswer()) async throws
        -> (detail: String, page: PageScripts.Page)
    {
        begin(answer)
        defer { end() }
        guard let w = web else { throw SafariBrowser.Failure.noWindow }
        let before = w.url?.absoluteString
        var strokes: [(PageScripts.Key, RealInput.Stroke)] = []
        for k in keys {
            let name = Self.keyName(k)
            // They would use the Owner's clipboard (Constitution IV).
            if k.meta || k.ctrl, ["c", "x", "v"].contains(k.key.lowercased()) {
                throw SafariBrowser.Failure.failed(
                    "\(name) isn't pressed: copy, cut and paste would use the owner's clipboard. Type the text with type instead."
                )
            }
            guard let s = RealInput.stroke(for: k) else {
                throw SafariBrowser.Failure.failed("\(name) isn't a key of a keyboard Latchkey can press.")
            }
            strokes.append((k, s))
        }
        var did: [String] = []
        try await active {
            if let ref {
                let at = try await self.spot(ref)
                try await self.focusField(ref, at, w)
            }
            for (k, s) in strokes {
                // FR-484: a one-line list's menu would hold Latchkey up until answered.
                let opensMenu = ["ArrowUp", "ArrowDown", " ", "Enter"].contains(k.key)
                if opensMenu, await RealInput.evaluate(w, RealInput.focused) == "select" {
                    throw SafariBrowser.Failure.failed(
                        "\(Self.keyName(k)) isn't pressed in a list: it would open the list's menu. Choose with select instead."
                    )
                }
                await RealInput.press(s, in: w)
                // Cmd+A selects all, as the Edit menu does, unless the page took the key.
                if k.meta, k.key.lowercased() == "a", !(await RealInput.lastKeyTaken(w)) {
                    _ = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: w, from: nil)
                }
                did.append(Self.keyName(k))
            }
        }
        await settle(from: before)
        let focus = await RealInput.evaluate(w, RealInput.focused) ?? ""
        let line =
            "pressed " + did.joined(separator: ", ")
            + (focus.isEmpty ? "; nothing on the page has the focus" : "; the focus is on \(focus)")
        let data = (try? JSONEncoder().encode([line])) ?? Data("[]".utf8)
        return (String(decoding: data, as: UTF8.self), try await page(offset: 0))
    }

    static func keyName(_ k: PageScripts.Key) -> String {
        (k.meta ? "cmd+" : "") + (k.ctrl ? "ctrl+" : "") + (k.alt ? "alt+" : "") + (k.shift ? "shift+" : "")
            + (k.key == " " ? "Space" : k.key)
    }

    /// FR-482: the view's own pointer moves onto the element; answers how many more things show.
    func hover(_ ref: String) async throws -> (detail: String, page: PageScripts.Page) {
        begin(DialogAnswer())
        defer { end() }
        guard let w = web else { throw SafariBrowser.Failure.noWindow }
        let shown =
            "(function () { var n = 0; document.querySelectorAll('body *').forEach(function (x) { if (x.getClientRects().length) n++; }); return String(n); })()"
        let before = Int(await RealInput.evaluate(w, shown) ?? "") ?? 0
        try await active {
            let at = try await self.spot(ref)
            if at.hidden == true { throw SafariBrowser.Failure.failed(Self.notShown(ref, at)) }
            guard let x = at.x, let y = at.y else {
                throw SafariBrowser.Failure.failed("The page didn't answer as expected.")
            }
            await RealInput.move(to: RealInput.windowPoint(x, y, in: w), in: w)
            try? await Task.sleep(for: .milliseconds(100))
        }
        let after = Int(await RealInput.evaluate(w, shown) ?? "") ?? 0
        return (String(max(after - before, 0)), try await page(offset: 0))
    }

    /// Spec 013 FR-1377: logins_fill's typing, as a keyboard's. The sign-in world checks the
    /// field as `fillField` does and names the fields to type into; each gets a real click, and
    /// before every character the focus is checked to be still on it (or, for a code, on the
    /// page's next code box after it), else typing stops. The secret goes only as key events to
    /// this page's view, and is never logged. Answers what `fillField` answers (JSON), and
    /// `{ step: "covered", is }` when something is drawn over the field.
    func fillReal(ref: String, kind: String, value: String, host: String) async throws -> String {
        begin(DialogAnswer())
        defer { end() }
        guard let w = web else { throw SafariBrowser.Failure.noWindow }
        struct Plan: Decodable {
            struct Field: Decodable {
                var ref: String
                var count: Int
            }
            var step: String
            var fields: [Field]?
            var follow: Bool?
            var ref: String?
        }
        func run(_ code: String) async throws -> Plan? {
            let text = try SafariBrowser.detail(try await script(code, world: Self.signInWorld), ref: ref)
            return try? JSONDecoder().decode(Plan.self, from: Data(text.utf8))
        }
        let unheld = #"{"step":"unheld"}"#
        let planText = try SafariBrowser.detail(
            try await script(
                PageScripts.fillPlan(ref: ref, kind: kind, length: value.count, host: host), world: Self.signInWorld),
            ref: ref)
        guard let plan = try? JSONDecoder().decode(Plan.self, from: Data(planText.utf8)) else { return unheld }
        guard plan.step == "plan", let fields = plan.fields, !fields.isEmpty else { return planText }
        let follow = plan.follow == true
        let chars = Array(value)
        var covered: String?
        let typed: Bool = try await active {
            var from = 0
            for f in fields {
                let part = chars[min(from, chars.count)..<min(from + f.count, chars.count)]
                from += f.count
                let at = try await self.spot(f.ref)
                // Drawn over: the click would land on something else, which must never get a
                // secret.
                if let c = at.covered {
                    covered = c
                    return false
                }
                guard at.refuse == nil, at.hidden != true, let x = at.x, let y = at.y else { return false }
                await RealInput.click(at: RealInput.windowPoint(x, y, in: w), in: w)
                var current = f.ref
                guard try await run(PageScripts.fillFocus(ref: current, host: host, follow: false))?.step == "same"
                else { return false }
                if at.filled == true, let back = RealInput.stroke(for: try PageScripts.Key("Backspace")) {
                    _ = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: w, from: nil)
                    await RealInput.press(back, in: w)
                }
                for ch in part {
                    // The focus is checked before every character: a page that moved it elsewhere
                    // gets nothing more (FR-1377).
                    let now = try await run(PageScripts.fillFocus(ref: current, host: host, follow: follow))
                    if now?.step == "next", let next = now?.ref {
                        current = next
                    } else if now?.step != "same" {
                        return false
                    }
                    if let k = RealInput.stroke(for: ch) {
                        await RealInput.press(k, in: w)
                    } else {
                        await RealInput.insert(String(ch), in: w)
                    }
                }
            }
            return true
        }
        if let covered {
            let data = (try? JSONEncoder().encode(["step": "covered", "is": covered])) ?? Data(unheld.utf8)
            return String(decoding: data, as: UTF8.self)
        }
        guard typed else { return unheld }
        let refs = fields.map(\.ref)
        let held = try await script(PageScripts.fillHeld(refs: refs, value: value, host: host), world: Self.signInWorld)
        let heldText = try SafariBrowser.detail(held, ref: ref)
        if heldText.contains("\"filled\"") || refs.count < 2 { return heldText }
        // Code boxes that didn't take the code key by key: pasted whole into the first.
        return try SafariBrowser.detail(
            try await script(PageScripts.fillPaste(refs: refs, value: value, host: host), world: Self.signInWorld),
            ref: ref)
    }

    // MARK: the real mouse and keyboard (FR-478 to FR-485)

    /// Runs `work` with the page counted as the focused front window (FR-483), and after it, as a
    /// window behind another app's again, whatever happened.
    private func active<T>(_ work: () async throws -> T) async rethrows -> T {
        let window = holderWindow as? HolderWindow
        window?.active = true
        defer { window?.active = false }
        return try await work()
    }

    /// Where the element is, as the input world answers it (scrolled into view first).
    private func spot(_ ref: String) async throws -> RealInput.Spot {
        let json = try await script(RealInput.spot(ref), world: RealInput.world)
        guard let s = try? JSONDecoder().decode(RealInput.Spot.self, from: Data(json.utf8)) else {
            throw SafariBrowser.Failure.failed("The page didn't answer as expected.")
        }
        if s.missing == true { throw SafariBrowser.Failure.elementMissing(ref) }
        return s
    }

    static func notShown(_ ref: String, _ at: RealInput.Spot) -> String {
        at.kind == "input:file"
            ? "\(ref) is a file field the page doesn't show: give it files with upload."
            : "\(ref) doesn't show on the page, so a mouse can't reach it: if it is in a closed menu, click the menu first (its name is in the page's list); else read the page again with browser_look."
    }

    /// FR-478, FR-479, FR-484: a real click on the element, after the checks; what was drawn over
    /// it, if anything, goes into the answer.
    @discardableResult
    private func mouseClick(_ ref: String, _ w: WKWebView, spot given: RealInput.Spot? = nil) async throws
        -> RealInput.Spot
    {
        let at: RealInput.Spot
        if let given { at = given } else { at = try await spot(ref) }
        switch at.refuse {
        case "list"?:
            throw SafariBrowser.Failure.failed(
                "\(ref) is a list: choose its option with select (a click would open its menu, which needs the screen)."
            )
        case "colour"?:
            throw SafariBrowser.Failure.failed(
                "\(ref) is a colour field: type the colour (like #336699) into it with type; a click would open the colour panel on the owner's screen."
            )
        case "date"?:
            throw SafariBrowser.Failure.failed(
                "\(ref) is a date or time field: type the date into it with type (a click would open its calendar, which needs the screen)."
            )
        default: break
        }
        if at.hidden == true { throw SafariBrowser.Failure.failed(Self.notShown(ref, at)) }
        guard let x = at.x, let y = at.y else {
            throw SafariBrowser.Failure.failed("The page didn't answer as expected.")
        }
        if let c = at.covered { inputNote("The click on \(ref) landed on what is drawn over it there: \(c).") }
        await RealInput.click(at: RealInput.windowPoint(x, y, in: w), in: w)
        return at
    }

    /// The focus into a field as a person puts it there: a click; a date or time field (whose
    /// calendar needs the screen) and a button or link get it as Tab gives it.
    private func focusField(_ ref: String, _ at: RealInput.Spot, _ w: WKWebView) async throws {
        if at.field == true, at.refuse == nil {
            try await mouseClick(ref, w, spot: at)
        } else {
            try check(try await script(RealInput.focus(ref), world: RealInput.world), ref: ref)
        }
    }

    /// What Latchkey's mouse did that Claude should know, told with the next answer (FR-479); at
    /// most 5, as dialogs.
    private var inputNotes: [String] = []
    private func inputNote(_ s: String) { if inputNotes.count < 5 { inputNotes.append(s) } }
    func takeInputNotes() -> [String] {
        defer { inputNotes = [] }
        return inputNotes
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
