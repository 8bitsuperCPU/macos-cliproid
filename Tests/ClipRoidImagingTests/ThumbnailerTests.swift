import Testing
import Foundation
import CoreGraphics
@testable import ClipRoidImaging

@Suite("Thumbnailer")
struct ThumbnailerTests {

    /// Built in-process rather than read from a fixture file, so the suite stays headless and has
    /// no on-disk dependencies.
    private func makePNG(width: Int, height: Int) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return try #require(Thumbnailer.encodePNG(image))
    }

    @Test("Inspect reports the real pixel dimensions")
    func inspects() throws {
        let data = try makePNG(width: 120, height: 80)
        let info = try #require(Thumbnailer.inspect(data))
        #expect(info.width == 120)
        #expect(info.height == 80)
    }

    @Test("Thumbnails are bounded by the max dimension and preserve aspect ratio")
    func thumbnails() throws {
        let data = try makePNG(width: 1000, height: 500)
        let thumb = try #require(Thumbnailer.thumbnailPNG(from: data, maxDimension: 100))
        let info = try #require(Thumbnailer.inspect(thumb))
        #expect(max(info.width, info.height) == 100)
        #expect(info.width == 100 && info.height == 50)
    }

    @Test("Images already small enough are passed through untouched for OCR")
    func skipsUnnecessaryDownsample() throws {
        let data = try makePNG(width: 300, height: 200)
        let prepared = try #require(Thumbnailer.downsampleForOCR(data, maxDimension: 2000))
        #expect(prepared == data)
    }

    @Test("Large images are downsampled before OCR")
    func downsamplesForOCR() throws {
        let data = try makePNG(width: 3000, height: 1000)
        let prepared = try #require(Thumbnailer.downsampleForOCR(data, maxDimension: 500))
        let info = try #require(Thumbnailer.inspect(prepared))
        #expect(max(info.width, info.height) == 500)
    }

    @Test("Garbage input returns nil rather than throwing")
    func handlesGarbage() {
        #expect(Thumbnailer.inspect(Data([0x00, 0x01, 0x02])) == nil)
        #expect(Thumbnailer.thumbnailPNG(from: Data()) == nil)
    }
}
