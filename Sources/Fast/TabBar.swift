import SwiftUI

/// Cheap counters in probe worlds, so strip animation checks can tell which
/// views were recomputed instead of inferring it from frame timing alone.
@MainActor
enum StripRenderMeter {
    private static let enabled = Store.testing
    private(set) static var bars = 0
    private(set) static var innerTabs = 0
    private(set) static var outerTabs = 0
    private(set) static var folders = 0
    /// The window's own view drawn again, all of it (ContentView).
    private(set) static var windows = 0

    static func reset() { bars = 0; innerTabs = 0; outerTabs = 0; folders = 0; windows = 0 }
    static func bar() { if enabled { bars += 1 } }
    static func window() { if enabled { windows += 1 } }
    static func tab(inner: Bool) {
        guard enabled else { return }
        if inner { innerTabs += 1 } else { outerTabs += 1 }
    }
    static func folder() { if enabled { folders += 1 } }
    static var report: [String: Int] {
        ["bar": bars, "innerTabs": innerTabs, "outerTabs": outerTabs, "folders": folders, "window": windows]
    }
}

/// The only chrome there is. Titles, one of them in a gray pill. The pill is
/// on the tab you picked the moment you pick it, a state, not a journey.
struct TabBar: View {
    @Environment(\.tabTitleSize) private var titleSize
    @ObservedObject var browser: Browser
    /// An agent's task on many tabs: one pill, a folder (AgentFolders).
    /// Watched: every window's folders tell the first window's
    /// (Folders.init(sharing:)); this window's are read.
    @ObservedObject private var watched = Folders.shared
    private var folders: Folders { browser.folderBook }

    /// The views laid under the pins ahead and the run, which the tabs in
    /// them are taken to the window through (KeySky.Anchor).
    @State private var aheadAnchor = KeySky.Anchor(.ahead)
    @State private var runAnchor = KeySky.Anchor(.run)
    /// Which tab is under the hand, where it started, and how far it has come.
    @State private var dragging: Tab.ID?
    @State private var from = 0
    @State private var travel: CGFloat = 0
    /// Where the pointer is along the run, and where in the tab it took hold.
    @State private var pointer: CGFloat = 0
    @State private var grab: CGFloat = 0
    /// Where in the tab it is held as drawn: the grip, or a square's middle
    /// once it has folded into a pin, sprung between the two, on its own,
    /// so the pointer can keep moving the tab while it changes shape.
    @State private var grabAt: CGFloat = 0
    /// Where the held tab would go if let go now, and whether as a pin.
    /// Nothing is reordered while the hand is on it: the others step aside
    /// to show where it would land, the row changes once, on letting go.
    /// Reordering underneath the drag had the held tab's place spring one
    /// way while the hand pulled it another, and it shook.
    @State private var plan: Plan?
    /// The one just let go of, and what is left of its way to its place.
    @State private var resting: Tab.ID?
    @State private var rest: CGFloat = 0
    /// The tab carried down over the pages (SplitDeck): it stays where it
    /// was in the row, a step quieter, while the deck has it.
    @State private var decked: Tab.ID?
    /// The tab taken out past the window's edge (TearOff): it stays where
    /// it was in the row, a step quieter, while its picture is outside.
    @State private var torn: Tab.ID?
    /// A shut folder of yours the hand opened by staying over its pill, to
    /// shut again if it leaves; a pill the held tab stayed over, to make a
    /// folder of the two (Kept.swift); and their clocks.
    @State private var sprung: UUID?
    @State private var combine: Tab.ID?
    @State private var choice: TabDropChoice?
    @State private var dragCancelled = false
    @State private var movingWindow = false
    @State private var choicePreviousActive: Tab.ID?
    @State private var clocks = Clocks()
    /// A folder lifted by its pill: all its tabs fold under it while the
    /// other kept pills make room for the folder as one thing.
    @State private var carrying: NestCarry?
    @State private var carryTravel: CGFloat = 0
    @State private var carryResting: String?
    @State private var carryRest: CGFloat = 0
    /// Picked loose tabs travel together, in their original order.
    @State private var groupIDs: [Tab.ID] = []
    /// One of the pins every space shares, ahead of the capsule, in the
    /// hand: where it was, how far it has come, where it would land among
    /// them, or past the capsule among the space's tabs, unpinned; the one
    /// just let go and what is left of its way.
    @State private var aheadHeld: Tab.ID?
    @State private var aheadFrom = 0
    @State private var aheadTravel: CGFloat = 0
    @State private var aheadGoal = 0
    @State private var aheadOut = false
    @State private var aheadResting: Tab.ID?
    @State private var aheadRest: CGFloat = 0
    /// Frozen while a tab or folder is in the hand.
    @State private var heldWidths: StripWidths?

    private struct NestCarry {
        let nest: Nest
        let start: CGFloat
        let grip: CGFloat
        let each: CGFloat
        let slots: [(key: Int, value: CGFloat)]
        var index: Int
        /// The folder of yours it lands in there, and a shut one it is
        /// over, to go in at that one's end (Folders.NestLanding).
        var parent: UUID?
        var into: UUID?
        /// One of today's, where it goes among them.
        var gap: Folders.TodayLanding?
    }

    @MainActor
    private final class Clocks {
        var spring: DispatchWorkItem?
        var springFor: UUID?
        var dwell: DispatchWorkItem?
        var hold: DispatchWorkItem?
        var escape: Any?

        isolated deinit {
            if let escape { NSEvent.removeMonitor(escape) }
        }

        func stop() {
            spring?.cancel()
            spring = nil
            springFor = nil
            hold?.cancel()
            hold = nil
            dwell?.cancel()
            dwell = nil
        }
    }

    private struct Plan: Equatable {
        var index: Int
        var pinned: Bool
        /// Taken out of an agent's folder, and so yours (Folders.landing).
        var out = false
        /// Before the stroke, kept, and in which folder of yours; over a
        /// shut one of yours, into it (Kept.swift).
        var kept = false
        var nest: UUID?
        var into: UUID?

        /// The same, as a landing among the loose tabs.
        func landing(pins: Int, slot: Int) -> Folders.Landing {
            Folders.Landing(index: index - pins, slot: slot, out: out, kept: kept, nest: nest, into: into)
        }
    }

    /// True while a hand is on a tab. A drag the system breaks off, the
    /// window losing focus mid-way, never says it ended; this going false
    /// with a tab still held is how that is noticed, and put right.
    @GestureState private var holding = false
    @State private var landing = false
    /// The plus only comes out when the pointer is in the row.
    @State private var nearby = false
    @State private var plussed = false
    /// How wide the doors at the far end are, extension buttons included.
    @State private var doors: CGFloat = 0
    @Environment(\.tone) private var tone

    /// Full screen has none of ours: the lights are macOS's own, in the
    /// title bar it brings down with the menu bar.
    private var lit: Bool { !browser.fullScreen }

    /// The row's start moves on the turn's spring when the space changes.
    private var slides: Bool { !(reduceMotion || SpaceTurn.still || !StripTurn.swiftUI("slide")) }

    /// Where the row starts: after the lights, or, without them, just in
    /// from the edge.
    /// The capsule's width is the space on screen's, and the row moves on
    /// with it, on its curve (LeadSlide). Ahead of the capsule, the pins
    /// every space shares.
    private var lead: CGFloat { corner + (browser.spacesShown ? aheadWidth + capsuleWidth + CapsulePlan.stripAfter : 0) }
    /// The space on screen's, in the switch's own pass: the capsule's plate
    /// and the tabs after it are laid out for it at once and drawn there on
    /// the turn's spring (CapsulePlate, LeadSlide). Laid a frame behind, as
    /// it was, the strip took a whole second pass of the window each switch.
    private var capsuleWidth: CGFloat { CapsulePlan.strip(name: browser.space.name).width ?? 0 }

    /// The pins every space shares, while the space on screen shows them:
    /// first in the strip, then the space's capsule, then its own tabs, the
    /// capsule parting what is in every space from what is in this one
    /// (docs/shared-pins.md). They lead the row, and the run leaves them out.
    private var ahead: [Tab] {
        guard browser.spacesShown, browser.showsShared(browser.spaceID) else { return [] }
        return Array(browser.tabs.prefix { $0.everywhere != nil })
    }
    private static var pinStride: CGFloat { Metrics.pinWidth + Metrics.tabGap }
    /// The stroke between the kept and today's: only with something kept to
    /// part them from, a kept tab or an empty folder of yours, as `layout`
    /// and the coming row (StripItem) lay it. The column's line heads
    /// today's tabs always, as Arc's does (Folders.lined), but across the
    /// top, with nothing before it, it stood alone after the reload button
    /// (feedback #87).
    private var stroked: Bool {
        guard folders.lined, browser.tabs.contains(where: { $0.pin == nil && !$0.kept }) else { return false }
        return !folders.empties.isEmpty || browser.tabs.dropFirst(ahead.count).contains { $0.pin == nil && $0.kept }
    }
    /// The pins ahead of the capsule and the stroke after them, one being
    /// edited grown into its field.
    private var aheadWidth: CGFloat {
        let pins = ahead
        guard !pins.isEmpty else { return 0 }
        let editing = pins.contains { $0.id == browser.editingTab } ? Self.fieldRoom - Metrics.pinWidth : 0
        return CGFloat(pins.count) * Self.pinStride + KeptDivider.width + Metrics.tabGap + editing
    }
    /// A pin ahead of the capsule edited as an address: the field it grows
    /// into, whatever the strip's width, which is worked out from it.
    private static let fieldRoom: CGFloat = 340
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the row would start with no space's icon before it.
    /// The doors, when here, start just past the lights, with no room kept
    /// for the book: it is in the address bar's band, or reached by ⌥⌘R.
    private var corner: CGFloat {
        if browser.bandDoors { return lit ? Metrics.lights : 12 }
        return (lit ? Metrics.helmLead : 12) + Metrics.helm + Metrics.tabGap
    }

