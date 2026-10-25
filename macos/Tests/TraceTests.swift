import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import Latchkey

@Suite struct TraceTests {
    /// A folder of its own and a key that never touches the real Keychain.
    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Every byte the store left on disk, including SQLite's side files.
    static func bytesOnDisk(_ dir: URL) throws -> [Data] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).map {
            try Data(contentsOf: $0)
        }
    }

    @MainActor @Test func recordsAndPurges() throws {
        let trace = try TraceStore(inMemory: true, keys: MemoryTraceKey())
        let now = Date()
        try trace.record(
            Activity(
                at: now.addingTimeInterval(-91 * 86_400), tool: "battery_status",
                arguments: "{}", result: "{\"battery_percent\":80}", isError: false, durationMS: 12))
        try trace.record(
            Activity(at: now, tool: "battery_status", arguments: "{}", result: "{}", isError: true, durationMS: 3))
        #expect(try trace.recent(limit: 10).count == 2)

        let removed = try trace.purge(olderThan: now.addingTimeInterval(-90 * 86_400))
        #expect(removed == 1, "FR-026: 90 days")
        let left = try trace.recent(limit: 10)
        #expect(left.count == 1)
        #expect(left.first?.isError == true)
        #expect(left.first?.durationMS == 3)
    }

    /// FR-026a: another program reading the activity log's files finds no tool, arguments, or result.
    @MainActor @Test func storesNothingReadable() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = "secret-note-\(UUID().uuidString)"
        do {
            let trace = try TraceStore(directory: dir, keys: MemoryTraceKey())
            try trace.record(
                Activity(
                    at: Date(), tool: "notes_read", arguments: "{\"q\":\"\(marker)\"}", result: marker, isError: false,
                    durationMS: 5))
            let back = try #require(try trace.recent(limit: 1).first)
            #expect(back.tool == "notes_read")
            #expect(back.arguments.contains(marker), "shown in the app, decrypted")
            #expect(back.result == marker)
        }
        let plain = Data(marker.utf8)
        for data in try Self.bytesOnDisk(dir) {
            #expect(data.range(of: plain) == nil, "no plaintext on disk")
            #expect(data.range(of: Data("notes_read".utf8)) == nil, "not even the tool name")
        }
    }

    /// Plaintext entries from before FR-026a are encrypted into the new log once, and the old
    /// file is deleted.
    @MainActor @Test func encryptsTheOldPlaintextLog() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = "old-message-\(UUID().uuidString)"
        let when = Date().addingTimeInterval(-3600)
        do {
            let old = try ModelContainer(
                for: TraceEntry.self, configurations: ModelConfiguration(url: dir.appending(path: "trace.store")))
            old.mainContext.insert(
                TraceEntry(
                    at: when, tool: "messages_read", arguments: "{}", result: marker, isError: false, durationMS: 9))
            try old.mainContext.save()
        }
        #expect(
            try Self.bytesOnDisk(dir).contains { $0.range(of: Data(marker.utf8)) != nil }, "the old log is plaintext")

        let trace = try TraceStore(directory: dir, keys: MemoryTraceKey())
        let moved = try #require(try trace.recent(limit: 10).first)
        #expect(moved.result == marker)
        #expect(moved.tool == "messages_read")
        #expect(abs(moved.at.timeIntervalSince(when)) < 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains { $0.hasPrefix("trace.store") }, "old files deleted: \(names)")
        for data in try Self.bytesOnDisk(dir) { #expect(data.range(of: Data(marker.utf8)) == nil) }
    }

    /// FR-203: entries saved under a key that is gone (another key in the Keychain) are not
    /// tool runs that failed. The menu and the window list only what can be read; the window
    /// says how many can't.
    @MainActor @Test func entriesThatCannotBeReadAreNotFailures() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        do {
            let trace = try TraceStore(directory: dir, keys: MemoryTraceKey())
            for age in [10.0, 20, 30] {
                try trace.record(
                    Activity(
                        at: now.addingTimeInterval(-age), tool: "shell_run", arguments: "{}", result: "ok",
                        isError: false, durationMS: 1))
            }
        }
        let trace = try TraceStore(directory: dir, keys: MemoryTraceKey())
        #expect(try trace.recent(limit: 10).isEmpty, "the menu lists none of them")
        #expect(try trace.page(limit: 500).unreadable == 3)

        try trace.record(
            Activity(
                at: now.addingTimeInterval(-60), tool: "notes_read", arguments: "{}", result: "older but readable",
                isError: false, durationMS: 2))
        try trace.record(
            Activity(
                at: now, tool: "files_read", arguments: "{}", result: "No such file.", isError: true, durationMS: 4)
        )
        // Only one entry asked for: the three unreadable ones between the two don't use up the limit.
        #expect(try trace.recent(limit: 1).map(\.tool) == ["files_read"])
        let menu = try trace.recent(limit: 10)
        #expect(menu.map(\.tool) == ["files_read", "notes_read"], "newest first, unreadable ones skipped")
        #expect(menu.map { ActivityFormat.title($0).hasSuffix("(failed)") } == [true, false], "only real failures")
        #expect(!menu.contains { $0.tool == "unknown" })

        let page = try trace.page(limit: 500)
        #expect(page.entries.map(\.tool) == ["files_read", "notes_read"])
        #expect(page.unreadable == 3)
        #expect(try trace.page(limit: 1).unreadable == 3, "counted whatever the limit")
    }

    /// Unreadable entries still age out after 90 days (FR-026).
    @MainActor @Test func entriesThatCannotBeReadStillAgeOut() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        do {
            let trace = try TraceStore(directory: dir, keys: MemoryTraceKey())
            for days in [91.0, 1] {
                try trace.record(
                    Activity(
                        at: now.addingTimeInterval(-days * 86_400), tool: "shell_run", arguments: "{}", result: "ok",
                        isError: false, durationMS: 1))
            }
        }
        let trace = try TraceStore(directory: dir, keys: MemoryTraceKey())
        #expect(try trace.page(limit: 10).unreadable == 2)
        #expect(try trace.purge(olderThan: now.addingTimeInterval(-TraceStore.retention)) == 1)
        #expect(try trace.page(limit: 10).unreadable == 1)
    }

    /// The one line the Activity window shows about them.
    @Test func theWindowSaysHowManyCannotBeRead() {
        #expect(ActivityFormat.unreadableNote(0) == nil)
        #expect(
            ActivityFormat.unreadableNote(1)
                == "1 older entry can’t be read because its key is no longer in the Keychain. It will be removed when it is 90 days old."
        )
        #expect(
            ActivityFormat.unreadableNote(12)
                == "12 older entries can’t be read because their key is no longer in the Keychain. They will be removed when they are 90 days old."
        )
    }

    @Test func theKeyIsMadeOnceAndKept() throws {
        let keys = MemoryTraceKey()
        let raw = { (k: SymmetricKey) in k.withUnsafeBytes { Data($0) } }
        let a = raw(try keys.loadOrCreate())
        #expect(a.count == 32, "AES-256")
        #expect(raw(try keys.loadOrCreate()) == a)
        keys.delete()
        #expect(raw(try keys.loadOrCreate()) != a, "a deleted key is gone")
    }
}
