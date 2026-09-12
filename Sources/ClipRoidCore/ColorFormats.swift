import Foundation

/// Converts a stored colour clip into the formats a designer actually pastes (spec §4.13).
public enum ColorFormats: String, CaseIterable, Sendable {
    case hex, rgb, hsl, cmyk

    public var displayName: String {
        switch self {
        case .hex: "HEX"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .cmyk: "CMYK"
        }
    }

    /// Parses `#RGB`, `#RRGGBB` or `#RRGGBBAA` into 0–1 components.
    public static func components(fromHex hex: String) -> (r: Double, g: Double, b: Double)? {
        var value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16) else { return nil }
        let hasAlpha = value.count == 8
        let shift = hasAlpha ? 8 : 0
        return (
            r: Double((number >> (16 + shift)) & 0xFF) / 255,
            g: Double((number >> (8 + shift)) & 0xFF) / 255,
            b: Double((number >> shift) & 0xFF) / 255
        )
    }

    public static func string(_ format: ColorFormats, fromHex hex: String) -> String? {
        guard let c = components(fromHex: hex) else { return nil }
        switch format {
        case .hex:
            return "#" + [c.r, c.g, c.b]
                .map { String(format: "%02X", Int(round($0 * 255))) }
                .joined()
        case .rgb:
            return "rgb(\(Int(round(c.r * 255))), \(Int(round(c.g * 255))), \(Int(round(c.b * 255))))"
        case .hsl:
            let (h, s, l) = hsl(c)
            return "hsl(\(Int(round(h))), \(Int(round(s * 100)))%, \(Int(round(l * 100)))%)"
        case .cmyk:
            let (cy, m, y, k) = cmyk(c)
            return "cmyk(\(pct(cy)), \(pct(m)), \(pct(y)), \(pct(k)))"
        }
    }

    private static func pct(_ value: Double) -> String { "\(Int(round(value * 100)))%" }

    static func hsl(_ c: (r: Double, g: Double, b: Double)) -> (Double, Double, Double) {
        let maxV = max(c.r, c.g, c.b)
        let minV = min(c.r, c.g, c.b)
        let delta = maxV - minV
        let lightness = (maxV + minV) / 2

        guard delta > 0 else { return (0, 0, lightness) }

        // Denominator flips either side of 50% lightness; using the wrong branch makes pale
        // colours report impossible saturations above 100%.
        let saturation = lightness > 0.5
            ? delta / (2 - maxV - minV)
            : delta / (maxV + minV)

        var hue: Double
        switch maxV {
        case c.r: hue = ((c.g - c.b) / delta).truncatingRemainder(dividingBy: 6)
        case c.g: hue = (c.b - c.r) / delta + 2
        default: hue = (c.r - c.g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, saturation, lightness)
    }

    static func cmyk(_ c: (r: Double, g: Double, b: Double)) -> (Double, Double, Double, Double) {
        let k = 1 - max(c.r, c.g, c.b)
        // Pure black divides by zero otherwise.
        guard k < 1 else { return (0, 0, 0, 1) }
        return ((1 - c.r - k) / (1 - k), (1 - c.g - k) / (1 - k), (1 - c.b - k) / (1 - k), k)
    }
}

/// Case transforms offered when copying text, as in the reference menu.
public enum TextCaseTransform: String, CaseIterable, Sendable {
    case upper, lower, sentence, title

    public var displayName: String {
        switch self {
        case .upper: "UPPERCASE"
        case .lower: "lowercase"
        case .sentence: "Sentence case"
        case .title: "Title Case"
        }
    }

    public func apply(to text: String) -> String {
        switch self {
        case .upper: text.uppercased()
        case .lower: text.lowercased()
        case .sentence: Self.sentenceCase(text)
        case .title: text.capitalized
        }
    }

    /// Capitalises the first letter of each sentence and lowercases the rest.
    ///
    /// Operates on the first *letter*, not the first character, so a line starting with a quote
    /// mark or a bullet still gets capitalised correctly.
    static func sentenceCase(_ text: String) -> String {
        var result = ""
        var startOfSentence = true
        for character in text.lowercased() {
            if startOfSentence, character.isLetter {
                result.append(Character(character.uppercased()))
                startOfSentence = false
            } else {
                result.append(character)
                if character == "." || character == "!" || character == "?" || character == "\n" {
                    startOfSentence = true
                }
            }
        }
        return result
    }
}

/// Builds the clip a picked or sampled colour becomes.
///
/// Shared by the screen picker and the image eyedropper so the two cannot drift into filing the
/// same thing differently — one of them setting `colorHex` and the other not would mean a colour
/// that looks right but never appears under the Colours filter.
public enum ColorClip {
    /// - Parameter origin: how the colour was obtained, shown as the clip's title.
    public static func captured(
        hex: String, origin: String, appBundleId: String?, appName: String
    ) -> CapturedClip {
        CapturedClip(
            contentType: .color,
            contentHash: Dedupe.hash(hex),
            body: hex,
            title: origin,
            sourceAppBundleId: appBundleId,
            sourceAppName: appName,
            contentSizeBytes: Int64(hex.utf8.count),
            colorHex: hex,
            enrichmentState: .notApplicable)
    }
}
