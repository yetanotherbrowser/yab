import Foundation
import Testing
@testable import Fast

// Day threads (docs/day-threads.md): visits grouped into what you were
// doing, kept beside them in the diary, named, forgotten and given back.
// Fixture data only: a diary of its own in a temporary folder, a seeded
// month of visits as evals seed one (agent-evals.md), never this Mac's.
struct DayThreadsTests {
    /// Three days ago at a time: never today, so no thread is still open.
    static func at(_ hour: Int, _ minute: Int, daysAgo: Int = 3) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date()))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    static func page(_ link: String, _ title: String, _ at: Date, space: String = "s1", quiet: Bool = false, text: String = "") -> Diary.Planted {
        Diary.Planted(url: URL(string: link)!, title: title, at: at, space: space, quiet: quiet, text: text)
    }

    static func diary() -> (Diary, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("threads-" + UUID().uuidString)
        return (Diary.scratch(folder.appendingPathComponent("diary.sqlite")), folder)
    }

    static func day(_ diary: Diary, _ date: Date) async -> [DayThread] {
        let from = Calendar.current.startOfDay(for: date)
        return await diary.threads(from: from, to: from.addingTimeInterval(86_400))
    }

    /// The morning the prototype draws: Lumen, then pricing, then flights.
    static let morning: [Diary.Planted] = [
        page("https://lumen.example/changelog", "Context Awareness · changelog · Lumen", at(9, 10),
             text: "Context Awareness records what you do so agents can recall it. Context Awareness needs the Max plan."),
        page("https://x.com/someone/status/1", "dont know why this button doesn't work / X", at(9, 18),
             text: "Lumen Context Awareness button does nothing. The Context Awareness switch is gray."),
        page("https://github.com/lumen/issues/12", "Context Awareness switch stays off · Issue #12", at(9, 35)),
        page("https://dia.com/pricing", "Dia Pro · Plans and pricing", at(10, 20)),
        page("https://arc.net/max", "Arc Max pricing", at(10, 31)),
        page("https://reddit.com/r/browsers/1", "Is Dia worth $20? : r/browsers", at(10, 50)),
        page("https://docs.google.com/spreadsheets/d/1", "Pricing table - Google Sheets", at(11, 5)),
        page("https://united.com/sfo", "SFO · Nov 10 · United Airlines", at(12, 5)),
        page("https://google.com/travel/flights", "Google Flights · New York to San Francisco", at(12, 6)),
        page("https://united.com/sfo/ua1123", "UA 1123 · SFO · Nov 10 · United Airlines", at(12, 25)),
    ]

    // MARK: grouping

    @Test func aMorningIsThreeThreads() async throws {
        let (diary, folder) = Self.diary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await diary.plant(Self.morning)
        await diary.rethread(Self.at(9, 0))
        let threads = await Self.day(diary, Self.at(9, 0))
        #expect(threads.count == 3)
        #expect(threads.map(\.pages.count) == [3, 4, 3])
        #expect(threads[1].pages.map(\.host) == ["dia.com", "arc.net", "reddit.com", "docs.google.com"])
        #expect(threads.map(\.order) == [0, 1, 2])
        #expect(threads.allSatisfy { !$0.open })
        // Named by the page gone back to, before any model.
        #expect(threads[1].name == "Dia Pro")
        #expect(threads[1].when == "10:20 to 11:05 AM")
        #expect(threads[2].when == "12:05 to 12:25 PM")
    }

    @Test func aPauseStartsAnother() async throws {
        let (diary, folder) = Self.diary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await diary.plant([
            Self.page("https://news.ycombinator.com/show", "Show HN guidelines", Self.at(14, 0)),
            Self.page("https://docs.google.com/document/d/2", "Show HN draft - Google Docs", Self.at(14, 6)),
            // Half an hour on: the same site, but another thing.
            Self.page("https://news.ycombinator.com/item?id=9", "Ask HN: Who is hiring?", Self.at(14, 40)),
            Self.page("https://news.ycombinator.com/item?id=10", "Ask HN: Freelancer? Seeking freelancer?", Self.at(14, 44)),
        ])
        await diary.rethread(Self.at(14, 0))
        let threads = await Self.day(diary, Self.at(14, 0))
        #expect(threads.count == 2)
        #expect(threads.map(\.pages.count) == [2, 2])
    }

    @Test func aPageComeBackToJoinsItsThread() async throws {
        let (diary, folder) = Self.diary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await diary.plant([
            Self.page("https://dia.com/pricing", "Dia Pro · Plans and pricing", Self.at(10, 0)),
            Self.page("https://dia.com/features", "Dia features", Self.at(10, 4)),
            Self.page("https://united.com/sfo", "SFO · Nov 10 · United Airlines", Self.at(10, 10)),
            Self.page("https://google.com/travel/flights", "Google Flights", Self.at(10, 11)),
            Self.page("https://dia.com/pricing", "Dia Pro · Plans and pricing", Self.at(10, 20)),
        ])
        await diary.rethread(Self.at(10, 0))
        let threads = await Self.day(diary, Self.at(10, 0))
        #expect(threads.count == 2)
        #expect(threads[0].pages.first?.visits == 2)
        #expect(threads[0].end == Self.at(10, 20))
    }

    @Test func spacesAreKeptApart() async throws {
        let (diary, folder) = Self.diary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await diary.plant([
            Self.page("https://dia.com/pricing", "Dia Pro · Plans and pricing", Self.at(10, 0), space: "work"),
            Self.page("https://dia.com/features", "Dia features", Self.at(10, 2), space: "home"),
            Self.page("https://arc.net/max", "Arc Max pricing", Self.at(10, 4), space: "work"),
            Self.page("https://dia.com/download", "Download Dia", Self.at(10, 6), space: "home"),
        ])
        await diary.rethread(Self.at(10, 0))
        let threads = await Self.day(diary, Self.at(10, 0))
        #expect(threads.count == 2)
        #expect(Set(threads.map(\.space)) == ["work", "home"])
    }

    @Test func anAgentsVisitsAndLonePagesAreNoThread() async throws {
        let (diary, folder) = Self.diary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await diary.plant([
            Self.page("https://dia.com/pricing", "Dia Pro · Plans and pricing", Self.at(10, 0), quiet: true),
            Self.page("https://arc.net/max", "Arc Max pricing", Self.at(10, 3), quiet: true),
            Self.page("https://dia.com/features", "Dia pricing features", Self.at(10, 5), quiet: true),
            // Yours, but one page alone.
            Self.page("https://weather.com/today", "Weather today", Self.at(13, 0)),
        ])
        await diary.rethread(Self.at(10, 0))
        #expect(await Self.day(diary, Self.at(10, 0)).isEmpty)
    }

    @Test func groupingIsPureAndOrdered() {
        let visits = Self.morning.enumerated().map { index, planted in
            DayThreads.Visit(id: Int64(index), key: Diary.key(planted.url), at: planted.at, host: Diary.host(planted.url),
                             title: planted.title, space: planted.space,
                             words: DayThreads.words(title: planted.title, host: Diary.host(planted.url), text: planted.text))
        }
        let groups = DayThreads.group(visits.reversed())
        #expect(groups.count == 3)
        #expect(DayThreads.group(visits).map { $0.map { visits[$0].id } } == [[0, 1, 2], [3, 4, 5, 6], [7, 8, 9]])
    }

    // MARK: names, kept

    @Test func aNameStaysWithWhatItNamed() async throws {
        let (diary, folder) = Self.diary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await diary.plant(Self.morning)
        await diary.rethread(Self.at(9, 0))
        let pricing = try #require(await diary.threadID(holding: URL(string: "https://dia.com/pricing")!, on: Self.at(9, 0)))
        await diary.name(thread: pricing, DayThreads.Naming(topic: "Arc and Dia pricing", doing: "Comparing Arc and Dia pricing",
                                                            done: "Compared Arc and Dia pricing", line: "Dia Pro is $20 a month billed yearly."))
        // Another page of it later, and the day grouped again.
        await diary.plant([Self.page("https://dia.com/pricing/faq", "Dia pricing FAQ", Self.at(11, 20))])
        await diary.rethread(Self.at(9, 0))
        let thread = try #require(await diary.thread(pricing))
        #expect(thread.name == "Comparing Arc and Dia pricing")
        #expect(thread.done == "Compared Arc and Dia pricing")
        #expect(thread.topic == "Arc and Dia pricing")
        #expect(thread.pages.count == 5)
        // Renamed by you: no model's name goes over it.
        await withCheckedContinuation { done in diary.rename(thread: pricing, to: "Browser prices") { done.resume() } }
        await diary.name(thread: pricing, DayThreads.Naming(topic: "x", doing: "Doing x", done: "Did x", line: ""))
        #expect(await diary.thread(pricing)?.name == "Browser prices")
    }

    // MARK: forgetting

    @Test func aForgottenPageLeavesItsThread() async throws {
        let (diary, folder) = Self.diary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await diary.plant(Self.morning)
        await diary.rethread(Self.at(9, 0))
        let flights = try #require(await diary.threadID(holding: URL(string: "https://united.com/sfo")!, on: Self.at(9, 0)))
        await withCheckedContinuation { done in
            diary.forget(keys: [Diary.key(URL(string: "https://google.com/travel/flights")!)]) { done.resume() }
        }
        #expect(await diary.thread(flights)?.pages.map(\.host) == ["united.com", "united.com"])
        await withCheckedContinuation { done in
            diary.forget(keys: [Diary.key(URL(string: "https://united.com/sfo/ua1123")!)]) { done.resume() }
        }
        // One page left: no thread.
        #expect(await diary.thread(flights) == nil)
    }

    @Test func aForgottenThreadTakesItsPagesAndComesBack() async throws {
        let (diary, folder) = Self.diary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await diary.plant(Self.morning + [
            // The pricing page seen the day before too: it stays, with that visit.
            Self.page("https://dia.com/pricing", "Dia Pro · Plans and pricing", Self.at(16, 0, daysAgo: 4)),
        ])
        await diary.rethread(Self.at(9, 0))
        let pricing = try #require(await diary.threadID(holding: URL(string: "https://dia.com/pricing")!, on: Self.at(9, 0)))
        let (taken, urls) = await diary.take(thread: pricing)
        #expect(Set(urls) == ["https://arc.net/max", "https://reddit.com/r/browsers/1", "https://docs.google.com/spreadsheets/d/1"])
        #expect(await diary.thread(pricing) == nil)
        let listed: [String] = await withCheckedContinuation { done in
            diary.list(before: nil, limit: 100) { rows in done.resume(returning: rows.compactMap { $0["url"] as? String }) }
        }
        #expect(!listed.contains("https://arc.net/max"))
        #expect(listed.filter { $0 == "https://dia.com/pricing" }.count == 1)
        await withCheckedContinuation { done in diary.giveBack(taken) { done.resume() } }
        let back = try #require(await diary.thread(pricing))
        #expect(back.pages.count == 4)
        #expect(await Self.day(diary, Self.at(9, 0)).count == 3)
    }

    // MARK: what you did

    @Test func whatYouDidIsReadCopiedAndDownloaded() async throws {
        let (diary, folder) = Self.diary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await diary.plant(Self.morning)
        diary.act(.copied, on: URL(string: "https://dia.com/pricing")!, words: "$20 a month, billed yearly", at: Self.at(10, 25))
        diary.act(.downloaded, on: URL(string: "https://arc.net/max")!, words: "Arc.dmg", at: Self.at(10, 33))
        // A page never visited, a private tab's: nothing kept.
        diary.act(.copied, on: URL(string: "https://secret.invalid/x")!, words: "nope", at: Self.at(10, 34))
        await diary.rethread(Self.at(9, 0))
        let pricing = try #require(await diary.threadID(holding: URL(string: "https://dia.com/pricing")!, on: Self.at(9, 0)))
        let thread = try #require(await diary.thread(pricing))
        // Read once: the page stayed on longest, the last page aside.
        #expect(thread.did.map(\.words) == [
            "Copied \u{201C}$20 a month, billed yearly\u{201D}",
            "Read Arc Max pricing",
            "Downloaded Arc.dmg",
        ])
        #expect(thread.did[1].time == "10:31 AM")
    }

    // MARK: a seeded month

    /// Thirty days of four things a day, as a probe world seeds them.
    static func month() -> [Diary.Planted] {
        let subjects: [[(String, String)]] = [
            [("https://dia.com/pricing", "Dia Pro · Plans and pricing"), ("https://arc.net/max", "Arc Max pricing"),
             ("https://reddit.com/r/browsers/dia", "Is Dia pricing worth it")],
            [("https://united.com/sfo", "SFO flights · United"), ("https://google.com/travel/flights", "Google Flights SFO flights"),
             ("https://kayak.com/sfo", "Cheap SFO flights · KAYAK")],
            [("https://news.ycombinator.com/show", "Show HN guidelines"), ("https://docs.google.com/document/d/hn", "Show HN draft"),
             ("https://github.com/yab/readme", "Show HN readme draft")],
            [("https://nytimes.com/cooking/bread", "Sourdough bread recipe"), ("https://kingarthur.com/starter", "Sourdough starter guide"),
             ("https://seriouseats.com/sourdough", "Sourdough bread baking tips")],
        ]
        var out: [Diary.Planted] = []
        for back in 3...32 {
            for (index, pages) in subjects.enumerated() {
                for (step, one) in pages.enumerated() {
                    out.append(page(one.0 + "?d=\(back)", one.1, at(9 + index * 2, step * 7, daysAgo: back)))
                }
            }
        }
        return out
    }

    @Test func aSeededMonthIsGroupedOnceOffTheMainThread() async throws {
        let (diary, folder) = Self.diary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await diary.plant(Self.month())
        await withCheckedContinuation { done in diary.backfillThreads(days: 33) { done.resume() } }
        let from = Calendar.current.startOfDay(for: Self.at(0, 0, daysAgo: 32))
        let all = await diary.threads(from: from, to: Date())
        #expect(all.count == 30 * 4)
        #expect(all.allSatisfy { $0.pages.count == 3 })
        let cost = await diary.threadCost()
        #expect(cost.onMain == 0)
        #expect(cost.passes == 33)
        #expect(cost.visits == 30 * 12)
        // A day of a dozen visits: well under a frame each.
        #expect(cost.longest < 100)
        // Grouped already: a second backfill groups only today.
        await withCheckedContinuation { done in diary.backfillThreads(days: 33) { done.resume() } }
        #expect(await diary.threadCost().passes == cost.passes + 1)
    }

    // MARK: words

    @Test func timeWordsNameTheirStretch() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // Wednesday, October 21, 2026, 4:12 PM.
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 16, minute: 12))!
        let morning = try #require(DayThreads.span("what did Dia Pro cost, the one I looked at this morning", now: now, calendar: calendar))
        #expect(morning.label == "From your morning")
        #expect(morning.words == "this morning")
        #expect(calendar.component(.hour, from: morning.to) == 12)
        #expect(morning.rest == "what did dia pro cost the one i looked at")
        let friday = try #require(DayThreads.span("pick up where I left off on Friday", now: now, calendar: calendar))
        #expect(friday.label == "Friday")
        #expect(calendar.component(.day, from: friday.from) == 16)
        #expect(DayThreads.span("yesterday", now: now, calendar: calendar)?.label == "Yesterday")
        #expect(calendar.component(.day, from: DayThreads.span("last week", now: now, calendar: calendar)!.from) == 11)
        #expect(DayThreads.span("arc pricing", now: now, calendar: calendar) == nil)
        #expect(DayThreads.picksUp("Pick up where I left off on Friday"))
        #expect(!DayThreads.picksUp("what did Dia cost"))
    }

    @Test func aModelsLinesAreRead() {
        let said = DayThreads.naming("Topic: Arc and Dia pricing\nDoing: Comparing Arc and Dia pricing.\nDone: Compared Arc and Dia pricing\nLine: Dia Pro is $20 a month billed yearly, Arc Max $25")
        #expect(said == DayThreads.Naming(topic: "Arc and Dia pricing", doing: "Comparing Arc and Dia pricing",
                                          done: "Compared Arc and Dia pricing", line: "Dia Pro is $20 a month billed yearly, Arc Max $25."))
        #expect(DayThreads.naming("Sure! Here is a name.") == nil)
        #expect(DayThreads.naming("Doing: " + String(repeating: "word ", count: 20)) == nil)
    }

    /// The Mac's model shapes its answer from `ThreadNaming`'s guides and
    /// copied the example names it was told into threads about anything
    /// else (#1058): what every model is told names no example.
    @Test func theNamingInstructionsGiveNoNameToCopy() {
        for example in ["Arc and Dia pricing", "Comparing Arc and Dia pricing", "Compared Arc and Dia pricing"] {
            #expect(!DayThreads.instructions.contains(example))
        }
    }

    // MARK: the day's note

    @Test func theDaysNoteSaysWhatYouDidAndKeepsYourCorrection() throws {
        let lines = ["- 9:10 to 10:05 AM · Read about Lumen's Context Awareness (4 pages)",
                     "- 10:20 to 11:40 AM · Compared Arc and Dia pricing. Dia Pro is $20 a month billed yearly."]
        let fresh = try #require(DayNotes.written("", day: "2026-10-20", lines: lines, last: nil))
        #expect(fresh == "# 2026-10-20\n\n## What you did\n" + lines.joined(separator: "\n") + "\n")
        // A day tasks wrote in already: ahead of what they noticed.
        let tasks = "# 2026-10-20\n\n### 4:12 PM · Weekly update\n- Weekly update written from this week's days, not sent.\n"
        let both = try #require(DayNotes.written(tasks, day: "2026-10-20", lines: lines, last: nil))
        #expect(both.hasPrefix("# 2026-10-20\n\n## What you did\n- 9:10"))
        #expect(both.hasSuffix("### 4:12 PM · Weekly update\n- Weekly update written from this week's days, not sent.\n"))
        #expect(DayNotes.noticed(both) == ["Weekly update written from this week's days, not sent."])
        // A task's line kept after the section, as Memory.write appends it.
        #expect(DayNotes.noticed(fresh + "\n- Weekly update, not sent.\n") == ["Weekly update, not sent."])
        // A thread more: the section as written goes, the new one in its place.
        let more = lines + ["- 12:05 to 12:30 PM · Looked at SFO flights for November 10. Chose UA 1123, didn't book."]
        let again = try #require(DayNotes.written(both, day: "2026-10-20", lines: more, last: DayNotes.section(lines)))
        #expect(again.contains("Chose UA 1123"))
        #expect(again.components(separatedBy: "## What you did").count == 2)
        #expect(DayNotes.written(again, day: "2026-10-20", lines: more, last: DayNotes.section(more)) == nil)
        // Corrected by hand: left as you wrote it.
        let corrected = again.replacingOccurrences(of: "Chose UA 1123", with: "Chose UA 1130")
        #expect(DayNotes.written(corrected, day: "2026-10-20", lines: lines, last: DayNotes.section(more)) == nil)
        #expect(DayNotes.line(DayThread(id: 1, day: "2026-10-20", space: "", start: Self.at(9, 10), end: Self.at(10, 5), topic: "Lumen",
                                        name: "Reading about Lumen", done: "Read about Lumen", summary: "", named: 1, order: 0,
                                        pages: [], acts: [], open: false)) == "- 9:10 to 10:05 AM · Read about Lumen (0 pages)")
    }

    @Test func aNameFromTitlesDropsTheSite() {
        #expect(DayThreads.fallbackName([("Show HN draft - Google Docs", "docs.google.com"), ("Show HN guidelines", "news.ycombinator.com"),
                                         ("Show HN draft - Google Docs", "docs.google.com")]) == "Show HN draft")
        #expect(DayThreads.span(from: Self.at(10, 20), to: Self.at(11, 40), open: false) == "10:20 to 11:40 AM")
        #expect(DayThreads.span(from: Self.at(11, 40), to: Self.at(12, 30), open: false) == "11:40 AM to 12:30 PM")
        #expect(DayThreads.span(from: Self.at(14, 0), to: Self.at(15, 0), open: true) == "2:00 PM to now")
    }
}
