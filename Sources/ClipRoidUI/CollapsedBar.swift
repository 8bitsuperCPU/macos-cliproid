import SwiftUI
import ClipRoidKit

/// The collapsed shelf: a small bar at the screen edge that expands when pointed at.
struct CollapsedBar: View {
    @Bindable var settings: SettingsStore

    private var radius: CGFloat { min(6, CGFloat(settings.collapsedThickness) / 2) }

    var body: some View {
        Group {
            if settings.collapsedRainbow {
                rainbow
            } else {
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.white.opacity(0.22))
                    .background(ShelfPalette.panel(settings).opacity(0.85))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A continuously cycling gradient.
    ///
    /// `TimelineView(.animation)` drives this from the display's own clock rather than a
    /// `repeatForever` animation, so the phase stays correct when the view is rebuilt — a
    /// `repeatForever` restarts from zero every time the shelf re-renders, which it does whenever
    /// a clip is captured.
    ///
    /// The frame rate is deliberately capped. This bar is on screen the entire time the shelf is
    /// collapsed, and repainting it at full display rate all day is not a reasonable thing for a
    /// clipboard manager to do to someone's battery.
    private var rainbow: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 6) / 6
            LinearGradient(
                colors: Self.spectrum(phase: phase),
                startPoint: .leading, endPoint: .trailing)
        }
    }

    /// Rotates the hue wheel by `phase`, wrapping so the two ends always meet and the gradient
    /// reads as continuous rather than snapping back at the seam.
    static func spectrum(phase: Double, stops: Int = 7) -> [Color] {
        (0..<stops).map { index in
            let hue = (Double(index) / Double(stops - 1) + phase)
                .truncatingRemainder(dividingBy: 1)
            return Color(hue: hue, saturation: 0.75, brightness: 0.95)
        }
    }
}
