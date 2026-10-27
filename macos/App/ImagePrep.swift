import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PreparedImage: Sendable {
    var data: Data
    var mimeType: String
}

/// Images Claude is shown from notes and messages (spec 002 FR-104, FR-113).
enum ImagePrep {
    /// The longest side Claude reads images at; larger ones are scaled down.
    static let maxSide = 1568

    struct NotAnImage: Error {}

    /// JPEG and PNG under the size limit go as they are; anything else (HEIC, large photos) becomes
    /// a JPEG no larger than `maxSide`.
    static func prepare(_ file: URL) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { throw NotAnImage() }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        return try prepare(source, size: size) { try? Data(contentsOf: file) }
    }

    /// The same for an image in memory (a contact's picture, spec 007 FR-721).
    static func prepare(data: Data) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw NotAnImage() }
        return try prepare(source, size: data.count) { data }
    }

    private static func prepare(_ source: CGImageSource, size: Int, original: () -> Data?) throws -> PreparedImage {
        guard let type = CGImageSourceGetType(source) as String? else { throw NotAnImage() }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let side = max(
            props?[kCGImagePropertyPixelWidth] as? Int ?? 0, props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        if side > 0, side <= maxSide, size < 3_000_000,
            let mime = [UTType.jpeg.identifier: "image/jpeg", UTType.png.identifier: "image/png"][type],
            let data = original()
        {
            return PreparedImage(data: data, mimeType: mime)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw NotAnImage()
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NotAnImage()
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NotAnImage() }
        return PreparedImage(data: out as Data, mimeType: "image/jpeg")
    }
}
