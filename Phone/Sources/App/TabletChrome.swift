import SwiftUI

/// Where the Mac's controls stand in the iPad workspace, from the same two
/// choices the Mac offers: tabs in the sidebar or across the top
/// (Sources/Fast/TabBar), and the address in the sidebar or as a band over
/// the page card (Show Address Bar, Sources/Fast/AddressBar).
struct TabletChromePlan: Equatable {
    /// Tabs across the top: the Mac's tab bar, the sidebar off.
    let strip: Bool
    /// The sidebar on screen beside the page.
    let sidebarInView: Bool
    let addressBars: Bool
    /// Two pages side by side: each keeps its own band, its own Back and
    /// its own close, as the Mac's split does.
    var split = false

    /// The address as a plate in the sidebar, under its header.
    var addressPlate: Bool { sidebarInView && !addressBars && !split }
    /// Back, Forward and Reload in the sidebar's header, beside its door.
    var headerNav: Bool { addressPlate }
    /// The address as a band across the top of the page card.
    var band: Bool { !addressPlate }
    /// The band holds Back, Forward and Reload, unless the tab bar has them.
    var bandNav: Bool { band && !strip }
    /// The band holds the sidebar's door and the tab buttons when neither
    /// the sidebar nor the tab bar is there to hold them.
    var bandWorkspace: Bool { !strip && !sidebarInView }

    enum Page: Hashable { case tab(Tab.ID), empty }
    /// The page area's panes. With no tab shown and nothing else holding the
    /// sidebar's door and New Tab, an empty pane keeps a band for them.
    func pages(_ ids: [Tab.ID]) -> [Page] {
        ids.isEmpty && bandWorkspace ? [.empty] : ids.map(Page.tab)
    }
}

/// What one pane's band holds and how wide its ends are. The ends are equal,
/// keeping the site centered, only while the pane has room for that; then
/// each end takes its own width; then the tab buttons fold into one menu and
/// Close Split into the split's menu, so the address always keeps its room.
struct TabletBandPlan: Equatable {
    enum Workspace: Equatable { case none, doors, menu }
    let sidebarDoor: Bool
    let navigation: Bool
    let siteControls: Bool
    let splitMenu: Bool
    let close: Bool
    let workspace: Workspace
    let centered: Bool
    let leadingWidth: CGFloat
    let trailingWidth: CGFloat
    let address: CGFloat

    /// `first` and `last` place the pane at the window's leading and trailing
    /// edges: the sidebar's door stands on the first, the tab buttons on the last.
    init(chrome: TabletChromePlan, width: CGFloat, first: Bool, last: Bool, focused: Bool, downloads: Bool, page: Bool = true) {
        typealias M = Metrics.Tablet
        let door = M.door
        let room = width - M.bandInset * 2
        let minimum = M.bandAddressMinimum
        sidebarDoor = chrome.bandWorkspace && first
        navigation = chrome.bandNav && page
        siteControls = focused && page
        splitMenu = chrome.split && focused && page
        let tabButtons = chrome.bandWorkspace && last
        func doors(_ count: Int) -> CGFloat { door * CGFloat(count) }
        let leading = doors((sidebarDoor ? 1 : 0) + (navigation ? M.bandNavigationDoors : 0))
        let fixed = doors((siteControls ? M.bandSiteControlsDoors : 0) + (splitMenu ? 1 : 0))
        let tabDoors = doors(M.bandTabButtonDoors) + (downloads ? M.downloadsDoor : 0)
        let spread = fixed + doors(chrome.split ? 1 : 0) + (tabButtons ? tabDoors : 0)
        let fits = leading + spread + minimum <= room
        let trailing: CGFloat
        if fits || !tabButtons && !splitMenu {
            close = chrome.split
            workspace = tabButtons ? .doors : .none
            trailing = spread
        } else {
            close = chrome.split && !splitMenu
            workspace = tabButtons ? .menu : .none
            trailing = fixed + doors((close ? 1 : 0) + (tabButtons ? 1 : 0))
        }
        let end = max(leading, trailing)
        centered = end * 2 + minimum <= room
        leadingWidth = centered ? end : leading
        trailingWidth = centered ? end : trailing
        address = max(0, room - leadingWidth - trailingWidth)
    }
}

/// A door of the Mac's chrome: a mark on a plate that shows under a
/// pointer or a press, a finger's target around it.
struct TabletChromeButton: View {
    let title: String
    let mark: Image
    let id: String
    var size: CGFloat = Metrics.Tablet.doorMark
    let action: () -> Void

