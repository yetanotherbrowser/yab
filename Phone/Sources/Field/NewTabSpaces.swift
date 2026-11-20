import SwiftUI
import UIKit
#if canImport(SyncKit)
import SyncKit
#endif

/// New Tab as one card in the space's color, as tall as the screen allows.
/// The phone puts its picker in the foot; the tablet keeps the capsule on
/// top. The space's pins, kept rows and today's tabs fill the card. Private is the first page; the eyes and the capsule both go there.
/// Typed words keep the card's height: the space gives way, the capsule
/// steps back, and the rows stand at the foot over the field.

/// Where the pages are: the card writes the position while it scrolls, the
/// capsule reads it for its lens and asks for a page with `jump`.
@MainActor
@Observable
final class NewTabPager {
    static let shared = NewTabPager()

    /// Position in the card's page order, fractional while the pages scroll.
    var position: CGFloat = 1
    var pagingByGesture = false
    /// The ordinary space last at rest in the card (kept while on Private).
    var spaceID: Space.ID?
    /// A page the capsule or the eyes asked for; the card scrolls to it.
    var jump: String?

    /// Private's page among the spaces' ids.
    static let privatePage = "yab.newtab.private"
    /// Chats: always the first page, before Private.
    static let chatsPage = "yab.newtab.chats"
    /// Chats are in front: the field searches them instead of the web.
    var onChats = false
    var activeFieldMode: Surfaces.FieldMode?
    /// The Chats page shows the archived chats (the three dots' filter; the
    /// box at the field's left on an iPad).
    var showsArchive = false
    enum SpaceFilter: Hashable { case everything, pins, today }
    /// What a space's page shows (the three dots).
    var spaceFilter = SpaceFilter.everything
    /// The page the next card opens on (a chat closed back into its row).
    @ObservationIgnored var startAt: String?
    /// The next card's space page opens with This iPhone's Today folded (named states).
    @ObservationIgnored var startFolded = false
}

/// The same wash spans the tablet's sidebar and the rim around its page.
/// Both follow the pager, including the blend while moving between spaces.
struct SpacePagesBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let spaces: [Space]
    let pages: [String]
    let position: CGFloat

    init(spaces: [Space], pages: [String]? = nil, position: CGFloat) {
        self.spaces = spaces
        self.pages = pages ?? [NewTabPager.privatePage, NewTabPager.chatsPage] + spaces.map(\.id)
        self.position = position
    }

    private var fraction: CGFloat { min(max(position, 0), CGFloat(pages.count - 1)) }
    var darkness: Double {
        guard let i = pages.firstIndex(of: NewTabPager.privatePage) else { return 0 }
        return Double(max(0, 1 - abs(fraction - CGFloat(i))))
    }
    /// The wash's top and foot here, blended between the pages. Light: the
    /// space's color, lifted toward white at the top. Dark: the Mac's dark
    /// shade of the space (folderGround), barely lifted; Chats keeps its
    /// dimmed neutral. Private is its own dark either way.
    func wash(dark: Bool) -> (top: SIMD3<Double>, foot: SIMD3<Double>) {
        func v(_ c: RGB) -> SIMD3<Double> { SIMD3(Double(c.r), Double(c.g), Double(c.b)) }
        func lift(_ c: SIMD3<Double>, _ k: Double) -> SIMD3<Double> { c + (SIMD3(repeating: 255) - c) * k }
        let ends = pages.map { key -> (SIMD3<Double>, SIMD3<Double>) in
            if key == NewTabPager.privatePage { let c = v(SpacePagesCard.privateWash); return (c, c) }
            let space = key == NewTabPager.chatsPage ? nil : spaces.first { $0.id == key }
            if dark, let space { let c = v(space.folderGround(dark: true)); return (lift(c, 0.06), c) }
            let c = v(space.map { $0.look?.ground ?? $0.tint } ?? SpacePagesCard.chatsWash)
            let dim = dark ? 0.55 : 1
            return (lift(c, 0.35) * dim, c * dim)
        }
        let i = Int(fraction.rounded(.down)), j = min(i + 1, ends.count - 1)
        let t = Double(fraction - CGFloat(i))
        return (ends[i].0 + (ends[j].0 - ends[i].0) * t, ends[i].1 + (ends[j].1 - ends[i].1) * t)
    }
    static func color(_ c: SIMD3<Double>) -> Color { Color(red: c.x / 255, green: c.y / 255, blue: c.z / 255) }
    var body: some View {
        let (top, foot) = wash(dark: colorScheme == .dark)
        ZStack {
            LinearGradient(colors: [Self.color(top), Self.color(foot)], startPoint: .top, endPoint: .bottom)
            let near = Int(fraction.rounded())
            LookGrainFill(amount: (spaces.first { $0.id == pages[near] }?.look?.grain ?? 0) * (1 - darkness))
        }
    }
}

// MARK: - the card

/// The morph moves the card from outside, frame by frame: its own body runs
/// only when what it shows changes.
extension SpacePagesCard: Equatable {
    static func == (a: Self, b: Self) -> Bool {
        a.rows == b.rows && a.content == b.content && a.width == b.width && a.maxHeight == b.maxHeight
            && a.fieldExtraHeight == b.fieldExtraHeight && a.bottom == b.bottom && a.privatePage == b.privatePage
            && a.onlyPrivate == b.onlyPrivate && a.reveal == b.reveal && a.fullness == b.fullness
    }
}

