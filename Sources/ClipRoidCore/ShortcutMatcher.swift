import Foundation

/// When an expansion fires (spec §4.5).
public enum ShortcutTrigger: String, Sendable, CaseIterable, Codable {
    /// As soon as the shortcut is complete.
    case immediate
    /// On the following space, which lets `;we` and `;welcome` coexist.
    case space
    case enter

    public var displayName: String {
        switch self {
        case .immediate: "Immediately"
        case .space: "After a space"
        case .enter: "After Return"
        }
    }
}

public struct ShortcutMatch: Sendable, Equatable {
    public var shortcut: String
    public var clipId: Int64
    /// How many characters to delete before inserting the clip. Includes the trigger character
    /// when there is one, because the user did type it.
    public var charactersToDelete: Int

    public init(shortcut: String, clipId: Int64, charactersToDelete: Int) {
        self.shortcut = shortcut
        self.clipId = clipId
        self.charactersToDelete = charactersToDelete
    }
}

/// Watches a stream of typed characters for a registered shortcut.
///
/// Deliberately operates on **characters, never key codes**. Spec §10 requires this: the same
/// physical key produces different characters under QWERTY, Dvorak and AZERTY, and a keycode-based
/// matcher would expand on the wrong keys the moment the user switched layout — or, worse, expand
/// on a Japanese IME committing unrelated text.
///
/// The buffer is bounded and lives only in memory. It is never written to disk, and it is cleared
/// on app switch, on Escape, and on any non-character key. Given the feature requires observing
/// keystrokes at all, keeping the observed window as small and as short-lived as possible is the
/// only defensible design.
public struct ShortcutMatcher: Sendable {
    /// Long enough for any plausible shortcut, short enough that the buffer never holds a sentence.
    public static let bufferLimit = 64

    public var prefix: Character
    public var trigger: ShortcutTrigger
    /// shortcut text (including its prefix) → clip id
    public var shortcuts: [String: Int64]

    private var buffer: String = ""

    public init(prefix: Character = ";", trigger: ShortcutTrigger = .space,
                shortcuts: [String: Int64] = [:]) {
        self.prefix = prefix
        self.trigger = trigger
        self.shortcuts = shortcuts
    }

    public var bufferContents: String { buffer }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// Feeds one typed character. Returns a match when an expansion should fire.
    public mutating func accept(_ character: Character) -> ShortcutMatch? {
        guard !shortcuts.isEmpty else { return nil }

        // A trigger character completes whatever is in the buffer.
        if isTriggerCharacter(character) {
            defer { reset() }
            guard let (shortcut, clipId) = longestMatch(in: buffer) else { return nil }
            // +1 for the trigger character itself, which the user typed and which must be removed
            // along with the shortcut.
            return ShortcutMatch(shortcut: shortcut, clipId: clipId,
                                 charactersToDelete: shortcut.count + 1)
        }

        if character == prefix {
            // A prefix always starts a new attempt, so ";;welcome" behaves as ";welcome".
            buffer = String(prefix)
            return nil
        }

        // Nothing is retained until a prefix has been seen.
        //
        // This is the difference between a buffer that holds "the quick brown fox" and one that is
        // empty while the user writes an email. Given the feature requires observing keystrokes at
        // all, the observed window has to be as small as it can possibly be — and outside an
        // in-progress shortcut, that is nothing. It also makes the buffer cheaper, but privacy is
        // the reason.
        guard !buffer.isEmpty else { return nil }

        // Anything that cannot appear in a shortcut ends the attempt.
        guard isShortcutBody(character) else {
            reset()
            return nil
        }

        buffer.append(character)
        if buffer.count > Self.bufferLimit { reset() }

        guard trigger == .immediate else { return nil }
        guard let clipId = shortcuts[buffer] else { return nil }
        let matched = buffer
        reset()
        return ShortcutMatch(shortcut: matched, clipId: clipId, charactersToDelete: matched.count)
    }

    /// The longest registered shortcut that the buffer ends with.
    ///
    /// Longest, not first: with both `;we` and `;welcome` registered, typing `;welcome` must expand
    /// the one the user actually finished typing.
    private func longestMatch(in text: String) -> (String, Int64)? {
        var best: (String, Int64)?
        for (shortcut, clipId) in shortcuts where text.hasSuffix(shortcut) {
            if best == nil || shortcut.count > best!.0.count {
                best = (shortcut, clipId)
            }
        }
        return best
    }

    private func isTriggerCharacter(_ character: Character) -> Bool {
        switch trigger {
        case .immediate: false
        case .space: character == " "
        case .enter: character == "\n" || character == "\r"
        }
    }

    /// Spec §4.5: alphanumerics plus underscore and hyphen.
    private func isShortcutBody(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }

    // MARK: - Validation

    public static func isValid(shortcut: String, prefix: Character) -> Bool {
        guard let first = shortcut.first, first == prefix else { return false }
        let body = shortcut.dropFirst()
        guard !body.isEmpty, body.count <= 32 else { return false }
        return body.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// Explains why a shortcut is unusable, for the assignment field (spec §4.5).
    public static func validationError(
        shortcut: String, prefix: Character, existing: [String: Int64], assigningTo clipId: Int64?
    ) -> String? {
        guard !shortcut.isEmpty else { return nil }
        guard shortcut.first == prefix else {
            return "Shortcuts must start with \(prefix)"
        }
        guard shortcut.count > 1 else {
            return "Add some letters after \(prefix)"
        }
        guard isValid(shortcut: shortcut, prefix: prefix) else {
            return "Use letters, numbers, hyphens and underscores only"
        }
        if let owner = existing[shortcut], owner != clipId {
            return "\(shortcut) is already used by another clip"
        }
        return nil
    }
}
