import Foundation
import Testing
import SyncKit
@testable import Fast

/// Yab's files as sync records and back (SyncShapes.swift): what goes out
/// comes back the same, a move changes one key, and what is this device's
/// own stays here.
@MainActor
struct SyncShapesTests {
    init() { SyncShapes.register() }

    private func records(_ collection: String, _ fields: SyncShapes.Collection, device: String = "a") throws -> [Record] {
        let j = try Journal(path: nil, device: device)
        try j.reconcile(collection, fields)
        return j.all(collection)
    }

    private func entry(_ n: Int, pin: String? = nil, kept: Bool? = nil, folder: String? = nil) -> Session.Entry {
        Session.Entry(url: "https://shapes.test/\(n)", title: "T\(n)", pin: pin, seen: Double(100 + n), kept: kept,
                      folder: folder, folderName: folder.map { _ in "Reading" }, folderOpen: folder.map { _ in true },
                      visits: n, id: "tab-\(n)")
    }

    @Test func aRowGoesOutAndComesBackTheSame() throws {
        let space = UUID()
        let shape = Session.Shape(tabs: [
            entry(0, pin: "A"),
            entry(1, kept: true, folder: "F1"), entry(2, kept: true, folder: "F1"), entry(3, kept: true),
            entry(4), entry(5),
        ], active: 4, pairs: [Session.Pair(first: 4, second: 5, share: 0.4)])
        let out = SyncShapes.rows([space: shape], orders: [:])
        #expect(out.tabs.count == 6 && out.folders.count == 1 && out.pairs.count == 1)
        let back = SyncShapes.row(space,
                                  tabs: try records(SyncShapes.tab, out.tabs),
                                  folders: try records(SyncShapes.folder, out.folders),
                                  pairs: try records(SyncShapes.pair, out.pairs),
                                  here: shape)
        #expect(back.tabs.map(\.id) == shape.tabs.map(\.id))
        #expect(back.tabs.map(\.url) == shape.tabs.map(\.url))
        #expect(back.tabs[1].folder == "F1" && back.tabs[1].folderName == "Reading" && back.tabs[2].folder == "F1")
        #expect(back.tabs.map(\.visits) == shape.tabs.map(\.visits))
        #expect(back.active == 4)
        #expect(back.pairs?.first?.first == 4 && back.pairs?.first?.second == 5 && back.pairs?.first?.share == 0.4)
    }

    @Test func aLateUpdateCannotReopenATabClosedBeforeTheRowWasPublished() throws {
        let space = UUID()
        let a = try Journal(path: nil, device: "a")
        let b = try Journal(path: nil, device: "b")
        // A kept tab: every Mac's (another Mac's tab of today never is this
        // one's to show or close, docs/sync.md, "Today is each device's own").
        let open = Session.Shape(tabs: [entry(0, kept: true)], active: 0)
        let out = SyncShapes.rows([space: open], orders: [:])
        try a.reconcile(SyncShapes.tab, out.tabs)
        _ = try SyncCenter.receive(a.pending().map { ($0.record, 1) }, into: b, localRows: nil)
        let key = Record.Key(collection: SyncShapes.tab, id: "tab-0")
        #expect(b.record(key)?.alive() == true, "joining takes the account's tab")
        let late = try a.change(key, ["title": "A title that arrived after the local close"])
        let closed = Session.Shape(tabs: [], active: 0)
        _ = try SyncCenter.receive([(late, 2)], into: b, localRows: [space: closed])
        #expect(b.record(key)?.alive() == false)
        #expect(b.pending().contains { $0.record.key == key && !$0.record.alive() })
        let shown = SyncShapes.row(space, tabs: b.all(SyncShapes.tab), folders: [], pairs: [], here: closed)
        #expect(shown.tabs.isEmpty)
        _ = try a.receive(b.pending().map { ($0.record, 3) })
        #expect(a.record(key)?.alive() == false, "the close also reaches the other Mac")
    }