    var body: some View {
        let _ = StripRenderMeter.bar()
        // A GeometryReader is only here to measure the width. Its content is
        // put in a stack of its own and told to fill it: left to itself a
        // reader pins whatever it holds to the top corner, which is the row
        // riding at the very top of the strip while the traffic lights center
        // themselves halfway down it.
        GeometryReader { geo in
            let widths = heldWidths ?? self.widths(in: geo.size.width)
            let content = self.content(in: geo.size.width, widths: widths)
            let room = self.room(in: geo.size.width)
            let run = min(content, room)
            let overflow = content > room + 0.5
            // Where the plate, the run and the doors stand, for a change of
            // space to picture them (StripView).
            let _ = StripGeometry.note(browser, StripGeometry(
                capsuleX: corner + (browser.spacesShown ? aheadWidth : 0), plate: browser.spacesShown ? capsuleWidth : 0,
                lead: lead, doorsStart: geo.size.width - Metrics.rim - (browser.bandDoors ? 0 : doors), width: geo.size.width))
            ZStack(alignment: .leading) {
                // The empty half of the strip is what you grab to move the
                // window; the tabs keep the run they sit on. Refuse only
                // the measured doors, leaving the existing right rim as a
                // minimum handle even when the run overflows.
                DragStrip(reserved: lead + run + Metrics.tabGap + Metrics.plusWidth,
                          notch: browser.bandDoors ? .zero : CGRect(x: StripPress.endGap, y: 0, width: doors, height: Metrics.row))
                // And the corner the lights sit in, which is title bar too,
                // the one stretch left to take hold of when tabs fill the row.
                DragStrip()
                    .frame(width: lead)
                if lit {
                    Lights().frame(width: Lights.run).padding(.leading, Lights.first - Lights.lead)
                        .opacity(browser.stillLights ? 0 : 1)
                        .transition(.opacity)
                }
                if !browser.bandDoors {
                    Helm(browser: browser, reads: false)
                        .padding(.leading, lit ? Metrics.helmLead : 12)
                }
                // The space on screen, at the head of the row, after the
                // pins every space shares.
                if browser.spacesShown {
                    HStack(spacing: Metrics.tabGap) {
                        let pins = ahead
                        if !pins.isEmpty {
                            aheadPins(pins)
                            KeptDivider()
                        }
                        SpaceCapsule(browser: browser, plan: CapsulePlan.strip(name: browser.space.name), up: false)
                            // Two fingers sideways over it: the next space, or
                            // back, as over the column. Over the tabs they still
                            // scroll the row.
                            .background { SpaceSwipe(browser: browser) }
                    }
                    .environment(\.stripRoom, aheadAnchor)
                    .background(StripAnchor(sky: browser.keySky, anchor: aheadAnchor).allowsHitTesting(false))
                    .coordinateSpace(name: "ahead")
                    .padding(.leading, corner)
                    // Over the run while one of them is carried along it.
                    .zIndex(aheadHeld == nil ? 0 : 1)
                }

                HStack(spacing: Metrics.tabGap) {
                    // The tabs, in a run of their own. While they fit, it is
                    // exactly as wide as they are and nothing about the row
                    // changes. Past what the window holds at their narrowest
                    // it takes the room there is and scrolls inside its own
                    // edges, never under the lights, never over the doors,
                    // keeping the tab you are on in view.
                    // With the + after them, one slide (LeadSlide).
                    HStack(spacing: Metrics.tabGap) {
                    ScrollViewReader { reader in
                        ThreadScrollView(.horizontal, showsIndicators: false) {
                            // The row holds still under the hand: the widths it
                            // had when the drag began, whatever the held tab is
                            // about to become. Letting them follow the plan let
                            // an unfolding pin push the run past what the window
                            // holds, which scrolled it, which moved the space the
                            // drag is measured in, which changed the plan back,
                            // round and round, every frame.
                            let each = widths.outer
                            let before = layout(each: each, planned: false, widths: widths)
                            let after = carrying.map { layout(each: each, planned: false, order: nestOrder($0), widths: widths) }
                                ?? (dragging == nil ? before : layout(each: each, planned: true, widths: widths))
                            let now = before.tabs
                            let then = after.tabs
                            let groupedIDs = Set(groupIDs)
                            let moving = dragging == nil && carrying == nil ? [:] : folderMoves(now: before.folders, then: after.folders)
                            // The stroke after the kept, before the first of today's.
                            let firstToday = stroked ? browser.tabs.first { $0.pin == nil && !$0.kept }?.id : nil
                            // Empty folders of yours at the end of the kept: before
                            // the stroke, or with no today's tabs, at the row's end.
                            let emptiesLast = firstToday == nil && !folders.empties.isEmpty ? browser.tabs.last?.id : nil
                            // No spacing of its own: each pill brings the gap
                            // after it, so one tucked away takes none
                            // (FolderPillPlace).
                            // The pins every space shares stand ahead of the
                            // capsule, not in the run.
                            let pills = ForEach(Array(browser.tabs.enumerated()).dropFirst(ahead.count), id: \.element.id) { index, tab in
                                    let held = dragging == tab.id
                                    let alongside = dragging.map { carried(tab, by: $0) } ?? false
                                    let lift = held || alongside || resting == tab.id
                                    let grouped = dragging != nil && groupIDs.count > 1 && groupedIDs.contains(tab.id)
                                    // Carried over the line between pins and titles:
                                    // it changes shape, but not the view that holds
                                    // the drag, changing what that view is made of
                                    // broke the gesture off mid-drag, and the tab was
                                    // left where it was while the hand went on. That
                                    // view stays as it is, unseen, at the width of what
                                    // the tab is becoming, and a copy in the new shape
                                    // is drawn over it.
                                    let becoming = held ? plan.flatMap { $0.pinned == (tab.pin != nil) ? nil : $0.pinned } : nil
                                    let place = folders.place(of: tab)
                                    if tab.id == firstToday {
                                        emptyPills(widths: widths, moving: moving)
                                        let going = dragging != nil && moving[Folders.line] == nil
                                        KeptDivider()
                                            .padding(.trailing, Metrics.tabGap)
                                            .offset(x: moving[Folders.line] ?? 0)
                                            .opacity(going ? 0 : 1)
                                            .animation(Motion.quick, value: going)
                                    }
                                    // A pill for each folder it is the first tab of, the outer first.
                                    ForEach(place?.heads ?? [], id: \.self) { key in
                                      if let folder = folders.folder(key) {
                                        let going = (dragging != nil || carrying != nil) && moving[folder.id] == nil
                                        Group {
                                            if let nest = folder.nest {
                                                NestPill(browser: browser, nest: nest, count: folder.members.count, width: folderWidth(folder, widths: widths),
                                                         aimed: (dragging != nil && plan?.into == nest.id) || carrying?.into == nest.id, over: folder.over)
                                                    .gesture(nestReorder(nest, each: each, widths: widths))
                                                    .allowsWindowActivationEvents()
                                            } else {
                                                FolderPill(browser: browser, folder: folder, open: folders.isOpen(folder.id), width: folderWidth(folder, widths: widths))
                                            }
                                        }
                                        .padding(.trailing, Metrics.tabGap)
                                        .offset(x: isCarried(folder.nest) ? carryTravel : carryResting == folder.id ? carryRest : moving[folder.id] ?? 0)
                                        .zIndex(isCarried(folder.nest) || carryResting == folder.id ? 2 : 0)
                                        .shadow(color: .black.opacity(isCarried(folder.nest) ? 0.14 : 0), radius: 12, y: 4) // design: the carried folder's lift matches the carried tab
                                        .opacity(going ? 0 : 1)
                                        .animation(Motion.quick, value: going)
                                      }
                                    }
                                    TabPill(
                                        browser: browser,
                                        prefs: browser.prefs,
                                        tab: tab,
                                        live: tab.id == browser.activeID,
                                        width: tabWidth(tab, place: place, widths: widths),
                                        room: geo.size.width - lead - 12,
                                        lifted: lift,
                                        hangs: tab.id == browser.activeID && hangs,
                                        close: { browser.shut(tab) }
                                    )
                                    .equatable()
                                    .opacity((choice?.target == tab.id || held) && choice?.revealed == true ? 0 : grouped && !held ? 0 : becoming == nil ? decked == tab.id || torn == tab.id ? 0.5 : 1 : 0)
                                    .frame(width: becoming.map { $0 ? Metrics.pinWidth : tabWidth(tab, place: place, widths: widths) }, alignment: .leading)
                                    .overlay(alignment: .leading) {
                                        if let becoming {
                                            TabPill(
                                                browser: browser,
                                                prefs: browser.prefs,
                                                tab: tab,
                                                live: tab.id == browser.activeID,
                                                width: tabWidth(tab, place: place, widths: widths),
                                                room: geo.size.width - lead - 12,
                                                asPin: becoming,
                                                lifted: true,
                                                close: {}
                                            )
                                            .allowsHitTesting(false)
                                        }
                                    }
                                    .overlay(alignment: .leading) {
                                        if held, choice?.revealed == true {
                                            Mark(icon: tab.displayIcon, letter: tab.monogram, size: 16)
                                                .frame(width: 28, height: 28)
                                                .background(Palette.wash(on: tone), in: RoundedRectangle(cornerRadius: Radius.control))
                                                .offset(x: grabAt + 10)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    // Stayed over by a held tab: it offers a folder of the two.
                                    .overlay {
                                        if let choice, choice.target == tab.id, choice.revealed {
                                            TabDropChoices(choice: choice, iconsOnly: true)
                                        }
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if held && groupIDs.count > 1 {
                                            Text("\(groupIDs.count)")
                                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                                .foregroundStyle(Palette.ground)
                                                .padding(.horizontal, 6)
                                                .frame(minWidth: 17, minHeight: 17)
                                                .background(Capsule().fill(Palette.ink))
                                                .offset(x: 5, y: -6)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .modifier(FolderPillPlace(place: place, gap: Metrics.tabGap))
                                    .shadow(color: .black.opacity(lift ? 0.14 : 0), radius: lift ? 12 : 0, y: lift ? 4 : 0) // design: the held tab's lift, as it was, moved outside the folder's clip
                                    // The held tab under the pointer; the others
                                    // where they will be once it is let go.
                                    // Outside the folder's own frame, which
                                    // clips its tabs as they fold.
                                    .offset(x: shift(tab, now: now, then: then))
                                    // The grip, apart: it springs as the tab folds
                                    // or unfolds while the pointer keeps moving it.
                                    .offset(x: held || alongside ? -grabAt : 0)
                                    .zIndex(lift ? 1 : 0)
                                    .overlay(alignment: .trailing) {
                                        // FolderPillPlace includes the empty gap after the pill.
                                        // Keep it a title-bar handle, outside the tab's gesture.
                                        if place?.shown != false {
                                            DragStrip().frame(width: Metrics.tabGap)
                                        }
                                    }
                                    .gesture(reorder(tab: tab, index: index,
                                                     each: tabWidth(tab, place: place, widths: widths), widths: widths))
                                    // In a window behind another, the press
                                    // that brings it forward is the tab's too
                                    // (see the column's rows).
                                    .allowsWindowActivationEvents()
                                    .id(tab.id)
                                    // An open task's folder of many shows four,
                                    // and says how many more wait (Folders.atOnce).
                                    if let place, place.more > 0 {
                                        FolderMore(folder: place.folder, count: place.more, width: StripWidths.moreWidth)
                                            .padding(.trailing, Metrics.tabGap)
                                            .offset(x: shift(tab, now: now, then: then))
                                    }
                                    if tab.id == emptiesLast {
                                        emptyPills(widths: widths, moving: moving)
                                    }
                                }
                            Group {
                                if browser.tabs.count > 32 {
                                    LazyHStack(spacing: 0) { pills }
                                } else {
                                    HStack(spacing: 0) { pills }
                                }
                            }
                            .background(alignment: .leading) {
                                capsules(layout: after, origin: before.folders, widths: widths)
                            }
                            // The last pill's gap is the row's to leave out.
                            .padding(.trailing, -Metrics.tabGap)
                            .environment(\.stripRoom, runAnchor)
                            // The run's place in the window, as AppKit has it.
                            .background(StripAnchor(sky: browser.keySky, anchor: runAnchor).allowsHitTesting(false))
                            // The run's own space: where the pins end and the
                            // titles start is counted from its first tab.
                            .coordinateSpace(name: "run")
                            .frame(height: Metrics.row)
                            .background(WheelAcross(enabled: dragging == nil))
                            // A new space's tabs come up from the side it
                            // lies on (StripTurn).
                            .modifier(StripArrival(space: browser.spaceID, step: browser.spaceStep))
                            // Two fingers over the capsule: the tabs go with
                            // them, cut at the row's own edge (StripPull).
                            .modifier(StripPull(space: browser.spaceID))
                        }
                        .scrollDisabled(!overflow)
                        // While the tabs fit there is nothing to scroll out
                        // of sight, and no edge to cut the open tab's shadow
                        // at, the first's on the left, the last's on the
                        // right (alpha report, 2026-10-28), nor a
                        // held tab's lift, as in the column (SideBar).
                        .scrollClipDisabled(!overflow)
                        .modifier(HardEdges())
                        .frame(width: run)
                        .overlay {
                            // Pills are centered in a row twelve points taller.
                            // These transparent handles do not change their layout.
                            DragStrip(tabAir: true)
                        }
                        // And the next space's tabs coming up where they
                        // will stand, as in the column (PagedSpace).
                        .overlay(alignment: .leading) {
                            StripComing(browser: browser, run: run, room: geo.size.width - lead - 12) {
                                coming($0, in: geo.size.width)
                            }
                        }
                        .onAppear { reveal(reader, in: geo.size.width) }
                        .onChange(of: overflow) { _, _ in reveal(reader, in: geo.size.width) }
                        .onChange(of: browser.activeID) { _, _ in reveal(reader, in: geo.size.width, gliding: true) }
                    }

                    // The way to a new page, right after the tabs rather than
                    // at the end of their run, so it is there however far the
                    // run has scrolled. Out of sight until the pointer is up here.
                    Button { plussed = false; browser.newTab() } label: {
                        Symbol("plus", size: 10, weight: .medium)
                            .foregroundStyle(Palette.muted(on: tone))
                            .frame(width: 15, height: 15)
                            .padding(.horizontal, 7)
                            .padding(.vertical, Density.current.tabPad)
                            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            .background(
                                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                    .fill(plussed ? Palette.hover(on: tone) : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    // It raises the field: not away and back (Browser.fieldAway).
                    .background(ClickZone(away: browser.fieldAway))
                    .onHover { plussed = $0 }
                    .keyTip("New Tab", shortcut: "New Tab")
                    // Out of sight until the pointer is near, or something
                    // found is waiting on a new tab: then it stands with its dot.
                    .modifier(PlusNews(nearby: nearby))
                    // Along to where the next space's run will end, as two
                    // fingers take the strip there: the edge its tabs are cut at.
                    .modifier(StripPlus(browser: browser, run: run) {
                        coming($0, in: geo.size.width)
                    })
                    }
                    // After the capsule, on the turn's spring (LeadSlide):
                    // the slide alone, nothing in the run laid out again.
                    .transaction(value: lead) { $0.animation = nil }
                    .modifier(LeadSlide(drawn: lead, lead: lead))
                    .transaction(value: lead) { StripTurn.carry(&$0, on: slides) }

                    Spacer(minLength: 0)

                    // Downloads and updates stay at the trailing end; navigation
                    // is beside the lights, or in the visible address bar.
                    if !browser.bandDoors {
                        // The sliders aren't here: ⌘E's panel hangs from
                        // the open tab's mark, the page it is about.
                        HStack(spacing: Metrics.tabGap) {
                            // A share going on, with no band to say it (ShareChip.swift).
                            if browser.shareSpot == .strip {
                                ShareChip(browser: browser, tab: browser.active)
                            }
                            UpdateButton(browser: browser, place: .strip)
                            HoardSlot(hoard: browser.hoard, place: .strip)
                        }
                        .background {
                            GeometryReader { box in
                                Color.clear
                                    .onAppear { doors = box.size.width }
                                    .onChange(of: box.size.width) { _, width in doors = width }
                            }
                        }
                    }
                }
                // The traffic lights come first, and the row starts after
                // them. Full screen has none but under the menu bar, and the
                // row starts at the edge.
                // Laid out at once: the tabs and the + get there on the
                // turn's spring by LeadSlide, drawn and not laid out again
                // each frame, as the capsule's plate does (StripTurn).
                .padding(.leading, lead)
                .transaction(value: lead) { $0.animation = nil }
                .padding(.trailing, Metrics.rim)
                .coordinateSpace(name: "strip")
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Metrics.row)
        .onHover { nearby = $0 }
        // A link dragged onto the row opens there.
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            browser.take(providers)
        }
        .background(landing ? Palette.hover(on: tone) : .clear)
        // The row makes room for the field on the same spring as everything
        // else. Without this the widths changed between one frame and the next
        // and the tabs appeared to jump aside.
        .animation(Motion.glide, value: browser.editingTab)
        // A tab opened or closed: the others make room, briefly, quicker
        // for a leaving than an arrival. Keyed on the count, so a drag, which
        // asks for its own spring, is left to it. The gray is not part of
        // this: each row puts its own down at once (see `.animation(nil,
        // value: live)` on the row).
        .animation(browser.tabsGrew ? Motion.room : Motion.leave, value: browser.tabs.count)
        .onDisappear {
            if let escape = clocks.escape { NSEvent.removeMonitor(escape); clocks.escape = nil }
            clearChoice()
            clocks.stop()
        }
        .onChange(of: holding) { _, still in
            // Let go properly, the drag has already put everything away by
            // the time this hears of it; broken off, it is left to do here,
            // everything back where it was, nothing moved.
            if still {
                dragCancelled = false
                if let escape = clocks.escape { NSEvent.removeMonitor(escape); clocks.escape = nil }
                clocks.escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak clocks, weak browser] event in
                    guard event.keyCode == 53 else { return event }
                    return MainActor.assumeIsolated {
                        guard let browser, dragging != nil, event.window === BrowserWindows.shared.window(for: browser) else { return event }
                        dragCancelled = true
                        clearChoice()
                        clocks?.stop()
                        if decked != nil { SplitDeck.shared.leave(); decked = nil }
                        SpaceDrop.shared.cancel()
                        TearOff.shared.cancel()
                        dragging = nil
                        groupIDs = []
                        plan = nil
                        travel = 0
                        heldWidths = nil
                        return nil
                    }
                }
                return
            }
            movingWindow = false
            if let escape = clocks.escape { NSEvent.removeMonitor(escape); clocks.escape = nil }
            DispatchQueue.main.async {
                if carrying != nil { endCarry(cancelled: true) }
                if aheadHeld != nil {
                    withAnimation(Motion.settle) {
                        aheadHeld = nil
                        aheadTravel = 0
                        aheadOut = false
                    }
                }
                guard dragging != nil else { return }
                TearOff.shared.cancel()
                torn = nil
                if decked != nil {
                    SplitDeck.shared.leave()
                    decked = nil
                }
                clearChoice()
                clocks.stop()
                withAnimation(Motion.settle) {
                    dragging = nil
                    groupIDs = []
                    plan = nil
                    travel = 0
                    resting = nil
                    sprung = nil
                    combine = nil
                    heldWidths = nil
                }
            }
        }
    }

    /// ⌘E's panel hangs from the open tab's mark while no band over the
    /// page has the site's sliders: the address bar, Split View's halves
    /// and a page in Developer Mode each keep their own. Not in mail, not
    /// on a new tab.
    private var hangs: Bool {
        !browser.barShown && !browser.inMail && browser.active.map { !$0.isBlank } == true
    }

    /// Where each tab starts along the run: as the row stands now, or as it
    /// will once the held tab is let go where the plan has it. The held tab
    /// counts at the width it is drawn at, square or title.
    private func places(each: CGFloat, planned: Bool) -> [Tab.ID: CGFloat] {
        layout(each: each, planned: planned).tabs
    }

    /// Empty folders of yours as pills, each where the drag has it.
    @ViewBuilder
    private func emptyPills(widths: StripWidths, moving: [String: CGFloat]) -> some View {
        ForEach(folders.empties) { nest in
            let going = dragging != nil && moving[nest.key] == nil
            NestPill(browser: browser, nest: nest, count: 0,
                     width: nest.open ? StripWidths.pillWidth(nest.name) : widths.outer,
                     aimed: dragging != nil && plan?.into == nest.id)
                .padding(.trailing, Metrics.tabGap)
                .offset(x: moving[nest.key] ?? 0)
                .opacity(going ? 0 : 1)
                .animation(Motion.quick, value: going)
        }
    }

    /// How far each folder's own pill, and the stroke after the kept, moves
    /// while a tab is held; left out when it has nowhere to be once the tab
    /// lands, and drawn going.
    private func folderMoves(now: [String: CGFloat], then: [String: CGFloat]) -> [String: CGFloat] {
        return now.reduce(into: [:]) { moves, pair in
            if let there = then[pair.key] { moves[pair.key] = there - pair.value }
        }
    }

    private func folderWidth(_ folder: Folders.Folder, widths: StripWidths?) -> CGFloat {
        guard folders.isOpen(folder.id) else { return widths?.outer ?? Metrics.tabWidth }
        return StripWidths.pillWidth(folder.nest?.name ?? Folders.title(folder.id))
    }

    private func tabWidth(_ tab: Tab, place: Folders.Place?, widths: StripWidths) -> CGFloat {
        if tab.pin != nil { return Metrics.pinWidth }
        guard place != nil else { return tab.id == browser.activeID ? widths.activeOuter : widths.outer }
        return tab.id == browser.activeID ? widths.activeInner : widths.inner
    }

    // MARK: - the pins ahead of the capsule

    /// A tab pinned now is one of the pins every space shares, ahead of the
    /// capsule (Browser.pin): in a space that shows them, one that can be.
    private func joinsAhead(_ tab: Tab) -> Bool {
        browser.spacesShown && browser.showsShared(browser.spaceID) && Browser.sharable(tab)
    }

    /// The pins every space shares, before the capsule: picked, edited and
    /// named as any pin, put in another order by dragging, and dragged on
    /// past the capsule among the space's tabs, unpinned there.
    private func aheadPins(_ pins: [Tab]) -> some View {
        ForEach(Array(pins.enumerated()), id: \.element.id) { index, tab in
            let lift = aheadHeld == tab.id || aheadResting == tab.id
            TabPill(browser: browser, prefs: browser.prefs, tab: tab, live: tab.id == browser.activeID,
                    width: Metrics.pinWidth, room: Self.fieldRoom, lifted: lift,
                    hangs: tab.id == browser.activeID && hangs, close: { browser.shut(tab) })
                .equatable()
                .shadow(color: .black.opacity(lift ? 0.14 : 0), radius: lift ? 12 : 0, y: lift ? 4 : 0) // design: the held tab's lift, as the run's
                .offset(x: aheadShift(tab, index: index))
                .zIndex(lift ? 1 : 0)
                .gesture(aheadReorder(tab, index: index, count: pins.count))
                .allowsWindowActivationEvents()
        }
    }

    /// The held one under the hand, the one let go what is left of its
    /// way, the others a pin's step toward the gap it left.
    private func aheadShift(_ tab: Tab, index: Int) -> CGFloat {
        if aheadHeld == tab.id { return aheadTravel }
        if aheadResting == tab.id { return aheadRest }
        guard aheadHeld != nil else { return 0 }
        if aheadOut { return index > aheadFrom ? -Self.pinStride : 0 }
        if aheadFrom < aheadGoal, index > aheadFrom, index <= aheadGoal { return -Self.pinStride }
        if aheadGoal < aheadFrom, index >= aheadGoal, index < aheadFrom { return Self.pinStride }
        return 0
    }

    /// Picked up, the others make way; let go, the row changes once and the
    /// held one glides the rest of the way, as the run's tabs do. Past the
    /// capsule it is unpinned, a tab at the head of this space's.
    private func aheadReorder(_ tab: Tab, index: Int, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("ahead"))
            .updating($holding) { _, state, _ in state = true }
            .onChanged { value in
                if aheadHeld != tab.id {
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) {
                        aheadResting = nil
                        aheadHeld = tab.id
                        aheadFrom = index
                        aheadGoal = index
                        aheadOut = false
                    }
                }
                aheadTravel = value.translation.width
                let out = value.location.x > CGFloat(count) * Self.pinStride + KeptDivider.width + Metrics.tabGap + capsuleWidth
                if out != aheadOut {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                    withAnimation(Motion.settle) { aheadOut = out }
                }
                guard !out else { return }
                let goal = min(max(0, aheadFrom + Int((aheadTravel / Self.pinStride).rounded())), count - 1)
                if goal != aheadGoal {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    withAnimation(Motion.settle) { aheadGoal = goal }
                }
            }
            .onEnded { _ in
                guard aheadHeld == tab.id else { return }
                let out = aheadOut, from = aheadFrom, goal = aheadGoal
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    if out { browser.unpin(tab) } else if goal != from { browser.move(tab, to: goal) }
                    aheadHeld = nil
                    aheadResting = out ? nil : tab.id
                    aheadRest = out ? 0 : aheadTravel - CGFloat(goal - from) * Self.pinStride
                    aheadTravel = 0
                    aheadOut = false
                }
                withAnimation(Motion.settle) { aheadRest = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if aheadResting == tab.id, aheadHeld == nil { aheadResting = nil }
                }
            }
    }

    private struct CapsuleSpan: Identifiable {
        let id: String
        let start: CGFloat
        let width: CGFloat
    }

    private func capsuleSpans(layout: (tabs: [Tab.ID: CGFloat], folders: [String: CGFloat]),
                              origin: [String: CGFloat], widths: StripWidths) -> [CapsuleSpan] {
        var spans: [CapsuleSpan] = []
        let tabsByID = Dictionary(browser.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for folder in folders.folders {
            let carried = isCarried(folder.nest)
            guard let planned = layout.folders[folder.id] else { continue }
            let start = carried ? (origin[folder.id] ?? planned) + carryTravel
                : carryResting == folder.id ? planned + carryRest : planned
            let shown = folder.members.compactMap { id -> CGFloat? in
                if id == dragging, plan?.out == true || plan?.nest != folder.nest?.id { return nil }
                guard !carried, let tab = tabsByID[id],
                      let place = folders.place(of: tab), place.shown,
                      let x = layout.tabs[id] else { return nil }
                return x + tabWidth(tab, place: place, widths: widths)
                    + (place.more > 0 ? Metrics.tabGap + StripWidths.moreWidth : 0)
            }
            guard folders.isOpen(folder.id) || !shown.isEmpty else { continue }
            let arriving = folder.nest?.id == plan?.nest && !carried
                ? dragging.flatMap { layout.tabs[$0] }.map { $0 + widths.inner } : nil
            let end = max(start + folderWidth(folder, widths: widths),
                          max(shown.max() ?? 0, arriving ?? 0))
            spans.append(CapsuleSpan(id: folder.id, start: start, width: end - start))
        }
        for nest in folders.empties where nest.open {
            if let start = layout.folders[nest.key] {
                spans.append(CapsuleSpan(id: nest.key, start: start, width: StripWidths.pillWidth(nest.name)))
            }
        }
        return spans
    }

    @ViewBuilder
    private func capsules(layout: (tabs: [Tab.ID: CGFloat], folders: [String: CGFloat]),
                          origin: [String: CGFloat], widths: StripWidths) -> some View {
        let spans = capsuleSpans(layout: layout, origin: origin, widths: widths)
        let washes = NestedWash.lay(spans.map { NestedWash.Span(id: $0.id, start: $0.start, end: $0.start + $0.width) },
                                    parent: nestParents)
        // Each from the run's leading edge: in a centered stack a folder's
        // wash inside a wider one was drawn in that one's middle, not at
        // its own pill.
        ZStack(alignment: .leading) {
            ForEach(washes) { wash in
                RoundedRectangle(cornerRadius: wash.radius, style: .continuous)
                    .fill(Palette.wash(on: tone))
                    .frame(width: wash.end - wash.start, height: wash.height)
                    .offset(x: wash.start)
                    .transition(.opacity)
            }
        }
    }

    /// Each folder of yours drawn on the row, and the folder it is in.
    private var nestParents: [String: String] {
        var parents: [String: String] = [:]
        for folder in folders.folders {
            if let nest = folder.nest, let parent = nest.parent { parents[folder.id] = parent.key }
        }
        for nest in folders.empties {
            if let parent = nest.parent { parents[nest.key] = parent.key }
        }
        return parents
    }

    private func isCarried(_ nest: Nest?) -> Bool {
        guard let nest, let held = carrying?.nest else { return false }
        return held === nest
    }

    /// The same order Browser.move(_:to:) will keep when the folder lands.
    private func nestOrder(_ held: NestCarry) -> [Tab] {
        if held.nest.today { return held.gap.map { browser.order(held.nest, before: $0.before) } ?? browser.tabs }
        let pins = browser.tabs.filter { $0.pin != nil }
        let kept = browser.tabs.filter(\.kept)
        let members = kept.filter { $0.nest?.within(held.nest) == true }
        var rest = kept.filter { $0.nest?.within(held.nest) != true }
        rest.insert(contentsOf: members, at: min(max(0, held.index), rest.count))
        return pins + rest + browser.tabs.filter { $0.pin == nil && !$0.kept }
    }

    /// Take the chosen tabs out of their old places, then place them in
    /// their original order at the gap the held tab found.
    private func groupOrder(_ held: Tab.ID, at index: Int) -> [Tab] {
        let members = Set(groupIDs)
        let single = Browser.moving(browser.tabs, held, to: index, with: browser.pair(of: held)?.other(than: held))
        let gap = single.prefix { $0.id != held }.filter { !members.contains($0.id) }.count
        let picked = browser.tabs.filter { members.contains($0.id) }
        var rest = browser.tabs.filter { !members.contains($0.id) }
        rest.insert(contentsOf: picked, at: min(gap, rest.count))
        return rest
    }

    /// A folder's pill carries its tabs as one among the kept, as its row
    /// does in the column, and one of today's among today's. It cannot cross
    /// the stroke or split a folder.
    private func nestReorder(_ nest: Nest, each: CGFloat, widths: StripWidths) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("run"))
            .updating($holding) { _, state, _ in state = true }
            .onChanged { value in
                if !isCarried(nest) {
                    guard browser.tabs.contains(where: { $0.nest?.within(nest) == true }) else { return }
                    // As the row draws it, its widths (see reorder's start).
                    let start = layout(each: each, planned: false, widths: widths).folders[nest.key] ?? 0
                    let kept = browser.tabs.filter(\.kept)
                    let first = kept.firstIndex { $0.nest?.within(nest) == true } ?? 0
                    let index = kept.prefix(first).filter { $0.nest?.within(nest) != true }.count
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) {
                        carryResting = nil
                        heldWidths = widths
                        carrying = NestCarry(nest: nest, start: start, grip: value.startLocation.x - start,
                                             each: each, slots: slotPoints(each: each), index: index, parent: nest.parent?.id)
                    }
                    withAnimation(Motion.settle) { folders.carry(nest.key) }
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
                carryTravel = value.translation.width
                guard let held = carrying else { return }
                // Over the space's capsule or its tray: it goes there whole
                // when let go (SpaceDrop).
                if SpaceDrop.shared.track(browser.tabs(in: nest), browser: browser, folder: nest) { return }
                let want = slotAt(value.location.x - held.grip, each: each, points: held.slots)
                let loose = Array(browser.tabs.dropFirst(browser.pinnedCount))
                if nest.today {
                    let next = folders.todayLanding(nest, want: want, among: loose)
                    guard next != held.gap else { return }
                    if held.gap != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                    withAnimation(Motion.settle) { carrying?.gap = next }
                    return
                }
                // Down off the strip, how many folders deep, as sideways in
                // the column.
                let deep = SideBar.deep(from: nest.depth - 1, sideways: value.translation.height)
                let current = Folders.NestLanding(index: held.index, slot: 0, parent: held.parent, into: held.into)
                var next = folders.nestLanding(nest, want: want, deep: deep, among: loose, current: current)
                next.slot = 0
                if next != current {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    withAnimation(Motion.settle) {
                        carrying?.index = next.index
                        carrying?.parent = next.parent
                        carrying?.into = next.into
                    }
                }
            }
            // Gone to another space: here it only settles back.
            .onEnded { _ in endCarry(cancelled: SpaceDrop.shared.finish(browser)) }
    }

    private func endCarry(cancelled: Bool) {
        guard let held = carrying else { return }
        let hand = held.start + carryTravel
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            if !cancelled {
                if held.nest.today {
                    if let gap = held.gap { browser.move(held.nest, before: gap.before) }
                } else if let into = held.into, let there = folders.nest(into) {
                    browser.file(held.nest, in: there)
                } else {
                    browser.move(held.nest, to: held.index, in: held.parent.flatMap { folders.nest($0) })
                }
            }
            carrying = nil
            heldWidths = nil
            carryTravel = 0
            folders.carry(nil)
            let head = layout(each: held.each, planned: false).folders[held.nest.key] ?? held.start
            carryResting = held.nest.key
            carryRest = hand - head
        }
        withAnimation(Motion.settle) { carryRest = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if carryResting == held.nest.key, carrying == nil { carryResting = nil }
        }
    }

