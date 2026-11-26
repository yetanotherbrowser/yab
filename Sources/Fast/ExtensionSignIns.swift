import Foundation
import WebKit
import Combine

// Extensions follow sign-ins, as Arc's and Dia's follow the Chrome profile.
//
// A space with sign-ins of its own is another profile: its own cookies, and
// its own extensions, installed there and nowhere else. Spaces that share
// the first space's sign-ins share its extensions. Each sign-in is an
// `Extensions` of its own: a list, a WebKit controller with storage of its
// own (storage.local, rules, by the space's id), the sign-in's store for its
// pages' data, and only that sign-in's tabs told to it. A page is given the
// controller of the store it is made in (`Extensions.attach`), so content
// scripts, popups and messages of one sign-in's extensions never reach
// another's pages.
//
// Before this, every extension ran in every space. The first launch that
// splits them gives each space with sign-ins of its own a copy of the list
// and of what the extensions kept in WebKit's storage, so nothing that
// worked there stops (`splitOnce`). What an extension's own pages kept in
// the shared store (IndexedDB, a password manager's session) isn't
// copied: WebKit's stores can't be, and in another profile it starts
// signed out, as it does in Chrome.
//
// One copy of each extension's files serves every sign-in (Extensions/<id>):
// installed in two, removed from one, the other keeps it; updated once,
// both run the new version.

@available(macOS 15.4, *)
@MainActor
extension Extensions {
    /// The spaces' own sign-ins' extensions made so far, by space id.
    private static var others: [UUID: Extensions] = [:]
    private static var making: Set<UUID> = []
    /// Made before the shared ones started: started with them.
    private static var unstarted: [Extensions] = []

    /// Any sign-in's list or install under way changed.
    static let listsChanged = PassthroughSubject<Void, Never>()

    /// Every sign-in's extensions made so far, the shared ones first.
    static var all: [Extensions] {
        [shared] + others.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { others[$0] }
    }

    /// The sign-in a space's pages are kept in: nil for the shared one,
    /// else the space's own id (`Spaces.store(for:)`).
    static func signIn(of space: UUID) -> UUID? {
        if space == Space.mailID || space == Space.pinsID || Spaces.sharing.contains(space) { return nil }
        let profile = Spaces.signIn(of: space)
        return profile == Space.firstID ? nil : profile
    }

    /// A sign-in's extensions by the sign-in: the shared ones for nil.
    static func instance(_ signIn: UUID?) -> Extensions {
        signIn.map(of(signIn:)) ?? shared
    }

    /// The extensions of the space's sign-in.
    static func of(space: UUID) -> Extensions {
        signIn(of: space).map(of(signIn:)) ?? shared
    }

    /// The extensions of the space a window shows: its buttons, its keys,
    /// where the store installs.
    static func of(_ browser: Browser?) -> Extensions {
        guard let browser else { return shared }
        return of(space: browser.spaceID)
    }

    /// The extensions a page of this store runs: a space's own store's,
    /// or the shared ones for any other (a private tab's, an agent's).
    static func of(store: WKWebsiteDataStore) -> Extensions {
        signIn(of: store).map(of(signIn:)) ?? shared
    }

    /// The sign-in a store is, without making its extensions: nil for the
    /// shared one and any store no space has as its own.
    static func signIn(of store: WKWebsiteDataStore) -> UUID? {
        guard let id = Spaces.madeStores.first(where: { $0.value === store })?.key else { return nil }
        return signIn(of: id)
    }

    /// The extensions a tab's page runs.
    static func of(tab: Tab) -> Extensions {
        all.first { $0.seen(tab) } ?? shared
    }

    /// Site Controls' extensions for `tab` in `browser`: a small window's page runs its own sign-in's.
    static func of(_ browser: Browser?, page tab: Tab?) -> Extensions {
        if let browser, let tab, browser.outside.contains(where: { $0 === tab }) { return of(tab: tab) }
        return of(browser)
    }

    /// The extensions whose controller loaded this context.
    static func owner(of context: WKWebExtensionContext) -> Extensions {
        all.first { $0.controller === context.webExtensionController } ?? shared
    }

    /// The extensions of the window in front: where Settings, a key and the
    /// store act when nothing names a window.
    static var here: Extensions { of(BrowserWindows.shared.activeBrowser ?? shared.browser) }

