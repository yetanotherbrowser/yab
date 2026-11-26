import Foundation
import CryptoKit
import SyncKit
import XCTest
@testable import YabPhone

final class SharedLinkSyncTests: XCTestCase {
    private var folder: URL!
    private var access: SharedLinkSyncAccess {
        .init(secrets: .init(storage: .files(folder.appendingPathComponent("secrets"))))
    }
    private let space = UUID().uuidString
    private let base = URL(string: "https://sync.test")!

    override func setUp() {
        SyncCollection.register()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("share-sync-\(UUID())")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func context(_ seal: Seal, tabs: [Record] = []) -> SharedLinkSyncContext {
        .init(account: seal.account, device: "phone", base: base, space: space, tabs: tabs, lastOrder: "V")
    }

    func testSharedSnapshotAndQueuedRecordAreEncryptedAtRest() throws {
        let seal = Seal.make(), key = SymmetricKey(size: .bits256)
        let queue = SharedLinkQueue(folder: folder.appendingPathComponent("links"), protection: .init(key: { key }))
        let link = try prepared(seal)
        let record = try XCTUnwrap(SharedLinkSyncRecord.read(link)?.record)
        try context(seal, tabs: [record]).save(for: queue)
        XCTAssertTrue(queue.add(link))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { !$0.hasDirectoryPath } + FileManager.default.contentsOfDirectory(at: queue.folder!, includingPropertiesForKeys: nil)
        for file in files {
            let data = try Data(contentsOf: file)
            XCTAssertTrue(SharedLinkProtection.isSealed(data))
            XCTAssertNil(data.range(of: Data("example.com".utf8)))
            XCTAssertNil(data.range(of: Data("An article".utf8)))
        }
        XCTAssertEqual(SharedLinkSyncContext.read(for: queue)?.tabs, [record])
        XCTAssertEqual(queue.take().first?.sync, link.sync)
    }

    func testUnavailableOrWrongKeyPreservesTheQueueAndNeverWritesPlaintext() throws {
        let key = SymmetricKey(size: .bits256), wrongKey = SymmetricKey(size: .bits256)
        let queue = SharedLinkQueue(folder: folder, protection: .init(key: { key }))
        let link = try prepared(.make())
        XCTAssertTrue(queue.add(link))
        for protection in [SharedLinkProtection(key: { nil }), SharedLinkProtection(key: { wrongKey })] {
            let unreadable = SharedLinkQueue(folder: folder, protection: protection)
            XCTAssertTrue(unreadable.take().isEmpty)
            XCTAssertTrue(unreadable.links.isEmpty)
            XCTAssertEqual(unreadable.count, 1)
        }
        let locked = SharedLinkQueue(folder: folder, protection: .init(key: { nil }))
        XCTAssertFalse(locked.add(link))
        XCTAssertEqual(queue.take().first?.sync, link.sync)
    }

    func testSnapshotRejectsTamperingWrongPurposeAndOldPlaintext() throws {
        let seal = Seal.make(), key = SymmetricKey(size: .bits256)
        let protection = SharedLinkProtection(key: { key })
        let queue = SharedLinkQueue(folder: folder.appendingPathComponent("links"), protection: protection)
        let snapshot = context(seal)
        try snapshot.save(for: queue)
        let file = try XCTUnwrap(SharedLinkSyncContext.file(for: queue))
        let data = try Data(contentsOf: file)
        XCTAssertNil(protection.open(data, purpose: "yab.shared.link.v1"))
        let wrong = SharedLinkQueue(folder: queue.folder, protection: .init(key: { SymmetricKey(size: .bits256) }))
        XCTAssertNil(SharedLinkSyncContext.read(for: wrong))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        var cipher = try XCTUnwrap(json["sealed"].flatMap { Data(base64Encoded: $0) })
        cipher[cipher.count - 1] ^= 1
        json["sealed"] = cipher.base64EncodedString()
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertNil(SharedLinkSyncContext.read(for: queue))
        try JSONEncoder().encode(snapshot).write(to: file)
        XCTAssertNil(SharedLinkSyncContext.read(for: queue))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLegacyQueueEntriesRemainReadable() throws {
        let plain = SharedLinkQueue(folder: folder)
        let link = SharedLink(action: .keep, address: "https://example.com/legacy", title: "Legacy")
        XCTAssertTrue(plain.add(link))
        let key = SymmetricKey(size: .bits256)
        let secured = SharedLinkQueue(folder: folder, protection: .init(key: { key }))
        XCTAssertEqual(secured.take().first?.address, link.address)
        XCTAssertEqual(secured.count, 0)
    }

    private func prepared(_ seal: Seal) throws -> SharedLink {
        try context(seal).prepare(.init(action: .keep, address: "example.com/article", title: "An article"), pending: [])
    }

    private func server(_ seal: Seal) -> SyncMemoryServer {
        let server = SyncMemoryServer()
        server.tokens["phone-token"] = (seal.account, "phone")
        return server
    }

    private func upload(_ record: Record, seal: Seal, server: SyncMemoryServer, succeeds: Bool = true) {
        let done = expectation(description: "share upload finishes")
        let session = access.grant(seal: seal, token: "phone-token", device: "phone")!
        let upload = SharedLinkUpload(record: record, access: access, session: session, transport: server)!
        upload.start(base: base, within: 0.3) { success in
            XCTAssertEqual(success, succeeds)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        withExtendedLifetime(upload) {}
    }

    func testRevokedSessionCannotOpenAConnectionEvenAfterSigningInAgain() throws {
        let seal = Seal.make(), server = server(seal)
        let record = try XCTUnwrap(SharedLinkSyncRecord.read(prepared(seal))?.record)
        let session = try XCTUnwrap(access.grant(seal: seal, token: "phone-token", device: "phone"))
        let upload = try XCTUnwrap(SharedLinkUpload(record: record, access: access, session: session, transport: server))
        access.revoke()
        XCTAssertNil(access.session)
        XCTAssertNil(access.secrets.read("sync-session"))
        let next = try XCTUnwrap(access.grant(seal: seal, token: "phone-token", device: "phone"))
        XCTAssertNotEqual(session.id, next.id)
        let done = expectation(description: "the old upload is refused locally")
        upload.start(base: base) { success in
            XCTAssertFalse(success)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(server.sockets.isEmpty)
        XCTAssertNil(server.records[seal.account])
    }

    private final class HeldTransport: Transport, Line, @unchecked Sendable {
        let lock = NSLock()
        var received: ((String) -> Void)?
        var firstSend: (() -> Void)?
        private(set) var sent: [String] = []
        func request(_ request: URLRequest, _ done: @escaping (Int?, Data?) -> Void) { XCTFail("no registration from a share") }
        func open(_ request: URLRequest, received: @escaping (String) -> Void, closed: @escaping (Int?) -> Void) -> any Line {
            lock.lock(); self.received = received; lock.unlock()
            return self
        }
        func send(_ text: String) {
            lock.lock(); sent.append(text); let callback = firstSend; firstSend = nil; lock.unlock()
            callback?()
        }
        func close() {}
        func reply(_ message: [String: Any]) throws {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
            lock.lock(); let callback = received; lock.unlock()
            callback?(text)
        }
    }

    func testSignOutStopsAConflictRetryFromAnAlreadyOpenShare() throws {
        let seal = Seal.make()
        let record = try XCTUnwrap(SharedLinkSyncRecord.read(prepared(seal))?.record)
        let session = try XCTUnwrap(access.grant(seal: seal, token: "phone-token", device: "phone"))
        let transport = HeldTransport()
        let sent = expectation(description: "first push is in flight")
        transport.firstSend = { sent.fulfill() }
        let done = expectation(description: "sign-out cancels the conflict retry")
        let upload = try XCTUnwrap(SharedLinkUpload(record: record, access: access, session: session, transport: transport))
        upload.start(base: base) { success in
            XCTAssertFalse(success)
            done.fulfill()
        }
        wait(for: [sent], timeout: 2)
        access.revoke()
        // An older server record would normally require a second push.
        let old = Record(collection: record.collection, id: record.id)
        try transport.reply(["t": "pushed", "id": "share-1", "accepted": [],
                             "conflicts": [["name": seal.name(record.key), "version": 1,
                                            "blob": try seal.seal(old).base64EncodedString()]]])
        wait(for: [done], timeout: 2)
        XCTAssertEqual(transport.sent.count, 1)
    }

    func testPreviousQueueKeyRemainsReadableAfterTheExtensionWritesANewKey() throws {
        let oldKey = SymmetricKey(size: .bits256), newKey = SymmetricKey(size: .bits256)
        let old = SharedLinkQueue(folder: folder, protection: .init(key: { oldKey }))
        let link = SharedLink(action: .keep, address: "https://example.test/before-update")
        XCTAssertTrue(old.add(link))
        let migrated = SharedLinkQueue(folder: folder, protection: .init(key: { newKey }, legacyKey: { oldKey }))
        XCTAssertEqual(migrated.take().first?.address, link.address)
    }

    private func remote(_ server: SyncMemoryServer, seal: Seal, record: Record) throws -> Record {
        server.lock.lock(); defer { server.lock.unlock() }
        let stored = try XCTUnwrap(server.records[seal.account]?[seal.name(record.key)])
        return try seal.open(XCTUnwrap(Data(base64Encoded: stored.blob)), name: seal.name(record.key))
    }

    func testQueueAloneDoesNotSyncButShareUploadReachesMacWithoutPhoneApp() throws {
        let seal = Seal.make(), server = server(seal)
        let queue = SharedLinkQueue(folder: folder)
        let link = try prepared(seal)
        XCTAssertTrue(queue.add(link))
        XCTAssertNil(server.records[seal.account], "before: queuing alone sends nothing")
        let record = try XCTUnwrap(SharedLinkSyncRecord.read(link)?.record)
        let mac = try TestMac(server: server, seal: seal)
        let live = expectation(description: "Mac online")
        let arrived = expectation(description: "Mac receives shared tab")
        mac.client.stateChanged = { if $0 == .live { live.fulfill() } }
        mac.client.received = { records in
            if records.contains(where: { $0.key == record.key }) { arrived.fulfill() }
        }
        mac.client.start()
        defer { mac.client.stop() }
        wait(for: [live], timeout: 2)
        upload(record, seal: seal, server: server)
        wait(for: [arrived], timeout: 2)
        let tab = try XCTUnwrap(mac.journal.record(record.key).flatMap(SyncTab.init))
        XCTAssertEqual(tab.url, "https://example.com/article")
        XCTAssertEqual(tab.title, "An article")
        XCTAssertEqual(tab.space, space)
        XCTAssertEqual(tab.list, .kept)
        XCTAssertNil(tab.device)
        XCTAssertEqual(queue.count, 1, "the app's durable import remains")
    }

    func testLostAcknowledgmentThenAppImportUsesOneTabAndOriginalStamps() throws {
        let seal = Seal.make(), server = server(seal)
        server.holdsPushes = true
        let link = try prepared(seal)
        let record = try XCTUnwrap(SharedLinkSyncRecord.read(link)?.record)
        upload(record, seal: seal, server: server, succeeds: false)
        XCTAssertEqual(try remote(server, seal: seal, record: record), record)
        let journal = try Journal(path: nil, device: "phone")
        XCTAssertEqual(try journal.importLocal(record), record)
        XCTAssertEqual(journal.pendingCount, 1)
        server.letPushesGo()
        let client = SyncClient(base: base, journal: journal, seal: seal,
                                device: .init(id: "phone", name: "Phone", model: "iPhone"), transport: server)
        let live = expectation(description: "phone catches up")
        client.stateChanged = { if $0 == .live { live.fulfill() } }
        client.start()
        defer { client.stop() }
        wait(for: [live], timeout: 2)
        XCTAssertEqual(journal.record(record.key), record)
        XCTAssertEqual(journal.pendingCount, 0)
        XCTAssertEqual(journal.living(SyncCollection.tab).count, 1)
    }

    func testOfflineShareStaysQueuedAndCanBeImportedAfterRelaunch() throws {
        let seal = Seal.make(), server = server(seal)
        server.down = true
        let queue = SharedLinkQueue(folder: folder)
        let link = try prepared(seal)
        XCTAssertTrue(queue.add(link))
        let record = try XCTUnwrap(SharedLinkSyncRecord.read(link)?.record)
        upload(record, seal: seal, server: server, succeeds: false)
        XCTAssertTrue(queue.take(accept: { _ in false }).isEmpty)
        XCTAssertEqual(queue.count, 1, "not discarded while the app's sync journal is still opening")
        let journal = try Journal(path: folder.appendingPathComponent("import.sqlite").path, device: "phone")
        _ = queue.take { saved in
            guard let record = SharedLinkSyncRecord.read(saved)?.record else { return false }
            return (try? journal.importLocal(record)) != nil
        }
        XCTAssertEqual(queue.count, 0)
        let reopened = try Journal(path: folder.appendingPathComponent("import.sqlite").path, device: "phone")
        XCTAssertEqual(reopened.record(record.key), record)
        XCTAssertEqual(reopened.pendingCount, 1)
    }

    func testRepeatedSharesBeforeAppLaunchUseTheSameIdentity() throws {
        let seal = Seal.make()
        let first = try prepared(seal)
        let again = try context(seal).prepare(first, pending: [first])
        XCTAssertEqual(SharedLinkSyncRecord.read(first)?.record, SharedLinkSyncRecord.read(again)?.record)
        let second = try context(seal).prepare(.init(action: .keep, address: "https://example.com/second"), pending: [first])
        let a = try XCTUnwrap(SharedLinkSyncRecord.read(first)?.record["order"]?.string)
        let b = try XCTUnwrap(SharedLinkSyncRecord.read(second)?.record["order"]?.string)
        XCTAssertLessThan(a, b)
    }

    func testExistingTodayTabIsKeptWithItsIdentityAndServerEditsSurviveConflict() throws {
        let seal = Seal.make(), server = server(seal)
        let journal = try Journal(path: nil, device: "mac")
        let tab = SyncTab(space: space, url: "https://example.com/article", title: "Original", device: "phone")
        let original = try journal.change(.init(collection: SyncCollection.tab, id: tab.id), tab.fields)
        upload(original, seal: seal, server: server)
        let link = try context(seal, tabs: [original]).prepare(.init(action: .keep, address: tab.url), pending: [])
        let kept = try XCTUnwrap(SharedLinkSyncRecord.read(link)?.record)
        XCTAssertEqual(kept.id, original.id)
        let renamed = try journal.change(original.key, ["name": "My name"])
        upload(renamed, seal: seal, server: server)
        upload(kept, seal: seal, server: server)
        let result = try remote(server, seal: seal, record: kept)
        XCTAssertEqual(result["name"]?.string, "My name")
        XCTAssertEqual(SyncTab(result)?.list, .kept)
        XCTAssertNil(SyncTab(result)?.device)
    }

    func testQueuedSharesKeepSaveOrderForNewAndExistingTodayTabs() throws {
        let seal = Seal.make()
        for firstExists in [false, true] {
            for secondExists in [false, true] {
                let journal = try Journal(path: nil, device: "mac")
                let first = SyncTab(id: "FFFFFFFF-0000-4000-8000-000000000001", space: space,
                                    url: "https://example.test/first", title: "First", device: "phone")
                let second = SyncTab(id: "AAAAAAAA-0000-4000-8000-000000000001", space: space,
                                     url: "https://example.test/second", title: "Second", device: "phone")
                let tabs = try [(first, firstExists), (second, secondExists)].compactMap { tab, exists in
                    exists ? try journal.change(.init(collection: SyncCollection.tab, id: tab.id), tab.fields) : nil
                }
                let snapshot = context(seal, tabs: tabs)
                let a = try snapshot.prepare(.init(action: .keep, address: first.url), pending: [])
                let b = try snapshot.prepare(.init(action: .keep, address: second.url), pending: [a])
                let records = try [a, b].map { try XCTUnwrap(SharedLinkSyncRecord.read($0)?.record) }
                let row = SyncRow(space: space, tabs: records, folders: [], pairs: [])
                XCTAssertEqual(row.kept.map(\.url), [first.url, second.url], "existing tabs: \(firstExists), \(secondExists)")
                XCTAssertLessThan(try XCTUnwrap(records[0]["order"]?.string), try XCTUnwrap(records[1]["order"]?.string))
                if firstExists { XCTAssertEqual(records[0].id, first.id) }
                if secondExists { XCTAssertEqual(records[1].id, second.id) }
            }
        }
    }

    func testQueuedOrdersDoNotMovePinsOrKeptTabsOrCrossAccountsAndSpaces() throws {
        let seal = Seal.make(), journal = try Journal(path: nil, device: "mac")
        let tabs = [SyncTab(space: space, order: "A", url: "https://example.test/pin", title: "Pin", pin: "P"),
                    SyncTab(space: space, order: "B", url: "https://example.test/kept", title: "Kept", kept: true),
                    SyncTab(space: space, url: "https://example.test/today", title: "Today", device: "phone")]
        let records = try tabs.map { try journal.change(.init(collection: SyncCollection.tab, id: $0.id), $0.fields) }
        let snapshot = context(seal, tabs: records)
        let earlier = try prepared(seal)
        for record in records.prefix(2) {
            let link = try snapshot.prepare(.init(action: .keep, address: record["url"]!.string!), pending: [earlier])
            XCTAssertEqual(SharedLinkSyncRecord.read(link)?.record, record)
        }
        var otherSpace = snapshot
        otherSpace.space = UUID().uuidString
        otherSpace.lastOrder = "z"
        var otherAccount = snapshot
        otherAccount.account = Seal.make().account
        otherAccount.lastOrder = "z"
        let unrelated = try [otherSpace, otherAccount].map {
            try $0.prepare(.init(action: .keep, address: "https://example.test/unrelated"), pending: [])
        }
        let link = try snapshot.prepare(.init(action: .keep, address: tabs[2].url), pending: unrelated)
        XCTAssertEqual(SharedLinkSyncRecord.read(link)?.record["order"]?.string, Order.between(snapshot.lastOrder, nil))
    }

    func testImportNeverRestoresATabDeletedOnMacOrChangesNewerFields() throws {
        let seal = Seal.make()
        let record = try XCTUnwrap(SharedLinkSyncRecord.read(prepared(seal))?.record)
        let journal = try Journal(path: nil, device: "mac")
        _ = try journal.receive([(record, 1)])
        try journal.change(record.key, ["title": "A newer title"])
        XCTAssertEqual(try journal.importLocal(record)["title"]?.string, "A newer title")
        try journal.remove(record.key)
        XCTAssertFalse(try journal.importLocal(record).alive())
        let pending = journal.pendingCount
        _ = try journal.importLocal(record)
        XCTAssertEqual(journal.pendingCount, pending)
    }

    func testOtherAccountsPendingLinksAndOpenActionsAreNotUploaded() throws {
        let seal = Seal.make(), other = Seal.make()
        let first = try prepared(other)
        let link = try context(seal).prepare(first, pending: [first])
        XCTAssertNotEqual(SharedLinkSyncRecord.read(first)?.record.id, SharedLinkSyncRecord.read(link)?.record.id)
        let open = SharedLink(action: .open, address: "https://example.com")
        XCTAssertNil(try context(seal).prepare(open, pending: []).sync)
        let search = SharedLink(action: .keep, address: "some words", search: true)
        XCTAssertNil(try context(seal).prepare(search, pending: []).sync)
    }

    func testRevokedDeviceCannotUploadAndTheQueueStillHoldsItsLink() throws {
        let seal = Seal.make(), server = server(seal)
        server.devices[seal.account] = ["phone": .init(id: "phone", name: "Phone", model: "iPhone", revoked: true)]
        let queue = SharedLinkQueue(folder: folder)
        let link = try prepared(seal)
        XCTAssertTrue(queue.add(link))
        upload(try XCTUnwrap(SharedLinkSyncRecord.read(link)?.record), seal: seal, server: server, succeeds: false)
        XCTAssertEqual(queue.count, 1)
        XCTAssertNil(server.records[seal.account])
    }
}
