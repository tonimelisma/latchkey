import Foundation

/// The Owner's Contacts (spec 007 US3), through the Contacts framework (plan D3).
enum ContactsCapability {
    static func make() -> Capability {
        Capability(
            id: CapabilityRegistry.contacts, title: "Contacts",
            summary: "Look up, add, change, and delete contacts and groups",
            readTools: readTools(backend: CNContactsBackend.shared, memory: .shared),
            writeTools: writeTools(backend: CNContactsBackend.shared, memory: .shared))
    }

    static let noAccess = """
        Latchkey can't see the contacts: macOS hasn't allowed it. The Mac's owner can allow \
        Contacts in Latchkey's Settings → Permissions.
        """

    static let maxCards = 100

    /// `memory` is what Latchkey created in this run; read and write tools share one (FR-724).
    static func readTools(backend: any ContactsBackend, memory: ContactsMemory) -> [ToolEntry] {
        [
            ToolEntry(
                tool: .make(
                    "contacts_find", title: "Find Contacts",
                    description: """
                        Searches the Mac's Contacts by name, nickname, company, email address, or phone number, \
                        with each card's id. With id: the card in full (phones, emails, addresses, birthday, \
                        dates, web addresses, related names, groups); with photo: true, its picture. With \
                        nothing: the groups and how many contacts there are.
                        """,
                    input: [
                        "id": .stringParam("A card's id, to read it in full"),
                        "query": .stringParam("Words in a name, company, or email, or a phone number"),
                        "group": .stringParam("Only cards in this group (name or id)"),
                        "photo": .boolParam("With id: show the card's picture"),
                        "limit": .integerParam("At most this many cards (default 20, up to 100)"),
                    ], readOnly: true, deadlineMS: 15_000),
                handler: { args in await run { try find(args, backend, memory) } })
        ]
    }

    static let changeActions = [
        "create", "update", "delete", "create_group", "rename_group", "delete_group", "add_to_group",
        "remove_from_group",
    ]

