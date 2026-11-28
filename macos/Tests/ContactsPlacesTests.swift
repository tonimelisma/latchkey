import Contacts
import Foundation
import Testing

@testable import Latchkey

/// Contacts in memory; the Owner's real ones are never touched.
final class FakeContacts: ContactsBackend, @unchecked Sendable {
    var access = true
    var cards = [
        ContactCard(
            id: "P1", givenName: "Sarah", familyName: "Smith", organization: "Acme",
            phones: [Labeled(label: "mobile", value: "+1 (555) 123-4567")],
            emails: [Labeled(label: "work", value: "sarah@acme.example")], groups: ["Family"]),
        ContactCard(
            id: "P2", givenName: "Sarah", familyName: "Jones", phones: [Labeled(label: "home", value: "555 999 0000")]),
        ContactCard(id: "P3", organization: "Joe's Pizza"),
    ]
    var groupNames = ["G1": "Family"]
    /// A group's own members, for copies that share another group's name.
    var extraMembers: [String: [String]] = [:]
    var lastDraft: ContactDraft?
    /// Run once each, one per call of groups() or all(): iCloud acting between two looks.
    var onGroups: [() -> Void] = []
    var onAll: [() -> Void] = []
    var afterDelete: (() -> Void)?
    /// Cards with a note: the Contacts framework refuses to save them (Cocoa error 134092 for apps
    /// without Apple's notes entitlement, the sandbox Mac 2026-11-26).
    var withNote: Set<String> = []

    /// iCloud giving a card or group a new id.
    func changeID(_ old: String, to new: String) {
        if let i = cards.firstIndex(where: { $0.id == old }) { cards[i].id = new }
        if let name = groupNames.removeValue(forKey: old) { groupNames[new] = name }
    }

    func allowed() -> Bool { access }
    func groups() throws -> [ContactGroup] {
        if !onGroups.isEmpty { onGroups.removeFirst()() }
        return groupNames.map { id, name in
            ContactGroup(id: id, name: name, count: cards.filter { $0.groups.contains(name) }.count)
        }
        .sorted { $0.name < $1.name }
    }
    func all() throws -> [ContactCard] {
        if !onAll.isEmpty { onAll.removeFirst()() }
        return cards
    }
    func card(id: String) throws -> ContactCard {
        guard let c = cards.first(where: { $0.id == id }) else { throw ContactsFailure.notFound(id) }
        return c
    }
    func photo(id: String) throws -> Data? { nil }
    func create(_ draft: ContactDraft) throws -> ContactCard {
        lastDraft = draft
        let c = ContactCard(
            id: "P\(cards.count + 1)", givenName: draft.givenName ?? "", familyName: draft.familyName ?? "",
            organization: draft.organization ?? "", phones: draft.phones ?? [], emails: draft.emails ?? [])
        cards.append(c)
        return c
    }
    func update(id: String, _ draft: ContactDraft) throws -> ContactCard {
        lastDraft = draft
        if withNote.contains(id) { throw ContactsFailure.hasNote }
        var c = try card(id: id)
        if let p = draft.phones { c.phones = p }
        if let e = draft.emails { c.emails = e }
        cards[cards.firstIndex { $0.id == id }!] = c
        return c
    }
    func delete(id: String) throws {
        guard cards.contains(where: { $0.id == id }) else { throw ContactsFailure.notFound(id) }
        if withNote.contains(id) { throw ContactsFailure.hasNote }
        cards.removeAll { $0.id == id }
        afterDelete?()
    }
    func createGroup(name: String) throws -> ContactGroup {
        let id = "G\(groupNames.count + 1)"
        groupNames[id] = name
        return ContactGroup(id: id, name: name, count: 0)
    }
    func renameGroup(id: String, name: String) throws -> ContactGroup {
        guard let old = groupNames[id] else { throw ContactsFailure.notFound(id) }
        groupNames[id] = name
        for i in cards.indices { cards[i].groups = cards[i].groups.map { $0 == old ? name : $0 } }
        return try groups().first { $0.id == id }!
    }
    func deleteGroup(id: String) throws {
        guard let old = groupNames.removeValue(forKey: id) else { throw ContactsFailure.notFound(id) }
        extraMembers[id] = nil
        if !groupNames.values.contains(old) {
            for i in cards.indices { cards[i].groups.removeAll { $0 == old } }
        }
        afterDelete?()
    }
    func memberIDs(groupID: String) throws -> [String] {
        guard let name = groupNames[groupID] else { throw ContactsFailure.notFound(groupID) }
        return extraMembers[groupID] ?? cards.filter { $0.groups.contains(name) }.map(\.id)
    }
    func addMember(contactID: String, groupID: String) throws {
        guard let name = groupNames[groupID], let i = cards.firstIndex(where: { $0.id == contactID }) else {
            throw ContactsFailure.notFound(contactID)
        }
        if !cards[i].groups.contains(name) { cards[i].groups.append(name) }
    }
    func removeMember(contactID: String, groupID: String) throws {
        guard let name = groupNames[groupID], let i = cards.firstIndex(where: { $0.id == contactID }) else {
            throw ContactsFailure.notFound(contactID)
        }
        cards[i].groups.removeAll { $0 == name }
    }
}

