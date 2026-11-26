import YabStore
import Foundation
import Security
import SyncKit

struct ContextGrant: Codable, Equatable {
    let world: String
    let epoch: String
    let run: String
    var acquisition = true
}

enum ContextOrigin {
    case learned(ContextGrant)
    case manual(Set<String>)
    case unknown
    case usage
    case sync(String)
}

/// Values in this journal have the same protection as saved addresses.
protocol ContextJournalStorage {
    func read() -> Data?
    func write(_ data: Data) -> Bool
    var available: Bool { get }
}
extension ContextJournalStorage { var available: Bool { true } }

final class MemoryContextJournal: ContextJournalStorage {
    var data: Data?
    func read() -> Data? { data }
    func write(_ data: Data) -> Bool { self.data = data; return true }
}

private final class ProtectedContextJournal: ContextJournalStorage {
    private(set) var available = true
    private let service = Store.name + " · context provenance · " + (Bundle.main.bundleIdentifier ?? "Fast")
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "journal-v1", kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }
    func read() -> Data? {
        var ask = query; ask[kSecReturnData as String] = true; ask[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = Keychain.copySaved(ask as CFDictionary, &value)
        available = status == errSecSuccess || status == errSecItemNotFound
        guard status == errSecSuccess else { return nil }
        return value as? Data
    }
    func write(_ data: Data) -> Bool {
        let status = Keychain.save(query as CFDictionary, data: data, attributes: [
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ])
        if status == errSecSuccess { available = true }
        return status == errSecSuccess
    }
}

/// Only the validated task-owned fixture uses a file journal. Ordinary test
/// processes keep synthetic provenance in memory and never touch Keychain.
private final class FixtureContextJournal: ContextJournalStorage {
    let file: URL
    private(set) var available = true
    init(_ file: URL) { self.file = file }
    func read() -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do { return try Data(contentsOf: file) } catch { available = false; return nil }
    }
    func write(_ data: Data) -> Bool {
        do { try data.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path); return true }
        catch { return false }
    }
}

/// One serialization boundary for context admission, mutations and clearing.
/// Old callbacks retain their original epoch; they can never mint a new one.
final class ContextPrivacy: @unchecked Sendable {
    static let shared = ContextPrivacy()
    static let changed = Notification.Name("YabContextPrivacyChanged")
    struct Cell: Codable, Equatable {
        var value: String
        var source: String? = nil
        var edited = false
    }
    struct Ownership: Codable {
        var revision: String
        var learned: Bool
        var adopted = false
        var lineage: Bool
        var before: Cell?
        var after: Cell
        var applied: Bool
    }
    private struct Journal: Codable {
        var world: String?
        var fields: [String: Ownership] = [:]
        var created: Set<String> = []
        var tombstones: [String: Stamp] = [:]
        var syncConflicts: [String: Stamp] = [:]
        var syncImages: [String: String] = [:]
        var acceptedSync: [String: Set<String>] = [:]
    }
    struct LegacyItem: Identifiable {
        let id: String
        let label: String
        let value: Cell
        var restore: Cell?
    }
    enum Choice { case keep, remove, restore }
    struct ClearPlan {
        let epoch: String
        let legacy: [LegacyItem]
        let revisions: [String: String]
        var cells: [String: Cell] = [:]
        var summary = ClearSummary()
        var issues: [String] = []
    }
    struct ClearSummary {
        var removedFields = 0
        var restoredFields = 0
        var preservedFields = 0
        var removedAddresses = 0
    }
    struct ClearResult {
        var removed = 0
        var restored = 0
        var preserved = 0
        var unresolved: [String] = []
        var complete: Bool { unresolved.isEmpty }
    }

