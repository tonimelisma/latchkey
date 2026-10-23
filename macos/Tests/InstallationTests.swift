import AuthenticationServices
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

        // Never the real pairing: the test app shares the installed app's Keychain and settings.
        var forgot = false
        LocalData(
            supportDirectory: support, defaultsDomain: suite, defaults: defaults, forgetIdentity: { forgot = true },
            systemFolders: [cache]
        ).remove()
        #expect(forgot)
        #expect(!FileManager.default.fileExists(atPath: support.path))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(UserDefaults(suiteName: suite)?.object(forKey: "keepAwakeEnabled") == nil)
    }

    @Test func readsTheKernelSleepFlag() {
        #expect(PowerReader.sleepDisabled() != nil, "IOPMrootDomain SleepDisabled is readable without privileges")
    }
}

@Suite struct PairingLinkTests {
    @Test func parsesCodeAndRelay() throws {
        let link = try #require(
            PairingFlow.parse(URL(string: "latchkey://paired?code=abc&relay=https%3A%2F%2Frelay.example.com")!))
        #expect(link.code == "abc")
        #expect(link.relay == URL(string: "https://relay.example.com"))
    }

    @Test func rejectsOtherLinks() {
        #expect(PairingFlow.parse(URL(string: "latchkey://paired")!) == nil, "no code")
        #expect(PairingFlow.parse(URL(string: "latchkey://other?code=abc")!) == nil)
        #expect(PairingFlow.parse(URL(string: "https://paired?code=abc")!) == nil)
    }

    @Test func refusesAPlainHTTPRelay() throws {
        let link = try #require(
            PairingFlow.parse(URL(string: "latchkey://paired?code=a&relay=http%3A%2F%2Fevil.example")!))
        #expect(link.relay == nil, "only https, or http on localhost")
    }

    @Test func replacementIsNotAnUninstall() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appending(path: "Latchkey.app/Contents")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        #expect(!AppLocation.replaced(at: dir.appending(path: "Latchkey.app").path), "no bundle there")
        try FileManager.default.removeItem(at: dir.appending(path: "Latchkey.app"))
        try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: dir.appending(path: "Latchkey.app"))
        #expect(AppLocation.replaced(at: dir.appending(path: "Latchkey.app").path), "a Latchkey took its place")
    }
}

@Suite struct PairingCallbackThreadTests {
    /// macOS calls the sign-in window's completion handler on a background thread. If the
    /// handler carried main-actor isolation, this call would trap (as 0.1.0 and 0.1.1 did).
    @Test func completionHandlerRunsOffTheMainThread() async {
        let got = Locked<String?>(nil)
        let handler = PairingFlow.completionHandler { result in
            got.mutate { $0 = (try? result.get())?.absoluteString ?? "error" }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                handler(URL(string: "latchkey://paired?code=x"), nil)
                handler(nil, ASWebAuthenticationSessionError(.canceledLogin))
                done.resume()
            }
        }
        #expect(got.value == "error", "the second call (cancelled) is delivered too")
    }
}
