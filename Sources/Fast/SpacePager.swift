import AppKit
import QuartzCore
import SwiftUI

// The column's spaces as one row of pages, a column wide, that slides when
// the space changes, the way Arc's do (SpacePaging has the numbers,
// docs/space-switching.md how they were measured).
//
// All of it is Core Animation's. When a change begins, the space's own part
// of the column, its pins, its name and its rows between the plate and the
// foot, is pictured once, and the column's live drawing of that part is
// masked out; the spaces beside it are drawn by hosts of their own
// (PagedSpace) and laid either side of the picture. Two fingers then move
// one transform a move; a key, a click or a let-go hand it to a spring the
// render server plays, while the main thread lays the new space out under
// the mask. When the spring has landed the pages go and the mask with them:
// the column under them is the space they were showing. Before this the
// rows were moved by SwiftUI, a pass of the main thread every frame of the
// swipe.
//
// The pins every space shares (docs/shared-pins.md) stand still over the
// row, as Arc's Favorites do, while every space it goes past shows them:
// the window onto the row then starts under them, at the space's name, so
// only the space's own part is seen sliding; the pages' drawing of the
// pins is out of it, and the column's own, live, is left unmasked. To or
// from a space with pins of its own, Mail, the pins go with their
// pages, as every space's did before they were shared (`hold`).

@MainActor
final class SpacePager {
    static let shared = SpacePager()

    private weak var browser: Browser?
    private var stage: PagerStage?
    /// The spaces, in the order the row of pages has them, when it came up.
    private var order: [UUID] = []
    /// Which of them stands at no offset: the one on screen when it came up.
    private var home = 0
    /// How far the row of pages is slid, the model's value, negative
    /// toward the spaces after.
    private var offset: CGFloat = 0
    private var page: CGFloat = 0
    /// Fingers on the column.
    private(set) var holding = false
    /// Springs still landing, of this coming up of the pages.
    private var landings = 0
    private var generation = 0
    /// The color over the window while the fingers hold: the space they
    /// are taking it to, and how much of it shows.
    private var wash: (index: Int, opacity: Swift.Float)?
    /// Set while a let-go switches the space itself, so the switch doesn't
    /// start a turn of its own.
    private var switching = false
    /// The column is a card over the page.
    private var floating = false
    /// Its ground is laid once under the row, not carried by each page.
    private var shared = false
    /// The band, in the column's space, and how far down it the part under
    /// the pins starts (ColumnView.underPins): what slides while they stand
    /// still. Zero with no pins over it.
    private(set) var band: CGRect = .zero
    private var underPins: CGFloat = 0
    /// The band takes in the plate: Mail, or spaces with different plate heights.
    private var plate = false
    /// What each page's grid shows, by its place in the order.
    private var pins: [Int: [Tab.ID]] = [:]

    /// With the AppKit column (ColumnKit), the row of pages is the column's
    /// own live pages (ColumnPages), slid in place: no picture, no mask.
    private weak var live: ColumnPages?
    /// The shared grid's last plate while showRow replaces its tabs and ID.
    private weak var livePlateTab: Tab?
    /// The places in the order whose page the live row has laid.
    private var livePages: Set<Int> = []

    /// The pages are up, moving or landing.
    var active: Bool { stage != nil || live != nil }
    func covers(_ browser: Browser) -> Bool { stage != nil && self.browser === browser }
    func keptPlate(in browser: Browser) -> Tab? {
        // showRow's two writes can briefly hide a nonempty front.
        guard live != nil, self.browser === browser,
              browser.rowTurning || browser.activeID != nil else { return nil }
        return livePlateTab
    }
    /// For the bench's track: 0 at rest, 1 the live row, 2 pictured
    /// pages, 3 pictured pages carrying the plate.
    var mode: Int { live != nil ? 1 : stage == nil ? 0 : plate ? 3 : 2 }

    private init() {
        // While fingers hold the row, what says they have gone though their
        // lift never came to the column (`lost`).
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { SpacePager.shared.away(note) }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { note in
            MainActor.assumeIsolated { SpacePager.shared.away(note) }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated { SpacePager.shared.heard(event) }
            return event
        }
    }

    // MARK: - keys, clicks, the tray

    /// A change of space is about to happen by key, click or menu: picture
    /// the space on screen and lay out the ones it will slide past. False
    /// when the column isn't there to slide, or shouldn't.
    func turn(_ browser: Browser, to id: UUID) -> Bool {
        if switching { return false }
        guard Self.allowed(browser), let target = browser.turnOrder.firstIndex(where: { $0.id == id }) else {
            if active { finish() }
            return false
        }
        if holding { finish() }
        // A changing plate goes with its page, including a key that turns
        // a still-landing live row toward a differently plated space.
        let movingPlate = Self.movesPlate(browser, toward: target) ?? true
        // Where the live row is drawn from the space it lands on: the
        // pictured row starts there, not snapped to that space.
        var carried: CGFloat = 0
        if live != nil, movingPlate {
            carried = drawn - offset
            finish()
        }
        guard active || raise(browser, toward: target, movingPlate: movingPlate) else { return false }
        guard order == browser.turnOrder.map(\.id) else { finish(); return false }
        if abs(carried) > 0.5 {
            let leaving = home + (carried < 0 ? 1 : -1)
            if order.indices.contains(leaving) { build(leaving) }
            set(carried)
        }
        // Every space between, so the row goes past them as Arc's does.
        let now = Int((-offset / max(page, 1)).rounded()) + home
        for index in min(now, target)...max(now, target) where index != home { build(index) }
        // The pins stand still when every space the row goes past shows
        // the same ones.
        hold(same(min(home, now, target)...max(home, now, target)))
        doors(toward: Array(min(home, now, target)...max(home, now, target)))
        SpaceShown.shared.pulled = true
        pendingTarget = target
        return true
    }

    private var pendingTarget: Int?

    /// The switch has been made: the row lands on its space.
    func land() {
        guard let target = pendingTarget else { return }
        pendingTarget = nil
        animate(to: -CGFloat(target - home) * page, velocity: 0)
    }

    // MARK: - fingers

    /// Two fingers have begun sideways over the column, `event` the move
    /// they took the row with.
    func grab(_ browser: Browser, by event: NSEvent) -> Bool {
        guard Self.allowed(browser), browser.turnOrder.count > 1 else { return false }
        // A landing still under way lands now; the fingers start from the
        // space it brought.
        ColumnSpaceCarry.of(browser)?.willPage()
        if active { finish() }
        guard raise(browser) else { return false }
        holding = true
        heldSince = event.timestamp
        return true
    }

    /// When the move that took the row was made: what came before it, or
    /// with it, is the gesture holding the row, not fingers down anew.
    private var heldSince: TimeInterval = 0

    /// The fingers have gone `travel` points, negative toward the next space.
    func follow(_ travel: CGFloat) {
        guard holding, let browser else { return }
        let back = home > 0, forward = home < order.count - 1
        let x = CGFloat(SpacePaging.offset(travel: Double(travel), page: Double(page), back: back, forward: forward))
        // The space it is going toward drawn beside it, its page woken.
        if x < 0, forward { build(home + 1) }
        if x > 0, back { build(home - 1) }
        let toward = x < 0 ? home + 1 : home - 1
        // Toward a space that shows the same pins they stand still, toward
        // one with others, or none, they go with their page; past the first
        // or the last space, where the row only gives, they stay.
        if x != 0 { hold(!order.indices.contains(toward) || same(toward...toward)) }
        if x != 0 { doors(toward: [toward]) }
        set(x)
        // The window takes on that space's color as far as the row has gone,
        // and a card's ground with it (SpaceWash's grounds).
        let share = Swift.Float(min(1, abs(x) / max(page, 1)))
        if x != 0, order.indices.contains(toward), let paint = paint(toward, browser) {
            browser.spaceWash.show(paint, opacity: share)
            wash = (toward, share)
        } else if let was = wash, let paint = paint(was.index, browser) {
            browser.spaceWash.show(paint, opacity: 0)
            wash = nil
        }
    }

    /// The fingers have lifted, going `speed` points a second.
    func release(speed: CGFloat) {
        guard holding, let browser else { return }
        holding = false
        let back = home > 0, forward = home < order.count - 1
        let to = SpacePaging.landing(offset: Double(offset), speed: Double(speed), page: Double(page), back: back, forward: forward)
        let target = -CGFloat(to) * page
        SpaceSwipe.note("release offset=\(Int(offset)) speed=\(Int(speed)) to=\(to)")
        // The row goes on as fast as it was going, toward where it lands.
        let velocity = speed * CGFloat(SpacePaging.follow)
        let showing = wash
        wash = nil
        if to == 0 {
            if let showing, let paint = paint(showing.index, browser) {
                browser.spaceWash.clear(paint, from: showing.opacity, spring: true)
            }
            animate(to: target, velocity: velocity)
            return
        }
        // Gone: the space comes at once, as Arc's page does, under a spring
        // the render server plays while its row is laid out.
        let id = order[home + to]
        let old = SpaceWash.grounded(in: browser)
        let shown = showing?.opacity ?? 0
        // How fast the row sets off, of its whole way a second, as its
        // spring has it (PagerStage.land): the color sets off as fast.
        let delta = offset - target
        let pace = abs(delta) > 0.25 ? -velocity / delta : 0
        animate(to: target, velocity: velocity)
        // The color goes on with it, on its spring, from as far over as the
        // fingers took it: sent with the row, not after the switch, where it
        // stood still while the row landed and came 100 to 200 ms after it,
        // more out of Mail (wash_matrix.py).
        var went = false
        if old != nil, let new = paint(home + to, browser) {
            browser.spaceWash.go(new, from: shown, velocity: pace)
            went = true
        }
        // Off to the render server now: the switch lays the window out for
        // the new space before its frame, and the row stood still where the
        // fingers left it that long, 100 to 200 ms (feedback, 2026-10-09).
        CATransaction.flush()
        // When the two set off, the row's spring's own start when it has one.
        let began = went ? slideBegan ?? CACurrentMediaTime() : nil
        SpaceShown.shared.pulled = true
        switching = true
        browser.switchSpace(to: id, washed: true)
        switching = false
        // The new color is the window's now; the old one over it clears from
        // as much of it as still showed, on the spring the row and the color
        // set off on before the switch, where it has got to: the same mix.
        if let old {
            browser.spaceWash.clear(old, from: 1 - shown, spring: true, base: SpaceWash.grounded(in: browser),
                                   began: began, velocity: pace)
        } else {
            browser.spaceWash.hide()
        }
    }

