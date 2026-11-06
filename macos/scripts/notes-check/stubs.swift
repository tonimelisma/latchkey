// The few helpers Notes' window code uses from the rest of the app, copied so the check
// compiles without the whole app (keep them the same as there: AppWindowReader.string in
// App/Computer/AppControl.swift, Permissions.notesApp, SystemScreen.isLocked in
// App/Computer/Screen.swift, the script runner in App/ScriptRunner.swift reduced to osascript).
import AppKit
import ApplicationServices
import Foundation

enum AppWindowReader {
    static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
}

enum Permissions {
    static let notesApp = "com.apple.Notes"
}

struct SystemScreen {
    func isLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

enum ScriptError: Error, Equatable {
    case timedOut
    case notAllowed
    case failed(String)
}

protocol ScriptRunner: Sendable {
    func run(_ script: String, _ args: [String]) async throws -> String
}

struct OSAScriptRunner: ScriptRunner {
    var app: String?

    func run(_ script: String, _ args: [String]) async throws -> String {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/osascript")
        p.arguments = script.split(separator: "\n", omittingEmptySubsequences: false).flatMap { ["-e", String($0)] }
            + ["--"] + args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw ScriptError.failed(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        return text.trimmingCharacters(in: .newlines)
    }
}

/// NotesWindowRoute.swift extends this; the check needs none of the rest.
enum NotesCapability {}
