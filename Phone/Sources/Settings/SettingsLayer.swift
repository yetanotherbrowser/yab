import SwiftUI
import UIKit

/// Settings, the whole screen (its head under the status bar), and joining a
/// Mac over it. Shown when Surfaces.settings says so, from the column's gear,
/// Site Settings or the word "settings" in the field: it rises from below as
/// iOS presents a screen (settingsOpen, 0.5 s) while the page behind dims a
/// little, and drops away (settingsClose, 0.3 s). Nothing grows out of what opened it and
/// nothing reopens when it goes. Closed by ×, by a swipe down on its head,
/// or by pulling its list down past the top.
struct SettingsLayer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let ui = SettingsUI.shared
        GeometryReader { geo in
            let tablet = app.workspace.tabletControls || app.workspace.unfolded
            let size = tablet ? CGSize(width: max(1, min(TabletWorkspaceGeometry.sheetWidth, geo.size.width - 48)),
                                       height: max(1, min(TabletWorkspaceGeometry.sheetHeight, geo.size.height - 80))) : geo.size
            let origin = CGPoint(x: (geo.size.width - size.width) / 2, y: (geo.size.height - size.height) / 2)
            // Join keeps its sheet's place over Settings, 60 under the top.
            let joinSize = CGSize(width: size.width, height: max(0, size.height - Metrics.Settings.top))
            let column = tablet ? nil : SettingsColumn(workspace: app.workspace, size: size, folded: app.chrome.folded, hasNow: app.nowItem != nil)
            ZStack(alignment: .topLeading) {
                if ui.sheet.presented {
                    Color.black
                        .opacity(Metrics.Settings.dim * ui.sheet.presence(height: size.height))
                        .frame(width: geo.size.width, height: geo.size.height)
                        // On iPad the sheet is a card: a tap beside it closes it, as a form sheet does.
                        .contentShape(Rectangle())
                        .onTapGesture { if tablet, !ui.join.presented { app.surfaces.closeSettings() } }
                        .allowsHitTesting(tablet)
                        .accessibilityHidden(true)
                    SettingsViewport(app: app, size: size, top: tablet ? Metrics.Settings.cardTop : SettingsLayer.statusBar, keyboardOffset: origin.y, column: column)
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: tablet ? 22 : 0))
                        // Corners while it moves; at rest none, the screen's own glass rounds it.
                        .growing(ui.sheet, size: size, topRadius: tablet ? 22 : (ui.sheet.settled ? 0 : LiftFrame.screenCorner))
                        .offset(x: origin.x, y: origin.y)
                        .accessibilityAction(.escape) {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            app.surfaces.closeSettings()
                        }
                }
                if ui.join.presented {
                    JoinSheet(size: joinSize)
                        .offset(x: origin.x, y: origin.y + Metrics.Settings.top)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onChange(of: size, initial: true) { _, value in ui.sheetHeight = value.height }
        }
        .ignoresSafeArea()
        .settingsAppearance(probe: true)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, DefaultBrowser.asksOnReturn else { return }
            DefaultBrowser.asksOnReturn = false
            SettingsContext.checkDefaultBrowser(ui, force: true)
        }
        .onChange(of: app.surfaces.settings, initial: true) { _, open in
            if open {
                SettingsContext.checkDefaultBrowser(ui)
                ui.sheet.show(from: nil)
            } else if ui.flickNext {
                ui.flickNext = false
                ui.sheet.flick(height: ui.sheetHeight) { ui.settingsGone() }
            } else {
                ui.sheet.hide(back: false) { ui.settingsGone() }
            }
        }
        .onChange(of: app.surfaces.join, initial: true) { _, open in
            if open {
                ui.join.show(from: app.surfaces.joinOrigin.map(SettingsUI.inSheet), radius: ui.joinOriginRadius)
                ui.joinOriginRadius = Metrics.Settings.originRadius
            } else if ui.flickNext {
                ui.flickNext = false
                ui.join.flick(height: ui.sheetHeight)
            } else {
                // Back into the welcome's button or the Sync row, both still there.
                ui.join.hide(back: true)
            }
        }
    }
}

extension SettingsLayer {
    /// What the status bar takes at the top of the whole-screen Settings.
    @MainActor static var statusBar: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }?.safeAreaInsets.top ?? 59
    }
}

