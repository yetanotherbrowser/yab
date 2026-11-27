import AppKit
import SwiftUI

// The island: what plays in a tab you aren't on, one capsule of Liquid Glass
// right over the column's foot, the downloads, the extensions and the space;
// with none of those it is the column's bottom row. At rest it is a row
// tall: the cover, the title, the artist and four bars that move while it
// plays and lie down as dots when it doesn't. Under the pointer, after a
// beat, it opens upward into a card on the same glass: the cover grows from
// where it was, the words take two lines, the progress and the buttons come
// in. Other tabs playing are buds beside it, round drops of the same glass:
// one shows, a second peeks from behind it, more are counted. A tap on a
// bud, or two fingers sideways over the island, swap them, the newcomer's
// cover riding in from its bud and the old one dropping into it (the
// carousel a skip makes too). Open, the buds grow into rows over the card.
// The card's progress line is a scrubber: pressed it goes there, dragged
// or swept with two fingers it follows, the times with it.
//
// The curves are concentric, as Apple asks of glass in glass: the capsule's
// is half its height, the cover in it is round on the same center (the
// capsule's 14 less its 4 inset), a bud is a circle and its cover one too.
// Open, the card is a card (Radius.card: CardFrame.inset plus a control's
// corner) and the cover in it has a control's corner, CardFrame.inset in.
//
// The glass is the system's: NSGlassEffectView in one container, so the
// island and its buds melt together when near and part with a neck as they
// move apart, on the render server. Their frames and corners move by
// NSAnimationContext; everything drawn over them is layers of ours, moved
// by Core Animation on the same curve and time, so nothing here re-runs a
// SwiftUI body or asks the main thread for a frame. The words are pictures,
// their fade painted in (no mask); each motion rule this follows is
// named where it applies (papers/family-values-motion).

enum Band {
    /// The island at rest: a capsule a little taller than a tab row.
    static let row: CGFloat = 30
    /// It stands this far in from the column's side, and this far over
    /// the foot, which keeps the column's bottom as in Arc (row 1090): the
    /// window's 18 less the capsule's 15. With no foot it hugs the
    /// column's corner, the two curves sharing a center.
    static let edge: CGFloat = Radius.window - foot
    /// Its bottom corners: the capsule's half height, as its top ones, one
    /// whole capsule; open, the card's top ones are the card's.
    static let foot: CGFloat = row / 2
    /// Open, the card is never narrower than this: in a column narrower
    /// than the usual 240 it stands out over the page rather than squeezing
    /// its buttons; in that one it is the island's width, inside the
    /// column, the edge in from both of its sides.
    static let minCard: CGFloat = 224
    /// The cover at rest, round, the capsule's inset in, so its curve and
    /// the capsule's share a center.
    static let inset: CGFloat = 4
    static let cover: CGFloat = row - 2 * inset
    /// After the cover, before the words.
    static let air: CGFloat = 8
    /// The capsule's right end, before the bars.
    static let end: CGFloat = 10
    /// How far a name that doesn't fit goes out, as a tab's does.
    static let fade: CGFloat = 22
    static var size: CGFloat { SidebarTypography.current }
    /// Another tab playing: a round bud, a row across.
    static let bud: CGFloat = row
    /// Between the island and a bud, and between the rows open: wider than
    /// the glass melts across (IslandGlass.melt), so at rest they stand
    /// apart, and only on the way do they hold on by a neck.
    static let split: CGFloat = 6
    /// What the bud behind it shows of a third.
    static let peek: CGFloat = 4
    /// Open: a card, everything CardFrame.inset in.
    static let card: CGFloat = 144
    static let art: CGFloat = 48
    /// The buds grown into rows over the open card, at most.
    static let listed = 3
    /// All the island can take, open with its rows: the view's height.
    static let reach: CGFloat = card + CGFloat(listed) * (row + split)
    /// What the column keeps for it at its bottom while it is up: its row
    /// and its inset, the foot standing over that.
    static let room: CGFloat = row + edge
    static func room(edge: CGFloat) -> CGFloat { row + edge }
    /// How far over the column's bottom the island's row stands: over the
    /// foot and its inset, the foot never pushed up by it (row 1090), or
    /// in the corner where the column has no foot.
    static func base(edge: CGFloat, foot: Bool) -> CGFloat { edge + (foot ? SideBar.footHeight : 0) }
    /// A button in the open card, its round ground under the pointer; the
    /// quiet ones at the ends, the sound and the way back, a size down.
    static let door: CGFloat = 36
    static let small: CGFloat = 28
    /// The progress line, a capsule.
    static let line: CGFloat = 5
    /// How far above and below it the line still takes a press: five
    /// points is no target.
    static let grip: CGFloat = 9
    /// The pointer rests this long before the island opens, so passing over
    /// it on the way to the foot opens nothing.
    static let wait: TimeInterval = 0.12
    /// Going: down into the edge with the foot coming down over it, soft
    /// at both ends. On the leaving curve, gathering speed into 0.15 s, the
    /// foot landed at full speed and read as a drop (report 2026-10-13).
    static let sink: TimeInterval = 0.26
    static var sinking: Animation { .timingCurve(0.45, 0, 0.25, 1, duration: sink) }
}

/// The island as SwiftUI places it.
struct PlayerBand: NSViewRepresentable {
    let player: Player
    /// The island's width at rest: the column's, less its insets.
    let rest: CGFloat
    /// The column is on the window's right: the view stands at its right
    /// end and the open card grows leftward, over the page.
    let trailing: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.tone) private var tone

    func makeNSView(context: Context) -> BandView {
        let view = BandView()
        view.attach(player)
        return view
    }

    func updateNSView(_ view: BandView, context: Context) {
        view.rest = rest
        view.trailing = trailing
        view.look(dark: scheme == .dark, toned: tone != nil)
    }
}

/// The island at the column's bottom, over the foot: laid over the column
/// (Column, Peek.swift), outside its clip, so the open card can stand out
/// over the page when the column is narrower than the card. The view is as
/// tall as the island open with its rows and as wide as the card; it takes
/// the pointer only where the glass is (BandView.hitTest).
struct BandSlot: View {
    let player: Player
    @ObservedObject var prefs: Preferences
    @ObservedObject var room: PlayerRoom
    /// The column's width now.
    let column: CGFloat
    /// The column is on the window's right: the slot is pinned to its
    /// right end, so the card's excess goes over the page, not past the
    /// window's edge.
    var trailing = false
    /// In from the column's side and over the foot (Browser.bandEdge).
    var edge = Band.edge
    /// The column has its foot, which the island stands over (Band.base).
    var foot = true

    var body: some View {
        if prefs.showsPlayer {
            let rest = max(0, column - 2 * edge)
            PlayerBand(player: player, rest: rest, trailing: trailing)
                .frame(width: max(rest, Band.minCard), height: Band.reach)
                .padding(trailing ? .trailing : .leading, edge)
                .padding(.bottom, Band.base(edge: edge, foot: foot))
        }
    }
}

/// Where the foot and the rows keep clear of the island: its row and its
/// inset, while it is up.
struct BandRoom: View {
    @ObservedObject var room: PlayerRoom
    var visible = true
    var edge = Band.edge

    var body: some View {
        Color.clear.frame(height: visible && room.up ? Band.room(edge: edge) : 0)
    }
}

// MARK: - glass

/// A drop of the island's glass: the system's Liquid Glass on macOS 26, a
/// blurred plate before it.
@MainActor
enum IslandGlass {
    /// Drops nearer than this melt into one.
    static let melt: CGFloat = 5

    static func container() -> NSView {
        if #available(macOS 26.0, *) {
            let box = NSGlassEffectContainerView()
            // Near enough to melt: a bud leaving the island keeps a neck
            // until it is this far off.
            box.spacing = melt
            box.contentView = NSView()
            return box
        }
        return NSView()
    }

    static func holder(of container: NSView) -> NSView {
        if #available(macOS 26.0, *), let box = container as? NSGlassEffectContainerView, let inside = box.contentView { return inside }
        return container
    }

    static func drop() -> NSView {
        if #available(macOS 26.0, *) {
            let glass = IslandDrop()
            glass.style = .regular
            return glass
        }
        let plate = NSVisualEffectView()
        plate.material = .popover
        plate.blendingMode = .withinWindow
        plate.state = .active
        plate.wantsLayer = true
        plate.layer?.cornerCurve = .continuous
        return plate
    }

    /// Its corners: `top` the upper two, `bottom` the lower two.
    static func corner(_ view: NSView, top: CGFloat, bottom: CGFloat) {
        if #available(macOS 26.0, *), let glass = view as? IslandDrop {
            glass.edges = (top, bottom)
            return
        }
        view.layer?.cornerRadius = min(top, bottom)
    }

    /// The cover's color through the glass, faintly: the subject's accent
    /// (P9) without a plate of paint.
    static func tint(_ view: NSView, _ color: NSColor?) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.tintColor = color
        }
    }

    /// macOS 27's `NSViewCornerConfiguration.uniformEdges(topRadius:
    /// bottomRadius:)` of two fixed radii, made through the runtime for a
    /// build whose SDK hasn't got it (IslandDrop); nil before macOS 27.
    static func corners(top: CGFloat, bottom: CGFloat) -> AnyObject? { makeCorners?(top, bottom) }

    private static let makeCorners: ((CGFloat, CGFloat) -> AnyObject?)? = {
        guard let radius = NSClassFromString("NSViewCornerRadius"),
              let configuration = NSClassFromString("NSViewCornerConfiguration"),
              let fixed = class_getClassMethod(radius, NSSelectorFromString("fixedRadius:")),
              let uniform = class_getClassMethod(configuration, NSSelectorFromString("configurationWithUniformTopRadius:bottomRadius:"))
        else { return nil }
        typealias Fixed = @convention(c) (AnyObject, Selector, CGFloat) -> UnsafeRawPointer?
        typealias Uniform = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> UnsafeRawPointer?
        let make = unsafeBitCast(method_getImplementation(fixed), to: Fixed.self)
        let pair = unsafeBitCast(method_getImplementation(uniform), to: Uniform.self)
        let (fixedName, uniformName) = (method_getName(fixed), method_getName(uniform))
        func object(_ pointer: UnsafeRawPointer?) -> AnyObject? {
            pointer.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
        }
        return { top, bottom in
            guard let a = object(make(radius as AnyObject, fixedName, top)),
                  let b = object(make(radius as AnyObject, fixedName, bottom)) else { return nil }
            return object(pair(configuration as AnyObject, uniformName, a, b))
        }
    }()
}

/// Liquid Glass with its upper and lower corners apart: the island's top is
/// a capsule's, its bottom concentric with the window's corner.
@available(macOS 26.0, *)
final class IslandDrop: NSGlassEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        // The first edges are the default's, so their didSet never runs:
        // before macOS 27, with no corner configuration, the glass kept its
        // own small radius (about 6) under a 15 capsule (seen on 26.7).
        cornerRadius = edges.top
    }

    required init?(coder: NSCoder) { fatalError() }

    var edges: (top: CGFloat, bottom: CGFloat) = (Band.row / 2, Band.foot) {
        didSet {
            guard edges != oldValue else { return }
            #if compiler(>=6.4) // macOS 27's SDK (Xcode 27); Xcode 26 has no corner configuration
            if #available(macOS 27.0, *) { invalidateCornerConfiguration(); return }
            #else
            let invalidate = NSSelectorFromString("invalidateCornerConfiguration")
            if responds(to: invalidate), IslandGlass.corners(top: 1, bottom: 1) != nil { perform(invalidate); return }
            #endif
            cornerRadius = edges.top
        }
    }

    #if compiler(>=6.4)
    @available(macOS 27.0, *)
    override var cornerConfiguration: NSViewCornerConfiguration? {
        // The glass lays its corners out flipped: what it calls the top
        // is the bottom on screen (measured, macOS 27).
        .uniformEdges(topRadius: .fixed(edges.bottom), bottomRadius: .fixed(edges.top))
    }
    #else
    /// Built with Xcode 26, as releases are, there is no corner
    /// configuration to override, yet macOS 27 asks the glass for one by
    /// this name all the same: answered by name, flipped as above. Without
    /// it the open card took the top's radius all round, 20 at the window's
    /// corner where 12 is concentric (0.0.9).
    @objc(cornerConfiguration) private var namedCorners: AnyObject? {
        IslandGlass.corners(top: edges.bottom, bottom: edges.top)
    }
    #endif
}

// MARK: - the bars

/// Four bars in the cover's color: moving while it plays, each on its own
/// loop the render server runs at a low rate, lying down as dots, one after
/// another, when it pauses (P6: the state flips at once, only the fall
/// takes time).
@MainActor
final class BarsLayer: CALayer {
    static let width: CGFloat = 4 * 2.4 + 3 * 1.8
    private var bars: [CALayer] = []
    private(set) var moving = false
    var tall: CGFloat = 11 { didSet { if oldValue != tall { place() } } }

    override init() {
        super.init()
        for _ in 0..<4 {
            let bar = CALayer()
            bar.cornerRadius = 1.2
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            addSublayer(bar)
            bars.append(bar)
        }
        bounds = CGRect(x: 0, y: 0, width: BarsLayer.width, height: tall)
        place()
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bounds.size = CGSize(width: BarsLayer.width, height: tall)
        for (i, bar) in bars.enumerated() {
            bar.position = CGPoint(x: 1.2 + CGFloat(i) * 4.2, y: tall / 2)
            bar.bounds.size = CGSize(width: 2.4, height: moving ? tall * 0.6 : 2.4)
        }
        CATransaction.commit()
        if moving { loop() }
    }

    func color(_ color: CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.backgroundColor = color }
        CATransaction.commit()
    }

    /// Playing: each bar up and down on a loop of its own.
    func play(animated: Bool) {
        moving = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let from = bar.presentation()?.bounds.height ?? bar.bounds.height
            bar.bounds.size.height = tall * 0.6
            if animated {
                // Up from the dot with a little give, one after another.
                let up = CASpringAnimation(keyPath: "bounds.size.height")
                up.fromValue = from
                up.toValue = tall * 0.6
                up.mass = 1
                up.stiffness = 420
                up.damping = 14
                up.duration = up.settlingDuration
                up.beginTime = bar.convertTime(CACurrentMediaTime(), from: nil) + Double(i) * 0.03
                up.fillMode = .backwards
                bar.add(up, forKey: "up")
            }
        }
        CATransaction.commit()
        loop(after: animated ? 0.25 : 0)
    }

    private func loop(after delay: CFTimeInterval = 0) {
        let heights: [[CGFloat]] = [[0.35, 0.9, 0.55, 1, 0.4], [0.8, 0.45, 1, 0.5, 0.7], [0.5, 1, 0.3, 0.75, 0.95], [0.9, 0.4, 0.7, 0.35, 0.6]]
        for (i, bar) in bars.enumerated() {
            let a = CAKeyframeAnimation(keyPath: "bounds.size.height")
            let values = heights[i].map { $0 * tall }
            a.values = values + [values[0]]
            a.duration = 1.1 + Double(i) * 0.17
            a.calculationMode = .cubic
            a.repeatCount = .infinity
            a.beginTime = bar.convertTime(CACurrentMediaTime(), from: nil) + delay
            if #available(macOS 12.0, *) { a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 24) }
            bar.add(a, forKey: "loop")
        }
    }

    /// Paused: down to dots, left to right.
    func pause(animated: Bool) {
        moving = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let from = bar.presentation()?.bounds.height ?? bar.bounds.height
            bar.removeAnimation(forKey: "loop")
            bar.removeAnimation(forKey: "up")
            bar.bounds.size.height = 2.4
            guard animated else { continue }
            let down = CABasicAnimation(keyPath: "bounds.size.height")
            down.fromValue = from
            down.duration = 0.09
            down.timingFunction = CAMediaTimingFunction(name: .easeIn)
            down.beginTime = bar.convertTime(CACurrentMediaTime(), from: nil) + Double(i) * 0.02
            down.fillMode = .backwards
            bar.add(down, forKey: "down")
        }
        CATransaction.commit()
    }
}

