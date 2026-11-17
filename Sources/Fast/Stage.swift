import SwiftUI
import WebKit

/// Everything below the strip: the page, the line that says it is coming, and
/// the sentence that says it never did.
///
/// The tab is watched from here rather than from the window. A tab is a class,
/// so going from blank to loaded changes nothing about the value the window
/// hands down, SwiftUI sees the same reference, re-runs nothing, and the page
/// arrives in WebKit without ever being put on screen. Watching it here is
/// what turns that into a redraw.
struct Page: View {
    @ObservedObject var tab: Tab
    /// Round when the page is a card on a backdrop, square when it is the
    /// window's whole ground.
    var corner: CGFloat = 0
    /// The address bar stands on the card's top edge: only the bottom
    /// corners are the page's to round.
    var flatTop = false
    var holding = false
    /// An animated resize: the held page given the size it shows on the way, see
    /// `StageView.following`.
    var following = false
    /// Held under a hand, the divider between two halves: see
    /// `StageView.tracking`.
    var tracking = false
    /// DevTools' moving room can expose a viewport before its next paint.
    var protectsViewportGrowth = false
    var sidebarPin = 0
    /// Mail's pane stands over the whole page (PageContent).
    var paned = false

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // A tab put down with ⌘W has no view, and asking for one here
        // would build an empty one a frame before the stage moves on.
        let page: NSView? = tab.isBlank || tab.asleep || tab.gone ? nil : tab.page
        // No page out to the card's edge: none, or a device's in the middle
        // of its ground. What lies under the stage is then the card's face,
        // cut at its outline; under a page it keeps a point clear of it.
        let bare = page == nil || tab.device != nil
        // SwiftUI's own, opaque, over the whole card: it owns the edge, and
        // the page under it steps a point in (StageView.covered).
        let covered = paned || tab.failure != nil || tab.untrusted != nil || tab.floating || tab.cover != nil
        ZStack {
            // The card's edge has one owner (docs/page-corners.md): the
            // stage while a page reaches it, else the clip of what SwiftUI
            // draws there. Never both on one edge.
            ZStack {
                // A blank card's face, in the page's light or dark, as the
                // paper under it was.
                if page == nil, !tab.shy, tab.cover == nil {
                    Palette.ground
                        .environment(\.colorScheme, (tab.isBlank ? nil : tab.shade) ?? scheme)
                        .allowsHitTesting(false)
                }
                // A private tab's ground, under whatever the page draws: dark
                // while it is blank or still loading.
                if tab.shy {
                    Hush(since: tab.hushedAt)
                }
                // Device mode: the page stands on a gray ground, smaller than
                // its room (DevDevice.swift).
                if tab.device != nil {
                    DeviceGround()
                }
            }
            .clipShape(PageCut(corner: corner, flatTop: flatTop, inset: bare ? 0 : 1))

            // Cut by its own layer alone, never by a SwiftUI clip: that one
            // lands on the stage's host as a second mask on the same curve.
            WebStage(
                page: page, corner: corner, flatTop: flatTop, covered: covered,
                owner: tab.id, tab: tab, away: tab.floating,
                holding: holding, following: following, tracking: tracking,
                protectsViewportGrowth: protectsViewportGrowth,
                sidebarPin: sidebarPin,
                shade: tab.shade, tone: tab.tone, device: tab.device
            )

            overlays
                // What SwiftUI draws over the page is clipped here, apart
                // from the stage. Not while the page is held: the clip is
                // at the new outline, and what is carried from the old one
                // would be cut there, its edge jumping home while it moved.
                .clipShape(holding ? AnyShape(Rectangle().inset(by: -400)) : AnyShape(PageCut(corner: corner, flatTop: flatTop, inset: 0)))
        }
        // The curves under it are for one tab's page failing, coming back
        // or going out to the little window. Another tab picked here is not
        // that: a failed page left for one that isn't changed `failure`, and
        // the new page, its stage a band taller or shorter (Developer
        // Mode's), slid there on Motion.quick instead of being in place.
        .transaction(value: tab.id) { $0.animation = nil }
        .animation(Motion.quick, value: tab.failure)
        .animation(Motion.quick, value: tab.untrusted)
        .animation(Motion.quick, value: tab.floating)
        .animation(.easeOut(duration: 0.2), value: tab.cover == nil)
    }

    @ViewBuilder
    private var overlays: some View {
        ZStack {
            if let device = tab.device {
                GeometryReader { room in
                    DeviceHandles(tab: tab, device: device, room: room.size)
                    DeviceBar(tab: tab, device: device, room: room.size)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }

            if let cover = tab.cover {
                // The page as it was left, while it is rebuilt underneath,
                // anchored where the page itself starts, and never in the
                // way of a click meant for the page.
                Image(nsImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if tab.floating {
                // The tab is not empty, its page is simply elsewhere. Saying so
                // is kinder than a white rectangle.
                AwayPlacard(call: tab.onCall)
                    .transition(.opacity)
            }

            if let failure = tab.failure {
                Trouble(message: failure) { tab.reload() }
                    .transition(.opacity)
            }

            if let untrusted = tab.untrusted {
                UntrustedPage(tab: tab, untrusted: untrusted)
                    .transition(.opacity)
            }

            if let flagged = tab.flagged {
                FlaggedPage(tab: tab, flagged: flagged)
                    .transition(.opacity)
            }

            // A PDF's Fill & Sign: its plate, and the mode over the page
            // once it is pressed (PDFDeskView.swift).
            if tab.failure == nil, tab.untrusted == nil, !tab.floating {
                PDFLayer(paper: tab.paper, tab: tab, corner: corner, flatTop: flatTop)
            }

            // The swipe's pill, drawn by Core Animation in a view of its
            // own and handed each move of the fingers directly, never
            // through this view's body.
            PullHost(tab: tab)
        }
    }
}

/// The page card's outline in SwiftUI, for what SwiftUI draws on the card:
/// the same continuous corners as the stage's mask (`Reshape.outline`),
/// square along the top under the address bar, or a point in, concentric,
/// for what lies under a page and must keep clear of its edge.
struct PageCut: Shape {
    var corner: CGFloat
    var flatTop = false
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        // Square corners are cut on whole pixels: nothing to keep clear of.
        let inset = corner > 0 ? inset : 0
        let round = max(corner - inset, 0)
        return UnevenRoundedRectangle(
            topLeadingRadius: flatTop ? 0 : round, bottomLeadingRadius: round,
            bottomTrailingRadius: round, topTrailingRadius: flatTop ? 0 : round,
            style: .continuous
        ).path(in: rect.insetBy(dx: inset, dy: inset))
    }
}

/// The one place a page is allowed to be. Tabs hand their web view over when
/// they become the live one and get it back untouched when they don't, no
/// reload, no lost scroll position, no forgotten form.
struct WebStage: NSViewRepresentable {
    let page: NSView?
    var corner: CGFloat = 0
    var flatTop = false
    /// SwiftUI's own cover owns the card's edge: see `StageView.covered`.
    var covered = false
    /// Whose page it is. A new owner is a new tab picked, and only that
    /// turns; the same tab going from blank to loaded does not.
    var owner: Tab.ID?
    /// A live ownership reference: an old SwiftUI value can outlive a
    /// window transfer, but this tab's delegate changes at the handoff.
    var tab: Tab?
    /// The page is out in the little window. Passed down, rather than the page
    /// being passed as nil, so that its coming home is a change SwiftUI can
    /// see: the page alone is the same reference before and after, and the
    /// stage was never told to take it back.
    var away = false
    /// The tabs are changing sides: see `StageView.hold`.
    var holding = false
    var following = false
    var tracking = false
    var protectsViewportGrowth = false
    var sidebarPin = 0
    /// Whether the page is light or dark as drawn, and the color of its
    /// top, as sampled: for what shows where a held page falls short of its
    /// outline (see `StageView.fill`).
    var shade: ColorScheme?
    var tone: NSColor?
    /// Device mode: the page at this device's size (DevDevice.swift).
    var device: DeviceMode?

    func makeNSView(context: Context) -> StageView {
        let stage = StageView()
        // The stage sets its page's frame itself, in `settle`. A page back
        // from the floating window, or from the bench's room, still carries
        // the mask it was given there, and AppKit would stretch it to every
        // size the stage passes through, a whole layout in WebKit each time,
        // before `settle` ever got a say.
        stage.autoresizesSubviews = false
        return stage
    }

    /// The page fills its stage. Letting AppKit measure it walks the web
    /// view's constraints during split and tab layout, even though none
    /// of the page's content determines the browser's size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ view: StageView, context: Context) {
        view.round(corner, flatTop: flatTop, covered: covered)
        view.shade = shade
        view.tone = tone
        view.following = following
        view.sidebarPin = sidebarPin
        view.hold(holding)
        view.tracking = tracking
        view.protectsViewportGrowth = protectsViewportGrowth
        view.away = away
        view.device = device
        // A switch whose page went on this stage ahead of SwiftUI (Browser's
        // DEFER_SWITCH): until it is written, an update for the tab still
        // in front doesn't take the stage back from it.
        if let held = view.heldFor, owner != held { return }
        view.show(page, of: owner, tab: tab)
    }
}

final class StageView: NSView {
    // NSView removes its children from super.dealloc, after Swift has
    // begun destroying this stage. Those callbacks must not create weak
    // references to self or schedule another page/fullscreen transition.
    private var tearingDown = false
    isolated deinit { tearingDown = true }
    /// The tab a switch put on this stage ahead of SwiftUI, until the switch
    /// is written (Browser.select).
    var heldFor: Tab.ID?
    override func hitTest(_ point: NSPoint) -> NSView? {
        // The tab is already selected while its previous surface is still
        // visible. Those coordinates cannot safely target either document.
        if awaitingPaint != nil, !isHiddenOrHasHiddenAncestor,
           bounds.contains(convert(point, from: superview)) { return self }
        return super.hitTest(point)
    }

    /// The page's corners, cut by the stage's own layer: a web view draws
    /// in a layer of its own that a SwiftUI clip never reaches.
    ///
    /// The stage is the one owner of the card's rounded edge, in every
    /// state (docs/page-corners.md): its corner radius at rest, turning and
    /// under a Peek, its mask on `Reshape.outline`'s curve while held or
    /// making room, never both. Either cuts the page and everything under
    /// it in the stage once, as one picture; anything else cut on the same
    /// edge, a clip round the stage or a ground beneath it, multiplied its
    /// soft pixels with the page's and showed through as an arc, worst on
    /// a dark page.
    func round(_ corner: CGFloat, flatTop: Bool = false, covered: Bool = false) {
        wantsLayer = true
        guard corner != self.corner || flatTop != self.flatTop || covered != self.covered else { return }
        self.corner = corner
        self.flatTop = flatTop
        self.covered = covered
        edge()
    }

    /// The card's corner radius, drawn by the mask (`edge`).
    private(set) var corner: CGFloat = 0
    /// The top corners are square: the address bar's are the card's.
    private var flatTop = false
    /// Something of SwiftUI's, opaque and over the whole card, owns the
    /// edge: Mail, a page that never came, an untrusted site. The page
    /// under it steps a point in, so the two are never cut on one curve.
    private var covered = false

