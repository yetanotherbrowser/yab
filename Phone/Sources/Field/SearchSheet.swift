import SwiftUI
import UIKit

/// Search as a low sheet over the page, as wide as the
/// keyboard: the field on top, under it the omnibox's rows (recent pages, or
/// what the words found), the page dimmed behind. Pulled up, the sheet becomes
/// the spaces, its second height, under the finger; pulled down, it goes.
struct SearchSheetPose: Equatable {
    /// How far `e` has come through a stretch of the way, 0 to 1.
    static func share(_ e: CGFloat, in stretch: ClosedRange<CGFloat>) -> CGFloat {
        min(max((e - stretch.lowerBound) / (stretch.upperBound - stretch.lowerBound), 0), 1)
    }


    /// 0 the low sheet, 1 the whole screen's spaces.
    var expand: CGFloat
    /// 0 under the screen's foot, 1 standing on the keyboard.
    var rise: CGFloat
    /// What stands under the field.
    var body: CGFloat
    /// 0 where it stands, 1 at the screen's top: a new page chosen.
    var leave: CGFloat = 0
    /// What it grows out of as it rises (the plate, +); nil rises from under the screen.
    var origin: CGRect? = nil

    /// How much of the sheet's own ground and rows has come, out of `origin`.
    func grown(_ stretch: ClosedRange<CGFloat>) -> CGFloat {
        origin == nil ? 1 : Self.share(rise, in: stretch)
    }
}

extension Metrics {
    enum SearchSheet {
        static let top: CGFloat = 16
        static let gap: CGFloat = 8
        static let foot: CGFloat = 14
        /// The field and the rows 16 from the screen's sides.
        static let fieldInset: CGFloat = 16
        /// Concentric with the field, which stands `fieldInset` in from its top and sides.
        static let radius: CGFloat = Metrics.Field.newTabHeight / 2 + fieldInset
        /// The field's magnifier on the rows' icons, its words on their titles.
        static let fieldLeading: CGFloat = 12
        /// Rows under the field, as the omnibox shows; the sheet keeps their
        /// height so the field stays put as words change.
        static let rows = 5
        /// The eyes: the sheet stands still, only its color and what is on it turn.
        static let privateTurn: Double = 0.2
        static let privateTint: Double = 0.86
        static let grabber = CGSize(width: 36, height: 5)
        static let grabberTop: CGFloat = 5
        /// Past this share of the way, let go, it opens.
        static let opensAt: CGFloat = 0.3
        static let flick: CGFloat = 900
        /// The morph, by share of the way: the rows are gone before the spaces
        /// come, so two lists never meet; the field turns into the capsule as
        /// it rises; the head and the foot bar come last.
        static let rowsOut: ClosedRange<CGFloat> = 0.08...0.22
        static let spacesIn: ClosedRange<CGFloat> = 0.28...0.45
        static let wordsOut: ClosedRange<CGFloat> = 0.2...0.36
        static let fieldToCapsule: ClosedRange<CGFloat> = 0.2...1
        static let headIn: ClosedRange<CGFloat> = 0.7...0.95
        static let barIn: ClosedRange<CGFloat> = 0.7...1
        static let fieldOut: ClosedRange<CGFloat> = 0.85...1
        /// Growing out of a control: the ground first, then the rows and the field's words.
        static let groundIn: ClosedRange<CGFloat> = 0...0.3
        static let rowsIn: ClosedRange<CGFloat> = 0.3...0.75
        static let wordsIn: ClosedRange<CGFloat> = 0.2...0.6
        /// Going up: the words go at once, the ground turns solid for the page to stand on.
        static let leaveWords: ClosedRange<CGFloat> = 0...0.4
        static let leaveSolid: ClosedRange<CGFloat> = 0.25...0.9
        /// The page shows through this far into the way up.
        static let revealAt: Double = 0.6
        /// The spaces stand this far low as they come, and fade in under the field this soft.
        static let spacesRise: CGFloat = 14
        static let spacesEdge: CGFloat = 26
        /// The spaces get built once the sheet has risen, so the first frame of a pull has them.
        /// The height under the field: the same public or private, so the eyes never move the sheet.
        static func body(plain: Bool) -> CGFloat { plain ? foot : CGFloat(rows) * Metrics.FieldCard.line + foot }
        /// Past the rise and the keyboard: the card's first build stops the main thread.
        static let spacesReadyAfter: Duration = .milliseconds(900)
        /// The glass's tint, so the rows read over the dimmed page.
        static let glassTint: Double = 0.45
        /// A breath of the space's own color on the glass.
        static let spaceTint: Double = 0.1
        /// The page beside the sheet.
        static let dim: Double = 0.3
    }
}

