// Prints, with the time, every change that would disturb someone using the Mac: the app in
// front, the window on top, a new window on screen, the pointer moving, and the clipboard
// changing. state-check.sh runs it next to a run so each group's disturbances can be read off.
// Window names need Screen Recording for the terminal; without it only the app is shown.
//
//   swift focus-watch.swift            runs until stopped
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
let clock = DateFormatter()
clock.dateFormat = "HH:mm:ss.SSS"
func say(_ s: String) { print("\(clock.string(from: Date())) \(s)") }

struct Win: Hashable {
    var id: Int
    var app: String
    var name: String
}

func windows() -> [Win] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    return ((list as? [[String: Any]]) ?? []).compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0,
            let id = w[kCGWindowNumber as String] as? Int,
            let app = w[kCGWindowOwnerName as String] as? String
        else { return nil }
        let bounds = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        // Tiny or invisible windows aren't seen by anyone.
        guard (bounds["Width"] ?? 0) > 40, (bounds["Height"] ?? 0) > 40,
            (w[kCGWindowAlpha as String] as? Double ?? 1) > 0
        else { return nil }
        return Win(id: id, app: app, name: w[kCGWindowName as String] as? String ?? "")
    }
}

var front = ""
var top = 0
var seen = Set(windows().map(\.id))
var pointer = NSEvent.mouseLocation
var pointerSaid = Date.distantPast
var clipboard = NSPasteboard.general.changeCount
say("watching")
while true {
    let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    if app != front {
        say("front: \(app)")
        front = app
    }
    let now = windows()
    if let first = now.first, first.id != top {
        say("top window: \(first.app) «\(first.name)»")
        top = first.id
    }
    for w in now where !seen.contains(w.id) { say("new window: \(w.app) «\(w.name)»") }
    seen = Set(now.map(\.id))
    let p = NSEvent.mouseLocation
    // At most once a second, so a person moving the pointer doesn't flood the log.
    if abs(p.x - pointer.x) + abs(p.y - pointer.y) > 2, Date().timeIntervalSince(pointerSaid) >= 1 {
        say("pointer: \(Int(p.x)),\(Int(p.y))")
        pointer = p
        pointerSaid = Date()
    }
    let c = NSPasteboard.general.changeCount
    if c != clipboard {
        say("clipboard changed")
        clipboard = c
    }
    // The run loop, not a sleep: NSWorkspace learns which app is in front from notifications
    // it receives there (with a sleep, the front app read at start never changed).
    RunLoop.main.run(until: Date() + 0.2)
}
