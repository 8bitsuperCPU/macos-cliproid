import Foundation
import CryptoKit

/// Content hashing and the "is this just a repeat of what we already have" decision.
///
/// Spec §4.1 asks for consecutive identical copies to collapse into one entry with a repeat hint,
/// rather than filling the timeline with the same row N times.
public enum Dedupe {
    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(_ string: String) -> String {
        hash(Data(string.utf8))
    }

    /// A repeat is the same content from the same app inside a short window. The app check matters:
    /// copying the same string from two different apps is a genuinely different event, and the
    /// source attribution is half of why the history is useful.
    public static func isRepeat(
        candidateHash: String,
        candidateApp: String?,
        candidateAt: Date,
        headHash: String?,
        headApp: String?,
        headAt: Date?,
        window: TimeInterval = 60
    ) -> Bool {
        guard let headHash, let headAt, candidateHash == headHash, candidateApp == headApp else {
            return false
        }
        return candidateAt.timeIntervalSince(headAt) <= window
    }
}
