import AppKit
import Foundation

/// Changes a card through the Contacts app's own scripting, for the cards the Contacts framework
/// can't save: macOS lets only apps with Apple's Contacts notes entitlement save a card that has a
/// note (Cocoa error 134092; Apple Developer Forums thread 847426, FB23452026), and that
/// entitlement isn't given to other developers. Toni chose (2026-11-27, "Via Contacts' scripting")
/// to change such cards the way the Contacts app would. Contacts is opened hidden and never in
/// front (Constitution IV: no window a person at the Mac would see), and quit again when Latchkey
/// opened it, unless the owner brought it to the front meanwhile (so nothing is left running that
/// the owner didn't open).
struct ContactsApp: Sendable {
    var runner: any ScriptRunner
    /// Opens Contacts hidden when it isn't running; true when it did.
    var openHidden: @Sendable () async -> Bool
    /// Quits the Contacts Latchkey opened, unless it is in front.
    var quitUnlessInFront: @Sendable () async -> Void

    static let live = ContactsApp(
        runner: OSAScriptRunner(app: Permissions.contactsApp),
        openHidden: { await ContactsAppProcess.openHidden() },
        quitUnlessInFront: { await ContactsAppProcess.quitUnlessInFront() })

    /// Sets the draft's fields on the card, as `CNContactsBackend.apply` would.
    func update(id: String, _ draft: ContactDraft) async throws {
        try await run(Script.update, Self.updateArguments(id: id, draft))
    }

    func delete(id: String) async throws {
        try await run(Script.delete, [id])
    }

    private func run(_ script: String, _ arguments: [String]) async throws {
        let opened = await openHidden()
        let answer: String
        do { answer = try await runner.run(script, arguments) } catch {
            if opened { await quitUnlessInFront() }
            switch error {
            case ScriptError.notAllowed: throw ContactsFailure.noAppControl
            case ScriptError.timedOut: throw ContactsFailure.failed("the Contacts app didn't answer in time")
            case ScriptError.failed(let why): throw ContactsFailure.failed("the Contacts app said: \(why)")
            default: throw error
            }
        }
        if opened { await quitUnlessInFront() }
        guard answer == "ok" else {
            throw ContactsFailure.failed(answer.isEmpty ? "the Contacts app didn't answer" : answer)
        }
    }

    /// The script's arguments: the card's id, then each field the draft sets, as a key and its
    /// values. A list is its key, how many items, then each item's values (label and value; for an
    /// address label, street, city, state, postal code, country). A birthday is its year ("" when
    /// it has none), month and day, or "clear". Labels are Apple's stored ones, as the framework
    /// saves them, so other apps show them in the owner's language.
    static func updateArguments(id: String, _ d: ContactDraft) -> [String] {
        var a = [id]
        let texts: [(String, String?)] = [
            ("first name", d.givenName), ("middle name", d.middleName), ("last name", d.familyName),
            ("nickname", d.nickname), ("organization", d.organization), ("job title", d.jobTitle),
            ("department", d.department),
        ]
        for case (let key, let value?) in texts { a += [key, value] }
        func labeled(_ key: String, _ items: [Labeled]?) {
            guard let items else { return }
            a += [key, String(items.count)]
            for i in items { a += [CNContactsBackend.storedLabel(i.label), i.value] }
        }
        labeled("phones", d.phones)
        labeled("emails", d.emails)
        labeled("urls", d.urls)
        if let addresses = d.addresses {
            a += ["addresses", String(addresses.count)]
            for p in addresses {
                a += [CNContactsBackend.storedLabel(p.label), p.street, p.city, p.state, p.postalCode, p.country]
            }
        }
        if let b = d.birthday {
            if b.isEmpty {
                a += ["birthday", "clear"]
            } else if let c = ContactsCapability.birthday(b), let m = c.month, let day = c.day {
                a += ["birthday", c.year.map(String.init) ?? "", String(m), String(day)]
            }
        }
        return a
    }

    enum Script {
        /// Never starts Contacts itself: Apple Events start an app shown, with its window
        /// (Constitution IV), so `openHidden` starts it first and the script stops if it isn't
        /// running (a Contacts still quitting when Latchkey looked, the sandbox Mac 2026-11-27).
        /// Written out in the scripts too: their text is fixed, never interpolated (Semgrep,
        /// threat model invariant 11); a test checks both say the same.
        static let notRunning = "Contacts isn't running"

