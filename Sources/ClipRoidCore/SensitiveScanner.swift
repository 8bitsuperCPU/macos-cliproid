import Foundation

public struct SensitivityFinding: Sendable, Equatable {
    public var tier: Sensitivity
    public var reason: String?

    public init(tier: Sensitivity, reason: String? = nil) {
        self.tier = tier
        self.reason = reason
    }

    public static let none = SensitivityFinding(tier: .none)
}

/// Tiered detection, per the revised spec §4.7.
///
/// The original draft flagged every email address, phone number and IP, plus any text containing
/// the words "password", "secret", "token" or "key". In practice that flags most of what a developer
/// copies in a day: the badge becomes meaningless, previews are blurred constantly, and the user
/// turns the feature off — which leaves them worse protected than a narrower rule would.
///
/// So: `secret` is reserved for patterns that are both high-confidence and high-consequence.
/// `personal` is recorded and filterable but changes nothing about how the clip is displayed.
///
/// This is a convenience, not a security boundary, and the UI says so.
public enum SensitiveScanner {
    public static func scan(_ text: String) -> SensitivityFinding {
        guard text.count < 100_000 else { return .none }

        for rule in secretRules where rule.matches(text) {
            return SensitivityFinding(tier: .secret, reason: rule.reason)
        }
        if let card = detectLuhnCard(text) {
            return SensitivityFinding(tier: .secret, reason: card)
        }
        for rule in personalRules where rule.matches(text) {
            return SensitivityFinding(tier: .personal, reason: rule.reason)
        }
        return .none
    }

    /// `NSRegularExpression` rather than Swift's `Regex`: `Regex` is not `Sendable`, and these
    /// rules are compiled once into a `static let` shared across every capture.
    struct Rule: Sendable {
        let reason: String
        let regex: NSRegularExpression

        func matches(_ text: String) -> Bool {
            let range = NSRange(text.startIndex..., in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        }
    }

    private static func rule(_ reason: String, _ pattern: String) -> Rule? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return Rule(reason: reason, regex: regex)
    }

    static let secretRules: [Rule] = [
        rule("Private key block", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        rule("JSON Web Token", #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
        rule("AWS access key ID", #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
        rule("GitHub token", #"\bgh[pousr]_[A-Za-z0-9]{36,}"#),
        rule("OpenAI-style API key", #"\bsk-[A-Za-z0-9_-]{20,}"#),
        rule("Slack token", #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#),
        rule("Google API key", #"\bAIza[0-9A-Za-z_-]{35}"#),
        rule("Stripe secret key", #"\b[rs]k_(live|test)_[A-Za-z0-9]{16,}"#),
        rule("Bearer token", #"\bBearer\s+[A-Za-z0-9._~+/-]{20,}={0,2}"#),
        rule("Connection string with password", #"://[^:/\s]+:[^@/\s]{6,}@"#),
    ].compactMap { $0 }

    static let personalRules: [Rule] = [
        rule("Email address", #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#),
        rule("IP address", #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#),
        rule("Phone number", #"(?:\+\d{1,3}[\s-]?)?(?:\(\d{2,4}\)[\s-]?)?\d{3,4}[\s-]?\d{3,4}\b"#),
    ].compactMap { $0 }

    /// A bare run of 16 digits is not a card number — an order id, a hash prefix and a timestamp all
    /// look the same. The Luhn check is what makes this rule usable rather than noisy.
    static func detectLuhnCard(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(?:\d[ -]*?){13,19}\b"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, options: [], range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            let digits = text[r].filter(\.isNumber)
            guard (13...19).contains(digits.count), luhnValid(digits) else { continue }
            return "Card number (Luhn-valid)"
        }
        return nil
    }

    static func luhnValid<S: StringProtocol>(_ digits: S) -> Bool {
        var sum = 0
        for (offset, char) in digits.reversed().enumerated() {
            guard let d = char.wholeNumberValue else { return false }
            if offset % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0 && sum > 0
    }
}
