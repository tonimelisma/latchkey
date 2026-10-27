import AppKit
import SwiftUI
import Testing

@testable import Latchkey

@MainActor @Suite struct SetupRenderTests {
    @Test func fitsOnASmallScreen() throws {
        let view = SetupView(model: AppModel(), close: {}).background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        if let dir = ProcessInfo.processInfo.environment["SETUP_RENDER_DIR"],
            let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        {
            try png.write(to: URL(filePath: dir).appending(path: "setup.png"))
        }
        // A 13-inch MacBook Air's screen, less the menu bar and some margin.
        #expect(image.size.height <= 800, "height \(image.size.height)")
    }

    /// The Permissions tab lists every approval (FR-606); SETUP_RENDER_DIR saves a picture.
    @Test func permissionsPaneRenders() throws {
        // ImageRenderer draws a Form blank (it is AppKit underneath); a hosting view draws it.
        let host = NSHostingView(rootView: PermissionsPane(model: AppModel()).environment(\.colorScheme, .light))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 720)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let dir = ProcessInfo.processInfo.environment["SETUP_RENDER_DIR"],
            let png = bitmap.representation(using: .png, properties: [:])
        {
            try png.write(to: URL(filePath: dir).appending(path: "permissions.png"))
        }
        #expect(bitmap.pixelsWide > 0)
    }
}
