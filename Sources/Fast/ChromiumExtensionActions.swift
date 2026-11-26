import AppKit
import Combine
import SwiftUI
import YabCoreClient

/// The pinned buttons of a Chromium tab's extensions, drawn by Yab's own
/// column (PlatePin) from Chrome's live action state: the extension's icon,
/// its badge and title on that tab, and whether it is on there.
/// Chrome keeps that state per native tab; YabCore reads it from the
/// extension's worker (`ext.actions.state`) and says when it changed
/// (`ext.actions.changed`). Popups are hosted by the core track.
@MainActor
final class ChromiumColumn: ObservableObject {
    static let shared = ChromiumColumn()

    /// One extension's action on one page, as Chromium has it.
    struct Native: Equatable {
        var title = ""
        var badge = ""
        /// The extension shows a blocked-request count Chrome keeps from it.
        var countHidden = false
        var enabled = true
        var popup = false
        /// A dynamic icon the extension set, PNG; nil keeps its own.
        var icon: Data?
        /// That icon is for every tab, not this one's own.
        var iconEverywhere = false
        var nativeTab: Int?
        var error: String?

        /// Nil for a row that is not this extension's or not an action.
        nonisolated static func parse(_ row: JSONValue, id: String) -> Native? {
            guard row["id"].string == id else { return nil }
            if let error = row["error"].string { return Native(error: error) }
            guard row["action"] == .bool(true) else { return nil }
            var value = Native()
            value.title = String((row["title"].string ?? "").prefix(200))
            // Chrome keeps badges short; a long one is not a badge.
            let badge = row["badge"].string ?? ""
            value.badge = badge.count <= 6 ? badge : String(badge.prefix(4))
            value.countHidden = row["countHidden"] == .bool(true)
            value.enabled = row["enabled"] != .bool(false)
            value.popup = row["popup"] == .bool(true)
            value.nativeTab = row["tabId"].number.map { Int($0) }
            if let url = row["icon"].string, url.hasPrefix("data:image/png;base64,"), url.count < 220_000 {
                value.icon = Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count)))
            }
            value.iconEverywhere = row["iconEverywhere"] == .bool(true)
            return value
        }
    }

    /// By page (its YabCore tab) and extension.
    @Published private(set) var states: [String: [String: Native]] = [:]
    private struct Watched {
        weak var tab: Tab?
        let profile: String
        /// Requested actions, independent of the results Chrome returned.
        let actions: [String]
    }
    private var watched: [String: Watched] = [:]
    private var reading: [String: Task<Void, Never>] = [:]
    /// The last failed read by page, for the bench (a page that cannot be read keeps the extension's own icon).
    private var failures: [String: String] = [:]
    private var again: Set<String> = []
    private var lists: [String: AnyCancellable] = [:]
    private var listedAt: [String: Date] = [:]
    private var listing: Set<String> = []
    /// The last failed list read by profile, for the bench.
    private var listErrors: [String: String] = [:]
    private var images: [Data: NSImage] = [:]
    /// The icon each extension last set for every tab, by profile. Chrome
    /// keeps it past the worker's sleep and has no getter for it, and the
    /// worker's record goes with the worker, so a read after that finds none.
    private var everywhereIcons: [String: [String: Data]] = [:]

    /// The profile's extensions a Chromium tab's column draws: its page's,
    /// or, while the tab has no page (asleep, or brought back from last
    /// time and not looked at yet), the same profile's, found without
    /// building a page or reading anything. Nil for a WebKit tab. A private
    /// tab's is its space's, when "Allow in private tabs" is on and its page
    /// is that space profile's private side (ChromiumPrivateProfiles); its
    /// buttons are only the extensions Chrome lets run there.
    func native(for tab: Tab) -> ChromiumExtensions? {
        guard tab.engineKind == .chromium else { return nil }
        if Self.isPrivate(tab) {
            guard ChromiumPrivateProfiles.extensionsAllowed, let page = tab.builtPage as? ChromiumPage,
                  let space = ChromiumPrivateProfiles.space(of: page.profile) else { return nil }
            return ChromiumExtensions.shared(profile: space.profile, store: space.store)
        }
        if let page = tab.builtPage as? ChromiumPage { return page.extensions }
        guard tab.builtPage == nil else { return nil }
        return ChromiumExtensions.existing(in: tab.pageStore, profile: tab.siteEngineProfile)
    }

    static func isPrivate(_ tab: Tab) -> Bool { tab.shy || !tab.pageStore.isPersistent }

    /// The profile a new Chromium tab in `space` runs, for a plate with no
    /// tab in front: one already read for the space's store, never made or
    /// read for this. A private window's only with "Allow in private tabs".
    func native(space: UUID, privately: Bool) -> ChromiumExtensions? {
        guard !privately || ChromiumPrivateProfiles.extensionsAllowed, let store = Spaces.madeStore(for: space) else { return nil }
        return ChromiumExtensions.existing(in: store)
    }

    /// The list's rows a tab can use: in a private tab, those allowed there.
    func items(_ native: ChromiumExtensions, for tab: Tab) -> [ChromiumExtensions.Item] {
        items(native, privately: Self.isPrivate(tab))
    }

    func items(_ native: ChromiumExtensions, privately: Bool) -> [ChromiumExtensions.Item] {
        privately ? native.items.filter(\.incognito) : native.items
    }

    /// Which buttons a profile's list makes: its pins in pin order, then
    /// with `all` every other one that is on. Whatever a page has or hasn't
    /// said yet changes none of them; only how each looks.
    static func members(_ items: [ChromiumExtensions.Item], pinnedIDs: [String], all: Bool) -> (pinned: [ChromiumExtensions.Item], rest: [ChromiumExtensions.Item]) {
        let shown = { (item: ChromiumExtensions.Item) in item.enabled || ApplePasswordExtensionRoute.offersButton(item.id) }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pinned = pinnedIDs.compactMap { byID[$0] }.filter(shown)
        let pins = Set(pinnedIDs)
        return (pinned, all ? items.filter { shown($0) && !pins.contains($0.id) } : [])
    }

    /// The tab's pinned buttons, in pin order; with `all`, then every other
    /// enabled one (Site Controls' list). Nothing for a WebKit tab.
    /// Which buttons, and in what order, is the profile's: the same before
    /// the tab's page has its native tab, or a page at all, as after. Only
    /// the icon, badge, title and whether it is on here wait for the page.
    @available(macOS 15.4, *)
    func buttons(for tab: Tab, all: Bool = false) -> [Extensions.Button] {
        guard let native = native(for: tab) else { return [] }
        follow(native)
        var here: [String: Native] = [:]
        if let page = tab.builtPage as? ChromiumPage, let remote = page.remoteID,
           let core = ChromiumProcess.shared.connectedClient {
            refresh(native, connectedTo: core)
            watch(tab, remote: remote, profile: native.profile, actions: Self.actionIDs(items(native, for: tab), pinnedIDs: native.pinnedIDs))
            here = states[remote] ?? [:]
        }
        return buttons(native, items: items(native, for: tab), here: here, all: all)
    }

    /// The pinned buttons of a profile with no page to say how each looks:
    /// a plate with no tab in front.
    @available(macOS 15.4, *)
    func buttons(_ native: ChromiumExtensions, privately: Bool) -> [Extensions.Button] {
        follow(native)
        return buttons(native, items: items(native, privately: privately), here: [:], all: false)
    }

    @available(macOS 15.4, *)
    private func buttons(_ native: ChromiumExtensions, items: [ChromiumExtensions.Item], here: [String: Native], all: Bool) -> [Extensions.Button] {
        let (pinned, rest) = Self.members(items, pinnedIDs: native.pinnedIDs, all: all)
        let pins = Set(pinned.map(\.id))
        return (pinned + rest).map { item in
            let state = here[item.id]
            let title = state?.title ?? ""
            return Extensions.Button(
                id: item.id, name: item.name,
                label: ExtensionTip.label(action: title.isEmpty ? item.name : title, name: item.name, displayName: item.name, shortName: ""),
                icon: ExtensionIconShape.rounded(image(state?.icon ?? item.iconData)),
                badge: state?.badge ?? "", enabled: ApplePasswordExtensionRoute.offersButton(item.id) || (state?.enabled ?? true), pinned: pins.contains(item.id),
                // The key Chrome gave its button's command, for its tip, as a WebKit button's.
                keys: item.commands.first { $0.action && !ExtensionCommands.off(item.id, $0.name) }?.hotkey
                    .flatMap { ExtensionCommands.routes($0) ? $0.text : nil })
        }
    }

    /// The pins `buttons` draws, without building a page or reading the
    /// helper: the room the column keeps for them is always the row's own.
    /// A parked plate must carry different equal-height native pin sets too.
    func pinnedIDs(for tab: Tab) -> [String] {
        guard let native = native(for: tab) else { return [] }
        return pinnedIDs(native, privately: Self.isPrivate(tab))
    }

    func pinnedIDs(_ native: ChromiumExtensions, privately: Bool) -> [String] {
        Self.members(items(native, privately: privately), pinnedIDs: native.pinnedIDs, all: false).pinned.map(\.id)
    }

    /// How many the column keeps room for, without reading anything.
    func pinnedCount(for tab: Tab) -> Int { pinnedIDs(for: tab).count }

    /// Open the extension's own action popup for this native page window.
    /// `list`: the sliders' list it was pressed in, for its popup to take over.
    func press(_ id: String, tab: Tab, list: NSPopover? = nil) {
        if ApplePasswordExtensionRoute.matches(id) {
            list?.close()
            ApplePasswordExtensionRoute.intercept(id, browser: tab.delegate as? Browser)
            return
        }
        guard tab.engineKind == .chromium, let page = tab.builtPage as? ChromiumPage, let native = native(for: tab),
              let item = items(native, for: tab).first(where: { $0.id == id }) else { return }
        popupTrace("press \(id.prefix(6))")
        if ChromiumPopupHost.shared.toggleClosed(page: page, extensionID: id) { list?.close(); return }
        let pressedInList = list != nil
        // The button is drawn before the page has its native tab; until it
        // has, nothing is known of a popup.
        let knownPopup = page.remoteID.flatMap { states[$0]?[id]?.popup }
        ChromiumPopupHost.shared.expect(id, page: page, list: list, knownPopup: knownPopup)
        Task { @MainActor in
            // Chrome's own action click on this exact page: a popup, or
            // onClicked with activeTab granted for this tab, as in Chromium.
            // First, since asking about a side panel builds a page for it.
            // It waits for the page's native tab.
            if await page.openExtensionAction(id) { popupTrace("action taken \(id.prefix(6))"); return }
            if pressedInList { ChromiumPopupHost.shared.dropList() }
            // Chrome leaves a side panel to its button's owner, and would
            // show it in a window Yab hides.
            if #available(macOS 15.4, *), await ChromiumSidePanel.shared.press(id, from: tab) { return }
            guard let remote = page.remoteID else { return }
            do {
                _ = try await ChromiumDRMExtensionSession.actions(of: tab).request("ext.actions.openPopup", ["page": remote, "extension": id])
            } catch { native.failure = "\(item.name): \(error.localizedDescription)" }
        }
    }

    private func image(_ data: Data?) -> NSImage? {
        guard let data else { return nil }
        if let known = images[data] { return known }
        guard let made = NSImage(data: data) else { return nil }
        if images.count > 256 { images.removeAll() }
        images[data] = made
        return made
    }

    private func follow(_ native: ChromiumExtensions) {
        let key = (native.privateMode ? "private:" : "regular:") + native.profile
        guard lists[key] == nil else { return }
        lists[key] = native.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    /// The column draws from the list: read it when nothing has, and again
    /// now and then, since Chrome can install or remove behind Yab's back
    /// and a first read can fail while the helper is starting.
    private func refresh(_ native: ChromiumExtensions, connectedTo core: YabCoreClient) {
        let key = (native.privateMode ? "private:" : "regular:") + native.profile
        let stale = Date().timeIntervalSince(listedAt[key] ?? .distantPast) > (native.items.isEmpty ? 1.5 : 8)
        guard stale, !listing.contains(key) else { return }
        listing.insert(key)
        listedAt[key] = Date()
        Task { @MainActor [weak self] in
            // A passive read must not wake a helper after its page crashed.
            do { _ = try await native.list(connectedTo: core); self?.listErrors[key] = nil }
            catch { self?.listErrors[key] = String(describing: error) }
            self?.listing.remove(key)
        }
    }

    /// Native toolbar routes (Apple Passwords) are drawn alongside Chromium
    /// actions, but have no extension worker or action state to read.
    static func actionIDs(_ items: [ChromiumExtensions.Item], pinnedIDs: [String]) -> [String] {
        let native = Set(items.filter { $0.enabled && !ApplePasswordExtensionRoute.matches($0.id) }.map(\.id))
        return pinnedIDs.filter(native.contains)
    }

    private func watch(_ tab: Tab, remote: String, profile: String, actions: [String]) {
        let changed = watched[remote]?.actions != actions
        watched[remote] = Watched(tab: tab, profile: profile, actions: actions)
        guard changed || watched.count > 8 else { return }
        // A read belongs to a changed request, not to missing result rows.
        // Chrome may return no action for an extension; an empty answer is
        // still an answer. Drawing it must not schedule the same read again.
        DispatchQueue.main.async {
            for (key, value) in self.watched where value.tab == nil || value.tab?.gone == true {
                self.watched[key] = nil; self.states[key] = nil
            }
            if changed { self.read(remote) }
        }
    }

    /// Read again, at most one at a time per page; a change meanwhile reads once more.
    func read(_ remote: String) {
        guard let entry = watched[remote], let tab = entry.tab, !tab.gone,
              let page = tab.builtPage as? ChromiumPage, page.remoteID == remote,
              let core = ChromiumProcess.shared.connectedClient else {
            watched[remote] = nil; states[remote] = nil; return
        }
        if reading[remote] != nil { again.insert(remote); return }
        guard let native = native(for: tab) else { states[remote] = [:]; return }
        let ids = Self.actionIDs(items(native, for: tab), pinnedIDs: native.pinnedIDs)
        guard !ids.isEmpty else { states[remote] = [:]; return }
        reading[remote] = Task { @MainActor [weak self] in
            defer {
                self?.reading[remote] = nil
                if self?.again.remove(remote) != nil { self?.read(remote) }
            }
            do {
                let result = try await ChromiumDRMExtensionSession.actions(of: tab).request("ext.actions.state", ["page": remote, "extensions": ids], connectedTo: core)
                guard case .array(let rows) = result["actions"] else { self?.failures[remote] = "No actions array in the answer"; return }
                var next: [String: Native] = [:]
                for id in ids {
                    guard let row = rows.first(where: { $0["id"].string == id }), var state = Native.parse(row, id: id) else { continue }
                    if state.iconEverywhere { self?.everywhereIcons[entry.profile, default: [:]][id] = state.icon }
                    else if state.icon == nil { state.icon = self?.everywhereIcons[entry.profile]?[id] }
                    next[id] = state
                }
                self?.failures[remote] = nil
                if self?.states[remote] != next { self?.states[remote] = next }
            } catch {
                // A page that cannot be read keeps the extension's own icon.
                self?.failures[remote] = String(describing: error)
                if self?.states[remote] == nil { self?.states[remote] = [:] }
            }
        }
    }

    /// `ext.actions.changed` from a profile's control tab.
    static func receive(_ event: YabCoreEvent) -> Bool {
        guard event.name == "ext.actions.changed" else { return false }
        guard let profile = event.params["profile"]?.string, let id = event.params["extension"]?.string,
              ChromiumExtensions.validID(id) else { return true }
        let column = shared
        // A worker that just started may still be running the listener that
        // sets its badge; read again once it has had a moment.
        let restarted = event.params["reason"]?.string == "worker"
        for (remote, entry) in column.watched where entry.profile == profile {
            guard let tab = entry.tab, tab.builtPage is ChromiumPage, column.native(for: tab)?.pinnedIDs.contains(id) == true else { continue }
            column.read(remote)
            if restarted { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { column.read(remote) } }
        }
        return true
    }
}

