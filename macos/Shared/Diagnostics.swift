import Foundation
import OSLog

/// What the app and its helper write to macOS's log so a problem can be traced afterwards
/// (spec 001 FR-620): keep-awake, the helper, the relay connection, sleep and power, and macOS
/// permissions. States and reasons only: never message text, tool arguments or results, file
/// names, or the relay's address in the clear. Read with
/// `log show --predicate 'subsystem == "net.melisma.latchkey"'`.
enum Diagnostics {
    private static let subsystem = AppIdentity.current.logSubsystem
    static let keepAwake = Logger(subsystem: subsystem, category: "keepawake")
    static let helper = Logger(subsystem: subsystem, category: "helper")
    static let connection = Logger(subsystem: subsystem, category: "connection")
    static let power = Logger(subsystem: subsystem, category: "power")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
}

/// Passes a value on only when it differs from the last one, so a state read every few seconds
/// is logged once per change.
final class Changes<Value: Equatable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Value?

    /// True the first time and whenever `value` differs from the previous call's.
    func changed(_ value: Value) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value != last else { return false }
        last = value
        return true
    }
}