/// The Contacts app, scripted: records each script and its arguments, and answers as told. Never
/// the owner's Contacts.
final class FakeContactsApp: ScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _runs: [(script: String, args: [String])] = []
    private var _opened = 0
    private var _quit = 0
    var answer: () throws -> String = { "ok" }
    /// What the app's change does to the cards, as the framework then reads them.
    var onRun: (String, [String]) -> Void = { _, _ in }

    var runs: [(script: String, args: [String])] { lock.withLock { _runs } }
    var opened: Int { lock.withLock { _opened } }
    var quit: Int { lock.withLock { _quit } }

    func run(_ script: String, _ args: [String]) async throws -> String {
        lock.withLock { _runs.append((script, args)) }
        onRun(script, args)
        return try answer()
    }

    var app: ContactsApp {
        ContactsApp(
            runner: self,
            openHidden: { [self] in
                lock.withLock { _opened += 1 }
                return true
            },
            quitUnlessInFront: { [self] in lock.withLock { _quit += 1 } })
    }
}

func resultText(_ r: ToolResult) -> String {
    guard case .array(let items) = r.content else { return "" }
    return items.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
}

@Suite struct ContactsToolTests {
    let fake = FakeContacts()
    let memory = ContactsMemory(settle: .zero)
    let contactsApp = FakeContactsApp()

