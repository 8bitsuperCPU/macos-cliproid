import SwiftUI
import ClipRoidCore

/// An image that can be zoomed and panned.
///
/// Loads the full-resolution file rather than a thumbnail. Thumbnails are capped at 256px, so any
/// window bigger than a card upscales them several times over — which is where the blur in the
/// preview came from.
struct ZoomableImage: View {
    let url: URL?
    /// Pixel dimensions, used to decide whether a small image should be left alone.
    var imageSize: (width: Int, height: Int)?
    var showsControls: Bool = true

    @State private var zoom: Double = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    /// nil means "fit", which is the default and what most clips want.
    @State private var isFitting = true

    private let minZoom: Double = 0.25
    private let maxZoom: Double = 8

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let url {
                    AsyncImage(url: url) { image in
                        content(image, in: proxy.size)
                    } placeholder: {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            // Scroll to zoom, anchored where it usually is in image viewers.
            .onScrollWheel { delta in
                guard showsControls else { return }
                isFitting = false
                zoom = min(max(zoom * (1 + delta * 0.01), minZoom), maxZoom)
            }
            .overlay(alignment: .bottomTrailing) {
                if showsControls { controls }
            }
        }
    }

    @ViewBuilder
    private func content(_ image: Image, in available: CGSize) -> some View {
        if isFitting {
            // Fit, but never upscale a small image — blowing a 60x20 favicon up to fill the window
            // is blurry and tells the user less than showing it at its real size.
            image
                .resizable()
                .aspectRatio(contentMode: shouldScaleDown(in: available) ? .fit : .fill)
                .frame(
                    maxWidth: shouldScaleDown(in: available) ? .infinity : naturalWidth,
                    maxHeight: shouldScaleDown(in: available) ? .infinity : naturalHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(zoom)
                .offset(offset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: dragStart.width + value.translation.width,
                                height: dragStart.height + value.translation.height)
                        }
                        .onEnded { _ in dragStart = offset })
        }
    }

    private var naturalWidth: CGFloat? { imageSize.map { CGFloat($0.width) } }
    private var naturalHeight: CGFloat? { imageSize.map { CGFloat($0.height) } }

    private func shouldScaleDown(in available: CGSize) -> Bool {
        guard let size = imageSize else { return true }
        return CGFloat(size.width) > available.width || CGFloat(size.height) > available.height
    }

    private var controls: some View {
        HStack(spacing: 2) {
            button("minus.magnifyingglass", "Zoom out") {
                isFitting = false
                zoom = max(zoom / 1.4, minZoom)
            }
            Text(isFitting ? "Fit" : "\(Int(zoom * 100))%")
                .font(.caption2.monospacedDigit())
                .frame(width: 40)
                .foregroundStyle(.white)
            button("plus.magnifyingglass", "Zoom in") {
                isFitting = false
                zoom = min(zoom * 1.4, maxZoom)
            }
            button("arrow.up.left.and.down.right.magnifyingglass", "Fit to window") {
                isFitting = true
                zoom = 1
                offset = .zero
                dragStart = .zero
            }
        }
        .padding(4)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(8)
    }

    private func button(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Scroll-wheel reporting, which SwiftUI does not expose.
///
/// `onScrollWheel` rather than a magnification gesture: a trackpad pinch works through
/// `MagnificationGesture`, but a mouse wheel — which most people zoom images with — produces
/// nothing SwiftUI surfaces.
private struct ScrollWheelReader: NSViewRepresentable {
    var onScroll: (Double) -> Void

    func makeNSView(context: Context) -> NSView { WheelView(onScroll: onScroll) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WheelView)?.onScroll = onScroll
    }

    final class WheelView: NSView {
        var onScroll: (Double) -> Void
        init(onScroll: @escaping (Double) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func scrollWheel(with event: NSEvent) {
            // Only a deliberate zoom gesture, not ordinary two-finger scrolling, which would make
            // the image lurch every time the user scrolled a list behind it.
            guard event.modifierFlags.contains(.command) || event.phase == [] else {
                super.scrollWheel(with: event)
                return
            }
            onScroll(Double(event.scrollingDeltaY))
        }
    }
}

extension View {
    func onScrollWheel(_ action: @escaping (Double) -> Void) -> some View {
        background(ScrollWheelReader(onScroll: action))
    }
}
