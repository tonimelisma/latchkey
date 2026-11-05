// Latchkey's real SafariBrowser against the real Safari (spec 005 plan D6, research.md
// "Real Safari check"): checks the stand-in Safari of the unit tests can't make. Run by
// scripts/safari-check.sh, from a program that may control Safari (a terminal), not from the
// test host, which would need its own Automation approval. Works only in a Safari window it
// opens for the purpose, in front so Claude's tab opens there, and closes it afterwards; the
// Owner's tabs are only listed (titles and addresses, not printed), and read only with
// LATCHKEY_READ_OWNER_TAB=1 (counts and the host printed); nothing of the Owner's is clicked,
// typed into, or closed. Needs the network and Safari's
// "Allow JavaScript from Apple Events". Exit code 0 when every check passed.
import AppKit
import Foundation

let runner = OSAScriptRunner()
var failures: [String] = []

@MainActor func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok: \(what)" : "  FAILED: \(what)")
    if !ok { failures.append(what) }
}

final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [String] = []
    var all: [String] { lock.withLock { made } }
    func add(_ s: String) { lock.withLock { made.append(s) } }
}

@MainActor func openWindow() async throws -> String {
    try await runner.run(
        """
        on run argv
        tell application "Safari"
        set beforeIDs to id of every window
        make new document with properties {URL:"about:blank"}
        repeat 50 times
        repeat with w in windows
        if (id of w) is not in beforeIDs then return (id of w) as text
        end repeat
        delay 0.1
        end repeat
        error "no window"
        end tell
        end run
        """, [])
}

@MainActor func tabCount(_ id: String) async -> Int {
    let n = try? await runner.run(
        """
        on run argv
        tell application "Safari"
        if not (exists window id ((item 1 of argv) as integer)) then return "0"
        return (count of tabs of window id ((item 1 of argv) as integer)) as text
        end tell
        end run
        """, [id])
    return n.flatMap { Int($0) } ?? 0
}

/// Runs `body` with a browser whose tab is in a window of the check's own; closes the window.
@MainActor func withTab(_ name: String, _ body: (SafariBrowser, Notes) async throws -> Void) async {
    // LATCHKEY_CHECK_ONLY=text runs only the checks whose name contains it.
    if let only = ProcessInfo.processInfo.environment["LATCHKEY_CHECK_ONLY"], !name.contains(only) { return }
    print(name)
    let before = await windowIDs()
    let opened: String?
    do { opened = try await openWindow() } catch {
        print("  \(error)")
        opened = nil
    }
    guard let window = opened else {
        check(false, "\(name): couldn't open a window of the check's own")
        await closeLate(before)
        return
    }
    let notes = Notes()
    let b = SafariBrowser(scripts: runner, place: { .tab }, note: { notes.add($0) })
    currentWindow = window
    do { try await body(b, notes) } catch { check(false, "\(name): \(error)") }
    _ = try? await runner.run(SafariBrowser.Script.close, [window])
    var gone = false
    for _ in 0..<50 where !gone {
        gone = !(await windowIDs()).contains(window)
        if !gone { try? await Task.sleep(for: .milliseconds(200)) }
    }
    check(gone, "\(name): the check's window is closed")
}

