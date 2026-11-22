import Foundation

/// The Owner's sign-ins, as Latchkey holds them (spec 013 FR-1303, FR-1310): one Keychain item of
/// this app's, readable after the Mac's first unlock (also while locked), never synced, never
/// sent anywhere. Refusals and the codes sent are counted in memory only (FR-1324).
final class SignInStore: @unchecked Sendable {
    static let account = "sign-ins"
    static let shared = SignInStore(vault: KeychainVault())

    struct Contents: Codable, Equatable, Sendable {
        var imported: Date
        var logins: [SavedSignIn]
    }

    enum Load: Equatable {
        case none
        case some(Contents)
        /// The item is there but can't be read now; never taken for "none" (`.claude/rules`).
        case unreadable

        var logins: [SavedSignIn] { if case .some(let c) = self { c.logins } else { [] } }
    }

    private let vault: any PairingVault
    private let lock = NSLock()
    private var cached: Contents?
    private var codes: Set<String> = []

    init(vault: any PairingVault) { self.vault = vault }

    private static func key(_ s: SavedSignIn) -> String { s.site + "\n" + s.user }

    func load() -> Load {
        lock.withLock {
            if let cached { return .some(cached) }
            switch vault.lookup(Self.account) {
            case .absent: return .none
            case .unreadable: return .unreadable
            case .found(let data):
                guard let c = try? JSONDecoder().decode(Contents.self, from: data) else { return .unreadable }
                cached = c
                return .some(c)
            }
        }
    }

    /// Replaces every copy with these, in one write: when it fails, the old copies stay (FR-1303).
    func replace(with logins: [SavedSignIn], at date: Date) throws {
        let c = Contents(imported: date, logins: logins)
        let data = try JSONEncoder().encode(c)
        try lock.withLock {
            try vault.write(data, Self.account)
            cached = c
            codes = []
        }
    }

    /// Removes every copy (FR-1305).
    func removeAll() {
        lock.withLock {
            vault.delete(Self.account)
            cached = nil
            codes = []
        }
    }

    func mayUseCode(_ s: SavedSignIn, step: UInt64) -> Bool {
        lock.withLock { !codes.contains(Self.key(s) + "\n\(step)") }
    }

    func usedCode(_ s: SavedSignIn, step: UInt64) {
        _ = lock.withLock { codes.insert(Self.key(s) + "\n\(step)") }
    }
}
