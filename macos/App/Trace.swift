import CryptoKit
import Foundation
import OSLog
import Security
import SwiftData

/// What an entry is: something Claude had the Mac do, or the app's own event (FR-633).
enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case action, event
}

/// One entry of the activity log, as the app shows it (FR-026, FR-633): a tool call the Mac ran
/// (an action), or one of the app's own events. Kept only on this Mac.
struct Activity: Identifiable, Sendable, Codable {
    var id = UUID()
    var at: Date
    /// The tool's name; for an event, its category (`EventCategory`).
    var tool: String
    var arguments: String
    /// For an event, its text.
    var result: String
    var isError: Bool
    var durationMS: Int
    /// Its place in the tamper check's chain (FR-612); 0 for an entry recorded before the check.
    /// Kept beside the sealed content, not in it.
    var seq = 0
    /// Kept beside the sealed content, like `seq`, and covered by the chain.
    var kind = ActivityKind.action
    /// The relay's id of the call (FR-632); nil for events and entries from before call ids.
    var callID: String?
    /// The pairing (device ID) the call came through, so the comparison with the relay's audit
    /// of this Mac leaves out the calls of an earlier pairing (FR-634).
    var device: String?
    /// The Claude app that made the call, as the relay named it (FR-637); nil when unknown, for
    /// events, and for entries from before. Sealed with the content; text from the network.
    var client: String?

    var beforeCheck: Bool { seq == 0 }

    /// The sealed content: everything but the fields kept beside it. `client` is optional, so
    /// content sealed before it existed opens as before.
    enum CodingKeys: String, CodingKey { case id, at, tool, arguments, result, isError, durationMS, client }

    /// One of the app's own events (FR-633).
    static func event(_ category: EventCategory, _ text: String, error: Bool = false, at: Date = Date()) -> Activity {
        Activity(
            at: at, tool: category.rawValue, arguments: "", result: text, isError: error, durationMS: 0, kind: .event)
    }
}

/// What is stored: the time and the chain's fields in the clear, everything else AES-GCM
/// encrypted (FR-026a). The fields added on 2026-10-26 all have defaults, so SwiftData upgrades
/// a log from before them in place (FR-612).
@Model
final class SealedActivity {
    #Index<SealedActivity>([\.at, \.seq], [\.seq], [\.keyID])

    var id: UUID
    var at: Date
    var sealed: Data
    /// Its number in the chain, counting up across keys; 0 = recorded before the check (FR-612).
    var seq: Int = 0
    /// HMAC-SHA256 over the previous entry's `mac`, `seq`, `id`, `at`, and `keyID` (FR-612).
    var mac: Data?
    /// Which log key sealed it (8 bytes derived from the key, as hex), so entries that can't be
    /// read are counted without decrypting the log (FR-203). "" = not yet looked at; "-" = sealed
    /// with a key that was already gone when the check came.
    var keyID: String = ""
    /// `ActivityKind`'s raw value (FR-633). Added 2026-10-27 with defaults, so a log from before
    /// upgrades in place: its entries are actions without a call id.
    var kind: String = ActivityKind.action.rawValue
    /// The relay's call id (FR-632), or "".
    var callID: String = ""
    /// The device ID the call came through, or "".
    var device: String = ""

    init(
        id: UUID, at: Date, sealed: Data, seq: Int = 0, mac: Data? = nil, keyID: String = "",
        kind: String = ActivityKind.action.rawValue, callID: String = "", device: String = ""
    ) {
        self.id = id
        self.at = at
        self.sealed = sealed
        self.seq = seq
        self.mac = mac
        self.keyID = keyID
        self.kind = kind
        self.callID = callID
        self.device = device
    }
}

/// The activity log before FR-026a, in plaintext: read once, encrypted into the new log, and
/// its file deleted (research.md "Encrypting the activity log").
@Model
final class TraceEntry {
    var at: Date
    var tool: String
    var arguments: String
    var result: String
    var isError: Bool
    var durationMS: Int

    init(at: Date, tool: String, arguments: String, result: String, isError: Bool, durationMS: Int) {
        self.at = at
        self.tool = tool
        self.arguments = arguments
        self.result = result
        self.isError = isError
        self.durationMS = durationMS
    }
}

/// What a look for one stored item found. "Unreadable" is not "absent": the item is there, and
/// whatever was encrypted or paired with it is lost the moment something writes over it.
enum StoredItem: Equatable, Sendable {
    case absent
    case found(Data)
    /// The item exists but its data can't be had; the text says why, for the log.
    case unreadable(String)
}

/// Where the activity log's key lives. The app uses the Keychain; tests use memory, never the
/// real Keychain (the test app has its own identity, `AppIdentity`, but still keeps no real data).
protocol TraceKeyStore: Sendable {
    /// The key, made (256 random bits) and saved only when there is none at all (FR-201).
    func loadOrCreate() throws -> SymmetricKey
    func delete()
}

