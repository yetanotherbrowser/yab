import UIKit
import XCTest
@testable import YabPhone

/// The tab stack's order (TabRecency), what the right button shows, the
/// flick's state and All Tabs' closing and opening, on the model; the
/// fingers are UITests/TabStackTests.
@MainActor
final class TabStackTests: XCTestCase {
    private var oldDisabled = false

    override func setUp() { oldDisabled = Motion.disabled; Motion.disabled = true }
    override func tearDown() { Motion.disabled = oldDisabled }

    private func tab(_ id: String, place: Tab.Place = .today, url: String? = nil, icon: String = "globe") -> Tab {
        Tab(id: id, title: id.capitalized, site: id, icon: icon, url: url ?? "http://127.0.0.1/\(id)", place: place)
    }

    private func mira() throws -> AppModel {
        AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
    }

    /// The selection is followed on the next turn of the main queue.
    private func turn() async {
        for _ in 0..<3 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }

    private func select(_ app: AppModel, _ ids: Tab.ID...) async {
        for id in ids {
            app.browser.select(id)
            await turn()
        }
    }

    // MARK: - the order

    func testTheTabInFrontComesFirstThenTheOnesUsedSinceThenTodaysNeverShownNewestFirst() {
        let space = Space(id: "s", name: "S", emoji: "", tint: RGB(1, 2, 3),
                          today: [tab("new"), tab("mid"), tab("old")], current: "mid")
        XCTAssertEqual(TabRecency.order(of: space, recent: []).map(\.id), ["mid", "new", "old"])
        XCTAssertEqual(TabRecency.order(of: space, recent: ["mid", "old"]).map(\.id), ["mid", "old", "new"])
        // Gone tabs and repeats in the list are skipped.
        XCTAssertEqual(TabRecency.order(of: space, recent: ["gone", "old", "old", "mid"]).map(\.id), ["mid", "old", "new"])
    }

    func testTheOrderHasWhatWasOpenedTheTabInFrontMailNeverAndAnEmptyTabOnlyInFront() {
        let space = Space(id: "s", name: "S", emoji: "", tint: RGB(1, 2, 3),
                          pins: [tab("pin", place: .pinned), Tab(id: "mail", title: "Mail", site: "Mail", icon: "mail", place: .pinned)],
                          kept: [.tab(tab("kept", place: .kept))],
                          today: [tab("blank", url: "about:blank"), tab("page")], current: "page")
        XCTAssertEqual(TabRecency.order(of: space, recent: []).map(\.id), ["page"])
        XCTAssertEqual(TabRecency.order(of: space, recent: ["page", "kept", "mail", "pin", "blank"]).map(\.id), ["page", "kept", "pin"])
        var blankInFront = space
        blankInFront.current = "blank"
        XCTAssertEqual(TabRecency.order(of: blankInFront, recent: []).map(\.id), ["blank", "page"])
    }

    func testMobileSwitcherExcludesMacTodayPinsKeptAndOtherSpaces() {
        var mac = tab("mac"); mac.onMac = true
        let space = Space(id: "s", name: "S", emoji: "", tint: RGB(1, 2, 3),
                          pins: [tab("pin", place: .pinned)],
                          kept: [.tab(tab("kept", place: .kept))],
                          today: [mac, tab("new"), tab("old")], current: "pin")
        XCTAssertEqual(TabRecency.mobileTodayOrder(of: space,
            recent: ["other-space", "mac", "kept", "old", "pin"]).map(\.id), ["pin", "old", "new"], "the page in front keeps its card")
    }

    func testTouchMovesATabToTheFrontOfItsSpaceAndDropLetsAKeptTabGo() {
        var recency = TabRecency()
        recency.touch("a", in: "s")
        recency.touch("b", in: "s")
        recency.touch("a", in: "s")
        recency.touch("x", in: "other")
        XCTAssertEqual(recency.recent(in: "s"), ["a", "b"])
        XCTAssertEqual(recency.recent(in: "other"), ["x"])
        recency.drop("a", in: "s")
        XCTAssertEqual(recency.recent(in: "s"), ["b"])
        for i in 0..<(TabRecency.limit + 20) { recency.touch("t\(i)", in: "s") }
        XCTAssertEqual(recency.recent(in: "s").count, TabRecency.limit)
        XCTAssertEqual(recency.recent(in: "s").first, "t\(TabRecency.limit + 19)")
    }

    func testTheDiskKeepsOnlyPublicSpacesAndTabsThatStillExist() throws {
        let open = Space(id: "public", name: "Public", emoji: "", tint: RGB(1, 2, 3), today: [tab("a"), tab("b")], current: "a")
        var hidden = tab("secret"); hidden.isPrivate = true
        let shy = Space(id: "private", name: "Private", emoji: "", tint: RGB(1, 2, 3), today: [hidden], current: "secret", isPrivate: true)
        var recency = TabRecency()
        recency.touch("b", in: "public"); recency.touch("gone", in: "public"); recency.touch("a", in: "public")
        recency.touch("secret", in: "private")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-recency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = TabRecencyFile(url: folder.appendingPathComponent("tab-recency.json"))
        try file.write(recency, spaces: [shy, open])
        let text = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertFalse(text.contains("secret"), "a private tab's place never reaches the disk")
        XCTAssertFalse(text.contains("gone"))
        let read = file.read(spaces: [shy, open])
        XCTAssertEqual(read.recent(in: "public"), ["a", "b"])
        XCTAssertEqual(read.recent(in: "private"), [])
        XCTAssertEqual(TabRecencyFile(url: folder.appendingPathComponent("missing.json")).read(spaces: [open]), TabRecency())
    }

    // MARK: - the button

    func testTheStackShowsTheTwoTabsUsedBeforeTheOneInFront() async throws {
        let app = try mira()
        let stack = TabStack.of(app)
        await turn()
        // Nothing used yet but Figma: today's, newest first.
        XCTAssertEqual(stack.contents().front?.id, "work-hn")
        XCTAssertEqual(stack.contents().back?.id, "work-gh-pr")
        XCTAssertEqual(stack.contents().count, 6, "Figma, kept and in front, and today's five")
        await select(app, "work-lumen", "work-gh-pr", "work-figma-onb")
        XCTAssertEqual(stack.recency.recent(in: "work").prefix(3), ["work-figma-onb", "work-gh-pr", "work-lumen"])
        XCTAssertEqual(stack.contents().front?.id, "work-gh-pr")
        XCTAssertEqual(stack.contents().back?.id, "work-lumen")
        XCTAssertEqual(stack.previous?.id, "work-gh-pr")
        // A kept tab used here stays in the stack once it is off the front.
        await select(app, "work-ledger", "work-hn")
        XCTAssertEqual(stack.contents().front?.id, "work-ledger")
        XCTAssertEqual(stack.contents().count, 7)
    }

