import SwiftUI
import UIKit

/// Tablet chrome has its own bounds; the phone and Duo keep their existing rail.
struct TabletWorkspaceGeometry: Equatable {
    static let minimumSide: CGFloat = 700
    static let toolbar = Metrics.Tablet.toolbar
    static let searchWidth: CGFloat = 540
    static let siteWidth: CGFloat = 280
    static let sheetWidth: CGFloat = 600
    static let sheetHeight: CGFloat = 760
    static let welcomeWidth: CGFloat = 520
    static let pageCorner: CGFloat = 10
    let size: CGSize
    let statusBar: CGFloat
    let sidebar: Bool
    let framed: Bool
    var sidebarExtent: CGFloat = Metrics.Tablet.sidebar
    var paired = false

    static func usesToolbar(size: CGSize, regular: Bool, idiom: UIUserInterfaceIdiom, verticalBar: Bool = false) -> Bool {
        !verticalBar && idiom == .pad && regular && min(size.width, size.height) >= minimumSide
    }
    var top: CGFloat { statusBar + Self.toolbar }
    var sidebarWidth: CGFloat {
        guard sidebar else { return 0 }
        let width = min(Metrics.Tablet.sidebarMaximum, max(Metrics.Tablet.sidebarMinimum, sidebarExtent))
        let reserved = paired && size.width > size.height
            ? Metrics.Workspace.minimumPane * 2 + Metrics.Tablet.splitGap : Metrics.Workspace.minimumPane
        return size.width - width - (framed ? 16 : 0) >= reserved ? width : 0
    }
    var rim: CGFloat { sidebarWidth > 0 && framed ? 8 : 0 }
    var page: CGRect {
        CGRect(x: sidebarWidth + rim, y: top + rim,
               width: max(1, size.width - sidebarWidth - rim * 2),
               height: max(1, size.height - top - rim * 2))
    }
    func searchHeight(keyboard: CGFloat) -> CGFloat { max(44, min(292, size.height - max(0, keyboard) - top - 40)) }
}

struct TabletWorkspaceView: View {
    @Environment(AppModel.self) private var app
    let size: CGSize
    private var preferences: TabletLayoutPreferences { app.workspace.preferences }
    private var geometry: TabletWorkspaceGeometry {
        TabletWorkspaceGeometry(size: size, statusBar: SettingsLayer.statusBar,
                                sidebar: preferences.sidebarShown, framed: preferences.framed,
                                sidebarExtent: preferences.sidebarWidth, paired: app.workspace.paired)
    }
    private var covered: Bool {
        FirstLaunch.shows(app) || app.surfaces.settings || app.surfaces.join || app.surfaces.chat != nil
            || app.surfaces.field != nil || AboutModel.shared.shown
    }
    private var gallery: Bool { TabStack.of(app).gallery != nil }
    private func layout(_ g: TabletWorkspaceGeometry) -> BrowserWorkspaceLayout {
        BrowserWorkspaceLayout(size: g.page.size, regular: true, paired: app.workspace.paired && !gallery,
                               fraction: preferences.splitFraction, gap: Metrics.Tablet.splitGap,
                               horizontal: size.width > size.height)
    }

