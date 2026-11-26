import AppKit
import SwiftUI
import QuartzCore

/// Only a deliberate horizontal trackpad gesture dismisses the corner.
/// Lock its axis once, so a vertical scroll cannot turn into a dismissal.
struct CaptureSwipe {
    enum Axis { case waiting, horizontal, vertical }
    private(set) var active = false
    private(set) var axis = Axis.waiting
    private(set) var travel = CGPoint.zero

    mutating func begin() { active = true; axis = .waiting; travel = .zero }
    mutating func move(x: CGFloat, y: CGFloat) {
        guard active else { return }
        travel.x += x
        travel.y += y
        if axis == .waiting, max(abs(travel.x), abs(travel.y)) >= 6 {
            axis = abs(travel.x) > abs(travel.y) * 1.2 ? .horizontal : .vertical
        }
    }
    func dismisses(width: CGFloat) -> Bool {
        active && axis == .horizontal && abs(travel.x) >= min(80, max(48, width * 0.25))
    }
}

/// The capture over the window: the outline while picking, then the picture
/// and the card around it (Capture.swift). Its own view over everything, as
/// LinkPeek's flight is, so the window's SwiftUI never lays out for it.
///
/// Every layer hangs in `stage`, which is the page's rect and clips to it:
/// the picture lifts off inside the page and never crosses the column.
/// Geometry is AppKit's, from the bottom left.
@MainActor
final class CaptureView: NSView, NSDraggingSource {
    private unowned let capture: Capture
    private var page = CGRect.zero
    /// Nothing was dimmed for this capture (`pick`).
    private var quiet = false
    private var model: CaptureModel?

    /// Where `stage` hangs: a view of its own, first among the subviews,
    /// so the card is always under the words and buttons hosted over it.
    /// Hung in the view's own layer, it went on top of them once it was
    /// put back for a second capture, and the row under the picture, the
    /// pill and the editor's controls were drawn under the card.
    private let floor = CaptureFloor()
    private let stage = CALayer()
    private let veil = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let badge = CALayer()
    private let badgeText = CATextLayer()
    private let cover = CALayer()
    private let surface = CALayer()
    /// The canvas, at the picture's points, scaled as one: the file in small.
    private let canvas = CALayer()
    private let bg = CAGradientLayer()
    private let lift = CALayer()
    private let picture = CALayer()
    private var blocks: [CALayer] = []

    private var foot: NSHostingView<CaptureFoot>?
    private var bar: NSHostingView<CapturePlateBar>?
    private var top: NSHostingView<CaptureEditorTop>?
    private var tools: NSHostingView<CaptureEditorBar>?
    /// Save, one button in the corner and in the editor alike: it rides
    /// with the card's corner from one place to the other.
    private var saver: NSHostingView<CaptureSaveButton>?
    /// Done, the editor's, beside Save.
    private var done: NSHostingView<CaptureDoneButton>?

    private var layout: CaptureLayout?
    /// Where the canvas is and how big, whichever card it is in.
    private var slot = CGRect.zero
    private var card = CGRect.zero
    private var editing = false
    private var down: CGPoint?
    private var area: CGRect?
    private var lastPoint: CGPoint?
    private(set) var hovering = false
    private var tracking: NSTrackingArea?
    private var cardTracking: NSTrackingArea?
    private var swipe = CaptureSwipe()
    private var swipeOffset: CGFloat = 0
    private var momentumMonitor: Any?

    init(capture: Capture, frame: CGRect) {
        self.capture = capture
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        floor.frame = bounds
        floor.autoresizingMask = [.width, .height]
        addSubview(floor)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: motion

    /// The capture's curve, Motion's: (.2, .8, .2, 1), no give.
    static let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    static let out = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.4)
    /// The measured beats (docs/capture.md): into the corner, into the
    /// editor and back, a new shape, into Downloads, away.
    static let landing: CFTimeInterval = 0.36
    static let opening: CFTimeInterval = 0.34
    static let closing: CFTimeInterval = 0.26
    static let reshaping: CFTimeInterval = 0.22
    static let saving: CFTimeInterval = 0.34
    static let leaving: CFTimeInterval = 0.15

    private var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func run(_ layer: CALayer, _ key: String, _ from: Any?, _ to: Any?, _ duration: CFTimeInterval,
                     after: CFTimeInterval = 0, curve: CAMediaTimingFunction = CaptureView.curve) {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = curve
        if after > 0 {
            a.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + after
            a.fillMode = .backwards
        }
        layer.add(a, forKey: "capture." + key)
    }

    private func fade(_ view: NSView?, to: CGFloat, _ duration: CFTimeInterval, after: CFTimeInterval = 0) {
        guard let view, let layer = view.layer else { return }
        let from = view.alphaValue
        view.alphaValue = to
        run(layer, "opacity", from, to, duration, after: after)
    }

    /// A hosted view kept on the card's edge while the card moves: laid
    /// out where it ends, drawn from where the same edge was, on the
    /// card's clock. `lift` starts it that much lower, to rise as it comes.
    private func ride(_ view: NSView?, by delta: CGPoint, lift: CGFloat = 0, _ duration: CFTimeInterval) {
        guard let layer = view?.layer, !still else { return }
        if delta.x != 0 { run(layer, "transform.translation.x", delta.x, 0, duration) }
        if delta.y - lift != 0 { run(layer, "transform.translation.y", delta.y - lift, 0, duration) }
    }

    private func hosted<V: View>(_ view: inout NSHostingView<V>?, _ root: () -> V) -> NSHostingView<V> {
        if let view { return view }
        let made = NSHostingView(rootView: root())
        made.sizingOptions = []
        made.wantsLayer = true
        addSubview(made)
        view = made
        return made
    }

    /// Where the row under the picture and Save stand in the corner's card,
    /// in window points.
    private func plateRow(_ card: CGRect, save: CGSize) -> (row: CGRect, save: CGRect) {
        let inset = CardFrame.inset
        let y = page.minY + card.minY + inset
        let saveRect = CGRect(x: page.minX + card.maxX - inset - save.width, y: y, width: save.width, height: CaptureView.rowHeight)
        let row = CGRect(x: page.minX + card.minX + inset, y: y, width: saveRect.minX - 6 - (page.minX + card.minX + inset), height: CaptureView.rowHeight)
        return (row, saveRect)
    }

    /// Where Save and Done stand in the editor, at its foot's right.
    private func editorKeys(_ card: CGRect, save: CGSize, done: CGSize) -> (save: CGRect, done: CGRect) {
        let y = page.minY + card.minY + 16
        let doneRect = CGRect(x: page.minX + card.maxX - 16 - done.width, y: y, width: done.width, height: ButtonSize.regular.height)
        let saveRect = CGRect(x: doneRect.minX - 8 - save.width, y: y, width: save.width, height: ButtonSize.regular.height)
        return (saveRect, doneRect)
    }

