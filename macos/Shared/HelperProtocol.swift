import Foundation

/// The privileged helper's XPC interface (plan D7). It does exactly two things: turn the
/// system SleepDisabled setting on or off, and read it back.
@objc(LatchkeyHelperProtocol)
protocol HelperProtocol {
    /// Sets SleepDisabled and replies with the value read back afterwards.
    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (_ nowDisabled: Bool, _ error: String?) -> Void)
    /// Replies with the current SleepDisabled value.
    func readSleepDisabled(reply: @escaping @Sendable (_ disabled: Bool) -> Void)
}

enum HelperIdentity {
    static let machService = "net.melisma.latchkey.helper"
    static let plistName = "net.melisma.latchkey.helper.plist"
    static let appBundleID = "net.melisma.latchkey"
    static let helperBundleID = "net.melisma.latchkey.helper"
}
