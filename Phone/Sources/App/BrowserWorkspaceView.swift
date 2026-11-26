import SwiftUI
import WebKit

/// The existing phone tree keeps its identity as its pane changes size and
/// position. No second AppModel, profile or web session is made on rotation.
struct BrowserWorkspaceView<Content: View>: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            // All Tabs uses the full spread, then returns to the remembered pair.
            let paired = app.workspace.paired && TabStack.of(app).gallery == nil
            let layout = BrowserWorkspaceLayout(size: geo.size, regular: sizeClass == .regular || BrowserWorkspace.regularForced, paired: paired)
            let active = layout.pane(app.workspace.secondFocused)
            let _ = Self.publishSides(pane: active, window: geo.size, insets: app.workspace.windowInsets, reservations: app.workspace.reservations)
            Group {
                if TabletWorkspaceGeometry.usesToolbar(size: geo.size, regular: sizeClass == .regular, idiom: UIDevice.current.userInterfaceIdiom, verticalBar: app.workspace.verticalBarLeading != nil) {
                    TabletWorkspaceView(size: geo.size)
                } else {
                    ZStack(alignment: .topLeading) {
                        Ink.ground
                        if layout.split, let id = app.workspace.companion, let tab = app.browser.tab(id), !app.pageIsPrivate {
                            let frame = layout.pane(!app.workspace.secondFocused)
                            CompanionPage(tab: tab)
                                .frame(width: frame.width, height: frame.height)
                                .offset(x: frame.minX, y: frame.minY)
                        }
                        content()
                            .frame(width: active.width, height: active.height)
                            .clipped()
                            .offset(x: active.minX, y: active.minY)
                        if !app.surfaces.settings, !app.surfaces.join, app.surfaces.chat == nil, app.surfaces.menu == nil, !FirstLaunch.shows(app) {
                            if app.workspace.unfolded {
                                if TabStack.of(app).gallery == nil, !app.surfaces.coversChrome {
                                    let rail = ChromeGeometry(size: active.size, folded: false, hasNow: false, verticalControls: true, leadingRail: app.workspace.leadingRail)
                                    sidebarButton
                                        .position(x: active.minX + rail.sidebar.midX, y: active.minY + rail.sidebar.midY)
                                }
                            } else if app.workspace.canSplit, !app.surfaces.coversChrome {
                                workspaceMenu
                                    .padding(Metrics.Edge.bar)
                                    .padding(.top, max(geo.safeAreaInsets.top, Metrics.statusBar + Metrics.Chrome.round))
                                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
                            }
                        }
                    }
                }
            }
            .background(WindowInsetsProbe { snapshot in
                if app.workspace.windowInsets != snapshot.insets { app.workspace.windowInsets = snapshot.insets }
                if app.workspace.reservations != snapshot.reservations { app.workspace.reservations = snapshot.reservations }
                if app.workspace.verticalBarLeading != snapshot.leading { app.workspace.verticalBarLeading = snapshot.leading }
            })
            .onAppear { update(layout) }
            .onChange(of: layout) { _, layout in update(layout) }
            .onChange(of: sizeClass) { _, _ in update(layout) }
            .onChange(of: app.workspace.verticalBarLeading) { _, _ in update(layout) }
            .onChange(of: app.workspace.secondFocused) { _, _ in update(layout) }
            .onChange(of: app.workspace.unfolded && app.field.spacesResting, initial: true) { _, beside in
                app.surfaces.fieldBeside = beside
            }
            .onChange(of: app.browser.tab?.id) { _, _ in reconcile() }
            .onChange(of: app.browser.space) { _, _ in reconcile() }
            .onChange(of: app.surfaces.field == nil) { _, closed in
                if closed { reconcile(); app.workspace.fieldClosed() }
            }
        }
    }

    /// A row of the layout menu in the Mac's drawing for the same action.
    private func menuLabel(_ title: String, _ glyph: MacGlyph) -> some View {
        Label { Text(title) } icon: { UIImage.menuGlyph(glyph).map { Image(uiImage: $0) } }
    }

    /// The unfolded rail's way to the spaces' column, and back.
    private var sidebarButton: some View {
        Button { if app.field.shown { app.field.close() } else { app.field.openSpaces() } } label: {
            Image("TabletSidebar")
                .renderingMode(.template).resizable()
                .frame(width: Metrics.Chrome.backIcon, height: Metrics.Chrome.backIcon)
                .foregroundStyle(Ink.primary)
                .frame(width: Metrics.Chrome.round, height: Metrics.Chrome.round)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Sidebar")
        .accessibilityValue(app.field.spacesResting ? "shown" : "hidden")
        .accessibilityIdentifier("workspace.sidebar")
    }

    private var workspaceMenu: some View {
        Menu {
            Button { app.field.openSpaces() } label: { menuLabel("Show Tabs", .yabSidebar) }
            if !app.pageIsPrivate, let current = app.browser.tab, !current.isMail {
                Button { app.newTabBeside() } label: { menuLabel("Split View", .yabSplitPlus) }
                if app.workspace.paired {
                    Button { app.workspace.fullSpread() } label: { menuLabel("Separate Split View", .yabSplitSlash) }
                    Button { app.closeWorkspacePage() } label: { menuLabel("Close Split", .yabTabX) }
                }
            }
        } label: {
            Image("TabletSplitView")
                .renderingMode(.template).resizable()
                .frame(width: Metrics.Chrome.backIcon, height: Metrics.Chrome.backIcon)
                .foregroundStyle(Ink.primary)
                .frame(width: Metrics.touch, height: Metrics.touch)
        }
        .glassEffect(.regular.interactive(), in: Circle())
        .tint(Ink.primary)
        .accessibilityLabel("Page Layout")
        .accessibilityIdentifier("workspace.menu")
    }

    /// The window's reserved left and right edges, for the pane that touches
    /// them: the chrome keeps its controls out of the system's own column.
    @MainActor private static func publishSides(pane: CGRect, window size: CGSize, insets: UIEdgeInsets, reservations: ChromeGeometry.Reservations) {
        let extra = ChromeGeometry.extraSides
        let sides = ChromeGeometry.Sides.of(pane: pane, window: size,
                                            insets: UIEdgeInsets(top: insets.top, left: insets.left + extra.left,
                                                                 bottom: insets.bottom, right: insets.right + extra.right))
        if ChromeGeometry.windowSides != sides { ChromeGeometry.windowSides = sides }
        let local = ChromeGeometry.Reservations(
            occlusions: reservations.occlusions.map { $0.offsetBy(dx: -pane.minX, dy: -pane.minY) },
            divisions: reservations.divisions.map { $0.offsetBy(dx: -pane.minX, dy: -pane.minY) },
            statusBarHeight: reservations.statusBarHeight)
        if ChromeGeometry.windowReservations != local { ChromeGeometry.windowReservations = local }
    }

    private func update(_ layout: BrowserWorkspaceLayout) {
        app.workspace.tabletControls = TabletWorkspaceGeometry.usesToolbar(size: layout.size, regular: sizeClass == .regular, idiom: UIDevice.current.userInterfaceIdiom, verticalBar: app.workspace.verticalBarLeading != nil)
        app.workspace.regularWidth = sizeClass == .regular
        app.workspace.legacyTabletWindow = UIDevice.current.userInterfaceIdiom == .pad && app.workspace.verticalBarLeading == nil
        app.workspace.resize(expanded: layout.expanded)
        app.workspace.windowSize = layout.size
        if !app.workspace.tabletControls { app.workspace.paneFrame = layout.pane(app.workspace.secondFocused) }
        reconcile()
    }

    private func reconcile() {
        app.reconcileWorkspace()
    }
}