/// The one place the key is kept, as the rule below sees it.
protocol TraceKeyItem: Sendable {
    func lookup() -> StoredItem
    /// Saves a new key. Never replaces one that is there.
    func add(_ data: Data) throws
}

/// The key exists but can't be used: the log is unavailable for this launch and the key is
/// left exactly as it is (FR-201).
struct TraceKeyUnreadable: Error, Equatable, LocalizedError {
    var reason: String
    var errorDescription: String? { "the activity log’s key is in the Keychain but can’t be read (\(reason))" }
}

enum TraceKey {
    static let size = 32  // AES-256

    /// The rule of FR-201: a new key only when no key exists at all. On 2026-10-24 a Keychain
    /// read that always failed made every launch write a new key over the real one, and the log
    /// written under it was unreadable for good.
    static func loadOrCreate(in item: any TraceKeyItem) throws -> SymmetricKey {
        switch item.lookup() {
        case .found(let data) where data.count == size:
            return SymmetricKey(data: data)
        case .found(let data):
            throw TraceKeyUnreadable(reason: "it has \(data.count) bytes, not \(size)")
        case .unreadable(let reason):
            throw TraceKeyUnreadable(reason: reason)
        case .absent:
            let key = SymmetricKey(size: .bits256)
            try item.add(key.withUnsafeBytes { Data($0) })
            return key
        }
    }
}

extension Keychain {
    static let traceKeyAccount = "activity-log-key"
    /// The newest entry's number and checksum (FR-613).
    static let latestEntryAccount = "activity-log-latest"
}

private var underTest: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

/// The key as a generic password in the login Keychain, readable after the first unlock, this
/// Mac only. Its access list trusts only the app that created it: another program asking for it
/// makes macOS ask the Owner first.
struct KeychainTraceKey: TraceKeyStore, TraceKeyItem {
    func loadOrCreate() throws -> SymmetricKey {
        guard !underTest else { throw CocoaError(.featureUnsupported) }
        return try TraceKey.loadOrCreate(in: self)
    }

    func lookup() -> StoredItem { Keychain.lookup(account: Keychain.traceKeyAccount) }

    func add(_ data: Data) throws {
        guard !underTest else { throw CocoaError(.featureUnsupported) }
        try Keychain.write(data, account: Keychain.traceKeyAccount, replacing: false)
    }

    func delete() {
        guard !underTest else { return }
        Keychain.delete(account: Keychain.traceKeyAccount)
    }
}

final class MemoryTraceKey: TraceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?

    func loadOrCreate() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let key { return key }
        let k = SymmetricKey(size: .bits256)
        key = k
        return k
    }

    func delete() {
        lock.lock()
        key = nil
        lock.unlock()
    }
}

// MARK: the record of the newest entry (FR-613)

/// The Keychain item that holds the newest entry's number and checksum.
protocol LatestEntryItem: Sendable {
    func lookup() -> StoredItem
    /// Saves a record where there is none. Never replaces one.
    func add(_ data: Data) throws
    /// Replaces the record that is there, in one step (no moment without one).
    func update(_ data: Data) throws
    func delete()
}

struct KeychainLatestEntry: LatestEntryItem {
    func lookup() -> StoredItem {
        guard !underTest else { return .unreadable("not used in tests") }
        return Keychain.lookup(account: Keychain.latestEntryAccount)
    }

    func add(_ data: Data) throws {
        guard !underTest else { throw CocoaError(.featureUnsupported) }
        try Keychain.write(data, account: Keychain.latestEntryAccount, replacing: false)
    }

    func update(_ data: Data) throws {
        guard !underTest else { throw CocoaError(.featureUnsupported) }
        try Keychain.update(data, account: Keychain.latestEntryAccount)
    }

    func delete() {
        guard !underTest else { return }
        Keychain.delete(account: Keychain.latestEntryAccount)
    }
}

/// The record in memory, for tests; every write is kept so a test can show none happened.
final class MemoryLatestEntry: LatestEntryItem, @unchecked Sendable {
    private let lock = NSLock()
    private var state: StoredItem
    private var log: [String] = []

    init(_ state: StoredItem = .absent) { self.state = state }

    var writes: [String] { lock.withLock { log } }
    var stored: StoredItem { lock.withLock { state } }
    func set(_ new: StoredItem) { lock.withLock { state = new } }

    func lookup() -> StoredItem { lock.withLock { state } }
    func add(_ data: Data) throws {
        try lock.withLock {
            guard case .absent = state else { throw CocoaError(.fileWriteFileExists) }
            log.append("add")
            state = .found(data)
        }
    }
    func update(_ data: Data) throws {
        try lock.withLock {
            guard case .found = state else { throw CocoaError(.fileNoSuchFile) }
            log.append("update")
            state = .found(data)
        }
    }
    func delete() { lock.withLock { state = .absent } }
}

