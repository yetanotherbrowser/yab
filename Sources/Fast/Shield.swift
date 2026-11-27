import CryptoKit
import WebKit

// The ad blocker. No counter, no shield icon going green, it is simply true
// that the page is lighter.
//
// A content rule list is enforced inside WebKit, before a request is made
// and before a stylesheet is applied, so this costs nothing at run time in
// the way a JavaScript blocker does. The rules are uBlock Origin's lists
// (EasyList, EasyPrivacy, uBlock's own, Peter Lowe's), turned into WebKit's
// form by Filters, about 160 000 of them in two lists (three, should the
// blocking outgrow one): the blocks and sites' own hiding, and the hiding
// for every site.
//
// None of that is on the way to the first page. At launch the lists are
// looked up where WebKit stored them compiled, which takes a millisecond;
// they are fetched again once a week, in the background, and compiled off
// the main thread, only when something in them changed. Before any list has
// ever arrived, and whenever the network never answers, a short list built
// in (`base`) stands in.

@MainActor
final class Shield: ObservableObject {
    static let shared = Shield()

    /// Set the one time building the lists didn't work and nothing is
    /// blocking. The toggle in Settings can say "on" all it wants, so it is
    /// the one thing worth telling a person about rather than failing the
    /// quiet way a missing ad is quiet.
    @Published private(set) var trouble: String?

    /// On unless somebody said otherwise. Every tab's controller is told when
    /// this changes, so it takes effect on the next request rather than the
    /// next launch.
    var enabled = true

    /// Sites it is off for, the ones it broke. A checkout that never
    /// finishes, a video that never starts: switching off here, for this site,
    /// beats switching off everywhere and forgetting to switch back.
    @Published private(set) var paused: Set<String> = Set(
        Store.settings.stringArray(forKey: "shield.paused") ?? []
    )

    /// The compiled lists, attached to every page in this order.
    private(set) var lists: [WKContentRuleList] = []

    /// A list switched off stays cached; its rules leave the next build.
    @Published private(set) var disabledSources: Set<String> = Set(
        Store.settings.stringArray(forKey: "shield.disabled-sources") ?? []
    )
    @Published private(set) var customSources: [ShieldSubscription] = ShieldSubscription.read(in: Store.settings)

    func setSource(_ name: String, enabled: Bool) {
        guard availableSources.contains(where: { $0.name == name }), disabledSources.contains(name) == enabled else { return }
        if enabled { disabledSources.remove(name) } else { disabledSources.insert(name) }
        Store.settings.set(disabledSources.sorted(), forKey: "shield.disabled-sources")
        rebuild()
        if enabled, Self.cached(name) == nil { needsRefresh = true; refresh(now: true) }
    }

    nonisolated static func selectedSources(disabling disabled: Set<String>, custom: [ShieldSubscription] = []) -> [Source] {
        (sources + custom.map(\.source)).filter { !disabled.contains($0.name) }
    }

    /// A record written before selection existed means every built-in list.
    nonisolated static func selectionMatches(_ stored: [String]?, current: [String]) -> Bool {
        (stored ?? sources.map(\.name)) == current
    }

    var availableSources: [Source] { Self.sources + customSources.map(\.source) }
    private var selectedSourceNames: [String] { Self.selectedSources(disabling: disabledSources, custom: customSources).map(\.name) }

    @discardableResult
    func addSource(_ raw: String, facts known: ShieldLists.Facts? = nil) -> Bool {
        guard customSources.count < 16, let item = ShieldSubscription(raw),
              !availableSources.contains(where: { $0.url == item.url }) else { return false }
        customSources.append(item)
        // What Settings' check read, so the row has its name before the fetch.
        if let known { facts[item.source.name] = known }
        ShieldSubscription.save(customSources, in: Store.settings)
        // If a refresh is already in flight, rebuild/retry with the new inventory.
        needsRefresh = true
        refresh(now: true)
        return true
    }

    func removeSource(_ id: UUID) {
        guard let item = customSources.first(where: { $0.id == id }) else { return }
        customSources.removeAll { $0.id == id }
        disabledSources.remove(item.source.name)
        ShieldSubscription.save(customSources, in: Store.settings)
        Store.settings.set(disabledSources.sorted(), forKey: "shield.disabled-sources")
        facts[item.source.name] = nil
        rebuild()
    }

    /// Each list's rule count, title and date, read from the copies kept
    /// on disk (the texts the build compiles), for Settings' rows.
    @Published private(set) var facts: [String: ShieldLists.Facts] = [:]
    private var readingFacts = false
    private var readFactsAgain = false
    /// Settings has shown the lists: their facts are kept current after.
    private var factsWanted = false

    func readFacts() {
        factsWanted = true
        guard !readingFacts else { readFactsAgain = true; return }
        readingFacts = true
        let names = availableSources.map(\.name)
        Task.detached(priority: .utility) {
            var found: [String: ShieldLists.Facts] = [:]
            for name in names { if let text = Shield.cached(name) { found[name] = ShieldLists.facts(text) } }
            await MainActor.run {
                let shield = Shield.shared
                shield.readingFacts = false
                // A list added meanwhile keeps what its check read.
                let names = Set(shield.availableSources.map(\.name))
                shield.facts = shield.facts.filter { found[$0.key] == nil && names.contains($0.key) }
                    .merging(found) { _, new in new }
                if shield.readFactsAgain { shield.readFactsAgain = false; shield.readFacts() }
            }
        }
    }

    /// The rules the last build gave WebKit, and when the lists were last fetched.
    var builtRules: Int { made?.rules ?? 0 }
    var fetchedAt: Date? { made?.fetched }

    // MARK: - who blocks (docs/ad-blocker-source.md)

