import WebKit
import XCTest
@testable import YabPhone

/// The ad blocker (Page/Shield): the lists split to stay within WebKit's
/// rules a list, compiled once and found compiled at the next launch,
/// compiled again only when the texts change, put on and taken off a page by
/// its site; which pages get them (Settings, Site Settings, the Mac's sites);
/// the words in Settings. Each Shield here has a folder of its own.
@MainActor
final class ShieldTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-shield-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - splitting

    /// Rules as WebKit reads them, each list parsed.
    private func parse(_ list: String) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(list.utf8)) as? [[String: Any]])
    }

    private func action(_ rule: [String: Any]) -> String {
        (rule["action"] as? [String: Any])?["type"] as? String ?? ""
    }

    /// Third-party loads of a whole site: one rule each. A site with no
    /// kinds named would be two (what pages load, and pages in frames).
    private var manyTexts: [String] {
        [(0..<2_500).map { "||ad\($0).example.com^$3p" }.joined(separator: "\n"),
         (0..<10).map { "@@||ok\($0).example.com^$script" }.joined(separator: "\n"),
         (0..<1_500).map { "##.promo-\($0)" }.joined(separator: "\n")]
    }

    func testListsStayWithinTheirSizeAndEveryBlockingListEndsWithEveryException() throws {
        let split = try XCTUnwrap(Shield.split(manyTexts, perList: 1_000, cap: 6_000))
        // 2 569 rules (the lists' blocks, base's own and its 15 site hides)
        // at 986 a list, the 14 exceptions ending each, then 1 509 generic
        // hiding rules at 1 000 a list.
        XCTAssertEqual(split.lists.count, 5)
        XCTAssertEqual(split.skipped, 0)
        let lists = try split.lists.map(parse)
        for list in lists { XCTAssertLessThanOrEqual(list.count, 1_000) }
        for list in lists.prefix(3) {
            XCTAssertTrue(list.contains { action($0) == "block" })
            XCTAssertEqual(list.suffix(10).map(action), Array(repeating: "ignore-previous-rules", count: 10),
                           "an exception only reaches the rules before it in its own list")
        }
        for list in lists.suffix(2) {
            XCTAssertTrue(list.allSatisfy { action($0) == "css-display-none" }, "the hiding for every site is lists of its own")
        }
        let exceptions = lists[0].filter { action($0) == "ignore-previous-rules" }.count
        XCTAssertEqual(lists.map(\.count).reduce(0, +), split.rules + 2 * exceptions, "the exceptions repeat at the end of each blocking list")
    }

    func testOverTheCapTheLastReadRulesAreLeftOut() throws {
        let split = try XCTUnwrap(Shield.split(manyTexts, perList: 1_000, cap: 2_000))
        XCTAssertEqual(split.lists.count, 2, "no more lists than the cap allows")
        XCTAssertGreaterThanOrEqual(split.skipped, 597 + 1_509)
        for list in try split.lists.map(parse) { XCTAssertLessThanOrEqual(list.count, 1_000) }
    }

    func testTheRealSizeIsUnderWebKitsLimit() {
        // WebKit refuses a list of more than 150 000 rules.
        XCTAssertLessThan(Filters.perList, 150_000)
        XCTAssertGreaterThanOrEqual(Filters.cap / Filters.perList, 2)
    }

    func testSplitListsCompileInWebKit() async throws {
        let split = try XCTUnwrap(Shield.split(manyTexts, perList: 1_000, cap: 6_000))
        let compiled = folder.appendingPathComponent("compiled", isDirectory: true)
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        let store = try XCTUnwrap(WKContentRuleListStore(url: compiled))
        for (index, list) in split.lists.enumerated() {
            let made: WKContentRuleList? = await withCheckedContinuation { done in
                store.compileContentRuleList(forIdentifier: "split-\(index)", encodedContentRuleList: list) { list, error in
                    XCTAssertNil(error)
                    done.resume(returning: list)
                }
            }
            XCTAssertNotNil(made, "list \(index) didn't compile")
        }
    }

    // MARK: - compiling once

    private func started(fetches: Bool = false) async -> Shield {
        let shield = Shield(folder: folder, fetches: fetches)
        shield.start()
        await shield.settled()
        return shield
    }

    func testTheFirstLaunchCompilesTheBuiltInListAndTheNextFindsItCompiled() async throws {
        let first = await started()
        XCTAssertEqual(first.compiles, 1)
        XCTAssertNil(first.trouble)
        let ids = first.lists.compactMap(\.identifier)
        XCTAssertEqual(ids, ["shield-1-0", "shield-1-1"], "the built-in list: its blocks, then the hiding for every site")
        let made = try XCTUnwrap(first.made)
        XCTAssertEqual(made.build, 1)
        XCTAssertEqual(made.schema, Shield.schema)
        XCTAssertNotNil(made.digest)
        XCTAssertNotNil(first.report["compile_ms"])
        XCTAssertEqual(first.report["main_thread"] as? Bool, false, "converted and compiled off the main thread")

        let second = await started()
        XCTAssertEqual(second.compiles, 0, "the same texts are never compiled twice")
        XCTAssertEqual(second.lookups, 1)
        XCTAssertEqual(second.lists.compactMap(\.identifier), ids)
        XCTAssertEqual(second.made, made)
    }

    func testChangedTextsCompileAgainUnderANewBuildAndTheOldOneGoes() async throws {
        _ = await started()
        let lists = Shield.listsFolder(folder)
        try FileManager.default.createDirectory(at: lists, withIntermediateDirectories: true)
        try "||tracker.example^\n##.sponsored-box\n".write(to: lists.appendingPathComponent("easylist.txt"), atomically: true, encoding: .utf8)

        let changed = await started()
        XCTAssertEqual(changed.lookups, 1, "last build's lists block while the new ones compile")
        XCTAssertEqual(changed.compiles, 1)
        XCTAssertEqual(changed.made?.build, 2)
        XCTAssertEqual(changed.lists.compactMap(\.identifier), ["shield-2-0", "shield-2-1"])
        XCTAssertEqual(changed.report["sources"] as? Int, 1)

        let store = try XCTUnwrap(WKContentRuleListStore(url: folder.appendingPathComponent("compiled", isDirectory: true)))
        var gone = false
        for _ in 0..<40 where !gone {
            let names: [String] = await withCheckedContinuation { done in store.getAvailableContentRuleListIdentifiers { done.resume(returning: $0 ?? []) } }
            gone = !names.contains("shield-1-0") && names.contains("shield-2-0")
            if !gone { try? await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertTrue(gone, "the build before is removed once the new one is in")

        let again = await started()
        XCTAssertEqual(again.compiles, 0)
        XCTAssertEqual(again.made?.build, 2)
    }

    func testAListWebKitRefusesIsLeftOutAndTheRestStillBlock() async throws {
        let lists = Shield.listsFolder(folder)
        try FileManager.default.createDirectory(at: lists, withIntermediateDirectories: true)
        try "||fine.example^\n".write(to: lists.appendingPathComponent("easylist.txt"), atomically: true, encoding: .utf8)
        // Over a list's worth of exceptions: Filters gives up on the build.
        let exceptions = (0..<40_000).map { "@@||ok\($0).example^$script" }.joined(separator: "\n")
        try exceptions.write(to: lists.appendingPathComponent("easyprivacy.txt"), atomically: true, encoding: .utf8)
        let shield = await started()
        XCTAssertFalse(shield.lists.isEmpty, "the other texts still build")
        XCTAssertEqual(shield.made?.left.map { Array($0.keys) }, ["easyprivacy"])
        XCTAssertNil(shield.trouble)
    }

    // MARK: - pages

    func testAPageBeforeTheListsLoadsUnblockedAndGetsThemWhenTheyArrive() async throws {
        let shield = Shield(folder: folder, fetches: false)
        let controller = WKUserContentController()
        shield.fit(controller, host: "news.example", isPrivate: false)
        XCTAssertEqual(shield.identifiers(on: controller), [])
        shield.start()
        await shield.settled()
        XCTAssertEqual(shield.identifiers(on: controller), ["shield-1-0", "shield-1-1"])
    }

    func testTheListsGoOnAndOffByTheSiteAPageIsHeadingTo() async throws {
        let shield = await started()
        shield.wants = { host, isPrivate in host != "off.example" && !(isPrivate && host == "private-off.example") }
        let page = WKUserContentController(), other = WKUserContentController()
        shield.fit(page, host: "news.example", isPrivate: false)
        shield.fit(other, host: "private-off.example", isPrivate: true)
        XCTAssertEqual(shield.identifiers(on: page).count, 2)
        XCTAssertEqual(shield.identifiers(on: other), [])
        shield.fit(page, host: "off.example", isPrivate: false)
        XCTAssertEqual(shield.identifiers(on: page), [])
        shield.fit(page, host: "news.example", isPrivate: false)
        // The switch off everywhere: every page follows at once.
        shield.wants = { _, _ in false }
        shield.apply()
        XCTAssertEqual(shield.identifiers(on: page), [])
        shield.wants = { _, _ in true }
        shield.apply()
        XCTAssertEqual(shield.identifiers(on: page).count, 2)
        XCTAssertEqual(shield.identifiers(on: other).count, 2)
    }

    // MARK: - scriptlets

    private func started(with list: String, scriptlets allowed: Bool = true) async throws -> Shield {
        let lists = Shield.listsFolder(folder)
        try FileManager.default.createDirectory(at: lists, withIntermediateDirectories: true)
        try list.write(to: lists.appendingPathComponent("easylist.txt"), atomically: true, encoding: .utf8)
        let shield = Shield(folder: folder, fetches: false)
        shield.scriptletsAllowed = allowed
        shield.start()
        await shield.settled()
        return shield
    }

    /// A controller as WebPool makes one: Dark Reader's page-world proxy and
    /// its own world, then a page-world reporter at the end.
    private func pageController() -> WKUserContentController {
        let controller = WKUserContentController()
        WebsiteDarkening.install(in: controller, enabled: { false })
        controller.addUserScript(WKUserScript(source: "/* reporter */", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        return controller
    }

    private func ids(_ scripts: [WKUserScript]) -> Set<ObjectIdentifier> { Set(scripts.map(ObjectIdentifier.init)) }

    private func runsFirst(_ script: WKUserScript, on controller: WKUserContentController) -> Bool {
        let scripts = controller.userScripts
        guard let at = scripts.firstIndex(where: { $0 === script }),
              let proxy = scripts.firstIndex(where: { $0.source == WebsiteDarkening.proxy }),
              let reporter = scripts.firstIndex(where: { $0.source == "/* reporter */" }) else { return false }
        return at < proxy && proxy < reporter
    }

    func testTheScriptletsGoOnBeforeThePagesOwnScriptsOnlyWhereTheListsDo() async throws {
        let shield = try await started(with: "news.example##+js(aopr, aclib)\n")
        let script = try XCTUnwrap(shield.scriptlets)
        XCTAssertEqual(script.injectionTime, .atDocumentStart)
        XCTAssertFalse(script.isForMainFrameOnly, "every frame picks its own rules")
        XCTAssertTrue(script.source.contains(#""hosts":" news.example=0 ""#))
        XCTAssertFalse(script.source.contains("__YAB_"))
        shield.wants = { host, _ in host != "off.example" }
        let controller = pageController()
        // A copy: WebKit hands out its live array.
        let own = controller.userScripts.map { $0 }
        shield.fit(controller, host: "news.example", isPrivate: false)
        XCTAssertTrue(runsFirst(script, on: controller), "before Dark Reader's proxy and the page's code")
        XCTAssertEqual(ids(controller.userScripts), ids(own + [script]), "nothing of the page's own lost or doubled")
        XCTAssertFalse(shield.identifiers(on: controller).isEmpty)

        let placed = shield.placements
        shield.fit(controller, host: "news.example", isPrivate: false)
        shield.fit(controller, host: "other.example", isPrivate: false)
        XCTAssertEqual(shield.placements, placed, "the same script and lists: nothing done")

        shield.fit(controller, host: "off.example", isPrivate: false)
        XCTAssertEqual(ids(controller.userScripts), ids(own), "off for the site: the script goes with the lists")
        XCTAssertEqual(shield.identifiers(on: controller), [])
        shield.fit(controller, host: "news.example", isPrivate: false)
        XCTAssertTrue(runsFirst(script, on: controller))

        shield.wants = { _, _ in false }
        shield.apply()
        XCTAssertEqual(ids(controller.userScripts), ids(own), "the switch off everywhere")
        shield.wants = { _, _ in true }
        shield.apply()
        XCTAssertTrue(runsFirst(script, on: controller))
        XCTAssertEqual(controller.userScripts.count, own.count + 1)
    }

    func testTheLibraryIsServedCompacted() throws {
        let library = try XCTUnwrap(Shield.scriptletLibrary)
        XCTAssertTrue(library.contains("__YAB_TABLE__") && library.contains("__YAB_OFF__"))
        XCTAssertFalse(library.contains("__YAB_GUARD__"), "the click guard is in, at its marker")
        XCTAssertTrue(library.contains("function guardClicks("))
        let lines = library.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertTrue(lines.allSatisfy { !$0.isEmpty && !$0.hasPrefix(" ") && !$0.hasPrefix("\t") && !$0.hasPrefix("//") })
    }

    func testTheScriptletsAreKeptBesideTheirBuildFoundAtTheNextLaunchAndGoWithIt() async throws {
        let first = try await started(with: "news.example##+js(aopr, aclib)\n")
        let one = folder.appendingPathComponent("scriptlets-1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: one.path))
        let again = Shield(folder: folder, fetches: false)
        again.start()
        await again.settled()
        XCTAssertEqual(again.compiles, 0)
        XCTAssertNotNil(again.scriptlets)
        XCTAssertEqual(again.scriptlets?.source, first.scriptlets?.source)

        try "other.example##+js(nowoif)\n".write(to: Shield.listsFolder(folder).appendingPathComponent("easylist.txt"), atomically: true, encoding: .utf8)
        again.compile()
        await again.settled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: one.path), "the old build's table goes with its lists")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("scriptlets-2.json").path))
        XCTAssertEqual(again.scriptlets?.source.contains("other.example"), true)
        XCTAssertEqual(again.scriptlets?.source.contains("news.example"), false)
    }

    func testNoScriptWithTheSwitchOffOrNoneInTheLists() async throws {
        XCTAssertTrue(Shield.scriptletsAllowed(environment: [:], arguments: []))
        XCTAssertFalse(Shield.scriptletsAllowed(environment: ["YAB_SHIELD_SCRIPTLETS": "0"], arguments: []))
        XCTAssertFalse(Shield.scriptletsAllowed(environment: [:], arguments: ["-YAB_SHIELD_SCRIPTLETS", "0"]))
        let plain = Shield(folder: folder.appendingPathComponent("plain", isDirectory: true), fetches: false)
        plain.start()
        await plain.settled()
        XCTAssertNil(plain.scriptlets, "the built-in list has no ##+js: it names no site, so no page gets the click guard either")
        XCTAssertFalse(plain.lists.isEmpty)
        let off = try await started(with: "news.example##+js(aopr, aclib)\n", scriptlets: false)
        XCTAssertNil(off.scriptlets)
        XCTAssertFalse(off.lists.isEmpty, "the lists block as before")
        let controller = pageController()
        let own = controller.userScripts.map { $0 }
        off.fit(controller, host: "news.example", isPrivate: false)
        XCTAssertEqual(ids(controller.userScripts), ids(own))
        XCTAssertEqual(off.placements, 0)
    }

    func testANewPageGetsTheScriptletsFirstWithNothingMoved() async throws {
        let shield = try await started(with: "127.0.0.1##+js(aopr, aclib)\n")
        let script = try XCTUnwrap(shield.scriptlets)
        let pool = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
        pool.shield = shield
        let tab = Tab(id: "new", title: "New", site: "127.0.0.1", icon: "", url: "http://127.0.0.1:9/page")
        let view = pool.view(for: tab)
        defer { view.stopLoading() }
        let scripts = view.configuration.userContentController.userScripts
        XCTAssertTrue(scripts.first === script)
        XCTAssertEqual(scripts.filter { $0 === script }.count, 1)
        XCTAssertEqual(scripts.filter { $0.source == WebsiteDarkening.proxy }.count, 1)
        XCTAssertEqual(shield.placements, 0, "nothing taken off and put back")
        XCTAssertFalse(shield.identifiers(on: view.configuration.userContentController).isEmpty)
    }

    func testAnAdoptedPageKeepsDarkReaderAndGetsTheScriptletsFirst() async throws {
        let shield = try await started(with: "127.0.0.1##+js(aopr, aclib)\n")
        let script = try XCTUnwrap(shield.scriptlets)
        let pool = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
        pool.shield = shield
        let tab = Tab(id: "adopted", title: "Adopted", site: "127.0.0.1", icon: "", url: "http://127.0.0.1/page")
        let configuration = pool.configurationForPage(for: tab)
        // As a page made elsewhere has one: Dark Reader's handler already on.
        configuration.userContentController = pageController()
        let view = WKWebView(frame: .zero, configuration: configuration)
        XCTAssertTrue(pool.adopt(view, for: tab))
        let scripts = view.configuration.userContentController.userScripts
        XCTAssertEqual(scripts.filter { $0.source == WebsiteDarkening.proxy }.count, 1, "Dark Reader's proxy back, once")
        XCTAssertEqual(scripts.filter { $0.source.hasPrefix("globalThis.__yabWebsiteDarkEngine") }.count, 1)
        let at = try XCTUnwrap(scripts.firstIndex { $0 === script })
        let proxy = try XCTUnwrap(scripts.firstIndex { $0.source == WebsiteDarkening.proxy })
        XCTAssertLessThan(at, proxy)
        XCTAssertFalse(shield.identifiers(on: view.configuration.userContentController).isEmpty)
    }

    // MARK: - which pages

    private func store() throws -> (SettingsStore, UserDefaults, String) {
        let suite = "shield-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (SettingsStore(defaults: defaults), defaults, suite)
    }

    private func app() -> AppModel {
        let world = World(name: "Shield", space: "public", spaces: [Space(id: "public", name: "Public", emoji: "", tint: RGB(235, 235, 235))])
        return AppModel(world: world, fixturesEnabled: true, privateLockEnabled: { false })
    }

    func testTheSiteChoiceBeatsTheMacsAndTheSwitchBeatsEverything() throws {
        let (settings, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = app()
        XCTAssertTrue(app.blocksAds(on: "news.example", isPrivate: false, settings: settings), "on, as on the Mac")
        settings.importShieldPreferences(enabled: true, paused: ["www.Paused.example"])
        XCTAssertFalse(app.blocksAds(on: "paused.example", isPrivate: false, settings: settings), "the Mac's sites are off here too")
        XCTAssertFalse(app.blocksAds(on: "www.paused.example", isPrivate: false, settings: settings))
        XCTAssertTrue(app.blocksAds(on: "news.example", isPrivate: false, settings: settings))
        app.siteSettings.setBlocksAds(true, for: "paused.example", isPrivate: false)
        XCTAssertTrue(app.blocksAds(on: "paused.example", isPrivate: false, settings: settings), "what this iPhone was told wins")
        XCTAssertFalse(app.blocksAds(on: "paused.example", isPrivate: true, settings: settings), "private reads only what was said in private")
        app.siteSettings.setBlocksAds(false, for: "news.example", isPrivate: true)
        XCTAssertFalse(app.blocksAds(on: "news.example", isPrivate: true, settings: settings))
        XCTAssertTrue(app.blocksAds(on: "news.example", isPrivate: false, settings: settings))
        settings.blocksAds = false
        XCTAssertFalse(app.blocksAds(on: "news.example", isPrivate: false, settings: settings))
        XCTAssertFalse(app.blocksAds(on: "paused.example", isPrivate: false, settings: settings), "the switch off, no site blocks")
    }

    func testTheMacsSwitchIsTheDefaultUntilTheIPhoneChooses() throws {
        let (settings, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(settings.blocksAds)
        settings.importShieldPreferences(enabled: false, paused: nil)
        XCTAssertFalse(settings.blocksAds)
        XCTAssertNil(defaults.object(forKey: SettingsStore.Key.blocksAds), "the import stays read-only")
        settings.blocksAds = true
        settings.importShieldPreferences(enabled: false, paused: ["a.example"])
        XCTAssertTrue(settings.blocksAds, "chosen here, it stays")
        XCTAssertTrue(settings.macPausesAds(on: "a.example"))
        XCTAssertTrue(SettingsStore(defaults: defaults).blocksAds)
        settings.importShieldPreferences(enabled: nil, paused: nil)
        XCTAssertFalse(settings.macPausesAds(on: "a.example"), "the account gone, its sites go")
    }

    func testASiteChoiceIsRememberedPrivateOnesOnlyInMemory() throws {
        let suite = "shield-sites-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sites = SiteSettings(defaults: defaults)
        sites.setBlocksAds(false, for: "www.News.example", isPrivate: false)
        sites.setBlocksAds(false, for: "secret.example", isPrivate: true)
        XCTAssertEqual(sites.blocksAds("news.example", isPrivate: false), false)
        XCTAssertNil(sites.blocksAds("news.example", isPrivate: true))
        let later = SiteSettings(defaults: defaults)
        XCTAssertEqual(later.blocksAds("news.example", isPrivate: false), false)
        XCTAssertNil(later.blocksAds("secret.example", isPrivate: true))
        XCTAssertNil(later.blocksAds("secret.example", isPrivate: false))
        later.clear("news.example", isPrivate: false)
        XCTAssertNil(later.blocksAds("news.example", isPrivate: false), "Clear Data takes it with the rest")
        // Settings saved before the blocker read as they were (a dictionary
        // keyed by an enum is an array in JSON).
        let old = #"{"github.com":{"zoom":1.2,"desktop":false,"permissions":["camera","allowed"]}}"#
        defaults.set(Data(old.utf8), forKey: "yab.siteSettings")
        let before = SiteSettings(defaults: defaults)
        XCTAssertEqual(before.zoom("github.com", isPrivate: false), 1.2)
        XCTAssertEqual(before.decision(.camera, for: "github.com", isPrivate: false), .allowed)
        XCTAssertNil(before.blocksAds("github.com", isPrivate: false))
    }

    // MARK: - Settings

    func testPrivacyStartsWithTheSwitchAndItsWordsFollowIt() throws {
        let (settings, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        let content = SettingsContent(store: settings, context: SettingsContext())
        let sections = content.sections(.privacy)
        // Clear History and Website Data closes the page (Settings/ClearBrowsingData).
        XCTAssertEqual(sections.map(\.id), ["privacy.shield", "privacy", "privacy.data"])
        let row = try XCTUnwrap(sections.first?.rows.first)
        XCTAssertEqual(row.id, "privacy.shield")
        XCTAssertEqual(row.title, "Block ads and trackers")
        XCTAssertEqual(sections.first?.rows.count, 1)
        XCTAssertEqual(sections.first?.footer, "Ads and trackers never load. If a site breaks, turn blocking off for it in its Site Settings.")
        guard case let .toggle(binding) = row.kind else { return XCTFail("the blocker is a switch") }
        XCTAssertTrue(binding.wrappedValue)
        binding.wrappedValue = false
        XCTAssertFalse(settings.blocksAds)
        XCTAssertEqual(SettingsContent(store: settings, context: SettingsContext()).sections(.privacy).first?.footer,
                       "Off. Every site loads everything it asks for.")
        XCTAssertEqual(SettingsIndex.matches("ads", content: content).first?.page, .privacy)
    }

    func testABuildThatFailedSaysSoAndOffersTryAgain() throws {
        let (settings, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        var retried = false
        var content = SettingsContent(store: settings, context: SettingsContext(shieldTrouble: Shield.failure))
        content.retryShield = { retried = true }
        let section = try XCTUnwrap(content.sections(.privacy).first)
        XCTAssertEqual(section.rows.map(\.id), ["privacy.shield", "privacy.shield.retry"])
        XCTAssertEqual(section.footer, "The ad blocker's lists didn't build. Nothing is blocked until this clears.")
        guard case let .action(retry) = section.rows[1].kind else { return XCTFail("Try Again does something") }
        retry()
        XCTAssertTrue(retried)
    }
}
