import EventKit
import Foundation

/// Invitations through EventKit (spec 007 FR-705 to FR-707, plan D9). EventKit's public API
/// reads attendees and answers but can't change them; the calls Calendar itself uses to invite
/// people and answer invitations are methods of EventKit's own classes that Apple doesn't
/// document (research.md "Invitations"). Each is looked up before use, so a macOS without one
/// gets a plain answer instead of a crash, and every change is read back after the save.
enum EventKitInvitations {
    /// What the Owner can do when this macOS lacks one of the calls.
    static let elsewhere =
        "Answer it or change the invitees in the Calendar app (with Computer control on, Claude can do that there)."

    private static let setStatus = NSSelectorFromString("setParticipationStatus:")
    private static let getStatus = NSSelectorFromString("participationStatus")
    private static let setComment = NSSelectorFromString("setResponseComment:")
    private static let addAttendee = NSSelectorFromString("addAttendee:")
    private static let removeAttendee = NSSelectorFromString("removeAttendee:")
    private static let makeAttendee = NSSelectorFromString("attendeeWithName:emailAddress:")

    /// The calls this needs exist on this macOS.
    static var available: Bool {
        let probe = EKEvent.instancesRespond(to:)
        return probe(setStatus) && probe(getStatus) && probe(addAttendee) && probe(removeAttendee)
            && (attendeeClass?.responds(to: makeAttendee) ?? false)
    }

    private static var attendeeClass: NSObject.Type? { NSClassFromString("EKAttendee") as? NSObject.Type }

    private static func missing(_ what: String) -> EventsFailure {
        .failed("this version of macOS doesn't offer the calendar call Latchkey uses to \(what). \(elsewhere)")
    }

    /// A yes/no property of the event, or nil when this macOS doesn't have it.
    static func flag(_ key: String, of e: EKEvent) -> Bool? {
        guard e.responds(to: NSSelectorFromString(key)) else { return nil }
        return (e.value(forKey: key) as? NSNumber)?.boolValue
    }

    static func status(_ a: InvitationAnswer) -> EKParticipantStatus {
        switch a {
        case .accepted: .accepted
        case .tentative: .tentative
        case .declined: .declined
        }
    }

    /// The Owner's answer as the event now holds it.
    static func answer(of e: EKEvent) -> EKParticipantStatus? {
        guard e.responds(to: getStatus), let n = e.value(forKey: "participationStatus") as? NSNumber else {
            return nil
        }
        return EKParticipantStatus(rawValue: n.intValue)
    }

    /// Sets the Owner's answer (and a note to the organizer) on the event; the save sends it.
    static func setAnswer(_ status: EKParticipantStatus, comment: String?, on e: EKEvent) throws {
        guard e.responds(to: setStatus), e.responds(to: getStatus) else { throw missing("answer invitations") }
        e.setValue(NSNumber(value: status.rawValue), forKey: "participationStatus")
        if let comment {
            guard e.responds(to: setComment) else { throw missing("send a note with an answer") }
            e.setValue(comment, forKey: "responseComment")
        }
    }

    static func email(_ p: EKParticipant) -> String? {
        p.url.scheme?.lowercased() == "mailto" ? String(p.url.absoluteString.dropFirst("mailto:".count)) : nil
    }

    static func invite(_ emails: [String], to e: EKEvent) throws {
        guard !emails.isEmpty else { return }
        guard let cls = attendeeClass, cls.responds(to: makeAttendee), e.responds(to: addAttendee) else {
            throw missing("invite people")
        }
        let present = Set((e.attendees ?? []).compactMap { email($0)?.lowercased() })
        for address in emails where !present.contains(address.lowercased()) {
            guard let made = cls.perform(makeAttendee, with: address, with: address)?.takeUnretainedValue() else {
                throw EventsFailure.failed("macOS couldn't make an invitation for \(address).")
            }
            e.perform(addAttendee, with: made)
        }
    }

    static func uninvite(_ emails: [String], from e: EKEvent) throws {
        guard !emails.isEmpty else { return }
        guard e.responds(to: removeAttendee) else { throw missing("uninvite people") }
        let wanted = Set(emails.map { $0.lowercased() })
        for p in e.attendees ?? [] where email(p).map({ wanted.contains($0.lowercased()) }) == true {
            e.perform(removeAttendee, with: p)
        }
    }

    /// After a save: the invitees asked for are on the event and the uninvited ones aren't.
    static func checkPeople(_ d: EventDraft, on e: EKEvent) throws {
        guard !d.invite.isEmpty || !d.uninvite.isEmpty else { return }
        let now = Set((e.attendees ?? []).compactMap { email($0)?.lowercased() })
        let notAdded = d.invite.filter { !now.contains($0.lowercased()) }
        let notRemoved = d.uninvite.filter { now.contains($0.lowercased()) }
        guard notAdded.isEmpty && notRemoved.isEmpty else {
            throw EventsFailure.failed(
                "the event was saved, but the calendar didn't take "
                    + (notAdded + notRemoved).joined(separator: ", ") + ". \(elsewhere)")
        }
    }
}
