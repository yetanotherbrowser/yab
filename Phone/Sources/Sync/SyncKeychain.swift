import Foundation
import Security
#if canImport(SyncKit)
import SyncKit
#endif

// Where the sync key lives on the iPhone (Phone/Reference/digest/sync-ios.md,
// "The key"). The Mac keeps two copies (SyncKey.swift): its own, and one in
// iCloud Keychain, a synchronizable generic password, service "Yab · sync",
// account "key", in the Mac app's default access group,
// `<TeamID>.dev.serafim.fast` (its application identifier: the Mac lists no
// keychain-access-groups of its own). iCloud Keychain brings that copy to an
// iPhone on the same Apple ID, and this app reads it when that group is in
// its `keychain-access-groups`; so is `<TeamID>.dev.serafim.fast.sync`, the
// shared group of PLAN-iphone.md decision 5, should the Mac move there. A
// key that came by a code or the Recovery Key is kept the same two ways, the
// shared copy in the Mac's group, where a Mac turning sync on looks.
//
// Test worlds keep everything in files of their folder: no keychain item is
// left behind by a run, and no other world's is found.

public nonisolated struct SyncKeychain: Sendable {
    /// The Mac's service name: `"\(Store.name) · sync"` for the shipping Yab.
    public static let macService = "Yab \u{B7} sync"

    public enum Storage: Sendable {
        case keychain
        /// A folder of files instead, for tests and worlds. A file named
        /// `key-shared` there plays iCloud Keychain.
        case files(URL)
    }

    public var storage: Storage
    /// The service the key is filed under, the Mac's.
    public var service: String
    /// Where a Mac's copy may be, in the order tried. Each must be in the
    /// app's `keychain-access-groups`.
    public var sharedGroups: [String]
    /// Where this iPhone puts the copy a Mac finds; nil: the app's default.
    public var writeGroup: String?
    /// This iPhone's own items (the key it runs with, its token, its id):
    /// never synced, readable after the first unlock, for background wakes.
    public var ownGroup: String?

    public init(storage: Storage = .keychain, service: String = SyncKeychain.macService, sharedGroups: [String], writeGroup: String?, ownGroup: String? = nil) {
        self.storage = storage; self.service = service; self.sharedGroups = sharedGroups; self.writeGroup = writeGroup; self.ownGroup = ownGroup
    }

    /// The app's: the groups from Info.plist's `YabSyncKeychainGroups`
    /// (strings like "$(AppIdentifierPrefix)dev.serafim.fast", expanded at
    /// build), else the team's two from the prefix the keychain reports: the
    /// Mac's own group first, the one written to, then decision 5's.
    public static func standard() -> SyncKeychain {
        // An unsigned build leaves the prefix out ("dev.serafim.fast"):
        // only a group with the team in front is one the app can have.
        var groups = (Bundle.main.object(forInfoDictionaryKey: "YabSyncKeychainGroups") as? [String] ?? [])
            .filter { !$0.contains("$(") && team(of: $0) != nil }
        let own = appGroup()
        if groups.isEmpty, let own, let team = team(of: own) {
            groups = ["\(team).dev.serafim.fast", "\(team).dev.serafim.fast.sync"]
        }
        return SyncKeychain(sharedGroups: groups, writeGroup: groups.first, ownGroup: own)
    }

    public static func testing(folder: URL) -> SyncKeychain {
        SyncKeychain(storage: .files(folder), sharedGroups: [], writeGroup: nil)
    }

    // MARK: The key

    /// This iPhone's copy: present means this iPhone is in sync.
    public var local: Seal? { read("key", synced: false, group: ownGroup).flatMap(Seal.init(raw:)) }

    /// A copy iCloud Keychain brought from a Mac (or another iPhone): joining
    /// with it takes no step at all. With the group it was found in.
    public var shared: (seal: Seal, group: String?)? {
        if case .files = storage { return read("key", synced: true, group: nil).flatMap(Seal.init(raw:)).map { ($0, nil) } }
        for group in sharedGroups {
            if let seal = read("key", synced: true, group: group).flatMap(Seal.init(raw:)) { return (seal, group) }
        }
        // Any group the app may read, the Mac's default among them.
        return read("key", synced: true, group: nil).flatMap(Seal.init(raw:)).map { ($0, nil) }
    }

    public enum Keeping: Sendable, Equatable {
        case localFailure
        case localOnly
        case localAndShared
    }

    public enum Failure: Error, LocalizedError, Sendable {
        case deviceIdentity
        public var errorDescription: String? {
            "This \(DeviceWord.name) could not save its Sync identity. Unlock it and try again."
        }
    }

    /// Joining requires a durable local key. Sharing is a separate result:
    /// failure there must not discard this iPhone's successfully saved key.
    @discardableResult
    public func keep(_ seal: Seal, share: Bool = true) -> Keeping {
        guard write(seal.raw, "key", synced: false, group: ownGroup),
              read("key", synced: false, group: ownGroup) == seal.raw else { return .localFailure }
        guard share else { return .localOnly }
        guard write(seal.raw, "key", synced: true, group: writeGroup),
              read("key", synced: true, group: writeGroup) == seal.raw else { return .localOnly }
        return .localAndShared
    }

    /// Off on this iPhone: the key, the token and the device id go (a device
    /// removed from the account comes back under a new id, the old one being
    /// refused for good). The iCloud copy stays for the others unless
    /// `everywhere`, when the account is gone.
    public func forget(everywhere: Bool = false, keepingLocalKey: Bool = false) {
        for name in keepingLocalKey ? ["token", "device"] : ["key", "token", "device"] {
            delete(name, synced: false, group: ownGroup)
        }
        guard everywhere else { return }
        if case .files = storage { delete("key", synced: true, group: nil); return }
        for group in Set(sharedGroups + [writeGroup].compactMap { $0 }) { delete("key", synced: true, group: group) }
    }

    /// The device token the server gave, kept between launches.
    public var token: String? {
        get { read("token", synced: false, group: ownGroup).flatMap { String(data: $0, encoding: .utf8) } }
        nonmutating set {
            if let newValue { write(Data(newValue.utf8), "token", synced: false, group: ownGroup) } else { delete("token", synced: false, group: ownGroup) }
        }
    }

    /// This iPhone's id among the devices: made once, lowercased like the
    /// Mac's, kept on this iPhone only.
    public var deviceID: String { (try? savedDeviceID()) ?? "" }

    /// Never start a foreground or background line with an identity that
    /// changes after relaunch because the keychain refused its first write.
    public func savedDeviceID() throws -> String {
        if let kept = read("device", synced: false, group: ownGroup).flatMap({ String(data: $0, encoding: .utf8) }),
           !kept.isEmpty { return kept }
        let id = UUID().uuidString.lowercased()
        let data = Data(id.utf8)
        guard write(data, "device", synced: false, group: ownGroup),
              read("device", synced: false, group: ownGroup) == data else { throw Failure.deviceIdentity }
        return id
    }

    // MARK: Groups

    /// The app's own default access group, `<TeamID>.<bundle id>`: what an
    /// item made without a group gets, read back from one.
    public static func appGroup() -> String? {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "yab.sync.group-probe",
            kSecAttrAccount as String: "probe",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var query = probe
        query[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound {
            status = SecItemAdd(probe as CFDictionary, nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else { return nil }
            status = SecItemCopyMatching(query as CFDictionary, &out)
        }
        guard status == errSecSuccess, let attributes = out as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessGroup as String] as? String
    }

    /// The team id at the front of a group: ten capitals and digits.
    public static func team(of group: String) -> String? {
        guard let first = group.split(separator: ".").first, first.count == 10,
              first.allSatisfy({ $0.isUppercase || $0.isNumber }) else { return nil }
        return String(first)
    }

    // MARK: Keychain

    private func query(_ name: String, synced: Bool, group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecAttrSynchronizable as String: synced ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
            // The iPhone has no other keychain; on a Mac (the tests) this
            // is the one iCloud Keychain lives in.
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    private func file(_ name: String, synced: Bool, in folder: URL) -> URL {
        folder.appendingPathComponent("\(name)\(synced ? "-shared" : "")")
    }

    private func read(_ name: String, synced: Bool, group: String?) -> Data? {
        if case .files(let folder) = storage { return try? Data(contentsOf: file(name, synced: synced, in: folder)) }
        var query = query(name, synced: synced, group: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    private func write(_ data: Data, _ name: String, synced: Bool, group: String?) -> Bool {
        if case .files(let folder) = storage {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return (try? data.write(to: file(name, synced: synced, in: folder), options: .atomic)) != nil
        }
        let base = query(name, synced: synced, group: group)
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Yab Sync"
            // A synced item can't be this device's only; the Mac's is
            // readable after the first unlock too.
            add[kSecAttrAccessible as String] = synced ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    private func delete(_ name: String, synced: Bool, group: String?) {
        if case .files(let folder) = storage { try? FileManager.default.removeItem(at: file(name, synced: synced, in: folder)); return }
        SecItemDelete(query(name, synced: synced, group: group) as CFDictionary)
    }
}
