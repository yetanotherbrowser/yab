import Combine
import SwiftUI

/// The put-away column out over the page as a card, and how the column
/// looks while it is out of its place (Browser.sidePeek, sideCard). An
/// object of its own: as two of the browser's, every view watching the
/// browser, the whole window, was drawn again when the edge brought the
/// card out, and again when it let it go, before the card could move.
@MainActor
final class SidePeek: ObservableObject {
    @Published var out = false
    @Published var card = false
    /// The next change of `out` slides, though it comes with no animation
    /// (Brim.bring, ColumnView.peek).
    var sliding = false
}

/// The put-away strip out over the page, and how it looks while it is out
/// of its place (Browser.stripPeek, stripCard), with the tabs across the
/// top. Its own object for the same reason as SidePeek: as two of the
/// browser's, the edge bringing the strip out drew the whole window again
/// twice before the strip could move. Only the strip, the window's drag
/// strip and the downloads button watch it.
@MainActor
final class StripPeek: ObservableObject {
    @Published var out = false
    @Published var card = false
}

/// The band with the lights over the page, beside a column on the right
/// (HeadBand, Browser.headOut and headShown). Its own object for the same
/// reason as the strip's and the column's: as the browser's, the band coming
/// out drew the whole window again in the frame the page was to start
/// moving, a pass long enough to drop that frame. Only the band and the
/// page column's offset (HeadSunk) watch it.
@MainActor
final class HeadPeek: ObservableObject {
    /// Asked out: what the edge and the band's clicks go by, at once.
    @Published var out = false
    @Published var shown = false
    /// The page column laid out down under the band. It follows `out` once
    /// Core Animation has carried the page there (Browser.moveHead), so the
    /// window is laid out again when nothing is moving.
    @Published var sunk = false
    /// How far down that is, as the column last worked it out (HeadSunk):
    /// what the page is carried by. Not published; nothing draws from it.
    var sink: CGFloat = 0
}