/// Settings beside a status column (an iPhone Duo's cover). Apple puts Back
/// or Close at the top of the column, so the head's button stands exactly
/// where the page's Back does, and the head and bodies keep to the safe area.
struct SettingsColumn: Equatable {
    /// The page's Back, from the chrome's own geometry: it already clears
    /// the camera, a Live Activity and a fold.
    let button: CGRect
    let sides: ChromeGeometry.Sides

    /// nil without a status column: the head as on every other phone. The
    /// workspace's own reservations (the whole window's, as Settings is) are
    /// observed, so a Live Activity growing while Settings is open moves it.
    @MainActor init?(workspace: BrowserWorkspace, size: CGSize, folded: Bool, hasNow: Bool) {
        guard workspace.statusColumn else { return nil }
        sides = workspace.sides(ofSurface: size.width)
        button = ChromeGeometry(size: size, folded: folded, hasNow: hasNow, verticalControls: workspace.verticalControls,
                                leadingRail: workspace.leadingRail, sides: sides, reservations: workspace.reservations).back
    }
}

/// The Settings sheet: one head and one body. The head's button on the left
/// (at the top of a status column) is × on the root and ‹ on a page, the one turning into the other; its
/// title crossfades. A page does not push in from the side: it changes the
/// body in place, the old body going up 8 and out while the new one comes
/// from 8 below, overlapping (settingsPush, 0.28 s; back, 0.22 s). The root
/// and every page under the one in front stay alive, hidden, so the query,
/// the scroll position and what a page was doing are there on the way back.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let size: CGSize
    /// The status bar over its head: Settings is the whole screen.
    var top: CGFloat = 0
    var keyboardOffset: CGFloat = 0
    var column: SettingsColumn? = nil
    @State private var position = ScrollPosition(edge: .top)
    @State private var pulledFar = false
    @State private var keyboard: CGFloat = 0

    /// A page over the root: where it is in the stack and what it shows.
    private struct Layer: Hashable, Identifiable {
        let depth: Int
        let route: SettingsRoute
        var id: Self { self }
    }

    var body: some View {
        let ui = SettingsUI.shared
        let routes = ui.navigation
        let layers = routes.enumerated().map { Layer(depth: $0.offset, route: $0.element) }
        // The rows go on under the head and the status bar as they scroll up,
        // under the standard iOS bar: a blurred ground down to the head's
        // foot, with its hairline, there only once rows are under it.
        let barShown = routes.isEmpty ? ui.rootUnder : ui.pageUnder
        let sides = column?.sides ?? .zero
        // How far a finger has taken the page in front back, 0 to 1: the
        // button and the title go over to the page under it as it goes.
        let pull = size.width > 0 ? min(max(ui.backDrag / size.width, 0), 1) : 0
        // The page in front is the one Settings opened at: × closes, as on the root.
        let onPage = !routes.isEmpty && !ui.standsAsRoot
        let button = SettingsHeadButton(page: !onPage ? 0 : routes.count == 1 ? 1 - pull : 1,
                                        diameter: column?.button.width ?? Metrics.Settings.headButton,
                                        action: onPage ? { ui.closePage() } : close)
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                root
                    .settingsBody(level: routes.count, width: size.width, drag: ui.backDrag)
                ForEach(layers) { layer in
                    SettingsDestinationView(route: layer.route)
                        .settingsBody(level: routes.count - 1 - layer.depth, width: size.width, drag: ui.backDrag)
                        .zIndex(Double(layer.depth + 1))
                        .transition(.settingsBody)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .safeAreaPadding(.top, top + Metrics.Settings.headBar)
            .safeAreaPadding(.leading, sides.left)
            .safeAreaPadding(.trailing, sides.right)
            .scrollEdgeEffectHidden(true, for: .top)
            .clipped()
            SettingsHeadBar()
                .frame(height: top + Metrics.Settings.headBar)
                .opacity(barShown ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: barShown)
                .allowsHitTesting(false)
            SettingsHead(routes: routes, pull: pull, button: column == nil ? button : nil, drag: headerDrag)
                .padding(.leading, sides.left)
                .padding(.trailing, sides.right)
                .padding(.top, top)
            if let column {
                button.position(x: column.button.midX, y: column.button.midY)
            }
        }
        .tint(SettingsInk.text)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .safeAreaPadding(.bottom, keyboard)
        .transaction { if reduceMotion || Motion.reducedForTests { $0.disablesAnimations = true } }
        .frame(width: size.width, height: size.height)
        .background(SettingsInk.pageGround)
        .surfaceContents(ui.sheet)
        .onAppear { ui.sheet.appeared() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let bottom = size.height + keyboardOffset
            keyboard = min(size.height, max(0, bottom - frame.minY))
        }
    }

    // MARK: - the root

    private var root: some View {
        @Bindable var ui = SettingsUI.shared
        let content = SettingsContent(store: SettingsStore.shared, context: SettingsContext(app: app), tabletLayout: app.workspace.preferences)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Metrics.Settings.headGap) {
                    Glyph(.magnifyingGlass, size: Metrics.Settings.searchIcon, color: SettingsInk.value)
                    SettingsSearchField(text: $ui.search)
                        .frame(maxWidth: .infinity)
                    if !ui.search.isEmpty {
                        SettingsSearchClear { ui.search = "" }
                            .frame(width: Metrics.touch, height: Metrics.touch)
                    }
                }.padding(.horizontal, Metrics.Settings.searchInset)
                    .frame(minHeight: Metrics.Settings.searchHeight)
                    .modifier(SettingsSearchGlass(opaque: reduceTransparency))
                    .padding(.bottom, Metrics.Settings.searchGap)
                if ui.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: Metrics.Settings.indexGap) {
                        ForEach(Array(SettingsIndex.groups.enumerated()), id: \.offset) { _, pages in
                            SettingsIndexCard {
                                ForEach(pages) { page in
                                    indexRow(page, detail: indexValue(page), id: "settings.row." + page.rawValue) { ui.openPage(page) }
                                }
                            }
                        }
                    }
                } else {
                    let matches = SettingsIndex.matches(ui.search, content: content)
                    if matches.isEmpty {
                        Text("No settings found").font(.body).foregroundStyle(SettingsInk.footer)
                            .frame(maxWidth: .infinity, minHeight: Metrics.touch).accessibilityIdentifier("settings.search.empty")
                    } else {
                        SettingsIndexCard {
                            ForEach(matches) { match in
                                indexRow(match.page, detail: match.detail, id: "settings.search.result." + match.id) {
                                    ui.openPage(match.page, from: match.row)
                                }
                            }
                        }
                    }
                }
            }.padding(.horizontal, Metrics.Settings.bodySide)
                .padding(.top, Metrics.Settings.indexTop)
                .padding(.bottom, Metrics.Settings.bodyBottom)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SettingsInk.pageGround)
        .scrollIndicators(.hidden)
        .scrollPosition($position)
        .scrollBounceBehavior(.always)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
            ui.rootOffset = y
            if ui.rootUnder != (y > 0.5) { ui.rootUnder = y > 0.5 }
            pulledFar = y < -Metrics.Settings.pullToClose
        }
        .onScrollPhaseChange { old, new in
            if old == .interacting, new != .interacting, pulledFar {
                ui.flickNext = true
                close()
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom - geometry.containerSize.height)
        } action: { _, room in ui.listRoom = room }
        .task {
            guard let target = ui.scrollTarget else { return }
            ui.scrollTarget = nil
            var lastRoom: CGFloat = -1
            for _ in 0..<120 {
                if Task.isCancelled { ui.scrollTarget = target; return }
                position.scrollTo(y: target)
                try? await Task.sleep(for: .milliseconds(16))
                let room = ui.listRoom
                if room == lastRoom, ui.rootOffset >= min(target, room) - 0.5 { break }
                lastRoom = room
            }
            ui.scrolled = true
        }
        .accessibilityIdentifier("settings.index")
    }

    /// A root row as on the Mac: the page's pen tile on paper, its name, and
    /// what it is set to under the name.
    private func indexRow(_ page: SettingsPageID, detail: String?, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Metrics.Settings.rowGap) {
                SettingsTile(page: page)
                VStack(alignment: .leading, spacing: 0) {
                    SettingsText(words: SettingsContent.title(page), ground: SettingsInk.group)
                    if let detail {
                        SettingsText(words: detail, style: .footnote, ink: SettingsInk.footer, ground: SettingsInk.group)
                    }
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(.horizontal, Metrics.Settings.rowPadding)
                .padding(.vertical, Metrics.Settings.indexRowPadding)
                .frame(minHeight: Metrics.Settings.indexRow)
                .contentShape(Rectangle())
        }.buttonStyle(SettingsRowStyle()).accessibilityIdentifier(id)
    }

    private func indexValue(_ page: SettingsPageID) -> String? {
        switch page {
        case .appearance: SettingsContent.words(SettingsStore.shared.appearance)
        case .appIcon: AppIconSelection.shared.title
        case .sync: app.hasMac ? app.macName : "Not joined"
        case .about: SettingsStore.version()
        default: nil
        }
    }

    // MARK: - closing

    private var headerDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { SettingsUI.shared.sheet.drag = max(0, $0.translation.height) }
            .onEnded { value in
                if value.translation.height > Metrics.Settings.closeDistance || value.velocity.height > Metrics.Settings.closeVelocity {
                    SettingsUI.shared.flickNext = true
                    close()
                } else { SettingsUI.shared.sheet.snap() }
            }
    }

    private func close() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        app.surfaces.closeSettings()
    }
}

