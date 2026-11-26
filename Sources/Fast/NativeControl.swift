import AppKit
import Combine

/// Production native operations. The transport has no setters of its own;
/// each effect runs here through the same models used by the visible UI.
@MainActor
final class NativeControl {
    static let shared = NativeControl(file: Store.file("native-operations.json"))
    let changes: NativeChanges
    private struct WindowWatch { weak var browser: Browser?; let cancellables: [AnyCancellable] }
    private var observed: [ObjectIdentifier: WindowWatch] = [:]
    private var observedTabs: Set<UUID> = []
    private var tabWatches: [UUID: [AnyCancellable]] = [:]
    private var pending: [String: () -> Void] = [:]
    private var moves: [String: SpaceMove] = [:]
    private var groups: [String: [UUID: (Bool, Nest?)]] = [:]
    /// The folders a folder change took out of where they were, and where
    /// that was, by operation (folder.ungroup).
    private var folderParents: [String: [(Nest, Nest?)]] = [:]
    private struct PinState {
        let order: [UUID]
        let pairs: [Pair]
        let pin: String?
        let kept: Bool
        let nest: Nest?
    }
    private var pins: [String: PinState] = [:]
    /// What tabs.close took away, by operation: the batch Recently Closed
    /// keeps them under, the row as it stood, and each tab's pin, folder,
    /// name and home, for Undo to put back.
    private struct Closing {
        let batch: UUID
        let space: UUID
        let order: [UUID]
        /// The loose tabs closed, by id, with the names they had.
        let closed: [(id: UUID, name: String?)]
        /// The pinned and kept ones put down, asleep where they stand, as ⌘W leaves them.
        let rested: [UUID]
    }
    private var closings: [String: Closing] = [:]
    /// The ⌘Z step each tabs.close left in its window, taken out once undone.
    private var closeSteps: [String: UUID] = [:]
    private var nestWatches: [UUID: [AnyCancellable]] = [:]
    private var mailOwners: [String: UUID] = [:]
    /// The folder a live.add or live.follow_repo made or found, by operation.
    private var liveMade: [String: UUID] = [:]
    private var zoomWatch: AnyCancellable?

    init(file: URL) {
        changes = NativeChanges(file: file)
        zoomWatch = NotificationCenter.default.publisher(for: PageAppearance.siteZoomChanged).sink { [weak self] note in
            MainActor.assumeIsolated {
                if let host = note.object as? String { self?.changes.changed(Self.zoomResource(host) + ":edits") }
            }
        }
    }
    func latestUndoable(in browser: Browser) -> String? {
        changes.receipts.last { $0.status == "verified" && !$0.undone && $0.version != nil && $0.window == windowID(browser) }?.id
    }

    private func windowID(_ browser: Browser) -> String { (browser.windowID ?? BrowserWindows.primaryID).uuidString }

    /// Preferences are per window, while these values persist application-wide.
    /// Refresh from the saved model and distribute native edits to open windows.
    private func synchronizeApplication(_ browser: Browser) {
        let fonts = PageFonts.read()
        let mail = MailExperiment.enabled()
        for target in BrowserWindows.shared.browsers + [browser] {
            for setting in NativeSetting.all where setting.scope == "application" {
                if let saved = setting.saved, setting.read(target.prefs) != saved { try? setting.write(target.prefs, saved) }
            }
            if target.prefs.pageFonts != fonts { target.prefs.pageFonts = fonts }
            if target.prefs.usesMail != mail { target.prefs.usesMail = mail }
        }
    }

    static func writable(_ session: Agents.Session, nobody: Bool? = nil) -> Bool {
        !(nobody ?? Headless.nobody) && session.state.live && !session.textOnly && !session.unattended && !session.remembering && session.parent == nil
            && session.profile != "context_explorer" && session.profile != "code_explorer"
    }