    /// Request 1260: closing the last today's tab brings no pin or kept tab.
    func testClosingTheLastTodaysTabLeavesTheEmptyPageAndAMacTabWaits() async throws {
        let app = try mira()
        let stack = TabStack.of(app)
        app.browser.select("work-hn")
        for tab in app.browser.space.today { app.browser.close(tab.id) }
        await turn()
        XCTAssertNil(app.browser.tab)
        XCTAssertFalse(app.browser.space.pins.isEmpty)
        XCTAssertFalse(app.browser.space.keptTabs.isEmpty)
        XCTAssertEqual(stack.contents().count, 0)
        XCTAssertFalse(stack.contents().showsStack)
        XCTAssertFalse(stack.contents().loneCard)
        // A tab the Mac opens doesn't come in front; it waits as the one card.
        var next = app.browser.space
        next.today = [Tab(id: "mac", title: "Mac", site: "Mac", icon: "globe", url: "example.com/mac")]
        next.placeTabs()
        next.current = SyncMapping.current(in: next, old: app.browser.space)
        XCTAssertNil(next.current)
        app.browser.adopt(app.browser.spaces.map { $0.id == next.id ? next : $0 })
        await turn()
        XCTAssertNil(app.browser.tab)
        XCTAssertEqual(stack.contents().front?.id, "mac")
        XCTAssertEqual(stack.previous?.id, "mac")
    }

    func testOnePageInFrontShowsItsCardInTheStack() async throws {
        let app = try mira()
        let stack = TabStack.of(app)
        app.browser.select("work-hn")
        for tab in app.browser.space.today where tab.id != "work-hn" { app.browser.close(tab.id) }
        await turn()
        XCTAssertEqual(stack.contents().count, 1)
        XCTAssertTrue(stack.contents().showsStack)
        XCTAssertEqual(stack.contents().front?.id, "work-hn")
        XCTAssertTrue(stack.contents().loneCard)
        // A pin in front is open too: it stands in the stack.
        app.browser.close("work-hn")
        let pin = try XCTUnwrap(app.browser.space.pins.first?.id)
        app.browser.select(pin)
        await turn()
        XCTAssertTrue(stack.contents().showsStack)
        XCTAssertEqual(stack.contents().front?.id, pin)
    }

    /// #1501: no ordinary tabs exist to mask an empty private selection.
    func testClosingLastPrivateCardReturnsToEmptyOrdinarySpace() async throws {
        let home = Space(id: "home", name: "Personal", emoji: "", tint: RGB(238, 233, 226))
        let app = AppModel(world: World(name: "test", space: home.id, spaces: [home]), privateLockEnabled: { false })
        app.openPrivately(tab("private-1501"))
        let id = try XCTUnwrap(app.browser.tab?.id)
        XCTAssertTrue(app.browser.space.isPrivate)
        let stack = TabStack.of(app)
        stack.openGallery()
        await turn()
        stack.closeCard(id)
        await turn()
        XCTAssertNil(app.browser.tab(id))
        XCTAssertEqual(app.browser.spaceID, home.id)
        XCTAssertFalse(app.hasPrivateForeground)
        XCTAssertTrue(app.browser.space.allTabs.isEmpty)
        XCTAssertFalse(app.field.isPrivate)
        app.field.close()
        await turn()
        app.openNewTab()
        XCTAssertFalse(app.field.isPrivate)
        XCTAssertFalse(app.browser.space.isPrivate)
    }

    func testClosingLastPrivateCardPreservesOrdinarySelection() async throws {
        let app = try mira()
        let space = app.browser.spaceID
        let publicTab = app.browser.tab?.id
        app.openPrivately(tab("private-1501-with-public"))
        let id = try XCTUnwrap(app.browser.tab?.id)
        let stack = TabStack.of(app)
        stack.openGallery()
        await turn()
        stack.closeCard(id)
        await turn()
        XCTAssertEqual(app.browser.spaceID, space)
        XCTAssertEqual(app.browser.tab?.id, publicTab)
        XCTAssertFalse(app.hasPrivateForeground)
    }

    func testAFreshProfileHasNoTabs() {
        let start = BrowserProfile.Snapshot.empty()
        XCTAssertTrue(start.isValid)
        XCTAssertEqual(start.spaces.flatMap(\.allTabs).count, 0)
        XCTAssertNil(start.spaces[0].current)
        let store = BrowserStore(world: World(name: "profile", space: start.spaceID, spaces: start.spaces), fixturesEnabled: false)
        XCTAssertNil(store.tab)
    }

    func testAMappedSpaceNeverBringsAPinForward() {
        let pin = tab("pin", place: .pinned), kept = tab("kept", place: .kept)
        var old = Space(id: "s", name: "S", emoji: "", tint: RGB(1, 1, 1), pins: [pin], kept: [.tab(kept)], today: [tab("a"), tab("b")], current: "a")
        var now = old
        now.today = [tab("b")]
        XCTAssertEqual(SyncMapping.current(in: now, old: old), "b", "a today's neighbor")
        now.today = []
        XCTAssertNil(SyncMapping.current(in: now, old: old), "no pin, no kept")
        old.current = nil
        now.today = [tab("c")]
        XCTAssertNil(SyncMapping.current(in: now, old: old), "the empty page stays")
        XCTAssertEqual(SyncMapping.current(in: now, old: nil), "c", "a space first seen here")
    }

    func testWithNoOtherTabTheStackShowsThatTabAndHasNothingToFlickTo() async throws {
        let app = try mira()
        app.browser.showSpace("lisbon")
        app.browser.close("lisbon-wiki")
        app.browser.close("lisbon-alfama-wiki")
        let stack = TabStack.of(app)
        await turn()
        XCTAssertTrue(stack.contents().showsStack)
        XCTAssertNil(stack.previous)
        XCTAssertFalse(stack.canFlick)
        XCTAssertEqual(stack.contents().count, 1)
    }

