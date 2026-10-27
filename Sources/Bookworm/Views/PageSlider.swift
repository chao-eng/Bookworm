import SwiftUI
import AppKit

struct PageSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let reversed: Bool

    var body: some View {
        // Flipping the binding alone only mirrored the thumb's position — the
        // fill direction (and which way you had to drag) stayed left-to-right.
        // Forcing layoutDirection on the Slider's environment flips the whole
        // control: thumb starts on the right at page 0, the fill grows from
        // the right toward the thumb, and dragging left advances pages,
        // which matches the right-to-left reading flow.
        Slider(value: $value, in: range, step: 1)
            .controlSize(.regular)
            .tint(.white)
            .environment(\.layoutDirection, reversed ? .rightToLeft : .leftToRight)
    }
}

struct KeyEventHandlingView: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool
    /// Trackpad swipe-between-pages gesture. Receives the event's
    /// `deltaX` (positive = swipe toward the left). Optional so existing
    /// callers that only want key handling don't have to supply it.
    var onSwipe: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> KeyCatcherView {
        let v = KeyCatcherView()
        v.onKeyDown = onKeyDown
        v.onSwipe = onSwipe
        return v
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onKeyDown = onKeyDown
        nsView.onSwipe = onSwipe
    }
}

final class KeyCatcherView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onSwipe: ((CGFloat) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }
    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
    /// Two/three-finger trackpad swipe (the system "swipe between pages"
    /// gesture). Distinct from scrollWheel, so it doesn't fight the
    /// reader's NSScrollView panning when the page is zoomed in.
    override func swipe(with event: NSEvent) {
        if event.deltaX != 0 {
            onSwipe?(event.deltaX)
        } else {
            super.swipe(with: event)
        }
    }
}
