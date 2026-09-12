import Testing
import Foundation
@testable import ClipRoidCore

@Suite("Colour formats")
struct ColorFormatTests {

    /// The reference values from the supplied screenshot: #B7DE72 shown as
    /// rgb(183, 222, 114), cmyk(18%, 0%, 49%, 13%), hsl(82, 62%, 66%).
    @Test("The reference colour converts to every format")
    func referenceColour() {
        #expect(ColorFormats.string(.hex, fromHex: "#B7DE72") == "#B7DE72")
        #expect(ColorFormats.string(.rgb, fromHex: "#B7DE72") == "rgb(183, 222, 114)")
        #expect(ColorFormats.string(.hsl, fromHex: "#B7DE72") == "hsl(82, 62%, 66%)")
        #expect(ColorFormats.string(.cmyk, fromHex: "#B7DE72") == "cmyk(18%, 0%, 49%, 13%)")
    }

    @Test("Shorthand and alpha hex both parse")
    func parsesHexVariants() {
        #expect(ColorFormats.string(.rgb, fromHex: "#FFF") == "rgb(255, 255, 255)")
        #expect(ColorFormats.string(.rgb, fromHex: "#FF8800FF") == "rgb(255, 136, 0)")
        #expect(ColorFormats.string(.rgb, fromHex: "B7DE72") == "rgb(183, 222, 114)")
    }

    @Test("Greys have no hue or saturation")
    func greys() {
        #expect(ColorFormats.string(.hsl, fromHex: "#808080") == "hsl(0, 0%, 50%)")
    }

    /// Pure black divides by zero in the CMYK conversion if the k == 1 case is not handled.
    @Test("Black and white do not divide by zero")
    func extremes() {
        #expect(ColorFormats.string(.cmyk, fromHex: "#000000") == "cmyk(0%, 0%, 0%, 100%)")
        #expect(ColorFormats.string(.cmyk, fromHex: "#FFFFFF") == "cmyk(0%, 0%, 0%, 0%)")
    }

    /// The HSL saturation denominator flips either side of 50% lightness. Using one branch for
    /// both makes pale colours report saturations above 100%.
    @Test("Pale colours report a valid saturation")
    func paleColours() {
        let hsl = ColorFormats.string(.hsl, fromHex: "#FFE5E5")
        #expect(hsl != nil)
        let saturation = hsl.flatMap { text -> Int? in
            text.split(separator: ",").dropFirst().first
                .flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: " %"))) }
        }
        #expect((saturation ?? 0) <= 100)
    }

    @Test("Malformed input returns nil rather than a wrong colour", arguments: ["", "#", "nope", "#12345"])
    func rejectsMalformed(hex: String) {
        #expect(ColorFormats.string(.rgb, fromHex: hex) == nil)
    }
}

@Suite("Text case transforms")
struct TextCaseTests {
    @Test("Simple transforms")
    func simple() {
        #expect(TextCaseTransform.upper.apply(to: "hello world") == "HELLO WORLD")
        #expect(TextCaseTransform.lower.apply(to: "HELLO World") == "hello world")
        #expect(TextCaseTransform.title.apply(to: "hello world") == "Hello World")
    }

    @Test("Sentence case capitalises after terminators")
    func sentenceCase() {
        #expect(TextCaseTransform.sentence.apply(to: "hello world. goodbye now.")
                == "Hello world. Goodbye now.")
    }

    /// Operating on the first *character* rather than the first letter leaves quoted or bulleted
    /// lines uncapitalised.
    @Test("Sentence case skips leading punctuation")
    func sentenceCaseWithPunctuation() {
        #expect(TextCaseTransform.sentence.apply(to: "\"hello there\"") == "\"Hello there\"")
        #expect(TextCaseTransform.sentence.apply(to: "- item one. item two")
                == "- Item one. Item two")
    }

    @Test("Empty text survives every transform")
    func emptyText() {
        for transform in TextCaseTransform.allCases {
            #expect(transform.apply(to: "").isEmpty)
        }
    }
}