    /// The tabs' places and each agent folder's own pill's, which stands
    /// before its first tab; a tab tucked into a folder takes no room.
    private func layout(each: CGFloat, planned: Bool, order given: [Tab]? = nil,
                        widths explicit: StripWidths? = nil) -> (tabs: [Tab.ID: CGFloat], folders: [String: CGFloat]) {
        let widths = explicit ?? heldWidths
        var order = given ?? browser.tabs
        if planned, let id = dragging, let plan {
            // A half of a pair takes its other half with it.
            order = groupIDs.count > 1 ? groupOrder(id, at: plan.index)
                : Browser.moving(order, id, to: plan.index, with: browser.pair(of: id)?.other(than: id))
        }
        let out = planned && plan?.out == true ? dragging : nil
        // The held tab as the plan has it: kept or not, in a folder or not.
        let guised = planned ? dragging : nil
        let group = planned && groupIDs.count > 1 ? Set(groupIDs) : []
        // The pins ahead of the capsule take no room in the run, nor do tabs
        // on their way to join them.
        var away = Set(ahead.map(\.id))
        if planned, plan?.pinned == true {
            for tab in order where (tab.id == guised || group.contains(tab.id)) && joinsAhead(tab) { away.insert(tab.id) }
        }
        var x: CGFloat = 0
        var tabs: [Tab.ID: CGFloat] = [:]
        var made: [String: CGFloat] = [:]
        // Empty folders of yours at the kept's end, a pill each, then the
        // stroke, if any of today's come after.
        let empty = folders.empties
        var kept = !empty.isEmpty
        var lined = false
        func empties() {
            for nest in empty {
                made[nest.key] = x
                x += (nest.open ? StripWidths.pillWidth(nest.name) : widths?.outer ?? each) + Metrics.tabGap
            }
        }
        for tab in order {
            if away.contains(tab.id) { continue }
            let moved = tab.id == guised || group.contains(tab.id)
            let pinned = moved ? (plan?.pinned ?? (tab.pin != nil)) : tab.pin != nil
            if !pinned {
                // The stroke, before the first of today's, after the kept.
                if moved ? plan?.kept == true : tab.kept {
                    kept = true
                } else if kept, !lined {
                    empties()
                    made[Folders.line] = x
                    x += KeptDivider.width + Metrics.tabGap
                    lined = true
                }
            }
            let place: (keys: [String], shown: Bool)?
            if moved, !pinned {
                place = plan?.nest.map { id in (folders.nest(id)?.chain.map(\.key) ?? [Nest.key(id)], true) }
            } else if tab.id == out || group.contains(tab.id) && plan?.out == true {
                place = nil
            } else {
                place = folders.place(of: tab).map { ($0.chain.isEmpty ? [$0.folder] : $0.chain, $0.shown) }
            }
            if let place {
                // A pill for each folder above it not drawn yet, the outer first.
                for key in place.keys where made[key] == nil {
                    made[key] = x
                    let folder = folders.folder(key)
                    x += folder.map { folderWidth($0, widths: widths) } ?? each
                    x += Metrics.tabGap
                }
                tabs[tab.id] = x
                if !place.shown { continue }
            }
            tabs[tab.id] = x
            let folderTab = place != nil && !pinned
            let width = pinned ? Metrics.pinWidth : folderTab
                ? (tab.id == browser.activeID ? widths?.activeInner : widths?.inner) ?? each
                : (tab.id == browser.activeID ? widths?.activeOuter : widths?.outer) ?? each
            x += width + Metrics.tabGap
            if tab.id != out, let place = folders.place(of: tab), place.more > 0 {
                x += StripWidths.moreWidth + Metrics.tabGap
            }
        }
        if kept, !lined { empties() }
        return (tabs, made)
    }

    /// How far down the loose tabs the held one's leading edge is, in
    /// slots as `Folders.slots` counts them (a folder's pill, the stroke,
    /// each tab shown), fractional, from where the row stands now.
    private func slotPoints(each: CGFloat) -> [(key: Int, value: CGFloat)] {
        let loose = Array(browser.tabs.dropFirst(browser.pinnedCount))
        let slots = folders.slots(loose)
        let places = layout(each: each, planned: false)
        var starts: [Int: CGFloat] = [:]
        for (key, slot) in slots.folders { if let x = places.folders[key] { starts[slot] = x } }
        for tab in loose {
            guard let slot = slots.tabs[tab.id], starts[slot] == nil, folders.place(of: tab)?.shown ?? true,
                  let x = places.tabs[tab.id] else { continue }
            starts[slot] = x
        }
        return starts.sorted { $0.key < $1.key }
    }

    private func slotAt(_ leading: CGFloat, each: CGFloat, points cached: [(key: Int, value: CGFloat)]? = nil) -> Double {
        let points = cached ?? slotPoints(each: each)
        guard let first = points.first else { return 0 }
        if leading <= first.value { return Double(first.key) + Double((leading - first.value) / (each + Metrics.tabGap)) }
        for (a, b) in zip(points, points.dropFirst()) where leading < b.value {
            return Double(a.key) + Double((leading - a.value) / max(1, b.value - a.value)) * Double(b.key - a.key)
        }
        let last = points[points.count - 1]
        return Double(last.key) + Double((leading - last.value) / (each + Metrics.tabGap))
    }

    /// The held tab under the pointer; the one just let go, what is left of
    /// its way; the others, the difference between where they stand and
    /// where the plan puts them.
    private func shift(_ tab: Tab, now: [Tab.ID: CGFloat], then: [Tab.ID: CGFloat]) -> CGFloat {
        if dragging == tab.id { return pointer - (now[tab.id] ?? 0) }
        // The other half of the one in the hand, carried beside it.
        if let id = dragging, carried(tab, by: id) { return pointer - (now[id] ?? 0) }
        if resting == tab.id { return rest }
        guard dragging != nil else { return 0 }
        return (then[tab.id] ?? 0) - (now[tab.id] ?? 0)
    }

    /// Whether `tab` is the other half of the pair `id` is in.
    private func carried(_ tab: Tab, by id: Tab.ID) -> Bool {
        id != tab.id && browser.pair(of: id)?.contains(tab.id) == true
    }

    /// Pick a tab up and the others get out of its way as it passes them.
    /// Brought left over the pins it folds into one, and a gap opens among
    /// them for it; a pin taken right past them unfolds into a tab. A light
    /// tap under the finger at each tab it passes, a firmer one when it
    /// changes sides.
    private func reorder(tab: Tab, index: Int, each: CGFloat, widths: StripWidths) -> some Gesture {
        // In the run's space, not the pill's, see the sidebar's grid for why.
        DragGesture(minimumDistance: 5, coordinateSpace: .named("run"))
            .updating($holding) { _, state, _ in state = true }
            .onChanged { value in
                guard !dragCancelled, !movingWindow else { return }
                if dragging == nil,
                   StripPress.verticalTab(value.translation.width, value.translation.height),
                   let window = BrowserWindows.shared.window(for: browser),
                   WindowDrag.dragTab(in: window) {
                    movingWindow = true
                    return
                }
                if dragging != tab.id {
                    // Where it stands as the row draws it: the widths the
                    // row has now, which the hand keeps (heldWidths, not yet
                    // set here). Laid without them, every folder's pill
                    // counted a whole tab's width and the held tab was
                    // drawn that far right of the pointer.
                    let start = layout(each: each, planned: false, widths: widths).tabs[tab.id] ?? 0
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) {
                        resting = nil
                        heldWidths = widths
                        dragging = tab.id
                        groupIDs = tab.pin == nil && browser.isPicked(tab)
                            ? browser.tabs.filter { $0.pin == nil && browser.isPicked($0) }.map(\.id)
                            : []
                        from = index
                        grab = value.startLocation.x - start
                        grabAt = grab
                        pointer = value.location.x
                        plan = Plan(index: index, pinned: tab.pin != nil, kept: tab.kept, nest: tab.nest?.id)
                        sprung = nil
                        combine = nil
                    }
                    clocks.stop()
                }
                // Out past the window's edge: the tab is leaving the window
                // (TearOff), and the row stays as it was. Back inside, the
                // drag goes on here.
                if groupIDs.count < 2, TearOff.shared.track(tab, browser: browser, moved: value.translation) {
                    if torn != tab.id {
                        if decked != nil {
                            SplitDeck.shared.leave()
                            decked = nil
                        }
                        clearChoice()
                        clocks.stop()
                        withAnimation(Motion.settle) {
                            torn = tab.id
                            combine = nil
                            plan = Plan(index: from, pinned: tab.pin != nil, kept: tab.kept, nest: tab.nest?.id)
                            travel = 0
                            pointer = value.startLocation.x
                            grabAt = grab
                        }
                    }
                    return
                }
                if torn == tab.id { torn = nil }
                // Down over the pages: the deck has the tab, and every move
                // is its alone, nothing of the row's changes. Back up in the
                // row, the drag goes on here.
                let out = value.translation.height > Metrics.row + 8
                if out { clearChoice() }
                if decked != nil {
                    if out { SplitDeck.shared.move(); return }
                    SplitDeck.shared.leave()
                    decked = nil
                } else if out, groupIDs.count < 2, tab.pin == nil, SplitDeck.shared.begin(tab, in: browser) {
                    clearChoice()
                    decked = tab.id
                    withAnimation(Motion.settle) {
                        plan = Plan(index: from, pinned: false, kept: tab.kept, nest: tab.nest?.id)
                        travel = 0
                        pointer = value.startLocation.x
                    }
                    return
                }
                pointer = value.location.x
                travel = value.translation.width
                // Over the space's capsule, or the tray it opens: the tab is
                // going to another space, and the others stay where they were.
                let members = Set(groupIDs)
                let moving = members.count > 1
                    ? browser.tabs.filter { members.contains($0.id) } : [tab]
                if SpaceDrop.shared.track(moving, browser: browser) {
                    clearChoice()
                    let home = Plan(index: from, pinned: tab.pin != nil, kept: tab.kept, nest: tab.nest?.id)
                    if plan != home { withAnimation(Motion.settle) { plan = home } }
                    return
                }
                guard let plan else { return }
                let pins = browser.pinnedCount
                let pinStride = Metrics.pinWidth + Metrics.tabGap
                // The pins every space shares stand ahead of the capsule,
                // out of the run: those in it are the space's own.
                let lead = ahead.count
                let pinsEnd = CGFloat(pins - lead) * pinStride
                var next = plan
                if tab.pin == nil {
                    // Over the pins, past their end, or, once folded, past
                    // the end of the room they have made for it.
                    if value.location.x < pinsEnd + (plan.pinned ? pinStride + 6 : -6) {
                        clearChoice()
                        next.pinned = true
                        if value.location.x < 0, lead > 0, joinsAhead(tab) {
                            // Out past the capsule, over the pins ahead of
                            // it: among them, under the hand.
                            // How far into them from the last one's end: back
                            // over the gap, the capsule, the gap, the stroke
                            // and the gap before it.
                            let past = -value.location.x - 3 * Metrics.tabGap - capsuleWidth - KeptDivider.width
                            next.index = min(max(0, Int((CGFloat(lead) - past / pinStride).rounded())), lead)
                        } else {
                            next.index = lead + min(max(0, Int(value.location.x / pinStride)), pins - lead)
                        }
                    } else {
                        next.pinned = false
                        // Staying over another pill: let go, a folder of the two.
                        if groupIDs.count < 2 {
                            dwell(tab, x: value.location.x, leading: value.location.x - grabAt, each: each)
                        }
                        if choice != nil { return }
                        // By pills as drawn, folders' and the stroke's
                        // (Folders.landing): the held one's leading edge, in
                        // slots, a neighbor making way once it is half over it.
                        let loose = Array(browser.tabs.dropFirst(pins))
                        let want = slotAt(value.location.x - grabAt, each: each)
                        let current = plan.pinned ? nil : plan.landing(pins: pins, slot: 0)
                        let landing = folders.landing(tab, want: want, among: loose, current: current)
                        next.index = pins + landing.index
                        next.out = landing.out
                        next.kept = landing.kept
                        next.nest = landing.nest
                        next.into = landing.into
                        spring(tab, next: next, x: value.location.x, each: each)
                        // Passing a pill a folder could be made with, it makes
                        // way once the held one is 70% over it, not half: the
                        // 30 to 70% between is where staying offers a folder.
                        if next.into == nil, plan.into == nil, !plan.pinned, next.kept == plan.kept, next.nest == plan.nest,
                           abs(next.index - plan.index) == 1,
                           let over = overlapped(tab, leading: value.location.x - grabAt, each: each), over.by < 0.7 {
                            return
                        }
                    }
                } else {
                    // Out past the pins, among the titles.
                    if value.location.x > pinsEnd + (plan.pinned ? 6 : -pinStride - 6) {
                        next.pinned = false
                        // Counted from where the tab's own leading edge is,
                        // and taken at the halfway mark, the way a tab moves
                        // among titles: a neighbor makes way once the held
                        // tab is half over it, not once the pointer is past it.
                        let titlesStart = CGFloat(pins - lead - 1) * pinStride
                        let leading = value.location.x - (plan.pinned ? min(grab, each / 2) : grabAt)
                        let slot = Int(((leading - titlesStart) / (each + Metrics.tabGap)).rounded())
                        next.index = pins - 1 + min(max(0, slot), browser.tabs.count - pins)
                        // Among the kept, it is kept.
                        next.kept = next.index - (pins - 1) < browser.keptCount
                    } else {
                        next.pinned = true
                        let moved = Int((travel / pinStride).rounded())
                        next.index = min(max(lead, from + moved), pins - 1)
                    }
                }
                guard next != plan else { return }
                let crossed = next.pinned != plan.pinned
                NSHapticFeedbackManager.defaultPerformer.perform(crossed ? .levelChange : .alignment, performanceTime: .now)
                withAnimation(Motion.settle) {
                    self.plan = next
                    if crossed { grabAt = next.pinned ? Metrics.pinWidth / 2 : min(grab, each / 2) }
                }
            }
            .onEnded { value in
                if movingWindow { movingWindow = false; return }
                guard !dragCancelled, dragging == tab.id else { return }
                // Let go out of the window: it went to another, or a new one.
                if TearOff.shared.finish(browser) {
                    clearChoice()
                    clocks.stop()
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) {
                        dragging = nil
                        torn = nil
                        groupIDs = []
                        plan = nil
                        travel = 0
                        heldWidths = nil
                        combine = nil
                    }
                    return
                }
                torn = nil
                // Let go over a space in the tray: it went there.
                if SpaceDrop.shared.finish(browser) {
                    clearChoice()
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) {
                        dragging = nil
                        groupIDs = []
                        plan = nil
                        travel = 0
                        heldWidths = nil
                    }
                    return
                }
                if choice != nil, decked == nil {
                    dwell(tab, x: value.location.x, leading: value.location.x - grabAt, each: each)
                }
                // Let go down over the pages with nothing there to take it:
                // back to its place, no folder made of a pill it crossed.
                if decked != tab.id, value.translation.height > Metrics.row + 8 {
                    clearChoice()
                    plan = Plan(index: from, pinned: tab.pin != nil, kept: tab.kept, nest: tab.nest?.id)
                }
                finish(tab, each: each)
            }
    }

    private func finish(_ tab: Tab, each: CGFloat) {
                if groupIDs.count > 1 {
                    finishGroup(tab, each: each)
                    return
                }
                if decked == tab.id {
                    let drop = SplitDeck.shared.end()
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) {
                        decked = nil
                        dragging = nil
                        plan = nil
                        travel = 0
                        heldWidths = nil
                    }
                    if let drop { browser.dropSplit(tab, drop) }
                    return
                }
                clocks.stop()
                sprung = nil
                guard dragging == tab.id, let plan else { return }
                let visual = pointer - grabAt
                let splitTarget = choice.flatMap { value -> Tab? in
                    value.revealed && value.side == .split ? browser.tab(id: value.target) : nil
                }
                choicePreviousActive = nil
                choice = nil
                let other = combine.flatMap { id in browser.tabs.first { $0.id == id } }
                combine = nil
                var still = Transaction()
                still.disablesAnimations = true
                var stays = false
                withTransaction(still) {
                    if let splitTarget {
                        browser.split(tab, with: splitTarget)
                        stays = true
                    } else if let other {
                        // Stayed over another pill: a new folder of the two.
                        browser.newFolder(with: [other, tab], today: !other.kept, around: other)
                    } else if plan.pinned != (tab.pin != nil) {
                        // A half of a pair leaves a square on its page (`pin`),
                        // the half staying in the pair.
                        // A pair that can be pinned as one is: one square,
                        // as its menu's Pin Pair makes it (PinPairs.swift).
                        if plan.pinned, let pair = browser.pair(of: tab.id), browser.canPinPair(pair) {
                            browser.pinPair(pair, cell: plan.index)
                            stays = true
                        } else if plan.pinned, browser.pair(of: tab.id) != nil {
                            if let square = browser.pin(tab) { browser.move(square, to: plan.index) }
                            stays = true
                        } else if plan.pinned { browser.pin(tab) } else { browser.unpin(tab) }
                    }
                    // Out of an agent's folder, onto its pill or before it: yours.
                    if other == nil, plan.out { folders.keep(tab) }
                    if other != nil || stays {
                        // Made above.
                    } else if let into = plan.into, let nest = browser.nests.first(where: { $0.id == into }) {
                        // Over a shut folder of yours: into it.
                        browser.file([tab], in: nest)
                    } else {
                        // Across the stroke, or into a folder of yours or out.
                        let changed = !plan.pinned && (plan.kept != tab.kept || plan.nest != tab.nest?.id)
                        if changed {
                            tab.kept = plan.kept && tab.keepable
                            tab.nest = plan.nest.flatMap { id in browser.nests.first { $0.id == id } }
                        }
                        browser.move(tab, to: plan.index)
                        if changed {
                            folders.refresh()
                            browser.writeSession(now: true)
                        }
                    }
                    dragging = nil
                    groupIDs = []
                    self.plan = nil
                    travel = 0
                    let landed = places(each: each, planned: false)[tab.id] ?? 0
                    heldWidths = nil
                    resting = tab.id
                    rest = visual - landed
                }
                withAnimation(Motion.settle) { rest = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard resting == tab.id, dragging == nil else { return }
                    withAnimation(Motion.quick) { resting = nil }
                }
    }

    private func finishGroup(_ tab: Tab, each: CGFloat) {
        clocks.stop()
        sprung = nil
        guard dragging == tab.id, let plan else { return }
        let ids = Set(groupIDs)
        let group = browser.tabs.filter { ids.contains($0.id) }
        let visual = pointer - grabAt
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            if plan.pinned {
                browser.pin(group, at: plan.index)
            } else if let into = plan.into, let nest = browser.nests.first(where: { $0.id == into }) {
                browser.file(group, in: nest)
            } else {
                let order = groupOrder(tab.id, at: plan.index)
                for member in group {
                    member.kept = plan.kept && member.keepable
                    member.nest = member.kept ? plan.nest.flatMap { id in browser.nests.first { $0.id == id } } : nil
                }
                browser.arrange(loose: order.filter { $0.pin == nil }.map(\.id))
                folders.refresh()
                browser.writeSession(now: true)
            }
            dragging = nil
            groupIDs = []
            self.plan = nil
            travel = 0
            let landed = places(each: each, planned: false)[tab.id] ?? 0
            heldWidths = nil
            resting = tab.id
            rest = visual - landed
        }
        withAnimation(Motion.settle) { rest = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if resting == tab.id, dragging == nil { resting = nil }
        }
    }

    /// A shut folder of yours whose pill the hand stays over for 0.6 s opens,
    /// its tabs coming out to its right, to put the held one between them;
    /// one opened so shuts again once the hand leaves it.
    private func spring(_ tab: Tab, next: Plan, x: CGFloat, each: CGFloat) {
        if let into = next.into, let nest = browser.nests.first(where: { $0.id == into }), !nest.open,
           browser.tabs.contains(where: { $0.nest?.within(nest) == true }) {
            guard clocks.springFor != into else { return }
            clocks.spring?.cancel()
            clocks.springFor = into
            let work = DispatchWorkItem { [self] in
                guard dragging == tab.id, plan?.into == into, !nest.open else { return }
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                sprung = into
                folders.toggle(nest.key) { [self] in plan?.into = nil }
            }
            clocks.spring = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            return
        }
        clocks.spring?.cancel()
        clocks.springFor = nil
        guard let open = sprung, let nest = browser.nests.first(where: { $0.id == open }), nest.open,
              next.nest.flatMap({ folders.nest($0) })?.within(nest) != true else { return }
        let now = layout(each: each, planned: false)
        let head = now.folders[nest.key] ?? 0
        let end = browser.tabs.filter { $0.nest?.within(nest) == true }.compactMap { now.tabs[$0.id] }.max().map { $0 + each } ?? head + each
        guard x < head - each / 2 || x > end + each / 2 else { return }
        sprung = nil
        folders.toggle(nest.key)
    }

    /// The pointer staying 0.5 s over another pill, one outside your
    /// folders: that pill offers a folder of the two. Moving on takes it back.
    private func dwell(_ tab: Tab, x: CGFloat, leading: CGFloat, each: CGFloat) {
        guard tab.keepable, plan?.into == nil, plan?.pinned == false,
              let over = overlapped(tab, leading: leading, each: each),
              over.by >= 0.3, over.by <= 0.7,
              let start = places(each: each, planned: true)[over.tab.id] else { return clearChoice() }
        let canSplit = browser.canCarry(tab, beside: over.tab)
        let side: TabDropChoice.Side = canSplit && x >= start + each / 2 ? .split : .folder
        if choice?.target == over.tab.id {
            if choice?.side != side {
                choice?.side = side
                choice?.fill = 0
                choice?.ready = false
                combine = nil
                clocks.hold?.cancel()
                if choice?.revealed == true { choose(tab, other: over.tab) }
            }
            return
        }
        clearChoice()
        choice = TabDropChoice(target: over.tab.id, side: side, canSplit: canSplit)
        let work = DispatchWorkItem { [self] in
            guard dragging == tab.id, choice?.target == over.tab.id else { return }
            choice?.revealed = true
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            choose(tab, other: over.tab)
        }
        clocks.dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TabDropChoice.revealDelay, execute: work)
    }

    private func choose(_ tab: Tab, other: Tab) {
        guard choice?.revealed == true else { return }
        if choice?.side == .split {
            if choicePreviousActive == nil { choicePreviousActive = browser.activeID }
            browser.select(other)
            browser.previewSplit(.right)
        } else {
            restoreChoicePreview()
            choice?.fill = 0
            DispatchQueue.main.async {
                guard choice?.target == other.id, choice?.side == .folder else { return }
                choice?.fill = 1
            }
            let work = DispatchWorkItem { [self] in
                guard dragging == tab.id, choice?.target == other.id, choice?.side == .folder else { return }
                choice?.count = (browser.partner(of: other) == nil ? 1 : 2) + (browser.partner(of: tab) == nil ? 1 : 2)
                choice?.ready = true
                combine = other.id
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
            clocks.hold = work
            DispatchQueue.main.asyncAfter(deadline: .now() + TabDropChoice.folderHold, execute: work)
        }
    }

    private func restoreChoicePreview() {
        guard choice?.side == .split || choicePreviousActive != nil else { return }
        browser.previewSplit(nil)
        if let id = choicePreviousActive, let previous = browser.tab(id: id) { browser.select(previous) }
        choicePreviousActive = nil
    }

    private func clearChoice() {
        clocks.dwell?.cancel()
        clocks.hold?.cancel()
        restoreChoicePreview()
        choice = nil
        combine = nil
    }

    /// The pill the held one is most over as drawn, and by how much of its
    /// width, if a folder of the two can be made.
    private func overlapped(_ tab: Tab, leading: CGFloat, each: CGFloat) -> (tab: Tab, by: CGFloat)? {
        let then = layout(each: each, planned: true).tabs
        let partner = browser.partner(of: tab)?.id
        var best: (tab: Tab, by: CGFloat)?
        for other in browser.tabs where other.id != tab.id && other.id != partner && other.pin == nil {
            guard let start = then[other.id], folders.place(of: other)?.shown ?? true else { continue }
            let by = (min(leading, start) + each - max(leading, start)) / each
            if by > (best?.by ?? 0) { best = (other, by) }
        }
        guard let best, best.tab.keepable,
              folders.place(of: best.tab).map({ Nest.isKey($0.folder) }) ?? true else { return nil }
        return best
    }

    /// Brings the tab you are on into view once the run scrolls: at once
    /// when the window first shows it, on the strip's spring when you pick
    /// another. A turn of the run loop later, so the run has been laid out.
    private func reveal(_ reader: ScrollViewProxy, in strip: CGFloat, gliding: Bool = false) {
        // Never under a drag: scrolling moves the space the drag is measured in.
        guard dragging == nil, overflowing(in: strip), let id = browser.activeID else { return }
        DispatchQueue.main.async {
            if gliding {
                withAnimation(Motion.glide) { reader.scrollTo(id) }
            } else {
                reader.scrollTo(id)
            }
        }
    }

    /// How wide the run of tabs is: as wide as the tabs while they fit, as
    /// wide as the room there is once they don't.
    private func overflowing(in strip: CGFloat) -> Bool {
        content(in: strip) > room(in: strip) + 0.5
    }

    /// Everything in the run at the width the tabs get, and the address
    /// field's width for a tab being edited, which grows to take it.
    private func content(in strip: CGFloat, widths proposed: StripWidths? = nil) -> CGFloat {
        let widths = proposed ?? heldWidths ?? widths(in: strip)
        var total = widths.content
        // One ahead of the capsule grows there (aheadWidth).
        if let id = browser.editingTab, let tab = browser.tabs.first(where: { $0.id == id }), !ahead.contains(where: { $0.id == id }) {
            total += min(340, strip - lead - 12) - (tab.pin != nil ? Metrics.pinWidth :
                tabWidth(tab, place: folders.place(of: tab), widths: widths))
        }
        // A tab carried across the line counts at the shape it has taken,
        // a pin pulled out among the titles is a title's width, and the run
        // has to hold it, or it is cut off at the run's end with the + still
        // where it was. Only its own width changes, once, as it crosses; the
        // other tabs keep theirs until it is let go.
        if let id = dragging, let plan, let tab = browser.tabs.first(where: { $0.id == id }),
           plan.pinned != (tab.pin != nil) {
            total += plan.pinned ? Metrics.pinWidth - widths.outer : widths.outer - Metrics.pinWidth
        }
        return total
    }

    /// The strip, less the lights, the plus, the doors at the far end and
    /// the air around them. The doors are measured; until they have been,
    /// a door's width stands in for them.
    private func room(in strip: CGFloat, bar: Bool? = nil) -> CGFloat {
        let far = bar ?? browser.bandDoors ? 0 : doors > 0 ? doors : 26
        return max(0, strip - lead - StripPress.endGap - Metrics.plusWidth - far - 3 * Metrics.tabGap)
    }

    /// How the next space's row will lie, as this one's is counted: the
    /// width its tabs get, those that travel with you included, and the run
    /// they take, with the doors at the far end or, its address bar up or
    /// its tab in front one of two side by side, without them. Never past
    /// the doors on screen now, which stay until the space is here.
    private func coming(_ row: Parked, in strip: CGFloat) -> StripComing.Lay {
        let tabs = row.tabs + browser.tabs.filter(browser.travels)
        let front = tabs.first { $0.id == row.active }
        let bar = row.pairs.contains { $0.first == row.active || $0.second == row.active }
            || browser.prefs.addressBar && front.map { !$0.isBlank && !$0.immersed && !$0.showsMail } == true
        // Its folders of yours a pill each, their tucked tabs none, and the
        // stroke after its kept (StripItem).
        let items = StripItem.items(tabs, active: row.active, open: folders.open, whole: folders.whole)
        let widths = widths(for: items, active: row.active, room: room(in: strip, bar: bar))
        return StripComing.Lay(widths: widths, run: min(widths.content, room(in: strip, bar: bar), room(in: strip)))
    }

    private func widths(in strip: CGFloat) -> StripWidths {
        var outer = 0
        var inner = 0
        // The pins in the run: those every space shares are ahead of it.
        let pinned = browser.pinnedCount - ahead.count
        var fixed: CGFloat = CGFloat(pinned) * Metrics.pinWidth
        var pills = pinned
        for folder in folders.folders {
            pills += 1
            if folders.isOpen(folder.id) {
                fixed += StripWidths.pillWidth(folder.nest?.name ?? Folders.title(folder.id))
            } else { outer += 1 }
        }
        for nest in folders.empties {
            pills += 1
            if nest.open { fixed += StripWidths.pillWidth(nest.name) } else { outer += 1 }
        }
        for tab in browser.tabs where tab.pin == nil {
            if let place = folders.place(of: tab) {
                if place.shown {
                    inner += 1
                    pills += 1
                    if place.more > 0 { fixed += StripWidths.moreWidth; pills += 1 }
                }
            } else { outer += 1; pills += 1 }
        }
        fixed += CGFloat(max(0, pills - 1)) * Metrics.tabGap
        if stroked { fixed += KeptDivider.width + Metrics.tabGap }
        return StripWidths.solve(room: room(in: strip), outer: outer, inner: inner,
                                 fixed: fixed, activeInside: browser.active.map { folders.place(of: $0)?.shown == true } ?? false,
                                 activeOutside: browser.active.map { $0.pin == nil && folders.place(of: $0) == nil } ?? false)
    }

    private func widths(for items: [StripItem], active: Tab.ID?, room: CGFloat) -> StripWidths {
        StripItem.widths(items, active: active, open: folders.open, room: room)
    }
}

