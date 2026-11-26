import AppKit
import Combine
import QuartzCore
import SwiftUI

// The column's rows on AppKit and Core Animation (docs/column-appkit.md).
// Each space's rows are a page of their own (ColumnPage), kept alive while
// the space is away, five at most: a change of space shows a page already
// laid rather than SwiftUI laying out and drawing every kept row of the
// column's one graph again (45 ms of a 93 ms switch, renderer-2). A page's
// rows are cells, only as many as are in sight, each the row SideBar draws
// (SideRow, NestRow...) in a small host of its own: a tab's title, mark or
// loading changing redraws its own row and nothing else.

/// Where SideBar's rows were: the pages, laid in SideBar's own place for
/// them so SwiftUI keeps its order (the head, the pins, the name and the
/// foot drawn over them, as over its own rows).
struct ColumnPagesHost: NSViewRepresentable {
    let browser: Browser
    /// How far down the rows rest, under the lights, the plate, the pins
    /// and the name; and the foot's room at the bottom (SideBar's `lead`
    /// and `footRoom`).
    let lead: CGFloat
    let footRoom: CGFloat
    /// The rows' ends dimmed and blurred (ColumnFade, ColumnBlur): where the
    /// top's starts, and whether there is a foot to go under.
    let top: CGFloat
    let foot: Bool
    let grain: Double

    func makeNSView(context: Context) -> ColumnPages { ColumnPages(browser: browser) }

    func updateNSView(_ view: ColumnPages, context: Context) {
        let env = context.environment
        view.given(ColumnPages.Frame(lead: lead, footRoom: footRoom, top: top, foot: foot),
                   look: ColumnPages.Look(tone: env.tone, scheme: env.colorScheme, titleSize: env.tabTitleSize, grain: grain))
    }

    /// As big as it is given: never asked to measure its pages.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ColumnPages, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleNSView(_ view: ColumnPages, coordinator: ()) { view.stop() }
}

/// The pages of the spaces visited lately, the one on screen shown.
final class ColumnPages: NSView {
    /// What a row is drawn in: the column's color's words, its light or
    /// dark, its type.
    struct Look: Equatable {
        var tone: Tone?
        var scheme: ColorScheme
        var titleSize: CGFloat
        var grain: Double
    }

    struct Frame: Equatable {
        var lead: CGFloat
        var footRoom: CGFloat
        var top: CGFloat
        var foot: Bool
    }

    private(set) weak var browser: Browser?
    private(set) var pages: [UUID: ColumnPage] = [:]
    /// The spaces, the latest last, the one on screen among them.
    private var order: [UUID] = []
    private var frame_ = Frame(lead: 0, footRoom: 0, top: 0, foot: true)
    var carryLook: Look { browser.flatMap { browser in browser.spaces.first { $0.id == browser.spaceID } }.map { look(of: $0) } ?? look }
    private var look = Look(tone: nil, scheme: .light, titleSize: 13, grain: 0)
    private var watching: [AnyCancellable] = []
    private var pending = false
    private var observer: CFRunLoopObserver?
    /// As many as are kept: past it the one left longest ago goes.
    static let most = 5