    // MARK: - fingers that lifted unseen

    /// SpaceSwipe lets the row go when the gesture's end comes to the
    /// column's window. A swipe of three fingers to another desktop, begun
    /// as two over the column, hands its end to whatever window is under
    /// the pointer there, and the row stood held part way, a page's
    /// stretch past the first space or the last, the column's own rows
    /// masked under it, a card gone or docked or not, until the space was
    /// changed by hand (0.0.13). Any of these lets it go as a lift would:
    /// Yab going from the front or coming back to it, the column's window
    /// out of sight or closed, the desktop changed, a click, fingers down
    /// anew, or a gesture's end SpaceSwipe didn't take.
    private func away(_ note: Notification) {
        // A window closing lets go of the pages kept (`made`): theirs hold
        // its browser, and with it every tab of its spaces.
        if note.name == NSWindow.willCloseNotification, let window = note.object as? NSWindow, window === madeIn {
            made = [:]
            madeOrder = []
        }
        guard holding else { return }
        if let window = note.object as? NSWindow {
            guard window === browser?.column?.window else { return }
            if note.name == NSWindow.didChangeOcclusionStateNotification, window.occlusionState.contains(.visible) { return }
        }
        // Which of them it was, for the bench's trace: a row let go
        // mid-swipe with no event of its own to blame was one of these.
        SpaceSwipe.note("let go by \(note.name.rawValue)")
        lost(generation)
    }

    private func heard(_ event: NSEvent) {
        guard holding else { return }
        let run = generation
        // A press has no phase: asked one, NSEvent throws, and AppKit drops
        // the press with the throw. A click while the row was held did
        // nothing, the page's own click with it, and the row stayed up.
        let scroll = event.type == .scrollWheel
        let phase: NSEvent.Phase = scroll ? event.phase : []
        switch Self.parting(scroll: scroll, phase: phase, momentum: scroll ? event.momentumPhase : [],
                            at: event.timestamp, heldSince: heldSince) {
        case .now:
            SpaceSwipe.note("let go by type=\(event.type.rawValue) phase=\(phase.rawValue)")
            lost(run)
        // An end the column's window takes lets the row go at the
        // fingers' speed (SpaceSwipe); one still holding it once the end
        // has been heard went somewhere else.
        case .afterSwipe: DispatchQueue.main.async { SpacePager.shared.lost(run) }
        case .no: break
        }
    }

    enum Parting: Equatable { case now, afterSwipe, no }

    /// What an event heard while fingers hold the row says of them: gone
    /// now (a click, fingers down anew), gone unless the column's catch
    /// takes this end first, or nothing.
    ///
    /// Every local monitor hears every event, the catch's taking it
    /// (returning nil) or not, and in an order AppKit doesn't keep: it
    /// changes as monitors come and go. A trackpad's began carries the
    /// fingers' first move, and SpaceSwipe takes the row with it; heard
    /// here after that, it read as fingers down anew and let the row go
    /// at once, a few points out. Every swipe over the column did nothing
    /// from then on until the order turned again, a while later or at the
    /// next launch (#98, #100). What came with the move that took the row,
    /// or before it, is the same fingers.
    nonisolated static func parting(scroll: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase,
                                    at time: TimeInterval, heldSince: TimeInterval) -> Parting {
        guard scroll else { return .now }
        guard time > heldSince else { return .no }
        if phase == .began || phase == .mayBegin { return .now }
        if phase == .ended || phase == .cancelled || momentum != [] { return .afterSwipe }
        return .no
    }

    /// Let go where it is, as fingers lifted still.
    private func lost(_ run: Int) {
        guard holding, generation == run else { return }
        release(speed: 0)
    }

    /// The column as SwiftUI lays it now: pages up over a card that has
    /// gone past the edge, or over a column whose shape changed under
    /// them, a card docked or the other way round, come down.
    func settle(_ browser: Browser, out: Bool) {
        guard active, self.browser === browser else { return }
        if !out || floating != (browser.prefs.sideShut && browser.sideCard) { finish() }
    }

    // MARK: - the pages

