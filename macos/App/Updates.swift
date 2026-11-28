import AppKit
import Foundation
import Observation
import Sparkle

/// Updates (spec 001 FR-072 to FR-072d, FR-669). A build that carries Latchkey's own update key
/// (EdDSA, `SPARKLE_PUBLIC_ED_KEY`; no Developer ID needed) updates itself with Sparkle 2: it
/// checks the published feed every hour, downloads a newer release in the background without
/// showing anything (Constitution IV), and installs it only while Latchkey is idle
/// (`UpdateGate`). A build without the key looks at GitHub's releases once a day and, when a
/// newer Latchkey is out, offers its download page in the menu and in Settings (FR-669).
@MainActor
@Observable
final class Updates {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    /// Sparkle holds its delegate weakly; this keeps it.
    @ObservationIgnored private let gate: UpdateGate
    /// A newer Latchkey on GitHub, once the daily check has found one.
    private(set) var notice: ReleaseNotice?
    @ObservationIgnored private var checking: Task<Void, Never>?

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        gate = UpdateGate(
            marks: AppIdentity.current.supportDirectory.appending(
                path: CallMarks.folderName, directoryHint: .isDirectory))
        // Only the installed app: never a test run, and never a Debug build (it would replace
        // itself with the release build).
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        controller =
            key.isEmpty || testing || AppIdentity.current != .release
            ? nil : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: gate, userDriverDelegate: nil)
    }

    /// The calls running now (FR-072b): the gate waits for them as well as for the marks on disk.
    func watchCalls(_ calls: CallsInFlight) {
        gate.calls = { [weak calls] in calls.map { ($0.runningCount, $0.lastChange) } }
    }

    /// Sparkle's own check is available (a build with an update key).
    var available: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// Starts the daily look at GitHub's releases: the installed app only, never a Debug or test
    /// build (their version isn't a release), and not when Sparkle does the job.
    func startDailyCheck(current: String) {
        guard controller == nil, checking == nil, AppIdentity.current == .release,
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        else { return }
        checking = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))  // not in the way of connecting at start
            while !Task.isCancelled {
                let found = await ReleaseCheck.fetch(current: current)
                if let self, let found { self.record(found) }
                try? await Task.sleep(for: .seconds(ReleaseCheck.interval))
            }
        }
    }

    private func record(_ found: ReleaseCheck.Outcome) {
        switch found {
        case .newer(let release):
            if release != notice {
                EventLog.shared.record(.app, "Latchkey \(release.version) is available")
            }
            notice = release
        case .current:
            notice = nil
        }
    }

    /// Opens the release's page in the Owner's browser (they chose Download).
    func openDownload() {
        guard let notice else { return }
        NSWorkspace.shared.open(notice.page)
    }
}

/// Holds a downloaded update until Latchkey is idle (FR-072b; decided 2026-11-22: an install had
/// restarted Latchkey in the middle of his Target order): no call running and none started or
/// ended for 10 minutes, the same rule the Mac's install script used (`idle_verdict`). Sparkle
/// asks before installing a downloaded update on quit; the gate keeps its install block, looks
/// every minute, and installs (Sparkle quits, replaces, and starts the app again) once idle.
@MainActor
final class UpdateGate: NSObject, SPUUpdaterDelegate {
    static let quiet: TimeInterval = 10 * 60
    private let marks: URL
    /// The calls in memory: how many run and when one last started or ended.
    var calls: (@MainActor () -> (running: Int, lastChange: Date)?)?
    private var install: (() -> Void)?
    private var watching: Task<Void, Never>?

    init(marks: URL) { self.marks = marks }

