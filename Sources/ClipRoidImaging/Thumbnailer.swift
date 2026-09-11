import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Thumbnail generation and image inspection. CoreGraphics and ImageIO only — deliberately no
/// AppKit, so these tests run headless with no window server.
///
/// Follows the approach in ~/projects/nyx/avatar-editor/Sources/AvatarEditorKit/Imaging/.
public enum Thumbnailer {
    /// Card previews are at most ~64pt at 2x. Generating anything larger wastes both disk and the
    /// decode time on every scroll.
    public static let maxThumbnailDimension = 256

    public struct ImageInfo: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var utType: String?
    }

    public static func inspect(_ data: Data) -> ImageInfo? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { return nil }
        return ImageInfo(width: width, height: height, utType: CGImageSourceGetType(source) as String?)
    }

    /// `CGImageSourceCreateThumbnailAtIndex` decodes straight to the target size rather than
    /// decoding full-resolution and scaling down — for a 6000px screenshot that is the difference
    /// between a few milliseconds and a hundred.
    public static func thumbnailPNG(from data: Data, maxDimension: Int = maxThumbnailDimension) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return encodePNG(thumb)
    }

    public static func encodePNG(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Vision runs a great deal faster on a downsampled image, and OCR accuracy on screen text does
    /// not improve above roughly 2000px. Spec §8.3 asks for this explicitly.
    public static func downsampleForOCR(_ data: Data, maxDimension: Int = 2000) -> Data? {
        guard let info = inspect(data) else { return nil }
        guard max(info.width, info.height) > maxDimension else { return data }
        return thumbnailPNG(from: data, maxDimension: maxDimension)
    }
}
