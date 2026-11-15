import CryptoKit
import Foundation

@testable import Latchkey

/// Stand-ins the tests use instead of the Keychain and the Secure Enclave, which tests never touch
/// (macos.md).

/// The activity log's key, in memory.
final class MemoryTraceKey: TraceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?

    func loadOrCreate() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let key { return key }
        let k = SymmetricKey(size: .bits256)
        key = k
        return k
    }

    func delete() {
        lock.lock()
        key = nil
        lock.unlock()
    }
}

/// A signing key in memory, for pairing and signature tests.
struct SoftwareSigningKey: SigningKey {
    let key = P256.Signing.PrivateKey()
    var publicKeyDER: Data { key.publicKey.derRepresentation }
    func sign(_ data: Data) throws -> String {
        try key.signature(for: data).derRepresentation.base64URLEncodedString()
    }
}
