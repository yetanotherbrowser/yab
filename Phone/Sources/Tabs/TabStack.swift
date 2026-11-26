import os
import SwiftUI
import UIKit

/// The tab stack on the right of the plate, in place of +: which tabs were
/// used last (TabRecency), the flick up that brings the previous one back,
/// and All Tabs. One per app, as the pager is; the chrome's right button
/// (ChromeNativePlus), TabFlickLayer and TabGalleryLayer draw what it says.
@MainActor
@Observable
final class TabStack {
    let app: AppModel
    private(set) var recency: TabRecency
    /// Bumped whenever a tab's picture comes or goes (the pool's, or one
    /// kept in `store`), so cards redraw.
    private(set) var pictures = 0
    /// Every card's picture kept past the pool's own, on disk for ordinary
    /// tabs (TabPictures): the cards show real pages after a launch too.
    let store: TabPictures

    // MARK: - the flick

    /// A flick up on the stack: the previous tab's card lifted with the
    /// finger, then, let go past the commit, its page growing from there.
    struct Flick: Equatable {
        let target: Tab
        /// The tab in front when it began, and its space.
        let from: Tab.ID
        let space: Space.ID
        var released = false
        /// Where the lifted card was as the finger let go, in screen points,
        /// before its turn (Metrics.TabStack.frontTurn).
        var start: CGRect = .zero
    }
    private(set) var flick: Flick?
    /// How far the flicked tab's page has grown out of its card, 0 to 1
    /// (apart from `flick`, so the chrome isn't redrawn on every frame).
    private(set) var growth: CGFloat = 0

    // MARK: - All Tabs

    /// All Tabs, up: the space's open tabs as cards, oldest on the left.
    struct Gallery: Equatable {
        let space: Space.ID
        /// Oldest first; the tab that was in front is last, its page shrank
        /// into that card. A closed card's tab keeps its place here, so the
        /// toast's Undo brings the card back where it was.
        var order: [Tab.ID]
        /// iPad presents the remembered split as one card. Phones keep individual cards.
        var pair: BrowserWorkspace.Pair?
        /// Kept and pinned tabs closed here: they stay, but not as cards.
        var dropped: Set<Tab.ID> = []
        /// The card standing at the focus (oldest 0): at first the tab used
        /// before the one in front; a finger moves it.
        var focus: CGFloat = 0
        /// Coming, up, or going into a card's page; `time` is the seconds
        /// since the tap, while it comes or goes (TabGalleryMotion).
        var phase: Phase = .opening
        var time: Double = 0
        var pinchProgress: CGFloat?
        /// The front card's offset from its path while a finger holds it
        /// (Safari's: the page shrinks under the finger, wherever it goes).
        var pinchShift: CGSize = .zero
        /// A card a finger is taking up, and how far (negative is up).
        var lifted: Tab.ID?
        var lift: CGFloat = 0
        /// Cards flying away, closed.
        var leaving: Set<Tab.ID> = []
        var flightOffsets: [Tab.ID: CGFloat] = [:]
        /// The card tapped; where each card was then and what it does now;
        /// the bar's share then (a tap while it still opens goes from there).
        var chosen: Tab.ID?
        var from: [Tab.ID: TabCardPose] = [:]
        var roles: [Tab.ID: TabGalleryMotion.Role] = [:]
        var barFrom: CGFloat = 1
        /// The circle as it closes (TabGalleryMotion.Closing): the stack's
        /// cards that don't fly, in their places in it; whether it comes up
        /// from below (the top card chosen); whether the stack shows any
        /// card afterwards (else its +).
        var seated: [Seated] = []
        var rises = false
        var stacked = true

        struct Seated: Equatable {
            let id: Tab.ID
            /// `.front` or `.back`.
            let place: TabGalleryMotion.Role
        }

        enum Phase: Equatable { case opening, open, closing }

        /// How much of the gallery's own bar (its + and its ground under the
        /// chrome's row) shows: the page's chrome has the rest.
        var bar: CGFloat {
            switch phase {
            case .opening: pinchProgress ?? TabGalleryTiming.barProgress(time)
            case .open: 1
            case .closing: barFrom * (1 - TabGalleryTiming.barProgress(time))
            }
        }
    }
    private(set) var gallery: Gallery?

    /// The right button, for the lifted card frame by frame.
    @ObservationIgnored weak var control: ChromePlusControl?
    /// The screen the layers fill: TabFlickLayer tells.
    @ObservationIgnored var screen: CGSize = Metrics.screen {
        didSet { if screen != oldValue { store.shape = Self.shape(screen) } }
    }
    /// All Tabs' warm-up of cards with no picture at all, and where its
    /// pages load (TabWarmupStage, at the back of All Tabs).
    @ObservationIgnored private(set) lazy var warmup: TabWarmup = {
        let warmup = TabWarmup(width: 2, warm: { [weak self] tab in await self?.warm(tab) ?? .failed },
                               letGo: { [weak self] id, keep in self?.letGoWarm(id, keep: keep) })
        warmup.mayStart = { [weak self] in self?.still ?? false }
        return warmup
    }()
    @ObservationIgnored weak var stage: TabWarmupStage?
    /// Off with -YabTabWarmup NO (a UI test proving pictures came from the disk).
    @ObservationIgnored private let warmsUp: Bool
    /// A finger moves All Tabs' cards sideways.
    @ObservationIgnored private var touching = false
    @ObservationIgnored private var settling: Task<Void, Never>?
    @ObservationIgnored private var pruning: Task<Void, Never>?
    @ObservationIgnored private var resignation: NSObjectProtocol?
    /// What pictures cost, for the measures (TabPicturesTests): the main
    /// thread's milliseconds inside each capture's call, and the seconds each
    /// warmed card took from its page's start to its picture.
    @ObservationIgnored private(set) var captureCalls: [Double] = []
    @ObservationIgnored private(set) var warmTimes: [Double] = []
    @ObservationIgnored private let file: TabRecencyFile?
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var leavingForField: Task<Void, Never>?
    @ObservationIgnored private var litStatusBar = false
    @ObservationIgnored private var chromeFrom: Double = 1
    @ObservationIgnored private let clock = TabGalleryClock()
    @ObservationIgnored lazy var pinchGesture = TabOverviewPinch(stack: self)
    /// All Tabs turning, in place, into the spaces sidebar (its computer tapped).
    var toSidebar = false
    @ObservationIgnored private var flights: [Tab.ID: TabCardFlight] = [:]
    @ObservationIgnored private var scrollStep: CGFloat = 1
    @ObservationIgnored private var pinchProgress: CGFloat?
    @ObservationIgnored private var pinchEnd: (commit: Bool, velocity: CGFloat)?
    /// Up from the plate: where the finger touched the page, and how far it went.
    /// When the foot's capsule last turned All Tabs to another space.
    @ObservationIgnored private(set) var pagedAt: CFTimeInterval = 0
    @ObservationIgnored private var pinchAnchor: CGPoint?
    @ObservationIgnored private var pinchFinger: CGSize = .zero
    /// Let go: the card's offset then, and the progress it had, which the
    /// spring takes to nothing as it settles.
    @ObservationIgnored private var pinchRelease: (shift: CGSize, progress: CGFloat)?
    @ObservationIgnored private lazy var pinchSpring = spring { [weak self] value in self?.updatePinch(value / 1000) }
    @ObservationIgnored private lazy var scrollSpring = spring { [weak self] value in
        guard let self, self.gallery?.phase == .open else { return }
        self.gallery?.focus = value / self.scrollStep
    }
    @ObservationIgnored private lazy var cardSpring = spring { [weak self] value in self?.gallery?.lift = value }
    @ObservationIgnored private lazy var liftSpring = spring { [weak self] v in self?.control?.stackView.lift = v }
    @ObservationIgnored private lazy var growSpring = spring { [weak self] v in self?.grew(v / 1000) }

