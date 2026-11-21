import Foundation
import Testing
import WebKit

@testable import Latchkey

/// Spec 013 FR-1350 to FR-1355: Latchkey signs in itself where it holds a password, so Safari
/// stays signed in; it keeps those sign-ins; a site where that can't finish falls back to Safari's.
@MainActor @Suite struct OwnSessionsTests {
    static let imported = Date(timeIntervalSince1970: 1_800_000_000)
    static let a = SavedSignIn(title: "A", site: "a.test", user: "ann", password: "pw-a", otp: nil)
    static let g = SavedSignIn(title: "G", site: "accounts.g.test", user: "gil", password: "pw-g", otp: nil)

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        /// The real time, for pages whose cookies WebKit dates by it.
        static func live() -> Clock {
            let c = Clock()
            c.now = Date()
            return c
        }
    }

    static func sessions(
        _ logins: [SavedSignIn] = [a, g], vault: MemoryVault = MemoryVault(), clock: Clock = Clock(), on: Bool = true
    ) throws -> (OwnSessions, SignInStore, MemoryVault) {
        let store = SignInStore(vault: MemoryVault())
        try store.replace(with: logins, at: imported)
        let s = OwnSessions(signIns: store, vault: vault, now: { clock.now })
        s.on = { on }
        return (s, store, vault)
    }

    static func cookie(
        _ domain: String, _ name: String = "sid", _ value: String = "v1", expires: Date? = nil, httpOnly: Bool = true
    ) -> HTTPCookie {
        var p: [HTTPCookiePropertyKey: Any] = [
            .domain: domain, .path: "/", .name: name, .value: value, .secure: "TRUE",
        ]
        if let expires { p[.expires] = expires }
        if httpOnly { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: p)!
    }

    @Test func theSitesWithAPasswordAreLatchkeysOwn() throws {
        let (s, _, _) = try Self.sessions()
        #expect(s.isOwn("a.test") && s.isOwn("www.a.test") && s.isOwn("accounts.g.test"))
        #expect(!s.isOwn("b.test") && !s.isOwn("g.test") && !s.isOwn("evil-a.test"))
        #expect(s.ownSite("www.a.test") == "a.test")
        // A cookie reaches an own site from the site, under it, or a wider domain of it.
        #expect(s.reaches(".a.test") && s.reaches("x.a.test") && s.reaches(".g.test") && s.reaches("accounts.g.test"))
        #expect(!s.reaches("b.test") && !s.reaches("other.g.test") && !s.reaches("evil-a.test"))
    }

    @Test func whileSignInIsOffNothingIsOwn() throws {
        let (s, _, _) = try Self.sessions(on: false)
        #expect(!s.isOwn("a.test") && !s.reaches(".a.test"))
        s.keep([Self.cookie("a.test")])
        #expect(s.kept().isEmpty)
    }

    @Test func keepsOnlyCookiesThatReachAnOwnSite() throws {
        let (s, _, vault) = try Self.sessions()
        let later = Self.imported.addingTimeInterval(30 * 86400)
        s.keep([Self.cookie("a.test", expires: later), Self.cookie(".g.test", "SID"), Self.cookie("b.test")])
        let kept = s.kept().map { "\($0.domain) \($0.name)" }.sorted()
        #expect(kept == [".g.test SID", "a.test sid"])
        #expect(vault.items[OwnSessions.account] != nil)
        // Nothing changed: nothing written.
        let writes = vault.changes.count
        s.keep([Self.cookie("a.test", expires: later), Self.cookie(".g.test", "SID"), Self.cookie("b.test")])
        #expect(vault.changes.count == writes)
        // A cookie the site took away goes.
        s.keep([Self.cookie(".g.test", "SID")])
        #expect(s.kept().map(\.name) == ["SID"])
    }

    @Test func expiredAndOldSessionCookiesGo() throws {
        let clock = Clock()
        let (s, _, _) = try Self.sessions(clock: clock)
        s.keep([
            Self.cookie("a.test", "short", expires: Self.imported.addingTimeInterval(3600)),
            Self.cookie("a.test", "session"),
        ])
        #expect(s.kept().count == 2)
        clock.now = Self.imported.addingTimeInterval(2 * 3600)
        #expect(s.kept().map(\.name) == ["session"])
        // Unchanged, the session cookie keeps the day it was first kept: 14 days at most.
        s.keep([Self.cookie("a.test", "session")])
        clock.now = Self.imported.addingTimeInterval(15 * 86400)
        #expect(s.kept().isEmpty)
    }

    @Test func aKeptCookieComesBackWhole() throws {
        let (s, _, vault) = try Self.sessions()
        let later = Self.imported.addingTimeInterval(86400)
        s.keep([Self.cookie("a.test", "sid", "secret-v", expires: later)])
        // Another copy of the app reads what this one kept (a restart).
        let store = SignInStore(vault: MemoryVault())
        try store.replace(with: [Self.a], at: Self.imported)
        let again = OwnSessions(signIns: store, vault: vault, now: { Self.imported })
        again.on = { true }
        let c = try #require(again.kept().first)
        #expect(c.name == "sid" && c.value == "secret-v" && c.domain == "a.test" && c.isSecure && c.isHTTPOnly)
        #expect(c.expiresDate == later)
    }

    @Test func aFallenBackSiteIsSafarisUntilTheNextExport() throws {
        let (s, store, _) = try Self.sessions()
        s.keep([Self.cookie("a.test"), Self.cookie(".g.test", "SID")])
        s.fallBack("a.test")
        #expect(!s.isOwn("a.test") && s.fellBack("a.test") && s.isOwn("accounts.g.test"))
        #expect(s.kept().map(\.name) == ["SID"], "its kept sign-in goes")
        try store.replace(with: [Self.a, Self.g], at: Self.imported.addingTimeInterval(60))
        #expect(s.isOwn("a.test") && !s.fellBack("a.test"), "the next export tries Latchkey's own again")
    }

    @Test func aFallbackCoversEverySignInUnderTheSameName() throws {
        let n = SavedSignIn(title: "N", site: "na.account.a.test", user: "ann", password: "pw", otp: nil)
        let (s, _, _) = try Self.sessions([Self.a, n, Self.g])
        #expect(s.fallBack("a.test") == ["a.test", "na.account.a.test"])
        #expect(!s.isOwn("na.account.a.test") && !s.reaches(".a.test") && s.isOwn("accounts.g.test"))
    }

    @Test func aFallbackKeptBeforeTheWholeSiteRuleCoversItToo() throws {
        let n = SavedSignIn(title: "N", site: "na.account.a.test", user: "ann", password: "pw", otp: nil)
        let vault = MemoryVault()
        let old = OwnSessions.Contents(cookies: [], fellBack: ["a.test"], fellBackFor: Self.imported)
        vault.items[OwnSessions.account] = try JSONEncoder().encode(old)
        let (s, _, _) = try Self.sessions([Self.a, n], vault: vault)
        #expect(!s.isOwn("na.account.a.test") && !s.reaches(".a.test"))
    }

    @Test func registeredNames() {
        #expect(PublicSuffix.registrable("na.account.amazon.com") == "amazon.com")
        #expect(PublicSuffix.registrable("amazon.com") == "amazon.com")
        #expect(PublicSuffix.registrable("www.bbc.co.uk") == "bbc.co.uk")
        #expect(PublicSuffix.registrable("app.herokuapp.com") == "app.herokuapp.com")
    }

    @Test func anUnreadableItemIsNeverWrittenOver() throws {
        let vault = MemoryVault()
        vault.items[OwnSessions.account] = Data("{}".utf8)
        vault.unreadable = [OwnSessions.account]
        let (s, _, _) = try Self.sessions(vault: vault)
        s.keep([Self.cookie("a.test")])
        s.fallBack("a.test")
        #expect(vault.changes.isEmpty)
    }

    @Test func removeAllDeletesTheItem() throws {
        let (s, _, vault) = try Self.sessions()
        s.keep([Self.cookie("a.test")])
        s.removeAll()
        #expect(vault.items[OwnSessions.account] == nil && s.kept().isEmpty)
    }
}

