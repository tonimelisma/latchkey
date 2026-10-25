import Foundation

// The Claude apps that have access to this Mac (FR-190 to FR-192): what the menu shows and what
// happens when the Owner removes one. No AppKit here, so all of it is unit-tested
// (ClientAccessTests).

/// Why a removal didn't happen.
enum RemovalFailure: Equatable, Sendable {
    case noAnswer  // no new list within `ClientAccess.removalTimeout`
    case disconnected  // the connection dropped, or the request couldn't be sent

    func message(for entry: ClientEntry) -> String {
        switch self {
        case .noAnswer: "Couldn’t remove “\(entry.displayName)”. The relay didn’t answer. Try again."
        case .disconnected:
            "Couldn’t remove “\(entry.displayName)”. This Mac lost its connection to the relay. Try again when it’s connected."
        }
    }
}

/// How a removal the Owner asked for ended.
enum RemovalOutcome: Equatable, Sendable {
    case removed(ClientEntry)
    case failed(ClientEntry, RemovalFailure)

    /// The entry for the Mac's activity log (FR-191).
    func activity(at: Date) -> Activity {
        switch self {
        case .removed(let entry):
            Activity(
                at: at, tool: "remove_access", arguments: entry.title,
                result: "Removed from this Mac’s menu. It no longer has access.", isError: false, durationMS: 0)
        case .failed(let entry, let why):
            Activity(
                at: at, tool: "remove_access", arguments: entry.title, result: why.message(for: entry),
                isError: true, durationMS: 0)
        }
    }
}

/// The list as the app knows it, and the removals waiting for the relay's answer.
struct ClientAccess: Equatable, Sendable {
    /// How long a removal waits for the relay's new list before it counts as failed.
    static let removalTimeout: TimeInterval = 5
    /// The menu shows this many, newest first; the window shows all.
    static let menuLimit = 5

    private struct Pending: Equatable, Sendable {
        var entry: ClientEntry
        var deadline: Date
    }

    private struct Failed: Equatable, Sendable {
        var id: String
        var message: String
    }

    /// Nil until the relay sends a list on this connection: an older relay never does, and after
    /// a disconnect the last list can't be trusted (it may have changed elsewhere), so nothing is
    /// shown rather than a claim the app can't back up.
    private(set) var entries: [ClientEntry]?
    private var pending: [String: Pending] = [:]
    private var failed: Failed?

    var isKnown: Bool { entries != nil }
    var menuEntries: [ClientEntry] { Array((entries ?? []).prefix(Self.menuLimit)) }
    var hasMore: Bool { (entries?.count ?? 0) > Self.menuLimit }
    func isRemoving(_ id: String) -> Bool { pending[id] != nil }

    /// The last removal that didn't happen, in words, until it is tried again or the entry goes.
    var failure: String? { failed?.message }

    /// The relay's full list (FR-192). Removals whose entry is gone are done. One whose entry is
    /// still listed keeps waiting until its deadline: a list sent for another reason (a new
    /// approval) can cross the request on the wire.
    mutating func received(_ list: [ClientEntry], now: Date) -> [RemovalOutcome] {
        entries = list
        let listed = Set(list.map(\.id))
        let done = pending.values.filter { !listed.contains($0.entry.id) }.map(\.entry).sorted { $0.id < $1.id }
        for entry in done { pending[entry.id] = nil }
        if let failed, !listed.contains(failed.id) { self.failed = nil }
        return done.map { .removed($0) }
    }

    /// The Owner confirmed removing an entry. Returns the one message to send, or nil when there
    /// is nothing to send: no such entry, or its removal is already in flight (FR-191).
    mutating func beginRemoval(_ id: String, now: Date) -> RevokeClient? {
        guard pending[id] == nil, let entry = entries?.first(where: { $0.id == id }) else { return nil }
        pending[id] = Pending(entry: entry, deadline: now.addingTimeInterval(Self.removalTimeout))
        failed = nil
        return RevokeClient(id: id)
    }

    /// Removals whose deadline has passed failed: their entries show as before.
    mutating func expire(now: Date) -> [RemovalOutcome] {
        fail(pending.values.filter { $0.deadline <= now }.map(\.entry), .noAnswer)
    }

