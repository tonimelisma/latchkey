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
final class LockedBrowser: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
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
        let store = config.websiteDataStore.httpCookieStore
        let data = (try? Data(contentsOf: SafariCookies.file)) ?? Data()
        for cookie in SafariCookies.parse(data).compactMap(SafariCookies.httpCookie) {
            await store.setCookie(cookie)
        }
        web = w
        return w
    }

    /// Drops the page and its cookies (the Mac was unlocked, or Claude closed it).
    func discard() {
        web?.stopLoading()
        web?.navigationDelegate = nil
        web = nil
        finished?.resume(returning: false)
        finished = nil
    }

    // MARK: navigation

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { done(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated {
            failure = error.localizedDescription
            done(false)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        MainActor.assumeIsolated {
            failure = error.localizedDescription
            done(false)
        }
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
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            finished = c
            start(w)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.loadLimit)
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

    func read(offset: Int) async throws -> PageScripts.Page {
        guard web != nil else { throw SafariBrowser.Failure.noWindow }
        return try await page(offset: offset)
    }

    func click(_ ref: String) async throws -> PageScripts.Page {
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

    func type(_ ref: String, text: String, submit: Bool) async throws -> PageScripts.Page {
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
        guard w.canGoBack else { throw SafariBrowser.Failure.failed("There's no page to go back to.") }
        try await navigate { _ = $0.goBack() }
        return try await page(offset: 0)
    }

    func run(_ code: String) async throws -> String {
        guard let w = web else { throw SafariBrowser.Failure.noWindow }
        let before = w.url?.absoluteString
        do { return try await script(PageScripts.custom(code)) } catch {
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