    init(app: AppModel, store: TabPictures? = nil, warmsUp: Bool? = nil) {
        self.app = app
        file = app.profile.map { TabRecencyFile(url: $0.folder.appendingPathComponent("tab-recency.json")) }
        recency = file?.read(spaces: app.browser.spaces) ?? TabRecency()
        self.store = store ?? TabPictures(folder: TabPictures.folder(for: app), shape: Self.shape(Metrics.screen))
        self.warmsUp = warmsUp ?? Self.warmUpArgument
        app.pages.onPicture = { [weak self] id in self?.pictured(id) }
        app.pages.onPainted = { [weak self] id in self?.painted(id) }
        self.store.onChange = { [weak self] in self?.pictures += 1 }
        resignation = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resigning() }
        }
        // Not inside the view update that may have made it.
        Task { @MainActor [weak self] in
            self?.watchSelection()
            self?.watchSurfaces()
            self?.watchTabs()
            self?.watchPrivateLock()
        }
    }

    private static var stacks: [ObjectIdentifier: TabStack] = [:]

    static func of(_ app: AppModel) -> TabStack {
        let key = ObjectIdentifier(app)
        if let stack = stacks[key] { return stack }
        let stack = TabStack(app: app)
        stacks[key] = stack
        return stack
    }

    /// Tests: the app's stack with its pictures kept in `store`.
    @discardableResult
    static func attach(_ app: AppModel, store: TabPictures, warmsUp: Bool = true) -> TabStack {
        let stack = TabStack(app: app, store: store, warmsUp: warmsUp)
        stacks[ObjectIdentifier(app)] = stack
        return stack
    }

    private static let warmUpArgument: Bool = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-YabTabWarmup"), i + 1 < arguments.count else { return true }
        return !["no", "false", "0", "off"].contains(arguments[i + 1].lowercased())
    }()

    /// A card's picture on this screen at its scale.
    static func shape(_ screen: CGSize) -> TabPictures.Shape {
        let scale = TabGalleryClock.window?.traitCollection.displayScale ?? UITraitCollection.current.displayScale
        return TabPictures.Shape(layout: TabGalleryLayout(screen: screen, count: 0), scale: scale > 0 ? scale : 3)
    }

    /// Under Reduce Motion a run cross-fades the window instead (SpringValue).
    private func spring(_ update: @escaping (CGFloat) -> Void) -> SpringValue {
        let spring = SpringValue(0, onUpdate: update)
        spring.fadeView = { TabGalleryClock.window }
        return spring
    }

    // MARK: - the order

    /// The space in front's open tabs, latest first: the tab in front, then
    /// the one used before it, and so on (TabRecency.order).
    var order: [Tab] { TabRecency.order(of: app.browser.space, recent: recency.recent(in: app.browser.spaceID)) }

    /// The tab used before the one in front: the stack's front card. With
    /// nothing in front (the empty page) the first of the order is no page
    /// being left, and it is that card.
    var previous: Tab? { behindFront(order).first }

    private func behindFront(_ tabs: [Tab]) -> ArraySlice<Tab> {
        tabs.first?.id == app.browser.tab?.id ? tabs.dropFirst() : tabs[...]
    }

    /// What the right button shows: the two tabs used last after the one in
    /// front (none: it is + as before), and how many All Tabs would show.
    struct Contents: Equatable {
        var front: Tab?
        var back: Tab?
        var count = 0
        var pictures = 0
        /// One page, in front (a today's tab, or a pin with Today empty): the
        /// stack shows it alone, and All Tabs is where its card closes it.
        var loneCard = false
        var showsStack: Bool { front != nil }
    }

    func contents() -> Contents {
        var tabs = order
        let firstWasFront = tabs.first?.id == app.browser.tab?.id
        // Let go of a flick: the stack shows the tab being left in front at
        // once, while the previous one grows into the page.
        if let flick, flick.released, tabs.count > 1, tabs[1].id == flick.target.id { tabs.swapAt(0, 1) }
        let behind = firstWasFront ? tabs.dropFirst() : tabs[...]
        // One page, in front: the stack shows it, so what is open is always in sight.
        return Contents(front: behind.first ?? tabs.first, back: behind.dropFirst().first, count: tabs.count, pictures: pictures,
                        loneCard: tabs.count == 1 && behind.isEmpty)
    }

    /// A tab's last picture: the pool's (this run's, the whole page) or
    /// the one kept for its card, read from the disk as it is first asked
    /// for (`pictures` changes when it is here).
    func picture(_ tab: Tab) -> UIImage? { app.pages.snapshots[tab.id] ?? store.image(for: tab.id) }

    /// A picture exists for the tab, drawn yet or not.
    func hasPicture(_ tab: Tab) -> Bool { app.pages.snapshots[tab.id] != nil || store.has(tab.id) }

    /// The tab in front changed: it is first in its space's order now.
    private func watchSelection() {
        let now = withObservationTracking {
            (app.browser.spaceID, app.browser.tab?.id)
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchSelection() }
        }
        if let id = now.1 { touch(id, in: now.0) }
        // No page left to scroll: the chrome that folded with it comes back.
        else if app.chrome.folded { app.chrome.setFolded(false) }
    }

    func touch(_ id: Tab.ID, in space: Space.ID) {
        guard recency.recent(in: space).first != id else { return }
        recency.touch(id, in: space)
        save()
    }

    private func save() {
        guard let file else { return }
        saving?.cancel()
        saving = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            try? file.write(self.recency, spaces: self.app.browser.spaces)
        }
    }

    /// A menu, a sheet or the private curtain over the page.
    private var covered: Bool {
        let s = app.surfaces
        return app.privateContentBlocked || s.field != nil || s.chat != nil || s.settings
            || s.join || s.menu != nil
    }

    /// Another surface takes the screen: a flick in the middle goes back, All
    /// Tabs goes; under New Tab's field (its +) it waits until the field has grown.
    private func watchSurfaces() {
        let busy = withObservationTracking { covered } onChange: { [weak self] in
            Task { @MainActor in self?.watchSurfaces() }
        }
        guard busy else { return }
        if flick?.released == false { cancelFlick(animated: false) }
        guard gallery != nil else { return }
        // Settings from All Tabs' gear stands over it and closes back to it.
        let s = app.surfaces
        if s.settings && !app.privateContentBlocked && s.field == nil && s.chat == nil && s.menu == nil { return }
        if app.surfaces.field != nil && !app.privateContentBlocked {
            // The last card goes up beside the sheet, and closes its tab when it is gone.
            guard leavingForField == nil else { return }
            leavingForField = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Motion.disabled ? 0 : Motion.plusToField.duration))
                self?.leavingForField = nil
                self?.dismissGallery()
            }
        } else {
            dismissGallery()
        }
    }

    /// Nothing over the page, no page swiped across or pulled from the left
    /// edge, and its control visible: the stack answers.
    private var sourceFree: Bool {
        !covered && !app.surfaces.pageSwiping && app.backStack.swipe == nil
            && (!app.chrome.folded || app.workspace.verticalControls || app.workspace.tabletControls)
    }

    /// Another tab, without a flick: a row of the stack's menu, VoiceOver.
    func switchTo(_ id: Tab.ID) {
        guard flick == nil, gallery == nil, app.browser.space.tab(id) != nil else { return }
        app.browser.select(id)
    }

    // MARK: - the flick

    var canFlick: Bool { flick == nil && gallery == nil && previous != nil && sourceFree }

    /// A finger starts up from the stack: the previous tab's card is in hand.
    @discardableResult
    func flickBegan() -> Bool {
        guard canFlick, let target = previous, let front = app.browser.tab else { return false }
        Haptics.prepare()
        // The page being left is pictured for the stack's front card, and the
        // one coming is alive behind, to take over from its picture.
        app.pages.picture(front.id)
        app.pages.warm(target)
        flick = Flick(target: target, from: front.id, space: app.browser.spaceID)
        liftSpring.set(0)
        return true
    }

    /// The finger is `up` points over where it started.
    func flickMoved(_ up: CGFloat) {
        guard let flick, !flick.released else { return }
        guard current(flick) else { cancelFlick(animated: false); return }
        liftSpring.set(resisted(up))
    }

    /// Let go: past the commit (or thrown) the previous tab grows from the
    /// card to the page over this one; else the card goes back.
    func flickEnded(_ up: CGFloat, velocity: CGFloat) {
        typealias M = Metrics.TabStack
        guard var next = flick, !next.released else { return }
        guard current(next) else { cancelFlick(animated: false); return }
        let lift = resisted(up)
        guard lift + max(0, velocity) * M.flickProjection >= M.flickCommit else { cancelFlick(); return }
        // Decided as it is let go: felt now, not when the page has grown.
        Haptics.play(.light, reason: Haptics.Reason.flickLetGo)
        liftSpring.stop()
        next.released = true
        next.start = liftedCard(lift)
        growth = 0
        flick = next
        control?.stackView.lift = 0
        control?.stackView.arrival = 0
        growSpring.set(0)
        growSpring.animate(to: 1000, .tabFlickGrow) { [weak self] finished in
            if finished { self?.landFlick() }
        }
    }

    /// UIKit took the touch, or the page changed under it: the card goes back.
    func cancelFlick(animated: Bool = true) {
        guard let held = flick, !held.released else { return }
        guard animated else {
            liftSpring.set(0)
            flick = nil
            return
        }
        liftSpring.animate(to: 0, .tabFlickBack) { [weak self] _ in
            guard let self, self.flick == held else { return }
            self.flick = nil
        }
    }

    private func grew(_ g: CGFloat) {
        guard flick?.released == true else { return }
        growth = g
        control?.stackView.arrival = min(max((g - 0.7) / 0.3, 0), 1)
        // A hundredth short the page has landed to the eye; the tail is slow.
        if g >= 0.99 { landFlick() }
    }

    /// The page has grown: the tab changes, its live page takes over from the picture.
    private func landFlick() {
        guard let landed = flick, landed.released else { return }
        flick = nil
        growth = 0
        growSpring.stop()
        control?.stackView.arrival = 1
        guard current(landed), app.browser.space.tab(landed.target.id) != nil else { return }
        quietly { app.browser.select(landed.target.id) }
    }

    /// Named states: a flick let go, its page held `g` of the way grown.
    func holdFlick(at g: CGFloat) {
        guard flickBegan(), var held = flick else { return }
        liftSpring.stop()
        held.released = true
        held.start = liftedCard(Metrics.TabStack.liftSpan)
        flick = held
        control?.stackView.lift = 0
        growth = g
        control?.stackView.arrival = min(max((g - 0.7) / 0.3, 0), 1)
    }

    private func current(_ flick: Flick) -> Bool {
        app.browser.spaceID == flick.space && app.browser.tab?.id == flick.from && !covered
    }

    /// Up to its 60 the card follows the finger; past them it resists.
    private func resisted(_ up: CGFloat) -> CGFloat {
        typealias M = Metrics.TabStack
        if up <= 0 { return 0 }
        if up <= M.liftSpan { return up }
        return M.liftSpan + ColumnMath.rubber(up - M.liftSpan, M.liftRubber)
    }

    /// The lifted front card on the screen, before its turn: grown about its
    /// middle, `lift` up from its place on the button.
    func liftedCard(_ lift: CGFloat) -> CGRect {
        typealias M = Metrics.TabStack
        let button = stackGeometry.circle
        let rest = TabStackGeometry(button: button).front
        let grown = 1 + M.liftGrowth * min(1, lift / M.liftSpan)
        let width = rest.width * grown, height = rest.height * grown
        return CGRect(x: rest.midX - width / 2, y: rest.midY - lift - height / 2, width: width, height: height)
    }

    // MARK: - All Tabs

    /// The cards All Tabs shows now: its tabs still in the space, less the
    /// kept ones closed here (Undo brings a closed one back in its place).
    func cards(of gallery: Gallery) -> [Tab] {
        guard let space = app.browser.space(gallery.space) else { return [] }
        // Every animation frame asks for these. A search per card makes a
        // close quadratic in the number of open tabs.
        let tabs = Dictionary(space.allTabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pair = pairTabs(in: gallery)
        let hidden = pair.count == 2 ? pair.first(where: { $0.id != gallery.pair?.focused })?.id : nil
        return gallery.order.compactMap { gallery.dropped.contains($0) || $0 == hidden ? nil : tabs[$0] }
    }

    func pairTabs(in gallery: Gallery) -> [Tab] {
        guard let pair = gallery.pair, let space = app.browser.space(gallery.space),
              !pair.ids.contains(where: { gallery.dropped.contains($0) }) else { return [] }
        let tabs = pair.ids.compactMap { space.tab($0) }
        return tabs.count == 2 ? tabs : []
    }

    func pairTabs(for tab: Tab) -> [Tab] {
        guard let gallery, gallery.pair?.focused == tab.id else { return [] }
        return pairTabs(in: gallery)
    }

    /// Where All Tabs' cards and the stack's stand on this screen.
    func layout(_ gallery: Gallery) -> TabGalleryLayout {
        TabGalleryLayout(screen: screen, count: cards(of: gallery).count,
                         verticalControls: app.workspace.galleryVerticalControls, leadingRail: app.workspace.leadingRail,
                         circle: app.workspace.statusColumn ? stackGeometry.circle : nil,
                         across: app.workspace.galleryAcross)
    }
    var stackGeometry: TabStackGeometry {
        TabStackGeometry(button: ChromeGeometry(size: screen, folded: false, hasNow: app.nowItem != nil,
                                               verticalControls: app.workspace.verticalControls, leadingRail: app.workspace.leadingRail).space)
    }

    /// Card `i` (oldest 0) as All Tabs draws it now: coming, at rest (taken
    /// up by a finger, flying away), or going.
    func pose(_ i: Int, of tab: Tab, in gallery: Gallery, layout: TabGalleryLayout) -> TabCardPose {
        let stack = stackGeometry
        switch gallery.phase {
        case .opening:
            if let progress = gallery.pinchProgress {
                var pose = TabGalleryMotion.interactiveOpening(i, layout: layout, stack: stack, progress: progress)
                if i == gallery.order.count - 1 {
                    pose.rect = pose.rect.offsetBy(dx: gallery.pinchShift.width, dy: gallery.pinchShift.height)
                }
                return pose
            }
            return TabGalleryMotion.opening(i, layout: layout, stack: stack, t: gallery.time)
        case .closing:
            let from = gallery.from[tab.id] ?? TabGalleryMotion.rest(i, layout: layout, focus: gallery.focus)
            return TabGalleryMotion.closing(gallery.roles[tab.id] ?? .other, from: from, layout: layout, stack: stack, t: gallery.time)
        case .open:
            var pose = TabGalleryMotion.rest(i, layout: layout, focus: gallery.focus)
            if gallery.lifted == tab.id {
                pose.rect.origin.y += gallery.lift
                let away = Double(1 - min(max(-gallery.lift / 24, 0), 1))
                pose.icon *= away
                pose.title *= away
            }
            if let offset = gallery.flightOffsets[tab.id] {
                pose.rect.origin.y += offset
                pose.icon = 0
                pose.title = 0
            }
            return pose
        }
    }

    /// How far below its place the circle is now: it comes up from below as
    /// All Tabs closes on the top card.
    func circleOffset(_ gallery: Gallery) -> CGFloat {
        gallery.phase == .closing ? TabGalleryMotion.rise(gallery.rises, t: gallery.time) : 0
    }

    /// A stack card that doesn't fly as All Tabs closes, in the circle.
    struct SeatedCard: Identifiable {
        let tab: Tab
        let pose: TabCardPose
        var id: Tab.ID { tab.id }
    }

    /// The stack's cards that don't fly as All Tabs closes, in the circle:
    /// appearing in their places, or coming up with it.
    func seatedCards(_ gallery: Gallery, layout: TabGalleryLayout) -> [SeatedCard] {
        guard gallery.phase == .closing, let space = app.browser.space(gallery.space) else { return [] }
        let stack = stackGeometry
        return gallery.seated.compactMap { seated in
            space.tab(seated.id).map { tab in
                SeatedCard(tab: tab, pose: TabGalleryMotion.seated(seated.place, rises: gallery.rises, layout: layout, stack: stack, t: gallery.time))
            }
        }
    }

    /// The page shrinks into its card and the cards come out of the stack,
    /// once the page in front has been pictured for its card.
    func openGallery() {
        // All Tabs takes the whole spread: the spaces' column gives way.
        if app.surfaces.fieldBeside { app.field.close() }
        guard gallery == nil, flick == nil, sourceFree || pinchProgress != nil, !order.isEmpty else { return }
        let front = app.browser.tab
        let space = app.browser.spaceID
        // Every recent tab, latest in front, as the Mac's Control-Tab row has them.
        let order = self.order.reversed().map(\.id)
        if app.workspace.tabletControls, let pair = app.workspace.savedPair {
            for id in pair.ids { app.pages.picture(id) { _ in } }
        }
        let present: @MainActor () -> Void = { [weak self] in
            guard let self, self.gallery == nil, self.flick == nil, self.sourceFree || self.pinchProgress != nil,
                  !self.covered, !self.app.surfaces.pageSwiping, self.app.backStack.swipe == nil,
                  self.app.browser.spaceID == space, self.app.browser.tab?.id == front?.id else { return }
            if self.pinchEnd?.commit == false {
                self.pinchProgress = nil
                self.pinchEnd = nil
                self.pinchAnchor = nil
                self.pinchRelease = nil
                return
            }
            var next = Gallery(space: space, order: order)
            if self.app.workspace.tabletControls, let pair = self.app.workspace.savedPair,
               pair.ids.allSatisfy({ self.app.browser.space.tab($0) != nil }) {
                next.pair = pair
                for id in pair.ids where !next.order.contains(id) { next.order.insert(id, at: 0) }
            }
            next.focus = self.layout(next).initialFocus
            self.gallery = next
            if self.app.surfaces.statusBarLight == nil {
                self.app.surfaces.statusBarLight = TabGalleryGround.isDark(self.app)
                self.litStatusBar = true
            }
            // The circle and its cards are All Tabs' now (TabGalleryLayer).
            self.control?.lent = true
            if let progress = self.pinchProgress {
                self.updatePinch(progress)
                if let end = self.pinchEnd { self.finishPinch(commit: end.commit, velocity: end.velocity) }
                return
            }
            self.clock.run(.tabsOpen, for: TabGalleryTiming.openDuration) { [weak self] t in
                self?.openedFor(t)
            } end: { [weak self] in
                self?.opened()
            }
        }
        // The empty page has no picture to shrink into a card.
        if let front { app.pages.picture(front.id) { _ in present() } } else { present() }
    }

    private func openedFor(_ t: Double) {
        guard gallery?.phase == .opening else { return }
        gallery?.time = t
        app.surfaces.chromeOpacity = Double(1 - TabGalleryTiming.barProgress(t))
    }

    private func opened() {
        guard gallery?.phase == .opening else { return }
        gallery?.phase = .open
        gallery?.time = 0
        gallery?.pinchProgress = nil
        gallery?.pinchShift = .zero
        pinchProgress = nil
        pinchEnd = nil
        pinchAnchor = nil
        pinchRelease = nil
        app.surfaces.chromeOpacity = 0
        refreshWarmup()
    }

    /// Named states: All Tabs held `t` seconds into opening.
    func holdOpening(at t: Double) {
        guard gallery != nil else { return }
        clock.stop()
        gallery?.phase = .opening
        openedFor(t)
    }

    /// A card tapped: its tab comes in front under it at once, and the card
    /// grows into its page while the cards lying on it fly into the circle
    /// and the others go (TabGalleryMotion.Closing). `held` keeps it there
    /// (named states).
    func choose(_ id: Tab.ID, heldAt held: Double? = nil) {
        guard var next = gallery, next.phase != .closing else { return }
        let cards = cards(of: next)
        guard let chosen = cards.firstIndex(where: { $0.id == id }) else { return }
        stopGalleryGestures()
        // Pages warming up go now; one for the card tapped comes in front.
        warmup.stop(keeping: id)
        let layout = layout(next)
        let plan = TabGalleryMotion.Closing(count: cards.count, chosen: chosen, stack: !app.workspace.tabletControls)
        var from: [Tab.ID: TabCardPose] = [:]
        for (i, tab) in cards.enumerated() { from[tab.id] = pose(i, of: tab, in: next, layout: layout) }
        next.barFrom = next.bar
        next.phase = .closing
        next.time = 0
        next.chosen = id
        next.from = from
        next.roles = Dictionary(uniqueKeysWithValues: zip(cards.map(\.id), plan.roles))
        next.seated = plan.seated.map { Gallery.Seated(id: cards[$0.index].id, place: $0.place) }
        next.rises = plan.rises
        next.stacked = plan.front != nil
        next.lifted = nil
        next.lift = 0
        clock.stop()
        chromeFrom = app.surfaces.chromeOpacity
        gallery = next
        if app.workspace.tabletControls, let pair = next.pair, !pair.ids.contains(id) { app.workspace.leaveSplit() }
        if app.browser.tab?.id != id { quietly { app.browser.select(id) } }
        if app.workspace.tabletControls { app.reconcileWorkspace() }
        if let held {
            closedFor(held)
            return
        }
        clock.run(.tabsCardOpen, for: TabGalleryTiming.closeDuration) { [weak self] t in
            self?.closedFor(t)
        } end: { [weak self] in
            self?.dismissGallery()
        }
    }

    /// A tap on the ground: back to the tab in front, its card growing back.
    func chooseFront() {
        guard let shown = gallery else { return }
        let cards = cards(of: shown)
        if let front = app.browser.tab?.id {
            if cards.contains(where: { $0.id == front }) { choose(front) }
            else { dismissGallery() } // A kept page stays in front outside the mobile Today gallery.
        }
        else if let newest = cards.last { choose(newest.id) }
        else { dismissGallery() }
    }

    private func closedFor(_ t: Double) {
        guard gallery?.phase == .closing else { return }
        gallery?.time = t
        let bar = Double(TabGalleryTiming.barProgress(t))
        app.surfaces.chromeOpacity = chromeFrom + (1 - chromeFrom) * bar
        if litStatusBar, TabGalleryTiming.cardToPage.value(t) > 0.5 {
            litStatusBar = false
            app.surfaces.statusBarLight = nil
        }
    }

    /// Gone, the page and the chrome as they are, the stack showing its cards.
    func dismissGallery() {
        guard gallery != nil else { return }
        toSidebar = false
        stopGalleryGestures()
        warmup.stop()
        touching = false
        clock.stop()
        leavingForField?.cancel()
        leavingForField = nil
        gallery = nil
        if litStatusBar {
            litStatusBar = false
            app.surfaces.statusBarLight = nil
        }
        app.surfaces.chromeOpacity = 1
        control?.lent = false
        // Pictures All Tabs drew may go now, past the memory's limit.
        store.trim()
    }

    /// A finger moves the cards sideways: the card at the focus, already
    /// resisted past the ends.
    func scrollGallery(to focus: CGFloat) {
        guard gallery?.phase == .open else { return }
        scrollSpring.stop()
        touching = true
        gallery?.focus = focus
    }

    /// Let go of a scroll: the cards glide on to the card nearest where the
    /// finger threw them, never past the first or the last.
    func settleScroll(_ projected: CGFloat, velocity: CGFloat = 0) {
        touching = false
        guard let shown = gallery, shown.phase == .open else { return }
        let end = min(max(projected.rounded(), 0), layout(shown).maxFocus)
        scrollStep = layout(shown).step
        scrollSpring.set(shown.focus * scrollStep)
        scrollSpring.animate(to: end * scrollStep, .tabsScroll, velocity: velocity) { [weak self] finished in
            if finished { self?.refreshWarmup() }
        }
    }

    /// A finger takes a card up (dy negative); down it hardly moves.
    func liftCard(_ id: Tab.ID, by dy: CGFloat) {
        guard var next = gallery, next.phase == .open,
              cards(of: next).contains(where: { $0.id == id }) else { return }
        cardSpring.stop()
        flights.removeValue(forKey: id)?.stop()
        next.leaving.remove(id)
        next.flightOffsets.removeValue(forKey: id)
        next.lifted = id
        next.lift = dy < 0 ? dy : ColumnMath.rubber(dy, Metrics.TabGallery.rubber) * 0.3
        gallery = next
    }

    /// Let go of a card: up far enough (or thrown) it closes, else it goes back.
    func releaseCard(_ id: Tab.ID, dy: CGFloat, velocity: CGFloat) {
        typealias G = Metrics.TabGallery
        guard gallery?.lifted == id else { return }
        if -(dy + velocity * G.closeProjection) >= G.closeDistance {
            closeCard(id, velocity: velocity)
        } else {
            cardSpring.set(gallery?.lift ?? 0)
            cardSpring.animate(to: 0, .tabsCardBack, velocity: velocity) { [weak self] finished in
                guard finished, let self, self.gallery?.lifted == id else { return }
                self.gallery?.lifted = nil
            }
        }
    }

    /// Close: the card flies up and its tab closes (today's, the toast
    /// offering it back as the spaces' Close does), or leaves the open tabs
    /// (a kept or pinned one, which stays where it is kept); the other cards
    /// close the gap. The last one closed leaves the empty page, with Undo.
    func closeCard(_ id: Tab.ID, velocity: CGFloat = 0) {
        guard let shown = gallery, shown.phase == .open, !shown.leaving.contains(id),
              cards(of: shown).contains(where: { $0.id == id }) else { return }
        Haptics.play(.soft, reason: Haptics.Reason.cardThrown)
        let layout = layout(shown)
        let index = cards(of: shown).firstIndex(where: { $0.id == id })!
        let start = shown.lifted == id ? shown.lift : 0
        if shown.lifted == id { gallery?.lifted = nil; gallery?.lift = 0 }
        gallery?.leaving.insert(id)
        gallery?.flightOffsets[id] = start
        let flight = TabCardFlight(TabCardTrajectory(start: start, velocity: velocity,
                                                     bottom: layout.card(index, focus: shown.focus).maxY)) { [weak self] offset in
            self?.gallery?.flightOffsets[id] = offset
        } completion: { [weak self] in
            self?.flights.removeValue(forKey: id)
            self?.removeCard(id)
        }
        flights[id] = flight
        flight.run()
        // Even the last card can be caught. Search waits until it has left.
    }

    private func removeCard(_ id: Tab.ID) {
        guard let shown = gallery else { return }
        scrollSpring.stop()
        let before = cards(of: shown)
        guard let index = before.firstIndex(where: { $0.id == id }) else { return }
        let wasFront = app.browser.tab?.id == id
        var closed: ClosedTab?
        Motion.tabsReflow.run {
            if shown.pair?.focused == id {
                gallery?.pair = nil
                app.workspace.fullSpread()
            }
            closed = closeTab(id, in: shown.space)
            gallery?.leaving.remove(id)
            gallery?.flightOffsets.removeValue(forKey: id)
            if gallery?.lifted == id { gallery?.lifted = nil; gallery?.lift = 0 }
            // The card at the focus stays there; the focus card closed, the
            // next older one comes to the focus, the tab in front still beside it.
            if let focus = gallery?.focus {
                let kept = CGFloat(index) <= focus ? focus - 1 : focus
                gallery?.focus = min(max(kept, 0), CGFloat(max(0, before.count - 2)))
            }
        }
        let rest = gallery.map { cards(of: $0) } ?? []
        guard let newest = rest.last else {
            // A pin or a kept tab in front lets go of the page too.
            if app.browser.spaceID == shown.space, let front = app.browser.tab { app.browser.letGo(of: front.id) }
            Motion.tabsReflow.run { dismissGallery() }
            // Nothing left to look at: search, at once.
            if app.surfaces.field == nil { app.openNewTab() }
            if let closed { app.backStack.offer(closed) }
            return
        }
        // The tab in front closed: the newest left takes its place under the cards.
        if wasFront || !(app.browser.tab.map { front in rest.contains { $0.id == front.id } } ?? false) {
            quietly { app.browser.select(newest.id) }
        }
        if let closed { app.backStack.offer(closed) }
        // The cards closed the gap: another may need its picture now.
        refreshWarmup()
    }

    /// Today's tab closes, remembered for Undo (Back/BackStack); a kept or
    /// pinned one only leaves the open tabs.
    private func closeTab(_ id: Tab.ID, in space: Space.ID) -> ClosedTab? {
        guard let tab = app.browser.space(space)?.tab(id) else { return nil }
        guard tab.place == .today else {
            recency.drop(id, in: space)
            save()
            gallery?.dropped.insert(id)
            // The saved entry stays, but its dismissed page must stop playing.
            app.pages.forget(id)
            return nil
        }
        let closed = app.backStack.remember(id)
        app.browser.close(id)
        app.pages.forget(id)
        return closed
    }

    /// Switch the visible gallery without closing either space's tabs.
    func selectGallerySpace(_ id: Space.ID) {
        guard let shown = gallery, shown.phase == .open, shown.space != id, shown.leaving.isEmpty,
              shown.lifted == nil, !app.workspace.tabletControls, app.browser.space(id)?.isPrivate == false else { return }
        warmup.stop()
        clock.stop()
        touching = false
        app.browser.showSpace(id)
        if litStatusBar { app.surfaces.statusBarLight = TabGalleryGround.isDark(app) }
        let order = TabRecency.order(of: app.browser.space, recent: recency.recent(in: id)).reversed().map(\.id)
        var next = Gallery(space: id, order: order)
        next.phase = .open
        next.focus = layout(next).initialFocus
        // The new space's cards come in beside the old ones' place, following
        // the capsule's lens to its name (TabGalleryLayer.pageShift).
        pagedAt = CACurrentMediaTime()
        gallery = next
        refreshWarmup()
    }

    /// New Tab from All Tabs' +: the field grows from it, over the cards,
    /// which go once it has (watchSurfaces).
    func galleryNewTab(from origin: CGRect) {
        guard let shown = gallery, shown.phase != .closing else { return }
        app.openNewTab(from: origin)
    }

    /// Chats from All Tabs' left button: the spaces on their Chats page, grown
    /// from it over the cards, which go once they have (watchSurfaces).
    func galleryChats(from origin: CGRect) {
        guard let shown = gallery, shown.phase == .open else { return }
        NewTabPager.shared.startAt = NewTabPager.chatsPage
        app.openNewTab(from: origin)
    }

    /// The spaces sidebar from All Tabs' computer button: the plate's swipe up,
    /// on the space the gallery shows; the cards go once it has (watchSurfaces).
    func gallerySidebar(from origin: CGRect) {
        guard let shown = gallery, shown.phase == .open, !toSidebar else { return }
        Haptics.play(.light, reason: Haptics.Reason.columnOpened)
        app.chrome.unfold()
        // The sidebar's pages start on the gallery's space, its capsule's lens where it is.
        let pages = [NewTabPager.chatsPage] + app.browser.spaces.filter { !$0.isPrivate }.map(\.id)
        let pager = NewTabPager.shared
        pager.startAt = shown.space
        pager.spaceID = shown.space
        pager.onChats = false
        if let i = pages.firstIndex(of: shown.space) { pager.position = CGFloat(i) }
        // In place: the controls stay, the cards blur out as the space blurs in.
        app.field.sidebarBlur = 1
        app.field.openSpacesInPlace()
        let turn = Motion.disabled ? nil : Animation.easeOut(duration: Motion.plusToField.duration)
        withAnimation(turn) {
            toSidebar = true
            app.field.sidebarBlur = 0
        }
    }

    /// Settings from All Tabs' gear, over the cards (watchSurfaces keeps them).
    func gallerySettings() {
        guard let shown = gallery, shown.phase == .open else { return }
        Haptics.play(.soft, reason: Haptics.Reason.settingsOpen)
        Motion.sheetGrow.run { app.surfaces.openSettings() }
    }

    private func quietly(_ change: () -> Void) {
        var quiet = Transaction(animation: nil)
        quiet.disablesAnimations = true
        withTransaction(quiet, change)
    }

    // MARK: - pictures

    /// After a page in front drew, it is pictured once it has settled: its
    /// images and fonts come a little after. Tried again while a finger moves it.
    static let settle: Duration = .milliseconds(800)
    static let settleTries = 4
    /// Pictures of closed tabs leave the disk this soon after.
    static let pruneDelay: Duration = .seconds(2)

    /// The pool pictured a tab's whole page (leaving it, All Tabs, the
    /// flick): the cards draw it, and a card's size of it is kept.
    private func pictured(_ id: Tab.ID) {
        pictures += 1
        guard let image = app.pages.snapshots[id] else { return }
        keep(image, for: id)
    }

    /// Into the store: a private tab's in memory only, never as Private locks.
    private func keep(_ image: UIImage, for id: Tab.ID) {
        guard app.browser.tab(id) != nil else { return }
        let shy = isPrivate(id)
        if shy, app.privateLock.requiresAuthentication, app.privateLock.phase != .unlocked { return }
        store.keep(image, for: id, isPrivate: shy)
    }

    private func isPrivate(_ id: Tab.ID) -> Bool {
        app.browser.tab(id)?.isPrivate == true || app.browser.space(holding: id)?.isPrivate == true
    }

    /// The page in front loaded and drew: once it has settled, its card's
    /// picture. Never while a finger scrolls or pages it, or All Tabs or the
    /// flick is up (they picture it themselves), so it stays off those paths.
    private func painted(_ id: Tab.ID) {
        guard id == app.pages.front, !app.pages.isBorrowed(id) else { return }
        settling?.cancel()
        settling = Task { @MainActor [weak self] in
            for _ in 0..<Self.settleTries {
                try? await Task.sleep(for: Self.settle)
                guard !Task.isCancelled, let self, self.app.pages.front == id, self.app.pages.painted.contains(id) else { return }
                guard self.quiet(id) else { continue }
                if let image = await self.cardPicture(id, afterScreenUpdates: true) { self.keep(image, for: id) }
                return
            }
        }
    }

    /// Nothing moves or covers the page in front.
    private func quiet(_ id: Tab.ID) -> Bool {
        guard gallery == nil, flick == nil, !app.surfaces.pageSwiping, app.backStack.swipe == nil,
              let scroll = app.pages.liveView(id)?.scrollView else { return false }
        return !scroll.isTracking && !scroll.isDragging && !scroll.isDecelerating
    }

    /// Yab goes away: the page in front as it is now, for its card after the
    /// next launch (written before iOS suspends Yab). Private's stay out.
    func resigning() {
        guard let front = app.browser.tab, front.id == app.pages.front, !isPrivate(front.id) else { return }
        let application = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = application.beginBackgroundTask(withName: "Tab picture") {
            if task != .invalid { application.endBackgroundTask(task); task = .invalid }
        }
        Task { @MainActor [weak self] in
            if let self, let image = await self.cardPicture(front.id, afterScreenUpdates: false) {
                self.keep(image, for: front.id)
                await self.store.settled()
            }
            if task != .invalid { application.endBackgroundTask(task); task = .invalid }
        }
    }

    /// A card's picture of a tab's live page (WebPool.cardPicture): from the
    /// screen's top to the chrome's row, as wide as All Tabs' widest card.
    func cardPicture(_ id: Tab.ID, afterScreenUpdates: Bool, unpainted: Bool = false) async -> UIImage? {
        guard let view = app.pages.liveView(id), view.bounds.width > 0 else { return nil }
        let layout = TabGalleryLayout(screen: view.bounds.size, count: 0)
        let rect = CGRect(x: 0, y: 0, width: view.bounds.width, height: min(view.bounds.height, layout.page.height))
        return await withCheckedContinuation { (done: CheckedContinuation<UIImage?, Never>) in
            let begun = CACurrentMediaTime()
            app.pages.cardPicture(id, rect: rect, width: layout.pictureWidth, afterScreenUpdates: afterScreenUpdates,
                                  unpainted: unpainted) { done.resume(returning: $0) }
            // What the call itself held the main thread for (without
            // afterScreenUpdates WebKit draws the picture inside it).
            captureCalls.append((CACurrentMediaTime() - begun) * 1000)
            if captureCalls.count > 64 { captureCalls.removeFirst(captureCalls.count - 64) }
        }
    }

    /// Pictures of tabs gone (closed here, by Clear, or on the Mac) leave
    /// the disk soon after; in memory they wait for Undo (TabPictures.prune).
    private func watchTabs() {
        let ids = withObservationTracking { Set(app.browser.allTabs.map(\.id)) } onChange: { [weak self] in
            Task { @MainActor in self?.watchTabs() }
        }
        pruning?.cancel()
        pruning = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.pruneDelay)
            while !Task.isCancelled {
                guard let self, self.store.prune(keeping: ids) else { return }
                try? await Task.sleep(for: .seconds(TabPictures.closedFor))
            }
        }
    }

    /// Private locks (Open with Face ID): its pictures go, the pool's too.
    private func watchPrivateLock() {
        let locked = withObservationTracking { app.privateLock.phase == .locked } onChange: { [weak self] in
            Task { @MainActor in self?.watchPrivateLock() }
        }
        guard locked, app.privateLock.requiresAuthentication else { return }
        store.dropPrivate()
        app.pages.forgetPictures(private: true)
        pictures += 1
    }

    /// Clear History and Website Data: ordinary tabs' pictures go, kept and
    /// the pool's; the cards warm up again from the cleared pages.
    func forgetPictures() {
        store.clear()
        app.pages.forgetPictures(private: false)
        pictures += 1
    }

    // MARK: - the warm-up

    /// The cards All Tabs draws that have no picture at all, nearest the focus first.
    func needingPictures(_ shown: Gallery) -> [Tab] {
        let cards = cards(of: shown), layout = layout(shown)
        var needed = cards.indices
            .filter { layout.draws($0, focus: shown.focus) && !hasPicture(cards[$0]) && !TabRecency.isEmpty(cards[$0]) }
            .sorted { abs(layout.depth($0, focus: shown.focus)) < abs(layout.depth($1, focus: shown.focus)) }
            .map { cards[$0] }
        if let pair = shown.pair, cards.contains(where: { $0.id == pair.focused }) {
            let known = Set(needed.map(\.id))
            needed += pairTabs(in: shown).filter { !known.contains($0.id) && !hasPicture($0) }
        }
        return needed
    }

    private func refreshWarmup() {
        guard warmsUp, let shown = gallery, shown.phase == .open else { return }
        warmup.start(needingPictures(shown))
    }

    /// All Tabs is up and no finger is on its cards.
    private var still: Bool {
        guard let shown = gallery else { return false }
        return shown.phase == .open && shown.lifted == nil && !touching && !scrollSpring.isMoving && flights.isEmpty
    }

    private func stopGalleryGestures() {
        scrollSpring.stop()
        cardSpring.stop()
        pinchSpring.stop()
        pinchProgress = nil
        pinchEnd = nil
        pinchAnchor = nil
        pinchRelease = nil
        for flight in flights.values { flight.stop() }
        flights.removeAll()
    }

    var canPinchGallery: Bool {
        gallery == nil && flick == nil && !covered && !app.surfaces.pageSwiping
            && app.backStack.swipe == nil && !order.isEmpty
    }

    func beginPinch(at anchor: CGPoint? = nil) {
        guard canPinchGallery else { return }
        pinchProgress = 0
        pinchEnd = nil
        pinchAnchor = anchor
        pinchFinger = .zero
        pinchRelease = nil
        openGallery()
    }

    /// A finger up from the plate, `finger` from where it touched: the page
    /// shrinks toward its card as it rises, held where the finger holds it.
    func followPinch(_ finger: CGSize, span: CGFloat) {
        guard pinchProgress != nil, pinchEnd == nil else { return }
        pinchFinger = CGSize(width: finger.width, height: min(finger.height, 0))
        updatePinch(-pinchFinger.height / span)
    }

    /// Where the front card stands off its path at `progress`: the point of
    /// the page the finger took stays under the finger; let go, that offset
    /// fades as the spring carries the card home (or back to the page).
    private func pinchShift(_ progress: CGFloat) -> CGSize {
        if let release = pinchRelease {
            let k: CGFloat
            if let end = pinchEnd, end.commit {
                k = release.progress >= 1 ? 0 : max(0, (1 - progress) / (1 - release.progress))
            } else {
                k = release.progress <= 0 ? 0 : max(0, progress / release.progress)
            }
            return CGSize(width: release.shift.width * min(k, 1), height: release.shift.height * min(k, 1))
        }
        guard let anchor = pinchAnchor, let shown = gallery, !shown.order.isEmpty else { return .zero }
        let layout = layout(shown)
        let n = shown.order.count
        let path = TabGalleryMotion.interactiveOpening(n - 1, layout: layout, stack: stackGeometry, progress: progress).rect
        let page = layout.page
        guard page.width > 0, page.height > 0 else { return .zero }
        let fx = (anchor.x - page.minX) / page.width, fy = (anchor.y - page.minY) / page.height
        let finger = CGPoint(x: anchor.x + pinchFinger.width, y: anchor.y + pinchFinger.height)
        let x = finger.x - (fx - 0.5) * path.width, y = finger.y - (fy - 0.5) * path.height
        return CGSize(width: x - path.midX, height: y - path.midY)
    }

    func updatePinch(_ progress: CGFloat) {
        guard pinchProgress != nil else { return }
        let p = min(max(progress, 0), 1)
        pinchProgress = p
        guard gallery?.phase == .opening else { return }
        guard !Motion.reduced else { return }
        let shift = pinchShift(p)
        gallery?.pinchProgress = p
        gallery?.pinchShift = shift
        app.surfaces.chromeOpacity = Double(1 - p)
    }

    func endPinch(velocity: CGFloat, cancelled: Bool) {
        guard let progress = pinchProgress else { return }
        let commit = !cancelled && progress + velocity * 0.15 >= Metrics.TabGallery.pinchCommit
        pinchEnd = (commit, velocity)
        pinchRelease = (gallery?.pinchShift ?? .zero, progress)
        if gallery != nil { finishPinch(commit: commit, velocity: velocity) }
    }

    private func finishPinch(commit: Bool, velocity: CGFloat) {
        if Motion.reduced {
            clock.run(.tabsOpen, for: TabGalleryTiming.openDuration, tick: { _ in }) { [weak self] in
                if commit { self?.opened() } else { self?.dismissGallery() }
            }
            return
        }
        pinchSpring.set((pinchProgress ?? 0) * 1000)
        pinchSpring.animate(to: commit ? 1000 : 0, .tabsOpen, velocity: velocity * 1000) { [weak self] finished in
            guard finished, let self else { return }
            if commit { self.opened() } else { self.dismissGallery() }
        }
    }

    /// One card's page loaded out of sight under the cards, pictured as soon
    /// as it drew (or as far as it got), and let go.
    private func warm(_ tab: Tab) async -> TabWarmup.Outcome {
        guard let stage, stage.window != nil, gallery?.phase == .open else { return .failed }
        // The page in front, under All Tabs (opened before it drew): pictured where it is.
        if app.pages.front == tab.id {
            await app.pages.waitUntilPainted(tab.id, timeout: TabWarmup.paintTimeout)
            guard !Task.isCancelled, let image = await cardPicture(tab.id, afterScreenUpdates: true) else { return .failed }
            keep(image, for: tab.id)
            return .pictured
        }
        guard let view = app.pages.borrow(tab) else { return .noRoom }
        stage.show(view)
        let begun = CACurrentMediaTime()
        await app.pages.waitUntilPainted(tab.id, timeout: TabWarmup.paintTimeout)
        guard !Task.isCancelled, app.pages.isBorrowed(tab.id) else { return .failed }
        let image = await cardPicture(tab.id, afterScreenUpdates: true, unpainted: true)
        guard !Task.isCancelled, app.pages.isBorrowed(tab.id) else { return .failed }
        letGoWarm(tab.id, keep: false)
        guard let image else { return .failed }
        keep(image, for: tab.id)
        warmTimes.append(CACurrentMediaTime() - begun)
        return .pictured
    }

    /// A warmed page goes back to the pool: let go, or kept alive in front.
    private func letGoWarm(_ id: Tab.ID, keep: Bool) {
        if !keep { stage?.remove(app.pages.liveView(id)) }
        app.pages.giveBack(id, keep: keep)
    }
}

