import Foundation

/// The Owner's Safari, driven through Apple Events in a window of Claude's own (spec 005 plan
/// D2). Remembers that window's id; never touches other windows.
actor SafariBrowser {
    enum Failure: Error, Equatable {
        case noWindow
        case javaScriptOff
        case elementMissing(String)
        case noOption(String)
        case failed(String)
    }

    let scripts: any ScriptRunner
    private var window: String?

    init(scripts: any ScriptRunner) { self.scripts = scripts }

    /// Loads `url` in Claude's window (a new tab if asked), making the window if needed.
    func open(_ url: String, newTab: Bool) async throws -> PageScripts.Page {
        let address = try Self.normalize(url)
        let before = try? await stamp()
        let id = try await call(Script.open, [address, window ?? "", newTab ? "yes" : "no"])
        window = id
        try await settle(after: before, expectNavigation: true)
        return try await read(offset: 0)
    }

    func read(offset: Int) async throws -> PageScripts.Page {
        do {
            return try PageScripts.decode(try await javaScript(PageScripts.read(offset: offset)))
        } catch is DecodingError {
            throw Failure.failed("Safari reported a problem: the page didn't answer as expected.")
        }
    }

    func click(_ ref: String) async throws -> PageScripts.Page {
        let before = try? await stamp()
        try check(try await javaScript(PageScripts.click(ref)), ref: ref)
        try await settle(after: before, expectNavigation: false)
        return try await read(offset: 0)
    }

    func type(_ ref: String, text: String, submit: Bool) async throws -> PageScripts.Page {
        let before = try? await stamp()
        try check(try await javaScript(PageScripts.type(ref, text: text, submit: submit)), ref: ref, option: text)
        if submit { try await settle(after: before, expectNavigation: false) }
        return try await read(offset: 0)
    }

    func back() async throws -> PageScripts.Page {
        let before = try? await stamp()
        _ = try await javaScript(PageScripts.back)
        try await settle(after: before, expectNavigation: true)
        return try await read(offset: 0)
    }

    func run(_ code: String) async throws -> String { try await javaScript(PageScripts.custom(code)) }

    /// The tabs of Claude's window (index, title, address) and which is showing; `select`
    /// switches to a tab first.
    func tabs(select: Int?) async throws -> (current: Int, tabs: [(Int, String, String)]) {
        guard let window else { throw Failure.noWindow }
        let out = try await call(Script.tabs, [window, select.map(String.init) ?? ""])
        var lines = out.split(separator: "\n", omittingEmptySubsequences: true)
        let current = lines.isEmpty ? 1 : Int(lines.removeFirst()) ?? 1
        let tabs = lines.map { line -> (Int, String, String) in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return (Int(f[0]) ?? 0, f.count > 1 ? f[1] : "", f.count > 2 ? f[2] : "")
        }
        return (current, tabs)
    }

    /// For setup: opens a blank window, runs one line of script, closes it.
    func probe() async throws {
        _ = try await call(Script.probe, [])
    }

    // MARK: helpers

    /// FR-409: the address Claude asks to open, as Safari gets it: http and https only (and
    /// about:blank); one without a scheme gets https. Everything else is refused: javascript:
    /// would run script in the signed-in page even at Read only, file: would read local files,
    /// and data:, blob:, and app schemes have no business here (security scan, 2026-10-24).
    /// Tabs and line breaks are removed first, as browsers do, so "java\nscript:" can't slip by.
    static func normalize(_ url: String) throws -> String {
        let u = url.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.controlCharacters))
        if u.lowercased() == "about:blank" { return "about:blank" }
        var address = u
        if !hasScheme(u) { address = "https://" + u }
        guard let c = URLComponents(string: address), let scheme = c.scheme?.lowercased(),
            ["http", "https"].contains(scheme), c.host?.isEmpty == false,
            address.dropFirst(scheme.count).hasPrefix("://")
        else {
            let shown = u.count > 80 ? String(u.prefix(79)) + "…" : u
            throw Failure.failed(
                "Latchkey's browser opens only web addresses (http:// or https://); \"\(shown)\" wasn't opened.")
        }
        return address
    }

    /// Whether the text starts with a scheme ("name:"), not a host and port ("localhost:3000").
    private static func hasScheme(_ u: String) -> Bool {
        guard let colon = u.firstIndex(of: ":") else { return false }
        let name = u[..<colon]
        guard let first = name.first, first.isASCII, first.isLetter,
            name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return false }
        let rest = u[u.index(after: colon)...]
        let port = rest.prefix { $0.isASCII && $0.isNumber }
        let afterPort = rest.dropFirst(port.count)
        let isPort = !port.isEmpty && (afterPort.isEmpty || "/?#".contains(afterPort.first!))
        return !isPort
    }

    private func javaScript(_ code: String) async throws -> String {
        guard let window else { throw Failure.noWindow }
        return try await call(Script.javaScript, [window, code])
    }

    /// The current document's identity: each page load has its own start time, even at the same
    /// address. Answers "origin|readyState|address".
    private func stamp() async throws -> PageScripts.Stamp {
        PageScripts.Stamp(try await javaScript(PageScripts.stamp))
    }

    /// Waits until a new page has finished loading, at most 15 s (plan D3). The old page (or a new
    /// window's blank page) also reads "complete", so finished means a different document. An
    /// action that may not navigate (a click that only changes the page) counts as finished when
    /// no new page has started after 1.5 s.
    private func settle(after before: PageScripts.Stamp?, expectNavigation: Bool) async throws {
        let start = ContinuousClock.now
        while ContinuousClock.now < start + .seconds(15) {
            try await Task.sleep(for: .milliseconds(250))
            guard let now = try? await stamp() else { continue }
            let newDocument = before.map { $0.origin != now.origin } ?? (now.address != "about:blank")
            if now.complete, newDocument { return }
            if now.complete, !expectNavigation, ContinuousClock.now > start + .milliseconds(1500) { return }
        }
    }

    private func check(_ answer: String, ref: String, option: String = "") throws {
        switch answer {
        case "ok": return
        case "missing": throw Failure.elementMissing(ref)
        case "nooption": throw Failure.noOption(option)
        default: throw Failure.failed("The page answered: \(answer)")
        }
    }

    private func call(_ script: String, _ args: [String]) async throws -> String {
        do { return try await scripts.run(script, args) } catch ScriptError.failed(let message) {
            if message.contains("LATCHKEY_NO_WINDOW") {
                window = nil
                throw Failure.noWindow
            }
            if message.contains("Allow JavaScript from Apple Events") { throw Failure.javaScriptOff }
            throw Failure.failed("Safari reported a problem: \(message)")
        }
    }

    enum Script {
        /// argv: url, Claude's window id (or empty), "yes" for a new tab.
        static let open = """
            on run argv
            set theURL to item 1 of argv
            set winID to item 2 of argv
            set newTab to item 3 of argv
            tell application "Safari"
            if winID is not "" then
            if (exists window id (winID as integer)) then
            set w to window id (winID as integer)
            if newTab is "yes" then
            set t to make new tab at end of tabs of w with properties {URL:theURL}
            set current tab of w to t
            else
            set URL of current tab of w to theURL
            end if
            return winID
            end if
            end if
            make new document with properties {URL:theURL}
            return (id of front window) as text
            end tell
            end run
            """
        /// argv: window id, script.
        static let javaScript = """
            on run argv
            set winID to (item 1 of argv) as integer
            tell application "Safari"
            if not (exists window id winID) then error "LATCHKEY_NO_WINDOW"
            return do JavaScript (item 2 of argv) in current tab of window id winID
            end tell
            end run
            """
        /// argv: window id, tab to select (or empty).
        static let tabs = """
            on run argv
            set winID to (item 1 of argv) as integer
            set sel to item 2 of argv
            set sep to character id 9
            tell application "Safari"
            if not (exists window id winID) then error "LATCHKEY_NO_WINDOW"
            set w to window id winID
            if sel is not "" then set current tab of w to tab (sel as integer) of w
            set out to ((index of current tab of w) as text) & linefeed
            repeat with t in tabs of w
            set out to out & (index of t) & sep & (name of t) & sep & (URL of t) & linefeed
            end repeat
            return out
            end tell
            end run
            """
        static let probe = """
            on run argv
            tell application "Safari"
            make new document with properties {URL:"about:blank"}
            set w to front window
            try
            do JavaScript "1" in current tab of w
            on error message
            close w
            error message
            end try
            close w
            end tell
            end run
            """
    }
}
