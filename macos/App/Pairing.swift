import AuthenticationServices
import Foundation

enum PairingError: LocalizedError {
    case cancelled
    case relay(String)
    case invalidRelay

    var errorDescription: String? {
        switch self {
        case .cancelled: "Connecting was cancelled."
        case .relay(let msg): msg
        case .invalidRelay: "Enter the relay's address, for example https://relay.example.com."
        }
    }
}

/// What the Owner is asked when a pairing link arrives other than through the app's own sign-in
/// window (FR-054): the account's email and the relay, and whether it replaces the current
/// pairing. Without the email (the lookup failed) there is no Connect button.
struct PairingConfirmation: Equatable {
    let title: String
    let message: String
    let canConnect: Bool

    init(relay: URL, email: String?, current: URL?) {
        let host = relay.host() ?? relay.absoluteString
        guard let email else {
            title = "This connection link has expired"
            message = "To connect this Mac, choose Connect to a Relay… in the Latchkey menu again."
            canConnect = false
            return
        }
        title = "Connect this Mac to \(email)’s account?"
        var text =
            "A connection link from the relay \(host) was opened. Claude signed in to that account will be able to use this Mac. Connect only if you just clicked Connect on that page yourself."
        if let current {
            text += " This replaces this Mac’s current connection to \(current.host() ?? current.absoluteString)."
        }
        message = text
        canConnect = true
    }
}

/// Pairs this Mac with an account through the Owner's browser (plan D6, agent-protocol.md
/// "Pairing"). No codes are copied by hand (FR-050).
@MainActor
final class PairingFlow: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var pending: CheckedContinuation<URL, Error>?

    private func finish(_ result: Result<URL, Error>) {
        guard let p = pending else { return }
        pending = nil
        p.resume(with: result)
    }

    var isPairing: Bool { pending != nil }

    /// The sign-in window's completion handler. macOS calls it on a background thread, so it is
    /// built outside the main actor and marked @Sendable: a closure written inside this
    /// main-actor class would inherit main-actor isolation, and Swift 6 traps when it is called
    /// from another thread (that crashed 0.1.0 and 0.1.1).
    nonisolated static func completionHandler(
        _ deliver: @escaping @Sendable (Result<URL, Error>) -> Void
    ) -> @Sendable (URL?, Error?) -> Void {
        { @Sendable url, error in
            let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
            if let url {
                deliver(.success(url))
            } else {
                deliver(.failure(cancelled ? PairingError.cancelled : (error ?? PairingError.cancelled)))
            }
        }
    }

    /// Ends the sign-in window's pairing in progress, if any, as cancelled: a link the Owner
    /// confirmed from elsewhere (FR-054) takes its place.
    func cancelPending() {
        guard pending != nil else { return }
        session?.cancel()
        finish(.failure(PairingError.cancelled))
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let anchor = { @MainActor in
            NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? ASPresentationAnchor()
        }
        if Thread.isMainThread { return MainActor.assumeIsolated(anchor) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(anchor) }
    }

    /// The code and relay from a latchkey://paired link.
    nonisolated static func parse(_ url: URL) -> (code: String, relay: URL?)? {
        guard url.scheme == "latchkey", url.host() == "paired",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { return nil }
        return (code, items.first(where: { $0.name == "relay" })?.value.flatMap(normalize))
    }

    nonisolated static func normalize(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.contains("://") { t = "https://" + t }
        guard var c = URLComponents(string: t), let host = c.host, !host.isEmpty,
            c.scheme == "https" || (c.scheme == "http" && ["localhost", "127.0.0.1"].contains(host))
        else { return nil }
        c.path = ""
        c.query = nil
        c.fragment = nil
        return c.url
    }

    func pair(relay: URL, macName: String) async throws -> DeviceIdentity {
        var c = URLComponents(url: relay, resolvingAgainstBaseURL: false)!
        c.path = "/pair"
        c.queryItems = [URLQueryItem(name: "name", value: macName)]
        let callback = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            pending = cont
            let s = ASWebAuthenticationSession(
                url: c.url!, callback: .customScheme("latchkey"),
                completionHandler: Self.completionHandler { [weak self] result in
                    Task { @MainActor in self?.finish(result) }
                })
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false  // use the browser's passkeys and session
            session = s
            s.start()
        }
        session = nil
        guard
            let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value
        else { throw PairingError.relay("The relay didn't send a connection code.") }
        ownCode = code
        return try await Self.exchange(relay: relay, code: code, macName: macName)
    }

    /// The code the sign-in window last delivered. If a browser also hands the same link to the
    /// app, it is already used: `isOwn` lets the app ignore it instead of showing "expired".
    private var ownCode: String?
    func isOwn(_ code: String) -> Bool { ownCode == code }

    /// Asks the relay which account a pairing code belongs to, without using the code
    /// (agent-protocol.md "Pairing", FR-054). Throws if the code is unknown, used, or expired,
    /// or the relay can't be reached or answers with something that isn't a plain address.
    nonisolated static func preview(relay: URL, code: String) async throws -> String {
        var req = URLRequest(url: relay.appending(path: "pair/preview"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["code": code])
        req.timeoutInterval = 15
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw PairingError.relay("The relay couldn't be reached.")
        }
        let body = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let email = body["email"].flatMap(cleanEmail) else {
            throw PairingError.relay(body["error"] ?? "This connection link has expired.")
        }
        return email
    }

    /// The address as shown in the confirmation dialog, or nil if it isn't one plain email
    /// address (so a relay can't put misleading text in the dialog).
    nonisolated static func cleanEmail(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count <= 254, t.wholeMatch(of: /[^\s@]+@[^\s@]+\.[^\s@]+/) != nil,
            t.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return t
    }

    /// Registers this Mac's new Secure Enclave key with the relay and saves the pairing.
    static func exchange(relay: URL, code: String, macName: String, save: Bool = true) async throws
        -> DeviceIdentity
    {
        let key = try SecureEnclaveSigningKey.create()
        var req = URLRequest(url: relay.appending(path: "pair/exchange"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode([
            "code": code, "public_key": key.publicKeyDER.base64URLEncodedString(), "name": macName,
        ])
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        let body = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let deviceID = body["device_id"] else {
            throw PairingError.relay(body["error"] ?? "The relay couldn't connect this Mac. Try again.")
        }
        if save { try DeviceIdentity.save(relayURL: relay, deviceID: deviceID, key: key) }
        return DeviceIdentity(relayURL: relay, deviceID: deviceID, key: key)
    }
}