// MARK: - the view

@MainActor
final class BandView: NSView, ColumnFloat {
    /// The last one made, for the bench.
    static weak var last: BandView?

    private weak var player: Player?
    private var face: Player.Face?
    private var dark = false
    private var toned = false
    private var looked = false

    /// Where the pointer can be that means something.
    enum Spot: Equatable {
        case previous, play, next, back, forward, sound, home, line
        /// The open card's progress line: pressed it goes there, dragged
        /// it follows.
        case progress
        /// A live stream's words while behind: back to its edge.
        case live
        /// A bud at rest, or its row over the open card.
        case bud(Int)
        /// At rest, the island's end where its bars stand: play and pause
        /// without opening the card or going to the tab.
        case rest
    }

    /// The glass, under everything drawn.
    private let glassBox = IslandGlass.container()
    private let island = IslandGlass.drop()
    /// The buds' glass, by their tabs.
    private var budGlass: [Tab.ID: NSView] = [:]
    /// Everything drawn over the glass.
    private let inkView = InkView()
    private var ink0: CALayer { inkView.root }

    /// The island's own face: its cover and words, clipped to its glass
    /// while it slides (a swipe, a skip).
    private let faceLayer = CALayer()
    private let cover = CALayer()
    private let title = LineLayer()
    private let artist = LineLayer()
    private let openTitle = LineLayer()
    private let openArtist = LineLayer()
    private let bars = BarsLayer()
    private let track = CALayer()
    private let fill = CALayer()
    private let elapsed = LineLayer()
    private let remaining = LineLayer()
    private let previous = BandDoor(.previous)
    private let play = BandDoor(.play)
    private let next = BandDoor(.next)
    /// 15 seconds back and on, in the skips' places where the site gives
    /// no previous and next (Tune.seeks).
    private let back = BandDoor(.back)
    private let forward = BandDoor(.forward)
    /// The playing tab's sound, off and on, where WebKit lets it be muted.
    private let sound = BandDoor(.sound)
    /// Back to the tab that plays.
    private let home = BandDoor(.tab)
    /// At rest, in the bars' place at the island's end: play while it is
    /// paused, shown instead of the dots, so a paused row says how it plays
    /// again and a press there does it; pause under the pointer while it
    /// plays. The rest of the row goes to the tab, as Arc's does.
    private let restDoor = BandDoor(.play, compact: true)
    private var doorsAll: [BandDoor] { [previous, play, next, back, forward, sound, home] }
    /// The playing tab is muted: the sound door says so.
    private var silent: Bool { player?.tab?.muted ?? false }
    /// The buds' faces: a round cover, and the words and bars of a row.
    private var budFaces: [Tab.ID: BudFace] = [:]
    /// How many play besides the bud and the one behind it.
    private let count = CALayer()

    private var up = false
    /// Open into the card.
    private var open = false
    private var hovering = false
    private var waitOpen: DispatchWorkItem?
    private var waitClose: DispatchWorkItem?
    private var pointed: Spot?
    private var pressed: Spot?
    /// Two fingers sideways: what they do (Sweep), how far the face has
    /// gone, and the one coming.
    private enum Sweep { case swap, scrub }
    private var sweep: Sweep?
    /// The gesture is one the island took: the glide after the fingers
    /// lift is its too, and goes nowhere.
    private var taken = false
    private var swipe: CGFloat = 0
    private var incoming: (layer: CALayer, tab: Tab.ID)?
    /// Where a finger holds the progress line, nought to one, by a press
    /// or two fingers: the line and the times say that point, not the
    /// page's clock, until it lets go.
    private var held: Double?
    /// The way the next change of face goes: a skip pressed, a swipe let go.
    private var heading = 1
    private var swiped: CGFloat?
    private var ticking: Timer?
    /// The open card's seconds, for reading the page every other one.
    private var beat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func attach(_ player: Player) {
        self.player = player
        BandView.made.add(self)
        if window != nil { DispatchQueue.main.async { [weak self] in self?.bind() } }
    }

    /// Every island view made, held weakly: SwiftUI makes the column's
    /// overlay anew when the look or the density changes, and a view it
    /// made and threw away again had taken the player's word from the one
    /// still on screen, which then stood deaf, its face as it was, and
    /// the bench lost it (`last` gone with the thrown one).
    private static let made = NSHashTable<BandView>.weakObjects()

