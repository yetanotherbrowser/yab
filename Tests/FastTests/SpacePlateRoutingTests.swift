import Testing
@testable import Fast

struct SpacePlateRoutingTests {
    @Test func keysIncludeEveryIntermediateSpaceInEitherDirection() {
        #expect(SpacePlateRouting.places(home: 0, count: 4, toward: 3) == [1, 2, 3])
        #expect(SpacePlateRouting.places(home: 3, count: 4, toward: 0) == [0, 1, 2])
        #expect(SpacePlateRouting.places(home: 2, count: 4, toward: 2).isEmpty)
    }

    @Test func gesturesUseOnlyRealNeighborsAndNeverWrap() {
        #expect(SpacePlateRouting.places(home: 0, count: 3, toward: nil) == [1])
        #expect(SpacePlateRouting.places(home: 1, count: 3, toward: nil) == [0, 2])
        #expect(SpacePlateRouting.places(home: 2, count: 3, toward: nil) == [1])
    }

    @Test func invalidOrdersDoNotSelectRows() {
        #expect(SpacePlateRouting.places(home: 0, count: 0, toward: nil).isEmpty)
        #expect(SpacePlateRouting.places(home: 0, count: -1, toward: nil).isEmpty)
        #expect(SpacePlateRouting.places(home: -1, count: 3, toward: 1).isEmpty)
        #expect(SpacePlateRouting.places(home: 1, count: 3, toward: 3).isEmpty)
    }
}