    /// The one cut of the card's edge: the corner radius at rest, a mask
    /// while the page is held or under SwiftUI's own cover, nothing but the
    /// stage's own rectangle edge to edge. Set at once; a change of shape
    /// is drawn by `reshape` and `preview` on the mask.
    private func edge() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // At rest, Core Animation's own corner: measured in its renderer, a
        // shape mask on a page whose tiles change every frame cost about
        // twice the render time of a clipping corner radius (0.63 against
        // 0.29 to 0.33 ms a 2880 by 1800 frame), on every frame of every
        // scroll. Its curve is a hair off `Reshape.outline`'s, so nothing
        // else is cut on it: the paper keeps clear (a ground a point in, a
        // hairline and shadow outside) and SwiftUI clips nothing on the
        // stage. The mask is only for a page held or making room, whose
        // outline Core Animation draws from one shape to another.
        if held == nil, previewing == nil, corner > 0, !covered {
            if layer.mask != nil { layer.mask = nil }
            drawn = nil
            if clipsToBounds { clipsToBounds = false }
            layer.cornerRadius = corner
            layer.cornerCurve = .continuous
            layer.maskedCorners = flatTop ? bottomCorners : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            if !layer.masksToBounds { layer.masksToBounds = true }
            return
        }
        if layer.cornerRadius != 0 { layer.cornerRadius = 0 }
        guard corner > 0 || held != nil else {
            if layer.mask != nil { layer.mask = nil }
            // Square, edge to edge: a page turning in is cut at the stage's
            // own rectangle, whole pixels, never antialiased.
            if !clipsToBounds { clipsToBounds = true }
            if !layer.masksToBounds { layer.masksToBounds = true }
            return
        }
        if clipsToBounds { clipsToBounds = false }
        if layer.masksToBounds { layer.masksToBounds = false }
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        if layer.mask !== mask {
            layer.mask = mask
            drawn = nil
        }
        // A layer made here is drawn at 1x unless told otherwise: on a Retina
        // screen its soft edge was twice as wide as the page's own.
        let scale = window?.backingScaleFactor ?? layer.contentsScale
        if mask.contentsScale != scale { mask.contentsScale = scale }
        // A shape changing is the animations' to draw, and a preview's
        // outline stands until it is let go.
        guard mask.animation(forKey: "reshape.path") == nil, mask.animation(forKey: "preview.path") == nil,
              previewing == nil else { return StageView.spread(mask, over: layer.bounds) }
        // The stage lays out on every frame of a slide: the same outline is
        // not handed to the render server again.
        let now = Drawn(bounds: layer.bounds, corner: corner, flatTop: flatTop, covered: covered && held == nil)
        guard now != drawn || mask.path == nil else { return }
        StageView.spread(mask, over: layer.bounds)
        mask.path = rest(bounds)
        drawn = now
    }

    /// What the mask's outline at rest was last drawn for.
    private struct Drawn: Equatable {
        var bounds: CGRect
        var corner: CGFloat
        var flatTop: Bool
        var covered: Bool
    }
    private var drawn: Drawn?

    /// The outline at rest: the card's, or a point in where SwiftUI's own
    /// cover owns the edge.
    private func rest(_ rect: CGRect) -> CGPath {
        guard covered, held == nil, corner > 0 else { return outline(rect) }
        return outline(rect.insetBy(dx: 1, dy: 1), corner: max(corner - 1, Reshape.leastCorner))
    }

    /// For the bench and tests (PageCorners): the layer cutting the edge,
    /// and the states that decide where it lies.
    var cuttingMask: CAShapeLayer? { layer?.mask as? CAShapeLayer }
    var isHeld: Bool { held != nil }
    var isCovered: Bool { covered }

    /// The layer's edge the page's top is on. Which way the layer's y runs
    /// is AppKit's business, so it is asked rather than assumed.
    private var topEdge: CGRectEdge {
        // A step up the screen, in the view's coordinates and then in the
        // layer's: no size needed, so it holds before the first layout.
        let here = convertToLayer(NSPoint.zero).y
        let up = convertToLayer(NSPoint(x: 0, y: isFlipped ? -1 : 1)).y
        return up > here ? .maxYEdge : .minYEdge
    }

    private var bottomCorners: CACornerMask {
        topEdge == .maxYEdge
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }

    /// The page's outline, in the layer's coordinates, as its corners are,
    /// or were: the mask's, which moves (see `Reshape.leastCorner`).
    private func outline(_ rect: CGRect, corner: CGFloat? = nil) -> CGPath {
        let corner = max(corner ?? self.corner, Reshape.leastCorner)
        return Reshape.outline(convertToLayer(rect), corner: corner, square: flatTop ? topEdge : nil)
    }

    /// The corners the page had when it was last laid out, for a mask that
    /// goes from those to the ones it has now: a card going edge to edge.
    private var wasCorner: CGFloat = 0

    // MARK: - held while the tabs change sides

    /// The page's size, kept for as long as the tabs are changing sides.
    /// Nil the rest of the time.
    ///
    /// Made another size, a web view lays the whole page out again, in
    /// WebKit, and until WebKit has drawn it anew the view shows what it
    /// had, in the wrong place, or nothing, black. Animated by SwiftUI the
    /// stage was made another size on every frame of the move: some
    /// thirty-five layouts for one ⇧⌘S, each a frame WebKit could be late
    /// for.
    ///
    /// So for the move the page keeps the size it had and is only carried:
    /// its top left corner goes with the stage's, the way the page's own
    /// content would, and the stage cuts it to its new outline. Both drawn
    /// by Core Animation, from where they were to where they are, in the
    /// render server (see `Reshape`), the stage itself takes its new frame
    /// at once. Where the page, at the size it had, falls short of the new
    /// outline, the page's own under-page color shows. Once nothing is
    /// moving, it is given its new size and laid out, once.
    private var held: CGSize?
    /// The height the stage was last settled at, for the page stepping off.
    private var laidHeight: CGFloat = 0
    /// Where the stage was last laid out, in the window's coordinates.
    private var was: CGRect?

    /// Held while a hand moves the divider between two halves: the outline
    /// and the page follow the hand frame by frame as they are laid out,
    /// with nothing drawn from where they were. Drawn over the fraction of
    /// a second a change of shape takes, each move started a curve of its
    /// own, and the edge trailed the hand.
    var tracking = false
    var protectsViewportGrowth = false
    /// Device mode: the page at the device's size, in the middle of the
    /// stage under the bar, drawn at the scale that fits (DevDevice.swift).
    var device: DeviceMode? {
        didSet { if device != oldValue { needsLayout = true } }
    }
    /// The scale the page was last given, told to WebKit only when it
    /// changes: the stage lays out on every frame of a slide.
    private var scaled: CGFloat = 1
    private weak var scaledPage: WKWebView?
    /// See `WebStage.shade`.
    var shade: ColorScheme?
    var tone: NSColor?

    /// Held as SwiftUI asks (`holding`); a preview holds the page as well,
    /// and it is let go only when neither wants it.
    private var asked = false

    func hold(_ on: Bool) {
        if on != asked { note("hold", ["on": on]) }
        asked = on
        if !on, trackingPreview {
            // A divider can return to its original share, so no changed
            // frame calls landPreview. SwiftUI assigns tracking and the
            // final frame after this hold; finish in the following pass.
            // SplitDeck's previews have their own owner and stay up.
            let turn = previews
            DispatchQueue.main.async { [weak self] in
                guard let self, self.previews == turn, !self.asked, !self.tracking,
                      self.trackingPreview, self.previewing != nil else { return }
                self.preview(nil, duration: 0, timing: CAMediaTimingFunction(name: .linear))
            }
        }
        grip(on || previewing != nil)
    }

    private func grip(_ on: Bool) {
        guard on else {
            guard held != nil else { return }
            if follower?.native == true {
                // SwiftUI may update this hold before assigning the last
                // frame of a dragged divider. Read that frame after the
                // update pass, even when the preceding width has painted.
                let turn = followTurn
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.followTurn == turn, !self.asked,
                          self.previewing == nil, self.follower?.native == true else { return }
                    self.follower?.to = self.bounds
                    self.follower?.finishing = true
                    self.geometryStep(at: CACurrentMediaTime())
                }
                // A heavy page (x.com) takes most of a second to draw each
                // width, and the last one was waited for a width at a time:
                // the chat column gone and the page held at its old width
                // for seconds, an empty strip where the column was. The
                // motion over, the page is let go at its final size soon
                // after; what WebKit has not drawn yet stays covered.
                DispatchQueue.main.asyncAfter(deadline: .now() + StageView.longestStep) { [weak self] in
                    guard let self, self.followTurn == turn, !self.asked, self.previewing == nil,
                          let step = self.follower, step.native, step.finishing, step.asked != nil else { return }
                    self.note("sidebar-final-timeout")
                    self.releaseGrip()
                }
            } else {
                releaseGrip()
            }
            return
        }
        // A new gesture can resume while the last painted size of the
        // previous one is still in flight. Its owner still holds the page.
        if follower?.native == true { follower?.finishing = false }
        guard held == nil, window != nil else { return }
        held = bounds.size
        wantsLayer = true
        guard let layer else { return }
        // What lies past the stage's edges while it is held is the strip's
        // or the column's, never the page's: the same mask as at rest, made
        // larger than the stage all round (`spread`), so a page carried
        // from where it was is cut at its outline and nowhere else. AppKit's
        // own clip of the view to its bounds is off for the same reason.
        edge()
        if let mask = layer.mask as? CAShapeLayer, mask.animation(forKey: "reshape.path") == nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.path = outline(bounds)
            drawn = nil
            CATransaction.commit()
        }
        layer.backgroundColor = StageView.fill(under: (wanted as? WKWebView)?.underPageBackgroundColor, shade: shade, tone: tone).cgColor
    }

    private func releaseGrip() {
        stopFollowing()
        held = nil
        if let mask = layer?.mask {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.removeAnimation(forKey: "reshape.path")
            mask.removeAnimation(forKey: "preview.path")
            CATransaction.commit()
        }
        layer?.backgroundColor = nil
        edge()
        needsLayout = true
    }

    // MARK: - room made for a tab carried over the page (SplitDeck)

    /// Where the page is drawn for now, in the window's coordinates, while a
    /// tab carried over it asks for room beside it: held, cut to this
    /// outline and carried there, its top left corner with the outline's,
    /// by Core Animation alone. Nothing is laid out and WebKit is not asked
    /// for another size. Nil the rest of the time.
    private(set) var previewing: CGRect?
    private var previews = 0
    private var trackingPreview = false
    /// How far the held page is moved from the stage's top left for the
    /// room a preview made, in this view's coordinates.
    private var shifted: CGPoint = .zero

    /// Room made, or given back with nil, on the curve given.
    func preview(_ rect: CGRect?, duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        guard window != nil, rect != nil || previewing != nil else { return }
        if rect != nil {
            previewing = rect
            grip(true)
        }
        previews += 1
        let turn = previews
        guard let layer, let mask = layer.mask as? CAShapeLayer else { return }
        let target = rect.map { convert($0, from: nil) } ?? bounds
        let wasPath = mask.presentation()?.path ?? mask.path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.path = outline(target)
        drawn = nil
        CATransaction.commit()
        // Nothing drawn between with no time to draw it in: a hand moving
        // it sets it, once a move.
        if let wasPath, duration > 0 {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = wasPath
            animation.duration = duration
            animation.timingFunction = timing
            mask.add(animation, forKey: "preview.path")
        }
        // SplitRule moves an outline without relaying out SwiftUI. Feed
        // that target to the same viewport coordinator as a normal drag,
        // rather than resizing WebKit later from a separate timer. A
        // Chromium page too: left to the carry below, its half grew empty
        // beside it until the divider was let go (feedback #1900).
        if device == nil, Self.geometryFollowing, Self.follows,
           tracking || trackingPreview, let web = wanted, web is WKWebView || web is ChromiumPage {
            trackingPreview = rect != nil
            shifted = .zero
            follow(from: web.frame, to: target, duration: duration)
            if rect == nil {
                previewing = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                    guard let self, self.previews == turn, self.previewing == nil else { return }
                    self.grip(self.asked)
                }
            }
            return
        }
        // The page's top left corner to the outline's: its frame moved,
        // never its size, so WebKit lays nothing out, and drawn there from
        // where it was, added to wherever AppKit puts it (see Reshape.carry).
        let next = CGPoint(x: target.minX - bounds.minX, y: target.maxY - bounds.maxY)
        let before = shifted
        shifted = next
        // Given back: the page its whole size again at once, under an
        // outline still growing to it, rather than narrow inside it.
        if rect == nil, held != nil, held != bounds.size, let web = wanted as? WKWebView {
            held = bounds.size
            StageView.resizes += 1
            web.frame = CGRect(x: shifted.x, y: shifted.y, width: bounds.width, height: bounds.height)
        }
        settle()
        if let page = wanted?.layer, before != next, duration > 0 {
            let was = convertToLayer(NSPoint(x: before.x, y: before.y))
            let now = convertToLayer(NSPoint(x: next.x, y: next.y))
            let zero = convertToLayer(NSPoint.zero)
            let carry = CABasicAnimation(keyPath: "position")
            carry.isAdditive = true
            carry.fromValue = CGPoint(x: (was.x - zero.x) - (now.x - zero.x), y: (was.y - zero.y) - (now.y - zero.y))
            carry.toValue = CGPoint.zero
            carry.duration = duration
            carry.timingFunction = timing
            page.add(carry, forKey: "preview.carry")
        }
        if let rect {
            // There: the page laid out once at the width it shows, as Arc
            // does, still held, so letting go has nothing left to do.
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 1.0 / 60) { [weak self] in
                guard let self, self.previews == turn, self.previewing == rect, self.window != nil,
                      let web = self.wanted as? WKWebView else { return }
                let size = self.convert(rect, from: nil).size
                guard self.held != size else { return }
                self.held = size
                StageView.resizes += 1
                web.frame = CGRect(x: self.shifted.x, y: self.bounds.height - size.height + self.shifted.y,
                                   width: size.width, height: size.height)
            }
            return
        }
        previewing = nil
        // Given back: let go once it is home, unless held for something else
        // or another preview has started since.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.previews == turn, self.previewing == nil else { return }
            self.grip(self.asked)
        }
    }

    /// Laid out where the preview had it: the room it made is the room it
    /// now has, so the mask and the page are put there as they are, with
    /// nothing drawn from the old frame. True when that is what happened.
    private func landPreview(from old: CGRect?) -> (landed: Bool, shown: CGRect?) {
        guard let previewing, let old, old != bounds, let layer else { return (false, nil) }
        self.previewing = nil
        if trackingPreview {
            trackingPreview = false
            follower?.to = bounds
        }
        previews += 1
        let now = convert(bounds, to: nil)
        shifted = .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wanted?.layer?.removeAnimation(forKey: "preview.carry")
        (layer.mask as? CAShapeLayer)?.removeAnimation(forKey: "preview.path")
        CATransaction.commit()
        grip(asked)
        let landed = abs(now.minX - previewing.minX) < 1.5 && abs(now.maxX - previewing.maxX) < 1.5
            && abs(now.minY - previewing.minY) < 1.5 && abs(now.maxY - previewing.maxY) < 1.5
        // Laid out somewhere else, a band put over it: drawn there from where
        // the preview showed it, not from the frame it had before.
        return (landed, landed ? nil : convert(previewing, from: nil))
    }

    /// Where the held page's outline is drawn now, in this view's
    /// coordinates as they were when it was last laid out, while a change
    /// of shape is still drawing it there; nil when nothing is moving.
    private func seen() -> CGRect? {
        guard let mask = layer?.mask as? CAShapeLayer, mask.animation(forKey: "reshape.path") != nil,
              let path = mask.presentation()?.path else { return nil }
        let box = convertFromLayer(path.boundingBox)
        return box.isEmpty ? nil : box
    }

    /// A mask draws nothing past its own bounds: laid over the stage's alone,
    /// it cut a page still carried from a taller outline at the new edge,
    /// and the edge jumped there while the page moved. So it is made larger
    /// than the stage all round, its coordinates kept the stage's own.
    private static func spread(_ mask: CALayer, over bounds: CGRect) {
        let room = bounds.insetBy(dx: -400, dy: -400)
        mask.frame = room
        mask.bounds = room
    }

    /// The stage has its new frame, having last been at `old`, in its own
    /// coordinates now. Held, the mask's outline is drawn there from the
    /// old one, by Core Animation.
    private func reshape(from old: CGRect?, corner: CGFloat, landed: Bool = false) {
        // At rest the outline is simply where the stage is: nothing is
        // carried, so nothing is drawn from where it was.
        guard held != nil else { return edge() }
        guard let layer, let mask = layer.mask as? CAShapeLayer else { return }
        // Laid out again in place while room is made: the preview's outline
        // stands.
        if previewing != nil, old == nil || old == bounds { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        StageView.spread(mask, over: layer.bounds)
        mask.path = outline(bounds)
        drawn = nil
        CATransaction.commit()
        // DevTools' final viewport can still be painting after SwiftUI has
        // finished tracking. Keep that latched follower's mask at its target.
        let nativeTracking = follower?.native == true && follower?.protectsGrowth == true
        guard let old, old != bounds, !tracking, !nativeTracking, !landed else { return }
        Reshape.run("path", from: outline(old, corner: corner), on: mask)
    }

    /// What this stage has been told to show, and the only thing it keeps.
    ///
    /// It used to track that *and* what it was holding, and reconcile the two.
    /// One divergence between them, a page taken by the floating window, a tab
    /// closed at the wrong moment, an update that arrived out of order, and
    /// the stage would sit there holding nothing while believing it held
    /// something. That is the white page, and it came back every time from a
    /// different direction because the bookkeeping had many ways to slip.
    ///
    /// Now there is one fact and one rule: show `wanted`, and put that right on
    /// every layout. Nothing to fall out of step with.
    private weak var wanted: NSView?
    private weak var claimant: Tab?
    /// Keep the host scope through detach/close, when the registry may
    /// already have retired its window but SwiftUI can still update us.
    private var hostWindowID: UUID?
    /// `wanted` is in the little window, on purpose. Left to itself the
    /// stage would take it back on its next layout, from under a window
    /// still showing it.
    var away = false {
        didSet {
            guard away else { return }
            cancelPaintWait()
        }
    }
    /// The page of the tab just left, kept under the new one for the moment
    /// the new one takes to come in, so there is never a frame of nothing
    /// between two pages. Gone the moment that is over.
    private weak var leaving: NSView?
    /// A page attached at its final size, still transparent until WebKit
    /// presents it. The departing surface stays visible during that wait.
    private weak var awaitingPaint: WKWebView?
    /// A freshly woken page has no document yet. Its first presentation
    /// can be just WebKit's empty backing, so wait for navigation commit
    /// before asking for the presentation that releases the old page.
    private var firstDocument: (() -> Void)?
    /// How long the departing page may stand in for one that hasn't painted.
    /// A load stopped before its document, a link that turned into a
    /// download or a page that never paints would otherwise leave another
    /// tab's page in its place for as long as it is picked.
    static let paintWait: TimeInterval = 1
    private var pageTurns = 0

    /// Back or Forward to a page whose last frame was kept: shown at once,
    /// over the page, until the page has drawn after its commit, 0.6 s at
    /// most (Browser's decidePolicyFor, BACK_STILLS).
    func coverForHistory(_ still: PageStills.Still, page web: WKWebView) {
        guard web === wanted, web.superview === self, still.key.size.width > 0,
              abs(still.key.size.width - bounds.width) < 0.5, abs(still.key.size.height - bounds.height) < 0.5,
              self.still == nil, awaitingPaint == nil else {
            Self.mark("cover", ["kept": true, "up": false])
            return
        }
        Self.mark("cover", ["kept": true, "up": true])
        stillSince = CACurrentMediaTime()
        putStill(still)
        CATransaction.flush()
        historyCover = web
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak web] in
            guard let self, let web, self.historyCover === web else { return }
            self.historyCover = nil
            self.liftStill(to: web, painted: false)
        }
    }
    private weak var historyCover: WKWebView?

    /// The navigation under a history cover ended without a commit.
    func uncoverHistory() {
        guard let web = historyCover else { return }
        historyCover = nil
        liftStill(to: web, painted: false)
    }

    func documentCommitted(_ web: WKWebView) {
        if web === historyCover {
            Self.afterNextDrawing(web, requirePaint: true) { [weak self, weak web] in
                guard let self, let web, self.historyCover === web else { return }
                self.historyCover = nil
                self.liftStill(to: web, painted: true)
            }
        }
        // A new document on the stage: pictured once it has had a moment
        // to draw itself (`refresh`).
        if web === wanted, awaitingPaint == nil { moved(after: 1.5) }
        if web === unseenPage, let back = seenBack {
            seenBack = nil
            Self.afterNextDrawing(web, requirePaint: true, back)
        }
        if web === bareGround, let back = groundBack {
            groundBack = nil
            Self.afterNextDrawing(web, requirePaint: true, back)
        }
        guard awaitingPaint === web, let ready = firstDocument else { return }
        firstDocument = nil
        Self.afterNextDrawing(web, requirePaint: true, ready)
    }

    /// A page that `groundless` stopped from drawing WebKit's own ground,
    /// and what gives it back once the page has drawn.
    private weak var bareGround: WKWebView?
    private var groundBack: (() -> Void)?

    /// The first page of a stage with nothing to stand in for it draws no
    /// ground of WebKit's until its first document has drawn: that ground
    /// is white, a dark site's too, for as long as its stylesheets take.
    /// The stage's own ground shows instead; the page's, once it has
    /// drawn, or after `groundWait` all the same. Longer than `paintWait`:
    /// a page with no ground yet shows nothing wrong, only the stage's, and
    /// given back early on a slow load the white came back with it.
    static let groundWait: TimeInterval = 5
    private func groundless(_ web: WKWebView) {
        web.setValue(false, forKey: "drawsBackground")
        bareGround = web
        let back = { [weak self, weak web] in
            guard let self, let web, self.bareGround === web else { return }
            self.giveGroundBack()
        }
        if web.isLoading || web.url == nil {
            groundBack = back
        } else {
            Self.afterNextDrawing(web, requirePaint: true, back)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.groundWait, execute: back)
    }

    /// A page shown before it had drawn, kept unseen until it has: its
    /// layer at no opacity, given back on its first drawing after its
    /// document, or after `groundWait` all the same. Never left unseen
    /// once another page is wanted (`show`).
    private weak var unseenPage: WKWebView?
    private var seenBack: (() -> Void)?

    private func unseen(_ web: WKWebView, committed: Bool) {
        unseenPage = web
        note("unseen-until-drawn", ["committed": committed])
        // Nothing lies under a page on the card (Page): the stage's own
        // ground, in Yab's light or dark. Not the tab's `shade`: sampled
        // from this very page, not drawn yet, it says light.
        var ground = Palette.NS.ground.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { ground = Palette.NS.ground.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = ground
        CATransaction.commit()
        let back = { [weak self, weak web] in
            guard let self, let web, self.unseenPage === web else { return }
            self.giveSightBack()
        }
        if committed {
            Self.afterNextDrawing(web, requirePaint: true, back)
        } else {
            seenBack = back
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.groundWait, execute: back)
    }

    private func giveSightBack() {
        seenBack = nil
        guard let web = unseenPage else { return }
        unseenPage = nil
        note("seen", [:])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        web.layer?.opacity = 1
        if held == nil { layer?.backgroundColor = nil }
        CATransaction.commit()
    }

    private func giveGroundBack() {
        groundBack = nil
        guard let web = bareGround else { return }
        bareGround = nil
        web.setValue(true, forKey: "drawsBackground")
    }

    private func cancelPaintWait() {
        giveSightBack()
        firstDocument = nil
        guard let web = awaitingPaint else { return liftStill(to: nil, painted: false) }
        pageTurns += 1
        awaitingPaint = nil
        leaving = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        web.layer?.opacity = 1
        liftStill(to: nil, painted: false)
        CATransaction.commit()
    }

    // MARK: - the page's last frame, until it draws (PageStills)

    /// The still standing in for the page coming in, and the layer showing
    /// it, over the page and the one leaving, under the veils, cut by this
    /// stage's own edge like everything in it. A layer, never a view: a
    /// click can't land on it, nor Accessibility read it; the stage takes
    /// clicks itself while it is up (`hitTest`), as while the page left
    /// stood in.
    private var still: PageStills.Still?
    private var stillLayer: CALayer?
    private var stillSince: CFTimeInterval = 0

    /// Whether the stage shows a still now, for tests and the bench.
    var showsStill: Bool { still != nil }

    /// A still of `owner`'s page drawn for exactly how it would be shown
    /// here now, or nil. Never for a page held, made room for, shown as a
    /// device, lent away, full screen or beside its inspector: each shows
    /// the page at another size than the stage's.
    private func stillFor(_ web: NSView, of owner: Tab.ID?) -> PageStills.Still? {
        guard let owner, let key = stillKey(web) else { return nil }
        return PageStills.shared.still(for: owner, matching: key)
    }

    private func stillKey(_ view: NSView) -> PageStills.Key? {
        if let page = view as? ChromiumPage {
            guard PageStills.on, window != nil, held == nil, previewing == nil,
                  device == nil, !away, !page.media.fullscreen, !inspecting else { return nil }
            return PageStills.key(page, on: self)
        }
        guard let web = view as? WKWebView else { return nil }
        guard PageStills.on, web is PageView, window != nil, held == nil, previewing == nil,
              device == nil, !away, web.fullscreenState == .notInFullscreen, !inspecting else { return nil }
        return PageStills.key(web, on: self)
    }

    private func putStill(_ still: PageStills.Still) {
        guard let layer else { return }
        let shown = stillLayer ?? CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let was = self.still, was !== still { PageStills.shared.hidden(was) }
        if self.still !== still { PageStills.shared.shown(still) }
        self.still = still
        shown.removeAllAnimations()
        shown.contents = still.surface
        // A halved still is drawn up to the page's size.
        shown.contentsGravity = .resize
        shown.minificationFilter = .linear
        shown.magnificationFilter = .linear
        shown.isOpaque = true
        shown.opacity = 1
        shown.zPosition = 5
        // Its top left corner on the page's, this view's y running up.
        let size = still.key.size
        shown.frame = convertToLayer(CGRect(x: 0, y: bounds.height - size.height, width: size.width, height: size.height))
        if shown.superlayer !== layer { layer.addSublayer(shown) }
        CATransaction.commit()
        stillLayer = shown
        stillSince = CACurrentMediaTime()
        note("still", ["owner": String(still.owner.uuidString.prefix(8)).lowercased(), "reduced": still.reduced])
    }

    /// The still down, the live page in its place.
    private func liftStill(to web: WKWebView?, painted: Bool) {
        guard let still else { return }
        self.still = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let shown = stillLayer {
            shown.removeAllAnimations()
            shown.removeFromSuperlayer()
            shown.contents = nil
        }
        CATransaction.commit()
        PageStills.shared.hidden(still)
        note("live", ["painted": painted, "ms": ((CACurrentMediaTime() - stillSince) * 10000).rounded() / 10])
    }

    /// The page on show, pictured as it is now for coming back to it, when
    /// it is shown at this stage's size and nothing stands in for it.
    private func picture(_ web: WKWebView, of owner: Tab.ID) {
        guard PageStills.on, let page = web as? PageView, page.superview === self, window != nil, held == nil,
              previewing == nil, device == nil, !away, page.fullscreenState == .notInFullscreen,
              abs(page.frame.width - bounds.width) < 0.5, abs(page.frame.height - bounds.height) < 0.5,
              !inspecting else { return }
        let key = PageStills.key(page, on: self)
        // Asked of the page's own process after this pass: nothing of it
        // is waited for here.
        let shy = !page.configuration.websiteDataStore.isPersistent
        DispatchQueue.main.async {
            PageStills.shared.take(page, owner: owner, key: key, shy: shy)
        }
    }

    private func picture(_ page: ChromiumPage, of owner: Tab.ID) {
        guard let key = stillKey(page), page.superview === self,
              abs(page.frame.width - bounds.width) < 0.5, abs(page.frame.height - bounds.height) < 0.5 else { return }
        let shy = page.privateMode
        // Asked here, not on the next turn: the page leaving this stage queues
        // its hide when it goes (ChromiumPage.syncGeometry), and Chromium
        // pictures a page only while it is shown. Asked first, the picture
        // reaches the helper ahead of the hide, which waits for it.
        PageStills.shared.take(page, owner: owner, key: key, shy: shy)
    }

    /// The page on show moved, scrolled or loaded: pictured again once it
    /// has been still for `delay`, no more than once every two seconds.
    /// One timer however often it is called: a scroll calls it on every
    /// frame it moves.
    func moved(after delay: TimeInterval = 1.2, page: NSView? = nil) {
        guard PageStills.on else { return }
        // A page stepping off under the one just picked, its scroll still
        // gliding, is not the page on show (#455).
        if let page, page !== wanted { return }
        settledAt = max(settledAt, CACurrentMediaTime() + delay)
        refreshFor = owner
        guard !refreshing else { return }
        refreshing = true
        refresh(in: delay)
    }

    private func refresh(in wait: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, wait)) { [weak self] in
            guard let self else { return }
            let now = CACurrentMediaTime()
            let due = max(self.settledAt, self.refreshed + 2)
            if now < due - 0.01 { return self.refresh(in: due - now) }
            self.refreshing = false
            // For the page that moved: a tab picked meanwhile is not
            // pictured on its timer just after it came (#455).
            guard let owner = self.owner, owner == self.refreshFor, let view = self.wanted,
                  self.awaitingPaint == nil, self.leaving == nil, self.still == nil else { return }
            self.refreshed = now
            if let page = view as? ChromiumPage {
                if !page.media.report.playing && !page.media.report.audible { self.picture(page, of: owner) }
                return
            }
            guard let web = view as? WKWebView else { return }
            // Not while its video or sound plays: the picture is a whole
            // page painted at full size by the page's process, and with a
            // video playing that took its frames for a fifth of a second
            // after each scroll (#243, evals/youtube-scroll). A still of a
            // playing video is out of date at once anyway; the one taken
            // as the page leaves its stage still is.
            web.requestMediaPlaybackState { [weak self, weak web] state in
                MainActor.assumeIsolated {
                    guard let self, let web, state != .playing, self.owner == owner, self.wanted === web,
                          self.awaitingPaint == nil, self.leaving == nil, self.still == nil else { return }
                    self.picture(web, of: owner)
                }
            }
        }
    }
    private var refreshing = false
    private var refreshFor: Tab.ID?
    private var settledAt: CFTimeInterval = 0
    private var refreshed: CFTimeInterval = 0

    /// The tab now in front shown on this stage at once, from its page's
    /// last frame, before SwiftUI's pass for the switch hands the page over
    /// (Browser.showEarly): that pass, laying the window out for another
    /// tab or space, held the main thread 20 to 100 ms with nothing new on
    /// screen. Only for a page with a still for exactly this stage, taken
    /// over from the page it shows now; SwiftUI then hands over the same
    /// page and nothing more happens.
    @discardableResult
    static func early(from left: Tab?, to coming: Tab?, single: Bool) -> Bool {
        guard PageStills.on, single, let left, let coming, left.id != coming.id else { return false }
        func no(_ why: String) -> Bool {
            mark("early", ["no": why])
            return false
        }
        guard let leftPage = left.builtPage, let stage = leftPage.superview as? StageView,
              stage.shows == left.id, stage.wanted === leftPage else { return no("stage") }
        guard let web = coming.builtPage, web.superview == nil else { return no("page elsewhere") }
        guard !coming.asleep, !coming.isBlank, !coming.gone, !coming.floating, coming.device == nil,
              coming.failure == nil, coming.untrusted == nil, coming.cover == nil else { return no("tab") }
        guard let key = stage.stillKey(web), PageStills.shared.has(coming.id, matching: key) else { return no("no still") }
        stage.flushing = true
        stage.show(web, of: coming.id, tab: coming)
        stage.flushing = false
        // On screen now, not at the end of the switch's pass.
        CATransaction.flush()
        return stage.still != nil
    }

    /// A Chromium page comes with no still: its renderer draws by itself, so
    /// it goes on the stage as it is, ahead of the switch, and on screen now.
    static func earlyChromium(from left: Tab?, to coming: Tab, single: Bool) -> StageView? {
        guard single, let left, left.id != coming.id, let leftPage = left.builtPage,
              let stage = leftPage.superview as? StageView, stage.shows == left.id, stage.wanted === leftPage,
              let page = coming.builtPage as? ChromiumPage, page.superview == nil,
              !coming.asleep, !coming.isBlank, !coming.gone, !coming.floating, coming.device == nil,
              coming.failure == nil, coming.untrusted == nil, coming.cover == nil else { return nil }
        stage.flushing = true
        stage.show(page, of: coming.id, tab: coming)
        stage.flushing = false
        CATransaction.flush()
        return stage
    }

    /// The tab `Browser.open` is about to put in front, or a sleeping one
    /// `select` wakes there (feedback #278), which `show` takes in at once
    /// (`takeOpening`). A moment old at most: a show that never came leaves
    /// no tab to be taken that way later.
    // Windows can open different tabs before either stage takes its page.
    // One process-wide slot let the second window erase the first one's
    // instruction and left its previous page visible instead (#1312).
    private static var opening: [Tab.ID: CFTimeInterval] = [:]
    private static func pruneOpenings(now: CFTimeInterval) {
        opening = opening.filter { now - $0.value < 1 }
    }
    static func willOpen(_ id: Tab.ID) {
        let now = CACurrentMediaTime()
        pruneOpenings(now: now)
        opening[id] = now
    }
    /// Whether `id` is that tab now, for tests.
    static func opensAtOnce(_ id: Tab.ID) -> Bool {
        pruneOpenings(now: CACurrentMediaTime())
        return opening[id] != nil
    }
    /// Tests preserve the original pending set and age markers without
    /// sleeping or changing the production monotonic clock.
    static var benchOpenings: [Tab.ID: CFTimeInterval] {
        get { Store.testing ? opening : [:] }
        set { if Store.testing { opening = newValue } }
    }
    /// Whether `page`, shown now for `owner`, is the tab just opened, with
    /// no document of its own yet.
    private static func takeOpening(_ owner: Tab.ID?, _ page: NSView?) -> Bool {
        pruneOpenings(now: CACurrentMediaTime())
        guard let owner, opening.removeValue(forKey: owner) != nil, let web = page as? WKWebView else { return false }
        return web.backForwardList.currentItem == nil
    }

    /// A tab just opened, its page put on this stage now, under the page
    /// shown until it has drawn (`show` keeps the one leaving), before
    /// SwiftUI's pass for the tab in front (Browser.open, OPEN_FIRST).
    @discardableResult
    static func earlyOpen(from left: Tab?, to coming: Tab) -> Bool {
        guard let left, let stage = left.webKitOnly("WebKit first-frame scheduling", build: false)?.superview as? StageView, stage.shows == left.id,
              stage.wanted === left.webKitOnly("WebKit first-frame scheduling", build: false), let web = coming.webKitOnly("WebKit first-frame scheduling", build: false), web.superview == nil else { return false }
        stage.show(web, of: coming.id, tab: coming)
        let shown = stage.shows == coming.id && web.superview === stage
        mark("early.open", ["shown": shown, "waiting": stage.awaitingPaint === web])
        return shown && stage.awaitingPaint === web
    }

    /// Called once `web`, waiting to draw on this stage, is shown (drawn,
    /// or past the paint wait), or at once if it isn't waiting.
    func afterReveal(of web: WKWebView, _ done: @escaping () -> Void) {
        guard awaitingPaint === web else { return done() }
        revealed = (web, done)
    }
    private var revealed: (web: WKWebView, done: () -> Void)?

    /// A window transfer ends this stage's ownership before another takes
    /// the page. Removing just the NSView leaves `wanted` behind, so a
    /// later layout of the old stage can take the live page back.
    func relinquish(_ page: NSView) {
        guard wanted === page else { return }
        heldFor = nil
        show(nil)
    }

    override func willRemoveSubview(_ subview: NSView) {
        guard !tearingDown else { super.willRemoveSubview(subview); return }
        if subview === resizingPage { stopFollowing() }
        // Restore before a Floater or another stage borrows the view. A
        // stale callback must never change the receiving stage's opacity.
        if subview === awaitingPaint { cancelPaintWait() }
        if subview === leaving { leaving = nil }
        super.willRemoveSubview(subview)
    }
    private var owner: Tab.ID?
    /// Whose page this stage shows, for a click to say which half it is.
    var shows: Tab.ID? { owner }

    /// What the stage did as the page changed shape, in a test world only,
    /// for the bench (`stagetrace`, evals/sidebar-motion/trace.py): each
    /// layout, hold and carry, and what the changes around it said (`mark`).
    /// Whether the page was held when the window was laid out at its new
    /// size is what decides if it slides or jumps there.
    static var trace: [[String: Any]] = []
    private static let tracing = Store.testing
    static func mark(_ event: String, _ more: @autoclosure () -> [String: Any] = [:]) {
        guard tracing else { return }
        if trace.count > 400 { trace.removeFirst(100) }
        trace.append(["t": CACurrentMediaTime(), "e": event].merging(more()) { $1 })
    }
    /// Where the stage and its page are now, in the window's points from
    /// its top left, as laid out and as Core Animation shows them this
    /// moment (the mask's outline on its way, the page carried), for the
    /// bench's `devframes` in a test world.
    func benchGeometry() -> [String: Any] {
        guard let window, let content = window.contentView else { return [:] }
        func top(_ r: CGRect) -> [Double] { [r.minX, content.bounds.height - r.maxY, r.width, r.height].map(Double.init) }
        var out: [String: Any] = ["stage": top(convert(bounds, to: nil)), "held": held.map { [Double($0.width), Double($0.height)] } ?? [],
                                  "following": follower != nil, "veil": veil != nil, "followVeil": followVeil.map { !$0.isHidden } ?? false,
                                  "viewportPending": follower?.asked != nil,
                                  "awaiting": awaitingPaint != nil, "leaving": leaving != nil, "still": still != nil,
                                  "views": subviews.map { NSStringFromClass(type(of: $0)) }]
        if let page = wanted {
            out["page"] = top(page.convert(page.bounds, to: nil))
            if let shown = page.layer?.presentation(), let host = layer {
                out["pageShown"] = top(convert(convertFromLayer(host.convert(shown.frame, from: shown.superlayer)), to: nil))
            }
        }
        if let mask = layer?.mask as? CAShapeLayer, let path = mask.presentation()?.path ?? mask.path {
            out["outline"] = top(convert(convertFromLayer(path.boundingBox), to: nil))
        }
        return out
    }

    private func note(_ event: String, _ more: @autoclosure () -> [String: Any] = [:]) {
        guard StageView.tracing else { return }
        StageView.mark(event, ["held": held != nil, "w": Double(bounds.width),
                               "x": Double(convert(bounds, to: nil).minX)].merging(more()) { $1 })
    }

    override func layout() {
        super.layout()
        guard !tearingDown else { return }
        StageView.layouts += 1
        guard window != nil else { settle(); return }
        let now = convert(bounds, to: nil)
        var old = was.map { convert($0, from: nil) }
        if follower?.native == true, let was, let web = resizingPage {
            let dx = was.minX - now.minX, dy = was.minY - now.minY
            if dx != 0 || dy != 0 {
                web.setFrameOrigin(web.frame.origin.applying(CGAffineTransform(translationX: dx, y: dy)))
                if let frame = follower?.pendingFrame {
                    follower?.pendingFrame = frame.offsetBy(dx: dx, dy: dy)
                }
                if let step = follower, step.protectsGrowth, step.asked != nil {
                    coverNativeGrowth(in: web.frame, painted: step.drawn)
                }
            }
        }
        note("layout", ["was": was.map { [Double($0.minX), Double($0.width)] } ?? [], "tracking": tracking])
        // Given somewhere else while still on its way: from where it shows.
        // A viewport commit can lay this stage out again in the same
        // place. Sampling its moving mask then restarted the curve on each
        // commit, so a leading chat never finished giving the page back.
        // Only a new stage frame interrupts and retargets that curve.
        if held != nil, let was, was != now, let seen = seen() {
            old = seen.offsetBy(dx: was.minX - now.minX, dy: was.minY - now.minY)
        }
        was = now
        // A still drawn for another size than the stage now has is not
        // the page as it will be: the page comes in as it is.
        if let still, abs(still.key.size.width - bounds.width) > 0.5 || abs(still.key.size.height - bounds.height) > 0.5 {
            cancelPaintWait()
        }
        let corner = wasCorner
        wasCorner = self.corner
        // Let go into the room a preview made: already drawn there.
        let (landed, shown) = landPreview(from: old)
        if let shown { old = shown }
        reshape(from: old, corner: corner, landed: landed)
        settle(from: landed ? nil : old)
    }

    private func belongsHere(_ page: NSView, tab: Tab?, owner: Tab.ID?) -> Bool {
        if let window, let browser = BrowserWindows.shared.browser(for: window) {
            hostWindowID = browser.windowID ?? BrowserWindows.primaryID
        }
        guard let tab else { return owner == nil || hostWindowID == nil }
        guard (owner == nil || tab.id == owner), tab.builtPage === page else { return false }
        guard let hostWindowID else { return true }
        guard let browser = tab.delegate as? Browser else { return false }
        return (browser.windowID ?? BrowserWindows.primaryID) == hostWindowID
    }

    func show(_ page: NSView?, of owner: Tab.ID? = nil, tab: Tab? = nil) {
        // Validate current ownership, not the owner captured in an older
        // WebStage value. Otherwise that value can recreate `wanted` after
        // relinquish and take the destination's live view back.
        let claiming: Tab?
        if page == nil { claiming = nil }
        else if let tab { claiming = tab }
        else if wanted === page, let claimant { claiming = claimant }
        else if let browser = window.flatMap({ BrowserWindows.shared.browser(for: $0) }) {
            claiming = (browser.everyTab + browser.outside).first { $0.id == owner && $0.builtPage === page }
        } else { claiming = nil }
        if let page, !belongsHere(page, tab: claiming, owner: owner) {
            note("ownership.rejected", ["tab": owner?.uuidString ?? "", "window": window?.windowNumber ?? 0])
            return
        }
        claimant = claiming
        // A mini page already has visible pixels. Its flight handles the
        // animation, and the direct path must keep those pixels while its
        // WebContent process is busy, instead of waiting at opacity zero.
        let fromMini = page?.superview is PageHolder && page?.window != nil && page?.window !== window
        let turned = self.owner != nil && owner != self.owner
        let left = self.owner
        self.owner = owner
        let old = wanted
        if old !== page { pinned = sidebarPin }
        // SwiftUI may deliver the same page again while it is waiting for
        // paint. A layout update must not cancel that wait or its surface.
        if old === page {
            // Asked again from inside this very change (a flush runs
            // AppKit's display cycle, and SwiftUI's update with it): the
            // page isn't attached yet, and that is not a page lent away.
            if changing { return }
            if away || window == nil || page?.superview !== self {
                cancelPaintWait()
            }
            settle()
            return
        }
        changing = true
        defer { changing = false }
        pageTurns += 1
        let generation = pageTurns
        if follower?.native == true, !asked, previewing == nil {
            releaseGrip()
        } else {
            stopFollowing()
        }
        // A page going without its ground drawn gets it back.
        if bareGround !== page { giveGroundBack() }
        if unseenPage !== page { giveSightBack() }
        let wasWaiting = awaitingPaint != nil
        let departing = wasWaiting ? leaving : old
        awaitingPaint = nil
        firstDocument = nil
        // A still is for the page it stood in for, not the one coming.
        liftStill(to: nil, painted: false)
        // The page left, pictured as it was last seen, to stand in for it
        // when its tab comes back (PageStills). Not one that was still
        // waiting to draw: what it shows is not yet itself.
        if turned, !wasWaiting, let left {
            if let page = old as? ChromiumPage { picture(page, of: left) }
            else if let web = old as? WKWebView { picture(web, of: left) }
        }
        wanted = page
        // A veil is for the page it was put over, not the one coming.
        unveil()
        old?.layer?.removeAllAnimations()
        old?.layer?.opacity = 1
        // Picked again while the page left still stood under one waiting to
        // draw: it is put right at once, and a page coming straight back is
        // still where it was, under the one just left.
        if let still = leaving {
            leaving = nil
            still.layer?.removeAllAnimations()
            still.layer?.opacity = 1
            if still === page {
                settle()
                return
            }
        }
        guard turned, window != nil, !fromMini else {
            settle()
            return
        }
        // A third tab picked before paint keeps the original visible
        // surface underneath; the pending, transparent page is not a
        // usable departing surface.
        leaving = departing?.superview === self ? departing : nil
        // This page's own last frame, if it was drawn for exactly how the
        // page is shown here now: put up before the page itself joins the
        // window, and on screen at once when the switch came early
        // (`early`): that commit then carries nothing of WebKit's, which
        // can hold a commit for its page.
        let still = page.flatMap { stillFor($0, of: owner) }
        // A tab you just opened in front, its site not yet answered: it is
        // in front now, on the stage's own ground, and the page left steps
        // off at once rather than standing in until the site answers, as
        // Arc opens one (feedback #206). Nothing of WebKit's white shows
        // meanwhile (`groundless`).
        // A woken page with its last frame kept has that frame instead.
        let opened = Self.takeOpening(owner, page) && still == nil
        note("show", ["owner": owner.map { String($0.uuidString.prefix(8)).lowercased() } ?? "", "still": still != nil, "leaving": leaving != nil, "opened": opened])
        if let still {
            putStill(still)
            // The page left is covered: it goes at once. Nothing moves or
            // fades on a switch, as in Arc and Chrome: the page stepping in
            // from the tab's side shifted the layout a little on every
            // switch (register #441).
            leaving = nil
            if flushing { CATransaction.flush() }
        }
        settle()
        if opened, let web = page as? WKWebView, web.superview === self { groundless(web) }
        // Keep the departing surface under a waking page too. Attaching
        // its empty backing before its first document caused a brief flat
        // frame on the first space switch after launch.
        if let web = page as? WKWebView, !opened, leaving != nil || still != nil, web.superview === self {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            web.layer?.opacity = 0
            CATransaction.commit()
            awaitingPaint = web
            let begun = CACurrentMediaTime()
            let reveal = { [weak self, weak web] (painted: Bool) in
                guard let self, let web, self.pageTurns == generation,
                      self.wanted === web, self.awaitingPaint === web else { return }
                self.awaitingPaint = nil
                let committed = self.firstDocument == nil
                self.firstDocument = nil
                let stood = self.still != nil
                self.note("reveal", ["painted": painted, "stood": stood, "ms": ((CACurrentMediaTime() - begun) * 10000).rounded() / 10])
                // Not drawn by `paintWait`: a late stylesheet or a slow
                // server holds a dark site's first paint, and what WebKit
                // shows until then is white (evals/dark-first-paint slow-css,
                // slow-tab, woken; feedback #205). The page left goes; this
                // one stays unseen over the stage's own ground until it has
                // drawn.
                if !painted {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.liftStill(to: nil, painted: false)
                    CATransaction.commit()
                    if let then = self.revealed, then.web === web {
                        self.revealed = nil
                        then.done()
                    }
                    self.leaving = nil
                    self.settle()
                    self.unseen(web, committed: committed)
                    return
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                web.layer?.opacity = 1
                self.liftStill(to: web, painted: painted)
                CATransaction.commit()
                if let then = self.revealed, then.web === web {
                    self.revealed = nil
                    then.done()
                }
                guard web.superview === self, self.window != nil, !self.away else {
                    self.leaving = nil
                    self.settle()
                    return
                }
                // Live and drawn, and not pictured again a moment later:
                // that is a whole page painted by its own process while you
                // look at the tab just picked, which held a heavy page's
                // frames and scripts 0.4 to 0.6 s (feedback #455,
                // evals/feedback-455). It is pictured as it leaves, or once
                // it has moved.
                // The still already stood in; the page takes its place.
                if stood { return }
                self.leaving = nil
                self.settle()
            }
            if web.backForwardList.currentItem == nil, web.isLoading || web.url == nil {
                firstDocument = { reveal(true) }
            } else {
                StageView.afterNextDrawing(web, requirePaint: true) { reveal(true) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.paintWait) { reveal(false) }
        } else if let remote = page as? ChromiumPage, still != nil, remote.superview === self {
            let reveal = { [weak self, weak remote] (painted: Bool) in
                guard let self, let remote, self.pageTurns == generation, self.wanted === remote else { return }
                self.liftStill(to: nil, painted: painted)
            }
            remote.afterNextFrame { reveal($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.paintWait) { reveal(false) }
        } else if still != nil {
            // Put up for a page that didn't stay here after all.
            liftStill(to: nil, painted: false)
        } else {
            leaving = nil
            settle()
        }
    }

    /// Set while `early` shows a page: the still is flushed to the screen
    /// before the page joins the window.
    private var flushing = false
    /// Inside `show`, for a call back into it to know.
    private var changing = false

    private func settle(from old: CGRect? = nil) {
        // The tab can move between this stage's show and its next layout.
        // A stage in the old window has no authority to reparent it then.
        if let wanted, !belongsHere(wanted, tab: claimant, owner: owner) {
            note("ownership.rejected-layout", ["tab": owner?.uuidString ?? "", "window": window?.windowNumber ?? 0])
            return
        }
        // The page stepping off under the one coming keeps its place from
        // the top, as every page here is put: this view's y runs up, and a
        // stage made taller in the same change (the Developer Tools card,
        // which is the tab's, going with the tab left) left it at the foot,
        // a strip of it under white for the frames the new page took.
        if abs(bounds.height - laidHeight) > 0.5 {
            if laidHeight > 0, let leaving, leaving.superview === self {
                leaving.setFrameOrigin(NSPoint(x: leaving.frame.minX, y: leaving.frame.minY + bounds.height - laidHeight))
            }
            laidHeight = bounds.height
        }
        // A video filling the screen has its page lent to WebKit's own
        // window, with a placeholder left here in its place. The chrome
        // stepping aside lays the stage out again that same moment, and
        // taking the page back then left the screen black with the sound
        // still playing. WebKit brings it back itself on the way out.
        if let web = wanted as? WKWebView, web.fullscreenState != .notInFullscreen {
            stopFollowing()
            return
        }
        // A Chromium page's own full screen lends it to a window of Yab's
        // own the same way (ChromiumPage+Media.swift).
        if let page = wanted as? ChromiumPage, page.media.fullscreen {
            stopFollowing()
            return
        }

        // Anything here that isn't wanted, out, except the page stepping
        // off under the new one. Only ever what is actually ours: a page may
        // be somewhere else on purpose. And except the Web Inspector docked
        // beside the page: WebKit puts it here, next to the page, and makes
        // the page narrower to fit it. Taken out on the next resize, it left
        // the page narrow beside nothing.
        // Asked of WebKit only when something besides the page is here: the
        // stage lays out on every frame of a slide, and nearly always holds
        // the page alone.
        let docked = subviews.contains { $0 !== wanted && $0 !== leaving } && inspecting
        for view in subviews where view !== wanted && view !== leaving && !(docked && Self.isInspector(view)) {
            view.removeFromSuperview()
        }

        guard let wanted, window != nil, !away || wanted.superview === self else { return }
        if wanted.superview !== self {
            // A web view can have only one superview, so taking it back is how
            // it is taken back, straight from wherever it is, never through
            // having no window at all. A web view with no window is a hidden
            // page, and a hidden page pauses its video.
            wanted.alphaValue = 1
            let begin = NSSelectorFromString("_beginDeferringViewInWindowChanges")
            let end = NSSelectorFromString("_endDeferringViewInWindowChanges")
            if let web = wanted as? WKWebView, web.superview is PageHolder,
               let source = web.window, let destination = window, source !== destination,
               web.responds(to: begin), web.responds(to: end) {
                // WebKit otherwise sees an out-of-window/in-window pair,
                // hides its current pixels and synchronously waits for a
                // paint. Publish only the final in-window state. Balance
                // the pair inside this synchronous reparent, never later.
                web.perform(begin)
                defer { web.perform(end) }
                addSubview(web)
            } else {
                addSubview(wanted)
            }
            // A web view coming back into a window sometimes keeps the last
            // picture it had, which, after a while out of one, is nothing.
            // Asking it to draw again is cheap and is what brings it back.
            wanted.needsLayout = true
            wanted.needsDisplay = true
            wanted.layer?.setNeedsDisplay()
            // The first page of a stage that had none, the first tab of an
            // empty window (`show` came before the stage was in it): no page
            // left and no still to stand in for it, so WebKit's own backing
            // showed, white in dark too, for as long as the site's
            // stylesheets took (evals/dark-first-paint: 600 ms for a late
            // one). It draws none of that until it has drawn itself.
            if let web = wanted as? WKWebView, awaitingPaint == nil, leaving == nil, still == nil,
               web.backForwardList.currentItem == nil {
                groundless(web)
            }
        }
        // Held, the page keeps its size, its top left corner in the
        // stage's; this view's y runs up.
        // With the inspector docked, WebKit lays the page and it out side by
        // side as the stage changes size; a frame set here would cover it.
        if docked, subviews.contains(where: Self.isInspector) {
            stopFollowing()
            return
        }
        var frame = held.map { CGRect(x: shifted.x, y: bounds.height - $0.height + shifted.y, width: $0.width, height: $0.height) } ?? bounds
        // As a device: that size, drawn smaller when the room is, the page
        // told it has the device's width to lay out in. This view's y runs up.
        if let web = wanted as? WKWebView {
            var scale: CGFloat = 1
            if let device, held == nil {
                let rect = device.frame(in: bounds.size)
                frame = CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
                // From the frame as drawn, whole points: the page is then laid
                // out at the device's own width, not a point or two off it.
                scale = device.width > 0 ? rect.width / device.width : 1
            } else if device != nil {
                scale = scaled
            }
            if scale != scaled || web !== scaledPage {
                // A page still drawn small from another stage, come to this
                // one at 1, is put back too: it drew its words at that scale.
                if scale != 1 || scaled != 1 || (DeviceStage.scale(of: web) ?? 1) != 1 { DeviceStage.scale(web, scale) }
                scaled = scale
                scaledPage = web
            }
        } else if let chromium = wanted as? ChromiumPage, let device, held == nil {
            let rect = device.frame(in: bounds.size)
            frame = CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
            chromium.emulate(device, scale: device.width > 0 ? rect.width / device.width : 1)
        }
        if held != nil, tracking || following, !docked, device == nil,
           Self.geometryFollowing, Self.follows, let old, old != bounds {
            follow(from: old)
            return
        }
        let before = wanted.frame.size
        if sidebarPin != pinned, let old, old != bounds,
           wanted is WKWebView || wanted is ChromiumPage {
            let web = wanted
            pinned = sidebarPin
            stopFollowing()
            held = old.size
            web.frame = old
            edge()
            follower = Follow(native: true, from: old, to: bounds, start: CACurrentMediaTime(),
                              duration: 0, curve: .linear, drawn: old.size, finishing: true)
            beginNativeFollowing(web)
            geometryStep(at: CACurrentMediaTime())
            return
        }
        // Releasing a divider and laying out its last target can arrive in
        // the same SwiftUI pass. Keep that latest target until its paint,
        // rather than release an earlier width and snap to the last one.
        if follower?.native == true, !asked, previewing == nil {
            follower?.to = bounds
            if follower?.finishing == true { geometryStep(at: CACurrentMediaTime()) }
            return
        }
        // A native geometry update owns both the page's origin and size.
        // An unrelated SwiftUI update must not put it at the final origin
        // while its viewport is still part-way through the transition.
        if follower?.native == true { return }
        if before != frame.size { StageView.resizes += 1 }
        // SwiftUI can update the stage several times at the same size.
        // Avoid entering WebKit's frame setter again for those passes.
        if wanted.frame != frame { wanted.frame = frame }
        // Made larger, the new part is covered until WebKit draws it, but not
        // while a page turns in over the last one: the veil would stand
        // still while the page moves. Made any other size, a veil still up
        // for an earlier growth covers what the page now draws itself.
        if before != frame.size, before.width > 0, wanted.superview === self {
            if leaving == nil { cover(grown: before, to: frame.size) }
            if leaving != nil || (frame.width <= before.width + 0.5 && frame.height <= before.height + 0.5) { unveil() }
        }
        // And carried there from where it was, the same way as the mask.
        if held != nil, !tracking, let old, old != bounds, let page = wanted.layer {
            // From the old top left corner to the new, in the layer's own
            // coordinates, which need not run the way the view's do.
            let was = convertToLayer(NSPoint(x: old.minX, y: old.maxY))
            let now = convertToLayer(NSPoint(x: bounds.minX, y: bounds.maxY))
            Reshape.carry(page, by: CGPoint(x: was.x - now.x, y: was.y - now.y))
            note("carry", ["by": Double(was.x - now.x)])
            if following, !docked { follow(from: old) }
        }
    }

    // MARK: - the size it shows, given on the way

    /// All animated viewport changes share the same coordinator. The
    /// outline moves in Core Animation; WebKit receives one size at a
    /// time, and its origin moves with the content committed at that size.
    /// A dragged divider supplies direct targets instead of a curve, with
    /// intermediate pointer updates coalesced to the newest target.
    /// The final target stays held until it has painted. Fixed device
    /// viewports and the test-only legacy path retain their sizing rules.
    var following = false
    var sidebarPin = 0
    private var pinned = 0

    /// Off only for measuring what it costs (`fold.live` = off).
    static var follows = !(Store.testing && Store.settings.string(forKey: "fold.live") == "off")

    /// The legacy carry/predict path is retained only for same-build A/B.
    static var geometryFollowing: Bool {
        !(Store.testing && Store.settings.string(forKey: "fold.geometry") == "legacy")
    }

    /// The least change in either dimension worth a layout on the way.
    /// (`split.step` in a test world, to weigh one against another.)
    private static let leastStep: CGFloat = Store.testing ? CGFloat(Store.settings.double(forKey: "split.step")).nonzero ?? 16 : 16
    /// The longest a size on the way is waited for.
    private static let longestStep: CFTimeInterval = 0.25

    /// How long WebKit has lately taken from a new size to having it on
    /// screen, so the size asked for is the one the edge is at by then.
    private static var lag: CFTimeInterval = 1.0 / 30

    /// Each size given on the way, for the bench, in a test world only:
    /// [ms from the start of the move, width, ms until WebKit drew it];
    /// and, as [-1, …], each start: the stage's left and right edges
    /// from and to, and the page's width then.
    static var steps: [[Double]] = []

    private struct Follow {
        let native: Bool
        /// The stage's outline it goes from and to, in its own coordinates.
        let from: CGRect
        var to: CGRect
        let start: CFTimeInterval
        let duration: CFTimeInterval
        let curve: UnitCurve
        /// A size handed to WebKit and not yet on screen, and when.
        var asked: CGSize?
        var askedAt: CFTimeInterval = 0
        var pendingFrame: CGRect?
        /// The size WebKit last put on screen.
        var drawn: CGSize
        var finishing = false
        /// Retained through the final paint, after SwiftUI releases its hold.
        var protectsGrowth = false
    }

    private var follower: Follow?
    private var followLink: CADisplayLink?
    private var followTurn = 0
    /// Over the part of a page made larger that WebKit has not drawn yet,
    /// the ground a held page shows, carried with the page.
    private var followVeil: CAShapeLayer?
    private weak var resizingPage: NSView?
    private var nativeLag: CFTimeInterval = 1.0 / 60

    private func follow(from old: CGRect, to target: CGRect? = nil, duration: CFTimeInterval? = nil) {
        guard StageView.follows, let held, wanted is WKWebView || wanted is ChromiumPage else { return }
        let target = target ?? bounds
        let duration = duration ?? (tracking ? 0 : Reshape.duration)
        // Laid out again on the way, the page carried afresh from where
        // that put it: the same from here, but a size still with WebKit
        // is still waited for.
        let native = device == nil && Self.geometryFollowing
        guard native || wanted is WKWebView else { return }
        guard native || abs(old.width - target.width) > 0.5 || abs(old.height - target.height) > 0.5 else { return }
        if let follower, follower.native != native { stopFollowing() }
        var next = Follow(native: native, from: old, to: target, start: Reshape.started, duration: duration,
                          curve: Reshape.pace.curve, drawn: follower?.drawn ?? held)
        next.asked = follower?.asked
        next.askedAt = follower?.askedAt ?? 0
        next.pendingFrame = follower?.pendingFrame
        next.protectsGrowth = protectsViewportGrowth || follower?.protectsGrowth == true
        follower = next
        if native, let web = wanted {
            // The content process is asynchronous. Keep the old origin
            // until its next viewport has committed, then move the page in
            // that same CA transaction (not one frame after presentation).
            web.layer?.removeAnimation(forKey: "reshape.carry")
            if resizingPage !== web {
                web.frame = old
            } else {
                follower = Follow(native: true, from: CGRect(origin: web.frame.origin, size: next.drawn),
                                  to: target, start: Reshape.started, duration: duration,
                                  curve: Reshape.pace.curve, asked: next.asked, askedAt: next.askedAt,
                                  pendingFrame: next.pendingFrame, drawn: next.drawn,
                                  protectsGrowth: next.protectsGrowth)
            }
            beginNativeFollowing(web)
            if followLink == nil {
                let link = displayLink(target: self, selector: #selector(followStep))
                link.add(to: .main, forMode: .common)
                followLink = link
            }
            // Commit the panel's animation before the first viewport
            // resize. Resizing WebKit during this layout pass can hold up
            // the transaction that starts the whole sidebar transition.
            // The display link requests its first size on the next tick,
            // just as the other live-layout path below does.
            return
        }
        // The veil goes with the page on the page's own carry, added in
        // the same commit, so the two start on the same frame: begun a
        // few milliseconds apart on the quick start of the curve, they
        // were a dozen points apart, and the page's white showed between.
        if let layer, let carry = wanted?.layer?.animation(forKey: "reshape.carry") {
            let veil = followVeil ?? CAShapeLayer()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            veil.zPosition = 10
            if veil.superlayer !== layer { layer.addSublayer(veil) }
            veil.add(carry, forKey: "reshape.carry")
            CATransaction.commit()
            followVeil = veil
        }
        if Store.testing { StageView.steps.append([-1, Double(old.minX), Double(old.maxX), Double(bounds.minX), Double(bounds.maxX), Double(held.width)]) }
        if followLink == nil {
            let link = displayLink(target: self, selector: #selector(followStep))
            link.add(to: .main, forMode: .common)
            followLink = link
        }
        // The first width on the link's next tick, not in this pass: this
        // one already lays the window out and hands Core Animation its
        // curves, and the page made another size in it as well was one
        // frame too long to draw at the start of every motion.
    }

    @objc private func followStep() {
        if follower?.native == true { geometryStep(at: CACurrentMediaTime()); return }
        guard var step = follower, let size = held, let web = wanted as? WKWebView else { return stopFollowing() }
        let now = CACurrentMediaTime()
        // A size WebKit never says it drew, a page busy or hung, holds the
        // rest of the way no longer than this: the next is asked for, and
        // the late word on the last finds it is not the one waited for.
        if step.asked != nil {
            guard now - step.askedAt > StageView.longestStep else { return }
            step.drawn = size
            step.asked = nil
            follower = step
        }
        let along = min(1, max(0, (now + StageView.lag - step.start) / step.duration))
        let p = step.curve.value(at: along)
        let left = step.to.minX + (step.from.minX - step.to.minX) * (1 - p)
        let right = step.to.maxX + (step.from.maxX - step.to.maxX) * (1 - p)
        let next = CGSize(width: (right - left).rounded(),
                          height: (step.from.height + (step.to.height - step.from.height) * p).rounded())
        let change = max(abs(next.width - size.width), abs(next.height - size.height))
        guard change >= StageView.leastStep || (along >= 1 && change >= 1) else {
            if along >= 1 { stopFollowing() }
            return
        }
        held = next
        StageView.resizes += 1
        let setting = CACurrentMediaTime()
        web.frame = CGRect(x: shifted.x, y: bounds.height - next.height + shifted.y,
                           width: next.width, height: next.height)
        let set = (CACurrentMediaTime() - setting) * 1000
        step.asked = next
        step.askedAt = now
        follower = step
        veil(step)
        // [ms from the start, width, ms until drawn, ms the frame took to set]
        if Store.testing { StageView.steps.append([((now - step.start) * 1000).rounded(), Double(next.width), 0, (set * 100).rounded() / 100]) }
        let turn = followTurn
        StageView.afterNextDrawing(web) { [weak self] in
            guard let self, self.followTurn == turn, var step = self.follower, step.asked == next else { return }
            let took = CACurrentMediaTime() - step.askedAt
            StageView.lag = min(0.1, max(1.0 / 120, StageView.lag * 0.6 + took * 0.4))
            if Store.testing, let last = StageView.steps.indices.last, StageView.steps[last].count > 2 { StageView.steps[last][2] = (took * 1000).rounded() }
            step.drawn = next
            step.asked = nil
            self.follower = step
            // A frame after it is on screen, as `cover` waits.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
                guard let self, self.followTurn == turn, let step = self.follower, step.asked == nil else { return }
                self.veil(step)
            }
        }
    }

    /// Both engines keep one viewport in flight. Chromium's native receipt
    /// identifies the canvas size; the coordinator still waits for its own CA
    /// commit before requesting another size or releasing the final hold.
    private static func afterViewportPaint(_ page: NSView, _ done: @escaping () -> Void) {
        if let web = page as? WKWebView {
            afterNextDrawing(web, requirePaint: true, done)
        } else if let chromium = page as? ChromiumPage {
            chromium.afterViewportPaint(done)
        }
    }

    private func beginNativeFollowing(_ web: NSView) {
        guard resizingPage !== web else { return }
        (resizingPage as? WKWebView)?.viewDidEndLiveResize()
        resizingPage = web
        (web as? WKWebView)?.viewWillStartLiveResize()
    }

    /// One viewport in flight. Origin changes in WebKit's layer-tree
    /// commit callback, together with the content drawn at that width.
    /// Finishing also waits for the final viewport, never dropping the
    /// hold merely because the panel's clock has reached its duration.
    private func geometryStep(at now: CFTimeInterval) {
        guard var step = follower, let web = resizingPage, web === wanted,
              web.superview === self else { return stopFollowing() }
        guard step.asked == nil else { return }
        let prediction = step.from.size == step.to.size ? 0 : nativeLag
        let along = step.finishing || step.duration == 0 ? 1 : min(1, max(0, (now + prediction - step.start) / step.duration))
        let p = step.curve.value(at: along)
        let left = step.to.minX + (step.from.minX - step.to.minX) * (1 - p)
        let top = step.to.maxY + (step.from.maxY - step.to.maxY) * (1 - p)
        let width = (step.from.width + (step.to.width - step.from.width) * p).rounded()
        let height = (step.from.height + (step.to.height - step.from.height) * p).rounded()
        let frame = CGRect(x: left + shifted.x, y: top - height + shifted.y, width: width, height: height)
        if frame.size == step.drawn {
            // Moving a panel from one side to the other can preserve the
            // viewport's size. Its already painted content can move along
            // the same curve without requesting another WebKit layout.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if web.frame.origin != frame.origin {
                web.setFrameOrigin(frame.origin)
                note("viewport-position", ["frame": [Double(frame.minX), Double(frame.minY), Double(width), Double(height)]])
            }
            CATransaction.commit()
            if step.finishing {
                releaseGrip()
            }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        held = frame.size
        if web.frame.size != frame.size { StageView.resizes += 1 }
        let setting = CACurrentMediaTime()
        // Resize in place first. Moving its origin here would expose the
        // previous width at the next position until WebKit catches up.
        web.setFrameSize(frame.size)
        if step.protectsGrowth { coverNativeGrowth(in: web.frame, painted: step.drawn) }
        step.asked = frame.size
        step.askedAt = setting
        step.pendingFrame = frame
        follower = step
        note("sidebar-viewport-request", ["frame": [Double(frame.minX), Double(frame.minY), Double(width), Double(height)],
                                          "turn": followTurn])
        CATransaction.commit()
        let index = StageView.steps.count
        if Store.testing {
            StageView.steps.append([(now - step.start) * 1000, Double(width), 0, (CACurrentMediaTime() - setting) * 1000])
        }
        let generation = followTurn
        Self.afterViewportPaint(web) { [weak self, weak web] in
            guard let self, let web, self.followTurn == generation, self.wanted === web, web.superview === self,
                  let current = self.follower, current.native, let shown = current.pendingFrame else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // WebKit calls back while its layer tree is being committed.
            // Its callback is not a display acknowledgment: clearing asked
            // here lets the next display-link tick resize the same backing
            // again before this origin ever reaches the render server.
            // Keep the viewport in flight until this CA transaction ends.
            Self.afterNextCommit { [weak self, weak web] in
                DispatchQueue.main.async {
                    guard let self, let web, self.followTurn == generation,
                          self.wanted === web, web.superview === self, var committed = self.follower,
                          committed.native, committed.askedAt == setting else { return }
                    committed.drawn = shown.size
                    committed.asked = nil
                    committed.pendingFrame = nil
                    self.follower = committed
                    if committed.protectsGrowth {
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        self.followVeil?.removeFromSuperlayer()
                        self.followVeil = nil
                        CATransaction.commit()
                    }
                    self.note("sidebar-viewport-committed", ["turn": generation,
                        "shownX": web.layer?.presentation().map { Double($0.frame.minX) } ?? 0])
                    if committed.finishing { self.geometryStep(at: CACurrentMediaTime()) }
                }
            }
            web.setFrameOrigin(shown.origin)
            if current.protectsGrowth { self.coverNativeGrowth(in: shown, painted: current.drawn) }
            CATransaction.commit()
            self.nativeLag = min(0.05, max(1.0 / 120, self.nativeLag * 0.6 + (CACurrentMediaTime() - setting) * 0.4))
            self.note("sidebar-viewport-callback", ["frame": [Double(web.frame.minX), Double(web.frame.minY), Double(web.frame.width), Double(web.frame.height)],
                                                     "layerX": web.layer.map { Double($0.frame.minX) } ?? 0,
                                                     "shownX": web.layer?.presentation().map { Double($0.frame.minX) } ?? 0,
                                                     "turn": generation])
            if Store.testing, StageView.steps.indices.contains(index) {
                StageView.steps[index][2] = (CACurrentMediaTime() - setting) * 1000
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak web] in
            guard let self, let web, self.followTurn == generation, self.wanted === web,
                  self.follower?.askedAt == setting, self.follower?.asked != nil else { return }
            // A terminated or unresponsive WebContent process must not
            // retain the display link or trap the next sidebar command.
            // Recovery is not a paint acknowledgment or an acceptance pass.
            self.note("sidebar-width-timeout")
            self.releaseGrip()
        }
    }

    /// The native viewport grows before its remote layer tree commits.
    /// Keep only that unpainted part on the page's existing ground until
    /// the commit acknowledgment, including its deferred origin change.
    private func coverNativeGrowth(in requested: CGRect, painted: CGSize) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // WebKit keeps old content at the requested view's top left.
        // Use the actual frame, not bounds: left/bottom docking defer its
        // origin until the paint callback and move this cover with it.
        let drawn = CGRect(x: requested.minX, y: requested.maxY - painted.height,
                           width: painted.width, height: painted.height)
        let ready = requested.intersection(drawn)
        guard ready != requested else { followVeil?.isHidden = true; return }
        let veil = followVeil ?? CAShapeLayer()
        veil.frame = layer.bounds
        veil.zPosition = 10
        veil.fillRule = .evenOdd
        veil.fillColor = StageView.fill(under: (wanted as? WKWebView)?.underPageBackgroundColor, shade: shade, tone: tone).cgColor
        veil.isHidden = false
        let path = CGMutablePath()
        path.addRect(convertToLayer(requested))
        if !ready.isNull { path.addRect(convertToLayer(ready)) }
        veil.path = path
        if veil.superlayer !== layer { layer.addSublayer(veil) }
        followVeil = veil
    }

    /// Where the page is larger than WebKit has drawn it yet, the ground a
    /// held page shows, going with the page. Its own color, WebKit's white,
    /// would show there otherwise, a pale band beside a dark page.
    private func veil(_ step: Follow) {
        guard let veil = followVeil, let size = held else { return }
        let outer = CGRect(x: shifted.x, y: bounds.height - size.height + shifted.y,
                           width: size.width, height: size.height)
        let drawn = CGRect(x: shifted.x, y: bounds.height - step.drawn.height + shifted.y,
                           width: step.drawn.width, height: step.drawn.height)
        let bare = outer.intersection(drawn)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        veil.isHidden = bare == outer
        if !veil.isHidden {
            veil.frame = layer?.bounds ?? bounds
            veil.fillRule = .evenOdd
            veil.fillColor = StageView.fill(under: (wanted as? WKWebView)?.underPageBackgroundColor, shade: shade, tone: tone).cgColor
            let path = CGMutablePath()
            path.addRect(convertToLayer(outer))
            if !bare.isNull { path.addRect(convertToLayer(bare)) }
            veil.path = path
        }
        CATransaction.commit()
    }

    /// Taken out of the window mid-way, it lets go of its display link,
    /// which holds it, and of WebKit.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !tearingDown else { return }
        if window == nil { stopFollowing(); cancelPaintWait(); giveGroundBack() }
        // Slid whole with the page column (Reshape.slide).
        if window != nil {
            Reshape.carriers.add(self)
            // SwiftUI can select the page before mounting this stage, with
            // its final geometry already assigned. Do not wait for another
            // layout or tab switch to attach that page to the window.
            settle()
        }
    }

    private func stopFollowing() {
        followLink?.invalidate()
        followLink = nil
        (resizingPage as? WKWebView)?.viewDidEndLiveResize()
        (resizingPage as? ChromiumPage)?.cancelViewportPaint()
        resizingPage = nil
        guard let step = follower else { return }
        followTurn += 1
        follower = nil
        guard let veil = followVeil else { return }
        followVeil = nil
        if step.native && step.protectsGrowth { veil.removeFromSuperlayer(); return }
        guard step.asked != nil, !veil.isHidden, let web = wanted as? WKWebView else { return veil.removeFromSuperlayer() }
        // Let go with the last width not on screen yet: its ground stays
        // over it until it is.
        var lifted = false
        let lift = {
            guard !lifted else { return }
            lifted = true
            veil.removeFromSuperlayer()
        }
        StageView.afterNextDrawing(web) { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: lift) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: lift)
    }

    // MARK: - a page made larger

    /// Where a page just made larger has not drawn yet. WebKit lays the
    /// page out at its new size in its own process and hands back what it
    /// drew a moment later; until then the new part of the view is the web
    /// view's own background, white, a white band flashing beside a dark
    /// page after every ⇧⌘S, ⌘S or split. So the new part is covered, in
    /// the color the stage shows round a held page, until WebKit says it
    /// has drawn at the new size. One plain layer, for a few frames.
    private var veil: CAShapeLayer?
    private var veils = 0

    private func cover(grown old: CGSize, to new: CGSize) {
        // Not in macOS's move into full screen: the page holds that move's
        // picture until it has drawn at its new size (Brim.inFullScreenMove).
        guard StageView.covering, !Brim.inFullScreenMove(window), let web = wanted as? WKWebView, let layer,
              new.width > old.width + 0.5 || new.height > old.height + 0.5 else { return }
        let veil = self.veil ?? CAShapeLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        veil.frame = layer.bounds
        veil.zPosition = 10
        veil.fillRule = .evenOdd
        veil.fillColor = StageView.fill(under: web.underPageBackgroundColor, shade: shade, tone: tone).cgColor
        // Everything but where the page was, its top left corner kept, in
        // the stage's own coordinates, which run up.
        let path = CGMutablePath()
        path.addRect(convertToLayer(bounds))
        path.addRect(convertToLayer(CGRect(x: 0, y: bounds.height - old.height, width: old.width, height: old.height)))
        veil.path = path
        if veil.superlayer !== layer { layer.addSublayer(veil) }
        CATransaction.commit()
        self.veil = veil
        veils += 1
        let turn = veils
        let put = CACurrentMediaTime()
        let lift = { [weak self] (drawn: Bool) in
            guard let self, self.veils == turn, self.veil != nil else { return }
            self.veil?.removeFromSuperlayer()
            self.veil = nil
            if Store.testing { StageView.lifts.append((drawn, (CACurrentMediaTime() - put) * 1000)) }
        }
        // A frame after WebKit's next drawing at the new size is on screen,
        // and in any case after a second.
        StageView.afterNextDrawing(web) { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { lift(true) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { lift(false) }
    }

    /// The veil down at once, and a lift still to come for it made void.
    private func unveil() {
        guard veil != nil else { return }
        veils += 1
        veil?.removeFromSuperlayer()
        veil = nil
    }

    /// Each veil taken away, for the bench, in a test world only: whether
    /// WebKit's drawing took it away or the second ran out, and after how
    /// many ms.
    static var lifts: [(drawn: Bool, ms: Double)] = []

    /// A page transferred from another holder must belong to the receiving
    /// stage before a presentation callback can release its cover. SwiftUI
    /// attaches it on a later pass, and the old holder can still snapshot.
    static func afterHandoff(_ web: NSView, owner: Tab.ID, window: @escaping () -> NSWindow?,
                             cancelled: @escaping () -> Bool, attached: @escaping (StageView) -> Void,
                             done: @escaping (Bool) -> Void) {
        var finished = false
        var attempt = 0
        var hadVisibleWindow = false
        func finish(_ presented: Bool) {
            guard !finished else { return }
            finished = true
            done(presented)
        }
        func destinationClosed() -> Bool {
            guard let destination = window() else { return hadVisibleWindow }
            if destination.isVisible { hadVisibleWindow = true; return false }
            return hadVisibleWindow
        }
        func receivingStage() -> StageView? {
            guard let destination = window(), destination.isVisible,
                  let stage = web.superview as? StageView,
                  stage.shows == owner, web.window === destination,
                  !stage.isHiddenOrHasHiddenAncestor,
                  stage.bounds.width > 0, stage.bounds.height > 0 else { return nil }
            return stage
        }
        func waitForStage() {
            guard !finished else { return }
            attempt += 1
            let generation = attempt
            guard !cancelled(), !destinationClosed() else { finish(false); return }
            guard let stage = receivingStage() else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: waitForStage)
                return
            }
            stage.layoutSubtreeIfNeeded()
            let frame = web.frame
            attached(stage)
            func resolve(painted: Bool) {
                guard !finished, attempt == generation else { return }
                guard !cancelled(), !destinationClosed() else { finish(false); return }
                guard receivingStage() === stage, web.frame == frame else {
                    waitForStage()
                    return
                }
                finish(painted)
            }
            afterPageDrawing(web, requirePaint: true) { resolve(painted: true) }
            // A failed WebContent process can miss its callback. This bound
            // starts only after attachment and never uncovers another owner.
            // Expiry completes cleanup, but does not certify a presentation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { resolve(painted: false) }
        }
        waitForStage()
    }

    /// Off only for measuring what it saves (`split.cover` = off).
    static var covering = !(Store.testing && Store.settings.string(forKey: "split.cover") == "off")

    /// `done` once WebKit has put on screen what it draws next: a name
    /// outside WebKit's public framework, asked for before use. A turn
    /// requires a drawing barrier even when that selector is unavailable;
    /// existing veil callers keep their immediate fallback.
    static func afterNextDrawing(_ web: WKWebView, requirePaint: Bool = false, _ done: @escaping () -> Void) {
        let name = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard web.responds(to: name) else {
            guard requirePaint else { done(); return }
            // The turn cannot reveal an unpainted backing on this fallback
            // either. A one-point snapshot requests the same async drawing
            // barrier without retaining a full page image.
            let snapshot = WKSnapshotConfiguration()
            snapshot.afterScreenUpdates = true
            snapshot.snapshotWidth = 1
            web.takeSnapshot(with: snapshot) { image, error in
                if image != nil, error == nil { done() }
            }
            return
        }
        let block: @convention(block) () -> Void = done
        web.perform(name, with: block)
    }

    /// A nested transaction ending is not the outer transaction reaching
    /// the compositor. Use the same post-commit barrier WebKit uses for its
    /// backing stores, rather than an animation-completion callback (which
    /// can run immediately for an empty group or wait on unrelated motion).
    static func afterNextCommit(_ done: @escaping () -> Void) {
        let selector = NSSelectorFromString("addCommitHandler:forPhase:")
        guard let method = class_getClassMethod(CATransaction.self, selector) else {
            CATransaction.setCompletionBlock(done)
            return
        }
        typealias Commit = @convention(c) (AnyObject, Selector, @convention(block) () -> Void, UInt32) -> Void
        let call = unsafeBitCast(method_getImplementation(method), to: Commit.self)
        let block: @convention(block) () -> Void = done
        // kCATransactionPhasePostCommit, as declared by WebKit's QuartzCoreSPI.h.
        call(CATransaction.self as AnyObject, selector, block, 2)
    }

    /// What shows where a page held at its size falls short of its
    /// outline: WebKit's under-page color, the page's own below its content,
    /// unless it contradicts what the page drew. A dark site that never
    /// says so, GitHub, leaves it white, and a white band opened beside a
    /// dark page; then the top's color if it is as dark as the page, or a
    /// plain dark ground. Never the top's color first: an orange or navy
    /// bar is not what lies below a page.
    static func fill(under: NSColor?, shade: ColorScheme?, tone: NSColor?) -> NSColor {
        func light(_ color: NSColor) -> CGFloat {
            guard let rgb = color.usingColorSpace(.sRGB) else { return 0.5 }
            return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        }
        guard let under else { return tone ?? Palette.NS.ground }
        guard let shade, (shade == .dark) != (light(under) < 0.5) else { return under }
        // The top only when it is plainly as dark, or as light, as the page:
        // an orange bar is neither.
        if let tone, shade == .dark ? light(tone) < 0.25 : light(tone) > 0.75 { return tone }
        return shade == .dark ? NSColor(white: 0.11, alpha: 1) : .white
    }

    /// How many times a page has been made another size, for `bench pace`.
    static var resizes = 0
    /// And how many times a stage was laid out, each one a frame of its
    /// outline drawn from where it was: once per change of shape.
    static var layouts = 0

    /// Whether the page on show has its Web Inspector up. WebKit answers
    /// only through names outside its public framework, asked for before
    /// use (see Inspector.swift).
    private var inspecting: Bool {
        guard let web = wanted as? WKWebView else { return false }
        return Inspector.of(web).map { Inspector.asks($0, "isVisible") } ?? false
    }

    private static func isInspector(_ view: NSView) -> Bool {
        NSStringFromClass(type(of: view)).hasPrefix("WKInspector")
    }
}

