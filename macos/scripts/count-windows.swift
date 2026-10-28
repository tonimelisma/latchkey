// Prints how many ordinary windows the installed Latchkey app has on screen (menu bar items
// excluded), for install.sh's check that a set-up Mac shows none (spec 001 FR-622). System Events
// misses SwiftUI windows; the window server's own list doesn't.
import CoreGraphics
import Foundation

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let mine = windows.filter {
    ($0[kCGWindowOwnerName as String] as? String) == "Latchkey" && ($0[kCGWindowLayer as String] as? Int) == 0
}
print(mine.count)