    var body: some View {
        let g = geometry
        ZStack(alignment: .topLeading) {
            Ink.ground.ignoresSafeArea()
            SpacePagesBackground(spaces: app.browser.spaces, pages: app.browser.spaces.map(\.id), position: CGFloat(app.browser.spaceIndex))
                .frame(width: size.width, height: size.height - g.top).offset(y: g.top)
            pages(in: g)
                .frame(width: g.page.width, height: g.page.height)
                .padding(.leading, g.page.minX).padding(.top, g.page.minY)
                .accessibilityHidden(covered || gallery)
            // Keep the outgoing sidebar at its full width while it travels.
            // Removing the conditional view first made its rows vanish at once.
            TabletSidebar(width: preferences.sidebarWidth)
                .frame(height: size.height - g.top)
                .offset(x: Motion.reduced || g.sidebarWidth > 0 ? 0 : -preferences.sidebarWidth, y: g.top)
                .opacity(g.sidebarWidth > 0 ? 1 : 0)
                .allowsHitTesting(g.sidebarWidth > 0 && !covered && !gallery)
                .accessibilityHidden(g.sidebarWidth == 0 || covered || gallery)
            TabletResizeHandle(label: "Sidebar Width", identifier: "tablet.sidebar.resize", value: preferences.sidebarWidth) { width, save in
                preferences.resizeSidebar(to: width, save: save)
            }
            .frame(height: size.height - g.top)
            .offset(x: g.sidebarWidth - Metrics.Tablet.resizeTarget / 2, y: g.top)
            .opacity(g.sidebarWidth > 0 ? 1 : 0)
            .allowsHitTesting(g.sidebarWidth > 0 && !covered && !gallery)
            .accessibilityHidden(g.sidebarWidth == 0 || covered || gallery)
            if !FirstLaunch.shows(app), !gallery {
                Group {
                    if !layout(g).split && preferences.addressBars {
                        TabletSingleToolbar(sidebarShown: g.sidebarWidth > 0)
                    } else {
                        TabletToolbar(sidebarShown: g.sidebarWidth > 0)
                    }
                }
                    .padding(.top, g.statusBar)
                    .environment(\.colorScheme, app.pageIsPrivate ? .dark : AppAppearance.current)
                    .allowsHitTesting(!covered).accessibilityHidden(covered)
            }
            // No phone chrome under All Tabs: the sidebar is the iPad's, and the
            // phone's plate faded in over the page as All Tabs closed.
            TabGalleryLayer()
            if app.field.shown { TabletOmnibox(geometry: g) }
            WorkspaceChatsLayer()
            TasksLayer()
            WelcomeLayer()
            SettingsLayer()
            AboutLayer()
            ReaderCardLayer()
            ToastLayer()
            AssistantApprovalLayer()
            if app.showsDesignSheet { DesignSheet() }
        }
        .frame(width: size.width, height: size.height)
        .animation(Motion.tabletSidebar.current, value: preferences.sidebarShown)
        .environment(\.colorScheme, app.pageIsPrivate ? .dark : AppAppearance.current)
        .onChange(of: app.field.revision, initial: true) { _, _ in
            if app.field.shown, app.field.mode == .newTab, app.field.resting {
                preferences.sidebarShown = true
                app.field.close()
            }
        }
        .onChange(of: app.browser.spaceID, initial: true) { _, id in
            if !app.browser.space.isPrivate { NewTabPager.shared.spaceID = id }
        }
        .onChange(of: g, initial: true) { _, _ in updateFrame() }
        .onChange(of: preferences.splitFraction) { _, _ in updateFrame() }
        .onChange(of: preferences.addressBars) { _, _ in updateFrame() }
        .onChange(of: app.workspace.paired) { _, _ in updateFrame() }
        .onChange(of: app.workspace.secondFocused) { _, _ in updateFrame() }
        .onChange(of: gallery) { _, _ in updateFrame() }
    }

    private func updateFrame() {
        let g = geometry
        TabStack.of(app).screen = size
        var pane = layout(g).pane(app.workspace.secondFocused)
        if preferences.addressBars && layout(g).split { pane.origin.y += Metrics.Tablet.paneBar; pane.size.height -= Metrics.Tablet.paneBar }
        app.workspace.paneFrame = pane.offsetBy(dx: g.page.minX, dy: g.page.minY)
    }