    /// Whether the column's spaces may slide: the column on screen, in its
    /// place or brought out over the page as a card, and motion wanted.
    ///
    /// The card was left out at first (0.0.8, 9ece098b), and a swipe over
    /// it fell back to the old way, whose space coming under the rows had
    /// gone with that change: the rows faded out and nothing came until
    /// the fingers lifted. A column put away and brought out by the edge
    /// is how many keep it; it slides as the docked one does.
    ///
    /// With spaces off, Mail and the one space slide too, into Mail as well
    /// as out of it: only Mail on screen was let slide, so going in by the
    /// envelope or two fingers had no row under it (feedback #158).
    static func allowed(_ browser: Browser) -> Bool {
        guard let column = browser.column, !SpaceTurn.still else { return false }
        return SpacePaging.slides(place(browser, column), spaces: browser.prefs.usesSpaces || withMail(browser, toward: nil),
                                  reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Whether the docked column wears a ground of its own, as it did edge
    /// to edge from c768dcbb until #256 stood it on the window's backdrop.
    /// Who carries the ground is SpacePaging.ground's to say, for every
    /// way the window can be.
    static func ownGround(_ browser: Browser) -> Bool {
        SpacePaging.ground(backdrop: browser.prefs.backdrop, place: .docked) == .row && SpaceWash.grounded(in: browser) != nil
    }

    /// Whether Mail is in this change of space: on screen, the space it
    /// goes to, or with fingers, beside the one on screen.
    static func withMail(_ browser: Browser, toward target: Int?) -> Bool {
        if browser.inMail { return true }
        let order = browser.turnOrder.map(\.id)
        guard order.contains(Space.mailID), let home = order.firstIndex(of: browser.spaceID) else { return false }
        let near = SpacePlateRouting.places(home: home, count: order.count, toward: target)
        return near.contains { order.indices.contains($0) && order[$0] == Space.mailID }
    }

    /// Nil until setup has restored an unknown row. Diagnostics and
    /// picture-ahead checks never restore tabs or their configurations.
    private static func movesPlate(_ browser: Browser, toward target: Int?, load: Bool = false) -> Bool? {
        if withMail(browser, toward: target) { return true }
        guard ColumnKit.on else { return false }
        let order = browser.turnOrder.map(\.id)
        guard let home = order.firstIndex(of: browser.spaceID) else { return nil }
        let current = SidePlate.extensionPlate(in: browser, space: browser.spaceID, tab: browser.active, shown: browser.sidePlated)
        let travelling = browser.tabs.filter(browser.travels)
        let plates: [SpacePlateRouting.Plate?] = SpacePlateRouting.places(home: home, count: order.count, toward: target).map { index in
            let id = order[index]
            if load, browser.parked[id] == nil { browser.parked[id] = browser.loadRow(id) }
            guard let row = browser.parked[id].map({ browser.withShared($0, in: id) }) else { return nil }
            let tab = (row.tabs + travelling).first { $0.id == row.active }
            return SidePlate.extensionPlate(in: browser, space: id, tab: tab, shown: browser.sidePlated(row))
        }
        return SpacePlateRouting.moves(from: current, to: plates)
    }

    /// The same plate-inclusive band for the picture, prepared pages and
    /// the stage that will show them.
    private static func plateBand(_ band: CGRect, top: CGFloat) -> CGRect {
        let edge = (top + Metrics.strip - SidePlate.lift).rounded(.down)
        return edge < band.minY ? CGRect(x: band.minX, y: edge, width: band.width, height: band.maxY - edge) : band
    }

    /// Where the column is now, as the browser has it: the view's own
    /// word for it comes with SwiftUI's next pass over it, which a window
    /// out of sight may not have had yet.
    static func place(_ browser: Browser, _ column: ColumnView) -> SpacePaging.Place {
        guard column.window != nil, browser.prefs.sidebar else { return .away }
        if !browser.prefs.sideShut { return .docked }
        return browser.sidePeek ? .card : .away
    }

    /// The pages up over the column: the space on screen pictured, its live
    /// drawing masked out.
    private func raise(_ browser: Browser, toward target: Int? = nil, movingPlate: Bool? = nil) -> Bool {
        let mail = Self.withMail(browser, toward: target)
        let carriesPlate = movingPlate ?? Self.movesPlate(browser, toward: target) ?? true
        if ColumnKit.on && !carriesPlate { return raiseLive(browser) }
        // Out over the page as a card, the column stands in from the
        // window's edges and paints a ground of its own, cut out of the
        // card with the band. The picture is taken without it, and it is
        // laid back still under the row (PagerStage.ground), where it turns
        // with the rest of the card and the window, the next space's color
        // over it as far as the row has gone, as Arc's color goes
        // (CardGround, SpaceWash's grounds).
        let floating = browser.prefs.sideShut && browser.sideCard
        guard let column = browser.column, var band = column.spaceBand(browser), band.width > 20, band.height > 20 else { return false }
        let top = (floating ? Metrics.floatInset : 0) + browser.menuDown
        // Different plate heights travel with their pages, as Mail's do:
        // the native rows and the stationary SwiftUI plate share one mask.
        if carriesPlate { band = Self.plateBand(band, top: top) }
        let height = column.bounds.height - top - (floating ? Metrics.floatInset : 0)
        // Where the pointer is, for the pages to come in under it as the
        // column will stand: its plate's doors and the row under it lit.
        SlidePointer.shared.take(column, band: band, top: top)
        // Light the live column too before the pager covers it. Its grid
        // finishes the hover fade behind the travelling page, instead of
        // starting that fade only after the page is removed at landing.
        column.rehover()
        let card = CGRect(x: band.minX, y: top, width: band.width, height: height)
        // Docked edge to edge the column wears its space's look on a ground
        // of its own, as the card does: left out of the picture and laid
        // once under the row, it turns with the fingers (c768dcbb wore it
        // docked but left it in each page, and the color stood still until
        // the row landed).
        let own = !floating && Self.ownGround(browser)
        let carded = floating && SpacePaging.ground(backdrop: browser.prefs.backdrop, place: .card) == .row
        let taken = picture(column, band: band, card: carded ? card : nil, own: own, browser: browser)
        SwitchMeter.mark("pictured")
        guard let picture = taken.image else { return false }
        let order = browser.turnOrder.map(\.id)
        guard let home = order.firstIndex(of: browser.spaceID) else { return false }
        self.browser = browser
        self.order = order
        self.home = home
        page = band.width
        offset = 0
        landings = 0
        generation += 1
        wash = nil
        self.floating = floating
        self.band = band
        plate = carriesPlate
        underPins = column.underPins(browser, in: band) ?? 0
        pins = [home: browser.tabs.filter { $0.pin != nil }.map(\.id)]
        // Found and left out of the picture: one ground under the row.
        // Not found, each page carries its own (PagedSpaceRoot).
        shared = taken.dropped
        let stage = PagerStage(band: band, picture: picture, beside: taken.beside, scale: column.window?.backingScaleFactor ?? 2,
                               top: top, height: height, rim: floating ? PagerStage.rim : 0)
        if shared {
            // Its color as it is now: the switch hands it the next
            // space's, as it does the card around it.
            let paint = SpaceWash.grounded(in: browser)
            stage.ground(PagedGround(browser: browser, prefs: browser.prefs, paint: paint), paint: paint, wash: browser.spaceWash)
        }
        // The head's doors go with their pages too, over the band: Mail's
        // New Mail where a space has back, forward and reload. Not with
        // the column out as a card, whose ground the doors' window would
        // cut a hole in.
        if mail, !floating, band.minY > top {
            // Clear of the lights by a door's gap, the fade (doorsFade)
            // over it: the doors went out through the green light.
            let lights = browser.flank == .left ? Metrics.sideLights + SideBar.margin + 6 : 0
            let rect = CGRect(x: band.minX + lights, y: top, width: band.width - lights, height: band.minY - top)
            if let doors = column.pictureAll(rect, bare: own && shared) {
                stage.doorsRow(rect, picture: doors, scale: column.window?.backingScaleFactor ?? 2,
                               ground: own && shared ? SpaceWash.grounded(in: browser) : nil, wash: browser.spaceWash)
                // Every space's it may go to, drawn now: the one beside it
                // either way for fingers, every one on the way for a key.
                let places = target.map { Array(min(home, $0)...max(home, $0)) } ?? [home - 1, home + 1]
                for index in places where index != home {
                    if let made = doorsPicture(index, browser: browser) { stage.adoptDoors(made.image, scale: made.scale, at: index - home, index: index) }
                }
            }
        }
        column.raise(stage)
        // A row's card was over the space that slides away: gone with it.
        if browser.glance.shown != nil { browser.glance.drop() }
        // The card's blur and its row's in one backdrop group, one picture
        // of the page under them both (PagerStage.ground).
        if shared { column.cardFrosts.forEach { $0.group = PagerStage.frostGroup } }
        self.stage = stage
        mask()
        return true
    }

    /// The row of the AppKit column's own pages up: the space on screen's at
    /// no offset, the others laid beside it as the row comes to them.
    private func raiseLive(_ browser: Browser) -> Bool {
        let tab = browser.active
        let grid = SidePlate.pinsHeight(in: browser, space: browser.spaceID, tab: tab) > 0
        guard let pages = ColumnPages.of(browser), let column = browser.column else { return false }
        let order = browser.turnOrder.map(\.id)
        guard let home = order.firstIndex(of: browser.spaceID), pages.beginSlide(order: order, home: home) else { return false }
        self.browser = browser
        self.order = order
        self.home = home
        page = pages.bounds.width
        offset = 0
        landings = 0
        generation += 1
        wash = nil
        floating = browser.prefs.sideShut && browser.sideCard
        // Where the space's own part is, as with the pictures: what the
        // bench and overlap.py compare.
        band = column.spaceBand(browser) ?? pages.convert(pages.bounds, to: column)
        underPins = 0
        pins = [home: browser.tabs.filter { $0.pin != nil }.map(\.id)]
        live = pages
        livePlateTab = grid ? tab : nil
        livePages = [home]
        if browser.glance.shown != nil { browser.glance.drop() }
        SwitchMeter.mark("pictured")
        return true
    }

    /// The column's own drawing of the band hidden while the row is up: a
    /// card's hairline down either edge stays live, out of the mask and
    /// the window onto the row, and so do the pins while they stand still.
    private func mask() {
        guard let stage else { return }
        var hidden = floating ? band.insetBy(dx: PagerStage.rim, dy: 0) : band
        hidden.origin.y += stage.cut
        hidden.size.height -= stage.cut
        browser?.column?.maskSpace(hidden, also: stage.hasDoors && stage.doorsGo ? stage.doorsFrame : nil)
    }

    /// The pins over the row stand still, or go with their pages. Still
    /// while every page it goes past shows the same ones, the pins every
    /// space shares: the window onto the row starts under them, the pages'
    /// own drawing of them out of it, and the column's own, live, let
    /// through. With their pages to or from a space with pins of its own,
    /// Mail, as every space's pins went before they were shared.
    private func hold(_ still: Bool) {
        if let live {
            live.holdPins(still)
            return
        }
        guard let stage else { return }
        // Identical pin IDs do not stand at the same height when the
        // plate changes. Keep the whole plate/pins band in the row.
        let cut = still && !plate ? underPins : 0
        guard cut != stage.cut else { return }
        stage.hold(cut)
        mask()
    }

    /// The head's doors go with the row when Mail is on screen or among
    /// the places it goes to, and stand still otherwise.
    private func doors(toward places: [Int]) {
        guard let stage, stage.hasDoors else { return }
        let go = ([home] + places).contains { order.indices.contains($0) && order[$0] == Space.mailID }
        guard go != stage.doorsGo else { return }
        stage.doors(go: go)
        mask()
    }

    private func same(_ places: ClosedRange<Int>) -> Bool {
        guard let browser, order.indices.contains(home), browser.showsShared(order[home]),
              places.allSatisfy({ order.indices.contains($0) && browser.showsShared(order[$0]) }) else { return false }
        return Self.stands(pins, home: home, over: places)
    }

    /// Whether the pages at these places all show the pins the one at
    /// `home` does, each drawn already: then the pins stand still while the
    /// row goes past them. None, they have nothing to stand still for.
    nonisolated static func stands(_ pins: [Int: [UUID]], home: Int, over places: ClosedRange<Int>) -> Bool {
        guard let mine = pins[home], !mine.isEmpty else { return false }
        return places.allSatisfy { pins[$0] == mine }
    }

    /// The page of the space at `index` in the row, drawn if it isn't yet.
    private func build(_ index: Int) {
        guard let browser, order.indices.contains(index), index != home else { return }
        if live != nil {
            guard !livePages.contains(index) else { return }
        } else {
            guard let stage, stage.pages[index] == nil else { return }
        }
        let id = order[index]
        let mail = id == Space.mailID
        var row: Parked?
        if !mail {
            if id == browser.spaceID {
                // On screen already, the switch made: its row is the browser's own.
                row = Parked(tabs: browser.tabs.filter { !browser.travels($0) }, active: browser.activeID, pairs: browser.pairs)
            } else {
                if browser.parked[id] == nil { browser.parked[id] = browser.loadRow(id) }
                row = browser.parked[id].map { browser.withShared($0, in: id) }
                // Its page in front, and the other of two side by side,
                // woken now: by the time the row lands they are drawn.
                if let row, let front = row.tabs.first(where: { $0.id == row.active }) {
                    if !front.wake() { front.revive() }
                    if let pair = row.pairs.first(where: { $0.first == front.id || $0.second == front.id }),
                       let other = row.tabs.first(where: { $0.id == (pair.first == front.id ? pair.second : pair.first) }) {
                        if !other.wake() { other.revive() }
                    }
                }
            }
        }
        let travelling = browser.tabs.filter(browser.travels)
        pins[index] = mail ? [] : ((row?.tabs ?? []) + travelling).filter { $0.pin != nil }.map(\.id)
        if let live {
            livePages.insert(index)
            let kept = live.build(index, row: row, travelling: travelling)
            SwitchMeter.mark(kept ? "page kept" : "page laid")
            return
        }
        guard let stage else { return }
        let painted = paint(index, browser)
        // A picture made while the pointer was away cannot show the plate's
        // hover doors or extension grid. Draw a live page under the pointer
        // instead, so they do not appear only after the row lands.
        if !SlidePointer.shared.near, let snap = snaps[id], snap.sign == Self.sign(row, travelling: travelling),
           snap.key == pageKey(id, row: row, travelling: travelling, paint: painted, band: band, floating: floating, shared: shared,
                               plate: plate, browser: browser),
           let scale = browser.column?.window?.backingScaleFactor {
            stage.adopt(picture: snap.image, scale: scale, at: index - home, index: index)
            SwitchMeter.mark("page pictured")
            return
        }
        let made = page(id, row: row, travelling: travelling, paint: painted, band: band, floating: floating, shared: shared,
                        plate: plate, browser: browser)
        stage.adopt(made.host, at: index - home, index: index, kept: made.kept)
        SwitchMeter.mark(made.kept ? "page kept" : "page laid")
    }

    /// A space's page, the one kept if it still shows what the space does
    /// (`made`), or made now and kept. Laid out once for the band, so the
    /// frame it is first shown in is whole.
    private func page(_ id: UUID, row: Parked?, travelling: [Tab], paint: SpaceWash.Paint?, band: CGRect, floating: Bool, shared: Bool,
                      plate: Bool = false, browser: Browser) -> (host: NSView, kept: Bool) {
        let mail = id == Space.mailID
        let scrollOffset = PagedSpace.savedOffset(in: browser, space: id)
        let rows = Int(((band.height + scrollOffset) / (SideBar.row + SideBar.gap)).rounded(.up)) + 1
        // Made before and still what the space shows: shown again, at no
        // cost. Back and forth between two spaces, each page is made once.
        let key = pageKey(id, row: row, travelling: travelling, paint: paint, band: band, floating: floating, shared: shared,
                          plate: plate, browser: browser)
        if let key, let page = made[id], page.key == key { return (page.host, true) }
        let view = PagedSpace(browser: browser, prefs: browser.prefs, mail: mail, row: row,
                              travelling: travelling, space: browser.spaces.first { $0.id == id }, empty: browser.folderBook.empties(in: id),
                              rows: rows, scrollOffset: scrollOffset, plate: plate)
        let host = PagerStage.page(PagedSpaceRoot(browser: browser, prefs: browser.prefs, content: view, paint: paint,
                                                  floating: floating, grounded: !shared))
        if let key { keep(host, key: key, for: id, in: browser.column?.window) }
        return (host, false)
    }

    /// What a page shows, as `page` keeps it (`made`) and its picture
    /// made ahead (`snaps`). Nil for Mail's.
    private func pageKey(_ id: UUID, row: Parked?, travelling: [Tab], paint: SpaceWash.Paint?, band: CGRect, floating: Bool, shared: Bool,
                         plate: Bool, browser: Browser) -> String? {
        guard id != Space.mailID else { return nil }
        let rows = Int((band.height / (SideBar.row + SideBar.gap)).rounded(.up)) + 1
        return Self.key(id, row: row, travelling: travelling, rows: rows, paint: paint,
                        size: CGSize(width: band.width, height: band.height), floating: floating, shared: shared, browser: browser)
            + " \(plate) \(SlidePointer.shared.near) \(PagedSpace.savedOffset(in: browser, space: id))"
    }

    /// A space's head doors as a picture, for the doors' row: drawn at
    /// once, in its own words, as PagedSpaceRoot's swatch has them (Worn
    /// drew nothing in a picture made at once).
    private func doorsPicture(_ index: Int, browser: Browser) -> (image: CGImage, scale: CGFloat)? {
        guard order.indices.contains(index) else { return nil }
        let id = order[index]
        let mail = id == Space.mailID
        var row: Parked?
        if !mail {
            if id == browser.spaceID {
                row = Parked(tabs: browser.tabs, active: browser.activeID, pairs: browser.pairs)
            } else {
                if browser.parked[id] == nil { browser.parked[id] = browser.loadRow(id) }
                row = browser.parked[id]
            }
        }
        let front = row.flatMap { row in row.tabs.first { $0.id == row.active } }
        let paired = row.map { row in row.pairs.contains { $0.first == row.active || $0.second == row.active } } ?? false
        let window = browser.column?.window
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let prefs = browser.prefs
        // Edge to edge, the space's look the column wears (SpaceWash.grounded).
        let tone: Tone? = paint(index, browser).map { Tone($0.color, lifted: true, glass: $0.glass) }
            ?? (prefs.backdrop == .none && !prefs.edgeBackdrop ? nil : Tone(prefs.swatch.color(dark: dark, custom: prefs.backdropColor), lifted: true, glass: prefs.wearsGlass))
        let renderer = ImageRenderer(content: PagedDoors(browser: browser, mail: mail, tab: front, paired: paired)
            .modifier(SidebarTypography())
            .toned(tone)
            .frame(width: band.width, height: Metrics.strip)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = window?.backingScaleFactor ?? 2
        renderer.isOpaque = false
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        return image.map { ($0, renderer.scale) }
    }

    // MARK: - pages made ahead

    /// The pages of the spaces either side of the one on screen, made while
    /// the window has nothing else to do, so that a key, a click on the
    /// foot's dots or two fingers find them made: made at the switch, each
    /// was 30 to 100 ms of the main thread before the row could set off, or
    /// a stall in the first move of two fingers (feedback, 2026-10-09). A
    /// space's page is made again once what it shows changes (`key`), the
    /// space left after tabs were opened in it among them, so this runs
    /// after every switch has landed. One page a turn of the run loop, and
    /// none while anything happens in the window.
    func prepare(_ browser: Browser, only: UUID? = nil) {
        if ColumnKit.on { return prepareLive(browser, only: only) }
        guard !active, Self.allowed(browser), let column = browser.column, let window = column.window,
              !(browser.prefs.sideShut && browser.sideCard), let band = column.spaceBand(browser), band.width > 20, band.height > 20 else { return }
        let order = browser.turnOrder.map(\.id)
        guard let here = order.firstIndex(of: browser.spaceID) else { return }
        var wanted: [UUID]
        if let only {
            wanted = order.contains(only) && only != browser.spaceID ? [only] : []
        } else {
            // The next first, the one keys and fingers go to most, then the
            // one before; round the ends, as ⌃⇥ does (stepSpace).
            wanted = [1, -1].map { order[(here + $0 + order.count) % order.count] }.filter { $0 != browser.spaceID }
        }
        wanted.removeAll { $0 == Space.mailID }
        guard !wanted.isEmpty else { return }
        let travelling = browser.tabs.filter(browser.travels)
        for id in wanted {
            guard let index = order.firstIndex(of: id) else { continue }
            if browser.parked[id] == nil { browser.parked[id] = browser.loadRow(id) }
            let row = browser.parked[id].map { browser.withShared($0, in: id) }
            let rows = Int((band.height / (SideBar.row + SideBar.gap)).rounded(.up)) + 1
            let paint: SpaceWash.Paint? = {
                guard let space = browser.spaces.first(where: { $0.id == order[index] }) else { return nil }
                return SpaceWash.worn(space.paint ?? SpacePaint(browser.prefs), prefs: browser.prefs)
            }()
            let key = Self.key(id, row: row, travelling: travelling, rows: rows, paint: paint,
                               size: CGSize(width: band.width, height: band.height), floating: false, shared: false, browser: browser)
            if made[id]?.key == key, madeIn === window { continue }
            let started = CACurrentMediaTime()
            let made = page(id, row: row, travelling: travelling, paint: paint, band: band, floating: false, shared: false, browser: browser)
            // Laid out where it will be shown, in the window but out of
            // sight, so its first frame there draws what is laid already.
            Self.lay(made.host, band: band, top: browser.menuDown, in: column)
            Self.madeAhead += 1
            Self.aheadMs = (CACurrentMediaTime() - started) * 1000
            // One a turn: the next, if any, once the window is still again.
            if only == nil { prepareSoon(browser, after: 0.05) }
            return
        }
        // The pages made: the column's rows of the spaces not yet visited
        // next, their rows read now, once each (SideBar.rowPages).
        guard only == nil else { return }
        let unseen = browser.spaces.map(\.id).filter { $0 != browser.spaceID && !seeded.contains($0) }.prefix(4)
        guard !unseen.isEmpty else { return }
        for id in unseen where browser.parked[id] == nil { browser.parked[id] = browser.loadRow(id) }
        seeded.formUnion(unseen)
        NotificationCenter.default.post(name: Self.seedRows, object: browser)
    }

    /// The AppKit column's pages of the spaces either side laid ahead,
    /// hidden, one a turn, while the window is still.
    private func prepareLive(_ browser: Browser, only: UUID?) {
        guard !active, Self.allowed(browser), let pages = ColumnPages.of(browser) else { return }
        let order = browser.turnOrder.map(\.id)
        guard let here = order.firstIndex(of: browser.spaceID) else { return }
        var wanted = only.map { [$0] } ?? [1, -1].map { order[(here + $0 + order.count) % order.count] }
        wanted.removeAll { $0 == browser.spaceID || $0 == Space.mailID }
        let travelling = browser.tabs.filter(browser.travels)
        for id in wanted {
            if browser.parked[id] == nil { browser.parked[id] = browser.loadRow(id) }
            guard let row = browser.parked[id].map({ browser.withShared($0, in: id) }) else { continue }
            let started = CACurrentMediaTime()
            let direct = Self.movesPlate(browser, toward: order.firstIndex(of: id), load: false)
            let gesture = Self.movesPlate(browser, toward: nil, load: false)
            // The column's own page always: the switch adopts it whether
            // the row slides live or pictured, or it makes the space's rows
            // in the switch's pass. A route that carries the plate also
            // gets its pictured page. One a quiet turn.
            let native = pages.ready(id, row: row, travelling: travelling)
            let pictured = !native && (direct != false || gesture != false)
                && preparePlate(browser, id: id, row: row, travelling: travelling)
            guard native || pictured else { continue }
            Self.madeAhead += 1
            Self.aheadMs = (CACurrentMediaTime() - started) * 1000
            if only == nil { prepareSoon(browser, after: 0.05) }
            return
        }
    }

    /// A pictured page for a plate-changing route. Its band, paint and
    /// plate flag match build/page, including the page cache identity.
    private func preparePlate(_ browser: Browser, id: UUID, row: Parked, travelling: [Tab]) -> Bool {
        guard let column = browser.column, let window = column.window,
              !(browser.prefs.sideShut && browser.sideCard),
              let raw = column.spaceBand(browser), raw.width > 20, raw.height > 20,
              let space = browser.spaces.first(where: { $0.id == id }) else { return false }
        let band = Self.plateBand(raw, top: browser.menuDown)
        let paint = SpaceWash.grounded(space.paint, in: browser)
        let sign = Self.sign(row, travelling: travelling)
        let key = pageKey(id, row: row, travelling: travelling, paint: paint, band: band, floating: false, shared: false,
                          plate: true, browser: browser)
        if let snap = snaps[id], snap.key == key, snap.sign == sign { return false }
        let made = page(id, row: row, travelling: travelling, paint: paint, band: band,
                        floating: false, shared: false, plate: true, browser: browser)
        // Shown in the row, a page's host had its rows made and drawn in
        // the switch's own pass. Drawn out of sight here instead, a turn
        // later pictured, and then let go: kept, even out of the window,
        // its rows watched the browser and drew again in every switch (11
        // of them). Made again only if its picture no longer says what its
        // rows do.
        guard made.kept, madeIn === window, made.host.superview != nil, !made.host.isHidden else {
            Self.lay(made.host, band: band, top: browser.menuDown, in: column)
            made.host.isHidden = false
            return true
        }
        let image = Self.snapshot(made.host)
        forget(id)
        guard let image, let key else { return false }
        snaps[id] = (key, image, sign)
        return true
    }

    /// Pictures of plate-carrying pages made ahead (`preparePlate`), with
    /// what the page showed (`pageKey`) and what its rows said then.
    private var snaps: [UUID: (key: String, image: CGImage, sign: Int)] = [:]

    /// What a page's rows say that its key leaves out: titles.
    private static func sign(_ row: Parked?, travelling: [Tab]) -> Int {
        var hasher = Hasher()
        for tab in (row?.tabs ?? []) + travelling {
            hasher.combine(tab.id)
            hasher.combine(tab.label)
        }
        return hasher.finalize()
    }

    private static func snapshot(_ host: NSView) -> CGImage? {
        guard let layer = host.layer, let window = host.window else { return nil }
        let scale = window.backingScaleFactor
        let size = host.bounds.size
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: window.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // As ColumnView.pictureAll: turned over, y down as the host lays it.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        Bench.render(layer, in: context)
        return context.makeImage()
    }

    /// Spaces whose rows the column was asked to make ahead.
    private var seeded: Set<UUID> = []
    /// Asks the column to make the rows of spaces not yet visited.
    static let seedRows = Notification.Name("yab.space.seedRows")

    // MARK: - the space on screen, pictured ahead

    /// The column's band as last pictured, for what, and when. Pictured at
    /// the switch it was 8 to 17 ms of the main thread before the row could
    /// set off; pictured once the window is still, a switch finds it made,
    /// unless the column has drawn anything since (`touched`).
    private var pictured: (key: String, taken: (image: CGImage?, dropped: Bool, beside: CGImage?), at: CFTimeInterval)?
    /// The column drew something since its band was pictured: a row, a pin,
    /// the plate or the name, said from their bodies.
    private static var stale = true
    static func touched(pager: Bool = false) {
        // The pager's own pages drawing say nothing of the column's band;
        // their pictures are checked by what their rows say (`sign`).
        if pager { return }
        guard !stale else { return }
        stale = true
        // Pictured again once the window is still.
        if let browser = shared.lastBrowser, !shared.active { shared.prepareSoon(browser, after: 0.6) }
    }
    /// The window the pages are made ahead for.
    private weak var lastBrowser: Browser?

    private func picture(_ column: ColumnView, band: CGRect, card: CGRect?, own: Bool = false, browser: Browser) -> (image: CGImage?, dropped: Bool, beside: CGImage?) {
        let plate = SidePlate.extensionPlate(in: browser, space: browser.spaceID, tab: browser.active, shown: browser.sidePlated)
        let key = "\(ObjectIdentifier(browser)) \(browser.spaceID) \(plate) \(band) \(card.map { "\($0)" } ?? "-") \(own) \(column.window?.backingScaleFactor ?? 0)"
        if let pictured, pictured.key == key, !Self.stale, pictured.taken.image != nil {
            Self.pictureKept += 1
            return pictured.taken
        }
        let taken = column.picture(band, card: card, own: own)
        pictured = (key, taken, CACurrentMediaTime())
        Self.stale = false
        return taken
    }

    /// The band pictured now, if it has drawn since, ahead of a switch.
    private func pictureAhead(_ browser: Browser) {
        guard !active, let column = browser.column, !(browser.prefs.sideShut && browser.sideCard),
              let band = column.spaceBand(browser), band.width > 20, band.height > 20 else { return }
        // Only a route that carries the plate wants a picture with the
        // AppKit column. Missing rows are restored by prepare/setup, never
        // by this check; a later quiet turn can picture them.
        let movingPlate = Self.movesPlate(browser, toward: nil)
        if ColumnKit.on, movingPlate != true { return }
        let picturedBand = movingPlate == true ? Self.plateBand(band, top: browser.menuDown) : band
        _ = picture(column, band: picturedBand, card: nil, own: Self.ownGround(browser), browser: browser)
    }

    /// Switches that found the band pictured ahead, for the bench.
    private(set) static var pictureKept = 0

    /// Pages made ahead, and how long the last took, for the bench.
    private(set) static var madeAhead = 0
    private(set) static var aheadMs = 0.0

    /// `host` laid out at the size the stage will give it, and parked.
    private static func lay(_ host: NSView, band: CGRect, top: CGFloat, in column: NSView) {
        host.frame = CGRect(x: 0, y: 0, width: band.width, height: column.bounds.height - top)
        park(host, in: column)
        host.layoutSubtreeIfNeeded()
    }

    /// A kept page between switches: in the column's window, far out of
    /// sight to its left, rather than out of the window. Taken out of it
    /// and put back, a page's host was laid out whole again in the frame
    /// it came back in, 10 to 17 ms of the main thread before the row
    /// could set off; moved within the window at its size, it is not.
    private static func park(_ host: NSView, in column: NSView) {
        host.frame.origin = CGPoint(x: -20_000, y: 0)
        // Hidden, so a change of color or a title meanwhile is not drawn
        // and committed for a page no one sees.
        host.isHidden = true
        column.addSubview(host, positioned: .below, relativeTo: nil)
    }

    /// A page no longer kept: out of the window, unless a stage shows it.
    private static func unpark(_ host: NSView) {
        if !(host.superview?.superview is PagerStage) { host.removeFromSuperview() }
    }

    private var aheadWork: DispatchWorkItem?

    /// `prepare` once the window has been still a moment: after a switch
    /// has landed, or the window came up.
    func prepareSoon(_ browser: Browser, after delay: TimeInterval = 0.4) {
        aheadWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak browser] in
            MainActor.assumeIsolated {
                guard let self, let browser else { return }
                // Something going on in the window: later.
                let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                // Nor while the column or the page is on its way somewhere
                // with no key or pointer behind it: ⌘S's slide, ⇧⌘S.
                if quiet < 0.25 || self.active || browser.folding || browser.turning {
                    return self.prepareSoon(browser, after: 0.3)
                }
                self.prepare(browser)
                self.pictureAhead(browser)
            }
        }
        lastBrowser = browser
        aheadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Pages made for spaces, kept once their row has gone down, by space,
    /// with what each showed (`key`), the latest last. A page is a host of
    /// its own with every row in it made, 30 to 100 ms of the main thread
    /// before the row could slide (feedback, 2026-10-09); its rows watch
    /// their own tabs, so a title or a mark that changed since is drawn
    /// as it is now. What its rows are, their order, folders and look
    /// changing makes it again.
    private var made: [UUID: (key: String, host: NSView)] = [:]
    private var madeOrder: [UUID] = []
    private static let kept = 6

    /// The window the kept pages were made in: one browser's at a time.
    private weak var madeIn: NSWindow?

    /// A page let go once pictured (`preparePlate`).
    private func forget(_ id: UUID) {
        guard let gone = made.removeValue(forKey: id) else { return }
        madeOrder.removeAll { $0 == id }
        gone.host.removeFromSuperview()
    }

    private func keep(_ host: NSView, key: String, for id: UUID, in window: NSWindow?) {
        if window !== madeIn {
            made.values.forEach { Self.unpark($0.host) }
            made = [:]
            madeOrder = []
            madeIn = window
        }
        if let old = made[id]?.host, old !== host { Self.unpark(old) }
        made[id] = (key, host)
        madeOrder.removeAll { $0 == id }
        madeOrder.append(id)
        while madeOrder.count > Self.kept {
            if let gone = made.removeValue(forKey: madeOrder.removeFirst()) { Self.unpark(gone.host) }
        }
    }

    /// What a space's page shows, as far as making it goes: its rows, in
    /// order, pinned, kept or filed, the folders open or shut, the one
    /// in front, and the band, the column and the color it is drawn for.
    private static func key(_ id: UUID, row: Parked?, travelling: [Tab], rows: Int, paint: SpaceWash.Paint?, size: CGSize,
                            floating: Bool, shared: Bool, browser: Browser) -> String {
        let folders = browser.folderBook
        var key = "\(ObjectIdentifier(browser).hashValue) \(id) \(rows) \(size) \(floating) \(shared) \(browser.prefs.sideWidth) \(browser.barShown(row, travelling: travelling)) \(browser.namesSpaces)"
        key += " \(NSApp.effectiveAppearance.name.rawValue) \(paint.map { "\($0)" } ?? "-") \(browser.prefs.glyph) \(browser.prefs.density)"
        key += " \(browser.prefs.backdrop) \(browser.prefs.wearsGlass)"
        key += " \(row?.active?.uuidString ?? "-") \(row?.pairs.map { "\($0.first)\($0.second)\($0.share)" } ?? [])"
        key += " \(SidePlate.extensionPlate(in: browser, space: id, tab: ((row?.tabs ?? []) + travelling).first { $0.id == row?.active }, shown: browser.sidePlated(row)))"
        key += " \(folders.open.sorted()) \(folders.whole.sorted()) \(folders.isShut(id, in: browser))"
        key += " \(folders.empties(in: id).map { "\($0.id)\($0.open)\($0.name)\($0.parent?.id.uuidString ?? "")" })"
        for tab in (row?.tabs ?? []) + travelling {
            key += "|\(tab.id) \(tab.pin ?? "") \(tab.kept) "
            if let nest = tab.nest { key += "\(nest.id)\(nest.open)\(nest.name)\(nest.parent?.id.uuidString ?? "")" }
        }
        return key
    }

    private func paint(_ index: Int, _ browser: Browser) -> SpaceWash.Paint? {
        let id = order[index]
        // Edge to edge, a card's spaces wear their own looks (SpaceWash.card).
        if id == Space.mailID { return SpaceWash.grounded(Space.mail.paint, in: browser) }
        guard let space = browser.spaces.first(where: { $0.id == id }) else { return nil }
        return SpaceWash.grounded(space.paint, in: browser)
    }

    /// The row where the fingers have it, now, nothing animated.
    private func set(_ x: CGFloat) {
        offset = x
        stage?.slide(x)
        live?.slideTo(x)
    }

    /// The row to `target` on the spring, from wherever it is drawn and as
    /// fast as `velocity` adds: a spring added to whatever is still
    /// landing, so a second key turns it without a jolt.
    private func animate(to target: CGFloat, velocity: CGFloat) {
        if let live {
            let from = offset
            offset = target
            let run = generation
            landings += 1
            live.land(from: from, to: target, velocity: velocity) { [weak self] in
                guard let self, self.generation == run else { return }
                self.landings -= 1
                if self.landings <= 0, !self.holding, self.pendingTarget == nil { self.finish() }
            }
            return
        }
        guard let stage else { return }
        let from = offset
        offset = target
        let run = generation
        landings += 1
        stage.land(from: from, to: target, velocity: velocity) { [weak self] in
            guard let self, self.generation == run else { return }
            self.landings -= 1
            if self.landings <= 0, !self.holding, self.pendingTarget == nil { self.finish() }
        }
    }

    /// The pages down and the column's own drawing back: it is the space
    /// they were showing, at rest.
    func finish() {
        generation += 1
        livePlateTab = nil
        landings = 0
        holding = false
        pendingTarget = nil
        if wash != nil {
            browser?.spaceWash.hide()
            wash = nil
        }
        if let live {
            self.live = nil
            livePages = []
            live.endSlide()
            if let browser {
                browser.column?.rehover()
                prepareSoon(browser)
            }
            return
        }
        // The pages kept parked in the window for the next switch.
        if let stage, let column = browser?.column {
            let kept = Set(made.values.map { ObjectIdentifier($0.host) })
            for host in stage.pages.values where kept.contains(ObjectIdentifier(host)) { Self.park(host, in: column) }
        }
        stage?.removeFromSuperview()
        stage = nil
        browser?.column?.cardFrosts.forEach { $0.group = nil }
        browser?.column?.maskSpace(nil)
        // What is under the pointer now lit in the same frame as the pages
        // go, as they drew it.
        browser?.column?.rehover()
        // Landed: the spaces either side of this one made ahead for the
        // next switch, once the window is still.
        if let browser { prepareSoon(browser) }
    }

    // MARK: - bench

    /// Why the pages wouldn't come up now, nil when they would: for the
    /// bench to say what a swipe that left the rows alone ran into.
    static func refusal(_ browser: Browser) -> String? {
        guard let column = browser.column else { return "no column" }
        if !browser.prefs.sidebar { return "tabs on top" }
        if browser.prefs.sideShut, !browser.sidePeek { return "column put away" }
        if place(browser, column) == .away { return "column not in a window" }
        if !(browser.prefs.usesSpaces || withMail(browser, toward: nil)) { return "no spaces" }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return "reduce motion" }
        if SpaceTurn.still { return "still" }
        if browser.turnOrder.count < 2 { return "one space" }
        if browser.rowsClip == nil { return "no rows clip" }
        if browser.spaceFloor == nil { return "no floor" }
        guard let band = column.spaceBand(browser) else { return "no band" }
        if band.width <= 20 || band.height <= 20 { return "band too small \(band)" }
        // A diagnostic must not restore rows or render a picture. Setup
        // validates the actual picture in raise before masking the column.
        if !browser.turnOrder.map(\.id).contains(browser.spaceID) { return "space not in order" }
        return nil
    }

    /// Where the row is drawn now, the spring's way included.
    var drawn: CGFloat { live?.drawnOffset ?? stage?.drawnOffset ?? 0 }

    /// When the latest landing spring began, on the render server's clock
    /// (CACurrentMediaTime): the commit that sent it. For the bench.
    var slideBegan: CFTimeInterval? { live?.slideBegan ?? stage?.slideBegan }

    /// How far the row is drawn from the space it set off from, in pages,
    /// the spring's way included; nil with no pages up. For the bench's
    /// films, the color judged against it (wash_matrix.py).
    var drawnPages: Double? {
        guard active, page > 0 else { return nil }
        return Double(abs(drawn) / page)
    }

    /// How much is drawn in the band's left and right halves now, as a
    /// share of their pixels that stand out from the half's ground: the
    /// space going and the one coming both there while the fingers hold.
    /// Nil with no pages up.
    var ink: [Double]? {
        guard let stage, let layer = stage.layer else { return nil }
        let band = stage.bandFrame
        let width = Int(band.width), height = Int(band.height)
        guard width > 2, height > 2,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.translateBy(x: 0, y: band.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -band.minX, y: -band.minY)
        Bench.render(layer, in: context)
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return [0, 1].map { half -> Double in
            let from = half * width / 2, to = from + width / 2
            var lights: [Int] = []
            lights.reserveCapacity((to - from) * height)
            for y in 0..<height {
                for x in from..<to {
                    let i = (y * width + x) * 4
                    lights.append(Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114 + Int(pixels[i + 3]) * 1000)
                }
            }
            let ground = lights.sorted()[lights.count / 2]
            let inked = lights.filter { abs($0 - ground) > 40_000 }.count
            return (Double(inked) / Double(max(1, lights.count)) * 10_000).rounded() / 10_000
        }
    }

    /// Where the row is drawn now and where it is going, for the bench.
    var state: [String: Any] {
        ["active": active, "holding": holding, "offset": Double(offset), "page": Double(page), "home": home,
         "drawn": Double(drawn), "pages": live != nil ? livePages.sorted() : stage.map { $0.pages.keys.sorted() } ?? [], "landings": landings,
         "live": live != nil,
         // How far down the band the row's window starts: the pins over it
         // standing still, and where they would.
         "held": Double(stage?.cut ?? 0), "under_pins": Double(underPins),
         // Pages made ahead (`prepare`), how long the last took, and the
         // spaces whose page is kept.
         "made_ahead": Self.madeAhead, "snaps": snaps.count, "hosts_in_window": made.values.filter { $0.host.window != nil }.count, "ahead_ms": (Self.aheadMs * 10).rounded() / 10, "kept_pages": made.count,
         // The live pages' row (ColumnKit) is the whole band.
         "row_window": stage.map { [$0.rowWindow.minX, $0.rowWindow.minY, $0.rowWindow.width, $0.rowWindow.height].map { Double($0) } }
            ?? (live != nil ? [band.minX, band.minY, band.width, band.height].map { Double($0) } : [])]
    }
}

/// A space's page in its own host: the column's look, its color's ink and
/// its type, as the column wears them (ColumnRoot).
struct PagedSpaceRoot: View {
    /// Not watched: a page is kept to be shown again (SpacePager.made), out
    /// of the window meanwhile, and drawn again on everything the browser
    /// said it would be work for nothing on screen.
    let browser: Browser
    /// Not watched either: every switch wears the next space's color into
    /// them, and every page kept was drawn again for it, unseen, then laid
    /// out whole when shown (10 ms of the turn). What of them a page shows
    /// is in its key (SpacePager.key): a change there makes it again.
    let prefs: Preferences
    let content: PagedSpace
    /// The space's own color, when it wears one: its ink is worked out
    /// from it, and a card's page is painted with it.
    var paint: SpaceWash.Paint? = nil
    /// The column is a card over the page: the page carries the ground the
    /// card paints under its rows (Column.ground), in its space's color.
    var floating = false
    /// Paints a ground at all: not when one is laid under the whole row.
    var grounded = true
    @Environment(\.colorScheme) private var scheme