/// All Tabs' clock: the seconds since the tap, told every frame (as the
/// frame will show), until `duration`. Its run sits in the Motion's signpost;
/// with motion off it ends at once, and under Reduce Motion the window
/// cross-fades to the end instead (the plan's rule for every morph).
@MainActor
final class TabGalleryClock: NSObject {
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var duration: Double = 0
    private var tick: ((Double) -> Void)?
    private var end: (() -> Void)?
    private var name: StaticString = "tabsOpen"
    private var signpost: OSSignpostIntervalState?

    static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
    }

    func run(_ motion: Motion, for duration: Double, tick: @escaping (Double) -> Void, end: @escaping () -> Void) {
        stop()
        if Motion.disabled {
            tick(duration)
            end()
            return
        }
        if Motion.reduced {
            let fade = MotionSignposts.begin("fade", motion: motion.name, expected: Motion.fadeDuration)
            guard let window = Self.window else {
                tick(duration); end()
                MotionSignposts.end("fade", fade, motion: motion.name)
                return
            }
            UIView.transition(with: window, duration: Motion.fadeDuration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                tick(duration)
                end()
            } completion: { _ in
                MainActor.assumeIsolated { MotionSignposts.end("fade", fade, motion: motion.name) }
            }
            return
        }
        self.duration = duration
        self.tick = tick
        self.end = end
        name = motion.name
        signpost = MotionSignposts.begin(motion.name, expected: duration)
        start = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        tick(0)
    }

    var isRunning: Bool { link != nil }

    /// Stops where it is, without its end.
    func stop() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        MotionSignposts.end(name, signpost)
        signpost = nil
        tick = nil
        end = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let t = link.targetTimestamp - start
        guard t < duration else {
            let tick = self.tick, end = self.end
            stop()
            tick?(duration)
            end?()
            return
        }
        tick?(t)
    }
}