/// What there is to say when the page never came. One line, and the only thing
/// worth offering, another go.
private struct Trouble: View {
    let message: String
    let retry: () -> Void

    @ObservedObject private var reload = Keymap.shared.slot(.reload)

    var body: some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Button(action: retry) {
                HStack(spacing: 6) {
                    Text("Try Again")
                    if let keys = reload.keys?.text {
                        KeyGlyphs(keys: keys, size: 12.5, tint: nil, rest: 0.6)
                            .transaction { $0.animation = nil }
                    }
                }
            }
            .buttonStyle(.yab(.secondary, .regular))
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
    }
}

/// Hands back the NSWindow once there is one. SwiftUI has no opinion about
/// traffic lights or title bars, and both need settling by hand here.
struct WindowSetup: NSViewRepresentable {
    var prepare: ((NSWindow) -> Void)? = nil
    let ready: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Probe(prepare: prepare, ready: ready) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        let prepare: ((NSWindow) -> Void)?
        let ready: (NSWindow) -> Void

        // Restored windows must not pick the first sidebar button (often
        // a tab's close button) as their initial keyboard target. This
        // invisible responder has no action and stays out of the Tab loop.
        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        init(prepare: ((NSWindow) -> Void)?, ready: @escaping (NSWindow) -> Void) {
            self.prepare = prepare
            self.ready = ready
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            WindowHosting.disableSizing(of: window)
            prepare?(window)
            window.initialFirstResponder = self
            if window.firstResponder == nil || window.firstResponder === window {
                window.makeFirstResponder(self)
            }
            // The window is still being put together at this point; anything
            // set now gets overwritten a moment later.
            DispatchQueue.main.async {
                guard self.window === window else { return }
                // SwiftUI finishes installing its scene host after attach.
                WindowHosting.ownFrame(of: window)
                window.initialFirstResponder = self
                // SwiftUI installs its own key-view proxy after attachment.
                // Reset that automatic choice once, without taking focus
                // from a field or page that already asked for the keyboard.
                if !(window.firstResponder is NSText),
                   !Self.onPage(window.firstResponder as? NSView) {
                    window.makeFirstResponder(self)
                }
                self.ready(window)
            }
        }