    /// The player tells this one, the one in a window: what it shows now,
    /// and every change after.
    private func bind() {
        guard let player else { return }
        BandView.last = self
        player.onFace = { [weak self] face in self?.show(face) }
        if face != player.face { show(player.face) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            waitClose?.cancel()
            waitClose = nil
            hover(false, animated: false)
        }
        // A turn on: SwiftUI is laying out, and coming up tells it of the
        // room the island takes (PlayerRoom).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if window != nil {
                bind()
            } else if let other = BandView.made.allObjects.last(where: { $0 !== self && $0.window != nil }) {
                // Taken out of its window: another still in one listens.
                other.bind()
            }
        }
    }

    private func build() {
        glassBox.frame = bounds
        glassBox.autoresizingMask = [.width, .height]
        addSubview(glassBox)
        IslandGlass.holder(of: glassBox).addSubview(island)
        IslandGlass.corner(island, top: Band.row / 2, bottom: Band.foot)
        inkView.frame = bounds
        inkView.autoresizingMask = [.width, .height]
        addSubview(inkView)
        glassBox.alphaValue = 0
        inkView.alphaValue = 0

        faceLayer.anchorPoint = .zero
        faceLayer.masksToBounds = true
        faceLayer.cornerCurve = .continuous
        cover.masksToBounds = true
        cover.cornerCurve = .continuous
        cover.contentsGravity = .resizeAspectFill
        for line in [title, artist, openTitle, openArtist, elapsed, remaining] { line.anchorPoint = .zero }
        openTitle.opacity = 0
        openArtist.opacity = 0
        track.cornerRadius = Band.line / 2
        fill.cornerRadius = Band.line / 2
        fill.anchorPoint = .zero
        for door in doorsAll { door.opacity = 0 }
        count.contentsGravity = .center
        count.opacity = 0
        [cover, title, artist, openTitle, openArtist, bars, restDoor].forEach(faceLayer.addSublayer)
        [faceLayer, track, fill, elapsed, remaining, previous, play, next, back, forward, sound, home, count].forEach(ink0.addSublayer)
        [track, fill, elapsed, remaining].forEach { $0.opacity = 0 }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    // MARK: looks

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    private var ink: CGColor { CGColor(gray: dark ? 0.94 : 0.08, alpha: 1) }
    /// On a space's color the quiet words are white or black let through,
    /// not a gray of their own, so the color comes up through them, as
    /// the column's are (Palette.faint(on:)).
    private var muted: CGColor {
        toned ? CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.62 : 0.6) : CGColor(gray: dark ? 0.66 : 0.4, alpha: 1)
    }
    private var accent: CGColor { face?.tune.accent?.cgColor ?? muted }
    private var playing: Bool { face?.tune.playing ?? true }
    private var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func look(dark: Bool, toned: Bool) {
        guard !looked || dark != self.dark || toned != self.toned else { return }
        looked = true
        self.dark = dark
        self.toned = toned
        repaint()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        repaint()
    }

    override func setFrameSize(_ size: NSSize) {
        let changed = size.width != frame.width
        super.setFrameSize(size)
        settle()
        if changed { repaint() }
    }

    /// Everything painted and placed again, at once: the look, the scale or
    /// the width changed.
    private func repaint() {
        still {
            paintTints()
            paintWords()
            paintCover()
            paintDoors()
            paintCount()
            for (id, bud) in budFaces { bud.paint(tune: tune(of: id), ink: ink, muted: muted, scale: scale, width: bounds.width) }
            lay(animated: false)
        }
    }

    private func tune(of id: Tab.ID) -> Tune? { face?.others.first { $0.tab == id }?.tune }

    private func paintTints() {
        IslandGlass.tint(island, face?.tune.accent?.withAlphaComponent(dark ? 0.26 : 0.16))
        for (id, glass) in budGlass { IslandGlass.tint(glass, tune(of: id)?.accent?.withAlphaComponent(dark ? 0.26 : 0.16)) }
        bars.color(playing ? accent : muted)
    }

    private var titleRun: LineLayer.Run {
        LineLayer.Run(text: face?.tune.title ?? "", font: .systemFont(ofSize: Band.size, weight: .medium), color: playing ? ink : muted)
    }

    private var artistRun: LineLayer.Run {
        // In a live stream, "Ad · muted" or "Catching up…" while so.
        LineLayer.Run(text: face?.tune.subtitle ?? "", font: .systemFont(ofSize: Band.size), color: muted)
    }

    private var openTitleRun: LineLayer.Run {
        LineLayer.Run(text: face?.tune.title ?? "", font: .systemFont(ofSize: 13.5, weight: .semibold), color: playing ? ink : muted)
    }

    private func paintWords() {
        for line in [title, artist, openTitle, openArtist, elapsed, remaining] { line.scale = scale }
        let slots = self.slots(for: face)
        title.bounds.size = CGSize(width: slots.title, height: Band.row)
        artist.bounds.size = CGSize(width: slots.artist, height: Band.row)
        title.show([titleRun], width: slots.title)
        artist.show(face?.tune.subtitle.isEmpty == false ? [artistRun] : [], width: slots.artist)
        let wide = openWords
        openTitle.bounds.size = CGSize(width: wide, height: 18)
        openArtist.bounds.size = CGSize(width: wide, height: 18)
        openTitle.show([openTitleRun], width: wide)
        openArtist.show(face?.tune.subtitle.isEmpty == false ? [artistRun] : [], width: wide)
        paintTimes()
    }

    private func paintTimes() {
        guard let tune = face?.tune else { return }
        // Held, the point under the finger; else where it plays.
        let at = held.map { $0 * tune.duration } ?? tune.position()
        let small = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        // A live stream has no time gone to count and none left: Live, or
        // how far behind it, where the time left would be. Behind, those
        // words are the way back to the edge, in ink as a button's are.
        let behind = held.map { LiveEdge.words(behind: (1 - $0) * tune.kept()) }
        let left = LineLayer.Run(text: tune.live ? "" : BandView.clock(at), font: small, color: muted)
        let right = LineLayer.Run(
            text: tune.live ? behind ?? tune.words()
                : tune.duration > 0 ? "−" + BandView.clock(max(0, tune.duration - at)) : "",
            font: small, color: held == nil && tune.goesLive() ? ink : muted)
        elapsed.bounds.size = CGSize(width: 48, height: 14)
        remaining.bounds.size = CGSize(width: 48, height: 14)
        elapsed.show([left], width: 48)
        let w = ceil(LineLayer.natural([right]))
        remaining.bounds.size.width = w
        remaining.show([right], width: w)
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    private func paintCover() {
        if let image = face?.tune.cover {
            cover.contents = image
            cover.backgroundColor = nil
        } else {
            cover.contents = nil
            cover.backgroundColor = ink.copy(alpha: 0.12)
        }
        cover.opacity = playing ? 1 : 0.55
    }

    private func paintDoors() {
        for door in doorsAll { door.paint(ink: ink, muted: muted, scale: scale, playing: playing, silent: silent) }
        restDoor.paint(ink: playing ? ink : muted, muted: muted, scale: scale, playing: playing)
        placeRest(animated: false)
        paintSite()
    }

    /// The rest door's square, in the island's own space at rest: on the
    /// bars, as tall as the cover.
    private var restFrame: CGRect {
        let mid = pillWidth(others) - Band.end - BarsLayer.width / 2
        return CGRect(x: mid - Band.cover / 2, y: Band.inset, width: Band.cover, height: Band.cover)
    }

    /// Bars or the rest door: at rest, play while paused, pause under the
    /// pointer while playing; open, the bars as before.
    private func placeRest(animated: Bool, after delay: CFTimeInterval = 0) {
        let shows = up && !open && (!playing || pointed == .rest)
        let was = restDoor.presentation()?.opacity ?? restDoor.opacity
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated && !reduced ? 0.12 : 0)
        if !animated || reduced { CATransaction.setDisableActions(true) }
        restDoor.bounds = CGRect(origin: .zero, size: restFrame.size)
        restDoor.position = CGPoint(x: restFrame.midX, y: restFrame.midY)
        restDoor.opacity = shows ? 1 : 0
        bars.opacity = shows ? 0 : 1
        CATransaction.commit()
        // The card closing: the door comes in once the row has landed, not
        // over the shrinking card's corner.
        if animated, !reduced, shows, delay > 0, was < 1 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.12
            fade.beginTime = restDoor.convertTime(CACurrentMediaTime(), from: nil) + delay
            fade.fillMode = .backwards
            restDoor.add(fade, forKey: "opacity")
        }
    }

    /// The way back wears the playing site's icon.
    private func paintSite() {
        let tab = player?.tab
        let icon = tab?.icon.flatMap { image -> CGImage? in
            var rect = CGRect(x: 0, y: 0, width: 16, height: 16)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
        }
        let named = tab?.address?.host() != nil ? siteName : (tab?.title ?? "")
        home.site(icon: icon, initial: String(named.trimmingCharacters(in: .whitespaces).prefix(1)), scale: scale)
    }

    /// The playing site by the name people know it by.
    private var siteName: String {
        guard let host = player?.tab?.address?.host() else { return "the Tab" }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let known = ["music.youtube.com": "YouTube Music", "youtube.com": "YouTube", "m.youtube.com": "YouTube",
                     "open.spotify.com": "Spotify", "soundcloud.com": "SoundCloud", "music.apple.com": "Apple Music",
                     "bandcamp.com": "Bandcamp", "deezer.com": "Deezer", "tidal.com": "TIDAL", "listen.tidal.com": "TIDAL",
                     "music.yandex.ru": "Yandex Music", "music.amazon.com": "Amazon Music", "twitch.tv": "Twitch", "vimeo.com": "Vimeo"]
        if let name = known[bare] { return name }
        if bare.hasSuffix(".bandcamp.com") { return "Bandcamp" }
        return bare
    }

    private func paintCount() {
        let n = face?.others.count ?? 0
        guard n >= 2 else { return }
        let run = LineLayer.Run(text: "\(n)", font: .systemFont(ofSize: 10, weight: .semibold), color: CGColor(gray: dark ? 0.08 : 0.98, alpha: 1))
        let (image, width) = LineLayer.picture([run], width: nil, height: 14, scale: scale)
        count.contents = image
        count.contentsScale = scale
        count.bounds.size = CGSize(width: max(14, ceil(width) + 8), height: 14)
        count.cornerRadius = 7
        count.backgroundColor = ink
    }

    // MARK: geometry

    private var width: CGFloat { bounds.width }
    /// The island's width at rest, the column's less its insets; open, the
    /// card takes the view's whole width, never less than Band.minCard.
    var rest: CGFloat = 0 {
        didSet { if rest != oldValue { repaint() } }
    }

    /// The column on the window's right: the view's right end is the
    /// column's, and the island at rest is the left one mirrored, against
    /// the window's edge with its buds toward the page, so the open card,
    /// the view's whole width, grows from that corner leftward over it.
    var trailing = false {
        didSet { if trailing != oldValue { repaint() } }
    }

    /// A frame at rest, laid out as on the left in the column's width from
    /// the view's left, where the column puts it: on the right, mirrored
    /// against the view's right end.
    private func side(_ frame: CGRect) -> CGRect {
        guard trailing else { return frame }
        return CGRect(x: width - frame.maxX, y: frame.minY, width: frame.width, height: frame.height)
    }

    /// The way from the island to its buds on screen: right, or left with
    /// the column on the right.
    private var toBuds: Int { trailing ? -1 : 1 }

    /// The island's width at rest: the column's, less its buds.
    private func pillWidth(_ others: Int) -> CGFloat {
        switch others {
        case 0: return rest
        case 1: return rest - Band.bud - Band.split
        default: return rest - Band.bud - Band.split - Band.peek
        }
    }

    private var others: Int { face?.others.count ?? 0 }

    private var islandFrame: CGRect {
        open ? CGRect(x: 0, y: 0, width: width, height: Band.card) : side(CGRect(x: 0, y: 0, width: pillWidth(others), height: Band.row))
    }

    private var islandCorner: CGFloat { open ? Radius.card : Band.row / 2 }

    /// The cover: round at rest, a control's corner open.
    private var coverFrame: CGRect {
        open ? CGRect(x: CardFrame.inset, y: Band.card - CardFrame.inset - Band.art, width: Band.art, height: Band.art)
             : CGRect(x: Band.inset, y: Band.inset, width: Band.cover, height: Band.cover)
    }

    private var coverCorner: CGFloat { open ? Radius.control : Band.cover / 2 }

    private var textX: CGFloat { Band.inset + Band.cover + Band.air }
    private var openX: CGFloat { CardFrame.inset + Band.art + CardFrame.inset }
    private var openWords: CGFloat { max(0, width - openX - CardFrame.inset - BarsLayer.width - 8) }
    /// Open, the progress line's middle, 16 under the cover, and how long it is.
    private var lineY: CGFloat { Band.card - CardFrame.inset - Band.art - 16 }
    private var lineWidth: CGFloat { width - 2 * CardFrame.inset }

    /// The widths the words have at rest: the title's, and the artist's
    /// after it, both going out before the bars.
    private func slots(for face: Player.Face?) -> (title: CGFloat, artist: CGFloat, second: CGFloat) {
        let natural = LineLayer.natural([LineLayer.Run(text: face?.tune.title ?? "", font: .systemFont(ofSize: Band.size, weight: .medium), color: ink)])
        let end = pillWidth(face?.others.count ?? 0) - Band.end - BarsLayer.width - 8
        let room = max(0, end - textX)
        let title = min(natural, room)
        let second = textX + title + LineLayer.spacing
        return (title, max(0, textX + room - second), second)
    }

    /// Where a bud stands: at rest beside the island, open a row over the
    /// card. Past the second at rest, or the listed ones open, it waits
    /// behind the last one shown.
    private func budFrame(_ i: Int, of n: Int) -> CGRect {
        if open {
            let row = min(i, Band.listed - 1)
            return CGRect(x: 0, y: Band.card + Band.split + CGFloat(row) * (Band.row + Band.split), width: width, height: Band.row)
        }
        let x = pillWidth(n) + Band.split + (i == 0 ? 0 : Band.peek)
        return side(CGRect(x: x, y: 0, width: Band.bud, height: Band.bud))
    }

    private func budShown(_ i: Int) -> Bool { open ? i < Band.listed : i < 2 }

    /// Where a bud shows its cover: round in the middle of a bud, at a
    /// row's start open (BudFace.place).
    private func budCover(_ frame: CGRect) -> CGRect {
        if open { return CGRect(x: frame.minX + Band.inset, y: frame.minY + Band.inset, width: Band.cover, height: Band.cover) }
        let side = frame.height - 6
        return CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
    }

    private var doorsShown: [BandDoor] {
        guard let tune = face?.tune else { return [play] }
        if tune.seeks { return [back, play, forward] }
        return [tune.previous ? previous : nil, play, tune.next ? next : nil].compactMap { $0 }
    }

    /// The buttons' row: previous, play and next in the middle, a door
    /// apart, whether the skips are there or not, so play never moves (15
    /// seconds back and on take the skips' places); the way back at the
    /// left end and the sound at the right, their grounds as far from the
    /// side as from the bottom.
    private func doorFrame(_ door: BandDoor) -> CGRect {
        let mid = CardFrame.inset + Band.door / 2 - 4
        if door === home || door === sound {
            // As far from the side as from the bottom, so the round ground
            // sits square in the card's corner, not pushed into its curve.
            let off = mid - Band.small / 2
            let x = door === home ? off : width - off - Band.small
            return CGRect(x: x, y: off, width: Band.small, height: Band.small)
        }
        let at: CGFloat = door === previous || door === back ? -1 : door === next || door === forward ? 1 : 0
        // A door and 12 apart; in a narrow card the room between the way
        // back and the sound shared out evenly, the gaps at the ends the
        // same as between the doors.
        let ends = 2 * (mid - Band.small / 2 + Band.small)
        let step = min(Band.door + 12, Band.door + (width - ends - 3 * Band.door) / 4)
        return CGRect(x: width / 2 + at * step - Band.door / 2, y: mid - Band.door / 2, width: Band.door, height: Band.door)
    }

    // MARK: laying it out

    /// Every frame for the state as it is: the glass by NSAnimationContext,
    /// the layers over it by Core Animation, on one curve and time.
    private func lay(animated: Bool, curve: CAMediaTimingFunction = Curve.out, time: CFTimeInterval = 0.24) {
        settle()
        let move = animated && !reduced
        let t = move ? time : 0
        let frame = islandFrame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = t
            context.timingFunction = curve
            context.allowsImplicitAnimation = move
            if move { island.animator().frame = frame } else { island.frame = frame }
            IslandGlass.corner(island, top: islandCorner, bottom: Band.foot)
            let ids = face?.others.map(\.tab) ?? []
            for (i, id) in ids.enumerated() {
                guard let glass = budGlass[id] else { continue }
                let target = budFrame(i, of: ids.count)
                if move { glass.animator().frame = target; glass.animator().alphaValue = budShown(i) ? 1 : 0 }
                else { glass.frame = target; glass.alphaValue = budShown(i) ? 1 : 0 }
                IslandGlass.corner(glass, top: Band.row / 2, bottom: Band.row / 2)
            }
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(t)
        CATransaction.setAnimationTimingFunction(curve)
        if !move { CATransaction.setDisableActions(true) }
        placeLayers(animated: move, time: t, curve: curve)
        CATransaction.commit()
    }

    /// The layers over the glass where the state puts them.
    private func placeLayers(animated: Bool, time: CFTimeInterval, curve: CAMediaTimingFunction) {
        let shape = islandFrame
        glide(faceLayer, to: shape, animated: animated, time: time, curve: curve)
        faceLayer.cornerRadius = min(islandCorner, Band.foot)
        glide(cover, to: coverFrame, animated: animated, time: time, curve: curve)
        cover.cornerRadius = coverCorner
        let slots = self.slots(for: face)
        // At rest the words sit on the row; open they go to the card's
        // first two lines, the resting pair fading out as they go and the
        // open pair coming in from where the resting one was (P2, P4).
        let restTitle = CGRect(x: textX, y: 0, width: slots.title, height: Band.row)
        let restArtist = CGRect(x: slots.second, y: 0, width: slots.artist, height: Band.row)
        let topTitle = CGRect(x: openX, y: Band.card - CardFrame.inset - 22, width: openWords, height: 18)
        let topArtist = CGRect(x: openX, y: Band.card - CardFrame.inset - 40, width: openWords, height: 18)
        glide(title, to: open ? CGRect(origin: topTitle.origin, size: restTitle.size) : restTitle, animated: animated, time: time, curve: curve)
        glide(artist, to: open ? CGRect(origin: topArtist.origin, size: restArtist.size) : restArtist, animated: animated, time: time, curve: curve)
        glide(openTitle, to: open ? topTitle : CGRect(origin: CGPoint(x: textX, y: 5), size: topTitle.size), animated: animated, time: time, curve: curve)
        glide(openArtist, to: open ? topArtist : CGRect(origin: CGPoint(x: slots.second, y: 5), size: topArtist.size), animated: animated, time: time, curve: curve)
        fade(title, to: open ? 0 : 1, time: open ? time * 0.4 : time, animated: animated)
        fade(artist, to: open ? 0 : 1, time: open ? time * 0.4 : time, animated: animated)
        fade(openTitle, to: open ? 1 : 0, time: open ? time : time * 0.4, animated: animated, delay: open ? time * 0.2 : 0)
        fade(openArtist, to: open ? 1 : 0, time: open ? time : time * 0.4, animated: animated, delay: open ? time * 0.25 : 0)
        bars.tall = open ? 13 : 11
        let barsAt = open ? CGPoint(x: width - CardFrame.inset - BarsLayer.width / 2, y: Band.card - CardFrame.inset - 13)
                          : CGPoint(x: shape.width - Band.end - BarsLayer.width / 2, y: Band.row / 2)
        glide(bars, to: CGRect(x: barsAt.x - BarsLayer.width / 2, y: barsAt.y - bars.tall / 2, width: BarsLayer.width, height: bars.tall),
              animated: animated, time: time, curve: curve)
        // Open only: the progress, the times and the buttons, out of the
        // card as it grows, a beat after the shape (P3).
        track.frame = CGRect(x: CardFrame.inset, y: lineY - Band.line / 2, width: lineWidth, height: Band.line)
        track.backgroundColor = ink.copy(alpha: 0.12)
        fill.backgroundColor = ink.copy(alpha: 0.78)
        fill.position = CGPoint(x: CardFrame.inset, y: lineY - Band.line / 2)
        elapsed.frame = CGRect(x: CardFrame.inset, y: lineY - 20, width: elapsed.bounds.width, height: 14)
        remaining.frame = CGRect(x: width - CardFrame.inset - remaining.bounds.width, y: lineY - 20, width: remaining.bounds.width, height: 14)
        // A live stream that keeps nothing to go back into has no line,
        // only its words.
        let lined = !(face?.tune.live == true && face?.tune.rewinds == false)
        let extra: [CALayer] = [track, fill, elapsed, remaining]
        for layer in extra {
            let on = open && (lined || layer === remaining || layer === elapsed)
            fade(layer, to: on ? 1 : 0, time: open ? time * 0.7 : time * 0.35, animated: animated, delay: open ? time * 0.3 : 0)
        }
        let shown = doorsShown + (AudioWatch.canMute ? [sound] : []) + [home]
        // A live stream at its edge: nowhere to go on, as the floating
        // window says it.
        forward.dim(face?.tune.live == true && face?.tune.goesLive() == false)
        for door in doorsAll {
            door.bounds = CGRect(origin: .zero, size: doorFrame(door).size)
            door.position = CGPoint(x: doorFrame(door).midX, y: doorFrame(door).midY)
            fade(door, to: open && shown.contains(door) ? 1 : 0, time: open ? time * 0.7 : time * 0.35, animated: animated, delay: open ? time * 0.35 : 0)
        }
        if open { progress() }
        placeRest(animated: animated, after: open ? 0 : time * 0.8)
        // The buds' faces with their glass.
        let ids = face?.others.map(\.tab) ?? []
        for (i, id) in ids.enumerated() {
            guard let bud = budFaces[id] else { continue }
            bud.place(in: budFrame(i, of: ids.count), open: open, shown: budShown(i), animated: animated, time: time, curve: curve)
        }
        if ids.count >= 2, !open {
            let b = budFrame(0, of: ids.count)
            let at = CGPoint(x: trailing ? b.minX + 2 : b.maxX - 2, y: b.maxY - 2)
            if count.opacity == 0 { still { count.position = at } }
            count.position = at
            fade(count, to: 1, time: time, animated: animated)
        } else {
            fade(count, to: 0, time: time * 0.5, animated: animated)
        }
    }

    /// The progress line: where it stands, and going on by itself on the
    /// render server for as long as it plays (nothing ticks for it); held,
    /// under the finger and still.
    private func progress() {
        guard let tune = face?.tune else { return }
        let full = lineWidth
        // A live stream's line stands still: playing, it keeps as far
        // behind its edge as it was.
        let at = CGFloat(held ?? tune.through())
        fill.removeAnimation(forKey: "run")
        fill.bounds = CGRect(x: 0, y: 0, width: full * min(1, at), height: Band.line)
        guard held == nil, tune.playing, !tune.live, tune.duration > 0, at < 1 else { return }
        let run = CABasicAnimation(keyPath: "bounds.size.width")
        run.fromValue = full * at
        run.toValue = full
        run.duration = max(0.1, tune.duration - tune.position())
        run.timingFunction = CAMediaTimingFunction(name: .linear)
        if #available(macOS 12.0, *) { run.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 15, preferred: 10) }
        fill.bounds.size.width = full
        fill.add(run, forKey: "run")
    }

    // MARK: the face

    private func show(_ fresh: Player.Face?) {
        let t0 = CACurrentMediaTime()
        defer { Player.cost += (CACurrentMediaTime() - t0) * 1000 }
        let was = face
        // A line held for a tab no longer shown is let go of, and moves
        // nothing.
        if fresh?.tab != was?.tab, held != nil {
            held = nil
            if pressed == .progress { pressed = nil }
            if sweep == .scrub { sweep = nil }
        }
        guard let fresh else {
            face = nil
            if up { leave() }
            return
        }
        guard up, let was else {
            face = fresh
            syncBuds(from: nil, animated: false)
            still {
                paintTints()
                paintWords()
                paintCover()
                paintDoors()
                paintCount()
                lay(animated: false)
                if fresh.tune.playing { bars.play(animated: false) } else { bars.pause(animated: false) }
            }
            label()
            arrive()
            return
        }
        face = fresh
        let swapped = was.tab != fresh.tab
        let skipped = !swapped && (was.tune.title != fresh.tune.title || was.tune.artist != fresh.tune.artist)
        let way = heading
        heading = 1
        if swapped || skipped {
            // P8: the old face goes the way of the change and the new one
            // comes from the other side; a bud's cover rides in from its bud.
            let from = was.others.firstIndex { $0.tab == fresh.tab }.map { budCover(budFrame($0, of: was.others.count)) }
            // After a swipe the cover came in with the face, under the fingers.
            carousel(way: way, coverFrom: swapped && swiped == nil ? from : nil, fromSwipe: swiped)
            swiped = nil
        }
        syncBuds(from: was, animated: true, arriving: swapped ? was.tab : nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paintTints()
        if swapped || skipped || was.tune.playing != fresh.tune.playing || was.others.count != fresh.others.count
            || was.tune.subtitle != fresh.tune.subtitle { paintWords() }
        if swapped || skipped || was.tune.cover !== fresh.tune.cover || was.tune.playing != fresh.tune.playing { paintCover() }
        // Pause and play turn into each other on the island's own tab.
        if !swapped, was.tune.playing != fresh.tune.playing {
            play.turn(playing: fresh.tune.playing, animated: open && !reduced)
            restDoor.turn(playing: fresh.tune.playing, animated: !open && !reduced)
        }
        if was.tune.playing != fresh.tune.playing || was.tune.next != fresh.tune.next || was.tune.previous != fresh.tune.previous { paintDoors() }
        if was.others.count != fresh.others.count { paintCount() }
        CATransaction.commit()
        if !swapped, !skipped, was.tune.cover !== fresh.tune.cover, !reduced {
            // The cover came in after the words: it fades in where the
            // plate was, never pops.
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            cover.add(fade, forKey: "cover")
        }
        if was.tune.playing != fresh.tune.playing || swapped {
            // P6: the state flips at once, the bars fall or rise.
            if fresh.tune.playing { if !bars.moving { bars.play(animated: !reduced) } } else { bars.pause(animated: !reduced) }
        }
        if was.others.map(\.tab) != fresh.others.map(\.tab) || swapped {
            lay(animated: true, curve: Curve.give, time: 0.42)
        } else {
            still { lay(animated: false) }
        }
        if open { progress(); paintTimes(); placeTimes() }
        label()
    }

    /// The old face slides out the way it went, the new one comes in
    /// from the other side, its cover from its bud when it was one.
    private func carousel(way: Int, coverFrom bud: CGRect?, fromSwipe: CGFloat?) {
        still {
            faceLayer.sublayerTransform = CATransform3DIdentity
            incoming?.layer.removeFromSuperlayer()
            incoming = nil
            budFaces.values.forEach { $0.shrink(1) }
        }
        guard !reduced else {
            crossfade()
            return
        }
        let dir = CGFloat(way >= 0 ? 1 : -1)
        let span: CGFloat = 40
        // What was: a picture of it, sliding off.
        let leaving = CALayer()
        leaving.frame = faceLayer.frame
        leaving.masksToBounds = true
        leaving.cornerRadius = faceLayer.cornerRadius
        leaving.cornerCurve = .continuous
        for layer in [cover, open ? openTitle : title, open ? openArtist : artist] {
            let copy = CALayer()
            copy.frame = layer.frame
            copy.contents = layer is LineLayer ? (layer as? LineLayer)?.pictureContents : layer.contents
            copy.contentsGravity = layer is LineLayer ? .bottomLeft : .resizeAspectFill
            copy.contentsScale = scale
            copy.backgroundColor = layer.backgroundColor
            copy.cornerRadius = layer.cornerRadius
            copy.cornerCurve = .continuous
            copy.masksToBounds = layer === cover
            copy.opacity = layer.opacity
            leaving.addSublayer(copy)
        }
        let start = fromSwipe ?? 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { leaving.removeFromSuperlayer() }
        ink0.insertSublayer(leaving, above: faceLayer)
        let off = CABasicAnimation(keyPath: "sublayerTransform.translation.x")
        off.fromValue = start
        off.toValue = fromSwipe != nil ? -dir * faceLayer.bounds.width : -dir * span
        off.duration = fromSwipe != nil ? 0.26 : 0.18
        off.timingFunction = Curve.out
        off.fillMode = .forwards
        off.isRemovedOnCompletion = false
        let gone = CABasicAnimation(keyPath: "opacity")
        gone.fromValue = 1
        gone.toValue = 0
        gone.duration = fromSwipe != nil ? 0.26 : 0.14
        gone.fillMode = .forwards
        gone.isRemovedOnCompletion = false
        leaving.add(off, forKey: "off")
        leaving.add(gone, forKey: "gone")
        // What is: the words in from the other side, the cover from its bud.
        let enter = CASpringAnimation(perceptualDuration: 0.3, bounce: 0.12)
        enter.keyPath = "sublayerTransform.translation.x"
        enter.fromValue = (fromSwipe.map { $0 + dir * faceLayer.bounds.width }) ?? dir * span
        enter.toValue = 0
        enter.duration = enter.settlingDuration
        faceLayer.add(enter, forKey: "enter")
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 0
        show.duration = 0.16
        show.beginTime = faceLayer.convertTime(CACurrentMediaTime(), from: nil) + 0.04
        show.fillMode = .backwards
        faceLayer.add(show, forKey: "show")
        if let bud {
            // The cover rides in from where the bud showed it, over
            // everything, as a drop, and lands as the island's.
            let ride = CALayer()
            let side = bud.width
            ride.frame = bud
            ride.contents = face?.tune.cover
            ride.contentsGravity = .resizeAspectFill
            ride.masksToBounds = true
            ride.cornerRadius = side / 2
            ride.cornerCurve = .continuous
            ink0.addSublayer(ride)
            let to = coverFrame.offsetBy(dx: islandFrame.minX, dy: 0)
            let a = CABasicAnimation(keyPath: "position")
            a.toValue = CGPoint(x: to.midX, y: to.midY)
            let b = CABasicAnimation(keyPath: "bounds.size")
            b.toValue = to.size
            let c = CABasicAnimation(keyPath: "cornerRadius")
            c.toValue = coverCorner
            let g = CAAnimationGroup()
            g.animations = [a, b, c]
            g.duration = 0.26
            g.timingFunction = Curve.out
            g.fillMode = .forwards
            g.isRemovedOnCompletion = false
            ride.add(g, forKey: "ride")
            // The island's own cover waits under it until it lands.
            let hold = CABasicAnimation(keyPath: "opacity")
            hold.fromValue = 0
            hold.toValue = 0
            hold.duration = 0.26
            cover.add(hold, forKey: "hold")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.27) { ride.removeFromSuperlayer() }
        }
        CATransaction.commit()
    }

    /// Without motion: one face over the other, 0.15 s.
    private func crossfade() {
        let a = CATransition()
        a.type = .fade
        a.duration = 0.15
        faceLayer.add(a, forKey: "swap")
    }

    /// The buds as the face has them: one made for a newcomer, out of the
    /// island's right end (the glass gives it a neck as it leaves), one put
    /// back into it for a tab that stopped, and the one the island just was
    /// dropping into the bud its new face left.
    private func syncBuds(from was: Player.Face?, animated: Bool, arriving: Tab.ID? = nil) {
        let ids = face?.others.map(\.tab) ?? []
        let holder = IslandGlass.holder(of: glassBox)
        let n = ids.count
        // Gone: into the island's end, then away.
        for (id, glass) in budGlass where !ids.contains(id) {
            budGlass[id] = nil
            let bud = budFaces.removeValue(forKey: id)
            let end = side(CGRect(x: pillWidth(n) - Band.bud, y: 2, width: Band.bud - 4, height: Band.bud - 4))
            if animated, !reduced, face?.tab != id {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.28
                    context.timingFunction = Curve.inOut
                    context.allowsImplicitAnimation = true
                    glass.animator().frame = open ? glass.frame.insetBy(dx: 0, dy: Band.row / 2) : end
                    glass.animator().alphaValue = 0
                }, completionHandler: { glass.removeFromSuperview() })
                bud?.leave(to: end, time: 0.28)
            } else {
                glass.removeFromSuperview()
                bud?.removeFromSuperlayer()
            }
        }
        for (i, id) in ids.enumerated() where budGlass[id] == nil {
            let glass = IslandGlass.drop()
            IslandGlass.corner(glass, top: Band.row / 2, bottom: Band.row / 2)
            IslandGlass.tint(glass, face?.others[i].tune.accent?.withAlphaComponent(dark ? 0.26 : 0.16))
            let target = budFrame(i, of: n)
            let swapIn = id == arriving
            // A newcomer is born inside the island's end; the old face drops
            // into the bud its new face left, small first.
            let start = swapIn ? CGRect(x: target.midX - 6, y: target.midY - 6, width: 12, height: 12)
                               : side(CGRect(x: pillWidth(was?.others.count ?? 0) - Band.bud, y: 2, width: Band.bud - 4, height: Band.bud - 4))
            glass.frame = animated && !reduced ? start : target
            glass.alphaValue = budShown(i) ? 1 : 0
            holder.addSubview(glass, positioned: .below, relativeTo: nil)
            budGlass[id] = glass
            let bud = BudFace()
            bud.paint(tune: face?.others[i].tune, ink: ink, muted: muted, scale: scale, width: width)
            ink0.insertSublayer(bud, below: count)
            bud.place(in: glass.frame, open: open, shown: budShown(i), animated: false, time: 0, curve: Curve.out)
            budFaces[id] = bud
            if swapIn, animated, !reduced { bud.drop(after: 0.16) }
        }
        // Repainted where their tunes changed.
        for (i, id) in ids.enumerated() {
            if let old = was?.others.first(where: { $0.tab == id })?.tune, old == face?.others[i].tune { continue }
            budFaces[id]?.paint(tune: face?.others[i].tune, ink: ink, muted: muted, scale: scale, width: width)
            IslandGlass.tint(budGlass[id] ?? NSView(), face?.others[i].tune.accent?.withAlphaComponent(dark ? 0.26 : 0.16))
        }
        // The buds in order under the island's glass, the first on top.
        for id in ids.reversed() { if let glass = budGlass[id] { holder.addSubview(glass, positioned: .below, relativeTo: island) } }
    }

    private func label() {
        guard let tune = face?.tune else { return }
        var words = "Now playing: \(tune.title)\(tune.artist.isEmpty ? "" : ", " + tune.artist)"
        if others > 0 { words += ", \(others) more playing" }
        setAccessibilityLabel(words)
    }

    // MARK: arriving and leaving

    /// P3, P10: out of the column's bottom edge, 0.22 s, the column's own
    /// arrival, the foot and the rows rising on the same curve and time
    /// just over it, one stack pushed up rather than a foot jumping out of
    /// the way and an island fading in under it. It leaves by the same
    /// path, quicker. Already standing room (it went and came back at
    /// once), it only comes up by 8 and in.
    private func arrive() {
        up = true
        rising = !reduced
        placeRest(animated: false)
        let room = player?.room
        let pushes = room?.up == false && !reduced
        let from: CGFloat = reduced ? 0 : pushes ? -Band.room : -8
        // Clipped at its own bottom while it moves, so it comes out of the
        // edge rather than drawing below the column.
        clipsToBounds = pushes
        for view in [glassBox, inkView] {
            view.setFrameOrigin(NSPoint(x: 0, y: from))
            view.alphaValue = pushes ? 1 : 0
        }
        if let room, !room.up {
            withAnimation(reduced ? nil : Motion.arrive) { room.up = true }
            // SwiftUI moves the foot on its next pass, a frame or so on
            // (filmed): the island waits that long, so the two go as one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { [weak self] in
                guard let self, self.up else { return }
                self.rise()
            }
            return
        }
        rise()
    }

    private func rise() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = Curve.arrive
            context.allowsImplicitAnimation = true
            for view in [glassBox, inkView] {
                view.animator().setFrameOrigin(.zero)
                view.animator().alphaValue = 1
            }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.up else { return }
                self.clipsToBounds = false
                self.rising = false
                self.settle()
            }
        }
    }

    /// Coming up from the edge, its glass and ink below where they rest.
    private var rising = false

    /// Up and done moving: the glass and the ink exactly where they rest,
    /// on the view's own bottom. In a tester's recording of 0.0.19
    /// (2026-10-09) the capsule stood about 8 points low, the start of a
    /// rise, on the window's bottom edge with no gap under it, through
    /// every hover; whatever leaves a rise short of its end, every layout
    /// and every change of size puts them back.
    private func settle() {
        guard up, !rising else { return }
        for view in [glassBox, inkView] {
            if view.frame != bounds { view.frame = bounds }
            if view.alphaValue != 1 { view.alphaValue = 1 }
        }
    }

    private func leave() {
        up = false
        rising = false
        // Back down into the edge it came out of, the foot coming down over
        // it on the same curve and time, soft at both ends (Band.sink).
        let pushes = player?.room.up == true && !reduced
        if let room = player?.room, room.up {
            withAnimation(reduced ? nil : Band.sinking) { room.up = false }
        }
        if hovering || open { hover(false, animated: false) }
        clipsToBounds = pushes
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Band.sink
            context.timingFunction = Curve.inOut
            context.allowsImplicitAnimation = true
            for view in [glassBox, inkView] {
                view.animator().setFrameOrigin(NSPoint(x: 0, y: reduced ? 0 : pushes ? -Band.room : -8))
                if !pushes { view.animator().alphaValue = 0 }
            }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.up else { return }
                for view in [self.glassBox, self.inkView] { view.alphaValue = 0 }
                self.clipsToBounds = false
            }
        }
    }

    // MARK: under the pointer

    /// The pointer on the island: after a beat it opens on a spring (P10:
    /// passing over it opens nothing), and closes quicker, no give, once
    /// the pointer has left the card and its rows.
    private func hover(_ on: Bool, animated: Bool = true) {
        guard on != hovering || (!on && open) else { return }
        hovering = on
        waitOpen?.cancel()
        waitOpen = nil
        if on {
            let item = DispatchWorkItem { [weak self] in self?.setOpen(true) }
            waitOpen = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Band.wait, execute: item)
        } else {
            setOpen(false, animated: animated)
        }
    }

    private func setOpen(_ on: Bool, animated: Bool = true) {
        guard on != open else { return }
        open = on
        // P3: grown from where it was, the shape first and the rest a beat
        // after; back quicker and with no give.
        lay(animated: animated, curve: on ? Curve.give : Curve.out, time: on ? 0.38 : 0.24)
        ticking?.invalidate()
        ticking = nil
        if on {
            // Where the page really is: a site that starts over on its own,
            // or seeks with nothing said, has gone on from the last reading.
            player?.reread()
            paintTimes()
            // The site's icon may have come since the face did.
            still { paintSite() }
            beat = 0
            ticking = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.beat += 1
                    // A live stream's words change by the minute, and are
                    // read again as the stream is (TuneWatch.followLive).
                    guard let tune = self.face?.tune, tune.playing, !tune.live else { return }
                    self.still { self.paintTimes(); self.placeTimes() }
                    // Open, the page's own clock every two seconds: a site
                    // that starts over by itself or seeks with nothing said
                    // (a stream looped by its script) is where it says.
                    if self.beat % 2 == 0 { self.player?.reread() }
                    // A loop's line runs to its end on the render server
                    // and stops there: started again once it went round.
                    if tune.loops, self.held == nil, self.fill.animation(forKey: "run") == nil { self.progress() }
                }
            }
        } else if pointed != nil {
            pointed = nil
            still { doorsAll.forEach { $0.lit(false) } }
        }
    }

    private func placeTimes() {
        remaining.frame = CGRect(x: width - CardFrame.inset - remaining.bounds.width, y: lineY - 20, width: remaining.bounds.width, height: 14)
    }

    /// Where the glass is, the island's and the buds', for the pointer.
    /// The glass and its shadow, open or at rest.
    var standing: [CGRect] { shapes().map { $0.0.insetBy(dx: -6, dy: -6) } }

    private func shapes() -> [(CGRect, Spot?)] {
        guard up else { return [] }
        var out: [(CGRect, Spot?)] = []
        for i in (face?.others ?? []).indices where budShown(i) {
            out.append((budFrame(i, of: others), .bud(open ? i : 0)))
        }
        out.append((islandFrame, nil))
        return out
    }

    /// A two-finger swipe that begins on the island is the island's: the
    /// column's swipe between spaces leaves it alone (SpaceSwipe). At rest
    /// with buds it swaps them; open, or with none to swap, it scrubs. Over
    /// the open card's rows, or with no line to scrub, the column has it.
    static func claims(_ event: NSEvent) -> Bool {
        guard let view = last, view.window === event.window else { return false }
        return view.way(at: view.convert(event.locationInWindow, from: nil)) != nil
    }

    /// What two fingers sideways do from here, if anything.
    private func way(at p: CGPoint) -> Sweep? {
        guard up else { return nil }
        if !open, others > 0 {
            return shapes().contains { $0.0.insetBy(dx: -2, dy: -2).contains(p) } ? .swap : nil
        }
        return face?.tune.scrubs == true && islandFrame.insetBy(dx: -2, dy: -2).contains(p) ? .scrub : nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard up, let superview else { return nil }
        let p = convert(point, from: superview)
        return shapes().contains { $0.0.insetBy(dx: -2, dy: -2).contains(p) } ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { pointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointer(at: nil) }

    /// The bench's: the real pointer ignored, so a test world's pictures
    /// show what the bench asked for rather than where the mouse happens to be.
    static var deaf = false

    private func pointer(at p: CGPoint?) {
        guard !BandView.deaf else { return }
        let island = islandFrame.insetBy(dx: -2, dy: -2)
        let onIsland = up && p.map { island.contains($0) } == true
        // Open, the card and its rows hold it; at rest only the island
        // itself, not its buds, opens it.
        let inside = open ? up && p.map { at in shapes().contains { $0.0.insetBy(dx: -6, dy: -6).contains(at) } } == true : onIsland
        if inside, !open, p.flatMap(spot(at:)) == .rest {
            // On the rest door: a button, which opens nothing; the row
            // beside it does.
            waitClose?.cancel()
            waitClose = nil
            if hovering {
                waitOpen?.cancel()
                waitOpen = nil
                hovering = false
            }
        } else if inside {
            waitClose?.cancel()
            waitClose = nil
            if !hovering { hover(true) }
        } else if hovering, waitClose == nil {
            // A moment's grace: the pointer crossing the gap between a
            // row and the card doesn't close it.
            let item = DispatchWorkItem { [weak self] in
                self?.waitClose = nil
                self?.hover(false)
            }
            waitClose = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
        }
        point(p.flatMap(spot(at:)))
    }

    private func point(_ spot: Spot?) {
        guard spot != pointed else { return }
        pointed = spot
        // Yab's own tip over the way back: where it leads, in words.
        if spot == .home, let window {
            // Right over the door, as any tip over a button.
            let rect = window.convertToScreen(convert(doorFrame(home), to: nil))
            KeyTip.shared.hover(home, title: "Show in \(siteName)", shortcut: nil, at: rect, side: .above)
        } else {
            KeyTip.shared.leave(home)
        }
        placeRest(animated: true)
        still {
            previous.lit(spot == .previous)
            play.lit(spot == .play)
            next.lit(spot == .next)
            back.lit(spot == .back)
            forward.lit(spot == .forward && !forward.dimmed)
            sound.lit(spot == .sound)
            home.lit(spot == .home)
            restDoor.lit(spot == .rest)
            for (i, id) in (face?.others.map(\.tab) ?? []).enumerated() { budFaces[id]?.lit(spot == .bud(i) || (!open && i == 0 && spot == .bud(0))) }
        }
    }

    private func spot(at p: CGPoint) -> Spot? {
        for (frame, spot) in shapes() where spot != nil && frame.contains(p) { return spot }
        guard islandFrame.contains(p) else { return nil }
        if !open {
            // The bars' end, the island's whole height and a little more
            // than the door across, so it isn't a pinpoint.
            let door = restFrame.offsetBy(dx: islandFrame.minX, dy: 0)
            if CGRect(x: door.midX - 14, y: 0, width: 28, height: Band.row).contains(p) { return .rest }
        }
        if open {
            for door in doorsShown + (AudioWatch.canMute ? [sound] : []) + [home] where doorFrame(door).insetBy(dx: -2, dy: -2).contains(p) {
                return door === previous ? .previous : door === play ? .play : door === next ? .next
                    : door === back ? .back : door === forward ? .forward : door === home ? .home : .sound
            }
            if face?.tune.goesLive() == true, remaining.frame.insetBy(dx: -4, dy: -4).contains(p) { return .live }
            if face?.tune.scrubs == true, track.opacity > 0,
               track.frame.insetBy(dx: -4, dy: -Band.grip).contains(p) { return .progress }
        }
        return .line
    }

    override func mouseDown(with event: NSEvent) {
        // Control-click is a right-click here too.
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        pressed = spot(at: p)
        if pressed == .progress { hold(p.x) }
        if let pressed, let door = door(for: pressed) { door.press(true) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed == .progress else {
            super.mouseDragged(with: event)
            return
        }
        hold(convert(event.locationInWindow, from: nil).x)
        if let held { player?.seek(held, rough: true) }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if pressed == .progress {
            // Let go: exactly there, and the card closes if the pointer
            // left it on the way.
            pressed = nil
            hold(p.x)
            letGo()
            pointer(at: p)
            return
        }
        let at = spot(at: p)
        if let pressed, let door = door(for: pressed) { door.press(false) }
        defer { pressed = nil }
        guard let at, at == pressed else { return }
        act(at)
    }

    /// The line held under `x`: the fill there at once, and the times saying
    /// that point.
    private func hold(_ x: CGFloat) {
        held = Double(min(1, max(0, (x - CardFrame.inset) / max(1, lineWidth))))
        still {
            progress()
            paintTimes()
            placeTimes()
        }
    }

    /// The line let go: the page goes exactly there, and the line and the
    /// times follow its clock again.
    private func letGo() {
        guard let at = held else { return }
        held = nil
        player?.seek(at, rough: false)
        still {
            progress()
            paintTimes()
            placeTimes()
        }
    }

    private func door(for spot: Spot) -> BandDoor? {
        switch spot {
        case .previous: return previous
        case .play: return play
        case .next: return next
        case .back: return back
        case .forward: return forward.dimmed ? nil : forward
        case .sound: return sound
        case .home: return home
        case .rest: return restDoor
        default: return nil
        }
    }

    private func act(_ spot: Spot) {
        switch spot {
        case .play: player?.toggle()
        case .previous: heading = -1; previous.skip(); player?.skip(forward: false)
        case .next: heading = 1; next.skip(); player?.skip(forward: true)
        case .back: back.jump(); player?.jump(-15)
        case .forward:
            guard !forward.dimmed else { return }
            forward.jump(); player?.jump(15)
        case .home: player?.go()
        case .sound:
            player?.mute()
            sound.paint(ink: ink, muted: muted, scale: scale, playing: playing, silent: silent)
            sound.lit(pointed == .sound)
        case .bud(let i):
            guard let others = face?.others, i < others.count else { return }
            heading = toBuds
            player?.promote(others[i].tab)
        case .line: player?.go()
        case .rest: player?.toggle()
        case .live: player?.goLive()
        case .progress: break
        }
    }

    /// Two fingers sideways. Over the island at rest with buds: its face
    /// follows them, the first bud's sliding in under its edge; let go past
    /// 40 points, or quickly, and they swap, else it springs back. Open, or
    /// with none to swap: they scrub, the line's end following them a point
    /// a point (the card opening for it at once), the page there roughly as
    /// they go and exactly where they lift.
    override func scrollWheel(with event: NSEvent) {
        if event.phase == [], event.momentumPhase != [] {
            if !taken { super.scrollWheel(with: event) }
            return
        }
        if event.phase == .began {
            if sweep == .scrub { letGo() }
            sweep = nil
            taken = false
        }
        if sweep == nil {
            guard event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
                  event.phase == .began || event.phase == .changed,
                  let way = way(at: convert(event.locationInWindow, from: nil))
            else {
                super.scrollWheel(with: event)
                return
            }
            sweep = way
            taken = true
            swipe = 0
            if way == .swap { faceLayer.removeAnimation(forKey: "back") }
            if way == .scrub, let tune = face?.tune {
                if !open {
                    hover(true)
                    setOpen(true)
                }
                held = tune.through()
            }
        }
        let lifted = event.phase == .ended || event.phase == .cancelled
        if sweep == .scrub {
            if !lifted, let at = held, event.scrollingDeltaX != 0 {
                hold(CardFrame.inset + CGFloat(at) * lineWidth + event.scrollingDeltaX)
                if let held { player?.seek(held, rough: true) }
            }
            if lifted {
                sweep = nil
                letGo()
            }
            return
        }
        if !lifted {
            swipe += event.scrollingDeltaX
            follow()
            return
        }
        sweep = nil
        let fast = abs(event.scrollingDeltaX) > 6
        if others > 0, abs(swipe) > 40 || (fast && abs(swipe) > 12) {
            heading = swipe < 0 ? 1 : -1
            swiped = followed
            incoming?.layer.removeFromSuperlayer()
            incoming = nil
            player?.cycle(heading * toBuds)
        } else {
            springBack()
        }
        swipe = 0
    }

    /// How far the face stands off now.
    private var followed: CGFloat {
        others > 0 ? swipe : swipe * 0.22
    }

    private func follow() {
        still {
            faceLayer.sublayerTransform = CATransform3DMakeTranslation(followed, 0, 0)
            guard others > 0, let face else { return }
            // The one on the side the fingers come from: the first bud's
            // side brings the first.
            let other = (swipe < 0) == (toBuds > 0) ? face.others[0] : face.others[face.others.count - 1]
            if incoming?.tab != other.tab {
                incoming?.layer.removeFromSuperlayer()
                let layer = BudFace.peek(tune: other.tune, ink: ink, muted: muted, scale: scale, cover: coverFrame, textX: textX)
                faceLayer.addSublayer(layer)
                incoming = (layer, other.tab)
            }
            let w = faceLayer.bounds.width
            incoming?.layer.transform = CATransform3DMakeTranslation(-followed + (swipe < 0 ? w : -w) + followed, 0, 0)
            budFaces[other.tab]?.shrink(1 - min(1, abs(swipe) / w))
        }
    }

    private func springBack() {
        let from = followed
        still {
            faceLayer.sublayerTransform = CATransform3DIdentity
            incoming?.layer.removeFromSuperlayer()
            incoming = nil
            budFaces.values.forEach { $0.shrink(1) }
        }
        guard !reduced else { return }
        let back = CASpringAnimation(perceptualDuration: 0.32, bounce: 0.25)
        back.keyPath = "sublayerTransform.translation.x"
        back.fromValue = from
        back.toValue = 0
        back.duration = back.settlingDuration
        faceLayer.add(back, forKey: "back")
    }

    /// Right-click, or Control-click: what the buttons do, the others
    /// playing to swap in. Visibility is chosen in Settings; hiding the
    /// controls never pauses their source.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard up, let face, let player else { return nil }
        let tune = face.tune
        let menu = NSMenu()
        func item(_ title: String, _ enabled: Bool = true, mark: String? = nil, _ run: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(BandMenuAction.run(_:)), keyEquivalent: "")
            let action = BandMenuAction(run)
            item.target = action
            item.representedObject = action
            item.isEnabled = enabled
            MenuMark.put(mark, on: item)
            menu.addItem(item)
        }
        item("Show Tab", mark: "yab.tab.right") { player.go() }
        // On a site whose video is the point of it: out in the little
        // window, from here (Float.swift).
        if Players.knows(player.tab?.address) {
            item("Float Video", mark: "yab.pip") { player.float() }
        }
        menu.addItem(.separator())
        item(tune.playing ? "Pause" : "Play", mark: "yab.play") { player.toggle() }
        item("Next", tune.next, mark: "yab.next") { [weak self] in self?.act(.next) }
        item("Previous", tune.previous, mark: "yab.previous") { [weak self] in self?.act(.previous) }
        if tune.seeks {
            item("Back 15 Seconds", mark: "yab.undo") { [weak self] in self?.act(.back) }
            item("Forward 15 Seconds", !forward.dimmed, mark: "yab.redo") { [weak self] in self?.act(.forward) }
        }
        if AudioWatch.canMute {
            item(silent ? "Unmute Tab" : "Mute Tab", mark: silent ? "yab.speaker" : "yab.speakeroff") { [weak self] in self?.act(.sound) }
        }
        if !face.others.isEmpty {
            menu.addItem(.separator())
            if #available(macOS 14.0, *) { menu.addItem(.sectionHeader(title: "Also Playing")) }
            for other in face.others {
                let words = [other.tune.title, other.tune.artist].filter { !$0.isEmpty }.joined(separator: " · ")
                item(words) { [weak self] in
                    self?.heading = self?.toBuds ?? 1
                    player.promote(other.tab)
                }
            }
            if ([tune] + face.others.map(\.tune)).filter(\.playing).count > 1 {
                item("Pause All", mark: "yab.pause") { player.pauseAll() }
            }
        }
        return menu
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let tune = face?.tune else { return nil }
        var actions = [NSAccessibilityCustomAction(name: tune.playing ? "Pause" : "Play") { [weak self] in self?.player?.toggle(); return true }]
        if tune.next { actions.append(NSAccessibilityCustomAction(name: "Next") { [weak self] in self?.player?.skip(forward: true); return true }) }
        if tune.previous { actions.append(NSAccessibilityCustomAction(name: "Previous") { [weak self] in self?.player?.skip(forward: false); return true }) }
        if tune.seeks {
            actions.append(NSAccessibilityCustomAction(name: "Back 15 Seconds") { [weak self] in self?.act(.back); return true })
            if !forward.dimmed { actions.append(NSAccessibilityCustomAction(name: "Forward 15 Seconds") { [weak self] in self?.act(.forward); return true }) }
        }
        actions.append(NSAccessibilityCustomAction(name: "Show Tab") { [weak self] in self?.player?.go(); return true })
        for other in face?.others ?? [] {
            actions.append(NSAccessibilityCustomAction(name: "Switch to \(other.tune.title)") { [weak self] in self?.player?.promote(other.tab); return true })
        }
        return actions
    }

    // MARK: helpers

    /// Changes made at once, as one commit, with none of a bare layer's
    /// implicit animations.
    private func still(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    /// A layer to its frame, from wherever it is shown now.
    private func glide(_ layer: CALayer, to frame: CGRect, animated: Bool, time: CFTimeInterval, curve: CAMediaTimingFunction) {
        let fromPosition = layer.presentation()?.position ?? layer.position
        let fromSize = layer.presentation()?.bounds.size ?? layer.bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds.size = frame.size
        layer.position = CGPoint(x: frame.minX + frame.width * layer.anchorPoint.x, y: frame.minY + frame.height * layer.anchorPoint.y)
        CATransaction.commit()
        guard animated, time > 0 else { return }
        let a = CABasicAnimation(keyPath: "position")
        a.fromValue = fromPosition
        let b = CABasicAnimation(keyPath: "bounds.size")
        b.fromValue = fromSize
        let g = CAAnimationGroup()
        g.animations = [a, b]
        g.duration = time
        g.timingFunction = curve
        layer.add(g, forKey: "glide")
    }

    private func fade(_ layer: CALayer, to value: Float, time: CFTimeInterval, animated: Bool, delay: CFTimeInterval = 0) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = value
        CATransaction.commit()
        guard animated, time > 0, from != value else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.duration = time
        a.timingFunction = Curve.out
        if delay > 0 {
            a.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            a.fillMode = .backwards
        }
        layer.add(a, forKey: "fade")
    }

    // MARK: for the bench

    var report: [String: Any] {
        let soundPoint = convert(CGPoint(x: doorFrame(sound).midX, y: doorFrame(sound).midY), to: nil)
        let soundHit = window?.contentView.flatMap { root in
            root.hitTest(root.superview?.convert(soundPoint, from: nil) ?? .zero).map { String(describing: type(of: $0)) }
        } ?? ""
        // The sound door mutes the WebKit page, independently of each
        // video's DOM muted flag. Read its actual audio bit for the bench.
        var pageMuted: Any = NSNull()
        if let web = player?.tab?.webKitOnly("WebKit player runtime", build: false) {
            let selector = NSSelectorFromString("_mediaMutedState")
            if web.responds(to: selector) {
                typealias Get = @convention(c) (AnyObject, Selector) -> UInt
                let get = unsafeBitCast(web.method(for: selector), to: Get.self)
                pageMuted = get(web, selector) & 1 != 0
            }
        }
        return [
            "up": up, "hovering": hovering,
            // The room the column keeps under its foot, and whether this is
            // the view the player tells (a remade overlay's old one was).
            "room_up": player?.room.up ?? false, "bound": BandView.last === self, "in_window": window != nil,
            "views": BandView.made.allObjects.filter { $0.window != nil }.count, "open": open, "pointed": pointed.map { "\($0)" } ?? "",
            "title": face?.tune.title ?? "", "artist": face?.tune.artist ?? "",
            "playing": face?.tune.playing ?? false, "others": face?.others.map(\.tune.title) ?? [],
            "next": face?.tune.next ?? false, "previous": face?.tune.previous ?? false,
            "seeks": face?.tune.seeks ?? false, "forward_dim": forward.dimmed,
            "cover": face?.tune.cover != nil, "accent": face?.tune.accent?.hex ?? "",
            // The times as drawn, and how far along the line.
            "times": [elapsed, remaining].map { $0.runs.map(\.text).joined() },
            "live": face?.tune.live ?? false, "duration": face?.tune.duration ?? 0,
            "subtitle": face?.tune.subtitle ?? "", "goes_live": face?.tune.goesLive() ?? false,
            "lined": track.opacity > 0, "time_color": remaining.runs.first.map { $0.color == ink ? "ink" : "muted" } ?? "",
            "line": Double(fill.bounds.width / max(1, width - 2 * CardFrame.inset)),
            // How far the line is drawn now, mid-run: the model's width is
            // its end while it runs.
            "line_now": Double((fill.presentation()?.bounds.width ?? fill.bounds.width) / max(1, width - 2 * CardFrame.inset)),
            "frame": NSStringFromRect(convert(bounds, to: nil)),
            "island": NSStringFromRect(convert(island.frame, to: nil)),
            // Where the glass and the ink stand in the view (zero at rest),
            // and the island in the window as drawn, their offset included.
            "box": NSStringFromRect(glassBox.frame), "ink_box": NSStringFromRect(inkView.frame),
            "rest_door": restDoor.opacity > 0.5 ? (playing ? "pause" : "play") : "",
            "drawn_island": island.superview.map { NSStringFromRect($0.convert(island.frame, to: nil)) } ?? "",
            "buds": (face?.others ?? []).compactMap { budGlass[$0.tab].map { NSStringFromRect(convert($0.frame, to: nil)) } },
            "glass": island.className,
            "morph_ms": LineLayer.lastCost,
            "silent": silent, "players": player?.all().count ?? 0,
            "sound_target": [soundPoint.x, soundPoint.y], "sound_hit": soundHit,
            "source_id": player?.tab.map { String($0.id.uuidString.prefix(8)).lowercased() } ?? "",
            "source_url": player?.tab?.address?.absoluteString ?? "", "webkit_audio_muted": pageMuted,
            "ours_ms": (Player.cost * 100).rounded() / 100,
            "menu": BandView.lastMenu,
            // What a click 60 points over the island lands on: not this
            // view while the glass isn't there.
            "over_island": window?.contentView.flatMap { root in
                root.hitTest(root.superview?.convert(convert(CGPoint(x: 40, y: islandFrame.maxY + 60), to: nil), from: nil) ?? .zero).map { String(describing: type(of: $0)) }
            } ?? "",
            // What the window itself hands a press on the open card's line
            // and on its title, from its frame view down, as the mouse's
            // own are routed, with the views over it.
            "line_hit": windowHit(CGPoint(x: CardFrame.inset + lineWidth / 3, y: lineY)),
            "title_hit": windowHit(CGPoint(x: openX + 20, y: Band.card - CardFrame.inset - 13)),
        ]
    }

    private func windowHit(_ at: CGPoint) -> [String] {
        guard let frame = window?.contentView?.superview else { return [] }
        var chain: [String] = []
        var view = frame.hitTest(convert(at, to: nil))
        while let v = view, chain.count < 4 {
            chain.append(String(describing: type(of: v)))
            view = v.superview
        }
        return chain
    }

    /// The island's menu as a right-click on it would make it.
    private func benchMenu() -> NSMenu? {
        guard let window, let event = NSEvent.mouseEvent(with: .rightMouseDown, location: convert(CGPoint(x: 20, y: Band.row / 2), to: nil), modifierFlags: [],
                                                         timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return nil }
        return menu(for: event)
    }

    /// Its items' titles the last time the bench asked: "-" a separator, a
    /// title in brackets one turned off.
    static var lastMenu: [String] = []

    /// hover, unhover, open, close, point:SPOT, click:SPOT (a real click
    /// there, down and up through the window), toggle, next, previous,
    /// cycle, back, go, mute, pauseall, bud:N (that bud tapped), swipe:DX
    /// (two fingers that far and let go); on test runs, pretend:N (that
    /// many tabs playing made-up tunes), skip (the island's site skips),
    /// sitepause (the site pauses or plays), gone:N (the Nth stops: 0 the
    /// island, 1 the first bud), live:S (the island's a live stream S
    /// seconds behind its edge), menu (its right-click menu's items, into
    /// the report), menu:TITLE (that item chosen). Real events: press:F, drag:F, lift:F (the
    /// mouse on the open card's line, F along it), fingers:DX and fingers:up
    /// (two fingers on the island, sideways, then lifted), click:title;
    /// grab:PATH, the window as the window server has it.
    func bench(_ action: String) {
        switch action {
        case "hover", "open": hover(true); if action == "open" { setOpen(true) }
        case "unhover", "close": hover(false); point(nil)
        case "deaf": BandView.deaf = true
        case "hear": BandView.deaf = false
        case "toggle": player?.toggle()
        case "next": act(.next)
        case "previous": act(.previous)
        case "back15": act(.back)
        case "forward15": act(.forward)
        case "cycle": heading = toBuds; player?.cycle(1)
        case "back": heading = -toBuds; player?.cycle(-1)
        case "go": player?.go()
        case "mute": act(.sound)
        case "pauseall": player?.pauseAll()
        case "skip": heading = 1; player?.pretendNext()
        case "menu": BandView.lastMenu = benchMenu()?.items.map { $0.isSeparatorItem ? "-" : ($0.isEnabled ? $0.title : "(\($0.title))") } ?? []
        case "sitepause": player?.pretendToggle()
        default:
            if action.hasPrefix("menu:") {
                // That item of the island's menu chosen.
                let title = String(action.dropFirst(5))
                if let item = benchMenu()?.items.first(where: { $0.title == title }), let deed = item.representedObject as? BandMenuAction {
                    deed.run(item)
                }
            } else if action.hasPrefix("pretend:"), let n = Int(action.dropFirst(8)) {
                player?.pretend(n)
            } else if action.hasPrefix("live:"), let behind = Double(action.dropFirst(5)) {
                player?.pretendLive(behind: behind)
            } else if action.hasPrefix("livestate:") {
                player?.pretendLiveState(String(action.dropFirst(10)))
            } else if action.hasPrefix("gone:"), let n = Int(action.dropFirst(5)) {
                player?.pretendGone(n)
            } else if action.hasPrefix("bud:"), let n = Int(action.dropFirst(4)) {
                act(.bud(n))
            } else if action.hasPrefix("swipe:"), let dx = Double(action.dropFirst(6)) {
                swipe = 0
                sweep = .swap
                let steps = 8
                for i in 1...steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.016) { [weak self] in
                        guard let self else { return }
                        self.swipe = CGFloat(dx) * CGFloat(i) / CGFloat(steps)
                        self.follow()
                        if i == steps {
                            self.sweep = nil
                            if self.others > 0, abs(self.swipe) > 40 {
                                self.heading = self.swipe < 0 ? 1 : -1
                                self.swiped = self.followed
                                self.incoming?.layer.removeFromSuperlayer()
                                self.incoming = nil
                                self.player?.cycle(self.heading * self.toBuds)
                            } else {
                                self.springBack()
                            }
                            self.swipe = 0
                        }
                    }
                }
            } else if action.hasPrefix("point:") {
                let name = String(action.dropFirst(6))
                let spot: Spot? = ["previous": .previous, "play": .play, "next": .next, "back": .back, "forward": .forward, "sound": .sound, "tab": .home, "line": .line, "rest": .rest][name]
                    ?? (name.hasPrefix("bud") ? Int(name.dropFirst(3)).map(Spot.bud) : nil)
                point(spot)
            } else if action.hasPrefix("click:"), action != "click:title", let window {
                let name = String(action.dropFirst(6))
                let at: CGPoint
                switch name {
                case "previous": at = CGPoint(x: doorFrame(previous).midX, y: doorFrame(previous).midY)
                case "play": at = CGPoint(x: doorFrame(play).midX, y: doorFrame(play).midY)
                case "next": at = CGPoint(x: doorFrame(next).midX, y: doorFrame(next).midY)
                case "back": at = CGPoint(x: doorFrame(back).midX, y: doorFrame(back).midY)
                case "forward": at = CGPoint(x: doorFrame(forward).midX, y: doorFrame(forward).midY)
                case "sound": at = CGPoint(x: doorFrame(sound).midX, y: doorFrame(sound).midY)
                case "rest": at = CGPoint(x: islandFrame.minX + restFrame.midX, y: restFrame.midY)
                case "tab": at = CGPoint(x: doorFrame(home).midX, y: doorFrame(home).midY)
                case "bud": let b = budFrame(0, of: others); at = CGPoint(x: b.midX, y: b.midY)
                case "live": at = CGPoint(x: remaining.frame.midX, y: remaining.frame.midY)
                default: at = CGPoint(x: islandFrame.minX + textX + 20, y: Band.row / 2)
                }
                let inWindow = convert(at, to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            } else if let window, let kind = ["press:": NSEvent.EventType.leftMouseDown, "drag:": .leftMouseDragged, "lift:": .leftMouseUp]
                .first(where: { action.hasPrefix($0.key) }), let f = Double(action.dropFirst(kind.key.count)) {
                // A real press, drag or let-go on the open card's progress
                // line, that far along it.
                benchPost(kind.value, at: CGPoint(x: CardFrame.inset + CGFloat(f) * lineWidth, y: lineY), in: window)
            } else if action == "click:title", let window {
                // The open card's title, or the island's at rest.
                let at = open ? CGPoint(x: openX + 20, y: Band.card - CardFrame.inset - 13) : CGPoint(x: islandFrame.minX + textX + 20, y: Band.row / 2)
                benchPost(.leftMouseDown, at: at, in: window)
                benchPost(.leftMouseUp, at: at, in: window)
            } else if action == "fingers:up" {
                Bench.pull(island, by: 0, over: 0, begin: false, end: true)
            } else if action.hasPrefix("fingers:"), let dx = Double(action.dropFirst(8)) {
                // Two real fingers down on the island and that far sideways
                // over a quarter second; "fingers:up" lifts them.
                Bench.pull(island, by: dx, over: 0.25, begin: true, end: false)
            } else if action.hasPrefix("grab:"), let window {
                benchGrab(String(action.dropFirst(5)), window: window)
            }
        }
    }

    /// A mouse event at `at` in the view, handed to the window, which
    /// hit-tests it and keeps a drag with the view the press landed on.
    /// Straight to the window, as the bench's `drag` with `direct`: through
    /// the app a press brings a probe forward, over whatever someone is
    /// typing in.
    private func benchPost(_ type: NSEvent.EventType, at: CGPoint, in window: NSWindow) {
        guard let event = NSEvent.mouseEvent(with: type, location: convert(at, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        window.sendEvent(event)
    }

    /// The window as the window server puts it together, glass and all,
    /// which a layer render never draws: the app's own window needs no
    /// permission. Beside it, PATH.json: where the island and the window
    /// are, and the corners AppKit worked out for the island's glass.
    private func benchGrab(_ path: String, window: NSWindow) {
        typealias Grab = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        var facts: [String: Any] = ["island": NSStringFromRect(convert(island.frame, to: nil)), "window": NSStringFromRect(window.frame),
                                    "scale": window.backingScaleFactor, "open": open]
        // Where the glass is on screen now, mid-move: its layer's
        // presentation, the frame above being where it is going.
        if let shown = island.layer?.presentation()?.frame, let holder = island.superview {
            facts["shown"] = NSStringFromRect(holder.convert(shown, to: nil))
        }
        let radii = NSSelectorFromString("computedEffectiveCornerRadii")
        if island.responds(to: radii), let corners = island.perform(radii)?.takeUnretainedValue() {
            facts["corners"] = String(describing: corners)
        }
        // The window alone (optionIncludingWindow), its frame left out and
        // at full resolution (boundsIgnoreFraming, bestResolution).
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
           let image = unsafeBitCast(symbol, to: Grab.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue(),
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            facts["pixels"] = [image.width, image.height]
        } else {
            facts["error"] = "no picture from the window server"
        }
        if let json = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: URL(fileURLWithPath: path + ".json"))
        }
    }
}

