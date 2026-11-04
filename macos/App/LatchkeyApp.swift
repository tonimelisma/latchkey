import AppKit
import SwiftUI
import UserNotifications

@main
struct LatchkeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            let icon = delegate.model.icon
            HStack(spacing: 1) {
                Image(systemName: icon.symbol)
                if let mark = icon.mark {  // FR-600; the working dot is spec 002 FR-132
                    Image(systemName: mark).font(.system(size: mark == "circle.fill" ? 5 : 7, weight: .bold))
                }
            }
            .accessibilityLabel(icon.spoken)
        }
        Window("Latchkey Activity", id: "activity") {
            ActivityView(model: delegate.model)
        }
        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    private let presence = WindowPresence()
    private var terminateSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }  // unit tests
        // Alone, as nearly always: start at once, before any link the app was opened with arrives.
        guard SingleCopy.others().isEmpty else {
            Task {
                // Before anything is touched: no connection, no keep-awake, no quit steps (FR-207).
                if await SingleCopy.anotherStays() {
                    AppModel.log.notice("Another copy of Latchkey is running; this one quits")
                    exit(0)
                }
                begin()
            }
            return
        }
        begin()
    }

    private func begin() {
        quitCleanlyOnSIGTERM()
        UNUserNotificationCenter.current().delegate = self
        model.start()
    }

    /// A click on "… is off" opens setup at what's missing (FR-626); other notices just bring
    /// the app forward, as before.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.content.categoryIdentifier == PermissionLoss.category else { return }
        await MainActor.run { model.showSetup() }
    }

    /// The installer (macos/scripts/install.sh) quits the app with SIGTERM; quit as if from the
    /// menu, so the relay is told and sleep is restored.
    private func quitCleanlyOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            EventLog.shared.record(.app, "SIGTERM: quitting")
            // Not from inside this main-queue block: terminate's wait for the shutdown would run
            // nested in it, and the main queue (which the shutdown needs) would never run again.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
        source.resume()
        terminateSignal = source
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(model.open)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Names the calls running, which the shutdown records as cut off (FR-666).
        EventLog.shared.record(.app, model.inFlight.quitLine)
        // Quit within 6 s even if a step hangs (Constitution II); the helper restores sleep by
        // itself when the app goes away.
        let done = QuitOnce { sender.reply(toApplicationShouldTerminate: true) }
        Task {
            await model.shutdown()
            EventLog.shared.record(.app, "Quit: the relay was told and sleep restored")
            done.fire()
        }
        Task {
            try? await Task.sleep(for: .seconds(6))
            EventLog.shared.record(.app, "Quit: shutdown took too long; quitting anyway", error: true)
            done.fire()
        }
        return .terminateLater
    }
}

/// Runs its action once, whichever caller comes first (quit finished, or the deadline).
@MainActor
final class QuitOnce {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func fire() {
        action?()
        action = nil
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
                    let key = name == NSWindow.didBecomeKeyNotification ? note.object as? NSWindow : nil
                    MainActor.assumeIsolated {
                        // With "Show All Activity chosen", tells a window slow to open from one that
                        // opened behind another app's (2026-10-27: about 10 s, not seen again).
                        if key?.title == "Latchkey Activity" {
                            Diagnostics.activity.notice("Activity window in front (app active: \(NSApp.isActive))")
                        }
                        self?.update(closing: closing)
                    }
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
