import XCTest
@testable import YabPhone

/// DownloadStore's list, disk and words, the question and what Site Settings
/// keeps of it. The real transfers are PageDownloadTests'.
@MainActor
final class DownloadStoreTests: XCTestCase {
    private var root: URL!
    private var folder: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    private var privateFolder: URL { root.appendingPathComponent("private", isDirectory: true) }
    private var index: URL { root.appendingPathComponent("index.json") }
    private var oldDisabled = false

    override func setUp() async throws {
        oldDisabled = Motion.disabled; Motion.disabled = true
        root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-store-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        Motion.disabled = oldDisabled
        try? FileManager.default.removeItem(at: root)
    }

    private func store() -> DownloadStore { DownloadStore(folder: folder, privateFolder: privateFolder, index: index) }

    private func incoming(_ words: String = "bytes") throws -> URL {
        let file = root.appendingPathComponent(UUID().uuidString)
        try Data(words.utf8).write(to: file)
        return file
    }

    @discardableResult
    private func finished(_ store: DownloadStore, _ name: String, host: String = "acme.com", isPrivate: Bool = false) throws -> UUID {
        let id = UUID()
        store.begin(id, name: name, host: host, total: nil, isPrivate: isPrivate, control: .init())
        XCTAssertTrue(store.finish(id, from: try incoming()))
        return id
    }

    func testAFileReachesTheFolderAndSurvivesALaunch() throws {
        let first = store()
        let id = try finished(first, "report.pdf", host: "www.Acme.com")
        let entry = try XCTUnwrap(first.entry(id))
        XCTAssertEqual(entry.state, .done)
        XCTAssertEqual(entry.host, "acme.com", "kept as Site Settings keys it")
        XCTAssertEqual(entry.size, 5)
        XCTAssertEqual(first.url(of: entry), folder.appendingPathComponent("report.pdf"))
        let again = store()
        XCTAssertEqual(again.entries.map(\.name), ["report.pdf"])
        XCTAssertEqual(again.entries.first?.host, "acme.com")
        XCTAssertEqual(again.entries.first?.size, 5)
    }

    func testNamesNeverOverwrite() throws {
        let store = store()
        try finished(store, "report.pdf")
        try finished(store, "report.pdf")
        try finished(store, "report.pdf")
        try finished(store, "plain")
        try finished(store, "plain")
        XCTAssertEqual(Set(store.entries.map(\.name)), ["report.pdf", "report 2.pdf", "report 3.pdf", "plain", "plain 2"])
    }

    func testAFileGoneFromFilesGoesFromTheList() throws {
        let store = store()
        let id = try finished(store, "report.pdf")
        try FileManager.default.removeItem(at: try XCTUnwrap(store.url(of: try XCTUnwrap(store.entry(id)))))
        store.comeBack()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(self.store().entries.isEmpty, "the index forgot it too")
    }

