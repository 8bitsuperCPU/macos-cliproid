import SwiftUI
import ClipRoidKit

/// Colours for the shelf, kept in one place.
///
/// The card surface is deliberately **independent of the panel background**. The reported bug was
/// that changing the shelf's background colour also recoloured every clip tile, because the tiles
/// used a semantic material (`.quaternary`) that blends with whatever is behind it. Against a
/// custom opaque panel that made the cards vanish into the background.
///
/// A card is its own surface: always opaque, always a fixed step lighter than the panel, whatever
/// the user picks. Its job is to read as a distinct object sitting *on* the shelf.
enum ShelfPalette {
    /// Card surface — fixed, opaque, never derived from the panel colour.
    static let card = Color(red: 0.14, green: 0.14, blue: 0.15)
    static let cardHovered = Color(red: 0.20, green: 0.20, blue: 0.22)
    static let cardBorder = Color.white.opacity(0.07)

    /// Chrome that sits directly on the panel.
    static let controlFill = Color.white.opacity(0.08)
    static let controlFillHovered = Color.white.opacity(0.14)

    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.5)
    static let tertiaryText = Color.white.opacity(0.35)

    /// The selected chip is a white pill with dark text, as in the reference.
    static let selectedChip = Color.white
    static let selectedChipText = Color(red: 0.08, green: 0.08, blue: 0.09)

    static let defaultPanel = Color(red: 0.07, green: 0.07, blue: 0.08)

    @MainActor
    static func panel(_ settings: SettingsStore) -> Color {
        switch settings.shelfBackground {
        case .material: defaultPanel
        case .custom: Color(hex: settings.shelfTintHex) ?? defaultPanel
        }
    }
}
