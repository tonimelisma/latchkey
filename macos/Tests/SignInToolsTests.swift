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
}