    private func pages(in g: TabletWorkspaceGeometry) -> some View {
        let plan = layout(g)
        let paneBars = preferences.addressBars && plan.split
        let ids = plan.split ? [app.workspace.first, app.workspace.second].compactMap { $0 } : [app.browser.tab?.id].compactMap { $0 }
        return ZStack(alignment: .topLeading) {
            // In the page's own corners: square, it stood white past a round screen's.
            Ink.ground.clipShape(pageCorners(g))
            ForEach(ids, id: \.self) { id in
                if let tab = app.browser.tab(id) {
                    let second = plan.split && id == app.workspace.second
                    let frame = plan.pane(second)
                    let focused = id == app.browser.tab?.id
                    VStack(spacing: 0) {
                        if paneBars { TabletPaneBar(tab: tab) }
                        ZStack {
                            if focused { BackRevealLayer() }
                            TabletDocumentView(tab: tab, app: app, interactive: !covered && !gallery)
                                .offset(x: focused ? (app.backStack.swipe?.offset ?? 0) : 0)
                            if focused { BrowserClearUndo() }
                        }
                        .frame(width: frame.width, height: max(1, frame.height - (paneBars ? Metrics.Tablet.paneBar : 0)))
                        .clipped().contentShape(Rectangle())
                    }
                    .frame(width: frame.width, height: frame.height)
                    .contentShape(Rectangle())
                    .clipShape(pageCorners(g))
                    .overlay {
                        pageCorners(g).stroke(focused && plan.split ? Metrics.Tablet.focusColor : Ink.primary.opacity(0.1),
                                                    lineWidth: focused && plan.split ? Metrics.Tablet.focusStroke : 1)
                            .allowsHitTesting(false)
                    }
                    .offset(x: frame.minX, y: frame.minY)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("tablet.pane.\(id)")
                }
            }
            if plan.split {
                let first = plan.pane(false)
                TabletResizeHandle(label: "Split Width", identifier: "tablet.split.resize", value: first.width) { width, save in
                    let available = max(1, g.page.width - Metrics.Tablet.splitGap)
                    let minimum = Metrics.Workspace.minimumPane / available
                    preferences.resizeSplit(to: min(1 - minimum, max(minimum, width / available)), save: save)
                }
                .frame(height: g.page.height)
                .offset(x: first.maxX + Metrics.Tablet.splitGap / 2 - Metrics.Tablet.resizeTarget / 2)
                .allowsHitTesting(!covered && !gallery)
            }
        }
    }

    private func pageCorners(_ g: TabletWorkspaceGeometry) -> ConcentricRectangle {
        let corner = g.rim > 0 ? TabletWorkspaceGeometry.pageCorner : 0
        return ConcentricRectangle(topLeadingCorner: .fixed(corner), topTrailingCorner: .fixed(corner),
                                   bottomLeadingCorner: .concentric(minimum: .fixed(corner)),
                                   bottomTrailingCorner: .concentric(minimum: .fixed(corner)))
    }
}

private struct TabletSingleToolbar: View {
    @Environment(AppModel.self) private var app
    let sidebarShown: Bool
    private var siteOpen: Binding<Bool> {
        Binding(get: { app.surfaces.menu == .plate }, set: { open in
            if !open { app.surfaces.closeMenu(); app.pageMenu.reset() }
        })
    }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 0) {
                tool("Sidebar", asset: "TabletSidebar", id: "tablet.sidebar") {
                    app.workspace.sidebarShown.toggle()
                }
                .accessibilityValue(sidebarShown ? "shown" : "hidden")
                .contextMenu {
                    Toggle("Frame Page with Sidebar", isOn: Binding(get: { app.workspace.preferences.framed },
                                                                    set: { app.workspace.preferences.framed = $0 }))
                }
                macTool("Back", .yabBack, id: "tablet.back") { app.goBack() }
                    .disabled(app.backStack.route(for: app.browser.tab) == .nowhere)
                macTool("Forward", .yabForward, id: "tablet.forward") { app.pageMenuForward() }
                    .disabled(!app.currentPageState.canGoForward)
            }
            .frame(width: 132)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                macTool(app.currentPageState.isLoading ? "Stop" : "Reload", app.currentPageState.isLoading ? .yabStop : .yabReload, id: "tablet.reload") {
                    guard let id = app.browser.tab?.id else { return }
                    if app.currentPageState.isLoading { app.pages.stop(id) } else { app.pages.reload(id) }
                }
                Button { app.surfaces.openField(.address) } label: {
                    Text(app.browser.tab?.address ?? "Search or enter address")
                        .font(.system(size: Metrics.Chrome.labelFont))
                        .foregroundStyle(Ink.primary).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, minHeight: Metrics.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search or enter address")
                .accessibilityValue(app.browser.tab?.address ?? "")
                .accessibilityIdentifier("tablet.address")
                macTool("Site Controls", .sliderHorizontal2Square, id: "tablet.siteControls") {
                    if app.surfaces.menu == .plate { app.surfaces.closeMenu(); app.pageMenu.reset() }
                    else { app.openPageMenu(); app.pageMenu.shown = true; app.pageMenu.page = .site }
                }
                .popover(isPresented: siteOpen, arrowEdge: .top) {
                    TabletSiteControls().environment(app)
                        .presentationCompactAdaptation(.popover)
                }
            }
            .frame(maxWidth: 540)
            .background(Ink.primary.opacity(0.055), in: Capsule())
            .accessibilityElement(children: .contain).accessibilityIdentifier("tablet.singleAddressBar")
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                if app.workspace.canSplit { Menu {
                    Button("Open Beside") { app.newTabBeside() }
                    if app.workspace.paired {
                        Button("Separate Split") { app.workspace.fullSpread() }
                        Button("Close Page") { app.closeWorkspacePage() }
                    }
                } label: { TabletGlyph("TabletSplitView").frame(width: Metrics.touch, height: Metrics.touch).contentShape(Rectangle()) }
                .accessibilityLabel("Split View").accessibilityIdentifier("workspace.menu")
                .disabled(app.pageIsPrivate || app.browser.tab == nil || app.browser.tab?.isMail == true)
                }
                tool("New Tab", asset: "TabletPlus", id: "tablet.newTab") { app.openNewTab() }
                macTool("All Tabs", .yabTabs, id: "tablet.tabs") { TabStack.of(app).openGallery() }
            }
            .frame(width: app.workspace.canSplit ? 132 : 88)
        }
        .padding(.horizontal, 12)
        .frame(height: TabletWorkspaceGeometry.toolbar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tablet.toolbar")
    }

    private func tool(_ title: String, asset: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { TabletGlyph(asset).frame(width: Metrics.touch, height: Metrics.touch).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel(title).accessibilityIdentifier(id)
    }
    private func macTool(_ title: String, _ glyph: MacGlyph, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Glyph(mac: glyph).frame(width: Metrics.touch, height: Metrics.touch).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel(title).accessibilityIdentifier(id)
    }
}

