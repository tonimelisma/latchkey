import Foundation
import Testing

@testable import Latchkey

/// Spec 013: where the copies live, and what a refusal does (FR-1303, FR-1305, FR-1310, FR-1324).
@Suite struct SignInStoreTests {
    static let a = SavedSignIn(title: "A", site: "a.test", user: "ann", password: "pw-a", otp: nil)
    static let b = SavedSignIn(title: "B", site: "b.test", user: "bob", password: "pw-b", otp: nil)
    static let b2 = SavedSignIn(title: "B2", site: "b.test", user: "bea", password: "pw-b2", otp: nil)

    @Test func startsEmptyAndKeepsAnImportInOneItem() throws {
        let vault = MemoryVault()
        let store = SignInStore(vault: vault)
        #expect(store.load() == .none)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        try store.replace(with: [Self.a, Self.b], at: when)
        #expect(vault.items.keys.sorted() == [SignInStore.account])
        // A new store (a restart) reads the same item back.
        guard case .some(let c) = SignInStore(vault: vault).load() else {
            Issue.record("nothing stored")
            return
        }
        #expect(c.logins == [Self.a, Self.b] && c.imported == when)
    }

    @Test func anImportReplacesEverything() throws {
        let store = SignInStore(vault: MemoryVault())
        try store.replace(with: [Self.a, Self.b], at: Date())
        try store.replace(with: [Self.b2], at: Date())
        #expect(store.load().logins == [Self.b2])
    }

    @Test func aFailedWriteKeepsTheOldCopies() throws {
        let vault = MemoryVault()
        let store = SignInStore(vault: vault)
        try store.replace(with: [Self.a], at: Date())
        vault.failWrites = true
        #expect(throws: (any Error).self) { try store.replace(with: [Self.b], at: Date()) }
        #expect(store.load().logins == [Self.a])
    }

    @Test func anUnreadableItemIsNotAbsent() throws {
        let vault = MemoryVault()
        try SignInStore(vault: vault).replace(with: [Self.a], at: Date())
        vault.unreadable = [SignInStore.account]
        #expect(SignInStore(vault: vault).load() == .unreadable)
    }

    @Test func removeAllDeletesTheItem() throws {
        let vault = MemoryVault()
        let store = SignInStore(vault: vault)
        try store.replace(with: [Self.a], at: Date())
        store.removeAll()
        #expect(vault.items.isEmpty && store.load() == .none)
    }

    @Test func findsTheSignInsOfAPage() throws {
        let store = SignInStore(vault: MemoryVault())
        try store.replace(with: [Self.a, Self.b, Self.b2], at: Date())
        #expect(store.load().logins.filter { SiteMatch.fills(site: $0.site, on: "https://www.b.test/x") }.count == 2)
    }

    @Test func theSecondRefusalBlocksUntilTheNextImport() throws {
        let store = SignInStore(vault: MemoryVault())
        try store.replace(with: [Self.a], at: Date())
        #expect(!store.blocked(Self.a))
        #expect(store.refused(Self.a) == 1)
        #expect(!store.blocked(Self.a))
        #expect(store.refused(Self.a) == 2)
        #expect(store.blocked(Self.a))
        try store.replace(with: [Self.a], at: Date())
        #expect(!store.blocked(Self.a))
    }

    @Test func aCodeIsSentOncePerStep() throws {
        let store = SignInStore(vault: MemoryVault())
        #expect(store.mayUseCode(Self.a, step: 100))
        store.usedCode(Self.a, step: 100)
        #expect(!store.mayUseCode(Self.a, step: 100))
        #expect(store.mayUseCode(Self.a, step: 101))
    }
}