    /// Its own space's glass, or the window's.
    private var glassActive: Bool {
        paint?.glass ?? prefs.wearsGlass
    }

    var body: some View {
        Worn(browser: browser, mode: prefs.backdrop, swatch: swatch, glassActive: glassActive) { tone in
            content.equatable()
                .modifier(SidebarTypography())
                .frame(width: prefs.sideWidth, alignment: .topLeading)
                // The host's height, from its top, whatever the rows add up
                // to: taller than the host, the page grew to them and the
                // host centered it, its pins and rows drawn half a band too
                // high, gone under the column's head while the row slid,
                // and dropping into place when it landed (the pins "jerk",
                // 2026-10-09).
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                // Where the pointer is on the page, from its top-left: what
                // is under it drawn lit, as the column will draw it.
                .coordinateSpace(.named(SlidePointer.space))
                .environment(\.slidePointer, SlidePointer.shared)
                // As a card over the page, in the words its see-through
                // ground keeps (Tone.card), as the column's own.
                // On the site's color, the words the live column wears (Tone.columnInk).
                .toned(own ? tone?.card(paint ?? tone.map { Column.paint($0, prefs: prefs) }) : tone == swatch ? tone : Tone.columnInk(tone))
                .background {
                    if grounded { PagedGround.fill(tone: tone, paint: paint, prefs: prefs, floating: own, scheme: scheme) }
                }
        }
    }

