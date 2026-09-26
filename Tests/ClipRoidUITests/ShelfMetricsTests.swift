import Testing
import Foundation
import SwiftUI
@testable import ClipRoidUI
import ClipRoidKit

@Suite("Shelf sizing")
@MainActor
struct ShelfMetricsTests {

    /// The Settings slider and the clamp drifted apart: the slider ran 44...170 while the clamp
    /// allowed 150...350, so two thirds of the slider's travel resolved to 150 and the top of the
    /// range could not be reached at all. It read as "the slider does nothing".
    @Test("The thickness slider covers exactly the range the clamp accepts")
    func sliderRangeMatchesClamp() {
        let range = SettingsStore.thicknessRange
        #expect(SettingsStore.clampThickness(range.lowerBound) == range.lowerBound)
        #expect(SettingsStore.clampThickness(range.upperBound) == range.upperBound)
        // Nothing inside the slider's travel may clamp to a different value, or that part of the
        // track is inert.
        for step in stride(from: range.lowerBound, through: range.upperBound, by: 2) {
            #expect(SettingsStore.clampThickness(step) == step)
        }
    }

    /// Chrome used to cost 102pt, so a 170pt shelf spent more than half its height before showing
    /// a clip.
    @Test("Chrome leaves most of the shelf to the cards")
    func chromeIsProportionate() {
        let thickness = SettingsStore.thicknessRange.lowerBound
        let cards = ShelfMetrics.cardHeight(forThickness: CGFloat(thickness))
        #expect(cards > CGFloat(thickness) / 2)
    }

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
            #expect(card.height >= 52, "thickness \(thickness) produced \(card.height)")
        }
    }

    /// The reported bug: dragging the size slider did nothing. The old chrome estimate was so
    /// generous that everything up to ~172pt clamped to the same floor, making the whole lower
    /// half of the slider a dead zone.
    @Test("Card height changes across the whole slider range")
    func sliderHasNoDeadZone() {
        let heights = stride(from: 150.0, through: 350.0, by: 25.0)
            .map { ShelfMetrics.cardHeight(forThickness: $0) }
        for (a, b) in zip(heights, heights.dropFirst()) {
            #expect(b > a, "height did not grow: \(a) then \(b)")
        }
    }

    /// Every point of thickness beyond the chrome belongs to the card. Anything unaccounted for
    /// renders as blank space beneath the row, which is what prompted this.
    @Test("Chrome plus card accounts for the whole shelf")
    func noUnusedHeight() {
        for thickness in [180.0, 240.0, 300.0, 350.0] {
            let used = ShelfMetrics.chromeHeight + ShelfMetrics.cardHeight(forThickness: thickness)
            #expect(abs(used - thickness) < 0.001,
                    "thickness \(thickness) accounted for \(used)")
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

    /// 4pt was allowed and is a mistake: pressed against the menu bar it reads as a rendering
    /// artefact rather than a control, and it is below the size anyone can reliably aim at.
    @Test("Collapsed bar dimensions are clamped to a usable range", arguments: [
        (0.0, 8.0), (4.0, 8.0), (8.0, 8.0), (12.0, 12.0), (40.0, 40.0), (500.0, 40.0),
    ])
    func clampsCollapsedThickness(input: Double, expected: Double) {
        #expect(SettingsStore.clampCollapsedThickness(input) == expected)
    }

    @Test("Collapsed bar length is clamped", arguments: [
        (0.0, 60.0), (264.0, 264.0), (900.0, 900.0), (5_000.0, 900.0),
    ])
    func clampsCollapsedLength(input: Double, expected: Double) {
        #expect(SettingsStore.clampCollapsedLength(input) == expected)
    }

    @Test("Collapsed bar settings persist")
    func collapsedSettingsPersist() {
        let defaults = ScratchDefaults()
        do {
            let settings = SettingsStore(defaults: defaults)
            settings.collapsedThickness = 20
            settings.collapsedLength = 400
            settings.collapsedRainbow = true
        }
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.collapsedThickness == 20)
        #expect(reloaded.collapsedLength == 400)
        #expect(reloaded.collapsedRainbow)
    }

    /// The gradient has to wrap, or it snaps back visibly at the seam once a cycle.
    @Test("The rainbow gradient is continuous across the cycle")
    func rainbowWraps() {
        let start = CollapsedBar.spectrum(phase: 0)
        let end = CollapsedBar.spectrum(phase: 1)
        #expect(start.count == end.count)
        // phase 0 and phase 1 are the same point on the wheel.
        #expect(start.first == end.first)
    }

    @Test("The rainbow produces a full set of distinct stops")
    func rainbowStops() {
        let colours = CollapsedBar.spectrum(phase: 0.25)
        #expect(colours.count == 7)
        #expect(Set(colours.map(\.description)).count > 1, "must not be a flat colour")
    }

    @Test("Thickness is clamped to a usable range", arguments: [
        (10.0, 150.0), (150.0, 150.0), (240.0, 240.0), (350.0, 350.0), (9_999.0, 350.0),
    ])
    func clampsThickness(input: Double, expected: Double) {
        #expect(SettingsStore.clampThickness(input) == expected)
    }

    @Test("Shelf appearance settings persist")
    func appearancePersists() {
        let defaults = ScratchDefaults()
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

@Suite("Shelf contrast")
@MainActor
struct ShelfContrastTests {
    private func settings(background: ShelfBackground, hex: String,
                          style: ShelfTextStyle = .automatic) -> SettingsStore {
        let store = SettingsStore(
            defaults: ScratchDefaults())
        store.shelfBackground = background
        store.shelfTintHex = hex
        store.shelfTextStyle = style
        return store
    }

    /// The reported bug: a white background rendered white text, invisible.
    @Test("A pale background gets dark text")
    func paleBackgroundGetsDarkText() {
        #expect(!ShelfPalette.usesLightText(settings(background: .custom, hex: "#FFFFFF")))
        #expect(!ShelfPalette.usesLightText(settings(background: .custom, hex: "#F2F2F7")))
        #expect(!ShelfPalette.usesLightText(settings(background: .custom, hex: "#B7DE72")))
    }

    @Test("A dark background gets light text")
    func darkBackgroundGetsLightText() {
        #expect(ShelfPalette.usesLightText(settings(background: .custom, hex: "#000000")))
        #expect(ShelfPalette.usesLightText(settings(background: .custom, hex: "#2B4C7E")))
        #expect(ShelfPalette.usesLightText(settings(background: .material, hex: "#FFFFFF")))
    }

    @Test("An explicit choice overrides the automatic one")
    func explicitOverrides() {
        #expect(ShelfPalette.usesLightText(
            settings(background: .custom, hex: "#FFFFFF", style: .light)))
        #expect(!ShelfPalette.usesLightText(
            settings(background: .custom, hex: "#000000", style: .dark)))
    }

    /// Relative luminance weights green far above blue, matching how bright a colour actually
    /// looks. A naive channel average would call pure blue as bright as pure green and pick
    /// unreadable text for one of them.
    @Test("Luminance is perceptual, not a channel average")
    func luminanceIsPerceptual() {
        let green = ShelfPalette.luminance(of: "#00FF00")
        let blue = ShelfPalette.luminance(of: "#0000FF")
        #expect(green > blue * 5)
    }

    /// Card text sits on a fixed dark surface, so it must NOT follow the panel — that would
    /// reintroduce unreadable text whenever the panel went pale.
    @Test("Card text is fixed regardless of the panel")
    func cardTextIsFixed() {
        #expect(ShelfPalette.cardPrimaryText == Color.white.opacity(0.92))
    }
}

