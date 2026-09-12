import Foundation
import AppKit
import CoreGraphics
import ClipRoidCore
import os.log

/// Observes typed characters so inline shortcuts can expand (spec §4.5).
///
/// ## Why this is the most carefully constrained thing in the app
///
/// Technically this is a listen-only session event tap. Reputationally it is "the clipboard
/// manager that reads everything I type", which is precisely the accusation that would sink an app
/// whose pitch is "fully offline, no analytics, no tracking". Plan risk R5 flags it as the single
/// most likely thing to destroy trust.
///
/// So every constraint below is deliberate:
///
/// - **Off by default.** The tap is not created until the user turns the feature on, and is torn
///   down the moment they turn it off — not merely ignored. When disabled, no tap exists at all.
/// - **Listen-only.** `.listenOnly` means the tap cannot alter or swallow events, only observe.
/// - **Constant-time handler.** It converts one event to characters and hands them on. Everything
///   else — matching, store lookups, expansion — happens elsewhere. A slow tap handler is also a
///   correctness problem: the system disables taps that take too long.
/// - **Nothing is retained.** Characters go to a matcher whose buffer stays empty unless a
///   shortcut is in progress, and nothing is ever written to disk.
/// - **Our own synthetic events are ignored**, so a paste ClipRoid delivers is not mistaken for
///   typing.
@MainActor
public final class KeystrokeObserver {
    public typealias Handler = @MainActor (Character) -> Void

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: Handler?
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "Keystrokes")

    public init() {}

    public var isRunning: Bool { tap != nil }

    /// Returns false when the tap could not be created, which in practice means Accessibility has
    /// not been granted.
    @discardableResult
    public func start(handler: @escaping Handler) -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else {
            logger.notice("Keystroke observation needs Accessibility; not starting")
            return false
        }
        self.handler = handler

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let observer = Unmanaged<KeystrokeObserver>.fromOpaque(userInfo).takeUnretainedValue()
            MainActor.assumeIsolated { observer.handle(type: type, event: event) }
            // Always pass the event through untouched. This tap observes; it never intercepts.
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue)
                | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Could not create the keystroke tap")
            self.handler = nil
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        Diagnostics.log("Keystroke observation started (inline shortcuts enabled)")
        return true
    }

    /// Tears the tap down completely. Disabling the feature must remove it, not leave it running
    /// with its output discarded — "we ignore what we read" is not a privacy guarantee anyone
    /// should be asked to accept.
    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
        handler = nil
        Diagnostics.log("Keystroke observation stopped")
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables a tap whose handler runs slow. Without re-enabling, inline shortcuts
        // stop working silently and never recover until the app restarts.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                logger.notice("Tap was disabled by the system; re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        guard type == .keyDown else { return }

        // Skip events ClipRoid posted itself, so a paste we deliver is not read back as typing.
        if event.getIntegerValueField(.eventSourceUserData) == clipRoidEventMagic { return }

        // A modifier chord is a command, not typing — and reading them would be gratuitous.
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return }

        // Characters, not key codes — spec §10. The same physical key produces different
        // characters under QWERTY, Dvorak and AZERTY.
        for scalar in String(utf16CodeUnits: chars, count: length) {
            handler?(scalar)
        }
    }

    // A tap left alive after the observer is freed would call back into a dangling pointer, so
    // this is a real safety requirement rather than tidiness. `isolated deinit` because the tap is
    // MainActor state and a nonisolated deinit cannot touch it.
    isolated deinit {
        stop()
    }
}
