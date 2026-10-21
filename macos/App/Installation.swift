import AppKit
import Foundation
import ServiceManagement

/// Where the app runs from, and moving it into Applications on first launch (FR-078).
enum AppLocation {
    /// True when the app should offer to move itself: not in an Applications folder, and not a
    /// development build run from Xcode's build folder.
    static func needsMove(_ bundle: URL) -> Bool {
        let path = bundle.standardizedFileURL.path
        if path.hasPrefix("/Applications/") || path.contains("/Applications/") { return false }
        if path.contains("/DerivedData/") || path.contains("/Build/Products/") { return false }
        return true
    }

    /// Copies (from a disk image) or moves (from Downloads) the app into /Applications, replacing
    /// an older copy, and opens the new one. Returns false if the Owner declined.
    @MainActor
    static func offerMove() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move Latchkey to the Applications folder?"
        alert.informativeText =
            "Latchkey runs in the background and starts at login, so it needs to live in Applications."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Quit")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let source = Bundle.main.bundleURL
        let dest = URL(fileURLWithPath: "/Applications").appending(path: source.lastPathComponent)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            if fm.isWritableFile(atPath: source.deletingLastPathComponent().path) {
                try fm.moveItem(at: source, to: dest)
            } else {
                try fm.copyItem(at: source, to: dest)  // read-only, e.g. the disk image
            }
        } catch {
            let fail = NSAlert(error: error)
            fail.messageText = "Latchkey couldn't be moved. Drag it into the Applications folder yourself."
            fail.runModal()
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
        return true
    }
}

/// Watches the app bundle. When the Owner moves Latchkey to the Trash, the app uninstalls itself
/// cleanly (FR-077): see AppModel.uninstall.
final class TrashWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private let fd: Int32

    init?(bundle: URL, onTrashed: @escaping @MainActor () -> Void) {
        fd = open(bundle.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.rename, .delete], queue: .main)
        src.setEventHandler { [fd] in
            if Self.isInTrash(Self.currentPath(fd) ?? "") {
                MainActor.assumeIsolated { onTrashed() }
            }
        }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }

    /// The path a file descriptor points at now (it follows renames).
    static func currentPath(_ fd: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) != -1 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }
}

/// What uninstalling removes. Paths are injectable for tests.
struct LocalData {
    var supportDirectory = URL.applicationSupportDirectory.appending(path: "Latchkey", directoryHint: .isDirectory)
    var defaultsDomain = HelperIdentity.appBundleID
    var defaults = UserDefaults.standard
    /// Folders macOS creates for the app by itself: network cache, cookies, saved window state.
    var systemFolders: [URL] = {
        let library = URL.libraryDirectory
        let id = HelperIdentity.appBundleID
        return [
            library.appending(path: "Caches/\(id)"),
            library.appending(path: "HTTPStorages/\(id)"),
            library.appending(path: "HTTPStorages/\(id).binarycookies"),
            library.appending(path: "Saved Application State/\(id).savedState"),
        ]
    }()

    /// Deletes the device key, settings, the activity log, and the app's system folders.
    func remove() {
        DeviceIdentity.delete()
        try? FileManager.default.removeItem(at: supportDirectory)
        for folder in systemFolders { try? FileManager.default.removeItem(at: folder) }
        defaults.removePersistentDomain(forName: defaultsDomain)
        defaults.synchronize()
    }
}

enum BackgroundItems {
    /// Removes the login item and the helper's launchd registration.
    @MainActor
    static func unregisterAll() async {
        try? await SMAppService.daemon(plistName: HelperIdentity.plistName).unregister()
        try? await SMAppService.mainApp.unregister()
    }
}
