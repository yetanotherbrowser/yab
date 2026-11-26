import AppKit
import Testing
import WebKit
@testable import Fast

/// A game in an extension's popup that moves on its own keydown and never
/// calls preventDefault (Stacker): WebKit sends each arrow back up the
/// responder chain unused, where it beeped, as it did in a tab before
/// PageView kept those quiet.
@MainActor
@Suite(.serialized)
struct ExtensionPopupKeysTests {
    private static func until(_ seconds: Double = 15, _ check: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await check() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await check()
    }

    @Test func arrowsAPopupGameTakesWithoutPreventDefaultDoNotBeep() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-popup-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"manifest_version":3,"name":"Keys test","version":"1.0","action":{"default_popup":"popup.html"}}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        // Its own file: an extension's page runs no inline script.
        try """
            <!doctype html><style>html, body { width: 200px; height: 120px; margin: 0; overflow: hidden }</style>
            <script src="popup.js"></script>
            """.write(to: folder.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)
        try #"globalThis.moves = []; document.addEventListener("keydown", e => moves.push(e.key))"#
            .write(to: folder.appendingPathComponent("popup.js"), atomically: true, encoding: .utf8)

        let controller = TestExtensions.controller()
        controller.delegate = Extensions.shared
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.baseURL = try #require(URL(string: "\(Extensions.scheme)://keys\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))/"))
        try controller.load(context)
        defer { try? controller.unload(context) }

        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = NSView(frame: NSRect(x: 180, y: 260, width: 30, height: 30))
        window.contentView?.addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { ExtensionPopup.shared.close(); window.orderOut(nil) }

        ExtensionPopup.shared.show(context.baseURL.appendingPathComponent("popup.html"), for: context, from: anchor)
        let up = try await Self.until {
            guard let web = ExtensionPopup.shared.view, web.window?.firstResponder === web else { return false }
            return (try? await web.evaluateJavaScript("Array.isArray(globalThis.moves)")) as? Bool == true
        }
        try #require(up)
        let web = try #require(ExtensionPopup.shared.view)
        let popupWindow = try #require(web.window)

        Beeps.watch()
        let before = Beeps.count
        for name in ["left", "right", "down", "up"] {
            let key = try #require(Beeps.key(name))
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try #require(NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: key.flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popupWindow.windowNumber, context: nil,
                    characters: key.chars, charactersIgnoringModifiers: key.chars, isARepeat: false, keyCode: key.code))
                // As NSApp hands a key to the popup's window: a key equivalent
                // first, which is where WebKit takes the arrows.
                if !popupWindow.performKeyEquivalent(with: event) { popupWindow.sendEvent(event) }
            }
        }
        let moved = try await Self.until {
            (try? await web.evaluateJavaScript("moves.join(' ')")) as? String == "ArrowLeft ArrowRight ArrowDown ArrowUp"
        }
        #expect(moved)
        // WebKit's unused keys come back after the page has had them.
        try await Task.sleep(for: .milliseconds(500))
        #expect(Beeps.count - before == 0)
    }
}
