// Spikes S2 (hotkey firing) + S4 (paste round-trip), combined into one signed app bundle.
//
// They are combined because both need the same thing: a stable, signed bundle that TCC can hang an
// Accessibility grant on. A bare executable cannot hold one reliably. This is also, deliberately,
// the M2 walking skeleton — hotkey in, paste out — so what it proves carries straight into the app.
//
// Build:  Spikes/SpikeApp/build.sh
// Run:    open .build/ClipRoidSpike.app   (then press Ctrl+Cmd+V in any app)
import AppKit
import Carbon.HIToolbox

/// Also mirrored to a file, because a bundle launched with `open` has no stderr to read — and
/// launching with `open` versus exec'ing the binary directly is itself the thing under test:
/// TCC attributes a directly-exec'd binary to its *responsible process* (the terminal), so a
/// paste that "works" from a shell may be riding the terminal's Accessibility grant, not the
/// app's own.
let logURL = URL(fileURLWithPath: "/tmp/cliproid-spike.log")
let log = { (s: String) in
    let line = "[spike] " + s + "\n"
    FileHandle.standardError.write(Data(line.utf8))
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}
log("launched (rebuild #2 — binary changed). AXIsProcessTrusted=\(AXIsProcessTrusted())")

// MARK: - Layout-aware keycode for "v"

/// kVK_ANSI_V is a physical key *position*. On Dvorak that position is not "v", so a paste posted
/// with it delivers whatever else lives there. The spec raises layout-independence for shortcut
/// detection and misses it for paste delivery; this is that gap.
func keyCodeForV() -> CGKeyCode? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    return data.withUnsafeBytes { raw -> CGKeyCode? in
        guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
        var dead: UInt32 = 0
        for code in 0..<128 as Range<UInt16> {
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            if UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                              UInt32(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars) == noErr,
               length == 1, chars[0] == UniChar(UnicodeScalar("v").value) {
                return CGKeyCode(code)
            }
        }
        return nil
    }
}

func waitForModifiersToClear(timeout: TimeInterval = 0.3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let f = CGEventSource.flagsState(.combinedSessionState)
        if !f.contains(.maskControl) && !f.contains(.maskAlternate) && !f.contains(.maskShift) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.015)
    }
    return false
}


// MARK: - Verification: read back what the focused element actually contains

/// Reads the text of the system-wide focused UI element via the Accessibility API.
///
/// This is what turns S4 from "a human looked at the screen" into an automated per-app result.
/// Note it is used only to *verify*, never to deliver the paste — AX text insertion fails or
/// corrupts state in web views, Electron and terminals, which is precisely the set of apps this
/// table exists to measure.
func readFocusedText() -> String? {
    let system = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let element = focused else { return nil }
    let target = unsafeBitCast(element, to: AXUIElement.self)

    // Whole value first; fall back to the selection, which is what some web views and terminals
    // expose instead.
    for attribute in [kAXValueAttribute, kAXSelectedTextAttribute] {
        var out: CFTypeRef?
        if AXUIElementCopyAttributeValue(target, attribute as CFString, &out) == .success,
           let string = out as? String, !string.isEmpty {
            return string
        }
    }
    return nil
}

/// Posts Cmd+S, for targets whose AX tree exposes no readable text.
///
/// VS Code is the case this exists for: its editor is a custom-rendered surface and the AXTextArea
/// it exposes holds only a small proxy buffer, so reading it back proves nothing. Saving to a
/// scratch file and reading that from disk is the only honest way to confirm the paste landed.
func postSave() {
    guard let src = CGEventSource(stateID: .combinedSessionState),
          let vKey = keyCodeForS() else { return }
    let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
    down?.flags = .maskCommand
    let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
    down?.post(tap: .cghidEventTap)
    usleep(20_000)
    up?.post(tap: .cghidEventTap)
}

func keyCodeForS() -> CGKeyCode? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    return data.withUnsafeBytes { raw -> CGKeyCode? in
        guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
        var dead: UInt32 = 0
        for code in 0..<128 as Range<UInt16> {
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            if UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                              UInt32(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars) == noErr,
               length == 1, chars[0] == UniChar(UnicodeScalar("s").value) {
                return CGKeyCode(code)
            }
        }
        return nil
    }
}

/// What kind of element received the paste — useful context when a target fails.
func describeFocusedElement() -> String {
    let system = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let element = focused else { return "none" }
    let target = unsafeBitCast(element, to: AXUIElement.self)
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(target, kAXRoleAttribute as CFString, &role)
    return (role as? String) ?? "unknown"
}

