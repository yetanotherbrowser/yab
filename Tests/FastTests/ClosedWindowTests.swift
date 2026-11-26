import AppKit
import Testing
@testable import Fast

/// #1046: a window opened with ⌘N and closed is let go, its browser with
/// it, rather than staying in the window server, off screen, for as long
/// as Yab runs.
@MainActor @Suite(.serialized)
struct ClosedWindowTests {
    @Test func aClosedWindowIsLetGoWithItsBrowser() async throws {
        try #require(Store.testing && Store.unitTests && Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
        // Startup watches the process's first window until it is seen on
        // screen, which an off-screen test window never is; and work done
        // once per process holds on to the first browser window it meets,
        // which in the app is the first window, kept anyway. Measured on
        // the second.
        Startup.mark("window")
        for round in 0..<2 {
            weak var browser: Browser?
            weak var window: NSWindow?
            var id = UUID()
            do {
                let opened = BrowserWindows.shared.newWindow()
                browser = opened
                window = BrowserWindows.shared.window(for: opened)
                id = try #require(opened.windowID)
            }
            defer {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                try? FileManager.default.removeItem(at: Store.file("spaces-window-\(id.uuidString).json"))
            }
            try #require(window != nil)
            // Its body up and on screen, as a window is before a hand can close it.
            try await Task.sleep(for: .milliseconds(800))
            window?.close()
            for _ in 0..<30 where window != nil || browser != nil { try await Task.sleep(for: .milliseconds(100)) }
            if round == 1 {
                #expect(window == nil)
                #expect(browser == nil)
            }
        }
    }

    @Test func aClosedWindowDoesNotOverwriteItsSavedSession() async throws {
        try #require(Store.testing && Store.unitTests && Store.settings !== UserDefaults.standard)
        let id = UUID()
        let url = URL(string: "https://example.test/kept-on-close")!
        let browser = Browser(windowID: id)
        defer {
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            try? FileManager.default.removeItem(at: Store.file("spaces-window-\(id.uuidString).json"))
        }
        _ = browser.open(url, foreground: true)
        browser.flushSession()
        browser.rememberSession()
        // Keep a strong reference to `browser` past the 1.2s debounce, as a
        // finishing download task can, and verify `letGo()` does not let the
        // delayed session write overwrite the flushed tabs with an empty row.
        browser.letGo()
        try await Task.sleep(for: .milliseconds(1400))
        let saved = Session.read(space: browser.spaceID, window: id)
        #expect(saved.tabs.contains { $0.url == url.absoluteString })
        _ = browser
    }
}
