import Foundation

/// Size policy for text and payloads. Spec §10, revised: the original 200MB default meant a
/// routine copy could move 200MB out of pasteboardd and onto disk on a 300ms tick.
public enum SizeLimits {
    /// Default per-item capture cap.
    public static let defaultMaxCaptureBytes = 50 * 1024 * 1024
    /// Configurable ceiling the user can raise to.
    public static let maxCaptureBytesCeiling = 200 * 1024 * 1024

    /// Text longer than this also goes to a blob file, so ordinary rows stay small and the
    /// timeline query stays fast.
    public static let textBlobThreshold = 256 * 1024

    /// Most text we will put in the FTS index. A 40MB log paste is still findable by its first
    /// megabyte; indexing all of it would bloat the index for no practical gain.
    public static let maxIndexedBodyBytes = 1024 * 1024

    /// Refuse to capture when the volume is this close to full (spec §10).
    public static let lowDiskThresholdBytes: Int64 = 500 * 1024 * 1024

    /// Preview length carried in `ClipSummary`.
    public static let previewLength = 120
}

extension String {
    /// Single-line preview for a card, collapsed and clipped.
    public func clipPreview(limit: Int = SizeLimits.previewLength) -> String {
        let collapsed = split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit)) + "…"
    }
}
