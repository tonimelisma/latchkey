import Foundation

/// The names macOS knows a build of Latchkey by. The installed app is a Release build; Debug and
/// test builds are a different app in macOS's eyes (Toni, 2026-10-25), so a test copy never shares
/// the installed app's settings, Keychain items, privacy permissions, helper, or link handling.
/// (While both were one identity, a test erased the Owner's pairing twice, and a leftover Debug
/// build, which carries the debugging entitlement, could borrow the installed app's permissions.)
///
/// `project.yml` sets the same identifiers per configuration (`LATCHKEY_APP_ID`,
/// `LATCHKEY_URL_SCHEME`, `LATCHKEY_DISPLAY_NAME`); `IdentityTests` checks the two agree.
struct AppIdentity: Sendable, Equatable {
    /// The app's bundle identifier: also its settings domain, Keychain service, and log subsystem.
    let bundleID: String
    /// The link scheme this build registers with macOS.
    let urlScheme: String
    /// The folder in Application Support with the activity log.
    let supportFolderName: String

    var helperBundleID: String { bundleID + ".helper" }
    /// The helper's launchd label and Mach service name.
    var machService: String { helperBundleID }
    /// The helper's launchd plist inside the app, as `SMAppService` names it.
    var helperPlistName: String { helperBundleID + ".plist" }
    var keychainService: String { bundleID }
    var logSubsystem: String { bundleID }
    var defaultsDomain: String { bundleID }
    var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: supportFolderName, directoryHint: .isDirectory)
    }

    /// The installed app. These strings must never change: the pairing, the activity log's key,
    /// the settings, and the privacy permissions are all filed under them.
    static let release = AppIdentity(
        bundleID: "net.melisma.latchkey", urlScheme: "latchkey", supportFolderName: "Latchkey")
    /// Debug and test builds.
    static let development = AppIdentity(
        bundleID: "net.melisma.latchkey.dev", urlScheme: "latchkey-dev", supportFolderName: "Latchkey Dev")

    /// This build's own identity.
    static let current: AppIdentity = {
        #if DEBUG
            .development
        #else
            .release
        #endif
    }()
}
