import Foundation
import CoreGraphics
import ImageIO

/// Reads the colour of a single pixel from image data.
///
/// Used by the detail panel's eyedropper: click anywhere in an image clip and get the colour under
/// the pointer. It is the same job as spec §4.13's screen picker, but against a stored clip rather
/// than the live screen — and it needs no permission at all, because the pixels are already ours.
public enum PixelSampler {
    public struct Sample: Sendable, Equatable {
        public var red: Int
        public var green: Int
        public var blue: Int
        public var alpha: Double

        public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
        public var rgb: String { "rgb(\(red), \(green), \(blue))" }
    }

    /// `point` is in **image pixel coordinates**, origin top-left — the convention every caller
    /// converting from a view's coordinate space already has.
    public static func sample(_ data: Data, at point: CGPoint) -> Sample? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }

        // Redraw the single pixel into a known layout rather than trusting the source's bitmap
        // info: images arrive as RGBA, BGRA, premultiplied, 16-bit and CMYK, and reading raw bytes
        // would need a branch for each. One pixel is cheap.
        // sRGB explicitly, not CGColorSpaceCreateDeviceRGB().
        //
        // "Device" RGB is whatever the display profile says, so redrawing through it silently
        // converts: pure blue came back as #0433FF and pure green as #00F900. For a colour picker
        // that is the whole failure — the hex handed to the user is not the colour they clicked,
        // and it is wrong by a small enough margin to look plausible.
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        context.translateBy(x: CGFloat(-x), y: CGFloat(y - image.height + 1))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        let alpha = Double(pixel[3]) / 255
        guard alpha > 0 else {
            return Sample(red: 0, green: 0, blue: 0, alpha: 0)
        }
        // Undo premultiplication, or a semi-transparent pixel reports as darker than it looks.
        return Sample(
            red: Int((Double(pixel[0]) / alpha).rounded()),
            green: Int((Double(pixel[1]) / alpha).rounded()),
            blue: Int((Double(pixel[2]) / alpha).rounded()),
            alpha: alpha)
    }
}
