import Foundation
import ScreenCaptureKit
import Testing

@testable import Latchkey

/// A permission missing at call time is named in Claude's answer (spec 001 FR-625).
struct PermissionAnswerTests {
    @Test func privacyRefusalIsToldFromFilePermissions() {
        let privacy = NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        let ownPermissions = NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        #expect(FilesCapability.refusedByPrivacy(privacy))
        #expect(!FilesCapability.refusedByPrivacy(ownPermissions))
        #expect(FilesCapability.privacyRefusal.contains("Full Disk Access"))
    }

    @Test func anUnreachableDeviceNearbyIsRecognised() {
        #expect(LocalNetwork.looksRefused("ping: sendto: No route to host"))
        #expect(LocalNetwork.looksRefused("curl: (7) Failed to connect to 192.168.1.1 port 80: No route to host"))
        #expect(!LocalNetwork.looksRefused("curl: (6) Could not resolve host: example.invalid"))
        #expect(LocalNetwork.hint.contains("Local Network"))
    }

    @Test func aDeclinedScreenshotIsRecognised() {
        let declined = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        #expect(ScreenCapture.declined(declined))
        #expect(!ScreenCapture.declined(NSError(domain: SCStreamErrorDomain, code: -1)))
    }

    @Test func automationAnswersPointToLatchkeysPermissions() {
        for text in [
            NotesCapability.explain(ScriptError.notAllowed), MessagesCapability.explain(ScriptError.notAllowed),
        ] {
            #expect(text.contains("Latchkey's Settings → Permissions"))
        }
    }
}
