import AppKit
import YabCoreClient

/// One batch owns its native preflights until all documents agree. No native
/// page closes while a later document can still answer Stay.
@MainActor
final class ChromiumCloseBatch {
    @MainActor final class Entry {
        let tab: Tab
        let page: ChromiumPage
        let remote: String
        let owner = UUID().uuidString
        var request: String?
        var document: String?
        var token: String?
        var committing = false
        var closedConfirmed = false
        weak var batch: ChromiumCloseBatch?
        init(tab: Tab, page: ChromiumPage, remote: String) {
            self.tab = tab; self.page = page; self.remote = remote
        }
        var live: Bool { !tab.gone && tab.builtPage === page && page.remoteID == remote }
        var wire: JSONValue {
            .object(["tab": .string(remote), "owner": .string(owner),
                     "document": .string(document ?? ""), "token": .string(token ?? "")])
        }
    }
    static var active: [ObjectIdentifier: Entry] = [:]
    /// lifecycle.inc's words when the SDK has no patch 0039.
    nonisolated static let noPreflight = "Non-destructive native close is unavailable in this SDK/API mode"
    let core: YabCoreClient
    var entries: [Entry] = []
    var valid = true
    private(set) var unavailable = false
    init(core: YabCoreClient) { self.core = core }

    func invalidate() {
        guard valid else { return }
        valid = false
        for entry in entries { Leaving.withdrawChromium(entry.page) }
        // Withdraw a later pending question too. Native cancellation has its
        // own callback and can never progress the browser's close machinery.
        Task { @MainActor in await cancelNative() }
    }
    func cancelNative(includingDispatched: Bool = false, quitting: Bool = false) async {
        guard ChromiumProcess.shared.isCurrent(core) else { return }
        for entry in entries where includingDispatched || !entry.committing {
            _ = try? await core.request("tab.close.cancel", params: [
                "tab": .string(entry.remote), "owner": .string(entry.owner), "quitting": .bool(quitting)])
        }
    }
    func finish(_ leave: Bool) {
        for entry in entries {
            let id = ObjectIdentifier(entry.page)
            if Self.active[id] === entry { Self.active[id] = nil }
            if leave, entry.committing { entry.page.closeCommitted = true }
            if leave { Leaving.finish(entry.page, true) }
            else { Leaving.withdrawChromium(entry.page) }
        }
    }
    static func retireClosedRows(_ entries: [Entry], outcome: ChromiumCloseOutcome?) {
        for entry in entries where entry.closedConfirmed || outcome?.closed.contains(entry.remote) == true {
            guard !entry.tab.gone, entry.tab.builtPage === entry.page,
                  let browser = entry.tab.delegate as? Browser else { continue }
            if browser.tabs.contains(where: { $0 === entry.tab }) { browser.close([entry.tab]) }
            else { browser.closeElsewhere(entry.tab) }
        }
    }
    func prepare(_ tabs: [Tab], stoppingLoads: Bool = false) async -> Bool {
        // Reserve every local page before the first native question. A second
        // overlapping close cannot take ownership of another batch's token.
        for tab in tabs where !tab.gone {
            guard let page = tab.builtPage as? ChromiumPage else { continue }
            guard let remote = page.remoteID, Self.active[ObjectIdentifier(page)] == nil else {
                finish(false); return false
            }
            let entry = Entry(tab: tab, page: page, remote: remote)
            entry.batch = self; entries.append(entry)
            Self.active[ObjectIdentifier(page)] = entry
            Leaving.waits[ObjectIdentifier(page)] = Leaving.Wait { _ in }
        }
        guard !entries.isEmpty else { return true }
        guard valid, entries.allSatisfy(\.live), ChromiumProcess.shared.isCurrent(core) else {
            await cancelNative(); finish(false); return false
        }
        // Every page asked at once, as Chromium asks its tabs on Quit: one
        // after another, 136 tabs took longer than a person waits for Quit.
        // A page that asks still puts its question up in turn (Leaving.asked).
        let core = self.core
        let answers = await withTaskGroup(of: (Int, ChromiumCloseApproval?, Bool).self) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask { @MainActor in
                    do {
                        guard self.valid, entry.live, ChromiumProcess.shared.isCurrent(core) else { return (index, nil, false) }
                        let reply: JSONValue
                        do {
                            reply = try await entry.page.prepareNativeClose(owner: entry.owner, core: core, remote: entry.remote, allowUnresponsive: true)
                        } catch YabCoreError.remote(let message) where stoppingLoads && entry.page.isLoading
                            && message == "Native close preflight cancelled" && self.valid && entry.live
                            && ChromiumProcess.shared.isCurrent(core) {
                            // A pending navigation prevents native preflight
                            // from starting. Cancel it and ask again. Accepted
                            // preflights do not need an explicit stop request.
                            _ = try await core.request("tab.stop", params: ["tab": .string(entry.remote)])
                            guard self.valid, entry.live, ChromiumProcess.shared.isCurrent(core) else { return (index, nil, false) }
                            reply = try await entry.page.prepareNativeClose(owner: entry.owner, core: core, remote: entry.remote, allowUnresponsive: true)
                        }
                        return (index, ChromiumCloseApproval(reply, owner: entry.owner), false)
                    } catch YabCoreError.remote(let message) where message == Self.noPreflight {
                        return (index, nil, true)
                    } catch {
                        // Which page kept a quit or a close from going, and why (#2021).
                        if Store.testing { FileHandle.standardError.write(Data("yab: close preflight refused host=\(entry.tab.address?.host() ?? "") loading=\(entry.page.isLoading) error=\(error)\n".utf8)) }
                        return (index, nil, false)
                    }
                }
            }
            var found = [(ChromiumCloseApproval?, Bool)](repeating: (nil, false), count: entries.count)
            for await (index, approval, missing) in group { found[index] = (approval, missing) }
            return found
        }
        // The helper's one SDK answers for all of them.
        if answers.allSatisfy(\.1), valid, entries.allSatisfy(\.live) {
            unavailable = true
            return true
        }
        let approvals = answers.map(\.0)
        for (entry, approval) in zip(entries, approvals) {
            guard valid, entries.allSatisfy(\.live), let approval else {
                if Store.testing {
                    FileHandle.standardError.write(Data("yab: close preflight not approved host=\(entry.tab.address?.host() ?? "") valid=\(valid) live=\(entries.filter { !$0.live }.count == 0) approval=\(approval != nil)\n".utf8))
                }
                await cancelNative(); finish(false); return false
            }
            entry.request = approval.request; entry.document = approval.document; entry.token = approval.token
        }
        guard valid, entries.allSatisfy(\.live), ChromiumProcess.shared.isCurrent(core) else {
            await cancelNative(); finish(false); return false
        }
        return true
    }
    /// Yab quitting: every page asked, none closed. The quit can still be called
    /// off at its own question, and a quit that goes through ends the pages with
    /// the process.
    /// A page still loading can't be asked until its navigation stops (the
    /// helper refuses a pending entry), as on ⌘W: without stopping it, one
    /// loading tab answered for every page, and ⌘Q did nothing, no card and
    /// no word, as often as it was pressed (#2021). Chrome never lets a load
    /// keep it from quitting; only a page's Stay does.
    func ask(_ tabs: [Tab]) async -> Bool {
        guard await prepare(tabs, stoppingLoads: true) else { return false }
        if !unavailable { await cancelNative(quitting: true) }
        finish(true)
        return true
    }
    /// The native beforeunload asked and then released: the document stays,
    /// and stays open if this tab's engine switch goes no further.
    func approve(_ tab: Tab, _ page: ChromiumPage, remote: String) async -> EngineSwitchApproval.Page {
        guard Self.active[ObjectIdentifier(page)] == nil else { return .unavailable }
        let entry = Entry(tab: tab, page: page, remote: remote)
        entry.batch = self; entries.append(entry)
        Self.active[ObjectIdentifier(page)] = entry
        Leaving.waits[ObjectIdentifier(page)] = Leaving.Wait { _ in }
        let verdict: EngineSwitchApproval.Page
        do {
            let reply = try await page.prepareNativeClose(owner: entry.owner, core: core, remote: remote)
            verdict = ChromiumCloseApproval(reply, owner: entry.owner) != nil && valid ? .leave : .stay
        } catch {
            // A Stay already heard may end the request in an error too. Any
            // other failure means no answer: wave11's SDK has no preflight.
            verdict = valid ? .unavailable : .stay
        }
        await cancelNative()
        finish(false)
        return verdict
    }
    func run(_ tabs: [Tab]) async -> Bool {
        guard await prepare(tabs, stoppingLoads: true) else { return false }
        guard !entries.isEmpty else { return true }
        // A helper without the native preflight has no question to put: a
        // refusal by nobody is not a person's Stay. The pages close the plain
        // way. Only this falls through; a real Stay or a question up holds.
        if unavailable { finish(true); return true }
        // The helper validates every exact native document tree in one UI
        // task, marks all closing and commits without an event-loop yield.
        entries.forEach { $0.committing = true }
        let reply = try? await core.request("tabs.close.commit", params: ["approvals": .array(entries.map(\.wire))], timeout: 300)
        let outcome = reply.flatMap { ChromiumCloseOutcome($0, requested: Set(entries.map(\.remote))) }
        let allClosed = outcome?.allClosed == true
        if !allClosed {
            // Only positively confirmed old endpoints may lose their rows.
            // A replacement handle or retained/unknown endpoint remains.
            Self.retireClosedRows(entries, outcome: outcome)
            // Cancellation is safe even after a transport failure: the helper
            // rejects tab-scoped cancellation once native commit is in flight.
            await cancelNative(includingDispatched: true)
        }
        finish(allClosed)
        return allClosed
    }
}