/// The ids of Safari's windows.
@MainActor func windowIDs() async -> Set<String> {
    let out = (try? await runner.run("tell application \"Safari\" to return id of every window", [])) ?? ""
    return Set(out.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
}

/// A window the check asked for may appear after its wait gave up (Safari is slow while the Mac
/// is locked; seen 2026-11-05): each new window whose tabs are all blank (or that has none) is
/// closed, for up to a minute, and the check fails loudly if one stays. A new window showing a
/// real page isn't the check's: it is left alone and named by its id.
@MainActor func closeLate(_ before: Set<String>) async {
    let blank = """
        on run argv
        tell application "Safari"
        set w to window id ((item 1 of argv) as integer)
        repeat with t in tabs of w
        set u to URL of t
        if u is not missing value and u is not "about:blank" then return "page"
        end repeat
        close w
        return "closed"
        end tell
        end run
        """
    var left: Set<String> = []
    for _ in 0..<30 {
        left = (await windowIDs()).subtracting(before)
        for id in left { _ = try? await runner.run(blank, [id]) }
        try? await Task.sleep(for: .seconds(2))
        left = (await windowIDs()).subtracting(before)
        if left.isEmpty { break }
    }
    check(left.isEmpty, "no window of the check's left behind (still open: \(left.sorted()))")
}

var currentWindow = ""

/// Opens Claude's first page; it must be a tab in the check's own window, or the check stops
/// (closing Claude's tab wherever it went: it never works in the Owner's).
@MainActor func open(_ b: SafariBrowser, _ url: String) async throws -> PageScripts.Page {
    let page = try await b.open(url, newTab: false)
    guard await tabCount(currentWindow) == 2 else {
        _ = await b.closeIfIdle(after: 0)
        throw SafariBrowser.Failure.failed("Claude's tab didn't open in the check's own window")
    }
    return page
}

let article = "https://en.wikipedia.org/wiki/Mac_mini"

@MainActor func ref(_ page: PageScripts.Page, _ match: (String) -> Bool) throws -> String {
    guard let r = page.elements.first(where: { $0.kind == "link" && match($0.href ?? "") })?.ref else {
        throw SafariBrowser.Failure.failed("no such link on \(page.url)")
    }
    return r
}

await withTab("A same-site click keeps Claude's tab") { b, notes in
    let first = try await open(b, article)
    check(first.url.contains("wikipedia.org/wiki/Mac"), "opened \(first.url)")
    let next = try await b.click(try ref(first) { $0.hasSuffix("/wiki/Mac_Studio") })
    check(next.url.hasSuffix("/wiki/Mac_Studio"), "the click's answer is the new page (\(next.url))")
    let again = try await b.read(offset: 0)
    check(again.url.hasSuffix("/wiki/Mac_Studio"), "the new page reads (\(again.url))")
    let tabs = try await b.listTabs().windows.flatMap(\.tabs)
    check(tabs.first { $0.claudes }?.address.hasSuffix("/wiki/Mac_Studio") == true, "tabs lists it as Claude's")
    let back = try await b.back()
    check(back.url.contains("/wiki/Mac_") && !back.url.hasSuffix("/wiki/Mac_Studio"), "back (\(back.url))")
    let redirect = try await b.click(try ref(back) { $0.hasSuffix("/wiki/Mac_Pro") || $0.hasSuffix("/wiki/IMac") })
    check(redirect.url.contains("/wiki/"), "a second click (\(redirect.url))")
    _ = try await b.read(offset: 0)
    check(notes.all.isEmpty, "nothing lost: \(notes.all)")
}

// A script of Claude's never opens the allowance (security review, fourth round, 2026-10-29).
await withTab("A script that sends the page elsewhere loses Claude's tab, as designed") { b, notes in
    _ = try await open(b, article)
    _ = try await b.run("location.href = 'https://en.wikipedia.org/wiki/Mac_Studio'; 'ok'")
    var lost = false
    for _ in 0..<20 where !lost {
        do { _ = try await b.read(offset: 0) } catch SafariBrowser.Failure.noWindow { lost = true }
        if !lost { try await Task.sleep(for: .milliseconds(500)) }
    }
    check(lost, "Latchkey no longer uses the tab")
    check(notes.all.contains { $0.contains("lost track") }, "noted as lost")
}

await withTab("A cross-site click keeps Claude's tab (since 2026-11-01)") { b, notes in
    let first = try await open(b, "https://en.wikipedia.org/wiki/Example.com")
    let r = try ref(first) { $0.hasPrefix("https://example.com") || $0.hasPrefix("http://example.com") }
    let page = try await b.click(r)
    check(page.url.contains("example.com") && !page.url.contains("wikipedia"), "the new page reads: \(page.url)")
    let again = try await b.read(offset: 0)
    check(again.url.contains("example.com") && !again.url.contains("wikipedia"), "and reads again")
    check(!notes.all.contains { $0.contains("lost track") }, "not lost")
}

await withTab("A long page comes in parts") { b, _ in
    let first = try await open(b, article)
    let a0 = PageScripts.answer(first)
    check(a0.count <= ResultLimit.characters, "the first part is \(a0.count) characters")
    guard let match = a0.firstMatch(of: /offset (\d+)\.\)/), let next = Int(match.output.1) else {
        check(false, "the first part names where to read on")
        return
    }
    let second = try await b.read(offset: next)
    let a1 = PageScripts.answer(second)
    check(a1.count <= ResultLimit.characters, "the second part is \(a1.count) characters")
    check(second.offset == next && !second.text.isEmpty && second.text != first.text, "offset \(next) reads on")
    print("  page \(first.total) characters, \(first.elements.count) links and buttons; read on at \(next)")
}