private struct TabletToolbar: View {
    @Environment(AppModel.self) private var app
    let sidebarShown: Bool
    var body: some View {
        HStack(spacing: 4) {
            Button { app.workspace.sidebarShown.toggle() } label: {
                TabletGlyph("TabletSidebar").frame(width: Metrics.touch, height: Metrics.touch).contentShape(Rectangle())
            }
                .frame(width: Metrics.touch, height: Metrics.touch)
                .accessibilityLabel("Sidebar").accessibilityValue(sidebarShown ? "shown" : "hidden")
                .accessibilityIdentifier("tablet.sidebar")
                .contextMenu {
                    Toggle("Frame Page with Sidebar", isOn: Binding(get: { app.workspace.preferences.framed },
                                                                    set: { app.workspace.preferences.framed = $0 }))
                }
            Text(app.browser.space.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if !app.workspace.preferences.addressBars {
                Button { app.surfaces.openField(.address) } label: {
                    TabletGlyph("TabletFind").frame(width: Metrics.touch, height: Metrics.touch).contentShape(Rectangle())
                }
                    .frame(width: Metrics.touch, height: Metrics.touch)
                    .accessibilityLabel("Search or enter address").accessibilityValue(app.browser.tab?.address ?? "")
                    .accessibilityIdentifier("tablet.address")
            }
            if app.workspace.canSplit {
                Menu {
                    Button("Open Beside") { app.newTabBeside() }
                    if app.workspace.paired {
                        Button("Separate Split") { app.workspace.fullSpread() }
                        Button("Close Page") { app.closeWorkspacePage() }
                    }
                } label: { TabletGlyph("TabletSplitView").frame(width: Metrics.touch, height: Metrics.touch) }
                .accessibilityLabel("Split View").accessibilityIdentifier("workspace.menu")
                .disabled(app.pageIsPrivate || app.browser.tab == nil || app.browser.tab?.isMail == true)
            }
            Button { app.openNewTab() } label: {
                TabletGlyph("TabletPlus").frame(width: Metrics.touch, height: Metrics.touch).contentShape(Rectangle())
            }
                .frame(width: Metrics.touch, height: Metrics.touch).accessibilityLabel("New Tab").accessibilityIdentifier("tablet.newTab")
            Button { TabStack.of(app).openGallery() } label: {
                Glyph(mac: .yabTabs).frame(width: Metrics.touch, height: Metrics.touch).contentShape(Rectangle())
            }
                .frame(width: Metrics.touch, height: Metrics.touch).accessibilityLabel("All Tabs").accessibilityIdentifier("tablet.tabs")
        }
        .buttonStyle(.plain).foregroundStyle(Ink.primary).padding(.horizontal, 8)
        .frame(height: TabletWorkspaceGeometry.toolbar)
        .accessibilityElement(children: .contain).accessibilityIdentifier("tablet.toolbar")
    }
}

private struct TabletPaneBar: View {
    @Environment(AppModel.self) private var app
    let tab: Tab
    private var focused: Bool { app.browser.tab?.id == tab.id }
    private var state: WebPool.PageState { app.chrome.pageStates[tab.id] ?? .idle }
    private var canGoBack: Bool {
        focused ? app.backStack.route(for: tab) != .nowhere
            : state.canGoBack || state.readerEnabled || app.backStack.opener(of: tab.id) != nil
    }
    private func act(_ action: () -> Void) {
        if !focused {
            app.browser.select(tab.id)
            // Navigation reads the pool's active page in this same touch.
            // SwiftUI updates its document host on the following render.
            _ = app.pages.activate(tab)
        }
        action()
    }
    private var siteOpen: Binding<Bool> {
        Binding(get: { focused && app.surfaces.menu == .plate }, set: { open in
            if !open && focused { app.surfaces.closeMenu(); app.pageMenu.reset() }
        })
    }
    var body: some View {
        HStack(spacing: 0) {
            tool("Back", .yabBack, "tablet.back") { app.goBack() }
                .disabled(!canGoBack)
            tool("Forward", .yabForward, "tablet.forward") { app.pageMenuForward() }
                .disabled(!state.canGoForward)
            if focused {
                tool(state.isLoading ? "Stop" : "Reload", state.isLoading ? .yabStop : .yabReload, "tablet.reload") {
                    if state.isLoading { app.pages.stop(tab.id) } else { app.pages.reload(tab.id) }
                }
            }
            Button { act { app.surfaces.openField(.address) } } label: {
                Text(tab.address).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(focused ? Ink.primary : Ink.secondary)
                    .frame(maxWidth: .infinity, minHeight: Metrics.Tablet.paneBar).contentShape(Rectangle())
            }
            .accessibilityLabel("Search or enter address").accessibilityValue(tab.address)
            .accessibilityIdentifier(focused ? "tablet.address" : "tablet.address.\(tab.id)")
            if focused {
                tool("Site Controls", .sliderHorizontal2Square, "tablet.siteControls") {
                    if app.surfaces.menu == .plate { app.surfaces.closeMenu(); app.pageMenu.reset() }
                    else { app.openPageMenu(); app.pageMenu.shown = true; app.pageMenu.page = .site }
                }
                .popover(isPresented: siteOpen, arrowEdge: .top) {
                    TabletSiteControls().environment(app).presentationCompactAdaptation(.popover)
                }
                Menu {
                    Button("Open Beside") { app.newTabBeside() }
                    Button("Separate Split") { app.workspace.fullSpread() }
                    Button("Close Page") { app.closeWorkspacePage(tab.id) }
                } label: {
                    TabletGlyph("TabletSplitView", size: 16)
                        .frame(width: Metrics.touch, height: Metrics.Tablet.paneBar).contentShape(Rectangle())
                }
                .accessibilityLabel("Split View").accessibilityIdentifier("tablet.paneMenu")
            }
            Button { app.closeWorkspacePage(tab.id) } label: {
                Glyph(.crossSmall, size: 15)
                    .frame(width: Metrics.touch, height: Metrics.Tablet.paneBar).contentShape(Rectangle())
            }
            .accessibilityLabel("Close Page").accessibilityIdentifier("tablet.close.\(tab.id)")
        }
        .buttonStyle(.plain).foregroundStyle(Ink.primary).padding(.horizontal, 4)
        .frame(height: Metrics.Tablet.paneBar).background(Ink.surface.opacity(0.92))
        .accessibilityElement(children: .contain).accessibilityIdentifier("tablet.addressBar.\(tab.id)")
        .accessibilityValue(focused ? "active" : "inactive")
    }
    private func tool(_ title: String, _ glyph: MacGlyph, _ id: String, action: @escaping () -> Void) -> some View {
        Button { act(action) } label: {
            Glyph(mac: glyph, size: 15, color: focused ? Ink.primary : Ink.secondary).frame(width: Metrics.touch, height: Metrics.Tablet.paneBar).contentShape(Rectangle())
        }
            .accessibilityLabel(title).accessibilityIdentifier(focused ? id : id + "." + tab.id)
    }
}

private struct TabletGlyph: View {
    let asset: String
    var size: CGFloat = 20
    var color: Color? = nil
    init(_ asset: String, size: CGFloat = 20, color: Color? = nil) { self.asset = asset; self.size = size; self.color = color }
    var body: some View {
        Image(asset).renderingMode(.template).resizable().frame(width: size, height: size)
            .foregroundStyle(color ?? Ink.primary).accessibilityHidden(true)
    }
}

private struct TabletSiteControls: View {
    @Environment(AppModel.self) private var app
    @State private var contentHeight: CGFloat = 280

