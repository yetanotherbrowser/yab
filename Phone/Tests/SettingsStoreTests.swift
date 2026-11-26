import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

/// Settings keeps what the person chose, and says it in the prototype's words.
@MainActor
final class SettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "settings-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsAreThePrototypes() {
        let store = SettingsStore(defaults: defaults, supportsOnDeviceAnswers: true)
        XCTAssertEqual(store.appearance, .system)
        XCTAssertFalse(store.darkenWebsites)
        XCTAssertEqual(store.pageAnswers, .iPhone)
        XCTAssertEqual(store.agent, .claude)
        XCTAssertTrue(store.faceIDForYes)
        XCTAssertEqual(store.lockScreen, .afterFaceID)
        XCTAssertFalse(store.privateLock)
        XCTAssertEqual(store.notifications, .needsYou)
        XCTAssertFalse(store.welcomed)
        // The Mac's Today on the spaces' pages: off until turned on.
        XCTAssertFalse(store.macTabs)
    }

    func testChoicesOutliveTheStore() {
        let store = SettingsStore(defaults: defaults)
        store.appearance = .dark
        store.darkenWebsites = true
        store.pageAnswers = .mac
        store.agent = .chatGPT
        store.faceIDForYes = false
        store.lockScreen = .never
        store.privateLock = true
        store.notifications = .off
        store.welcomed = true
        store.macTabs = true
        let again = SettingsStore(defaults: defaults)
        XCTAssertEqual(again.appearance, .dark)
        XCTAssertTrue(again.darkenWebsites)
        XCTAssertEqual(again.pageAnswers, .mac)
        XCTAssertEqual(again.agent, .chatGPT)
        XCTAssertFalse(again.faceIDForYes)
        XCTAssertEqual(again.lockScreen, .never)
        XCTAssertTrue(again.privateLock)
        XCTAssertEqual(again.notifications, .off)
        XCTAssertTrue(again.welcomed)
        XCTAssertTrue(again.macTabs)
    }

    func testPageAnswerDefaultFollowsDeviceSupportButSavedChoicesWin() {
        XCTAssertEqual(SettingsStore(defaults: defaults, supportsOnDeviceAnswers: true).pageAnswers, .iPhone)
        let unsupported = SettingsStore(defaults: defaults, supportsOnDeviceAnswers: false)
        XCTAssertEqual(unsupported.pageAnswers, .mac)
        XCTAssertNil(defaults.object(forKey: SettingsStore.Key.pageAnswers))
        unsupported.pageAnswers = .iPhone
        XCTAssertEqual(SettingsStore(defaults: defaults, supportsOnDeviceAnswers: false).pageAnswers, .iPhone)
        unsupported.pageAnswers = .mac
        XCTAssertEqual(SettingsStore(defaults: defaults, supportsOnDeviceAnswers: true).pageAnswers, .mac)
    }

    func testWebsiteDarkeningNotifiesItsStoreOnlyWhenTheChoiceChanges() {
        let store = SettingsStore(defaults: defaults)
        let changed = expectation(description: "website darkening changes twice")
        changed.expectedFulfillmentCount = 2
        let token = NotificationCenter.default.addObserver(forName: SettingsStore.websiteDarkeningChanged, object: store, queue: .main) { _ in
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        store.darkenWebsites = false
        store.darkenWebsites = true
        store.darkenWebsites = true
        store.darkenWebsites = false
        XCTAssertFalse(SettingsStore(defaults: defaults).darkenWebsites)
        wait(for: [changed], timeout: 1)
    }

    func testWebsiteDarkeningSwitchIsAvailableWithoutAMacAndPersistsItsChoice() throws {
        let store = SettingsStore(defaults: defaults)
        let content = SettingsContent(store: store, context: SettingsContext(hasMac: false))
        let row = try XCTUnwrap(content.sections(.appearance).flatMap(\.rows).first { $0.id == "appearance.darkenWebsites" })
        guard case let .toggle(binding) = row.kind else { return XCTFail("Darken Websites must remain a switch") }
        XCTAssertFalse(binding.wrappedValue)
        binding.wrappedValue = true
        XCTAssertTrue(store.darkenWebsites)
        XCTAssertTrue(SettingsStore(defaults: defaults).darkenWebsites)
        XCTAssertTrue(SettingsIndex.matches("darken websites", content: content).contains { $0.page == .appearance })
    }

    func testAChangeIsObserved() {
        let store = SettingsStore(defaults: defaults)
        let changed = expectation(description: "appearance observed")
        withObservationTracking {
            _ = store.appearance
        } onChange: {
            changed.fulfill()
        }
        store.appearance = .light
        wait(for: [changed], timeout: 1)
    }

    func testAnUnknownStoredValueFallsBack() {
        defaults.set("sepia", forKey: SettingsStore.Key.appearance)
        XCTAssertEqual(SettingsStore(defaults: defaults).appearance, .system)
    }

    func testTestRunsKeepTheirOwnEmptySuite() {
        let options = LaunchOptions(arguments: ["Yab", "-YabWorld", "empty"])
        let suite = SettingsStore.launchDefaults(options)
        XCTAssertNotEqual(suite, UserDefaults.standard)
        suite.set(true, forKey: SettingsStore.Key.welcomed)
        // The next launch of a test run starts empty again.
        XCTAssertNil(SettingsStore.launchDefaults(options).object(forKey: SettingsStore.Key.welcomed))
    }

    func testAppearanceResolves() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.colorScheme(systemIsDark: true), .dark)
        XCTAssertEqual(store.colorScheme(systemIsDark: false), .light)
        store.appearance = .light
        XCTAssertEqual(store.colorScheme(systemIsDark: true), .light)
        store.appearance = .dark
        XCTAssertEqual(store.colorScheme(systemIsDark: false), .dark)
        XCTAssertEqual(UIUserInterfaceStyle(SettingsStore.Appearance.system), .unspecified)
        XCTAssertEqual(UIUserInterfaceStyle(SettingsStore.Appearance.dark), .dark)
    }

    func testTheWordSettingsInAField() {
        for words in ["sett", "Settings", "  SETTINGS ", "set", "pre", "pref", "preferences"] {
            XCTAssertTrue(SettingsStore.wantsSettings(words), words)
        }
        for words in ["", "se", "settingsx", "setup", "prefs", "settings for wifi"] {
            XCTAssertFalse(SettingsStore.wantsSettings(words), words)
        }
        XCTAssertEqual(SettingsFieldRow.title, "Settings")
        XCTAssertEqual(SettingsFieldRow.subtitle, "Yab on this \(DeviceWord.name)")
    }

    func testVersionIsTheBundles() {
        // The bundle's own (MARKETING_VERSION in Phone/project.yml), whatever version it is now.
        let bundled = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertNotNil(bundled)
        XCTAssertEqual(SettingsStore.version(), bundled)
        XCTAssertFalse(SettingsStore.build().isEmpty)
    }
}

