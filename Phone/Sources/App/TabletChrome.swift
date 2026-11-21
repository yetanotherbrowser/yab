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
    var plate: Bool { sidebarInView && !addressBars && !split }
    /// Back, Forward and Reload in the sidebar's header, beside its door.
    var headerNav: Bool { plate }
    /// The address as a band across the top of the page card.
    var band: Bool { !plate }
    /// The band holds Back, Forward and Reload, unless the tab bar has them.
    var bandNav: Bool { band && !strip }
    /// The band holds the sidebar's door and the tab buttons when neither
    /// the sidebar nor the tab bar is there to hold them.
    var bandWorkspace: Bool { !strip && !sidebarInView }
}

extension Metrics.Tablet {
    /// The Mac's sidebar header (Metrics.strip) and its doors (SideBar).
    static let header: CGFloat = 52
    static let door: CGFloat = 36
    static let doorRadius: CGFloat = 10
    /// The Mac's address plate in the sidebar (SiteControls).
    static let plate: CGFloat = 36
    static let plateRadius: CGFloat = 10
    static let plateFont: CGFloat = 12.5
    /// The Mac's tab bar: its row, a tab, a pin (Design.swift Density).
    static let strip: CGFloat = 46
    static let stripTab: CGFloat = 34
    static let stripTabWidth: CGFloat = 186
    static let stripPin: CGFloat = 36
    static let stripGap: CGFloat = 2
}

/// A door of the Mac's chrome: a mark on a plate that shows under a
/// pointer or a press, a finger's target around it.
struct TabletDoor: View {
    let title: String
    let mark: Image
    let id: String
    var size: CGFloat = 15
    let action: () -> Void

    init(_ title: String, mac: MacGlyph, id: String, size: CGFloat = 15, action: @escaping () -> Void) {
        self.title = title; self.mark = Image(mac.rawValue); self.id = id; self.size = size; self.action = action
    }
    init(_ title: String, asset: String, id: String, size: CGFloat = 17, action: @escaping () -> Void) {
        self.title = title; self.mark = Image(asset); self.id = id; self.size = size; self.action = action
    }

    var body: some View {
        Button(action: action) {
            mark.renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size)
                .frame(width: Metrics.Tablet.door, height: Metrics.Tablet.door)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Metrics.Tablet.doorRadius, style: .continuous))
                .hoverEffect(.highlight)
                .contentShape(Rectangle())
        }
        .buttonStyle(TabletDoorPress())
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}

