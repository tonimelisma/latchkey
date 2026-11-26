import Foundation
import Testing

@testable import Latchkey

/// Spec 013 FR-1376 (Toni, 2026-11-22: "test all approaches for robustness on a wide variety of
/// web sites"): finding a site's code in the owner's texts and email, for Latchkey's two ways of
/// the codes experiment.
@MainActor @Suite struct CodeFinderTests {
    typealias M = CodeFinder.Message
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let mailKey = MailCodes.Place(id: 7, account: "acc", mailbox: "INBOX").key

    func finder(texts: [M] = [], mail: [M] = [], clock: ManualClock = ManualClock()) -> CodeFinder {
        let f = CodeFinder()
        f.textsOn = { true }
        f.mailOn = { true }
        f.texts = { _ in texts }
        f.mail = { _ in mail }
        f.startMail = {}
        // A clock only the test moves: a busy runner's wait for a thread can't decide a test
        // (regression below; spec 016 FR-1602).
        f.clock = clock
        return f
    }

    @Test func theCodeIsANumberNextToACodeWord() {
        #expect(CodeFinder.code(in: "Your GitHub verification code is 482913.") == "482913")
        #expect(CodeFinder.code(in: "Use 1234 as your one-time passcode") == "1234")
        #expect(CodeFinder.code(in: "Your code.123456Please don't share it") == "123456")
        #expect(CodeFinder.code(in: "Meet at 1830 by the station") == nil, "no code word: no code")
        #expect(CodeFinder.code(in: "Order 123456789 shipped, code below") == nil, "9 digits is no code")
    }

    @Test func aSiteBoundLineGivesItsDomainAndCode() {
        let b = CodeFinder.bound("Your code is 123456.\n\n@github.com #123456")
        #expect(b?.domain == "github.com" && b?.code == "123456")
        #expect(CodeFinder.bound("@a.test #9X8Y7Z @b.test")?.code == "9X8Y7Z")
        #expect(CodeFinder.bound("Your code is 123456") == nil)
        #expect(CodeFinder.code(in: "Code 111111\n@a.test #222222") == "222222", "the bound code wins")
    }

    /// A bound text counts only for its own site; an email only when it names the site; a plain
    /// text from anyone (Toni, 2026-11-21: "Any new code text").
    /// Security review 2026-11-22: the site's name as a whole word only.
    @Test func anEmailNamesTheSiteAsAWholeWord() {
        #expect(MailCodes.names("online.citi.com", in: "Citi: your code is 123456"))
        #expect(!MailCodes.names("citi.com", in: "Our capacities code 123456"))
        #expect(!MailCodes.names("app.com", in: "Your Apple code 123456"))
        #expect(MailCodes.names("github.com", in: "From: noreply@github.com"))
        #expect(MailCodes.names("x.ai", in: "From: x.ai team") && !MailCodes.names("x.ai", in: "max.aim"))
    }

    /// Of two codes that came together, the one naming the site; a used message never again, also
    /// for a checked code.
    @Test func theSitesOwnTextFirstAndAUsedOneNeverAgain() async {
        let f = finder(texts: [
            M(id: "other", text: "Your Shop code is 111111", date: Self.now),
            M(id: "mine", text: "Your GitHub code is 222222", date: Self.now.addingTimeInterval(-30)),
        ])
        #expect(await f.find(site: "github.com", email: false, since: Self.now)?.id == "mine")
        #expect(await f.holding("222222", site: "github.com", since: Self.now) == "mine")
        f.markUsed("mine")
        #expect(await f.holding("222222", site: "github.com", since: Self.now) == nil)
    }

