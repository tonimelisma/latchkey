// Prints the Mac's screen state as one word, for state-check.sh: lid_closed (lid shut, session
// still unlocked: macOS keeps drawing the screen for a few minutes after the last activity),
// lid_closed_locked (lid shut and locked), screen_asleep (lid open, main display off), locked
// (display on, session locked), or unlocked. Uses the same calls as the app's ScreenCheck
// (App/Computer/Screen.swift).
import CoreGraphics
import Foundation
import IOKit

func lidClosed() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    defer { IOObjectRelease(service) }
    let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
    return (value?.takeRetainedValue() as? Bool) == true
}

func locked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
    return (session["CGSSessionScreenIsLocked"] as? Bool) == true
        || (session[kCGSessionOnConsoleKey as String] as? Bool) == false
}

if lidClosed() {
    print(locked() ? "lid_closed_locked" : "lid_closed")
} else if locked() {
    // Locked first: a display asleep after the lock is still locked (2026-11-03, a check called a
    // locked Mac "screen asleep", and a send started just before the lock froze Mail).
    print("locked")
} else if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
    print("screen_asleep")
} else {
    print("unlocked")
}