/// The Mac's door under a finger: its plate, briefly.
struct TabletDoorPress: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Ink.primary : Ink.secondary.opacity(0.5))
            .background(Ink.primary.opacity(configuration.isPressed ? 0.1 : 0),
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
            TabletDoor("Back", mac: .yabBack, id: id("tablet.back")) { act { app.goBack() } }
                .disabled(!canGoBack)
            TabletDoor("Forward", mac: .yabForward, id: id("tablet.forward")) { act { app.pageMenuForward() } }
                .disabled(!state.canGoForward)
            TabletDoor(state.isLoading ? "Stop" : "Reload", mac: state.isLoading ? .yabStop : .yabReload, id: id("tablet.reload"), size: 16) {
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
        TabletDoor("Sidebar", asset: "TabletSidebar", id: "tablet.sidebar", size: 18) {
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
        .padding(.horizontal, Metrics.Tablet.inset - 4)
        .frame(height: Metrics.Tablet.header)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tablet.sidebar.header")
    }
}

/// Opens and closes Site Controls in its popover from wherever it stands.
struct TabletSiteControlsDoor: View {
    @Environment(AppModel.self) private var app
    var size: CGFloat = 15
    private var open: Binding<Bool> {
        Binding(get: { app.surfaces.menu == .plate }, set: { open in
            if !open { app.surfaces.closeMenu(); app.pageMenu.reset() }
        })
    }
    var body: some View {
        TabletDoor("Site Controls", mac: .sliderHorizontal2Square, id: "tablet.siteControls", size: size) {
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
                HStack(spacing: 8) {
                    if app.pages.connection(app.browser.tab?.id ?? "", fallback: app.browser.tab?.navigationURL).secure == false,
                       app.browser.tab != nil {
                        TabletGlyph("TabletUnlock", size: 12, color: .red)
                    }
                    Text(host.isEmpty ? "Search or enter address" : host)
                        .font(.system(size: Metrics.Tablet.plateFont, weight: .medium))
                        .foregroundStyle(host.isEmpty ? Ink.secondary : Ink.primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search or enter address")
            .accessibilityValue(app.browser.tab?.address ?? "")
            .accessibilityIdentifier("tablet.address")
            TabletSiteControlsDoor(size: 14)
        }
        .frame(height: Metrics.Tablet.plate)
        .background(Ink.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: Metrics.Tablet.plateRadius, style: .continuous))
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
        TabletDoor("All Tabs", mac: .yabTabs, id: "tablet.tabs", size: 17) { TabStack.of(app).openGallery() }
            .disabled(app.browser.space.allTabs.isEmpty)
    }
}

/// New Tab on a tap; on a hold the other ways in and the split.
struct TabletNewTabMenu: View {
    @Environment(AppModel.self) private var app
    let id: String
    var spaces: (() -> Void)? = nil
    var body: some View {
        Menu {
            Button { app.openNewTab() } label: { Label("New Tab", image: MacGlyph.yabTabPlus.rawValue) }
                .accessibilityIdentifier("tablet.menu.newTab")
            Button { app.openNewTab(privately: true) } label: { Label("New Private Tab", image: MacGlyph.incognito.rawValue) }
                .accessibilityIdentifier("tablet.menu.newPrivateTab")
            Button { TabStack.of(app).openGallery() } label: { Label("All Tabs", image: MacGlyph.yabTabs.rawValue) }
                .accessibilityIdentifier("tablet.menu.allTabs")
            if app.workspace.canSplit, !app.pageIsPrivate, app.browser.tab != nil, app.browser.tab?.isMail != true {
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
            Glyph(.plusMedium, size: 17)
                .frame(width: Metrics.Tablet.door, height: Metrics.Tablet.door)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Metrics.Tablet.doorRadius, style: .continuous))
                .hoverEffect(.highlight)
                .contentShape(Rectangle())
        } primaryAction: {
            app.openNewTab()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Tab")
        .accessibilityIdentifier(id)
    }
}

/// The address band over a page card (Show Address Bar on, the sidebar
/// away, or the tab bar): the site in the middle, its controls at the ends.
/// In a split, one over each pane, the focused one in full.
struct TabletPageBand: View {
    @Environment(AppModel.self) private var app
    let tab: Tab
    let plan: TabletChromePlan
    let split: Bool
    private var focused: Bool { app.browser.tab?.id == tab.id }
    private var leading: Bool { !split || tab.id == app.workspace.first }
    private var side: CGFloat {
        // Both ends as wide as the wider, so the site stays centered.
        let leading = (plan.bandWorkspace ? 1 : 0) + (plan.bandNav ? 3 : 0)
        let trailing = 1 + (split ? 2 : 0) + (plan.bandWorkspace ? 2 + (app.showsToolbarDownloads(sidebarShown: false) ? 1 : 0) : 0)
        return Metrics.Tablet.door * CGFloat(max(leading, trailing))
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                // One door, at the window's leading edge: on the first page of a split.
                if plan.bandWorkspace, leading { TabletSidebarDoor() }
                if plan.bandNav { TabletNavigationDoors(tab: tab) }
            }
            .frame(width: side, alignment: .leading)
            Button {
                if !focused { app.browser.select(tab.id); _ = app.pages.activate(tab) }
                app.surfaces.openField(.address)
            } label: {
                Text(tab.addressHost.isEmpty ? tab.address : tab.addressHost)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(focused ? Ink.primary : Ink.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search or enter address").accessibilityValue(tab.address)
            .accessibilityIdentifier(focused ? "tablet.address" : "tablet.address.\(tab.id)")
            HStack(spacing: 0) {
                if focused { TabletSiteControlsDoor() }
                if split && focused { splitMenu }
                if split {
                    Button { app.closeWorkspacePage(tab.id) } label: {
                        Glyph(.crossSmall, size: 15).frame(width: Metrics.Tablet.door, height: Metrics.Tablet.door)
                            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Metrics.Tablet.doorRadius, style: .continuous))
                            .hoverEffect(.highlight).contentShape(Rectangle())
                    }
                    .buttonStyle(TabletDoorPress())
                    .accessibilityLabel("Close Split").accessibilityIdentifier("tablet.close.\(tab.id)")
                }
                if plan.bandWorkspace && focused { TabletWorkspaceDoors() }
            }
            .frame(width: side, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(height: Metrics.Tablet.paneBar)
        .background(Ink.surface.opacity(0.92))
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.primary.opacity(0.08)).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tablet.addressBar.\(tab.id)")
        .accessibilityValue(focused ? "active" : "inactive")
    }
}

extension TabletPageBand {
    /// The split's own choices, on its focused page.
    var splitMenu: some View {
        Menu {
            Button("Split View") { app.newTabBeside() }
            Button("Separate Split View") { app.workspace.fullSpread() }
            Button("Close Split") { app.closeWorkspacePage(tab.id) }
        } label: {
            TabletGlyph("TabletSplitView", size: 16)
                .frame(width: Metrics.Tablet.door, height: Metrics.Tablet.door)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Metrics.Tablet.doorRadius, style: .continuous))
                .hoverEffect(.highlight)
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
        HStack(spacing: 6) {
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
                    .padding(.horizontal, 2)
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
        .padding(.horizontal, 8)
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
            HStack(spacing: 6) {
                if !space.emoji.isEmpty { Text(space.emoji).font(.system(size: 15)) }
                Text(space.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, 10)
            .frame(height: Metrics.Tablet.stripTab)
            .background(Ink.primary.opacity(0.055), in: Capsule())
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
            Favicon(icon: tab.icon, host: tab.addressHost, size: 17, url: tab.navigationURL, isPrivate: tab.isPrivate, mark: tab.customMark)
                .frame(width: Metrics.Tablet.stripPin, height: Metrics.Tablet.stripTab)
                .background(Ink.primary.opacity(tab.id == space.current ? 0.09 : 0.04),
                            in: RoundedRectangle(cornerRadius: Metrics.Tablet.doorRadius, style: .continuous))
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Metrics.Tablet.doorRadius, style: .continuous))
                .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.short)
        .accessibilityAddTraits(tab.id == space.current ? .isSelected : [])
        .accessibilityIdentifier("tablet.pin.\(tab.id)")
        .modifier(TabHold(tab: tab, list: .pins))
    }

    private func tab(_ tab: Tab) -> some View {
        let current = tab.id == space.current
        return Button { select(tab) } label: {
            HStack(spacing: 8) {
                Favicon(icon: tab.icon, host: tab.addressHost, size: 15, url: tab.navigationURL, isPrivate: tab.isPrivate, mark: tab.customMark)
                Text(tab.short).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, 10)
            .frame(width: Metrics.Tablet.stripTabWidth, height: Metrics.Tablet.stripTab)
            .background(Ink.primary.opacity(current ? 0.09 : 0), in: RoundedRectangle(cornerRadius: Metrics.Tablet.doorRadius, style: .continuous))
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Metrics.Tablet.doorRadius, style: .continuous))
            .hoverEffect(.highlight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tablet.tab.\(tab.id)")
        .accessibilityAddTraits(current ? .isSelected : [])
        .modifier(TabHold(tab: tab, list: tab.place == .kept ? .kept : .today))
    }
}