    @Test func aTabFromAnotherMacLandsInOrderAndTheFrontTabStays() throws {
        let space = UUID()
        let mine = Session.Shape(tabs: [entry(0), entry(1), entry(2)], active: 2)
        let out = SyncShapes.rows([space: mine], orders: [:])
        let a = try Journal(path: nil, device: "a")
        try a.reconcile(SyncShapes.tab, out.tabs)
        // The other Mac opened one between the first two.
        let b = try Journal(path: nil, device: "b")
        _ = try b.receive(a.pending().map { ($0.record, 1) })
        let first = b.record(.init(collection: SyncShapes.tab, id: "tab-0"))?["order"]?.string
        let second = b.record(.init(collection: SyncShapes.tab, id: "tab-1"))?["order"]?.string
        try b.change(.init(collection: SyncShapes.tab, id: "tab-9"),
                     ["parent": .string(space.uuidString), "order": .string(Order.between(first, second)), "url": "https://shapes.test/9", "title": "T9"])
        _ = try a.receive(b.pending().map { ($0.record, 2) })
        let back = SyncShapes.row(space, tabs: a.all(SyncShapes.tab), folders: [], pairs: [], here: mine)
        #expect(back.tabs.map(\.id) == ["tab-0", "tab-9", "tab-1", "tab-2"])
        #expect(back.tabs[back.active].id == "tab-2")
    }

    /// A row left with none in front, or on a shared pin, comes back from
    /// sync so, not on its first tab.
    @Test func aRowLeftWithNoneInFrontStaysSoThroughSync() throws {
        let space = UUID()
        for here in [Session.Shape(tabs: [entry(0, pin: "P"), entry(1, kept: true), entry(2)], front: nil),
                     Session.Shape(tabs: [entry(0, pin: "P"), entry(1, kept: true), entry(2)], front: -1)] {
            let out = SyncShapes.rows([space: here], orders: [:])
            let a = try Journal(path: nil, device: "a")
            try a.reconcile(SyncShapes.tab, out.tabs)
            let back = SyncShapes.row(space, tabs: a.all(SyncShapes.tab), folders: [], pairs: [], here: here)
            #expect(back.tabs.count == 3)
            #expect(back.front == here.front)
        }
    }

    @Test func movingOneTabChangesOneKey() throws {
        let space = UUID()
        let shape = Session.Shape(tabs: (0..<20).map { entry($0) }, active: 0)
        let first = SyncShapes.rows([space: shape], orders: [:]).tabs
        let orders = first.compactMapValues { $0["order"]?.string }
        var moved = shape
        moved.tabs.insert(moved.tabs.remove(at: 15), at: 0)
        let second = SyncShapes.rows([space: moved], orders: orders).tabs
        let changed = second.keys.filter { second[$0]?["order"] != first[$0]?["order"] }
        #expect(changed == ["tab-15"])
    }

    @Test func pinsComeFirstWhateverTheirKeys() throws {
        let space = UUID().uuidString
        let j = try Journal(path: nil, device: "a")
        try j.reconcile(SyncShapes.tab, [
            "today": ["parent": .string(space), "order": "1", "url": "https://shapes.test/t", "title": "t"],
            "kept": ["parent": .string(space), "order": "2", "url": "https://shapes.test/k", "title": "k", "kept": true],
            "pin": ["parent": .string(space), "order": "3", "url": "https://shapes.test/p", "title": "p", "pin": "P"],
        ])
        let back = SyncShapes.row(UUID(uuidString: space)!, tabs: j.all(SyncShapes.tab), folders: [], pairs: [], here: .init(tabs: [], active: 0))
        #expect(back.tabs.map(\.id) == ["pin", "kept", "today"])
    }

    @Test func spacesGoOutAndComeBack() throws {
        let list = [
            Space(id: Space.firstID, name: "Home", icon: "🏠", ownSignIns: false),
            Space(id: UUID(), name: "Work", icon: "💼", ownSignIns: true, origin: "Arc:1"),
        ]
        let back = SyncShapes.spaces(from: try records(SyncShapes.space, SyncShapes.spaces(list, orders: [:])))
        #expect(back == list)
    }