/// A menu item's deed, kept by the item itself.
final class BandMenuAction: NSObject {
    private let deed: () -> Void
    init(_ deed: @escaping () -> Void) { self.deed = deed }
    @MainActor @objc func run(_ sender: Any?) { deed() }
}

/// The view everything drawn over the glass lives in: layers only, and
/// nothing of AppKit's on them.
@MainActor
final class InkView: NSView {
    let root = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.masksToBounds = false
        layer = root
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A bud's face over its glass: a round cover at rest; open, a row of its
/// own with the cover, the title and the artist, and its bars.
@MainActor
final class BudFace: CALayer {
    private let cover = CALayer()
    private let words = LineLayer()
    private let bars = BarsLayer()
    private let ground = CALayer()
    private var playing = true

    override init() {
        super.init()
        anchorPoint = .zero
        cover.masksToBounds = true
        cover.cornerCurve = .continuous
        cover.contentsGravity = .resizeAspectFill
        words.anchorPoint = .zero
        words.opacity = 0
        bars.opacity = 0
        ground.cornerCurve = .continuous
        ground.opacity = 0
        [ground, cover, words, bars].forEach(addSublayer)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func paint(tune: Tune?, ink: CGColor, muted: CGColor, scale: CGFloat, width: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playing = tune?.playing ?? false
        cover.contents = tune?.cover
        cover.backgroundColor = tune?.cover == nil ? ink.copy(alpha: 0.12) : nil
        cover.opacity = playing ? 1 : 0.55
        words.scale = scale
        let room = max(0, width - (Band.inset + Band.cover + Band.air) - Band.end - BarsLayer.width - 8)
        words.bounds.size = CGSize(width: room, height: Band.row)
        let title = LineLayer.Run(text: tune?.title ?? "", font: .systemFont(ofSize: 12, weight: .medium), color: playing ? ink : muted)
        let artist = LineLayer.Run(text: tune?.artist ?? "", font: .systemFont(ofSize: 12), color: muted)
        words.show(tune?.artist.isEmpty == false ? [title, artist] : [title], width: room)
        bars.color((playing ? tune?.accent?.cgColor : nil) ?? muted)
        ground.backgroundColor = ink.copy(alpha: 0.06)
        CATransaction.commit()
        if playing { if !bars.moving { bars.play(animated: false) } } else { bars.pause(animated: false) }
    }

    /// To its glass's frame: at rest a round cover in the bud; open, a row.
    func place(in frame: CGRect, open: Bool, shown: Bool, animated: Bool, time: CFTimeInterval, curve: CAMediaTimingFunction) {
        let wasCover = cover.presentation()?.frame ?? cover.frame
        let wasSelf = presentation()?.position ?? position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bounds.size = frame.size
        position = frame.origin
        let side = open ? Band.cover : frame.height - 6
        cover.frame = open ? CGRect(x: Band.inset, y: Band.inset, width: side, height: side)
                           : CGRect(x: (frame.width - side) / 2, y: (frame.height - side) / 2, width: side, height: side)
        cover.cornerRadius = side / 2
        words.frame = CGRect(x: Band.inset + Band.cover + Band.air, y: 0, width: words.bounds.width, height: Band.row)
        bars.position = CGPoint(x: frame.width - Band.end - BarsLayer.width / 2, y: frame.height / 2)
        ground.frame = bounds
        ground.cornerRadius = frame.height / 2
        opacity = shown ? 1 : 0
        CATransaction.commit()
        let wordsTo: Float = open && shown ? 1 : 0
        if animated, time > 0 {
            let a = CABasicAnimation(keyPath: "position")
            a.fromValue = wasSelf
            a.duration = time
            a.timingFunction = curve
            add(a, forKey: "move")
            let c = CABasicAnimation(keyPath: "position")
            c.fromValue = CGPoint(x: wasCover.midX, y: wasCover.midY)
            c.duration = time
            c.timingFunction = curve
            cover.add(c, forKey: "move")
            for layer in [words, bars] as [CALayer] {
                let f = CABasicAnimation(keyPath: "opacity")
                f.fromValue = layer.presentation()?.opacity ?? layer.opacity
                f.duration = open ? time * 0.8 : time * 0.3
                if open { f.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + time * 0.3; f.fillMode = .backwards }
                layer.add(f, forKey: "fade")
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        words.opacity = wordsTo
        bars.opacity = wordsTo
        CATransaction.commit()
    }

    func lit(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ground.opacity = on ? 1 : 0
        CATransaction.commit()
    }

    /// The old face dropping into the bud: from small, with give.
    func drop(after delay: CFTimeInterval) {
        let a = CASpringAnimation(perceptualDuration: 0.3, bounce: 0.3)
        a.keyPath = "transform.scale"
        a.fromValue = 0.4
        a.toValue = 1
        a.duration = a.settlingDuration
        a.beginTime = cover.convertTime(CACurrentMediaTime(), from: nil) + delay
        a.fillMode = .backwards
        cover.add(a, forKey: "drop")
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = 0
        f.toValue = cover.opacity
        f.duration = 0.1
        f.beginTime = a.beginTime
        f.fillMode = .backwards
        cover.add(f, forKey: "in")
    }

    /// Its cover giving way while a swipe brings it into the island.
    func shrink(_ to: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.transform = CATransform3DMakeScale(to, to, 1)
        CATransaction.commit()
    }

    /// Stopped: into the island's end with its glass.
    func leave(to end: CGRect, time: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperlayer() }
        let a = CABasicAnimation(keyPath: "position")
        a.toValue = end.origin
        let o = CABasicAnimation(keyPath: "opacity")
        o.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [a, o]
        g.duration = time
        g.timingFunction = Curve.inOut
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        add(g, forKey: "leave")
        CATransaction.commit()
    }

    /// The face a swipe brings in under the island's edge: its cover and
    /// words where the island's will be.
    static func peek(tune: Tune, ink: CGColor, muted: CGColor, scale: CGFloat, cover frame: CGRect, textX: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.anchorPoint = .zero
        layer.frame = CGRect(x: 0, y: 0, width: 400, height: Band.row)
        let art = CALayer()
        art.frame = frame
        art.contents = tune.cover
        art.contentsGravity = .resizeAspectFill
        art.masksToBounds = true
        art.cornerRadius = frame.width / 2
        art.cornerCurve = .continuous
        let words = LineLayer()
        words.anchorPoint = .zero
        words.scale = scale
        words.frame = CGRect(x: textX, y: 0, width: 220, height: Band.row)
        let title = LineLayer.Run(text: tune.title, font: .systemFont(ofSize: Band.size, weight: .medium), color: ink)
        let artist = LineLayer.Run(text: tune.artist, font: .systemFont(ofSize: Band.size), color: muted)
        words.show(tune.artist.isEmpty ? [title] : [title, artist], width: 220)
        layer.addSublayer(art)
        layer.addSublayer(words)
        return layer
    }
}

/// The curves, as Motion has them for SwiftUI.
enum Curve {
    static let arrive = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    static let depart = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.4)
    static let inOut = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1)
    static let out = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    /// A spring's shape in a curve: out past the mark by a few percent and
    /// back, for the glass, whose frames NSAnimationContext moves and which
    /// takes no spring of its own.
    static let give = CAMediaTimingFunction(controlPoints: 0.3, 1.32, 0.5, 1)
}

/// A button in the open island, drawn as Apple Music and Control Center
/// draw theirs: previous and next are two filled triangles, play is a
/// filled triangle and pause two bars, a size up from the skips; at the
/// ends the way back, which is the playing site's own icon in its colors
/// (where it leads, not an arrow to learn), and the sound, quieter. Under the
/// pointer a round ground comes up (a capsule's control on glass); a press
/// squeezes the mark and lets it go with a little give. Pause and play are
/// one path that turns into the other (P5: the shape is kept, the state
/// flips), and a skip moves its triangles: the back one takes the front's
/// place, the front one goes on and out, a new one grows at the back.
/// 15 seconds back and on are the floating window's marks, an arrow round
/// a 15, the arrow turning as it is pressed. Everything is layers, moved
/// on the render server.
@MainActor
final class BandDoor: CALayer {
    enum Kind { case previous, play, next, back, forward, sound, tab }
    let kind: Kind
    /// The island's own at rest, a size down: the mark a cover's half.
    let compact: Bool
    private let ground = CALayer()
    /// The mark, squeezed as a whole by a press.
    private let mark = CALayer()
    private let shapes: [CAShapeLayer]
    private var ink: CGColor = CGColor(gray: 0, alpha: 1)
    private var on = false
    private var showsPause = true

