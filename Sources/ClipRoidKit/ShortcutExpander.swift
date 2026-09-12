import Foundation
import AppKit
import ClipRoidCore
import ClipRoidStore
import ClipRoidPlatform
import os.log

/// Expands inline shortcuts as they are typed (spec §4.5).
///
/// Off unless the user explicitly enables it. `start()` creates the keystroke tap, `stop()`
/// destroys it — there is no state in which the tap exists but is being ignored, because
/// "we read your keystrokes but discard them" is not a promise anyone should be asked to accept.
@MainActor
public final class ShortcutExpander {
    private let store: ClipStore
    private let observer: KeystrokeObserver
    private let pasteboard: SystemPasteboard
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "Shortcuts")

    private var matcher: ShortcutMatcher
    private var appSwitchObserver: (any NSObjectProtocol)?
    private var isExpanding = false

    public private(set) var isRunning = false

    public init(store: ClipStore, observer: KeystrokeObserver, pasteboard: SystemPasteboard,
                prefix: Character = ";", trigger: ShortcutTrigger = .space) {
        self.store = store
        self.observer = observer
        self.pasteboard = pasteboard
        self.matcher = ShortcutMatcher(prefix: prefix, trigger: trigger)
    }

    @discardableResult
    public func start() async -> Bool {
        guard !isRunning else { return true }
        await refreshShortcuts()

        let started = observer.start { [weak self] character in
            self?.accept(character)
        }
        guard started else { return false }

        // Switching apps ends any shortcut in progress. Carrying a half-typed shortcut from one
        // app into another would expand in the wrong place, and it keeps the buffer's lifetime as
        // short as possible.
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.matcher.reset() }
        }

        isRunning = true
        return true
    }

    public func stop() {
        observer.stop()
        if let appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver)
            self.appSwitchObserver = nil
        }
        matcher.reset()
        isRunning = false
    }

    public func refreshShortcuts() async {
        matcher.shortcuts = (try? await store.shortcuts()) ?? [:]
    }

    public func updateSettings(prefix: Character, trigger: ShortcutTrigger) {
        matcher.prefix = prefix
        matcher.trigger = trigger
        matcher.reset()
    }

    private func accept(_ character: Character) {
        // Our own expansion types characters; reading them back would recurse.
        guard !isExpanding else { return }
        guard let match = matcher.accept(character) else { return }
        Task { await expand(match) }
    }

    private func expand(_ match: ShortcutMatch) async {
        isExpanding = true
        defer { isExpanding = false }

        guard let text = try? await store.fullText(id: match.clipId), !text.isEmpty else { return }

        // Delete the shortcut the user typed, then paste the content in its place.
        //
        // Backspaces rather than an Accessibility text replacement: AX insertion fails or corrupts
        // state in web views, Electron and terminals — precisely the apps where this needs to
        // work — and it cannot carry rich content at all. See Docs/spikes.md, S4.
        deleteBackward(times: match.charactersToDelete)
        try? await Task.sleep(for: .milliseconds(30))

        await pasteboard.write(.text(text), originClipUUID: nil)
        try? await Task.sleep(for: .milliseconds(20))
        postPaste()
    }

    private func deleteBackward(times: Int) {
        guard times > 0, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for _ in 0..<times {
            let down = CGEvent(keyboardEventSource: source, virtualKey: 51 /* kVK_Delete */, keyDown: true)
            down?.setIntegerValueField(.eventSourceUserData, value: clipRoidEventMagic)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
            up?.setIntegerValueField(.eventSourceUserData, value: clipRoidEventMagic)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            usleep(4_000)
        }
    }

    private func postPaste() {
        guard let vKey = KeyboardLayout.shared.keyCode(for: "v"),
              let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        down?.setIntegerValueField(.eventSourceUserData, value: clipRoidEventMagic)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.setIntegerValueField(.eventSourceUserData, value: clipRoidEventMagic)
        down?.post(tap: .cghidEventTap)
        usleep(20_000)
        up?.post(tap: .cghidEventTap)
    }
}
