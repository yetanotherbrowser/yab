import SyncKit
import XCTest
@testable import YabPhone

/// The app in sync against a Mac on a server in memory: joining, the Mac's
/// rows in the column, the iPhone's changes on the Mac, presence, the Mac
/// asleep, the outbox across a relaunch, a removed iPhone.
@MainActor
final class SyncBridgeTests: XCTestCase {
    private final class FailingDevice: ChatBackend {
        let who = Chat.Answerer.iphone
        var isAvailable: Bool { true }
        var calls = 0
        enum Failure: Error { case unavailable }
        func answer(_ context: AskContext) async throws -> String {
            calls += 1
            throw Failure.unavailable
        }
    }
    private final class SuspendedFailingDevice: ChatBackend {
        let who = Chat.Answerer.iphone
        var isAvailable: Bool { true }
        var calls = 0
        private var waiting: CheckedContinuation<String, Error>?

        func answer(_ context: AskContext) async throws -> String {
            calls += 1
            return try await withCheckedThrowingContinuation { waiting = $0 }
        }

        func fail() {
            let continuation = waiting
            waiting = nil
            continuation?.resume(throwing: FailingDevice.Failure.unavailable)
        }
    }
    private var folder: URL!
    private let work = "6A1E4F0C-3B2D-4F77-9C1A-0E5D2B7A9F10"
    private let first = SyncCollection.firstSpace

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-bridge-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - helpers

    private func setup(_ server: SyncMemoryServer, seed: Bool = false, onlineFor: TimeInterval = PhoneSync.onlineFor,
                       refreshEvery: TimeInterval = 60, ownWorld: Bool = true, home: URL? = nil) -> SyncBridge.Setup {
        let folder: URL = home ?? folder
        return SyncBridge.Setup(base: URL(string: "https://sync.test")!, keys: .testing(folder: folder.appendingPathComponent("keys")),
                         folder: folder.appendingPathComponent("journal"), seed: seed, makesKey: seed, deviceName: "Test iPhone",
                         transport: server, onlineFor: onlineFor, refreshEvery: refreshEvery, ownWorld: ownWorld)
    }

    /// An iPhone on its first launch: one empty space of its own.
    private func blank() -> World {
        World(name: "test", space: "home", spaces: [Space(id: "home", name: "Home", emoji: "🏠", tint: RGB(238, 233, 226))])
    }

    private func until(_ seconds: Double = 4, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    /// A Mac with Mira's Work: a pin, a folder of two, a kept tab, three of today's.
    private func macWithWork(_ server: SyncMemoryServer, _ seal: Seal) async throws -> TestMac {
        let mac = try TestMac(server: server, seal: seal)
        try mac.write(SyncCollection.space, first, SyncSpace(id: first, name: "Personal", icon: "🏠", order: "V").fields)
        try mac.write(SyncCollection.space, work, SyncSpace(id: work, name: "Work", icon: "💼", order: "X").fields)
        try mac.write(SyncCollection.folder, "F0000000-0000-4000-8000-000000000001",
                      SyncFolder(id: "F0000000-0000-4000-8000-000000000001", space: work, order: "B", name: "Onboarding v3", open: true).fields)
        let tabs = [
            SyncTab(id: "AAAAAAAA-0000-4000-8000-000000000001", space: work, order: "A", url: "https://daybook.app", title: "Daybook", pin: "D"),
            SyncTab(id: "AAAAAAAA-0000-4000-8000-000000000002", space: work, order: "B", url: "https://figma.com/design/xK29fLm8/Onboarding-v3",
                    title: "Onboarding v3 · Welcome screens", kept: true, folder: "F0000000-0000-4000-8000-000000000001"),
            SyncTab(id: "AAAAAAAA-0000-4000-8000-000000000003", space: work, order: "C", url: "https://paper.so/tern/onboarding-v3-spec",
                    title: "Onboarding v3 spec · Paper", kept: true, folder: "F0000000-0000-4000-8000-000000000001"),
            SyncTab(id: "AAAAAAAA-0000-4000-8000-000000000004", space: work, order: "D", url: "https://ledger.app/tern/overview", title: "Overview · Ledger", kept: true),
            SyncTab(id: "AAAAAAAA-0000-4000-8000-000000000005", space: work, order: "E", url: "https://news.ycombinator.com", title: "Hacker News"),
            SyncTab(id: "AAAAAAAA-0000-4000-8000-000000000006", space: work, order: "F", url: "http://localhost:5173", title: "Tern · Calm scheduling for busy teams"),
            SyncTab(id: "AAAAAAAA-0000-4000-8000-000000000007", space: work, order: "G", url: "https://lumen.events/e/design-systems-night", title: "Design Systems Night · Stockholm"),
        ]
        for tab in tabs { try mac.write(SyncCollection.tab, tab.id, tab.fields) }
        mac.client.start()
        let up = await until { mac.client.state == .live && mac.pending == 0 }
        XCTAssertTrue(up, "the Mac made the account: \(mac.client.state)")
        return mac
    }

    /// The iPhone, in with the key iCloud Keychain brought.
    private func phone(_ server: SyncMemoryServer, _ seal: Seal, world: World? = nil, onlineFor: TimeInterval = PhoneSync.onlineFor,
                       refreshEvery: TimeInterval = 60, ownWorld: Bool = true, fixturesEnabled: Bool = true,
                       home: URL? = nil) async throws -> AppModel {
        let keys = (home ?? folder).appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: keys.appendingPathComponent("key").path) {
            try seal.raw.write(to: keys.appendingPathComponent("key-shared"))
        }
        let app = AppModel(world: world ?? blank(), fixturesEnabled: fixturesEnabled)
        app.sync.attach(app, setup: setup(server, onlineFor: onlineFor, refreshEvery: refreshEvery, ownWorld: ownWorld, home: home))
        let live = await until { app.sync.line == .live }
        XCTAssertTrue(live, "the iPhone's line: \(app.sync.line)")
        return app
    }

    private func todayIDs(_ app: AppModel, _ space: String) -> [String] {
        app.browser.space(space)?.today.map(\.id) ?? []
    }

    /// This iPhone's device id, the `device` its tabs of today carry.
    private var phoneID: String { SyncKeychain.testing(folder: folder.appendingPathComponent("keys")).deviceID }

    /// The Mac's three tabs of today: there to look into, not in the iPhone's rows.
    private func macToday(_ app: AppModel) -> [String] { app.sync.macTabs(in: work).map(\.title) }
    private let macTitles = ["Hacker News", "Tern · Calm scheduling for busy teams", "Design Systems Night · Stockholm"]

