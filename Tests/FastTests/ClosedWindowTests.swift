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
}
