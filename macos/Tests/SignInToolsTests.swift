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
        #expect(on.tools.contains { $0.name == "logins_find" } && on.tools.contains { $0.name == "logins_fill" })
        levels[CapabilityRegistry.logins] = .off
        let off = CapabilityRegistry(capabilities: AppModel.makeCapabilities(), levels: levels)
        #expect(!off.tools.contains { $0.name.hasPrefix("logins_") })
        #expect(CapabilityRegistry.defaultLevels[CapabilityRegistry.logins] == .readWrite, "On by default")
    }

    @Test func findListsSitesAndUserNamesNeverSecrets() async throws {
        let s = try store([
            SignInStoreTests.a, SignInStoreTests.b,
            SavedSignIn(title: "G", site: "github.com", user: "toni", password: "gh-secret", otp: SignInFillTests.otp),
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
}
