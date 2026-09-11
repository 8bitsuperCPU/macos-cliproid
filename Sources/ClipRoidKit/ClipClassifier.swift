import Foundation
import ClipRoidCore

/// Turns a raw pasteboard snapshot into a typed, hashed, sensitivity-scanned clip.
///
/// Lives in Kit rather than Core only because it needs `SensitiveScanner`; the classification rules
/// themselves are pure and fully testable without a pasteboard.
public enum ClipClassifier {
    public static func classify(_ snapshot: RawSnapshot) -> CapturedClip? {
        let concealed = PasteboardConventions.isConcealed(declaredTypes: snapshot.declaredTypes)

        if let imageData = snapshot.imageData {
            return CapturedClip(
                contentType: .image,
                contentHash: Dedupe.hash(imageData),
                title: nil,
                sensitivity: concealed ? .secret : .none,
                sensitiveReason: concealed ? "Marked concealed by the source app" : nil,
                sourceAppBundleId: snapshot.sourceAppBundleId,
                sourceAppName: snapshot.sourceAppName,
                copiedAt: snapshot.capturedAt,
                contentSizeBytes: Int64(imageData.count),
                imageData: imageData
            )
        }

        if !snapshot.fileURLs.isEmpty {
            let joined = snapshot.fileURLs.map(\.path).joined(separator: "\n")
            return CapturedClip(
                contentType: .file,
                contentHash: Dedupe.hash(joined),
                body: joined,
                title: snapshot.fileURLs.first?.lastPathComponent,
                sourceAppBundleId: snapshot.sourceAppBundleId,
                sourceAppName: snapshot.sourceAppName,
                copiedAt: snapshot.capturedAt,
                contentSizeBytes: Int64(joined.utf8.count),
                fileURLs: snapshot.fileURLs
            )
        }

        guard let text = snapshot.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let finding = concealed
            ? SensitivityFinding(tier: .secret, reason: "Marked concealed by the source app")
            : SensitiveScanner.scan(text)

        var type: ClipContentType = snapshot.htmlData != nil ? .richText : .text
        var linkUrl: String?
        var linkHost: String?
        var colorHex: String?

        if let url = detectURL(text) {
            type = .link
            linkUrl = url.absoluteString
            linkHost = url.host()
        } else if let hex = detectColor(text) {
            type = .color
            colorHex = hex
        } else if type == .text, looksLikeCode(text) {
            type = .code
        }

        return CapturedClip(
            contentType: type,
            contentHash: Dedupe.hash(text),
            body: text,
            title: linkHost,
            sensitivity: finding.tier,
            sensitiveReason: finding.reason,
            sourceAppBundleId: snapshot.sourceAppBundleId,
            sourceAppName: snapshot.sourceAppName,
            copiedAt: snapshot.capturedAt,
            contentSizeBytes: Int64(text.utf8.count),
            htmlData: snapshot.htmlData,
            linkUrl: linkUrl,
            linkHost: linkHost,
            colorHex: colorHex,
            enrichmentState: type == .link ? .pending : .notApplicable
        )
    }

    /// A clip is a link only if the *entire* content is one URL. Prose that happens to contain a
    /// link is still prose, and typing it as a link would give it a favicon card and lose the text.
    static func detectURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              trimmed.count < 2048,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp", "mailto"].contains(scheme),
              url.host() != nil
        else { return nil }
        return url
    }

    static func detectColor(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let hex = String(trimmed.dropFirst())
        guard [3, 6, 8].contains(hex.count),
              hex.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return "#" + hex.uppercased()
    }

    /// Deliberately conservative. A false positive here means ordinary prose gets rendered in a
    /// monospace syntax-highlighted card, which looks broken; a false negative just means a text
    /// card, which looks fine.
    static func looksLikeCode(_ text: String) -> Bool {
        guard text.count > 24 else { return false }
        let markers = ["{", "}", "();", "=>", "func ", "def ", "class ", "import ", "const ", "let ",
                       "var ", "public ", "private ", "return ", "#include", "<?php", "SELECT ", "</"]
        let hits = markers.count { text.contains($0) }
        let lines = text.split(whereSeparator: \.isNewline)
        let indented = lines.count { $0.hasPrefix("  ") || $0.hasPrefix("\t") }
        return hits >= 2 || (hits >= 1 && indented >= 2)
    }
}