    func tool(_ name: String) throws -> ToolEntry {
        try #require(
            (ContactsCapability.readTools(backend: fake, memory: memory)
                + ContactsCapability.writeTools(backend: fake, memory: memory, app: contactsApp.app))
                .first { $0.tool.name == name })
    }

    @Test func matchesNamesCompaniesAndPhoneDigits() {
        let sarah = fake.cards[0]
        #expect(ContactMatch.matches(sarah, "sarah smith"))
        #expect(ContactMatch.matches(sarah, "acme"))
        #expect(ContactMatch.matches(sarah, "555-123"))
        #expect(ContactMatch.matches(sarah, "5551234567"))
        #expect(!ContactMatch.matches(sarah, "sarah jones"))
        #expect(!ContactMatch.matches(sarah, "999 0000"))
    }

    @Test func findListsGroupsSearchesAndReads() async throws {
        let overview = resultText(try await tool("contacts_find").handler(.object([:])))
        #expect(overview.contains("3 contacts.") && overview.contains("Family: 1"))
        let sarahs = resultText(try await tool("contacts_find").handler(.object(["query": .string("sarah")])))
        #expect(sarahs.contains("Sarah Smith · Acme · +1 (555) 123-4567") && sarahs.contains("Sarah Jones"))
        let family = resultText(
            try await tool("contacts_find").handler(.object(["query": .string("sarah"), "group": .string("family")])))
        #expect(family.contains("Smith") && !family.contains("Jones"))
        let card = resultText(try await tool("contacts_find").handler(.object(["id": .string("P1")])))
        #expect(card.contains("Phone (mobile): +1 (555) 123-4567") && card.contains("Groups: Family"))
        let pizza = resultText(try await tool("contacts_find").handler(.object(["query": .string("pizza")])))
        #expect(pizza.contains("Joe's Pizza"))
    }

    @Test func createsUpdatesAndDeletes() async throws {
        let change = try tool("contacts_change")
        let made = await change.handler(
            .object(["action": .string("create"), "given_name": .string("Test"), "family_name": .string("Person")]))
        #expect(made.activity == "Claude added Test Person to Contacts")
        let noName = await change.handler(.object(["action": .string("create"), "job_title": .string("CEO")]))
        #expect(noName.isError)
        let phones = await change.handler(
            .object([
                "action": .string("update"), "id": .string("P2"),
                "phones": .array([
                    .object(["label": .string("mobile"), "value": .string("555 222 3333")]), .string("555 444"),
                ]),
            ]))
        #expect(!phones.isError, "\(resultText(phones))")
        #expect(
            fake.lastDraft?.phones == [
                Labeled(label: "mobile", value: "555 222 3333"), Labeled(label: "", value: "555 444"),
            ])
        let gone = await change.handler(.object(["action": .string("delete"), "id": .string("P2")]))
        #expect(gone.activity == "Claude deleted the contact Sarah Jones")
        #expect(!fake.cards.contains { $0.id == "P2" })
        let badDay = await change.handler(
            .object(["action": .string("update"), "id": .string("P1"), "birthday": .string("1990-02-30")]))
        #expect(badDay.isError)
    }

    @Test func createsRenamesAndDeletesGroups() async throws {
        let change = try tool("contacts_change")
        let made = await change.handler(.object(["action": .string("create_group"), "name": .string("Book club")]))
        #expect(!made.isError, "\(resultText(made))")
        #expect(made.activity == "Claude created the contact group “Book club”")
        #expect(fake.groupNames.values.contains("Book club"))
        let twice = await change.handler(.object(["action": .string("create_group"), "name": .string("family")]))
        #expect(twice.isError && fake.groupNames.count == 2)
        let noName = await change.handler(.object(["action": .string("create_group")]))
        #expect(noName.isError)
        let renamed = await change.handler(
            .object(["action": .string("rename_group"), "group": .string("Family"), "name": .string("Relatives")]))
        #expect(renamed.activity == "Claude renamed the contact group “Family” to “Relatives”")
        #expect(fake.cards[0].groups == ["Relatives"])
        let missing = await change.handler(
            .object(["action": .string("rename_group"), "group": .string("Nope"), "name": .string("X")]))
        #expect(missing.isError && resultText(missing).contains("Relatives"))
        let gone = await change.handler(.object(["action": .string("delete_group"), "group": .string("G1")]))
        #expect(gone.activity == "Claude deleted the contact group “Relatives”")
        #expect(resultText(gone).contains("Its 1 card stays in Contacts."), "\(resultText(gone))")
        #expect(fake.groupNames["G1"] == nil)
        #expect(fake.cards.count == 3 && fake.cards[0].groups.isEmpty)
        _ = await change.handler(.object(["action": .string("create_group"), "name": .string("Empty")]))
        let empty = await change.handler(.object(["action": .string("delete_group"), "group": .string("Empty")]))
        #expect(resultText(empty).contains("It had no cards."), "\(resultText(empty))")
    }

    /// Live check 2026-10-29: a new group's id changed within seconds (iCloud); its name still works.
    @Test func aStaleGroupIdSaysToUseTheName() async throws {
        let change = try tool("contacts_change")
        let stale = await change.handler(
            .object([
                "action": .string("delete_group"), "group": .string("0214F621-BF95-4AE3-A402-AB56FC9EDF1C:ABGroup"),
            ]))
        #expect(stale.isError)
        #expect(resultText(stale).contains("No group has the id"), "\(resultText(stale))")
        #expect(resultText(stale).contains("name"))
    }

    @Test func addsAndRemovesGroupMembers() async throws {
        let change = try tool("contacts_change")
        let added = await change.handler(
            .object([
                "action": .string("add_to_group"), "group": .string("family"),
                "ids": .array([.string("P2"), .string("P3")]),
            ]))
        #expect(!added.isError, "\(resultText(added))")
        #expect(added.activity == "Claude added Sarah Jones and Joe's Pizza to the contact group “Family”")
        #expect(fake.cards.allSatisfy { $0.groups == ["Family"] })
        let removed = await change.handler(
            .object(["action": .string("remove_from_group"), "group": .string("Family"), "id": .string("P1")]))
        #expect(removed.activity == "Claude removed Sarah Smith from the contact group “Family”")
        #expect(fake.cards[0].groups.isEmpty)
        let nobody = await change.handler(.object(["action": .string("add_to_group"), "group": .string("Family")]))
        #expect(nobody.isError)
        let unknown = await change.handler(
            .object(["action": .string("add_to_group"), "group": .string("Family"), "id": .string("P9")]))
        #expect(unknown.isError)
    }

    /// A card with a note (the framework refuses it, Cocoa error 134092) is changed through the
    /// Contacts app's scripting, opened hidden and quit after (decided 2026-11-27: "Via Contacts'
    /// scripting"; the sandbox check contacts-card-with-note).
    @Test func aCardWithANoteIsChangedThroughTheContactsApp() async throws {
        fake.withNote = ["P2"]
        contactsApp.onRun = { [fake] script, args in
            if script == ContactsApp.Script.update, args.first == "P2" { fake.cards[1].jobTitle = "Tester" }
        }
        let r = try await tool("contacts_change").handler(
            .object(["action": .string("update"), "id": .string("P2"), "job_title": .string("Tester")]))
        #expect(!r.isError, "\(resultText(r))")
        #expect(resultText(r).contains("Changed Sarah Jones") && resultText(r).contains("Tester"))
        #expect(contactsApp.runs.map(\.script) == [ContactsApp.Script.update])
        #expect(contactsApp.runs.first?.args == ["P2", "job title", "Tester"])
        #expect(contactsApp.opened == 1 && contactsApp.quit == 1, "Contacts opened hidden and quit again")

        let gone = try await tool("contacts_change").handler(
            .object(["action": .string("delete"), "id": .string("P2")]))
        #expect(!gone.isError, "\(resultText(gone))")
        #expect(contactsApp.runs.last?.script == ContactsApp.Script.delete && contactsApp.runs.last?.args == ["P2"])
        #expect(contactsApp.opened == 2 && contactsApp.quit == 2)
    }

    /// A card without a note never goes near the Contacts app.
    @Test func aCardWithoutANoteStaysWithTheFramework() async throws {
        let r = try await tool("contacts_change").handler(
            .object(["action": .string("update"), "id": .string("P2"), "job_title": .string("Tester")]))
        #expect(!r.isError)
        #expect(contactsApp.runs.isEmpty && contactsApp.opened == 0)
    }

    /// Without Control Contacts, the answer names the permission and where to allow it; the app
    /// opened for the change is quit again.
    @Test func aCardWithANoteWithoutControlSaysWhatToAllow() async throws {
        fake.withNote = ["P2"]
        contactsApp.answer = { throw ScriptError.notAllowed }
        let r = try await tool("contacts_change").handler(
            .object(["action": .string("update"), "id": .string("P2"), "job_title": .string("Tester")]))
        #expect(r.isError && resultText(r).contains("Control Contacts"), "\(resultText(r))")
        #expect(contactsApp.quit == 1)
    }

    /// The scripts never start Contacts themselves (an Apple Event starts it shown, with its window):
    /// when Contacts isn't running (it was still quitting when Latchkey looked, the sandbox Mac
    /// 2026-11-27) the change fails, and the Contacts Latchkey opened is quit.
    @Test func theScriptsNeverStartContactsThemselves() async throws {
        for script in [ContactsApp.Script.update, ContactsApp.Script.delete] {
            #expect(
                script.split(separator: "\n").dropFirst().first
                    == #"if application id "com.apple.AddressBook" is not running then return "Contacts isn't running""#
            )
        }
        fake.withNote = ["P2"]
        contactsApp.answer = { ContactsApp.Script.notRunning }
        let r = try await tool("contacts_change").handler(
            .object(["action": .string("update"), "id": .string("P2"), "job_title": .string("Tester")]))
        #expect(r.isError && resultText(r).contains("Contacts isn't running"), "\(resultText(r))")
        #expect(contactsApp.quit == 1)
    }

    /// Every field the draft sets reaches the script, lists whole, labels as Apple stores them.
    @Test func theContactsAppGetsEveryField() {
        let d = ContactDraft(
            givenName: "A", familyName: "", jobTitle: "J",
            phones: [Labeled(label: "mobile", value: "555 1")], emails: [],
            addresses: [
                PostalAddress(
                    label: "home", street: "1 Main", city: "Town", state: "CA", postalCode: "9", country: "US")
            ],
            birthday: "--02-29", urls: [Labeled(label: "", value: "https://x.example")])
        #expect(
            ContactsApp.updateArguments(id: "P1", d) == [
                "P1", "first name", "A", "last name", "", "job title", "J",
                "phones", "1", CNLabelPhoneNumberMobile, "555 1", "emails", "0",
                "urls", "1", CNLabelOther, "https://x.example",
                "addresses", "1", CNLabelHome, "1 Main", "Town", "CA", "9", "US",
                "birthday", "", "2", "29",
            ])
        #expect(
            ContactsApp.updateArguments(id: "P1", ContactDraft(birthday: "1990-05-04")) == [
                "P1", "birthday", "1990", "5", "4",
            ])
        #expect(ContactsApp.updateArguments(id: "P1", ContactDraft(birthday: "")) == ["P1", "birthday", "clear"])
    }

    @Test func theNoteRefusalIsRecognized() {
        #expect(CNContactsBackend.refusedForNote(NSError(domain: NSCocoaErrorDomain, code: 134092)))
        #expect(!CNContactsBackend.refusedForNote(NSError(domain: NSCocoaErrorDomain, code: 134091)))
        #expect(!CNContactsBackend.refusedForNote(NSError(domain: CNErrorDomain, code: 134092)))
    }

    @Test func birthdaysWithAndWithoutYear() {
        #expect(ContactsCapability.birthday("1990-05-17")?.year == 1990)
        #expect(ContactsCapability.birthday("--02-29")?.year == nil)
        #expect(ContactsCapability.birthday("--02-29")?.day == 29)
        #expect(ContactsCapability.birthday("1990-13-01") == nil)
    }

    @Test func buildsAppleContactsWithoutSaving() {
        let c = CNMutableContact()
        CNContactsBackend.apply(
            ContactDraft(
                givenName: "Ann", phones: [Labeled(label: "mobile", value: "555")],
                addresses: [PostalAddress(label: "home", street: "1 Main", city: "Oakland")], birthday: "--03-04"),
            to: c)
        #expect(c.givenName == "Ann")
        #expect(c.phoneNumbers.first?.label == CNLabelPhoneNumberMobile)
        #expect(c.postalAddresses.first?.value.city == "Oakland")
        #expect(c.birthday?.month == 3 && c.birthday?.year == nil)
        #expect(
            CNContactsBackend.card(c).phones == [
                Labeled(label: CNContactsBackend.label(CNLabelPhoneNumberMobile), value: "555")
            ])
    }

    @Test func saysWhatToAllowWithoutAccess() async throws {
        fake.access = false
        let r = try await tool("contacts_find").handler(.object(["query": .string("x")]))
        #expect(r.isError && resultText(r).contains("Settings → Permissions"))
    }
}

