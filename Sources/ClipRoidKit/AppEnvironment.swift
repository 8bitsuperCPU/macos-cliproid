import Foundation
import ClipRoidCore
import ClipRoidStore
import ClipRoidPlatform
import os.log

/// Everything the app owns exactly once, constructed once in `App.init` and passed down.
///
/// Same pattern and same reason as ~/projects/nyx/Sources/NyxLib/AppEnvironment.swift: it exists so
/// there is exactly one handle on the store. Two `ClipStore`s over one SQLite file is a class of bug
/// that shows up as intermittent corruption long after the code that caused it.
@MainActor
public final class AppEnvironment {
    public let store: ClipStore
    public let pasteboard: SystemPasteboard
    public let poller: PasteboardPoller
    public let capture: CaptureCoordinator
    public let enrichment: EnrichmentPipeline
    public let retention: RetentionSweeper
    public let hotKeys: HotKeyCenter
    public let settings: SettingsStore
    public let smartFilters: SmartFilterService
    public let shortcuts: ShortcutExpander
    public let externalEditor: ExternalEditor
    public let paste: PasteCoordinator
    private let deliverer = PasteDeliverer()

    /// Set by the UI layer, which owns the panel. Kit deliberately does not import SwiftUI, so the
    /// hotkey handler calls out through this rather than reaching into a window itself.
    public var onQuickPasteHotKey: (@MainActor () -> Void)?
    public var onRecentSlotHotKey: (@MainActor (Int) -> Void)?