    /// The request couldn't be sent at all.
    mutating func notSent(_ id: String) -> [RemovalOutcome] {
        fail(pending[id].map { [$0.entry] } ?? [], .disconnected)
    }

    /// The connection is gone: removals in flight failed, and the list is no longer shown.
    mutating func disconnected() -> [RemovalOutcome] {
        let outcomes = fail(pending.values.map(\.entry), .disconnected)
        entries = nil
        return outcomes
    }

    private mutating func fail(_ entries: [ClientEntry], _ why: RemovalFailure) -> [RemovalOutcome] {
        let sorted = entries.sorted { $0.id < $1.id }
        for entry in sorted {
            pending[entry.id] = nil
            failed = Failed(id: entry.id, message: why.message(for: entry))
        }
        return sorted.map { .failed($0, why) }
    }
}

// MARK: wording

extension ClientEntry {
    static let nameLimit = 40
    static let hostLimit = 60

    /// Text from the network made safe to show: one line, no control or invisible formatting
    /// characters (which could reorder or hide text), cut to `limit` characters. Always shown
    /// verbatim: never as Markdown, a link, or an attributed string.
    static func plain(_ text: String, limit: Int) -> String {
        var line = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator, .surrogate, .privateUse,
                .unassigned:
                line.append(" ")
            default: line.append(scalar)
            }
        }
        let words = String(line).split(separator: " ", omittingEmptySubsequences: true)
        let joined = words.joined(separator: " ")
        return joined.count > limit ? String(joined.prefix(limit - 1)) + "…" : joined
    }

    /// A program that signed in on a computer, such as Claude Code, not one of Claude's hosted apps.
    var isLocalProgram: Bool { redirect == Self.thisComputer }

    var displayName: String {
        let name = Self.plain(name, limit: Self.nameLimit)
        return name.isEmpty ? "Unnamed App" : name
    }

    var displayHost: String { Self.plain(host, limit: Self.hostLimit) }

    /// Where it is from, inside a sentence.
    var origin: String {
        if isLocalProgram { return "a program on a computer" }
        return displayHost.isEmpty ? "an unknown address" : displayHost
    }

    /// The menu item and the window row: "Claude — claude.ai", "Claude Code — on a computer".
    var title: String {
        if isLocalProgram { return "\(displayName) — on a computer" }
        return displayHost.isEmpty ? displayName : "\(displayName) — \(displayHost)"
    }

    var originLine: String {
        isLocalProgram ? "A program on a computer, such as Claude Code" : "From \(origin)"
    }

    /// Claude's own hosted apps share one identity, so one entry stands for all of them.
    private var isClaudeHosted: Bool { !isLocalProgram && ["claude.ai", "claude.com"].contains(host) }

    static let hostedApps = "Claude on the web, desktop, and phone"

    /// Whether this one entry stands for all of Claude's hosted apps.
    var coversHostedApps: Bool { isClaudeHosted }

    /// What one entry stands for, where the app knows: it never promises one entry per device.
    var scopeLine: String? {
        if isLocalProgram { return "One sign-in; each sign-in is listed separately" }
        return isClaudeHosted ? "Covers \(Self.hostedApps)" : nil
    }

    func approvedLine(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone)
        return "Approved \(approvedAt.formatted(style))"
    }

    func lastUsedLine(now: Date, locale: Locale = .current) -> String {
        guard let lastUsedAt else { return "Not used yet" }
        // Within the last minute, or a little ahead of this Mac's clock.
        if lastUsedAt > now.addingTimeInterval(-60) { return "Last used just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return "Last used \(formatter.localizedString(for: lastUsedAt, relativeTo: now))"
    }
}

/// The dialog before a removal: it can't be undone from the Mac, so it says what happens (FR-191).
struct RemovalConfirmation: Equatable, Sendable {
    let title: String
    let message: String
    static let confirm = "Remove"
    static let cancel = "Cancel"

    init(_ entry: ClientEntry) {
        title = "Remove access for “\(entry.displayName)”?"
        var text =
            "Claude will stop working on this Mac from “\(entry.displayName)” (\(entry.origin)) until you approve it again on Latchkey’s Allow page."
        if entry.coversHostedApps { text += " This covers \(ClientEntry.hostedApps)." }
        message = text
    }
}
