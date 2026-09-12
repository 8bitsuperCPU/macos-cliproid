import Testing
import Foundation
import SwiftUI
@testable import ClipRoidUI
import ClipRoidKit

@Suite("Shelf sizing")
@MainActor
struct ShelfMetricsTests {

    /// The reported bug: reducing the clip count left the shelf the same size, because its width
    /// was a flat 600pt rather than derived from its contents.
    @Test("Tile length grows with thickness")
    func lengthTracksThickness() {
        let small = ShelfMetrics.itemLength(forThickness: 54)
        let large = ShelfMetrics.itemLength(forThickness: 140)
        #expect(large > small)
    }

    /// A tall square showing three words is worse than a wider tile showing a line, so tiles
    /// widen once they are big enough to carry a preview.
    @Test("Tiles widen once they are large enough to preview")
    func tilesWidenForPreviews() {
        let compact = ShelfMetrics.itemLength(forThickness: 60)
        #expect(compact == ShelfMetrics.itemBreadth(forThickness: 60), "square while compact")

        let big = ShelfMetrics.itemLength(forThickness: 140)
        #expect(big > ShelfMetrics.itemBreadth(forThickness: 140), "wider than tall once previewing")
    }

    @Test("Thickness is clamped to a usable range", arguments: [
        (10.0, 44.0), (44.0, 44.0), (100.0, 100.0), (170.0, 170.0), (9_999.0, 170.0),
    ])
    func clampsThickness(input: Double, expected: Double) {
        #expect(SettingsStore.clampThickness(input) == expected)
    }

    @Test("Previews switch on only above the threshold")
    func previewThreshold() {
        let defaults = UserDefaults(suiteName: "ShelfMetrics-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)

        settings.shelfThickness = 54
        #expect(!settings.shelfShowsPreviews)

        settings.shelfThickness = SettingsStore.previewThreshold
        #expect(settings.shelfShowsPreviews)

        settings.shelfThickness = 140
        #expect(settings.shelfShowsPreviews)
    }

    @Test("Shelf appearance settings persist")
    func appearancePersists() {
        let defaults = UserDefaults(suiteName: "ShelfAppearance-\(UUID().uuidString)")!
        do {
            let settings = SettingsStore(defaults: defaults)
            settings.shelfThickness = 120
            settings.shelfAutoHide = true
            settings.shelfBackground = .custom
            settings.shelfTintHex = "#2B4C7E"
            settings.shelfOpacity = 0.65
        }
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.shelfThickness == 120)
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
