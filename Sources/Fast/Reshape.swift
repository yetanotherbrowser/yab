import AppKit
import SwiftUI

// The page changing shape as tabs or a panel move, done by Core Animation
// rather than by SwiftUI.
//
// Animated by SwiftUI, the page's new frame is worked out again on every
// frame of the move: the whole window is laid out anew, sixty times a
// second, on the main thread, most of what a frame of the change cost,
// and on a 120 Hz screen more than a frame has. So the window is laid out
// once, at once, where everything ends up, and the two things that show the
// page's edge, the page itself and the paper it lies on, draw that edge
// from where it was to where it is on their own layers, in the render
// server. The main thread has nothing to do for it after the first frame.

enum Reshape {
    /// A curve of `Motion`'s, for Core Animation as well as for SwiftUI, so
    /// what the page does in the render server keeps step with what moves
    /// beside it.
    enum Pace {
        /// `room` and `unroom`: the page in front making room for a tab
        /// carried over it and taking it back (Browser.previewSplit), the
        /// way back quicker, both landing soft. `strip`: ⌘S putting the
        /// strip of tabs away and bringing it back (Motion.stripCurve).
        case reshape, arrive, depart, room, unroom, strip

        var duration: CFTimeInterval {
            let base: CFTimeInterval = switch self {
            case .reshape: 0.3
            case .arrive: 0.22
            case .depart: 0.15
            case .room: 0.2
            case .unroom: 0.16
            case .strip: Motion.stripTime
            }
            return base * Reshape.slow
        }

        var timing: CAMediaTimingFunction {
            switch self {
            case .reshape, .arrive, .room, .unroom: CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            case .depart: CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.4)
            case .strip: CAMediaTimingFunction(controlPoints: Motion.stripCurve.0, Motion.stripCurve.1, Motion.stripCurve.2, Motion.stripCurve.3)
            }
        }

        var animation: Animation {
            switch self {
            case .reshape: Motion.reshape
            case .arrive: Motion.arrive
            case .depart: Motion.depart
            case .room, .unroom: .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
            case .strip: .timingCurve(Double(Motion.stripCurve.0), Double(Motion.stripCurve.1), Double(Motion.stripCurve.2), Double(Motion.stripCurve.3), duration: duration)
            }
        }

