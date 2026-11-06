// The helpers RemindersWindow uses from the rest of the app, copied so the harness compiles
// without the Computer capability (AppWindowReader.string, SystemScreen.isLocked; keep them the
// same as in App/Computer).
import AppKit
import ApplicationServices

enum AppWindowReader {
    static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
}

struct SystemScreen {
    func isLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
            || (session[kCGSessionOnConsoleKey as String] as? Bool) == false
    }
}
