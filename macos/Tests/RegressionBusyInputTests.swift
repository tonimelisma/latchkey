import AppKit
import Foundation
import Testing
import WebKit

@testable import Latchkey

/// GitHub's macOS 26 runner, 2026-11-25, after real input (#51; seen in a test program, not on
/// the installed app, so no sandbox check): with dozens of pages in one program, Latchkey
/// looked at each page's event counts every 5 ms, which took the main thread, so a key's release
/// reached a page up to 0.75 s late and steps ran past their limits; and when the wait for the
/// keys before an "é" ran out, the é was typed anyway and landed before them ("Café" came out
/// "Céaf"). Waits are now woken by the page's own word, and a character never follows keys the
/// page hasn't taken. Spec 005 FR-480, FR-485.
@MainActor @Suite struct RegressionBusyInputTests {
    /// A view whose page never tells Latchkey anything (no input world), with keys sent to it
    /// that it hasn't taken.
    func untakenKeys() -> (WKWebView, InputSignal) {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let signal = InputSignal()
        RealInput.register(signal, for: view)
        signal.sentKeys = 2
        return (view, signal)
    }

    @Test func aCharacterIsntTypedBeforeKeysThePageHasntTaken() async {
        let (view, _) = untakenKeys()
        defer { RealInput.unregister(view) }
        let typed = await RealInput.insert("é", in: view, within: .milliseconds(200))
        #expect(!typed, "the é would land before the keys on their way")
    }

    @Test func aWaitIsWokenByThePagesWordNotByLookingAgain() async {
        let signal = InputSignal()
        let started = ContinuousClock.now
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            signal.received(["k": "key", "p": false], host: "a.test")
        }
        let told = await signal.until(within: .seconds(20)) { signal.count("key") >= 1 }
        #expect(told)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func aWaitThatNothingAnswersEndsAtItsLimit() async {
        let signal = InputSignal()
        let started = ContinuousClock.now
        let told = await signal.until(within: .milliseconds(200)) { signal.count("input") >= 1 }
        #expect(!told)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// Security review 2026-11-25: a cancelled call doesn't wait out the limit.
    @Test func aCancelledWaitEndsAtOnce() async {
        let signal = InputSignal()
        let started = ContinuousClock.now
        let waiting = Task { @MainActor in
            await signal.until(within: .seconds(30)) { signal.count("key") >= 1 }
        }
        try? await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        #expect(!(await waiting.value))
        #expect(ContinuousClock.now - started < .seconds(20))
    }

    @Test func anEventOfAnotherKindDoesntEndTheWait() async {
        let signal = InputSignal()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            signal.received(["k": "up"], host: "a.test")
        }
        let told = await signal.until(within: .milliseconds(400)) { signal.count("input") >= 1 }
        #expect(!told)
        #expect(signal.count("up") == 1)
    }

    @Test func typingThatStopsSaysHowFarItGotAndThatEnterWasntPressed() {
        let said = LockedBrowser.notTaken(3, of: 4, submit: true)
        #expect(said.contains("3 of 4") && said.contains("Enter wasn't pressed") && said.contains("Read the page"))
        #expect(!LockedBrowser.notTaken(0, of: 2, submit: false).contains("Enter"))
    }
}

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-480, FR-485
