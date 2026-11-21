import CryptoKit
import UIKit
import WebKit
import os

/// The ad blocker, as Yab on the Mac has it (Sources/Fast/Shield.swift): the
/// lists uBlock Origin reads, turned into WebKit's content rule lists by the
/// Mac's own Filters and ShieldLists, which this app compiles as they are.
/// WebKit enforces them before a request is made and before a stylesheet is
/// applied, so a page costs nothing more at run time.
///
/// Nothing of it is on the way to the first page. At launch the lists are
/// looked up where WebKit stored them compiled, a few milliseconds; a page
/// that opens before they are found, or before the very first build, loads
/// unblocked and gets them from its next request. The lists are fetched
/// again once a week while Yab is in front, and converted and compiled off
/// the main thread only when something in them changed. Before any list has
/// arrived (and in test worlds, which never fetch) the short list built in
/// stands in.
///
/// Each page's web view has a controller of its own (WebPool), so the lists
/// go on or off for the site it is heading to, as each tab's do on the Mac.
@MainActor
@Observable
final class Shield {
    /// Smaller compiler batches bound the first build's memory on iPhone.
    /// The shared converter still supplies every exception to each batch.
    nonisolated static let perList = 50_000
    nonisolated static let schema = ShieldLists.schema * 100 + 4
    /// The lists' !#if words that hold on iPhone (Filters.Preparser).
    nonisolated static let env = Filters.webKit.union(["env_mobile"])
    static let shared = Shield(folder: Shield.folder(), fetches: Shield.fetches())

    /// Where the lists, their compiled form and the record of the build are
    /// kept: inside an isolated profile when a test names one, a folder of
    /// its own in any other test run, so a test never touches the person's.
    static func folder(_ options: LaunchOptions = .current) -> URL {
        if let profile = options.profileDirectory, !profile.isEmpty {
            return URL(fileURLWithPath: profile, isDirectory: true).appendingPathComponent("Shield", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(options.isTestRun ? "Shield-test" : "Shield", isDirectory: true)
    }

    /// Test runs never fetch: their pages are fixtures and their runs are
    /// measured. -YabShieldFetch YES lets a measuring run fetch anyway.
    static func fetches(_ options: LaunchOptions = .current, arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        if let i = arguments.firstIndex(of: "-YabShieldFetch"), i + 1 < arguments.count {
            return ["yes", "true", "1"].contains(arguments[i + 1].lowercased())
        }
        return !options.isTestRun
    }

    /// The one time building the lists didn't work and nothing is blocking:
    /// worth saying under the switch, which otherwise says "on" for nothing.
    private(set) var trouble: String?

    /// The compiled lists, put on every page that blocks, in this order.
    @ObservationIgnored private(set) var lists: [WKContentRuleList] = []

    /// The lists' scriptlets as one script for every page that gets the
    /// lists (Shield+Scriptlets), nil for none.
    @ObservationIgnored private(set) var scriptlets: WKUserScript?
    @ObservationIgnored private var scriptletSource: String?
    @ObservationIgnored private var scriptletAsk = 0
    /// Off with YAB_SHIELD_SCRIPTLETS=0, to measure them.
    @ObservationIgnored var scriptletsAllowed = Shield.scriptletsAllowed()
    /// How many times a page's script was put on or taken off: for tests.
    @ObservationIgnored private(set) var placements = 0

    /// Whether a page of this site, private or not, gets the lists: the app
    /// answers from Settings, Site Settings and the Mac's (AppModel.blocksAds).
    @ObservationIgnored var wants: @MainActor (_ host: String?, _ isPrivate: Bool) -> Bool = { _, _ in true }

    let folder: URL
    let fetches: Bool
    /// How long after launch the first look for newer lists waits: the first
    /// pages are in by then.
    @ObservationIgnored var refreshDelay: Duration = .seconds(30)

    private let store: WKContentRuleListStore?
    private let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "shield")

    init(folder: URL, fetches: Bool) {
        self.folder = folder
        self.fetches = fetches
        // Made here, on the main thread, and only then handed to the build's
        // own task: WebKit's classes are the main thread's, and a store made
        // elsewhere is not one to share with the pages.
        let compiled = folder.appendingPathComponent("compiled", isDirectory: true)
        try? FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: compiled)
    }

