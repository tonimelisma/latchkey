import AppKit
import CryptoKit

/// One of the Owner's tabs as Latchkey knows it while Claude works in it (spec 005 plan D8).
/// Safari gives tabs no id, so the tab is known by its position, the window's tab count and its
/// address when Latchkey last saw them, and a mark (`token`) Latchkey puts on its page, which a
/// new page loses.
struct PickedTab: Equatable, Sendable {
    var index: Int
    var count: Int
    var address: String
    var token: String
    /// The window's tabs when the mark was last seen (`TabSurvey.fingerprint`, FR-432).
    var fingerprint: String? = nil
}

/// What Safari reports about a window's tabs before Latchkey uses the picked one: for each tab
/// only whether it shows the tab's last address and whether it carries Latchkey's mark (checked
/// only in the tab at the picked position and tabs at that address), and for the tab at that
/// position whether it shows an address Claude's own click, typing, or back is loading.
struct TabSurvey: Equatable {
    struct Row: Equatable {
        var index: Int
        var sameAddress: Bool
        var marked: Bool
        var loading = false
        /// The page didn't answer within 10 s: it waits on a dialog it showed, or Safari has paused
        /// or is busy with the tab (spec 005 FR-432; 2 s until 2026-11-15, when a busy tab was
        /// reported as waiting on a dialog it didn't have; an idle Safari took 12 s to answer its
        /// first script that day, then 0.5 s).
        var waiting = false
        /// The tab's address, only for the window's fingerprint.
        var address = ""
    }

