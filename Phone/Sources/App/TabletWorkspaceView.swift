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
    /// Tabs across the top (the Mac's tab bar) instead of in the sidebar.
    var strip = false

    static func usesToolbar(size: CGSize, regular: Bool, idiom: UIUserInterfaceIdiom, verticalBar: Bool = false) -> Bool {
        !verticalBar && idiom == .pad && regular && min(size.width, size.height) >= minimumSide
    }
    /// The workspace's top: under the status bar, and under the tab bar
    /// when there is one. The sidebar starts here; the page card a rim lower.
    var top: CGFloat { statusBar + (strip ? Metrics.Tablet.strip : 0) }
    var sidebarWidth: CGFloat {
        guard sidebar, !strip else { return 0 }
        let width = min(Metrics.Tablet.sidebarMaximum, max(Metrics.Tablet.sidebarMinimum, sidebarExtent))
        let reserved = paired && size.width > size.height
            ? Metrics.Workspace.minimumPane * 2 + Metrics.Tablet.splitGap : Metrics.Workspace.minimumPane
        return size.width - width - (framed ? 16 : 0) >= reserved ? width : 0
    }
    /// The Mac's card: in from every edge while framed, the sidebar or not.
    var rim: CGFloat { framed ? Metrics.Tablet.rim : 0 }
    var page: CGRect {
        CGRect(x: sidebarWidth + rim, y: top + rim,
               width: max(1, size.width - sidebarWidth - rim * 2),
               height: max(1, size.height - top - rim * 2))
    }
    static func conversation(in size: CGSize, expanded: Bool, chat: Bool) -> CGFloat {
        let column = Metrics.Workspace.conversation
        return expanded && chat && size.width >= column + Metrics.Workspace.minimumPane ? column : 0
    }
    func searchHeight(keyboard: CGFloat) -> CGFloat { max(44, min(292, size.height - max(0, keyboard) - top - 40)) }
}

struct TabletWorkspaceView: View {
    @Environment(AppModel.self) private var app
    let size: CGSize
    private var preferences: TabletLayoutPreferences { app.workspace.preferences }
    /// A chat's column stands beside the workspace, as the phone's wide
    /// layout and the Mac's chat panel do, never over its toolbar or page.
    private var conversation: CGFloat { app.tabletConversation(in: size) }
    private var geometry: TabletWorkspaceGeometry { app.tabletGeometry(in: size) }
    private func plan(_ g: TabletWorkspaceGeometry) -> TabletChromePlan {
        TabletChromePlan(strip: g.strip, sidebarInView: g.sidebarWidth > 0, addressBars: preferences.addressBars,
                         split: layout(g).split)
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
                .frame(width: g.size.width, height: size.height - g.top).offset(y: g.top)
            pages(in: g)
                .frame(width: g.page.width, height: g.page.height)
                .padding(.leading, g.page.minX).padding(.top, g.page.minY)
                .accessibilityHidden(covered || gallery)
            // Keep the outgoing sidebar at its full width while it travels.
            // Removing the conditional view first made its rows vanish at once.
            TabletSidebar(width: preferences.sidebarWidth, shown: g.sidebarWidth > 0, plan: plan(g))
                .frame(height: size.height - g.top)
                .offset(x: Motion.reduced || g.sidebarWidth > 0 ? 0 : -preferences.sidebarWidth, y: g.top)
                .opacity(g.sidebarWidth > 0 ? (gallery ? app.surfaces.chromeOpacity : 1) : 0)
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
            if g.strip, !FirstLaunch.shows(app) {
                TabletTabStrip()
                    .frame(width: g.size.width)
                    .padding(.top, g.statusBar)
                    .environment(\.colorScheme, app.pageIsPrivate ? .dark : AppAppearance.current)
                    // All Tabs fades it with the page's bar, so it is back as the card lands.
                    .opacity(gallery ? app.surfaces.chromeOpacity : 1)
                    .allowsHitTesting(!covered && !gallery).accessibilityHidden(covered || gallery)
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
            TabletDownloadFlights()
            AssistantApprovalLayer()
            if app.showsDesignSheet { DesignSheet() }
        }
        .frame(width: size.width, height: size.height)
        .animation(Motion.tabletSidebar.current, value: preferences.sidebarShown)
        .animation(Motion.tabletSidebar.current, value: preferences.tabsInSidebar)
        .animation(Motion.tabletSidebar.current, value: preferences.addressBars)
        .animation(Motion.tabletSidebar.current, value: conversation)
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
        .onChange(of: preferences.tabsInSidebar) { _, _ in updateFrame() }
        .onChange(of: app.workspace.paired) { _, _ in updateFrame() }
        .onChange(of: app.workspace.secondFocused) { _, _ in updateFrame() }
        .onChange(of: gallery) { _, _ in updateFrame() }
    }

