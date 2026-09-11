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

    /// App Nap will throttle a background app's timers, which for this app means silently missing
    /// clips. The token returned by `beginActivity` must be **retained** — dropping it ends the
    /// assertion immediately and the call becomes a silent no-op. (The spec named
    /// `NSProcessAssertActivity`, which is not an API.)
    private var activityToken: (any NSObjectProtocol)?

    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "Environment")

    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
        self.capture = CaptureCoordinator(poller: poller, store: store)
        self.enrichment = EnrichmentPipeline(store: store, recognizer: VisionTextRecognizer())
        self.retention = RetentionSweeper(store: store)
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
        let count = await pasteboard.changeCount
        await poller.seed(changeCount: count)
        await capture.start()
        await enrichment.start()
        await retention.start()
    }

    public func stop() async {
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