    static func writeTools(backend: any ContactsBackend, memory: ContactsMemory) -> [ToolEntry] {
        let labeled: (String) -> JSONValue = { what in
            .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "label": .stringParam("home, work, mobile, iphone, main, other, or your own"),
                        "value": .stringParam(what),
                    ]),
                    "required": .array([.string("value")]),
                ]),
                "description": .string("The whole list (it replaces the card's); [] removes all"),
            ])
        }
        return [
            ToolEntry(
                tool: .make(
                    "contacts_change", title: "Change Contacts",
                    description: """
                        Creates, changes, or deletes a card in the Mac's Contacts. action: create (at least a name \
                        or company), update (id and only the fields to change; a list such as phones replaces the \
                        card's whole list, so read the card first), delete (id; the card is removed from every \
                        device the Contacts sync with). An empty text clears a field. birthday is YYYY-MM-DD, or \
                        --MM-DD without a year. Groups: create_group (name), rename_group (group and the new name), \
                        delete_group (group; its cards stay in Contacts), add_to_group and remove_from_group (group \
                        and id, or ids for several cards).
                        """,
                    input: [
                        "action": .enumParam(changeActions, "What to do"),
                        "id": .stringParam("The card's id, from contacts_find"),
                        "given_name": .stringParam("First name"), "middle_name": .stringParam("Middle name"),
                        "family_name": .stringParam("Last name"), "nickname": .stringParam("Nickname"),
                        "organization": .stringParam("Company"), "job_title": .stringParam("Job title"),
                        "department": .stringParam("Department"),
                        "phones": labeled("The phone number"), "emails": labeled("The email address"),
                        "urls": labeled("The web address"),
                        "addresses": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object(
                                    Dictionary(
                                        uniqueKeysWithValues: [
                                            "label", "street", "city", "state", "postal_code", "country",
                                        ]
                                        .map {
                                            ($0, JSONValue.stringParam($0.replacingOccurrences(of: "_", with: " ")))
                                        })),
                            ]),
                            "description": .string("The whole list of postal addresses; [] removes all"),
                        ]),
                        "birthday": .stringParam("YYYY-MM-DD or --MM-DD"),
                        "group": .stringParam("The group (name or id, from contacts_find)"),
                        "name": .stringParam("For create_group and rename_group: the group's name"),
                        "ids": .object([
                            "type": .string("array"), "items": .object(["type": .string("string")]),
                            "description": .string("For add_to_group and remove_from_group: several cards' ids"),
                        ]),
                    ], required: ["action"], readOnly: false, destructive: true, deadlineMS: 15_000),
                handler: { args in await run { try await change(args, backend, memory) } })
        ]
    }

    // MARK: find

    static func find(_ args: JSONValue, _ backend: any ContactsBackend, _ memory: ContactsMemory) throws
        -> ToolResult
    {
        guard backend.allowed() else { throw ContactsFailure.noAccess }
        if let id = args["id"]?.stringValue, !id.isEmpty {
            let (card, moved) = try card(id, backend, memory)
            if args["photo"]?.boolValue == true {
                guard let data = try backend.photo(id: card.id), let image = try? ImagePrep.prepare(data: data) else {
                    return .text("This card has no picture." + (moved.map { " " + $0 } ?? ""))
                }
                return .image(image.data, mimeType: image.mimeType)
            }
            return .text(describe(card) + (moved.map { "\n" + $0 } ?? ""))
        }
        var cards = try backend.all()
        if !args.hasAny("query", "group") {
            let groups = try backend.groups()
            var lines = ["\(cards.count) contacts."]
            if !groups.isEmpty {
                lines.append("Groups:")
                lines += groups.map { "- \($0.name): \($0.count) (id \($0.id))" }
            }
            lines.append("Search with query to find someone.")
            return .text(lines.joined(separator: "\n"))
        }
        if let g = args["group"]?.stringValue, !g.isEmpty {
            let group = try group(g, backend, memory).group
            cards = cards.filter { $0.groups.contains(group.name) }
        }
        let query = args["query"]?.stringValue ?? ""
        cards = cards.filter { ContactMatch.matches($0, query) }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let limit = min(try args.integer("limit", in: 1...Int.max) ?? 20, maxCards)
        var lines = cards.isEmpty ? ["No contacts found."] : cards.prefix(limit).map { "- " + line($0) }
        if cards.count > limit { lines.append("… and \(cards.count - limit) more; narrow the search or raise limit.") }
        return .text(lines.joined(separator: "\n"))
    }

    static func line(_ c: ContactCard) -> String {
        var parts = [c.name]
        if !c.organization.isEmpty && c.name != c.organization { parts.append(c.organization) }
        if let p = c.phones.first { parts.append(p.value) }
        if let e = c.emails.first { parts.append(e.value) }
        return parts.joined(separator: " · ") + " (id \(c.id))"
    }

    static func describe(_ c: ContactCard) -> String {
        var lines = ["Name: \(c.name)"]
        let fields = [
            ("Nickname", c.nickname), ("Company", c.organization), ("Job title", c.jobTitle),
            ("Department", c.department),
        ]
        for (title, value) in fields where !value.isEmpty { lines.append("\(title): \(value)") }
        func list(_ title: String, _ items: [Labeled]) {
            for i in items { lines.append("\(title)\(i.label.isEmpty ? "" : " (\(i.label))"): \(i.value)") }
        }
        list("Phone", c.phones)
        list("Email", c.emails)
        for a in c.addresses { lines.append("Address\(a.label.isEmpty ? "" : " (\(a.label))"): \(a.oneLine)") }
        if let b = c.birthday { lines.append("Birthday: \(b)") }
        list("Date", c.dates)
        list("Web", c.urls)
        list("Related", c.related)
        if !c.groups.isEmpty { lines.append("Groups: \(c.groups.joined(separator: ", "))") }
        if c.hasPhoto { lines.append("Has a picture (photo: true to see it).") }
        lines.append("id: \(c.id)")
        return lines.joined(separator: "\n")
    }

    // MARK: ids that change (FR-724, FR-725)

    /// The card with this id, or, when the id is one of a card Latchkey made in this run that
    /// iCloud gave a new id, that card under its new id with a line saying so.
    static func card(_ id: String, _ backend: any ContactsBackend, _ memory: ContactsMemory) throws
        -> (card: ContactCard, moved: String?)
    {
        do { return (try backend.card(id: id), nil) } catch ContactsFailure.notFound(let missing) {
            guard let found = try memory.refindCard(id, in: backend) else { throw ContactsFailure.notFound(missing) }
            return (found, "\(found.name)'s id changed to \(found.id) (iCloud took the card over); use that one.")
        }
    }

    /// The group a name or id names, found again by its name when the id is one of a group
    /// Latchkey made in this run that iCloud gave a new id.
    static func group(_ nameOrID: String, _ backend: any ContactsBackend, _ memory: ContactsMemory) throws
        -> (group: ContactGroup, moved: String?)
    {
        do { return (try backend.resolveGroup(nameOrID), nil) } catch let failure as ContactsFailure {
            guard case .noSuchGroup = failure, let found = try memory.refindGroup(nameOrID, in: backend) else {
                throw failure
            }
            return (found, "The group's id changed to \(found.id) (iCloud took it over).")
        }
    }

    // MARK: change

    static func change(_ args: JSONValue, _ backend: any ContactsBackend, _ memory: ContactsMemory) async throws
        -> ToolResult
    {
        guard backend.allowed() else { throw ContactsFailure.noAccess }
        // iCloud's copies of things deleted earlier that came back after that answer (FR-727).
        let leftovers = memory.isEmpty ? [] : try memory.sweepLeftovers(in: backend)
        var r = try await changeOne(args, backend, memory)
        for line in leftovers { r.appendText(line) }
        return r
    }

    private static func changeOne(_ args: JSONValue, _ backend: any ContactsBackend, _ memory: ContactsMemory)
        async throws -> ToolResult
    {
        let action = args["action"]?.stringValue
        func id() throws -> String {
            guard let id = args["id"]?.stringValue, !id.isEmpty else {
                throw ArgumentError(message: "Give the card's id, from contacts_find.")
            }
            return id
        }
        func with(_ moved: String?, _ text: String) -> String { moved.map { text + "\n" + $0 } ?? text }
        switch action {
        case "create":
            let d = try draft(args)
            guard [d.givenName, d.familyName, d.organization, d.nickname].contains(where: { !($0 ?? "").isEmpty })
            else {
                throw ArgumentError(message: "Give at least a name or a company.")
            }
            // Cards that already look like the new one are never taken for it (FR-724).
            let before = try backend.all()
            let c = try backend.create(d)
            memory.rememberCreated(c, before: before)
            var r = ToolResult.text("Added \(c.name) to Contacts. id \(c.id)")
            r.activity = "Claude added \(c.name) to Contacts"
            r.made = "the contact \(c.name)"
            return r
        case "update":
            let d = try draft(args)
            guard !d.isEmpty else { throw ArgumentError(message: "Give at least one field to change.") }
            let (old, moved) = try card(try id(), backend, memory)
            let key = memory.cardRecord(for: old)
            let before = key == nil ? [] : try backend.all()
            let c = try backend.update(id: old.id, d)
            if let key { memory.changed(key, to: c, before: before) }
            var r = ToolResult.text(with(moved, "Changed \(c.name):\n\(describe(c))"))
            r.activity = "Claude changed the contact \(c.name)"
            return r
        case "delete":
            let (old, moved) = try card(try id(), backend, memory)
            let key = memory.cardRecord(for: old)
            try backend.delete(id: old.id)
            var text = with(moved, "Deleted \(old.name) from Contacts.")
            var activity = "Claude deleted the contact \(old.name)"
            var copies: [String] = []
            if let key { copies = try await memory.deletedCard(key, in: backend) }
            if !copies.isEmpty {
                // FR-726: iCloud's copy of a card Latchkey made goes with it.
                text += "\nAlso deleted iCloud's copy of the card, which had appeared with a new id."
                activity += " and iCloud's copy of it"
            }
            var r = ToolResult.text(text)
            r.activity = activity
            return r
        case "create_group", "rename_group", "delete_group", "add_to_group", "remove_from_group":
            return try await changeGroup(action ?? "", args, backend, memory)
        default:
            return .unknown("action", action, allowed: changeActions)
        }
    }

    /// Group changes (spec 007 FR-723): the cards themselves are never deleted here.
    static func changeGroup(
        _ action: String, _ args: JSONValue, _ backend: any ContactsBackend, _ memory: ContactsMemory
    ) async throws -> ToolResult {
        func newName() throws -> (name: String, before: [ContactGroup]) {
            let name = args["name"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !name.isEmpty else { throw ArgumentError(message: "Give the group's name.") }
            let all = try backend.groups()
            if let same = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw ArgumentError(message: "There's already a group named “\(same.name)” (id \(same.id)).")
            }
            return (name, all)
        }
        func group() throws -> (group: ContactGroup, moved: String?) {
            guard let g = args["group"]?.stringValue, !g.isEmpty else {
                throw ArgumentError(message: "Give the group (name or id), from contacts_find.")
            }
            return try Self.group(g, backend, memory)
        }
        func done(_ text: String, _ moved: String?, _ activity: String) -> ToolResult {
            var r = ToolResult.text(moved.map { text + "\n" + $0 } ?? text)
            r.activity = activity
            return r
        }
        switch action {
        case "create_group":
            let (name, before) = try newName()
            let g = try backend.createGroup(name: name)
            memory.rememberCreated(g, before: before)
            var r = done(
                "Created the group “\(g.name)”. id \(g.id)", nil, "Claude created the contact group “\(g.name)”")
            r.made = "the contact group “\(g.name)”"
            return r
        case "rename_group":
            let (old, moved) = try group()
            let key = memory.groupRecord(for: old)
            let (name, before) = try newName()
            let g = try backend.renameGroup(id: old.id, name: name)
            if let key { memory.renamed(key, to: g, before: before) }
            return done(
                "Renamed the group “\(old.name)” to “\(g.name)”.", moved,
                "Claude renamed the contact group “\(old.name)” to “\(g.name)”")
        case "delete_group":
            let (g, moved) = try group()
            let key = memory.groupRecord(for: g)
            try backend.deleteGroup(id: g.id)
            let cards =
                g.count == 0
                ? "It had no cards."
                : g.count == 1 ? "Its 1 card stays in Contacts." : "Its \(g.count) cards stay in Contacts."
            var text = "Deleted the group “\(g.name)”. \(cards)"
            var activity = "Claude deleted the contact group “\(g.name)”"
            if let key {
                // FR-726: iCloud's copy of a group Latchkey made goes with it.
                let sweep = try await memory.deletedGroup(key, in: backend)
                if sweep.deleted > 0 {
                    text += " Also deleted iCloud's copy of the group, which had appeared with a new id."
                    activity += " and iCloud's copy of it"
                }
                for kept in sweep.kept {
                    text +=
                        " Another group named “\(kept.name)” (id \(kept.id)) is still there: it holds cards"
                        + " Latchkey didn't put in the group, so it was left alone."
                }
            }
            return done(text, moved, activity)
        default:
            let (g, moved) = try group()
            var ids: [String] = []
            if case .array(let items)? = args["ids"] {
                ids = try items.map {
                    guard let s = $0.stringValue, !s.isEmpty else {
                        throw ArgumentError(message: "ids must be card ids.")
                    }
                    return s
                }
            }
            if let id = args["id"]?.stringValue, !id.isEmpty { ids.insert(id, at: 0) }
            guard !ids.isEmpty else { throw ArgumentError(message: "Give the card's id (or ids), from contacts_find.") }
            let found = try ids.map { try card($0, backend, memory) }
            let cards = found.map(\.card)
            let notes = ([moved] + found.map(\.moved)).compactMap { $0 }
            let adding = action == "add_to_group"
            for c in cards {
                if adding {
                    try backend.addMember(contactID: c.id, groupID: g.id)
                } else {
                    try backend.removeMember(contactID: c.id, groupID: g.id)
                }
            }
            if adding, let key = memory.groupRecord(for: g) { memory.added(cards, to: key) }
            let names =
                cards.dropLast().map(\.name).joined(separator: ", ") + (cards.count > 1 ? " and " : "")
                + cards.last!.name
            let note = notes.isEmpty ? nil : notes.joined(separator: "\n")
            return adding
                ? done(
                    "Added \(names) to “\(g.name)”.", note, "Claude added \(names) to the contact group “\(g.name)”")
                : done(
                    "Removed \(names) from “\(g.name)”.", note,
                    "Claude removed \(names) from the contact group “\(g.name)”")
        }
    }

    static func draft(_ args: JSONValue) throws -> ContactDraft {
        var d = ContactDraft()
        let texts: [(String, WritableKeyPath<ContactDraft, String?>)] = [
            ("given_name", \.givenName), ("middle_name", \.middleName), ("family_name", \.familyName),
            ("nickname", \.nickname), ("organization", \.organization), ("job_title", \.jobTitle),
            ("department", \.department),
        ]
        for (key, path) in texts { if let s = args[key]?.stringValue { d[keyPath: path] = s } }
        for (key, path) in [("phones", \ContactDraft.phones), ("emails", \.emails), ("urls", \.urls)] {
            if let v = args[key] { d[keyPath: path] = try labeled(v, key) }
        }
        if let v = args["addresses"] {
            guard case .array(let items) = v else { throw ArgumentError(message: "addresses must be a list.") }
            d.addresses = try items.map { item in
                guard case .object = item else { throw ArgumentError(message: "Each address must be an object.") }
                let s: (String) -> String = { item[$0]?.stringValue ?? "" }
                return PostalAddress(
                    label: s("label"), street: s("street"), city: s("city"), state: s("state"),
                    postalCode: s("postal_code"), country: s("country"))
            }
        }
        if let b = args["birthday"]?.stringValue {
            guard b.isEmpty || birthday(b) != nil else {
                throw ArgumentError(message: "birthday must be YYYY-MM-DD, or --MM-DD without a year.")
            }
            d.birthday = b
        }
        return d
    }

    private static func labeled(_ v: JSONValue, _ key: String) throws -> [Labeled] {
        guard case .array(let items) = v else { throw ArgumentError(message: "\(key) must be a list.") }
        return try items.map { item in
            if let s = item.stringValue { return Labeled(label: "", value: s) }
            guard let value = item["value"]?.stringValue, !value.isEmpty else {
                throw ArgumentError(message: "Each item in \(key) needs a value.")
            }
            return Labeled(label: item["label"]?.stringValue ?? "", value: value)
        }
    }

    /// `YYYY-MM-DD` or `--MM-DD` as date components, nil when it isn't a real day.
    static func birthday(_ s: String) -> DateComponents? {
        guard let m = s.wholeMatch(of: /^(?:(\d{4})|-)-(\d{2})-(\d{2})$/), let month = Int(m.2), let day = Int(m.3),
            (1...12).contains(month)
        else { return nil }
        let year = m.1.flatMap { Int($0) }
        let cal = Calendar(identifier: .gregorian)
        let check = DateComponents(year: year ?? 2000, month: month, day: day)  // 2000: Feb 29 exists
        guard let date = cal.date(from: check), cal.component(.day, from: date) == day else { return nil }
        return DateComponents(calendar: cal, year: year, month: month, day: day)
    }

    static func run(_ body: () async throws -> ToolResult) async -> ToolResult {
        do { return try await body() } catch let e as ArgumentError {
            return .text(e.message, isError: true)
        } catch let f as ContactsFailure {
            switch f {
            case .noAccess: return .text(noAccess, isError: true)
            case .notFound(let id):
                return .text("No card has the id \(id). Search again with contacts_find.", isError: true)
            case .noSuchGroup(let g, let available):
                // A new group's id can change within seconds (iCloud, live check 2026-10-29).
                let start =
                    g.hasSuffix(":ABGroup")
                    ? "No group has the id \(g); a group's id can change right after it's made, so give its name instead."
                    : "There's no group named “\(g)”."
                return .text(
                    start
                        + (available.isEmpty ? "" : " Groups: \(available.joined(separator: ", "))."), isError: true)
            case .failed(let why): return .text("Contacts didn't accept the change: \(why)", isError: true)
            }
        } catch {
            return .text("Latchkey couldn't do that: \(error.localizedDescription)", isError: true)
        }
    }
}
