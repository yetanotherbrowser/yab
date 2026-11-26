import AppKit
import SwiftUI
import Testing
@testable import Fast

/// #401: with the column put away its door comes over to the address band,
/// at the band's end on the column's side. For a column on the right it
/// stood at the band's start, the window's other side from where the column
/// comes out.
@MainActor
@Suite(.serialized)
struct AddressBarColumnDoorTests {
    @Test(arguments: [false, true])
    func theHiddenColumnsDoorStandsOnTheColumnsSide(right: Bool) async throws {
        _ = NSApplication.shared
        let screen = try #require(TestScreen.screen)
        let browser = Browser(windowID: UUID())
        let prefs = browser.prefs
        let old = (prefs.addressBar, prefs.sidebar, prefs.sideShut, prefs.sideFlank, prefs.sidebarButton)
        prefs.addressBar = true
        prefs.sidebar = true
        prefs.sideShut = true
        prefs.sideFlank = right ? .right : .left
        prefs.sidebarButton = true
        let tab = Tab()
        tab.restore(url: URL(string: "https://example.test/path")!, title: "Example")
        browser.prepare(tab)
        browser.lay([tab])
        browser.activeID = tab.id
        let width: CGFloat = 800
        let host = NSHostingView(rootView: AddressBar(browser: browser, tab: tab, peek: browser.peek,
                                                     strip: false, height: 36, corner: 0)
            .frame(width: width, height: 36))
        let window = NSWindow(contentRect: CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100,
                                                  width: width, height: 36),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.close()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            tab.close()
            prefs.addressBar = old.0
            prefs.sidebar = old.1
            prefs.sideShut = old.2
            prefs.sideFlank = old.3
            prefs.sidebarButton = old.4
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
        }
        Bench.spots["column door"] = nil
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let door = try #require(Bench.spots["column door"])
        // In the band's first or last tenth, and nowhere near the middle.
        if right {
            #expect(door.minX > width * 0.9)
        } else {
            #expect(door.maxX < width * 0.1)
        }
    }
}