    func testPrivateHasAStackOfItsOwnPrivateTabs() async throws {
        let app = try mira()
        let stack = TabStack.of(app)
        for id in ["work-hn", "work-gh-pr"] {
            var copy = try XCTUnwrap(app.browser.tab(id))
            copy.id = "private-" + id
            app.openPrivately(copy)
            await turn()
        }
        XCTAssertTrue(app.browser.space.isPrivate)
        XCTAssertEqual(stack.contents().front?.id, "private-work-hn")
        XCTAssertNil(stack.contents().back)
        XCTAssertTrue(stack.order.allSatisfy(\.isPrivate))
        app.browser.showSpace("work")
        await turn()
        XCTAssertFalse(stack.order.contains { $0.isPrivate })
    }

    // MARK: - the flick

    func testAFlickPastTheCommitBringsThePreviousTabWithOneTickAndAnotherTakesItBack() async throws {
        let app = try mira()
        let stack = TabStack.of(app)
        await select(app, "work-gh-pr", "work-lumen")
        let before = Haptics.played.count
        XCTAssertTrue(stack.flickBegan())
        stack.flickMoved(30)
        stack.flickEnded(30, velocity: 300)
        XCTAssertEqual(app.browser.tab?.id, "work-gh-pr")
        XCTAssertNil(stack.flick)
        XCTAssertEqual(Haptics.played.suffix(from: before).map(\.reason), [Haptics.Reason.flickLetGo], "felt as it is let go")
        XCTAssertEqual(Haptics.played.last?.kind, .light)
        await turn()
        XCTAssertEqual(stack.previous?.id, "work-lumen")
        XCTAssertTrue(stack.flickBegan())
        stack.flickEnded(80, velocity: 0)
        XCTAssertEqual(app.browser.tab?.id, "work-lumen")
    }

    func testAShortSlowFlickGoesBackAndChangesNothing() async throws {
        let app = try mira()
        let stack = TabStack.of(app)
        await turn()
        let before = Haptics.played.count
        XCTAssertTrue(stack.flickBegan())
        stack.flickMoved(15)
        stack.flickEnded(15, velocity: 50)
        XCTAssertEqual(app.browser.tab?.id, "work-figma-onb")
        XCTAssertNil(stack.flick)
        XCTAssertEqual(Haptics.played.count, before)
    }

    func testWhileReleasedTheStackShowsTheTabBeingLeftInFront() async throws {
        let app = try mira()
        let stack = TabStack.of(app)
        await select(app, "work-hn", "work-gh-pr", "work-figma-onb")
        stack.holdFlick(at: 0.5)
        XCTAssertEqual(stack.flick?.target.id, "work-gh-pr")
        XCTAssertEqual(stack.growth, 0.5)
        XCTAssertEqual(stack.contents().front?.id, "work-figma-onb")
        XCTAssertEqual(stack.contents().back?.id, "work-hn")
        XCTAssertEqual(app.browser.tab?.id, "work-figma-onb", "the tab changes once the page has grown")
    }

    func testTheLiftedCardGrowsByAThirdAboutItsMiddle() throws {
        let app = try mira()
        let stack = TabStack.of(app)
        stack.screen = Metrics.screen
        let rest = stack.liftedCard(0), lifted = stack.liftedCard(Metrics.TabStack.liftSpan)
        let button = ChromeGeometry(size: Metrics.screen, folded: false, hasNow: app.nowItem != nil).space
        // The front card in the circle: 22 x 24, its middle 2 right of and 1 over the circle's.
        XCTAssertEqual(rest.midX, button.midX + 2, accuracy: 0.001)
        XCTAssertEqual(rest.midY, button.midY - 1, accuracy: 0.001)
        XCTAssertEqual(rest.size, CGSize(width: 22, height: 24))
        XCTAssertEqual(rest, TabStackGeometry(button: button).front)
        XCTAssertEqual(lifted.width, 22 * 1.35, accuracy: 0.001)
        XCTAssertEqual(lifted.midX, rest.midX, accuracy: 0.001)
        XCTAssertEqual(lifted.midY, rest.midY - 60, accuracy: 0.001)
    }

    // MARK: - All Tabs

    func testGalleryCanSwitchToEmptyAndPopulatedSpacesWithoutClosingTabs() async throws {
        let app = try mira()
        let empty = app.browser.createSpace(name: "Empty", emoji: "", look: SpaceLook(color: RGB(80, 90, 100)))
        app.browser.showSpace("work")
        let before = app.browser.spaces
        let stack = TabStack.of(app)
        stack.openGallery()
        stack.selectGallerySpace("lisbon")
        XCTAssertEqual(stack.gallery?.space, "lisbon")
        XCTAssertEqual(Set(stack.gallery?.order ?? []), ["lisbon-wiki", "lisbon-alfama-wiki", "lisbon-flights"])
        stack.selectGallerySpace(empty)
        XCTAssertEqual(stack.gallery?.space, empty)
        XCTAssertEqual(stack.gallery?.order, [])
        stack.selectGallerySpace("work")
        XCTAssertEqual(stack.gallery?.space, "work")
        XCTAssertEqual(app.browser.spaceID, "work")
        XCTAssertEqual(app.browser.spaces, before)
        stack.selectGallerySpace(NewTabPager.privatePage)
        XCTAssertEqual(app.browser.spaceID, "work")
        stack.chooseFront()
        XCTAssertNil(stack.gallery)
        XCTAssertEqual(app.browser.spaces, before, "Done keeps the selected kept page too")
    }

    func testPhoneGalleryContainsOnlyMobileTodayAndPreservesKeptTabs() async throws {
        let app = try mira()
        let stack = TabStack.of(app)
        await select(app, "work-hn", "work-gh-pr", "work-figma-onb")
        stack.openGallery()
        let gallery = try XCTUnwrap(stack.gallery)
        XCTAssertEqual(gallery.order, ["work-linear-method", "work-lumen", "work-tern-local", "work-hn", "work-gh-pr", "work-figma-onb"],
                       "every recent tab, as the Mac's Control-Tab row")
        XCTAssertNotNil(app.browser.tab("work-figma-onb"))
    }