    private func updateFrame() {
        let g = geometry
        TabStack.of(app).screen = size
        var pane = layout(g).pane(app.workspace.secondFocused)
        if plan(g).band { pane.origin.y += Metrics.Tablet.paneBar; pane.size.height -= Metrics.Tablet.paneBar }
        app.workspace.paneFrame = pane.offsetBy(dx: g.page.minX, dy: g.page.minY)
    }

    private func pages(in g: TabletWorkspaceGeometry) -> some View {
        let plan = layout(g)
        let chrome = self.plan(g)
        let paneBars = chrome.band
        let ids = plan.split ? [app.workspace.first, app.workspace.second].compactMap { $0 } : [app.browser.tab?.id].compactMap { $0 }
        let downloads = app.showsToolbarDownloads(sidebarShown: false)
        return ZStack(alignment: .topLeading) {
            // In the page's own corners: square, it stood white past a round screen's.
            Ink.ground.clipShape(pageCorners(g))
            ForEach(chrome.pages(ids.filter { app.browser.tab($0) != nil }), id: \.self) { page in
                if case .tab(let id) = page, let tab = app.browser.tab(id) {
                    let second = plan.split && id == app.workspace.second
                    let frame = plan.pane(second)
                    let focused = id == app.browser.tab?.id
                    VStack(spacing: 0) {
                        if paneBars {
                            TabletPageBand(tab: tab, band: TabletBandPlan(chrome: chrome, width: frame.width, first: !second,
                                                                          last: !plan.split || second, focused: focused,
                                                                          downloads: downloads))
                        }
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
                        pageCorners(g).stroke(focused && plan.split ? Ink.splitFocus : Ink.primary.opacity(0.1),
                                                    lineWidth: focused && plan.split ? Metrics.Tablet.focusStroke : 1)
                            .allowsHitTesting(false)
                    }
                    .offset(x: frame.minX, y: frame.minY)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("tablet.pane.\(id)")
                } else if page == .empty {
                    TabletPageBand(tab: nil, band: TabletBandPlan(chrome: chrome, width: g.page.width, first: true, last: true,
                                                                  focused: false, downloads: downloads, page: false))
                        .frame(width: g.page.width)
                        .clipShape(pageCorners(g))
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

struct TabletGlyph: View {
    let asset: String
    var size: CGFloat = 20
    var color: Color? = nil
    init(_ asset: String, size: CGFloat = 20, color: Color? = nil) { self.asset = asset; self.size = size; self.color = color }
    var body: some View {
        Image(asset).renderingMode(.template).resizable().frame(width: size, height: size)
            .foregroundStyle(color ?? Ink.primary).accessibilityHidden(true)
    }
}

struct TabletSiteControls: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var contentHeight: CGFloat = M.startHeight

    private typealias M = Metrics.Tablet.Site
    private func corners(_ minimum: CGFloat) -> ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(minimum)))
    }

    var body: some View {
        ScrollView {
            Group {
                if app.pageMenu.page == .certificate, let tab = app.browser.tab { certificate(tab) }
                else if app.pageMenu.page == .downloads { downloads }
                else { main }
            }
            .padding(M.inset)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: TabletWorkspaceGeometry.siteWidth, height: min(M.maxHeight, max(Metrics.touch, contentHeight)))
        .background(Ink.surface)
        .containerShape(.rect(cornerRadius: M.popoverCorner, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("site.settings")
        .confirmationDialog("Clear data for this site?", isPresented: Binding(get: { app.pageMenu.confirmClear }, set: { app.pageMenu.confirmClear = $0 }), titleVisibility: .visible) {
            Button("Clear Data", role: .destructive) { app.clearSiteData() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Cookies go too, so it signs you out.") }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: M.actionGap) {
                action("Share", asset: "TabletShare", id: "plate.menu.share", run: app.pageMenuShare)
                action("Find on Page", asset: "TabletFind", id: "plate.menu.find", run: app.pageMenuFind)
                    .disabled(app.currentPageState.isLoading)
                action("Reader", asset: "TabletReader", id: "plate.menu.reader", run: app.pageMenuReader)
                    .disabled(!app.currentPageState.readerAvailable && !app.currentPageState.readerEnabled)
                action("Translate", asset: "TabletTranslate", id: "plate.menu.translate", run: app.pageMenuTranslate)
                    .disabled(app.browser.tab.flatMap { app.translation.page($0.id) } == nil)
            }
            Text("This site").font(.system(size: M.headFont, weight: .semibold))
                .padding(.horizontal, M.headInset).padding(.top, M.headTop).padding(.bottom, M.headBelow)
            VStack(spacing: M.rowSpacing) {
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
                                asset: kind.tabletAsset, on: decision == .allowed)
                        }
                        .accessibilityIdentifier("site.permission.\(kind.rawValue).decision")
                    }
                    let here = app.downloads.list(isPrivate: app.pageIsPrivate, host: app.siteHost(of: tab)).count
                    if here > 0 {
                        Button { app.openSiteDownloads() } label: {
                            row("Downloaded Here", subtitle: here == 1 ? "1 file" : "\(here) files", asset: MacGlyph.yabDownload.rawValue)
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("site.downloads.here")
                    }
                }
            }
            if let tab = app.browser.tab {
                Divider().padding(.vertical, M.dividerGap)
                HStack(spacing: 0) {
                    let secure = app.pages.connection(tab.id, fallback: tab.navigationURL).secure
                    Button { if secure { app.openCertificate() } } label: {
                        HStack(spacing: M.connectionGap) {
                            TabletGlyph(secure ? "TabletLock" : "TabletUnlock", size: M.smallGlyph, color: secure ? Ink.primary : .red)
                            Text(secure ? "Secure" : "Not secure").font(.system(size: M.connectionFont, weight: .medium))
                        }
                        .foregroundStyle(secure ? Ink.primary : .red)
                        .padding(.horizontal, M.connectionInset).frame(height: M.mark)
                        .background(Ink.tabletWash, in: corners(M.smallRadius))
                        .frame(minHeight: Metrics.touch).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("site.connection")
                    Spacer(minLength: 0)
                    Menu {
                        // The popover goes first: the panel and the sheet stand in its place.
                        Button("Print…") { app.surfaces.closeMenu(); app.pageMenu.reset(); app.printPage() }
                            .disabled(!app.pageCanBeDrawn)
                        Button("Save as PDF") { app.surfaces.closeMenu(); app.pageMenu.reset(); app.savePageAsPDF() }
                            .disabled(!app.pageCanBeDrawn)
                        if app.pageDownloadable {
                            Button("Download") { app.surfaces.closeMenu(); app.pageMenu.reset(); app.downloadPage() }
                        }
                        Divider()
                        Button("Clear Cookies and Site Data…", role: .destructive) { app.pageMenu.confirmClear = true }
                        Button("Yab Settings…") { app.pageMenuYabSettings() }
                    } label: { smallFace("TabletMore") }
                    .accessibilityLabel("More Site Settings").accessibilityIdentifier("site.more")
                }
            }
        }
    }

    /// Downloaded Here, or every file: the phone's Downloads page in the popover.
    private var downloads: some View {
        VStack(alignment: .leading, spacing: M.detailGap) {
            back("site.downloads.back").padding(.horizontal, M.rowInset)
            DownloadsBody(ink: PageMenuInk(dark: app.pageIsPrivate || scheme == .dark),
                          host: app.pageMenu.downloadsHost, isPrivate: app.pageIsPrivate)
        }
    }

    /// ‹ Site Controls, over a page one step deeper (downloads, the certificate).
    private func back(_ id: String) -> some View {
        Button { app.pageMenu.page = .site } label: {
            HStack(spacing: M.backGap) {
                Glyph(mac: .yabBack, size: M.backGlyph)
                Text("Site Controls").font(.system(size: M.titleFont, weight: .medium))
                Spacer(minLength: 0)
            }.frame(minHeight: Metrics.touch).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier(id)
    }

    private func row(_ title: String, subtitle: String, asset: String, on: Bool = false) -> some View {
        HStack(spacing: M.rowGap) {
            TabletGlyph(asset, size: M.markGlyph, color: on ? Ink.surface : Ink.secondary)
                .frame(width: M.mark, height: M.mark)
                .background(on ? Ink.primary : Ink.tabletWash, in: Circle())
            VStack(alignment: .leading, spacing: M.lineGap) {
                Text(title).font(.system(size: M.titleFont, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: M.subtitleFont)).foregroundStyle(Ink.secondary).lineLimit(2)
            }
            Spacer(minLength: M.rowEnd)
        }
        .foregroundStyle(Ink.primary)
        .frame(minHeight: Metrics.touch).padding(.horizontal, M.rowInset).contentShape(Rectangle())
    }

    private func smallFace(_ asset: String) -> some View {
        TabletGlyph(asset, size: M.smallGlyph, color: Ink.secondary).frame(width: M.mark, height: M.mark)
            .background(Ink.tabletWash, in: corners(M.smallRadius))
            .frame(width: Metrics.touch, height: Metrics.touch).contentShape(Rectangle())
    }
    private func small(_ title: String, asset: String, id: String, run: @escaping () -> Void) -> some View {
        Button(action: run) { smallFace(asset) }
            .buttonStyle(.plain).accessibilityLabel(title).accessibilityIdentifier(id)
    }
    private func action(_ title: String, asset: String, id: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            TabletGlyph(asset, size: M.actionMark).frame(maxWidth: .infinity).frame(height: Metrics.touch)
                .background(Ink.tabletWash, in: corners(M.actionRadius)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(title).accessibilityIdentifier(id)
    }

    private func certificate(_ tab: Tab) -> some View {
        let connection = app.pages.connection(tab.id, fallback: tab.navigationURL)
        return VStack(alignment: .leading, spacing: M.detailGap) {
            back("site.certificate.back")
            Text("The connection to \(app.siteHost(of: tab)) is encrypted, and its certificate is valid.")
                .font(.system(size: M.titleFont)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                fact("Issued to", connection.subject ?? app.siteHost(of: tab))
                if let issuer = connection.issuer { Divider(); fact("Issued by", issuer) }
                if let expires = connection.expires { Divider(); fact("Valid until", expires.formatted(date: .abbreviated, time: .omitted)) }
            }
        }
        .padding(.horizontal, M.rowInset)
        .accessibilityElement(children: .contain).accessibilityIdentifier("site.certificate")
    }
    private func fact(_ name: String, _ value: String) -> some View {
        HStack(spacing: M.factGap) {
            Text(name).foregroundStyle(Ink.primary)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: M.titleFont)).frame(minHeight: Metrics.touch)
    }
}

extension SiteSettings.Permission {
    /// Site Controls' mark for the permission, in the popover's asset names.
    var tabletAsset: String {
        switch self {
        case .camera: "TabletCamera"
        case .microphone: MacGlyph.mic.rawValue
        case .downloads: MacGlyph.yabDownload.rawValue
        }
    }
}

extension AppModel {
    /// The chat's column beside the workspace, its width.
    func tabletConversation(in size: CGSize) -> CGFloat {
        TabletWorkspaceGeometry.conversation(in: size, expanded: workspace.expanded, chat: chatSheet.shown && !field.shown)
    }

    /// The iPad workspace in a window this size: what TabletWorkspaceView
    /// lays out, and what the field's commands read to know what is on screen.
    func tabletGeometry(in size: CGSize) -> TabletWorkspaceGeometry {
        let preferences = workspace.preferences
        return TabletWorkspaceGeometry(size: CGSize(width: size.width - tabletConversation(in: size), height: size.height),
                                       statusBar: SettingsLayer.statusBar, sidebar: preferences.sidebarShown,
                                       framed: preferences.framed, sidebarExtent: preferences.sidebarWidth,
                                       paired: workspace.paired, strip: !preferences.tabsInSidebar)
    }

    /// The Mac's rule: the toolbar's downloads button only from the first
    /// file, and only while the sidebar's foot, which always has one, is away.
    func showsToolbarDownloads(sidebarShown: Bool) -> Bool {
        !sidebarShown && (downloads.asking(isPrivate: pageIsPrivate) != nil || !downloads.list(isPrivate: pageIsPrivate).isEmpty)
    }
}
