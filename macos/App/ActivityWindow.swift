import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Activity window: every entry, a page at a time, with search, a tool and date filter,
/// Export…, the space the log uses, and what the tamper check found (FR-026, FR-203, FR-610 to
/// FR-615).
struct ActivityView: View {
    let model: AppModel
    @State private var query = ActivityQuery()
    @State private var range = ActivityRange.anyTime
    @State private var customFrom = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customTo = Date()
    /// What the table shows: small rows, never a screenshot's megabytes (2026-10-27: the window
    /// took about 10 seconds to appear over a 19 MB log of screenshots).
    @State private var rows: [ActivityRow] = []
    /// The entries behind the rows, for the details pane only.
    @State private var entries: [Activity.ID: Activity] = [:]
    @State private var detail: ActivityDetail?
    @State private var next: ActivityCursor?
    @State private var unreadable = 0
    @State private var changed = 0
    @State private var check: LogCheck?
    @State private var loading = false
    @State private var exporting = false
    @State private var diskBytes: Int64 = 0
    @State private var selection: Activity.ID?

    private static let pageSize = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if range == .custom {
                HStack {
                    DatePicker("From", selection: $customFrom, displayedComponents: .date)
                    DatePicker("To", selection: $customTo, displayedComponents: .date)
                    Spacer()
                }
                .padding(8)
                Divider()
            }
            table
            if let detail, detail.id == selection {
                Divider()
                details(detail)
            }
            footer
        }
        .frame(minWidth: 640, minHeight: 360)
        .searchable(text: $query.text, placement: .toolbar, prompt: "Search Activity")
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $query.show) {
                    Text("Everything").tag(ActivityShow.everything)
                    Divider()
                    Text("Claude’s Actions").tag(ActivityShow.actions)
                    Text("Latchkey Events").tag(ActivityShow.events)
                    Text("Left Behind").tag(ActivityShow.leftBehind)
                }
                .help("Show what Claude did, Latchkey’s own events, what Claude’s work left on this Mac, or everything")
            }
            ToolbarItem {
                Picker("Tool", selection: $query.tool) {
                    Text("All Tools").tag(String?.none)
                    Divider()
                    ForEach(ActivityFormat.toolNames(model.capabilities), id: \.self) {
                        Text(verbatim: $0).tag(String?.some($0))
                    }
                }
                .help("Show one tool only")
            }
            ToolbarItem {
                Picker("Date", selection: $range) {
                    ForEach(ActivityRange.allCases) { Text($0.title).tag($0) }
                }
                .help("Show entries from a period")
            }
            ToolbarItem {
                Button("Check Against Relay") { Task { await model.checkAudit() } }
                    .disabled(model.trace == nil || model.auditing)
                    .help("Compare this log with the relay’s record of the calls it sent to this Mac")
            }
            ToolbarItem {
                Button("Export…", action: export)
                    .disabled(model.trace == nil || exporting)
                    .help("Save the entries shown as a JSON Lines file")
            }
        }
        .onChange(of: range) { applyRange() }
        .onChange(of: model.auditLine) { Task { await load(reset: true) } }  // its event is new
        .onChange(of: customFrom) { applyRange() }
        .onChange(of: customTo) { applyRange() }
        .task(id: query) {
            if !query.text.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }  // typing
            guard !Task.isCancelled else { return }
            await load(reset: true)
        }
        .task { await runCheck() }
        // With the menu's line, shows where the time goes when the window is slow to appear.
        .onAppear { Diagnostics.activity.notice("Activity window shown") }
        .task(id: selection) { await showDetail() }
    }

    private var table: some View {
        let broken = check?.brokenSeqs ?? []
        return Table(rows, selection: $selection) {
            TableColumn("When") { e in
                Text(e.at.formatted(date: .abbreviated, time: .standard))
                    .onAppear { if e.id == rows.last?.id { Task { await load(reset: false) } } }
            }
            TableColumn("Tool") { e in
                Text(verbatim: e.kind == .event ? ActivityFormat.eventTitle(e.tool) : e.tool)
                    .monospaced(e.kind == .action)
            }
            TableColumn("Result") { e in
                if e.kind == .event {
                    Text(verbatim: e.summary).foregroundStyle(e.isError ? .red : .primary).lineLimit(1)
                        .help(e.summary)
                } else {
                    Text(e.isError ? "Error" : "OK")
                }
            }
            TableColumn("Time Taken") { e in Text(e.kind == .event ? "" : "\(e.durationMS) ms") }
            TableColumn("Claude App") { e in Text(verbatim: e.client ?? "").lineLimit(1) }  // FR-637
            TableColumn("Check") { e in
                if broken.contains(e.seq) {
                    Label("Changed", systemImage: "exclamationmark.triangle")
                } else if e.beforeCheck {
                    Text("Before check").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark").foregroundStyle(.secondary).accessibilityLabel("Checked")
                }
            }
            .width(min: 60, ideal: 90)
        }
    }

    private func details(_ e: ActivityDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if e.kind == .event {
                    Text(verbatim: ActivityFormat.eventTitle(e.tool)).font(.headline)
                    Text(verbatim: e.result).textSelection(.enabled)
                } else {
                    Text("Arguments").font(.headline)
                    Text(verbatim: e.arguments).monospaced().textSelection(.enabled)
                    Text("Result").font(.headline)
                    Text(verbatim: e.result).monospaced().textSelection(.enabled)
                    if let client = e.client {
                        Text(verbatim: "From \(client)").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let id = e.callID {
                        Text(verbatim: "Call \(id)").font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxHeight: 220)
    }

    @ViewBuilder private var footer: some View {
        let warnings =
            (ActivityFormat.auditWarning(model.audit).map { [$0] } ?? [])
            + ActivityFormat.warnings(check: check, changed: changed)
        let notes = [
            model.audit == nil ? model.auditLine : nil,
            model.trace.flatMap { ActivityFormat.latestNote($0.latestState) },
            ActivityFormat.unreadableNote(unreadable),
            ActivityFormat.beforeCheckNote(check?.beforeCheck ?? 0),
        ].compactMap { $0 }
        if let problem = model.activityLog.problem {
            Label(problem, systemImage: "exclamationmark.triangle").padding(.horizontal, 8).padding(.top, 8)
        }
        ForEach(warnings, id: \.self) {
            Label($0, systemImage: "exclamationmark.triangle.fill").padding(.horizontal, 8).padding(.top, 8)
        }
        ForEach(notes, id: \.self) {
            Text($0).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 8)
        }
        HStack {
            Text(ActivityFormat.footnote(bytes: diskBytes))
            Spacer()
            if loading || exporting { ProgressView().controlSize(.small) }
        }
        .font(.footnote).foregroundStyle(.secondary).padding(8)
    }

    private func applyRange() {
        let span = range.span(now: Date(), customFrom: customFrom, customTo: customTo)
        query.from = span.from
        query.to = span.to
    }

    /// The first page for the current search, or the next one after what is shown.
    private func load(reset: Bool) async {
        guard let reader = model.trace?.reader else { return }
        if !reset && (loading || next == nil) { return }
        let q = query
        let after = reset ? nil : next
        let limit = Self.pageSize
        loading = true
        let started = Date()
        let loaded = await Task.detached { () -> (ActivityPage, [ActivityRow])? in
            guard let page = try? reader.page(q, after: after, limit: limit) else { return nil }
            return (page, page.entries.map(ActivityRow.init))
        }.value
        loading = false
        guard q == query, let (page, newRows) = loaded else { return }
        let byID = Dictionary(page.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if reset {
            rows = newRows
            entries = byID
            unreadable = page.unreadable
            changed = page.changed.count
            diskBytes = model.trace?.diskBytes ?? 0
            Diagnostics.activity.notice(
                "Activity window: first page of \(newRows.count) in \(Int(Date().timeIntervalSince(started) * 1000)) ms"
            )
        } else {
            rows += newRows
            entries.merge(byID) { a, _ in a }
            changed += page.changed.count
        }
        next = page.next
    }

    /// The selected entry's details, made off the main thread: a screenshot is shown as one line
    /// and long text is cut, so the pane never lays out megabytes.
    private func showDetail() async {
        guard let id = selection, let e = entries[id] else {
            detail = nil
            return
        }
        detail = await Task.detached { ActivityDetail(e) }.value
    }

    private func runCheck() async {
        guard let trace = model.trace else { return }
        let reader = trace.reader
        let expected = trace.expected
        check = await Task.detached { try? reader.check(expected: expected) }.value
    }

    /// Export… (FR-615): what the search and filters select, to a file the Owner picks.
    private func export() {
        guard let reader = model.trace?.reader else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json]
        panel.nameFieldStringValue = ActivityFormat.exportName(Date())
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let q = query
        exporting = true
        Task {
            let outcome = await Task.detached { Result { try reader.export(q, to: url) } }.value
            exporting = false
            if case .failure(let error) = outcome {
                let alert = NSAlert()
                alert.messageText = "The activity couldn’t be exported"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

/// The date filter's choices (FR-614).
enum ActivityRange: String, CaseIterable, Identifiable {
    case anyTime, today, week, month, year, custom
    var id: Self { self }

    var title: String {
        switch self {
        case .anyTime: "Any Time"
        case .today: "Today"
        case .week: "Last 7 Days"
        case .month: "Last 30 Days"
        case .year: "Last 12 Months"
        case .custom: "Custom Range"
        }
    }

    /// From the start of the first day to the end of the last (custom: both days included).
    func span(now: Date, customFrom: Date, customTo: Date, calendar: Calendar = .current) -> (from: Date?, to: Date?) {
        let today = calendar.startOfDay(for: now)
        func daysBack(_ n: Int) -> Date? { calendar.date(byAdding: .day, value: -n, to: today) }
        switch self {
        case .anyTime: return (nil, nil)
        case .today: return (today, nil)
        case .week: return (daysBack(6), nil)
        case .month: return (daysBack(29), nil)
        case .year: return (calendar.date(byAdding: .year, value: -1, to: today), nil)
        case .custom:
            let from = calendar.startOfDay(for: min(customFrom, customTo))
            let last = calendar.startOfDay(for: max(customFrom, customTo))
            return (from, calendar.date(byAdding: .day, value: 1, to: last))
        }
    }
}

extension ActivityFormat {
    /// Every tool the Mac can run, whatever its level, and the Owner's removals (FR-614).
    static func toolNames(_ registry: CapabilityRegistry) -> [String] {
        let tools = registry.capabilities.flatMap { ($0.readTools + $0.writeTools).map(\.tool.name) }
        return Array(Set(tools + ["remove_access"])).sorted()
    }

    /// What an event's category is called in the window.
    static func eventTitle(_ category: String) -> String {
        switch EventCategory(rawValue: category) {
        case .app: "Latchkey"
        case .connection: "Connection"
        case .keepAwake: "Keep-Awake"
        case .helper: "Keep-Awake Helper"
        case .power: "Sleep and Power"
        case .permissions: "Permissions"
        case .setup: "Setup"
        case .pause: "Pause"
        case .pairing: "Pairing"
        case .activity: "Activity Log"
        case .audit: "Relay Check"
        case .leftovers: "Left Behind"
        case nil: category
        }
    }

    /// The warning while the last comparison with the relay found calls missing (FR-634); nil
    /// when all matched or none was made.
    static func auditWarning(_ comparison: AuditComparison?) -> String? {
        guard let comparison, !comparison.allMatch else { return nil }
        let mac = comparison.missingOnMac.count
        let relay = comparison.missingOnRelay.count
        var parts: [String] = []
        if mac > 0 {
            parts.append(
                mac == 1 ? "1 call the relay sent isn’t in this log" : "\(mac) calls the relay sent aren’t in this log")
        }
        if relay > 0 {
            parts.append(
                relay == 1
                    ? "1 call in this log isn’t in the relay’s record"
                    : "\(relay) calls in this log aren’t in the relay’s record")
        }
        return "The activity log and the relay disagree: " + parts.joined(separator: ", and ")
            + ". Choose Latchkey Events to see which."
    }

    static func footnote(bytes: Int64) -> String {
        "Every tool Claude ran on this Mac, each app whose access you removed, and Latchkey’s own events. This log stays on this Mac, encrypted, until you uninstall Latchkey. It uses \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
    }

    /// What the tamper check found (FR-612, FR-613), most serious first.
    static func warnings(check: LogCheck?, changed: Int) -> [String] {
        var out: [String] = []
        if let check, check.missingNewer {
            if let last = check.lastPresent {
                out.append(
                    "Newer entries are missing from the activity log. Entries after \(last.formatted(date: .abbreviated, time: .shortened)) were removed outside Latchkey, or lost when the Mac shut down unexpectedly."
                )
            } else {
                out.append(
                    "Entries are missing from the activity log. They were removed outside Latchkey, or lost when the Mac shut down unexpectedly."
                )
            }
        }
        if let first = check?.broken.first {
            out.append(
                "The activity log was changed outside Latchkey. Starting with the entry from \(first.at.formatted(date: .abbreviated, time: .standard)), entries were removed, changed, or put out of order. Entries that don’t check out are marked “Changed”."
            )
        }
        switch changed {
        case ..<1: break
        case 1: out.append("1 entry was changed outside Latchkey and can’t be shown.")
        default: out.append("\(changed) entries were changed outside Latchkey and can’t be shown.")
        }
        return out
    }

    /// The line about the Keychain's record of the newest entry (FR-613); nil when all is well.
    static func latestNote(_ state: LatestEntryState) -> String? {
        switch state {
        case .ok: nil
        case .missing:
            "Latchkey’s record of the newest entry is missing from the Keychain, so it can’t tell whether entries were removed from the end of the log before now."
        case .unreadable:
            "Latchkey couldn’t read its record of the newest entry in the Keychain, so it can’t check right now whether newer entries were removed. It tries again each time it opens."
        }
    }

    static func beforeCheckNote(_ count: Int) -> String? {
        count > 0
            ? "Entries marked “Before check” were recorded before Latchkey began checking the log for changes." : nil
    }

    static func exportName(_ date: Date) -> String {
        "Latchkey Activity \(date.formatted(.iso8601.year().month().day())).jsonl"
    }

    /// The most of an entry's arguments or result the details pane lays out.
    static let previewLimit = 10_000

    /// Text for the details pane: images in a tool result (base64, often hundreds of kilobytes)
    /// become one line naming their type and size, and what is still longer than `previewLimit`
    /// is cut, saying how much more there is. Export… keeps everything.
    static func preview(_ text: String) -> String {
        var shown = text
        if text.contains("\"image\""),
            let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
            let data = try? JSONSerialization.data(
                withJSONObject: withoutImages(value), options: [.fragmentsAllowed, .withoutEscapingSlashes]),
            let short = String(data: data, encoding: .utf8)
        {
            shown = short
        }
        let scalars = shown.unicodeScalars
        let count = scalars.count
        guard count > previewLimit else { return shown }
        return String(String.UnicodeScalarView(scalars.prefix(previewLimit)))
            + "… (\(count - previewLimit) more characters; Export… saves the whole entry)"
    }

    private static func withoutImages(_ value: Any) -> Any {
        if let array = value as? [Any] { return array.map(withoutImages) }
        guard var object = value as? [String: Any] else { return value }
        if object["type"] as? String == "image", let data = object["data"] as? String {
            let bytes = Int64(data.utf8.count / 4 * 3)
            let type = object["mimeType"] as? String ?? "image"
            object["data"] =
                "[\(type) image, \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)), not shown]"
            return object
        }
        return object.mapValues(withoutImages)
    }
}

/// One row of the Activity window's table: only what the row shows, so the table never holds
/// a screenshot's megabytes (2026-10-27).
struct ActivityRow: Identifiable, Equatable, Sendable {
    static let summaryLimit = 200

    var id: Activity.ID
    var at: Date
    var tool: String
    var kind: ActivityKind
    var isError: Bool
    var durationMS: Int
    var seq: Int
    /// An event's text, cut to `summaryLimit`; "" for an action.
    var summary: String
    var client: String?

    var beforeCheck: Bool { seq == 0 }

    init(_ a: Activity) {
        id = a.id
        at = a.at
        tool = a.tool
        kind = a.kind
        isError = a.isError
        durationMS = a.durationMS
        seq = a.seq
        summary = a.kind == .event ? ActivityFormat.clip(a.result, Self.summaryLimit) : ""
        client = a.client
    }
}

/// The details pane's text for one entry, made off the main thread.
struct ActivityDetail: Sendable, Equatable {
    var id: Activity.ID
    var kind: ActivityKind
    var tool: String
    var arguments: String
    var result: String
    var client: String?
    var callID: String?

    init(_ a: Activity) {
        id = a.id
        kind = a.kind
        tool = a.tool
        arguments = ActivityFormat.preview(a.arguments)
        result = a.kind == .event ? a.result : ActivityFormat.preview(a.result)
        client = a.client
        callID = a.callID
    }
}

/// The Show filter's choices (FR-633, FR-640).
enum ActivityShow: Hashable {
    case everything, actions, events, leftBehind
}

extension ActivityQuery {
    /// The Show filter as kind and tool: Left Behind is the events of that category.
    var show: ActivityShow {
        get {
            switch kind {
            case nil: .everything
            case .action: .actions
            case .event: tool == EventCategory.leftovers.rawValue ? .leftBehind : .events
            }
        }
        set {
            if tool == EventCategory.leftovers.rawValue { tool = nil }
            switch newValue {
            case .everything: kind = nil
            case .actions: kind = .action
            case .events: kind = .event
            case .leftBehind:
                kind = .event
                tool = EventCategory.leftovers.rawValue
            }
        }
    }
}
