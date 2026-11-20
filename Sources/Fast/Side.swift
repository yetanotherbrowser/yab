import SwiftUI

/// The tabs, down the left instead of across the top.
///
/// The same pieces as the strip, the gray that slides to the tab you picked,
/// the pinned squares, the cross that appears under the pointer, laid out the
/// other way. The traffic lights are the column's own, in its top corner, so
/// they go wherever it goes; the page takes the whole height beside it.
struct SideBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject private var extensionsHere = ExtensionsHere.shared
    /// An agent's task on many tabs: one row, a folder (AgentFolders).
    /// Watched: every window's folders tell the first window's
    /// (Folders.init(sharing:)); this window's are read.
    @ObservedObject private var watched = Folders.shared
    private var folders: Folders { browser.folderBook }
    /// Out over the page in full screen rather than beside it: a card with
    /// its own corners and no hairline down its side.
    var floating = false

    /// Set while the window wears a backdrop: the column is then no room of
    /// its own, just the backdrop with tabs on it.
    @Environment(\.tone) private var tone

    @State private var dragging: Tab.ID?
    @State private var from = 0
    @State private var travel: CGFloat = 0
    @State private var landing = false

    /// A pin, picked up out of the grid, a separate state from the loose
    /// rows above, since the two gestures never happen at once but move on
    /// two different axes.
    @State private var pinDragging: Tab.ID?
    @State private var pinFrom = 0
    @State private var pinTravel: CGSize = .zero

    /// Where the held row, or square, would land if let go now. Nothing is
    /// reordered while the hand is on it: the held one simply follows the
    /// hand, the others step aside to show where it would go, and the list
    /// itself changes once, on letting go. Reordering underneath a drag had
    /// the held one's place spring one way while the hand pulled it another,
    /// and it shook.
    @State private var target = 0
    /// With an agent's folder in the list, where the held one lands, in
    /// rows as drawn (Folders.landing): its slot, and whether it leaves its
    /// folder. Nil without folders, where index and row are one.
    @State private var aim: Folders.Landing?
    /// The hand's travel, in quarter rows and its lean sideways, `aim` was
    /// last worked out for: only again once it has moved.
    @State private var landedFor = 0
    /// The slot the held row is drawn in when it is taken up.
    @State private var fromSlot = 0
    /// Let go of over a shut folder of yours: going into it, smaller.
    @State private var sinking: Tab.ID?
    @State private var pinGoal = 0
    /// The one just let go of, and how far it still is from its place: the
    /// list changes in one frame, and this is what is left for it to travel.
    @State private var resting: Tab.ID?
    @State private var rest: CGSize = .zero

    /// A tab on its way from one list to the other: a row lifted up into the
    /// pins, or a pin brought down among the rows. It is drawn over the
    /// column rather than in either list, so that it can change shape on the
    /// way, and the list it is headed for opens a gap where it would land.
    @State private var carry: Carry?
    /// Where the carried tab is drawn, in the column's space, and how big.
    /// Both spring after the hand rather than being set, so the change of
    /// shape and the landing are one movement.
    @State private var carryAt: CGPoint = .zero
    @State private var carrySize: CGSize = .zero
    @State private var carryFolded = false
    /// Put down and on its way to its place: its lift, the shadow, a ground
    /// a resting row would not have, fades as it goes, so it arrives looking
    /// exactly like what it is about to become.
    @State private var carryLanding = false
    /// The plate had no tab in front a moment ago: one coming in finds its
    /// address where the question was and slides it into place.
    @State private var plateAsking = false
    /// A tab just put down, still flying to its new place: hidden there until
    /// it arrives.
    @State private var settling: Tab.ID?

    /// Several picked rows taken up by one of them (see `Browser.gathered`),
    /// or one row brought down to the bookmarks: out of the list, drawn as one
    /// stack under the hand, with a gap in the list where they would go.
    @State private var herd: Herd?
    /// The tab carried out over the pages (SplitDeck): its row stays where
    /// it was, a step quieter, while the deck has it.
    @State private var decked: Tab.ID?
    /// The row taken out past the window's edge (TearOff): back in its
    /// place, a step quieter, while its picture is outside.
    @State private var torn: Tab.ID?
    /// The middle of the stack, in the column's space. An object of its own,
    /// watched only by the stack: it changes with every move of the mouse,
    /// and as the column's own state it had every row in the column worked
    /// out again each time.
    @State private var hand = Hand()
    /// Let go of over a folder: it goes into it, smaller, and out.
    @State private var herdKept = false
    @State private var columnHeight: CGFloat = 0
    /// A newer Yab's note over the foot (UpdateRoom), which the rows go on
    /// under as they do under the foot.
    @State private var noteRoom: CGFloat = 0
    /// The agents' row over the foot and its gap (AgentRow), which the rows
    /// go on under as they do under the foot.
    @State private var agentRoom: CGFloat = 0
    /// The player's island over the foot (BandRoom), which the rows go on
    /// under as they do under the foot.
    @State private var bandRoom: CGFloat = 0
    @State private var shifts = Shifts()
    /// A shut folder of yours the hand opened by staying over it with a row,
    /// to shut again if the hand leaves it (`spring`).
    @State private var sprung: UUID?
    /// How far the held row is moved to stay under the hand while rows
    /// above it open or shut under it (`refold`).
    @State private var bias: CGFloat = 0
    /// A folder opening or shutting under the row in the hand, just now,
    /// and on which clock (Folders.toggle).
    @State private var refolding: Animation?
    /// A row the held one stayed over: let go, the two make a new folder.
    @State private var combine: Tab.ID?
    /// The row the held one is over, turning into the folder the two would
    /// make, and how far it has turned, 0 to 1 on the dwell's clock.
    @State private var folding: Tab.ID?
    @State private var fold: CGFloat = 0
    /// A folder of yours carried whole, where it would land, and how far
    /// the hand has taken it; the one just let go and what is left of its way.
    @State private var carrying: NestCarry?
    @State private var nestTravel: CGFloat = 0
    @State private var nestResting: String?
    @State private var nestRest: CGFloat = 0

    private struct NestCarry: Equatable {
        let nest: Nest
        let fromSlot: Int
        var index: Int
        var slot: Int
        /// The folder of yours it lands in there, and the shut one it is
        /// over, to go in at that one's end (Folders.NestLanding).
        var parent: UUID?
        var into: UUID?
        var landing: Folders.NestLanding { Folders.NestLanding(index: index, slot: slot, parent: parent, into: into) }
        static func == (a: NestCarry, b: NestCarry) -> Bool {
            a.nest === b.nest && a.fromSlot == b.fromSlot && a.index == b.index && a.slot == b.slot && a.parent == b.parent && a.into == b.into
        }
    }

    private struct Herd: Equatable {
        /// In the row's order; the held one among them.
        let ids: [Tab.ID]
        /// The same, to look up in while drawing.
        let members: Set<Tab.ID>
        let held: Tab.ID
        /// How many of them could be pins, a blank tab can't.
        let pinnable: Int
        /// Over the grid: the cell the first of them would take.
        var pinAt: Int?
        /// Among the rows left behind: where they came from, and where the
        /// gap now stands, none while they are over the shelf.
        let home: Int
        var index: Int?
        /// Over a shut or empty folder of yours: let go, they go into it,
        /// the gap staying where it was drawn.
        var into: UUID?
        /// From the pointer to the stack's middle, so it hangs from where it
        /// was taken.
        let grip: CGFloat
        /// Let go of: back in the list, hidden in their places until the
        /// stack gets there.
        var landed = false
    }

    /// True while a hand is on a row or a square: a drag the system breaks
    /// off never says it ended, and this going false with one still held is
    /// how that is noticed, and put right (see TabBar).
    @GestureState private var holding = false
    /// The pin under a pressed button, for its square to go down as a
    /// button does (Press). Beside the reorder, never instead of it.
    @GestureState private var pressingPin: Tab.ID?

    private struct Carry: Equatable {
        let tab: Tab.ID
        /// A row being pinned; otherwise a pin being let go of.
        let toPins: Bool
        /// Where in the other list it would land.
        var index: Int
    }

    /// A tab's row, a row's mark, a site's icon or a folder's face, and the
    /// gap from it to the title, at the column's density (Density).
    static var row: CGFloat { Density.current.row }
    static var mark: CGFloat { Density.current.mark }
    static var folder: CGFloat { Density.current.folder }
    static var folderWeight: CGFloat { 2 * mark / 24 }
    static var markGap: CGFloat { Density.current.markGap }
    /// The cross's slot's inset from a row's end (the cross is RowPlate's).
    static var endInset: CGFloat { Density.current.endInset }
    /// What the header's row holds at the column's width (ColumnHead):
    /// narrow, reload and the column's door go into "⋯". Reading mode has
    /// no door here; its key and menus have it.
    private var headFit: ColumnHead.Fit {
        ColumnHead.fit(width: prefs.sideWidth, right: browser.flank == .right, showSidebarButton: prefs.sidebarButton)
    }
    /// The row has back, forward and reload of its own (Helm). Not while
    /// the address bar is shown: they stand at its start, as Arc's toolbar
    /// takes them from its sidebar.
    private var helmRow: Bool { !ColumnKit.cut.contains("head") && !prefs.helmInBand && (helmed || mailPaging) }
    /// The column's own door stands in the row, but where "⋯" holds it.
    /// Full screen too, docked or out as a card, as Arc keeps it there
    /// (feedback #274): the column is the same column there, ⌘S and all.
    private var columnDoored: Bool { prefs.sidebarButton && !(helmRow && headFit == .fold) }
    /// The column's own doors, none with two side by side: each half has
    /// its own in its band, and a third set here would act on whichever
    /// half was last clicked. None in mail: its one page has nowhere to go
    /// back to and nothing to reload; New Mail stands where reload was.
    private var helmed: Bool { !browser.splitShown && !browser.inMail }
    /// One of mail's space's tabs in front rather than its page: back,
    /// forward and reload come by the lights for it, as in any space.
    private var mailPaging: Bool { browser.inMail && !MailPage.isMail(browser.active?.pending ?? browser.active?.address) }
    /// New Mail by the lights over mail's page only: a tab in front has its
    /// doors there, as in any space, and New Mail beside them pressed back
    /// on the lights and reload on itself.
    private var mailNew: Bool { browser.inMail && !helmed && !mailPaging }
    static var gap: CGFloat { Density.current.gap }
    /// The line over today's: its strip, and how much less it takes than a
    /// row, which the rows under it stand that much higher for.
    static var line: CGFloat { Density.current.line }
    static var lineShort: CGFloat { row - line }
    /// A row's corner, and the square under the pointer on its cross.
    static var radius: CGFloat { Density.current.radius }
    /// The column's one measure, the page's own inset: from the window's
    /// edge to what the column holds, from that to the page, between the
    /// pins, under them and under the foot. The header keeps it too, from
    /// its doors to the plate and the plate to the pins (SidePlate.below).
    static let margin: CGFloat = Backdrop.inset
    /// Scrollable room below the last row, separate from the foot: four
    /// rows of nothing, so a long list scrolls its last tabs up off the
    /// foot and away from the window's bottom edge rather than stopping
    /// against it. In rows, so a compact column keeps the same share.
    static var rowsTail: CGFloat { 4 * row }
    /// Where a row's icon starts inside it, and on the same line the
    /// plate's words and the ends of the line under the kept.
    static let inner: CGFloat = 10
    private var plateTab: Tab? { browser.active ?? SpacePager.shared.keptPlate(in: browser) }
    /// Where the pins start: the column's margin under the header's doors,
    /// and under the plate when the column has the address (SidePlate).
    /// Mail's column keeps the whole band (MailColumn).
    private var top: CGFloat { browser.inMail ? Metrics.strip : Self.pinsTop(plated: browser.sidePlated, extensions: SidePlate.pinsHeight(in: browser)) }
    static func pinsTop(plated: Bool, extensions: CGFloat = 0) -> CGFloat {
        Metrics.strip - SidePlate.lift + (plated ? SidePlate.height + SidePlate.below + extensions : 0)
    }
    /// The pointer is in the column: the plate shows its pinned extensions
    /// and the link.
    @State private var near = false
    /// The plate blurs what shows through it (PlateBlur): the drawings'
    /// lines, or a window behind through glass.
    private var plateFrosted: Bool { prefs.wearsGlass || prefs.wearsDrawings }
    static var square: CGFloat { Density.current.pin }
    /// A pin's corner, and the address plate's over the pins: a row's, so
    /// the plate's corner and the pins' under it are one curve; a pin
    /// squeezed shorter than the plate rounds off in step.
    static func corner(_ side: CGFloat) -> CGFloat {
        Density.current.radius * min(1, side / Density.current.plate)
    }
    static var pinGap: CGFloat { Density.current.pinGap }

    var body: some View {
        let _ = SpacePager.touched()
        ZStack(alignment: .top) {
            // Under the last row the window is dragged by, and a right
            // click there brings the space's menu, as Arc's sidebar does.
            DragStrip(reserved: 0, below: rowsEnd, menu: roomMenu,
                      contextTail: { [browser] point, view, event in
                          ColumnPages.of(browser)?.spaceMenuTail(at: point, from: view, event: event) == true
                      },
                      doubled: { [browser] in browser.newTab() })

            // The band the lights sit in is this mode's title bar: the window
            // is dragged by it and a double-click fills the screen with it,
            // everywhere but over the three doors at its far end, which take
            // their own clicks, when they are there. The lights answer first
            // wherever they are.
            band

            // The rows on AppKit (ColumnKit): each space's a page of its
            // own, under the head, the pins, the name and the foot, as
            // SideBar's own rows were.
            if ColumnKit.on {
                ColumnPagesHost(browser: browser, lead: lead, footRoom: pagesFootRoom, top: max(0, lead - SideBar.margin),
                                foot: pagesFootRoom > 0, grain: tone == nil ? 0 : prefs.grain)
                    .opacity(browser.inMail ? 0 : 1)
                    .modifier(HoardHush(hoard: browser.hoard))
            }

            VStack(alignment: .leading, spacing: 0) {
                // The traffic lights in their corner, and back, forward and
                // reload held against the right edge of the column, reload's
                // plate flush with the address plate's edge under it, as Arc
                // has it.
                // The column's own door right after the lights, as Arc has
                // it; with the column on the right, the lights over the page,
                // at the outer end, and the doors at the inner one.
                HStack(spacing: 0) {
                    if browser.flank == .left {
                        Lights(handle: true)
                            .frame(width: Lights.run)
                            // Lights.first in from the window's edge to the
                            // first one's center, where the strip keeps them and the lights
                            // stay while the tabs change sides (stillLights).
                            .padding(.leading, Lights.first - Lights.lead - SideBar.margin)
                            // The window's edge up to the row, which the band
                            // leaves to the lights (lightsEnd).
                            .background(alignment: .leading) {
                                DragStrip().frame(width: Lights.first - Lights.lead).offset(x: -SideBar.margin)
                            }
                            .frame(width: Metrics.sideLights, alignment: .leading)
                            .opacity(browser.stillLights || browser.titleLights ? 0 : 1)
                            .allowsHitTesting(!browser.titleLights)
                        if columnDoored {
                            ColumnDoor(browser: browser, prefs: prefs)
                                .environment(\.doorSize, .header)
                                .padding(.leading, ColumnHead.doorX() - SideBar.margin - Metrics.sideLights)
                        }
                        Spacer(minLength: 0)
                        headDoors
                    } else {
                        headDoors
                        Spacer(minLength: 0)
                        if columnDoored {
                            ColumnDoor(browser: browser, prefs: prefs)
                                .environment(\.doorSize, .header)
                        }
                    }
                }
                .frame(height: Metrics.strip)
                // Over the rows going on under it to the window's top, and
                // still the window's title bar there.
                .background { band.padding(.horizontal, -SideBar.margin) }
                .zIndex(1)
                // The address over the page: the pins come up to the
                // column's margin under the doors, as the plate does.
                .padding(.bottom, browser.sidePlated || browser.inMail ? 0 : -SidePlate.lift)

                // The address, when nothing over the page has it.
                if browser.sidePlated, !ColumnKit.cut.contains("plate") {
                    Group {
                        if let tab = plateTab {
                            // Still the last turn's answer as it is made.
                            SidePlate(browser: browser, tab: tab, near: near, width: prefs.sideWidth, fromAsking: plateAsking,
                                      frosted: plateFrosted)
                        } else {
                            EmptyPlate(browser: browser, frosted: plateFrosted)
                        }
                    }
                    .padding(.top, -SidePlate.lift)
                    .padding(.bottom, SidePlate.below)
                    .transition(.opacity)
                    .onChange(of: plateTab == nil, initial: true) { _, empty in plateAsking = empty }
                    .zIndex(1)
                }

                if shownPins > 0 {
                    Group {
                        // The AppKit column draws the pins itself, in each
                        // space's page (ColumnPage): their room is kept here.
                        if ColumnKit.on && !browser.inMail {
                            Color.clear.frame(height: pinBlock(count: shownPins) - SideBar.margin)
                        } else {
                            pinned
                        }
                    }
                        // Where the space's own part of the column starts,
                        // for a change of space to slide it (SpacePager).
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { [browser] in browser.pinsTop = $0 }
                        // Gone only with the pins: a column made again (the
                        // tabs back from the top) says where its grid is
                        // before the old one's going is heard, and that left
                        // the band without its pins.
                        .onDisappear { [browser] in if browser.pinnedCount == 0 { browser.pinsTop = nil } }
                        .padding(.bottom, SideBar.margin + unnamedGap)
                        // The pins every space shares stay where they are
                        // while the space under them comes in.
                        .modifier(SpaceTurn(id: browser.spaceID, step: browser.spaceStep, holds: { [browser] in browser.pinsHold($0) }))
                        .modifier(HoardHush(hoard: browser.hoard))
                        .zIndex(1)
                }

                // The private window names itself where a normal window
                // names its space, below the address and above its tabs.
                if named {
                    Group {
                        if ColumnKit.on {
                            Color.clear.frame(height: SideBar.row)
                        } else if browser.windowPurpose == .privateOnly {
                            PrivateName()
                        } else {
                            SpaceName(space: browser.space, browser: browser)
                        }
                    }
                        // Where what slides starts while the pins stand
                        // still (SpacePager.hold).
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { [browser] in browser.nameTop = $0 }
                        .onDisappear { [browser] in if !browser.namesSpaces || browser.inMail { browser.nameTop = nil } }
                        .padding(.bottom, SideBar.gap)
                        .modifier(SpaceTurn(id: browser.spaceID, step: browser.spaceStep))
                        .modifier(HoardHush(hoard: browser.hoard))
                        .zIndex(1)
                }

                // A row too long for the window scrolls between the pins and
                // the foot, and on under them, the address and the lights up
                // to the window's top, and the foot down to its bottom, as
                // Raycast's lists go under its search (ColumnEnds): dimmed
                // and blurred there, never off the window. One scroll view at
                // every count, never swapped for a plain stack, so the rows
                // keep who they are when the list grows past the window;
                // while it fits it is as tall as the rows, worked out rather
                // than measured, doesn't bounce, and the space under it is
                // still the window's to be dragged by.
                // Each space's row in a scroll view of its own, the ones of
                // spaces visited lately kept built behind the one on screen,
                // unseen (`rowPages`): a change of space shows a row already
                // made instead of making every row of it.
                if !ColumnKit.on {
                ZStack(alignment: .top) {
                    ForEach(rowPages, id: \.space) { source in
                        KeptPage(still: source.still, live: source.live) { rowsScroll(source) }
                            .equatable()
                            .toned(source.tone)
                            .opacity(source.live ? 1 : 0)
                            .allowsHitTesting(source.live)
                            .accessibilityHidden(!source.live)
                            .zIndex(source.live ? 1 : 0)
                    }
                }
                .modifier(SpaceTurn(id: browser.spaceID, step: browser.spaceStep))
                .coordinateSpace(name: "rows")
                .mask { ColumnFade(ends: ends, top: max(0, lead - SideBar.margin), foot: footRoom > 0, footRoom: footRoom) }
                .overlay { ColumnBlur(ends: ends, top: max(0, lead - SideBar.margin), foot: footRoom > 0, grain: tone == nil ? 0 : prefs.grain, radius: ColumnEnds.pinsBlur, footRoom: footRoom) }
                // In mail's space the column is mail's own (MailColumn):
                // its one page is no row to show.
                .frame(maxHeight: browser.inMail ? 0 : lead + rowsEnd - rowsLine + footRoom)
                .opacity(browser.inMail ? 0 : 1)
                // Under the downloads, while they stand over it.
                .modifier(HoardHush(hoard: browser.hoard))
                // Up to the window's top, under the pins, the address and
                // the lights, and down under the foot, standing in the
                // column where it always did.
                .padding(.top, -lead)
                .padding(.bottom, -footRoom)
                .padding(.horizontal, -SideBar.margin)
                }

                if browser.inMail {
                    MailColumn(browser: browser, rise: mailRise, note: noteRoom)
                        .padding(.top, 4)
                        .modifier(SpaceTurn(id: browser.spaceID, step: browser.spaceStep))
                }
                // Clear of the foot, which sits over the column's bottom,
                // and of the band over it while something plays elsewhere.
                Spacer(minLength: SideBar.footHeight)
                    // Where the space's own part ends, over the foot
                    // (SpacePager).
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY - SideBar.footHeight } action: { [browser] in browser.spaceFloor = $0 }
                // The note's room next to the foot's, the rows' scroll view
                // reaching down through both to the foot's bottom.
                Color.clear.frame(height: agentRoom)
                UpdateRoom(calls: browser.calls)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { noteRoom = $0 }
                BandRoom(room: browser.player.room, visible: prefs.showsPlayer, edge: browser.bandEdge)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bandRoom = $0 }
            }
            // One space for both lists, so a drag can tell which of them it
            // is over, and the carried tab can be drawn anywhere between.
            .coordinateSpace(name: "column")
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { columnHeight = $0 }
            .overlay(alignment: .topLeading) { carried }
            .overlay(alignment: .topLeading) { herded }
            .padding(.horizontal, SideBar.margin)

            VStack(spacing: 0) {
                Spacer()
                // Agents in One Row (experimental): what agents do out of
                // the list, over the note and the foot.
                if prefs.agentRow, !browser.inMail {
                    AgentRowView(browser: browser)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { agentRoom = $0 }
                        .onDisappear { agentRoom = 0 }
                }
                // A newer Yab: the room its note is written in, over the
                // band and the foot, whose capsule its button stands in for
                // (UpdateDoodle.swift).
                UpdateSlot(calls: browser.calls)
                // What plays in a tab you aren't on stands over the foot,
                // which keeps the column's bottom as in Arc (row 1090): the
                // island takes its room from the rows. The island itself is
                // laid over the column from outside its clip (Column,
                // Peek.swift), so its card can stand out over the page.
                // Here, its room.
                BandRoom(room: browser.player.room, visible: prefs.showsPlayer, edge: browser.bandEdge)
                if !ColumnKit.cut.contains("foot") {
                    SideFoot(browser: browser, prefs: prefs, hoard: browser.hoard)
                }
            }
            .overlayPreferenceValue(UpdateMarks.Key.self) {
                UpdateNoteInColumn(marks: $0, prefs: prefs)
                    .modifier(HoardHush(hoard: browser.hoard))
            }
        }
        .modifier(SidebarTypography())
        .modifier(StretchedColumn(browser: browser, prefs: prefs))
        .frame(maxHeight: .infinity)
        .onHover { hovering in
            // The pager covering the column can send a false exit while
            // the pointer still lies over its incoming page. Keep the
            // live grid ready at the same visibility as that page.
            let pointed = SpacePager.shared.covers(browser) ? SlidePointer.shared.near : hovering
            near = pointed
            browser.columnHovered = pointed
        }
        .onDisappear { browser.columnHovered = false }
        // The window still: the rows of spaces not yet visited made now.
        .onReceive(NotificationCenter.default.publisher(for: SpacePager.seedRows)) { [browser] note in
            if (note.object as AnyObject?) === browser { seeded += 1 }
        }
        .animation(Motion.glide, value: browser.sidePlated)
        // Two fingers sideways over the column: the next space, or back,
        // the column's spaces sliding as one row (SpacePager).
        .background { SpaceSwipe(browser: browser, column: true) }
        .background(landing ? Palette.hover(on: tone) : (tone == nil ? Palette.ground : .clear))
        .overlay(alignment: .trailing) {
            if !floating, tone == nil { Rectangle().fill(Palette.ink.opacity(0.05)).frame(width: 1) }
        }
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            browser.take(providers)
        }
        .animation(Motion.glide, value: browser.editingTab)
        // A tab opened or closed: the others make room, briefly, quicker
        // for a leaving than an arrival. Keyed on the count, so a drag, which
        // asks for its own spring, is left to it. The gray is not part of
        // this: each row puts its own down at once (see `.animation(nil,
        // value: live)` on the row).
        .animation(browser.tabsLineChanged ? Motion.keptShift : browser.tabsGrew || browser.dustLanding ? Motion.room : Motion.leave, value: browser.tabs.count)
        .animation(browser.dustFolded.isEmpty ? Motion.keptShift : Dust.fold, value: lineShown)
        .onChange(of: holding) { _, still in
            guard !still else { return }
            DispatchQueue.main.async {
                guard dragging != nil || pinDragging != nil || carrying != nil else { return }
                TearOff.shared.cancel()
                torn = nil
                if decked != nil {
                    SplitDeck.shared.leave()
                    decked = nil
                }
                shifts.stop()
                if carrying != nil { endCarry(cancelled: true) }
                withAnimation(Motion.settle) {
                    carry = nil
                    dragging = nil
                    travel = 0
                    bias = 0
                    sprung = nil
                    combine = nil
                    folding = nil
                    fold = 0
                    pinDragging = nil
                    pinTravel = .zero
                    resting = nil
                    herd = nil
                }
            }
        }
    }

    /// The space's menu, made at the press (SpaceMenu); none in mail's
    /// space, whose column is mail's own.
    private var roomMenu: (@MainActor () -> NSMenu)? {
        guard !browser.inMail else { return nil }
        let browser = browser
        return { NSHostingMenu(rootView: SpaceMenu(browser: browser, space: browser.space)) }
    }

    /// Where the rows stop and the window's own drag area starts. Added up
    /// from what was drawn rather than measured: a measurement would arrive a
    /// frame late, and for one frame the whole column would drag the window.
    private var rowsEnd: CGFloat {
        var rows = browser.tabs.count - browser.pinnedCount + folders.extra + (carry.map { $0.toPins ? -1 : 1 } ?? 0) - browser.pairs.count
            + (lineComing == nil ? 0 : 1)
        if let herd, !herd.landed { rows -= herd.ids.count - (herd.index == nil ? 0 : 1) }
        // A pair's second has no row of its own, as `pairs.count` says.
        rows -= browser.dustFolded.filter { browser.pair(of: $0)?.second != $0 }.count + browser.dustFoldedRows.count
        let loose = CGFloat(max(0, rows)) * (SideBar.row + SideBar.gap)
        // New Tab's row: the line's second, or its own over the rows.
        return top + pinBlock(count: shownPins) + nameBlock + loose + (folders.lined ? 0 : SideBar.row + SideBar.gap) + 8
    }

    // MARK: - the pinned squares

    private var pinnedTabs: [Tab] { browser.gridPins }
    private var looseTabs: [Tab] { browser.tabs.filter { $0.pin == nil } }

    /// At most this many across, however wide the column: Arc's Favorites
    /// keep four columns from a 240 pt sidebar to its 500 pt widest, the
    /// tiles growing wider rather than more of them fitting in.
    static let pinMaxColumns = 4
    /// A cell is never narrower than this, Arc's tile height: its Favorites
    /// go three across at a 220 pt sidebar (four would be 45 wide) and four
    /// at 240 (50 wide).
    static let pinMinWidth: CGFloat = 47

    /// As many columns as the column's width fits at `pinMinWidth`, four at
    /// most, and then only as many of those as it takes to keep the rows
    /// even: six pins go three and three rather than four and two, five go
    /// three and two.
    static func pinColumns(_ count: Int, width: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        let room = width - 2 * margin + pinGap
        let fits = min(pinMaxColumns, max(1, Int(room / (pinMinWidth + pinGap))))
        let rows = (count + fits - 1) / fits
        return (count + rows - 1) / rows
    }

    /// The pins the grid lays out: the pinned tabs, and a gap for a row on
    /// its way in.
    private var shownPins: Int {
        browser.pinnedCount + (carry?.toPins == true ? 1 : 0) + (herd?.pinAt != nil ? herd?.pinnable ?? 0 : 0)
    }

    private var pinCols: Int { pinGeometry(count: shownPins).cols }
    private var pinWidth: CGFloat { pinGeometry(count: shownPins).width }
    private var pinHeight: CGFloat { pinGeometry(count: shownPins).height }

    /// However many columns there are, they split the row's own width
    /// between them, the row is what fills edge to edge, not each cell on
    /// its own. The height is the one dimension that doesn't chase the
    /// sidebar's width: a wide column makes a cell a wide, short button,
    /// never a bigger square.
    private func pinGeometry(count: Int) -> (cols: Int, width: CGFloat, height: CGFloat) {
        let cols = SideBar.pinColumns(count, width: prefs.sideWidth)
        let available = prefs.sideWidth - 2 * SideBar.margin - CGFloat(cols - 1) * SideBar.pinGap
        let width = max(20, available / CGFloat(cols))
        return (cols, width, min(SideBar.square, width))
    }

    /// How tall the grid stands with this many pins, its gap below included.
    private func pinBlock(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let grid = pinGeometry(count: count)
        let rows = (count + grid.cols - 1) / grid.cols
        return CGFloat(rows) * grid.height + CGFloat(rows - 1) * SideBar.pinGap + SideBar.margin
    }

    /// The middle of a cell, in the column's space, for a grid of this many.
    private func pinCenter(_ index: Int, count: Int) -> CGPoint {
        let grid = pinGeometry(count: count)
        return CGPoint(
            x: CGFloat(index % grid.cols) * (grid.width + SideBar.pinGap) + grid.width / 2,
            y: top + CGFloat(index / grid.cols) * (grid.height + SideBar.pinGap) + grid.height / 2
        )
    }

    private var columnWidth: CGFloat { prefs.sideWidth - 2 * SideBar.margin }

    /// The grid itself: fixed-size cells, left-aligned, so a half-empty last
    /// row holds its ground rather than stretching to fill it.
    private var pinned: some View {
        let tabs = pinnedTabs
        let cols = pinCols
        let width = pinWidth
        let height = pinHeight
        let columns = Array(repeating: GridItem(.fixed(width), spacing: SideBar.pinGap), count: cols)
        // Measured in the grid's own space, not the square's: a square that
        // has just been moved to a new cell would otherwise report the drag
        // from where it now is, the target would jump back, and the square
        // would shuttle between two cells for as long as the finger stayed.
        var cells: [Slot] = tabs.enumerated().map { Slot(tab: $0.element, index: $0.offset) }
        if let carry, carry.toPins { cells.insert(Slot(tab: nil, index: -1), at: min(carry.index, cells.count)) }
        // A stack held over the grid: a cell for each of them.
        if let herd, let at = herd.pinAt {
            cells.insert(contentsOf: (0..<herd.pinnable).map { Slot(tab: nil, index: -10 - $0) }, at: min(at, cells.count))
        }
        return VStack(spacing: 0) { LazyVGrid(columns: columns, alignment: .leading, spacing: SideBar.pinGap) {
            ForEach(cells) { cell in
                if let tab = cell.tab {
                    let held = pinDragging == tab.id
                    let lift = (held || resting == tab.id) && carry == nil
                    PinSquare(
                        browser: browser,
                        prefs: prefs,
                        tab: tab,
                        live: tab.id == liveID || browser.pinMate(of: tab)?.id == liveID,
                        width: width,
                        height: height,
                        lifted: held || resting == tab.id,
                        pressed: pressingPin == tab.id && !held
                    )
                    .offset(pinShift(tab, index: cell.index))
                    .zIndex(held || resting == tab.id ? 1 : 0)
                    // Only the one in the hand casts a shadow. A clear shadow
                    // is still a blur the window server works out for every
                    // square on every frame they move.
                    .shadow(color: .black.opacity(lift ? 0.16 : 0), radius: lift ? 10 : 0, y: lift ? 3 : 0)
                    // Carried off down to the rows, or still flying in: the
                    // cell keeps its place, the square is drawn elsewhere.
                    .opacity(carry?.tab == tab.id || settling == tab.id ? 0 : 1)
                    .gesture(pinReorder(tab: tab, index: cell.index, columns: cols, width: width, height: height))
                    .simultaneousGesture(DragGesture(minimumDistance: 0).updating($pressingPin) { _, state, _ in state = tab.id })
                    // In a window behind another, as a row (see `reorder`).
                    .allowsWindowActivationEvents()
                } else {
                    // Where the row being brought up will land.
                    RoundedRectangle(cornerRadius: SideBar.corner(min(width, height)), style: .continuous)
                        .fill(Palette.wash(on: tone).opacity(0.35))
                        .frame(width: width, height: height)
                        .transition(.opacity)
                }
            }
        } }
        // A pin's home typed into Edit… (PinnedHome.swift): no room in a
        // square, so the pin's row of the grid is its field for as long as
        // it is typed into, as a pin across the top grows into one.
        .overlay(alignment: .topLeading) {
            if browser.editingHome, let id = browser.editingTab, let at = tabs.firstIndex(where: { $0.id == id }) {
                PinHomeField(browser: browser, tab: tabs[at], height: height)
                    .offset(y: CGFloat(at / cols) * (height + SideBar.pinGap))
                    .transition(.opacity)
            }
        }
    }

    /// A place in a list: a tab, the gap a carried tab would land in, or
    /// the line under the kept tabs.
    private struct Slot: Identifiable {
        let tab: Tab?
        /// The tab's position among its own list; for the gap, which gap;
        /// `line` for the line, `empty` for an empty folder of yours.
        let index: Int
        /// The empty folder's.
        var nest: Nest? = nil
        var id: String { tab?.id.uuidString ?? nest.map { Nest.key($0.id) } ?? (index == Slot.line ? "line" : "gap\(index)") }

        static let line = -100
        static let empty = -200
    }

    /// The held square is glued to the hand. The ones between where it was
    /// and where it would land each step one cell towards the gap it left,
    /// across a row, and round into the next.
    private func pinShift(_ tab: Tab, index: Int) -> CGSize {
        if pinDragging == tab.id { return pinTravel }
        if resting == tab.id { return rest }
        guard pinDragging != nil, carry == nil else { return .zero }
        var goal = index
        if pinFrom < pinGoal, index > pinFrom, index <= pinGoal { goal = index - 1 }
        if pinGoal < pinFrom, index >= pinGoal, index < pinFrom { goal = index + 1 }
        guard goal != index else { return .zero }
        let here = pinCenter(index, count: shownPins)
        let there = pinCenter(goal, count: shownPins)
        return CGSize(width: there.x - here.x, height: there.y - here.y)
    }

    /// How many cells the drag has moved, in the grid's own row-major order
    /// a straight line through the array a column-major offset would get
    /// wrong the moment it crossed a row. Row and column travel each measure
    /// themselves against that axis's own step now that a cell's width and
    /// height aren't the same number.
    private func pinDelta(columns: Int, stepX: CGFloat, stepY: CGFloat) -> Int {
        let col = Int((pinTravel.width / stepX).rounded())
        let row = Int((pinTravel.height / stepY).rounded())
        return row * columns + col
    }

    private func pinTarget(from: Int, moved: Int, shared: Bool) -> Int {
        pinPlace(min(max(0, from + moved), max(0, pinnedTabs.count - 1)), shared: shared, moving: true)
    }

    /// A cell for a pin that is, or is about to be, one of those every
    /// space shares, or not. Those come first and the space's own after
    /// them (one a call brought along, a private one), so a pin lands
    /// among the ones it will stand with (Folders.gather keeps it so).
    /// `moving`: one already in the grid, not one coming into it.
    private func pinPlace(_ index: Int, shared: Bool, moving: Bool = false) -> Int {
        guard browser.showsShared(browser.spaceID) else { return index }
        let count = browser.tabs.prefix { $0.everywhere != nil }.count
        return shared ? min(index, max(0, count - (moving ? 1 : 0))) : max(index, count)
    }

    /// Pick a square up and the others make way, across a row, and down
    /// into the next, exactly as far as the fingers actually moved.
    private func pinReorder(tab: Tab, index: Int, columns: Int, width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("column"))
            .updating($holding) { _, state, _ in state = true }
            .onChanged { value in
                if pinDragging != tab.id {
                    pinDragging = tab.id
                    pinFrom = index
                    pinGoal = index
                }
                pinTravel = value.translation
                // Below the grid, among the rows: the pin is being let go of.
                let below = value.location.y > pinsLine + (carry == nil ? 6 : -6)
                if below {
                    let step = SideBar.row + SideBar.gap
                    let target = min(max(0, Int(((value.location.y - rowsTop) / step).rounded(.down))), drawnRows(baseSlots))
                    let point = CGPoint(x: columnWidth / 2, y: value.location.y)
                    if carry == nil {
                        let start = pinCenter(pinFrom, count: browser.pinnedCount)
                        lift(tab, toPins: false, index: target,
                             from: CGPoint(x: start.x + pinTravel.width, y: start.y + pinTravel.height),
                             size: CGSize(width: width, height: height),
                             to: point, becoming: CGSize(width: columnWidth, height: SideBar.row))
                    } else {
                        follow(to: point, index: target)
                    }
                    return
                }
                if carry != nil { drop() }
                let stepX = width + SideBar.pinGap
                let stepY = height + SideBar.pinGap
                let goal = pinTarget(from: pinFrom, moved: pinDelta(columns: columns, stepX: stepX, stepY: stepY), shared: tab.everywhere != nil)
                if goal != pinGoal {
                    tick()
                    withAnimation(Motion.settle) { pinGoal = goal }
                }
            }
            .onEnded { _ in
                if let carry, !carry.toPins {
                    // Down among the rows: it lands as one, where the gap was.
                    let rowsTop = top + pinBlock(count: browser.pinnedCount - 1) + nameBlock - scroll.offset
                    let step = SideBar.row + SideBar.gap
                    // Above the line it is kept, and in a folder of yours if let
                    // go between two of its tabs.
                    let spot = placing(position(carry.index, in: baseSlots), in: baseSlots)
                    land(tab, at: CGPoint(x: columnWidth / 2, y: rowsTop + CGFloat(carry.index) * step + SideBar.row / 2),
                         size: CGSize(width: columnWidth, height: SideBar.row)) {
                        browser.unpin(tab)
                        if spot.kept, tab.keepable {
                            tab.kept = true
                            tab.nest = spot.nest
                        } else if let nest = spot.nest, nest.today {
                            tab.nest = nest
                        }
                        let rest = browser.tabs.filter { $0.pin == nil && $0.id != tab.id }
                        let index = spot.before.flatMap { before in rest.firstIndex { $0.id == before.id } } ?? rest.count
                        browser.move(tab, to: browser.pinnedCount + index)
                        folders.refresh()
                    }
                    withAnimation(Motion.settle) {
                        pinDragging = nil
                        pinTravel = .zero
                    }
                    return
                }
                guard pinDragging == tab.id else { return }
                let start = pinCenter(pinFrom, count: shownPins)
                let end = pinCenter(pinGoal, count: shownPins)
                put(tab, left: CGSize(width: start.x + pinTravel.width - end.x, height: start.y + pinTravel.height - end.y)) {
                    if pinGoal != pinFrom { browser.move(tab, to: pinGoal) }
                    pinDragging = nil
                    pinTravel = .zero
                }
            }
    }

    // MARK: - the rows

    private func loose(_ source: RowsSource) -> some View {
        // Lazy: a space of a hundred and seventy tabs, an Arc sidebar
        // brought in, built every row on the way in, 200 to 450 ms of main
        // thread a switch; only the rows on screen are built now. The rows
        // are placed by their index, not by where they were measured, so
        // a drag has its bearings whether a row is built or not.
        // No spacing of its own: each row brings the gap under it, so one
        // tucked away in a shut folder takes none (FolderRowPlace).
        LazyVStack(spacing: 0) {
            // See the grid: the drag is measured in the column's space, not
            // the row's, so a row that has just moved keeps its bearings.
            // A kept row has no hand on it, nor two tabs side by side.
            let moving = !source.live ? nil : carrying != nil ? nestShifts : folderShifts
            let rows = source.live ? pairRows : nil
            let liveID = source.liveID
            let lineShown = source.lineShown
            ForEach(source.slots) { cell in
                let step = SideBar.row + SideBar.gap
                if let tab = cell.tab, rows != nil, let pair = browser.pair(of: tab.id), pair.second == tab.id {
                    // Its first's row holds it, beside it (see PairRow).
                    Color.clear.frame(height: 0)
                } else if let tab = cell.tab {
                    let index = cell.index
                    let held = dragging == tab.id
                    // Lifted up into the pins: gone from the list, which
                    // closes up behind it, though its drag carries on.
                    let away = carry?.tab == tab.id || (herd?.held == tab.id && herd?.landed == false)
                    let place = place(of: tab, in: source)
                    // The rows of the folders it is the first tab of, the
                    // outer first, each stepped in as deep as it is.
                    ForEach(place?.heads ?? [], id: \.self) { key in
                      if let folder = folder(key, in: source) {
                        let going = moving.map { $0.folders[folder.id] == nil } ?? false
                        let lifted = carrying?.nest === folder.nest && folder.nest != nil
                        Group {
                            if let nest = folder.nest {
                                NestRow(browser: browser, nest: nest, count: folder.members.count,
                                        aimed: (aim?.into == nest.id && dragging != nil) || (herd?.into == nest.id && herd?.landed == false) || carrying?.into == nest.id,
                                        lifted: lifted, over: folder.over)
                                    // A search's folder stays where it grew, among today's.
                                    .gesture(nestReorder(nest, step: step), including: nest.today ? .subviews : .all)
                                    .allowsWindowActivationEvents()
                            } else {
                                FolderRow(browser: browser, folder: folder, open: isOpen(folder.id, in: source))
                            }
                        }
                        .padding(.leading, CGFloat(lifted ? carriedDepth : (folder.nest?.depth ?? 1) - 1) * Folders.indent)
                        .animation(Motion.settle, value: lifted ? carriedDepth : 0)
                        .modifier(DrawnRow(key: DrawnRows.folder(folder.id), rows: browser.drawnRows))
                        .padding(.bottom, SideBar.gap)
                        .offset(y: lifted ? nestTravel : nestResting == folder.id ? nestRest : CGFloat(moving?.folders[folder.id] ?? 0) * step)
                        .zIndex(lifted || nestResting == folder.id ? 1 : 0)
                        .opacity(going && !lifted ? 0 : 1)
                        .animation(Motion.quick, value: going)
                        // Its tabs all gone to dust in Clear's wave: it goes with them.
                        .opacity(browser.dustingRows.contains(DrawnRows.folder(folder.id)) ? 0 : 1)
                        .frame(height: browser.dustFoldedRows.contains(DrawnRows.folder(folder.id)) ? 0 : nil, alignment: .top)
                        .allowsHitTesting(!browser.dustingRows.contains(DrawnRows.folder(folder.id)))
                      }
                    }
                    // Tucked away in a shut folder: no row, but while the folder
                    // opens or shuts (the first tab's cell, which the folder's
                    // row is drawn in, is otherwise empty). A cell of no height
                    // is always in view to a lazy list, and fifty tabs' rows
                    // built and drawn again at every move of a drag, for
                    // nothing on screen, held the main thread.
                    Group {
                        if place.map({ $0.shown || $0.listed }) ?? true {
                            // A value of its own, drawn again only when what it
                            // shows changes (TabCell): each of these modifiers
                            // was worked out again for every row on screen, in
                            // every kept space, at every change of the column,
                            // a change of space's 50 ms of the main thread.
                            let other = rows != nil ? browser.partner(of: tab) : nil
                            let lifted = held || resting == tab.id
                            let editing = browser.editingTab == tab.id
                            TabCell(
                                look: TabCell.Look(
                                    tab: ObjectIdentifier(tab), other: other.map(ObjectIdentifier.init), newTabLit: browser.newTabLit,
                                    live: tab.id == liveID, picked: browser.isPicked(tab), lifted: lifted,
                                    editing: editing, refusals: editing ? browser.refusals : 0, joint: browser.joint(of: tab.id),
                                    staged: browser.stagePair?.contains(tab.id) == true, glyph: prefs.glyph,
                                    folding: folding == tab.id, fold: folding == tab.id ? fold : 0, made: combine == tab.id, away: away,
                                    opacity: away || settling == tab.id || sinking == tab.id || browser.dusting.contains(tab.id) || (herd?.landed == true && herd?.members.contains(tab.id) == true) ? 0 : decked != nil && (decked == tab.id || browser.partner(of: tab)?.id == decked) || torn == tab.id ? 0.5 : 1,
                                    indent: held ? indent(of: place) : 0,
                                    offset: CGSize(width: held ? (aim?.into != nil ? 16 : 32 * tuck) : 0,
                                                   height: rowShift(tab, index: index, step: step, moving: moving, rows: rows) + (held && aim?.into != nil ? 14 : 0)),
                                    scale: sinking == tab.id ? 0.6 : held ? (aim?.into != nil ? 0.88 : 1 - 0.12 * tuck) : 1, sinking: sinking == tab.id,
                                    index: index),
                                browser: browser, prefs: prefs, tab: tab, other: other,
                                gesture: reorder(tab: tab, index: index, step: step))
                                .equatable()
                        }
                    }
                    .modifier(FolderRowPlace(place: place, gap: SideBar.gap))
                    // Gone to dust in Clear's wave: its room given up,
                    // the rows under it riding up behind the dust (Tidy.swift).
                    .frame(height: browser.dustFolded.contains(tab.id) ? 0 : nil, alignment: .top)
                    .allowsHitTesting(!browser.dusting.contains(tab.id))
                    .zIndex(held || resting == tab.id ? 1 : 0)
                    .transition(browser.tabsLineChanged
                        ? .asymmetric(insertion: .opacity.animation(Motion.keptShift), removal: .opacity.animation(Motion.keptFade).combined(with: .offset(y: -(SideBar.row + SideBar.gap)).animation(Motion.keptShift)))
                        : .asymmetric(insertion: .identity, removal: .opacity.combined(with: .scale(scale: 0.96))))
                    // An open task's folder of many shows four, and says
                    // how many more wait under them (Folders.atOnce).
                    if let place, place.more > 0 {
                        FolderMore(folder: place.folder, count: place.more)
                            .padding(.leading, Folders.indent)
                            .modifier(DrawnRow(key: DrawnRows.more(place.folder), rows: browser.drawnRows))
                            .padding(.bottom, SideBar.gap)
                            .offset(y: rowShift(tab, index: index, step: step, moving: moving, rows: rows))
                            .opacity(browser.dustingRows.contains(DrawnRows.more(place.folder)) ? 0 : 1)
                            .frame(height: browser.dustFoldedRows.contains(DrawnRows.more(place.folder)) ? 0 : nil, alignment: .top)
                    }
                } else if let nest = cell.nest {
                    // An empty folder of yours.
                    let going = moving.map { $0.folders[nest.key] == nil } ?? false
                    NestRow(browser: browser, nest: nest, count: 0, aimed: (aim?.into == nest.id && dragging != nil) || carrying?.into == nest.id)
                        .padding(.bottom, SideBar.gap)
                    // In a folder of yours, stepped in as deep as it is.
                    .padding(.leading, CGFloat(nest.depth - 1) * Folders.indent)
                    .offset(y: CGFloat(moving?.folders[nest.key] ?? 0) * step)
                    .opacity(going ? 0 : 1)
                    .animation(Motion.quick, value: going)
                } else if cell.index == Slot.line {
                    // Keep New Tab's identity as the boundary folds away.
                    let going = moving.map { $0.folders[Folders.line] == nil } ?? false
                    VStack(spacing: 0) {
                        KeptLine(browser: browser, reports: source.live, visible: lineShown)
                            .padding(.bottom, SideBar.gap)
                            .opacity(lineShown && !going ? 1 : 0)
                            .animation(lineShown && !going ? Motion.keptShift : Motion.keptFade, value: lineShown && !going)
                            .offset(y: lineShown ? 0 : -(SideBar.line + SideBar.gap))
                            .animation(lineShown ? nil : browser.dustFolded.isEmpty ? Motion.keptShift : Dust.fold, value: lineShown)
                            .frame(height: lineShown ? SideBar.line + SideBar.gap : 0, alignment: .top)
                            .clipped()
                            .allowsHitTesting(lineShown && !going)
                            .accessibilityHidden(!lineShown || going)
                        newTab(lit: source.live && browser.newTabLit)
                    }
                    .offset(y: CGFloat(moving?.folders[Folders.newTab] ?? 0) * step)
                } else {
                    // Where the pin being brought down will land.
                    RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                        .fill(Palette.wash(on: tone).opacity(0.35))
                        .frame(height: SideBar.row)
                        .padding(.bottom, SideBar.gap)
                        .transition(.opacity)
                }
            }
        }
        // The last row's gap is the list's to leave out, as spacing would.
        .padding(.bottom, -SideBar.gap)
    }

    private var looseSlots: [Slot] {
        // The line, under the last kept tab, a row of its own.
        var cells = baseSlots
        if let carry, !carry.toPins { cells.insert(Slot(tab: nil, index: -1), at: position(carry.index, in: cells)) }
        // A stack in the hand: its rows are out of the list, and the gap
        // stands where they would go.
        // The held one stays, folded to nothing, since its drag is the one
        // going on.
        if let herd, !herd.landed {
            cells.removeAll { $0.tab.map { $0.id != herd.held && herd.members.contains($0.id) } ?? false }
            if let index = herd.index {
                cells.insert(Slot(tab: nil, index: -2), at: position(index, in: cells, skip: herd.held))
            }
        }
        return cells
    }

    /// The held row is glued to the hand; the ones it has passed each step
    /// one row towards the gap it left.
    private func rowShift(_ tab: Tab, index: Int, step: CGFloat, moving: (tabs: [Tab.ID: Int], folders: [String: Int])? = nil, rows: [Int]? = nil) -> CGFloat {
        if dragging == tab.id { return travel }
        if resting == tab.id { return rest.height }
        if carrying != nil { return CGFloat(moving?.tabs[tab.id] ?? 0) * step }
        guard dragging != nil, carry == nil, herd == nil else { return 0 }
        if let moving { return CGFloat(moving.tabs[tab.id] ?? 0) * step }
        // With pairs, by the rows as drawn, a pair's two sharing one.
        let (here, start, end) = rows.map { ($0[index], $0[from], $0[min(target, $0.count - 1)]) } ?? (index, from, target)
        if start < end, here > start, here <= end { return -step }
        if end < start, here >= end, here < start { return step }
        return 0
    }

    /// With two tabs side by side in the list, the row each loose tab is
    /// drawn in: a pair's second shares its first's. Nil without pairs,
    /// where the index is the row.
    private var pairRows: [Int]? {
        guard !browser.pairs.isEmpty else { return nil }
        var row = -1
        return looseTabs.map { tab in
            if browser.pair(of: tab.id)?.second != tab.id { row += 1 }
            return max(0, row)
        }
    }

    /// The index to move to for a row as drawn: the first tab in it going
    /// up, the last going down, so a pair is passed whole.
    private func tabIndex(ofRow row: Int, in rows: [Int], down: Bool) -> Int {
        let at = down ? rows.lastIndex { $0 <= row } : rows.firstIndex { $0 >= row }
        return at ?? (down ? rows.count - 1 : 0)
    }

    /// With a folder in the list, how many rows each row and each folder's
    /// own row moves while one is held: from where it is drawn now to where
    /// it is drawn once the held one lands. Worked out once a drawing.
    private var folderShifts: (tabs: [Tab.ID: Int], folders: [String: Int])? {
        guard let aim, let id = dragging, carry == nil, herd == nil else { return nil }
        // The same for every move of the hand until the aim changes: kept.
        // The row doesn't change under a drag but by a tab coming or going,
        // and a new drag starts afresh (see `reorder`).
        let key = Shifts.Key(aim: aim, held: id, count: browser.tabs.count, version: folders.version)
        if shifts.key == key, let value = shifts.value { return value }
        guard let held = looseTabs.first(where: { $0.id == id }) else { return nil }
        let value = shiftsFor(aim: aim, held: held, loose: alone(held))
        shifts.key = key
        shifts.value = value
        return value
    }

    /// The last rows' shifts worked out, and for what. An object, so keeping
    /// them redraws nothing.
    private final class Shifts {
        struct Key: Equatable {
            let aim: Folders.Landing
            let held: Tab.ID
            let count: Int
            let version: Int
        }
        var key: Key?
        var value: (tabs: [Tab.ID: Int], folders: [String: Int])?
        /// The line's slot as drawn now (`shiftsFor`).
        var lineNow: Int?
        /// Where each row is drawn for that aim, for what the hand is over.
        var drawn: [Tab.ID: Int] = [:]
        /// The hand staying over a shut folder, or over a row.
        var spring: DispatchWorkItem?
        var springFor: UUID?
        var dwell: DispatchWorkItem?

        func stop() {
            spring?.cancel()
            spring = nil
            springFor = nil
            dwell?.cancel()
            dwell = nil
        }
    }

    private func shiftsFor(aim: Folders.Landing, held: Tab, loose: [Tab]) -> (tabs: [Tab.ID: Int], folders: [String: Int]) {
        let id = held.id
        let now = folders.slots(loose, joined: !browser.pairs.isEmpty)
        var order = loose.filter { $0.id != id }
        order.insert(held, at: min(aim.index, order.count))
        let then = folders.slots(order, out: aim.out ? id : nil, joined: !browser.pairs.isEmpty, held: id, as: aim.guise)
        shifts.drawn = then.tabs
        shifts.lineNow = now.folders[Folders.line]
        var tabs: [Tab.ID: Int] = [:]
        for (key, slot) in now.tabs { tabs[key] = (then.tabs[key] ?? slot) - slot }
        // A folder's row or the line with nowhere to be once it lands, the
        // held one the last of its tabs or the last kept: left out, and
        // drawn going.
        var made: [String: Int] = [:]
        for (key, slot) in now.folders {
            if let there = then.folders[key] { made[key] = there - slot }
        }
        return (tabs, made)
    }

    /// Where the held row is drawn before it moves, in rows.
    /// The loose tabs as a held row moves among them: a pair's row is its
    /// first alone, the second going wherever the first does, so a pair is
    /// placed as the one row it is drawn as.
    private func alone(_ held: Tab) -> [Tab] {
        guard let pair = browser.pair(of: held.id), pair.first == held.id else { return looseTabs }
        return looseTabs.filter { $0.id != pair.second }
    }

    private func drawnRow(_ tab: Tab, index: Int) -> Int {
        folders.folders.isEmpty && !folders.lined ? index : folders.slots(looseTabs, joined: !browser.pairs.isEmpty).tabs[tab.id] ?? index
    }

    /// Where a row taken up would land if let go at once: where it is, as
    /// it is.
    private func still(_ tab: Tab, at index: Int) -> Folders.Landing {
        Folders.Landing(index: index, slot: drawnRow(tab, index: index), kept: tab.kept, nest: tab.nest?.id)
    }

    /// The line on its way in under a row being kept, the first: where it
    /// would stand, in rows, while the list has none of its own yet.
    private var lineComing: Int? {
        guard !folders.lined, let aim, let id = dragging, carry == nil, herd == nil,
              let held = looseTabs.first(where: { $0.id == id }) else { return nil }
        var order = alone(held).filter { $0.id != id }
        order.insert(held, at: min(aim.index, order.count))
        return folders.slots(order, joined: !browser.pairs.isEmpty, held: id, as: aim.guise).folders[Folders.line]
    }

    /// The rows as drawn with no gap and nothing in the hand: the tabs, and
    /// the line under the kept.
    private var baseSlots: [Slot] {
        // A pair's second has no cell of its own: its first's row holds it.
        // Nor has a tab tucked away in a shut folder, but while the folder
        // opens or shuts (Folders.toggle); the first of them keeps its cell,
        // for the folder's own row drawn in it.
        let joined = !browser.pairs.isEmpty
        var cells = looseTabs.enumerated().compactMap { index, tab -> Slot? in
            if joined, browser.pair(of: tab.id)?.second == tab.id { return nil }
            if let place = folders.place(of: tab), !place.shown, !place.listed, !place.head { return nil }
            return Slot(tab: tab, index: index)
        }
        // Empty folders standing among the kept, just above the run each
        // stands over (Nest.stand).
        if !folders.ahead.isEmpty {
            var begun: Set<String> = []
            cells = cells.flatMap { cell -> [Slot] in
                guard let tab = cell.tab, tab.kept, begun.insert(folders.run(tab)).inserted,
                      let nests = folders.ahead[folders.run(tab)] else { return [cell] }
                return nests.map { Slot(tab: nil, index: Slot.empty, nest: $0) } + [cell]
            }
        }
        // Empty folders in a folder of yours with tabs: at the end of its
        // run, while it is open and its row drawn (Folders.slots), the
        // deepest first where two runs end together.
        let ends = folders.trail.compactMap { key, nests -> (at: Int, depth: Int, nests: [Nest])? in
            guard let folder = folders.folder(key), let nest = folder.nest, nest.open, key != folders.carried, folders.drawn(key),
                  let last = cells.lastIndex(where: { cell in cell.tab.map { folder.members.contains($0.id) } ?? false }) else { return nil }
            return (last + 1, nest.depth, nests)
        }
        for end in ends.sorted(by: { $0.at != $1.at ? $0.at > $1.at : $0.depth < $1.depth }) {
            cells.insert(contentsOf: end.nests.map { Slot(tab: nil, index: Slot.empty, nest: $0) }, at: end.at)
        }
        // The boundary slot survives with only New Tab when today's is empty.
        let at = cells.firstIndex { $0.tab?.kept == false } ?? cells.count
        cells.insert(contentsOf: folders.block.map { Slot(tab: nil, index: Slot.empty, nest: $0) } + [Slot(tab: nil, index: Slot.line)], at: at)
        return cells
    }

    /// How many rows a cell draws: a folder's own row in its first tab's,
    /// and the tab's unless it is tucked away in a shut folder.
    private func drawnRows(_ cell: Slot) -> Int {
        if cell.nest != nil { return 1 }
        if cell.index == Slot.line { return folders.lined ? Folders.lineRows : 1 }
        guard let tab = cell.tab else { return 1 }
        let place = folders.place(of: tab)
        return (place?.heads.count ?? 0) + (place?.shown == false ? 0 : 1) + ((place?.more ?? 0) > 0 ? 1 : 0)
    }

    private func drawnRows(_ cells: [Slot]) -> Int { cells.reduce(0) { $0 + drawnRows($1) } }

    /// Where among `cells` a gap goes for `rows` rows down as drawn: before
    /// the first cell that starts there or further down.
    private func position(_ rows: Int, in cells: [Slot], skip: Tab.ID? = nil) -> Int {
        var at = 0
        for (index, cell) in cells.enumerated() {
            if let skip, cell.tab?.id == skip { continue }
            if cell.index == Slot.line, drawnRows(cell) == 0 { continue }
            if at >= rows { return index }
            at += drawnRows(cell)
        }
        return cells.count
    }

    /// A gap `at` among the cells: the tab it stands before (none at
    /// the end), whether above the line, and in which of your folders, when
    /// it is between two of one's tabs.
    private func placing(_ at: Int, in cells: [Slot]) -> (before: Tab?, kept: Bool, nest: Nest?) {
        let above = cells.prefix(at).last { $0.tab != nil }?.tab
        let below = cells.dropFirst(at).first { $0.tab != nil }?.tab
        guard let line = cells.firstIndex(where: { $0.index == Slot.line }), at <= line else {
            // Among today's, a search's folder takes what lands inside it.
            if let nest = above?.nest, nest.today, nest === below?.nest { return (below, false, nest) }
            return (below, false, nil)
        }
        // Between two of a folder's tabs: in the deepest folder both are in.
        let up = above?.nest?.chain ?? [], down = below?.nest?.chain ?? []
        let shared = zip(up, down).prefix(while: { $0 === $1 }).map { $0.0 }
        return (below, true, shared.last)
    }

    /// A light tap under the finger each time the held one passes another,
    /// a step down the list, and a firmer one for crossing into the other
    /// list (see `lift`).
    private func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Let go inside its own list: the list changes in one frame, with no
    /// animation, everything is already drawn where that leaves it, the
    /// others having stepped aside, and the one let go of glides the last
    /// of the way from wherever the hand left it.
    private func put(_ tab: Tab, left: CGSize, change: () -> Void) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            change()
            resting = tab.id
            rest = left
        }
        withAnimation(Motion.settle) { rest = .zero }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard resting == tab.id, dragging == nil, pinDragging == nil else { return }
            withAnimation(Motion.quick) { resting = nil }
        }
    }

    /// Pick a row up and the others make way as it passes them.
    private func reorder(tab: Tab, index: Int, step: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("column"))
            .updating($holding) { _, state, _ in state = true }
            .onChanged { value in
                if dragging != tab.id {
                    dragging = tab.id
                    from = index
                    target = index
                    aim = still(tab, at: index)
                    fromSlot = aim?.slot ?? index
                    shifts.key = nil
                    shifts.stop()
                    bias = 0
                    sprung = nil
                    combine = nil
                    folding = nil
                    fold = 0
                    landedFor = 0
                    resting = nil
                    // Picked with others: they all come.
                    let picked = browser.isPicked(tab) ? looseTabs.filter { browser.isPicked($0) }.map(\.id) : []
                    if picked.count > 1 {
                        gather(picked, held: tab, index: index, step: step, at: value)
                    }
                }
                // Out past the window's edge: the tab is leaving the window
                // (TearOff), and the rows stay as they were. Back inside,
                // the drag goes on here.
                if herd == nil, TearOff.shared.track(tab, browser: browser, moved: value.translation) {
                    if torn != tab.id {
                        if decked != nil {
                            SplitDeck.shared.leave()
                            decked = nil
                        }
                        if carry != nil { drop() }
                        shifts.stop()
                        sprung = nil
                        bias = 0
                        withAnimation(Motion.settle) {
                            torn = tab.id
                            combine = nil
                            folding = nil
                            fold = 0
                            target = from
                            travel = 0
                            aim = still(tab, at: from)
                            landedFor = 0
                        }
                    }
                    return
                }
                if torn == tab.id { torn = nil }
                // Over the space's capsule, or the tray it opens: the tabs
                // are going to another space, and the rows stay as they were.
                let held = herd.map { herd in browser.tabs.filter { herd.members.contains($0.id) } } ?? [tab]
                if SpaceDrop.shared.track(held, browser: browser) {
                    if let herd, !herd.landed {
                        withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.9)) {
                            hand.at = CGPoint(x: columnWidth / 2, y: value.location.y - herd.grip)
                        }
                    } else if herd == nil {
                        travel = value.translation.height
                        if carry != nil { drop() }
                        if target != from { withAnimation(Motion.settle) { target = from } }
                    }
                    return
                }
                // A stack moves by itself (see `Hand`); the column's own
                // state is left alone, so the rows aren't worked out again for
                // every move of the mouse.
                // Out over the pages: the deck has the tab, and every move
                // is its alone, nothing of the column's changes. Back over
                // the column, the drag goes on here.
                let out = browser.flank == .left ? value.location.x > prefs.sideWidth + 8 : value.location.x < -8
                // One row taken down past the list, and on out over the
                // pages: it goes back to its gap, and the deck has it.
                if out, decked == nil, carry == nil, let herd, herd.ids.count == 1, !herd.landed,
                   let held = decking(tab, at: value.startLocation.x), SplitDeck.shared.begin(held, in: browser) {
                    decked = held.id
                    withAnimation(Motion.settle) {
                        self.herd = nil
                        target = from
                        travel = 0
                        aim = still(tab, at: from)
                        landedFor = 0
                    }
                    return
                }
                if herd != nil {
                    herdMove(to: value.location, step: step)
                    return
                }
                if decked != nil {
                    if out { SplitDeck.shared.move(); return }
                    SplitDeck.shared.leave()
                    decked = nil
                } else if out, carry == nil, let held = decking(tab, at: value.startLocation.x),
                          SplitDeck.shared.begin(held, in: browser) {
                    decked = held.id
                    withAnimation(Motion.settle) {
                        target = from
                        travel = 0
                        aim = still(tab, at: from)
                        landedFor = 0
                    }
                    return
                }
                if let curve = refolding {
                    // A folder opening or shutting under it moves its place
                    // in the list on the folder's clock, and the hand's
                    // offset makes up for it on the same one: set at once, the
                    // row would ride up and slide back down with the rows.
                    withAnimation(curve) { travel = value.translation.height + bias }
                } else {
                    travel = value.translation.height + bias
                }
                // Down past the list, towards the space's capsule at the
                // foot: the row leaves the list the way a stack of them
                // would, a stack of one, drawn over everything, where the
                // list's own edge would cut it off on its way.
                if browser.spacesShown, belowRows(value.location.y) {
                    withAnimation(Motion.settle) { target = from }
                    // A pair row goes as the pair (#259).
                    let pair = browser.pair(of: tab.id).flatMap { $0.first == tab.id && browser.tab(id: $0.second) != nil ? $0 : nil }
                    gather(pair.map { [$0.first, $0.second] } ?? [tab.id], held: tab, index: index, step: step, at: value)
                    herdMove(to: value.location, step: step)
                    return
                }
                // Above the rows, in the pins: the row is being pinned. Going
                // in, the line is the top of the rows; once in, it is the
                // bottom of the grid as it now stands, the gap it opened for
                // this one included, so the hand can bring it down onto
                // that gap without it taking that for a way back to the list.
                let line = carry == nil ? pinsLine - 6 : top + pinBlock(count: browser.pinnedCount + 1) + 4
                let above = value.location.y < line
                if above {
                    // Pinned in a space that shows the pins every space
                    // shares, it is one of them (Browser.pin).
                    let target = pinPlace(pinTarget(at: value.location), shared: Browser.sharable(tab))
                    let cell = pinGeometry(count: browser.pinnedCount + 1)
                    if carry == nil {
                        lift(tab, toPins: true, index: target,
                             from: CGPoint(x: columnWidth / 2, y: rowsTop + CGFloat(drawnRow(tab, index: from)) * step + travel + SideBar.row / 2),
                             size: CGSize(width: columnWidth, height: SideBar.row),
                             to: value.location, becoming: CGSize(width: cell.width, height: cell.height))
                    } else {
                        follow(to: value.location, index: target)
                    }
                    return
                }
                if carry != nil { drop() }
                let moved = Int((travel / step).rounded())
                // By the rows as drawn: a folder's own row counts, and the
                // line's, a tab tucked into one doesn't, your rows stay above
                // a task's folders, and a folder's tab comes out onto its row.
                // Worked out each quarter of a row the hand moves, and when
                // it leans in or out of a folder.
                if let aim {
                    let want = Double(fromSlot) + Double(travel / step)
                    // Staying over another row: let go, a new folder of the two.
                    dwell(tab, want: want, right: value.translation.width)
                    if combine != nil { return }
                    // Sideways, how many folders deep: a mark's width a step,
                    // the first a little sooner, from as deep as it was.
                    let deep = Self.deep(from: tab.nest?.depth ?? 0, sideways: value.translation.width)
                    let key = Int((want * 4).rounded()) * 16 + (deep.map { $0 + 1 } ?? 0)
                    guard key != landedFor else { return }
                    landedFor = key
                    let next = folders.landing(tab, want: want, deep: deep, among: alone(tab), joined: !browser.pairs.isEmpty, current: aim, drawn: fromSlot)
                    spring(tab, next: next, want: want, step: step)
                    // Passing a row a folder could be made with, it makes way
                    // once the held one is 80% over it, not half: the 20 to
                    // 80% between is where staying offers a folder of the two.
                    if next != aim, withheld(tab, from: aim, to: next, want: want) {
                        landedFor = .min
                        return
                    }
                    if next != aim {
                        let crossed = next.kept != aim.kept || (next.into != nil) != (aim.into != nil)
                        NSHapticFeedbackManager.defaultPerformer.perform(crossed ? .levelChange : .alignment, performanceTime: .now)
                        withAnimation(Motion.settle) {
                            target = next.index
                            self.aim = next
                        }
                    }
                    return
                }
                var goal = min(max(0, from + moved), looseTabs.count - 1)
                if let rows = pairRows {
                    // Rows, not tabs: a pair is one.
                    let row = min(max(0, rows[from] + moved), rows.last ?? 0)
                    goal = tabIndex(ofRow: row, in: rows, down: moved > 0)
                    // The held pair's own second is where it already is.
                    if browser.pair(of: tab.id) != nil, moved == 0 { goal = from }
                }
                if goal != target {
                    tick()
                    withAnimation(Motion.settle) { target = goal }
                }
            }
            .onEnded { value in
                // Let go out of the window: it went to another, or a new one.
                if TearOff.shared.finish(browser) {
                    shifts.stop()
                    sprung = nil
                    bias = 0
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) {
                        dragging = nil
                        torn = nil
                        travel = 0
                        target = from
                        aim = nil
                        combine = nil
                        folding = nil
                        fold = 0
                    }
                    return
                }
                torn = nil
                // Let go over a space in the tray: they went there.
                if SpaceDrop.shared.finish(browser) {
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) {
                        dragging = nil
                        travel = 0
                        target = from
                        aim = nil
                        herd = nil
                    }
                    return
                }
                if herd != nil {
                    herdEnd(step: step)
                    return
                }
                if let id = decked {
                    let drop = SplitDeck.shared.end()
                    decked = nil
                    dragging = nil
                    aim = nil
                    travel = 0
                    if let drop, let held = browser.tabs.first(where: { $0.id == id }) {
                        browser.dropSplit(held, drop)
                    }
                    return
                }
                if let carry, carry.toPins {
                    // Up in the pins: it lands as a square, where the gap was.
                    let count = browser.pinnedCount + 1
                    let cell = pinGeometry(count: count)
                    land(tab, at: pinCenter(carry.index, count: count), size: CGSize(width: cell.width, height: cell.height)) {
                        // A pair row: pinned as one (PinPairs.swift).
                        if let pair = browser.pair(of: tab.id), browser.canPinPair(pair) {
                            browser.pinPair(pair, cell: carry.index)
                            return
                        }
                        // A half of a pair leaves a square on its page (`pin`).
                        let pinned = browser.pin(tab) ?? tab
                        browser.move(pinned, to: carry.index)
                    }
                    withAnimation(Motion.settle) {
                        dragging = nil
                        travel = 0
                    }
                    return
                }
                shifts.stop()
                sprung = nil
                bias = 0
                guard dragging == tab.id else { return }
                // Let go out over the pages with nothing there to take it:
                // back to its place, the rows it crossed on its way out left
                // as they were. Kept, a row it passed over became a folder
                // of the two, made of a drop meant for the page.
                if value.location.x > prefs.sideWidth + 8 {
                    combine = nil
                    folding = nil
                    fold = 0
                    aim = nil
                    target = from
                }
                // Stayed over another row: a new folder of the two, where it
                // stood, its row already drawn as the folder's.
                if let id = combine, let other = browser.tabs.first(where: { $0.id == id }) {
                    glide(tab, step: step) {
                        combine = nil
                        folding = nil
                        fold = 0
                        // Made on one of today's rows, it is today's; on a row
                        // in a folder of yours, in that one, where it stood.
                        browser.newFolder(with: [other, tab], today: !other.kept, around: other)
                    }
                    return
                }
                unfold()
                // Over a shut folder of yours: in it.
                if let into = aim?.into, let nest = browser.nests.first(where: { $0.id == into }) {
                    sink(tab, into: nest, step: step)
                    return
                }
                // Positions here are among the loose rows; the pinned block
                // sits in front of them in the real list.
                let drawn = pairRows
                let rows = aim.map { $0.slot - fromSlot } ?? drawn.map { $0[target] - $0[from] } ?? target - from
                let leaving = aim?.out == true
                let guise = aim?.guise
                put(tab, left: CGSize(width: 0, height: travel - CGFloat(rows) * step)) {
                    // Out of an agent's folder, onto its row or above: yours
                    // now, where it was let go.
                    if leaving { folders.keep(tab) }
                    // Across the line, or into a folder of yours or out.
                    let changed = guise.map { $0.kept != tab.kept || $0.nest != tab.nest?.id } ?? false
                    if let guise, changed {
                        tab.kept = guise.kept && tab.keepable
                        tab.nest = guise.nest.flatMap { id in browser.nests.first { $0.id == id } }
                    }
                    // Among folders a pair's row is placed without its second
                    // (see `alone`); taken down past where it was, the second
                    // it leaves behind is one more before it.
                    let past = aim != nil && target > from && browser.partner(of: tab) != nil && browser.pair(of: tab.id)?.first == tab.id
                    if target != from { browser.move(tab, to: target + (past ? 1 : 0) + browser.pinnedCount) }
                    if changed {
                        folders.refresh()
                        browser.writeSession(now: true)
                    }
                    dragging = nil
                    aim = nil
                    travel = 0
                }
            }
    }

    /// How far the held row steps in beyond where it is drawn at rest: into
    /// a folder, or back out of the one it is in.
    private func indent(of place: Folders.Place?) -> CGFloat {
        guard let aim, aim.into == nil else { return 0 }
        let task = place.map { !Nest.isKey($0.folder) } ?? false
        let then = aim.nest.map { folders.nest($0)?.depth ?? 1 } ?? (task && !aim.out ? 1 : 0)
        return CGFloat(then - (place?.depth ?? 0)) * Folders.indent
    }

    /// How many folders deep the hand asks a held row to go, from `depth`
    /// it was: nil while it has gone less than 10 points sideways, then one
    /// step, and another each 15 points (a mark's width) further.
    static func deep(from depth: Int, sideways: CGFloat) -> Int? {
        let far = abs(sideways)
        guard far >= 10 else { return nil }
        let steps = 1 + Int((far - 10) / Folders.indent)
        return max(0, min(Nest.deepest, depth + (sideways > 0 ? steps : -steps)))
    }

    /// The depth a folder in the hand is drawn at: of where it would land.
    private var carriedDepth: Int {
        guard let carried = carrying else { return 0 }
        if let into = carried.into { return folders.nest(into)?.depth ?? 0 }
        return carried.parent.flatMap { folders.nest($0)?.depth } ?? 0
    }

    /// Let go of over a shut folder of yours: the row goes to the folder's,
    /// smaller, and into it, and the rows close up behind it. The tab on
    /// screen stays out under the folder, as it always does, and glides
    /// there instead.
    private func sink(_ tab: Tab, into nest: Nest, step: CGFloat) {
        if tab.id == browser.activeID {
            glide(tab, step: step) { browser.file([tab], in: nest) }
            return
        }
        let head = folders.slots(looseTabs, joined: !browser.pairs.isEmpty).folders[nest.key] ?? fromSlot
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.16)) {
            travel = CGFloat(head - fromSlot) * step
            sinking = tab.id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(Motion.settle) {
                browser.file([tab], in: nest)
                dragging = nil
                aim = nil
                travel = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if sinking == tab.id { sinking = nil }
            }
        }
    }

    /// The list changed under a held row, in one frame, and the row glides
    /// the last of the way from the hand to where it now stands.
    private func glide(_ tab: Tab, step: CGFloat, change: () -> Void) {
        let hand = CGFloat(fromSlot) * step + travel
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            change()
            dragging = nil
            aim = nil
            travel = 0
            let now = looseTabs.firstIndex { $0.id == tab.id } ?? 0
            resting = tab.id
            rest = CGSize(width: 0, height: hand - CGFloat(drawnRow(tab, index: now)) * step)
        }
        withAnimation(Motion.settle) { rest = .zero }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard resting == tab.id, dragging == nil else { return }
            withAnimation(Motion.quick) { resting = nil }
        }
    }

    /// A shut folder of yours held over for 0.6 s opens under the hand, to
    /// put the row between its tabs; one opened so shuts again when the hand
    /// leaves it without letting go there, as Finder's folders spring.
    private func spring(_ tab: Tab, next: Folders.Landing, want: Double, step: CGFloat) {
        if let into = next.into, let nest = browser.nests.first(where: { $0.id == into }), !nest.open,
           browser.tabs.contains(where: { $0.nest?.within(nest) == true }) {
            guard shifts.springFor != into else { return }
            shifts.spring?.cancel()
            shifts.springFor = into
            let work = DispatchWorkItem { [self] in
                guard dragging == tab.id, aim?.into == into, !nest.open else { return }
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                sprung = into
                refold(tab, nest: nest, step: step)
            }
            shifts.spring = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            return
        }
        shifts.spring?.cancel()
        shifts.springFor = nil
        // Shut again once the hand lands outside it, not in a folder in it.
        guard let open = sprung, let nest = browser.nests.first(where: { $0.id == open }), nest.open,
              next.nest.flatMap({ folders.nest($0) })?.within(nest) != true,
              next.into.flatMap({ folders.nest($0) })?.within(nest) != true else { return }
        let loose = alone(tab)
        let drawn = folders.slots(loose, joined: !browser.pairs.isEmpty)
        let head = drawn.folders[nest.key] ?? 0
        let last = loose.filter { $0.nest?.within(nest) == true }.compactMap { drawn.tabs[$0.id] }.max() ?? head
        guard want < Double(head) - 0.8 || want > Double(last) + 1.5 else { return }
        sprung = nil
        refold(tab, nest: nest, step: step)
    }

    /// A folder opened or shut under a held row: the rows above it moving, the
    /// row itself stays under the hand, on the folder's clock.
    private func refold(_ tab: Tab, nest: Nest, step: CGFloat) {
        let index = looseTabs.firstIndex { $0.id == tab.id } ?? from
        let before = fromSlot
        let opening = !nest.open
        refolding = Folders.clock(opening: opening)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in refolding = nil }
        folders.toggle(nest.key) { [self] in
            let after = drawnRow(tab, index: index)
            var moved = CGFloat(after - before) * step
            // Opened under it: it goes in first, under the folder's own row,
            // where it was drawn stepped in over the shut folder, rather
            // than over that row, which would then make way for it and
            // slide down under the hand.
            if opening, let head = folders.slots(looseTabs, joined: !browser.pairs.isEmpty).folders[nest.key] {
                let now = Double(after) + Double((travel - moved) / step)
                moved -= CGFloat(max(0, Double(head + 1) - now)) * step
            }
            bias -= moved
            travel -= moved
            fromSlot = after
            landedFor = .min
            aim?.into = nil
            // Where it lands from there, at once: the hand may be still.
            guard let current = aim else { return }
            let next = folders.landing(tab, want: Double(fromSlot) + Double(travel / step), among: alone(tab),
                                       joined: !browser.pairs.isEmpty, current: current, drawn: fromSlot)
            target = next.index
            aim = next
        }
    }

    /// How far the held row has stepped aside for the row it is over to
    /// turn into a folder.
    private var tuck: CGFloat { combine != nil ? 1 : folding != nil ? fold : 0 }

    /// The dwell's clock: this long 20 to 80% over another row, and it is
    /// a folder of the two.
    private static let folds: TimeInterval = 0.18

    /// The hand over another row, one outside your folders, with the held
    /// one (Firefox's and Vivaldi's way): 20 to 80% over it for 0.18 s, or
    /// over it at all and gone 18 points right, and that row turns into
    /// the folder the two would make, the turn drawn as it comes. Moving
    /// off it takes the offer back.
    private func dwell(_ tab: Tab, want: Double, right: CGFloat) {
        // How far over the row next to its gap the held one is, 0 to 1.
        let over = aim.map { abs(want - Double($0.slot)) } ?? 0
        if let made = combine {
            // Kept while the hand is anywhere on it but its very edges; past
            // them, the row makes way as any other would.
            if let near = neighbor(of: tab, want: want), near.id == made, (0.08...0.9).contains(over) { return }
            unfold()
            landedFor = .min
            return
        }
        guard tab.keepable, herd == nil, carry == nil, aim?.into == nil else { return unfold() }
        // Only a kept row makes a folder with the held one. Among today's a
        // tab held or leaned over another made one of the two, and leaning
        // right is how a tab starts out to the page for a split: the folder
        // came of a drag meant for the page.
        let kept = { (id: Tab.ID) in browser.tabs.first(where: { $0.id == id })?.kept == true }
        if right > 18, let near = neighbor(of: tab, want: want), (0.05...0.9).contains(over) {
            return kept(near.id) ? make(near.id) : unfold()
        }
        guard let under = rowUnder(want, held: tab), kept(under) else { return unfold() }
        // Already turning; one turning back starts over.
        if folding == under, shifts.dwell != nil { return }
        shifts.dwell?.cancel()
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            folding = under
            fold = 0
        }
        // Once the row's turn is in, so it turns from nothing.
        DispatchQueue.main.async {
            guard folding == under, combine == nil else { return }
            withAnimation(.linear(duration: Self.folds)) { fold = 1 }
        }
        let work = DispatchWorkItem { [self] in
            guard dragging == tab.id, folding == under, combine == nil else { return }
            make(under)
        }
        shifts.dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.folds, execute: work)
    }

    /// The row under the held one is the folder the two would make: let
    /// go, it is.
    private func make(_ id: Tab.ID) {
        shifts.dwell?.cancel()
        shifts.dwell = nil
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        if folding != id {
            // Straight in from the side: the turn runs whole, quickly.
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                folding = id
                fold = 0
            }
            DispatchQueue.main.async {
                guard folding == id else { return }
                withAnimation(Motion.settle) {
                    fold = 1
                    combine = id
                }
            }
            return
        }
        withAnimation(Motion.settle) {
            fold = 1
            combine = id
        }
    }

    /// The row turning or turned into a folder turns back into a row, and
    /// is drawn as one again once it has.
    private func unfold() {
        shifts.dwell?.cancel()
        shifts.dwell = nil
        guard let was = folding else { return }
        withAnimation(Motion.quick) {
            combine = nil
            fold = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard folding == was, combine == nil, shifts.dwell == nil else { return }
            folding = nil
        }
    }

    /// The row next to the held one's gap, the way the hand is going, if a
    /// folder can be made with it: yours, not a pin, not in a folder, not the
    /// held one's pair.
    private func neighbor(of held: Tab, want: Double) -> (id: Tab.ID, slot: Int)? {
        guard held.keepable, let gap = aim?.slot else { return nil }
        let up = want < Double(gap)
        let partner = browser.partner(of: held)?.id
        let near = up ? gap - 1 : gap + 1
        for tab in looseTabs where tab.id != held.id && tab.id != partner {
            // A tab tucked away in a shut folder shares the slot after it.
            guard shifts.drawn[tab.id] == near, folders.place(of: tab)?.shown ?? true else { continue }
            // In a folder of yours too: the two make a folder in it.
            guard tab.keepable, tab.nest?.today != true, folders.place(of: tab).map({ Nest.isKey($0.folder) }) ?? true else { return nil }
            return (tab.id, near)
        }
        return nil
    }

    /// Whether the move to `next` waits: one step past a row a folder could
    /// be made with, and the held row less than 80% over it.
    private func withheld(_ tab: Tab, from aim: Folders.Landing, to next: Folders.Landing, want: Double) -> Bool {
        guard next.into == nil, aim.into == nil, next.kept == aim.kept, next.nest == aim.nest, abs(next.slot - aim.slot) == 1,
              let passed = neighbor(of: tab, want: want) else { return false }
        return abs(want - Double(passed.slot)) > 0.2
    }

    /// The row the held one is 20 to 80% over, next to its gap, if a folder
    /// can be made with it.
    private func rowUnder(_ want: Double, held: Tab) -> Tab.ID? {
        guard let near = neighbor(of: held, want: want) else { return nil }
        let off = abs(want - Double(near.slot))
        return off >= 0.2 && off <= 0.8 ? near.id : nil
    }

    // MARK: - a folder of yours in the hand

    /// Taken up by its row: its tabs fold under it, the one on screen too,
    /// and it moves among the kept as one row; let go, it opens out where
    /// it lands as it was. Never under the line, never into another folder.
    private func nestReorder(_ nest: Nest, step: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("column"))
            .updating($holding) { _, state, _ in state = true }
            .onChanged { value in
                if carrying?.nest !== nest {
                    guard browser.tabs.contains(where: { $0.nest?.within(nest) == true }) else { return }
                    withAnimation(Motion.settle) { folders.carry(nest.key) }
                    let from = folders.slots(looseTabs, joined: !browser.pairs.isEmpty).folders[nest.key] ?? 0
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) {
                        nestResting = nil
                        // Where it stands among the kept that aren't its own.
                        let kept = browser.tabs.filter(\.kept)
                        let first = kept.firstIndex { $0.nest?.within(nest) == true } ?? 0
                        let index = kept.prefix(first).filter { $0.nest?.within(nest) != true }.count
                        carrying = NestCarry(nest: nest, fromSlot: from, index: index, slot: from, parent: nest.parent?.id)
                    }
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
                nestTravel = value.translation.height
                guard let carried = carrying else { return }
                // Over a space in the foot, the capsule or the tray: it goes
                // there whole when let go (SpaceDrop).
                if SpaceDrop.shared.track(browser.tabs(in: nest), browser: browser, folder: nest) { return }
                let want = Double(carried.fromSlot) + Double(nestTravel / step)
                let deep = Self.deep(from: nest.depth - 1, sideways: value.translation.width)
                let next = folders.nestLanding(nest, want: want, deep: deep, among: looseTabs, current: carried.landing)
                if next != carried.landing {
                    if next.index != carried.index || (next.into != nil) != (carried.into != nil) { tick() }
                    withAnimation(Motion.settle) {
                        carrying?.index = next.index
                        carrying?.slot = next.slot
                        carrying?.parent = next.parent
                        carrying?.into = next.into
                    }
                }
            }
            // Gone to another space: here it only settles back.
            .onEnded { _ in endCarry(cancelled: SpaceDrop.shared.finish(browser), step: step) }
    }

    /// Let go of, or broken off: the folder where it lands, or back where
    /// it was, gliding the last of the way.
    private func endCarry(cancelled: Bool, step: CGFloat = SideBar.row + SideBar.gap) {
        guard let carried = carrying else { return }
        let hand = CGFloat(carried.fromSlot) * step + nestTravel
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            if !cancelled {
                if let into = carried.into, let there = folders.nest(into) {
                    // Over a shut folder of yours: in it, at the end of its run.
                    browser.file(carried.nest, in: there)
                } else {
                    browser.move(carried.nest, to: carried.index, in: carried.parent.flatMap { folders.nest($0) })
                }
            }
            carrying = nil
            nestTravel = 0
            let head = folders.slots(looseTabs, joined: !browser.pairs.isEmpty).folders[carried.nest.key] ?? carried.fromSlot
            nestResting = carried.nest.key
            nestRest = hand - CGFloat(head) * step
        }
        withAnimation(Motion.settle) {
            nestRest = 0
            folders.carry(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if nestResting == carried.nest.key, carrying == nil { nestResting = nil }
        }
    }

    /// The rows' shifts with a folder in the hand: from where they are drawn
    /// now to where they are once it lands.
    private var nestShifts: (tabs: [Tab.ID: Int], folders: [String: Int])? {
        guard let carried = carrying else { return nil }
        let loose = looseTabs
        let now = folders.slots(loose, joined: !browser.pairs.isEmpty)
        let members = loose.filter { $0.nest?.within(carried.nest) == true }
        var order = loose.filter { $0.nest?.within(carried.nest) != true }
        let kept = order.prefix(while: \.kept).count
        order.insert(contentsOf: members, at: min(carried.index, kept))
        let then = folders.slots(order, joined: !browser.pairs.isEmpty)
        var tabs: [Tab.ID: Int] = [:]
        for (key, slot) in now.tabs { tabs[key] = (then.tabs[key] ?? slot) - slot }
        var made: [String: Int] = [:]
        for (key, slot) in now.folders { if let there = then.folders[key] { made[key] = there - slot } }
        return (tabs, made)
    }

    /// Which tab of a row goes out over the pages: the row's own, or, from
    /// a pair's row, the chip the hand took it by.
    private func decking(_ tab: Tab, at x: CGFloat) -> Tab? {
        guard let other = browser.partner(of: tab), browser.pair(of: tab.id)?.first == tab.id else { return tab }
        return x > columnWidth / 2 ? other : tab
    }

    // MARK: - carrying several

    /// Where the rows start, the first of them, as far as it is scrolled.
    private var rowsTop: CGFloat { rowsLine - scroll.offset }
    /// Where the rows' room starts, under the pins and the space's name,
    /// however they scroll.
    private var rowsLine: CGFloat { pinsLine + nameBlock }
    /// The foot of the grid, its gap under it included: a row held up past
    /// it is being pinned, a pin brought down past it let go of. The
    /// space's name under it is the rows' side.
    private var pinsLine: CGFloat { top + pinBlock(count: browser.pinnedCount) }
    /// The space's name over the rows (SpaceName), and the gap under it;
    /// with no name, the room that keeps the rows from reading as the
    /// grid's next row (`unnamedGap`).
    private var nameBlock: CGFloat { named ? SideBar.row + SideBar.gap : unnamedGap }
    /// Under the pins with no space's name, another margin: the rows 8
    /// points under the grid, as far as its rows are from each other, read
    /// as one more row of it.
    private var unnamedGap: CGFloat { SideBar.unnamedGap(pins: shownPins > 0, named: named || browser.inMail) }
    static func unnamedGap(pins: Bool, named: Bool) -> CGFloat { pins && !named ? margin : 0 }
    private var named: Bool { (browser.namesSpaces || browser.windowPurpose == .privateOnly) && !browser.inMail }

    /// How far down the rows rest in their scroll view, which reaches the
    /// window's top: under the lights, the address, the pins and the
    /// space's name. Nothing in mail's space, which have no rows.
    private var lead: CGFloat {
        browser.inMail ? 0 : top + pinBlock(count: shownPins) + nameBlock
    }
    /// The foot's room at the scroll view's bottom, and the note's and the
    /// agents' row's over it, which the rows go on under. SwiftUI's rows
    /// stand over the player's room (BandRoom), so they end above it too.
    private var footRoom: CGFloat { browser.inMail ? 0 : SideBar.footHeight + noteRoom + agentRoom }
    /// The AppKit pages are laid over the column's whole height, the
    /// player's island too: their bottom room is everything stacked at the
    /// column's bottom, so their rows end above the foot there as well (#335).
    private var pagesFootRoom: CGFloat { browser.inMail ? 0 : footRoom + bandRoom }
    /// How far below the window's top mail's column stands, its lists going
    /// on up under the lights (MailColumn).
    private var mailRise: CGFloat {
        Metrics.strip + (browser.sidePlated ? SidePlate.block + SidePlate.pinsHeight(in: browser) : 0) + (shownPins > 0 ? pinBlock(count: shownPins) : 0) + 4
    }
    /// The band's drag strip, at the window's top and again under the
    /// lights' row, over the rows going under it. Only the doors shown are
    /// cut out of it: over them, under them and the book's room while the
    /// page has nothing to read still move the window, as Arc's band does.
    private var band: some View {
        let right = browser.flank == .right
        let start = lightsEnd
        return DragStrip(notch: right ? columnDoorNotch : doorsNotch,
                         leadNotch: (right ? doorsNotch : columnDoorNotch).offsetBy(dx: -start, dy: 0))
            .frame(height: Metrics.strip)
            .padding(.leading, start)
    }

    /// Where the band starts: past the lights when they are the column's
    /// and on show. A strip under them, even one hidden from accessibility,
    /// is where SwiftUI's accessibility hit test stops in this header, and
    /// Magnet and VoiceOver found no lights; their row moves the window
    /// itself (Lights.handle). See-through while the tabs change sides
    /// (stillLights), the row may take no press, and the band runs under it.
    private var lightsEnd: CGFloat {
        browser.flank == .left && !browser.titleLights && !browser.stillLights ? Lights.first - Lights.lead + Lights.run : 0
    }

    /// The doors at the header's far end, back, forward and reload, or
    /// New Mail over mail's page.
    @ViewBuilder private var headDoors: some View {
        if helmRow {
            // A page of mail's space in front: its doors, at once,
            // where any space has them, and never its book.
            Helm(browser: browser, reads: false, folded: headFit == .fold)
                .environment(\.doorSize, helmSize)
        }
        if mailNew {
            MailNewButton()
        }
    }

    /// Where the band's doors stand, from the corner of the end they are
    /// held against: the top trailing one, or the leading one with the
    /// column on the right.
    private var doorsNotch: CGRect {
        if mailNew {
            return CGRect(x: SideBar.margin, y: 0, width: MailNewButton.side, height: Metrics.strip)
        }
        // A tab in front in mail's space has the doors any space has.
        guard helmRow else { return .zero }
        let size = helmSize
        return CGRect(x: SideBar.margin, y: (Metrics.strip - size.side) / 2, width: size.helm, height: size.side)
    }

    /// The size of the doors at the header's far end at the column's width.
    private var helmSize: Door.Size {
        ColumnHead.doors(width: prefs.sideWidth, right: browser.flank == .right)
    }

    /// Where the column's own door stands, from the corner of its end.
    private var columnDoorNotch: CGRect {
        guard columnDoored else { return .zero }
        let door = Door.Size.header.side
        let x = browser.flank == .right ? SideBar.margin : ColumnHead.doorX()
        return CGRect(x: x, y: (Metrics.strip - door) / 2, width: door, height: door)
    }

    /// Taken up: the rows leave the list for the stack in the hand, and the
    /// list closes up around a gap where the held one was.
    private func gather(_ ids: [Tab.ID], held tab: Tab, index: Int, step: CGFloat, at value: DragGesture.Value) {
        let middle = rowsTop + CGFloat(drawnRow(tab, index: index)) * step + SideBar.row / 2
        // As drawn among the rows left: the line counts, and New Tab under it.
        let home = looseTabs.prefix(index).filter { !ids.contains($0.id) }.count + (folders.lined && !tab.kept ? Folders.lineRows : 0)
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            hand.at = CGPoint(x: columnWidth / 2, y: value.location.y - (value.startLocation.y - middle))
            herdKept = false
        }
        if ids.count > 1 { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
        withAnimation(Motion.settle) {
            let blank = browser.tabs.filter { ids.contains($0.id) && $0.isBlank }.count
            // A pair row goes up into the pins as one square.
            let pair = browser.pair(of: tab.id).flatMap { ids == [$0.first, $0.second] ? $0 : nil }
            herd = Herd(ids: ids, members: Set(ids), held: tab.id, pinnable: pair.map { browser.canPinPair($0) ? 1 : 0 } ?? ids.count - blank,
                        home: home, index: home, grip: value.startLocation.y - middle)
        }
    }

    private func herdMove(to point: CGPoint, step: CGFloat) {
        guard let herd, !herd.landed else { return }
        withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.9)) {
            hand.at = CGPoint(x: columnWidth / 2, y: point.y - herd.grip)
        }
        // Up over the pins: they open a cell for each. The line is the top
        // of the rows going in, and the foot of the grid grown for them once
        // there, as for a single row.
        let line = herd.pinAt == nil
            ? pinsLine - 6
            : top + pinBlock(count: browser.pinnedCount + herd.pinnable) + 4
        if herd.pinnable > 0, point.y < line {
            let held = browser.tabs.first { $0.id == herd.held }
            let at = pinPlace(pinTarget(at: point, adding: herd.pinnable), shared: held.map(Browser.sharable) ?? false)
            if herd.pinAt == nil { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
            if at != herd.pinAt {
                if herd.pinAt != nil { tick() }
                withAnimation(Motion.settle) {
                    self.herd?.pinAt = at
                    self.herd?.index = nil
                }
            }
            return
        }
        if herd.pinAt != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            withAnimation(Motion.settle) { self.herd?.pinAt = nil }
        }
        let left = drawnRows(baseSlots.filter { $0.tab.map { !herd.members.contains($0.id) } ?? true })
        let top = point.y - herd.grip - SideBar.row / 2
        // Over a shut or empty folder of yours, as the rows are drawn now.
        if let nest = herdFolder(at: Double((top - rowsTop) / step), staying: herd.into) {
            if herd.into != nest.id {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                withAnimation(Motion.settle) { self.herd?.into = nest.id }
            }
            return
        }
        if herd.into != nil { withAnimation(Motion.settle) { self.herd?.into = nil } }
        let index = min(max(0, Int(((top - rowsTop) / step).rounded())), left)
        if index != herd.index {
            tick()
            withAnimation(Motion.settle) { self.herd?.index = index }
        }
    }

    /// The shut or empty folder of yours whose row is drawn `row` rows down,
    /// with the stack in the hand; a little more room to stay over the one
    /// it is already over.
    private func herdFolder(at row: Double, staying: UUID?) -> Nest? {
        guard let herd else { return nil }
        var at = 0
        for cell in looseSlots {
            if let nest = cell.nest {
                if abs(row - Double(at)) <= (staying == nest.id ? 0.6 : 0.45) { return nest }
            } else if let tab = cell.tab, let place = folders.place(of: tab), place.head, !herd.members.contains(tab.id) {
                for (step, key) in place.heads.enumerated() {
                    guard let nest = folders.folder(key)?.nest, !nest.open else { continue }
                    if abs(row - Double(at + step)) <= (staying == nest.id ? 0.6 : 0.45) { return nest }
                }
            }
            if let tab = cell.tab, herd.members.contains(tab.id), tab.id != herd.held { continue }
            if cell.tab?.id == herd.held { continue }
            at += drawnRows(cell)
        }
        return nil
    }

    /// Let go of. Over a folder, they are kept in it and stay where they
    /// were; over the list, they go in together where the gap is, in the
    /// order they stood, whatever lay between them before.
    private func herdEnd(step: CGFloat) {
        guard let herd else { return }
        dragging = nil
        travel = 0
        target = from
        let group = browser.tabs.filter { herd.members.contains($0.id) }
        // Over a shut or empty folder of yours: into it, smaller, and in.
        if let into = herd.into, let nest = browser.nests.first(where: { $0.id == into }) {
            withAnimation(Motion.settle) {
                hand.at = CGPoint(x: columnWidth / 2, y: hand.at.y)
                herdKept = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    browser.file(group.filter(\.keepable), in: nest)
                    self.herd = nil
                }
            }
            return
        }
        // Over the grid: pinned, in their order, from the cell under the
        // hand; the stack goes into the first of them.
        if let at = herd.pinAt {
            let spot = pinCenter(at, count: browser.pinnedCount + herd.pinnable)
            withAnimation(Motion.settle) {
                hand.at = spot
                herdKept = true
                self.herd?.pinAt = nil
                if let pair = browser.pair(of: herd.held), herd.ids == [pair.first, pair.second] {
                    browser.pinPair(pair, cell: at)
                } else {
                    browser.pin(group, at: at)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { self.herd = nil }
            }
            return
        }
        let index = herd.index ?? herd.home
        // Where the gap is among the rows left, the line's included: above
        // it they are kept, between two of an open folder's tabs in it.
        let others = baseSlots.filter { $0.tab.map { !herd.members.contains($0.id) } ?? true }
        let spot = placing(position(index, in: others), in: others)
        var order = looseTabs.filter { !herd.members.contains($0.id) }.map(\.id)
        let at = spot.before.flatMap { before in order.firstIndex(of: before.id) } ?? order.count
        order.insert(contentsOf: herd.ids, at: at)
        withAnimation(Motion.settle) {
            hand.at = CGPoint(x: columnWidth / 2, y: rowsTop + CGFloat(index) * step + SideBar.row / 2)
            self.herd?.landed = true
            for tab in group {
                tab.kept = spot.kept && tab.keepable
                tab.nest = tab.kept ? spot.nest : nil
            }
            browser.arrange(loose: order)
            folders.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            guard self.herd?.landed == true else { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { self.herd = nil }
        }
    }

    /// The stack, drawn over the list.
    @ViewBuilder
    private var herded: some View {
        if let herd, let tab = browser.tabs.first(where: { $0.id == herd.held }) {
            let mate = browser.pair(of: tab.id).flatMap { pair in herd.ids == [pair.first, pair.second] ? browser.tab(id: pair.second) : nil }
            Stack(tab: tab, mate: mate, browser: browser, prefs: prefs, count: herd.ids.count, width: columnWidth, landing: herd.landed || herdKept,
                  live: tab.id == browser.activeID)
                .scaleEffect(herdKept ? 0.6 : 1)
                .opacity(herdKept ? 0 : 1)
                .modifier(Follow(hand: hand))
                .allowsHitTesting(false)
        }
    }

    // MARK: - past the list

    /// Below the last row, or, with the column full of them, near its foot,
    /// where the space's capsule is.
    private func belowRows(_ y: CGFloat) -> Bool {
        let rowsEnd = rowsTop + CGFloat(looseTabs.count + folders.extra - browser.pairs.count
            + (folders.lined ? 0 : 1)) * (SideBar.row + SideBar.gap) + 8
        return y > min(rowsEnd, columnHeight - SideBar.footHeight - 24)
    }

    // MARK: - carrying a tab across

    /// Which cell a row brought up over the grid would take: under the
    /// pointer, in a grid that has made room for one more.
    private func pinTarget(at point: CGPoint, adding: Int = 1) -> Int {
        let grid = pinGeometry(count: browser.pinnedCount + adding)
        let col = min(max(0, Int(point.x / (grid.width + SideBar.pinGap))), grid.cols - 1)
        let row = max(0, Int((point.y - top) / (grid.height + SideBar.pinGap)))
        return min(row * grid.cols + col, browser.pinnedCount)
    }

    /// Over the line into the other list. A tap under the finger says so,
    /// and the tab leaves the list it was in: drawn from exactly where it
    /// was, it takes the other list's shape as it goes to the pointer.
    private func lift(_ tab: Tab, toPins: Bool, index: Int, from: CGPoint, size: CGSize, to point: CGPoint, becoming shape: CGSize) {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        // Where it starts is set, not animated: it has to appear right on
        // top of what it is taking over from.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            carryAt = from
            carrySize = size
            carryFolded = !toPins
            carryLanding = false
        }
        withAnimation(Motion.settle) {
            carry = Carry(tab: tab.id, toPins: toPins, index: index)
        }
        DispatchQueue.main.async {
            withAnimation(Motion.settle) {
                carryAt = point
                carrySize = shape
                carryFolded = toPins
            }
        }
    }

    /// Held over the other list: it follows the hand on a short spring, and
    /// the gap moves to wherever it would now land.
    private func follow(to point: CGPoint, index: Int) {
        withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.9)) { carryAt = point }
        if carry?.index != index {
            withAnimation(Motion.settle) { carry?.index = index }
        }
    }

    /// Brought back over the line: a tap again, and it is simply back in
    /// the list it came from, as it was.
    private func drop() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        withAnimation(Motion.settle) { carry = nil }
    }

    /// Let go over the other list: it flies to its place while the lists
    /// change underneath, hidden in its new place until it gets there.
    private func land(_ tab: Tab, at point: CGPoint, size: CGSize, change: @escaping () -> Void) {
        settling = tab.id
        withAnimation(Motion.settle) {
            carryAt = point
            carrySize = size
            carryLanding = true
        }
        withAnimation(Motion.settle) {
            change()
            carry = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard settling == tab.id else { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { settling = nil }
        }
    }

    /// The tab being carried, drawn over both lists.
    @ViewBuilder
    private var carried: some View {
        if let id = carry?.tab ?? settling, let tab = browser.tabs.first(where: { $0.id == id }) {
            Carried(
                tab: tab, prefs: prefs, folded: carryFolded, size: carrySize,
                landing: carryLanding, live: tab.id == browser.activeID
            )
                .position(carryAt)
                .allowsHitTesting(false)
        }
    }

    // MARK: - each space's rows, kept

    /// What a space's rows are drawn from: for the space on screen the
    /// column's own, live; for one kept built behind it, its row as it last
    /// stood there, folders and all (`KeptRows`).
    private struct RowsSource {
        let space: UUID
        let live: Bool
        let slots: [Slot]
        /// Nil for the live row, which asks Folders.
        var places: [Tab.ID: Folders.Place]? = nil
        var folders: [String: Folders.Folder] = [:]
        var open: Set<String> = []
        var empties: [Nest] = []
        let liveID: Tab.ID?
        let lineShown: Bool
        /// The space's own color's words, as the column wore them there: a
        /// kept row keeps them, so it is not drawn again in the next
        /// space's colors while unseen, nor again in its own when it comes
        /// back. Every row reads them: a change of color drew every row
        /// built, kept ones and all.
        var tone: Tone? = nil

        /// What a kept row shows, to be drawn again only when it changes.
        var still: KeptStill { KeptStill(space: space, slots: slots.map(\.id), liveID: liveID, lineShown: lineShown) }
    }

    /// The rows of the spaces visited lately, made once and kept behind the
    /// one on screen, unseen, each in its own scroll view: a change of
    /// space had SwiftUI make every row of the new space and take down
    /// every row of the old, 100 to 200 ms of the main thread with the row
    /// of spaces sliding (feedback, 2026-10-09); back to a kept space its
    /// rows are already there, and only what changed since is drawn. Each
    /// kept row stands as it was when its space was left: it watches its
    /// tabs, as every row does, but not the column. An object, so keeping
    /// them redraws nothing.
    private final class KeptRows {
        /// The spaces, in the order they were first kept, the one on screen
        /// among them; and the same, the one left longest ago first.
        var order: [UUID] = []
        var recent: [UUID] = []
        var frozen: [UUID: RowsSource] = [:]
        /// How far each kept row's ends are scrolled under (ColumnEnds).
        var depths: [UUID: ColumnEnds.Depth] = [:]
        /// The space on screen when the rows were last drawn.
        var live: UUID?
        /// As many as are kept: past it the one left longest ago goes.
        static let most = 5
    }
    @State private var kept = KeptRows()
    /// Asked to make the rows of spaces not yet visited (SpacePager.prepare).
    @State private var seeded = 0

    /// The row on screen, and the kept ones behind it.
    private var rowPages: [RowsSource] {
        let now = browser.spaceID
        let live = RowsSource(space: now, live: true, slots: looseSlots, liveID: liveID, lineShown: lineShown, tone: tone)
        scroll.live = now
        // A change of space: the ends' fade as the row come in is scrolled.
        if kept.live != now {
            kept.live = now
            let depth = kept.depths[now] ?? ColumnEnds.Depth(above: 0, below: 0)
            DispatchQueue.main.async { [ends] in if ends.depth != depth { ends.depth = depth } }
        }
        // As it stands, for when the space is left: the rows as drawn, each
        // tab's place among the folders, what is open. Not the tabs that go
        // from space to space with you: they are the next space's too.
        if !browser.inMail {
            let slots = live.slots.filter { $0.tab.map { !browser.travels($0) } ?? true }
            let places = slots.compactMap(\.tab).compactMap { tab in folders.place(of: tab).map { (tab.id, $0) } }
            kept.frozen[now] = RowsSource(space: now, live: false, slots: slots,
                                          places: Dictionary(places, uniquingKeysWith: { a, _ in a }),
                                          folders: Dictionary(folders.folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                                          open: folders.open, empties: folders.empties, liveID: liveID, lineShown: lineShown, tone: tone)
        }
        // In the order they were first kept, never moved: the stack's order
        // changed at every switch had SwiftUI move its pages and lay every
        // one of them out again (50 ms). Which is in front is its zIndex;
        // which goes when too many are kept is `recent`'s.
        if !kept.order.contains(now) { kept.order.append(now) }
        kept.recent.removeAll { $0 == now }
        kept.recent.append(now)
        // Spaces not yet visited, their rows made ahead while the window is
        // still (SpacePager.prepare asks, `seeded`): as their rows stand
        // parked, without folders worked out, so the first visit finds
        // most of its rows made. Behind the ones visited: they go first.
        if seeded > 0, !browser.inMail {
            for space in browser.spaces where kept.order.count < KeptRows.most && kept.frozen[space.id] == nil && space.id != now {
                guard let row = browser.parked[space.id] else { continue }
                let loose = row.tabs.filter { $0.pin == nil && !browser.travels($0) }
                var slots = loose.enumerated().map { Slot(tab: $1, index: $0) }
                slots.insert(Slot(tab: nil, index: Slot.line), at: slots.firstIndex { $0.tab?.kept == false } ?? slots.count)
                kept.frozen[space.id] = RowsSource(space: space.id, live: false, slots: slots, places: [:], liveID: row.active,
                                                   lineShown: Folders.showsLine(loose), tone: tone)
                kept.order.append(space.id)
                kept.recent.insert(space.id, at: 0)
            }
        }
        // Spaces gone, and past the most kept, the one left longest ago.
        let spaces = Set(browser.spaces.map(\.id))
        kept.recent.removeAll { $0 != now && !spaces.contains($0) }
        while kept.recent.count > KeptRows.most { kept.recent.removeFirst() }
        kept.order.removeAll { !kept.recent.contains($0) }
        for id in kept.frozen.keys where !kept.order.contains(id) { kept.frozen[id] = nil }
        return kept.order.compactMap { $0 == now ? live : kept.frozen[$0] }
    }

    /// One space's row in its scroll view: the space on screen's, or one
    /// kept behind it, unseen and untouched.
    private func rowsScroll(_ source: RowsSource) -> some View {
        ScrollViewReader { proxy in
            // The scroll view reaches into the margin on both sides
            // and the rows keep inside it: the bar, a thread
            // (ThreadScroller), lands in the margin rather than over
            // a row's cross, and a held row's shadow and shake
            // aren't cut at its edge.
            ThreadScrollView(.vertical) {
                rows(source)
                    .padding(.horizontal, SideBar.margin)
                    .background(ColumnThread())
                    // How far it has scrolled, for a drag to find its
                    // rows by: kept, not drawn from, so a scroll draws
                    // nothing else again. A card over a row is put
                    // away as the rows move under the pointer.
                    .onGeometryChange(for: CGFloat.self) { [lead] in max(0, lead - $0.frame(in: .named("rows")).minY) } action: { [space = source.space, live = source.live] offset in
                        scroll.offsets[space] = offset
                        if live, browser.glance.shown != nil { browser.glance.drop() }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            // The rows rest under the pins and stop over the foot at
            // the end: the scroll view's margins, which it scrolls a
            // row to see clear of.
            .contentMargins(.top, lead, for: .scrollContent)
            .contentMargins(.bottom, footRoom + SideBar.rowsTail, for: .scrollContent)
            .contentMargins(.top, lead, for: .scrollIndicators)
            .contentMargins(.bottom, footRoom, for: .scrollIndicators)
            .modifier(OwnScrollEdges())
            .ignoresSafeArea(.container, edges: .vertical)
            // While the rows fit there is nothing to scroll out of
            // sight, and no edge to cut a held row off at as it goes
            // up past the first row or down past the last.
            .scrollClipDisabled(scroll.height >= rowsEnd - rowsLine - 1)
            // The room between the margins, what of the rows shows clear.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [lead, footRoom, space = source.space] in scroll.heights[space] = $0 - lead - footRoom }
            // What of the rows is in sight, for Clear's dust.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [browser, lead, footRoom, live = source.live] frame in
                if live { browser.rowsClip = CGRect(x: frame.minX, y: frame.minY + lead, width: frame.width, height: max(0, frame.height - lead - footRoom)) }
            }
            .modifier(ColumnScrolled(ends: ends, live: source.live) { [kept, space = source.space] in kept.depths[space] = $0 })
            // The tab you go to is the tab you see: ⌘1 to ⌘9, ⇧⌘], a
            // link opening beside the one on screen. A held key walks
            // the row without a spring chasing every step.
            .onChange(of: browser.activeID) { _, id in
                guard source.live else { return }
                // Another space's row come in: it is there at once,
                // under the row of spaces still sliding, not
                // scrolled to on a spring of the main thread's.
                let turned = scroll.space != nil && scroll.space != browser.spaceID
                scroll.space = browser.spaceID
                guard let id, dragging == nil, herd == nil, !inView(id) else { return }
                // By the row's own id, as its ForEach knows it (Slot).
                // isARepeat is only a key's to answer: asked of a
                // click, AppKit throws.
                if turned {
                    proxy.scrollTo(id.uuidString)
                } else if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat {
                    proxy.scrollTo(id.uuidString)
                } else {
                    withAnimation(Motion.glide) { proxy.scrollTo(id.uuidString) }
                }
            }
            .onAppear {
                guard source.live else { return }
                scroll.space = browser.spaceID
                if let id = browser.activeID { proxy.scrollTo(id.uuidString, anchor: .center) }
            }
        }
    }

    /// A tab's place among the folders, in the row `source` draws.
    private func place(of tab: Tab, in source: RowsSource) -> Folders.Place? {
        source.places.map { $0[tab.id] } ?? folders.place(of: tab)
    }

    private func folder(_ key: String, in source: RowsSource) -> Folders.Folder? {
        source.live ? folders.folder(key) : source.folders[key]
    }

    private func isOpen(_ key: String, in source: RowsSource) -> Bool {
        if source.live { return folders.isOpen(key) }
        if let folder = source.folders[key] { return Folders.isOpen(folder, among: source.open) }
        return source.open.contains(key)
    }

    /// The loose tabs and the row that makes another, which scroll as one.
    /// New Tab heads today's tabs, under the line when there is one (see
    /// `loose`), where a new tab comes in (Browser.open).
    private func rows(_ source: RowsSource) -> some View {
        loose(source)
            .overlay(alignment: .top) {
                if source.live, let at = lineComing {
                    KeptLine(browser: browser)
                        .offset(y: CGFloat(at) * (SideBar.row + SideBar.gap))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(Motion.keptShift, value: lineComing)
    }

    /// The foot's door and its margin beneath.
    static let footHeight: CGFloat = 26 + margin

    /// The tab's row shows whole where the rows are scrolled to, or it is a
    /// pin, never in the rows: nothing to scroll to. Asked of the scroll
    /// view, it laid the whole window out again there and then to find the
    /// row, on every switch of tab, a seventh of what the switch cost.
    private func inView(_ id: Tab.ID) -> Bool {
        guard let tab = browser.active, tab.id == id else { return false }
        if tab.pin != nil { return true }
        guard scroll.height > 0, let index = looseTabs.firstIndex(where: { $0.id == id }) else { return false }
        let top = CGFloat(drawnRow(tab, index: index)) * (SideBar.row + SideBar.gap)
        return top >= scroll.offset && top + SideBar.row <= scroll.offset + scroll.height
    }

    /// How far the rows are scrolled. An object, so a scroll redraws nothing.
    private final class Scroll {
        /// Each kept space's row scrolls on its own (`rowPages`): how far
        /// each is, and how much of it shows, the scroll view's own
        /// height. The space on screen's, read as `offset` and `height`.
        var offsets: [UUID: CGFloat] = [:]
        var heights: [UUID: CGFloat] = [:]
        var live: UUID?
        var offset: CGFloat { live.flatMap { offsets[$0] } ?? 0 }
        var height: CGFloat { live.flatMap { heights[$0] } ?? 0 }
        /// The space whose row it last scrolled for.
        var space: UUID?
    }
    @State private var scroll = Scroll()
    /// How far the rows have gone under the ends (ColumnEnds). Read by the
    /// fade and the blur alone, so a scroll draws nothing else again.
    @State private var ends = ColumnEnds()

    /// The tab the column lights: none while New Tab's row is lit.
    private var liveID: Tab.ID? { browser.newTabLit ? nil : browser.activeID }

    private var lineShown: Bool {
        Folders.showsLine(looseTabs, folded: browser.dustFolded)
    }

    private func newTab(lit: Bool) -> some View {
        Quiet(icon: "plus", title: "New tab", height: SideBar.row, news: true, lit: lit, prefs: browser.prefs, browser: browser) { browser.newTab() }
            // It raises the field: not away and back (Browser.fieldAway).
            .background(ClickZone(away: browser.fieldAway))
            .padding(.bottom, SideBar.gap)
    }

}

/// A loose tab's row in the column with all the column lays on it: in the
/// hand, folding, going to dust, stepped aside. A value compared by what it
/// shows (`look`), so a change of the column that leaves a row as it is
/// leaves its modifiers alone, its gesture among them: the drag reads the
/// column's state as it moves, and what the gesture was built for (the
/// tab, its index) is in the look. The row itself still watches its tab.
fileprivate struct TabCell<Reorder: Gesture>: View, Equatable {
    struct Look: Equatable {
        let tab: ObjectIdentifier
        let other: ObjectIdentifier?
        let newTabLit: Bool
        let live: Bool
        let picked: Bool
        let lifted: Bool
        let editing: Bool
        let refusals: Int
        let joint: Joint?
        let staged: Bool
        let glyph: Glyph
        let folding: Bool
        let fold: CGFloat
        let made: Bool
        let away: Bool
        let opacity: Double
        let indent: CGFloat
        let offset: CGSize
        let scale: CGFloat
        let sinking: Bool
        let index: Int
    }

    let look: Look
    let browser: Browser
    let prefs: Preferences
    let tab: Tab
    let other: Tab?
    let gesture: Reorder

    static func == (a: TabCell, b: TabCell) -> Bool { a.look == b.look }

    var body: some View {
        Group {
            if let other {
                PairRow(browser: browser, prefs: prefs, first: tab, second: other, lifted: look.lifted,
                        shown: look.newTabLit ? false : nil)
            } else {
                SideRow(browser: browser, prefs: prefs, tab: tab, live: look.live, picked: look.picked, lifted: look.lifted)
            }
        }
        .modifier(DrawnRow(key: DrawnRows.tab(tab.id), rows: browser.drawnRows))
        // Stayed over by a held row: it turns into the
        // folder the two would make, drawn in its place.
        .opacity(look.folding ? 0 : 1)
        .overlay {
            if look.folding {
                FolderToBe(tab: tab, turn: look.fold, made: look.made, live: look.live, prefs: prefs)
            }
        }
        .frame(height: look.away ? 0 : nil, alignment: .top)
        .opacity(look.opacity)
        // In the hand, stepped in or out as where it would land
        // is in a folder or not.
        .padding(.leading, look.indent)
        // Only the one in the hand casts a shadow (see the grid).
        .shadow(color: .black.opacity(look.lifted ? 0.14 : 0), radius: look.lifted ? 12 : 0, y: look.lifted ? 4 : 0) // design: the held row's lift, as it was
        // Over a shut folder of yours: smaller, and off its row
        // enough to show which folder it is going into; let go
        // there, smaller still as it goes in. Over a row
        // turning into a folder: smaller and aside, as the
        // row turns, never off the hand's height, so the
        // turn shows past it.
        .offset(look.offset)
        .scaleEffect(look.scale, anchor: look.sinking ? .center : .topLeading)
        .gesture(gesture)
        // In a window behind another, the press that
        // brings it forward is the tab's too, as in
        // Chrome: a click picks the tab and a drag takes
        // it at once, out to the window in front among
        // others. Without it the first press only woke
        // the window, and a drag from it went nowhere.
        .allowsWindowActivationEvents()
    }
}

/// What a space's row kept behind the one on screen shows (SideBar.rowPages).
fileprivate struct KeptStill: Equatable {
    let space: UUID
    let slots: [String]
    let liveID: Tab.ID?
    let lineShown: Bool
}

/// A space's row kept behind the one on screen: drawn again only when what
/// it shows changes, not on every change of the column around it. The row
/// on screen (`still` nil) is drawn whenever the column is.
fileprivate struct KeptPage<Content: View>: View, Equatable {
    let still: KeptStill
    let live: Bool
    @ViewBuilder let content: () -> Content

    var body: some View { content() }

    static func == (a: KeptPage, b: KeptPage) -> Bool {
        // The row on screen, or one coming to it or leaving it: drawn.
        if a.live || b.live { return false }
        return a.still == b.still
    }
}

/// The head's doors as a space draws them, pictured for the doors' row
/// while the spaces slide to or from Mail (SpacePager.doorsPicture): back,
/// forward and reload for the tab in front, none for a pair side by side,
/// whose halves have their own; New Mail in Mail. Held against the
/// column's end as the head holds them.
struct PagedDoors: View {
    let browser: Browser
    let mail: Bool
    /// The space's tab in front, and whether it is one of a pair.
    let tab: Tab?
    let paired: Bool
    @Environment(\.tone) private var tone

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if mail {
                // New Mail at rest: its glass doesn't draw in a picture.
                Symbol("square.and.pencil", size: 12)
                    .foregroundStyle(Palette.ink)
                    .frame(width: MailNewButton.side, height: MailNewButton.side)
                    .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.wash(on: tone)))
            } else if !paired && !browser.prefs.helmInBand {
                // With the address bar shown, they are in the band.
                StillHelm(tab: tab)
                    .environment(\.doorSize, ColumnHead.doors(width: browser.prefs.sideWidth, right: browser.flank == .right))
            }
        }
        .frame(height: Metrics.strip)
        .padding(.horizontal, SideBar.margin)
    }
}

