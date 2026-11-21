import Foundation
import Testing

@testable import Latchkey

/// Spec 013 FR-1320, FR-1323 to FR-1326, FR-1340: the two Sign-in tools, through their handlers,
/// on real WebKit pages of Claude's.
@MainActor @Suite struct SignInToolsTests {
    static let base = URL(string: "https://a.test/login")!

    func store(_ logins: [SavedSignIn]) throws -> SignInStore {
        let s = SignInStore(vault: MemoryVault())
        try s.replace(with: logins, at: Date(timeIntervalSince1970: 1_800_000_000))
        return s
    }

    func pages() -> OwnPages { OwnPages(cookies: { [] }, isLocked: { true }, record: { _ in }) }

    @Test func offMeansNeitherToolExists() {
        var levels = CapabilityRegistry.defaultLevels
        let on = CapabilityRegistry(capabilities: AppModel.makeCapabilities(), levels: levels)
        #expect(on.tools.contains { $0.name == "logins_find" } && on.tools.contains { $0.name == "logins_sign_in" })
        levels[CapabilityRegistry.logins] = .off
        let off = CapabilityRegistry(capabilities: AppModel.makeCapabilities(), levels: levels)
        #expect(!off.tools.contains { $0.name.hasPrefix("logins_") })
        #expect(CapabilityRegistry.defaultLevels[CapabilityRegistry.logins] == .readWrite, "On by default")
    }

    @Test func findListsSitesAndUserNamesNeverSecrets() async throws {
        let s = try store([
            SignInStoreTests.a, SignInStoreTests.b,
            SavedSignIn(title: "G", site: "github.com", user: "toni", password: "gh-secret", otp: SignInPageTests.otp),
        ])
        let find = LoginsCapability.find(store: s)
        let all = await find.handler(.object([:])).plainText
        #expect(all.contains("a.test — ann") && all.contains("github.com — toni (has a verification code)"))
        #expect(!all.contains("pw-a") && !all.contains("gh-secret") && !all.contains("GEZDGNBV"))
        let one = await find.handler(.object(["site": .string("https://github.com/login")])).plainText
        #expect(one.contains("github.com") && !one.contains("a.test"))
        // Totals, and codes said either way (feedback report, 2026-11-21).
        #expect(all.contains("3 sign-ins for 3 sites; 1 with a verification code"), "\(all)")
        let noCodes = await LoginsCapability.find(store: try store([SignInStoreTests.a])).handler(.object([:]))
            .plainText
        #expect(noCodes.contains("1 sign-in for 1 site; none has a verification code in Passwords."), "\(noCodes)")
        let empty = await LoginsCapability.find(store: SignInStore(vault: MemoryVault())).handler(.object([:]))
        #expect(empty.plainText.contains("no sign-ins yet"))
    }

    @Test func signsInOnClaudesPage() async throws {
        let own = pages()
        defer { own.closeAll() }
        let name = try await own.open(html: SignInPageTests.onePage(), base: Self.base)
        let s = try store([SignInPageTests.ann])
        let r = await LoginsCapability.signIn(store: s, own: own).handler(.object(["page": .string(name)]))
        #expect(!r.isError, "\(r.plainText)")
        #expect(r.plainText.contains("Signed in to a.test as ann."))
        #expect(r.plainText.contains("From Latchkey's own browser"))
        #expect(!r.plainText.contains(SignInPageTests.ann.password))
        #expect(r.activity == "Signed in to a.test as ann")
    }

    @Test func noSignInForTheSiteIsSaidAtOnce() async throws {
        let own = pages()
        defer { own.closeAll() }
        let name = try await own.open(html: SignInPageTests.onePage(), base: URL(string: "https://other.test/")!)
        let r = await LoginsCapability.signIn(store: try store([SignInStoreTests.a]), own: own).handler(
            .object(["page": .string(name)]))
        #expect(r.isError && r.plainText.contains("no saved sign-in for other.test") && r.plainText.contains("a.test"))
    }

