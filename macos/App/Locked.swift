import Foundation

/// A value read and changed from any thread.
final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ v: T) { stored = v }
    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func mutate(_ f: (inout T) -> Void) {
        lock.lock()
        f(&stored)
        lock.unlock()
    }
}
