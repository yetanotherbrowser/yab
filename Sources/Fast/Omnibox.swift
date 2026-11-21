import SwiftUI
import AppKit
import Combine

/// One field, in the middle, and the few places it thinks you mean, along
/// with the things the app can do and the pages of its settings, found by
/// name. Type something that is none of those and isn't an address, and it
/// shivers and says so, rather than quietly handing your keystrokes to a
/// search engine.
///
/// The field and its list share a fixed-height surface. Results stand at
/// the top; unused room stays empty, so neither the field nor its foot
/// moves when a query gains or loses results.
struct Omnibox: View {
    let browser: Browser
    @ObservedObject var query: Query
    /// Room on the left outside the active split half; zero otherwise,
    /// so the field stands in the middle of the whole window.
    let inset: CGFloat
    /// Room on the right not the field's: the other half, in split view,
    /// where the field stands over the half in front.
    let trail: CGFloat
    /// Page edges used only by the Compact card. Full keeps its original layout.
    let pageTop: CGFloat
    let pageBottom: CGFloat
    /// Taken as a value, not read off the browser in the body: the browser
    /// is the same object before and after, so a refusal would otherwise
    /// give this view nothing to notice and the field would never shiver.
    let refusals: Int
    /// Over a private tab: the field goes dark, so where you are typing
    /// says, before anything else does, that none of it is being kept.
    let shy: Bool
    /// When this tab went private, if it was the act of going private,
    /// the field plays its part of that moment (see `Stealth`).
    let hushedAt: Date?
    /// A private tab in a normal window: the field says it in its own
    /// words and mask (`Stealth`). A private window says it once, at its
    /// column's foot, and its field is everyone's, only dark.
    let stealth: Bool
    /// Look.apply sets the app's appearance; a window can wear a space's
    /// different Look. Observe the app so every window's field agrees.
    @State private var appAppearance = NSApplication.shared.effectiveAppearance
    /// One pixel of the screen the card is on, for its hairline edge.
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceTransparency) private var solid
    @State private var shake: CGFloat = 0
    @State private var refused = false
    @StateObject private var retainedRows: RetainedFieldRows

    init(browser: Browser, inset: CGFloat, trail: CGFloat = 0, pageTop: CGFloat = 0, pageBottom: CGFloat = 0) {
        self.browser = browser
        self.query = browser.query
        self.inset = inset
        self.trail = trail
        self.pageTop = pageTop
        self.pageBottom = pageBottom
        self.refusals = browser.refusals
        self.shy = browser.windowPurpose.isPrivate(active: (browser.fieldGuest ?? browser.active)?.shy)
        self.hushedAt = (browser.fieldGuest ?? browser.active)?.hushedAt
        self.stealth = shy && browser.windowPurpose == .normal
        self._retainedRows = StateObject(wrappedValue: RetainedFieldRows(browser: browser))
    }

    /// The box's own space, where the field is the top fieldHeight.
    static let box = "omnibox"
    /// The field's own height: its line and the room round it, Raycast's.
    static let fieldHeight: CGFloat = 58
    /// A row's height in the list under it.
    static let rowHeight: CGFloat = 38
    /// Emoji's grid, across.
    static let emojiColumns = 8
    /// A place's own list, Clipboard History's, is this tall whatever it
    /// holds: its preview beside it wants the room.
    static let placeHeight: CGFloat = 352
    /// Under the field, whatever it holds, the box is this tall: it stands
    /// still as rows come and go and its foot never moves (Raycast's 475
    /// less its field).
    static let bodyHeight: CGFloat = 417
    /// A row's picture: a tile of its own, as a launcher's app icons are.
    static let tile: CGFloat = 22
    /// The compact card (Settings › Appearance › Field): this wide, and
    /// as tall as its rows, this many at most before they scroll.
    static let compactWidth: CGFloat = 540
    static let compactRows = 5
    /// Its corners, and its field: smaller than the box's, as the card is.
    /// A row's are the card's less the list's inset, so they run on its curve.
    static let compactCorner: CGFloat = 18
    static let compactFieldHeight: CGFloat = 52
    /// Its rows: taller than the box's and set in closer, as the example's.
    static let compactRowHeight: CGFloat = 40
    static let compactInset: CGFloat = 6
    /// How much of the ground tints the compact card's glass.
    static let compactGlassTint: CGFloat = 0.18
    /// More on a dark card: over a white page the thin material alone left
    /// it light gray under white words.
    static let compactGlassTintDark: CGFloat = 0.45

    // One grid for the field and every row under it, so the mark down the
    // left of each and the words after it stand in two straight columns.
    /// From the surface's edge to the column of marks, on either side.
    static let gutter: CGFloat = 16
    /// The column of marks: the field's glass and each row's kind.
    static let slot: CGFloat = 22
    /// From the marks to the words.
    static let gap: CGFloat = 12
    /// The list's own inset, inside which each row has its highlight.
    static let inset: CGFloat = 8
    /// Every mark, drawn or a site's own icon, at one size: the set's
    /// 24-point square at 12, which is 16 on screen.
    static let mark: CGFloat = 12
    /// The field's own glass, at the head of the field: 20 on screen.
    static let glass: CGFloat = 15
    /// The card's corners: the window's own curve.
    static let corner: CGFloat = Radius.box
    /// The dark ground, lifted: between the ground and a row under the
    /// pointer, so a row's hover still shows on it.
    static let nearer = Color(white: 0.13)

    /// Theme from Settings, independent of the page and the space's Look.
    /// A private field keeps its own dark appearance.
    private var look: ColorScheme { Self.colorScheme(for: appAppearance, privateField: shy) }
    private var normalLook: ColorScheme { Self.colorScheme(for: appAppearance) }

    static func colorScheme(for appearance: NSAppearance, privateField: Bool = false) -> ColorScheme {
        if privateField { return .dark }
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// Drawn as on a dark window.
    private var dim: Bool { look == .dark }

    /// The card's edge: a hairline of ink, white on a dark window, black
    /// on a light one, so a white card
    /// still has its outline on a white page (row 1091).
    private var ring: Color { dim ? .white.opacity(0.12) : .black.opacity(0.13) }
    private var hairline: CGFloat { 1 / max(displayScale, 1) }

    /// The card's two short shadows, both tucked in under it: it sits on
    /// what is behind it rather than floating over it.
    private var tint: Color { dim ? .black.opacity(0.3) : .black.opacity(0.05) }

    /// Where the card last stood in the window's content, top-left origin.
    @MainActor static var card: CGRect = .zero
    @MainActor static var probeCards: [ObjectIdentifier: CGRect] = [:]
    @MainActor static var presentations = 0

    /// Glass for the box: on a Mac that draws it, with transparency left
    /// on. In a private tab too, smoked: always dark, over a thicker
    /// material, the night's color over all of it (see `siteLight`).
    private var glassy: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return !solid
    }
    /// A private box's own color, one for every private box: violet going
    /// to night, over the whole glass as a searched site's color is.
    static let night = Color(red: 0.28, green: 0.16, blue: 0.72)
    /// How much of the box's ground tints its glass, over the material.
    static let glassTint: CGFloat = 0.3

    /// The chosen row: a veil of the ink, lighter on a dark box and darker
    /// on a light one, which the glass still shows through. The rows' wash
    /// is opaque, and put a grey slab over the glass.
    static let chosenFill = Palette.ink.opacity(0.08)
    /// A line in the box, between parts of a list, a list and its preview,
    /// ⌘K's list and its search: a veil of ink, as the address bar's line
    /// is, so the glass shows through it; the hairline's gray lay on the
    /// glass as a line painted on.
    static let seam = Palette.ink.opacity(0.08)
    /// A drawn mark's tile, and every other line of a clip's Information:
    /// the same veil, fainter.
    static let tileFill = Palette.ink.opacity(0.05)

    /// Searching one site, the whole glass takes a breath of its color,
    /// evenly, as if the box were made of it: no band or chip of color at
    /// one side. Up in 0.12 s on Tab and out as the site is left, in the
    /// last site's color, so the fade keeps it. In a private tab the
    /// night's color is there all along, as evenly; a site searched there
    /// tints it its own instead.
    private var siteLight: some View {
        let searching = query.scope != nil
        let color = query.lastTint(dark: dim)
        return ZStack {
            shape.fill(color.opacity(dim ? Self.siteTint.dark : Self.siteTint.light))
                .opacity(searching ? 1 : 0)
            shape.fill(Self.night.opacity(Self.nightTint))
                .opacity(shy && !searching ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.12), value: searching)
        .allowsHitTesting(false)
    }
    /// How much of a searched site's color lies over the glass, on a light
    /// box and a dark one: enough to say whose box it is, never a wash
    /// the rows have to read through.
    static let siteTint = (light: 0.12, dark: 0.16)
    /// The night's color over a private box: less than a site's, so the
    /// box reads dark first and violet only a little.
    static let nightTint = 0.06

    /// The card's own ground, which what scrolls in it fades into.
    private var ground: Color { dim ? Self.nearer : Palette.ground }


    var body: some View {
        GeometryReader { space in
            VStack(spacing: 8) {
                surface(room: compactList ? Self.compactRoom(in: space.size.height, pageTop: pageTop, pageBottom: pageBottom) : Self.placeRoom(in: space.size.height))
            }
                .frame(width: compactList ? min(Self.compactWidth, Self.width(in: space.size.width)) : Self.width(in: space.size.width))
                .animation(nil, value: compactList)
                // A click on the box leaves it up; anywhere else in the
                // window puts it away (Browser.fieldAway).
                .background(ClickZone(away: browser.fieldAway))
                // Lifted a little above center: dead center reads as low,
                // because the strip at the top isn't part of what the eye is
                // measuring. The top edge is what is placed, never the
                // middle of the field and its list together, which rose by
                // half of every row that came.
                .padding(.top, compactList
                    ? Self.compactTop(in: space.size.height, pageTop: pageTop, pageBottom: pageBottom)
                    : Self.top(in: space.size.height))
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .padding(.leading, inset)
        .padding(.trailing, trail)
        .onReceive(NSApplication.shared.publisher(for: \.effectiveAppearance)) { appAppearance = $0 }
    }

    /// The field's width in a space this wide: its own, or, where the page
    /// is narrower than that, the page less a margin on either side, so the
    /// card never runs past the page's edge.
    static func width(in room: CGFloat) -> CGFloat {
        max(0, min(Metrics.fieldWidth, room - 2 * margin))
    }

    /// How tall a place's own list is in a space this tall: its own height,
    /// or less, so the card with its foot ends above the window's; the field
    /// never moves up to make room.
    static func placeRoom(in height: CGFloat) -> CGFloat {
        max(200, min(bodyHeight, height - top(in: height) - fieldHeight - 16))
    }

    /// The least room between the field and the page's sides.
    static let margin: CGFloat = 16

    /// Where the field's top edge stands in a space this tall: the existing
    /// 18% position through 1050 points, then half of any extra height below
    /// its 189-point anchor. In a window too short for that,
    /// the card at its fullest stands in the middle, as much room above it
    /// as below, rather than high with its list pressed to the bottom. The
    /// full card is what is measured, never the rows it has, so the field
    /// stays put as they come and go. A private tab's box too: Private is
    /// one of the field's places, the same card where every other one is.
    static func top(in height: CGFloat) -> CGFloat {
        let preferred = height <= 1050 ? (height * 0.18).rounded() : 189 + (height - 1050) / 2
        return max(16, min(((height - fieldHeight - bodyHeight) / 2).rounded(), preferred))
    }

    /// The middle of the field, as a point of the space it stands in,
    /// what it grows from as ⌘L raises it.
    static func middle(in size: CGSize, inset: CGFloat, trail: CGFloat = 0) -> UnitPoint {
        guard size.width > 0, size.height > 0 else { return .center }
        return UnitPoint(
            x: (inset + (size.width - inset - trail) / 2) / size.width,
            y: (top(in: size.height) + fieldHeight / 2) / size.height
        )
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: compactList ? Self.compactCorner : Self.corner, style: .continuous)
    }

    /// The field's height here: the compact card's over its plain list.
    private var fieldTall: CGFloat { compactList ? Self.compactFieldHeight : Self.fieldHeight }

    /// Whether anything stands under the field: a place, a site's or an
    /// extension's search (its foot), emoji or rows.
    private var hasContent: Bool {
        if compactList, compactRoom == 0 || compactRoom == FieldFoot.room, query.offers.isEmpty || browser.untouched != nil { return false }
        return query.place != nil || query.scope != nil || browser.emojiWords != nil || !query.offers.isEmpty
    }

    /// The small card asked for in Settings › Appearance › Field.
    private var compact: Bool { browser.prefs.compactField }

    /// The compact card over its plain list: as tall as its rows, with no
    /// foot. Only entering a place or an answer opens the full box;
    /// choosing a result with a preview keeps the same compact list. An
    /// empty private tab's field too (row 1027): compact as chosen, with
    /// Private at its foot as a site's search has its name.
    private var compactList: Bool {
        compact && query.place == nil && browser.emojiWords == nil
            && !query.answering && browser.mailEmpty == nil
    }

    /// The compact card's foot, kept under its rows: a site's search says
    /// whose it is; an empty private tab's field, with no rows yet, has
    /// Private, the way back. Its rows come as any compact card's do.
    private var compactFooted: Bool {
        query.scope != nil || (shy && browser.privateLeavable && query.offers.isEmpty)
    }

    /// A fixed expanded list for Compact, including any footer. Both Cmd-T
    /// and Cmd-L reserve five rows even when the query has fewer results.
    static let compactBodyHeight = CGFloat(compactRows) * compactRowHeight + 2 * compactInset

    private var compactRoom: CGFloat {
        if compactList { return Self.compactBodyHeight }
        // Full also observes this value to suppress row animations. Keep
        // its original calculation, including the untouched-address case.
        if browser.untouched != nil { return 0 }
        let count = min(query.offers.count, Self.compactRows)
        let rows = count == 0 ? 0 : CGFloat(count) * Self.compactRowHeight + 2 * Self.compactInset
        return rows + (compactFooted ? FieldFoot.room : 0)
    }

    static func compactRoom(in height: CGFloat, pageTop: CGFloat = 0, pageBottom: CGFloat = 0) -> CGFloat {
        max(0, min(compactBodyHeight, height - pageTop - pageBottom - compactFieldHeight - 2 * margin))
    }

    static func compactTop(in height: CGFloat, pageTop: CGFloat = 0, pageBottom: CGFloat = 0) -> CGFloat {
        let room = compactRoom(in: height, pageTop: pageTop, pageBottom: pageBottom)
        return pageTop + max(0, (height - pageTop - pageBottom - compactFieldHeight - room) / 2)
    }

    private func surface(room: CGFloat) -> some View {
        // The field floats over the top of what the box holds, as the foot
        // does over its bottom: the rows scroll up under it and blur there,
        // a launcher's way, where they were cut at its foot.
        ZStack(alignment: .top) {
            // The same gap as the rows': the field sets its words right at
            // its own edge, so the typed address and the names under it
            // start in one column.
            HStack(spacing: Self.gap) {
                // What the field is for, before a letter is typed: finding.
                // Over a page, while it still says that page's address, it
                // is the page's, its site's mark, until the first key
                // makes it a question again. Swapped, never faded. In a
                // private tab it is a mask, not a glass: what kind of place
                // this is, said where the eye already is.
                if query.answering {
                    // The field is the answer's follow-up now, at its
                    // foot; the way back is at the answer's head.
                    EmptyView()
                } else if query.place != nil || browser.emojiWords != nil {
                    // In a place of the field's own, the way back where the
                    // glass was, as a launcher's command has it; the place's
                    // name is at the foot (FieldFoot).
                    Button { _ = browser.leavePlace() } label: {
                        Symbol("chevron.left", size: 13)
                            .foregroundStyle(Palette.muted)
                            .frame(width: Self.slot, height: Self.slot)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .keyTip("Back")
                    .transition(.identity)
                    .transaction { $0.animation = nil }
                } else if query.scope != nil {
                    // One site's or extension's search, as a place of the
                    // field's own is: the way back where the glass was,
                    // its mark and name at the foot (FieldFoot).
                    Button { _ = browser.leaveScope(restoring: true) } label: {
                        Symbol("chevron.left", size: 13)
                            .foregroundStyle(Palette.muted)
                            .frame(width: Self.slot, height: Self.slot)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .keyTip("Back")
                    .transition(.identity)
                    .transaction { $0.animation = nil }
                } else if shy, browser.privateLeavable {
                    // An empty private field is still a search: the glass
                    // stays. The way back is Private at the foot (FieldFoot),
                    // ⌫ in the empty field, or Escape.
                    Symbol("magnifyingglass", size: Self.glass)
                        .foregroundStyle(Palette.muted)
                        .frame(width: Self.slot)
                        .transition(.identity)
                        .transaction { $0.animation = nil }
                } else if query.actionsPage {
                    // Actions, in the space's color, as Arc's pill.
                    Text("Actions")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Self.spaceTone(browser, dark: dim)))
                        .fixedSize()
                        .transition(.identity)
                        .transaction { $0.animation = nil }
                } else if !compactList || shy {
                Group {
                    if let tab = browser.fieldPage, browser.untouched != nil {
                        Mark(icon: tab.icon, letter: tab.monogram, size: Self.tile - 2)
                    } else if stealth {
                        StealthGlass(since: hushedAt, size: Self.glass)
                    } else {
                        Symbol("magnifyingglass", size: Self.glass)
                            .foregroundStyle(Palette.muted)
                    }
                }
                .frame(width: Self.slot)
                .transition(.identity)
                .transaction { $0.animation = nil }
                }
                AddressField(browser: browser, query: query, dark: shy, hushed: stealth, look: look)
                    .frame(height: 26)
                    .overlay(alignment: .leading) {
                        // The private field's words, drawn over the field
                        // rather than as its placeholder, so they can turn
                        // into the new ones (see `StealthHint`). Gone with
                        // the first key, as a placeholder would be.
                        // Not while a site or a place is searched: then the
                        // field says which, as it does in any tab.
                        if stealth, query.typed.isEmpty, !InputMethod.composing(focused: browser.fieldShowing), browser.untouched == nil, query.scope == nil, query.place == nil {
                            StealthHint(since: hushedAt)
                        }
                        if query.answering, query.typed.isEmpty, !InputMethod.composing(focused: browser.fieldShowing) {
                            Text("Ask a follow-up…")
                                .font(.system(size: 13.5))
                                .foregroundStyle(Palette.muted)
                                .allowsHitTesting(false)
                                // After the words sent have risen out of the field (SendFlight).
                                .transition(.asymmetric(insertion: .opacity.animation(Motion.hintBack), removal: .identity))
                        }
                    }
                if query.place == .clipboard {
                    FieldFilterButton(browser: browser, query: query)
                        .transition(.identity)
                } else if let edit = query.edit {
                    // What is being written, where the filter was.
                    Text(edit.title)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.identity)
                } else if query.place == .files, query.form?.file != nil {
                    // Where Files looks; where ↩ puts the file is said in
                    // the foot, beside Files.
                    FieldFilterButton(browser: browser, query: query)
                        .transition(.identity)
                } else if let target = browser.placeTarget {
                    // Where ↩ will put the chosen row, or why it won't.
                    PlaceTargetView(target: target)
                        .fixedSize()
                        .transition(.identity)
                        .transaction { $0.animation = nil }
                } else if query.place == .bookmarks ? browser.bookmarks.roots.contains(where: \.isFolder) : query.place?.filters.isEmpty == false {
                    // What the list is narrowed to; pressed, the choices drop
                    // from it as Files' folders do.
                    FieldFilterButton(browser: browser, query: query)
                        .transition(.identity)
                } else if let offering = query.offering, query.scope == nil, query.place == nil, browser.emojiWords == nil {
                    // Tab searches the site the words begin, said where the
                    // words are, with its key: the
                    // row stays the place Return goes to.
                    HStack(spacing: 8) {
                        Text("Search \(offering.name)")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                        KeyGlyphs(keys: "⇥", size: 13.5)
                    }
                    .transition(.identity)
                    .transaction { $0.animation = nil }
                } else if let ask = browser.tabAsks {
                    // Tab asks the words at once, said the same way.
                    HStack(spacing: 8) {
                        Text(ask.key)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                        KeyGlyphs(keys: "⇥", size: 13.5) // design: the field end's Tab hint, as the site search one above
                    }
                    .transition(.identity)
                    .transaction { $0.animation = nil }
                } else if compactList, !shy, !query.actionsPage, query.typed.isEmpty || browser.untouched != nil {
                    // The compact card's empty field: Tab has its Actions.
                    HStack(spacing: 8) {
                        Text("Actions")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Palette.muted)
                        KeyGlyphs(keys: "⇥", size: 13.5) // design: the field end's Tab hint, as the site search one above
                    }
                    .transition(.identity)
                    .transaction { $0.animation = nil }
                }
                // Nothing about Return here: its key is on the chosen row
                // and its words in the foot. The field's end says only Tab:
                // the site it searches, or the agent it asks.
            }
            // Under an answer the words sit 14 pt into the capsule, not 8,
            // clear of its round end.
            .padding(.leading, query.answering ? 6 : 0)
            .padding(.horizontal, Self.gutter)
            // Under an answer the field is at the foot, beside the pill, as
            // a chat's is: the same field moved, not another, so the words
            // and the keyboard stay in it (FieldAnswer has the head).
            .frame(height: query.answering ? FieldFoot.room : fieldTall)
            // A row passing under it is neither pointed at nor clicked.
            .contentShape(Rectangle())
            // On glass of the pill's own shape, the pill's height, a pill of
            // its own beside the one Return and ⌘K are on.
            .background {
                if query.answering {
                    FieldGlass(shape: Capsule())
                        .frame(height: FieldFoot.pill)
                        .padding(.leading, 8)
                }
            }
            // Its middle on the pill's (FieldFoot), the pill left to itself.
            .padding(.trailing, query.answering ? query.footPill + 16 : 0)
            .offset(y: query.answering ? room + fieldTall - FieldFoot.room : 0)
            .background {
                // What scrolls under the field, blurred as it passes, the
                // blur gone by the field's foot where the rows stand clear.
                if hasContent, !query.answering {
                    FieldBand()
                        .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false)
                }
            }
            // Under ⌘K's list when it is the follow-up at the foot: the list rises there.
            .zIndex(query.answering && query.acting != nil ? 0 : 1)
            // No line between the field and its rows: the field's shade
            // has already gone back to the ground by its foot, so the rows
            // begin where its light ends.
            // What is under the field is replaced, never faded one into the
            // other; the card keeps the same height even with no rows.
            Group {
                // The foot floats over the bottom of each, which keeps room
                // under its last row to clear it.
                if query.place == .clipboard {
                    ClipPlace(browser: browser, query: query, height: room + fieldTall, ground: ground)
                        .footed(foot)
                } else if query.place == .selection, query.answering {
                    FieldAnswer(browser: browser, commands: browser.selectionCommands, height: room + fieldTall)
                        .footed(foot)
                } else if let place = query.place, place != .emoji, place != .selection, place != .mail {
                    PlaceView(browser: browser, query: query, place: place, height: room + fieldTall)
                        .footed(foot)
                } else if browser.emojiWords != nil {
                    EmojiPlace(browser: browser, query: query, height: room + fieldTall, ground: ground)
                        .footed(foot)
                } else if compactList || !query.offers.isEmpty {
                    // Keep the compact scroll view mounted behind the address
                    // even when its rows have no room. Removing it for Cmd-L
                    // and an empty/closed field rebuilt AppKit's scroll view
                    // and its tracking views in the next Cmd-T opening frame.
                    // One list, whatever stands beside it: a branch of its
                    // own for each side made a new scroll view each time
                    // the chosen row brought or took a side, and the list
                    // jumped back to its top. Pointing at Yab for iPhone,
                    // the row over Set up Yab, did it on every pass (#248).
                    let side = listSide
                    if compactList {
                        // The rows scroll under the field and blur there, as
                        // the box's do, and fade out at the card's foot.
                        list(room: room + fieldTall)
                            .environment(\.fieldBareMarks, true)
                            .frame(height: room + fieldTall)
                            .opacity(room > 0 ? 1 : 0)
                            .allowsHitTesting(room > 0)
                            .accessibilityHidden(room == 0)
                            .footed(foot, shown: compactFooted)
                    } else {
                        GeometryReader { area in
                            let beside = side != nil && area.size.width >= 560
                            HStack(spacing: 0) {
                                // The foot says in words what Return does to
                                // the chosen row, and that ⌘K has the rest.
                                list(room: room + fieldTall)
                                    .frame(width: beside ? side?.width : area.size.width)
                                if beside {
                                    Rectangle()
                                        .fill(Omnibox.seam)
                                        .frame(width: 1)
                                        .belowField()
                                    sideView(side)
                                        .belowField()
                                }
                            }
                        }
                        .frame(height: room + fieldTall)
                        .footed(foot)
                    }
                } else if let empty = browser.mailEmpty {
                    PlaceEmptyView(browser: browser, query: query, empty: empty)
                        .belowField()
                        .frame(height: room + fieldTall)
                        .footed(foot)
                } else if query.scope != nil || shy {
                    // A site's or an extension's search with nothing yet:
                    // empty, its mark and name still at the foot. Private
                    // the same.
                    Color.clear
                        .frame(height: room + fieldTall)
                        .footed(foot)
                }
            }
            .environment(\.underField, fieldTall)
            .environment(\.fieldFooted, !compactList || compactFooted)
            .transition(.identity)
        }
        .frame(height: room + fieldTall, alignment: .top)
        .overlay(alignment: .topLeading) {
            // The models to answer again on drop from the model's name under
            // the answer's title; ⌘K's other
            // lists rise from the foot's corner.
            if query.answering, query.choosingModel, query.acting != nil {
                FieldActionsPanel(browser: browser, query: query)
                    .padding(.leading, FieldAnswer.modelInset)
                    .padding(.top, fieldTall - 10)
                    .transition(.opacity)
            }
        }
        .animation(query.acting == nil ? Motion.depart : Motion.arrive, value: query.acting != nil && query.choosingModel)
        .overlay(alignment: .topTrailing) {
            // What the list is narrowed to drops from the field's end:
            // Files' folders, Clipboard History's kinds, a place's sites.
            if query.place != nil, query.choosingFilter, query.acting != nil {
                FieldActionsPanel(browser: browser, query: query)
                    .padding(.trailing, 8)
                    .padding(.top, fieldTall - 10)
                    .transition(.opacity)
            }
        }
        .animation(query.acting == nil ? Motion.depart : Motion.arrive, value: query.acting != nil && query.choosingFilter)
        .coordinateSpace(.named(Self.box))
        // Lay out results at their final height. In a retained card the
        // hidden, empty field otherwise grows its glass from one line to a
        // full list while opening, resizing backdrop surfaces each frame.
        // The card's arrival still fades as a whole.
        .animation(nil, value: query.offers.count)
        .animation(nil, value: query.place)
        .clipShape(shape)
        .background {
            // The card stands off the page, full and compact: a soft wide shadow round it, never under its glass.
            FieldShadow(shape: shape, dark: dim)
            if #available(macOS 26.0, *), glassy {
                // Liquid Glass where the Mac draws it, over a material: the
                // glass alone let a busy page read through the rows, and its
                // tint barely changes that, from 0.3 to 0.88 alike. The
                // material blurs the page into an even haze of its colors;
                // the glass gives it its rim, its bend and its shadow. Two
                // layers the window server draws; the box is one height, so
                // neither reshapes on a keystroke.
                // Smoked in a private tab: a thicker material, so the page
                // under it is only a dark haze.
                if compactList, !shy {
                    // The compact card: the thinnest material, which takes
                    // the look's light or dark and blurs a page's words out
                    // from under the rows (with none, a dark card's white
                    // words stood on a white page), and the glass over it
                    // with a breath of the ground. The box's thicker
                    // material made it a white slab and hid its edge's bend.
                    shape.fill(.ultraThinMaterial)
                    Color.clear.glassEffect(.regular.tint(ground.opacity(dim ? Self.compactGlassTintDark : Self.compactGlassTint)), in: shape)
                } else {
                    shape.fill(shy ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.regularMaterial))
                    Color.clear.glassEffect(.regular.tint(ground.opacity(Self.glassTint)), in: shape)
                }
                siteLight
            } else {
            // One card, on a blank tab and over a page alike: its ground,
            // a hairline ring and a short shadow close under it, no
            // sheen, no lift. The shadow hangs on the plain shape rather
            // than on the field and its rows, so it is drawn from a rounded
            // rectangle and not from every glyph inside on each keystroke.
            shape
                .fill(dim ? Self.nearer : Palette.ground)
                .shadow(color: tint, radius: 1.5, y: 2)
                .shadow(color: tint, radius: 0.5, y: 1)
            siteLight
            }
            // Going private, the field goes dark with the page, not ahead
            // of it: the card it was, fading off.
            if shy {
                Unveil(since: hushedAt, shape: shape, color: normalLook == .dark ? Self.nearer : .white)
            }
        }
        .overlay(
            // Its edge: a hairline ring, red for a moment when Return had
            // nowhere to go. Searching one site no longer colors it: a ring
            // and a band of the site's color round the glass read as a
            // second frame on it. The site is said by its chip, at the
            // head of the field.
            shape
                .strokeBorder(refused ? Color.red.opacity(0.35) : ring, lineWidth: refused ? 1 : hairline)
                .allowsHitTesting(false)
        )
        .overlay {
            // And a light top edge, the glass catching it.
            if compactList {
                shape.inset(by: 0.5)
                    .stroke(LinearGradient(colors: [.white.opacity(dim ? 0.18 : 0.7), .white.opacity(0)],
                                           startPoint: .top, endPoint: .center), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .modifier(Shake(travel: shake))
        // The field gone, ⌘K's list goes with it.
        .onDisappear { query.acting = nil }
        // Where the card stands, for the bench's pictures of it.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            Omnibox.card = $0
            if Store.testing { Self.probeCards[ObjectIdentifier(browser)] = $0 }
        }
        .onAppear {
            if Store.testing, browser.fieldShowing { Self.presentations += 1 }
            // What needs you is asked for again as the field comes up, and
            // what came in is standing once it has been shown.
            if browser.fieldShowing, browser.askingNew {
                Hints.shared.refresh()
                Hints.shared.saw()
            }
        }
        .onChange(of: browser.fieldShowing) { _, showing in
            if showing {
                if Store.testing { Self.presentations += 1 }
                if browser.askingNew {
                    Hints.shared.refresh()
                    Hints.shared.saw()
                }
            } else {
                query.acting = nil
            }
        }
        .onChange(of: refusals) { _, _ in
            shake = 0
            refused = true
            withAnimation(.easeOut(duration: 0.35)) { shake = 1 }
        }
        .onChange(of: query.typed) { _, _ in
            refused = false
        }
        .environment(\.colorScheme, look)
        // The compact card is never stretched into its size: it fades in
        // already as tall as its rows, and changes size in one step.
        .animation(nil, value: compactRoom)
        .animation(nil, value: compactList)
    }

    /// The compact card's chosen row and its Actions pill: the space's
    /// color, deep enough for white words on it.
    static func spaceTone(_ browser: Browser, dark: Bool) -> Color {
        let paint = browser.spaces.first { $0.id == browser.spaceID }?.paint ?? SpacePaint(browser.prefs)
        let color = paint.color(dark: dark).usingColorSpace(.deviceRGB) ?? .gray
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // A gray space's row is a dark gray: a mid one under white
        // words was mud on a light page (2.6 : 1), and on a dark card.
        let gray = saturation < 0.06
        let tone = gray ? 0 : max(saturation, 0.55)
        var depth = gray ? 0.40 : (dark ? 0.58 : 0.62)
        // Deeper still until the row's quiet words, white at 0.8, read on
        // it as the full box's gray words read on its ground (4.5 : 1 at
        // least): a yellow or green space at the same brightness as a
        // blue one left them at 3 : 1, and a mid gray on a dark card too.
        while depth > 0.2, quietContrast(NSColor(hue: hue, saturation: tone, brightness: depth, alpha: 1)) < 4.5 {
            depth -= 0.02
        }
        return Color(nsColor: NSColor(hue: hue, saturation: tone, brightness: depth, alpha: 1))
    }

    /// White at 0.8 over `color`, against `color`: the chosen compact
    /// row's quiet words on its fill.
    static func quietContrast(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 21 }
        func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
            func linear(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        let r = rgb.redComponent, g = rgb.greenComponent, b = rgb.blueComponent
        let ground = luminance(r, g, b)
        let words = luminance(0.8 + 0.2 * r, 0.8 + 0.2 * g, 0.8 + 0.2 * b)
        return (words + 0.05) / (ground + 0.05)
    }

    /// What it thinks you mean. Pages already open come first, with a dot;
    /// places you have been come with their titles; things to do come with
    /// the keys that do them.
    ///
    /// Rows are kept by position, not by what they hold, so a keystroke that
    /// changes the third answer rewrites the third row where it stands
    /// instead of sliding one out and another in.
    private func list(room: CGFloat) -> some View {
        // The box is as tall as it always is, a launcher's window: the
        // rows stand at its top and scroll, going out under the foot.
        ScrollViewReader { reader in
            ThreadScrollView(.vertical) { rows }
                .edgeScroll(bottomInset: listBottomInset)
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: room)
                .onChange(of: query.current) { _, current in
                    if let current { reader.scrollTo(current) }
                }
        }
    }

    private var listBottomInset: CGFloat {
        compactList && !compactFooted ? Self.compactInset : 0
    }

    /// What stands beside the list, and the list's width then: Mail's New
    /// Split's chosen thread, a request's preview, a phone's code.
    private enum ListSide {
        case mail, request(FieldRequest), phone

        var width: CGFloat {
            switch self {
            case .mail, .request: 320
            case .phone: PhoneBeta.listWidth
            }
        }
    }

    private var listSide: ListSide? {
        // A row's preview must never resize the compact search. Its own
        // place can show the full view after an explicit transition.
        if compact && query.place == nil { return nil }
        if query.place == .mail, query.stock.mail?.mode == .library { return .mail }
        if query.place == nil, let request = browser.chosenRequest, request.previewed { return .request(request) }
        if browser.phoneRowChosen { return .phone }
        return nil
    }

    @ViewBuilder
    private func sideView(_ side: ListSide?) -> some View {
        switch side {
        case .mail:
            MailLibraryPreview(chosen: browser.mailLibraryChosen)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .request(let request):
            RequestPreview(request: request)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .phone:
            PhoneBetaPreview(chosen: true)
        case nil:
            EmptyView()
        }
    }

    private var rows: some View {
        // Keep at most the five compact row slots mounted while the list
        // is invisible. The visible list always reads the live suggestions.
        let offers = compactList && (compactRoom == 0 || !browser.fieldShowing) ? retainedRows.offers : query.offers
        return rows(offers)
    }

    private func rows(_ offers: [Suggestion]) -> some View {
        VStack(spacing: 0) {
            // The empty field's rows come in parts, each with its heading,
            // Now, Recent Tabs, Places, or the
            // page's own. Typed-for rows need none.
            // The compact card has no headings: its few rows say what they are.
            let quiet = !compact && (query.typed.isEmpty || browser.untouched != nil || query.place == .mail)
            ForEach(Array(offers.enumerated()), id: \.offset) { index, offer in
                let section = quiet ? browser.quietSection(offer) : nil
                if let section, index == 0 || browser.quietSection(offers[index - 1]) != section {
                    Text(section)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Self.gutter - Self.inset)
                        .padding(.top, index == 0 ? 4 : 12)
                        .padding(.bottom, 6)
                }
                // One chosen row, one mark on it: the wash says "this is
                // what Return does", the foot's pill how. Favorites' heading doesn't
                // say a row is an open tab: the row does.
                Row(browser: browser, offer: offer, chosen: query.current == index, headed: section != nil && !offer.favorite,
                    version: query.stock.version, compact: compactList)
                    // Reading Mode has no heading: under a list, its air.
                    .padding(.top, quiet && index > 0 && offer.kind == .command(.reader) ? 12 : 0)
                    .id(index)
                    .contentShape(Rectangle())
                    // ⌘ and ⌘⇧ open a place in a new tab, as on a link;
                    // ⌥ beside the page, as ⌥↩ does while it has its key.
                    .onTapGesture { browser.take(offer, Browser.clickWay(for: NSEvent.modifierFlags, alternate: Keymap.shared.keys(.fieldAlternate))) }
                    // A right-click: its actions, as ⌘K has them.
                    .overlay { FieldRowMenu(name: "row \(index)") { browser.showActions(forRow: index) } }
                    // Not while the part of it the pointer is on has gone
                    // under the field.
                    .onContinuousHover(coordinateSpace: .named(Self.box)) { phase in
                        if case .active(let at) = phase, at.y > fieldTall { browser.point(at: index) }
                    }
            }
        }
        .padding(compactList ? Self.compactInset : Self.inset)
        // This inset is already reserved outside the compact scroll view.
        .padding(.bottom, -listBottomInset)
    }

    /// Under whatever the card holds: what Return does, and ⌘K for the rest.
    @ViewBuilder
    private var foot: some View {
        // While the models drop from their name the pill still says what
        // Return does to the answer.
        let actions = query.choosingModel ? browser.answerActions : query.choosingFilter ? browser.rowActions : browser.fieldActions
        FieldFoot(
            browser: browser,
            query: query,
            place: query.answering ? nil : query.place ?? (browser.emojiWords != nil ? .emoji : nil),
            scope: query.answering ? nil : query.scope,
            menu: browser.aboutOffered && query.scope == nil,
            shy: shy && !query.answering,
            detail: query.answering ? nil : footDetail,
            target: query.place == .files && !query.answering ? browser.placeTarget : nil,
            primary: actions.first?.title,
            primaryKeys: actions.first?.danger == true ? actions.first?.keys ?? "↩" : "↩",
            danger: actions.first?.danger == true,
            featured: actions.filter(\.featured),
            more: actions.count > 1
        )
    }

    /// The left of the foot: the emoji chosen, by name.
    private var footDetail: String? {
        // Rows picked together: how many.
        if let picked = browser.pickedWords { return picked }
        // The selection's place: what is selected, its start, quoted.
        if query.place == .selection, let text = browser.fieldSelection?.text, !text.isEmpty {
            let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return "\u{201C}" + (line.count > 36 ? String(line.prefix(36)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : line) + "\u{201D}"
        }
        guard browser.emojiWords != nil else { return nil }
        let list = browser.placeEmoji
        guard list.indices.contains(query.spot) else { return nil }
        return list[query.spot].glyph + "  " + list[query.spot].name.capitalized
    }

    private struct Row: View {
        let browser: Browser
        let offer: Suggestion
        /// The row that is chosen, and so what Return takes.
        let chosen: Bool
        /// Under a heading, which already says what kind of row it is.
        var headed = false
        /// What a mail row says at its end lives in Browser.mailRows, not in
        /// the offer: a count read later changes only this, and without it
        /// the row kept its old end until the pointer redrew it.
        var version = 0
        /// In the compact card: a sum is a row as any other, and the chosen
        /// row says what Return does at its end, as there is no foot to.
        var compact = false
        @Environment(\.colorScheme) private var scheme

        private var calculatedAnswer: Calc.Answer? {
            offer.kind == .sum ? Calc.answer(offer.title) : nil
        }

        private var pageAddon: Bool {
            guard offer.pageRowID != nil, case .page(let what) = offer.kind else { return false }
            return what.hasPrefix("ext:") || what.hasPrefix("us:")
        }

        /// A row whose key is its address and whose title is the page's name:
        /// history, bookmarks, well-known sites and a typed address. Frequent,
        /// Favorites, open tabs and pages found in what you read carry the
        /// name as the key and the address as the title.
        private var keyIsAddress: Bool {
            switch offer.kind {
            case .known, .address: return true
            case .visited: return offer.frequent == nil && offer.seen == nil && !offer.favorite
            default: return false
            }
        }

        /// A place's name first, then its address; only the address when it
        /// has no name.
        private var lead: String {
            if keyIsAddress { return offer.title.isEmpty ? IDN.shownAddress(offer.key) : offer.title }
            return offer.isPlace ? IDN.shownAddress(offer.key) : offer.key
        }

        private var detail: String {
            if let answer = calculatedAnswer, case .color = answer.kind { return answer.result }
            if keyIsAddress { return offer.title.isEmpty ? "" : IDN.shownAddress(offer.key) }
            return offer.url == nil ? offer.title : IDN.shownAddress(offer.title)
        }

        /// The folder of yours an open tab is in (Kept.swift).
        static func folder(of id: UUID?) -> String? {
            guard let id else { return nil }
            return BrowserWindows.shared.browsers.lazy.compactMap { $0.tabs.first { $0.id == id } }.first?.nest?.name
                ?? Folders.shared.browser?.tabs.first { $0.id == id }?.nest?.name
        }

        var body: some View {
            if offer.kind == .sum, !compact, let answer = Calc.answer(offer.title) {
                CalcCard(answer: answer, chosen: chosen)
            } else {
                line
            }
        }

        private var line: some View {
            HStack(spacing: Omnibox.gap) {
                mark
                    .frame(width: Omnibox.slot)
                Text(lead)
                    .font(.system(size: 13.5, weight: offer.kind == .sum && !compact ? .semibold : .regular))
                    .foregroundStyle(lit ? Color.white : Palette.ink)
                    .lineLimit(1)

                if offer.isMenuCommand {
                    // The title slot holds the shortcut; it goes at the end.
                } else if showsAll {
                    // How many more is its mark's, not words after it.
                } else if pageAddon {
                    // The extension or script is said at the row's end.
                } else if compact, case .request = offer.kind {
                    // Its source belongs at the row's trailing edge.
                } else if !offer.title.isEmpty {
                    Text(detail)
                        .font(.system(size: 13.5))
                        .foregroundStyle(lit ? Color.white.opacity(0.8) : Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                // The compact card's chosen row trades its end for what
                // Return does there, the words the foot's pill would say.
                ZStack(alignment: .trailing) {
                    HStack(spacing: Omnibox.gap) {
                        // A command's own shortcut, chosen or not: the end of the row never trades it for ↩, which the
                        // foot's pill says once for the whole list.
                        if offer.isMenuCommand, !offer.title.isEmpty {
                            caps(offer.title)
                        }
                        if offer.kind == .open {
                            // Already open: this goes back to it, not to a second copy.
                            // In a folder of yours, which one, as a shut one hides it.
                            // Under Recent Tabs every row is open: the heading says
                            // it once, not each row again.
                            // In a space not on screen, which, by its emoji and name,
                            // as Arc's Command Bar says it.
                            let elsewhere = offer.tab.flatMap { BrowserWindows.shared.owner(of: $0) }
                                .map { $0.browser !== browser } ?? false
                            if let id = offer.space, let space = browser.spaces.first(where: { $0.id == id }) {
                                HStack(spacing: 6) {
                                    SpaceMark(icon: space.icon, size: 11.5).fixedSize()
                                    kind(space.name)
                                }
                            } else if let words = elsewhere ? "Other Window" : Row.folder(of: offer.tab).map({ "In \($0)" }) ?? (headed ? nil : "Open Tab") {
                                kind(words)
                            }
                        }
                        // What kind of row, said at its end.
                        switch offer.kind {
                        case .visited where offer.seen != nil:
                            // A page found in what you read: when you were there.
                            kind(Row.visited(offer.seen ?? Date())).opacity(forgets ? 0 : 1)
                        case .visited where offer.bookmarked:
                            // Under the chosen row's minus, kept in place so nothing moves.
                            kind("Bookmark").opacity(forgets ? 0 : 1)
                        case .setting: kind("Settings")
                        case .mailAccount: kind("Mail")
                        case .quickAction(let id):
                            if let action = QuickActions.shared.action(id), let key = Hotkey(stored: action.shortcut) { caps(key.text) }
                        case .sum: kind("Sum")
                        case .request(let index):
                            if let request = browser.request(index) {
                                if compact {
                                    kind(request.site.isEmpty ? request.route.word : request.site)
                                } else if !request.previewed {
                                    kind(request.route.word)
                                }
                            }
                        case .clip: kind("Clipboard")
                        case .place(let place):
                            // Its own key, where it has one, as a command's row says
                            // its shortcut.
                            if let keys = place.shortcut.flatMap({ Keymap.shared.keys($0)?.text }) { caps(keys) }
                        case .hint(let id):
                            if let hint = Hints.shared.row(id) {
                                if HintList.joining(hint, now: Hints.now) {
                                    kind("Join")
                                } else if hint.local, Noticing.shared.openTab(for: hint) != nil {
                                    // Already open: this goes back to it, as a tab's row says.
                                    kind("Open Tab")
                                } else if let words = offer.handed ?? Hints.shared.handedWords(hint.id) {
                                    // Handed to the agent (Do It), in the accent: its face
                                    // only while it works, a tick once done.
                                    let mark: String? = words == "On it" ? "agent.face" : words == "Done" ? "checkmark.circle" : nil
                                    HStack(spacing: 4) {
                                        if let mark { Symbol(mark, size: 12 / Glyphs.scale) }
                                        Text(words).font(.system(size: 13.5))
                                    }
                                    .foregroundStyle(words == "Done" ? Palette.ink : words == "Didn’t finish" ? Palette.muted : Color.accentColor)
                                    .lineLimit(1)
                                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                                    .id("handed \(words)")
                                } else if !hint.setup, !HintList.status(hint, now: Hints.now).isEmpty {
                                    // Where it stands, in its own column at the end.
                                    kind(HintList.status(hint, now: Hints.now))
                                }
                            }
                        case .page(let what) where what.hasPrefix("mail:"):
                            // Its key on the page, or how many and when.
                            if let shown = Browser.mailRows[String(what.dropFirst(5))], !shown.end.isEmpty {
                                if shown.row.keyed {
                                    keystrokes(shown.end)
                                } else if shown.end.count <= 3 {
                                    caps(shown.end)
                                } else {
                                    kind(shown.end)
                                }
                            }
                        case .page("mail-now"):
                            FieldMailEnd(lit: lit)
                        case .page(let what) where what.hasPrefix("menu:"):
                            // Concrete menu actions carry their own remapped key.
                            if !offer.title.isEmpty { caps(offer.title) }
                        case .page(let what) where what.hasPrefix("ext:"):
                            if pageAddon { kind(offer.title) }
                            if let keys = Browser.extensionCommand(what).keys { caps(keys) }
                        case .page(let what) where what.hasPrefix("us:"):
                            if pageAddon { kind(offer.title) }
                        case .page(let what) where what.hasPrefix("sel") || what == "setup" || what == "wrapped" || what.hasPrefix("us"):
                            // Where it runs is its row's words; no key of its own.
                            EmptyView()
                        case .page(let what) where FieldPageRows.command(what) != nil:
                            if let command = FieldPageRows.command(what), !command.keys.isEmpty { caps(command.keys) }
                        case .page("tracking"):
                            EmptyView()
                        case .page(let what) where what.hasPrefix("menu:"):
                            // A command's target: its own keys are drawn
                            // above, and no key means none, not ⌘J's ask.
                            EmptyView()
                        case .page(let what):
                            let action: Shortcut.Action? = switch what {
                            case "copy": .copyAddress
                            case "markdown": .copyMarkdownLink
                            case "duplicate": .duplicate
                            case "reader": .reader
                            default: nil
                            }
                            if let keys = Keymap.shared.keys(action ?? .agentAsk)?.text { caps(keys) }
                        default: EmptyView()
                        }
                    }
                    .opacity(compact && chosen && !commanded ? 0 : 1)
                    if compact, chosen, !commanded, let does = browser.fieldActions.first?.title {
                        HStack(spacing: 8) {
                            if offer.kind == .page("mail-now"), let item = FieldMail.item {
                                MailCodeChip(item: item, size: 13.5).padding(.trailing, 4)
                            }
                            kind(does)
                            caps("↩")
                        }
                    }
                }
            }
            .padding(.horizontal, Omnibox.gutter - (compact ? Omnibox.compactInset : Omnibox.inset))
            .frame(height: compact ? Omnibox.compactRowHeight : Omnibox.rowHeight)
            // A place you have been can go from the history from its row,
            // a minus on a plate at its end
            // while it is chosen, over the row, so choosing it moves
            // nothing (#199). Its tip says Remove above it, with ⇧⌫.
            .overlay(alignment: .trailing) {
                if forgets {
                    RemoveMinus(keys: Keymap.shared.text(.fieldForget), side: .above) { browser.forget(offer) }
                        .padding(.trailing, Omnibox.gutter - Omnibox.inset) // design: the plate's edge on the row's words' end
                }
            }
            // Shown but nothing to take (a Get Me To Zero age with no thread
            // in it): dimmed, and never chosen (Browser.inert).
            .opacity(quiet ? 0.4 : 1)
            .background {
                if chosen {
                    RoundedRectangle(cornerRadius: compact ? Omnibox.compactCorner - Omnibox.compactInset : Radius.surface, style: .continuous)
                        .fill(compact ? spaceFill : Omnibox.chosenFill)
                        // Lifted off the glass, as the example's chosen row is.
                        .cast(Shadow.fieldRow, on: compact)
                }
            }
            .lineLimit(1)
            // The compact card's chosen row is a deep color: white words on it.
            .environment(\.colorScheme, compact && chosen ? .dark : scheme)
            // State, not geometry: on the row the moment it is chosen.
            .transaction { $0.animation = nil }
        }

        /// The chosen row is a place the history can forget: it wears the minus.
        private var forgets: Bool { chosen && browser.forgettable(offer) }

        /// Now's Show All, under its first four: its title is how many more.
        private var showsAll: Bool { offer.kind == .place(.now) && offer.key == "Show All in Now" }

        /// A mail row shown but not to be taken (MailField's quiet rows).
        private var quiet: Bool { Browser.inert(offer) }

        /// "Visited today", "Visited yesterday", "Visited Sep 3".
        static func visited(_ at: Date, now: Date = Date()) -> String {
            let calendar = Calendar.current
            if calendar.isDate(at, inSameDayAs: now) { return "Visited today" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(at, inSameDayAs: yesterday) {
                return "Visited yesterday"
            }
            let sameYear = calendar.component(.year, from: at) == calendar.component(.year, from: now)
            return "Visited " + at.formatted(sameYear ? AppDates.dateTime.month(.abbreviated).day() : AppDates.dateTime.month(.abbreviated).day().year())
        }

        /// The compact card's chosen row: a veil of this space's own color,
        /// as the example the card was drawn from fills its chosen row.
        /// The compact card's chosen row: white words on its color.
        private var lit: Bool { compact && chosen }

        /// A command's row: its keys say what it does, chosen or not.
        private var commanded: Bool {
            if offer.isMenuCommand { return true }
            return false
        }

        /// Spaces' colors are the window's pale grounds; this is the same
        /// hue made deep enough for white words on it, gray for a gray space.
        private var spaceFill: Color { Omnibox.spaceTone(browser, dark: scheme == .dark) }

        /// What kind of row, at its end: the words and weight "Search
        /// YouTube" has there, so every row's end reads as one column.
        private func kind(_ words: String) -> some View {
            Text(words)
                .font(.system(size: 13.5))
                .foregroundStyle(lit ? Color.white.opacity(0.8) : Palette.muted)
                .lineLimit(1)
        }

        /// Keys at a row's end, at the row's words' size, as a shortcut
        /// at the end of a row is everywhere (KeyGlyphs).
        private func caps(_ keys: String) -> some View {
            // White on the compact card's chosen row, its plate a veil of white.
            KeyGlyphs(keys: keys, size: 13.5, tint: lit ? .white : Palette.muted)
        }

        /// Keys pressed one after another, "G S": each keystroke its own
        /// caps, a little apart.
        private func keystrokes(_ keys: String) -> some View {
            HStack(spacing: 4) {
                ForEach(Array(keys.split(separator: " ").enumerated()), id: \.offset) { _, stroke in caps(String(stroke)) }
            }
        }

        /// What kind of answer this is, at a glance down the left: a site's
        /// own icon for a place, the app's own line for everything else.
        @ViewBuilder
        private var mark: some View {
            switch offer.kind {
            case .sum:
                CalcMark(answer: calculatedAnswer)
            case .task:
                // The agent, in the color Settings gives Agents.
                FieldMark(symbol: "agent.face", tint: .systemPurple)
            case .request(let index):
                let request = browser.request(index)
                FieldMark(symbol: request?.symbol ?? "agent.face", tint: request?.tint ?? .systemPurple)
            case .within(let place):
                FieldMark(symbol: place.pen ?? place.symbol, tint: place.tint)
            case .place(let place):
                if showsAll {
                    // How many more of Now there are, on the well a row's mark has.
                    FieldMark(symbol: place.symbol, words: "+" + offer.title)
                } else {
                    // Places of the box's own are features, as Settings' are, in
                    // Settings' colors where Settings has the same feature.
                    FieldMark(symbol: place.pen ?? place.symbol, tint: place.tint)
                }
            case .page(let what) where what.hasPrefix("sel-ask:"):
                FieldMark(symbol: "bubble.sparkle")
            case .page("sel-task"):
                FieldMark(symbol: "agent.face", tint: .systemPurple)
            case .page("setup"):
                FieldMark(symbol: "list.bullet", tint: .systemPurple)
            case .page(let what) where what.hasPrefix("mail:"):
                if case .account(let account)? = Browser.mailRows[String(what.dropFirst(5))]?.row {
                    MailAccountMark(account: account, size: Omnibox.tile - 4)
                        .frame(width: Omnibox.tile, height: Omnibox.tile)
                } else if case .library(let id)? = Browser.mailRows[String(what.dropFirst(5))]?.row {
                    FieldMark(symbol: Browser.mailRows[String(what.dropFirst(5))]?.symbol ?? "envelope",
                              tint: MailSplitLibrary.tint(id))
                } else {
                    FieldMark(symbol: Browser.mailRows[String(what.dropFirst(5))]?.symbol ?? "envelope")
                }
            case .mailAccount(let account):
                // As the column's chooser draws it: its photo or its letter.
                MailAccountMark(account: account, size: Omnibox.tile - 4)
                    .frame(width: Omnibox.tile, height: Omnibox.tile)
            case .page(let what) where what.hasPrefix("ext:"):
                // The extension's own icon, as on its pin.
                if let icon = Browser.extensionCommand(what).icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: Omnibox.tile - 6, height: Omnibox.tile - 6)
                        .frame(width: Omnibox.tile, height: Omnibox.tile)
                } else {
                    FieldMark(symbol: "puzzlepiece.extension")
                }
            case .page(let what) where what.hasPrefix("us"):
                FieldMark(symbol: "puzzlepiece.extension")
            case .page("mail-now"):
                FieldMailMark(browser: browser)
            case .page("wrapped"):
                // The arcade icon Yab Wrapped unlocks.
                Image(nsImage: AppIconStyle.picture(.arcade, dark: false))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Omnibox.tile, height: Omnibox.tile)
            case .page(let what) where what.hasPrefix("sel:"):
                // The mark it wears in ⌘J's list.
                FieldMark(symbol: SelectionLayer.symbol(String(what.dropFirst(4))))
            case .page(let what) where what.hasPrefix("menu:"):
                FieldMark(symbol: MenuCommands.symbol(forTargetID: String(what.dropFirst(5))))
            case .page(let what) where FieldPageRows.command(what) != nil:
                if let command = FieldPageRows.command(what) { FieldMark(symbol: FieldPageRows.symbol(command)) }
            case .page("tracking"):
                FieldMark(symbol: "link")
            case .page(let what):
                switch what {
                case "copy": FieldMark(symbol: "link")
                case "markdown": FieldMark(symbol: "markdown")
                case "duplicate": FieldMark(symbol: "plus.square.on.square")
                case "reader": FieldMark(symbol: "yab.bookopen")
                // The agent, in the color Settings gives Agents.
                default: FieldMark(symbol: "agent.face", tint: .systemPurple)
                }
            case .clip(let id):
                ClipMark(clip: Clips.shared.items.first { $0.id == id })
            case .hint(let id):
                HintMark(hint: Hints.shared.row(id))
            case .ask:
                // Gray, as a question to the answer ⌘J gives: the purple
                // is the task's, the agent at work.
                FieldMark(symbol: "bubble.sparkle")
            case .asked:
                FieldMark(symbol: "clock")
            case .search, .suggested:
                FieldMark(symbol: "magnifyingglass")
            case .command(let command):
                FieldMark(symbol: command.symbol, tint: command.tint)
            case .setting(let page):
                FieldMark(symbol: page.icon, tint: page.tint, page: page)
            case .open, .visited, .known, .address, .site:
                // Only what is already on this Mac: a list that fetched as
                // you typed would be fetching for every letter.
                Mark(icon: favicon, letter: letter, size: Omnibox.tile - 4)
            case .quickAction:
                // A handful of known makers: their product's icon is asked
                // for once, as a bookmark's is.
                Mark(icon: favicon, letter: letter, size: Omnibox.tile - 4)
                    .onAppear { if favicon == nil { QuickActions.fetchIcon(of: offer) } }
            }
        }

        private var favicon: NSImage? { Omnibox.favicon(for: offer) }

        private var letter: String {
            let name = offer.url?.host().map { IDN.shown($0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0) } ?? offer.key
            return name.first.map { String($0).uppercased() } ?? ""
        }
    }
}

