import Foundation
import Testing

@testable import Latchkey

/// Spec 005 FR-453, FR-454: Latchkey's log says which sign-in cookies Claude's pages took from
/// Safari, how old Safari's cookie file was, and when a site changed one of them, by name and
/// never by value (Toni, 2026-11-15: Target signed Safari out after Claude's page used a copy).
@MainActor @Suite struct CookieWatchTests {
    static func cookie(
        _ name: String, _ value: String, domain: String = ".shop.example", httpOnly: Bool = false
    ) -> HTTPCookie {
        var p: [HTTPCookiePropertyKey: Any] = [
            .domain: domain, .name: name, .path: "/", .value: value, .expires: Date().addingTimeInterval(3600),
        ]
        if httpOnly { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: p)!
    }

    /// Only a server can set an HttpOnly cookie, and sign-ins keep their tokens in those or in
    /// cookies named for a token; page scripts' own cookies (analytics) are neither.
    @Test func signInCookiesAreHttpOnlyOrNamedForAToken() {
        #expect(CookieWatch.isSignIn(name: "refreshToken", httpOnly: true))
        #expect(CookieWatch.isSignIn(name: "SESSION", httpOnly: true))
        #expect(CookieWatch.isSignIn(name: "idToken", httpOnly: false))
        #expect(CookieWatch.isSignIn(name: "access_token", httpOnly: false))
        #expect(!CookieWatch.isSignIn(name: "kampyleUserSession", httpOnly: false))
        #expect(!CookieWatch.isSignIn(name: "_px3", httpOnly: false))
    }

    @Test func theCopyLineNamesTheSignInCookiesAndTheFilesAgeNeverAValue() throws {
        let set = [
            Self.cookie("refreshToken", "SECRET-R", httpOnly: true), Self.cookie("idToken", "SECRET-I"),
            Self.cookie("_px3", "SECRET-P"),
        ]
        let line = try #require(CookieWatch.copyLine(site: "www.shop.example", set: set, fileAge: 272))
        #expect(line.contains("www.shop.example"))
        #expect(line.contains("3 of Safari's cookies"))
        #expect(line.contains("idToken") && line.contains("refreshToken") && !line.contains("_px3"))
        #expect(line.contains("4 min"), "Safari's cookie file was written 272 s before: \(line)")
        #expect(!line.contains("SECRET"))
        #expect(CookieWatch.copyLine(site: "www.shop.example", set: [], fileAge: 5) == nil, "nothing set: no line")
        let unknown = try #require(CookieWatch.copyLine(site: "a.example", set: set, fileAge: nil))
        #expect(unknown.contains("age unknown"))
    }

    /// A site replacing, removing, or adding a sign-in cookie is one line per site; a cookie it
    /// leaves alone and a page script's own cookie are not told.
    @Test func changesAreToldPerSiteByNameOnly() {
        var watch = CookieWatch.Seen()
        watch.note(
            [
                Self.cookie("refreshToken", "R1", httpOnly: true), Self.cookie("idToken", "I1"),
                Self.cookie("_px3", "P1"),
            ],
            fromSafari: true)
        let after = [
            Self.cookie("refreshToken", "R2", httpOnly: true),  // replaced
            Self.cookie("_px3", "P2"),  // not a sign-in cookie
            Self.cookie("accessToken", "A1", httpOnly: true),  // new
            Self.cookie("sid", "S1", domain: "other.example", httpOnly: true),  // another site, new
        ]
        let lines = watch.changes(now: after).sorted()
        #expect(lines.count == 2, "\(lines)")
        #expect(lines[0].hasPrefix("other.example"))
        #expect(lines[0].contains("new: sid"))
        #expect(lines[1].hasPrefix("shop.example"))
        #expect(lines[1].contains("replaced Safari's refreshToken"))
        #expect(lines[1].contains("removed Safari's idToken"))
        #expect(lines[1].contains("new: accessToken"))
        #expect(!lines.joined().contains("R2") && !lines.joined().contains("A1"))
        #expect(watch.changes(now: after).isEmpty, "nothing changed since")
        // A second renewal of what the site set is told again, no longer as Safari's.
        let again = watch.changes(now: [Self.cookie("refreshToken", "R3", httpOnly: true)] + after.dropFirst())
        #expect(again.count == 1 && again[0].contains("replaced refreshToken") && !again[0].contains("Safari's"))
    }

    /// In a real WebKit page: Safari's token is copied (told), then the page replaces it (told).
    @Test func aPageReplacingSafarisTokenIsLogged() async throws {
        let jar = LockedBrowserTests.Jar()
        jar.cookies = [
            SafariCookies.Cookie(
                domain: "test.example", name: "accessToken", path: "/", value: "from-safari", secure: false,
                httpOnly: false, expires: Date().addingTimeInterval(3600))
        ]
        let told = Told()
        let pages = OwnPages(cookies: { jar.cookies }, isLocked: { true }, fileAge: { 30 }, record: { told.add($0) })
        defer { pages.closeAll() }
        let name = try await pages.open(html: "<p>Hi</p>", base: URL(string: "https://test.example/")!)
        #expect(
            told.lines.contains { $0.contains("test.example") && $0.contains("accessToken") && $0.contains("30 s") })
        _ = try await pages.page(name).run("document.cookie = 'accessToken=from-site; path=/'; 1")
        let deadline = ContinuousClock.now + .seconds(5)
        while !told.lines.contains(where: { $0.contains("replaced Safari's accessToken") }),
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(50))
        }
        let jarNow = (try? await pages.page(name).run("document.cookie.replace(/=[^;]*/g, '=…')")) ?? "?"
        #expect(
            told.lines.contains { $0.contains("replaced Safari's accessToken") },
            "\(told.lines); the page's cookies (names): \(jarNow)")
        #expect(!told.lines.joined().contains("from-"))
    }

    final class Told: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [String] = []
        var lines: [String] { lock.withLock { held } }
        func add(_ s: String) { lock.withLock { held.append(s) } }
    }
}
