// Draws the app icon (a key on a blue rounded square, matching the relay's web icon) at every
// size macOS needs: swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: artwork is 824/1024 of the canvas, corner radius about 185/1024.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = s * 12 / 1024
    shadow.shadowOffset = NSSize(width: 0, height: -s * 6 / 1024)
    shadow.set()
    NSColor(red: 0.10, green: 0.37, blue: 0.84, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(
        starting: NSColor(red: 0.24, green: 0.55, blue: 0.99, alpha: 1),
        ending: NSColor(red: 0.10, green: 0.37, blue: 0.84, alpha: 1))!.draw(in: shape, angle: -90)

    // The key, in the same proportions as the 64-unit web icon, scaled into the artwork.
    let unit = body.width / 64
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: body.minX + x * unit, y: body.maxY - y * unit) }
    NSColor.white.setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: p(13.5, 0).x, y: p(0, 41.5).y, width: 19 * unit, height: 19 * unit))
    ring.lineWidth = 5 * unit
    ring.stroke()
    let shaft = NSBezierPath()
    shaft.lineWidth = 5 * unit
    shaft.lineCapStyle = .round
    shaft.move(to: p(32.5, 32)); shaft.line(to: p(52, 32))
    shaft.move(to: p(45.5, 32)); shaft.line(to: p(45.5, 39.5))
    shaft.move(to: p(51.5, 32)); shaft.line(to: p(51.5, 37.5))
    shaft.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! draw(points * scale).write(to: out.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appending(path: "Contents.json"))
try! JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: .prettyPrinted)
    .write(to: out.deletingLastPathComponent().appending(path: "Contents.json"))
print("wrote \(images.count) icons")
