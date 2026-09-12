import Foundation
import AppKit
import CoreGraphics
import ClipRoidCore
import os.log

/// How a paste was delivered, so the UI can tell the user what actually happened.
public enum PasteOutcome: Sendable, Equatable {
    /// Content written and a synthetic Cmd+V delivered to the target.
    case pasted
    /// Content written to the pasteboard only — the user presses Cmd+V themselves.
    /// Not a failure: this is the zero-permission path, and it always works.
    case clipboardOnly(reason: ClipboardOnlyReason)
}

public enum ClipboardOnlyReason: Sendable, Equatable {
    /// The user turned auto-paste off. Not a failure — a preference.
    case disabledByUser
    case accessibilityNotGranted
    case noTargetApp
    case keyboardLayoutUnresolvable
    case appOnDenyList
}

/// Marks synthetic events as ours, so the M5 keystroke observer ignores them rather than treating
/// ClipRoid's own paste as something the user typed.
public let clipRoidEventMagic: Int64 = 0x43_4C_52_44

@MainActor
public final class PasteDeliverer {
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "Paste")

    /// Whether to deliver a synthetic Cmd+V at all.
    ///
    /// Off means clips still reach the clipboard and the user presses ⌘V themselves — the same
    /// path taken when Accessibility has not been granted, and a perfectly usable one.
    public var isAutoPasteEnabled = true

    /// Apps where auto-paste is known to misbehave. Empty at present — S4 found all five tested
    /// targets working, including Electron and Terminal — but the mechanism exists because the
    /// next app is always the one that breaks.
    public var denyList: Set<String> = []

    public init() {}

    public static var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system's Accessibility prompt. Deliberately separate from the check, so the app
    /// can ask at the moment the user opts into auto-paste rather than at launch (spec §4.20).
    public static func requestAccessibility() {
        // kAXTrustedCheckOptionPrompt is an imported global var and so not concurrency-safe to
        // read; its value is this constant string, which is stable API.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Returns activation to `target` and posts Cmd+V.
    ///
    /// The pasteboard must already have been written, on `PasteboardActor`, before this is called.
    public func deliver(to target: SourceApp?) async -> PasteOutcome {
        guard let pid = target?.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid) else {
            return .clipboardOnly(reason: .noTargetApp)
        }
        if let bundleId = target?.bundleId, denyList.contains(bundleId) {
            return .clipboardOnly(reason: .appOnDenyList)
        }
        guard isAutoPasteEnabled else {
            return .clipboardOnly(reason: .disabledByUser)
        }
        guard Self.isAccessibilityGranted else {
            return .clipboardOnly(reason: .accessibilityNotGranted)
        }
        guard let vKey = KeyboardLayout.shared.keyCode(for: "v") else {
            logger.error("No keycode produces 'v' under the current layout")
            return .clipboardOnly(reason: .keyboardLayoutUnresolvable)
        }

        await returnActivation(to: app)
        await waitForModifiersToClear()
        post(keyCode: vKey)
        return .pasted
    }

    /// Brings `app` back to the front and waits until the system confirms it.
    ///
    /// Two things here were each worth a bug (Docs/spikes.md, S4):
    ///
    /// 1. If the app is already active, no `didActivateApplicationNotification` will ever fire,
    ///    because it only fires on a *change*. Waiting for one burns the whole timeout. That is the
    ///    common case for a hotkey paste, since the user is typing into the app they want to paste
    ///    into.
    /// 2. The notification is delivered on the main run loop, so blocking the main thread on a
    ///    semaphore to wait for it blocks the very thread that would deliver it — the wait can then
    ///    only ever time out. `withCheckedContinuation` suspends instead of blocking, which leaves
    ///    the run loop free to deliver.
    ///
    /// Both bugs were invisible: the paste succeeded regardless, just 400ms later than it should
    /// have, out of the 3-second budget in spec §13.
    private func returnActivation(to app: NSRunningApplication) async {
        if app.isActive { return }

        let notificationCenter = NSWorkspace.shared.notificationCenter
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = ResumeOnce(continuation)
            var observer: (any NSObjectProtocol)?
            observer = notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { note in
                let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard activated?.processIdentifier == app.processIdentifier else { return }
                if let observer { notificationCenter.removeObserver(observer) }
                box.resume()
            }

            app.activate(options: [])

            // Timing varies with Spaces switches and app launches, so a fixed sleep is wrong in
            // both directions. This is a backstop, not the expected path.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let observer { notificationCenter.removeObserver(observer) }
                box.resume()
            }
        }
    }

    /// The user may still be holding Ctrl+Cmd from the hotkey. Posting Cmd+V on top of a held Ctrl
    /// delivers Ctrl+Cmd+V to the target, which is a different command — and the single most common
    /// cause of "paste sometimes does nothing" in this class of app.
    private func waitForModifiersToClear(timeout: TimeInterval = 0.3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if !flags.contains(.maskControl) && !flags.contains(.maskAlternate)
                && !flags.contains(.maskShift) {
                return
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private func post(keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = .maskCommand
        down?.setIntegerValueField(.eventSourceUserData, value: clipRoidEventMagic)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.setIntegerValueField(.eventSourceUserData, value: clipRoidEventMagic)

        down?.post(tap: .cghidEventTap)
        usleep(20_000)
        up?.post(tap: .cghidEventTap)
    }
}

/// A continuation can only be resumed once, and here two paths race to resume it: the notification
/// and the timeout. Resuming twice is a crash, not a warning.
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}
