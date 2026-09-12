import Testing
import Foundation
@testable import ClipRoidKit
import ClipRoidCore
import ClipRoidStore

@Suite("Smart filter service")
struct SmartFilterServiceTests {

    private func open(_ scratch: ScratchDirectory) async throws -> ClipStore {
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)
        return store
    }

    private func clip(_ body: String, type: ClipContentType = .text, app: String? = nil) -> CapturedClip {
        CapturedClip(contentType: type, contentHash: Dedupe.hash(body + (app ?? "")),
                     body: body, sourceAppBundleId: app,
                     sourceAppName: app?.components(separatedBy: ".").last)
    }

    @Test("A rule files a newly captured clip")
    func filesOnCapture() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        let category = try await store.createCategory(name: "Design Assets")
        try await store.createRule(SmartFilterRule(
            id: 0, name: "Figma", categoryId: category.id, sourceAppBundleId: "figma"))

        let service = SmartFilterService(store: store)
        let summary = try await store.insert(clip("a frame", type: .image, app: "com.figma.Desktop"))
        await service.apply(
            toClipId: summary.id,
            candidate: .init(contentType: .image, sourceAppBundleId: "com.figma.Desktop",
                             sourceAppName: "Desktop", text: nil))

        #expect(try await store.categoryIds(forClip: summary.id) == [category.id])
        await store.close()
    }

    /// Spec §4.2 requires rules to apply retroactively as well as at capture. The same pure
    /// function serves both, so they cannot disagree about what a rule means.
    @Test("Rules re-apply across existing history")
    func reappliesRetroactively() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)

        for i in 1...50 {
            try await store.insert(clip("invoice number \(i)"))
            try await store.insert(clip("unrelated note \(i)"))
        }

        let category = try await store.createCategory(name: "Invoices")
        try await store.createRule(SmartFilterRule(
            id: 0, name: "Invoices", categoryId: category.id, textPattern: "invoice"))

        let service = SmartFilterService(store: store)
        let assigned = await service.reapplyToAll(batchSize: 20)

        #expect(assigned == 50)
        #expect(try await store.categoryCounts()[category.id] == 50)
        await store.close()
    }

    @Test("Re-applying twice does not duplicate assignments")
    func reapplyIsIdempotent() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        try await store.insert(clip("invoice 1"))
        let category = try await store.createCategory(name: "Invoices")
        try await store.createRule(SmartFilterRule(
            id: 0, name: "Invoices", categoryId: category.id, textPattern: "invoice"))

        let service = SmartFilterService(store: store)
        await service.reapplyToAll()
        await service.reapplyToAll()

        #expect(try await store.categoryCounts()[category.id] == 1)
        await store.close()
    }

    /// An edit must take effect on the very next clip, not after a restart.
    @Test("Editing a rule invalidates the cache")
    func editInvalidatesCache() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        let category = try await store.createCategory(name: "Code")
        let service = SmartFilterService(store: store)

        // Prime the cache while there are no rules.
        let first = try await store.insert(clip("func f() {}", type: .code))
        await service.apply(toClipId: first.id,
                            candidate: .init(contentType: .code, text: "func f() {}"))
        #expect(try await store.categoryIds(forClip: first.id).isEmpty)

        try await store.createRule(SmartFilterRule(
            id: 0, name: "Code", categoryId: category.id, contentType: .code))
        await service.invalidateRules()

        let second = try await store.insert(clip("let x = 1", type: .code))
        await service.apply(toClipId: second.id,
                            candidate: .init(contentType: .code, text: "let x = 1"))
        #expect(try await store.categoryIds(forClip: second.id) == [category.id])
        await store.close()
    }

    /// A category is a label. Deleting one must never take clips with it.
    @Test("Deleting a category keeps the clips")
    func deletingCategoryKeepsClips() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        let category = try await store.createCategory(name: "Temporary")
        let summary = try await store.insert(clip("important content"))
        try await store.assign(clipIds: [summary.id], toCategory: category.id)

        try await store.deleteCategory(id: category.id)

        #expect(try await store.count() == 1)
        #expect(try await store.categoryIds(forClip: summary.id).isEmpty)
        #expect(try await store.fullText(id: summary.id) == "important content")
        await store.close()
    }
}

@Suite("Tags")
struct TagTests {
    private func open(_ scratch: ScratchDirectory) async throws -> ClipStore {
        let store = ClipStore.makeDefault(root: scratch.url)
        try await store.open(backupDirectory: nil)
        return store
    }

    @Test("Tags round-trip and are case-normalised")
    func roundTrips() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        let clip = try await store.insert(CapturedClip(
            contentType: .text, contentHash: "a", body: "hello"))

        try await store.addTags(["Invoice", "URGENT"], toClip: clip.id)
        #expect(try await store.tags(forClip: clip.id) == ["invoice", "urgent"])

        // Re-adding must not duplicate — a tag is a set membership, not a list entry.
        try await store.addTags(["invoice"], toClip: clip.id)
        #expect(try await store.tags(forClip: clip.id).count == 2)

        try await store.removeTag("urgent", fromClip: clip.id)
        #expect(try await store.tags(forClip: clip.id) == ["invoice"])
        await store.close()
    }

    @Test("Tag counts drive the cloud, most used first")
    func countsForCloud() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        for i in 1...5 {
            let clip = try await store.insert(CapturedClip(
                contentType: .text, contentHash: "c\(i)", body: "clip \(i)"))
            try await store.addTags(i <= 3 ? ["common"] : ["rare"], toClip: clip.id)
        }
        let counts = try await store.tagCounts()
        #expect(counts.first?.name == "common")
        #expect(counts.first?.count == 3)
        await store.close()
    }

    /// Without pruning, a tag cloud slowly fills with entries no clip references — the visible
    /// residue of every retention sweep.
    @Test("Orphan tags are pruned when their clips are deleted")
    func prunesOrphans() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        let clip = try await store.insert(CapturedClip(
            contentType: .text, contentHash: "a", body: "hello"))
        try await store.addTags(["ephemeral"], toClip: clip.id)
        #expect(try await store.tagCounts().count == 1)

        try await store.delete(ids: [clip.id])
        try await store.pruneOrphanTags()
        #expect(try await store.tagCounts().isEmpty)
        await store.close()
    }

    @Test("Filtering by tag returns only that tag's clips")
    func filtersByTag() async throws {
        let scratch = ScratchDirectory()
        let store = try await open(scratch)
        let a = try await store.insert(CapturedClip(contentType: .text, contentHash: "a", body: "one"))
        let b = try await store.insert(CapturedClip(contentType: .text, contentHash: "b", body: "two"))
        try await store.addTags(["keep"], toClip: a.id)
        _ = b

        let hits = try await store.clips(withTag: "keep")
        #expect(hits.map(\.id) == [a.id])
        await store.close()
    }
}