    /// Which one blocks: Shield's own lists, or one ad blocker extension.
    /// One at a time, never both: a second blocker adds next to nothing and
    /// costs a lot (extension-ad-blockers.md).
    /// (Its lists' sources are `Source`, from ShieldLists.)
    enum Blocking: Equatable {
        case builtIn
        case `extension`(String)
    }

    /// The extension picked to block, kept across launches; nil for
    /// Built-in. It blocks (`source`) only once its rules are compiled:
    /// until then Shield's lists stay on, so there is no gap.
    @Published private(set) var chosen: String? = Store.settings.string(forKey: "shield.source").flatMap { $0.isEmpty ? nil : $0 }

    /// Who blocks now. Built-in until the chosen extension's first compiled
    /// rule file is held (ExtensionRules), and again whenever it is gone.
    @Published private(set) var source: Blocking = .builtIn {
        didSet { if source != oldValue { apply() } }
    }

    /// The chosen extension's rules didn't load: Built-in blocks meanwhile,
    /// and Settings › Privacy says so.
    @Published private(set) var failed: String?

    /// Sites turned off through an extension, waiting on its recompile:
    /// when the off was asked for, for the countdown in ⌘E.
    @Published private(set) var waiting: [String: Date] = [:]

    /// Whether this extension blocks pages in a tab, private or not: a
    /// private tab gets its rules only when it is allowed in private tabs,
    /// and Shield blocks there otherwise.
    var handsOver: (_ id: String, _ persistent: Bool) -> Bool = { _, persistent in persistent }

    /// Takes the extension's compiled list off a page, or puts it back
    /// (ExtensionRules.drop), so "off on this site" is at once whoever blocks.
    var dropExtension: (_ controller: WKUserContentController, _ id: String, _ off: Bool) -> Void = { _, _, _ in }

    /// Whether this page has the blocking extension's list taken off.
    func dropped(_ controller: WKUserContentController) -> Bool {
        fitting(controller).dropped != nil
    }

    func choose(_ id: String?) {
        chosen = id
        failed = nil
        Store.settings.set(id ?? "", forKey: "shield.source")
        if id == nil { source = .builtIn }
        if case .extension(let now) = source, now != id { source = .builtIn }
        waiting = [:]
    }

    /// The chosen extension's compiled rules are on pages now.
    func landed(_ id: String) {
        guard chosen == id else { return }
        failed = nil
        source = .extension(id)
    }

    /// Its rules failed, or it went away: back to the lists.
    func fellBack(_ id: String, failed: Bool) {
        guard chosen == id else { return }
        if failed { self.failed = id }
        source = .builtIn
    }

    func wait(_ host: String, _ on: Bool) {
        if on { waiting[host] = Date() } else { waiting[host] = nil }
    }

    /// How long the extension's last recompile took, in seconds, for the
    /// countdown; nil before one was timed.
    func compileSeconds(_ id: String) -> Double? {
        let value = Store.settings.double(forKey: "shield.compile.\(id)")
        return value > 0 ? value : nil
    }

    func timed(_ id: String, seconds: Double) {
        Store.settings.set(seconds, forKey: "shield.compile.\(id)")
    }

    /// The extension blocking a page in this kind of tab, or nil for Shield.
    func blocker(persistent: Bool) -> String? {
        guard case .extension(let id) = source, handsOver(id, persistent) else { return nil }
        return id
    }

    /// Lists left off every page, by their place in `lists`: for finding
    /// which of them costs a page its time. YAB_SHIELD_SKIP=1,3 at launch,
    /// or the bench's "skip" meanwhile (a test run). ";" separates too, for
    /// the stand's variants, which split on ",".
    var skipping: Set<Int> = Set(
        (ProcessInfo.processInfo.environment["YAB_SHIELD_SKIP"] ?? "").split(whereSeparator: { $0 == "," || $0 == ";" })
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    ) {
        didSet { if skipping != oldValue { apply() } }
    }

    /// A list the bench made from part of one of them, put on pages in its
    /// place (Shield.trial), to cut a list in halves until what costs is
    /// found.
    var trial: (index: Int, list: WKContentRuleList)? {
        didSet { apply() }
    }

    /// What pages are given: the lists, less those skipped, with a trial in
    /// its list's place.
    private var chosenLists: [WKContentRuleList] {
        guard !skipping.isEmpty || trial != nil else { return lists }
        return lists.indices.compactMap { index in
            if skipping.contains(index) { return nil }
            if let trial, trial.index == index { return trial.list }
            return lists[index]
        }
    }

    /// Every controller it has seen, weakly, each with what is on it now
    /// and the site it is for. A navigation that changes neither costs
    /// nothing: adding or taking off a list is a message to every web
    /// process, and the web process builds the list's stylesheet again when
    /// it is added.
    private let attached = NSHashTable<WKUserContentController>.weakObjects()

    /// Kept on the controller itself, so it goes when the controller does,
    /// and with it the lists it holds: a map from weak keys to strong values
    /// only lets a value go when the map next grows, and a build of lists
    /// is tens of megabytes.
    private final class Fitting {
        var lists: [WKContentRuleList] = []
        var host: String?
        /// A quiet site's own list for this page (QuietSites), none when
        /// the lists blocked nothing there, nil for the lists.
        var quiet: [WKContentRuleList]?
        /// The page is watched: what the lists block on it is noted.
        var watched = false
        /// What was blocked on this page, by the lists or a quiet site's
        /// list, kept on a --test run only for the bench.
        var tally: [String] = []
        /// A tab of a private window keeps Shield unless the extension
        /// blocking is allowed there.
        var persistent = true
        /// The blocking extension's list taken off this page, for a site
        /// turned off: its own pause rule only lands with a recompile.
        var dropped: String?
    }
    private nonisolated(unsafe) static var fittingKey: UInt8 = 0

