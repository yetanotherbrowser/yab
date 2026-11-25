import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct ChromiumTabGroupsTests {
    private func turn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func changesWaitForConnectionAndCoalesceAfterSetters() async {
        let groups = ChromiumTabGroups()
        groups.changed()
        await turn()
        #expect(groups.scans == 0, "A WebKit-only launch has no grouping work")
        groups.start(native: true)
        for _ in 0..<100 { groups.changed() }
        #expect(groups.scans == 0, "A setter must finish before reading its state")
        await turn()
        #expect(groups.scans == 1)
        groups.changed()
        await turn()
        #expect(groups.scans == 2)
    }

    @Test func helperWithoutNativeGroupsPublishesNothing() async throws {
        let groups = ChromiumTabGroups()
        groups.start(native: false)
        groups.changed()
        await turn()
        try await groups.syncNow()
        #expect(groups.scans == 0, "Stock CEF has no tabs.group; a page's navigation must not wait on it")
    }

    @Test func unchangedStateHasNoPeriodicScanAndReconnectInvalidates() async throws {
        let groups = ChromiumTabGroups()
        groups.start(native: true)
        await turn()
        let before = groups.scans
        // More than two periods of the removed half-second timer.
        try await Task.sleep(for: .milliseconds(1200))
        #expect(groups.scans == before)
        groups.start(native: true)
        await turn()
        #expect(groups.scans == before + 1, "A new helper must receive the groups again")
    }
}
