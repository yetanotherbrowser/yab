#if SHARE_EXTENSION_REGRESSION
import CryptoKit
import SyncKit
import XCTest
@testable import YabPhone

/// The regression runner compiles the real share controller from each ref.
/// Its only adaptations expose the action/model and inject these services.
@MainActor
enum ShareExtensionFixture {
    static var queue = SharedLinkQueue(folder: nil)
    static var keys = SyncKeychain.testing(folder: FileManager.default.temporaryDirectory)
#if SHARE_SYNC_ACCESS
    static var syncAccess: SharedLinkSyncAccess?
#endif
    static var transport: any Transport = SyncMemoryServer()
}

@MainActor
final class ShareExtensionRegressionTests: XCTestCase {
    func testKeepForLaterReachesMacWithoutOpeningPhoneApp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("share-action-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let seal = Seal.make(), server = SyncMemoryServer()
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        keys.keep(seal, share: false)
        let device = try keys.savedDeviceID()
        keys.token = "share-test-token"
        server.tokens["share-test-token"] = (seal.account, device)
        let space = UUID().uuidString
        let mac = try TestMac(server: server, seal: seal)
        try mac.write(SyncCollection.space, space, SyncSpace(id: space, name: "Personal", icon: "", order: "V").fields)
        let live = expectation(description: "Mac connected")
        let received = expectation(description: "Keep for Later delivers a tab without opening the phone app")
        let address = "https://example.test/shared-from-safari"
        mac.client.stateChanged = { if $0 == .live { live.fulfill() } }
        mac.client.received = { records in
            if records.contains(where: { $0.collection == SyncCollection.tab && $0["url"]?.string == address }) { received.fulfill() }
        }
        mac.client.start()
        defer { mac.client.stop() }
        await fulfillment(of: [live], timeout: 3)

        let queueFolder = folder.appendingPathComponent("links")
#if SHARE_SYNC_CONTEXT
        // Arrange the context the app publishes before it goes to the back.
        let key = SymmetricKey(size: .bits256)
        ShareExtensionFixture.queue = SharedLinkQueue(folder: queueFolder, protection: .init(key: { key }))
        try SharedLinkSyncContext(account: seal.account, device: device, base: URL(string: "https://sync.test")!,
                                  space: space, tabs: [], lastOrder: nil).save(for: ShareExtensionFixture.queue)
#else
        ShareExtensionFixture.queue = SharedLinkQueue(folder: queueFolder)
#endif
        ShareExtensionFixture.keys = keys
#if SHARE_SYNC_ACCESS
        let access = SharedLinkSyncAccess(secrets: .init(storage: .files(folder.appendingPathComponent("share-secrets"))))
        XCTAssertNotNil(access.grant(seal: seal, token: "share-test-token", device: device))
        ShareExtensionFixture.syncAccess = access
#endif
        ShareExtensionFixture.transport = server
        let controller = ShareViewController()
        controller.model.found = .init(address: address, search: false, title: "Shared from Safari")
        controller.model.phase = .ready
        controller.choose(.keep)

        await fulfillment(of: [received], timeout: 3)
        withExtendedLifetime(controller) {}
        XCTAssertEqual(mac.journal.living(SyncCollection.tab).filter { $0["url"]?.string == address }.count, 1)
        XCTAssertEqual(ShareExtensionFixture.queue.count, 1, "the local import remains durable")
    }

#if SHARE_SYNC_ACCESS
    func testShareSheetOpenedBeforeSignOutCannotUseStaleContext() async throws {
        let wasTurnedOff = SettingsStore.shared.syncTurnedOff
        defer { SettingsStore.shared.syncTurnedOff = wasTurnedOff }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("share-signout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = SyncMemoryServer(), seal = Seal.make()
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        keys.keep(seal, share: false)
        let setup = SyncBridge.Setup(base: URL(string: "https://sync.test")!, keys: keys,
                                    folder: folder.appendingPathComponent("journal"), seed: false, makesKey: false,
                                    deviceName: "Test iPhone", transport: server, ownWorld: false)
        let profile = BrowserProfile(folder: folder.appendingPathComponent("profile"))
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        app.sync.attach(app, setup: setup)
        defer { app.sync.end() }
        let deadline = Date().addingTimeInterval(3)
        while setup.shareAccess.session == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(setup.shareAccess.session)
        let context = try XCTUnwrap(SharedLinkSyncContext.read(for: setup.sharedLinks))
        ShareExtensionFixture.queue = setup.sharedLinks
        ShareExtensionFixture.syncAccess = setup.shareAccess
        ShareExtensionFixture.transport = server
        let controller = ShareViewController()
        controller.model.found = .init(address: "https://example.test/after-sign-out", search: false, title: "Saved offline")
        controller.model.phase = .ready

        server.cut()
        app.sync.turnOff()
        // Even an old snapshot left by a concurrent reader grants no authority.
        try context.save(for: setup.sharedLinks)
        controller.choose(.keep)
        let saved = try XCTUnwrap(setup.sharedLinks.links.first)
        XCTAssertNil(saved.sync)
        XCTAssertEqual(saved.address, "https://example.test/after-sign-out")
        XCTAssertEqual(controller.model.phase, .kept)
        XCTAssertNil(setup.shareAccess.session)
    }
#endif
}
#endif
