import Foundation

/// What Latchkey itself created in Contacts during this run of the app, so an id that iCloud
/// replaced within seconds still finds the card or group, and iCloud's copy of something Claude
/// deletes goes with it (spec 007 FR-724 to FR-727, research.md "Ids that change"). Kept in
/// memory only and forgotten when the app quits (Constitution VI).
///
/// Why this can't touch the Owner's own cards or groups:
/// - A card or group is only ever matched to a record of something Latchkey created in this run.
/// - `preexisting` holds every card or group that already looked the same (same fingerprint, or
///   for a group the same name) just before Latchkey created or changed it; those are never
///   matched, even when they are identical.
/// - A card matches only on its whole fingerprint (names, company, job, every phone, email,
///   address, web address, date, related name, birthday, and whether it has a picture), so a
///   card someone edited after it was made doesn't match.
/// - Nothing is matched when two live records share a fingerprint or name, or when more than
///   one card or group could be meant.
/// - A copy is deleted only within `copyWindow` of the create, and a group copy only when every
///   card in it is one Latchkey put in that group.
final class ContactsMemory: @unchecked Sendable {
    static let shared = ContactsMemory()

    /// How long after a create iCloud's copy is still deleted as ours.
    static let copyWindow: TimeInterval = 10 * 60
    /// A delete this soon after the create looks for a copy twice, `settle` apart.
    static let settleAge: TimeInterval = 2 * 60
    static let maxRecords = 200

    struct CardRecord: Sendable {
        let key = UUID()
        /// Every id the card has had, first the one the create answered.
        var ids: [String]
        /// The fingerprints of every version Latchkey wrote.
        var fingerprints: Set<String>
        /// Cards that looked like one of those versions before Latchkey wrote it.
        var preexisting: Set<String>
        let created: Date
        var deleted = false
    }

    struct GroupRecord: Sendable {
        let key = UUID()
        var ids: [String]
        /// The group's name now.
        var name: String
        /// Every name it had, lowercased.
        var names: Set<String>
        /// Groups that had one of those names before Latchkey gave it.
        var preexisting: Set<String>
        /// Fingerprints of the cards Latchkey put in the group.
        var members: Set<String> = []
        let created: Date
        var deleted = false
    }

    private struct State {
        var cards: [CardRecord] = []
        var groups: [GroupRecord] = []
    }

    private let lock = NSLock()
    private var state = State()
    let now: @Sendable () -> Date
    let settle: Duration

    init(now: @escaping @Sendable () -> Date = { Date() }, settle: Duration = .seconds(2)) {
        self.now = now
        self.settle = settle
    }

    private func with<T>(_ f: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f(&state)
    }

