import AppKit
import SwiftUI

@main
struct LatchkeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            Image(systemName: delegate.model.menuIcon)
                .accessibilityLabel("Latchkey: \(delegate.model.statusLine)")
        }
        Window("Latchkey Activity", id: "activity") {
            ActivityView(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }  // unit tests
        model.start()
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
