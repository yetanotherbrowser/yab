import AppKit
import SwiftUI
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct SplitMenuTests {
    private func world(pinned: Bool = false, _ body: (Browser, Fast.Tab, Fast.Tab) throws -> Void) rethrows {
        let id = UUID(), browser = Browser(windowID: id)
        defer {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs + browser.parkedTabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
        let left = Fast.Tab(), right = Fast.Tab()
        for tab in [left, right] { browser.prepare(tab) }
        left.restore(url: URL(string: "https://left.test/page")!, title: "Left")
        right.restore(url: URL(string: "https://right.test/page")!, title: "Right")
        if pinned { left.pin = "L"; right.pin = "R" }
        browser.lay([left, right])
        browser.activeID = left.id
        browser.splitBook.place = CGRect(x: 0, y: 0, width: 1400, height: 900)
        browser.pairs = [Pair(first: left.id, second: right.id, share: 0.6)]
        try body(browser, left, right)
    }

    private func menu(_ browser: Browser, _ tab: Fast.Tab) -> NSMenu {
        let menu = NSHostingMenu(rootView: TabMenu(browser: browser, tab: tab, close: { browser.shut(tab) }))
        menu.update()
        ActionMenu.prepare(menu)
        return menu
    }

    private func item(_ menu: NSMenu, _ path: [String]) throws -> NSMenuItem {
        menu.update()
        let first = try #require(path.first)
        let item = try #require(menu.items.first { $0.title == first })
        if path.count == 1 { return item }
        let submenu = try #require(item.submenu)
        return try self.item(submenu, Array(path.dropFirst()))
    }

    private func pick(_ menu: NSMenu, _ path: [String]) throws {
        let item = try item(menu, path)
        #expect(item.isEnabled)
        let parent = try #require(item.menu)
        parent.performActionForItem(at: parent.index(of: item))
    }

    @Test(arguments: [false, true], [false, true])
    func eitherChipOpensTheWholeSplitMenu(pinned: Bool, rightClicked: Bool) throws {
        try world(pinned: pinned) { browser, left, right in
            let root = menu(browser, rightClicked ? right : left)
            let list = ActionMenuList(menu: root, falls: true)
            #expect(list.compact && list.searchVisible)
            let pinTitle = pinned ? "Unpin Pair" : "Pin Pair"
            #expect(list.lines.map(\.title) == [pinTitle, "Separate All Tabs", "Arrange", "Tab Options", "Left", "Right", "Duplicate", "Move to", "Archive Item", "Archive Tabs Below"])
            #expect(try item(root, [pinTitle]).image === MenuMark.image(pinned ? "pin.slash" : "pin"))
            #expect(list.lines.first { $0.title == "Tab Options" }?.enabled == false)
            #expect(list.lines.first { $0.title == "Left" }?.image != nil)
            #expect(list.lines.first { $0.title == "Right" }?.image != nil)
            for (title, mark) in [("Separate All Tabs", "yab.split.slash"), ("Duplicate", "yab.tabs.plus"),
                                  ("Move to", "arrow.right"), ("Archive Item", "yab.tabs.x"),
                                  ("Archive Tabs Below", "yab.tabs.down")] {
                #expect(try item(root, [title]).image === MenuMark.image(mark))
            }
            for title in ["Left", "Right"] {
                let child = try #require(try item(root, [title]).submenu)
                let lines = ActionMenuList(menu: child, falls: true)
                #expect(lines.lines.map(\.title) == ["Separate from Split View", "Mute", "Copy Link", "Copy link as Markdown", "Change Icon…", "Rename…", "Archive Item"])
                #expect(!lines.lines.contains { $0.title.contains("Share") || $0.title == "Pin" })
                for (action, mark) in [("Separate from Split View", "yab.split.slash"), ("Mute", "speaker.slash"),
                                       ("Copy Link", "link"), ("Copy link as Markdown", "markdown"),
                                       ("Change Icon…", "face.smiling"), ("Rename…", "pencil"), ("Archive Item", "yab.tab.x")] {
                    #expect(try item(child, [action]).image === MenuMark.image(mark))
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func moveToPinsThePairFromEitherChip(rightClicked: Bool) throws {
        try world { browser, left, right in
            let pair = try #require(browser.pairs.first)
            try pick(menu(browser, rightClicked ? right : left), ["Move to", "Pinned Tabs"])
            #expect(browser.pinPair(of: left.id) == pair)
            #expect(browser.gridPins.map(\.id) == [left.id])
            #expect(left.pin != nil && right.pin != nil)
            #expect(browser.tabs.count == 2)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func firstActionTogglesTheWholePair(pinned: Bool, rightClicked: Bool) throws {
        try world(pinned: pinned) { browser, left, right in
            let pair = try #require(browser.pairs.first)
            try pick(menu(browser, rightClicked ? right : left), [pinned ? "Unpin Pair" : "Pin Pair"])
            #expect((left.pin != nil) == !pinned)
            #expect((right.pin != nil) == !pinned)
            #expect(browser.pair(of: left.id) == pair)
            #expect(browser.gridPins.map(\.id) == (pinned ? [] : [left.id]))
            #expect(browser.tabs.count == 2)
        }
    }

    @Test(arguments: [false, true])
    func searchingPinAlsoPinsTheWholePair(rightClicked: Bool) throws {
        try world { browser, left, right in
            let list = ActionMenuList(menu: menu(browser, rightClicked ? right : left), falls: true)
            list.query = "Pin"
            #expect(list.searchVisible)
            let line = try #require(list.lines.first { $0.title == "Pin Pair" })
            line.menu.performActionForItem(at: line.index)
            #expect(browser.pinPair(of: left.id) != nil)
            #expect(browser.gridPins.count == 1 && browser.tabs.count == 2)
        }
    }

    @Test func moveToTodayUnpinsBothHalvesTogether() throws {
        try world(pinned: true) { browser, left, right in
            try pick(menu(browser, right), ["Move to", "Today"])
            #expect(left.pin == nil && right.pin == nil)
            #expect(browser.pair(of: left.id)?.second == right.id)
            #expect(browser.gridPins.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func duplicateCreatesAnotherSplitWithTheSamePagesAndShare(pinned: Bool) throws {
        try world(pinned: pinned) { browser, left, right in
            let original = try #require(browser.pairs.first)
            try pick(menu(browser, right), ["Duplicate"])
            #expect(browser.tabs.count == 4 && browser.pairs.count == 2)
            #expect(browser.pairs.first == original)
            let copy = try #require(browser.pairs.last)
            let a = try #require(browser.tab(id: copy.first)), b = try #require(browser.tab(id: copy.second))
            #expect(a !== left && b !== right)
            #expect((a.pending ?? a.address) == left.address)
            #expect((b.pending ?? b.address) == right.address)
            #expect(a.pin == nil && b.pin == nil)
            #expect(copy.share == original.share && copy.contains(browser.activeID))
            let list = ActionMenuList(menu: menu(browser, b), falls: true)
            #expect(list.lines.first?.title == "Pin Pair")
        }
    }

    @Test func copyingFromTheRightSubmenuUsesTheRightPage() throws {
        try world { browser, left, right in
            try pick(menu(browser, left), ["Right", "Copy Link"])
            #expect(NSPasteboard.general.string(forType: .string) == right.address?.absoluteString)
            #expect(browser.pairs.count == 1 && browser.tabs.count == 2)
        }
    }

    @Test func pageSubmenusKeepTheirOwnIconsInFullColor() throws {
        try world { browser, left, right in
            func icon(_ color: NSColor) -> NSImage {
                NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                    color.setFill()
                    NSBezierPath(rect: rect).fill()
                    return true
                }
            }
            left.icon = icon(.red)
            right.icon = icon(.blue)
            let root = menu(browser, left)
            let a = try #require(try item(root, ["Left"]).image)
            let b = try #require(try item(root, ["Right"]).image)
            #expect(!a.isTemplate && !b.isTemplate)
            let red = try #require(a.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.colorAt(x: 8, y: 8)?.usingColorSpace(.deviceRGB))
            let blue = try #require(b.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.colorAt(x: 8, y: 8)?.usingColorSpace(.deviceRGB))
            #expect(red.redComponent > 0.9 && red.blueComponent < 0.1)
            #expect(blue.blueComponent > 0.9 && blue.redComponent < 0.1)
        }
    }
}
