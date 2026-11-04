import AppKit

/// Where Claude's pages open (spec 005 FR-412, FR-417): a tab in the Owner's Safari window (the
/// default, Toni 2026-10-29) or a Safari window of Claude's own. Chosen in Settings.
enum BrowserPlace: String, CaseIterable, Sendable {
    case tab, window

    /// The user defaults key the Settings window writes.
    static let key = "browserPlace"

    static func stored(in defaults: UserDefaults) -> BrowserPlace {
        defaults.string(forKey: key).flatMap(BrowserPlace.init(rawValue:)) ?? .tab
    }

    static var current: BrowserPlace { stored(in: .standard) }
}

/// Claude's tab in the Owner's window (plan D6). Safari gives tabs no id, so the tab is known by
/// its position, the window's tab count and its address when Latchkey last saw them, and a mark
/// (`token`) Latchkey puts on its page, which a new page loses.
struct ClaudeTab: Codable, Equatable, Sendable {
    var index: Int
    var count: Int
    var address: String
    var token: String
}

/// What Safari reports about a window's tabs before Latchkey uses Claude's: for each tab only
/// whether it shows Claude's last address and whether it carries Claude's mark (checked only in
/// the tab at Claude's position and tabs at that address), and for the tab at Claude's position
/// whether it shows an address Claude just loaded. Nothing of the Owner's tabs comes back.
struct TabSurvey: Equatable {
    struct Row: Equatable {
        var index: Int
        var sameAddress: Bool
        var marked: Bool
        var loading = false
        /// The page didn't answer within 2 s: it waits on a dialog it showed (spec 005 FR-432).
        var waiting = false
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
                waiting: f.count > 4 && f[4] == "true")
        }
    }

    /// Which tab is Claude's, or nil when none surely is (FR-403: better lose Claude's tab than
    /// use one of the Owner's). The tab at Claude's position with Claude's mark; or, while a page
    /// Claude loaded is loading (`navigating`; the new page has no mark yet), the tab at that
    /// position when the window has as many tabs as before and the tab shows the address Claude
    /// loaded; or, when tabs moved, a tab with Claude's mark at Claude's last address.
    static func pick(_ s: TabSurvey, remembered t: ClaudeTab, navigating: Bool) -> Int? {
        if let r = s.rows.first(where: { $0.index == t.index }) {
            if r.marked { return r.index }
            if navigating && r.loading && s.count == t.count { return r.index }
            // A page waiting on its own dialog answers no script, so it can't show the mark: it
            // is the tab where it was, as many tabs, at its last address (FR-432).
            if r.waiting && r.sameAddress && s.count == t.count { return r.index }
        }
        return s.rows.first { $0.index != t.index && $0.sameAddress && $0.marked }?.index
    }
}

