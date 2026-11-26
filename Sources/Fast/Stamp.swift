import YabStore
import AppKit
import Combine
import Foundation
import Security
import SwiftUI

// The First Edition stamp: the number and restored date assigned by the
// site (fast-web lib/stamps.ts), and what is written on its back.
// With a friend's link that is the friend and their note; without one, a
// note from Yab's maker. It shows in Welcome's mark place for an invited friend
// and stays in Settings › About; the note reads under the pointer, as paper
// held to a lamp (StampView).
//
// Asked with the same random invites ID as Invites, the first name, and for
// Yabs that were here before stamps, the day of the first page in History,
// so the earliest get the earliest numbers.
@MainActor
final class MemberStamp: ObservableObject {
    static let shared = MemberStamp()

    struct Info: Codable, Equatable {
        var number: Int
        /// friend, best, alpha or self
        var kind: String
        var from: String
        var note: String
        /// When this Mac first had it, for "from Anna, Oct 13".
        var at: Date
        /// The invites ID whose number this is: another Mac of the same
        /// person when it came through Sync.
        var owner: String?
    }

    /// This Yab's stamp, once the site gave it.
    @Published private(set) var info: Info?
    /// The restored first observed day from the site, or a local candidate
    /// until the site answers. Used on the back and for anniversary postmarks.
    @Published private(set) var since: Date?
    /// What goes on the back of friends' stamps (InviteFriendsPage).
    @Published var outgoing: String {
        didSet {
            Store.settings.set(outgoing, forKey: "stamp.outgoing")
            sendSoon()
        }
    }

    private var serverSince: Date?
    private var started = false
    private var watching: AnyCancellable?
    private var sending: Task<Void, Never>?
    private var clock: Timer?
    private var identityUnavailable = false

    private init() {
        info = Self.decode(Store.settings.data(forKey: "stamp.info"))
        outgoing = Store.settings.string(forKey: "stamp.outgoing") ?? ""
        serverSince = Self.restoredSince(settings: Store.settings)
        since = serverSince ?? Self.day(Store.settings.double(forKey: "stamp.since"))
    }

    var invited: Bool { info.map { $0.kind == "friend" || $0.kind == "best" } ?? false }