    // MARK: - pages

    /// Every controller seen, weakly, each with the lists on it now and the
    /// site it is for. A navigation that changes neither costs nothing:
    /// adding or taking off a list is a message to the web process, which
    /// builds the list's stylesheet again when it is added.
    private let attached = NSHashTable<WKUserContentController>.weakObjects()

    /// Kept on the controller itself, so it goes when the controller does,
    /// and with it the lists it holds.
    private final class Fitting {
        var lists: [WKContentRuleList] = []
        var script: WKUserScript?
        var host: String?
        var isPrivate = false
    }
    private nonisolated(unsafe) static var fittingKey: UInt8 = 0

    private func fitting(_ controller: WKUserContentController) -> Fitting {
        if let fitting = objc_getAssociatedObject(controller, &Shield.fittingKey) as? Fitting { return fitting }
        let fitting = Fitting()
        objc_setAssociatedObject(controller, &Shield.fittingKey, fitting, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        attached.add(controller)
        return fitting
    }

    /// Before each page: the lists go on or off for the site this view is
    /// heading to. A rule list is enforced from the moment it is added, so
    /// doing this at the navigation makes "off for this site" true for the
    /// whole page rather than for its second half.
    func fit(_ controller: WKUserContentController, host: String?, isPrivate: Bool) {
        let fitting = fitting(controller)
        fitting.host = host
        fitting.isPrivate = isPrivate
        let on = wants(host, isPrivate)
        let want = on ? lists : []
        let have = fitting.lists
        if have.count != want.count || zip(have, want).contains(where: { $0 !== $1 }) {
            for list in have where !want.contains(where: { $0 === list }) { controller.remove(list) }
            for list in want where !have.contains(where: { $0 === list }) { controller.add(list) }
            fitting.lists = want
        }
        // A user script reaches only the next document, so a page's script
        // follows from its next load, as the per-site switch's reload does.
        let script = on ? scriptlets : nil
        if fitting.script !== script {
            Shield.place(script, replacing: fitting.script, in: controller)
            fitting.script = script
            placements += 1
        }
    }

    /// A new page's controller, before its other scripts: the scriptlets go
    /// on first with nothing to move. The lists wait for the view (fit).
    func prepare(_ controller: WKUserContentController, host: String?, isPrivate: Bool) {
        guard let scriptlets, controller.userScripts.isEmpty, wants(host, isPrivate) else { return }
        controller.addUserScript(scriptlets)
        fitting(controller).script = scriptlets
    }

    /// Every user script was taken off this controller (WebPool.adopt):
    /// the next fit puts the scriptlets back.
    func scriptsRemoved(from controller: WKUserContentController) {
        fitting(controller).script = nil
    }

    /// Switched on or off for every page already open, or the lists swapped
    /// for newer ones: from each page's next request.
    func apply() {
        for controller in attached.allObjects {
            let fitting = fitting(controller)
            fit(controller, host: fitting.host, isPrivate: fitting.isPrivate)
        }
    }

    /// The lists on a page now, by identifier: for tests.
    func identifiers(on controller: WKUserContentController) -> [String] {
        fitting(controller).lists.compactMap(\.identifier)
    }

    // MARK: - launch

    /// What WebKit was last given, kept beside the lists: which build
    /// (identifiers carry it, so a new build never overwrites the lists open
    /// pages hold), how many, from which texts, by which Filters.
    struct Made: Codable, Equatable {
        var schema: Int
        var build: Int
        var count: Int
        var rules: Int
        var fetched: Date?
        /// The texts the lists were made from, `base` first: the same digest
        /// is the same lists, never compiled twice.
        var digest: String?
        /// Lists that failed to build, by name, with a digest of the text
        /// that failed: left out until a fetch brings a different text.
        var left: [String: String]?
        /// Not even `base` built: not tried again until the lists change.
        var failed: Bool?
    }

    private var madeFile: URL { folder.appendingPathComponent("made.json") }
    private var reportFile: URL { folder.appendingPathComponent("report.json") }

    private(set) var made: Made? {
        get { (try? Data(contentsOf: madeFile)).flatMap { try? JSONDecoder().decode(Made.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { try? data.write(to: madeFile, options: .atomic) }
            else { try? FileManager.default.removeItem(at: madeFile) }
        }
    }

    @ObservationIgnored private var started = false
    @ObservationIgnored private var busy = 0
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    /// How many times the lists were compiled, and found compiled, since
    /// this Shield was made: what the cache saves, for tests.
    @ObservationIgnored private(set) var compiles = 0
    @ObservationIgnored private(set) var lookups = 0
    /// How the last build went, step by step, for measuring.
    @ObservationIgnored private(set) var report: [String: Any] = [:]

    /// At launch: the compiled lists looked up, the one thing done now; a
    /// build only if they are missing or made from other texts.
    func start() {
        guard !started else { return }
        started = true
        let made = made
        if let made, made.count > 0, made.schema == Shield.schema {
            hold()
            let t0 = CACurrentMediaTime()
            look(made.build, made.count) { [weak self] found in
                guard let self else { return }
                report["lookup_ms"] = Int((CACurrentMediaTime() - t0) * 1000)
                if let found {
                    lookups += 1
                    loadScriptlets(made.build)
                    install(found)
                }
                // Missing (an iOS update can retire WebKit's compiled form)
                // or made from other texts: made again, whatever was found
                // blocking meanwhile.
                rebuild(unless: found == nil ? nil : made.digest)
                letGo()
            }
        } else if made?.failed == true, made?.schema == Shield.schema {
            trouble = Shield.failure
        } else {
            rebuild(unless: nil)
        }
        scheduleRefresh()
    }

    /// "Try Again": compiled again from the texts kept, failed ones included.
    func compile() {
        if var made {
            made.left = nil
            made.failed = nil
            self.made = made
        }
        rebuild(unless: nil)
    }

    nonisolated static let failure = "The ad blocker's lists didn't build"

    /// Until the lookups, builds and fetches under way are done: for tests,
    /// and a named state that needs the page blocked from its first request.
    func settled() async {
        guard busy > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func hold() { busy += 1 }

    /// A build's table, read and made a script off the main thread, then
    /// on every page that blocks.
    private func loadScriptlets(_ build: Int) {
        guard scriptletsAllowed else { return }
        scriptletAsk += 1
        let ask = scriptletAsk
        let file = Shield.scriptletsFile(build, in: folder)
        hold()
        Task.detached(priority: .userInitiated) {
            let source = (try? String(contentsOf: file, encoding: .utf8)).flatMap(Shield.scriptletSource)
            await MainActor.run {
                let shield = self
                if ask == shield.scriptletAsk, shield.takeScriptlets(source) { shield.apply() }
                shield.letGo()
            }
        }
    }

    /// A new script object only for a new source, so pages keep theirs
    /// across builds whose table is the same; whether it changed.
    @discardableResult
    private func takeScriptlets(_ source: String?) -> Bool {
        let source = scriptletsAllowed ? source : nil
        guard source != scriptletSource else { return false }
        scriptletSource = source
        scriptlets = source.map { WKUserScript(source: $0, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page) }
        return true
    }

    private func letGo() {
        busy -= 1
        guard busy == 0 else { return }
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }

    private func look(_ build: Int, _ count: Int, _ done: @escaping @MainActor ([WKContentRuleList]?) -> Void) {
        guard let store else { return done(nil) }
        var found = [WKContentRuleList?](repeating: nil, count: count)
        var left = count
        for index in 0..<count {
            store.lookUpContentRuleList(forIdentifier: Shield.identifier(build, index)) { list, _ in
                MainActor.assumeIsolated {
                    found[index] = list
                    left -= 1
                    if left == 0 { done(found.contains(where: { $0 == nil }) ? nil : found.compactMap { $0 }) }
                }
            }
        }
    }

    private func install(_ fresh: [WKContentRuleList]) {
        lists = fresh
        trouble = nil
        apply()
    }

    nonisolated static func identifier(_ build: Int, _ index: Int) -> String {
        "shield-\(build)-\(index)"
    }

    // MARK: - building

    @ObservationIgnored private var building = false
    @ObservationIgnored private var again = false

    /// Converts and compiles off the main thread, one list after another,
    /// then puts the new lists on every page at once and drops the old.
    /// `unless`: the digest of the texts the lists in use were made from;
    /// the same texts again and nothing is compiled.
    private func rebuild(unless digest: String?) {
        guard !building else {
            again = true
            return
        }
        building = true
        hold()
        let old = made
        let build = (old?.build ?? 0) + 1
        let store = store
        let folder = folder
        let known = old?.left ?? [:]
        let unchanged = old?.schema == Shield.schema ? digest : nil
        let allowed = scriptletsAllowed
        Task.detached(priority: .utility) {
            let result = await Shield.make(build, folder: folder, in: store, leaving: known, unless: unchanged, scriptlets: allowed)
            await MainActor.run {
                let shield = self
                shield.building = false
                if !result.unchanged {
                    shield.report.merge(result.report) { _, new in new }
                    shield.writeReport()
                }
                if result.unchanged {
                    shield.log.debug("the lists are the ones compiled; nothing to build")
                } else if let fresh = result.lists {
                    shield.compiles += 1
                    shield.made = Made(schema: Shield.schema, build: build, count: fresh.count, rules: result.rules,
                                       fetched: shield.made?.fetched, digest: result.digest,
                                       left: result.left.isEmpty ? nil : result.left)
                    shield.scriptletAsk += 1
                    shield.takeScriptlets(result.scriptlets)
                    shield.install(fresh)
                    if let old, old.count > 0 { shield.forget(old.build, old.count) }
                    let took = result.report["total_ms"] as? Int ?? 0
                    shield.log.notice("built \(fresh.count) lists of \(result.rules) rules in \(took) ms")
                } else {
                    // Not even the built-in list: kept from being tried at
                    // every launch, and whatever was found keeps blocking.
                    var made = shield.made ?? Made(schema: Shield.schema, build: 0, count: 0, rules: 0)
                    if made.count == 0 || shield.lists.isEmpty {
                        made.schema = Shield.schema
                        made.failed = true
                        shield.made = made
                    }
                    if shield.lists.isEmpty { shield.trouble = Shield.failure }
                }
                if shield.again {
                    shield.again = false
                    shield.rebuild(unless: shield.lists.isEmpty ? nil : shield.made?.digest)
                }
                shield.letGo()
            }
        }
    }

    private struct Result: @unchecked Sendable {
        var lists: [WKContentRuleList]?
        var scriptlets: String?
        var unchanged = false
        var rules = 0
        var digest: String?
        var left: [String: String] = [:]
        var report: [String: Any] = [:]
    }

    /// The lists built from `base` and every text kept on disk. If that
    /// fails, each text is tried alone to find the one WebKit won't take,
    /// and the build made again without it; failing that, `base` alone.
    private nonisolated static func make(_ build: Int, folder: URL, in store: WKContentRuleListStore?,
                                         leaving known: [String: String], unless unchanged: String?,
                                         scriptlets allowed: Bool) async -> Result {
        var report: [String: Any] = ["main_thread": pthread_main_np() != 0]
        guard let store else { return Result(report: report) }
        let t0 = CFAbsoluteTimeGetCurrent()
        var texts: [(name: String, text: String, digest: String)] = []
        var left: [String: String] = [:]
        for source in ShieldLists.sources {
            guard let text = cached(source.name, in: folder) else { continue }
            let digest = digest(text)
            if known[source.name] == digest { left[source.name] = digest } else { texts.append((source.name, text, digest)) }
        }
        let inputs = digest(of: texts.map(\.digest))
        report["read_ms"] = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        if let unchanged, unchanged == inputs { return Result(unchanged: true, digest: inputs, report: report) }

        var used = texts.count
        var attempt = await compile(texts.map(\.text), as: { identifier(build, $0) }, in: store)
        report["convert_ms"] = attempt.convert
        report["compile_ms"] = attempt.compile
        if attempt.lists == nil, !texts.isEmpty {
            var good: [String] = []
            for (index, source) in texts.enumerated() {
                let probe = await compile([source.text], as: { "shield-probe-\(index)-\($0)" }, in: store)
                if let lists = probe.lists {
                    good.append(source.text)
                    remove(lists.indices.map { "shield-probe-\(index)-\($0)" }, from: store)
                } else {
                    left[source.name] = source.digest
                }
            }
            used = good.count
            attempt = await compile(good, as: { identifier(build, $0) }, in: store)
            if attempt.lists == nil, !good.isEmpty {
                used = 0
                attempt = await compile([], as: { identifier(build, $0) }, in: store)
            }
        }
        report["total_ms"] = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        report["left"] = Array(left.keys).sorted()
        report["sources"] = used
        report["rules"] = attempt.rules
        report["skipped"] = attempt.skipped
        report["lists"] = attempt.lists?.count ?? 0
        report["sizes"] = attempt.sizes
        report["scriptlet_bytes"] = attempt.table?.utf8.count ?? 0
        keep(attempt.lists == nil ? nil : attempt.table, build: build, in: folder)
        let source = allowed ? attempt.table.flatMap(scriptletSource) : nil
        return Result(lists: attempt.lists, scriptlets: source, rules: attempt.rules, digest: inputs, left: left, report: report)
    }

    private struct Attempt: @unchecked Sendable {
        var lists: [WKContentRuleList]?
        /// The scriptlet table the page script reads, nil for none.
        var table: String?
        var rules = 0
        var skipped = 0
        var convert = 0
        var compile: [Int] = []
        var sizes: [Int] = []
    }

    /// `base` and these texts, converted, split to stay within WebKit's
    /// rules a list (Filters.lists) and compiled one list after another
    /// under the names given. All of them, or nil and none kept.
    private nonisolated static func compile(_ texts: [String], as name: @escaping @Sendable (Int) -> String,
                                            in store: WKContentRuleListStore) async -> Attempt {
        var attempt = Attempt()
        let t0 = CFAbsoluteTimeGetCurrent()
        let rules = autoreleasepool { Filters.convert([ShieldLists.base] + texts, env: env) }
        guard let parts = Filters.plan(rules, perList: Shield.perList, cap: Filters.cap) else { return attempt }
        attempt.convert = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        attempt.rules = rules.count - parts.left
        attempt.skipped = rules.skipped + parts.left
        // No ##+js names no site: no page gets the script, nor the click guard in it.
        attempt.table = rules.scriptlets.isEmpty ? nil : rules.scriptlets.table()
        var lists: [WKContentRuleList] = []
        for (index, part) in parts.parts.enumerated() {
            let list = autoreleasepool { part.json }
            let start = CFAbsoluteTimeGetCurrent()
            attempt.sizes.append(list.utf8.count)
            // Asked from here, not the main thread: WebKit reads the JSON on
            // the thread that asks, and only then compiles on a queue of its own.
            let compiled: WKContentRuleList? = await withCheckedContinuation { done in
                store.compileContentRuleList(forIdentifier: name(index), encodedContentRuleList: list) { compiled, error in
                    if let error { Logger(subsystem: "dev.serafim.fast.iphone", category: "shield").error("list \(index) didn't compile: \(String(describing: error), privacy: .public)") }
                    done.resume(returning: compiled)
                }
            }
            attempt.compile.append(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
            guard let compiled else {
                remove((0..<index).map(name), from: store)
                return attempt
            }
            lists.append(compiled)
        }
        attempt.lists = lists
        return attempt
    }

    struct Split: Sendable {
        var lists: [String]
        var rules: Int
        var skipped: Int
    }

    /// `base` and the lists' texts as WebKit's lists: the Mac's conversion
    /// and split, each list within WebKit's limit (Filters.perList).
    nonisolated static func split(_ texts: [String], perList: Int = Shield.perList, cap: Int = Filters.cap) -> Split? {
        let rules = Filters.convert([ShieldLists.base] + texts, env: env)
        guard let split = Filters.lists(rules, perList: perList, cap: cap) else { return nil }
        return Split(lists: split.lists, rules: rules.count - split.left, skipped: rules.skipped + split.left)
    }

    nonisolated static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// What a build is made from: the schema, `base` and each text, in order.
    nonisolated static func digest(of texts: [String]) -> String {
        digest(([String(Shield.schema), digest(ShieldLists.base)] + texts).joined(separator: "\n"))
    }

    private nonisolated static func remove(_ identifiers: [String], from store: WKContentRuleListStore) {
        for identifier in identifiers { store.removeContentRuleList(forIdentifier: identifier) { _ in } }
    }

    /// The build before, once no page holds it: WebKit's files go; lists
    /// already on a page keep working from memory until taken off.
    private func forget(_ build: Int, _ count: Int) {
        try? FileManager.default.removeItem(at: Shield.scriptletsFile(build, in: folder))
        guard let store else { return }
        Shield.remove((0..<max(count, 4)).map { Shield.identifier(build, $0) }, from: store)
    }

    private func writeReport() {
        var out = report
        out["compiles"] = compiles
        out["lookups"] = lookups
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: reportFile, options: .atomic)
        }
    }

    // MARK: - fetching

    nonisolated static func listsFolder(_ folder: URL) -> URL {
        folder.appendingPathComponent("lists", isDirectory: true)
    }

    private nonisolated static func cached(_ name: String, in folder: URL) -> String? {
        try? String(contentsOf: listsFolder(folder).appendingPathComponent(name + ".txt"), encoding: .utf8)
    }

    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var scheduled = false

    /// A look a while after launch, and each time Yab comes back to the
    /// front; each one fetches only if the lists are a week old. iOS gives
    /// a background app no time for this, and a week's lists can wait for
    /// the next time Yab is open.
    private func scheduleRefresh() {
        guard fetches, !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            guard let delay = self?.refreshDelay else { return }
            try? await Task.sleep(for: delay)
            self?.refresh()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// The lists fetched again, all at once, if a week has gone by (or
    /// `now`). Each is kept only if it arrived whole; one that didn't leaves
    /// last week's copy in its place. Compiled only if something changed.
    /// Not while the blocker is off everywhere (`wants` for no site), not on
    /// a network the person asked to spare.
    func refresh(now: Bool = false) {
        guard !refreshing else { return }
        if !now {
            if !fetches || !wants(nil, false) { return }
            if let fetched = made?.fetched, Date().timeIntervalSince(fetched) < ShieldLists.week { return }
        }
        refreshing = true
        hold()
        let folder = folder
        Task.detached(priority: .utility) {
            let t0 = CFAbsoluteTimeGetCurrent()
            let changed = await Shield.fetch(into: folder)
            let took = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            await MainActor.run {
                let shield = self
                shield.refreshing = false
                shield.report["fetch_ms"] = took
                shield.report["fetched_changed"] = changed
                if changed >= 0 {
                    if var made = shield.made {
                        made.fetched = Date()
                        shield.made = made
                    } else {
                        shield.made = Made(schema: 0, build: 0, count: 0, rules: 0, fetched: Date())
                    }
                    if changed > 0 || shield.lists.isEmpty { shield.rebuild(unless: shield.lists.isEmpty ? nil : shield.made?.digest) }
                }
                shield.writeReport()
                shield.letGo()
            }
        }
    }

    /// How many lists came back different, or -1 if none came back at all.
    private nonisolated static func fetch(into folder: URL) async -> Int {
        let lists = listsFolder(folder)
        try? FileManager.default.createDirectory(at: lists, withIntermediateDirectories: true)
        let fresh = await withTaskGroup(of: (String, Data?).self) { group in
            for source in ShieldLists.sources {
                group.addTask {
                    guard let data = await ShieldLists.Download(source.url, most: ShieldLists.most, lowData: false).data,
                          data.count >= source.least,
                          String(decoding: data.prefix(4096), as: UTF8.self).contains("\n")
                    else { return (source.name, nil) }
                    return (source.name, data)
                }
            }
            var out: [String: Data] = [:]
            for await (name, data) in group { if let data { out[name] = data } }
            return out
        }
        guard !fresh.isEmpty else { return -1 }
        var changed = 0
        for (name, data) in fresh {
            let file = lists.appendingPathComponent(name + ".txt")
            if (try? Data(contentsOf: file)) == data { continue }
            if (try? data.write(to: file, options: .atomic)) != nil { changed += 1 }
        }
        return changed
    }
}
