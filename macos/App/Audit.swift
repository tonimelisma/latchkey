import Foundation

// The comparison of the Mac's activity log with the relay's audit of this Mac, by call id
// (spec 001 FR-634, agent-protocol.md "Audit comparison"). No AppKit and no storage here: the
// rules are pure functions, unit-tested in AuditTrailTests.

/// One action in the Mac's log that carries a call id, from the fields kept in the clear.
struct MacCall: Equatable, Sendable {
    var callID: String
    /// The device ID the call came through; "" when not known.
    var device: String
    var at: Date
}

/// What fetching the relay's audit gave.
enum AuditFetch: Equatable, Sendable {
    case entries([AuditEntry])
    /// A page didn't come within its deadline (Constitution II).
    case noAnswer
    /// A page larger than asked for, with an entry from before its `since`, or whose `next_since`
    /// doesn't move on past its newest entry; or more entries than the Mac collects in all.
    case badAnswer
    case notConnected

    /// The event's text when the comparison couldn't be made; nil when it could.
    var problem: String? {
        switch self {
        case .entries: nil
        case .noAnswer: "Audit check not possible: the relay didn't answer"
        case .badAnswer: "Audit check not possible: the relay's answer was malformed"
        case .notConnected: "Audit check not possible: not connected to the relay"
        }
    }
}

/// Asks for the relay's audit a page at a time, from the start, until the last page.
enum AuditPaging {
    static let pageSize = 1000
    /// A million calls: far beyond any Mac, and an end however the relay answers.
    static let maxEntries = 1_000_000

    /// `page(since)` is one request for at most `limit` entries, nil when it got no answer in
    /// time. The relay's answers are checked before anything is kept (security review,
    /// 2026-10-27): a page larger than asked for, an entry from before `since`, or a next page
    /// that doesn't start after the newest entry (and after `since`) is a malformed answer, so a
    /// relay can't make the Mac collect without end or loop over pages it already has; and no
    /// more than `maxEntries` are collected in all.
    static func fetch(
        limit: Int = pageSize, maxEntries: Int = maxEntries, _ page: @Sendable (Int64) async -> AuditPage?
    ) async -> AuditFetch {
        var all: [AuditEntry] = []
        var since: Int64 = 0
        // Empty pages that keep moving on would never end either.
        for _ in 0...(maxEntries / max(limit, 1) + 1) {
            guard let answer = await page(since) else { return .noAnswer }
            guard answer.entries.count <= limit, answer.entries.allSatisfy({ $0.at >= since }),
                answer.entries.allSatisfy({ $0.callID.isEmpty || AuditComparison.isValidCallID($0.callID) })
            else {
                return .badAnswer
            }
            guard all.count + answer.entries.count <= maxEntries else { return .badAnswer }
            all += answer.entries
            guard let next = answer.nextSince else { return .entries(all) }
            let newest = answer.entries.map(\.at).max() ?? since
            guard next > since, next > newest else { return .badAnswer }
            since = next
        }
        return .badAnswer
    }
}

/// The result of comparing the two sides.
struct AuditComparison: Equatable, Sendable {
    /// Calls on both sides.
    var matched = 0
    /// Calls the relay sent to the Mac (any outcome but `offline`) that aren't in the Mac's log.
    var missingOnMac: [AuditEntry] = []
    /// Calls in the Mac's log that aren't in the relay's audit.
    var missingOnRelay: [MacCall] = []
    /// Left out and counted: calls from before call ids (the relay's rows with no id, the Mac's
    /// actions without one or with an id of the older per-connection kind such as "c_1").
    var beforeCallIDs = 0
    /// Left out and counted: the Mac's calls through an earlier pairing (another device ID, so
    /// in another device's audit on the relay).
    var otherPairings = 0
    /// Left out and counted: calls on one side only that are recent enough to be still running.
    var stillRunning = 0
    /// Ids recorded more than once in the Mac's log, and listed more than once by the relay: each
    /// call has one id, so a repeat is a discrepancy (security review, 2026-10-27).
    var twiceOnMac: [String] = []
    var twiceOnRelay: [String] = []

    var allMatch: Bool { missingOnMac.isEmpty && missingOnRelay.isEmpty && twiceOnMac.isEmpty && twiceOnRelay.isEmpty }

    /// Since FR-632 every call id is `call_` and 1 to 64 letters or digits (the relay makes 26
    /// base32 characters). Ids are compared whole, never cut, so this bound is checked instead.
    static func isValidCallID(_ id: String) -> Bool {
        id.wholeMatch(of: /call_[0-9A-Za-z]{1,64}/) != nil
    }

    /// A call on one side only this recent may still be running or not yet recorded on the
    /// other: the relay caps a call's deadline at 60 seconds, and a call the relay gave up on can
    /// finish on the Mac a little later.
    static let grace: TimeInterval = 120

    /// Ids the relay makes since FR-632: `call_` and random base32.
    static func isGlobal(_ id: String) -> Bool { id.hasPrefix("call_") }