/// Reading mode's book, offered only where there is something to read
/// (Tab.readable), which is how anyone finds out it exists: no notice, no
/// badge, a door that is there on an article and not on a feed. Lit while
/// reading, on the held plate, where it is the way back. At the address
/// bar's far end beside the camera (AddressBar), whichever side the tabs
/// are on; with no address bar, while the page is read, on a plate in the
/// page's top right corner (ReadingPlate), so Aa beside it is always there.
struct ReadingDoor: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    /// A half's own, in split view: it reads that half, whichever is in
    /// front. Otherwise the tab in front.
    var own = false

    /// The page has something to read, or is being read.
    static func offered(_ tab: Tab) -> Bool { !tab.isBlank && (tab.readable || tab.reader) }

    var body: some View {
        if tab.reader {
            // Lit, the way back; Aa beside it, the card of themes and
            // settings (ReaderCard), only while the page is read.
            Door(icon: "book.open", on: true, help: "Leave Reading Mode", shortcut: "Reading Mode") {
                browser.toggleReader(own ? tab : nil)
            }
            .accessibilityLabel("Leave Reading Mode")
            .benchSpot("reading door")
            ThemesDoor(browser: browser, tab: tab)
        } else {
            Door(icon: "book.open", on: tab.reader,
                 help: tab.reader ? "Leave Reading Mode" : "Reading Mode",
                 shortcut: "Reading Mode") { browser.toggleReader(own ? tab : nil) }
                .accessibilityLabel(tab.reader ? "Leave Reading Mode" : "Reading Mode")
                .benchSpot("reading door")
        }
    }
}

/// Reading mode's book and Aa where no address bar has them: on a plate in
/// the page's top right corner while the page is read, where the prototype
/// has them at the bar's end, so the way back and the card of themes are
/// in sight whatever the layout. Away the moment reading mode is.
///
/// Light or dark as the page it stands on: the reading theme's own light
/// (Themes & Settings' Light, Dark or Match the Mac), not the window's, as
/// the card it opens is. With only the window's, a dark reading page wore a
/// white plate and a light one a black plate (row 1054, #646).
struct ReadingPlate: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    /// Told where the plate stands in its host, for the host's presses.
    var placed: (CGRect) -> Void = { _ in }
    @ObservedObject private var style = ReaderStyle.shared
    /// The window's, which Match the Mac follows.
    @Environment(\.colorScheme) private var window

    var body: some View {
        if tab.reader {
            HStack(spacing: Door.Size.band.gap) {
                ReadingDoor(browser: browser, tab: tab)
            }
            .environment(\.doorSize, .band)
            .cardFrame()
            .environment(\.colorScheme, style.prefs.isDark(system: window == .dark) ? .dark : .light)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ReadingPlateHost.space)) } action: { placed($0) }
            .onDisappear { placed(.zero) }
            .transition(.opacity)
        }
    }
}

/// The plate in a view of its own over the page, as the card it opens is
/// (ReaderCard.Host): SwiftUI drawn over the page's own view never gets a
/// press, the page's view does. As wide and tall as the page, it takes
/// presses only on the plate.
struct ReadingPlateHost: NSViewRepresentable {
    let browser: Browser
    let tab: Tab
    nonisolated static let space = "reading-plate"

    func makeNSView(context: Context) -> PlateView {
        let view = PlateView(rootView: AnyView(EmptyView()))
        view.sizingOptions = []
        view.safeAreaRegions = []
        return view
    }

    func updateNSView(_ view: PlateView, context: Context) {
        view.rootView = AnyView(
            ReadingPlate(browser: browser, tab: tab) { [weak view] in view?.plate = $0 }
                .padding(.top, Metrics.rim)
                .padding(.trailing, Metrics.rim)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .coordinateSpace(name: Self.space)
                .hosted(in: context.environment)
        )
    }

    final class PlateView: NSHostingView<AnyView> {
        /// The plate, from the host's top left; empty while it is away.
        var plate: CGRect = .zero {
            didSet { if Bench.spotting { spot() } }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            let y = isFlipped ? local.y : bounds.height - local.y
            guard plate.contains(CGPoint(x: local.x, y: y)) else { return nil }
            return super.hitTest(point)
        }

        override func layout() {
            super.layout()
            if Bench.spotting { spot() }
        }

        /// The plate in the window's points from its top left, for the
        /// bench: a spot inside this host would be the host's own.
        private func spot() {
            guard let window, let content = window.contentView, !plate.isEmpty else { Bench.spots["reading plate"] = nil; return }
            let local = NSRect(x: plate.minX, y: isFlipped ? plate.minY : bounds.height - plate.maxY, width: plate.width, height: plate.height)
            let frame = convert(local, to: nil)
            Bench.spots["reading plate"] = CGRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        }
    }
}

/// Back, forward, reload. They watch the live tab, not the window: whether
/// there is anywhere to go back to is the tab's to say, and it changes with
/// every page. Used here, at the right edge of the sidebar's header, and
/// beside the small window's lights (LinkWindow), with a `steer` of its own.
struct Helm: View {
    @ObservedObject var browser: Browser
    /// A half's own, in split view: they act on that half, whichever is in
    /// front. Otherwise the tab in front's.
    var tab: Tab? = nil
    /// The book goes before back when the page has something to read (see
    /// `Wheel`), where the doors are held against an end, so they never
    /// move. Not in the address bar, which has it at its far end beside the
    /// camera (ReadingDoor), nor beside the lights in the row of tabs, nor
    /// where there is no room for a fourth door, a sidebar near its
    /// narrowest.
    var reads = true

    /// A narrow column's: "⋯" in reload's place, holding reload and the
    /// column's own door (HelmMore, ColumnHead).
    var folded = false

    /// A half behind its pair's front one: back, forward and nothing else,
    /// reload and the book kept in their room but out of sight.
    var quiet = false

    /// A page outside the browser's window, the small window's: the doors
    /// count their uses here and not on the browser, so the small window's
    /// keys kick its own doors and none of the browser's.
    var steer: HelmSteer? = nil

    /// Out of sight until wanted, the small window's doors in its field:
    /// back and forward kept in their room, reload there only while the
    /// page is coming, as the stop that tells it is. Still pressed where
    /// they are, though no pointer gets there without the field showing them.
    var resting = false

    /// Reload before back, the small window's field: its stop, the one door
    /// shown at rest, at the field's edge and not loose in its middle.
    var reloadFirst = false

    /// The address bar's: back and forward stay put when pressed, neither
    /// leaning nor giving (#727). The sidebar's, the row of tabs' and the
    /// small window's lean the way they go.
    var still = false

    @Environment(\.doorSize) private var size

    var body: some View {
        if tab != nil {
            doors(peek: nil)
        } else {
            Following(peek: browser.peekFront) { doors(peek: $0) }
        }
    }

    private struct Following<Content: View>: View {
        @ObservedObject var peek: PeekFront
        @ViewBuilder let content: (Tab?) -> Content
        var body: some View { content(peek.page) }
    }

    /// An explicit half keeps its own doors; the shared ones follow Peek.
    @ViewBuilder private func doors(peek: Tab?) -> some View {
        if let steer, let tab {
            Steered(browser: browser, tab: tab, steer: steer, reads: reads, resting: resting, reloadFirst: reloadFirst)
        } else if let tab = tab ?? peek ?? browser.active {
            Wheel(browser: browser, tab: tab, own: self.tab != nil, reads: reads, quiet: quiet, folded: folded, still: still)
        } else {
            // Nowhere to go and nothing to reload: the doors stay in place,
            // grayed, so the row doesn't shift when a tab arrives.
            HStack(spacing: size.gap) {
                Group {
                    Door(icon: "arrow.left") {}
                    Door(icon: "arrow.right") {}
                    if !folded { Door(icon: "arrow.clockwise") {} }
                }
                .disabled(true)
                if folded { HelmMore(browser: browser, tab: nil) }
            }
        }
    }

    /// The counts the doors' kicks follow, from whoever keeps them.
    struct Pulses: Equatable {
        var back: Int
        var forward: Int
        var reload: Int
    }

    /// The wheel answering to a steer, watched so its counts reach the doors.
    private struct Steered: View {
        let browser: Browser
        let tab: Tab
        @ObservedObject var steer: HelmSteer
        let reads: Bool
        let resting: Bool
        let reloadFirst: Bool

        var body: some View {
            Wheel(browser: browser, tab: tab, own: true, reads: reads, quiet: false, resting: resting, reloadFirst: reloadFirst, steer: steer,
                  pulses: Pulses(back: steer.backs, forward: steer.forwards, reload: steer.reloads))
        }
    }

    private struct Wheel: View {
        // Watched, not just held: the counts of backs, forwards and reloads
        // are what set the doors' icons going when a shortcut does it.
        @ObservedObject var browser: Browser
        @ObservedObject var tab: Tab
        let own: Bool
        let reads: Bool
        let quiet: Bool
        var folded = false
        var resting = false
        var reloadFirst = false
        var still = false
        /// Set for a page outside the browser's window: its uses are counted
        /// there, and `pulses` are its counts.
        var steer: HelmSteer? = nil
        var pulses: Pulses? = nil
        @Environment(\.doorSize) private var size

        var body: some View {
            let back = !tab.isBlank && tab.canGoBack
            let forward = !tab.isBlank && tab.canGoForward
            // The keys act on the tab in front: only its doors answer them.
            // A half behind plays its own kick when clicked. A steered
            // wheel's page is the only one its window's keys reach.
            let front = tab.id == browser.activeID || tab === browser.peeking
            let pulses = self.pulses ?? (front ? Pulses(back: browser.backs, forward: browser.forwards, reload: browser.reloads) : nil)
            let mine = own ? tab : nil
            HStack(spacing: size.gap) {
                if reads { book(mine) }
                if reloadFirst { reload(mine, pulses) }
                // Held, each lists the pages that way, as a swipe does.
                Door(icon: "arrow.left", help: "Back", shortcut: "Back", kick: still ? .none : .left,
                     pulse: still ? nil : pulses?.back, pressScale: still ? 1 : 0.96,
                     hold: back ? { browser.history(back: true, of: tab, own: own, from: $0) } : nil,
                     beside: back && steer == nil ? { browser.beside(back: true, of: tab, front: $0) } : nil) {
                    if let steer { steer.back(tab) } else { browser.back(mine) }
                }
                .disabled(!back)
                .opacity(resting ? 0 : 1)
                Door(icon: "arrow.right", help: "Forward", shortcut: "Forward", kick: still ? .none : .right,
                     pulse: still ? nil : pulses?.forward, pressScale: still ? 1 : 0.96,
                     hold: forward ? { browser.history(back: false, of: tab, own: own, from: $0) } : nil,
                     beside: forward && steer == nil ? { browser.beside(back: false, of: tab, front: $0) } : nil) {
                    if let steer { steer.forward(tab) } else { browser.forward(mine) }
                }
                .disabled(!forward)
                .opacity(resting ? 0 : 1)
                if folded {
                    HelmMore(browser: browser, tab: tab, own: own)
                } else if !reloadFirst {
                    reload(mine, pulses)
                }
            }
        }

        /// Reload, or stop while it is still coming.
        private func reload(_ mine: Tab?, _ pulses: Pulses?) -> some View {
            Door(
                icon: tab.loadingShown ? "xmark" : "arrow.clockwise",
                help: tab.loadingShown ? "Stop" : "Reload",
                shortcut: tab.loadingShown ? "Stop Loading" : "Reload Page",
                // Only a reload turns; a stop just lets the arrow come back.
                kick: .turn,
                pulse: pulses?.reload,
                beside: tab.isBlank || tab.loadingShown || steer != nil ? nil : { browser.reloadBeside(tab, front: $0) }
            ) {
                if tab.loading { steer == nil ? browser.stop(tab) : tab.stop() } else if let steer { steer.reload(tab) } else { browser.reload(mine) }
            }
            .disabled(tab.isBlank)
            .opacity(quiet || (resting && !tab.loadingShown) ? 0 : 1)
            .allowsHitTesting(!quiet)
        }

        /// Reading mode's book (ReadingDoor). It comes and goes at once,
        /// as the page changes, without a move of its own, and its room is
        /// kept when it is away: nothing else in the column's header shifts
        /// for it.
        private func book(_ mine: Tab?) -> some View {
            let offered = ReadingDoor.offered(tab)
            return ReadingDoor(browser: browser, tab: tab, own: mine != nil)
                .opacity(offered ? 1 : 0)
                .allowsHitTesting(offered)
                .accessibilityHidden(!offered)
        }
    }
}

/// Back, forward and reload for a page outside the browser's window, the
/// small window's (LinkWindow), counted as the browser counts its own
/// (Browser.backs), so a key in that window kicks that window's doors and
/// the browser's stay still.
@MainActor
final class HelmSteer: ObservableObject {
    @Published private(set) var backs = 0
    @Published private(set) var forwards = 0
    @Published private(set) var reloads = 0

    /// A door, or with `byKey` ⌘[ and ⌘], whose page just appears.
    func back(_ tab: Tab, byKey: Bool = false) {
        if !tab.isBlank, tab.canGoBack { backs += 1 }
        tab.back(byKey: byKey)
    }

    func forward(_ tab: Tab, byKey: Bool = false) {
        if !tab.isBlank, tab.canGoForward { forwards += 1 }
        tab.forward(byKey: byKey)
    }

    func reload(_ tab: Tab) {
        if !tab.isBlank { reloads += 1 }
        tab.reload()
    }
}

/// Watching the tab, not the browser. A pill that watched the browser was
/// drawn again, every one of them, whenever anything in the browser
/// changed, a pick, a keystroke in the field, a download's progress, and
/// with two hundred tabs a click to pick one spent most of its time on the
/// hundred and ninety-nine that looked the same before and after. What a
/// pill needs of the browser is handed in as values, and a pill whose
/// values have not changed is not drawn again (see `==`).
/// The space two fingers are taking the strip to: its tabs, drawn as the
/// strip draws its own, coming up from the 24 points they come in by as the
/// strip's own go (StripPull), cut where the + stands on its way to the
/// new run's end (StripPlus), as the run cuts its own. Only looked at; gone
/// once the space is here.
private struct StripComing: View {
    struct Lay {
        let widths: StripWidths
        let run: CGFloat
    }

    @ObservedObject var browser: Browser
    /// This space's run.
    let run: CGFloat
    let room: CGFloat
    let lay: (Parked) -> Lay
    @ObservedObject private var pull = SpacePull.shared
    /// Watched: every window's folders tell the first window's
    /// (Folders.init(sharing:)); this window's are read.
    @ObservedObject private var watched = Folders.shared
    private var folders: Folders { browser.folderBook }
    @Environment(\.tone) private var tone

    private func itemWidth(_ item: StripItem, widths: StripWidths, active: Tab.ID?) -> CGFloat {
        switch item {
        case .stroke: return KeptDivider.width
        case .folder(let folder):
            return Folders.isOpen(folder, among: folders.open) ? StripWidths.pillWidth(StripItem.name(folder)) : widths.outer
        case .more: return StripWidths.moreWidth
        case .tab(let tab, let folder):
            if tab.pin != nil { return Metrics.pinWidth }
            if folder != nil { return tab.id == active ? widths.activeInner : widths.inner }
            return tab.id == active ? widths.activeOuter : widths.outer
        }
    }

    /// Each folder's wash, from its pill to the end of the last of its
    /// tabs shown (and its "more"), as the strip's capsules are.
    private func comingParents(_ items: [StripItem]) -> [String: String] {
        var parents: [String: String] = [:]
        for item in items {
            if case .folder(let folder) = item, let parent = folder.nest?.parent { parents[folder.id] = parent.key }
        }
        return parents
    }

