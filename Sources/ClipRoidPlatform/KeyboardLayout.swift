import Foundation
import Carbon.HIToolbox
import CoreGraphics

/// Resolves keycodes by the character they produce under the *active* keyboard layout.
///
/// `kVK_ANSI_V` is a physical key *position*, not the letter "v". On Dvorak that position types
/// "." and a paste posted with it does something else entirely. Spec §10 raises layout
/// independence for shortcut detection and misses it for paste delivery; this closes that gap.
///
/// Results are cached because `UCKeyTranslate` over 128 keycodes runs on every paste otherwise, and
/// invalidated on `kTISNotifySelectedKeyboardInputSourceChanged` so switching layouts mid-session
/// is picked up.
public final class KeyboardLayout: @unchecked Sendable {
    public static let shared = KeyboardLayout()

    private let lock = NSLock()
    private var cache: [Character: CGKeyCode] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.invalidate()
        }
    }

    public func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// The keycode that produces `character` under the current layout, or nil if none does.
    public func keyCode(for character: Character) -> CGKeyCode? {
        lock.lock()
        if let cached = cache[character] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let resolved = Self.lookup(character) else { return nil }
        lock.lock()
        cache[character] = resolved
        lock.unlock()
        return resolved
    }

    private static func lookup(_ character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return nil
        }

        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            var deadKeyState: UInt32 = 0
            for code in 0..<128 as Range<UInt16> {
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars)
                if status == noErr, length == 1, chars[0] == UniChar(scalar.value) {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