    /// A space's own sign-in's, made and started the first time it is asked for.
    static func of(signIn id: UUID) -> Extensions {
        if let made = others[id] { return made }
        // Asked again while it is being made (something it tells asks
        // which sign-in is on screen): not made twice, over and over.
        guard !making.contains(id) else { return shared }
        making.insert(id)
        let made = Extensions(signIn: id)
        making.remove(id)
        others[id] = made
        if let browser = shared.browser { made.startSignIn(in: browser) } else { unstarted.append(made) }
        return made
    }

    /// The shared ones started: those made before them start now.
    static func startUnstarted(in browser: Browser) {
        let waiting = unstarted
        unstarted = []
        for made in waiting { made.startSignIn(in: browser) }
    }

    // MARK: at rest on Chromium

    private static var resting: [Extensions] = []
    private static var webKitPageSeen = false

    /// With Chromium the default, the pages have the CEF profile's extensions,
    /// and these would only run beside them: a second worker of each, a second
    /// of every reminder and sync, memory for nothing. They load when a page of
    /// the default's own WebKit first appears (a rule, memory, a choice).
    static var restsForChromium: Bool { PageEngineFactory.chromiumEnabled && !webKitPageSeen }

    static func rest(_ extensions: Extensions) { resting.append(extensions) }

    /// Those adopted into this store's Chromium profile, which stay asleep
    /// here for good while Chromium is on: a WebKit page has the Chromium copy
    /// bridged to it, and a WebKit copy woken beside it would bring back the
    /// storage and account from before, after a sign-out or removal there.
    static func restingInChromium(_ store: WKWebsiteDataStore) -> Set<String> {
        guard PageEngineFactory.chromiumEnabled, store.isPersistent else { return [] }
        return ChromiumExtensions.inChromium(profile: ChromiumPersistentProfiles.profile(store: store, placement: Space.firstID))
    }

    /// Removed or turned off in Chromium: off in the WebKit list too, so a
    /// WebKit copy never runs what the person took away, Chromium on or off.
    static func offInChromium(_ id: String, signIn: UUID?) {
        let made: Extensions?
        if let signIn { made = others[signIn] } else { made = shared }
        if let made, made.installed.contains(where: { $0.id == id }) {
            if made.installed.contains(where: { $0.id == id && $0.enabled }) { made.setEnabled(id, false) }
            return
        }
        guard var saved = unread(signIn), let index = saved.firstIndex(where: { $0.id == id && $0.enabled }) else { return }
        saved[index].enabled = false
        try? JSONEncoder().encode(saved).write(to: list(of: signIn), options: .atomic)
    }

    /// A web page on WebKit is being built, one of those extensions act on.
    static func webKitPageMade() {
        guard !webKitPageSeen else { return }
        webKitPageSeen = true
        let waking = resting
        resting = []
        // What Chromium changed comes first: they start where it left off.
        for extensions in waking {
            inTurn {
                await ChromiumExtensions.bringStorageHome(signIn: extensions.signIn)
                await extensions.launch()
            }
        }
    }

    // MARK: one sign-in at a time

    private static var turn: Task<Void, Never>?
    private static var launched = false
    private static var waiting: [@MainActor () async -> Void] = []

    /// Loading, one sign-in after another: started all at once, WebKit
    /// fails some workers and never tries them again. The shared ones go
    /// first (`first`), and the others wait for them.
    static func inTurn(first: Bool = false, _ work: @escaping @MainActor () async -> Void) {
        guard launched || first else { return waiting.append(work) }
        let before = turn
        turn = Task { @MainActor in
            await before?.value
            await work()
        }
    }

    /// Sign-ins whose pages wait for them (`whenFirstPagesReady`), loaded
    /// between two extensions of the sign-in loading now, rather than
    /// after all of them: the shared ones' launch, a dozen extensions
    /// with a worker each, takes seconds.
    private static var promoted: [Extensions] = []

    static func promote(_ waiting: Extensions) {
        guard !promoted.contains(where: { $0 === waiting }) else { return }
        promoted.append(waiting)
        // Nothing loading to take it in between: a turn of its own.
        if launched { inTurn { await launchPromoted() } }
    }

    /// Whichever sign-ins have pages waiting, loaded now; one not started
    /// yet, its windows not followed, keeps its own turn.
    static func launchPromoted() async {
        while let next = promoted.first {
            promoted.removeFirst()
            if next.browser != nil { await next.launch() }
        }
    }