/// Back, forward and reload as Helm draws them at rest, for a page: the
/// glyphs alone, in the ink their doors would wear, none of the doors'
/// anchors, lists or motion.
private struct StillHelm: View {
    let tab: Tab?
    @Environment(\.doorSize) private var size
    @Environment(\.tone) private var tone

    var body: some View {
        let open = tab.map { !$0.isBlank } ?? false
        HStack(spacing: size.gap) {
            mark("arrow.left", open && tab?.canGoBack == true)
            mark("arrow.right", open && tab?.canGoForward == true)
            mark("arrow.clockwise", open)
        }
    }

    private func mark(_ icon: String, _ enabled: Bool) -> some View {
        size.symbol(icon)
            .foregroundStyle(enabled ? Palette.muted(on: tone) : Palette.faint(on: tone))
            .frame(width: size.side, height: size.side)
    }
}

/// A space's own part of the column, its pins and rows as the column draws
/// them, for a space that isn't on screen: the pages beside the one on
/// screen while the column's spaces slide (SpacePager), in a host of their
/// own. Drawn from the top of the column, so its rows stand where the
/// column's will; the room over them is left empty. Only looked at, never
/// clicked: the space isn't there yet.
struct PagedSpace: View, Equatable {
    /// Not watched, nor are the folders: a page is drawn once, as the space
    /// stood when the row came up. Watching them, every page was drawn
    /// again on each thing the switch it slides for wrote, its rows'
    /// order worked out afresh from every tab of its space. Each row
    /// watches its own tab, and the preferences, itself.
    let browser: Browser
    let prefs: Preferences
    /// Mail's space: its column, as it will stand.
    let mail: Bool
    /// The space's row, as it was when the page was made: once the space
    /// comes, the browser's own copy of it goes.
    let row: Parked?
    /// The tabs that go with you from space to space (an agent's),
    /// as they were.
    let travelling: [Tab]
    /// The space, for its name over its rows as the column has it.
    var space: Space? = nil
    var empty: [Nest] = []
    /// How many rows the band has room for: the rest are under the foot,
    /// and a row built for a page is a row's worth of the main thread
    /// before the row can start to slide.
    var rows = 40
    /// The native page keeps its scroll while away. Its pictured replacement
    /// must start there too, or the rows jump when the picture comes down.
    var scrollOffset: CGFloat = 0
    /// The address over its pins drawn too, still: the pager's window
    /// takes it in on the way to or from Mail, whose column has none, so
    /// the plate goes with its page rather than standing over Mail's.
    var plate = false
    /// Which tasks' folders are open, as the column has them.
    private var folders: Folders { browser.folderBook }