/// One entry's place in the chain: its number and checksum.
struct ChainTip: Sendable, Equatable {
    var seq: Int
    var mac: Data
}

/// The record's bytes: version 1, the key's ID (16 hex characters), the number (8 bytes, big
/// endian), the checksum (32 bytes).
enum LatestEntryRecord {
    static let version: UInt8 = 1
    static let size = 1 + 16 + 8 + 32

    static func encode(keyID: String, tip: ChainTip) -> Data {
        var d = Data([version])
        d.append(Data(keyID.utf8))
        d.append(bigEndian: UInt64(tip.seq))
        d.append(tip.mac)
        return d
    }

    /// nil when the bytes aren't a record this version understands.
    static func decode(_ d: Data) -> (keyID: String, tip: ChainTip)? {
        let b = [UInt8](d)
        guard b.count == size, b[0] == version, let keyID = String(bytes: b[1..<17], encoding: .utf8) else {
            return nil
        }
        let seq = b[17..<25].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard seq > 0, seq <= UInt64(Int.max) else { return nil }
        return (keyID, ChainTip(seq: Int(seq), mac: Data(b[25...])))
    }
}

/// What the start found about the record (FR-613), for the Activity window.
enum LatestEntryState: Equatable, Sendable {
    /// Read and understood, or none needed yet.
    case ok
    /// None in the Keychain although checked entries exist; a new one starts with the next entry.
    case missing
    /// There but not readable or not understood: left alone, not written this launch.
    case unreadable(String)
}

