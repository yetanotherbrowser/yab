import AppKit
import SwiftUI

/// The ends of a column that its rows scroll under, as a launcher's lists go
/// under its search and its bar: the lights, the address and the pins at
/// the top, the foot at the bottom. Under them a row is dimmed and blurred,
/// and comes clear a little past them, so what stands there reads over it
/// and the row is still seen going; nothing standing there is glass. Only
/// as far as rows have gone under an end, so a column at rest is untouched.
/// The tabs' rows (SideBar) and mail's lists (MailColumn) both. The foot's
/// end is its own, as Arc's: the rows end at the foot's top, nothing of them
/// under the spaces and the plus, eased away over a fall above it (#335:
/// with many tabs the rows under the foot hid its spaces).
@MainActor
final class ColumnEnds: ObservableObject {
    struct Depth: Equatable {
        var above: CGFloat = 0
        var below: CGFloat = 0
    }
    @Published var depth = Depth()

    /// How far past what stands over an end a row comes clear.
    nonisolated static let fall: CGFloat = 24
    /// How much of a row shows under what stands over an end.
    nonisolated static let shown: Double = 0.45
    /// How much it is blurred there: soft, a row still made out under the
    /// search.
    nonisolated static let blur: CGFloat = 4
    /// The tabs' column's own, under the pins and the space's name: enough
    /// that a row's words melt there (#303), the row still seen going by
    /// as a smear of its color, as a line of words melts under the address
    /// plate (PlateBlurView).
    nonisolated static let pinsBlur: CGFloat = 12

    /// The foot's end: none of a row under the foot's room (the foot, and a
    /// newer Yab's note or the agents' row over it), the row eased back over
    /// `footFall` above it.
    nonisolated static let footFall: CGFloat = 24
    nonisolated static let footShown: Double = 0
    nonisolated static let footBlur: CGFloat = 5
}

/// Tells ColumnEnds how far the rows have gone under each end, a fall's
/// worth at most and in tenths, so a scroll past that tells it nothing more.
/// Measured past the scroll view's margins, where the rows rest.
struct ColumnScrolled: ViewModifier {
    let ends: ColumnEnds
    /// The rows on screen: a space's kept behind them (SideBar.rowPages)
    /// only says how far it is scrolled, to `kept`.
    var live = true
    var kept: ((ColumnEnds.Depth) -> Void)? = nil

    func body(content: Content) -> some View {
        let fall = ColumnEnds.fall
        content.onScrollGeometryChange(for: ColumnEnds.Depth.self) { geo in
            let above = geo.visibleRect.minY + geo.contentInsets.top
            let below = geo.contentSize.height + geo.contentInsets.bottom - geo.visibleRect.maxY
            func share(_ by: CGFloat, _ fall: CGFloat) -> CGFloat { (min(1, max(0, by / fall)) * 10).rounded() / 10 }
            return .init(above: share(above, fall), below: share(below, ColumnEnds.footFall))
        } action: { [live, kept] _, now in
            kept?(now)
            if live { ends.depth = now }
        }
    }
}

/// The rows' own alpha at the ends, as a mask over them: whole between
/// them; ColumnEnds.shown under what stands over the top (`top` from it),
/// eased whole over the fall past it; at the bottom, with a `foot`, the
/// foot's own end: nothing over `footRoom`, whole past ColumnEnds.footFall
/// above it. Their
/// own alpha, not the ground laid over them: the ground is a gradient,
/// grain or see-through, and stays as it is. Whole a little past the
/// scroll view's edges too, where a held row is drawn while the rows fit
/// and nothing clips them (SideBar's scrollClipDisabled).
struct ColumnFade: View {
    @ObservedObject var ends: ColumnEnds
    let top: CGFloat
    let foot: Bool
    /// What stands over the column's bottom: the foot, a note over it, the
    /// player under it.
    var footRoom: CGFloat = SideBar.footHeight

    private static var beyond: CGFloat { 2 * SideBar.row }

    var body: some View {
        let fall = ColumnEnds.fall
        VStack(spacing: 0) {
            Color.black.frame(height: Self.beyond)
            LinearGradient(stops: Self.stops(depth: ends.depth.above, under: top / (top + fall)), startPoint: .top, endPoint: .bottom)
                .frame(height: top + fall)
            Color.black
            if foot {
                let low = footRoom, drop = ColumnEnds.footFall
                LinearGradient(stops: Self.stops(depth: ends.depth.below, under: low / (low + drop), shown: ColumnEnds.footShown),
                               startPoint: .bottom, endPoint: .top)
                    .frame(height: low + drop)
            }
            Color.black.frame(height: Self.beyond)
        }
        .padding(.vertical, -Self.beyond)
    }