/// The address field's text field, with an editor of its own
/// (`AddressEditor`) instead of the window's shared one.
final class AddressTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { AddressCell.self }
        set {}
    }
}

final class AddressCell: NSTextFieldCell {
    private lazy var editor = AddressEditor.make()
    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }

    /// A session's undo ends with it, as a plain field's does.
    override func endEditing(_ textObj: NSText) {
        super.endEditing(textObj)
        editor.edits.removeAllActions()
    }
}

/// What a paste leaves in the address field: no space added beside what
/// is already there, and the words trimmed (feedback #164a). A word chosen on a page with a double click is
/// copied with AppKit's smart paste type, and the window's editor, smart
/// insert on, put a space between it and the letters before it; a line
/// copied with its newline came in with it, drawn as a space at the end.
final class AddressEditor: NSTextView {
    /// The field's typing, undone in the field and gone with it (crash #64,
    /// 0.35.13). A field's own field editor files its keys in the window's
    /// undo, not in a session's own as the window's shared editor does, and
    /// they stayed there after the ⌘T or ⌘L field was freed: ⌘Z later in
    /// any other field with nothing of its own to undo went on to the
    /// window's, into the freed field's typing.
    let edits = UndoManager()
    override var undoManager: UndoManager? { edits }
    @objc func undo(_ sender: Any?) { edits.undo() }
    @objc func redo(_ sender: Any?) { edits.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = edits.undoMenuItemTitle
            return edits.canUndo
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = edits.redoMenuItemTitle
            return edits.canRedo
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    static func make() -> AddressEditor {
        let editor = AddressEditor(frame: .zero)
        AppleWritingTools.shared.apply(to: editor)
        // As the window's own editor is set up, but for smart insert, and
        // nothing turned into something else under the caret of a field
        // that takes addresses.
        editor.isFieldEditor = true
        editor.allowsUndo = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.usesFontPanel = false
        editor.smartInsertDeleteEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        return editor
    }

    /// Some input methods commit their marked text before forwarding Return
    /// as a text command. Keep the start of that one key, so the same Return
    /// cannot also submit the address after the mark has disappeared (#1238).
    private var keyBeganComposing = false

    override func keyDown(with event: NSEvent) {
        let previous = keyBeganComposing
        keyBeganComposing = hasMarkedText()
        defer { keyBeganComposing = previous }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.insertNewline(_:)) ||
            selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            if keyBeganComposing || hasMarkedText() {
                // The input context normally commits first. If it forwards a
                // command with the mark still present, commit those exact raw
                // characters through AppKit's normal insertion notifications.
                if hasMarkedText() {
                    let range = markedRange()
                    let raw = (string as NSString).substring(with: range)
                    insertText(raw, replacementRange: range)
                    inputContext?.discardMarkedText()
                }
                return
            }
        }
        super.doCommand(by: selector)
    }

    /// Copy, Cut, a drag and Services all write the selection here: of the
    /// untouched address ⌘L brought, the page's own address, scheme and all,
    /// not the shortened words the field shows (feedback #1519). It used to
    /// be put right by ⌘C alone, in the window's key monitor; Edit › Copy
    /// and the field's own menu took "example.com/page" with no https://.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let here = ((delegate as? NSTextField)?.delegate as? AddressField.Coordinator)?.browser.untouched
        guard let whole = Self.copied(string, selectedRange(), here: here) else {
            return super.writeSelection(to: pboard, types: types)
        }
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(whole, forType: .string)
    }

    /// What a copy of `range` of the field's `text` takes when the text is
    /// the address `here` as ⌘L shows it: all of it, the address itself; a
    /// start of it, that start with its scheme put back, as Chromium copies
    /// from its address bar. Nil leaves the words as they are.
    static func copied(_ text: String, _ range: NSRange, here: URL?) -> String? {
        guard let here, range.location == 0, range.length > 0, text == Address.whole(here) else { return nil }
        let shown = text as NSString
        guard range.length < shown.length else { return here.absoluteString }
        guard let scheme = here.scheme, !text.lowercased().hasPrefix(scheme.lowercased() + ":") else { return nil }
        return scheme + "://" + shown.substring(with: range)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let words = pboard.string(forType: .string) else { return super.readSelection(from: pboard, type: type) }
        pasting = true
        defer { pasting = false }
        insertText(Self.pasted(words), replacementRange: selectedRange())
        return true
    }

    /// Words a paste, a drop or a service is putting in, while they go in:
    /// a space among them never starts a site's search (Scopes.spaced), as
    /// Chrome's paste state keeps a paste out of keyword mode.
    private(set) var pasting = false

    /// The edges' white space gone, a run of white space with a line break
    /// in it taken out (an address broken over lines comes back whole), and
    /// any other spaces inside kept as they were.
    static func pasted(_ words: String) -> String {
        var out = ""
        var run = ""
        for character in words.trimmingCharacters(in: .whitespacesAndNewlines) {
            if character.isWhitespace {
                run.append(character)
                continue
            }
            if !run.contains(where: \.isNewline) { out += run }
            run = ""
            out.append(character)
        }
        return out
    }
}

