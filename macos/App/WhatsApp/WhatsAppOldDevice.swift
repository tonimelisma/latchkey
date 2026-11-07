import Foundation
import WebKit

/// Latchkey's own WhatsApp device was withdrawn (Toni, 2026-11-04, plan D4): at the first start
/// without it, what it stored is deleted, once.
@MainActor
enum WhatsAppOldDevice {
    static let storeID = UUID(uuidString: "6F1C2A4E-8B3D-4E51-9A7C-1D2E3F405162")!
    static let doneKey = "whatsappOldDeviceRemoved"

    static func removeOnce(_ defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: doneKey) else { return }
        // WebKit must be set up (a web view made) before a store can be removed (0.8.101 crashed).
        let starter = WKWebView(frame: .zero)
        try? await WKWebsiteDataStore.remove(forIdentifier: storeID)
        _ = starter
        defaults.removeObject(forKey: "whatsappLinked")
        defaults.set(true, forKey: doneKey)
        EventLog.shared.record(.app, "WhatsApp: deleted what Latchkey's own WhatsApp device stored (withdrawn)")
    }
}