/// Cards and groups whose ids iCloud changes, and iCloud's copies (spec 007 FR-724 to FR-727;
/// live checks 2026-10-26 and 2026-10-29). All in memory.
@Suite struct ContactsChangingIDTests {
    let fake = FakeContacts()
    let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
    let memory: ContactsMemory

    init() {
        let clock = clock
        memory = ContactsMemory(now: { clock.value }, settle: .milliseconds(1))
    }

    func call(_ name: String, _ args: [String: JSONValue]) async throws -> ToolResult {
        let tools =
            ContactsCapability.readTools(backend: fake, memory: memory)
            + ContactsCapability.writeTools(backend: fake, memory: memory, app: FakeContactsApp().app)
        return try await #require(tools.first { $0.tool.name == name }).handler(.object(args))
    }

    func change(_ args: [String: JSONValue]) async throws -> ToolResult { try await call("contacts_change", args) }

    /// Creates Test Person (with an email) and answers its id.
    func createTestPerson() async throws -> String {
        let made = try await change([
            "action": .string("create"), "given_name": .string("Test"), "family_name": .string("Person"),
            "emails": .array([.string("test@example.com")]),
        ])
        let id = try #require(fake.cards.last?.id)
        #expect(resultText(made).contains(id))
        return id
    }

    func createGroup(_ name: String) async throws -> String {
        _ = try await change(["action": .string("create_group"), "name": .string(name)])
        return try #require(fake.groupNames.first { $0.value == name }?.key)
    }