    func handle(_ verb: String, request: [String: Any], browser suppliedBrowser: Browser, answer: @escaping ([String: Any]) -> Void) {
        do {
            guard let id = request["session"] as? String, let session = Agents.shared.session(id), session.state.live else {
                throw NativeFailure("session_required", "Native tools require a live registered task")
            }
            let browser: Browser
            if let origin = session.nativeWindowID, origin.uuidString != windowID(suppliedBrowser) {
                guard let original = BrowserWindows.shared.browsers.first(where: { windowID($0) == origin.uuidString }) else {
                    throw NativeFailure("conflict", "The task's original browser window is closed")
                }
                browser = original
            } else { browser = suppliedBrowser }
            for open in BrowserWindows.shared.browsers + [browser] { observe(open) }
            synchronizeApplication(browser)
            switch verb {
            case "agent-native-context": answer(try context(request, browser: browser, session: session))
            case "agent-native-actions":
                let query = (request["query"] as? String ?? "").lowercased()
                let descriptors = NativeActions.descriptors.filter { query.isEmpty || "\($0["id"] ?? "") \($0["title"] ?? "")".lowercased().contains(query) }
                answer(["catalogVersion": NativeActions.version, "actions": descriptors, "canWrite": Self.writable(session)])
            case "agent-native-apply":
                guard Self.writable(session) else { throw NativeFailure("read_only", "This task may read native state but cannot change Yab") }
                answer(try apply(request, browser: browser, session: session))
            case "agent-native-operation":
                let operation = request["operationId"] as? String ?? ""
                guard let receipt = changes.receipt(operation, session: id) else { throw NativeFailure("not_found", "No such operation for this task") }
                if request["cancel"] as? Bool == true {
                    guard Self.writable(session) else { throw NativeFailure("read_only", "This task cannot cancel operations") }
                    cancel(receipt, browser: browser)
                }
                let seconds = min(10, max(0, request["seconds"] as? Double ?? 0))
                let previous = changes.receipt(operation, session: id)?.status
                Task { @MainActor in
                    let until = Date().addingTimeInterval(seconds)
                    while Date() < until, session.state.live,
                          changes.receipt(operation, session: id)?.status == previous,
                          ["running", "needs_user"].contains(previous ?? "") {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    answer(changes.receipt(operation, session: id)?.result?.any as? [String: Any] ?? ["status": "unknown_outcome"])
                }
            case "agent-native-undo":
                guard Self.writable(session) else { throw NativeFailure("read_only", "This task cannot undo changes") }
                let id = request["changeId"] as? String ?? session.nativeUndoChange
                    ?? changes.receipts.last(where: { $0.session == session.id && $0.status == "verified" && !$0.undone && $0.version != nil })?.id ?? ""
                let owner = id == session.nativeUndoChange ? changes.receipts.last(where: { $0.id == id })?.session ?? session.id : session.id
                answer(try undo(id, session: owner, browser: browser))
                session.nativeUndoChange = nil
            default: throw NativeFailure("unsupported", "Unknown native operation")
            }
        } catch let error as NativeFailure { answer(error.reply) }
        catch { answer(NativeFailure("invalid_arguments", "The native request could not be read").reply) }
    }

    func forget(_ browser: Browser) {
        observed.removeValue(forKey: ObjectIdentifier(browser))
        let goneTabs = Set((browser.tabs + browser.parkedTabs).map(\.id))
        for id in goneTabs {
            observedTabs.remove(id)
            tabWatches.removeValue(forKey: id)
        }
        pruneNests(among: BrowserWindows.shared.browsers.filter { $0 !== browser })
    }

    private func pruneNests(among windows: [Browser]) {
        var liveNests = Set<UUID>()
        for window in windows {
            for tab in window.tabs + window.parkedTabs { if let id = tab.nest?.id { liveNests.insert(id) } }
            for nest in LiveFolders.nests(in: window) { liveNests.insert(nest.id) }
        }
        for group in groups.values { for (_, state) in group { if let id = state.1?.id { liveNests.insert(id) } } }
        for moved in folderParents.values { for (nest, parent) in moved { liveNests.insert(nest.id); if let id = parent?.id { liveNests.insert(id) } } }
        for id in Set(nestWatches.keys).subtracting(liveNests) { nestWatches.removeValue(forKey: id) }
    }

    func observe(_ browser: Browser) {
        for (id, watch) in observed where watch.browser == nil { observed.removeValue(forKey: id) }
        let identity = ObjectIdentifier(browser)
        if observed[identity]?.browser !== browser {
            var watches = NativeSetting.all.map { setting in
                setting.observe(browser.prefs) { [weak self, weak browser] in
                    self?.changes.changed("setting:" + setting.id)
                    if setting.scope == "space", let browser { self?.changes.changed("space:" + browser.spaceID.uuidString) }
                }
            }
            watches.append(browser.prefs.changes(\.pageFonts).dropFirst().sink { [weak self] _ in self?.changes.changed("fonts") })
            watches.append(browser.prefs.changes(\.backdropColor).dropFirst().sink { [weak self, weak browser] _ in
                if let browser { self?.changes.changed("space:" + browser.spaceID.uuidString) }
            })
            watches.append(browser.prefs.changes(\.backdropColors).dropFirst().sink { [weak self, weak browser] _ in
                if let browser { self?.changes.changed("space:" + browser.spaceID.uuidString) }
            })
            watches.append(browser.prefs.changes(\.usesMail).dropFirst().sink { [weak self] _ in self?.changes.changed("mail-enabled") })
            watches.append(browser.changes(\.spaceID).dropFirst().sink { [weak self] _ in self?.changes.changed("active-space") })
            var layout = browser.tabs.filter { !$0.shy && !$0.bench }.map(\.id)
            let layoutResource = "layout:" + windowID(browser)
            let pairResource = "pairs:" + windowID(browser)
            watches.append(browser.changes(\.pairs).dropFirst().sink { [weak self] _ in self?.changes.changed(pairResource) })
            watches.append(browser.changes(\.tabs).dropFirst().sink { [weak self] next in
                let next = next.filter { !$0.shy && !$0.bench }.map(\.id)
                if layout != next { self?.changes.changed(layoutResource); layout = next }
            })
            var before = browser.spaces
            watches.append(browser.changes(\.spaces).dropFirst().sink { [weak self] next in
                self?.changes.changed("spaces")
                for id in Set(before.map(\.id) + next.map(\.id)) where before.first(where: { $0.id == id }) != next.first(where: { $0.id == id }) {
                    self?.changes.changed("space:" + id.uuidString)
                }
                before = next
            })
            observed[identity] = WindowWatch(browser: browser, cancellables: watches)
        }
        for tab in browser.tabs + browser.parkedTabs where !tab.shy && !observedTabs.contains(tab.id) {
            observedTabs.insert(tab.id)
            let resource = "tab:" + tab.id.uuidString
            tabWatches[tab.id] = [
                tab.changes(\.pin).dropFirst().sink { [weak self] _ in self?.changes.changed(resource) },
                tab.changes(\.name).dropFirst().sink { [weak self] _ in self?.changes.changed(resource) },
                tab.changes(\.zoom).dropFirst().sink { [weak self] _ in self?.changes.changed(resource) },
                tab.changes(\.address).dropFirst().sink { [weak self] _ in self?.changes.changed(resource) },
                tab.changes(\.kept).dropFirst().sink { [weak self] _ in self?.changes.changed(resource) },
                tab.changes(\.nest).dropFirst().sink { [weak self] _ in self?.changes.changed(resource) }
            ]
        }
        for nest in (browser.tabs + browser.parkedTabs).compactMap(\.nest) + LiveFolders.nests(in: browser) where nestWatches[nest.id] == nil {
            let resource = "nest:" + nest.id.uuidString, live = "live:" + nest.id.uuidString
            nestWatches[nest.id] = [nest.$name.dropFirst().sink { [weak self] _ in self?.changes.changed(resource); self?.changes.changed(live) },
                                   nest.$customMark.dropFirst().sink { [weak self] _ in self?.changes.changed(resource) },
                                   nest.$color.dropFirst().sink { [weak self] _ in self?.changes.changed(resource) },
                                   nest.$live.dropFirst().sink { [weak self] _ in self?.changes.changed(live) }]
        }
        pruneNests(among: BrowserWindows.shared.browsers + [browser])
        let live = Set((BrowserWindows.shared.browsers + [browser]).flatMap { $0.tabs + $0.parkedTabs }.map(\.id))
        for id in observedTabs.subtracting(live) { observedTabs.remove(id); tabWatches.removeValue(forKey: id) }
    }

    private func tab(_ id: String, browser: Browser) throws -> Tab {
        guard let tab = (browser.tabs + browser.parkedTabs).first(where: { !$0.shy && ($0.id.uuidString == id || Bench.short($0) == id) }) else {
            throw NativeFailure("not_found", "No such tab")
        }
        return tab
    }

    private func space(_ id: String, browser: Browser) throws -> Space {
        guard let id = UUID(uuidString: id), let space = browser.spaces.first(where: { $0.id == id }) else { throw NativeFailure("not_found", "No such space") }
        return space
    }

    /// A folder of the space on screen, a folder in a folder included: the
    /// ones the column lists (Browser.nests), by the folderId tabs carry.
    /// What tabs.move takes: the tabs named, or every tab under the folder
    /// named when no tabs are.
    private func moving(_ arguments: [String: NativeValue], browser: Browser) throws -> [Tab] {
        if arguments["tabs"] == nil, let id = string(arguments["folder"]) { return browser.tabs(in: try folder(id, browser: browser)) }
        return try strings(arguments["tabs"]).map { try tab($0, browser: browser) }
    }

    private func folder(_ id: String, browser: Browser) throws -> Nest {
        guard let wanted = UUID(uuidString: id), let nest = browser.nests.first(where: { $0.id == wanted }) else {
            throw NativeFailure("not_found", "No such folder in the current space; folderId comes from native_context's tabs or folders")
        }
        return nest
    }

    /// The row and its folders, each with the folder it is in, so taking a
    /// folder out of another changes the state even when no tab's own
    /// folder does.
    private func folderLayout(_ browser: Browser) -> NativeValue {
        .object(["space": .string(browser.spaceID.uuidString),
                 "tabs": .array(browser.tabs.filter { !$0.shy && !$0.bench }.map(versionedTabState)),
                 "folders": .array(browser.nests.map { .object(["id": .string($0.id.uuidString), "name": .string($0.name), "parent": $0.parent.map { NativeValue.string($0.id.uuidString) } ?? .null]) })])
    }

    private func folderSummary(_ nest: Nest, browser: Browser) -> [String: Any] {
        ["id": nest.id.uuidString, "name": nest.name, "path": nest.chain.map(\.name).joined(separator: " \u{203A} "),
         "parentId": nest.parent?.id.uuidString ?? "", "tabs": browser.tabs(in: nest).filter { !$0.shy }.count,
         "ownTabs": browser.tabs.filter { $0.nest === nest && !$0.shy }.count,
         "live": nest.live != nil, "today": nest.today, "search": nest.research]
    }

    /// A live folder of the space on screen: the only ones with a real Nest
    /// and that space's sign-ins, as Settings opens another space's first.
    private func liveNest(_ id: String, browser: Browser) throws -> Nest {
        let wanted = UUID(uuidString: id)
        if let nest = LiveFolders.nests(in: browser).first(where: { $0.id == wanted }) { return nest }
        if let other = LiveFolderSummary.all(in: browser).first(where: { $0.id == wanted }), other.space != browser.spaceID {
            throw NativeFailure("conflict", "This live folder is in another space; show that space first with space.switch")
        }
        throw NativeFailure("not_found", "No such live folder")
    }

    /// What an agent may change of a folder, without what its reads change
    /// (tabs, when it was read), so a background update never blocks an undo.
    private func liveState(_ nest: Nest) -> NativeValue {
        guard let live = nest.live else { return .object(["id": .string(nest.id.uuidString), "name": .string(nest.name), "live": .bool(false)]) }
        return .object(["id": .string(nest.id.uuidString), "name": .string(nest.name), "live": .bool(true), "source": .string(live.source),
                        "host": .string(live.host), "show": .array(live.show.map(NativeValue.string)), "hidden": .array(live.hidden.map(NativeValue.string)),
                        "query": live.query.map(NativeValue.string) ?? .null, "days": live.days.map { .number(Double($0)) } ?? .null])
    }

    private func liveList(_ browser: Browser) -> NativeValue {
        .object(["enabled": .bool(browser.prefs.usesLiveFolders), "space": .string(browser.spaceID.uuidString),
                 "folders": .array(LiveFolders.nests(in: browser).map(liveState))])
    }

    private func liveSummary(_ entry: LiveFolderSummary, browser: Browser) -> [String: Any] {
        let live = entry.live, source = LiveSource.of(live.source)
        var out: [String: Any] = ["id": entry.id.uuidString, "name": entry.name, "spaceId": entry.space.uuidString,
                                  "inCurrentSpace": entry.space == browser.spaceID, "source": live.source, "sourceTitle": source?.title ?? live.source,
                                  "host": live.host, "show": live.show, "lists": (source?.lists ?? []).map { ["id": $0.id, "title": $0.title] },
                                  "hidden": live.hidden, "tabs": entry.count]
        if let repo = live.followed { out["followedRepository"] = repo; out["days"] = live.days ?? 7 }
        else if let query = live.query { out["query"] = query }
        if live.source == "routine" { out["routineId"] = live.host }
        if let state = LiveFolders.shared.states[entry.id] {
            out["signedOut"] = state.signedOut; out["failedReads"] = state.failures
            if let read = state.read { out["lastRead"] = read.ISO8601Format() }
        }
        out["updating"] = LiveFolders.shared.reading.contains(entry.id)
        if entry.space == browser.spaceID, let nest = try? liveNest(entry.id.uuidString, browser: browser) {
            out["resourceVersion"] = changes.version("live:" + nest.id.uuidString, liveState(nest))
        }
        return out
    }

    private func switchSpace(_ id: String, browser: Browser) throws {
        let destination = id == Space.mailID.uuidString ? Space.mail : try space(id, browser: browser)
        guard destination.id == browser.spaceID || browser.prefs.usesSpaces || browser.inMail || destination.id == Space.mailID else {
            throw NativeFailure("spaces_disabled", "Turn on Spaces before switching to another space")
        }
        browser.switchSpace(to: destination.id)
        guard browser.spaceID == destination.id else { throw NativeFailure("verification_failed", "The requested space was not shown") }
    }

    private static func zoomResource(_ host: String) -> String { "site-zoom:" + NativeValue.string(host).fingerprint }

    private func zoomState(_ tab: Tab) throws -> (String, NativeValue) {
        guard let url = tab.address, ["http", "https"].contains(url.scheme ?? ""), let host = url.host() else {
            throw NativeFailure("invalid_arguments", "Zoom needs a website")
        }
        let resource = Self.zoomResource(host)
        let saved = try NativeValue.read(Store.settings.object(forKey: "zoom." + host) ?? NSNull())
        return (resource, .object(["tab": versionedTabState(tab), "saved": saved,
                                  "siteRevision": .string(changes.version(resource + ":edits", saved))]))
    }

    private func pinState(_ tab: Tab, browser: Browser) throws -> NativeValue {
        guard browser.tabs.contains(where: { $0 === tab }), !tab.bench else {
            throw NativeFailure("invalid_arguments", "Pin a user tab in the current space")
        }
        guard !MailPage.isMail(tab.pending ?? tab.address) else {
            throw NativeFailure("unsupported", "Use Mail's own Pin or Unpin control; it also changes Mail's door")
        }
        guard browser.partner(of: tab)?.shy != true else { throw NativeFailure("conflict", "This split cannot be changed safely") }
        let order = NativeValue.array(browser.tabs.map { .string($0.id.uuidString) }).fingerprint
        let pairs = NativeValue.array(browser.pairs.map { .object(["first": .string($0.first.uuidString), "second": .string($0.second.uuidString), "share": .number(Double($0.share))]) }).fingerprint
        let row = NativeValue.array(browser.tabs.filter { !$0.shy && !$0.bench }.map(versionedTabState)).fingerprint
        return .object(["tab": versionedTabState(tab), "rowRevision": .string(row),
                        "space": .string(browser.spaceID.uuidString), "order": .string(order), "pairs": .string(pairs),
                        "pairsRevision": .string(changes.version("pairs:" + windowID(browser), .null)),
                        "layoutRevision": .string(changes.version("layout:" + windowID(browser), .null))])
    }

    /// Deletion covers every row it will erase, including closed windows' saved rows.
    /// Disk revisions are hashed; session URLs and credentials never enter a receipt.
    private func deletionState(_ id: String, browser: Browser) throws -> NativeValue {
        let target = try space(id, browser: browser)
        var windows = BrowserWindows.shared.browsers.filter { $0 !== browser }; windows.append(browser)
        let rows = windows.sorted { windowID($0) < windowID($1) }.map { window -> NativeValue in
            let tabs = window.spaceID == target.id ? window.tabs : window.parked[target.id]?.tabs ?? []
            let row = NativeValue.array(tabs.filter { !$0.shy && !$0.bench }.map(versionedTabState))
            return .object(["window": .string(windowID(window)), "rowRevision": .string(row.fingerprint)])
        }
        Session.settle()
        let files = try FileManager.default.contentsOfDirectory(at: Store.folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == "session-\(target.id.uuidString).json" ||
                ($0.lastPathComponent.hasPrefix("session-window-") && $0.lastPathComponent.hasSuffix("-\(target.id.uuidString).json")) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let saved = try files.map { file -> NativeValue in
            let data = try Data(contentsOf: file)
            return .object(["file": .string(file.lastPathComponent), "revision": .string(NativeValue.string(data.base64EncodedString()).fingerprint)])
        }
        return .object(["space": versionedSpaceState(target, browser: browser), "rows": .array(rows), "savedRevision": .string(NativeValue.array(saved).fingerprint)])
    }

    private func tabState(_ tab: Tab) -> NativeValue {
        .object(["id": .string(tab.id.uuidString), "name": tab.name.map(NativeValue.string) ?? .null,
                 "pin": tab.pin.map(NativeValue.string) ?? .null, "inEverySpace": .bool(tab.everywhere != nil), "zoom": .number(Double(tab.zoom)),
                 "kept": .bool(tab.kept), "folder": tab.nest.map { .object(["id": .string($0.id.uuidString), "name": .string($0.name), "revision": .string(changes.version("nest:" + $0.id.uuidString, .null))]) } ?? .null,
                 "navigation": .string(NativeValue.string(tab.address?.absoluteString ?? "").fingerprint)])
    }

    private func versionedTabState(_ tab: Tab) -> NativeValue {
        .object(["state": tabState(tab), "revision": .string(changes.version("tab:" + tab.id.uuidString, tabState(tab)))])
    }

    private func versionedSpaceState(_ space: Space, browser: Browser) -> NativeValue {
        let state = spaceState(space, browser: browser)
        return .object(["id": .string(space.id.uuidString), "state": state, "revision": .string(changes.version("space:" + space.id.uuidString, state))])
    }

    private func spaceState(_ space: Space, browser: Browser) -> NativeValue {
        let paint = space.id == browser.spaceID ? SpacePaint(browser.prefs) : space.paint ?? SpacePaint(browser.prefs)
        return .object(["id": .string(space.id.uuidString), "name": .string(space.name), "color": .string(paint.color),
                        "swatch": .string(paint.swatch), "grain": .number(paint.grain), "transparency": .number(paint.transparency), "glass": .bool(paint.glass), "colors": .array(paint.colors.map(NativeValue.string)),
                        "separateSignIns": .bool(space.ownSignIns), "authStoreId": .string(space.profileID.uuidString)])
    }

    private func snapshot(action: String, target: String, arguments: [String: NativeValue], browser: Browser) throws -> (String, NativeValue) {
        if action.hasPrefix("settings.set."), let setting = NativeSetting.all.first(where: { "settings.set." + $0.id == action }) {
            if setting.scope == "space" { return ("space:" + target, spaceState(try space(target, browser: browser), browser: browser)) }
            return ("setting:" + setting.id, setting.read(browser.prefs))
        }
        switch action {
        case "settings.open": return ("settings-page", .object(["visible": .bool(SettingsWindow.shared.window?.isVisible == true), "page": .string(SettingsWindow.shared.page.rawValue)]))
        case "space.create": return ("spaces", .object(["enabled": .bool(browser.prefs.usesSpaces), "spaces": .array(browser.spaces.map { versionedSpaceState($0, browser: browser) }), "layout": .string(changes.version("layout:" + windowID(browser), .null))]))
        case "space.switch": return ("active-space", .string(browser.spaceID.uuidString))
        case "space.rename", "space.set_appearance": return ("space:" + target, spaceState(try space(target, browser: browser), browser: browser))
        case "space.delete": return ("delete-space:" + target, try deletionState(target, browser: browser))
        case "tabs.pin":
            let tab = try tab(target, browser: browser)
            return ("pin:" + tab.id.uuidString, try pinState(tab, browser: browser))
        case "tabs.rename": return ("tab:" + (try tab(target, browser: browser)).id.uuidString, tabState(try tab(target, browser: browser)))
        case "site.set_zoom": return try zoomState(tab(target, browser: browser))
        case "tabs.reorder", "tabs.group":
            guard browser.spaceID.uuidString == target else { throw NativeFailure("conflict", "This action targets the current space's row") }
            return ("layout:" + windowID(browser), .object(["space": .string(target), "tabs": .array(browser.tabs.filter { !$0.shy && !$0.bench }.map(versionedTabState))]))
        case "tabs.move_to_folder", "folder.ungroup": return ("layout:" + windowID(browser), folderLayout(browser))
        case "tabs.close":
            guard browser.spaceID.uuidString == target else { throw NativeFailure("conflict", "Close tabs of the space on screen; show another with space.switch first") }
            let closing = try strings(arguments["tabs"]).map { try tab($0, browser: browser) }
            return ("layout:" + windowID(browser), .object(["space": .string(target),
                                                            "row": .array(browser.tabs.filter { !$0.shy && !$0.bench }.map { .string($0.id.uuidString) }),
                                                            "closing": .array(closing.map(versionedTabState))]))
        case "tabs.move_out_of_folder":
            guard browser.spaceID.uuidString == target else { throw NativeFailure("conflict", "This action targets the current space's row") }
            return ("layout:" + windowID(browser), folderLayout(browser))
        case "tabs.move":
            let destination = try space(target, browser: browser)
            let chosen = try moving(arguments, browser: browser)
            let inTarget = browser.spaceID == destination.id ? browser.tabs : browser.parked[destination.id]?.tabs ?? []
            return ("move:" + target, .object(["from": .string(browser.spaceID.uuidString), "to": versionedSpaceState(destination, browser: browser),
                                              "layout": .string(changes.version("layout:" + windowID(browser), .null)),
                                              "source": .array(browser.tabs.filter { !$0.shy && !$0.bench }.map { .string($0.id.uuidString) }),
                                              "destination": .array(inTarget.filter { !$0.shy && !$0.bench }.map { .string($0.id.uuidString) }),
                                              "chosen": .array(chosen.map(versionedTabState))]))
        case "pages.set_fonts": return ("fonts", try NativeValue.read(JSONSerialization.jsonObject(with: JSONEncoder().encode(browser.prefs.pageFonts))))
        case "links.set_route", "links.remove_route", "links.set_default_space": return ("link-routes", routesState())
        case "site.set_engine":
            let host = try engineHost(arguments["site"])
            return ("site-engine:" + host, .string(Store.settings.string(forKey: EngineRules.ownPrefix + host) ?? ""))
        case "site.set_dark":
            let host = try darkHost(arguments["site"])
            return ("site-dark:" + host, .string(DarkPages.choice(host) ?? ""))
        case "site.keep_awake": return ("awake-sites", .array(AwakeSites.shared.sites.map(NativeValue.string)))
        case "mail.set_enabled": return ("mail-enabled", .bool(browser.prefs.usesMail))
        case "mail.set_notify": return ("mail-notify:" + target, .string(MailNotify.shared.mode(try mailAccount(target)).rawValue))
        case "mail.set_read_statuses":
            guard let store = MailCenter.shared.engines[try mailAccount(target)]?.store else { throw NativeFailure("not_found", "This account's mail isn't open yet") }
            return ("mail-reads:" + target, .bool(MailReads.on(store)))
        case "live.add", "live.follow_repo": return ("live-folders:" + windowID(browser), liveList(browser))
        case "live.set", "live.update", "live.stop":
            let nest = try liveNest(target, browser: browser)
            return ("live:" + nest.id.uuidString, liveState(nest))
        case "mail.connect", "mail.reconnect", "mail.disconnect":
            return ("mail:" + target, .object(["accounts": .array(MailCenter.shared.accounts.sorted().map(NativeValue.string)), "connecting": .bool(MailCenter.shared.connecting)]))
        default: throw NativeFailure("unsupported", "This action is not supported by this build")
        }
    }

    private func context(_ request: [String: Any], browser: Browser, session: Agents.Session) throws -> [String: Any] {
        let query = (request["query"] as? String ?? "").lowercased()
        let section = request["section"] as? String ?? "summary"
        let settings = NativeSetting.all.filter {
            if !query.isEmpty { return ($0.id + " " + $0.title).lowercased().contains(query) }
            return section == "settings" || ["theme", "sidebar", "page-zoom"].contains($0.id)
        }.map { setting -> [String: Any] in
            let value = setting.read(browser.prefs)
            let state = setting.scope == "space" ? browser.spaces.first(where: { $0.id == browser.spaceID }).map { spaceState($0, browser: browser) } ?? .null : value
            let resource = setting.scope == "space" ? "space:" + browser.spaceID.uuidString : "setting:" + setting.id
            return ["id": setting.id, "title": setting.title, "value": value.any, "valueSchema": setting.schema,
                    "target": ["kind": setting.scope, "id": setting.scope == "space" ? browser.spaceID.uuidString : "app"],
                    "resourceVersion": changes.version(resource, state)]
        }
        // The first tab at each address, for the ones after it: "close my
        // duplicates" (tabs.close).
        var firstAt: [String: UUID] = [:]
        for tab in browser.tabs where !tab.shy && !tab.bench {
            if let key = Self.sameAddress(tab), firstAt[key] == nil { firstAt[key] = tab.id }
        }
        func metadata(_ tab: Tab) -> [String: Any] {
            var url = tab.address.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            url?.query = nil; url?.fragment = nil; url?.user = nil; url?.password = nil; url?.path = ""
            return ["id": tab.id.uuidString, "title": String(tab.label.prefix(160)), "url": url?.string ?? "", "active": browser.activeID == tab.id,
                    "pinned": tab.pin != nil, "inEverySpace": tab.everywhere != nil,
                    "visible": browser.tabs.contains { $0 === tab }, "kept": tab.kept, "blank": tab.isBlank, "folderId": tab.nest?.id.uuidString ?? "", "folderName": tab.nest?.name ?? "",
                    // The folders it is in from the top, a folder in a folder's included.
                    "folderPath": tab.nest.map { $0.chain.map(\.name).joined(separator: " \u{203A} ") } ?? "",
                    "splitPartnerId": browser.partner(of: tab).flatMap { $0.shy ? nil : $0.id.uuidString } ?? "",
                    "ownedByTask": tab.agent == session.id, "resourceVersion": changes.version("tab:" + tab.id.uuidString, tabState(tab)),
                    // When the user last looked at it: "close what I haven't used in a week".
                    "lastUsed": tab.touched.ISO8601Format(),
                    "duplicateOf": Self.sameAddress(tab).flatMap { firstAt[$0] }.flatMap { $0 == tab.id ? nil : $0.uuidString } ?? ""]
        }
        let shared = browser.sharedPins ?? []
        let visible = (browser.tabs + shared.filter { pin in !browser.tabs.contains { $0 === pin } }).filter { !$0.shy }
        let offset = max(0, request["offset"] as? Int ?? 0)
        let limit = min(50, max(1, request["limit"] as? Int ?? 10))
        let spaces = browser.spaces.map { space -> [String: Any] in
            let state = spaceState(space, browser: browser)
            return ["id": space.id.uuidString, "name": space.name, "active": space.id == browser.spaceID,
                    "authStoreId": space.ownSignIns ? Spaces.signIn(of: space.id).uuidString : Space.firstID.uuidString,
                    "separateSignIns": space.ownSignIns, "showsSharedPins": browser.showsShared(space.id), "appearance": state.any, "resourceVersion": changes.version("space:" + space.id.uuidString, state)]
        }
        let accounts = MailCenter.shared.accounts.map { account -> [String: Any] in
            let status = MailCenter.shared.status[account]
            return ["id": account, "provider": "gmail", "connected": true, "signedOut": status?.signedOut ?? false,
                    "lastSynced": status?.synced?.ISO8601Format() ?? "", "trouble": status?.trouble ?? "",
                    "calendarGranted": Store.settings.bool(forKey: "mail.calendar." + account),
                    "notify": MailNotify.shared.mode(account).rawValue,
                    "readStatuses": MailCenter.shared.engines[account].map { MailReads.on($0.store) } ?? false]
        }
        var out: [String: Any] = ["catalogVersion": NativeActions.version, "appVersion": Guide.version,
                                  "windowId": windowID(browser),
                                  "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev", "canWrite": Self.writable(session),
                                  "settings": settings, "spaces": spaces, "mailAccounts": accounts,
                                  "mailEnabled": browser.prefs.usesMail, "mailConfigured": MailClient.configured != nil,
                                  "sync": ["on": SyncCenter.shared.on, "devices": SyncCenter.shared.devices.map(\.name),
                                           "note": "The devices tool lists each device's open tabs; history with device reads what was opened there"] as [String: Any],
                                  "tabs": visible.dropFirst(offset).prefix(limit).map(metadata), "hasMoreTabs": visible.count > offset + limit,
                                  "task": ["id": session.id, "prompt": String(session.prompt.prefix(2000)), "state": session.state.rawValue],
                                  "operations": changes.receipts.filter { $0.session == session.id }.suffix(12).map { ["id": $0.id, "action": $0.action, "status": $0.status] }]
        if let active = browser.active, !active.shy { out["activeTab"] = metadata(active) }
        out["activeSpaceId"] = browser.spaceID.uuidString
        out["coverage"] = ["privateTabsExcluded": true, "parkedTabsIncluded": false, "parkedSharedPinsIncluded": true,
                           "visibleTabCount": browser.tabs.filter { !$0.shy }.count]
        out["pinsInEverySpace"] = browser.pinsShared
        let selection = browser.chosen.filter { !$0.shy && !$0.bench }
        out["selectedTabIds"] = selection.prefix(50).map { $0.id.uuidString }
        out["selectionCount"] = selection.count
        out["hasMoreSelectedTabs"] = selection.count > 50
        out["permissions"] = ["asking": browser.prefs.agentsAsking.rawValue, "nativeWrite": Self.writable(session),
                              "userConfirmation": ["space.delete", "mail.disconnect", "mail.connect", "mail.reconnect", "mail.set_read_statuses"],
                              "macAccessRequired": false, "policyChangesAllowed": false] as [String: Any]
        out["unresolvedOperations"] = changes.receipts.filter { $0.status == "unknown_outcome" }.suffix(10).map {
            ["action": $0.action, "target": $0.target, "status": $0.status, "message": "Read actual state before attempting this effect again"]
        }
        // Folders of the space on screen, a folder before the folders in it:
        // targets of tabs.move_to_folder and folder.ungroup.
        out["folders"] = browser.nests.map { folderSummary($0, browser: browser) }
        out["liveFolders"] = ["enabled": browser.prefs.usesLiveFolders,
                              "folders": LiveFolderSummary.all(in: browser).map { liveSummary($0, browser: browser) },
                              "sources": NativeActions.liveSources.compactMap(LiveSource.of).map {
                                  ["id": $0.id, "title": $0.title, "brings": LiveFoldersSettings.what($0.id), "lists": $0.lists.map { ["id": $0.id, "title": $0.title] }]
                              },
                              "note": "Folders update with their space's sign-ins while that space is open. Change one of another space after space.switch."] as [String: Any]
        out["surface"] = SettingsWindow.shared.window?.isVisible == true ? "settings" : browser.inMail ? "mail" : "website"
        if SettingsWindow.shared.window?.isVisible == true { out["settingsPage"] = SettingsWindow.shared.page.rawValue }
        out["taskTargets"] = ["tabId": session.nativeOriginTab?.uuidString ?? "", "spaceId": session.nativeOriginSpace?.uuidString ?? "", "undoChangeId": session.nativeUndoChange ?? ""]
        out["activeSpaceVersion"] = changes.version("active-space", .string(browser.spaceID.uuidString))
        out["spacesVersion"] = changes.version("spaces", try snapshot(action: "space.create", target: "app", arguments: [:], browser: browser).1)
        let routes = LinkRoutes.shared
        out["linkRoutes"] = ["rules": routes.routes.map { route -> [String: Any] in
                                 ["site": route.site, "space": Self.routeToken(route.space),
                                  "spaceName": browser.spaces.first { $0.id == route.space }?.name ?? (route.space == LinkRoutes.recentSpaceID ? "Recent space" : ""),
                                  "skipSmallWindow": route.opensInMain == true]
                             },
                             "defaultSpace": routes.defaultSpace.map(Self.routeToken) ?? "",
                             "working": browser.spacesShown && browser.spaces.count > 1,
                             "smallWindowForOutsideLinks": browser.prefs.smallLinks,
                             "resourceVersion": changes.version("link-routes", routesState()),
                             "note": "Rules send a site's links from other apps, and links its pages open in new tabs, to a space; they work only with two spaces or more. Small Window for every link from other apps is settings.set.small-links."] as [String: Any]
        out["sites"] = ["keptAwake": AwakeSites.shared.sites, "keptLight": DarkPages.keptLight(),
                        "engines": EngineRules.available ? SiteEngineSettings.shared.ownRules.map { ["site": $0.host, "engine": $0.kind.rawValue] } : []] as [String: Any]
        out["fonts"] = try snapshot(action: "pages.set_fonts", target: "app", arguments: [:], browser: browser).1.any
        out["fontsVersion"] = changes.version("fonts", try snapshot(action: "pages.set_fonts", target: "app", arguments: [:], browser: browser).1)
        if section == "catalog" || request["includeCatalog"] as? Bool == true {
            out["settingsCatalog"] = SettingsItem.all.filter { query.isEmpty || ($0.id + " " + $0.title).lowercased().contains(query) }.map {
                ["id": $0.id, "title": $0.title, "page": $0.page.title, "access": NativeActions.classification($0)]
            }
            let native: [Command: String] = [.settings: "settings.open", .pinTab: "tabs.pin", .unpinTab: "tabs.pin", .zoomIn: "site.set_zoom", .zoomOut: "site.set_zoom", .actualSize: "site.set_zoom", .showBar: "settings.set.address-bar", .hideBar: "settings.set.address-bar", .showSidebar: "settings.set.sidebar", .hideSidebar: "settings.set.sidebar", .newYork: "settings.set.sidebar", .sanFrancisco: "settings.set.sidebar"]
            out["commandsCatalog"] = Command.allCases.filter { query.isEmpty || ($0.rawValue + " " + $0.title).lowercased().contains(query) }.map {
                ["id": $0.rawValue, "title": $0.title, "access": native[$0] == nil ? "ui_only" : "native_action", "action": native[$0] ?? ""]
            }
        }
        if let action = request["action"] as? String {
            guard let descriptor = NativeActions.descriptors.first(where: { $0["id"] as? String == action }),
                  let target = request["target"] as? [String: String], target["kind"] == descriptor["targetKind"] as? String, let id = target["id"],
                  case .object(let arguments) = try NativeValue.read(request["arguments"] ?? [String: Any]()) else {
                throw NativeFailure("invalid_arguments", "Preview a listed action with its target and arguments")
            }
            try NativeActions.validate(arguments, descriptor: descriptor)
            let normalized = ["space", "liveFolder", "folder"].contains(target["kind"] ?? "") ? UUID(uuidString: id)?.uuidString ?? id : id
            let (resource, state) = try snapshot(action: action, target: normalized, arguments: arguments, browser: browser)
            out["targetState"] = state.any; out["resourceVersion"] = changes.version(resource, state)
            out["previewAction"] = action
        } else if let target = request["target"] as? [String: String], let id = target["id"] {
            let value: NativeValue, resource: String
            switch target["kind"] {
            case "space": let space = try space(id, browser: browser); resource = "space:" + space.id.uuidString; value = spaceState(space, browser: browser)
            case "tab": let tab = try tab(id, browser: browser); resource = "tab:" + tab.id.uuidString; value = tabState(tab)
            case "liveFolder": let nest = try liveNest(id, browser: browser); resource = "live:" + nest.id.uuidString; value = liveState(nest)
            case "folder": _ = try folder(id, browser: browser); resource = "layout:" + windowID(browser); value = folderLayout(browser)
            default: throw NativeFailure("invalid_arguments", "Read a specific tab, space, folder or live folder by its kind and id")
            }
            out["targetState"] = value.any; out["resourceVersion"] = changes.version(resource, value)
        }
        return out
    }

    private func apply(_ request: [String: Any], browser: Browser, session: Agents.Session) throws -> [String: Any] {
        let action = request["action"] as? String ?? ""
        guard let descriptor = NativeActions.descriptors.first(where: { $0["id"] as? String == action }) else { throw NativeFailure("unsupported", "Unknown native action; read native_actions for this build") }
        guard let requestID = request["requestId"] as? String, (1...128).contains(requestID.count) else { throw NativeFailure("invalid_arguments", "Give this effect a stable requestId, and reuse it when retrying") }
        guard let rawTarget = request["target"] as? [String: Any], Set(rawTarget.keys) == Set(["kind", "id"]) else { throw NativeFailure("invalid_arguments", "Give the target's kind and id") }
        guard rawTarget["kind"] as? String == descriptor["targetKind"] as? String, let rawID = rawTarget["id"] as? String,
              (1...160).contains(rawID.count), rawTarget["kind"] as? String != "application" || rawID == "app" else { throw NativeFailure("invalid_arguments", "Give an explicit target of the action's targetKind") }
        let target = ["space", "liveFolder", "folder"].contains(rawTarget["kind"] as? String ?? "") ? UUID(uuidString: rawID)?.uuidString ?? rawID : rawID
        guard let rawArguments = request["arguments"] as? [String: Any] else { throw NativeFailure("invalid_arguments", "Arguments must be an object") }
        guard case .object(let arguments) = try NativeValue.read(rawArguments) else { throw NativeFailure("invalid_arguments", "Arguments must be an object") }
        try NativeActions.validate(arguments, descriptor: descriptor)
        let fingerprint = try NativeValue.read(["action": action, "target": rawTarget, "arguments": rawArguments]).fingerprint
        if let previous = try changes.existing(session: session.id, request: requestID, fingerprint: fingerprint) {
            return previous.result?.any as? [String: Any] ?? ["status": previous.status, "operationId": previous.id]
        }
        if action == "space.switch", target != Space.mailID.uuidString { _ = try space(target, browser: browser) }
        if action == "tabs.move_to_folder" || action == "folder.ungroup" { _ = try folder(target, browser: browser) }
        if action == "mail.reconnect" || action == "mail.disconnect" {
            guard MailCenter.shared.accounts.contains(target) else { throw NativeFailure("not_found", "No such mail account") }
        }
        if action == "mail.connect" || action == "mail.reconnect" {
            let email = string(arguments["email"]) ?? (target == "app" ? nil : target)
            let alreadyConnected = email.map {
                MailCenter.shared.accounts.contains($0.lowercased())
                    && MailCenter.shared.status[$0.lowercased()]?.signedOut != true && action != "mail.reconnect"
            } ?? false
            if !alreadyConnected, let problem = MailCenter.shared.gmailConnectionProblem(expectedAccount: email) {
                throw NativeFailure("connection_unavailable", problem)
            }
            guard MailClient.configured != nil else { throw NativeFailure("not_configured", "This build has no Google client for Mail") }
            if let email = string(arguments["email"]) {
                guard MailDesk.address(email) else { throw NativeFailure("invalid_arguments", "Give the Gmail account's email address") }
            }
        }
        let (resource, before) = try snapshot(action: action, target: target, arguments: arguments, browser: browser)
        let version = changes.version(resource, before)
        if let expected = request["expectedVersion"] as? String, expected != version { throw NativeFailure("conflict", "The target changed. Read its current state before trying again") }
        let receipt = try changes.prepare(session: session.id, request: requestID, fingerprint: fingerprint, action: action, target: target, resource: resource, before: before, window: windowID(browser))
        Agents.shared.touch(session.id, "native · " + (descriptor["title"] as? String ?? action))
        let execute = { [weak self, weak browser] in
            guard let self, let browser else { return }
            do {
                guard Self.writable(session), changes.receipt(receipt.id, session: session.id)?.status != "cancelled" else { throw NativeFailure("cancelled", "This task was stopped or the operation was cancelled") }
                let now = try snapshot(action: action, target: target, arguments: arguments, browser: browser)
                guard changes.version(resource, now.1) == version else { throw NativeFailure("conflict", "The target changed while waiting. Request the action again with its current state") }
                try ensureIdle(action, target: target, arguments: arguments, browser: browser, operation: receipt.id)
                if action == "mail.connect" || action == "mail.reconnect" { try connect(receipt, arguments: arguments, browser: browser, session: session); return }
                try mutate(action, target: target, arguments: arguments, browser: browser, operation: receipt.id)
                synchronizeApplication(browser)
                observe(browser)
                var afterArguments = arguments
                if let move = moves[receipt.id] { afterArguments["tabs"] = .array(move.tabs.map { .string($0.now.id.uuidString) }) }
                if action == "tabs.close" { afterArguments["tabs"] = .array([]) }
                let after = action == "space.delete" || action == "live.stop" ? NativeValue.null : try snapshot(action: action, target: target, arguments: afterArguments, browser: browser).1
                if before != after { changes.changed(resource) }
                var result: [String: Any] = ["status": "verified", "operationId": receipt.id, "action": action, "target": target,
                                             "before": before.any, "after": after.any, "resourceVersion": changes.version(resource, after)]
                // Pins and kept tabs only put down leave nothing to bring back.
                let undoable = descriptor["undo"] as? Bool == true && before != after && closings[receipt.id]?.closed.isEmpty != true
                result["undo"] = ["available": undoable, "changeId": undoable ? receipt.id : ""]
                if let made = liveMade.removeValue(forKey: receipt.id) { result["folderId"] = made.uuidString }
                if action == "live.update" { result["message"] = "The folder is reading its site now; read native_context's liveFolders for the outcome." }
                if action == "tabs.close", let closing = closings[receipt.id] {
                    result["closed"] = closing.closed.count
                    result["putDown"] = closing.rested.count
                    result["message"] = (closing.closed.isEmpty ? "" : "Closed \(Self.tabCount(closing.closed.count)). ")
                        + (closing.rested.isEmpty ? "" : "Put \(Self.tabCount(closing.rested.count)) pinned or kept to sleep; they stay in the sidebar, as ⌘W leaves them. ")
                        + "Answer in plain words, like “Closed 9 YouTube tabs.”, with no list of them and no mention of Undo: Yab's corner notice carries it."
                }
                if action == "mail.disconnect" { result["remoteRevocation"] = "requested_unverified"; result["message"] = "The account was removed from Yab. Google's access revocation was requested separately." }
                try changes.update(receipt.id, status: "verified", result: result, after: after, version: undoable ? changes.version(resource, after) : nil)
                if action == "tabs.close" {
                    // Pins and kept tabs put down, as ⌘W puts them, say
                    // nothing; the closed ones get the corner's Undo.
                    guard let closing = closings[receipt.id], !closing.closed.isEmpty else { return }
                    // ⌘Z's step and the notice's Undo are one: either takes
                    // the tabs back, once.
                    let step = browser.did { [weak self, weak browser] in
                        guard let self, let browser else { return }
                        do { _ = try self.undo(receipt.id, session: session.id, browser: browser) }
                        catch let error as NativeFailure { browser.announce(error.message) }
                        catch { browser.announce("Could not bring the tabs back") }
                    }
                    closeSteps[receipt.id] = step
                    browser.toaster.pop("Closed " + Self.tabCount(closing.closed.count), mark: "xmark", undo: { [weak browser] in browser?.undo(step: step) })
                } else if before != after {
                    browser.toaster.pop("\(descriptor["title"] as? String ?? "Yab updated")", mark: "checkmark", undo: undoable ? { [weak self, weak browser] in
                        guard let self, let browser else { return }
                        do { _ = try self.undo(receipt.id, session: session.id, browser: browser) }
                        catch let error as NativeFailure { browser.announce(error.message) }
                        catch { browser.announce("Could not undo this change") }
                    } : nil, feedback: .success)
                }
            } catch let error as NativeFailure { finishFailure(receipt, error) }
            catch { finishFailure(receipt, NativeFailure("failed", "The native action could not be completed")) }
        }
        let confirmation: Bool
        do { confirmation = try needsConfirmation(action, target: target, arguments: arguments, browser: browser, session: session) }
        catch let failure as NativeFailure {
            finishFailure(receipt, failure)
            return changes.receipt(receipt.id, session: session.id)?.result?.any as? [String: Any] ?? failure.reply
        }
        if confirmation {
            guard let anchor = browser.active, !anchor.shy, anchor.permit == nil, anchor.handoff == nil else {
                let failure = NativeFailure("busy", "Finish the current question before starting this action")
                finishFailure(receipt, failure)
                return changes.receipt(receipt.id, session: session.id)?.result?.any as? [String: Any] ?? failure.reply
            }
            let result: [String: Any] = ["status": "needs_user", "operationId": receipt.id, "message": "Confirm this action in Yab", "action": action, "target": target]
            try changes.update(receipt.id, status: "needs_user", result: result)
            pending[receipt.id] = execute
            let detail = confirmationDetail(action, target: target, arguments: arguments, browser: browser)
            Agents.shared.ask(anchor, AgentPermit(kind: .native(label: confirmationLabel(action, arguments: arguments), operation: receipt.id), session: session.id, detail: "", draft: detail))
        } else { execute() }
        return changes.receipt(receipt.id, session: session.id)?.result?.any as? [String: Any] ?? ["status": "running", "operationId": receipt.id]
    }

    /// Called only by the existing user confirmation UI, never by an MCP verb.
    func decide(_ id: String, session: String, yes: Bool) {
        guard let receipt = changes.receipt(id, session: session), receipt.status == "needs_user", let execute = pending.removeValue(forKey: id) else { return }
        guard Date().timeIntervalSince(receipt.at) < 300 else { finishFailure(receipt, NativeFailure("expired", "This confirmation expired. Read current state and request the action again")); return }
        if yes { execute() } else { finishFailure(receipt, NativeFailure("cancelled", "The user declined this action")) }
    }

    func stop(_ session: String, browser: Browser) {
        for receipt in changes.receipts.filter({ $0.session == session }) { cancel(receipt, browser: browser) }
    }

    private func needsConfirmation(_ action: String, target: String, arguments: [String: NativeValue], browser: Browser, session: Agents.Session) throws -> Bool {
        try ensureIdle(action, target: target, arguments: arguments, browser: browser)
        if ["space.delete", "mail.disconnect", "mail.connect", "mail.reconnect"].contains(action) { return true }
        if action == "mail.set_read_statuses" { return boolean(arguments["value"]) == true }
        if action == "tabs.move" {
            let destination = try space(target, browser: browser)
            if destination.id == browser.spaceID { return false }
            if Spaces.store(for: browser.spaceID) !== Spaces.store(for: destination.id) { return true }
            return browser.prefs.agentsAsking == .ask
        }
        if action == "live.stop" { return true }
        if ["tabs.reorder", "tabs.group", "tabs.move_to_folder", "tabs.move_out_of_folder", "folder.ungroup", "live.add", "live.follow_repo"].contains(action) {
            return browser.prefs.agentsAsking == .ask
        }
        if ["tabs.pin", "tabs.rename", "site.set_zoom"].contains(action) {
            let target = try tab(target, browser: browser)
            return browser.prefs.agentsAsking == .ask && target.agent != session.id && !target.allowed.contains(session.id)
        }
        return false
    }

    private func ensureIdle(_ action: String, target: String, arguments: [String: NativeValue], browser: Browser, operation: String? = nil) throws {
        let tabs: [Tab]
        if action == "tabs.move" {
            tabs = try moving(arguments, browser: browser)
        } else if ["tabs.group", "tabs.reorder", "tabs.move_to_folder", "tabs.move_out_of_folder", "tabs.close"].contains(action) {
            tabs = try strings(arguments["tabs"]).map { try tab($0, browser: browser) }
        } else if action == "folder.ungroup" {
            tabs = try browser.tabs(in: folder(target, browser: browser))
        } else if ["tabs.pin", "tabs.rename", "site.set_zoom"].contains(action) {
            tabs = [try tab(target, browser: browser)]
        } else if action == "space.delete" {
            let id = try space(target, browser: browser).id
            tabs = (BrowserWindows.shared.browsers.filter { $0 !== browser } + [browser]).flatMap {
                $0.spaceID == id ? $0.tabs : $0.parked[id]?.tabs ?? []
            }
        } else { return }
        for tab in tabs {
            let ownPermit: Bool
            if case .native(_, let id) = tab.permit?.kind { ownPermit = id == operation }
            else { ownPermit = false }
            guard !AgentFeed.shared.driving.contains(tab.id), !AgentFeed.shared.touchedLately(tab),
                  (tab.permit == nil || ownPermit), (tab.handoff == nil || ownPermit),
                  action != "space.delete" || (!tab.shy && !tab.onCall) else {
                throw NativeFailure("conflict", "The user is using one of these tabs. Wait until they hand it back")
            }
        }
    }

    private func confirmationLabel(_ action: String, arguments: [String: NativeValue]) -> String {
        switch action {
        case "space.delete": return "Delete space"
        case "mail.disconnect": return "Disconnect Gmail"
        case "mail.connect": return "Connect Gmail"
        case "mail.reconnect": return "Reconnect Gmail"
        case "tabs.move": return "Move tabs"
        case "tabs.reorder": return "Reorder tabs"
        case "tabs.close": return "Close " + Self.tabCount(strings(arguments["tabs"]).count)
        case "tabs.group": return "Create folder"
        case "tabs.move_to_folder": return "Move to folder"
        case "tabs.move_out_of_folder": return "Move out of folder"
        case "folder.ungroup": return "Ungroup folder"
        case "tabs.pin": return boolean(arguments["value"]) == true ? "Pin tab" : "Unpin tab"
        case "tabs.rename": return "Rename tab"
        case "site.set_zoom": return "Set site zoom"
        case "live.add": return "Add live folder"
        case "live.follow_repo": return "Follow repository"
        case "live.stop": return "Stop updating folder"
        case "mail.set_read_statuses": return "Turn on read statuses"
        default: return "Apply change"
        }
    }

    private func confirmationDetail(_ action: String, target: String, arguments: [String: NativeValue], browser: Browser) -> String {
        if action == "mail.disconnect" { return "Disconnect \(target), request revocation of Yab's Google access and remove its local mail and draft files. Calendar may also require sign-in again. Mail at Gmail stays." }
        if action == "mail.connect" || action == "mail.reconnect" {
            return "Connect \(string(arguments["email"]) ?? (target == "app" ? "a Gmail account" : target)). Choose the account and grant access yourself in the sign-in window."
                + (MailClient.underReview ? " Google may warn that Yab Mail has not been verified." : "")
        }
        if action == "space.delete", let space = try? space(target, browser: browser) { return "Delete \(space.name), its tabs and any separate sign-ins. This cannot be undone." }
        if action == "tabs.move", let destination = try? space(target, browser: browser) {
            let what = string(arguments["folder"]).flatMap { id in try? folder(id, browser: browser) }.map { "the folder “\($0.name)” and its tabs" }
                ?? "\(strings(arguments["tabs"]).count) selected tabs"
            return "Move \(what) to “\(destination.name)”."
                + (Spaces.store(for: browser.spaceID) !== Spaces.store(for: destination.id) ? " The pages will reopen with that space's sign-ins; unsaved page changes may be lost." : " Their sign-ins stay the same.")
        }
        if action == "live.add", let source = string(arguments["source"]).flatMap(LiveSource.of) {
            return "Add a live folder of \(source.title) in “\(browser.space.name)”. It reads the site with this space's sign-ins."
        }
        if action == "mail.set_read_statuses" { return "Put a tiny picture in mail sent from \(target), so Yab can tell when it was opened. Some mail apps send such mail to spam." }
        if action == "live.follow_repo" { return "Follow \(LiveFolders.repo(string(arguments["repository"]) ?? "") ?? "the repository")'s open pull requests in a live folder of its own." }
        if action == "live.stop", let nest = try? liveNest(target, browser: browser) {
            return "Stop updating “\(nest.name)”. Its tabs stay in \(browser.space.name), as a plain folder."
        }
        if action == "tabs.close" {
            return "Close \(Self.tabCount(strings(arguments["tabs"]).count)) in “\(browser.space.name)”. Undo brings them back where they were."
        }
        if action == "tabs.group" { return "Keep \(strings(arguments["tabs"]).count) selected tabs in a new folder, “\(string(arguments["name"]) ?? "")”. Existing folder membership will change." }
        if action == "tabs.move_to_folder", let nest = try? folder(target, browser: browser) {
            return "Move \(strings(arguments["tabs"]).count) selected tabs into the folder “\(nest.name)”. They stay open."
        }
        if action == "tabs.move_out_of_folder" {
            return "Move \(strings(arguments["tabs"]).count) selected tabs out of " + (boolean(arguments["oneStep"]) == true ? "the folder they are in." : "their folders, to the top of the space.") + " They stay open."
        }
        if action == "folder.ungroup", let nest = try? folder(target, browser: browser) {
            return "Remove the folder “\(nest.name)”. Its \(browser.tabs(in: nest).count) tabs stay open where they are."
        }
        if action == "tabs.reorder" {
            let names = strings(arguments["tabs"]).prefix(10).compactMap { try? tab($0, browser: browser).label }
            return "Use this tab order: " + names.joined(separator: ", ") + (strings(arguments["tabs"]).count > 10 ? ", then the remaining selected tabs." : ".")
        }
        if let tab = try? tab(target, browser: browser) {
            if action == "tabs.pin" { return "\(boolean(arguments["value"]) == true ? "Pin" : "Unpin") “\(tab.label)”." }
            if action == "tabs.rename" { return "Rename “\(tab.label)” to “\(string(arguments["name"]) ?? "")”. An empty name restores the page's title." }
            if action == "site.set_zoom", case .number(let zoom) = arguments["value"] { return "Set the site in “\(tab.label)” to \(Int(zoom * 100))% zoom." }
        }
        return "Apply this change in Yab."
    }

    private func mutate(_ action: String, target: String, arguments: [String: NativeValue], browser: Browser, operation: String) throws {
        if let setting = NativeSetting.all.first(where: { "settings.set." + $0.id == action }), let value = arguments["value"] {
            if setting.scope == "space" {
                let space = try space(target, browser: browser)
                var paint = space.id == browser.spaceID ? SpacePaint(browser.prefs) : space.paint ?? SpacePaint(browser.prefs)
                if setting.id == "transparency", case .number(let amount) = value { paint.transparency = amount }
                if setting.id == "glass", case .bool(let on) = value { paint.glass = on }
                if setting.id == "grain", case .number(let grain) = value { paint.grain = grain }
                if setting.id == "color", case .string(let swatch) = value { paint.swatch = swatch }
                if paint != (space.id == browser.spaceID ? SpacePaint(browser.prefs) : space.paint) { browser.setSpacePaint(space.id, to: paint) }
                let kept = try spaceState(self.space(target, browser: browser), browser: browser)
                guard case .object(let state) = kept,
                      state[setting.id == "color" ? "swatch" : setting.id] == value else { throw NativeFailure("verification_failed", "The space did not keep the requested appearance") }
                return
            }
            if setting.read(browser.prefs) == value { return }
            try setting.write(browser.prefs, value)
            guard setting.read(browser.prefs) == value else { throw NativeFailure("verification_failed", "The setting did not keep its requested value") }
            return
        }
        switch action {
        case "links.set_route":
            let site = try routeSite(arguments["site"])
            let space = try routeSpace(try nonempty(arguments["space"]), browser: browser)
            LinkRoutes.shared.set(site, to: space)
            if let skip = boolean(arguments["skipSmallWindow"]) { LinkRoutes.shared.setMainWindow(site, enabled: skip) }
            guard let kept = LinkRoutes.shared.route(site: site), kept.space == space,
                  boolean(arguments["skipSmallWindow"]).map({ (kept.opensInMain == true) == $0 }) ?? true else {
                throw NativeFailure("verification_failed", "The rule was not kept")
            }
        case "links.remove_route":
            let site = try routeSite(arguments["site"])
            guard LinkRoutes.shared.route(site: site) != nil else { throw NativeFailure("not_found", "No rule for \(site); native_context's linkRoutes lists them") }
            LinkRoutes.shared.remove(site)
            guard LinkRoutes.shared.route(site: site) == nil else { throw NativeFailure("verification_failed", "The rule was not removed") }
        case "site.set_engine":
            guard EngineRules.available else { throw NativeFailure("unsupported", "This build has no Chromium") }
            let host = try engineHost(arguments["site"])
            switch string(arguments["value"]) {
            case "chromium": SiteEngineSettings.shared.setOwn(.chromium, host: host)
            case "webKit": SiteEngineSettings.shared.setOwn(.webKit, host: host)
            default: SiteEngineSettings.shared.setOwn(nil, host: host)
            }
            EngineRulesModel.shared.reload()
        case "site.set_dark":
            let host = try darkHost(arguments["site"])
            switch string(arguments["value"]) {
            case "light": DarkPages.keepLight(host, true)
            // Dark with Dark pages off is a word over the site; with it on,
            // dark is what every site gets, so no word is kept.
            case "dark" where DarkMode.read() == .off: setDark("yes", host: host)
            default: DarkPages.keepLight(host, false)
            }
        case "site.keep_awake":
            let site = try awakeSite(arguments["site"]), awake = AwakeSites.shared, on = boolean(arguments["value"]) == true
            if on { awake.add(site) }
            // Kept by a wider site in the list, that one is let go too,
            // as the tab's own menu does.
            else { for kept in awake.sites where site == kept || site.hasSuffix("." + kept) { awake.remove(kept) } }
            guard awake.keeps(URL(string: "https://" + site)) == on else { throw NativeFailure("verification_failed", "The site's sleep was not changed") }
        case "links.set_default_space":
            let raw = string(arguments["space"]) ?? ""
            let space = raw.isEmpty ? nil : try routeSpace(raw, browser: browser)
            LinkRoutes.shared.setDefaultSpace(space)
            guard LinkRoutes.shared.defaultSpace == space else { throw NativeFailure("verification_failed", "The default space was not kept") }
        case "settings.open":
            guard let raw = string(arguments["page"]), let page = SettingsPage(rawValue: raw) else { throw NativeFailure("invalid_arguments", "Choose a Settings page") }
            SettingsWindow.shared.show(page, for: browser)
            guard SettingsWindow.shared.window?.isVisible == true else { throw NativeFailure("verification_failed", "Settings could not be opened") }
        case "space.create":
            let name = try nonempty(arguments["name"])
            guard !browser.spaces.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw NativeFailure("conflict", "A space already has this name") }
            browser.prefs.usesSpaces = true
            let id = browser.addSpace(named: name, ownSignIns: boolean(arguments["separateSignIns"]) ?? false, show: false)
            guard browser.spaces.contains(where: { $0.id == id && $0.name == name }) else { throw NativeFailure("verification_failed", "The space was not created") }
        case "space.rename":
            let space = try space(target, browser: browser), name = try nonempty(arguments["name"])
            if space.name != name { browser.renameSpace(space.id, to: name) }
            guard try self.space(target, browser: browser).name == name else { throw NativeFailure("verification_failed", "The space was not renamed") }
        case "space.set_appearance":
            let space = try space(target, browser: browser)
            guard let raw = string(arguments["color"]), let color = NSColor(hex: raw) else { throw NativeFailure("invalid_arguments", "Give a valid hex color") }
            var paint = space.id == browser.spaceID ? SpacePaint(browser.prefs) : space.paint ?? SpacePaint(browser.prefs)
            paint.color = color.hex; paint.colors = []; paint.swatch = "custom"
            if case .array(let colors) = arguments["colors"] {
                let parsed = try colors.map { value -> String in
                    guard let raw = string(value), let color = NSColor(hex: raw) else { throw NativeFailure("invalid_arguments", "Every gradient stop needs a valid hex color") }
                    return color.hex
                }
                paint.colors = parsed
            }
            if case .number(let grain) = arguments["grain"] { paint.grain = grain }
            browser.setSpacePaint(space.id, to: paint)
        case "space.switch": try switchSpace(target, browser: browser)
        case "space.delete":
            let space = try space(target, browser: browser)
            guard browser.canDeleteSpace(space.id) else { throw NativeFailure("invalid_arguments", "The last space cannot be deleted") }
            browser.deleteSpace(space.id)
            guard !browser.spaces.contains(where: { $0.id == space.id }) else { throw NativeFailure("verification_failed", "The space could not be deleted") }
        case "tabs.pin":
            let tab = try tab(target, browser: browser)
            guard browser.tabs.contains(where: { $0 === tab }), !tab.bench else { throw NativeFailure("invalid_arguments", "Pin a user tab in the current space") }
            if (tab.pin != nil) == boolean(arguments["value"]) { return }
            pins[operation] = PinState(order: browser.tabs.map(\.id), pairs: browser.pairs, pin: tab.pin, kept: tab.kept, nest: tab.nest)
            if boolean(arguments["value"]) == true { if tab.pin == nil { browser.pin(tab, apart: true) } }
            else if tab.pin != nil { browser.unpin(tab) }
            guard (tab.pin != nil) == boolean(arguments["value"]) else { throw NativeFailure("verification_failed", "The tab's pin state did not change") }
        case "tabs.rename":
            let tab = try tab(target, browser: browser)
            let name = string(arguments["name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let wanted = name.isEmpty ? nil : name
            if tab.name != wanted { tab.name = wanted; browser.rememberSession() }
        case "site.set_zoom":
            let tab = try tab(target, browser: browser)
            guard let url = tab.address, ["http", "https"].contains(url.scheme ?? ""), case .number(let value) = arguments["value"] else { throw NativeFailure("invalid_arguments", "Zoom needs a website and a numeric value") }
            tab.magnify(to: CGFloat(value))
        case "tabs.move":
            let destination = try space(target, browser: browser)
            // A whole folder: its tabs and its folders', the folder with them
            // (Browser.sendFolder).
            if arguments["tabs"] == nil, let id = string(arguments["folder"]) {
                let nest = try folder(id, browser: browser)
                if destination.id == browser.spaceID { return }
                guard !browser.tabs(in: nest).isEmpty else { throw NativeFailure("invalid_arguments", "This folder has no tabs to move") }
                guard let move = browser.sendFolder(nest, to: destination.id) else { throw NativeFailure("verification_failed", "The folder could not be moved") }
                moves[operation] = move
                return
            }
            let tabs = try strings(arguments["tabs"]).map { try tab($0, browser: browser) }
            let ids = Set(tabs.map(\.id))
            guard ids.count == tabs.count, tabs.allSatisfy({ chosen in browser.tabs.contains(where: { $0 === chosen }) && !chosen.bench && !browser.travels(chosen) && (browser.partner(of: chosen).map { ids.contains($0.id) } ?? true) }) else { throw NativeFailure("invalid_arguments", "Select user tabs in the current space, including both sides of a split") }
            if destination.id == browser.spaceID { return }
            if Spaces.store(for: browser.spaceID) !== Spaces.store(for: destination.id), tabs.contains(where: { $0.pending == nil && $0.address == nil }) {
                throw NativeFailure("invalid_arguments", "Blank tabs cannot move to a different sign-in store; give them a page first")
            }
            // A shared pin is in a space that shows the shared pins already.
            let going = tabs.filter { !browser.pinnedAlready($0, in: destination.id) }
            if going.isEmpty { return }
            guard let move = browser.moveTabs(going, to: destination.id, say: false), move.tabs.count == going.count else { throw NativeFailure("verification_failed", "The tabs could not all be moved") }
            moves[operation] = move
        case "tabs.reorder": try reorder(strings(arguments["tabs"]), browser: browser)
        case "tabs.close": try close(strings(arguments["tabs"]), pinned: boolean(arguments["includePinned"]) == true, browser: browser, operation: operation)
        case "tabs.group":
            let tabs = try strings(arguments["tabs"]).map { try tab($0, browser: browser) }
            let ids = Set(tabs.map(\.id)), name = try nonempty(arguments["name"])
            guard ids.count == tabs.count, tabs.allSatisfy({ chosen in
                browser.tabs.contains(where: { $0 === chosen }) && chosen.keepable && chosen.nest?.live == nil && chosen.nest?.today != true
                    && (browser.partner(of: chosen).map { ids.contains($0.id) } ?? true)
            }) else { throw NativeFailure("invalid_arguments", "Choose ordinary website tabs, including both sides of each split") }
            groups[operation] = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, ($0.kept, $0.nest)) })
            let nest = Nest(name: name)
            browser.keepTabs(tabs, in: nest)
            guard tabs.allSatisfy({ $0.kept && $0.nest === nest }) else { throw NativeFailure("verification_failed", "The tabs could not all be grouped") }
        case "tabs.move_to_folder":
            let nest = try folder(target, browser: browser)
            guard nest.live == nil, !nest.research else { throw NativeFailure("invalid_arguments", "A live folder or a search's folder fills itself; choose a folder of yours") }
            let tabs = try strings(arguments["tabs"]).map { try tab($0, browser: browser) }
            let ids = Set(tabs.map(\.id))
            guard ids.count == tabs.count, tabs.allSatisfy({ chosen in
                browser.tabs.contains(where: { $0 === chosen }) && chosen.keepable && chosen.nest?.live == nil
                    && (browser.partner(of: chosen).map { ids.contains($0.id) } ?? true)
            }) else { throw NativeFailure("invalid_arguments", "Choose ordinary website tabs in the current space, including both sides of each split") }
            guard tabs.contains(where: { $0.nest !== nest }) else { return }
            remember(operation, tabs: tabs, folders: [])
            // Move to Folder, as the column's tab menu does.
            browser.file(tabs.filter { $0.nest !== nest }, in: nest)
            guard tabs.allSatisfy({ $0.nest === nest }) else { throw NativeFailure("verification_failed", "The tabs could not all be moved into the folder") }
        case "tabs.move_out_of_folder":
            let tabs = try strings(arguments["tabs"]).map { try tab($0, browser: browser) }
            guard Set(tabs.map(\.id)).count == tabs.count, tabs.allSatisfy({ chosen in
                browser.tabs.contains(where: { $0 === chosen }) && !chosen.bench && chosen.nest != nil && chosen.nest?.live == nil
            }) else { throw NativeFailure("invalid_arguments", "Choose tabs of the current space that are in a folder; a live folder's tabs stay until live.stop") }
            remember(operation, tabs: tabs, folders: [])
            let oneStep = boolean(arguments["oneStep"]) == true
            let wanted: [UUID: Nest?] = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, oneStep && $0.nest?.today == false ? $0.nest?.parent : nil) })
            for tab in tabs {
                // Move Out of Folder, a step at a time as the column takes
                // it: each step puts it just after the folder it left.
                var steps = 0
                repeat { browser.unfile(tab); steps += 1 } while !oneStep && tab.nest != nil && steps <= Nest.deepest
            }
            guard tabs.allSatisfy({ tab in tab.nest === (wanted[tab.id] ?? nil) && browser.tabs.contains { $0 === tab } }) else {
                throw NativeFailure("verification_failed", "The tabs could not all be moved out of their folders")
            }
        case "folder.ungroup":
            let nest = try folder(target, browser: browser)
            guard nest.live == nil else { throw NativeFailure("invalid_arguments", "Stop updating this live folder with live.stop first; it is then a plain folder to ungroup") }
            let inside = browser.tabs(in: nest)
            guard !inside.isEmpty else { throw NativeFailure("invalid_arguments", "This folder has no tabs to keep") }
            remember(operation, tabs: browser.tabs.filter { $0.nest === nest }, folders: browser.folders(in: nest))
            // Remove Folder, Keep Tabs; a search's folder's Ungroup.
            if nest.research { browser.ungroupSearch(nest) } else { browser.ungroup(nest) }
            guard !browser.nests.contains(where: { $0 === nest }), inside.allSatisfy({ tab in browser.tabs.contains { $0 === tab } }) else {
                throw NativeFailure("verification_failed", "The folder could not be removed with its tabs kept")
            }
        case "pages.set_fonts":
            var fonts = browser.prefs.pageFonts
            if case .number(let v) = arguments["size"] { fonts.size = Int(v) }
            if case .number(let v) = arguments["minimum"] { fonts.minimum = Int(v) }
            if let value = string(arguments["standard"]) { fonts.standard = value }
            if let value = string(arguments["serif"]) { fonts.serif = value }
            if let value = string(arguments["sans"]) { fonts.sans = value }
            if let value = string(arguments["fixed"]) { fonts.fixed = value }
            if fonts != browser.prefs.pageFonts { browser.prefs.pageFonts = fonts }
        case "mail.set_enabled":
            let enabled = boolean(arguments["value"]) ?? false
            if browser.prefs.usesMail != enabled { browser.prefs.usesMail = enabled }
        case "mail.set_notify":
            guard let raw = string(arguments["value"]), let mode = MailNotify.Mode(rawValue: raw) else { throw NativeFailure("invalid_arguments", "off, needs or inbox") }
            let account = try mailAccount(target)
            if MailNotify.shared.mode(account) != mode { MailNotify.shared.setMode(mode, for: account) }
        case "mail.set_read_statuses":
            guard let store = MailCenter.shared.engines[try mailAccount(target)]?.store else { throw NativeFailure("not_found", "This account's mail isn't open yet") }
            let on = boolean(arguments["value"]) ?? false
            if MailReads.on(store) != on { MailReads.set(on, in: store) }
        case "live.add":
            guard let id = string(arguments["source"]), NativeActions.liveSources.contains(id) else { throw NativeFailure("invalid_arguments", "Choose a listed source") }
            var host: String? = nil
            if id == "feed" {
                guard let raw = string(arguments["address"]), let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? ""), url.host() != nil else {
                    throw NativeFailure("invalid_arguments", "A feed needs its http(s) address")
                }
                host = url.absoluteString
            } else if let git = LiveGitService.of(id) {
                guard let raw = string(arguments["address"]), let page = git.repository(raw) else {
                    throw NativeFailure("invalid_arguments", "Give this Git service's full https repository or tracker URL")
                }
                host = page.absoluteString
            } else if arguments["address"] != nil { throw NativeFailure("invalid_arguments", "Only a feed or Git repository takes an address") }
            let name = string(arguments["name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Folders.shared.browser === browser else { throw NativeFailure("conflict", "Bring this window to the front, then try again") }
            guard let nest = LiveFolders.shared.make(id, in: browser, host: host, name: name?.isEmpty == false ? name : nil) else {
                throw NativeFailure("verification_failed", "The live folder was not made")
            }
            liveMade[operation] = nest.id
        case "live.follow_repo":
            guard let repo = LiveFolders.repo(string(arguments["repository"]) ?? "") else { throw NativeFailure("invalid_arguments", "Give the repository as owner/name or its github.com address") }
            guard Folders.shared.browser === browser else { throw NativeFailure("conflict", "Bring this window to the front, then try again") }
            guard let nest = LiveFolders.shared.followRepo(repo, in: browser) else { throw NativeFailure("verification_failed", "The repository's folder was not made") }
            liveMade[operation] = nest.id
        case "live.set":
            let nest = try liveNest(target, browser: browser)
            guard var live = nest.live, let source = LiveSource.of(live.source) else { throw NativeFailure("conflict", "This folder no longer updates") }
            if case .array = arguments["show"] {
                let show = strings(arguments["show"]), lists = source.lists.map(\.id)
                guard !lists.isEmpty else { throw NativeFailure("invalid_arguments", "This folder has no lists to choose") }
                guard Set(show).isSubset(of: Set(lists)) else { throw NativeFailure("invalid_arguments", "Choose lists from: " + lists.joined(separator: ", ")) }
                live.show = lists.filter(show.contains)
            }
            if case .array = arguments["hidden"] {
                guard ["github.pulls", "github.issues", "linear"].contains(live.source) else { throw NativeFailure("invalid_arguments", "Only GitHub and Linear folders hide repositories or workspaces") }
                var seen = Set<String>()
                live.hidden = strings(arguments["hidden"]).filter { seen.insert($0).inserted }
            }
            if case .number(let days) = arguments["days"] {
                guard live.followed != nil else { throw NativeFailure("invalid_arguments", "Only a followed repository's folder has a time window") }
                live.days = Int(days)
            }
            if arguments["name"] != nil {
                let name = try nonempty(arguments["name"])
                if nest.name != name { nest.name = name }
            }
            if live != nest.live { nest.live = live; LiveFolders.shared.changed(nest, in: browser) }
            else { Folders.shared.emptyChanged(nest); browser.writeSession(now: true) }
            guard nest.live == live else { throw NativeFailure("verification_failed", "The folder did not keep the change") }
        case "live.update":
            let nest = try liveNest(target, browser: browser)
            guard browser.prefs.usesLiveFolders else { throw NativeFailure("disabled", "Live Folders are off; turn them on with settings.set.live-folders") }
            LiveFolders.shared.read(nest, in: browser)
        case "live.stop":
            let nest = try liveNest(target, browser: browser)
            if nest.live?.source == "routine", let id = nest.live?.host { Routines.shared.stopKeeping(id) }
            LiveFolders.shared.stop(nest, in: browser)
            guard nest.live == nil else { throw NativeFailure("verification_failed", "The folder still updates") }
        case "mail.disconnect":
            MailCenter.shared.disconnect(target)
            guard !MailCenter.shared.accounts.contains(target) else { throw NativeFailure("verification_failed", "Gmail could not be disconnected") }
        default: throw NativeFailure("unsupported", "This action is not supported")
        }
    }

    /// What a folder change can take back: each tab's kept state and
    /// folder, and the folders it took out of the one they were in.
    private func remember(_ operation: String, tabs: [Tab], folders: [Nest]) {
        groups[operation] = Dictionary(tabs.map { ($0.id, ($0.kept, $0.nest)) }, uniquingKeysWith: { a, _ in a })
        if !folders.isEmpty { folderParents[operation] = folders.map { ($0, $0.parent) } }
    }

    /// A connected mail account by its address.
    private func mailAccount(_ id: String) throws -> String {
        guard let account = MailCenter.shared.accounts.first(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw NativeFailure("not_found", "No such mail account")
        }
        return account
    }

    /// The corner Undo of the tabs this task closed last, while it still has
    /// one: the task's answer toast keeps it (Agents.taskEnded). Never in the chat.
    func closeUndo(session: String, in browser: Browser) -> (() -> Void)? {
        guard let receipt = changes.receipts.last(where: { $0.session == session && $0.status == "verified" }),
              receipt.action == "tabs.close", !receipt.undone, receipt.window == windowID(browser),
              let step = closeSteps[receipt.id], browser.steps.contains(where: { $0.id == step }) else { return nil }
        return { [weak browser] in browser?.undo(step: step) }
    }

    static func tabCount(_ count: Int) -> String { count == 1 ? "1 tab" : "\(count) tabs" }

    /// One page's address for duplicates: the same page with or without
    /// its fragment. Nil for a tab with no page.
    static func sameAddress(_ tab: Tab) -> String? {
        guard let url = tab.pending ?? tab.address, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.fragment = nil
        return parts.string
    }

    /// Why a tab may not be closed for the user, nil when it may: their
    /// tabs of the space on screen, a pinned or kept one only when they
    /// named it (`pinned`), never an agent's, mail's pin, a pin of every
    /// space, a live folder's or one with no page to bring back.
    static func closeRefusal(_ tab: Tab, pinned: Bool, in browser: Browser) -> String? {
        let name = "“\(tab.label)”"
        if !browser.tabs.contains(where: { $0 === tab }) { return "\(name) is in another space; show it with space.switch first" }
        if tab.bench || Agents.shared.sealed(tab) { return "\(name) is an agent's tab; close your own with close" }
        if MailPage.isMail(tab.pending ?? tab.address) { return "\(name) is Mail's pin; the user takes it away with Unpin" }
        if tab.everywhere != nil { return "\(name) is pinned in every space; the user unpins it there" }
        if tab.nest?.live != nil { return "\(name) is in a live folder, which brings it back; stop the folder with live.stop" }
        if tab.address == nil { return "\(name) has no page to bring back" }
        if !pinned, tab.pin != nil { return "\(name) is pinned: close it only when the user named it, with includePinned" }
        if !pinned, tab.kept { return "\(name) is kept in the sidebar: close it only when the user named it, with includePinned" }
        return nil
    }

    private func close(_ ids: [String], pinned: Bool, browser: Browser, operation: String) throws {
        let going = try ids.map { try tab($0, browser: browser) }
        guard Set(going.map(\.id)).count == going.count else { throw NativeFailure("invalid_arguments", "Give each tab once") }
        if let refusal = going.lazy.compactMap({ Self.closeRefusal($0, pinned: pinned, in: browser) }).first { throw NativeFailure("invalid_arguments", refusal) }
        let row = browser.tabs
        // ⌘W's way, as the hand closes several picked: a pinned or kept
        // tab is only put down, asleep where it stands, and keeps its place;
        // the loose ones close as one batch that Undo brings back.
        let resting = going.filter { $0.pin != nil || $0.kept }
        let leaving = going.filter { $0.pin == nil && !$0.kept }
        let closed = leaving.compactMap { tab in row.firstIndex { $0 === tab }.map { (tab, $0) } }.sorted { $0.1 < $1.1 }.map { tab, _ in
            (id: tab.id, name: tab.name)
        }
        let closing = Closing(batch: UUID(), space: browser.spaceID, order: row.map(\.id), closed: closed, rested: resting.map(\.id))
        let steps = browser.steps.count
        browser.close(going, batch: closing.batch)
        // ⌘Z's step is the native one (apply), not ⌘⇧T's.
        if browser.steps.count > steps, case .closed = browser.steps.last { browser.steps.removeLast() }
        closings[operation] = closing
        guard leaving.allSatisfy({ tab in !browser.tabs.contains { $0 === tab } }) else { throw NativeFailure("verification_failed", "Some tabs could not be closed") }
        guard resting.allSatisfy({ tab in browser.tabs.contains { $0 === tab } && tab.asleep }) else {
            throw NativeFailure("verification_failed", "Some pinned or kept tabs were not put to sleep in their places")
        }
        guard browser.ghosts.filter({ $0.batch == closing.batch }).count == leaving.count else {
            throw NativeFailure("verification_failed", "Some tabs were closed without a way back")
        }
    }

    /// tabs.close's Undo: the closed batch back, asleep, each where it
    /// stood and named as it was. The pinned and kept never left.
    private func reopen(_ receipt: NativeChanges.Receipt, browser: Browser) throws -> [String: Any] {
        guard !receipt.undone else { throw NativeFailure("conflict", "These tabs are already back") }
        guard let closing = closings[receipt.id] else { throw NativeFailure("conflict", "These tabs can't be brought back after a restart; History › Recently Closed has them") }
        guard browser.ghosts.contains(where: { $0.batch == closing.batch }) else {
            throw NativeFailure("conflict", "These tabs were already brought back (⇧⌘T or Recently Closed)")
        }
        if browser.spaceID != closing.space { try switchSpace(closing.space.uuidString, browser: browser) }
        let undoing = browser.undoing
        browser.undoing = true
        let back = browser.bringBack(closing.batch)
        browser.undoing = undoing
        guard back.count == closing.closed.count else { throw NativeFailure("verification_failed", "Only \(back.count) of \(closing.closed.count) tabs came back") }
        var now: [UUID: Tab] = [:]
        for (tab, (id, name)) in zip(back, closing.closed) {
            tab.name = name
            now[id] = tab
        }
        // The row as it stood, tabs opened since after the rest of their block.
        let here = Dictionary(browser.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var row = closing.order.compactMap { now[$0] ?? here[$0] }
        let placed = Set(row.map(\.id))
        row += browser.tabs.filter { !placed.contains($0.id) }
        browser.lay(row.filter { $0.pin != nil } + row.filter { $0.pin == nil && $0.kept } + row.filter { $0.pin == nil && !$0.kept })
        browser.folderBook.refresh()
        browser.writeSession(now: true)
        observe(browser)
        guard back.allSatisfy({ tab in browser.tabs.contains { $0 === tab } }) else { throw NativeFailure("verification_failed", "The tabs came back, but not all of them in this space") }
        closings.removeValue(forKey: receipt.id)
        if let step = closeSteps.removeValue(forKey: receipt.id) { browser.steps.removeAll { $0.id == step } }
        // Back by the agent's native_undo: the corner's Undo is spent.
        if browser.toaster.shown, browser.toaster.undo != nil, browser.toaster.words.hasPrefix("Closed ") { browser.toaster.dismiss() }
        changes.changed(receipt.resource)
        let result: [String: Any] = ["status": "verified", "operationId": receipt.id, "undone": true, "reopened": back.map(\.id.uuidString)]
        try changes.update(receipt.id, status: "verified", result: result, undone: true)
        return result
    }

    private func reorder(_ ids: [String], browser: Browser) throws {
        let current = browser.tabs.filter { !$0.shy && !$0.bench }
        guard ids.count == current.count, Set(ids) == Set(current.map { $0.id.uuidString }) else { throw NativeFailure("invalid_arguments", "Give every user tab in this space exactly once, in the desired order") }
        let order = try ids.map { try tab($0, browser: browser) }
        let ranks = order.map { $0.pin != nil ? 0 : $0.kept ? 1 : 2 }
        guard ranks == ranks.sorted() else { throw NativeFailure("invalid_arguments", "Pins, kept tabs and ordinary tabs must stay in their separate blocks") }
        for (index, tab) in order.enumerated() {
            if let other = browser.partner(of: tab), let at = order.firstIndex(where: { $0 === other }), abs(index - at) != 1 {
                throw NativeFailure("invalid_arguments", "Keep both sides of a split together")
            }
            if let nest = tab.nest {
                let indices = order.indices.filter { order[$0].nest === nest }
                guard (indices.last! - indices.first! + 1) == indices.count else { throw NativeFailure("invalid_arguments", "Keep each folder's tabs together") }
            }
        }
        guard ids != current.map({ $0.id.uuidString }) else { return }
        var next = order.makeIterator()
        browser.lay(browser.tabs.map { !$0.shy && !$0.bench ? next.next()! : $0 })
        browser.rememberSession()
        guard browser.tabs.filter({ !$0.shy && !$0.bench }).map({ $0.id.uuidString }) == ids else { throw NativeFailure("verification_failed", "The tab order did not keep the requested order") }
    }

    private func undo(_ id: String, session: String, browser: Browser) throws -> [String: Any] {
        guard let receipt = changes.receipt(id, session: session), let after = receipt.after else { throw NativeFailure("not_found", "No such change for this task") }
        guard receipt.window == windowID(browser) else { throw NativeFailure("conflict", "Undo this change in its original browser window") }
        // Tabs opened or moved since don't stand in the way: the closed
        // come back among them, as long as Recently Closed still has them.
        if receipt.action == "tabs.close" { return try reopen(receipt, browser: browser) }
        let arguments: [String: NativeValue]
        if receipt.action == "tabs.move", let move = moves[id] { arguments = ["tabs": .array(move.tabs.map { .string($0.now.id.uuidString) })] }
        // A site's own setting: its host is the resource's tail.
        else if ["site.set_engine", "site.set_dark"].contains(receipt.action), let colon = receipt.resource.firstIndex(of: ":") {
            arguments = ["site": .string(String(receipt.resource[receipt.resource.index(after: colon)...]))]
        } else { arguments = [:] }
        let current = try snapshot(action: receipt.action, target: receipt.target, arguments: arguments, browser: browser).1
        guard changes.canUndo(receipt, current: current), current == after else { throw NativeFailure("conflict", "This object changed after the task, or Yab restarted. Your later changes are preserved") }
        if let setting = NativeSetting.all.first(where: { "settings.set." + $0.id == receipt.action && $0.scope == "application" }) { try setting.write(browser.prefs, receipt.before) }
        else {
            switch receipt.action {
            case "space.rename", "space.set_appearance", "settings.set.color", "settings.set.grain", "settings.set.transparency", "settings.set.glass":
                guard case .object(let state) = receipt.before else { throw NativeFailure("failed", "The previous state is unavailable") }
                let space = try space(receipt.target, browser: browser)
                if receipt.action == "space.rename" { browser.renameSpace(space.id, to: string(state["name"]) ?? space.name) }
                else {
                    var paint = space.paint ?? SpacePaint(browser.prefs)
                    paint.color = string(state["color"]) ?? paint.color; paint.swatch = string(state["swatch"]) ?? paint.swatch
                    if case .number(let amount) = state["transparency"] { paint.transparency = amount }
                    if case .bool(let on) = state["glass"] { paint.glass = on }
                    if case .number(let grain) = state["grain"] { paint.grain = grain }
                    paint.colors = strings(state["colors"]); browser.setSpacePaint(space.id, to: paint)
                }
            case "space.switch": if case .string(let previous) = receipt.before { try switchSpace(previous, browser: browser) }
            case "space.create":
                guard case .object(let before) = receipt.before, case .object(let after) = after else { throw NativeFailure("failed", "The previous state is unavailable") }
                let oldIDs = Set(objects(before["spaces"]).compactMap { string($0["id"]) })
                let created = objects(after["spaces"]).compactMap { string($0["id"]) }.filter { !oldIDs.contains($0) }
                guard created.count == 1 else { throw NativeFailure("conflict", "The created space could not be identified") }
                let space = try space(created[0], browser: browser)
                // The pins every space shares stand in it too, and stay
                // (SharedPins.swift): they are no tabs of its own.
                let tabs = (space.id == browser.spaceID ? browser.tabs : browser.parked[space.id]?.tabs ?? []).filter { $0.everywhere == nil }
                guard tabs.allSatisfy({ $0.isBlank && !$0.shy && $0.pin == nil }) else { throw NativeFailure("conflict", "The new space has tabs now; it will not be deleted by Undo") }
                browser.deleteSpace(space.id)
                if boolean(before["enabled"]) == false { browser.prefs.usesSpaces = false }
            case "tabs.pin":
                guard let previous = pins[id] else { throw NativeFailure("conflict", "This pin change cannot be undone after a restart") }
                let tab = try tab(receipt.target, browser: browser)
                let available = Dictionary(browser.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                guard previous.order.allSatisfy({ available[$0] != nil }), previous.order.count == available.count else {
                    throw NativeFailure("conflict", "The tab row changed after this pin change")
                }
                tab.pin = previous.pin; tab.kept = previous.kept; tab.nest = previous.nest
                browser.lay(previous.order.compactMap { available[$0] })
                browser.pairs = previous.pairs
                Folders.shared.refresh()
                browser.writeSession(now: true)
                guard browser.tabs.map(\.id) == previous.order, browser.pairs == previous.pairs,
                      tab.pin == previous.pin, tab.kept == previous.kept, tab.nest === previous.nest else {
                    throw NativeFailure("verification_failed", "The previous pin, folder, split and row could not all be restored")
                }
                pins.removeValue(forKey: id)
            case "site.set_zoom":
                guard case .object(let before) = receipt.before, case .object(let versioned) = before["tab"],
                      case .object(let state) = versioned["state"], case .number(let zoom) = state["zoom"] else {
                    throw NativeFailure("failed", "The previous site zoom is unavailable")
                }
                let tab = try tab(receipt.target, browser: browser)
                guard let host = tab.address?.host() else { throw NativeFailure("conflict", "The tab no longer has its website") }
                tab.magnify(to: CGFloat(zoom))
                let saved: Double?
                if case .number(let value) = before["saved"] { saved = value } else { saved = nil }
                PageAppearance.rememberZoom(saved, host: host)
                guard abs(Double(tab.zoom) - zoom) < 0.004,
                      try NativeValue.read(Store.settings.object(forKey: "zoom." + host) ?? NSNull()) == before["saved"] else {
                    throw NativeFailure("verification_failed", "The previous site zoom could not be restored")
                }
            case "tabs.rename":
                guard case .object(let state) = receipt.before else { throw NativeFailure("failed", "The previous tab state is unavailable") }
                let tab = try tab(receipt.target, browser: browser)
                if receipt.action == "tabs.rename" { tab.name = string(state["name"]); browser.rememberSession() }
            case "tabs.move":
                guard let move = moves[id] else { throw NativeFailure("conflict", "This move cannot be undone after a restart") }
                let existing = Set(browser.tabs.map(\.id))
                let expected = move.tabs.map { ($0.original, $0.now.name, $0.now.pending ?? $0.now.address) }
                browser.undoMove(move)
                var returned = browser.tabs.filter { !existing.contains($0.id) }
                for (original, name, url) in expected {
                    guard let at = returned.firstIndex(where: {
                        $0.id == original || ($0.name == name && ($0.pending ?? $0.address) == url && $0.store === Spaces.store(for: move.from))
                    }) else { throw NativeFailure("verification_failed", "Some tabs could not return to their original space") }
                    returned.remove(at: at)
                }
                moves.removeValue(forKey: id)
            case "tabs.reorder", "tabs.group", "tabs.move_to_folder", "tabs.move_out_of_folder", "folder.ungroup":
                guard case .object(let before) = receipt.before else { throw NativeFailure("failed", "The previous row is unavailable") }
                let folders = receipt.action != "tabs.reorder"
                if folders {
                    guard let previous = groups[id] else { throw NativeFailure("conflict", "This folder change cannot be undone after a restart") }
                    let tabs = try previous.keys.map { try tab($0.uuidString, browser: browser) }
                    for (nest, parent) in folderParents[id] ?? [] { nest.parent = parent; Folders.shared.emptyChanged(nest) }
                    for tab in tabs { if let state = previous[tab.id] { tab.kept = state.0; tab.nest = state.1 } }
                    groups.removeValue(forKey: id)
                    folderParents.removeValue(forKey: id)
                    Folders.shared.refresh()
                }
                let ids = objects(before["tabs"]).compactMap { row -> String? in if case .object(let state) = row["state"] { return string(state["id"]) }; return nil }
                try reorder(ids, browser: browser)
                if folders { browser.writeSession(now: true) }
            case "pages.set_fonts":
                browser.prefs.pageFonts = try JSONDecoder().decode(PageFonts.self, from: JSONSerialization.data(withJSONObject: receipt.before.any))
            case "mail.set_enabled": browser.prefs.usesMail = boolean(receipt.before) ?? false
            case "site.set_engine":
                let host = String(receipt.resource.dropFirst("site-engine:".count))
                switch string(receipt.before) {
                case SiteEngineChoice.chromium.rawValue: SiteEngineSettings.shared.setOwn(.chromium, host: host)
                case SiteEngineChoice.webKit.rawValue: SiteEngineSettings.shared.setOwn(.webKit, host: host)
                default: SiteEngineSettings.shared.setOwn(nil, host: host)
                }
                EngineRulesModel.shared.reload()
            case "site.set_dark":
                setDark(string(receipt.before) ?? "", host: String(receipt.resource.dropFirst("site-dark:".count)))
            case "site.keep_awake": AwakeSites.shared.restore(strings(receipt.before))
            case "links.set_route", "links.remove_route", "links.set_default_space":
                guard case .object(let state) = receipt.before else { throw NativeFailure("failed", "The previous rules are unavailable") }
                let rules = try objects(state["rules"]).map { rule -> LinkRoute in
                    guard let site = string(rule["site"]), let space = string(rule["space"]).flatMap(Self.routeID) else {
                        throw NativeFailure("failed", "The previous rules are unavailable")
                    }
                    return LinkRoute(site: site, space: space, opensInMain: boolean(rule["skipSmallWindow"]) == true ? true : nil)
                }
                LinkRoutes.shared.restore(rules, defaultSpace: string(state["defaultSpace"]).flatMap(Self.routeID))
            case "mail.set_notify":
                if let raw = string(receipt.before), let mode = MailNotify.Mode(rawValue: raw) { MailNotify.shared.setMode(mode, for: try mailAccount(receipt.target)) }
            case "mail.set_read_statuses":
                if let store = MailCenter.shared.engines[try mailAccount(receipt.target)]?.store { MailReads.set(boolean(receipt.before) ?? false, in: store) }
            case "live.set":
                guard case .object(let state) = receipt.before else { throw NativeFailure("failed", "The previous folder is unavailable") }
                let nest = try liveNest(receipt.target, browser: browser)
                guard var live = nest.live else { throw NativeFailure("conflict", "This folder no longer updates") }
                live.show = strings(state["show"]); live.hidden = strings(state["hidden"])
                if case .number(let days) = state["days"] { live.days = Int(days) } else { live.days = nil }
                nest.name = string(state["name"]) ?? nest.name
                if live != nest.live { nest.live = live; LiveFolders.shared.changed(nest, in: browser) }
                else { Folders.shared.emptyChanged(nest); browser.writeSession(now: true) }
                guard liveState(nest) == receipt.before else { throw NativeFailure("verification_failed", "The folder's previous settings could not be restored") }
            default: throw NativeFailure("unsupported", "This action cannot be undone")
            }
        }
        synchronizeApplication(browser)
        changes.changed(receipt.resource)
        let result: [String: Any] = ["status": "verified", "operationId": id, "undone": true]
        try changes.update(id, status: "verified", result: result, undone: true)
        browser.announce("Change undone", mark: "arrow.uturn.backward")
        return result
    }

    private func connect(_ receipt: NativeChanges.Receipt, arguments: [String: NativeValue], browser: Browser, session: Agents.Session) throws {
        let email = string(arguments["email"]) ?? (receipt.target == "app" ? nil : receipt.target)
        if let email, MailCenter.shared.accounts.contains(email.lowercased()), MailCenter.shared.status[email.lowercased()]?.signedOut != true, receipt.action != "mail.reconnect" {
            try changes.update(receipt.id, status: "verified", result: ["status": "verified", "operationId": receipt.id, "account": email.lowercased(), "alreadyConnected": true]); return
        }
        if let problem = MailCenter.shared.gmailConnectionProblem(expectedAccount: email) {
            throw NativeFailure("connection_unavailable", problem)
        }
        guard MailClient.configured != nil else { throw NativeFailure("not_configured", "This build has no Google client for Mail") }
        guard !MailCenter.shared.connecting else { throw NativeFailure("busy", "Another Gmail connection is already in progress") }
        let attempt = UUID()
        mailOwners[receipt.id] = attempt
        try changes.update(receipt.id, status: "running", result: ["status": "running", "operationId": receipt.id, "step": "waiting_for_user", "message": "Choose your Google account and grant access in the sign-in window"])
        browser.prefs.usesMail = true
        MailCenter.shared.connect(in: browser, hint: email, outside: true, expectedAccount: email, attempt: attempt,
                                  authorized: { [weak self] in Self.writable(session) && self?.mailOwners[receipt.id] == attempt }) { [weak self] result in
            guard let self, mailOwners.removeValue(forKey: receipt.id) == attempt,
                  changes.receipt(receipt.id, session: receipt.session)?.status != "cancelled" else { return }
            switch result {
            case .success(let account):
                try? changes.update(receipt.id, status: "verified", result: ["status": "verified", "operationId": receipt.id,
                    "account": account, "connected": true, "syncing": MailCenter.shared.status[account]?.synced == nil,
                    "message": "Gmail is connected. Mail may still be downloading."])
            case .failure: finishFailure(receipt, NativeFailure("connection_failed", "Gmail was not connected. The account or granted access may differ from the request"))
            }
        }
    }

    private func cancel(_ receipt: NativeChanges.Receipt, browser: Browser) {
        guard ["prepared", "running", "needs_user"].contains(receipt.status) else { return }
        pending.removeValue(forKey: receipt.id)
        if let attempt = mailOwners.removeValue(forKey: receipt.id) { MailCenter.shared.cancelConnect(in: browser, attempt: attempt) }
        for tab in (BrowserWindows.shared.browsers + [browser]).flatMap(\.tabs) {
            if case .native(_, let id) = tab.permit?.kind, id == receipt.id { Agents.shared.answer(tab, yes: false) }
        }
        finishFailure(receipt, NativeFailure("cancelled", "The operation was cancelled"))
    }

    private func finishFailure(_ receipt: NativeChanges.Receipt, _ failure: NativeFailure) {
        var reply = failure.reply; reply["operationId"] = receipt.id
        if ["verification_failed", "journal_unavailable", "connection_failed"].contains(failure.code) { reply["effectsMayHaveApplied"] = true; reply["message"] = "Read current native state before another attempt" }
        let status = failure.code == "cancelled" ? "cancelled" : failure.code == "journal_unavailable" ? "unknown_outcome" : reply["status"] as? String ?? "failed"
        reply["status"] = status
        try? changes.update(receipt.id, status: status, result: reply)
    }

    /// Air Traffic Control as an agent reads it: rules in their order and
    /// the fallback, spaces by id, the recent-space token as "recent".
    private func routesState() -> NativeValue {
        let routes = LinkRoutes.shared
        return .object(["rules": .array(routes.routes.map {
                            .object(["site": .string($0.site), "space": .string(Self.routeToken($0.space)), "skipSmallWindow": .bool($0.opensInMain == true)])
                        }),
                        "defaultSpace": .string(routes.defaultSpace.map(Self.routeToken) ?? "")])
    }

    static func routeToken(_ space: UUID) -> String { space == LinkRoutes.recentSpaceID ? "recent" : space.uuidString }
    static func routeID(_ token: String) -> UUID? { token == "recent" ? LinkRoutes.recentSpaceID : UUID(uuidString: token) }

    /// The host as Settings › General's engine card takes it: exact, www kept.
    private func engineHost(_ value: NativeValue?) throws -> String {
        guard let host = string(value).flatMap(EngineSiteEditing.host(from:)) else { throw NativeFailure("invalid_arguments", "Give a site such as www.youtube.com") }
        return host
    }

    /// The host as dark pages keys it: lowercased, without www.
    private func darkHost(_ value: NativeValue?) throws -> String {
        guard let text = string(value), let host = PageScripts.host(of: URL(string: text.contains("://") ? text : "https://" + text)),
              host.contains(".") else { throw NativeFailure("invalid_arguments", "Give a site such as github.com") }
        return host
    }

    private func awakeSite(_ value: NativeValue?) throws -> String {
        guard let site = string(value).flatMap(AwakeSites.site(from:)) else { throw NativeFailure("invalid_arguments", "Give a site such as web.whatsapp.com") }
        return site
    }

    /// A site's word for dark pages: "off" keeps it light, "yes" dark with
    /// the mode Off, empty none.
    private func setDark(_ word: String, host: String) {
        if word.isEmpty { Store.settings.removeObject(forKey: DarkPages.choiceKey(host)) }
        else { Store.settings.set(word, forKey: DarkPages.choiceKey(host)) }
        NotificationCenter.default.post(name: DarkPages.changed, object: host)
    }

    /// What the agent typed, as Settings' rule card reads it.
    private func routeSite(_ value: NativeValue?) throws -> String {
        guard let site = string(value).flatMap(LinkRoutes.site(from:)) else {
            throw NativeFailure("invalid_arguments", "Give a site such as linear.app, docs.google.com/spreadsheets or a *pattern*")
        }
        return site
    }

    private func routeSpace(_ token: String, browser: Browser) throws -> UUID {
        guard let id = Self.routeID(token), id == LinkRoutes.recentSpaceID || browser.spaces.contains(where: { $0.id == id }) else {
            throw NativeFailure("not_found", "No such space; use a space id from native_context or recent")
        }
        return id
    }

    private func string(_ value: NativeValue?) -> String? { if case .string(let text) = value { return text }; return nil }
    private func boolean(_ value: NativeValue?) -> Bool? { if case .bool(let on) = value { return on }; return nil }
    private func strings(_ value: NativeValue?) -> [String] { if case .array(let values) = value { return values.compactMap { string($0) } }; return [] }
    private func objects(_ value: NativeValue?) -> [[String: NativeValue]] { if case .array(let values) = value { return values.compactMap { if case .object(let object) = $0 { return object }; return nil } }; return [] }
    private func nonempty(_ value: NativeValue?) throws -> String {
        guard let name = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { throw NativeFailure("invalid_arguments", "Give a nonempty name") }
        return name
    }
}
