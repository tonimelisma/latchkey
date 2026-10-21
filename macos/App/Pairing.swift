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

    /// A latchkey://paired link opened from another browser window (for example after signing
    /// up through the emailed link) completes the pairing in progress. Returns false if none is.
    func receive(_ url: URL) -> Bool {
        guard pending != nil, url.scheme == "latchkey", url.host() == "paired" else { return false }
        session?.cancel()
        finish(.success(url))
        return true
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }

    static func normalize(_ text: String) -> URL? {
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
            let s = ASWebAuthenticationSession(url: c.url!, callback: .customScheme("latchkey")) {
                [weak self] url, error in
                MainActor.assumeIsolated {
                    if let url {
                        self?.finish(.success(url))
                    } else {
                        let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                        self?.finish(.failure(cancelled ? PairingError.cancelled : (error ?? PairingError.cancelled)))
                    }
                }
            }
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
        return try await Self.exchange(relay: relay, code: code, macName: macName)
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