    @Test func aNewCardWhoseIdChangedIsFoundAgain() async throws {
        let id = try await createTestPerson()
        fake.changeID(id, to: "ICLOUD-1")
        let read = try await call("contacts_find", ["id": .string(id)])
        #expect(!read.isError, "\(resultText(read))")
        #expect(resultText(read).contains("id changed to ICLOUD-1"))
        let changed = try await change([
            "action": .string("update"), "id": .string(id), "phones": .array([.string("555 1234")]),
        ])
        #expect(!changed.isError && resultText(changed).contains("ICLOUD-1"), "\(resultText(changed))")
        // After a change of Latchkey's own, its new content is still known as Latchkey's.
        fake.changeID("ICLOUD-1", to: "ICLOUD-2")
        let gone = try await change(["action": .string("delete"), "id": .string(id)])
        #expect(!gone.isError, "\(resultText(gone))")
        #expect(gone.activity == "Claude deleted the contact Test Person")
        #expect(!fake.cards.contains { $0.givenName == "Test" })
    }

    @Test func aCardLatchkeyDidNotMakeStillSaysSearchAgain() async throws {
        _ = try await createTestPerson()
        let r = try await change(["action": .string("delete"), "id": .string("SOMEONE-ELSE")])
        #expect(r.isError && resultText(r).contains("No card has the id SOMEONE-ELSE"))
        #expect(fake.cards.count == 4)
    }

    @Test func deletingANewCardDeletesICloudsCopy() async throws {
        let id = try await createTestPerson()
        var copy = try #require(fake.cards.last)
        copy.id = "ICLOUD-COPY"
        copy.emails = [Labeled(label: "home", value: "TEST@example.com")]  // relabelled, same address
        fake.cards.append(copy)
        let gone = try await change(["action": .string("delete"), "id": .string(id)])
        #expect(resultText(gone).contains("Also deleted iCloud's copy"), "\(resultText(gone))")
        #expect(gone.activity == "Claude deleted the contact Test Person and iCloud's copy of it")
        #expect(fake.cards.map(\.id) == ["P1", "P2", "P3"])
    }

    /// The Owner's own card that looks exactly like the new one is never taken for it.
    @Test func anIdenticalCardTheOwnerHadIsNeverTouched() async throws {
        let made = try await change([
            "action": .string("create"), "given_name": .string("Sarah"), "family_name": .string("Jones"),
            "phones": .array([.string("(555) 999-0000")]),
        ])
        #expect(!made.isError)
        let id = try #require(fake.cards.last?.id)
        // iCloud renames the new one; looking it up by its first id must not find P2.
        fake.changeID(id, to: "ICLOUD-1")
        let read = try await call("contacts_find", ["id": .string(id)])
        #expect(resultText(read).contains("ICLOUD-1") && !resultText(read).contains("P2"), "\(resultText(read))")
        let gone = try await change(["action": .string("delete"), "id": .string("ICLOUD-1")])
        #expect(!gone.isError && !resultText(gone).contains("Also deleted"), "\(resultText(gone))")
        #expect(fake.cards.contains { $0.id == "P2" })
        // And when the new card is simply gone, P2 is still not taken for it.
        let again = try await call("contacts_find", ["id": .string(id)])
        #expect(again.isError)
    }

    @Test func aCopySomeoneChangedIsLeftAlone() async throws {
        let id = try await createTestPerson()
        var copy = try #require(fake.cards.last)
        copy.id = "ICLOUD-COPY"
        copy.phones = [Labeled(label: "mobile", value: "555 0000")]
        fake.cards.append(copy)
        let gone = try await change(["action": .string("delete"), "id": .string(id)])
        #expect(!resultText(gone).contains("Also deleted"))
        #expect(fake.cards.contains { $0.id == "ICLOUD-COPY" })
    }

