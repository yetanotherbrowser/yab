import Foundation
@MainActor func run(_ name: String, _ body: (BackgroundDownloadsTests) async throws -> Void) async {
    let test = BackgroundDownloadsTests()
    let before = failures
    do { try await test.setUp(); try await body(test) } catch { failures += 1; print("    THREW \(error)") }
    try? await test.tearDown()
    print("\(failures == before ? "PASS" : "FAIL") \(name)")
}
await run("testOnlyAWholeReplayableGetGoesToTheSystem") { $0.testOnlyAWholeReplayableGetGoesToTheSystem() }
await run("testTheRequestCarriesOnlyTheCookiesABrowserWouldSendThere") { try $0.testTheRequestCarriesOnlyTheCookiesABrowserWouldSendThere() }
await run("testOnlyTheFileCountsAndOnlyStopIsThePersons") { $0.testOnlyTheFileCountsAndOnlyStopIsThePersons() }
await run("testAWholeFileLandsUnderItsRowWithoutCookiesAndLeavesNothingBehind") { try await $0.testAWholeFileLandsUnderItsRowWithoutCookiesAndLeavesNothingBehind() }
await run("testAnErrorPageIsAFailureWithRetryAndRetryLandsUnderTheSameRow") { try await $0.testAnErrorPageIsAFailureWithRetryAndRetryLandsUnderTheSameRow() }
await run("testStopDropsTheRowAndKeepsNothing") { try await $0.testStopDropsTheRowAndKeepsNothing() }
await run("testRedirectedAnonymousTransferCarriesNoCredentials") { try await $0.testRedirectedAnonymousTransferCarriesNoCredentials() }
await run("testFailedFileMoveKeepsRetry") { try await $0.testFailedFileMoveKeepsRetry() }
await run("testEventCompletionWorksInEitherCallbackOrder") { $0.testEventCompletionWorksInEitherCallbackOrder() }
await run("testMissingSystemTaskLeavesAFailedRowAndNoStaleLedger") { try await $0.testMissingSystemTaskLeavesAFailedRowAndNoStaleLedger() }
await run("testARecordOutlivesTheProcessThatStartedIt") { try await $0.testARecordOutlivesTheProcessThatStartedIt() }
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
