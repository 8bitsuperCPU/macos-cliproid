import Testing
import Foundation
import SwiftUI
@testable import ClipRoidUI
import ClipRoidKit

@Suite("Shelf sizing")
@MainActor
struct ShelfMetricsTests {

    @Test("Cards grow with shelf thickness")
    func cardsTrackThickness() {
        let small = ShelfMetrics.cardSize(forThickness: 200)
        let large = ShelfMetrics.cardSize(forThickness: 300)
        #expect(large.height > small.height)
        #expect(large.width > small.width)
    }

    /// Cards are wider than tall, because a tall square showing three words reads worse than a
    /// wider card showing a line.
    @Test("Cards are landscape")
    func cardsAreLandscape() {
        let card = ShelfMetrics.cardSize(forThickness: 260)
        #expect(card.width > card.height)
    }

    /// Chrome — search row, chips, section header — has to fit before any card does, or a small
    /// shelf renders cards with negative height.
    @Test("Cards never collapse below a usable size, however thin the shelf")
    func cardsHaveAFloor() {
        for thickness in [44.0, 80.0, 108.0, 120.0] {
            let card = ShelfMetrics.cardSize(forThickness: thickness)
            #expect(card.height >= 64, "thickness \(thickness) produced \(card.height)")
        }
    }

    /// The reported bug: reducing the clip count left the shelf the same size, because its length
    /// was a flat 600pt rather than derived from its contents.
    @Test("Expanded length tracks the number of cards")
    func lengthTracksCardCount() {
        let few = ShelfMetrics.expandedLength(cardCount: 3, thickness: 260)
        let many = ShelfMetrics.expandedLength(cardCount: 12, thickness: 260)
        #expect(many > few * 2)
    }

    @Test("The collapsed nub is small but aimable")
    func collapsedNubIsSmall() {
        #expect(ShelfMetrics.collapsedThickness <= 8)
        #expect(ShelfMetrics.collapsedLength >= 100)
    }

    @Test("Thickness is clamped to a usable range", arguments: [
        (10.0, 180.0), (180.0, 180.0), (240.0, 240.0), (380.0, 380.0), (9_999.0, 380.0),
    ])
    func clampsThickness(input: Double, expected: Double) {
        #expect(SettingsStore.clampThickness(input) == expected)
    }

    @Test("Shelf appearance settings persist")
    func appearancePersists() {
        let defaults = UserDefaults(suiteName: "ShelfAppearance-\(UUID().uuidString)")!
        do {
            let settings = SettingsStore(defaults: defaults)
            settings.shelfThickness = 300
            settings.shelfAutoHide = true
            settings.shelfBackground = .custom
            settings.shelfTintHex = "#2B4C7E"
            settings.shelfOpacity = 0.65
        }
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.shelfThickness == 300)
        #expect(reloaded.shelfAutoHide)
        #expect(reloaded.shelfBackground == .custom)
        #expect(reloaded.shelfTintHex == "#2B4C7E")
        #expect(abs(reloaded.shelfOpacity - 0.65) < 0.001)
    }
}

@Suite("Colour parsing")
struct ColorHexTests {
    @Test("Hex round-trips through the picker", arguments: ["#FF8800", "#2B4C7E", "#000000", "#FFFFFF"])
    func roundTrips(hex: String) {
        let colour = Color(hex: hex)
        #expect(colour != nil)
        #expect(colour?.hexString == hex)
    }

    @Test("Malformed hex returns nil rather than a wrong colour", arguments: ["", "#", "nope", "#12345"])
    func rejectsMalformed(hex: String) {
        #expect(Color(hex: hex) == nil)
    }
}