    /// The window's tabs, in order, as one value: the same while no tab opened, closed, moved,
    /// or changed its page (security review 2026-11-03).
    var fingerprint: String {
        let all = rows.map(\.address).joined(separator: "\n")
        return SHA256.hash(data: Data("\(count)\n\(all)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var count: Int
    var rows: [Row]

    init(count: Int, rows: [Row]) {
        self.count = count
        self.rows = rows
    }

    /// Safari's answer: the tab count, then "index<TAB>same<TAB>marked<TAB>loading" per tab,
    /// each true or false.
    init(_ text: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        count = lines.isEmpty ? 0 : Int(lines.removeFirst().trimmingCharacters(in: .whitespaces)) ?? 0
        rows = lines.compactMap { line in
            let f = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 3, let i = Int(f[0]) else { return nil }
            return Row(
                index: i, sameAddress: f[1] == "true", marked: f[2] == "true", loading: f.count > 3 && f[3] == "true",
                waiting: f.count > 4 && f[4] == "true", address: f.count > 5 ? f[5] : "")
        }
    }

    /// Which tab is the picked one, or nil when none surely is (better lose the tab than use
    /// another): the tab at its position with Latchkey's mark; or, while a page Claude's own
    /// action loaded is loading (`navigating`; the new page has no mark yet), the tab at that
    /// position when the window has as many tabs as before and the tab shows that address; or,
    /// when tabs moved, a tab with the mark at the tab's last address.
    static func pick(_ s: TabSurvey, remembered t: PickedTab, navigating: Bool) -> Int? {
        if let r = s.rows.first(where: { $0.index == t.index }) {
            if r.marked { return r.index }
            if navigating && r.loading && s.count == t.count { return r.index }
            // A page waiting on its own dialog answers no script, so it can't show the mark: it
            // is the picked tab only while the window's tabs are exactly as when its mark was last
            // seen (FR-432; security review 2026-11-03: an address alone could be another tab's).
            if r.waiting && r.sameAddress && s.count == t.count, let seen = t.fingerprint, seen == s.fingerprint {
                return r.index
            }
        }
        return s.rows.first { $0.index != t.index && $0.sameAddress && $0.marked }?.index
    }
}

/// The Owner's Safari tabs, driven through Apple Events in the background (spec 005 plan D8):
/// listed, and read and acted in when a call names one (FR-424 to FR-431, FR-447). Claude's own
/// pages are Latchkey's own browser's (FR-444, `OwnPages`), never Safari's.
actor SafariBrowser {
    enum Failure: Error, Equatable {
        /// No tab of the Owner's is picked (or Latchkey's own page isn't open).
        case noWindow
        case javaScriptOff
        case elementMissing(String)
        case noOption(String)
        case moved
        /// The Owner's tab Claude was working in isn't surely there any more (FR-429).
        case tabGone
        /// The Owner's tab didn't answer in time (10 s when found, 6 s right after): it may wait on a
        /// dialog of its own, or be paused or busy (FR-432).
        case dialogWaiting
        /// A page of Claude's in Latchkey's own browser holds a confirm or prompt for Claude to
        /// answer (FR-448): the page's name, the dialog's kind, and its text (the website's).
        case dialogHeld(page: String, kind: String, message: String)
        case failed(String)
    }

    let scripts: any ScriptRunner
    /// What the page's dialogs said since the last answer, told to Claude with it (FR-432).
    private var dialogs: [String] = []

    /// Takes the dialogs noted since the last call.
    func takeDialogs() -> [String] {
        defer { dialogs = [] }
        return dialogs
    }

    /// At most 5 notes, as in Latchkey's own browser (security review 2026-11-02).
    private func heard(_ json: String) {
        guard let data = json.data(using: .utf8), let said = try? JSONDecoder().decode([[String]].self, from: data)
        else { return }
        for d in said where d.count >= 2 {
            if dialogs.count < 5 {
                dialogs.append(PageScripts.dialogNote(kind: d[0], message: d[1], answer: d.count > 2 ? d[2] : nil))
            } else if dialogs.count == 5 {
                dialogs.append("…and more.")
            }
        }
    }

    /// The Owner's tab Claude works in (FR-425): its window, position, count, address, and a mark
    /// of Latchkey's own. Kept in memory only.
    private var picked: (window: String, tab: PickedTab)?
    /// The address of a picked tab whose page Safari let no script mark (an empty tab, Safari's
    /// own pages), as it was when picked: such a tab is known by it instead (plan D8). Never
    /// updated, so a navigation can't move it.
    private var pickedUnmarked: String?
    /// Set when this action lost the Owner's tab: the rest of it does nothing (FR-429).
    private var lostPick = false
    /// When Latchkey last used the picked tab (an unused pick is forgotten, FR-425).
    private var lastUse = Date()
    /// How long a page may take to load (plan D3).
    private let settleLimit: Duration
    /// How long a script with await may run in Safari before its result is given up (the call has 30 s).
    private let asyncLimit: Duration = .seconds(20)
    /// Claude's own navigation in the tab: when it started and where to (where the page said it
    /// was going after Claude's click, typing, or back). Not `lastUse`, which every Apple Event
    /// refreshes (security review, 2026-10-29).
    private var navigation: (since: Date, addresses: [String])?
    /// Per action of Claude's (each public call): whether the navigation began in it, and
    /// whether its page's note of where it is going was taken. One note per action, and
    /// `navigation.since` set at most once per action (security review, 2026-10-29: the note
    /// comes from the page, which could otherwise keep the allowance open).
    private var navigatedThisAction = false
    private var noteTaken = false
    /// When a page's note last opened the allowance: a note never moves it forward while that
    /// allowance is open, so calls that interleave can't keep it open (security review,
    /// 2026-10-29).
    private var noteOpened: Date?
    /// Whether this action may move the page (a click, typing, back): only then may a note open
    /// the allowance (security review, 2026-10-29).
    private var mayNavigate = false
    /// How long after Claude's navigation started the tab may be unmarked.
    private var allowance: TimeInterval { Double(settleLimit.components.seconds) + 1 }

    /// While the Mac is locked, scripts go to `lockedScripts` (a shorter limit), so a Safari that
    /// stopped answering is told within the relay's 30 s (FR-430; 2026-11-15: with 25 s for each
    /// of a call's scripts, a locked Mac's call passed the relay's limit, and Claude heard only that
    /// the Mac didn't answer).
    private let lockedScripts: (any ScriptRunner)?
    private let isLocked: @Sendable () -> Bool

    init(
        scripts: any ScriptRunner, settleLimit: Duration = .seconds(15), lockedScripts: (any ScriptRunner)? = nil,
        isLocked: @escaping @Sendable () -> Bool = { SystemScreen().isLocked() }
    ) {
        self.scripts = scripts
        self.settleLimit = settleLimit
        self.lockedScripts = lockedScripts
        self.isLocked = isLocked
    }

    /// For tests: as if Claude last used the tab, and last navigated it, `seconds` earlier.
    func age(by seconds: TimeInterval) {
        lastUse = lastUse.addingTimeInterval(-seconds)
        navigation?.since.addTimeInterval(-seconds)
    }

    /// For tests: Claude's navigation as Latchkey has it.
    func navigationState() -> (since: Date, addresses: [String])? { navigation }

    private func beginAction(mayNavigate: Bool = false) {
        lostPick = false
        navigatedThisAction = false
        noteTaken = false
        self.mayNavigate = mayNavigate
    }

    private func navigated(to address: String) {
        navigation = (Date(), [address])
        navigatedThisAction = true
    }

    /// Takes the page's note of where it is going: once per action. In an action that already
    /// began a navigation, the address joins it without moving its start.
    /// A note the page wrote counts only for an address on the site of the page Claude's tab
    /// shows: what the page can name is its own site (security review, 2026-10-29). The address
    /// of the link Claude clicked (or of the entry back goes to), read by Latchkey's own script,
    /// counts on any site when the link's address was the same before and after the click
    /// (2026-11-01: a click to another site lost the tab until then; the security review of the
    /// change asked that a page's click handler can't name another site); the tab is still taken
    /// only at Claude's position, with as many tabs as before, while it shows that address loading
    /// (`TabSurvey.pick`).
    /// One script's notes count as one: the note taken in the script's own run, the one the
    /// acting script waited for, and the clicked address, each JSON-encoded.
    private func take(notes: [String], here: String?, clicked: String? = nil, clickedAnySite: Bool = false) {
        guard !noteTaken, let here else { return }
        var goals: [String] = []
        if let clicked, let goal = Self.goal(fromNote: clicked), clickedAnySite || Self.sameSite(goal, here) {
            goals.append(goal)
        }
        for note in notes {
            if let goal = Self.goal(fromNote: note), Self.sameSite(goal, here), !goals.contains(goal) {
                goals.append(goal)
            }
        }
        guard let first = goals.first else { return }
        noteTaken = true
        func add() {
            for goal in goals where navigation?.addresses.contains(goal) == false { navigation?.addresses.append(goal) }
        }
        if navigatedThisAction, navigation != nil {
            add()
        } else if let opened = noteOpened, Date().timeIntervalSince(opened) < allowance {
            add()
        } else if mayNavigate {
            noteOpened = Date()
            navigated(to: first)
            add()
        }
    }

    /// The same site: scheme http or https, the host with or without www., the same port.
    static func sameSite(_ a: String, _ b: String) -> Bool {
        func site(_ s: String) -> (String, Int?)? {
            guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(),
                ["http", "https"].contains(scheme),
                var host = c.host?.lowercased(), !host.isEmpty
            else { return nil }
            if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
            return (host, c.port)
        }
        guard let x = site(a), let y = site(b) else { return false }
        return x.0 == y.0 && x.1 == y.1
    }

    /// The address in the page's note (JSON-encoded by the page script), if it is one web
    /// address with no spaces or line breaks; nil otherwise.
    static func goal(fromNote note: String) -> String? {
        guard let data = note.data(using: .utf8),
            let goal = try? JSONDecoder().decode(String.self, from: data), !goal.isEmpty,
            goal.unicodeScalars.allSatisfy({
                !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
            }),
            let c = URLComponents(string: goal), let scheme = c.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            c.host?.isEmpty == false
        else { return nil }
        return goal
    }

    func read(offset: Int) async throws -> PageScripts.Page {
        beginAction()
        return try await readPage(offset: offset)
    }

    private func readPage(offset: Int) async throws -> PageScripts.Page {
        // Safari answers no script while locked: waiting would only add a timeout (FR-430).
        if offset == 0, !isLocked() { await PageScripts.quiet { try await javaScript(PageScripts.changes) } }
        do {
            return try PageScripts.decode(try await javaScript(PageScripts.read(offset: offset)))
        } catch is DecodingError {
            throw Failure.failed("Safari reported a problem: the page didn't answer as expected.")
        }
    }

    /// `answer`: how the page's dialogs are answered during this click only (FR-432).
    /// The tab Claude works in is one Latchkey opened for Claude (FR-455), not the owner's.
    private var claudesTab = false

    func click(_ ref: String, answer: DialogAnswer = DialogAnswer()) async throws -> PageScripts.Page {
        beginAction(mayNavigate: true)
        let before = try? await stamp()
        try check(
            try await javaScript(PageScripts.click(ref, sameTab: claudesTab), acting: true, answer: answer), ref: ref)
        _ = try await settle(after: before, expectNavigation: false)
        return try await readPage(offset: 0)
    }

    func type(_ ref: String, text: String, submit: Bool, answer: DialogAnswer = DialogAnswer()) async throws
        -> PageScripts.Page
    {
        beginAction(mayNavigate: true)
        let before = try? await stamp()
        try check(
            try await javaScript(PageScripts.type(ref, text: text, submit: submit), acting: true, answer: answer),
            ref: ref, option: text)
        if submit { _ = try await settle(after: before, expectNavigation: false) }
        return try await readPage(offset: 0)
    }

    func back() async throws -> PageScripts.Page {
        beginAction(mayNavigate: true)
        let before = try? await stamp()
        _ = try await javaScript(PageScripts.back, acting: true)
        _ = try await settle(after: before, expectNavigation: true)
        return try await readPage(offset: 0)
    }

    func run(_ code: String, answer: DialogAnswer = DialogAnswer()) async throws -> String {
        beginAction()
        if !PageScripts.usesAwait(code) {
            let out = try await javaScript(PageScripts.custom(code), answer: answer)
            if !PageScripts.evalRefused(out) { return out }
        }
        return try await runAsync(code, answer: answer)
    }

    /// Claude's script as spliced code in an async function: for await, and for pages whose
    /// policy forbids eval (2026-11-16). Started in one script, its result collected by the next
    /// ones, as Safari's `do JavaScript` doesn't wait for a promise.
    private func runAsync(_ code: String, answer: DialogAnswer) async throws -> String {
        let id = Self.newToken()
        for body in PageScripts.asyncBodies(code) {
            let started = try await javaScript(PageScripts.startAsync(id: id, body: body), answer: answer)
            guard started == "started" else { continue }
            let deadline = ContinuousClock.now + asyncLimit
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
                let r = try await javaScript(PageScripts.asyncResult(id: id))
                switch r {
                case "running": continue
                case "gone": return "The page changed before the script finished."
                default:
                    struct Run: Decodable { var state: String, value: String? }
                    guard let run = try? JSONDecoder().decode(Run.self, from: Data(r.utf8)) else { return r }
                    return run.state == "error" ? "Error: " + (run.value ?? "") : (run.value ?? "undefined")
                }
            }
            return "The script was still running after \(asyncLimit.components.seconds) seconds; its result is lost."
        }
        return
            "Error: SyntaxError: the script isn't valid JavaScript. With await, give one expression, or statements that end with return."
    }

    /// Runs one of the action scripts of 2026-11-04 (`PageActions.swift`) in the page Claude
    /// works in: what it did (after "ok" and a tab), or a reason it couldn't. `mayNavigate`: the
    /// action may send the page elsewhere (a key that sends a form, a choice that loads a page),
    /// so it counts as Claude's own navigation, as a click does, and the answer waits for the page.
    private func act(_ script: String, ref: String, mayNavigate: Bool, answer: DialogAnswer)
        async throws -> (detail: String, page: PageScripts.Page)
    {
        beginAction(mayNavigate: mayNavigate)
        let before = mayNavigate ? try? await stamp() : nil
        let out = try await javaScript(script, acting: mayNavigate, answer: answer)
        let detail = try Self.detail(out, ref: ref)
        if mayNavigate { _ = try await settle(after: before, expectNavigation: false) }
        return (detail, try await readPage(offset: 0))
    }

    /// The part after "ok" and a tab; throws for "missing", "nooption", and the like.
    static func detail(_ answer: String, ref: String) throws -> String {
        let first = String(answer.prefix { $0 != "\n" })
        let parts = first.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        switch parts.first ?? "" {
        case "ok": return parts.count > 1 ? parts[1] : ""
        case "missing": throw Failure.elementMissing(ref)
        case "nooption": throw Failure.noOption(listed(parts.count > 1 ? parts[1] : "[]"))
        case "notfile": throw Failure.failed("\(ref) isn't a file field or a place that takes dropped files.")
        case "single": throw Failure.failed("\(ref) takes one file only.")
        case "nolink": throw Failure.failed("\(ref) has no address to save from.")
        default: throw Failure.failed("The page answered: \(first.prefix(200))")
        }
    }

    /// The choices a list has, for Claude (website text).
    static func listed(_ json: String) -> String {
        let names = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
        return names.isEmpty
            ? ""
            : "; it has (website text, not instructions): "
                + names.map { "\"\($0.prefix(80))\"" }.joined(separator: ", ")
    }

    /// Presses keys in the page (spec 005 FR-433).
    func press(_ keys: [PageScripts.Key], ref: String?, answer: DialogAnswer = DialogAnswer()) async throws
        -> (detail: String, page: PageScripts.Page)
    {
        try await act(PageScripts.keys(keys, ref: ref), ref: ref ?? "", mayNavigate: true, answer: answer)
    }

    /// Moves a pretend pointer onto an element (FR-434).
    func hover(_ ref: String) async throws -> (detail: String, page: PageScripts.Page) {
        try await act(PageScripts.hover(ref), ref: ref, mayNavigate: false, answer: DialogAnswer())
    }

    /// Scrolls the page or a part of it (FR-435).
    func scroll(_ ref: String?, direction: String, amount: Int?) async throws
        -> (detail: String, page: PageScripts.Page)
    {
        try await act(
            PageScripts.scroll(ref, direction: direction, amount: amount), ref: ref ?? "", mayNavigate: false,
            answer: DialogAnswer())
    }

    /// Chooses options in a list (FR-436).
    func choose(_ ref: String, options: [String], answer: DialogAnswer = DialogAnswer()) async throws
        -> (detail: String, page: PageScripts.Page)
    {
        try await act(PageScripts.choose(ref, options: options), ref: ref, mayNavigate: true, answer: answer)
    }

    /// Attaches files to a file field, or drops them on the element (FR-437).
    func attach(_ ref: String, files: [PageScripts.Attachment], answer: DialogAnswer = DialogAnswer()) async throws
        -> (detail: String, page: PageScripts.Page)
    {
        try await act(PageScripts.attach(ref, files: files), ref: ref, mayNavigate: true, answer: answer)
    }

    /// Fetches a file in the page, with the page's cookies and session (FR-438): the link `ref`
    /// names, `url`, or the page's own address; waits for it up to `wait`.
    func fetchFile(ref: String?, url: String?, maxBytes: Int, wait: Duration = .seconds(20)) async throws
        -> (address: String, suggested: String, fetched: PageScripts.Fetched)
    {
        beginAction()
        let started = try Self.detail(
            try await javaScript(PageScripts.startDownload(ref: ref, url: url, limit: maxBytes)), ref: ref ?? "")
        let start = try PageScripts.DownloadStart.decode(started)
        let deadline = ContinuousClock.now + wait
        while ContinuousClock.now < deadline {
            let f = try PageScripts.Fetched.decode(try await javaScript(PageScripts.takeDownload))
            if f.state != "running" { return (start.address, start.suggested, f) }
            try await Task.sleep(for: .milliseconds(150))
        }
        return (start.address, start.suggested, PageScripts.Fetched(state: "failed", error: BrowserDownloads.tooLong))
    }

    /// The page as it is now, for a picture Latchkey draws itself (FR-439).
    func pictureCopy() async throws -> PageScripts.PictureCopy {
        beginAction()
        return try PageScripts.PictureCopy.decode(
            try await javaScript(PageScripts.pictureCopy(limit: PageScripts.pictureCopyLimit)))
    }

    /// Every tab of every Safari window, front to back (FR-424), with the tab Claude works in.
    /// No script runs in any page for the list itself.
    func listTabs() async throws -> SafariTabList {
        beginAction()
        var list = SafariTabList(try await call(Script.allTabs, []))
        // While locked each script may wait 12 s: finding the tab again would put the list past the
        // relay's 30 s (feedback report 2026-11-17); the tab it was at is marked then.
        if picked != nil, !isLocked() { _ = try? await locate() }
        let working = picked.map { ($0.window, $0.tab.index) }
        for w in list.windows.indices {
            for t in list.windows[w].tabs.indices {
                let here = (list.windows[w].id, list.windows[w].tabs[t].index)
                list.windows[w].tabs[t].working = working.map { $0 == here } ?? false
            }
        }
        return list
    }

    /// The tab Claude works in, as the list names it ("4213.2"), or nil.
    func working() -> String? { picked.map { "\($0.window).\($0.tab.index)" } }

    /// Forgets the picked tab (nothing is done to it).
    func forget() {
        picked = nil
        claudesTab = false
        pickedUnmarked = nil
        navigation = nil
        noteOpened = nil
    }

    /// The Owner's tab is lost (FR-429): the rest of this action does nothing.
    private func losePick() {
        forget()
        lostPick = true
    }

    /// Makes Claude work in a tab from the list (FR-425): "4213.2" (window id, then tab number),
    /// or a bare number: that tab of the front window. The tab gets a mark of Latchkey's own;
    /// nothing comes forward (FR-427).
    func pick(_ reference: String) async throws {
        beginAction()
        let parts = reference.trimmingCharacters(in: .whitespaces).split(
            separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) }),
            let last = parts.last, let number = Int(last), number >= 1, parts.count == 1 || Int(parts[0]) != nil
        else {
            throw Failure.failed(
                "\"\(reference.prefix(40))\" isn't a tab from the list. Tabs are named like 4213.2 (window, then tab); list them with browser_read and tabs."
            )
        }
        var id = parts.count == 2 ? String(parts[0]) : nil
        if id == nil { id = SafariTabList(try await call(Script.allTabs, [])).windows.first?.id }
        guard let id else { throw Failure.failed("Safari has no window open.") }
        let token = Self.newToken()
        let out: String
        do {
            out = try await call(
                Script.tabPick, [id, String(number), PageScripts.tabMark(token) + PageScripts.tabCheck(token)])
        } catch Failure.failed(let message) where message.contains("LATCHKEY_NO_TAB") {
            throw Failure.failed(
                "Safari has no tab \(id).\(number) now. List the tabs again with browser_read and tabs.")
        }
        let f = out.trimmingCharacters(in: .newlines).split(
            separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard f.count == 3, let count = Int(f[0]) else {
            throw Failure.failed("Safari reported a problem: it didn't describe tab \(id).\(number).")
        }
        forget()
        picked = (id, PickedTab(index: number, count: count, address: String(f[2]), token: token))
        claudesTab = false
        pickedUnmarked = f[1] == "yes" ? nil : String(f[2])
    }

    /// Opens `url` in a new tab of Claude's at the end of the Owner's front Safari window, behind
    /// the tab in front (FR-455), and works in it; nothing comes forward. False when Safari has
    /// no window (a new window would show on the Owner's screen, so none is made).
    func openTab(_ url: String) async throws -> PageScripts.Page? {
        beginAction()
        let address = try Self.normalize(url)
        let out = try await call(Script.tabNew, [address]).trimmingCharacters(in: .whitespacesAndNewlines)
        if out == "none" { return nil }
        let f = out.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count == 3, let index = Int(f[1]), let count = Int(f[2]) else {
            throw Failure.failed("Safari reported a problem: it didn't say where the new tab is.")
        }
        forget()
        picked = (f[0], PickedTab(index: index, count: count, address: address, token: Self.newToken()))
        claudesTab = true  // a tab Latchkey opened for Claude
        navigated(to: address)
        guard try await settle(after: nil, expectNavigation: true) else {
            throw Failure.failed(
                "Safari didn't finish loading \(address) within \(settleLimit.components.seconds) seconds. Read the page as it is with browser_read and page."
            )
        }
        return try await readPage(offset: 0)
    }

    /// Loads `url` in the tab Claude works in (a tab of Claude's own, FR-455).
    func load(_ url: String) async throws -> PageScripts.Page {
        beginAction()
        let address = try Self.normalize(url)
        let before = try? await stamp()
        let found = try await locate()
        _ = try await call(Script.tabLoad, replacingArguments(found) + [address])
        picked?.tab.address = address
        navigated(to: address)
        guard try await settle(after: before, expectNavigation: true) else {
            throw Failure.failed(
                "Safari didn't finish loading \(address) within \(settleLimit.components.seconds) seconds. Read the page as it is with browser_read and page."
            )
        }
        return try await readPage(offset: 0)
    }

    /// A driver of its own for a Safari tab of Claude's (FR-455): the same scripts and limits, its
    /// own tab, so pages of different chats never share one.
    nonisolated func sibling() -> SafariBrowser {
        SafariBrowser(scripts: scripts, settleLimit: settleLimit, lockedScripts: lockedScripts, isLocked: isLocked)
    }

    /// The address of the page Claude works in, as last seen.
    func workingAddress() -> String? { picked?.tab.address }

    /// Closes the Owner's tab Claude works in (FR-428), through the same check as any action
    /// (FR-429). Its address, or nil when no tab is picked.
    func closeWorking() async throws -> String? {
        beginAction()
        guard picked != nil else { return nil }
        // Tabs may move between finding the tab and closing it: the script checks again, and
        // Latchkey finds the tab again once.
        for attempt in 1...2 {
            let found = try await locate(navigating: false)
            do {
                _ = try await call(Script.tabClose, replacingArguments(found))
                forget()
                return found.tab.address
            } catch Failure.moved where attempt == 1 {
                continue
            }
        }
        losePick()
        throw Failure.tabGone
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

    /// Runs `code` in the picked tab. `acting`: Claude's click, typing, or back, whose script may
    /// answer the address it sends the page to on a second line (taken here, not returned), and
    /// after which the acting AppleScript waits a moment for the page's note of where it is going.
    /// The page's own dialogs come back after each script (FR-432).
    private func javaScript(_ code: String, acting: Bool = false, answer: DialogAnswer = DialogAnswer())
        async throws -> String
    {
        if lostPick { throw Failure.tabGone }
        guard picked != nil else { throw Failure.noWindow }
        let answering = PageScripts.dialogAnswers(answer)
        let taking = PageScripts.takeDialogs(restore: true)
        // Safari's tabs may move between finding the tab and using it: the script checks again
        // before acting, and Latchkey finds the tab again once.
        for attempt in 1...2 {
            let found = try await locate()
            if found.waiting { throw Failure.dialogWaiting }
            do {
                let file = try ScriptFile(answering + PageScripts.tabMark(found.tab.token) + PageScripts.inTab(code))
                defer { file.remove() }
                let out = try await call(
                    Script.tabJavaScript,
                    guardArguments(found) + [file.argument, PageScripts.takeDestination, acting ? "yes" : "no", taking])
                var parts = out.split(separator: "\n", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                if parts.count > 2 { heard(parts.remove(at: 2)) }
                // The site to compare a note with is the one the tab showed before the script.
                let before = picked?.tab.address
                if let address = parts.first, !address.isEmpty { picked?.tab.address = address }
                var answer = ""
                var notes: [String] = []
                if parts.count > 2, let data = parts[2].data(using: .utf8),
                    let both = try? JSONDecoder().decode([String].self, from: data), both.count == 2
                {
                    answer = both[0]
                    notes.append(both[1])
                }
                if parts.count > 1 { notes.append(parts[1]) }
                var clicked: String?
                var unchanged = false
                if acting, let line = answer.firstIndex(of: "\n") {
                    let rest = answer[answer.index(after: line)...].split(
                        separator: "\n", omittingEmptySubsequences: false)
                    clicked = rest.first.map(String.init)
                    unchanged = rest.count > 1 && rest[1] == "\"same\""
                    answer = String(answer[..<line])
                }
                // The page said it is going to another page (Claude's click, a form, back).
                take(notes: notes, here: before, clicked: clicked, clickedAnySite: unchanged)
                return answer
            } catch Failure.moved where attempt == 1 {
                continue
            }
        }
        throw Failure.moved
    }

    /// The picked tab as found, and the addresses an unmarked tab in its place may show (empty
    /// unless a page Claude's action loaded is loading).
    struct Found {
        var window: String
        var tab: PickedTab
        var loading: [String]
        /// The page waits on its own dialog (FR-432): it is left as it is.
        var waiting = false
    }

    /// The addresses the tab may show unmarked now: those of Claude's own navigation, while it is
    /// recent, in their usual spellings (http or https, with or without www. and a final /).
    private var loadingAddresses: [String] {
        guard let navigation, Date().timeIntervalSince(navigation.since) < allowance else { return [] }
        return Self.spellings(of: navigation.addresses)
    }

    /// The picked tab, found again (plan D6, D8). It is also taken while it shows the address
    /// Latchkey last saw there when Safari let no script mark it; when it isn't surely found,
    /// Claude stops working in it and is told to list the tabs again (FR-429). `navigating: false`
    /// allows only a marked tab (closing).
    private func locate(navigating: Bool = true) async throws -> Found {
        guard let window = picked?.window, var t = picked?.tab else { throw Failure.noWindow }
        var loading = navigating ? loadingAddresses : []
        if let fixed = pickedUnmarked, !fixed.isEmpty, !fixed.contains("\n"), !loading.contains(fixed) {
            loading.append(fixed)
        }
        let survey = TabSurvey(
            try await call(
                Script.tabSurvey,
                [window, String(t.index), t.address, PageScripts.tabCheck(t.token), loading.joined(separator: "\n")]))
        guard let index = TabSurvey.pick(survey, remembered: t, navigating: !loading.isEmpty) else {
            losePick()
            throw Failure.tabGone
        }
        t.index = index
        t.count = survey.count
        let row = survey.rows.first { $0.index == index }
        if row?.marked == true { t.fingerprint = survey.fingerprint }
        picked?.tab = t
        return Found(window: window, tab: t, loading: loading, waiting: row?.waiting ?? false)
    }

    /// The first arguments of every script that acts on Claude's tab: it checks again, in the
    /// same script, that the tab is Claude's before acting (marked, or showing an address Claude
    /// is loading), so a tab that moved into Claude's place in between is left alone.
    private func guardArguments(_ f: Found) -> [String] {
        [
            f.window, String(f.tab.index), String(f.tab.count), PageScripts.tabCheck(f.tab.token),
            f.loading.joined(separator: "\n"),
        ]
    }

    /// The same for loading over the page or closing the tab: a page waiting on its own dialog
    /// answers no script, so it is also known by the address it showed (FR-432).
    private func replacingArguments(_ f: Found) -> [String] {
        var a = guardArguments(f)
        if f.waiting, !f.tab.address.isEmpty, !f.tab.address.contains("\n") {
            a[4] = (f.loading + [f.tab.address]).joined(separator: "\n")
        }
        return a
    }

    /// The usual spellings of `addresses`, as a redirect to https, to www., or to a final / gives.
    static func spellings(of addresses: [String]) -> [String] {
        var out: [String] = []
        func add(_ s: String) { if !s.contains("\n"), !out.contains(s) { out.append(s) } }
        for a in addresses {
            add(a)
            guard var c = URLComponents(string: a), let host = c.host, !host.isEmpty,
                let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme)
            else { continue }
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let path = c.percentEncodedPath
            let paths =
                path.isEmpty || path == "/"
                ? ["", "/"] : (path.hasSuffix("/") ? [path, String(path.dropLast())] : [path, path + "/"])
            for s in ["https", "http"] {
                for h in [bare, "www." + bare] {
                    for p in paths {
                        c.scheme = s
                        c.host = h
                        c.percentEncodedPath = p
                        if let spelled = c.string { add(spelled) }
                    }
                }
            }
        }
        return out
    }

    /// What a picture of the picked tab would take (spec 005 FR-423): whether the tab must first
    /// come to the front of its window, the title that window shows now, and the page's address.
    func pictureSwitch() async throws -> (needed: Bool, shownTitle: String, address: String) {
        let found = try await locate()
        let f = try await call(Script.tabFront, guardArguments(found)).trimmingCharacters(in: .newlines).split(
            separator: "\t", maxSplits: 2, omittingEmptySubsequences: false
        ).map(String.init)
        guard f.count == 3 else { throw Failure.failed("Safari answered: \(f.joined(separator: " "))") }
        return (f[0] != "true", f[1], f[2])
    }

    /// Shows the picked tab for a screenshot (spec 006 FR-509): `body` gets the title Safari's
    /// window then shows. The tab comes to the front for the shot and the tab that was in front
    /// comes back afterwards, also when the shot failed (FR-415); a tab the Owner switched to
    /// meanwhile stays.
    func showing<T: Sendable>(_ body: @Sendable (String) async throws -> T) async throws -> T {
        beginAction()
        let found = try await locate()
        let t = found.tab
        let f = try await call(Script.tabShow, guardArguments(found)).split(
            separator: "\t", maxSplits: 1, omittingEmptySubsequences: false
        ).map(String.init)
        let previous = f.first.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? t.index
        let title = f.count > 1 ? f[1].trimmingCharacters(in: .newlines) : ""
        let back = [found.window, String(t.index), String(previous), PageScripts.tabCheck(t.token)]
        do {
            try await Task.sleep(for: .milliseconds(300))  // Safari draws the tab
            let result = try await body(title)
            _ = try? await scripts.run(Script.tabRestore, back)
            return result
        } catch {
            _ = try? await scripts.run(Script.tabRestore, back)
            throw error
        }
    }

    private static func newToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The current document's identity: each page load has its own start time, even at the same
    /// address. Answers "origin|readyState|address".
    /// What a file name in a script's argument starts with (`Script.readCode`).
    static let fileMark = "LATCHKEY_FILE:"
    /// Scripts longer than this go to Safari through a file (`Script.readCode`).
    static let argumentLimit = 200_000

    /// A page script as `osascript` gets it: as it is, or, when longer than `argumentLimit`, the
    /// name of a file only this user can read, which the AppleScript reads; removed right after
    /// (research.md: 10 MB went into a background tab this way in 0.55 s).
    struct ScriptFile {
        let argument: String
        private let file: URL?

        init(_ code: String) throws {
            guard code.utf8.count > SafariBrowser.argumentLimit else {
                argument = code
                file = nil
                return
            }
            let folder = FileManager.default.temporaryDirectory.appending(
                path: "latchkey-page-scripts", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = folder.appending(path: UUID().uuidString + ".js")
            guard
                FileManager.default.createFile(
                    atPath: url.path, contents: Data(code.utf8), attributes: [.posixPermissions: 0o600])
            else { throw Failure.failed("Latchkey couldn't pass the script to Safari.") }
            argument = SafariBrowser.fileMark + url.path
            file = url
        }

        func remove() {
            if let file { try? FileManager.default.removeItem(at: file) }
        }
    }

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

    /// Forgets the picked tab once it has gone `after` unused (FR-425); it is the Owner's, so it is
    /// never closed. True when it forgot one.
    func forgetIfIdle(after: TimeInterval = 1800, now: Date = Date()) -> Bool {
        guard picked != nil, now.timeIntervalSince(lastUse) >= after else { return false }
        forget()
        return true
    }

    private func call(_ script: String, _ args: [String]) async throws -> String {
        lastUse = Date()
        let locked = isLocked()
        let runner = locked ? (lockedScripts ?? scripts) : scripts
        do { return try await runner.run(script, args) } catch ScriptError.failed(let message) {
            if message.contains("LATCHKEY_NO_WINDOW") {
                // The window of the tab Claude works in is gone.
                let had = picked != nil
                losePick()
                throw had ? Failure.tabGone : Failure.noWindow
            }
            if message.contains("LATCHKEY_MOVED") { throw Failure.moved }
            if message.contains("LATCHKEY_DIALOG_WAITING") { throw Failure.dialogWaiting }
            if message.contains("Allow JavaScript from Apple Events") { throw Failure.javaScriptOff }
            throw Failure.failed("Safari reported a problem: \(message)")
        } catch ScriptError.timedOut where locked {
            // Seen live 2026-11-01: with the Mac locked, Safari stops answering scripts after a page.
            throw Failure.failed(
                "Safari stopped answering while the Mac is locked. It answers again once someone unlocks the Mac."
            )
        }
    }

    enum Script {
        /// argv: window id, Claude's tab index, Claude's last address, the yes/no mark check.
        /// Answers the tab count, then per tab "index, same address, marked" (TabSurvey). The
        /// check runs only in the tab at Claude's position and tabs at Claude's address, and only
        /// says yes or no.
        static let tabSurvey = """
            on clean(s)
            set s to s as text
            set AppleScript's text item delimiters to {tab, return, linefeed}
            set parts to text items of s
            set AppleScript's text item delimiters to " "
            set s to parts as text
            set AppleScript's text item delimiters to ""
            return s
            end clean
            on run argv
            set winID to (item 1 of argv) as integer
            set idx to (item 2 of argv) as integer
            set lastURL to item 3 of argv
            set checkJS to item 4 of argv
            set theExpected to paragraphs of (item 5 of argv)
            set sep to character id 9
            tell application "Safari"
            if not (exists window id winID) then error "LATCHKEY_NO_WINDOW"
            set w to window id winID
            set n to count of tabs of w
            set out to (n as text) & linefeed
            repeat with i from 1 to n
            set t to tab i of w
            set sameURL to false
            try
            set sameURL to ((URL of t) is lastURL)
            end try
            set isMarked to false
            set isWaiting to false
            if i is idx or sameURL then
            try
            with timeout of 10 seconds
            set isMarked to ((do JavaScript checkJS in t) is "yes")
            end timeout
            on error number errNum
            if errNum is -1712 then set isWaiting to true
            end try
            end if
            set isLoading to false
            if i is idx then
            try
            set isLoading to ((URL of t) is in theExpected)
            end try
            end if
            set theURL to ""
            try
            set theURL to my clean(URL of t)
            end try
            set out to out & (i as text) & sep & (sameURL as text) & sep & (isMarked as text) & sep & (isLoading as text) & sep & (isWaiting as text) & sep & theURL & linefeed
            end repeat
            return out
            end tell
            end run
            """
        /// Sets `theCode` to argument `item`, or, when that names a file (`fileMark`), to the
        /// file's text: a script too long for a program's arguments (macOS allows about 1 MB for
        /// all of them), such as one carrying a file Claude attaches, travels that way. Read
        /// before `tell`, so the script itself reads the file, not Safari.
        static func readCode(_ item: Int) -> String {
            // nosemgrep: scripts.semgrep.latchkey-applescript-constant -- only fixed text (an argument number, a constant mark) is spliced in; every value is an argument
            """
            set theCode to item \(item) of argv
            if theCode starts with "\(SafariBrowser.fileMark)" then set theCode to (read (POSIX file (text \(SafariBrowser.fileMark.count + 1) thru -1 of theCode)) as «class utf8»)
            """
        }

        /// The start of every script that acts on Claude's tab (argv: window id, tab index, tab
        /// count, the yes/no mark check, the addresses Claude is loading, one per line): the
        /// window has as many tabs as when Latchkey found Claude's, and the tab still carries
        /// Claude's mark or shows an address Claude is loading. Else tabs moved in between, and
        /// nothing is done to the tab (security review, 2026-10-29).
        private static let tabGuard = """
            set winID to (item 1 of argv) as integer
            set idx to (item 2 of argv) as integer
            set n to (item 3 of argv) as integer
            set checkJS to item 4 of argv
            set theExpected to paragraphs of (item 5 of argv)
            tell application "Safari"
            if not (exists window id winID) then error "LATCHKEY_NO_WINDOW"
            set w to window id winID
            if (count of tabs of w) is not n then error "LATCHKEY_MOVED"
            set t to tab idx of w
            set confirmed to false
            set waiting to false
            try
            with timeout of 6 seconds
            set confirmed to ((do JavaScript checkJS in t) is "yes")
            end timeout
            on error number errNum
            if errNum is -1712 then set waiting to true
            end try
            if not confirmed then
            try
            set confirmed to ((URL of t) is in theExpected)
            end try
            end if
            if not confirmed then
            if waiting then error "LATCHKEY_DIALOG_WAITING"
            error "LATCHKEY_MOVED"
            end if
            """
        /// argv: the guard's five, the script, the script that answers where the page said it is
        /// going, "yes" when the script is Claude's click, typing, or back, the script that takes
        /// what the page's dialogs said. Answers the tab's address, where the page is going (or
        /// nothing), the dialogs (JSON), and the script's result, one per line.
        /// After a click, typing, or back, it asks for the page's note for up to about 0.6 s:
        /// Safari fires the `navigate` event of a link, a form, or back only after the script
        /// returned (real Safari, 2026-10-29). It stops at a note, at a page without Latchkey's
        /// note (the new page), or when the window's tabs changed.
        static let tabJavaScript =
            "on run argv\n" + readCode(6) + "\n" + tabGuard + "\n"
                + """
                if waiting then error "LATCHKEY_DIALOG_WAITING"
                set theAnswer to do JavaScript theCode in t
                if theAnswer is missing value then set theAnswer to ""
                set theGoal to ""
                set theNothing to quote & quote
                if (item 8 of argv) is "yes" then
                repeat 12 times
                set thePolled to "null"
                try
                if (count of tabs of w) is n then set thePolled to (do JavaScript (item 7 of argv) in t) as text
                end try
                if thePolled is not theNothing then
                if thePolled is not "null" and thePolled is not "missing value" then set theGoal to thePolled
                exit repeat
                end if
                delay 0.05
                end repeat
                end if
                -- The note is the page's: it must not add lines to the answer.
                set AppleScript's text item delimiters to {return, linefeed}
                set theGoalParts to text items of theGoal
                set AppleScript's text item delimiters to ""
                set theGoal to theGoalParts as text
                set theAddress to ""
                try
                set theAddress to (URL of t) as text
                end try
                set theDialogs to "[]"
                try
                with timeout of 2 seconds
                set theDialogs to (do JavaScript (item 9 of argv) in t) as text
                end timeout
                end try
                return theAddress & linefeed & theGoal & linefeed & theDialogs & linefeed & (theAnswer as text)
                end tell
                end run
                """
        /// argv: the guard's five. Answers, without changing anything, whether Claude's tab is
        /// the one in front, the title the window shows, and Claude's page address.
        static let tabFront =
            "on run argv\n" + tabGuard + "\n"
                + """
                set sep to character id 9
                set isFront to ((index of current tab of w) is idx)
                set shownTitle to ""
                try
                set shownTitle to (name of current tab of w) as text
                end try
                set theURL to ""
                try
                set theURL to (URL of t) as text
                end try
                return (isFront as text) & sep & shownTitle & sep & theURL
                end tell
                end run
                """
        /// argv: the guard's five. Brings Claude's tab to the front of its window;
        /// answers the tab that was in front and Claude's page title.
        static let tabShow =
            "on run argv\n" + tabGuard + "\n"
                + """
                set sep to character id 9
                set previousIndex to index of current tab of w
                set current tab of w to t
                set theTitle to ""
                try
                set theTitle to (name of t) as text
                end try
                return (previousIndex as text) & sep & theTitle
                end tell
                end run
                """
        /// argv: window id, Claude's tab index, the tab to bring back, the yes/no mark check. Only
        /// while Claude's tab, still marked, is in front: a tab the Owner chose meanwhile stays.
        static let tabRestore = """
            on run argv
            set winID to (item 1 of argv) as integer
            set idx to (item 2 of argv) as integer
            set previousIndex to (item 3 of argv) as integer
            set checkJS to item 4 of argv
            tell application "Safari"
            if not (exists window id winID) then return ""
            set w to window id winID
            if (index of current tab of w) is idx and previousIndex is not idx and previousIndex is less than or equal to (count of tabs of w) then
            set isMarked to false
            try
            with timeout of 2 seconds
            set isMarked to ((do JavaScript checkJS in (tab idx of w)) is "yes")
            end timeout
            end try
            if isMarked then set current tab of w to tab previousIndex of w
            end if
            return ""
            end tell
            end run
            """
        /// argv: the guard's five, url. Loads the address in Claude's tab only.
        static let tabLoad =
            "on run argv\n" + tabGuard + "\n"
                + """
                set URL of t to (item 6 of argv)
                return ""
                end tell
                end run
                """
        /// argv: url. A new tab at the end of the Owner's front Safari window, behind the tab the
        /// Owner has in front, for a page of Claude's (FR-455). Answers "window id<TAB>tab
        /// index<TAB>tab count", or "none" when Safari has no window: a new one would show on
        /// the Owner's screen (Constitution IV), so none is made.
        static let tabNew = """
            on run argv
            set theURL to item 1 of argv
            set sep to character id 9
            tell application "Safari"
            repeat with w in windows
            set isBrowser to false
            try
            get current tab of w
            set isBrowser to true
            end try
            if isBrowser then
            make new tab at end of tabs of w with properties {URL:theURL}
            set n to count of tabs of w
            return ((id of w) as text) & sep & (n as text) & sep & (n as text)
            end if
            end repeat
            return "none"
            end tell
            end run
            """
        /// argv: the guard's five. Closes Claude's tab only.
        static let tabClose =
            "on run argv\n" + tabGuard + "\n"
                + """
                close t
                return ""
                end tell
                end run
                """
        /// Every browser window, front to back (FR-424): "W<TAB>id<TAB>front tab number", then
        /// "T<TAB>number<TAB>title<TAB>address" per tab; tabs and line breaks in titles and
        /// addresses become spaces. No script runs in any page.
        static let allTabs = """
            on clean(s)
            set s to s as text
            set AppleScript's text item delimiters to {tab, return, linefeed}
            set parts to text items of s
            set AppleScript's text item delimiters to " "
            set s to parts as text
            set AppleScript's text item delimiters to ""
            return s
            end clean
            on run argv
            set sep to character id 9
            set out to ""
            tell application "Safari"
            repeat with w in windows
            set frontIndex to 0
            try
            set frontIndex to index of current tab of w
            end try
            if frontIndex is not 0 then
            set out to out & "W" & sep & ((id of w) as text) & sep & (frontIndex as text) & linefeed
            set n to count of tabs of w
            repeat with i from 1 to n
            set t to tab i of w
            set theName to ""
            set theURL to ""
            try
            set theName to name of t
            end try
            try
            set theURL to URL of t
            end try
            if theName is missing value then set theName to ""
            if theURL is missing value then set theURL to ""
            set out to out & "T" & sep & (i as text) & sep & (my clean(theName)) & sep & (my clean(theURL)) & linefeed
            end repeat
            end if
            end repeat
            end tell
            return out
            end run
            """
        /// argv: window id, tab number, Claude's mark script (ending with the yes/no check). Puts
        /// the mark on that tab's page (where Safari lets a script in) without bringing anything
        /// forward, and answers "count<TAB>yes or no (marked)<TAB>address".
        static let tabPick = """
            on run argv
            set winID to (item 1 of argv) as integer
            set idx to (item 2 of argv) as integer
            tell application "Safari"
            if not (exists window id winID) then error "LATCHKEY_NO_TAB"
            set w to window id winID
            set n to count of tabs of w
            if idx > n then error "LATCHKEY_NO_TAB"
            set t to tab idx of w
            set isMarked to "no"
            try
            with timeout of 10 seconds
            if (do JavaScript (item 3 of argv) in t) is "yes" then set isMarked to "yes"
            end timeout
            end try
            set theURL to ""
            try
            set theURL to (URL of t) as text
            end try
            return (n as text) & (character id 9) & isMarked & (character id 9) & theURL
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

/// Every tab of every Safari window (spec 005 FR-424), front to back, as `Script.allTabs`
/// answers. A tab's reference is its window's id and its number: "4213.2".
struct SafariTabList: Equatable, Sendable {
    struct Tab: Equatable, Sendable {
        var window: String
        var index: Int
        var title: String
        var address: String
        /// The tab in front of its window.
        var front: Bool
        /// The tab Claude works in (when it is one of the Owner's).
        var working = false
        var reference: String { "\(window).\(index)" }
    }

    struct Window: Equatable, Sendable {
        var id: String
        var frontWindow: Bool
        var tabs: [Tab]
    }

    var windows: [Window]

    init(windows: [Window]) { self.windows = windows }

    init(_ text: String) {
        var out: [Window] = []
        var front = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if f.first == "W", f.count >= 3 {
                front = Int(f[2]) ?? 0
                out.append(Window(id: f[1], frontWindow: out.isEmpty, tabs: []))
            } else if f.first == "T", f.count >= 4, let i = Int(f[1]), let w = out.indices.last {
                out[w].tabs.append(
                    Tab(
                        window: out[w].id, index: i, title: f[2], address: f[3...].joined(separator: " "),
                        front: i == front))
            }
        }
        windows = out
    }
}
