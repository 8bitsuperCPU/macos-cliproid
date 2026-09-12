import Testing
import Foundation
import AppKit
@testable import ClipRoidKit
import ClipRoidCore
import ClipRoidStore
import ClipRoidPlatform

@Suite("Tools")
@MainActor
struct ToolsServiceTests {

    /// Stands in for the system loupe, which cannot be driven from a test.
    private final class FakeSampler: ColorPicking {
        var next: String?
        var callCount = 0
        init(next: String?) { self.next = next }
        func pickColor() async -> String? {
            callCount += 1
            return next
        }
    }

    private func makeStore() async throws -> ClipStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ClipStore.makeDefault(root: dir)
        try await store.open(backupDirectory: nil)
        return store
    }

    /// The whole point of the tool: a picked colour has to land in the history. Writing the hex
    /// to the pasteboard cannot do it, because ClipDroid suppresses its own writes.
    @Test("Picking a colour files it as a colour clip")
    func picksAndSaves() async throws {
        let store = try await makeStore()
        let tools = ToolsService(store: store, sampler: FakeSampler(next: "#3366FF"))

        let picked = await tools.pickColour()
        #expect(picked == "#3366FF")

        let clips = try await store.recent(limit: 10)
        #expect(clips.count == 1)
        #expect(clips.first?.contentType == .color)
        #expect(clips.first?.colorHex == "#3366FF")
        await store.close()
    }

    /// Escape from the loupe must leave no trace — a cancelled pick that still filed a clip
    /// would be worse than the tool not existing.
    @Test("Cancelling the picker saves nothing")
    func cancelSavesNothing() async throws {
        let store = try await makeStore()
        let tools = ToolsService(store: store, sampler: FakeSampler(next: nil))

        let picked = await tools.pickColour()
        #expect(picked == nil)
        #expect(try await store.recent(limit: 10).isEmpty)
        await store.close()
    }

    /// Both colour paths — the screen loupe and the image eyedropper — go through one factory,
    /// so neither can end up filing a colour without its `colorHex` metadata and quietly missing
    /// from the Colours filter.
    @Test("The colour clip factory always sets the hex as metadata")
    func factorySetsMetadata() {
        let clip = ColorClip.captured(
            hex: "#ABCDEF", origin: "Picked from the screen",
            appBundleId: "dev.philtronic.ClipRoid", appName: "ClipDroid")
        #expect(clip.contentType == .color)
        #expect(clip.colorHex == "#ABCDEF")
        #expect(clip.body == "#ABCDEF")
        #expect(clip.title == "Picked from the screen")
    }

    /// The loupe reports colours in the display's own space. Without converting to sRGB the hex
    /// would not match what any other app shows for the same pixel.
    @Test("Colours are converted to sRGB before being read")
    func convertsToSRGB() throws {
        #expect(SystemColorSampler.hex(from: .white) == "#FFFFFF")
        #expect(SystemColorSampler.hex(from: .black) == "#000000")

        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        #expect(SystemColorSampler.hex(from: red) == "#FF0000")

        // Pure red in display-P3 is outside the sRGB gamut, so its components land beyond 0–1
        // when converted. Unclamped that formats as garbage rather than #FF0000.
        let wide = NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)
        let hex = try #require(SystemColorSampler.hex(from: wide))
        #expect(hex.count == 7)
        #expect(hex.hasPrefix("#"))
        let digits = hex.dropFirst()
        #expect(digits.allSatisfy { $0.isHexDigit }, "clamped, not overflowed: \(hex)")
    }

    /// A hex the picker produces must be one the classifier and the format converter accept, or
    /// the clip shows a swatch the "Copy as RGB" menu cannot convert.
    @Test("Picked hexes round-trip through the format converter")
    func roundTripsThroughFormats() throws {
        let hex = try #require(SystemColorSampler.hex(from: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)))
        let components = try #require(ColorFormats.components(fromHex: hex))
        #expect(abs(components.r - 0.2) < 0.01)
        #expect(abs(components.g - 0.4) < 0.01)
        #expect(abs(components.b - 0.6) < 0.01)
        #expect(ColorFormats.string(.rgb, fromHex: hex) == "rgb(51, 102, 153)")
    }
}