    struct Stores {
        var profile: () -> Profile = { Profile.load() }
        var saveProfile: (Profile) -> Bool = { Profile.save($0, origin: .usage) }
        var saveSyncedProfile: (Profile) -> Bool = { Profile.saveSynced($0) }
        var addresses: () -> [StreetAddress] = { Wallet.addresses() }
        var saveAddress: (StreetAddress) -> Bool = { Wallet.save($0, origin: .usage) }
        var removeAddress: (String) -> Bool = { id in Wallet.forget(address: id); return !Wallet.addresses().contains { $0.id == id } }
        var billingIDs: () -> Set<String> = { Wallet.billingAddressIDs() }
        var eraseNotes: () -> Bool = { Memory.eraseFiles() }
        var report: () -> KnowReport? = { KnowReport.load() }
    }

    private let lock = NSRecursiveLock()
    private let settings: UserDefaults
    private let stores: Stores
    private let storage: ContextJournalStorage
    let world: String
    private var journal: Journal
    private var journalAvailable: Bool
    private var runs: Set<String> = []
    private var generation: String
    private var syncJournal: SyncKit.Journal?
    func attachSync(_ journal: SyncKit.Journal) { transaction { syncJournal = journal } }
    var epoch: String { transaction { generation } }

    init(root: URL = Store.folder, settings: UserDefaults = Store.settings, storage: ContextJournalStorage? = nil, stores: Stores = Stores()) {
        self.settings = settings
        self.stores = stores
        if let storage { self.storage = storage }
        else if Store.testing, let home = AgentFixture.discovery()?.env["HOME"] {
            self.storage = FixtureContextJournal(URL(fileURLWithPath: home).appendingPathComponent("context-journal.json"))
        } else { self.storage = Store.testing ? MemoryContextJournal() : ProtectedContextJournal() }
        world = root.standardizedFileURL.resolvingSymlinksInPath().path + "|" + Store.name
        generation = settings.string(forKey: "context.epoch.v1") ?? UUID().uuidString
        settings.set(generation, forKey: "context.epoch.v1")
        let data = self.storage.read()
        let decoded = data.flatMap { try? JSONDecoder().decode(Journal.self, from: $0) }
        journalAvailable = self.storage.available && (data == nil || decoded != nil) && (decoded?.world == nil || decoded?.world == world)
        journal = decoded ?? Journal()
        journal.world = world
    }

