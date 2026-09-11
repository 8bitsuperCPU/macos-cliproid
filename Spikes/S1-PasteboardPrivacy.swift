// Spike S1 — does macOS 26 add friction to programmatic pasteboard reads by a background process?
//
// macOS 15.4 added NSPasteboardDetectionPattern and, with it, this sentence in the NSPasteboard
// header for detectPatternsForPatterns: "This method ... doesn't allow the app to access the item's
// contents. As a result, the system doesn't notify the person using the app about reading the
// contents of the pasteboard."
//
// The implication is the thing this spike exists to test: reading the contents *does* notify.
// If a 300ms background poller trips that notification, ClipRoid's capture model has to change.
//
// Build and run:  swiftc -swift-version 6 Spikes/S1-PasteboardPrivacy.swift -o /tmp/s1 && /tmp/s1
import AppKit
import Foundation

let pb = NSPasteboard.general

print("== context ==")
print("frontmost app:     \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")")
print("we are frontmost:  \(NSRunningApplication.current.isActive)")
print("activationPolicy:  \(NSRunningApplication.current.activationPolicy.rawValue) (0=regular, 2=prohibited)")
print("bundleIdentifier:  \(Bundle.main.bundleIdentifier ?? "none — bare executable")")

print("\n== 1. changeCount (the poll operation itself) ==")
print("changeCount: \(pb.changeCount)")

print("\n== 2. declared types (no payload bytes pulled) ==")
print((pb.types ?? []).map(\.rawValue).joined(separator: "\n  "))

print("\n== 3. detectPatterns — the read-free pre-check ==")
// NS_REFINED_FOR_SWIFT + NS_TYPED_ENUM, and the refined overlay is NOT present in MacOSX26.5.sdk.
// Neither NSPasteboard.DetectionPattern nor the NSPasteboardDetectionPattern* constants are
// reachable from Swift; only the underscored ObjC import __detectPatterns(forPatterns:) exists,
// and it wants the constants that Swift cannot see. dlsym is the way through without an ObjC shim.
func patternConstant(_ symbol: String) -> String? {
    guard let handle = dlopen(
        "/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY) else { return nil }
    defer { dlclose(handle) }
    guard let sym = dlsym(handle, symbol) else { return nil }
    return sym.assumingMemoryBound(to: Unmanaged<NSString>?.self)
        .pointee?.takeUnretainedValue() as String?
}

if #available(macOS 15.4, *) {
    let names = [
        "NSPasteboardDetectionPatternProbableWebURL",
        "NSPasteboardDetectionPatternNumber",
        "NSPasteboardDetectionPatternEmailAddress",
    ]
    let patterns = names.compactMap(patternConstant)
    print("resolved \(patterns.count)/\(names.count) pattern constants via dlsym: \(patterns)")

    if !patterns.isEmpty {
        let sem = DispatchSemaphore(value: 0)
        pb.__detectPatterns(forPatterns: Set(patterns.map { __NSPasteboardDetectionPattern(rawValue: $0) })) { detected, error in
            if let error {
                print("detectPatterns FAILED: \(error.localizedDescription)")
            } else {
                print("detectPatterns matched: \((detected ?? []).map(\.rawValue))")
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
    }
}

print("\n== 4. payload read — the operation that would be gated ==")
let text = pb.string(forType: .string)
print("string(forType:) -> \(text.map { "\($0.count) chars: \"\($0.prefix(48))\"" } ?? "nil")")
print("data(forType:.png) -> \(pb.data(forType: .png).map { "\($0.count) bytes" } ?? "nil")")

print("\n== 5. sustained polling, reading payload every tick ==")
var ok = 0
for i in 1...10 {
    Thread.sleep(forTimeInterval: 0.3)
    let cc = pb.changeCount
    if pb.string(forType: .string) != nil { ok += 1 }
    if i % 5 == 0 { print("  tick \(i): changeCount=\(cc)") }
}
print("successful payload reads: \(ok)/10")
print("\nIf every read above returned data and no system alert appeared, a background poller is")
print("unimpeded on this OS version and the M0 capture model stands.")