    private func fitting(_ controller: WKUserContentController) -> Fitting {
        if let fitting = objc_getAssociatedObject(controller, &Shield.fittingKey) as? Fitting { return fitting }
        let fitting = Fitting()
        objc_setAssociatedObject(controller, &Shield.fittingKey, fitting, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        attached.add(controller)
        return fitting
    }

    func isPaused(on host: String?) -> Bool {
        guard let host else { return false }
        return paused.contains(host)
    }

    /// Off with YAB_BLOCK_LOCAL_PAGES=1, for evals whose ad fixtures are
    /// served from this Mac: local pages blocked as websites are.
    nonisolated static let blocksLocalPages = ProcessInfo.processInfo.environment["YAB_BLOCK_LOCAL_PAGES"] == "1"

    /// No blocker on this page: off for the site, or the page is this Mac's
    /// or the network's (localhost:3000, app.lvh.me, a router), where
    /// there are no ads to block and a rule only breaks a developer's frames
    /// (feedback #884). Settings' switch for the site stays as it was.
    func isOff(on host: String?) -> Bool {
        isPaused(on: host) || (!Shield.blocksLocalPages && LocalNetwork.isHome(host))
    }

    func pause(_ host: String, _ off: Bool) {
        if off { paused.insert(host) } else { paused.remove(host) }
        Store.settings.set(Array(paused).sorted(), forKey: "shield.paused")
    }

    /// Whether YouTube's own ads are taken out of this page (see YouTube).
    func skips(on host: String?) -> Bool {
        enabled && !isPaused(on: host) && YouTube.runs(on: host)
    }

    // MARK: - tabs

    /// Every tab asks for it once, before it has anywhere to go.
    func protect(_ controller: WKUserContentController, persistent: Bool = true) {
        fitting(controller).persistent = persistent
        fit(controller, for: nil)
    }

    /// Before each page: the lists go on or off for the site this tab is
    /// heading to. A rule list is enforced from the moment it is added, so
    /// doing this at the navigation is what makes "off for this site" true
    /// for the whole page rather than for the second half of it.
    func tune(_ controller: WKUserContentController, for host: String?, watching: Bool = true) {
        let fitting = fitting(controller)
        fitting.quiet = nil
        fitting.watched = false
        fitting.tally = []
        if let host, watching, Shield.learns, enabled, blocker(persistent: fitting.persistent) == nil, !hidingSites.isEmpty, !isOff(on: host), !QuietSites.hides(host, in: hidingSites) {
            if let keys = quiet.visit(host, now: Date().timeIntervalSince1970) {
                // Not compiled yet: the lists this once, and the page
                // watched as any other.
                // With it, the generic hiding: a list of selectors WebKit
                // makes one stylesheet of, next to nothing for each load,
                // which hides the empty boxes a site keeps for the ads
                // its own list stops.
                if let list = quietList(keys) { fitting.quiet = list + (Shield.quietHides ? hidingLists : []) } else { fitting.watched = true }
            } else {
                fitting.watched = true
            }
            keep()
        }
        fit(controller, for: host)
    }

    // MARK: - quiet sites

    /// Off with YAB_SHIELD_QUIET=0 at launch, for measuring: every page
    /// gets the lists.
    nonisolated static let learns = ProcessInfo.processInfo.environment["YAB_SHIELD_QUIET"] != "0"
    /// Off with YAB_SHIELD_QUIET_HIDING=0, for measuring what the generic
    /// hiding costs a quiet site's pages.
    nonisolated static let quietHides = ProcessInfo.processInfo.environment["YAB_SHIELD_QUIET_HIDING"] != "0"

    private(set) var quiet: QuietSites = Store.settings.data(forKey: "shield.quiet")
        .flatMap { try? JSONDecoder().decode(QuietSites.self, from: $0) } ?? QuietSites()

    /// Sites with hiding rules of their own, written beside the lists when
    /// they are built and read at launch. Left empty, and no site quiet,
    /// until it is known which lists hold the generic hiding.
    private var hidingSites: Set<String> = []
    /// How many of `lists`, at the end, hold only the generic hiding.
    private var hiding = 0

    /// The lists a quiet site's pages keep: the generic hiding, less any
    /// the bench left off.
    private var hidingLists: [WKContentRuleList] {
        lists.indices.suffix(hiding).filter { !skipping.contains($0) }.map { lists[$0] }
    }

    /// Quiet sites' lists, compiled, by the addresses they hold.
    private var quietLists: [String: WKContentRuleList] = [:]
    private var compilingQuiet: Set<String> = []

    /// WebKit says the lists (or, `quietly`, a quiet site's list) blocked a
    /// load of the page in this controller.
    func blocked(_ url: URL, on controller: WKUserContentController, quietly: Bool = false) {
        let fitting = fitting(controller)
        if Store.testing { fitting.tally.append(url.absoluteString) }
        WrappedLedger.shared.add(.ads)
        guard !quietly, fitting.watched, let host = fitting.host else { return }
        if let key = QuietSites.key(url) {
            if quiet.saw(key, on: host) { keep() }
        } else {
            quiet.refuse(host)
            keep()
        }
    }

    /// What a page's lists blocked and which it had, for the bench.
    func tally(_ controller: WKUserContentController) -> [String: Any] {
        let fitting = fitting(controller)
        let mode = fitting.quiet != nil ? "quiet" : fitting.watched ? "watched" : "lists"
        return ["blocked": fitting.tally, "mode": mode, "host": fitting.host ?? "", "lists": fitting.lists.map { $0.identifier ?? "" }]
    }

    /// Forgets every site, for the bench.
    func forgetQuiet() {
        quiet = QuietSites()
        keep()
    }

    private var keeping = false

    private func keep() {
        guard !keeping else { return }
        keeping = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            keeping = false
            Store.settings.set(try? JSONEncoder().encode(quiet), forKey: "shield.quiet")
        }
    }