struct SpacePagesCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    /// Typed words' rows: the space gives way and they stand at the foot.
    var rows: [WordRow] = []
    let content: NewTabContent
    let width: CGFloat
    let maxHeight: CGFloat
    var fieldExtraHeight: CGFloat = 0
    var bottom: CGFloat? = nil
    /// Private's page first (New Tab); the plate's field has none.
    var privatePage = true
    /// Over a private tab: Private's page alone, nothing of Chats or the
    /// spaces behind it.
    var onlyPrivate = false
    /// How far a finger has lifted the card out of the plate (1 open): the
    /// space is there by a third of the way, the capsule just after.
    var reveal: CGFloat = 1
    /// The whole screen (1): no corners, the head under the status bar.
    var fullness: CGFloat = 1
    /// A sidebar below a toolbar has already cleared the status bar.
    var headerInset: CGFloat? = nil

    @State private var page: String?
    /// The rows last typed, kept while they leave.
    @State private var shownRows: [WordRow] = []
    @State private var typing = false
    /// The capsule spreads to the card's width while a finger moves the pages.
    @State private var wide = false
    @State private var narrowing: DispatchWorkItem?
    @State private var lastDy: CGFloat?
    @State private var puttingKeyboardAway = false

    private var spaces: [Space] { app.browser.spaces.filter { !$0.isPrivate } }
    /// Private (New Tab only), then Chats, then the spaces; over a private tab, Private alone.
    private var pages: [String] {
        if onlyPrivate { return [NewTabPager.privatePage] }
        // Private is a way to search, its tabs in the stack: no page among the spaces.
        return (privatePage && !app.field.sheetAllowed ? [NewTabPager.privatePage] : []) + [NewTabPager.chatsPage] + spaces.map(\.id)
    }
    private var names: [String] {
        pages.map { key in
            key == NewTabPager.chatsPage ? "Chats" : key == NewTabPager.privatePage ? "Private"
                : spaces.first { $0.id == key }?.name ?? ""
        }
    }
    private func background(at position: CGFloat) -> SpacePagesBackground {
        SpacePagesBackground(spaces: spaces, pages: pages, position: position)
    }
    /// How dark the card is: 1 on Private's page, 0 a page away from it.
    private func darkness(at position: CGFloat) -> Double { background(at: position).darkness }
    private var pager: NewTabPager { .shared }
    private var showsCapsule: Bool { pages.count > 1 }
    /// Room the capsule takes at the card's top.
    /// The head keeps its place on screen while the card stretches: the
    /// card's top moves up by `highest`, the head moves down inside it as much.
    private var capsuleTopNow: CGFloat {
        if let headerInset { return headerInset }
        // The column beside a page: no status bar stands over it.
        if width < app.workspace.windowSize.width - 0.5, app.workspace.windowInsets.left == 0 { return Self.columnTop }
        return Self.capsuleTop + fullness * Metrics.NewTab.highest
    }
    static let columnTop: CGFloat = 20
    /// The capsule keeps the card's own width at rest, so its model never rebuilds mid-stretch.
    /// A status column takes its side from the head: the camera stays over the
    /// screen there, the list under it keeps its width.
    private var capsuleWidth: CGFloat { width - 2 * Metrics.NewTab.inset * fullness - reserved.left - reserved.right }
    private var reserved: ChromeGeometry.Sides { app.workspace.sides(ofSurface: width) }
    private var head: CGFloat {
        if showsCapsule { return capsuleTopNow + Metrics.Column.barHeight + 6 }
        // Private's page alone behind a private tab's field: no capsule, but
        // its title still clears the status bar where the capsule would sit.
        return onlyPrivate ? capsuleTopNow : 0
    }
    static let capsuleTop: CGFloat = 12
    /// The whole screen's capsule, where the search sheet's field lands.
    static func restCapsule(width: CGFloat, sides: ChromeGeometry.Sides = .zero) -> CGRect {
        let free = width - sides.left - sides.right
        let w = min(Metrics.Column.barWidth - Metrics.Column.capsuleInset * 2, free - 2 * (12 + Metrics.touch + 24))
        return CGRect(x: sides.left + (free - w) / 2, y: capsuleTop + Metrics.NewTab.highest, width: w, height: Metrics.Column.barHeight)
    }
    /// The whole screen's head buttons, Settings at the left and the computer
    /// (or the dots) at the right, inside what the system reserves at the
    /// sides: an iPhone Duo's status column takes every touch on it. All Tabs,
    /// the empty home and the spaces stand them in the same places.
    static func headButton(right: Bool, width: CGFloat, sides: ChromeGeometry.Sides) -> CGRect {
        let x = right ? width - sides.right - Metrics.NewTab.inset - Metrics.touch : sides.left + Metrics.NewTab.inset
        return CGRect(x: x, y: capsuleTop + Metrics.NewTab.highest, width: Metrics.touch, height: Metrics.touch)
    }
    /// Where a whole screen's page starts, under the capsule.
    static var restHead: CGFloat { capsuleTop + Metrics.NewTab.highest + Metrics.Column.barHeight + 6 }
    /// One content edge for everything in the card, 24 in from its sides: the
    /// pins, the rows' icons (whose middle, 35, is the field's magnifier's),
    /// the line and Clear. Rows bring 8 of their own, so the stack is 16 in.
    static let edge: CGFloat = 24
    static let side: CGFloat = edge - Metrics.NewTab.rowPadding.leading

    var body: some View {
        let height = maxHeight
        let f = min(max(pager.position, 0), CGFloat(pages.count - 1))
        let dark = darkness(at: f) > 0.5
        let bottomRoom = Metrics.NewTab.cardPadding.bottom + fieldExtraHeight
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
            background(at: f)
            // Out of the plate: its glass flows into the space's color, never see-through.
            Rectangle().fill(.regularMaterial)
                .opacity(1 - Double(min(max((reveal - 0.05) / 0.4, 0), 1)))
                .allowsHitTesting(false)
            // Typed words: the space stays in sight, the rows' glass card over it.
            pagesView(height: height, bottomRoom: bottomRoom)
                .opacity(Double(min(max((reveal - 0.06) / 0.18, 0), 1)))
                .allowsHitTesting(!typing)
                .accessibilityHidden(typing)
            }
            // All Tabs' computer: the cards give way to the space in place, through a blur.
            .blur(radius: Metrics.NewTab.sidebarBlur * app.field.sidebarBlur)
            .opacity(Double(1 - app.field.sidebarBlur))
            TypedRows(rows: shownRows, shown: typing, dark: dark, bottomRoom: bottomRoom,
                      fill: WordRowView.bestFill(dark: dark))
                // Under the capsule, which stays in sight over the space.
                .padding(.top, head)
                .frame(height: height, alignment: .bottom)
                .allowsHitTesting(typing)
                .accessibilityHidden(!typing)
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture().onEnded { value in
                    guard typing, let next = SpaceSearchPaging.destination(from: page, pages: pages,
                                                                           translation: value.translation) else { return }
                    app.field.putKeyboardAway()
                    pager.jump = next
                })
            if app.field.sheetAllowed && !app.workspace.tabletControls && !app.surfaces.fieldBeside {
                // All Tabs' head in the same places: Settings at the left, and
                // at the right the dots where its computer was, come through a blur.
                HStack {
                    Button { app.openSettingsFromSpaces(at: nil) } label: {
                        Glyph(SettingsFieldRow.glyph, size: Metrics.Chrome.spaceEmoji, color: dark ? .white : Ink.primary)
                            .frame(width: Metrics.touch, height: Metrics.touch)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("newtab.settings")
                    Spacer()
                    SpacesMoreMenu(dark: dark)
                        .blur(radius: Metrics.NewTab.sidebarBlur * app.field.sidebarBlur)
                        .opacity(Double(1 - app.field.sidebarBlur))
                }
                .buttonStyle(.plain)
                .padding(.leading, Metrics.NewTab.inset + reserved.left)
                .padding(.trailing, Metrics.NewTab.inset + reserved.right)
                .padding(.top, capsuleTopNow)
            } else if showsCapsule {
                // Search results replace the rows, not the space selector.
                CardCapsule(names: names, current: pages.firstIndex(of: page ?? "") ?? Int(f.rounded()), position: f,
                            width: capsuleWidth, dark: dark, more: app.field.sheetAllowed) { i in
                    app.field.putKeyboardAway()
                    pager.jump = pages[i]
                } sheetDrag: { dy, ended, velocity in
                    sheetDrag(dy, ended: ended, velocity: velocity)
                } about: {
                    // Yab's mark opens About Yab (About/AboutLayer).
                    AboutModel.shared.open()
                } settings: {
                    app.openSettingsFromSpaces(at: nil)
                }
                .padding(.top, capsuleTopNow)
                .padding(.leading, reserved.left)
                .padding(.trailing, reserved.right)
                .opacity(Double(min(max((reveal - 0.04) / 0.16, 0), 1)))
            }
        }
        .frame(width: width, height: height)
        // The field is a sibling above this card, so its taps keep editing.
        // Observe touches alongside the rows' buttons and native scrolling.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            if app.fieldAnswer == nil { app.field.putKeyboardAway() }
        })
        .simultaneousGesture(DragGesture().onChanged { _ in
            // Space lists dismiss from their own pan, before deciding whether
            // this finger may fold the screen. Private's empty room has no list.
            if page == NewTabPager.privatePage, !app.field.resting { app.field.putKeyboardAway() }
        })
        .clipShape(RoundedRectangle(cornerRadius: Metrics.NewTab.radius * (1 - fullness), style: .continuous))
        // The keyboard's rounded top corners show what is under them: the
        // space's color goes on down behind the keyboard.
        .background(alignment: .bottom) {
            washFoot(at: f)
                .frame(height: Metrics.NewTab.underKeyboard)
                .offset(y: Metrics.NewTab.underKeyboard)
                .opacity(Double(fullness))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .shadow(color: Ink.shadow.opacity(0.06 * Double(1 - fullness)), radius: 1, x: 0, y: 1)
        .shadow(color: Ink.shadow.opacity(0.22 * Double(1 - fullness)), radius: 10, x: 0, y: 12)
        .offset(y: bottom.map { $0 - height } ?? 0)
        .onAppear {
            pager.activeFieldMode = app.field.mode
            var start: String = (app.field.isPrivate || onlyPrivate) && pages.contains(NewTabPager.privatePage) ? NewTabPager.privatePage
                : (spaces.contains { $0.id == app.browser.spaceID } ? app.browser.spaceID : app.browser.ordinarySpaceID)
            if let asked = pager.startAt, pages.contains(asked) { start = asked }
            pager.startAt = nil
            pager.onChats = start == NewTabPager.chatsPage
            page = start
            if start != NewTabPager.privatePage, start != NewTabPager.chatsPage { pager.spaceID = start }
            if let i = pages.firstIndex(of: start) { pager.position = CGFloat(i) }
            if !rows.isEmpty { shownRows = rows; typing = true }
        }
        .onChange(of: rows) { _, now in
            if !now.isEmpty { shownRows = now }
            let wanted = !now.isEmpty
            if wanted != typing { withAnimation(Motion.cardHug.animation) { typing = wanted } }
        }
        .onChange(of: page) { _, now in
            guard let now else { return }
            pager.onChats = now == NewTabPager.chatsPage
            if now == NewTabPager.chatsPage {
                if app.field.isPrivate { app.field.setPrivate(false) }
                // Chats is a list to look through first: its search takes the
                // keyboard only when tapped.
                app.field.putKeyboardAway()
            } else if now == NewTabPager.privatePage {
                // A private tab's own field is private already: its words stay in that tab.
                if !app.field.isPrivate, !onlyPrivate { app.field.setPrivate(true) }
            } else {
                app.selectSpacePage(now)
                if app.field.isPrivate { app.field.setPrivate(false) }
            }
        }
        // The eyes: to Private, and back to the space it came from.
        .onChange(of: app.field.isPrivate) { _, isPrivate in
            let wanted = isPrivate ? NewTabPager.privatePage : (pager.spaceID ?? spaces.first?.id)
            // The plate's field has no Private page to go to: its eyes only darken the field.
            if let wanted, wanted != page, pages.contains(wanted) { withAnimation(Motion.space.animation) { page = wanted } }
        }
        .onChange(of: pager.jump) { _, wanted in
            guard let wanted else { return }
            pager.jump = nil
            withAnimation(Motion.space.animation) { page = wanted }
        }
        .onDisappear {
            pager.onChats = false; pager.showsArchive = false; pager.spaceFilter = .everything; pager.activeFieldMode = nil
            pager.pagingByGesture = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("newtab.spaces")
    }

    /// A finger on the head moving down: the screen goes back into the plate
    /// with it, and comes back if it is let go early.
    private func sheetDrag(_ dy: CGFloat, ended: Bool, velocity: CGFloat) {
        let field = app.field
        if !ended {
            if lastDy == nil { puttingKeyboardAway = !field.resting }
            if puttingKeyboardAway {
                field.putKeyboardAway()
                lastDy = dy
                return
            }
            if lastDy == nil { field.beginLower() }
            field.lowerMoved(by: dy - (lastDy ?? 0))
            lastDy = dy
            return
        }
        lastDy = nil
        if puttingKeyboardAway { puttingKeyboardAway = false; return }
        field.lowerEnded(velocity: velocity)
    }

    /// The wash's foot, its last color, carried on under the keyboard.
    private func washFoot(at position: CGFloat) -> some View {
        SpacePagesBackground.color(background(at: position).wash(dark: colorScheme == .dark).foot)
    }

    /// The page's own color, for the best typed row: the space's picked
    /// color, or its wash with the white taken back out (SpaceLook.wash).
    private func color(at f: CGFloat) -> RGB {
        let key = pages[min(max(Int(f.rounded()), 0), pages.count - 1)]
        guard let space = spaces.first(where: { $0.id == key }) else { return Self.chatsWash }
        return Self.ownColor(of: space)
    }

    static func ownColor(of space: Space) -> RGB {
        if let look = space.look { return look.primary }
        func unwash(_ c: Int) -> Int { min(255, max(0, Int(((Double(c) - 255 * 0.82) / 0.18).rounded()))) }
        return RGB(unwash(space.tint.r), unwash(space.tint.g), unwash(space.tint.b))
    }

    static let privateWash = RGB(28, 28, 32)
    /// Chats' page: a quiet neutral, the conversations carry the color.
    static let chatsWash = RGB(226, 224, 232)

    private func pagesView(height: CGFloat, bottomRoom: CGFloat) -> some View {
        ScrollViewReader { proxy in
            pagesScroll(height: height, bottomRoom: bottomRoom)
                // Stretched or let back: the pages keep standing on the one in front.
                .onChange(of: width) { _, _ in
                    guard let page else { return }
                    var quiet = Transaction(animation: nil)
                    quiet.disablesAnimations = true
                    withTransaction(quiet) { proxy.scrollTo(page, anchor: .leading) }
                }
        }
    }

    private func pagesScroll(height: CGFloat, bottomRoom: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(pages, id: \.self) { key in
                    Group {
                        if key == NewTabPager.chatsPage {
                            ChatsPage(top: head, bottomRoom: bottomRoom)
                        } else if key == NewTabPager.privatePage {
                            PrivateNewTab()
                                .padding(.top, head)
                                .padding(.bottom, bottomRoom)
                        } else if let space = spaces.first(where: { $0.id == key }) {
                            SpacePage(space: space, now: content.now, top: head, bottomRoom: bottomRoom,
                                      pinsWidth: width - 2 * Self.edge)
                        }
                    }
                    .frame(width: width, height: height, alignment: .top)
                    .id(key)
                }
            }
            .scrollTargetLayout()
            .background(SpacePagingTouchGate())
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $page)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
            if width > 0 { pager.position = x / width }
        }
        // A finger on the pages spreads the capsule; 0.28 s after they stop it
        // settles back, as the capsule artifact does. A tap's jump doesn't.
        .onScrollPhaseChange { _, phase in
            pager.pagingByGesture = phase == .interacting || phase == .decelerating
            if phase == .interacting, !app.field.resting { app.field.putKeyboardAway() }
            switch phase {
            case .tracking, .interacting, .decelerating:
                narrowing?.cancel()
                if !wide { withAnimation(.spring(response: 0.42, dampingFraction: 1)) { wide = true } }
            case .idle:
                narrowing?.cancel()
                let work = DispatchWorkItem { withAnimation(.spring(response: 0.42, dampingFraction: 1)) { wide = false } }
                narrowing = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
            default: break
            }
        }
        .frame(width: width, height: height)
    }
}

