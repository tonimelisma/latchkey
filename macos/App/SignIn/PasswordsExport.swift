import AppKit
import ApplicationServices

/// The one-touch export (spec 013 FR-1301, FR-1306; plan D3): when the Owner clicks Export,
/// Latchkey opens Passwords and works its export through Accessibility (Passwords can't be
/// scripted); the Owner only approves with Touch ID or the Mac's password. The file is saved in
/// Latchkey's import folder, where `SignInImport` takes it in. Only while the Mac is unlocked,
/// and only after the Owner's click. English menu and button titles (Toni's Mac).
@MainActor
enum PasswordsExport {
    static let bundleID = "com.apple.Passwords"
    static let app = URL(fileURLWithPath: "/System/Applications/Passwords.app")

    enum Outcome: Equatable {
        case saved
        /// Accessibility isn't allowed: the Owner exports by hand into the folder.
        case byHand
        case stopped(String)
    }

    static var running = false

    /// Runs the export; how it ended. `approve`: how long the Owner has for Touch ID.
    static func run(into folder: URL = SignInImport.folder, approve: Duration = .seconds(120)) async -> Outcome {
        guard !running else { return .stopped("an export is already running") }
        running = true
        defer { running = false }
        guard AXIsProcessTrusted() else { return .byHand }
        guard !SystemScreen().isLocked() else { return .stopped("the Mac is locked") }
        try? SignInImport.prepare(folder)
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true  // the Owner clicked Export: Passwords comes forward for them (FR-1301)
        guard let opened = try? await NSWorkspace.shared.openApplication(at: app, configuration: config) else {
            return .stopped("Passwords didn't open")
        }
        let pid = opened.processIdentifier
        let ax = AXUIElementCreateApplication(pid)
        let outcome = await steps(ax, pid: pid, folder: folder, approve: approve)
        if outcome == .saved, !wasRunning { opened.terminate() }
        EventLog.shared.record(.app, "Passwords export: \(outcome)", error: outcome != .saved)
        return outcome
    }

    private static func steps(_ ax: AXUIElement, pid: pid_t, folder: URL, approve: Duration) async -> Outcome {
        // 1. The menu item is enabled once Passwords is unlocked (the Owner's Touch ID).
        guard
            let item = await waitFor(
                approve,
                {
                    menuItem(ax, menu: "File", prefix: "Export All Passwords").flatMap { enabled($0) ? $0 : nil }
                })
        else { return .stopped("Passwords wasn't unlocked within \(approve.components.seconds / 60) minutes") }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        // 2. The confirmation: Export Passwords.
        guard let export = await waitFor(.seconds(10), { button(ax, prefix: "Export") }) else {
            return .stopped("Passwords' export confirmation didn't show")
        }
        AXUIElementPerformAction(export, kAXPressAction as CFString)
        // 3. The save panel (macOS may ask for the Owner's approval first).
        guard let name = await waitFor(approve, { saveName(ax) }) else {
            return .stopped("Passwords' save panel didn't show")
        }
        let file = "Passwords-\(UUID().uuidString.prefix(8)).csv"
        AXUIElementSetAttributeValue(name, kAXValueAttribute as CFString, file as CFString)
        // Go to Latchkey's folder: Command-Shift-G opens a field of its own (a new element, told
        // apart with CFEqual: Accessibility hands out a new reference on every look), the
        // folder's path, Return. Anything unexpected cancels the panel: nothing is saved.
        let before = fields(ax)
        key(pid, 5, flags: [.maskCommand, .maskShift])  // G
        guard
            let goTo = await waitFor(
                .seconds(5),
                {
                    fields(ax).first { f in !CFEqual(f, name) && !before.contains { CFEqual($0, f) } }
                })
        else { return cancel(ax, "the save panel's Go to Folder didn't open") }
        AXUIElementSetAttributeValue(goTo, kAXValueAttribute as CFString, folder.path as CFString)
        try? await Task.sleep(for: .milliseconds(400))
        key(pid, 36)  // Return: goes to the folder
        // The Go to field closes and the name is still Latchkey's, or nothing is saved.
        guard
            await waitFor(
                .seconds(5),
                { () -> Bool? in
                    fields(ax).contains { CFEqual($0, goTo) } ? nil : true
                }) == true,
            let named = saveName(ax), (value(named, kAXValueAttribute) as? String) == file
        else { return cancel(ax, "the save panel didn't go to Latchkey's folder") }
        guard let save = await waitFor(.seconds(5), { button(ax, prefix: "Save") }) else {
            return cancel(ax, "the save panel's Save button wasn't found")
        }
        AXUIElementPerformAction(save, kAXPressAction as CFString)
        let target = folder.appending(path: file)
        let landed = await waitFor(.seconds(15)) { () -> Bool? in
            // Taken in (and deleted) by the import already, or still there to take.
            FileManager.default.fileExists(atPath: target.path) || SignInWatcher.shared.lastTaken == file ? true : nil
        }
        if landed == true { return .saved }
        // Saved somewhere else after all: find the file by its name and wipe it.
        let wiped = wipeStray(file)
        return .stopped(
            "the file didn't arrive in Latchkey's folder"
                + (wiped ? " (it was saved elsewhere and is now deleted)" : ""))
    }

