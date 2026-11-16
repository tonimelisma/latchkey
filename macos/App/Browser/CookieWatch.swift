import Foundation
import WebKit

/// What Claude's pages in Latchkey's own browser did with sign-ins, for Latchkey's log (spec 005
/// FR-453, FR-454; Toni, 2026-11-15: Target signed Safari out after Claude's page used a copy of
/// its cookies, and nothing recorded what that page did). Each copy of Safari's cookies is one
/// line: the site, how many were set, the sign-in cookies among them, and how long before Safari
/// had last written its cookie file (a copy is only as new as that file). Each time a site
/// replaces, removes, or adds a sign-in cookie in the shared store, one line per site. Names and
/// times only: a value is never logged (FR-421).
@MainActor
final class CookieWatch: NSObject, WKHTTPCookieStoreObserver {
    /// The sign-in cookies the store holds, as last seen: pure, so tests check it without WebKit.
    struct Seen {
        struct Entry {
            var value: String
            /// Still the value taken from Safari (not one the site set since).
            var fromSafari: Bool
        }

        /// One site's changes: replaced and removed (Safari's or the site's own), new.
        struct Told {
            var replacedSafari: [String] = [], replaced: [String] = []
            var removedSafari: [String] = [], removed: [String] = []
            var new: [String] = []
        }

        private(set) var held: [String: Entry] = [:]

        /// The same cookie whatever form its domain takes (".a.example" or "a.example").
        static func key(_ c: HTTPCookie) -> String { "\(site(c.domain))\t\(c.path)\t\(c.name)" }
        static func site(_ domain: String) -> String {
            domain.hasPrefix(".") ? String(domain.dropFirst()).lowercased() : domain.lowercased()
        }

        mutating func note(_ cookies: [HTTPCookie], fromSafari: Bool) {
            for c in cookies where CookieWatch.isSignIn(name: c.name, httpOnly: c.isHTTPOnly) {
                held[Self.key(c)] = Entry(value: c.value, fromSafari: fromSafari)
            }
        }

        /// The changes since last seen, one line per site, and `now` remembered.
        mutating func changes(now: [HTTPCookie]) -> [String] {
            var current: [String: (site: String, name: String, value: String)] = [:]
            for c in now where CookieWatch.isSignIn(name: c.name, httpOnly: c.isHTTPOnly) {
                current[Self.key(c)] = (Self.site(c.domain), c.name, c.value)
            }
            var told: [String: Told] = [:]
            func add(_ site: String, _ change: (inout Told) -> Void) { change(&told[site, default: Told()]) }
            var next: [String: Entry] = [:]
            for (key, was) in held {
                let parts = key.split(separator: "\t", omittingEmptySubsequences: false)
                let site = String(parts.first ?? ""), name = String(parts.last ?? "")
                guard let now = current[key] else {
                    add(site) { was.fromSafari ? $0.removedSafari.append(name) : $0.removed.append(name) }
                    continue
                }
                if now.value == was.value {
                    next[key] = was
                } else {
                    add(site) { was.fromSafari ? $0.replacedSafari.append(name) : $0.replaced.append(name) }
                    next[key] = Entry(value: now.value, fromSafari: false)
                }
            }
            for (key, now) in current where held[key] == nil {
                add(now.site) { $0.new.append(now.name) }
                next[key] = Entry(value: now.value, fromSafari: false)
            }
            held = next
            return told.keys.sorted().map { site in
                let t = told[site]!
                var parts: [String] = []
                func names(_ n: [String]) -> String { n.sorted().joined(separator: ", ") }
                if !t.replacedSafari.isEmpty { parts.append("replaced Safari's \(names(t.replacedSafari))") }
                if !t.replaced.isEmpty { parts.append("replaced \(names(t.replaced))") }
                if !t.removedSafari.isEmpty { parts.append("removed Safari's \(names(t.removedSafari))") }
                if !t.removed.isEmpty { parts.append("removed \(names(t.removed))") }
                if !t.new.isEmpty { parts.append("new: \(names(t.new))") }
                return "\(site) changed sign-in cookies in Claude's pages: " + parts.joined(separator: "; ")
            }
        }
    }

    /// A sign-in cookie: HttpOnly (only a server sets those; page scripts' analytics cookies
    /// can't be), or named for a token (some sites keep an ID token readable by their scripts).
    nonisolated static func isSignIn(name: String, httpOnly: Bool) -> Bool {
        httpOnly || name.range(of: "token", options: .caseInsensitive) != nil
    }

    /// The line for one copy of Safari's cookies into Claude's pages; nil when none was set.
    nonisolated static func copyLine(site: String, set: [HTTPCookie], fileAge: TimeInterval?) -> String? {
        guard !set.isEmpty else { return nil }
        let signIn = Set(set.filter { isSignIn(name: $0.name, httpOnly: $0.isHTTPOnly) }.map(\.name)).sorted()
        let shown =
            signIn.prefix(12).joined(separator: ", ") + (signIn.count > 12 ? ", and \(signIn.count - 12) more" : "")
        let age = fileAge.map { "written \(Self.age($0)) before" } ?? "age unknown"
        return "Claude's page took \(set.count) of Safari's cookies for \(site) (Safari's cookie file \(age)); "
            + (signIn.isEmpty ? "no sign-in cookies" : "sign-in cookies: \(shown)")
    }

    nonisolated static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 90 { return "\(Int(s)) s" }
        if s < 90 * 60 { return "\(Int(s / 60)) min" }
        if s < 48 * 3600 { return "\(Int(s / 3600)) h" }
        return "\(Int(s / 86400)) days"
    }

    private var seen = Seen()
    private let store: WKHTTPCookieStore
    private let record: @Sendable (String) -> Void
    private var looking = false

    init(store: WKHTTPCookieStore, record: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.record = record
        super.init()
        store.add(self)  // held weakly by the store
    }

    /// Called once a copy of Safari's cookies is in the store (`LockedBrowser`).
    func copied(site: String, set: [HTTPCookie], fileAge: TimeInterval?) {
        if let line = Self.copyLine(site: site, set: set, fileAge: fileAge) { record(line) }
        seen.note(set, fromSafari: true)
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.look() }
    }

    /// One look at the store for changes arriving together (a page sets several at once).
    private func look() {
        guard !looking else { return }
        looking = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            looking = false
            guard let all = await LockedBrowser.holding(store) else { return }
            for line in seen.changes(now: all) { record(line) }
        }
    }

    func stop() { store.remove(self) }
}
