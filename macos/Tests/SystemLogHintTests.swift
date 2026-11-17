import Testing

@testable import Latchkey

/// A refused `log show` points to Latchkey's own log (regression case
/// regressions.shell_unified_log_readable_or_said, 2026-11-16).
struct SystemLogHintTests {
    @Test func aRefusedSystemLogPointsToLatchkeysOwn() {
        #expect(Fence.looksLikeSystemLog("log: Cannot run while sandboxed."))
        #expect(!Fence.looksLikeSystemLog("Operation not permitted"))
        #expect(Fence.systemLogHint.contains("latchkey_log"))
    }
}
