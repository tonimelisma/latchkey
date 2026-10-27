import Foundation

// The privileged helper (plan D7). It runs as root under launchd and does only this: turn the
// system SleepDisabled setting on or off for the Latchkey app, and restore sleep whenever the
// app is gone.

final class SleepSetting: NSObject, HelperProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: AppIdentity.current.helperBundleID + ".pmset")

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool, String?) -> Void) {
        queue.async {
            let error = Self.pmset(["-a", "disablesleep", disabled ? "1" : "0"]).error
            reply(Self.current(), error)
        }
    }

    func readSleepDisabled(reply: @escaping @Sendable (Bool) -> Void) {
        queue.async { reply(Self.current()) }
    }

    func restore() {
        queue.sync { _ = Self.pmset(["-a", "disablesleep", "0"]) }
    }

    static func current() -> Bool { PmsetParser.sleepDisabled(pmset(["-g"]).output) }

    static func pmset(_ args: [String]) -> (output: String, error: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return ("", "\(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return (text, p.terminationStatus == 0 ? nil : text)
    }
}

final class Listener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let setting = SleepSetting()
    private let lock = NSLock()
    private var clients = 0
    /// Read once at start: the team comes from this program's file, and an install replaces that
    /// file under the running helper, after which reading it fails (UNIX error 2) and every app
    /// connection was refused (2026-10-26).
    private let requirement = CodeSigning.requirement(identifier: AppIdentity.current.bundleID)
    private let program = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
    private let started = FileStamp.of(Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0])

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // A newer helper was installed: end this old one so launchd starts the new program for
        // the app's next try (the app makes a new connection after a failed one).
        if let started, FileStamp.of(program) != started {
            setting.restore()
            DispatchQueue.main.async { exit(0) }
            return false
        }
        // Only the Latchkey app signed by the same team may connect.
        guard let req = requirement else { return false }
        c.setCodeSigningRequirement(req)
        c.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        c.exportedObject = setting
        c.invalidationHandler = { [weak self] in self?.clientLeft() }
        lock.lock()
        clients += 1
        lock.unlock()
        c.resume()
        return true
    }

    /// The app quit or crashed: restore normal sleep (FR-035).
    private func clientLeft() {
        lock.lock()
        clients -= 1
        let none = clients == 0
        lock.unlock()
        if none { setting.restore() }
    }

}

// Every start (at boot, or on demand) begins with normal sleep; the app turns keep-awake back on
// when it connects. So a setting left over from a crash or power loss never outlives the app,
// even if the app is deleted before it runs again.
let delegate = Listener()
delegate.setting.restore()
let listener = NSXPCListener(machServiceName: AppIdentity.current.machService)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