    /// From the edge, `shown` as far as `under`, then a smoothstep to
    /// whole; whole throughout at `depth` 0.
    static func stops(depth: CGFloat, under: CGFloat, shown: Double = ColumnEnds.shown) -> [Gradient.Stop] {
        let low = 1 - Double(depth) * (1 - shown)
        var stops: [Gradient.Stop] = [.init(color: .black.opacity(low), location: 0)]
        for n in 0...8 {
            let t = Double(n) / 8
            stops.append(.init(color: .black.opacity(low + (1 - low) * t * t * (3 - 2 * t)), location: under + (1 - under) * t))
        }
        return stops
    }
}

/// The blur at the ends, laid over the rows: whole under what stands over
/// an end and eased away over the fall past it, as far as the rows have
/// gone under (ColumnEnds). The grain again over it, the window's own tile
/// from the same corner, so the ground under the blur keeps its grain. Laid
/// on outside the rows' mask: a mask over it would draw it on its own,
/// with nothing under it to blur.
struct ColumnBlur: View {
    @ObservedObject var ends: ColumnEnds
    let top: CGFloat
    let foot: Bool
    /// The window's grain, 0 for none.
    let grain: Double
    /// The top end's blur: the tabs' column's is stronger (`pinsBlur`).
    var radius: CGFloat = ColumnEnds.blur
    /// What stands over the column's bottom (ColumnFade.footRoom).
    var footRoom: CGFloat = SideBar.footHeight

    var body: some View {
        let fall = ColumnEnds.fall
        let low = footRoom, drop = ColumnEnds.footFall
        ZStack {
            VStack(spacing: 0) {
                EdgeBlur(edge: .top, whole: top / (top + fall), radius: radius)
                    .frame(height: top + fall)
                    .opacity(ends.depth.above)
                Spacer(minLength: 0)
                if foot {
                    EdgeBlur(edge: .bottom, whole: low / (low + drop), radius: ColumnEnds.footBlur)
                        .frame(height: low + drop)
                        .opacity(ends.depth.below)
                }
            }
            if grain > 0 {
                Image(nsImage: Grain.tile)
                    .resizable(resizingMode: .tile)
                    .opacity(Grain.opacity(grain))
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(stops: Self.stops(under: top / (top + fall)), startPoint: .top, endPoint: .bottom)
                                .frame(height: top + fall)
                                .opacity(ends.depth.above)
                            Color.clear
                            if foot {
                                LinearGradient(stops: Self.stops(under: low / (low + drop)), startPoint: .bottom, endPoint: .top)
                                    .frame(height: low + drop)
                                    .opacity(ends.depth.below)
                            }
                        }
                    }
            }
        }
        .allowsHitTesting(false)
    }

    /// The grain's mask, as the blur's own (EdgeBlurView.curve).
    static func stops(under: CGFloat) -> [Gradient.Stop] {
        EdgeBlurView.curve(under: under).map { .init(color: .black.opacity($0.alpha), location: $0.at) }
    }
}

/// A blur of what is under it in the window, whole from one edge to
/// `whole` of its height and eased away past that: Core Animation's
/// backdrop with a gaussian blur, its gradient the backdrop layer's own
/// mask.
struct EdgeBlur: NSViewRepresentable {
    enum Edge { case top, bottom }
    let edge: Edge
    let whole: CGFloat
    let radius: CGFloat

    func makeNSView(context: Context) -> EdgeBlurView { EdgeBlurView(radius: radius) }

    func updateNSView(_ view: EdgeBlurView, context: Context) {
        guard view.edge != edge || view.whole != whole else { return }
        view.edge = edge
        view.whole = whole
        view.needsLayout = true
    }
}

final class EdgeBlurView: NSView {
    private let backdrop: CALayer?
    private let fade = CAGradientLayer()
    var edge: EdgeBlur.Edge = .top
    var whole: CGFloat = 0.5

    init(radius: CGFloat) {
        backdrop = EdgeBlurView.backdrop(radius: radius)
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        guard let backdrop else { return }
        backdrop.mask = fade
        layer?.addSublayer(backdrop)
    }