/// The standard iOS bar behind the head: the system's bar material from the
/// screen's top to the head's foot, and its hairline.
private struct SettingsHeadBar: View {
    var body: some View {
        Rectangle()
            .fill(.bar)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(uiColor: .separator)).frame(height: 1 / UIScreen.main.scale)
            }
            .accessibilityHidden(true)
    }
}

/// The sheet's one head: the round glass button on the left (× on the root,
/// ‹ on a page; nil when it stands in a status column) and the title in the
/// middle ("Settings" on the root, a page whose body has no big title of its
/// own says its name here).
private struct SettingsHead<Drag: Gesture>: View {
    let routes: [SettingsRoute]
    /// How far a finger has taken the page in front back, 0 to 1 (SettingsSheet).
    var pull: CGFloat = 0
    let button: SettingsHeadButton?
    let drag: Drag

    var body: some View {
        let title = Self.title(routes.last)
        // The page under the one in front: the root's when only one is open.
        let under: String? = routes.isEmpty ? nil : Self.title(routes.count >= 2 ? routes[routes.count - 2] : nil)
        HStack(spacing: 0) {
            if let button { button }
            Spacer(minLength: 0)
        }
        .padding(.leading, Metrics.Settings.headSide)
        .frame(maxWidth: .infinity, minHeight: Metrics.Settings.headBar, maxHeight: Metrics.Settings.headBar)
        .overlay {
            ZStack {
                if let title {
                    SettingsText(words: title, weight: .semibold, ground: .clear, alignment: .center,
                                 identifier: "settings.title", isHeader: true)
                        .fixedSize()
                        .id(title)
                        .transition(.opacity)
                        .opacity(Double(1 - pull))
                }
                if pull > 0, let under, under != title {
                    SettingsText(words: under, weight: .semibold, ground: .clear, alignment: .center)
                        .fixedSize()
                        .opacity(Double(pull))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Metrics.Settings.headSide + Metrics.Settings.headButton + Metrics.Settings.headGap)
            .allowsHitTesting(false)
        }
        // The pull down to close is the head's ground's: the button keeps
        // its own touches and its own accessibility frame.
        .background {
            // See-through: the rows pass under it; it still takes the pull down.
            Color.clear
                .contentShape(Rectangle())
                .gesture(drag)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }

    /// The head's words for what is in front; nil where the body says it.
    static func title(_ route: SettingsRoute?) -> String? {
        switch route {
        case nil: "Settings"
        case .page(.appIcon)?: SettingsContent.title(.appIcon)
        case .page(.history)?: SettingsContent.title(.history)
        default: nil
        }
    }
}

/// × and ‹ are one button: the cross turns away and shrinks as the chevron
/// turns in, crossfading, in the body's own motion.
private struct SettingsHeadButton: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// 0 ×, 1 ‹, between them as a finger takes the last page back.
    let page: CGFloat
    /// The head's 44, or the rail's round in a status column.
    var diameter = Metrics.Settings.headButton
    let action: () -> Void
    private var onPage: Bool { page > 0.5 }

    var body: some View {
        Button(action: action) {
            ZStack {
                Glyph(.crossMedium, size: Metrics.Settings.crossIcon, color: SettingsInk.text)
                    .opacity(Double(1 - page))
                    .rotationEffect(.degrees(-90 * page))
                    .scaleEffect(1 - 0.3 * page)
                Glyph(.chevronLeft, size: Metrics.Settings.headIcon, color: SettingsInk.text)
                    .opacity(Double(page))
                    .rotationEffect(.degrees(90 * (1 - page)))
                    .scaleEffect(0.7 + 0.3 * page)
            }
            .frame(width: diameter, height: diameter)
            .modifier(SettingsHeadGlass(opaque: reduceTransparency))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(onPage ? "Back" : "Close")
        .accessibilityIdentifier(onPage ? "settings.back" : "settings.close")
    }
}

private struct SettingsHeadGlass: ViewModifier {
    let opaque: Bool
    func body(content: Content) -> some View {
        if opaque { content.background(SettingsInk.group, in: Circle()) }
        else { content.glassEffect(.regular.interactive(), in: Circle()) }
    }
}

/// The root's groups: white cards on the sheet's gray, as the Mac's window.
private struct SettingsIndexCard<Rows: View>: View {
    @ViewBuilder let rows: Rows
    var body: some View {
        VStack(spacing: 0) { rows }
            .padding(.vertical, Metrics.Settings.indexCardPadding)
            .background(SettingsInk.group)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.Settings.indexCardRadius, style: .continuous))
    }
}

