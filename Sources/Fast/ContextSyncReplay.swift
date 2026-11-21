import Foundation
import SyncKit
import CryptoKit

/// Reviews a version already in Yab's Sync journal. No remote fetch, card
/// secret, credential or provider operation is needed to inspect or apply it.
final class ContextSyncReplay {
    enum Target: Equatable {
        case profile(String)
        case address(String, String?)
        case memory(String)
        case report
    }
    struct Item: Identifiable {
        let id: String
        let stamp: Stamp
        let label: String
        let text: String
        let epoch: String
        let target: Target?
        let record: SyncKit.Record?
        var profile: ContextPrivacy.Cell?
        var address: StreetAddress?
        var localProfile: ContextPrivacy.Cell?
        var localAddress: StreetAddress?
        var localFile: Data?
        var localExisted = false
        var image = ""
        var readable = true
        var canUse: Bool { target != nil && record != nil && readable }
        func sameReview(as other: Item) -> Bool {
            id == other.id && image == other.image && stamp == other.stamp && epoch == other.epoch && record == other.record
                && localProfile == other.localProfile && localAddress == other.localAddress
                && localExisted == other.localExisted && localFile == other.localFile && readable == other.readable
        }
    }
    let privacy: ContextPrivacy
    let journal: SyncKit.Journal?
    let root: URL
    let decodeAddress: (SyncKit.Record) -> StreetAddress?
    let writeAddress: ((StreetAddress, SyncKit.Record) -> Bool)?

    init(privacy: ContextPrivacy, journal: SyncKit.Journal?, root: URL,
         decodeAddress: @escaping (SyncKit.Record) -> StreetAddress? = { _ in nil },
         writeAddress: ((StreetAddress, SyncKit.Record) -> Bool)? = nil) {
        self.privacy = privacy; self.journal = journal; self.root = root
        self.decodeAddress = decodeAddress; self.writeAddress = writeAddress
    }

    func items() -> [Item] {
        privacy.transaction {
            privacy.syncReview.sorted { $0.key < $1.key }.map { id, originalStamp in
                var stamp = originalStamp
                var item = Item(id: id, stamp: stamp, label: id, text: "This version is unavailable. Keep the local clear, or retry after Sync is available.",
                    epoch: privacy.epoch, target: nil, record: nil)
                item.image = privacy.syncReviewImages[id] ?? ""
                guard let target = Self.target(id), let key = Self.key(target),
                      let record = journal?.record(key), let currentStamp = record.latest else { return item }
                let image = Self.image(record)
                if currentStamp != stamp || privacy.syncReviewImages[id] != image {
                    _ = privacy.mayTakeSync(id, epoch: privacy.epoch, stamp: currentStamp, image: image)
                    guard privacy.syncReview[id] == currentStamp, privacy.syncReviewImages[id] == image else { return item }
                    stamp = currentStamp
                }
                item = Item(id: id, stamp: stamp, label: Self.label(target), text: "Removed on the other device", epoch: privacy.epoch, target: target, record: record)
                item.image = image
                switch target {
                case .profile(let field):
                    item.localProfile = privacy.syncProfileCell(field)
                    guard record.alive(), let incoming = SyncShapes.profile(from: record), let value = Profile.cells(incoming)[field] else { item.readable = false; return item }
                    item.profile = value
                    item = replacingText(item, value.value.isEmpty ? "Empty value" : value.value)
                case .address(let id, let field):
                    item.localAddress = privacy.syncAddress(id)
                    guard record.alive(), let incoming = decodeAddress(record), incoming.id == id else { item.readable = false; return item }
                    item.address = incoming
                    let text = field.map(incoming.contextValue) ?? Wallet.contextKeys.map { $0 + ": " + incoming.contextValue($0) }.joined(separator: "\n")
                    item = replacingText(item, text.isEmpty ? "Empty value" : text)
                case .memory, .report:
                    guard let file = file(target, record: record) else { item.readable = false; return item }
                    item.localFile = try? Data(contentsOf: file)
                    item.localExisted = FileManager.default.fileExists(atPath: file.path)
                    item.readable = item.localFile != nil || !item.localExisted
                    if record.alive() {
                        if case .memory = target, let text = record["text"]?.string { item = replacingText(item, text) }
                        else if case .memory = target { item.readable = false }
                        else if let data = Self.json(record) { item = replacingText(item, String(decoding: data, as: UTF8.self)) }
                        else { item.readable = false }
                    }
                }
                return item
            }
        }
    }

    /// The captured version and local before-image must both still match.
    /// A successful acceptance applies it now; it is never left waiting for
    /// an unrelated future Sync notification to replay an unchanged record.
    func resolve(_ item: Item, use: Bool) -> Bool {
        privacy.transaction {
            guard privacy.current(item.epoch) else { return false }
            if let record = item.record, let current = journal?.record(record.key), current != record {
                _ = privacy.mayTakeSync(item.id, epoch: item.epoch, stamp: current.latest, image: Self.image(current))
                return false
            }
            if use {
                guard item.canUse, let record = item.record, journal?.record(record.key) == record else { return false }
            }
            return privacy.resolveSync(item.id, stamp: item.stamp, image: item.image.isEmpty ? nil : item.image, accept: use) {
                !use || self.apply(item)
            }
        }
    }

