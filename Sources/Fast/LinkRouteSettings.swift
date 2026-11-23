import SwiftUI

/// Settings › Spaces, under the spaces: the sites whose links from other
/// apps, and those a page opens in a new tab, always open in one space (LinkRoutes.swift), including words and
/// address patterns, in the table language
/// of Search's sites and the hotkeys: the site bare, its space in a
/// MenuCell, Remove on a right click, Add Site… in the heading; a click on
/// a rule opens its card to change or remove it. A list that
/// belongs to spaces, so a group on their page and not a page of its own.
struct LinkRouteSettings: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var routes = LinkRoutes.shared
    @ObservedObject private var editing = LinkRouteEditing.shared

    var body: some View {
        let spaces = browser.spaces
        let suggestion = routes.suggestion(in: spaces)
        Section {
            SettingsRow("Default Space", detail: "When no rule matches") {
                MenuCell(title: "Default Space", options: [(title: SettingsWords.text("No default space"), value: UUID?.none)]
                    + LinkRouteEditing.choices(spaces).map { (title: $0.title, value: Optional($0.value)) },
                    selection: Binding(get: { routes.defaultSpace }, set: { routes.setDefaultSpace($0) }), trailing: true)
            }
            .settingsAnchor("link-routes-default")
            SettingsSwitch("Use manual rule priority", isOn: $routes.manualPriority)
                .settingsAnchor("link-routes-manual")
            if !routes.routes.isEmpty {
                LinkRouteList(items: routes.displayedRoutes, spaces: spaces, manual: routes.manualPriority, move: { routes.move($0, to: $1) })
                    // The form's inset round a cell traded for the
                    // list's own air, as the spaces' list does.
                    .padding(.vertical, SettingsList.air - 10) // design: the form's own inset round a cell, traded for the list's air
            }
            if let suggestion, let space = spaces.first(where: { $0.id == suggestion.space }) {
                LinkRouteSuggestion(suggestion: suggestion, space: space)
            }
            if routes.routes.isEmpty, suggestion == nil {
                Text("No rules yet")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 8) {
                Text("Air Traffic Control")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Site…") { editing.open(spaces: spaces, space: browser.spaceID) }
                    .settingsButton()
            }
            .textCase(nil)
            .settingsAnchor("link-routes")
        } footer: {
            if routes.manualPriority {
                SettingsNote("The first matching rule wins. Drag to reorder. Rules override the default.")
            } else {
                SettingsNote("Rules override the default. Recent space uses the space open when a link arrives. Click a rule to edit or remove it.")
            }
        }
    }
}

private struct LinkRouteList: View {
    let items: [LinkRoute]
    let spaces: [Space]
    let manual: Bool
    let move: (String, Int) -> Void
    @State private var lifted: String?
    @State private var lift: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, route in
                LinkRouteRow(route: route, spaces: spaces,
                             lifted: lifted == route.id, rule: index > 0 && lifted != route.id,
                             grip: manual && items.count > 1 ? reorder(route) : nil,
                             moveUp: manual && index > 0 ? { move(route.id, index - 1) } : nil,
                             moveDown: manual && index < items.count - 1 ? { move(route.id, index + 1) } : nil)
                    .settingsAnchor("link-route:" + route.site)
                    .offset(y: shift(index))
                    .zIndex(lifted == route.id ? 1 : 0)
                    .animation(lifted == nil || lifted == route.id ? nil : Motion.settle, value: shift(index))
            }
        }
        .onDisappear {
            if lifted != nil { NSCursor.pop() }
            lifted = nil
            lift = 0
        }
    }

    private func landing(_ from: Int) -> Int {
        min(items.count - 1, max(0, from + Int((lift / SettingsList.row).rounded())))
    }

    private func shift(_ index: Int) -> CGFloat {
        guard let lifted, let from = items.firstIndex(where: { $0.id == lifted }) else { return 0 }
        if index == from { return lift }
        let to = landing(from)
        if from < to, index > from, index <= to { return -SettingsList.row }
        if from > to, index < from, index >= to { return SettingsList.row }
        return 0
    }

    private func reorder(_ route: LinkRoute) -> AnyGesture<Void> {
        AnyGesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { drag in
                if lifted != route.id { NSCursor.closedHand.push() }
                lifted = route.id
                lift = drag.translation.height
            }
            .onEnded { _ in
                if lifted != nil { NSCursor.pop() }
                guard lifted == route.id, let from = items.firstIndex(where: { $0.id == route.id }) else {
                    lifted = nil
                    lift = 0
                    return
                }
                let to = landing(from)
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    move(route.id, to)
                    lifted = nil
                    lift = 0
                }
            }
            .map { _ in () })
    }
}

/// One rule: the site's icon, or a search mark for an address pattern, its scope,
/// and the space its links go to.
private struct LinkRouteRow: View {
    static let handleWidth: CGFloat = 14
    static let spacing: CGFloat = 8

    let route: LinkRoute
    let spaces: [Space]
    let lifted: Bool
    let rule: Bool
    let grip: AnyGesture<Void>?
    let moveUp: (() -> Void)?
    let moveDown: (() -> Void)?