final class Spike {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var fireCount = 0

    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<Spike>.fromOpaque(userData).takeUnretainedValue().fired()
            return noErr
        }
        let s1 = InstallEventHandler(GetEventDispatcherTarget(), callback, 1, &spec,
                                     Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x43_4C_52_44), id: 1)
        let s2 = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey | cmdKey),
                                     id, GetEventDispatcherTarget(), 0, &ref)
        log("InstallEventHandler=\(s1) RegisterEventHotKey=\(s2)")
        log("Accessibility trusted: \(AXIsProcessTrusted())")
        log(s2 == noErr ? "READY — press Ctrl+Cmd+V in any app" : "FAILED to register hotkey")
    }

    func fired() {
        fireCount += 1

        // Step 1: capture the target BEFORE anything of ours can take focus. In the real app a
        // window appears here; one frame later the frontmost app is ClipRoid and this is useless.
        guard let target = NSWorkspace.shared.frontmostApplication else { return }
        log("--- fire #\(fireCount): target = \(target.localizedName ?? "?") (pid \(target.processIdentifier))")
        paste(into: target)
    }

    /// The paste sequence, separated from the hotkey so the per-app results table S4 asks for can be
    /// produced by naming targets rather than pressing the hotkey once per app.
    @discardableResult
    func paste(into target: NSRunningApplication) -> String? {

        guard AXIsProcessTrusted() else {
            log("    no Accessibility — clipboard-only fallback would run here (still useful)")
            return nil
        }
        guard let vKey = keyCodeForV() else { log("    could not resolve 'v' keycode"); return nil }

        let marker = "ClipRoid spike paste \(Int(Date().timeIntervalSince1970))"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(marker, forType: .string)

        // Step 2: wait for confirmed activation rather than sleeping a fixed amount — but only
        // when activation is actually changing.
        //
        // didActivateApplicationNotification fires on a *change* of active app. If the target is
        // already frontmost, no notification can ever arrive, and waiting burns the full timeout
        // for nothing. That is the common case for a hotkey-driven paste, because the user is
        // typing into the app they want to paste into. The paste still succeeds, so the cost is
        // invisible — 400ms of the 3-second budget in spec §13, on every paste.
        let activated: Bool
        if target.isActive {
            activated = true
        } else {
            // Do NOT block this thread waiting for the notification.
            //
            // NSWorkspace delivers didActivateApplicationNotification on the main run loop. A
            // DispatchSemaphore wait on the main thread therefore blocks the very thread that would
            // deliver the thing being waited for: the notification cannot arrive, the wait always
            // runs to its full timeout, and `activated` is always false. The paste still worked,
            // because by the time 400ms elapsed the app genuinely had activated — so the bug was
            // invisible and cost 400ms of the 3-second budget on every paste.
            //
            // Spinning the run loop lets the notification be delivered. In the real app this
            // becomes async/await with a continuation; the principle is the same — never block the
            // thread the answer arrives on.
            var didActivate = false
            let obs = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
            ) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.processIdentifier == target.processIdentifier { didActivate = true }
            }
            target.activate(options: [])
            let deadline = Date().addingTimeInterval(0.4)
            while !didActivate && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            activated = didActivate
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }

        // Step 3: the user is probably still holding Ctrl+Cmd from the hotkey. Posting Cmd+V on top
        // of a held Ctrl delivers Ctrl+Cmd+V to the target, which is a different command entirely.
        let cleared = waitForModifiersToClear()
        log("    activated=\(activated) modifiersCleared=\(cleared) vKey=\(vKey)")

        guard let src = CGEventSource(stateID: .combinedSessionState) else { return nil }
        let magic: Int64 = 0x43_4C_52_44
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        down?.setIntegerValueField(.eventSourceUserData, value: magic)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.setIntegerValueField(.eventSourceUserData, value: magic)
        down?.post(tap: .cghidEventTap)
        usleep(20_000)
        up?.post(tap: .cghidEventTap)
        log("    posted Cmd+V — target should now contain: \(marker)")
        return marker
    }
}

NSApplication.shared.setActivationPolicy(.accessory)
let spike = Spike()

// S4_TARGETS=com.apple.TextEdit,com.apple.Safari  -> paste into each in turn and exit.
// Without it, arm the hotkey and wait, which is the S2 firing test.
let saveTargets = Set((ProcessInfo.processInfo.environment["S4_SAVE_TARGETS"] ?? "")
    .split(separator: ",").map(String.init))
let saveProbePath = ProcessInfo.processInfo.environment["S4_SAVE_PROBE"] ?? ""

if let targets = ProcessInfo.processInfo.environment["S4_TARGETS"], !targets.isEmpty {
    log("Accessibility trusted: \(AXIsProcessTrusted())")
    for bundleId in targets.split(separator: ",").map(String.init) {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleId).first else {
            log("--- \(bundleId): NOT RUNNING, skipped")
            continue
        }
        log("--- \(bundleId)")
        let marker = spike.paste(into: app)
        Thread.sleep(forTimeInterval: 1.2)

        let role = describeFocusedElement()
        let contents = readFocusedText()
        if let marker, let contents, contents.contains(marker) {
            log("    PASS  focused=\(role)")
        } else if let contents {
            log("    FAIL  focused=\(role) — marker absent; element holds \(contents.count) chars")
        } else if let marker, saveTargets.contains(bundleId) {
            // AX cannot read this one; save and check the file on disk instead.
            postSave()
            Thread.sleep(forTimeInterval: 1.5)
            let onDisk = (try? String(contentsOfFile: saveProbePath, encoding: .utf8)) ?? ""
            if onDisk.contains(marker) {
                log("    PASS  focused=\(role) (verified via saved file, not AX)")
            } else {
                log("    FAIL  focused=\(role) — not in AX and not in the saved file")
            }
        } else {
            log("    UNVERIFIED  focused=\(role) — element exposes no readable text via AX")
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    log("done")
    exit(0)
}

spike.start()
NSApplication.shared.run()
