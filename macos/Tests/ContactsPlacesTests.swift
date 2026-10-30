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
        var c = try card(id: id)
        if let p = draft.phones { c.phones = p }
        if let e = draft.emails { c.emails = e }
        cards[cards.firstIndex { $0.id == id }!] = c
        return c
    }
    func delete(id: String) throws {
        guard cards.contains(where: { $0.id == id }) else { throw ContactsFailure.notFound(id) }
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

func resultText(_ r: ToolResult) -> String {
    guard case .array(let items) = r.content else { return "" }
    return items.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
}

@Suite struct ContactsToolTests {
    let fake = FakeContacts()
    let memory = ContactsMemory(settle: .zero)

    func tool(_ name: String) throws -> ToolEntry {
        try #require(
            (ContactsCapability.readTools(backend: fake, memory: memory)
                + ContactsCapability.writeTools(backend: fake, memory: memory))
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
            + ContactsCapability.writeTools(backend: fake, memory: memory)
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
    let here = Coordinate(latitude: 37.9, longitude: -122.06)
    var lastSearchCenter: Coordinate?
    var lastMode: String?

    func locationAccess() -> LocationAccess { access }
    func currentFix() async throws -> Fix {
        guard access == .allowed else { throw PlacesFailure.location(access) }
        return Fix(coordinate: here, accuracy: 35, at: Date())
    }
    func reverse(_ c: Coordinate) async throws -> Place? {
        Place(name: "Home", address: "1406 N Broadway, Walnut Creek, CA", coordinate: c)
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
                name: "Philz Coffee", address: "1 Main St", coordinate: Coordinate(latitude: 37.91, longitude: -122.06),
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
        #expect(t.contains("37.90000,-122.06000") && t.contains("within about 35 m"))
        #expect(t.contains("Walnut Creek"))
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
        let back = resultText(try await tool("maps_find").handler(.object(["address": .string("37.9,-122.06")])))
        #expect(back.contains("is 1406 N Broadway"))
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