extension FieldGeometry {
    private typealias S = Metrics.SearchSheet
    private func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    /// The sheet's top on its keyboard, before it is pulled.
    private func sheetTop(_ pose: SearchSheetPose) -> CGFloat {
        size.height - keyboard - (S.top + sheetFieldHeight + S.gap + pose.body)
    }

    /// The finger's way from the sheet to the whole screen: the sheet's top follows it one to one.
    func sheetSpan(_ pose: SearchSheetPose) -> CGFloat { max(1, sheetTop(pose)) }

    /// The field on the sheet's top, turning into the spaces' capsule as it rises.
    func sheetField(_ pose: SearchSheetPose, height h: CGFloat) -> CGRect {
        let t = SearchSheetPose.share(pose.expand, in: S.fieldToCapsule)
        let capsule = SpacePagesCard.restCapsule(width: size.width, sides: ChromeGeometry.effectiveSides)
        let field = CGRect(x: mix(S.fieldInset, capsule.minX, t), y: max(sheetRect(pose).minY + S.top, capsule.minY),
                           width: mix(size.width - S.fieldInset * 2, capsule.width, t), height: mix(h, capsule.height, t))
        guard let origin = pose.origin else { return field }
        return CGRect(x: mix(origin.minX, field.minX, pose.rise), y: field.minY,
                      width: mix(origin.width, field.width, pose.rise), height: mix(origin.height, field.height, pose.rise))
    }

    func sheetRestField(height h: CGFloat) -> CGRect {
        CGRect(x: Metrics.Field.newTabInset,
               y: size.height - Metrics.NewTab.restingFoot - Metrics.Field.newTabAboveKeyboard - h,
               width: size.width - Metrics.Field.newTabInset * 2 - h - Metrics.Field.closeGap, height: h)
    }

    func sheetRect(_ pose: SearchSheetPose) -> CGRect {
        let top = mix(mix(sheetTop(pose), 0, pose.expand), 0, pose.leave)
        return CGRect(x: 0, y: top, width: size.width, height: size.height - top)
    }

    /// How far under its place the sheet stands while it rises and goes.
    func sheetDrop(_ pose: SearchSheetPose) -> CGFloat {
        if let origin = pose.origin { return (1 - pose.rise) * (origin.minY - S.top - sheetTop(pose)) }
        return (1 - pose.rise) * (size.height - sheetTop(pose) + S.foot)
    }
}

extension AppModel {
    /// The space the sheet is about: the one the spaces last stood on, else the one in front.
    var searchSheetSpace: Space {
        if let id = NewTabPager.shared.spaceID, let space = browser.space(id), !space.isPrivate { return space }
        if !browser.space.isPrivate { return browser.space }
        return browser.space(browser.ordinarySpaceID) ?? browser.space
    }
}

/// The sheet's ground, under the spaces (FieldSurface keeps one spaces card for
/// the whole morph, so the sheet never builds them anew under a moving finger).
struct SearchSheetGround: View {
    @Environment(AppModel.self) private var app
    let geometry: FieldGeometry
    let pose: SearchSheetPose

    private typealias S = Metrics.SearchSheet

    var body: some View {
        let model = app.field
        let e = pose.expand
        let rect = geometry.sheetRect(pose)
        let shape = RoundedRectangle(cornerRadius: S.radius + (LiftFrame.screenCorner - S.radius) * max(e, pose.leave), style: .continuous)
        let spacesIn = SearchSheetPose.share(e, in: S.spacesIn)
        // Liquid Glass at rest; the space's color comes up with its spaces, over the whole
        // sheet at once, so the sheet stays one sheet. The eyes darken it where it stands.
        ZStack {
            Color.clear.glassEffect(.regular.tint(Ink.surface.opacity(S.glassTint)), in: shape)
            Color(rgb: SpacePagesCard.ownColor(of: app.searchSheetSpace)).opacity(model.isPrivate ? 0 : S.spaceTint).clipShape(shape)
            wash()
                .clipShape(shape)
                .opacity(model.isPrivate ? 0 : Double(spacesIn))
            Color(rgb: SpacePagesCard.privateWash)
                .clipShape(shape)
                .opacity(model.isPrivate ? max(S.privateTint, Double(spacesIn)) : 0)
            Ink.surface
                .clipShape(shape)
                .opacity(Double(SearchSheetPose.share(pose.leave, in: S.leaveSolid)))
        }
        .opacity(Double(pose.grown(S.groundIn)) * model.sheetVeil)
        .animation(Motion.disabled ? nil : .easeInOut(duration: S.privateTurn), value: model.isPrivate)
        .frame(width: rect.width, height: rect.height)
        .contentShape(shape)
        .onTapGesture {}
        .gesture(model.sheetDrag)
        .offset(x: rect.minX, y: rect.minY + geometry.sheetDrop(pose))
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        .accessibilityHidden(true)
        .onChange(of: geometry.sheetSpan(pose), initial: true) { _, span in model.sheetSpan = span }
        .task {
            try? await Task.sleep(for: S.spacesReadyAfter)
            // VoiceOver keeps to the sheet: there the spaces come only when asked for.
            // Nor under words being typed: the keys come first, a pull builds them.
            if !UIAccessibility.isVoiceOverRunning, model.text.isEmpty { model.sheetSpacesReady = true }
        }
    }