    override var isFlipped: Bool { true }

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        // Anything the rows are drawn from: laid again once, before the
        // frame is committed, however many things said so.
        watching = [
            browser.objectWillChange.sink { [weak self] _ in self?.soon() },
            Folders.shared.objectWillChange.sink { [weak self] _ in self?.soon() },
            browser.prefs.objectWillChange.sink { [weak self] _ in self?.soon() },
            Extensions.listsChanged.sink { [weak self] _ in self?.soon() },
            // The put-away column out over the page or back past the edge:
            // SwiftUI moves it (Column's offset) and nothing in it is laid
            // again, so where its rows are is said anew once that move is in.
            browser.peek.$out.dropFirst().removeDuplicates().sink { [weak self] _ in self?.movedSoon() },
            // The column to the window's other side: moved, every row laid
            // as it was, and their places went on saying the left (tear-off's
            // rows, Clear's dust, the bench's rowframes).
            browser.prefs.changes(\.sideFlank).dropFirst().removeDuplicates().sink { [weak self] _ in self?.movedOnceThere() },
        ]
        ColumnPages.live.add(self)
        ColumnPages.hostsMade += 1
    }

    /// Made, for the bench: one a window, unless SwiftUI makes the column
    /// anew (bench columnkit).
    static var hostsMade = 0

    required init?(coder: NSCoder) { nil }

    /// The pages of every window, for the bench.
    static let live = NSHashTable<ColumnPages>.weakObjects()

    /// `browser`'s pages laid again as the column stands, after something
    /// that held their rows back has let go (Browser.sideStretching).
    static func relay(_ browser: Browser) {
        for pages in live.allObjects where pages.browser === browser { pages.sync() }
    }

    func stop() {
        watching = []
        if let observer { CFRunLoopObserverInvalidate(observer) }
        observer = nil
    }

    func given(_ frame: Frame, look: Look) {
        let changed = frame != frame_ || look != self.look
        frame_ = frame
        self.look = look
        if changed { sync() }
    }

    /// Laid again before this turn's frame is committed: after SwiftUI's
    /// own pass has written what it will, before Core Animation sends it.
    private func soon() {
        guard !pending else { return }
        pending = true
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 1_999_000) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = false
                self.sync()
            }
        }
        if let old = self.observer { CFRunLoopObserverInvalidate(old) }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// After this turn's frame is committed, SwiftUI's move of the column
    /// in it: the page on screen says where its rows are from there.
    private func movedSoon() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_100_000) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.moved() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// The column to the window's other side: SwiftUI puts it there in a
    /// pass of the column's own host, a turn or more after the change, not
    /// always in the change's own (said then, the places were the left's
    /// one time in two), and on Settings' glide over several frames. Looked
    /// at 30 times a second until it stands somewhere else in the window
    /// and has stayed there a tenth of a second, a second and a half at
    /// most, then its rows say where they are.
    private func movedOnceThere() {
        func place(_ view: NSView) -> CGFloat? { view.window == nil ? nil : view.convert(view.bounds, to: nil).minX }
        let from = place(self)
        let started = CACurrentMediaTime()
        var last = from, still = started
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let now = CACurrentMediaTime(), here = place(self)
                if here != last { last = here; still = now }
                guard (here != from && now - still >= 0.1) || now - started > 1.5 else { return }
                timer.invalidate()
                self.moved()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The page on screen says where its rows stand now, as a card is about
    /// to hang from one of them (TabGlance).
    func moved() {
        guard let browser, slide == nil else { return }
        pages[browser.spaceID]?.moved()
    }

    /// What of the rows is in sight, in the window, y down from its top,
    /// from where the page stands now rather than where it last said: the
    /// column put away and brought out over the page is moved by SwiftUI
    /// with nothing in it laid again. Nil while no page is on screen.
    var rowsInWindow: CGRect? {
        guard let browser, slide == nil, !browser.inMail, let window, let content = window.contentView,
              let page = pages[browser.spaceID], !page.away else { return nil }
        let rect = page.convert(page.rowsClip, to: nil)
        guard rect.width > 0 else { return nil }
        return CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    override func layout() {
        super.layout()
        // Laid from here only at new bounds: what the rows show is watched
        // (`sync`). Laid at every pass as well, a switch laid them twice on
        // macOS 26, where SwiftUI lays this host out with the window; on 15
        // it doesn't, and the rows had nothing else (feedback #298). A test
        // run without the watch (YAB_COLUMN_UNTOLD=1) lays them here at
        // every pass, as before, unless it stands in for macOS 15 too
        // (YAB_COLUMN_UNLAID=1).
        // Resting pages use the whole bounds as their frame. A same-size
        // origin change must move them too, or the rows lose their inset.
        // A sliding row keeps its pages together; endSlide syncs them once
        // it lands. Keep the existing size-change path while it is moving.
        let changed = bounds.size != laidBounds.size || (slide == nil && bounds.origin != laidBounds.origin)
        laidBounds = bounds
        if !changed, !ColumnPages.untold || ColumnPages.unlaid { return }
        ColumnPages.laidSyncs += 1
        sync()
    }
    private var laidBounds = CGRect.zero
    /// A test run standing in for macOS 15, whose SwiftUI lays this host
    /// out only at a new size, for #298's A/B.
    static let unlaid = Store.testing && ProcessInfo.processInfo.environment["YAB_COLUMN_UNLAID"] == "1"
    /// A test run without the watch (`sync`), as before #298's fix, for its A/B.
    static let untold = Store.testing && ProcessInfo.processInfo.environment["YAB_COLUMN_UNTOLD"] == "1"

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        sync()
        // Laid before SwiftUI has put the column where it goes (made anew
        // on the window's other side, Sidebar › Right): its rows say where
        // they are again once that is in.
        movedSoon()
    }

    /// The space on screen's page shown and laid as the column stands now,
    /// the others hidden as they were left. Laid again, once, before the
    /// frame after anything it read changes: the tab in front, the tabs,
    /// the pairs, a tab's place. The browser is @Observable and its
    /// objectWillChange no longer says any of that; the rows followed a
    /// switch only when SwiftUI happened to lay this host out in the same
    /// pass, which it did on macOS 26 and not on 15, where the page changed
    /// and the old row stayed lit (feedback #298).
    func sync() {
        guard !tracking, !ColumnPages.untold else { return syncNow() }
        tracking = true
        withObservationTracking {
            syncNow()
        } onChange: { [weak self] in
            let me = self
            let told: @Sendable () -> Void = { MainActor.assumeIsolated { me?.told() } }
            if Thread.isMainThread { told() } else { DispatchQueue.main.async(execute: told) }
        }
    }

    /// Something the last laying read is about to change.
    private func told() {
        tracking = false
        ColumnPages.toldSyncs += 1
        soon()
    }

    /// A laying's reads are being watched (`sync`): one watch at a time.
    private var tracking = false

    private func syncNow() {
        guard let browser else { return }
        // Mid-switch, the space on screen's id with the last one's tabs or
        // folders: laid once the switch has written its row (feedback #249).
        if browser.rowTurning {
            ColumnPages.turningSkipped += 1
            if Store.testing, ColumnPages.turningWho.isEmpty { ColumnPages.turningWho = Array(Thread.callStackSymbols.prefix(24)) }
            // Nothing read to be told of: the laying this asks for watches.
            tracking = false
            soon()
            return
        }
        ColumnPages.syncs += 1
        let started = CACurrentMediaTime()
        defer {
            ColumnPages.lastSync = (CACurrentMediaTime() - started) * 1000
            Startup.accrue("column", ms: ColumnPages.lastSync)
        }
        let space = browser.spaceID
        if browser.inMail {
            if slide == nil { pages.values.forEach(park) }
            return
        }
        let page: ColumnPage
        if let kept = pages[space] {
            page = kept
        } else {
            page = ColumnPage(browser: browser, space: space)
            pages[space] = page
            addSubview(page)
            ColumnPages.made += 1
        }
        order.removeAll { $0 == space }
        order.append(space)
        // Spaces gone, and past the most kept, the one left longest ago.
        let spaces = Set(browser.spaces.map(\.id))
        for id in order where id != space && !spaces.contains(id) { drop(id) }
        while order.count > Self.most {
            guard let oldest = order.first(where: { $0 != space && $0 != ColumnSpaceCarry.of(browser)?.home }) else { break }
            drop(oldest)
        }
        if let slide {
            // The row of spaces sliding: every page it goes past where the
            // row has it, the one now on screen laid live in its place.
            if let at = slide.order.firstIndex(of: space) {
                let frame = bounds.offsetBy(dx: CGFloat(at - slide.home) * bounds.width, dy: 0)
                if page.frame != frame { page.frame = frame }
                page.isHidden = false
            }
        } else {
            for (id, each) in pages where id != space { park(each) }
            if page.frame != bounds { page.frame = bounds }
            page.isHidden = false
        }
        // The rows' lead worked out here, as for a page laid ahead, rather
        // than SideBar's, which comes a SwiftUI pass after the pins it
        // stands under: a space with pins came in with the last one's lead
        // for a frame and its rows jumped; the last pin brought down, the
        // name glided while the rows jumped (2026-10-14).
        var frame = frame_
        // The gaps the hand opens in the pins count: a row of the grid more
        // takes the rows down with it, and its let-go changes nothing.
        if !browser.inMail { frame.lead = ColumnLayout.lead(browser, pins: browser.pinCellCount + (page.hand.pinGaps?.count ?? 0)) }
        page.live(ColumnLayout.live(browser, shape: page.hand.shape), head: ColumnLayout.head(browser, gaps: page.hand.pinGaps), frame: frame, look: look)
        SwitchMarks.lit(browser.activeID)
    }

    /// How far out of the column a page waits: drawn there, not hidden, so
    /// a change of space shows it as it is, with nothing left to draw.
    static let parked: CGFloat = -20_000

    private func park(_ page: ColumnPage) {
        guard page.frame.minX != Self.parked else { return }
        page.frame = bounds.offsetBy(dx: Self.parked, dy: 0)
        page.isHidden = false
    }

    /// To VoiceOver, the space on screen's page alone.
    override func accessibilityChildren() -> [Any]? {
        shown.map { [$0] } ?? []
    }

    private func drop(_ id: UUID) {
        order.removeAll { $0 == id }
        pages.removeValue(forKey: id)?.removeFromSuperview()
    }

    /// The page on screen.
    var shown: ColumnPage? { browser.flatMap { pages[$0.spaceID] } }

    /// Only the rows take the pointer, where they are clear of the head and
    /// the foot; over a card hanging over them (a preview), the card.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let browser, !isHidden, !browser.inMail else { return nil }
        let local = convert(point, from: superview)
        if let event = NSApp.currentEvent, event.window === window, browser.glance.covers(event) { return nil }
        // Over the pins, the name and the rows; under the last row the
        // window is dragged by, as under SideBar's.
        guard let page = shown else { return nil }
        let inPage = convert(local, to: page)
        // A scroll over the empty tail under the last row is the rows' too.
        if NSApp.currentEvent?.type == .scrollWheel, page.holdsScroll(inPage) { return page.scrollView }
        guard page.holds(inPage) else { return nil }
        // A scroll goes straight to the rows' scroll view, never into a
        // row's own SwiftUI host: a host takes a trackpad's phased scroll
        // for itself, and the rows never moved under two fingers (the
        // bench's 500 tabs stayed at the top; stops.py's swipes were let go
        // a few points out). SideBar's rows were in its ScrollView.
        if NSApp.currentEvent?.type == .scrollWheel { return page.scrollView }
        return super.hitTest(point)
    }

    /// Qualifies only the existing background Space-menu target. Ordinary
    /// clicks, dragging and scrolling keep their own hit-test routes.
    // Read-only native route observation, normally nil. Test owners scope and
    // restore it; no result supplied by this observer can grant a target.
    static var tailMenuTrace: ((ColumnPages, NSEvent, Bool) -> Void)?

    func spaceMenuTail(at point: NSPoint, from view: NSView, event: NSEvent) -> Bool {
        var admitted = false
        defer { Self.tailMenuTrace?(self, event, admitted) }
        guard ColumnKit.on, let browser, !browser.inMail, !isHidden,
              let window, event.window === window, view.window === window,
              let column = browser.column, column.shown, column.window === window,
              isDescendant(of: column), !browser.glance.covers(event),
              let page = shown, !page.away, !page.hand.holding,
              page.space == browser.spaceID else { return false }
        let local = convert(point, from: view)
        guard bounds.contains(local) else { return false }
        admitted = page.spaceMenuTail(convert(local, to: page))
        return admitted
    }

    /// For the bench: pages made, and how long the last laying took.
    static var made = 0
    /// Each page beside laid again, why and what it cost (bench columnkit).
    static var readies: [String] = []
    static var readyWhy = ""
    static var lastSync = 0.0
    /// Syncs, and syncs laid from AppKit's layout pass, for the bench.
    static var syncs = 0
    /// Syncs put off while a change of space wrote its row (rowTurning).
    static var turningSkipped = 0
    /// Who asked the first one, for the bench.
    static var turningWho: [String] = []
    static var laidSyncs = 0
    /// Layings asked because something the last one read changed (`told`).
    static var toldSyncs = 0

    /// The pages of `browser`'s window.
    static func of(_ browser: Browser) -> ColumnPages? {
        live.allObjects.first { $0.browser === browser && $0.window != nil }
    }

    // MARK: - the row of spaces (SpacePager)

    /// The spaces in the row's order, and which stands at no offset: the
    /// one on screen when the row came up.
    private struct Slide {
        var order: [UUID]
        var home: Int
        /// The pins every space it goes past shows stand still, the home
        /// page's own, over the row.
        var still = false
    }
    private var slide: Slide?
    /// Mail's space as a page: its column, as it will stand.
    private var mailPage: NSView?

    /// The row of spaces up: the live pages themselves, side by side, in a
    /// clip that one transform moves (SpacePager, as PagerStage with the
    /// pictures). No picture, no mask: what slides is what is there.
    func beginSlide(order: [UUID], home: Int) -> Bool {
        guard let browser, !browser.inMail, order.indices.contains(home), let page = pages[order[home]], bounds.width > 20 else { return false }
        slide = Slide(order: order, home: home)
        // No transaction of its own: begun and committed here, with none
        // open yet in the switch's turn, it committed the whole window,
        // laid out there and then, 5 ms before the row could set off. A
        // view's own layer takes no implicit animation anyway.
        layer?.masksToBounds = true
        layer?.sublayerTransform = CATransform3DIdentity
        page.frame = bounds
        page.isHidden = false
        return true
    }

    /// The page of the space at `index` in the row, laid if it isn't: from
    /// its parked row, in its own color's words.
    func build(_ index: Int, row: Parked?, travelling: [Tab]) -> Bool {
        guard let browser, let slide, slide.order.indices.contains(index) else { return false }
        let id = slide.order[index]
        let frame = bounds.offsetBy(dx: CGFloat(index - slide.home) * bounds.width, dy: 0)
        if id == Space.mailID {
            let host: NSView = mailPage ?? { () -> NSView in
                let made = NSHostingView(rootView: AnyView(PagedSpaceRoot(browser: browser, prefs: browser.prefs,
                                                                          content: PagedSpace(browser: browser, prefs: browser.prefs, mail: true, row: nil, travelling: []),
                                                                          paint: SpaceWash.worn(browser.prefs), floating: false, grounded: false)))
                made.sizingOptions = []
                addSubview(made)
                return made
            }()
            mailPage = host
            host.frame = frame
            host.isHidden = false
            host.layoutSubtreeIfNeeded()
            return false
        }
        let kept = pages[id] != nil
        let page = pages[id] ?? {
            let made = ColumnPage(browser: browser, space: id)
            pages[id] = made
            addSubview(made, positioned: .below, relativeTo: nil)
            ColumnPages.made += 1
            return made
        }()
        page.frame = frame
        page.isHidden = false
        if !kept || id != browser.spaceID, let row, let space = browser.spaces.first(where: { $0.id == id }) {
            // Laid as it stood: only when made now, or its row changed since
            // it was laid ahead.
            let key = laidKey(row, travelling: travelling, space: space)
            if !kept || page.laidKey != key {
                let laid = ColumnLayout.parked(browser, row: row, travelling: travelling, space: space)
                if !kept || page.stale(laid.items, head: laid.head) {
                    var frame = frame_
                    frame.lead = ColumnLayout.lead(browser, pins: laid.head.filter(\.isPin).count, row: row, space: space, travelling: travelling)
                    page.still(laid.items, head: laid.head, frame: frame, look: look(of: space), top: !kept, active: row.active)
                }
                page.laidKey = key
            }
        }
        if !order.contains(id) { order.insert(id, at: max(0, order.count - 1)) }
        return kept
    }

    /// A space's page laid ahead, hidden, from its parked row: true when it
    /// was laid now, false when the one kept still shows it.
    func ready(_ id: UUID, row: Parked, travelling: [Tab]) -> Bool {
        guard let browser, slide == nil, id != browser.spaceID, let space = browser.spaces.first(where: { $0.id == id }) else { return false }
        let key = laidKey(row, travelling: travelling, space: space)
        if let page = pages[id], page.laidKey == key { return false }
        let laid = ColumnLayout.parked(browser, row: row, travelling: travelling, space: space)
        if let page = pages[id], !page.stale(laid.items, head: laid.head) {
            page.laidKey = key
            return false
        }
        let fresh = pages[id] == nil
        if Store.testing {
            // Why a page beside is laid again, for the bench (columnkit).
            let old = pages[id].map { ($0.items, $0.headItems) }
            var why = fresh ? "fresh" : "?"
            if let old {
                if old.0.count != laid.items.count { why = "items \(old.0.count)->\(laid.items.count)" }
                else if old.1.count != laid.head.count { why = "head \(old.1.count)->\(laid.head.count)" }
                else if let i = laid.items.indices.first(where: { !laid.items[$0].same(old.0[$0]) || laid.items[$0].y != old.0[$0].y }) {
                    why = "item \(i) \(laid.items[i].id)/\(old.0[i].id) same \(laid.items[i].same(old.0[i])) y \(laid.items[i].y)/\(old.0[i].y)"
                } else if let i = laid.head.indices.first(where: { !laid.head[$0].same(old.1[$0]) || laid.head[$0].y != old.1[$0].y }) {
                    why = "head \(i) \(laid.head[i].id)/\(old.1[i].id) same \(laid.head[i].same(old.1[i])) y \(laid.head[i].y)/\(old.1[i].y)"
                }
            }
            ColumnPages.readyWhy = why
        }
        let readyStart = CACurrentMediaTime(), cellsBefore = ColumnPage.cellsMade, boundBefore = ColumnCell.bound
        let page = pages[id] ?? {
            let made = ColumnPage(browser: browser, space: id)
            pages[id] = made
            addSubview(made, positioned: .below, relativeTo: nil)
            ColumnPages.made += 1
            return made
        }()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        page.frame = bounds
        page.isHidden = false
        var frame = frame_
        frame.lead = ColumnLayout.lead(browser, pins: laid.head.filter(\.isPin).count, row: row, space: space, travelling: travelling)
        page.still(laid.items, head: laid.head, frame: frame, look: look(of: space), top: fresh, active: row.active)
        page.laidKey = key
        park(page)
        CATransaction.commit()
        if Store.testing {
            ColumnPages.readies.append("\(ColumnPages.readyWhy) \(Int((CACurrentMediaTime() - readyStart) * 1000))ms made+\(ColumnPage.cellsMade - cellsBefore) bound+\(ColumnCell.bound - boundBefore)")
            if ColumnPages.readies.count > 30 { ColumnPages.readies.removeFirst() }
        }
        if !order.contains(id) { order.insert(id, at: max(0, order.count - 1)) }
        return true
    }

    /// What a parked row's page shows, as far as laying it goes: its tabs,
    /// pinned, kept, filed, the one in front, the folders, the look.
    private func laidKey(_ row: Parked, travelling: [Tab], space: Space) -> String {
        guard let browser else { return "" }
        var key = "\(space.id) \(space.name) \(space.icon) \(row.active?.uuidString ?? "-") \(row.pairs.count) \(browser.folderBook.version)"
        key += " \(browser.folderBook.open.count) \(browser.prefs.sideWidth) \(Density.current) \(browser.namesSpaces) \(browser.sidePlated)"
        key += " extensions:\(SidePlate.extensionPlate(in: browser, space: space.id, tab: (row.tabs + travelling).first { $0.id == row.active }, shown: browser.sidePlated(row)))"
        key += " \(String(describing: look(of: space).tone?.page))"
        for tab in row.tabs + travelling {
            key += "|\(tab.id.uuidString.prefix(8))\(tab.pin ?? "")\(tab.kept ? "k" : "")\(tab.nest.map { "\($0.id.uuidString.prefix(6))\($0.open)" } ?? "")"
        }
        return key
    }

    /// A space's look before it is on screen: its own color's words, as
    /// PagedSpaceRoot wears them.
    private func look(of space: Space) -> Look {
        guard let browser else { return look }
        let prefs = browser.prefs
        guard let paint = SpaceWash.grounded(space.paint, in: browser) else { return look }
        var tone = Tone(paint.color, lifted: true, glass: paint.glass)
        if look.tone?.seeThrough == true || (prefs.backdrop == .none && !prefs.edgeBackdrop) || (prefs.sideShut && browser.sideCard) { tone = tone.card(paint) }
        return Look(tone: tone, scheme: tone.scheme, titleSize: look.titleSize, grain: look.grain)
    }

    /// Slid to `x`, at once: two fingers' move.
    func slideTo(_ x: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayerTransform = CATransform3DMakeTranslation(x, 0, 0)
        stillPins(x, from: nil, velocity: 0)
        CATransaction.commit()
    }

    /// From `from` to `to` on the row's spring, added to whatever still
    /// lands, so a second key turns it without a jolt.
    func land(from: CGFloat, to: CGFloat, velocity: CGFloat, done: @escaping () -> Void) {
        guard let layer else { return done() }
        let delta = from - to
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(done)
        layer.sublayerTransform = CATransform3DMakeTranslation(to, 0, 0)
        if abs(delta) > 0.25 {
            let spring = SpacePaging.animation(keyPath: "sublayerTransform.translation.x", from: delta, to: 0, velocity: -velocity / delta)
            spring.isAdditive = true
            layer.add(spring, forKey: "pager.\(UUID().uuidString)")
        }
        stillPins(to, from: from, velocity: velocity)
        CATransaction.commit()
    }

    /// The pins standing still over the row: the home page's head carried
    /// back as far as the row goes, the others' hidden.
    private func stillPins(_ x: CGFloat, from: CGFloat?, velocity: CGFloat) {
        guard let slide else { return }
        for (id, page) in pages {
            let home = id == slide.order[slide.home]
            page.headPins(hidden: slide.still && !home, offset: slide.still && home ? -x : 0, from: from.map { -$0 }, velocity: -velocity)
        }
    }

    /// The pins over the row stand still, or go with their pages.
    func holdPins(_ still: Bool) {
        guard slide != nil, slide?.still != still else { return }
        slide?.still = still
        let x = layer?.presentation()?.sublayerTransform.m41 ?? layer?.sublayerTransform.m41 ?? 0
        if let slide, let home = pages[slide.order[slide.home]] { addSubview(home, positioned: .above, relativeTo: nil) }
        stillPins(x, from: nil, velocity: 0)
    }

    /// Where the row is drawn, the spring's way included.
    var drawnOffset: CGFloat {
        let shown = layer?.presentation() ?? layer
        return shown?.sublayerTransform.m41 ?? 0
    }

    /// When the latest landing spring began, as its commit stamped it.
    var slideBegan: CFTimeInterval? {
        guard let layer else { return nil }
        return (layer.animationKeys() ?? []).filter { $0.hasPrefix("pager.") }.compactMap { layer.animation(forKey: $0)?.beginTime }.filter { $0 > 0 }.max()
    }

    var sliding: Bool { slide != nil }

    /// Landed: the space on screen's page at no offset, the others hidden,
    /// in one commit that moves nothing on screen.
    func endSlide() {
        guard slide != nil else { return }
        slide = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for key in layer?.animationKeys() ?? [] where key.hasPrefix("pager.") { layer?.removeAnimation(forKey: key) }
        layer?.sublayerTransform = CATransform3DIdentity
        layer?.masksToBounds = false
        mailPage?.isHidden = true
        for page in pages.values { page.headPins(hidden: false, offset: 0, from: nil, velocity: 0) }
        // The page landed on put at no offset in the same commit as the row
        // comes off: committed first, from a landing's completion with no
        // transaction open, the row at rest showed the space it started
        // from for a frame or two before this one came back (feedback #181).
        sync()
        CATransaction.commit()
    }
}

