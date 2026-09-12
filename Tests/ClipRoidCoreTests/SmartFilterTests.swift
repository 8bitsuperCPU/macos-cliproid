import Testing
import Foundation
@testable import ClipRoidCore

@Suite("Smart filter rules")
struct SmartFilterTests {

    private func rule(
        category: Int64 = 1, enabled: Bool = true, type: ClipContentType? = nil,
        app: String? = nil, pattern: String? = nil, isRegex: Bool = false
    ) -> SmartFilterRule {
        SmartFilterRule(id: 1, name: "test", categoryId: category, enabled: enabled,
                        contentType: type, sourceAppBundleId: app,
                        textPattern: pattern, isRegex: isRegex)
    }

    private func clip(
        _ type: ClipContentType = .text, app: String? = nil,
        appName: String? = nil, text: String? = nil
    ) -> SmartFilterEngine.Candidate {
        .init(contentType: type, sourceAppBundleId: app, sourceAppName: appName, text: text)
    }

    @Test("Matching on content type")
    func matchesType() {
        #expect(SmartFilterEngine.matches(clip(.image), rule: rule(type: .image)))
        #expect(!SmartFilterEngine.matches(clip(.text), rule: rule(type: .image)))
    }

    /// The spec's own example: "all clips from Figma → Design Assets". A user writes "Figma", not
    /// "com.figma.Desktop", so the rule has to match the display name as well as the bundle id.
    @Test("An app rule matches by name as well as bundle id")
    func matchesAppByEitherIdentifier() {
        let r = rule(app: "Figma")
        #expect(SmartFilterEngine.matches(
            clip(.image, app: "com.figma.Desktop", appName: "Figma"), rule: r))
        #expect(SmartFilterEngine.matches(
            clip(.image, app: "com.figma.Desktop", appName: nil), rule: r))
        #expect(!SmartFilterEngine.matches(
            clip(.image, app: "com.apple.Safari", appName: "Safari"), rule: r))
    }

    @Test("Text matching is case-insensitive substring by default")
    func matchesSubstring() {
        let r = rule(pattern: "invoice")
        #expect(SmartFilterEngine.matches(clip(text: "Your INVOICE is attached"), rule: r))
        #expect(!SmartFilterEngine.matches(clip(text: "unrelated"), rule: r))
    }

    @Test("Regex matching when asked for")
    func matchesRegex() {
        let r = rule(pattern: #"^INV-\d{4}$"#, isRegex: true)
        #expect(SmartFilterEngine.matches(clip(text: "INV-2024"), rule: r))
        #expect(!SmartFilterEngine.matches(clip(text: "INV-20"), rule: r))
    }

    /// A malformed regex must file nothing. Matching everything would silently sweep the entire
    /// history into one category, which is far worse than the rule simply not working.
    @Test("A broken regex matches nothing rather than everything")
    func brokenRegexMatchesNothing() {
        let r = rule(pattern: "[unclosed", isRegex: true)
        #expect(!SmartFilterEngine.matches(clip(text: "anything at all"), rule: r))
        #expect(SmartFilterEngine.validationError(for: r)?.contains("valid regular expression") == true)
    }

    @Test("Conditions are ANDed, not ORed")
    func conditionsAreAnded() {
        let r = rule(type: .code, app: "Xcode")
        #expect(SmartFilterEngine.matches(clip(.code, appName: "Xcode"), rule: r))
        #expect(!SmartFilterEngine.matches(clip(.code, appName: "Safari"), rule: r),
                "right type, wrong app")
        #expect(!SmartFilterEngine.matches(clip(.text, appName: "Xcode"), rule: r),
                "right app, wrong type")
    }

    /// "File everything here" is almost never what someone means, and the version that silently
    /// swallows the whole history is the worse mistake.
    @Test("A rule with no conditions matches nothing")
    func emptyRuleMatchesNothing() {
        let r = rule()
        #expect(!r.hasAnyCondition)
        #expect(!SmartFilterEngine.matches(clip(text: "anything"), rule: r))
        #expect(SmartFilterEngine.validationError(for: r)?.contains("at least one condition") == true)
    }

    @Test("A disabled rule never matches")
    func disabledRuleIgnored() {
        #expect(!SmartFilterEngine.matches(clip(.image), rule: rule(enabled: false, type: .image)))
    }

    @Test("A text rule does not match a clip with no text")
    func textRuleNeedsText() {
        #expect(!SmartFilterEngine.matches(clip(.image, text: nil), rule: rule(pattern: "invoice")))
    }

    @Test("Several rules can file one clip into several categories")
    func multipleRulesMultipleCategories() {
        let rules = [
            SmartFilterRule(id: 1, name: "images", categoryId: 10, contentType: .image),
            SmartFilterRule(id: 2, name: "figma", categoryId: 20, sourceAppBundleId: "Figma"),
            SmartFilterRule(id: 3, name: "code", categoryId: 30, contentType: .code),
        ]
        let matched = SmartFilterEngine.categoryIds(
            for: clip(.image, app: "com.figma.Desktop", appName: "Figma"), rules: rules)
        #expect(matched == [10, 20])
    }
}
