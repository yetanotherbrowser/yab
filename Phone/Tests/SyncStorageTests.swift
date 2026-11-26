import Foundation
import SyncKit
import XCTest
@testable import YabPhone

/// Refusals use only this test's file-backed key store, never a real keychain.
@MainActor
final class SyncStorageTests: XCTestCase {
    private var folder: URL!
    private var app: AppModel?
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        app?.sync.end(); app = nil
        try? FileManager.default.removeItem(at: folder)
    }
    private var keyFolder: URL { folder.appendingPathComponent("keys") }
    private var keys: SyncKeychain { .testing(folder: keyFolder) }
    private func directory(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    private func phone() -> AppModel {
        let world = World(name: "storage-test", space: "public", spaces: [
            Space(id: "public", name: "Public", emoji: "", tint: RGB(238, 233, 226))
        ])
        let result = AppModel(world: world); app = result
        result.sync.attach(result, setup: .init(base: URL(string: "https://sync.test")!, keys: keys,
            folder: folder.appendingPathComponent("journal"), seed: false, makesKey: false,
            deviceName: "Owned test iPhone", transport: SyncMemoryServer()))
        return result
    }
    private var joinedCount: Int { Haptics.played.filter { $0.kind == .success && $0.reason == "joined" }.count }

    func testStoppedBackgroundCatchUpFinishesOnceWithoutWaitingForDeadline() async throws {
        let server = SyncMemoryServer()
        server.down = true
        let engine = try PhoneSync(seal: .make(), options: .init(base: URL(string: "https://sync.test")!,
            folder: folder.appendingPathComponent("catch-up"), device: .init(id: "phone", name: "Phone", model: "iPhone"), transport: server))
        defer { engine.stop() }
        let completed = expectation(description: "superseded catch-up")
        completed.assertForOverFulfill = true
        engine.catchUp(within: 30, closeAfter: true) { changed in
            XCTAssertFalse(changed)
            completed.fulfill()
        }
        engine.stop()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(engine.state, .off)
    }

    func testAccountMoveForgetsOldIdentityButKeepsTheSavedDestinationKey() throws {
        let destination = Seal.make()
        _ = keys.keep(destination)
        keys.token = "old-account-token"
        let before = try keys.savedDeviceID()
        keys.forget(keepingLocalKey: true)
        XCTAssertEqual(keys.local?.raw, destination.raw)
        XCTAssertNil(keys.token)
        XCTAssertNotEqual(try keys.savedDeviceID(), before)
    }

    func testLocalWriteFailureNeverWritesASharedKey() throws {
        try Data("owned obstacle".utf8).write(to: keyFolder)
        XCTAssertEqual(keys.keep(Seal.make()), .localFailure)
        XCTAssertNil(keys.local); XCTAssertNil(keys.shared)
        XCTAssertEqual(try Data(contentsOf: keyFolder), Data("owned obstacle".utf8))
    }
    func testSharedWriteFailureKeepsTheDurableLocalKeyAndReportsItsOwnResult() throws {
        let seal = Seal.make()
        try directory(keyFolder.appendingPathComponent("key-shared"))
        XCTAssertEqual(keys.keep(seal), .localOnly)
        XCTAssertEqual(keys.local?.raw, seal.raw); XCTAssertNil(keys.shared)
        let again = SyncKeychain.testing(folder: keyFolder)
        XCTAssertEqual(again.local?.raw, seal.raw)
        XCTAssertEqual(again.keep(seal, share: false), .localOnly)
    }
    func testSuccessfulSaveChecksBothCopiesAndSavedDeviceIdentityIsStable() throws {
        let seal = Seal.make()
        XCTAssertEqual(keys.keep(seal), .localAndShared)
        XCTAssertEqual(keys.local?.raw, seal.raw); XCTAssertEqual(keys.shared?.seal.raw, seal.raw)
        let first = try keys.savedDeviceID()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(try SyncKeychain.testing(folder: keyFolder).savedDeviceID(), first)
    }
    func testDeviceIdentityRefusalCannotReturnAnEphemeralIdentity() throws {
        let obstacle = keyFolder.appendingPathComponent("device")
        try directory(obstacle)
        XCTAssertThrowsError(try keys.savedDeviceID()); XCTAssertThrowsError(try keys.savedDeviceID())
        XCTAssertEqual(keys.deviceID, "")
        try FileManager.default.removeItem(at: obstacle)
        let saved = try keys.savedDeviceID()
        XCTAssertFalse(saved.isEmpty); XCTAssertEqual(try keys.savedDeviceID(), saved)
    }
    func testRecoveryStorageFailureRetainsInputAndNeverSignalsSuccessfulJoin() throws {
        let app = phone(), seal = Seal.make()
        app.sync.showRecovery(true); app.sync.typed = seal.recovery
        let count = joinedCount
        try directory(keyFolder.appendingPathComponent("key"))
        XCTAssertFalse(app.sync.useRecovery(app.sync.typed))
        XCTAssertEqual(app.sync.phase, .joining(.recovery(wrong: false)))
        XCTAssertEqual(app.sync.typed, seal.recovery); XCTAssertNotNil(app.sync.joinError)
        XCTAssertTrue(app.sync.showsJoin); XCTAssertNil(app.sync.engine); XCTAssertNil(keys.local)
        XCTAssertEqual(joinedCount, count); XCTAssertEqual(app.browser.spaceID, "public")
        try FileManager.default.removeItem(at: keyFolder.appendingPathComponent("key"))
        app.sync.retryJoin()
        XCTAssertEqual(app.sync.phase, .on); XCTAssertNil(app.sync.joinError)
        XCTAssertEqual(app.sync.typed, ""); XCTAssertEqual(keys.local?.raw, seal.raw)
        XCTAssertEqual(joinedCount, count + 1)
    }
    func testDeviceIdentityFailureKeepsTheSavedKeyAndRetriesWithoutReset() throws {
        let app = phone(), seal = Seal.make()
        app.sync.showRecovery(true); app.sync.typed = seal.recovery
        let count = joinedCount
        try directory(keyFolder.appendingPathComponent("device"))
        XCTAssertFalse(app.sync.useRecovery(app.sync.typed))
        XCTAssertEqual(app.sync.phase, .off); XCTAssertNotNil(app.sync.joinError)
        XCTAssertTrue(app.sync.showsJoin); XCTAssertNil(app.sync.engine)
        XCTAssertEqual(keys.local?.raw, seal.raw); XCTAssertEqual(app.sync.typed, seal.recovery)
        XCTAssertEqual(joinedCount, count)
        try FileManager.default.removeItem(at: keyFolder.appendingPathComponent("device"))
        app.sync.retryJoin()
        XCTAssertEqual(app.sync.phase, .on); XCTAssertEqual(keys.local?.raw, seal.raw)
        XCTAssertEqual(joinedCount, count + 1)
    }
    func testJournalStartFailureHasNoSuccessTickAndRetryKeepsIdentityAndData() throws {
        let app = phone(), seal = Seal.make()
        let journal = folder.appendingPathComponent("journal")
        let sentinel = Data("owned journal obstacle".utf8)
        try sentinel.write(to: journal)
        app.sync.showRecovery(true); app.sync.typed = seal.recovery
        let count = joinedCount
        XCTAssertFalse(app.sync.useRecovery(app.sync.typed))
        let id = try keys.savedDeviceID()
        XCTAssertEqual(app.sync.phase, .off); XCTAssertTrue(app.sync.showsJoin)
        XCTAssertNotNil(app.sync.joinError); XCTAssertEqual(app.sync.typed, seal.recovery)
        XCTAssertEqual(joinedCount, count); XCTAssertNil(app.sync.engine)
        XCTAssertEqual(try Data(contentsOf: journal), sentinel)
        let context = SharedLinkSyncContext(account: seal.account, device: id, base: URL(string: "https://sync.test")!,
                                           space: SyncCollection.firstSpace, tabs: [], lastOrder: nil)
        let shared = try context.prepare(.init(action: .keep, address: "https://example.test/share"), pending: [])
        XCTAssertEqual(app.sync.importShared(shared), false, "a failed journal leaves the share queued with its original identity")
        try FileManager.default.removeItem(at: journal)
        app.sync.retryJoin()
        XCTAssertEqual(app.sync.phase, .on); XCTAssertEqual(try keys.savedDeviceID(), id)
        XCTAssertEqual(keys.local?.raw, seal.raw); XCTAssertEqual(app.browser.spaceID, "public")
        XCTAssertEqual(joinedCount, count + 1)
    }
    func testICloudLocalCopyFailureShowsJoiningAndDoesNotStartAFalseAccount() throws {
        let seal = Seal.make()
        try directory(keyFolder.appendingPathComponent("key"))
        try seal.raw.write(to: keyFolder.appendingPathComponent("key-shared"))
        let app = phone()
        guard case .joining(.code) = app.sync.phase else { return XCTFail("A storage refusal cannot be joined") }
        XCTAssertNotNil(app.sync.joinError); XCTAssertTrue(app.sync.showsJoin)
        XCTAssertNil(app.sync.engine); XCTAssertNil(keys.local)
        XCTAssertEqual(keys.shared?.seal.raw, seal.raw)
    }
}
