import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// A display, in global screen points (origin at the top left of the main display) and pixels.
struct DisplayInfo: Sendable, Equatable {
    var id: CGDirectDisplayID
    var bounds: CGRect
    var pixelWidth: Int
    var pixelHeight: Int
}

/// Screenshot pixels ↔ screen points (spec 006 plan D3). Each display's screenshot size is fixed
/// (longest side at most 1,568 pixels), so coordinates mean the same with or without a fresh
/// screenshot.
enum ScreenGeometry {
    static let maxSide = 1568

    static func imageSize(_ d: DisplayInfo) -> (Int, Int) {
        let longest = max(d.pixelWidth, d.pixelHeight)
        guard longest > maxSide else { return (d.pixelWidth, d.pixelHeight) }
        let scale = Double(maxSide) / Double(longest)
        return (Int((Double(d.pixelWidth) * scale).rounded()), Int((Double(d.pixelHeight) * scale).rounded()))
    }

    static func point(x: Double, y: Double, on d: DisplayInfo) -> CGPoint {
        let (w, h) = imageSize(d)
        return CGPoint(
            x: d.bounds.minX + x * d.bounds.width / Double(w), y: d.bounds.minY + y * d.bounds.height / Double(h))
    }

    /// The screenshot pixel of a screen point, or nil when the point is no real position (NaN,
    /// infinite, or far off any screen). Points come from other apps' Accessibility frames, which
    /// they choose; converting such values with Int(_:) crashed the app (security scan, 2026-10-24).
    static func pixel(of p: CGPoint, on d: DisplayInfo) -> (Int, Int)? {
        let (w, h) = imageSize(d)
        let x = ((p.x - d.bounds.minX) * Double(w) / d.bounds.width).rounded()
        let y = ((p.y - d.bounds.minY) * Double(h) / d.bounds.height).rounded()
        let far = 1_000_000.0
        guard x.isFinite, y.isFinite, abs(x) <= far, abs(y) <= far else { return nil }
        return (Int(x), Int(y))
    }
}

/// What the screen is doing (plan D2). A protocol so tests can play every state.
protocol ScreenStateSource: Sendable {
    func displays() -> [DisplayInfo]
    func isLocked() -> Bool
    func isAsleep(_ id: CGDirectDisplayID) -> Bool
}

struct SystemScreen: ScreenStateSource {
    func displays() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let main = CGMainDisplayID()
        return (ids.filter { $0 == main } + ids.filter { $0 != main }).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            return DisplayInfo(
                id: id, bounds: CGDisplayBounds(id), pixelWidth: mode?.pixelWidth ?? CGDisplayPixelsWide(id),
                pixelHeight: mode?.pixelHeight ?? CGDisplayPixelsHigh(id))
        }
    }

    func isLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
            || (session[kCGSessionOnConsoleKey as String] as? Bool) == false
    }

    func isAsleep(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsAsleep(id) != 0 }
}

/// Plain reasons the screen can't be used now (FR-504); nil when it can.
/// A sleeping display is never woken (Toni, 2026-11-02: Latchkey doesn't get around the Mac's
/// idle lock, lid open or closed; waking it reset the idle time, so Claude's looks could keep an
/// idle Mac from locking).
enum ScreenCheck {
    static let stillWorks = "Files, shell, Notes, Messages, and the browser still work."

    static func problem(_ s: any ScreenStateSource) async -> String? {
        let displays = s.displays()
        guard let main = displays.first else {
            return
                "The Mac has no screen on right now (the lid is closed and no monitor is connected), so Claude can't see or use the screen. \(stillWorks)"
        }
        if s.isAsleep(main.id) {
            return
                "The Mac's display is asleep because no one has used the Mac for a while, so Claude can't see the screen; Latchkey doesn't wake it, so the Mac locks itself as usual. \(stillWorks)"
        }
        if s.isLocked() {
            return
                "The Mac is locked, so Claude can't see or use the screen until someone unlocks it at the Mac. Latchkey never types the Mac's password. \(stillWorks)"
        }
        return nil
    }
}

/// Key names Claude uses (`cmd+shift+4`, `return`) to virtual key codes and modifier flags.
enum KeyNames {
    struct Unknown: Error { var name: String }

    static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "shift": .maskShift, "alt": .maskAlternate,
        "option": .maskAlternate,
        "opt": .maskAlternate, "ctrl": .maskControl, "control": .maskControl, "fn": .maskSecondaryFn,
    ]

    static let codes: [String: CGKeyCode] = {
        var c: [String: CGKeyCode] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
            "v": 0x09,
            "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13,
            "3": 0x14,
            "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D,
            "]": 0x1E,
            "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28,
            ";": 0x29,
            "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
            "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33,
            "escape": 0x35,
            "esc": 0x35, "forwarddelete": 0x75, "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        ]
        let f: [CGKeyCode] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
        for (i, code) in f.enumerated() { c["f\(i + 1)"] = code }
        return c
    }()

    static func parse(_ keys: String) throws -> (code: CGKeyCode, flags: CGEventFlags) {
        var flags: CGEventFlags = []
        var code: CGKeyCode?
        for part in keys.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let m = modifiers[part] {
                flags.insert(m)
            } else if let c = codes[part] {
                code = c
            } else {
                throw Unknown(name: part)
            }
        }
        guard let code else { throw Unknown(name: keys) }
        return (code, flags)
    }
}
