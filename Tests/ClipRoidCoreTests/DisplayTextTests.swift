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

@Suite("Auto tags")
struct AutoTagsTests {
    private func linkClip(_ url: String) -> CapturedClip {
        CapturedClip(contentType: .link, contentHash: "h", linkUrl: url,
                     linkHost: URL(string: url)?.host())
    }

    @Test("A link is tagged with its domain")
    func tagsDomain() {
        #expect(AutoTags.tags(for: linkClip("https://github.com/anthropics/claude-code")) == ["github.com"])
    }

    /// A tag of `github.com` is useful; one of `gist.github.com` splits the same site across
    /// several tags and makes the cloud noisier for no gain.
    @Test("Subdomains collapse to the registrable domain", arguments: [
        ("https://gist.github.com/x", "github.com"),
        ("https://docs.google.com/d/1", "google.com"),
        ("https://www.bbc.co.uk/news", "bbc.co.uk"),
        ("https://shop.example.com.au/x", "example.com.au"),
    ])
    func collapsesSubdomains(url: String, expected: String) {
        #expect(AutoTags.tags(for: linkClip(url)) == [expected])
    }

    @Test("File clips are tagged with their extension")
    func tagsFileExtension() {
        let clip = CapturedClip(
            contentType: .file, contentHash: "h",
            fileURLs: [URL(fileURLWithPath: "/tmp/report.PDF"),
                       URL(fileURLWithPath: "/tmp/image.png")])
        #expect(AutoTags.tags(for: clip) == ["pdf", "png"])
    }

    /// Content type and source app are already sidebar facets with their own counts and filters.
    /// Duplicating them as tags would give two ways to express one filter and a cloud dominated
    /// by "text" and "Safari".
    @Test("Plain text produces no tags at all")
    func noRedundantTags() {
        let clip = CapturedClip(contentType: .text, contentHash: "h", body: "hello",
                                sourceAppBundleId: "com.apple.Safari", sourceAppName: "Safari")
        #expect(AutoTags.tags(for: clip).isEmpty)
    }
}

@Suite("File clip display")
struct FileDisplayTests {
    private func fileClip(_ paths: String) -> ClipSummary {
        ClipSummary(id: 1, uuid: UUID(), contentType: .file, preview: paths, copiedAt: Date())
    }

    /// A card is far too narrow for /Users/me/Documents/Work/…, and the path is the least useful
    /// part of it anyway.
    @Test("A file clip shows its name, not its path")
    func showsFilename() {
        #expect(fileClip("/Users/me/Documents/Quarterly Report.xlsx").displayText
                == "Quarterly Report.xlsx")
    }

    @Test("Several files show the first one's name")
    func showsFirstOfMany() {
        #expect(fileClip("/tmp/a.csv\n/tmp/b.csv").displayText == "a.csv")
    }

    @Test("The full path is still available for opening the file")
    func keepsFullPath() {
        #expect(fileClip("/tmp/a.csv\n/tmp/b.csv").firstFilePath == "/tmp/a.csv")
    }

    @Test("A file clip with no path still says something")
    func emptyFileClip() {
        #expect(fileClip("").displayText == "File")
    }
}
