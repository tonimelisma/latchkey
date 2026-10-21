import Foundation
import Sparkle

/// Signed updates with Sparkle 2 (FR-072). The updater runs only when the build carries an
/// EdDSA public key, so a build without one never offers a broken update check.
@MainActor
final class Updates {
    private let controller: SPUStandardUpdaterController?

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        controller =
            key.isEmpty
            ? nil : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var available: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
