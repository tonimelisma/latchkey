import Foundation

/// One sign-in on one of Claude's pages (spec 013 FR-1322 to FR-1324; plan D6, D7): at most four
/// steps of filling and sending, then whatever Latchkey filled is cleared from the page.
enum SignInFlow {
    /// Runs a sign-in script in the page: (its answer after "ok", the page after it).
    typealias Run = (_ script: String, _ navigates: Bool) async throws -> (detail: String, page: PageScripts.Page)

    struct State: Decodable, Equatable {
        var address: String
        var password: Bool
        var code: Bool
        var user: Bool
        var captcha: Bool
        var problem: String
    }

    enum Outcome: Equatable {
        case signedIn
        /// The page asks for a code Latchkey doesn't hold.
        case needsCode
        /// A captcha or another check Latchkey can't answer.
        case check
        /// The site refused: the page's words, if any.
        case refused(String)
        /// Nothing on the page to fill.
        case noForm
        /// The page went to another site before Latchkey filled anything.
        case wrongSite
    }

    static func state(_ detail: String) throws -> State {
        do { return try JSONDecoder().decode(State.self, from: Data(detail.utf8)) } catch {
            throw SafariBrowser.Failure.failed("The page didn't answer as expected.")
        }
    }

    /// Signs in with `login` on the page `run` works in; the outcome and the page at the end.
    static func signIn(
        isolation: isolated (any Actor)? = #isolation,
        _ login: SavedSignIn, exact: Bool, store: SignInStore, run: Run, now: () -> Date = Date.init,
        wait: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async throws -> (outcome: Outcome, page: PageScripts.Page) {
        let totp = login.otp.flatMap { TOTP(uri: $0) }
        var (detail, page) = try await run(PageScripts.signInState, false)
        var now_ = try state(detail)
        var sentPassword = false
        var sentCode = false
        var sentUser = false
        var filledAny = false
        var outcome: Outcome?
        for _ in 0..<4 {
            if now_.password && sentPassword || now_.code && sentCode {
                outcome = .refused(now_.problem)
                break
            }
            if now_.captcha && !now_.password && !now_.code {
                outcome = .check
                break
            }
            var code = ""
            if now_.code, !now_.password, let totp {
                // A code about to run out waits for the next one; a code sent once is never sent
                // again in its step (FR-1324).
                var at = now()
                let left = Double(totp.period) - at.timeIntervalSince1970.truncatingRemainder(dividingBy: Double(totp.period))
                if left < 2 || !store.mayUseCode(login, step: totp.step(at: at)) {
                    await wait(.milliseconds(Int((left + 0.2) * 1000)))
                    at = now()
                }
                guard store.mayUseCode(login, step: totp.step(at: at)) else {
                    outcome = .refused(now_.problem)
                    break
                }
                code = totp.code(at: at)
                store.usedCode(login, step: totp.step(at: at))
            } else if now_.code, !now_.password {
                outcome = .needsCode
                break
            }
            (detail, page) = try await run(
                PageScripts.signInStep(
                    site: login.site, exact: exact, user: login.user, password: login.password, code: code,
                    userSent: sentUser), true)
            struct Step: Decodable { var step: String }
            let step = (try? JSONDecoder().decode(Step.self, from: Data(detail.utf8)))?.step ?? "none"
            switch step {
            case "password": sentPassword = true
            case "code": sentCode = true
            case "user": sentUser = true
            case "wrongsite": outcome = filledAny ? .signedIn : .wrongSite
            default: outcome = filledAny ? nil : .noForm
            }
            if step == "wrongsite" || step == "none" { break }
            filledAny = true
            (detail, page) = try await run(PageScripts.signInState, false)
            now_ = try state(detail)
        }
        if outcome == nil {
            if now_.password && sentPassword || now_.code && sentCode {
                outcome = .refused(now_.problem)
            } else if sentUser && !sentPassword && !now_.password && !now_.code && now_.user {
                // The user name went, and the site showed no password field after it.
                outcome = .refused(now_.problem)
            } else if now_.code && totp == nil && !now_.password {
                outcome = .needsCode
            } else if now_.captcha {
                outcome = .check
            } else if !filledAny {
                outcome = .noForm
            } else {
                outcome = .signedIn
            }
        }
        // FR-1311: nothing Latchkey filled stays readable on the page.
        (_, page) = try await run(PageScripts.clearSignIn, false)
        return (outcome ?? .signedIn, page)
    }
}