    /// On a ground of its own: a card over the page, or edge to edge the
    /// column docked too (Column.card).
    private var own: Bool { floating || (prefs.backdrop == .none && !prefs.edgeBackdrop) }

    private var swatch: Tone? {
        // Edge to edge the column wears its space's look, docked or out
        // over the page (Column.card).
        guard prefs.backdrop != .none || prefs.edgeBackdrop || paint != nil else { return nil }
        if let paint { return Tone(paint.color, lifted: true, glass: glassActive) }
        return Tone(prefs.swatch.color(dark: scheme == .dark, custom: prefs.backdropColor), lifted: true, glass: glassActive)
    }
}

/// A space's ground on its page: what the column paints under its rows
/// itself. With no backdrop, docked, the plain ground (SideBar); as a card
/// over the page, the backdrop's color, grain, gradient and frost
/// (Column.ground), in the space's own color when it wears one, edge to
/// edge too (SpaceWash.card); docked on a backdrop, nothing: the window's
/// backdrop shows through.
struct PagedGround: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// The card's paint when the row came up: the stage lays its color and
    /// its frost itself (PagerStage.ground), this view nothing for it.
    var paint: SpaceWash.Paint?
    @Environment(\.colorScheme) private var scheme

    private var glassActive: Bool { prefs.wearsGlass }