/// Chats, the first page: New Chat, then the person's own chats as Your
/// Chats lists them (pinned first, then by recency), and under them, folded,
/// the ones an agent or a command began (Tasks) and the routines' runs, one
/// row each, its latest (Routines). The field at the foot searches them
/// all. A card zooms into its chat, a page in its own cover (UIKit's zoom,
/// as Chat Info's), and ‹, a pull down or the edge swipe zoom it back into
/// the card, here. Held, a card has the Mac's chat menu.
private struct ChatsPage: View {
    @Environment(AppModel.self) private var app
    let top: CGFloat
    let bottomRoom: CGFloat
    @State private var open: Set<ChatGroup> = []
    @State private var renaming: Chat.ID?
    @State private var renameText = ""
    @State private var deleting: Chat.ID?
    @State private var archivingBelow: (id: Chat.ID, list: [Chat])?
    /// The cards and New Chat's row, as the sources a chat's cover zooms
    /// out of and back into (ChatPageCover).
    @Namespace private var cards

    var body: some View {
        let query = app.field.words.trimmingCharacters(in: .whitespacesAndNewlines)
        let archive = NewTabPager.shared.showsArchive
        let archived = app.chats.visibleChats.filter(\.archived)
        let all = archive
            ? (query.isEmpty ? archived : ChatSectioning.search(query, in: archived, sheet: app.chatSheet, app: app).filter(\.archived))
            : query.isEmpty
            ? ChatSectioning.listed(app.chats.visibleChats, sheet: app.chatSheet)
            : ChatSectioning.search(query, in: app.chats.visibleChats, sheet: app.chatSheet, app: app)
        // A project's chats stand in it: its circle over the cards when it
        // is pinned, else a card of its own among them (ChatSectioning.cards).
        let grouped = query.isEmpty && !archive
        let split = grouped ? ChatSectioning.byProject(all, projects: app.projects.all) : (loose: all, within: [:])
        let groups = grouped ? ChatGroup.split(split.loose) : [(ChatGroup.yours, all)]
        let pinned = grouped ? app.projects.pinned : []
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if archive {
                    Text("Archived")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Ink.rowSubtitle)
                        .padding(.horizontal, SpacePagesCard.edge)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                } else if query.isEmpty, !app.field.sheetAllowed { NewChatRow(cards: cards) }
                if !pinned.isEmpty {
                    ProjectPins(projects: pinned, within: split.within, cards: cards)
                }
                ForEach(groups, id: \.0) { entry in
                    let (group, list) = entry
                    if group != .yours {
                        GroupHeader(group: group, count: list.count, open: open.contains(group)) {
                            Motion.columnRows.run { if open.contains(group) { open.remove(group) } else { open.insert(group) } }
                        }
                    }
                    if group == .yours || open.contains(group) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.NewTab.chatCardGap, alignment: .top), count: 2),
                                  spacing: Metrics.NewTab.chatCardGap + Metrics.NewTab.chatStackStep * 2) {
                            ForEach(group == .yours && grouped
                                    ? ChatSectioning.cards(list, listed: all, projects: app.projects.all, within: split.within)
                                    : list.map(ChatSectioning.Card.chat)) { card in
                                switch card {
                                case let .chat(chat):
                                    ChatPageRow(chat: chat, cards: cards, below: AppModel.archivableBelow(chat.id, in: list).count,
                                                leaving: leaving.contains(chat.id),
                                                rename: { renameText = chat.title; renaming = chat.id },
                                                delete: { deleting = chat.id },
                                                archiveBelow: { archivingBelow = (chat.id, list) })
                                case let .project(project, chats):
                                    ProjectPageCard(project: project, chats: chats, cards: cards)
                                }
                            }
                        }
                        .padding(.top, Metrics.NewTab.chatStackStep * 2)
                        .padding(.bottom, 6)
                    }
                }
                if all.isEmpty {
                    Text(archive ? (query.isEmpty ? "No archived chats." : "No archived chats with \u{201C}\(query)\u{201D}.")
                         : query.isEmpty ? "No chats yet." : "No chats with \u{201C}\(query)\u{201D}.")
                        .font(.subheadline)
                        .foregroundStyle(Ink.rowSubtitle)
                        .padding(.horizontal, SpacePagesCard.edge)
                        .padding(.vertical, 16)
                }
            }
            .padding(.horizontal, SpacePagesCard.side)
            .padding(.top, 8)
            .padding(.bottom, bottomRoom)
            .background(CardPull(field: app.field))
            // A tap between the cards puts the search's keyboard away, as in Messages.
            .background { Color.clear.contentShape(Rectangle()).onTapGesture { app.field.putKeyboardAway() } }
        }
        // Dragged down into it, the keyboard goes with the finger, as in Messages and Mail.
        .scrollDismissesKeyboard(.interactively)
        .background { Color.clear.contentShape(Rectangle()).onTapGesture { app.field.putKeyboardAway() } }
        .modifier(UnderCapsule(top: top))
        .accessibilityIdentifier("newtab.chats")
        // A chat out of its card: UIKit's zoom, as Chat Info's out of the face.
        .fullScreenCover(item: ChatPagePresentation.binding(app: app)) { presentation in
            ChatPageCover(presentation: presentation)
                .environment(app)
                .navigationTransition(.zoom(sourceID: presentation.source, in: cards))
        }
        // A project out of its circle or its card, the same zoom.
        .fullScreenCover(item: ProjectPresentation.binding(app: app)) { presentation in
            ProjectPage(presentation: presentation)
                .environment(app)
                .navigationTransition(.zoom(sourceID: ProjectPage.source(presentation.project), in: cards))
        }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let id = renaming { app.rename(id, to: renameText) }
                renaming = nil
            }
        }
        .confirmationDialog(deleting.map { app.deleteQuestion($0).title } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Chat", role: .destructive) {
                if let id = deleting { app.deleteChat(id) }
                deleting = nil
            }
        } message: {
            if let detail = deleting.flatMap({ app.deleteQuestion($0).detail }) { Text(detail) }
        }
        .confirmationDialog(archiveBelowTitle, isPresented: Binding(get: { archivingBelow != nil }, set: { if !$0 { archivingBelow = nil } }),
                            titleVisibility: .visible) {
            Button("Archive") {
                if let below = archivingBelow { app.archive(below: below.id, in: below.list) }
                archivingBelow = nil
            }
        }
    }

    private var archiveBelowTitle: String {
        let count = leaving.count
        return count == 1 ? "Archive 1 older chat?" : "Archive \(count) older chats?"
    }

    /// The chats Archive Older would put away, while it asks: their cards
    /// go dim in the grid, so the grid itself says what older means.
    private var leaving: Set<Chat.ID> {
        guard let below = archivingBelow else { return [] }
        return Set(AppModel.archivableBelow(below.id, in: below.list).map(\.id))
    }
}

/// Who began the chats under one heading of the Chats page.
enum ChatGroup: String, Hashable, CaseIterable {
    case yours, tasks, routines

    var title: String {
        switch self {
        case .yours: "Chats"
        case .tasks: "Tasks"
        case .routines: "Routines"
        }
    }