        /// The same curve, to be read at any point of the way from here
        /// rather than handed to Core Animation.
        var curve: UnitCurve {
            switch self {
            case .reshape, .arrive, .room, .unroom: .bezier(startControlPoint: UnitPoint(x: 0.2, y: 0.8), endControlPoint: UnitPoint(x: 0.2, y: 1))
            case .depart: .bezier(startControlPoint: UnitPoint(x: 0.4, y: 0), endControlPoint: UnitPoint(x: 0.8, y: 0.4))
            case .strip: .bezier(startControlPoint: UnitPoint(x: Double(Motion.stripCurve.0), y: Double(Motion.stripCurve.1)),
                                 endControlPoint: UnitPoint(x: Double(Motion.stripCurve.2), y: Double(Motion.stripCurve.3)))
            }
        }
    }

    /// Every curve drawn this many times slower, for pictures of it frame
    /// by frame in a test world (`reshape.slow`).
    static let slow: CFTimeInterval = Store.testing ? max(1, Store.settings.double(forKey: "reshape.slow")) : 1

    /// The curve the change under way is drawn on: `Motion.reshape`'s,
    /// unless ⌘S has asked for the column's own.
    static var pace = Pace.reshape
    static var duration: CFTimeInterval { pace.duration }
    static var timing: CAMediaTimingFunction { pace.timing }

    /// The least corner an outline that moves is drawn with. A path is
    /// drawn from one shape to another only between paths of the same
    /// parts; a rounded rectangle has eighteen, a square one five, and a
    /// corner going to nothing would jump square in the first frame.
    static let leastCorner: CGFloat = 0.01

    /// A card's outline with the corners every card here has, the
    /// continuous kind, which CGPath has no word for but SwiftUI draws.
    static func outline(_ rect: CGRect, corner: CGFloat) -> CGPath {
        guard corner > 0 else { return CGPath(rect: rect, transform: nil) }
        // The same shape SwiftUI draws the address bar's corners and every
        // card clip with (PageCut, AddressBar): one curve everywhere on the
        // card's edge (docs/page-corners.md).
        return UnevenRoundedRectangle(
            topLeadingRadius: corner, bottomLeadingRadius: corner,
            bottomTrailingRadius: corner, topTrailingRadius: corner,
            style: .continuous
        ).path(in: rect).cgPath
    }

    /// The same, with the corners along one edge left square, the page
    /// under the address bar, whose top corners are the bar's. Along a side,
    /// the round outline is drawn past that edge, far enough for a
    /// continuous corner to be wholly beyond it, and cut back to the
    /// rectangle.
    static func outline(_ rect: CGRect, corner: CGFloat, square edge: CGRectEdge?) -> CGPath {
        guard let edge, corner > 0 else { return outline(rect, corner: corner) }
        // Along the top or the bottom, the corners there all but square:
        // the same parts in the same order for any rectangle, so a mask can
        // be drawn from one to another. Cut from a larger one, the outline's
        // parts came in an order that changed with the rectangle, and Core
        // Animation drew them sweeping across the page on their way.
        if edge == .minYEdge || edge == .maxYEdge {
            let low = edge == .minYEdge ? leastCorner : corner
            let high = edge == .maxYEdge ? leastCorner : corner
            return UnevenRoundedRectangle(
                topLeadingRadius: low, bottomLeadingRadius: high,
                bottomTrailingRadius: high, topTrailingRadius: low,
                style: .continuous
            ).path(in: rect).cgPath
        }
        let past = corner * 2
        var grown = rect
        switch edge {
        case .maxYEdge: grown.size.height += past
        case .minYEdge: grown.origin.y -= past; grown.size.height += past
        case .maxXEdge: grown.size.width += past
        case .minXEdge: grown.origin.x -= past; grown.size.width += past
        }
        return outline(grown, corner: corner).intersection(CGPath(rect: rect, transform: nil))
    }

    /// When a change of shape last started, as its curves were handed to
    /// Core Animation: what is held until it is over waits from here, not
    /// from when the change was asked for, which on a busy Mac can be a
    /// good part of a second earlier.
    static var started: CFTimeInterval = 0
    /// How many curves were handed to Core Animation, for `bench pace`.
    static var runs = 0

    /// The longest a change asked for at `asked` waits for the window's
    /// pass to hand its curves over, a frame at a time, before it is taken
    /// as having none (nothing held moved). Yab in the back, behind another
    /// app's window, was laid out more than half a second after the change.
    static let longestWait: CFTimeInterval = 1

    /// `done` a frame after the curve of a change asked for at `asked` has
    /// run, counted from when the window's pass handed it to Core Animation
    /// (`started`). Until that pass has come, it waits for it, a frame at a
    /// time: on a busy Mac, or with the window's glass, it came a fifth of a
    /// second after the change, and what holds the page let go before it
    /// left the page unheld for its own layout, at its new size in one frame.
    @MainActor static func landed(after asked: CFTimeInterval, pace: Pace, _ done: @escaping @MainActor () -> Void) {
        let now = CACurrentMediaTime()
        let handed = started >= asked
        var left = max(asked, started) + pace.duration + 1.0 / 60 - now
        if !handed, now - asked < longestWait { left = max(left, 1.0 / 60) }
        guard left > 0.002 else { return done() }
        DispatchQueue.main.asyncAfter(deadline: .now() + left) {
            MainActor.assumeIsolated { landed(after: asked, pace: pace, done) }
        }
    }

    /// `key` on `layer` goes from `from` to what the layer already holds.
    static func run(_ key: String, from: Any, on layer: CALayer) {
        started = CACurrentMediaTime()
        runs += 1
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: "reshape." + key)
    }

    /// Everything under the band that `slide` moves, so it need not walk
    /// the window's views to find them: each half's card whole (its address
    /// bar, page and paper, PeekSurfaceView), the chat's column
    /// (ChatColumnView), the bookmarks (SlideHost), and a page and paper
    /// outside a card. One inside another moves with it, not again.
    @MainActor static let carriers = NSHashTable<NSView>.weakObjects()

    /// What lands the slide under way, if one is: run at once when another
    /// starts, so each starts from a window laid out where it shows.
    @MainActor private static var landing: (() -> Void)?
    @MainActor private static var slides = 0

    /// Every page and paper in `window` slid `down` points (up, less than
    /// none) on the curve of `pace` by Core Animation, a transform on each
    /// one's layer, and `land` run once they are there, the transforms
    /// taken off and the window laid out for it in the same commit. Nothing
    /// for SwiftUI, AppKit or WebKit while anything moves: the one pass the
    /// change costs comes after the motion, where a long one shows nothing.
    /// For the band with the lights (Browser.moveHead), the page column
    /// carried down whole and back.
    @MainActor static func slide(in window: NSWindow?, down: CGFloat, pace: Pace, land: @escaping () -> Void) {
        landing?()
        guard let window, let root = window.contentView, abs(down) > 0.5 else { return land() }
        slides += 1
        let turn = slides
        var slid: [CALayer] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let here = carriers.allObjects.filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
        let all = Set(here.map(ObjectIdentifier.init))
        func inner(_ view: NSView) -> Bool {
            var up = view.superview
            while let next = up {
                if all.contains(ObjectIdentifier(next)) { return true }
                up = next.superview
            }
            return false
        }
        for view in here where !inner(view) {
            guard let layer = view.layer, let up = view.superview else { continue }
            // The window's y runs up; the layers' need not.
            let origin = view.convert(view.bounds, to: nil).origin
            let from = up.convertToLayer(up.convert(origin, from: nil))
            let to = up.convertToLayer(up.convert(CGPoint(x: origin.x, y: origin.y - down), from: nil))
            let moved = CATransform3DMakeTranslation(to.x - from.x, to.y - from.y, 0)
            layer.transform = moved
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = CATransform3DIdentity
            animation.toValue = moved
            animation.duration = pace.duration
            animation.timingFunction = pace.timing
            layer.add(animation, forKey: "reshape.slide")
            slid.append(layer)
        }
        CATransaction.commit()
        started = CACurrentMediaTime()
        runs += 1
        let done = {
            guard landing != nil else { return }
            landing = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            land()
            root.layoutSubtreeIfNeeded()
            for layer in slid {
                layer.removeAnimation(forKey: "reshape.slide")
                layer.transform = CATransform3DIdentity
            }
            CATransaction.commit()
        }
        landing = done
        DispatchQueue.main.asyncAfter(deadline: .now() + pace.duration + 1.0 / 60) {
            MainActor.assumeIsolated { if slides == turn { done() } }
        }
    }

    /// `layer` drawn `by` away from wherever AppKit puts it, and brought
    /// back. Added to its position rather than replacing it, so it holds
    /// whenever in the pass AppKit gets round to setting that position.
    static func carry(_ layer: CALayer, by offset: CGPoint) {
        started = CACurrentMediaTime()
        let animation = CABasicAnimation(keyPath: "position")
        animation.isAdditive = true
        animation.fromValue = offset
        animation.toValue = CGPoint.zero
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: "reshape.carry")
    }
}


