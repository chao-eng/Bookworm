import SwiftUI
import AppKit

struct PagedReaderView: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ZoomablePageView(model: model,
                                 pageIndex: model.currentPage,
                                 displaySize: geo.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        handleClick(at: location, container: geo.size)
                    }

                // Translate overlay sits on top of the page and renders OCR'd
                // bubbles with hover tooltips. Hidden unless translate mode
                // is on so it costs zero in the common case.
                if model.translateMode {
                    TranslateOverlayView(model: model,
                                         settings: TranslationSettings.shared,
                                         displaySize: geo.size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(true)
                }
            }
        }
    }

    private func handleClick(at location: CGPoint, container: CGSize) {
        // Tap-to-page: tap on right third goes next (in LTR), left third goes prev.
        let third = container.width / 3
        if location.x < third {
            model.direction == .rightToLeft ? model.goNext() : model.goPrev()
        } else if location.x > container.width - third {
            model.direction == .rightToLeft ? model.goPrev() : model.goNext()
        }
    }
}

struct ZoomablePageView: View {
    @ObservedObject var model: ReaderModel
    let pageIndex: Int
    let displaySize: CGSize

    @State private var image: NSImage?
    @State private var placeholder: NSImage?

    var body: some View {
        Group {
            if let img = image {
                // Keep the same ZoomScrollView (and the same underlying
                // NSScrollView) across page changes — so a pinch zoom the
                // user has done persists into the next page, and there's no
                // tear-down/rebuild flash when flipping pages.
                ZoomScrollView(
                    image: img,
                    zoomMode: model.zoomMode,
                    onUserMagnify: { mag in
                        // Capture the pinch into the model so the next page
                        // (which goes through applyZoom on image swap)
                        // continues at the same magnification.
                        model.zoomMode = .custom(mag)
                    }
                )
            } else if let placeholder = placeholder {
                ZStack {
                    Image(nsImage: placeholder)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .blur(radius: 6)
                        .opacity(0.65)
                    ProgressView()
                        .controlSize(.large)
                        .tint(model.backgroundDark ? .white : .black)
                }
            } else {
                ZStack {
                    Color.clear
                    ProgressView()
                        .controlSize(.large)
                        .tint(model.backgroundDark ? .white : .black)
                }
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipped()
        // Re-decode when the page changes OR when spread mode / reading
        // direction changes — both alter what the composed image is.
        .task(id: PageRenderKey(page: pageIndex,
                                 spread: model.twoPageSpread,
                                 direction: model.direction)) {
            await loadCurrent()
        }
    }

    /// Identity for `.task(id:)` so the decode re-runs on the inputs
    /// that change the displayed image.
    private struct PageRenderKey: Equatable {
        let page: Int
        let spread: Bool
        let direction: ReadingDirection
    }

    @MainActor
    private func loadCurrent() async {
        // Important: do NOT clear `image` before the new one is ready. Holding
        // the previous page visible until the next decode completes means
        // SwiftUI never has to fall back to the placeholder branch on a page
        // turn (which would cause a flash of the cover thumbnail in
        // windowed mode), and ZoomScrollView stays mounted the whole time so
        // updateNSView can swap the image in place.
        if image == nil {
            placeholder = (pageIndex == 0) ? model.coverThumbnail() : nil
        }
        guard pageIndex >= 0, pageIndex < model.pageCount else { return }
        let img = await model.displayImage(at: pageIndex)
        if !Task.isCancelled, let img {
            image = img
            placeholder = nil
        }
    }
}

struct ZoomScrollView: NSViewRepresentable {
    let image: NSImage
    let zoomMode: ZoomMode
    let onUserMagnify: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onUserMagnify: onUserMagnify) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8.0
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = .clear
        scroll.drawsBackground = false
        // Required for frameDidChangeNotification to fire when the scroll
        // view's own frame changes (e.g. window resize).
        scroll.postsFrameChangedNotifications = true

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        imageView.wantsLayer = true

        let clipped = FlippedClipContainer()
        clipped.frame = imageView.frame
        clipped.addSubview(imageView)
        clipped.imageView = imageView

        scroll.documentView = clipped
        context.coordinator.scrollView = scroll
        context.coordinator.container = clipped
        context.coordinator.currentImage = image
        context.coordinator.currentZoomMode = zoomMode
        context.coordinator.lastImage = image
        context.coordinator.lastZoomMode = zoomMode

        // Pinch-zoom capture — push the user's final magnification back to
        // the model so it persists into the next page and the toolbar
        // reflects reality.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.didEndLiveMagnify(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scroll
        )
        // Window-resize / layout: re-apply zoom on every frame change so the
        // image stays at e.g. .fitPage as the viewport grows or shrinks.
        // SwiftUI's updateNSView is NOT called for parent-geometry changes —
        // only when this NSViewRepresentable's own state changes — so we
        // need the AppKit-side notification.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.didChangeFrame(_:)),
            name: NSView.frameDidChangeNotification,
            object: scroll
        )

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let container = context.coordinator.container else { return }
        let coord = context.coordinator
        coord.onUserMagnify = onUserMagnify
        coord.currentImage = image
        coord.currentZoomMode = zoomMode

        let imageChanged = coord.lastImage !== image
        let zoomModeChanged = coord.lastZoomMode != zoomMode

        if imageChanged {
            coord.lastImage = image
            container.imageView?.image = image
            container.frame = NSRect(origin: .zero, size: image.size)
            container.imageView?.frame = container.bounds
            // New page: snap to fit-page and scroll to top synchronously
            // so we never paint at the previous page's scroll position,
            // then refine async once the clip view has been tiled.
            coord.applyZoom(resetScroll: true)
            DispatchQueue.main.async { coord.applyZoom(resetScroll: true) }
        }

        if zoomModeChanged {
            coord.lastZoomMode = zoomMode
            if coord.suppressNextZoomApply {
                // The user just finished pinching — we already wrote the
                // chosen magnification back to the model and don't want
                // the resulting re-render to clobber the scroll position.
                coord.suppressNextZoomApply = false
            } else if !imageChanged {
                DispatchQueue.main.async { coord.applyZoom(resetScroll: false) }
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator,
                                                   name: NSScrollView.didEndLiveMagnifyNotification,
                                                   object: scroll)
        NotificationCenter.default.removeObserver(coordinator,
                                                   name: NSView.frameDidChangeNotification,
                                                   object: scroll)
    }

    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var container: FlippedClipContainer?
        // What SwiftUI last told us to render; the frame-change notification
        // reads these to know what zoom + image to apply.
        var currentImage: NSImage?
        var currentZoomMode: ZoomMode = .fitPage
        // What we last *did* render; lets updateNSView dedupe applies.
        var lastImage: NSImage?
        var lastZoomMode: ZoomMode = .fitPage
        var lastViewportSize: CGSize?
        var onUserMagnify: (CGFloat) -> Void
        var suppressNextZoomApply: Bool = false

        init(onUserMagnify: @escaping (CGFloat) -> Void) {
            self.onUserMagnify = onUserMagnify
        }

        @objc func didEndLiveMagnify(_ notification: Notification) {
            guard let scroll = notification.object as? NSScrollView else { return }
            let mag = scroll.magnification
            // We're about to push this magnification onto the model, which
            // will come back through updateNSView as a zoomMode change.
            // Suppress that re-apply so the scroll position the user just
            // pinched into isn't reset under them.
            suppressNextZoomApply = true
            let callback = onUserMagnify
            DispatchQueue.main.async {
                callback(mag)
            }
        }

        @objc func didChangeFrame(_ notification: Notification) {
            // Live-resize: NSScrollView's frame just changed. Re-apply the
            // current zoom mode so the image keeps matching the new
            // viewport.
            guard let scroll = scrollView else { return }
            let viewport = scroll.contentView.frame.size
            // Dedupe — don't fire applyZoom on every spurious frame event
            // (e.g. the initial layout that just hands us a non-zero size).
            if let last = lastViewportSize,
               abs(last.width - viewport.width) < 0.5,
               abs(last.height - viewport.height) < 0.5 {
                return
            }
            if viewport.width > 0, viewport.height > 0 {
                lastViewportSize = viewport
            }
            // Preserve scroll spot through the resize.
            applyZoom(resetScroll: false)
        }

        /// Apply the current zoom mode to the underlying NSScrollView.
        /// Lives on the coordinator (not the struct) so the frame-change
        /// observer can call it without needing access to SwiftUI state.
        func applyZoom(resetScroll: Bool) {
            guard let scroll = scrollView,
                  let container = container,
                  let image = currentImage else { return }
            let imgSize = image.size
            guard imgSize.width > 0, imgSize.height > 0 else { return }

            // Clip view's *frame* (screen pixels) — bounds is doc coords
            // and would scale-feedback against the magnification.
            var viewport = scroll.contentView.frame.size
            if viewport.width <= 0 || viewport.height <= 0 {
                viewport = scroll.bounds.size
            }
            guard viewport.width > 0, viewport.height > 0 else { return }

            switch currentZoomMode {
            case .fitPage:
                let scale = min(viewport.width / imgSize.width,
                                viewport.height / imgSize.height)
                setContent(scroll: scroll, container: container,
                           size: imgSize, magnification: scale)
                if resetScroll { scrollToTopLeft(scroll: scroll) }
            case .fitWidth:
                let scale = viewport.width / imgSize.width
                setContent(scroll: scroll, container: container,
                           size: imgSize, magnification: scale)
                if resetScroll { scrollToTopLeft(scroll: scroll) }
            case .fitHeight:
                let scale = viewport.height / imgSize.height
                setContent(scroll: scroll, container: container,
                           size: imgSize, magnification: scale)
                if resetScroll { scrollToTopCenterX(scroll: scroll) }
            case .actual:
                setContent(scroll: scroll, container: container,
                           size: imgSize, magnification: 1.0)
                if resetScroll { scrollToTopLeft(scroll: scroll) }
            case .custom(let m):
                setContent(scroll: scroll, container: container,
                           size: imgSize, magnification: m)
                if resetScroll { scrollToTopLeft(scroll: scroll) }
            }
        }

        private func setContent(scroll: NSScrollView,
                                 container: FlippedClipContainer,
                                 size: CGSize,
                                 magnification: CGFloat) {
            container.frame = NSRect(origin: .zero, size: size)
            container.imageView?.frame = container.bounds
            scroll.magnification = magnification
        }

        private func scrollToTopLeft(scroll: NSScrollView) {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        private func scrollToTopCenterX(scroll: NSScrollView) {
            guard let doc = scroll.documentView else { return }
            let mag = scroll.magnification
            let viewportWidthScreen = scroll.contentView.frame.width
            let viewportWidthDoc = mag > 0 ? viewportWidthScreen / mag : viewportWidthScreen
            let excessDoc = max(0, doc.frame.width - viewportWidthDoc) / 2
            scroll.contentView.scroll(to: NSPoint(x: excessDoc, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

final class FlippedClipContainer: NSView {
    weak var imageView: NSImageView?
    override var isFlipped: Bool { true }
}
