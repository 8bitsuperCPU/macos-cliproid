import AppKit
import ClipRoidCore

/// The system colour loupe (spec §4.13).
///
/// `NSColorSampler` rather than a ScreenCaptureKit read of the pixel under the pointer: the loupe
/// runs out of process, so it needs no Screen Recording grant and ClipDroid never sees the screen.
/// That removes an entire TCC gate the spec had assumed was unavoidable.
@MainActor
public final class SystemColorSampler: ColorPicking {
    /// Held for the lifetime of the pick.
    ///
    /// `NSColorSampler().show { }` on a temporary is the classic way to get a loupe that never
    /// calls back: nothing retains the sampler, it is released at the end of the statement, and
    /// the closure is dropped with it.
    private var active: NSColorSampler?

    public init() {}

    public func pickColor() async -> String? {
        // Serialise: a second loupe while one is open leaks the first continuation, and a
        // continuation resumed twice is a crash rather than a bug you can shrug at.
        guard active == nil else { return nil }

        let sampler = NSColorSampler()
        active = sampler
        let hex: String? = await withCheckedContinuation { continuation in
            sampler.show { color in
                guard let color else { return continuation.resume(returning: nil) }
                continuation.resume(returning: Self.hex(from: color))
            }
        }
        active = nil
        return hex
    }

    /// Converts to sRGB before reading components.
    ///
    /// The loupe reports a colour in the display's own space. Reading `redComponent` straight off
    /// a display-P3 colour yields numbers that do not match the hex any other app would show for
    /// the same pixel, and on a wide-gamut display they can fall outside 0–1 entirely.
    public nonisolated static func hex(from color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X",
                      channel(srgb.redComponent),
                      channel(srgb.greenComponent),
                      channel(srgb.blueComponent))
    }
}
