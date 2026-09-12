import Testing
import Foundation
@testable import ClipRoidCore

@Suite("Shortcut matching")
struct ShortcutMatcherTests {

    private func matcher(
        trigger: ShortcutTrigger = .space,
        shortcuts: [String: Int64] = [";welcome": 1, ";addr": 2]
    ) -> ShortcutMatcher {
        ShortcutMatcher(prefix: ";", trigger: trigger, shortcuts: shortcuts)
    }

    /// Feeds a string one character at a time, the way the event tap will.
    private func type(_ text: String, into m: inout ShortcutMatcher) -> ShortcutMatch? {
        var last: ShortcutMatch?
        for ch in text {
            if let match = m.accept(ch) { last = match }
        }
        return last
    }

    @Test("A shortcut followed by a space expands")
    func expandsOnSpace() {
        var m = matcher()
        let match = type(";welcome ", into: &m)
        #expect(match?.shortcut == ";welcome")
        #expect(match?.clipId == 1)
        // The trigger space was typed by the user and has to be removed too.
        #expect(match?.charactersToDelete == ";welcome".count + 1)
    }

    @Test("Nothing fires before the trigger")
    func waitsForTrigger() {
        var m = matcher()
        #expect(type(";welcome", into: &m) == nil)
    }

    @Test("Immediate mode fires as soon as the shortcut completes")
    func immediateMode() {
        var m = matcher(trigger: .immediate)
        let match = type(";addr", into: &m)
        #expect(match?.clipId == 2)
        #expect(match?.charactersToDelete == ";addr".count, "no trigger character to remove")
    }

    /// With both registered, typing the longer one must expand the longer one — matching the
    /// first-found would silently expand the wrong clip.
    @Test("The longest matching shortcut wins")
    func prefersLongestMatch() {
        var m = matcher(shortcuts: [";we": 1, ";welcome": 2])
        #expect(type(";welcome ", into: &m)?.clipId == 2)

        var m2 = matcher(shortcuts: [";we": 1, ";welcome": 2])
        #expect(type(";we ", into: &m2)?.clipId == 1)
    }

    @Test("An unregistered shortcut expands nothing")
    func ignoresUnknown() {
        var m = matcher()
        #expect(type(";nothing ", into: &m) == nil)
    }

    @Test("Ordinary prose never expands")
    func ignoresProse() {
        var m = matcher()
        #expect(type("the quick brown fox welcome addr ", into: &m) == nil)
    }

    @Test("Text before the prefix does not become part of the shortcut")
    func prefixStartsFresh() {
        var m = matcher()
        #expect(type("hello;welcome ", into: &m)?.shortcut == ";welcome")
    }

    @Test("A repeated prefix restarts rather than breaking the match")
    func repeatedPrefixRestarts() {
        var m = matcher()
        #expect(type(";;welcome ", into: &m)?.shortcut == ";welcome")
    }

    @Test("A character that cannot appear in a shortcut cancels the attempt")
    func punctuationCancels() {
        var m = matcher()
        #expect(type(";wel!come ", into: &m) == nil)
    }

    @Test("The buffer is bounded, so it never holds a sentence")
    func bufferIsBounded() {
        var m = matcher()
        _ = type(";" + String(repeating: "a", count: 500), into: &m)
        #expect(m.bufferContents.count <= ShortcutMatcher.bufferLimit)
    }

    @Test("Resetting clears the buffer")
    func resetClears() {
        var m = matcher()
        _ = type(";wel", into: &m)
        m.reset()
        #expect(m.bufferContents.isEmpty)
        #expect(type("come ", into: &m) == nil, "a reset must not leave a partial match live")
    }

    /// Spec §10: matching is on characters, so a layout switch cannot change behaviour. The tap
    /// delivers characters, and these are the characters a Dvorak user's keys produce.
    @Test("Matching is layout-independent because it works on characters")
    func layoutIndependent() {
        var m = matcher(shortcuts: [";sig": 7])
        // Under Dvorak, ";sig" is typed on the physical keys z-o-c-f. The tap reports characters,
        // so the matcher sees ";sig" either way.
        #expect(type(";sig ", into: &m)?.clipId == 7)
    }

    @Test("A custom prefix is honoured")
    func customPrefix() {
        var m = ShortcutMatcher(prefix: ":", trigger: .space, shortcuts: [":hi": 3])
        #expect(type(":hi ", into: &m)?.clipId == 3)
        var semi = ShortcutMatcher(prefix: ":", trigger: .space, shortcuts: [":hi": 3])
        #expect(type(";hi ", into: &semi) == nil, "the old prefix must not still work")
    }