extension ChromiumPage {
    /// Never starts/recreates a helper or waits behind a suspended script.
    /// Native beforeunload asks have their own bounded request lifetime.
    fileprivate func prepareNativeClose(owner: String, core: YabCoreClient, remote: String, allowUnresponsive: Bool = false) async throws -> JSONValue {
        guard remoteID == remote, ChromiumProcess.shared.isCurrent(core) else { throw CancellationError() }
        return try await core.request("tab.close.prepare", params: ["tab": .string(remote), "owner": .string(owner), "allowUnresponsive": .bool(allowUnresponsive)], timeout: 240)
    }

    /// Listener census is diagnostic only; it never authorizes a close.
    func beforeUnloadListeners() async -> Int? {
        guard remoteID != nil, let value = try? await navigationRequest("page.beforeUnloadListeners") else { return nil }
        return value["count"].number.map(Int.init)
    }

    func tryClose() async -> Bool? {
        guard remoteID != nil, let value = try? await navigationRequest("tab.tryClose") else { return nil }
        return value["immediate"] == .bool(true)
    }

    func receiveLifecycle(_ event: YabCoreEvent) -> Bool {
        if event.name == "tab.closePreflight" {
            guard let entry = ChromiumCloseBatch.active[ObjectIdentifier(self)],
                  event.params["owner"] == .string(entry.owner) else { return true }
            if event.params["final"] == .bool(true) {
                guard event.tab == entry.remote, event.params["version"] == .number(1),
                      event.params["request"]?.string == entry.request, entry.request != nil,
                      event.params["document"]?.string == entry.document, entry.document != nil,
                      event.params["token"]?.string == entry.token, entry.token != nil else { return true }
                if event.params["phase"] == .string("closed"), event.params["closed"] == .bool(true) {
                    entry.closedConfirmed = true
                } else if event.params["phase"] == .string("retained"), event.params["closed"] == .bool(false) {
                    entry.committing = false
                }
                return true
            }
            if event.params["withdrawn"] == .bool(true) ||
                (event.params["decision"] == .bool(true) && event.params["allow"] != .bool(true)) {
                entry.batch?.invalidate()
            }
            return true
        }
        guard event.name == "tab.closed" else { return false }
        return Leaving.chromiumClosed(self, closedRemote: event.tab)
    }
}