    // Sparkle calls its delegate on the main thread.
    nonisolated func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        nonisolated(unsafe) let block = immediateInstallationBlock  // used on the main thread only
        MainActor.assumeIsolated { hold(block, version: version) }
        return true
    }

    private func hold(_ block: @escaping () -> Void, version: String) {
        install = block
        guard watching == nil else { return }
        EventLog.shared.record(.app, "Latchkey \(version) is downloaded; it installs once Latchkey is idle")
        watching = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.idleNow() {
                    self.watching = nil
                    EventLog.shared.record(.app, "Installing Latchkey \(version) now that Latchkey is idle")
                    // Sparkle quits the app: never from inside a main-queue job (.claude/rules/macos.md).
                    self.perform(#selector(self.installNow), with: nil, afterDelay: 0)
                    return
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    @objc private func installNow() {
        // A call may have started since the last look: then keep waiting.
        guard idleNow() else {
            if let block = install {
                install = nil
                hold(block, version: "the downloaded update")
            }
            return
        }
        let block = install
        install = nil
        block?()
    }

    /// Idle by both the marks on disk and the calls in memory (marks exist only while the
    /// activity log is open, so the disk alone could say idle while a call runs).
    private func idleNow() -> Bool {
        let now = Date()
        guard Self.isIdle(marks: marks, now: now, quiet: Self.quiet) else { return false }
        guard let state = calls?() else { return calls == nil }
        return Self.isIdle(running: state.running, lastChange: state.lastChange, now: now, quiet: Self.quiet)
    }

    /// Whether the calls in memory leave Latchkey idle: none running and none started or ended
    /// for `quiet`.
    nonisolated static func isIdle(running: Int, lastChange: Date, now: Date, quiet: TimeInterval) -> Bool {
        running == 0 && now.timeIntervalSince(lastChange) >= quiet
    }

    /// Whether Latchkey is idle: no running-call mark in `marks`, and the folder (whose change
    /// time is when a call last started or ended) unchanged for `quiet`. No folder: no call ever
    /// ran, so idle.
    nonisolated static func isIdle(marks: URL, now: Date, quiet: TimeInterval) -> Bool {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: marks.path) else { return true }
        if names.contains(where: { $0.hasSuffix(".call") }) { return false }
        guard let changed = (try? manager.attributesOfItem(atPath: marks.path))?[.modificationDate] as? Date
        else { return true }
        return now.timeIntervalSince(changed) >= quiet
    }

    /// The build number Sparkle compares (CFBundleVersion) for release `x.y.z`: x·1,000,000 +
    /// y·1,000 + z, so it grows with every release; nil for anything else. Kept in step with
    /// `macos/scripts/package.sh`.
    nonisolated static func buildNumber(_ version: String) -> Int? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let x = parts[0], let y = parts[1], let z = parts[2],
            x >= 0, (0..<1000).contains(y), (0..<1000).contains(z)
        else { return nil }
        return x * 1_000_000 + y * 1000 + z
    }
}

/// A newer release of the Mac app on GitHub.
struct ReleaseNotice: Equatable, Sendable {
    let version: String
    let page: URL
}

/// Reading GitHub's list of releases (FR-669). The list holds the Linux program's releases too;
/// only `mac-<x.y.z>` tags count. The page opened is built from the tag, never taken from the
/// answer, so a bad answer can't send the Owner elsewhere.
enum ReleaseCheck {
    static let repository = "tonimelisma/latchkey"
    static let feed = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=50")!
    static let interval: TimeInterval = 24 * 60 * 60
    static let prefix = "mac-"

    enum Outcome: Equatable, Sendable {
        case newer(ReleaseNotice)
        case current
    }

    private struct Release: Decodable {
        let tag: String
        let draft: Bool?
        let prerelease: Bool?
        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case draft, prerelease
        }
    }

    /// The newest release above `current`, or nil when there's none or the answer can't be read.
    static func notice(from data: Data, current: String) -> ReleaseNotice? {
        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else { return nil }
        let versions = releases.compactMap { release -> String? in
            guard release.draft != true, release.prerelease != true, release.tag.hasPrefix(prefix)
            else { return nil }
            let version = String(release.tag.dropFirst(prefix.count))
            return numbers(version) == nil ? nil : version
        }
        guard let newest = versions.max(by: { isNewer($1, than: $0) }), isNewer(newest, than: current),
            let page = URL(string: "https://github.com/\(repository)/releases/tag/\(prefix)\(newest)")
        else { return nil }
        return ReleaseNotice(version: newest, page: page)
    }

    /// Whether version `a` is above `b`, comparing numbers part by part (missing parts are 0).
    /// False when either isn't a version.
    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = numbers(a), let y = numbers(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// One look at GitHub: nil when it can't be reached or read (the next day tries again).
    /// No cookies or stored credentials go with it.
    static func fetch(current: String) async -> Outcome? {
        var request = URLRequest(url: feed, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Latchkey/\(current)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        if let release = notice(from: data, current: current) { return .newer(release) }
        // A readable list with nothing newer is "current"; an unreadable one tells nothing.
        return (try? JSONSerialization.jsonObject(with: data)) is [Any] ? .current : nil
    }
}
