import Foundation
import ClipRoidCore
import ClipRoidStore
import os.log

/// Applies the retention policy periodically and on demand.
///
/// Clips accumulate fast, and images dominate the footprint (spec §8.3). Without this the store
/// grows without bound while Settings claims a limit is in force.
public actor RetentionSweeper {
    private let store: ClipStore
    private var policy: RetentionPolicy
    private let interval: Duration
    private let logger = Logger(subsystem: "dev.philtronic.ClipRoid", category: "Retention")

    private var task: Task<Void, Never>?

    public init(store: ClipStore, policy: RetentionPolicy = .default, interval: Duration = .seconds(900)) {
        self.store = store
        self.policy = policy
        self.interval = interval
    }

    public func updatePolicy(_ policy: RetentionPolicy) {
        self.policy = policy
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            // Sweep once shortly after launch to catch anything that aged out while the app was
            // closed — particularly `secret` clips, whose whole point is a short clock.
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self.sweep()
                try? await Task.sleep(for: await self.interval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    @discardableResult
    public func sweep(now: Date = Date()) async -> [Int64] {
        do {
            let purged = try await store.applyRetention(policy: policy, now: now)
            if !purged.isEmpty {
                logger.info("Retention removed \(purged.count) clip(s)")
            }
            return purged
        } catch {
            logger.error("Retention sweep failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
