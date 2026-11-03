import AppKit
import ApplicationServices
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Screenshots with ScreenCaptureKit (plan D3, D7); needs the Screen Recording permission.
enum ScreenCapture {
    struct Failure: Error { var message: String }

    /// ScreenCaptureKit's refusal: the Owner declined, or macOS's question is waiting.
    static func declined(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == SCStreamErrorDomain && e.code == SCStreamError.Code.userDeclined.rawValue
    }

    static func display(_ d: DisplayInfo) async throws -> PreparedImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == d.id }) else {
            throw Failure(message: "That display isn't available to capture.")
        }
        let (w, h) = ScreenGeometry.imageSize(d)
        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
        return try jpeg(image)
    }

    /// One small screenshot, thrown away, so macOS's second question about direct screen access
    /// comes in setup rather than at Claude's first look (FR-623). True when it went through.
    static func confirm() async -> Bool {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
            let display = content.displays.first
        else { return false }
        let config = SCStreamConfiguration()
        config.width = 64
        config.height = 40
        let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
        return image != nil
    }

    /// The window of `bundleID` whose title is `title` (Claude's Safari tab).
    static func window(app bundleID: String, title: String) async throws -> PreparedImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard
            let window = content.windows.first(where: {
                $0.owningApplication?.bundleIdentifier == bundleID && $0.title == title
            })
                ?? content.windows.first(where: {
                    $0.owningApplication?.bundleIdentifier == bundleID && ($0.title ?? "").contains(title)
                })
        else {
            throw Failure(
                message: "Claude's Safari window isn't on screen (it may be minimized or behind a full-screen app).")
        }
        return try await self.window(window)
    }

    /// One window alone, also while other windows cover it.
    static func window(_ window: SCWindow) async throws -> PreparedImage {
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        let px = (window.frame.width * scale, window.frame.height * scale)
        let fit = min(1, Double(ScreenGeometry.maxSide) / max(px.0, px.1))
        let config = SCStreamConfiguration()
        config.width = Int(px.0 * fit)
        config.height = Int(px.1 * fit)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        return try jpeg(image)
    }

    /// Whether the Owner can see any of the window of `app` titled `title`: it is on screen, on
    /// this Space, and some of it isn't under another window (spec 005 FR-423). Sampled on a grid.
    static func windowVisible(app: String, title: String) -> Bool {
        let list =
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]) ?? []
        func rect(_ w: [String: Any]) -> CGRect? {
            guard let b = w[kCGWindowBounds as String] as? [String: Double] else { return nil }
            return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        }
        guard
            let i = list.firstIndex(where: {
                ($0[kCGWindowOwnerName as String] as? String) == app && ($0[kCGWindowLayer as String] as? Int) == 0
                    && ($0[kCGWindowName as String] as? String ?? "").contains(title)
            }), let target = rect(list[i])
        else { return false }
        let above = list[..<i].filter {
            ($0[kCGWindowLayer as String] as? Int ?? 0) >= 0 && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }.compactMap(rect)
        // NSScreen is bottom-left based; window bounds are top-left based.
        let top = NSScreen.screens.first?.frame.height ?? 0
        let screens = NSScreen.screens.map {
            CGRect(x: $0.frame.minX, y: top - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
        }
        let steps = 12
        for a in 0...steps {
            for b in 0...steps {
                let p = CGPoint(
                    x: target.minX + target.width * CGFloat(a) / CGFloat(steps),
                    y: target.minY + target.height * CGFloat(b) / CGFloat(steps))
                if screens.contains(where: { $0.contains(p) }), !above.contains(where: { $0.contains(p) }) {
                    return true
                }
            }
        }
        return false
    }

    private static func jpeg(_ image: CGImage) throws -> PreparedImage {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure(message: "The screenshot couldn't be encoded.")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure(message: "The screenshot couldn't be encoded.") }
        return PreparedImage(data: out as Data, mimeType: "image/jpeg")
    }
}

struct UIElementInfo: Sendable, Equatable {
    var role: String
    var label: String
    var value: String?
    /// In global screen points.
    var frame: CGRect
}

/// The front app's focused window through the Accessibility API (plan D3).
enum FrontWindow {
    static let maxElements = 300

    static func elements() -> [UIElementInfo] {
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var window: AnyObject?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &window) == .success,
            let window
        else { return [] }
        var out: [UIElementInfo] = []
        walk(window as! AXUIElement, depth: 0, into: &out)
        return out
    }

    private static func walk(_ e: AXUIElement, depth: Int, into out: inout [UIElementInfo]) {
        guard out.count < maxElements, depth < 15 else { return }
        let role = string(e, kAXRoleAttribute) ?? ""
        let label =
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].lazy.compactMap { string(e, $0) }
            .first { !$0.isEmpty } ?? ""
        let value = string(e, kAXValueAttribute)
        if let frame = frame(e), !label.isEmpty || !(value ?? "").isEmpty || role == kAXButtonRole as String {
            out.append(
                UIElementInfo(role: role, label: label, value: value.map { String($0.prefix(200)) }, frame: frame))
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

    private static func frame(_ e: AXUIElement) -> CGRect? {
        var pos: AnyObject?
        var size: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos) == .success,
            AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size) == .success
        else { return nil }
        // The front app answers these; anything but a point and a size is no frame (no force casts).
        guard let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else {
            return nil
        }
        return CGRect(origin: p, size: s)
    }
}
