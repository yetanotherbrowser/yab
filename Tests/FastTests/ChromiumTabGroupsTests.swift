import Foundation
import Testing
import YabCoreClient
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
        groups.start()
        for _ in 0..<100 { groups.changed() }
        #expect(groups.scans == 0, "A setter must finish before reading its state")
        await turn()
        #expect(groups.scans == 1)
        groups.changed()
        await turn()
        #expect(groups.scans == 2)
    }

    @Test func unchangedStateHasNoPeriodicScanAndReconnectInvalidates() async throws {
        let groups = ChromiumTabGroups()
        groups.start()
        await turn()
        let before = groups.scans
        // More than two periods of the removed half-second timer.
        try await Task.sleep(for: .milliseconds(1200))
        #expect(groups.scans == before)
        groups.start()
        await turn()
        #expect(groups.scans == before + 1, "A new helper must receive the groups again")
    }

    @Test func onlyAHelperThatSaysSoHasNoNativeGroups() {
        #expect(ChromiumTabGroups.helperLacksGroups(.number(0)), "A helper built on stock CEF")
        #expect(ChromiumTabGroups.helperLacksGroups(.bool(false)))
        for capability in [nil, .null, .number(1), .bool(true), .string("false")] as [JSONValue?] {
            #expect(!ChromiumTabGroups.helperLacksGroups(capability), "The patched helper, or one from before the hook")
        }
    }
}