extension Leaving {
    static func eachChromium(_ tabs: [Tab], closing: Bool, done: @escaping (Bool) -> Void) {
        guard let core = ChromiumProcess.shared.connectedClient else { return done(false) }
        Task { @MainActor in
            let batch = ChromiumCloseBatch(core: core)
            done(await (closing ? batch.run(tabs) : batch.ask(tabs)))
        }
    }

    static func askChromiumForSwitch(_ tab: Tab, _ page: ChromiumPage) async -> EngineSwitchApproval.Page {
        // No native document yet: nothing typed, nothing to ask.
        guard let remote = page.remoteID else { return .leave }
        guard let core = ChromiumProcess.shared.connectedClient else { return .unavailable }
        // Entries only hold their batch weakly: keep it in a local while it asks.
        let batch = ChromiumCloseBatch(core: core)
        return await batch.approve(tab, page, remote: remote)
    }

    @discardableResult static func chromiumClosed(_ page: ChromiumPage, closedRemote: String? = nil) -> Bool {
        // The batch's reply can beat some of its tab.closed events. A late one
        // is the batch's close, not a page closing itself: its row stays.
        if page.closeCommitted { return true }
        if let entry = ChromiumCloseBatch.active[ObjectIdentifier(page)] {
            // helperExited also arrives here; only an authenticated tab.closed
            // for this original wire endpoint confirms endpoint death.
            if closedRemote == entry.remote { entry.closedConfirmed = true }
            if entry.committing { return true }
            entry.batch?.invalidate()
            finish(page, false)
            return false
        }
        guard waits[ObjectIdentifier(page)] != nil else { return false }
        finish(page, false)
        return true
    }
}