    @Test func bookmarksGoOutAndComeBack() throws {
        let tree = [
            Bookmark(title: "Bar", url: nil, children: [
                .site("A", URL(string: "https://a.test")!, added: Date(timeIntervalSince1970: 1000)),
                Bookmark(title: "Inner", url: nil, children: [.site("B", URL(string: "https://b.test")!, added: nil)]),
            ]),
            .site("C", URL(string: "https://c.test")!, added: nil),
        ]
        let back = SyncShapes.bookmarks(from: try records(SyncShapes.bookmark, SyncShapes.bookmarks(tree, orders: [:])))
        #expect(back == tree)
    }

    @Test func aBookmarkWhoseFolderIsGoneGoesToTheTop() throws {
        let j = try Journal(path: nil, device: "a")
        try j.reconcile(SyncShapes.bookmark, [
            "\(UUID())": ["parent": "root", "order": "V", "title": "kept", "url": "https://k.test"],
            "\(UUID())": ["parent": .string(UUID().uuidString), "order": "V", "title": "lost", "url": "https://l.test"],
        ])
        let back = SyncShapes.bookmarks(from: j.all(SyncShapes.bookmark))
        #expect(back.map(\.title).sorted() == ["kept", "lost"])
    }

    @Test func onlyYourSettingsSync() {
        let defaults: [String: Any] = [
            "look": "dark", "tabs.sleep": 4, "zoom.github.com": 1.25, "shortcuts": ["newTab": "cmd+t"],
            "mail.splits": Data([1, 2, 3]), "passwords.never": ["bank.test"], "peek": true,
            "activity.installation": "secret", "NSWindow Frame main": "0 0 10 10", "models.recent": ["x"], "hints.seen": 3,
        ]
        let out = SyncShapes.settings(defaults)
        #expect(Set(out.keys) == ["look", "tabs.sleep", "zoom.github.com", "shortcuts", "shortcut.newTab", "passwords.never", "peek"])
        #expect(out["peek"]?["value"] == .bool(true))
        #expect(out["tabs.sleep"]?["value"] == .number(4))
        let back = out.compactMapValues { $0["value"].flatMap(SyncShapes.plist) }
        #expect(back["passwords.never"] as? [String] == ["bank.test"])
        #expect(back["peek"] as? Bool == true)
        #expect(back["zoom.github.com"] as? Double == 1.25)
        #expect((back["shortcuts"] as? [String: String]) == ["newTab": "cmd+t"])
    }

    /// A key changed on one Mac and another on a second both stay.
    @Test func shortcutsFromTwoMacsAddUp() throws {
        let ja = try Journal(path: nil, device: "a"), jb = try Journal(path: nil, device: "b")
        let split = SyncShapes.shortcutsSplit
        try SyncShapes.reconcileSettings(ja, [split: true, "shortcuts": ["newTab": "cmd+y"]], addons: true)
        try SyncShapes.reconcileSettings(jb, [split: true, "shortcuts": ["reload": "cmd+e"]], addons: true)
        _ = try jb.receive(ja.pending().map { ($0.record, 1) })
        _ = try ja.receive(jb.pending().map { ($0.record, 1) })
        let both = ["newTab": "cmd+y", "reload": "cmd+e"]
        #expect(SyncShapes.shortcuts(from: ja.living(SyncShapes.setting)) == both)
        #expect(SyncShapes.shortcuts(from: jb.living(SyncShapes.setting)) == both)

        // Back to its own key on B: gone on A too.
        try SyncShapes.reconcileSettings(jb, [split: true, "shortcuts": ["newTab": "cmd+y"]], addons: true)
        _ = try ja.receive(jb.pending().map { ($0.record, 2) })
        #expect(SyncShapes.shortcuts(from: ja.living(SyncShapes.setting)) == ["newTab": "cmd+y"])
    }

