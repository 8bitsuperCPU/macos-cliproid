import Testing
import Foundation
import CoreGraphics
@testable import ClipRoidImaging

@Suite("Pixel sampling")
struct PixelSamplerTests {

    /// Four quadrants of known colour, so a sample's position can be checked as well as its value.
    private func quadrants() throws -> Data {
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // CGContext has a bottom-left origin, so "top" here is the upper half of the image.
        func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: srgb, components: [r, g, b, a])!
        }
        ctx.setFillColor(colour(1, 0, 0))
        ctx.fill(CGRect(x: 0, y: 50, width: 50, height: 50))       // top-left red
        ctx.setFillColor(colour(0, 1, 0))
        ctx.fill(CGRect(x: 50, y: 50, width: 50, height: 50))      // top-right green
        ctx.setFillColor(colour(0, 0, 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 50))        // bottom-left blue
        ctx.setFillColor(colour(1, 1, 1))
        ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 50))       // bottom-right white
        let image = try #require(ctx.makeImage())
        return try #require(Thumbnailer.encodePNG(image))
    }

    /// Points are in image pixel coordinates with a top-left origin. Getting this the wrong way up
    /// is the classic bug here, and it produces a plausible-looking wrong colour rather than an
    /// error.
    @Test("Samples the right quadrant, top-left origin")
    func samplesCorrectQuadrant() throws {
        let data = try quadrants()
        #expect(PixelSampler.sample(data, at: CGPoint(x: 25, y: 25))?.hex == "#FF0000")
        #expect(PixelSampler.sample(data, at: CGPoint(x: 75, y: 25))?.hex == "#00FF00")
        #expect(PixelSampler.sample(data, at: CGPoint(x: 25, y: 75))?.hex == "#0000FF")
        #expect(PixelSampler.sample(data, at: CGPoint(x: 75, y: 75))?.hex == "#FFFFFF")
    }

    @Test("Reports RGB as well as hex")
    func reportsRGB() throws {
        let sample = try #require(PixelSampler.sample(try quadrants(), at: CGPoint(x: 25, y: 25)))
        #expect(sample.rgb == "rgb(255, 0, 0)")
        #expect(sample.red == 255)
    }

    @Test("Points outside the image return nil rather than a wrong colour", arguments: [
        CGPoint(x: -1, y: 10), CGPoint(x: 10, y: -1),
        CGPoint(x: 100, y: 10), CGPoint(x: 10, y: 100),
    ])
    func rejectsOutOfBounds(point: CGPoint) throws {
        #expect(PixelSampler.sample(try quadrants(), at: point) == nil)
    }

    @Test("Garbage data returns nil")
    func rejectsGarbage() {
        #expect(PixelSampler.sample(Data([0, 1, 2, 3]), at: .zero) == nil)
    }

    /// Without undoing premultiplication a half-transparent red reads as a dark red, and the hex
    /// the user is shown is not the colour they clicked.
    @Test("Semi-transparent pixels report their true colour")
    func unpremultiplies() throws {
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(colorSpace: srgb, components: [1, 0, 0, 0.5])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let image = try #require(ctx.makeImage())
        let data = try #require(Thumbnailer.encodePNG(image))

        let sample = try #require(PixelSampler.sample(data, at: CGPoint(x: 5, y: 5)))
        #expect(sample.red > 250, "red should read as full strength, got \(sample.red)")
        #expect(abs(sample.alpha - 0.5) < 0.02)
    }
}