    // The desktop panel's 280-point width, 8-point inset, 28-point row marks,
    // and 12.5/11.5-point type. Touch targets stay 44 points on iPad.
    /// The system popover's corner (64 px on a 2x iPad, measured): its
    /// plates' corners follow it, the popover's radius less their inset.
    private static let popoverCorner: CGFloat = 32
    private var wash: Color { Ink.primary.opacity(0.055) }
    private func corners(_ minimum: CGFloat) -> ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(minimum)))
    }

    var body: some View {
        ScrollView {
            Group {
                if app.pageMenu.page == .certificate, let tab = app.browser.tab { certificate(tab) }
                else { main }
            }
            .padding(8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: TabletWorkspaceGeometry.siteWidth, height: min(480, max(44, contentHeight)))
        .background(Ink.surface)
        .containerShape(.rect(cornerRadius: Self.popoverCorner, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("site.settings")
        .confirmationDialog("Clear data for this site?", isPresented: Binding(get: { app.pageMenu.confirmClear }, set: { app.pageMenu.confirmClear = $0 }), titleVisibility: .visible) {
            Button("Clear Data", role: .destructive) { app.clearSiteData() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Cookies go too, so it signs you out.") }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                action("Share", asset: "TabletShare", id: "plate.menu.share", run: app.pageMenuShare)
                action("Find on Page", asset: "TabletFind", id: "plate.menu.find", run: app.pageMenuFind)
                    .disabled(app.currentPageState.isLoading)
                action("Reader", asset: "TabletReader", id: "plate.menu.reader", run: app.pageMenuReader)
                    .disabled(!app.currentPageState.readerAvailable && !app.currentPageState.readerEnabled)
                action("Translate", asset: "TabletTranslate", id: "plate.menu.translate", run: app.pageMenuTranslate)
                    .disabled(app.browser.tab.flatMap { app.translation.page($0.id) } == nil)
            }
            Text("This site").font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 6).padding(.top, 12).padding(.bottom, 4)
            VStack(spacing: 1) {
                if SettingsStore.shared.blocksAds, app.pages.shield?.trouble == nil {
                    Button { app.pageMenuBlocksAds(!app.pageBlocksAds) } label: {
                        row("Block ads and trackers", subtitle: app.pageBlocksAds ? "On" : "Off",
                            asset: app.pageBlocksAds ? "TabletShield" : "TabletShieldOff", on: app.pageBlocksAds)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Block ads and trackers")
                    .accessibilityValue(app.pageBlocksAds ? "On" : "Off").accessibilityIdentifier("site.blocksAds.toggle")
                }
                Button { app.pageMenuDesktop() } label: {
                    row("Desktop site", subtitle: app.pageIsDesktop ? "On" : "Off", asset: MacGlyph.yabScreen.rawValue, on: app.pageIsDesktop)
                }
                .buttonStyle(.plain).accessibilityLabel("Desktop site")
                .accessibilityValue(app.pageIsDesktop ? "On" : "Off").accessibilityIdentifier("site.desktop.toggle")
                HStack(spacing: 0) {
                    Button { app.pageMenuZoom(0) } label: {
                        row("Zoom", subtitle: "\(Int((app.pageZoom * 100).rounded()))%", asset: "TabletZoom")
                    }
                    .buttonStyle(.plain).accessibilityLabel("Reset Zoom")
                    .accessibilityValue("\(Int((app.pageZoom * 100).rounded()))%").accessibilityIdentifier("site.zoom.reset")
                    small("Zoom Out", asset: "TabletZoomOut", id: "site.zoom.out") { app.pageMenuZoom(-1) }
                        .disabled(SiteSettings.step(app.pageZoom, by: -1) == nil)
                    small("Zoom In", asset: "TabletZoom", id: "site.zoom.in") { app.pageMenuZoom(1) }
                        .disabled(SiteSettings.step(app.pageZoom, by: 1) == nil)
                }
                if let tab = app.browser.tab {
                    ForEach(app.siteSettings.permissions(app.siteHost(of: tab), isPrivate: app.pageIsPrivate), id: \.0) { kind, decision in
                        Menu {
                            ForEach(SiteSettings.Decision.allCases, id: \.self) { choice in
                                Button(choice.word) { app.setPermission(kind, choice) }
                            }
                            Button("Forget Permission") { app.forgetPermission(kind) }
                        } label: {
                            row(kind.title, subtitle: decision.word,
                                asset: kind == .camera ? "TabletCamera" : MacGlyph.mic.rawValue, on: decision == .allowed)
                        }
                        .accessibilityIdentifier("site.permission.\(kind.rawValue).decision")
                    }
                }
            }
            if let tab = app.browser.tab {
                Divider().padding(.vertical, 6)
                HStack(spacing: 0) {
                    let secure = app.pages.connection(tab.id, fallback: tab.navigationURL).secure
                    Button { if secure { app.openCertificate() } } label: {
                        HStack(spacing: 6) {
                            TabletGlyph(secure ? "TabletLock" : "TabletUnlock", size: 14, color: secure ? Ink.primary : .red)
                            Text(secure ? "Secure" : "Not secure").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(secure ? Ink.primary : .red)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(wash, in: corners(8))
                        .frame(minHeight: Metrics.touch).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("site.connection")
                    Spacer(minLength: 0)
                    Menu {
                        Button("Clear Cookies and Site Data…", role: .destructive) { app.pageMenu.confirmClear = true }
                        Button("Yab Settings…") { app.pageMenuYabSettings() }
                    } label: { smallFace("TabletMore") }
                    .accessibilityLabel("More Site Settings").accessibilityIdentifier("site.more")
                }
            }
        }
    }

    private func row(_ title: String, subtitle: String, asset: String, on: Bool = false) -> some View {
        HStack(spacing: 10) {
            TabletGlyph(asset, size: 15, color: on ? Ink.surface : Ink.secondary)
                .frame(width: 28, height: 28)
                .background(on ? Ink.primary : wash, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Ink.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
        }
        .foregroundStyle(Ink.primary)
        .frame(minHeight: Metrics.touch).padding(.horizontal, 6).contentShape(Rectangle())
    }

    private func smallFace(_ asset: String) -> some View {
        TabletGlyph(asset, size: 14, color: Ink.secondary).frame(width: 28, height: 28)
            .background(wash, in: corners(8))
            .frame(width: Metrics.touch, height: Metrics.touch).contentShape(Rectangle())
    }
    private func small(_ title: String, asset: String, id: String, run: @escaping () -> Void) -> some View {
        Button(action: run) { smallFace(asset) }
            .buttonStyle(.plain).accessibilityLabel(title).accessibilityIdentifier(id)
    }
    private func action(_ title: String, asset: String, id: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            TabletGlyph(asset, size: 16).frame(maxWidth: .infinity).frame(height: Metrics.touch)
                .background(wash, in: corners(12)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(title).accessibilityIdentifier(id)
    }

    private func certificate(_ tab: Tab) -> some View {
        let connection = app.pages.connection(tab.id, fallback: tab.navigationURL)
        return VStack(alignment: .leading, spacing: 8) {
            Button { app.pageMenu.page = .site } label: {
                HStack(spacing: 8) {
                    Glyph(mac: .yabBack, size: 14)
                    Text("Site Controls").font(.system(size: 12.5, weight: .medium))
                    Spacer(minLength: 0)
                }.frame(minHeight: Metrics.touch).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("site.certificate.back")
            Text("The connection to \(app.siteHost(of: tab)) is encrypted, and its certificate is valid.")
                .font(.system(size: 12.5)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                fact("Issued to", connection.subject ?? app.siteHost(of: tab))
                if let issuer = connection.issuer { Divider(); fact("Issued by", issuer) }
                if let expires = connection.expires { Divider(); fact("Valid until", expires.formatted(date: .abbreviated, time: .omitted)) }
            }
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain).accessibilityIdentifier("site.certificate")
    }
    private func fact(_ name: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(name).foregroundStyle(Ink.primary)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12.5)).frame(minHeight: Metrics.touch)
    }
}
