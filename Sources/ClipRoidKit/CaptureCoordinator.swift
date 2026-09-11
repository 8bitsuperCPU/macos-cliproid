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
    private let ignoredBundleIds: Set<String>
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "Capture")

    private var task: Task<Void, Never>?

    public init(poller: PasteboardPoller, store: ClipStore, ignoredBundleIds: Set<String> = []) {
        self.poller = poller
        self.store = store
        self.ignoredBundleIds = ignoredBundleIds
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
            try await store.insert(clip)
        } catch {
            logger.error("Failed to store clip: \(error.localizedDescription, privacy: .public)")
        }
    }
}
