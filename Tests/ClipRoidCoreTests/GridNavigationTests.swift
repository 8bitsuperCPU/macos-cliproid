import Testing
import Foundation
@testable import ClipRoidCore

@Suite("Grid navigation")
struct GridNavigationTests {
    typealias Nav = GridNavigation

    @Test("Left and right walk the row")
    func horizontal() {
        #expect(Nav.destination(from: 1, count: 9, columns: 3, direction: .right) == 2)
        #expect(Nav.destination(from: 1, count: 9, columns: 3, direction: .left) == 0)
    }

    /// Right at the end and left at the start return nil rather than the same index, so the view
    /// leaves the key unhandled instead of silently eating it.
    @Test("The ends of the collection are not wrapped or swallowed")
    func horizontalEdges() {
        #expect(Nav.destination(from: 0, count: 9, columns: 3, direction: .left) == nil)
        #expect(Nav.destination(from: 8, count: 9, columns: 3, direction: .right) == nil)
    }

    /// Right from the end of a row continues onto the next, which is what a grid of tiles reads
    /// as — the alternative, stopping at each row end, makes arrowing through a long grid painful.
    @Test("Right moves onto the next row")
    func rowWrap() {
        #expect(Nav.destination(from: 2, count: 9, columns: 3, direction: .right) == 3)
    }

    @Test("Up and down move by a whole row")
    func vertical() {
        #expect(Nav.destination(from: 4, count: 9, columns: 3, direction: .up) == 1)
        #expect(Nav.destination(from: 4, count: 9, columns: 3, direction: .down) == 7)
    }

    @Test("Up from the first row has nowhere to go")
    func topEdge() {
        #expect(Nav.destination(from: 1, count: 9, columns: 3, direction: .up) == nil)
    }

    /// Down from a full row into a shorter last row lands on its final item rather than doing
    /// nothing — 7 clips in 3 columns leaves a last row of one.
    @Test("Down into a partly filled last row lands on its final item")
    func partialLastRow() {
        #expect(Nav.destination(from: 5, count: 7, columns: 3, direction: .down) == 6)
        // Already in the last row: nowhere further down.
        #expect(Nav.destination(from: 6, count: 7, columns: 3, direction: .down) == nil)
    }

    /// In a list, left and right are not "previous" and "next" — treating them that way makes the
    /// cursor jump for no reason the user can see.
    @Test("A single column ignores left and right")
    func listIgnoresHorizontal() {
        #expect(Nav.destination(from: 2, count: 5, columns: 1, direction: .left) == nil)
        #expect(Nav.destination(from: 2, count: 5, columns: 1, direction: .right) == nil)
        #expect(Nav.destination(from: 2, count: 5, columns: 1, direction: .up) == 1)
        #expect(Nav.destination(from: 2, count: 5, columns: 1, direction: .down) == 3)
    }

    @Test("An empty or out-of-range collection moves nowhere")
    func degenerate() {
        #expect(Nav.destination(from: 0, count: 0, columns: 3, direction: .down) == nil)
        #expect(Nav.destination(from: 9, count: 5, columns: 3, direction: .up) == nil)
        #expect(Nav.destination(from: -1, count: 5, columns: 3, direction: .up) == nil)
    }

    /// Zero columns would divide the layout by zero; it is clamped rather than trapped.
    @Test("A nonsense column count is clamped, not crashed")
    func clampsColumns() {
        #expect(Nav.destination(from: 1, count: 5, columns: 0, direction: .down) == 2)
    }

    /// The estimate has to match what LazyVGrid actually lays out, or up and down move diagonally.
    @Test("Column count matches an adaptive grid")
    func columnCount() {
        // Three 100pt items with 10pt gaps need 320pt; 330 fits three, 319 only two.
        #expect(Nav.columnCount(availableWidth: 330, minimumItemWidth: 100, spacing: 10) == 3)
        #expect(Nav.columnCount(availableWidth: 319, minimumItemWidth: 100, spacing: 10) == 2)
        // Never zero, however narrow the window gets.
        #expect(Nav.columnCount(availableWidth: 10, minimumItemWidth: 100, spacing: 10) == 1)
        #expect(Nav.columnCount(availableWidth: 0, minimumItemWidth: 100, spacing: 10) == 1)
    }

    @Test("Shift-extension works in both directions")
    func ranges() {
        #expect(Nav.range(from: 2, to: 5) == 2...5)
        #expect(Nav.range(from: 5, to: 2) == 2...5)
        #expect(Nav.range(from: 3, to: 3) == 3...3)
    }
}