    /// A hosted button's own size, asked once: with `sizingOptions` empty,
    /// as every hosted view here has it, `fittingSize` says nothing.
    private var sizes: [ObjectIdentifier: CGSize] = [:]
    private func size<V: View>(of view: NSHostingView<V>) -> CGSize {
        let id = ObjectIdentifier(view)
        if let known = sizes[id] { return known }
        let measured = NSHostingController(rootView: view.rootView).sizeThatFits(in: CGSize(width: 400, height: 100))
        let size = CGSize(width: ceil(measured.width), height: ButtonSize.regular.height)
        sizes[id] = size
        return size
    }

    private func delta(_ from: CGPoint, _ to: CGPoint) -> CGPoint { CGPoint(x: from.x - to.x, y: from.y - to.y) }

    // MARK: picking

    /// Made once and kept, hidden, for the next capture: building the
    /// hosting views each time cost the start some 80 ms of the main thread.
    /// `quiet`: Capture Image, which has nothing to pick: no dim and no bar,
    /// only the stage for the picture to land on.
    func pick(page: CGRect, model: CaptureModel, quiet: Bool = false) {
        self.page = page
        self.model = model
        self.quiet = quiet
        guard let root = floor.layer else { return }
        isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reset()
        stage.frame = page
        stage.masksToBounds = true
        stage.cornerRadius = Radius.surface
        stage.cornerCurve = .continuous
        stage.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        root.addSublayer(stage)

        veil.fillRule = .evenOdd
        veil.fillColor = NSColor(white: 0, alpha: 0.16).cgColor
        veil.path = CGPath(rect: stage.bounds, transform: nil)
        stage.addSublayer(veil)

        ring.fillColor = nil
        ring.lineWidth = 2
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.opacity = 0
        stage.addSublayer(ring)

        badge.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.cornerRadius = Radius.small
        badge.opacity = 0
        badgeText.contentsScale = window?.backingScaleFactor ?? 2
        badgeText.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        badgeText.fontSize = 11
        badgeText.foregroundColor = NSColor.white.cgColor
        badgeText.alignmentMode = .center
        badge.addSublayer(badgeText)
        stage.addSublayer(badge)
        CATransaction.commit()
        if quiet {
            foot?.isHidden = true
            track()
            return
        }
        if !still { run(veil, "opacity", 0, 1, 0.12, curve: CAMediaTimingFunction(name: .linear)) }

        let foot = self.foot ?? {
            let made = NSHostingView(rootView: CaptureFoot(model: model))
            made.wantsLayer = true
            addSubview(made)
            self.foot = made
            return made
        }()
        let size = foot.fittingSize
        foot.sizingOptions = []
        foot.frame = CGRect(x: (page.midX - size.width / 2).rounded(), y: page.minY + 16, width: size.width, height: size.height)
        foot.isHidden = false
        foot.alphaValue = 1
        if !still, let layer = foot.layer {
            run(layer, "opacity", 0, 1, 0.15)
            run(layer, "transform.translation.y", -12, 0, 0.22)
        }
        track()
        window?.invalidateCursorRects(for: self)
    }

    /// Back to nothing on screen, for the next capture.
    private func reset() {
        for layer in [stage, veil, ring, badge, cover, surface, canvas, bg, lift, picture] as [CALayer] { layer.removeAllAnimations() }
        stage.sublayers = nil
        stage.opacity = 1
        stage.transform = CATransform3DIdentity
        stage.masksToBounds = true
        veil.opacity = 1
        cover.opacity = 0
        cover.contents = nil
        surface.opacity = 1
        surface.transform = CATransform3DIdentity
        canvas.opacity = 1
        canvas.transform = CATransform3DIdentity
        picture.contents = nil
        blocks.forEach { $0.removeFromSuperlayer() }
        blocks = []
        layout = nil
        card = .zero
        slot = .zero
        editing = false
        down = nil
        area = nil
        hovering = false
        swipe = CaptureSwipe()
        swipeOffset = 0
        for view in [foot, bar, top, tools, saver, done] as [NSView?] {
            view?.isHidden = true
            view?.layer?.removeAllAnimations()
            view?.layer?.transform = CATransform3DIdentity
        }
    }

