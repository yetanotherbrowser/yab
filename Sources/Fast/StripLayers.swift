import AppKit
import SwiftUI

// The strip across the top in a view of its own, and a change of space
// played on it in Core Animation (StripTurn).
//
// In the window's own SwiftUI host, a switch's first pass held the main
// thread 70 to 90 ms laying out the whole window for the new space, and the
// strip waited for it: the page had changed (PageStills puts it up first),
// the strip still showed the space left, then moved once the pass was over.
// And every frame of the turn was a pass of the window's SwiftUI: the tabs
// after the capsule riding its edge (LeadSlide), the old row going, the new
// one coming, the names' carousel, 60 to 90 ms of the main thread a switch.
//
// Here the strip is laid out for the new space on its own, the moment the
// switch has written it; pictured before and after, as the column's row of
// spaces is (SpacePager); and the turn is played from those pictures by the
// render server: the plate's width, the names' carousel in it, the old row
// going and the new one coming, on StripTurn's spring and curves, put on
// screen before the window's own pass. When it has landed the pictures go
// and the strip itself shows, laid out as the last frame was.

/// Where things stand along the strip, as TabBar lays it out (its body
/// notes it): the capsule's plate, the run of tabs after it, the doors at
/// the far end.
struct StripGeometry: Equatable {
    var capsuleX: CGFloat
    var plate: CGFloat
    var lead: CGFloat
    var doorsStart: CGFloat
    var width: CGFloat

    @MainActor private static var noted: [ObjectIdentifier: StripGeometry] = [:]
    @MainActor static func note(_ browser: Browser, _ geometry: StripGeometry) { noted[ObjectIdentifier(browser)] = geometry }
    @MainActor static func of(_ browser: Browser) -> StripGeometry? { noted[ObjectIdentifier(browser)] }
}

/// TabBar drawn in a host of its own, so a change of space can lay it out
/// and picture it apart from the window (above). Its host keeps the
/// surrounding environment whole, as SlideHost's does.
struct StripHost<Content: View>: NSViewRepresentable {
    let browser: Browser
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> StripView { StripView(browser: browser) }

    func updateNSView(_ view: StripView, context: Context) {
        view.still = context.environment.accessibilityReduceMotion
        view.tone = context.environment.tone
        view.scheme = context.environment.colorScheme
        view.host.rootView = AnyView(content.hosted(in: context.environment))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StripView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: Metrics.row)
    }

    static func dismantleNSView(_ view: StripView, coordinator: ()) { view.finish() }
}

