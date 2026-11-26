import XCTest

final class TabFolderEditingUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() { continueAfterFailure = false }
    override func tearDown() { app?.terminate() }

    private func picture(_ name: String) throws {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let folder = Atlas.out.appendingPathComponent("tab-edits")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try screenshot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
    }
    private func row(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func button(_ title: String) -> XCUIElement { app.buttons[title].firstMatch }
    private func hold(_ id: String, expecting title: String) {
        let target = row(id)
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.press(forDuration: 1)
        XCTAssertTrue(button(title).waitForExistence(timeout: 10), app.debugDescription)
    }
    private func run(dark: Bool) throws {
        app = XCUIApplication()
        let ready = Atlas.readyFolder()
        defer { try? FileManager.default.removeItem(at: ready) }
        XCTAssertTrue(Atlas.launch(app, state: "tabedits.1", ready: ready,
                                   extra: ["-settings.appearance", dark ? "dark" : "light"]))
        let mode = dark ? "dark" : "light"
        try picture(mode + "-column")
        hold("newtab.pin.edit-pin", expecting: "Rename Tab…")
        try picture(mode + "-pin-menu")
        button("Rename Tab…").tap()
        XCTAssertTrue(app.alerts["Rename Tab"].waitForExistence(timeout: 10))
        try picture(mode + "-rename-alert")
        let text = app.alerts.textFields.firstMatch
        text.tap()
        text.press(forDuration: 1)
        if button("Select All").waitForExistence(timeout: 2) { button("Select All").tap() }
        text.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60) + "My reference")
        app.alerts.buttons["Save"].tap()
        hold("newtab.pin.edit-pin", expecting: "Rename Tab…")
        button("Rename Tab…").tap()
        XCTAssertTrue(app.alerts.buttons["Reset"].waitForExistence(timeout: 10))
        app.alerts.buttons["Reset"].tap()
        hold("newtab.tab.edit-tab", expecting: "Move to Folder")
        try picture(mode + "-kept-menu")
        button("Move to Folder").tap()
        XCTAssertTrue(button("New Folder").waitForExistence(timeout: 10))
        try picture(mode + "-move-menu")
        button("New Folder").tap()
        XCTAssertTrue(app.alerts["New Folder"].waitForExistence(timeout: 10))
        let folderName = app.alerts.textFields.firstMatch
        folderName.tap()
        folderName.typeText("Reading")
        app.alerts.buttons["Save"].tap()
        let reading = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Reading")).firstMatch
        XCTAssertTrue(reading.waitForExistence(timeout: 10))
        try picture(mode + "-created-folder")
        reading.tap()
        hold("newtab.tab.edit-tab", expecting: "Move Out of Folder")
        button("Move Out of Folder").tap()
        hold("newtab.folder.edit-folder", expecting: "Rename Folder")
        try picture(mode + "-folder-menu")
        button("Rename Folder").tap()
        XCTAssertTrue(app.alerts["Rename Folder"].waitForExistence(timeout: 10))
        app.alerts.buttons["Cancel"].tap()
        hold("newtab.folder.edit-folder", expecting: "Delete Folder")
        button("Delete Folder").tap()
        XCTAssertFalse(row("newtab.folder.edit-folder").exists)
        XCTAssertTrue(row("newtab.tab.edit-tab").exists)
    }
    func testNativeMenusRenameResetAndFoldersInLight() throws { try run(dark: false) }
    func testNativeMenusRenameResetAndFoldersInDark() throws { try run(dark: true) }
}
