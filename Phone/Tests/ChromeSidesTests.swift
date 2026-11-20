import UIKit
import XCTest
@testable import YabPhone

/// The chrome keeps its controls out of what the system reserves at the
/// window's sides (a status column on a foldable, a cutout in landscape).
@MainActor
final class ChromeSidesTests: XCTestCase {
    private let wide = CGSize(width: 900, height: 600)
    private let sides = ChromeGeometry.Sides(left: 40, right: 80)

    private func geometry(_ size: CGSize? = nil, rail: Bool? = true, leading: Bool = false,
                          sides: ChromeGeometry.Sides? = nil) -> ChromeGeometry {
        ChromeGeometry(size: size ?? wide, folded: false, hasNow: false, verticalControls: rail,
                       leadingRail: leading, sides: sides ?? self.sides)
    }

    func testTrailingRailClearsTheRightColumn() {
        let g = geometry()
        XCTAssertLessThanOrEqual(g.back.maxX, wide.width - sides.right - Metrics.Edge.bar)
        XCTAssertLessThanOrEqual(g.space.maxX, wide.width - sides.right - Metrics.Edge.bar)
        XCTAssertEqual(g.back.minX, g.space.minX)
    }

    func testLeadingRailClearsTheLeftInset() {
        let g = geometry(leading: true)
        XCTAssertGreaterThanOrEqual(g.back.minX, sides.left + Metrics.Edge.bar)
        XCTAssertGreaterThanOrEqual(g.space.minX, sides.left + Metrics.Edge.bar)
    }

    func testPortraitSideButtonsClearBothInsets() {
        let g = geometry(CGSize(width: 400, height: 800), rail: false)
        XCTAssertGreaterThanOrEqual(g.back.minX, sides.left)
        XCTAssertLessThanOrEqual(g.space.maxX, 400 - sides.right)
    }

    /// All Tabs and the spaces on the Duo's cover (466 wide, status column 84
    /// at the right): the head's computer stays out of the column, which takes
    /// every touch, and the foot's capsule stays clear of + and Done (#915).
    func testSpacesHeadAndFootClearTheCoverColumn() {
        let size = CGSize(width: 466, height: 678), column = ChromeGeometry.Sides(left: 0, right: 84)
        let computer = SpacePagesCard.headButton(right: true, width: size.width, sides: column)
        XCTAssertLessThanOrEqual(computer.maxX, size.width - column.right)
        let foot = TabGalleryLayout(screen: size, count: 0, verticalControls: false, sides: column)
        let width = SpacesFootBar.capsuleWidth(foot), mid = SpacesFootBar.capsuleMidX(foot)
        XCTAssertGreaterThan(mid - width / 2, foot.chats.maxX)
        XCTAssertLessThan(mid + width / 2, foot.gear.minX)
    }

    func testPlateNeverReachesTheRail() {
        for leading in [false, true] {
            let g = geometry(leading: leading)
            XCTAssertFalse(g.plate.intersects(g.space), "plate \(g.plate) vs space \(g.space)")
            XCTAssertFalse(g.plate.intersects(g.back), "plate \(g.plate) vs back \(g.back)")
            XCTAssertGreaterThanOrEqual(g.plate.minX, sides.left)
            XCTAssertLessThanOrEqual(g.plate.maxX, wide.width - sides.right)
        }
    }

    func testBottomRowCentersInsideTheSafeArea() {
        let size = CGSize(width: 466, height: 678)
        let g = geometry(size, rail: false, sides: .init(left: 0, right: 84))
        XCTAssertEqual(g.plate.midX, (size.width - 84) / 2)
        XCTAssertEqual(g.back.minX, size.width - 84 - g.space.maxX)
    }

