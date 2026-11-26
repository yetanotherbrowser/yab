import SwiftUI

/// The Mac's column: its header (the door, and Back, Forward and Reload
/// while the address is a plate), the address plate, then each space's
/// page of pins and tabs side by side, sliding as the Mac's do when the
/// space changes (docs/space-switching.md), and the foot.
struct TabletSidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let width: CGFloat
    /// On screen: the sidebar stays in the tree, faded, while it is away.
    var shown = true
    var plan = TabletChromePlan(strip: false, sidebarInView: true, addressBars: false)
    @State private var browseSpaces = false
    @GestureState private var drag: CGFloat = 0
    private var space: Space { app.browser.space }
    /// The pages side by side: every ordinary space, and a private one only while it is in front.
    private var pages: [Space] { app.browser.spaces.filter { !$0.isPrivate || $0.id == space.id } }
    private var pair: [Tab.ID] { app.workspace.paired ? [app.workspace.first, app.workspace.second].compactMap { $0 } : [] }

    var body: some View {
        VStack(spacing: 0) {
            // Away, its doors go: the band holds the same ones (TabletPageBand).
            if shown { TabletSidebarHeader(plan: plan).transition(.identity) } else { Color.clear.frame(height: Metrics.Tablet.header) }
            if plan.addressPlate {
                TabletAddressPlate()
                    .padding(.horizontal, Metrics.Tablet.inset)
                    .padding(.bottom, Metrics.Tablet.plateBelow)
                    // Gone at once: the band takes the address as the sidebar leaves.
                    .transition(.identity)
            }
            pager
            footer
        }
        .frame(width: width)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tablet.sidebar.content")
    }

    // MARK: - the pages

    private var pager: some View {
        let index = CGFloat(pages.firstIndex { $0.id == space.id } ?? 0)
        return HStack(spacing: 0) {
            ForEach(pages) { page in
                self.page(page)
                    .frame(width: width)
                    .accessibilityHidden(page.id != space.id)
            }
        }
        .frame(width: width, alignment: .leading)
        .offset(x: -index * width + drag)
        .animation(Motion.space.current, value: index)
        .clipped()
        .contentShape(Rectangle())
        // A sideways swipe pages the spaces as two fingers do on the Mac
        // (SpacePaging): half the finger's travel, a page at most, resisting
        // past the ends; let go moving it keeps on, held it settles nearest.
        .simultaneousGesture(
            DragGesture(minimumDistance: Metrics.Tablet.spaceSwipeStart)
                .updating($drag) { value, state, _ in
                    guard abs(value.translation.width) > abs(value.translation.height) * Metrics.Tablet.spaceSwipeSlant else { return }
                    state = Self.paged(value.translation.width, index: Int(index), count: pages.count, width: width)
                }
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * Metrics.Tablet.spaceSwipeSlant else { return }
                    let moved = Self.paged(value.translation.width, index: Int(index), count: pages.count, width: width)
                    let speed = value.velocity.width * Metrics.Tablet.spacePull
                    let step: Int
                    if abs(speed) > Metrics.Tablet.spaceFling { step = speed < 0 ? 1 : -1 }
                    else { step = abs(moved) > width / 2 ? (moved < 0 ? 1 : -1) : 0 }
                    let next = Int(index) + step
                    guard step != 0, pages.indices.contains(next) else { return }
                    show(pages[next])
                }
        )
    }

    /// The pages' offset for a finger's travel: the Mac's half, one page at
    /// most, a little give past the first and the last.
    static func paged(_ travel: CGFloat, index: Int, count: Int, width: CGFloat) -> CGFloat {
        let moved = min(width, max(-width, travel * Metrics.Tablet.spacePull))
        let pastEnd = (index == 0 && moved > 0) || (index >= count - 1 && moved < 0)
        return pastEnd ? moved * Metrics.Tablet.spaceGive : moved
    }

    private func page(_ space: Space) -> some View {
        let pins = app.sync.pins(in: space)
        let front = space.id == self.space.id
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !pins.isEmpty {
                    let columns = Metrics.Tablet.pinColumns(pins.count, width: width - 2 * Metrics.Tablet.inset)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.Tablet.pinGap), count: columns),
                              spacing: Metrics.Tablet.pinGap) {
                        ForEach(pins) { tab in
                            Button { select(tab, in: space) } label: {
                                mark(tab, size: Metrics.Tablet.pinMark).frame(maxWidth: .infinity).frame(height: Metrics.Tablet.pin)
                                    .background(tab.id == space.current ? Ink.tabletPinFront : Ink.tabletPinGround,
                                                in: RoundedRectangle(cornerRadius: Metrics.Tablet.doorRadius, style: .continuous))
                                    .tabletHover()
                            }
                            .buttonStyle(.plain).accessibilityLabel(tab.short)
                            .accessibilityIdentifier("tablet.pin.\(tab.id)")
                            .modifier(TabHold(tab: tab, list: .pins, page: space.id))
                        }
                    }.padding(.bottom, Metrics.Tablet.pinsBelow)
                }
                ForEach(space.kept) { kept($0, in: space, depth: 0) }
                if !space.today.isEmpty { clearLine(space) }
                if front, pair.count == 2 { pairRow(space) }
                ForEach(space.today.filter { (space.isPrivate || !$0.isPrivate) && !(front && pair.contains($0.id)) }) { row($0, in: space) }
            }
            .padding(.horizontal, Metrics.Tablet.inset).padding(.top, Metrics.Tablet.listTop)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tablet.sidebar.page.\(space.id)")
    }

    private func mark(_ tab: Tab, size: CGFloat = 17) -> some View {
        Favicon(icon: tab.icon, host: tab.addressHost, size: size, url: tab.navigationURL,
                isPrivate: tab.isPrivate, mark: tab.customMark)
    }
    private func select(_ tab: Tab, in space: Space) { app.chooseFromSpacePage(tab.id, in: space.id) }
    private func show(_ space: Space) {
        guard space.id != self.space.id else { return }
        Motion.space.run { app.workspace.fullSpread(); app.browser.showSpace(space.id) }
    }

    /// The Mac's line between kept tabs and Today: thin, Clear at its end.
    private func clearLine(_ space: Space) -> some View {
        HStack(spacing: Metrics.Tablet.clearGap) {
            Rectangle().fill(Ink.tabletClearRule).frame(height: Metrics.Tablet.clearRule)
            Button("Clear") { Task { @MainActor in await app.tabClear.clear(in: space.id) } }
                .font(.system(size: Metrics.Tablet.clearFont)).foregroundStyle(Ink.secondary)
                .frame(minWidth: Metrics.touch, minHeight: Metrics.Tablet.clearLine)
                .contentShape(Rectangle())
                .hoverEffect(.highlight)
                .accessibilityIdentifier("tablet.clear")
        }
        .padding(.horizontal, Metrics.Tablet.clearInset)
    }

    /// A tab's row: the Mac's 36-point ground inside a finger's 44.
    private func row(_ tab: Tab, in space: Space, depth: Int = 0) -> some View {
        let current = tab.id == space.current
        return Button { select(tab, in: space) } label: {
            HStack(spacing: 10) {
                mark(tab)
                Text(tab.short).font(.system(size: 13.5)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, Metrics.Tablet.rowInset)
            .frame(height: Metrics.Tablet.rowGround)
            .background(current ? Ink.tabletRowFront : .clear,
                        in: RoundedRectangle(cornerRadius: Metrics.Tablet.doorRadius, style: .continuous))
            .tabletHover()
            .padding(.leading, CGFloat(depth) * 16)
            .frame(minHeight: Metrics.Tablet.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("tablet.tab.\(tab.id)")
        .accessibilityAddTraits(current ? .isSelected : [])
        .modifier(TabHold(tab: tab, list: tab.place == .kept ? .kept : .today))
    }

    private func pairRow(_ space: Space) -> some View {
        HStack(spacing: Metrics.Tablet.pairGap) {
            ForEach(pair, id: \.self) { id in
                if let tab = app.browser.tab(id) {
                    Button { select(tab, in: space) } label: {
                        HStack(spacing: Metrics.Tablet.pairPadding) {
                            mark(tab, size: Metrics.Tablet.pairIcon)
                            Text(tab.short).font(.system(size: Metrics.Tablet.labelFont)).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Ink.primary)
                        .padding(.horizontal, Metrics.Tablet.pairPadding)
                        .frame(maxWidth: .infinity)
                        .frame(height: Metrics.Tablet.rowGround - 2 * Metrics.Tablet.pairInset)
                        .background(Ink.tabletPairChip, in: RoundedRectangle(cornerRadius: Metrics.Tablet.pairRadius))
                        // The Mac's chip, a finger's height to touch.
                        .frame(height: Metrics.Tablet.row)
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
        .background(Ink.tabletRowFront, in: RoundedRectangle(cornerRadius: Metrics.Tablet.doorRadius, style: .continuous)
            .inset(by: (Metrics.Tablet.row - Metrics.Tablet.rowGround) / 2))
        .accessibilityElement(children: .contain).accessibilityIdentifier("tablet.split.row")
    }

    private func kept(_ item: KeptItem, in space: Space, depth: Int) -> AnyView {
        switch item {
        case let .tab(tab): return AnyView(row(tab, in: space, depth: depth))
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
                if folder.open { ForEach(folder.items) { kept($0, in: space, depth: depth + 1) } }
            })
        }
    }

    // MARK: - the foot

    /// What the foot's spaces leave its two buttons, their gaps and its insets.
    private var footEnds: CGFloat {
        typealias M = Metrics.Tablet
        return M.downloadsDoor + M.door + 2 * M.footGap + 2 * M.footInset
    }

    /// The Mac's foot: downloads, the spaces in the middle (the one in front
    /// in its color, the rest dimmed), and +.
    private var footer: some View {
        HStack(spacing: Metrics.Tablet.footGap) {
            TabletDownloadsButton(active: shown, id: "tablet.downloads.sidebar")
            ScrollViewReader { scroll in
                ScrollView(.horizontal) {
                    HStack(spacing: Metrics.Tablet.footGap) {
                        ForEach(app.browser.spaces.filter { !$0.isPrivate }) { item in spaceButton(item).id(item.id) }
                    }
                    .frame(minWidth: max(0, width - footEnds))
                }
                .scrollIndicators(.hidden)
                .onChange(of: space.id, initial: true) { _, id in Motion.space.run { scroll.scrollTo(id, anchor: .center) } }
            }
            TabletNewTabMenu(id: "tablet.sidebar.newTab", spaces: { browseSpaces = true })
                .popover(isPresented: $browseSpaces) {
                    SpacePagesCard(content: NewTabContent.make(for: app), width: Metrics.Workspace.sidebar,
                                   maxHeight: TabletWorkspaceGeometry.sheetHeight, fullness: 1,
                                   headerInset: SpacePagesCard.capsuleTop)
                        .environment(app).presentationCompactAdaptation(.popover)
                }
        }
        .foregroundStyle(Ink.primary)
        .padding(.horizontal, Metrics.Tablet.footInset).padding(.vertical, Metrics.Tablet.footInset)
        .background(alignment: .top) { Rectangle().fill(Ink.primary.opacity(0.1)).frame(height: 0.5) }
        .onChange(of: app.browser.tab?.id) { _, _ in browseSpaces = false }
        .onChange(of: app.surfaces.chat) { _, _ in browseSpaces = false }
        .onChange(of: app.surfaces.settings) { _, shown in if shown { browseSpaces = false } }
    }

    private func spaceButton(_ item: Space) -> some View {
        let current = item.id == space.id
        return Button { show(item) } label: {
            Group {
                if item.emoji.isEmpty { Image(systemName: "circle.fill").font(.system(size: Metrics.Tablet.footDot)) }
                else { Text(item.emoji).font(.system(size: Metrics.Tablet.footEmoji)) }
            }
            .saturation(current ? 1 : 0)
            .opacity(current ? 1 : Metrics.Tablet.dimmedSpace)
            .frame(width: Metrics.Tablet.door, height: Metrics.Tablet.door)
            .background(current ? Ink.tabletSpaceFront : .clear,
                        in: RoundedRectangle(cornerRadius: Metrics.Tablet.doorRadius, style: .continuous))
            .tabletHover()
            .frame(width: Metrics.touch, height: Metrics.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(item.name)
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityIdentifier("tablet.space.\(item.id)")
    }
}