    init(_ title: String, mac: MacGlyph, id: String, size: CGFloat = Metrics.Tablet.doorMark, action: @escaping () -> Void) {
        self.title = title; self.mark = Image(mac.rawValue); self.id = id; self.size = size; self.action = action
    }
    init(_ title: String, asset: String, id: String, size: CGFloat = Metrics.Tablet.doorArt, action: @escaping () -> Void) {
        self.title = title; self.mark = Image(asset); self.id = id; self.size = size; self.action = action
    }

    var body: some View {
        Button(action: action) {
            mark.renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size)
                .frame(width: Metrics.Tablet.door, height: Metrics.Tablet.door)
                .tabletHover()
                .contentShape(Rectangle())
        }
        .buttonStyle(TabletChromeButtonPress())
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}

extension View {
    /// A pointer over an iPad control lights the door's rounded square.
    func tabletHover() -> some View {
        contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Metrics.Tablet.doorRadius, style: .continuous))
            .hoverEffect(.highlight)
    }
}

/// The Mac's door under a finger: its plate, briefly.
struct TabletChromeButtonPress: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Ink.primary : Ink.tabletDisabled)
            .background(configuration.isPressed ? Ink.tabletPressed : .clear,
                        in: RoundedRectangle(cornerRadius: Metrics.Tablet.doorRadius, style: .continuous))
    }
}

/// Back, Forward and Reload (Stop while loading) for a tab: the focused
/// page's unless one is named.
struct TabletNavigationDoors: View {
    @Environment(AppModel.self) private var app
    var tab: Tab? = nil
    private var target: Tab? { tab ?? app.browser.tab }
    private var focused: Bool { target?.id == app.browser.tab?.id }
    private var state: WebPool.PageState { target.flatMap { app.chrome.pageStates[$0.id] } ?? .idle }
    private var canGoBack: Bool {
        guard let target else { return false }
        return focused ? app.backStack.route(for: target) != .nowhere
            : state.canGoBack || state.readerEnabled || app.backStack.opener(of: target.id) != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            TabletChromeButton("Back", mac: .yabBack, id: id("tablet.back")) { act { app.goBack() } }
                .disabled(!canGoBack)
            TabletChromeButton("Forward", mac: .yabForward, id: id("tablet.forward")) { act { app.pageMenuForward() } }
                .disabled(!state.canGoForward)
            TabletChromeButton(state.isLoading ? "Stop" : "Reload", mac: state.isLoading ? .yabStop : .yabReload, id: id("tablet.reload"), size: Metrics.Tablet.reloadMark) {
                guard let target else { return }
                if state.isLoading { app.pages.stop(target.id) } else { app.pages.reload(target.id) }
            }
            .disabled(target == nil)
        }
    }

    private func id(_ base: String) -> String {
        guard let tab, !focused else { return base }
        return base + "." + tab.id
    }

    /// Another pane's door takes that pane first: navigation reads the
    /// pool's active page in this same touch.
    private func act(_ action: () -> Void) {
        if let target, !focused {
            app.browser.select(target.id)
            _ = app.pages.activate(target)
        }
        action()
    }
}

/// The door that shows or hides the sidebar, with the layout's choices on
/// its hold. From the tab bar it brings the tabs back into the sidebar.
struct TabletSidebarDoor: View {
    @Environment(AppModel.self) private var app
    private var preferences: TabletLayoutPreferences { app.workspace.preferences }
    var body: some View {
        TabletChromeButton("Sidebar", asset: "TabletSidebar", id: "tablet.sidebar", size: Metrics.Tablet.sidebarMark) {
            if !preferences.tabsInSidebar {
                preferences.tabsInSidebar = true
                preferences.sidebarShown = true
            } else {
                app.workspace.sidebarShown.toggle()
            }
        }
        .accessibilityValue(preferences.tabsInSidebar && app.workspace.sidebarShown ? "shown" : "hidden")
        .contextMenu {
            Toggle("Show Tabs in Sidebar", isOn: Binding(get: { app.workspace.preferences.tabsInSidebar },
                                                         set: { app.workspace.preferences.tabsInSidebar = $0 }))
            Toggle("Show Address Bar", isOn: Binding(get: { app.workspace.preferences.addressBars },
                                                     set: { app.workspace.preferences.addressBars = $0 }))
            Toggle("Frame Page with Sidebar", isOn: Binding(get: { app.workspace.preferences.framed },
                                                            set: { app.workspace.preferences.framed = $0 }))
        }
    }
}

