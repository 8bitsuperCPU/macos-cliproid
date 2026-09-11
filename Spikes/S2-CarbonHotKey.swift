// Spike S2 — Carbon RegisterEventHotKey from a background app, under Swift 6 language mode.
//
// Two questions:
//   1. Does a global hotkey need Accessibility? (It must not — the plan's whole permission story
//      depends on the app being useful before any TCC prompt. CGEventTap needs Accessibility;
//      RegisterEventHotKey is claimed not to.)
//   2. Does the Unmanaged userData C-callback trampoline survive `-swift-version 6`? Carbon's
//      EventHandlerUPP is the one piece of this app most likely to force a .v5 downgrade.
//
// Build and run: swiftc -swift-version 6 Spikes/S2-CarbonHotKey.swift -o /tmp/s2 && /tmp/s2
import AppKit
import Carbon.HIToolbox

final class HotKeyCenter {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var fireCount = 0

    /// Carbon hands the callback a raw pointer and nothing else, so `self` has to be smuggled
    /// through userData. `passUnretained` is correct here only because the center outlives the
    /// handler — it is installed for the lifetime of the app and removed in deinit.
    func install(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            center.fireCount += 1
            print("  >> hotkey fired (id \(hotKeyID.id)), count = \(center.fireCount)")
            return noErr
        }

        let status = InstallEventHandler(
            GetEventDispatcherTarget(), callback, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return status }

        let id = EventHotKeyID(signature: OSType(0x43_4C_52_44 /* 'CLRD' */), id: 1)
        return RegisterEventHotKey(keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

// A hotkey is delivered to an app with a run loop, so behave like one.
NSApplication.shared.setActivationPolicy(.accessory)

print("== context ==")
print("Accessibility trusted: \(AXIsProcessTrusted())")
print("frontmost app:         \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")")

let center = HotKeyCenter()
// kVK_ANSI_V is a *physical key position*, not the letter "v". That distinction matters for
// delivering a paste (see S4) but is the right thing for registration: the user's Ctrl+Cmd+V is
// positional too.
let status = center.install(keyCode: UInt32(kVK_ANSI_V),
                            modifiers: UInt32(controlKey | cmdKey))

print("\n== registration ==")
print("RegisterEventHotKey status: \(status) \(status == noErr ? "(noErr)" : "(FAILED)")")
print("Accessibility trusted after registering: \(AXIsProcessTrusted())")
if status == noErr && !AXIsProcessTrusted() {
    print("=> PASS: a global hotkey registered with no Accessibility grant.")
} else if status != noErr {
    print("=> FAIL: registration did not succeed.")
}

let seconds = Int(ProcessInfo.processInfo.environment["S2_WAIT"] ?? "0") ?? 0
if seconds > 0 {
    print("\n== listening \(seconds)s — press Ctrl+Cmd+V now, from any app ==")
    let deadline = Date().addingTimeInterval(Double(seconds))
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    print("\nfired \(center.fireCount) time(s) — \(center.fireCount > 0 ? "PASS" : "no keypress observed")")
}