    private func comingCapsules(_ items: [StripItem], widths: StripWidths, active: Tab.ID?) -> [String: (CGFloat, CGFloat)] {
        var x: CGFloat = 0
        var spans: [String: (CGFloat, CGFloat)] = [:]
        for (index, item) in items.enumerated() {
            let width = itemWidth(item, widths: widths, active: active)
            switch item {
            case .folder(let folder):
                spans[folder.id] = (x, Folders.isOpen(folder, among: folders.open) ? x + width : x)
            case .tab(_, let folder?), .more(let folder, _):
                if let span = spans[folder] { spans[folder] = (span.0, x + width) }
            case .tab, .stroke: break
            }
            x += width + (index < items.count - 1 ? Metrics.tabGap : 0)
        }
        return spans.filter { $0.value.1 > $0.value.0 }
    }

    @ObservedObject private var turns = StripTurns.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let row = pull.coming(in: browser) {
            let lay = lay(row)
            // Coming up only once the old ones are mostly gone, so the two
            // rows never stand half seen over each other (StripTurn).
            picture(row, lay: lay)
                .offset(x: CGFloat(pull.dir) * StripTurn.arrival * (1 - pull.progress))
                .frame(width: run + (lay.run - run) * pull.progress, alignment: .leading)
                .clipped()
                .modifier(StripCross(progress: pull.progress, coming: true, on: true))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else if !(reduceMotion || SpaceTurn.still || !StripTurn.swiftUI("leaving")) {
            // The space just left: its tabs go 16 points the other way and
            // fade, gone by a little past half the new ones' arrival.
            let dir = CGFloat(browser.spaceStep)
            let row = turns.left.flatMap { $0 == browser.spaceID ? nil : browser.parked[$0] }
            Color.clear
                .frame(width: 0, height: Metrics.row)
                .keyframeAnimator(initialValue: CGFloat(1), trigger: turns.started) { _, r in
                    Group {
                        if let row, r < 1 / CGFloat(StripTurn.leaveSpeed) {
                            picture(row, lay: lay(row))
                                .offset(x: -dir * StripTurn.leave * r)
                                .opacity(Double(1 - CGFloat(StripTurn.leaveSpeed) * r))
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                } keyframes: { _ in
                    KeyframeTrack {
                        MoveKeyframe(turns.start)
                        LinearKeyframe(1, duration: StripTurn.arrivalTime, timingCurve: StripTurn.arrivalCurve)
                    }
                }
        }
    }

    /// How much of the next space's row shows, `p` of the way there.
    static func comingOpacity(_ p: CGFloat) -> CGFloat { StripTurn.coming(p) }

    /// A space's row as the strip lays it, drawn as one picture.
    private func picture(_ row: Parked, lay: Lay) -> some View {
        let widths = lay.widths
        let tabs = row.tabs + browser.tabs.filter(browser.travels)
        let items = Array(StripItem.items(tabs, active: row.active, open: folders.open, whole: folders.whole).prefix(24))
        return HStack(spacing: Metrics.tabGap) {
            // As the switch will lay it, the tabs that go with you from
            // space to space included.
            // The kept, the folders and the stroke after them, as the
            // row will draw them (Kept.swift, Folders).
            ForEach(items) { item in
                switch item {
                case .stroke:
                    KeptDivider()
                case .folder(let folder):
                    let width = itemWidth(item, widths: widths, active: row.active)
                    if let nest = folder.nest {
                        NestPill(browser: browser, nest: nest, count: folder.members.count, width: width, over: folder.over, still: true)
                    } else {
                        FolderPill(browser: browser, folder: folder, open: Folders.isOpen(folder, among: folders.open),
                                   width: width, among: tabs)
                    }
                case .more(let folder, let count):
                    FolderMore(folder: folder, count: count, width: StripWidths.moreWidth)
                case .tab(let tab, _):
                    TabPill(browser: browser, prefs: browser.prefs, tab: tab, live: tab.id == row.active,
                            width: itemWidth(item, widths: widths, active: row.active),
                            room: room, row: row, close: {})
                }
            }
        }
        .background(alignment: .leading) {
            let spans = comingCapsules(items, widths: widths, active: row.active)
                .map { NestedWash.Span(id: $0.key, start: $0.value.0, end: $0.value.1) }
            ZStack(alignment: .leading) {
                ForEach(NestedWash.lay(spans, parent: comingParents(items))) { wash in
                    RoundedRectangle(cornerRadius: wash.radius, style: .continuous)
                        .fill(Palette.wash(on: tone))
                        .frame(width: wash.end - wash.start, height: wash.height)
                        .offset(x: wash.start)
                }
            }
        }
        .frame(height: Metrics.row)
        .fixedSize()
        // One layer to fade, not each pill: a drawing group drew a pill's
        // AppKit parts as a crossed-out yellow box.
        .compositingGroup()
    }
}

/// The tabs after the capsule laid out at the new space's place at once,
/// and drawn from the old one's on the way there: `drawn` is animated,
/// `lead` is where they are laid. A padding animated instead laid the whole
/// strip out again every frame of the turn, twice the main thread's time.
private struct LeadSlide: GeometryEffect {
    var drawn: CGFloat
    let lead: CGFloat
    var animatableData: CGFloat {
        get { drawn }
        set { drawn = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: drawn - lead, y: 0))
    }
}

/// A new space's tabs across the top: there in the switch's own pass, 24
/// points in from the side the space lies on and faded, coming up over
/// 140 ms as the old row goes (StripTurn); after two fingers, from as far
/// as they had brought the next row (StripComing).
private struct StripArrival: ViewModifier {
    let space: UUID
    let step: Int
    @ObservedObject private var turns = StripTurns.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Arrival {
        var x: CGFloat = 0
        var opacity: CGFloat = 1
    }

    func body(content: Content) -> some View {
        let still = reduceMotion || SpaceTurn.still || !StripTurn.swiftUI("arrival")
        let start = turns.start
        let from = Arrival(x: StripTurn.arrival * CGFloat(step) * (1 - start), opacity: StripComing.comingOpacity(start))
        content
            .keyframeAnimator(initialValue: Arrival(), trigger: still ? nil : turns.started) { view, arrival in
                view.offset(x: arrival.x).opacity(Double(arrival.opacity))
            } keyframes: { _ in
                KeyframeTrack(\.x) {
                    MoveKeyframe(from.x)
                    LinearKeyframe(0, duration: StripTurn.arrivalTime, timingCurve: StripTurn.arrivalCurve)
                }
                KeyframeTrack(\.opacity) {
                    MoveKeyframe(from.opacity)
                    LinearKeyframe(1, duration: StripTurn.arrivalTime, timingCurve: StripTurn.arrivalCurve)
                }
            }
    }
}

/// The + after the strip's tabs, on its way to where the next space's run
/// will end while two fingers take the strip there. Back where it stands
/// the moment the space is here, the run then as long as it went.
private struct StripPlus: ViewModifier {
    let browser: Browser
    let run: CGFloat
    let lay: (Parked) -> StripComing.Lay
    @ObservedObject private var pull = SpacePull.shared

    func body(content: Content) -> some View {
        let shift = pull.coming(in: browser).map { (lay($0).run - run) * pull.progress } ?? 0
        content.offset(x: shift)
    }
}

/// What the coming row draws on top, in order, as the strip lays it
/// (Folders): a folder before its first tab, yours or a task's, its tabs
/// only while it is open (or the one to be on screen, or one asking), a
/// task's first four and how many more, and the stroke between the kept
/// and today's. `open` and `whole` are the strip's, so a task's tabs that
/// go with you from space to space come in folded as they are, not
/// spilled out of a folder that is shut.
@MainActor
enum StripItem: Identifiable {
    /// A tab, and the folder it is shown under, if it is.
    case tab(Tab, folder: String?)
    case stroke
    case folder(Folders.Folder)
    /// Under an open task folder's fourth, how many more it holds back.
    case more(String, Int)

    var id: String {
        switch self {
        case .tab(let tab, _): return tab.id.uuidString
        case .stroke: return "stroke"
        case .folder(let folder): return folder.id
        case .more(let folder, _): return "more " + folder
        }
    }

    static func items(_ tabs: [Tab], active: Tab.ID?, open: Set<String> = [], whole: Set<String> = []) -> [StripItem] {
        let loose = tabs.filter { $0.pin == nil }
        let made = Folders.marked(Folders.nests(in: loose) + Folders.tasks(in: loose), among: loose)
        let byID = Dictionary(made.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let places = Folders.lay(made, isOpen: { Folders.isOpen($0, among: open) }, whole: whole, folding: [], active: active,
                                 awake: Folders.awake(in: loose)).places
        var out: [StripItem] = []
        var kept = false
        var stroked = false
        for tab in tabs {
            if tab.pin == nil {
                if tab.kept {
                    kept = true
                } else if kept, !stroked {
                    out.append(.stroke)
                    stroked = true
                }
            }
            guard tab.pin == nil, let place = places[tab.id], let folder = byID[place.folder] else {
                out.append(.tab(tab, folder: nil))
                continue
            }
            // A pill for each folder it is the first tab of, the outer first.
            for key in place.heads { if let head = byID[key] { out.append(.folder(head)) } }
            if place.shown { out.append(.tab(tab, folder: folder.id)) }
            if place.more > 0 { out.append(.more(folder.id, place.more)) }
        }
        return out
    }

    /// What an open folder's pill is as wide as, as the strip's are.
    static func name(_ folder: Folders.Folder) -> String {
        folder.nest?.name ?? Folders.title(folder.id)
    }

    /// The widths the row's tabs get in `room`, counted as the strip counts
    /// its own (TabBar's widths(in:)): a pin its own width, an open folder
    /// its name's, a shut one and each loose tab a share, a folder's tab
    /// shown under it a narrower share, a "more" its own width.
    static func widths(_ items: [StripItem], active: Tab.ID?, open: Set<String>, room: CGFloat) -> StripWidths {
        var outer = 0
        var inner = 0
        var fixed: CGFloat = 0
        var activeInside = false
        var activeOutside = false
        for item in items {
            switch item {
            case .stroke: fixed += KeptDivider.width
            case .folder(let folder):
                if Folders.isOpen(folder, among: open) { fixed += StripWidths.pillWidth(name(folder)) } else { outer += 1 }
            case .more: fixed += StripWidths.moreWidth
            case .tab(let tab, let folder):
                if tab.pin != nil {
                    fixed += Metrics.pinWidth
                } else if folder != nil {
                    inner += 1
                    if tab.id == active { activeInside = true }
                } else {
                    outer += 1
                    if tab.id == active { activeOutside = true }
                }
            }
        }
        fixed += CGFloat(max(0, items.count - 1)) * Metrics.tabGap
        return StripWidths.solve(room: room, outer: outer, inner: inner, fixed: fixed,
                                 activeInside: activeInside, activeOutside: activeOutside)
    }
}

extension EnvironmentValues {
    /// The room along the top the tabs drawn here stand in, if any.
    @Entry var stripRoom: KeySky.Anchor? = nil
}

private struct TabPill: View, Equatable {
    let browser: Browser
    // Browser forwards preference changes to the parent. Snapshot the one
    // preference this pill draws so unrelated changes can pass through ==.
    let glyph: Glyph
    /// How tall it stands (Density.tab).
    let density: Density
    @ObservedObject var tab: Tab
    let live: Bool
    /// The browser's, for this tab.
    let editing: Bool
    let editingPin: Bool
    let picked: Bool
    let refusals: Int
    /// One of two tabs side by side (Split.swift): the pill is drawn as one
    /// with its other half's, the two of them one tab in the row.
    let joint: Joint?
    /// The pair is on screen, this half in front or not.
    let paired: Bool
    /// The next space's (StripComing): an agent's face at rest (StillFace).
    let pictured: Bool
    let width: CGFloat
    /// How much of the strip there is, for the field that grows over it.
    let room: CGFloat
    let close: () -> Void

    @State private var hovering = false
    @State private var shake: CGFloat = 0
    @Environment(\.tabTitleSize) private var titleSize

    /// Drawn as a pin, or as a title, whatever the tab is: a tab carried over
    /// the pins folds into a square before it is one, and a pin carried out
    /// among the titles unfolds.
    var asPin: Bool?
    /// In the hand: a ground of its own, the strip's color, under the gray,
    /// so the tabs it passes over don't show through it.
    var lifted = false
    /// The open tab while no band over the page has the site's sliders:
    /// ⌘E's panel hangs from its mark.
    var hangs = false
    /// Where the panel hangs: the tab's mark.
    @State private var anchor = ViewBox()
    /// Which room along the top it is in (KeySky.Anchor).
    @Environment(\.stripRoom) private var stripRoom
    /// This pill's word on where its tab is (KeySky.unlay).
    @State private var placeID = UUID()

    /// `row`: a row not yet the browser's, the next space's (StripComing),
    /// its pairs its own.
    init(browser: Browser, prefs: Preferences, tab: Tab, live: Bool, width: CGFloat, room: CGFloat, row: Parked? = nil, asPin: Bool? = nil, lifted: Bool = false, hangs: Bool = false, close: @escaping () -> Void) {
        self.browser = browser
        glyph = prefs.glyph
        density = prefs.density
        self.tab = tab
        self.live = live
        editing = browser.editingTab == tab.id
        editingPin = browser.editingPin == tab.id
        picked = !live && browser.isPicked(tab)
        refusals = browser.refusals
        pictured = row != nil
        if let row {
            let pair = row.pairs.first { $0.first == tab.id || $0.second == tab.id }
            joint = pair.map { $0.first == tab.id ? .first : .second }
            paired = pair.map { $0.first == row.active || $0.second == row.active } ?? false
        } else {
            joint = browser.joint(of: tab.id)
            paired = joint != nil && browser.stagePair?.contains(tab.id) == true
        }
        self.width = width
        self.room = room
        self.asPin = asPin
        self.lifted = lifted
        self.hangs = hangs
        self.close = close
    }
    @Environment(\.tone) private var tone

    /// Everything handed in but the closure, which is the same close every
    /// time and cannot be compared.
    static func == (a: TabPill, b: TabPill) -> Bool {
        a.tab === b.tab && a.glyph == b.glyph && a.density == b.density && a.live == b.live && a.width == b.width && a.room == b.room
            && a.asPin == b.asPin && a.lifted == b.lifted && a.editing == b.editing
            && a.editingPin == b.editingPin && a.picked == b.picked && a.refusals == b.refusals
            && a.joint == b.joint && a.paired == b.paired && a.hangs == b.hangs && a.pictured == b.pictured
    }
    private var pinned: Bool { (asPin ?? (tab.pin != nil)) && !editing }
    /// Kept, and gone on from the page it was kept at (PinnedHome.swift).
    private var away: Bool { !editing && !pinned && tab.awayFromHome }
    /// Too narrow for a title: the site's mark alone, the title in the
    /// tooltip, and ⌘W or the menu to close it, a cross on something this
    /// small would be what a click to pick the tab lands on.
    private var compact: Bool { !editing && !pinned && width < Metrics.tabTitled }

    /// A pinned tab is a square, an edited one is a field, everything else is
    /// its share of what is left.
    private var span: CGFloat {
        if editing { return min(340, room) }
        return pinned ? Metrics.pinWidth : width
    }

    var body: some View {
        let _ = StripRenderMeter.tab(inner: tab.nest != nil || Folders.shared.place(of: tab) != nil)
        Group {
            if pinned {
                Group {
                    if editingPin {
                        PinField(browser: browser, tab: tab)
                    } else {
                        keyed(16, room: 7, lettered: !((glyph == .icons || tab.customMark != nil) && tab.displayIcon != nil)) {
                            PinNumber(browser: browser, tab: tab, size: 12, tint: color) {
                                if glyph == .icons || tab.customMark != nil, let icon = tab.displayIcon {
                                    Mark(icon: icon, letter: tab.pin ?? tab.monogram, size: 16)
                                } else {
                                    Text(tab.pin ?? tab.monogram)
                                        .font(.system(size: 12, weight: .medium))
                                        // A pin holding no page is still there and still
                                        // yours, at full ink: after a launch every pin but
                                        // the open one sleeps, and faded they read as gone.
                                        .foregroundStyle(color)
                                }
                            }
                            // The mark's square whatever is in it (see PinSquare).
                            .frame(width: 16, height: 16)
                        }
                    }
                }
                .frame(width: 16, height: 16)
                .padding(.horizontal, 7)
                .padding(.vertical, Density.current.tabPad)
                .frame(width: span)
                // A pinned calendar's next meeting: the pin says it (PinMeeting).
                .modifier(PinMeeting(browser: browser, tab: tab, calls: browser.calls, radius: Radius.control))
                // No room in a pin for the sliders: ⌘E's panel and the
                // menu's hang from the pin itself.
                .background { if hangs { PanelAnchor(box: anchor).allowsHitTesting(false) } }
            } else {
                loose
            }
        }
        .background { ground }
        // The open tab of a page on this Mac's own server (DevMode.swift).
        .overlay { if live && tab.isDev { DevTape() } }
        // Where the tab stands, for a page's question to hang from, its
        // card, a middle press: in its room along the top, which KeySky
        // takes to the window as it is read (StripAnchor). Not the next
        // space's, drawn into a picture, nor the copy a carried tab is
        // drawn as over itself.
        .onGeometryChange(for: CGRect.self) { [space = stripRoom?.room.space] proxy in
            space.map { proxy.frame(in: .named($0)) } ?? proxy.frame(in: .global)
        } action: { [id = tab.id, sky = browser.keySky, room = stripRoom, by = placeID, own = !pictured && asPin == nil] frame in
            guard own else { return }
            if let room { sky.lay(id, frame, in: room, by: by) } else { sky.lay(id, frame) }
        }
        .onDisappear { [id = tab.id, sky = browser.keySky, by = placeID] in sky.unlay(id, by: by) }
        .background {
            if lifted {
                RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous) // design: a tab's row (Density.radius)
                    .fill(tone?.color ?? Palette.ground)
            }
        }
        .modifier(Shake(travel: shake))
        .contentShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)) // design: a tab's row (Density.radius)
        // Select on the first click; the browser remembers it across the
        // redraw so a second click can rename it or return a pin home.
        .onTapGesture { browser.tapTab(tab) }
        .onHover { on in
            hovering = on
            browser.glance.hover(tab.id, on)
            // Down to its face, the whole tab is the face.
            if compact, !pinned, tab.wearsFace { browser.glance.face(tab.id, on) }
            // One of the pair on screen: its half outlined faintly, unless it
            // is the one in front.
            if paired { browser.splitHint.hint(tab.id, on && !live) }
        }
        .overlay { if joint != nil { LeaveMark(hint: browser.splitHint, id: tab.id) } }
        .onChange(of: lifted) { _, held in if held { browser.glance.drop() } }
        .steadyMenu(actions: true) { TabMenu(browser: browser, tab: tab, close: close) }
        .iconPicker(tab, in: browser)
        .splitMateIconPicker(browser.pinMate(of: tab), in: browser)
        .animation(Motion.glide, value: editing)
        .animation(Motion.glide, value: tab.pin)
        .onChange(of: refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        // Arriving and leaving from the strip rather than from nowhere.
        // Picked or not is a state, not a journey: whatever else is moving
        // when it changes, the gray lands at once.
        .animation(nil, value: live)
        .animation(nil, value: picked)
        // An arrival takes its place whole, it is the button's own spot,
        // and the button steps aside for it. A leaving fades and gives a
        // little, over less time than the room it leaves takes to close.
        .transition(.asymmetric(insertion: .identity, removal: .opacity.combined(with: .scale(scale: 0.96))))
    }

    @ViewBuilder
    private var loose: some View {
        if compact {
            keyed(15, room: (span - 16) / 2) {
                ZStack {
                    if tab.wearsFace {
                        // Down to one square: the agent's face is what's worth
                        // showing, and resting on it is resting on the face.
                        AgentFace(tab: tab, tint: color, tip: false, still: pictured)
                    } else if tab.spinning {
                        Ring()
                    } else {
                        PinNumber(browser: browser, tab: tab, size: 12, tint: color) {
                            Mark(icon: (glyph == .icons || tab.customMark != nil) ? tab.displayIcon : nil, letter: tab.monogram, size: 15, dim: tab.asleep)
                        }
                    }
                }
            }
            .frame(width: 16, height: 16)
            .padding(.vertical, Density.current.tabPad)
            .frame(width: span)
            // Down to its mark: the panel hangs from the tab itself.
            .background { if hangs { PanelAnchor(box: anchor).allowsHitTesting(false) } }
        } else {
            titled
        }
    }