/// The column of tabs down the left, as one surface at every size it takes.
///
/// Docked, it is part of the window: flush with its left edge, its outer
/// corners the window's own, the page laid beside it. Put away, or in full
/// screen, where it is never docked, it waits past the left edge, and comes
/// in over the page as a card: flush with the window's edge, its outer
/// corners the window's own (Metrics.floatInset), with a hairline and a
/// shadow to lift it off the page; the page stays as it is under it,
/// undimmed.
///
/// The card and the docked column are the same view, never one swapped for
/// the other. Pinning the card grows it into its place in the window, the
/// inner corners squaring against the page, the shadow going
/// while the page makes room in the same beat; putting the column away
/// takes the same path back, into the card and then out past the edge. The
/// way a tray grows into the full screen and back: one surface at two
/// sizes.
///
/// Coming in from the edge it arrives whole and already composed, and does
/// nothing on the way but travel. Put away, it leaves as it was, flush,
/// flat, the page taking its room, rather than stopping as a card first. The springs are the caller's: arriving,
/// leaving and reshaping each have their own (see Motion).
struct Column: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var peek: SidePeek
    /// In the window beside the page, rather than over it.
    let docked: Bool
    /// The backdrop the column wears, if there is one: docked, it sits on
    /// the window's; brought out over the page as a card, it carries the
    /// same color, grain and transparency on a ground of its own, as Arc's
    /// does (`ground`).
    let tone: Tone?
    /// Edge to edge with the column put away, where the window wears no
    /// color and `tone` is nil: the space's look for the column out over
    /// the page as a card, as Arc's sidebar wears its space's theme
    /// (feedback #165). Docked, the window wears it under the column and
    /// `tone` is set, as on a color (Preferences.edgeBackdrop, #256).
    var card: Tone? = nil
    /// Slid in and out by Core Animation (`ColumnView`), not by SwiftUI:
    /// the offset lands at once and the view it is in draws the way there.
    var carried = false
    /// The words worn on the site's color, when they aren't `tone`'s own
    /// (ColumnRoot.ink).
    var ink: Tone? = nil
    @Environment(\.colorScheme) private var scheme

    /// What the column paints under its rows itself. Docked, nothing: the
    /// window's backdrop shows through it. As a card over the page, the
    /// backdrop's color, so a column put away and brought out by the edge
    /// keeps the window's look rather than a plain white or black card.
    /// Nil with no backdrop: the card then draws the ground as it always has.
    static func ground(floating: Bool, tone: Tone?) -> Tone? {
        floating ? tone : nil
    }

    /// The card's ground as paint: on a color, the window's own, worked out
    /// as SpaceWash works it out, so a switch hands the card the same paint
    /// it hands the window; on a site's color, that color.
    static func paint(_ ground: Tone, prefs: Preferences, privateWindow: Bool = false) -> SpaceWash.Paint {
        if privateWindow { return SpaceWash.Paint(color: ContentView.privateBackdrop, grain: prefs.grain) }
        if let worn = SpaceWash.card(prefs) { return worn }
        return SpaceWash.Paint(color: ground.page, grain: prefs.grain, transparency: prefs.wornTransparency(dark: ground.scheme == .dark),
                               glass: prefs.wearsGlass)
    }

    var body: some View {
        let out = docked || peek.out
        // A card while brought out over the page, and flush the rest of the
        // time, so a column put away leaves as it was, and one brought back
        // in from past the edge arrives as it will be.
        let floating = !docked && peek.card
        let inset = floating ? Metrics.floatInset : 0
        // Docked, it is as wide as the window gives it, less while the
        // edge is being pulled; floating, it is always its full width.
        // Changing sides, it keeps its whole width either way: it is only
        // fading, and the page makes room for it on its own.
        let width = docked && !browser.turning ? browser.sideShown : prefs.sideWidth
        let flank = browser.flank
        // Past the edge by its own width, its inset and its shadow.
        let away = -(prefs.sideWidth + Metrics.floatInset + 40) * flank.sign
        // Its outer corners are the window's, against the window's edge,
        // docked or floating alike: flush with it (Metrics.floatInset), the
        // window server rounds them, and a cut of its own on that edge
        // never agrees with the window's. Between the two curves lay what
        // is under the column: docked, the window's ground (#221); out over
        // the page, the page itself, a white arc at both outer corners on a
        // white site (register 368). The inner ones face the page: floating,
        // the window's radius (Metrics.floatCorner), so the island's capsule
        // at its foot sits in the same curve as in the window's (Band.edge).
        let outer: CGFloat = 0
        let inner = floating ? Metrics.floatCorner : 0
        let left = flank == .left
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: left ? outer : inner, bottomLeadingRadius: left ? outer : inner,
            bottomTrailingRadius: left ? inner : outer, topTrailingRadius: left ? inner : outer,
            style: .continuous
        )
        let corner = Alignment(horizontal: flank.horizontal, vertical: .top)
        // Edge to edge and put away, where the window wears no color, the
        // column wears its space's look on a ground of its own, out and on
        // the way between alike, as Arc's sidebar always wears its theme.
        let ground = tone == nil ? card : Self.ground(floating: floating, tone: tone)
        let paint = ground.map { Self.paint($0, prefs: prefs, privateWindow: browser.windowPurpose == .privateOnly) }
        // What the card's own hairline and the island at its foot are
        // drawn on: the window's backdrop, or edge to edge the column's.
        let worn = tone ?? card

        ZStack(alignment: corner) {
            SideBar(browser: browser, prefs: prefs, floating: floating)
                // Every size in it comes from the density (Density): drawn
                // anew when it changes, rows the column keeps included.
                .id(prefs.density)
                .background(ChorusInk(chorus: browser.chorus))
                // Put away, it keeps the look it had in its place while it
                // goes: a column that took on its own ground on the way out
                // flashed white past a dark site's page. Out over the page
                // as a card, it wears the backdrop on a ground of its own,
                // in the words a see-through one keeps (Tone.card).
                .toned(ground.map { $0.card(paint) } ?? ink ?? tone)
                // In Core Animation, turned with the window's when the space
                // changes, on the row's spring (CardGround, SpaceWash).
                .background {
                    ZStack {
                        if let paint { ownGround(paint) }
                    }
                    // Taken or given back at once when Window changes, with
                    // the window's ground (ContentView): faded, it let the
                    // desktop through the column midway. A ZStack, as there.
                    .animation(nil, value: prefs.backdrop)
                }
                .frame(width: width, alignment: flank.alignment)
                .overlay(alignment: left ? .trailing : .leading) {
                    // Docked and pulled in, the column's own hairline is cut
                    // off with the rest of it; the page's edge keeps one.
                    if docked, width < prefs.sideWidth, worn == nil {
                        Rectangle().fill(Palette.ink.opacity(0.05)).frame(width: 1)
                    }
                }
                // Round a card in a color of its own, a hairline, as Arc
                // draws a rim round its sidebar out over the page, edge to
                // edge too; on the plain ground the card is lifted by its
                // shadow alone, a hairline there a frame drawn on the page.
                // In the card's own ink, thinly: the app's hairline is
                // neutral-200 in light mode, a white ring round a dark card
                // over a dark page. Not on its outer side: that edge is
                // the window's, so the line runs past it, cut off with the
                // card.
                .overlay(shape.strokeBorder(Palette.ink.opacity(0.1), lineWidth: 1)
                    .padding(left ? .leading : .trailing, -Metrics.floatBleed)
                    .toned(ink ?? worn)
                    .opacity(floating && (prefs.backdrop != .none || worn != nil) ? 1 : 0))
                .clipShape(shape)
                // Past its outer edge, its own ground a little further, out
                // of sight at rest: the spring that brings the card in
                // carries it 2% past its place (CardMotion), and in that
                // gap at the window's edge lay the page, a white strip on a
                // white site (register 368).
                .background(alignment: flank.alignment) {
                    if floating, let paint {
                        ownGround(paint)
                            .frame(width: Metrics.floatBleed)
                            .offset(x: -Metrics.floatBleed * flank.sign)
                    }
                }
                // One native handle belongs to the column in both modes.
                // A second handle in the window's host could keep its old
                // geometry while this host resized or became a card.
                .overlay(alignment: left ? .trailing : .leading) {
                    if out {
                        SideEdge(browser: browser, prefs: prefs, floating: floating)
                            .offset(x: Metrics.edgeReach / 2 * flank.sign)
                            .transition(.identity)
                    }
                }
                // Above the column's clip and hairlines: open, the island
                // can stand over its edge without the border crossing its
                // card or its controls (PlayerBand.swift).
                .overlay(alignment: left ? .bottomLeading : .bottomTrailing) {
                    BandSlot(player: browser.player, prefs: prefs, room: browser.player.room, column: width, trailing: !left, edge: browser.bandEdge, foot: !ColumnKit.cut.contains("foot"))
                        .toned(ink ?? worn)
                        // The island stands outside the rows' clip, so it
                        // also needs their fade under the downloads stack.
                        .modifier(HoardHush(hoard: browser.hoard))
                }
                .compositingGroup()
                .shadow(color: .black.opacity(floating && out ? 0.14 : 0), radius: 24, x: 0, y: 8)
                .padding(left ? .leading : .trailing, inset)
                .padding(.vertical, inset)
                .padding(.top, browser.menuDown)
                .offset(x: carried ? 0 : out ? 0 : away)
                .transaction(value: out) { if carried { $0.animation = nil } }
                .allowsHitTesting(out)
                .accessibilityHidden(!out)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
        .ignoresSafeArea()
        // Put away, it changes sides out of sight: from past one edge
        // straight to past the other. On Settings' glide it flew across
        // the whole window to get there, a column nobody had asked to see.
        .transaction(value: flank) { if !out { $0.animation = nil } }
    }

    /// The column's own ground in its paint.
    @ViewBuilder private func ownGround(_ paint: SpaceWash.Paint) -> some View {
        if tone == nil {
            // Edge to edge the column is the only thing wearing the look,
            // so Shift with tabs and Take the site's color turn and tint
            // it, as they do the window on a color (LookWorn).
            LookWorn(browser: browser) { site, step in
                CardGround(paint: SpaceWash.sited(paint, prefs: prefs, site: site), step: step).environment(browser)
            }
        } else {
            CardGround(paint: paint).environment(browser)
        }
    }
}

