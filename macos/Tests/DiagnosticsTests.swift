import Foundation
import Testing

@testable import Latchkey

/// The diagnostic log says a state once per change, not on every check (spec 001 FR-620).
@Suite struct DiagnosticsTests {
    @Test func passesOnlyChanges() {
        let changes = Changes<String>()
        #expect(changes.changed("Keep-awake on"), "the first value is new")
        #expect(!changes.changed("Keep-awake on"), "the same again is not")
        #expect(changes.changed("Keep-awake off_helper_unavailable"))
        #expect(changes.changed("Keep-awake on"), "back to an earlier value is a change")
    }

    /// Every category reads under the app's own subsystem, so one search shows them all.
    @Test func everyCategoryUsesTheAppsSubsystem() {
        #expect(AppIdentity.current.logSubsystem == AppIdentity.current.bundleID)
    }
}
