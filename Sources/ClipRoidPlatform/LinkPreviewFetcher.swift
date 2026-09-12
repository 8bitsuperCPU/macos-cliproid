import Foundation
import ClipRoidCore
import os.log

/// Fetches a web page's title and preview image (spec §4.2's link cards).
///
/// This is the **only** network request ClipRoid ever makes, and it happens solely when the user
/// switches it on. The privacy promise in spec §9 is "fully offline", so this has to be opt-in,
/// clearly described, and easy to turn back off — which is why the setting explains exactly what
/// leaves the machine rather than calling it "rich link previews" and leaving it at that.
public struct LinkPreviewFetcher: LinkPreviewFetching, LinkPreviewImageFetching {
    private let session: URLSession
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "LinkPreview")

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        // Ephemeral, and cookies explicitly off: fetching a preview must not carry the user's
        // logged-in identity to the site, or copying a link would quietly tell that site who they
        // are.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration)
    }

    public func preview(for url: URL) async throws -> LinkPreview {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return LinkPreview()
        }

        var request = URLRequest(url: url)
        // Identifies the app honestly rather than impersonating a browser, and asks only for HTML.
        request.setValue("ClipDroid/1.0 (+link preview)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return LinkPreview()
        }
        // Anything that is not HTML has no preview to give, and decoding a binary body as text
        // would be wasted work on a potentially very large file.
        if let type = http.mimeType, !type.contains("html") {
            return LinkPreview()
        }

        let limited = data.prefix(LinkPreviewParser.maxBytesExamined)
        guard let html = String(data: limited, encoding: .utf8)
            ?? String(data: limited, encoding: .isoLatin1) else {
            return LinkPreview()
        }
        return LinkPreviewParser.parse(html: html, baseURL: response.url ?? url)
    }

    /// Downloads a preview image, small enough to be a thumbnail.
    public func imageData(from url: URL, maxBytes: Int = 4 * 1024 * 1024) async throws -> Data? {
        var request = URLRequest(url: url)
        request.setValue("ClipDroid/1.0 (+link preview)", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= maxBytes else { return nil }
        guard http.mimeType?.hasPrefix("image/") == true else { return nil }
        return data
    }
}