    /// The card's ground laid once under the whole row while its spaces
    /// slide, turning with the card around it and the window.
    var body: some View {
        Worn(browser: browser, mode: prefs.backdrop, swatch: swatch, glassActive: glassActive) { tone in
            Group {
                if paint != nil {
                    // The frost, the page under it blurred and veiled as
                    // CardGround lays it, is the stage's own (PagerStage.ground).
                    Color.clear
                } else if let tone {
                    CardGround(paint: Column.paint(tone, prefs: prefs)).environment(browser)
                } else {
                    Palette.ground
                }
            }
            .frame(width: prefs.sideWidth)
            .frame(maxHeight: .infinity)
        }
    }

    private var swatch: Tone? {
        guard prefs.backdrop != .none || prefs.edgeBackdrop else { return nil }
        return Tone(prefs.swatch.color(dark: scheme == .dark, custom: prefs.backdropColor), lifted: true, glass: glassActive)
    }

    @ViewBuilder
    static func fill(tone: Tone?, paint: SpaceWash.Paint?, prefs: Preferences, floating: Bool, scheme: ColorScheme) -> some View {
        if tone == nil {
            Palette.ground
        } else if floating, let tone {
            if let paint {
                BackdropFill(color: Color(nsColor: paint.color), grain: paint.grain, transparency: paint.transparency,
                             colors: paint.colors.map { Color(nsColor: $0) }, card: true)
            } else {
                // As the card paints it now (Column).
                BackdropFill(color: tone.color, grain: prefs.grain, transparency: prefs.wornTransparency(dark: scheme == .dark),
                             colors: prefs.backdrop == .color ? SpacePaint(prefs).gradient(dark: scheme == .dark) : [], card: true)
            }
        }
    }
}