/// The column in a view of its own, so that its coming in from the edge and
/// going out past it are Core Animation's, one commit and the render server
/// draws the rest, as the page beside it is carried (see `Reshape`). Slid
/// by SwiftUI, every frame was a commit of the main thread's; on a busy Mac
/// each of those could wait on the window server, and the rows stood still
/// while the page went under them, or the column was left half drawn until
/// the page's new size had been laid out.
///
/// The view covers the window from its top left, as the column did in it,
/// so everything the column says in window space (`.global`) is where it
/// was, and takes clicks only where the column is.
struct ColumnHost: NSViewRepresentable {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    func makeNSView(context: Context) -> ColumnView { ColumnView(browser: browser) }

    /// As big as it is given, the window: asked by SwiftUI in every pass,
    /// and left to AppKit to answer, it measured the whole column through
    /// the hosting view inside, about a tenth of a switch of tab.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ColumnView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ view: ColumnView, context: Context) {
        let moving = context.transaction.animation != nil && !context.transaction.disablesAnimations
        view.slide(out: !prefs.sideShut || browser.peek.out, animated: moving)
    }
}

final class ColumnView: NSView {
    private typealias Host = ColumnHoverHost<ColumnRoot>
    private let host: Host
    private weak var browser: Browser?
    private var out: Bool?
    private var slides = 0
    private var peeking: AnyCancellable?

    init(browser: Browser) {
        self.browser = browser
        host = Host(rootView: ColumnRoot(browser: browser, prefs: browser.prefs))
        host.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        host.autoresizingMask = [.width, .height]
        // It takes the window's size, never gives one: no size of its own
        // worked out from the column for AppKit to ask about.
        host.sizingOptions = []
        // No safe area: the column lays itself out from the window's top
        // (Metrics.strip). With the title bar's, the rows' scroll view,
        // which reaches up under the lights past it, grew up into it from
        // the card brought out over the page, 8 points down from the top,
        // and took the rows up with it, flush under the pins.
        host.safeAreaRegions = []
        addSubview(host)
        browser.column = self
        // The card in or out as the edge has it (Brim.bring): slid from the
        // change itself. Slid from the window's pass (updateNSView) it slid
        // nothing, and the card came and went in one frame: the column's own
        // host watches the card too, and a host inside another watching the
        // same object makes the outer one run again inside the change, with
        // the value from before it (as the chat column's and AskView's hosts
        // found), so `sliding` went on a pass with nothing to slide. Any
        // other change of it, with the window's mode or ⌘S, is only noted
        // here; ⌘S's own pass slides.
        peeking = browser.peek.$out.dropFirst().sink { [weak self] out in
            MainActor.assumeIsolated { self?.peek(out) }
        }
    }

    private func peek(_ value: Bool) {
        guard let browser, !browser.folding else { return }
        let sliding = browser.peek.sliding
        browser.peek.sliding = false
        slide(out: !browser.prefs.sideShut || value, animated: sliding)
    }

    /// Out and in a window: its rows are on screen.
    var shown: Bool { out == true && window != nil }

    /// Rows of the column, in its SwiftUI space, gone to dust over it.
    func dust(_ rows: [DustRow], renaming: Bool = false) -> Bool {
        Dust.shared.play(rows: rows, host: host, over: self, renaming: renaming)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    /// Only the column takes clicks; the rest of the window is the page's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let browser, let out, out else { return nil }
        let prefs = browser.prefs
        let local = convert(point, from: superview)
        let docked = !prefs.sideShut
        // Out over the page, its edge reaches half its width past it.
        let width = (docked ? browser.sideShown : Metrics.floatInset + prefs.sideWidth) + Metrics.edgeReach / 2
        // From the edge the column is on.
        let x = browser.flank == .left ? local.x : bounds.width - local.x
        guard x >= 0 else { return nil }
        // The island's open card may stand out over the page from the
        // column's foot: there it takes the pointer where its glass is.
        guard x <= width else {
            let hit = super.hitTest(point)
            return hit is BandView ? hit : nil
        }
        return super.hitTest(point)
    }