    /// The page's own script can't pass for the site whose sign-in it wants.
    @Test func aPageCantClaimAnotherSitesAddress() async throws {
        let own = pages()
        defer { own.closeAll() }
        let html = """
            <script>var real = JSON.stringify; JSON.stringify = function (v) { if (v && 'password' in v) v.address = 'https://a.test/login'; return real(v); };</script>
            """ + SignInPageTests.onePage()
        let name = try await own.open(html: html, base: URL(string: "https://evil.example/login")!)
        let r = await LoginsCapability.signIn(store: try store([SignInPageTests.ann]), own: own).handler(
            .object(["page": .string(name)]))
        #expect(r.isError && r.plainText.contains("no saved sign-in for evil.example"))
    }

    @Test func severalUserNamesAskWhich() async throws {
        let own = pages()
        defer { own.closeAll() }
        let name = try await own.open(html: SignInPageTests.onePage(), base: URL(string: "https://b.test/")!)
        let tool = LoginsCapability.signIn(store: try store([SignInStoreTests.b, SignInStoreTests.b2]), own: own)
        let r = await tool.handler(.object(["page": .string(name)]))
        #expect(r.isError && r.plainText.contains("bob") && r.plainText.contains("bea") && r.plainText.contains("user"))
        let wrong = await tool.handler(.object(["page": .string(name), "user": .string("carl")]))
        #expect(wrong.isError && wrong.plainText.contains("no saved sign-in for carl"))
    }

    @Test func theSecondRefusalBlocksTheThird() async throws {
        let own = pages()
        defer { own.closeAll() }
        let name = try await own.open(html: SignInPageTests.onePage(expect: "other"), base: Self.base)
        let tool = LoginsCapability.signIn(store: try store([SignInPageTests.ann]), own: own)
        let first = await tool.handler(.object(["page": .string(name)])).plainText
        #expect(first.contains("refused") && first.contains("One more try is allowed"))
        let second = await tool.handler(.object(["page": .string(name)])).plainText
        #expect(second.contains("won't try it again"))
        let third = await tool.handler(.object(["page": .string(name)]))
        #expect(third.isError && third.plainText.contains("refused this sign-in twice"))
    }

    @Test func onlyHTTPSPages() async throws {
        let own = pages()
        defer { own.closeAll() }
        let name = try await own.open(html: SignInPageTests.onePage(), base: URL(string: "http://a.test/")!)
        let r = await LoginsCapability.signIn(store: try store([SignInPageTests.ann]), own: own).handler(
            .object(["page": .string(name)]))
        #expect(r.isError && r.plainText.contains("only on https"))
    }

    /// Spec 013 FR-1352: where Latchkey's own sign-in can't finish, the owner's Safari sign-in.
    static let needsCode = """
        <form onsubmit="event.preventDefault(); document.body.innerHTML = '<label>Enter the code we texted you <input name=code autocomplete=one-time-code></label>';">
        <input name="username" autocomplete="username"><input type="password" name="p"><button>Log in</button></form>
        """

    /// A sign-in whose 2 minutes of waiting for a code are over (FR-1361): its fallback follows.
    static func noWait() -> TextedCodes {
        let c = TextedCodes(defaults: nil)
        c.window = 0
        c.firstWait = .zero
        return c
    }

    func fallback(locked: Bool, wide: Bool = false) throws -> (OwnPages, OwnSessions, SignInStore) {
        // wide: a second sign-in saved for another name under a.test, and Safari's sign-in in a
        // cookie for all of a.test (Amazon's shape, live check 2026-11-21).
        let s = try store(
            [SignInPageTests.ann]
                + (wide
                    ? [SavedSignIn(title: "N", site: "na.account.a.test", user: "ann", password: "pw", otp: nil)] : []))
        let sessions = OwnSessions(signIns: s, vault: MemoryVault())
        sessions.on = { true }
        let safari = [
            SafariCookies.Cookie(
                domain: wide ? ".a.test" : "a.test", name: "safari_a", path: "/", value: "1", secure: true,
                httpOnly: false, expires: Date().addingTimeInterval(86400))
        ]
        let own = OwnPages(cookies: { safari }, isLocked: { locked }, record: { _ in }, sessions: sessions)
        return (own, sessions, s)
    }

