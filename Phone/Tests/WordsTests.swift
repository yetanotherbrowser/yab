import XCTest
@testable import YabPhone

/// How words read, 200 phrases, from the table the Mac's tests read too
/// (Phone/Tests/WordsPhrases.json, Tests/FastTests/PhoneWordsTests.swift):
/// a phrase leads to the same row on the Mac and the iPhone. Where the
/// prototype's readWords disagrees with the Mac (a one-word question, a verb
/// before a question mark, the prototype's extra verbs) the Mac's reading is
/// kept, and the table says so.
final class WordsTests: XCTestCase {
    typealias K = Words.Kind

    /// Phrase, how it reads: the shared table, read from the checkout.
    static let phrases: [(String, K)] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("WordsPhrases.json")
        struct Table: Decodable {
            struct Group: Decodable { let phrases: [[String]] }
            let groups: [Group]
        }
        guard let data = try? Data(contentsOf: url), let table = try? JSONDecoder().decode(Table.self, from: data) else { return [] }
        return table.groups.flatMap(\.phrases).compactMap { pair in
            guard pair.count == 2, let kind = K(rawValue: pair[1]) else { return nil }
            return (pair[0], kind)
        }
    }()

    func testTwoHundredPhrasesReadAsTheMacReadsThem() {
        XCTAssertGreaterThanOrEqual(Self.phrases.count, 200, "the table has \(Self.phrases.count) phrases")
        var wrong: [String] = []
        for (phrase, kind) in Self.phrases where Words.read(phrase) != kind {
            wrong.append("“\(phrase)”: \(Words.read(phrase).rawValue), expected \(kind.rawValue)")
        }
        XCTAssertTrue(wrong.isEmpty, "\(wrong.count) phrases read otherwise:\n" + wrong.joined(separator: "\n"))
    }

    func testEveryPhraseIsInTheTableOnce() {
        var seen = Set<String>()
        let twice = Self.phrases.map(\.0).filter { !seen.insert($0).inserted }
        XCTAssertEqual(twice, [], "phrases twice in the table")
    }

    /// The prototype's own verbs aren't the Mac's: the iPhone reads them as
    /// the Mac does.
    func testOnlyTheMacsVerbsMakeATask() {
        XCTAssertFalse(TaskReading.verbs.contains("request"))
        XCTAssertEqual(Words.read("request a spot at design systems night"), .search)
    }

    // MARK: - addresses

    @MainActor
    func testHostlessAddressesAndStoredTabsCannotIndexAnEmptyHost() {
        for text in ["/", "?", "#", "?query=1", "#section", ":", ":5000", "", "\n"] {
            XCTAssertNil(Address.url(from: text, names: true), text)
            XCTAssertNil(Address.url(from: text, names: false), text)
            let tab = Tab(id: "malformed", title: "Malformed", site: "", icon: "globe", url: text)
            XCTAssertNil(tab.navigationURL, text)
        }
    }

    func testAddressesGetTheirScheme() {
        XCTAssertEqual(Words.address("lumen.events")?.absoluteString, "https://lumen.events")
        XCTAssertEqual(Words.address("localhost:5173")?.absoluteString, "http://localhost:5173")
        XCTAssertEqual(Words.address("192.168.1.10:8080")?.absoluteString, "http://192.168.1.10:8080")
        XCTAssertEqual(Words.address("https://example.com/a?b=1")?.absoluteString, "https://example.com/a?b=1")
        XCTAssertNil(Words.address("hello world"))
        XCTAssertEqual(Address.pretty(URL(string: "https://www.lumen.events/e/design-systems-night")!), "lumen.events/e/design-systems-night")
    }

    // MARK: - the words beside the kind

    func testWordsThatPointAtThePage() {
        XCTAssertTrue(Words.pointsAtPage("summarize this page"))
        XCTAssertTrue(Words.pointsAtPage("book the seat here"))
        XCTAssertFalse(Words.pointsAtPage("book the tap 18:35 to lisbon"))
        XCTAssertFalse(Words.pointsAtPage("thistle seeds"))
    }

    func testSettingsIsFoundByThreeLetters() {
        XCTAssertTrue(Words.wantsSettings("sett"))
        XCTAssertTrue(Words.wantsSettings("Settings"))
        XCTAssertTrue(Words.wantsSettings("pref"))
        XCTAssertFalse(Words.wantsSettings("se"))
        XCTAssertFalse(Words.wantsSettings("setting up a tent"))
    }

    // MARK: - rows

    private let tabs: [TabCandidate] = [
        TabCandidate(id: "work-figma-onb", title: "Onboarding v3 · Welcome screens", site: "Figma", icon: "figma", folder: "Onboarding v3", space: "Work"),
        TabCandidate(id: "work-onb-spec", title: "Onboarding v3 spec · Paper", site: "Paper", icon: "paper", folder: "Onboarding v3", space: "Work"),
        TabCandidate(id: "work-hn", title: "Hacker News", site: "Hacker News", icon: "hn", space: "Work"),
        TabCandidate(id: "work-lumen", title: "Design Systems Night · Stockholm", site: "Lumen", icon: "lumen", space: "Work"),
        TabCandidate(id: "lisbon-flights", title: "Stockholm to Lisbon · Flights", site: "Google Flights", icon: "google", folder: "Lisbon trip", space: "Lisbon"),
        TabCandidate(id: "lisbon-timeout", title: "The best things to do in Lisbon", site: "Time Out", icon: "timeout", folder: "Lisbon trip", space: "Lisbon"),
        TabCandidate(id: "lisbon-wiki", title: "Lisbon · Wikipedia", site: "Wikipedia", icon: "wiki", space: "Lisbon"),
    ]

    private func describe(_ rows: [WordRow]) -> [String] {
        rows.map { "\($0.title) | \($0.subtitle) | \($0.key.rawValue)" }
    }

    /// field.2: "hacker" finds its tab, then the search, then Ask.
    func testAWordFindsATab() {
        let rows = Words.rows(for: "hacker", in: .page, tabs: tabs, except: "work-figma-onb")
        XCTAssertEqual(describe(rows), [
            "Hacker News | Hacker News · Work | go",
            "hacker | Search Google · in this tab | search",
            "hacker | Ask Claude · about this page | go",
        ])
        XCTAssertEqual(rows.first?.action, .tab(id: "work-hn"))
    }

    /// field.4: a question puts Ask on top, about this page.
    func testAQuestionAsksAboutThePage() {
        let rows = Words.rows(for: "what does anna want?", in: .page, tabs: tabs, except: "work-figma-onb")
        XCTAssertEqual(rows.map(\.action), [.ask, .task, .search])
        XCTAssertEqual(rows.first?.subtitle, "Ask Claude · about this page")
        XCTAssertEqual(rows.first?.key, .go)
    }

    /// Guess from Your Words off: a question or a task searches at Return,
    /// the agent's rows under it; rows taken away are never offered.
    func testWithoutGuessingTheSearchLeads() {
        XCTAssertEqual(Words.rows(for: "how tall is mount everest", in: .newTab, guesses: false).map(\.action), [.search, .ask, .task])
        XCTAssertEqual(Words.rows(for: "how tall is mount everest", in: .newTab, guesses: false).first?.key, .search)
        XCTAssertEqual(Words.rows(for: "book the tap 18:35 to lisbon", in: .page, guesses: false).map(\.action), [.search, .ask, .task])
        XCTAssertEqual(Words.rows(for: "how tall is mount everest", in: .newTab, asks: false, tasks: false).map(\.action), [.search])
        XCTAssertEqual(Words.rows(for: "how tall is mount everest", in: .newTab, asks: false).map(\.action), [.search, .task])
        XCTAssertEqual(Words.rows(for: "lisbon weather october", in: .page, asks: false).map(\.action), [.search])
        XCTAssertEqual(Words.rows(for: "lumen.events", in: .page, guesses: false).map(\.action), [.open, .search])
    }

    /// field.5: a verb first puts the task on top, key send.
    func testAVerbFirstIsATaskForTheMac() {
        let rows = Words.rows(for: "book the tap 18:35 to lisbon, window seat", in: .page, tabs: tabs, except: "lisbon-flights")
        XCTAssertEqual(describe(rows), [
            "book the tap 18:35 to lisbon, window seat | Task for Claude · on your Mac | send",
            "book the tap 18:35 to lisbon, window seat | Ask Claude · about this page | go",
            "book the tap 18:35 to lisbon, window seat | Search Google · in this tab | search",
        ])
        let pointed = Words.rows(for: "summarize this page please", in: .page)
        XCTAssertEqual(pointed.first?.subtitle, "Task for Claude · on your Mac, with this page")
        XCTAssertEqual(Words.rows(for: "summarize this page please", in: .newTab).first?.subtitle, "Task for Claude · on your Mac")
    }

    /// field.3: a plain search, key search.
    func testASearchIsASearch() {
        let rows = Words.rows(for: "lisbon weather october", in: .page, tabs: tabs)
        XCTAssertEqual(rows.first?.action, .search)
        XCTAssertEqual(rows.first?.key, .search)
        XCTAssertEqual(rows.map(\.action), [.search, .ask])
    }

    /// newtab.2: "lis" in New Tab: two tabs, the search, Ask.
    func testNewTabFindsTabsInEverySpace() {
        let rows = Words.rows(for: "lis", in: .newTab, tabs: tabs, sites: NewTabContent.miraSites)
        XCTAssertEqual(describe(rows), [
            "Stockholm to Lisbon · Flights | Google Flights · in Lisbon trip | go",
            "The best things to do in Lisbon | Time Out · in Lisbon trip | go",
            "lis | Search Google · new tab | search",
            "lis | Ask Claude | go",
        ])
        let groups = Words.grouped(rows)
        XCTAssertEqual(groups.map(\.group), [.tabs, .web, .claude])
    }

    func testNewTabOffersTheSiteTheWordsBegin() {
        let rows = Words.rows(for: "lum", in: .newTab, tabs: tabs, sites: NewTabContent.miraSites)
        XCTAssertEqual(rows.map(\.action), [.tab(id: "work-lumen"), .site(key: "lumen"), .search, .ask])
        XCTAssertEqual(rows[1].subtitle, "lumen.events · open in a new tab")
    }

    func testAnAddressOpens() {
        XCTAssertEqual(describe(Words.rows(for: "lumen.events", in: .page)), [
            "lumen.events | Open in this tab | go", "lumen.events | Search Google · in this tab | search",
        ])
        XCTAssertEqual(Words.rows(for: "lumen.events", in: .newTab).first?.subtitle, "Open in a new tab")
    }

    /// settings.2: three letters of "settings" put Yab's Settings on top.
    func testSettingsComesFirst() {
        let rows = Words.rows(for: "sett", in: .newTab, tabs: tabs, sites: NewTabContent.miraSites)
        XCTAssertEqual(describe(rows), [
            "Settings | Yab on this \(DeviceWord.name) | go",
            "sett | Search Google · new tab | search",
            "sett | Ask Claude | go",
        ])
        XCTAssertEqual(Words.grouped(rows).first?.group, .yab)
    }

    /// privacy.3: with the eyes shut, only where the words go.
    func testIncognitoKeepsNoHistory() {
        XCTAssertEqual(describe(Words.rows(for: "gift ideas for jonas", in: .privateTab, tabs: tabs)), [
            "gift ideas for jonas | Search Google · new tab | search",
        ])
        XCTAssertEqual(Words.rows(for: "hacker", in: .privateTab, tabs: tabs).map(\.action), [.search])
        XCTAssertEqual(Words.rows(for: "lumen.events", in: .privateTab).map(\.action), [.open, .search])
        XCTAssertEqual(Words.rows(for: "settings", in: .privateTab).map(\.action), [.search])
        XCTAssertEqual(Words.rows(for: "book a table for two", in: .privateTab).map(\.action), [.search])
    }

    func testTabsNeedTwoLettersAndNeverTheTabInFront() {
        XCTAssertEqual(Words.rows(for: "h", in: .page, tabs: tabs).map(\.action), [.search, .ask])
        let onboarding = Words.rows(for: "onboarding", in: .page, tabs: tabs, except: "work-figma-onb")
        XCTAssertEqual(onboarding.first?.action, .tab(id: "work-onb-spec"))
        XCTAssertFalse(onboarding.contains { $0.action == .tab(id: "work-figma-onb") })
        // At most two tabs, at most four rows.
        let lisbon = Words.rows(for: "lisbon", in: .page, tabs: tabs)
        XCTAssertEqual(lisbon.filter { if case .tab = $0.action { true } else { false } }.count, 2)
        XCTAssertLessThanOrEqual(lisbon.count, 4)
    }

    func testTheKeyIsTheTopRows() {
        XCTAssertEqual(Words.rows(for: "hacker", in: .page, tabs: tabs).first?.key, .go)
        XCTAssertEqual(Words.rows(for: "lisbon weather october", in: .page).first?.key, .search)
        XCTAssertEqual(Words.rows(for: "draft replies to anna", in: .page).first?.key, .send)
        XCTAssertEqual(Words.rows(for: "is figma down", in: .page).first?.key, .go)
        XCTAssertTrue(Words.rows(for: "", in: .page).isEmpty)
    }
}