    // MARK: - the spaces sliding (SpacePager)

    /// The space's own part of the column, its pins, its name and its rows
    /// from under the plate to over the foot, in the column's flipped
    /// space: nil while the column hasn't said where they are.
    func spaceBand(_ browser: Browser) -> CGRect? {
        guard let rows = browser.rowsClip, let floor = browser.spaceFloor else { return nil }
        let top = min(browser.pinsTop ?? rows.minY, browser.nameTop ?? rows.minY, rows.minY)
        guard floor > top else { return nil }
        return CGRect(x: rows.minX, y: top, width: rows.width, height: floor - top).integral
    }

    /// How far down `band` its part under the pins starts, the space's name
    /// or its rows: all that slides while the pins stand still, the same in
    /// every space it goes past (SpacePager.hold). Nil with no pins.
    func underPins(_ browser: Browser, in band: CGRect) -> CGFloat? {
        guard browser.pinsTop != nil, let rows = browser.rowsClip else { return nil }
        let under = min(browser.nameTop ?? rows.minY, rows.minY).rounded(.down) - band.minY
        return under > 0 && under < band.height ? under : nil
    }

    /// The column as drawn in `band`, its own layers only: the window's
    /// color under it stays out.
    func picture(_ band: CGRect) -> CGImage? { picture(band, card: nil).image }

