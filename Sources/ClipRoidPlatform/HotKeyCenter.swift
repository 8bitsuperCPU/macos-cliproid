import Foundation
import AppKit
import Carbon.HIToolbox
import ClipRoidCore
import os.log

/// A global hotkey, as stored in Settings.
public struct HotKeySpec: Sendable, Equatable, Codable {
    /// Physical key position — correct for a hotkey, because the user's chord is positional too.
    public var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `controlKey`, `optionKey`, `shiftKey`).
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Ctrl+Cmd+V, the default from spec §4.4.
    public static let quickPaste = HotKeySpec(
        keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | cmdKey))

    /// Ctrl+Cmd+0…9 for the recent slots (spec §4.19).
    public static func recentSlot(_ index: Int) -> HotKeySpec? {
        let codes = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                     kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        guard codes.indices.contains(index) else { return nil }
        return HotKeySpec(keyCode: UInt32(codes[index]), modifiers: UInt32(controlKey | cmdKey))
    }

    public var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(KeyCodeNames.name(for: keyCode))
        return parts.joined()
    }
}

enum KeyCodeNames {
    static func name(for keyCode: UInt32) -> String {
        let map: [Int: String] = [
            kVK_ANSI_V: "V", kVK_ANSI_C: "C", kVK_ANSI_0: "0", kVK_ANSI_1: "1",
            kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
            kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "Return",
        ]
        return map[Int(keyCode)] ?? "Key\(keyCode)"
    }
}

/// Registers global hotkeys through Carbon.
///
/// Carbon rather than a `CGEventTap`, deliberately: `RegisterEventHotKey` needs **no Accessibility
/// grant** (proven in Docs/spikes.md, S2), so Quick Paste can open, search, and put a clip on the
/// pasteboard on a machine that has granted ClipRoid nothing at all. Only the final synthetic
/// Cmd+V needs permission.
@MainActor
public final class HotKeyCenter {
    public typealias Handler = @MainActor (UInt32) -> Void

    private var handlers: [UInt32: Handler] = [:]
    private var registered: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "HotKey")

    public init() {}

    /// Returns the assigned id, or nil if the system refused the registration — usually because
    /// another app already owns that chord.
    @discardableResult
    public func register(_ spec: HotKeySpec, handler: @escaping Handler) -> UInt32? {
        installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x43_4C_52_44 /* 'CLRD' */), id: id)
        let status = RegisterEventHotKey(
            spec.keyCode, spec.modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)

        guard status == noErr, let ref else {
            logger.error("Could not register \(spec.displayString, privacy: .public) — status \(status)")
            return nil
        }
        registered[id] = ref
        handlers[id] = handler
        return id
    }

    public func unregister(_ id: UInt32) {
        if let ref = registered.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers[id] = nil
    }

    public func unregisterAll() {
        for id in Array(registered.keys) { unregister(id) }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        // Carbon hands the callback a raw pointer and nothing else, so self travels through
        // userData. `passUnretained` is safe here only because the center is owned by
        // AppEnvironment for the lifetime of the app and removes the handler in deinit.
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { center.fire(hotKeyID.id) }
            return noErr
        }

        InstallEventHandler(GetEventDispatcherTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    private func fire(_ id: UInt32) {
        handlers[id]?(id)
    }

    /// Releases the Carbon resources. These are not Swift objects and leak silently if not
    /// released, and the installed event handler keeps an unretained pointer to `self` — which
    /// would dangle if the center were freed with the handler still installed.
    ///
    /// Called from `AppEnvironment.stop()`. `isolated deinit` backs it up so a center that is
    /// dropped without an explicit shutdown still cleans up.
    public func shutdown() {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    isolated deinit {
        shutdown()
    }
}