/// The sidebar's head, as the Mac's column has it: the door on the left,
/// Back, Forward and Reload against the right while the address is a plate.
struct TabletSidebarHeader: View {
    let plan: TabletChromePlan
    var body: some View {
        HStack(spacing: 0) {
            TabletSidebarDoor()
            TabletAllTabsDoor()
            Spacer(minLength: 0)
            if plan.headerNav { TabletNavigationDoors() }
        }
        .padding(.horizontal, Metrics.Tablet.headerInset)
        .frame(height: Metrics.Tablet.header)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tablet.sidebar.header")
    }
}

/// Opens and closes Site Controls in its popover from wherever it stands.
struct TabletSiteControlsDoor: View {
    @Environment(AppModel.self) private var app
    var size: CGFloat = Metrics.Tablet.doorMark
    private var open: Binding<Bool> {
        Binding(get: { app.surfaces.menu == .plate }, set: { open in
            if !open { app.surfaces.closeMenu(); app.pageMenu.reset() }
        })
    }
    var body: some View {
        TabletChromeButton("Site Controls", mac: .sliderHorizontal2Square, id: "tablet.siteControls", size: size) {
            if app.surfaces.menu == .plate { app.surfaces.closeMenu(); app.pageMenu.reset() }
            else { app.openPageMenu(); app.pageMenu.shown = true; app.pageMenu.page = .site }
        }
        .disabled(app.browser.tab == nil)
        .popover(isPresented: open, arrowEdge: .top) {
            TabletSiteControls().environment(app).presentationCompactAdaptation(.popover)
        }
    }
}

/// The address in the sidebar, as the Mac's column shows it with Show
/// Address Bar off: the site in a plate, a tap away from the field.
struct TabletAddressPlate: View {
    @Environment(AppModel.self) private var app
    private var host: String { app.browser.tab.map { $0.addressHost.isEmpty ? $0.address : $0.addressHost } ?? "" }

    var body: some View {
        HStack(spacing: 0) {
            Button { app.surfaces.openField(.address) } label: {
                HStack(spacing: Metrics.Tablet.plateGap) {
                    if app.pages.connection(app.browser.tab?.id ?? "", fallback: app.browser.tab?.navigationURL).secure == false,
                       app.browser.tab != nil {
                        TabletGlyph("TabletUnlock", size: Metrics.Tablet.plateLock, color: .red)
                    }
                    Text(host.isEmpty ? "Search or enter address" : host)
                        .font(.system(size: Metrics.Tablet.plateFont, weight: .medium))
                        .foregroundStyle(host.isEmpty ? Ink.secondary : Ink.primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, Metrics.Tablet.plateInset)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search or enter address")
            .accessibilityValue(app.browser.tab?.address ?? "")
            .accessibilityIdentifier("tablet.address")
            TabletSiteControlsDoor(size: Metrics.Tablet.plateDoorMark)
        }
        .frame(height: Metrics.Tablet.plate)
        .background(Ink.tabletWash, in: RoundedRectangle(cornerRadius: Metrics.Tablet.plateRadius, style: .continuous))
        .hoverEffect(.highlight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tablet.addressPlate")
    }
}

/// The tab buttons for when nothing else holds them: downloads, New Tab
/// (its hold has the rest) and All Tabs.
struct TabletWorkspaceDoors: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        HStack(spacing: 0) {
            if app.showsToolbarDownloads(sidebarShown: false) {
                TabletDownloadsButton(active: true, id: "tablet.downloads")
            }
            TabletNewTabMenu(id: "tablet.newTab")
            TabletAllTabsDoor()
        }
    }
}

/// All Tabs: every tab of the space as cards.
struct TabletAllTabsDoor: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        TabletChromeButton("All Tabs", mac: .yabTabs, id: "tablet.tabs", size: Metrics.Tablet.allTabsMark) { TabStack.of(app).openGallery() }
            .disabled(app.browser.space.allTabs.isEmpty)
    }
}