    /// All the column draws in `rect`, as it stands: the head's doors, for
    /// their own row while the spaces slide (PagerStage.doorsRow).
    /// `bare`: the column's own ground left out (`ownGrounds`), for a
    /// row laid over a ground of its own that turns with the window.
    func pictureAll(_ rect: CGRect, bare: Bool = false) -> CGImage? {
        guard let layer = host.layer else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int((rect.width * scale).rounded()), height = Int((rect.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Turned over and brought to the corner, as `picture` does.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: rect.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        let hidden = bare ? ownGrounds : []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hidden.forEach { $0.isHidden = true }
        Bench.render(layer, in: context)
        hidden.forEach { $0.isHidden = false }
        CATransaction.commit()
        return context.makeImage()
    }

    /// The layers of the column's own ground, its look's color, gradient,
    /// grain and drawings (CardGround) and frost: edge to edge the docked
    /// column wears them itself, as a card does (Column.card).
    var ownGrounds: [CALayer] { (cardFrosts + cardGrounds).compactMap(\.layer) }

    /// The same, and for a `card` (where it stands, in the column's
    /// space), its ground left out (its frost, tint, color and grain:
    /// `grounds`): drawn by `render(in:)` a see-through card's frost came
    /// out an opaque gray, far darker than on screen, and a ground carried
    /// by each page left a seam between them as they slid. `dropped` says
    /// it was found and left out; it is laid back under the row, live
    /// (SpacePager). The card's hairline down either edge is left out too:
    /// it stays live, and pictured it slid in over the next space as a line.
    ///
    /// What the head and the foot draw into the band, their shadows, is
    /// left out of it and pictured apart (`beside`), to stand still over
    /// the row (PagerStage): in the space's picture it slid away with the
    /// space, the foot's buttons' shadows a dark smudge over the next
    /// space's foot and gone from over their own.
    ///
    /// `own`: docked edge to edge, the column's ground is its own too
    /// (Column.card), left out the same way, with no hairline to keep. Kept
    /// in, each page carried its space's look and the row slid them past
    /// each other with a seam, the window's color still until it landed.
    func picture(_ band: CGRect, card: CGRect?, own: Bool = false) -> (image: CGImage?, dropped: Bool, beside: CGImage?) {
        guard let layer = host.layer else { return (nil, false, nil) }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int((band.width * scale).rounded()), height = Int((band.height * scale).rounded())
        // In the window's own color space and the render server's byte
        // order: in sRGB RGBA, every switch converted it on the main thread
        // as it was committed (CA::Render::copy_image).
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return (nil, false, nil) }
        // The host's layer draws y down, as its rows are measured (Dust's
        // Snapshot): turned over, and the band brought to the corner.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: band.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -band.minX, y: -band.minY)
        // The plain ground SwiftUI lays, the frost (a view of its own), and
        // the color, gradient and grain over it (CardGround's own view).
        let ground = card.map { Self.grounds(in: layer, card: $0) + ownGrounds } ?? (own ? ownGrounds : [])
        // And what is there but not seen: drawn by `render(in:)`, the glass
        // of the Now Playing island put away (PlayerBand) came out under its
        // own clear.
        let unseen = Self.unseen(in: layer)
        let parts = Self.split(layer, band: band)
        func draw(hiding: [CALayer]) -> CGImage? {
            context.clear(band)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hiding.forEach { $0.isHidden = true }
            Bench.render(layer, in: context)
            hiding.forEach { $0.isHidden = false }
            CATransaction.commit()
            if card != nil {
                context.clear(CGRect(x: band.minX, y: band.minY, width: PagerStage.rim, height: band.height))
                context.clear(CGRect(x: band.maxX - PagerStage.rim, y: band.minY, width: PagerStage.rim, height: band.height))
            }
            return context.makeImage()
        }
        let image = draw(hiding: ground + unseen + parts.outside)
        // Only what stands beside the band and casts into it, each drawn
        // on its own where it stands. Drawn as the column with the band's
        // own layers hidden, a layer holding both kinds kept what it drew
        // itself: with glass or a see-through window (a shadow somewhere in
        // the head) the space's name, its pins or rows stood still over the
        // row as it slid, the next space's drawn through them (a tester,
        // 2026-10-10: "the tabs sort of overlap").
        var beside: CGImage?
        if !parts.casting.isEmpty {
            context.clear(band)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for part in parts.casting {
                let origin = part.convert(part.bounds.origin, to: layer)
                var alpha: Float = 1
                var up = part.superlayer
                while let at = up, at !== layer { alpha *= at.opacity; up = at.superlayer }
                context.saveGState()
                context.setAlpha(CGFloat(alpha))
                context.translateBy(x: origin.x - part.bounds.minX, y: origin.y - part.bounds.minY)
                Bench.render(part, in: context)
                context.restoreGState()
            }
            CATransaction.commit()
            beside = context.makeImage()
        }
        return (image, !ground.isEmpty, beside)
    }

    /// The layers under `root` that draw the band's own (`inside`: in it,
    /// or across its edge with nothing of their own beside it) and those
    /// that stand beside it, the head's and the foot's (`outside`), and
    /// those of them that cast a shadow, which falls into the band.
    static func split(_ root: CALayer, band: CGRect) -> (inside: [CALayer], outside: [CALayer], casting: [CALayer]) {
        var inside: [CALayer] = [], outside: [CALayer] = [], casting: [CALayer] = []
        func casts(_ layer: CALayer) -> Bool {
            if layer.isHidden || layer.opacity == 0 { return false }
            if layer.shadowOpacity > 0 || layer.filters?.isEmpty == false { return true }
            return layer.sublayers?.contains(where: casts) ?? false
        }
        func walk(_ layer: CALayer) {
            if layer.isHidden || layer.opacity == 0 { return }
            let frame = layer.convert(layer.bounds, to: root)
            if frame.maxY <= band.minY + 0.5 || frame.minY >= band.maxY - 0.5 || frame.maxX <= band.minX + 0.5 || frame.minX >= band.maxX - 0.5 {
                outside.append(layer)
                if casts(layer) { casting.append(layer) }
                return
            }
            guard let below = layer.sublayers, !below.isEmpty, !band.contains(frame) else {
                inside.append(layer)
                return
            }
            below.forEach(walk)
        }
        root.sublayers?.forEach(walk)
        return (inside, outside, casting)
    }

    /// A card's ground under `root`, as SwiftUI lays it out: in the card's
    /// own layer (as big as the card, where it stands), the bare layers as
    /// big as it before the first of the column's own (with no backdrop,
    /// the plain ground). The frost, and the color, the gradient and the
    /// grain, are views of their own (`cardFrosts`, `cardGrounds`).
    static func grounds(in root: CALayer, card: CGRect) -> [CALayer] {
        func near(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
        }
        func find(_ layer: CALayer, depth: Int) -> CALayer? {
            if near(layer.frame, card), (layer.sublayers?.count ?? 0) > 1 { return layer }
            guard depth < 3 else { return nil }
            for sub in layer.sublayers ?? [] { if let found = find(sub, depth: depth + 1) { return found } }
            return nil
        }
        guard let own = (root.sublayers ?? []).lazy.compactMap({ find($0, depth: 0) }).first else { return [] }
        var found: [CALayer] = []
        for layer in own.sublayers ?? [] {
            guard near(layer.bounds, own.bounds), layer.sublayers?.isEmpty ?? true, !(layer.delegate is NSView), !layer.isHidden else { break }
            found.append(layer)
        }
        return found
    }

    /// The card's grounds in the column (CardGround), wherever SwiftUI put
    /// their views.
    var cardGrounds: [CardGroundView] { shown(CardGroundView.self) }

    /// Their frosts, likewise (BackdropVeil.Frost).
    var cardFrosts: [CardFrostView] { shown(CardFrostView.self) }

    private func shown<View: NSView>(_ kind: View.Type) -> [View] {
        func walk(_ view: NSView) -> [View] {
            if let found = view as? View { return found.isHiddenOrHasHiddenAncestor ? [] : [found] }
            return view.subviews.flatMap(walk)
        }
        return walk(host)
    }

    /// The layers under `root` drawn clear: on screen nothing, though a
    /// picture of them by `render(in:)` may show their glass.
    static func unseen(in root: CALayer) -> [CALayer] {
        var found: [CALayer] = []
        func walk(_ layer: CALayer) {
            if layer.isHidden { return }
            if layer.opacity == 0 {
                found.append(layer)
                return
            }
            layer.sublayers?.forEach(walk)
        }
        walk(root)
        return found
    }

    /// The material layers under `root`: a see-through ground's frost.
    static func frosts(in root: CALayer) -> [CALayer] {
        var found: [CALayer] = []
        func walk(_ layer: CALayer) {
            if layer.isHidden { return }
            if NSStringFromClass(type(of: layer)).contains("Backdrop") || layer.delegate is NSVisualEffectView {
                found.append(layer)
                return
            }
            layer.sublayers?.forEach(walk)
        }
        walk(root)
        return found
    }

    /// How many frosts the column has now, and how many layers a card's
    /// ground is, for the bench.
    var frostCount: Int { host.layer.map { Self.frosts(in: $0).count } ?? 0 }
    func groundCount(_ card: CGRect) -> Int { host.layer.map { Self.grounds(in: $0, card: card).count } ?? 0 }

    /// Whether `layer` is the one a PagerStage draws into: a layer-backed
    /// view is its layer's delegate, so the stage is found through that.
    static func isPagerLayer(_ layer: CALayer) -> Bool {
        (layer.delegate as AnyObject?) is PagerStage
    }

    /// What of the window draws in `band` while the column's own drawing of
    /// it is masked, and is neither the pages over it nor under the mask:
    /// what would show through the row of spaces sliding. For the bench.
    func leaks(_ band: CGRect) -> [[String: Any]] {
        guard let root = window?.contentView?.superview?.layer, let mine = host.layer else { return [] }
        var found: [[String: Any]] = []
        func walk(_ layer: CALayer, masked: Bool) {
            if layer.isHidden || layer.opacity < 0.01 || found.count > 40 { return }
            if Self.isPagerLayer(layer) { return }
            let masked = masked || (layer === mine && layer.mask != nil)
            let frame = layer.convert(layer.bounds, to: mine)
            let draws = layer.contents != nil || (layer.backgroundColor.map { $0.alpha > 0.01 } ?? false) || layer is CATextLayer
            if !masked, draws, frame.intersects(band), frame.width < band.width * 3, frame.height < band.height * 3 {
                found.append(["class": NSStringFromClass(type(of: layer)), "view": layer.delegate.map { "\(type(of: $0))" } ?? "",
                              "frame": [frame.minX, frame.minY, frame.width, frame.height].map { Double($0.rounded()) },
                              "under_column": sequence(first: layer, next: { $0.superlayer }).contains { $0 === mine }])
            }
            layer.sublayers?.forEach { walk($0, masked: masked) }
        }
        walk(root, masked: false)
        return found
    }

    /// The pages laid over the column.
    /// The column told where the pointer is, as a move to where it already
    /// is: the pages that slid over it gone, its plate, its rows and the
    /// column's own `near` hear nothing until the hand next moves, and lit
    /// only then, a beat after the row landed (the plate's doors and the
    /// row under the pointer popping in, 2026-10-13). The host hears it, and
    /// the row's own host under the pointer (ColumnPages' cells).
    func rehover() {
        guard let window, window.isVisible else { return }
        let at = window.mouseLocationOutsideOfEventStream
        guard NSPointInRect(convert(at, from: nil), bounds),
              let moved = NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: NSEvent.modifierFlags,
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        else { return }
        host.mouseMoved(with: moved)
        if let hit = superview?.hitTest(superview?.convert(at, from: nil) ?? at), hit !== host, hit.isDescendant(of: self) {
            hit.mouseMoved(with: moved)
        }
    }

    func raise(_ stage: PagerStage) {
        stage.frame = bounds
        stage.autoresizingMask = [.width, .height]
        addSubview(stage, positioned: .above, relativeTo: host)
    }

    /// The column's own drawing of `band` hidden, the rest of it as it is;
    /// nil shows all of it again.
    func maskSpace(_ band: CGRect?, also: CGRect? = nil) {
        guard let layer = host.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let band else {
            layer.mask = nil
            return
        }
        let mask = CAShapeLayer()
        mask.frame = layer.bounds
        // Far past the window on every side, for the island's card out over
        // the page, with the band cut out of it.
        let path = CGMutablePath()
        path.addRect(layer.bounds.insetBy(dx: -4000, dy: -4000))
        path.addRect(band)
        // Apart from the band, or the even-odd fill shows their overlap.
        if let also { path.addRect(also) }
        mask.path = path
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        layer.mask = mask
    }

    /// Where the column's view and its host are, and how their layers
    /// stand, for the bench: a column that is there yet draws nothing.
    var benchState: [String: Any] {
        func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }
        func describe(_ layer: CALayer?) -> [String: Any] {
            guard let layer else { return ["none": true] }
            let shown = layer.presentation() ?? layer
            return ["frame": rect(layer.frame), "shown_frame": rect(shown.frame), "opacity": Double(layer.opacity),
                    "shown_opacity": Double(shown.opacity), "hidden": layer.isHidden, "masked": layer.mask != nil,
                    "transform": !CATransform3DIsIdentity(layer.transform), "animations": layer.animationKeys() ?? [],
                    "sublayers": layer.sublayers?.count ?? 0]
        }
        var chain: [[String: Any]] = []
        var view: NSView? = self
        while let v = view, v !== window?.contentView?.superview {
            chain.append(["view": "\(type(of: v))", "hidden": v.isHidden, "alpha": Double(v.alphaValue), "frame": rect(v.frame),
                          "layer": describe(v.layer)])
            view = v.superview
        }
        func placed(_ child: CALayer?, in parent: CALayer?) -> [Double] {
            guard let child, let parent else { return [] }
            return rect(child.convert(child.bounds, to: parent))
        }
        return ["id": "\(ObjectIdentifier(self).hashValue)", "window": window != nil, "out": out.map { $0 as Any } ?? NSNull(), "shown": shown,
                "host": ["frame": rect(host.frame), "hidden": host.isHidden, "alpha": Double(host.alphaValue),
                         "subviews": host.subviews.count, "layer": describe(host.layer)],
                "placement": ["model": placed(host.layer, in: layer),
                              "presentation": placed(host.layer?.presentation() ?? host.layer, in: layer?.presentation() ?? layer),
                              "animations": layer?.animationKeys() ?? []],
                "chain": chain]
    }