    @discardableResult
    func transaction<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }

    func begin() -> ContextGrant {
        transaction {
            let run = UUID().uuidString; runs.insert(run)
            ConsentAudit.record("context.allow")
            return ContextGrant(world: world, epoch: generation, run: run)
        }
    }

    func revoke() {
        transaction { generation = UUID().uuidString; settings.set(generation, forKey: "context.epoch.v1"); runs = []; ConsentAudit.record("context.revoke") }
    }

    func derivation() -> ContextGrant {
        transaction { let id = UUID().uuidString; runs.insert(id); return ContextGrant(world: world, epoch: generation, run: id, acquisition: false) }
    }

    func valid(_ grant: ContextGrant?) -> Bool {
        transaction { grant.map { $0.world == world && $0.epoch == generation && runs.contains($0.run) } ?? false }
    }
    func current(_ epoch: String) -> Bool { transaction { epoch == generation } }

    private func persist() -> Bool {
        guard let data = try? JSONEncoder().encode(journal) else { return false }
        return storage.write(data)
    }
    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    private func syncImage(_ stamp: Stamp?, image: String?) -> String { image ?? "stamp:" + (stamp?.description ?? "unknown") }

    /// Prepare the protected intent before committing any learned values.
    /// A failed save restores the previous ledger. Pending crash intents are
    /// rolled back only when the exact post-image still matches at clear.
    func mutate(resource: String, before: [String: Cell], after: [String: Cell], origin: ContextOrigin,
                write: () -> Bool) -> Bool {
        transaction {
            switch origin {
            case .learned(let grant): guard valid(grant) else { ConsentAudit.record("context.late-write"); return false }
            case .sync(let epoch): guard current(epoch) else { return false }
            default: break
            }
            if case .usage = origin { return write() }
            guard journalAvailable else { return false }
            let previous = journal
            for (field, value) in after {
                let explicit: Bool
                if case .manual(let fields) = origin { explicit = fields.contains(field) } else { explicit = false }
                guard before[field] != value || explicit else { continue }
                let id = resource + ":" + field
                let old = journal.fields[id]
                let learned: Bool
                if case .learned = origin { learned = true } else { learned = false }
                let original = learned && old?.learned == true ? old?.before : before[field]
                journal.fields[id] = Ownership(revision: UUID().uuidString, learned: learned, adopted: explicit,
                    lineage: learned || old?.lineage == true, before: learned ? original : (explicit ? nil : old?.before), after: value, applied: false)
            }
            if before.isEmpty, case .learned = origin { journal.created.insert(resource) }
            guard persist() else { journal = previous; return false }
            guard write() else { journal = previous; _ = persist(); return false }
            for field in after.keys { let id = resource + ":" + field; if journal.fields[id] != nil { journal.fields[id]?.applied = true } }
            guard persist() else { return false } // Keep prepared intent for restart recovery.
            if case .learned = origin { ConsentAudit.record("context.write") }
            return true
        }
    }

    /// Clock order can reject a known old version. It cannot prove an
    /// unknown remote edit happened after a clear: that needs explicit review.
    func mayTakeSync(_ id: String, epoch: String, stamp: Stamp? = nil, image: String? = nil) -> Bool {
        transaction {
            guard current(epoch) else { return false }
            let fence = journal.tombstones[id] ?? (id.hasPrefix("memory/") ? journal.tombstones["memory"] : nil)
            guard let fence else { return true }
            let image = syncImage(stamp, image: image)
            if journal.acceptedSync[id]?.contains(image) == true { return true }
            if let stamp, stamp <= fence { return false }
            let unknown = stamp ?? Stamp(wall: 0, device: "unknown")
            if journal.syncConflicts[id] != unknown || journal.syncImages[id] != image {
                journal.syncConflicts[id] = unknown; journal.syncImages[id] = image; _ = persist(); notify()
            }
            return false
        }
    }
    var syncReview: [String: Stamp] { transaction { journal.syncConflicts } }
    var syncReviewImages: [String: String] { transaction { journal.syncImages } }
    /// Accept exactly the reviewed version; a different future version asks
    /// again. Rejecting keeps the local clear in force.
    func resolveSync(_ id: String, stamp: Stamp, image: String? = nil, accept: Bool, apply: (() -> Bool)? = nil) -> Bool {
        transaction {
            let image = syncImage(stamp, image: image)
            guard journal.syncConflicts[id] == stamp, journal.syncImages[id] == image else { return false }
            let previous = journal
            // Applying uses the captured, checked local image while the
            // version is still quarantined. No failed write/validation can
            // leave a durable admission that a later merge could borrow.
            if let apply, !apply() { notify(); return false }
            journal.syncConflicts[id] = nil
            journal.syncImages[id] = nil
            if accept { journal.acceptedSync[id, default: []].insert(image) }
            else { journal.tombstones[id] = max(journal.tombstones[id] ?? stamp, stamp) }
            guard persist() else {
                // A successful data writer may have added recoverable
                // ownership intent. Restore only this resolution's metadata.
                journal.acceptedSync[id] = previous.acceptedSync[id]
                journal.tombstones[id] = previous.tombstones[id]
                journal.syncConflicts[id] = stamp
                journal.syncImages[id] = image
                notify()
                return false
            }
            notify()
            return true
        }
    }

    func syncProfileCell(_ key: String) -> Cell? { transaction { Profile.cells(stores.profile())[key] } }
    func syncAddress(_ id: String) -> StreetAddress? { transaction { stores.addresses().first { $0.id == id } } }

    func applyReviewedProfile(_ key: String, value: Cell, expected: Cell?, epoch: String) -> Bool {
        transaction {
            guard current(epoch), Profile.keys.contains(key) else { return false }
            var next = stores.profile()
            let before = Profile.cells(next)
            guard before[key] == expected else { return false }
            next[key] = value.value; next.sources[key] = value.source
            if value.edited { next.edited.insert(key) } else { next.edited.remove(key) }
            return mutate(resource: "profile", before: before, after: Profile.cells(next), origin: .sync(epoch)) { stores.saveProfile(next) }
        }
    }

    func applyReviewedAddress(_ incoming: StreetAddress, field: String?, expected: StreetAddress?, epoch: String,
                              write: ((StreetAddress) -> Bool)? = nil) -> Bool {
        transaction {
            guard current(epoch) else { return false }
            let current = syncAddress(incoming.id)
            var next = incoming
            if let field {
                guard Wallet.contextKeys.contains(field), current?.contextValue(field) == expected?.contextValue(field), var changed = current else { return false }
                changed.setContext(field, incoming.contextValue(field)); next = changed
            } else if current != expected { return false }
            return mutate(resource: "address/" + next.id, before: current.map(Wallet.contextCells) ?? [:],
                after: Wallet.contextCells(next), origin: .sync(epoch)) { (write ?? stores.saveAddress)(next) }
        }
    }

    func mergeSyncedProfile(_ incoming: Profile, epoch: String, stamp: Stamp? = nil, image: String? = nil) -> Bool {
        transaction {
            guard current(epoch) else { return false }
            var next = incoming
            let current = stores.profile()
            for key in Profile.keys where !mayTakeSync("profile:" + key, epoch: epoch, stamp: stamp, image: image) {
                next[key] = current[key]; next.sources[key] = current.sources[key]
                if current.edited.contains(key) { next.edited.insert(key) } else { next.edited.remove(key) }
            }
            // This Mac's own profile come back: nothing to write. One that
            // keeps some of this Mac's values is a change made here.
            if next == current { return true }
            return mutate(resource: "profile", before: Profile.cells(current), after: Profile.cells(next), origin: .sync(epoch)) {
                next == incoming ? stores.saveSyncedProfile(next) : stores.saveProfile(next)
            }
        }
    }

    func mergeSyncedAddress(_ incoming: StreetAddress, epoch: String, stamp: Stamp? = nil, image: String? = nil, write: ((StreetAddress) -> Bool)? = nil) -> Bool {
        transaction {
            guard mayTakeSync("address/" + incoming.id, epoch: epoch, stamp: stamp, image: image) else { return false }
            var next = incoming
            let current = stores.addresses().first { $0.id == incoming.id }
            for key in Wallet.contextKeys where !mayTakeSync("address/" + incoming.id + ":" + key, epoch: epoch, stamp: stamp, image: image) {
                next.setContext(key, current?.contextValue(key) ?? "")
            }
            return mutate(resource: "address/" + incoming.id, before: current.map(Wallet.contextCells) ?? [:], after: Wallet.contextCells(next), origin: .sync(epoch)) { (write ?? stores.saveAddress)(next) }
        }
    }

    func profilePatch(_ given: [String: String], source: String, grant: ContextGrant) -> (changed: [String], kept: [String])? {
        transaction {
            guard valid(grant) else { return nil }
            var profile = stores.profile()
            let result = profile.merge(given, source: source)
            guard result.changed.isEmpty || mutate(resource: "profile", before: Profile.cells(stores.profile()), after: Profile.cells(profile), origin: .learned(grant), write: { stores.saveProfile(profile) }) else { return nil }
            return result
        }
    }

    func saveAddress(_ incoming: StreetAddress, origin: ContextOrigin, write: ((StreetAddress) -> Bool)? = nil) -> Bool {
        transaction {
            let old = stores.addresses().first { $0.id == incoming.id }
            var next = incoming.tidied()
            if let old {
                if case .manual(let fields) = origin {
                    next = old
                    for key in fields { next.setContext(key, incoming.tidied().contextValue(key)) }
                } else if case .learned = origin {
                    for key in Wallet.contextKeys where journal.fields["address/" + incoming.id + ":" + key]?.adopted == true {
                        next.setContext(key, old.contextValue(key))
                    }
                }
            }
            return mutate(resource: "address/" + incoming.id, before: old.map(Wallet.contextCells) ?? [:], after: Wallet.contextCells(next), origin: origin) {
                (write ?? stores.saveAddress)(next)
            }
        }
    }

    func preview() -> ClearPlan {
        transaction {
            var legacy: [LegacyItem] = []
            let profile = stores.profile()
            for key in Profile.keys {
                let id = "profile:" + key
                let ownership = journal.fields[id]
                let unknownLineage = ownership?.lineage == true && ownership?.learned != true && ownership?.adopted != true
                guard unknownLineage || !profile[key].isEmpty else { continue }
                if journal.fields[id]?.learned != true && journal.fields[id]?.adopted != true {
                    legacy.append(LegacyItem(id: id, label: "Profile · " + key, value: Profile.cells(profile)[key]!, restore: journal.fields[id]?.before))
                }
            }
            for address in stores.addresses() {
                let resource = "address/" + address.id
                for (key, value) in Wallet.contextCells(address) {
                    let ownership = journal.fields[resource + ":" + key]
                    let unknownLineage = ownership?.lineage == true && ownership?.learned != true && ownership?.adopted != true
                    guard unknownLineage || !value.value.isEmpty else { continue }
                    if ownership?.learned == true || ownership?.adopted == true { continue }
                    legacy.append(LegacyItem(id: resource + ":" + key, label: address.title + " · " + key, value: value, restore: ownership?.before))
                }
            }
            var current = Dictionary(uniqueKeysWithValues: Profile.cells(profile).map { ("profile:" + $0.key, $0.value) })
            for address in stores.addresses() {
                for (key, cell) in Wallet.contextCells(address) { current["address/" + address.id + ":" + key] = cell }
            }
            for (id, ownership) in journal.fields where ownership.learned {
                guard let cell = current[id], cell != ownership.after, cell != (ownership.before ?? Cell(value: "")) else { continue }
                legacy.append(LegacyItem(id: id, label: id, value: cell, restore: ownership.before))
            }
            if let report = stores.report() {
                for doubt in report.doubts {
                    guard let was = doubt.was else { continue }
                    if let previous = was.value, let index = legacy.firstIndex(where: { $0.id == "profile:" + doubt.about }) {
                        legacy[index].restore = Cell(value: previous, source: was.source, edited: was.edited)
                    }
                    for (address, previous) in was.addresses {
                        if let index = legacy.firstIndex(where: { $0.id == "address/" + address + ":" + doubt.about }) { legacy[index].restore = Cell(value: previous) }
                    }
                }
            }
            var summary = ClearSummary()
            for (id, ownership) in journal.fields {
                if ownership.adopted { summary.preservedFields += 1 }
                guard ownership.learned, !legacy.contains(where: { $0.id == id }), current[id] == ownership.after else { continue }
                if ownership.before?.value.isEmpty ?? true { summary.removedFields += 1 } else { summary.restoredFields += 1 }
            }
            var issues: [String] = journalAvailable ? [] : ["Context provenance is unavailable. Unlock this Mac and try again."]
            let billing = stores.billingIDs()
            for resource in journal.created where resource.hasPrefix("address/") {
                guard !journal.fields.contains(where: { $0.key.hasPrefix(resource + ":") && $0.value.adopted }) else { continue }
                let id = String(resource.dropFirst(8))
                if billing.contains(id) { issues.append("An address is used for billing. Keep it in Wallet or choose another billing address, then review again.") }
                else { summary.removedAddresses += 1 }
            }
            return ClearPlan(epoch: generation, legacy: legacy.sorted { $0.id < $1.id }, revisions: journal.fields.mapValues(\.revision),
                cells: current, summary: summary, issues: issues)
        }
    }

    /// Refuses unresolved historical attribution, rather than calling it erased.
    func clear(_ plan: ClearPlan, choices: [String: Choice]) -> ClearResult {
        transaction {
            var result = ClearResult()
            guard journalAvailable else { result.unresolved = ["Context provenance is unavailable. Unlock this Mac and try again."]; return result }
            result.preserved = journal.fields.values.filter { $0.lineage && !$0.learned }.count
            guard plan.epoch == generation else { result.unresolved = ["The stored data changed. Review it again."]; return result }
            guard plan.revisions == journal.fields.mapValues(\.revision) else {
                result.unresolved = ["The stored data changed. Review it again."]; return result
            }
            if !plan.cells.isEmpty {
                var current = Dictionary(uniqueKeysWithValues: Profile.cells(stores.profile()).map { ("profile:" + $0.key, $0.value) })
                for address in stores.addresses() {
                    for (key, cell) in Wallet.contextCells(address) { current["address/" + address.id + ":" + key] = cell }
                }
                guard current == plan.cells else { result.unresolved = ["The stored data changed. Review it again."]; return result }
            }
            result.unresolved = plan.legacy.filter { choices[$0.id] == nil }.map(\.id)
            result.unresolved += journal.syncConflicts.keys.map { "sync:" + $0 }
            guard result.unresolved.isEmpty else { return result }
            generation = UUID().uuidString; settings.set(generation, forKey: "context.epoch.v1"); runs = []
            ConsentAudit.record("context.revoke")
            let previous = journal
            // A decision to restore one version belongs to the context
            // being cleared. It cannot authorize replay after this clear.
            journal.acceptedSync = [:]
            let cutoff = syncJournal?.tick() ?? Stamp(wall: 0, device: "local-context")
            for id in Array(journal.fields.filter { $0.value.learned }.keys) + plan.legacy.filter({ choices[$0.id] != .keep }).map(\.id) + ["memory", "know.json"] { journal.tombstones[id] = cutoff }
            guard persist() else { journal = previous; result.unresolved = ["Could not protect the clear operation. Try again."]; return result }
            let recovery = journal
            defer { if !result.complete { journal = recovery; _ = persist() } }
            var profile = stores.profile()
            var addresses = Dictionary(stores.addresses().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let originalProfile = profile, originalAddresses = addresses
            for (id, ownership) in journal.fields where ownership.learned {
                if plan.legacy.contains(where: { $0.id == id }) { continue }
                guard plan.revisions[id] == ownership.revision else { result.unresolved.append(id); continue }
                if id.hasPrefix("profile:") {
                    let key = String(id.dropFirst(8))
                    let old = ownership.before ?? Cell(value: "")
                    if Profile.cells(profile)[key] == old { continue } // Recovery after a partial clear.
                    guard Profile.cells(profile)[key] == ownership.after else { result.unresolved.append(id); continue }
                    profile[key] = old.value; profile.sources[key] = old.source
                    if old.edited { profile.edited.insert(key) } else { profile.edited.remove(key) }
                    if old.value.isEmpty { result.removed += 1 } else { result.restored += 1 }
                } else if let cut = id.lastIndex(of: ":"), id.hasPrefix("address/") {
                    let addressID = String(id[id.index(id.startIndex, offsetBy: 8)..<cut]), key = String(id[id.index(after: cut)...])
                    guard var address = addresses[addressID] else { continue }
                    if Wallet.contextCells(address)[key] == (ownership.before ?? Cell(value: "")) { continue }
                    guard Wallet.contextCells(address)[key] == ownership.after else { result.unresolved.append(id); continue }
                    address.setContext(key, ownership.before?.value ?? "")
                    addresses[addressID] = address
                    result.restored += 1
                }
                journal.tombstones[id] = cutoff
            }
            for item in plan.legacy {
                let current: Cell?
                if item.id.hasPrefix("profile:") { current = Profile.cells(profile)[String(item.id.dropFirst(8))] }
                else if let cut = item.id.lastIndex(of: ":") {
                    let addressID = String(item.id[item.id.index(item.id.startIndex, offsetBy: 8)..<cut])
                    current = addresses[addressID].map(Wallet.contextCells)?[String(item.id[item.id.index(after: cut)...])]
                } else { current = nil }
                guard current == item.value else { result.unresolved.append(item.id); continue }
                switch choices[item.id] {
                case .keep:
                    result.preserved += 1
                    journal.fields[item.id] = Ownership(revision: UUID().uuidString, learned: false, adopted: true,
                        lineage: true, before: nil, after: item.value, applied: true)
                case .remove, .restore:
                    let value = choices[item.id] == .restore ? item.restore : Cell(value: "")
                    guard let value else { result.unresolved.append(item.id); continue }
                    if item.id.hasPrefix("profile:") {
                        let key = String(item.id.dropFirst(8))
                        guard Profile.cells(profile)[key] == item.value else { result.unresolved.append(item.id); continue }
                        profile[key] = value.value; profile.sources[key] = value.source; profile.edited.insert(key)
                    } else if let cut = item.id.lastIndex(of: ":") {
                        let addressID = String(item.id[item.id.index(item.id.startIndex, offsetBy: 8)..<cut]), key = String(item.id[item.id.index(after: cut)...])
                        guard var address = addresses[addressID], Wallet.contextCells(address)[key] == item.value else { result.unresolved.append(item.id); continue }
                        address.setContext(key, value.value); addresses[addressID] = address
                    }
                    journal.tombstones[item.id] = cutoff; result.removed += 1
                    journal.fields[item.id] = Ownership(revision: UUID().uuidString, learned: false, adopted: true,
                        lineage: true, before: nil, after: value, applied: true)
                case nil: break
                }
            }
            // Commit original data restoration before discarding protected before-images.
            if profile != originalProfile, !stores.saveProfile(profile) { result.unresolved.append("profile") }
            for (id, address) in addresses {
                let resource = "address/" + id
                let adopted = journal.fields.contains { $0.key.hasPrefix(resource + ":") && $0.value.adopted }
                if journal.created.contains(resource), !adopted {
                    if result.unresolved.contains(where: { $0.hasPrefix(resource + ":") }) { continue }
                    if stores.billingIDs().contains(id) { result.unresolved.append(resource + ":billing-reference"); continue }
                    if !stores.removeAddress(id) { result.unresolved.append(resource); continue }
                    journal.tombstones[resource] = cutoff
                } else if address != originalAddresses[id], !stores.saveAddress(address) { result.unresolved.append(resource) }
            }
            if result.complete, let syncJournal {
                do {
                    let records = syncJournal.all(SyncShapes.memory)
                    guard records.allSatisfy({ ($0.latest ?? cutoff) <= cutoff }) else {
                        result.unresolved.append("A synchronized context version needs review."); return result
                    }
                    for record in records { try syncJournal.remove(record.key) }
                    try syncJournal.remove(.init(collection: SyncShapes.file, id: "know.json"))
                } catch { result.unresolved.append("Could not publish the context removal to Sync."); return result }
            }
            if result.complete {
                guard stores.eraseNotes() else { result.unresolved.append("memory"); return result }
                journal.fields = journal.fields.filter { !$0.value.learned }
                journal.created = []
                journal.tombstones["memory"] = cutoff; journal.tombstones["know.json"] = cutoff
                guard persist() else { result.unresolved.append("provenance"); return result }
                settings.removeObject(forKey: "memory.tasks"); settings.removeObject(forKey: "memory.dreamt")
                settings.set(true, forKey: "profile.fromMemory")
                notify()
            }
            return result
        }
    }
}

