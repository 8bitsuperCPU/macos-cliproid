import Foundation

/// Retention policy from Settings (spec §4.19). Either limit can be disabled independently.
public struct RetentionPolicy: Sendable, Equatable {
    public var maxClipCount: Int?
    public var maxAgeDays: Int?
    /// Spec §4.7: `secret` clips can be aged out far more aggressively than ordinary ones.
    public var secretMaxAgeHours: Int?

    public init(maxClipCount: Int? = nil, maxAgeDays: Int? = nil, secretMaxAgeHours: Int? = nil) {
        self.maxClipCount = maxClipCount
        self.maxAgeDays = maxAgeDays
        self.secretMaxAgeHours = secretMaxAgeHours
    }

    /// 10,000 clips, matching the figure spec §13 sets as the performance target.
    public static let `default` = RetentionPolicy(maxClipCount: 10_000, maxAgeDays: 90)

    public var isUnlimited: Bool {
        maxClipCount == nil && maxAgeDays == nil && secretMaxAgeHours == nil
    }

    public func ageCutoff(now: Date) -> Date? {
        maxAgeDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
    }

    public func secretCutoff(now: Date) -> Date? {
        secretMaxAgeHours.map { now.addingTimeInterval(-Double($0) * 3_600) }
    }
}

/// Which clips a policy would remove. Pure, so the rules are testable without a database.
public enum RetentionEvaluator {
    /// A clip the user has explicitly kept is never purged by a policy they probably forgot they
    /// set. Pins and favourites are the user saying "keep this"; silently deleting them would be a
    /// betrayal of that, and a support ticket nobody can reproduce.
    public struct Candidate: Sendable, Equatable {
        public var id: Int64
        public var copiedAt: Date
        public var isPinned: Bool
        public var isFavorite: Bool
        public var sensitivity: Sensitivity

        public init(id: Int64, copiedAt: Date, isPinned: Bool = false,
                    isFavorite: Bool = false, sensitivity: Sensitivity = .none) {
            self.id = id
            self.copiedAt = copiedAt
            self.isPinned = isPinned
            self.isFavorite = isFavorite
            self.sensitivity = sensitivity
        }

        public var isProtected: Bool { isPinned || isFavorite }
    }

    public static func idsToPurge(
        candidates: [Candidate], policy: RetentionPolicy, now: Date = Date()
    ) -> [Int64] {
        guard !policy.isUnlimited else { return [] }

        var doomed = Set<Int64>()
        let newestFirst = candidates.sorted { $0.copiedAt > $1.copiedAt }

        if let cutoff = policy.ageCutoff(now: now) {
            for c in newestFirst where !c.isProtected && c.copiedAt < cutoff {
                doomed.insert(c.id)
            }
        }

        // Secrets age out on their own, much shorter clock — the point of the setting is that a
        // copied credential should not sit in the history for 90 days.
        if let cutoff = policy.secretCutoff(now: now) {
            for c in newestFirst where !c.isProtected && c.sensitivity == .secret && c.copiedAt < cutoff {
                doomed.insert(c.id)
            }
        }

        if let limit = policy.maxClipCount {
            // Protected clips are kept but still occupy the budget, so the count the user set is
            // the count they actually get.
            var kept = 0
            for c in newestFirst {
                if doomed.contains(c.id) { continue }
                kept += 1
                if kept > limit && !c.isProtected { doomed.insert(c.id) }
            }
        }

        return candidates.filter { doomed.contains($0.id) }.map(\.id)
    }
}