    private func wash() -> some View {
        let spaces = app.browser.spaces.filter { !$0.isPrivate }
        let pages = [NewTabPager.privatePage, NewTabPager.chatsPage] + spaces.map(\.id)
        return SpacePagesBackground(spaces: spaces, pages: pages,
                                    position: CGFloat(pages.firstIndex(of: app.searchSheetSpace.id) ?? 2))
    }
}

/// Where the one spaces card stands during the morph: riding the sheet under
/// the field, its head coming last.
extension FieldGeometry {
    func sheetSpacesHang(_ pose: SearchSheetPose) -> CGFloat {
        typealias S = Metrics.SearchSheet
        let top = sheetRect(pose).minY + S.top + sheetFieldHeight + S.gap
        return max(0, top - SpacePagesCard.restHead) + S.spacesRise * (1 - SearchSheetPose.share(pose.expand, in: S.spacesIn))
    }

    /// How much of the screen's top stays hidden, its soft edge just under.
    func sheetSpacesHidden(_ pose: SearchSheetPose) -> CGFloat {
        typealias S = Metrics.SearchSheet
        let head = SearchSheetPose.share(pose.expand, in: S.headIn)
        return max(sheetRect(pose).minY, sheetSpacesHang(pose) + SpacePagesCard.restHead * (1 - head))
    }
}

/// The sheet's front, over the spaces: its grabber and what stands under the field.
struct SearchSheetFront: View {
    @Environment(AppModel.self) private var app
    let rows: [WordRow]
    let recent: [NewTabItem]
    let geometry: FieldGeometry
    let pose: SearchSheetPose

    private typealias S = Metrics.SearchSheet

    var body: some View {
        let model = app.field
        let e = pose.expand
        let rect = geometry.sheetRect(pose)
        let top = rect.minY + S.top + geometry.sheetFieldHeight + S.gap
        let rowsGone = 1 - (1 - SearchSheetPose.share(e, in: S.rowsOut)) * pose.grown(S.rowsIn)
            * (1 - SearchSheetPose.share(pose.leave, in: S.leaveWords))
        ZStack(alignment: .topLeading) {
            Capsule().fill(Color.primary.opacity(0.2))
                .frame(width: S.grabber.width, height: S.grabber.height)
                .offset(x: (geometry.size.width - S.grabber.width) / 2, y: rect.minY + S.grabberTop)
                .opacity(Double(1 - rowsGone))
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            SearchSheetLines(rows: rows, recent: recent, dark: model.isPrivate)
                .equatable()
                .frame(width: rect.width - S.fieldInset * 2, alignment: .topLeading)
                .offset(x: rect.minX + S.fieldInset, y: top)
                .opacity(Double(1 - rowsGone))
                // A finger that started on a row keeps its pull as they fade.
                .allowsHitTesting(e < 0.02 || model.sheetPulling)
        }
        .offset(y: geometry.sheetDrop(pose))
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.sheet")
        .accessibilityValue(e < 0.01 ? "low" : e >= 1 ? "spaces" : "pulled")
        .accessibilityAction(named: "Show Spaces") { model.expandSheet() }
    }

}

/// What stands under the field. The eyes turn it through a blur, the sheet still.
/// The sheet moves it from outside; its own body runs when the rows change.
struct SearchSheetLines: View, Equatable {
    @Environment(AppModel.self) private var app
    let rows: [WordRow]
    let recent: [NewTabItem]
    let dark: Bool

    private typealias S = Metrics.SearchSheet

    static func == (a: Self, b: Self) -> Bool { a.rows == b.rows && a.recent == b.recent && a.dark == b.dark }