@MainActor
enum ContextConsent {
    static let refusal = "Choose Allow in Yab's context permission before starting this read."
    static var disclosure: String {
        "Reads your browsing history and the sites you're signed in to. Page text goes to \(AgentSetupModel.name(Agents.preferred)), the AI you connected. About ten minutes. Nothing is sent or posted to those sites. Inspect or clear what it keeps in AI › Memory."
    }
    static func webReadURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil,
              url.user == nil, url.password == nil else { return false }
        return true
    }
    /// Know Me runs only with AI in Yab On (AIUse): it is background work.
    static func request() {
        guard AgentSetupModel.shared.anyConnected, AIUse.allows(.background) else { return }
        Task { @MainActor in
            let question = Question(title: "Give your agents context about you", detail: disclosure, glyph: "hand.raised", yes: "Allow", no: "Not Now")
            guard await Questions.shared.ask(question) else { return }
            _ = allow()
        }
    }
    @discardableResult static func allow() -> Agents.Session? {
        guard AgentSetupModel.shared.anyConnected, AIUse.allows(.background) else { return nil }
        if let current = Agents.shared.knowingRun, ContextPrivacy.shared.valid(current.contextGrant) { return current }
        let grant = ContextPrivacy.shared.begin()
        return Agents.shared.setUpMemory(grant: grant)
    }

    /// Verbs that only report a task's own state and result to whoever
    /// started it (`yab "…"`, `yab session resume`). They read no page,
    /// history or memory, so a task that has ended, and so lost its
    /// admission, still answers them with its result.
    static let watching: Set<String> = ["agent-wait"]

    nonisolated static let unavailable = "This task is no longer available."

    /// Pure metadata check before any tab lookup, cookies, JS or remote reader.
    static func preflight(_ request: [String: Any], lookup: ((String) -> Agents.Session?)? = nil) -> String? {
        guard let id = request["session"] as? String else { return nil }
        let known: Agents.Session?
        if let lookup { known = lookup(id) } else { known = Agents.shared.session(id) }
        guard let session = known else { return unavailable }
        if watching.contains(request["do"] as? String ?? ""), !session.knowing, !session.memoryOnly { return nil }
        guard (session.state.live || session.remembering), session.admission.valid else { return "This task's permission expired. Start a new task." }
        if session.memoryEpoch != ContextPrivacy.shared.epoch { return "This context was cleared. Start a new task." }
        let verb = request["do"] as? String ?? ""
        if session.memoryOnly {
            let memory: Set<String> = ["agent-caps", "agent-memory-read", "agent-memory-search", "agent-memory-write", "agent-status", "agent-wait", "agent-name"]
            guard memory.contains(verb) else { return "This memory pass cannot read sites or browsing history." }
        }
        guard session.knowing else { return nil }
        guard session.state.live, ContextPrivacy.shared.valid(session.contextGrant) else { return refusal }
        if let raw = request["url"] as? String, !webReadURL(raw) {
            return "This context read only opens http or https pages. Local files, scripts and internal pages are unavailable."
        }
        let reads: Set<String> = ["agent-caps", "open", "go", "agent-go", "agent-tabs", "agent-browse", "close", "tabs", "spaces", "snapshot", "text", "wait", "settle", "name", "agent-name",
            "agent-history", "agent-read", "agent-fetch", "agent-memory-read", "agent-memory-search", "agent-memory-write", "agent-profile", "agent-keep-address", "agent-know-report", "agent-status", "agent-wait"]
        if session.contextGrant?.acquisition == false {
            let derived: Set<String> = ["agent-caps", "agent-memory-read", "agent-memory-search", "agent-profile", "agent-keep-address", "agent-status", "agent-wait", "agent-name"]
            guard derived.contains(verb) else { return "Profile from memory can only read existing memory and update its derived profile and addresses." }
        }
        guard reads.contains(verb), (request["method"] as? String ?? "GET").uppercased() == "GET" else {
            return "This context read cannot post, send, sign in, click, type, run page scripts or change sites."
        }
        ConsentAudit.record((verb == "agent-caps" ? "context.metadata." : "context.tool.") + verb)
        return nil
    }
}
