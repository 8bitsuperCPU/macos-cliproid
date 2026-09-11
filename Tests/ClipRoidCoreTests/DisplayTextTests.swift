import Testing
import Foundation
@testable import ClipRoidCore

@Suite("Clip display text")
struct DisplayTextTests {
    private func summary(_ type: ClipContentType, preview: String = "", title: String? = nil,
                         colorHex: String? = nil,
                         size: (width: Int, height: Int)? = nil) -> ClipSummary {
        ClipSummary(id: 1, uuid: UUID(), contentType: type, preview: preview, title: title,
                    copiedAt: Date(), colorHex: colorHex, imageSize: size)
    }

    @Test("Text content is shown as-is")
    func usesPreview() {
        #expect(summary(.text, preview: "hello").displayText == "hello")
    }

    /// An image clip has no body and, until OCR lands, no title. Without a fallback the row renders
    /// as a thumbnail above a blank line, which reads as broken rather than as "an image".
    @Test("An image with no text still describes itself")
    func imageFallsBackToDimensions() {
        #expect(summary(.image, size: (1280, 800)).displayText == "Image · 1280×800")
        #expect(summary(.screenshot, size: (2560, 1440)).displayText == "Screenshot · 2560×1440")
    }

    @Test("An image whose dimensions are not known yet still says what it is")
    func imageWithoutDimensions() {
        #expect(summary(.image).displayText == "Image")
        #expect(summary(.screenshot).displayText == "Screenshot")
    }

    @Test("Colour clips show their hex")
    func colorShowsHex() {
        #expect(summary(.color, colorHex: "#FF8800").displayText == "#FF8800")
    }

    @Test("A title is used when there is no body")
    func prefersTitleOverGenericLabel() {
        #expect(summary(.image, title: "logo.png").displayText == "logo.png")
    }

    @Test("Nothing renders as an empty row")
    func neverEmpty(){
        for type in ClipContentType.allCases {
            #expect(!summary(type).displayText.isEmpty, "\(type) must say something")
        }
    }
}