/// The browser's side (FR-1350, FR-1351, FR-1353 to FR-1355), on the real WebKit view.
@MainActor @Suite struct OwnSessionsBrowserTests {
    nonisolated static func safari(_ domain: String, _ name: String, _ value: String) -> SafariCookies.Cookie {
        SafariCookies.Cookie(
            domain: domain, name: name, path: "/", value: value, secure: true, httpOnly: false,
            expires: Date().addingTimeInterval(30 * 86400))
    }

    nonisolated static let safariCookies = [
        safari("a.test", "safari_a", "1"), safari(".g.test", "safari_g", "1"), safari("b.test", "safari_b", "1"),
    ]

    func pages(locked: Bool, sessions: OwnSessions) -> OwnPages {
        OwnPages(cookies: { Self.safariCookies }, isLocked: { locked }, record: { _ in }, sessions: sessions)
    }

    func cookies(_ own: OwnPages, _ name: String) async throws -> String {
        try await own.page(name).run("document.cookie")
    }

    @Test func noCopyOfSafarisCookiesReachesAnOwnSite() async throws {
        let (s, _, _) = try OwnSessionsTests.sessions(clock: .live())
        let own = pages(locked: true, sessions: s)
        defer { own.closeAll() }
        let a = try await own.open(html: "<p>a</p>", base: URL(string: "https://www.a.test/")!)
        #expect(try await cookies(own, a) == "", "no copy for a site Latchkey signs in to itself")
        let www = try await own.open(html: "<p>g</p>", base: URL(string: "https://www.g.test/")!)
        #expect(!(try await cookies(own, www)).contains("safari_g"), "nor a wider domain's cookie that reaches one")
        let b = try await own.open(html: "<p>b</p>", base: URL(string: "https://b.test/")!)
        #expect(try await cookies(own, b).contains("safari_b"), "other sites take Safari's while locked, as before")
    }

