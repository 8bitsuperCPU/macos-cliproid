import Foundation
import ClipRoidCore
import ClipRoidStore
import ClipRoidImaging
import os.log

/// Work that happens *after* a clip is stored: thumbnails, OCR, link titles.
///
/// Separated from capture for two reasons. Capture must stay fast enough that a clip is in the
/// store before the user can press Ctrl+Cmd+V — roughly 200ms — and OCR on a full-screen
/// screenshot is far slower than that. And enrichment is allowed to fail: a clip with no thumbnail
/// is still a usable clip, so nothing here may ever block or discard a capture.
///
/// An actor rather than a queue because spec §8.3 asks for one OCR operation at a time. Copying
/// fifty screenshots in a minute should not start fifty concurrent Vision requests.
public actor EnrichmentPipeline {
    private let store: ClipStore
    private let recognizer: any TextRecognizing
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "Enrichment")

    private var task: Task<Void, Never>?
    private var idlePause: Duration = .seconds(2)

    public init(store: ClipStore, recognizer: any TextRecognizing) {
        self.store = store
        self.recognizer = recognizer
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let processed = await self.drainOnce()
                // Only sleep when there was nothing to do. With a backlog, keep going — but yield
                // between items so a large backfill cannot monopolise the cooperative pool.
                if processed == 0 {
                    try? await Task.sleep(for: await self.idlePause)
                } else {
                    await Task.yield()
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Exposed so tests can run the pipeline deterministically rather than racing a background loop.
    @discardableResult
    public func drainOnce(limit: Int = 10) async -> Int {
        let jobs: [ClipStore.EnrichmentJob]
        do {
            jobs = try await store.pendingEnrichment(limit: limit)
        } catch {
            logger.error("Could not read the enrichment backlog: \(error.localizedDescription, privacy: .public)")
            return 0
        }

        for job in jobs {
            await process(job)
        }
        return jobs.count
    }

    private func process(_ job: ClipStore.EnrichmentJob) async {
        var ocrText: String?
        var thumbnailPath: String?
        var title: String?
        var state = EnrichmentState.done

        switch job.contentType {
        case .image, .screenshot:
            guard let path = job.imageBlobPath,
                  let data = await store.imageData(forBlobPath: path) else {
                // The blob is gone — the row outlived its bytes. Mark it resolved rather than
                // retrying forever; a permanently failing job at the head of the backlog would
                // starve everything behind it.
                await apply(job, ocrText: nil, thumbnailPath: nil, title: nil, state: .failed)
                return
            }

            if let info = Thumbnailer.inspect(data) {
                try? await store.setImageDimensions(id: job.id, width: info.width, height: info.height)
            }
            if let thumb = Thumbnailer.thumbnailPNG(from: data) {
                thumbnailPath = try? await store.writeThumbnail(thumb, uuid: job.uuid)
            }
            do {
                ocrText = try await recognizer.recognizeText(in: data)
            } catch {
                logger.error("OCR failed for clip \(job.id): \(error.localizedDescription, privacy: .public)")
                // A thumbnail without OCR is still worth keeping, so this is not a total failure.
                state = thumbnailPath == nil ? .failed : .done
            }

        case .link:
            // Fetching a page title means a network request per copied link, which contradicts the
            // "fully offline, no phone-home" promise in spec §9 unless the user opts in. Deferred
            // rather than quietly implemented; the host is already shown on the card.
            title = job.linkUrl.flatMap { URL(string: $0)?.host() }
            state = .done

        default:
            state = .notApplicable
        }

        await apply(job, ocrText: ocrText, thumbnailPath: thumbnailPath, title: title, state: state)
    }

    private func apply(
        _ job: ClipStore.EnrichmentJob, ocrText: String?, thumbnailPath: String?,
        title: String?, state: EnrichmentState
    ) async {
        do {
            try await store.applyEnrichment(
                id: job.id, ocrText: ocrText, thumbnailPath: thumbnailPath,
                title: title, state: state)
        } catch {
            logger.error("Could not apply enrichment to \(job.id): \(error.localizedDescription, privacy: .public)")
        }
    }
}
