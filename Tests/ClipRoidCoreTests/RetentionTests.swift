import Testing
import Foundation
@testable import ClipRoidCore

@Suite("Retention rules")
struct RetentionTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func candidate(
        _ id: Int64, daysAgo: Double, pinned: Bool = false,
        favorite: Bool = false, sensitivity: Sensitivity = .none
    ) -> RetentionEvaluator.Candidate {
        RetentionEvaluator.Candidate(
            id: id, copiedAt: now.addingTimeInterval(-daysAgo * 86_400),
            isPinned: pinned, isFavorite: favorite, sensitivity: sensitivity)
    }

    @Test("An unlimited policy purges nothing")
    func unlimitedKeepsEverything() {
        let clips = (1...100).map { candidate(Int64($0), daysAgo: Double($0) * 10) }
        #expect(RetentionEvaluator.idsToPurge(
            candidates: clips, policy: RetentionPolicy(), now: now).isEmpty)
    }

    @Test("Age-based retention removes only clips past the cutoff")
    func purgesByAge() {
        let clips = [candidate(1, daysAgo: 1), candidate(2, daysAgo: 50), candidate(3, daysAgo: 120)]
        let purged = RetentionEvaluator.idsToPurge(
            candidates: clips, policy: RetentionPolicy(maxAgeDays: 90), now: now)
        #expect(purged == [3])
    }

    @Test("Count-based retention keeps the newest N")
    func purgesByCount() {
        let clips = (1...10).map { candidate(Int64($0), daysAgo: Double($0)) }
        let purged = Set(RetentionEvaluator.idsToPurge(
            candidates: clips, policy: RetentionPolicy(maxClipCount: 3), now: now))
        // Newest three are ids 1, 2, 3 (smallest daysAgo).
        #expect(purged == Set([4, 5, 6, 7, 8, 9, 10]))
    }

    /// A pin or a favourite is the user saying "keep this". Silently deleting it because of a
    /// retention setting they configured months ago is a betrayal of that, and a support report
    /// nobody can reproduce.
    @Test("Pinned and favourite clips are never purged, however old")
    func protectsPinnedAndFavorites() {
        let clips = [
            candidate(1, daysAgo: 5000, pinned: true),
            candidate(2, daysAgo: 5000, favorite: true),
            candidate(3, daysAgo: 5000),
        ]
        let purged = RetentionEvaluator.idsToPurge(
            candidates: clips, policy: RetentionPolicy(maxClipCount: 1, maxAgeDays: 30), now: now)
        #expect(purged == [3])
    }

    @Test("Secrets age out on their own, much shorter clock")
    func purgesSecretsEarly() {
        let clips = [
            candidate(1, daysAgo: 0.5, sensitivity: .secret),   // 12h old
            candidate(2, daysAgo: 0.1, sensitivity: .secret),   // ~2.4h old
            candidate(3, daysAgo: 0.5),                          // ordinary, same age
        ]
        let purged = RetentionEvaluator.idsToPurge(
            candidates: clips,
            policy: RetentionPolicy(maxAgeDays: 90, secretMaxAgeHours: 6),
            now: now)
        #expect(purged == [1], "only the secret past its own cutoff")
    }

    @Test("Protected clips still count against the budget")
    func protectedOccupyBudget() {
        // The user asked for 2 clips. With one pinned, they should end up with exactly 2 total —
        // not 2 unprotected plus the pin.
        let clips = [
            candidate(1, daysAgo: 1, pinned: true),
            candidate(2, daysAgo: 2),
            candidate(3, daysAgo: 3),
        ]
        let purged = RetentionEvaluator.idsToPurge(
            candidates: clips, policy: RetentionPolicy(maxClipCount: 2), now: now)
        #expect(purged == [3])
    }
}