        private static func onPage(_ view: NSView?) -> Bool {
            guard let view else { return false }
            return view is WKWebView || onPage(view.superview)
        }
    }
}

/// Drag to move, double-click as on a title bar. Lifted from the canvas app,
/// with the title bar hidden the interface swallows the clicks a title bar
/// would have handled, and they have to be put back.
///
/// The strips are the window's only handles (WindowDrag): AppKit drags it by
/// nothing of its own. A drag is handed to the window server as a title
/// bar's is, so the screen's edges tile it, the Option key shows the tiles,
/// and a tiled window pulled away comes back to its own size. It used to
/// set the window's origin by hand, which no edge ever saw.
struct DragStrip: View {
    /// How much of the leading edge belongs to the tabs. A representable is a
    /// real view sitting under everything SwiftUI draws on top of it, and a
    /// real view takes the click first, so the run the tabs occupy is refused
    /// here and falls through to them.
    var reserved: CGFloat = 0
    /// Only the six-point air above and below the top-row pills.
    var tabAir = false
    /// Real controls in a toolbar, in this view's top-left coordinates.
    var exclusions: [CGRect] = []
    /// How much of the top belongs to whatever is drawn there, measured from
    /// the top edge. The column of tabs uses this the way the strip uses the
    /// leading run.
    var below: CGFloat = 0
    /// The run at the trailing end that belongs to a button.
    var trailing: CGFloat = 0
    /// Buttons standing in the strip rather than at its end, measured from
    /// its top trailing corner: only they are refused, so the strip goes on
    /// over them, under them and beside them.
    var notch: CGRect = .zero
    /// The same, measured from its top leading corner.
    var leadNotch: CGRect = .zero
    /// What a right click or a ⌃-click on it brings, made at the press: the
    /// column's room under its rows has the space's menu (SpaceMenu).
    var menu: (@MainActor () -> NSMenu)? = nil
    /// A context press may reach the room revealed by native scrolling,
    /// even while the unscrolled rows extend below the window.
    var contextTail: (@MainActor (NSPoint, NSView, NSEvent) -> Bool)? = nil
    /// An empty sidebar opens New Tab; title-bar strips keep the system action.
    var doubled: (@MainActor () -> Void)? = nil

