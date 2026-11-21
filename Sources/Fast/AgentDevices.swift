import Foundation
import SyncKit

// What an agent may know of the user's other Yab devices in Sync: the
// `devices` tool, and the places `history` adds from them.
//
// Read from this Mac's own copy of sync (the journal), never asked of the
// server: an iPhone's visits come as `visit` records whose `last` it wrote,
// its tabs of today as `tab` records carrying its id (docs/sync.md). Names
// come from the account's device list, asked for once if it isn't here yet.

@MainActor
enum AgentDevices {
    /// A place last been to on another device.
    struct Visit: Sendable {
        let url: URL
        let title: String
        let at: Date
        let device: String
    }

    /// Who each device is, by the account's list: another Mac's name, an
    /// iPhone's with (iPhone) when its name doesn't say so.
    static func names() -> [String: String] {
        Dictionary(SyncCenter.shared.devices.map { found in
            let name = found.name.isEmpty ? found.model : found.name
            let phone = found.model.lowercased().hasPrefix("iphone") && !name.lowercased().contains("iphone")
            return (found.id, phone ? "\(name) (iPhone)" : name)
        }, uniquingKeysWith: { a, _ in a })
    }

    /// The account's device list, asked for when it is empty, then `done`.
    static func named(_ done: @escaping @MainActor () -> Void) {
        let sync = SyncCenter.shared
        guard sync.on, sync.devices.isEmpty else { return done() }
        sync.refreshDevices()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { done() }
    }

    /// What `visits` reads, taken on the main thread.
    static func source() -> (journal: Journal, me: String, names: [String: String])? {
        guard SyncCenter.shared.on, let journal = SyncCenter.shared.journal else { return nil }
        return (journal, SyncCenter.deviceID, names())
    }

    /// Places whose last visit another device wrote, since `days` ago. Off
    /// the main thread: the journal decodes every visit record.
    nonisolated static func visits(_ source: (journal: Journal, me: String, names: [String: String])?, days: Int = 365) -> [Visit] {
        guard let source else { return [] }
        let since = Date().timeIntervalSince1970 - Double(days) * 86_400
        return source.journal.living(SyncShapes.visit).compactMap { record in
            guard let device = record.stamps["last"]?.device, device != source.me,
                  let visit = SyncVisit(record), visit.last >= since, let url = URL(string: visit.url) else { return nil }
            return Visit(url: url, title: visit.title, at: Date(timeIntervalSince1970: visit.last), device: source.names[device] ?? "another device")
        }
    }

    /// The devices, when each was last seen, and the tabs of today open on
    /// each but this Mac, in Markdown. Off the main thread, as `visits`.
    nonisolated static func describe(_ source: (journal: Journal, me: String, names: [String: String])?, seen: [String: Date]) -> String {
        guard let source else {
            return "Sync is off: Yab knows no other devices. The user turns it on in Settings › Sync, and adds an iPhone or a Mac there with Add a Device."
        }
        let journal = source.journal, me = source.me, names = source.names
        let spaces = Dictionary(journal.living(SyncShapes.space).compactMap(SyncSpace.init).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var tabs: [String: [SyncTab]] = [:]
        for tab in journal.living(SyncShapes.tab).compactMap(SyncTab.init) where tab.list == .today {
            guard let device = tab.device, device != me else { continue }
            tabs[device, default: []].append(tab)
        }
        let others = names.keys.filter { $0 != me }
        guard !others.isEmpty || !tabs.isEmpty else { return "Only this Mac is in Sync. Another device joins in Settings › Sync, Add a Device." }
        var out = "# The user's other devices in Sync\n"
        for id in Set(others).union(tabs.keys).sorted(by: { (names[$0] ?? $0) < (names[$1] ?? $1) }) {
            let last = seen[id].map { " · last seen \($0.formatted(.relative(presentation: .named).locale(AppDates.locale)))" } ?? ""
            out += "\n## \(names[id] ?? "another device")\(last)\n"
            let open = (tabs[id] ?? []).sorted { ($0.seen ?? 0) > ($1.seen ?? 0) }
            if open.isEmpty { out += "No tabs of today open there.\n"; continue }
            for tab in open.prefix(60) {
                let title = tab.name ?? (tab.title.isEmpty ? "(untitled)" : tab.title)
                let space = spaces[tab.space].map { " · \($0)" } ?? ""
                out += "- \(title)\(space)\n  \(tab.url)\n"
            }
            if open.count > 60 { out += "…and \(open.count - 60) more.\n" }
        }
        out += "\nPins and kept tabs are shared by every device: they are the user's spaces, as `tabs` and native_context show them. `history` with device lists what was opened on one."
        return out
    }
}
