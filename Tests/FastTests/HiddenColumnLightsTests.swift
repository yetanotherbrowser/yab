import AppKit
import Testing
@testable import Fast

/// Actual ColumnView slide + native standard window buttons, kept in an
/// unshown offscreen window. No system menu, global input, or AX calls.
@MainActor @Suite(.serialized)
struct HiddenColumnLightsTests {
    private func world(_ check: (ColumnView, NSWindow, NSView) throws -> Void) throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let prefs = browser.prefs
        let old = (prefs.sidebar, prefs.sideShut)
        prefs.sidebar = true; prefs.sideShut = true
        browser.fullScreen = true
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 650))
        root.wantsLayer = true
        window.contentView = root
        let column = ColumnView(browser: browser)
        column.frame = root.bounds
        root.addSubview(column)
        defer {
            window.close()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            prefs.sidebar = old.0; prefs.sideShut = old.1
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
        }
        try check(column, window, root)
    }

    private func row(in parent: NSView, handle: Bool = false) throws -> (LightsRow, [NSButton]) {
        let row = LightsRow(frame: NSRect(x: 12, y: 12, width: Lights.run, height: Metrics.strip))
        parent.addSubview(row)
        row.handle = handle
        row.layoutSubtreeIfNeeded()
        let buttons = row.subviews.compactMap { $0 as? NSButton }
        try #require(buttons.count == 3 && buttons.allSatisfy { $0.window != nil }, "native lights fixture must attach")
        return (row, buttons)
    }

    @Test func layerDepartureRemovesTheNativeHitTargetAndReturnRestoresIt() throws {
        try world { column, window, root in
            column.slide(out: true, animated: false)
            let (row, buttons) = try row(in: column)
            let green = try #require(buttons.last)
            let point = green.convert(NSPoint(x: green.bounds.midX, y: green.bounds.midY), to: root)
            try #require(buttons.allSatisfy { !$0.isHidden })
            try #require(LightsRow.button(at: point, from: root, in: window) === green)
            column.slide(out: false, animated: true)
            #expect(!column.shown)
            #expect(buttons.allSatisfy { $0.isHidden }, "layer-hidden native cells must stop tracking at the old Back-button position")
            #expect(LightsRow.button(at: point, from: root, in: window) == nil)
            #expect(row.hitTest(row.convert(point, from: root)) == nil)
            // A key-window refresh must not resurrect the hidden cells.
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            #expect(buttons.allSatisfy { $0.isHidden })
            column.slide(out: true, animated: false)
            #expect(column.shown && buttons.allSatisfy { !$0.isHidden })
            #expect(LightsRow.button(at: point, from: root, in: window) === green)
        }
    }

    @Test func aHandleRowMovesTheWindowByItsAirAndGoesWithTheColumn() throws {
        try world { column, window, root in
            column.slide(out: true, animated: false)
            let (row, buttons) = try row(in: column, handle: true)
            let green = try #require(buttons.last)
            let host = try #require(row.superview)
            let light = host.convert(green.convert(NSPoint(x: green.bounds.midX, y: green.bounds.midY), to: nil), from: nil)
            let air = host.convert(row.convert(NSPoint(x: row.bounds.midX, y: 3), to: nil), from: nil)
            let onLight = try #require(row.hitTest(light))
            #expect(onLight === green || onLight.isDescendant(of: green))
            #expect(row.hitTest(air) is WindowHandle)
            column.slide(out: false, animated: true)
            #expect(row.hitTest(air) == nil, "the strip must not stay in the column's old place")
            #expect(row.hitTest(light) == nil)
            column.slide(out: true, animated: false)
            #expect(row.hitTest(air) is WindowHandle)
        }
    }

    @Test func attachingUnderAnAlreadyHiddenColumnStaysHiddenButTheBandDoesNot() throws {
        try world { column, window, root in
            column.slide(out: false, animated: false)
            let (_, hidden) = try row(in: column)
            #expect(hidden.allSatisfy { $0.isHidden })
            let (band, visible) = try row(in: root)
            band.setFrameOrigin(NSPoint(x: 200, y: 12))
            #expect(visible.allSatisfy { !$0.isHidden })
            let green = try #require(visible.last)
            let point = green.convert(NSPoint(x: green.bounds.midX, y: green.bounds.midY), to: root)
            #expect(LightsRow.button(at: point, from: root, in: window) === green)
            column.slide(out: false, animated: false)
            #expect(hidden.allSatisfy { $0.isHidden } && visible.allSatisfy { !$0.isHidden })
        }
    }
}
