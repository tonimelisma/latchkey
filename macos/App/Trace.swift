import CryptoKit
import Foundation
import OSLog
import Security

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
    /// For an event, whether its line went to macOS's log in public (FR-620): only those are
    /// ever shown to Claude (FR-663). Sealed with the content; nil for actions and for events
    /// recorded before 2026-11-03, which are never shown to Claude.
    var inSystemLog: Bool?

    var beforeCheck: Bool { seq == 0 }

    /// The sealed content: everything but the fields kept beside it. `client` and `inSystemLog`
    /// are optional, so content sealed before they existed opens as before.
    enum CodingKeys: String, CodingKey {
        case id, at, tool, arguments, result, isError, durationMS, client, inSystemLog
    }

    /// One of the app's own events (FR-633); `systemLog` as given to `EventLog.record`.
    static func event(
        _ category: EventCategory, _ text: String, error: Bool = false, systemLog: Bool = true, at: Date = Date()
    ) -> Activity {
        Activity(
            at: at, tool: category.rawValue, arguments: "", result: text, isError: error, durationMS: 0, kind: .event,
            inSystemLog: systemLog)
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
    /// Only the app's events whose line went to macOS's log in public (FR-663).
    var inSystemLogOnly = false

    func matches(_ a: Activity) -> Bool { matches(a, ActivityMatcher(text)) }

    func matches(_ a: Activity, _ matcher: ActivityMatcher) -> Bool {
        if let kind, a.kind != kind { return false }
        if inSystemLogOnly && (a.kind != .event || a.inSystemLog != true) { return false }
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

// MARK: the daily files (FR-680 to FR-682, contracts/trace-files.md)

/// One entry's fields in the clear: a line of a day's `.entries` file, and where its sealed
/// content is in the day's `.content` file.
struct TraceRow: Sendable, Equatable {
    var id: UUID
    var at: Date
    var seq: Int
    var keyID: String
    var kind: String
    var callID: String
    var device: String
    var mac: Data?
    /// The day's name, `YYYY-MM-DD` (UTC).
    var day: String
    var off: Int
    var len: Int
}

/// A line of a `.entries` file, version 1 (contracts/trace-files.md).
private struct EntriesLineV1: Codable {
    var v: Int
    var seq: Int
    var id: UUID
    /// The bit pattern of `at.timeIntervalSinceReferenceDate`, 16 hex digits: the chain's
    /// checksum is over that exact Double.
    var at: String
    /// The same time for people reading the file; never read back.
    var time: String
    var kind: String
    var callID: String
    var device: String
    var key: String
    var mac: String
    var off: Int
    var len: Int

    enum CodingKeys: String, CodingKey {
        case v, seq, id, at, time, kind, callID = "call_id", device, key, mac, off, len
    }
}

/// A day's headers as read: the rows that could be read, and how many lines couldn't (a version
/// this app doesn't know, or a line cut short).
struct TraceDay: Sendable {
    var rows: [TraceRow] = []
    var skipped = 0
}

/// The folder of daily files. Files are only ever appended to (FR-681): nothing here renames,
/// truncates, rewrites, or deletes one. Reading is safe from any thread; writing happens on one
/// (the app's `TraceStore`).
struct TraceFiles: Sendable {
    let folder: URL

    static let entriesSuffix = ".entries"
    static let contentSuffix = ".content"

    init(folder: URL) { self.folder = folder }

    /// The UTC day an entry with this time is filed under.
    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// ISO8601DateFormatter is safe to use from several threads.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")!
        return f
    }()

    static func hex(_ date: Date) -> String {
        String(format: "%016llx", date.timeIntervalSinceReferenceDate.bitPattern)
    }

    static func date(hex: String) -> Date? {
        guard hex.count == 16, let bits = UInt64(hex, radix: 16) else { return nil }
        return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
    }

    func entriesURL(_ day: String) -> URL { folder.appending(path: day + Self.entriesSuffix) }
    func contentURL(_ day: String) -> URL { folder.appending(path: day + Self.contentSuffix) }

    /// Every day with an entries file, oldest first.
    func days() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return
            names
            .filter { $0.hasSuffix(Self.entriesSuffix) && $0.count == 10 + Self.entriesSuffix.count }
            .map { String($0.dropLast(Self.entriesSuffix.count)) }
            .filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }
            .sorted()
    }

    /// A day's rows in file order. Lines that can't be read are counted, never changed.
    func rows(_ day: String) -> TraceDay {
        var out = TraceDay()
        guard let data = try? Data(contentsOf: entriesURL(day), options: .mappedIfSafe) else { return out }
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let l = try? decoder.decode(EntriesLineV1.self, from: Data(line)), l.v == 1,
                let at = Self.date(hex: l.at), l.off >= 0, l.len >= 0
            else {
                out.skipped += 1
                continue
            }
            out.rows.append(
                TraceRow(
                    id: l.id, at: at, seq: l.seq, keyID: l.key, kind: l.kind, callID: l.callID, device: l.device,
                    mac: l.mac.isEmpty ? nil : Data(base64Encoded: l.mac), day: day, off: l.off, len: l.len))
        }
        return out
    }

    /// Every row of every day, and how many lines couldn't be read.
    func allRows() -> TraceDay {
        var out = TraceDay()
        for day in days() {
            let d = rows(day)
            out.rows += d.rows
            out.skipped += d.skipped
        }
        return out
    }

    /// A day's content file, mapped (read on demand, safe to slice from any thread).
    func content(_ day: String) -> Data? { try? Data(contentsOf: contentURL(day), options: .alwaysMapped) }

    /// The sealed content of a row from a day's mapped content.
    static func sealed(_ row: TraceRow, in content: Data?) -> Data? {
        // Checked without adding: a changed line could hold numbers that overflow.
        guard let content, row.off >= 0, row.len >= 0, row.off <= content.count, row.len <= content.count - row.off
        else { return nil }
        return content.subdata(in: (content.startIndex + row.off)..<(content.startIndex + row.off + row.len))
    }

    /// An entry to write: its fields in the clear and its sealed content.
    struct Item {
        var id: UUID
        var at: Date
        var seq: Int
        var keyID: String
        var kind: String
        var callID: String
        var device: String
        var mac: Data?
        var sealed: Data
    }

    /// Appends the entries, each to the day of its time: the content first, then the entries
    /// lines, then both files synchronized to disk. Content without a line pointing at it (a crash
    /// in between) is never read.
    func append(_ items: [Item]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var byDay: [(String, [Item])] = []
        for item in items {
            let day = Self.day(item.at)
            if let i = byDay.firstIndex(where: { $0.0 == day }) {
                byDay[i].1.append(item)
            } else {
                byDay.append((day, [item]))
            }
        }
        let encoder = JSONEncoder()
        for (day, dayItems) in byDay {
            let content = try Self.openForAppend(contentURL(day))
            defer { try? content.close() }
            var offset = Int(try content.seekToEnd())
            var blob = Data()
            var lines = Data()
            for item in dayItems {
                let line = EntriesLineV1(
                    v: 1, seq: item.seq, id: item.id, at: Self.hex(item.at),
                    time: Self.isoFormatter.string(from: item.at),
                    kind: item.kind, callID: item.callID, device: item.device, key: item.keyID,
                    mac: item.mac?.base64EncodedString() ?? "", off: offset, len: item.sealed.count)
                blob.append(item.sealed)
                offset += item.sealed.count
                lines.append(try encoder.encode(line))
                lines.append(0x0A)
            }
            try content.write(contentsOf: blob)
            try content.synchronize()
            let entries = try Self.openForAppend(entriesURL(day))
            defer { try? entries.close() }
            let end = try entries.seekToEnd()
            if end > 0 {
                // A line cut short by a crash must not run into the next one.
                try entries.seek(toOffset: end - 1)
                if try entries.read(upToCount: 1) != Data([0x0A]) { lines.insert(0x0A, at: 0) }
                _ = try entries.seekToEnd()
            }
            try entries.write(contentsOf: lines)
            try entries.synchronize()
        }
    }

    private static func openForAppend(_ url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        return try FileHandle(forUpdating: url)
    }

    /// Bytes the files take on disk (FR-610, FR-689).
    var diskBytes: Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.reduce(0) { sum, name in
            let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appending(path: name).path)
            return sum + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}