    func testAllTabsHoldsTheOpenTabsOldestFirstAndATappedCardComesInFront() async throws {
        let app = try mira()
        app.workspace.tabletControls = true // Tablet All Tabs retains opened kept tabs.
        let stack = TabStack.of(app)
        await select(app, "work-hn", "work-gh-pr", "work-figma-onb")
        stack.openGallery()
        let gallery = try XCTUnwrap(stack.gallery)
        XCTAssertEqual(gallery.order, ["work-linear-method", "work-lumen", "work-tern-local", "work-hn", "work-gh-pr", "work-figma-onb"])
        XCTAssertEqual(gallery.phase, .open)
        XCTAssertEqual(gallery.focus, 4, "the previous tab, GitHub, at the focus")
        XCTAssertEqual(app.surfaces.chromeOpacity, 0, "the chrome goes as the cards come")
        XCTAssertEqual(app.surfaces.statusBarLight, TabGalleryGround.isDark(app))
        stack.choose("work-lumen")
        XCTAssertNil(stack.gallery)
        XCTAssertEqual(app.browser.tab?.id, "work-lumen")
        XCTAssertEqual(app.surfaces.chromeOpacity, 1)
        XCTAssertNil(app.surfaces.statusBarLight)
    }

    func testAClosedCardClosesTodaysTabButAKeptOneOnlyLeavesTheOpenTabs() async throws {
        let app = try mira()
        app.workspace.tabletControls = true // Tablet All Tabs retains opened kept tabs.
        let stack = TabStack.of(app)
        await select(app, "work-hn", "work-figma-onb")
        stack.openGallery()
        let before = Haptics.played.count
        stack.closeCard("work-hn")
        XCTAssertNil(app.browser.tab("work-hn"), "today's tab is closed")
        XCTAssertFalse(stack.cards(of: try XCTUnwrap(stack.gallery)).contains { $0.id == "work-hn" })
        XCTAssertEqual(Haptics.played.suffix(from: before).map(\.reason), [Haptics.Reason.cardThrown])
        XCTAssertEqual(Haptics.played.last?.kind, .soft)
        XCTAssertNil(app.surfaces.toast, "a close says nothing")
        // The only kept card there is: the one in front. It lets go of the page.
        stack.closeCard("work-figma-onb")
        XCTAssertNotNil(app.browser.tab("work-figma-onb"), "a kept tab stays kept")
        XCTAssertEqual(app.browser.tab("work-figma-onb")?.place, .kept)
        XCTAssertFalse(stack.recency.recent(in: "work").contains("work-figma-onb"))
        XCTAssertFalse(stack.order.contains { $0.id == "work-figma-onb" })
        XCTAssertFalse(stack.cards(of: try XCTUnwrap(stack.gallery)).contains { $0.id == "work-figma-onb" })
        XCTAssertEqual(app.browser.tab?.place, .today)
    }

    func testUndoBringsAClosedCardBackInItsPlace() async throws {
        let app = try mira()
        app.workspace.tabletControls = true // Tablet All Tabs retains opened kept tabs.
        let stack = TabStack.of(app)
        await select(app, "work-hn", "work-gh-pr", "work-figma-onb")
        stack.openGallery()
        let before = stack.cards(of: try XCTUnwrap(stack.gallery)).map(\.id)
        stack.closeCard("work-gh-pr")
        XCTAssertNil(app.browser.tab("work-gh-pr"))
        let closed = try XCTUnwrap(app.backStack.closed)
        XCTAssertTrue(app.backStack.undo(closed.id))
        XCTAssertNotNil(app.browser.tab("work-gh-pr"), "Undo brings the tab back")
        XCTAssertEqual(stack.cards(of: try XCTUnwrap(stack.gallery)).map(\.id), before, "and its card where it was")
    }

    func testClosingTheCardInFrontBringsTheNewestLeftAndTheLastLeavesTheEmptyPage() async throws {
        let app = try mira()
        app.workspace.tabletControls = true // Tablet All Tabs retains opened kept tabs.
        app.browser.showSpace("lisbon")
        app.browser.close("lisbon-alfama-wiki")
        let stack = TabStack.of(app)
        await select(app, "lisbon-wiki", "lisbon-flights")
        stack.openGallery()
        XCTAssertEqual(stack.gallery?.order, ["lisbon-wiki", "lisbon-flights"])
        stack.closeCard("lisbon-flights")
        XCTAssertEqual(app.browser.tab?.id, "lisbon-wiki", "the newest card left comes in front")
        XCTAssertEqual(app.browser.tab("lisbon-flights")?.place, .kept)
        stack.closeCard("lisbon-wiki")
        XCTAssertNil(stack.gallery)
        XCTAssertNil(app.browser.tab("lisbon-wiki"))
        XCTAssertNil(app.browser.tab, "with nothing left, the empty page: no pin in front")
        XCTAssertEqual(app.surfaces.field, .newTab, "and search comes up at once")
        XCTAssertNil(app.surfaces.toast, "the close says nothing")
        XCTAssertNotNil(app.backStack.closed, "the sheet offers it back")
    }

    func testAScrollStaysBetweenTheFirstAndTheLastCardAndAnotherSurfaceTakesTheGalleryAway() async throws {
        let app = try mira()
        app.workspace.tabletControls = true // Tablet All Tabs retains opened kept tabs.
        let stack = TabStack.of(app)
        await turn()
        stack.openGallery()
        let count = try XCTUnwrap(stack.gallery).order.count
        stack.settleScroll(10_000)
        XCTAssertEqual(try XCTUnwrap(stack.gallery?.focus), CGFloat(count - 1), accuracy: 0.0001)
        stack.settleScroll(-300)
        XCTAssertEqual(stack.gallery?.focus, 0)
        stack.settleScroll(2.4)
        XCTAssertEqual(stack.gallery?.focus, 2, "a throw comes to rest on a card")
        // Settings from All Tabs' gear stands over it and closes back to it.
        stack.gallerySettings()
        XCTAssertTrue(app.surfaces.settings)
        await turn()
        XCTAssertNotNil(stack.gallery, "Settings stands over All Tabs")
        app.surfaces.closeSettings()
        await turn()
        XCTAssertEqual(stack.gallery?.focus, 2, "and closes back to it as it was")
        // Another surface takes it away: a chat over it.
        app.surfaces.openChat(.newChat)
        let gone = await until { stack.gallery == nil }
        XCTAssertTrue(gone)
        XCTAssertEqual(app.surfaces.chromeOpacity, 1)
    }