/// What is laid over the column while its spaces slide: a window onto the
/// row of pages, the band of the column a space has of its own, and the
/// row in it, moved by one transform. Takes no clicks.
final class PagerStage: NSView {
    /// The window onto the row, its pages placed from its top as the
    /// column's are.
    private final class Clip: NSView {
        override var isFlipped: Bool { true }
    }
    private let clip = Clip()
    /// The band, in the column's space.
    var bandFrame: CGRect { band }
    /// Where the window onto the row is, in the same space: the band, or
    /// what is under the pins while they stand still. For the bench.
    var rowWindow: CGRect { clip.frame }
    /// The pages by their place in the spaces' order.
    private(set) var pages: [Int: NSView] = [:]
    private let band: CGRect
    /// Where the column's top is, in the column's space, and how tall it
    /// is: its pages are laid from there, as its rows are.
    private let top: CGFloat
    private let height: CGFloat
    private let rim: CGFloat
    /// How far down the band the window onto the row starts: over it the
    /// pins stand still, the column's own (`hold`).
    private(set) var cut: CGFloat = 0

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// How much of a card's edges the row leaves alone: its hairline.
    static let rim: CGFloat = 1

    init(band: CGRect, picture: CGImage, beside: CGImage? = nil, scale: CGFloat, top: CGFloat = 0, height: CGFloat = 0, rim: CGFloat = 0) {
        self.band = band
        self.top = top
        self.height = height
        self.rim = rim
        super.init(frame: .zero)
        wantsLayer = true
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.frame = band.insetBy(dx: rim, dy: 0)
        // Its pages placed as before, from the band's own left.
        clip.bounds.origin.x = rim
        addSubview(clip)

        // The space on screen, as it was drawn.
        let here = NSView(frame: CGRect(origin: .zero, size: band.size))
        here.wantsLayer = true
        here.layer?.contents = picture
        here.layer?.contentsScale = scale
        here.layer?.contentsGravity = .resize
        clip.addSubview(here)

        // What the head and foot draw into the band, their shadows, still
        // over the row as they are over the column (ColumnView.picture). In
        // a window of its own, cut with the row's: where the pins stand
        // still, the column draws its head's shadow itself.
        if let beside {
            shadows.wantsLayer = true
            shadows.layer?.masksToBounds = true
            shadows.frame = band
            let still = NSView(frame: CGRect(origin: .zero, size: band.size))
            still.wantsLayer = true
            still.layer?.contents = beside
            still.layer?.contentsScale = scale
            still.layer?.contentsGravity = .resize
            shadows.addSubview(still)
            addSubview(shadows, positioned: .above, relativeTo: clip)
        }
    }

    private let shadows = Clip()

    /// The head's doors, a row of their own over the band, on the way to
    /// or from Mail: back, forward and reload in a space, New Mail in Mail,
    /// each going with its page. The lights beside them stay.
    private let doors = Clip()
    private var doorsRect: CGRect = .zero
    private var doorPages: [Int: CALayer] = [:]