    private var titled: some View {
        HStack(spacing: 6) {
            if editing {
                TabAddressField(browser: browser, tab: tab.id)
                    .frame(height: 16)
            } else {
                if glyph == .icons {
                    // 6 points to the title, one of them kept clear.
                    keyed(Self.markSide, room: 5, worded: worded) {
                        if tab.isBlank {
                            // Nowhere yet, so no site's mark, but still something
                            // in the mark's place, so a new tab's title lines up
                            // with every other one's.
                            // A private one's is the mask, in the globe's place.
                            Symbol(tab.shy ? "incognito" : "globe", size: 11)
                                .foregroundStyle(color)
                                .frame(width: Self.markSide, height: Self.markSide)
                        } else {
                            // Its number while ⌘ is held, as a pin's (KeyNumbers).
                            PinNumber(browser: browser, tab: tab, size: Self.markSide * 12 / 16, tint: color) {
                                Mark(icon: tab.displayIcon, letter: tab.monogram, size: Self.markSide, corner: Self.markCorner)
                            }
                            .frame(width: Self.markSide, height: Self.markSide)
                        }
                    }
                } else if tab.offer?.parked == true || (tab.asks.first?.parked == true && !(worded && tab.wantsScreen)) || tab.handoff != nil || tab.camera != .none || tab.microphone != .none {
                    // Tabs without marks still get the key, the bubble and
                    // the dot, in front of the name.
                    keyed(15, room: 5, worded: worded) { EmptyView() }
                } else {
                    LooseCount(tab: tab)
                }
                if tab.shy, browser.windowPurpose == .normal, !(glyph == .icons && tab.isBlank) {
                    // Quiet, and only on the tabs that keep nothing, among
                    // ones that keep everything: a private window's are all
                    // private, said once at its foot.
                    Symbol("incognito", size: 9)
                        .foregroundStyle(color.opacity(0.7))
                }
                // Gone on from where it was kept: a slash, then the page
                // it is on, as Arc's pinned tab says it (PinnedHome.swift).
                if away {
                    HomeSlash(tab: tab, size: titleSize, tint: Palette.faint(on: tone))
                }
                // To the pill's own edge, under the slot, and out into
                // nothing there; the fade moves in only while the slot has
                // something in it.
                FadingTitle(text: away ? tab.awayLabel : tab.rowLabel, font: .system(size: titleSize), rest: look(hot: false, slotted: false), busy: look(hot: false, slotted: true), open: look(hot: true, slotted: true), slotted: busy, opened: hovering)
                    // Only when what it paints changes: a Canvas can't tell
                    // otherwise, and would repaint with every redraw of the tab,
                    // the reading gray's included.
                    .equatable()
                    // A tab opened: the others narrow on a spring, and the name
                    // goes to its new width at once rather than with them,
                    // painted once, not at each of the slide's widths (every
                    // name in the row, every frame: over 1,600 paints an open).
                    // It is only ever narrower than the pill around it.
                    .transaction { if Narrow.inkSnap, browser.tabsGrew { $0.animation = nil } }
                // Showing a page a screen, or shown to one (Share.swift).
                ShareWord(tab: tab, hovering: hovering)
                // A share asked for while behind, waiting here, where the
                // tab has room for the words (ShareWaiting.swift).
                ShareWaiting(tab: tab, shown: worded)
                // What a live folder's tab needs (LiveViews.swift).
                LiveWordsView(tab: tab, clearance: showsDevPort ? 0 : TabEnd.clear(tab, hovering: hovering, slotted: busy || hovering))
                // A page watched for the user (PageWatches.swift).
                WatchWords(tab: tab, short: true)
                // A page on this Mac's own server: which port (DevMode.swift).
                if showsDevPort {
                    DevPort(tab: tab, hovering: hovering, gap: 6)
                }
            }
        }
        // As tall as a pin's content and a compact tab's: 28 with the
        // padding, whatever the mark, so a row of tabs is one height.
        .frame(height: 16)
        // ⌘E's panel hangs from the mark, as from a tab down to it.
        .overlay(alignment: .leading) {
            if hangs { PanelAnchor(box: anchor).frame(width: 15, height: 16).allowsHitTesting(false) }
        }
        // The mark as far in from the tab's start as from its top and
        // bottom, as the cross's square is from its end; letters and the
        // field keep their 11.
        .padding(.leading, glyph == .icons && !editing ? Self.markInset : 11)
        .padding(.trailing, editing ? 11 : 7)
        .padding(.vertical, Density.current.tabPad)
        .frame(width: span, alignment: .leading)
        // Gone on from where it was kept: the mark is the way back, in a
        // square at the tab's start, as Arc's favicon is (PinnedHome.swift).
        .modifier(HomeMark(browser: browser, tab: tab, away: away && glyph == .icons && !editing, plate: .strip))
        // Pinned to the right-hand end of the pill, over the end of the title.
        .overlay(alignment: .trailing) {
            TabEnd(browser: browser, tab: tab, live: live, hovering: hovering, editing: editing, tint: color, close: close)
                .padding(.trailing, TabEnd.stripEnd)
        }
    }

    /// The mark across the top: 16, an even side like the 28 it stands in,
    /// so it stands on whole points six in all round, concentric with the
    /// tab, its corner the tab's less those six.
    static let markSide: CGFloat = 16
    static var markInset: CGFloat { (Density.current.tab - markSide) / 2 }
    static var markCorner: CGFloat { max(0, SideBar.radius - markInset) }

    /// Wide enough to say a share waiting on it in words.
    private var worded: Bool { span >= ShareWaiting.fits }

    @ViewBuilder
    private var ground: some View {
        if let joint, !pinned {
            JointGround(joint: joint, lit: live || paired, hovering: hovering, reading: live && paired && !editing ? tab.reading : 0, gap: Metrics.tabGap, across: true, front: paired, prefs: browser.prefs)
        } else if live {
            // In reading mode the gray fills from the left as you read down. It is
            // the one thing in the window that says how far in you are, and
            // it says it without adding anything to the window.
            ZStack(alignment: .leading) {
                SelectionPlate(corner: SideBar.radius, state: .selected, prefs: browser.prefs, strip: true)
                // Not on a pinned square, nor a tab down to its mark. Thirty
                // points of gray filling from the left behind a single letter
                // says nothing about anything, it needs the width of a title
                // to read as progress at all.
                // Nor while the tab is being named: what you type there
                // isn't the page, and half a field in a darker gray read as
                // something still loading.
                if !pinned && !compact && !editing {
                    Rectangle()
                        .fill(Palette.ink.opacity(0.055))
                        .frame(width: span * tab.reading)
                        .animation(.easeOut(duration: 0.15), value: tab.reading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)) // design: a tab's row (Density.radius)
                }
            }
        } else if picked {
            // Picked alongside the open one: its gray, lighter, a pin's
            // resting ground is already that light, so a picked pin gets the
            // open one's whole.
            SelectionPlate(corner: SideBar.radius, state: pinned ? .selected : .picked, prefs: browser.prefs, strip: true)
        } else if pinned {
            // A letter with nothing behind it reads as debris. A pinned tab
            // keeps a faint ground of its own so the block of them reads as
            // one thing; under the pointer it comes a step up.
            SelectionPlate(corner: SideBar.radius, state: .resting(hovering: hovering))
        } else if hovering {
            SelectionPlate(corner: SideBar.radius, state: .hover)
        }
    }

    private var color: Color { ink(hot: hovering) }

    private func ink(hot: Bool) -> Color {
        // Both halves of a pair on screen read alike (see JointGround).
        if live || picked || paired { return Palette.ink }
        return hot ? Palette.strong(on: tone).opacity(0.88) : Palette.muted(on: tone)
    }

    /// The name at rest, at rest with the slot at the end taken, and under
    /// the pointer: all painted, the tab only shows one or another (see
    /// `FadingTitle`).
    private func look(hot: Bool, slotted: Bool) -> FadingTitle.Look {
        // A routine's folder's page that has gone: struck, faint, until its next run.
        let gone = tab.live?.said?.gone == true
        return FadingTitle.Look(color: gone ? Palette.faint(on: tone) : ink(hot: hot), clear: showsDevPort || LiveWordsView.hasWords(tab) ? 0 : TabEnd.clear(tab, hovering: hot, slotted: slotted),
                                fade: slotted ? 28 : 40, strike: gone)
    }

    /// Below this width a port would leave under 60 points for a titled tab.
    private var showsDevPort: Bool { tab.devPort != nil && !tab.onCall && width >= 168 }

    /// Something in the slot at the tab's end, with the pointer away.
    private var busy: Bool {
        tab.spinning || tab.noisy || tab.muted || tab.wearsFace
    }

    /// The tab's mark, or the key of a password waiting on it. `room`: what
    /// is right of the mark inside the tab, for the words at its corner.
    private func keyed(_ size: CGFloat, room: CGFloat = .infinity, lettered: Bool = false, worded: Bool = false,
                       @ViewBuilder _ mark: @escaping () -> some View) -> some View {
        TabMark(tab: tab, sky: browser.keySky, size: size, tint: color, unpark: { [browser, tab] in browser.unparkOffer(tab) },
                room: room, lettered: lettered, worded: worded, mark: mark)
    }
}

/// The tab's name, typed into the tab itself.
///
/// A field of its own rather than SwiftUI's, for one reason: the system paints
/// selected text as a solid block of accent color, which over a pale gray pill
/// this size is the loudest thing in the window. Here it is a tenth of the ink.
struct TabAddressField: NSViewRepresentable {
    @ObservedObject var browser: Browser
    /// The tab whose row this field is in: a row drawn again for another
    /// tab (a column cell reused) never takes the keys for this one's edit.
    let tab: Tab.ID

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeNSView(context: Context) -> NSTextField {
        let field = TabNameField()
        context.coordinator.editing = tab
        context.coordinator.hold(field)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: context.environment.tabTitleSize)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        // A name longer than the tab scrolls under the caret, as any Mac
        // field's does: unscrolled, ⌥← ⌥→ and ⌘← ⌘→ moved a caret that
        // stayed past the field's end, out of sight (register #380).
        field.cell?.isScrollable = true
        field.isAutomaticTextCompletionEnabled = false
        field.stringValue = browser.tabDraft
        // Edit…'s: the home it opens first, as Arc's sheet says it.
        field.placeholderString = browser.editingHome ? "Address it opens first" : nil
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let font = NSFont.systemFont(ofSize: context.environment.tabTitleSize)
        if field.font != font {
            field.font = font
            field.currentEditor()?.font = font
        }
        let coordinator = context.coordinator
        coordinator.browser = browser
        coordinator.editing = tab
        field.appearance = context.environment.tone?.appearance
        if !coordinator.typing, field.stringValue != browser.tabDraft {
            field.stringValue = browser.tabDraft
        }
        coordinator.claim()
    }

    /// The field itself, which takes the keys when it comes into a window
    /// rather than on a clock. A long session's column can take a second
    /// to put the row on screen (#1899's own report: paint p95 1.2 s); a
    /// claim timed out at 0.2 s gave up first and left the edit open in a
    /// field with no keys, which no double-click or Rename… could start
    /// again, the same tab's edit asked for once more changing nothing
    /// (feedback #1899, #1902).
    final class TabNameField: NSTextField {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, let coordinator {
                TabAddressField.arrived = CACurrentMediaTime() - coordinator.browser.editBeganAt
            }
            coordinator?.claim()
        }
    }

    /// Seconds from the last begin to its field in a window, and to its
    /// keys taken: what the old 0.2 s claim had to beat (bench `kept`).
    static var arrived: Double?
    static var keyed: Double?

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var typing = false
        /// The tab this field was for: its end puts down only that edit,
        /// never a newer one begun as this row was drawn again.
        var editing: UUID?
        private weak var field: NSTextField?
        private var claiming = false
        /// The begin (Browser.editRound) the keys were last taken for: once
        /// for each, so a click away (a page's field) is never answered by
        /// the keys taken back before the edit is put down.
        private var served: Int?

        init(browser: Browser) { self.browser = browser }

        func hold(_ field: TabNameField) {
            self.field = field
            field.delegate = self
            field.coordinator = self
            // Rename asked for again, the same tab's included: the field
            // takes the keys back even though nothing it shows changed.
            NotificationCenter.default.addObserver(self, selector: #selector(editBegan(_:)), name: Browser.tabEditBegan, object: nil)
        }

        @objc private func editBegan(_ note: Notification) {
            guard note.object as? Browser === browser else { return }
            claim()
        }

        /// Whether the field has the window's keys now.
        var hasKeys: Bool {
            guard let field, let editor = field.currentEditor() else { return false }
            return field.window?.firstResponder === editor
        }

        /// The keys for the field, once it is in a window: the moment it
        /// arrives there (TabNameField), and again at each begin. Refused
        /// in its window, the edit is put down rather than left open in a
        /// field nobody can type in.
        func claim(tries: Int = 5) {
            guard let field, field.window != nil, !field.isHiddenOrHasHiddenAncestor, !claiming,
                  served != browser.editRound, !hasKeys, let editing, browser.editingTab == editing else { return }
            claiming = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 5 ? 0 : 0.05)) { [weak self] in
                guard let self else { return }
                self.claiming = false
                guard let field = self.field, let window = field.window, self.served != self.browser.editRound,
                      self.browser.editingTab == editing, !self.hasKeys else { return }
                guard window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else {
                    if tries > 1 { return self.claim(tries: tries - 1) }
                    return self.browser.cancelTabEdit()
                }
                self.served = self.browser.editRound
                TabAddressField.keyed = CACurrentMediaTime() - self.browser.editBeganAt
                editor.selectedTextAttributes = [
                    .backgroundColor: NSColor(Palette.ink.opacity(0.11)),
                    .foregroundColor: Palette.NS.ink,
                ]
                editor.selectAll(nil)
            }
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            typing = true
            browser.tabDraft = field.stringValue
            typing = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                browser.commitTabEdit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                browser.cancelTabEdit()
                return true
            default:
                return false
            }
        }

        /// Clicking anywhere else is a way of saying never mind.
        func controlTextDidEndEditing(_ note: Notification) {
            let browser = browser, editing = editing
            DispatchQueue.main.async {
                if editing == nil || browser.editingTab == editing { browser.cancelTabEdit() }
            }
        }
    }
}

/// Move to Space: the other spaces, ⌃⇧ and the place of each, and a new
/// one made around the tabs. Only when there are spaces. A tab an agent is
/// at work in has it too, and an agent's own: sent, it stays in that space
/// and the agent goes on in it (Browser.moveTabs). Not a script's bench
/// tab, which shows nowhere.
struct SpaceSend: View {
    @ObservedObject var browser: Browser
    let tabs: [Tab]
    var title: String? = nil
    /// The only group of its Move to: it stands in the menu as Move to Space.
    var alone = false

    var body: some View {
        if browser.spacesShown, tabs.contains(where: Browser.movable) {
            // From a Blank Window, its own space too (BlankWindow.swift).
            let others = browser.spaces.filter { $0.id != browser.spaceID || browser.blank }
            let lead = title == nil || alone
            if others.isEmpty {
                // New Space… is all there is to pick: the row is that, not a
                // submenu holding it.
                let n = tabs.count
                Button(lead ? (n == 1 ? "Move to New Space\u{2026}" : "Move \(n) Tabs to New Space\u{2026}") : "New Space\u{2026}", mark: "square.2.layers.3d") {
                    SpaceTray.open(browser, taking: tabs)
                }
            } else {
                Menu(alone ? "Move to Space" : title ?? (tabs.count == 1 ? "Move to Space" : "Move \(tabs.count) Tabs to Space"), mark: "square.2.layers.3d") {
                    ForEach(Array(browser.spaces.enumerated()), id: \.element.id) { index, space in
                        let here = space.id == browser.spaceID
                        Button(space.marked("  ")) { send(to: space.id) }
                            .disabled(here && !browser.blank)
                            // ⌃⇧N counts as ⌃N does, Mail in its place among them.
                            .modifier(PlaceKey(index: browser.turnOrder.firstIndex { $0.id == space.id } ?? index))
                    }
                    Divider()
                    Button("New Space\u{2026}", mark: "square.2.layers.3d") { SpaceTray.open(browser, taking: tabs) }
                }
            }
        }
    }

    /// As Arc's Move to: the rows close up a beat after the menu has gone
    /// (Browser.folderLeavesAfter); the tab on screen among them, the
    /// window follows it there, on the space's own slide, and nothing needs
    /// saying. Others are sent, and the corner says where. A shared pin on
    /// screen is in the other space's pins already: the window goes there
    /// and it stays in front.
    func send(to target: UUID) {
        let hand = Browser.handMade
        let follow = tabs.contains { $0.id == browser.activeID }
        DispatchQueue.main.asyncAfter(deadline: .now() + Browser.folderLeavesAfter) { [browser, tabs] in
            let was = Browser.pretendHand
            Browser.pretendHand = hand
            browser.columnCurve = Browser.folderLeaves
            let front = browser.active
            let there = front.map { browser.pinnedAlready($0, in: target) } ?? false
            let moved = browser.moveTabs(tabs, to: target, say: !follow)
            Browser.pretendHand = was
            if follow, moved != nil || there {
                browser.switchSpace(to: target)
                // Separate sign-ins replace the moved tab. Follow the arrival
                // returned by the transfer, rather than the old tab's id.
                let arrived = moved?.tabs.first { $0.original == front?.id }?.now ?? (there ? front : nil)
                if let arrived, browser.tabs.contains(where: { $0 === arrived }) { browser.select(arrived) }
            }
        }
    }

    /// ⌃⇧1 to ⌃⇧9 beside the first nine, as the keys go.
    private struct PlaceKey: ViewModifier {
        let index: Int
        func body(content: Content) -> some View {
            if index < 9, let action = Shortcut.numbered("sendSpace", index + 1) {
                content.shortcut(action)
            } else {
                content
            }
        }
    }
}

/// What a right-click on any tab offers, wherever the tab is drawn.
/// Show Count or Hide Count, for the site: every pin and kept tab of it.
private struct CountToggle: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var choices = CountSites.shared

    var body: some View {
        Button(Counts.shows(tab.address) ? "Hide Count" : "Show Count", mark: "yab.hash") { Counts.toggle(tab.address) }
    }
}