    func testDeleteTakesTheFile() throws {
        let store = store()
        let id = try finished(store, "report.pdf")
        let url = try XCTUnwrap(store.url(of: try XCTUnwrap(store.entry(id))))
        store.delete(id)
        XCTAssertNil(store.entry(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOnlyWholeFilesAreKept() throws {
        let first = store()
        first.begin(UUID(), name: "going.zip", host: "acme.com", total: 100, isPrivate: false, control: .init())
        let failed = UUID()
        first.begin(failed, name: "broken.zip", host: "acme.com", total: 100, isPrivate: false, control: .init())
        first.fail(failed, retry: {})
        try finished(first, "whole.pdf")
        XCTAssertEqual(store().entries.map(\.name), ["whole.pdf"])
    }

    /// A file that ends while a list of its own kind is open was watched; one
    /// the open list doesn't show, or one that ends with Yab away, waits.
    func testAFileEndingInAnOpenListIsSeen() throws {
        let store = store()
        store.showsList("button", isPrivate: false)
        try finished(store, "seen.pdf")
        XCTAssertEqual(store.arrival?.seen, true)
        try finished(store, "secret.pdf", isPrivate: true)
        XCTAssertEqual(store.arrival?.seen, false, "an ordinary list doesn't show a private file")
        store.leave()
        try finished(store, "away.pdf")
        store.comeBack()
        XCTAssertEqual(store.arrival?.seen, false, "nobody watched it end")
        store.showsList("button", isPrivate: nil)
        try finished(store, "closed.pdf")
        XCTAssertEqual(store.arrival?.seen, false, "the list closed")
    }

    /// A list opened shows only its own kind's files: the other kind's last
    /// file still waits on its button.
    func testOpeningAListSeesOnlyAFileItShows() throws {
        let store = store()
        try finished(store, "secret.pdf", isPrivate: true)
        store.showsList("button", isPrivate: false)
        XCTAssertEqual(store.arrival?.seen, false, "an ordinary list doesn't show a private file")
        store.showsList("button", isPrivate: true)
        XCTAssertEqual(store.arrival?.seen, true)
        store.showsList("button", isPrivate: nil)
        try finished(store, "open.pdf")
        store.showsList("button", isPrivate: true)
        XCTAssertEqual(store.arrival?.seen, false, "a private list doesn't show an ordinary file")
        store.showsList("button", isPrivate: false)
        XCTAssertEqual(store.arrival?.seen, true)
    }

    func testAPrivateFileStaysOutAndGoesWithThePrivateTabs() throws {
        let first = store()
        let id = try finished(first, "secret.pdf", isPrivate: true)
        try finished(first, "open.pdf")
        let entry = try XCTUnwrap(first.entry(id))
        let url = try XCTUnwrap(first.url(of: entry))
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "private", "never in the folder Files shows")
        XCTAssertEqual(first.list(isPrivate: false).map(\.name), ["open.pdf"])
        XCTAssertEqual(first.list(isPrivate: true).map(\.name), ["secret.pdf"])
        XCTAssertNil(first.nowItem(isPrivate: false).flatMap { $0.title == "secret.pdf" ? $0 : nil }, "the ordinary line never names it")
        XCTAssertEqual(store().entries.map(\.name), ["open.pdf"], "never in the index")
        first.forgetPrivate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(first.entries.map(\.name), ["open.pdf"])
    }

    /// Retry starts a private row again under its id: whatever the new
    /// transfer says, the row stays private and its file lands in private.
    func testARetriedPrivateRowStaysPrivate() throws {
        let store = store()
        let id = UUID()
        store.begin(id, name: "secret.pdf", host: "acme.com", total: nil, isPrivate: true, control: .init())
        store.fail(id, retry: {})
        store.begin(id, name: "secret.pdf", host: "acme.com", total: nil, isPrivate: false, control: .init())
        XCTAssertEqual(store.entry(id)?.isPrivate, true)
        XCTAssertTrue(store.finish(id, from: try incoming()))
        let entry = try XCTUnwrap(store.entry(id))
        XCTAssertEqual(try XCTUnwrap(store.url(of: entry)).deletingLastPathComponent().lastPathComponent, "private")
        XCTAssertTrue(store.list(isPrivate: false).isEmpty)
    }

    /// The iPad's button: a file pressed for flies from where it was held,
    /// only where something draws the flight; one with no place only bumps.
    func testAFileFliesFromWhereItWasHeldOnlyWhereFlightsAreDrawn() {
        let store = store()
        let at = CGPoint(x: 120, y: 340)
        store.begin(UUID(), name: "a.pdf", host: "acme.com", total: nil, isPrivate: false, control: .init(), from: at)
        XCTAssertTrue(store.flights.isEmpty, "the phone's Now line says it instead")
        XCTAssertEqual(store.bumps, 1)
        store.flies = true
        let thrown = UUID()
        store.begin(thrown, name: "b.pdf", host: "acme.com", total: nil, isPrivate: false, control: .init(), from: at)
        XCTAssertEqual(store.flights, [DownloadStore.Flight(id: thrown, from: at, name: "b.pdf")])
        XCTAssertEqual(store.bumps, 1, "no bump until it lands")
        store.landed(thrown)
        XCTAssertTrue(store.flights.isEmpty)
        XCTAssertEqual(store.bumps, 2)
        store.begin(UUID(), name: "c.pdf", host: "acme.com", total: nil, isPrivate: false, control: .init())
        XCTAssertTrue(store.flights.isEmpty, "no place held: the button only gives")
        XCTAssertEqual(store.bumps, 3)
    }

    /// One fact, the last file in: the iPad's button keeps a done file's
    /// icon, with no timer, until the list or the file opens, or the file goes.
    func testTheLastFileWaitsUntilSeen() throws {
        let store = store()
        let first = try finished(store, "one.pdf")
        XCTAssertEqual(store.arrival?.id, first)
        XCTAssertEqual(store.arrival?.done, true)
        XCTAssertEqual(store.arrival?.seen, false)
        let second = try finished(store, "two.pdf")
        XCTAssertEqual(store.arrival?.id, second, "the newest one")
        store.seen(first)
        XCTAssertEqual(store.arrival?.seen, false, "opening another file leaves it")
        store.seen(second)
        XCTAssertEqual(store.arrival?.seen, true)
        try finished(store, "three.pdf")
        store.listOpened(isPrivate: false)
        XCTAssertEqual(store.arrival?.seen, true, "the list opened")
        let fourth = try finished(store, "four.pdf")
        store.delete(fourth)
        XCTAssertNil(store.arrival)
        let secret = try finished(store, "secret.pdf", isPrivate: true)
        XCTAssertEqual(store.arrival?.id, secret)
        store.forgetPrivate()
        XCTAssertNil(store.arrival, "gone with the private tabs")
        let broken = UUID()
        store.begin(broken, name: "broken.zip", host: "acme.com", total: nil, isPrivate: false, control: .init())
        store.fail(broken, retry: {})
        XCTAssertEqual(store.arrival?.id, broken)
        XCTAssertEqual(store.arrival?.done, false, "a failure is the last file in too")
        store.begin(broken, name: "broken.zip", host: "acme.com", total: nil, isPrivate: false, control: .init())
        XCTAssertNil(store.arrival, "tried again: not in yet")
    }

    /// A list opened shows only its own kind's files: the other kind's last
    /// file still waits on its button.
    func testShowsListSeesOnlyAFileItShows() throws {
        let store = store()
        try finished(store, "secret.pdf", isPrivate: true)
        store.listOpened(isPrivate: false)
        XCTAssertEqual(store.arrival?.seen, false, "an ordinary list doesn't show a private file")
        store.listOpened(isPrivate: true)
        XCTAssertEqual(store.arrival?.seen, true)
        try finished(store, "open.pdf")
        store.listOpened(isPrivate: true)
        XCTAssertEqual(store.arrival?.seen, false, "a private list doesn't show an ordinary file")
        store.listOpened(isPrivate: false)
        XCTAssertEqual(store.arrival?.seen, true)
    }

    /// The Now line's two seconds are the line's: the icon the iPad keeps
    /// outlives them, and a file seen ends the line at once.
    func testTheLineEndsWithoutEndingTheArrival() async throws {
        let store = store()
        let id = try finished(store, "report.pdf")
        XCTAssertEqual(store.nowItem(isPrivate: false)?.subtitle, "Open")
        try await Task.sleep(for: .milliseconds(2300))
        XCTAssertNil(store.nowItem(isPrivate: false))
        XCTAssertEqual(store.arrival?.id, id)
        XCTAssertEqual(store.arrival?.seen, false, "still waiting on the iPad's button")
        let next = try finished(store, "next.pdf")
        store.seen(next)
        XCTAssertNil(store.nowItem(isPrivate: false), "opened: the line has nothing to say")
    }

    /// Away, the file is in but nothing says it; back, the line has its
    /// whole two seconds.
    func testAwayTheLineWaitsForTheReturn() throws {
        let store = store()
        store.leave()
        let id = try finished(store, "report.pdf")
        XCTAssertEqual(store.arrival?.id, id)
        XCTAssertNil(store.nowItem(isPrivate: false), "nothing is said while Yab is away")
        store.comeBack()
        XCTAssertEqual(store.nowItem(isPrivate: false)?.subtitle, "Open")
    }

    /// Documents open as files; pages, pictures and text stay pages.
    func testWhichTypesOpenInTheViewer() {
        for type in ["application/pdf", "Application/PDF; charset=binary", "text/pdf",
                     "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/vnd.apple.keynote"] {
            XCTAssertTrue(PageDocument.opensInViewer(type), type)
        }
        for type in ["text/html", "image/png", "video/mp4", "text/plain", "application/json", ""] {
            XCTAssertFalse(PageDocument.opensInViewer(type), type)
        }
        XCTAssertFalse(PageDocument.opensInViewer(nil))
    }

    func testALaunchClearsWhatAKilledPrivateSessionLeft() throws {
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: privateFolder.appendingPathComponent("left.pdf"))
        _ = store()
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateFolder.path))
    }

    func testSiteFilter() throws {
        let store = store()
        try finished(store, "a.pdf", host: "acme.com")
        try finished(store, "b.pdf", host: "figma.com")
        XCTAssertEqual(store.list(isPrivate: false, host: "www.acme.com").map(\.name), ["a.pdf"])
        XCTAssertEqual(store.list(isPrivate: false).count, 2)
    }

    func testProgressMovesInSteps() {
        let store = store()
        let id = UUID()
        store.begin(id, name: "a.bin", host: "acme.com", total: 10_000, isPrivate: false, control: .init())
        store.progress(id, received: 4_200, total: 10_000)
        XCTAssertEqual(store.entry(id)?.state, .running(received: 4_200, total: 10_000))
        store.progress(id, received: 4_250, total: 10_000)
        XCTAssertEqual(store.entry(id)?.state, .running(received: 4_200, total: 10_000), "the same percent draws nothing")
    }

    func testTheLineInWords() throws {
        let store = store()
        XCTAssertNil(store.nowItem(isPrivate: false))
        let one = UUID(), two = UUID(), three = UUID()
        store.begin(one, name: "report.pdf", host: "acme.com", total: 1000, isPrivate: false, control: .init())
        store.progress(one, received: 420, total: 1000)
        var item = try XCTUnwrap(store.nowItem(isPrivate: false))
        XCTAssertEqual(item.title, "report.pdf"); XCTAssertEqual(item.subtitle, "42%"); XCTAssertEqual(item.short, "42%")
        XCTAssertEqual(item.kind, .download)
        store.begin(two, name: "b.zip", host: "acme.com", total: 1000, isPrivate: false, control: .init())
        store.progress(two, received: 420, total: 1000)
        store.begin(three, name: "c.zip", host: "acme.com", total: 1000, isPrivate: false, control: .init())
        store.progress(three, received: 420, total: 1000)
        item = try XCTUnwrap(store.nowItem(isPrivate: false))
        XCTAssertEqual(item.title, "3 files · 42%"); XCTAssertEqual(item.subtitle, "")
        store.drop(two); store.drop(three); store.drop(one)
        let done = UUID()
        store.begin(done, name: "report.pdf", host: "acme.com", total: 5, isPrivate: false, control: .init())
        store.finish(done, from: try incoming())
        item = try XCTUnwrap(store.nowItem(isPrivate: false))
        XCTAssertEqual(item.subtitle, "Open")
        store.seen(done)
        XCTAssertNil(store.nowItem(isPrivate: false), "it leaves; the file stays")
        XCTAssertEqual(store.entries.count, 1)
    }

    func testOpenLeavesByItself() async throws {
        let store = store()
        try finished(store, "report.pdf")
        XCTAssertNotNil(store.nowItem(isPrivate: false))
        try await Task.sleep(for: .milliseconds(2300))
        XCTAssertNil(store.nowItem(isPrivate: false))
        XCTAssertEqual(store.entries.count, 1)
    }

    func testRowsMenuAndCardWords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 20))!
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(DownloadWords.ago(now.addingTimeInterval(-20), now: now, calendar: calendar), "just now")
        XCTAssertEqual(DownloadWords.ago(now.addingTimeInterval(-120), now: now, calendar: calendar), "2 min ago")
        XCTAssertEqual(DownloadWords.ago(now.addingTimeInterval(-3 * 3600), now: now, calendar: calendar), "3 hr ago")
        XCTAssertEqual(DownloadWords.ago(now.addingTimeInterval(-24 * 3600), now: now, calendar: calendar), "yesterday")
        XCTAssertEqual(DownloadWords.ago(now.addingTimeInterval(-7 * 86_400), now: now, calendar: calendar, locale: en), "Oct 9")

        var entry = DownloadEntry(id: UUID(), name: "report-2026.pdf", host: "acme.com", size: 2_900_000, date: now, state: .running(received: 1_218_000, total: 2_900_000))
        XCTAssertEqual(DownloadWords.detail(entry, showsHost: true, now: now, calendar: calendar), "42% · 1.2 of 2.9 MB")
        XCTAssertEqual(DownloadWords.menuValue([entry]), "report-2026.pdf 42%")
        entry.state = .failed
        XCTAssertEqual(DownloadWords.detail(entry, showsHost: true, now: now, calendar: calendar), "Didn’t finish")
        entry.state = .done
        entry.date = now.addingTimeInterval(-120)
        XCTAssertEqual(DownloadWords.detail(entry, showsHost: true, now: now, calendar: calendar), "acme.com · 2 min ago")
        XCTAssertEqual(DownloadWords.detail(entry, showsHost: false, now: now, calendar: calendar), "2 min ago")
        XCTAssertEqual(DownloadWords.menuValue([entry, entry, entry]), "3")
        XCTAssertNil(DownloadWords.menuValue([]))

        XCTAssertEqual(DownloadWords.askLine(DownloadAsk(id: UUID(), name: "a", host: "acme.com", size: 2_900_000, isPrivate: false)), "acme.com · 2.9 MB")
        XCTAssertEqual(DownloadWords.askLine(DownloadAsk(id: UUID(), name: "a", host: "acme.com", size: nil, isPrivate: false)), "acme.com")
        XCTAssertEqual(DownloadMark.of("hero.PNG"), .photo)
        XCTAssertEqual(DownloadMark.of("report.pdf"), .doc)
    }

    // MARK: - the question

    func testAnAllowedSiteDoesNotAskAndDownloadRemembersIt() throws {
        let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        app.surfaces.toastsStay = true
        var answers: [Bool] = []
        let ask = { (host: String, isPrivate: Bool) -> DownloadAsk in
            let question = DownloadAsk(id: UUID(), name: "a.pdf", host: host, size: 5, isPrivate: isPrivate)
            app.pages.onDownloadAsk?(question) { answers.append($0) }
            return question
        }
        // Cancel: nothing kept, the site asks again.
        var question = ask("acme.com", false)
        XCTAssertEqual(app.downloads.asking(isPrivate: false), question)
        XCTAssertTrue(answers.isEmpty)
        app.answerDownload(question, false)
        XCTAssertEqual(answers, [false])
        XCTAssertNil(app.downloads.asking(isPrivate: false))
        XCTAssertNil(app.siteSettings.decision(.downloads, for: "acme.com", isPrivate: false))
        // Download: remembered in Allowed Here, and no more questions.
        question = ask("acme.com", false)
        app.answerDownload(question, true)
        XCTAssertEqual(answers, [false, true])
        XCTAssertEqual(app.siteSettings.decision(.downloads, for: "acme.com", isPrivate: false), .allowed)
        _ = ask("acme.com", false)
        XCTAssertEqual(answers, [false, true, true])
        XCTAssertNil(app.downloads.asking(isPrivate: false))
        // Off in Site Settings: refused, in a word.
        app.siteSettings.setDecision(.off, .downloads, for: "acme.com", isPrivate: false)
        _ = ask("acme.com", false)
        XCTAssertEqual(answers.last, false)
        XCTAssertEqual(app.surfaces.toast?.text, "Downloads are off for acme.com")
        // A private tab asks every time and leaves nothing in Site Settings.
        question = ask("example.org", true)
        XCTAssertNil(app.downloads.asking(isPrivate: false), "the card shows only in its own kind of tab")
        XCTAssertEqual(app.downloads.asking(isPrivate: true), question)
        app.answerDownload(question, true)
        XCTAssertNil(app.siteSettings.decision(.downloads, for: "example.org", isPrivate: true))
        XCTAssertNil(app.siteSettings.decision(.downloads, for: "example.org", isPrivate: false))
        _ = ask("example.org", true)
        XCTAssertNotNil(app.downloads.asking(isPrivate: true), "and asks again")
    }

    func testTheLineOpensTheFileOrTheSheetOnDownloads() throws {
        let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        app.pages.downloads.begin(UUID(), name: "a.zip", host: "acme.com", total: 100, isPrivate: false, control: .init())
        XCTAssertEqual(app.nowItem?.kind, .download)
        app.tapNow(action: nil, from: .zero)
        XCTAssertEqual(app.surfaces.menu, .plate)
        XCTAssertEqual(app.pageMenu.page, .downloads, "the plate's morph with the page already set")
        XCTAssertNil(app.pageMenu.downloadsHost)
        app.siteSettingsBack()
        XCTAssertEqual(app.pageMenu.page, .menu)
    }

    func testAskingIsRememberedOnlyByDownload() {
        let settings = SiteSettings(defaults: nil)
        XCTAssertNil(settings.decision(.downloads, for: "acme.com", isPrivate: false))
        settings.setDecision(.allowed, .downloads, for: "acme.com", isPrivate: false)
        XCTAssertEqual(settings.permissions("acme.com", isPrivate: false).map(\.0), [.downloads], "a row in Allowed Here")
        settings.forget(.downloads, for: "acme.com", isPrivate: false)
        XCTAssertTrue(settings.permissions("acme.com", isPrivate: false).isEmpty)
        XCTAssertEqual(SiteSettings.Permission.downloads.title, "Downloads")
    }

    func testHoldKeepsOneDownloadRow() {
        let keep = UIAction(title: "Copy Link") { _ in }
        let system = UIAction(title: "Download Linked File") { _ in }
        let group = UIMenu(options: .displayInline, children: [keep, system])
        let lonely = UIMenu(options: .displayInline, children: [UIAction(title: "Download") { _ in }])
        let kept = PageLinkMenu.withoutDownload([group, lonely])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual((kept.first as? UIMenu)?.children.compactMap { ($0 as? UIAction)?.title }, ["Copy Link"])
    }
}
