import SwiftUI

/// Shows when a clip was copied, counting seconds only for the first minute.
///
/// `Text(date, style: .relative)` keeps ticking seconds forever — a clip from this morning reads
/// "7 hours, 3 minutes, 18 seconds ago" and changes every second. Two problems with that: it is
/// noise at any age beyond about a minute, and SwiftUI re-renders every visible row once a second
/// to maintain it, which at a few hundred rows is real work for no benefit.
///
/// So: live-ticking under a minute, where the movement is genuinely informative, and a settled
/// static string after that.
struct ClipTimestamp: View {
    let date: Date
    var font: Font = .caption2

    /// Re-resolved on a coarse timer rather than per second, so a row that ages past a boundary
    /// still updates — just not sixty times more often than it needs to.
    @State private var now = Date()

    private static let boundary: TimeInterval = 60

    var body: some View {
        Group {
            if now.timeIntervalSince(date) < Self.boundary {
                Text(date, style: .relative)
            } else {
                Text(Self.settled(date, now: now))
            }
        }
        .font(font)
        .monospacedDigit()
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    static func settled(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)

        // A clip copied a moment ago in the future (clock skew, or an iCloud sync from a device a
        // few seconds ahead) should read as "now", not as a negative interval.
        guard seconds >= 0 else { return "now" }

        switch seconds {
        case ..<boundary:
            return "\(Int(seconds))s ago"
        case ..<3_600:
            return "\(Int(seconds / 60))m ago"
        case ..<86_400:
            return "\(Int(seconds / 3_600))h ago"
        case ..<(86_400 * 7):
            return "\(Int(seconds / 86_400))d ago"
        default:
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
