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
    var lastDraft: ContactDraft?

    func allowed() -> Bool { access }
    func groups() throws -> [ContactGroup] { [ContactGroup(id: "G1", name: "Family", count: 1)] }
    func all() throws -> [ContactCard] { cards }
    func card(id: String) throws -> ContactCard {
        guard let c = cards.first(where: { $0.id == id }) else { throw ContactsFailure.notFound(id) }
        return c
    }
    func photo(id: String) throws -> Data? { nil }
    func create(_ draft: ContactDraft) throws -> ContactCard {
        lastDraft = draft
        let c = ContactCard(
            id: "P\(cards.count + 1)", givenName: draft.givenName ?? "", familyName: draft.familyName ?? "")
        cards.append(c)
        return c
    }
    func update(id: String, _ draft: ContactDraft) throws -> ContactCard {
        lastDraft = draft
        var c = try card(id: id)
        if let p = draft.phones { c.phones = p }
        cards[cards.firstIndex { $0.id == id }!] = c
        return c
    }
    func delete(id: String) throws { cards.removeAll { $0.id == id } }
}

func resultText(_ r: ToolResult) -> String {
    guard case .array(let items) = r.content else { return "" }
    return items.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
}

@Suite struct ContactsToolTests {
    let fake = FakeContacts()

    func tool(_ name: String) throws -> ToolEntry {
        try #require(
            (ContactsCapability.readTools(backend: fake) + ContactsCapability.writeTools(backend: fake))
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