/// The field itself, in AppKit.
///
/// SwiftUI's TextField can hold a string and nothing else, and the whole point
/// here is the part you didn't type: the rest of the address, already there and
/// selected, so carrying on typing replaces it and Return accepts it. That
/// needs a real text field and its delegate.
struct AddressField: NSViewRepresentable {
    /// The stand can distinguish a process's first native field from a
    /// field already created by the blank tab at startup.
    @MainActor static var creations = 0
    let browser: Browser
    /// Watched, rather than the browser: this is what changes as you type.
    @ObservedObject var query: Query
    /// Over a private tab, drawn as on a dark window.
    var dark = false
    /// Its empty words are the omnibox's (StealthHint), not its own.
    var hushed = false
    /// Light or dark, as the card round it is drawn.
    var look: ColorScheme?

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeNSView(context: Context) -> NSTextField {
        if Store.testing { Self.creations += 1 }
        let field = AddressTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.textColor = Palette.NS.ink
        field.lineBreakMode = .byTruncatingTail
        // An address, and said so. Left to guess, AppKit takes a field that
        // is focused the moment it appears for one that might want a code
        // from Messages, and sets AutoFill's window up for it, a round trip
        // to the window server that held the main thread for hundreds of
        // milliseconds on every new tab, long enough to swallow the row's
        // animation whole. Its own completion is off too: the list under
        // the field is ours.
        field.contentType = .URL
        field.isAutomaticTextCompletionEnabled = false
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        // The words while it is empty are ours, not its placeholder, so they
        // can turn into other words (see `FieldWords`).
        let words = FieldWords(frame: field.bounds)
        words.autoresizingMask = [.width, .height]
        field.addSubview(words)
        context.coordinator.words = words
        context.coordinator.holdKeys(for: field)
        context.coordinator.watchMarking(field)
        return field
    }