    // Nothing to read or press: under the lights and the tabs, SwiftUI's
    // accessibility hit test stopped here and found neither.
    var body: some View { Host(strip: self).accessibilityHidden(true) }

    private struct Host: NSViewRepresentable {
        let strip: DragStrip

        func makeNSView(context: Context) -> Strip { Strip() }

        func updateNSView(_ view: Strip, context: Context) {
            view.reserved = strip.reserved
            view.tabAir = strip.tabAir
            view.exclusions = strip.exclusions
            view.below = strip.below
            view.trailing = strip.trailing
            view.notch = strip.notch
            view.leadNotch = strip.leadNotch
            view.made = strip.menu
            view.contextTail = strip.contextTail
            view.doubled = strip.doubled
        }
    }

    final class Strip: NSView, WindowHandle {
        var reserved: CGFloat = 0
        var tabAir = false
        var exclusions: [CGRect] = []
        var below: CGFloat = 0
        var trailing: CGFloat = 0
        var notch: CGRect = .zero
        var leadNotch: CGRect = .zero
        var made: (@MainActor () -> NSMenu)?
        var contextTail: (@MainActor (NSPoint, NSView, NSEvent) -> Bool)?
        var doubled: (@MainActor () -> Void)?

        private var press: NSEvent?
        private var moved = false
        private var firstClick: TimeInterval?