    private func apply(_ item: Item) -> Bool {
        guard let target = item.target, let record = item.record, privacy.current(item.epoch) else { return false }
        switch target {
        case .profile(let field):
            guard let value = item.profile else { return false }
            return privacy.applyReviewedProfile(field, value: value, expected: item.localProfile, epoch: item.epoch)
        case .address(_, let field):
            guard let address = item.address else { return false }
            return privacy.applyReviewedAddress(address, field: field, expected: item.localAddress, epoch: item.epoch,
                write: writeAddress.map { write in { write($0, record) } })
        case .memory(let id):
            let path = record["day"]?.string ?? id
            guard let file = file(target, record: record), matches(item, file: file) else { return false }
            var data: Data?
            if record["day"]?.string != nil, let text = record["text"]?.string {
                var entries = item.localFile.map { SyncShapes.entries(String(decoding: $0, as: UTF8.self)) } ?? []
                entries.removeAll { $0 == text }
                if record.alive() { entries.append(text) }
                let day = (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
                data = entries.isEmpty ? nil : Data(("# " + day + "\n\n" + entries.sorted().joined(separator: "\n\n") + "\n").utf8)
            } else if record.alive(), let text = record["text"]?.string { data = Data(text.utf8) }
            return write(data, to: file)
        case .report:
            guard let file = file(target), matches(item, file: file) else { return false }
            return write(record.alive() ? Self.json(record) : nil, to: file)
        }
    }

    private func file(_ target: Target, record: SyncKit.Record? = nil) -> URL? {
        let relative: String
        switch target {
        case .memory(let id):
            let path = record?["day"]?.string ?? id
            guard path.hasSuffix(".md"), !path.contains(".."), !path.hasPrefix("/") else { return nil }
            relative = "memory/" + path
        case .report: relative = "know.json"
        default: return nil
        }
        let file = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        let confined = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return file.path.hasPrefix(confined) ? file : nil
    }
    private func write(_ data: Data?, to file: URL) -> Bool {
        do {
            if let data {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return true
        } catch { return false }
    }
    private func matches(_ item: Item, file: URL) -> Bool {
        let exists = FileManager.default.fileExists(atPath: file.path)
        guard exists == item.localExisted else { return false }
        guard exists else { return item.localFile == nil }
        guard let data = try? Data(contentsOf: file) else { return false }
        return data == item.localFile
    }
    private func replacingText(_ item: Item, _ text: String) -> Item {
        var next = Item(id: item.id, stamp: item.stamp, label: item.label, text: text, epoch: item.epoch, target: item.target, record: item.record)
        next.profile = item.profile; next.address = item.address; next.localProfile = item.localProfile; next.localAddress = item.localAddress
        next.localFile = item.localFile; next.localExisted = item.localExisted; next.readable = item.readable; next.image = item.image
        return next
    }
    private static func target(_ id: String) -> Target? {
        if id.hasPrefix("profile:"), Profile.keys.contains(String(id.dropFirst(8))) { return .profile(String(id.dropFirst(8))) }
        if id.hasPrefix("address/") {
            let rest = String(id.dropFirst(8))
            if let cut = rest.lastIndex(of: ":") {
                let field = String(rest[rest.index(after: cut)...])
                guard Wallet.contextKeys.contains(field) else { return nil }
                return .address(String(rest[..<cut]), field)
            }
            return .address(rest, nil)
        }
        if id == "know.json" { return .report }
        if id.hasPrefix("memory/") { return .memory(String(id.dropFirst(7))) }
        return nil
    }
    private static func key(_ target: Target) -> SyncKit.Record.Key? {
        switch target {
        case .profile: return .init(collection: SyncShapes.file, id: "profile.json")
        case .address(let id, _): return .init(collection: SyncWallet.address, id: id)
        case .memory(let id): return .init(collection: SyncShapes.memory, id: id)
        case .report: return .init(collection: SyncShapes.file, id: "know.json")
        }
    }
    private static func label(_ target: Target) -> String {
        switch target {
        case .profile(let field): return "Profile · " + field
        case .address(let id, let field): return "Wallet · " + id + (field.map { " · " + $0 } ?? "")
        case .memory(let path): return "Memory · " + path
        case .report: return "Notes About You report"
        }
    }
    private static func json(_ record: SyncKit.Record) -> Data? { record["json"].flatMap { try? JSONEncoder().encode($0) } }
    static func image(_ record: SyncKit.Record) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        // An unencodable record cannot keep a stable admission identity.
        guard let data = try? encoder.encode(record) else { return "unavailable:" + UUID().uuidString }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
