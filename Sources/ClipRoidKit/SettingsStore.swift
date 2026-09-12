import Foundation
import Observation
import ClipRoidCore
import ClipRoidPlatform

/// User preferences, backed by `UserDefaults` (spec §4.19).
///
/// Injectable defaults rather than `.standard`, so tests get an isolated suite and do not leave
/// residue in the developer's real preferences — the pattern `ScratchDefaults` in nyx's test
/// doubles exists for.
@MainActor
@Observable
public final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.shelfPositionRaw = defaults.string(forKey: Key.shelfPosition) ?? "top"
        // Clamped on read too: the stored value may predate the range, or have been hand-edited.
        self.storedShelfItemCount = Self.clampItemCount(
            defaults.object(forKey: Key.shelfItemCount) as? Int ?? 10)
        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        self.autoPasteEnabled = defaults.object(forKey: Key.autoPaste) as? Bool ?? true
        self.captureImages = defaults.object(forKey: Key.captureImages) as? Bool ?? true
        self.captureFiles = defaults.object(forKey: Key.captureFiles) as? Bool ?? true
        self.sensitiveDetectionEnabled = defaults.object(forKey: Key.sensitiveDetection) as? Bool ?? true
        self.hideSecretsFromShelf = defaults.object(forKey: Key.hideSecretsFromShelf) as? Bool ?? true
        self.maxClipCount = defaults.object(forKey: Key.maxClipCount) as? Int ?? 10_000
        self.maxClipAgeDays = defaults.object(forKey: Key.maxClipAgeDays) as? Int ?? 90
        self.ignoredBundleIds = defaults.stringArray(forKey: Key.ignoredApps) ?? []
        // Off by default, deliberately. Enabling it creates a keystroke tap, and that has to be a
        // decision the user makes rather than one they discover.
        self.inlineShortcutsEnabled = defaults.bool(forKey: Key.inlineShortcuts)
        self.shortcutPrefix = defaults.string(forKey: Key.shortcutPrefix) ?? ";"
        self.shortcutTriggerRaw = defaults.string(forKey: Key.shortcutTrigger) ?? "space"
        self.storedShelfThickness = Self.clampThickness(
            defaults.object(forKey: Key.shelfThickness) as? Double ?? 240)
        self.shelfAutoHide = defaults.bool(forKey: Key.shelfAutoHide)
        self.shelfBackgroundRaw = defaults.string(forKey: Key.shelfBackground) ?? "material"
        self.shelfTintHex = defaults.string(forKey: Key.shelfTintHex) ?? "#1C1C1E"
        self.shelfOpacity = defaults.object(forKey: Key.shelfOpacity) as? Double ?? 0.9
        self.storedCollapsedThickness = Self.clampCollapsedThickness(
            defaults.object(forKey: Key.collapsedThickness) as? Double ?? 12)
        self.storedCollapsedLength = Self.clampCollapsedLength(
            defaults.object(forKey: Key.collapsedLength) as? Double ?? 264)
        self.collapsedRainbow = defaults.bool(forKey: Key.collapsedRainbow)
        self.shelfTextStyleRaw = defaults.string(forKey: Key.shelfTextStyle) ?? "automatic"
    }

    private enum Key {
        static let shelfPosition = "shelf.position"
        static let shelfItemCount = "shelf.itemCount"
        static let launchAtLogin = "general.launchAtLogin"
        static let autoPaste = "paste.autoPaste"
        static let captureImages = "capture.images"
        static let captureFiles = "capture.files"
        static let sensitiveDetection = "sensitive.enabled"
        static let hideSecretsFromShelf = "sensitive.hideFromShelf"
        static let maxClipCount = "retention.maxCount"
        static let maxClipAgeDays = "retention.maxAgeDays"
        static let ignoredApps = "capture.ignoredApps"
        static let inlineShortcuts = "shortcuts.enabled"
        static let shortcutPrefix = "shortcuts.prefix"
        static let shortcutTrigger = "shortcuts.trigger"
        static let shelfThickness = "shelf.thickness"
        static let shelfAutoHide = "shelf.autoHide"
        static let shelfBackground = "shelf.background"
        static let shelfTintHex = "shelf.tintHex"
        static let shelfOpacity = "shelf.opacity"
        static let collapsedThickness = "shelf.collapsed.thickness"
        static let collapsedLength = "shelf.collapsed.length"
        static let collapsedRainbow = "shelf.collapsed.rainbow"
        static let shelfTextStyle = "shelf.textStyle"
    }

    /// Stored as its raw string so an unknown value from a future version degrades to the default
    /// rather than failing to decode.
    private var shelfPositionRaw: String {
        didSet { defaults.set(shelfPositionRaw, forKey: Key.shelfPosition) }
    }

    public var shelfPosition: ShelfPositionSetting {
        get { ShelfPositionSetting(rawValue: shelfPositionRaw) ?? .top }
        set { shelfPositionRaw = newValue.rawValue }
    }

    /// Spec §4.19 allows 5–20, clamped on write so a corrupt or hand-edited plist cannot produce a
    /// shelf of 10,000 items — which would hang the UI rather than fail visibly.
    ///
    /// Written as an explicit computed property rather than `didSet { value = clamp(value) }`.
    /// That shorthand is safe on a plain class, where assigning to a property inside its own
    /// `didSet` does not re-enter the observer — but `@Observable` rewrites stored properties into
    /// real getters and setters, so the self-assignment *does* re-enter, recurses without bound,
    /// and takes the process down with a stack overflow. The crash is a bare SIGSEGV with no test
    /// failure attached, which makes it thoroughly unpleasant to track down.
    @ObservationIgnored private var storedShelfItemCount: Int
    public var shelfItemCount: Int {
        get {
            access(keyPath: \.shelfItemCount)
            return storedShelfItemCount
        }
        set {
            withMutation(keyPath: \.shelfItemCount) {
                storedShelfItemCount = Self.clampItemCount(newValue)
                defaults.set(storedShelfItemCount, forKey: Key.shelfItemCount)
            }
        }
    }

    static func clampItemCount(_ value: Int) -> Int { min(max(value, 5), 20) }

    public var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            LaunchAtLogin.set(launchAtLogin)
        }
    }

    public var autoPasteEnabled: Bool {
        didSet { defaults.set(autoPasteEnabled, forKey: Key.autoPaste) }
    }
    public var captureImages: Bool {
        didSet { defaults.set(captureImages, forKey: Key.captureImages) }
    }
    public var captureFiles: Bool {
        didSet { defaults.set(captureFiles, forKey: Key.captureFiles) }
    }
    public var sensitiveDetectionEnabled: Bool {
        didSet { defaults.set(sensitiveDetectionEnabled, forKey: Key.sensitiveDetection) }
    }
    public var hideSecretsFromShelf: Bool {
        didSet { defaults.set(hideSecretsFromShelf, forKey: Key.hideSecretsFromShelf) }
    }
    public var maxClipCount: Int {
        didSet { defaults.set(maxClipCount, forKey: Key.maxClipCount) }
    }
    public var maxClipAgeDays: Int {
        didSet { defaults.set(maxClipAgeDays, forKey: Key.maxClipAgeDays) }
    }
    public var ignoredBundleIds: [String] {
        didSet { defaults.set(ignoredBundleIds, forKey: Key.ignoredApps) }
    }

    public var inlineShortcutsEnabled: Bool {
        didSet { defaults.set(inlineShortcutsEnabled, forKey: Key.inlineShortcuts) }
    }
    public var shortcutPrefix: String {
        didSet { defaults.set(shortcutPrefix, forKey: Key.shortcutPrefix) }
    }
    private var shortcutTriggerRaw: String {
        didSet { defaults.set(shortcutTriggerRaw, forKey: Key.shortcutTrigger) }
    }
    public var shortcutTrigger: ShortcutTrigger {
        get { ShortcutTrigger(rawValue: shortcutTriggerRaw) ?? .space }
        set { shortcutTriggerRaw = newValue.rawValue }
    }
    public var shortcutPrefixCharacter: Character {
        shortcutPrefix.first ?? ";"
    }

    // MARK: - Shelf appearance

    /// Height of a horizontal shelf, or width of a vertical one.
    ///
    /// Same explicit-computed-property shape as `shelfItemCount`, and for the same reason: a
    /// `didSet` that reassigns itself recurses without bound under `@Observable`.
    @ObservationIgnored private var storedShelfThickness: Double
    public var shelfThickness: Double {
        get {
            access(keyPath: \.shelfThickness)
            return storedShelfThickness
        }
        set {
            withMutation(keyPath: \.shelfThickness) {
                storedShelfThickness = Self.clampThickness(newValue)
                defaults.set(storedShelfThickness, forKey: Key.shelfThickness)
            }
        }
    }

    /// The expanded panel's height. It carries a search row, a chip row, a section header and a
    /// row of cards, so the useful range starts where a card is still legible and stops before
    /// the shelf becomes a window in its own right.
    public nonisolated static func clampThickness(_ value: Double) -> Double { min(max(value, 180), 380) }

    /// Above this, tiles are tall enough to show a useful preview of the clip rather than just an
    /// icon. Below it a preview would be a few illegible pixels.
    ///
    /// `nonisolated` because layout code needs it outside the main actor.
    public nonisolated static let previewThreshold: Double = 92

    public var shelfShowsPreviews: Bool { shelfThickness >= Self.previewThreshold }

    // MARK: - Collapsed bar

    /// Height of the collapsed bar for a top or bottom shelf; width for a side one.
    @ObservationIgnored private var storedCollapsedThickness: Double
    public var collapsedThickness: Double {
        get {
            access(keyPath: \.collapsedThickness)
            return storedCollapsedThickness
        }
        set {
            withMutation(keyPath: \.collapsedThickness) {
                storedCollapsedThickness = Self.clampCollapsedThickness(newValue)
                defaults.set(storedCollapsedThickness, forKey: Key.collapsedThickness)
            }
        }
    }

    /// How long the collapsed bar is along the screen edge.
    @ObservationIgnored private var storedCollapsedLength: Double
    public var collapsedLength: Double {
        get {
            access(keyPath: \.collapsedLength)
            return storedCollapsedLength
        }
        set {
            withMutation(keyPath: \.collapsedLength) {
                storedCollapsedLength = Self.clampCollapsedLength(newValue)
                defaults.set(storedCollapsedLength, forKey: Key.collapsedLength)
            }
        }
    }

    /// Below about 4pt the bar is hard to hit deliberately; above ~40pt it stops being a hint and
    /// starts occupying the screen it was meant to give back.
    public nonisolated static func clampCollapsedThickness(_ value: Double) -> Double {
        min(max(value, 4), 40)
    }

    public nonisolated static func clampCollapsedLength(_ value: Double) -> Double {
        min(max(value, 60), 900)
    }

    /// An animated gradient on the collapsed bar.
    ///
    /// Off by default: it repaints continuously while on screen, which is real work for an
    /// always-present element, so it should be a choice rather than something a user discovers
    /// their battery paying for.
    public var collapsedRainbow: Bool {
        didSet { defaults.set(collapsedRainbow, forKey: Key.collapsedRainbow) }
    }

    public var shelfAutoHide: Bool {
        didSet { defaults.set(shelfAutoHide, forKey: Key.shelfAutoHide) }
    }

    private var shelfBackgroundRaw: String {
        didSet { defaults.set(shelfBackgroundRaw, forKey: Key.shelfBackground) }
    }
    public var shelfBackground: ShelfBackground {
        get { ShelfBackground(rawValue: shelfBackgroundRaw) ?? .material }
        set { shelfBackgroundRaw = newValue.rawValue }
    }

    private var shelfTextStyleRaw: String {
        didSet { defaults.set(shelfTextStyleRaw, forKey: Key.shelfTextStyle) }
    }
    public var shelfTextStyle: ShelfTextStyle {
        get { ShelfTextStyle(rawValue: shelfTextStyleRaw) ?? .automatic }
        set { shelfTextStyleRaw = newValue.rawValue }
    }

    public var shelfTintHex: String {
        didSet { defaults.set(shelfTintHex, forKey: Key.shelfTintHex) }
    }
    public var shelfOpacity: Double {
        didSet { defaults.set(shelfOpacity, forKey: Key.shelfOpacity) }
    }

    public var retentionPolicy: RetentionPolicy {
        RetentionPolicy(
            maxClipCount: maxClipCount > 0 ? maxClipCount : nil,
            maxAgeDays: maxClipAgeDays > 0 ? maxClipAgeDays : nil)
    }
}

public enum ShelfTextStyle: String, CaseIterable, Sendable {
    /// Chosen from the background's brightness. The default, because the failure it prevents —
    /// white text on a white shelf, invisible — is one the user should never be able to reach by
    /// picking a colour they liked.
    case automatic
    case light
    case dark

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light text"
        case .dark: "Dark text"
        }
    }
}

public enum ShelfBackground: String, CaseIterable, Sendable {
    /// The system blur, which adapts to light and dark and to whatever is behind it.
    case material
    /// A flat colour the user picks.
    case custom

    public var displayName: String {
        switch self {
        case .material: "System blur"
        case .custom: "Custom colour"
        }
    }
}

/// Mirrors `ShelfPosition` in the UI layer. Kit cannot import ClipRoidUI — the dependency runs the
/// other way — so the persisted representation lives here and the UI maps to its own enum.
public enum ShelfPositionSetting: String, CaseIterable, Sendable {
    case top, left, right, bottom, hidden

    public var displayName: String {
        switch self {
        case .top: "Top"
        case .left: "Left"
        case .right: "Right"
        case .bottom: "Bottom"
        case .hidden: "Hidden"
        }
    }
}