        override func menu(for event: NSEvent) -> NSMenu? {
            // AppKit asks here before mouseDown for a Control-click. Returning
            // the NSMenu starts its own tracking loop and preempts our existing
            // ActionMenu route below. Let that original mouseDown handle it.
            if event.type == .leftMouseDown, event.modifierFlags.contains(.control) { return nil }
            return made?()
        }

        // The space's menu, as the tab's is, in the searchable panel
        // (ActionMenu.swift).
        override func rightMouseDown(with event: NSEvent) {
            guard let menu = made?() else { return super.rightMouseDown(with: event) }
            ActionMenu.show(menu, from: self, with: event)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let inside = convert(point, from: superview)
            if tabAir, !StripPress.inTabAir(inside, bounds: bounds) { return nil }
            let topPoint = CGPoint(x: inside.x, y: bounds.height - inside.y)
            guard !exclusions.contains(where: { $0.contains(topPoint) }) else { return nil }
            guard inside.x >= reserved, inside.x <= bounds.width - trailing else { return nil }
            // AppKit measures up from the bottom; the reservation is from the top.
            if bounds.height - inside.y < below {
                guard bounds.contains(inside), made != nil,
                      let event = NSApp.currentEvent, event.window === window,
                      event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
                      contextTail?(inside, self, event) == true else { return nil }
            }
            guard !notch.contains(CGPoint(x: bounds.width - inside.x, y: bounds.height - inside.y)) else { return nil }
            guard !leadNotch.contains(CGPoint(x: inside.x, y: bounds.height - inside.y)) else { return nil }
            // The traffic lights are never the strip's, whichever of the two
            // SwiftUI's hit test chose: with the tabs across the top the
            // corner's strip took presses on the lights, and a click there
            // did nothing until a later one reached the button (register
            // #375, #392). Refused (nil), the press went to the hosting
            // view and still not to the light: the light itself answers.
            if let window, let light = LightsRow.button(at: convert(point, from: superview), from: self, in: window) { return light }
            return super.hitTest(point)
        }