    func testRailTracksBothColumnsAndATallerLiveActivity() {
        for left in [false, true] {
            var g = geometry(CGSize(width: 951, height: 669), sides: left ? .init(left: 84, right: 0) : .init(left: 0, right: 84))
            let x: CGFloat = left ? 0 : 867
            g.reservations = .init(occlusions: [CGRect(x: x, y: 0, width: 84, height: 150)], statusBarHeight: 22)
            XCTAssertEqual(g.back.midX, left ? 42 : 909)
            XCTAssertEqual(g.space.midX, g.back.midX)
            XCTAssertEqual(g.back.minY, 172)
            let old = g.back
            g.reservations.occlusions.append(CGRect(x: x, y: 0, width: 84, height: 240))
            XCTAssertEqual(g.back.minY, 262)
            XCTAssertGreaterThan(g.back.minY, old.minY)
            XCTAssertGreaterThan(g.sidebar.minY, g.back.maxY)
        }
    }

    func testRailKeepsTheIdleColumnWithoutRegionsOrARowHeight() {
        var g = geometry(CGSize(width: 678, height: 466), sides: .init(left: 0, right: 84))
        // iOS 27.0: no reserved regions at all.
        XCTAssertEqual(g.back.minY, ChromeGeometry.idleColumnBottom)
        // A status bar standing in the column reports its length, not a row.
        g.reservations = .init(occlusions: [CGRect(x: 594, y: 0, width: 84, height: 80)], statusBarHeight: 466)
        XCTAssertEqual(g.back.minY, ChromeGeometry.idleColumnBottom)
        // However tall a Live Activity grows, Back and Sidebar stay above the space button.
        g.reservations = .init(occlusions: [CGRect(x: 594, y: 0, width: 84, height: 400)], statusBarHeight: 22)
        XCTAssertLessThanOrEqual(g.sidebar.maxY, g.space.minY)
        XCTAssertGreaterThan(g.back.minY, ChromeGeometry.idleColumnBottom)
    }

    func testRealDuoCameraAtEitherEndAndPortraitColumn() {
        let cases: [(CGSize, ChromeGeometry.Sides, [CGRect], CGFloat, CGFloat)] = [
            (.init(width: 678, height: 466), .init(left: 84, right: 0),
             [CGRect(x: 0, y: 0, width: 84, height: 82), CGRect(x: 29.667, y: 29.667, width: 37, height: 37)], 0, 390),
            (.init(width: 678, height: 466), .init(left: 0, right: 84),
             [CGRect(x: 594, y: 384, width: 84, height: 82), CGRect(x: 611.667, y: 399.667, width: 37, height: 37)], 0, 324),
            (.init(width: 466, height: 678), .init(left: 0, right: 84),
             [CGRect(x: 382, y: 0, width: 84, height: 170), CGRect(x: 399.667, y: 29.667, width: 37, height: 37)], 2, 602)
        ]
        for (size, sides, regions, status, footY) in cases {
            var g = geometry(size, sides: sides)
            g.reservations = .init(occlusions: regions, statusBarHeight: status)
            XCTAssertEqual(g.back.minY, 172)
            XCTAssertEqual(g.sidebar.minY, 232)
            XCTAssertEqual(g.space.minY, footY)
            XCTAssertLessThanOrEqual(g.sidebar.maxY + Metrics.Edge.bar, g.space.minY)
            for region in regions {
                for frame in [g.back, g.sidebar, g.space] { XCTAssertFalse(frame.intersects(region)) }
            }
            if regions[0].minY > size.height / 2 {
                XCTAssertEqual(g.space.maxY, regions[0].minY - Metrics.Edge.bar)
                // Preserve the top-group cap even if its own reservation grows.
                g.reservations.occlusions.append(CGRect(x: 594, y: 0, width: 84, height: 240))
                XCTAssertEqual(g.sidebar.maxY + Metrics.Edge.bar, g.space.minY)
            }
        }
    }

    func testFoldKeepsFootControlsInOneSafeSegment() {
        var g = geometry(CGSize(width: 951, height: 669), sides: .init(left: 0, right: 84))
        let fold = CGRect(x: 465, y: 0, width: 20, height: 669)
        g.reservations = .init(divisions: [fold])
        for frame in [g.plate, g.back, g.space, g.sidebar] { XCTAssertFalse(frame.intersects(fold)) }
        XCTAssertFalse(g.plate.intersects(g.space))
        g = geometry(CGSize(width: 951, height: 669), rail: false, sides: .zero)
        g.reservations = .init(divisions: [fold])
        XCTAssertFalse(g.plate.intersects(g.back))
        XCTAssertFalse(g.plate.intersects(g.space))
    }