    func start() {
        guard !started, !Store.testing, Updater.site != nil else { return }
        started = true
        // A Yab on its first launch starts today. One from before keeps its
        // day in the keychain, through a reinstall, and finds it in History
        // and on the site when it asks below.
        if !(Store.settings.bool(forKey: "welcomed") || Store.settings.object(forKey: "glyph") != nil) { note(since: Date()) }
        Task {
            let kept = await Task.detached(priority: .utility) { FirstDay.read() }.value
            note(since: kept)
            await refresh()
        }
        // A friend's link is claimed a moment after launch: ask again then,
        // so the stamp becomes theirs.
        watching = Invites.shared.$received.dropFirst().sink { [weak self] received in
            guard received != nil else { return }
            Task { await self?.refresh() }
        }
        // Until "You're No. 42" has been said once, look again each minute
        // for a moment it can be said in (not over Welcome).
        // The stamp is a synced setting: another Mac of the same person
        // may hand over its own, and the site keeps the earlier number.
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.adoptSynced()
                self?.adoptSyncedSince()
                self?.announceIfDue()
                if let self, self.identityUnavailable { Task { await self.refresh() } }
            }
        }
        clock?.tolerance = 10
    }

    /// What the site says this Yab's stamp is.
    func refresh() async {
        guard let installation = await Invites.installation else { identityUnavailable = true; return }
        identityUnavailable = false
        let since = await knownSince()
        var body: [String: Any] = ["install": installation, "name": Invites.firstName]
        if let since { body["since"] = since.timeIntervalSince1970 }
        if let owner = info?.owner, owner != installation { body["same"] = owner }
        guard let answer = await Self.ask("api/invites/stamp", body),
              let number = answer["number"] as? Int else { return }
        if let restored = Self.keepAuthoritativeSince(in: answer, settings: Store.settings) {
            serverSince = restored
            self.since = restored
        } else {
            note(since: (answer["since"] as? Double).flatMap(Self.day))
        }
        let next = Info(number: number, kind: answer["kind"] as? String ?? "self",
                        from: answer["from"] as? String ?? "Yab", note: answer["note"] as? String ?? "",
                        at: info?.at ?? Date(), owner: answer["owner"] as? String ?? installation)
        guard next != info else { return }
        info = next
        Store.settings.set(Self.data(next), forKey: "stamp.info")
        announceIfDue()
    }

    /// The server's recovered date may be later than imported browser History.
    static func authoritativeSince(in answer: [String: Any]) -> Date? {
        guard answer["sinceAuthoritative"] as? Bool == true,
              let seconds = answer["since"] as? Double,
              let date = day(seconds), plausible(date) else { return nil }
        return date
    }

    static func restoredSince(settings: UserDefaults) -> Date? {
        day(settings.double(forKey: "stamp.serverSince")).flatMap { plausible($0) ? $0 : nil }
    }

    static func keepAuthoritativeSince(in answer: [String: Any], settings: UserDefaults) -> Date? {
        guard let restored = authoritativeSince(in: answer) else { return nil }
        settings.set(restored.timeIntervalSince1970, forKey: "stamp.serverSince")
        settings.set(restored.timeIntervalSince1970, forKey: "stamp.since")
        return restored
    }

    /// A stamp another Mac put into the synced setting: ask the site which
    /// number this person keeps.
    private func adoptSynced() {
        guard let synced = Self.decode(Store.settings.data(forKey: "stamp.info")), synced != info else { return }
        info = synced
        Task {
            let installation = await Invites.installation
            if synced.owner != installation { await refresh() }
        }
    }

    // MARK: the first day

    /// The earliest day this person is known to have had Yab: what was
    /// kept, the first page in History, the day this Mac got its stamp.
    private func knownSince() async -> Date? {
        if let serverSince { return serverSince }
        note(since: await Self.firstVisit())
        note(since: info?.at)
        return since
    }

    /// A day this person had Yab, kept wherever the first day lives when
    /// it is earlier than the one known.
    private func note(since day: Date?) {
        guard serverSince == nil else { return }
        guard let day = Self.earliest(since, day), day != since else { return }
        since = day
        Store.settings.set(day.timeIntervalSince1970, forKey: "stamp.since")
        Task.detached(priority: .utility) { FirstDay.keep(day) }
    }

    /// The synced day: another Mac's earlier one is taken, and a later one
    /// written over ours is put back, so every Mac ends on the earliest.
    private func adoptSyncedSince() {
        let synced = Store.settings.double(forKey: "stamp.since")
        note(since: Self.day(synced))
        if let since, synced != since.timeIntervalSince1970 {
            Store.settings.set(since.timeIntervalSince1970, forKey: "stamp.since")
        }
    }

    /// The earlier of two days, leaving out what can't be a day of Yab.
    nonisolated static func earliest(_ a: Date?, _ b: Date?) -> Date? {
        [a, b].compactMap { $0 }.filter(plausible).min()
    }

    /// Yab came out in 2026; nothing was used with it before 2025, nor tomorrow.
    nonisolated static func plausible(_ day: Date) -> Bool {
        // Compare scalars: the SDK weak-links Date >= / <= to new Foundation
        // symbols on macOS 27.2, absent on the reporter's 27.2 runtime.
        let seconds = day.timeIntervalSince1970
        return seconds.isFinite && seconds >= 1_735_689_600 && seconds <= Date().timeIntervalSince1970 + 86_400
    }

    private static func day(_ seconds: Double) -> Date? {
        guard seconds.isFinite, seconds >= 1_735_689_600, seconds <= Date().timeIntervalSince1970 + 86_400 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The anniversaries reached by now, oldest first: one postmark each.
    /// A first day of Feb 29 comes round on Feb 28 in the other years.
    static func anniversaries(since: Date?, now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        guard let since else { return [] }
        let first = calendar.startOfDay(for: since)
        var days: [Date] = []
        while days.count < 200, let next = calendar.date(byAdding: .year, value: days.count + 1, to: first), next.timeIntervalSince1970 <= now.timeIntervalSince1970 {
            days.append(next)
        }
        return days
    }

    /// Once: the number, after Welcome, for the ones Welcome didn't show it to.
    private func announceIfDue() {
        guard let info, !Store.settings.bool(forKey: "stamp.announced") else { return }
        if invited {
            // Welcome showed it in the mark's place.
            Store.settings.set(true, forKey: "stamp.announced")
            return
        }
        guard let browser = BrowserWindows.shared.activeBrowser, !browser.welcoming else { return }
        browser.announce("You're No. \(info.number) · your stamp is in About", mark: "brand.blobplus")
        Store.settings.set(true, forKey: "stamp.announced")
    }

    /// The note on the back of friends' stamps, to the site a moment after
    /// the last keystroke.
    private func sendSoon() {
        sending?.cancel()
        let note = outgoing
        sending = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            guard let installation = await Invites.installation else { return }
            _ = await Self.ask("api/invites/note", ["install": installation, "from": Invites.firstName, "note": note])
        }
    }

    // MARK: Welcome's picture

    /// The stamp as Welcome's mark shows it: a square picture, the stamp
    /// upright in the middle, its number when the site gave it.
    static func welcomePicture(from received: Invites.Received, info: Info?) -> CGImage? {
        let art = StampArt(number: info.map { "\($0.number)" }, name: Invites.firstName,
                           blush: received.best ? CharmSwatch.color(received.color ?? "mint") : nil)
            .frame(width: StampArt.size.width, height: StampArt.size.height)
        let renderer = ImageRenderer(content: art)
        renderer.scale = 900 / StampArt.size.height
        guard let stamp = renderer.cgImage,
              let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let w = CGFloat(stamp.width), h = CGFloat(stamp.height)
        context.draw(stamp, in: CGRect(x: (1024 - w) / 2, y: (1024 - h) / 2, width: w, height: h))
        return context.makeImage()
    }

    // MARK: plumbing

    /// The day of the first page in History, for Yabs from before stamps.
    private static func firstVisit() async -> Date? {
        await withCheckedContinuation { done in
            Diary.shared.outline { out in
                let ms = out["since"] as? Double ?? 0
                done.resume(returning: ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil)
            }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    private static func ask(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
        guard let site = Updater.site else { return nil }
        var request = URLRequest(url: site.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The stamp as its synced setting keeps it, its keys sorted: the
    /// setting syncs as its bytes, and an encoder orders them anew in each
    /// run, so the same stamp written on two Macs went up as a change.
    nonisolated static func data(_ info: Info) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(info)
    }

    private static func decode(_ data: Data?) -> Info? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }
}

/// The first day in the login keychain too, under this Yab's name: it stays
/// when Yab and its data are deleted and installed again. Asked without the
/// keychain's password window, off the main thread.
enum FirstDay {
    /// One transaction, with raw storage supplied by the keychain in the app.
    /// Tests supply their own memory and lock, without touching a keychain.
    struct Storage {
        let readData: () -> Data?
        let writeData: (Data) -> Void
        let withLock: (() -> Void) -> Void

        static var keychain: Storage {
            Storage(readData: {
                var query = FirstDay.item
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var found: AnyObject?
                guard Keychain.copyMatching(query as CFDictionary, &found) == errSecSuccess else { return nil }
                return found as? Data
            }, writeData: { data in
                if Keychain.update(FirstDay.item as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
                    var add = FirstDay.item
                    add[kSecValueData as String] = data
                    _ = Keychain.add(add as CFDictionary, nil)
                }
            }, withLock: { body in Keychain.quietly(body) })
        }
    }

    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(Store.name) First Day",
         kSecAttrAccount as String: "since"]
    }

    private static func decode(_ data: Data?) -> Date? {
        guard let data, let seconds = Double(String(decoding: data, as: UTF8.self)), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func read(using storage: Storage = .keychain) -> Date? {
        var day: Date?
        storage.withLock { day = decode(storage.readData()) }
        return day
    }

    static func keep(_ day: Date, using storage: Storage = .keychain) {
        storage.withLock {
            let kept = decode(storage.readData())
            guard let first = MemberStamp.earliest(kept, day), first != kept else { return }
            storage.writeData(Data(String(first.timeIntervalSince1970).utf8))
        }
    }
}