    static let hint = "Enter a web address"

    /// Split View's field: it asks for the half beside the page.
    static let besideHint = "Open beside this page"

    /// The words an empty field says: what it is for, or the site it searches.
    private static func hint(for scope: Scope?, place: FieldPlace? = nil, splitting: Bool = false) -> String {
        if let place { return place.placeholder }
        return scope.map { "Search \($0.name)" } ?? (splitting ? besideHint : hint)
    }

    /// Whether the field takes input follows whether it shows. SwiftUI runs
    /// this from its host's layout pass, and disabling a field that is
    /// editing ends the editing there: the field editor leaves the window,
    /// the input method is deactivated over XPC, and the window is marked
    /// for more layout inside the pass that asked, until AppKit throws
    /// (crash #112, `-[NSTextField setEnabled:]` under `NSHostingView.layout`).
    /// A field being edited is disabled on the next turn of the main run
    /// loop instead; anything else changes at once.
    static func follow(showing: Bool, field: NSTextField, now: @escaping @MainActor () -> Bool) {
        guard field.isEnabled != showing else { return }
        guard !showing, field.currentEditor() != nil else { field.isEnabled = showing; return }
        DispatchQueue.main.async { [weak field] in
            MainActor.assumeIsolated {
                guard let field else { return }
                let wanted = now()
                if field.isEnabled != wanted { field.isEnabled = wanted }
            }
        }
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        Self.follow(showing: browser.fieldShowing, field: field) { [weak browser] in browser?.fieldShowing ?? false }
        let coordinator = context.coordinator
        coordinator.browser = browser
        let wanted: ColorScheme? = dark ? .dark : look
        let appearance = wanted.flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
        if field.appearance?.name != appearance?.name { field.appearance = appearance }
        // A private field's words are drawn over it, by the omnibox.
        let hint = query.answering ? "Ask a follow-up…" : query.actionsPage ? "Search actions…"
            : Self.hint(for: query.scope, place: query.place, splitting: browser.asked == .split)
        if field.accessibilityPlaceholderValue() != hint { field.setAccessibilityPlaceholderValue(hint) }
        // Under an answer the field is a pill beside the foot's, its words
        // at the pill's size; its empty words are the omnibox's then, since
        // FieldWords draws in the field's own large face.
        let size: CGFloat = query.answering ? 13.5 : 20
        if field.font?.pointSize != size { field.font = .systemFont(ofSize: size) }
        let words = coordinator.words
        if let cell = field.cell {
            // Where the field sets its own text: its drawing rect, the text's
            // own inset, and the baseline a line of this face has.
            let rect = cell.drawingRect(forBounds: field.bounds)
            let origin = CGPoint(x: rect.minX + Self.inset, y: rect.minY + Self.baseline)
            if words?.origin != origin { words?.origin = origin }
        }

        // Tab into a site, out of it, ⌫ giving the words back: the words
        // carried over rather than swapped (see `FieldWords`). Read before
        // the field's text below changes, since Tab's words start from it.
        let scope = query.scope?.id ?? query.place.map { "place:" + $0.rawValue }
        if scope != coordinator.scope, let words {
            let was = coordinator.scope
            coordinator.scope = scope
            // A place of the field's own, Clipboard History or Emoji, in or
            // out: its words share next to no letters with what was there,
            // so carried over they only slid about. Swapped at once, as a
            // placeholder is; a site's search keeps the morph, where the
            // site's name is carried into "Search YouTube" and back.
            let placed = (was ?? "").hasPrefix("place:") || (scope ?? "").hasPrefix("place:")
            if hushed || placed {
                words.settle()
            } else if was == nil {
                let shown = field.stringValue
                words.isHidden = false
                words.carry(from: shown.isEmpty ? nil : (shown, false), to: hint, faint: true)
            } else if browser.completed.isEmpty {
                words.isHidden = false
                words.carry(to: hint, faint: true)
            } else if !browser.typed.isEmpty, browser.typed == query.before,
                      let editor = field.currentEditor() {
                words.isHidden = false
                words.carry(to: browser.completed, faint: false, veiling: editor.superview ?? editor)
            } else {
                words.settle()
            }
        }

        // Only when something other than typing changed it, ⌘L arriving with
        // an address, a walk through the list, a submit clearing it.
        //
        // Comparing against the field's own text instead would undo every
        // backspace: deleting leaves the field shorter than what the browser
        // still considers complete, and the next update would helpfully type
        // it back in. That is a field you cannot shorten, and it reads exactly
        // like one that has stopped responding.
        let want = browser.completed
        if want != coordinator.synced {
            coordinator.synced = want
            field.stringValue = want
            coordinator.select(from: browser.typed.count, in: field)
            coordinator.paint(field)
        }

        if !browser.fieldShowing {
            coordinator.cancelFocus()
        } else if coordinator.answered != browser.focusRequest {
            coordinator.answered = browser.focusRequest
            coordinator.focus(field, notBefore: 0)
        }

        words?.seen()

        // The words at rest: there while the field is empty, the same frame
        // a key puts a letter in it or takes the last one out.
        if let words, !words.busy {
            // A private field's own words are the omnibox's (StealthHint),
            // but a site or a place searched there says so here.
            let empty = (!hushed || query.scope != nil || query.place != nil) && field.stringValue.isEmpty && !query.answering
                && !InputMethod.composing(field.currentEditor())
            if words.isHidden == empty { words.isHidden = !empty }
            if empty { words.set(hint, faint: true) }
        }
    }

