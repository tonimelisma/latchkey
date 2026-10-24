import AppKit
import SwiftUI

@main
struct LatchkeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            HStack(spacing: 1) {
                Image(systemName: delegate.model.menuIcon)
                if delegate.model.busy > 0 {
                    Image(systemName: "circle.fill").font(.system(size: 5))  // working (FR-132)
                }
            }
            .accessibilityLabel(
                "Latchkey: \(delegate.model.statusLine)\(delegate.model.busy > 0 ? ", working" : "")")
        }
        Window("Latchkey Activity", id: "activity") {
            ActivityView(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let presence = WindowPresence()
    private var terminateSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }  // unit tests
        quitCleanlyOnSIGTERM()
        model.start()
    }

    /// The installer (macos/scripts/install.sh) quits the app with SIGTERM; quit as if from the
    /// menu, so the relay is told and sleep is restored.
    private func quitCleanlyOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminateSignal = source
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(model.open)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Shows Latchkey in the Dock and in Cmd-Tab while one of its windows is open, and goes back to
/// menu bar only when the last one closes (the usual pattern for menu bar apps; FR-079).
@MainActor
final class WindowPresence {
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification,
        ] {
            observers.append(
                nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let closing = name == NSWindow.willCloseNotification ? note.object as? NSWindow : nil
                    MainActor.assumeIsolated { self?.update(closing: closing) }
                })
        }
    }

    private func update(closing: NSWindow?) {
        let open = NSApp.windows.contains {
            $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel)
        }
        let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if open { NSApp.activate() }
    }
}