// MARK: - the ends

/// The rows' ends dimmed and blurred as far as they have gone under what
/// stands over them (ColumnEnds, ColumnFade, ColumnBlur), in Core
/// Animation: a mask of the rows' own alpha, and the blur over them.
final class ColumnEndsLayers {
    private let mask = CALayer()
    private let topFade = CAGradientLayer()
    private let middle = CALayer()
    private let footFade = CAGradientLayer()
    private let above = CALayer()
    private let below = CALayer()
    private var topBlur: EdgeBlurView?
    private var footBlur: EdgeBlurView?
    private weak var host: NSView?
    private weak var rows: NSView?
    private var frame = ColumnPages.Frame(lead: 0, footRoom: 0, top: 0, foot: true)
    private var bounds: CGRect = .zero
    private var now = ColumnEnds.Depth(above: -1, below: -1)
    private var grain: Double = 0
    private let grains = CALayer()
    private let grainMask = CALayer()
    private let grainTop = CAGradientLayer()
    private let grainFoot = CAGradientLayer()

    @MainActor func install(in host: NSView, over rows: NSView) {
        self.host = host
        self.rows = rows
        rows.wantsLayer = true
        for layer in [above, topFade, middle, footFade, below] {
            layer.backgroundColor = NSColor.black.cgColor
            mask.addSublayer(layer)
        }
        topFade.backgroundColor = nil
        footFade.backgroundColor = nil
        rows.layer?.mask = mask
        let top = EdgeBlurView(radius: ColumnEnds.pinsBlur)
        top.edge = .top
        let foot = EdgeBlurView(radius: ColumnEnds.footBlur)
        foot.edge = .bottom
        host.addSubview(top, positioned: .above, relativeTo: rows)
        host.addSubview(foot, positioned: .above, relativeTo: rows)
        topBlur = top
        footBlur = foot
        grains.mask = grainMask
        grainMask.addSublayer(grainTop)
        grainMask.addSublayer(grainFoot)
        host.layer?.addSublayer(grains)
    }

