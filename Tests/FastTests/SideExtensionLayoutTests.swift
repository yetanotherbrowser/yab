import Foundation
import Testing
@testable import Fast

@MainActor
struct SideExtensionLayoutTests {
    private func layout(width: CGFloat, count: Int, door: CGFloat) -> SideExtensionLayout {
        // As SiteControls has it, for the room it keeps and the grid it draws.
        SideExtensionLayout(sidebar: width, count: count, door: door)
    }

    @Test func emptyAndSinglePinKeepAddressHeight() {
        for count in [0, 1] {
            let layout = layout(width: 240, count: count, door: 28)
            #expect(!layout.separate)
            #expect(layout.height == 0)
        }
    }

    @Test func wideningTheSidebarBringsTheSamePinsBackInline() {
        let narrow = layout(width: 240, count: 4, door: 28)
        let wide = layout(width: 360, count: 4, door: 28)
        #expect(narrow.separate)
        #expect(narrow.columns == 4)
        #expect(narrow.cell >= 28)
        #expect(!wide.separate)
        #expect(wide.height == 0)
    }

    @Test func everyPinHasRoomAtEveryDensity() {
        for door: CGFloat in [26, 28] {
            for width: CGFloat in [200, 240, 300, 360] {
                for count in [4, 8, 12, 30] {
                    let layout = self.layout(width: width, count: count, door: door)
                    if layout.separate {
                        #expect(layout.cell >= door)
                        #expect(CGFloat(layout.columns) * layout.cell + CGFloat(layout.columns - 1) * layout.gap <= width - 16 + 0.01)
                        let rows = Int(layout.height / (door + layout.gap))
                        #expect(rows * layout.columns >= count)
                    }
                }
            }
        }
    }
    /// Arc: six pinned extensions over four Favorites across, three over two.
    @Test func extensionsStandHalfAgainAsManyAcrossAsFavorites() {
        for width in stride(from: Metrics.sideMin, through: Metrics.sideMax, by: 5) {
            let favorites = SideBar.pinColumns(12, width: width)
            #expect(SideBar.extensionColumns(60, width: width) == favorites * 3 / 2, "width \(width)")
            let tiles = layout(width: width, count: 60, door: 28)
            #expect(tiles.gap == SideBar.pinGap)
        }
    }

    /// Five or six of them: one row where Favorites go four across, as
    /// Arc's do, not three and two; three and two or three and three where
    /// they go two across, not two, two and one.
    @Test func aFewExtensionsTakeTheRowsArcsDo() throws {
        let widths = Array(stride(from: Metrics.sideMin, through: Metrics.sideMax, by: 5))
        let wide = try #require(widths.first { SideBar.pinColumns(12, width: $0) == 4 })
        let narrow = try #require(widths.first { SideBar.pinColumns(12, width: $0) == 2 })
        for count in [5, 6] {
            #expect(SideBar.extensionColumns(count, width: wide) == count)
            #expect(SideBar.extensionColumns(count, width: narrow) == 3)
        }
    }

    /// The room kept for six over the pins, at the width where pins first
    /// go four across and a point narrower, in both densities: one row of
    /// six, then two of three.
    @Test func theRoomKeptIsTheRowsDrawn() throws {
        let widths = Array(stride(from: Metrics.sideMin, through: Metrics.sideMax, by: 1))
        let four = try #require(widths.first { SideBar.pinColumns(12, width: $0) == 4 })
        for door: CGFloat in [26, 28] {
            let one = layout(width: four, count: 6, door: door), two = layout(width: four - 1, count: 6, door: door)
            try #require(one.separate && two.separate)
            #expect(one.columns == 6 && one.height == door + one.gap)
            #expect(two.columns == 3 && two.height == 2 * (door + two.gap))
        }
    }

}