    // MARK: - The gallery's measured look (Metrics.TabGallery, TabGalleryTiming)

    /// On a 375 x 812 screen the layout puts the cards at the reference
    /// positions: left edges 291.8 (in front), 80.5 (the focus), 11.3 and -9.5,
    /// their middles at 418, the focus card rounded 24.5.
    func testOnTheReferenceScreenTheCardsStandAtTheirPositions() {
        let layout = TabGalleryLayout(screen: CGSize(width: 375, height: 812), count: 4)
        XCTAssertEqual(layout.initialFocus, 2)
        let current = layout.card(3, focus: 2), focus = layout.card(2, focus: 2)
        let one = layout.card(1, focus: 2), two = layout.card(0, focus: 2)
        XCTAssertEqual(current.minX, 291.8, accuracy: 0.1)
        XCTAssertEqual(focus.minX, 80.5, accuracy: 0.1)
        XCTAssertEqual(one.minX, 11.3, accuracy: 0.1)
        XCTAssertEqual(two.minX, -9.5, accuracy: 0.1)
        for card in [current, focus, one, two] { XCTAssertEqual(card.midY, 418, accuracy: 0.1) }
        // Our content area there is 682 high (the reference is 688): heights within 6.
        XCTAssertEqual(focus.height, 530.7, accuracy: 6)
        XCTAssertEqual(current.height, 536.6, accuracy: 6)
        XCTAssertEqual(focus.minY, 152.3, accuracy: 3)
        XCTAssertEqual(layout.radius(of: focus), 24.5, accuracy: 0.4)
        // Each card is its page's own shape (262 x 531 there).
        XCTAssertEqual(focus.width / focus.height, 375 / (812 - Metrics.statusBar), accuracy: 0.002)
        XCTAssertEqual(focus.width, 262, accuracy: 4)
        // The newest card at the focus stands in the middle (85 of 375 each side).
        let newest = layout.card(3, focus: 3)
        XCTAssertEqual(newest.midX, 187.5, accuracy: 0.5)
        XCTAssertEqual(newest.minX, 56.5, accuracy: 4)
        // The focus card's title runs to 16 short of the next card's icon (ends at 294).
        XCTAssertEqual(focus.minX + 18 + 20 + 6.5 + layout.titleWidth(2, focus: 2), 294, accuracy: 1)
    }

    /// The focus is the previous tab; the tab in front stands to its right
    /// and over it; older ones pile up to the left under it, closer and
    /// smaller the further back, under a veil, their icons fading.
    func testTheFocusIsThePreviousTabTheOneInFrontIsRightAndOverOlderOnesCompressedAndVeiled() {
        let layout = TabGalleryLayout(screen: Metrics.screen, count: 5)
        let poses = (0..<5).map { TabGalleryMotion.rest($0, layout: layout, focus: layout.initialFocus) }
        XCTAssertEqual(layout.initialFocus, 3)
        let current = poses[4], focus = poses[3], one = poses[2], two = poses[1], three = poses[0]
        XCTAssertGreaterThan(current.rect.minX, focus.rect.minX)
        XCTAssertGreaterThan(current.z, focus.z, "the tab in front is over the focus card")
        XCTAssertGreaterThan(current.rect.maxX, Metrics.screen.width, "mostly past the screen's edge")
        XCTAssertLessThan(current.rect.minX, focus.rect.maxX, "and over its right part")
        // Older: each shows less than the one before it, and is smaller.
        let shows = [focus.rect.minX - one.rect.minX, one.rect.minX - two.rect.minX, two.rect.minX - three.rect.minX]
        XCTAssertEqual(shows[0], 74.2, accuracy: 0.5, "the reference is 69 of 375")
        XCTAssertEqual(shows[1], 22.3, accuracy: 0.5)
        XCTAssertEqual(shows[2], 12.9, accuracy: 0.5)
        XCTAssertGreaterThan(focus.rect.height, one.rect.height)
        XCTAssertGreaterThan(one.rect.height, two.rect.height)
        XCTAssertGreaterThan(focus.z, one.z)
        for (pose, veil) in zip([current, focus, one, two, three], [0, 0, 0.2, 0.35, 0.35]) { XCTAssertEqual(pose.veil, veil, accuracy: 0.0001) }
        for (pose, title) in zip([current, focus, one], [0.0, 1, 0]) { XCTAssertEqual(pose.title, title, accuracy: 0.0001, "the focus card's title only") }
        for (pose, icon) in zip([focus, one, two, three], [1, 1, 0.4, 0]) { XCTAssertEqual(pose.icon, icon, accuracy: 0.0001) }
        XCTAssertEqual(focus.cropTop, Metrics.statusBar / Metrics.screen.height, accuracy: 0.0001, "the content area, under the status bar")
        // A finger's step brings the next card to the focus.
        XCTAssertEqual(layout.rect(depth: -1).minX - layout.rect(depth: 0).minX, layout.step, accuracy: 0.001)
        XCTAssertEqual(layout.card(at: CGPoint(x: current.rect.minX + 5, y: 400), focus: 3), 4, "the newer card where two overlap")
        XCTAssertEqual(layout.card(at: CGPoint(x: one.rect.minX + 5, y: 400), focus: 3), 2)
        // Let go: a short throw or a third of the way pages on;
        // the tab in front on the right comes to the focus with a short swipe.
        XCTAssertEqual(TabGalleryLayout.settle(from: 3, moved: 3.2, thrown: 3.4), 4, "a short throw left brings the card on the right")
        XCTAssertEqual(TabGalleryLayout.settle(from: 3, moved: 3.35, thrown: 3.36), 4, "a third of the way pages on")
        XCTAssertEqual(TabGalleryLayout.settle(from: 3, moved: 2.8, thrown: 2.6), 2, "and the other way")
        XCTAssertEqual(TabGalleryLayout.settle(from: 3, moved: 3.1, thrown: 3.12), 3, "a slight move goes back")
        XCTAssertEqual(TabGalleryLayout.settle(from: 3, moved: 3.3, thrown: 5.4), 5, "a long throw goes further")
        XCTAssertLessThan(layout.resisted(6), 6)
        XCTAssertGreaterThan(layout.resisted(-1), -1)
        XCTAssertEqual(layout.plus, CGRect(x: 153, y: 798, width: 96, height: 48))
    }