    /// The first flush after the update adds this Mac's keys and removes
    /// none of the account's, then hands back all of them.
    @Test func shortcutsSplitWithoutLosingAny() throws {
        let ja = try Journal(path: nil, device: "a"), jb = try Journal(path: nil, device: "b")
        try SyncShapes.reconcileSettings(ja, [SyncShapes.shortcutsSplit: true, "shortcuts": ["newTab": "cmd+y"]], addons: true)
        _ = try jb.receive(ja.pending().map { ($0.record, 1) })
        let keys = try SyncShapes.reconcileSettings(jb, ["shortcuts": ["reload": "cmd+e"]], addons: true)
        #expect(keys == ["newTab": "cmd+y", "reload": "cmd+e"])
        #expect(try SyncShapes.reconcileSettings(jb, [SyncShapes.shortcutsSplit: true, "shortcuts": keys!], addons: true) == nil)
        #expect(SyncShapes.shortcuts(from: jb.living(SyncShapes.setting)) == keys)
    }

    @Test func diaryEntriesFromTwoMacsAddUp() throws {
        let a = FileManager.default.temporaryDirectory.appendingPathComponent("mem-a-\(UUID())")
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("mem-b-\(UUID())")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        for folder in [a, b] { try FileManager.default.createDirectory(at: folder.appendingPathComponent("episodic"), withIntermediateDirectories: true) }
        try "# 2026-10-05\n\n## 09:00 Morning on A\nRead mail.\n".write(to: a.appendingPathComponent("episodic/2026-10-05.md"), atomically: true, encoding: .utf8)
        try "# 2026-10-05\n\n## 11:30 Noon on B\nBooked a table.\n".write(to: b.appendingPathComponent("episodic/2026-10-05.md"), atomically: true, encoding: .utf8)
        try "Sam likes short answers.".write(to: a.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)
        let ja = try Journal(path: nil, device: "a"), jb = try Journal(path: nil, device: "b")
        try ja.reconcile(SyncShapes.memory, SyncShapes.memory(in: a))
        try jb.reconcile(SyncShapes.memory, SyncShapes.memory(in: b))
        _ = try jb.receive(ja.pending().map { ($0.record, 1) })
        let files = SyncShapes.memoryFiles(from: jb.all(SyncShapes.memory))
        #expect(files["USER.md"] == "Sam likes short answers.")
        let day = try #require(files["episodic/2026-10-05.md"])
        #expect(day.hasPrefix("# 2026-10-05"))
        #expect(day.range(of: "## 09:00 Morning on A")!.lowerBound < day.range(of: "## 11:30 Noon on B")!.lowerBound)
    }

