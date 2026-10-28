import Foundation
import Testing

@testable import Latchkey

/// Setup opens only for steps macOS has said are not done; "not known yet" never opens it
/// (spec 001 FR-621; 2026-10-27 the window opened over a finished setup).
@Suite struct SetupDecisionTests {
    @Test func unknownIsNeverMissing() {
        let launching: [(String, SetupStep)] = [("connect", .done), ("location", .unknown)]
        #expect(SetupDecision.missing(launching).isEmpty)
        #expect(!SetupDecision.settled(launching))
        #expect(SetupDecision.unknown(launching) == ["location"])

        let settled: [(String, SetupStep)] = [("connect", .done), ("location", .missing), ("calendars", .done)]
        #expect(SetupDecision.missing(settled) == ["location"])
        #expect(SetupDecision.settled(settled))
    }

    /// Location's permission comes from Core Location's callback, so a launch reads "unknown",
    /// shown as Checking… and never as Not Allowed.
    @Test func locationNotKnownYetShowsAsChecking() {
        var facts = ApprovalFacts(
            helper: true, fullDiskAccess: true, notes: .allowed, messages: .allowed, safari: .allowed,
            contacts: .authorized, safariJavaScript: true, screenRecording: true, accessibility: true,
            level: { _ in .readWrite })
        facts.location = .unknown
        #expect(Approval.list(facts).first { $0.id == "location" }?.state == .checking)
        facts.location = .notAsked
        #expect(Approval.list(facts).first { $0.id == "location" }?.state == .missing)
    }

    @Test func coreLocationStatesMapToAccess() {
        #expect(AppleMapsBackend.access(.authorizedAlways, servicesOn: true) == .allowed)
        #expect(AppleMapsBackend.access(.notDetermined, servicesOn: true) == .notAsked)
        #expect(AppleMapsBackend.access(.denied, servicesOn: true) == .denied)
        #expect(AppleMapsBackend.access(.authorizedAlways, servicesOn: false) == .servicesOff)
    }
}
