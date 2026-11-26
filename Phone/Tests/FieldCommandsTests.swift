import XCTest
import SyncKit
@testable import YabPhone

/// The menu actions the field finds by name (AGENTS.md: a menu action is
/// discoverable in the command field), keys or not, Private included.
@MainActor
final class FieldCommandsTests: XCTestCase {
    private var app: AppModel!
    private var oldMotion = false
    private let page = URL(string: "https://example.com/a")!

    override func setUpWithError() throws {
        oldMotion = Motion.disabled
        Motion.disabled = true
        app = AppModel(world: try World.load(named: "mira"), fixturesEnabled: false, privateLockEnabled: { false })
    }

    override func tearDown() {
        app = nil
        Motion.disabled = oldMotion
    }

    private func openPage(privately: Bool = false) {
        let tab = PageFixtures.liveTab(for: page, isPrivate: privately)
        app.browser.open(tab, deduplicate: false)
        _ = app.pages.view(for: tab)
        app.surfaces.openField(.address)
    }

    /// The command rows the field shows for the words.
    private func commands(_ words: String) -> [WordRow] {
        app.field.typed(words)
        return app.fieldRows.filter { if case .command = $0.action { true } else { false } }
    }

    private func until(_ done: () -> Bool) async throws {
        let end = Date().addingTimeInterval(3)
        while !done(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(done())
    }

    private func widen() {
        app.workspace.resize(expanded: true)
        app.workspace.windowSize = CGSize(width: 1376, height: 1032)
    }

    func testActionsWithoutAKeyAreFoundByTheirNames() {
        widen()
        openPage()
        for name in ["Save as PDF", "Duplicate Tab", "Open in Split View"] {
            let rows = commands(name.lowercased())
            XCTAssertEqual(app.fieldRows.first?.action, rows.first?.action, "\(name) typed whole leads the rows")
            XCTAssertFalse(rows.isEmpty, name)
        }
    }

    func testActionsWithoutAKeyAreOfferedOnlyWhenTheyCanRun() {
        app.workspace.windowSize = CGSize(width: 800, height: 1100)
        openPage()
        XCTAssertTrue(commands("open in split view").isEmpty, "no split in a narrow window")
        let mail = Tab(id: "mail-tab", title: "Mail", site: "Mail", icon: "mail", url: "https://mail.example.com/")
        app.field.close()
        app.browser.open(mail, deduplicate: false)
        app.surfaces.openField(.address)
        XCTAssertTrue(commands("duplicate tab").isEmpty, "Mail has no page to copy")
    }

    func testDuplicateTabFromTheFieldOpensACopy() async throws {
        openPage()
        let before = app.browser.space.allTabs.count
        let row = try XCTUnwrap(commands("duplicate tab").first)
        app.choose(row)
        try await until { app.browser.space.allTabs.count == before + 1 }
        XCTAssertEqual(app.browser.tab?.navigationURL, page)
    }

    /// A command runs once: the field opened and closed again afterwards
    /// doesn't run it a second time.
    func testAChosenCommandRunsOnlyOnce() async throws {
        openPage()
        let before = app.browser.space.allTabs.count
        app.choose(try XCTUnwrap(commands("duplicate tab").first))
        try await until { app.browser.space.allTabs.count == before + 1 }
        app.surfaces.openField(.address)
        app.field.close()
        try await until { !app.field.shown && app.surfaces.field == nil }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(app.browser.space.allTabs.count, before + 1, "one copy, not two")
    }

    /// A command chosen belongs to the field it was chosen in. The field
    /// opened again before that one has finished closing drops it for good:
    /// closing the new field runs nothing from the old choice.
    func testACommandChosenBeforeAReopenedFieldClosesNeverRunsAfterIt() async throws {
        openPage()
        let other = PageFixtures.liveTab(for: URL(string: "https://example.com/b")!)
        app.browser.open(other, deduplicate: false)
        let before = app.browser.space.allTabs.count
        app.surfaces.openField(.address)
        app.choose(try XCTUnwrap(commands("close tab").first))
        XCTAssertNil(app.surfaces.field)
        XCTAssertTrue(app.field.shown, "the first field is still closing")
        app.surfaces.openField(.address)
        app.field.close()
        try await until { !app.field.shown && app.surfaces.field == nil }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(app.browser.space.allTabs.count, before, "the old Close Tab must not run")

        app.surfaces.openField(.address)
        app.choose(try XCTUnwrap(commands("close tab").first))
        try await until { app.browser.space.allTabs.count == before - 1 }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(app.browser.space.allTabs.count, before - 1, "a new choice runs once")
    }

    func testPrivateOffersOnlyWhatItCanRunAndRunsIt() async throws {
        widen()
        openPage(privately: true)
        XCTAssertTrue(app.field.place.isPrivate)
        for name in ["open in split view", "reopen closed tab", "show all tabs", "new tab"] {
            XCTAssertFalse(commands(name).contains { $0.title.lowercased() == name }, "\(name) leaves Private")
        }
        XCTAssertFalse(commands("reload page").isEmpty)
        let row = try XCTUnwrap(commands("duplicate tab").first)
        let before = app.browser.allTabs.filter(\.isPrivate).count
        app.choose(row)
        try await until { app.browser.allTabs.filter(\.isPrivate).count == before + 1 }
        XCTAssertEqual(app.browser.tab?.isPrivate, true, "the copy stays private")
        XCTAssertEqual(app.browser.tab?.navigationURL, page)
    }

    func testAPrivateFieldOverAnOrdinaryPageLeavesThatPageAlone() {
        openPage()
        app.field.setPrivate(true)
        XCTAssertTrue(app.field.place.isPrivate)
        for name in ["reload page", "duplicate tab", "close tab", "copy link"] {
            XCTAssertTrue(commands(name).isEmpty, "\(name) would act on the ordinary page")
        }
    }

    /// Save as PDF and Print draw the page that is on screen: a tab whose
    /// page isn't loaded yet (a restored tab, a Mac's) has nothing to keep.
    func testSaveAsPDFAndPrintAreOfferedOnlyWithAPageToDraw() throws {
        let restored = Tab(id: "restored", title: "Restored", site: "Restored", icon: "globe", url: "https://example.com/r")
        app.browser.open(restored, deduplicate: false)
        app.surfaces.openField(.address)
        XCTAssertNil(app.pages.liveView(restored.id), "nothing loaded it yet")
        XCTAssertTrue(commands("save as pdf").isEmpty, "no page to save")
        XCTAssertFalse(commands("print").contains { $0.title == "Print" }, "no page to print")
        XCTAssertFalse(app.offers(.print), "the menu bar's Print waits too")

        _ = app.pages.view(for: try XCTUnwrap(app.browser.tab))
        XCTAssertEqual(commands("save as pdf").first?.title, "Save as PDF")
        XCTAssertTrue(commands("print").contains { $0.title == "Print" })
        XCTAssertTrue(app.offers(.print))
    }

    /// Download is offered only over a page that is a file WebKit shows, and
    /// in Private only when that page is private.
    func testDownloadIsOfferedOnlyForAPageThatIsAFile() {
        func offered() -> Bool { commands("download").contains { $0.title == "Download" } }
        openPage()
        XCTAssertFalse(offered(), "an HTML page has nothing to download")
        app.pageStateOverride = WebPool.PageState(downloadable: true)
        XCTAssertTrue(offered())
        XCTAssertEqual(app.fieldRows.first?.title, "Download", "typed whole, it leads the rows")
        app.field.setPrivate(true)
        XCTAssertFalse(offered(), "a private field leaves the ordinary page alone")
        app.field.close()
        openPage(privately: true)
        XCTAssertTrue(offered(), "a private page in front may keep its file")
    }

    func testDuplicateTabOnAMacTabOpensACopyInThatRowsSpace() throws {
        let space = try XCTUnwrap(app.browser.spaces.first { !$0.isPrivate && $0.id != app.browser.spaceID }?.id)
        let synced = SyncTab(id: "AAAAAAAA-0000-4000-8000-0000000000aa", space: "mac-space",
                             url: "https://example.com/on-mac", title: "On the Mac")
        let before = app.browser.space(space)?.allTabs.count ?? 0
        app.duplicateFromMac(synced, in: space)
        XCTAssertEqual(app.browser.spaceID, space)
        XCTAssertEqual(app.browser.space(space)?.allTabs.count, before + 1)
        XCTAssertEqual(app.browser.tab?.navigationURL?.absoluteString, "https://example.com/on-mac")
        XCTAssertNotEqual(app.browser.tab?.id, synced.id, "a local copy, not the Mac's tab")
    }

    /// Every command a private field offers over a private page still runs
    /// once the field has gone: the offer and the run agree.
    func testEveryCommandPrivateOffersRunsOnceTheFieldIsGone() {
        widen()
        app.workspace.tabletControls = true
        openPage(privately: true)
        app.pageStateOverride = WebPool.PageState(downloadable: true)
        let offered = app.commandCandidates.compactMap { FieldCommand(token: $0.token) }
        XCTAssertEqual(Set(offered.map(\.title)), ["New Private Tab", "Show or Hide Sidebar",
                                                  "Close Tab", "Reload Page", "Zoom In", "Zoom Out", "Actual Size",
                                                  "Copy Link", "Print…", "Save as PDF", "Duplicate Tab", "Download",
                                                  "Show Downloads"])
        app.field.close()
        for command in offered {
            XCTAssertTrue(app.mayRun(command, privately: true), "\(command.title) is offered in Private, so it runs")
        }
    }

    /// A command chosen in a private field runs only if, once the field has
    /// gone, Private may still run it: the page in front is no longer the
    /// private one, so the ordinary page is left alone.
    func testAPrivateChoiceRechecksItsPageWhenItRuns() async throws {
        let ordinary = try XCTUnwrap(app.browser.tab)
        openPage(privately: true)
        let row = try XCTUnwrap(commands("duplicate tab").first)
        let before = app.browser.allTabs.count
        app.choose(row)
        app.browser.select(ordinary.id)
        XCTAssertFalse(app.browser.tab?.isPrivate ?? true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(app.browser.allTabs.count, before, "the ordinary page is not the private field's to copy")
    }

    /// Show Downloads is a command wherever a downloads list is in reach:
    /// the iPhone's plate page, the iPad's downloads button.
    func testShowDownloadsOpensThePlatesDownloadsOnIPhone() async throws {
        openPage()
        let row = try XCTUnwrap(commands("show downloads").first)
        XCTAssertEqual(app.fieldRows.first?.title, "Show Downloads", "typed whole, it leads the rows")
        app.choose(row)
        try await until { app.surfaces.menu == .plate && app.pageMenu.page == .downloads }
    }

    func testShowDownloadsOpensTheIPadsButtonWhereOneIsShown() async throws {
        widen()
        app.workspace.tabletControls = true
        app.workspace.preferences.sidebarShown = true
        // Nothing downloaded, whatever an earlier run left in the folder.
        app.downloads.pretend([])
        openPage()
        let row = try XCTUnwrap(commands("show downloads").first)
        let asked = app.workspace.downloadsShown
        app.choose(row)
        try await until { app.workspace.downloadsShown == asked + 1 }
        XCTAssertNil(app.surfaces.menu, "the iPad's list is its button's, not the phone's plate")

        // A window too narrow for the sidebar beside a split: no sidebar on
        // screen, so no button in its foot, whatever the switch says.
        app.field.close()
        app.workspace.windowSize = CGSize(width: 900, height: 700)
        let other = PageFixtures.liveTab(for: URL(string: "https://example.com/b")!)
        app.browser.open(other, deduplicate: false)
        let front = try XCTUnwrap(app.browser.tab?.id)
        let beside = try XCTUnwrap(app.browser.space.today.first { $0.id != front }?.id)
        app.workspace.openBeside(current: beside, other: front)
        XCTAssertTrue(app.workspace.paired)
        app.surfaces.openField(.address)
        XCTAssertTrue(commands("show downloads").isEmpty, "the sidebar gave way to the split")
        app.field.close()
        app.workspace.fullSpread()
        app.surfaces.openField(.address)
        XCTAssertFalse(commands("show downloads").isEmpty, "one page leaves room for the sidebar")

        app.field.close()
        app.workspace.preferences.sidebarShown = false
        app.surfaces.openField(.address)
        XCTAssertTrue(commands("show downloads").isEmpty, "no button in the toolbar with nothing downloaded")
    }
}