    @Test func whileUnlockedAnOwnSiteStaysInLatchkeysBrowser() throws {
        let (s, _, _) = try OwnSessionsTests.sessions(clock: .live())
        let signedIn = [
            SafariCookies.Cookie(
                domain: "a.test", name: "session", path: "/", value: "x", secure: true, httpOnly: true,
                expires: Date().addingTimeInterval(30 * 86400)),
            SafariCookies.Cookie(
                domain: "b.test", name: "session", path: "/", value: "x", secure: true, httpOnly: true,
                expires: Date().addingTimeInterval(30 * 86400)),
        ]
        let own = OwnPages(cookies: { signedIn }, isLocked: { false }, record: { _ in }, sessions: s)
        #expect(!own.inSafari("https://a.test/account"), "Latchkey signs in there itself")
        #expect(own.inSafari("https://b.test/account"), "a site with no saved password: the owner's Safari, as before")
    }

    @Test func keptSignInsComeBackInANewStore() async throws {
        let (s, _, _) = try OwnSessionsTests.sessions(clock: .live())
        s.keep([
            OwnSessionsTests.cookie(
                "a.test", "own_a", "kept", expires: Date().addingTimeInterval(86400), httpOnly: false)
        ])
        let own = pages(locked: false, sessions: s)
        defer { own.closeAll() }
        let a = try await own.open(html: "<p>a</p>", base: URL(string: "https://a.test/")!)
        #expect(try await cookies(own, a) == "own_a=kept")
    }

