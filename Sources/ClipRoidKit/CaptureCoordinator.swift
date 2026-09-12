import Foundation
import ClipRoidCore
import ClipRoidStore
import os.log

/// Drains the poller's snapshot stream, classifies each one, and writes it to the store.
///
/// Deliberately the only place those three meet. Because it is built from protocols rather than
/// concrete types, the entire capture pipeline can be driven in tests with a fake pasteboard and a
/// temp-directory store — including the self-write regression test.
public actor CaptureCoordinator {
    private let poller: PasteboardPoller
    private let store: ClipStore
    private let smartFilters: SmartFilterService?
    private var ignoredBundleIds: Set<String>
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "Capture")

    private var task: Task<Void, Never>?

    public init(poller: PasteboardPoller, store: ClipStore,
                smartFilters: SmartFilterService? = nil, ignoredBundleIds: Set<String> = []) {
        self.poller = poller
        self.store = store
        self.smartFilters = smartFilters
        self.ignoredBundleIds = ignoredBundleIds
    }

    public func updateIgnoredApps(_ bundleIds: Set<String>) {
        ignoredBundleIds = bundleIds
    }

    public func start() async {
        guard task == nil else { return }
        let stream = await poller.snapshots()
        await poller.start()
        task = Task { [weak self] in
            for await snapshot in stream {
                await self?.ingest(snapshot)
            }
        }
    }

    public func stop() async {
        task?.cancel()
        task = nil
        await poller.stop()
    }

    /// Public so tests can drive a snapshot straight through without a timer.
    public func ingest(_ snapshot: RawSnapshot) async {
        if let bundleId = snapshot.sourceAppBundleId, ignoredBundleIds.contains(bundleId) {
            return
        }
        guard let clip = ClipClassifier.classify(snapshot) else { return }
        do {
            let summary = try await store.insert(clip)

            // Auto-tags describe the *inside* of a clip — the domain a link points at, the kind of
            // file copied. Content type and source app are deliberately not tagged: they are
            // already sidebar facets, and duplicating them would fill the cloud with "text" and
            // "Safari". See AutoTags.
            let tags = AutoTags.tags(for: clip)
            if !tags.isEmpty {
                try? await store.addTags(tags, toClip: summary.id)
            }
            // Filed after the insert, never before: a rule must not be able to prevent a clip
            // being captured, and smart filtering failing is not a reason to lose the clip.
            await smartFilters?.apply(
                toClipId: summary.id,
                candidate: SmartFilterEngine.Candidate(
                    contentType: clip.contentType,
                    sourceAppBundleId: clip.sourceAppBundleId,
                    sourceAppName: clip.sourceAppName,
                    text: clip.body))
        } catch {
            logger.error("Failed to store clip: \(error.localizedDescription, privacy: .public)")
        }
    }
}