    /// The text's own inset in the field's drawing rect, and its baseline
    /// under the rect's top, as the field sets a line in its face.
    private static let inset: CGFloat = 2
    private static let baseline: CGFloat = NSLayoutManager().defaultBaselineOffset(for: FieldWords.font)

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var answered = -1
        /// The field's words while it is empty, and the site it last searched.
        var words: FieldWords?
        var scope: String?
        /// The last value pushed in from the browser side, so an update can
        /// tell a change worth applying from one it made itself.
        var synced = ""
        /// Hides the words at rest the moment an input method starts
        /// composing in the field: its marked text is not the field's
        /// value yet, and the placeholder sat over the Kana (row 1014).
        var marking: ObservationLoop?

        /// A backspace has to be allowed to actually take a letter off. Without
        /// this the field puts the same letter straight back as a completion
        /// and the address can never be shortened.
        private var deleting = false

        init(browser: Browser) {
            self.browser = browser
        }

        deinit {
            if let holding { NSEvent.removeMonitor(holding) }
        }

        /// The cursor into the field, at once, or not before `notBefore`
        /// (`CACurrentMediaTime`). Keys pressed
        /// while it waits are held rather than lost, and given to the field,
        /// in order, the moment it has the cursor: Return, Delete and all.
        /// Anything with ⌘ or ⌃ goes through untouched, ⌘W does not wait.
        private var pendingFocus: DispatchWorkItem?
        private var holding: Any?
        private var held: [NSEvent] = []
        private var focusedRequest = -1

