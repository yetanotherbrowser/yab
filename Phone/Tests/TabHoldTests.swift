import UIKit
import XCTest
@testable import YabPhone

/// A hold on one of this device's tabs, a row or a pin, offers Duplicate
/// Tab as a Mac tab's row does, and it opens the same page in a new tab.
@MainActor
final class TabHoldTests: XCTestCase {
    private var app: AppModel!
    private var oldMotion = false

    override func setUpWithError() throws {
        oldMotion = Motion.disabled
        Motion.disabled = true
        app = AppModel(world: try World.load(named: "mira"), fixturesEnabled: false, privateLockEnabled: { false })
    }

    override func tearDown() {
        app = nil
        Motion.disabled = oldMotion
    }

    private func titles(_ menu: UIMenu) -> [String] {
        menu.children.flatMap { element -> [String] in
            if let menu = element as? UIMenu, menu.options.contains(.displayInline) { return titles(menu) }
            return [element.title]
        }
    }

    func testHoldingATabOffersDuplicateTabAndOpensACopy() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/held"))
        let held = Tab(id: "held", title: "Held", site: "Held", icon: "globe", url: url.absoluteString)
        app.browser.open(held, deduplicate: false)
        let front = Tab(id: "front", title: "Front", site: "Front", icon: "globe", url: "https://example.com/front")
        app.browser.open(front, deduplicate: false)

        XCTAssertTrue(titles(PinHold.menu(held, app: app, page: app.browser.spaceID)).contains("Duplicate Tab"), "a pin's hold")
        let items = TabHold.pageItems(held, app: app, page: nil)
        let duplicate = try XCTUnwrap(items.first { $0.title == "Duplicate Tab" }, "a row's hold")
        let before = app.browser.space.allTabs.count
        duplicate.run()
        XCTAssertEqual(app.browser.space.allTabs.count, before + 1)
        XCTAssertEqual(app.browser.tab?.navigationURL, url, "the copy comes in front")
        XCTAssertFalse([held.id, front.id].contains(app.browser.tab?.id ?? ""), "a new tab, not the held one")
        XCTAssertNotNil(app.browser.tab(held.id), "the held tab stays")

        let mail = Tab(id: "mail", title: "Mail", site: "Mail", icon: "mail", url: "https://mail.example.com/")
        app.browser.open(mail, deduplicate: false)
        XCTAssertFalse(TabHold.pageItems(mail, app: app, page: nil).contains { $0.title == "Duplicate Tab" }, "Mail has no page to copy")
    }

    /// With the field closed (the iPad's sidebar, or the field still on its
    /// way back to the plate), Duplicate Tab leaves the words kept for New
    /// Tab. Held in the open field, the field makes way for the copy.
    func testDuplicateTabClearsTheFieldOnlyWhenItIsOpen() throws {
        let held = Tab(id: "held", title: "Held", site: "Held", icon: "globe", url: "https://example.com/held")
        app.browser.open(held, deduplicate: false)
        app.surfaces.openField(.newTab)
        app.field.typed("half a thought")
        app.surfaces.closeField()

        let duplicate = try XCTUnwrap(TabHold.pageItems(held, app: app, page: nil).first { $0.title == "Duplicate Tab" })
        duplicate.run()
        XCTAssertEqual(app.field.newTabWords, "half a thought", "a hold with the field closed keeps its words")

        app.surfaces.openField(.newTab)
        XCTAssertEqual(app.field.text, "half a thought")
        duplicate.run()
        XCTAssertNil(app.surfaces.field, "the open field makes way for the copy")
        XCTAssertEqual(app.field.newTabWords, "", "and forgets what it held")
    }
}
