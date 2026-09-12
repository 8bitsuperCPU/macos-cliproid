// Generates ClipRoid's app icon as a set of PNGs for iconutil.
//
// Drawn in code rather than committed as binary art: it stays diffable, it can be regenerated at
// any size, and there is no asset to lose track of. Run via Scripts/make-icon.sh.
import AppKit
import CoreGraphics

func draw(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS icons sit inside a rounded square with a margin; matching the platform proportions
    // keeps it from looking oversized next to system apps in the Dock.
    let inset = s * 0.09
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237  // the macOS "squircle" corner ratio

    let body = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(body)
    ctx.clip()

    // Indigo to violet, top-left to bottom-right.
    let colours = [
        CGColor(red: 0.35, green: 0.36, blue: 0.92, alpha: 1),
        CGColor(red: 0.58, green: 0.30, blue: 0.90, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colours, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY),
                               options: [])
    }
    ctx.resetClip()

    // A stack of clips, back to front — the history, which is what the app is actually about.
    let cardW = rect.width * 0.52
    let cardH = rect.height * 0.60
    let centreX = rect.midX
    let centreY = rect.midY

    let layers: [(dx: CGFloat, dy: CGFloat, scale: CGFloat, alpha: CGFloat)] = [
        (-0.10, 0.09, 0.86, 0.30),
        (-0.05, 0.045, 0.93, 0.55),
        (0, 0, 1.0, 1.0),
    ]

    for layer in layers {
        let w = cardW * layer.scale
        let h = cardH * layer.scale
        let card = CGRect(x: centreX - w / 2 + rect.width * layer.dx,
                          y: centreY - h / 2 - rect.height * layer.dy,
                          width: w, height: h)
        let path = CGPath(roundedRect: card, cornerWidth: w * 0.14,
                          cornerHeight: w * 0.14, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: layer.alpha))
        ctx.fillPath()
    }

    // Text lines on the front card, so it reads as a clip rather than a blank sheet.
    let front = CGRect(x: centreX - cardW / 2, y: centreY - cardH / 2,
                       width: cardW, height: cardH)
    ctx.setFillColor(CGColor(red: 0.42, green: 0.33, blue: 0.91, alpha: 0.85))
    let lineH = front.height * 0.075
    let widths: [CGFloat] = [0.68, 0.52, 0.60, 0.38]
    for (i, factor) in widths.enumerated() {
        let y = front.maxY - front.height * (0.22 + Double(i) * 0.17)
        let line = CGRect(x: front.minX + front.width * 0.16, y: y,
                          width: front.width * factor, height: lineH)
        ctx.addPath(CGPath(roundedRect: line, cornerWidth: lineH / 2,
                           cornerHeight: lineH / 2, transform: nil))
        ctx.fillPath()
    }

    guard let image = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
// The sizes iconutil expects in an .iconset.
let sizes = [16, 32, 64, 128, 256, 512, 1024]
for size in sizes {
    guard let data = draw(size: size) else { continue }
    let scale = size >= 32 ? "\(size / 2)x\(size / 2)@2x" : "\(size)x\(size)"
    try? data.write(to: URL(fileURLWithPath: "\(outputDir)/icon_\(size)x\(size).png"))
    try? data.write(to: URL(fileURLWithPath: "\(outputDir)/icon_\(scale).png"))
}
print("wrote icons to \(outputDir)")
