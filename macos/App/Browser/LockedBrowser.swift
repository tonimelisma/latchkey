import AppKit
import WebKit

/// The browser used while the Mac is locked (spec 005 FR-420 to FR-422, Toni 2026-11-02). Safari
/// stops answering scripts while the Mac is locked (seen live 2026-11-01), but a WebKit view of
/// Latchkey's own keeps working, off-screen (checked live, locked: it loaded, ran scripts,
/// navigated, went back, and took a picture). It starts with Safari's cookies, read from Safari's
/// file at that moment into a store that lives only in memory, so the Owner's signed-in sites
/// work; it is discarded, cookies and all, as soon as the Mac is unlocked, when Safari takes
/// over again. It runs the same page scripts as Safari (`PageScripts`), so Claude's answers look
/// the same; it has one page and no tabs.
@MainActor
final class LockedBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var web: WKWebView?
    /// What the page's own dialogs said since the last answer (alert, confirm, prompt), told
    /// to Claude with the next page; a confirm is answered Cancel and a prompt with nothing, so a
    /// page never gets a yes from Latchkey on its own (2026-11-02).
    private(set) var dialogs: [String] = []
    /// Claude's answers for the action that runs (FR-432), set with `acting`; Cancel and no
    /// text otherwise.
    private var dialogAnswer = DialogAnswer()
    private var droppedDialogs = 0
    /// True while Claude's own click, typing, or script runs: only then may the page open a new
    /// window (security review 2026-11-02: a page's own pop-up can't take Claude's page away).
    private var acting = false
    private var finished: CheckedContinuation<Bool, Never>?
    /// Where a load failed, for the answer.
    private var failure: String?

    static let loadLimit: Duration = .seconds(20)

    var isOpen: Bool { web != nil }

    /// The view, made on first use with Safari's cookies as they are now.
    private func view() async -> WKWebView {
        if let web { return web }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()  // memory only: nothing written to disk
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        w.navigationDelegate = self
        w.uiDelegate = self
        // Sites see Safari, as they do in the Owner's Safari: some refuse an app's own web view
        // (Google's sign-in, for one).
        w.customUserAgent = Self.safariUserAgent
        let store = config.websiteDataStore.httpCookieStore
        let data = (try? Data(contentsOf: SafariCookies.file)) ?? Data()
        for cookie in SafariCookies.parse(data).compactMap(SafariCookies.httpCookie) {
            await store.setCookie(cookie)
        }
        web = w
        return w
    }

    /// Safari's own user agent, built from its installed version.
    static let safariUserAgent: String = {
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
            let ok = acting && dialogAnswer.confirm
            note("confirm", message, ok ? "ok" : "cancel")
            completionHandler(ok)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        MainActor.assumeIsolated {
            let text = acting ? dialogAnswer.text : nil
            note("prompt", prompt, text ?? "")
            completionHandler(text)
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

    /// Drops the page and its cookies (the Mac was unlocked, or Claude closed it).
    func discard() {
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.uiDelegate = nil
        web = nil
        dialogs = []
        finished?.resume(returning: false)
        finished = nil
    }

    // MARK: navigation

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { done(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { failed(error) }
    }

    /// "Cancelled" (-999) is a page replaced by the next one, or back served from memory (seen live
    /// 2026-11-02: back said -999 and showed the page): not a failure.
    private func failed(_ error: any Error) {
        if (error as NSError).code == NSURLErrorCancelled {
            done(true)
            return
        }
        failure = error.localizedDescription
        done(false)
    }

    nonisolated func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        MainActor.assumeIsolated { failed(error) }
    }

    private func done(_ ok: Bool) {
        finished?.resume(returning: ok)
        finished = nil
    }

    /// Runs `start`, then waits for the page it loads to finish, at most `loadLimit`.
    private func navigate(_ start: (WKWebView) -> Void) async throws {
        let w = await view()
        failure = nil
        finished?.resume(returning: false)
        let before = w.url
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            finished = c
            start(w)
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

    /// After a click or a form: waits up to 5 s for the address to change and the page to finish.
    private func settle(from address: String?) async {
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            guard let w = web else { return }
            if w.url?.absoluteString != address, !w.isLoading { return }
        }
    }

    private func script(_ code: String) async throws -> String {
        let w = await view()
        do {
            let value = try await w.evaluateJavaScript(code)
            if let s = value as? String { return s }
            if let n = value as? NSNumber { return n.stringValue }
            return value.map { "\($0)" } ?? ""
        } catch {
            throw SafariBrowser.Failure.failed("The page's script failed: \(error.localizedDescription)")
        }
    }

    private func page(offset: Int) async throws -> PageScripts.Page {
        do { return try PageScripts.decode(try await script(PageScripts.read(offset: offset))) } catch is DecodingError
        {
            throw SafariBrowser.Failure.failed("The page didn't answer as expected.")
        }
    }

    // MARK: what Claude does

    func open(_ url: String) async throws -> PageScripts.Page {
        let address = try SafariBrowser.normalize(url)
        guard let u = URL(string: address) else { throw SafariBrowser.Failure.failed("That address isn't valid.") }
        try await navigate { $0.load(URLRequest(url: u)) }
        return try await page(offset: 0)
    }

    /// A page from text, at `base` (tests: the real WebKit view, no network).
    func open(html: String, base: URL) async throws -> PageScripts.Page {
        try await navigate { $0.loadHTMLString(html, baseURL: base) }
        return try await page(offset: 0)
    }

    func read(offset: Int) async throws -> PageScripts.Page {
        guard web != nil else { throw SafariBrowser.Failure.noWindow }
        return try await page(offset: offset)
    }

    func click(_ ref: String, answer: DialogAnswer = DialogAnswer()) async throws -> PageScripts.Page {
        acting = true
        dialogAnswer = answer
        defer {
            acting = false
            dialogAnswer = DialogAnswer()
        }
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
        acting = true
        dialogAnswer = answer
        defer {
            acting = false
            dialogAnswer = DialogAnswer()
        }
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
            try await navigate { _ = $0.goBack() }
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
        acting = true
        dialogAnswer = answer
        defer {
            acting = false
            dialogAnswer = DialogAnswer()
        }
        guard let w = web else { throw SafariBrowser.Failure.noWindow }
        let before = w.url?.absoluteString
        do {
            // Given to WebKit as it is: a page's Content Security Policy forbids the eval that
            // Safari's wrapper uses (seen live on GitHub), but not a script the app itself runs.
            let value = try await w.evaluateJavaScript(code)
            if let s = value as? String { return s }
            if let v = value, JSONSerialization.isValidJSONObject(v),
                let data = try? JSONSerialization.data(withJSONObject: v)
            {
                return String(decoding: data, as: UTF8.self)
            }
            return value.map { "\($0)" } ?? "undefined"
        } catch {
            // A script that sends the page elsewhere ends with the page it ran in (seen live).
            await settle(from: before)
            if let now = w.url?.absoluteString, now != before { return "The page went to \(now)." }
            throw error
        }
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
