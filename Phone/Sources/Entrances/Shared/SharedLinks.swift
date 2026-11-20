import Foundation
import CryptoKit
import Security

/// Only the share extension's own group, never the phone's Sync groups.
/// The app may publish a revocable session here; queue encryption is separate.
struct SharedLinkSecrets: Sendable {
    enum Storage: Sendable { case keychain(String?), files(URL) }
    let storage: Storage

    static var standard: Self {
        let group = Bundle.main.object(forInfoDictionaryKey: "YabShareKeychainGroup") as? String
        return Self(storage: .keychain(group.flatMap { $0.contains("$(") ? nil : $0 }))
    }

    private func query(_ name: String) -> [String: Any]? {
        guard case let .keychain(group?) = storage else { return nil }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Yab share extension",
                kSecAttrAccount as String: name,
                kSecAttrAccessGroup as String: group,
                kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true]
    }

    func read(_ name: String) -> Data? {
        if case let .files(folder) = storage { return try? Data(contentsOf: folder.appendingPathComponent(name)) }
        guard var query = query(name) else { return nil }
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    func write(_ data: Data, _ name: String, replacing: Bool = true) -> Bool {
        if case let .files(folder) = storage {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(name)
            return (try? data.write(to: file, options: replacing ? .atomic : .withoutOverwriting)) != nil
        }
        guard let query = query(name) else { return false }
        if replacing {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status != errSecItemNotFound { return status == errSecSuccess }
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func remove(_ name: String) -> Bool {
        if case let .files(folder) = storage {
            let file = folder.appendingPathComponent(name)
            return !FileManager.default.fileExists(atPath: file.path) || (try? FileManager.default.removeItem(at: file)) != nil
        }
        guard let query = query(name) else { return false }
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Local encryption for the app and share extension. This key is separate
/// from Sync, so turning Sync off cannot strand an unsent shared link.
struct SharedLinkProtection: Sendable {
    var key: @Sendable () -> SymmetricKey?
    var legacyKey: (@Sendable () -> SymmetricKey?)? = nil

    static let keychain = using(.standard)

    static func using(_ secrets: SharedLinkSecrets) -> Self {
        Self(key: {
            if let data = secrets.read("queue-key"), data.count == 32 { return SymmetricKey(data: data) }
            // Earlier PR builds used the phone's private group. The app can
            // migrate that key; the extension no longer has access to it.
            let old: SymmetricKey?
            if case .keychain = secrets.storage { old = previousKey() } else { old = nil }
            let key = old ?? SymmetricKey(size: .bits256)
            secrets.write(key.withUnsafeBytes { Data($0) }, "queue-key", replacing: false)
            guard let data = secrets.read("queue-key"), data.count == 32 else { return nil }
            return SymmetricKey(data: data)
        }, legacyKey: {
            guard case .keychain = secrets.storage else { return nil }
            return previousKey()
        })
    }

    private static func previousKey() -> SymmetricKey? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "Yab shared links",
                                   kSecAttrAccount as String: "local encryption",
                                   kSecUseDataProtectionKeychain as String: true]
        func read() -> SymmetricKey? {
            var request = query
            request[kSecReturnData as String] = true
            var result: CFTypeRef?
            guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data, data.count == 32 else { return nil }
            return SymmetricKey(data: data)
        }
        return read()
    }

    private struct Envelope: Codable { var sealed: Data }

    func seal(_ data: Data, purpose: String) throws -> Data {
        guard let key = key() else { throw CocoaError(.fileWriteNoPermission) }
        let box = try AES.GCM.seal(data, using: key, authenticating: Data(purpose.utf8))
        guard let combined = box.combined else { throw CryptoKitError.incorrectParameterSize }
        return try JSONEncoder().encode(Envelope(sealed: combined))
    }

    func open(_ data: Data, purpose: String) -> Data? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let box = try? AES.GCM.SealedBox(combined: envelope.sealed) else { return nil }
        if let key = key(), let opened = try? AES.GCM.open(box, using: key, authenticating: Data(purpose.utf8)) { return opened }
        guard let key = legacyKey?() else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: Data(purpose.utf8))
    }

    static func isSealed(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(Envelope.self, from: data)) != nil
    }
}

/// A link handed to Yab from another app's share sheet: opened as a tab, or
/// kept for later without opening Yab. The share extension (Phone/Share)
/// writes it to the queue both share; the app takes it (Entrances).
/// Compiled into the app, the extension and the UI tests, which queue links
/// with the same code the extension does.
struct SharedLink: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        /// Open in Yab: a tab in front of whatever is on screen, as a link from another app.
        case open
        /// Keep for Later: a kept tab in the space last in front, Yab not opened.
        case keep
    }

    var action: Action
    /// The link as it was shared: http or https, or written without a
    /// scheme (example.com/a), which the app reads as the field does. With
    /// `search`, words to search for instead.
    var address: String
    var search: Bool
    /// The page's title as the sharing app said it, if it did.
    var title: String?
    var date: Date
    /// The encrypted-sync record prepared before upload, for the app to
    /// import with the same identity even if the server's reply was lost.
    var sync: Data?

    init(action: Action, address: String, search: Bool = false, title: String? = nil, date: Date = Date()) {
        self.action = action
        self.address = address
        self.search = search
        self.title = title
        self.date = date
    }

    /// The link carried in the URL itself, for when the queue can't be
    /// reached: yab-open://<the link, percent-encoded> (Entrances/Links reads it).
    static func wrapped(_ address: String) -> URL? {
        let encoded = address.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? address
        return URL(string: "yab-open://\(encoded)")
    }
}