    /// Core Animation's backdrop, what is under it in the window, with a
    /// gaussian blur of `radius` whose edges stay whole. Nil where the Mac
    /// has no backdrop layer to make.
    static func backdrop(radius: CGFloat) -> CALayer? {
        guard let backdrop = (NSClassFromString("CABackdropLayer") as? CALayer.Type)?.init() else { return nil }
        if let type = NSClassFromString("CAFilter") as? NSObject.Type,
           let blur = type.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?.takeUnretainedValue() as? NSObject {
            blur.setValue(radius, forKey: "inputRadius")
            blur.setValue(true, forKey: "inputNormalizeEdges")
            backdrop.filters = [blur]
        }
        return backdrop
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard let backdrop else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        fade.frame = bounds
        let curve = Self.curve(under: whole)
        fade.colors = curve.map { NSColor.black.withAlphaComponent($0.alpha).cgColor }
        fade.locations = curve.map { NSNumber(value: $0.at) }
        // A layer's y goes up on the Mac: the top edge is at 1.
        fade.startPoint = CGPoint(x: 0.5, y: edge == .top ? 1 : 0)
        fade.endPoint = CGPoint(x: 0.5, y: edge == .top ? 0 : 1)
        CATransaction.commit()
    }

    /// Whole from the edge to `under`, a share of the height, then a
    /// smoothstep to nothing at the far end.
    static func curve(under: CGFloat) -> [(alpha: Double, at: Double)] {
        [(alpha: 1, at: 0)] + (0...8).map { n in
            let t = Double(n) / 8
            return (alpha: 1 - t * t * (3 - 2 * t), at: Double(under) + (1 - Double(under)) * t)
        }
    }
}

/// The one ground a row in the column or across the top stands on, by how
/// it is chosen: the open tab's, a picked one's, a folder aimed at, a pair
/// on screen, the space's name a tab is held over, New tab lit, and the
/// grays at rest and under the pointer. Selected and picked are a soft
/// white lifted off the column, with a sheen and a faint frost of what is
/// under them; at rest and under the pointer they are flat.
struct SelectionPlate: View {
    enum Kind: Equatable {
        /// The open one, or what stands for it.
        case selected
        /// Picked alongside the open one: its ground, lighter, lifted alike.
        case picked
        /// Under the pointer and nothing else.
        case hover
        /// A ground there at rest, a pin's or a pair's (Palette.resting).
        case resting(hovering: Bool)
    }

    /// The corners that round, `.all` but where a pair's halves meet
    /// (JointGround), whose inner corners stay square.
    struct Corners: OptionSet {
        let rawValue: Int
        static let topLeading = Corners(rawValue: 1)
        static let topTrailing = Corners(rawValue: 2)
        static let bottomLeading = Corners(rawValue: 4)
        static let bottomTrailing = Corners(rawValue: 8)
        static let leading: Corners = [.topLeading, .bottomLeading]
        static let trailing: Corners = [.topTrailing, .bottomTrailing]
        static let top: Corners = [.topLeading, .topTrailing]
        static let bottom: Corners = [.bottomLeading, .bottomTrailing]
        static let all: Corners = [.leading, .trailing]
    }

    let corner: CGFloat
    var corners: Corners = .all
    let state: Kind
    /// Whose look says whether the window wears glass or drawings, the
    /// only grounds the frost shows on; without it none is made.
    var prefs: Preferences? = nil
    /// On the strip across the top rather than in the column: bare, with no
    /// page color, it is white in a light window (Palette.selectionPressed).
    var strip = false

    var body: some View {
        if corners == .all {
            Plate(shape: RoundedRectangle(cornerRadius: corner, style: .continuous), corner: corner, corners: corners, state: state, prefs: prefs, strip: strip)
        } else {
            let r = { (c: Corners) in corners.contains(c) ? corner : 0 }
            Plate(shape: UnevenRoundedRectangle(topLeadingRadius: r(.topLeading), bottomLeadingRadius: r(.bottomLeading),
                                                bottomTrailingRadius: r(.bottomTrailing), topTrailingRadius: r(.topTrailing),
                                                style: .continuous),
                  corner: corner, corners: corners, state: state, prefs: prefs, strip: strip)
        }
    }

    private struct Plate<Outline: InsettableShape>: View {
        let shape: Outline
        let corner: CGFloat
        let corners: Corners
        let state: Kind
        let prefs: Preferences?
        let strip: Bool
        @Environment(\.colorScheme) private var scheme
        @Environment(\.tone) private var tone

