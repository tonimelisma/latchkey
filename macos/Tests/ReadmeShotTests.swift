import AppKit
import SwiftUI
import Testing

@testable import Latchkey

/// The README's pictures, drawn by the app's own views (scripts/readme-shots.sh). Nothing in them
/// comes from a real Mac: the setup is a fresh one, and the Permissions tab is filled in with
/// `showEverythingAllowed`. Without README_SHOTS_DIR, each is only drawn.
@MainActor @Suite struct ReadmeShotTests {
    /// Never the hosted relay's address, which is private (CLAUDE.md).
    static let exampleRelay = "https://relay.example.com"

    /// Draws a view in a window-sized hosting view (a Form draws blank in ImageRenderer).
    /// Without a height, as tall as the view needs.
    /// `prepare` runs just before the picture is taken: a pane that re-reads the test Mac's
    /// permissions when it appears would otherwise draw those instead of the sample.
    static func shot(
        _ view: some View, _ name: String, width: CGFloat, height: CGFloat? = nil, prepare: () -> Void = {}
    ) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height ?? 100)
        host.layoutSubtreeIfNeeded()
        if height == nil {
            host.frame.size.height = host.fittingSize.height
            host.layoutSubtreeIfNeeded()
        }
        prepare()
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        guard let dir = ProcessInfo.processInfo.environment["README_SHOTS_DIR"] else { return }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(filePath: dir).appending(path: "\(name).png"))
    }

    @Test func setupConnect() throws {
        let view = SetupView(model: AppModel(), close: {}, relayShown: Self.exampleRelay)
            .background(Color(nsColor: .windowBackgroundColor))
        try Self.shot(view, "setup-connect", width: 500)
    }

    @Test func setupQuestions() throws {
        let view = SetupView(model: AppModel(), close: {}, showing: "questions", relayShown: Self.exampleRelay)
            .background(Color(nsColor: .windowBackgroundColor))
        try Self.shot(view, "setup-questions", width: 500)
    }

    @Test func setupAddToClaude() throws {
        let view = SetupView(model: AppModel(), close: {}, showing: "claude", relayShown: Self.exampleRelay)
            .background(Color(nsColor: .windowBackgroundColor))
        try Self.shot(view, "setup-add-to-claude", width: 500)
    }

    @Test func whatClaudeCanDo() throws {
        try Self.shot(CapabilitiesPane(model: AppModel()), "settings-capabilities", width: 560, height: 620)
    }

    @Test func permissionsAllAllowed() throws {
        let model = AppModel()
        model.showEverythingAllowed()
        #expect(model.approvals.allSatisfy { $0.state == .allowed })
        try Self.shot(PermissionsPane(model: model), "settings-permissions", width: 560, height: 950) {
            model.showEverythingAllowed()
        }
    }
}