@MainActor func frontTab(_ id: String) async -> Int {
    let n = try? await runner.run(
        """
        on run argv
        tell application "Safari"
        return (index of current tab of window id ((item 1 of argv) as integer)) as text
        end tell
        end run
        """, [id])
    return n.flatMap { Int($0) } ?? 0
}

// 2026-11-03 (spec 005 FR-424 to FR-431): the check's own window's first tab plays one of the
// Owner's tabs: Claude lists it, works in it in the background, and closes it.
await withTab("Another tab is listed, read, clicked, and closed in the background") { b, notes in
    _ = try await open(b, "https://en.wikipedia.org/wiki/Example.com")
    _ = try await runner.run(
        """
        on run argv
        tell application "Safari" to set URL of tab 1 of window id ((item 1 of argv) as integer) to (item 2 of argv)
        end run
        """, [currentWindow, article])
    try await Task.sleep(for: .seconds(4))
    let list = try await b.listTabs()
    let mine = list.windows.first { $0.id == currentWindow }
    check(
        mine?.tabs.count == 2,
        "the check's window is listed with both tabs (\(mine?.tabs.map { "\($0.index) \($0.address)" } ?? []))")
    check(mine?.tabs.first?.front == true && mine?.tabs.last?.claudes == true, "front tab and Claude's tab named")
    try await b.pick("\(currentWindow).1")
    let read = try await b.read(offset: 0)
    check(read.url.lowercased().contains("/wiki/mac_mini"), "the other tab reads (\(read.url))")
    let next = try await b.click(try ref(read) { $0.hasSuffix("/wiki/Mac_Studio") })
    check(next.url.hasSuffix("/wiki/Mac_Studio"), "a click in it (\(next.url))")
    let back = try await b.back()
    check(back.url.lowercased().contains("/wiki/mac_mini"), "back in it (\(back.url))")
    check(await frontTab(currentWindow) == 1, "the tab in front stayed in front")
    check(await b.working() == "\(currentWindow).1", "still working in it")
    let closed = try await b.closeWorking()
    check(closed?.lowercased().contains("/wiki/mac_mini") == true, "closed it (\(closed ?? "nothing"))")
    check(await tabCount(currentWindow) == 1, "only Claude's tab is left")
    check(try await b.read(offset: 0).url.contains("Example.com"), "Claude works in its own tab again")
    check(notes.all.isEmpty, "nothing noted: \(notes.all)")
}

// 2026-11-05 (spec 005 FR-433 to FR-439): keys, hover, scrolling, lists, files in and out, and
// the copy a picture is drawn from, on the check's own local page (served from 127.0.0.1 by
// safari-check.sh; nothing is sent anywhere), in Claude's background tab: the check window's
// front tab stays in front and Safari doesn't come forward. Every file saved to Downloads is
// removed in the teardown, which runs also when a check throws, and the check fails if any
// is left.
@MainActor func element(_ p: PageScripts.Page, _ kind: String, _ label: String) throws -> String {
    guard let e = p.elements.first(where: { $0.kind.hasPrefix(kind) && $0.label.contains(label) }) else {
        throw SafariBrowser.Failure.failed("no \(kind) \"\(label)\" on \(p.url): \(p.elements.map { "\($0.kind) \($0.label)" })")
    }
    return e.ref
}

final class Saved: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL] = []
    func add(_ u: URL) { lock.withLock { files.append(u) } }
    var all: [URL] { lock.withLock { files } }
}