    /// Opening: the page in front starts as the whole page and shrinks into
    /// its card; the previous tab's card grows out of the circle's front
    /// card, its rect, its 8° turn and its rim; the one before it out of the
    /// back card; the older ones come in from nothing; at the end all stand
    /// at rest, no rim left.
    func testOpeningGrowsTheCardsOutOfTheStacksCardsAndEndsAtRest() {
        let layout = TabGalleryLayout(screen: Metrics.screen, count: 5)
        let stack = TabStackGeometry(screen: Metrics.screen)
        let start = (0..<5).map { TabGalleryMotion.opening($0, layout: layout, stack: stack, t: 0) }
        XCTAssertEqual(start[4].rect, layout.page)
        XCTAssertEqual(start[4].cropTop, 0)
        XCTAssertEqual(start[4].radius, 0)
        XCTAssertEqual(start[3].rect, stack.front)
        XCTAssertEqual(start[3].angle, 8)
        XCTAssertEqual(start[3].radius, 4)
        XCTAssertEqual(start[3].rim, 1, "it leaves the circle wearing its rim")
        XCTAssertEqual(start[4].rim, 0, "the page has none")
        XCTAssertEqual(start[2].rect, stack.back)
        XCTAssertEqual(start[2].angle, -12)
        XCTAssertEqual(start[2].opacity, 0.87, accuracy: 0.001)
        XCTAssertEqual(start[1].opacity, 0)
        XCTAssertEqual(start[3].icon, 0, "labels come in with their cards")
        // The stack sits below the content. The whole-page card includes
        // the floating chrome's room, so it covers the stack at the start.
        XCTAssertFalse(layout.content.intersects(stack.front))
        XCTAssertFalse(layout.content.intersects(stack.back))
        let end = (0..<5).map { TabGalleryMotion.opening($0, layout: layout, stack: stack, t: TabGalleryTiming.openDuration) }
        for i in 0..<5 {
            let rest = TabGalleryMotion.rest(i, layout: layout, focus: layout.initialFocus)
            XCTAssertEqual(end[i].rect.minX, rest.rect.minX, accuracy: 0.5, "card \(i)")
            XCTAssertEqual(end[i].rect.minY, rest.rect.minY, accuracy: 0.5, "card \(i)")
            XCTAssertEqual(end[i].rect.width, rest.rect.width, accuracy: 0.5, "card \(i)")
            XCTAssertEqual(end[i].angle, 0, accuracy: 0.01)
            XCTAssertEqual(end[i].rim, 0, accuracy: 0.001)
            XCTAssertEqual(end[i].opacity, 1, accuracy: 0.001)
            XCTAssertEqual(end[i].icon, rest.icon, accuracy: 0.001)
        }
        // Order of things: the page leaves at once, the stack's card 0.02 s
        // later and slower, straightening before it has half grown.
        let early = TabGalleryMotion.opening(3, layout: layout, stack: stack, t: 0.02)
        XCTAssertEqual(early.rect, stack.front)
        XCTAssertLessThan(early.angle, 8)
        let mid = TabGalleryMotion.opening(3, layout: layout, stack: stack, t: 0.1)
        XCTAssertLessThan(mid.angle, 2.5)
        XCTAssertLessThan(mid.rect.height, (stack.front.height + layout.card(3, focus: 3).height) * 0.6)
    }

    /// The circle: the chrome's right button, 48 round; both cards, turned,
    /// lie inside it, the front one up and right of the back one.
    func testTheStacksTwoCardsSitInsideTheGlassCircle() {
        let stack = TabStackGeometry(screen: Metrics.screen)
        XCTAssertEqual(stack.circle, ChromeGeometry(size: Metrics.screen, folded: false, hasNow: false).space)
        XCTAssertEqual(stack.circle.size, CGSize(width: 48, height: 48))
        // The prototype's on the 17 Pro: the circle at 328, 798; the cards' middles 354, 821 and 348, 824.
        XCTAssertEqual(stack.circle.origin, CGPoint(x: 328, y: 798))
        XCTAssertEqual(CGPoint(x: stack.front.midX, y: stack.front.midY), CGPoint(x: 354, y: 821))
        XCTAssertEqual(CGPoint(x: stack.back.midX, y: stack.back.midY), CGPoint(x: 348, y: 824))
        XCTAssertEqual(stack.front.size, CGSize(width: 22, height: 24))
        XCTAssertEqual(stack.back.size, CGSize(width: 22, height: 24))
        let middle = CGPoint(x: stack.circle.midX, y: stack.circle.midY)
        for (card, turn) in [(stack.front, Metrics.TabStack.frontTurn), (stack.back, Metrics.TabStack.backTurn)] {
            for corner in TabStackGeometry.corners(of: card, turned: turn) {
                XCTAssertLessThan(hypot(corner.x - middle.x, corner.y - middle.y), 24, "a corner of \(card) out of the circle")
            }
        }
        XCTAssertGreaterThan(stack.front.midX, stack.back.midX)
        XCTAssertLessThan(stack.front.midY, stack.back.midY)
        XCTAssertEqual(Metrics.TabStack.frontTurn, 8)
        XCTAssertEqual(Metrics.TabStack.backTurn, -12)
    }

