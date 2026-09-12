import Testing
import Foundation
@testable import ClipRoidCore

@Suite("Link preview parsing")
struct LinkPreviewParserTests {
    private let base = URL(string: "https://example.com/article")!

    private func parse(_ html: String) -> LinkPreview {
        LinkPreviewParser.parse(html: html, baseURL: base)
    }

    @Test("Reads Open Graph tags")
    func readsOpenGraph() {
        let preview = parse("""
        <html><head>
        <meta property="og:title" content="The Quarterly Report">
        <meta property="og:site_name" content="Example">
        <meta property="og:image" content="https://cdn.example.com/hero.png">
        </head><body>ignored</body></html>
        """)
        #expect(preview.title == "The Quarterly Report")
        #expect(preview.siteName == "Example")
        #expect(preview.imageURL?.absoluteString == "https://cdn.example.com/hero.png")
    }

    /// Real pages write attributes in both orders; a pattern that assumes one silently misses
    /// half the web.
    @Test("Handles either attribute order")
    func handlesAttributeOrder() {
        let preview = parse("""
        <head><meta content="Reversed Order" property="og:title"></head>
        """)
        #expect(preview.title == "Reversed Order")
    }

    @Test("Falls back to the title tag")
    func fallsBackToTitleTag() {
        #expect(parse("<html><head><title>Plain Title</title></head></html>").title == "Plain Title")
    }

    @Test("Open Graph wins over the title tag")
    func prefersOpenGraph() {
        let preview = parse("""
        <head><title>Generic Site Name</title>
        <meta property="og:title" content="The Actual Article"></head>
        """)
        #expect(preview.title == "The Actual Article")
    }

    @Test("Relative image paths resolve against the page")
    func resolvesRelativeImages() {
        let preview = parse("""
        <head><meta property="og:image" content="/images/hero.png"></head>
        """)
        #expect(preview.imageURL?.absoluteString == "https://example.com/images/hero.png")
    }

    @Test("Falls back to a touch icon, then a favicon")
    func fallsBackToIcons() {
        let touch = parse("""
        <head><link rel="apple-touch-icon" href="/touch.png"></head>
        """)
        #expect(touch.imageURL?.absoluteString == "https://example.com/touch.png")

        let favicon = parse("""
        <head><link rel="shortcut icon" href="/favicon.ico"></head>
        """)
        #expect(favicon.imageURL?.absoluteString == "https://example.com/favicon.ico")
    }

    /// A page's body can contain og: strings inside user-submitted content — a comment thread
    /// would otherwise let a stranger choose the title ClipRoid displays.
    @Test("Only the document head is read")
    func ignoresTheBody() {
        let preview = parse("""
        <head><title>Real Title</title></head>
        <body><meta property="og:title" content="Injected By A Commenter"></body>
        """)
        #expect(preview.title == "Real Title")
    }

    @Test("Entities in titles are decoded")
    func decodesEntities() {
        #expect(parse("<head><title>Tom &amp; Jerry &mdash; S1</title></head>").title
                == "Tom & Jerry — S1")
    }

    @Test("A page with nothing useful yields an empty preview")
    func emptyPage() {
        #expect(parse("<html><head></head><body>hello</body></html>").isEmpty)
        #expect(parse("").isEmpty)
    }

    /// Malformed markup must return nothing rather than throw or hang.
    @Test("Malformed markup is survivable", arguments: [
        "<head><title>unclosed",
        "<meta property=og:title content=unquoted>",
        "<<<>>>",
        String(repeating: "<div>", count: 5_000),
    ])
    func survivesMalformed(html: String) {
        _ = LinkPreviewParser.parse(html: html, baseURL: base)
    }
}
