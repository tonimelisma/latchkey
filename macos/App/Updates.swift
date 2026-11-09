import AppKit
import Foundation
import Observation
import Sparkle

/// Updates (spec 001 FR-072, FR-669). Signed updates with Sparkle 2 run only when the build
/// carries an EdDSA public key (with a Developer ID, later). Until then the app looks at GitHub's
/// releases once a day and, when a newer Latchkey is out, offers its download page in the menu
/// and in Settings; installing stays the Owner's.
@MainActor
@Observable
final class Updates {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    /// A newer Latchkey on GitHub, once the daily check has found one.
    private(set) var notice: ReleaseNotice?
    @ObservationIgnored private var checking: Task<Void, Never>?

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        controller =
            key.isEmpty
            ? nil : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
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
