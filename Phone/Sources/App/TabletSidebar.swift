import SwiftUI

/// The Mac's sidebar order, with iPad touch targets and the existing tab menus.
struct TabletSidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let width: CGFloat
    /// On screen: the sidebar stays in the tree, faded, while it is away.
    var shown = true
    @State private var browseSpaces = false
    private var space: Space { app.browser.space }
    private var shownPins: [Tab] { app.sync.pins(in: space) }
    private var pair: [Tab.ID] { app.workspace.paired ? [app.workspace.first, app.workspace.second].compactMap { $0 } : [] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !shownPins.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
                            ForEach(shownPins) { tab in
                                Button { select(tab) } label: {
                                    mark(tab, size: 24).frame(maxWidth: .infinity).frame(height: Metrics.Tablet.pin)
                                        .background(Ink.surface.opacity(tab.id == space.current ? 0.95 : 0.5), in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain).accessibilityLabel(tab.short)
                                .accessibilityIdentifier("tablet.pin.\(tab.id)")
                                .modifier(TabHold(tab: tab, list: .pins, page: space.id))
                            }
                        }.padding(.bottom, 12)
                    }
                    ForEach(space.kept) { kept($0, depth: 0) }
                    if !space.today.isEmpty {
                        HStack(spacing: 10) {
                            Rectangle().fill(Ink.primary.opacity(0.12)).frame(height: 0.5)
                            Button("Clear") { Task { @MainActor in await app.tabClear.clear(in: space.id) } }
                                .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                                .frame(minHeight: Metrics.touch)
                                .accessibilityIdentifier("tablet.clear")
                        }.padding(.horizontal, 8)
                    }
                    if pair.count == 2 { pairRow }
                    ForEach(space.today.filter { (space.isPrivate || !$0.isPrivate) && !pair.contains($0.id) }) { row($0) }
                }.padding(.horizontal, Metrics.Tablet.inset).padding(.top, 8)
            }
            footer
        }
        .frame(width: width)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tablet.sidebar.content")
    }

    private func mark(_ tab: Tab, size: CGFloat = 17) -> some View {
        Favicon(icon: tab.icon, host: tab.addressHost, size: size, url: tab.navigationURL,
                isPrivate: tab.isPrivate, mark: tab.customMark)
    }
    private func select(_ tab: Tab) { app.chooseFromSpacePage(tab.id, in: space.id) }

    private func row(_ tab: Tab, depth: Int = 0) -> some View {
        Button { select(tab) } label: {
            HStack(spacing: 10) {
                mark(tab)
                Text(tab.short).font(.system(size: 13.5)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, 10).frame(minHeight: Metrics.Tablet.row)
            .background(Ink.surface.opacity(tab.id == space.current ? 0.85 : 0), in: RoundedRectangle(cornerRadius: 8))
            .padding(.leading, CGFloat(depth) * 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("tablet.tab.\(tab.id)")
        .accessibilityAddTraits(tab.id == space.current ? .isSelected : [])
        .modifier(TabHold(tab: tab, list: tab.place == .kept ? .kept : .today))
    }

    private var pairRow: some View {
        HStack(spacing: Metrics.Tablet.pairGap) {
            ForEach(pair, id: \.self) { id in
                if let tab = app.browser.tab(id) {
                    Button { select(tab) } label: {
                        HStack(spacing: Metrics.Tablet.pairPadding) {
                            mark(tab, size: Metrics.Tablet.pairIcon)
                            Text(tab.short).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Ink.primary)
                        .padding(.horizontal, Metrics.Tablet.pairPadding)
                        .frame(maxWidth: .infinity)
                        .frame(height: Metrics.Tablet.row - 2 * Metrics.Tablet.pairInset)
                        .background(Ink.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: Metrics.Tablet.pairRadius))
                        .padding(.vertical, Metrics.Tablet.pairInset)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.short)
                    .accessibilityIdentifier("tablet.split.tab.\(id)")
                    .accessibilityAddTraits(id == app.browser.tab?.id ? .isSelected : [])
                    .modifier(TabHold(tab: tab, list: tab.place == .kept ? .kept : .today))
                }
            }
        }
        .padding(.horizontal, Metrics.Tablet.pairInset)
        .background(Ink.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain).accessibilityIdentifier("tablet.split.row")
    }

    private func kept(_ item: KeptItem, depth: Int) -> AnyView {
        switch item {
        case let .tab(tab): return AnyView(row(tab, depth: depth))
        case let .folder(folder):
            return AnyView(VStack(spacing: 0) {
                Button { (folder.open ? Motion.folderShut : Motion.folderOpen).run { app.browser.setFolder(folder.id, open: !folder.open, in: space.id) } } label: {
                    HStack(spacing: 10) {
                        FolderMark(mark: folder.customMark, open: folder.open, tint: space.folderGround(dark: scheme == .dark), dark: scheme == .dark, size: 17, color: folder.color)
                        Text(folder.name).font(.system(size: 13.5)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: folder.open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10)).foregroundStyle(Ink.secondary)
                    }
                    .foregroundStyle(Ink.primary).padding(.horizontal, 10)
                    .padding(.leading, CGFloat(depth) * 16).frame(minHeight: Metrics.Tablet.row)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("tablet.folder.\(folder.id)")
                if folder.open { ForEach(folder.items) { kept($0, depth: depth + 1) } }
            })
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button { app.openSettingsFromSpaces(at: nil) } label: {
                Glyph(SettingsFieldRow.glyph, size: 17).frame(width: Metrics.touch, height: Metrics.touch).contentShape(Rectangle())
            }
                .frame(width: Metrics.touch, height: Metrics.touch).accessibilityLabel("Settings")
                .contextMenu {
                    Button("Spaces and Chats") { browseSpaces = true }
                }
                .popover(isPresented: $browseSpaces) {
                    SpacePagesCard(content: NewTabContent.make(for: app), width: Metrics.Workspace.sidebar,
                                   maxHeight: TabletWorkspaceGeometry.sheetHeight, fullness: 1,
                                   headerInset: SpacePagesCard.capsuleTop)
                        .environment(app).presentationCompactAdaptation(.popover)
                }
                .accessibilityIdentifier("tablet.settings")
            TabletDownloadsButton(active: shown, id: "tablet.downloads.sidebar")
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(app.browser.spaces.filter { !$0.isPrivate }) { item in
                        Button { app.workspace.fullSpread(); app.browser.showSpace(item.id) } label: {
                            Group {
                                if item.emoji.isEmpty { Image(systemName: "circle.fill").font(.system(size: 10)) }
                                else { Text(item.emoji).font(.system(size: 17)) }
                            }
                            .frame(width: Metrics.touch, height: Metrics.touch)
                            .background(Ink.surface.opacity(item.id == space.id ? 0.8 : 0), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel(item.name)
                        .accessibilityAddTraits(item.id == space.id ? .isSelected : [])
                        .accessibilityIdentifier("tablet.space.\(item.id)")
                    }
                }
            }.scrollIndicators(.hidden)
            Button { app.openNewTab() } label: {
                Glyph(.plusMedium, size: 18).frame(width: Metrics.touch, height: Metrics.touch).contentShape(Rectangle())
            }
                .frame(width: Metrics.touch, height: Metrics.touch).accessibilityLabel("New Tab")
                .accessibilityIdentifier("tablet.sidebar.newTab")
        }
        .buttonStyle(.plain).foregroundStyle(Ink.primary)
        .padding(.horizontal, 4).padding(.vertical, 6)
        .background(alignment: .top) { Rectangle().fill(Ink.primary.opacity(0.1)).frame(height: 0.5) }
        .onChange(of: app.browser.tab?.id) { _, _ in browseSpaces = false }
        .onChange(of: app.surfaces.chat) { _, _ in browseSpaces = false }
        .onChange(of: app.surfaces.settings) { _, shown in if shown { browseSpaces = false } }
    }
}
