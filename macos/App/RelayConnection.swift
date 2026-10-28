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
    /// 4001 "account suspended": still paired; retried every 5 minutes (FR-204).
    case suspended

    /// The status before the connection has reported anything: a Mac with a stored pairing is
    /// paired from the first moment, so a fully set up Mac starts with no window (FR-205).
    static func atStart(paired: Bool) -> ConnectionStatus { paired ? .connecting : .notPaired }

    /// Whether this Mac belongs to an account. Only "not paired" and "revoked" send the Owner
    /// back to the Connect step of setup.
    var isPaired: Bool { self != .notPaired && self != .revoked }
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
    /// Each time a connection is established (after `welcome`); not awaited by the connection.
    var connected: @Sendable () async -> Void = {}
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
    /// Audit pages asked for and not yet answered, by request id (FR-634).
    private var auditWaiters: [String: CheckedContinuation<AuditPage?, Never>] = [:]
    private var auditRequests = 0
    /// How long one page may take (Constitution II).
    static let auditPageDeadline: Duration = .seconds(15)

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

    /// The relay's whole audit of this Mac, a page at a time (FR-634). Each page has a deadline;
    /// the connection ending answers every page still waiting.
    func fetchAudit() async -> AuditFetch {
        guard task != nil else { return .notConnected }
        let fetched = await AuditPaging.fetch { since in await self.auditPage(since: since) }
        if fetched == .noAnswer, task == nil { return .notConnected }
        return fetched
    }

    private func auditPage(since: Int64) async -> AuditPage? {
        guard let task else { return nil }
        auditRequests += 1
        let id = "a\(auditRequests)"
        return await withCheckedContinuation { (c: CheckedContinuation<AuditPage?, Never>) in
            auditWaiters[id] = c
            Task {
                do {
                    try await send(
                        .auditRequest(AuditRequest(id: id, since: since, limit: AuditPaging.pageSize)), on: task)
                } catch {
                    self.answerAudit(id, nil)
                    return
                }
                try? await Task.sleep(for: Self.auditPageDeadline)
                self.answerAudit(id, nil)
            }
        }
    }

    private func answerAudit(_ id: String, _ page: AuditPage?) {
        auditWaiters.removeValue(forKey: id)?.resume(returning: page)
    }

    /// The connection ended: no page can come. Only relays that answer `audit_request` are
    /// supported (Toni, 2026-10-27: no backwards compatibility).
    private func endAudits(closeCode: Int) {
        let waiting = auditWaiters
        auditWaiters = [:]
        for c in waiting.values { c.resume(returning: nil) }
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
        var suspended = false
        while !Task.isCancelled {
            // A suspended Mac keeps saying so while it tries again (FR-204).
            if !suspended { await hooks.status(.connecting) }
            let t = session.webSocketTask(with: Self.agentURL(relay: identity.relayURL), protocols: ["latchkey.v1"])
            t.maximumMessageSize = 4 << 20
            task = t
            t.resume()
            do {
                try await handshake(t)
                stateFrames.reset()
                attempt = 0
                suspended = false
                await hooks.status(.connected)
                EventLog.shared.record(.connection, "Connected to the relay")
                let connected = hooks.connected
                Task { await connected() }
                try await serve(t)
            } catch {
                // fall through to the close-code decision
                EventLog.shared.record(.connection, "Connection ended: \(error.localizedDescription)")
            }
            task = nil
            endAudits(closeCode: t.closeCode.rawValue)
            await calls.cancelAll()
            if Task.isCancelled { return }
            let reason = t.closeReason.map { String(decoding: $0, as: UTF8.self) }
            let next = policy.next(afterClose: t.closeCode.rawValue, reason: reason, attempt: attempt)
            suspended = next.show == .suspended
            EventLog.shared.record(
                .connection,
                Self.closeLine(
                    code: t.closeCode.rawValue, reason: reason, retryAfter: next.retryAfter, attempt: attempt))
            guard let delay = next.retryAfter else {
                if let show = next.show { await hooks.status(show) }
                loop = nil
                return
            }
            attempt += 1
            await hooks.status(next.show ?? .waiting(until: Date().addingTimeInterval(delay)))
            await sleep(delay)  // or until a wake or a network change (reconnectNow)
        }
    }

    /// The event for a closed connection: code, reason, and what happens next (FR-620, FR-633).
    static func closeLine(code: Int, reason: String?, retryAfter: TimeInterval?, attempt: Int) -> String {
        let reasonText = reason.map { $0.isEmpty ? "" : " \($0)" } ?? ""
        let next = retryAfter.map { "retrying in \(Int($0)) s" } ?? "not retrying"
        return "Closed with code \(code)\(reasonText); \(next) (attempt \(attempt + 1))"
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
            case .audit(let page): answerAudit(page.id, page)
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