        var body: some View {
            let dark = scheme == .dark
            switch state {
            case .hover:
                shape.fill(Palette.hover(on: tone))
            case .resting(let hovering):
                shape.fill(Palette.resting(on: tone, hovering: hovering))
            case .selected where Palette.selectionPressed(on: tone, dark: dark, strip: strip),
                 .picked where Palette.selectionPressed(on: tone, dark: dark, strip: strip):
                // On a ground as white as the plate: the ink pressed in, flat.
                let ground = Palette.selection(on: tone, dark: dark)
                shape.fill(state == .picked ? ground.opacity(0.55) : ground)
            case .selected, .picked:
                let ground = Palette.selection(on: tone, dark: dark)
                shape.fill(state == .picked ? ground.opacity(0.55) : ground)
                    .cast(dark ? Shadow.selectionDark : Shadow.selection)
                    .overlay {
                        if dark { shape.strokeBorder(Palette.pinRim, lineWidth: 1).allowsHitTesting(false) }
                    }
                    .overlay { shape.fill(Palette.selectionSheen).allowsHitTesting(false) }
                    .background {
                        if let prefs { Frost(prefs: prefs, corner: corner, corners: corners) }
                    }
            }
        }
    }

    /// The frost under a selection, on drawings and glass only: on a plain
    /// color there is nothing under it to melt, and a backdrop layer under
    /// every chosen row would be made for nothing. Reads the look here, so
    /// a change of it redraws this, not the row.
    private struct Frost: View {
        let prefs: Preferences
        let corner: CGFloat
        let corners: Corners

        var body: some View {
            if prefs.wearsGlass || prefs.wearsDrawings {
                PlateBlur(corner: corner, radius: PlateBlurView.selection, corners: corners.layerMask)
            }
        }
    }
}

extension SelectionPlate.Corners {
    /// The same corners for a layer, whose y goes up on the Mac (PlateBlurView
    /// hosts its own layer, unflipped): the top is MaxY.
    var layerMask: CACornerMask {
        var mask: CACornerMask = []
        if contains(.topLeading) { mask.insert(.layerMinXMaxYCorner) }
        if contains(.topTrailing) { mask.insert(.layerMaxXMaxYCorner) }
        if contains(.bottomLeading) { mask.insert(.layerMinXMinYCorner) }
        if contains(.bottomTrailing) { mask.insert(.layerMaxXMinYCorner) }
        return mask
    }
}

/// A blur of all that is under it in the window, in a rounded outline: the
/// column's address plate over drawings or glass (SidePlate), where the
/// drawings' lines and the words of a window behind ran under the site's.
struct PlateBlur: NSViewRepresentable {
    let corner: CGFloat
    var radius: CGFloat = PlateBlurView.radius
    var corners: CACornerMask = PlateBlurView.allCorners

    func makeNSView(context: Context) -> PlateBlurView { PlateBlurView(corner: corner, radius: radius) }
    func updateNSView(_ view: PlateBlurView, context: Context) {
        view.configure(corner: corner, radius: radius, corners: corners)
    }
}

final class PlateBlurView: NSView {
    /// Enough to melt a line of words behind the window into the plate's
    /// ground, and the drawings' strokes with it.
    static let radius: CGFloat = 12
    /// Under a selected row (SelectionPlate): only enough to soften a
    /// drawing's line or a word through glass, the row's own ground does
    /// the rest.
    static let selection: CGFloat = 1.5
    static let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    private let backdrop: CALayer?

    init(corner: CGFloat, radius: CGFloat = PlateBlurView.radius) {
        backdrop = EdgeBlurView.backdrop(radius: radius)
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        guard let backdrop else { return }
        backdrop.cornerRadius = corner
        backdrop.cornerCurve = .continuous
        backdrop.masksToBounds = true
        layer?.addSublayer(backdrop)
    }

    required init?(coder: NSCoder) { nil }

    func configure(corner: CGFloat, radius: CGFloat, corners: CACornerMask = PlateBlurView.allCorners) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.cornerRadius = corner
        backdrop?.maskedCorners = corners
        (backdrop?.filters?.first as? NSObject)?.setValue(radius, forKey: "inputRadius")
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.frame = bounds
        CATransaction.commit()
    }
}

/// No soft edge of the system's own where rows scroll under a column's
/// margins: its ends are ColumnFade's and ColumnBlur's, and macOS 26's haze
/// there would lie over them.
struct OwnScrollEdges: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .vertical)
        } else {
            content
        }
    }
}