    /// The shared ones' launch is under way: the others' follow it.
    static func sharedStarted() {
        launched = true
        let queued = waiting
        waiting = []
        for work in queued { inTurn(work) }
    }

    // MARK: where each keeps its things

    /// WebKit's configuration for a sign-in's controller: the shared one's
    /// as it always was, a space's own by the space's id.
    static func configuration(for signIn: UUID?) -> WKWebExtensionController.Configuration {
        guard let signIn else {
            return Store.testing && !Store.ownContainer ? .init(identifier: Store.probeStore(2)) : .default()
        }
        return .init(identifier: signIn)
    }

    /// Where WebKit keeps a sign-in's extensions' storage, a folder for each.
    static func storageRoot(of signIn: UUID?) -> URL? {
        let key = "_storageDirectoryPath"
        let configuration = configuration(for: signIn)
        guard configuration.responds(to: NSSelectorFromString(key)), let path = configuration.value(forKey: key) as? String else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The list on disk of a sign-in, as last saved, or nil.
    static func unread(_ signIn: UUID?) -> [Installed]? {
        (try? Data(contentsOf: list(of: signIn))).flatMap { try? JSONDecoder().decode([Installed].self, from: $0) }
    }

    /// The sign-ins that have a list on disk, made or not.
    static var listed: [UUID] {
        let files = (try? FileManager.default.contentsOfDirectory(at: signIns, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
    }

    /// Whether a sign-in other than this one has it installed.
    static func installedElsewhere(_ id: String, than signIn: UUID?) -> Bool {
        // The shared list as saved: a sign-in erased at launch is forgotten
        // before the shared one is made.
        if signIn != nil, (unread(nil) ?? []).contains(where: { $0.id == id }) { return true }
        for other in listed where other != signIn {
            let list = others[other]?.installed ?? unread(other) ?? []
            if list.contains(where: { $0.id == id }) { return true }
        }
        return false
    }

    /// Every sign-in's installed extensions, each once: the store is asked
    /// about each folder once.
    static func everyInstalled() -> [Installed] {
        var seen = Set<String>()
        var out: [Installed] = []
        let lists = [shared.installed] + listed.map { others[$0]?.installed ?? unread($0) ?? [] }
        for list in lists {
            for item in list where seen.insert(item.id).inserted { out.append(item) }
        }
        return out
    }

    /// An update to its folder written into the lists of the sign-ins not
    /// made this run, which read it when they start.
    static func updatedUnread(_ id: String, version: String, grants: [String]) {
        for signIn in listed where others[signIn] == nil {
            guard var list = unread(signIn), let index = list.firstIndex(where: { $0.id == id }) else { continue }
            list[index].version = version
            list[index].permissions = grants
            try? JSONEncoder().encode(list).write(to: Extensions.list(of: signIn), options: .atomic)
        }
    }

    // MARK: the split, once

    static let splitKey = "extensions.signIns.split"

    /// The first launch with extensions per sign-in: each space that has
    /// sign-ins of its own then keeps every extension it ran, with what
    /// each kept in WebKit's storage. Spaces given sign-ins of their own
    /// later start with none, as a new Chrome profile does.
    static func splitOnce() {
        guard !Store.settings.bool(forKey: splitKey) else { return }
        Store.settings.set(true, forKey: splitKey)
        let own = Array(Set(Spaces.read().filter(\.ownSignIns).map(\.profileID)))
        guard let data = try? Data(contentsOf: list(of: nil)),
              let list = try? JSONDecoder().decode([Installed].self, from: data), !list.isEmpty else { return }
        split(list, into: own, lists: signIns, storage: storageRoot(of: nil), root: storageRoot)
    }

    /// The list and each extension's storage put in each sign-in that has
    /// none yet, its list in `lists`. `root` finds a sign-in's storage
    /// folder (tests give their own).
    nonisolated static func split(_ list: [Installed], into spaces: [UUID], lists: URL, storage from: URL?, root: (UUID) -> URL?) {
        let files = FileManager.default
        try? files.createDirectory(at: lists, withIntermediateDirectories: true)
        for space in spaces {
            let file = lists.appendingPathComponent(space.uuidString + ".json")
            guard !files.fileExists(atPath: file.path) else { continue }
            // Fresh to the list: nothing in it is new to anybody.
            guard let data = try? JSONEncoder().encode(list), (try? data.write(to: file, options: .atomic)) != nil else { continue }
            guard let from, let to = root(space) else { continue }
            try? files.createDirectory(at: to, withIntermediateDirectories: true)
            // Each extension's folder (storage.local, its rules) and the
            // mark that its stale origins were swept. Cloned, on APFS.
            for item in (try? files.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? [] {
                let target = to.appendingPathComponent(item.lastPathComponent)
                guard list.contains(where: { $0.id == item.lastPathComponent }) || item.lastPathComponent == "StaleExtensionOriginsCleared",
                      !files.fileExists(atPath: target.path) else { continue }
                try? files.copyItem(at: item, to: target)
            }
        }
    }

    /// Two spaces joined into one sign-in (Spaces.link): what the one that
    /// gave up its own had, in the list of the one it signs in with. Before
    /// either is read. The list and storage it had stay where they were.
    static func merge(signIn from: UUID, into to: UUID) {
        guard let root = storageRoot(of: from), let target = storageRoot(of: to) else { return }
        merge(list: list(of: from), into: list(of: to), storage: root, to: target)
    }

    /// The extensions of one list missing from the other, each with its
    /// storage, none of what the other has touched.
    nonisolated static func merge(list from: URL, into to: URL, storage: URL, to target: URL) {
        let files = FileManager.default
        guard let data = try? Data(contentsOf: from), let theirs = try? JSONDecoder().decode([Installed].self, from: data) else { return }
        let mine = (try? Data(contentsOf: to)).flatMap { try? JSONDecoder().decode([Installed].self, from: $0) } ?? []
        let have = Set(mine.map(\.id))
        let coming = theirs.filter { !have.contains($0.id) }
        guard !coming.isEmpty, let merged = try? JSONEncoder().encode(mine + coming) else { return }
        try? files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? merged.write(to: to, options: .atomic)) != nil else { return }
        try? files.createDirectory(at: target, withIntermediateDirectories: true)
        for item in coming {
            let there = target.appendingPathComponent(item.id)
            let here = storage.appendingPathComponent(item.id)
            if files.fileExists(atPath: here.path), !files.fileExists(atPath: there.path) { try? files.copyItem(at: here, to: there) }
        }
    }

    static func list(of signIn: UUID?) -> URL {
        guard let signIn else { return folder.appendingPathComponent("installed.json") }
        return signIns.appendingPathComponent(signIn.uuidString + ".json")
    }

    static var signIns: URL { folder.appendingPathComponent("Sign-Ins", isDirectory: true) }

    // MARK: a sign-in gone

    /// A space's own sign-in erased (Spaces.erase): its extensions let go
    /// of, its list, storage and the folders of the ones nobody else has.
    static func forget(signIn id: UUID) {
        let made = others.removeValue(forKey: id)
        unstarted.removeAll { $0 === made }
        let list = made?.installed ?? unread(id) ?? []
        made?.shutDown()
        let files = FileManager.default
        try? files.removeItem(at: Extensions.list(of: id))
        try? files.removeItem(at: signIns.appendingPathComponent(id.uuidString, isDirectory: true))
        if let root = storageRoot(of: id) { try? files.removeItem(at: root) }
        for item in list where !installedElsewhere(item.id, than: id) {
            try? files.removeItem(at: Extensions.folder(for: item.id))
        }
    }
}

/// The extensions of the window in front, for what draws them: the buttons
/// beside the address, the puzzle's list, Settings. It changes with the
/// space on screen and the window in front, and says so for whichever
/// sign-in's extensions it is, as they change.
@available(macOS 15.4, *)
@MainActor
final class ExtensionsHere: ObservableObject {
    static let shared = ExtensionsHere()

    @Published private(set) var current: Extensions = .shared
    private var following: AnyCancellable?
    private var focus: AnyCancellable?

    private init() {
        following = current.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        focus = BrowserWindows.shared.$focusedID.removeDuplicates().sink { _ in
            DispatchQueue.main.async { ExtensionsHere.shared.refresh() }
        }
    }

    /// Looked at again: a space switched, a window came to the front, a
    /// space's sign-ins changed.
    func refresh() {
        let now = Extensions.here
        guard now !== current else { return }
        current = now
        following = now.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
