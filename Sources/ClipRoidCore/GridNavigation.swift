import Foundation

/// Where an arrow key should move the keyboard cursor.
///
/// Pure index arithmetic, kept out of the views so it can be tested directly. The awkward cases
/// are all at the edges: a partly-filled last row, a single-column list where left and right mean
/// nothing, and an empty collection.
public enum GridNavigation {
    public enum Direction: Sendable, Hashable {
        case left, right, up, down
    }

    /// The index the cursor should move to, or `nil` when there is nowhere to go.
    ///
    /// Returning `nil` rather than the unchanged index lets the caller leave the key unhandled, so
    /// the event falls through to whatever else wants it — scrolling past the end of a list, for
    /// instance, instead of silently swallowing the press.
    public static func destination(
        from index: Int, count: Int, columns: Int, direction: Direction
    ) -> Int? {
        guard count > 0, index >= 0, index < count else { return nil }
        let columns = max(1, columns)

        switch direction {
        case .left, .right:
            // A single column is a list. Left and right would otherwise behave as previous and
            // next, which is not what those keys mean in a list and makes the cursor appear to
            // jump for no reason.
            guard columns > 1 else { return nil }
            let next = direction == .left ? index - 1 : index + 1
            return (0..<count).contains(next) ? next : nil

        case .up:
            let next = index - columns
            return next >= 0 ? next : nil

        case .down:
            let next = index + columns
            if next < count { return next }
            // Down from a full row into a shorter last row lands on its final item, which is what
            // every macOS grid does. Down from the last row itself has nowhere to go.
            let lastRowStart = ((count - 1) / columns) * columns
            return index < lastRowStart ? count - 1 : nil
        }
    }

    /// How many columns an adaptive grid fits, matching `GridItem(.adaptive(minimum:))`.
    ///
    /// SwiftUI does not report this, and up/down navigation is wrong by however much the estimate
    /// is out — the cursor jumps diagonally. Mirroring the same arithmetic keeps them in step.
    public static func columnCount(
        availableWidth: CGFloat, minimumItemWidth: CGFloat, spacing: CGFloat
    ) -> Int {
        guard availableWidth > 0, minimumItemWidth > 0 else { return 1 }
        return max(1, Int((availableWidth + spacing) / (minimumItemWidth + spacing)))
    }

    /// The contiguous range between two indices, in either order.
    ///
    /// Shift-clicking below the anchor and shift-clicking above it have to select the same way.
    public static func range(from anchor: Int, to target: Int) -> ClosedRange<Int> {
        anchor <= target ? anchor...target : target...anchor
    }
}
