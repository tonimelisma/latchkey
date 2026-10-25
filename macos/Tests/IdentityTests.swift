import Foundation
import Testing

@testable import Latchkey

/// Debug and test builds are their own app, apart from the installed one (Toni, 2026-10-25).
@Suite struct IdentityTests {
    static let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// The installed app's pairing, activity-log key, settings, and permissions are filed under
    /// these exact strings. Changing any of them unpairs every installed Mac.
    @Test func theInstalledAppsNamesNeverChange() {
        let id = AppIdentity.release
        #expect(id.bundleID == "net.melisma.latchkey")
        #expect(id.keychainService == "net.melisma.latchkey")
        #expect(id.logSubsystem == "net.melisma.latchkey", "macos/scripts/install.sh reads the log by this name")
        #expect(id.defaultsDomain == "net.melisma.latchkey")
        #expect(id.helperBundleID == "net.melisma.latchkey.helper")
        #expect(id.machService == "net.melisma.latchkey.helper")
        #expect(id.helperPlistName == "net.melisma.latchkey.helper.plist")
        #expect(id.urlScheme == "latchkey")
        #expect(id.supportFolderName == "Latchkey")
        #expect(id.supportDirectory.path == URL.applicationSupportDirectory.appending(path: "Latchkey").path)
        #expect(DeviceIdentity.recordAccount == "pairing")
        #expect(Keychain.traceKeyAccount == "activity-log-key")
    }

    @Test func aDevelopmentBuildSharesNoNameWithTheInstalledApp() {
        let dev = AppIdentity.development
        #expect(dev.bundleID == "net.melisma.latchkey.dev")
        #expect(dev.helperBundleID == "net.melisma.latchkey.dev.helper")
        #expect(dev.helperPlistName == "net.melisma.latchkey.dev.helper.plist")
        #expect(dev.urlScheme == "latchkey-dev")
        #expect(dev.supportFolderName == "Latchkey Dev")
        let names: (AppIdentity) -> [String] = {
            [
                $0.bundleID, $0.keychainService, $0.logSubsystem, $0.defaultsDomain, $0.helperBundleID,
                $0.machService, $0.helperPlistName, $0.urlScheme, $0.supportFolderName,
            ]
        }
        #expect(Set(names(dev)).isDisjoint(with: names(AppIdentity.release)))
    }