    @Test func twoAlikeCardsLatchkeyMadeAreNotGuessed() async throws {
        let first = try await createTestPerson()
        let second = try await createTestPerson()
        #expect(first != second)
        fake.changeID(first, to: "ICLOUD-1")
        let r = try await call("contacts_find", ["id": .string(first)])
        #expect(r.isError, "two cards could be meant: \(resultText(r))")
        let gone = try await change(["action": .string("delete"), "id": .string(second)])
        #expect(!resultText(gone).contains("Also deleted"))
        #expect(fake.cards.contains { $0.id == "ICLOUD-1" })
    }

    /// Live check 2026-11-16: about a minute after a new card and group were made, iCloud took
    /// both over with new ids and dropped the membership added meanwhile; it is put back (FR-728),
    /// and never for a card Claude took out.
    @Test func aMembershipICloudDroppedIsPutBack() async throws {
        let card = try await createTestPerson()
        let group = try await createGroup("Book club")
        let added = try await change(["action": .string("add_to_group"), "group": .string(group), "id": .string(card)])
        #expect(!added.isError, "\(resultText(added))")
        // iCloud takes both over and drops the membership.
        fake.changeID(card, to: "ICLOUD-P:ABPerson")
        fake.changeID(group, to: "ICLOUD-G:ABGroup")
        if let i = fake.cards.firstIndex(where: { $0.id == "ICLOUD-P:ABPerson" }) { fake.cards[i].groups = [] }
        let found = try await call("contacts_find", ["group": .string("Book club")])
        #expect(resultText(found).contains("Test Person"), "\(resultText(found))")
        #expect(fake.cards.first { $0.id == "ICLOUD-P:ABPerson" }?.groups == ["Book club"])

        // Taken out by Claude: stays out.
        let removed = try await change([
            "action": .string("remove_from_group"), "group": .string("Book club"), "id": .string("ICLOUD-P:ABPerson"),
        ])
        #expect(!removed.isError, "\(resultText(removed))")
        let after = try await call("contacts_find", ["group": .string("Book club")])
        #expect(resultText(after).contains("No contacts found"), "\(resultText(after))")

        // Past the window, nothing is put back.
        _ = try await change([
            "action": .string("add_to_group"), "group": .string("Book club"), "id": .string("ICLOUD-P:ABPerson"),
        ])
        clock.mutate { $0 = $0.addingTimeInterval(ContactsMemory.copyWindow + 1) }
        if let i = fake.cards.firstIndex(where: { $0.id == "ICLOUD-P:ABPerson" }) { fake.cards[i].groups = [] }
        let late = try await call("contacts_find", ["group": .string("Book club")])
        #expect(resultText(late).contains("No contacts found"), "\(resultText(late))")
    }

    @Test func aNewGroupWhoseIdChangedIsFoundAgain() async throws {
        let id = try await createGroup("Book club")
        fake.changeID(id, to: "ICLOUD-G:ABGroup")
        let added = try await change(["action": .string("add_to_group"), "group": .string(id), "id": .string("P2")])
        #expect(!added.isError, "\(resultText(added))")
        #expect(resultText(added).contains("id changed to ICLOUD-G:ABGroup"))
        let renamed = try await change([
            "action": .string("rename_group"), "group": .string(id), "name": .string("Readers"),
        ])
        #expect(!renamed.isError && fake.groupNames["ICLOUD-G:ABGroup"] == "Readers", "\(resultText(renamed))")
        let found = try await call("contacts_find", ["group": .string(id), "query": .string("sarah")])
        #expect(resultText(found).contains("Sarah Jones"), "\(resultText(found))")
        let gone = try await change(["action": .string("delete_group"), "group": .string(id)])
        #expect(!gone.isError && fake.groupNames["ICLOUD-G:ABGroup"] == nil, "\(resultText(gone))")
        #expect(fake.groupNames == ["G1": "Family"])
    }

    /// Live check 2026-10-29: deleting a new group by its first id left iCloud's copy behind.
    @Test func deletingANewGroupDeletesICloudsCopy() async throws {
        let id = try await createGroup("Book club")
        _ = try await change(["action": .string("add_to_group"), "group": .string(id), "id": .string("P2")])
        fake.groupNames["ICLOUD-G"] = "Book club"
        fake.extraMembers["ICLOUD-G"] = ["P2"]
        let gone = try await change(["action": .string("delete_group"), "group": .string(id)])
        #expect(resultText(gone).contains("Also deleted iCloud's copy of the group"), "\(resultText(gone))")
        #expect(gone.activity == "Claude deleted the contact group “Book club” and iCloud's copy of it")
        #expect(fake.groupNames == ["G1": "Family"])
    }

    /// Security review 2026-10-29: a copy deleted at a later change is in that change's activity
    /// (and so its notification), also when the change itself fails.
    @Test func aLaterCopyDeletionIsInTheActivity() async throws {
        let id = try await createGroup("Book club")
        let gone = try await change(["action": .string("delete_group"), "group": .string(id)])
        #expect(!gone.isError)
        fake.groupNames["LATE-G"] = "Book club"  // iCloud's copy turns up after the answer
        let failed = try await change([
            "action": .string("rename_group"), "group": .string("Nope"), "name": .string("X"),
        ])
        #expect(failed.isError)
        #expect(fake.groupNames["LATE-G"] == nil, "the late copy is deleted")
        #expect(failed.alsoDone?.contains("iCloud's leftover copies") == true, "\(failed.alsoDone ?? "nil")")
        #expect(resultText(failed).contains("Book club"), "\(resultText(failed))")
        #expect(fake.cards.count == 3, "cards are never deleted with a group")
    }