/// The paper under a card on a backdrop: its ground, a shadow short enough
/// to read as paper, and a hairline just outside its edge for a backdrop
/// close to the card's own color. A layer rather than a SwiftUI shape, so
/// that it can change shape with the page (see `Reshape`). Every card has
/// this one paper: a page's, the page under ⌘T's field, the developer
/// tools'.
///
/// None of it is on the card's edge, which has one owner, the card itself
/// (docs/page-corners.md): the ground lies a point inside it, concentric,
/// where the card covers it; the hairline is a ring from the edge outward;
/// the shadow is cut away inside the edge. Two layers cut on one curve
/// multiply their soft pixels, and the one beneath shows through as an arc
/// round every corner, worst in the dark. The band under the address bar
/// keeps clear of the edge too, though it wears the bar's own color.
///
/// Laid out a point bigger than the card on every side, for the hairline.
struct Paper: NSViewRepresentable {
    var corner: CGFloat
    var dark: Bool
    /// The address bar along the page's top, if there is one.
    var band: PaperBand?
    /// The tabs are changing sides: a change of frame is drawn, not jumped.
    var moving: Bool

    func makeNSView(context: Context) -> PaperView { PaperView() }

    func updateNSView(_ view: PaperView, context: Context) {
        view.moving = moving
        view.dress(corner: corner, dark: dark, band: band)
    }
}