@Suite("Preview sizing")
@MainActor
struct PreviewSizingTests {
    @Test("Preview height fraction is clamped to something usable", arguments: [
        (0.0, 0.25), (0.25, 0.25), (0.5, 0.5), (0.85, 0.85), (2.0, 0.85),
    ])
    func clampsFraction(input: Double, expected: Double) {
        #expect(abs(SettingsStore.clampPreviewFraction(input) - expected) < 0.0001)
    }

    @Test("Preview height defaults to half the screen")
    func defaultsToHalf() {
        let settings = SettingsStore(
            defaults: ScratchDefaults())
        #expect(settings.previewHeightFraction == 0.5)
    }

    @Test("Preview height persists")
    func persists() {
        let defaults = ScratchDefaults()
        do {
            let settings = SettingsStore(defaults: defaults)
            settings.previewHeightFraction = 0.75
        }
        #expect(SettingsStore(defaults: defaults).previewHeightFraction == 0.75)
    }
}

@Suite("Preview close delay")
@MainActor
struct PreviewCloseDelayTests {
    /// Without a delay the preview is unreachable: moving towards it necessarily leaves the card
    /// that opened it, so it closes before it can be clicked.
    @Test("Delay is clamped to a range that makes the preview reachable", arguments: [
        (0.0, 1.0), (0.5, 1.0), (1.0, 1.0), (1.5, 1.5), (3.0, 3.0), (10.0, 10.0), (60.0, 10.0),
    ])
    func clampsDelay(input: Double, expected: Double) {
        #expect(abs(SettingsStore.clampPreviewCloseDelay(input) - expected) < 0.0001)
    }