/// The hand-off between the share extension and the app: one small file per
/// link in the App Group's container, written whole (a rename) and removed
/// once read, so the two processes never edit one file. The app takes what
/// waits when it comes to the front and when the extension opens it
/// (yab://shared).
struct SharedLinkQueue: Sendable {
    static let appGroup = "group.dev.serafim.fast.iphone"
    /// More than this waiting and the oldest go: a queue Yab never reads stays small.
    static let limit = 50

    /// Where the files are; nil when the App Group isn't granted (a build
    /// without its entitlement), and then nothing is queued.
    let folder: URL?
    let protection: SharedLinkProtection?

    init(folder: URL?, protection: SharedLinkProtection? = nil) {
        self.folder = folder
        self.protection = protection
    }

    /// The App Group's queue, shared by the app and the extension.
    static var shared: SharedLinkQueue {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        return SharedLinkQueue(folder: container?.appendingPathComponent("Shared Links", isDirectory: true), protection: .keychain)
    }

    /// Queues a link; false when it couldn't be written.
    @discardableResult
    func add(_ link: SharedLink) -> Bool {
        guard let folder else { return false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // Named by the moment, so the names sort oldest first.
            let millis = Int64((link.date.timeIntervalSince1970 * 1000).rounded())
            let name = String(format: "%014lld-", millis) + UUID().uuidString + ".json"
            let plain = try encoder.encode(link)
            let data = try protection?.seal(plain, purpose: "yab.shared.link.v1") ?? plain
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        } catch {
            return false
        }
        for old in entries().dropLast(Self.limit) { try? FileManager.default.removeItem(at: old) }
        return true
    }

    /// Accepted links, oldest first, removed only after their import.
    /// Rejected links stay for a retry. Invalid files are removed too.
    func take(accept: (SharedLink) -> Bool = { _ in true }) -> [SharedLink] {
        return entries().compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            guard let link = decode(data) else {
                // A locked or unavailable key is not a corrupt queue entry.
                if SharedLinkProtection.isSealed(data) { return nil }
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            guard accept(link) else { return nil }
            try? FileManager.default.removeItem(at: file)
            return link
        }
    }

    /// Pending records also supply identities for repeated shares before
    /// the app has opened and refreshed its snapshot.
    var links: [SharedLink] {
        return entries().compactMap { file in
            (try? Data(contentsOf: file)).flatMap(decode)
        }
    }

    private func decode(_ data: Data) -> SharedLink? {
        let plain: Data
        if SharedLinkProtection.isSealed(data) {
            guard let opened = protection?.open(data, purpose: "yab.shared.link.v1") else { return nil }
            plain = opened
        } else { plain = data } // Keep links saved by an older app readable.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedLink.self, from: plain)
    }

    /// How many links wait, without taking them.
    var count: Int { entries().count }

    /// The queue's files, oldest first. A write in progress is a hidden
    /// temporary file until its rename, and never counts.
    private func entries() -> [URL] {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") && $0.hasSuffix(".json") }.sorted().map { folder.appendingPathComponent($0) }
    }
}

/// What a share sheet's items hold for Yab: the first web link, from a URL
/// item or inside text; else the text itself, to search for.
enum SharedItems {
    struct Found: Equatable, Sendable {
        /// A link (see SharedLink.address), or words with `search`.
        var address: String
        var search: Bool
        var title: String?

        /// What the card and a kept tab say for a link: its host, no www.
        var host: String? {
            guard !search else { return nil }
            let url = address.contains("://") ? URL(string: address) : URL(string: "https://" + address)
            guard let host = url?.host()?.lowercased() else { return nil }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }

    /// Words longer than this are cut before they become a search.
    static let searchLimit = 300
    /// A title longer than this is cut: it is a line in a card and a row.
    static let titleLimit = 120

    /// `urls` from URL items, `texts` from text items (and the item's own
    /// text last), `title` as the sharing app gave it.
    static func find(urls: [URL], texts: [String], title: String? = nil) -> Found? {
        if let url = urls.first(where: isWeb) {
            return Found(address: url.absoluteString, search: false, title: clean(title, besides: url.absoluteString))
        }
        for text in texts {
            if let link = link(in: text) { return Found(address: link, search: false, title: clean(title, besides: link)) }
        }
        for text in texts {
            let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !words.isEmpty { return Found(address: String(words.prefix(searchLimit)), search: true, title: nil) }
        }
        return nil
    }

    /// The first web link in some text. Written without a scheme
    /// (www.example.com/a), it stays as written: the app puts https in
    /// front, as its field does, where the detector would say http.
    static func link(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed), isWeb(url), url.host() != nil {
            return url.absoluteString
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for match in detector.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
            guard let url = match.url, isWeb(url), let range = Range(match.range, in: trimmed) else { continue }
            let written = String(trimmed[range])
            return written.contains("://") ? url.absoluteString : written
        }
        return nil
    }

    static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// A title as a line: its first line, trimmed and cut; none when it is
    /// only the link again or itself a link.
    static func clean(_ title: String?, besides link: String) -> String? {
        guard let line = title?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty, line != link, self.link(in: line) != line else { return nil }
        return line.count > titleLimit ? String(line.prefix(titleLimit - 1)) + "…" : line
    }
}
