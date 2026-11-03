import Foundation

/// Messages Claude queued while the Mac was locked, to go out when it is next unlocked (spec 008
/// FR-836, FR-837). Kept in one file readable only by the Owner's account, and removed once sent,
/// cancelled, or given up on after `MailQueue.tries` tries that sent nothing (FR-838).
actor MailQueue {
    struct Item: Codable, Sendable, Equatable {
        var id: String
        var created: Date
        /// The same inputs as mail_send.
        var args: JSONValue
        /// "«subject» to …", for lists and notifications.
        var summary: String
        /// Tries that sent nothing so far, and why the last one failed (FR-838).
        var failed: Int?
        var lastError: String?
    }

    /// Tries before a message that keeps failing is dropped (FR-838).
    static let tries = 3

    /// In the app's support folder, which uninstalling removes (FR-077).
    static let shared = MailQueue(file: AppIdentity.current.supportDirectory.appending(path: "mail-queue.json"))

    private let file: URL

    init(file: URL) { self.file = file }

    func items() -> [Item] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    private func save(_ list: [Item]) throws {
        if list.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func add(_ args: JSONValue, summary: String, now: Date = Date()) throws -> Item {
        var list = items()
        var n = list.count + 1
        while list.contains(where: { $0.id == "q\(n)" }) { n += 1 }
        let item = Item(id: "q\(n)", created: now, args: args, summary: summary)
        list.append(item)
        try save(list)
        return item
    }

    func cancel(_ id: String) throws -> Item? {
        var list = items()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return nil }
        let item = list.remove(at: i)
        try save(list)
        return item
    }

    /// Takes an item off the queue, to be sent now; nil when it isn't queued (any more).
    func take(_ id: String) throws -> Item? { try cancel(id) }

    /// Puts back an item whose try sent nothing, in its place by age (FR-838).
    func putBack(_ item: Item) throws {
        var list = items()
        list.insert(item, at: list.firstIndex { $0.created > item.created } ?? list.endIndex)
        try save(list)
    }
}
