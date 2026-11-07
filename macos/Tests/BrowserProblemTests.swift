import Foundation
import Testing
import WebKit

@testable import Latchkey

/// An error says which browser it came from (2026-11-07: a page script's exception in Latchkey's
/// own browser, while the Mac was locked, was said to be Safari's).
@Suite struct BrowserProblemTests {
    @Test func latchkeysOwnBrowserIsNamed() {
        let own = BrowserCapability.problem(
            NSError(domain: WKError.errorDomain, code: WKError.javaScriptExceptionOccurred.rawValue))
        #expect(own.hasPrefix("Latchkey's own browser"), "\(own)")
        let safari = BrowserCapability.problem(NSError(domain: NSCocoaErrorDomain, code: 1))
        #expect(safari.hasPrefix("Safari reported a problem"), "\(safari)")
    }
}
