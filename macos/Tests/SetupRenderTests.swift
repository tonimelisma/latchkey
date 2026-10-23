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
}