    /// The doors' row up over `rect` (the column's space), the space on
    /// screen's as it was drawn: a window onto it, as the pages have, and
    /// in it a view hosting a layer of its own, the pictures plain layers
    /// in that. As views of AppKit's, or layers in a view's layer, the
    /// pictures laid past the row's edge were drawn again with nothing,
    /// or dropped, before they came into sight.
    ///
    /// `ground`: docked edge to edge the column's own ground, left out of
    /// the doors' pictures (as of the band's) and laid under them, whole
    /// and unfaded, turning with the window. Mail's doors are drawn on
    /// nothing, and with the column masked there the head went the
    /// window's plain gray until the row landed.
    func doorsRow(_ rect: CGRect, picture: CGImage, scale: CGFloat, ground: SpaceWash.Paint? = nil, wash: SpaceWash? = nil) {
        doorsRect = rect
        if let ground {
            doorsGround.wantsLayer = true
            doorsGround.layer?.masksToBounds = true
            doorsGround.frame = rect
            addSubview(doorsGround, positioned: .below, relativeTo: nil)
            // Laid as the band's ground is, from the column's top, so its
            // grain and drawings meet the band's with no step.
            let frame = CGRect(x: band.minX - rect.minX, y: top - rect.minY, width: band.width, height: height)
            if ground.transparency > 0 {
                let frost = CardFrostView(frame: frame)
                frost.wear(ground.color, colors: ground.colors, transparency: ground.transparency)
                frost.group = Self.frostGroup
                doorsGround.addSubview(frost)
            }
            let color = CardGroundView(frame: frame)
            color.bind(to: wash)
            color.given(ground)
            doorsGround.addSubview(color)
        }
        doors.wantsLayer = true
        doors.layer?.masksToBounds = true
        doors.frame = rect
        addSubview(doors, positioned: .above, relativeTo: nil)
        let row = CALayer()
        doorsRowView.layer = row
        doorsRowView.wantsLayer = true
        doorsRowView.frame = CGRect(origin: .zero, size: rect.size)
        doors.addSubview(doorsRowView)
        row.addSublayer(Self.picture(picture, scale: scale, frame: CGRect(origin: .zero, size: rect.size)))
        // Gone out by the lights rather than cut against them: the doors
        // fade over their row's first points, the lights left alone.
        let fade = CAGradientLayer()
        fade.frame = CGRect(origin: .zero, size: rect.size)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: min(1, Self.doorsFade / max(rect.width, 1)), y: 0.5)
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        doors.layer?.mask = fade
    }

    private let doorsRowView = NSView()
    private let doorsGround = Clip()

    private static func picture(_ image: CGImage, scale: CGFloat, frame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsScale = scale
        layer.contentsGravity = .resize
        layer.frame = frame
        return layer
    }

    /// How far in from their row's edge by the lights the doors fade.
    static let doorsFade: CGFloat = 28

    var hasDoors: Bool { doors.superview != nil }
    var doorsFrame: CGRect { doorsRect }
    /// The doors go with the row only toward Mail or from it: between two
    /// spaces, whose doors are the same, the column's own stand still.
    private(set) var doorsGo = true

    func doors(go: Bool) {
        guard hasDoors, go != doorsGo else { return }
        doorsGo = go
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        doors.isHidden = !go
        doorsGround.isHidden = !go
        doorsRowView.layer?.removeAllAnimations()
        doorsRowView.layer?.sublayerTransform = go ? (clip.layer?.presentation() ?? clip.layer)?.sublayerTransform ?? CATransform3DIdentity : CATransform3DIdentity
        CATransaction.commit()
    }

    /// A space's doors, `place` pages from the one on screen, drawn from
    /// the column's top and edge as the head draws them.
    func adoptDoors(_ picture: CGImage, scale: CGFloat, at place: Int, index: Int) {
        guard hasDoors, doorPages[index] == nil, let row = doorsRowView.layer else { return }
        // The row's layer is y up: the strip from the column's top.
        let y = row.bounds.height - (top - doorsRect.minY) - Metrics.strip
        let layer = Self.picture(picture, scale: scale,
                                 frame: CGRect(x: CGFloat(place) * band.width - (doorsRect.minX - band.minX), y: y,
                                               width: band.width, height: Metrics.strip))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        row.addSublayer(layer)
        CATransaction.commit()
        doorPages[index] = layer
    }

    /// The windows that slide: the row, and the doors' when they go too.
    private var sliding: [CALayer] { [clip.layer, hasDoors && doorsGo ? doorsRowView.layer : nil].compactMap { $0 } }

    /// The window onto the row from `cut` points down the band, the pages
    /// where they were: over it, the pins every space it goes past shows
    /// stand still, the column's own drawing of them let through
    /// (SpacePager.hold). Zero gives the row the whole band again.
    func hold(_ cut: CGFloat) {
        guard cut != self.cut else { return }
        self.cut = cut
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let windows: [(view: NSView, edge: CGFloat)] = [(clip, rim), (groundsView, rim), (shadows, 0)]
        for (view, edge) in windows where view === clip || view.superview != nil {
            view.frame = CGRect(x: band.minX + edge, y: band.minY + cut, width: band.width - 2 * edge, height: band.height - cut)
            view.bounds.origin = CGPoint(x: edge, y: cut)
        }
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { nil }

    /// A card's ground, still under the row, laid once: its color turns
    /// with the card around it, not page by page. `paint` is laid in a
    /// CardGroundView of its own, over `view`: one in a new SwiftUI host is
    /// made with that host's first pass, after the switch has already
    /// turned the grounds there were, and it stayed the old color until the
    /// pages came down. Its frost is laid here too, in the card's own
    /// backdrop group (`frostGroup`): blurring what the card's own blur
    /// does, the page under the card, not the card's head and foot beside
    /// the band, whose light came into the band's top and bottom.
    func ground<Content: View>(_ view: Content, paint: SpaceWash.Paint?, wash: SpaceWash? = nil) {
        guard groundsView.superview == nil else { return }
        groundsView.wantsLayer = true
        groundsView.layer?.masksToBounds = true
        groundsView.frame = clip.frame
        groundsView.bounds.origin.x = clip.bounds.origin.x
        addSubview(groundsView, positioned: .below, relativeTo: clip)
        let frame = CGRect(x: 0, y: top - band.minY, width: band.width, height: height)
        // With a paint the SwiftUI ground draws nothing (PagedGround's
        // Color.clear), yet its host watched the browser and was laid out
        // again through the switch's pass: made only for a tone.
        if paint == nil {
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            host.frame = frame
            groundsView.addSubview(host)
            host.layoutSubtreeIfNeeded()
        }
        if let paint, paint.transparency > 0 {
            // Laid here rather than by SwiftUI (PagedGround), whose view of
            // it isn't made until the host is in a window.
            let frost = CardFrostView(frame: frame)
            frost.wear(paint.color, colors: paint.colors, transparency: paint.transparency)
            frost.group = Self.frostGroup
            groundsView.addSubview(frost)
        }
        if let paint {
            let color = CardGroundView(frame: frame)
            color.bind(to: wash)
            color.given(paint)
            groundsView.addSubview(color)
        }
    }

    /// The backdrop group of a card's blur and its row's while its spaces
    /// slide.
    static let frostGroup = "yab.card.frost"

    private final class Grounds: NSView {
        override var isFlipped: Bool { true }
    }
    private let groundsView = Grounds()

    /// A space's page, `at` pages from the one on screen, drawn from the
    /// column's top as the column draws its rows.
    @discardableResult
    func add<Content: View>(page view: Content, at place: Int, index: Int) -> NSView {
        let host = Self.page(view)
        adopt(host, at: place, index: index)
        return host
    }

    /// A page's host, not yet placed.
    static func page<Content: View>(_ view: Content) -> NSView {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        // Prepared pages are first parked at the column's window top.
        // Its title-bar safe area would add 32 points to their snapshots;
        // adopted live hosts, below the band, have no such inset.
        host.safeAreaRegions = []
        return host
    }

    /// A page made before (SpacePager.made), or just now, placed `place`
    /// pages from the one on screen.
    func adopt(_ host: NSView, at place: Int, index: Int, kept: Bool = false) {
        let height = self.height > 0 ? self.height : max(band.maxY, (superview?.bounds.height ?? band.maxY)) - top
        let size = host.frame.size
        host.frame = CGRect(x: CGFloat(place) * band.width, y: top - band.minY, width: band.width, height: height)
        host.isHidden = false
        clip.addSubview(host)
        // Laid out now, so its first frame on screen is whole; a kept page
        // at the size it was laid out at already is (9 ms a switch asked
        // again).
        if !kept || host.frame.size != size { host.layoutSubtreeIfNeeded() }
        pages[index] = host
    }

    /// A page made ahead as a picture (SpacePager.snaps): nothing of
    /// SwiftUI to make or lay out at the switch.
    func adopt(picture image: CGImage, scale: CGFloat, at place: Int, index: Int) {
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let view = NSView(frame: CGRect(x: CGFloat(place) * band.width, y: top - band.minY, width: size.width, height: size.height))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsScale = scale
        view.layer?.contentsGravity = .resize
        clip.addSubview(view)
        pages[index] = view
    }

    /// Slid to `x`, at once.
    func slide(_ x: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in sliding { layer.sublayerTransform = CATransform3DMakeTranslation(x, 0, 0) }
        CATransaction.commit()
    }

    /// When the latest landing spring began, as its commit stamped it.
    var slideBegan: CFTimeInterval? {
        guard let layer = clip.layer else { return nil }
        return (layer.animationKeys() ?? []).filter { $0.hasPrefix("pager.") }
            .compactMap { layer.animation(forKey: $0)?.beginTime }.filter { $0 > 0 }.max()
    }

    /// Where the row is drawn, the spring's way included.
    var drawnOffset: CGFloat {
        let layer = clip.layer?.presentation() ?? clip.layer
        return layer?.sublayerTransform.m41 ?? 0
    }

    /// From `from` to `to` on the spring, added to whatever still lands.
    func land(from: CGFloat, to: CGFloat, velocity: CGFloat, done: @escaping () -> Void) {
        guard let layer = clip.layer else { return done() }
        let delta = from - to
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Set first: it covers only what is added after it.
        CATransaction.setCompletionBlock(done)
        for each in sliding {
            each.sublayerTransform = CATransform3DMakeTranslation(to, 0, 0)
            guard abs(delta) > 0.25 else { continue }
            let spring = SpacePaging.animation(keyPath: "sublayerTransform.translation.x", from: delta, to: 0,
                                               velocity: -velocity / delta)
            spring.isAdditive = true
            // The row's own are named for the bench (slideBegan); the
            // doors' go with them, one spring the same.
            each.add(spring, forKey: (each === layer ? "pager." : "doors.") + UUID().uuidString)
        }
        CATransaction.commit()
    }
}

extension SpacePaging {
    /// The landing spring for Core Animation, from `from` to `to`, starting
    /// at `velocity` of the whole way a second.
    @MainActor static func animation(keyPath: String, from: Any, to: Any, velocity: CGFloat = 0) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = 1
        spring.stiffness = CGFloat(stiffness)
        spring.damping = CGFloat(friction)
        spring.initialVelocity = velocity.isFinite ? velocity : 0
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        return spring
    }
}

/// The pointer over the column as a change of space begins, for the pages
/// that slide in to be drawn as the column will stand under it: the
/// plate's doors in with it in the column, the row under it lit. Left
/// out, a page came in at rest and the column's own hover popped in only
/// when the row landed and the pages went (feedback, 2026-10-13). A page
/// takes no pointer of its own: nothing on it hears the mouse.
@MainActor
final class SlidePointer: ObservableObject {
    static let shared = SlidePointer()
    /// The named space a page measures from: its top-left as it lands.
    nonisolated static let space = "pagedSpace"

    /// The pointer is in the column (SideBar's `near`).
    @Published private(set) var near = false
    /// Where it is on a page, from the page's top-left, while in the column.
    @Published private(set) var point: CGPoint?

    /// Read from where the pointer is now, `band` and `top` where the
    /// pages stand in the column's flipped space.
    func take(_ column: NSView, band: CGRect, top: CGFloat) {
        var at: CGPoint?
        if let window = column.window {
            // Use the same window-local pointer the live column uses for
            // rehover. A floating column can be moving under the hand;
            // the global event position briefly left its incoming page
            // unpointed, then showed the grid only after the row landed.
            let local = column.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let y = column.isFlipped ? local.y : column.bounds.height - local.y
            if local.x >= band.minX, local.x < band.maxX, y >= 0, y < column.bounds.height {
                at = CGPoint(x: local.x - band.minX, y: y - top)
            }
        }
        if near != (at != nil) { near = at != nil }
        if point != at { point = at }
    }
}

private struct SlidePointerKey: EnvironmentKey {
    static let defaultValue: SlidePointer? = nil
}

extension EnvironmentValues {
    /// Set on a space's page (PagedSpaceRoot): the pointer it is drawn
    /// under. Nil in the column itself, whose views hear their own.
    var slidePointer: SlidePointer? {
        get { self[SlidePointerKey.self] }
        set { self[SlidePointerKey.self] = newValue }
    }
}

/// On a space's page, `hovering` as it will be when the page lands: true
/// while the pointer is over this view. Nothing in the column itself.
struct SlidePointed: ViewModifier {
    @Binding var hovering: Bool
    @Environment(\.slidePointer) private var pointer

    func body(content: Content) -> some View {
        if let pointer {
            content.modifier(Watch(pointer: pointer, hovering: $hovering))
        } else {
            content
        }
    }

    private struct Watch: ViewModifier {
        @ObservedObject var pointer: SlidePointer
        @Binding var hovering: Bool
        @State private var frame: CGRect = .null

        func body(content: Content) -> some View {
            content
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(SlidePointer.space)) }) { frame in
                    self.frame = frame
                    settle()
                }
                .onChange(of: pointer.point, initial: true) { _, _ in settle() }
        }

        private func settle() {
            let over = pointer.point.map { frame.contains($0) } ?? false
            guard hovering != over else { return }
            // Drawn so from its first frame, not faded in as a hover is.
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { hovering = over }
        }
    }
}
