// Latchkey's real SafariBrowser against the real Safari (spec 005 plan D6, research.md
// "Real Safari check"): checks the stand-in Safari of the unit tests can't make. Run by
// scripts/safari-check.sh, from a program that may control Safari (a terminal), not from the
// test host, which would need its own Automation approval. Works only in a Safari window it
// opens for the purpose, in front so Claude's tab opens there, and closes it afterwards; the
// Owner's windows and tabs are never read or touched. Needs the network and Safari's
// "Allow JavaScript from Apple Events". Exit code 0 when every check passed.
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
    print(name)
    let opened: String?
    do { opened = try await openWindow() } catch {
        print("  \(error)")
        opened = nil
    }
    guard let window = opened else {
        check(false, "\(name): couldn't open a window of the check's own")
        return
    }
    let notes = Notes()
    let b = SafariBrowser(scripts: runner, place: { .tab }, note: { notes.add($0) })
    currentWindow = window
    do { try await body(b, notes) } catch { check(false, "\(name): \(error)") }
    _ = try? await runner.run(SafariBrowser.Script.close, [window])
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
    let tabs = try await b.tabs(select: nil)
    check(tabs.tabs.first?.2.hasSuffix("/wiki/Mac_Studio") == true, "tabs lists it")
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

print(failures.isEmpty ? "All Safari checks passed." : "\(failures.count) Safari check(s) failed.")
exit(failures.isEmpty ? 0 : 1)