struct TabMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject private var windows = BrowserWindows.shared
    let close: () -> Void

    var body: some View {
        let group = browser.group(for: tab)
        let split = browser.pair(of: tab.id).flatMap { pair in
            group.allSatisfy { pair.contains($0.id) } ? pair : nil
        }
        if let pair = split {
            SplitMenu(browser: browser, pair: pair)
        } else if group.count > 1 {
            several(group)
        } else {
            one
        }
        // Kept by the menu as actions, not shown as another menu. Search
        // and Option use these same NSMenuItems and their original handlers.
        if split == nil {
            Menu(ActionMenu.tabSearchActions) {
                if group.count > 1 { allSeveral(group) } else { allActions }
                if !tab.kept, group.count == 1 {
                    Button("Close and Keep", mark: "xmark") {
                        if tab.pin == nil { browser.keepTabs([tab]) }
                        close()
                    }
                    .shortcut(.closeTab)
                }
            }
        }
    }

    @ViewBuilder
    private var one: some View {
        if let pair = browser.pair(of: tab.id) {
            Button("Separate", mark: "yab.split.slash") { browser.separate(pair) }
            // On screen, the halves change places, as View › Swap Halves.
            if browser.stagePair?.contains(tab.id) == true {
                Button("Swap Halves", mark: "arrow.left.arrow.right") { browser.swapHalves(pair) }
            }
        }
        if tab.pin != nil {
            Button("Unpin", mark: "pin.slash") { browser.unpin(tab) }.shortcut(.pin)
        } else if tab.kept {
            Button("Don't Keep Tab", mark: "anchor") { browser.releaseTabs([tab]) }.shortcut(.keepTab)
        } else {
            Button("Pin", mark: "pin") { browser.pin(tab) }.shortcut(.pin).disabled(tab.isBlank)
        }
        Divider()
        if AIUse.offers {
            Button("Ask About Tab", mark: "sparkles") { browser.askInChat(about: tab) }
                .shortcut(.agentAsk).disabled(tab.isBlank)
        }
        if browser.pair(of: tab.id) == nil {
            Button("Open as Split", mark: "yab.split.plus") {
                if tab.id != browser.activeID, let current = browser.active, browser.canCarry(tab, beside: current) {
                    browser.split(tab, with: current)
                } else {
                    browser.select(tab)
                    browser.splitView()
                }
            }.disabled(browser.splitRefusal(tab) != nil)
        }
        Button("Duplicate", mark: "yab.tabs.plus") { browser.duplicate(tab) }
            .shortcut(.duplicate).disabled(tab.isBlank)
        Divider()
        moveTo([tab])
        Divider()
        Button("Copy Link", mark: "link") { browser.copyAddress(tab) }
            .shortcut(.copyAddress).disabled(tab.isBlank)
        Menu("Share", mark: "yab.share") {
            if let url = tab.address {
                ShareLink(item: Diary.shareable(url)) {
                    Label { Text("Share Link…") } icon: { Image(nsImage: MenuMark.image("yab.share")) }
                }
            }
            PhoneSend(browser: browser, tab: tab)
        }.disabled(tab.isBlank)
        Divider()
        Button("Rename…", mark: "pencil") { browser.beginTabEdit(tab) }
            .shortcut(.rename).disabled(tab.isBlank || tab.pin != nil)
        HomeEditItems(browser: browser, tab: tab)
        ChangeIconItem(target: .tab(tab.id), mark: "face.smiling")
        RefreshIconItem(tab: tab)
        Button(browser.siteMuted(tab) ? "Unmute Site" : "Mute Site", mark: browser.siteMuted(tab) ? "speaker.wave.2" : "speaker.slash") { browser.toggleSiteMute(tab) }
            .disabled(!AudioWatch.canMute || tab.address?.scheme?.hasPrefix("http") != true)
        Divider()
        Button(tab.kept ? "Close and Keep" : "Close", mark: tab.kept ? "xmark" : "yab.tab.x", action: close).shortcut(.closeTab)
        // Both halves of the split at once.
        if let pair = browser.pair(of: tab.id) {
            Button("Close Split", mark: "yab.tabs.x") { browser.close([pair.first, pair.second].compactMap { browser.tab(id: $0) }) }
        }
        Button("Close Other Tabs", mark: "broom") { browser.closeOthers(but: [tab]) }
            .shortcut(.closeOthers).disabled(browser.tabs.count < 2)
        if tab.pin == nil, !tab.kept {
            Button(Shortcut.titles(sidebar: browser.prefs.sidebar)[.closeAfter]!, mark: "yab.tabs.down") { browser.closeAfter([tab]) }
                .shortcut(.closeAfter).disabled(browser.sideCloseTargets([tab], before: false).isEmpty)
        } else if tab.kept {
            Button(tab.nest == nil ? "Close and Don't Keep" : "Remove from Folder", mark: "trash") { browser.discard([tab], rekept: true) }
        }
    }

    @ViewBuilder
    private func several(_ group: [Tab]) -> some View {
        let n = group.count
        let loose = group.filter { $0.pin == nil && !$0.isBlank }.count
        let kept = group.filter(\.kept).count
        if loose > 0 {
            Button(loose == 1 ? "Pin" : "Pin \(loose) Tabs", mark: "pin") { browser.pin(group) }.shortcut(.pin)
        } else {
            Button("Unpin \(n) Tabs", mark: "pin.slash") { browser.unpin(group) }.shortcut(.pin)
        }
        let foldable = group.filter(\.keepable).count
        if foldable > 0 {
            Button(foldable == 1 ? "New Folder with Tab" : "New Folder with \(foldable) Tabs", mark: "yab.folder.plus") { browser.newFolder(picked: group) }
                .shortcut(.folderWithTabs)
                .disabled(browser.blank)
        }
        Divider()
        Button("Duplicate \(n) Tabs", mark: "yab.tabs.plus") { browser.duplicate(group) }.shortcut(.duplicate)
        moveTo(group)
        Divider()
        Button("Copy \(n) URLs", mark: "link") { browser.copyAddresses(group) }.shortcut(.copyAddress)
        Button("Copy \(n) Markdown Links", mark: "markdown") { browser.copyMarkdownLink(group) }.shortcut(.copyMarkdownLink)
        Divider()
        let loud = group.filter { $0.noisy || $0.muted }
        let quiet = !loud.isEmpty && loud.allSatisfy(\.muted)
        Button(quiet ? "Unmute \(loud.count) Tabs" : "Mute \(loud.isEmpty ? n : loud.count) Tabs", mark: quiet ? "speaker.wave.2" : "speaker.slash") {
            loud.forEach { $0.mute(!quiet) }
        }.disabled(!AudioWatch.canMute || loud.isEmpty)
        Button("Put \(n) Tabs to Sleep", mark: "yab.sleepa") { browser.sleep(group, byHand: true) }
            .disabled(!browser.canSleep(group, byHand: true))
        Divider()
        Button(kept == n ? "Close \(n) Tabs and Keep" : "Close \(n) Tabs", mark: kept == n ? "xmark" : "yab.tabs.x") { browser.close(group) }.shortcut(.closeTab)
        Button("Close Other Tabs", mark: "broom") { browser.closeOthers(but: group) }.shortcut(.closeOthers).disabled(browser.tabs.count <= n)
        if kept == n {
            let homes = Set(group.compactMap { $0.nest.map(ObjectIdentifier.init) })
            let filed = group.allSatisfy { $0.nest != nil }
            Button(!filed ? "Close \(n) Tabs and Don't Keep" : homes.count == 1 ? "Remove \(n) Tabs from Folder" : "Remove \(n) Tabs from Folders", mark: "trash") { browser.discard(group, rekept: true) }
        }
    }

    @ViewBuilder
    private func moveTo(_ group: [Tab]) -> some View {
        // Several tabs with no folder to offer: Space is the only group, so it
        // stands as Move to Space and not under a Move to of its own.
        if group.count > 1, !group.contains(where: \.keepable) {
            SpaceSend(browser: browser, tabs: group, alone: true)
        } else {
        Menu("Move to", mark: "arrow.right") {
            SpaceSend(browser: browser, tabs: group, title: "Space")
            // Only with something in it: a pin in a split, say, has no
            // folder to go to and no live folder of its site, and an empty
            // submenu said "No actions".
            let filing = group.count == 1 ? tab.keepable : group.contains(where: \.keepable)
            let live = group.count == 1 ? liveFolder : nil
            if filing || live != nil {
                Menu("Folder", mark: "yab.folder.right") {
                    if group.count == 1, tab.keepable {
                        NestSend(browser: browser, tab: tab).contents
                    } else if group.contains(where: \.keepable) {
                        Button("New Folder with \(group.count) Tabs", mark: "yab.folder.plus") { browser.newFolder(picked: group) }.shortcut(.folderWithTabs)
                    }
                    if let live { liveFolderAction(live) }
                }
            }
            if group.count == 1 {
                Button("New Window", mark: "yab.window.plus") { _ = windows.moveToNewWindow(tab, from: browser) }
                    .shortcut(.moveToWindow)
                    .disabled(tab.shy || tab.onCall || tab.everywhere != nil || browser.partner(of: tab) != nil)
                // Only with another window to go to, not a grayed row.
                if !windows.otherWindows(than: browser).isEmpty {
                    Menu("Window", mark: "yab.window.right") {
                        ForEach(Array(windows.otherWindows(than: browser).enumerated()), id: \.offset) { item in
                            Button(item.element.title, mark: "yab.window") { _ = windows.move(tab, from: browser, to: item.element.browser, selecting: tab.id == browser.activeID) }
                                .disabled(item.element.browser.spaceID != browser.spaceID || tab.shy || tab.onCall || tab.everywhere != nil || browser.partner(of: tab) != nil)
                        }
                    }
                }
                Button("Open Copy in New Window", mark: "yab.window.out") {
                    guard let url = tab.address else { return }
                    windows.newWindow(from: browser).arrive(url)
                }.disabled(tab.isBlank || tab.shy)
            }
        }
        }
    }

    /// The live folder this tab's site offers, if any: one from a pin's
    /// site, a GitHub search kept, or the site followed.
    private enum LiveFolderAct { case make(LiveSource), keepSearch, follow }

    private var liveFolder: LiveFolderAct? {
        if tab.pin != nil, let host = tab.address?.host(),
           let source = LiveSource.all.first(where: { LiveGitService.of($0.id) == nil && !["feed", "github.issues", "github.search"].contains($0.id) && $0.owns(host) }) {
            return .make(source)
        } else if tab.pin == nil, LiveIssues.search(in: tab.address) != nil, tab.address.flatMap(LiveGitHub.host(of:)) != nil,
                  tab.address?.host()?.contains("github") == true {
            return .keepSearch
        } else if tab.pin == nil, tab.live == nil, !tab.asleep, tab.address?.scheme?.hasPrefix("http") == true {
            return .follow
        }
        return nil
    }

    @ViewBuilder
    private func liveFolderAction(_ act: LiveFolderAct) -> some View {
        switch act {
        case .make(let source):
            Button("Live Folder from \(source.title)", mark: "yab.folder.bolt") { LiveFolders.shared.make(source.id, in: browser) }
        case .keepSearch:
            Button("Keep This Search as a Folder", mark: "yab.folder.search") { LiveFolders.shared.keepSearch(tab, in: browser) }
        case .follow:
            Button("Follow Site in a Folder", mark: "folder.bookmark") { LiveFolders.shared.follow(tab, in: browser) }
        }
    }

    /// Right-clicked on one of several picked: every line speaks for all of
    /// them, and says how many that is.
    @ViewBuilder
    private func allSeveral(_ group: [Tab]) -> some View {
        let n = group.count
        let agentTabs = group.filter { $0.agent != nil && !Agents.shared.sealed($0) }
        if !agentTabs.isEmpty {
            Button("Keep \(agentTabs.count == 1 ? "Tab" : "\(agentTabs.count) Tabs") for Yourself", mark: "yab.person.left") {
                browser.folderBook.keep(agentTabs, in: browser)
            }
        }
        let loose = group.filter { $0.pin == nil && !$0.isBlank }.count
        if loose > 0 {
            Button(loose == 1 ? "Pin" : "Pin \(loose) Tabs", mark: "pin") { browser.pin(group) }
                // Nothing is pinned or kept in a Blank Window, as in Arc's.
                .disabled(browser.blank)
        } else {
            Button("Unpin \(n) Tabs", mark: "pin.slash") { browser.unpin(group) }
        }
        // Above the line, or under it again (Kept.swift).
        let keepable = group.filter { $0.keepable && !$0.kept }.count
        let kept = group.filter(\.kept).count
        if keepable > 0 {
            Button(keepable == 1 ? "Keep Tab" : "Keep \(keepable) Tabs", mark: "anchor") { browser.keepTabs(group) }
                .shortcut(.keepTab)
                .disabled(browser.blank)
        } else if kept > 0 {
            Button(kept == 1 ? "Don't Keep Tab" : "Don't Keep \(kept) Tabs", mark: "anchor") { browser.releaseTabs(group) }
                .shortcut(.keepTab)
        }
        let foldable = group.filter(\.keepable).count
        if foldable > 0 {
            Button(foldable == 1 ? "New Folder with Tab" : "New Folder with \(foldable) Tabs", mark: "yab.folder.plus") { browser.newFolder(picked: group) }
                .shortcut(.folderWithTabs)
                .disabled(browser.blank)
        }
        Divider()
        Button("Bookmark \(n) Tabs", mark: "yab.bookmark.plus") { browser.keep(group) }
            .shortcut(.bookmark)
        Button("Duplicate \(n) Tabs", mark: "yab.tabs.plus") { browser.duplicate(group) }
            .shortcut(.duplicate)
        Button("Copy \(n) URLs", mark: "link") { browser.copyAddresses(group) }
            .shortcut(.copyAddress)
        Button("Copy \(n) Markdown Links", mark: "markdown") { browser.copyMarkdownLink(group) }
            .shortcut(.copyMarkdownLink)
        SpaceSend(browser: browser, tabs: group)
        Button("Put \(n) Tabs to Sleep", mark: "yab.sleepa") { browser.sleep(group, byHand: true) }
            .disabled(!browser.canSleep(group, byHand: true))
        let loud = group.filter { $0.noisy || $0.muted }
        if AudioWatch.canMute, !loud.isEmpty {
            // All quiet already: they all come back. Otherwise the ones still
            // making noise go quiet.
            let quiet = loud.allSatisfy(\.muted)
            Button(quiet ? "Unmute \(loud.count == 1 ? "Tab" : "\(loud.count) Tabs")"
                         : "Mute \(loud.count == 1 ? "Tab" : "\(loud.count) Tabs")",
                   mark: quiet ? "speaker.wave.2" : "yab.speakeroff") {
                loud.forEach { $0.mute(!quiet) }
            }
        }
        Divider()
        if kept == n {
            // Kept, all of them: put down, as a pin is, or taken out; out of
            // their folders when every one is in one.
            Button("Close \(n) Tabs and Keep", mark: "xmark") { browser.close(group) }
                .shortcut(.closeTab)
            let homes = Set(group.compactMap { $0.nest.map(ObjectIdentifier.init) })
            let filed = group.allSatisfy { $0.nest != nil }
            Button(!filed ? "Close \(n) Tabs and Don't Keep" : homes.count == 1 ? "Remove \(n) Tabs from Folder" : "Remove \(n) Tabs from Folders", mark: "trash") { browser.discard(group, rekept: true) }
        } else {
            Button("Close \(n) Tabs", mark: "yab.tabs.x") { browser.close(group) }
                .shortcut(.closeTab)
        }
        Button("Close Other Tabs", mark: "broom") { browser.closeOthers(but: group) }
            .disabled(browser.tabs.count <= n)
        if group.allSatisfy({ $0.pin == nil && !$0.kept }) {
            closeSides(group)
        }
    }

    @ViewBuilder
    private func closeSides(_ group: [Tab]) -> some View {
        let sidebar = browser.prefs.sidebar
        let titles = Shortcut.titles(sidebar: sidebar)
        Button(titles[.closeBefore]!, mark: sidebar ? "yab.tabs.up" : "arrow.left") { browser.closeBefore(group) }
            .shortcut(.closeBefore)
            .disabled(browser.sideCloseTargets(group, before: true).isEmpty)
        Button(titles[.closeAfter]!, mark: sidebar ? "yab.tabs.down" : "arrow.right") { browser.closeAfter(group) }
            .shortcut(.closeAfter)
            .disabled(browser.sideCloseTargets(group, before: false).isEmpty)
    }

    @ViewBuilder
    private var allActions: some View {
        if tab.agent != nil, !Agents.shared.sealed(tab) {
            Button("Keep Tab for Yourself", mark: "person") { browser.folderBook.keep([tab], in: browser) }
            Divider()
        }
        // A page watched for the user: its row says so (PageWatches.swift).
        if let watch = PageWatches.shared.watch(for: tab), watch.active {
            Button("Stop Watching", mark: "eye.slash") { PageWatches.shared.stop(watch.id) }
            Divider()
        }
        // Gone on from where it was pinned or kept: back there, or this
        // page its own (PinnedHome.swift), first, as Arc's row offers it.
        HomeItems(browser: browser, tab: tab)
        if tab.awayFromHome { Divider() }
        if tab.pin != nil || tab.kept {
            ChangeIconItem(target: .tab(tab.id), mark: "face.smiling")
        }
        RefreshIconItem(tab: tab)
        if tab.pin == nil {
            Button("Pin", mark: "pin") { browser.pin(tab) }
                .shortcut(.pin)
                .disabled(tab.isBlank || browser.blank)
            // Above the line in the column, the tabs that stay (Kept.swift).
            if tab.kept {
                Button("Don't Keep Tab", mark: "anchor") { browser.releaseTabs([tab]) }
                    .shortcut(.keepTab)
            } else {
                Button("Keep Tab", mark: "yab.anchor") { browser.keepTabs([tab]) }
                    .shortcut(.keepTab)
                    .disabled(!tab.keepable || browser.blank)
            }
            Button("Rename…", mark: "pencil") {
                browser.beginTabEdit(tab)
            }
            .shortcut(.rename)
            // Its home, as Arc's Edit Pinned Page (PinnedHome.swift).
            HomeEditItems(browser: browser, tab: tab)
            if tab.keepable { NestSend(browser: browser, tab: tab) }
        } else {
            Button("Change Letter", mark: "pencil") { browser.editLetter(tab) }
                .shortcut(.rename)
            HomeEditItems(browser: browser, tab: tab)
            Button("Unpin", mark: "pin.slash") { browser.unpin(tab) }
                .shortcut(.pin)
        }
        // A live folder's: out, and kept out until what it says changes.
        if tab.live != nil {
            Button("Hide from Folder", mark: "yab.eye.slash") { LiveFolders.shared.hide(tab, in: browser) }
        }
        // A live folder of this pin's site (LiveSources.swift), or of what
        // any page's feed says.
        if tab.pin != nil, let host = tab.address?.host(),
           let source = LiveSource.all.first(where: { LiveGitService.of($0.id) == nil && !["feed", "github.issues", "github.search"].contains($0.id) && $0.owns(host) }) {
            Button("Live Folder from \(source.title)", mark: "yab.folder.bolt") { LiveFolders.shared.make(source.id, in: browser) }
        } else if tab.pin == nil, LiveIssues.search(in: tab.address) != nil, tab.address.flatMap(LiveGitHub.host(of:)) != nil,
                  tab.address?.host()?.contains("github") == true {
            Button("Keep This Search as a Folder", mark: "yab.folder.search") { LiveFolders.shared.keepSearch(tab, in: browser) }
        } else if tab.pin == nil, tab.live == nil, !tab.asleep, tab.address?.scheme?.hasPrefix("http") == true {
            Button("Follow Site in a Folder", mark: "folder.bookmark") { LiveFolders.shared.follow(tab, in: browser) }
        }
        // How many wait there, at the mark's corner (Corner.swift): a pin's
        // or a kept tab's, and not a calendar's, whose corner is its meeting.
        if tab.pin != nil || tab.kept, !tab.isBlank, !Meetings.isCalendar(tab.address) {
            CountToggle(tab: tab)
        }
        Divider()
        Button("Duplicate", mark: "yab.tabs.plus") {
            browser.duplicate(tab)
        }
        .shortcut(.duplicate)
        .disabled(tab.isBlank)
        Divider()
        Button("Move to New Window", mark: "yab.window.plus") { _ = BrowserWindows.shared.moveToNewWindow(tab, from: browser) }
            .shortcut(.moveToWindow)
            .disabled(tab.shy || tab.onCall || tab.everywhere != nil || browser.partner(of: tab) != nil)
        let otherWindows = windows.otherWindows(than: browser)
        if !otherWindows.isEmpty {
            Menu("Move to Window", mark: "yab.window.right") {
                ForEach(Array(otherWindows.enumerated()), id: \.offset) { item in
                    Button(item.element.title, mark: "yab.window") {
                        _ = windows.move(tab, from: browser, to: item.element.browser, selecting: tab.id == browser.activeID)
                    }
                    .disabled(item.element.browser.spaceID != browser.spaceID || tab.shy || tab.onCall || tab.everywhere != nil || browser.partner(of: tab) != nil)
                }
            }
        }
        Button("Open Copy in New Window", mark: "yab.window.out") {
            guard let url = tab.address else { return }
            BrowserWindows.shared.newWindow(from: browser).arrive(url)
        }
        .disabled(tab.isBlank || tab.shy)
        Divider()
        // The way in for a tab with no room for the sliders, a pin or a
        // narrow one, and for any other: it comes to the front, and the
        // panel hangs from its end once it is there.
        Button("Site Controls", mark: "slider.horizontal.2.square") {
            if browser.active?.id != tab.id { browser.focus(tab) }
            DispatchQueue.main.async { ExtensionPanel.shared.toggle(tab: tab, page: .main, from: nil) }
        }
        .shortcut(.extensions)
        .disabled(tab.isBlank)
        Button("Copy URL", mark: "link") {
            browser.copyAddress(tab)
        }
        .shortcut(.copyAddress)
        .disabled(tab.isBlank)
        Button("Copy Markdown Link", mark: "markdown") { browser.copyMarkdownLink([tab]) }
            .shortcut(.copyMarkdownLink)
            .disabled(tab.isBlank)
        SpaceSend(browser: browser, tabs: [tab])
        // Each iPhone of the account that takes pages (SyncPhone).
        PhoneSend(browser: browser, tab: tab)
        // Side by side with the tab in front, or apart again.
        if let pair = browser.pair(of: tab.id) {
            Divider()
            // The pair as one square in the pins, as Dia pins a split
            // (PinPairs.swift).
            if browser.canPinPair(pair) {
                Button("Pin Pair", mark: "pin") { browser.pinPair(pair) }
            }
            Button("Separate", mark: "yab.split.slash") { browser.separate(pair) }
        } else if tab.id != browser.activeID, let current = browser.active, browser.canCarry(tab, beside: current) {
            Divider()
            Button("Split with Current Tab", mark: "yab.split.plus") { browser.split(tab, with: current) }
        }
        // A pin or a kept tab too: its row stays, the page lets go of its
        // memory until it is clicked again.
        Button("Put Tab to Sleep", mark: "yab.sleepa") { browser.sleep([tab], byHand: true) }
            .disabled(!browser.canSleep([tab], byHand: true))
        // Its site never put to sleep, Chrome's "Always keep this site
        // active", or let sleep again (AwakeSites).
        if let site = AwakeSites.site(from: tab.address?.host() ?? ""), tab.address?.scheme?.hasPrefix("http") == true {
            let kept = AwakeSites.shared.keeps(tab.address)
            Button(kept ? "Let \(site) Sleep" : "Always Keep \(site) Awake", mark: kept ? "yab.globe.sleep" : "yab.sun") {
                AwakeSites.shared.toggle(tab.address)
            }
        }
        // Only where there is something to hear, or something already
        // silenced to bring back.
        if AudioWatch.canMute {
            let siteMuted = browser.siteMuted(tab)
            if tab.noisy || tab.muted {
                Button(tab.muted ? "Unmute Tab" : "Mute Tab", mark: tab.muted ? "yab.speaker" : "yab.speakeroff") { tab.mute(!tab.muted) }
                    .shortcut(.mute)
            }
            // Its whole site in this space, the tabs open and the ones to
            // come, as in Dia.
            if tab.noisy || tab.muted || siteMuted, tab.address?.scheme?.hasPrefix("http") == true,
               let site = AwakeSites.site(from: tab.address?.host() ?? "") {
                Button(siteMuted ? "Unmute \(site)" : "Mute \(site)", mark: siteMuted ? "speaker.wave.2" : "speaker.slash") {
                    browser.toggleSiteMute(tab)
                }
            }
        }
        // An HTTP(S) site: its existing Developer Mode,
        // on or off (DevMode.swift).
        if tab.canDev {
            Button(tab.isDev ? "Turn Off Developer Mode" : "Turn On Developer Mode", mark: "yab.code") { browser.setDevMode(tab, !tab.isDev) }
        }
        // An agent's tab: the agent can be stopped from any of its tabs.
        if let session = Agents.shared.session(tab.worker), session.state.live, session.agent != .external {
            Divider()
            Button(Folders.stopping(session), mark: "stop") { _ = Agents.shared.stop(session.id) }
        }
        Divider()
        if tab.kept {
            // As Arc's pinned tab: ⌘W and the cross put it down, its row
            // staying ("Close and Keep Pinned" in Arc), and the way out is
            // its own item (Arc's Remove Pin). In a folder, out of the
            // folder for good; ⌘Z puts it back.
            Button("Close and Keep", mark: "xmark", action: close)
                .shortcut(.closeTab)
            Button(tab.nest == nil ? "Close and Don't Keep" : "Remove from Folder", mark: tab.nest == nil ? "trash" : "yab.folder.minus") { browser.discard([tab], rekept: true) }
        } else {
            Button("Close Tab", mark: "yab.tab.x", action: close)
                .shortcut(.closeTab)
        }
        Button("Close Other Tabs", mark: "yab.tabs.x") { browser.closeOthers(but: [tab]) }
            .shortcut(.closeOthers)
            .disabled(browser.tabs.count < 2)
        if tab.pin == nil, !tab.kept {
            closeSides([tab])
        }
    }
}

/// Move to Folder: one of your folders among the kept, a new one made
/// around the tab, or out of the one it is in.
struct NestSend: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    var body: some View {
        Menu("Move to Folder", mark: "yab.folder.right") { contents }
    }

    @ViewBuilder
    var contents: some View {
        // Yours among the kept: a search's folder is filled by searching.
        let nests = browser.nests.filter { !$0.research }
            // As deep as each is, a folder before the folders in it.
            ForEach(nests) { nest in
                Button(NestMove.indented(nest), mark: "yab.folder.right") { browser.file([tab], in: nest) }
                    .disabled(tab.nest === nest)
            }
            if !nests.isEmpty { Divider() }
            Button("New Folder", mark: "yab.folder.plus") { browser.newFolder(with: [tab]) }
                .shortcut(.folderWithTabs)
            if tab.nest != nil {
                Divider()
                // Still kept, one step out. Remove from Folder in the tab's
                // menu is the one that takes it out for good.
                Button("Move Out of Folder", mark: "yab.folder.up") { browser.unfile(tab) }
            }
    }
}

/// The strip or the column while the tabs change sides (⇧⌘S): a few points
/// of the way it goes, the strip up, the column to the left, under a fade.
/// In a touch after the other starts out, so the two overlap and there is
/// never an empty frame; out quicker, as every exit is.
///
/// Not a transition. Both sides are in the window for the length of the
/// change: the one arriving is put there, unseen, a frame before anything
/// moves, and the one leaving is taken away once nothing is moving any
/// more. Building a side, its rows, its lights, its tracking areas, costs
/// more than a frame, and built in the frame the movement starts, it was
/// that first frame, every time, that came late.
struct Presence: ViewModifier {
    let shown: Bool
    let edge: Edge