    var body: some View {
        HStack(spacing: Self.spacing) {
            handle
            Button(action: edit) {
                HStack(spacing: 8) {
                    if route.pattern {
                        Symbol("magnifyingglass", size: 12)
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    } else {
                        HostMark(host: route.host, size: 22)
                    }
                    Text(route.site)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if route.pattern {
                        Text("URL contains")
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else if !route.path.isEmpty {
                        Text("Exact URL")
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edits the rule for \(route.site)")
            MenuCell(title: "Opens in", options: LinkRouteEditing.choices(spaces), selection: Binding(
                get: { route.space },
                set: { LinkRoutes.shared.set(route.site, to: $0) }
            ), trailing: true)
        }
        .frame(height: SettingsList.row)
        .contentShape(Rectangle())
        .background {
            if lifted {
                let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                shape.fill(Color(nsColor: .controlBackgroundColor)) // design: a row lifted in the hand, as the tray's is, not a card
                    .castShadow(shape, color: .black.opacity(0.14), radius: 8, y: 3)
                    .padding(.horizontal, -6)
            }
        }
        .overlay(alignment: .top) {
            if rule {
                Divider()
                    .padding(.leading, Self.handleWidth + Self.spacing)
                    .offset(y: -0.5)
            }
        }
        .contextMenu {
            Button("Edit…", action: edit)
            Divider()
            Button("Remove") { LinkRoutes.shared.remove(route.site) }
        }
    }

    @ViewBuilder
    private var handle: some View {
        let dots = Symbol("circle.grid.2x3", size: 11)
            .foregroundStyle(.tertiary)
            .frame(width: Self.handleWidth, height: SettingsList.row)
            .contentShape(Rectangle())
        if let grip {
            dots
                .onHover { inside in
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .highPriorityGesture(grip)
                .keyTip("Drag to change its place")
                .accessibilityLabel("Reorder \(route.site)")
                .accessibilityActions {
                    if let moveUp { Button("Move Up", action: moveUp) }
                    if let moveDown { Button("Move Down", action: moveDown) }
                }
        } else {
            dots.hidden()
        }
    }

    private func edit() {
        LinkRouteEditing.shared.open(spaces: spaces, space: route.space, site: route.site)
    }
}

/// The one site the small window has kept into one space three times this
/// week, offered as a row of its own, gray until it is added.
private struct LinkRouteSuggestion: View {
    let suggestion: LinkRoutes.Suggestion
    let space: Space

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                HostMark(host: suggestion.site, size: 22)
                    .opacity(0.6)
                Text(suggestion.site)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("opened in \(space.name) \(suggestion.times) times this week")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Add") { LinkRoutes.shared.set(suggestion.site, to: suggestion.space) }
                .settingsButton()
            Button { LinkRoutes.shared.decline(suggestion.site) } label: { Symbol("xmark", size: 11) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyTip("Don't suggest this")
                .accessibilityLabel("Don't suggest \(suggestion.site)")
        }
    }
}

/// The site's icon when it has been seen, its letter until then.
struct HostMark: View {
    let host: String
    var size: CGFloat = 16
    @State private var icon: NSImage?

    var body: some View {
        Mark(icon: icon, letter: host.first.map { String($0).uppercased() } ?? "•", size: size)
            .onAppear {
                icon = Favicons.shared.cached(host)
                guard icon == nil else { return }
                Favicons.shared.fetch(host: host)
                // In a moment, once it has come.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { icon = Favicons.shared.cached(host) }
            }
    }
}

/// Add Site…'s card, over the whole of the settings as Search's is, and
/// the same card for a rule clicked, with its text to change.
@MainActor
final class LinkRouteEditing: ObservableObject {
    static let shared = LinkRouteEditing()

    struct Draft: Identifiable {
        let id = UUID()
        let spaces: [Space]
        let space: UUID
        /// The rule being changed, nil for a new one.
        var site: String?
        var opensInMain: Bool = false
    }

    @Published private(set) var draft: Draft?

    func open(spaces: [Space], space: UUID, site: String? = nil) {
        draft = Draft(spaces: spaces, space: space, site: site,
                      opensInMain: site.flatMap { LinkRoutes.shared.route(site: $0)?.opensInMain } == true)
    }
    func close() { draft = nil }

    /// The editor's Save, for new rules and renamed ones alike. Window
    /// choice remains the existing optional flag; false retains nil.
    func save(site: String, to space: UUID, opensInMain: Bool) {
        if let old = draft?.site {
            LinkRoutes.shared.replace(old, with: site, to: space)
        } else {
            LinkRoutes.shared.set(site, to: space)
        }
        LinkRoutes.shared.setMainWindow(site, enabled: opensInMain)
    }

    /// Each space as its menu line: its emoji, then its name.
    static func choices(_ spaces: [Space]) -> [(title: String, value: UUID)] {
        [(title: SettingsWords.text("Recent space"), value: LinkRoutes.recentSpaceID)]
            + spaces.map { (title: $0.marked("  "), value: $0.id) }
    }
}

struct LinkRouteCardLayer: View {
    @ObservedObject private var editing = LinkRouteEditing.shared

    var body: some View {
        ZStack {
            if let draft = editing.draft {
                LinkRouteCard(draft: draft) { editing.close() }
                    .frame(width: 440)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.97).combined(with: .opacity).animation(Motion.arrive),
                        removal: .identity
                    ))
                    .id(draft.id)
            }
        }
    }
}

/// The site, and the space its links go to. What the site will catch is
/// said under the title as it is typed: the whole site, only the pages
/// under a path, or a word or pattern anywhere in an address. A rule
/// changed is saved in the old one's place, and can be removed here.
private struct LinkRouteCard: View {
    let draft: LinkRouteEditing.Draft
    let done: () -> Void