    /// The list for these addresses if it is compiled, none for no
    /// addresses, or nil while WebKit looks it up or compiles it.
    private func quietList(_ keys: [String]) -> [WKContentRuleList]? {
        guard !keys.isEmpty else { return [] }
        let text = QuietSites.list(keys)
        let name = "shield-quiet-" + Shield.digest(text)
        if let list = quietLists[name] { return [list] }
        guard let store = Shield.store, compilingQuiet.insert(name).inserted else { return nil }
        store.lookUpContentRuleList(forIdentifier: name) { found, _ in
            MainActor.assumeIsolated {
                if let found {
                    self.quietLists[name] = found
                    self.compilingQuiet.remove(name)
                    return
                }
                store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: text) { list, error in
                    MainActor.assumeIsolated {
                        if let error { NSLog("yab: a quiet site's list didn't compile: \(error)") }
                        self.quietLists[name] = list
                        self.compilingQuiet.remove(name)
                    }
                }
            }
        }
        return nil
    }

    private nonisolated static var hidingFile: URL {
        Store.folder.appendingPathComponent("Shield/hiding-sites.txt")
    }

    /// How many lists hold the generic hiding, written with the sites.
    private nonisolated static var hidingCountFile: URL {
        Store.folder.appendingPathComponent("Shield/hiding-lists.txt")
    }

    // MARK: - skips

    /// The lists' $urlskip rules from the last build (Filters.Skip), kept
    /// beside the lists and read at launch, when nothing is converted.
    private nonisolated static var skipsFile: URL {
        Store.folder.appendingPathComponent("Shield/skips.json")
    }

    var skipper: Filters.Skipper?

    nonisolated static func writeSkips(_ skips: [Filters.Skip]) {
        try? FileManager.default.createDirectory(at: skipsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(skips).write(to: skipsFile, options: .atomic)
        let skipper = Filters.Skipper(skips)
        Task { @MainActor in Shield.shared.skipper = skipper }
    }

    private func readSkips() {
        Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: Shield.skipsFile),
                  let skips = try? JSONDecoder().decode([Filters.Skip].self, from: data) else { return }
            let skipper = Filters.Skipper(skips)
            await MainActor.run { if Shield.shared.skipper == nil { Shield.shared.skipper = skipper } }
        }
    }

    /// Where a tab's top document goes instead of `url`, a click tracker
    /// with its destination inside (Filters.Skip), else, when `cleaning`,
    /// `url` without the names a copy drops (Diary.withoutSharing), while
    /// Shield blocks on the site. `persistent`: a WebKit tab's kind, whose
    /// blocking an extension may have; nil for a Chromium tab, which Shield
    /// always blocks for.
    func redirect(_ url: URL, persistent: Bool?, cleaning: Bool) -> URL? {
        guard enabled, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        if let persistent, blocker(persistent: persistent) != nil { return nil }
        guard !isOff(on: PageScripts.host(of: url)) else { return nil }
        if let out = skipper?.destination(url.absoluteString) { return URL(string: out) }
        return cleaning ? Diary.withoutSharing(url) : nil
    }

    private func readHidingSites() {
        let count = lists.count
        Task.detached(priority: .utility) {
            let text = (try? String(contentsOf: Shield.hidingFile, encoding: .utf8)) ?? ""
            let hiding = (try? String(contentsOf: Shield.hidingCountFile, encoding: .utf8))
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            // Lists built before the count was written: no site is quiet
            // until they are built again.
            let known = hiding.map { $0 > 0 && $0 < count } ?? false
            let sites = known ? Set(text.split(separator: "\n").map(String.init)) : []
            await MainActor.run {
                Shield.shared.hidingSites = sites
                Shield.shared.hiding = known ? hiding ?? 0 : 0
            }
        }
    }

    /// Switched on or off for every page that is already open, or the
    /// lists swapped for newer ones.
    func apply() {
        for controller in attached.allObjects {
            fit(controller, for: fitting(controller).host)
        }
        ShieldChromium.tell()
    }

    /// For the bench, after it put these lists on and off a page by hand:
    /// they are taken off, and the page given again what it should have.
    func refit(_ controller: WKUserContentController, after touched: [WKContentRuleList]) {
        let fitting = fitting(controller)
        for list in touched { controller.remove(list) }
        fitting.lists.removeAll { list in touched.contains { $0 === list } }
        fit(controller, for: fitting.host)
    }

    /// For the bench: how often a page asked, how often that changed what
    /// was on it, and the main thread's time spent here.
    private(set) var fits = (asked: 0, changed: 0, seconds: 0.0)

    private func fit(_ controller: WKUserContentController, for host: String?) {
        let t0 = CACurrentMediaTime()
        defer { fits.seconds += CACurrentMediaTime() - t0 }
        fits.asked += 1
        let fitting = fitting(controller)
        fitting.host = host
        // An extension blocking takes the lists off at the page's next
        // navigation (or now, from `apply`): its own rules are on it.
        let handing = blocker(persistent: fitting.persistent)
        let handed = handing != nil
        // Off on this site with an extension blocking: its list comes off
        // this page now, and back when the site is on again.
        if let handing, isOff(on: host) {
            if fitting.dropped == nil {
                dropExtension(controller, handing, true)
                fitting.dropped = handing
            }
        } else if let dropped = fitting.dropped {
            dropExtension(controller, dropped, false)
            fitting.dropped = nil
        }
        let want = enabled && !isOff(on: host) && !handed ? fitting.quiet ?? chosenLists : []
        let have = fitting.lists
        guard have.count != want.count || zip(have, want).contains(where: { $0 !== $1 }) else { return }
        fits.changed += 1
        for list in have where !want.contains(where: { $0 === list }) { controller.remove(list) }
        for list in want where !have.contains(where: { $0 === list }) { controller.add(list) }
        fitting.lists = want
    }

    /// The state of things, for the bench.
    var report: [String: Any] {
        var out = last
        out["attached_lists"] = lists.count
        out["rules_made"] = made?.rules ?? 0
        out["build"] = made?.build ?? 0
        out["fetched"] = made?.fetched.map { $0.timeIntervalSince1970 } ?? 0
        out["building"] = building
        out["refreshing"] = refreshing
        out["refresh_failed"] = refreshFailed
        out["custom_sources"] = customSources.map { ["name": $0.source.name, "url": $0.url.absoluteString] }
        // Settings' counts and titles, by list.
        out["facts"] = facts.mapValues { ["rules": $0.rules, "title": $0.title ?? ""] }
        out["selection"] = made?.selection ?? Self.sources.map(\.name)
        out["wanted_selection"] = selectedSourceNames
        out["fits_asked"] = fits.asked
        out["fits_changed"] = fits.changed
        out["fits_ms"] = (fits.seconds * 10_000).rounded() / 10
        out["trouble"] = trouble ?? ""
        out["skipping"] = skipping.sorted()
        out["trial"] = trial.map { ["index": $0.index, "identifier": $0.list.identifier ?? ""] } ?? [:]
        out["quiet"] = quiet.sites.mapValues { site -> [String: Any] in
            ["visits": site.visits, "fresh": site.fresh, "keys": site.keys, "quiet": site.quiet, "since": site.since, "never": site.never]
        }
        out["hiding_sites"] = hidingSites.count
        out["skips"] = skipper?.count ?? 0
        out["hiding_lists"] = hiding
        out["chosen"] = chosen ?? ""
        if case .extension(let id) = source { out["source"] = id } else { out["source"] = "builtIn" }
        out["failed"] = failed ?? ""
        out["waiting"] = Array(waiting.keys).sorted()
        out["paused"] = Array(paused).sorted()
        out["compile_s"] = chosen.flatMap(compileSeconds) ?? 0
        out["quiet_lists"] = quietLists.count
        return out
    }

    private func install(_ fresh: [WKContentRuleList]) {
        lists = fresh
        readHidingSites()
        trouble = nil
        apply()
    }

    // MARK: - launch

    /// What WebKit was last given, in Store.settings: which build of the
    /// lists (identifiers carry it, so a new build never overwrites the
    /// lists the open tabs hold), how many, and by which version of this
    /// code. `schema` goes up whenever Filters or `base` changes what a list
    /// comes out as, and the cached text is compiled again once: on the
    /// iPhone too, which keeps it in ShieldLists beside `base`.
    /// +2: the build writes the lists' $urlskip rules (skips.json).
    /// +3: YouTube's #player-ads bait is spared (YouTube.filters).
    static let schema = ShieldLists.schema + 3
    private struct Made: Codable {
        var schema: Int
        var build: Int
        var count: Int
        var rules: Int
        var fetched: Date?
        /// Lists that failed to build, by name, with a digest of the text
        /// that failed: left out until a fetch brings a different text, so
        /// one broken list doesn't cost a failed build at every launch.
        var left: [String: String]?
        /// Not even `base` built. Said in Settings, and not tried again
        /// until the lists change or someone asks.
        var failed: Bool?
        /// The built-in inputs of this build, in compiler order.
        var selection: [String]?
    }

    private var made: Made? {
        get { Store.settings.data(forKey: "shield.made").flatMap { try? JSONDecoder().decode(Made.self, from: $0) } }
        set { Store.settings.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "shield.made") }
    }

    /// At launch. Looks the compiled lists up, the one thing done now, and
    /// leaves everything else for later.
    func start() {
        readSkips()
        guard let made, made.count > 0 else {
            if let made, made.failed == true, made.schema == Shield.schema,
               Self.selectionMatches(made.selection, current: selectedSourceNames) {
                trouble = "The ad blocker's lists didn't build"
            } else {
                // The one list the yab before this kept in WebKit's own store.
                if made == nil { WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: "yab-shield") { _ in } }
                rebuild()
            }
            scheduleRefresh()
            return
        }
        Shield.look(made.build, made.count) { [weak self] found in
            guard let self else { return }
            guard self.made?.build == made.build else { scheduleRefresh(); return }
            if let found { install(found) }
            // Missing, or made by an older Filters: made again from the
            // text kept on disk. Whatever was found blocks meanwhile.
            if found == nil || made.schema != Shield.schema || !Self.selectionMatches(made.selection, current: selectedSourceNames) { rebuild() }
            scheduleRefresh()
        }
    }

    /// "Try Again" in Settings: compiled again from the lists kept on disk,
    /// the ones that failed before included.
    func compile() {
        if var made {
            made.left = nil
            made.failed = nil
            self.made = made
        }
        rebuild()
    }

    private static func look(_ build: Int, _ count: Int, _ done: @escaping @MainActor ([WKContentRuleList]?) -> Void) {
        guard let store = Shield.store else { return done(nil) }
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

    // MARK: - building

    /// Where WebKit keeps the compiled lists: inside this app's own folder,
    /// so a test world's never mix with the browser's. Made on the main
    /// thread, the first time `look` or `rebuild` asks, and only then handed
    /// to the build's own task: WebKit's classes say they are the main
    /// thread's, and a store first made on another thread is not one to
    /// share with the tabs.
    static let store: WKContentRuleListStore? = {
        let folder = Store.folder.appendingPathComponent("Shield/compiled", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return WKContentRuleListStore(url: folder)
    }()

    nonisolated static func identifier(_ build: Int, _ index: Int) -> String {
        "shield-\(build)-\(index)"
    }

    private var building = false
    private var again = false
    /// Discarded builds still own their identifiers until WebKit removes them.
    private var lastBuild = 0
    /// How the last build went, for the bench: how long each step took and
    /// on which thread.
    private(set) var last: [String: Any] = [:]

    /// Converts and compiles off the main thread, one list after another,
    /// then puts the new lists on every tab at once and drops the old.
    private func rebuild() {
        guard !building else {
            again = true
            return
        }
        building = true
        let build = max(made?.build ?? 0, lastBuild) + 1
        lastBuild = build
        let old = made
        // Read here, on the main thread, which makes it the first time.
        let store = Shield.store
        let known = made?.left ?? [:]
        let selected = Self.selectedSources(disabling: disabledSources, custom: customSources)
        let selection = selected.map(\.name)
        Task.detached(priority: .utility) {
            let result = await Shield.make(build, in: store, leaving: known, sources: selected)
            await MainActor.run {
                let shield = Shield.shared
                shield.building = false
                shield.last = result.report
                // A switch changed while this build was away. Never put
                // its old choice back on the pages after the new one.
                guard selection == shield.selectedSourceNames else {
                    if let fresh = result.lists { Shield.forget(build, fresh.count) }
                    shield.again = false
                    shield.rebuild()
                    return
                }
                if let fresh = result.lists {
                    shield.made = Made(schema: Shield.schema, build: build, count: fresh.count, rules: result.rules,
                                       fetched: shield.made?.fetched, left: result.left.isEmpty ? nil : result.left,
                                       selection: selection)
                    shield.install(fresh)
                    // Settings' counts, only once someone has looked at them.
                    if shield.factsWanted { shield.readFacts() }
                    if let old { Shield.forget(old.build, old.count) }
                } else {
                    // Not even the built-in list: kept from being tried at
                    // every launch, and whatever was found keeps blocking.
                    var made = shield.made ?? Made(schema: Shield.schema, build: 0, count: 0, rules: 0)
                    if made.count == 0 || shield.lists.isEmpty {
                        made.schema = Shield.schema
                        made.failed = true
                        made.selection = selection
                        shield.made = made
                    }
                    if shield.lists.isEmpty { shield.trouble = "The ad blocker's lists didn't build" }
                }
                if shield.again {
                    shield.again = false
                    shield.rebuild()
                }
            }
        }
    }

    private struct Result {
        var lists: [WKContentRuleList]?
        var rules = 0
        var left: [String: String] = [:]
        var report: [String: Any] = [:]
    }

    /// The lists built from `base` and every source kept on disk. If that
    /// fails, each source is tried alone to find the one WebKit won't take,
    /// and the build made again without it; failing that, `base` alone.
    private nonisolated static func make(_ build: Int, in store: WKContentRuleListStore?, leaving known: [String: String], sources: [Source]) async -> Result {
        var report: [String: Any] = ["main_thread": pthread_main_np() != 0]
        guard let store else { return Result(report: report) }
        var texts: [(name: String, text: String, digest: String)] = []
        var left: [String: String] = [:]
        for source in sources {
            guard let text = cached(source.name) else { continue }
            let digest = digest(text)
            if known[source.name] == digest { left[source.name] = digest } else { texts.append((source.name, text, digest)) }
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        var used = texts.count
        var attempt = await compile(texts.map { ($0.name, $0.text) }, as: { identifier(build, $0) }, in: store)
        report["convert_ms"] = attempt.convert
        report["compile_ms"] = attempt.compile
        report["parse_ms"] = attempt.parse
        if attempt.lists == nil, !texts.isEmpty {
            // Which one: each alone beside `base`, under names of its own,
            // thrown away after.
            var good: [(name: String, text: String)] = []
            for (index, source) in texts.enumerated() {
                let probe = await compile([(source.name, source.text)], as: { "shield-probe-\(index)-\($0)" }, in: store)
                if let lists = probe.lists {
                    good.append((source.name, source.text))
                    await MainActor.run { Shield.remove(lists.indices.map { "shield-probe-\(index)-\($0)" }) }
                } else {
                    left[source.name] = source.digest
                    NSLog("yab: shield list \(source.name) left out, it didn't build")
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
        report["exceptions"] = attempt.exceptions
        report["skipped"] = attempt.skipped
        report["lists"] = attempt.lists?.count ?? 0
        return Result(lists: attempt.lists, rules: attempt.rules, left: left, report: report)
    }

    private struct Attempt {
        var lists: [WKContentRuleList]?
        var rules = 0
        var exceptions = 0
        var skipped = 0
        var convert = 0
        var compile: [Int] = []
        var parse: [Int] = []
    }

    /// `base` and these texts, converted and compiled one list after
    /// another under the names given. All of them, or nil and none kept.
    private nonisolated static func compile(_ texts: [(name: String, text: String)], as name: @escaping @Sendable (Int) -> String, in store: WKContentRuleListStore) async -> Attempt {
        var attempt = Attempt()
        let t0 = CFAbsoluteTimeGetCurrent()
        let rules = convert(texts)
        let split = Filters.lists(rules)
        attempt.convert = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        ShieldChromium.write(rules)
        writeSkips(rules.skips)
        attempt.rules = rules.count - (split?.left ?? 0)
        attempt.exceptions = rules.exceptions.count
        attempt.skipped = rules.skipped + (split?.left ?? 0)
        guard let split else {
            NSLog("yab: shield lists have too many exceptions (\(rules.exceptions.count))")
            return attempt
        }
        let hiding = rules.hidingSites.sorted().joined(separator: "\n")
        var lists: [WKContentRuleList] = []
        for (index, list) in split.lists.enumerated() {
            let start = CFAbsoluteTimeGetCurrent()
            // Called from here, not the main thread: WebKit reads the JSON
            // on the thread that asks, 70-100 ms of it for a list this big,
            // and only then hands the compiling to a queue of its own.
            let compiled: WKContentRuleList? = await withCheckedContinuation { done in
                store.compileContentRuleList(forIdentifier: name(index), encodedContentRuleList: list) { compiled, error in
                    if let error { NSLog("yab: shield list \(index) didn't compile: \(error)") }
                    done.resume(returning: compiled)
                }
                attempt.parse.append(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
            }
            attempt.compile.append(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
            guard let compiled else {
                let made = (0..<index).map(name)
                await MainActor.run { Shield.remove(made) }
                return attempt
            }
            lists.append(compiled)
        }
        attempt.lists = lists
        try? FileManager.default.createDirectory(at: hidingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? hiding.write(to: hidingFile, atomically: true, encoding: .utf8)
        try? String(split.hiding).write(to: hidingCountFile, atomically: true, encoding: .utf8)
        return attempt
    }

    // MARK: - taking the lists apart, for the bench

    /// What a rule is, for counting and cutting: a block, an exception, or
    /// a hiding rule for every site, every site but some, some sites as a
    /// condition (if-domain), or one site by its address.
    private nonisolated static func kind(_ rule: [String: Any]) -> String {
        let action = (rule["action"] as? [String: Any])?["type"] as? String ?? ""
        let trigger = rule["trigger"] as? [String: Any] ?? [:]
        switch action {
        case "block": return "block"
        case "ignore-previous-rules": return "allow"
        case "css-display-none":
            if trigger["if-domain"] != nil { return "hide-if" }
            if trigger["unless-domain"] != nil { return "hide-unless" }
            return trigger["url-filter"] as? String == ".*" ? "hide-all" : "hide-site"
        default: return action
        }
    }

    /// The lists as they are made now, from the text kept on disk, as
    /// arrays of rules: the same split Filters makes for WebKit.
    private nonisolated static func split() -> [[[String: Any]]] {
        let texts: [(name: String, text: String)] = sources.compactMap { source in cached(source.name).map { (source.name, $0) } }
        guard let split = Filters.lists(convert(texts)) else { return [] }
        return split.lists.map { list in
            (try? JSONSerialization.jsonObject(with: Data(list.utf8))) as? [[String: Any]] ?? []
        }
    }

    /// Each list: how many rules of each kind, how many of those for any
    /// address, and of the hiding rules how many select by an attribute,
    /// :has, or more than one step.
    nonisolated static func anatomy() -> [[String: Any]] {
        split().map { rules in
            var kinds: [String: Int] = [:]
            var attribute = 0, has = 0, compound = 0
            // Rules whose url-filter is ".*", by kind: what every load of
            // every page is given before WebKit looks at their conditions.
            var anywhere: [String: Int] = [:]
            for rule in rules {
                kinds[kind(rule), default: 0] += 1
                if (rule["trigger"] as? [String: Any])?["url-filter"] as? String == ".*" { anywhere[kind(rule), default: 0] += 1 }
                guard let selector = (rule["action"] as? [String: Any])?["selector"] as? String else { continue }
                if selector.contains("[") { attribute += 1 }
                if selector.contains(":has(") { has += 1 }
                if selector.contains(" ") || selector.contains(">") || selector.contains("+") || selector.contains("~") { compound += 1 }
            }
            return ["rules": rules.count, "kinds": kinds, "anywhere": anywhere, "attribute": attribute, "has": has, "compound": compound]
        }
    }

    /// The list at `index` cut down: of its rules of `kind` ("all" for
    /// every kind) only those from `from` to `to`, counted among that kind;
    /// its other rules kept with `others`, and its exceptions always, so
    /// they still end it. Compiled apart, never over the lists in use.
    nonisolated static func trial(_ index: Int, kind wanted: String, from: Int, to: Int, others: Bool) async -> (WKContentRuleList?, [String: Any]) {
        let lists = split()
        guard lists.indices.contains(index), let store = await MainActor.run(body: { Shield.store }) else { return (nil, ["error": "no list \(index)"]) }
        var seen = 0, kept: [[String: Any]] = [], taken = 0
        for rule in lists[index] {
            let kind = kind(rule)
            if kind == "allow" { kept.append(rule); continue }
            if wanted == "all" || kind == wanted {
                if seen >= from, seen < to { kept.append(rule); taken += 1 }
                seen += 1
            } else if others {
                kept.append(rule)
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: kept), let text = String(data: data, encoding: .utf8) else { return (nil, ["error": "json"]) }
        let t0 = CFAbsoluteTimeGetCurrent()
        let list: WKContentRuleList? = await withCheckedContinuation { done in
            store.compileContentRuleList(forIdentifier: "shield-trial-\(index)", encodedContentRuleList: text) { list, error in
                if let error { NSLog("yab: shield trial didn't compile: \(error)") }
                done.resume(returning: list)
            }
        }
        // A handful taken is what a search by halves ends on: shown whole.
        let shown = taken <= 64 ? kept.filter { kind($0) != "allow" }.compactMap { rule in
            (try? JSONSerialization.data(withJSONObject: rule)).flatMap { String(data: $0, encoding: .utf8) }
        } : []
        return (list, ["index": index, "kind": wanted, "of_kind": seen, "taken": taken, "rules": kept.count, "shown": shown,
                       "compile_ms": Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)])
    }

    private nonisolated static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func remove(_ identifiers: [String]) {
        guard let store else { return }
        for identifier in identifiers { store.removeContentRuleList(forIdentifier: identifier) { _ in } }
    }

    /// The build before, once no tab holds it: WebKit's files go, and the
    /// lists already attached keep working from memory until they are
    /// taken off.
    private static func forget(_ build: Int, _ count: Int) {
        remove((0..<max(count, 8)).map { identifier(build, $0) })
    }

    // MARK: - fetching

    /// The lists, where they come from and the one built in live in
    /// ShieldLists, which the iPhone compiles too.
    typealias Source = ShieldLists.Source
    nonisolated static var sources: [Source] { ShieldLists.sources }
    nonisolated static let week = ShieldLists.week
    nonisolated static let most = ShieldLists.most

    private nonisolated static var folder: URL {
        Store.folder.appendingPathComponent("Shield/lists", isDirectory: true)
    }

    private nonisolated static func cached(_ name: String) -> String? {
        try? String(contentsOf: folder.appendingPathComponent(name + ".txt"), encoding: .utf8)
    }

    /// The rules a build would make now, for what isn't WebKit: the Chromium
    /// helper's copy, made here when no build wrote one yet.
    nonisolated static func converted(sources: [Source]) -> Filters.Rules {
        let texts: [(name: String, text: String)] = sources.compactMap { source in cached(source.name).map { (source.name, $0) } }
        return convert(texts)
    }

    /// `base` and these lists converted, the $urlskip rules taken from
    /// uBlock Origin's own lists only, the ones it trusts with them.
    nonisolated static func convert(_ texts: [(name: String, text: String)]) -> Filters.Rules {
        let trusted = Set(texts.indices.filter { trusts(texts[$0].name) }.map { $0 + 1 })
        return Filters.convert([base] + texts.map(\.text), trusted: trusted)
    }

    nonisolated static func trusts(_ name: String) -> Bool {
        name.hasPrefix("ublock-") && ShieldLists.sources.contains { $0.name == name }
    }
    var selected: [Source] { Self.selectedSources(disabling: disabledSources, custom: customSources) }

    @Published private(set) var refreshing = false
    @Published private(set) var refreshFailed = false
    private var needsRefresh = false
    private var scheduler: NSBackgroundActivityScheduler?

    /// A look a while after launch, and then about once a day for as long
    /// as yab is open; each one fetches only if the lists are a week old.
    /// macOS picks the moment, when the Mac is idle and not on a low battery.
    private func scheduleRefresh() {
        guard scheduler == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.refresh() }
        let scheduler = NSBackgroundActivityScheduler(identifier: Bundle.main.bundleIdentifier.map { "\($0).shield" } ?? "yab.shield")
        scheduler.repeats = true
        scheduler.interval = 24 * 3600
        scheduler.tolerance = 3600
        scheduler.qualityOfService = .utility
        scheduler.schedule { done in
            DispatchQueue.main.async {
                Shield.shared.refresh()
                done(.finished)
            }
        }
        self.scheduler = scheduler
    }

    /// The lists fetched again, all at once, if a week has gone by (or
    /// `now`). Each is kept only if it arrived whole; one that didn't leaves
    /// last week's copy in its place, so a host that is down never takes
    /// its share of the blocking with it. Compiled only if something changed.
    /// Not while the blocker is off, and never on its own in a test world,
    /// whose runs are measured: there the bench asks (`now`).
    /// `only`: that one list fetched (a custom list's Update), the others
    /// left as they are.
    func refresh(now: Bool = false, only: String? = nil) {
        guard !refreshing else { return }
        if !now {
            if !enabled || Store.testing { return }
            if let fetched = made?.fetched, Date().timeIntervalSince(fetched) < Shield.week { return }
        }
        needsRefresh = false
        refreshFailed = false
        let sources = Self.selectedSources(disabling: disabledSources, custom: customSources).filter { only == nil || $0.name == only }
        refreshing = true
        Task.detached(priority: .utility) {
            let fetched = await Shield.fetch(sources: sources)
            await MainActor.run {
                let shield = Shield.shared
                shield.refreshing = false
                if shield.needsRefresh { shield.refresh(now: true); return }
                shield.refreshFailed = !fetched.failed.intersection(shield.selectedSourceNames).isEmpty
                let changed = fetched.changed
                guard changed >= 0 else { return }
                if only != nil {
                    // One list's Update is not the lists' update.
                } else if var made = shield.made {
                    made.fetched = Date()
                    shield.made = made
                } else {
                    shield.made = Made(schema: 0, build: 0, count: 0, rules: 0, fetched: Date())
                }
                if changed > 0 || shield.lists.isEmpty { shield.rebuild() } else if shield.factsWanted { shield.readFacts() }
            }
        }
    }

    /// Failed subscriptions retain their cached bytes. A partial update is
    /// visible too, so a custom URL cannot silently look successfully loaded.
    private nonisolated static func fetch(sources: [Source]) async -> (changed: Int, failed: Set<String>) {
        guard !sources.isEmpty else { return (0, []) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fresh = await withTaskGroup(of: (String, Data?).self) { group in
            for source in sources {
                group.addTask {
                    guard let data = await Download(source.url, most: most).data,
                          data.count >= source.least,
                          ShieldSubscription.accepts(data)
                    else { return (source.name, nil) }
                    return (source.name, data)
                }
            }
            var out: [String: Data] = [:]
            for await (name, data) in group { if let data { out[name] = data } }
            return out
        }
        let failed = Set(sources.map(\.name)).subtracting(fresh.keys)
        guard !fresh.isEmpty else { return (-1, failed) }
        var changed = 0
        for (name, data) in fresh {
            let file = folder.appendingPathComponent(name + ".txt")
            if (try? Data(contentsOf: file)) == data { continue }
            if (try? data.write(to: file, options: .atomic)) != nil { changed += 1 }
        }
        return (changed, failed)
    }

    typealias Download = ShieldLists.Download

    // MARK: - built in

    nonisolated static var base: String { ShieldLists.base + "\n" + YouTube.filters }
}
