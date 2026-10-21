import Foundation
import Testing

@testable import Latchkey

@Suite struct InstallationTests {
    @Test func offersToMoveOnlyOutsideApplications() {
        #expect(!AppLocation.needsMove(URL(fileURLWithPath: "/Applications/Latchkey.app")))
        #expect(!AppLocation.needsMove(URL(fileURLWithPath: "/Users/t/Applications/Latchkey.app")))
        #expect(AppLocation.needsMove(URL(fileURLWithPath: "/Users/t/Downloads/Latchkey.app")))
        #expect(AppLocation.needsMove(URL(fileURLWithPath: "/Volumes/Latchkey/Latchkey.app")), "the disk image")
        #expect(!AppLocation.needsMove(URL(fileURLWithPath: "/x/build/DerivedData/Build/Products/Debug/Latchkey.app")))
    }

    @Test func recognizesTheTrash() {
        #expect(TrashWatcher.isInTrash("/Users/t/.Trash/Latchkey.app"))
        #expect(TrashWatcher.isInTrash("/Volumes/USB/.Trashes/501/Latchkey.app"))
        #expect(!TrashWatcher.isInTrash("/Applications/Latchkey.app"))
        #expect(!TrashWatcher.isInTrash("/Applications/Old Latchkey.app"))
    }

    @Test func noticesAMoveToTheTrash() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let bundle = base.appending(path: "Apps/Latchkey.app")
        let trash = base.appending(path: ".Trash")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let fired = Locked(false)
        let watcher = try #require(TrashWatcher(bundle: bundle) { fired.mutate { $0 = true } })
        try FileManager.default.moveItem(at: bundle, to: trash.appending(path: "Latchkey.app"))
        for _ in 0..<50 where !fired.value { try await Task.sleep(for: .milliseconds(20)) }
        #expect(fired.value)
        _ = watcher
    }

    @Test func ignoresAnOrdinaryMove() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let bundle = base.appending(path: "A/Latchkey.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appending(path: "B"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let fired = Locked(false)
        let watcher = try #require(TrashWatcher(bundle: bundle) { fired.mutate { $0 = true } })
        try FileManager.default.moveItem(at: bundle, to: base.appending(path: "B/Latchkey.app"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!fired.value)
        _ = watcher
    }

    @Test func removesLocalData() throws {
        let support = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("log".utf8).write(to: support.appending(path: "trace.store"))
        let suite = "net.melisma.latchkey.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "keepAwakeEnabled")

        let cache = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        LocalData(supportDirectory: support, defaultsDomain: suite, defaults: defaults, systemFolders: [cache]).remove()
        #expect(!FileManager.default.fileExists(atPath: support.path))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(UserDefaults(suiteName: suite)?.object(forKey: "keepAwakeEnabled") == nil)
    }

    @Test func readsTheKernelSleepFlag() {
        #expect(PowerReader.sleepDisabled() != nil, "IOPMrootDomain SleepDisabled is readable without privileges")
    }
}
