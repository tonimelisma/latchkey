import Foundation
import Testing

@testable import Latchkey

/// At start the app decides whether to open the setup window before its connection has reported
/// anything. Until 0.8.12 the status was still "not paired" at that moment, so the window opened
/// on every start of a fully set up Mac (FR-205).
@Suite struct StartStatusTests {
    @Test func aStoredPairingCountsAsPairedBeforeTheConnectionReports() {
        let status = ConnectionStatus.atStart(paired: true)
        #expect(status == .connecting)
        #expect(status.isPaired)
    }

    @Test func withoutAPairingTheMacIsNotPaired() {
        let status = ConnectionStatus.atStart(paired: false)
        #expect(status == .notPaired)
        #expect(!status.isPaired)
    }

    @Test func onlyNotPairedAndRevokedMeanSetupMustConnectAgain() {
        #expect(!ConnectionStatus.notPaired.isPaired)
        #expect(!ConnectionStatus.revoked.isPaired)
        for status: ConnectionStatus in [
            .connecting, .connected, .waiting(until: .distantFuture), .signInAgain, .replaced, .updateRequired,
            .suspended,
        ] {
            #expect(status.isPaired, "\(status)")
        }
    }
}
