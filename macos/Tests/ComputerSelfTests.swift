import Testing

@testable import Latchkey

/// Computer control never acts on Latchkey, and says so rather than "isn't running"
/// (regression case regressions.computer_never_targets_latchkey, 2026-11-16).
struct ComputerSelfTests {
    @Test func latchkeyIsNamedAsLatchkey() {
        for name in ["Latchkey", "latchkey", " Latchkey Dev", "Latchkey.app"] {
            #expect(AppControl.namesLatchkey(name), "\(name)")
        }
        for name in ["Calculator", "Safari", "Keychain Access"] {
            #expect(!AppControl.namesLatchkey(name), "\(name)")
        }
    }
}