@MainActor
extension ChromiumExtensions {
    /// Pin or unpin in the column; kept beside the import's pin order.
    func setPinned(_ id: String, _ pinned: Bool) throws {
        guard Self.validID(id) else { throw YabCoreError.remote("A Chrome extension ID is required") }
        if #available(macOS 15.4, *), let list = oneList, list.installed.contains(where: { $0.id == id }) {
            list.setPinned(id, pinned)
            return
        }
        var state = try migration()
        state.pins.removeAll { $0 == id }
        if pinned { state.pins.append(id) }
        try saveMigration(state)
    }

    /// A password manager comes in pinned, the first time, as on WebKit.
    func pinOnArrival(_ id: String) {
        if #available(macOS 15.4, *), oneList != nil { return }
        guard var state = try? migration(), Extensions.passwordManagers.contains(id),
              !(state.arrived ?? []).contains(id) else { return }
        state.arrived = (state.arrived ?? []).union([id])
        if !state.pins.contains(id) { state.pins.insert(id, at: 0) }
        try? saveMigration(state)
    }
}

/// What a right-click on a Chromium tab's pinned extension offers, the
/// WebKit button's lines (ExtensionActions) over the native profile.
struct ChromiumPinActions: View {
    let id: String
    let name: String
    let tab: Tab