/// A nonfocused pane shows its live page. One tap makes it the owner of all
/// browser actions before another tap can interact with the website itself.
struct CompanionPage: View {
    @Environment(AppModel.self) private var app
    let tab: Tab

    var body: some View {
        ZStack(alignment: .bottom) {
            CompanionWebView(tab: tab, pool: app.pages, pane: BrowserWorkspaceLayout(size: app.workspace.windowSize, regular: app.workspace.expanded, paired: app.workspace.paired).pane(!app.workspace.secondFocused))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Button { focus() } label: { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            Text(tab.site).font(.body).lineLimit(1)
                .padding(.horizontal, Metrics.Chrome.labelPadding)
                .frame(height: Metrics.Chrome.height)
                .glassEffect(.regular, in: Capsule())
                .padding(.bottom, Metrics.Chrome.bottom)
                .allowsHitTesting(false)
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Use \(tab.title)")
        .accessibilityIdentifier("workspace.companion")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { focus() }
    }

    private func focus() {
        app.browser.select(tab.id)
        app.chrome.unfold()
    }
}

private struct CompanionWebView: UIViewRepresentable {
    let tab: Tab
    let pool: WebPool
    let pane: CGRect
    func makeUIView(context: Context) -> PageContainer { PageContainer() }
    func updateUIView(_ host: PageContainer, context: Context) {
        host.windowPane = pane
        host.accessibilityCovered = true
        host.fixturesEnabled = pool.fixturesEnabled
        host.chrome = PageViewport.Chrome(folded: false, hasNow: false, visible: false)
        host.show(pool.view(for: tab))
        host.updateViewport()
    }
    static func dismantleUIView(_ host: PageContainer, coordinator: ()) { host.show(nil) }
}

/// The spaces and conversations use the same phone surfaces in a bounded
/// column, rather than stretching text and cards across the whole tablet.
struct WorkspaceFieldLayer: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        GeometryReader { geo in
            FieldLayer()
                .frame(width: app.workspace.expanded ? min(Metrics.Workspace.sidebar, geo.size.width) : geo.size.width)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct WorkspaceChatsLayer: View {
    var body: some View { ChatsLayer() }
}

/// Reports the window's safe area whenever it changes, also when the window
/// keeps its size: turning a Duo by 180 degrees moves its status column from
/// one side to the other with the same bounds, so no layout pass would say so.
private struct WindowInsetsProbe: UIViewRepresentable {
    struct Snapshot: Equatable {
        var insets: UIEdgeInsets
        var reservations: ChromeGeometry.Reservations
        var leading: Bool?
    }
    let report: (Snapshot) -> Void

    final class Probe: UIView {
        var report: (Snapshot) -> Void = { _ in }
        private var last: Snapshot?
        private var link: CADisplayLink?
        @MainActor private final class Tick: NSObject {
            weak var probe: Probe?
            init(_ probe: Probe) { self.probe = probe }
            @objc func fire() { probe?.push() }
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            sample()
            push()
        }
        /// Reserved regions can change during a Live Activity without a
        /// safe-area or bounds change. Sample them only while the system
        /// keeps a vertical bar (a Duo's side column): every other iPhone and
        /// iPad never wakes for it. Publish only changed values, and never
        /// keep the view alive with the link.
        private func sample() {
            var wanted = false
            #if compiler(>=6.4.2)
            if #available(iOS 27.1, *), let window { wanted = window.traitCollection.verticalBarEdge != .unspecified }
            #endif
            guard wanted != (link != nil) else { return }
            stop()
            guard wanted else { return }
            let link = CADisplayLink(target: Tick(self), selector: #selector(Tick.fire))
            link.preferredFramesPerSecond = 4
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        func stop() { link?.invalidate(); link = nil }
        override func layoutSubviews() { super.layoutSubviews(); push() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); push() }
        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            sample()
            push()
        }
        private func push() {
            guard let window else { return }
            var reservations = ChromeGeometry.Reservations.empty
            var leading: Bool?
            #if compiler(>=6.4.2)
            if #available(iOS 27.1, *) {
                reservations.occlusions = window.reservedRegions(kind: .occlusion).filter(\.isActive).map(\.frame)
                reservations.divisions = window.reservedRegions(kind: .division).filter(\.isActive).map(\.frame)
                reservations.statusBarHeight = window.windowScene?.statusBarManager?.statusBarFrame.height ?? 0
                switch window.traitCollection.verticalBarEdge {
                case .leading: leading = window.effectiveUserInterfaceLayoutDirection != .rightToLeft
                case .trailing: leading = window.effectiveUserInterfaceLayoutDirection == .rightToLeft
                default: break
                }
            }
            #endif
            if let originalLeft = StateCatalog.rotatingColumnLeft {
                let reversed = window.windowScene?.interfaceOrientation == .landscapeLeft
                let left = reversed ? !originalLeft : originalLeft
                let safe = window.safeAreaInsets
                ChromeGeometry.extraSides = .init(left: (left ? 84 : 0) - safe.left,
                                                   right: (left ? 0 : 84) - safe.right)
                reservations = .init(occlusions: [CGRect(x: left ? 0 : window.bounds.width - 84,
                                                         y: 0, width: 84, height: 150)], statusBarHeight: 22)
                leading = left
            }
            let snapshot = Snapshot(insets: window.safeAreaInsets, reservations: reservations, leading: leading)
            guard snapshot != last else { return }
            last = snapshot
            DispatchQueue.main.async { [report] in report(snapshot) }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.isAccessibilityElement = false
        probe.report = report
        return probe
    }
    func updateUIView(_ probe: Probe, context: Context) { probe.report = report }
    static func dismantleUIView(_ probe: Probe, coordinator: ()) { probe.stop() }
}