    @Test("With no shortcuts registered nothing is even buffered")
    func noShortcutsNoWork() {
        var m = matcher(shortcuts: [:])
        #expect(type(";welcome ", into: &m) == nil)
        #expect(m.bufferContents.isEmpty)
    }

    @Test("Enter mode fires on Return, not on space")
    func enterMode() {
        var m = matcher(trigger: .enter)
        #expect(type(";welcome ", into: &m) == nil)
        var m2 = matcher(trigger: .enter)
        #expect(type(";welcome\n", into: &m2)?.clipId == 1)
    }
}

@Suite("Shortcut validation")
struct ShortcutValidationTests {
    @Test("Valid shortcuts", arguments: [";welcome", ";addr2", ";my-sig", ";snippet_1"])
    func accepts(shortcut: String) {
        #expect(ShortcutMatcher.isValid(shortcut: shortcut, prefix: ";"))
    }

    @Test("Invalid shortcuts", arguments: ["welcome", ";", ";has space", ";punct!", ""])
    func rejects(shortcut: String) {
        #expect(!ShortcutMatcher.isValid(shortcut: shortcut, prefix: ";"))
    }

    @Test("A shortcut already used by another clip is reported as a conflict")
    func reportsConflict() {
        let error = ShortcutMatcher.validationError(
            shortcut: ";welcome", prefix: ";", existing: [";welcome": 5], assigningTo: 9)
        #expect(error?.contains("already used") == true)
    }

    @Test("Reassigning a clip its own existing shortcut is not a conflict")
    func ownShortcutIsFine() {
        #expect(ShortcutMatcher.validationError(
            shortcut: ";welcome", prefix: ";", existing: [";welcome": 5], assigningTo: 5) == nil)
    }

    @Test("Each kind of malformed input explains itself", arguments: [
        ("welcome", "must start"),
        (";", "letters after"),
        (";has space", "letters, numbers"),
    ])
    func explainsProblems(shortcut: String, fragment: String) {
        let error = ShortcutMatcher.validationError(
            shortcut: shortcut, prefix: ";", existing: [:], assigningTo: nil)
        #expect(error?.localizedCaseInsensitiveContains(fragment) == true, "got: \(error ?? "nil")")
    }
}

@Suite("Shortcut buffer privacy")
struct ShortcutBufferPrivacyTests {
    private func type(_ text: String, into m: inout ShortcutMatcher) {
        for ch in text { _ = m.accept(ch) }
    }

    /// The single most important property of this feature.
    ///
    /// ClipRoid is pitched as fully offline with no tracking, and a keystroke observer is the
    /// easiest way to destroy that trust. The matcher must retain nothing at all while the user is
    /// writing ordinary text — the buffer only fills after a deliberate prefix character.
    @Test("Ordinary typing is never retained")
    func retainsNothingWhileTypingProse() {
        var m = ShortcutMatcher(prefix: ";", trigger: .space, shortcuts: [";welcome": 1])
        type("Dear Sarah, please find the invoice attached. My account number is 12345678.", into: &m)
        #expect(m.bufferContents.isEmpty, "no part of ordinary typing may be held")
    }

    @Test("Only an in-progress shortcut is held, and only until it resolves")
    func holdsOnlyTheShortcutInProgress() {
        var m = ShortcutMatcher(prefix: ";", trigger: .space, shortcuts: [";welcome": 1])
        type("hello ;wel", into: &m)
        #expect(m.bufferContents == ";wel")

        type(" ", into: &m)
        #expect(m.bufferContents.isEmpty, "resolved or abandoned, the buffer clears")
    }

    @Test("An abandoned attempt clears immediately")
    func abandonedAttemptClears() {
        var m = ShortcutMatcher(prefix: ";", trigger: .space, shortcuts: [";welcome": 1])
        type(";wel!", into: &m)
        #expect(m.bufferContents.isEmpty)
    }

    @Test("A password typed after an abandoned shortcut is not retained")
    func doesNotTrailIntoSensitiveTyping() {
        var m = ShortcutMatcher(prefix: ";", trigger: .space, shortcuts: [";welcome": 1])
        type(";x ", into: &m)
        type("hunter2SuperSecret", into: &m)
        #expect(m.bufferContents.isEmpty)
    }
}
