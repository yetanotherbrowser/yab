import AppKit
import Testing
@testable import Fast

// The tray's Sign-ins step offers what Settings' New Space does: the
// shared sign-ins, another space's of its own, or its own.
@MainActor @Suite(.serialized)
struct SpaceTraySignInsTests {
    private func world(_ spaces: [Space], _ body: (Browser) throws -> Void) throws {
        _ = NSApplication.shared
        let saved = Spaces.read()
        let browser = Browser(windowID: UUID())
        let old = browser.prefs.usesSpaces
        browser.prefs.usesSpaces = true
        browser.spaces = spaces
        browser.spaceID = spaces[0].id
        defer {
            browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.prefs.usesSpaces = old
            Spaces.write(saved)
        }
        try body(browser)
    }

    private let personal = Space(id: UUID(), name: "Personal", icon: "", ownSignIns: false)
    private let home = Space(id: UUID(), name: "Home", icon: "", ownSignIns: false)
    private let work = Space(id: UUID(), name: "Work", icon: "", ownSignIns: true)
    private let solo = Space(id: UUID(), name: "Solo", icon: "", ownSignIns: true)

    @Test func withOnlySharedSignInsTheStepIsAsItWas() throws {
        try world([personal, home]) { browser in
            #expect(browser.signInPeers.isEmpty)
        }
    }

    @Test func oneChoiceForEachSetOfSignInsOfTheirOwn() throws {
        var notes = Space(id: UUID(), name: "Work notes", icon: "", ownSignIns: true)
        notes.signInWith = work.id
        try world([personal, work, notes, solo]) { browser in
            #expect(browser.signInPeers.map(\.id) == [work.id, solo.id])
        }
    }

    @Test func aSpaceMadeSameAsWorkSharesWorksSignIns() throws {
        try world([personal, work]) { browser in
            let draft = SpaceDraft(prefs: browser.prefs, tab: nil)
            draft.name = "Projects"
            draft.peer = work.id
            SpaceTray.make(draft, in: browser, taking: [], washed: false)
            let made = try #require(browser.spaces.first { $0.name == "Projects" })
            #expect(made.ownSignIns)
            #expect(made.profileID == work.id)
            #expect(browser.spaceID == made.id)
            // Shared, as before: the shared sign-ins.
            let shared = SpaceDraft(prefs: browser.prefs, tab: nil)
            shared.name = "Errands"
            SpaceTray.make(shared, in: browser, taking: [], washed: false)
            let errands = try #require(browser.spaces.first { $0.name == "Errands" })
            #expect(!errands.ownSignIns)
            #expect(errands.profileID == Space.firstID)
        }
    }

    @Test func aTabTakenOntoItsOwnSignInsGoesAsItIs() throws {
        try world([personal, work]) { browser in
            browser.switchSpace(to: work.id)
            let tab = Tab()
            tab.restore(url: URL(string: "https://work.test/draft")!, title: "Draft")
            browser.prepare(tab)
            browser.lay([tab])
            browser.activeID = tab.id
            let draft = SpaceDraft(prefs: browser.prefs, tab: tab)
            draft.name = "Projects"
            draft.taking = true
            draft.peer = work.id
            SpaceTray.make(draft, in: browser, taking: [tab], washed: false)
            let made = try #require(browser.spaces.first { $0.name == "Projects" })
            #expect(made.profileID == work.id)
            #expect(browser.spaceID == made.id)
            // The same tab, live, not closed and opened again from disk.
            #expect(browser.tabs.contains { $0 === tab })
            #expect(browser.activeID == tab.id)
        }
    }

    @Test func manySignInsScrollInsideTheWindowAndOneIsAsItWas() {
        let today = 48 + 36 + 10 + 2 * 60 + 8 + CardFrame.inset + SpaceTray.foot
        #expect(SpaceTray.signInsHeight(peers: 0, ceiling: 10_000) == today)
        #expect(SpaceTray.signInsHeight(peers: 1, ceiling: 10_000) == today + 68)
        // Eight in a window with room for 590: no taller than that.
        #expect(SpaceTray.signInsHeight(peers: 8, ceiling: 590) == 590)
    }
}