    /// Done with: nothing shown, nothing hit, kept for the next.
    func rest() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reset()
        CATransaction.commit()
        isHidden = true
        if let cardTracking { removeTrackingArea(cardTracking) }
        cardTracking = nil
        window?.invalidateCursorRects(for: self)
    }

    private func track() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        if capture.stage == .picking { addCursorRect(page, cursor: .crosshair) }
    }

    override func cursorUpdate(with event: NSEvent) {
        CursorUpdateGuard.run(self) {
            if capture.stage == .picking, page.contains(convert(event.locationInWindow, from: nil)) { NSCursor.crosshair.set() } else { super.cursorUpdate(with: event) }
        }
    }

    /// Where the page is, from the stage's corner.
    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -page.minX, dy: -page.minY) }

    func outline(_ rect: CGRect?, name: String, size: CGSize) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(still ? 0 : 0.08)
        CATransaction.setAnimationTimingFunction(CaptureView.curve)
        guard let rect else {
            ring.opacity = 0
            badge.opacity = 0
            veil.path = CGPath(rect: stage.bounds, transform: nil)
            CATransaction.commit()
            return
        }
        let r = local(rect).intersection(stage.bounds.insetBy(dx: 1, dy: 1))
        let hole = CGMutablePath()
        hole.addRect(stage.bounds)
        hole.addRounded(r, corner: 4)
        veil.path = hole
        ring.path = CGPath.rounded(r, corner: 4)
        ring.lineDashPattern = nil
        ring.opacity = 1
        label("\(name)  \(Int(size.width.rounded())) × \(Int(size.height.rounded()))", over: r)
        CATransaction.commit()
    }

    private func label(_ text: String, over r: CGRect) {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let width = ((text as NSString).size(withAttributes: [.font: font]).width + 14).rounded(.up)
        let height: CGFloat = 20
        // Above the box, or inside its top when there is no room above.
        var y = r.maxY + 4
        if y + height > stage.bounds.maxY - 4 { y = r.maxY - height - 4 }
        let x = min(max(r.minX, 4), stage.bounds.maxX - width - 4)
        badge.frame = CGRect(x: x, y: y, width: width, height: height)
        badgeText.string = text
        badgeText.frame = CGRect(x: 0, y: 3, width: width, height: 14)
        badge.opacity = 1
    }

    func busy(_ words: String) {
        model?.busy = words
    }

    // MARK: pointer

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        switch capture.stage {
        case .picking: return super.hitTest(point) ?? self
        case .plate: return card.offsetBy(dx: page.minX, dy: page.minY).contains(p) ? (super.hitTest(point) ?? self) : nil
        case .editing: return page.contains(p) ? (super.hitTest(point) ?? self) : nil
        case .idle: return nil
        }
    }

    /// Whether a point is on the capture's card.
    func holds(_ p: CGPoint) -> Bool {
        card.offsetBy(dx: page.minX, dy: page.minY).contains(p)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard capture.stage == .picking, page.contains(p), down == nil else { return }
        lastPoint = p
        capture.hover(p)
    }

    override func scrollWheel(with event: NSEvent) {
        guard capture.stage == .picking else { return super.scrollWheel(with: event) }
        capture.scroll(event)
        if let lastPoint {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.capture.hover(lastPoint) }
        }
    }

    /// Called by the local monitor, including over the hosted buttons and
    /// after the pointer has left the card. Mouse wheels have no phases.
    func swipeToClose(_ event: NSEvent) -> Bool {
        guard capture.stage == .plate, event.hasPreciseScrollingDeltas else { return false }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            guard event.window === window, holds(convert(event.locationInWindow, from: nil)) else {
                if swipe.active {
                    swipe = CaptureSwipe()
                    moveCard(to: 0, animated: true)
                    capture.pointer(on: hovering)
                }
                return false
            }
            swipe.begin()
            capture.hold()
        }
        guard swipe.active else { return false }
        guard event.momentumPhase.isEmpty else { return true }
        swipe.move(x: event.scrollingDeltaX, y: event.scrollingDeltaY)
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let dismiss = !event.phase.contains(.cancelled) && swipe.dismisses(width: card.width)
            swipe = CaptureSwipe()
            if dismiss {
                drainMomentum()
                capture.close()
            } else {
                moveCard(to: 0, animated: true)
                capture.pointer(on: hovering)
            }
        } else if swipe.axis == .horizontal {
            moveCard(to: still ? 0 : swipe.travel.x)
        }
        return true
    }

    private func moveCard(to x: CGFloat, animated: Bool = false) {
        let from = swipeOffset
        swipeOffset = x
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [surface, canvas, bar?.layer, saver?.layer].compactMap({ $0 }) {
            let shown = layer.presentation()?.value(forKeyPath: "transform.translation.x") ?? from
            layer.setValue(x, forKeyPath: "transform.translation.x")
            layer.removeAnimation(forKey: "capture.transform.translation.x")
            if animated && !still { run(layer, "transform.translation.x", shown, x, CaptureView.reshaping) }
        }
        CATransaction.commit()
    }

    private func cancelSwipe() {
        swipe = CaptureSwipe()
        moveCard(to: 0)
    }

    /// Inertia from the dismissed card must not navigate/scroll the page.
    /// Stop at the next fresh gesture, or when this momentum ends.
    private func drainMomentum() {
        if let momentumMonitor { NSEvent.removeMonitor(momentumMonitor) }
        let window = self.window
        let token = UUID()
        momentumToken = token
        momentumMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak window] event in
            guard let self, let window, event.window == nil || event.window === window else { return event }
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                self.stopMomentum(token)
                return event
            }
            if !event.phase.isEmpty { return nil }
            guard !event.momentumPhase.isEmpty else { return event }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { self.stopMomentum(token) }
            return nil
        }
        let monitor = momentumMonitor
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if let self { self.stopMomentum(token) }
            else if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    private var momentumToken: UUID?
    private func stopMomentum(_ token: UUID) {
        guard momentumToken == token else { return }
        if let momentumMonitor { NSEvent.removeMonitor(momentumMonitor) }
        momentumMonitor = nil
        momentumToken = nil
    }

    private var pictureOnScreen: CGRect {
        canvas.frame.offsetBy(dx: page.minX, dy: page.minY)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch capture.stage {
        case .picking:
            guard page.contains(p) else { capture.cancel(); return }
            down = p
            area = nil
        case .plate, .editing:
            if pictureOnScreen.contains(p) { down = p; return }
            if capture.stage == .editing, !card.offsetBy(dx: page.minX, dy: page.minY).contains(p) { capture.back() }
        case .idle: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - down.x, p.y - down.y) > 4 else { return }
        switch capture.stage {
        case .picking:
            let r = CGRect(x: min(p.x, down.x), y: min(p.y, down.y), width: abs(p.x - down.x), height: abs(p.y - down.y)).intersection(page)
            area = r
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let l = local(r)
            let hole = CGMutablePath()
            hole.addRect(stage.bounds)
            hole.addRect(l)
            veil.path = hole
            ring.path = CGPath(rect: l, transform: nil)
            ring.lineDashPattern = [5, 4]
            ring.opacity = 1
            label("\(Int(r.width)) × \(Int(r.height))", over: l)
            CATransaction.commit()
        case .plate, .editing:
            self.down = nil
            drag(event)
        case .idle: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { down = nil; area = nil }
        guard down != nil else { return }
        switch capture.stage {
        case .picking:
            if let area, area.width >= 4, area.height >= 4 { capture.take(.area(area)) } else { capture.take(.box) }
        case .plate: capture.edit()
        default: break
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        capture.pointer(on: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !swipe.active { capture.pointer(on: false) }
    }

    private func trackCard() {
        if let cardTracking { removeTrackingArea(cardTracking) }
        let area = NSTrackingArea(rect: card.offsetBy(dx: page.minX, dy: page.minY), options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        cardTracking = area
    }

    // MARK: drag out

    private func drag(_ event: NSEvent) {
        guard let provider = capture.promise() else { return }
        let item = NSDraggingItem(pasteboardWriter: provider)
        let frame = pictureOnScreen
        let image = NSImage(size: frame.size)
        if let contents = picture.contents {
            image.addRepresentation(NSBitmapImageRep(cgImage: contents as! CGImage))
        }
        item.setDraggingFrame(frame, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    // MARK: the card

    /// The card in the corner: its width, the room the picture has in it,
    /// the row under it.
    static let plateWidth: CGFloat = 360
    static let plateRoom = CGSize(width: plateWidth - CardFrame.inset * 2, height: 200)
    static let rowHeight = ButtonSize.regular.height

    private func plate(for layout: CaptureLayout) -> (card: CGRect, slot: CGRect) {
        let room = CaptureView.plateRoom
        let s = min(room.width / layout.canvas.width, room.height / layout.canvas.height)
        let h = (layout.canvas.height * s).rounded()
        let inset = CardFrame.inset
        let height = inset + h + inset + CaptureView.rowHeight + inset
        let card = CGRect(x: stage.bounds.maxX - inset - CaptureView.plateWidth, y: stage.bounds.maxY - inset - height,
                          width: CaptureView.plateWidth, height: height)
        let slot = CGRect(x: card.minX + inset, y: card.maxY - inset - h, width: room.width, height: h)
        return (card, slot)
    }

    /// The editor: most of the page, the picture as large as it goes.
    static let editorTop: CGFloat = 44
    static let editorFoot: CGFloat = 96

    private func editor() -> (card: CGRect, slot: CGRect) {
        let w = min(stage.bounds.width - 48, 920), h = min(stage.bounds.height - 48, 680)
        let card = CGRect(x: ((stage.bounds.width - w) / 2).rounded(), y: ((stage.bounds.height - h) / 2).rounded(), width: w, height: h)
        let slot = CGRect(x: card.minX + 16, y: card.minY + CaptureView.editorFoot, width: w - 32,
                          height: h - CaptureView.editorTop - CaptureView.editorFoot)
        return (card, slot)
    }

    /// The canvas's scale and middle to sit in a slot.
    private func placed(_ layout: CaptureLayout, in slot: CGRect) -> (scale: CGFloat, position: CGPoint) {
        let s = min(slot.width / layout.canvas.width, slot.height / layout.canvas.height)
        // The canvas hangs from the picture's middle (anchorPoint), so its
        // position is where the picture's middle goes.
        let canvasMid = CGPoint(x: slot.midX, y: slot.midY)
        let offset = CGPoint(x: (layout.picture.midX - layout.canvas.width / 2) * s, y: (layout.picture.midY - layout.canvas.height / 2) * s)
        return (s, CGPoint(x: canvasMid.x + offset.x, y: canvasMid.y + offset.y))
    }

    /// The preview's corner in the canvas' own units, so that on screen it
    /// is the card's corner less the inset (Radius.control), concentric
    /// with the card at any scale. Only the preview: the file keeps its own.
    private func corner(_ s: CGFloat) -> CGFloat { Radius.control / max(s, 0.001) }

    /// The preview's corners for a scale, and how they get there with it.
    private func round(_ s: CGFloat, from s0: CGFloat? = nil, _ t: CFTimeInterval = 0, after: CFTimeInterval = 0) {
        let bare = picture.frame.size == canvas.bounds.size
        let r = corner(s)
        bg.cornerRadius = r
        if bare { picture.cornerRadius = r }
        guard let s0, t > 0 else { return }
        run(bg, "cornerRadius", corner(s0), r, t, after: after)
        if bare { run(picture, "cornerRadius", corner(s0), r, t, after: after) }
    }

    private func dress(_ layout: CaptureLayout, style: CaptureStyle) {
        canvas.bounds = CGRect(origin: .zero, size: layout.canvas)
        canvas.anchorPoint = CGPoint(x: layout.picture.midX / layout.canvas.width, y: layout.picture.midY / layout.canvas.height)
        bg.frame = canvas.bounds
        let framed = style.backdrop != .none
        picture.frame = layout.picture
        picture.cornerRadius = framed ? CaptureLayout.corner : 0
        lift.frame = layout.picture
        lift.shadowPath = CGPath.rounded(lift.bounds, corner: CaptureLayout.corner)
        lift.shadowOpacity = framed ? Shadow.lift.opacity : 0
        for block in blocks { block.isHidden = !style.hidePrivate }
    }

    /// The backdrop's look: a state, changed at once (P6).
    func backdrop(_ style: CaptureStyle, tint: NSColor?, wallpaper: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch style.backdrop {
        case .page, .hue:
            bg.contents = nil
            bg.colors = CaptureArt.colors(style, tint: tint)
        case .wallpaper:
            bg.colors = nil
            bg.contents = wallpaper
            bg.backgroundColor = NSColor(white: 0.9, alpha: 1).cgColor
        case .none:
            bg.colors = nil
            bg.contents = nil
            bg.backgroundColor = nil
        }
        if style.backdrop != .wallpaper { bg.backgroundColor = nil }
        CATransaction.commit()
    }

    /// What is hidden, painted over the picture as the file will have it.
    func blocks(_ secrets: [CGRect], in size: CGSize, hidden: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blocks.forEach { $0.removeFromSuperlayer() }
        blocks = secrets.map { box in
            let block = CALayer()
            block.backgroundColor = CaptureArt.hush
            block.cornerRadius = 3
            block.frame = CGRect(x: box.minX, y: size.height - box.maxY, width: box.width, height: box.height).insetBy(dx: -1, dy: -1)
            block.isHidden = hidden
            picture.addSublayer(block)
            return block
        }
        CATransaction.commit()
    }

    func preview(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        CATransaction.commit()
    }

    private func dressSurface(_ rect: CGRect) {
        surface.frame = rect
        surface.shadowPath = CGPath.rounded(surface.bounds, corner: Radius.card)
    }

    /// The picture lifts off where it was and goes to the corner, and the
    /// card grows out of it (P3, P4): the backdrop out of the picture, the
    /// card out of the backdrop, the row last.
    func land(_ shot: Shot, preview: CGImage?, style: CaptureStyle) {
        let layout = CaptureLayout(shot.size, style)
        self.layout = layout
        let (card, slot) = plate(for: layout)
        self.card = card
        self.slot = slot
        guard let model else { return }
        let appearance = effectiveAppearance

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        appearance.performAsCurrentDrawingAppearance {
            surface.backgroundColor = Palette.NS.ground.cgColor
            surface.borderColor = Palette.NS.hairline.cgColor
        }
        surface.borderWidth = 1
        surface.cornerRadius = Radius.card
        surface.cornerCurve = .continuous
        surface.shadowColor = NSColor.black.cgColor
        surface.shadowOpacity = Shadow.card.opacity
        surface.shadowRadius = Shadow.card.radius
        surface.shadowOffset = CGSize(width: 0, height: -Shadow.card.y)
        dressSurface(card)
        stage.addSublayer(surface)

        canvas.masksToBounds = false
        bg.startPoint = CGPoint(x: 0, y: 1)
        bg.endPoint = CGPoint(x: 1, y: 0)
        bg.contentsGravity = .resizeAspectFill
        bg.masksToBounds = true
        lift.shadowColor = NSColor.black.cgColor
        lift.shadowRadius = Shadow.lift.radius
        lift.shadowOffset = CGSize(width: 0, height: -Shadow.lift.y)
        picture.masksToBounds = true
        picture.cornerCurve = .continuous
        picture.contents = preview
        picture.contentsGravity = .resize
        picture.backgroundColor = NSColor.white.cgColor
        canvas.addSublayer(bg)
        canvas.addSublayer(lift)
        canvas.addSublayer(picture)
        stage.addSublayer(canvas)
        dress(layout, style: style)
        backdrop(style, tint: shot.tint, wallpaper: nil)

        let (s, position) = placed(layout, in: slot)
        canvas.position = position
        canvas.transform = CATransform3DMakeScale(s, s, 1)
        round(s)
        ring.opacity = 0
        badge.opacity = 0
        veil.opacity = 0
        CATransaction.commit()

        let bar = hosted(&self.bar) { CapturePlateBar(model: model) }
        let saver = hosted(&self.saver) { CaptureSaveButton(model: model) }
        let row = plateRow(card, save: size(of: saver))
        bar.frame = row.row
        saver.frame = row.save
        bar.isHidden = false
        saver.isHidden = false
        done?.isHidden = true
        trackCard()
        window?.invalidateCursorRects(for: self)

        let source = local(shot.source)
        let s0 = shot.size.width > 0 ? source.width / shot.size.width : 1
        let from = CGPoint(x: source.midX, y: source.midY)
        let t = CaptureView.landing
        // Where the picture lifts off, as much of it as the page shows.
        let shown = source.intersection(stage.bounds)
        let start = shown.isNull ? card : shown

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let foot { fade(foot, to: 0, 0.12) }
        if !quiet { run(veil, "opacity", 1, 0, 0.18, curve: CAMediaTimingFunction(name: .linear)) }
        if still {
            run(stage, "opacity", 0, 1, 0.15)
        } else {
            run(canvas, "position", NSValue(point: from), NSValue(point: position), t)
            run(canvas, "transform.scale", s0, s, t)
            let pictureBounds = CGRect(origin: .zero, size: layout.picture.size)
            run(bg, "bounds", NSValue(rect: pictureBounds), NSValue(rect: canvas.bounds), t - 0.06, after: 0.06)
            run(bg, "position", NSValue(point: CGPoint(x: layout.picture.midX, y: layout.picture.midY)),
                NSValue(point: CGPoint(x: layout.canvas.width / 2, y: layout.canvas.height / 2)), t - 0.06, after: 0.06)
            run(bg, "opacity", 0, 1, 0.14, after: 0.06)
            run(bg, "cornerRadius", 0, bg.cornerRadius, t - 0.06, after: 0.06)
            if style.backdrop == .none { run(picture, "cornerRadius", 0, picture.cornerRadius, t) }
            if style.backdrop != .none {
                run(picture, "cornerRadius", 0, CaptureLayout.corner, t)
                run(lift, "shadowOpacity", 0, Shadow.lift.opacity, t)
            }
            // The card starts as the picture and grows round it on the
            // picture's own clock: started later, or from the page's whole
            // rect, it trailed the picture as a pale sheet the size of the
            // page, then shrank after it into the corner.
            run(surface, "bounds", NSValue(rect: CGRect(origin: .zero, size: start.size)), NSValue(rect: surface.bounds), t)
            run(surface, "position", NSValue(point: CGPoint(x: start.midX, y: start.midY)), NSValue(point: surface.position), t)
            run(surface, "cornerRadius", 0, Radius.card, t)
            run(surface, "shadowPath", CGPath(rect: CGRect(origin: .zero, size: start.size), transform: nil), surface.shadowPath, t)
            // The row last, rising on the card's foot as the card settles.
            bar.alphaValue = 0
            saver.alphaValue = 0
            fade(bar, to: 1, 0.13, after: t * 0.62)
            fade(saver, to: 1, 0.13, after: t * 0.62)
            if let layer = bar.layer { run(layer, "transform.translation.y", -6, 0, 0.2, after: t * 0.62) }
            if let layer = saver.layer { run(layer, "transform.translation.y", -6, 0, 0.2, after: t * 0.62) }
        }
        CATransaction.commit()
        CATransaction.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.capture.stage != .picking else { return }
            self.foot?.isHidden = true
        }
    }

    /// The card grows into the editor and the picture with it; the page
    /// goes under a blur, so what moves is plain (P1, P4).
    func edit(_ shot: Shot, style: CaptureStyle) {
        cancelSwipe()
        guard let layout, let model else { return }
        editing = true
        let (card, slot) = editor()
        let old = (card: self.card, slot: self.slot)
        self.card = card
        self.slot = slot
        let (s0, p0) = placed(layout, in: old.slot)
        let (s, p) = placed(layout, in: slot)

        let top = hosted(&self.top) { CaptureEditorTop(model: model) }
        let tools = hosted(&self.tools) { CaptureEditorBar(model: model) }
        let saver = hosted(&self.saver) { CaptureSaveButton(model: model) }
        let done = hosted(&self.done) { CaptureDoneButton(model: model) }
        // Over the editor's bar, which spans the foot they stand on.
        if subviews.firstIndex(of: saver) ?? 0 < subviews.firstIndex(of: tools) ?? 0 {
            addSubview(saver, positioned: .above, relativeTo: tools)
        }
        let keys = editorKeys(card, save: size(of: saver), done: size(of: done))
        // Each edge's move, from the corner's card to the editor's: the
        // words ride the edge they hang from, so none is ever past it.
        let oldCard = old.card.offsetBy(dx: page.minX, dy: page.minY), newCard = card.offsetBy(dx: page.minX, dy: page.minY)
        let byTopLeft = delta(CGPoint(x: oldCard.minX, y: oldCard.maxY), CGPoint(x: newCard.minX, y: newCard.maxY))
        let byFootLeft = delta(CGPoint(x: oldCard.minX, y: oldCard.minY), CGPoint(x: newCard.minX, y: newCard.minY))
        let byFootRight = delta(CGPoint(x: oldCard.maxX, y: oldCard.minY), CGPoint(x: newCard.maxX, y: newCard.minY))
        let saveFrom = saver.frame.origin
        top.frame = CGRect(x: newCard.minX, y: newCard.maxY - CaptureView.editorTop, width: card.width, height: CaptureView.editorTop)
        tools.frame = CGRect(x: newCard.minX, y: newCard.minY, width: card.width, height: CaptureView.editorFoot)
        saver.frame = keys.save
        done.frame = keys.done
        top.isHidden = false
        tools.isHidden = false
        saver.isHidden = false
        done.isHidden = false

        let t = still ? 0.15 : CaptureView.opening
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.frame = stage.bounds
        cover.magnificationFilter = .linear
        cover.contentsGravity = .resizeAspectFill
        cover.backgroundColor = NSColor(white: 0.5, alpha: 0.25).cgColor
        stage.insertSublayer(cover, below: surface)
        cover.opacity = 1
        run(cover, "opacity", 0, 1, 0.3)
        let from = surface.frame
        dressSurface(card)
        canvas.position = p
        canvas.transform = CATransform3DMakeScale(s, s, 1)
        round(s, from: still ? nil : s0, t)
        if !still {
            run(surface, "bounds", NSValue(rect: CGRect(origin: .zero, size: from.size)), NSValue(rect: surface.bounds), t)
            run(surface, "position", NSValue(point: CGPoint(x: from.midX, y: from.midY)), NSValue(point: surface.position), t)
            run(surface, "shadowPath", CGPath.rounded(CGRect(origin: .zero, size: from.size), corner: Radius.card), surface.shadowPath, t)
            run(canvas, "position", NSValue(point: p0), NSValue(point: p), t)
            run(canvas, "transform.scale", s0, s, t)
        }
        // Copied and Edit go at once, riding the foot while they go; Save
        // rides the foot's right corner into its place beside Done.
        fade(bar, to: 0, 0.06)
        ride(saver, by: delta(saveFrom, keys.save.origin), t)
        if let layer = bar?.layer, !still {
            run(layer, "transform.translation.x", 0, -byFootLeft.x, t)
            run(layer, "transform.translation.y", 0, -byFootLeft.y, t)
        }
        // The editor's words come once the card is nearly there, rising on
        // the edge they hang from.
        let late = still ? 0 : t * 0.55
        top.alphaValue = 0
        tools.alphaValue = 0
        done.alphaValue = 0
        fade(top, to: 1, 0.13, after: late)
        fade(tools, to: 1, 0.13, after: late)
        fade(done, to: 1, 0.13, after: late)
        ride(top, by: byTopLeft, lift: 8, t)
        ride(tools, by: byFootLeft, lift: 8, t)
        ride(done, by: byFootRight, lift: 8, t)
        CATransaction.commit()
        trackCard()
        window?.invalidateCursorRects(for: self)
    }

    /// Done: the same way back, quicker.
    func back(_ shot: Shot, style: CaptureStyle) {
        guard let layout else { return }
        editing = false
        let (card, slot) = plate(for: layout)
        let old = self.slot
        let oldPlate = self.card
        self.card = card
        self.slot = slot
        let (s0, p0) = placed(layout, in: old)
        let (s, p) = placed(layout, in: slot)
        let t = still ? 0.12 : CaptureView.closing
        let top = self.top, tools = self.tools, done = self.done
        let oldCard = oldPlate.offsetBy(dx: page.minX, dy: page.minY), newCard = card.offsetBy(dx: page.minX, dy: page.minY)
        let byFootLeft = delta(CGPoint(x: oldCard.minX, y: oldCard.minY), CGPoint(x: newCard.minX, y: newCard.minY))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { [weak self] in
            guard self?.editing == false else { return }
            top?.isHidden = true
            tools?.isHidden = true
            done?.isHidden = true
        } }
        let from = surface.frame
        dressSurface(card)
        canvas.position = p
        canvas.transform = CATransform3DMakeScale(s, s, 1)
        round(s, from: still ? nil : s0, t)
        cover.opacity = 0
        run(cover, "opacity", 1, 0, 0.22)
        if !still {
            run(surface, "bounds", NSValue(rect: CGRect(origin: .zero, size: from.size)), NSValue(rect: surface.bounds), t)
            run(surface, "position", NSValue(point: CGPoint(x: from.midX, y: from.midY)), NSValue(point: surface.position), t)
            run(surface, "shadowPath", CGPath.rounded(CGRect(origin: .zero, size: from.size), corner: Radius.card), surface.shadowPath, t)
            run(canvas, "position", NSValue(point: p0), NSValue(point: p), t)
            run(canvas, "transform.scale", s0, s, t)
        }
        // Gone before the card has shrunk past them.
        fade(top, to: 0, 0.06)
        fade(tools, to: 0, 0.06)
        fade(done, to: 0, 0.06)
        // Save rides the foot's corner back; Copied and Edit come beside it
        // as the card settles, on the foot.
        if let saver, let bar {
            let row = plateRow(card, save: saver.frame.size)
            let saveFrom = saver.frame.origin
            saver.frame = row.save
            ride(saver, by: delta(saveFrom, row.save.origin), t)
            bar.frame = row.row
            bar.alphaValue = 0
            fade(bar, to: 1, 0.12, after: still ? 0 : t * 0.55)
            ride(bar, by: byFootLeft, lift: 6, t)
        }
        CATransaction.commit()
        trackCard()
        window?.invalidateCursorRects(for: self)
    }

    func cover(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.contents = image
        CATransaction.commit()
    }

    /// A new look. Colors and what is hidden at once; a new shape moves the
    /// frame around the same picture (P6, P7).
    func restyle(_ shot: Shot, from old: CaptureStyle, to style: CaptureStyle, tint: NSColor?, wallpaper: CGImage?, editing: Bool) {
        backdrop(style, tint: tint, wallpaper: wallpaper)
        let layout = CaptureLayout(shot.size, style)
        guard let before = self.layout else { return }
        self.layout = layout
        let oldCard = card, oldSlot = slot
        if editing {
            // The editor keeps its size; only the canvas in it changes.
        } else {
            (card, slot) = plate(for: layout)
        }
        let (s0, p0) = placed(before, in: oldSlot)
        let (s, p) = placed(layout, in: slot)
        let t = still || layout == before ? 0 : CaptureView.reshaping
        let oldBounds = canvas.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dress(layout, style: style)
        canvas.position = p
        canvas.transform = CATransform3DMakeScale(s, s, 1)
        round(s, from: s0, t)
        if t > 0 {
            run(canvas, "bounds", NSValue(rect: oldBounds), NSValue(rect: canvas.bounds), t)
            run(bg, "bounds", NSValue(rect: oldBounds), NSValue(rect: bg.bounds), t)
            run(bg, "position", NSValue(point: CGPoint(x: oldBounds.midX, y: oldBounds.midY)), NSValue(point: bg.position), t)
            run(canvas, "position", NSValue(point: p0), NSValue(point: p), t)
            run(canvas, "transform.scale", s0, s, t)
            if !editing, oldCard != card {
                let from = oldCard
                dressSurface(card)
                run(surface, "bounds", NSValue(rect: CGRect(origin: .zero, size: from.size)), NSValue(rect: surface.bounds), t)
                run(surface, "position", NSValue(point: CGPoint(x: from.midX, y: from.midY)), NSValue(point: surface.position), t)
                run(surface, "shadowPath", CGPath.rounded(CGRect(origin: .zero, size: from.size), corner: Radius.card), surface.shadowPath, t)
            }
        } else if !editing {
            dressSurface(card)
        }
        CATransaction.commit()
        if !editing, let bar, let saver {
            // The row rides the card's foot to its new height.
            let row = plateRow(card, save: saver.frame.size)
            let by = delta(bar.frame.origin, row.row.origin)
            bar.frame = row.row
            saver.frame = row.save
            if t > 0 {
                ride(bar, by: by, t)
                ride(saver, by: by, t)
            }
            trackCard()
        }
    }

    /// Save: the picture, framed, into the downloads button, the card
    /// closing round it on the way; `landed` false with nowhere to land.
    func fly(to landing: @escaping () -> CGPoint?, landed: @escaping (Bool) -> Void) {
        cancelSwipe()
        // The button makes room first; where it is is asked once it has
        // been laid out, a few frames on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            guard !self.still, let spot = landing() else {
                self.leave { landed(false) }
                return
            }
            let there = self.convert(spot, from: nil)
            let target = CGPoint(x: there.x - self.page.minX, y: there.y - self.page.minY)
            guard let layout = self.layout else { return landed(false) }
            let (s0, p0) = self.placed(layout, in: self.slot)
            let s = 16 / max(layout.canvas.width, layout.canvas.height)
            let t = CaptureView.saving
            // The downloads button can be past the page: the stage lets go
            // of its clip for the flight.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { landed(true) } }
            self.stage.masksToBounds = false
            self.canvas.position = target
            self.canvas.transform = CATransform3DMakeScale(s, s, 1)
            self.canvas.opacity = 0
            self.run(self.canvas, "position", NSValue(point: p0), NSValue(point: target), t)
            self.run(self.canvas, "transform.scale", s0, s, t)
            self.run(self.canvas, "opacity", 1, 0, 0.08, after: t - 0.08)
            let from = self.surface.frame
            let to = CGRect(x: target.x - 8, y: target.y - 8, width: 16, height: 16)
            self.dressSurface(to)
            self.surface.opacity = 0
            self.run(self.surface, "bounds", NSValue(rect: CGRect(origin: .zero, size: from.size)), NSValue(rect: self.surface.bounds), 0.24)
            self.run(self.surface, "position", NSValue(point: CGPoint(x: from.midX, y: from.midY)), NSValue(point: self.surface.position), 0.24)
            self.run(self.surface, "opacity", 1, 0, 0.12, after: 0.12)
            self.cover.opacity = 0
            self.run(self.cover, "opacity", 1, 0, 0.2)
            for view in [self.bar, self.top, self.tools, self.saver, self.done] as [NSView?] { self.fade(view, to: 0, 0.1) }
            CATransaction.commit()
        }
    }

    /// Away, up a little and out, quicker than it came.
    func leave(_ done: @escaping () -> Void) {
        let t = CaptureView.leaving
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        stage.opacity = 0
        run(stage, "opacity", 1, 0, t, curve: CaptureView.out)
        if !still {
            if swipeOffset != 0 {
                let direction: CGFloat = swipeOffset > 0 ? 1 : -1
                moveCard(to: swipeOffset + direction * 100, animated: true)
            } else {
                run(stage, "transform.translation.y", 0, 6, t, curve: CaptureView.out)
            }
        }
        for view in [foot, bar, top, tools, saver, self.done] as [NSView?] { fade(view, to: 0, t) }
        CATransaction.commit()
    }

    /// What ./bench is told: where each part is, in window points.
    var state: [String: Any] {
        func r(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height].map { Double(($0 * 10).rounded() / 10) } }
        var out: [String: Any] = [
            "page": r(page),
            "card": r(card.offsetBy(dx: page.minX, dy: page.minY)),
            "picture": r(pictureOnScreen),
            "ring": ring.opacity, "veil": veil.opacity, "cover": cover.opacity,
            "blocks": blocks.filter { !$0.isHidden }.count,
            "editing": editing,
        ]
        out["view"] = [
            "frame": r(frame), "hidden": isHidden, "alpha": alphaValue,
            "super": superview.map { String(describing: type(of: $0)) } ?? "none",
            "window": window?.windowNumber ?? -1,
            "index": superview?.subviews.firstIndex(of: self) ?? -1,
            "siblings": superview?.subviews.count ?? 0,
            "layer": layer.map { "\(type(of: $0)) sub=\($0.sublayers?.count ?? 0) op=\($0.opacity) hidden=\($0.isHidden)" } ?? "none",
            "stage": "\(stage.frame) op=\(stage.opacity) super=\(stage.superlayer != nil)",
        ]
        if let foot { out["foot"] = r(foot.frame) }
        if let bar { out["bar"] = r(bar.frame) }
        if let saver { out["save"] = r(saver.frame) }
        if let done { out["done"] = r(done.frame) }
        return out
    }
}

