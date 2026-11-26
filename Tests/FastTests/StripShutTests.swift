import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Fast

/// Feedback #48: with the tabs across the top, ⌘S puts the strip away the
/// way it puts the column away with the tabs down the side, the page taking
/// its room; the window's top edge brings it out over the page; and the
/// strip stays put away from one launch to the next.
@Suite(.serialized)
struct StripShutTests {
    /// The settings these tests change, put back as they were found.
    private static let keys = ["sidebar", "sidebar.shut", "strip.shut"]

    @MainActor private func keeping(_ body: () async throws -> Void) async rethrows {
        let old = Self.keys.map { Store.settings.object(forKey: $0) }
        defer { for (key, value) in zip(Self.keys, old) { Store.settings.set(value, forKey: key) } }
        try await body()
    }

    @MainActor private func withBrowser(_ body: (Browser) async throws -> Void) async rethrows {
        let window = UUID(), browser = Browser(windowID: window)
        let tab = Tab()
        tab.restore(url: URL(string: "https://strip-shut.test/")!, title: "Strip")
        browser.prepare(tab)
        browser.lay([tab])
        browser.activeID = tab.id
        defer {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
        }
        try await body(browser)
    }

    /// Until `done`, or two seconds: ⌘S waits a frame before it moves
    /// anything, and lets the page go a frame after the strip has landed.
    @MainActor private func settle(_ done: () -> Bool) async throws {
        for _ in 0..<80 where !done() {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @MainActor @Test func theStripPutAwayIsKeptForTheNextLaunch() async {
        await keeping {
            let prefs = Preferences()
            prefs.stripShut = true
            #expect(Store.settings.bool(forKey: "strip.shut"))
            #expect(Preferences().stripShut)
            prefs.stripShut = false
            #expect(!Preferences().stripShut)
            // Its own key: the column put away is another thing.
            prefs.sideShut = false
            prefs.stripShut = true
            #expect(!Preferences().sideShut)
        }
    }

    /// The menu item, and App Shortcuts' keys given to any of its names,
    /// are ⌘S's.
    @MainActor @Test func theMenuItemSaysWhatItPutsAway() {
        #expect(Browser.menuTitle(sidebar: true, away: false) == "Hide Sidebar")
        #expect(Browser.menuTitle(sidebar: true, away: true) == "Show Sidebar")
        #expect(Browser.menuTitle(sidebar: false, away: false) == "Hide Tab Bar")
        #expect(Browser.menuTitle(sidebar: false, away: true) == "Show Tab Bar")
        for title in ["Hide Sidebar", "Show Sidebar", "Hide Tab Bar", "Show Tab Bar"] {
            #expect(Hotkeys.action(forTitle: title) == .column)
        }
        let keys = Hotkeys.normalizedUserKeys(["Show Tab Bar": "@k"], visibleTitles: [.column: "Show Tab Bar"])
        #expect(keys["Hide Sidebar"] == "@k")
    }

    /// The band over the page: the strip's row in its place, nothing once
    /// it is put away, and the column's way unchanged.
    @MainActor @Test func thePageTakesTheStripsRoom() {
        #expect(ContentView.bandHeight(sidebar: false, stripAway: false) == Metrics.row)
        #expect(ContentView.bandHeight(sidebar: false, stripAway: true) == 0)
        #expect(ContentView.bandHeight(sidebar: true, stripAway: false) == 0)
        // The band with the lights beside a column on the right takes no
        // room: the page is carried down a row from the top, whole.
        #expect(ContentView.headSink(out: false, laid: true, shelf: 0) == 0)
        #expect(ContentView.headSink(out: true, laid: false, shelf: 0) == Metrics.row)
        #expect(ContentView.headSink(out: true, laid: true, shelf: 0) == Metrics.row - Backdrop.inset)
        #expect(ContentView.headSink(out: true, laid: true, shelf: BookmarkBar.height) == Metrics.row)
        // The page's top moves the strip's height edge to edge; on a
        // backdrop it keeps the card's inset from the window's top, and
        // under the bookmarks it moves the whole row.
        #expect(ContentView.stripStep(carded: false, full: false, chat: false, shelf: false) == Metrics.row)
        #expect(ContentView.stripStep(carded: true, full: false, chat: false, shelf: false) == Metrics.row - Backdrop.inset)
        #expect(ContentView.stripStep(carded: true, full: false, chat: false, shelf: true) == Metrics.row)
        // In full screen the page with the strip away is edge to edge, its
        // top at the screen's: the whole row both ways, the strip coming
        // back too, though the page is a card again once it has. With the
        // chat's column out it stays a card, in by the inset.
        #expect(ContentView.stripStep(carded: true, full: true, chat: false, shelf: false) == Metrics.row)
        #expect(ContentView.stripStep(carded: true, full: true, chat: true, shelf: false) == Metrics.row - Backdrop.inset)
    }

    @MainActor @Test func reduceMotionMovesNothingAndDiasCurveMovesTheRest() {
        #expect(Browser.stripPace(reduce: true) == nil)
        // Dia's curve both ways, read off a film of Dia (Motion.stripCurve),
        // the page carried by Core Animation on the very curve SwiftUI
        // slides the strip on.
        #expect(Browser.stripPace(reduce: false) == .strip)
        let pace = Reshape.Pace.strip
        #expect(abs(pace.duration - Motion.stripTime * Reshape.slow) < 0.0001)
        var first = [Float](repeating: 0, count: 2), second = first
        first.withUnsafeMutableBufferPointer { pace.timing.getControlPoint(at: 1, values: $0.baseAddress!) }
        second.withUnsafeMutableBufferPointer { pace.timing.getControlPoint(at: 2, values: $0.baseAddress!) }
        #expect(first + second == [Motion.stripCurve.0, Motion.stripCurve.1, Motion.stripCurve.2, Motion.stripCurve.3])
        #expect(abs(pace.curve.value(at: 0.5) - 0.82) < 0.05)
    }

    /// WebKit's paint callback runs inside a larger CA transaction. A
    /// nested group must not release the next viewport before that outer
    /// transaction commits, nor wait for the sidebar animation to finish.
    @MainActor @Test func aViewportWaitsForTheOuterCommit() async throws {
        var committed = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.begin()
        StageView.afterNextCommit { committed = true }
        CATransaction.commit()
        #expect(!committed)
        CATransaction.commit()
        CATransaction.flush()
        try await settle { committed }
        #expect(committed)
    }

    /// ⌘S goes to whatever holds the tabs: the strip across the top, the
    /// column down the side, each leaving the other's state alone.
    @MainActor @Test func commandSPutsAwayWhateverHoldsTheTabs() async throws {
        try await keeping {
            try await withBrowser { browser in
                browser.prefs.sidebar = false
                browser.putStrip(away: false)
                let sideShut = browser.prefs.sideShut
                #expect(browser.columnTitle == "Hide Tab Bar")
                #expect(Command.hideStrip.available(in: browser))
                #expect(!Command.showStrip.available(in: browser))
                #expect(!Command.hideSidebar.available(in: browser))

                browser.toggleColumn()
                try await settle { browser.prefs.stripShut && !browser.stripMoving }
                #expect(browser.prefs.stripShut)
                #expect(browser.stripAway && browser.tabsAway)
                #expect(!browser.stripPeek && !browser.stripCard)
                #expect(browser.prefs.sideShut == sideShut)
                #expect(Store.settings.bool(forKey: "strip.shut"))
                #expect(browser.columnTitle == "Show Tab Bar")
                #expect(Command.showStrip.available(in: browser))
                #expect(!Command.hideStrip.available(in: browser))

                browser.toggleColumn()
                try await settle { !browser.prefs.stripShut && !browser.stripMoving }
                #expect(!browser.prefs.stripShut)
                #expect(!browser.stripAway)

                // Down the side, the column, and the strip as it was.
                browser.prefs.sidebar = true
                browser.prefs.sideShut = false
                #expect(!Command.hideStrip.available(in: browser))
                browser.toggleColumn()
                try await settle { browser.prefs.sideShut && !browser.folding }
                #expect(browser.prefs.sideShut)
                #expect(!browser.prefs.stripShut)
                #expect(!browser.stripAway)
                browser.toggleColumn()
                try await settle { !browser.prefs.sideShut && !browser.folding }
            }
        }
    }

    /// Register 2551: in full screen with the column put away a page alone
    /// has the screen edge to edge, but the two halves of a pair stay cards
    /// on the space's color, round and between them, as in a window.
    @MainActor @Test func aPairStaysCardsInFullScreen() async throws {
        try await keeping {
            try await withBrowser { browser in
                browser.prefs.sidebar = true
                browser.prefs.sideShut = true
                browser.fullScreen = true
                #expect(browser.tabsAway)
                #expect(browser.pageSquare)
                let other = Tab()
                other.restore(url: URL(string: "https://strip-shut.test/other")!, title: "Other")
                browser.prepare(other)
                browser.lay(browser.tabs + [other])
                browser.stagePair = Pair(first: browser.activeID!, second: other.id)
                #expect(browser.pageShared)
                #expect(!browser.pageSquare)
                browser.stagePair = nil
                browser.fullScreen = false
            }
        }
    }

    /// Two quick presses are two changes, the second undoing the first,
    /// pressed before the first has moved anything or while it moves.
    @MainActor @Test func twoQuickPressesUndoEachOther() async throws {
        try await keeping {
            try await withBrowser { browser in
                browser.prefs.sidebar = false
                browser.putStrip(away: false)
                browser.toggleStrip()
                browser.toggleStrip()
                try await settle { !browser.stripMoving }
                #expect(!browser.prefs.stripShut)
                browser.toggleStrip()
                try await settle { browser.stripMoving && browser.prefs.stripShut }
                browser.toggleStrip()
                try await settle { !browser.prefs.stripShut && !browser.stripMoving }
                #expect(!browser.prefs.stripShut && browser.stripDown == 1)
            }
        }
    }

    /// Before the first queued change, and part-way through a slide, a
    /// second sidebar command reverses the requested state. An old queued
    /// change or completion must not overwrite the last request.
    @MainActor @Test(arguments: [0, 8, 80])
    func sidebarCommandsKeepTheLastRequestedState(delay: Int) async throws {
        try await keeping {
            try await withBrowser { browser in
                browser.prefs.sidebar = true
                for startHidden in [false, true] {
                    browser.prefs.sideShut = startHidden
                    browser.toggleColumn()
                    if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                    browser.toggleColumn()
                    try await settle { !browser.folding }
                    #expect(browser.prefs.sideShut == startHidden)
                    // Wait past either obsolete callback, too.
                    try await Task.sleep(for: .milliseconds(300))
                    #expect(browser.prefs.sideShut == startHidden)
                    #expect(!browser.folding)
                }
            }
        }
    }

    @MainActor @Test func floatingSidebarPinsDirectlyAsDiaDoes() async throws {
        try await keeping {
            try await withBrowser { browser in
                browser.prefs.sidebar = true
                browser.prefs.sideShut = true
                browser.sidePeek = true
                browser.sideCard = true
                browser.toggleColumn()
                #expect(!browser.prefs.sideShut)
                #expect(!browser.sidePeek && !browser.sideCard)
                #expect(!browser.folding)
                try await Task.sleep(for: .milliseconds(350))
                #expect(!browser.prefs.sideShut && !browser.folding)
            }
        }
    }

    @MainActor @Test func aPreparedFloatingCardOnlyPublishesItsVisibility() async throws {
        try await keeping {
            try await withBrowser { browser in
                browser.prefs.sidebar = true
                browser.prefs.sideShut = true
                browser.sideCard = true
                var paints = 0
                let watching = browser.peek.objectWillChange.sink { _ in paints += 1 }
                Brim.bring(browser, out: true)
                #expect(browser.sidePeek && browser.sideCard)
                #expect(paints == 1)
                Brim.bring(browser, out: true)
                #expect(paints == 1)
                Brim.bring(browser, out: false)
                #expect(!browser.sidePeek && browser.sideCard)
                #expect(paints == 2)
                _ = watching
            }
        }
    }

    /// The edge bringing the strip out over the page, and letting it go,
    /// changes the strip's own state, which the window's view doesn't
    /// watch: one change of the strip's peek, the look and the place
    /// together, and none of the browser's, which drew the whole window
    /// again, twice, before the strip could move.
    @MainActor @Test func theEdgeDrawsTheStripNotTheWindow() async throws {
        try await keeping {
            try await withBrowser { browser in
                browser.prefs.sidebar = false
                browser.putStrip(away: true)
                var window = 0, strip = 0
                let watching = [
                    browser.relay.any.sink { _ in window += 1 },
                    browser.topPeek.objectWillChange.sink { _ in strip += 1 },
                ]
                Brim.bringStrip(browser, out: true)
                #expect(browser.stripPeek && browser.stripCard)
                #expect(window == 0)
                #expect(strip == 2)
                Brim.bringStrip(browser, out: true)
                #expect(strip == 2)
                Brim.bringStrip(browser, out: false)
                #expect(!browser.stripPeek)
                // Lifted still, past the edge, for the next time.
                #expect(browser.stripCard)
                #expect(window == 0)
                _ = watching
                // Nothing to bring with the strip in its place.
                browser.putStrip(away: false)
                Brim.bringStrip(browser, out: true)
                #expect(!browser.stripPeek)
            }
        }
    }

    /// A rest at the top edge cut short by another window taking the
    /// pointer counts for nothing once the pointer is back: the strip waits
    /// a whole rest from there (#786, review of #932).
    @MainActor @Test func aRestCutShortByAnotherWindowStartsOverAtTheEdge() async throws {
        try await keeping {
            try await withBrowser { browser in
                browser.prefs.sidebar = false
                browser.putStrip(away: true)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                      styleMask: [.borderless], backing: .buffered, defer: true)
                Brim.keep(window, for: browser)
                defer { Brim.benchPointer = nil; Brim.benchFront = false }
                let rest = Int(TopReach.edgeRest * 1000)
                Brim.benchPointer = NSPoint(x: window.frame.midX, y: window.frame.maxY - 1)
                Brim.benchFront = true
                Brim.benchLook(in: window)
                try await Task.sleep(for: .milliseconds(rest / 3))
                // Not in front and on no screen: nothing of it is watched.
                Brim.benchFront = false
                Brim.benchLook(in: window)
                try await Task.sleep(for: .milliseconds(rest + 100))
                Brim.benchFront = true
                Brim.benchLook(in: window)
                #expect(!browser.stripPeek)
                try await Task.sleep(for: .milliseconds(rest + 100))
                Brim.benchLook(in: window)
                #expect(browser.stripPeek)
            }
        }
    }

    /// Out over the page, the strip stays where it is when ⌘S brings it
    /// back: it lands, lifted no more.
    @MainActor @Test func commandSOverThePageLandsTheStrip() async throws {
        try await keeping {
            try await withBrowser { browser in
                browser.prefs.sidebar = false
                browser.putStrip(away: true)
                browser.stripCard = true
                browser.stripPeek = true
                browser.toggleStrip()
                try await settle { !browser.prefs.stripShut && !browser.stripMoving }
                #expect(!browser.prefs.stripShut)
                #expect(!browser.stripPeek)
                #expect(!browser.stripCard)
            }
        }
    }

    /// Brought back by ⌘S from past the edge, the strip comes down flat,
    /// as it is in its place, whatever lift the edge last gave it.
    @MainActor @Test func commandSFromPastTheEdgeBringsItFlat() async throws {
        try await keeping {
            try await withBrowser { browser in
                browser.prefs.sidebar = false
                browser.putStrip(away: true)
                // Out over the page and gone again: lifted still.
                browser.stripCard = true
                browser.toggleStrip()
                #expect(!browser.stripCard)
                // Drawn where it stood, past the edge, until it moves; under
                // Reduce Motion it is simply back.
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { #expect(browser.stripDown == 0) }
                try await settle { !browser.prefs.stripShut && !browser.stripMoving }
                #expect(!browser.prefs.stripShut && browser.stripDown == 1)
            }
        }
    }

    /// ⇧⌘S from a strip put away leaves it put away on its way out, so it
    /// never drops into its place as the column comes in.
    @MainActor @Test func turningToTheSideLeavesTheStripAway() async throws {
        try await keeping {
            try await withBrowser { browser in
                browser.prefs.sidebar = false
                browser.putStrip(away: true)
                browser.toggleSidebar()
                try await settle { browser.prefs.sidebar }
                #expect(browser.prefs.sidebar)
                #expect(browser.prefs.stripShut)
                #expect(!browser.stripAway)
                try await settle { !browser.turning }
            }
        }
    }

    /// Asked for the tabs across the top, ⇧⌘S brings the strip, not one
    /// put away: a strip left away in an earlier session would otherwise
    /// leave the window with no tabs in sight at all.
    @MainActor @Test func turningToTheTopBringsTheStripInItsPlace() async throws {
        try await keeping {
            try await withBrowser { browser in
                browser.prefs.sidebar = true
                browser.prefs.stripShut = true
                browser.toggleSidebar()
                #expect(!browser.prefs.stripShut)
                try await settle { !browser.prefs.sidebar }
                #expect(!browser.prefs.sidebar)
                #expect(!browser.stripAway)
                try await settle { !browser.turning }
            }
        }
    }

    /// Where the pointer brings the strip out and keeps it, from the
    /// window's top left: the left edge's rules, Dia's, turned to the top.
    @Test func theTopEdgeBringsTheStripAsTheLeftEdgeBringsTheColumn() {
        let width: CGFloat = 1180
        // The very edge, anywhere along it, as the left edge's 4 points;
        // not a little further in, nor in the menu bar over the window,
        // where a hand goes for a menu.
        #expect(TopReach.at(CGPoint(x: 600, y: 0), width: width))
        #expect(TopReach.at(CGPoint(x: 600, y: Metrics.edgeWall), width: width))
        #expect(!TopReach.at(CGPoint(x: 600, y: 6), width: width))
        #expect(!TopReach.at(CGPoint(x: 600, y: -10), width: width))
        #expect(!TopReach.at(CGPoint(x: width + 20, y: 1), width: width))
        // The lights' corner, the column's own, only with nothing of Yab's
        // there: the address bar's Back, the first bookmarks.
        #expect(TopReach.corner(CGPoint(x: 40, y: 30), clear: true))
        #expect(!TopReach.corner(CGPoint(x: 40, y: 30), clear: false))
        #expect(!TopReach.corner(CGPoint(x: Metrics.lightsCorner.width + 10, y: 30), clear: true))
        #expect(!TopReach.corner(CGPoint(x: 40, y: Metrics.lightsCorner.height + 10), clear: true))
        // The top edge keeps its own rest, and the left corner's.
        #expect(TopReach.rest(edge: true, corner: false, hand: false, quiet: false) == TopReach.edgeRest)
        #expect(TopReach.rest(edge: false, corner: true, hand: false, quiet: false) == EdgeReach.cornerRest)
        #expect(TopReach.rest(edge: true, corner: true, hand: false, quiet: false) == TopReach.edgeRest)
        #expect(TopReach.rest(edge: false, corner: false, hand: false, quiet: false) == nil)
        // Bug #58 at the edge too, not only in the corner: edge to edge the
        // top is the page's own, its header's links, so quiet over what the
        // page takes a click on and just after a press near the top.
        #expect(TopReach.rest(edge: true, corner: false, hand: true, quiet: false) == nil)
        #expect(TopReach.rest(edge: true, corner: false, hand: false, quiet: true) == nil)
        #expect(TopReach.rest(edge: false, corner: true, hand: true, quiet: false) == nil)
        #expect(TopReach.rest(edge: false, corner: true, hand: false, quiet: true) == nil)
        #expect(TopReach.near(CGPoint(x: 600, y: 20), width: width))
        #expect(!TopReach.near(CGPoint(x: 600, y: Metrics.lightsCorner.height + 10), width: width))
        // Kept on it, a little under its foot, and up above on the way to
        // the menu bar; let go well down the page, or far off.
        #expect(TopReach.keeps(CGPoint(x: 600, y: 20), width: width))
        #expect(TopReach.keeps(CGPoint(x: 600, y: Metrics.row + 6), width: width))
        #expect(TopReach.keeps(CGPoint(x: 600, y: -100), width: width))
        #expect(!TopReach.keeps(CGPoint(x: 600, y: 120), width: width))
        #expect(!TopReach.keeps(CGPoint(x: 600, y: -400), width: width))
        #expect(!TopReach.keeps(CGPoint(x: width + 100, y: 20), width: width))
    }

    /// The edge's strip comes and goes on the card's curves, Dia's, as the
    /// column does from the left edge (CardMotion), not ⌘S's.
    @Test func theEdgeMovesOnTheCardsCurves() {
        #expect(CardMotion.arrive == .spring(response: CardMotion.response * Reshape.slow, dampingFraction: Double(CardMotion.damping)))
        var points = [Float](repeating: 0, count: 2), more = points
        points.withUnsafeMutableBufferPointer { CardMotion.leavingCurve.getControlPoint(at: 1, values: $0.baseAddress!) }
        more.withUnsafeMutableBufferPointer { CardMotion.leavingCurve.getControlPoint(at: 2, values: $0.baseAddress!) }
        #expect(points + more == [CardMotion.leavingPoints.0, CardMotion.leavingPoints.1, CardMotion.leavingPoints.2, CardMotion.leavingPoints.3])
    }
}
