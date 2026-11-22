import Foundation

/// One sign-in on one of Claude's pages (spec 013 FR-1322 to FR-1324; plan D6, D7): at most four
/// steps of filling and sending, then whatever Latchkey filled is cleared from the page, also
/// when a step fails.
enum SignInFlow {
    /// Runs a sign-in script in the page: its answer after "ok", the page after it, and the page's
    /// address as the browser has it (never as the page's script says).
    typealias Run = (_ script: String, _ navigates: Bool) async throws -> (
        detail: String, page: PageScripts.Page, address: String
    )

    /// What the page asks for. Written by a script in the page, so it only steers what to fill;
    /// where to fill is decided from the browser's own address.
    struct State: Decodable, Equatable {
        var password: Bool
        var code: Bool
        var user: Bool
        var captcha: Bool
        var problem: String
        /// A button that sends the code by text or email, or picks that way (Citi, GitHub).
        var deliver: Bool
        /// A second step with nothing to fill (a passkey or security key page; GitHub, 2026-11-21).
        var secondFactor: Bool
    }

    enum Outcome: Equatable {
        case signedIn
        /// The page asks for a code Latchkey doesn't hold.
        case needsCode
        /// The site sent a code that hasn't reached Latchkey yet (FR-1361, FR-1364): call again.
        case waitingForCode
        /// A captcha or another check Latchkey can't answer.
        case check
        /// The site refused: the page's words, if any.
        case refused(String)
        /// Nothing on the page to fill.
        case noForm
        /// A field didn't hold what Latchkey typed, so nothing was sent (Citi, 2026-11-21).
        case couldntFill
        /// The page is on another site (or moved there) before Latchkey filled anything.
        case wrongSite
    }

    static func state(_ detail: String) throws -> State {
        do { return try JSONDecoder().decode(State.self, from: Data(detail.utf8)) } catch {
            throw SafariBrowser.Failure.failed("The page didn't answer as expected.")
        }
    }

    /// The host to fill on, when the browser's address is one `login` fills on (FR-1321).
    static func host(_ login: SavedSignIn, exact: Bool, address: String) -> String? {
        guard SiteMatch.fills(site: login.site, on: address), var host = URL(string: address)?.host()?.lowercased()
        else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard !exact || host == login.site else { return nil }
        return host
    }

    /// A code texted to the Owner (FR-1360): the code, or none, and whether one may still come.
    typealias Texted = () async -> (code: String?, pending: Bool)

    /// Signs in with `login` on the page `run` works in; the outcome and the page at the end.
    static func signIn(
        isolation: isolated (any Actor)? = #isolation,
        _ login: SavedSignIn, exact: Bool, store: SignInStore, run: Run, now: () -> Date = Date.init,
        wait: (Duration) async -> Void = { try? await Task.sleep(for: $0) }, texted: Texted? = nil,
        mayDeliver: Bool = true, delivered: () -> Void = {}
    ) async throws -> (outcome: Outcome, page: PageScripts.Page) {
        var filledAny = false
        do {
            let r = try await steps(
                login, exact: exact, store: store, run: run, now: now, wait: wait, texted: texted,
                mayDeliver: mayDeliver, delivered: delivered
            ) {
                filledAny = true
            }
            // FR-1311: nothing Latchkey filled stays readable on the page.
            let cleared = try await run(PageScripts.clearSignIn, false)
            return (r, cleared.page)
        } catch {
            if filledAny { _ = try? await run(PageScripts.clearSignIn, false) }
            throw error
        }
    }

    private static func steps(
        isolation: isolated (any Actor)? = #isolation,
        _ login: SavedSignIn, exact: Bool, store: SignInStore, run: Run, now: () -> Date,
        wait: (Duration) async -> Void, texted: Texted?, mayDeliver: Bool, delivered: () -> Void,
        filled: () -> Void
    ) async throws -> Outcome {
        let totp = login.otp.flatMap { TOTP(uri: $0) }
        var r = try await run(PageScripts.signInState, false)
        var page = try state(r.detail)
        var sentPassword = false
        var sentCode = false
        var sentUser = false
        var sentDelivery = false
        var deliveries = 0
        var filledAny = false
        steps: for _ in 0..<6 {
            // A button that sends the code (or picks the text way) is pressed: after the password
            // on its page (Citi keeps its password field there), or on a page past the password
            // that asks for nothing else yet (GitHub's passkey page and its "Send SMS"), at most
            // twice a call and not again while a code sent shortly before may still come.
            let pastPassword = !page.password && !page.user && !sentCode
            let choosing =
                page.deliver && deliveries < 2
                && ((sentPassword && !page.code && !sentDelivery) || (pastPassword && mayDeliver))
            // Back at a sign-in form after asking for the code: the site ended the sign-in
            // (Citi did, 2026-11-21); no refusal of the password, which it had taken.
            if sentDelivery && page.password && !page.code && !sentCode { return .check }
            if !choosing, page.password && sentPassword || page.code && sentCode { return .refused(page.problem) }
            if page.captcha && !page.password && !page.code { return .check }
            if page.secondFactor && !choosing { return .check }
            var code = ""
            if choosing {
                // The button first; the code comes after it.
            } else if page.code, !page.password, totp == nil {
                // FR-1360: a code the site texted to the Owner, when Latchkey may use texts.
                guard let texted else { return .needsCode }
                let t = await texted()
                guard let c = t.code else { return t.pending ? .waitingForCode : .needsCode }
                code = c
            } else if page.code, !page.password, let totp {
                // A code about to run out waits for the next one; a code sent once is never sent
                // again in its step (FR-1324).
                var at = now()
                let period = Double(totp.period)
                let left = period - at.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
                if left < 2 || !store.mayUseCode(login, step: totp.step(at: at)) {
                    await wait(.milliseconds(Int((left + 0.2) * 1000)))
                    at = now()
                }
                guard store.mayUseCode(login, step: totp.step(at: at)) else { return .refused(page.problem) }
                code = totp.code(at: at)
                store.usedCode(login, step: totp.step(at: at))
            }
            // Where to fill is decided here, from the browser's own address.
            guard let host = host(login, exact: exact, address: r.address) else {
                return filledAny ? .signedIn : .wrongSite
            }
            filled()
            r = try await run(
                PageScripts.signInStep(
                    host: host, user: login.user, password: login.password, code: code, userSent: sentUser,
                    mayDeliver: choosing), true)
            struct Step: Decodable { var step: String }
            let step =
                r.detail == "wrongsite"
                ? "wrongsite" : (try? JSONDecoder().decode(Step.self, from: Data(r.detail.utf8)))?.step ?? "none"
            switch step {
            case "password": sentPassword = true
            case "code": sentCode = true
            case "user": sentUser = true
            case "delivery":
                sentDelivery = true
                deliveries += 1
                delivered()
            case "wrongsite": return filledAny ? .signedIn : .wrongSite
            case "unfilled": return .couldntFill
            default: break steps  // nothing more to fill: what the page shows decides
            }
            filledAny = true
            r = try await run(PageScripts.signInState, false)
            page = try state(r.detail)
        }
        if sentDelivery && page.password && !page.code && !sentCode { return .check }
        if page.password && sentPassword || page.code && sentCode { return .refused(page.problem) }
        // The user name went, and the site showed no password field after it.
        if sentUser && !sentPassword && !page.password && !page.code && page.user { return .refused(page.problem) }
        if page.code && totp == nil && !page.password { return .needsCode }
        if page.captcha || page.secondFactor { return .check }
        return filledAny ? .signedIn : .noForm
    }
}