    /// Presses the panel's Cancel, so nothing is saved; the reason.
    private static func cancel(_ ax: AXUIElement, _ why: String) -> Outcome {
        if let c = button(ax, prefix: "Cancel") { AXUIElementPerformAction(c, kAXPressAction as CFString) }
        return .stopped(why)
    }

    /// Looks for an export by its unique name where a save panel may have put it (the home
    /// folder, Desktop, Documents, Downloads, iCloud Drive, two levels down) and wipes it.
    static func wipeStray(_ name: String, home: URL = .homeDirectory) -> Bool {
        let places = ["", "Desktop", "Documents", "Downloads", "Library/Mobile Documents/com~apple~CloudDocs"]
        var found = false
        for place in places {
            let root = place.isEmpty ? home : home.appending(path: place)
            guard
                let walk = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            while let url = walk.nextObject() as? URL {
                if walk.level > 2 { walk.skipDescendants() }
                if url.lastPathComponent == name {
                    SignInImport.wipe(url)
                    found = true
                }
            }
        }
        return found
    }

    // MARK: Accessibility

    private static func waitFor<T>(_ limit: Duration, _ look: () -> T?) async -> T? {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let found = look() { return found }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private static func value(_ e: AXUIElement, _ attribute: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success ? v : nil
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        (value(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func title(_ e: AXUIElement) -> String { (value(e, kAXTitleAttribute) as? String) ?? "" }
    private static func role(_ e: AXUIElement) -> String { (value(e, kAXRoleAttribute) as? String) ?? "" }
    private static func enabled(_ e: AXUIElement) -> Bool { (value(e, kAXEnabledAttribute) as? Bool) ?? false }

    private static func menuItem(_ ax: AXUIElement, menu: String, prefix: String) -> AXUIElement? {
        guard let bar = value(ax, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        for top in children(bar as! AXUIElement) where title(top) == menu {
            for list in children(top) {
                if let hit = children(list).first(where: { title($0).hasPrefix(prefix) }) { return hit }
            }
        }
        return nil
    }

    /// Every element under the app's windows (sheets included), breadth first, at most 4,000.
    private static func everything(_ ax: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var queue = (value(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        while !queue.isEmpty, out.count < 4000 {
            let e = queue.removeFirst()
            out.append(e)
            queue.append(contentsOf: children(e))
        }
        return out
    }

    private static func button(_ ax: AXUIElement, prefix: String) -> AXUIElement? {
        everything(ax).first { role($0) == kAXButtonRole && title($0).hasPrefix(prefix) && enabled($0) }
    }

    private static func fields(_ ax: AXUIElement) -> [AXUIElement] {
        everything(ax).filter { [kAXTextFieldRole, kAXComboBoxRole].contains(role($0)) }
    }

    /// The save panel's name field ("Save As").
    private static func saveName(_ ax: AXUIElement) -> AXUIElement? {
        let all = everything(ax)
        guard all.contains(where: { role($0) == kAXButtonRole && title($0) == "Save" }) else { return nil }
        return all.first {
            role($0) == kAXTextFieldRole && (value($0, kAXIdentifierAttribute) as? String) == "saveAsNameTextField"
        }
            ?? all.first { role($0) == kAXTextFieldRole }
    }

    /// A key press sent to Passwords alone.
    private static func key(_ pid: pid_t, _ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.postToPid(pid)
        }
    }
}