        /// Installed with the retained field, before the first layout of an
        /// opening. A key can arrive before updateNSView schedules focus.
        func holdKeys(for field: NSTextField) {
            holding = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak field] event in
                guard let self, let field, event.window === field.window,
                      event.modifierFlags.intersection([.command, .control]).isEmpty,
                      MainActor.assumeIsolated({ Questions.shared.current?.place != .page && self.browser.fieldShowing &&
                          (self.pendingFocus != nil || self.focusedRequest != self.browser.focusRequest) })
                else { return event }
                self.held.append(event)
                return nil
            }
        }

        func cancelFocus() {
            pendingFocus?.cancel()
            pendingFocus = nil
            focusedRequest = -1
            held = []
        }

        func focus(_ field: NSTextField, notBefore: CFTimeInterval, tries: Int = 0) {
            pendingFocus?.cancel()
            // Let the card's first layout commit before AppKit builds and
            // selects its field editor. Doing both in the same pass made
            // the first frame miss its budget. The event monitor below
            // holds keys during this short handoff. Leave a full frame
            // after layout as well: a timer due during that first layout
            // otherwise runs in the same display cycle.
            let firstFrame = field.currentEditor() == nil ? 2.0 / 60 : 0
            let wait = tries > 0 ? 1.0 / 60 : max(firstFrame, notBefore - CACurrentMediaTime())
            let work = DispatchWorkItem { [weak self, weak field] in
                guard let self else { return }
                self.pendingFocus = nil
                // Made but not yet hung in the window, as a field that comes
                // up over a page can be a turn of the run loop later: a frame
                // on, a few times, rather than the cursor left on the page.
                // Keys pressed meanwhile are still held.
                if let field, field.window == nil, tries < 30 {
                    self.focus(field, notBefore: 0, tries: tries + 1)
                    return
                }
                let keys = self.held
                self.held = []
                guard MainActor.assumeIsolated({ self.browser.fieldShowing }),
                      let field, let window = field.window else { return }
                // Raised in a small window: only the field standing there
                // takes the keyboard, not the window's own one hidden under.
                if let host = MainActor.assumeIsolated({ self.browser.fieldHost }), window !== host { return }
                window.makeFirstResponder(field)
                if let editor = field.currentEditor() as? NSTextView {
                    // The system paints selected text as a block of accent
                    // color, which over this pale field is the loudest thing
                    // in the window. A tenth of the ink says "selected"
                    // quietly enough.
                    editor.selectedTextAttributes = [
                        .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                        .foregroundColor: Palette.NS.ink,
                    ]
                    editor.selectAll(nil)
                }
                MainActor.assumeIsolated {
                    self.paint(field)
                    self.focusedRequest = self.browser.focusRequest
                }
                // Re-enter the app's event queue, including its key monitors:
                // sending straight to NSWindow skipped Escape's routing.
                for key in keys.reversed() { NSApp.postEvent(key, atStart: true) }
            }
            pendingFocus = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
        }

        /// The words at rest go the frame an input method starts composing
        /// in the field; its words committed or dropped, the field's text
        /// says again (controlTextDidChange, updateNSView).
        @MainActor func watchMarking(_ field: NSTextField) {
            marking = ObservationLoop { [weak self, weak field] in
                guard InputMethod.Marking.shared.composing, let self, let field,
                      InputMethod.composing(field.currentEditor()), let words = self.words else { return }
                if words.busy { words.settle() }
                words.isHidden = true
            }
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let text = field.stringValue
            // Words an input method is still composing: not the field's yet,
            // so nothing is finished after them, but the placeholder goes.
            let composing = InputMethod.composing(field.currentEditor())
            // A key while the words are moving: they are where they were
            // going, and gone if the field has something in it now.
            if let words, words.busy {
                words.settle()
            }
            words?.isHidden = !text.isEmpty || composing

            // A space typed after a site's alias: that site's search, as Tab
            // starts it (Settings › Field › Sites › Keyboard shortcut). The
            // words before the change are still the browser's, and the
            // field takes the site's words from updateNSView, as after Tab.
            if !deleting, !composing, let editor = field.currentEditor() as? AddressEditor, !editor.pasting,
               editor.selectedRange().length == 0,
               browser.enterScope(spacing: browser.typed, to: text, caret: editor.selectedRange().location) {
                return
            }

            browser.replaceTyped(text, completing: !deleting && !composing)
            guard !deleting, !composing, let ending = browser.ending else {
                deleting = false
                synced = browser.completed
                return
            }
            deleting = false

            field.stringValue = text + ending
            synced = field.stringValue
            select(from: text.count, in: field)
        }

        /// Return, as the keys held with it ask: ⌘ for a new tab behind,
        /// ⌘⇧ for one in front, ⌥ for a new tab in front at the end of the
        /// row (Browser.submitAlternate).
        @MainActor private func submit() {
            let flags = NSApp.currentEvent?.modifierFlags.intersection([.command, .option, .control, .shift]) ?? []
            // The configurable variants are taken by ContentView before the
            // field editor. An old binding must not keep working here.
            guard flags.isDisjoint(with: [.command, .option, .control]) else { return }
            browser.submit()
        }

        /// These words in the field, as though typed, the caret after them
        /// and whatever the field then finishes selected.
        @MainActor private func show(_ words: String, in field: NSTextField) {
            browser.typed = words
            synced = browser.completed
            field.stringValue = synced
            select(from: words.count, in: field)
            paint(field)
        }

        /// The part after the caret, shown as selected, so the next keystroke
        /// replaces it and Return takes it.
        func select(from start: Int, in field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            let length = field.stringValue.count
            guard start <= length else { return }
            editor.selectedRange = NSRange(location: start, length: length - start)
        }

        /// The page's own address, as ⌘L brings it: what is after the path,
        /// the query, the fragment, a shade quieter, there so Return and a
        /// copy keep them, not so they are read. Selected, it stays quieter;
        /// the first key typed over it is ink again.
        @MainActor func paint(_ field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView,
                  let storage = editor.textStorage else { return }
            let text = storage.string as NSString
            let tail = browser.untouched == nil
                ? NSRange(location: NSNotFound, length: 0)
                : text.rangeOfCharacter(from: CharacterSet(charactersIn: "?#"))
            var selected = editor.selectedTextAttributes
            if tail.location == NSNotFound {
                selected[.foregroundColor] = Palette.NS.ink
                editor.selectedTextAttributes = selected
                return
            }
            // Selected text is drawn in the selection's color, which would
            // put the quiet part back in ink; left out, each part keeps its own.
            selected[.foregroundColor] = nil
            editor.selectedTextAttributes = selected
            storage.addAttribute(.foregroundColor, value: Palette.NS.ink, range: NSRange(location: 0, length: tail.location))
            storage.addAttribute(.foregroundColor, value: NSColor(Palette.muted),
                                 range: NSRange(location: tail.location, length: text.length - tail.location))
            editor.typingAttributes[.foregroundColor] = Palette.NS.ink
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.deleteBackward(_:)) where browser.picking,
                 #selector(NSResponder.deleteForward(_:)) where browser.picking:
                // ⌫ with rows picked: the foot's act on all of them, before
                // ⌫ in an empty place's field leaves it.
                browser.forgetPicked()
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 // ⌥Return: the field editor's own word for it.
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // ⌥↩ on a row of Now, nothing typed: Later Today.
                submit()
                return true
            case Selector(("noop:")):
                // ⌘Return, which the text system has no binding for.
                guard let event = NSApp.currentEvent, event.type == .keyDown,
                      [36, 76].contains(event.keyCode) else { return false }
                submit()
                return true
            case #selector(NSResponder.insertTab(_:)) where browser.enterNamedPlace() || browser.enterScope() || browser.askOnTab()
                || browser.enterActions():
                return true
            case #selector(NSResponder.deleteBackward(_:)) where browser.query.actionsPage && textView.string.isEmpty:
                // ⌫ in Actions' empty field: the plain field.
                browser.leaveActions()
                return true
            case #selector(NSResponder.deleteBackward(_:)) where browser.query.place != nil && textView.string.isEmpty:
                // ⌫ in a place's empty field: the plain field again.
                browser.leavePlace()
                return true
            case #selector(NSResponder.moveLeft(_:)) where browser.showPhone(.iPhone):
                return true
            case #selector(NSResponder.moveRight(_:)) where browser.showPhone(.android):
                return true
            case #selector(NSResponder.moveLeft(_:)) where browser.emojiWords != nil:
                // Across Emoji's grid, as the arrows go in any grid.
                _ = browser.walkPlace(-1)
                return true
            case #selector(NSResponder.moveRight(_:)) where browser.emojiWords != nil:
                _ = browser.walkPlace(1)
                return true
            case #selector(NSResponder.deleteBackward(_:)) where browser.query.scope != nil && textView.string.isEmpty:
                // ⌫ in a site's empty field: the plain field, the words Tab
                // took given back.
                browser.leaveScope(restoring: true)
                return true
            case #selector(NSResponder.deleteBackward(_:)) where textView.string.isEmpty && browser.leavePrivate():
                // ⌫ in Private's empty field: the plain field, as out of a site's.
                return true
            case #selector(NSResponder.insertTab(_:)):
                // Tab takes what the field is finishing, or the row walked
                // to, as though typed, the caret at its end. With nothing
                // offered it is the usual Tab. ⌘Z gives the words back as
                // they were, the ending offered again.
                let before = browser.typed
                let whole = browser.completed
                guard whole != before, let field = control as? NSTextField else { return false }
                show(whole, in: field)
                // Filed against the editor, whose undo it is in: an undo
                // manager never keeps its target alive.
                textView.undoManager?.registerUndo(withTarget: textView) { [weak self, weak field] _ in
                    guard let self, let field else { return }
                    self.show(before, in: field)
                }
                textView.undoManager?.setActionName("Typing")
                return true
            case #selector(NSResponder.moveDownAndModifySelection(_:)) where browser.pickStep(1),
                 #selector(NSResponder.moveUpAndModifySelection(_:)) where browser.pickStep(-1):
                // ⇧↓ and ⇧↑ in a place that picks: the picks stretched.
                return true
            case #selector(NSResponder.moveDown(_:)):
                browser.walk(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                browser.walk(-1)
                return true
            case #selector(NSResponder.deleteBackward(_:)) where textView.string.isEmpty &&
                 NSApp.currentEvent.map({ Keymap.shared.matches($0, .fieldDone) }) == true && browser.hintKey("done"):
                // ⌫ on a row of Now, nothing typed: Done.
                return true
            case #selector(NSResponder.deleteBackward(_:)),
                 #selector(NSResponder.deleteForward(_:)),
                 // ⌥⌫, ⌘⌫ and the rest delete too. Not flagged, they took
                 // off only the offered ending, which came straight back,
                 // so ⌥⌫ did nothing; now it takes the ending off, as in
                 // Chrome, and the next one the word before the caret.
                 #selector(NSResponder.deleteWordBackward(_:)),
                 #selector(NSResponder.deleteWordForward(_:)),
                 #selector(NSResponder.deleteToBeginningOfLine(_:)),
                 #selector(NSResponder.deleteToEndOfLine(_:)),
                 #selector(NSResponder.deleteToBeginningOfParagraph(_:)),
                 #selector(NSResponder.deleteToEndOfParagraph(_:)),
                 #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:)),
                 #selector(NSResponder.deleteToMark(_:)):
                // ⇧⌫, fn⇧⌫: a place in the list not to be offered again.
                if NSApp.currentEvent.map({ Keymap.shared.matches($0, .fieldForget) }) == true,
                   browser.forgetChosen() { return true }
                deleting = true
                return false
            default:
                return false
            }
        }
    }
}