/// The room, kept out of accessibility until a capture is up in it.
struct CaptureSkyLayer: View {
    let capture: Capture
    @ObservedObject private var model: CaptureModel

    init(capture: Capture) {
        self.capture = capture
        model = capture.model
    }

    var body: some View {
        CaptureSky(capture: capture).accessibilityHidden(!model.up)
    }
}

/// The room the capture's view is put in, over everything in the window,
/// as the other skies are (HoardSky, ChorusSky). Empty, it lets every click
/// through.
struct CaptureSky: NSViewRepresentable {
    let capture: Capture

    func makeNSView(context: Context) -> CaptureRoom {
        let room = CaptureRoom()
        capture.room = room
        return room
    }

    func updateNSView(_ room: CaptureRoom, context: Context) {
        capture.room = room
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CaptureRoom, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// The card's floor under the capture's hosted words: drawn, never hit.
final class CaptureFloor: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class CaptureRoom: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

// MARK: - what the capture says

/// The bar at the page's foot while picking, on Liquid Glass as the
/// field's box is: what to do, and the buttons for what a click can't say,
/// each with its key.
struct CaptureFoot: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        ModeFoot(say: "Click a part or drag an area", busy: model.busy) {
            FootKey("Visible", "↩", .secondary) { model.act(.visible) }
            FootKey("Whole Page", "F", .secondary) { model.act(.whole) }
            FootKey("Cancel", "esc", .quiet) { model.act(.cancel) }
        }
    }
}