    func testPlateClearsTheRailOnTheCoverOnItsSide() {
        let g = geometry(CGSize(width: 678, height: 466), sides: .init(left: 0, right: 84))
        XCTAssertFalse(g.plate.intersects(g.space))
    }

    func testPageRunsUnderAStatusColumnAndKeepsANotchsSides() {
        let chrome = PageViewport.Chrome(folded: false, hasNow: false, visible: true)
        let duo = PageViewport(size: wide, hardware: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84), chrome: chrome)
        XCTAssertEqual(duo.maximum.right, 0)
        XCTAssertEqual(duo.clear.right, 84)
        let left = PageViewport(size: wide, hardware: UIEdgeInsets(top: 0, left: 84, bottom: 34, right: 0), chrome: chrome)
        XCTAssertEqual(left.minimum.left, 0)
        XCTAssertEqual(left.maximum.right, 0)
        XCTAssertEqual(left.clear.left, 84)
        // A split pane at a notched window's edge keeps that edge.
        let pane = PageViewport(size: wide, hardware: UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 0), chrome: chrome,
                                statusColumn: false)
        XCTAssertEqual(pane.maximum.left, 62)
        let notch = PageViewport(size: wide, hardware: UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62), chrome: chrome)
        XCTAssertEqual(notch.maximum.left, 62)
        XCTAssertEqual(notch.maximum.right, 62)
    }

    func testColumnBesideAPageKeepsAPhonesFoot() {
        let column = CGSize(width: 320, height: 600)
        let foot = TabGalleryLayout(screen: column, count: 0, verticalControls: false, sides: .zero)
        XCTAssertEqual(foot.chats.midY, foot.gear.midY)
        XCTAssertEqual(foot.plus.midY, foot.gear.midY)
        XCTAssertFalse(foot.chats.intersects(foot.plus))
        XCTAssertFalse(foot.gear.intersects(foot.plus))
    }

    func testNoInsetsKeepsTheDrawing() {
        let g = geometry(sides: .zero)
        XCTAssertEqual(g.space.maxX, wide.width - Metrics.Edge.bar)
        let l = geometry(leading: true, sides: .zero)
        XCTAssertEqual(l.back.minX, Metrics.Edge.bar)
        var activity = g
        activity.reservations = .init(occlusions: [CGRect(x: 0, y: 0, width: 84, height: 240)], statusBarHeight: 22)
        XCTAssertEqual(activity.back, g.back)
        XCTAssertEqual(activity.plate, g.plate)
        XCTAssertEqual(activity.space, g.space)
    }

    func testPairedPaneTakesOnlyTheEdgeItTouches() {
        let layout = BrowserWorkspaceLayout(size: wide, regular: true, paired: true)
        let insets = UIEdgeInsets(top: 0, left: 40, bottom: 0, right: 80)
        let first = ChromeGeometry.Sides.of(pane: layout.pane(false), window: wide, insets: insets)
        let second = ChromeGeometry.Sides.of(pane: layout.pane(true), window: wide, insets: insets)
        XCTAssertEqual(first, .init(left: 40, right: 0))
        XCTAssertEqual(second, .init(left: 0, right: 80))
        // A pane's rail goes under the status column of the edge it touches.
        // Neither moves for an edge it does not touch.
        let a = geometry(layout.pane(false).size, leading: true, sides: first)
        XCTAssertEqual(a.back.midX, 20)
        XCTAssertEqual(a.back.minY, ChromeGeometry.idleColumnBottom)
        let b = geometry(layout.pane(true).size, sides: second)
        XCTAssertEqual(b.space.midX, layout.pane(true).width - 40)
        let inner = geometry(layout.pane(true).size, leading: true, sides: second)
        XCTAssertEqual(inner.back.midX, b.back.midX)
    }
}
