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

    public var retentionPolicy: RetentionPolicy {
        RetentionPolicy(
            maxClipCount: maxClipCount > 0 ? maxClipCount : nil,
            maxAgeDays: maxClipAgeDays > 0 ? maxClipAgeDays : nil)
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