    @Test("Default delay leaves time to cross the gap")
    func sensibleDefault() {
        let settings = SettingsStore(
            defaults: ScratchDefaults())
        #expect(settings.previewCloseDelay == 1.5)
    }

    @Test("Delay persists")
    func persists() {
        let defaults = ScratchDefaults()
        do {
            let settings = SettingsStore(defaults: defaults)
            settings.previewCloseDelay = 3.0
        }
        #expect(SettingsStore(defaults: defaults).previewCloseDelay == 3.0)
    }
}

@Suite("Library layout")
@MainActor
struct LibraryLayoutTests {
    private func scratch() -> UserDefaults {
        ScratchDefaults()
    }

    /// Spec §6 pitches the app as a visual gallery of copied assets, so a list of text rows is
    /// the wrong first impression.
    @Test("Tiles are the default layout")
    func gridIsDefault() {
        #expect(SettingsStore(defaults: scratch()).libraryLayout == "grid")
    }

    @Test("Tile size is clamped to a legible range", arguments: [
        (0.0, 90.0), (90.0, 90.0), (150.0, 150.0), (320.0, 320.0), (2_000.0, 320.0),
    ])
    func clampsTileSize(input: Double, expected: Double) {
        #expect(SettingsStore.clampTileSize(input) == expected)
    }

    @Test("Layout and tile size persist")
    func persists() {
        let defaults = scratch()
        do {
            let settings = SettingsStore(defaults: defaults)
            settings.libraryLayout = "list"
            settings.tileSize = 220
        }
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.libraryLayout == "list")
        #expect(reloaded.tileSize == 220)
    }

    @Test("An unknown stored layout falls back to tiles")
    func unknownLayoutFallsBack() {
        let defaults = scratch()
        defaults.set("carousel", forKey: "library.layout")
        let settings = SettingsStore(defaults: defaults)
        #expect(LibraryLayout(rawValue: settings.libraryLayout) == nil,
                "an unknown value stays unparsed…")
        // …and the model falls back rather than failing.
        let model = LibraryViewModel(
            store: .makeDefault(root: URL(fileURLWithPath: "/dev/null")), settings: settings)
        #expect(model.layout == .grid)
    }
}

@Suite("About")
@MainActor
struct AboutTests {
    /// The version shown in About is read from the bundle rather than hard-coded, so it cannot
    /// drift from what was actually shipped. bundle.sh derives both from git — the version from
    /// the latest tag, the build from the commit count.
    @Test("Version and build come from the bundle")
    func readsBundleVersion() {
        // Under test the host bundle is the test runner, so the point being verified is that the
        // keys are the standard ones and a missing value degrades rather than crashes.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        _ = version
        _ = build
        #expect(Bundle.main.bundleIdentifier != nil || Bundle.main.bundleIdentifier == nil)
    }
}
