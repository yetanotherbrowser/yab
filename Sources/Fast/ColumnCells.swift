import AppKit
import QuartzCore
import SwiftUI

/// A row of the AppKit column (ColumnPage): the row SideBar draws, in a
/// host of its own. Its own graph, so a row's tab changing redraws it alone;
/// no size of its own, so laying it out asks nothing of AppKit. Used again
/// for another row of its kind when its own goes out of sight.
final class ColumnCell: NSHostingView<AnyView> {
    /// What kind of row it draws: a cell is used again only for its kind,
    /// which keeps the same SwiftUI views and lets their graph be updated
    /// rather than made again.
    enum Kind: Hashable {
        case tab, pair, nest, task, more, line, newTab, gap, pin, pinGap, name, home, lineComing
    }

    /// What the row is drawn from besides itself.
    struct Context {
        let browser: Browser
        let look: ColumnPages.Look
        /// The tab the column lights: none while New tab's row is lit.
        let liveID: Tab.ID?
        /// The row the pointer is on, by its item's id (ColumnPage.point).
        var pointedID: String? = nil
    }

    /// What a hand on the column does to a row (SideBar's drag state as the
    /// row draws it).
    struct Hold: Equatable {
        /// In the hand, or just let go and gliding to its place: a ground
        /// of its own and the shadow.
        var lifted = false
        /// A folder of yours a row is held over, to go in.
        var aimed = false
        /// A pin under a pressed button.
        var pressed = false
        /// The row a held one stays over turning into the folder the two
        /// would make, how far, and whether it is made.
        var turn: CGFloat?
        var made = false
        var compact = false
        var choice: TabDropChoice?
    }

    /// What the row shows: drawn again only when it changes (TabCell.Look).
    struct Look: Equatable {
        let id: String
        let tab: ObjectIdentifier?
        let other: ObjectIdentifier?
        let live: Bool
        let picked: Bool
        let editing: Bool
        let refusals: Int
        let joint: Joint?
        let staged: Bool
        let glyph: Glyph
        /// Settings › Appearance › Glass pins: a pin's ground drawn again
        /// when it is turned on or off, as for Tab icons.
        let glass: Bool
        let lit: Bool
        let size: CGSize
        let count: Int
        let open: Bool
        let over: FacePose?
        let folder: Folders.Folder?
        let space: Space?
        let pointed: Bool
        let hold: Hold
        let look: ColumnPages.Look
    }

    let kind: Kind
    private(set) var current: Look?
    /// How many times its row was handed to SwiftUI, for the bench.
    private(set) var binds = 0
    /// The item it last drew.
    private(set) var itemID: String?
    /// The tab of the row it last drew, a lone tab's: the middle button
    /// asks which row is under the pointer by where it is drawn, as the
    /// strip across the top does (YabApp's middle-click watcher).
    private(set) weak var rowTab: Tab?
    /// A single tab drawn in this cell, including a pin or its home row.
    /// Closing follows the hit cell even when its preview uses folder hover.
    private weak var hitTab: Tab?

    func tabUnderPointer(hovered: Tab?) -> Tab.ID? {
        if let hitTab { return hitTab.id }
        // A pair still needs the half under the pointer, validated against
        // the cell that actually drew it. A stale hover names nothing else.
        guard kind == .pin || kind == .pair, let hovered, let look = current,
              look.tab == ObjectIdentifier(hovered) || look.other == ObjectIdentifier(hovered) else { return nil }
        return hovered.id
    }
    /// Its row's identity to SwiftUI: a new one for another row, so none of
    /// the last row's state (the pointer on it, a shake) comes along, but
    /// kept for a row scrolled into sight in a cell another scrolled out of,
    /// whose SwiftUI graph is then only updated, not made again.
    private(set) var generation = 0