        /// A window behind others is moved by its strip in one go, as by a
        /// title bar: the press that brings it forward starts the drag too.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control), let menu = made?() {
                firstClick = nil
                ActionMenu.show(menu, from: self, with: event)
                return
            }
            press = event
            moved = false
        }

        /// Past the slack, the press the drag began with goes to the window
        /// server once. The call returns immediately; later drag events
        /// must not start another system drag before the next press.
        override func mouseDragged(with event: NSEvent) {
            guard let window, let press, !moved else { return }
            let from = press.locationInWindow, now = event.locationInWindow
            guard StripPress.drags(now.x - from.x, now.y - from.y) else { return }
            moved = true
            firstClick = nil
            // In full screen there is nowhere to move it to.
            guard !window.styleMask.contains(.fullScreen) else { return }
            window.performDrag(with: press)
        }

        /// A double-click does what a title bar's does. It answered every
        /// click before, so a double-click filled the screen on the first
        /// click and put the window back on the second, and looked like
        /// nothing at all.
        override func mouseUp(with event: NSEvent) {
            defer { press = nil }
            if let doubled {
                guard let press, !moved else { firstClick = nil; return }
                let first = firstClick
                firstClick = event.clickCount == 1 ? event.timestamp : nil
                // Both clicks must have reached this empty area. A row's
                // first click followed by a second just outside it is not one.
                if event.clickCount == 2, let first,
                   press.timestamp - first <= NSEvent.doubleClickInterval {
                    doubled()
                }
                return
            }
            guard let window, !moved, event.clickCount == 2 else { return }
            StripPress.twice(window)
        }
    }
}