    /// The person's own, the tasks an agent or a command began, and each
    /// routine's latest run; empty groups are left out.
    static func split(_ chats: [Chat]) -> [(ChatGroup, [Chat])] {
        var yours: [Chat] = [], tasks: [Chat] = [], routines: [Chat] = []
        var seen = Set<String>()
        for chat in chats {
            if let routine = chat.routine ?? (chat.origin == "routine" ? chat.title : nil) {
                // Listed newest first: the first of a routine is its latest run.
                if seen.insert(routine).inserted { routines.append(chat) }
            } else if chat.isYours || chat.pinned {
                yours.append(chat)
            } else {
                tasks.append(chat)
            }
        }
        return [(.yours, yours), (.tasks, tasks), (.routines, routines)].filter { $0.0 == .yours || !$0.1.isEmpty }
    }
}

/// A folded group's heading: its name, how many, a chevron.
private struct GroupHeader: View {
    let group: ChatGroup
    let count: Int
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(group.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Ink.rowSubtitle)
                Text("\(count)")
                    .font(.footnote)
                    .foregroundStyle(Ink.rowSubtitle)
                Spacer(minLength: 0)
                Glyph(open ? .chevronDownSmall : .chevronRight, size: 14, color: Ink.rowSubtitle)
            }
            .padding(.horizontal, SpacePagesCard.edge)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("newtab.chats.group.\(group.rawValue)")
        .accessibilityValue(open ? "open" : "folded")
    }
}

private struct ChatPageRow: View {
    @Environment(AppModel.self) private var app
    let chat: Chat
    let cards: Namespace.ID
    /// How many chats Archive Older would put away.
    let below: Int
    /// Archive Older is asking about this card: dim, with the archive's mark.
    let leaving: Bool
    let rename: () -> Void
    let delete: () -> Void
    let archiveBelow: () -> Void

    /// What the card stacks: a task's tabs on the Mac, else the sites the
    /// chat's agent worked on, in the order it came to them.
    private var marks: (icons: [String], words: String)? {
        if let id = chat.task, let tabs = app.tasks.definition(id)?.tabs, !tabs.isEmpty {
            return (tabs.map(\.icon), tabs.count == 1 ? "1 tab" : "\(tabs.count) tabs")
        }
        var hosts: [String] = []
        for message in chat.messages { for host in TurnWork.hosts(message.work?.steps ?? []) where !hosts.contains(host) { hosts.append(host) } }
        guard !hosts.isEmpty else { return nil }
        return (hosts, hosts.count == 1 ? "1 site" : "\(hosts.count) sites")
    }
    private var sites: [String] { marks?.icons ?? [] }

    /// The sheets showing above the card: one for a site, two for three and more.
    @ViewBuilder private var stack: some View {
        let count = sites.isEmpty ? 0 : sites.count >= 3 ? 2 : 1
        let step = Metrics.NewTab.chatStackStep
        ZStack(alignment: .top) {
            ForEach((0..<count).reversed(), id: \.self) { i in
                RoundedRectangle(cornerRadius: Metrics.NewTab.chatCardRadius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(i == 0 ? 0.75 : 0.5))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.NewTab.chatCardRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
                    .frame(height: 40)
                    .padding(.horizontal, step * CGFloat(i + 1) + 1)
                    .offset(y: -step * CGFloat(i + 1))
            }
        }
        .accessibilityHidden(true)
    }

