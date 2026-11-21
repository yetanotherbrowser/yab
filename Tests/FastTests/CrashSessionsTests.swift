import Foundation
import XCTest
@testable import Fast

final class CrashSessionsTests: XCTestCase {
    private func fixture() throws -> (URL, CrashSessionLedger) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, CrashSessionLedger(folder: folder))
    }

    private func makeRun(_ pid: Int32 = 123) -> CrashSessionLedger.Run {
        .init(started: Date(timeIntervalSince1970: 100), observed: Date(timeIntervalSince1970: 160),
              version: "0.47.1", build: 202611082225, os: "27.0", pid: pid, uptime: 60,
              tabs: 37, windows: 2, asleepTabs: 35,
              extensions: [.init(id: "aeblfdkhhhdcdjpifhhbdiojplfjncoa", version: "8.12.44.33", enabled: true)],
              processIDs: [pid, 456])
    }

    func testNextLaunchRetainsUncleanRunAndCleanQuitDoesNotResurrectMarker() throws {
        let (folder, first) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = makeRun()
        try first.begin(old)
        first.update { $0.tabs = 40 }
        // A second process reads the on-disk marker. Flush the first process's
        // queued observation without deleting it, as SIGKILL would leave it.
        _ = try first.pending()
        let next = CrashSessionLedger(folder: folder)
        try next.begin(makeRun(789))
        let pending = try XCTUnwrap(next.pending().first)
        XCTAssertEqual(pending.id, old.id)
        XCTAssertEqual(pending.tabs, 40)
        next.update { $0.windows = 3 }
        try next.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: next.marker.path))
        XCTAssertEqual(try next.pending().count, 1, "a clean quit does not discard an unsent earlier run")
        try next.acknowledge(pending)
        XCTAssertTrue(try next.pending().isEmpty)
        let clean = CrashSessionLedger(folder: folder)
        try clean.begin(makeRun(999))
        XCTAssertTrue(try clean.pending().isEmpty)
        try clean.finish()
    }

    func testRepeatedUncleanLaunchesAreSeparateAndUnacknowledgedRunsRemain() throws {
        let (folder, ledger) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = makeRun(), b = makeRun(456), c = makeRun(789)
        try ledger.begin(a)
        try ledger.begin(b)
        try ledger.begin(c)
        XCTAssertEqual(Set(try ledger.pending().map(\.id)), Set([a.id, b.id]))
        try ledger.acknowledge(a)
        XCTAssertEqual(try ledger.pending().map(\.id), [b.id])
        try ledger.finish()
    }

    func testReportKeepsContextButNeverInventsSignalOrStack() throws {
        var old = makeRun()
        old.deaths = [.init(at: old.observed, kind: "helper", pid: 456, reason: "signal", code: 9)]
        let logs = CrashExitLogs.Result(availability: "unavailable (error 1)", from: old.started,
                                       through: old.observed, entries: [])
        let report = try CrashExitLogs.report(old, logs: logs)
        let parts = report.text.split(separator: "\n", maxSplits: 1)
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any])
        XCTAssertEqual(header["bug_type"] as? String, "YabUncleanExit")
        XCTAssertEqual(Crashes.uploadIdentity(report.text).version, "0.47.1")
        XCTAssertEqual((body["exception"] as? [String: String])?["type"], "UNCLEAN_EXIT")
        XCTAssertNil((body["exception"] as? [String: Any])?["signal"])
        XCTAssertTrue((body["threads"] as? [Any])?.isEmpty == true)
        let data = try XCTUnwrap(body["uncleanExit"] as? [String: Any])
        let session = try XCTUnwrap(data["session"] as? [String: Any])
        XCTAssertEqual(session["tabs"] as? Int, 37)
        XCTAssertEqual(session["windows"] as? Int, 2)
        XCTAssertEqual(session["uptime"] as? Double, 60)
        XCTAssertEqual((session["extensions"] as? [[String: Any]])?.first?["id"] as? String,
                       "aeblfdkhhhdcdjpifhhbdiojplfjncoa")
    }

    func testUnifiedLogClassificationDropsRawMessagesAndUnrelatedProcesses() throws {
        let old = makeRun()
        let secret = "SIGKILL pid 123 https://private.example/token?key=secret /Users/alice/Documents/private alice@example.com"
        let evidence = try XCTUnwrap(CrashExitLogs.evidence(at: old.observed, process: "launchd", pid: 1,
                                                           message: secret, run: old))
        XCTAssertEqual(evidence.signal, 9)
        XCTAssertEqual(evidence.correlatedPID, 123)
        let data = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
        for word in ["private", "alice", "secret", "example.com"] { XCTAssertFalse(data.contains(word)) }
        XCTAssertNil(CrashExitLogs.evidence(at: old.observed, process: "other", pid: 123,
                                          message: secret, run: old))
        XCTAssertNil(CrashExitLogs.evidence(at: old.observed, process: "launchd", pid: 1,
                                          message: "pid 1234 exited status 9", run: old))
        XCTAssertNil(CrashExitLogs.evidence(at: old.observed, process: "launchd", pid: 1,
                                          message: "unrelated service exited after 123 seconds", run: old))
        let pressure = CrashExitLogs.evidence(at: old.observed, process: "kernel", pid: 0,
                                             message: "memory pressure warning", run: old)
        XCTAssertEqual(pressure?.kind, "memory-pressure")
        XCTAssertNil(pressure?.correlatedPID, "system pressure is context, not an attributed kill")
    }

    func testTerminationReasonSurvivesGlobalPressureChatter() throws {
        let run = makeRun()
        let exit = try XCTUnwrap(CrashExitLogs.evidence(at: run.observed, process: "runningboardd", pid: 5,
            message: "[app<application.dev.serafim.fast>:123] termination reason: namespace SIGNAL, code 0x9", run: run))
        XCTAssertEqual(exit.correlatedPID, 123)
        XCTAssertEqual(exit.namespace, "SIGNAL")
        XCTAssertEqual(exit.code, 9)
        XCTAssertNil(exit.reason, "SIGKILL alone cannot distinguish Force Quit from an OS kill")
        var entries: [CrashExitLogs.Evidence] = []
        CrashExitLogs.retain(exit, in: &entries)
        for i in 0..<100 {
            let pressure = try XCTUnwrap(CrashExitLogs.evidence(at: run.observed.addingTimeInterval(Double(i)),
                process: "runningboardd", pid: 5, message: "memory pressure warning", run: run))
            CrashExitLogs.retain(pressure, in: &entries)
        }
        XCTAssertEqual(entries.count, 9)
        XCTAssertEqual(entries.first, exit)
        let report = try CrashExitLogs.report(run, logs: .init(availability: "available", from: run.started,
                                                             through: run.observed, entries: entries))
        XCTAssertTrue(report.text.contains("SIGNAL"))
        XCTAssertTrue(report.text.contains("namespace"))
    }

    func testRunningBoardContextIsStructuredAndPrivateExplanationIsDropped() throws {
        let run = makeRun()
        let exit = try XCTUnwrap(CrashExitLogs.evidence(at: run.observed, process: "runningboardd", pid: 5,
            message: "[app<application.dev.serafim.fast>:123] <RBSProcessExitContext| <RBSTerminateContext| domain:10 code:0x8BADF00D explanation:alice@example.com>>", run: run))
        XCTAssertEqual(exit.domain, 10)
        XCTAssertEqual(exit.code, 0x8BADF00D)
        XCTAssertEqual(exit.kind, "termination-reason")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(exit), as: UTF8.self).contains("alice"))
        XCTAssertNil(CrashExitLogs.evidence(at: run.observed, process: "runningboardd", pid: 5,
            message: "[app<application.other>:1234] termination reason: namespace SIGNAL, code 9", run: run))
        let forced = CrashExitLogs.evidence(at: run.observed, process: "launchd", pid: 1,
            message: "pid 123 exited SIGKILL (Force Quit)", run: run)
        XCTAssertEqual(forced?.reason, "force-quit")
        let helper = CrashExitLogs.evidence(at: run.observed, process: "kernel", pid: 0,
            message: "memorystatus killing process 456 jetsam", run: run)
        XCTAssertEqual(helper?.correlatedPID, 456)
        XCTAssertEqual(helper?.reason, "memory-kill")
    }

    func testReadinessAndJetsamBoostAreNotTerminationEvidence() throws {
        let run = makeRun()
        for message in ["SignalReady: pid=123 asn=0x0-0x1", "SIGNAL: pid=123 asn=0x0-0x1",
                        "ProcessAssertion::acquireSync Successfully took RBS assertion 'Jetsam Boost' for process with PID=456"] {
            XCTAssertNil(CrashExitLogs.evidence(at: run.observed, process: "yab", pid: 123, message: message, run: run))
        }
        let helper = try XCTUnwrap(CrashExitLogs.evidence(at: run.observed, process: "yab", pid: 123,
            message: "pid 456 terminated with signal 9", run: run))
        XCTAssertEqual(helper.correlatedPID, 456, "the referenced process, not the logger's PID")
        XCTAssertEqual(helper.signal, 9)
        let snapshot = CrashExitLogs.evidence(at: run.observed, process: "kernel", pid: 0,
            message: "memorystatus_update_jetsam_snapshot_entry_locked: failed to update pid 789, priority 0", run: run)
        XCTAssertEqual(snapshot?.kind, "memory-pressure", "a jetsam accounting message is not another kill")
        XCTAssertNil(snapshot?.reason)
        let idle = CrashExitLogs.evidence(at: run.observed, process: "kernel", pid: 0,
            message: "memorystatus: killing (idle) yab [123] due to idle-exit (9)", run: run)
        XCTAssertEqual(idle?.reason, "idle-exit")
        XCTAssertNil(idle?.signal, "the jetsam reason number is not a signal number")
    }

    func testSyntheticReportScrubsUntrustedStringsToo() throws {
        var old = makeRun()
        old.version = "https://private.example/?token=secret"
        old.extensions[0].version = "alice@example.com /Users/alice/secret 0123456789abcdef0123456789abcdef"
        let report = try CrashExitLogs.report(old, logs: .init(availability: "available", from: old.started,
                                                             through: old.observed, entries: []))
        XCTAssertFalse(report.text.contains("private.example"))
        XCTAssertFalse(report.text.contains("alice"))
        XCTAssertFalse(report.text.contains("0123456789abcdef"))
    }

    func testWatcherObservesBodyWrittenAfterDirectoryEntry() async throws {
        let (folder, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = folder.appendingPathComponent("YabCore-fixture.ips")
        let changed = expectation(description: "complete report observed without app restart")
        changed.assertForOverFulfill = false
        let watcher = CrashReportWatch(folder: folder, after: .distantPast) {
            if (try? String(contentsOf: report, encoding: .utf8))?.hasSuffix("complete") == true { changed.fulfill() }
        }
        try Data("header\n".utf8).write(to: report)
        try await Task.sleep(for: .milliseconds(300))
        let handle = try FileHandle(forWritingTo: report)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("complete".utf8))
        try handle.close()
        await fulfillment(of: [changed], timeout: 12)
        withExtendedLifetime(watcher) {}
    }

    private func marked(_ ledger: CrashSessionLedger) throws -> CrashSessionLedger.Run {
        _ = try ledger.pending()
        return try JSONDecoder().decode(CrashSessionLedger.Run.self, from: Data(contentsOf: ledger.marker))
    }

    func testAnUnchangedRunIsWrittenOnlyOnceABeat() throws {
        let (folder, ledger) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let run = makeRun()
        try ledger.begin(run)
        let start = run.observed
        // Looked at again and again with nothing new: the marker stays as written.
        for seconds in [10.0, 20, 30] {
            ledger.observe(at: start.addingTimeInterval(seconds)) { $0.uptime += 15; $0.memoryBytes = UInt64(seconds) }
        }
        XCTAssertEqual(try marked(ledger).observed, start)
        // A beat on, it is written whatever: the exit is looked for up to two minutes after.
        ledger.observe(at: start.addingTimeInterval(CrashSessionLedger.beat)) { _ in }
        XCTAssertEqual(try marked(ledger).observed, start.addingTimeInterval(CrashSessionLedger.beat))
        // Something new is written at once.
        ledger.observe(at: start.addingTimeInterval(CrashSessionLedger.beat + 15)) { $0.tabs = 38 }
        let now = try marked(ledger)
        XCTAssertEqual(now.tabs, 38)
        XCTAssertEqual(now.observed, start.addingTimeInterval(CrashSessionLedger.beat + 15))
        try ledger.finish()
    }

    @MainActor func testTheRunIsLookedAtLessWhileYabIsBehind() {
        XCTAssertEqual(CrashSessions.every(active: true), 15)
        XCTAssertEqual(CrashSessions.every(active: false), 60)
        // A slow look a moment early still writes.
        XCTAssertLessThan(CrashSessionLedger.beat, CrashSessions.every(active: false))
    }

    @MainActor func testAnExitAfterASkippedLookThenASlowOneIsStillLookedFor() throws {
        let (folder, ledger) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let run = makeRun()
        try ledger.begin(run)
        let start = run.observed
        // Yab coming forward brought a look to just short of a beat: it skips writing.
        let skipped = start.addingTimeInterval(CrashSessionLedger.beat - 1)
        ledger.observe(at: skipped) { _ in }
        XCTAssertEqual(try marked(ledger).observed, start)
        // Switched away before it fired, so the next look is the slowest one
        // later, and the main thread hangs a moment before it.
        let hang = skipped.addingTimeInterval(CrashSessions.every(active: false) - 1)
        // The person waits as long as before (one 15 s look, the exit looked
        // for 120 s after it) before force-quitting.
        let exit = hang.addingTimeInterval(120 - 15)
        let through = CrashExitLogs.window(try marked(ledger), now: exit.addingTimeInterval(3600)).through
        XCTAssertGreaterThanOrEqual(through, exit)
        try ledger.finish()
    }

    func testAWriteBetweenBeatsCarriesTheLatestLook() throws {
        let (folder, ledger) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let run = makeRun()
        try ledger.begin(run)
        let start = run.observed
        ledger.observe(at: start.addingTimeInterval(15)) { $0.uptime += 15; $0.memoryBytes = 300 << 20 }
        XCTAssertEqual(try marked(ledger).observed, start)
        // A pressure notice or a helper's death writes the run as last looked
        // at, not as last written: a jetsam report shows the memory at the end.
        ledger.update { $0.memoryPressure = "critical" }
        let pressed = try marked(ledger)
        XCTAssertEqual(pressed.memoryBytes, 300 << 20)
        XCTAssertEqual(pressed.observed, start.addingTimeInterval(15))
        XCTAssertEqual(pressed.memoryPressure, "critical")
        // A slow climb is still measured from what was written.
        ledger.observe(at: start.addingTimeInterval(30)) { $0.memoryBytes = 700 << 20 }
        XCTAssertEqual(try marked(ledger).observed, start.addingTimeInterval(15))
        ledger.observe(at: start.addingTimeInterval(40)) { $0.memoryBytes = 900 << 20 }
        XCTAssertEqual(try marked(ledger).memoryBytes, 900 << 20)
        try ledger.finish()
    }

    func testAMemoryClimbIsWrittenAtOnce() {
        var run = makeRun(), climbed = run
        run.memoryBytes = 3 << 30
        climbed.memoryBytes = 4 << 30
        // An out-of-memory exit's marker shows the climb, not memory a beat old.
        XCTAssertFalse(CrashSessionLedger.same(run, climbed))
        climbed.memoryBytes = (3 << 30) + (100 << 20)
        XCTAssertTrue(CrashSessionLedger.same(run, climbed))
    }
}