/// A mode's bar at the page's foot, while the pointer picks something on
/// the page, Capture's and Hide Elements': what a click does now, in muted
/// words, and the buttons that end it or take a step back, each with its
/// key. While something is under way, `busy` says so in ink instead.
struct ModeFoot<Buttons: View>: View {
    let say: String
    var busy: String? = nil
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        HStack(spacing: 4) {
            if let busy {
                Text(busy)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .frame(height: ButtonSize.regular.height)
            } else {
                Text(say)
                    .foregroundStyle(Palette.muted)
                    .padding(.leading, 10)
                    .padding(.trailing, 6) // design: the words' room before the first button, with the row's 4
                buttons()
            }
        }
        .font(.system(size: 12.5))
        .padding(BarFrame.inset)
        .background { CaptureGlass(corner: Radius.floating) }
        .fixedSize()
    }
}

/// A button on a mode's bar, its key after its words.
struct FootKey: View {
    let title: String
    let keys: String
    let kind: ButtonKind
    let act: () -> Void

    init(_ title: String, _ keys: String, _ kind: ButtonKind, act: @escaping () -> Void) {
        self.title = title
        self.keys = keys
        self.kind = kind
        self.act = act
    }

    var body: some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Text(title)
                KeyGlyphs(keys: keys, size: 12.5, tint: nil, rest: 0.6)
                    .transaction { $0.animation = nil }
            }
        }
        .buttonStyle(.yab(kind, .regular))
    }
}