    @Test func aSameNamedGroupWithOtherCardsIsLeftAlone() async throws {
        let id = try await createGroup("Book club")
        fake.groupNames["OTHER-G"] = "Book club"
        fake.extraMembers["OTHER-G"] = ["P1"]  // Latchkey never put Sarah Smith in it
        let gone = try await change(["action": .string("delete_group"), "group": .string(id)])
        #expect(resultText(gone).contains("is still there"), "\(resultText(gone))")
        #expect(fake.groupNames["OTHER-G"] == "Book club")
    }

    @Test func theOwnersGroupsAreNeverTouched() async throws {
        let id = try await createGroup("Book club")
        fake.changeID(id, to: "ICLOUD-G")
        // The Owner's Family group is empty, but its name isn't one Latchkey gave.
        fake.cards[0].groups = []
        _ = try await change(["action": .string("delete_group"), "group": .string(id)])
        _ = try await change(["action": .string("create_group"), "name": .string("Other")])
        #expect(fake.groupNames.values.sorted() == ["Family", "Other"])
        // Deleting the Owner's own group looks for no copies.
        fake.groupNames["DUP"] = "Family"
        _ = try await change(["action": .string("delete_group"), "group": .string("G1")])
        #expect(fake.groupNames["DUP"] == "Family")
    }

    @Test func aCopyThatAppearsAMomentLaterIsDeletedToo() async throws {
        let id = try await createGroup("Book club")
        let fake = fake
        fake.afterDelete = {
            // The first look finds nothing; iCloud's copy is there by the second.
            fake.afterDelete = nil
            fake.onGroups = [{}, { fake.groupNames["ICLOUD-G"] = "Book club" }]
        }
        let gone = try await change(["action": .string("delete_group"), "group": .string(id)])
        #expect(resultText(gone).contains("Also deleted iCloud's copy"), "\(resultText(gone))")
        #expect(fake.groupNames == ["G1": "Family"])
    }

    @Test func aCopyThatComesBackLaterGoesAtTheNextChange() async throws {
        let id = try await createTestPerson()
        let group = try await createGroup("Book club")
        _ = try await change(["action": .string("delete"), "id": .string(id)])
        _ = try await change(["action": .string("delete_group"), "group": .string(group)])
        fake.cards.append(
            ContactCard(
                id: "LATE", givenName: "Test", familyName: "Person",
                emails: [Labeled(label: "", value: "test@example.com")]))
        fake.groupNames["LATE-G"] = "Book club"
        clock.mutate { $0 += 60 }
        let next = try await change(["action": .string("create_group"), "name": .string("Other")])
        #expect(resultText(next).contains("leftover copy of the contact Test Person"), "\(resultText(next))")
        #expect(resultText(next).contains("leftover copy of the group “Book club”"))
        #expect(!fake.cards.contains { $0.id == "LATE" } && fake.groupNames["LATE-G"] == nil)
    }

    @Test func copiesAreOnlyDeletedSoonAfterTheCreate() async throws {
        let id = try await createTestPerson()
        clock.mutate { $0 += ContactsMemory.copyWindow + 1 }
        var copy = try #require(fake.cards.last)
        copy.id = "ICLOUD-COPY"
        fake.cards.append(copy)
        let gone = try await change(["action": .string("delete"), "id": .string(id)])
        #expect(!resultText(gone).contains("Also deleted"))
        #expect(fake.cards.contains { $0.id == "ICLOUD-COPY" })
    }

    @Test func fingerprintsIgnoreLabelsAndFormatting() {
        let a = ContactCard(
            id: "A", givenName: "Ann", phones: [Labeled(label: "mobile", value: "+1 (555) 123-4567")],
            emails: [Labeled(label: "home", value: "Ann@Example.com")])
        var b = a
        b.id = "B"
        b.phones = [Labeled(label: "iPhone", value: "+15551234567")]
        b.emails = [Labeled(label: "", value: "ann@example.com")]
        #expect(ContactsMemory.fingerprint(a) == ContactsMemory.fingerprint(b))
        b.urls = [Labeled(label: "", value: "https://ann.example")]
        #expect(ContactsMemory.fingerprint(a) != ContactsMemory.fingerprint(b))
    }
}

/// Maps and location in memory; no network.
final class FakePlaces: PlacesBackend, @unchecked Sendable {
    var access = LocationAccess.allowed
    let here = Coordinate(latitude: 37.33, longitude: -122.03)
    var lastSearchCenter: Coordinate?
    var lastMode: String?

