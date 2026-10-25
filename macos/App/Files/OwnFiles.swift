import Foundation

/// Latchkey's own files, which Files never changes (spec 003 FR-210): the activity log and other
/// data, the settings (they hold the capability levels), and the app itself. Reading is allowed.
struct OwnFiles: Sendable {
    /// Folders that are Latchkey's, with everything in them.
    var folders: [URL]
    /// Folders where settings files live, and the start of the names of Latchkey's.
    var settingsFolders: [URL]
    var settingsPrefix: String

    static let refusal = "Latchkey doesn't change its own files. Nothing was changed."

    static let standard = OwnFiles(
        folders: [
            URL.applicationSupportDirectory.appending(path: "Latchkey", directoryHint: .isDirectory),
            Bundle.main.bundleURL,
        ],
        settingsFolders: [
            URL.libraryDirectory.appending(path: "Preferences", directoryHint: .isDirectory),
            URL.libraryDirectory.appending(path: "Preferences/ByHost", directoryHint: .isDirectory),
        ],
        settingsPrefix: HelperIdentity.appBundleID)

    /// True when `url` is one of Latchkey's files or folders, or inside one.
    func holds(_ url: URL) -> Bool {
        let path = Self.parts(url)
        if folders.contains(where: { path.starts(with: Self.parts($0)) }) { return true }
        // A settings file: directly in a settings folder, named "<bundle id>.<anything>".
        guard let name = path.last, name.hasPrefix(Self.fold(settingsPrefix) + ".") else { return false }
        return settingsFolders.contains { Self.parts($0) == path.dropLast() }
    }

    /// True when `url` is a folder that has one of Latchkey's files or folders somewhere in it,
    /// so moving or deleting it would take them along.
    func isAbove(_ url: URL) -> Bool {
        let path = Self.parts(url)
        return (folders + settingsFolders).contains { Self.parts($0).starts(with: path) }
    }

    /// The path's parts as the disk sees them, for comparing: links followed, and letter case
    /// and accent encoding ignored, as the Mac's disk ignores them. (On a disk that tells
    /// "Latchkey" from "latchkey", this refuses both.)
    static func parts(_ url: URL) -> [String] {
        real(url.standardizedFileURL).pathComponents.map(fold)
    }

    private static func fold(_ s: String) -> String { s.decomposedStringWithCanonicalMapping.lowercased() }

    /// `url` with every symbolic link followed, including the links on the way to a file that
    /// doesn't exist yet (a new file in a linked folder) and a link whose target doesn't.
    static func real(_ url: URL, hops: Int = 0) -> URL {
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return URL(filePath: String(cString: resolved))
        }
        guard url.path != "/", hops < 100 else { return url }
        let parent = url.deletingLastPathComponent()
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            return real(URL(filePath: target, relativeTo: parent).absoluteURL.standardizedFileURL, hops: hops + 1)
        }
        return real(parent, hops: hops + 1).appending(path: url.lastPathComponent)
    }
}
