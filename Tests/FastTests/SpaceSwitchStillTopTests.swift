import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Fast

/// A change of space holds the top of the column still, as Arc's does: the
/// address and the pinned extensions stay where they are whatever the next
/// space has in front, a site, a blank tab or nothing, so only the space's
/// own part slides, and the pins every space shares stand still over it
/// (SpacePager.hold), lit as the space on screen lights them.
@MainActor
@Suite(.serialized)
struct SpaceSwitchStillTopTests {
    @MainActor private final class World {
        let id = UUID()
        let browser: Browser
        private var lists: [URL] = []
        private var made: [UUID] = []
        private let spaces: Any?
        private let sharing: Any?
        private let spacesList: Data?
        private let sharedList: Data?
        private let prefs: (addressBar: Bool, sidebar: Bool, sideShut: Bool, sideWidth: CGFloat)
        private var extensions: (installed: [Installed], asleep: Set<String>)?
        private static var spacesFile: URL { Store.file("spaces.json") }
        private static var sharedFile: URL { Store.file("session-\(Space.pinsID.uuidString).json") }

        init() {
            spaces = Store.settings.object(forKey: "spaces")
            sharing = Store.settings.object(forKey: SharedPins.key)
            spacesList = try? Data(contentsOf: World.spacesFile)
            sharedList = try? Data(contentsOf: World.sharedFile)
            Store.settings.set(false, forKey: SharedPins.key)
            Spaces.write([Space(id: Space.firstID, name: "Personal", icon: "🏠", ownSignIns: false)])
            browser = Browser(windowID: id)
            browser.prefs.usesSpaces = true
            let prefs = browser.prefs
            self.prefs = (prefs.addressBar, prefs.sidebar, prefs.sideShut, prefs.sideWidth)
            // The address in the column, not over the page.
            prefs.addressBar = false
            prefs.sidebar = true
            prefs.sideShut = false
        }

        /// Five extensions pinned in a list: for a space with sign-ins of
        /// its own, its saved list, never loaded; for those every space
        /// shares, the shared sign-in's, each asleep until used.
        static func pinned(_ count: Int) -> [Installed] {
            (0..<count).map { index in
                Installed(id: String(repeating: String(UnicodeScalar(UInt8(97 + index))), count: 32), name: "Pinned \(index)",
                          version: "1", enabled: true, fromStore: true, permissions: [], pinned: true)
            }
        }

        func space(_ name: String, own: Bool, pinned: Int = 5) throws -> Space {
            let space = Space(id: UUID(), name: name, icon: "🧪", ownSignIns: own)
            if own {
                let list = Extensions.list(of: space.id)
                try FileManager.default.createDirectory(at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(Self.pinned(pinned)).write(to: list)
                lists.append(list)
            }
            browser.spaces.append(space)
            Spaces.write(browser.spaces)
            made.append(space.id)
            return space
        }

        func share(_ count: Int) {
            let list = Self.pinned(count)
            let was = Extensions.shared.installedForTest(list, asleep: Set(list.map(\.id)))
            if extensions == nil { extensions = was }
            SharedPins.turn(true, in: [browser], spacesOn: true)
        }

        func site(_ address: String = "https://example.test/") -> Fast.Tab {
            let tab = Fast.Tab()
            tab.restore(url: URL(string: address)!, title: address)
            browser.prepare(tab)
            return tab
        }

        func close() {
            if let extensions { Extensions.shared.installedForTest(extensions.installed, asleep: extensions.asleep) }
            browser.prefs.addressBar = prefs.addressBar
            browser.prefs.sidebar = prefs.sidebar
            browser.prefs.sideShut = prefs.sideShut
            browser.prefs.sideWidth = prefs.sideWidth
            browser.letGo()
            lists.forEach { try? FileManager.default.removeItem(at: $0) }
            Store.settings.set(spaces, forKey: "spaces")
            Store.settings.set(sharing, forKey: SharedPins.key)
            if let spacesList { try? spacesList.write(to: World.spacesFile, options: .atomic) } else { try? FileManager.default.removeItem(at: World.spacesFile) }
            if let sharedList { try? sharedList.write(to: World.sharedFile) } else { try? FileManager.default.removeItem(at: World.sharedFile) }
            _ = Spaces.read()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            for space in made {
                Spaces.sharing.remove(space)
                Spaces.pageCounts[space] = nil
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString)-\(space.uuidString).json"))
            }
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
    }

    /// On main a blank tab, or none, dropped the row: every pin under it
    /// went up a row on a new tab, and on a change of space to or from one.
    @Test func theExtensionsRowStaysOnABlankTabOrNone() throws {
        let world = World()
        defer { world.close() }
        let space = try world.space("Here", own: true)
        let shown = SidePlate.extensionPlate(in: world.browser, space: space.id, tab: world.site())
        #expect(shown.extensionHeight > 0)
        let blank = Fast.Tab()
        #expect(blank.isBlank)
        #expect(SidePlate.extensionPlate(in: world.browser, space: space.id, tab: blank) == shown)
        #expect(SidePlate.extensionPlate(in: world.browser, space: space.id, tab: nil) == shown)
    }

    /// The user's case: spaces that share sign-ins and a real shared pin,
    /// a site in front here and nothing in the space beside it. On main the
    /// plates differed, so the row was pictured with the address and the
    /// pins in its pages and they slid with it.
    @Test func sharedPinsAndTheAddressStayOutOfTheRowToASpaceWithNoTab() throws {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let work = try world.space("Work", own: false)
        world.share(5)
        let pin = world.site("https://pin.example.test/"), site = world.site()
        browser.lay([pin, site])
        browser.pin(pin)
        browser.select(site)
        #expect(browser.showsShared(browser.spaceID) && browser.showsShared(work.id))
        let here = SidePlate.extensionPlate(in: browser, space: browser.spaceID, tab: browser.active, shown: browser.sidePlated)
        #expect(here.extensionHeight > 0)
        let order = browser.turnOrder.map(\.id)
        let to = try #require(order.firstIndex(of: work.id))
        #expect(SpacePager.movesPlate(browser, toward: to, load: true) == false)
        #expect(SpacePager.movesPlate(browser, toward: nil) == false)
    }