    func body(content: Content) -> some View {
        let hint: CGFloat = shown ? 0 : (edge == .top ? 12 : 16)
        content
            .opacity(shown ? 1 : 0)
            .offset(x: edge == .leading ? -hint : edge == .trailing ? hint : 0, y: edge == .top ? -hint : 0)
            .allowsHitTesting(shown)
            .animation(shown ? Motion.arrive.delay(0.04) : Motion.depart, value: shown)
    }
}

/// A button that draws nothing of its own and says when it is held, for a
/// face drawn somewhere other than its label.
struct Held: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, down in pressed = down }
    }
}

/// The end of a tab, in the row or down the column: one slot where the
/// close button, the ring, the speaker and an agent's face take turns.
///
/// A tab that plays sound, or is muted, has its speaker in the slot, and
/// the speaker is the mute button, at rest as under the pointer. When the
/// pointer comes onto the tab the speaker slides left, out of the cross's
/// way, and the cross comes in where it stood: the tab's end stays where
/// the hand closes tabs. The slide is the one thing here that moves; the
/// cross, the ring and the rest still come and go at once, as state.
///
/// The cross comes with the tab's light, in the same frame, and goes with
/// it: run down the column and only the tab under the pointer has one. It
/// is the muted ink of the speaker with nothing behind it; its
/// square, and the full ink, come only with the pointer on the cross
/// itself, as the speaker's and the face's do.
///
/// An agent's face moves as the speaker does, and as a folder's face does
/// (FolderEnd): under the pointer it slides left and the cross comes in at
/// the end, so a tab's cross stands where a folder's does. Resting on the
/// face brings the agent's own card down from it (see `TabGlance.face`); a
/// click on it is a click on the tab.
///
/// Nothing else comes into a tab: reading mode's book and
/// the site's sliders stand in the address bar's band (AddressBar), and
/// with the band hidden ⌥⌘R, ⌘E and ⌘T reach them, the site's panel
/// hanging from the tab's mark (TabPill).
struct TabEnd: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    let live: Bool
    let hovering: Bool
    let editing: Bool
    /// The tab's own ink, muted on one you aren't on.
    let tint: Color
    /// The speaker stands at the end, in the row of tabs; the column has
    /// it beside the tab's mark, as Arc does (SideSpeaker).
    var speaker = true
    let close: () -> Void
    /// A kept tab put down, where the row offers it: the cross takes it out
    /// of the kept, closed (Close and Don't Keep). Awake, a kept tab's end
    /// is a minus that puts it down and keeps it, as Arc's pinned tabs have.
    var unkeep: (() -> Void)? = nil
    /// How tall what the pointer has to hit is: the tab's height.
    var reach: CGFloat = Density.current.tab
    /// The square under the pointer on the cross, the face and the speaker,
    /// and the cross drawn on it: a tab's across the top, or a row's in the
    /// column.
    var plate: RowPlate = .strip
    /// From one place's middle to the next's: `across` along the top,
    /// `beside` in the column.
    var pitch: CGFloat = TabEnd.across
    /// The slot's side: `stripSlot` along the top, 15 in the column.
    var slotSide: CGFloat = TabEnd.stripSlot
    /// The row keeps its hover while this control has the pointer.
    var closeHover: (Bool) -> Void = { _ in }

    /// The cross held down: it gives as every button does (see `Press`).
    @State private var crossPressed = false
    /// The pointer on the cross's reach.
    @State private var onCross = false
    /// The pointer on the face itself.
    @State private var onFace = false
    /// The pointer on the speaker beside the cross.
    @State private var onSpeaker = false
    /// When the tab was last put down: the minus turns into the cross under
    /// the pointer, and the second press of a double click lands on it.
    @State private var putDownAt = Date.distantPast
    @Environment(\.tone) private var tone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The cross's 15 and the gap between its square and the face's, in
    /// the column.
    static let beside: CGFloat = 15 + 5
    /// Across the top, 22 from one place's middle to the next: their
    /// squares (RowPlate.strip, 20) two points apart, never touching.
    static let across: CGFloat = 15 + 7
    /// The slot across the top: 16, an even side like its square's and
    /// the 28 it stands in, so its middle, the square's and the glyph's
    /// fall on whole points and stay one on a 1x screen too (a 15 stood
    /// at 6.5 and was rounded a point low, the square with it).
    static let stripSlot: CGFloat = 16
    /// The slot's inset from a tab's end across the top: its middle 14
    /// in, so the square on it stands four in, as above and below it.
    static var stripEnd: CGFloat { RowPlate.strip.inset + RowPlate.strip.side / 2 - stripSlot / 2 }

    /// How far from the tab's end its title must stop.
    static func clear(_ tab: Tab, hovering: Bool, slotted: Bool, speaker: Bool = true, unkeeps: Bool = false, pitch: CGFloat = across) -> CGFloat {
        guard slotted else { return 0 }
        let loud = speaker && (tab.noisy || tab.muted)
        // Kept and asleep, there is no cross to make room for, but where
        // the cross takes it out of the kept, under the pointer.
        if tab.putDown, !(unkeeps && hovering), !tab.spinning, !loud, !tab.wearsFace { return 0 }
        // The cross beside the face or the speaker at the end.
        let next = hovering && (tab.wearsFace || (speaker && sounding(tab))) ? 1 : 0
        return 15 + 6 + CGFloat(next) * pitch
    }

    /// Playing sound or muted, where muting can be done.
    static func sounding(_ tab: Tab) -> Bool {
        AudioWatch.canMute && (tab.noisy || tab.muted)
    }

    /// An agent's face has the slot: while it works here or waits on you,
    /// and until you've come to see what it left (Tab.wearsFace).
    private var agent: Bool { tab.wearsFace && !editing }
    /// The speaker stands beside the cross, and the cross's reach stops
    /// short of it.
    private var speakerBeside: Bool { speaker && !agent && !editing && hovering && !tab.putDown && Self.sounding(tab) }
    /// The cross is there to press: on a tab awake, and on a kept one put
    /// down where it takes it out of the kept.
    private var crossable: Bool { !tab.putDown || unkeep != nil }

    /// The cross pressed: a kept tab put down leaves the kept; any other
    /// closes, a kept one put down.
    private func crossed() {
        browser.glance.drop()
        if tab.putDown, let unkeep {
            // A double click on the minus only puts the tab down: the cross
            // that opened under it takes no press until a double click's
            // time has gone.
            guard Date.now.timeIntervalSince(putDownAt) > NSEvent.doubleClickInterval else { return }
            unkeep()
        } else {
            close()
        }
    }

    /// The speaker is there, as a button: in the slot at rest, unless the
    /// ring has it, and beside the cross under the pointer.
    private var speakerShown: Bool { speaker && !agent && !editing && Self.sounding(tab) && (hovering || !tab.spinning) }

    /// The face or the speaker stands beside the cross, and the cross's
    /// reach stops short of it.
    private var beside: Bool { speakerBeside || (agent && hovering) }
    /// The cross comes: under the pointer, on a tab it can close or put
    /// down, and always beside an agent's face.
    private var crossShown: Bool { hovering && !editing && (crossable || agent) }

    var body: some View {
        slot
        .animation(hovering ? Motion.arrive : Motion.quick, value: hovering)
        // The face going, once you've seen what it left, fades; the cross
        // and the rest come back as they are.
        .animation(Motion.quick, value: agent)
        .onChange(of: hovering) { _, on in if !on { face(false); onCross = false } }
        .onChange(of: agent) { _, on in if !on { face(false) } }
        .onChange(of: speakerBeside) { _, on in if !on { onSpeaker = false } }
        .onChange(of: tab.putDown) { _, down in if down { putDownAt = .now } }
        .onDisappear { face(false) }
    }

    private var slot: some View {
        ZStack {
            if agent {
                AgentFace(tab: tab, tint: tint, tip: false)
                    .background {
                        // Under the pointer, the square the cross has: the
                        // face is something to point at too.
                        if onFace { plate.square() }
                    }
                    // One face that moves, as the speaker does.
                    .offset(x: hovering ? -pitch : 0)
                    .transition(.opacity)
            }
            if crossShown {
                // Beside a face moving out of its way, it fades in as a
                // folder's does rather than standing on the face at once.
                cross.transition(agent ? .opacity : .identity)
            } else if !agent, tab.spinning {
                Ring().transition(.opacity)
            } else if !agent, speaker, tab.noisy || tab.muted, !Self.sounding(tab) {
                // Which tab the noise is coming from, where WebKit can't
                // be asked to silence it: only a mark.
                Symbol(tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 8)
                    .foregroundStyle(Palette.muted(on: tone))
                    .transition(.opacity)
            }
            if speakerShown {
                // One speaker that moves rather than one going and another
                // coming: the pointer on its way to it finds it on the way.
                muteButton
                    .offset(x: speakerBeside ? -pitch : 0)
                    .transition(.opacity)
            }
        }
        .frame(width: editing ? 0 : slotSide, height: slotSide)
        .opacity(editing ? 0 : 1)
        // What you have to hit is the whole right-hand end of the tab, not
        // the slot drawn: an overlay is not laid out, so it can reach
        // past its own frame without moving anything that is.
        .overlay {
            if agent {
                // Not a button: a click here is the tab's.
                Color.clear
                    .frame(width: pitch, height: reach)
                    .contentShape(Rectangle())
                    .onHover { face($0) }
                    .offset(x: hovering ? -pitch : 0)
            }
            // A closable tab keeps this target when its face or row hover changes.
            if !editing && (crossable || (agent && hovering)) {
                // A button rather than a tap, so it can be held: the press
                // reaches the cross drawn under it, and letting go off it
                // closes nothing.
                // With the speaker or the face beside it, trimmed only on that
                // side: the reach past the tab's end stays the cross's.
                // Trimmed, it stops half a pitch left of the slot's middle,
                // where the reach of what stands beside begins.
                Button { if hovering { crossed() } } label: {
                    Color.clear
                        .frame(width: beside ? 15 + pitch / 2 : 30, height: reach)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Held(pressed: $crossPressed))
                // Shared by sidebar rows, kept tabs, split halves and the
                // top strip. The transparent hover target must never enter
                // the Tab loop, even while its cross is not drawn.
                .focusable(false)
                .onHover { onCross = $0; closeHover($0) }
                .onDisappear { if onCross { onCross = false }; closeHover(false) }
                .offset(x: beside ? (15 - pitch / 2) / 2 : 0)
                // At rest the face owns this slot, and a click is the row's.
                .allowsHitTesting(!agent || hovering)
            }
        }
    }

    /// The mute button: what the tab is doing, hover or not. Under the
    /// pointer it only gains the cross's square; the tip says what a click
    /// does, the mark changes once it's done.
    private var muteButton: some View {
        let playing = !tab.muted
        return Button { tab.mute(playing) } label: {
            Symbol(playing ? "speaker.wave.2.fill" : "speaker.slash.fill", size: 8)
                .foregroundStyle(onSpeaker ? Palette.ink : Palette.muted(on: tone))
                .frame(width: slotSide, height: slotSide)
                .background {
                    if onSpeaker { plate.square() }
                }
                .frame(width: pitch, height: reach)
                .contentShape(Rectangle())
                .frame(width: slotSide, height: slotSide)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { onSpeaker = $0 }
        .keyTip(playing ? "Mute Tab" : "Unmute Tab", shortcut: "Mute Tab")
        .accessibilityLabel(playing ? "Mute Tab" : "Unmute Tab")
    }

    /// A cross, or on a kept tab awake a minus: it is put down, not closed.
    /// Put down under the pointer, the minus opens into the cross where it
    /// stands, its two strokes swinging apart (concept A,
    /// https://claude.ai/artifact/5ZTV5PpmZvJHnjkPWEjcZa); woken, it folds
    /// back. With Reduce Motion it is the other at once.
    private var cross: some View {
        let minus = tab.kept && !tab.putDown
        return MinusCross(open: minus ? 0 : 1)
            // Two points at a 16-point cross, Arc's stroke (RowPlate.cross).
            .stroke(style: StrokeStyle(lineWidth: plate.cross / 8, lineCap: .round))
            .frame(width: plate.cross, height: plate.cross)
            .animation(reduceMotion ? nil : Motion.markTurn, value: minus)
            // The ink of the tab's other marks, the speaker, and of the +
            // after the tabs: faint, it read as
            // greyed out beside them (feedback #87). On its own reach it
            // darkens, as they do.
            // Under the pointer a shade short of the title's ink, as Arc's
            // cross is (0.7 white beside a 0.9 title, measured 2026-10-12).
            .foregroundStyle(onCross ? Palette.ink.opacity(0.75) : Palette.muted(on: tone))
            .frame(width: slotSide, height: slotSide)
            // Under the pointer, a square, concentric with the tab around it
            // (RowPlate). Drawn past the slot, so the title doesn't
            // move for it.
            .background {
                if onCross { plate.square() }
            }
            // The pointer's comings and goings flip it at once, whatever the
            // tab around it eases.
            .transaction { $0.animation = nil }
            // About 1.5 pt of its 18, as a small button gives.
            .scaleEffect(crossPressed && !reduceMotion ? 0.9 : 1)
            .animation(crossPressed ? Press.down : Press.up, value: crossPressed)
    }

    private func face(_ on: Bool) {
        guard on != onFace else { return }
        onFace = on
        browser.glance.face(tab.id, on)
    }
}

/// An almost-closed ring, turning, the same one the canvas app uses, small
/// enough to sit inside a tab without becoming the loudest thing in it.
///
/// Turned by Core Animation, handed to the render server once, so a page
/// loading costs the main thread nothing from one frame to the next;
/// turned by SwiftUI, every tab loading woke the window's whole graph
/// sixty times a second. With Reduce Motion it holds still and breathes.
struct Ring: NSViewRepresentable {
    var size: CGFloat = 10
    @Environment(\.tone) private var tone
    @Environment(\.accessibilityReduceMotion) private var still

    /// A test run started with YAB_STILL=1 holds the ring still as Reduce
    /// Motion would, without the setting changed for the whole Mac.
    static let stillForTests = Store.testing && ProcessInfo.processInfo.environment["YAB_STILL"] == "1"

    func makeNSView(context: Context) -> RingView { RingView() }

    func updateNSView(_ view: RingView, context: Context) {
        let ink = Palette.muted(on: tone).opacity(0.7).resolve(in: context.environment).cgColor
        view.update(size: size, ink: ink, still: still || Ring.stillForTests)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RingView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class RingView: NSView {
    // Drawn top down, as SwiftUI drew it, in a layer of our own: AppKit
    // decides the flip of a hosting view's own.
    private let canvas = CALayer()
    private let arc = CAShapeLayer()
    private var size: CGFloat = 0
    private var still: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        canvas.isGeometryFlipped = true
        layer?.addSublayer(canvas)
        canvas.addSublayer(arc)
        arc.fillColor = nil
        arc.lineCap = .round
        arc.lineWidth = 1.4
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        arc.contentsScale = window?.backingScaleFactor ?? 2
    }

    func update(size: CGFloat, ink: CGColor, still: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if size != self.size {
            self.size = size
            let box = CGRect(x: 0, y: 0, width: size, height: size)
            canvas.frame = box
            arc.bounds = box
            arc.position = CGPoint(x: size / 2, y: size / 2)
            arc.path = Circle().trim(from: 0, to: 0.78).path(in: box).cgPath
            arc.contentsScale = window?.backingScaleFactor ?? 2
        }
        arc.strokeColor = ink
        CATransaction.commit()
        guard still != self.still else { return }
        self.still = still
        move()
    }

    /// Taken off a window and put in another, a layer can come back without
    /// its animations, and the ring would stand still while the page loads.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, still != nil, arc.animation(forKey: "motion") == nil { move() }
    }

    private func move() {
        guard let still else { return }
        arc.removeAllAnimations()
        let motion: CABasicAnimation
        if still {
            // Where it is, its ink coming and going, slowly.
            motion = CABasicAnimation(keyPath: "opacity")
            motion.fromValue = 1
            motion.toValue = 0.35
            motion.duration = 0.9
            motion.autoreverses = true
            motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        } else {
            // Clockwise, on a canvas drawn top down.
            motion = CABasicAnimation(keyPath: "transform.rotation.z")
            motion.fromValue = 0
            motion.toValue = 2 * Double.pi
            motion.duration = 0.85
        }
        motion.repeatCount = .infinity
        arc.add(motion, forKey: "motion")
    }
}


/// The letter of a pinned tab, typed in the square itself.
///
/// A field of its own rather than SwiftUI's, for the same reason as the address
/// in a tab: the system paints selected text as a solid block of accent color,
/// and over a thirty-point gray square that is the loudest thing on screen.
struct PinField: NSViewRepresentable {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser, tab: tab) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.stringValue = tab.pin ?? ""
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        coordinator.tab = tab
        field.appearance = context.environment.tone?.appearance
        if !coordinator.typing, field.stringValue != tab.pin ?? "" {
            field.stringValue = tab.pin ?? ""
        }
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            // The guessed letter arrives selected, so one keystroke replaces it
            // and doing nothing keeps it.
            editor.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var tab: Tab
        var claimed = false
        var typing = false

        init(browser: Browser, tab: Tab) {
            self.browser = browser
            self.tab = tab
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            typing = true
            browser.letter(field.stringValue, for: tab)
            // One character only, and shown as it will be worn.
            field.stringValue = tab.pin ?? ""
            typing = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.cancelOperation(_:)),
                 #selector(NSResponder.insertTab(_:)):
                browser.endPinEdit()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            let browser = browser
            DispatchQueue.main.async { browser.endPinEdit() }
        }
    }
}

/// The washes of open folders on the row, one folder in another: the inner
/// one sits a rim in from its folder's on every side, so the two read as
/// two, not one wash with a seam. The innermost keeps the tabs' height and
/// each one around it grows by the rim above, below and past its end; the
/// outer folder's pill stays where it starts. Corners are concentric, the
/// inner radius plus the rim, and where they overlap the two layers of
/// wash make the inner one a little denser.
enum NestedWash {
    struct Span {
        let id: String
        let start: CGFloat
        let end: CGFloat
    }

    struct Wash: Identifiable {
        let id: String
        let start: CGFloat
        let end: CGFloat
        let height: CGFloat
        let radius: CGFloat
    }

    static let rim: CGFloat = 3
    /// A tab's height, the innermost wash's.
    static var tab: CGFloat { Density.current.tab }

    /// Outer first, so an inner wash is drawn over its folder's.
    static func lay(_ spans: [Span], parent: [String: String]) -> [Wash] {
        let byID = Dictionary(spans.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // The nearest folder around it that has a wash on the row too, and
        // whose wash it starts in: an empty folder at the kept's end is no
        // inner wash of its folder's.
        var outer: [String: String] = [:]
        for span in spans {
            var key = parent[span.id]
            var seen: Set<String> = [span.id]
            while let at = key, seen.insert(at).inserted {
                if let around = byID[at] {
                    if span.start > around.start, span.start <= around.end { outer[span.id] = at }
                    break
                }
                key = parent[at]
            }
        }
        var inner: [String: [String]] = [:]
        for (child, around) in outer { inner[around, default: []].append(child) }

        var ends: [String: CGFloat] = [:]
        var levels: [String: Int] = [:]
        func settle(_ id: String, _ trail: Set<String>) {
            guard ends[id] == nil, let span = byID[id], !trail.contains(id) else { return }
            var end = span.end
            var level = 0
            for child in inner[id] ?? [] {
                settle(child, trail.union([id]))
                end = max(end, (ends[child] ?? 0) + rim)
                level = max(level, (levels[child] ?? 0) + 1)
            }
            ends[id] = end
            levels[id] = level
        }
        for span in spans { settle(span.id, []) }

        var washes: [Wash] = []
        func place(_ id: String, height: CGFloat) {
            guard let span = byID[id] else { return }
            washes.append(Wash(id: id, start: span.start, end: ends[id] ?? span.end, height: height,
                               radius: max(Radius.small, Density.current.radius + (height - tab) / 2)))
            for child in inner[id] ?? [] { place(child, height: max(2 * Radius.small, height - 2 * rim)) }
        }
        for span in spans where outer[span.id] == nil {
            place(span.id, height: min(Metrics.row, tab + 2 * rim * CGFloat(levels[span.id] ?? 0)))
        }
        return washes
    }
}

/// No soft edge where the run scrolls under its ends. macOS 26 lays a haze
/// there that shows a tab which has scrolled past the end as though it were
/// still there, out over the gap by the lights, where nothing is, so a
/// click on it did nothing and the pointer going there lost the tab's hover.
/// The run is cut off square at its own edge instead.
private struct HardEdges: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .horizontal)
        } else {
            content
        }
    }
}

/// A mouse's wheel turns the run of tabs sideways once it holds more than
/// the row shows. A wheel only goes up and down, and a run that scrolls
/// only across did nothing under it. A trackpad already moves it both ways
/// and is left alone, and so is a wheel with Shift held, which macOS turns
/// sideways itself. Inside the run, so the scroll view is the one it is in.
struct WheelAcross: NSViewRepresentable {
    /// Off under a drag: scrolling moves the space the drag is measured in.
    var enabled: Bool

    func makeNSView(context: Context) -> WheelAcrossView { WheelAcrossView() }

    func updateNSView(_ view: WheelAcrossView, context: Context) {
        view.enabled = enabled
    }
}

final class WheelAcrossView: NSView {
    var enabled = true
    private var monitor: Any?
    /// How far one line of a wheel goes: what a page goes, WebKit's step.
    static let line: CGFloat = 40

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.turn(event) ?? event
        }
    }

    /// Every scroll in the app passes through here, a trackpad's sixty and
    /// more a second over a page among them, so what isn't a wheel's line
    /// goes back on its way at the first question.
    private func turn(_ event: NSEvent) -> NSEvent? {
        guard !event.hasPreciseScrollingDeltas, enabled, event.window === window,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let scroll = enclosingScrollView, let run = scroll.documentView,
              scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
        else { return event }
        let clip = scroll.contentView
        let most = max(0, run.frame.width - clip.bounds.width)
        // Down goes on along the row, up goes back, as down goes on down a page.
        let x = min(max(clip.bounds.origin.x - event.scrollingDeltaY * Self.line, 0), most)
        guard most > 0, x != clip.bounds.origin.x else { return event }
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        scroll.reflectScrolledClipView(clip)
        return nil
    }
}