    /// The mark's size: the bars' height, the skips' width, the small ones'.
    var side: CGFloat {
        switch kind {
        case .play: return compact ? 11 : 20
        case .previous, .next, .back, .forward: return 22
        case .sound, .tab: return 14
        }
    }

    /// How round a filled mark's corners are: true arcs of this radius, as
    /// SF Symbols round theirs, the mark keeping its size.
    private var round: CGFloat { kind == .sound ? 0.8 : 1.8 }
    /// The pause bars' corners.
    private static let barCorner: CGFloat = 1.6

    /// Quieter at rest: the sound. The way back is the site's own icon, in
    /// its own colors.
    private var secondary: Bool { kind == .sound }
    /// The site's icon, for the way back.
    private let picture = CALayer()
    /// 15 seconds back or on: the arrow, which turns, and the 15 inside it,
    /// each the ink through its glyph.
    private let arrow = CALayer()
    private let digits = CALayer()
    /// Nowhere to go this way (a live stream at its edge): faint, and a
    /// press does nothing.
    private(set) var dimmed = false

    init(_ kind: Kind, compact: Bool = false) {
        self.kind = kind
        self.compact = compact
        let count = kind == .previous || kind == .next ? 3 : (kind == .sound ? 3 : (kind == .play ? 2 : 1))
        shapes = (0..<count).map { _ in CAShapeLayer() }
        super.init()
        ground.opacity = 0
        addSublayer(ground)
        addSublayer(mark)
        for shape in shapes {
            shape.lineJoin = .round
            shape.lineCap = .round
            mark.addSublayer(shape)
        }
        picture.contentsGravity = .resizeAspect
        picture.minificationFilter = .trilinear
        if kind == .tab { mark.addSublayer(picture) }
        if kind == .back || kind == .forward {
            for layer in [arrow, digits] {
                let glyph = CALayer()
                glyph.contentsGravity = .resize
                layer.mask = glyph
                mark.addSublayer(layer)
            }
        }
        if kind == .previous { mark.sublayerTransform = CATransform3DMakeScale(-1, 1, 1) }
    }

