import Foundation

/// The Owner's Contacts (spec 007 US3), through the Contacts framework (plan D3).
enum ContactsCapability {
    static func make() -> Capability {
        Capability(
            id: CapabilityRegistry.contacts, title: "Contacts",
            summary: "Look up, add, change, and delete contacts",
            readTools: readTools(backend: CNContactsBackend.shared),
            writeTools: writeTools(backend: CNContactsBackend.shared))
    }

    static let noAccess = """
        Latchkey can't see the contacts: macOS hasn't allowed it. The Mac's owner can allow \
        Contacts in Latchkey's Settings → Permissions.
        """

    static let maxCards = 100

    static func readTools(backend: any ContactsBackend) -> [ToolEntry] {
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
                handler: { args in await run { try find(args, backend) } })
        ]
    }

    static let changeActions = ["create", "update", "delete"]

    static func writeTools(backend: any ContactsBackend) -> [ToolEntry] {
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
                        --MM-DD without a year.
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
                    ], required: ["action"], readOnly: false, destructive: true, deadlineMS: 15_000),
                handler: { args in await run { try change(args, backend) } })
        ]
    }

    // MARK: find

    static func find(_ args: JSONValue, _ backend: any ContactsBackend) throws -> ToolResult {
        guard backend.allowed() else { throw ContactsFailure.noAccess }
        if let id = args["id"]?.stringValue, !id.isEmpty {
            if args["photo"]?.boolValue == true {
                guard let data = try backend.photo(id: id), let image = try? ImagePrep.prepare(data: data) else {
                    return .text("This card has no picture.")
                }
                return .image(image.data, mimeType: image.mimeType)
            }
            return .text(describe(try backend.card(id: id)))
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
            let groups = try backend.groups()
            guard let group = groups.first(where: { $0.id == g || $0.name.caseInsensitiveCompare(g) == .orderedSame })
            else { throw ContactsFailure.noSuchGroup(g, available: groups.map(\.name)) }
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

    // MARK: change

    static func change(_ args: JSONValue, _ backend: any ContactsBackend) throws -> ToolResult {
        guard backend.allowed() else { throw ContactsFailure.noAccess }
        let action = args["action"]?.stringValue
        func id() throws -> String {
            guard let id = args["id"]?.stringValue, !id.isEmpty else {
                throw ArgumentError(message: "Give the card's id, from contacts_find.")
            }
            return id
        }
        switch action {
        case "create":
            let d = try draft(args)
            guard [d.givenName, d.familyName, d.organization, d.nickname].contains(where: { !($0 ?? "").isEmpty })
            else {
                throw ArgumentError(message: "Give at least a name or a company.")
            }
            let c = try backend.create(d)
            var r = ToolResult.text("Added \(c.name) to Contacts. id \(c.id)")
            r.activity = "Claude added \(c.name) to Contacts"
            r.made = "the contact \(c.name)"
            return r
        case "update":
            let d = try draft(args)
            guard !d.isEmpty else { throw ArgumentError(message: "Give at least one field to change.") }
            let c = try backend.update(id: try id(), d)
            var r = ToolResult.text("Changed \(c.name):\n\(describe(c))")
            r.activity = "Claude changed the contact \(c.name)"
            return r
        case "delete":
            let old = try backend.card(id: try id())
            try backend.delete(id: old.id)
            var r = ToolResult.text("Deleted \(old.name) from Contacts.")
            r.activity = "Claude deleted the contact \(old.name)"
            return r
        default:
            return .unknown("action", action, allowed: changeActions)
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

    static func run(_ body: () throws -> ToolResult) async -> ToolResult {
        do { return try body() } catch let e as ArgumentError {
            return .text(e.message, isError: true)
        } catch let f as ContactsFailure {
            switch f {
            case .noAccess: return .text(noAccess, isError: true)
            case .notFound(let id):
                return .text("No card has the id \(id). Search again with contacts_find.", isError: true)
            case .noSuchGroup(let g, let available):
                return .text(
                    "There's no group named “\(g)”."
                        + (available.isEmpty ? "" : " Groups: \(available.joined(separator: ", "))."), isError: true)
            case .failed(let why): return .text("Contacts didn't accept the change: \(why)", isError: true)
            }
        } catch {
            return .text("Latchkey couldn't do that: \(error.localizedDescription)", isError: true)
        }
    }
}