    func testChatAndTabQuestionsSeenAndAnswersTravelThroughTheJournal() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        defer { mac.client.stop() }
        let app = try await phone(server, seal)
        var chat = try AssistantApprovalRecords.Request(
            id: UUID().uuidString.lowercased(), account: seal.account, mac: "mac-a", assistant: "local.external",
            session: "child", tab: "chat:root", permit: "mail.read", title: "Claude: Search your mail?",
            lines: ["Travel plans", "once for this chat"], expires: Date().addingTimeInterval(300))
        let page = try AssistantApprovalRecords.Request(
            id: UUID().uuidString.lowercased(), account: seal.account, mac: "mac-a", assistant: "local.external",
            session: "task", tab: UUID().uuidString.lowercased(), permit: "press:e1", title: "Claude: Continue?",
            lines: ["example.test"], expires: Date().addingTimeInterval(300))
        for request in [chat, page] { try mac.write(AssistantApprovalRecords.requestCollection, request.id, request.fields()) }
        let arrived = await until { app.sync.assistantApprovals.count == 2 }
        XCTAssertTrue(arrived)
        XCTAssertEqual(app.sync.assistantApprovals.first { $0.id == chat.id }?.yesLabel, "Search")
        chat.seen = .init(device: "mac-a")
        try mac.write(AssistantApprovalRecords.requestCollection, chat.id, chat.fields())
        let seen = await until { app.sync.assistantApprovals.first { $0.id == chat.id }?.seen != nil }
        XCTAssertTrue(seen, "opening on Mac leaves the card answerable")
        app.sync.answerAssistantApproval(chat.id, yes: true)
        let key = Record.Key(collection: AssistantApprovalRecords.answerCollection, id: chat.id)
        let answered = await until { mac.journal.record(key)?.alive() == true }
        XCTAssertTrue(answered)
        let answerRecord = try XCTUnwrap(mac.journal.record(key))
        let answer = try AssistantApprovalRecords.Answer.read(answerRecord, request: chat, device: phoneID)
        XCTAssertTrue(answer.yes)
        app.sync.openAssistantApproval(page.id)
        try mac.journal.remove(.init(collection: AssistantApprovalRecords.requestCollection, id: page.id))
        mac.client.kick()
        let closed = await until { app.sync.assistantApprovals.isEmpty && app.sync.assistantApprovalReceipt != nil }
        XCTAssertTrue(closed)
        XCTAssertEqual(app.sync.assistantApprovalReceipt, "Answered on your Mac")
    }

    /// A Mac question asked while the person is at the Mac goes up quiet
    /// (already `seen`): opening Yab here shows it in the tray, answerable,
    /// without a notification; rung once they are away, it notifies, and
    /// the answer given here reaches the Mac (bug 2026-10-22).
    func testAQuietMacQuestionIsInTheTrayAndRingsOnceTheMacSaysSo() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        defer { mac.client.stop() }
        let app = try await phone(server, seal)
        var send = try AssistantApprovalRecords.Request(
            id: UUID().uuidString.lowercased(), account: seal.account, mac: "mac-a", assistant: "local.external",
            session: "task", tab: UUID().uuidString.lowercased(), permit: "mail.send:k", title: "Claude: Send this mail?",
            lines: ["To ann@example.com"], expires: Date().addingTimeInterval(900))
        send.seen = .init(device: "mac-a")
        try mac.write(AssistantApprovalRecords.requestCollection, send.id, send.fields())
        let arrived = await until { app.sync.presentedAssistantApproval?.id == send.id }
        XCTAssertTrue(arrived, "the quiet question is the one the tray shows")
        let inbox: [(identifier: String, approval: String?, thread: String)] = [(send.id, send.id, ApprovalNotice.thread)]
        XCTAssertEqual(ApprovalNotice.stale(inbox, requests: app.sync.assistantApprovals), [send.id], "quiet: no notification for it")
        send.seen = nil
        try mac.write(AssistantApprovalRecords.requestCollection, send.id, send.fields())
        let rung = await until { app.sync.assistantApprovals.first { $0.id == send.id }?.seen == nil }
        XCTAssertTrue(rung)
        XCTAssertTrue(ApprovalNotice.stale(inbox, requests: app.sync.assistantApprovals).isEmpty, "rung: its notification stays")
        app.sync.answerAssistantApproval(send.id, yes: false)
        let key = Record.Key(collection: AssistantApprovalRecords.answerCollection, id: send.id)
        let answered = await until { mac.journal.record(key)?.alive() == true }
        XCTAssertTrue(answered)
        let answer = try AssistantApprovalRecords.Answer.read(try XCTUnwrap(mac.journal.record(key)), request: send, device: phoneID)
        XCTAssertFalse(answer.yes)
        let gone = await until { app.sync.assistantApprovals.isEmpty }
        XCTAssertTrue(gone, "answered here, it leaves the tray")
    }

    // MARK: - joining

    func testTheKeyFromICloudBringsTheMacsSpacesAndRows() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        _ = try await macWithWork(server, seal)
        let app = try await phone(server, seal)
        XCTAssertEqual(app.sync.phase, .on)
        XCTAssertFalse(app.sync.showsJoin, "no step at all")
        let arrived = await until { app.browser.spaces.map(\.name) == ["Personal", "Work"] }
        XCTAssertTrue(arrived, "\(app.browser.spaces.map(\.name))")
        let space = try XCTUnwrap(app.browser.space(work))
        XCTAssertEqual(space.pins.map(\.site), ["Daybook"])
        XCTAssertEqual(space.folders.map(\.name), ["Onboarding v3"])
        XCTAssertEqual(space.folders.first?.tabs.map(\.page), ["figma", "paper-spec"])
        XCTAssertEqual(space.keptTabs.count, 3)
        // Today is each device's own: the Mac's are looked into, not shown.
        XCTAssertEqual(space.today.map(\.title), [])
        XCTAssertEqual(macToday(app), macTitles)
        XCTAssertEqual(app.sync.macTabs(in: work).first { $0.id == "AAAAAAAA-0000-4000-8000-000000000006" }?.url, "http://localhost:5173")
        // The key is this iPhone's now, and its copy for the Macs is there.
        XCTAssertEqual(SyncKeychain.testing(folder: folder.appendingPathComponent("keys")).local?.raw, seal.raw)
    }

    /// #1658: ff1b1bfe0's iPhone follower must join the surviving account.
    func testIPhoneFollowsTheAccountWhenTwoMacAccountsMerge() async throws {
        let defaults = UserDefaults.standard
        let before = defaults.stringArray(forKey: "sync.leftAccounts")
        defaults.removeObject(forKey: "sync.leftAccounts")
        defer { defaults.set(before, forKey: "sync.leftAccounts") }
        let server = SyncMemoryServer(), oldSeal = Seal.make(), destination = Seal.make()
        let oldMac = try await macWithWork(server, oldSeal)
        let survivingMac = try await macWithWork(server, destination)
        defer { oldMac.client.stop(); survivingMac.client.stop() }
        try survivingMac.write(SyncCollection.space, first,
                               SyncSpace(id: first, name: "Surviving account", icon: "", order: "V").fields)
        let app = try await phone(server, oldSeal)
        defer { app.sync.engine?.stop() }
        try oldMac.write(SyncCollection.moved, AccountMove.id, AccountMove.fields(to: destination))
        let followed = await until(8) { app.sync.engine?.seal.account == destination.account && app.sync.line == .live }
        XCTAssertTrue(followed)
        let rebuilt = await until { app.browser.spaces.contains { $0.name == "Surviving account" } }
        XCTAssertTrue(rebuilt)
        XCTAssertEqual(SyncKeychain.testing(folder: folder.appendingPathComponent("keys")).local?.raw, destination.raw)
        app.sync.end()
        let again = try await phone(server, destination)
        defer { again.sync.engine?.stop() }
        XCTAssertEqual(again.sync.engine?.seal.account, destination.account)
    }

    func testTheRecoveryKeyLetsTheIPhoneIn() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        _ = try await macWithWork(server, seal)
        let app = AppModel(world: blank())
        app.sync.attach(app, setup: setup(server))
        guard case .joining(.code(let code)) = app.sync.phase else { return XCTFail("no code shown: \(app.sync.phase)") }
        XCTAssertEqual(code.count, 9)
        XCTAssertTrue(app.sync.showsJoin)
        app.sync.showRecovery(true)
        XCTAssertFalse(app.sync.useRecovery("ABCD-EFGH-1234"))
        XCTAssertEqual(app.sync.phase, .joining(.recovery(wrong: true)))
        XCTAssertTrue(app.sync.useRecovery(seal.recovery.lowercased().replacingOccurrences(of: "-", with: " ")))
        XCTAssertEqual(app.sync.phase, .on)
        let arrived = await until { self.macToday(app).count == 3 }
        XCTAssertTrue(arrived)
        XCTAssertEqual(Haptics.played.suffix(2).map(\.kind), [.error, .success])
    }

    func testARemovedIPhoneIsToldAndJoinsAgainAsNew() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        _ = try await macWithWork(server, seal)
        let app = try await phone(server, seal)
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        let id = keys.deviceID
        server.revoke(id)
        let told = await until { app.sync.phase == .refused("This iPhone was removed from Sync.") }
        XCTAssertTrue(told, "\(app.sync.phase)")
        XCTAssertTrue(app.sync.showsJoin)
        app.sync.joinAgain()
        guard case .joining(.code) = app.sync.phase else { return XCTFail("\(app.sync.phase)") }
        XCTAssertNil(keys.local)
        XCTAssertNotEqual(keys.deviceID, id, "a removed id is refused for good: it comes back as new")
    }

    // MARK: - the Mac's changes

    func testATabOfTheMacsTodayStaysThereAndComesOnceKept() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal)
        _ = await until { self.macToday(app).count == 3 }
        let linear = "BBBBBBBB-0000-4000-8000-000000000001"
        var tab = SyncTab(id: linear, space: work, order: "DV", url: "https://linear.app/tern/issue/ENG-412/invite-flow",
                          title: "ENG-412 · Invite flow · Linear")
        try mac.write(SyncCollection.tab, linear, tab.fields)
        // The Mac's tab of today: looked into from here, never in the rows.
        let there = await until { self.macToday(app).contains("ENG-412 · Invite flow · Linear") }
        XCTAssertTrue(there, "\(macToday(app))")
        XCTAssertNil(app.browser.tab(linear))
        // Kept on the Mac: everyone's, so here too, with its page.
        tab.kept = true
        try mac.write(SyncCollection.tab, linear, tab.fields)
        let sent = Date()
        let arrived = await until { app.browser.space(self.work)?.keptTabs.contains { $0.id == linear } == true }
        XCTAssertTrue(arrived)
        print("Mac keeps a tab -> in the iPhone's column: \(Int(Date().timeIntervalSince(sent) * 1000)) ms (in memory)")
        XCTAssertEqual(app.browser.tab(linear)?.page, "linear-invite")
        XCTAssertFalse(macToday(app).contains("ENG-412 · Invite flow · Linear"))
        mac.front = ("https://linear.app/tern/issue/ENG-412/invite-flow", "ENG-412 · Invite flow · Linear", linear)
        mac.client.sayPresence()
        let marked = await until { app.browser.onMac?.id == linear }
        XCTAssertTrue(marked)
        XCTAssertEqual(app.sync.frontTab, linear)
        // Closed on the Mac: gone here.
        app.browser.select(linear)
        try mac.remove(linear)
        let gone = await until { app.browser.tab(linear) == nil }
        XCTAssertTrue(gone)
    }

    /// Request 1260: a zero-tab iPhone neither takes the Mac's tabs with it
    /// nor gets its closed ones back, and nothing steps forward on it.
    func testAZeroTabIPhoneLosesNothingAndGetsNothingBack() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal)
        _ = await until { self.macToday(app).count == 3 }
        app.browser.showSpace(work)
        app.browser.open(Tab(id: "mine-1", title: "Opened here", site: "Example", icon: "example", url: "example.com/mine"))
        let up = await until { mac.row(self.work).today.contains { $0.url == "https://example.com/mine" } }
        XCTAssertTrue(up)
        let keptBefore = mac.row(work).kept.map(\.id).sorted()
        let pinsBefore = mac.row(work).pins.map(\.id).sorted()
        let macBefore = mac.row(work).today.filter { $0.device != self.phoneID }.map(\.id).sorted()

        for tab in try XCTUnwrap(app.browser.space(work)?.today) { app.browser.close(tab.id) }
        app.sync.flushLocal()
        XCTAssertNil(app.browser.tab)
        let closed = await until { mac.pending == 0 && !mac.row(self.work).today.contains { $0.url == "https://example.com/mine" } }
        XCTAssertTrue(closed, "this iPhone's tab closes for the account")
        XCTAssertEqual(mac.row(work).kept.map(\.id).sorted(), keptBefore, "kept tabs stay")
        XCTAssertEqual(mac.row(work).pins.map(\.id).sorted(), pinsBefore, "pins stay")
        XCTAssertEqual(mac.row(work).today.filter { $0.device != self.phoneID }.map(\.id).sorted(), macBefore, "the Mac's today stays")

        // The Mac opens another: the closed one stays closed, nothing comes in front.
        let id = "AAAAAAAA-0000-4000-8000-000000000099"
        try mac.write(SyncCollection.tab, id, SyncTab(id: id, space: work, order: "Z", url: "https://example.com/later", title: "Later").fields)
        let came = await until { self.macToday(app).contains("Later") }
        XCTAssertTrue(came)
        XCTAssertEqual(app.browser.space(work)?.today.map(\.url), [], "closed tabs don't come back")
        XCTAssertNil(app.browser.tab, "the empty page stays")
        XCTAssertEqual(mac.row(work).kept.map(\.id).sorted(), keptBefore)
    }

    func testClearOnTheMacLeavesTheIPhonesOwn() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal)
        _ = await until { self.macToday(app).count == 3 }
        app.browser.showSpace(work)
        app.browser.open(Tab(id: "mine-1", title: "Opened here", site: "Example", icon: "example", url: "example.com/mine"))
        let up = await until { mac.row(self.work).today.contains { $0.url == "https://example.com/mine" } }
        XCTAssertTrue(up)
        for tab in mac.row(work).today where tab.device != self.phoneID { try mac.remove(tab.id) }
        let cleared = await until { self.macToday(app).isEmpty }
        XCTAssertTrue(cleared)
        XCTAssertEqual(app.browser.space(work)?.today.map(\.title), ["Opened here"], "this iPhone's stay")
        XCTAssertEqual(app.browser.space(work)?.keptTabs.count, 3, "the kept stay")
    }

    func testPhoneNamesAndNestedFoldersRoundTripWithoutDuplicates() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        defer { mac.client.stop() }
        let app = try await phone(server, seal)
        let tid = "AAAAAAAA-0000-4000-8000-000000000004"
        let loaded = await until { app.browser.tab(app.sync.localID(tid)) != nil }
        XCTAssertTrue(loaded)
        app.browser.showSpace(work)
        let local = app.sync.localID(tid)
        XCTAssertTrue(app.browser.renameTab(local, to: "My saved page"))
        let parent = try XCTUnwrap(app.browser.createFolder(name: "Research", in: work))
        let child = try XCTUnwrap(app.browser.createFolder(name: "Sources", in: work, parent: parent))
        XCTAssertTrue(app.browser.moveIntoFolder(local, in: work, to: child))
        app.sync.flushLocal()
        let fid = try XCTUnwrap(app.sync.syncSpace(child)), pid = try XCTUnwrap(app.sync.syncSpace(parent))
        let received = await until { mac.row(self.work).folders[fid]?.folder == pid && mac.row(self.work).kept.first(where: { $0.id == tid })?.name == "My saved page" }
        XCTAssertTrue(received)
        XCTAssertEqual(mac.row(work).kept.first { $0.id == tid }?.title, "Overview · Ledger")
        XCTAssertEqual(mac.row(work).kept.first { $0.id == tid }?.folder, fid)
        XCTAssertEqual(mac.row(work).folders.count, 3)
        for _ in 0..<3 { app.sync.flushLocal() }
        XCTAssertEqual(mac.row(work).folders.count, 3)
        try mac.write("tab", tid, ["name": .string("Named on Mac")])
        let renamed = await until { app.browser.tab(local)?.title == "Named on Mac" }
        XCTAssertTrue(renamed)
        XCTAssertTrue(app.browser.renameTab(local, to: nil))
        XCTAssertTrue(app.browser.renameFolder(child, in: work, to: "References"))
        app.sync.flushLocal()
        let reset = await until { mac.row(self.work).kept.first(where: { $0.id == tid })?.name == nil && mac.row(self.work).folders[fid]?.name == "References" }
        XCTAssertTrue(reset)
        XCTAssertEqual(app.browser.tab(local)?.title, "Overview · Ledger")
        XCTAssertTrue(app.browser.deleteFolder(parent, in: work))
        app.sync.flushLocal()
        let promoted = await until { mac.row(self.work).folders[pid] == nil && mac.row(self.work).folders[fid]?.folder == nil }
        XCTAssertTrue(promoted)
        XCTAssertTrue(app.browser.deleteFolder(child, in: work))
        app.sync.flushLocal()
        let dissolved = await until { mac.row(self.work).folders[fid] == nil && mac.row(self.work).kept.first(where: { $0.id == tid })?.folder == nil }
        XCTAssertTrue(dissolved)
        XCTAssertEqual(mac.row(work).all.count, 7)
    }

    func testProfileLinkSurvivesMacToPhoneRenameAndExplicitDetach() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        defer { mac.client.stop() }
        let member = "BBBBBBBB-0000-4000-8000-000000002329"
        try mac.write(SyncCollection.space, work, SyncSpace(id: work, name: "Work", icon: "💼", ownSignIns: true, order: "X").fields)
        try mac.write(SyncCollection.space, member, SyncSpace(id: member, name: "Projects", icon: "📁", ownSignIns: true, order: "Z", signInWith: work).fields)
        let app = try await phone(server, seal)
        defer { app.sync.engine?.stop() }
        let loaded = await until { app.browser.space(member)?.signInWith == self.work }
        XCTAssertTrue(loaded)
        XCTAssertEqual(app.browser.space(member)?.signInWith, work)
        app.browser.setSpace(member, name: "Renamed on iPhone")
        app.sync.flushLocal()
        let renamed = await until { mac.journal.record(.init(collection: SyncCollection.space, id: member))?["name"]?.string == "Renamed on iPhone" }
        XCTAssertTrue(renamed)
        XCTAssertEqual(mac.journal.record(.init(collection: SyncCollection.space, id: member))?["signInWith"]?.string, work)
        try mac.write(SyncCollection.space, member, SyncSpace(id: member, name: "Renamed on iPhone", icon: "📁", ownSignIns: true, order: "Z").fields)
        let detached = await until { app.browser.space(member)?.signInWith == nil }
        XCTAssertTrue(detached)
        XCTAssertTrue(app.browser.space(member)?.ownSignIns == true)
    }

    // MARK: - the iPhone's changes

    /// #1479: the Mac publishes shared pins once, under Personal.
    func testSharedPinsAppearWithoutMovingTheirCanonicalRecord() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        defer { mac.client.stop() }
        let pinID = "AAAAAAAA-0000-4000-8000-000000001479"
        let own = "BBBBBBBB-0000-4000-8000-000000001479"
        try mac.write(SyncCollection.tab, pinID,
                      SyncTab(id: pinID, space: first, order: "A", url: "https://shared.test/pin", title: "Shared", pin: "S").fields)
        try mac.write(SyncCollection.space, own,
                      SyncSpace(id: own, name: "Separate", icon: "", ownSignIns: true, order: "Z").fields)
        try mac.write(SyncCollection.setting, SyncBridge.sharedPinsKey, ["value": .bool(true)])
        let app = try await phone(server, seal)
        defer { app.sync.engine?.stop() }
        let loaded = await until { app.sync.sharesPins && app.browser.tab(app.sync.localID(pinID)) != nil && app.browser.space(own) != nil }
        XCTAssertTrue(loaded)
        let workSpace = try XCTUnwrap(app.browser.space(work))
        let ownSpace = try XCTUnwrap(app.browser.space(own))
        XCTAssertEqual(app.sync.pins(in: workSpace).map(\.id), [app.sync.localID(pinID), app.sync.localID("AAAAAAAA-0000-4000-8000-000000000001")])
        XCTAssertTrue(app.sync.pins(in: ownSpace).isEmpty)
        XCTAssertEqual(app.browser.allTabs.filter { $0.id == app.sync.localID(pinID) }.count, 1)
        app.chooseFromSpacePage(app.sync.localID(pinID), in: work)
        XCTAssertEqual(app.browser.spaceID, work)
        XCTAssertEqual(app.browser.tab?.navigationURL?.absoluteString, "https://shared.test/pin")
        XCTAssertNotEqual(app.browser.tab?.id, app.sync.localID(pinID))
        app.sync.flushLocal()
        let unchanged = SyncTab(try XCTUnwrap(mac.journal.record(.init(collection: SyncCollection.tab, id: pinID))))
        XCTAssertEqual(unchanged?.space, first)
        XCTAssertEqual(unchanged?.list, .pinned)
        XCTAssertEqual(app.sync.engine?.tab(pinID)?.space, first)
        XCTAssertEqual(app.sync.engine?.tab(pinID)?.list, .pinned)

        // A remote change updates the projection, including turning it off.
        try mac.write(SyncCollection.setting, SyncBridge.sharedPinsKey, ["value": .bool(false)])
        let disabled = await until { !app.sync.sharesPins }
        XCTAssertTrue(disabled)
        XCTAssertEqual(app.sync.pins(in: workSpace).map(\.id), workSpace.visiblePins.map(\.id))
    }

    /// Row 2602: six pins on the Mac, three of them shared (Personal's) and
    /// three still Work's own, as sync carries them until the Mac joins them
    /// (or the iPhone pinned one there). The Mac's Work shows all six; the
    /// iPhone showed the three shared ones in their place.
    func testASharingSpaceShowsItsOwnPinsAfterTheSharedOnes() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        defer { mac.client.stop() }
        let shared = (1...3).map { n in
            SyncTab(id: "AAAAAAAA-0000-4000-8000-00000000260\(n)", space: first, order: "A\(n)",
                    url: "https://shared\(n).test/", title: "Shared \(n)", pin: "S")
        }
        let own = [
            SyncTab(id: "AAAAAAAA-0000-4000-8000-000000002611", space: work, order: "A1", url: "https://own1.test/", title: "Own 1", pin: "O"),
            SyncTab(id: "AAAAAAAA-0000-4000-8000-000000002612", space: work, order: "A2", url: "https://own2.test/", title: "Own 2", pin: "O"),
            // At a shared pin's address: the Mac closes it as it joins, so it isn't shown twice.
            SyncTab(id: "AAAAAAAA-0000-4000-8000-000000002613", space: work, order: "A3", url: "https://shared2.test/", title: "Again", pin: "S"),
        ]
        for tab in shared + own { try mac.write(SyncCollection.tab, tab.id, tab.fields) }
        try mac.write(SyncCollection.setting, SyncBridge.sharedPinsKey, ["value": .bool(true)])
        let app = try await phone(server, seal)
        defer { app.sync.engine?.stop() }
        let loaded = await until {
            app.sync.sharesPins && app.browser.space(self.work)?.pins.count == 4
                && app.browser.space(app.sync.localID(self.first))?.pins.count == 3
        }
        XCTAssertTrue(loaded)
        let workSpace = try XCTUnwrap(app.browser.space(work))
        let daybook = "AAAAAAAA-0000-4000-8000-000000000001"
        XCTAssertEqual(app.sync.pins(in: workSpace).map(\.id),
                       (shared.map(\.id) + [daybook, own[0].id, own[1].id]).map(app.sync.localID))
        // Personal shows its own row as it is.
        XCTAssertEqual(app.sync.pins(in: try XCTUnwrap(app.browser.space(app.sync.localID(first)))).map(\.id), shared.map(\.id).map(app.sync.localID))
        // A pin made on the iPhone in Work stands among them at once.
        let kept = app.sync.localID("AAAAAAAA-0000-4000-8000-000000000004")
        ColumnState.of(app).pin(kept)
        let pinned = await until { app.sync.pins(in: app.browser.space(self.work)!).contains { $0.id == kept } }
        XCTAssertTrue(pinned)
    }

    func testSharedPinsSurviveDeletedPersonalWithoutRevivingOrMovingIt() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        defer { mac.client.stop() }
        let pinID = "AAAAAAAA-0000-4000-8000-000000001480"
        try mac.write(SyncCollection.tab, pinID,
                      SyncTab(id: pinID, space: first, url: "https://shared.test/virtual", title: "Virtual", pin: "V").fields)
        try mac.write(SyncCollection.setting, SyncBridge.sharedPinsKey, ["value": .bool(true)])
        try mac.journal.remove(.init(collection: SyncCollection.space, id: first))
        mac.client.kick()
        let app = try await phone(server, seal)
        defer { app.sync.engine?.stop() }
        let loaded = await until { app.sync.sharesPins && app.sync.pins(in: app.browser.space).contains { $0.id == pinID } }
        XCTAssertTrue(loaded)
        XCTAssertNil(app.browser.space(app.sync.localID(first)))
        app.sync.flushLocal()
        XCTAssertEqual(app.sync.engine?.tab(pinID)?.space, first)
        XCTAssertEqual(app.sync.engine?.tab(pinID)?.list, .pinned)
        app.chooseFromSpacePage(pinID, in: work)
        XCTAssertEqual(app.browser.spaceID, work)
        XCTAssertEqual(app.browser.tab?.navigationURL?.absoluteString, "https://shared.test/virtual")
        ColumnState.of(app).unpin(pinID)
        XCTAssertEqual(app.sync.engine?.tab(pinID)?.list, .today)
        XCTAssertEqual(app.sync.engine?.tab(pinID)?.space, work)
        XCTAssertTrue(app.sync.pins(in: try XCTUnwrap(app.browser.space(work))).allSatisfy { $0.id != pinID })
    }

    /// A hold on a shared pin whose Personal was deleted here: no tab here
    /// owns it, as a tap on it, Duplicate Tab and Ask About Page open it in
    /// the space whose page shows it. The pin stays Personal's.
    func testHoldingASharedPinWithoutItsPersonalCopiesItIntoTheSpaceShowingIt() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        defer { mac.client.stop() }
        let pinID = "AAAAAAAA-0000-4000-8000-000000001481"
        let url = "https://shared.test/held"
        try mac.write(SyncCollection.tab, pinID,
                      SyncTab(id: pinID, space: first, url: url, title: "Held", pin: "H").fields)
        try mac.write(SyncCollection.setting, SyncBridge.sharedPinsKey, ["value": .bool(true)])
        try mac.journal.remove(.init(collection: SyncCollection.space, id: first))
        mac.client.kick()
        let app = try await phone(server, seal)
        defer { app.sync.engine?.stop() }
        let loaded = await until { app.sync.sharesPins && app.browser.space(self.work).map { app.sync.pins(in: $0).contains { $0.id == pinID } } == true }
        XCTAssertTrue(loaded)
        let pin = try XCTUnwrap(app.sync.pins(in: try XCTUnwrap(app.browser.space(work))).first { $0.id == pinID })
        XCTAssertNil(app.browser.space(holding: pinID), "no space here owns it")
        func copies() -> [Tab] { app.browser.space(work)?.allTabs.filter { $0.navigationURL?.absoluteString == url } ?? [] }

        let duplicate = try XCTUnwrap(TabHold.pageItems(pin, app: app, page: work).first { $0.title == "Duplicate Tab" })
        duplicate.run()
        XCTAssertEqual(copies().count, 1)
        XCTAssertEqual(app.browser.spaceID, work)
        XCTAssertEqual(app.browser.tab?.navigationURL?.absoluteString, url, "the copy comes in front")
        XCTAssertNotEqual(app.browser.tab?.id, pinID)
        duplicate.run()
        XCTAssertEqual(copies().count, 2, "each Duplicate Tab is a new copy")

        app.browser.select(try XCTUnwrap(app.browser.space(work)?.allTabs.first { $0.navigationURL?.absoluteString != url }?.id))
        TabHold.ask(pin, app: app, page: work)
        XCTAssertEqual(app.browser.tab?.navigationURL?.absoluteString, url, "Ask About Page asks about the pin's page")

        app.sync.flushLocal()
        XCTAssertEqual(app.sync.engine?.tab(pinID)?.space, first)
        XCTAssertEqual(app.sync.engine?.tab(pinID)?.list, .pinned)
    }

    /// With Personal here, a shared pin held on another sharing space's
    /// page is copied into that space, as a tap there opens it there.
    func testDuplicatingASharedPinStaysInTheSpaceShowingIt() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        defer { mac.client.stop() }
        let pinID = "AAAAAAAA-0000-4000-8000-000000001482"
        let url = "https://shared.test/owned"
        try mac.write(SyncCollection.tab, pinID,
                      SyncTab(id: pinID, space: first, order: "A", url: url, title: "Owned", pin: "O").fields)
        try mac.write(SyncCollection.setting, SyncBridge.sharedPinsKey, ["value": .bool(true)])
        let app = try await phone(server, seal)
        defer { app.sync.engine?.stop() }
        let local = app.sync.localID(pinID)
        let loaded = await until { app.sync.sharesPins && app.browser.tab(local) != nil && app.browser.space(self.work) != nil }
        XCTAssertTrue(loaded)
        let pin = try XCTUnwrap(app.sync.pins(in: try XCTUnwrap(app.browser.space(work))).first { $0.id == local })
        XCTAssertNotEqual(app.browser.space(holding: local)?.id, work, "Personal owns it")

        try XCTUnwrap(TabHold.pageItems(pin, app: app, page: work).first { $0.title == "Duplicate Tab" }).run()
        XCTAssertEqual(app.browser.spaceID, work)
        XCTAssertEqual(app.browser.tab?.navigationURL?.absoluteString, url)
        XCTAssertNotEqual(app.browser.tab?.id, local)
        XCTAssertEqual(app.browser.space(holding: local)?.pins.filter { $0.navigationURL?.absoluteString == url }.count, 1,
                       "Personal keeps only its pin")
    }

    func testPhonePinsAndUnpinsReachTheMac() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal)
        let tabID = "AAAAAAAA-0000-4000-8000-000000000003"
        let loaded = await until { app.browser.space(self.work)?.keptTabs.contains { $0.id == app.sync.localID(tabID) } == true }
        XCTAssertTrue(loaded)
        let local = app.sync.localID(tabID)
        app.browser.pin(local)
        app.sync.flushLocal()
        var received = await until { mac.row(self.work).pins.last?.id == tabID }
        XCTAssertTrue(received)
        let pin = try XCTUnwrap(mac.row(work).pins.first { $0.id == tabID })
        XCTAssertEqual(pin.pin, "P")
        XCTAssertFalse(pin.kept)
        XCTAssertNil(pin.folder)
        XCTAssertNil(pin.device)
        app.browser.unpin(local)
        app.sync.flushLocal()
        received = await until { mac.row(self.work).today.first { $0.id == tabID }?.device == self.phoneID }
        XCTAssertTrue(received)
        XCTAssertNil(mac.row(work).today.first { $0.id == tabID }?.pin)
        XCTAssertFalse(mac.row(work).pins.contains { $0.id == tabID })

        // Open and pin before the bridge has written the new tab once.
        app.browser.showSpace(work)
        app.browser.open(Tab(id: "instant-pin", title: "Example", site: "Example", icon: "example", url: "https://www.example.com/pin"))
        app.browser.pin("instant-pin")
        app.sync.flushLocal()
        received = await until { mac.row(self.work).pins.contains { SyncMapping.address($0.url) == "example.com/pin" } }
        XCTAssertTrue(received, "pins: \(mac.row(work).pins.map(\.url))")
        let immediate = try XCTUnwrap(mac.row(work).pins.first { SyncMapping.address($0.url) == "example.com/pin" })
        XCTAssertEqual(immediate.pin, "E")
        XCTAssertNil(immediate.device)
        app.sync.engine?.stop()
        mac.client.stop()
    }

    func testTheIPhonesChangesReachTheMac() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal)
        _ = await until { self.macToday(app).count == 3 }
        let macs = mac.row(work).today.map(\.id)
        app.browser.showSpace(work)
        func own(_ url: String) -> SyncTab? { mac.row(self.work).today.first { $0.url == url } }
        func local(_ url: String) -> String? { app.browser.space(self.work)?.today.first { SyncMapping.fullURL($0.url ?? "") == url }?.id }

        // Opened here, with an id of the app's own: a UUID, this iPhone's tab of today.
        let urls = ["https://google.com/search?q=lisbon+weather+october", "https://a.test/one", "https://b.test/two"]
        for (n, url) in urls.enumerated() {
            app.browser.open(Tab(id: "field-\(n)", title: "Here \(n)", site: "Here", icon: "example", url: String(url.dropFirst(8))))
        }
        var done = await until { urls.allSatisfy { own($0) != nil } }
        XCTAssertTrue(done, "\(mac.row(work).today.map(\.url))")
        XCTAssertNotNil(UUID(uuidString: own(urls[0])?.id ?? ""))
        XCTAssertEqual(own(urls[0])?.device, phoneID)

        // Closed here: gone on the Mac.
        app.browser.close(try XCTUnwrap(local(urls[1])))
        done = await until { own(urls[1]) == nil }
        XCTAssertTrue(done, "closed")

        // Kept here: everyone's, under the Mac's kept tabs; unkept: this iPhone's again, on top.
        let first = try XCTUnwrap(own(urls[0])?.id)
        app.browser.keep(try XCTUnwrap(local(urls[0])))
        done = await until { mac.row(self.work).kept.last?.id == first }
        XCTAssertTrue(done, "kept: \(mac.row(work).kept.map(\.title))")
        XCTAssertNil(mac.row(work).kept.last?.device)
        app.browser.unkeep(app.sync.localID(first))
        done = await until { own(urls[0])?.device == self.phoneID }
        XCTAssertTrue(done, "unkept: \(mac.row(work).today.map(\.title))")

        // Put in a new place of its list.
        let third = try XCTUnwrap(local(urls[2]))
        app.browser.reorder(third, to: 0)
        done = await until { mac.row(self.work).today.filter { $0.device == self.phoneID }.first?.url == urls[2] }
        XCTAssertTrue(done, "reordered")

        // To another space: the top of its today's.
        app.browser.move(app.sync.localID(first), to: self.first)
        done = await until { mac.row(self.first).today.first?.id == first }
        XCTAssertTrue(done, "moved")

        // Clear: this iPhone's tabs of today go, all but the tab in front;
        // the Mac's, the kept and the pins stay.
        app.browser.select(third)
        app.browser.clearToday(in: work)
        done = await until { mac.row(self.work).today.filter { $0.device == self.phoneID }.map(\.url) == [urls[2]] }
        XCTAssertTrue(done, "cleared: \(mac.row(work).today.map(\.title))")
        XCTAssertEqual(Set(mac.row(work).today.map(\.id)).intersection(macs).count, 3, "the Mac's stay")
        XCTAssertEqual(mac.row(work).kept.count, 3, "the kept stay")
        XCTAssertEqual(mac.row(work).pins.count, 1, "and the pins")
    }

    func testSpaceSwitchesAndRemoteUpdatesKeepEveryMobileTodayTab() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        defer { mac.client.stop() }
        let app = try await phone(server, seal, fixturesEnabled: false)
        let arrived = await until { app.browser.space(self.work) != nil && app.browser.space(self.first) != nil }
        XCTAssertTrue(arrived)
        app.field.openSpaces()
        for space in [first, work] {
            app.selectSpacePage(space)
            for n in 0..<2 {
                app.browser.open(Tab(id: UUID().uuidString, title: "Mobile \(n)", site: "Fixture", icon: "globe",
                                     url: "https://example.test/\(space)/\(n)"))
            }
            app.sync.flushLocal()
        }
        await settle(mac, app)
        let before = [first, work].compactMap { app.browser.space($0) }
        XCTAssertEqual(before.count, 2)
        XCTAssertTrue(before.allSatisfy { $0.today.count == 2 })
        let remoteIDs = Set(mac.row(work).today.filter { $0.device != phoneID }.map(\.id))
        for round in 0..<2 {
            app.selectSpacePage(first)
            app.sync.flushLocal()
            app.selectSpacePage(work)
            try mac.write(SyncCollection.space, work, ["name": .string("Work \(round)")])
            let changed = await until { app.browser.space(self.work)?.name == "Work \(round)" }
            XCTAssertTrue(changed)
            app.selectSpacePage(first)
            await settle(mac, app)
            for space in before {
                XCTAssertEqual(app.browser.space(space.id)?.today.map(\.id), space.today.map(\.id))
                XCTAssertEqual(app.browser.space(space.id)?.current, space.current)
                XCTAssertEqual(Set(mac.row(space.id).today.filter { $0.device == phoneID }.map(\.id)),
                               Set(space.today.map(\.id)))
            }
            XCTAssertEqual(Set(mac.row(work).today.filter { $0.device != phoneID }.map(\.id)), remoteIDs)
        }
    }

    /// Delete Space here: the space, its tabs and folder go on the Mac too.
    /// The Mac's first space and the last one stay.
    func testASpaceDeletedHereIsGoneOnTheMac() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal)
        _ = await until { app.browser.space(self.work) != nil && app.sync.syncSpace(self.work) != nil }
        let firstLocal = app.sync.localID(first)
        XCTAssertFalse(app.sync.mayDeleteSpace(firstLocal), "the Mac's first space stays")
        XCTAssertTrue(app.sync.mayDeleteSpace(work))
        app.browser.showSpace(work)
        app.sync.deleteSpace(work)
        XCTAssertNil(app.browser.space(work))
        XCTAssertEqual(app.browser.spaceID, firstLocal, "the one above comes on screen")
        let gone = await until {
            !mac.journal.living(SyncCollection.space).contains { $0.id == self.work }
                && mac.row(self.work).all.isEmpty && mac.row(self.work).folders.isEmpty
        }
        XCTAssertTrue(gone, "\(mac.row(work).all.map(\.title))")
        XCTAssertEqual(mac.journal.living(SyncCollection.space).map(\.id), [first])
        app.sync.flushLocal()
        XCTAssertNil(app.browser.space(work), "sync doesn't bring it back")
    }

    /// A reinstall's untouched starting Personal joins an account with
    /// spaces as nothing: each reinstall once added another empty one.
    func testAFreshInstallsStartingSpaceIsNotAddedToTheAccount() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let start = BrowserProfile.Snapshot.empty()
        let app = try await phone(server, seal, world: World(name: "profile", space: start.spaceID, spaces: start.spaces), fixturesEnabled: false)
        let came = await until { app.browser.space(self.work) != nil }
        XCTAssertTrue(came)
        app.sync.flushLocal()
        _ = await until { mac.pending == 0 && app.sync.engine?.journal.pending(limit: 100).isEmpty == true }
        XCTAssertNil(app.browser.space(BrowserProfile.startSpace))
        XCTAssertEqual(Set(mac.journal.living(SyncCollection.space).map(\.id)), [first, work])
    }

    // MARK: - one Personal (register row 361)

    /// A new profile's world with the starting Personal, a page opened in
    /// it before joining when `used`.
    private func startWorld(used: String? = nil) -> World {
        var start = BrowserProfile.Snapshot.empty()
        if let used {
            let tab = Tab(id: "local.used.\(UUID().uuidString.prefix(6))", title: used, site: used, icon: "globe", url: used)
            start.spaces[0].today.append(tab)
            start.spaces[0].current = tab.id
        }
        return World(name: "profile", space: start.spaceID, spaces: start.spaces)
    }

    private func spaceNames(_ mac: TestMac) -> [String] {
        mac.journal.living(SyncCollection.space).compactMap(SyncSpace.init).map(\.name).sorted()
    }

    private func settle(_ mac: TestMac, _ apps: AppModel...) async {
        for app in apps { app.sync.flushLocal() }
        _ = await until { mac.pending == 0 && apps.allSatisfy { $0.sync.engine?.journal.pending(limit: 100).isEmpty == true } }
    }

    /// Fresh install, a page opened, then joined: that page is in the
    /// account's Personal, and no second Personal is made.
    func testAStartingSpaceUsedBeforeJoiningGoesIntoTheAccountsPersonal() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal, world: startWorld(used: "https://example.com/before-join"), fixturesEnabled: false)
        let came = await until { app.browser.space(self.work) != nil }
        XCTAssertTrue(came)
        await settle(mac, app)
        XCTAssertNil(app.browser.space(BrowserProfile.startSpace), "the starting space became the account's")
        XCTAssertEqual(app.browser.spaces.filter { !$0.isPrivate && $0.name == "Personal" }.count, 1)
        XCTAssertEqual(spaceNames(mac), ["Personal", "Work"])
        let arrived = await until { mac.row(self.first).all.contains { $0.url == "https://example.com/before-join" } }
        XCTAssertTrue(arrived, "the page went into the first space: \(mac.row(first).all.map(\.url))")
        XCTAssertEqual(app.browser.spaceID, app.sync.localID(first), "the page in front stays in front")
    }

    /// A catch-up longer than a page, the first space written last: the
    /// page with only Work is not the account yet, and joining then made a
    /// second Personal (an iPad showed two houses in its foot).
    func testAStartingSpaceUsedBeforeJoiningWaitsForTheWholeCatchUp() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal)
        try mac.write(SyncCollection.space, work, SyncSpace(id: work, name: "Work", icon: "💼", order: "X").fields)
        mac.client.start()
        let up = await until { mac.client.state == .live && mac.pending == 0 }
        XCTAssertTrue(up, "the Mac made the account: \(mac.client.state)")
        // Written in turn, so the server's order is Work, more than a page, Personal.
        for i in 0..<600 { try mac.write(SyncCollection.memory, "memory-\(i)", ["text": .string("note \(i)")]) }
        _ = await until { mac.pending == 0 }
        try mac.write(SyncCollection.space, first, SyncSpace(id: first, name: "Personal", icon: "🏠", order: "V").fields)
        _ = await until { mac.pending == 0 }
        let app = try await phone(server, seal, world: startWorld(used: "https://example.com/before-join"), fixturesEnabled: false)
        await settle(mac, app)
        XCTAssertEqual(spaceNames(mac), ["Personal", "Work"])
        XCTAssertEqual(app.browser.spaces.filter { !$0.isPrivate && $0.name == "Personal" }.count, 1)
        let arrived = await until { mac.row(self.first).all.contains { $0.url == "https://example.com/before-join" } }
        XCTAssertTrue(arrived, "the page went into the first space: \(mac.row(first).all.map(\.url))")
    }

    /// The same catch-up cut after its first page (Work in, the first space
    /// not yet), then a launch: the saved journal holds spaces, but they
    /// are not the account yet. The launch waits for the whole catch-up,
    /// and no second Personal is ever written.
    func testALaunchAfterAnInterruptedFirstCatchUpWaitsForTheWholeOne() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal)
        try mac.write(SyncCollection.space, work, SyncSpace(id: work, name: "Work", icon: "💼", order: "X").fields)
        mac.client.start()
        let up = await until { mac.client.state == .live && mac.pending == 0 }
        XCTAssertTrue(up, "the Mac made the account: \(mac.client.state)")
        for i in 0..<600 { try mac.write(SyncCollection.memory, "memory-\(i)", ["text": .string("note \(i)")]) }
        _ = await until { mac.pending == 0 }
        try mac.write(SyncCollection.space, first, SyncSpace(id: first, name: "Personal", icon: "🏠", order: "V").fields)
        _ = await until { mac.pending == 0 }

        let profile = BrowserProfile(folder: folder.appendingPathComponent("browser"))
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        app.browser.open(PageFixtures.liveTab(for: URL(string: "https://example.com/before-join")!))
        SyncKeychain.testing(folder: folder.appendingPathComponent("keys")).keep(seal, share: false)
        server.catchUpPages = 1
        app.sync.attach(app, setup: setup(server, ownWorld: false))
        let half = await until { app.sync.engine?.journal.living(SyncCollection.space).contains { $0.id == self.work } == true }
        XCTAssertTrue(half, "the first page came")
        XCTAssertNotEqual(app.sync.line, .live)
        XCTAssertFalse(app.sync.writing, "a page of the catch-up is not the account")
        await app.flushProfile()
        app.sync.end()

        server.catchUpPages = nil
        let again = await relaunch(server, profile.folder)
        await settle(mac, again)
        XCTAssertEqual(Set(mac.journal.all(SyncCollection.space).map(\.id)), [first, work], "no second Personal, not even for a moment")
        XCTAssertEqual(again.browser.spaces.filter { !$0.isPrivate && $0.name == "Personal" }.count, 1)
        let arrived = await until { mac.row(self.first).all.contains { $0.url == "https://example.com/before-join" } }
        XCTAssertTrue(arrived, "the page went into the first space: \(mac.row(first).all.map(\.url))")
        again.sync.end()
    }

    /// An iPhone that has been in the account takes it at once on a launch
    /// with no network: caught up once is enough, and so is an association
    /// saved before the mark was kept (an install joined on an older build).
    func testAJoinedIPhoneTakesTheAccountOfflineOldInstallsToo() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let profile = BrowserProfile(folder: folder.appendingPathComponent("browser"))
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        app.browser.open(PageFixtures.liveTab(for: URL(string: "https://example.com/joined")!))
        SyncKeychain.testing(folder: folder.appendingPathComponent("keys")).keep(seal, share: false)
        app.sync.attach(app, setup: setup(server, ownWorld: false))
        let joined = await until(8) { app.sync.line == .live && app.sync.writing }
        XCTAssertTrue(joined, "\(app.sync.line)")
        await settle(mac, app)
        await app.flushProfile()
        app.sync.end()
        server.cut()

        let offline = { () async -> AppModel in
            let saved = BrowserProfile(folder: profile.folder)
            let back = AppModel(world: saved.world, fixturesEnabled: false, profile: saved)
            back.sync.attach(back, setup: self.setup(server, ownWorld: false))
            let took = await self.until { back.sync.writing }
            XCTAssertTrue(took, "the account taken from the saved journal")
            XCTAssertNotEqual(back.sync.line, .live)
            back.sync.end()
            return back
        }
        _ = await offline()

        let saved = folder.appendingPathComponent("journal/browser-ids.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: saved)) as? [String: Any])
        XCTAssertNotNil(json["caughtUp"], "the mark is kept with the association")
        json["caughtUp"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: saved)
        _ = await offline()
    }

    /// The same iPhone installed three times (each a new journal and
    /// device, as a deleted app comes back): the account keeps one Personal.
    func testReinstallsAddNoPersonal() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        for round in 0..<3 {
            let home = folder.appendingPathComponent("install-\(round)")
            let app = try await phone(server, seal, world: startWorld(used: round == 1 ? "https://example.com/r1" : nil),
                                      fixturesEnabled: false, home: home)
            _ = await until { app.browser.space(self.work) != nil }
            await settle(mac, app)
            XCTAssertEqual(spaceNames(mac), ["Personal", "Work"], "install \(round)")
            XCTAssertEqual(app.browser.spaces.filter { !$0.isPrivate }.count, 2, "install \(round)")
            app.sync.end()
        }
    }

    /// Two iPhones join the same account, each used first: one Personal
    /// with both pages.
    func testTwoPhonesJoiningShareOnePersonal() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let a = try await phone(server, seal, world: startWorld(used: "https://example.com/a"), fixturesEnabled: false,
                                home: folder.appendingPathComponent("a"))
        let b = try await phone(server, seal, world: startWorld(used: "https://example.com/b"), fixturesEnabled: false,
                                home: folder.appendingPathComponent("b"))
        _ = await until { a.browser.space(self.work) != nil && b.browser.space(self.work) != nil }
        await settle(mac, a, b)
        XCTAssertEqual(spaceNames(mac), ["Personal", "Work"])
        let both = await until {
            let urls = Set(mac.row(self.first).all.map(\.url))
            return urls.contains("https://example.com/a") && urls.contains("https://example.com/b")
        }
        XCTAssertTrue(both, "\(mac.row(first).all.map(\.url))")
        for app in [a, b] {
            XCTAssertEqual(app.browser.spaces.filter { !$0.isPrivate && $0.name == "Personal" }.count, 1)
        }
        a.sync.end()
        b.sync.end()
    }

    /// Empty Personal spaces earlier installs left go on joining, on the
    /// Mac too; one with a page stays.
    func testEmptyDuplicatePersonalsLeftByEarlierInstallsGo() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let blankDup = "D0000000-0000-4000-8000-000000000001", usedDup = "D0000000-0000-4000-8000-000000000002"
        let bareDup = "D0000000-0000-4000-8000-000000000003"
        try mac.write(SyncCollection.space, blankDup, SyncSpace(id: blankDup, name: "Personal", icon: "🏠", order: "Y").fields)
        try mac.write(SyncCollection.tab, "D1000000-0000-4000-8000-000000000001",
                      SyncTab(id: "D1000000-0000-4000-8000-000000000001", space: blankDup, url: "about:blank", title: "New Tab",
                              device: "old-iphone").fields)
        try mac.write(SyncCollection.space, usedDup, SyncSpace(id: usedDup, name: "Personal", icon: "🏠", order: "Z").fields)
        try mac.write(SyncCollection.tab, "D1000000-0000-4000-8000-000000000002",
                      SyncTab(id: "D1000000-0000-4000-8000-000000000002", space: usedDup, url: "https://example.com/kept",
                              title: "Kept", kept: true).fields)
        try mac.write(SyncCollection.space, bareDup, SyncSpace(id: bareDup, name: "Personal", icon: "🏠", order: "Zz").fields)
        _ = await until { mac.pending == 0 }
        let app = try await phone(server, seal, world: startWorld(), fixturesEnabled: false)
        let pruned = await until {
            mac.journal.living(SyncCollection.space).map(\.id).sorted() == [self.first, usedDup, self.work].sorted()
        }
        XCTAssertTrue(pruned, "\(mac.journal.living(SyncCollection.space).map(\.id))")
        XCTAssertTrue(mac.row(blankDup).all.isEmpty)
        XCTAssertEqual(mac.row(usedDup).all.map(\.url), ["https://example.com/kept"], "a Personal with a page stays")
        XCTAssertNil(app.browser.space(blankDup))
        XCTAssertNil(app.browser.space(bareDup))
        XCTAssertNotNil(app.browser.space(usedDup))
    }

    /// The first space renamed and every other Personal empty: the oldest
    /// of them stays, so a Personal is never lost.
    func testEmptyPersonalsKeepOneWhenTheFirstSpaceIsRenamed() {
        let dupA = "D0000000-0000-4000-8000-00000000000A", dupB = "D0000000-0000-4000-8000-00000000000B"
        let spaces = [SyncSpace(id: first, name: "Home", icon: "🏠", order: "V"),
                      SyncSpace(id: dupA, name: "Personal", icon: "🏠", order: "X"),
                      SyncSpace(id: dupB, name: "Personal", icon: "🏠", order: "Y"),
                      SyncSpace(id: work, name: "Work", icon: "💼", order: "Z")]
        let mirror = SyncMirror(spaces: spaces, rows: [:], device: "phone")
        XCTAssertEqual(SyncBridge.emptyPersonals(mirror, local: { $0 }, app: []), [dupB])
        var named = spaces
        named[0].name = "Personal"
        let namedMirror = SyncMirror(spaces: named, rows: [:], device: "phone")
        XCTAssertEqual(SyncBridge.emptyPersonals(namedMirror, local: { $0 }, app: []), [dupA, dupB])
        let privateHere = Space(id: dupB, name: "Personal", emoji: "🏠", tint: RGB(238, 233, 226),
                                today: [Tab(id: "p", title: "Secret", site: "x", icon: "globe", url: "https://x.test", isPrivate: true)])
        XCTAssertEqual(SyncBridge.emptyPersonals(namedMirror, local: { $0 }, app: [privateHere]), [dupA], "a private tab here keeps it")
        let noFirst = SyncMirror(spaces: Array(spaces.dropFirst()), rows: [:], device: "phone")
        XCTAssertEqual(SyncBridge.emptyPersonals(noFirst, local: { $0 }, app: []), [], "no first space, nothing goes")
    }

    // MARK: - the second Personal a broken join made

    private enum Broken {
        static let pinned = "https://example.org/pinned"
        static let kept = "https://example.org/kept"
        static let today = "https://example.org/today"
        static let urls = [pinned, kept, today]
    }

    /// How a broken join left an account: the iPhone joined before the
    /// account's first space was in (Work only), so its used starting
    /// Personal went up as a second Personal under a new id, holding a pin,
    /// a kept tab and one of today's. Then the first space came, with the
    /// same pin. `before` changes the iPhone's profile before it joins;
    /// `firstComes` false leaves the account without its first space.
    /// Returns the Mac, the copy's id and the profile's folder.
    private func brokenJoin(_ server: SyncMemoryServer, _ seal: Seal, firstComes: Bool = true,
                            before: (AppModel) -> Void = { _ in }) async throws -> (TestMac, String, URL) {
        let mac = try TestMac(server: server, seal: seal)
        try mac.write(SyncCollection.space, work, SyncSpace(id: work, name: "Work", icon: "💼", order: "X").fields)
        mac.client.start()
        let up = await until { mac.client.state == .live && mac.pending == 0 }
        XCTAssertTrue(up, "the Mac made the account: \(mac.client.state)")
        let profile = BrowserProfile(folder: folder.appendingPathComponent("browser"))
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        let tabs = Broken.urls.map { PageFixtures.liveTab(for: URL(string: $0)!) }
        for tab in tabs { app.browser.open(tab) }
        app.browser.pin(tabs[0].id)
        app.browser.keep(tabs[1].id)
        before(app)
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        keys.keep(seal, share: false)
        app.sync.attach(app, setup: setup(server, ownWorld: false))
        let sent = await until(8) {
            app.sync.line == .live && app.sync.pending == 0
                && Broken.urls.allSatisfy { url in self.living(mac).contains { $0.url == url } }
        }
        XCTAssertTrue(sent, "\(living(mac).map(\.url))")
        let copy = try XCTUnwrap(living(mac).first { $0.url == Broken.today }?.space)
        XCTAssertNotEqual(copy, first)
        if firstComes {
            try mac.write(SyncCollection.space, first, SyncSpace(id: first, name: "Personal", icon: "🏠", order: "V").fields)
            try mac.write(SyncCollection.tab, "AAAAAAAA-0000-4000-8000-0000000000B1",
                          SyncTab(id: "AAAAAAAA-0000-4000-8000-0000000000B1", space: first, order: "A", url: Broken.pinned,
                                  title: "Pinned", pin: "P").fields)
            let came = await until { app.browser.space(self.first) != nil && mac.pending == 0 }
            XCTAssertTrue(came, "the first space came")
        }
        await app.flushProfile()
        app.sync.end()
        return (mac, copy, profile.folder)
    }

    /// The iPhone launched again on its saved profile, its line live.
    private func relaunch(_ server: SyncMemoryServer, _ profileFolder: URL) async -> AppModel {
        let profile = BrowserProfile(folder: profileFolder)
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        app.sync.attach(app, setup: setup(server, ownWorld: false))
        let live = await until(8) { app.sync.line == .live && app.sync.writing }
        XCTAssertTrue(live, "\(app.sync.line)")
        return app
    }

    /// The iPhone that made the second Personal puts its tabs into the
    /// first space, pins pinned and kept kept, and deletes the copy on
    /// every device. A pin the first space has already isn't doubled.
    func testTheSecondPersonalABrokenJoinMadeGoesIntoTheFirst() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let (mac, copy, profile) = try await brokenJoin(server, seal)
        XCTAssertEqual(spaceNames(mac), ["Personal", "Personal", "Work"], "the broken state")
        let app = await relaunch(server, profile)
        let repaired = await until(8) {
            !mac.journal.living(SyncCollection.space).contains { $0.id == copy } && mac.pending == 0
        }
        XCTAssertTrue(repaired, "\(spaceNames(mac))")
        await settle(mac, app)
        XCTAssertEqual(spaceNames(mac), ["Personal", "Work"])
        XCTAssertTrue(mac.row(copy).all.isEmpty, "nothing left under the copy")
        let row = mac.row(first)
        XCTAssertEqual(row.pins.filter { $0.url == Broken.pinned }.count, 1, "the pin once: \(row.pins.map(\.url))")
        XCTAssertEqual(row.kept.map(\.url), [Broken.kept], "kept stays kept")
        XCTAssertEqual(row.today.map(\.url), [Broken.today])
        XCTAssertEqual(row.today.first?.device, app.sync.engine?.device, "today's stays this iPhone's")
        XCTAssertEqual(app.browser.spaces.filter { !$0.isPrivate }.map(\.name).sorted(), ["Personal", "Work"])
        let here = try XCTUnwrap(app.browser.space(app.sync.localID(first)))
        XCTAssertEqual(here.keptTabs.map(\.url), [Broken.kept])
        XCTAssertEqual(here.today.compactMap(\.url), [Broken.today])
        XCTAssertEqual(here.pins.compactMap(\.url), [Broken.pinned])
        XCTAssertEqual(app.browser.spaceID, here.id, "the space in front was the copy: the first comes in front")

        XCTAssertFalse(app.sync.repairJoinDuplicate(), "a second run finds nothing")
        XCTAssertEqual(app.sync.engine?.journal.pending(limit: 100).count, 0, "and writes nothing")
        app.sync.end()
    }

    /// The copy's pin and the first space's are on the same page now, a
    /// sign-in page, but were saved at different ones: they are two pins,
    /// and the copy's goes into the first space with its saved address.
    func testTheSecondPersonalsPinSavedElsewhereIsKept() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let (mac, copy, profile) = try await brokenJoin(server, seal)
        var theirs = try XCTUnwrap(mac.row(copy).pins.first { $0.url == Broken.pinned })
        theirs.home = "https://example.org/docs"
        try mac.write(SyncCollection.tab, theirs.id, theirs.fields)
        var firsts = try XCTUnwrap(mac.row(first).pins.first { $0.url == Broken.pinned })
        firsts.home = "https://example.org/mail"
        try mac.write(SyncCollection.tab, firsts.id, firsts.fields)
        _ = await until { mac.pending == 0 }
        let app = await relaunch(server, profile)
        let repaired = await until(8) {
            !mac.journal.living(SyncCollection.space).contains { $0.id == copy } && mac.pending == 0
        }
        XCTAssertTrue(repaired, "\(spaceNames(mac))")
        await settle(mac, app)
        let pins = mac.row(first).pins
        XCTAssertEqual(pins.map(\.id).sorted(), [firsts.id, theirs.id].sorted(), "\(pins.map(\.url))")
        XCTAssertEqual(pins.first { $0.id == theirs.id }?.home, "https://example.org/docs", "its saved address goes with it")
        app.sync.end()
    }

    /// Two iPhones and a Mac: the second iPhone took the copy in, then was
    /// away while the first repaired it. Back with its stale journal, it
    /// tidies after the repair: no tab is lost and the copy stays gone.
    func testAnotherIPhonesStaleCopyLosesNoTabAndRevivesNoSpace() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let (mac, copy, profile) = try await brokenJoin(server, seal)
        let other = folder.appendingPathComponent("other")
        let b = try await phone(server, seal, world: startWorld(), fixturesEnabled: false, home: other)
        let took = await until {
            Set(b.browser.space(copy)?.allTabs.compactMap(\.url) ?? []).isSuperset(of: [Broken.pinned, Broken.kept])
        }
        XCTAssertTrue(took, "the other iPhone has the copy's shared tabs: \(b.browser.spaces.map(\.name))")
        XCTAssertFalse(b.sync.repairJoinDuplicate(), "not its copy")
        b.sync.end()

        let a = await relaunch(server, profile)
        let repaired = await until(8) { !mac.journal.living(SyncCollection.space).contains { $0.id == copy } && mac.pending == 0 }
        XCTAssertTrue(repaired, "\(spaceNames(mac))")

        let back = try await phone(server, seal, world: startWorld(), fixturesEnabled: false, home: other)
        let listed = await until { back.sync.engine?.roster != nil }
        XCTAssertTrue(listed, "the device list read: the tidy ran")
        await settle(mac, a, back)
        XCTAssertEqual(spaceNames(mac), ["Personal", "Work"], "the copy isn't back")
        XCTAssertTrue(mac.row(copy).all.isEmpty)
        let row = mac.row(first)
        XCTAssertEqual(row.pins.filter { $0.url == Broken.pinned }.count, 1, "\(row.pins.map(\.url))")
        XCTAssertEqual(row.kept.map(\.url), [Broken.kept])
        XCTAssertEqual(row.today.map(\.url), [Broken.today])
        for app in [a, back] {
            XCTAssertNil(app.browser.space(copy))
            XCTAssertEqual(app.browser.spaces.filter { !$0.isPrivate }.map(\.name).sorted(), ["Personal", "Work"])
            XCTAssertEqual(app.browser.space(app.sync.localID(first))?.keptTabs.map(\.url), [Broken.kept])
        }
        a.sync.end()
        back.sync.end()
    }

    /// Launched again, the iPhone leaves the copy and every page in it.
    private func copyStays(_ server: SyncMemoryServer, _ mac: TestMac, _ copy: String, _ profile: URL,
                           _ why: String, line: UInt = #line) async throws {
        let app = await relaunch(server, profile)
        XCTAssertFalse(app.sync.repairJoinDuplicate(), why, line: line)
        await settle(mac, app)
        let journal = try XCTUnwrap(app.sync.engine?.journal)
        XCTAssertTrue(journal.living(SyncCollection.space).contains { $0.id == copy }, why, line: line)
        XCTAssertTrue(mac.journal.living(SyncCollection.space).contains { $0.id == copy }, why, line: line)
        XCTAssertEqual(Set(mac.row(copy).all.map(\.url)).intersection(Broken.urls), Set(Broken.urls), why, line: line)
        app.sync.end()
    }

    func testARenamedStartingSpaceIsNotTakenForTheSecondPersonal() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let (mac, copy, profile) = try await brokenJoin(server, seal) { app in
            app.browser.setSpace(BrowserProfile.startSpace, name: "Reading")
        }
        try await copyStays(server, mac, copy, profile, "renamed, it is a space of the person's own")
        XCTAssertEqual(spaceNames(mac), ["Personal", "Reading", "Work"])
    }

    func testASecondPersonalWithItsOwnSignInsStays() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let (mac, copy, profile) = try await brokenJoin(server, seal) { app in
            app.browser.setSpaceSignIns(BrowserProfile.startSpace, own: true)
        }
        try await copyStays(server, mac, copy, profile, "its own sign-ins would go with it")
    }

    func testASecondPersonalWithAnotherDevicesTabOfTodayStays() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let (mac, copy, profile) = try await brokenJoin(server, seal)
        try mac.write(SyncCollection.tab, "AAAAAAAA-0000-4000-8000-0000000000C1",
                      SyncTab(id: "AAAAAAAA-0000-4000-8000-0000000000C1", space: copy, order: "Z", url: "https://example.org/theirs",
                              title: "Theirs", device: "other-iphone").fields)
        _ = await until { mac.pending == 0 }
        try await copyStays(server, mac, copy, profile, "another device's tab of today is theirs")
        XCTAssertTrue(mac.row(copy).today.contains { $0.url == "https://example.org/theirs" })
    }

    func testNoRepairUntilTheAccountsFirstSpaceIsIn() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let (mac, copy, profile) = try await brokenJoin(server, seal, firstComes: false)
        try await copyStays(server, mac, copy, profile, "nowhere to put its tabs")
        XCTAssertEqual(spaceNames(mac), ["Personal", "Work"])
    }

    // MARK: - joining again (register row 385)

    private func living(_ mac: TestMac) -> [SyncTab] { mac.journal.living(SyncCollection.tab).compactMap(SyncTab.init) }

    /// A real profile in sync with spaces of its own: the starting space
    /// renamed Reading (an id the Mac wouldn't take, synced under another)
    /// with a page of today's, Trips made here with a kept page and one of
    /// today's, and a page of today's in Work. Then `leave` (Turn Off, or
    /// Join Again after being removed) and joining the same account again:
    /// no space comes back twice, no tab is lost or doubled, each tab is the
    /// record and the local id it was, and today's are this iPhone's again.
    private func leavesAndJoinsAgain(_ leave: (AppModel, SyncMemoryServer) async -> Void) async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let profile = BrowserProfile(folder: folder.appendingPathComponent("browser"))
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        let reading = app.browser.spaceID
        app.browser.setSpace(reading, name: "Reading")
        let essay = PageFixtures.liveTab(for: URL(string: "https://example.org/essay")!)
        app.browser.open(essay)
        let trips = app.browser.createSpace(name: "Trips", emoji: "🧳", look: SpaceLook(color: RGB(168, 195, 160)))
        let flights = PageFixtures.liveTab(for: URL(string: "https://example.org/flights")!)
        let hotel = PageFixtures.liveTab(for: URL(string: "https://example.org/hotel")!)
        app.browser.open(flights, in: trips)
        app.browser.open(hotel, in: trips)
        app.browser.keep(hotel.id)
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        keys.keep(seal, share: false)
        app.sync.attach(app, setup: setup(server, ownWorld: false))
        let came = await until { app.sync.writing && app.browser.space(self.work) != nil }
        XCTAssertTrue(came)
        let notes = PageFixtures.liveTab(for: URL(string: "https://example.org/work-notes")!)
        app.browser.open(notes, in: work)
        let mine = [essay, flights, hotel, notes]
        let up = await until(8) {
            app.sync.line == .live && app.sync.pending == 0
                && mine.allSatisfy { tab in self.living(mac).contains { $0.url == tab.url } }
        }
        XCTAssertTrue(up, "\(living(mac).map(\.url))")
        await settle(mac, app)
        XCTAssertEqual(spaceNames(mac), ["Personal", "Reading", "Trips", "Work"])
        let before = Dictionary(uniqueKeysWithValues: mine.map { tab in (tab.url!, living(mac).first { $0.url == tab.url }!.id) })
        let oldDevice = keys.deviceID

        await leave(app, server)
        XCTAssertEqual(app.sync.phase == .on, false)
        // Used while out: a page of today's opened in Trips.
        let packing = PageFixtures.liveTab(for: URL(string: "https://example.org/packing")!)
        app.browser.open(packing, in: trips)

        XCTAssertTrue(app.sync.useRecovery(seal.recovery))
        XCTAssertNotEqual(keys.deviceID, oldDevice, "joined again as a new device")
        let back = await until(8) { app.sync.line == .live && app.sync.writing && app.sync.pending == 0 }
        XCTAssertTrue(back, "\(app.sync.line)")
        await settle(mac, app)

        XCTAssertEqual(spaceNames(mac), ["Personal", "Reading", "Trips", "Work"], "no space came back twice")
        XCTAssertEqual(app.browser.spaces.filter { !$0.isPrivate }.map(\.name).sorted(), ["Personal", "Reading", "Trips", "Work"])
        XCTAssertEqual(app.browser.space(reading)?.today.map(\.url), [essay.url], "the renamed starting space is the one it was")
        XCTAssertEqual(Set(app.browser.space(trips)?.today.map(\.id) ?? []), [flights.id, packing.id])
        XCTAssertEqual(app.browser.space(trips)?.keptTabs.map(\.id), [hotel.id])
        XCTAssertNotNil(app.browser.space(work)?.today.first { $0.id == notes.id }, "today's in a Mac's space stays")
        let rows = living(mac)
        for tab in mine + [packing] {
            XCTAssertEqual(rows.filter { $0.url == tab.url }.count, 1, "\(tab.url!) once on the Mac")
            XCTAssertEqual(app.browser.spaces.flatMap(\.allTabs).filter { $0.url == tab.url }.count, 1, "\(tab.url!) once here")
        }
        for tab in mine { XCTAssertEqual(rows.first { $0.url == tab.url }?.id, before[tab.url!], "\(tab.url!) is the record it was") }
        for url in [essay.url!, flights.url!, notes.url!, packing.url!] {
            XCTAssertEqual(rows.first { $0.url == url }?.device, keys.deviceID, "\(url) is this iPhone's today again")
        }
        XCTAssertTrue(app.sync.macTabs(in: work).allSatisfy { $0.device != oldDevice }, "nothing of the old device is taken for the Mac's")
        app.sync.end()
    }

    func testTurnOffAndOnAgainAddsNoSpaceAndLosesNoTab() async throws {
        try await leavesAndJoinsAgain { app, _ in
            app.sync.turnOff()
            XCTAssertEqual(app.sync.phase, .off)
        }
    }

    func testJoinAgainAfterRemovalAddsNoSpaceAndLosesNoTab() async throws {
        try await leavesAndJoinsAgain { app, server in
            server.revoke(SyncKeychain.testing(folder: self.folder.appendingPathComponent("keys")).deviceID)
            let told = await self.until { app.sync.phase == .refused("This iPhone was removed from Sync.") }
            XCTAssertTrue(told, "\(app.sync.phase)")
            app.sync.joinAgain()
        }
    }

    // MARK: - the copies an older Join Again left (rows 385, 386)

    /// An account as an iPhone on a build before row 385's fix left it,
    /// joined three times (devices phone-a, phone-b, then phone-c, this
    /// one): its starting space renamed Reading came back each time as a
    /// new space, its kept page with it, and today's pages under the device
    /// it was. Beside them a Mac's spaces, and copies that hold something
    /// of their own.
    private enum Dupes {
        static let readingA = "B0000000-0000-4000-8000-00000000000A"   // made by phone-a, gone
        static let readingB = "B0000000-0000-4000-8000-00000000000B"   // made by phone-b, gone
        static let readingC = "B0000000-0000-4000-8000-00000000000C"   // made by phone-c, this iPhone
        static let readingOwn = "B0000000-0000-4000-8000-00000000000D" // phone-b's, with a page of its own
        static let tripsA = "C0000000-0000-4000-8000-00000000000A"     // phone-a's, the Mac's tab of today in it
        static let tripsC = "C0000000-0000-4000-8000-00000000000C"
        static let lonely = "E0000000-0000-4000-8000-00000000000A"     // phone-a's, no living copy
        static let lonelyToo = "E0000000-0000-4000-8000-00000000000B"
        static let signIns = "F0000000-0000-4000-8000-00000000000A"    // a Work copy with its own sign-ins
    }

    private func dupesMirror(first: String, work: String) -> (SyncMirror, [String: String]) {
        let essay = "https://example.org/essay", longread = "https://example.org/longread/"
        func t(_ space: String, _ url: String, kept: Bool = false, device: String? = nil) -> SyncTab {
            SyncTab(space: space, order: "A", url: url, title: url, kept: kept, device: kept ? nil : device)
        }
        let spaces = [
            SyncSpace(id: first, name: "Personal", icon: "🏠", order: "V"),
            SyncSpace(id: work, name: "Work", icon: "💼", order: "W"),
            SyncSpace(id: Dupes.readingA, name: "Reading", icon: "📚", order: "X"),
            SyncSpace(id: Dupes.readingB, name: "Reading", icon: "📚", order: "Xa"),
            SyncSpace(id: Dupes.readingOwn, name: "Reading", icon: "📚", order: "Xb"),
            SyncSpace(id: Dupes.readingC, name: "Reading ", icon: "📚", order: "Xc"),
            SyncSpace(id: Dupes.tripsA, name: "Trips", icon: "🧳", order: "Y"),
            SyncSpace(id: Dupes.tripsC, name: "Trips", icon: "🧳", order: "Ya"),
            SyncSpace(id: Dupes.lonely, name: "Recipes", icon: "🍳", order: "Z"),
            SyncSpace(id: Dupes.lonelyToo, name: "Recipes", icon: "🍳", order: "Za"),
            SyncSpace(id: Dupes.signIns, name: "Work", icon: "💼", ownSignIns: true, order: "Zb"),
        ]
        let rows: [String: SyncRow] = [
            work: SyncRow(space: work, kept: [t(work, "https://ledger.app/tern/overview", kept: true)],
                          today: [t(work, "https://news.ycombinator.com", device: "mac-a")]),
            Dupes.readingA: SyncRow(space: Dupes.readingA, kept: [t(Dupes.readingA, longread, kept: true)],
                                    today: [t(Dupes.readingA, essay, device: "phone-a")]),
            Dupes.readingB: SyncRow(space: Dupes.readingB, kept: [t(Dupes.readingB, "https://example.org/longread", kept: true)],
                                    today: [t(Dupes.readingB, essay, device: "phone-b"), t(Dupes.readingB, "https://old.example/gone-tab", device: "phone-b")]),
            Dupes.readingOwn: SyncRow(space: Dupes.readingOwn, kept: [t(Dupes.readingOwn, longread, kept: true),
                                                                     t(Dupes.readingOwn, "https://example.org/only-here", kept: true)]),
            Dupes.readingC: SyncRow(space: Dupes.readingC, kept: [t(Dupes.readingC, longread, kept: true)],
                                    today: [t(Dupes.readingC, essay, device: "phone-c")]),
            Dupes.tripsA: SyncRow(space: Dupes.tripsA, today: [t(Dupes.tripsA, "https://maps.example/route", device: "mac-a")]),
            Dupes.tripsC: SyncRow(space: Dupes.tripsC, today: [t(Dupes.tripsC, "https://example.org/flights", device: "phone-c")]),
            Dupes.lonely: SyncRow(space: Dupes.lonely, kept: [t(Dupes.lonely, "https://food.example/pie", kept: true)]),
            Dupes.lonelyToo: SyncRow(space: Dupes.lonelyToo, kept: [t(Dupes.lonelyToo, "https://food.example/pie", kept: true)]),
        ]
        let creators = [first: "mac-a", work: "mac-a", Dupes.readingA: "phone-a", Dupes.readingB: "phone-b",
                        Dupes.readingOwn: "phone-b", Dupes.readingC: "phone-c", Dupes.tripsA: "phone-a", Dupes.tripsC: "phone-c",
                        Dupes.lonely: "phone-a", Dupes.lonelyToo: "phone-b", Dupes.signIns: "phone-a"]
        return (SyncMirror(spaces: spaces, rows: rows, device: "phone-c"), creators)
    }

    /// Only the copies with nothing of their own go: a gone device made
    /// them, a living copy has every page, a gone device's today's count
    /// for nothing; a copy with its own page, a living device's tab of
    /// today, its own sign-ins, or no living copy beside it stays.
    func testCopiesJoiningAgainLeftGoOnlyWhenNothingInThemIsTheirOwn() {
        let (mirror, creators) = dupesMirror(first: first, work: work)
        let gone: Set<String> = ["phone-a", "phone-b"]
        let doomed = SyncBridge.duplicateSpaces(mirror, creators: creators, gone: gone, local: { $0 }, app: [])
        XCTAssertEqual(Set(doomed), [Dupes.readingA, Dupes.readingB])
        XCTAssertEqual(SyncBridge.duplicateSpaces(mirror, creators: creators, gone: [], local: { $0 }, app: []), [],
                       "nobody gone: nothing goes")
        XCTAssertEqual(SyncBridge.duplicateSpaces(mirror, creators: creators, gone: ["phone-a"], local: { $0 }, app: []),
                       [Dupes.readingA, Dupes.lonely],
                       "phone-b still in: its Reading holds its tabs of today, and its Recipes is a living copy of phone-a's")

        // Here, the copy shows a private tab or a page the living copies lack: it stays.
        let secret = Space(id: Dupes.readingA, name: "Reading", emoji: "📚", tint: RGB(238, 233, 226),
                           today: [Tab(id: "p", title: "Secret", site: "x", icon: "globe", url: "https://x.test", isPrivate: true)])
        XCTAssertEqual(SyncBridge.duplicateSpaces(mirror, creators: creators, gone: gone, local: { $0 }, app: [secret]), [Dupes.readingB])
        let unsent = Space(id: Dupes.readingB, name: "Reading", emoji: "📚", tint: RGB(238, 233, 226),
                           today: [Tab(id: "u", title: "Unsent", site: "x", icon: "globe", url: "https://unsent.example")])
        XCTAssertEqual(SyncBridge.duplicateSpaces(mirror, creators: creators, gone: gone, local: { $0 }, app: [unsent]), [Dupes.readingA])
        // A page the living copy has only here (not sent yet) still covers.
        let living = Space(id: Dupes.readingC, name: "Reading", emoji: "📚", tint: RGB(238, 233, 226),
                           today: [Tab(id: "u2", title: "Unsent", site: "x", icon: "globe", url: "https://unsent.example")])
        XCTAssertEqual(Set(SyncBridge.duplicateSpaces(mirror, creators: creators, gone: gone, local: { $0 }, app: [unsent, living])),
                       [Dupes.readingA, Dupes.readingB])
    }

    func testGoneDevicesAreRemovedFormerAndLongSilentPhonesOnly() {
        let now = Date()
        let old = now.addingTimeInterval(-40 * 86_400), recent = now.addingTimeInterval(-3 * 86_400)
        let roster = [
            SyncClient.Listed(id: "phone-c", name: "iPhone", model: "iPhone17,1", lastSeen: now, revoked: false),
            SyncClient.Listed(id: "phone-a", name: "iPhone", model: "iPhone17,1", lastSeen: old, revoked: true),
            SyncClient.Listed(id: "phone-reinstalled", name: "iPhone", model: "iPhone17,1", lastSeen: old, revoked: false),
            SyncClient.Listed(id: "ipad", name: "iPad", model: "iPad14,1", lastSeen: recent, revoked: false),
            SyncClient.Listed(id: "ipad-unknown", name: "iPad", model: "iPad14,1", lastSeen: nil, revoked: false),
            SyncClient.Listed(id: "mac-old", name: "MacBook", model: "Mac16,1", lastSeen: old, revoked: false),
            SyncClient.Listed(id: "mac-removed", name: "MacBook", model: "Mac16,1", lastSeen: old, revoked: true),
        ]
        XCTAssertEqual(SyncBridge.goneDevices(roster, me: "phone-c", former: ["phone-b", "phone-c"], now: now),
                       ["phone-a", "phone-b", "phone-reinstalled", "mac-removed"])
    }

    /// Row 386: a Personal copy whose only tabs are a gone install's of
    /// today goes; one with a living device's tab of today stays.
    func testAPersonalHoldingOnlyAGoneDevicesTabsOfTodayIsEmpty() {
        let dead = "D0000000-0000-4000-8000-00000000000A", alive = "D0000000-0000-4000-8000-00000000000B"
        let spaces = [SyncSpace(id: first, name: "Personal", icon: "🏠", order: "V"),
                      SyncSpace(id: dead, name: "Personal", icon: "🏠", order: "X"),
                      SyncSpace(id: alive, name: "Personal", icon: "🏠", order: "Y")]
        let rows = [dead: SyncRow(space: dead, today: [SyncTab(space: dead, url: "https://old.example", title: "Old", device: "phone-old")]),
                    alive: SyncRow(space: alive, today: [SyncTab(space: alive, url: "https://mac.example", title: "Mac", device: "mac-a")])]
        let mirror = SyncMirror(spaces: spaces, rows: rows, device: "phone")
        XCTAssertEqual(SyncBridge.emptyPersonals(mirror, local: { $0 }, app: []), [], "without the list, a tab is a tab")
        XCTAssertEqual(SyncBridge.emptyPersonals(mirror, local: { $0 }, app: [], gone: ["phone-old"]), [dead])
    }

    /// The real thing: an iPhone joined, Turned Off and joined again the
    /// way a build before row 385's fix did (browser-ids.json gone with
    /// the rest), so Reading came back as a second space with its kept page
    /// twice. The update's sweep takes the old copy away on every device,
    /// once; with a page of its own in the old copy, both stay.
    private func joinsAgainLikeBefore(pageOfItsOwn: Bool) async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let profile = BrowserProfile(folder: folder.appendingPathComponent("browser"))
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        let reading = app.browser.spaceID
        app.browser.setSpace(reading, name: "Reading")
        let essay = PageFixtures.liveTab(for: URL(string: "https://example.org/essay")!)
        let longread = PageFixtures.liveTab(for: URL(string: "https://example.org/longread")!)
        app.browser.open(essay)
        app.browser.open(longread)
        app.browser.keep(longread.id)
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        keys.keep(seal, share: false)
        app.sync.attach(app, setup: setup(server, ownWorld: false))
        let up = await until(8) {
            app.sync.line == .live && app.sync.writing && app.sync.pending == 0
                && [essay, longread].allSatisfy { tab in self.living(mac).contains { $0.url == tab.url } }
        }
        XCTAssertTrue(up, "\(living(mac).map(\.url))")
        await settle(mac, app)
        let oldCopy = try XCTUnwrap(mac.journal.living(SyncCollection.space).compactMap(SyncSpace.init).first { $0.name == "Reading" }?.id)
        let oldDevice = keys.deviceID

        // An older build's Turn Off: the server removes the device, and the
        // iPhone forgot which of its spaces and tabs were which records.
        app.sync.turnOff()
        server.revoke(oldDevice)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("journal").appendingPathComponent("browser-ids.json"))
        if pageOfItsOwn {
            try mac.write(SyncCollection.tab, "AAAAAAAA-0000-4000-8000-0000000000F1",
                          SyncTab(id: "AAAAAAAA-0000-4000-8000-0000000000F1", space: oldCopy, order: "Z",
                                  url: "https://example.org/only-in-the-old-copy", title: "Only here", kept: true).fields)
        }

        XCTAssertTrue(app.sync.useRecovery(seal.recovery))
        let back = await until(8) { app.sync.line == .live && app.sync.writing && app.sync.pending == 0 }
        XCTAssertTrue(back, "\(app.sync.line)")
        await settle(mac, app)
        let swept = await until(8) {
            self.spaceNames(mac).filter { $0 == "Reading" }.count == (pageOfItsOwn ? 2 : 1) && mac.pending == 0
        }
        XCTAssertTrue(swept, "\(spaceNames(mac))")
        await settle(mac, app)

        let saved = try String(contentsOf: folder.appendingPathComponent("journal").appendingPathComponent("browser-ids.json"), encoding: .utf8)
        XCTAssertTrue(saved.contains("\"swept\":1"), "the sweep ran once for this account: \(saved)")
        let names = app.browser.spaces.filter { !$0.isPrivate }.map(\.name).sorted()
        if pageOfItsOwn {
            XCTAssertEqual(spaceNames(mac), ["Personal", "Reading", "Reading", "Work"], "a copy with a page of its own stays")
            XCTAssertEqual(names, ["Personal", "Reading", "Reading", "Work"])
            XCTAssertNotNil(mac.journal.record(.init(collection: SyncCollection.space, id: oldCopy)).flatMap(SyncSpace.init),
                            "the old copy is the one that stayed")
        } else {
            XCTAssertEqual(spaceNames(mac), ["Personal", "Reading", "Work"], "the old copy went on the Mac")
            XCTAssertEqual(names, ["Personal", "Reading", "Work"], "and here")
            XCTAssertNil(app.browser.spaces.first { $0.id == oldCopy })
            let rows = living(mac)
            XCTAssertEqual(rows.filter { $0.url == longread.url }.count, 1, "the kept page once")
            XCTAssertEqual(rows.filter { $0.url == essay.url }.count, 1, "the page of today once")
            let kept = try XCTUnwrap(app.browser.spaces.first { $0.name == "Reading" })
            XCTAssertEqual(kept.keptTabs.map(\.url), [longread.url])
            XCTAssertEqual(kept.today.compactMap(\.url).filter { $0 == essay.url }.count, 1)
        }
        app.sync.end()
    }

    func testTheSweepTakesAwayTheCopyAnOlderJoinAgainLeft() async throws {
        try await joinsAgainLikeBefore(pageOfItsOwn: false)
    }

    func testTheSweepLeavesACopyWithAPageOfItsOwn() async throws {
        try await joinsAgainLikeBefore(pageOfItsOwn: true)
    }

    /// The pure half: a space as the account has it, with the iPhone's own
    /// tabs put back where they stood.
    func testCarriedTabsGoBackWhereTheyStood() {
        func tab(_ id: String, isPrivate: Bool = false) -> Tab {
            Tab(id: id, title: id, site: id, icon: "globe", url: "https://\(id).test", isPrivate: isPrivate)
        }
        let had = Space(id: "s", name: "Trips", emoji: "🧳", tint: RGB(1, 2, 3),
                        pins: [tab("p1"), tab("p2")], kept: [.tab(tab("k1")), .tab(tab("k2"))],
                        today: [tab("a"), tab("mine"), tab("secret", isPrivate: true), tab("b"), tab("gone")])
        let rebuilt = Space(id: "s", name: "Trips", emoji: "🧳", tint: RGB(1, 2, 3),
                            pins: [tab("p1")], kept: [.tab(tab("k1"))], today: [tab("a"), tab("secret", isPrivate: true), tab("b")])
        let out = SyncBridge.carried(had, into: rebuilt) { tab, _ in tab.id != "gone" }
        XCTAssertEqual(out.today.map(\.id), ["a", "mine", "secret", "b"])
        XCTAssertEqual(out.keptTabs.map(\.id), ["k1", "k2"])
        XCTAssertEqual(out.keptTabs.last?.place, .kept)
        XCTAssertEqual(out.pins.map(\.id), ["p1", "p2"])
        XCTAssertEqual(out.pins.last?.place, .pinned)
        XCTAssertEqual(SyncBridge.carried(had, into: rebuilt) { _, _ in false }, rebuilt)
    }

    func testPinsMadeBeforeJoiningStayPinnedInTheFirstSpace() {
        let pin = Tab(id: "pin", title: "Example", site: "Example", icon: "example", url: "https://example.com")
        let start = Space(id: "local", name: "Personal", emoji: "", tint: RGB(1, 2, 3), pins: [pin], current: pin.id)
        let first = Space(id: "first", name: "Personal", emoji: "", tint: RGB(1, 2, 3))
        let merged = SyncBridge.merged(start, into: first, home: \.url)
        XCTAssertEqual(merged.pins.map(\.id), [pin.id])
        XCTAssertEqual(merged.pins.first?.place, .pinned)
        XCTAssertTrue(merged.today.isEmpty)
        XCTAssertEqual(merged.current, pin.id)
    }

    /// Two pins with no address are not the same page: a blank pin of the
    /// first space doesn't keep the starting space's real pins out, and a
    /// blank one of its own stays behind as blank tabs do.
    func testPinsWithNoAddressAreNoDuplicates() {
        let real = Tab(id: "real", title: "Example", site: "Example", icon: "example", url: "https://example.com")
        let none = { (id: String) in Tab(id: id, title: id, site: id, icon: "globe", url: nil) }
        let start = Space(id: "local", name: "Personal", emoji: "🏠", tint: RGB(1, 2, 3), pins: [none("start.none"), real])
        let first = Space(id: "first", name: "Personal", emoji: "🏠", tint: RGB(1, 2, 3), pins: [none("first.none")])
        XCTAssertEqual(SyncBridge.merged(start, into: first, home: \.url).pins.map(\.id), ["first.none", "real"])
    }

    /// A pin is the same pin by the address it was saved at: two saved at
    /// different pages and both on a sign-in page now are two, and one saved
    /// at the same page as the first space's goes, wherever it is now.
    func testPinsAreTheSameByWhereTheyWereSaved() {
        let pin = { (id: String) in Tab(id: id, title: id, site: id, icon: "globe", url: "https://example.com/sign-in") }
        let saved = ["first.mail": "https://example.com/mail", "start.docs": "https://example.com/docs", "start.mail": "https://example.com/mail/"]
        let start = Space(id: "local", name: "Personal", emoji: "🏠", tint: RGB(1, 2, 3), pins: [pin("start.docs"), pin("start.mail")])
        let first = Space(id: "first", name: "Personal", emoji: "🏠", tint: RGB(1, 2, 3), pins: [pin("first.mail")])
        let merged = SyncBridge.merged(start, into: first) { saved[$0.id] ?? $0.url }
        XCTAssertEqual(merged.pins.map(\.id), ["first.mail", "start.docs"])
    }

    /// The starting Personal is Yab's only while named Personal with the
    /// house, in the app's space and in the account's alike.
    func testTheStartingPersonalIsNamedPersonalWithTheHouse() {
        func start(_ name: String, _ emoji: String) -> Space {
            Space(id: BrowserProfile.startSpace, name: name, emoji: emoji, tint: RGB(1, 2, 3))
        }
        XCTAssertTrue(SyncBridge.mergesIntoFirst(start("Personal", "🏠")))
        XCTAssertTrue(SyncBridge.mergesIntoFirst(start(" Personal ", "🏠")))
        XCTAssertFalse(SyncBridge.mergesIntoFirst(start("Reading", "🏠")))
        XCTAssertFalse(SyncBridge.mergesIntoFirst(start("Personal", "📚")), "another icon makes it the person's own")
    }

    /// A space's look goes whole both ways: what the Mac sets comes here
    /// with what this iPhone doesn't draw (theme, glass, Shift), its wash
    /// the same as sync makes; what is changed here (color, linked colors,
    /// drawings, their strength, transparency, grain) reaches the Mac and
    /// keeps the Mac's own fields.
    func testASpacesLookTravelsWholeBothWays() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal)
        _ = await until { self.macToday(app).count == 3 }

        let macLook: Value = .object(["swatch": "custom", "color": "#F37C5A", "colors": .array(["#F23B97"]),
            "grain": true, "grainAmount": 0.4, "transparency": 0.2, "drawings": "life", "drawingsStrength": 0.6,
            "mode": "dark", "glass": true, "shift": true])
        try mac.write(SyncCollection.space, work, SyncSpace(id: work, name: "Work", icon: "💼", paint: SyncPaint(macLook), order: "X").fields)
        let came = await until { app.browser.space(self.work)?.look?.drawings == "life" }
        XCTAssertTrue(came, "the Mac's look came: \(String(describing: app.browser.space(work)?.look?.raw))")
        let here = try XCTUnwrap(app.browser.space(work)?.look)
        XCTAssertEqual(here.primary, RGB(0xF3, 0x7C, 0x5A))
        XCTAssertEqual(here.colors, [RGB(0xF2, 0x3B, 0x97)])
        XCTAssertEqual(here.drawingsStrength, 0.6, accuracy: 0.001)
        XCTAssertEqual(here.transparency, 0.2, accuracy: 0.001)
        XCTAssertEqual(here.raw.object?["mode"], "dark")
        XCTAssertEqual(app.browser.space(work)?.tint, here.wash, "the wash sync makes")

        // Changed here, as the Color page changes it.
        var edited = here
        edited.setPalette(LookColor(RGB(0x74, 0xBF, 0xD6)), following: [LookColor(RGB(0x66, 0x65, 0x87)), LookColor(RGB(0x44, 0xFE, 0x96))])
        edited.setDrawings("browser")
        edited.setDrawingsStrength(0.3)
        edited.setTransparency(0.5)
        edited.setGrain(0.15)
        app.browser.setSpace(work, look: edited)
        XCTAssertEqual(app.browser.space(work)?.tint, edited.wash, "the spaces' card takes it at once")
        let key = Record.Key(collection: SyncCollection.space, id: work)
        let went = await until { mac.journal.record(key)?.fields["paint"]?.object?["drawings"] == "browser" }
        XCTAssertTrue(went, "the iPhone's look reached the Mac: \(String(describing: mac.journal.record(key)?.fields["paint"]))")
        let there = try XCTUnwrap(mac.journal.record(key)?.fields["paint"]?.object)
        XCTAssertEqual(there["color"]?.string, SpaceLook.hex(LookColor(RGB(0x74, 0xBF, 0xD6)).rgb))
        XCTAssertEqual(there["colors"]?.array?.count, 2)
        XCTAssertEqual(there["drawingsStrength"]?.number ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(there["transparency"]?.number ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(there["grainAmount"]?.number ?? 0, 0.15, accuracy: 0.001)
        XCTAssertEqual(there["mode"], "dark", "the Mac's theme stays")
        XCTAssertEqual(there["glass"], true, "and its glass")
        XCTAssertEqual(there["shift"], true, "and Shift with tabs")
    }

    /// Feedback #354: a symbol the Mac picked (star.fill) is shown here as
    /// its emoji, and a change made here must not write that emoji back
    /// over the Mac's symbol; another emoji picked here still goes.
    func testTheMacsSymbolIsNotWrittenBackAsItsEmoji() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal)
        _ = await until { self.macToday(app).count == 3 }
        let choiceID = UUID().uuidString
        try mac.write(SyncCollection.space, work, SyncSpace(id: work, name: "Work", icon: "star.fill", order: "X", iconChoice: "star.fill", iconChoiceID: choiceID).fields)
        let came = await until { app.browser.space(self.work)?.emoji == "⭐️" }
        XCTAssertTrue(came, "shown as its emoji: \(String(describing: app.browser.space(work)?.emoji))")
        let key = Record.Key(collection: SyncCollection.space, id: work)
        // Something else changed here: the space's record is gone over again.
        app.browser.showSpace(work)
        app.browser.open(Tab(id: "symbol-open", title: "Opened", site: "Example", icon: "example", url: "example.com/symbol"))
        app.sync.flushLocal()
        let up = await until { mac.row(self.work).today.contains { $0.url == "https://example.com/symbol" } }
        XCTAssertTrue(up)
        XCTAssertEqual(mac.journal.record(key)?.fields["icon"]?.string, "star.fill", "the Mac's symbol stays")
        XCTAssertEqual(mac.journal.record(key)?.fields["iconChoice"]?.string, "star.fill", "the Mac's explicit choice stays with it")
        XCTAssertEqual(mac.journal.record(key)?.fields["iconChoiceID"]?.string, choiceID, "a generic tab write does not invent a new choice")
        app.browser.setSpace(work, name: "Work renamed")
        app.sync.flushLocal()
        let renamed = await until { mac.journal.record(key)?.fields["name"]?.string == "Work renamed" }
        XCTAssertTrue(renamed)
        XCTAssertEqual(mac.journal.record(key)?.fields["iconChoiceID"]?.string, choiceID, "a rename preserves the symbol choice")
        // Another emoji picked here goes as it is.
        app.browser.setSpace(work, emoji: "🔭")
        app.sync.flushLocal()
        let went = await until { mac.journal.record(key)?.fields["icon"]?.string == "🔭" }
        XCTAssertTrue(went, "picked here: \(String(describing: mac.journal.record(key)?.fields["icon"]))")
        XCTAssertEqual(mac.journal.record(key)?.fields["iconChoice"]?.string, "🔭", "another emoji is a deliberate pick")
        XCTAssertEqual(mac.journal.record(key)?.stamps["iconChoice"], mac.journal.record(key)?.stamps["icon"])
        XCTAssertNotEqual(mac.journal.record(key)?.fields["iconChoiceID"]?.string, choiceID)
        XCTAssertNotNil(mac.journal.record(key)?.fields["iconChoiceID"]?.string)
        XCTAssertEqual(mac.journal.record(key)?.stamps["iconChoiceID"], mac.journal.record(key)?.stamps["icon"])
    }

    func testPrivateTabsNeverLeaveTheIPhone() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal)
        _ = await until { self.macToday(app).count == 3 }
        app.browser.showSpace(work)
        app.browser.open(Tab(id: "private-1", title: "Something private", site: "Example", icon: "example", url: "example.com/secret", isPrivate: true))
        let privateSpace = app.browser.spaceID
        XCTAssertTrue(app.browser.space.isPrivate)
        app.browser.showSpace(work)
        app.browser.open(Tab(id: "open-1", title: "Not private", site: "Example", icon: "example", url: "example.com/open"))
        let up = await until { mac.row(self.work).today.contains { $0.url == "https://example.com/open" } }
        XCTAssertTrue(up)
        XCTAssertFalse(mac.journal.all(SyncCollection.tab).contains { $0["url"]?.string?.contains("secret") == true })
        XCTAssertFalse(app.sync.engine!.journal.all(SyncCollection.tab).contains { $0["url"]?.string?.contains("secret") == true })
        // A change from the Mac rebuilds the row: the private tab stays here.
        try mac.write(SyncCollection.tab, "CCCCCCCC-0000-4000-8000-000000000001",
                      SyncTab(id: "CCCCCCCC-0000-4000-8000-000000000001", space: work, order: "Z", url: "https://a.test", title: "A").fields)
        _ = await until { app.browser.tab("CCCCCCCC-0000-4000-8000-000000000001") != nil }
        XCTAssertEqual(app.browser.tab("private-1")?.isPrivate, true)
        XCTAssertEqual(app.browser.space(holding: "private-1")?.id, privateSpace)
        XCTAssertFalse(app.sync.engine!.journal.all(SyncCollection.space).contains { $0["name"]?.string == "Private" })
    }

    // MARK: - the Mac asleep

    func testTheMacAsleepLineCountsAndGoesWhenItWakes() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal, onlineFor: 0.6, refreshEvery: 0.2)
        _ = await until { self.macToday(app).count == 3 }
        app.browser.showSpace(work)
        mac.client.sayPresence()
        _ = await until { app.sync.awakeMac != nil }
        XCTAssertFalse(app.browser.macAsleep)
        mac.client.stop()
        let asleep = await until(4) { app.browser.macAsleep }
        XCTAssertTrue(asleep, "\(app.sync.macs)")
        XCTAssertNil(app.sync.note(for: work), "quiet until something waits for it")
        app.browser.open(Tab(id: "while-asleep", title: "Opened while it sleeps", site: "Example", icon: "example", url: "example.com/asleep"))
        app.browser.open(Tab(id: "while-asleep-2", title: "And another", site: "Example", icon: "example", url: "example.com/asleep-2"))
        XCTAssertEqual(app.sync.note(for: work), .macAsleep(2))
        XCTAssertNil(app.sync.note(for: first), "only under the space in front")
        // Awake: it catches up by itself, the line goes, nothing lost.
        mac.client.start()
        _ = await until { mac.client.state == .live }
        mac.client.sayPresence()
        let awake = await until { !app.browser.macAsleep }
        XCTAssertTrue(awake)
        XCTAssertNil(app.sync.note(for: work))
        let caught = await until { ["https://example.com/asleep", "https://example.com/asleep-2"].allSatisfy { url in mac.row(self.work).today.contains { $0.url == url } } }
        XCTAssertTrue(caught)
    }

    func testTheMacsTabIsOfferedOnceAndTakenWhenOpened() async throws {
        let app = AppModel(world: try World.load(named: "mira"))
        app.sync.attach(app, setup: nil)
        app.sync.pretendMac(awake: true, front: "work-hn")
        XCTAssertEqual(app.browser.onMac?.id, "work-hn", "\"Mac\" moves to the Mac's tab")
        app.sync.offerHandoff()
        XCTAssertEqual(app.tasks.handoff?.id, "work-hn")
        XCTAssertEqual(app.nowItem?.kind, .handoff)
        app.sync.offerHandoff()
        app.browser.select("work-hn")
        let taken = await until { app.tasks.handoff == nil }
        XCTAssertTrue(taken, "opened from its row: the offer goes")
        app.sync.offerHandoff()
        XCTAssertNil(app.tasks.handoff, "once for each tab the Mac has in front")
        // Asleep: the line says what waits, only under the space in front.
        app.sync.pretendMac(awake: false, front: "work-hn")
        XCTAssertTrue(app.browser.macAsleep)
        XCTAssertEqual(app.browser.onMac?.id, "work-hn", "its tab is still in front there")
        XCTAssertNil(app.sync.note(for: "work"))
        app.browser.keep("work-gh-pr")
        XCTAssertEqual(app.sync.note(for: "work"), .macAsleep(1))
        app.sync.pretendMac(awake: true, front: "work-hn")
        XCTAssertNil(app.sync.note(for: "work"))
        XCTAssertEqual(app.browser.pendingForMac, 0)
    }

    func testANamedStatesMacKeepsTheSpacesAndTheirOrder() async throws {
        let app = AppModel(world: try World.load(named: "mira"))
        app.sync.attach(app, setup: nil)
        let before = app.browser.spaces.map(\.name)
        let linear = "6F2B1C3A-4E5D-4A7B-9C8D-0E1F2A3B4C5D"
        app.sync.pretendMacOpens(linear, url: "https://linear.app/tern/issue/ENG-412/invite-flow", title: "ENG-412 · Invite flow · Linear", in: "work")
        XCTAssertEqual(app.browser.spaces.map(\.name), before, "the capsule's order stays")
        XCTAssertEqual(app.browser.space("work")?.today.first?.id, linear, "at the top of today")
        XCTAssertEqual(app.browser.space("work")?.today.dropFirst().map(\.id),
                       ["work-hn", "work-gh-pr", "work-tern-local", "work-lumen", "work-linear-method"])
        XCTAssertEqual(app.browser.space("work")?.folders.first?.open, true)
        XCTAssertEqual(app.browser.space("work")?.tint, RGB(226, 233, 244), "its wash stays")
        XCTAssertEqual(app.browser.tab?.id, "work-figma-onb", "the tab in front stays")
    }

    // MARK: - offline and relaunch

    func testTheOutboxSurvivesARelaunch() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        server.down = true
        let world = try World.load(named: "offline")
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        keys.keep(seal, share: false)
        var app: AppModel? = AppModel(world: world)
        app!.sync.attach(app!, setup: setup(server, seed: true))
        let waiting = await until { app!.sync.pending == 50 }
        XCTAssertTrue(waiting, "pending \(app!.sync.pending)")
        let offline = await until(5) { app!.sync.note(for: app!.browser.spaceID) == .offline(50) }
        XCTAssertTrue(offline, "\(String(describing: app!.sync.note(for: app!.browser.spaceID)))")
        // Ended without a goodbye: what is left is the journal on disk.
        app!.sync.end()
        app = nil
        try await Task.sleep(for: .milliseconds(300))
        server.down = false
        let again = AppModel(world: blank())
        again.sync.attach(again, setup: setup(server, seed: true))
        let shown = await until { again.browser.spaces.map(\.name) == ["Personal", "Work"] }
        XCTAssertTrue(shown, "the journal's spaces, read off the main thread before the line opens: \(again.browser.spaces.map(\.name))")
        let sent = await until(6) { again.sync.line == .live && again.sync.pending == 0 }
        XCTAssertTrue(sent, "\(again.sync.line) pending \(again.sync.pending)")
        let mac = try TestMac(server: server, seal: seal)
        mac.client.start()
        let all = await until { mac.journal.living(SyncCollection.tab).count == 48 && mac.journal.living(SyncCollection.space).count == 2 }
        XCTAssertTrue(all, "the Mac has \(mac.journal.living(SyncCollection.tab).count) tabs")
        let personal = mac.row(first)
        XCTAssertEqual(personal.today.first?.title, "Train notes 1 · Paper")
        XCTAssertEqual(personal.today.map(\.title), world.spaces[0].today.map(\.title), "in the iPhone's order")
    }

    // MARK: - joining stays in reach

    func testTheJoinSheetComesBackUntilThisIPhoneIsIn() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        _ = try await macWithWork(server, seal)
        let app = AppModel(world: blank())
        app.sync.attach(app, setup: setup(server))
        XCTAssertTrue(app.sync.showsJoin)
        app.sync.closeJoin()
        XCTAssertFalse(app.sync.showsJoin)
        app.sync.cameToFront()
        XCTAssertTrue(app.sync.showsJoin, "put away, joining waits: the sheet comes back with Yab")
        app.sync.closeJoin()
        app.sync.asksOnFront = false
        app.sync.cameToFront()
        XCTAssertFalse(app.sync.showsJoin, "Not Now in the welcome: Settings has it")
        app.sync.openJoin()
        XCTAssertTrue(app.sync.showsJoin, "Settings › Join Your Mac")
    }

    func testARemovedIPhoneSaysSoUntilItJoinsAgain() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        _ = try await macWithWork(server, seal)
        let app = try await phone(server, seal)
        _ = await until { self.macToday(app).count == 3 }
        server.revoke(SyncKeychain.testing(folder: folder.appendingPathComponent("keys")).deviceID)
        _ = await until { if case .refused = app.sync.phase { return true }; return false }
        app.sync.closeJoin()
        XCTAssertEqual(app.sync.note(for: app.browser.spaceID), .removed, "the quiet line says sync is off")
        app.sync.asksOnFront = false
        app.sync.cameToFront()
        XCTAssertTrue(app.sync.showsJoin, "a removed iPhone is asked again whatever")
    }

    // MARK: - the line in front and in the back

    func testComingBackWhileThePauseDrainsKeepsTheLine() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal)
        _ = await until { self.macToday(app).count == 3 }
        server.holdsPushes = true
        app.browser.showSpace(work)
        app.browser.open(Tab(id: "in-flight", title: "In flight", site: "Example", icon: "example", url: "example.com/in-flight"))
        _ = await until { app.sync.pending > 0 }
        // To the back with a change in flight, and in front again a moment later.
        app.sync.engine!.pause(within: 5)
        try await Task.sleep(for: .milliseconds(150))
        app.sync.cameToFront()
        server.letPushesGo()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(app.sync.line, .live, "the drained pause leaves the line up while Yab is in front")
        // And it still carries changes both ways.
        try mac.write(SyncCollection.tab, "CCCCCCCC-0000-4000-8000-000000000002",
                      SyncTab(id: "CCCCCCCC-0000-4000-8000-000000000002", space: work, order: "Z", url: "https://b.test", title: "B", kept: true).fields)
        let came = await until { app.browser.tab("CCCCCCCC-0000-4000-8000-000000000002") != nil }
        XCTAssertTrue(came)
    }

    func testAPushInTheBackCatchesUpAndClosesTheLine() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal)
        _ = await until { self.macToday(app).count == 3 }
        // Where the pushes go, told once the line is up.
        SyncPush.registered(Data([0xAB, 0xCD, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06]))
        let told = await until { server.pushTokens[SyncKeychain.testing(folder: self.folder.appendingPathComponent("keys")).deviceID] == "abcd010203040506" }
        XCTAssertTrue(told, "\(server.pushTokens)")
        app.sync.engine!.pause(within: 1)
        _ = await until { app.sync.line == .off }
        let id = "CCCCCCCC-0000-4000-8000-000000000003"
        try mac.write(SyncCollection.tab, id, SyncTab(id: id, space: work, order: "Z", url: "https://c.test", title: "C", kept: true).fields)
        _ = await until { mac.pending == 0 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(app.browser.tab(id), "nothing comes while the line is closed")
        let woke = expectation(description: "caught up")
        app.sync.engine!.catchUp(closeAfter: true) { came in
            XCTAssertTrue(came)
            woke.fulfill()
        }
        await fulfillment(of: [woke], timeout: 5)
        let came = await until { app.browser.tab(id) != nil }
        XCTAssertTrue(came, "in the stores, before Yab is opened")
        let closed = await until { app.sync.line == .off }
        XCTAssertTrue(closed, "and the line closed again: \(app.sync.line)")
    }

    // MARK: - a person's own launch

    func testAPersonsLaunchShowsOnlyTheAccountAndWritesNoWorld() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        // An account no Mac has filled yet: the world must not go into it.
        let mira = try World.load(named: "mira")
        let app = try await phone(server, seal, world: mira, ownWorld: false)
        XCTAssertEqual(app.browser.spaces.map(\.id), [SyncBridge.waitingSpace], "Mira's spaces are put away")
        XCTAssertTrue(app.chats.chats.isEmpty, "and her chats")
        try await Task.sleep(for: .milliseconds(300))
        // Only what this iPhone takes from a Mac (its own commandcap, OpenOnPhone) goes up.
        let capability = seal.name(.init(collection: OpenOnMac.capability, id: app.sync.ownDevice ?? ""))
        XCTAssertTrue((server.records.values.first ?? [:]).keys.allSatisfy { $0 == capability }, "nothing of the world was written into the account")
        // The Mac's spaces arrive: they are what the iPhone shows, and its own changes go up from here.
        let mac = try await macWithWork(server, seal)
        let arrived = await until { app.browser.spaces.map(\.name) == ["Personal", "Work"] }
        XCTAssertTrue(arrived, "\(app.browser.spaces.map(\.name))")
        app.browser.showSpace(work)
        app.browser.open(Tab(id: UUID().uuidString, title: "Mine", site: "Example", icon: "example", url: "example.com/mine"))
        let up = await until { mac.row(self.work).today.contains { $0.url == "https://example.com/mine" && $0.device == self.phoneID } }
        XCTAssertTrue(up)
        XCTAssertEqual(mac.journal.living(SyncCollection.space).count, 2, "no third space")
    }

    // MARK: - one page, one row

    func testOpeningAPageAlreadyInTheRowBringsThatRowUp() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal)
        _ = await until { self.macToday(app).count == 3 }
        app.browser.showSpace(work)
        app.browser.open(Tab(id: "lumen-here", title: "Design Systems Night · Stockholm · Lumen", site: "Lumen", icon: "lumen",
                             url: "https://www.lumen.events/e/design-systems-night/"))
        app.browser.open(Tab(id: "other-here", title: "Another page", site: "Example", icon: "example", url: "example.com/other"))
        XCTAssertEqual(todayIDs(app, work), ["other-here", "lumen-here"])
        // The same page again: the row already there comes up, not a second one.
        app.browser.open(Tab(id: UUID().uuidString, title: "Design Systems Night · Stockholm · Lumen", site: "Lumen", icon: "lumen",
                             url: "https://www.lumen.events/e/design-systems-night/"))
        XCTAssertEqual(todayIDs(app, work), ["lumen-here", "other-here"], "the row already there, at the top")
        XCTAssertEqual(app.browser.tab?.id, "lumen-here")
        let moved = await until { mac.row(self.work).today.filter { $0.device == self.phoneID }.first?.url.contains("lumen.events") == true }
        XCTAssertTrue(moved, "\(mac.row(work).today.map(\.title))")
        XCTAssertEqual(mac.row(work).today.filter { $0.device == self.phoneID }.count, 2, "one row in the account too")
        // A kept page opened again is shown where it is kept.
        app.browser.open(Tab(id: UUID().uuidString, title: "Ledger", site: "Ledger", icon: "ledger", url: "ledger.app/tern/overview"))
        XCTAssertEqual(app.browser.tab?.id, "AAAAAAAA-0000-4000-8000-000000000004")
        XCTAssertEqual(todayIDs(app, work).count, 2)
    }

    // MARK: - presence

    func testANewIPhoneKnowsTheMacsTabAndSleepAtOnce() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        mac.front = ("http://localhost:5173", "Tern · Calm scheduling for busy teams", "AAAAAAAA-0000-4000-8000-000000000006")
        mac.asleep = true
        mac.client.sayPresence()
        try await Task.sleep(for: .milliseconds(100))
        mac.client.stop()
        // Long before any beat or devices refresh: the server's kept word.
        let app = try await phone(server, seal, refreshEvery: 600)
        // The Mac's tab of today isn't in this iPhone's rows: New Tab's Now
        // offers it from the Mac's word, to open here.
        // Now belongs to the space the Mac's tab is in, not whichever one is in front.
        let macTab = "AAAAAAAA-0000-4000-8000-000000000006"
        func now() -> NewTabItem? { NewTabContent.macNow(app, in: app.sync.spaceOfMacTab(macTab)) }
        let known = await until(2) { now() != nil && app.browser.macAsleep }
        XCTAssertTrue(known, "now \(String(describing: now())) asleep \(app.browser.macAsleep)")
        guard case let .open(copy) = now()?.action else { return XCTFail("a copy here") }
        XCTAssertEqual(copy.title, "Tern · Calm scheduling for busy teams")
        XCTAssertEqual(copy.port, ":5173")
    }

    func testTheMacsPlaceOnAPageIsPassedOnlyAsItsTabComesInFront() async throws {
        let app = AppModel(world: try World.load(named: "mira"))
        app.sync.attach(app, setup: nil)
        app.sync.pretendMac(awake: true, front: "work-hn", scroll: 0.5)
        XCTAssertEqual(app.sync.scrollsPassed, 0)
        app.browser.select("work-hn")
        let passed = await until { app.sync.scrollsPassed == 1 }
        XCTAssertTrue(passed)
        // A new beat while the tab stays open, then rows changing: never again.
        app.sync.pretendMac(awake: true, front: "work-hn", scroll: 0.8)
        app.browser.keep("work-gh-pr")
        app.sync.pretendMac(awake: true, front: "work-hn", scroll: 0.9)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(app.sync.scrollsPassed, 1)
        // Away and back with what the Mac said since: that place, once.
        app.browser.select("work-tern-local")
        try await Task.sleep(for: .milliseconds(50))
        app.browser.select("work-hn")
        let again = await until { app.sync.scrollsPassed == 2 }
        XCTAssertTrue(again)
    }

    // MARK: - chats

    func testAMacsChatAndWordsForIt() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let now = Date().timeIntervalSince1970
        try mac.write(SyncCollection.chat, "a:k3", ["kind": "agent", "device": "mac-a", "title": "Find a hotel", "state": "done",
                                                     "started": .number(now - 60), "updated": .number(now - 30), "cli": "claude"])
        try mac.write(SyncCollection.chatItem, "a:k3/i1", ["chat": "a:k3", "n": 1, "kind": "asked", "text": "Find a hotel in Lisbon", "state": "done"])
        try mac.write(SyncCollection.chatItem, "a:k3/i2", ["chat": "a:k3", "n": 2, "kind": "message", "text": "Memmo Alfama, 180 € a night.", "state": "done"])
        _ = await until { mac.pending == 0 }
        let app = try await phone(server, seal, fixturesEnabled: false)
        let came = await until { app.chats.chat("a:k3")?.messages.count == 2 }
        XCTAssertTrue(came, "\(String(describing: app.chats.chat("a:k3")))")
        XCTAssertEqual(app.chats.chat("a:k3")?.lastAnswer?.text, "Memmo Alfama, 180 € a night.")
        // Words typed here go to the Mac that runs the chat.
        app.openChat("a:k3")
        app.send("And a cheaper one?")
        let heard = await until { mac.journal.living(SyncCollection.send).contains { $0["text"]?.string == "And a cheaper one?" } }
        XCTAssertTrue(heard)
        let send = try XCTUnwrap(mac.journal.living(SyncCollection.send).first)
        XCTAssertEqual(send["device"]?.string, "mac-a")
        XCTAssertEqual(send["chat"]?.string, "a:k3")
        let shown = await until { app.chats.chat("a:k3")?.messages.last?.role == .typing }
        XCTAssertTrue(shown, "waiting for the Mac's answer")
        XCTAssertFalse(app.canDelete("a:k3"), "a chat its Mac is working on is stopped first, as on the Mac")
        app.sync.flushLocal()
        app.sync.flushLocal()
        XCTAssertEqual(app.sync.engine?.sends().count, 1, "store observation never sends the question again")
    }

    func testARealNewQuestionBecomesTheMacsChatAndItsAnswer() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal, fixturesEnabled: false)
        let seesMac = await until { !app.sync.macs.isEmpty }
        XCTAssertTrue(seesMac)
        app.ask("Find a quiet café", page: nil)
        let local = try XCTUnwrap(app.chatSheet.chatID)
        app.expand()
        app.chats.parked = .init(chat: local, mode: .chat)
        let sent = await until { mac.journal.living(SyncCollection.send).count == 1 }
        XCTAssertTrue(sent)
        let record = try XCTUnwrap(mac.journal.living(SyncCollection.send).first)
        XCTAssertEqual(record["agentText"]?.string, "Find a quiet café")
        XCTAssertNil(record["text"], "a rolled-back Mac must not run its default provider")
        XCTAssertEqual(record["clientChat"]?.string, local)
        XCTAssertEqual(record["clientDevice"]?.string, app.sync.engine?.options.device.id)
        XCTAssertEqual(record["kind"]?.string, "agent")
        XCTAssertNil(record["chat"]?.string)
        app.chatSheet.draft = "Another question"
        app.send("Another question")
        XCTAssertEqual(app.chatSheet.draft, "Another question", "a second turn waits for the Mac's chat id")
        XCTAssertEqual(app.sync.engine?.sends().count, 1)
        let now = Date().timeIntervalSince1970
        try mac.write(SyncCollection.send, record.id, ["state": "taken", "chat": "a:real", "took": .number(now)])
        let acknowledged = await until { app.sync.engine?.sends().first?.state == .taken }
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(app.sync.engine?.sends().first?.clientChat, local, "Mac takeSends changes only state/chat/took, preserving correlation fields")
        XCTAssertEqual(app.sync.engine?.sends().first?.clientDevice, app.sync.engine?.options.device.id)
        XCTAssertEqual(app.chatSheet.chatID, local, "an acknowledgement without a chat head keeps the question visible")
        try mac.write(SyncCollection.chat, "a:real", ["kind": "agent", "device": "mac-a", "title": "Quiet café", "state": "running", "started": .number(now), "updated": .number(now)])
        try mac.write(SyncCollection.chatItem, "a:real/1", ["chat": "a:real", "n": 1, "kind": "asked", "text": "Find a quiet café", "began": .number(now)])
        try mac.write(SyncCollection.chatItem, "a:real/2", ["chat": "a:real", "n": 2, "kind": "message", "text": "This is the answer from the Mac.", "began": .number(now + 1)])
        try mac.write(SyncCollection.chat, "a:real", ["state": "done", "updated": .number(now + 1)])
        let answered = await until { app.chatSheet.chatID == "a:real" && app.chats.chat("a:real")?.lastAnswer?.text == "This is the answer from the Mac." }
        XCTAssertTrue(answered)
        XCTAssertNil(app.chats.chat(local))
        XCTAssertEqual(app.chats.parked?.chat, "a:real")
        XCTAssertEqual(app.surfaces.chat, .chat("a:real"))
        XCTAssertEqual(app.chats.chat("a:real")?.messages.map(\.role), [.you, .answer])
        app.send("Any others?")
        let continued = await until { mac.journal.living(SyncCollection.send).count == 2 }
        XCTAssertTrue(continued)
        let followup = try XCTUnwrap(mac.journal.living(SyncCollection.send).first { $0.id != record.id })
        XCTAssertEqual(followup["chat"]?.string, "a:real")
        XCTAssertEqual(followup["text"]?.string, "Any others?", "the Mac already owns its preceding turns")
        try mac.write(SyncCollection.send, followup.id, ["state": "failed", "reason": "Claude is signed out"])
        let failed = await until { app.chats.chat("a:real")?.messages.last?.text.contains("Claude is signed out") == true }
        XCTAssertTrue(failed)
        XCTAssertEqual(app.chats.chat("a:real")?.messages.last?.role, .failed)
        XCTAssertEqual(app.sync.engine?.sends().count, 2)
    }

    func testANewQuestionSurvivesRelaunchAndShowsExpiry() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal, fixturesEnabled: false)
        _ = await until { !app.sync.macs.isEmpty }
        app.ask("Question waiting for my Mac", page: nil)
        let local = try XCTUnwrap(app.chatSheet.chatID)
        let sent = await until { mac.journal.living(SyncCollection.send).count == 1 }
        XCTAssertTrue(sent)
        let record = try XCTUnwrap(mac.journal.living(SyncCollection.send).first)
        app.sync.end()
        let again = try await phone(server, seal, fixturesEnabled: false)
        let recovered = await until { again.chats.chat(local)?.messages.first?.text == "Question waiting for my Mac" }
        XCTAssertTrue(recovered, "the send's correlation reconstructs the pending chat from the journal")
        try mac.write(SyncCollection.send, record.id, ["state": "expired"])
        let expired = await until { again.chats.chat(local)?.messages.last?.text.contains("expired before") == true }
        XCTAssertTrue(expired)
        XCTAssertEqual(again.chats.chat(local)?.messages.last?.role, .failed)
        XCTAssertFalse(again.sync.isStartingChat(local))
    }

    /// A question its Mac never took, waiting or failed, deletes at once,
    /// takes its send back, and stays deleted through sync and relaunch.
    func testAStuckOrFailedQuestionDeletesForGood() async throws {
        let previous = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = previous }
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal, fixturesEnabled: false)
        _ = await until { !app.sync.macs.isEmpty }

        // Waiting for its Mac: Delete is there and works the first time.
        app.ask("What is webkit", page: nil)
        let stuck = try XCTUnwrap(app.chatSheet.chatID)
        let sent = await until { mac.journal.living(SyncCollection.send).count == 1 }
        XCTAssertTrue(sent)
        let waiting = try XCTUnwrap(mac.journal.living(SyncCollection.send).first)
        XCTAssertTrue(app.chats.chat(stuck)?.working == true || app.chats.chat(stuck)?.messages.last?.role == .wait)
        XCTAssertTrue(app.canDelete(stuck), "a chat waiting for its Mac can be deleted")
        app.deleteChat(stuck)
        XCTAssertNil(app.chats.chat(stuck))
        XCTAssertEqual(app.sync.engine?.sends().first { $0.id == waiting.id }?.state, .cancelled, "its question is taken back")
        let cancelled = await until { mac.journal.record(.init(collection: SyncCollection.send, id: waiting.id))?["state"]?.string == "cancelled" }
        XCTAssertTrue(cancelled, "its Mac won't start it")

        // Failed: Delete removes it, and the failed send never brings it back.
        app.ask("A question that expires", page: nil)
        let failing = try XCTUnwrap(app.chatSheet.chatID)
        _ = await until { mac.journal.living(SyncCollection.send).count == 2 }
        let second = try XCTUnwrap(mac.journal.living(SyncCollection.send).first { $0.id != waiting.id })
        try mac.write(SyncCollection.send, second.id, ["state": "expired"])
        let failed = await until { app.chats.chat(failing)?.messages.last?.role == .failed }
        XCTAssertTrue(failed)
        XCTAssertTrue(app.canDelete(failing))
        app.deleteChat(failing)
        XCTAssertNil(app.chats.chat(failing))
        // Sync touches the send again (its Mac writes it once more).
        try mac.write(SyncCollection.send, second.id, ["state": "expired", "took": .number(Date().timeIntervalSince1970)])
        _ = await until { app.sync.engine?.sends().first { $0.id == second.id }?.took != nil }
        XCTAssertNil(app.chats.chat(failing), "Delete never restarts the wait")
        XCTAssertNil(app.chats.chat(stuck))

        // Relaunch, and its Mac taking the first one late: neither comes back.
        app.sync.end()
        try mac.write(SyncCollection.send, waiting.id, ["state": "taken", "chat": "a:late", "took": .number(Date().timeIntervalSince1970)])
        let now = Date().timeIntervalSince1970
        try mac.write(SyncCollection.chat, "a:late", ["kind": "agent", "device": "mac-a", "title": "WebKit", "state": "done",
                                                       "started": .number(now), "updated": .number(now)])
        _ = await until { mac.pending == 0 }
        let again = try await phone(server, seal, fixturesEnabled: false)
        _ = await until { !again.sync.macs.isEmpty && again.sync.engine?.sends().count == 2 }
        _ = await until { again.sync.engine?.sends().first { $0.id == waiting.id }?.state == .taken }
        XCTAssertNil(again.chats.chat(stuck))
        XCTAssertNil(again.chats.chat(failing))
        XCTAssertNil(again.chats.chat("a:late"), "the chat its Mac made of a deleted question stays on the Mac")
    }

    func testATakenSendCannotRedirectTheQuestionToAnotherMacsChat() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal, fixturesEnabled: false)
        _ = await until { !app.sync.macs.isEmpty }
        app.ask("My question", page: nil)
        let local = try XCTUnwrap(app.chatSheet.chatID)
        _ = await until { mac.journal.living(SyncCollection.send).count == 1 }
        let record = try XCTUnwrap(mac.journal.living(SyncCollection.send).first)
        try mac.write(SyncCollection.chat, "a:other", ["device": "mac-b", "state": "done", "title": "Other Mac"])
        try mac.write(SyncCollection.send, record.id, ["state": "taken", "chat": "a:other"])
        let refused = await until { app.chats.chat(local)?.messages.last?.text.contains("couldn’t be opened") == true }
        XCTAssertTrue(refused)
        XCTAssertEqual(app.chatSheet.chatID, local)
        XCTAssertNotNil(app.chats.chat(local))
    }

    func testAttachingAnEmptyAccountKeepsAPersonsLocalBrowser() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let local = World(name: "local", space: "mine", spaces: [Space(id: "mine", name: "Mine", emoji: "🏠", tint: RGB(1, 2, 3),
                                  today: [Tab(id: "local-tab", title: "Local page", site: "Example", icon: "example", url: "http://example.org/unsynced")])])
        let app = try await phone(server, seal, world: local, ownWorld: false, fixturesEnabled: false)
        XCTAssertEqual(app.browser.spaceID, "mine")
        XCTAssertEqual(app.browser.tab("local-tab")?.url, "http://example.org/unsynced")
        XCTAssertEqual(app.sync.engine?.spaces().count, 1, "a real local profile is imported once the empty account is live")
    }

    func testJoiningAPopulatedAccountKeepsAnUnsyncedLiveProfile() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let profile = BrowserProfile(folder: folder.appendingPathComponent("browser"))
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        let local = PageFixtures.liveTab(for: URL(string: "http://example.org/unsynced?query=one#two")!)
        app.browser.open(local)
        let space = app.browser.spaceID
        await app.flushProfile()
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        keys.keep(seal, share: false)
        app.sync.attach(app, setup: setup(server, ownWorld: false))
        let imported = await until {
            app.sync.line == .live && mac.journal.living(SyncCollection.tab).contains { $0["url"]?.string == local.url }
        }
        XCTAssertTrue(imported, "the person's tabs join the populated Mac account")
        // The starting Personal is the account's: its page went into the first space.
        XCTAssertEqual(space, BrowserProfile.startSpace)
        XCTAssertEqual(app.browser.spaceID, app.sync.localID(first))
        XCTAssertEqual(app.browser.space(app.sync.localID(first))?.tab(local.id)?.url, local.url)
        XCTAssertEqual(app.browser.tab(local.id)?.url, local.url)
        XCTAssertNotNil(app.browser.space(work), "the Mac's spaces are present too")
        XCTAssertEqual(mac.journal.living(SyncCollection.tab).filter { $0["url"]?.string == local.url }.count, 1)
        await app.flushProfile()
        let disk = BrowserProfile(folder: profile.folder)
        XCTAssertEqual(disk.world.spaces.flatMap(\.allTabs).first { $0.id == local.id }?.url, local.url)
        XCTAssertEqual(disk.world.space, app.sync.localID(first))
        app.sync.end()
    }

    func testASyncedLiveProfileKeepsItsIdentityBackHistoryAndScrollOnRelaunch() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let profile = BrowserProfile(folder: folder.appendingPathComponent("browser"))
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        let local = PageFixtures.liveTab(for: URL(string: "https://example.org/b#position")!)
        app.browser.open(local)
        let space = app.browser.spaceID
        profile.capture(app.browser)
        let navigation = BrowserNavigation(entries: [
            .init(url: "https://example.org/a", title: "A", scrollY: 120),
            .init(url: local.url!, title: "B", scrollY: 456)
        ], index: 1)
        profile.navigationChanged(local.id, navigation)
        let secret = PageFixtures.liveTab(for: URL(string: "https://private.example/secret")!, id: "secret-device-tab", isPrivate: true)
        app.browser.open(secret)
        app.browser.select(local.id)
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        keys.keep(seal, share: false)
        app.sync.attach(app, setup: setup(server, ownWorld: false))
        let imported = await until { mac.journal.living(SyncCollection.tab).contains { $0["url"]?.string == local.url } && app.sync.pending == 0 }
        XCTAssertTrue(imported)
        let wire = try XCTUnwrap(mac.journal.living(SyncCollection.tab).first { $0["url"]?.string == local.url })
        XCTAssertNotEqual(wire.id, local.id, "the Mac's UUID differs from a live factory's local id")
        let associations = try String(contentsOf: folder.appendingPathComponent("journal/browser-ids.json"), encoding: .utf8)
        XCTAssertFalse(associations.contains(secret.id), "private identities never enter the persisted sync association")
        await app.flushProfile()
        app.sync.end()

        let restoredProfile = BrowserProfile(folder: profile.folder)
        let again = AppModel(world: restoredProfile.world, fixturesEnabled: false, profile: restoredProfile)
        again.sync.attach(again, setup: setup(server, ownWorld: false))
        let live = await until { again.sync.line == .live && again.sync.ready }
        XCTAssertTrue(live)
        XCTAssertEqual(space, BrowserProfile.startSpace, "the starting Personal, merged into the first space on joining")
        XCTAssertEqual(again.browser.spaceID, again.sync.localID(first))
        XCTAssertEqual(again.browser.tab?.id, local.id)
        XCTAssertEqual(again.browser.tab(local.id)?.url, local.url)
        XCTAssertNil(again.browser.tab(secret.id))
        XCTAssertEqual(restoredProfile.navigation[local.id], navigation)
        await again.flushProfile()
        XCTAssertEqual(BrowserProfile(folder: profile.folder).navigation[local.id], navigation)
        XCTAssertEqual(mac.journal.living(SyncCollection.tab).filter { $0["url"]?.string == local.url }.map(\.id), [wire.id], "relaunch never opens the same page under another wire id")
        again.sync.end()
    }

    func testPrivateExternalLinkReusesItsTabWhilePublicSyncIsPaused() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        defer { mac.client.stop() }
        let app = try await phone(server, seal, fixturesEnabled: false)
        defer { app.sync.end() }
        let privateSpace = try XCTUnwrap(app.browser.spaces.first(where: \.isPrivate))
        app.browser.showSpace(privateSpace.id)
        let target = URL(string: "https://private.example.test/page")!
        app.openLink(target)
        let original = app.browser.tab?.id
        let count = app.browser.space.allTabs.count
        app.sync.engine!.pause(within: 1)
        let paused = await until { app.sync.line == .off }
        XCTAssertTrue(paused)
        app.privateLock.willResignActive()
        app.privateLock.didEnterBackground()
        app.openLink(target)
        app.privateLock.didBecomeActive()
        XCTAssertEqual(app.browser.tab?.id, original, "Private rows cannot be removed by public sync catch-up")
        XCTAssertEqual(app.browser.space.allTabs.count, count)
        XCTAssertTrue(app.browser.tab?.isPrivate == true)
    }

    func testActiveExternalLinkReusesRememberedTabWhenSyncIsLive() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        defer { mac.client.stop() }
        let app = try await phone(server, seal, fixturesEnabled: false)
        defer { app.sync.end() }
        let targetID = "AAAAAAAA-0000-4000-8000-000000000004"
        let remembered = await until { app.browser.tab(targetID) != nil && app.sync.line == .live }
        XCTAssertTrue(remembered)
        app.browser.showSpace(work)
        let count = app.browser.space.allTabs.count
        app.openLink(URL(string: "https://ledger.app/tern/overview")!)
        XCTAssertEqual(app.browser.tab?.id, targetID)
        XCTAssertEqual(app.browser.space.allTabs.count, count, "an active, live profile keeps normal deduplication")
    }

    func testExternalLinkWinsOverCatchUpRemovalOfItsRememberedTab() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        defer { mac.client.stop() }
        let app = try await phone(server, seal, fixturesEnabled: false)
        defer { app.sync.end() }
        let targetID = "AAAAAAAA-0000-4000-8000-000000000004"
        let target = URL(string: "https://ledger.app/tern/overview")!
        let remembered = await until { app.browser.tab(targetID) != nil }
        XCTAssertTrue(remembered)
        app.browser.showSpace(work)
        app.browser.select("AAAAAAAA-0000-4000-8000-000000000002")
        app.sync.engine!.pause(within: 1)
        let paused = await until { app.sync.line == .off }
        XCTAssertTrue(paused)
        app.pages.appWillResignActive()
        app.privateLock.willResignActive()
        app.tabClear.resigned()

        // The Mac closes a remembered tab while the phone's line is down.
        try mac.journal.remove(.init(collection: SyncCollection.tab, id: targetID))
        let marker = "CCCCCCCC-0000-4000-8000-000000000099"
        try mac.write(SyncCollection.tab, marker,
                      SyncTab(id: marker, space: work, order: "z", url: "https://example.test/caught-up", title: "Caught up", kept: true).fields)
        mac.client.kick()
        let sent = await until { mac.pending == 0 }
        XCTAssertTrue(sent)
        XCTAssertNotNil(app.browser.tab(targetID), "the phone still remembers the old tab before catch-up")

        // A first tap selects that remembered row before foreground catch-up.
        app.openLink(target)
        XCTAssertEqual(app.browser.tab?.navigationURL, target)
        app.privateLock.didBecomeActive()
        app.tabClear.becameActive()
        app.pages.appDidBecomeActive()
        app.sync.cameToFront()
        let caughtUp = await until { app.browser.tab(marker) != nil }
        XCTAssertTrue(caughtUp, "the remote batch must actually arrive")
        XCTAssertEqual(app.browser.tab?.navigationURL, target,
                       "catch-up must not replace the explicitly requested page with the old page")
    }

    /// Row 1176: a link from another app launched Yab, in sync, and the tab
    /// it opened went as the journal came in (read off the main thread, it
    /// lands after the link): Yab showed the page that was in front before.
    func testALinkThatLaunchedYabStaysInFrontOnceTheJournalIsRead() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let profile = BrowserProfile(folder: folder.appendingPathComponent("browser"))
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        let before = PageFixtures.liveTab(for: URL(string: "https://example.org/before")!)
        app.browser.open(before)
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        keys.keep(seal, share: false)
        app.sync.attach(app, setup: setup(server, ownWorld: false))
        let synced = await until { mac.journal.living(SyncCollection.tab).contains { $0["url"]?.string == before.url } && app.sync.pending == 0 }
        XCTAssertTrue(synced)
        await app.flushProfile()
        app.sync.end()

        // The next launch, for a link: the scene opens it on the main thread
        // while the journal is still being read.
        let restored = BrowserProfile(folder: profile.folder)
        let again = AppModel(world: restored.world, fixturesEnabled: false, profile: restored)
        again.sync.attach(again, setup: setup(server, ownWorld: false))
        let link = URL(string: "https://example.com/from-another-app")!
        again.openLink(link)
        XCTAssertEqual(again.browser.tab?.navigationURL, link)
        let live = await until { again.sync.line == .live && again.sync.ready && again.sync.pending == 0 }
        XCTAssertTrue(live)
        XCTAssertEqual(again.browser.tab?.navigationURL, link, "the link's page is in front, not \(again.browser.tab?.url ?? "nil")")
        XCTAssertEqual(again.browser.space.today.first?.navigationURL, link, "at the top of today's")
        let sent = await until { mac.journal.living(SyncCollection.tab).contains { $0["url"]?.string == link.absoluteString } }
        XCTAssertTrue(sent, "the link's tab reaches the Mac")
        XCTAssertNotNil(again.browser.tab(before.id), "the page before stays a tab")
        again.sync.end()
    }

    func testARemovedMappedSpaceIsNotImportedAgainFromAStaleLiveProfile() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let profile = BrowserProfile(folder: folder.appendingPathComponent("browser"))
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        let local = PageFixtures.liveTab(for: URL(string: "https://example.org/removed-space")!)
        app.browser.open(local)
        let space = app.browser.spaceID
        // Renamed, the starting space is a space of the person's own, not the account's Personal.
        app.browser.setSpace(space, name: "Reading")
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        keys.keep(seal, share: false)
        app.sync.attach(app, setup: setup(server, ownWorld: false))
        let imported = await until { mac.journal.living(SyncCollection.tab).contains { $0["url"]?.string == local.url } && app.sync.pending == 0 }
        XCTAssertTrue(imported)
        let row = try XCTUnwrap(mac.journal.living(SyncCollection.tab).first { $0["url"]?.string == local.url })
        let wireSpace = try XCTUnwrap(SyncTab(row)).space
        await app.flushProfile()
        app.sync.end()
        try mac.journal.remove(.init(collection: SyncCollection.space, id: wireSpace))
        mac.client.kick()
        let removed = await until { mac.pending == 0 }
        XCTAssertTrue(removed)

        let stale = BrowserProfile(folder: profile.folder)
        XCTAssertNotNil(stale.world.spaces.first { $0.id == space })
        let again = AppModel(world: stale.world, fixturesEnabled: false, profile: stale)
        again.sync.attach(again, setup: setup(server, ownWorld: false))
        let dropped = await until { again.sync.line == .live && again.browser.space(space) == nil }
        XCTAssertTrue(dropped, "a known journal tombstone is a removal, not an unsynced local space")
        XCTAssertFalse(mac.journal.living(SyncCollection.space).contains { $0.id == wireSpace })
        XCTAssertNil(again.browser.tab(local.id))
        await again.flushProfile()
        XCTAssertNil(BrowserProfile(folder: profile.folder).world.spaces.first { $0.id == space })
        again.sync.end()
    }

    func testAFailedOnDeviceAnswerKeepsActualPageContextOnThisIPhone() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal, fixturesEnabled: false)
        let model = FailingDevice()
        app.chatSheet.answerers.device = model
        app.chatSheet.answerers.pageAnswers = { .iPhone }
        let page = Tab(id: "peek-page", title: "A real article", site: "Example", icon: "example", url: "http://example.org/article?lang=ru#intro")
        app.ask("Summarize this article", page: page)
        let local = try XCTUnwrap(app.chatSheet.chatID)
        let released = await until { model.calls == 1 && !app.chatSheet.answeringHere.contains(local) }
        XCTAssertTrue(released)
        XCTAssertEqual(app.chats.chat(local)?.by, .iphone)
        XCTAssertEqual(app.chats.chat(local)?.messages.last?.text, Answerers.LocalFailure.interrupted.localizedDescription)
        XCTAssertFalse(app.chats.chat(local)?.messages.contains { $0.role == .answer || $0.role == .typing || $0.role == .wait } == true)
        app.sync.flushLocal()
        XCTAssertTrue(app.sync.engine?.sends().isEmpty == true)
        XCTAssertTrue(mac.journal.living(SyncCollection.send).isEmpty)
        XCTAssertEqual(app.chatSheet.pageSources[local]?.url, page.url)
    }

    func testAFollowupWaitsWhileTheIPhoneAnswersAndRetriesLocallyAfterFailure() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal, fixturesEnabled: false)
        let model = SuspendedFailingDevice()
        app.chatSheet.answerers.device = model
        app.chatSheet.answerers.pageAnswers = { .iPhone }
        let page = PageFixtures.liveTab(for: URL(string: "https://example.org/article")!)
        app.ask("First question", page: page)
        let local = try XCTUnwrap(app.chatSheet.chatID)
        let answering = await until { model.calls == 1 }
        XCTAssertTrue(answering)
        app.chatSheet.draft = "Second question"
        app.send("Second question")
        XCTAssertEqual(app.chatSheet.draft, "Second question")
        XCTAssertEqual(model.calls, 1)
        XCTAssertEqual(app.chats.chat(local)?.messages.filter { $0.role == .you }.map(\.text), ["First question"])
        model.fail()
        let released = await until { !app.chatSheet.answeringHere.contains(local) }
        XCTAssertTrue(released)
        XCTAssertEqual(app.chatSheet.draft, "Second question")
        XCTAssertEqual(app.chats.chat(local)?.messages.last?.text, Answerers.LocalFailure.interrupted.localizedDescription)
        XCTAssertTrue(app.sync.engine?.sends().isEmpty == true)
        app.send(app.chatSheet.draft)
        let again = await until { model.calls == 2 }
        XCTAssertTrue(again, "a failed local turn releases its pending guard")
        XCTAssertEqual(app.chatSheet.draft, "")
        XCTAssertEqual(app.chats.chat(local)?.messages.filter { $0.role == .you && $0.text == "Second question" }.count, 1)
        model.fail()
        let finished = await until { !app.chatSheet.answeringHere.contains(local) }
        XCTAssertTrue(finished)
        XCTAssertFalse(app.chatSheet.sendingToMac.contains(local))
        XCTAssertTrue(app.sync.engine?.sends().isEmpty == true)
        XCTAssertTrue(mac.journal.living(SyncCollection.send).isEmpty)
        app.sync.end()
    }

    func testRealNavigationSyncPreservesSchemeAndFragment() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await macWithWork(server, seal)
        let app = try await phone(server, seal, fixturesEnabled: false)
        _ = await until { self.macToday(app).count == 3 }
        app.browser.showSpace(work)
        let id = UUID().uuidString
        app.browser.open(Tab(id: id, title: "Start", site: "Example", icon: "example", url: "https://example.org/start"))
        _ = await until { mac.row(self.work).today.contains { $0.id == id } }
        app.browser.replace(id, with: Tab(id: id, title: "A real site", site: "Example", icon: "example", url: "http://example.org/a%2Fb?query=1#first"))
        let sent = await until { mac.row(self.work).today.first { $0.id == id }?.url == "http://example.org/a%2Fb?query=1#first" }
        XCTAssertTrue(sent)
        app.browser.replace(id, with: Tab(id: id, title: "A real site", site: "Example", icon: "example", url: "https://example.org/a%2Fb?query=1#second"))
        let changed = await until { mac.row(self.work).today.first { $0.id == id }?.url == "https://example.org/a%2Fb?query=1#second" }
        XCTAssertTrue(changed)
    }
}
