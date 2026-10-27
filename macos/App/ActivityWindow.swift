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
    @State private var entries: [Activity] = []
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
            if let id = selection, let e = entries.first(where: { $0.id == id }) {
                Divider()
                details(e)
            }
            footer
        }
        .frame(minWidth: 640, minHeight: 360)
        .searchable(text: $query.text, placement: .toolbar, prompt: "Search Activity")
        .toolbar {
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
                Button("Export…", action: export)
                    .disabled(model.trace == nil || exporting)
                    .help("Save the entries shown as a JSON Lines file")
            }
        }
        .onChange(of: range) { applyRange() }
        .onChange(of: customFrom) { applyRange() }
        .onChange(of: customTo) { applyRange() }
        .task(id: query) {
            if !query.text.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }  // typing
            guard !Task.isCancelled else { return }
            await load(reset: true)
        }
        .task { await runCheck() }
    }

    private var table: some View {
        let broken = check?.brokenSeqs ?? []
        return Table(entries, selection: $selection) {
            TableColumn("When") { e in
                Text(e.at.formatted(date: .abbreviated, time: .standard))
                    .onAppear { if e.id == entries.last?.id { Task { await load(reset: false) } } }
            }
            TableColumn("Tool") { Text(verbatim: $0.tool).monospaced() }
            TableColumn("Result") { Text($0.isError ? "Error" : "OK") }
            TableColumn("Time Taken") { Text("\($0.durationMS) ms") }
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

    private func details(_ e: Activity) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Arguments").font(.headline)
                Text(verbatim: e.arguments).monospaced().textSelection(.enabled)
                Text("Result").font(.headline)
                Text(verbatim: e.result).monospaced().textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxHeight: 220)
    }

    @ViewBuilder private var footer: some View {
        let warnings = ActivityFormat.warnings(check: check, changed: changed)
        let notes = [
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
        let page = await Task.detached { try? reader.page(q, after: after, limit: limit) }.value
        loading = false
        guard q == query, let page else { return }
        if reset {
            entries = page.entries
            unreadable = page.unreadable
            changed = page.changed.count
            diskBytes = model.trace?.diskBytes ?? 0
        } else {
            entries += page.entries
            changed += page.changed.count
        }
        next = page.next
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

    static func footnote(bytes: Int64) -> String {
        "Every tool Claude ran on this Mac, and each app whose access you removed. This log stays on this Mac, encrypted, until you uninstall Latchkey. It uses \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
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
}
