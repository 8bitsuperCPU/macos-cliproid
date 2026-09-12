import Foundation

public struct ClipCategory: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var uuid: UUID
    public var name: String
    public var colorHex: String?
    public var iconName: String?
    public var sortOrder: Int
    /// True when the category is maintained by a smart filter rather than by hand.
    public var isSmart: Bool

    public init(
        id: Int64, uuid: UUID = UUID(), name: String, colorHex: String? = nil,
        iconName: String? = nil, sortOrder: Int = 0, isSmart: Bool = false
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.colorHex = colorHex
        self.iconName = iconName
        self.sortOrder = sortOrder
        self.isSmart = isSmart
    }
}

/// A rule that files clips into a category automatically (spec §4.2).
///
/// All populated conditions must match — they are ANDed. A rule with no conditions at all matches
/// nothing rather than everything: "file every clip into this category" is almost never what
/// someone means, and the version that silently swallows the whole history is the worse mistake.
public struct SmartFilterRule: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var uuid: UUID
    public var name: String
    public var categoryId: Int64
    public var enabled: Bool
    public var contentType: ClipContentType?
    public var sourceAppBundleId: String?
    public var textPattern: String?
    public var isRegex: Bool
    public var sortOrder: Int

    public init(
        id: Int64, uuid: UUID = UUID(), name: String, categoryId: Int64, enabled: Bool = true,
        contentType: ClipContentType? = nil, sourceAppBundleId: String? = nil,
        textPattern: String? = nil, isRegex: Bool = false, sortOrder: Int = 0
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.categoryId = categoryId
        self.enabled = enabled
        self.contentType = contentType
        self.sourceAppBundleId = sourceAppBundleId
        self.textPattern = textPattern
        self.isRegex = isRegex
        self.sortOrder = sortOrder
    }

    public var hasAnyCondition: Bool {
        contentType != nil || sourceAppBundleId != nil
            || !(textPattern ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Evaluates smart filter rules.
///
/// Pure, and used by *both* the capture path and the retroactive re-application path (spec §4.2),
/// so the two can never disagree about what a rule means — which they inevitably would if the
/// logic were written twice.
public enum SmartFilterEngine {

    /// What a clip needs to expose for rules to be evaluated against it.
    public struct Candidate: Sendable {
        public var contentType: ClipContentType
        public var sourceAppBundleId: String?
        public var sourceAppName: String?
        public var text: String?

        public init(contentType: ClipContentType, sourceAppBundleId: String? = nil,
                    sourceAppName: String? = nil, text: String? = nil) {
            self.contentType = contentType
            self.sourceAppBundleId = sourceAppBundleId
            self.sourceAppName = sourceAppName
            self.text = text
        }
    }

    public static func categoryIds(for candidate: Candidate, rules: [SmartFilterRule]) -> Set<Int64> {
        var matched = Set<Int64>()
        for rule in rules where rule.enabled && rule.hasAnyCondition {
            if matches(candidate, rule: rule) {
                matched.insert(rule.categoryId)
            }
        }
        return matched
    }

    public static func matches(_ candidate: Candidate, rule: SmartFilterRule) -> Bool {
        guard rule.enabled, rule.hasAnyCondition else { return false }

        if let type = rule.contentType, candidate.contentType != type { return false }

        if let app = rule.sourceAppBundleId, !app.isEmpty {
            // Matched against bundle id *or* display name, because a user writing a rule types
            // "Figma", not "com.figma.Desktop".
            let haystack = [candidate.sourceAppBundleId, candidate.sourceAppName]
                .compactMap { $0?.lowercased() }
            guard haystack.contains(where: { $0.contains(app.lowercased()) }) else { return false }
        }

        if let pattern = rule.textPattern,
           !pattern.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let text = candidate.text, !text.isEmpty else { return false }
            if rule.isRegex {
                // A malformed regex must not match everything, and must not throw into the capture
                // path either — a broken rule should file nothing, and say so in the editor.
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    return false
                }
                let range = NSRange(text.startIndex..., in: text)
                guard regex.firstMatch(in: text, options: [], range: range) != nil else { return false }
            } else {
                guard text.localizedCaseInsensitiveContains(pattern) else { return false }
            }
        }

        return true
    }

    /// Validates a rule before it is saved, so a broken regex is reported in the editor rather
    /// than silently filing nothing forever.
    public static func validationError(for rule: SmartFilterRule) -> String? {
        if !rule.hasAnyCondition {
            return "Add at least one condition, or this rule will never match anything."
        }
        if rule.isRegex, let pattern = rule.textPattern, !pattern.isEmpty,
           (try? NSRegularExpression(pattern: pattern)) == nil {
            return "That is not a valid regular expression."
        }
        return nil
    }
}