    var body: some View {
        let card = RoundedRectangle(cornerRadius: Metrics.NewTab.chatCardRadius, style: .continuous)
        Button {
            app.openChatFromSpaces(chat.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // A chat whose agent went to sites wears their marks and how
                // many; any other, its own icon.
                Group {
                    if sites.isEmpty {
                        ChatRowIcon(chat: chat)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(Array(sites.prefix(3).enumerated()), id: \.offset) { _, icon in
                                let host = icon.contains(".") ? icon : nil
                                let page = host.flatMap { URL(string: "https://" + $0) }
                                Favicon(icon: icon, host: host, size: Metrics.NewTab.chatCardFavicon, url: page)
                                    // A site the agent went to, not one of this
                                    // iPhone's tabs: its icon comes from the site.
                                    .task(id: icon) { if let page { await SiteIcons.shared.load(for: page) } }
                            }
                            Text(marks?.words ?? "")
                                .font(.caption)
                                .foregroundStyle(Ink.rowSubtitle)
                                .padding(.leading, 2)
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(chat.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if chat.unread {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    }
                }
                Text(ChatWords.preview(chat, app: app))
                    .font(.footnote)
                    .foregroundStyle(Ink.rowSubtitle)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                // Waiting for a Mac that is down: where, in place of its time.
                let waits = chat.messages.last { $0.role == .wait }.map { MacWords.waitsFor($0.mac?.name ?? "your Mac") }
                Text(chat.working ? "working" : waits ?? chat.time)
                    .font(.caption)
                    .foregroundStyle(chat.working ? Ink.done : Ink.faint)
            }
            .padding(Metrics.NewTab.chatCardPadding)
            .frame(maxWidth: .infinity, minHeight: Metrics.NewTab.chatCardHeight, alignment: .topLeading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: card)
            // The whole card, its rounded rect, is what the chat's cover
            // zooms out of and back into (the sheets behind stay put).
            .matchedTransitionSource(id: chat.id, in: cards) { source in
                source.background(Color(uiColor: .secondarySystemGroupedBackground)).clipShape(card)
            }
            .background(alignment: .top) { stack }
            .contentShape(card)
        }
        .buttonStyle(.plain)
        .opacity(leaving ? 0.4 : 1)
        .overlay(alignment: .topTrailing) {
            if leaving {
                Glyph(mac: .yabArchive, size: 18, color: Ink.secondary)
                    .padding(Metrics.NewTab.chatCardPadding)
                    .transition(.opacity)
            }
        }
        .animation(Motion.columnRows.current, value: leaving)
        .contentShape(.contextMenuPreview, card)
        .contextMenu { menu }
        // Where a chat from the Now line goes back into, by ‹ (ChatFlow.openHistory).
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { app.chatSheet.rowFrames[chat.id] = $0 }
        .accessibilityIdentifier("newtab.chat.\(chat.id)")
    }

    /// As the Mac's chat list has it: open, copy, keep, rename, archive,
    /// stop, delete (ChatFlow.deleteChat says from where).
    @ViewBuilder private var menu: some View {
        let control = app.canControl(chat.id)
        Button {
            app.openChatFromSpaces(chat.id)
        } label: { item("Open Chat", .yabChatRight) }
        if chat.lastAnswer != nil {
            Button { app.copyAnswer(of: chat.id) } label: { item("Copy Answer", .yabCopyframeText) }
        }
        Divider()
        Button { app.setPinned(chat.id, !chat.pinned) } label: {
            item(chat.pinned ? "Unpin Chat" : "Pin Chat", chat.pinned ? .pinSlash : .pin)
        }
        MoveToProjectMenu(chat: chat)
        Button { app.setUnread(chat.id, !chat.unread) } label: {
            item(chat.unread ? "Mark as Read" : "Mark as Unread", chat.unread ? .yabChat : .yabChatDot)
        }
        Button(action: rename) { item("Rename Chat\u{2026}", .pencil) }
        if chat.archived {
            Button { app.unarchive(chat.id) } label: { item("Unarchive Chat", .yabArchiveUp) }
        } else {
            Button { app.archive(chat.id) } label: { item("Archive Chat", .yabArchive) }
        }
        if below > 0, !chat.archived {
            Button(action: archiveBelow) { item("Archive Older\u{2026}", .yabArchiveDown) }
        }
        if control, chat.working {
            Button { app.stopChat(chat.id) } label: { item("Stop", .yabStop) }
        }
        if app.canDelete(chat.id) {
            Divider()
            Button(role: .destructive, action: delete) { item("Delete Chat\u{2026}", .trash) }
        }
    }

    private func item(_ title: String, _ glyph: MacGlyph) -> some View {
        Label {
            Text(title)
        } icon: {
            if let image = UIImage.menuGlyph(glyph) { Image(uiImage: image) }
        }
    }
}

private struct NewChatRow: View {
    @Environment(AppModel.self) private var app
    let cards: Namespace.ID

    var body: some View {
        let row = RoundedRectangle(cornerRadius: Metrics.NewTab.chatCardRadius, style: .continuous)
        Button {
            app.newChatFromSpaces()
        } label: {
            HStack(spacing: Metrics.FieldCard.rowGap) {
                NewChatMark()
                Text("New Chat")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: 0)
            }
            .padding(Metrics.NewTab.rowPadding)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
            // The new chat's cover zooms out of the row and back into it.
            .matchedTransitionSource(id: ChatPagePresentation.newChat, in: cards) { source in
                source.clipShape(row)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("newtab.chats.new")
    }
}

/// New Chat's mark in its row: the Mac's square and pencil in a light circle.
struct NewChatMark: View {
    var body: some View {
        Image("MacSquareAndPencil")
            .renderingMode(.template)
            .resizable()
            .frame(width: 22, height: 22)
            .foregroundStyle(Ink.primary)
            .frame(width: Metrics.Chats.rowIconBox, height: Metrics.Chats.rowIconBox)
            .background(ChatInk.fill(0.08), in: Circle())
    }
}

/// One space's page: its pins as the column draws them, what it keeps and
/// today's tabs, then Now; no titles, the groups apart by space alone.
private struct SpacePage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let space: Space
    let now: [NewTabItem]
    let top: CGFloat
    let bottomRoom: CGFloat
    let pinsWidth: CGFloat

    @State private var open: Set<Folder.ID> = []
    @State private var allPins = false
    /// Todays folded by their line's name: this iPhone's, a Mac's (by its id).
    @State private var folded: Set<String> = []
    /// Macs whose whole list was asked for ("Show all 24").
    @State private var allMac: Set<String> = []
    static let mine = "yab.thisIPhone"
    private var shownPins: [Tab] { app.sync.pins(in: space) }

    var body: some View {
        // A List, not a stack: its rows take the system's own swipe actions.
        List {
            Group {
                // The card's pull rides the list's own pan, from a row of
                // nothing at its head.
                Color.clear.frame(height: 0).background(CardPull(field: app.field))
                let filter = NewTabPager.shared.spaceFilter
                if !shownPins.isEmpty, filter != .today {
                    pins
                        .padding(.horizontal, SpacePagesCard.edge - SpacePagesCard.side)
                        .padding(.top, 16)
                        .padding(.bottom, SpacePage.gap)
                }
                if filter != .today { ForEach(keptRows) { row in kept(row.item, depth: row.depth) } }
                // The column's line between what's kept and today, with Clear.
                // With the Mac's Today on, it says "This iPhone" and the Macs'
                // lines follow this iPhone's Today (docs/iphone-mac-tabs.md).
                let today = filter == .pins ? [] : space.today.filter { !$0.isPrivate }
                let macs = SettingsStore.shared.macTabs && filter != .pins ? app.sync.macToday(in: space.id) : []
                let mineFolded = !macs.isEmpty && folded.contains(Self.mine)
                if (!space.kept.isEmpty && filter == .everything) || !today.isEmpty || !macs.isEmpty {
                    TodayLine(clear: !today.isEmpty && !mineFolded, spaceID: space.id, isPrivate: false, separator: !space.kept.isEmpty,
                              label: macs.isEmpty ? nil : "This iPhone", folded: mineFolded, fold: { toggle(Self.mine) },
                              action: {
                                  Haptics.play(.rigid, reason: Haptics.Reason.clear)
                                  Task { @MainActor in await app.tabClear.clear(in: space.id) }
                              })
                    .frame(height: Metrics.Column.lineHeight)
                    .padding(.vertical, Metrics.Column.lineMargin)
                    // The line starts and Clear ends on the content edge, 24 in.
                    .padding(.horizontal, SpacePagesCard.edge - SpacePagesCard.side - Metrics.Column.rowPadding)
                    // Clear's dust, made ready before Clear can be pressed.
                    .onAppear { if !today.isEmpty { TodayDust.shared.warm() } }
                }
                if !mineFolded {
                    ForEach(today) { tab in
                        tabRow(tab, subtitle: tab.addressHost)
                            .modifier(TodayDustFold(id: tab.id))
                    }
                }
                ForEach(macs) { line in macLine(line) }
                // Now, less what this page shows already: the tab open on the
                // Mac is often one of the space's own, in its row above, and
                // with the Mac's Today on it leads the Mac's line instead.
                let pageNow = now.filter { $0.id != "mac" } + (NewTabContent.macNow(app, in: space.id).map { [$0] } ?? [])
                let others = pageNow.filter { item in
                    if !macs.isEmpty, item.id == "mac" { return false }
                    if case let .go(id) = item.action { return space.tab(id) == nil }
                    return true
                }
                if !others.isEmpty {
                    Color.clear.frame(height: SpacePage.gap)
                    ForEach(others) { item in
                        Button { app.choose(item) } label: {
                            NewTabRowView(icon: item.icon, title: item.title, subtitle: item.subtitle)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: SpacePagesCard.side, bottom: 0, trailing: SpacePagesCard.side))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .contentMargins(.bottom, bottomRoom, for: .scrollContent)
        .modifier(UnderCapsule(top: top))
        // Where today's rows can be seen: under the capsule, over the field.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            TodayDust.shared.visible[space.id] = CGRect(x: frame.minX, y: frame.minY + top, width: frame.width,
                                              height: max(0, frame.height - top - bottomRoom))
        }
        .onAppear {
            guard NewTabPager.shared.startFolded, space.id == app.browser.spaceID else { return }
            NewTabPager.shared.startFolded = false
            folded.insert(Self.mine)
        }
        .contextMenu {
            Button("New Folder", systemImage: "folder.badge.plus") { app.tabEdits.begin(.newFolder(space.id, nil, nil)) }
        }
        .accessibilityIdentifier("newtab.space.\(space.id)")
    }

    static let gap: CGFloat = 16

    /// The column's pin grid: across the whole width, at most five a row,
    /// rows as even as they can be, "+N more" past three rows.
    private var pins: some View {
        let grid = PinGrid(pins: shownPins, open: allPins || space.pinsOpen, width: pinsWidth)
        return ZStack(alignment: .topLeading) {
            ForEach(grid.cells) { cell in
                PinHold(tab: { if case let .pin(tab) = cell.kind { return tab }; return nil }(), content: AnyView(pinCell(cell)))
                    .frame(width: cell.frame.width, height: cell.frame.height)
                    .offset(x: cell.frame.minX, y: cell.frame.minY)
            }
        }
        .frame(width: pinsWidth, height: grid.height, alignment: .topLeading)
    }

    private func pinCell(_ cell: PinGrid.Cell) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.Column.pinRadius, style: .continuous)
        let open: Bool = { if case let .pin(tab) = cell.kind { return tab.id == space.current }; return false }()
        return Button {
            switch cell.kind {
            case let .pin(tab): app.chooseFromSpacePage(tab.id, in: space.id)
            case .more: withAnimation(Motion.columnRows.animation) { allPins = true }
            }
        } label: {
            Group {
                switch cell.kind {
                case let .pin(tab):
                    Favicon(icon: tab.icon, host: tab.addressHost, size: Metrics.Column.pinIcon, url: tab.navigationURL, isPrivate: tab.isPrivate, mark: tab.customMark)
                case let .more(n):
                    Text("+\(n)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.primary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The pin open in this space stands out as the Mac's selected pin: whole white, a shade under it.
            .background(shape.fill(Color.white.opacity(open ? 1 : 0.55)).shadow(color: .black.opacity(open ? 0.08 : 0), radius: 3, y: 1))
            .overlay(shape.strokeBorder(Color.black.opacity(open ? 0.08 : 0.04), lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .frame(width: cell.frame.width, height: cell.frame.height)
        .contentShape(.contextMenuPreview, shape)
        .accessibilityLabel({ if case let .pin(tab) = cell.kind { return tab.name ?? tab.site }; return "More pins" }())
        .accessibilityIdentifier({ if case let .pin(tab) = cell.kind { return "newtab.pin.\(tab.id)" }; return "newtab.pin.more" }())
    }

    /// The kept as rows, each folder's open ones under it: one row each, so
    /// a tab in a folder swipes as any other.
    private var keptRows: [KeptRow] {
        var out: [KeptRow] = []
        func walk(_ items: [KeptItem], _ depth: Int) {
            for item in items {
                out.append(KeptRow(item: item, depth: depth))
                if case let .folder(folder) = item, open.contains(folder.id) { walk(folder.items, depth + 1) }
            }
        }
        walk(space.kept, 0)
        return out
    }

    private struct KeptRow: Identifiable {
        var item: KeptItem
        var depth: Int
        var id: KeptItem.ID { item.id }
    }

    @ViewBuilder private func kept(_ item: KeptItem, depth: Int) -> some View {
        switch item {
        case let .tab(tab):
            tabRow(tab, subtitle: tab.addressHost, indent: CGFloat(depth) * 32)
        case let .folder(folder):
            let isOpen = open.contains(folder.id)
            Button {
                Haptics.play(.selection, reason: Haptics.Reason.rowAction)
                withAnimation((isOpen ? Motion.folderShut : Motion.folderOpen).animation) {
                    if isOpen { open.remove(folder.id) } else { open.insert(folder.id) }
                }
            } label: {
                HStack(spacing: Metrics.FieldCard.rowGap) {
                    FolderMark(mark: folder.customMark, open: isOpen, tint: space.folderGround(dark: scheme == .dark),
                               dark: scheme == .dark, size: Metrics.FieldCard.rowIconColumn, color: folder.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name).font(.callout.weight(.semibold)).foregroundStyle(Ink.primary)
                        Text(KeptTree.tabs(folder.items).count == 1 ? "1 tab" : "\(KeptTree.tabs(folder.items).count) tabs")
                            .font(.footnote).foregroundStyle(Ink.rowSubtitle)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.rowSubtitle)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(Metrics.NewTab.rowPadding)
                .frame(minHeight: Metrics.NewTab.row)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(depth) * 32)
            .contextMenu {
                if app.sync.mayEditFolder(folder.id, in: space.id) {
                    Button("Rename Folder", systemImage: "pencil") { app.tabEdits.begin(.folder(space.id, folder)) }
                    if depth + 1 < KeptTree.deepest {
                        Button("New Folder", systemImage: "folder.badge.plus") { app.tabEdits.begin(.newFolder(space.id, folder.id, nil)) }
                    }
                    Button("Delete Folder", systemImage: "trash", role: .destructive) {
                        guard TabEdits.isCurrentSpace(space.id, in: app),
                              app.browser.space(space.id)?.folders.first(where: { $0.id == folder.id }) == folder else { return }
                        _ = app.browser.deleteFolder(folder.id, in: space.id)
                        app.sync.flushLocal()
                    }
                }
            }
            .accessibilityIdentifier("newtab.folder.\(folder.id)")
            .accessibilityValue(isOpen ? "open" : "closed")
        }
    }

    private func toggle(_ key: String) {
        Haptics.play(.selection, reason: Haptics.Reason.rowAction)
        withAnimation(Motion.columnRows.animation) {
            if folded.contains(key) { folded.remove(key) } else { folded.insert(key) }
        }
    }

    /// A Mac's line and its Today in this space: the first five, its tab in
    /// front first, then "Show all N"; folded, how many at the line's end.
    @ViewBuilder private func macLine(_ line: MacTodayLine) -> some View {
        let shut = folded.contains(line.id)
        TodayLine(clear: false, spaceID: space.id, isPrivate: false, label: line.name, folded: shut,
                  fold: { toggle(line.id) }, note: MacToday.note(line, folded: shut))
            .frame(height: Metrics.Column.lineHeight)
            .padding(.vertical, Metrics.Column.lineMargin)
            .padding(.horizontal, SpacePagesCard.edge - SpacePagesCard.side - Metrics.Column.rowPadding)
        if !shut {
            let shown = MacToday.visible(line, all: allMac.contains(line.id))
            ForEach(shown.rows) { row in
                MacTabRow(row: row, up: line.state.isUp, space: space.id)
            }
            if let all = shown.more {
                Button {
                    Haptics.play(.selection, reason: Haptics.Reason.rowAction)
                    withAnimation(Motion.columnRows.animation) { _ = allMac.insert(line.id) }
                } label: {
                    HStack(spacing: Metrics.FieldCard.rowGap) {
                        Color.clear.frame(width: Metrics.FieldCard.rowIconColumn, height: 1)
                        Text("Show all \(all)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Ink.rowSubtitle)
                        Spacer(minLength: 0)
                    }
                    .padding(Metrics.NewTab.rowPadding)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("newtab.mac.more.\(line.id)")
            }
        }
    }

    private func tabRow(_ tab: Tab, subtitle: String, indent: CGFloat = 0) -> some View {
        // The tab open in this space wears the selected row's plate, as the
        // Mac's column marks it and the field marks its best row.
        let open = tab.id == space.current
        return Button { app.chooseFromSpacePage(tab.id, in: space.id) } label: {
            NewTabRowView(icon: .favicon(key: tab.icon, host: tab.host), title: tab.short, subtitle: subtitle, tab: tab)
                .background(open ? Color.white.opacity(scheme == .dark ? 0.12 : 0.6) : Color.clear,
                            in: RoundedRectangle(cornerRadius: Metrics.NewTab.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(open ? .isSelected : [])
        .modifier(TabHold(tab: tab, list: tab.place == .kept ? .kept : .today))
        .accessibilityIdentifier("newtab.tab.\(tab.id)")
        .padding(.leading, indent)
        .modifier(SpaceTabSwipes(tab: tab))
    }
}

/// One of the Mac's tabs of today on a space's page. A tap opens a copy at
/// the top of this iPhone's Today; the Mac's tab stays. Held: Open Here,
/// Copy Link, Share, Close on Mac. The one in front there wears the
/// selected row's plate.
private struct MacTabRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let row: MacTodayRow
    let up: Bool
    let space: Space.ID

    var body: some View {
        let tab = SyncMapping.tab(row.tab, id: row.tab.id, old: nil, fixturesEnabled: app.fixturesEnabled)
        Button { if !row.closing { app.openFromMac(row.tab, in: space) } } label: {
            NewTabRowView(icon: .favicon(key: tab.icon, host: tab.host), title: tab.short,
                          subtitle: MacToday.subtitle(row, up: up, host: tab.addressHost))
                .background(row.front ? Color.white.opacity(scheme == .dark ? 0.12 : 0.6) : Color.clear,
                            in: RoundedRectangle(cornerRadius: Metrics.NewTab.rowRadius, style: .continuous))
                .opacity(row.closing ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(row.closing)
        .contextMenu { if !row.closing { menu(tab) } }
        .accessibilityIdentifier("newtab.mac.\(row.tab.id)")
    }

    @ViewBuilder private func menu(_ tab: Tab) -> some View {
        Section {
            item("Open Here", .yabTabsPlus) { app.openFromMac(row.tab, in: space) }
            item("Copy Link", .link) { app.copyLink(of: tab) }
            item("Share", .yabShare) { app.share(tab) }
        }
        Section {
            Button(role: .destructive) { app.sync.closeOnMac(row.tab) } label: {
                Text("Close on Mac")
                if !up { Text("When your Mac wakes") }
                glyph(.yabTabX)
            }
        }
    }

    private func item(_ title: String, _ name: MacGlyph, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label { Text(title) } icon: { glyph(name) } }
    }

    private func glyph(_ name: MacGlyph) -> Image {
        UIImage.menuGlyph(name).map { Image(uiImage: $0) } ?? Image(systemName: "circle")
    }
}

/// The typed rows in New Tab's card: groups in reverse as one list, no
/// titles or gaps, best lowest over the field; each row rises
/// from the field a beat after the one under it.
private struct TypedRows: View {
    @Environment(AppModel.self) private var app
    let rows: [WordRow]
    let shown: Bool
    let dark: Bool
    let bottomRoom: CGFloat
    /// The best row's fill: the space's color, deepened.
    let fill: Color
    @State private var rowsHeight: CGFloat = 0

    /// Lines from the bottom: the best row is 0.
    private static func order(_ groups: [WordGroup]) -> [String: Int] {
        var order: [String: Int] = [:]
        var k = 0
        for group in groups.reversed() {
            for entry in group.rows { order[entry.row.id] = k; k += 1 }
        }
        return order
    }

    var body: some View {
        let groups = Array(Words.grouped(rows).reversed())
        let order = Self.order(groups)
        let answer = shown ? app.fieldAnswer : nil
        let keyCopies = answer != nil && app.fieldAnswerTakesKey
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            // The words' answer on a plate of its own over the rows (FieldAnswer).
            if let answer {
                AnswerPlate(answer: answer, words: app.field.words, lit: keyCopies ? fill : nil, dark: dark,
                            copy: app.copyFieldAnswer)
                    .layoutPriority(2)
                    .padding(.bottom, Metrics.FieldCard.linesOverField)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
            }
            // The card is as tall as its rows, and never past the capsule:
            // more rows scroll inside it, the best one kept in sight.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    // One list: the groups keep their order, with no gaps between them.
                    ForEach(groups) { group in
                        ForEach(group.rows.reversed()) { entry in
                            Button { app.choose(entry.row) } label: {
                                WordRowView(row: entry.row, best: entry.index == 0 && !keyCopies, dark: dark, isPrivate: app.field.isPrivate)
                            }
                            .buttonStyle(WordRowPress(best: entry.index == 0 && !keyCopies, fill: fill))
                            .accessibilityIdentifier(entry.index == 0 ? "field.best" : "field.row.\(entry.index)")
                            .modifier(Rise(shown: shown, step: order[entry.row.id] ?? 0))
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                .background(CardPull(field: app.field))
            }
            .defaultScrollAnchor(.bottom)
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollIndicators(.hidden)
            .frame(maxHeight: rowsHeight > 0 ? rowsHeight : .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.FieldCard.lineRadius, style: .continuous))
            // One card for all the rows, 8 from the screen as the field is:
            // Liquid Glass, there only while rows are (it leaves with them).
            .padding(Metrics.FieldCard.linesPadding)
            .background {
                if shown {
                    Color.clear
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.FieldCard.linesRadius, style: .continuous))
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
                }
            }
            .animation(Motion.disabled ? nil : Motion.typedRows.animation, value: shown)
            .layoutPriority(1)
        }
        .animation(Motion.disabled ? nil : Motion.typedRows.animation, value: answer == nil)
        // bottomRoom ends the rows 10 over the field; the card's foot stands 8 over it.
        .padding(EdgeInsets(top: 0, leading: Metrics.NewTab.inset,
                            bottom: bottomRoom - Metrics.Edge.stack + Metrics.FieldCard.linesOverField,
                            trailing: Metrics.NewTab.inset))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("newtab.card")
    }

    private struct Rise: ViewModifier {
        let shown: Bool
        let step: Int

        func body(content: Content) -> some View {
            content
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 12)
                .animation(Motion.disabled ? nil : Motion.typedRows.animation.delay(shown ? Double(min(step, 10)) * 0.025 : 0),
                           value: shown)
        }
    }
}

// MARK: - the capsule

/// The card's capsule: main's capsule itself, its model (CapsuleModel, the
/// approved capsule.js) stepped every frame and its drawing (the recess,
/// the Liquid Glass lens, the names at 45 %), following the card's pages
/// and turning them. A vertical finger on it is the card's own drag.
struct CardCapsule: View {
    typealias C = Metrics.Column
    let names: [String]
    let current: Int
    let position: CGFloat
    let width: CGFloat
    let dark: Bool
    /// The three dots at the right, in place of the gear (it moved to the foot).
    var more = false
    /// In a foot between + and Done: no mark or gear at its sides, the whole width its own.
    var bare = false
    /// One model for the phone's foot: All Tabs' capsule and the sidebar's are
    /// the same capsule, so nothing moves as one hands over to the other.
    var shared: CardCapsuleDriver?
    var pagingByGesture = false
    let pick: (Int) -> Void
    let sheetDrag: (CGFloat, Bool, CGFloat) -> Void
    /// Yab's mark on the left, tapped: About Yab.
    let about: () -> Void
    /// The gear on the right: Settings.
    let settings: () -> Void

    @State private var own = CardCapsuleDriver()
    private var driver: CardCapsuleDriver { shared ?? own }
    @State private var axis: Axis?
    /// Where the capsule stands on the screen: the finger is read in the
    /// screen's own points, which stand still while the spaces follow it down.
    @State private var screenFrame: CGRect = .zero

    var body: some View {
        let pose = driver.pose
        let track = driver.track
        let capsulePosition = driver.fixedPair && !pagingByGesture ? CGFloat(current) : position
        let h = C.barHeight
        let lens = CGRect(x: pose.lensCenter - pose.lensWidth / 2, y: (h - CapsuleModel.lensHeight) / 2,
                          width: pose.lensWidth, height: CapsuleModel.lensHeight)
        ZStack(alignment: .topLeading) {
            CapsuleRecess(dark: dark)
                // The recess blurs what scrolls under it, as glass does.
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .frame(width: pose.width, height: h)
                .offset(x: pose.left)
            nameTrack(pose: pose, track: track, height: h)
                .frame(width: width, height: h, alignment: .topLeading)
                .mask(alignment: .topLeading) {
                    Capsule(style: .continuous).frame(width: pose.width, height: h).offset(x: pose.left)
                }
                .glassEffect(.regular.tint(Color.white.opacity(dark ? 0.16 : 0.42)),
                             in: LensShape(rect: lens, radius: CapsuleModel.lensHeight / 2, scale: 1 + 0.08 * pose.press))
            // Yab's mark, bare, and Settings' gear on glass at the capsule's
            // sides: they step out as a finger widens it, as the column's buttons do.
            if !bare {
            HStack(spacing: 0) {
                Button(action: about) {
                    YabMark(size: Metrics.NewTab.spacesHeaderMark)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .frame(width: Metrics.touch, height: Metrics.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AboutMarkPress())
                .accessibilityLabel("About Yab")
                .accessibilityIdentifier("newtab.about")
                .offset(x: -12 * pose.side)
                Spacer(minLength: 0)
                Group {
                    if more {
                        SpacesMoreMenu(dark: dark)
                    } else {
                        Button(action: settings) {
                            Glyph(.settingsGear1, size: 22, color: dark ? .white : Ink.primary)
                                .frame(width: Metrics.touch, height: Metrics.touch)
                                .glassEffect(.regular.interactive(), in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("newtab.settings")
                    }
                }
                .offset(x: 12 * pose.side)
            }
            .padding(.horizontal, 12)
            .frame(width: width, height: h)
            .opacity(Double(1 - pose.side))
            .allowsHitTesting(pose.side < 0.5)
            }
        }
        .frame(width: width, height: h)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { screenFrame = $0 }
        .gesture(
            // In the screen's points: the capsule moves down with the spaces
            // as a finger takes them, and in its own points the finger's
            // travel came out short, so the spaces sprang back up.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { v in
                    if axis == nil, max(abs(v.translation.width), abs(v.translation.height)) > 8 {
                        axis = abs(v.translation.height) > abs(v.translation.width) ? .vertical : .horizontal
                        if axis == .vertical { driver.cancel() }
                    }
                    if axis == .vertical { sheetDrag(v.translation.height, false, 0); return }
                    // Names move only while the capsule stands still: its own x.
                    if !driver.touching { driver.down(v.startLocation.x - screenFrame.minX) }
                    driver.move(v.location.x - screenFrame.minX)
                }
                .onEnded { v in
                    defer { axis = nil }
                    if axis == .vertical { sheetDrag(v.translation.height, true, v.velocity.height); return }
                    if !driver.touching { driver.down(v.startLocation.x - screenFrame.minX) }
                    if let i = driver.up(v.location.x - screenFrame.minX) { pick(i) }
                }
        )
        .onAppear { driver.configure(names: names, current: current, width: width, bare: bare) }
        .onChange(of: names) { _, now in driver.configure(names: now, current: current, width: width, bare: bare) }
        .onChange(of: width) { _, now in driver.configure(names: names, current: current, width: now, bare: bare) }
        .onChange(of: capsulePosition) { _, now in driver.follow(now, index: current, followingPageDrag: pagingByGesture) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("newtab.capsule")
    }

    private func nameTrack(pose: CapsulePose, track: CapsuleTrack, height: CGFloat) -> some View {
        let edge = CapsuleModel.edge / max(1, pose.width)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                if track.widths.indices.contains(i) {
                    let d = min(1, abs(CGFloat(i) - pose.f))
                    Text(name)
                        .font(.system(size: C.nameInCapsuleFont, weight: .semibold))
                        .tracking(C.nameTracking * C.nameInCapsuleFont)
                        .foregroundStyle(dark ? Color.white : Ink.primary)
                        .lineLimit(1)
                        .fixedSize()
                        .opacity(Double(1 - 0.55 * d))
                        .frame(width: track.widths[i], height: C.nameHeight)
                        .position(x: pose.trackX + track.centers[i], y: height / 2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(name)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityValue(i == current ? "current" : "")
                        .accessibilityAction { pick(i) }
                }
            }
        }
        .mask(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: pose.fadeLeft ? .clear : .black, location: 0),
                                   .init(color: .black, location: pose.fadeLeft ? edge : 0),
                                   .init(color: .black, location: pose.fadeRight ? 1 - edge : 1),
                                   .init(color: pose.fadeRight ? .clear : .black, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: pose.width, height: height)
                .offset(x: pose.left)
        }
    }
}

/// Steps the capsule's model on the screen's refresh while anything moves.
@MainActor
@Observable
final class CardCapsuleDriver {
    /// The phone's foot capsule, All Tabs' and the sidebar's.
    static let foot = CardCapsuleDriver()

    private(set) var pose = CapsulePose.rest(mid: 0)
    @ObservationIgnored private(set) var track = CapsuleTrack(names: [])
    @ObservationIgnored private var model = CapsuleModel(track: CapsuleTrack(names: []), current: 0, mid: 0,
                                                         restWidth: 246, wideWidth: 362, pair: false)
    @ObservationIgnored private var names: [String] = []
    @ObservationIgnored private var width: CGFloat = 0
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var proxy: LinkProxy?
    @ObservationIgnored private var lastTime: CFTimeInterval = 0
    @ObservationIgnored private var lastTicks = 0

    var touching: Bool { model.isTouched }
    var fixedPair: Bool { model.fixedPair }

    func configure(names: [String], current: Int, width: CGFloat, bare: Bool = false) {
        guard names != self.names || abs(width - self.width) > 0.5 else { return }
        self.names = names
        self.width = width
        track = CapsuleTrack(names: names)
        model = CapsuleModel(track: track, current: current, mid: width / 2,
                             // At rest it keeps 24 clear of Yab's mark and the gear (12 in, 44 wide);
                             // bare between + and Done, the room between them is all its own.
                             restWidth: bare ? width : min(Metrics.Column.barWidth - Metrics.Column.capsuleInset * 2, width - 2 * (12 + Metrics.touch + 24)),
                             wideWidth: bare ? width : min(Metrics.Column.barWidth, width - 24), pair: names.count == 2,
                             fixedWidth: bare)
        publish()
    }

    func follow(_ position: CGFloat, index: Int, followingPageDrag: Bool) {
        guard !model.isTouched else { return }
        model.follow(position, index: index, followingPageDrag: followingPageDrag)
        run()
    }

    func down(_ x: CGFloat) { model.down(x, now: model.time); run() }
    func move(_ x: CGFloat) { model.move(x, now: model.time); run() }
    func cancel() { model.cancel(); run() }

    /// The finger lifted: the page to go to, if a name was chosen or thrown to.
    func up(_ x: CGFloat) -> Int? {
        let event = model.up(x)
        run()
        switch event {
        case .pressCurrent?:
            Haptics.play(.soft, reason: Haptics.Reason.lensPress)
            return nil
        case let .tap(i)?, let .release(i)?: return i
        default: return nil
        }
    }

    private func run() {
        publish()
        guard link == nil else { return }
        let proxy = LinkProxy { [weak self] link in self?.tick(link) }
        let link = CADisplayLink(target: proxy, selector: #selector(LinkProxy.fire(_:)))
        link.add(to: .main, forMode: .common)
        self.proxy = proxy
        self.link = link
        lastTime = 0
    }

    private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTime == 0 ? 1.0 / 60 : min(0.05, now - lastTime)
        lastTime = now
        model.step(CGFloat(dt))
        if model.ticks != lastTicks {
            lastTicks = model.ticks
            Haptics.play(.selection, reason: Haptics.Reason.spaceUnderLens)
        }
        publish()
        if model.isSettled {
            link.invalidate()
            self.link = nil
            proxy = nil
        }
    }

    private func publish() { pose = CapsulePose(model) }

    private final class LinkProxy: NSObject {
        let action: (CADisplayLink) -> Void
        init(_ action: @escaping (CADisplayLink) -> Void) { self.action = action }
        @objc func fire(_ link: CADisplayLink) { action(link) }
    }
}

// MARK: - a page's list under the capsule

/// A page's list starts under the capsule and scrolls on under it to the
/// very top of the screen, nothing over it there but the capsule's own
/// blurring recess.
private struct UnderCapsule: ViewModifier {
    let top: CGFloat

    func body(content: Content) -> some View {
        content
            .safeAreaBar(edge: .top, spacing: 0) { Color.clear.frame(height: top).allowsHitTesting(false) }
            // No edge of the system's: it blurs too much, at the head and the foot.
            .scrollEdgeEffectHidden(true, for: .all)
            // Short lists bounce too, so a finger on them can take the screen down.
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollIndicators(.hidden)
    }
}

/// A page's list and the screen share one finger, as a sheet and its list
/// do: down at the list's top takes the screen back toward the plate with
/// the finger, and up again brings it back before the list scrolls.
private struct CardPull: UIViewRepresentable {
    let field: FieldModel

    func makeUIView(context: Context) -> CardPullView { CardPullView() }
    func updateUIView(_ view: CardPullView, context: Context) { view.field = field }
}

final class CardPullView: UIView {
    weak var field: FieldModel?
    private weak var scroll: UIScrollView?
    private var lastY: CGFloat = 0
    private var lastOffset: CGFloat = 0
    private var holding = false
    private var mayLower = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        var view = superview
        while let v = view, !(v is UIScrollView) { view = v.superview }
        guard let found = view as? UIScrollView, found !== scroll else { return }
        scroll?.panGestureRecognizer.removeTarget(self, action: #selector(pan(_:)))
        scroll = found
        found.panGestureRecognizer.addTarget(self, action: #selector(pan(_:)))
    }

    /// Runs after the list's own pan has moved it: what the screen takes, the
    /// list gives back, so the two never move at once.
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard let scroll, let field else { return }
        let y = gesture.translation(in: nil).y
        switch gesture.state {
        case .began:
            lastY = y
            lastOffset = scroll.contentOffset.y
            holding = false
            // A first pull puts the keyboard away; only a new pull folds the screen.
            mayLower = field.canLower || field.isLowering
            if !field.resting { field.putKeyboardAway() }
        case .changed:
            let dy = y - lastY
            lastY = y
            let atTop = lastOffset <= -scroll.adjustedContentInset.top + 0.5
            let lowered = field.isLowering && (field.reveal < 1 || (field.inSheet && field.sheetExpand < 1))
            holding = mayLower && ((dy > 0 && atTop && (field.isLowering || field.canLower)) || (dy < 0 && lowered) || (dy == 0 && holding))
            if holding {
                if !field.isLowering { field.beginLower() }
                field.lowerMoved(by: dy)
                scroll.contentOffset.y = lastOffset
            } else {
                lastOffset = scroll.contentOffset.y
            }
        case .ended, .cancelled, .failed:
            // The throw that moved the screen doesn't carry the list on.
            if holding { scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: lastOffset), animated: false) }
            holding = false
            if field.isLowering { field.lowerEnded(velocity: gesture.velocity(in: nil).y) }
        default: break
        }
    }
}

// MARK: - holding a tab

/// A hold on a tab's row or pin: the column's hold, iOS's own way. The row
/// lifts with its page's picture over it, the column's menu under it (Copy
/// Link, Share, Open on Mac; Keep or Unkeep, Move to Space, Ask About Page;
/// Close Tab), each with the column's glyph.
struct TabHold: ViewModifier {
    @Environment(AppModel.self) private var app
    let tab: Tab?
    let list: ColumnLayout.List

    func body(content: Content) -> some View {
        if let tab {
            content.contextMenu {
                menu(tab)
            } preview: {
                TabHoldPreview(tab: tab, picture: app.pages.snapshots[tab.id], pool: app.pages)
            }
        } else {
            content
        }
    }

    @ViewBuilder private func menu(_ tab: Tab) -> some View {
        let column = ColumnState.of(app)
        Section {
            if app.workspace.canSplit, !tab.isPrivate, !tab.isMail, tab.id != app.browser.tab?.id, app.browser.space.tab(tab.id) != nil {
                item("Open Beside", .yabSplitPlus) { app.openTabBeside(tab) }
            }
            item("Copy Link", .link) { app.copyLink(of: tab) }
            item("Share", .yabShare) { app.share(tab) }
            if !tab.isPrivate {
                item("Open on Mac", .yabLaptopRight) {
                    if app.isFixture { app.say("Opened on \(app.macName)", glyph: .macbook) } else { app.sync.openOnMac(tab) }
                }
            }
        }
        if !tab.isPrivate {
            Section {
                if list != .today, !tab.isMail, let space = app.browser.space(holding: tab.id) {
                    item("Rename…", .pencil) { app.tabEdits.begin(.tab(space.id, tab)) }
                }
                MoveToFolderMenu(tab: tab)
                if list == .pins {
                    if !tab.isMail { item("Unpin", .pinSlash) { column.unpin(tab.id) } }
                } else {
                    item("Pin", .pin) { column.pin(tab.id) }
                }
                if list == .today {
                    item("Keep", .yabAnchor) { column.keep(tab.id) }
                } else if list != .pins {
                    item("Unkeep", .anchor) { column.unkeep(tab.id) }
                }
                let home = app.browser.space(holding: tab.id)?.id
                let others = app.browser.spaces.filter { !$0.isPrivate && $0.id != home }
                if !others.isEmpty {
                    Menu {
                        ForEach(others) { space in
                            Button("\(space.emoji) \(space.name)") { column.move(tab.id, to: space.id) }
                        }
                    } label: {
                        Label { Text("Move to Space") } icon: { glyph(.square2Layers3d) }
                    }
                }
                item("Ask About Page", .yabChatSpark) { Self.ask(tab, app: app) }
            }
        }
        Section {
            item("Close Tab", .yabTabX) { column.close(tab.id) }
        }
    }

    private func item(_ title: String, _ name: MacGlyph, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label { Text(title) } icon: { glyph(name) } }
    }

    private func glyph(_ name: MacGlyph) -> Image {
        UIImage.menuGlyph(name).map { Image(uiImage: $0) } ?? Image(systemName: "circle")
    }

    /// Ask About Page: the tab in front, then the field to ask about it.
    static func ask(_ tab: Tab, app: AppModel) {
        app.browser.select(tab.id)
        app.surfaces.closeField()
        let screen = app.screenSize
        Task { @MainActor [app] in
            if !Motion.disabled { try? await Task.sleep(for: .seconds(Metrics.Column.askDelay)) }
            let plate = ChromeGeometry(size: screen, folded: false, hasNow: app.nowItem != nil).plate
            Motion.fieldOpen.run { app.surfaces.openField(.address, from: plate) }
        }
    }
}

/// The held tab: its page's picture over its row, as the column's hold card.
struct TabHoldPreview: View {
    let tab: Tab
    let picture: UIImage?
    let pool: WebPool

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let picture {
                    Image(uiImage: picture).resizable().scaledToFill()
                } else {
                    TabHoldPage(tab: tab, pool: pool)
                }
            }
            .frame(width: 340, height: Metrics.Hold.tabSketch, alignment: .top)
            .clipped()
            HStack(spacing: 12) {
                Favicon(icon: tab.icon, host: tab.addressHost, size: 22, url: tab.navigationURL, isPrivate: tab.isPrivate, mark: tab.customMark)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.short).font(.callout.weight(.semibold)).foregroundStyle(Ink.primary).lineLimit(1)
                    Text(tab.addressHost).font(.footnote).foregroundStyle(Ink.rowSubtitle).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(width: 340, height: Metrics.Hold.tabRow)
            .background(Color(uiColor: .systemBackground))
        }
    }
}

/// A cold held tab uses the pool's store and blocker, and gives its page
/// back when the menu closes. No second, unblocked preview configuration.
struct TabHoldPage: UIViewRepresentable {
    let tab: Tab
    let pool: WebPool

    @MainActor final class Coordinator {
        var task: Task<Void, Never>?
        var borrowed: (WebPool, Tab.ID)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.isUserInteractionEnabled = false
        host.clipsToBounds = true
        let coordinator = context.coordinator
        coordinator.task = Task { @MainActor [weak host] in
            await pool.shield?.settled()
            guard !Task.isCancelled, let host, let page = pool.borrow(tab) else { return }
            coordinator.borrowed = (pool, tab.id)
            page.frame = host.bounds
            page.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(page)
        }
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {}

    static func dismantleUIView(_ host: UIView, coordinator: Coordinator) {
        coordinator.task?.cancel()
        host.subviews.forEach { $0.removeFromSuperview() }
        if let (pool, id) = coordinator.borrowed { pool.giveBack(id) }
        coordinator.borrowed = nil
    }
}

// MARK: - choosing from a page

extension AppModel {
    /// The spaces' mark and gear: Settings over them, on About Yab for the
    /// mark. The spaces stay under it, keyboard down, and are where it closes to.
    func openSettingsFromSpaces(at page: SettingsPageID?) {
        Haptics.play(.soft, reason: Haptics.Reason.settingsOpen)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        var quiet = Transaction(animation: nil)
        quiet.disablesAnimations = true
        withTransaction(quiet) { SettingsUI.shared.navigation = page.map { [.page($0)] } ?? [] }
        Motion.sheetGrow.run { surfaces.openSettings(keepingField: true) }
    }

    /// A pin or a tab on a space's page: that space comes in front with it.
    func chooseFromSpacePage(_ id: Tab.ID, in space: Space.ID) {
        if browser.space(space)?.tab(id) == nil, sync.openSharedPin(id, in: space) { return }
        field.forget()
        closeFieldAfterChoice()
        if browser.spaceID != space { browser.showSpace(space) }
        browser.select(id)
    }

    /// One of the Mac's tabs of today, from its line on a space's page: a
    /// copy of it at the top of this iPhone's Today in that space. The
    /// Mac's tab stays where it is.
    func openFromMac(_ synced: SyncTab, in space: Space.ID) {
        field.forget()
        closeFieldAfterChoice()
        if browser.spaceID != space { browser.showSpace(space) }
        if let here = browser.space.today.first(where: { !$0.isPrivate && $0.navigationURL?.absoluteString == synced.url }) {
            browser.select(here.id)
            return
        }
        show(SyncMapping.tab(synced, id: PageFixtures.newID(), old: nil, fixturesEnabled: fixturesEnabled), newTab: true)
    }

    /// A chat's card on the Chats page zooms into the chat, a page in its
    /// own cover over the Chats page, which stays as it is (its search words
    /// too); ‹, a pull down or the edge swipe zoom it back (ChatPageCover).
    func openChatFromSpaces(_ id: Chat.ID) {
        openChatPage(id)
    }

    func newChatFromSpaces() {
        newChat(asPage: ChatPagePresentation.newChat)
    }

    /// Keep the browser and its saved selection with the public page on screen.
    /// Address editing only previews spaces; it still belongs to its original tab.
    func selectSpacePage(_ id: Space.ID) {
        guard browser.space(id)?.isPrivate == false else { return }
        NewTabPager.shared.spaceID = id
        if field.mode == .newTab, browser.spaceID != id { browser.showSpace(id) }
    }

    /// Typed words or Now from New Tab open in the space on the card.
    func adoptNewTabSpace() {
        guard field.mode == .newTab, !field.isPrivate, let id = NewTabPager.shared.spaceID,
              id != browser.spaceID, browser.space(id)?.isPrivate == false else { return }
        browser.showSpace(id)
    }
}