    private var native: ChromiumExtensions? { ChromiumColumn.shared.native(for: tab) }

    var body: some View {
        if let native {
            // The extension's own rows first, as under its name in Chrome's
            // menu (CEF patch 0124; read ahead, ChromiumActionMenu).
            let own = ChromiumActionMenu.shared.rows(id, tab: tab)
            if !own.isEmpty {
                ChromiumActionMenuRows(id: id, tab: tab, rows: own)
                Divider()
            }
            let pinned = native.pinnedIDs.contains(id)
            SwiftUI.Button(pinned ? "Unpin" : "Pin", mark: "pin") { try? native.setPinned(id, !pinned) }
            if let url = native.items.first(where: { $0.id == id })?.optionsURL {
                SwiftUI.Button("Options…", mark: "gearshape") {
                    (tab.delegate as? Browser)?.open(url, foreground: true)
                }
            }
            Divider()
            SwiftUI.Button("Remove from Yab…", mark: "trash") {
                native.perform {
                    guard try await native.reviewRemoval(id, name: name, place: .plain) else { return }
                    try? native.setPinned(id, false)
                }
            }
        }
    }
}

extension ChromiumColumn {
    /// The bench's view of a Chromium tab's column: the buttons as drawn,
    /// Chrome's raw action state, and the pin order. `pin` pins or unpins
    /// first; `read` asks for a fresh read.
    @available(macOS 15.4, *)
    static func benchState(tab: Tab, page: ChromiumPage, pin: String?, pinned: Bool, read: Bool) -> [String: Any] {
        var failure: String?
        let column = shared
        // A private tab's list is its space's (native(for:)), when it has one.
        let list = column.native(for: tab) ?? page.extensions
        if let pin {
            do { try list.setPinned(pin, pinned) } catch { failure = error.localizedDescription }
        }
        let buttons = column.buttons(for: tab)
        if read, let remote = page.remoteID { column.read(remote) }
        let states = page.remoteID.flatMap { column.states[$0] } ?? [:]
        var out: [String: Any] = [
            "pins": list.pinnedIDs,
            "items": list.items.map { ["id": $0.id, "name": $0.name, "state": $0.state, "incognito": $0.incognito] },
            "private": isPrivate(tab),
            "space": ChromiumPrivateProfiles.space(of: page.profile)?.profile ?? "",
            "buttons": buttons.map { button -> [String: Any] in
                ["id": button.id, "label": button.label, "badge": button.badge, "enabled": button.enabled,
                 "icon": button.icon.map { [$0.size.width, $0.size.height] } ?? [], "tint": ExtensionOneList.tint(button.icon)]
            },
            "native": states.mapValues { state -> [String: Any] in
                ["title": state.title, "badge": state.badge, "countHidden": state.countHidden, "enabled": state.enabled,
                 "popup": state.popup, "dynamicIcon": state.icon?.count ?? 0, "iconTint": ExtensionOneList.tint(state.icon.flatMap(NSImage.init(data:))),
                 "nativeTab": state.nativeTab ?? -1,
                 "error": state.error ?? ""]
            },
            "reading": page.remoteID.map { column.reading[$0] != nil } ?? false,
            "readFailure": page.remoteID.flatMap { column.failures[$0] } ?? "",
            "watching": page.remoteID.map { column.watched[$0] != nil } ?? false,
            "enabledItems": list.items.filter(\.enabled).map(\.id),
            "failure": list.failure ?? "",
            "listError": column.listErrors[(list.privateMode ? "private:" : "regular:") + list.profile] ?? "",
        ]
        // What the store install shows: the corner offer and Yab's question.
        if let up = Questions.shared.current {
            out["question"] = ["title": up.title, "detail": up.detail, "folded": up.folded, "lines": up.lines, "yes": up.yes] as [String: Any]
        }
        if let toaster = (tab.delegate as? Browser)?.toaster, toaster.shown {
            out["toast"] = ["words": toaster.words, "act": toaster.act ?? ""]
        }
        if let failure { out["error"] = failure }
        if let failed = page.extensions.failure { out["extensionsFailure"] = failed }
        return out
    }
}
