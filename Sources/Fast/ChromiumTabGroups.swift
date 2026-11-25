import AppKit
import YabCoreClient

/// What Chrome's extensions see as a window: a Yab window's Chromium pages,
/// per profile, in the column's order, the one on screen active. Without it
/// each page is a window of its own, since each has a concealed native one.
/// Pages not built yet are not listed: Chrome has nothing for them.
@MainActor
final class ChromiumTabGroups {
    static let shared = ChromiumTabGroups()
    private var started = false
    private var queued = false
    private(set) var scans = 0
    private var sent: [String: [String]] = [:]
    private var tail: Task<Void, Error>?
    private var refreshing = false

    func start() {
        started = true
        sent = [:]
        changed()
    }

    /// Membership, ordering, selection and remote-page lifetimes own this
    /// state. Read after their setters finish, once per main-loop turn;
    /// unchanged tabs need no periodic reconstruction of the same groups.
    func changed() {
        guard started, !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            AppKitMainThread.sync {
                guard let self else { return }
                self.queued = false
                self.sync()
            }
        }
    }

    private func sync() {
        guard !refreshing else { return }
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false }
            do { try await syncNow() }
            catch { DebugLog.note("chromium-window-model", ["error": String(describing: error)]) }
        }
    }

    /// Mutation responses wait for the same native model used by tabs.query.
    /// Serializing snapshots prevents a timer's older row replacing that state.
    func syncNow() async throws {
        let previous = tail
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try await publish()
        }
        tail = task
        try await task.value
    }

    private func publish() async throws {
        scans += 1
        guard let core = ChromiumProcess.shared.connectedClient else {
            sent = [:]
            return
        }
        var live = Set<String>()
        for browser in BrowserWindows.shared.browsers {
            var byProfile: [String: [String]] = [:]
            var active: [String: String] = [:]
            var groups: [String: Int] = [:], pinned: [String: JSONValue] = [:], openers: [String: JSONValue] = [:]
            let all = browser.tabs + browser.parkedTabs + browser.outside
            for tab in browser.tabs + browser.parkedTabs where !tab.shy {
                guard let page = tab.builtPage as? ChromiumPage, let remote = page.remoteID else { continue }
                byProfile[page.profile, default: []].append(remote)
                pinned[remote] = .bool(tab.pin != nil)
                if let opener = tab.opener, let source = all.first(where: { $0.id == opener }), let native = (source.builtPage as? ChromiumPage)?.remoteID { openers[remote] = .string(native) }
                groups[remote] = tab.nest.map { ExtensionGroups.id(of: $0.id) } ?? -1
                if tab.id == browser.activeID { active[page.profile] = remote }
            }
            // An extension's side panel is in this window too: in Chrome its
            // current window is the browser window it is shown in, so
            // tabs.query({active: true, currentWindow: true}) from the panel
            // gives the page it is beside. Left out, the panel's page was a
            // window of its own and that query came back empty (Apollo's
            // panel stayed blank). Listed last and never active, so the
            // window's own tabs keep their indexes.
            for remote in ChromiumSidePanel.shared.pages(in: browser) {
                guard let profile = remote.profile, byProfile[profile]?.contains(remote.id) != true else { continue }
                byProfile[profile, default: []].append(remote.id)
                pinned[remote.id] = .bool(false)
                groups[remote.id] = -1
            }
            for (profile, tabs) in byProfile {
                let key = "\(ObjectIdentifier(browser))/\(profile)"
                live.insert(key)
                let shape = tabs + ["|", active[profile] ?? ""] + tabs.map { "\(groups[$0] ?? -1)/\(pinned[$0] == .bool(true))/\(openers[$0]?.string ?? "")" }
                guard sent[key] != shape else { continue }
                let params: [String: JSONValue] = ["tabs": .array(tabs.map { .string($0) }), "active": .string(active[profile] ?? ""),
                    "groups": .object(groups.mapValues { .number(Double($0)) }),
                    "windowKey": .string(browser.windowID?.uuidString ?? "primary"), "pinned": .object(pinned), "openers": .object(openers)]
                let reply = try await core.request("tabs.group", params: params)
                guard reply["refused"].number == 0 else { throw YabCoreError.remote("Native window membership was refused") }
                sent[key] = shape
            }
        }
        sent = sent.filter { live.contains($0.key) }
    }
}