    /// App Nap will throttle a background app's timers, which for this app means silently missing
    /// clips. The token returned by `beginActivity` must be **retained** — dropping it ends the
    /// assertion immediately and the call becomes a silent no-op. (The spec named
    /// `NSProcessAssertActivity`, which is not an API.)
    private var activityToken: (any NSObjectProtocol)?

    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "Environment")

    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Still "ClipRoid", deliberately, even though the app is now called ClipDroid.
        //
        // This directory holds every clip the user has. Renaming it would orphan their entire
        // history behind a folder the app no longer looks in — a rename of the product is not a
        // reason to lose their data. Same reasoning keeps the bundle identifier unchanged: it is
        // what TCC keys the Accessibility grant on and what UserDefaults keys every preference on,
        // so changing it would silently reset both.
        return base.appendingPathComponent("ClipRoid", isDirectory: true)
    }

    public init(root: URL = AppEnvironment.defaultRoot()) {
        let store = ClipStore.makeDefault(root: root)
        let pasteboard = SystemPasteboard()
        let poller = PasteboardPoller(
            pasteboard: pasteboard,
            frontmost: WorkspaceFrontmostAppProvider(),
            idleSeconds: { SystemIdle.secondsSinceLastInput() }
        )
        self.store = store
        self.pasteboard = pasteboard
        self.poller = poller
        let filters = SmartFilterService(store: store)
        self.smartFilters = filters
        self.capture = CaptureCoordinator(poller: poller, store: store, smartFilters: filters)
        self.settings = SettingsStore()
        self.enrichment = EnrichmentPipeline(
            store: store, recognizer: VisionTextRecognizer(),
            linkPreviews: LinkPreviewFetcher())
        self.retention = RetentionSweeper(store: store)
        self.hotKeys = HotKeyCenter()
        self.externalEditor = ExternalEditor(store: store)
        self.shortcuts = ShortcutExpander(
            store: store, observer: KeystrokeObserver(), pasteboard: pasteboard)
        self.paste = PasteCoordinator(
            store: store, pasteboard: pasteboard,
            deliverer: deliverer, frontmost: WorkspaceFrontmostAppProvider())
    }

    /// Registers the global hotkeys. Separate from `start()` because the UI must have installed its
    /// callbacks first — a hotkey that fires into a nil handler is a silently dead shortcut.
    public func registerHotKeys() {
        let quickPasteID = hotKeys.register(.quickPaste) { [weak self] _ in
            guard let self else { return }
            // Capture the target BEFORE the panel appears. One frame later the frontmost app is
            // ClipRoid and the real target is gone.
            self.paste.markHotKeyFired()
            self.paste.captureTarget()
            self.onQuickPasteHotKey?()
        }
        Diagnostics.log(quickPasteID == nil
            ? "FAILED to register \(HotKeySpec.quickPaste.displayString) — another app likely owns it"
            : "Registered \(HotKeySpec.quickPaste.displayString) for Quick Paste")

        for slot in 0...9 {
            guard let spec = HotKeySpec.recentSlot(slot) else { continue }
            hotKeys.register(spec) { [weak self] _ in
                guard let self else { return }
                self.paste.captureTarget()
                self.onRecentSlotHotKey?(slot)
            }
        }
    }

    /// Pastes the Nth most recent clip directly, with no window (spec §4.19).
    public func pasteRecentSlot(_ slot: Int) async {
        guard let clips = try? await store.recent(limit: 10),
              clips.indices.contains(slot) else { return }
        await paste.paste(clips[slot])
    }

    public func start() async {
        do {
            try await store.open(backupDirectory: Self.defaultRoot().appendingPathComponent("Backups"))
        } catch {
            logger.error("Could not open store: \(error.localizedDescription, privacy: .public)")
            return
        }
        // `.userInitiatedAllowingIdleSystemSleep`, deliberately, NOT `.userInitiated`.
        //
        // `.userInitiated` implies `.idleSystemSleepDisabled`, which stops the Mac sleeping for as
        // long as the app runs — visible in `pmset -g assertions` as a PreventUserIdleSystemSleep
        // assertion. For a clipboard manager that sits in the background all day that is indefensible:
        // it would silently cost the user hours of battery and keep their machine awake overnight.
        //
        // What is actually needed is only the App Nap half — without an activity assertion the
        // system throttles a background app's timers and the poller starts missing clips. This
        // option gives exactly that and lets the machine sleep normally. Nothing needs capturing
        // while the Mac is asleep, because nothing can be copied.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Monitoring the clipboard for new clips"
        )
        Diagnostics.log("ClipDroid starting — Accessibility granted: \(PasteDeliverer.isAccessibilityGranted)")
        let count = await pasteboard.changeCount
        await poller.seed(changeCount: count)
        await capture.start()
        await enrichment.start()
        await retention.updatePolicy(settings.retentionPolicy)
        await retention.start()
        await capture.updateIgnoredApps(Set(settings.ignoredBundleIds))
        applyPasteSettings()
        await applyLinkPreviewSettings()
        await applyShortcutSettings()
    }

    /// Pushes changed retention preferences to the sweeper without waiting for the next sweep.
    public func applyRetentionSettings() async {
        await retention.updatePolicy(settings.retentionPolicy)
    }

    /// Pushes the auto-paste preference to the deliverer. Without this the Settings toggle is a
    /// control that looks live and changes nothing.
    public func applyPasteSettings() {
        deliverer.isAutoPasteEnabled = settings.autoPasteEnabled
    }

    /// Hands the link-preview preference to the enrichment actor.
    public func applyLinkPreviewSettings() async {
        await enrichment.setFetchLinkPreviews(settings.fetchLinkPreviews)
    }

    /// Starts or tears down the keystroke tap to match the preference.
    ///
    /// Turning the feature off destroys the tap rather than leaving it running with its output
    /// ignored — see ShortcutExpander and plan risk R5.
    public func applyShortcutSettings() async {
        shortcuts.updateSettings(
            prefix: settings.shortcutPrefixCharacter, trigger: settings.shortcutTrigger)

        if settings.inlineShortcutsEnabled {
            let started = await shortcuts.start()
            if !started {
                Diagnostics.log("Inline shortcuts could not start — Accessibility not granted")
            }
        } else if shortcuts.isRunning {
            shortcuts.stop()
        }
    }

    public func stop() async {
        externalEditor.stopAll()
        shortcuts.stop()
        hotKeys.shutdown()
        await retention.stop()
        await enrichment.stop()
        await capture.stop()
        await store.close()
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }
}
