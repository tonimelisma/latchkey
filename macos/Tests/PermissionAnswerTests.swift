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

    @Test func aDeclinedScreenshotIsRecognised() {
        let declined = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        #expect(ScreenCapture.declined(declined))
        #expect(!ScreenCapture.declined(NSError(domain: SCStreamErrorDomain, code: -1)))
    }

    @Test func automationAnswersPointToLatchkeysPermissions() {
        for text in [
            NotesCapability.explain(ScriptError.notAllowed), MessagesCapability.explain(ScriptError.notAllowed),
            MailCapability.notAllowed,
        ] {
            #expect(text.contains("Latchkey's Settings → Permissions"))
        }
    }
}