/// The band under the field: the blur of the system's header material,
/// blending what is under it in the window, the rows, not the desktop
/// behind the window as SwiftUI's own materials do here.
struct FieldBand: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = ClearBand()
        view.material = .headerView
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The header material's blur alone. Over it the material lays a fill of
/// its own, a gray at 0.8 on a dark window and a white on a light one,
/// and a touch of the desktop's color: over glass tinted by the page, a
/// blue one, that fill stood at the top of the box as a gray shadow. With
/// only the blur the band is the color of whatever is under it, the glass
/// where nothing scrolls, and still blurs a row passing under the field.
/// AppKit builds the material's layers again as the look, the window or
/// the emphasis change, so they are hidden again after each.
final class ClearBand: NSVisualEffectView {
    /// The backdrop group its blur is drawn in: blurs of one group share
    /// one picture of what is under the first of them, so one laid over
    /// another's view blurs what that one does, not that view (a card's
    /// row of spaces over the card, PagerStage.ground).
    var group: String? {
        didSet {
            guard group != oldValue else { return }
            grouped = true
            strip()
        }
    }
    /// A group was ever asked for: until then the blur's own is left alone.
    private var grouped = false

    private func strip() {
        guard let root = layer else { return }
        let backdrop: AnyClass? = NSClassFromString("CABackdropLayer")
        let grouping = NSSelectorFromString("setGroupName:")
        for material in root.sublayers ?? [] {
            for part in material.sublayers ?? [] where !part.isHidden {
                if let backdrop, part.isKind(of: backdrop) {
                    if grouped, part.responds(to: grouping) { part.setValue(group, forKey: "groupName") }
                } else if backdrop != nil {
                    part.isHidden = true
                }
            }
        }
    }

