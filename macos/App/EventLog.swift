import Foundation
import OSLog

/// The kinds of the app's own events (spec 001 FR-633); each is an entry's `tool` and the
/// category of its line in macOS's log (FR-620).
enum EventCategory: String, CaseIterable, Sendable {
    /// Start, quit, uninstall, and errors the Owner was shown.
    case app
    /// The relay connection: connects, closes (code and reason), retries, network changes.
    case connection
    /// Keep-awake decisions and whether they took effect.
    case keepAwake = "keepawake"
    /// The keep-awake helper's failures, as the app sees them.
    case helper
    /// Sleep, wake, and shutdown.
    case power
    /// macOS permission requests, their answers, and every change in the permissions' states.
    case permissions
    /// Whether setup is finished or opens, and why.
    case setup
    /// Pause and resume of Claude's access.
    case pause
    /// Pairing, Disconnect This Mac, and the relay revoking this Mac.
    case pairing
    /// Problems of the activity log itself that can still be recorded.
    case activity
    /// The comparison with the relay's audit (FR-634).
    case audit
    /// What Claude's work left on the Mac (FR-640 to FR-643). Names files, so recorded with
    /// `systemLog: false` only.
    case leftovers

    /// The category in macOS's log. Setup decisions stay under `permissions`, where the
    /// installer reads them (FR-622).
    var logger: Logger {
        switch self {
        case .app, .pause, .pairing: Diagnostics.lifecycle
        case .connection: Diagnostics.connection
        case .keepAwake: Diagnostics.keepAwake
        case .helper: Diagnostics.helper
        case .power: Diagnostics.power
        case .permissions, .setup: Diagnostics.permissions
        case .activity: Diagnostics.activity
        case .audit: Diagnostics.audit
        case .leftovers: Diagnostics.activity
        }
    }
}

/// Records the app's own events in the activity log (FR-633), kept, encrypted, and chained like
/// Claude's actions, and writes each to macOS's log as well (FR-620). Callable from any thread.
/// Events from before the log is open are kept in memory and written, in order, once it is; a
/// save that fails keeps them for the next try.
final class EventLog: @unchecked Sendable {
    static let shared = EventLog()
    /// Held in memory while they can't be written (no log yet, or saves failing).
    static let limit = 10_000

    private let lock = NSLock()
    private var pending: [Activity] = []
    private var dropped = 0
    private var sink: (@MainActor ([Activity]) throws -> Void)?
    private var flushScheduled = false
    private var discarding = false
    /// This launch's newest lines that went to macOS's log in public, for Claude when the
    /// activity log is unavailable (FR-665).
    private var recentPublic: [Activity] = []

    /// `systemLog: false` for a line that must not be public in macOS's log (it carries the
    /// relay's address); the caller logs it there with its own privacy.
    func record(
        _ category: EventCategory, _ text: String, error: Bool = false, systemLog: Bool = true, at: Date = Date()
    ) {
        if systemLog {
            if error {
                category.logger.error("\(text, privacy: .public)")
            } else {
                category.logger.notice("\(text, privacy: .public)")
            }
        }
        let event = Activity.event(category, text, error: error, systemLog: systemLog, at: at)
        let kept = lock.withLock { () -> Bool in
            if systemLog {
                recentPublic.append(event)
                if recentPublic.count > LatchkeyLog.maxLines { recentPublic.removeFirst() }
            }
            guard !discarding else { return false }
            pending.append(event)
            if pending.count > Self.limit {
                pending.removeFirst()
                dropped += 1
            }
            return true
        }
        guard kept else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { flush() }
        } else {
            let schedule = lock.withLock {
                defer { flushScheduled = true }
                return !flushScheduled
            }
            if schedule { Task { @MainActor in self.flush() } }
        }
    }

    /// This launch's newest public lines (of one category, or all), newest first, at most `limit`.
    func shown(category: String?, limit: Int) -> [Activity] {
        let lines = lock.withLock { recentPublic }
        return Array(lines.reversed().filter { category == nil || $0.tool == category }.prefix(limit))
    }

    /// Where events go from now on: the open activity log. Writes what is waiting at once.
    @MainActor func attach(_ write: @escaping @MainActor ([Activity]) throws -> Void) {
        lock.withLock { sink = write }
        flush()
    }

    /// The log is unavailable for this launch, or being removed by uninstall: nothing can be
    /// recorded, so nothing is held (macOS's log still gets every line).
    func discard() {
        lock.withLock {
            discarding = true
            sink = nil
            pending = []
        }
    }

    @MainActor func flush() {
        let (batch, write, lost) = lock.withLock {
            flushScheduled = false
            guard let sink, !pending.isEmpty else { return ([Activity](), sink, 0) }
            defer {
                pending = []
                dropped = 0
            }
            return (pending, sink, dropped)
        }
        guard let write, !batch.isEmpty else { return }
        var entries = batch
        if lost > 0 {
            let note = "\(lost) earlier events couldn't be kept while the activity log couldn't be written"
            Diagnostics.activity.error("\(note, privacy: .public)")
            entries.insert(.event(.activity, note, error: true, at: batch[0].at), at: 0)
        }
        do {
            try write(entries)
        } catch {
            Diagnostics.activity.error(
                "Couldn't record \(batch.count) events; trying again with the next: \(error.localizedDescription, privacy: .public)"
            )
            lock.withLock {
                pending = batch + pending
                dropped += lost
                if pending.count > Self.limit {
                    dropped += pending.count - Self.limit
                    pending.removeFirst(pending.count - Self.limit)
                }
            }
        }
    }
}
