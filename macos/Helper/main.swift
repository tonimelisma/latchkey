import Foundation

// The privileged helper (plan D7). It runs as root under launchd and does only this: turn the
// system SleepDisabled setting on or off for the Latchkey app, and restore sleep whenever the
// app is gone.

final class SleepSetting: NSObject, HelperProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.melisma.latchkey.helper.pmset")

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
    private var everConnected = false

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // Only the Latchkey app signed by the same team may connect.
        guard let req = CodeSigning.requirement(identifier: HelperIdentity.appBundleID) else { return false }
        c.setCodeSigningRequirement(req)
        c.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        c.exportedObject = setting
        c.invalidationHandler = { [weak self] in self?.clientLeft() }
        lock.lock()
        clients += 1
        everConnected = true
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

    /// At startup (for example after a reboot), restore sleep unless the app connects within 60 s.
    func restoreIfAppAbsent() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [self] in
            lock.lock()
            let absent = !everConnected
            lock.unlock()
            if absent { setting.restore() }
        }
    }
}

let delegate = Listener()
let listener = NSXPCListener(machServiceName: HelperIdentity.machService)
listener.delegate = delegate
delegate.restoreIfAppAbsent()
listener.resume()
RunLoop.main.run()
