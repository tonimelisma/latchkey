import Foundation

/// Latchkey's own sign-ins (spec 013 FR-1350 to FR-1354; plan D10): the sites Latchkey holds a
/// saved sign-in for take no copy of the Owner's Safari cookies, so a site renewing a copy never
/// signs Safari out; Latchkey signs in there itself, and keeps the cookies those sites set (its own
/// sign-ins) in a Keychain item of its own, across restarts. A site where Latchkey's own sign-in
/// couldn't finish falls back to Safari's sign-in until the next export.
@MainActor
final class OwnSessions {
    static let account = "sign-in sessions"
    static let shared = OwnSessions(signIns: .shared, vault: KeychainVault())

    /// A cookie kept: what a browser needs to send it again, and when it was first kept.
    struct Kept: Codable, Equatable, Sendable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Date?
        var secure: Bool
        var httpOnly: Bool
        var sameSite: String?
        var kept: Date

        var key: String { OwnSessions.key(domain, path, name) }

        init(_ c: HTTPCookie, kept: Date) {
            name = c.name
            value = c.value
            domain = c.domain
            path = c.path
            expires = c.expiresDate
            secure = c.isSecure
            httpOnly = c.isHTTPOnly
            sameSite = c.sameSitePolicy?.rawValue
            self.kept = kept
        }

        var cookie: HTTPCookie? {
            var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
            if let expires { p[.expires] = expires }
            if secure { p[.secure] = "TRUE" }
            if httpOnly { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let sameSite { p[.sameSitePolicy] = sameSite }
            return HTTPCookie(properties: p)
        }
    }

    /// What is kept. An item written while sites could fall back to Safari's sign-in (`fellBack`,
    /// withdrawn FR-1352) still reads: the extra keys are left out (Toni, 2026-11-22: "Decide
    /// fresh each time").
    struct Contents: Codable, Equatable {
        var cookies: [Kept] = []
    }

    /// A cookie with no expiry is kept this long at most (FR-1353).
    static let sessionLimit: TimeInterval = 14 * 86400

    private let signIns: SignInStore
    private let vault: any PairingVault
    private let now: () -> Date
    /// Whether Sign-in is On (FR-1354: while Off, no site is an own one). The app sets it at
    /// start; until then (and in tests, which never reach the Owner's real sign-ins) it is Off.
    var on: () -> Bool = { false }
    private var cached: Contents?
    /// The own sites, worked out once per export.
    private var sitesFor: (imported: Date, sites: [String])?

    init(signIns: SignInStore, vault: any PairingVault, now: @escaping () -> Date = Date.init) {
        self.signIns = signIns
        self.vault = vault
        self.now = now
    }

    /// The same cookie whatever form its domain takes.
    nonisolated static func key(_ domain: String, _ path: String, _ name: String) -> String {
        "\(bare(domain))\t\(path)\t\(name)"
    }

    nonisolated static func key(of c: HTTPCookie) -> String { key(c.domain, c.path, c.name) }

    nonisolated static func bare(_ domain: String) -> String {
        var d = domain.lowercased()
        if d.hasPrefix(".") { d.removeFirst() }
        if d.hasSuffix(".") { d.removeLast() }
        return d
    }

    /// What the item holds; nil when it is there but can't be read now, which is never taken for
    /// "nothing kept" (`.claude/rules`): nothing is written over it then.
    private func contents() -> Contents? {
        if let cached { return cached }
        switch vault.lookup(Self.account) {
        case .absent: return Contents()
        case .unreadable: return nil
        case .found(let data):
            guard let c = try? JSONDecoder().decode(Contents.self, from: data) else { return nil }
            cached = c
            return c
        }
    }

    private func save(_ c: Contents) {
        guard let data = try? JSONEncoder().encode(c), (try? vault.write(data, Self.account)) != nil else { return }
        cached = c
    }

    /// The sites Latchkey signs in to itself: those it holds a sign-in for; none while Sign-in is
    /// Off.
    func sites() -> [String] {
        guard on(), case .some(let held) = signIns.load() else { return [] }
        if let s = sitesFor, s.imported == held.imported { return s.sites }
        let sites = Set(held.logins.map(\.site)).sorted()
        sitesFor = (held.imported, sites)
        return sites
    }

    /// FR-1350, FR-1351: whether `host` is a site Latchkey signs in to itself.
    func isOwn(_ host: String) -> Bool {
        let h = Self.bare(host)
        guard !h.isEmpty else { return false }
        return sites().contains { SiteMatch.fills(site: $0, on: "https://\(h)/") }
    }

    /// The own site `host` belongs to, if any (for what Claude is told, FR-1355).
    func ownSite(_ host: String) -> String? {
        let h = Self.bare(host)
        guard !h.isEmpty else { return nil }
        return sites().first { SiteMatch.fills(site: $0, on: "https://\(h)/") }
    }

    /// FR-1350: whether a cookie of `domain` reaches an own site: the domain is one, is under one,
    /// or is a wider domain of one (".google.com" reaches accounts.google.com).
    func reaches(_ domain: String) -> Bool {
        let d = Self.bare(domain)
        guard !d.isEmpty else { return false }
        let mine = SiteMatch.registered(d)
        return sites().contains {
            $0 == d || $0.hasSuffix("." + d) || d.hasSuffix("." + $0)
                || (mine != nil && SiteMatch.registered($0) == mine)
        }
    }

    /// FR-1353: keeps the cookies of `all` (what the store holds now) that reach an own site, in
    /// place of those kept before; writes only on a change. `copied`: the domains a copy of
    /// Safari's cookies went to in the store: no cookie related to one is kept (the same domain,
    /// under it, or a wider one), whatever its name.
    func keep(_ all: [HTTPCookie], copied: Set<String> = []) {
        func tainted(_ domain: String) -> Bool {
            let d = Self.bare(domain)
            return copied.contains { $0 == d || $0.hasSuffix("." + d) || d.hasSuffix("." + $0) }
        }
        guard !sites().isEmpty, var c = contents() else { return }
        let before = Dictionary(c.cookies.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let at = now()
        var fresh = all.filter { reaches($0.domain) && !tainted($0.domain) }.compactMap { cookie -> Kept? in
            var k = Kept(cookie, kept: at)
            // An unchanged cookie keeps when it was first kept, for the 14 days of FR-1353.
            if let was = before[k.key], was.value == k.value { k.kept = was.kept }
            return expired(k.expires, kept: k.kept, at: at) ? nil : k
        }
        // What was kept for a site this store took a copy for stays as it was kept: the store's
        // cookies there can't be told apart from the copy's.
        fresh += c.cookies.filter { tainted($0.domain) && !expired($0.expires, kept: $0.kept, at: at) }
        fresh.sort { $0.key < $1.key }
        guard fresh != c.cookies.sorted(by: { $0.key < $1.key }) else { return }
        c.cookies = fresh
        save(c)
    }

    /// The kept sign-ins to set in a new store: still reaching an own site, not expired.
    func kept() -> [HTTPCookie] {
        let at = now()
        return (contents()?.cookies ?? []).filter { reaches($0.domain) && !expired($0.expires, kept: $0.kept, at: at) }
            .compactMap(\.cookie)
    }

    private func expired(_ expires: Date?, kept: Date, at: Date) -> Bool {
        if let expires { return expires <= at }
        return at.timeIntervalSince(kept) > Self.sessionLimit
    }

    /// FR-1354: Remove All and uninstalling.
    func removeAll() {
        vault.delete(Self.account)
        cached = nil
        sitesFor = nil
    }
}