    override init(layer: Any) {
        let other = layer as? BandDoor
        kind = other?.kind ?? .next
        compact = other?.compact ?? false
        shapes = []
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ground.frame = bounds
        ground.cornerRadius = bounds.height / 2
        mark.bounds = CGRect(x: -bounds.width / 2, y: -bounds.height / 2, width: bounds.width, height: bounds.height)
        mark.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // The marks are drawn about 0, the mark layer's middle.
        for shape in shapes {
            shape.bounds = mark.bounds
            shape.position = .zero
        }
        draw()
        CATransaction.commit()
    }

    func paint(ink: CGColor, muted: CGColor, scale: CGFloat, playing: Bool, silent: Bool = false) {
        self.ink = ink
        self.silent = silent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ground.backgroundColor = ink.copy(alpha: 0.07)
        contentsScale = scale
        for shape in shapes { shape.contentsScale = scale }
        if kind == .play { showsPause = playing }
        if kind == .back || kind == .forward {
            for (layer, name) in [(arrow, kind == .back ? "gobackward.arrow" : "goforward.arrow"), (digits, "skip.15")] {
                guard let glyph = layer.mask else { continue }
                glyph.contents = Glyphs.image(name, side: side)?.layerContents(forContentsScale: scale)
                glyph.contentsScale = scale
            }
        }
        draw()
        mark.opacity = rest
        CATransaction.commit()
    }

