import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Computer control of one named app without the front or the pointer (spec 006 FR-510, Toni
/// 2026-11-02: "Background first"): its front window's buttons and fields through Accessibility,
/// pressed there; keys sent to that app alone (`CGEvent.postToPid`); a picture of just that
/// window, which ScreenCaptureKit takes even while other windows cover it. Checked live
/// 2026-11-02 with Calculator behind other windows: presses and keys worked, the picture was
/// whole, the pointer and the front app never changed. A click sent to an app alone does nothing,
/// so clicks at a point still use the pointer.
struct AppTarget: Sendable, Equatable {
    var name: String
    var pid: pid_t
}

/// One element of an app's window, with the handle to act on it.
struct AppElement: @unchecked Sendable {
    var ref: String
    var role: String
    var label: String
    var value: String?
    var element: AXUIElement?
}

struct AppControl: Sendable {
    var find: @Sendable (String) -> AppTarget?
    var elements: @Sendable (AppTarget) -> [AppElement]
    var press: @Sendable (AppElement) -> Bool
    var focus: @Sendable (AppElement) -> Bool
    var poster: @Sendable (AppTarget) -> any InputPoster
    var picture: @Sendable (AppTarget) async throws -> PreparedImage

    static let live = AppControl(
        find: { name in
            // Never Latchkey itself: its windows set what Claude may do (security review 2026-11-02).
            let apps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !AppControl.isLatchkey($0)
            }
            let wanted = name.lowercased()
            guard
                let app = apps.first(where: { ($0.localizedName ?? "").lowercased() == wanted })
                    ?? apps.first(where: { ($0.localizedName ?? "").lowercased().hasPrefix(wanted) })
            else { return nil }
            return AppTarget(name: app.localizedName ?? name, pid: app.processIdentifier)
        },
        elements: { AppWindowReader.elements(of: $0.pid) },
        press: { e in
            guard let el = e.element else { return false }
            return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
        },
        focus: { e in
            guard let el = e.element else { return false }
            return AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        },
        poster: { PidPoster(pid: $0.pid) },
        picture: { try await AppWindowReader.picture(of: $0.pid) })

    /// Any copy of Latchkey (installed, test build, helper), by its bundle ID or bundle path.
    static func isLatchkey(_ app: NSRunningApplication) -> Bool {
        let id = app.bundleIdentifier ?? ""
        // The release ID is the start of the development one and of both helpers'.
        if id == Bundle.main.bundleIdentifier || id.hasPrefix(AppIdentity.release.bundleID) { return true }
        return app.bundleURL?.lastPathComponent.lowercased().hasPrefix("latchkey") == true
    }

    /// The last listing of each app's window, so a reference stays the element Claude saw.
    static let refs = Locked<[pid_t: [String: AppElement]]>([:])
}

/// Key and text events to one process only; mouse events can't go this way.
struct PidPoster: InputPoster {
    var pid: pid_t

    func post(_ e: InputEvent) {
        let src = CGEventSource(stateID: .privateState)
        switch e {
        case .key(let code, let down, let flags):
            let event = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.postToPid(pid)
        case .text(let s):
            var units = Array(s.utf16)[...]
            while !units.isEmpty {
                let chunk = Array(units.prefix(16))
                units = units.dropFirst(chunk.count)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                    event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    event?.postToPid(pid)
                }
                usleep(15_000)
            }
        default:
            break
        }
    }
}

enum AppWindowReader {
    static let maxElements = 300

    /// The app's front window: its main or focused one, else its first.
    static func window(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3)
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var w: AnyObject?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &w) == .success, let w,
                CFGetTypeID(w) == AXUIElementGetTypeID()
            {
                return (w as! AXUIElement)
            }
        }
        var list: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list) == .success else { return nil }
        return (list as? [AXUIElement])?.first
    }

    static func elements(of pid: pid_t) -> [AppElement] {
        guard let w = window(of: pid) else { return [] }
        var out: [AppElement] = []
        walk(w, depth: 0, into: &out)
        return out
    }

    private static let acting: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXComboBox", "AXLink", "AXSlider", "AXSearchField", "AXCell", "AXRow", "AXTab",
    ]

    private static func walk(_ e: AXUIElement, depth: Int, into out: inout [AppElement]) {
        guard out.count < maxElements, depth < 15 else { return }
        let role = string(e, kAXRoleAttribute) ?? ""
        let label =
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].lazy.compactMap { string(e, $0) }
            .first { !$0.isEmpty } ?? ""
        let value = string(e, kAXValueAttribute)
        if acting.contains(role) || !label.isEmpty || !(value ?? "").isEmpty {
            out.append(
                AppElement(
                    ref: "e\(out.count + 1)", role: role, label: label, value: value.map { String($0.prefix(200)) },
                    element: e))
        }
        var children: AnyObject?
        if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) == .success,
            let list = children as? [AXUIElement]
        {
            for c in list { walk(c, depth: depth + 1, into: &out) }
        }
    }

    private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// A picture of the app's front window alone, covered or not.
    static func picture(of pid: pid_t) async throws -> PreparedImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let mine = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 40
        }
        // Front to back, as the window server lists them.
        let order =
            ((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? Int }
        guard
            let window = order.lazy.compactMap({ id in mine.first { Int($0.windowID) == id } }).first ?? mine.first
        else {
            throw ComputerCapability.Failure(
                message: "That app has no window on screen (it may be minimized, hidden, or on another desktop).")
        }
        return try await ScreenCapture.window(window)
    }
}