    @Test func whatTheSiteSetsIsKept() async throws {
        let (s, _, _) = try OwnSessionsTests.sessions(clock: .live())
        let own = pages(locked: false, sessions: s)
        defer { own.closeAll() }
        let a = try await own.open(html: "<p>a</p>", base: URL(string: "https://a.test/")!)
        _ = try await own.page(a).run("document.cookie = 'own_a=set; max-age=86400; path=/; secure'; 'ok'")
        #expect(try await cookies(own, a) == "own_a=set", "the page set it")
        var kept: [HTTPCookie] = []
        for _ in 0..<40 where kept.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            kept = s.kept()
        }
        #expect(kept.map(\.name) == ["own_a"])
    }

    @Test func unlockingDropsOnlyTheCopies() async throws {
        let (s, _, _) = try OwnSessionsTests.sessions(clock: .live())
        final class Lock: @unchecked Sendable { var on = true }
        let lock = Lock()
        let own = OwnPages(cookies: { Self.safariCookies }, isLocked: { lock.on }, record: { _ in }, sessions: s)
        defer { own.closeAll() }
        let b = try await own.open(html: "<p>b</p>", base: URL(string: "https://b.test/")!)
        let a = try await own.open(html: "<p>a</p>", base: URL(string: "https://a.test/")!)
        _ = try await own.page(a).run("document.cookie = 'own_a=mine; max-age=86400; path=/; secure'; 'ok'")
        #expect(try await cookies(own, b).contains("safari_b"))
        lock.on = false
        await own.forgetCopiesIfUnlocked()
        #expect(try await cookies(own, b) == "", "the copy of Safari's went")
        #expect(try await cookies(own, a) == "own_a=mine", "Latchkey's own sign-in stayed")
    }

    /// Security review 2026-11-21: a copy of Safari's taken while a site wasn't Latchkey's own
    /// (before an export named it, or after a fallback) is never kept once it becomes own.
    @Test func aCopyTakenBeforeTheSiteBecameOwnIsNeverKept() async throws {
        let store = SignInStore(vault: MemoryVault())
        try store.replace(with: [OwnSessionsTests.a], at: OwnSessionsTests.imported)
        let s = OwnSessions(signIns: store, vault: MemoryVault())
        s.on = { true }
        let own = pages(locked: true, sessions: s)
        defer { own.closeAll() }
        let b = try await own.open(html: "<p>b</p>", base: URL(string: "https://b.test/")!)
        #expect(try await cookies(own, b).contains("safari_b"), "b.test isn't Latchkey's own yet: a copy")
        // The next export holds a password for b.test too.
        try store.replace(
            with: [OwnSessionsTests.a, SavedSignIn(title: "B", site: "b.test", user: "bo", password: "pw", otp: nil)],
            at: OwnSessionsTests.imported.addingTimeInterval(60))
        #expect(s.isOwn("b.test"))
        // The store took a copy for b.test: nothing of b.test from it is kept, whatever its name
        // (a site may renew a copied session under a new one).
        _ = try await own.page(b).run("document.cookie = 'own_b=mine; max-age=86400; path=/; secure'; 'ok'")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(!s.kept().contains { $0.domain.contains("b.test") }, "\(s.kept().map(\.name))")
        // A new store (no copy in it; unlocked, so none is taken) keeps what the site sets.
        own.closeAll()
        let fresh = pages(locked: false, sessions: s)
        defer { fresh.closeAll() }
        let again = try await fresh.open(html: "<p>b</p>", base: URL(string: "https://b.test/")!)
        _ = try await fresh.page(again).run("document.cookie = 'own_b=fresh; max-age=86400; path=/; secure'; 'ok'")
        var kept: [String] = []
        for _ in 0..<40 where kept.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            kept = s.kept().map(\.name)
        }
        #expect(kept == ["own_b"])
    }

    @Test func aCopyForASiteNeverDropsWhatWasKeptThere() throws {
        let (s, _, _) = try OwnSessionsTests.sessions(clock: .live())
        s.keep([OwnSessionsTests.cookie("a.test", "own_a", "kept", expires: Date().addingTimeInterval(86400))])
        s.keep([OwnSessionsTests.cookie("a.test", "own_a", "other")], copied: ["a.test"])
        #expect(s.kept().map(\.value) == ["kept"])
    }

    @Test func theAnswerSaysLatchkeySignsInItself() async throws {
        let (s, _, _) = try OwnSessionsTests.sessions(clock: .live())
        let own = pages(locked: false, sessions: s)
        defer { own.closeAll() }
        let a = try await own.open(html: "<p>a</p>", base: URL(string: "https://a.test/")!)
        let site = try own.page(a).ownSite
        #expect(site == "a.test")
        let line = BrowserCapability.ownBrowser(a, signedIn: false, own: site)
        #expect(
            line.contains("with Latchkey's own sign-in for a.test") && !line.contains("without the owner's sign-ins"))
    }
}
