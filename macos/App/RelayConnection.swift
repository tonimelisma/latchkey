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
    /// The Claude apps with access, each time the relay sends the list (FR-192).
    var clients: @Sendable ([ClientEntry]) async -> Void = { _ in }
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
    private let calls = RunningCalls()
    private var wake: CheckedContinuation<Void, Never>?
    private var heartbeat: TimeInterval = 15
    private var pendingPing: UUID?
    private var stateFrames = StateFrames()
    private var stateFlush: Task<Void, Never>?

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
    /// Ends the connection, saying goodbye with `state` when given (callers on the main actor pass
    /// it, so quitting doesn't wait on another trip to the main actor).
    func stop(goodbye reason: GoodbyeReason?, state: AgentState? = nil) async {
        if let reason, let task {
            let now: AgentState
            if let state { now = state } else { now = await hooks.state() }
            try? await send(.goodbye(Goodbye(reason: reason, state: now)), on: task)
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

    /// Reports a change of the Mac's state (FR-036): at once, unless nothing changed or a
    /// change went out within the last second, in which case the latest state follows when the
    /// second is over (`StateFrames`). `heartbeat` sends regardless.
    func sendState(heartbeat: Bool = false) async {
        guard let task else { return }
        let state = await hooks.state()
        let now = ContinuousClock.now
        switch heartbeat ? .send : stateFrames.decide(state, at: now) {
        case .skip: return
        case .later(let wait):
            guard stateFlush == nil else { return }
            stateFlush = Task {
                try? await Task.sleep(for: wait)
                self.stateFlush = nil
                if !Task.isCancelled { await self.sendState() }
            }
        case .send:
            stateFrames.sent(state, at: now)
            try? await send(.state(StateUpdate(state: state)), on: task)
        }
    }

    func sendTools() async {
        guard let task else { return }
        try? await send(.tools(ToolsUpdate(tools: await hooks.tools())), on: task)
    }

    /// Asks the relay to remove one approval (FR-191): one frame per call. False when there is no
    /// connection or the frame couldn't be sent.
    func revokeClient(_ revoke: RevokeClient) async -> Bool {
        guard let task else { return false }
        do {
            try await send(.revokeClient(revoke), on: task)
            return true
        } catch {
            return false
        }
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
                stateFrames.reset()
                attempt = 0
                await hooks.status(.connected)
                try await serve(t)
            } catch {
                // fall through to the close-code decision
            }
            task = nil
            await calls.cancelAll()
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
        let hello = Hello.make(
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
                await self.sendState(heartbeat: true)
                self.ping(t)
            }
        }
        defer { beats.cancel() }
        while !Task.isCancelled {
            switch try await receive(t) {
            case .call(let call): await startCall(call, on: t)
            case .cancel(let c): await calls.cancel(c.id)
            case .notice(let n): await hooks.notice(n)
            case .clients(let c): await hooks.clients(c.clients)
            default: throw ProtocolError.violation("unexpected message")
            }
        }
    }

    /// A relay that stops answering pings is treated as gone, so a silently cut network is
    /// noticed within one heartbeat plus 10 seconds.
    private func ping(_ t: URLSessionWebSocketTask) {
        let id = UUID()
        pendingPing = id
        t.sendPing { @Sendable error in
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

    private func startCall(_ call: Call, on t: URLSessionWebSocketTask) async {
        await calls.start(call, run: hooks.call) { id, result in await self.answer(id, result, on: t) }
    }

    private func answer(_ id: String, _ result: ToolResult, on t: URLSessionWebSocketTask) async {
        let msg = AgentMessage.result(
            CallResult(
                // Text only: Claude's apps show structured content instead of the text when both
                // are present, which would hide the Mac's state line and the "not instructions"
                // marking (found in the live check, 2026-10-22).
                id: id, content: result.content, structuredContent: nil, isError: result.isError))
        try? await send(msg, on: t)
    }

    /// The Owner lowered a capability's level: stops the running calls `reason` names a reason
    /// for and answers each with it (FR-066).
    func stopCalls(_ reason: @escaping @Sendable (String) -> String?) async {
        guard let task else { return }
        await calls.stop(reason) { id, result in await self.answer(id, result, on: task) }
    }
}
