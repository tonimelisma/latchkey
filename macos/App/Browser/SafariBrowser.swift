import AppKit

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
    private var window: String? { didSet { remember() } }
    /// When Claude last used its window (spec 005 FR-411).
    private var lastUse = Date() { didSet { remember() } }
    /// How long a page may take to load (plan D3).
    private let settleLimit: Duration
    private let memory: WindowMemory?

    init(scripts: any ScriptRunner, settleLimit: Duration = .seconds(15), memory: WindowMemory? = nil) {
        self.scripts = scripts
        self.settleLimit = settleLimit
        self.memory = memory
        // The window a Latchkey that quit was using, so it still closes when unused (FR-411; a
        // restart forgot it, live check 2026-10-29). Only from the same run of Safari: after
        // Safari restarts, the id may be one of the Owner's windows.
        if let memory, let saved = memory.load(), saved.safari == memory.safari() {
            window = saved.window
            lastUse = saved.lastUse
        }
    }

    private func remember() {
        guard let memory else { return }
        if let window, let safari = memory.safari() {
            memory.save(WindowMemory.Saved(window: window, lastUse: lastUse, safari: safari))
        } else {
            memory.save(nil)
        }
    }

    /// Loads `url` in Claude's window (a new tab if asked), making the window if needed. A page
    /// that doesn't finish loading is an error naming what Safari still shows, never a read of
    /// the old page as if it were the new one (2026-10-25: Claude asked for an Amazon page and
    /// was given another page's text).
    func open(_ url: String, newTab: Bool) async throws -> PageScripts.Page {
        let address = try Self.normalize(url)
        let before = try? await stamp()
        let id = try await call(Script.open, [address, window ?? "", newTab ? "yes" : "no"])
        window = id
        guard try await settle(after: before, expectNavigation: true) else {
            let shown = (try? await stamp())?.address ?? "an unknown page"
            throw Failure.failed(
                "Safari didn't finish loading \(address) within \(settleLimit.components.seconds) seconds; Claude's window still shows \(shown). Try again, or read the page as it is with browser_read."
            )
        }
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
        _ = try await settle(after: before, expectNavigation: false)
        return try await read(offset: 0)
    }

    func type(_ ref: String, text: String, submit: Bool) async throws -> PageScripts.Page {
        let before = try? await stamp()
        try check(try await javaScript(PageScripts.type(ref, text: text, submit: submit)), ref: ref, option: text)
        if submit { _ = try await settle(after: before, expectNavigation: false) }
        return try await read(offset: 0)
    }

    func back() async throws -> PageScripts.Page {
        let before = try? await stamp()
        _ = try await javaScript(PageScripts.back)
        _ = try await settle(after: before, expectNavigation: true)
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

    /// Waits until a new page has finished loading, at most `settleLimit` (plan D3). The old page
    /// (or a new window's blank page) also reads "complete", so finished means a different
    /// document. An action that may not navigate (a click that only changes the page) counts as
    /// finished when no new page has started after 1.5 s. False when the time ran out.
    private func settle(after before: PageScripts.Stamp?, expectNavigation: Bool) async throws -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now < start + settleLimit {
            try await Task.sleep(for: .milliseconds(250))
            let now: PageScripts.Stamp
            do { now = try await stamp() } catch Failure.javaScriptOff {
                throw Failure.javaScriptOff  // waiting won't help; the Owner must turn it on
            } catch {
                continue
            }
            let newDocument = before.map { $0.origin != now.origin } ?? (now.address != "about:blank")
            if now.complete, newDocument { return true }
            if now.complete, !expectNavigation, ContinuousClock.now > start + .milliseconds(1500) { return true }
        }
        return false
    }

    private func check(_ answer: String, ref: String, option: String = "") throws {
        switch answer {
        case "ok": return
        case "missing": throw Failure.elementMissing(ref)
        case "nooption": throw Failure.noOption(option)
        default: throw Failure.failed("The page answered: \(answer)")
        }
    }

    /// Closes Claude's window once it has gone `after` unused (FR-411). True when it closed one.
    func closeIfIdle(after: TimeInterval = 1800, now: Date = Date()) async -> Bool {
        guard let id = window, now.timeIntervalSince(lastUse) >= after else { return false }
        window = nil
        _ = try? await scripts.run(Script.close, [id])
        return true
    }

    private func call(_ script: String, _ args: [String]) async throws -> String {
        lastUse = Date()
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
            -- The new window is the one whose id wasn't there before: the front window may be
            -- one of the Owner's (another Space, full screen), and Claude must never adopt it.
            set beforeIDs to id of every window
            make new document with properties {URL:theURL}
            repeat 50 times
            repeat with w in windows
            if (id of w) is not in beforeIDs then return (id of w) as text
            end repeat
            delay 0.1
            end repeat
            error "Safari didn't show the new window."
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
        /// argv: window id. Closes that window only, if it is still there.
        static let close = """
            on run argv
            set winID to (item 1 of argv) as integer
            tell application "Safari"
            if (exists window id winID) then close window id winID
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

/// Where Claude's Safari window is kept across restarts of Latchkey: a small file in its support
/// folder (research.md). `safari` names the running Safari, by process id and launch time.
struct WindowMemory: Sendable {
    struct Saved: Codable, Equatable, Sendable {
        var window: String
        var lastUse: Date
        var safari: String
    }

    var file: URL
    var safari: @Sendable () -> String?

    func load() -> Saved? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    func save(_ saved: Saved?) {
        let fm = FileManager.default
        guard let saved, let data = try? JSONEncoder().encode(saved) else {
            try? fm.removeItem(at: file)
            return
        }
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The app's own; none under tests, which never touch real storage.
    static var app: WindowMemory? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        return WindowMemory(file: AppIdentity.current.supportDirectory.appending(path: "safari-window.json")) {
            guard let s = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first,
                let launched = s.launchDate
            else { return nil }
            return "\(s.processIdentifier) \(launched.timeIntervalSince1970)"
        }
    }
}
