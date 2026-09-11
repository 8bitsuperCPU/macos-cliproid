import Testing
import Foundation
@testable import ClipRoidCore

@Suite("Sensitive content scanning")
struct SensitiveScannerTests {

    @Test("High-consequence secrets are flagged as secret", arguments: [
        "AKIAIOSFODNN7EXAMPLE",
        "ghp_1234567890abcdefghijklmnopqrstuvwxyz",
        "sk-abcdefghijklmnopqrstuvwxyz123456",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dQw4w9WgXcQdQw4w9WgXcQ",
        "-----BEGIN RSA PRIVATE KEY-----",
        "postgres://admin:sup3rs3cret@db.example.com:5432/app",
    ])
    func flagsSecrets(input: String) {
        #expect(SensitiveScanner.scan(input).tier == .secret, "\(input) should be secret")
    }

    /// The heart of the §4.7 revision. Every one of these was flagged by the original spec's rules,
    /// and flagging them means most of what a developer copies in a day gets blurred — at which
    /// point the user turns the feature off and is protected by nothing at all.
    @Test("Ordinary developer text is not flagged as secret", arguments: [
        "Remember to reset your password before Friday",
        "The API key rotation is documented in the runbook",
        "let secret = try loadSecret()",
        "TODO: move this token handling into the auth service",
        "private func configure() {}",
        "confidential — do not forward",
    ])
    func doesNotFlagProse(input: String) {
        #expect(SensitiveScanner.scan(input).tier != .secret, "\(input) should not be secret")
    }

    @Test("Contact details are personal, not secret")
    func tiersContactDetails() {
        #expect(SensitiveScanner.scan("someone@example.com").tier == .personal)
        #expect(SensitiveScanner.scan("192.168.1.1").tier == .personal)
    }

    @Test("Card numbers are only flagged when Luhn-valid")
    func requiresLuhn() {
        // A real Visa test number.
        #expect(SensitiveScanner.scan("4111 1111 1111 1111").tier == .secret)
        // A 16-digit run that is not a card: an order id, a hash prefix, a timestamp.
        #expect(SensitiveScanner.scan("1234567812345678").tier != .secret)
    }

    @Test("Luhn check arithmetic", arguments: [
        ("4111111111111111", true),
        ("5500005555555559", true),
        ("1234567812345678", false),
        ("0000000000000000", false),
    ])
    func luhn(digits: String, expected: Bool) {
        #expect(SensitiveScanner.luhnValid(digits) == expected)
    }

    @Test("Very large text is skipped rather than scanned")
    func skipsHugeText() {
        let huge = String(repeating: "a", count: 200_000)
        #expect(SensitiveScanner.scan(huge).tier == .none)
    }
}

@Suite("Dedupe")
struct DedupeTests {
    @Test("The same content from the same app inside the window is a repeat")
    func detectsRepeat() {
        let now = Date()
        #expect(Dedupe.isRepeat(
            candidateHash: "abc", candidateApp: "com.apple.Safari", candidateAt: now,
            headHash: "abc", headApp: "com.apple.Safari", headAt: now.addingTimeInterval(-5)))
    }

    @Test("The same content from a different app is a distinct event")
    func differentAppIsNotRepeat() {
        let now = Date()
        #expect(!Dedupe.isRepeat(
            candidateHash: "abc", candidateApp: "com.apple.Safari", candidateAt: now,
            headHash: "abc", headApp: "com.apple.dt.Xcode", headAt: now.addingTimeInterval(-5)))
    }

    @Test("Outside the window it is a new clip, not a repeat")
    func expiresWindow() {
        let now = Date()
        #expect(!Dedupe.isRepeat(
            candidateHash: "abc", candidateApp: "a", candidateAt: now,
            headHash: "abc", headApp: "a", headAt: now.addingTimeInterval(-3600)))
    }

    @Test("Hashing is stable and content-addressed")
    func hashesStably() {
        #expect(Dedupe.hash("hello") == Dedupe.hash("hello"))
        #expect(Dedupe.hash("hello") != Dedupe.hash("hello "))
    }
}

@Suite("Previews and conventions")
struct PreviewTests {
    @Test("Preview collapses newlines and clips to the limit")
    func collapsesPreview() {
        let preview = "one\ntwo\nthree".clipPreview()
        #expect(preview == "one two three")
        #expect(String(repeating: "x", count: 500).clipPreview().count == SizeLimits.previewLength + 1)
    }

    @Test("Transient and concealed pasteboard types are skipped")
    func respectsConventions() {
        #expect(PasteboardConventions.shouldSkipCapture(
            declaredTypes: ["public.utf8-plain-text", PasteboardConventions.concealedType]))
        #expect(PasteboardConventions.shouldSkipCapture(
            declaredTypes: [PasteboardConventions.transientType]))
        #expect(!PasteboardConventions.shouldSkipCapture(declaredTypes: ["public.utf8-plain-text"]))
    }
}