    /// The tests run inside a Debug build of the app: it must be the development identity, in
    /// the code and in what macOS reads from the bundle.
    @Test @MainActor func thisTestAppIsNotTheInstalledApp() throws {
        #expect(AppIdentity.current == .development)
        #expect(Bundle.main.bundleIdentifier == "net.melisma.latchkey.dev")
        #expect(Keychain.service == "net.melisma.latchkey.dev")
        #expect(LocalData().defaultsDomain == "net.melisma.latchkey.dev")
        #expect(LocalData().supportDirectory.lastPathComponent == "Latchkey Dev")
        #expect(TraceStore.defaultDirectory.lastPathComponent == "Latchkey Dev")

        // The bundle on disk (Bundle.main caches; read the file).
        let contents = Bundle.main.bundleURL.appending(path: "Contents")
        let info = try #require(NSDictionary(contentsOf: contents.appending(path: "Info.plist")))
        #expect(info["CFBundleIdentifier"] as? String == "net.melisma.latchkey.dev")
        #expect(info["CFBundleDisplayName"] as? String == "Latchkey Dev")
        let types = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        #expect(types.count == 1)
        #expect(types.first?["CFBundleURLSchemes"] as? [String] == ["latchkey-dev"], "it must not claim latchkey://")
        #expect(types.first?["CFBundleURLName"] as? String == "net.melisma.latchkey.dev.pairing")

        // Its helper: one launchd plist, under the development names.
        let daemons = contents.appending(path: "Library/LaunchDaemons")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: daemons.path)
                == ["net.melisma.latchkey.dev.helper.plist"])
        let plist = try #require(
            NSDictionary(contentsOf: daemons.appending(path: AppIdentity.development.helperPlistName)))
        #expect(plist["Label"] as? String == "net.melisma.latchkey.dev.helper")
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["net.melisma.latchkey.dev"])
        #expect((plist["MachServices"] as? [String: Bool]) == ["net.melisma.latchkey.dev.helper": true])
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/LatchkeyHelper")
    }

    /// The helper's launchd plist is made from one template at build time. For the installed
    /// app it must come out exactly as the file that shipped up to 0.8.8.
    @Test func theInstalledHelpersPlistIsUnchanged() throws {
        let template = try String(
            contentsOf: Self.macos.appending(path: "Helper/LaunchDaemon.plist"), encoding: .utf8)
        let made = template.replacingOccurrences(of: "$(LATCHKEY_APP_ID)", with: AppIdentity.release.bundleID)
        let shipped = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>Label</key>
            \t<string>net.melisma.latchkey.helper</string>
            \t<key>BundleProgram</key>
            \t<string>Contents/MacOS/LatchkeyHelper</string>
            \t<key>AssociatedBundleIdentifiers</key>
            \t<array>
            \t\t<string>net.melisma.latchkey</string>
            \t</array>
            \t<key>MachServices</key>
            \t<dict>
            \t\t<key>net.melisma.latchkey.helper</key>
            \t\t<true/>
            \t</dict>
            \t<key>RunAtLoad</key>
            \t<true/>
            </dict>
            </plist>

            """
        #expect(made == shipped)
    }

    /// `project.yml` gives each configuration its identifiers; they must be the ones the code uses.
    @Test func theProjectUsesTheSameIdentifiers() throws {
        let text = try String(contentsOf: Self.macos.appending(path: "project.yml"), encoding: .utf8)
        func settings(_ config: String) throws -> String {
            let block = try #require(text.firstMatch(of: try Regex("(?m)^    \(config):\n((?:      .*\n)+)")))
            return String(try #require(block.output[1].substring))
        }
        let release = try settings("Release")
        #expect(release.contains("      LATCHKEY_APP_ID: net.melisma.latchkey\n"))
        #expect(release.contains("      LATCHKEY_URL_SCHEME: latchkey\n"))
        #expect(release.contains("      LATCHKEY_DISPLAY_NAME: Latchkey\n"))
        let debug = try settings("Debug")
        #expect(debug.contains("      LATCHKEY_APP_ID: net.melisma.latchkey.dev\n"))
        #expect(debug.contains("      LATCHKEY_URL_SCHEME: latchkey-dev\n"))
        #expect(debug.contains("      LATCHKEY_DISPLAY_NAME: Latchkey Dev\n"))
        #expect(text.contains("        PRODUCT_BUNDLE_IDENTIFIER: $(LATCHKEY_APP_ID)\n"))
        #expect(text.contains("        PRODUCT_BUNDLE_IDENTIFIER: $(LATCHKEY_APP_ID).helper\n"))
        #expect(!text.contains("PRODUCT_BUNDLE_IDENTIFIER: net."), "an identifier that ignores the configuration")
    }

    /// A link the system hands over arrives under this build's own scheme; the relay's sign-in
    /// redirect, caught by the sign-in window, is always latchkey://.
    @Test func linksUnderTheBuildsOwnSchemeAreRead() throws {
        let own = try #require(URL(string: "latchkey-dev://paired?code=abc"))
        #expect(PairingFlow.parse(own, ownScheme: "latchkey-dev")?.code == "abc")
        #expect(PairingFlow.parse(own, ownScheme: "latchkey") == nil, "the installed app ignores a development link")
        let relay = try #require(URL(string: "latchkey://paired?code=abc"))
        #expect(PairingFlow.parse(relay, ownScheme: "latchkey-dev")?.code == "abc")
        #expect(PairingFlow.parse(relay, ownScheme: "latchkey")?.code == "abc")
    }

    /// Files never changes the settings and data of the running build, nor the installed app's.
    @Test func bothBuildsSettingsAndDataAreOwnFiles() {
        let own = OwnFiles.standard
        let library = URL.libraryDirectory
        for id in ["net.melisma.latchkey", "net.melisma.latchkey.dev"] {
            #expect(own.holds(library.appending(path: "Preferences/\(id).plist")))
            #expect(own.holds(library.appending(path: "Preferences/ByHost/\(id).0000.plist")))
        }
        #expect(own.holds(library.appending(path: "Application Support/Latchkey/activity.store")))
        #expect(own.holds(library.appending(path: "Application Support/Latchkey Dev/activity.store")))
        #expect(!own.holds(library.appending(path: "Preferences/net.melisma.other.plist")))
    }
}
