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
    /// The reference of the nearest listed element this one is in.
    var parent: String? = nil
}

/// Where an app's keyboard focus is, against the element Claude meant (FR-511).
enum FocusCheck: Sendable, Equatable {
    case inside
    /// The focus is on something else, described ("AXPopUpButton \"Country\""), or nothing.
    case elsewhere(String)
}

struct AppControl: Sendable {
    var find: @Sendable (String) -> AppTarget?
    var elements: @Sendable (AppTarget) -> AppListing
    var press: @Sendable (AppElement) -> Bool
    /// Asks for the keyboard focus; macOS answers yes even when the element can't take it (a
    /// web page's text, a frame's button: FormLab check 2026-11-03), so `focusCheck` decides.
    var focus: @Sendable (AppElement) -> Bool
    var poster: @Sendable (AppTarget) -> any InputPoster
    var picture: @Sendable (AppTarget) async throws -> PreparedImage
    /// Whether the app's keyboard focus is on the element or inside it (FR-511).
    var focusCheck: @Sendable (AppTarget, AppElement) -> FocusCheck = { _, _ in .inside }
    /// What has the app's keyboard focus, described; nil when nothing does.
    var focused: @Sendable (AppTarget) -> String? = { _ in nil }
    /// The element's value now.
    var value: @Sendable (AppElement) -> String? = { $0.value }

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
        picture: { try await AppWindowReader.picture(of: $0.pid) },
        focusCheck: { t, e in
            guard let el = e.element else { return .elsewhere("nothing") }
            let app = AXUIElementCreateApplication(t.pid)
            guard let f = AppWindowReader.focusedElement(app) else { return .elsewhere("nothing") }
            var current: AXUIElement? = f
            for _ in 0..<40 {
                guard let c = current else { break }
                if CFEqual(c, el) { return .inside }
                current = AppWindowReader.parent(c)
            }
            return .elsewhere(AppWindowReader.describe(f))
        },
        focused: { t in
            AppWindowReader.focusedElement(AXUIElementCreateApplication(t.pid)).map(AppWindowReader.describe)
        },
        value: { e in e.element.flatMap { AppWindowReader.string($0, kAXValueAttribute) } })

    /// Any copy of Latchkey (installed, test build, helper), by its bundle ID or bundle path.
    static func isLatchkey(_ app: NSRunningApplication) -> Bool {
        let id = app.bundleIdentifier ?? ""
        // The release ID is the start of the development one and of both helpers'.
        if id == Bundle.main.bundleIdentifier || id.hasPrefix(AppIdentity.release.bundleID) { return true }
        return app.bundleURL?.lastPathComponent.lowercased().hasPrefix("latchkey") == true
    }

    /// The last listing of each app's window, so a reference stays the element Claude saw.
    static let refs = Locked<[pid_t: AppListing]>([:])
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
    /// Listed at most, and looked at at most, per look (FR-512).
    static let maxElements = 2000
    static let maxVisited = 20_000
    static let maxDepth = 40

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

    static func elements(of pid: pid_t) -> AppListing {
        guard let w = window(of: pid) else { return AppListing(items: []) }
        var walk = Walk()
        walk.visit(w, depth: 0, parent: nil)
        return AppListing(items: walk.out, cut: walk.cut)
    }

    static func focusedElement(_ app: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(app, 3)
        var f: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f,
            CFGetTypeID(f) == AXUIElementGetTypeID()
        else { return nil }
        return (f as! AXUIElement)
    }

    static func parent(_ e: AXUIElement) -> AXUIElement? {
        var p: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &p) == .success, let p,
            CFGetTypeID(p) == AXUIElementGetTypeID()
        else { return nil }
        return (p as! AXUIElement)
    }

    /// `AXPopUpButton "Country"`, with its value when it has one.
    static func describe(_ e: AXUIElement) -> String {
        let role = string(e, kAXRoleAttribute) ?? "an element"
        var text = "\(role) \"\(label(e))\""
        if let v = string(e, kAXValueAttribute), !v.isEmpty { text += " (value: \(v.prefix(80)))" }
        return text
    }

    private static let acting: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXComboBox", "AXLink", "AXSlider", "AXSearchField", "AXCell", "AXRow", "AXTab",
    ]

    private static func label(_ e: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].lazy.compactMap { string(e, $0) }
            .first { !$0.isEmpty } ?? ""
    }

    /// Each element once: a table's cells are its rows' children and its columns' too, and its
    /// header's (FormLab check 2026-11-03), which filled the old 300 places with copies.
    private struct Walk {
        var out: [AppElement] = []
        var seen: [Int: [AXUIElement]] = [:]
        var visited = 0
        var cut = false

        mutating func visit(_ e: AXUIElement, depth: Int, parent: String?) {
            guard out.count < maxElements, visited < maxVisited, depth < maxDepth else {
                cut = true
                return
            }
            let hash = Int(bitPattern: UInt(CFHash(e)))
            if seen[hash]?.contains(where: { CFEqual($0, e) }) == true { return }
            seen[hash, default: []].append(e)
            visited += 1
            let role = string(e, kAXRoleAttribute) ?? ""
            let label = AppWindowReader.label(e)
            let value = string(e, kAXValueAttribute)
            var here = parent
            if acting.contains(role) || !label.isEmpty || !(value ?? "").isEmpty {
                let ref = "e\(out.count + 1)"
                out.append(
                    AppElement(
                        ref: ref, role: role, label: label, value: value.map { String($0.prefix(200)) }, element: e,
                        parent: parent))
                here = ref
            }
            var children: AnyObject?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) == .success,
                let list = children as? [AXUIElement]
            {
                for c in list { visit(c, depth: depth + 1, parent: here) }
            }
        }
    }

    static func string(_ e: AXUIElement, _ attribute: String) -> String? {
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