/// The address bar over the top of a page: how tall it is and the color
/// it wears, in the light or dark that color is read in.
struct PaperBand: Equatable {
    var height: CGFloat
    var color: NSColor
    var dark: Bool
}

/// SwiftUI drawn in a view of its own, so the band with the lights can
/// slide it with the page by Core Animation (Reshape.slide) rather than
/// SwiftUI stepping it each frame: the bookmarks over the page. Its host
/// keeps the surrounding environment whole, as the card's does
/// (PeekSurface).
struct SlideHost<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> CarriedView { CarriedView() }

    func updateNSView(_ view: CarriedView, context: Context) {
        view.host.rootView = AnyView(content.hosted(in: context.environment).ignoresSafeArea())
    }

    /// As big as it is placed: the content has its own frame.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CarriedView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class CarriedView: NSView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Reshape.carriers.add(self) }
    }
}

final class PaperView: NSView {
    var moving = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Reshape.carriers.add(self) }
    }
    private var corner: CGFloat = 0
    private var dark = false
    private var band: PaperBand?
    /// Where the page's edge was last drawn, in the window's coordinates.
    private var was: CGRect?
    /// And with what corners.
    private var wasCorner: CGFloat = 0

    /// How far in from the card's edge the ground lies, its corners as much
    /// tighter: covered by the card wherever there is one.
    static var groundInset: CGFloat { groundOnEdge ? 0 : 1 }
    /// The old arrangement, the ground on the card's edge, put back by the
    /// bench in a test world (`corners` with `control`) for the pixel check
    /// to show it still catches it.
    static var groundOnEdge = false
    /// How far past the card the shadow can reach, for the cut that keeps it
    /// outside: its blur and its drop with room to spare.
    private static let shadowReach: CGFloat = 24

    /// The ground: under the card, a point in from its edge.
    private let ground = CAShapeLayer()
    /// The shadow, cast by `caster` and cut away inside the card's edge by
    /// `shadowCut`, an even-odd ring: the room round the card, less the card.
    private let shadowRoom = CALayer()
    private let caster = CALayer()
    private let shadowCut = CAShapeLayer()
    /// The hairline, a ring from the card's edge a point outward: its inner
    /// edge the card's own outline, so the two share each soft pixel rather
    /// than both covering it.
    private let edge = CAShapeLayer()
    /// The paper under the address bar, in the bar's own color, with no
    /// ground under it (see `ground(for:corner:)`): what shows in a seam
    /// while the bar and the page move a frame apart. A point in from the
    /// bar's top and sides: the bar's fill alone cuts its corners. On the
    /// edge, even in the bar's color, it made each soft corner pixel
    /// heavier, and it hid the bar cutting its own corners twice (a clip
    /// over its fill on the same curve, gone now).
    private let top = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        edge.fillRule = .evenOdd
        shadowCut.fillRule = .evenOdd
        shadowCut.fillColor = NSColor.black.cgColor
        shadowRoom.mask = shadowCut
        shadowRoom.addSublayer(caster)
        top.strokeColor = nil
        top.fillColor = nil
        // Its color and shape at once, as the bar's are: drawn from black
        // the first time the bar comes, it would show a dark arc a moment.
        top.actions = ["fillColor": NSNull(), "path": NSNull(), "hidden": NSNull()]
        for sublayer in [shadowRoom, ground, top, edge] { layer?.addSublayer(sublayer) }
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func dress(corner: CGFloat, dark: Bool, band: PaperBand?) {
        guard corner != self.corner || dark != self.dark || band != self.band else { return }
        self.corner = corner
        self.dark = dark
        self.band = band
        paint()
        needsLayout = true
    }

    override func updateLayer() {
        paint()
    }

    /// The ground, the hairline and the shadow, set on their layers at once.
    /// Not left to `updateLayer` alone: AppKit need not ask for it before
    /// the path is laid out, and a shape layer with a path and no fill of
    /// its own is filled black, a black card where an empty tab should be.
    private func paint() {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            ground.fillColor = Palette.NS.ground.cgColor
            edge.fillColor = Palette.NS.ink.withAlphaComponent(0.06).cgColor
        }
        if let band {
            (NSAppearance(named: band.dark ? .darkAqua : .aqua) ?? effectiveAppearance).performAsCurrentDrawingAppearance {
                top.fillColor = band.color.cgColor
            }
        }
        top.isHidden = band == nil
        ground.strokeColor = nil
        edge.strokeColor = nil
        caster.shadowColor = NSColor.black.cgColor
        caster.shadowOpacity = dark ? 0.35 : 0.10
        caster.shadowRadius = 5
        // Down a point; this layer's y runs up.
        caster.shadowOffset = CGSize(width: 0, height: -1)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    // MARK: - receding under a Peek

    private var recedes = 0

    /// Under a Peek the whole card is scaled (PeekDepth), and a hairline or
    /// shadow sampled at a fractional scale opens into a rim. They fade out
    /// as the card goes back rather than the card being clipped at its
    /// outline, which would be a second cut on the page's edge, and come
    /// back once it is home.
    func recede(_ on: Bool, animated: Bool) {
        recedes += 1
        let turn = recedes
        let fade = { [weak self] (opacity: Float, duration: CFTimeInterval) in
            guard let self, self.recedes == turn else { return }
            for layer in [self.shadowRoom, self.edge] {
                let from = layer.presentation()?.opacity ?? layer.opacity
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.opacity = opacity
                CATransaction.commit()
                guard duration > 0, from != opacity else { continue }
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = from
                animation.duration = duration
                layer.add(animation, forKey: "peek.opacity")
            }
        }
        if on {
            fade(0, animated ? 0.12 : 0)
        } else if animated {
            // Home first: the card's spring settles within half a second.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { fade(1, 0.15) }
        } else {
            fade(1, 0)
        }
    }

    /// Whether the hairline and shadow are down for a Peek, for the bench.
    var receded: Bool { edge.opacity < 1 }

    // MARK: - laid out

    override func layout() {
        super.layout()
        let now = window.map { _ in convert(bounds, to: nil) }
        // Laid out again in place while room is made (SplitDeck): the
        // preview's outline stands.
        if previewing != nil, now == nil || now == was { return }
        // Laid out where the preview had it: already drawn there.
        var landed = false
        var shown: CGRect?
        if let previewing, let now {
            self.previewing = nil
            landed = abs(now.minX - (previewing.minX - 1)) < 1.5 && abs(now.maxX - (previewing.maxX + 1)) < 1.5
            // Laid out elsewhere: drawn from where the preview showed it.
            if !landed { shown = previewing.insetBy(dx: -1, dy: -1) }
            for (layer, key) in parts { layer.removeAnimation(forKey: "preview." + key) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let room = layer?.bounds ?? bounds
        for sublayer in [shadowRoom, ground, top, edge, caster] { sublayer.frame = room }
        // Layers made here are drawn at 1x unless told otherwise: on a Retina
        // screen the ground's and hairline's soft edges were twice as wide
        // as the page's.
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 1
        for sublayer in [shadowRoom, ground, top, edge, caster, shadowCut] where sublayer.contentsScale != scale {
            sublayer.contentsScale = scale
        }
        // A mask draws nothing past its own bounds: made as large as the
        // shadow can reach, in the paper's own coordinates.
        let reach = room.insetBy(dx: -Self.shadowReach, dy: -Self.shadowReach)
        shadowCut.frame = reach
        shadowCut.bounds = reach
        let next = paths(for: bounds, corner: corner)
        for (layer, key) in parts { set(layer, key, next[key + "@" + name(layer)]) }
        CATransaction.commit()

        guard let now else { return }
        if moving, !landed, let was, was != now || wasCorner != corner {
            // Where it was, in its own coordinates now, with the corners it
            // had then; still on its way there, where it shows. The
            // hairline's outer edge is this view's own.
            var old = convert(shown ?? was, from: nil)
            if shown == nil, edge.animation(forKey: "reshape.path") != nil, let path = edge.presentation()?.path, !path.boundingBox.isEmpty {
                old = convertFromLayer(path.boundingBox)
                    .offsetBy(dx: was.minX - now.minX, dy: was.minY - now.minY)
            }
            let from = paths(for: old, corner: wasCorner)
            for (layer, key) in parts {
                if let path = from[key + "@" + name(layer)] { Reshape.run(key, from: path, on: layer) }
            }
        }
        was = now
        wasCorner = corner
    }

    /// Every path this paper draws, by layer, and the key it is set on.
    private var parts: [(CALayer, String)] {
        [(ground, "path"), (caster, "shadowPath"), (shadowCut, "path"), (edge, "path"), (top, "path")]
    }

    private func name(_ layer: CALayer) -> String {
        layer === ground ? "ground" : layer === caster ? "caster" : layer === shadowCut ? "cut" : layer === edge ? "edge" : "top"
    }

    private func set(_ layer: CALayer, _ key: String, _ path: CGPath?) {
        if key == "shadowPath" { layer.shadowPath = path } else { (layer as? CAShapeLayer)?.path = path }
    }

    /// The paths for the card drawn round `rect`, this view's rectangle (a
    /// point bigger than the card), by "key@layer".
    private func paths(for rect: CGRect, corner: CGFloat) -> [String: CGPath] {
        var found = [
            "path@ground": ground(for: rect, corner: corner),
            "shadowPath@caster": card(for: rect, corner: corner),
            "path@cut": cut(for: rect, corner: corner),
            "path@edge": hairline(for: rect, corner: corner),
        ]
        if let band { found["path@top"] = under(for: rect, corner: corner, height: band.height) }
        return found
    }

    /// Where the card is drawn for now, in the window's coordinates, while
    /// a tab carried over its page asks for room beside it (SplitDeck): the
    /// page's own outline, the card a point out from it. Nil the rest of
    /// the time.
    private(set) var previewing: CGRect?

    /// Room made, or given back with nil, on the curve given.
    func preview(_ rect: CGRect?, duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        guard window != nil, rect != nil || previewing != nil else { return }
        previewing = rect
        // The view is laid out a point bigger than the page all round.
        let target = rect.map { convert($0.insetBy(dx: -1, dy: -1), from: nil) } ?? bounds
        let next = paths(for: target, corner: corner)
        for (layer, key) in parts {
            guard let path = next[key + "@" + name(layer)] else { continue }
            let was: CGPath? = key == "path" ? ((layer as? CAShapeLayer)?.presentation()?.path ?? (layer as? CAShapeLayer)?.path)
                : (layer.presentation()?.shadowPath ?? layer.shadowPath)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            set(layer, key, path)
            CATransaction.commit()
            guard let was, duration > 0 else { continue }
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = was
            animation.duration = duration
            animation.timingFunction = timing
            layer.add(animation, forKey: "preview." + key)
        }
    }

    /// The card, a point in from the view's edge, in the layer's own
    /// coordinates, which need not run the way the view's do. Never quite
    /// square, so that its corners can be drawn going (see
    /// `Reshape.leastCorner`).
    private func card(for rect: CGRect, corner: CGFloat) -> CGPath {
        Reshape.outline(convertToLayer(rect.insetBy(dx: 1, dy: 1)), corner: max(corner, Reshape.leastCorner))
    }

    /// The hairline: a point wide, from the card's edge outward, filled
    /// even-odd between the card's outline and one a point larger, its
    /// corners a point rounder, so all of it lies outside the card.
    private func hairline(for rect: CGRect, corner: CGFloat) -> CGPath {
        let ring = CGMutablePath()
        ring.addPath(Reshape.outline(convertToLayer(rect), corner: max(corner + 1, Reshape.leastCorner)))
        ring.addPath(card(for: rect, corner: corner))
        return ring
    }

    /// What of the shadow is kept: the room round the card, less the card,
    /// even-odd.
    private func cut(for rect: CGRect, corner: CGFloat) -> CGPath {
        let room = CGMutablePath()
        room.addRect(convertToLayer(rect.insetBy(dx: -Self.shadowReach, dy: -Self.shadowReach)))
        room.addPath(card(for: rect, corner: corner))
        return room
    }

    /// The card's top, as tall as the address bar: the card's corners
    /// along it, square ones where the page starts. In the layer's own
    /// coordinates, whichever way they run.
    private func under(for rect: CGRect, corner: CGFloat, height: CGFloat) -> CGPath {
        // A point in along the top and sides, as the ground is from the
        // page's edge: the bar's own fill cuts its corners, alone.
        let card = rect.insetBy(dx: 1, dy: 1)
        let inset = Self.groundInset
        let tall = min(max(height, 0), card.height)
        let band = CGRect(x: card.minX + inset, y: isFlipped ? card.minY + inset : card.maxY - tall,
                          width: max(card.width - 2 * inset, 0), height: max(tall - inset, 0))
        return part(of: band, corner: corner - inset, top: true, height: band.height)
    }

    /// The ground: the card a point in all round, concentric, or with the
    /// address bar over the page what lies below the bar, a point in from
    /// the card's sides and foot. Under the bar's own color its corners
    /// still showed through, a pixel half in the bar being half the bar's
    /// layer and so a quarter the ground.
    private func ground(for rect: CGRect, corner: CGFloat) -> CGPath {
        let card = rect.insetBy(dx: 1, dy: 1)
        let tighter = corner - Self.groundInset
        guard let band else {
            return Reshape.outline(convertToLayer(card.insetBy(dx: Self.groundInset, dy: Self.groundInset)),
                                   corner: max(tighter, Reshape.leastCorner))
        }
        // Below the bar, a point in along the sides and the foot; along the
        // bar the cut stays where it is, the bar's band over it.
        let inset = Self.groundInset
        let tall = min(max(band.height, 0), card.height)
        let below = CGRect(x: card.minX + inset, y: isFlipped ? card.minY + tall : card.minY + inset,
                           width: max(card.width - 2 * inset, 0), height: max(card.height - tall - inset, 0))
        return part(of: below, corner: tighter, top: false, height: 0)
    }

    /// `card` cut across `height` down from its top: the part above, the
    /// card's corners along its top, or the part below, along its foot;
    /// the corners on the cut are square.
    private func part(of card: CGRect, corner: CGFloat, top: Bool, height: CGFloat) -> CGPath {
        let tall = min(max(height, 0), card.height)
        let cut = isFlipped ? card.minY + tall : card.maxY - tall
        let part = top
            ? CGRect(x: card.minX, y: isFlipped ? card.minY : cut, width: card.width, height: tall)
            : CGRect(x: card.minX, y: isFlipped ? cut : card.minY, width: card.width, height: card.height - tall)
        let laid = convertToLayer(part)
        // Which way the layer's y runs decides which of its edges is the cut.
        let up = abs(convertToLayer(card).maxY - convertToLayer(CGRect(x: card.minX, y: isFlipped ? card.minY : card.maxY - 1, width: 1, height: 1)).maxY) < 0.5
        let square: CGRectEdge = (top == up) ? .minYEdge : .maxYEdge
        return Reshape.outline(laid, corner: max(corner, Reshape.leastCorner), square: square)
    }

    // MARK: - for the bench and tests (PageCorners)

    /// The card's outline as drawn, band and page, and the layer whose
    /// coordinates it is in, for the pixel check to find its corners.
    var cardOutline: (path: CGPath, layer: CALayer)? {
        caster.shadowPath.map { ($0, caster) }
    }

    /// Where each part lies against the card's edge: the ground's least
    /// distance inside it in points,
    /// whether the shadow is cut away inside it, and whether the hairline
    /// is a ring outside it rather than a stroke across it.
    var audit: [String: Any] {
        let card = convertToLayer(bounds.insetBy(dx: 1, dy: 1))
        let laid = ground.path?.boundingBox ?? .null
        var inset: CGFloat = 0
        // Under a bar the ground's top is the bar's cut, the bar's height
        // down: never the least.
        if !laid.isNull {
            inset = min(laid.minX - card.minX, card.maxX - laid.maxX, laid.minY - card.minY, card.maxY - laid.maxY)
        }
        return ["groundInset": Double(inset),
                "groundClear": inset >= 0.99,
                "shadowCut": shadowRoom.mask === shadowCut && shadowCut.fillRule == .evenOdd,
                "hairlineOutside": edge.fillRule == .evenOdd && edge.strokeColor == nil,
                "receded": receded, "band": band != nil]
    }
}