if let pages = ProcessInfo.processInfo.environment["LATCHKEY_PAGES"] {
    let saved = Saved()
    let downloadsBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: BrowserDownloads.downloads.path)) ?? [])
    await withTab("Keys, hover, scrolling, lists, files, and the picture copy, in a background tab") { b, notes in
        let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var page = try await open(b, pages + "/actions.html")
        check(page.title == "Latchkey check actions", "opened the local page (\(page.url))")
        @MainActor func stillBehind(_ what: String) async {
            check(await frontTab(currentWindow) == 1, "\(what): the tab in front stayed in front")
        }
        // Keys.
        let name = try element(page, "field:text", "Name")
        var done = try await b.press(try ["l", "k", "Enter"].map(PageScripts.Key.init), ref: name)
        check(done.page.title == "sent:lk", "typed keys and Enter sent the form (\(done.page.title))")
        done = try await b.press([try PageScripts.Key("Escape")], ref: nil)
        check(!done.page.text.contains("An open panel"), "Escape reached the page's own handler")
        done = try await b.press([try PageScripts.Key("Tab")], ref: name)
        check(done.detail.contains("moved the focus"), "Tab moved the focus (\(done.detail))")
        done = try await b.press([try PageScripts.Key("cmd+a"), try PageScripts.Key("Backspace")], ref: name)
        check(try await b.run("document.getElementById('name').value") == "", "cmd+a and Backspace cleared the field")
        check(done.page.text.contains("cmd+a"), "the page heard cmd+a")
        await stillBehind("keys")
        // Lists.
        page = try await b.read(offset: 0)
        done = try await b.choose(try element(page, "choice", "Small"), options: ["Large"])
        check(try await b.run("document.getElementById('size').value") == "l", "chose Large (\(done.detail))")
        done = try await b.choose(try element(page, "choice", "Cheese"), options: ["Cheese", "Olives"])
        check(done.detail.contains("Cheese") && done.detail.contains("Olives"), "chose two in a list that takes several")
        done = try await b.choose(try element(page, "combobox", "Pick a color"), options: ["Blue"])
        check(done.page.text.contains("picked:blue"), "chose from a list the page builds itself")
        do {
            _ = try await b.choose(try element(page, "choice", "Large"), options: ["Purple"])
            check(false, "an option that isn't there is refused")
        } catch SafariBrowser.Failure.noOption(let said) {
            check(said.contains("Medium"), "an option that isn't there names those there are")
        }
        // Hover.
        done = try await b.hover(try element(page, "div", "Products menu"))
        check(done.page.elements.contains { $0.label == "Hidden product" }, "hover opened the menu (\(done.detail) more)")
        // Scrolling.
        done = try await b.scroll(nil, direction: "down", amount: 500)
        check(done.detail.contains("\"y\":500"), "the page scrolled 500 pixels (\(done.detail))")
        done = try await b.scroll(try element(page, "scrollable", "Inside"), direction: "bottom", amount: nil)
        check(done.detail.contains("\"element\":true") && !done.detail.contains("\"y\":0,"), "the box scrolled to its bottom (\(done.detail))")
        done = try await b.scroll(nil, direction: "top", amount: nil)
        check(done.detail.contains("\"y\":0"), "back to the top")
        await stillBehind("lists, hover, scroll")
        // Files into the page: a small one, and one too big for a program's arguments.
        let small = PageScripts.Attachment(name: "latchkey-check-upload.txt", type: "text/plain", data: Data("uploaded by the check".utf8))
        done = try await b.attach(try element(page, "field:file", "Attach"), files: [small])
        try await Task.sleep(for: .milliseconds(300))
        var log = try await b.run("document.getElementById('filelog').textContent")
        check(log.contains("latchkey-check-upload.txt=21:uploaded by the check"), "a file field got the file (\(log))")
        let big = PageScripts.Attachment(name: "latchkey-check-big.bin", type: "application/octet-stream", data: Data(repeating: 65, count: 3_000_000))
        done = try await b.attach(try element(page, "field:file", "Attach"), files: [big])
        try await Task.sleep(for: .milliseconds(500))
        log = try await b.run("document.getElementById('filelog').textContent")
        check(log.contains("latchkey-check-big.bin=3000000"), "a 3 MB file went in (\(log.suffix(80)))")
        done = try await b.attach(try element(page, "button", "Drop files"), files: [small])
        check(done.detail.contains("dropped"), "dropped on a drop place (\(done.detail))")
        check(done.page.text.contains("dropped: latchkey-check-upload.txt"), "the page took the dropped file")
        await stillBehind("files in")
        // Files out of the page: a link, a file the page made, a 3 MB file, and a PDF the tab shows.
        @MainActor func save(_ ref: String?, _ url: String? = nil) async throws -> (URL, String) {
            let got = try await b.fetchFile(ref: ref, url: url, maxBytes: BrowserDownloads.pageLimit)
            guard got.fetched.state == "done", let b64 = got.fetched.b64, let data = Data(base64Encoded: b64) else {
                throw SafariBrowser.Failure.failed("fetch \(got.fetched.state) \(got.fetched.error ?? "")")
            }
            let name = BrowserDownloads.name(disposition: got.fetched.disposition, suggested: got.suggested, address: got.fetched.final ?? got.address, type: got.fetched.type)
            let file = try BrowserDownloads.save(data, name: name, from: got.address)
            saved.add(file)
            return (file, String(decoding: data.prefix(64), as: UTF8.self))
        }
        var (file, text) = try await save(try element(page, "link", "Save the text file"))
        check(file.lastPathComponent == "latchkey-check-download.txt" && text.hasPrefix("Latchkey check download"), "saved a link's file to \(file.path)")
        (file, text) = try await save(try element(page, "link", "Save a file the page makes"))
        check(file.lastPathComponent == "latchkey-check-blob.txt" && text == "made by the page", "saved a file the page made (\(file.lastPathComponent))")
        (file, _) = try await save(nil, pages + "/files/latchkey-check-big.bin")
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        check(size == 3_000_000, "saved a 3 MB file (\(size) bytes)")
        // The picture copy holds what Claude typed and chose.
        _ = try await b.type(name, text: "picture me", submit: false)
        let copy = try await b.pictureCopy()
        check(copy.html.contains("value=\"picture me\"") && copy.html.contains("<base"), "the copy for a picture holds the page as it is")
        await stillBehind("files out")
        // The PDF, opened in Claude's tab, saved as the page itself.
        _ = try? await b.open(pages + "/files/latchkey-check.pdf", newTab: false)
        do {
            (file, text) = try await save(nil)
            check(file.lastPathComponent == "latchkey-check.pdf" && text.hasPrefix("%PDF"), "saved the PDF the tab shows")
        } catch {
            check(false, "saving the PDF the tab shows: \(error)")
        }
        check(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == frontApp, "the app in front stayed in front (\(frontApp ?? "?"))")
        check(notes.all.isEmpty, "nothing lost: \(notes.all)")
    }
    // Teardown: every saved file goes, then nothing new may be left in Downloads.
    for f in saved.all { try? FileManager.default.removeItem(at: f) }
    let left = Set((try? FileManager.default.contentsOfDirectory(atPath: BrowserDownloads.downloads.path)) ?? []).subtracting(downloadsBefore)
    check(left.isEmpty, "no file of the check left in Downloads (\(left.sorted()))")
}