    private var silent = false

    /// The marks at rest, in the mark layer's own space, centered on 0.
    private func draw() {
        let s = side
        switch kind {
        case .play:
            // Pause and play are two marks; one shows at a time.
            shapes[0].path = BandDoor.pauseBars(s)
            shapes[1].path = BandDoor.playTriangle(s, round)
            shapes[0].opacity = showsPause ? 1 : 0
            shapes[1].opacity = showsPause ? 0 : 1
            shapes.forEach(fill)
        case .previous, .next:
            let w = s * 0.5, h = s * 0.6
            shapes[0].path = BandDoor.triangle(x: 0, w: w, h: h, round: round)
            shapes[1].path = BandDoor.triangle(x: -w, w: w, h: h, round: round)
            shapes[2].path = BandDoor.triangle(x: -w, w: w, h: h, round: round)
            shapes[2].opacity = 0
            shapes.forEach(fill)
        case .sound:
            shapes[0].path = BandDoor.speaker(s, round: round)
            fill(shapes[0])
            for (i, shape) in shapes.dropFirst().enumerated() {
                shape.path = silent ? (i == 0 ? BandDoor.slash(s) : nil) : BandDoor.wave(s, far: i == 1)
                stroke(shape, width: s * 0.1)
            }
        case .tab:
            // The site's icon; without one, its first letter on a plate.
            let side: CGFloat = 16
            picture.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            picture.position = .zero
            // Rounded, the letter plate and the site's icon alike.
            picture.cornerRadius = Radius.small
            picture.cornerCurve = .continuous
            picture.masksToBounds = true
            picture.contents = siteImage ?? letter
            picture.contentsGravity = siteImage == nil ? .center : .resizeAspect
            picture.backgroundColor = siteImage == nil ? ink.copy(alpha: 0.12) : nil
            shapes[0].path = nil
        case .back, .forward:
            for layer in [arrow, digits] {
                layer.bounds = CGRect(x: 0, y: 0, width: s, height: s)
                layer.position = .zero
                layer.backgroundColor = ink
                layer.mask?.frame = layer.bounds
            }
        }
    }

    /// The mark's opacity as it stands: faint dimmed, quieter at rest for
    /// the sound.
    private var rest: Float { dimmed ? 0.3 : secondary && !on ? 0.55 : 1 }

    func dim(_ on: Bool) {
        guard on != dimmed else { return }
        dimmed = on
        if on { lit(false) }
        CATransaction.begin()
        CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16)
        mark.opacity = rest
        CATransaction.commit()
    }

    /// 15 seconds back or on: the arrow turns 30° the way it points and
    /// settles back, 0.26 s, the 15 staying, as the floating window's does.
    func jump() {
        guard kind == .back || kind == .forward, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // Unflipped, a positive turn goes left.
        let angle = (kind == .forward ? -1.0 : 1.0) * Double.pi / 6
        let spin = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        spin.values = [0, angle, 0]
        spin.keyTimes = [0, 0.35, 1]
        spin.timingFunctions = [markCurve, markCurve]
        spin.duration = 0.26
        arrow.add(spin, forKey: "turn")
    }

    private func fill(_ shape: CAShapeLayer) {
        shape.fillColor = ink
        shape.strokeColor = nil
        shape.lineWidth = 0
    }

    private func stroke(_ shape: CAShapeLayer, width: CGFloat) {
        shape.fillColor = nil
        shape.strokeColor = ink
        shape.lineWidth = width
    }

    func lit(_ on: Bool) {
        guard on != self.on else { return }
        self.on = on
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        ground.opacity = on ? 1 : 0
        mark.opacity = rest
        CATransaction.commit()
    }

    /// Held down: in to 84%; let go: back with a little give.
    func press(_ down: Bool) {
        let from = mark.presentation()?.transform ?? mark.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.transform = down ? CATransform3DMakeScale(0.84, 0.84, 1) : CATransform3DIdentity
        ground.backgroundColor = ink.copy(alpha: down ? 0.12 : 0.07)
        CATransaction.commit()
        let a: CABasicAnimation
        if down {
            a = CABasicAnimation(keyPath: "transform")
            a.duration = 0.06
        } else {
            let spring = CASpringAnimation(perceptualDuration: 0.28, bounce: 0.45)
            spring.keyPath = "transform"
            spring.duration = spring.settlingDuration
            a = spring
        }
        a.fromValue = from
        mark.add(a, forKey: "press")
    }

    private var siteImage: CGImage?
    private var letter: CGImage?

