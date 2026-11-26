import XCTest
@testable import YabPhone

/// The Mac's commands in the field: a whole name leads, a begun one follows the first row.
final class CommandRowsTests: XCTestCase {
    private let commands = [
        CommandCandidate(token: "zoomIn", title: "Zoom In", aliases: ["bigger"], shortcut: "⌘+"),
        CommandCandidate(token: "reader", title: "Show Reader", aliases: ["reader"], shortcut: "⇧⌘R"),
        CommandCandidate(token: "print", title: "Print…", shortcut: "⌘P"),
    ]

    func testAWholeNameLeadsEveryOtherRow() {
        let search = WordRow(action: .search, icon: .magnifier, title: "print", subtitle: "", key: .search, group: .web)
        let rows = Words.withCommands([search], typed: "Print", commands: commands)
        XCTAssertEqual(rows.first?.action, .command("print"))
        XCTAssertEqual(rows.first?.title, "Print")
        XCTAssertEqual(rows.first?.subtitle, "Yab · ⌘P")
        XCTAssertEqual(rows.last, search)
    }

    func testAnAliasCountsAsTheName() {
        XCTAssertEqual(Words.commandRows("reader", commands: commands).exact.map(\.action), [.command("reader")])
        XCTAssertEqual(Words.commandRows("bigger", commands: commands).exact.map(\.action), [.command("zoomIn")])
    }

    func testABegunNameStandsUnderTheFirstRow() {
        let first = WordRow(action: .tab(id: "a"), icon: .globe, title: "Zoo", subtitle: "", key: .go, group: .tabs)
        let rows = Words.withCommands([first], typed: "zoo", commands: commands)
        XCTAssertEqual(rows.map(\.action), [.tab(id: "a"), .command("zoomIn")])
        XCTAssertTrue(Words.commandRows("zo", commands: commands).begun.isEmpty, "two letters find nothing")
        XCTAssertTrue(Words.commandRows("weather", commands: commands).begun.isEmpty)
    }

    func testShortcutsReadAsTheMenuWritesThem() {
        XCTAssertEqual(BrowserKey.reader.shortcut, "⇧⌘R")
        XCTAssertEqual(BrowserKey.zoomIn.shortcut, "⌘+")
        XCTAssertFalse(BrowserKey.tab(3).commandable)
        XCTAssertEqual(Set(BrowserKey.all.map(\.title)).count, BrowserKey.all.count)
    }
}