    /// The same page: drawn once, it is never drawn again for its root's
    /// sake, the window's color changing under it with the switch.
    static func == (a: PagedSpace, b: PagedSpace) -> Bool {
        a.browser === b.browser && a.mail == b.mail && a.space?.id == b.space?.id && a.rows == b.rows && a.plate == b.plate && a.scrollOffset == b.scrollOffset
            && a.row?.active == b.row?.active && a.row?.tabs.map(\.id) == b.row?.tabs.map(\.id) && a.travelling.map(\.id) == b.travelling.map(\.id)
    }

    @MainActor static func savedOffset(in browser: Browser, space: UUID) -> CGFloat {
        guard ColumnKit.on, space != Space.mailID else { return 0 }
        return max(0, ColumnPages.of(browser)?.pages[space]?.offset ?? 0)
    }

    var body: some View {
        if mail {
            VStack(alignment: .leading, spacing: 0) {
                // Where Mail's column stands, under the doors: it has no
                // plate, whatever the space it comes from has.
                Color.clear.frame(height: Metrics.strip)
                MailColumn(browser: browser)
                    .padding(.top, 4)
                Spacer(minLength: SideBar.footHeight)
            }
            .padding(.horizontal, SideBar.margin)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else if let row {
            // Its row as the switch will lay it, the tabs that go with
            // you from space to space included (an agent's): left
            // out, they came in on the switch and pushed everything under
            // them down.
            let all = row.tabs + travelling
            // A pinned pair is one square (PinPairs.swift).
            let tucked = Set(row.pairs.filter { pair in all.contains { $0.id == pair.first && $0.pin != nil } && all.contains { $0.id == pair.second && $0.pin != nil } }.map(\.second))
            let pins = all.filter { $0.pin != nil && !tucked.contains($0.id) }
            let loose = all.filter { $0.pin == nil }
            // Plated as this space will be, not as the one on screen is.
            let plated = browser.sidePlated(row)
            VStack(alignment: .leading, spacing: 0) {
                if plate && plated {
                    Color.clear.frame(height: Metrics.strip)
                    PagedPlate(browser: browser, tab: all.first { $0.id == row.active }, width: prefs.sideWidth, space: space?.id)
                        .padding(.top, -SidePlate.lift)
                        .padding(.bottom, SidePlate.below)
                } else {
                    Color.clear.frame(height: SideBar.pinsTop(plated: plated, extensions: SidePlate.pinsHeight(in: browser, space: space?.id, tab: all.first { $0.id == row.active })))
                }
                // Its pins, even when they are the ones on screen: the
                // pager's window onto the row starts under them while they
                // stand still (SpacePager.hold), and this page's are then
                // out of it.
                if !pins.isEmpty {
                    grid(pins, active: row.active)
                        .padding(.bottom, SideBar.margin + SideBar.unnamedGap(pins: true, named: browser.namesSpaces))
                }
                if let space, browser.namesSpaces {
                    SpaceName(space: space).padding(.bottom, SideBar.gap)
                }
                VStack(alignment: .leading, spacing: SideBar.gap) {
                    // As many as the column can show: the rest are under
                    // its foot either way.
                    // A pair of tabs side by side is one row, as the column
                    // draws it: it doesn't fold into one as the space comes.
                    // The kept, their folders and the line under them, as
                    // the column will draw them (Kept.swift).
                    let shut = space.map { folders.isShut($0.id, in: browser) } ?? false
                    let items = Coming.items(loose, active: row.active, open: folders.open, whole: folders.whole, empty: empty, shut: shut,
                                             partner: { id in row.pairs.first { $0.first == id }?.second ?? row.pairs.first { $0.second == id }?.first }).prefix(rows)

                    ForEach(items) { item in
                        switch item {
                        case .newTab:
                            comingNew
                        case .line:
                            KeptLine(browser: browser)
                            comingNew
                        case .folder(let folder):
                            if let nest = folder.nest {
                                NestRow(browser: browser, nest: nest, count: folder.members.count, over: folder.over)
                                    .padding(.leading, CGFloat(nest.depth - 1) * Folders.indent)
                            } else {
                                FolderRow(browser: browser, folder: folder, open: Folders.isOpen(folder, among: folders.open), among: all)
                            }
                        case .more(let folder, let count):
                            FolderMore(folder: folder, count: count)
                                .padding(.leading, Folders.indent)
                        case .tab(let tab, let depth):
                            Group {
                                if let pair = row.pairs.first(where: { $0.first == tab.id }),
                                   let other = row.tabs.first(where: { $0.id == pair.second }) {
                                    PairRow(browser: browser, prefs: prefs, first: tab, second: other,
                                            shown: row.active == tab.id || row.active == other.id)
                                } else if !row.pairs.contains(where: { $0.second == tab.id }) {
                                    SideRow(browser: browser, prefs: prefs, tab: tab, live: tab.id == row.active, closes: false)
                                }
                            }
                            .padding(.leading, CGFloat(depth) * Folders.indent)
                        }
                    }
                }
                .offset(y: -scrollOffset)
                .clipped()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SideBar.margin)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// New Tab, heading today's as in the column.
    private var comingNew: some View {
        Quiet(icon: "plus", title: "New tab", height: SideBar.row, news: true) {}
    }

    /// What the coming row draws, in order.
    @MainActor
    enum Coming: Identifiable {
        /// A tab, and how many folders deep its row is stepped in.
        case tab(Tab, depth: Int)
        case line
        case newTab
        /// A folder of yours, or a task's.
        case folder(Folders.Folder)
        /// Under an open task folder's fourth, how many more it holds back.
        case more(String, Int)

        nonisolated var id: String {
            switch self {
            case .tab(let tab, _): return tab.id.uuidString
            case .line: return "line"
            case .newTab: return "new-tab"
            case .folder(let folder): return folder.id
            case .more(let folder, _): return "more " + folder
            }
        }

        /// The row as the column lays it (Folders): a folder's row before
        /// its first tab, its tabs only while it is open (or the one to be
        /// on screen, or one asking), a task's first four and how many more,
        /// and the line after the kept. `open` and `whole` are the column's,
        /// so a task's tabs that go with you from space to space come in
        /// folded as they are, not spilled out of a folder that is shut.
        /// `shut`: the space folded under its name (Folders.fold), its kept
        /// out of sight but the tab on screen, `partner` the other half of
        /// a pair.
        static func items(_ loose: [Tab], active: Tab.ID?, open: Set<String> = [], whole: Set<String> = [], empty: [Nest] = [],
                          shut: Bool = false, partner: (Tab.ID) -> Tab.ID? = { _ in nil }) -> [Coming] {
            let yours = Folders.nests(in: loose)
            let living = Set(yours.compactMap { $0.nest?.id })
            let empty = empty.filter { !living.contains($0.id) }
            let made = Folders.marked(yours + empty.map { Folders.Folder(id: $0.key, members: [], asking: [], nest: $0) } + Folders.tasks(in: loose, rowed: true), among: loose)
            let byID = Dictionary(made.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var places = Folders.lay(made, isOpen: { Folders.isOpen($0, among: open) }, whole: whole, folding: [], active: active,
                                     awake: Folders.awake(in: loose), partner: partner).places
            let folded = shut && (!empty.isEmpty || loose.contains(where: \.kept))
            var away: Set<Tab.ID> = []
            if folded {
                let asking = made.reduce(into: Set<Tab.ID>()) { $0.formUnion($1.asking) }
                away = Folders.fold(&places, tabs: loose, active: active, asking: asking, partner: partner, listed: false).away
            }
            var out: [Coming] = []
            var lined = false
            func roots() {
                guard !folded else { return }
                for nest in Folders.flat(empty, under: nil) { if let folder = byID[nest.key] { out.append(.folder(folder)) } }
            }
            let trails = folded ? [:] : Folders.trails(empty, living: living)
            var ends: [String: Tab.ID] = [:]
            for tab in loose { for key in places[tab.id]?.chain ?? [] { ends[key] = tab.id } }
            for tab in loose {
                if !tab.kept, !lined {
                    roots()
                    out.append(.line)
                    lined = true
                }
                if away.contains(tab.id) || AgentRow.holds(tab) { continue }
                if let place = places[tab.id], place.bare {
                    if place.shown { out.append(.tab(tab, depth: 0)) }
                    continue
                }
                guard let place = places[tab.id], let folder = byID[place.folder] else {
                    out.append(.tab(tab, depth: 0))
                    continue
                }
                for key in place.heads { if let head = byID[key] { out.append(.folder(head)) } }
                if place.shown { out.append(.tab(tab, depth: place.depth)) }
                if place.more > 0 { out.append(.more(folder.id, place.more)) }
                for key in place.chain.reversed() where ends[key] == tab.id && byID[key]?.nest?.open == true {
                    for nest in trails[key] ?? [] { if let folder = byID[nest.key] { out.append(.folder(folder)) } }
                }
            }
            if !lined { roots(); out.append(.newTab) }
            return out
        }
    }

    private func grid(_ pins: [Tab], active: Tab.ID?) -> some View {
        let cols = SideBar.pinColumns(pins.count, width: prefs.sideWidth)
        let available = prefs.sideWidth - 2 * SideBar.margin - CGFloat(cols - 1) * SideBar.pinGap
        let width = max(20, available / CGFloat(cols))
        let height = min(SideBar.square, width)
        // Laid out whole, not lazily as the column's grid is: a page is
        // made once and shown again from a host put back in the window
        // (SpacePager.made), and is drawn whole in the frame it comes in.
        let lines = stride(from: 0, to: pins.count, by: max(1, cols)).map { Array(pins[$0..<min($0 + max(1, cols), pins.count)]) }
        return VStack(alignment: .leading, spacing: SideBar.pinGap) {
            ForEach(lines.indices, id: \.self) { line in
                HStack(spacing: SideBar.pinGap) {
                    ForEach(lines[line]) { tab in
                        PinSquare(browser: browser, prefs: prefs, tab: tab, live: tab.id == active, width: width, height: height)
                            .frame(width: width)
                    }
                }
            }
        }
    }
}

/// The space's name at the head of its rows, as Arc has it: with the pins
/// every space shares standing still over them (docs/shared-pins.md),
/// the name sliding in with its rows and the window's color are what say
/// The private window's name in the same row and type as a space name.
struct PrivateName: View {
    @Environment(\.tone) private var tone
    @Environment(\.tabTitleSize) private var titleSize

    var body: some View {
        HStack(spacing: SideBar.markGap) {
            Symbol("incognito", size: 11.5)
                .frame(width: SideBar.mark, height: SideBar.mark)
            Text("Private")
                .lineLimit(1)
        }
        .font(.system(size: titleSize, weight: .semibold))
        .foregroundStyle(Palette.muted(on: tone))
        .padding(.leading, SideBar.inner)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SideBar.row)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("Private window")
    }
}

/// Which space this is. In the column it folds the space, as Arc's does:
/// under the pointer a plate, a chevron where the emoji was and ••• at its
/// end with the space's menu; a click folds the kept tabs away under it, or
/// back (Folders.toggleSpace), and a second click soon after puts them back
/// and names the space, as a folder's double-click does. The concept:
/// work/design/space-collapse-2026-10-08.
struct SpaceName: View {
    let space: Space
    /// The column's own, to be clicked; a space on its way in only shows it.
    var browser: Browser? = nil
    /// A tab held over it, folded: let go, it is kept there.
    var aimed = false
    /// Watched: every window's folders tell the first window's; this
    /// window's are read.
    @ObservedObject private var watched = Folders.shared
    private var folders: Folders { browser?.folderBook ?? .shared }
    @Environment(\.tone) private var tone
    @Environment(\.tabTitleSize) private var titleSize
    @State private var onDots = false
    @State private var hovering = false
    @State private var lastTap: TimeInterval?

    /// The dots' plate and its room off the row's end, a tab row's cross's
    /// square (RowPlate): the name stops short of it at rest too, so
    /// nothing moves under the pointer.
    private static var dots: CGSize { CGSize(width: RowPlate.column.side, height: RowPlate.column.side) }
    private static var dotsInset: CGFloat { RowPlate.column.inset }

    private var live: Bool { browser != nil }
    /// Something to fold: the chevron shows, and a click folds.
    private var folds: Bool { live && folders.keeps }
    private var shut: Bool { live && folders.shut }

    var body: some View {
        if browser?.blank == true {
            BlankHeading()
        } else {
            named
        }
    }

    private var named: some View {
        let _ = SpacePager.touched()
        // On a tab row's lines, as Arc's: the mark in a site's mark's slot,
        // the name where a title starts and at its size.
        return HStack(spacing: SideBar.markGap) {
            ZStack {
                SpaceMark(icon: space.icon, size: 11.5)
                    .opacity(hovering && folds ? 0 : 1)
                if hovering && folds {
                    // Down while its kept show, to the side once folded, on
                    // the rows' clock (Folders.clock). Its line a tab's
                    // cross's (RowPlate).
                    Symbol("chevron.down", size: 9, weight: .semibold, stroke: RowPlate.column.cross / 8)
                        .rotationEffect(.degrees(shut ? -90 : 0))
                }
            }
            .frame(width: SideBar.mark, height: SideBar.mark)
            Text(space.name).lineLimit(1)
        }
        .font(.system(size: titleSize, weight: .semibold))
        .foregroundStyle(Palette.muted(on: tone))
        .padding(.leading, SideBar.inner)
        .padding(.trailing, Self.dots.width + Self.dotsInset + CapsulePlan.gap) // design: the name stops short of the ••• that comes at the row's end
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SideBar.row)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(folds ? [.isHeader, .isButton] : .isHeader)
        .accessibilityValue(folds ? (shut ? "Collapsed" : "Expanded") : "")
        .accessibilityAction { if folds { folders.toggleSpace() } }
        .overlay(alignment: .trailing) {
            if let browser { dots(browser) }
        }
        .background {
            if aimed {
                SelectionPlate(corner: SideBar.radius, state: .selected, prefs: browser?.prefs)
            } else if hovering {
                SelectionPlate(corner: SideBar.radius, state: .hover)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
        .onHover { hovering = live && $0 }
        .onTapGesture { tapped() }
        .steadyMenu(actions: true) {
            if let browser { SpaceMenu(browser: browser, space: space) }
        }
    }

    /// Folded or back at once; a second click soon after puts it as it was
    /// and names the space, as Finder's double-click does.
    private func tapped() {
        guard let browser else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let second = lastTap.map { now - $0 < NSEvent.doubleClickInterval } ?? false
        lastTap = second ? nil : now
        if folds { folders.toggleSpace() }
        if second {
            SpaceAsk.name(space, browser: browser) { browser.renameSpace(space.id, to: $0) }
        }
    }

    /// ••• at the row's end under the pointer: the space's menu. Always
    /// there, only unseen at rest, so an open menu keeps its button.
    private func dots(_ browser: Browser) -> some View {
        // The searchable panel (ActionMenu.swift) from where it was pressed.
        Button {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            let at = NSApp.currentEvent.map { window.convertPoint(toScreen: $0.locationInWindow) } ?? NSEvent.mouseLocation
            ActionMenu.show(NSHostingMenu(rootView: SpaceMenu(browser: browser, space: space)), in: window, at: at)
        } label: {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 3, height: 3) }
            }
            .foregroundStyle(onDots ? Palette.strong(on: tone) : Palette.muted(on: tone))
            .frame(width: Self.dots.width, height: Self.dots.height)
            .background { if onDots { RowPlate.column.square() } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .focusable(false)
        .onHover { onDots = $0 }
        .padding(.trailing, Self.dotsInset)
        .opacity(hovering || onDots ? 1 : 0)
        .allowsHitTesting(hovering || onDots)
        .accessibilityLabel("Space menu")
    }
}

extension Browser {
    /// The column says which space it is over its rows whenever spaces are
    /// on, one space alone too, as Arc's does: the name is where the space
    /// folds its kept tabs away (feedback #270). A private window names
    /// none of yours (register 1015). A Blank Window's says "This Window"
    /// there, spaces on or off. Hide Space Name in a space's menu takes
    /// every space's off (Preferences.spaceNames), and with them the
    /// folding under the name.
    var namesSpaces: Bool { blank || spacesShown && prefs.spaceNames }

    /// The foot's row of spaces: with spaces on, one space alone too, as
    /// Arc's (feedback #270); with them off, Mail's and the first's while
    /// Mail is in the order.
    /// None in a Blank Window: it stays in its space, as Arc's has no
    /// spaces at its foot.
    var footShowsSpaces: Bool { windowPurpose == .normal && !blank && (prefs.usesSpaces || turnOrder.count > 1) }

    /// New Tab's row wears the live tab's plate, and the tab under the
    /// field none, while the field asks for the tab that row makes: ⌘T's,
    /// the plus's or the row's own, or the field standing up by itself with
    /// no tab in front. As Arc does it, from one frame to the next; ⌘L,
    /// ⌘N and Split View leave the plate where it is.
    var newTabLit: Bool { !inMail && !spaceVisiting && ((editing && asked == .tab) || active == nil) }

    /// The grid stays where it is while the space changes: the pins every
    /// space shares, on screen in the space it is going from and the one
    /// it is going to (two fingers' while they hold, the last switch's
    /// after).
    func pinsHold(_ pull: SpacePull) -> Bool {
        guard showsShared(spaceID) else { return false }
        if let to = pull.to, pull.from?.id == spaceID { return showsShared(to.id) }
        return pinsStayed
    }
}

/// A pinned tab as a cell in the block at the top of the column, as wide as
/// its row asks for, but never taller than the classic square, so a row with
/// room to spare turns into a wide, short button rather than a bigger icon.
struct PinSquare: View {
    /// Not watched, as a row isn't (SideRow): what of the browser and the
    /// preferences the pin shows comes in as values below, handed over again
    /// by the column, which watches them, whenever they change. Watched,
    /// every pin was drawn again on anything either said: a tab picked, a
    /// page loading, ⌘S, a space's color worn, and under a switch's slide
    /// every pin of the space's page too.
    let browser: Browser
    /// Marks or letters (Settings › Appearance › Tab icons).
    let glyph: Glyph
    /// Out over the page in full screen rather than beside it: a card with
    /// its own corners and no hairline down its side.
    var floating = false
    @ObservedObject var tab: Tab
    let live: Bool
    var width: CGFloat = SideBar.square
    var height: CGFloat = SideBar.square
    /// In the hand: a ground of its own under the gray, the column's color,
    /// so the squares it passes over don't show through it.
    var lifted = false
    /// Under a pressed button: down a little, as every button goes.
    var pressed = false
    /// Its letter being written in (`Browser.editingPin`).
    let editing: Bool
    /// One of several picked with the open tab (`Browser.isPicked`).
    let picked: Bool
    /// The other half when this square is a pinned pair (PinPairs.swift):
    /// both marks, a hairline between them.
    let mate: Tab?

    init(browser: Browser, prefs: Preferences, floating: Bool = false, tab: Tab, live: Bool,
         width: CGFloat = SideBar.square, height: CGFloat = SideBar.square, lifted: Bool = false, pressed: Bool = false) {
        self.browser = browser
        glyph = prefs.glyph
        self.floating = floating
        self.tab = tab
        self.live = live
        self.width = width
        self.height = height
        self.lifted = lifted
        self.pressed = pressed
        editing = browser.editingPin == tab.id
        picked = browser.isPicked(tab)
        mate = browser.pinMate(of: tab)
    }

    @Environment(\.tone) private var tone
    /// The column's light or dark, the tone's own when it wears one.
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// In a cell of the AppKit column: where it stands is the page's to say.
    @Environment(\.columnHosted) private var hosted
    @State private var hovering = false
    /// A pinned pair just made grows in at the grid's end, as Dia's does,
    /// without its blur (PinPairs.swift).
    @State private var grown = true

    /// Everything drawn inside scales off the shorter edge, the one that
    /// stays put, so the glyph sits at its usual size, centered, rather than
    /// stretching to chase the width: 16 points from a 34-point pin up, as
    /// Arc's at 45, smaller only in a narrower cell.
    private var scale: CGFloat { min(width, height) }

    var body: some View {
        let _ = SpacePager.touched()
        let markSide = min(16, scale * 16 / 34)
        Group {
            if let mate, !editing {
                PinPairMarks(first: tab, second: mate, glyph: glyph, size: markSide, room: width)
            } else if editing {
                PinField(browser: browser, tab: tab)
            } else {
                TabMark(tab: tab, sky: browser.keySky, size: min(16, scale * 16 / 34), tint: live ? Palette.ink : Palette.muted(on: tone),
                        unpark: { [browser, tab] in browser.unparkOffer(tab) }, room: (width - min(16, scale * 16 / 34)) / 2,
                        lettered: !((glyph == .icons || tab.customMark != nil) && tab.displayIcon != nil)) {
                    PinNumber(browser: browser, tab: tab, size: min(12, scale * 12 / 34), tint: live ? Palette.ink : Palette.muted(on: tone)) {
                        if glyph == .icons || tab.customMark != nil, let icon = tab.displayIcon {
                            Mark(icon: icon, letter: tab.pin ?? "", size: min(16, scale * 16 / 34))
                        } else {
                            Text(tab.pin ?? "")
                                .font(.system(size: min(12, scale * 12 / 34), weight: .medium))
                                .foregroundStyle(live ? Palette.ink : Palette.muted(on: tone))
                        }
                    }
                    // The mark's square whatever is in it, a letter's too:
                    // the call's dot and its cut sit on this square's corner,
                    // not on the corner of a letter's own narrow box.
                    .frame(width: min(16, scale * 16 / 34), height: min(16, scale * 16 / 34))
                }
            }
        }
        .frame(width: mate == nil || editing ? markSide : width, height: markSide)
        .frame(width: width, height: height)
        // A pinned calendar's next meeting: the pin says it at its mark's
        // corner, and is the button while it joins (PinMeeting).
        .modifier(PinMeeting(browser: browser, tab: tab, calls: browser.calls, radius: SideBar.corner(scale)))
        .background {
            // A picked pin gets the open one's ground, as a picked row
            // gets the open row's, and both wear the open tab's selection.
            if live || picked {
                SelectionPlate(corner: SideBar.corner(scale), state: .selected, prefs: browser.prefs)
            } else {
                RoundedRectangle(cornerRadius: SideBar.corner(scale), style: .continuous)
                    .fill(Palette.pin(on: tone, dark: scheme == .dark, hovering: hovering))
            }
        }
        .background {
            if lifted {
                GroundFill(shape: RoundedRectangle(cornerRadius: SideBar.corner(scale), style: .continuous), browser: browser)
            }
        }
        .scaleEffect(pressed && !reduceMotion ? ButtonSize.large.pressed : 1)
        .animation(pressed ? Press.down : Press.up, value: pressed)
        .scaleEffect(grown ? 1 : 0.55)
        .opacity(grown ? 1 : 0)
        .onAppear {
            guard mate != nil, browser.pinGrowing == tab.id, !reduceMotion else { return }
            browser.pinGrowing = nil
            grown = false
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78).delay(0.12)) { grown = true }
        }
        .contentShape(RoundedRectangle(cornerRadius: SideBar.corner(scale), style: .continuous))
        // Where the pin stands, for its card to hang from. Only while it is
        // one: a pin let go of is a row already, and this square, on its way
        // out, would otherwise have the last word on where the tab is.
        .globalFrame(!hosted) { [id = tab.id, sky = browser.keySky, tab, hosted] in
            if tab.pin != nil, !hosted { sky.lay(id, $0) }
        }
        .onTapGesture { browser.tapTab(tab) }
        .onHover { hovering = $0; browser.glance.hover(tab.id, $0) }
        // On a space's page sliding in, lit if it will be under the pointer.
        .modifier(SlidePointed(hovering: $hovering))
        .onChange(of: lifted) { _, held in if held { browser.glance.drop() } }
        .steadyMenu(actions: true) { TabMenu(browser: browser, tab: tab, close: { browser.shut(tab) }) }
        .iconPicker(tab, in: browser)
        .splitMateIconPicker(mate, in: browser)
        // Picked or not is a state, not a journey: whatever else is moving
        // when it changes, the gray lands at once.
        .animation(nil, value: live)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// A pinned pair's square inside (PinPairs.swift): both halves' marks, a
/// hairline between them, the half put down by its cross dimmed until the
/// square is clicked again. The concept's variant A, drawn as picked.
struct PinPairMarks: View {
    @ObservedObject var first: Tab
    @ObservedObject var second: Tab
    let glyph: Glyph
    let size: CGFloat
    /// The cell's full width: each mark is centered in its own half.
    /// Narrow cells also shrink the marks to keep them inside.
    var room: CGFloat = .infinity
    @Environment(\.tone) private var tone

    /// The marks' side, the gap each side of the line and the whole width,
    /// in a square this wide: the concept's, or as much of it as fits with
    /// the square's own inset each side.
    static func fit(_ side: CGFloat, in room: CGFloat) -> (side: CGFloat, gap: CGFloat, width: CGFloat) {
        let inside = room - 2 * Self.inset
        if width(side) <= inside { return (side, gap, width(side)) }
        let gap: CGFloat = 4
        let fitted = max(8, min(side, (inside - 2 * gap - 1) / 2))
        return (fitted, gap, 2 * fitted + 2 * gap + 1)
    }
    /// What a square keeps clear each side of the marks.
    static let inset: CGFloat = 6

    /// The gap each side of the hairline.
    static let gap: CGFloat = 7 // design: the concept's gap each side of the hairline, so two 16-pt marks and the line sit in a 45-pt square
    static func width(_ side: CGFloat) -> CGFloat { 2 * side + 2 * gap + 1 }

    var body: some View {
        let fit = Self.fit(size, in: room)
        HStack(spacing: 0) {
            mark(first, fit.side)
                .frame(maxWidth: .infinity)
            mark(second, fit.side)
                .frame(maxWidth: .infinity)
        }
        .frame(width: room.isFinite ? room : fit.width)
        .overlay {
            Rectangle()
                .fill(Palette.ink.opacity(0.16)) // design: the hairline between a pinned pair's marks, as drawn in the concept
                .frame(width: 1, height: size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(first.rowLabel) and \(second.rowLabel)")
    }

    private func mark(_ tab: Tab, _ side: CGFloat) -> some View {
        Mark(icon: (glyph == .icons || tab.customMark != nil) ? tab.displayIcon : nil, letter: tab.monogram, size: side)
            .opacity(tab.pairRest ? 0.32 : 1)
            .saturation(tab.pairRest ? 0 : 1)
            .animation(.easeOut(duration: 0.18), value: tab.pairRest)
    }
}

/// Two tabs side by side down the column: one row, each tab a chip in it,
/// its mark and as much of its title as fits. On screen, the row wears the
/// live tab's gray, and both halves are chips lifted off it; at rest,
/// only the hairline between the halves remains. A click on a chip is a
/// click on that tab: the pair comes up with that half in front, or, the
/// pair already up, that half comes to the front.
struct PairRow: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var first: Tab
    @ObservedObject var second: Tab
    var lifted = false
    /// On screen or not, said by whoever draws it: a space not on screen
    /// yet (PagedSpace) has no stage of its own to ask.
    var shown: Bool? = nil
    @State private var hoverState = RowLocalState(false)
    /// The column's word in the AppKit column (SideRow's `columnPointed`).
    @Environment(\.columnPointed) private var columnPointed
    private var hovering: Bool {
        get { columnPointed ?? hoverState[first.id] }
        nonmutating set { hoverState[first.id] = newValue }
    }
    @Environment(\.tone) private var tone

    /// Arc's 28-point chips in a 36-point row; Compact keeps the same inset
    /// proportion. Shared with the AppKit column's reported chip frames.
    static var inset: CGFloat { Density.current == .compact ? 3 : 4 }
    static var chipHeight: CGFloat { SideBar.row - 2 * inset }

    var body: some View {
        let on = shown ?? (browser.stagePair?.contains(first.id) == true)
        let pointed = hovering && !lifted
        GeometryReader { geo in
            let half = max(0, (geo.size.width - 2 * Self.inset - SideBar.gap) / 2)
            let end = pointed ? RowPlate.column.side + SideBar.gap : 0
            HStack(spacing: SideBar.gap) {
                // The first half stays put when the group button comes in;
                // only the second gives it room, as in the Arc reference.
                PairChip(browser: browser, prefs: prefs, tab: first, on: on)
                    .frame(width: half)
                PairChip(browser: browser, prefs: prefs, tab: second, on: on)
                    .frame(width: max(0, half - end))
                if pointed {
                    TabEnd(browser: browser, tab: first, live: on, hovering: true, editing: false,
                           tint: Palette.ink, speaker: false, close: { browser.shut([first, second]) },
                           unkeep: first.kept && second.kept ? { browser.discard([first, second], rekept: true) } : nil,
                           reach: SideBar.row, plate: .column, slotSide: 15)
                        .frame(width: RowPlate.column.side, height: Self.chipHeight)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(first.kept && !first.putDown ? "Put Down Split View" : "Close Split View")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction {
                            browser.glance.drop()
                            if first.kept && second.kept && first.putDown && second.putDown {
                                browser.discard([first, second], rekept: true)
                            } else {
                                browser.shut([first, second])
                            }
                        }
                }
            }
            .padding(Self.inset)
            .overlay {
                if !on {
                    Rectangle().fill(Palette.ink.opacity(0.18))
                        .frame(width: 1, height: 16)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: SideBar.row)
        .frame(maxWidth: .infinity)
        .background {
            if lifted {
                GroundFill(shape: RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous), browser: browser)
            }
        }
        .background {
            if on {
                SelectionPlate(corner: SideBar.radius, state: .selected, prefs: prefs)
            } else if pointed {
                SelectionPlate(corner: SideBar.radius, state: .hover, prefs: prefs)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
        .modifier(RowHover(on: columnPointed == nil) { hovering = $0 })
        .onChange(of: lifted) { _, held in if held { hovering = false; browser.glance.drop() } }
        // Between and round the chips too: the menu of the half pressed in,
        // the tab's own with the split's lines (TabMenu).
        .steadyMenu(actions: true, halves: { [browser, first, second] left in
            TabMenu(browser: browser, tab: left ? first : second, close: { browser.shut(left ? first : second) })
        })
        .transition(.asymmetric(insertion: .identity, removal: .opacity.combined(with: .scale(scale: 0.96))))
    }
}

/// One tab of a pair, in its row down the column.
private struct PairChip: View {
    let browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    /// Concentric with the pair row's outer curve.
    static var corner: CGFloat { SideBar.radius - PairRow.inset }
    /// The pair is on screen.
    let on: Bool

    @State private var hovering = false
    @Environment(\.tabTitleSize) private var titleSize
    @Environment(\.tone) private var tone
    @Environment(\.colorScheme) private var scheme
    @Environment(\.columnHosted) private var hosted

    var body: some View {
        HStack(spacing: 6) {
            if tab.isBlank {
                Symbol("globe", size: 10)
                    .foregroundStyle(color)
                    .frame(width: 14, height: 14)
            } else {
                // Through TabMark, as a row's mark is: a call in a pair wears
                // its dot too.
                TabMark(tab: tab, sky: browser.keySky, size: 14, tint: color,
                        unpark: { [browser, tab] in browser.unparkOffer(tab) }, dotInset: 1) {
                    PinNumber(browser: browser, tab: tab, size: 11, tint: color) {
                        Mark(icon: (prefs.glyph == .icons || tab.customMark != nil) ? tab.displayIcon : nil, letter: tab.monogram, size: 14, dim: tab.asleep)
                    }
                    .frame(width: 14, height: 14)
                }
            }
            if browser.editingTab == tab.id {
                TabAddressField(browser: browser, tab: tab.id).frame(height: titleSize + 4)
            } else {
                Text(tab.rowLabel)
                    .font(.system(size: titleSize))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: PairRow.chipHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .fill(on ? chip : .clear)
                // How far down the page in front is, on its own chip, as a
                // lone tab's row shows it.
                .overlay {
                    if on, browser.activeID == tab.id, tab.reading > 0 {
                        ReadingFill(progress: tab.reading, outline: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
                            .fill(Palette.ink.opacity(0.055))
                            .animation(.easeOut(duration: 0.15), value: tab.reading)
                    }
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .onTapGesture {
            browser.glance.drop()
            browser.select(tab)
        }
        // Each half remains individually selectable and closable through
        // VoiceOver and its menu; the visible end button acts on the group.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(on && browser.activeID == tab.id ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { browser.select(tab) }
        .accessibilityAction(named: "Close") { browser.shut(tab) }
        .onHover { on in
            hovering = on
            browser.glance.hover(tab.id, on)
            // Which half is this chip's: outlined faintly while the pointer
            // is on it, and only when it isn't the one in front.
            if self.on { browser.splitHint.hint(tab.id, on && browser.activeID != tab.id) }
        }
        // The one to go back to the list, while the pointer is on its
        // half's cross.
        .overlay { LeaveMark(hint: browser.splitHint, id: tab.id) }
        .steadyMenu(actions: true) { TabMenu(browser: browser, tab: tab, close: { browser.shut(tab) }) }
        .iconPicker(tab, in: browser)
        .pointerTip(tab.label)
        // Where the tab stands, for a page's question to hang from.
        .globalFrame(!hosted) { [id = tab.id, sky = browser.keySky, hosted] in
            if !hosted { sky.lay(id, $0) }
        }
        .animation(nil, value: on)
    }

    /// Arc's gray chips on the light selection, lighter on a dark one.
    private var chip: Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.07)
    }

    private var color: Color {
        if on || hovering { return Palette.ink }
        return Palette.strong(on: tone).opacity(0.88)
    }
}

/// One tab, as a line in the column.
/// A row a held tab stays over, turning into the folder the two would
/// make: its mark goes into a folder's corner as the folder's mark grows
/// out from under it, and once made the row reads as that folder's own
/// row (NestRow), "New Folder" and the two it would hold.
struct FolderToBe: View {
    @ObservedObject var tab: Tab
    /// How far it has turned, 0 to 1.
    let turn: CGFloat
    let made: Bool
    /// The tab on screen: its row's own ground, under the turn.
    let live: Bool
    /// For the frost under its ground (SelectionPlate).
    var prefs: Preferences? = nil
    @Environment(\.tabTitleSize) private var titleSize
    @Environment(\.tone) private var tone

    var body: some View {
        HStack(spacing: SideBar.markGap) {
            // The plain folder's mark at once, as NestRow draws the open
            // folder it becomes: no site's mark tucked into its corner, which
            // read as an agent's folder (alpha 2026-10-13).
            Face(pose: .seen, size: SideBar.folder, tint: Palette.strong(on: tone), folder: true, unfolded: true, weight: SideBar.folderWeight)
                .frame(width: SideBar.mark, height: SideBar.mark)
            ZStack(alignment: .leading) {
                Text(tab.rowLabel)
                    .font(.system(size: titleSize))
                    .foregroundStyle(live ? Palette.ink : Palette.muted(on: tone))
                    .opacity(made ? 0 : 1)
                    .offset(y: made ? -6 : 0)
                Text("New Folder")
                    .font(.system(size: titleSize, weight: .medium))
                    .foregroundStyle(Palette.strong(on: tone))
                    .opacity(made ? 1 : 0)
                    .offset(y: made ? 0 : 6)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, SideBar.inner)
        .padding(.trailing, SideBar.endInset)
        .frame(height: SideBar.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The words slide in and out within the row; its ground's lift
        // shows past it.
        .clipped()
        .background {
            // In the row's place, its own words and mark redrawn, on the
            // selection of the folder to be (NestRow, aimed), coming in as
            // it turns. The open tab's is the same one, so from it the
            // ground stays whole, lift and sheen from the first frame.
            SelectionPlate(corner: SideBar.radius, state: .selected, prefs: prefs)
                .opacity(live ? 1 : Double(turn))
        }
        .allowsHitTesting(false)
    }
}

struct SideRow: View {
    /// The close control can keep the pointer when the row loses its hover.
    struct Hover {
        var row = false
        var close = false
        var inside: Bool { row || close }
    }

    /// Not watched: a row that watched the browser was drawn again, every
    /// row of the column, on anything the browser said, a switch of tab
    /// among them. What of it the row shows comes in as values below, so
    /// only the rows whose values change are drawn again.
    let browser: Browser
    /// Marks or counts (Settings › Appearance › Tab icons): the one thing of
    /// the preferences the row draws by. A value, not the preferences
    /// watched: every row was drawn again at any change of any of them,
    /// ⌘S putting the column away, ⇧⌘S, ⇧⌘B, a space's color worn.
    let glyph: Glyph
    /// Out over the page in full screen rather than beside it: a card with
    /// its own corners and no hairline down its side.
    var floating = false
    @ObservedObject var tab: Tab
    let live: Bool
    /// One of several picked with the open tab (see `Browser.gathered`).
    var picked = false
    /// Its title being written in (`Browser.editingTab`).
    var editing = false
    /// One of two tabs side by side: the row is drawn as one with its other
    /// half's, one over the other (see `JointGround`).
    var joint: Joint?
    /// Its pair is the one on screen (`Browser.stagePair`).
    var staged = false
    /// A name refused while it is being written: the row shakes at each.
    var refusals = 0
    /// Closed from its end or its menu; a row only drawn for a moment, the
    /// next space's under a swipe, closes nothing.
    var closes = true

    @Environment(\.tabTitleSize) private var titleSize
    @Environment(\.tone) private var tone
    /// In a cell of the AppKit column: where it stands is the page's to say.
    @Environment(\.columnHosted) private var hosted
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var hoverState = RowLocalState(Hover())
    @State private var shakeState = RowLocalState<CGFloat>(0)
    private var hover: Hover {
        get { hoverState[tab.id] }
        nonmutating set { hoverState[tab.id] = newValue }
    }
    private var shake: CGFloat {
        get { shakeState[tab.id] }
        nonmutating set { shakeState[tab.id] = newValue }
    }

    /// In the AppKit column the column says whether the pointer is on the
    /// row, from where both are (ColumnPage.point), so a row that slides
    /// or scrolls under a still pointer lights, and one that leaves it goes
    /// dark (register 1239). `hover.row` there is only a space's page
    /// sliding in under the pointer (SlidePointed).
    @Environment(\.columnPointed) private var columnPointed
    private var hovering: Bool { columnPointed.map { $0 || hover.row } ?? hover.inside }

    /// In the hand: it gets a ground of its own, the column's color, so it
    /// covers the rows it passes over instead of its title running into
    /// theirs.
    var lifted = false

    init(browser: Browser, prefs: Preferences, floating: Bool = false, tab: Tab, live: Bool, picked: Bool = false, lifted: Bool = false, closes: Bool = true) {
        self.browser = browser
        glyph = prefs.glyph
        self.floating = floating
        self.tab = tab
        self.live = live
        self.picked = picked
        self.lifted = lifted
        self.closes = closes
        editing = browser.editingTab == tab.id
        joint = browser.joint(of: tab.id)
        staged = browser.stagePair?.contains(tab.id) == true
        refusals = editing ? browser.refusals : 0
    }

    private func close() {
        if closes { browser.shut(tab) }
    }

    private func point(_ on: Bool, atClose: Bool) {
        // The same word again (a disappear after a leave): nothing to write.
        if (atClose ? hover.close : hover.row) == on { return }
        let was = hovering
        if atClose { hover.close = on } else { hover.row = on }
        if hovering != was { browser.glance.hover(tab.id, hovering) }
    }

    private var sounding: Bool { tab.noisy || tab.muted }

    /// An agent waiting on you here: the row itself asks, not only its face.
    private var calling: Bool { tab.handoff != nil && tab.worker != nil }

    /// Kept, and gone on from the page it was kept at (PinnedHome.swift).
    private var away: Bool { !editing && tab.awayFromHome }

    var body: some View {
        let _ = SwitchMeter.countRow()
        let _ = SwitchMeter.note("body \(closes ? "column" : "pager") \(tab.label.prefix(10))\(live ? " live" : "")")
        let _ = ColumnKit.rowBodies += 1
        let _ = SpacePager.touched(pager: !closes)
        HStack(spacing: SideBar.markGap) {
            if editing {
                TabAddressField(browser: browser, tab: tab.id)
                    .frame(height: titleSize + 4)
            } else {
                HStack(spacing: 0) {
                    if glyph == .icons || tab.instantState != nil {
                        keyed {
                            if tab.isBlank {
                                // Nowhere yet, so no site's mark, but still something
                                // in the mark's place, so a new tab's title lines up
                                // with every other one's.
                                // A private one's is the mask, in the globe's place.
                                Symbol(tab.shy ? "incognito" : "globe", size: 11)
                                    .foregroundStyle(color)
                                    .frame(width: SideBar.mark, height: SideBar.mark)
                            } else {
                                // Its number while ⌘ is held, as a pin's (KeyNumbers).
                                PinNumber(browser: browser, tab: tab, size: SideBar.mark * 12 / 16, tint: color) {
                                    Mark(icon: tab.displayIcon, letter: tab.monogram, size: SideBar.mark)
                                }
                                .frame(width: SideBar.mark, height: SideBar.mark)
                            }
                        }
                    } else if tab.offer?.parked == true || (tab.asks.first?.parked == true && !tab.wantsScreen) || tab.handoff != nil || tab.camera != .none || tab.microphone != .none {
                        keyed { EmptyView() }
                    } else {
                        LooseCount(tab: tab)
                    }
                    // A stable slot collapses with the title. The glyph is
                    // revealed through its left edge, as in the reference,
                    // rather than fading at full width over moving text.
                    SideSpeaker(tab: tab)
                        .frame(width: SideSpeaker.room, alignment: .trailing)
                        .offset(x: SideSpeaker.fit.shift)
                        .opacity(sounding ? 1 : 0)
                        .scaleEffect(x: sounding ? 1 : 0, y: 1, anchor: .leading)
                        .frame(width: sounding ? SideSpeaker.room : 0, alignment: .leading)
                        .clipped()
                        .allowsHitTesting(sounding)
                        .accessibilityHidden(!sounding)
                }
                // Six points to the title: with the glyph's own bearing,
                // the reference has eight visible points after the mark.
                .padding(.trailing, SideSpeaker.fit.title - SideBar.markGap)
                // Among tabs that keep everything; a private window's are
                // all private, said once at its foot.
                if tab.shy, browser.windowPurpose == .normal, !(glyph == .icons && tab.isBlank) {
                    Symbol("incognito", size: 9)
                        .foregroundStyle(color.opacity(0.7))
                }
                // Gone on from where it was kept: a slash, then the page
                // it is on, as Arc's pinned tab says it (PinnedHome.swift).
                if away {
                    HomeSlash(tab: tab, size: titleSize, tint: Palette.faint(on: tone))
                        .padding(.horizontal, -2) // design: 6 either side of the slash, as across the top
                }
                // The title runs to the row's edge and out into nothing
                // there; the fade moves in only while the slot at the end
                // has something in it.
                FadingTitle(text: away ? tab.awayLabel : tab.rowLabel, font: .system(size: titleSize, weight: calling ? .medium : .regular), rest: look(hot: false, slotted: false), busy: look(hot: false, slotted: true), open: look(hot: true, slotted: true), slotted: busy, opened: hovering)
                    // Only when what it paints changes: a Canvas can't tell
                    // otherwise, and would repaint with every redraw of the tab,
                    // the reading gray's included.
                    .equatable()
                    // Its short name just given: in behind the old one's dust.
                    .modifier(RenameReveal(since: away ? nil : tab.tidiedAt, tint: Rename.tint(tone)))
                // No sharing words or Stop on the column's rows (owner,
                // 0.46.10): the favicon's red dot and the speaker say a call
                // is on; the band, the strip and the tag say a share.
                // A share asked for while behind, waiting here (ShareWaiting.swift).
                ShareWaiting(tab: tab)
                // What a live folder's tab needs (LiveViews.swift).
                LiveWordsView(tab: tab, clearance: showsDevPort ? 0 : TabEnd.clear(tab, hovering: hovering, slotted: busy || hovering,
                                                              speaker: false, unkeeps: closes, pitch: TabEnd.beside))
                // A page watched for the user (PageWatches.swift).
                WatchWords(tab: tab)
                // A page on this Mac's own server: which port (DevMode.swift).
                if showsDevPort {
                    DevPort(tab: tab, hovering: hovering, gap: 8, speaker: false, unkeeps: closes)
                }
            }
        }
        .animation(still ? nil : SideSpeaker.reveal, value: sounding)
        .padding(.leading, SideBar.inner)
        .padding(.trailing, editing ? SideBar.inner : SideBar.endInset)
        .frame(height: SideBar.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Gone on from where it was kept: the mark is the way back, in a
        // square at the row's start, as Arc's favicon is (PinnedHome.swift).
        .modifier(HomeMark(browser: browser, tab: tab, away: away && glyph == .icons && !editing, plate: .column))
        .overlay(alignment: .trailing) {
            TabEnd(browser: browser, tab: tab, live: live, hovering: hovering, editing: editing, tint: color, speaker: false, close: close,
                   unkeep: closes ? { [browser, tab] in browser.discard([tab], rekept: true) } : nil, reach: SideBar.row, plate: .column, pitch: TabEnd.beside, slotSide: 15,
                   closeHover: { if columnPointed == nil { point($0, atClose: true) } })
                .padding(.trailing, SideBar.endInset)
        }
        .background { ground }
        // The open tab of a page on this Mac's own server (DevMode.swift).
        .overlay { if live && tab.isDev { DevTape() } }
        // Where the tab stands, for a page's question to hang from. Not once
        // it is pinned: the row goes out after the pin is in, and its last
        // frames would put the tab where the row was.
        .globalFrame(!hosted) { [id = tab.id, sky = browser.keySky, tab, hosted] in
            if tab.pin == nil, !hosted { sky.lay(id, $0) }
        }
        .background {
            if lifted {
                GroundFill(shape: RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous), browser: browser)
            }
        }
        .modifier(Shake(travel: shake))
        .contentShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
        .onTapGesture { browser.tapTab(tab) }
        // Recycled for another tab: its hover and shake read as new already
        // (RowLocalState), so nothing is written and the row draws once; only
        // the glance hears the last tab is no longer under the pointer.
        .onChange(of: tab.id) { old, _ in
            if columnPointed == nil, hoverState[old].inside { browser.glance.hover(old, false) }
        }
        .modifier(RowHover(on: columnPointed == nil) { point($0, atClose: false) })
        // On a space's page sliding in, lit if it will be under the pointer.
        .modifier(SlidePointed(hovering: Binding(get: { hover.row }, set: { hover.row = $0 })))
        // Scrolled away: cheap for a row the pointer isn't on (`TabGlance.concerns`).
        .onDisappear {
            if hover.inside { hover = Hover() }
            if columnPointed == nil { browser.glance.hover(tab.id, false) }
        }
        .onChange(of: lifted) { _, held in if held { browser.glance.drop() } }
        .steadyMenu(actions: true) { TabMenu(browser: browser, tab: tab, close: close) }
        // From the mark's square, the row's own picture.
        .iconPicker(tab, in: browser, at: CGRect(x: SideBar.inner, y: 0, width: SideBar.mark, height: SideBar.row))
        .animation(Motion.glide, value: editing)
        .onChange(of: refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        .animation(nil, value: live)
        .animation(nil, value: picked)
        // For the bench: rows made by a change of space.
        .onAppear { if SwitchMeter.on { SwitchMeter.made += 1; if !closes { SwitchMeter.pagerMade += 1 } } }
        // An arrival takes its place whole, it is the button's own spot,
        // and the button steps aside for it. A leaving fades and gives a
        // little, over less time than the room it leaves takes to close.
        .transition(.asymmetric(insertion: .identity, removal: .opacity.combined(with: .scale(scale: 0.96))))
    }

    @ViewBuilder
    private var ground: some View {
        if let joint {
            JointGround(
                joint: joint, lit: live || staged, hovering: hovering || calling,
                reading: live && !editing ? tab.reading : 0, gap: SideBar.gap, across: false,
                prefs: browser.prefs
            )
        } else if live {
            ZStack(alignment: .leading) {
                SelectionPlate(corner: SideBar.radius, state: .selected, prefs: browser.prefs)
                GeometryReader { geo in
                    Rectangle()
                        .fill(Palette.ink.opacity(0.055))
                        .frame(width: geo.size.width * tab.reading)
                        .animation(.easeOut(duration: 0.15), value: tab.reading)
                }
                .clipShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
            }
        } else if picked {
            // The open one's gray, lighter, each row its own, side by side
            // or not, so every one of them reads as a tab you picked.
            SelectionPlate(corner: SideBar.radius, state: .picked, prefs: browser.prefs)
        } else if hovering || calling {
            SelectionPlate(corner: SideBar.radius, state: .hover)
        }
    }

    private var color: Color { ink(hot: hovering) }

    private func ink(hot: Bool) -> Color {
        if live || picked || calling { return Palette.ink }
        return hot ? Palette.strong(on: tone).opacity(0.88) : Palette.muted(on: tone)
    }

    /// The name at rest, at rest with the slot at the end taken, and under
    /// the pointer: all painted, the tab only shows one or another (see
    /// `FadingTitle`).
    private func look(hot: Bool, slotted: Bool) -> FadingTitle.Look {
        // A routine's folder's page that has gone: struck, faint, until its next run.
        let gone = tab.live?.said?.gone == true
        return FadingTitle.Look(color: gone ? Palette.faint(on: tone) : ink(hot: hot), clear: showsDevPort || LiveWordsView.hasWords(tab) ? 0 : TabEnd.clear(tab, hovering: hot, slotted: slotted, speaker: false, unkeeps: closes, pitch: TabEnd.beside),
                                fade: slotted ? 28 : 40, strike: gone)
    }

    /// The end-of-call clock needs the space more than the port does.
    private var showsDevPort: Bool { tab.devPort != nil && !tab.onCall }

    /// Something in the slot at the tab's end, with the pointer away.
    private var busy: Bool { tab.spinning || tab.wearsFace }

    /// The tab's mark, or the key of a password waiting on it.
    private func keyed(@ViewBuilder _ mark: @escaping () -> some View) -> some View {
        // SideBar.markGap to the title, one point kept clear of a wide count.
        TabMark(tab: tab, sky: browser.keySky, size: SideBar.mark, tint: color, unpark: { [browser, tab] in browser.unparkOffer(tab) },
                room: SideBar.markGap - 1, worded: true, mark: mark)
    }
}

/// The speaker beside a playing or muted tab's mark in the column, as Arc
/// has it: what the tab is doing, and a click mutes it or lets it be
/// heard. Still while it plays; only a change moves it. Going quiet, the
/// waves fade into the slashed speaker seen in the supplied reference;
/// sound back, the waves return one after the other, the near one first.
struct SideSpeaker: View {
    @ObservedObject var tab: Tab

    @State private var hovering = false
    @Environment(\.tone) private var tone
    @Environment(\.accessibilityReduceMotion) private var still

    /// Measured from the supplied Arc recording at 2x: a 24-point
    /// plate, a 16-point filled mark and 31 points of title displacement.
    /// Compact keeps the same relationship with its smaller row.
    static var side: CGFloat { RowPlate.column.side }
    /// The optical fit to the same recording, in one place: the glyph's
    /// own bearing tucked into the gap after the mark (`tuck`), the slot
    /// carried a point back toward it (`shift`), and the room from the
    /// marks to the title (`title`), with the bearing making it Arc's eight.
    static let fit = (tuck: CGFloat(3), shift: CGFloat(-1), title: CGFloat(6))
    static var room: CGFloat { side + SideBar.markGap - fit.tuck }
    static let reveal = Animation.timingCurve(0.42, 0, 0.58, 1, duration: 0.17)
    private static var glyph: CGFloat { SideBar.mark / Glyphs.scale }
    /// Where the cross stands in the glyph's 24-point square (19.25, 11.75
    /// in speaker.xmark), so it grows in where it is, not from the middle.
    private static let cross = UnitPoint(x: 19.25 / 24, y: 11.75 / 24)

    var body: some View {
        if AudioWatch.canMute {
            Button { tab.mute(!tab.muted) } label: { mark }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { hovering = $0 }
                .onChange(of: tab.noisy || tab.muted) { _, on in if !on { hovering = false } }
                .keyTip(tab.muted ? "Unmute Tab" : "Mute Tab", shortcut: "Mute Tab")
                .accessibilityLabel(tab.muted ? "Unmute Tab" : "Mute Tab")
        } else {
            // Where WebKit can't be asked to silence it: only which tab
            // the noise is coming from.
            mark.allowsHitTesting(false)
        }
    }

    private var mark: some View {
        let muted = tab.muted
        // speaker.slash.fill in its parts: the body stays where it is, the
        // waves go out and only the cross comes in where they were.
        return ZStack {
            Symbol("speaker.body.fill", size: Self.glyph)
            Symbol("speaker.wave.inner.fill", size: Self.glyph)
                .opacity(muted ? 0 : 1)
                .animation(wave(after: 0.06), value: muted)
            Symbol("speaker.wave.outer.fill", size: Self.glyph)
                .opacity(muted ? 0 : 1)
                .animation(wave(after: 0.12), value: muted)
            Symbol("speaker.xmark", size: Self.glyph)
                .opacity(muted ? 1 : 0)
                .scaleEffect(muted ? 1 : 0.8, anchor: Self.cross)
                .animation(still ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.14), value: muted)
        }
        .foregroundStyle(hovering ? Palette.ink : Palette.muted(on: tone))
        .frame(width: Self.side, height: Self.side)
        // The hit target and its hover plate share the same 24-point square.
        .background { if hovering { RowPlate.column.square() } }
        .contentShape(Rectangle())
    }

    /// A wave going goes at once; coming back, it waits its turn.
    private func wave(after delay: Double) -> Animation? {
        if still { return nil }
        return tab.muted ? .easeOut(duration: 0.12) : .easeOut(duration: 0.12).delay(delay)
    }
}

/// A row that is an action rather than a page. Quiet until the pointer is on it.
struct Quiet: View {
    let icon: String
    let title: String
    var height: CGFloat = SideBar.row
    /// New Tab's: the dot for rows found while you were elsewhere.
    var news = false
    /// Lit as the live tab is (Browser.newTabLit).
    var lit = false
    /// For the frost under it lit (SelectionPlate).
    var prefs: Preferences? = nil
    /// The window it is in, for the site's color it wears (`ink`).
    var browser: Browser? = nil
    let act: () -> Void

    @Environment(\.tabTitleSize) private var titleSize
    @Environment(\.tone) private var tone
    @State private var hovering = false

    var body: some View {
        // Pressed, it lets go of the pointer at once: the new tab takes its
        // spot under the pointer and it slides away from under it, and the
        // system would only say so on the pointer's next move.
        Button(action: { hovering = false; act() }) {
            HStack(spacing: SideBar.markGap) {
                // A size under the header's doors, so the plus reads as
                // the row's mark, not a button of its own; centered on the
                // favicons under it. Drawn 15.5 across, Arc's plus to the
                // pixel: 11.5 pt end to end.
                Symbol(icon, size: 11, weight: .medium, side: 15.5)
                    .frame(width: SideBar.mark)
                    .overlay(alignment: .topTrailing) { if news { NewsDot() } }
                Text(title)
                    .font(.system(size: titleSize))
                Spacer(minLength: 0)
            }
            // Under the pointer only its ground, the words as quiet as at
            // rest, as Arc has it: lit, it is the live tab's. On a color a
            // step past faint, so it isn't a gray smudge (Palette.quiet).
            .foregroundStyle(lit ? Palette.ink : Self.ink(on: tone, browser: browser))
            .padding(.horizontal, 10)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if lit {
                    SelectionPlate(corner: SideBar.radius, state: .selected, prefs: prefs)
                } else if hovering {
                    SelectionPlate(corner: SideBar.radius, state: .hover)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        // Out of the key loop, as Door is.
        .focusable(false)
        .onHover { hovering = $0 }
        .animation(nil, value: lit)
        .accessibilityAddTraits(lit ? .isSelected : [])
    }

    /// Its words at rest. On a site's color the column's tone is a gray
    /// standing in for it (Tone.columnInk), on the dark side up to a step
    /// darker than the site: white let through as far as that gray needs
    /// was lost on the site's own lighter ground, a mid gray page under a
    /// cookie sheet's shade (request 1008: "text is missing"). So this row
    /// also works its words out from the site's color itself, read here
    /// alone as GroundFill reads it (a switch draws this row again, not the
    /// column), and takes whichever stands further off: on the light side
    /// the stand-in is the lighter, and the column's frost lighter still.
    @MainActor
    static func ink(on tone: Tone?, browser: Browser?) -> Color {
        let site = tone?.ink == true ? (browser ?? BrowserWindows.shared.activeBrowser)?.worn.color : nil
        return Palette.quiet(on: inkTone(tone, site: site))
    }

    /// The tone its words are worked out on: the site's own color under a
    /// stand-in gray of the same light or dark when that asks for words
    /// further off it, else the column's.
    static func inkTone(_ tone: Tone?, site: NSColor?) -> Tone? {
        guard let tone, tone.ink, let site else { return tone }
        let own = Tone(site, lifted: true)
        guard own.scheme == tone.scheme, !own.blank else { return tone }
        return Palette.shades(own).quietLift > Palette.shades(tone).quietLift ? own : tone
    }
}

/// A small square holding one symbol. Lit when what it opens is open.
struct Door: View {
    let icon: String
    var on = false
    var help = ""
    /// Its shortcut, by its menu item's title (Hotkeys), or keys written out:
    /// named in its tooltip as they are now.
    var shortcut: String?
    var keys: String?
    /// What the glyph does when the door is used, so the click is answered
    /// by the icon itself saying which way things went.
    var kick: Kick = .none
    /// Set when the door isn't the only way in, a shortcut does the same
    /// thing, and whoever counts it plays the kick instead of the click, so
    /// both look the same and neither plays it twice.
    var pulse: Int?
    /// Some frequently used controls stay still when pressed.
    var pressScale: CGFloat = 0.96
    /// Held, pressed and drawn down, or right-clicked: a list opens from
    /// it (DoorList), and the click it was is not one. Says whether there
    /// was anything to list.
    var hold: ((NSView) -> Bool)? = nil
    /// Clicked with ⌘ or the middle button (`Browser.beside`): what it
    /// leads to in a new tab instead, told whether that comes to the front.
    var beside: ((Bool) -> Void)? = nil
    /// The rest before its tip, when it is not a door pressed all day.
    var tipWait: TimeInterval = KeyTip.dwell
    /// Its glyph changes at once, with no fade: "⋯" turning into the cross
    /// as its menu opens, before the menu holds the run loop and with it
    /// every curve (HelmMore).
    var instant = false
    let act: () -> Void

    /// A door is this square; whatever else stands in a row of them, the
    /// update pill, is this tall.
    static let side: CGFloat = 26

    /// A door and its glyph. The column's header has larger ones, as Arc's
    /// are, set over its doors (DoorSize); every other row keeps these.
    struct Size {
        var side: CGFloat = Door.side
        var glyph: CGFloat = 11
        /// Back's and forward's arrows, and the column's mark, where they
        /// are drawn larger than the rest, as Arc draws its own (measured
        /// at 2x against Arc on 2026-10-21: its arrows 14.5 across, its
        /// mark 18.5); none keeps them at the glyph.
        var arrow: CGFloat? = nil
        var mark: CGFloat? = nil
        /// Reload's square, where it is drawn smaller than its glyph size
        /// would make it: the header's, a size under Arc's bold arrows.
        var reload: CGFloat? = nil
        /// One line weight for every glyph in the row, in points, whatever
        /// square each is drawn in; none keeps each icon's own 2 on its 24
        /// grid, which comes out heavier the larger the icon.
        var stroke: CGFloat? = nil
        /// The sidebar mark with Arc's rounder corners.
        var roundMark = false
        /// Between doors in a row of them (Helm).
        var gap: CGFloat = SideBar.gap
        /// Back, forward and reload with the two gaps between them.
        var helm: CGFloat { 3 * side + 2 * gap }
        /// Its corner: a control's, but in the column's header a row's, the
        /// address plate's under it, which reload stands flush with; it is
        /// also the 8 in from the card's 18 when the column comes out over
        /// the page.
        var corner: CGFloat = Radius.control
        /// The glyph for this door's symbol.
        func glyph(for icon: String) -> CGFloat {
            switch icon {
            case "arrow.left", "arrow.right": arrow ?? glyph
            case "sidebar.left", "sidebar.right": mark ?? glyph
            default: glyph
            }
        }
        /// The square this door's symbol is drawn in, where it isn't the
        /// one its glyph size gives.
        func side(for icon: String) -> CGFloat? {
            icon == "arrow.clockwise" ? reload : nil
        }
        /// The drawing this door shows for a symbol.
        func drawing(for icon: String) -> String {
            roundMark && (icon == "sidebar.left" || icon == "sidebar.right") ? icon + ".round" : icon
        }
        /// The door's symbol as this row draws it.
        func symbol(_ icon: String) -> Symbol {
            Symbol(drawing(for: icon), size: glyph(for: icon), weight: .medium, side: side(for: icon), stroke: stroke)
        }

        /// The column's header: a door nearly the plate's height under it,
        /// Arc's arrows and mark in it, Arc's 34 from one door's center to
        /// the next, every line 1.5 and reload a size smaller, the mark's
        /// corners round (the Oct 21 mockup). Compact takes two points off the
        /// door and the glyphs in step, Arc having no compact of its own.
        static var header: Size {
            Density.current == .compact
                ? Size(side: 28, glyph: 12, arrow: 13.5, mark: 15, reload: 16, stroke: 1.5, roundMark: true, gap: 4, corner: SideBar.radius)
                : Size(side: 30, glyph: 13, arrow: 14.5, mark: 16, reload: 18, stroke: 1.5, roundMark: true, gap: 4, corner: SideBar.radius)
        }
        /// The band over a page (AddressBar): the header's doors with more
        /// air between them, as Arc spaces its own.
        static let band = Size(side: 30, glyph: 13, arrow: 14.5, mark: 16, reload: 16.5, stroke: 1.5, roundMark: true, gap: 4)
        /// The header's doors in a column near its narrowest, where Arc
        /// draws its own closer together (ColumnHead.doors): the same
        /// glyphs on smaller doors, 28 from center to center.
        static var tight: Size {
            var size = header
            size.side = 26
            size.gap = 2
            return size
        }
    }

    /// Back leans left, forward leans right. Reload turns while pressed.
    /// A flash of direction, not a journey: a few
    /// points and gone, because these are pressed all day and the frequent
    /// path stays quiet.
    enum Kick {
        case none, left, right, turn
    }

    @State private var hovering = false
    /// Counts leans; each one plays again from the top.
    @State private var kicks = 0
    @Environment(\.tone) private var tone
    @Environment(\.accessibilityReduceMotion) private var still
    @Environment(\.doorSize) private var size
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button {
            // The press that opened a list is spent on it.
            if hold != nil, DoorHold.shared.spent() { return }
            if let beside, let front = Browser.beside(NSApp.currentEvent) { return beside(front) }
            if pulse == nil { play() }
            act()
        } label: {
            // Reload and stop shrink into each other (Unwind); pointer-down
            // turns the arrow in Give, and releasing it returns it to rest.
            ZStack {
                if kick == .turn {
                    Unwind(stop: icon == "xmark", size: size.glyph, ink: ink,
                           arrowSide: size.reload, stroke: size.stroke)
                } else {
                    size.symbol(icon)
                        .id(icon)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .animation(kick == .turn || instant ? nil : Motion.settle, value: icon)
            .keyframeAnimator(initialValue: CGFloat(0), trigger: kicks) { glyph, x in
                glyph.offset(x: x)
            } keyframes: { _ in
                CubicKeyframe(kick == .left ? -3.5 : 3.5, duration: 0.09)
                SpringKeyframe(0, duration: 0.34, spring: Spring(response: 0.3, dampingRatio: 0.6))
            }
            // Nowhere to go is drawn in a solid paler ink, not the door made
            // see-through: a glyph of two strokes, an arrow's shaft and
            // head, would show darker where they cross.
            .foregroundStyle(ink)
            .frame(width: size.side, height: size.side)
            .contentShape(RoundedRectangle(cornerRadius: size.corner, style: .continuous))
        }
        .buttonStyle(Give(reload: kick == .turn, stop: icon == "xmark", scale: pressScale))
        // Never the window's first key view: with keyboard navigation on,
        // the first door that isn't grayed, reload, on a fresh launch,
        // would open wearing a focus ring. Every door has a shortcut.
        .focusable(false)
        .background(
            RoundedRectangle(cornerRadius: size.corner, style: .continuous)
                .fill(on ? Palette.wash(on: tone) : (hovering ? Palette.hover(on: tone) : .clear))
        )
        .onHover { hovering = $0 }
        .background { if hold != nil || beside != nil { DoorHold.Anchor(open: hold, beside: beside, name: icon) } }
        .modifier(DoorTip(help: help, shortcut: shortcut, keys: keys, wait: tipWait))
        .onChange(of: pulse) { old, new in
            if let old, let new, new > old { play() }
        }
    }

    private var ink: Color {
        !enabled ? Palette.faint(on: tone) : on ? Palette.ink : (hovering ? Palette.ink.opacity(0.88) : Palette.muted(on: tone))
    }

    private func play() {
        guard !still else { return }
        switch kick {
        case .none:
            break
        case .left, .right:
            kicks += 1
        case .turn:
            // Reload answers pointer-down, rather than spinning on release.
            break
        }
    }

    /// The glyph sinks a little under the pointer the moment it goes down,
    /// before anything else happens, the press is answered at once, and
    /// the kick plays on release, when the click has actually been made.
    /// The doors' press, shared by the address bar's lock and link.
    struct Give: ButtonStyle {
        var reload = false
        var stop = false
        var scale: CGFloat = 0.96
        @Environment(\.accessibilityReduceMotion) private var still

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .environment(\.doorPressed, configuration.isPressed)
                .rotationEffect(.degrees(reload && !stop && configuration.isPressed && !still ? 90 : 0))
                .scaleEffect(!reload && configuration.isPressed ? scale : 1)
                .animation(
                    still ? nil : reload
                        // Arc's: a quarter turn in about 0.1 s, back in a bit more.
                        ? .easeOut(duration: configuration.isPressed ? 0.1 : 0.14)
                        : configuration.isPressed ? Motion.quick : Motion.settle,
                    value: configuration.isPressed
                )
        }
    }
}

/// The column's width: its setting, or more while its edge is pulled out
/// past its widest. A modifier of its own, so the pull redraws this frame
/// and what lays itself out in it, never the column's own body.
struct StretchedColumn: ViewModifier {
    let browser: Browser
    @ObservedObject var prefs: Preferences

    func body(content: Content) -> some View {
        content
            // Its width steps back on the curve; what is in it only follows,
            // with no curve of its own for each place and size it has, all
            // set going in the let-go's frame.
            .transaction { if $0.stretchBack { $0.animation = nil } }
            .frame(width: max(prefs.sideWidth, browser.sidePull ?? 0))
    }
}

extension Transaction {
    /// The column going back to its widest after its edge was let go past
    /// it (SideEdge, StretchedColumn).
    @Entry var stretchBack = false
}

/// The column's edge: pull it to make the column wider or narrower; ⌘S puts
/// the column away (a click on the edge no longer does, #1852). Notion's sidebar edge, measured
/// (feedback #287): a 12 pt strip, the column-resize cursor, a tip after a
/// second's rest beside the pointer saying both ("Close  Click or ⌘\", "Resize  Drag"),
/// and any move between press and release makes it a drag, none a click.
/// Nothing is drawn for it: the cursor and the tip are its only signs.
///
/// Pulled in past its narrowest, the column doesn't stop dead: the page
/// keeps coming over it, less and less, as if the left edge were holding
/// on to it. Let go there and it springs back out. Pull far enough and
/// the edge wins, the column snaps shut into it, with a tap under the
/// finger to say so. A quick flick inward does the same from anywhere.
/// Pulled out past its widest, the whole column still widens the same
/// way, up to Metrics.sideStretch more, and springs back when let go.
///
/// It sits astride the hairline, Metrics.edgeReach wide, half of it over the
/// page. The page is a real view and would take the pointer from anything
/// SwiftUI drew over it, so this is a real view too, laid on after it.
struct SideEdge: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// The edge of the card the column put away comes out over the page
    /// as: it only makes the column wider or narrower, between its
    /// narrowest and its widest, as Arc's sidebar out over the page does
    /// (feedback #197). Nothing to shut into, and the page has no room of
    /// the column's to stretch into.
    var floating = false

    /// The width the column had when the edge was picked up.
    @State private var grabbed: CGFloat?
    @State private var widthDetent = SidebarWidthDetent(width: Metrics.side)
    /// The widest it may go under this hand: with a pair on screen, as wide
    /// as leaves both halves their least (Split.swift).
    @State private var most = Metrics.sideMax
    /// The edge was pulled far enough in that the column let go and shut.
    /// The rest of that same drag is ignored.
    @State private var snapped = false
    @State private var tip = KeyTipAnchor()

    /// What the edge's tip says, Notion's words on Yab's plate (picked Oct
    /// 20): "Hide  ⌘S", "Resize  Drag". Out over the page as a card, ⌘S
    /// puts the column back in its place, "Dock". The edge itself takes no
    /// click (feedback #1852), so the tip names only the key.
    static func tip(floating: Bool, docks: Bool = true) -> String {
        let how = KeyTipView.how
        let keys = Hotkeys.shared.keys("Hide Sidebar")
        let what = floating && docks ? "Dock" : "Hide"
        let resize = "Resize\(how)Drag"
        return keys.isEmpty ? resize : "\(what)\(how)\(keys)\n\(resize)"
    }

    var body: some View {
        EdgeHandle(
            changed: { travel in
                guard !snapped else { return }
                if grabbed == nil {
                    browser.beginSideSize()
                    grabbed = prefs.sideWidth
                    widthDetent = SidebarWidthDetent(width: prefs.sideWidth)
                    most = max(Metrics.sideMin, min(Metrics.sideMax, browser.columnMost))
                }
                let wanted = (grabbed ?? prefs.sideWidth) + travel * browser.flank.sign
                if floating {
                    let sizing = widthDetent.update(wanted: wanted, maximum: most)
                    if prefs.sideWidth != sizing.width { prefs.sideWidth = sizing.width }
                    if sizing.aligned {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                    return
                }
                let over = Metrics.sideMin - wanted
                if over > Metrics.sideSnap { shut(); return }
                let sizing = widthDetent.update(wanted: wanted, maximum: most)
                if prefs.sideWidth != sizing.width { prefs.sideWidth = sizing.width }
                if sizing.aligned {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                // Past its widest the column still widens, rows and head
                // with it (StretchedColumn), less and less, in whole points:
                // the setting stays its widest, so nothing kept is written
                // and nothing laid out for it is laid out again.
                let past = wanted - most
                let pull = over > 0
                    ? Metrics.sideMin - resisted(over, room: Metrics.sideMin)
                    : past > 0 ? (most + resisted(past, room: Metrics.sideStretch)).rounded() : nil
                if browser.sidePull != pull { browser.sidePull = pull }
                browser.sideStretching = past > 0
            },
            ended: { _, predicted in
                browser.endSideSize()
                defer { grabbed = nil; snapped = false }
                guard !snapped, !floating else { return }
                let flung = (grabbed ?? prefs.sideWidth) + predicted * browser.flank.sign
                if Metrics.sideMin - flung > Metrics.sideSnap {
                    shut()
                } else if let pull = browser.sidePull, pull > prefs.sideWidth {
                    browser.sideLetGo = CACurrentMediaTime()
                    var back = Transaction(animation: Motion.stretchBack)
                    back.stretchBack = true
                    back.addAnimationCompletion { [browser] in
                        browser.sideStretching = false
                        ColumnPages.relay(browser)
                    }
                    withTransaction(back) { browser.sidePull = nil }
                } else if browser.sidePull != nil {
                    withAnimation(Motion.reshape) { browser.sidePull = nil }
                }
            },
            // A click on the edge does nothing: it hid the column for people
            // reaching for the edge to resize it (feedback #1852, owner's
            // pick 2026-11-05). ⌘S still hides it, a drag still sizes it.
            doubled: {},
            hover: { [tip, floating, browser] on in
                guard on else { return KeyTip.shared.leave(tip) }
                // A fixed gap from the hairline, at the latest pointer height.
                // The pointer can enter anywhere in the 20-point hit strip
                // and travel along it during the dwell.
                KeyTip.shared.hover(tip, title: Self.tip(floating: floating, docks: browser.columnMost >= browser.prefs.sideWidth), shortcut: nil,
                                    side: browser.flank == .right ? .left : .right, wait: 1,
                                    position: {
                                        guard let rect = tip.screenRect, let point = tip.hoverPoint else { return nil }
                                        return NSRect(x: rect.midX - 0.5, y: point.y - 0.5, width: 1, height: 1)
                                    })
            },
            anchor: tip
        )
        .frame(width: Metrics.edgeReach)
        .frame(maxHeight: .infinity)
        .onDisappear { browser.endSideSize() }
    }

    /// The edge let go of the column. Already on its way into the left edge
    /// under the hand, it goes straight on out past it rather than the long
    /// way round through the card ⌘S takes.
    private func shut() {
        snapped = true
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            browser.sideSizing = false
            browser.sideCard = false
        }
        withAnimation(Motion.depart) {
            browser.sidePull = nil
            prefs.sideShut = true
        }
    }
}

/// A strip of real view that reports the pointer over it and a drag along it,
/// the way DragGesture would, travel so far, and where a flick would have
/// ended up, without losing the pointer to the page underneath.
struct EdgeHandle: NSViewRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void
    let doubled: () -> Void
    /// A press let go with no move in between, for an edge a click does
    /// something on (the column's, SideEdge). With it, each click is one:
    /// a double click is two, and `doubled` is never asked.
    var clicked: (() -> Void)? = nil
    /// The pointer came onto the edge, or left it: for a divider that
    /// shows its grip only then.
    var hover: (Bool) -> Void = { _ in }
    /// The real strip's frame and latest hover point for a delayed tip.
    var anchor: KeyTipAnchor? = nil
    /// Dragged up and down, travel upward: an edge across the window, as
    /// the developer tools' over the page (DevEdge).
    var vertical = false

    func makeNSView(context: Context) -> Handle { Handle() }

    func updateNSView(_ view: Handle, context: Context) {
        view.vertical = vertical
        view.changed = changed
        view.ended = ended
        view.doubled = doubled
        view.clicked = clicked
        view.hover = hover
        view.anchor = anchor
        anchor?.view = view
    }

    static func dismantleNSView(_ view: Handle, coordinator: ()) { view.stopWatching() }

    /// The cursor is the edge's only sign, so it has to be right every time.
    /// Half the edge lies over the page, and the page sets its own cursor on
    /// every move it hears of, a beat later, from its own process, so a
    /// cursor set on entering lost to it within a frame. Instead the moves
    /// inside the edge are kept from everything else in the window: the
    /// edge sets the cursor and nothing gets to set it back.
    final class Handle: NSView {
        var changed: (CGFloat) -> Void = { _ in }
        var ended: (CGFloat, CGFloat) -> Void = { _, _ in }
        var doubled: () -> Void = {}
        var clicked: (() -> Void)?
        var hover: (Bool) -> Void = { _ in }
        var anchor: KeyTipAnchor?
        var vertical = false

        private var cursor: NSCursor { vertical ? .resizeUpDown : .resizeLeftRight }
        private func along(_ event: NSEvent) -> CGFloat { vertical ? event.locationInWindow.y : event.locationInWindow.x }

        private var start: CGFloat = 0
        private var last: (x: CGFloat, at: TimeInterval)?
        private var speed: CGFloat = 0
        private var dragging = false
        private var spent = false
        private var inside = false
        private var monitor: Any?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                guard let self else { return event }
                return self.moved(event)
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if inside { inside = false; hover(false); NSCursor.arrow.set() }
        }

        private func moved(_ event: NSEvent) -> NSEvent? {
            guard !dragging else { return nil }
            let over = event.window === window
                && window?.isKeyWindow == true
                && !isHiddenOrHasHiddenAncestor
                && bounds.contains(convert(event.locationInWindow, from: nil))
                && window?.contentView?.hitTest(event.locationInWindow) === self
            if over {
                anchor?.hoverPoint = window?.convertPoint(toScreen: event.locationInWindow)
                if !inside { hover(true) }
                inside = true
                cursor.set()
                return nil
            }
            if inside {
                // Back to the arrow; over the page, the page puts its own
                // cursor up again as it hears of this same move.
                inside = false
                hover(false)
                NSCursor.arrow.set()
            }
            return event
        }

        override func cursorUpdate(with event: NSEvent) {
            CursorUpdateGuard.run(self) {
                if inside || dragging { cursor.set() } else { super.cursorUpdate(with: event) }
            }
        }

        override func mouseDown(with event: NSEvent) {
            cursor.set()
            // A double click's own drag moves nothing: it was measured from
            // the press before.
            spent = clicked == nil && event.clickCount == 2
            if spent { doubled(); return }
            // Where the event says, in the window, rather than where the
            // pointer is on the screen: the window stays put while an edge
            // is dragged, and a drag the bench posts has no pointer behind it.
            start = along(event)
            last = (start, event.timestamp)
            speed = 0
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !spent else { return }
            let x = along(event)
            // Held still, a press is still a click.
            guard dragging || x != start else { return }
            dragging = true
            cursor.set()
            if let last, event.timestamp > last.at {
                speed = (x - last.x) / (event.timestamp - last.at)
            }
            last = (x, event.timestamp)
            changed(x - start)
        }

        override func mouseUp(with event: NSEvent) {
            guard dragging else {
                if !spent, let clicked { clicked() }
                return
            }
            dragging = false
            let travel = along(event) - start
            // Where the hand was headed: a tenth of a second more at the
            // speed it let go at, which is about what a DragGesture reckons.
            ended(travel, travel + speed * 0.1)
            inside = bounds.contains(convert(event.locationInWindow, from: nil))
            if !inside { hover(false); NSCursor.arrow.set() }
        }
    }
}

/// Where the stack is: the only thing that moves with the mouse, so the only
/// thing that redraws for it.
@MainActor
private final class Hand: ObservableObject {
    @Published var at: CGPoint = .zero
}

private struct Follow: ViewModifier {
    @ObservedObject var hand: Hand
    func body(content: Content) -> some View { content.position(hand.at) }
}

/// Rows in the hand together: the one taken up on top, the rest as sheets
/// showing under its lower edge, and how many there are in its corner.
struct Stack: View {
    @ObservedObject var tab: Tab
    /// A pair row in the hand: the second half, and the row is drawn as
    /// the pair it is, not as a stack of two (#259).
    var mate: Tab? = nil
    var browser: Browser? = nil
    @ObservedObject var prefs: Preferences
    let count: Int
    let width: CGFloat
    let landing: Bool
    let live: Bool

    @Environment(\.tone) private var tone

    var body: some View {
        if let mate, let browser {
            PairRow(browser: browser, prefs: prefs, first: tab, second: mate, lifted: !landing)
                .frame(width: width)
                .shadow(color: .black.opacity(landing ? 0 : 0.14), radius: 12, y: 4) // design: the same lift as Carried's row in the hand
        } else {
            sheets
        }
    }

    private var sheets: some View {
        ZStack {
            ForEach((1..<min(count, 3)).reversed(), id: \.self) { sheet in
                GroundFill(shape: RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                            // On a color the ink let through, not a gray edge.
                            .strokeBorder(tone == nil ? Palette.hairline : Palette.ink.opacity(0.12), lineWidth: 1)
                    }
                    .frame(width: width - CGFloat(sheet) * 12, height: SideBar.row)
                    .offset(y: CGFloat(sheet) * 4)
                    .opacity(landing ? 0 : 1)
            }
            Carried(tab: tab, prefs: prefs, folded: false, size: CGSize(width: width, height: SideBar.row), landing: landing, live: live)
        }
        .overlay(alignment: .topTrailing) {
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(GroundFill<Rectangle>.ground(tone, browser: nil))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Capsule().fill(Palette.ink))
                    .offset(x: 5, y: -6)
                    .opacity(landing ? 0 : 1)
            }
        }
    }
}

/// A tab in the hand between the two lists: a row, or the square it becomes
/// over the pins, one thing changing shape, its title giving way to its
/// mark as it narrows, and back.
struct Carried: View {
    @ObservedObject var tab: Tab
    /// The other half, for a pair row carried up into the pins or a pinned
    /// pair's square: folded, both marks, as the square wears them.
    var mate: Tab? = nil
    @ObservedObject var prefs: Preferences
    let folded: Bool
    let size: CGSize
    let landing: Bool
    let live: Bool

    @Environment(\.tabTitleSize) private var titleSize
    @Environment(\.tone) private var tone

    /// In the hand it has a ground whatever it is; set down, the ground it
    /// will have at rest: a pin's faint one, a row's none unless it is the
    /// tab being looked at.
    private var ground: Double {
        guard landing, !live else { return 1 }
        return folded ? 0.55 : 0
    }

    var body: some View {
        let side = min(size.width, size.height)
        ZStack(alignment: folded ? .center : .leading) {
            // The column's own color under the gray while it is in the hand,
            // so nothing shows through it; gone as it settles.
            GroundFill(shape: RoundedRectangle(cornerRadius: folded ? SideBar.corner(side) : SideBar.radius, style: .continuous))
                .opacity(landing ? 0 : 1)
            RoundedRectangle(cornerRadius: folded ? SideBar.corner(side) : SideBar.radius, style: .continuous)
                .fill(Palette.wash(on: tone).opacity(ground))
            if folded {
                Group {
                    if let mate {
                        PinPairMarks(first: tab, second: mate, glyph: prefs.glyph, size: min(16, side * 16 / 34), room: size.width)
                    } else if prefs.glyph == .icons || tab.customMark != nil, let icon = tab.displayIcon {
                        Mark(icon: icon, letter: tab.pin ?? tab.monogram, size: min(16, side * 16 / 34))
                    } else {
                        Text(tab.pin ?? tab.monogram)
                            .font(.system(size: min(12, side * 12 / 34), weight: .medium))
                            .foregroundStyle(Palette.ink)
                    }
                }
                .transition(.opacity)
            } else {
                HStack(spacing: SideBar.markGap) {
                    if prefs.glyph == .icons {
                        Mark(icon: tab.displayIcon, letter: tab.monogram, size: SideBar.mark)
                    }
                    Text(tab.label)
                        .font(.system(size: titleSize))
                        .lineLimit(1)
                        .foregroundStyle(landing && !live ? Palette.muted(on: tone) : Palette.ink)
                }
                .padding(.leading, 10)
                .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(landing ? 0 : 0.14), radius: 12, y: 4)
    }
}

/// A door's tooltip: one that names its keys when it has any.
private struct DoorTip: ViewModifier {
    let help: String
    let shortcut: String?
    let keys: String?
    let wait: TimeInterval

    func body(content: Content) -> some View {
        content.keyTip(help, shortcut: shortcut, keys: keys, wait: wait)
    }
}

private struct DoorSizeKey: EnvironmentKey {
    static let defaultValue = Door.Size()
}

extension EnvironmentValues {
    var doorSize: Door.Size {
        get { self[DoorSizeKey.self] }
        set { self[DoorSizeKey.self] = newValue }
    }
}