extension Data {
    fileprivate mutating func append(bigEndian value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

// MARK: browsing (FR-614)

/// What the Activity window asks for: all text fields are searched together.
struct ActivityQuery: Sendable, Equatable {
    /// Found in the tool, arguments, or result, ignoring case; empty matches all.
    var text = ""
    /// One tool's name, or nil for every tool.
    var tool: String?
    /// From this moment (inclusive) to `to` (exclusive); nil is open.
    var from: Date?
    var to: Date?
    /// Claude's actions or the app's events only; nil for both (FR-633).
    var kind: ActivityKind?

    func matches(_ a: Activity) -> Bool { matches(a, ActivityMatcher(text)) }

    func matches(_ a: Activity, _ matcher: ActivityMatcher) -> Bool {
        if let kind, a.kind != kind { return false }
        if let tool, a.tool != tool { return false }
        return matcher.isEmpty || matcher.found(in: a.tool) || matcher.found(in: a.arguments)
            || matcher.found(in: a.result) || a.client.map(matcher.found(in:)) == true
    }
}

/// Finds text ignoring case and accents. Plain ASCII text, most of the log, is searched with the C
/// library's case-blind search; anything else falls back to Foundation's comparison, which is
/// several times slower.
struct ActivityMatcher: Sendable {
    let needle: String
    /// Whether the needle is all ASCII (it is already lowercase and without accents).
    private let ascii: Bool

    init(_ text: String) {
        needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        ascii = needle.canBeConverted(to: .ascii) && !needle.contains("\0")
    }

    var isEmpty: Bool { needle.isEmpty }

    func found(in text: String) -> Bool {
        if ascii {
            let hit = text.withCString { hay in needle.withCString { strcasestr(hay, $0) != nil } }
            if hit { return true }
            // Text with a NUL could hide a match from the C search; all-ASCII text has no accents.
            if text.canBeConverted(to: .ascii) && !text.contains("\0") { return false }
        }
        return text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// Where a page ended: the next page starts after this entry (newest first).
struct ActivityCursor: Sendable, Equatable {
    var at: Date
    var seq: Int
}

/// One page of the Activity window.
struct ActivityPage: Sendable {
    var entries: [Activity] = []
    /// Entries saved under a key that is no longer in the Keychain (FR-203); counted on the first page.
    var unreadable = 0
    /// Where the next page starts; nil when there are no more entries.
    var next: ActivityCursor?
    /// Times of entries under the current key that no longer decrypt: changed outside Latchkey (FR-612).
    var changed: [Date] = []
}

/// What the tamper check found (FR-612, FR-613).
struct LogCheck: Sendable, Equatable {
    /// Each checked entry that doesn't follow from the one before it, oldest first.
    var broken: [ActivityCursor] = []
    /// The newest entry Latchkey wrote is gone, with nothing after it: entries were cut off the end.
    var missingNewer = false
    /// The newest entry still there, when `missingNewer`.
    var lastPresent: Date?
    /// Entries recorded before the check began.
    var beforeCheck = 0

    var brokenSeqs: Set<Int> { Set(broken.map(\.seq)) }
}

/// The log's keys and the chain's rules; Sendable, so the window's searches and the check run off
/// the main thread, each on its own `ModelContext`.
struct ActivityReader: Sendable {
    let container: ModelContainer
    let key: SymmetricKey
    let chainKey: SymmetricKey
    let keyID: String

    static let unknownKey = "-"
    private static let log = Logger(subsystem: AppIdentity.current.logSubsystem, category: "activity")

    init(container: ModelContainer, key: SymmetricKey) {
        self.container = container
        self.key = key
        chainKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key, info: Data("latchkey activity chain".utf8), outputByteCount: 32)
        keyID = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key, info: Data("latchkey activity key id".utf8), outputByteCount: 8
        ).withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    }

    /// The checksum of FR-612: HMAC-SHA256 under a key derived from the log key. An event, a call
    /// id, or a device (FR-632, FR-633) is covered too; an action without them is checksummed
    /// exactly as before they existed, so the chain of an upgraded log still holds.
    func mac(
        previous: Data, seq: Int, id: UUID, at: Date, keyID: String, kind: String = ActivityKind.action.rawValue,
        callID: String = "", device: String = ""
    ) -> Data {
        var m = Data(previous)
        m.append(bigEndian: UInt64(seq))
        m.append(contentsOf: withUnsafeBytes(of: id.uuid) { Array($0) })
        m.append(bigEndian: at.timeIntervalSinceReferenceDate.bitPattern)
        m.append(Data(keyID.utf8))
        if kind != ActivityKind.action.rawValue || !callID.isEmpty || !device.isEmpty {
            // The key ID before is always 16 characters (or "-", never chained), so these
            // separated fields can't be confused with it.
            for field in [kind, callID, device] {
                m.append(0)
                m.append(Data(field.utf8))
            }
        }
        return Data(HMAC<SHA256>.authenticationCode(for: m, using: chainKey))
    }

    func mac(previous: Data, _ a: Activity, seq: Int) -> Data {
        mac(
            previous: previous, seq: seq, id: a.id, at: a.at, keyID: keyID, kind: a.kind.rawValue,
            callID: a.callID ?? "", device: a.device ?? "")
    }

    static let chainStart = Data(repeating: 0, count: 32)

    /// Binds a checked entry's sealed content to its place, so it can't be moved to another row.
    static func boundData(seq: Int, id: UUID) -> Data {
        var d = Data("latchkey activity".utf8)
        d.append(bigEndian: UInt64(seq))
        d.append(contentsOf: withUnsafeBytes(of: id.uuid) { Array($0) })
        return d
    }

    func seal(_ a: Activity, seq: Int) throws -> Data {
        let plain = try JSONEncoder().encode(a)
        return try AES.GCM.seal(plain, using: key, authenticating: Self.boundData(seq: seq, id: a.id)).combined!
    }

    /// A stored row's values, copied out of its context so they can be opened on any thread.
    struct Row: Sendable {
        var id: UUID
        var at: Date
        var seq: Int
        var keyID: String
        var sealed: Data
        var kind: String
        var callID: String
        var device: String

        init(_ s: SealedActivity) {
            id = s.id
            at = s.at
            seq = s.seq
            keyID = s.keyID
            sealed = s.sealed
            kind = s.kind
            callID = s.callID
            device = s.device
        }
    }

    func open(_ s: SealedActivity) -> Activity? { open(Row(s)) }

    /// Decrypts an entry; nil for one sealed with a key that is gone or changed since. Such an
    /// entry is never shown as a tool run, least of all a failed one (FR-203).
    func open(_ s: Row) -> Activity? {
        guard let box = try? AES.GCM.SealedBox(combined: s.sealed) else { return nil }
        let data =
            s.seq == 0
            ? try? AES.GCM.open(box, using: key)
            : try? AES.GCM.open(box, using: key, authenticating: Self.boundData(seq: s.seq, id: s.id))
        guard let data, var a = try? JSONDecoder().decode(Activity.self, from: data) else { return nil }
        a.id = s.id
        a.seq = s.seq
        a.kind = ActivityKind(rawValue: s.kind) ?? .action
        a.callID = s.callID.isEmpty ? nil : s.callID
        a.device = s.device.isEmpty ? nil : s.device
        return a
    }

    /// The entries matching `query`, newest first (or oldest first), after `cursor`, at most
    /// `limit`. Decrypts a batch at a time, each batch in a context of its own so memory stays flat.
    /// `countUnreadable: false` leaves `unreadable` at 0: counting reads an index of the whole
    /// log, and the menu doesn't show the count.
    func page(
        _ query: ActivityQuery, after cursor: ActivityCursor? = nil, limit: Int, oldestFirst: Bool = false,
        countUnreadable: Bool = true
    ) throws -> ActivityPage {
        var page = ActivityPage()
        let kid = keyID
        if cursor == nil && countUnreadable {
            page.unreadable = try ModelContext(container).fetchCount(
                FetchDescriptor<SealedActivity>(predicate: #Predicate { $0.keyID != kid }))
        }
        var position =
            cursor
            ?? (oldestFirst ? ActivityCursor(at: .distantPast, seq: -1) : ActivityCursor(at: .distantFuture, seq: .max))
        let from = query.from ?? .distantPast
        let to = query.to ?? .distantFuture
        let kind = query.kind?.rawValue ?? ""
        // Unfiltered, a page needs about `limit` rows (the menu asks for 10); a search, many.
        let batch = query.text.isEmpty && query.tool == nil ? min(max(limit, 50), 1000) : 1000
        let matcher = ActivityMatcher(query.text)
        while true {
            let pAt = position.at
            let pSeq = position.seq
            let order: SortOrder = oldestFirst ? .forward : .reverse
            var d = FetchDescriptor<SealedActivity>(
                // A plain range on the time, which the index serves; entries at the cursor's own
                // time that were already shown are skipped below.
                predicate: oldestFirst
                    ? #Predicate { $0.at >= from && $0.at < to && $0.at >= pAt && (kind == "" || $0.kind == kind) }
                    : #Predicate { $0.at >= from && $0.at < to && $0.at <= pAt && (kind == "" || $0.kind == kind) },
                sortBy: [SortDescriptor(\.at, order: order), SortDescriptor(\.seq, order: order)])
            d.fetchLimit = batch
            let (count, done) = try autoreleasepool { () throws -> (Int, Bool) in
                let fetched = try ModelContext(container).fetch(d)
                let rows = fetched.filter { $0.at != pAt || (oldestFirst ? $0.seq > pSeq : $0.seq < pSeq) }.map(
                    Row.init)
                // A whole batch at one moment, all shown already, can't happen; never loop on it.
                if rows.isEmpty && fetched.count == batch { return (0, false) }
                for (row, outcome) in zip(rows, sift(rows, query, matcher)) {
                    position = ActivityCursor(at: row.at, seq: row.seq)
                    switch outcome {
                    case .unopenable:
                        if row.keyID == kid { page.changed.append(row.at) }
                    case .skipped:
                        break
                    case .entry(let a):
                        page.entries.append(a)
                        if page.entries.count == limit { return (fetched.count, true) }
                    }
                }
                return (fetched.count, false)
            }
            if done {
                page.next = position
                return page
            }
            if count < batch { return page }
        }
    }

    private enum Sifted: Sendable {
        case entry(Activity)
        case skipped
        case unopenable
    }

    /// Opens and matches a batch on every core; the order is kept.
    private func sift(_ rows: [Row], _ query: ActivityQuery, _ matcher: ActivityMatcher) -> [Sifted] {
        let out = Slots(count: rows.count)
        defer { out.free() }
        let chunk = 32
        DispatchQueue.concurrentPerform(iterations: (rows.count + chunk - 1) / chunk) { c in
            for i in c * chunk..<min(rows.count, (c + 1) * chunk) {
                guard let a = open(rows[i]) else {
                    out.put(i, .unopenable)
                    continue
                }
                out.put(i, query.matches(a, matcher) ? .entry(a) : .skipped)
            }
        }
        return out.values
    }

    /// Results written by index from several threads; each index by one thread only.
    private final class Slots: @unchecked Sendable {
        private let buffer: UnsafeMutableBufferPointer<Sifted>

        init(count: Int) {
            buffer = .allocate(capacity: count)
            buffer.initialize(repeating: .skipped)
        }
        func put(_ i: Int, _ value: Sifted) { buffer[i] = value }
        var values: [Sifted] { Array(buffer) }
        func free() {
            buffer.deinitialize()
            buffer.deallocate()
        }
    }

    /// The newest of Claude's actions that can be read, for the menu (FR-203).
    func recent(limit: Int) throws -> [Activity] {
        try page(ActivityQuery(kind: .action), limit: limit, countUnreadable: false).entries
    }

    /// Every entry `query` selects, oldest first, as JSON Lines into `url` (FR-615). Returns how
    /// many were written.
    @discardableResult
    func export(_ query: ActivityQuery, to url: URL, timeZone: TimeZone = .current) throws -> Int {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: 0)
        let format = ActivityExport(timeZone: timeZone)
        var written = 0
        var cursor: ActivityCursor?
        repeat {
            let p = try page(query, after: cursor, limit: 1000, oldestFirst: true)
            var chunk = Data()
            for a in p.entries {
                chunk.append(Data(format.line(a).utf8))
                chunk.append(0x0A)
            }
            try file.write(contentsOf: chunk)
            written += p.entries.count
            cursor = p.next
        } while cursor != nil
        return written
    }

    /// Every action with a call id, from the fields in the clear (no decrypting), and how many
    /// actions have none (from before call ids, FR-634).
    func calls() throws -> (calls: [MacCall], withoutIDs: Int) {
        let action = ActivityKind.action.rawValue
        var d = FetchDescriptor<SealedActivity>(predicate: #Predicate { $0.kind == action && $0.callID != "" })
        d.propertiesToFetch = [\.callID, \.device, \.at]
        let calls = try ModelContext(container).fetch(d).map {
            MacCall(callID: $0.callID, device: $0.device, at: $0.at)
        }
        let without = try ModelContext(container).fetchCount(
            FetchDescriptor<SealedActivity>(predicate: #Predicate { $0.kind == action && $0.callID == "" }))
        return (calls, without)
    }

    /// The tool of each of these calls, decrypted, for naming the ones missing on the relay.
    func tools(of callIDs: Set<String>) throws -> [String: String] {
        guard !callIDs.isEmpty else { return [:] }
        let ids = Array(callIDs)
        let rows = try ModelContext(container).fetch(
            FetchDescriptor<SealedActivity>(predicate: #Predicate { ids.contains($0.callID) }))
        var out: [String: String] = [:]
        for row in rows { if let a = open(row) { out[row.callID] = a.tool } }
        return out
    }

    /// The newest checked entry under the current key: its number and checksum, where the chain
    /// continues. Walks the numbers down from the newest, a few rows at a time.
    ///
    /// Not one query for "this key, highest number": SQLite answers that from the key's index
    /// and sorts every entry of the key to find the top one, so each start read the whole log
    /// (2026-10-29). The number's own index gives the rows newest first; another key's rows
    /// are skipped here. Only a log whose newest entries are all under an earlier key (the key
    /// was lost) is walked further, and only until the first entry under this one.
    func newestChained(_ context: ModelContext) throws -> ChainTip? {
        let kid = keyID
        var below = Int.max
        let batch = 64
        while true {
            let b = below
            var d = FetchDescriptor<SealedActivity>(
                predicate: #Predicate { $0.seq > 0 && $0.seq < b }, sortBy: [SortDescriptor(\.seq, order: .reverse)])
            d.fetchLimit = batch
            d.propertiesToFetch = [\.seq, \.keyID, \.mac]
            let rows = try context.fetch(d)
            if let mine = rows.first(where: { $0.keyID == kid }) {
                return ChainTip(seq: mine.seq, mac: mine.mac ?? Data())
            }
            guard rows.count == batch, let last = rows.last else { return nil }
            below = last.seq
        }
    }

    /// Entries under the current key recorded before the check began. Asked for by number
    /// alone (there are no new ones), for the same reason as the check's batches.
    private func beforeCheckCount() throws -> Int {
        let kid = keyID
        var d = FetchDescriptor<SealedActivity>(predicate: #Predicate { $0.seq == 0 })
        d.propertiesToFetch = [\.keyID]
        return try autoreleasepool { try ModelContext(container).fetch(d).filter { $0.keyID == kid }.count }
    }

    /// Walks the chain of entries under the current key, oldest first, reading only the
    /// fields in the clear (FR-612); then looks for the newest entry Latchkey knows it wrote
    /// (FR-613). `expected` is nil when that isn't known.
    ///
    /// Each batch is asked for by number alone, so SQLite reads it in order from the number's
    /// index; rows of other keys are skipped here. Asked for "this key and after this number",
    /// SQLite used the key's index and sorted every remaining entry for each batch of 5,000:
    /// that sorting grew with the square of the log (2026-10-29; the whole check took 5 s at 100,000).
    func check(expected: ChainTip?) throws -> LogCheck {
        var result = LogCheck()
        let kid = keyID
        result.beforeCheck = try beforeCheckCount()
        var previous = Self.chainStart
        var after = 0
        var found = false
        var newest: (seq: Int, at: Date)?
        let batch = 5000
        while true {
            let a = after
            var d = FetchDescriptor<SealedActivity>(
                predicate: #Predicate { $0.seq > a }, sortBy: [SortDescriptor(\.seq)])
            d.fetchLimit = batch
            d.propertiesToFetch = [\.seq, \.id, \.at, \.keyID, \.mac, \.kind, \.callID, \.device]
            let count = try autoreleasepool { () throws -> Int in
                let rows = try ModelContext(container).fetch(d)
                for row in rows {
                    after = row.seq
                    guard row.keyID == kid else { continue }
                    let stored = row.mac ?? Data()
                    let place = ActivityCursor(at: row.at, seq: row.seq)
                    let computed = mac(
                        previous: previous, seq: row.seq, id: row.id, at: row.at, keyID: kid, kind: row.kind,
                        callID: row.callID, device: row.device)
                    if stored != computed {
                        result.broken.append(place)
                    }
                    if let expected, row.seq == expected.seq {
                        found = true
                        if stored != expected.mac, result.broken.last != place { result.broken.append(place) }
                    }
                    previous = stored
                    newest = (row.seq, row.at)
                }
                return rows.count
            }
            if count < batch { break }
        }
        if let expected, !found, (newest?.seq ?? 0) < expected.seq {
            result.missingNewer = true
            // The newest entry of any kind still there, for the warning.
            var d = FetchDescriptor<SealedActivity>(sortBy: [SortDescriptor(\.at, order: .reverse)])
            d.fetchLimit = 1
            d.propertiesToFetch = [\.at]
            result.lastPresent = try ModelContext(container).fetch(d).first?.at
        }
        return result
    }
}

/// One exported entry per line (FR-615): fields in a fixed order; arguments and results that
/// are JSON stay JSON, anything else is a string.
struct ActivityExport {
    let formatter: ISO8601DateFormatter

    init(timeZone: TimeZone) {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
    }

    func line(_ a: Activity) -> String {
        let fields: [(String, String)] = [
            ("time", Self.json(formatter.string(from: a.at))), ("kind", Self.json(a.kind.rawValue)),
            ("tool", Self.json(a.tool)), ("arguments", Self.embedded(a.arguments)),
            // An event's text is text, even when it happens to parse as JSON.
            ("result", a.kind == .event ? Self.json(a.result) : Self.embedded(a.result)),
            ("isError", a.isError ? "true" : "false"), ("durationMS", String(a.durationMS)),
            ("call_id", a.callID.map { Self.json($0) } ?? "null"),
            ("client", a.client.map { Self.json($0) } ?? "null"),
        ]
        return "{" + fields.map { "\(Self.json($0.0)):\($0.1)" }.joined(separator: ",") + "}"
    }

    private static func json(_ value: Any) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    private static func embedded(_ text: String) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        else { return json(text) }
        return json(value)
    }
}

/// The activity log for this launch: open, or unavailable with the sentence the app shows
/// (FR-201). The app works the same either way; without the log nothing is recorded.
@MainActor
enum ActivityLog {
    case available(TraceStore)
    case unavailable(String)

    static let keyUnreadable =
        "Activity can’t be shown or recorded right now because Latchkey couldn’t read the log’s key in the Keychain. Latchkey tries again each time it opens."
    static let cannotOpen =
        "Activity can’t be shown or recorded right now because the log couldn’t be opened. Latchkey tries again each time it opens."

    static func open(_ make: () throws -> TraceStore = { try TraceStore() }) -> ActivityLog {
        do {
            return .available(try make())
        } catch let error as TraceKeyUnreadable {
            AppModel.log.error("Activity log unavailable: \(error.localizedDescription, privacy: .public)")
            return .unavailable(keyUnreadable)
        } catch {
            AppModel.log.error("Activity log unavailable: \(error.localizedDescription, privacy: .public)")
            return .unavailable(cannotOpen)
        }
    }

    var store: TraceStore? { if case .available(let s) = self { s } else { nil } }
    var problem: String? { if case .unavailable(let why) = self { why } else { nil } }
}

@MainActor
final class TraceStore {
    static let defaultDirectory = AppIdentity.current.supportDirectory
    nonisolated static let fileName = "activity.store"
    static let legacyFileName = "trace.store"

    let container: ModelContainer
    let reader: ActivityReader
    /// The store's file, for the space it uses (FR-610); nil in memory.
    private let file: URL?
    private let latest: any LatestEntryItem
    /// What the start found about the record of the newest entry (FR-613).
    private(set) var latestState = LatestEntryState.ok
    /// Whether a record exists to update (else the next write adds one).
    private var latestExists = false
    /// The newest entry Latchkey knows it wrote: from the record, then from each new entry.
    /// nil while unknown (no record, or one that couldn't be read).
    private(set) var expected: ChainTip?
    private var nextSeq = 1
    private var previousMac = ActivityReader.chainStart

    init(
        directory: URL = TraceStore.defaultDirectory, keys: any TraceKeyStore = KeychainTraceKey(),
        latest: any LatestEntryItem = KeychainLatestEntry()
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = try keys.loadOrCreate()
        let url = directory.appending(path: Self.fileName)
        container = try ModelContainer(for: SealedActivity.self, configurations: ModelConfiguration(url: url))
        reader = ActivityReader(container: container, key: key)
        file = url
        self.latest = latest
        try prepare()
        try migrateLegacy(in: directory)
    }

    init(inMemory: Bool, keys: any TraceKeyStore, latest: any LatestEntryItem = MemoryLatestEntry()) throws {
        let key = try keys.loadOrCreate()
        container = try ModelContainer(
            for: SealedActivity.self, configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
        reader = ActivityReader(container: container, key: key)
        file = nil
        self.latest = latest
        try prepare()
    }

    private var context: ModelContext { container.mainContext }

    /// Upgrades entries from before the check, then finds where the chain continues.
    private func prepare() throws {
        try labelOldEntries()
        let kid = reader.keyID
        var newest = FetchDescriptor<SealedActivity>(sortBy: [SortDescriptor(\.seq, order: .reverse)])
        newest.fetchLimit = 1
        let lastSeq = try context.fetch(newest).first?.seq ?? 0
        let lastMine = try reader.newestChained(context)

        // FR-613: only "no record" may lead to writing one; one that can't be read or isn't
        // understood is left alone for this launch, and raises no alarm.
        var recorded: ChainTip?
        switch latest.lookup() {
        case .absent:
            latestState = lastMine == nil ? .ok : .missing
        case .unreadable(let why):
            latestState = .unreadable(why)
        case .found(let data):
            latestExists = true
            if let r = LatestEntryRecord.decode(data) {
                if r.keyID == kid { recorded = r.tip }  // one of an earlier key is replaced as it goes
            } else {
                latestState = .unreadable("the record isn’t one this version understands")
            }
        }
        expected = recorded
        // Continue from the newest of the record and the log: the record is ahead when entries
        // were cut off the end, and continuing from it keeps that gap in the chain for good.
        let tip = [recorded, lastMine].compactMap { $0 }.max { $0.seq < $1.seq }
        nextSeq = max(lastSeq, tip?.seq ?? 0) + 1
        previousMac = tip?.mac ?? ActivityReader.chainStart
    }

    /// FR-612 upgrade: entries from before the check get the ID of the key that opens them, in
    /// one save; if it fails, nothing changes and the next start tries again.
    private func labelOldEntries() throws {
        let rows = try context.fetch(FetchDescriptor<SealedActivity>(predicate: #Predicate { $0.keyID == "" }))
        guard !rows.isEmpty else { return }
        for row in rows {
            row.keyID = reader.open(row) == nil ? ActivityReader.unknownKey : reader.keyID
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            AppModel.log.error("Couldn't label the older activity entries: \(error.localizedDescription)")
        }
    }

    func record(_ a: Activity) throws { try record([a]) }

    /// Seals and chains each entry, saves them together, then moves the record of the newest
    /// entry on (FR-612, FR-613). The record is written only after the entries are saved, so it
    /// never names an entry that isn't there.
    func record(_ entries: [Activity]) throws {
        guard !entries.isEmpty else { return }
        var seq = nextSeq
        var previous = previousMac
        for a in entries {
            let mac = reader.mac(previous: previous, a, seq: seq)
            context.insert(
                SealedActivity(
                    id: a.id, at: a.at, sealed: try reader.seal(a, seq: seq), seq: seq, mac: mac, keyID: reader.keyID,
                    kind: a.kind.rawValue, callID: a.callID ?? "", device: a.device ?? ""))
            previous = mac
            seq += 1
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        let tip = ChainTip(seq: seq - 1, mac: previous)
        nextSeq = seq
        previousMac = previous
        expected = tip
        writeLatest(tip)
    }

    private func writeLatest(_ tip: ChainTip) {
        if case .unreadable = latestState { return }  // never written over blindly
        let data = LatestEntryRecord.encode(keyID: reader.keyID, tip: tip)
        do {
            if latestExists {
                try latest.update(data)
            } else {
                try latest.add(data)
                latestExists = true
            }
        } catch {
            // A record left behind only makes the check less strict, never a false alarm.
            AppModel.log.error("Couldn't update the activity log's newest-entry record: \(error.localizedDescription)")
        }
    }

    /// The newest of Claude's actions that can be read, for the menu (FR-203); the app's own
    /// events are in the Activity window only.
    func recent(limit: Int) throws -> [Activity] { try reader.recent(limit: limit) }

    /// The newest readable entries, and how many stored entries can't be read (FR-203).
    func page(limit: Int) throws -> ActivityPage { try reader.page(ActivityQuery(), limit: limit) }

    /// Bytes the log's files take on disk, SQLite's side files included (FR-610).
    var diskBytes: Int64 {
        guard let file else { return 0 }
        return ["", "-wal", "-shm"].reduce(0) { sum, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path + suffix)
            return sum + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Encrypts the plaintext log from before FR-026a into this one, then deletes its files.
    /// The files go even if they can't be read: plaintext must not stay on disk.
    private func migrateLegacy(in directory: URL) throws {
        let legacy = directory.appending(path: Self.legacyFileName)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        do {
            let old = try ModelContainer(for: TraceEntry.self, configurations: ModelConfiguration(url: legacy))
            let entries = try ModelContext(old).fetch(FetchDescriptor<TraceEntry>(sortBy: [SortDescriptor(\.at)]))
            try record(
                entries.map {
                    Activity(
                        at: $0.at, tool: $0.tool, arguments: $0.arguments, result: $0.result, isError: $0.isError,
                        durationMS: $0.durationMS)
                })
        } catch {
            AppModel.log.error("Couldn't move the old activity log; deleting it: \(error.localizedDescription)")
        }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: directory.appending(path: Self.legacyFileName + suffix))
        }
    }
}