    /// The playing site's icon for the way back, or its first letter.
    func site(icon: CGImage?, initial: String, scale: CGFloat) {
        siteImage = icon
        if icon == nil {
            let run = LineLayer.Run(text: initial.uppercased(), font: .systemFont(ofSize: 10, weight: .semibold), color: ink)
            letter = LineLayer.picture([run], width: nil, height: 16, scale: scale).0
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contentsScale = scale
        draw()
        CATransaction.commit()
    }

    /// Pause into play or back, as Apple replaces a symbol: the old mark
    /// goes down and out, the new one comes up with a little give.
    func turn(playing: Bool, animated: Bool) {
        guard kind == .play, playing != showsPause, shapes.count == 2 else { return }
        showsPause = playing
        let (out, into) = playing ? (shapes[1], shapes[0]) : (shapes[0], shapes[1])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        out.opacity = 0
        into.opacity = 1
        CATransaction.commit()
        guard animated else { return }
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = 0.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let leave = CAAnimationGroup()
        leave.animations = [shrink, fade]
        leave.duration = 0.12
        leave.timingFunction = Curve.depart
        out.add(leave, forKey: "turn")
        let grow = CASpringAnimation(perceptualDuration: 0.3, bounce: 0.3)
        grow.keyPath = "transform.scale"
        grow.fromValue = 0.5
        grow.toValue = 1
        grow.duration = grow.settlingDuration
        grow.beginTime = into.convertTime(CACurrentMediaTime(), from: nil) + 0.06
        grow.fillMode = .backwards
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 0
        show.toValue = 1
        show.duration = 0.1
        show.beginTime = grow.beginTime
        show.fillMode = .backwards
        into.add(grow, forKey: "turn")
        into.add(show, forKey: "show")
    }

    /// A skip: the triangles move on by one.
    func skip() {
        guard kind == .previous || kind == .next, shapes.count == 3 else { return }
        let w = side * 0.5
        let time: CFTimeInterval = 0.34
        let curve = Curve.out
        func move(_ layer: CAShapeLayer, from: CATransform3D, to: CATransform3D, fade: (Float, Float)) {
            let t = CABasicAnimation(keyPath: "transform")
            t.fromValue = from
            t.toValue = to
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = fade.0
            o.toValue = fade.1
            let g = CAAnimationGroup()
            g.animations = [t, o]
            g.duration = time
            g.timingFunction = curve
            layer.add(g, forKey: "skip")
        }
        // Scaled about each triangle's own middle.
        func at(_ dx: CGFloat, scale: CGFloat, center: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(center + dx, 0, 0)
            t = CATransform3DScale(t, scale, scale, 1)
            return CATransform3DTranslate(t, -center, 0, 0)
        }
        // The model stays as at rest, so when the moves are done the three
        // stand where they began: the same picture.
        move(shapes[0], from: CATransform3DIdentity, to: at(w * 0.7, scale: 0.5, center: w / 2), fade: (1, 0))
        move(shapes[1], from: CATransform3DIdentity, to: CATransform3DMakeTranslation(w, 0, 0), fade: (1, 1))
        move(shapes[2], from: at(w * 0.5, scale: 0.01, center: -w / 2), to: CATransform3DIdentity, fade: (0, 1))
    }

    // MARK: drawings

    /// A polygon with every corner rounded to `radius`: true arcs tangent
    /// to both edges. A triangle is grown about its incenter first, as much
    /// as rounding takes off its tips, so it reads the same size.
    static func rounded(_ points: [CGPoint], radius: CGFloat) -> CGPath {
        var points = points
        if points.count == 3, radius > 0 {
            let d = { (a: CGPoint, b: CGPoint) in hypot(a.x - b.x, a.y - b.y) }
            let a = d(points[1], points[2]), b = d(points[0], points[2]), c = d(points[0], points[1]), p = a + b + c
            let center = CGPoint(x: (a * points[0].x + b * points[1].x + c * points[2].x) / p,
                                 y: (a * points[0].y + b * points[1].y + c * points[2].y) / p)
            let area = abs((points[1].x - points[0].x) * (points[2].y - points[0].y) - (points[2].x - points[0].x) * (points[1].y - points[0].y)) / 2
            let inner = area / (p / 2), k = (inner + 0.55 * radius) / inner
            points = points.map { CGPoint(x: center.x + ($0.x - center.x) * k, y: center.y + ($0.y - center.y) * k) }
        }
        let path = CGMutablePath()
        let n = points.count
        path.move(to: CGPoint(x: (points[n - 1].x + points[0].x) / 2, y: (points[n - 1].y + points[0].y) / 2))
        for i in 0..<n { path.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % n], radius: radius) }
        path.closeSubpath()
        return path
    }

    /// Two bars, their corners rounded. No corner is more than half a bar:
    /// macOS 15's CoreGraphics asserts on one that is, and the compact
    /// island's bars are 2.86 wide (0.0.30 crashed at launch with a playing
    /// tab restored, 2026-10-19); later systems only clamp it.
    static func pauseBars(_ s: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for (bar, corner) in pauseBarShapes(s) {
            path.addRoundedRect(in: bar, cornerWidth: corner, cornerHeight: corner)
        }
        return path
    }

    /// The pause bars and each one's corner.
    static func pauseBarShapes(_ s: CGFloat) -> [(bar: CGRect, corner: CGFloat)] {
        [(-0.34, -0.08), (0.08, 0.34)].map { (a: CGFloat, b: CGFloat) in
            let bar = CGRect(x: a * s, y: -s / 2, width: (b - a) * s, height: s)
            return (bar, max(0, min(barCorner, bar.width / 2, bar.height / 2)))
        }
    }

    /// The play triangle, nudged right by its optical center.
    static func playTriangle(_ s: CGFloat, _ round: CGFloat) -> CGPath {
        rounded([CGPoint(x: -0.3 * s + 1.5, y: -0.52 * s), CGPoint(x: 0.48 * s + 1.5, y: 0), CGPoint(x: -0.3 * s + 1.5, y: 0.52 * s)], radius: round)
    }

    /// A triangle pointing right, its back at x and its tip at x + w.
    static func triangle(x: CGFloat, w: CGFloat, h: CGFloat, round: CGFloat) -> CGPath {
        rounded([CGPoint(x: x, y: -h / 2), CGPoint(x: x + w, y: 0), CGPoint(x: x, y: h / 2)], radius: round)
    }

    static func speaker(_ s: CGFloat, round: CGFloat) -> CGPath {
        rounded([CGPoint(x: -0.45 * s, y: -0.17 * s), CGPoint(x: -0.25 * s, y: -0.17 * s), CGPoint(x: 0, y: -0.39 * s),
                 CGPoint(x: 0, y: 0.39 * s), CGPoint(x: -0.25 * s, y: 0.17 * s), CGPoint(x: -0.45 * s, y: 0.17 * s)], radius: round)
    }

    static func wave(_ s: CGFloat, far: Bool) -> CGPath {
        let path = CGMutablePath()
        let r = far ? 0.42 * s : 0.24 * s
        path.addArc(center: CGPoint(x: 0.04 * s, y: 0), radius: r, startAngle: -0.8, endAngle: 0.8, clockwise: false)
        return path
    }

    static func slash(_ s: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0.14 * s, y: -0.24 * s))
        path.addLine(to: CGPoint(x: 0.46 * s, y: 0.24 * s))
        path.move(to: CGPoint(x: 0.14 * s, y: 0.24 * s))
        path.addLine(to: CGPoint(x: 0.46 * s, y: -0.24 * s))
        return path
    }
}

extension LineLayer {
    /// The line's own width, measured, nothing painted.
    static func natural(_ runs: [Run]) -> CGFloat {
        let widths = runs.map { run -> CGFloat in
            let text = NSAttributedString(string: run.text, attributes: [.font: run.font])
            return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil))
        }
        return widths.reduce(0, +) + spacing * CGFloat(max(0, runs.count - 1))
    }
}

// MARK: - the words

/// A line of words in one or more runs, the title and the artist, painted
/// as one picture that goes out into nothing where it doesn't fit, and a
/// new line brought in letter by letter (P5, after ex-25): the letters the
/// two share slide to where they stand in the new one, the rest fade where
/// they are, and none of it is laid out again while it moves.
@MainActor
final class LineLayer: CALayer {
    struct Run: Equatable {
        let text: String
        let font: NSFont
        let color: CGColor
    }

    /// The air between one run and the next.
    static let spacing: CGFloat = 6

    var scale: CGFloat = 2
    private(set) var runs: [Run] = []
    /// The line's picture as shown, for a copy that slides away.
    var pictureContents: Any? { picture.contents }
    private let picture = CALayer()
    private var letters: [CALayer] = []
    private var turn = 0

    override init() {
        super.init()
        picture.anchorPoint = .zero
        picture.contentsGravity = .bottomLeft
        addSublayer(picture)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    /// The line as it is, at once.
    func show(_ runs: [Run], width: CGFloat, crossing: CFTimeInterval = 0) {
        let was = picture.contents
        turn += 1
        drop()
        self.runs = runs
        let (image, _) = LineLayer.picture(runs, width: width, height: bounds.height, scale: scale)
        picture.contents = image
        picture.contentsScale = scale
        picture.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        picture.opacity = 1
        // The same words with their fade elsewhere: one picture into the
        // other, the render server's to cross.
        if crossing > 0, let was {
            let a = CABasicAnimation(keyPath: "contents")
            a.fromValue = was
            a.duration = crossing
            a.timingFunction = Curve.out
            picture.add(a, forKey: "cross")
        }
    }

    /// From the line shown to this one, letter by letter.
    func morph(to next: [Run], width: CGFloat, reduce: Bool) {
        let old = runs
        guard old != next, !old.isEmpty, !next.isEmpty else { show(next, width: width); return }
        if reduce {
            // Without motion: one picture over the other, 0.15 s.
            let was = picture.contents
            show(next, width: width)
            let a = CABasicAnimation(keyPath: "contents")
            a.fromValue = was
            a.duration = 0.15
            picture.add(a, forKey: "swap")
            return
        }
        turn += 1
        let mine = turn
        drop()
        runs = next
        let t0 = CACurrentMediaTime()
        let height = bounds.height
        let a = LineLayer.letters(old, height: height, scale: scale)
        let b = LineLayer.letters(next, height: height, scale: scale)
        // Each letter is a slice of its whole line's picture, cut on the
        // pixel where its advance begins and ends: nothing is painted per
        // letter, and at rest the slices tile back into the same pixels.
        let (was, _) = LineLayer.picture(old, width: nil, height: height, scale: scale)
        let (will, _) = LineLayer.picture(next, width: nil, height: height, scale: scale)
        let pairs = LineLayer.shared(a.map(\.key), b.map(\.key))
        var matched: [Int: Int] = [:]
        for (i, j) in pairs { matched[i] = j }
        let kept = Set(pairs.map(\.1))
        let now = convertTime(CACurrentMediaTime(), from: nil)
        let slide = CFTimeInterval(0.26)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Set before any animation is added: the block waits only for the
        // ones added after it, and with none it runs at once.
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.turn == mine else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.picture.opacity = 1
                self.drop()
                CATransaction.commit()
            }
        }
        picture.opacity = 0
        // Only what can be seen, with a little over for the fade's edge.
        let reach = width + 2
        for (i, letter) in a.enumerated() where letter.x < reach || matched[i].map({ b[$0].x < reach }) == true {
            guard let layer = letter.slice(of: was, scale: scale, height: height) else { continue }
            addSublayer(layer)
            letters.append(layer)
            if let j = matched[i] {
                let to = (b[j].x * scale).rounded() / scale
                let move = CABasicAnimation(keyPath: "position.x")
                move.fromValue = layer.position.x
                move.toValue = to
                move.duration = slide
                move.timingFunction = Curve.inOut
                layer.position.x = to
                layer.add(move, forKey: "slide")
            } else {
                let out = CABasicAnimation(keyPath: "opacity")
                out.fromValue = 1
                out.toValue = 0
                out.duration = slide * 0.6
                out.timingFunction = Curve.inOut
                layer.opacity = 0
                layer.add(out, forKey: "out")
            }
        }
        for (j, letter) in b.enumerated() where !kept.contains(j) && letter.x < reach {
            guard let layer = letter.slice(of: will, scale: scale, height: height) else { continue }
            addSublayer(layer)
            letters.append(layer)
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.beginTime = now + slide * 0.3
            fadeIn.duration = slide * 0.7
            fadeIn.fillMode = .backwards
            fadeIn.timingFunction = Curve.inOut
            layer.add(fadeIn, forKey: "in")
        }
        // A name wider than the line: its end goes out as the picture's
        // does, for as long as the letters are loose, and no longer.
        let over = (a.last.map { $0.x + $0.width } ?? 0) > width || (b.last.map { $0.x + $0.width } ?? 0) > width
        if over {
            let fadeMask = CAGradientLayer()
            fadeMask.frame = CGRect(x: 0, y: 0, width: width, height: height)
            fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
            fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
            let edge = max(0, (width - Band.fade) / max(1, width))
            fadeMask.locations = [0, NSNumber(value: Double(edge)), 1]
            fadeMask.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
            mask = fadeMask
        }
        let (image, _) = LineLayer.picture(next, width: width, height: height, scale: scale)
        picture.contents = image
        picture.contentsScale = scale
        picture.frame = CGRect(x: 0, y: 0, width: width, height: height)
        CATransaction.commit()
        LineLayer.lastCost = ((CACurrentMediaTime() - t0) * 100_000).rounded() / 100
    }

    /// What the last change of name cost the main thread, in ms, for the bench.
    static var lastCost: Double = 0

    private func drop() {
        letters.forEach { $0.removeFromSuperlayer() }
        letters.removeAll()
        mask = nil
    }

    // MARK: painting

    /// One letter: where it stands in its line, and its picture.
    struct Letter {
        let key: String
        let char: String
        let run: Run
        let x: CGFloat
        let width: CGFloat
        let baseline: CGFloat

        /// This letter's slice of its line's picture, on whole pixels.
        @MainActor
        func slice(of image: CGImage?, scale: CGFloat, height: CGFloat) -> CALayer? {
            guard let image, image.width > 0 else { return nil }
            let left = (x * scale).rounded(), right = ((x + width) * scale).rounded()
            guard right > left else { return nil }
            let full = CGFloat(image.width)
            let layer = CALayer()
            layer.anchorPoint = .zero
            layer.contents = image
            layer.contentsScale = scale
            layer.contentsRect = CGRect(x: left / full, y: 0, width: (right - left) / full, height: 1)
            layer.frame = CGRect(x: left / scale, y: 0, width: (right - left) / scale, height: height)
            return layer
        }
    }

    private static func line(_ run: Run) -> CTLine {
        let text = NSAttributedString(string: run.text, attributes: [.font: run.font, .foregroundColor: run.color])
        return CTLineCreateWithAttributedString(text)
    }

    static func letters(_ runs: [Run], height: CGFloat, scale: CGFloat) -> [Letter] {
        var out: [Letter] = []
        var x: CGFloat = 0
        for (r, run) in runs.enumerated() {
            let ct = line(run)
            let width = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil))
            let baseline = LineLayer.baseline(run.font, height: height, scale: scale)
            let text = run.text
            var i = text.startIndex
            while i < text.endIndex {
                let n = text.index(after: i)
                let a = CTLineGetOffsetForStringIndex(ct, i.utf16Offset(in: text), nil)
                let b = n == text.endIndex ? width : CTLineGetOffsetForStringIndex(ct, n.utf16Offset(in: text), nil)
                let ch = String(text[i..<n])
                out.append(Letter(key: "\(r):\(ch)", char: ch, run: run, x: x + a, width: max(0, b - a), baseline: baseline))
                i = n
            }
            x += width + (r < runs.count - 1 ? spacing : 0)
        }
        return out
    }

    /// The baseline that centers the font's caps and descenders in the
    /// row, on a whole pixel.
    static func baseline(_ font: NSFont, height: CGFloat, scale: CGFloat) -> CGFloat {
        let body = font.ascender - font.descender
        return (((height - body) / 2 - font.descender) * scale).rounded() / scale
    }

    /// Longest common subsequence of the two keys, as index pairs.
    static func shared(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return pairs
    }

    /// The whole line as one picture `width` across, its end going out
    /// over `Band.fade` when it runs past; `width` nil for the line's own.
    static func picture(_ runs: [Run], width: CGFloat?, height: CGFloat, scale: CGFloat) -> (CGImage?, CGFloat) {
        let lines = runs.map(line)
        let widths = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        let natural = widths.reduce(0, +) + spacing * CGFloat(max(0, runs.count - 1))
        let w = width ?? ceil(natural)
        let pw = Int(ceil(w * scale)), ph = Int(ceil(height * scale))
        guard pw > 0, ph > 0, let context = bitmap(pw, ph) else { return (nil, natural) }
        context.scaleBy(x: scale, y: scale)
        var x: CGFloat = 0
        for (i, ct) in lines.enumerated() {
            context.textPosition = CGPoint(x: x, y: baseline(runs[i].font, height: height, scale: scale))
            CTLineDraw(ct, context)
            x += widths[i] + spacing
        }
        if natural > w + 0.5 {
            // The letters themselves go clear, nothing laid over them.
            context.setBlendMode(.destinationOut)
            let colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: w - Band.fade, y: 0), end: CGPoint(x: w, y: 0), options: [.drawsAfterEndLocation])
            }
        }
        return (context.makeImage(), natural)
    }

    private static func bitmap(_ w: Int, _ h: Int) -> CGContext? {
        let context = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setShouldSmoothFonts(false)
        context?.setAllowsFontSubpixelPositioning(true)
        context?.setShouldSubpixelPositionFonts(true)
        return context
    }
}