    /// The rule: only the cards lying on the chosen one (newer, to its
    /// right) fly into the circle, the two nearest the top; the stack's card
    /// that lay under it appears in its place; the top card has nothing on
    /// it, so the circle rises with its cards. The stack shows afterwards
    /// what TabRecency says: the two newest but the chosen one.
    func testOnlyTheCardsOnTheChosenOneFlyIntoTheCircle() {
        typealias Role = TabGalleryMotion.Role
        typealias Closing = TabGalleryMotion.Closing
        // The top card (Figma in front): nothing flies; GitHub and HN come up with the circle.
        let top = Closing(count: 6, chosen: 5)
        XCTAssertEqual(top.roles, [Role.other, .other, .other, .other, .other, .chosen])
        XCTAssertEqual(top.front, 4)
        XCTAssertEqual(top.back, 3)
        XCTAssertTrue(top.rises)
        XCTAssertEqual(top.seated, [TabGalleryMotion.Seat(index: 4, place: .front), TabGalleryMotion.Seat(index: 3, place: .back)])
        // The second (GitHub, the focus): Figma on it flies into the front
        // card; HN, under it, appears in the back card.
        let second = Closing(count: 6, chosen: 4)
        XCTAssertEqual(second.roles, [Role.other, .other, .other, .other, .chosen, .front])
        XCTAssertEqual(second.front, 5)
        XCTAssertEqual(second.back, 3)
        XCTAssertFalse(second.rises)
        XCTAssertEqual(second.seated, [TabGalleryMotion.Seat(index: 3, place: .back)])
        // The third (HN): Figma and GitHub fly in, Figma in front.
        let third = Closing(count: 6, chosen: 3)
        XCTAssertEqual(third.roles, [Role.other, .other, .other, .chosen, .back, .front])
        XCTAssertEqual(third.seated, [])
        XCTAssertFalse(third.rises)
        // Further down: the two nearest the top fly; the one between stays and fades.
        let fifth = Closing(count: 6, chosen: 1)
        XCTAssertEqual(fifth.roles, [Role.other, .chosen, .other, .other, .back, .front])
        XCTAssertEqual(fifth.seated, [])
        // Two cards: the other one flies or rises alone; one card: + rises.
        XCTAssertEqual(Closing(count: 2, chosen: 0).roles, [Role.chosen, .front])
        XCTAssertEqual(Closing(count: 2, chosen: 1).seated, [TabGalleryMotion.Seat(index: 0, place: .front)])
        let alone = Closing(count: 1, chosen: 0)
        XCTAssertNil(alone.front)
        XCTAssertTrue(alone.rises)
        XCTAssertEqual(alone.seated, [])
        // The iPad has no circle: nothing flies, sits or rises; the others fade in place.
        for chosen in 0..<6 {
            let flat = Closing(count: 6, chosen: chosen, stack: false)
            XCTAssertEqual(flat.roles, (0..<6).map { $0 == chosen ? Role.chosen : .other })
            XCTAssertEqual(flat.seated, [])
            XCTAssertFalse(flat.rises)
        }
        // The stack's cards are what TabRecency shows after the chosen tab comes first.
        for count in 1...6 {
            for chosen in 0..<count {
                let plan = Closing(count: count, chosen: chosen)
                let recent = [chosen] + (0..<count).reversed().filter { $0 != chosen }
                XCTAssertEqual(plan.front, recent.dropFirst().first, "front, \(chosen) of \(count)")
                XCTAssertEqual(plan.back, recent.dropFirst(2).first, "back, \(chosen) of \(count)")
                for (i, role) in plan.roles.enumerated() where role == .front || role == .back {
                    XCTAssertGreaterThan(i, chosen, "only cards on the chosen one fly")
                }
            }
        }
    }

    /// Where everything is as the rule plays: the flying cards end in the
    /// circle's cards, rect, turn and rim, quicker than the page grows; the
    /// others stay where they were and are gone in 0.1 s, those under the
    /// chosen card under it; the stack card that lay under it fades in in
    /// its place as the others land; with the top card the circle and its
    /// two cards come up 104 on the cards' spring.
    func testClosingFliesFadesAppearsAndRises() {
        let layout = TabGalleryLayout(screen: Metrics.screen, count: 6)
        let stack = TabStackGeometry(screen: Metrics.screen)
        let from = (0..<6).map { TabGalleryMotion.rest($0, layout: layout, focus: layout.initialFocus) }
        let end = TabGalleryTiming.closeDuration
        // The third: Figma and GitHub fly into the front and back cards.
        let third = TabGalleryMotion.Closing(count: 6, chosen: 3)
        let landed = (0..<6).map { TabGalleryMotion.closing(third.roles[$0], from: from[$0], layout: layout, stack: stack, t: end) }
        XCTAssertEqual(landed[3].rect.minY, 0, accuracy: 0.5)
        XCTAssertEqual(landed[3].rect.height, layout.page.height, accuracy: 0.5)
        XCTAssertEqual(landed[3].cropTop, 0, accuracy: 0.0001)
        for (i, card, turn) in [(5, stack.front, Metrics.TabStack.frontTurn), (4, stack.back, Metrics.TabStack.backTurn)] {
            XCTAssertEqual(landed[i].rect.midX, card.midX, accuracy: 0.1)
            XCTAssertEqual(landed[i].rect.midY, card.midY, accuracy: 0.1)
            XCTAssertEqual(landed[i].rect.width, card.width, accuracy: 0.1)
            XCTAssertEqual(landed[i].angle, turn, accuracy: 0.01)
            XCTAssertEqual(landed[i].rim, 1, accuracy: 0.001)
            XCTAssertGreaterThan(landed[i].z, landed[3].z, "drawn over the growing page")
        }
        XCTAssertEqual(landed[4].opacity, 0.87, accuracy: 0.001)
        XCTAssertEqual(landed[4].veil, 0.08, accuracy: 0.001)
        // The cards under HN stay where they were, under it, and are gone in 0.1 s.
        for i in 0..<3 {
            let going = TabGalleryMotion.closing(third.roles[i], from: from[i], layout: layout, stack: stack, t: 0.05)
            XCTAssertEqual(going.rect, from[i].rect, "card \(i) stays where it is")
            XCTAssertEqual(going.opacity, 0.5, accuracy: 0.001)
            XCTAssertLessThan(going.z, landed[3].z, "under the growing page")
            XCTAssertEqual(TabGalleryMotion.closing(third.roles[i], from: from[i], layout: layout, stack: stack, t: TabGalleryTiming.othersFade).opacity, 0)
        }
        // The flying cards are quicker than the one growing.
        let t = 0.1
        let shrinking = TabGalleryMotion.closing(.front, from: from[5], layout: layout, stack: stack, t: t)
        let growing = TabGalleryMotion.closing(.chosen, from: from[3], layout: layout, stack: stack, t: t)
        let shrunk = (from[5].rect.height - shrinking.rect.height) / (from[5].rect.height - stack.front.height)
        let grown = (growing.rect.height - from[3].rect.height) / (layout.page.height - from[3].rect.height)
        XCTAssertGreaterThan(shrunk, grown)
        // The second: HN appears in the back card as Figma lands in the front one.
        XCTAssertEqual(TabGalleryMotion.rise(false, t: 0), 0)
        let appearing = (0...4).map { TabGalleryMotion.seated(.back, rises: false, layout: layout, stack: stack, t: Double($0) * 0.05) }
        XCTAssertEqual(appearing[0].opacity, 0)
        XCTAssertEqual(appearing[0].rect, stack.back, "in its place, not flying")
        XCTAssertEqual(appearing[0].angle, Metrics.TabStack.backTurn)
        XCTAssertEqual(appearing[0].rim, 1)
        for (a, b) in zip(appearing, appearing.dropFirst()) { XCTAssertLessThanOrEqual(a.opacity, b.opacity) }
        XCTAssertEqual(TabGalleryMotion.seated(.back, rises: false, layout: layout, stack: stack, t: end).opacity, 0.87, accuracy: 0.001)
        let second = TabGalleryMotion.Closing(count: 6, chosen: 4)
        let hn = TabGalleryMotion.closing(second.roles[3], from: from[3], layout: layout, stack: stack, t: 0.05)
        XCTAssertEqual(hn.rect, from[3].rect, "its card in All Tabs fades where it is")
        // The top: the circle comes up from 104 below on the cards' spring, its cards whole.
        XCTAssertEqual(TabGalleryMotion.rise(true, t: 0), 104)
        XCTAssertEqual(TabGalleryMotion.rise(true, t: 0.12), 104 * (1 - TabGalleryTiming.cardToStack.value(0.12)), accuracy: 0.001)
        XCTAssertLessThan(TabGalleryMotion.rise(true, t: 0.12), 104 * 0.11, "90 % of the way by 0.12 s")
        XCTAssertEqual(TabGalleryMotion.rise(true, t: end), 0, accuracy: 0.01)
        let rising = TabGalleryMotion.seated(.front, rises: true, layout: layout, stack: stack, t: 0)
        XCTAssertEqual(rising.rect, stack.front.offsetBy(dx: 0, dy: 104))
        XCTAssertEqual(rising.opacity, 1)
        XCTAssertGreaterThan(rising.rect.minY, Metrics.screen.height, "it starts out of sight")
        XCTAssertEqual(TabGalleryMotion.seated(.back, rises: true, layout: layout, stack: stack, t: 0).opacity, 0.87, accuracy: 0.001)
        XCTAssertGreaterThan(rising.z, TabGalleryMotion.seated(.back, rises: true, layout: layout, stack: stack, t: 0).z)
    }