    /// Whether the band is masked now, and how the host's layer is turned,
    /// for the bench.
    var spaceMasked: [String: Any] {
        ["masked": host.layer?.mask != nil, "flipped": host.isFlipped, "geometry_flipped": host.layer?.isGeometryFlipped ?? false,
         "contents_flipped": host.layer?.contentsAreFlipped() ?? false]
    }

    /// In from past the edge and out again as a card over the page on
    /// Dia's curves (CardMotion); flush, put away by its edge, on the
    /// arriving and leaving ones; with the page making room, ⌘S, on the
    /// page's curve, whichever that is. SwiftUI has put the column where it
    /// ends up; it is drawn from where it was, added to that, so it holds
    /// however the pass lays it out.
    func slide(out now: Bool, animated: Bool) {
        defer {
            let changed = out != now
            out = now
            if changed {
                Lights.rows(in: self).forEach { $0.columnVisibilityChanged(now) }
                if !now {
                    func stop(in view: NSView) {
                        if let page = view as? ColumnPage { page.stopPointing(); return }
                        view.subviews.forEach { stop(in: $0) }
                    }
                    stop(in: self)
                    browser?.glance.drop()
                }
            }
        }
        if !now {
            ScrollLatch.release(in: self)
            WheelLatch.release(in: self)
        }
        // Going past the edge while its spaces slide (a card the pointer
        // left), or docked from a card or put away under them: the pages
        // come down, the column goes as it is. Pages held up over a card
        // stayed over the docked column, laid for the card (0.0.13).
        if let browser { SpacePager.shared.settle(browser, out: now) }
        guard let browser, let layer else { return }
        let away = -(browser.prefs.sideWidth + Metrics.floatInset + 40) * browser.flank.sign
        let target: CGFloat = now ? 0 : away
        let carried = layer.presentation()?.sublayerTransform.m41 ?? layer.sublayerTransform.m41
        // AppKit resets a hosting view's backing transform when it first
        // sizes it. Carry its drawing from the parent's sublayer transform,
        // leaving the host's full-window frame and SwiftUI space in place.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(target, forKeyPath: "sublayerTransform.translation.x")
        CATransaction.commit()
        guard let was = out, was != now else { return }
        StageView.mark("slide", ["out": now, "animated": animated])
        // A reversal starts where the column is drawn now. Adding a full
        // arrival to a departure still running on a different curve can
        // carry the column past its resting edge and leave a gap beside it.
        for key in layer.animationKeys() ?? [] where key.hasPrefix("column.slide.") {
            layer.removeAnimation(forKey: key)
        }
        guard animated else { return }
        let animation: CABasicAnimation
        var from = carried
        if !browser.folding, browser.sideCard {
            animation = now ? CardMotion.arriving() : CardMotion.leaving()
            // From all of it past the edge, out of sight: just past its
            // shadow, as Dia's starts, not from further, which the spring
            // spent its first frames on with nothing to see.
            if now, abs(carried - away) < 0.5 {
                from = -(browser.prefs.sideWidth + Metrics.floatInset + CardMotion.shadow) * browser.flank.sign
            }
        } else {
            let pace: Reshape.Pace = browser.folding ? Reshape.pace : now ? .arrive : .depart
            animation = CABasicAnimation(keyPath: "sublayerTransform.translation.x")
            animation.duration = pace.duration
            animation.timingFunction = pace.timing
        }
        animation.keyPath = "sublayerTransform.translation.x"
        animation.isAdditive = false
        animation.fromValue = from
        animation.toValue = target
        // Only this new motion remains; other animations on the host keep
        // their own keys and continue.
        slides += 1
        layer.add(animation, forKey: "column.slide.\(slides)")
        Self.slid = CACurrentMediaTime()
    }