/// The bar's ground: Liquid Glass over a material, as the field's box has
/// it (Omnibox), so a busy page is an even haze under the words; a card's
/// ground, hairline and shadow where the Mac draws no glass.
struct CaptureGlass: View {
    let corner: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        if #available(macOS 26.0, *), PullView.glassy {
            ZStack {
                shape.fill(.regularMaterial)
                Color.clear.glassEffect(.regular.tint(Palette.ground.opacity(Omnibox.glassTint)), in: shape)
            }
        } else {
            shape
                .fill(Palette.ground)
                .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(Double(Shadow.card.opacity)), radius: Shadow.card.radius, y: Shadow.card.y) // design: the glass bar's fallback is a card's shadow on its shape
        }
    }
}

/// The row under the picture in the corner: it is on the clipboard, how
/// big, and the two things to do next. The picture itself is the way to
/// the editor, and a drag takes it anywhere.
struct CapturePlateBar: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        HStack(spacing: 6) {
            Symbol("doc.on.clipboard", size: 11)
                .foregroundStyle(Palette.muted)
            Text("Copied")
                .foregroundStyle(Palette.ink)
                .fixedSize()
            Text(model.dims)
                .foregroundStyle(Palette.muted)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Edit") { model.act(.edit) }
                .buttonStyle(.yab(.secondary, .regular))
                .fixedSize()
        }
        .font(.system(size: 12.5))
    }
}

