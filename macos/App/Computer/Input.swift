import CoreGraphics
import Foundation

enum MouseButton: String, Sendable, Equatable { case left, right }

/// One synthetic input event, in global screen points.
enum InputEvent: Sendable, Equatable {
    case move(CGPoint)
    case down(MouseButton, CGPoint, Int)
    case up(MouseButton, CGPoint, Int)
    case dragTo(CGPoint)
    case scroll(dx: Int32, dy: Int32)
    case key(CGKeyCode, down: Bool, CGEventFlags)
    case text(String)
}

/// Sends input events (plan D4). A protocol so tests record instead of moving the pointer.
protocol InputPoster: Sendable {
    func post(_ e: InputEvent)
}

/// Quartz events to the system's event stream; needs the Accessibility permission.
struct QuartzPoster: InputPoster {
    func post(_ e: InputEvent) {
        let src = CGEventSource(stateID: .hidSystemState)
        switch e {
        case .move(let p):
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(
                tap: .cghidEventTap)
        case .down(let b, let p, let count), .up(let b, let p, let count):
            let isDown = if case .down = e { true } else { false }
            let type: CGEventType =
                b == .left ? (isDown ? .leftMouseDown : .leftMouseUp) : (isDown ? .rightMouseDown : .rightMouseUp)
            let ev = CGEvent(
                mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: b == .left ? .left : .right
            )
            ev?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            ev?.post(tap: .cghidEventTap)
        case .dragTo(let p):
            CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?
                .post(
                    tap: .cghidEventTap)
        case .scroll(let dx, let dy):
            CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?.post(
                tap: .cghidEventTap)
        case .key(let code, let down, let flags):
            let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            ev?.flags = flags
            ev?.post(tap: .cghidEventTap)
        case .text(let s):
            // Unicode text in chunks, so any language and emoji arrive as typed.
            let units = Array(s.utf16)
            for start in stride(from: 0, to: units.count, by: 16) {
                let chunk = Array(units[start..<min(start + 16, units.count)])
                for down in [true, false] {
                    let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                    ev?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    ev?.post(tap: .cghidEventTap)
                }
                usleep(8000)
            }
        }
        usleep(15000)  // give apps a moment between events
    }
}

/// Mouse and keyboard actions in screenshot pixels (plan D4).
struct ComputerActions: Sendable {
    struct Failure: Error { var message: String }

    let poster: any InputPoster
    let displays: [DisplayInfo]

    /// Displays are numbered from 1, the main display first.
    func display(_ n: Int) throws -> DisplayInfo {
        guard n >= 1, n <= displays.count else {
            throw Failure(message: "There's no display \(n); the Mac has \(displays.count).")
        }
        return displays[n - 1]
    }

    func move(x: Double, y: Double, display n: Int) throws {
        poster.post(.move(ScreenGeometry.point(x: x, y: y, on: try display(n))))
    }

    func click(x: Double, y: Double, button: MouseButton, count: Int, display n: Int) throws {
        let p = ScreenGeometry.point(x: x, y: y, on: try display(n))
        poster.post(.move(p))
        for i in 1...max(1, min(count, 3)) {
            poster.post(.down(button, p, i))
            poster.post(.up(button, p, i))
        }
    }

    func drag(from: (Double, Double), to: (Double, Double), display n: Int) throws {
        let d = try display(n)
        let a = ScreenGeometry.point(x: from.0, y: from.1, on: d)
        let b = ScreenGeometry.point(x: to.0, y: to.1, on: d)
        poster.post(.move(a))
        poster.post(.down(.left, a, 1))
        for step in 1...10 {
            let t = Double(step) / 10
            poster.post(.dragTo(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
        }
        poster.post(.up(.left, b, 1))
    }

    func scroll(x: Double, y: Double, direction: String, amount: Int, display n: Int) throws {
        poster.post(.move(ScreenGeometry.point(x: x, y: y, on: try display(n))))
        let a = Int32(max(1, min(amount, 50)))
        switch direction {
        case "up": poster.post(.scroll(dx: 0, dy: a))
        case "down": poster.post(.scroll(dx: 0, dy: -a))
        case "left": poster.post(.scroll(dx: a, dy: 0))
        case "right": poster.post(.scroll(dx: -a, dy: 0))
        default: throw Failure(message: "direction must be up, down, left, or right.")
        }
    }

    func type(_ text: String) { poster.post(.text(text)) }

    func key(_ keys: String) throws {
        let k: (code: CGKeyCode, flags: CGEventFlags)
        do { k = try KeyNames.parse(keys) } catch let u as KeyNames.Unknown {
            throw Failure(message: "Unknown key \(u.name). Use names like cmd+c, shift+tab, return, escape, up, f5.")
        }
        poster.post(.key(k.code, down: true, k.flags))
        poster.post(.key(k.code, down: false, k.flags))
    }
}