    var body: some View {
        ZStack(alignment: .top) {
            if !rows.isEmpty {
                typed(dark: dark).transition(.blurReplace)
            } else if dark {
                Text("You\u{2019}re browsing privately")
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .highPriorityGesture(app.field.sheetDrag)
                    .transition(.blurReplace)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { i, item in
                        Button {
                            if !app.field.sheetSwallowsTap { app.choose(item) }
                        } label: {
                            WordRowView(row: WordRow(action: .tab(id: item.id), icon: item.icon, title: item.title, subtitle: item.subtitle,
                                                     key: .go, group: .tabs), best: false, pageURL: item.pageURL)
                        }
                        .buttonStyle(WordRowPress(best: false, fill: .clear))
                        .accessibilityIdentifier("search.recent.\(i)")
                        .contextMenu {
                            if let site = item.removable {
                                Button("Remove from Suggestions") {
                                    SuggestionMemory.remove(site)
                                    app.field.picksRevision += 1
                                }
                            }
                        }
                        // A page from history has no tab to fetch its icon for it.
                        .task(id: item.id) { if let page = item.pageURL { await SiteIcons.shared.load(for: page) } }
                    }
                }
                .contentShape(Rectangle())
                // Over the buttons: a row travels with the finger, and letting go on it would open it.
                .highPriorityGesture(app.field.sheetDrag)
                .transition(.blurReplace)
            }
        }
        .frame(height: CGFloat(S.rows) * Metrics.FieldCard.line, alignment: .top)
        .animation(Motion.disabled ? nil : .easeInOut(duration: S.privateTurn), value: dark)
    }

    /// The typed rows, the best one right under the field.
    private func typed(dark: Bool) -> some View {
        let answer = app.fieldAnswer
        let keyCopies = answer != nil && app.fieldAnswerTakesKey
        let fill = WordRowView.bestFill(dark: dark)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if let answer {
                    AnswerPlate(answer: answer, words: app.field.words, lit: keyCopies ? fill : nil, dark: dark, copy: app.copyFieldAnswer)
                        .padding(.bottom, Metrics.FieldCard.linesOverField)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    Button { app.choose(row) } label: {
                        WordRowView(row: row, best: i == 0 && !keyCopies, dark: dark, isPrivate: app.field.isPrivate)
                    }
                    .buttonStyle(WordRowPress(best: i == 0 && !keyCopies, fill: fill))
                    .accessibilityIdentifier(i == 0 ? "field.best" : "field.row.\(i)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.FieldCard.lineRadius, style: .continuous))
        .frame(height: CGFloat(S.rows) * Metrics.FieldCard.line, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("field.rows")
    }
}

/// The phone spaces' foot: New Tab, the space picker, and Done.
/// The tablet column keeps its own Settings and search controls.
struct SpacesFootBar: View {
    @Environment(AppModel.self) private var app
    let size: CGSize

    var body: some View {
        let model = app.field
        // The column beside a page is a phone's width: its foot is a phone's
        // row, and only the window's left edge is reserved from it.
        let column = size.width < app.workspace.windowSize.width - 0.5
        let phonePicker = !column && !app.workspace.tabletControls
        let layout = column
            ? TabGalleryLayout(screen: size, count: 0, verticalControls: false, sides: app.workspace.sides(ofSurface: size.width))
            : TabGalleryLayout(screen: size, count: 0, verticalControls: phonePicker ? false : app.workspace.verticalControls,
                               leadingRail: app.workspace.leadingRail)
        let chats = NewTabPager.shared.onChats
        ZStack(alignment: .topLeading) {
            if phonePicker {
                button(layout.chats, Circle(), id: chats ? "spaces.newChat" : "spaces.new",
                       label: chats ? "New Chat" : "Search",
                       action: { if chats { app.newChatFromSpaces() } else { model.askFromSpaces() } }) {
                    Glyph(.plusMedium, size: Metrics.Chrome.spaceEmoji, color: Ink.primary)
                }
                // The header's capsule itself, moved to the foot: it follows the
                // pages under a finger and turns them, as it did on top.
                let pager = NewTabPager.shared
                let spaces = app.browser.spaces.filter { !$0.isPrivate }
                let pages = [NewTabPager.chatsPage] + spaces.map(\.id)
                let current = pager.onChats ? 0 : (pages.firstIndex(of: pager.spaceID ?? "") ?? 0)
                CardCapsule(names: ["Chats"] + spaces.map(\.name), current: current,
                            position: min(max(pager.position, 0), CGFloat(pages.count - 1)),
                            width: SpacesFootBar.capsuleWidth(layout), dark: false, bare: true, shared: .foot,
                            pagingByGesture: pager.pagingByGesture) { i in
                    app.field.putKeyboardAway()
                    pager.jump = pages[i]
                } sheetDrag: { _, _, _ in } about: {} settings: {}
                .position(x: SpacesFootBar.capsuleMidX(layout), y: layout.plus.midY)
            } else {
            // One glass in each place; only its glyph turns, through a blur, as the page does.
            button(layout.chats, Circle(), id: chats ? "spaces.newChat" : "newtab.settings", label: chats ? "New Chat" : "Settings",
                   action: { if chats { app.newChatFromSpaces() } else { app.openSettingsFromSpaces(at: nil) } }) {
                ZStack {
                    if chats {
                        Image("MacSquareAndPencil").renderingMode(.template).resizable().frame(width: 22, height: 22)
                            .transition(.blurReplace)
                    } else {
                        Glyph(SettingsFieldRow.glyph, size: Metrics.Chrome.spaceEmoji, color: Ink.primary)
                            .transition(.blurReplace)
                    }
                }
            }
            // The column's foot: the gear on the left, a round + on the right.
            let plus = column ? layout.gear : layout.plus
            button(plus, Capsule(style: .continuous), id: chats ? "spaces.search" : "spaces.new", label: chats ? "Search Chats" : "Search",
                   action: { if chats { model.askFrom(layout.plus) } else { model.askFromSpaces() } }) {
                ZStack {
                    if chats {
                        Glyph(.magnifyingGlass, size: Metrics.Chrome.spaceEmoji, color: Ink.primary)
                            .transition(.blurReplace)
                    } else {
                        Glyph(.plusMedium, size: Metrics.Chrome.spaceEmoji, color: Ink.primary)
                            .transition(.blurReplace)
                    }
                }
            }
            }
            if !column {
            Button { model.close() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: layout.gear.width, height: layout.gear.height)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Color.accentColor).interactive(), in: Circle())
            .position(x: layout.gear.midX, y: layout.gear.midY)
            .accessibilityLabel("Done")
            .accessibilityIdentifier("spaces.done")
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(Motion.disabled ? nil : .easeInOut(duration: 0.28), value: chats)
    }

    /// The capsule's room between + and Done, in the spaces' foot and All Tabs' alike.
    static func capsuleWidth(_ layout: TabGalleryLayout) -> CGFloat {
        layout.gear.minX - layout.chats.maxX - 2 * Metrics.NewTab.spacePickerControlGap
    }

    /// The middle of that room, not the screen's: a status column on one side
    /// moves Done in and the screen's middle would put the capsule under it.
    static func capsuleMidX(_ layout: TabGalleryLayout) -> CGFloat {
        (layout.chats.maxX + layout.gear.minX) / 2
    }

    private func button<S: Shape, Label: View>(_ rect: CGRect, _ shape: S, id: String, label: String, action: @escaping () -> Void,
                                               @ViewBuilder glyph: () -> Label) -> some View {
        Button(action: action) {
            glyph()
                .foregroundStyle(Ink.primary)
                .frame(width: rect.width, height: rect.height)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: shape)
        .position(x: rect.midX, y: rect.midY)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// The three dots at the capsule's right: the system's menu, which grows out
/// of the button, with this page's filters and the quick switch.
struct SpacesMoreMenu: View {
    let dark: Bool

    var body: some View {
        let pager = NewTabPager.shared
        Menu {
            if pager.onChats {
                Picker("Chats", selection: Binding(get: { pager.showsArchive }, set: { value in
                    Motion.columnRows.run { pager.showsArchive = value }
                })) {
                    Text("All Chats").tag(false)
                    Text("Archived").tag(true)
                }
                .pickerStyle(.inline)
            } else {
                Picker("Show", selection: Binding(get: { pager.spaceFilter }, set: { value in
                    Motion.columnRows.run { pager.spaceFilter = value }
                })) {
                    Text("Everything").tag(NewTabPager.SpaceFilter.everything)
                    Text("Pins").tag(NewTabPager.SpaceFilter.pins)
                    Text("Today").tag(NewTabPager.SpaceFilter.today)
                }
                .pickerStyle(.inline)
                Section {
                    Toggle("Your Mac\u{2019}s Tabs", isOn: Binding(get: { SettingsStore.shared.macTabs },
                                                                   set: { SettingsStore.shared.macTabs = $0 }))
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(dark ? Color.white : Ink.primary)
                .frame(width: Metrics.touch, height: Metrics.touch)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("newtab.more")
    }
}