/// Save, the one button the corner's card and the editor share: the view
/// over the page moves it from one place to the other (CaptureView).
struct CaptureSaveButton: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        Button { model.act(.save) } label: {
            HStack(spacing: 6) {
                Text("Save")
                ShortcutGlyphs(.captureSave, size: 12.5, tint: nil).opacity(0.6)
                    .transaction { $0.animation = nil }
            }
        }
        .buttonStyle(.yab(.secondary, .regular))
        .fixedSize()
    }
}

/// Done, the editor's last word, beside Save.
struct CaptureDoneButton: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        Button { model.act(.done) } label: {
            HStack(spacing: 6) {
                Text("Done")
                KeyGlyphs(keys: "↩", size: 12.5, tint: nil, rest: 0.6)
                    .transaction { $0.animation = nil }
            }
        }
        .buttonStyle(.yab(.primary, .regular))
        .fixedSize()
    }
}

struct CaptureEditorTop: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        HStack(spacing: 6) {
            Text(model.host.isEmpty ? "Capture" : model.host)
                .fontWeight(.medium)
                .foregroundStyle(Palette.ink)
            Text(model.name)
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 12)
            Text(model.dims)
                .foregroundStyle(Palette.muted)
                .monospacedDigit()
        }
        .lineLimit(1)
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
    }
}