// Reading only (2026-11-03): with LATCHKEY_READ_OWNER_TAB=1, lists the Owner's real tabs and
// reads one of them; prints only counts and the host, nothing of the page.
if ProcessInfo.processInfo.environment["LATCHKEY_READ_OWNER_TAB"] == "1" {
    print("The Owner's tabs are listed and one is read (reading only)")
    let b = SafariBrowser(scripts: runner, place: { .tab })
    do {
        let list = try await b.listTabs()
        let tabs = list.windows.flatMap(\.tabs)
        check(!tabs.isEmpty, "\(list.windows.count) windows, \(tabs.count) tabs listed")
        let hidden = tabs.first { !$0.front && $0.address.hasPrefix("https://") }
        if let t = hidden ?? tabs.first(where: { $0.address.hasPrefix("https://") }) {
            let fronts = list.windows.map { w in w.tabs.first { $0.front }?.index ?? 0 }
            try await b.pick(t.reference)
            let page = try await b.read(offset: 0)
            let host = URL(string: page.url)?.host() ?? "?"
            check(page.total > 0, "read tab \(t.reference) (\(t.front ? "in front" : "behind another")) on \(host): \(page.total) characters, \(page.elements.count) links and fields")
            let after = try await b.listTabs().windows.map { w in w.tabs.first { $0.front }?.index ?? 0 }
            check(after == fronts, "every window's front tab stayed in front")
        } else {
            check(false, "no web page among the Owner's tabs")
        }
    } catch {
        check(false, "reading the Owner's tab: \(error)")
    }
}

print(failures.isEmpty ? "All Safari checks passed." : "\(failures.count) Safari check(s) failed.")
exit(failures.isEmpty ? 0 : 1)