    @State private var typed = ""
    @State private var space: UUID
    @State private var opensInMain: Bool
    @FocusState private var typing: Bool

    init(draft: LinkRouteEditing.Draft, done: @escaping () -> Void) {
        self.draft = draft
        self.done = done
        _space = State(initialValue: draft.space)
        _typed = State(initialValue: draft.site ?? "")
        _opensInMain = State(initialValue: draft.opensInMain)
    }

    private var site: String? { LinkRoutes.site(from: typed) }

    private var detail: String {
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Its links, from another app or opened in a new tab, open in the space you pick."
        }
        guard let site else { return "Needs to be a site, like linear.app, a page’s address, or a word." }
        let route = LinkRoute(site: site, space: space)
        if route.pattern {
            if !typed.contains("*") {
                return "Any link with “\(site.dropFirst().dropLast())” in its address."
            }
            if !site.contains("/"), !site.contains("?"), !site.hasSuffix("*") {
                return "Links that match \(site). Add * at the end to include pages."
            }
            return "Links that match \(site)."
        }
        return route.path.isEmpty ? "\(route.host) and every page on it." : "Only the pages under \(site)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: CardFrame.wellGap) {
                well
                VStack(alignment: .leading, spacing: 2) {
                    Text("Always open these links in a selected space")
                        .font(CardFrame.title)
                        .foregroundStyle(Palette.ink)
                    Text(detail)
                        .font(CardFrame.detail)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 6) {
                TextField("", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                    .focused($typing)
                    .modifier(CardField(hint: "linear.app, a page’s address, or a word", empty: typed.isEmpty, typing: typing))
                    .onSubmit(save)
                HStack(spacing: 8) {
                    Text("Opens in")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    MenuCell(title: "Opens in", options: LinkRouteEditing.choices(draft.spaces), selection: $space, trailing: true)
                }
                .padding(.leading, 10)
                .frame(height: 32)
                HStack(spacing: 8) {
                    Text("Window")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 8)
                    MenuCell(title: "Window", options: [
                        (title: "Follow Small Window setting", value: false),
                        (title: "Main window", value: true)
                    ], selection: $opensInMain, width: 240, trailing: true)
                }
                .padding(.leading, 10)
                .frame(height: 32)
                Text("Applies to links from other apps.")
                    .font(CardFrame.detail)
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
            }
            .padding(.top, 12)
            HStack(spacing: 6) {
                if let old = draft.site {
                    Button("Remove", role: .destructive) {
                        LinkRoutes.shared.remove(old)
                        done()
                    }
                    .buttonStyle(.yab(.quiet, CardFrame.button, tint: ButtonCSS.danger))
                    .fixedSize()
                }
                Spacer(minLength: 8)
                // Escape works here as on every card, and says so as theirs do.
                Button(action: done) {
                    HStack(spacing: 6) {
                        Text("Cancel")
                        KeyGlyphs(keys: "esc", size: CardFrame.words, tint: nil, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.secondary, CardFrame.button))
                .fixedSize()
                Button(action: save) {
                    HStack(spacing: 6) {
                        Text(draft.site == nil ? "Add" : "Save")
                        KeyGlyphs(keys: "↩", size: CardFrame.words, tint: nil, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.primary, CardFrame.button))
                .fixedSize()
                .disabled(site == nil)
                .allowsHitTesting(site != nil)
            }
            .padding(.top, CardFrame.buttonGap)
        }
        .cardFrame()
        .onExitCommand(perform: done)
        .onAppear { DispatchQueue.main.async { typing = true } }
    }

    private func save() {
        guard let site else { return }
        LinkRouteEditing.shared.save(site: site, to: space, opensInMain: opensInMain)
        done()
    }

    /// Plus for a new rule; a rule changed shows its own mark, as its row does.
    private var wellSymbol: String {
        guard draft.site != nil else { return "plus" }
        let pattern = site.map { LinkRoute(site: $0, space: space).pattern } ?? false
        return pattern ? "magnifyingglass" : "globe"
    }

    private var well: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return shape.fill(Palette.ink.opacity(0.05))
            .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
            .overlay { Symbol(wellSymbol, size: 16).foregroundStyle(Palette.ink) }
            .frame(width: CardFrame.well, height: CardFrame.well)
    }
}
