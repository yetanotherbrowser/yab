import Foundation
import Testing
@testable import Fast

struct MemoryCeilingPaceTests {
    @Test func pagesAreWeighedOftenOnlyWhileOneCouldReachTheCeiling() {
        let ceiling: UInt64 = 8 << 30
        #expect(MemoryCeiling.every(agents: false, largest: 500 << 20, ceiling: ceiling) == 15)
        #expect(MemoryCeiling.every(agents: false, largest: (2 << 30) - 1, ceiling: ceiling) == 15)
        #expect(MemoryCeiling.every(agents: false, largest: 2 << 30, ceiling: ceiling) == 5)
        #expect(MemoryCeiling.every(agents: true, largest: 0, ceiling: ceiling) == 5)
        // A page the census hasn't seen yet waits a slow look for it and one
        // more to be weighed: from nothing it would have to grow by the whole
        // ceiling in that time, over 250 MB a second.
        #expect(Double(ceiling) / (2 * MemoryCeiling.slow) > 250 * 1_048_576)
    }
}