/// The sheet says what the prototype's sheet says, in its order.
@MainActor
final class SettingsContentTests: XCTestCase {
    private func content(_ context: SettingsContext = SettingsContext(), configure: (SettingsStore) -> Void = { _ in }) -> SettingsContent {
        let defaults = UserDefaults(suiteName: "settings-content-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        configure(store)
        return SettingsContent(store: store, context: context)
    }

    func testTheSheetIsThePrototypes() {
        let root = content().root
        XCTAssertEqual(root.map(\.title), ["Your Mac", "Answers", "Tabs", "Privacy", nil])
        let rows = root.flatMap(\.rows).map { "\($0.title) | \($0.value ?? "")" }
        XCTAssertEqual(rows, [
            "MacBook Pro | Online",
            "Agent | Claude · on your Mac",
            "About a page | This \(DeviceWord.name)",
            "Everything else | Claude",
            "Default Browser | Yab",
            "Today | This \(DeviceWord.name)’s own",
            "Face ID for Pay and Post | On",
            "Lock Screen Details | After Face ID",
            "Private Tabs | Not kept",
            "Notifications | Needs you",
            "Appearance | System",
            "About Yab | 0.0.1",
        ])
        XCTAssertEqual(root[0].footer, "Tasks run in Yab on your Mac, with your sign-ins. The \(DeviceWord.name) sends codes and the yes signed by Face ID.")
        XCTAssertEqual(root[2].footer, "Spaces, pins and kept tabs are the same on your Mac; Today is this \(DeviceWord.name)’s own. Mail stays in Yab on your Mac.")
        XCTAssertNil(root[1].footer)
    }

    func testTheGlyphsAreThePrototypes() {
        let icons: [String] = content().root.flatMap(\.rows).map { row in
            switch row.icon {
            case let .glyph(name)?: name.rawValue
            case .face?: "face"
            case .mark?: "mark"
            case nil: "none"
            }
        }
        XCTAssertEqual(icons, ["Macbook", "face", "Sparkle", "face", "Globe", "SquareBehindSquare1",
                               "FaceId", "Lock", "Incognito", "BellCheck", "SettingsGear1", "mark"])
    }

    func testValuesFollowTheChoices() {
        let root = content(SettingsContext(macAsleep: true, yabIsDefaultBrowser: false)) { store in
            store.agent = .chatGPT
            store.pageAnswers = .mac
            store.appearance = .dark
            store.notifications = .needsYouAndDone
        }.root
        let values = Dictionary(uniqueKeysWithValues: root.flatMap(\.rows).map { ($0.id, $0.value ?? "") })
        XCTAssertEqual(values["mac"], "Asleep")
        XCTAssertEqual(values["agent"], "ChatGPT · on your Mac")
        XCTAssertEqual(values["aboutPage"], "Your Mac")
        XCTAssertEqual(values["everythingElse"], "ChatGPT")
        XCTAssertEqual(values["defaultBrowser"], "Not Yet")
        XCTAssertEqual(values["appearance"], "Dark")
        XCTAssertEqual(values["notifications"], "Needs you and done")
    }

    /// "Opens hidden when you log in" only for a Mac that says Open at Login
    /// is on there; else the words say where to turn it on.
    func testYourMacSaysOpenAtLoginOnlyWhenTheMacDoes() {
        let on = content(SettingsContext(macOpensAtLogin: true)).sections(.mac)[0].footer ?? ""
        XCTAssertTrue(on.contains("Yab opens hidden when you log in"), on)
        let off = content(SettingsContext(macOpensAtLogin: false)).sections(.mac)[0].footer ?? ""
        XCTAssertFalse(off.contains("when you log in"), off)
        XCTAssertTrue(off.contains("Open at Login in Yab’s Settings › General"), off)
    }

    func testNoMacYetAsksToJoin() {
        let root = content(SettingsContext(hasMac: false)).root
        let first = root[0].rows[0]
        XCTAssertEqual(first.id, "join")
        XCTAssertEqual(first.title, "Join Your Mac")
        guard case .join = first.kind else { return XCTFail("the first row joins a Mac") }
        XCTAssertEqual(root.flatMap(\.rows).first { $0.id == "everythingElse" }?.value, "Needs your Mac")
        // The agent has nowhere to run yet either, and the words say so.
        XCTAssertEqual(root.flatMap(\.rows).first { $0.id == "agent" }?.value, "Needs your Mac")
        XCTAssertFalse(root[0].footer?.hasPrefix("Tasks run in Yab on your Mac") ?? true)
    }

    func testFootersFollowTheChoice() {
        let defaults = UserDefaults(suiteName: "settings-footers-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let content = SettingsContent(store: store, context: SettingsContext())
        var said: Set<String> = []
        for level in SettingsStore.Notifications.allCases {
            store.notifications = level
            let footer = content.sections(.notifications)[0].footer ?? ""
            XCTAssertEqual(footer, SettingsContent.footer(level))
            said.insert(footer)
        }
        XCTAssertEqual(said.count, SettingsStore.Notifications.allCases.count, "each choice says its own")
        store.notifications = .off
        XCTAssertFalse(content.sections(.notifications)[0].footer!.hasPrefix("Only when"))
        said = []
        for lock in SettingsStore.LockScreen.allCases {
            store.lockScreen = lock
            said.insert(content.sections(.lockScreen)[0].footer ?? "")
        }
        XCTAssertEqual(said.count, SettingsStore.LockScreen.allCases.count)
        for text in said { XCTAssertFalse(text.contains("\u{2014}"), text) }
    }

    func testTheMacsPageHasItsAgent() {
        let defaults = UserDefaults(suiteName: "settings-mac-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let content = SettingsContent(store: store, context: SettingsContext())
        let sections = content.sections(.mac)
        XCTAssertEqual(sections.map(\.id), ["mac", "mac.agent", "sync"])
        let chatGPT = sections[1].rows.first { $0.id == "mac.agent.chatGPT" }
        guard case let .choice(selected, choose)? = chatGPT?.kind else { return XCTFail("no agent to choose on the Mac's page") }
        XCTAssertFalse(selected)
        choose()
        XCTAssertEqual(store.agent, .chatGPT)
        XCTAssertTrue(content.sections(.mac)[1].rows.first { $0.id == "mac.agent.chatGPT" }?.isSelected ?? false)
        XCTAssertTrue(content.sections(.agent)[0].rows.first { $0.id == "agent.chatGPT" }?.isSelected ?? false)
    }

    func testEverySettingDetailIsReachableFromTheActualIndex() {
        let pages = SettingsIndex.groups(alternateIcons: true).flatMap { $0 }
        XCTAssertEqual(Set(pages).count, pages.count, "one real root tile for each page")
        var reachable = Set(pages)
        var pending = pages
        let content = content()
        while let page = pending.popLast() {
            for row in content.sections(page).flatMap(\.rows) {
                if case let .page(child) = row.kind, reachable.insert(child).inserted { pending.append(child) }
            }
        }
        XCTAssertEqual(reachable, Set(SettingsPageID.allCases), "a detail must remain reachable from the index")
    }

    func testEveryPageHasWordsAndAChoiceSticks() {
        let defaults = UserDefaults(suiteName: "settings-pages-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let content = SettingsContent(store: store, context: SettingsContext())
        for page in SettingsPageID.allCases {
            let sections = content.sections(page)
            // App Icon and History are their own pages (Cover Flow and a
            // button; the list of pages), no rows.
            XCTAssertEqual(sections.isEmpty, page == .appIcon || page == .history, page.rawValue)
            XCTAssertFalse(SettingsContent.title(page).isEmpty)
            for text in sections.compactMap(\.footer) + sections.flatMap(\.rows).map(\.title) {
                XCTAssertFalse(text.contains("\u{2014}"), "no em dashes: \(text)")
            }
        }
        // Appearance: Dark chosen on its page.
        let dark = content.sections(.appearance).flatMap(\.rows).first { $0.id == "appearance.dark" }
        guard case let .choice(selected, choose)? = dark?.kind else { return XCTFail("no Dark choice") }
        XCTAssertFalse(selected)
        choose()
        XCTAssertEqual(store.appearance, .dark)
        let again = content.sections(.appearance).flatMap(\.rows).first { $0.id == "appearance.dark" }
        XCTAssertTrue(again?.isSelected ?? false)
        // The Mac's page carries the Sync row, which joins.
        let sync = content.sections(.mac).flatMap(\.rows).first { $0.id == "sync" }
        guard case .join? = sync?.kind else { return XCTFail("Sync joins a Mac") }
    }

    func testTheRootWordsHaveNoEmDashes() {
        for section in content().root {
            for text in [section.title, section.footer].compactMap({ $0 }) + section.rows.flatMap({ [$0.title, $0.value ?? ""] }) {
                XCTAssertFalse(text.contains("\u{2014}"), text)
            }
        }
    }
}

/// Sheets grow from what summoned them, or rise; the first launch welcomes.
@MainActor
final class SettingsMotionTests: XCTestCase {
    // An earlier suite may leave motion off; these tests read the motion.
    override func setUp() {
        Motion.disabled = false
    }

    override func tearDown() {
        Motion.disabled = false
    }

    func testEntranceAndExitAreTheCodeAndYesSheets() {
        XCTAssertEqual("\(GrowingSurface.entrance(from: CGRect(x: 132, y: 528, width: 250, height: 44)).name)", "sheetGrow")
        XCTAssertEqual("\(GrowingSurface.entrance(from: nil).name)", "sheetRise")
        XCTAssertEqual("\(GrowingSurface.exit(back: true).name)", "sheetBack")
        XCTAssertEqual("\(GrowingSurface.exit(back: false).name)", "sheetDrop")
        XCTAssertEqual(Motion.sheetGrow.duration, 0.34, accuracy: 0.001)
        XCTAssertEqual(Motion.sheetRise.duration, 0.3, accuracy: 0.001)
        XCTAssertEqual(Motion.sheetBack.duration, 0.26, accuracy: 0.001)
        XCTAssertEqual(Motion.sheetDrop.duration, 0.2, accuracy: 0.001)
        XCTAssertEqual(Motion.sheetContents.duration, 0.22 + 0.09, accuracy: 0.001)
        XCTAssertEqual(Motion.sheetContentsOut.duration, 0.12, accuracy: 0.001)
        XCTAssertEqual(Motion.welcomeOut.duration, 0.18, accuracy: 0.001)
    }

    /// Settings is a plain sheet: up from below and down out of sight by its
    /// own motions (0.22 s ease-out, 0.16 s ease-in), never out of an origin,
    /// opaque all the way.
    func testSettingsIsAPlainSheet() {
        let surface = GrowingSurface(plain: .init(up: .settingsOpen, down: .settingsClose))
        let before = TaskMotion.played.count
        surface.show(from: CGRect(x: 10, y: 10, width: 100, height: 44))
        XCTAssertFalse(surface.grewFromOrigin, "an origin is ignored")
        XCTAssertNil(surface.origin)
        XCTAssertEqual(surface.grown, 0)
        XCTAssertEqual(surface.contents, 1, "what it holds comes with it, no later fade")
        surface.appeared()
        XCTAssertEqual(surface.grown, 1)
        XCTAssertEqual(surface.presence(height: 800), 1)
        surface.drag = 400
        XCTAssertEqual(surface.presence(height: 800), 0.5, accuracy: 0.001)
        surface.drag = 0
        surface.hide(back: true)
        XCTAssertEqual(Array(TaskMotion.played.dropFirst(before)), ["settingsOpen", "settingsClose"], "back or not, it goes down")
        // The whole screen as iOS presents one (d0ca2190), pages as iOS's
        // navigation pushes them (fc244762).
        XCTAssertEqual(Motion.settingsOpen.duration, 0.5, accuracy: 0.001)
        XCTAssertEqual(Motion.settingsClose.duration, 0.3, accuracy: 0.001)
        XCTAssertEqual(Motion.settingsPush.duration, 0.42, accuracy: 0.001)
        XCTAssertEqual(Motion.settingsBack.duration, 0.35, accuracy: 0.001)
        XCTAssertNotNil(SettingsUI.shared.sheet.plain, "the app's Settings sheet is the plain one")
    }

    func testStillSurfacesLandAtOnce() {
        Motion.disabled = true
        let surface = GrowingSurface()
        surface.show(from: CGRect(x: 10, y: 10, width: 100, height: 44))
        XCTAssertTrue(surface.presented)
        XCTAssertEqual(surface.grown, 1)
        XCTAssertEqual(surface.contents, 1)
        XCTAssertTrue(surface.settled, "in place at once, what it covers may leave the tree")
        var gone = false
        surface.hide(back: true) { gone = true }
        XCTAssertTrue(gone)
        XCTAssertFalse(surface.presented)
        XCTAssertFalse(surface.settled)
    }

    func testAGrowingSurfaceWaitsForItsViewThenGrows() {
        let surface = GrowingSurface()
        surface.show(from: CGRect(x: 10, y: 10, width: 100, height: 44))
        XCTAssertTrue(surface.presented)
        XCTAssertTrue(surface.grewFromOrigin)
        XCTAssertEqual(surface.grown, 0, "not before its view is on screen")
        XCTAssertEqual(surface.contents, 0)
        XCTAssertFalse(surface.settled, "moving: what it covers stays")
        surface.appeared()
        XCTAssertEqual(surface.grown, 1)
        XCTAssertEqual(surface.contents, 1)
    }

    func testTheClipGrowsFromTheOrigin() {
        let origin = CGRect(x: 132, y: 468, width: 250, height: 44)
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 814)
        let start = GrowClip(origin: origin, originRadius: 16, topRadius: 38, progress: 0).path(in: bounds).boundingRect
        XCTAssertEqual(start.minX, origin.minX, accuracy: 0.5)
        XCTAssertEqual(start.minY, origin.minY, accuracy: 0.5)
        XCTAssertEqual(start.width, origin.width, accuracy: 0.5)
        let end = GrowClip(origin: origin, originRadius: 16, topRadius: 38, progress: 1).path(in: bounds).boundingRect
        XCTAssertEqual(end.minY, bounds.minY, accuracy: 0.5)
        XCTAssertEqual(end.width, bounds.width, accuracy: 0.5)
        XCTAssertEqual(end.height, bounds.height, accuracy: 0.5)
        // On its way, every corner at the origin's radius going to 34: the
        // path holds a point a 16 corner cuts at the start and 34 doesn't.
        let corner = { (radius: CGFloat, progress: CGFloat) -> Bool in
            let clip = GrowClip(origin: origin, originRadius: radius, topRadius: 38, progress: progress).path(in: bounds)
            let frame = clip.boundingRect
            return clip.contains(CGPoint(x: frame.minX + 3, y: frame.minY + 3))
        }
        XCTAssertTrue(corner(4, 0), "a small radius keeps its corner")
        XCTAssertFalse(corner(25, 0), "a capsule's origin starts round")
        XCTAssertFalse(corner(16, 0.99), "near the end the corners are 34")
    }

    func testAShowKeepsItsOriginsRadius() {
        Motion.disabled = true
        let surface = GrowingSurface()
        surface.show(from: CGRect(x: 20, y: 682, width: 362, height: 50), radius: 25)
        XCTAssertEqual(surface.originRadius, 25)
        surface.dismissNow()
        surface.show(from: CGRect(x: 12, y: 112, width: 378, height: 44))
        XCTAssertEqual(surface.originRadius, Metrics.Settings.originRadius)
    }

    func testOriginsComeIntoTheSheetsCoordinates() {
        let row = CGRect(x: 12, y: 172, width: 378, height: 44)
        XCTAssertEqual(SettingsUI.inSheet(row), CGRect(x: 12, y: 112, width: 378, height: 44))
    }

    func testANewSettingsForgetsWhereItWasScrolled() {
        let ui = SettingsUI()
        ui.rootOffset = 140
        ui.rowFrames["mac"] = CGRect(x: 12, y: 172, width: 378, height: 44)
        ui.settingsGone()
        XCTAssertEqual(ui.rootOffset, 0)
        XCTAssertTrue(ui.rowFrames.isEmpty)
    }

    func testTheAppWearsOneAppearance() {
        let defaults = UserDefaults(suiteName: "settings-appearance-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        store.appearance = .dark
        // Until the app draws dark, every screen of it and the window stay light.
        if !AppAppearance.drawsDark {
            XCTAssertEqual(AppAppearance.scheme(store, systemIsDark: true), .light)
            XCTAssertEqual(AppAppearance.windowStyle(.dark), .light)
        } else {
            XCTAssertEqual(AppAppearance.scheme(store, systemIsDark: false), .dark)
        }
    }

    func testTheWelcomeShowsUntilAnswered() {
        XCTAssertTrue(FirstLaunch.shows(hasMac: false, welcomed: false, forced: nil))
        XCTAssertFalse(FirstLaunch.shows(hasMac: false, welcomed: true, forced: nil))
        XCTAssertFalse(FirstLaunch.shows(hasMac: true, welcomed: false, forced: nil))
        XCTAssertTrue(FirstLaunch.shows(hasMac: true, welcomed: true, forced: true))
        XCTAssertFalse(FirstLaunch.shows(hasMac: false, welcomed: false, forced: false))
        // A Mac found through iCloud Keychain, or one joined mid-flow, keeps
        // the first run up to its end; an earlier join never brings it back.
        XCTAssertTrue(FirstLaunch.shows(hasMac: true, welcomed: false, forced: nil, held: true))
        XCTAssertFalse(FirstLaunch.shows(hasMac: true, welcomed: true, forced: nil, held: true))
        // Begun on this launch, it runs to its end even once answered.
        XCTAssertTrue(FirstLaunch.shows(hasMac: false, welcomed: true, forced: nil, running: true))
        XCTAssertFalse(FirstLaunch.shows(hasMac: false, welcomed: true, forced: false, running: true))
    }

    /// 1813: Use Without a Mac, then a quit on a later page (Open links in
    /// Yab?) brought the whole welcome back over every launch, as only its
    /// last page wrote it down as answered.
    func testUsingYabWithoutAMacAnswersTheWelcomeForLaterLaunches() throws {
        let store = SettingsStore.shared
        let saved = (store.welcomed, store.withoutMac, SettingsUI.shared.welcomeForced, Motion.disabled)
        let run = FirstRun.shared
        defer {
            run.reset()
            store.welcomed = saved.0; store.withoutMac = saved.1
            SettingsUI.shared.welcomeForced = saved.2; Motion.disabled = saved.3
        }
        Motion.disabled = true
        store.welcomed = false; store.withoutMac = false; SettingsUI.shared.welcomeForced = nil
        let app = AppModel(world: try World.load(named: "empty"))
        run.reset()
        XCTAssertTrue(FirstLaunch.shows(app))
        run.begin(app)
        run.forward(app)
        XCTAssertEqual(run.step, .noMac)
        run.forward(app)
        XCTAssertEqual(run.step, .field)
        XCTAssertTrue(store.welcomed, "Use Without a Mac answers the welcome")
        XCTAssertTrue(FirstLaunch.shows(app), "its later pages still run on this launch")
        run.forward(app)
        XCTAssertEqual(run.step, .incognito)
        XCTAssertTrue(FirstLaunch.shows(app))
        // Yab quit here: the next launch has no flow running, and no welcome.
        run.reset()
        XCTAssertFalse(FirstLaunch.shows(app), "a later launch opens the browser")

        // "Yab is on my Mac" after all: unanswered again until it joins.
        run.begin(app)
        run.forward(app)
        run.forward(app)
        XCTAssertTrue(store.welcomed)
        run.back(app)
        XCTAssertEqual(run.step, .noMac)
        run.chooseMac(app)
        XCTAssertFalse(store.welcomed, "a quit before joining brings the welcome back")
    }

    func testTheEmptyWorldHasNoMacAndNoTabs() throws {
        let world = try World.load(named: "empty")
        XCTAssertNil(world.problem)
        XCTAssertFalse(world.mac.joined)
        XCTAssertTrue(world.spaces.allSatisfy { $0.allTabs.isEmpty })
        // Mira has her Mac: joined unless a world says otherwise.
        XCTAssertTrue(try World.load(named: "mira").mac.joined)
    }

    func testEveryStateOfTheBranchIsNamedOnce() {
        let names = StateCatalog.settings.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        for name in ["settings.1", "settings.3", "welcome.1", "welcome.2", "welcome.3", "welcome.4", "welcome.5"] {
            XCTAssertNotNil(StateCatalog.named(name), name)
        }
        XCTAssertEqual(names.filter { $0.hasPrefix("settings.page-") }.count, SettingsPageID.allCases.count)
    }
}

/// UIKit consumers and SwiftUI must use the same palette while Yab's own
/// surfaces are forced light, even if a consumer supplies dark traits.
@MainActor
final class SettingsPaletteTests: XCTestCase {
    func testTheForcedLightPaletteStaysReadableUnderDarkUIKitTraits() {
        guard !AppAppearance.drawsDark else { return }
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        dark.performAsCurrent {
            for color in [SettingsInk.text, SettingsInk.footer] {
                let ink = UIColor(color).resolvedColor(with: dark)
                XCTAssertGreaterThanOrEqual(contrast(ink, .white), 4.5)
                XCTAssertGreaterThanOrEqual(contrast(ink, UIColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 1)), 4.5)
            }
            let ground = UIColor(SettingsInk.ground).resolvedColor(with: dark)
            XCTAssertGreaterThanOrEqual(luminance(ground), 0.99, "the welcome is drawn light")
        }
    }

    private func contrast(_ ink: UIColor, _ ground: UIColor) -> Double {
        let values = [luminance(ink), luminance(ground)]
        return (values.max()! + 0.05) / (values.min()! + 0.05)
    }

    private func luminance(_ color: UIColor) -> Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(alpha, 1, accuracy: 0.001)
        let linear: (CGFloat) -> Double = { component in
            let c = Double(component)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    // MARK: - the default browser

    private func defaultBrowserDefaults() -> UserDefaults {
        let name = "defaultBrowser." + UUID().uuidString
        UserDefaults().removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }

    @MainActor
    func testTheDefaultBrowserIsAskedRarelyAndARefusalKeepsTheAnswer() {
        let defaults = defaultBrowserDefaults(), start = Date()
        var asked = 0
        XCTAssertEqual(DefaultBrowser.refresh(now: start, in: defaults) { asked += 1; return true }, true)
        DefaultBrowser.refresh(now: start.addingTimeInterval(3600), in: defaults) { asked += 1; return false }
        XCTAssertEqual(asked, 1, "Settings opening again spends none of iOS's four answers")
        let refused = NSError(domain: "x", code: 1, userInfo: [UIApplication.CategoryDefaultError.retryAvailableDateErrorKey: start.addingTimeInterval(9000)])
        XCTAssertEqual(DefaultBrowser.refresh(force: true, now: start.addingTimeInterval(7200), in: defaults) { throw refused }, true)
        DefaultBrowser.refresh(force: true, now: start.addingTimeInterval(7300), in: defaults) { asked += 1; return false }
        XCTAssertEqual(asked, 1, "nothing is asked before the date iOS named")
    }

    @MainActor
    func testALinkFromAnotherAppSaysYabIsTheDefault() {
        let defaults = defaultBrowserDefaults()
        XCTAssertNil(DefaultBrowser.answer(in: defaults))
        DefaultBrowser.linkArrived(in: defaults)
        XCTAssertEqual(DefaultBrowser.answer(in: defaults), true)
    }

    @MainActor
    func testTheAppIconsDarkPictureIsItsOwn() throws {
        let light = try XCTUnwrap(PhoneAppIcon.flat.picture(dark: false)?.pngData())
        let dark = try XCTUnwrap(PhoneAppIcon.flat.picture(dark: true)?.pngData())
        XCTAssertNotEqual(light, dark)
    }
}