/// The log's keys and the chain's rules; Sendable, so the window's searches and the check run off
/// the main thread.
struct ActivityReader: Sendable {
    let files: TraceFiles
    let key: SymmetricKey
    let chainKey: SymmetricKey
    let keyID: String

    static let unknownKey = "-"

    init(files: TraceFiles, key: SymmetricKey) {
        self.files = files
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

    /// Decrypts an entry; nil for one sealed with a key that is gone or changed since. Such an
    /// entry is never shown as a tool run, least of all a failed one (FR-203).
    func open(_ s: TraceRow, sealed: Data?) -> Activity? {
        guard let sealed, let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
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

    /// Opens rows of one day.
    func open(_ rows: [TraceRow]) -> [Activity?] {
        var contents: [String: Data] = [:]
        return rows.map { row in
            if contents[row.day] == nil { contents[row.day] = files.content(row.day) ?? Data() }
            return open(row, sealed: TraceFiles.sealed(row, in: contents[row.day]))
        }
    }

    private static func before(_ a: TraceRow, _ c: ActivityCursor) -> Bool {
        a.at < c.at || (a.at == c.at && a.seq < c.seq)
    }

    /// The entries matching `query`, newest first (or oldest first), after `cursor`, at most
    /// `limit`. Reads a day at a time, newest day first, so the first page reads only the newest
    /// days. `countUnreadable: false` leaves `unreadable` at 0: counting reads every day's
    /// entries file, and the menu doesn't show the count.
    func page(
        _ query: ActivityQuery, after cursor: ActivityCursor? = nil, limit: Int, oldestFirst: Bool = false,
        countUnreadable: Bool = true
    ) throws -> ActivityPage {
        var page = ActivityPage()
        let kid = keyID
        if cursor == nil && countUnreadable {
            let all = files.allRows()
            page.unreadable = all.rows.filter { $0.keyID != kid }.count + all.skipped
        }
        let from = query.from ?? .distantPast
        let to = query.to ?? .distantFuture
        let fromDay = query.from.map(TraceFiles.day)
        let toDay = query.to.map(TraceFiles.day)
        let cursorDay = cursor.map { TraceFiles.day($0.at) }
        var days = files.days()
        if !oldestFirst { days.reverse() }
        let matcher = ActivityMatcher(query.text)
        for day in days {
            if let fromDay, day < fromDay { continue }
            if let toDay, day > toDay { continue }
            if let cursorDay, oldestFirst ? day < cursorDay : day > cursorDay { continue }
            var rows = files.rows(day).rows.filter { r in
                r.at >= from && r.at < to && (query.kind == nil || r.kind == query.kind!.rawValue)
                    && (cursor.map { c in oldestFirst ? Self.before(c.asRow, r.cursor) : Self.before(r, c) } ?? true)
            }
            rows.sort { oldestFirst ? Self.before($0, $1.cursor) : Self.before($1, $0.cursor) }
            guard !rows.isEmpty else { continue }
            let content = files.content(day)
            var start = 0
            let batch = query.text.isEmpty && query.tool == nil ? max(limit, 50) : 1000
            while start < rows.count {
                let chunk = Array(rows[start..<min(rows.count, start + batch)])
                start += chunk.count
                for (row, outcome) in zip(chunk, sift(chunk, content, query, matcher)) {
                    switch outcome {
                    case .unopenable:
                        if row.keyID == kid { page.changed.append(row.at) }
                    case .skipped:
                        break
                    case .entry(let a):
                        page.entries.append(a)
                        if page.entries.count == limit {
                            page.next = row.cursor
                            return page
                        }
                    }
                }
            }
        }
        return page
    }

    private enum Sifted: Sendable {
        case entry(Activity)
        case skipped
        case unopenable
    }

    /// Opens and matches a batch on every core; the order is kept.
    private func sift(_ rows: [TraceRow], _ content: Data?, _ query: ActivityQuery, _ matcher: ActivityMatcher)
        -> [Sifted]
    {
        let out = Slots(count: rows.count)
        defer { out.free() }
        let chunk = 32
        DispatchQueue.concurrentPerform(iterations: (rows.count + chunk - 1) / chunk) { c in
            for i in c * chunk..<min(rows.count, (c + 1) * chunk) {
                guard let a = open(rows[i], sealed: TraceFiles.sealed(rows[i], in: content)) else {
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

    /// Every entry `query` selects, oldest first, as JSON Lines into `url` (FR-615, FR-686).
    /// Returns how many were written.
    @discardableResult
    func export(_ query: ActivityQuery, to url: URL, machine: String, timeZone: TimeZone = .current) throws -> Int {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: 0)
        let format = ActivityExport(timeZone: timeZone, machine: machine)
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
        let actions = files.allRows().rows.filter { $0.kind == ActivityKind.action.rawValue }
        let calls = actions.filter { !$0.callID.isEmpty }.map {
            MacCall(callID: $0.callID, device: $0.device, at: $0.at)
        }
        return (calls, actions.count - calls.count)
    }

    /// The tool of each of these calls, decrypted, for naming the ones missing on the relay.
    func tools(of callIDs: Set<String>) throws -> [String: String] {
        guard !callIDs.isEmpty else { return [:] }
        let rows = files.allRows().rows.filter { callIDs.contains($0.callID) }
        var out: [String: String] = [:]
        for (row, a) in zip(rows, open(rows)) { if let a { out[row.callID] = a.tool } }
        return out
    }

    /// Which of these call ids the log has an action for (FR-667).
    func logged(_ callIDs: Set<String>) throws -> Set<String> {
        guard !callIDs.isEmpty else { return [] }
        return Set(
            files.allRows().rows.filter { $0.kind == ActivityKind.action.rawValue && callIDs.contains($0.callID) }.map(
                \.callID))
    }

    /// The text of the quit event apps from before FR-666 recorded; this app's own quit line
    /// always says more (`CallsInFlight.quitLine`).
    static let oldQuitLine = "Quitting"

    /// When an app from before FR-666, which didn't record the calls running at its quit, began
    /// to quit within one of these windows (FR-668): its app event saying just "Quitting".
    /// Reads only the days of the windows.
    func oldQuits(in windows: [ClosedRange<Date>]) throws -> [Date] {
        var found: Set<Date> = []
        let event = ActivityKind.event.rawValue
        for w in windows {
            let days = files.days().filter { $0 >= TraceFiles.day(w.lowerBound) && $0 <= TraceFiles.day(w.upperBound) }
            for day in days {
                let rows = files.rows(day).rows.filter { $0.kind == event && w.contains($0.at) }
                for a in open(rows).compactMap({ $0 })
                where a.tool == EventCategory.app.rawValue && a.result == Self.oldQuitLine {
                    found.insert(a.at)
                }
            }
        }
        return found.sorted()
    }

    /// The newest entry's number of any key, and the newest checked entry under the current key:
    /// where the chain continues. An entry is filed under the day it began, so one written just
    /// after midnight can sit in the day before; the newest two days with entries are read, and
    /// further back only while the newest days hold none under this key (the key was lost).
    func tip() -> (lastSeq: Int, mine: ChainTip?) {
        let kid = keyID
        var lastSeq = 0
        var mine: TraceRow?
        var read = 0
        for day in files.days().reversed() {
            let rows = files.rows(day).rows
            guard !rows.isEmpty else { continue }
            read += 1
            if read <= 2 { lastSeq = max(lastSeq, rows.map(\.seq).max() ?? 0) }
            if let m = rows.filter({ $0.keyID == kid && $0.seq > 0 }).max(by: { $0.seq < $1.seq }),
                m.seq > (mine?.seq ?? 0)
            {
                mine = m
            }
            if read >= 2 && mine != nil { break }
        }
        return (lastSeq, mine.map { ChainTip(seq: $0.seq, mac: $0.mac ?? Data()) })
    }

    /// Walks the chain of entries under the current key, oldest first, reading only the
    /// fields in the clear (FR-612); then looks for the newest entry Latchkey knows it wrote
    /// (FR-613). `expected` is nil when that isn't known.
    func check(expected: ChainTip?) throws -> LogCheck {
        var result = LogCheck()
        let kid = keyID
        let all = files.allRows().rows
        result.beforeCheck = all.filter { $0.seq == 0 && $0.keyID == kid }.count
        var previous = Self.chainStart
        var found = false
        var newest: (seq: Int, at: Date)?
        for row in all.filter({ $0.seq > 0 && $0.keyID == kid }).sorted(by: { $0.seq < $1.seq }) {
            let stored = row.mac ?? Data()
            let place = row.cursor
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
        if let expected, !found, (newest?.seq ?? 0) < expected.seq {
            result.missingNewer = true
            result.lastPresent = all.map(\.at).max()
        }
        return result
    }
}

extension TraceRow {
    var cursor: ActivityCursor { ActivityCursor(at: at, seq: seq) }
}

extension ActivityCursor {
    fileprivate var asRow: TraceRow {
        TraceRow(id: UUID(), at: at, seq: seq, keyID: "", kind: "", callID: "", device: "", day: "", off: 0, len: 0)
    }
}

/// One exported entry per line (FR-615, FR-686, contracts/trace-files.md "The export line"):
/// fields in a fixed order; arguments and results that are JSON stay JSON, anything else is a
/// string.
struct ActivityExport {
    let formatter: ISO8601DateFormatter
    let machine: String

    init(timeZone: TimeZone, machine: String) {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        self.machine = machine
    }

    func line(_ a: Activity) -> String {
        let fields: [(String, String)] = [
            ("v", "1"), ("source", Self.json("mac")), ("machine", Self.json(machine)),
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

/// The earlier activity database (until 2026-11-15), read once, read-only, straight with SQLite:
/// never opened through SwiftData, which may change a store's file just by opening it (FR-682).
enum ActivityDatabase {
    struct Row {
        var id: UUID
        var at: Date
        var sealed: Data
        var seq: Int
        var keyID: String
        var mac: Data?
        var kind: String
        var callID: String
        var device: String
    }

    /// Every row in the order it was stored; none when there is no table (a store never written).
    static func rows(_ url: URL) throws -> [Row] {
        let db = try SQLite.openReadOnly(url)
        defer { SQLite.close(db) }
        let columns = Set(
            try SQLite.rows(db, "PRAGMA table_info(ZSEALEDACTIVITY)").compactMap { $0.count > 1 ? $0[1].text : nil })
        guard columns.contains("ZID"), columns.contains("ZAT"), columns.contains("ZSEALED") else { return [] }
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let sql = """
            SELECT ZID, ZAT, ZSEALED, \(column("ZSEQ")), \(column("ZKEYID")), \(column("ZMAC")), \
            \(column("ZKIND")), \(column("ZCALLID")), \(column("ZDEVICE")) FROM ZSEALEDACTIVITY ORDER BY Z_PK
            """
        var out: [Row] = []
        try SQLite.forEachRow(db, sql) { v in
            guard let idData = v[0].blob, idData.count == 16, let at = v[1].double, let sealed = v[2].blob else {
                throw SQLite.Failure(message: "a row of the activity database can’t be read")
            }
            let id = idData.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
            out.append(
                Row(
                    id: id, at: Date(timeIntervalSinceReferenceDate: at), sealed: sealed, seq: Int(v[3].int ?? 0),
                    keyID: v[4].text ?? "", mac: v[5].blob, kind: v[6].text ?? ActivityKind.action.rawValue,
                    callID: v[7].text ?? "", device: v[8].text ?? ""))
            return true
        }
        return out
    }

    /// The plaintext log from before FR-026a (`trace.store`), read the same way.
    static func plaintextEntries(_ url: URL) throws -> [Activity] {
        let db = try SQLite.openReadOnly(url)
        defer { SQLite.close(db) }
        let tables = try SQLite.rows(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='ZTRACEENTRY'")
        guard !tables.isEmpty else { return [] }
        return try SQLite.rows(
            db, "SELECT ZAT, ZTOOL, ZARGUMENTS, ZRESULT, ZISERROR, ZDURATIONMS FROM ZTRACEENTRY ORDER BY ZAT"
        ).map { v in
            Activity(
                at: Date(timeIntervalSinceReferenceDate: v[0].double ?? 0), tool: v[1].text ?? "",
                arguments: v[2].text ?? "", result: v[3].text ?? "", isError: (v[4].int ?? 0) != 0,
                durationMS: Int(v[5].int ?? 0))
        }
    }
}

@MainActor
final class TraceStore {
    static let defaultDirectory = AppIdentity.current.supportDirectory
    /// The daily files' folder (FR-680).
    nonisolated static let folderName = "activity"
    /// Where the copy from the database is made before it becomes the folder (FR-682).
    nonisolated static let copyingName = "activity.copying"
    /// The database the log was kept in until 2026-11-15: read once, never changed (FR-682).
    nonisolated static let fileName = "activity.store"
    static let legacyFileName = "trace.store"

    let files: TraceFiles
    let reader: ActivityReader
    /// A folder of the store's own for a test log, removed with the store.
    private let temporary: URL?
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
    /// How many entries the start copied from the database; 0 when there was nothing to copy.
    private(set) var copiedFromDatabase = 0

    convenience init(
        directory: URL = TraceStore.defaultDirectory, keys: any TraceKeyStore = KeychainTraceKey(),
        latest: any LatestEntryItem = KeychainLatestEntry()
    ) throws {
        try self.init(directory: directory, keys: keys, latest: latest, temporary: nil)
    }

    /// A log of its own in a fresh temporary folder, removed with the store (for tests).
    convenience init(inMemory: Bool, keys: any TraceKeyStore, latest: any LatestEntryItem = MemoryLatestEntry()) throws
    {
        let dir = FileManager.default.temporaryDirectory.appending(path: "latchkey-trace-\(UUID().uuidString)")
        try self.init(directory: dir, keys: keys, latest: latest, temporary: dir)
    }

    private init(directory: URL, keys: any TraceKeyStore, latest: any LatestEntryItem, temporary: URL?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = try keys.loadOrCreate()
        let folder = directory.appending(path: Self.folderName)
        files = TraceFiles(folder: folder)
        reader = ActivityReader(files: files, key: key)
        self.temporary = temporary
        self.latest = latest
        copiedFromDatabase = try Self.copyDatabase(
            directory.appending(path: Self.fileName), into: folder, reader: reader)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try prepare()
        try migrateLegacy(in: directory)
        if copiedFromDatabase > 0 {
            try record(
                .event(
                    .app,
                    "The activity log moved into daily files: \(copiedFromDatabase) entries copied unchanged; the earlier database is kept as it was",
                    systemLog: false))
        }
    }

    deinit {
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
    }

    /// Copies every row of the earlier database into the daily files unchanged, all or nothing
    /// (FR-682, contracts/trace-files.md): into a folder of its own, read back, then renamed.
    /// A start that finds the files never copies again; the database is only ever read.
    /// Returns how many entries were copied.
    nonisolated static func copyDatabase(_ database: URL, into folder: URL, reader: ActivityReader) throws -> Int {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { return 0 }
        let copying = folder.deletingLastPathComponent().appending(path: copyingName)
        if fm.fileExists(atPath: copying.path) { try fm.removeItem(at: copying) }  // an interrupted copy
        guard fm.fileExists(atPath: database.path) else { return 0 }
        // Read from a copy: even a read-only SQLite connection writes the database's
        // shared-memory file, and the original is to stay exactly as it was.
        let snapshot = fm.temporaryDirectory.appending(path: "latchkey-activity-\(UUID().uuidString)")
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: snapshot) }
        for suffix in ["", "-wal", "-shm"] {
            let file = database.deletingLastPathComponent().appending(path: database.lastPathComponent + suffix)
            if fm.fileExists(atPath: file.path) {
                try fm.copyItem(at: file, to: snapshot.appending(path: fileName + suffix))
            }
        }
        let rows = try ActivityDatabase.rows(snapshot.appending(path: fileName))
        guard !rows.isEmpty else { return 0 }
        let staging = TraceFiles(folder: copying)
        let kid = reader.keyID
        var start = 0
        while start < rows.count {
            let chunk = rows[start..<min(rows.count, start + 500)]
            start += chunk.count
            try autoreleasepool {
                try staging.append(
                    chunk.map { r in
                        // An entry not yet labelled gets the ID of the key that opens it (FR-612).
                        var keyID = r.keyID
                        if keyID.isEmpty {
                            let row = TraceRow(
                                id: r.id, at: r.at, seq: r.seq, keyID: "", kind: r.kind, callID: r.callID,
                                device: r.device, day: "", off: 0, len: r.sealed.count)
                            keyID = reader.open(row, sealed: r.sealed) == nil ? ActivityReader.unknownKey : kid
                        }
                        return TraceFiles.Item(
                            id: r.id, at: r.at, seq: r.seq, keyID: keyID, kind: r.kind, callID: r.callID,
                            device: r.device, mac: r.mac, sealed: r.sealed)
                    })
            }
        }
        let back = staging.allRows()
        guard back.skipped == 0, back.rows.count == rows.count,
            back.rows.map(\.seq).max() == rows.map(\.seq).max(),
            Set(back.rows.map(\.id)) == Set(rows.map(\.id))
        else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSDebugDescriptionErrorKey: "the copy didn’t read back"])
        }
        try fm.moveItem(at: copying, to: folder)
        return rows.count
    }

    /// Finds where the chain continues.
    private func prepare() throws {
        let kid = reader.keyID
        let (lastSeq, lastMine) = reader.tip()

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

    func record(_ a: Activity) throws { try record([a]) }

    /// Seals and chains each entry, appends them to their days' files, then moves the record of
    /// the newest entry on (FR-612, FR-613). The record is written only after the entries are on
    /// disk, so it never names an entry that isn't there.
    func record(_ entries: [Activity]) throws {
        guard !entries.isEmpty else { return }
        var seq = nextSeq
        var previous = previousMac
        var items: [TraceFiles.Item] = []
        for a in entries {
            let mac = reader.mac(previous: previous, a, seq: seq)
            items.append(
                TraceFiles.Item(
                    id: a.id, at: a.at, seq: seq, keyID: reader.keyID, kind: a.kind.rawValue, callID: a.callID ?? "",
                    device: a.device ?? "", mac: mac, sealed: try reader.seal(a, seq: seq)))
            previous = mac
            seq += 1
        }
        try files.append(items)
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

    /// Bytes the daily files take on disk (FR-610, FR-689); the earlier database isn't counted.
    var diskBytes: Int64 { files.diskBytes }

    /// Encrypts the plaintext log from before FR-026a into this one, then deletes its files.
    /// The files go even if they can't be read: plaintext must not stay on disk.
    private func migrateLegacy(in directory: URL) throws {
        let legacy = directory.appending(path: Self.legacyFileName)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        do {
            try record(try ActivityDatabase.plaintextEntries(legacy))
        } catch {
            AppModel.log.error("Couldn't move the old activity log; deleting it: \(error.localizedDescription)")
        }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: directory.appending(path: Self.legacyFileName + suffix))
        }
    }
}