    override func updateLayer() { super.updateLayer(); strip() }
    override func layout() { super.layout(); strip() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); strip() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); strip() }
}

/// What the words work out to, as a launcher's calculator shows it: the
/// question on the left as it was read, the answer on the right, each with
/// a line under it saying what it is, an arrow between. Return copies the
/// answer (the foot says so).
struct CalcCard: View {
    let answer: Calc.Answer
    let chosen: Bool

    static let height: CGFloat = 96

    var body: some View {
        HStack(spacing: 0) {
            side(answer.question, answer.questionNote, swatch: {
                if case .color(let rgb) = answer.kind { return rgb }
                return nil
            }())
            Symbol("arrow.right", size: 13)
                .foregroundStyle(Palette.muted)
                .frame(width: 32)
            side(answer.result, answer.resultNote, strong: true)
        }
        .frame(height: Self.height)
        .background {
            RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
                .fill(chosen ? Omnibox.chosenFill : Palette.ink.opacity(0.04))
        }
        .padding(.bottom, 4)
        // State, not geometry: on the card the moment it is chosen.
        .transaction { $0.animation = nil }
    }

    /// One half of the card. A color's question carries its swatch in line
    /// before the words, so both halves keep their width and the arrow
    /// stays in the middle.
    private func side(_ words: String, _ note: String, strong: Bool = false, swatch: UInt32? = nil) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                if let swatch { CalcSwatch(rgb: swatch, side: 20) }
                Text(words)
                    .font(.system(size: 22, weight: strong ? .semibold : .regular))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
            }
            Text(note.isEmpty ? " " : note)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }
}

/// Only the hidden compact list uses these values. Holding five slots
/// keeps its native row menus and hover views alive through Escape/Cmd-L;
/// the next Cmd-T rewrites their contents instead of mounting them again.
@MainActor
private final class RetainedFieldRows: ObservableObject {
    private(set) var offers: [Suggestion] = []
    private var watching: AnyCancellable?

    init(browser: Browser) {
        watching = browser.query.$offers.sink { [weak self, weak browser] offers in
            guard let self, let browser else { return }
            if browser.windowPurpose.isPrivate(active: (browser.fieldGuest ?? browser.active)?.shy) {
                self.offers = []
                return
            }
            let query = browser.query
            guard browser.prefs.compactField, query.place == nil, !query.answering, !offers.isEmpty else { return }
            // The address's page actions are not displayed in Compact.
            if let here = query.here, query.typed == Address.whole(here) { return }
            let first = Array(offers.prefix(Omnibox.compactRows))
            self.offers = first + Array(self.offers.dropFirst(first.count))
        }
    }
}

/// A card's shadow alone, cut out where the card is, so it falls round
/// the glass and never shows through it: a near one and a far one, deeper
/// on a dark box. Drawn from the plain shape, once, not from what the card
/// holds on each keystroke.
struct FieldShadow: View {
    let shape: RoundedRectangle
    let dark: Bool

    var body: some View {
        ZStack {
            shape.fill(.black)
                .cast(dark ? Shadow.fieldNearDark : Shadow.fieldNear)
                .cast(dark ? Shadow.fieldFarDark : Shadow.fieldFar)
            shape.fill(.black).blendMode(.destinationOut)
        }
        .compositingGroup()
        .allowsHitTesting(false)
    }
}

extension Omnibox {
    /// The icon a row for a page or a site wears: only what is already on
    /// this Mac, a list that fetched as you typed would be fetching for
    /// every letter.
    @MainActor static func favicon(for offer: Suggestion) -> NSImage? {
        // Yab's own page wears its tab's mark, not a letter of yab://.
        if let own = Tab.ownIcon(offer.url) { return own }
        // A page seen before wears what it wore, a slideshow's own and
        // not the Docs icon its host keeps (Favicons.pageIcon).
        if QuickActions.site(of: offer) == nil, let url = offer.url, let hit = Favicons.shared.pageIcon(url) { return hit }
        // A port's own site wears its own icon, none of its host's.
        if QuickActions.site(of: offer) == nil, let url = offer.url, let site = Favicons.site(url), site != url.host()?.lowercased() {
            return Favicons.shared.cached(site)
        }
        guard let host = QuickActions.site(of: offer) ?? offer.url?.host()?.lowercased() else { return nil }
        return Favicons.shared.cached(host)
            ?? Favicons.shared.cached(host.hasPrefix("www.") ? String(host.dropFirst(4)) : "www." + host)
    }
}