/// The Owner's Safari, driven through Apple Events in a tab of the Owner's window or a window of
/// Claude's own (spec 005 plan D2, D6). Remembers which; never touches other tabs and windows.
actor SafariBrowser {
    enum Failure: Error, Equatable {
        case noWindow
        case javaScriptOff
        case elementMissing(String)
        case noOption(String)
        case moved
        /// The Owner's tab Claude was working in isn't surely there any more (FR-429).
        case tabGone
        /// The page waits on a dialog it showed before Latchkey's answers were in it (FR-432);
        /// `owners`: one of the Owner's tabs, not Claude's own.
        case dialogWaiting(owners: Bool)
        case failed(String)
    }

    let scripts: any ScriptRunner
    /// How the next scripts answer the page's own dialogs (FR-432): Cancel and no text unless
    /// Claude's action says otherwise.
    private var dialogAnswer = DialogAnswer()
    /// What the page's dialogs said since the last answer, told to Claude with it.
    private var dialogs: [String] = []

    /// Claude's answers for the dialogs of the action that follows; `answering(.init())` after it.
    func answering(_ a: DialogAnswer) { dialogAnswer = a }

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
    /// Claude's window, or the Owner's window that holds Claude's tab.
    private var window: String? {
        didSet {
            if window != oldValue { tabs = [] }  // another window's tabs never stand for this one
            remember()
        }
    }
    /// Set when Claude's page is a tab in `window` rather than the whole window.
    private var tab: ClaudeTab? { didSet { remember() } }
    /// The Owner's tab Claude works in, when not its own page (spec 005 FR-425, Toni 2026-11-03).
    /// Known as Claude's tab is (its window, position, count, address, and a mark of its own), and
    /// kept in memory only.
    private var picked: (window: String, tab: ClaudeTab)?
    /// The address of a picked tab whose page Safari let no script mark (an empty tab, Safari's
    /// own pages), as it was when picked: such a tab is known by it instead (plan D8). Never
    /// updated, so a navigation can't move it.
    private var pickedUnmarked: String?
    /// Set when this action lost the Owner's tab: the rest of it never falls back to Claude's own
    /// page (FR-429).
    private var lostPick = false
    /// The window and tab Claude works in now: the Owner's tab it picked, else its own page.
    private var workWindow: String? { picked?.window ?? window }
    private var workTab: ClaudeTab? { picked?.tab ?? tab }
    private func setWork(_ t: ClaudeTab) {
        if picked != nil { picked?.tab = t } else { tab = t }
    }
    /// When Claude last used its page (spec 005 FR-411).
    private var lastUse = Date() { didSet { remember() } }
    /// How long a page may take to load (plan D3).
    private let settleLimit: Duration
    private let memory: WindowMemory?
    private let place: @Sendable () -> BrowserPlace
    /// Records a Left Behind entry (spec 001 FR-640).
    private let note: @Sendable (String) -> Void
    /// Claude's own navigation in its tab: when it started and where to (the address Claude
    /// loaded, or where Claude's marked page said it was going). Not `lastUse`, which every Apple
    /// Event refreshes (security review, 2026-10-29).
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
    /// Whether this action may move Claude's page (a click, typing, back): only then may a note
    /// open the allowance (security review, 2026-10-29).
    private var mayNavigate = false
    /// How long after Claude's navigation started its tab may be unmarked.
    private var allowance: TimeInterval { Double(settleLimit.components.seconds) + 1 }

    /// `place` is read each time Claude opens a page; callers that don't say get a window of
    /// Claude's own, as before tabs (the app passes the Owner's setting).
    init(
        scripts: any ScriptRunner, settleLimit: Duration = .seconds(15), memory: WindowMemory? = nil,
        place: @escaping @Sendable () -> BrowserPlace = { .window },
        note: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.scripts = scripts
        self.settleLimit = settleLimit
        self.memory = memory
        self.place = place
        self.note = note
        // The window a Latchkey that quit was using, so it still closes when unused (FR-411; a
        // restart forgot it, live check 2026-10-29). Its id holds only in the same run of
        // Safari: after Safari restarts, the id may be one of the Owner's windows, so the page
        // is looked for again (`findRestored`).
        guard let memory, let saved = memory.load() else { return }
        if saved.safari == memory.safari() {
            window = saved.window
            tab = saved.tab
            lastUse = saved.lastUse
            tabs = saved.tabs ?? []
        } else {
            restored = saved
        }
    }

    private func remember() {
        guard let memory else { return }
        if let window, let safari = memory.safari() {
            restored = nil
            memory.save(
                WindowMemory.Saved(
                    window: window, lastUse: lastUse, safari: safari, tab: tab, tabs: tab == nil ? tabs : nil))
        } else if restored == nil {
            memory.save(nil)
        }
    }

    /// The addresses of Claude's own window's tabs, noted each minute: how the window is known
    /// again after Safari restarts and brings it back under a new id.
    private var tabs: [String] = []
    /// Claude's page from before Safari restarted, still to be looked for.
    private var restored: WindowMemory.Saved?
    /// Claude's own window as Safari brought it back: only ever closed, never used for Claude's
    /// pages, since it is known by its addresses alone (security review, 2026-10-29).
    private var orphan: (window: String, tabs: [String], lastUse: Date)?

    /// After Safari restarted (FR-411): Claude's own window is found again when exactly one open
    /// window has exactly its tabs, and none otherwise; tried in the first 5 minutes after Safari
    /// starts, then given up. Claude's tab in the Owner's window can't be told from the Owner's tabs
    /// once its mark is gone, so it is left alone and, when a tab shows Claude's last address,
    /// noted as lost (FR-418).
    private func findRestored(now: Date) async {
        guard let saved = restored, memory?.safari() != nil else { return }
        if let t = saved.tab {
            forgetRestored()
            if (try? await scripts.run(Script.anyTabAt, [t.address])) == "yes" {
                note(
                    "Latchkey lost track of Claude's Safari tab (\(t.address)) when Safari restarted. If it's still open, it stays open."
                )
            }
            return
        }
        // Only while Safari is bringing its windows back, so a window the Owner opens later with
        // the same tabs is never taken for Claude's (security review, 2026-10-29).
        guard let safari = memory?.safari(), let launched = WindowMemory.launched(safari),
            now.timeIntervalSince(launched) < 300
        else { return forgetRestored() }
        guard let tabs = saved.tabs, !tabs.isEmpty,
            let found = try? await scripts.run(Script.findWindow, [tabs.joined(separator: "\n")]),
            !found.isEmpty
        else { return }
        forgetRestored()
        orphan = (found, tabs, saved.lastUse)
    }

    /// Closes the window Safari brought back once 30 minutes have passed since Claude last used
    /// it, and only if it is still the one window with exactly those tabs; a window that changed
    /// is left open and noted.
    private func closeOrphan(after: TimeInterval, now: Date) async {
        guard let o = orphan, now.timeIntervalSince(o.lastUse) >= after else { return }
        orphan = nil
        let still = try? await scripts.run(Script.findWindow, [o.tabs.joined(separator: "\n")])
        guard still == o.window else {
            note(
                "Latchkey lost track of Claude's Safari window after Safari restarted (its tabs changed). If it's still open, it stays open."
            )
            return
        }
        _ = try? await scripts.run(Script.close, [o.window])
        note("Closed Claude's Safari window after \(Int(after / 60)) minutes unused (Safari had restarted)")
    }

    private func forgetRestored() {
        restored = nil
        if window == nil { memory?.save(nil) }
    }

    /// Notes the tabs of Claude's own window; forgets the window when the Owner closed it.
    private func noteTabs(_ id: String) async {
        guard let answer = try? await scripts.run(Script.tabAddresses, [id]), !answer.isEmpty else { return }
        if answer == "LATCHKEY_NO_WINDOW" {
            window = nil
            return
        }
        let now = answer.components(separatedBy: "\n")
        if now != tabs {
            tabs = now
            remember()
        }
    }

    /// For tests: as if Claude last used its page, and last navigated it, `seconds` earlier.
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

    /// Loads `url` in Claude's window (a new tab if asked), making the window if needed. A page
    /// that doesn't finish loading is an error naming what Safari still shows, never a read of
    /// the old page as if it were the new one (2026-10-25: Claude asked for an Amazon page and
    /// was given another page's text).
    func open(_ url: String, newTab: Bool) async throws -> PageScripts.Page {
        beginAction()
        let address = try Self.normalize(url)
        workInOwnPage()  // FR-426: Claude's pages open in its own tab or window
        await findRestored(now: Date())
        let wanted = place()
        if window != nil, (tab != nil) != (wanted == .tab) { await closeClaudesPage() }  // FR-417
        var before = try? await stamp()
        if wanted == .tab {
            if try await !loadInTab(address) {
                before = nil  // a new tab: any finished page in it is the new one
                let f = try await call(Script.tabNew, [address]).split(separator: "\t").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard f.count == 3, let index = Int(f[1]), let count = Int(f[2]) else {
                    throw Failure.failed("Safari reported a problem: it didn't say where the new tab is.")
                }
                window = f[0]
                tab = ClaudeTab(index: index, count: count, address: address, token: Self.newToken())
                navigated(to: address)
            }
        } else {
            window = try await call(Script.open, [address, window ?? "", newTab ? "yes" : "no"])
        }
        guard try await settle(after: before, expectNavigation: true) else {
            let shown = (try? await stamp())?.address ?? "an unknown page"
            throw Failure.failed(
                "Safari didn't finish loading \(address) within \(settleLimit.components.seconds) seconds; Claude's window still shows \(shown). Try again, or read the page as it is with browser_read."
            )
        }
        return try await readPage(offset: 0)
    }

    func read(offset: Int) async throws -> PageScripts.Page {
        beginAction()
        return try await readPage(offset: offset)
    }

    private func readPage(offset: Int) async throws -> PageScripts.Page {
        do {
            return try PageScripts.decode(try await javaScript(PageScripts.read(offset: offset)))
        } catch is DecodingError {
            throw Failure.failed("Safari reported a problem: the page didn't answer as expected.")
        }
    }

    func click(_ ref: String) async throws -> PageScripts.Page {
        beginAction(mayNavigate: true)
        let before = try? await stamp()
        try check(try await javaScript(PageScripts.click(ref), acting: true), ref: ref)
        _ = try await settle(after: before, expectNavigation: false)
        return try await readPage(offset: 0)
    }

    func type(_ ref: String, text: String, submit: Bool) async throws -> PageScripts.Page {
        beginAction(mayNavigate: true)
        let before = try? await stamp()
        try check(
            try await javaScript(PageScripts.type(ref, text: text, submit: submit), acting: true), ref: ref,
            option: text)
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

    func run(_ code: String) async throws -> String {
        beginAction()
        return try await javaScript(PageScripts.custom(code))
    }

    /// The tabs of a window of Claude's own (index, title, address) and which is showing;
    /// `select` switches that window to a tab first.
    private func windowTabs(_ id: String, select: Int?) async throws -> (current: Int, tabs: [(Int, String, String)]) {
        let out = try await call(Script.tabs, [id, select.map(String.init) ?? ""])
        var lines = out.split(separator: "\n", omittingEmptySubsequences: true)
        let current = lines.isEmpty ? 1 : Int(lines.removeFirst()) ?? 1
        let tabs = lines.map { line -> (Int, String, String) in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return (Int(f[0]) ?? 0, f.count > 1 ? f[1] : "", f.count > 2 ? f[2] : "")
        }
        return (current, tabs)
    }

    /// Every tab of every Safari window, front to back (FR-424), with Claude's own tab and the tab
    /// Claude works in. No script runs in any page for the list itself.
    func listTabs() async throws -> SafariTabList {
        beginAction()
        var list = SafariTabList(try await call(Script.allTabs, []))
        var claudes: (String, Int)?
        if let window {
            if tab != nil {
                if let found = try? await locate(claudes: true) { claudes = (found.window, found.tab.index) }
            } else if let w = list.windows.first(where: { $0.id == window }) {
                claudes = (window, w.tabs.first { $0.front }?.index ?? 1)
            }
        }
        if picked != nil { _ = try? await locate() }
        let working = picked.map { ($0.window, $0.tab.index) }
        for w in list.windows.indices {
            for t in list.windows[w].tabs.indices {
                let here = (list.windows[w].id, list.windows[w].tabs[t].index)
                list.windows[w].tabs[t].claudes = claudes.map { $0 == here } ?? false
                list.windows[w].tabs[t].working = working.map { $0 == here } ?? false
            }
        }
        return list
    }

    /// The tab Claude works in, as the list names it ("4213.2"), or nil for Claude's own page.
    func working() -> String? { picked.map { "\($0.window).\($0.tab.index)" } }

    /// Claude works in its own page again (FR-426).
    func workInOwnPage() {
        guard picked != nil else { return }
        picked = nil
        pickedUnmarked = nil
        navigation = nil
        noteOpened = nil
    }

    /// The Owner's tab is lost (FR-429): Claude works in its own page from the next action on.
    private func losePick() {
        workInOwnPage()
        lostPick = true
    }

    /// Makes Claude work in a tab from the list (FR-425): "4213.2" (window id, then tab number),
    /// or a bare number: that tab of the window that holds Claude's page, else of the front
    /// window. Claude's own tab, or a tab of Claude's own window (which then shows it, as before),
    /// is Claude's own page. Any other tab gets a mark of its own; nothing comes forward (FR-427).
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
        var id = parts.count == 2 ? String(parts[0]) : window
        if id == nil { id = SafariTabList(try await call(Script.allTabs, [])).windows.first?.id }
        guard let id else { throw Failure.failed("Safari has no window open.") }
        if id == window {
            if tab == nil {
                _ = try await windowTabs(id, select: number)  // Claude's own window shows that tab
                workInOwnPage()
                return
            }
            if let found = try? await locate(claudes: true), found.tab.index == number {
                workInOwnPage()
                return
            }
        }
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
        workInOwnPage()
        picked = (id, ClaudeTab(index: number, count: count, address: String(f[2]), token: token))
        pickedUnmarked = f[1] == "yes" ? nil : String(f[2])
    }

    /// Closes the Owner's tab Claude works in (FR-428), through the same check as any action
    /// (FR-429); then Claude works in its own page again. Its address, or nil when Claude works in
    /// its own page.
    func closeWorking() async throws -> String? {
        beginAction()
        guard picked != nil else { return nil }
        // Tabs may move between finding the tab and closing it: the script checks again, and
        // Latchkey finds the tab again once.
        for attempt in 1...2 {
            let found = try await locate(navigating: false)
            do {
                _ = try await call(Script.tabClose, replacingArguments(found))
                workInOwnPage()
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

    /// Runs `code` in Claude's page. `acting`: Claude's click, typing, or back, whose script may
    /// answer the address it sends the page to on a second line (taken here, not returned), and
    /// after which the acting AppleScript waits a moment for the page's note of where it is going.
    private func javaScript(_ code: String, acting: Bool = false) async throws -> String {
        if lostPick { throw Failure.tabGone }
        guard let window = workWindow else { throw Failure.noWindow }
        let answering = PageScripts.dialogAnswers(dialogAnswer)
        guard workTab != nil else {
            let out = try await call(Script.javaScript, [window, answering + code, PageScripts.takeDialogs])
            let both = out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            heard(both.first ?? "[]")
            let result = both.count > 1 ? both[1] : ""
            return acting ? String(result.prefix { $0 != "\n" }) : result
        }
        // Safari's tabs may move between finding Claude's tab and using it: the script checks
        // again before acting, and Latchkey finds the tab again once.
        for attempt in 1...2 {
            let found = try await locate()
            if found.waiting { throw Failure.dialogWaiting(owners: picked != nil) }
            do {
                let out = try await call(
                    Script.tabJavaScript,
                    guardArguments(found) + [
                        answering + PageScripts.tabMark(found.tab.token) + PageScripts.inTab(code),
                        PageScripts.takeDestination, acting ? "yes" : "no", PageScripts.takeDialogs,
                    ])
                var parts = out.split(separator: "\n", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                if parts.count > 2 { heard(parts.remove(at: 2)) }
                // The site to compare a note with is the one the tab showed before the script.
                let before = workTab?.address
                if let address = parts.first, !address.isEmpty, var t = workTab {
                    t.address = address
                    setWork(t)
                }
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
                // Claude's own page said it is going to another page (a click, a form, back).
                take(notes: notes, here: before, clicked: clicked, clickedAnySite: unchanged)
                return answer
            } catch Failure.moved where attempt == 1 {
                continue
            }
        }
        throw Failure.moved
    }

    /// Claude's tab as found, and the addresses an unmarked tab in its place may show (empty
    /// unless a page Claude loaded is loading).
    struct Found {
        var window: String
        var tab: ClaudeTab
        var loading: [String]
        /// The page waits on its own dialog (FR-432): it can be loaded over or closed, not read.
        var waiting = false
    }

    /// The addresses Claude's tab may show unmarked now: those of Claude's own navigation, while
    /// it is recent, in their usual spellings (http or https, with or without www. and a final /).
    private var loadingAddresses: [String] {
        guard let navigation, Date().timeIntervalSince(navigation.since) < allowance else { return [] }
        return Self.spellings(of: navigation.addresses)
    }

    /// Claude's tab in the Owner's window, found again (plan D6). When no tab surely is Claude's,
    /// Latchkey forgets it, notes that it lost track of it, and Claude is told its page is gone.
    /// `navigating: false` allows only a marked tab (closing).
    /// `claudes`: Claude's own tab even while Claude works in one of the Owner's. The Owner's tab
    /// is also taken while it shows the address Latchkey last saw there (a page Safari lets no
    /// script into can't carry the mark; plan D8); when it isn't surely found, Claude stops
    /// working in it and is told to list the tabs again (FR-429).
    private func locate(navigating: Bool = true, claudes: Bool = false) async throws -> Found {
        let owners = picked != nil && !claudes
        guard let window = owners ? picked?.window : window, var t = owners ? picked?.tab : tab else {
            throw Failure.noWindow
        }
        var loading = navigating ? loadingAddresses : []
        if owners, let fixed = pickedUnmarked, !fixed.isEmpty, !fixed.contains("\n"), !loading.contains(fixed) {
            loading.append(fixed)
        }
        let survey = TabSurvey(
            try await call(
                Script.tabSurvey,
                [window, String(t.index), t.address, PageScripts.tabCheck(t.token), loading.joined(separator: "\n")]))
        guard let index = TabSurvey.pick(survey, remembered: t, navigating: !loading.isEmpty) else {
            if owners {
                losePick()
                throw Failure.tabGone
            }
            lost()
            throw Failure.noWindow
        }
        t.index = index
        t.count = survey.count
        if owners { picked?.tab = t } else { tab = t }
        let waiting = survey.rows.first { $0.index == index }?.waiting ?? false
        return Found(window: window, tab: t, loading: loading, waiting: waiting)
    }

    private func lost() {
        window = nil
        tab = nil
        navigation = nil
        note(
            "Latchkey lost track of Claude's Safari tab (it was closed, or moved while its page changed). If it's still open, it stays open."
        )
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

    /// Loads `address` in Claude's tab, if Latchkey still finds one. False when not.
    private func loadInTab(_ address: String) async throws -> Bool {
        guard tab != nil else { return false }
        let found: Found
        do { found = try await locate() } catch Failure.noWindow { return false }
        _ = try await call(Script.tabLoad, replacingArguments(found) + [address])
        tab?.address = address
        navigated(to: address)
        return true
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

    /// Closes Claude's tab or window, whichever it has: the setting changed (FR-417).
    private func closeClaudesPage() async {
        if tab != nil {
            if let found = try? await locate(navigating: false, claudes: true) {
                _ = try? await call(Script.tabClose, replacingArguments(found))
            }
        } else if let window {
            _ = try? await scripts.run(Script.close, [window])
        }
        window = nil
        tab = nil
        navigation = nil
    }

    /// What a picture of Claude's page would take (spec 005 FR-423): whether Claude's tab must
    /// first come to the front of the Owner's window, the title that window shows now, and the
    /// page's address. Claude's own window needs no switch.
    func pictureSwitch() async throws -> (needed: Bool, shownTitle: String, address: String) {
        guard workTab != nil else { return (false, "", "") }
        let found = try await locate()
        let f = try await call(Script.tabFront, guardArguments(found)).trimmingCharacters(in: .newlines).split(
            separator: "\t", maxSplits: 2, omittingEmptySubsequences: false
        ).map(String.init)
        guard f.count == 3 else { throw Failure.failed("Safari answered: \(f.joined(separator: " "))") }
        return (f[0] != "true", f[1], f[2])
    }

    /// Shows Claude's page for a screenshot (spec 006 FR-509): `body` gets the title Safari's
    /// window then shows. In a tab of the Owner's window, Claude's tab comes to the front for the
    /// shot and the tab the Owner had in front comes back afterwards, also when the shot failed
    /// (FR-415); a tab the Owner switched to meanwhile stays.
    func showing<T: Sendable>(_ body: @Sendable (String) async throws -> T) async throws -> T {
        beginAction()
        guard workTab != nil else {
            guard let window else { throw Failure.noWindow }
            let t = try await windowTabs(window, select: nil)
            return try await body(t.tabs.first { $0.0 == t.current }?.1 ?? "")
        }
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

    /// Closes Claude's tab or window when Claude asks (2026-11-01); a tab Latchkey can't surely
    /// find is left open, as when idle. True when Claude had a page.
    func closePage() async -> Bool {
        let had = window != nil
        await closeClaudesPage()
        return had
    }

    /// Closes Claude's tab or window once it has gone `after` unused (FR-411), and notes it for
    /// the Left Behind list. True when it closed one, or found its tab gone.
    func closeIfIdle(after: TimeInterval = 1800, now: Date = Date()) async -> Bool {
        await findRestored(now: now)
        await closeOrphan(after: after, now: now)
        // FR-425: an Owner's tab unused this long is only forgotten, never closed.
        if picked != nil, now.timeIntervalSince(lastUse) >= after { workInOwnPage() }
        guard let id = window else { return false }
        guard now.timeIntervalSince(lastUse) >= after else {
            if tab == nil { await noteTabs(id) }
            return false
        }
        let minutes = Int(after / 60)
        if tab != nil {
            // A tab Latchkey can't surely find isn't closed: it might be the Owner's now.
            if let found = try? await locate(navigating: false, claudes: true) {
                do {
                    _ = try await call(Script.tabClose, guardArguments(found))
                    note("Closed Claude's Safari tab after \(minutes) minutes unused")
                } catch {
                    lost()
                }
            }
            window = nil
            tab = nil
            navigation = nil
            return true
        }
        window = nil
        _ = try? await scripts.run(Script.close, [id])
        note("Closed Claude's Safari window after \(minutes) minutes unused")
        return true
    }

    private func call(_ script: String, _ args: [String]) async throws -> String {
        lastUse = Date()
        do { return try await scripts.run(script, args) } catch ScriptError.failed(let message) {
            if message.contains("LATCHKEY_NO_WINDOW") {
                // The window the script named is gone: the Owner's tab Claude works in, Claude's
                // own page, or both.
                let gone = args.first
                let wasPicked = picked != nil && picked?.window == gone
                if wasPicked { losePick() }
                if window == gone {
                    window = nil
                    tab = nil
                }
                throw wasPicked ? Failure.tabGone : Failure.noWindow
            }
            if message.contains("LATCHKEY_MOVED") { throw Failure.moved }
            if message.contains("LATCHKEY_DIALOG_WAITING") { throw Failure.dialogWaiting(owners: picked != nil) }
            if message.contains("Allow JavaScript from Apple Events") { throw Failure.javaScriptOff }
            throw Failure.failed("Safari reported a problem: \(message)")
        } catch ScriptError.timedOut where SystemScreen().isLocked() {
            // Seen live 2026-11-01: with the Mac locked, Safari stops answering scripts after a page.
            throw Failure.failed(
                "Safari stopped answering while the Mac is locked. It answers again once someone unlocks the Mac."
            )
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
        /// argv: window id, script, the script that takes what the page's dialogs said. Answers
        /// the dialogs (JSON), then the script's result.
        static let javaScript = """
            on run argv
            set winID to (item 1 of argv) as integer
            tell application "Safari"
            if not (exists window id winID) then error "LATCHKEY_NO_WINDOW"
            set t to current tab of window id winID
            try
            with timeout of 2 seconds
            do JavaScript "1" in t
            end timeout
            on error number errNum
            if errNum is -1712 then error "LATCHKEY_DIALOG_WAITING"
            end try
            set theAnswer to do JavaScript (item 2 of argv) in t
            if theAnswer is missing value then set theAnswer to ""
            set theDialogs to "[]"
            try
            with timeout of 2 seconds
            set theDialogs to (do JavaScript (item 3 of argv) in t) as text
            end timeout
            end try
            return theDialogs & linefeed & (theAnswer as text)
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
        /// argv: Claude's own window id. Its tabs' addresses, one per line.
        static let tabAddresses = """
            on run argv
            set winID to (item 1 of argv) as integer
            tell application "Safari"
            if not (exists window id winID) then return "LATCHKEY_NO_WINDOW"
            if not (visible of window id winID) then return "LATCHKEY_NO_WINDOW"
            set theAddresses to URL of every tab of window id winID
            end tell
            set out to ""
            repeat with theAddress in theAddresses
            if out is not "" then set out to out & linefeed
            if theAddress is not missing value then set out to out & theAddress
            end repeat
            return out
            end run
            """
        /// argv: addresses, one per line. The id of the one visible window whose tabs are exactly
        /// these, or "" when none or more than one; nothing else of the Owner's windows.
        static let findWindow = """
            on run argv
            set wanted to item 1 of argv
            set found to {}
            tell application "Safari"
            repeat with w in windows
            try
            if visible of w then
            set theAddresses to URL of every tab of w
            set out to ""
            repeat with theAddress in theAddresses
            if out is not "" then set out to out & linefeed
            if theAddress is not missing value then set out to out & theAddress
            end repeat
            if out is wanted then set end of found to ((id of w) as text)
            end if
            end try
            end repeat
            end tell
            if (count of found) is 1 then return item 1 of found
            return ""
            end run
            """
        /// argv: an address. "yes" when some open tab shows it, else "no".
        static let anyTabAt = """
            on run argv
            set wanted to item 1 of argv
            tell application "Safari"
            repeat with w in windows
            try
            if visible of w then
            repeat with t in tabs of w
            if (URL of t) is wanted then return "yes"
            end repeat
            end if
            end try
            end repeat
            end tell
            return "no"
            end run
            """
        static let close = """
            on run argv
            set winID to (item 1 of argv) as integer
            tell application "Safari"
            if (exists window id winID) then close window id winID
            end tell
            end run
            """
        /// argv: window id, Claude's tab index, Claude's last address, the yes/no mark check.
        /// Answers the tab count, then per tab "index, same address, marked" (TabSurvey). The
        /// check runs only in the tab at Claude's position and tabs at Claude's address, and only
        /// says yes or no.
        static let tabSurvey = """
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
            with timeout of 2 seconds
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
            set out to out & (i as text) & sep & (sameURL as text) & sep & (isMarked as text) & sep & (isLoading as text) & sep & (isWaiting as text) & linefeed
            end repeat
            return out
            end tell
            end run
            """
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
            with timeout of 2 seconds
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
            "on run argv\n" + tabGuard + "\n"
                + """
                if waiting then error "LATCHKEY_DIALOG_WAITING"
                set theAnswer to do JavaScript (item 6 of argv) in t
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
        /// argv: the guard's five, url.
        static let tabLoad =
            "on run argv\n" + tabGuard + "\n"
                + """
                set URL of t to (item 6 of argv)
                return ""
                end tell
                end run
                """
        /// argv: url. A new tab at the end of the Owner's front Safari window, behind the tab the
        /// Owner has in front (FR-413); a new window when Safari has none (FR-414). Answers
        /// "window id<TAB>tab index<TAB>tab count".
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
            set beforeIDs to id of every window
            make new document with properties {URL:theURL}
            repeat 50 times
            repeat with w in windows
            if (id of w) is not in beforeIDs then return ((id of w) as text) & sep & "1" & sep & ((count of tabs of w) as text)
            end repeat
            delay 0.1
            end repeat
            error "Safari didn't show the new window."
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
            with timeout of 2 seconds
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

/// Where Claude's Safari window (or tab) is kept across restarts of Latchkey: a small file in its support
/// folder (research.md). `safari` names the running Safari, by process id and launch time.
struct WindowMemory: Sendable {
    struct Saved: Codable, Equatable, Sendable {
        var window: String
        var lastUse: Date
        var safari: String
        /// Claude's tab in that window, when its page is a tab (FR-412); none in older files.
        var tab: ClaudeTab?
        /// The addresses of Claude's own window's tabs, to find it after Safari restarts.
        var tabs: [String]?
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

    /// When that Safari started, from `safari`'s "pid launch-time".
    static func launched(_ safari: String) -> Date? {
        safari.split(separator: " ").last.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
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
        var claudes = false
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
