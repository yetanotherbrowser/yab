import UIKit
import XCTest
@testable import YabPhone

/// On a status column (an iPhone Duo's cover) Settings' × or ‹ stands where
/// the page's Back does, and its head and bodies keep to the safe area.
@MainActor
final class SettingsColumnTests: XCTestCase {
    private let cover = CGSize(width: 466, height: 678)
    private var sides = ChromeGeometry.Sides.zero

    override func setUp() { sides = ChromeGeometry.windowSides }
    override func tearDown() { ChromeGeometry.windowSides = sides }

    private func workspace(_ insets: UIEdgeInsets) -> BrowserWorkspace {
        let workspace = BrowserWorkspace()
        workspace.windowSize = cover
        workspace.windowInsets = insets
        ChromeGeometry.windowSides = .init(left: insets.left, right: insets.right)
        return workspace
    }

    private func pageBack(_ workspace: BrowserWorkspace) -> CGRect {
        ChromeGeometry(size: cover, folded: false, hasNow: false, verticalControls: workspace.verticalControls,
                       leadingRail: workspace.leadingRail, reservations: workspace.reservations).back
    }

    func testTheHeadButtonTakesThePagesBackInTheColumn() throws {
        for left in [false, true] {
            let x: CGFloat = left ? 0 : 382
            let workspace = workspace(UIEdgeInsets(top: 0, left: left ? 84 : 0, bottom: 34, right: left ? 0 : 84))
            // The Duo simulator's idle cover: the column's top and the camera.
            workspace.reservations = .init(occlusions: [CGRect(x: x, y: 0, width: 84, height: 170),
                                                       CGRect(x: x + 17.667, y: 29.667, width: 37, height: 37)],
                                           statusBarHeight: 2)
            var column = try XCTUnwrap(SettingsColumn(workspace: workspace, size: cover, folded: false, hasNow: false))
            XCTAssertEqual(column.button, pageBack(workspace))
            XCTAssertEqual(column.button.minY, ChromeGeometry.idleColumnBottom)
            XCTAssertEqual(column.button.midX, x + 42)
            XCTAssertEqual(column.sides, .init(left: left ? 84 : 0, right: left ? 0 : 84))
            // A Live Activity grows down the column: the button follows Back below it.
            workspace.reservations.occlusions.append(CGRect(x: x, y: 0, width: 84, height: 240))
            column = try XCTUnwrap(SettingsColumn(workspace: workspace, size: cover, folded: false, hasNow: false))
            XCTAssertEqual(column.button, pageBack(workspace))
            XCTAssertEqual(column.button.minY, 242)
        }
    }

    func testAPhoneWithoutAColumnKeepsItsHead() {
        let workspace = workspace(UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0))
        XCTAssertNil(SettingsColumn(workspace: workspace, size: cover, folded: false, hasNow: false))
    }
}
