import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Single-touch gesture that begins on touch-down (no movement threshold), so strokes
/// start exactly where the finger or pencil lands. A second finger cancels it, letting
/// the PDF view scroll and zoom.
final class DrawingGestureRecognizer: UIGestureRecognizer {
    /// Return false to fail immediately (e.g. the select tool touched empty space).
    var shouldBeginAt: ((CGPoint) -> Bool)?
    private(set) var lastTouchType: UITouch.TouchType = .direct
    private var tracked: UITouch?
    private var pending = [CGPoint]()

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if tracked != nil || touches.count > 1 {
            // second finger: hand over to scrolling / pinch
            if state == .began || state == .changed { state = .cancelled } else { state = .failed }
            return
        }
        guard let t = touches.first else { return }
        let p = t.location(in: view)
        if let check = shouldBeginAt, !check(p) {
            state = .failed
            return
        }
        tracked = t
        lastTouchType = t.type
        pending = [p]
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        // coalesced touches: Apple Pencil reports up to 240 Hz
        let samples = event.coalescedTouches(for: t) ?? [t]
        pending.append(contentsOf: samples.map { $0.location(in: view) })
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        pending.append(t.location(in: view))
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    override func reset() {
        super.reset()
        tracked = nil
    }

    /// Points (in the recognizer's view) received since the last call.
    func takeSamples() -> [CGPoint] {
        let s = pending
        pending.removeAll()
        return s
    }
}
