import AppKit
import ApplicationServices

/// WhatsApp for Mac's window, the fallback for sending text to a person (spec 012 plan D3).
protocol WhatsAppWindowAPI: Sendable {
    /// Why the window can't be used now, or nil.
    func unusable() async -> String?
    /// Opens the chat with `number` holding `text` and presses Return in WhatsApp alone; throws
    /// `WhatsAppCapability.Problem` saying why when it couldn't.
    func send(number: String, text: String) async throws
    /// Whether WhatsApp for Mac is running (its database is current only then; FR-1222).
    func running() -> Bool
}

struct LiveWhatsAppWindow: WhatsAppWindowAPI {
    static let bundleID = "net.whatsapp.WhatsApp"

    func unusable() async -> String? {
        if SystemScreen().isLocked() { return "WhatsApp for Mac can't be used while the Mac is locked" }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil else {
            return "WhatsApp for Mac isn't installed"
        }
        guard AXIsProcessTrusted() else {
            return
                "Latchkey isn't allowed to control the Mac (System Settings → Privacy & Security → Accessibility), which WhatsApp for Mac needs"
        }
        return nil
    }

    func running() -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }

    func send(number: String, text: String) async throws { try await Self.send(number: number, text: text) }

    /// `whatsapp://send?phone=…&text=…` with the text encoded so that `+`, `&`, `=` and line breaks
    /// arrive as written.
    static func link(number: String, text: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        guard let t = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "whatsapp://send?phone=\(number.filter(\.isNumber))&text=\(t)")
    }

    /// Text compared without differences in spaces and line breaks (the field may wrap or trim).
    static func same(_ a: String, _ b: String) -> Bool {
        func squeeze(_ s: String) -> String {
            s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return squeeze(a) == squeeze(b)
    }

    @MainActor
    private static func send(number: String, text: String) async throws {
        guard let url = link(number: number, text: text) else {
            throw WhatsAppCapability.Problem("Nothing was sent: the text can't go into WhatsApp for Mac's link")
        }
        let before = NSWorkspace.shared.frontmostApplication
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.open(url, configuration: config)
        defer {
            if let before, before.bundleIdentifier != bundleID { before.activate() }
        }
        // Up to 10 s for WhatsApp to be in front with the chat open and the text in its field.
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(200))
            guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID,
                let shown = focusedText(app.processIdentifier), same(shown, text)
            else { continue }
            let source = CGEventSource(stateID: .privateState)
            for down in [true, false] {
                CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.postToPid(app.processIdentifier)
            }
            try await Task.sleep(for: .milliseconds(600))
            return
        }
        throw WhatsAppCapability.Problem(
            "Nothing was sent: WhatsApp for Mac didn't show the chat with the text within 10 seconds (is it logged in?)"
        )
    }

    /// The text in the focused field of the app with `pid`, through Accessibility.
    @MainActor
    private static func focusedText(_ pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXFocusedUIElement" as CFString, &focused) == .success,
            let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, "AXValue" as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}
