import Foundation
import CoreGraphics

/// How long since the user last touched the keyboard or mouse. Drives the poller's adaptive
/// interval — no permission required, this is not an event tap.
public enum SystemIdle {
    public static func secondsSinceLastInput() -> TimeInterval {
        // kCGAnyInputEventType is not exposed to Swift; its value is ~0 as a CGEventType.
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}