    /// Direct pinning ends a floating arrival at its docked position;
    /// ordinary view updates leave an in-flight animation alone.
    func settleSlide(out now: Bool) {
        for key in layer?.animationKeys() ?? [] where key.hasPrefix("column.slide.") {
            layer?.removeAnimation(forKey: key)
        }
        out = nil
        slide(out: now, animated: false)
    }

    /// When the last slide was handed to Core Animation, for the bench.
    static var slid: CFTimeInterval?
}

/// The card the pointer at the window's edge brings out over the page, and
/// lets go: on Dia's curves, measured frame by frame against it with the
/// same hand (evals/side-peek/hover.py, 2026-10-07). In on a spring, Dia's
/// ⌘S one, of 0.21 s and damping 0.78: half way in 50 ms, nine tenths in
/// 97, 2% past its place at 170 and back, within half a point by 270.
/// Out on a curve that barely slows, in 0.11 s to just out of sight as
/// Dia's goes, 0.12 s for the further this one goes past it, half way in 49.
enum CardMotion {
    static let response: CFTimeInterval = 0.21
    static let damping: CGFloat = 0.78
    static let leavingTime: CFTimeInterval = 0.12
    /// Past the card, just out of sight: its shadow shows 16 points past it.
    static let shadow: CGFloat = 20
    static let leavingPoints: (Float, Float, Float, Float) = (0.67, 0.85, 0.73, 0.86)
    static let leavingCurve = CAMediaTimingFunction(controlPoints: leavingPoints.0, leavingPoints.1, leavingPoints.2, leavingPoints.3)

