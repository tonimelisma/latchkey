import Contacts
import Foundation

/// Contacts as the tools use them (spec 007 plan D3). The app's backend is the Contacts
/// framework; tests use one in memory and never touch the Owner's contacts.
struct Labeled: Sendable, Equatable {
    var label: String
    var value: String
}

struct PostalAddress: Sendable, Equatable {
    var label = ""
    var street = ""
    var city = ""
    var state = ""
    var postalCode = ""
    var country = ""

    var oneLine: String {
        [
            street.replacingOccurrences(of: "\n", with: ", "), city,
            [state, postalCode].filter { !$0.isEmpty }.joined(separator: " "), country,
        ]
        .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct ContactCard: Sendable, Equatable {
    var id: String
    var givenName = ""
    var middleName = ""
    var familyName = ""
    var nickname = ""
    var organization = ""
    var jobTitle = ""
    var department = ""
    var phones: [Labeled] = []
    var emails: [Labeled] = []
    var addresses: [PostalAddress] = []
    /// `YYYY-MM-DD`, or `--MM-DD` without a year.
    var birthday: String?
    var dates: [Labeled] = []
    var urls: [Labeled] = []
    var related: [Labeled] = []
    var groups: [String] = []
    var hasPhoto = false

    var name: String {
        let full = [givenName, middleName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
        return full.isEmpty ? (organization.isEmpty ? "(no name)" : organization) : full
    }
}

/// Fields a change sets; nil leaves a field as it is, an empty text or list clears it.
struct ContactDraft: Sendable, Equatable {
    var givenName: String?
    var middleName: String?
    var familyName: String?
    var nickname: String?
    var organization: String?
    var jobTitle: String?
    var department: String?
    var phones: [Labeled]?
    var emails: [Labeled]?
    var addresses: [PostalAddress]?
    var birthday: String?
    var urls: [Labeled]?

    var isEmpty: Bool { self == ContactDraft() }
}

struct ContactGroup: Sendable, Equatable {
    var id: String
    var name: String
    var count: Int
}

enum ContactsFailure: Error, Equatable {
    case noAccess
    case notFound(String)
    case noSuchGroup(String, available: [String])
    case failed(String)
}

protocol ContactsBackend: Sendable {
    func allowed() -> Bool
    func groups() throws -> [ContactGroup]
    func all() throws -> [ContactCard]
    func card(id: String) throws -> ContactCard
    func photo(id: String) throws -> Data?
    func create(_ draft: ContactDraft) throws -> ContactCard
    func update(id: String, _ draft: ContactDraft) throws -> ContactCard
    func delete(id: String) throws
    func createGroup(name: String) throws -> ContactGroup
    func renameGroup(id: String, name: String) throws -> ContactGroup
    /// Deletes the group only; its cards stay in Contacts.
    func deleteGroup(id: String) throws
    func addMember(contactID: String, groupID: String) throws
    func removeMember(contactID: String, groupID: String) throws
    /// The ids of the cards in a group.
    func memberIDs(groupID: String) throws -> [String]
}

extension ContactsBackend {
    /// The group a name or id names.
    func resolveGroup(_ nameOrID: String) throws -> ContactGroup {
        let all = try groups()
        guard
            let g = all.first(where: { $0.id == nameOrID })
                ?? all.first(where: { $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame })
        else { throw ContactsFailure.noSuchGroup(nameOrID, available: all.map(\.name)) }
        return g
    }
}

enum ContactMatch {
    /// Whether the card matches: words in its names, nickname, company, or emails, or the digits
    /// of one of its phone numbers (spec 007 FR-721).
    static func matches(_ c: ContactCard, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let digits = ContactBook.digits(q)
        if digits.count >= 4, q.allSatisfy({ $0.isNumber || " +-().".contains($0) }) {
            return c.phones.contains { ContactBook.digits($0.value).contains(digits) }
        }
        let texts = [c.name, c.nickname, c.organization] + c.emails.map(\.value)
        // Every word must appear somewhere ("sarah smith" matches Sarah J. Smith).
        return q.split(separator: " ").allSatisfy { word in
            texts.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

/// The Owner's Contacts through the Contacts framework.
final class CNContactsBackend: ContactsBackend, @unchecked Sendable {
    static let shared = CNContactsBackend()
    private let store = CNContactStore()

    func allowed() -> Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    private func check() throws { guard allowed() else { throw ContactsFailure.noAccess } }

    private static var keys: [CNKeyDescriptor] {
        [
            CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
            CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactDepartmentNameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey,
            CNContactBirthdayKey, CNContactDatesKey, CNContactUrlAddressesKey, CNContactRelationsKey,
            CNContactImageDataAvailableKey, CNContactIdentifierKey,
        ] as [CNKeyDescriptor]
    }

    func groups() throws -> [ContactGroup] {
        try check()
        return try store.groups(matching: nil).map { g in
            let n =
                (try? store.unifiedContacts(
                    matching: CNContact.predicateForContactsInGroup(withIdentifier: g.identifier),
                    keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
                ).count) ?? 0
            return ContactGroup(id: g.identifier, name: g.name, count: n)
        }.sorted { $0.name < $1.name }
    }

    private func membership() -> [String: [String]] {
        var byContact: [String: [String]] = [:]
        for g in (try? store.groups(matching: nil)) ?? [] {
            let members =
                (try? store.unifiedContacts(
                    matching: CNContact.predicateForContactsInGroup(withIdentifier: g.identifier),
                    keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])) ?? []
            for m in members { byContact[m.identifier, default: []].append(g.name) }
        }
        return byContact
    }

    func all() throws -> [ContactCard] {
        try check()
        let groups = membership()
        var cards: [ContactCard] = []
        try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: Self.keys)) { c, _ in
            var card = Self.card(c)
            card.groups = groups[c.identifier] ?? []
            cards.append(card)
        }
        return cards
    }

    private func cn(_ id: String, keys: [CNKeyDescriptor] = CNContactsBackend.keys) throws -> CNContact {
        do { return try store.unifiedContact(withIdentifier: id, keysToFetch: keys) } catch {
            throw ContactsFailure.notFound(id)
        }
    }

    func card(id: String) throws -> ContactCard {
        try check()
        var card = Self.card(try cn(id))
        card.groups = membership()[id] ?? []
        return card
    }

    func photo(id: String) throws -> Data? {
        try check()
        return try cn(id, keys: [CNContactImageDataKey as CNKeyDescriptor]).imageData
    }

    func create(_ draft: ContactDraft) throws -> ContactCard {
        try check()
        let c = CNMutableContact()
        Self.apply(draft, to: c)
        let save = CNSaveRequest()
        save.add(c, toContainerWithIdentifier: nil)
        try execute(save)
        return try card(id: c.identifier)
    }

    func update(id: String, _ draft: ContactDraft) throws -> ContactCard {
        try check()
        guard let c = try cn(id).mutableCopy() as? CNMutableContact else { throw ContactsFailure.notFound(id) }
        Self.apply(draft, to: c)
        let save = CNSaveRequest()
        save.update(c)
        try execute(save)
        return try card(id: id)
    }

    func delete(id: String) throws {
        try check()
        guard let c = try cn(id).mutableCopy() as? CNMutableContact else { throw ContactsFailure.notFound(id) }
        let save = CNSaveRequest()
        save.delete(c)
        try execute(save)
    }

    // MARK: groups

    private func cnGroup(_ id: String) throws -> CNMutableGroup {
        let found = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [id])).first
        guard let g = found?.mutableCopy() as? CNMutableGroup else { throw ContactsFailure.notFound(id) }
        return g
    }

    private func group(id: String) throws -> ContactGroup {
        guard let g = try groups().first(where: { $0.id == id }) else { throw ContactsFailure.notFound(id) }
        return g
    }

    func createGroup(name: String) throws -> ContactGroup {
        try check()
        let g = CNMutableGroup()
        g.name = name
        let save = CNSaveRequest()
        save.add(g, toContainerWithIdentifier: nil)
        try execute(save)
        return ContactGroup(id: g.identifier, name: g.name, count: 0)
    }

    func renameGroup(id: String, name: String) throws -> ContactGroup {
        try check()
        let g = try cnGroup(id)
        g.name = name
        let save = CNSaveRequest()
        save.update(g)
        try execute(save)
        return try group(id: id)
    }

    func deleteGroup(id: String) throws {
        try check()
        let save = CNSaveRequest()
        save.delete(try cnGroup(id))
        try execute(save)
    }

    func addMember(contactID: String, groupID: String) throws {
        try check()
        let save = CNSaveRequest()
        save.addMember(try cn(contactID, keys: [CNContactIdentifierKey as CNKeyDescriptor]), to: try cnGroup(groupID))
        try execute(save)
    }

    /// Removes the card from the group: the group holds one of the card's linked records (iCloud's
    /// copy once iCloud took the card over), not the unified card Claude sees, and removing the
    /// unified one answered success but left it there (live check 2026-11-07). So each record of
    /// the card that the group holds is removed, and the group is read back.
    func removeMember(contactID: String, groupID: String) throws {
        try check()
        let group = try cnGroup(groupID)
        let keys = [CNContactIdentifierKey as CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.predicate = CNContact.predicateForContactsInGroup(withIdentifier: groupID)
        request.unifyResults = false
        var records: [CNContact] = []
        let store = self.store
        do {
            try store.enumerateContacts(with: request) { record, _ in
                let unified = try? store.unifiedContact(withIdentifier: record.identifier, keysToFetch: keys)
                if record.identifier == contactID || unified?.identifier == contactID { records.append(record) }
            }
        } catch { throw ContactsFailure.failed(error.localizedDescription) }
        guard !records.isEmpty else { return }  // not in the group
        let save = CNSaveRequest()
        for record in records { save.removeMember(record, from: group) }
        try execute(save)
        if try memberIDs(groupID: groupID).contains(contactID) {
            throw ContactsFailure.failed("Contacts kept the card in the group")
        }
    }

    func memberIDs(groupID: String) throws -> [String] {
        try check()
        return try store.unifiedContacts(
            matching: CNContact.predicateForContactsInGroup(withIdentifier: groupID),
            keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
        ).map(\.identifier)
    }

    private func execute(_ save: CNSaveRequest) throws {
        // Messages' names reload on the store's change notification (ContactBook, plan D3).
        do { try store.execute(save) } catch { throw ContactsFailure.failed(error.localizedDescription) }
    }

    // MARK: conversion

    /// Apple's stored labels ("_$!<Mobile>!$_") as words.
    static func label(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw)
    }

    /// Words to Apple's labels, so other apps show them in the Owner's language.
    static func storedLabel(_ word: String) -> String {
        switch word.lowercased() {
        case "home": CNLabelHome
        case "work": CNLabelWork
        case "other": CNLabelOther
        case "mobile", "cell": CNLabelPhoneNumberMobile
        case "iphone": CNLabelPhoneNumberiPhone
        case "main": CNLabelPhoneNumberMain
        case "school": CNLabelSchool
        case "": CNLabelOther
        default: word
        }
    }

    static func day(_ c: DateComponents?) -> String? {
        guard let c, let m = c.month, let d = c.day else { return nil }
        return c.year.map { String(format: "%04d-%02d-%02d", $0, m, d) } ?? String(format: "--%02d-%02d", m, d)
    }

    static func card(_ c: CNContact) -> ContactCard {
        ContactCard(
            id: c.identifier, givenName: c.givenName, middleName: c.middleName, familyName: c.familyName,
            nickname: c.nickname, organization: c.organizationName, jobTitle: c.jobTitle,
            department: c.departmentName,
            phones: c.phoneNumbers.map { Labeled(label: label($0.label), value: $0.value.stringValue) },
            emails: c.emailAddresses.map { Labeled(label: label($0.label), value: $0.value as String) },
            addresses: c.postalAddresses.map {
                PostalAddress(
                    label: label($0.label), street: $0.value.street, city: $0.value.city, state: $0.value.state,
                    postalCode: $0.value.postalCode, country: $0.value.country)
            },
            birthday: day(c.birthday),
            dates: c.dates.compactMap { d in
                day(d.value as DateComponents).map { Labeled(label: label(d.label), value: $0) }
            },
            urls: c.urlAddresses.map { Labeled(label: label($0.label), value: $0.value as String) },
            related: c.contactRelations.map { Labeled(label: label($0.label), value: $0.value.name) },
            hasPhoto: c.imageDataAvailable)
    }

    static func apply(_ d: ContactDraft, to c: CNMutableContact) {
        if let v = d.givenName { c.givenName = v }
        if let v = d.middleName { c.middleName = v }
        if let v = d.familyName { c.familyName = v }
        if let v = d.nickname { c.nickname = v }
        if let v = d.organization { c.organizationName = v }
        if let v = d.jobTitle { c.jobTitle = v }
        if let v = d.department { c.departmentName = v }
        if let v = d.phones {
            c.phoneNumbers = v.map {
                CNLabeledValue(label: storedLabel($0.label), value: CNPhoneNumber(stringValue: $0.value))
            }
        }
        if let v = d.emails {
            c.emailAddresses = v.map { CNLabeledValue(label: storedLabel($0.label), value: $0.value as NSString) }
        }
        if let v = d.urls {
            c.urlAddresses = v.map { CNLabeledValue(label: storedLabel($0.label), value: $0.value as NSString) }
        }
        if let v = d.addresses {
            c.postalAddresses = v.map { a in
                let p = CNMutablePostalAddress()
                p.street = a.street
                p.city = a.city
                p.state = a.state
                p.postalCode = a.postalCode
                p.country = a.country
                return CNLabeledValue(label: storedLabel(a.label), value: p)
            }
        }
        if let b = d.birthday { c.birthday = b.isEmpty ? nil : ContactsCapability.birthday(b) }
    }
}