    @Test func whichMessagesMayHoldTheSitesCode() {
        #expect(CodeFinder.mayBe(M(id: "g", text: "code 123456\n@a.test #123456", date: Self.now), for: "a.test"))
        #expect(!CodeFinder.mayBe(M(id: "g", text: "code 123456\n@evil.test #123456", date: Self.now), for: "a.test"))
        #expect(CodeFinder.mayBe(M(id: "g", text: "Your code is 123456", date: Self.now), for: "a.test"))
        #expect(
            CodeFinder.mayBe(
                M(id: Self.mailKey, text: "From: GitHub\nYour GitHub code 123456", date: Self.now), for: "github.com"))
        #expect(
            !CodeFinder.mayBe(
                M(id: Self.mailKey, text: "From: Shop\nYour code 123456", date: Self.now), for: "github.com"))
    }

    /// Codes count from the password Latchkey typed in the last 10 minutes, else the last 3.
    @Test func codesCountFromThePasswordTyped() {
        let f = finder()
        #expect(f.since("a.test", now: Self.now) == Self.now.addingTimeInterval(-180))
        f.passwordTyped("a.test", at: Self.now.addingTimeInterval(-400))
        #expect(f.since("a.test", now: Self.now) == Self.now.addingTimeInterval(-400))
        #expect(f.since("a.test", now: Self.now.addingTimeInterval(400)) == Self.now.addingTimeInterval(220))
    }

    @Test func findTakesTheNewestUnusedCodeForTheSite() async {
        let f = finder(texts: [
            M(id: "old", text: "Your code is 111111", date: Self.now.addingTimeInterval(-60)),
            M(id: "new", text: "Your code is 222222", date: Self.now),
            M(id: "other", text: "Your code is 333333\n@evil.test #333333", date: Self.now.addingTimeInterval(10)),
        ])
        let first = await f.find(site: "a.test", email: false, since: Self.now.addingTimeInterval(-120))
        #expect(first?.code == "222222" && first?.id == "new")
        f.markUsed("new")
        #expect(await f.find(site: "a.test", email: false, since: Self.now)?.code == "111111")
        f.markUsed("old")
        #expect(await f.find(site: "a.test", email: false, since: Self.now) == nil)
    }

    @Test func nothingIsReadWhileTheCapabilityIsOff() async {
        let f = finder(texts: [M(id: "t", text: "Your code is 222222", date: Self.now)])
        f.textsOn = { false }
        #expect(!f.readable(email: false))
        #expect(await f.find(site: "a.test", email: false, since: Self.now) == nil)
        #expect(await f.holding("222222", site: "a.test", since: Self.now) == nil)
    }

    @Test func holdingFindsTheMessageWithExactlyThatCode() async {
        let f = finder(
            texts: [M(id: "t", text: "Your code is 222222", date: Self.now)],
            mail: [M(id: Self.mailKey, text: "From: A.test\nYour a code is 444444", date: Self.now)])
        #expect(await f.holding("222222", site: "a.test", since: Self.now) == "t")
        #expect(await f.holding("444444", site: "a.test", since: Self.now) == Self.mailKey)
        #expect(await f.holding("999999", site: "a.test", since: Self.now) == nil)
    }

    /// Regression (mac build on GitHub's macOS runner, 2026-11-24): the three tests above that
    /// call `find` or `holding` failed on every run, though nothing in them was wrong. The runner
    /// was so busy that the stand-in texts were read 21 to 31 s after the call (runs 45348160266,
    /// 45348152855), past the 10 s limit, and the lookup answered nil. The limit is measured on
    /// the finder's clock, which the tests move: a read that takes long in real time still counts
    /// while that clock is within the limit.
    @Test func aReadThatStartsLateStillCountsWithinTheLimit() async {
        let clock = ManualClock()
        let f = finder(clock: clock)
        let gate = DispatchSemaphore(value: 0)
        let late = [M(id: "late", text: "Your code is 222222", date: Self.now)]
        f.texts = { _ in
            gate.wait()
            return late
        }
        let found = Task { await f.find(site: "a.test", email: false, since: Self.now)?.id }
        #expect(await clock.waitForSleepers(1), "the read's limit started")
        clock.advance(by: f.readLimit - .seconds(1))
        gate.signal()
        #expect(await found.value == "late")
    }

    /// A read that never answers gives no code once the limit passes (Constitution II): the
    /// stand-in is held until the lookup has answered, and the test moves the clock past the
    /// limit, so no timing decides it.
    @Test func aReadThatNeverAnswersGivesNothingAtTheLimit() async {
        let gate = DispatchSemaphore(value: 0)
        let clock = ManualClock()
        let f = finder(clock: clock)
        let never = [M(id: "never", text: "Your code is 222222", date: Self.now)]
        f.texts = { _ in
            gate.wait()
            return never
        }
        let found = Task { await f.find(site: "a.test", email: false, since: Self.now)?.id }
        #expect(await clock.waitForSleepers(1), "the read's limit started")
        clock.advance(by: f.readLimit)
        #expect(await found.value == nil)
        gate.signal()
    }
}