    @MainActor func lay(in bounds: CGRect, frame: ColumnPages.Frame) {
        // Only wider or narrower (the column's edge pulled, or on its way
        // back): the layers take the width, and the fades, the blurs' curve
        // and the grain, all drawn down the height, are left as they are.
        let across = bounds.height == self.bounds.height && frame == self.frame && bounds.width != self.bounds.width
        self.bounds = bounds
        self.frame = frame
        let fall = ColumnEnds.fall
        let low = frame.footRoom, drop = ColumnEnds.footFall
        let top = frame.top
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The mask in the rows' scroll view's own space, which is the
        // page's: whole a little past either edge, where a held row is
        // drawn while the rows fit.
        let beyond = 2 * SideBar.row
        mask.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        // The mask goes down from the top, as the rows do: AppKit flips a
        // flipped view's layer, and a mask follows the layer it masks (measured).
        let flipped = false
        func y(_ from: CGFloat, _ h: CGFloat) -> CGRect {
            // A layer's y goes up unless its view flipped it.
            CGRect(x: -beyond, y: flipped ? bounds.height - from - h : from, width: bounds.width + 2 * beyond, height: h)
        }
        above.frame = y(-beyond, beyond)
        topFade.frame = y(0, top + fall)
        let footH = frame.foot ? low + drop : 0
        middle.frame = y(top + fall, max(0, bounds.height - top - fall - footH))
        footFade.frame = y(bounds.height - footH, footH)
        below.frame = y(bounds.height, beyond)
        topBlur?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: top + fall)
        topBlur?.whole = top / (top + fall)
        topBlur?.needsLayout = true
        footBlur?.isHidden = !frame.foot
        footBlur?.frame = CGRect(x: 0, y: bounds.height - footH, width: bounds.width, height: footH)
        footBlur?.whole = low / (low + drop)
        footBlur?.needsLayout = true
        // The player's room changes the blur's height and its curve in
        // this transaction. Do not draw its new frame with the previous
        // backdrop mask while AppKit waits for a separate layout pass.
        footBlur?.layoutSubtreeIfNeeded()
        grains.frame = host?.layer?.bounds ?? bounds
        grainMask.frame = grains.bounds
        if across {
            grainTop.frame.size.width = grains.bounds.width
            grainFoot.frame.size.width = grains.bounds.width
        }
        CATransaction.commit()
        guard !across else { return }
        let depth = now
        now = ColumnEnds.Depth(above: -1, below: -1)
        self.depth(depth, grain: grain, tone: grains.isHidden == false)
    }

    @MainActor func depth(_ depth: ColumnEnds.Depth, grain: Double, tone: Bool) {
        let grain = tone ? grain : 0
        guard depth != now || grain != self.grain else { return }
        now = depth
        self.grain = grain
        let fall = ColumnEnds.fall
        let low = frame.footRoom, drop = ColumnEnds.footFall
        let top = frame.top
        let flipped = false
        let grainsUp = host?.layer?.isGeometryFlipped == false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        func set(_ layer: CAGradientLayer, _ stops: [(alpha: Double, at: Double)], fromTop: Bool) {
            layer.colors = stops.map { NSColor.black.withAlphaComponent($0.alpha).cgColor }
            layer.locations = stops.map { NSNumber(value: $0.at) }
            // From the edge it fades from; a layer's y goes up unless its
            // view flipped it.
            let up = fromTop == flipped
            layer.startPoint = CGPoint(x: 0.5, y: up ? 1 : 0)
            layer.endPoint = CGPoint(x: 0.5, y: up ? 0 : 1)
        }
        set(topFade, Self.stops(depth: max(0, depth.above), under: top / (top + fall), shown: ColumnEnds.shown), fromTop: true)
        set(footFade, Self.stops(depth: max(0, depth.below), under: low / (low + drop), shown: ColumnEnds.footShown), fromTop: false)
        topBlur?.alphaValue = max(0, depth.above)
        footBlur?.alphaValue = max(0, depth.below)
        grains.isHidden = grain <= 0
        if grain > 0 {
            if grains.backgroundColor == nil { grains.backgroundColor = NSColor(patternImage: Grain.tile).cgColor }
            grains.opacity = Float(Grain.opacity(grain))
            let topH = top + fall, footH = frame.foot ? low + drop : 0
            let h = grains.bounds.height
            // Its mask goes down from the top too.
            _ = grainsUp
            grainTop.frame = CGRect(x: 0, y: 0, width: grains.bounds.width, height: topH)
            grainFoot.frame = CGRect(x: 0, y: h - footH, width: grains.bounds.width, height: footH)
            set(grainTop, EdgeBlurView.curve(under: top / topH).map { ($0.alpha, $0.at) }, fromTop: true)
            set(grainFoot, EdgeBlurView.curve(under: low / (low + drop)).map { ($0.alpha, $0.at) }, fromTop: false)
            grainTop.opacity = Float(max(0, depth.above))
            grainFoot.opacity = Float(max(0, depth.below))
        }
        CATransaction.commit()
    }

    /// ColumnFade.stops, as alphas and locations.
    static func stops(depth: CGFloat, under: CGFloat, shown: Double) -> [(alpha: Double, at: Double)] {
        let low = 1 - Double(depth) * (1 - shown)
        var stops: [(alpha: Double, at: Double)] = [(low, 0)]
        for n in 0...8 {
            let t = Double(n) / 8
            stops.append((low + (1 - low) * t * t * (3 - 2 * t), Double(under) + (1 - Double(under)) * t))
        }
        return stops
    }
}
