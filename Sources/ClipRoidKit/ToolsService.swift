import Foundation
import AppKit
import ClipRoidCore
import ClipRoidStore
import ClipRoidPlatform

/// The tools that create clips rather than capture them (spec §4.13, §4.14).
///
/// These insert into the store directly instead of writing to the pasteboard. ClipDroid suppresses
/// its own pasteboard writes — deliberately, or every paste would echo back as a new clip — so a
/// tool that only wrote the hex would produce nothing at all.
@MainActor
public final class ToolsService {
    private let store: ClipStore
    private let sampler: ColorPicking
    private let paste: PasteCoordinator?

    public init(store: ClipStore, sampler: ColorPicking, paste: PasteCoordinator? = nil) {
        self.store = store
        self.sampler = sampler
        self.paste = paste
    }

    /// Opens the system loupe and files whatever the user picks.
    ///
    /// Also puts the hex on the pasteboard, because "pick a colour" almost always means "and let
    /// me paste it somewhere" — the clip is the record, the pasteboard is the immediate use.
    @discardableResult
    public func pickColour() async -> String? {
        guard let hex = await sampler.pickColor() else { return nil }

        let clip = ColorClip.captured(
            hex: hex, origin: "Picked from the screen",
            appBundleId: Bundle.main.bundleIdentifier, appName: "ClipDroid")
        do {
            _ = try await store.insert(clip)
        } catch {
            Diagnostics.log("Colour picker could not save \(hex): \(error)")
        }
        await paste?.writeOnly(.text(hex), originClipUUID: clip.uuid)
        return hex
    }
}
