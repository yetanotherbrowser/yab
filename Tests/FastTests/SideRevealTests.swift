import AppKit
import Testing
@testable import Fast

/// Settings › Appearance › Hidden sidebar opens (#249): how long the pointer
/// rests at the window's edge before the put-away column comes out. Arc's
/// moment stays the default, and the edge that counts is the same for each.
struct SideRevealTests {
    static let height: CGFloat = 780
    static let edge = CGPoint(x: 3, y: 300)
    static let page = CGPoint(x: 300, y: 300)

    /// Brim's look at the pointer, as LightsEdgeTests has it, with a choice.
    private struct Pointer {
        let reveal: SideReveal
        var now: CFTimeInterval = 100
        var dwell = EdgeReach.Dwell()

        mutating func look(_ point: CGPoint) -> Bool {
            let edge = EdgeReach.at(point, past: false, height: SideRevealTests.height)
            return dwell.remaining(rest: EdgeReach.rest(edge: edge, reveal: reveal), now: now) == 0
        }

        mutating func wait(_ seconds: CFTimeInterval, at point: CGPoint) -> Bool {
            now += seconds
            return look(point)
        }
    }

    @Test func afterAMomentIsArcsAsBefore() {
        #expect(SideReveal.allCases == [.moment, .quick, .instant])
        #expect(SideReveal.moment.rest == EdgeReach.edgeRest)
        #expect(EdgeReach.rest(edge: true) == 0.3)
        var pointer = Pointer(reveal: .moment)
        let arrived = pointer.look(Self.edge)
        #expect(!arrived)
        let beforeDeadline = pointer.wait(0.29, at: Self.edge)
        #expect(!beforeDeadline)
        let rested = pointer.wait(0.02, at: Self.edge)
        #expect(rested)
    }

    @Test func quicklyWaitsTheTopStripsRest() {
        #expect(SideReveal.quick.rest == TopReach.edgeRest)
        var pointer = Pointer(reveal: .quick)
        let arrivedQuickly = pointer.look(Self.edge)
        #expect(!arrivedQuickly)
        let beforeQuickDeadline = pointer.wait(0.14, at: Self.edge)
        #expect(!beforeQuickDeadline)
        let restedQuickly = pointer.wait(0.02, at: Self.edge)
        #expect(restedQuickly)
    }

    @Test func instantlyOpensAtTheFirstLookAtTheEdge() {
        var pointer = Pointer(reveal: .instant)
        let onPage = pointer.look(Self.page)
        #expect(!onPage)
        let atEdge = pointer.look(Self.edge)
        #expect(atEdge)
    }

    /// The page's own controls just inside the window keep their hover,
    /// however short the wait.
    @Test func noChoiceWidensTheEdge() {
        for reveal in SideReveal.allCases {
            var pointer = Pointer(reveal: reveal)
            for x in [CGFloat(4), 8, 20, 60] {
                let point = CGPoint(x: x, y: 24)
                let overControl = pointer.look(point)
                #expect(!overControl, "\(reveal) at \(x)")
                let restedOverControl = pointer.wait(1, at: point)
                #expect(!restedOverControl, "\(reveal) at \(x)")
            }
            #expect(EdgeReach.rest(edge: false, reveal: reveal) == nil)
        }
    }

    @MainActor @Test func aMacThatNeverChoseWaitsArcsMoment() {
        let held = Store.settings.object(forKey: SideReveal.key)
        defer { Store.settings.set(held, forKey: SideReveal.key) }
        Store.settings.removeObject(forKey: SideReveal.key)
        #expect(Preferences().sideReveal == .moment)
        Store.settings.set("sometime", forKey: SideReveal.key)
        #expect(Preferences().sideReveal == .moment)
    }

    /// Each window has its own settings and watches its own edge: the
    /// choice made from one reaches the others, as Theme does.
    @MainActor @Test func everyOpenWindowTakesTheChoice() {
        _ = NSApplication.shared
        let held = Store.settings.object(forKey: SideReveal.key)
        let first = Browser(windowID: UUID()), second = Browser(windowID: UUID())
        let windows = [first, second].map { browser -> NSWindow in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            BrowserWindows.shared.register(window, for: browser)
            return window
        }
        defer {
            [first, second].forEach { BrowserWindows.shared.forgetForTests($0) }
            windows.forEach { $0.close() }
            first.letGo(); second.letGo()
            Store.settings.set(held, forKey: SideReveal.key)
        }
        first.prefs.sideReveal = .moment
        second.prefs.sideReveal = .moment
        first.prefs.sideReveal = .instant
        #expect(second.prefs.sideReveal == .instant)
        second.prefs.sideReveal = .quick
        #expect(first.prefs.sideReveal == .quick)
    }

    /// Yab's own agent can change it (NativeActions), and Settings' search
    /// finds the row.
    @MainActor @Test func theRowIsFoundAndYabsAgentCanChangeIt() throws {
        let held = Store.settings.object(forKey: SideReveal.key)
        defer { Store.settings.set(held, forKey: SideReveal.key) }
        let setting = try #require(NativeSetting.all.first { $0.id == "sidebar-reveal" })
        let prefs = Preferences()
        try setting.write(prefs, .string("instant"))
        #expect(prefs.sideReveal == .instant)
        #expect(Store.settings.string(forKey: SideReveal.key) == "instant")
        #expect(setting.saved == .string("instant"))
        #expect(throws: NativeFailure.self) { try setting.write(prefs, .string("slowly")) }
        #expect(SettingsItem.all.contains { $0.id == "sidebar-reveal" && $0.page == .appearance })
    }
}
