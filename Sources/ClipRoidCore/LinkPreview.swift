import Foundation

/// What a fetched web page told us about itself.
public struct LinkPreview: Sendable, Equatable {
    public var title: String?
    public var siteName: String?
    /// Open Graph image, or the site's icon — whichever the page offered.
    public var imageURL: URL?

    public init(title: String? = nil, siteName: String? = nil, imageURL: URL? = nil) {
        self.title = title
        self.siteName = siteName
        self.imageURL = imageURL
    }

    public var isEmpty: Bool { title == nil && siteName == nil && imageURL == nil }
}

/// Fetches a page's title and preview image.
///
/// Declared here so the enrichment pipeline can be tested without a network.
public protocol LinkPreviewFetching: Sendable {
    func preview(for url: URL) async throws -> LinkPreview
}

/// Separate from `LinkPreviewFetching` so a test double can supply metadata without also having to
/// pretend to download images.
public protocol LinkPreviewImageFetching: Sendable {
    func imageData(from url: URL, maxBytes: Int) async throws -> Data?
}

/// Pulls a preview out of raw HTML.
///
/// A deliberately small hand-rolled parser rather than a full HTML library. It reads four things
/// from the document head and ignores everything else, which keeps a malformed or hostile page
/// from being able to do much: no scripts run, no external resources load, and only the first
/// 128KB is ever examined.
public enum LinkPreviewParser {
    /// Pages routinely put the whole document in one line, so a size cap matters more than a
    /// line cap. 128KB comfortably covers any real `<head>`.
    public static let maxBytesExamined = 128 * 1024

    public static func parse(html: String, baseURL: URL) -> LinkPreview {
        // Only the head: a body can contain og: strings in user content, and on a page with
        // comments that means picking up whatever a stranger wrote.
        let head = html.range(of: "</head>", options: [.caseInsensitive])
            .map { String(html[html.startIndex..<$0.lowerBound]) } ?? html

        var preview = LinkPreview()
        preview.title = metaContent(in: head, property: "og:title")
            ?? titleTag(in: head)
        preview.siteName = metaContent(in: head, property: "og:site_name")
        if let image = metaContent(in: head, property: "og:image")
            ?? metaContent(in: head, property: "twitter:image") {
            preview.imageURL = URL(string: image, relativeTo: baseURL)?.absoluteURL
        }
        if preview.imageURL == nil, let icon = linkHref(in: head, rel: "apple-touch-icon")
            ?? linkHref(in: head, rel: "icon") {
            preview.imageURL = URL(string: icon, relativeTo: baseURL)?.absoluteURL
        }
        return preview
    }

    static func titleTag(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<title[^>]*>(.*?)</title>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        return firstCapture(regex, in: html).map(decodeEntities)
    }

    /// Handles both attribute orders — `property` before `content` and after — because real pages
    /// use both and a pattern that assumes one silently misses half the web.
    static func metaContent(in html: String, property: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            "<meta[^>]+(?:property|name)=[\"']\(escaped)[\"'][^>]+content=[\"']([^\"']*)[\"']",
            "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+(?:property|name)=[\"']\(escaped)[\"']",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]) else { continue }
            if let value = firstCapture(regex, in: html), !value.isEmpty {
                return decodeEntities(value)
            }
        }
        return nil
    }

    static func linkHref(in html: String, rel: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: rel)
        let patterns = [
            "<link[^>]+rel=[\"'][^\"']*\(escaped)[^\"']*[\"'][^>]+href=[\"']([^\"']*)[\"']",
            "<link[^>]+href=[\"']([^\"']*)[\"'][^>]+rel=[\"'][^\"']*\(escaped)[^\"']*[\"']",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]) else { continue }
            if let value = firstCapture(regex, in: html), !value.isEmpty { return value }
        }
        return nil
    }

    private static func firstCapture(_ regex: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The handful of entities that actually turn up in titles. A full decoder is not worth
    /// carrying for this.
    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, character) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
        ] {
            result = result.replacingOccurrences(of: entity, with: character,
                                                 options: [.caseInsensitive])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