        /// An empty text clears the field (missing value), as an empty text does in the framework.
        /// A birthday without a year is saved in 1604, the year Contacts itself uses for one.
        static let update = """
            on run argv
            if application id "com.apple.AddressBook" is not running then return "Contacts isn't running"
            set personID to item 1 of argv
            set argCount to count of argv
            tell application "Contacts"
            set thePerson to person id personID
            set i to 2
            repeat while i ≤ argCount
            set theKey to item i of argv
            if theKey is "phones" or theKey is "emails" or theKey is "urls" then
            set itemCount to (item (i + 1) of argv) as integer
            set i to i + 2
            if theKey is "phones" then
            delete every phone of thePerson
            else if theKey is "emails" then
            delete every email of thePerson
            else
            delete every url of thePerson
            end if
            repeat itemCount times
            set theLabel to item i of argv
            set theValue to item (i + 1) of argv
            if theKey is "phones" then
            make new phone at end of phones of thePerson with properties {label:theLabel, value:theValue}
            else if theKey is "emails" then
            make new email at end of emails of thePerson with properties {label:theLabel, value:theValue}
            else
            make new url at end of urls of thePerson with properties {label:theLabel, value:theValue}
            end if
            set i to i + 2
            end repeat
            else if theKey is "addresses" then
            set itemCount to (item (i + 1) of argv) as integer
            set i to i + 2
            delete every address of thePerson
            repeat itemCount times
            make new address at end of addresses of thePerson with properties {label:(item i of argv), street:(item (i + 1) of argv), city:(item (i + 2) of argv), state:(item (i + 3) of argv), zip:(item (i + 4) of argv), country:(item (i + 5) of argv)}
            set i to i + 6
            end repeat
            else if theKey is "birthday" then
            if item (i + 1) of argv is "clear" then
            set birth date of thePerson to missing value
            set i to i + 2
            else
            set birth date of thePerson to my dayOf(item (i + 1) of argv, item (i + 2) of argv, item (i + 3) of argv)
            set i to i + 4
            end if
            else
            set theText to item (i + 1) of argv
            if theText is "" then set theText to missing value
            if theKey is "first name" then
            set first name of thePerson to theText
            else if theKey is "middle name" then
            set middle name of thePerson to theText
            else if theKey is "last name" then
            set last name of thePerson to theText
            else if theKey is "nickname" then
            set nickname of thePerson to theText
            else if theKey is "organization" then
            set organization of thePerson to theText
            else if theKey is "job title" then
            set job title of thePerson to theText
            else if theKey is "department" then
            set department of thePerson to theText
            else
            error "unknown field " & theKey
            end if
            set i to i + 2
            end if
            end repeat
            save
            end tell
            return "ok"
            end run

            on dayOf(theYear, theMonth, theDay)
            set theDate to current date
            set day of theDate to 1
            if theYear is "" then
            set year of theDate to 1604
            else
            set year of theDate to (theYear as integer)
            end if
            set month of theDate to (theMonth as integer)
            set day of theDate to (theDay as integer)
            set time of theDate to 12 * hours
            return theDate
            end dayOf
            """

        static let delete = """
            on run argv
            if application id "com.apple.AddressBook" is not running then return "Contacts isn't running"
            tell application "Contacts"
            delete person id (item 1 of argv)
            save
            end tell
            return "ok"
            end run
            """
    }
}

/// Contacts' own process, opened and quit without a window (Constitution IV).
enum ContactsAppProcess {
    @MainActor
    static func openHidden() async -> Bool {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Permissions.contactsApp).isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Permissions.contactsApp)
        else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        guard let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: config) else {
            return false
        }
        // Its scripting answers once it has finished launching (up to 5 s).
        for _ in 0..<50 where !app.isFinishedLaunching { try? await Task.sleep(for: .milliseconds(100)) }
        EventLog.shared.record(.app, "Started Contacts in the background to change a card with a note")
        return true
    }

    /// Every Contacts running now came after Latchkey found none: quit them, except one in front
    /// (the owner brought it up meanwhile, so it is theirs now).
    @MainActor
    static func quitUnlessInFront() async {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Permissions.contactsApp)
        where !app.isActive {
            app.terminate()
        }
    }
}
