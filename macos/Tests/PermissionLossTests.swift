import Foundation
import Testing

@testable import Latchkey

/// A permission that was on and goes off is told to the Owner once (FR-626).
struct PermissionLossTests {
    static func approval(_ id: String, _ state: Approval.State, title: String? = nil, purpose: String = "To do it.")
        -> Approval
    {
        Approval(id: id, title: title ?? id, purpose: purpose, state: state)
    }

    @Test func toldOnlyWhenAllowedGoesMissing() {
        var loss = PermissionLoss()
        // Missing from the start: setup handles it (FR-621), no notification.
        #expect(loss.update([Self.approval("disk", .allowed), Self.approval("mail", .missing)]).isEmpty)
        let lost = loss.update([Self.approval("disk", .missing), Self.approval("mail", .missing)])
        #expect(lost.map(\.id) == ["disk"])
    }

    @Test func toldOncePerLoss() {
        var loss = PermissionLoss()
        _ = loss.update([Self.approval("disk", .allowed)])
        #expect(loss.update([Self.approval("disk", .missing)]).count == 1)
        #expect(loss.update([Self.approval("disk", .missing)]).isEmpty)
        // Turned on again, then lost again: told again.
        #expect(loss.update([Self.approval("disk", .allowed)]).isEmpty)
        #expect(loss.update([Self.approval("disk", .missing)]).count == 1)
    }

    @Test func notKnownYetIsNeitherAllowedNorLost() {
        var loss = PermissionLoss()
        _ = loss.update([Self.approval("location", .allowed)])
        #expect(loss.update([Self.approval("location", .checking)]).isEmpty)
        #expect(loss.update([Self.approval("location", .missing)]).count == 1)
        var fresh = PermissionLoss()
        _ = fresh.update([Self.approval("location", .checking)])
        #expect(fresh.update([Self.approval("location", .missing)]).isEmpty)
    }

    /// A notification can't arrive without Notifications, and the screenshot question isn't
    /// something macOS takes back.
    @Test func notificationsAndScreenAccessAreNotTold() {
        var loss = PermissionLoss()
        _ = loss.update([Self.approval("notifications", .allowed), Self.approval("screenAccess", .allowed)])
        #expect(
            loss.update([Self.approval("notifications", .missing), Self.approval("screenAccess", .missing)]).isEmpty)
    }

    @Test func oneLossNamesItAndWhatItIsFor() {
        let notice = PermissionLoss.notice([
            Self.approval(
                "disk", .missing, title: "Full Disk Access", purpose: "To read your files, notes, messages, and mail.")
        ])
        #expect(notice?.title == "Full Disk Access is off")
        #expect(
            notice?.body
                == "Latchkey needs it to read your files, notes, messages, and mail. Click to turn it on again.")
        let helper = PermissionLoss.notice([
            Self.approval(
                "helper", .missing, title: "Keep This Mac Awake",
                purpose: "So Claude can reach this Mac with the lid closed.")
        ])
        #expect(
            helper?.body
                == "Latchkey needs it so Claude can reach this Mac with the lid closed. Click to turn it on again.")
    }

    @Test func severalLossesInOneNotification() {
        let two = PermissionLoss.notice([
            Self.approval("a", .missing, title: "A"), Self.approval("b", .missing, title: "B"),
        ])
        #expect(two?.title == "2 Latchkey permissions are off")
        #expect(two?.body == "A and B. Claude can’t use what they allow until they’re on again. Click to turn them on.")
        let three = PermissionLoss.notice([
            Self.approval("a", .missing, title: "A"), Self.approval("b", .missing, title: "B"),
            Self.approval("c", .missing, title: "C"),
        ])
        #expect(three?.body.hasPrefix("A, B, and C. ") == true)
        #expect(PermissionLoss.notice([]) == nil)
    }

    /// Every permission in the Permissions tab reads well in the one-loss notice.
    @Test func everyPurposeReadsAfterNeedsIt() {
        let facts = ApprovalFacts(
            helper: true, fullDiskAccess: true, notes: .allowed, messages: .allowed, safari: .allowed,
            contacts: .authorized, screenRecording: true, accessibility: true)
        for approval in Approval.list(facts) where !PermissionLoss.unwatched.contains(approval.id) {
            let body = PermissionLoss.notice([approval])?.body ?? ""
            #expect(
                body.hasPrefix("Latchkey needs it to ") || body.hasPrefix("Latchkey needs it so "),
                "\(approval.id): \(body)")
        }
    }
}