    /// The springs against the recording's own frames (progress 0 to 1 at
    /// the frame's time after the tap): the page's left edge going to its
    /// card, the previous tab's card leaving the stack, the card tapped
    /// growing, a card going back into the stack.
    func testTheSpringsFollowArcsFrames() {
        typealias T = TabGalleryTiming
        let pageToCard: [(Double, CGFloat)] = [(0.033, 0.195), (0.05, 0.362), (0.067, 0.524), (0.083, 0.661), (0.1, 0.766),
                                               (0.117, 0.846), (0.133, 0.896), (0.15, 0.934), (0.183, 0.974), (0.25, 0.998)]
        for (t, arc) in pageToCard { XCTAssertEqual(T.pageToCard.value(t - 0.004), arc, accuracy: 0.02, "page into its card at \(t)") }
        let stackToCard: [(Double, CGFloat)] = [(0.05, 0.108), (0.067, 0.243), (0.083, 0.38), (0.1, 0.511), (0.133, 0.711),
                                                (0.167, 0.85), (0.2, 0.919), (0.25, 0.974), (0.3, 0.991)]
        for (t, arc) in stackToCard {
            XCTAssertEqual(T.stackToCard.value(t - 0.004 - T.frontDelay), arc, accuracy: 0.025, "card out of the stack at \(t)")
        }
        let cardToPage: [(Double, CGFloat)] = [(0.033, 0.142), (0.05, 0.278), (0.067, 0.41), (0.083, 0.534), (0.1, 0.638),
                                               (0.133, 0.794), (0.167, 0.887), (0.2, 0.938), (0.25, 0.977)]
        for (t, arc) in cardToPage { XCTAssertEqual(T.cardToPage.value(t), arc, accuracy: 0.02, "card into its page at \(t)") }
        let cardToStack: [(Double, CGFloat)] = [(0.084, 0.753), (0.1, 0.851), (0.117, 0.906), (0.133, 0.947), (0.15, 0.976), (0.183, 0.997)]
        for (t, arc) in cardToStack { XCTAssertEqual(T.cardToStack.value(t), arc, accuracy: 0.02, "card into the stack at \(t)") }
        XCTAssertEqual(T.barProgress(0.1), 0.72, accuracy: 0.06, "the bar's buttons, 0.68 at 0.1 s in the reference")
        XCTAssertEqual(T.barProgress(0.19), 1)
    }

    /// Named states hold a moment of the movement.
    func testHeldMomentsOfOpeningAndClosing() async throws {
        let app = try mira()
        app.workspace.tabletControls = true // The phone's gallery leaves the kept Figma out.
        let stack = TabStack.of(app)
        await select(app, "work-hn", "work-gh-pr", "work-figma-onb")
        stack.openGallery()
        stack.holdOpening(at: 0.1)
        XCTAssertEqual(stack.gallery?.phase, .opening)
        XCTAssertEqual(stack.gallery?.time, 0.1)
        XCTAssertEqual(app.surfaces.chromeOpacity, Double(1 - TabGalleryTiming.barProgress(0.1)), accuracy: 0.0001)
        stack.choose("work-figma-onb", heldAt: 0.1)
        XCTAssertEqual(stack.gallery?.phase, .closing)
        // The top card: nothing flies. The iPad has no circle on its page, so
        // GitHub and HN fade where they are rather than coming up with one.
        XCTAssertEqual(stack.gallery?.roles["work-gh-pr"], .other)
        XCTAssertEqual(stack.gallery?.roles["work-hn"], .other)
        XCTAssertEqual(stack.gallery?.seated, [])
        XCTAssertEqual(stack.gallery?.rises, false)
        let gallery = try XCTUnwrap(stack.gallery)
        XCTAssertEqual(stack.circleOffset(gallery), 0, accuracy: 0.001)
        XCTAssertEqual(stack.seatedCards(gallery, layout: stack.layout(gallery)).map(\.tab.id), [])
        XCTAssertEqual(stack.contents().front?.id, "work-gh-pr", "what the stack shows once All Tabs is gone")
        XCTAssertEqual(stack.contents().back?.id, "work-hn")
        stack.dismissGallery()
        XCTAssertNil(stack.gallery)
        XCTAssertEqual(app.surfaces.chromeOpacity, 1)
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