@MainActor
final class StripView: NSView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    private(set) weak var browser: Browser?
    var tone: Tone?
    var scheme: ColorScheme = .light
    var still = false
    /// The turn's pictures over the strip, while one plays.
    private var turning: CALayer?

    /// The strip of each window's browser.
    private static let views = NSMapTable<Browser, StripView>.weakToWeakObjects()
    static func of(_ browser: Browser) -> StripView? { views.object(forKey: browser) }

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        // The turn's pictures, over the strip in a view of their own whose
        // layers are ours, not AppKit's to sort; presses go through it.
        stage.layer = CALayer()
        stage.wantsLayer = true
        stage.layer?.masksToBounds = false
        addSubview(stage, positioned: .above, relativeTo: host)
        Self.views.setObject(self, forKey: browser)
        StripTurn.hosted = true
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        host.frame = bounds
        stage.frame = bounds
    }

    /// Where the turn's pictures stand: drawn, never pressed.
    private final class Stage: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    private let stage = Stage()

    /// A picture of the strip as it is drawn now, and where things stand in
    /// it. Nil while it can't be: not in a window, or never laid out.
    struct Picture {
        let image: CGImage
        let geometry: StripGeometry
        let scale: CGFloat
        let ground: CGColor?
    }

    func picture() -> Picture? {
        guard let browser, let window, let layer = host.layer, let geometry = StripGeometry.of(browser),
              bounds.width > 1, abs(geometry.width - bounds.width) < 1 else { return nil }
        let scale = window.backingScaleFactor
        let size = bounds.size
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: window.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // As SpacePager's snapshot: turned over, y down as the host lays it.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        // Drawn whole even while hidden under a turn's pictures (its alpha):
        // the new space's strip is pictured then, and came out empty.
        let shown = layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        Bench.render(layer, in: context)
        layer.opacity = shown
        CATransaction.commit()
        guard let image = context.makeImage() else { return nil }
        // The plate's own color, on its top edge halfway along, where the name
        // never stands: under two fingers it slides, and the emoji's color
        // was taken for the plate's at its leading edge.
        let ground = Self.color(in: context, scale: scale, at: CGPoint(x: geometry.capsuleX + geometry.plate / 2, y: (size.height - CapsulePlan.stripHeight) / 2 + 1))
        return Picture(image: image, geometry: geometry, scale: scale, ground: ground)
    }

    /// Before a switch writes anything: a turn still playing lands, and the
    /// strip as it is now is pictured for the next one.
    func prepare() -> Picture? {
        guard StripTurn.layered, !still, !SpaceTurn.still else { return nil }
        finish()
        return picture()
    }

    /// The turn under way lands now: its pictures go, the strip shows.
    func finish() {
        guard let turning else { return }
        self.turning = nil
        SwitchMeter.mark("strip landed")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        turning.removeFromSuperlayer()
        host.alphaValue = 1
        CATransaction.commit()
    }

    /// The switch has written the new space: the turn sets off now from
    /// `before` (the strip as it was), with nothing laid out, and is put on
    /// screen at once; the new row joins it once the window's pass has laid
    /// the strip out for the new space (`arrive`). Laying the strip out here
    /// was the window's whole pass, 40 to 50 ms, before anything moved.
    /// `way`: 1 to a space after, -1 to one before; `start`: how far two
    /// fingers had taken it (0 for a key). False when it can't, and the strip
    /// just shows the new space.
    @discardableResult
    func turn(from before: Picture, old: Space, new: Space, way: Int, start: CGFloat) -> Bool {
        guard StripTurn.layered, !still, !SpaceTurn.still, old.id != new.id, window != nil else { return false }
        let a = before.geometry
        let h = bounds.height
        let w = bounds.width
        guard abs(a.width - w) < 1 else { return false }
        let d = CGFloat(way == 0 ? 1 : way)
        let q = min(max(start, 0), 0.95)
        // Where the plate's edge and the run after it will be: the name's
        // own width, as the strip lays it (CapsulePlan.strip).
        let plateTo = CapsulePlan.strip(name: new.name).width ?? a.plate
        let leadTo = a.lead + (plateTo - a.plate)

        let root = CALayer()
        root.frame = bounds
        root.masksToBounds = false

        // What doesn't move: the lights and the arrows, the pins ahead of
        // the capsule, and the doors at the far end, as they were until the
        // new space's are pictured.
        let fixed = CALayer()
        fixed.frame = bounds
        fixed.addSublayer(Self.crop(before, 0, a.capsuleX, w: w, h: h))
        fixed.addSublayer(Self.crop(before, a.doorsStart, w, w: w, h: h))
        root.addSublayer(fixed)
        // The rows, cut at the doors: the old one now, the new one to come.
        let rows = CALayer()
        rows.frame = CGRect(x: 0, y: 0, width: a.doorsStart, height: h)
        rows.masksToBounds = true
        root.addSublayer(rows)
        let oldRow = Self.crop(before, a.lead, a.doorsStart, w: w, h: h)
        rows.addSublayer(oldRow)
        // The plate, in its own color as the strip draws it.
        let plateFrame = CGRect(x: a.capsuleX, y: (h - CapsulePlan.stripHeight) / 2, width: a.plate, height: CapsulePlan.stripHeight)
        let plate = CALayer()
        plate.anchorPoint = CGPoint(x: 0, y: 0.5)
        plate.frame = plateFrame
        plate.cornerRadius = Radius.control
        plate.cornerCurve = .continuous
        plate.backgroundColor = before.ground ?? CGColor(gray: 1, alpha: 0.3)
        root.addSublayer(plate)
        // The names, clipped by a plate the same.
        let clip = CALayer()
        clip.anchorPoint = CGPoint(x: 0, y: 0.5)
        clip.frame = plateFrame
        clip.cornerRadius = Radius.control
        clip.cornerCurve = .continuous
        clip.masksToBounds = true
        root.addSublayer(clip)
        let oldName = label(old, scale: before.scale)
        let newName = label(new, scale: before.scale)
        let span = CapsulePlan.mark + CapsulePlan.stripGap + CapsulePlan.words(old.name, size: SidebarTypography.current) + StripTurn.nameGap
        let rest = CapsulePlan.stripInset
        for name in [oldName, newName] {
            name.frame.origin = CGPoint(x: rest, y: (CapsulePlan.stripHeight - name.bounds.height) / 2)
            clip.addSublayer(name)
        }

        // The curves, sampled from now: the spring's way for the plate, the
        // names and the old row riding the plate's edge as it goes.
        let duration = StripTurn.span + 0.02
        var plateW: [CGFloat] = [], oldX: [CGFloat] = [], oldA: [Float] = []
        var oldNameX: [CGFloat] = [], oldNameA: [Float] = [], newNameX: [CGFloat] = [], newNameA: [Float] = []
        let holdsNext = q >= StripTurn.crossing
        let times = Self.sample(duration) { t in
            let s = CGFloat(StripTurn.way(t))
            // The names go on from where the fingers left them.
            let p = q + (1 - q) * s
            let r = StripTurn.arrived(t)
            plateW.append(a.plate + (plateTo - a.plate) * s)
            // The old row: with the plate's edge, going the other way, and
            // dimmed, not gone: it stands until the new one is there to take
            // its place (`arrive`), so the strip is never empty between.
            // After two fingers it is one row or the other in the picture
            // (StripTurn.crossing): the next one's stands, its place the
            // new row takes over; what is left of the old one just goes.
            oldX.append(a.lead + (leadTo - a.lead) * s - (holdsNext ? 0 : d * StripTurn.leave * r))
            oldA.append(q == 0 ? Float(1 - 0.5 * r) : holdsNext ? 1 : Float(max(0, 1 - 2 * r)))
            oldNameX.append(rest - d * p * span + oldName.bounds.width / 2)
            oldNameA.append(Float(1 - p))
            newNameX.append(rest + d * (1 - p) * span + newName.bounds.width / 2)
            newNameA.append(Float(min(1, p * 1.4)))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // At rest where the turn ends; each animation draws the way there.
        plate.bounds.size.width = plateTo
        clip.bounds.size.width = plateTo
        Self.play(plate, "bounds.size.width", plateW, times, duration)
        Self.play(clip, "bounds.size.width", plateW, times, duration)
        Self.play(oldRow, "position.x", oldX, times, duration)
        Self.play(oldRow, "opacity", oldA, times, duration)
        Self.play(oldName, "position.x", oldNameX, times, duration)
        Self.play(oldName, "opacity", oldNameA, times, duration)
        Self.play(newName, "position.x", newNameX, times, duration)
        Self.play(newName, "opacity", newNameA, times, duration)
        oldRow.position.x = oldX.last ?? oldRow.position.x
        oldRow.opacity = oldA.last ?? 0.5
        oldName.opacity = 0
        oldName.position.x = oldNameX.last ?? oldName.position.x
        newName.position.x = newNameX.last ?? newName.position.x
        stage.layer?.addSublayer(root)
        host.alphaValue = 0
        CATransaction.commit()
        turning = root
        let began = CACurrentMediaTime()
        // On screen now, before the window's own pass for the switch.
        CATransaction.flush()
        // The new row, once that pass has laid the strip out for the space.
        DispatchQueue.main.async { [weak self, weak root] in
            guard let self, let root, self.turning === root else { return }
            self.arrive(root, fixed: fixed, rows: rows, oldRow: oldRow, from: a, plateTo: plateTo,
                        way: d, start: q, began: began, ground: before.ground)
        }
        return true
    }

    /// The window has laid the strip out for the new space: picture it, and
    /// bring its row in where the plate's edge is now, as the old one goes;
    /// the still parts take the new space's look. The turn lands when the
    /// last of it has.
    private func arrive(_ root: CALayer, fixed: CALayer, rows: CALayer, oldRow: CALayer, from a: StripGeometry,
                        plateTo: CGFloat, way d: CGFloat, start q: CGFloat, began: CFTimeInterval, ground: CGColor?) {
        host.layoutSubtreeIfNeeded()
        SwitchMeter.mark("strip laid")
        guard let after = picture(), abs(after.geometry.capsuleX - a.capsuleX) < 0.5, abs(after.geometry.width - a.width) < 0.5 else {
            finish()
            return
        }
        let b = after.geometry
        let h = bounds.height, w = bounds.width
        let now = CACurrentMediaTime()
        let t0 = now - began
        let newRow = Self.crop(after, b.lead, b.doorsStart, w: w, h: h)
        // After two fingers no title stands over another: the next row in
        // the picture gives way to this one where it stands, at once; what
        // is left of the old one goes first, and this one comes up after.
        let holdsNext = q >= StripTurn.crossing
        let fromOld = oldRow.presentation()?.opacity ?? oldRow.opacity
        let wait: TimeInterval = q > 0 && !holdsNext && fromOld > 0.01 ? 0.04 : 0
        let shown = holdsNext ? StripTurn.coming(q) : 0
        let length = max(StripTurn.arrivalTime + wait, StripTurn.span + 0.02 - t0) + 0.02
        var newX: [CGFloat] = [], newA: [Float] = [], oldA: [Float] = []
        let times = Self.sample(length) { t in
            let s = CGFloat(StripTurn.way(t0 + t))
            let r = StripTurn.arrived(max(0, t - wait))
            // On the plate's edge, wherever the spring has it.
            let edge = (a.lead - b.lead) * (1 - s)
            newX.append(b.lead + edge + d * StripTurn.arrival * (1 - q) * (1 - r))
            newA.append(Float(shown + (1 - shown) * r))
            oldA.append(q == 0 ? fromOld * Float(max(0, 1 - 2 * r))
                        : wait > 0 ? fromOld * Float(max(0, 1 - t / wait)) : 0)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Before any animation is added: set after them, Core Animation calls
        // it at once, and the turn landed the moment the new row came.
        CATransaction.setCompletionBlock { [weak self, weak root] in
            MainActor.assumeIsolated {
                guard let self, let root, self.turning === root else { return }
                self.finish()
            }
        }
        rows.frame.size.width = min(a.doorsStart, b.doorsStart)
        rows.addSublayer(newRow)
        Self.play(newRow, "position.x", newX, times, length)
        Self.play(newRow, "opacity", newA, times, length)
        newRow.position.x = b.lead
        oldRow.removeAnimation(forKey: "turn.opacity")
        if q > 0, wait == 0 {
            oldRow.removeFromSuperlayer()
        } else {
            Self.play(oldRow, "opacity", oldA, times, length)
            oldRow.opacity = 0
        }
        // The lights, the shared pins and the doors as the new space has them.
        fixed.sublayers = [Self.crop(after, 0, b.capsuleX, w: w, h: h), Self.crop(after, b.doorsStart, w, w: w, h: h)]
        CATransaction.commit()
        SwitchMeter.mark("strip arrived")
    }

    /// The part of a picture between `x0` and `x1`, placed where it was
    /// drawn, by its leading edge (anchor 0).
    private static func crop(_ picture: Picture, _ x0: CGFloat, _ x1: CGFloat, w: CGFloat, h: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer.frame = CGRect(x: x0, y: 0, width: max(0, x1 - x0), height: h)
        layer.contents = picture.image
        layer.contentsScale = picture.scale
        layer.contentsGravity = .resize
        layer.contentsRect = CGRect(x: x0 / w, y: 0, width: max(0, x1 - x0) / w, height: 1)
        return layer
    }

    /// Times 0 to 1 over `duration`, at 120 a second, `each` given each one's
    /// seconds in.
    private static func sample(_ duration: TimeInterval, _ each: (TimeInterval) -> Void) -> [NSNumber] {
        let steps = max(1, Int(duration * 120))
        return (0...steps).map { i in
            let t = Double(i) / 120
            each(t)
            return NSNumber(value: min(1, t / duration))
        }
    }

    private static func play(_ layer: CALayer, _ keyPath: String, _ values: [Any], _ times: [NSNumber], _ duration: TimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        animation.duration = duration
        animation.calculationMode = .linear
        // Its first value from the very first frame drawn, and its last one
        // held: without, a frame could show where the layer ends up.
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "turn." + keyPath)
    }

    /// Names pictured, by space, name, emoji, light or dark and scale.
    private var labels: [String: CGImage] = [:]

    /// A space's emoji and name as the capsule draws them, pictured.
    private func label(_ space: Space, scale: CGFloat) -> CALayer {
        let layer = CALayer()
        let key = "\(space.id) \(space.name) \(space.icon) \(scheme) \(scale) \(SidebarTypography.current)"
        var image = labels[key]
        if image == nil {
            let renderer = ImageRenderer(content: SpaceCapsule.stripLabel(space).toned(tone).environment(\.colorScheme, scheme))
            renderer.scale = scale
            // Under the strip's own light or dark (its tone's): the ink is a pair.
            NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?
                .performAsCurrentDrawingAppearance { image = renderer.cgImage }
            if labels.count > 32 { labels.removeAll() }
            labels[key] = image
        }
        if let image {
            layer.contents = image
            layer.contentsScale = scale
            layer.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        return layer
    }

    /// The color drawn at `point` (in points, y down) of a picture's context.
    private static func color(in context: CGContext, scale: CGFloat, at point: CGPoint) -> CGColor? {
        guard let data = context.data else { return nil }
        let x = Int(point.x * scale), y = Int(point.y * scale)
        guard x >= 0, y >= 0, x < context.width, y < context.height else { return nil }
        // Rows from the top in memory: the context was drawn turned over.
        let pixel = data.advanced(by: y * context.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        // Little-endian premultiplied ARGB: B, G, R, A in memory.
        let a = CGFloat(pixel[3]) / 255
        guard a > 0.01 else { return nil }
        let r = CGFloat(pixel[2]) / 255 / a, g = CGFloat(pixel[1]) / 255 / a, b = CGFloat(pixel[0]) / 255 / a
        return CGColor(srgbRed: min(1, r), green: min(1, g), blue: min(1, b), alpha: a)
    }
}