    /// The card's content as one text: names, company, and every value, without labels,
    /// formatting, or groups (iCloud may reformat a phone number or a label).
    static func fingerprint(_ c: ContactCard) -> String {
        let low: (String) -> String = {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let list: ([String]) -> String = { $0.map(low).sorted().joined(separator: ",") }
        return [
            low(c.givenName), low(c.middleName), low(c.familyName), low(c.nickname), low(c.organization),
            low(c.jobTitle), low(c.department),
            list(c.phones.map { ContactBook.digits($0.value) }), list(c.emails.map(\.value)),
            list(c.addresses.map(\.oneLine)), c.birthday ?? "", list(c.dates.map(\.value)),
            list(c.urls.map(\.value)), list(c.related.map(\.value)), c.hasPhoto ? "photo" : "",
        ].joined(separator: "|")
    }

    var isEmpty: Bool { with { $0.cards.isEmpty && $0.groups.isEmpty } }

    // MARK: cards

    func rememberCreated(_ card: ContactCard, before: [ContactCard]) {
        let fp = Self.fingerprint(card)
        let pre = Set(before.filter { Self.fingerprint($0) == fp }.map(\.id))
        let record = CardRecord(ids: [card.id], fingerprints: [fp], preexisting: pre, created: now())
        with {
            $0.cards.append(record)
            if $0.cards.count > Self.maxRecords { $0.cards.removeFirst($0.cards.count - Self.maxRecords) }
        }
    }

    /// The live record of a card Latchkey made: by its id, or else by its fingerprint when the
    /// card isn't one that existed before and no other record could own it. The id is learned.
    func cardRecord(for c: ContactCard) -> UUID? {
        with { s in
            if let r = s.cards.first(where: { !$0.deleted && $0.ids.contains(c.id) }) { return r.key }
            let fp = Self.fingerprint(c)
            let owners = s.cards.filter { !$0.deleted && $0.fingerprints.contains(fp) }
            guard owners.count == 1, let i = s.cards.firstIndex(where: { $0.key == owners[0].key }),
                !s.cards[i].preexisting.contains(c.id), !Self.claimed(c.id, in: s, except: owners[0].key)
            else { return nil }
            s.cards[i].ids.append(c.id)
            return owners[0].key
        }
    }

    /// A card Latchkey made whose id `id` was, found again by its content (FR-724).
    func refindCard(_ id: String, in backend: any ContactsBackend) throws -> ContactCard? {
        guard let rec = with({ s in s.cards.first { !$0.deleted && $0.ids.contains(id) } }) else { return nil }
        let candidates = candidates(rec, in: try backend.all())
        guard candidates.count == 1 else { return nil }
        with { s in
            if let i = s.cards.firstIndex(where: { $0.key == rec.key }) { s.cards[i].ids.append(candidates[0].id) }
        }
        return candidates[0]
    }

    /// Cards that may be `rec`'s card under another id: same content as a version Latchkey wrote,
    /// not one that existed before, not another record's; none when another live record could
    /// mean the same content.
    private func candidates(_ rec: CardRecord, in all: [ContactCard]) -> [ContactCard] {
        with { s in
            let shared = s.cards.contains {
                $0.key != rec.key && !$0.deleted && !$0.fingerprints.isDisjoint(with: rec.fingerprints)
            }
            guard !shared else { return [] }
            return all.filter {
                rec.fingerprints.contains(Self.fingerprint($0)) && !rec.preexisting.contains($0.id)
                    && !Self.claimed($0.id, in: s, except: rec.key)
            }
        }
    }

    private static func claimed(_ id: String, in s: State, except key: UUID) -> Bool {
        s.cards.contains { $0.key != key && $0.ids.contains(id) }
            || s.groups.contains { $0.key != key && $0.ids.contains(id) }
    }

    /// After Latchkey changed its own card: the new content is one of its versions, and cards
    /// that already looked like it (`before`) are never taken for it.
    func changed(_ key: UUID, to card: ContactCard, before: [ContactCard]) {
        let fp = Self.fingerprint(card)
        let pre = before.filter { $0.id != card.id && Self.fingerprint($0) == fp }.map(\.id)
        with { s in
            guard let i = s.cards.firstIndex(where: { $0.key == key }) else { return }
            s.cards[i].fingerprints.insert(fp)
            s.cards[i].preexisting.formUnion(pre)
            if !s.cards[i].ids.contains(card.id) { s.cards[i].ids.append(card.id) }
        }
    }

    func isCardRecord(_ id: String) -> Bool { with { s in s.cards.contains { !$0.deleted && $0.ids.contains(id) } } }

    /// Marks the card deleted, then deletes iCloud's copies of it (FR-726). Answers the names deleted.
    func deletedCard(_ key: UUID, in backend: any ContactsBackend) async throws -> [String] {
        with { s in
            if let i = s.cards.firstIndex(where: { $0.key == key }) { s.cards[i].deleted = true }
        }
        var removed = try removeCardCopies(key, in: backend)
        if removed.isEmpty, let rec = cardRecord(key: key), now().timeIntervalSince(rec.created) < Self.settleAge,
            settle > .zero
        {
            try? await Task.sleep(for: settle)
            removed = try removeCardCopies(key, in: backend)
        }
        return removed
    }

    private func cardRecord(key: UUID) -> CardRecord? { with { s in s.cards.first { $0.key == key } } }

    private func removeCardCopies(_ key: UUID, in backend: any ContactsBackend) throws -> [String] {
        guard let rec = cardRecord(key: key), now().timeIntervalSince(rec.created) <= Self.copyWindow else {
            return []
        }
        var names: [String] = []
        for copy in candidates(rec, in: try backend.all()) {
            try backend.delete(id: copy.id)
            with { s in
                if let i = s.cards.firstIndex(where: { $0.key == key }) { s.cards[i].ids.append(copy.id) }
            }
            names.append(copy.name)
        }
        return names
    }

    // MARK: groups

    func rememberCreated(_ group: ContactGroup, before: [ContactGroup]) {
        let name = group.name.lowercased()
        let pre = Set(before.filter { $0.name.lowercased() == name }.map(\.id))
        let record = GroupRecord(
            ids: [group.id], name: group.name, names: [name], preexisting: pre, created: now())
        with {
            $0.groups.append(record)
            if $0.groups.count > Self.maxRecords { $0.groups.removeFirst($0.groups.count - Self.maxRecords) }
        }
    }

    /// The live record of a group Latchkey made: by id, or by one of its names when the group
    /// didn't have that name before. The id is learned.
    func groupRecord(for g: ContactGroup) -> UUID? {
        with { s in
            if let r = s.groups.first(where: { !$0.deleted && $0.ids.contains(g.id) }) { return r.key }
            let owners = s.groups.filter { !$0.deleted && $0.names.contains(g.name.lowercased()) }
            guard owners.count == 1, let i = s.groups.firstIndex(where: { $0.key == owners[0].key }),
                !s.groups[i].preexisting.contains(g.id), !Self.claimed(g.id, in: s, except: owners[0].key)
            else { return nil }
            s.groups[i].ids.append(g.id)
            return owners[0].key
        }
    }

    /// A group Latchkey made whose id `id` was, found again by its name (FR-725).
    func refindGroup(_ id: String, in backend: any ContactsBackend) throws -> ContactGroup? {
        guard let rec = with({ s in s.groups.first { !$0.deleted && $0.ids.contains(id) } }) else { return nil }
        let found = groupCandidates(rec, in: try backend.groups()).filter {
            $0.name.lowercased() == rec.name.lowercased()
        }
        guard found.count == 1 else { return nil }
        with { s in
            if let i = s.groups.firstIndex(where: { $0.key == rec.key }) { s.groups[i].ids.append(found[0].id) }
        }
        return found[0]
    }

    private func groupCandidates(_ rec: GroupRecord, in all: [ContactGroup]) -> [ContactGroup] {
        with { s in
            let shared = s.groups.contains { $0.key != rec.key && !$0.deleted && !$0.names.isDisjoint(with: rec.names) }
            guard !shared else { return [] }
            return all.filter {
                rec.names.contains($0.name.lowercased()) && !rec.preexisting.contains($0.id)
                    && !Self.claimed($0.id, in: s, except: rec.key)
            }
        }
    }

    func renamed(_ key: UUID, to g: ContactGroup, before: [ContactGroup]) {
        let name = g.name.lowercased()
        let pre = before.filter { $0.id != g.id && $0.name.lowercased() == name }.map(\.id)
        with { s in
            guard let i = s.groups.firstIndex(where: { $0.key == key }) else { return }
            s.groups[i].name = g.name
            s.groups[i].names.insert(name)
            s.groups[i].preexisting.formUnion(pre)
        }
    }

    func added(_ cards: [ContactCard], to key: UUID) {
        with { s in
            guard let i = s.groups.firstIndex(where: { $0.key == key }) else { return }
            s.groups[i].members.formUnion(cards.map(Self.fingerprint))
        }
    }

    struct GroupSweep: Equatable {
        var deleted = 0
        /// Same-named groups left alone because they hold cards Latchkey didn't put there.
        var kept: [ContactGroup] = []
    }

    /// Marks the group deleted, then deletes iCloud's copies of it (FR-726).
    func deletedGroup(_ key: UUID, in backend: any ContactsBackend) async throws -> GroupSweep {
        with { s in
            if let i = s.groups.firstIndex(where: { $0.key == key }) { s.groups[i].deleted = true }
        }
        var sweep = try removeGroupCopies(key, in: backend)
        if sweep.deleted == 0, sweep.kept.isEmpty, let rec = groupRecord(key: key),
            now().timeIntervalSince(rec.created) < Self.settleAge, settle > .zero
        {
            try? await Task.sleep(for: settle)
            sweep = try removeGroupCopies(key, in: backend)
        }
        return sweep
    }

    private func groupRecord(key: UUID) -> GroupRecord? { with { s in s.groups.first { $0.key == key } } }

    private func removeGroupCopies(_ key: UUID, in backend: any ContactsBackend) throws -> GroupSweep {
        guard let rec = groupRecord(key: key), now().timeIntervalSince(rec.created) <= Self.copyWindow else {
            return GroupSweep()
        }
        var sweep = GroupSweep()
        for copy in groupCandidates(rec, in: try backend.groups()) {
            let members = try backend.memberIDs(groupID: copy.id)
            let ours = members.allSatisfy { id in
                (try? backend.card(id: id)).map { rec.members.contains(Self.fingerprint($0)) } ?? false
            }
            guard ours else {
                sweep.kept.append(copy)
                continue
            }
            try backend.deleteGroup(id: copy.id)
            with { s in
                if let i = s.groups.firstIndex(where: { $0.key == key }) { s.groups[i].ids.append(copy.id) }
            }
            sweep.deleted += 1
        }
        return sweep
    }

    // MARK: later copies

    /// Copies of cards and groups Latchkey deleted that iCloud brought back after the delete
    /// answered, deleted at the start of the next change (FR-727). Answers lines for the answer.
    func sweepLeftovers(in backend: any ContactsBackend) throws -> [String] {
        let (cards, groups) = with { s in
            let young: (Date) -> Bool = { self.now().timeIntervalSince($0) <= Self.copyWindow }
            return (
                s.cards.filter { $0.deleted && young($0.created) }.map(\.key),
                s.groups.filter { $0.deleted && young($0.created) }.map { ($0.key, $0.name) }
            )
        }
        // One failing copy doesn't hide the deletions already done (security review, 2026-10-29).
        var lines: [String] = []
        for key in cards {
            do {
                for name in try removeCardCopies(key, in: backend) {
                    lines.append("Also deleted iCloud's leftover copy of the contact \(name), deleted earlier.")
                }
            } catch {
                lines.append("Couldn't delete iCloud's leftover copy of a contact deleted earlier: \(error)")
            }
        }
        for (key, name) in groups {
            do {
                if try removeGroupCopies(key, in: backend).deleted > 0 {
                    lines.append("Also deleted iCloud's leftover copy of the group “\(name)”, deleted earlier.")
                }
            } catch {
                lines.append("Couldn't delete iCloud's leftover copy of the group “\(name)”: \(error)")
            }
        }
        return lines
    }
}