    /// A Mac joining with only the empty briefs Memory.prepare seeds doesn't
    /// send them over the account's by a stamp of now (register 3060).
    @Test func aJoiningMacsEmptyBriefsDontReplaceTheAccounts() throws {
        let a = try memoryFolder(), b = try memoryFolder()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let sam = "# User Briefing\n\nSam likes short answers.\n"
        try sam.write(to: a.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)
        try Seeds.user.write(to: b.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)
        try Seeds.operating.write(to: b.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        let ja = try Journal(path: nil, device: "a"), jb = try Journal(path: nil, device: "b")
        try SyncShapes.reconcileMemory(ja, in: a)
        // B's first flush, before its first hello, comes after A wrote its brief.
        try SyncShapes.reconcileMemory(jb, in: b)
        _ = try jb.receive(ja.pending().map { ($0.record, 1) })
        _ = try ja.receive(jb.pending().map { ($0.record, 2) })
        #expect(SyncShapes.memoryFiles(from: ja.all(SyncShapes.memory))["USER.md"] == sam)
        #expect(SyncShapes.memoryFiles(from: jb.all(SyncShapes.memory))["USER.md"] == sam)
    }

    /// A page from another Mac that this folder never took in (held for
    /// review after a clear here, ContextPrivacy.mayTakeSync) is no removal,
    /// and a brief still as this Mac last read it is no edit over a newer
    /// one: the next flush sends nothing back (register 3060).
    @Test func memoryThisFolderNeverTookInIsNoEdit() throws {
        let a = try memoryFolder(), b = try memoryFolder()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let first = "# User Briefing\n\nSam likes short answers.\n"
        for folder in [a, b] { try first.write(to: folder.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8) }
        let ja = try Journal(path: nil, device: "a"), jb = try Journal(path: nil, device: "b")
        try SyncShapes.reconcileMemory(ja, in: a)
        _ = try jb.receive(ja.pending().map { ($0.record, 1) })
        try SyncShapes.reconcileMemory(jb, in: b)
        // A writes a page and a newer brief; B's journal takes them, its folder doesn't.
        let newer = first + "Lives in Pune.\n", jane = "# Jane Doe\n\nWorks with Sam.\n"
        try newer.write(to: a.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: a.appendingPathComponent("people"), withIntermediateDirectories: true)
        try jane.write(to: a.appendingPathComponent("people/jane-doe.md"), atomically: true, encoding: .utf8)
        try SyncShapes.reconcileMemory(ja, in: a)
        _ = try jb.receive(ja.pending().map { ($0.record, 2) })
        try SyncShapes.reconcileMemory(jb, in: b)
        #expect(jb.pending().isEmpty)
        let files = SyncShapes.memoryFiles(from: jb.all(SyncShapes.memory))
        #expect(files["USER.md"] == newer)
        #expect(files["people/jane-doe.md"] == jane)
    }

    /// What this Mac changes still goes: a page removed here, and a brief
    /// emptied here after it said something. A page grown past what sync
    /// carries stays on the other Macs as it was, not removed.
    @Test func memoryChangedHereStillGoes() throws {
        let a = try memoryFolder()
        defer { try? FileManager.default.removeItem(at: a) }
        try FileManager.default.createDirectory(at: a.appendingPathComponent("people"), withIntermediateDirectories: true)
        try "# User Briefing\n\nSam likes short answers.\n".write(to: a.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)
        try "# Jane Doe\n\nWorks with Sam.\n".write(to: a.appendingPathComponent("people/jane-doe.md"), atomically: true, encoding: .utf8)
        try "# Sam\n\nLikes short answers.\n".write(to: a.appendingPathComponent("people/sam.md"), atomically: true, encoding: .utf8)
        let ja = try Journal(path: nil, device: "a")
        try SyncShapes.reconcileMemory(ja, in: a)
        try ja.sent(ja.pending().map { ($0.record, 1) })
        try FileManager.default.removeItem(at: a.appendingPathComponent("people/jane-doe.md"))
        try Seeds.user.write(to: a.appendingPathComponent("USER.md"), atomically: true, encoding: .utf8)
        try ("# Sam\n\n" + String(repeating: "Likes short answers. ", count: 2_500)).write(to: a.appendingPathComponent("people/sam.md"), atomically: true, encoding: .utf8)
        try SyncShapes.reconcileMemory(ja, in: a)
        let sent = Dictionary(uniqueKeysWithValues: ja.pending().map { ($0.record.id, $0.record) })
        #expect(sent["people/jane-doe.md"]?.alive() == false)
        #expect(sent["USER.md"]?["text"]?.string == Seeds.user)
        #expect(sent["people/sam.md"] == nil)
        #expect(ja.record(.init(collection: SyncShapes.memory, id: "people/sam.md"))?.alive() == true)
    }

    /// A page that just came, read back as the app does right after a
    /// delivery, and forgotten here still goes.
    @Test func aPageThatJustCameAndIsForgottenStillGoes() throws {
        let a = try memoryFolder(), b = try memoryFolder()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let ja = try Journal(path: nil, device: "a"), jb = try Journal(path: nil, device: "b")
        try SyncShapes.reconcileMemory(jb, in: b)
        let jane = "# Jane Doe\n\nWorks with Sam.\n"
        for folder in [a, b] { try FileManager.default.createDirectory(at: folder.appendingPathComponent("people"), withIntermediateDirectories: true) }
        try jane.write(to: a.appendingPathComponent("people/jane-doe.md"), atomically: true, encoding: .utf8)
        try SyncShapes.reconcileMemory(ja, in: a)
        _ = try jb.receive(ja.pending().map { ($0.record, 1) })
        try jane.write(to: b.appendingPathComponent("people/jane-doe.md"), atomically: true, encoding: .utf8)
        try SyncShapes.reconcileMemory(jb, in: b)
        #expect(jb.pending().isEmpty)
        try FileManager.default.removeItem(at: b.appendingPathComponent("people/jane-doe.md"))
        try SyncShapes.reconcileMemory(jb, in: b)
        #expect(jb.pending().map { $0.record.id } == ["people/jane-doe.md"])
        #expect(jb.record(.init(collection: SyncShapes.memory, id: "people/jane-doe.md"))?.alive() == false)
    }

    private func memoryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID())")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("episodic"), withIntermediateDirectories: true)
        return folder
    }

    @Test func aRoutineRunsOnOneMacAndKeepsItsRunsThere() throws {
        var routine = Routine(id: "r1", when: "daily 9:00", prompt: "Check the news", last: Date(), said: "Nothing new")
        routine.chat = "abc123"
        let out = SyncShapes.routines([routine], device: "mac-a")
        #expect(out["r1"]?["runsOn"] == "mac-a")
        #expect(out["r1"]?["said"] == nil && out["r1"]?["chat"] == nil && out["r1"]?["last"] == nil)
        let back = SyncShapes.routines(from: try records(SyncShapes.routine, out))
        #expect(back.first?.prompt == "Check the news" && back.first?.runsOn == "mac-a")
        #expect(back.first?.runsHere == (SyncCenter.deviceID == "mac-a"))
    }

    @Test func historyGoesWithoutItsCounts() throws {
        let visit = Visit(url: "https://shapes.test/page", key: "shapes.test/page", title: "Page", count: 7, last: Date(timeIntervalSince1970: 1_000_000), typed: 2)
        let out = SyncShapes.visits([visit])
        #expect(out["shapes.test/page"]?["count"] == nil && out["shapes.test/page"]?["typed"] == .bool(true))
        let back = SyncShapes.visits(from: try records(SyncShapes.visit, out))
        #expect(back.first?.url.absoluteString == "https://shapes.test/page" && back.first?.last == visit.last && back.first?.typed == true)
    }

    /// A page opened on Yab for iPhone, as its sync writes it (SyncVisit.fields:
    /// no count, keyed without the query): read here, taken into History,
    /// found by the field, and sent back under the same key by the next
    /// reconcile, so the Mac never removes the iPhone's record.
    @Test func anIPhonesVisitComesIntoHistoryUnderItsOwnKey() throws {
        let last = Date().timeIntervalSince1970.rounded(.down)
        let phone: SyncShapes.Collection = ["example.org/guide": [
            "url": .string("https://www.example.org/guide?from=phone"), "title": .string("A guide read on the iPhone"),
            "last": .number(last), "typed": .null,
        ]]
        let back = SyncShapes.visits(from: try records(SyncShapes.visit, phone, device: "iphone"))
        let history = History([])
        history.adoptSynced(back)
        let recent = history.visits(since: Date().addingTimeInterval(-SyncShapes.historyDays))
        #expect(recent.map(\.key) == ["example.org/guide"])
        #expect(Set(SyncShapes.visits(recent).keys) == Set(phone.keys))
        #expect(SyncShapes.visits(recent)["example.org/guide"]?["last"] == .number(last))
        #expect(history.suggestions(for: "example").first?.title == "A guide read on the iPhone")
    }

    @Test func aChatLeftRunningWithNoAgentAtItGoesAsStopped() {
        let chat = Chat(id: "orphan1", title: "Left running", began: .field, cli: "claude", items: [], state: "running", answer: "",
                        started: Date(timeIntervalSince1970: 10), updated: Date(timeIntervalSince1970: 20))
        #expect(SyncChats.head(chat, kind: "agent", device: "mac-a")["state"] == "stopped")
        #expect(SyncChats.head(chat, kind: "agent", device: "mac-a", live: true)["state"] == "running")
    }

    @Test func aChatGoesAsItsHeadAndItsLastSteps() {
        let items = (0..<200).map { ChatItem(id: "i\($0)", kind: .message, text: "step \($0)", state: .done) }
        let chat = Chat(id: "abc123", title: "Book a table", began: .field, cli: "claude", items: items, state: "done", answer: "Booked.",
                        started: Date(timeIntervalSince1970: 10), updated: Date(timeIntervalSince1970: 20))
        let head = SyncChats.head(chat, kind: "agent", device: "mac-a")
        #expect(head["device"] == "mac-a" && head["title"] == "Book a table" && head["state"] == "done")
        let out = SyncChats.items(chat, record: SyncChats.id(agent: chat.id))
        #expect(out.count == SyncChats.itemsKept)
        #expect(out["a:abc123/i199"]?["n"] == .number(199) && out["a:abc123/i199"]?["text"] == "step 199")
        #expect(out["a:abc123/i0"] == nil)
    }

    @Test func aMacTakesOnlyTheWordsMeantForIt() throws {
        let j = try Journal(path: nil, device: "phone")
        try j.change(.init(collection: SyncChats.send, id: "s1"), ["device": "mac-a", "text": "hello", "chat": "a:abc", "at": 100])
        try j.change(.init(collection: SyncChats.send, id: "s2"), ["device": "mac-b", "text": "not yours", "at": 101])
        try j.change(.init(collection: SyncChats.send, id: "s3"), ["device": "mac-a", "text": "done before", "at": 102, "state": "taken"])
        try j.change(.init(collection: SyncChats.send, id: "s4"), ["device": "mac-a", "kind": "code", "project": "p1", "text": "new", "at": 99])
        let waiting = SyncChats.waiting(j.all(SyncChats.send), device: "mac-a")
        #expect(waiting.map(\.id) == ["s4", "s1"])
        #expect(waiting[0].kind == "code" && waiting[0].chat == nil && waiting[1].chat == "a:abc")
    }

    @Test func formAnswersGoOneByOneAndMeetAnother() throws {
        let a = FormAnswers.Said(question: "what are you working on", answer: "Yab", site: "lu.ma", at: Date(timeIntervalSince1970: 100))
        let b = FormAnswers.Said(question: "company", answer: "Acme", site: "lu.ma", at: Date(timeIntervalSince1970: 200), fresh: true)
        let out = SyncShapes.answers([a, b])
        #expect(out.count == 2 && out[b.id]?["fresh"] == .bool(true) && out[a.id]?["fresh"] == .null)
        let j = try Journal(path: nil, device: "a")
        try j.reconcile(SyncShapes.answer, out)
        // Another Mac took "company" away; this one has an answer of its own
        // sync hasn't heard of yet.
        try j.remove(.init(collection: SyncShapes.answer, id: b.id))
        let mine = FormAnswers.Said(question: "role", answer: "design", site: "tally.so", at: Date(timeIntervalSince1970: 150))
        let back = SyncShapes.answers(from: j.all(SyncShapes.answer), local: [a, b, mine])
        #expect(back == [a, mine])
    }

    @Test func howFarDownATabWasReadTravelsWithIt() throws {
        let space = UUID()
        var read = entry(1)
        read.depth = 0.42
        let shape = Session.Shape(tabs: [read, entry(2)], active: 0)
        let out = SyncShapes.rows([space: shape], orders: [:])
        #expect(out.tabs["tab-1"]?["depth"] == .number(0.42) && out.tabs["tab-2"]?["depth"] == .null)
        let back = SyncShapes.row(space, tabs: try records(SyncShapes.tab, out.tabs), folders: [], pairs: [], here: shape)
        #expect(back.tabs.map(\.depth) == [0.42, nil])
    }
}