/// The editor's controls: four, and nothing to manage. The backdrop, the
/// shape, whether private things show, and done.
struct CaptureEditorBar: View {
    @ObservedObject var model: CaptureModel

    private var style: CaptureStyle { model.style }

    private func set(_ change: (inout CaptureStyle) -> Void) {
        var next = model.style
        change(&next)
        model.act(.style(next))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Backdrop")
                    .foregroundStyle(Palette.muted)
                    .frame(width: 64, alignment: .leading)
                CaptureSwatch(on: style.backdrop == .page, help: "The page’s colors") {
                    LinearGradient(colors: CaptureArt.colors(CaptureStyle(), tint: model.tint).map { Color(cgColor: $0) },
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                } act: { set { $0.backdrop = .page } }
                CaptureHue(hue: style.hue, on: style.backdrop == .hue) { hue in set { $0.hue = hue; $0.backdrop = .hue } }
                CaptureSwatch(on: style.backdrop == .wallpaper, help: "Your wallpaper") {
                    if let wallpaper = model.wallpaper {
                        Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Palette.faint
                    }
                } act: { set { $0.backdrop = .wallpaper } }
                CaptureSwatch(on: style.backdrop == .none, help: "No backdrop") {
                    ZStack {
                        Palette.ground
                        Path { p in p.move(to: CGPoint(x: 4, y: 16)); p.addLine(to: CGPoint(x: 16, y: 4)) }
                            .stroke(Palette.muted, lineWidth: 1.5)
                    }
                } act: { set { $0.backdrop = .none } }
                Spacer(minLength: 16)
                Text("Shape")
                    .foregroundStyle(Palette.muted)
                HStack(spacing: 2) {
                    ForEach(CaptureStyle.Shape.allCases, id: \.self) { shape in
                        Button(shape.title) { set { $0.shape = shape } }
                            .buttonStyle(.yab(style.shape == shape ? .secondary : .quiet, .small))
                            .disabled(style.backdrop == .none || !CaptureLayout.fits(model.size, shape))
                    }
                }
            }
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { style.hidePrivate }, set: { on in set { $0.hidePrivate = on } })) {
                    Text("Hide emails, keys and card numbers")
                }
                .toggleStyle(.checkbox)
                .disabled(model.secrets == 0)
                Text(model.secrets == 0 ? "none here" : model.secrets == 1 ? "1 here" : "\(model.secrets) here")
                    .foregroundStyle(Palette.muted)
                // Save and Done stand here, laid over the bar on their own
                // (CaptureSaveButton): Save comes from the corner's card.
                Spacer(minLength: 200)
            }
            .frame(height: ButtonSize.regular.height)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

/// A round swatch, ringed in ink when it is the one.
struct CaptureSwatch<Fill: View>: View {
    let on: Bool
    let help: String
    @ViewBuilder let fill: () -> Fill
    let act: () -> Void

    var body: some View {
        Button(action: act) {
            fill()
                .frame(width: 20, height: 20)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1)) // design: a swatch's edge, not a card
                .padding(2)
                .overlay(Circle().strokeBorder(on ? Palette.ink : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .keyTip(help)
    }
}

/// The hue, a rainbow to drag along: the whole of Arc's Portrait Mode in
/// one control, and the backdrop follows the thumb at once.
struct CaptureHue: View {
    let hue: Double
    let on: Bool
    let change: (Double) -> Void
    static let width: CGFloat = 180

    var body: some View {
        let stops = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { h in
            Color(hue: (h + 0.05).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.95)
        }
        ZStack(alignment: .leading) {
            Capsule()
                .fill(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
                .frame(height: 10)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(on ? Palette.ink : Color.black.opacity(0.2), lineWidth: on ? 1.5 : 1))
                .frame(width: 16, height: 16)
                .offset(x: (CaptureHue.width - 16) * hue / 360)
        }
        .frame(width: CaptureHue.width, height: 20)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            change(min(360, max(0, Double((drag.location.x - 8) / (CaptureHue.width - 16)) * 360)))
        })
        .pointerTip("A backdrop in any color")
    }
}
