import Foundation
import ClipRoidCore
import os.log

/// Watches the pasteboard change count and emits raw snapshots.
///
/// Polling rather than an observer because macOS provides no reliable asynchronous pasteboard
/// change callback that covers every content type (spec §8.3).
///
/// The tick does the minimum: read the count, read declared types, read bytes, hand off, return.
/// Everything expensive — classification, hashing, disk, OCR — happens on the consumer side, so a
/// 40MB image copy cannot stall the next tick.
public actor PasteboardPoller {
    public struct Interval: Sendable {
        public var active: Duration = .milliseconds(300)
        public var idle: Duration = .milliseconds(800)
        public var deepIdle: Duration = .seconds(2)
        public init() {}
    }

    private let pasteboard: any PasteboardReading
    private let frontmost: any FrontmostAppProviding
    private let idleSeconds: @Sendable () -> TimeInterval
    private let intervals: Interval
    private let maxBytes: Int
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "Poller")

    private var lastSeenChangeCount = -1
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<RawSnapshot>.Continuation?

    public init(
        pasteboard: any PasteboardReading,
        frontmost: any FrontmostAppProviding,
        idleSeconds: @escaping @Sendable () -> TimeInterval = { 0 },
        intervals: Interval = Interval(),
        maxBytes: Int = SizeLimits.defaultMaxCaptureBytes
    ) {
        self.pasteboard = pasteboard
        self.frontmost = frontmost
        self.idleSeconds = idleSeconds
        self.intervals = intervals
        self.maxBytes = maxBytes
    }

    /// `.bufferingNewest(8)` rather than unbounded: if the consumer falls behind, dropping the
    /// oldest pending snapshot is the right failure. Spec §10 already accepts that extremely fast
    /// copy sequences may not all be captured.
    public func snapshots() -> AsyncStream<RawSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            self.continuation = continuation
        }
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            // Task.sleep on the actor rather than Timer or a DispatchSourceTimer: no run-loop
            // dependency, cancellation is structured, and it composes with the App Nap assertion.
            while !Task.isCancelled {
                let delay = await self.currentInterval()
                try? await Task.sleep(for: delay)
                if Task.isCancelled { break }
                await self.tick()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }

    /// Three-per-second forever on battery is rude. Back off while the user is away and snap back
    /// on their first input. Worst case a clip lands two seconds late during an idle window — which
    /// by definition is a window where nobody is waiting for it.
    func currentInterval() -> Duration {
        let idle = idleSeconds()
        return switch idle {
        case ..<5: intervals.active
        case ..<60: intervals.idle
        default: intervals.deepIdle
        }
    }

    func tick() async {
        let count = await pasteboard.changeCount
        guard count != lastSeenChangeCount else { return }
        lastSeenChangeCount = count

        // Layer 1 of the self-capture guard: skip anything we wrote ourselves.
        guard await !pasteboard.isOwnChange(count) else { return }

        let app = frontmost.frontmostApp()
        guard let snapshot = await pasteboard.snapshot(sourceApp: app, maxBytes: maxBytes) else {
            return
        }
        continuation?.yield(snapshot)
    }

    /// Adopt the current change count without emitting it, so the first tick after launch does
    /// not treat whatever happens to be on the pasteboard as a brand-new copy.
    public func seed(changeCount: Int) {
        lastSeenChangeCount = changeCount
    }
}
