// Spike S4 — CGEvent paste round-trip into real apps.
//
// The plan's paste sequence has four steps that are each individually easy to get wrong and that
// together account for most "paste sometimes does nothing" reports in this class of app:
//
//   1. capture the frontmost app BEFORE any of our own UI appears;
//   2. return activation and WAIT for didActivateApplicationNotification, not a fixed sleep;
//   3. wait for the user's modifiers to clear — they may still be holding Ctrl+Cmd from the
//      hotkey, and posting Cmd+V on top of a held Ctrl delivers Ctrl+Cmd+V to the target;
//   4. resolve the keycode for "v" in the CURRENT layout — kVK_ANSI_V is a physical position, and
//      on Dvorak that position is not "v".
//
// Usage:  /tmp/s4 <bundle-id>        e.g. /tmp/s4 com.apple.TextEdit
import AppKit
import Carbon.HIToolbox

// MARK: - Step 4: layout-aware keycode resolution

/// Finds the keycode that produces "v" under the active keyboard layout.
///
/// `kVK_ANSI_V` (9) is where "v" sits on a US QWERTY board; on Dvorak that position types "." and
/// the paste silently does the wrong thing. Enumerating the layout is the only correct way.
func keyCodeForV() -> CGKeyCode? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data

    return data.withUnsafeBytes { raw -> CGKeyCode? in
        guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
        else { return nil }
        var deadKeys: UInt32 = 0
        for code in 0..<128 as Range<UInt16> {
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
            if status == noErr, length == 1, chars[0] == UniChar(UnicodeScalar("v").value) {
                return CGKeyCode(code)
            }
        }
        return nil
    }
}

// MARK: - Step 3: wait for held modifiers to clear

func waitForModifiersToClear(timeout: TimeInterval = 0.3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        if !flags.contains(.maskControl) && !flags.contains(.maskAlternate)
            && !flags.contains(.maskShift) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.015)
    }
    return false
}

// MARK: - Run

let targetBundleId = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "com.apple.TextEdit"

print("== preflight ==")
print("Accessibility trusted: \(AXIsProcessTrusted())")
guard AXIsProcessTrusted() else {
    print("""

    Not trusted. A synthetic Cmd+V cannot be posted without Accessibility — this is the one
    capability in the whole app that genuinely requires it. Grant it to the binary being run,
    then re-run. Everything else in ClipRoid works without it, which is the point of the
    clipboard-only fallback.
    """)
    exit(1)
}

guard let vKey = keyCodeForV() else {
    print("FAIL: could not resolve a keycode for \"v\" in the current layout")
    exit(1)
}
print("keycode for \"v\" in this layout: \(vKey) (kVK_ANSI_V is \(kVK_ANSI_V))")

guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleId).first
else {
    print("FAIL: \(targetBundleId) is not running — open it first")
    exit(1)
}
print("target: \(target.localizedName ?? targetBundleId) (pid \(target.processIdentifier))")

let marker = "ClipRoid S4 paste probe \(Int(Date().timeIntervalSince1970))"
let pb = NSPasteboard.general
pb.clearContents()
pb.setString(marker, forType: .string)
print("wrote marker to pasteboard: \"\(marker)\"")

// Step 2: activate and wait for confirmation rather than sleeping a fixed amount. Timing varies
// wildly with Spaces switches and app launches, which is exactly what makes fixed sleeps flaky.
let activated = DispatchSemaphore(value: 0)
let observer = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
) { note in
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    if app?.processIdentifier == target.processIdentifier { activated.signal() }
}
target.activate(options: [])
let didActivate = activated.wait(timeout: .now() + 0.4) == .success
NSWorkspace.shared.notificationCenter.removeObserver(observer)
print("activation confirmed: \(didActivate)")

print("modifiers cleared: \(waitForModifiersToClear())")

guard let source = CGEventSource(stateID: .combinedSessionState) else { exit(1) }
// Tag our own synthetic events so the M5 keystroke observer can ignore them.
let magic: Int64 = 0x43_4C_52_44
let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
down?.flags = .maskCommand
down?.setIntegerValueField(.eventSourceUserData, value: magic)
let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
up?.setIntegerValueField(.eventSourceUserData, value: magic)

down?.post(tap: .cghidEventTap)
usleep(20_000)
up?.post(tap: .cghidEventTap)
print("posted Cmd+V")

print("\nCheck \(target.localizedName ?? targetBundleId) — it should now contain:")
print("  \(marker)")
