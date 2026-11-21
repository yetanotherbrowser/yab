import Foundation
import Testing
@testable import Fast

/// A window's looks (Sleep.swift, Stuck.swift) end with the window.
@MainActor @Suite(.serialized)
struct WindowClocksTests {
    private func session(_ window: UUID) -> URL { Store.file("session-window-\(window.uuidString).json") }

    @Test func aClosedWindowsClocksStop() {
        let window = UUID(), browser = Browser(windowID: window)
        defer { try? FileManager.default.removeItem(at: session(window)) }
        #expect(browser.dozing?.isValid == true && browser.stuck.timer?.isValid == true)
        #expect(browser.stuck.agentTimer?.isValid == true && browser.stuck.frontTimer?.isValid == true)
        let pressure = browser.pressure
        browser.letGo()
        #expect(browser.dozing?.isValid != true)
        #expect(browser.stuck.timer?.isValid != true && browser.stuck.agentTimer?.isValid != true && browser.stuck.frontTimer?.isValid != true)
        #expect(pressure?.isCancelled == true)
    }

    @Test func aClosedWindowIsLetGo() {
        let window = UUID()
        defer { try? FileManager.default.removeItem(at: session(window)) }
        weak var gone: Browser?
        do {
            let browser = Browser(windowID: window)
            gone = browser
            browser.letGo()
        }
        #expect(gone == nil)
    }

    @Test func aNewWindowKeepsThePicturesOfTabsAsleepInAnother() {
        let first = UUID(), second = UUID()
        defer {
            try? FileManager.default.removeItem(at: session(first))
            try? FileManager.default.removeItem(at: session(second))
        }
        let one = Browser(windowID: first)
        defer { one.letGo() }
        let picture = Tab.pictures.appendingPathComponent(UUID().uuidString + ".jpg")
        Tab.disk.sync {
            try? FileManager.default.createDirectory(at: Tab.pictures, withIntermediateDirectories: true)
            try? Data([1, 2, 3]).write(to: picture)
        }
        defer { try? FileManager.default.removeItem(at: picture) }
        let two = Browser(windowID: second)
        defer { two.letGo() }
        Tab.disk.sync {}
        #expect(FileManager.default.fileExists(atPath: picture.path))
    }

    @Test func aClosedWindowStopsLookingForMemory() {
        let window = UUID(), browser = Browser(windowID: window)
        defer { try? FileManager.default.removeItem(at: session(window)); Pressure.forced = nil }
        browser.letGo()
        // A relief already under way calls relieve() again after the window is gone.
        Pressure.forced = 2
        browser.relieve()
        #expect(browser.nextLook == nil)
    }
}