    func locationAccess() -> LocationAccess { access }
    func currentFix() async throws -> Fix {
        guard access == .allowed else { throw PlacesFailure.location(access) }
        return Fix(coordinate: here, accuracy: 35, at: Date())
    }
    func reverse(_ c: Coordinate) async throws -> Place? {
        Place(name: "Home", address: "1 Main St, Springfield, CA", coordinate: c)
    }
    func geocode(_ address: String) async throws -> [Place] {
        address == "nowhere"
            ? []
            : [
                Place(
                    name: address, address: "\(address), CA", coordinate: Coordinate(latitude: 37.6, longitude: -122.4))
            ]
    }
    func search(_ query: String, near: Coordinate?, limit: Int) async throws -> [Place] {
        lastSearchCenter = near
        return [
            Place(
                name: "Philz Coffee", address: "1 Main St", coordinate: Coordinate(latitude: 37.34, longitude: -122.03),
                category: "cafe")
        ]
    }
    func route(from: Coordinate, to: Coordinate, mode: String, departAt: Date?, arriveBy: Date?) async throws -> Route {
        lastMode = mode
        return mode == "transit"
            ? Route(distance: nil, seconds: 3600, departure: Date(), arrival: Date().addingTimeInterval(3600))
            : Route(distance: 42_000, seconds: 2_700, name: "I-680 S", steps: ["Head south", "Merge onto I-680 S"])
    }
}

@Suite struct LocationToolTests {
    let fake = FakePlaces()

    func tool(_ name: String) throws -> ToolEntry {
        try #require(LocationCapability.tools(backend: fake, zone: { .current }).first { $0.tool.name == name })
    }

    @Test func readsTheMacLocationWithAddress() async throws {
        let t = resultText(try await tool("location_read").handler(.object([:])))
        #expect(t.contains("37.33000,-122.03000") && t.contains("within about 35 m"))
        #expect(t.contains("Springfield"))
    }

    @Test func explainsMissingLocation() async throws {
        fake.access = .servicesOff
        let r = try await tool("location_read").handler(.object([:]))
        #expect(r.isError && resultText(r).contains("Location Services are turned off"))
        // Maps still works without the Mac's location.
        let search = try await tool("maps_find").handler(.object(["query": .string("coffee")]))
        #expect(!search.isError && fake.lastSearchCenter == nil)
    }

    @Test func searchesNearTheMacOrAnAddress() async throws {
        let near = resultText(try await tool("maps_find").handler(.object(["query": .string("coffee")])))
        #expect(near.contains("Philz Coffee (cafe), 1 Main St") && near.contains("near the Mac"))
        #expect(fake.lastSearchCenter == fake.here)
        _ = try await tool("maps_find").handler(.object(["query": .string("coffee"), "near": .string("37.5,-122.2")]))
        #expect(fake.lastSearchCenter == Coordinate(latitude: 37.5, longitude: -122.2))
    }

    /// decided 2026-11-23 ("Only nearby, else none"): with near, a far place of a similar name is
    /// left out, and nothing nearby is said as such ("BARC" near Ubud gave Basra, Iraq).
    @Test func withNearOnlyNearbyPlaces() async throws {
        let near = resultText(
            try await tool("maps_find").handler(.object(["query": .string("coffee"), "near": .string("37.33,-122.03")])))
        #expect(near.contains("Philz Coffee"), "1 km away: kept")
        let far = try await tool("maps_find").handler(
            .object(["query": .string("coffee"), "near": .string("-8.65,115.2")]))
        #expect(far.isError && resultText(far).contains("within 50 km of"))
        #expect(!resultText(far).contains("Philz"))
    }

    @Test func givesDirectionsAndTransitTimes() async throws {
        let drive = resultText(try await tool("maps_find").handler(.object(["to": .string("SFO")])))
        #expect(drive.contains("Driving from the Mac to SFO, CA: 45 min, 42.0 km (26.1 mi) via I-680 S."))
        #expect(drive.contains("2. Merge onto I-680 S"))
        let transit = resultText(
            try await tool("maps_find").handler(
                .object(["to": .string("SFO"), "from": .string("Oakland"), "mode": .string("transit")])))
        #expect(transit.contains("Transit from Oakland, CA to SFO, CA: 1 h") && transit.contains("only the time"))
    }

    @Test func directionsToAPlaceByName() async throws {
        let t = resultText(try await tool("maps_find").handler(.object(["to": .string("nowhere")])))
        #expect(
            t.contains("Driving from the Mac to Philz Coffee"), "a name that isn't an address is searched as a place")
    }

    @Test func geocodesBothWays() async throws {
        let there = resultText(try await tool("maps_find").handler(.object(["address": .string("1 Infinite Loop")])))
        #expect(there.contains("37.60000,-122.40000"))
        let back = resultText(try await tool("maps_find").handler(.object(["address": .string("37.33,-122.03")])))
        #expect(back.contains("is 1 Main St"))
        let none = try await tool("maps_find").handler(.object(["address": .string("nowhere")]))
        #expect(none.isError && resultText(none).contains("found nothing"))
    }

    @Test func wantsExactlyOneQuestion() async throws {
        let both = try await tool("maps_find").handler(.object(["query": .string("x"), "to": .string("y")]))
        #expect(both.isError)
        let neither = try await tool("maps_find").handler(.object([:]))
        #expect(neither.isError)
    }
}

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-724, FR-727, FR-728