    /// The same two in SwiftUI's words, for the strip put away, which the
    /// window's top edge brings out over the page and lets go the way the
    /// left edge does the column (Brim.bringStrip).
    static var arrive: Animation {
        .spring(response: response * Reshape.slow, dampingFraction: Double(damping))
    }

    static var leave: Animation {
        .timingCurve(Double(leavingPoints.0), Double(leavingPoints.1), Double(leavingPoints.2), Double(leavingPoints.3),
                     duration: leavingTime * Reshape.slow)
    }

    static func arriving() -> CABasicAnimation {
        let spring = CASpringAnimation(keyPath: "transform.translation.x")
        // A SwiftUI spring's response and damping, as Core Animation has
        // them: stiffness and damping for a mass of one.
        let response = Self.response * Reshape.slow
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / response, 2)
        spring.damping = 4 * .pi * damping / response
        spring.duration = spring.settlingDuration
        return spring
    }

    static func leaving() -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.duration = leavingTime * Reshape.slow
        animation.timingFunction = leavingCurve
        return animation
    }
}

/// What the column wears, worked out where it is drawn: the site's color
/// or the backdrop's, as the window's own view works it out.
struct ColumnRoot: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @Environment(\.colorScheme) private var scheme
    private var privateWindow: Bool { browser.windowPurpose == .privateOnly }

    var body: some View {
        // The window's own dresser (Browser.dresser): with two halves on
        // screen, no site's color, as the backdrop and the strip have it,
        // not the color of whichever half was clicked last.
        // Kept whole when no tab is in front (SteadyWorn): Worn's two
        // branches made the column anew each time the tab in front came or
        // went (a new space, a split staged, a switch's passing moment), and
        // with it every page of ColumnPages and every cell in them.
        SteadyWorn(site: browser.worn, mode: privateWindow ? .color : prefs.backdrop, swatch: swatch, glassActive: glassActive) { tone in
            // Docked it paints nothing of its own, the window's color shows
            // through it: on the site's color it is handed its words alone,
            // the same from one site to the next of the same light. Out over
            // the page as a card it paints the site's color itself.
            let docked = !prefs.sideShut
            Column(browser: browser, prefs: prefs, peek: browser.peek, docked: docked, tone: docked ? ink ?? tone : tone, card: card,
                   carried: true, ink: docked ? nil : ink)
        }
    }

    /// On the site's color, the words the column wears (Tone.columnInk): the
    /// site's light or dark, not its hue, so a switch to another site of the
    /// same light leaves every row, word and button as it is.
    private var ink: Tone? {
        guard !privateWindow, !glassActive, let color = browser.worn.color else { return nil }
        let site = Tone(color, lifted: true)
        guard Worn<EmptyView>.worn(site, mode: prefs.backdrop, dark: scheme == .dark) else { return nil }
        return Tone.columnInk(site)
    }

    // Kept while a page has the screen, as the window's backdrop is
    // (ContentView.backdrop): dropped then, the column was built again
    // without its look and put it back as the page came home, a beat
    // after the column came back flat.
    /// Edge to edge and docked too: the column stands on the window's
    /// backdrop then, as on a color (Preferences.edgeBackdrop).
    var swatch: Tone? {
        // This is an independent NSHostingView: ContentView's preferred
        // dark scheme and private paint do not supply its environment.
        if privateWindow { return Tone(ContentView.privateBackdrop, lifted: true) }
        guard prefs.backdrop != .none || prefs.edgeBackdrop else { return nil }
        return Tone(prefs.swatch.color(dark: scheme == .dark, custom: prefs.backdropColor), lifted: true, glass: glassActive)
    }

    /// Edge to edge and put away, the space's color for the column out
    /// over the page, as `swatch` is on a color (Column.card): the same
    /// color, so the same inks (Tone.card), and the same paint
    /// (SpaceWash.card).
    private var card: Tone? {
        guard !privateWindow, prefs.backdrop == .none, !prefs.edgeBackdrop else { return nil }
        return Tone(prefs.swatch.color(dark: scheme == .dark, custom: prefs.backdropColor), lifted: true,
                    glass: prefs.lookGlass && WindowGlassPolicy.supported)
    }

    private var glassActive: Bool { !privateWindow && prefs.wearsGlass }
}

/// Worn with one shape whether or not a tab is in front: Worn's two
/// branches made the column anew each time the tab in front came or went.
/// Its color is taken at once, as the page is.
struct SteadyWorn<Content: View>: View {
    var site: WornSite
    let mode: Backdrop
    let swatch: Tone?
    var glassActive = false
    @ViewBuilder let content: (Tone?) -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if glassActive {
            content(swatch)
        } else {
            let tone = site.color.map { Tone($0, lifted: true) }
            content(Worn<Content>.worn(tone, mode: mode, dark: scheme == .dark) ? tone : swatch)

        }
    }
}