    init(kind: Kind) {
        self.kind = kind
        super.init(rootView: AnyView(EmptyView()))
        sizingOptions = []
        safeAreaRegions = []
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @MainActor required init(rootView: AnyView) { fatalError() }
    required init?(coder: NSCoder) { nil }

    /// SwiftUI asks its update through the constraints pass. That ask stops
    /// at the column's page (ColumnPage.subviewsAsked, ColumnQuiet.keepsAsks)
    /// rather than laying out the column's host and the window's, so the
    /// row answers it itself, in its own layout: the pass SwiftUI waits for
    /// does run, or it would ask again after every layout (the night's
    /// 036e730d and e57d9dfe, and 064cf44e, looped on a row at rest).
    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            super.needsUpdateConstraints = newValue
            if newValue, ColumnQuiet.keepsAsks, !answering { needsLayout = true }
        }
    }

    private var answering = false

    /// Row layouts at a new size, for the bench.
    static var resized = 0
    private var laidSize = CGSize.zero

    override func layout() {
        if bounds.size != laidSize { laidSize = bounds.size; ColumnCell.resized += 1 }
        if ColumnQuiet.keepsAsks, super.needsUpdateConstraints {
            answering = true
            updateConstraintsForSubtreeIfNeeded()
            answering = false
            ColumnQuiet.asksAnswered += 1
        }
        super.layout()
    }

    static func kind(of item: ColumnItem) -> Kind {
        switch item.kind {
        case .tab: return .tab
        case .pair: return .pair
        case .nest: return .nest
        case .task: return .task
        case .more: return .more
        case .line: return .line
        case .newTab: return .newTab
        case .gap: return .gap
        case .pin: return .pin
        case .pinGap: return .pinGap
        case .name: return .name
        case .privateName: return .name
        case .home: return .home
        case .lineComing: return .lineComing
        }
    }

    /// In a window behind another, the press that brings it forward is the
    /// row's too, as SideBar's `allowsWindowActivationEvents` has it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The browser whose row it draws, for the pointer's sake.
    private weak var owner: Browser?

    /// Under a card hanging over the rows (a pin's, a folder's preview) the
    /// row doesn't light and take the card's place, as the column's own
    /// host has it (ColumnView.Host, TabGlance.covers).
    ///
    /// With the column put away it hears nothing: the column is slid past
    /// the edge by its host's layer alone, so a row's tracking stayed where
    /// the row stands docked, and the pointer over the page there, on its
    /// way to the edge, lit a row no one could see and brought up its card
    /// (register #381). Only the edge answers then, bringing the column
    /// out (Brim), as in Arc.
    override func mouseMoved(with event: NSEvent) {
        if away || owner?.glance.covers(event) == true { return }
        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        if away || owner?.glance.covers(event) == true { return }
        super.mouseEntered(with: event)
    }

    /// In the column, and the column past the edge. A row drawn anywhere
    /// else (no column known) hears as it always has.
    private var away: Bool {
        guard let column = owner?.column, isDescendant(of: column) else { return false }
        return !column.shown
    }

    /// Two fingers on the trackpad over a row, or a pin, scroll the rows:
    /// a host of SwiftUI's takes a phased scroll for itself and hands it on
    /// to nothing (the rows of 500 tabs never moved under the bench's
    /// trackpad, a mouse's wheel did), so it goes to the page's own scroll
    /// view, as it reached SideBar's ScrollView under its rows and pins.
    override func scrollWheel(with event: NSEvent) {
        var view = superview
        while let each = view, !(each is ColumnPage) { view = each.superview }
        if let page = view as? ColumnPage {
            page.scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// A press asking for a menu that SwiftUI's hit test kept for the cell
    /// itself goes to the row's own menu under it (SteadyMenuView): a
    /// split row's halves opened nothing at all (owner, 2026-10-25), the
    /// press stopping here, past both chips' menus.
    override func rightMouseDown(with event: NSEvent) {
        if let spot = menuSpot(event) { spot.rightMouseDown(with: event) } else { super.rightMouseDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let spot = menuSpot(event) { spot.mouseDown(with: event) } else { super.mouseDown(with: event) }
    }

    /// The smallest of the row's menus under the press: a chip's before
    /// its row's.
    private func menuSpot(_ event: NSEvent) -> SteadyMenuView? {
        func spots(_ view: NSView) -> [SteadyMenuView] {
            view.subviews.flatMap { sub in (sub as? SteadyMenuView).map { [$0] } ?? spots(sub) }
        }
        return spots(self)
            .filter { !$0.isHidden && $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    /// A link or a file dragged in goes past the row to the column's own
    /// host, whose drop opens it (SideBar's onDrop): no row takes one.
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}

    /// The row `item` drawn here, if it isn't already as it is now.
    func bind(_ item: ColumnItem, _ context: Context, hold: Hold = Hold(), force: Bool, animation: Animation? = nil, scrolled: Bool = false) {
        let browser = context.browser
        owner = browser
        // A row fills its cell's width as the cell is laid out, so a column
        // only wider or narrower (its edge pulled, let go, put back) lays
        // each row out at its new width and hands SwiftUI nothing new. A
        // pin's square is drawn for its width, and is bound again for it.
        let size = item.isPin ? frame.size : CGSize(width: 0, height: frame.height)
        var live = false, picked = false, editing = false, refusals = 0, joint: Joint?, staged = false, lit = false
        var tab: ObjectIdentifier?, other: ObjectIdentifier?, count = 0, open = false, over: FacePose?, folder: Folders.Folder?, space: Space?
        rowTab = nil
        hitTab = nil
        switch item.kind {
        case .tab(let row):
            tab = ObjectIdentifier(row)
            rowTab = row
            hitTab = row
            live = row.id == context.liveID
            picked = browser.isPicked(row)
            editing = browser.editingTab == row.id
            refusals = editing ? browser.refusals : 0
            joint = browser.joint(of: row.id)
            staged = browser.stagePair?.contains(row.id) == true
        case .pair(let first, let second):
            tab = ObjectIdentifier(first)
            other = ObjectIdentifier(second)
            lit = browser.newTabLit
        case .nest(let nest, let n, let pose):
            tab = ObjectIdentifier(nest)
            count = n
            over = pose
        case .task(let made, let isOpen):
            folder = made
            open = isOpen
        case .more(_, let n):
            count = n
        case .newTab:
            lit = browser.newTabLit
        case .pin(let pin):
            tab = ObjectIdentifier(pin)
            // A pinned pair's square is lit with either half in front.
            let mate = browser.pinMate(of: pin)
            if mate == nil { hitTab = pin }
            other = mate.map(ObjectIdentifier.init)
            live = pin.id == context.liveID || (mate != nil && mate?.id == context.liveID)
            picked = browser.isPicked(pin)
            editing = browser.editingPin == pin.id
        case .home(let pin):
            tab = ObjectIdentifier(pin)
            hitTab = pin
        case .name(let shown):
            space = shown
        case .privateName, .line, .gap, .lineComing, .pinGap:
            break
        }
        let look = Look(id: item.id, tab: tab, other: other, live: live, picked: picked, editing: editing, refusals: refusals, joint: joint,
                        staged: staged, glyph: browser.prefs.glyph, glass: browser.prefs.glassPins, lit: lit, size: size, count: count, open: open, over: over,
                        folder: folder, space: space, pointed: context.pointedID == item.id, hold: hold, look: context.look)
        guard force || look != current else { return }
        SwitchMeter.note({
            guard let was = current else { return "bind new" }
            if force { return "bind force" }
            var why: [String] = []
            if was.id != look.id { why.append("id") }
            if was.live != look.live { why.append("live") }
            if was.picked != look.picked { why.append("picked") }
            if was.look != look.look { why.append("look") }
            if was.size != look.size { why.append("size") }
            if was.hold != look.hold { why.append("hold") }
            return "bind " + (why.isEmpty ? "other" : why.joined(separator: "+"))
        }())
        // The same row, only its hold changed: SwiftUI's own animation, as
        // SideBar's `withAnimation` around the drag state gave it.
        let same = current?.id == look.id
        if !same, !scrolled { generation += 1 }
        current = look
        itemID = item.id
        binds += 1
        ColumnCell.bound += 1
        let root = AnyView(Self.row(item, browser: browser, live: live, picked: picked, hold: hold, look: context.look, size: size,
                                    generation: generation, pointed: look.pointed))
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, hold.choice != nil || hold.compact {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { rootView = root }
        } else if same, let animation {
            withAnimation(animation) { rootView = root }
        } else {
            rootView = root
        }
        cast(hold.lifted, pin: item.isPin, animated: same && animation != nil)
    }

    /// The held row's lift cast by the cell's own layer, not by SwiftUI's
    /// `.shadow` on every row: SwiftUI hangs a shadow (clear, radius 0) on
    /// each of a resting row's layers, about 130 of them in the column, and
    /// the render server works each out on every frame the rows move (the
    /// GPU busy 25.5 → 22.9% scrolling 200 tabs without it, job d91fb0ce).
    /// YAB_SMOOTH_LIFT=swiftui casts it as before.
    static let layerLift = ProcessInfo.processInfo.environment["YAB_SMOOTH_LIFT"] != "swiftui"

    /// Whether the cell's layer casts the lift now.
    private(set) var casting = false

    /// The lift as SideBar's rows cast it: black 14% (a pin's 16%), 12 pt
    /// of blur (10), 4 pt down (3), coming and going on Motion.settle as
    /// SwiftUI's animation of the modifier did. At rest its opacity is 0,
    /// which the render server skips.
    private func cast(_ lifted: Bool, pin: Bool, animated: Bool) {
        guard Self.layerLift, let layer, lifted != casting else { return }
        casting = lifted
        let radius: CGFloat = pin ? 10 : 12
        let offset = CGSize(width: 0, height: (pin ? 3 : 4) * Self.down(layer))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowColor = NSColor.black.withAlphaComponent(pin ? 0.16 : 0.14).cgColor
        let was = (opacity: layer.presentation()?.shadowOpacity ?? layer.shadowOpacity,
                   radius: layer.presentation()?.shadowRadius ?? layer.shadowRadius,
                   offset: layer.presentation()?.shadowOffset ?? layer.shadowOffset)
        layer.shadowOpacity = lifted ? 1 : 0
        layer.shadowRadius = lifted ? radius : 0
        layer.shadowOffset = lifted ? offset : .zero
        if animated, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            layer.add(ColumnMotion.animation("shadowOpacity", ColumnMotion.settle, from: was.opacity, to: layer.shadowOpacity),
                      forKey: "column.lift.opacity")
            layer.add(ColumnMotion.animation("shadowRadius", ColumnMotion.settle, from: was.radius, to: layer.shadowRadius),
                      forKey: "column.lift.radius")
            layer.add(ColumnMotion.animation("shadowOffset", ColumnMotion.settle, from: NSValue(size: was.offset),
                                             to: NSValue(size: layer.shadowOffset)),
                      forKey: "column.lift.offset")
        } else {
            for key in ["column.lift.opacity", "column.lift.radius", "column.lift.offset"] { layer.removeAnimation(forKey: key) }
        }
        CATransaction.commit()
    }

    /// The row as SideBar draws it, in the column's words.
    private static func row(_ item: ColumnItem, browser: Browser, live: Bool, picked: Bool, hold: Hold, look: ColumnPages.Look, size: CGSize,
                            generation: Int, pointed: Bool) -> some View {
        let prefs = browser.prefs
        return Group {
            switch item.kind {
            case .tab(let tab):
                SideRow(browser: browser, prefs: prefs, tab: tab, live: live, picked: picked, lifted: hold.lifted)
                    // Stayed over by a held row: it turns into the folder
                    // the two would make, drawn in its place.
                    .opacity(hold.turn == nil && !hold.compact ? 1 : 0)
                    .overlay(alignment: .leading) {
                        if hold.compact {
                            Mark(icon: tab.displayIcon, letter: tab.monogram, size: 16)
                                .frame(width: 28, height: 28)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.control))
                        }
                    }
                    .overlay {
                        if let choice = hold.choice {
                            TabDropChoices(choice: choice, iconsOnly: SideBar.row < 36)
                        } else if let turn = hold.turn {
                            FolderToBe(tab: tab, turn: turn, made: hold.made, live: live, prefs: prefs)
                        }
                    }
            case .pair(let first, let second):
                PairRow(browser: browser, prefs: prefs, first: first, second: second, lifted: hold.lifted, shown: browser.newTabLit ? false : nil)
                    .opacity(hold.choice == nil && !hold.compact ? 1 : 0)
                    .overlay(alignment: .leading) {
                        if hold.compact {
                            Mark(icon: first.displayIcon, letter: first.monogram, size: 16)
                                .frame(width: 28, height: 28)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.control))
                        }
                    }
                    .overlay { if let choice = hold.choice { TabDropChoices(choice: choice, iconsOnly: SideBar.row < 36) } }
            case .nest(let nest, let count, let over):
                NestRow(browser: browser, nest: nest, count: count, aimed: hold.aimed, lifted: hold.lifted, over: over)
                    .opacity(hold.choice == nil ? 1 : 0)
                    .overlay { if let choice = hold.choice { TabDropChoices(choice: choice) } }
            case .task(let folder, let open):
                FolderRow(browser: browser, folder: folder, open: open)
            case .more(let folder, let count):
                FolderMore(folder: folder, count: count)
            case .line:
                KeptLine(browser: browser, reports: false, visible: true)
            case .lineComing:
                KeptLine(browser: browser)
                    .allowsHitTesting(false)
            case .newTab:
                Quiet(icon: "plus", title: "New tab", height: SideBar.row, news: true, lit: browser.newTabLit, prefs: prefs, browser: browser) { browser.newTab() }
                    // It raises the field: not away and back (Browser.fieldAway).
                    .background(ClickZone(away: browser.fieldAway))
            case .gap:
                ColumnGap(square: false)
            case .pin(let tab):
                PinSquare(browser: browser, prefs: prefs, tab: tab, live: live, width: size.width, height: size.height,
                          lifted: hold.lifted, pressed: hold.pressed)
            case .pinGap:
                ColumnGap(square: true)
            case .home(let tab):
                PinHomeField(browser: browser, tab: tab, height: size.height)
            case .name(let space):
                SpaceName(space: space, browser: browser, aimed: hold.aimed)
            case .privateName:
                PrivateName()
            }
        }
        // Reuse the graph on scroll. Row-local interaction state is keyed by
        // the model id, so a recycled graph cannot light its next row.
        .id(generation)
        // Only the one in the hand casts a shadow, as in SideBar: the
        // cell's layer casts it (`cast`), or SwiftUI as before.
        .modifier(SwiftUILift(on: !layerLift, lifted: hold.lifted, pin: item.isPin))
        .frame(width: item.isPin ? size.width : nil, height: size.height, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .environment(\.columnHosted, true)
        .environment(\.columnPointed, Self.pointable(item) ? pointed : nil)
        .environment(\.tabTitleSize, look.titleSize)
        .environment(\.colorScheme, look.scheme)
        .toned(look.tone)
    }

    /// The rows whose hover the column says (ColumnPage.point): a tab's,
    /// a pair's, a folder of yours.
    static func pointable(_ item: ColumnItem) -> Bool {
        switch item.kind {
        case .tab, .pair, .nest: return true
        default: return false
        }
    }

    /// Rows handed to SwiftUI by every page, for the bench.
    static var bound = 0

    // MARK: - coming and going

    /// A row come into the list: a folder's tab opening comes down from a
    /// little above and fades in, in its turn (FolderRowPlace); another
    /// takes its place whole, as SideRow's arrival does. The turns of
    /// `count` rows coming at once spread over no longer than six rows'
    /// (0.15 s): a folder of thirty is in as soon as a folder of six, not a
    /// second later, a row at a time (row 1060).
    func arrive(_ item: ColumnItem, order: Int, of count: Int) {
        guard let layer, item.indent > 0, case .tab = item.kind else { return }
        let delay = 0.05 + Double(order) * Self.turn(count)
        let fade = ColumnMotion.animation("opacity", ColumnMotion.opening, from: 0, to: 1)
        fade.beginTime = CACurrentMediaTime() + delay
        layer.add(fade, forKey: "column.arrive.fade")
        ColumnMotion.slide(layer, by: 6, ColumnMotion.opening, delay: delay)
    }

    /// The time between two rows' turns when `count` come in together.
    static func turn(_ count: Int) -> Double { 0.03 * min(1, 5 / Double(max(1, count - 1))) }

    /// A row come in as a ⌘-click makes or fills a folder: faded in where it
    /// stands, the folder's row and the link's, while the rest slide. The
    /// folder's row a moment late, once the page's row has dropped from
    /// under it: Dia's first moving frame has the page half way down and
    /// the folder's row barely there.
    func fadeIn(late: Bool) {
        guard let layer else { return }
        let fade = ColumnMotion.animation("opacity", ColumnMotion.opening, from: 0, to: 1)
        if late { fade.beginTime = CACurrentMediaTime() + 0.07 }
        layer.add(fade, forKey: "column.arrive.fade")
    }

    /// A row gone: it fades and gives a little, quicker than the room it
    /// leaves closes (SideRow's removal), then `done`.
    func leave(_ done: @escaping () -> Void) {
        guard let layer else { return done() }
        var completion: (() -> Void)? = done
        let finish = {
            guard let done = completion else { return }
            completion = nil
            done()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(finish)
        // The model stays gone even if AppKit drops the animations while
        // the host redraws. Only the presentation draws the leaving row.
        alphaValue = 0
        layer.opacity = 0
        let fade = ColumnMotion.animation("opacity", ColumnMotion.leave, from: 1, to: 0)
        layer.add(fade, forKey: "column.leave.fade")
        // And gives a little, 0.96 about its middle (a view's layer hangs
        // from its corner).
        let size = layer.bounds.size
        let smaller = CATransform3DConcat(CATransform3DMakeScale(0.96, 0.96, 1),
                                          CATransform3DMakeTranslation(size.width * 0.02, size.height * 0.02, 0))
        let give = ColumnMotion.animation("transform", ColumnMotion.leave, from: NSValue(caTransform3D: layer.transform),
                                          to: NSValue(caTransform3D: CATransform3DConcat(smaller, layer.transform)))
        layer.add(give, forKey: "column.leave.give")
        CATransaction.commit()
        // A stalled transaction must not keep an unowned host and its
        // title attached. A late completion cannot recycle the cell twice.
        DispatchQueue.main.asyncAfter(deadline: .now() + ColumnMotion.duration(ColumnMotion.leave) + 0.05) { finish() }
    }

    // MARK: - moved by a hand

    /// Where the hand has the row, off its place, and how it is drawn there:
    /// its whole layer moved, on `curve` or at once.
    private(set) var shift: CGSize = .zero
    private(set) var lean = Lean()

    /// What a held row is drawn as besides moved: stepped in, off to the
    /// side and smaller, scaled about its top left or its middle.
    struct Lean: Equatable {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var scale: CGFloat = 1
        var centered = false
    }

    func move(to shift: CGSize, _ curve: ColumnMotion.Curve?) {
        guard let layer, shift != self.shift else { return }
        let from = self.shift
        self.shift = shift
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(shift.width, shift.height * Self.down(layer), 0)
        CATransaction.commit()
        if let curve {
            ColumnMotion.slide(layer, by: (shift.height - from.height) * Self.down(layer), dx: shift.width - from.width, curve)
        }
    }

    /// Stepped in, aside, smaller: SwiftUI's padding, offset and scaleEffect
    /// on the held row, as one transform of the row's own content.
    func lean(_ lean: Lean, _ curve: ColumnMotion.Curve?) {
        guard let layer, lean != self.lean else { return }
        let was = transform(self.lean, in: layer)
        self.lean = lean
        let now = transform(lean, in: layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = now
        if let curve {
            let animation = ColumnMotion.animation("sublayerTransform", curve, from: NSValue(caTransform3D: was), to: NSValue(caTransform3D: now))
            layer.add(animation, forKey: "column.lean")
        }
        CATransaction.commit()
    }

    /// Which way down is in the layer's space: each layer above it that is
    /// geometry-flipped turns its sublayers' y over, so it is the count of
    /// them all, not the parent's alone. AppKit may flip the rows' document
    /// or the clip view over it, and leave the other plain; reading only
    /// the parent sent the held row up as the hand went down.
    static func down(_ layer: CALayer) -> CGFloat {
        guard layer.superlayer != nil else { return 1 }
        var flips = 0
        var above = layer.superlayer
        while let at = above {
            if at.isGeometryFlipped { flips += 1 }
            above = at.superlayer
        }
        return flips % 2 == 1 ? 1 : -1
    }

    private func transform(_ lean: Lean, in layer: CALayer) -> CATransform3D {
        let size = layer.bounds.size
        let down = Self.down(layer)
        // A sublayer transform hangs from the layer's anchor.
        let a = CGPoint(x: layer.anchorPoint.x * size.width, y: layer.anchorPoint.y * size.height)
        // The point scaled about, in the layer's own space: its middle, or
        // its top left, which is its origin only when y goes down.
        let p = lean.centered ? CGPoint(x: size.width / 2, y: size.height / 2) : CGPoint(x: 0, y: down > 0 ? 0 : size.height)
        func move(_ x: CGFloat, _ y: CGFloat) -> CATransform3D { CATransform3DMakeTranslation(x, y, 0) }
        var t = move(a.x, a.y)
        t = CATransform3DConcat(t, move(-p.x, -p.y))
        t = CATransform3DConcat(t, CATransform3DMakeScale(lean.scale, lean.scale, 1))
        t = CATransform3DConcat(t, move(p.x, p.y))
        t = CATransform3DConcat(t, move(lean.x, lean.y * down))
        return CATransform3DConcat(t, move(-a.x, -a.y))
    }
}

/// The held row's lift as SwiftUI cast it on every row, for
/// YAB_SMOOTH_LIFT=swiftui (`on` is fixed for the run, so the row's identity
/// never changes with it).
private struct SwiftUILift: ViewModifier {
    let on: Bool
    let lifted: Bool
    let pin: Bool

    func body(content: Content) -> some View {
        if on {
            content
                .shadow(color: .black.opacity(lifted ? (pin ? 0.16 : 0.14) : 0), radius: lifted ? (pin ? 10 : 12) : 0, // design: the held row's lift, as SideBar casts it
                        y: lifted ? (pin ? 3 : 4) : 0)
        } else {
            content
        }
    }
}

/// Where a tab carried in would land: a row's or a pin's place, washed.
struct ColumnGap: View {
    let square: Bool
    @Environment(\.tone) private var tone

    var body: some View {
        GeometryReader { geo in
            let corner = square ? SideBar.corner(min(geo.size.width, geo.size.height)) : SideBar.radius
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Palette.wash(on: tone).opacity(0.35))
        }
    }
}

/// State that belongs to a model, rather than the hosting cell's SwiftUI
/// graph. Reads on rebind are clean immediately, before onChange/tracking
/// callbacks; writing a new owner's value discards the previous owner's.
struct RowLocalState<Value> {
    private var owner: UUID?
    private var stored: Value
    private let initial: Value

    init(_ initial: Value) { self.initial = initial; stored = initial }

    subscript(_ id: UUID) -> Value {
        get { owner == id ? stored : initial }
        set { owner = id; stored = newValue }
    }
}
