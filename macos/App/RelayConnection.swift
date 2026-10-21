import Foundation

enum ConnectionStatus: Equatable, Sendable {
    case notPaired
    case connecting
    case connected
    case waiting(until: Date)  // reconnecting after a failure
    case signInAgain  // 4001
    case revoked  // 4002: this Mac was disconnected from the account
    case replaced  // 4003
    case updateRequired  // 4004
}

/// What the connection needs from the rest of the app.
struct ConnectionHooks: Sendable {
    var state: @Sendable () async -> AgentState
    var tools: @Sendable () async -> [Tool]
    var call: @Sendable (Call) async -> ToolResult
    var status: @Sendable (ConnectionStatus) async -> Void
    var notice: @Sendable (Notice) async -> Void
}

/// The one outbound WebSocket to the relay (plan D1, agent-protocol.md). Reconnects by itself
/// with backoff; `reconnectNow` skips the wait (network change, wake).
actor RelayConnection {
    private let identity: DeviceIdentity
    private let hooks: ConnectionHooks
    private let policy = ReconnectPolicy()
    private let session: URLSession

    private var loop: Task<Void, Never>?
    private var task: URLSessionWebSocketTask?
    private var running: [String: Task<Void, Never>] = [:]
    private var wake: CheckedContinuation<Void, Never>?
    private var heartbeat: TimeInterval = 15
    private var pendingPing: UUID?

    init(identity: DeviceIdentity, hooks: ConnectionHooks) {
        self.identity = identity
        self.hooks = hooks
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    static func agentURL(relay: URL) -> URL {
        var c = URLComponents(url: relay, resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.path = "/agent/v1"
        c.query = nil
        return c.url!
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    /// Ends the connection, sending goodbye first when a reason is given.
    func stop(goodbye reason: GoodbyeReason?) async {
        if let reason, let task {
            let msg = AgentMessage.goodbye(Goodbye(reason: reason, state: await hooks.state()))
            try? await send(msg, on: task)
        }
        loop?.cancel()
        loop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        wake?.resume()
        wake = nil
    }

    /// Tells the relay the Mac is about to sleep or power off, without ending the loop; the
    /// connection drops by itself as the system sleeps, and reconnects on wake.
    func sendGoodbye(_ reason: GoodbyeReason) async {
        guard let task else { return }
        try? await send(.goodbye(Goodbye(reason: reason, state: await hooks.state())), on: task)
    }

    func reconnectNow() {
        if let wake {
            self.wake = nil
            wake.resume()
        } else if task == nil {
            start()
        }
    }

    func sendState() async {
        guard let task else { return }
        try? await send(.state(StateUpdate(state: await hooks.state())), on: task)
    }

    func sendTools() async {
        guard let task else { return }
        try? await send(.tools(ToolsUpdate(tools: await hooks.tools())), on: task)
    }

    private func send(_ m: AgentMessage, on t: URLSessionWebSocketTask) async throws {
        try await t.send(.string(String(decoding: try m.encode(), as: UTF8.self)))
    }

    private func receive(_ t: URLSessionWebSocketTask) async throws -> AgentMessage {
        switch try await t.receive() {
        case .string(let s): return try AgentMessage.decode(Data(s.utf8))
        case .data: throw ProtocolError.violation("binary frame")
        @unknown default: throw ProtocolError.violation("unknown frame")
        }
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            await hooks.status(.connecting)
            let t = session.webSocketTask(with: Self.agentURL(relay: identity.relayURL), protocols: ["latchkey.v1"])
            t.maximumMessageSize = 4 << 20
            task = t
            t.resume()
            do {
                try await handshake(t)
                attempt = 0
                await hooks.status(.connected)
                try await serve(t)
            } catch {
                // fall through to the close-code decision
            }
            task = nil
            cancelRunning()
            if Task.isCancelled { return }
            switch ReconnectPolicy.action(forClose: t.closeCode.rawValue) {
            case .reconnect: break
            case .signInAgain: await hooks.status(.signInAgain); loop = nil; return
            case .revoked: await hooks.status(.revoked); loop = nil; return
            case .stop: await hooks.status(.replaced); loop = nil; return
            case .updateRequired: await hooks.status(.updateRequired); loop = nil; return
            }
            let delay = policy.delay(attempt: attempt)
            attempt += 1
            await hooks.status(.waiting(until: Date().addingTimeInterval(delay)))
            await sleep(delay)
        }
    }

    /// Waits for the delay, or until reconnectNow.
    private func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wake = c
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                self.fireWake()
            }
        }
    }

    private func fireWake() {
        wake?.resume()
        wake = nil
    }

    /// The handshake must finish in 10 seconds; a watchdog closes the socket otherwise, which
    /// makes the pending receive fail.
    private func handshake(_ t: URLSessionWebSocketTask) async throws {
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            t.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        guard case .challenge(let challenge) = try await receive(t) else {
            throw ProtocolError.violation("expected challenge")
        }
        let signature = try identity.key.sign(
            DeviceIdentity.signatureInput(nonce: challenge.nonce, deviceID: identity.deviceID))
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let hello = Hello(
            deviceID: identity.deviceID, signature: signature,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            osVersion: v.patchVersion > 0
                ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)",
            tools: await hooks.tools(), state: await hooks.state())
        try await send(.hello(hello), on: t)
        guard case .welcome(let welcome) = try await receive(t) else {
            throw ProtocolError.violation("expected welcome")
        }
        heartbeat = TimeInterval(max(welcome.heartbeatIntervalS, 1))
    }

    private func serve(_ t: URLSessionWebSocketTask) async throws {
        let beats = Task { [heartbeat] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(heartbeat))
                if Task.isCancelled { return }
                await self.sendState()
                self.ping(t)
            }
        }
        defer { beats.cancel() }
        while !Task.isCancelled {
            switch try await receive(t) {
            case .call(let call): startCall(call, on: t)
            case .cancel(let c): running.removeValue(forKey: c.id)?.cancel()
            case .notice(let n): await hooks.notice(n)
            default: throw ProtocolError.violation("unexpected message")
            }
        }
    }

    /// A relay that stops answering pings is treated as gone, so a silently cut network is
    /// noticed within one heartbeat plus 10 seconds.
    private func ping(_ t: URLSessionWebSocketTask) {
        let id = UUID()
        pendingPing = id
        t.sendPing { error in
            Task { await self.pong(id, ok: error == nil, on: t) }
        }
        Task {
            try? await Task.sleep(for: .seconds(10))
            self.pingTimedOut(id, on: t)
        }
    }

    private func pong(_ id: UUID, ok: Bool, on t: URLSessionWebSocketTask) {
        guard pendingPing == id else { return }
        pendingPing = nil
        if !ok { t.cancel(with: .goingAway, reason: nil) }
    }

    private func pingTimedOut(_ id: UUID, on t: URLSessionWebSocketTask) {
        if pendingPing == id { t.cancel(with: .goingAway, reason: nil) }
    }

    private func startCall(_ call: Call, on t: URLSessionWebSocketTask) {
        running[call.id] = Task {
            let result = await hooks.call(call)
            if Task.isCancelled { return }  // cancelled by the relay: drop the result
            let msg = AgentMessage.result(
                CallResult(
                    id: call.id, content: result.content, structuredContent: result.structuredContent,
                    isError: result.isError))
            try? await self.send(msg, on: t)
            self.finished(call.id)
        }
    }

    private func finished(_ id: String) { running[id] = nil }

    private func cancelRunning() {
        running.values.forEach { $0.cancel() }
        running = [:]
    }
}