/// A site this Mac can't vouch for, in place of the site: what is wrong in
/// words, Go Back as the one dark button, and going on kept behind Details,
/// a line of text rather than a button as heavy as the way back.
private struct UntrustedPage: View {
    @ObservedObject var tab: Tab
    let untrusted: Untrusted
    @State private var opened = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            shape.fill(Palette.ink.opacity(0.05))
                .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
                .overlay { Symbol("exclamationmark.shield", size: 17).foregroundStyle(ButtonCSS.danger) }
                .frame(width: CardFrame.well, height: CardFrame.well)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(untrusted.host) may not be who it says")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(untrusted.why), so this Mac can’t tell who is on the other end. Someone could read or change what you send here.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Go Back") { back() }
                    .buttonStyle(.yab(.primary, .regular))
                if !opened {
                    Button("Details") { withAnimation(Motion.morph) { opened = true } }
                        .buttonStyle(.yab(.quiet, .regular))
                }
            }
            if opened {
                VStack(alignment: .leading, spacing: 6) {
                    if !untrusted.names.isEmpty {
                        Text(untrusted.names)
                    }
                    Text("Yab will trust this certificate on port \(untrusted.url.port ?? 443) until it changes.")
                    Button("Continue to \(untrusted.host)") { onward() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.ink)
                        .underline()
                        .disabled(untrusted.exception == nil)
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
        .frame(width: 400, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
    }

    private func back() {
        tab.untrusted = nil
        if tab.canGoBack { tab.back() }
    }

    private func onward() {
        tab.continuePastUntrusted()
    }
}

/// A site on the local phishing list (SafeBrowsing, opt-in), in place of
/// the site: what the list says in words, Go Back as the one dark button,
/// and going on kept behind Details, for this session.
private struct FlaggedPage: View {
    @ObservedObject var tab: Tab
    let flagged: Flagged
    @State private var opened = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            shape.fill(Palette.ink.opacity(0.05))
                .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
                .overlay { Symbol("exclamationmark.shield", size: 17).foregroundStyle(ButtonCSS.danger) }
                .frame(width: CardFrame.well, height: CardFrame.well)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(flagged.host) is on a phishing list")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Sites on it pretend to be someone else to take passwords and card numbers. If you know this one and it is safe, you can go on; nothing is sent to anyone either way.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Go Back") { back() }
                    .buttonStyle(.yab(.primary, .regular))
                if !opened {
                    Button("Details") { withAnimation(Motion.morph) { opened = true } }
                        .buttonStyle(.yab(.quiet, .regular))
                }
            }
            if opened {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The list is downloaded whole to this Mac and checked here; Yab sends no page or visit to check it. Going on keeps this site until Yab quits.")
                    Button("Continue to \(flagged.host)") { onward() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.ink)
                        .underline()
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
        .frame(width: 400, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
    }

    private func back() {
        tab.backFromFlagged()
    }

    private func onward() {
        tab.continuePastFlagged()
    }
}

private extension CGFloat {
    var nonzero: CGFloat? { self > 0 ? self : nil }
}

/// What Safari leaves where a video was when it is playing in picture in
/// picture, as WebKit draws it (modern-media-controls placard.css, PiPPlacard):
/// black, its mark and one line in a grey of 164, the line at 13, ten under
/// the mark, kept to 402 wide with 10 each side.
private struct AwayPlacard: View {
    var call: Bool

    private static let ink = Color(white: 164 / 255)

    var body: some View {
        VStack(spacing: 10) {
            PiPPlacardMark()
                .fill(Self.ink)
                .frame(width: 115, height: 90)
            Text(call ? "This call is playing in picture in picture." : "This video is playing in picture in picture.")
                .font(.system(size: 13))
                .foregroundStyle(Self.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 10)
                .frame(maxWidth: 402)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

/// WebKit's pip-placard image, traced off its 2x drawing (a mean 0.27 of
/// 255 from it, pixel by pixel): a window, 106 by
/// 80 with a stroke of 4, cut 3 clear round a smaller one, 50 by 38, in its
/// bottom right corner and standing past it.
private struct PiPPlacardMark: Shape {
    func path(in rect: CGRect) -> Path {
        let x = rect.width / 115, y = rect.height / 90
        func box(_ left: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: rect.minX + left * x, y: rect.minY + top * y, width: width * x, height: height * y)
        }
        let stroke = StrokeStyle(lineWidth: 4 * x)
        let big = Path(roundedRect: box(2, 2, 102, 76), cornerRadius: 4 * x, style: .continuous) // design: traced off WebKit's drawing
            .strokedPath(stroke)
        let hole = Path(roundedRect: box(62, 49, 56, 44), cornerRadius: 6.5 * x, style: .continuous) // design: traced off WebKit's drawing
        let small = Path(roundedRect: box(67, 54, 46, 34), cornerRadius: 1.5 * x, style: .continuous) // design: traced off WebKit's drawing
            .strokedPath(stroke)
        return big.subtracting(hole).union(small)
    }
}
