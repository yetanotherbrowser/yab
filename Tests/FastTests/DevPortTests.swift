import Testing
@testable import Fast

/// #319: a local page's port stands at the row's end, where the cross comes
/// up under the pointer. It gave way on a tab awake but not on a kept tab
/// put down, whose cross in the column takes it out of the kept: that cross
/// was drawn over the port.
struct DevPortTests {
    private func yields(hovering: Bool = true, working: Bool = false, putDown: Bool = false, unkeeps: Bool = false) -> Bool {
        DevPort.yields(hovering: hovering, working: working, putDown: putDown, unkeeps: unkeeps)
    }

    @Test func thePortGivesWayWhereverTheCrossComesUp() {
        // A tab awake: the cross closes it.
        #expect(yields())
        // Kept and put down in the column: the cross takes it out of the kept.
        #expect(yields(putDown: true, unkeeps: true))
        // An agent at work on it has the slot.
        #expect(yields(working: true, putDown: true))
    }

    @Test func thePortStaysWhereThereIsNoCross() {
        // Kept and put down in the row of tabs across the top: no cross.
        #expect(!yields(putDown: true))
        // No pointer on the row.
        #expect(!yields(hovering: false))
        #expect(!yields(hovering: false, putDown: true, unkeeps: true))
    }
}
