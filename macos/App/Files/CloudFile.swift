import Foundation
import os

/// Files kept only in the cloud (iCloud Drive, OneDrive, Dropbox, Google Drive: anything macOS's
/// File Provider manages) are downloaded before they're read (spec 003 plan D2).
///
/// macOS refused `startDownloadingUbiquitousItem` to the installed app for a OneDrive file with
/// "you don't have permission" while the same call from a plain program worked (2026-11-04), so the
/// download goes through file coordination first, which asks File Provider for the file however the
/// process is set up, and falls back to the download request. Whatever fails is described with its
/// error codes for Latchkey's log, never the file's name.
enum CloudFile {
    /// What reaching the cloud takes; real by default, replaced in tests.
    struct Steps: Sendable {
        var isCloudOnly: @Sendable (URL) -> Bool = CloudFile.isCloudOnly
        /// Blocks until File Provider has the file here, or fails.
        var coordinate: @Sendable (URL, NSFileCoordinator) -> Error? = CloudFile.coordinatedRead
        var request: @Sendable (URL) throws -> Void = { try FileManager.default.startDownloadingUbiquitousItem(at: $0) }
        var pause: Duration = .milliseconds(250)
        var cancel: @Sendable (NSFileCoordinator) -> Void = { $0.cancel() }
    }

    /// Downloads the file if only its placeholder is here. Nil when the file is here (or now is);
    /// otherwise why it isn't, for the log and the answer.
    static func download(_ url: URL, within limit: Duration = .seconds(20), steps: Steps = Steps()) async -> String? {
        guard steps.isCloudOnly(url) else { return nil }
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        var reasons: [String] = []
        switch await coordinated(url, until: deadline, steps: steps) {
        case .done where !steps.isCloudOnly(url): return nil
        case .done: reasons.append("coordination: finished but the file is still in the cloud")
        case .failed(let error): reasons.append("coordination: \(describe(error))")
        case .timedOut: return "it didn't download within \(limit.components.seconds) seconds"
        }
        do { try steps.request(url) } catch {
            reasons.append("download request: \(describe(error))")
            return reasons.joined(separator: "; ")
        }
        while clock.now < deadline {
            try? await Task.sleep(for: steps.pause)
            if !steps.isCloudOnly(url) { return nil }
        }
        reasons.append("download request: not done within \(limit.components.seconds) seconds")
        return reasons.joined(separator: "; ")
    }

    /// Only a placeholder is on the disk: the file system marks it dataless, or iCloud says it isn't
    /// downloaded.
    static func isCloudOnly(_ url: URL) -> Bool {
        var info = stat()
        if stat(url.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) != 0 { return true }
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let v = try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return v?.isUbiquitousItem == true && v?.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    /// An error and the errors under it, by domain and code: "NSCocoaErrorDomain 257 < NSPOSIXErrorDomain 1".
    static func describe(_ error: Error) -> String {
        var parts: [String] = []
        var e: NSError? = error as NSError
        while let current = e, parts.count < 4 {
            parts.append("\(current.domain) \(current.code)")
            e = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " < ")
    }

    private enum Outcome: Sendable {
        case done
        case failed(Error)
        case timedOut
    }

    /// Coordination blocks its thread, so it runs on its own thread, never one of Swift's shared
    /// ones, and is cancelled when the deadline passes (Constitution II).
    private static func coordinated(
        _ url: URL, until deadline: ContinuousClock.Instant, steps: Steps
    ) async -> Outcome {
        let coordinator = NSFileCoordinator()
        let answered = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let finish: @Sendable (Outcome) -> Bool = { outcome in
                let first = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: outcome) }
                return first
            }
            Thread.detachNewThread {
                _ = finish(steps.coordinate(url, coordinator).map { .failed($0) } ?? .done)
            }
            let wait = ContinuousClock().now.duration(to: deadline)
            let nanos = max(0, wait.components.seconds * 1_000_000_000 + wait.components.attoseconds / 1_000_000_000)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .nanoseconds(Int(nanos))) {
                if finish(.timedOut) { steps.cancel(coordinator) }
            }
        }
    }

    private static func coordinatedRead(_ url: URL, _ coordinator: NSFileCoordinator) -> Error? {
        var error: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &error) { _ in }
        return error
    }
}