    static func compare(
        relay: [AuditEntry], mac: [MacCall], macWithoutIDs: Int, device: String, now: Date,
        grace: TimeInterval = AuditComparison.grace
    ) -> AuditComparison {
        var c = AuditComparison()
        c.beforeCallIDs = macWithoutIDs
        let recent = now.addingTimeInterval(-grace)
        var macIDs = Set<String>()
        var macCalls: [MacCall] = []
        for m in mac {
            if !isGlobal(m.callID) {
                c.beforeCallIDs += 1
            } else if !m.device.isEmpty && m.device != device {
                c.otherPairings += 1
            } else if macIDs.insert(m.callID).inserted {
                macCalls.append(m)
            } else if !c.twiceOnMac.contains(m.callID) {
                c.twiceOnMac.append(m.callID)
            }
        }
        var relayIDs = Set<String>()
        for r in relay where r.outcome != .offline {
            guard !r.callID.isEmpty else {
                c.beforeCallIDs += 1
                continue
            }
            guard relayIDs.insert(r.callID).inserted else {
                if !c.twiceOnRelay.contains(r.callID) { c.twiceOnRelay.append(r.callID) }
                continue
            }
            if macIDs.contains(r.callID) {
                c.matched += 1
            } else if r.date > recent {
                c.stillRunning += 1
            } else {
                c.missingOnMac.append(r)
            }
        }
        // A call the relay recorded as offline never reached the Mac; one the Mac has anyway is
        // still the relay's, so it isn't missing there.
        let offline = Set(relay.filter { $0.outcome == .offline }.map(\.callID))
        for m in macCalls where !relayIDs.contains(m.callID) && !offline.contains(m.callID) {
            if m.at > recent { c.stillRunning += 1 } else { c.missingOnRelay.append(m) }
        }
        return c
    }

    /// How many missing calls an event names per side; the rest are counted. The event is kept
    /// forever and its ids come from the relay, so neither may make it huge (security review,
    /// 2026-10-27).
    static let namedPerSide = 20

    /// A relay-supplied value (call id, tool, Claude app name) cut to 64 characters.
    /// Bounded in Unicode scalars and bytes, not characters: one character can carry thousands of
    /// combining marks (security review, 2026-10-27). At most 64 scalars and 256 bytes.
    static func clip(_ s: String) -> String {
        guard s.unicodeScalars.count > 64 || s.utf8.count > 256 else { return s }
        var kept = String.UnicodeScalarView()
        var bytes = 0
        for scalar in s.unicodeScalars {
            let size = String(scalar).utf8.count
            guard kept.count < 63, bytes + size <= 253 else { break }  // room for "…" (3 bytes)
            kept.append(scalar)
            bytes += size
        }
        return String(kept) + "…"
    }

    private static func listed(_ items: [String]) -> String {
        let named = items.prefix(namedPerSide).joined(separator: ", ")
        return items.count > namedPerSide ? named + ", and \(items.count - namedPerSide) more" : named
    }

    /// The event's text, naming the missing calls (up to `namedPerSide` per side); `tools` names
    /// the Mac's missing ones.
    func summary(tools: [String: String]) -> String {
        let format = ISO8601DateFormatter()
        var parts: [String] = []
        let calls = matched == 1 ? "1 call matches" : "\(matched) calls match"
        parts.append(allMatch ? "all \(calls)" : calls)
        if !missingOnMac.isEmpty {
            parts.append(
                "missing on the Mac: "
                    + Self.listed(
                        missingOnMac.map {
                            "\(Self.clip($0.callID)) (\(Self.clip($0.tool)), \(format.string(from: $0.date)))"
                        }))
        }
        if !missingOnRelay.isEmpty {
            parts.append(
                "missing on the relay: "
                    + Self.listed(
                        missingOnRelay.map {
                            "\(Self.clip($0.callID)) (\(Self.clip(tools[$0.callID] ?? "unknown tool")), \(format.string(from: $0.at)))"
                        }))
        }
        if !twiceOnMac.isEmpty { parts.append("recorded twice on the Mac: " + Self.listed(twiceOnMac)) }
        if !twiceOnRelay.isEmpty { parts.append("listed twice by the relay: " + Self.listed(twiceOnRelay)) }
        if beforeCallIDs > 0 {
            parts.append("\(Self.count(beforeCallIDs)) from before call ids left out")
        }
        if otherPairings > 0 {
            parts.append(
                otherPairings == 1
                    ? "1 call from an earlier pairing left out"
                    : "\(otherPairings) calls from earlier pairings left out")
        }
        if stillRunning > 0 { parts.append("\(Self.count(stillRunning)) still running left out") }
        return "Audit check: " + parts.joined(separator: "; ")
    }

    private static func count(_ n: Int) -> String { n == 1 ? "1 call" : "\(n) calls" }
}

/// Calls whose id isn't the one shape FR-632 allows are refused before they run: the id is the
/// key the audit comparison matches on, so it's checked rather than cut (security review,
/// 2026-10-27).
enum CallCheck {
    static func refusal(callID: String) -> ToolResult? {
        AuditComparison.isValidCallID(callID)
            ? nil
            : .text(
                "Latchkey refused this call: the relay gave it an id of the wrong form. Nothing was done.",
                isError: true)
    }
}