/// New Tab on a tap; on a hold the other ways in and the split.
struct TabletNewTabMenu: View {
    @Environment(AppModel.self) private var app
    let id: String
    var spaces: (() -> Void)? = nil
    /// In a narrow band, the tab buttons' one door: All Tabs and the
    /// downloads (their list and question too) are in its menu.
    var folded = false
    @State private var downloadsOpen = false
    private var downloads: Bool { folded && app.showsToolbarDownloads(sidebarShown: false) }
    var body: some View {
        Menu {
            Button { app.openNewTab() } label: { Label("New Tab", image: MacGlyph.yabTabPlus.rawValue) }
                .accessibilityIdentifier("tablet.menu.newTab")
            Button { app.openNewTab(privately: true) } label: { Label("New Private Tab", image: MacGlyph.incognito.rawValue) }
                .accessibilityIdentifier("tablet.menu.newPrivateTab")
            Button { TabStack.of(app).openGallery() } label: { Label("All Tabs", image: MacGlyph.yabTabs.rawValue) }
                .accessibilityIdentifier("tablet.menu.allTabs")
            if downloads {
                Button { downloadsOpen = true } label: { Label("Downloads", image: MacGlyph.yabDownload.rawValue) }
                    .accessibilityIdentifier("tablet.menu.downloads")
            }
            if app.splitRowsShown {
                Divider()
                Button("Split View") { app.newTabBeside() }
                    .accessibilityIdentifier("tablet.menu.splitView")
                if app.workspace.paired {
                    Button("Separate Split View") { app.workspace.fullSpread() }
                    Button("Close Split") { app.closeWorkspacePage() }
                }
            }
            if let spaces {
                Divider()
                Button("Spaces and Chats", action: spaces)
                    .accessibilityIdentifier("tablet.menu.spaces")
            }
        } label: {
            Glyph(.plusMedium, size: Metrics.Tablet.newTabMark)
                .frame(width: Metrics.Tablet.door, height: Metrics.Tablet.door)
                .tabletHover()
                .contentShape(Rectangle())
        } primaryAction: {
            app.openNewTab()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Tab")
        .accessibilityIdentifier(id)
        .modifier(TabletDownloadsHost(active: downloads, id: id + ".downloads", open: $downloadsOpen))
    }
}

/// The address band over a page card (Show Address Bar on, the sidebar
/// away, or the tab bar): the site in the middle, its controls at the ends,
/// as TabletBandPlan places them. In a split, one over each pane, the
/// focused one in full. With no tab shown, the band keeps the sidebar's
/// door and the tab buttons, and its middle opens a new tab.
struct TabletPageBand: View {
    @Environment(AppModel.self) private var app
    let tab: Tab?
    let band: TabletBandPlan
    private var focused: Bool { tab != nil && app.browser.tab?.id == tab?.id }
    private var name: String { tab?.id ?? "empty" }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                if band.sidebarDoor { TabletSidebarDoor() }
                if band.navigation, let tab { TabletNavigationDoors(tab: tab) }
            }
            .frame(width: band.leadingWidth, alignment: .leading)
            address
            HStack(spacing: 0) {
                if band.siteControls { TabletSiteControlsDoor() }
                if band.splitMenu { splitMenu }
                if band.close, let tab {
                    Button { app.closeWorkspacePage(tab.id) } label: {
                        Glyph(.crossSmall, size: Metrics.Tablet.doorMark).frame(width: Metrics.Tablet.door, height: Metrics.Tablet.door)
                            .tabletHover().contentShape(Rectangle())
                    }
                    .buttonStyle(TabletChromeButtonPress())
                    .accessibilityLabel("Close Split").accessibilityIdentifier("tablet.close.\(tab.id)")
                }
                switch band.workspace {
                case .doors: TabletWorkspaceDoors()
                case .menu: TabletNewTabMenu(id: "tablet.newTab", folded: true)
                case .none: EmptyView()
                }
            }
            .frame(width: band.trailingWidth, alignment: .trailing)
        }
        .padding(.horizontal, Metrics.Tablet.bandInset)
        .frame(height: Metrics.Tablet.paneBar)
        .background(Ink.tabletBand)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.tabletRule).frame(height: Metrics.Tablet.bandRule) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tablet.addressBar.\(name)")
        .accessibilityValue(focused ? "active" : "inactive")
    }

    private var address: some View {
        Button {
            guard let tab else { app.openNewTab(); return }
            if !focused { app.browser.select(tab.id); _ = app.pages.activate(tab) }
            app.surfaces.openField(.address)
        } label: {
            Text(tab.map { $0.addressHost.isEmpty ? $0.address : $0.addressHost } ?? "Search or enter address")
                .font(.system(size: Metrics.Tablet.bandAddressFont, weight: .medium))
                .foregroundStyle(focused ? Ink.primary : Ink.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search or enter address").accessibilityValue(tab?.address ?? "")
        .accessibilityIdentifier(focused ? "tablet.address" : "tablet.address.\(name)")
    }
}

extension TabletPageBand {
    /// The split's own choices, on its focused page.
    var splitMenu: some View {
        Menu {
            Button("Split View") { app.newTabBeside() }
            Button("Separate Split View") { app.workspace.fullSpread() }
            Button("Close Split") { if let tab { app.closeWorkspacePage(tab.id) } }
        } label: {
            TabletGlyph("TabletSplitView", size: Metrics.Tablet.splitMark)
                .frame(width: Metrics.Tablet.door, height: Metrics.Tablet.door)
                .tabletHover()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Split View").accessibilityIdentifier("tablet.paneMenu")
    }
}

/// The Mac's tab bar, for Show Tabs in Sidebar off: Back, Forward and
/// Reload, the space, its pins, its tabs, +, then downloads and All Tabs.
struct TabletTabStrip: View {
    @Environment(AppModel.self) private var app
    private var space: Space { app.browser.space }
    private var tabs: [Tab] {
        space.keptTabs + space.today.filter { space.isPrivate || !$0.isPrivate }
    }

    var body: some View {
        HStack(spacing: Metrics.Tablet.stripSpacing) {
            HStack(spacing: 0) {
                TabletSidebarDoor()
                TabletNavigationDoors()
            }
            spaceMenu
            ScrollViewReader { scroll in
                ScrollView(.horizontal) {
                    HStack(spacing: Metrics.Tablet.stripGap) {
                        ForEach(app.sync.pins(in: space)) { pin($0) }
                        ForEach(tabs) { tab($0).id($0.id) }
                    }
                    .padding(.horizontal, Metrics.Tablet.stripScrollInset)
                }
                .scrollIndicators(.hidden)
                .onChange(of: app.browser.tab?.id, initial: true) { _, id in
                    guard let id else { return }
                    Motion.space.run { scroll.scrollTo(id, anchor: .center) }
                }
            }
            TabletNewTabMenu(id: "tablet.newTab")
            TabletDownloadsButton(active: true, id: "tablet.downloads")
            TabletAllTabsDoor()
        }
        .padding(.horizontal, Metrics.Tablet.stripInset)
        .frame(height: Metrics.Tablet.strip)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tablet.strip")
    }

    private var spaceMenu: some View {
        Menu {
            ForEach(app.browser.spaces.filter { !$0.isPrivate }) { item in
                Button { Motion.space.run { app.workspace.fullSpread(); app.browser.showSpace(item.id) } } label: {
                    Text(item.emoji.isEmpty ? item.name : "\(item.emoji)  \(item.name)")
                }
            }
        } label: {
            HStack(spacing: Metrics.Tablet.stripSpacing) {
                if !space.emoji.isEmpty { Text(space.emoji).font(.system(size: Metrics.Tablet.stripEmoji)) }
                Text(space.name).font(.system(size: Metrics.Tablet.labelFont, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, Metrics.Tablet.stripTabInset)
            .frame(height: Metrics.Tablet.stripTab)
            .background(Ink.tabletWash, in: Capsule())
            .contentShape(.hoverEffect, Capsule())
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Space")
        .accessibilityValue(space.name)
        .accessibilityIdentifier("tablet.strip.space")
    }

    private func select(_ tab: Tab) { app.chooseFromSpacePage(tab.id, in: space.id) }

    private func pin(_ tab: Tab) -> some View {
        Button { select(tab) } label: {
            Favicon(icon: tab.icon, host: tab.addressHost, size: Metrics.Tablet.stripPinIcon, url: tab.navigationURL, isPrivate: tab.isPrivate, mark: tab.customMark)
                .frame(width: Metrics.Tablet.stripPin, height: Metrics.Tablet.stripTab)
                .background(tab.id == space.current ? Ink.tabletSelected : Ink.tabletPinRest,
                            in: RoundedRectangle(cornerRadius: Metrics.Tablet.doorRadius, style: .continuous))
                .tabletHover()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.short)
        .accessibilityAddTraits(tab.id == space.current ? .isSelected : [])
        .accessibilityIdentifier("tablet.pin.\(tab.id)")
        .modifier(TabHold(tab: tab, list: .pins, page: space.id))
    }

    private func tab(_ tab: Tab) -> some View {
        let current = tab.id == space.current
        return Button { select(tab) } label: {
            HStack(spacing: Metrics.Tablet.stripTabGap) {
                Favicon(icon: tab.icon, host: tab.addressHost, size: Metrics.Tablet.stripTabIcon, url: tab.navigationURL, isPrivate: tab.isPrivate, mark: tab.customMark)
                Text(tab.short).font(.system(size: Metrics.Tablet.labelFont)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, Metrics.Tablet.stripTabInset)
            .frame(width: Metrics.Tablet.stripTabWidth, height: Metrics.Tablet.stripTab)
            .background(current ? Ink.tabletSelected : .clear, in: RoundedRectangle(cornerRadius: Metrics.Tablet.doorRadius, style: .continuous))
            .tabletHover()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tablet.tab.\(tab.id)")
        .accessibilityAddTraits(current ? .isSelected : [])
        .modifier(TabHold(tab: tab, list: tab.place == .kept ? .kept : .today))
    }
}
