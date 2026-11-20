import AppKit
import YabCoreClient

/// A finger on a touch display: a Mac with one, or an iPad by Sidecar.
///
/// AppKit hands a view without a gesture recognizer of its own a one-finger
/// drag as a left mouse drag ("Adopting gesture recognizers in your app"),
/// and a page reads a mouse drag as selecting text: a swipe up a paragraph
/// painted a selection instead of moving the page (#711). This pan is the
/// Chromium page's only; WebKit tabs are left as they were. It takes direct
/// touches and sends the finger on as touches, so Chromium's own gesture
/// detector scrolls the page and flings it as on a touch screen, and the
/// page's touch handlers and `touch-action` have their say.
enum ChromiumTouchInput {
    static let kinds: Set<String> = ["touchStart", "touchMove", "touchEnd", "touchCancel"]

    /// Direct touches only, and no mouse button, so the pan never claims a
    /// mouse or trackpad stream (the page's delegate also opts those out),
    /// and a click-drag reaches the page without waiting for it.
    /// `delaysPrimaryMouseButtonEvents` relies on NSGestureRecognizer.h: the
    /// view gets primary button events only once the gesture fails, and none
    /// of a recognized gesture. If that holds for the mouse events AppKit
    /// makes from a finger, a tap, which never pans, reaches the page as a
    /// click, and a pan never reaches it as a drag. Not observed on touch
    /// hardware.
    static func configure(_ pan: NSPanGestureRecognizer) {
        pan.allowedTouchTypes = .direct
        pan.buttonMask = 0
        pan.delaysPrimaryMouseButtonEvents = true
    }
}

/// One finger's touch on the page, from its pan's steps. The finger belongs
/// to the document it went down on, and it is one finger: a second one
/// cancels it, as does the page losing sight of it, and the rest of that pan
/// is ignored. Each pan is a gesture of its own number, which every one of
/// its events carries, so the helper never applies one to another gesture.
struct ChromiumTouchSequence {
    typealias Event = (kind: String, fields: [String: JSONValue])
    enum Held: Equatable { case up, down(turn: Int), dropped }
    private(set) var held = Held.up
    private(set) var gesture = 0

    /// The page's touch events for one step of the pan, in page points from
    /// the top left, and whether the pan should let go of the fingers. The
    /// pan begins only once the finger has moved, so its first step also
    /// puts the finger down where it landed: `point` less `moved`, the pan's
    /// translation. `fingers` is the most the pan saw down at once; 0 when
    /// it was told of no touch, which counts as one finger, so a swipe still
    /// scrolls if AppKit does not report its touches to the pan.
    mutating func step(_ state: NSGestureRecognizer.State, fingers: Int, turn: Int,
                       at point: CGPoint, moved: CGPoint) -> (events: [Event], letGo: Bool) {
        switch state {
        case .began:
            let left: [Event] = if case .down = held { [event("touchCancel")] } else { [] }
            gesture &+= 1
            guard fingers <= 1 else { held = .dropped; return (left, true) }
            held = .down(turn: turn)
            let start = CGPoint(x: point.x - moved.x, y: point.y - moved.y)
            return (left + [event("touchStart", start), event("touchMove", point)], false)
        case .changed:
            guard case .down(let first) = held else { return ([], false) }
            if fingers > 1 { held = .dropped; return ([event("touchCancel")], true) }
            if first != turn { held = .dropped; return ([event("touchCancel")], false) }
            return ([event("touchMove", point)], false)
        case .ended, .cancelled, .failed:
            defer { held = .up }
            guard case .down(let first) = held else { return ([], false) }
            // An end only for one finger on its own document: a lift that
            // follows a second finger, as any other, is a cancel, never a tap.
            let end = state == .ended && first == turn && fingers <= 1
            return ([event(end ? "touchEnd" : "touchCancel")], false)
        default: return ([], false)
        }
    }

    /// The page stops hearing the finger (hidden, or out of its window): the
    /// touch is cancelled, once, and the rest of its pan is ignored.
    mutating func interrupt() -> [Event] {
        guard case .down = held else { return [] }
        held = .dropped
        return [event("touchCancel")]
    }

    private func event(_ kind: String, _ point: CGPoint? = nil) -> Event {
        var fields: [String: JSONValue] = ["gesture": .number(Double(gesture))]
        if let point { fields["x"] = .number(point.x); fields["y"] = .number(point.y) }
        return (kind, fields)
    }
}

/// The page's pan. It also counts the fingers down during a pan, so the page
/// takes one finger only: with NSPanGestureRecognizer's own touch counts
/// (`maximumNumberOfTouches`, NSIntegerMax by default) only in the macOS 27
/// SDK, a second finger would otherwise move the page's one touch. The count
/// relies on AppKit calling `touchesBegan(with:)` on the pan with the touches
/// down; if it never does, the count stays 0 and the pan takes the finger.
final class ChromiumTouchPan: NSPanGestureRecognizer {
    private let down = NSMutableSet()
    /// The most fingers down at once since the pan last reset.
    private(set) var fingers = 0

    override func touchesBegan(with event: NSEvent) {
        for touch in event.touches(matching: .touching, in: view) { down.add(touch.identity) }
        fingers = max(fingers, down.count)
        super.touchesBegan(with: event)
    }
    override func touchesEnded(with event: NSEvent) { lift(event); super.touchesEnded(with: event) }
    override func touchesCancelled(with event: NSEvent) { lift(event); super.touchesCancelled(with: event) }
    override func reset() { down.removeAllObjects(); fingers = 0; super.reset() }
    private func lift(_ event: NSEvent) {
        for touch in event.touches(matching: [.ended, .cancelled], in: view) { down.remove(touch.identity) }
    }

    /// Disabling a recognizer cancels the gesture it is recognizing
    /// (NSGestureRecognizer.h, `enabled`): the fingers are no longer the pan's.
    func letGo() { isEnabled = false; isEnabled = true }
}

extension ChromiumPage: NSGestureRecognizerDelegate {
    func addTouchPan() {
        let pan = ChromiumTouchPan(target: self, action: #selector(touchPanned(_:)))
        ChromiumTouchInput.configure(pan)
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    @objc func touchPanned(_ pan: ChromiumTouchPan) {
        let point = pan.location(in: self), moved = pan.translation(in: self)
        // Page points from the top left; the view's y runs up.
        let step = touch.step(pan.state, fingers: pan.fingers, turn: documentTurn,
                              at: CGPoint(x: point.x, y: bounds.height - point.y), moved: CGPoint(x: moved.x, y: -moved.y))
        if case .down = touch.held, pan.state == .began || pan.state == .changed {
            // The page moves under the finger, as under a trackpad (pageGesture).
            hoverScrolled()
            navigationTab?.uncover()
            if let tab = navigationTab { tab.onSelectionTouch?(tab) }
        }
        for event in step.events { input(event.kind, event.fields) }
        if step.letGo { pan.letGo() }
    }

    /// The page is hidden or leaves its window with a finger down. A page
    /// that is torn down closes its browser, and the finger goes with it.
    func touchInterrupted() {
        for event in touch.interrupt() { input(event.kind, event.fields) }
    }

    /// The pan takes no event stream offered here. Per TN3212, AppKit asks
    /// this only for a mouse's or a trackpad's stream, never a touch's; the
    /// pan relies on that to keep taking fingers.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        false
    }
}
