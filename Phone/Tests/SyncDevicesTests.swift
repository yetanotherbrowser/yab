import SyncKit
import XCTest
@testable import YabPhone

/// Settings › Sync on the iPhone: the account's devices, the Recovery Key
/// behind Face ID, Turn Off Sync on This iPhone.
@MainActor
final class SyncDevicesTests: PhoneLinkTestCase {
    override func tearDown() async throws {
        // Shared stores: the next test starts as a launch would.
        SettingsStore.shared.syncTurnedOff = false
        SettingsUI.shared.recoveryShown = nil
        SyncRecovery.authenticate = { $0(false) }
        try await super.tearDown()
    }
    // MARK: - Settings › Sync: devices, the Recovery Key, Turn Off

    func testDevicesInTheMacsWords() {
        let now = Date()
        let words = SettingsDevice.list([
            SyncDevice(id: "mac", name: "MacBook Pro", model: "Mac16,1", lastSeen: now.addingTimeInterval(-30)),
            SyncDevice(id: "old", name: "Old iPhone", model: "iPhone15,2", lastSeen: now.addingTimeInterval(-3 * 3600)),
            SyncDevice(id: "phone", name: "Mira’s iPhone", model: "iPhone18,1", lastSeen: now),
        ], own: "phone", now: now)
        XCTAssertEqual(words.map(\.id), ["phone", "mac", "old"], "this iPhone first")
        XCTAssertEqual(words[0].words, "This \(DeviceWord.name)")
        XCTAssertTrue(words[0].isPhone && words[0].isThis)
        XCTAssertEqual(words[1].words, "Syncing now")
        XCTAssertFalse(words[1].isPhone)
        XCTAssertTrue(words[2].words.hasPrefix("Last synced "), words[2].words)
        XCTAssertEqual(SettingsDevice.words(lastSeen: nil, now: now), "Not synced yet")
    }

    private func content(inSync: Bool, devices: [SettingsDevice] = [], key: String? = nil) -> SettingsContent {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "send-to-phone-\(UUID().uuidString)")!)
        return SettingsContent(store: store, context: SettingsContext(inSync: inSync, devices: devices, recoveryKey: key))
    }

    func testTheSyncPageListsDevicesTheRecoveryKeyAndTurnOff() throws {
        let devices = SettingsDevice.list([
            SyncDevice(id: "phone", name: "Mira’s iPhone", model: "iPhone18,1", lastSeen: Date()),
            SyncDevice(id: "mac", name: "MacBook Pro", model: "Mac16,1", lastSeen: Date()),
        ], own: "phone", now: Date())
        let sections = content(inSync: true, devices: devices).sections(.sync)
        XCTAssertEqual(sections.map(\.id), ["sync", "sync.history", "sync.recovery", "sync.off"])
        XCTAssertEqual(sections[0].title, "Devices")
        XCTAssertEqual(sections[0].rows.map(\.id), ["sync.device.phone", "sync.device.mac", "sync"])
        XCTAssertEqual(sections[0].rows[0].value, "This \(DeviceWord.name)")
        XCTAssertEqual(sections[0].rows[1].value, "Syncing now")
        guard case .glyph(.phone)? = sections[0].rows[0].icon, case .glyph(.macbook)? = sections[0].rows[1].icon else {
            return XCTFail("an iPhone's and a Mac's glyph")
        }
        guard case .page(.recoveryKey) = sections[2].rows[0].kind else { return XCTFail("the Recovery Key's page") }
        let off = sections[3].rows[0]
        XCTAssertEqual(off.title, "Turn Off Sync on This \(DeviceWord.name)")
        XCTAssertTrue(off.danger)
        guard case .action = off.kind else { return XCTFail("an action, asked first") }
        // Not in sync (a test world): the Mac's row as before, and no Turn Off.
        let out = content(inSync: false).sections(.sync)
        XCTAssertEqual(out.map(\.id), ["sync", "sync.history", "sync.recovery"])
        XCTAssertEqual(out[0].rows.first?.id, "mac")
        for text in (sections + out).flatMap({ $0.rows.map(\.title) + [$0.footer ?? ""] }) {
            XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), "no long dashes: \(text)")
        }
    }

    func testTheRecoveryKeyIsBehindFaceID() async throws {
        let locked = content(inSync: true).sections(.recoveryKey)
        XCTAssertEqual(locked.flatMap(\.rows).map(\.id), ["recovery.show"])
        let shown = content(inSync: true, key: "AEBA-GBAF").sections(.recoveryKey)
        XCTAssertEqual(shown.flatMap(\.rows).map(\.id), ["recovery.key", "recovery.copy"])
        XCTAssertEqual(shown.first?.rows.first?.title, "AEBA-GBAF")

        // A real account: the key shows only after a yes, and goes as Settings closes.
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await mac(server, seal)
        defer { mac.client.stop() }
        let app = try await joinedPhone(server, seal)
        SyncRecovery.authenticate = { $0(false) }
        SyncRecovery.reveal(app)
        XCTAssertNil(SettingsUI.shared.recoveryShown, "no yes, no key")
        SyncRecovery.authenticate = { $0(true) }
        SyncRecovery.reveal(app)
        XCTAssertEqual(SettingsUI.shared.recoveryShown, seal.recovery)
        SettingsUI.shared.settingsGone()
        XCTAssertNil(SettingsUI.shared.recoveryShown)
        app.sync.end()
    }

    func testTheDevicesListComesFromTheAccount() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await mac(server, seal)
        defer { mac.client.stop() }
        let app = try await joinedPhone(server, seal)
        defer { app.sync.end() }
        let listed = await until { Set(app.sync.devices.map(\.name)) == ["MacBook Pro", "Test iPhone"] }
        XCTAssertTrue(listed, "\(app.sync.devices)")
        let words = SettingsDevice.list(app.sync.devices, own: app.sync.ownDevice, now: Date())
        XCTAssertEqual(words.first?.words, "This \(DeviceWord.name)")
        XCTAssertEqual(words.first?.isPhone, true)
    }

    func testTurnOffLeavesTheAccountForgetsTheKeyAndICloudDoesNotBringItBack() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await mac(server, seal)
        defer { mac.client.stop() }
        let app = try await joinedPhone(server, seal)
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        XCTAssertEqual(keys.local?.raw, seal.raw)
        app.sync.turnOff()
        XCTAssertEqual(app.sync.phase, .off)
        XCTAssertNil(keys.local, "the key is forgotten here")
        XCTAssertEqual(keys.shared?.seal.raw, seal.raw, "iCloud's copy stays for the others")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("journal/sync.sqlite").path))
        XCTAssertTrue(SettingsStore.shared.syncTurnedOff)
        XCTAssertTrue(app.sync.devices.isEmpty)
        XCTAssertTrue(app.sync.macs.isEmpty)
        // A relaunch: iCloud Keychain's key doesn't bring it back in by itself.
        let again = AppModel(world: World(name: "test", space: "home", spaces: [Space(id: "home", name: "Home", emoji: "🏠", tint: RGB(238, 233, 226))]))
        again.sync.attach(again, setup: setup(server))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotEqual(again.sync.phase, .on)
        XCTAssertFalse(again.sync.showsJoin, "and joining doesn't ask by itself either")
    }
}