private extension View {
    /// The bodies as iOS's navigation stacks them: the one in front (level 0)
    /// where a finger pulls it; the one under it (1) a third of the way left
    /// and a little dark, coming back as the front goes; deeper ones hidden.
    func settingsBody(level: Int, width: CGFloat, drag: CGFloat) -> some View {
        let p = width > 0 ? min(max(drag / width, 0), 1) : 0
        let x: CGFloat = level == 0 ? drag : level == 1 ? -width / 3 * (1 - p) : -width / 3
        return offset(x: x)
            .overlay {
                Color.black.opacity(level == 1 ? 0.08 * Double(1 - p) : 0).allowsHitTesting(false)
            }
            // Its edge's shadow, a strip of its own: a shadow on the whole page
            // would fall from every label onto the page's ground.
            .background(alignment: .leading) {
                LinearGradient(colors: [.clear, .black.opacity(0.1)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 14)
                    .offset(x: -14)
                    .opacity(level == 0 && drag > 0 ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .opacity(level >= 2 ? 0 : 1)
            .allowsHitTesting(level == 0)
            .accessibilityHidden(level != 0)
    }
}

private extension AnyTransition {
    /// A page comes in from the right edge and goes back out to it.
    static var settingsBody: AnyTransition { .move(edge: .trailing) }
}

private struct SettingsSearchGlass: ViewModifier {
    let opaque: Bool
    func body(content: Content) -> some View {
        if opaque { content.background(SettingsInk.group, in: Capsule()) }
        else { content.glassEffect(.regular, in: Capsule()) }
    }
}

/// What a tap on a row does, wherever the row is.
@MainActor
func settingsTap(_ row: SettingsRowModel, app: AppModel) {
    let ui = SettingsUI.shared
    switch row.kind {
    case let .page(id):
        ui.openPage(id, from: row.id)
    case .join:
        ui.joinOriginRadius = Metrics.Settings.originRadius
        app.openJoin(from: ui.rowFrames[row.id])
    case let .choice(_, choose):
        choose()
    case let .action(act):
        act()
    case .toggle, .info:
        break
    }
}

/// A page's body in the sheet: its own hero and rows; the sheet's head says
/// ‹. An edge swipe goes back too.
struct SettingsDestinationView: View {
    @Environment(AppModel.self) private var app
    let route: SettingsRoute
    var body: some View {
        Group {
            switch route {
            case .page(.appIcon): AppIconPickerView()
            case .page(.history): HistoryPage()
            case let .page(page): SettingsPageView(page: page)
            case let .space(id): SettingsSpacePage(spaceID: id)
            case let .spaceName(id): SettingsSpaceEditor(spaceID: id, step: .name)
            case let .spaceEmoji(id): SettingsSpaceEditor(spaceID: id, step: .emoji)
            case let .spaceColor(id): SettingsSpaceEditor(spaceID: id, step: .color)
            }
        }
        .gesture(SettingsBackGesture(route: route))
        .accessibilityAction(.escape) {
            if SettingsUI.shared.standsAsRoot { app.surfaces.closeSettings() } else { SettingsUI.shared.closePage() }
        }
    }
}

struct SettingsPageView: View {
    @Environment(AppModel.self) private var app
    let page: SettingsPageID
    var body: some View {
        let content = SettingsContent(store: SettingsStore.shared, context: SettingsContext(app: app), openSystemSettings: openSystemSettings,
                                      askClearData: { SettingsUI.shared.confirmClearData = true },
                                      askSyncOff: { SettingsUI.shared.confirmSyncOff = true },
                                      revealRecovery: { [app] in SyncRecovery.reveal(app) },
                                      copyRecovery: { [app] in SyncRecovery.copy(app) },
                                      showWelcome: { [app] in FirstRun.shared.replay(app) }, tabletLayout: app.workspace.preferences)
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.Settings.sectionGap) {
                    SettingsPageHeader(page: page)
                    if page == .spaces { SettingsSpacesView() }
                    else if page == .feedback { SettingsFeedbackView() }
                    else {
                        ForEach(content.sections(page)) { section in
                            SettingsSection(section: section) { row in settingsTap(row, app: app) }
                                .modifier(ClearDataConfirmation(asks: section.id == "privacy.data"))
                                .modifier(SyncOffConfirmation(asks: section.id == "sync.off"))
                        }
                    }
                }.padding(.horizontal, Metrics.Settings.bodySide)
                    .padding(.bottom, Metrics.Settings.bodyBottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
                .background(SettingsInk.pageGround)
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 0.5 } action: { _, under in
                    if SettingsUI.shared.navigation.last == .page(page), SettingsUI.shared.pageUnder != under {
                        SettingsUI.shared.pageUnder = under
                    }
                }
                .onAppear {
                    if let spot = SettingsUI.shared.searchSpot { reader.scrollTo(spot, anchor: .center) }
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.page.\(page.rawValue)")
    }
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Joining a Mac, in Settings' look: it grows out of the welcome's Join Your
/// Mac or the Sync row and goes back there. What it holds is sync's (M7,
/// Join/JoinLayer): the code to type on a Mac, the Recovery Key's field, or
/// why the account turned this iPhone away.
struct JoinSheet: View {
    @Environment(AppModel.self) private var app
    let size: CGSize

    var body: some View {
        let ui = SettingsUI.shared
        ZStack(alignment: .top) {
            // Opaque: it stands over Settings or the welcome, and they mustn't show through.
            SettingsInk.pageGround
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    SheetGrabber()
                    // × on the left, as in every sheet of Settings; the
                    // title in the middle.
                    ZStack {
                        Text("Join Your Mac")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(SettingsInk.text)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("join.title")
                            .padding(.horizontal, Metrics.Settings.headSide + Metrics.Settings.headButton + Metrics.Settings.headGap)
                        SheetHeadButton(glyph: .crossSmall, label: "Close", id: "join.close") { app.surfaces.closeJoin() }
                            .padding(.leading, Metrics.Settings.headSide)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, (Metrics.Settings.headHeight - Metrics.Settings.headButton) / 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .global)
                        .onChanged { value in ui.join.drag = max(0, value.translation.height) }
                        .onEnded { value in
                            if value.translation.height > Metrics.Settings.closeDistance || value.velocity.height > Metrics.Settings.closeVelocity {
                                ui.flickNext = true
                                app.surfaces.closeJoin()
                            } else {
                                ui.join.snap()
                            }
                        }
                )
                ScrollView {
                    // Sync's own words and fields (Join/JoinLayer), in this sheet.
                    JoinContent()
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("join.content")
                        .padding(.horizontal, Metrics.Sync.bodyInset)
                        .padding(.top, Metrics.Sync.bodyTop)
                        .padding(.bottom, Metrics.Settings.bodyBottom)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .surfaceContents(ui.join)
        }
        .frame(width: size.width, height: size.height)
        .growing(ui.join, size: size, topRadius: Metrics.Sheet.radius)
        .onAppear { ui.join.appeared() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("join.sheet")
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { app.surfaces.closeJoin() }
    }
}

extension Metrics {
    /// Joining with nothing to show yet: the Mac on a round plate, words under it.
    enum Join {
        static let glyph: CGFloat = 40
        static let plate: CGFloat = 76
        static let top: CGFloat = 36
        static let side: CGFloat = 32
        /// Scan QR's camera, a square-ish window on the Mac's code.
        static let scanner: CGFloat = 300
    }
}