    @Test func lockedItTakesSafarisSignInWhereItsOwnCantFinish() async throws {
        let (own, sessions, s) = try fallback(locked: true)
        defer { own.closeAll() }
        let name = try await own.open(html: Self.needsCode, base: Self.base)
        #expect(try await own.page(name).run("document.cookie") == "", "no copy before: Latchkey signs in itself")
        let r = await LoginsCapability.signIn(store: s, own: own, move: { _ in nil }, codes: Self.noWait()).handler(
            .object(["page": .string(name)]))
        #expect(r.plainText.contains("verification code Latchkey doesn't have"), "\(r.plainText)")
        #expect(r.plainText.contains("the owner's Safari sign-in is used there instead"))
        // A test page has no server to load it again from: said so, the copy taken all the same.
        #expect(r.plainText.contains("took a copy of Safari's cookies"))
        #expect(r.plainText.contains("loading it again didn't work"))
        #expect(sessions.fellBack("a.test") && !sessions.isOwn("a.test"))
        #expect(try await own.page(name).run("document.cookie") == "safari_a=1")
    }

    /// Live check 2026-11-21 (Amazon): the fallback covers every sign-in saved under the same
    /// name, so Safari's cookie for all of the site is copied, and what Latchkey's own try left
    /// goes first.
    @Test func theFallbackCoversTheWholeSiteAndDropsTheTry() async throws {
        let (own, sessions, s) = try fallback(locked: true, wide: true)
        defer { own.closeAll() }
        let name = try await own.open(html: Self.needsCode, base: Self.base)
        _ = try await own.page(name).run("document.cookie = 'attempt=1; path=/; secure'; 'ok'")
        let r = await LoginsCapability.signIn(store: s, own: own, move: { _ in nil }, codes: Self.noWait()).handler(
            .object(["page": .string(name)]))
        #expect(r.plainText.contains("the owner's Safari sign-in is used there instead"), "\(r.plainText)")
        #expect(sessions.fellBack("a.test") && sessions.fellBack("na.account.a.test"))
        #expect(!sessions.reaches(".a.test"))
        #expect(try await own.page(name).run("document.cookie") == "safari_a=1")
    }

    @Test func unlockedThePageMovesToSafari() async throws {
        let (own, sessions, s) = try fallback(locked: false)
        defer { own.closeAll() }
        let name = try await own.open(html: Self.needsCode, base: Self.base)
        let moved = Box()
        let r = await LoginsCapability.signIn(
            store: s, own: own,
            move: { _ in
                moved.called = true
                return nil
            }, codes: Self.noWait()
        ).handler(.object(["page": .string(name)]))
        #expect(moved.called, "\(r.plainText)")
        #expect(r.plainText.contains("couldn't move into Safari"))
        #expect(sessions.fellBack("a.test"))
    }

    final class Box: @unchecked Sendable { var called = false }

    @Test func aSignInThatWorksStaysLatchkeysOwn() async throws {
        let (own, sessions, s) = try fallback(locked: true)
        defer { own.closeAll() }
        let name = try await own.open(html: SignInPageTests.onePage(), base: Self.base)
        let r = await LoginsCapability.signIn(store: s, own: own, move: { _ in nil }, codes: Self.noWait()).handler(
            .object(["page": .string(name)]))
        #expect(r.plainText.contains("Signed in to a.test as ann."), "\(r.plainText)")
        #expect(!r.plainText.contains("Safari sign-in is used"))
        #expect(sessions.isOwn("a.test"))
        #expect(r.plainText.contains("with Latchkey's own sign-in for a.test"))
    }
}