    /// One extension fits in a wide plate: shown there with the pointer in
    /// the column, on a site and with no tab in front alike (on main the
    /// empty plate drew none, and the button went as the space changed).
    /// Only the live plate's pins are popups' anchors: a page's picture of
    /// the same plate has none.
    @Test func anInlinePinShowsOnTheEmptyPlateAsOnASite() async throws {
        _ = NSApplication.shared
        let world = World()
        defer { world.close() }
        let browser = world.browser
        browser.prefs.sideWidth = 320
        world.share(1)
        let site = world.site()
        let id = try #require(Extensions.shared.buttons.first { $0.pinned }?.id)
        #expect(SidePlate.extensionPlate(in: browser, space: nil, tab: site) == SidePlate.extensionPlate(in: browser, space: nil, tab: nil))
        #expect(SidePlate.extensionPlate(in: browser, space: nil, tab: nil).extensionHeight == 0)
        /// The pin's popup anchors drawn in the plate.
        func anchors(_ plate: some View) async throws -> Int {
            let host = NSHostingView(rootView: plate.frame(width: 320 - 2 * SideBar.margin))
            let window = NSWindow(contentRect: CGRect(x: -8000, y: -8000, width: 320, height: 120),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            for _ in 0..<20 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            func count(_ view: NSView) -> Int {
                ((view as? AnchorView)?.id == id ? 1 : 0) + view.subviews.reduce(0) { $0 + count($1) }
            }
            return count(host)
        }
        #expect(try await anchors(SidePlate(browser: browser, tab: site, near: true, width: 320)) == 1)
        #expect(try await anchors(EmptyPlate(browser: browser, near: true)) == 1)
        #expect(try await anchors(EmptyPlate(browser: browser, space: browser.spaceID, near: true)) == 0)
    }

    /// The shared pins over the row while it slides: still where they stand,
    /// and from the switch on lit as the space on screen lights them (on
    /// main the space left's pin stayed lit until the row landed). Pins
    /// that aren't every space's go with their page. An empty space's page
    /// beside it lights New tab as it will rest.
    @Test func heldPinsStayPutAndTakeTheNewSpacesLight() throws {
        _ = NSApplication.shared
        let world = World()
        defer { world.close() }
        let browser = world.browser
        browser.prefs.sideWidth = 240
        let work = try world.space("Work", own: false)
        world.share(0)
        let pin = world.site("https://pin.example.test/"), site = world.site()
        browser.lay([pin, site])
        browser.pin(pin)
        browser.select(pin)

        let room = CGRect(x: 0, y: 0, width: 240, height: 500)
        let root = NSView(frame: room)
        let window = NSWindow(contentRect: room, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        let pages = ColumnPages(browser: browser)
        pages.frame = room
        root.addSubview(pages)
        defer { pages.stop() }
        pages.given(ColumnPages.Frame(lead: 44, footRoom: 0, top: 36, foot: false),
                    look: ColumnPages.Look(tone: nil, scheme: .light, titleSize: 13, grain: 0))
        pages.layoutSubtreeIfNeeded()
        pages.layout()
        let home = try #require(pages.shown)
        func cell(in view: NSView) -> ColumnCell? {
            if let cell = view as? ColumnCell, cell.current?.tab == ObjectIdentifier(pin) { return cell }
            return view.subviews.lazy.compactMap { cell(in: $0) }.first
        }
        let square = try #require(cell(in: home))
        let pagesLayer = try #require(pages.layer)
        // Where it is drawn across: its frame in the column, and every
        // transform over it, the row's and the held pins'.
        func drawn() -> CGFloat {
            var x = square.convert(square.bounds, to: pages).minX + pagesLayer.sublayerTransform.m41
            var view: NSView? = square
            while let each = view, each !== pages {
                x += each.layer?.transform.m41 ?? 0
                view = each.superview
                if let above = view, above !== pages { x += above.layer?.sublayerTransform.m41 ?? 0 }
            }
            return x
        }
        let rest = drawn()
        #expect(square.current?.live == true)

        let order = browser.turnOrder.map(\.id)
        let from = try #require(order.firstIndex(of: browser.spaceID)), to = try #require(order.firstIndex(of: work.id))
        #expect(pages.beginSlide(order: order, home: from))
        _ = pages.build(to, row: browser.loadRow(work.id), travelling: [])
        // Work, with no tab in front, comes in with New tab lit as it will
        // rest: on main it lit only once the row had landed.
        func newTab(in view: NSView) -> ColumnCell? {
            if let cell = view as? ColumnCell, cell.itemID == "new-tab" { return cell }
            return view.subviews.lazy.compactMap { newTab(in: $0) }.first
        }
        let coming = try #require(pages.subviews.compactMap { $0 as? ColumnPage }.first { $0 !== home })
        #expect(newTab(in: coming)?.current?.lit == true)
        pages.holdPins(true)
        pages.slideTo(-100)
        #expect(abs(drawn() - rest) < 0.5)

        browser.switchSpace(to: work.id)
        pages.sync()
        #expect(abs(drawn() - rest) < 0.5)
        // Work has no tab in front: its New tab is lit, not the pin.
        #expect(square.current?.live == false)

        pages.holdPins(false)
        #expect(abs(drawn() - (rest - 100)) < 0.5)
        pages.endSlide()
    }
}
