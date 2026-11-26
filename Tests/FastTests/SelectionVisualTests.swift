import AppKit
import SwiftUI
import Testing
@testable import Fast

struct SelectionVisualTests {
    @Test @MainActor func saveSelectionScreenshotsWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["YAB_SELECTION_SHOTS"] == "1" else { return }
        let tab = Fast.Tab(bench: true)
        defer { tab.close() }
        tab.page.navigate(html:"<textarea id=body style='width:560px;height:140px'>hey, sorry for late reply, i looked at the plan and think we should move the meeting</textarea>",
                               base: URL(string: "https://example.test/"))
        for _ in 0..<100 {
            if (try? await tab.page.run("document.getElementById('body') != null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await tab.page.run("""
        const e = document.getElementById('body'); e.focus(); e.setSelectionRange(0, e.value.length); true
        """)
        let commands = SelectionCommands()
        commands.commands = SelectionCommand.builtIn
        var read: SelectionSnapshot?
        commands.peek(on: tab) { read = $0 }
        for _ in 0..<100 where read == nil { try await Task.sleep(for: .milliseconds(25)) }
        guard var snap = read else { Issue.record("nothing selected"); return }
        // The layer is the result's, over the text: a command's own, run and
        // then put in each state. (⌘J's list is the field's Selection place.)
        commands.run(SelectionCommand(id: "same", name: "Same", prompt: "", executor: "local"), on: tab, snapshot: snap)
        for _ in 0..<100 where commands.stage != .failed { try await Task.sleep(for: .milliseconds(25)) }
        let folder = ProcessInfo.processInfo.environment["YAB_SELECTION_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/shots/2026-10-10/selection-ink")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        commands.noChange = false
        commands.error = ""
        // A rewrite in the text's place (SelectionInk), each state, light and dark.
        snap.rect = CGRect(x: 76, y: 190, width: 560, height: 36)
        snap.box = CGRect(x: 76, y: 190, width: 600, height: 36)
        snap.fontSize = 13.5
        snap.lineHeight = 18
        snap.fontFamily = "-apple-system"
        commands.snapshot = snap
        commands.command = SelectionCommand.builtIn[0]
        let done = "Hi, sorry for the late reply. I looked at the plan and think we should move the meeting to next week."
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .dark ? "dark" : "light"
            commands.showOriginal = false
            commands.output = ""
            commands.stage = .running
            try save(commands, tab, to: folder.appendingPathComponent("1-waiting-\(name).png"), scheme: scheme)
            commands.output = String(done.prefix(52))
            try save(commands, tab, to: folder.appendingPathComponent("2-running-\(name).png"), scheme: scheme)
            commands.output = done
            commands.stage = .preview
            try save(commands, tab, to: folder.appendingPathComponent("3-done-\(name).png"), scheme: scheme)
            commands.showOriginal = true
            try save(commands, tab, to: folder.appendingPathComponent("4-original-\(name).png"), scheme: scheme)
            commands.showOriginal = false
            commands.output = ""
            commands.error = "Too long for this Mac\u{2019}s model. Ask an agent instead?"
            commands.command?.executor = "mac"
            commands.stage = .failed
            try save(commands, tab, to: folder.appendingPathComponent("5-failed-\(name).png"), scheme: scheme)
            commands.error = ""
            commands.output = done
            commands.stage = .preview
            try save(commands, tab, to: folder.appendingPathComponent("6-narrow-\(name).png"), scheme: scheme, canvasWidth: 460)
        }
        // Near the window's foot: the bar above the selection.
        snap.rect.origin.y = 560
        commands.snapshot = snap
        try save(commands, tab, to: folder.appendingPathComponent("7-bottom-light.png"), scheme: .light)
        // An explanation stays on its card, no quote and no heading.
        snap.rect.origin.y = 190
        commands.snapshot = snap
        commands.command = SelectionCommand.builtIn.first { $0.id == "explain" }
        commands.output = "The writer apologizes for answering late and suggests moving the meeting after reading the plan."
        try save(commands, tab, to: folder.appendingPathComponent("8-card-light.png"), scheme: .light)
        try save(commands, tab, to: folder.appendingPathComponent("8-card-dark.png"), scheme: .dark)
        try saveSettings(commands, to: folder.appendingPathComponent("settings-light.png"), scheme: .light)
        try saveSettings(commands, to: folder.appendingPathComponent("settings-dark.png"), scheme: .dark)
    }

    @Test @MainActor func saveSelectionDockMarkdownScreenshotWhenRequested() throws {
        guard let dir = ProcessInfo.processInfo.environment["YAB_SELECTION_DOCK_SHOT_DIR"] else { return }
        let tab = Fast.Tab(bench: true)
        defer { tab.close() }
        let commands = SelectionCommands()
        let snap = SelectionSnapshot(asking: tab)
        let markdown = """
        Someone just spent **$665,000** buying stock options that gain value if the stock **$ANT** drops significantly over the next few years.

        Here is what each part means:

        * **$ANT:** The stock symbol (ticker) for a specific company.
        * **$10 puts:** A **put option** is a contract that gives the buyer the right to sell a stock at a locked-in price, in this case **$10 per share**, even if the stock falls much lower on the open market.
        * **At $0.70:** This is the cost of the contract per share. Because each standard option contract covers 100 shares, each contract costs **$70** ($0.70 x 100).
        """
        let explain = try #require(SelectionCommand.builtIn.first { $0.id == "explain" })
        commands.show(explain, on: tab, snapshot: snap, stage: .preview, output: markdown)
        let folder = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let canvas = ZStack(alignment: .bottom) {
            Color(nsColor: NSColor(white: 0.08, alpha: 1))
            PageFoot(availableWidth: 620, tab: tab, selection: commands)
        }
        .frame(width: 620, height: 340)
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: canvas)
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 340)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: folder.appendingPathComponent("selection-dock-markdown-dark.png"), options: .atomic)
    }

    @MainActor
    private func save(_ commands: SelectionCommands, _ tab: Fast.Tab, to url: URL,
                      scheme: ColorScheme, canvasWidth: CGFloat = 820) throws {
        if var snap = commands.snapshot {
            snap.dark = scheme == .dark
            snap.ground = scheme == .dark ? Color(nsColor: NSColor(white: 0.11, alpha: 1)) : .white
            snap.foreground = scheme == .dark ? .white : .black
            commands.snapshot = snap
        }
        let canvas = ZStack {
            (scheme == .dark ? Color(nsColor: NSColor(white: 0.11, alpha: 1)) : Color.white)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("To").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    Text("anna@studio.example")
                }
                .frame(height: 36)
                Divider()
                HStack {
                    Text("Subject").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    Text("Re: pricing doc")
                }
                .frame(height: 36)
                Divider()
                Text("Hi Anna,").padding(.top, 20)
                Text("hey, sorry for late reply, i looked at the plan and think we should move the meeting to next week maybe")
                    .frame(width: min(canvasWidth - 152, commands.snapshot?.rect.width ?? 610), alignment: .leading)
                    .padding(.top, 18)
                Text("Alex").padding(.top, 90)
                Spacer()
            }
            .font(.system(size: 13.5))
            .padding(.horizontal, 76)
            .padding(.top, 64)
            SelectionLayer(commands: commands, tab: tab)
        }
        .frame(width: canvasWidth, height: 620)
        .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: canvas)
        host.frame = NSRect(x: 0, y: 0, width: canvasWidth, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url, options: .atomic)
    }

    @MainActor
    private func saveSettings(_ commands: SelectionCommands, to url: URL, scheme: ColorScheme) throws {
        let canvas = Form {
            CommandSettingsPage(commands: commands)
        }
        .formStyle(.grouped)
        .frame(width: 900, height: 680)
        .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: canvas)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 680)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url, options: .atomic)
    }
}
