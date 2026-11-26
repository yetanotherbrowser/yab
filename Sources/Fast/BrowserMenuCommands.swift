import AppKit
import SwiftUI

/// The menu bar exposes the same actions as the field and the tab row.
/// Numbered items use Keymap too, including the keys changed in Settings.
struct NumberedMenuButton: View {
    let title: String
    let action: Shortcut.Action?
    let perform: () -> Void

    @ViewBuilder var body: some View {
        if let action {
            Button(title, action: perform).shortcut(action)
        } else {
            Button(title, action: perform)
        }
    }
}

struct AppearanceMenu: View {
    @ObservedObject var browser: Browser

    var body: some View {
        // Settings › Appearance's Theme, in its words.
        Menu("Theme") {
            Picker("Theme", selection: Binding(
                get: { browser.prefs.look }, set: { browser.prefs.look = $0 }
            )) {
                Text("System").tag(Look.system)
                Text("Light").tag(Look.light)
                Text("Dark").tag(Look.dark)
            }
            .pickerStyle(.inline)
            Divider()
            // Dark pages (DarkPages.swift): checked while the page is
            // dark. Its ⌥⇧D is the key monitor's, never the menu's: as a
            // key equivalent it would take Î from every text field.
            DarkPageMenu(browser: browser)
        }
    }
}

struct BookmarksBarMenu: View {
    @ObservedObject var browser: Browser

    /// One switch, as Settings' Bookmarks bar and the menu's other bars.
    var body: some View {
        Toggle("Show Bookmarks Bar", isOn: Binding(
            get: { browser.prefs.bookmarkBar == .always }, set: { _ in browser.toggleBookmarkBar() }
        ))
        .shortcut(.bookmarksBar)
    }
}

struct NumberedTabsMenu: View {
    @ObservedObject var browser: Browser

    var body: some View {
        Menu("Go to Tab") {
            ForEach(1...9, id: \.self) { number in
                NumberedMenuButton(title: number == 9 ? "Last Tab" : "Tab \(number)",
                                   action: Shortcut.numbered("tab", number)) {
                    browser.select(index: number == 9 ? browser.tabs.count - 1 : number - 1)
                }
                .disabled(number == 9 ? available == 0 : number > available)
            }
        }
    }

    private var available: Int { browser.tabs.filter { !Agents.shared.sealed($0) }.count }
}

struct SplitMenuCommands: View {
    @ObservedObject var browser: Browser

    var body: some View {
        Button(browser.pair(of: browser.activeID) != nil ? "Separate Split View" : "Split View") {
            if browser.pair(of: browser.activeID) != nil { browser.separate() } else { browser.splitView() }
        }
        .shortcut(.split)
        // Of three or four, the next pane, round to the first.
        Button("Focus Other Half") {
            if let active = browser.active, let other = browser.partner(of: active) {
                browser.focus(other)
                if let web = other.builtPage { BrowserWindows.shared.window(for: browser)?.makeFirstResponder(web) }
            }
        }
        .disabled(!browser.splitShown)
        Button("Swap Halves") {
            if let pair = browser.stagePair { browser.swapHalves(pair) }
        }
        .disabled(!browser.splitShown || browser.stagePair?.count != 2)
    }
}

struct DeveloperMenuCommands: View {
    @ObservedObject var browser: Browser

    var body: some View {
        Menu("Developer") {
            Toggle("Developer Mode", isOn: Binding(get: { browser.menuDev }, set: { on in
                if let tab = browser.active { browser.setDevMode(tab, on) }
            }))
                .shortcut(.devMode)
                .disabled(!browser.canToggleDevMode)
            Divider()
            Button("Developer Tools") { browser.developerTools() }
                .shortcut(.inspector)
                .disabled(browser.menuBlank)
            Button("JavaScript Console") { browser.showConsole() }
                .shortcut(.console)
                .disabled(browser.menuBlank)
            Button("Inspect Element") { browser.inspectElement() }
                .shortcut(.inspectElement)
                .disabled(browser.menuBlank)
            Divider()
            Button("Errors and Network") { browser.toggleDevSheet() }
                .shortcut(.devSheet)
                .disabled(browser.menuBlank)
            Button("Measure") { browser.toggleMeasure() }
                .shortcut(.measure)
                .disabled(!browser.menuDev)
        }
    }
}

struct SpacesMenuCommands: Commands {
    @ObservedObject var browser: Browser

    var body: some Commands {
        CommandMenu("Spaces") {
            if browser.spacesShown {
                ForEach(Array(browser.turnOrder.enumerated()), id: \.element.id) { entry in
                    SpaceMenuButton(browser: browser, space: entry.element, number: entry.offset + 1)
                        // A Blank Window stays in its space, as Arc's.
                        .disabled(browser.blank)
                }
                Divider()
                Button("Next Space") { browser.stepSpace(1) }
                    .shortcut(.nextSpace)
                    .disabled(browser.turnOrder.count < 2 || browser.blank)
                Button("Previous Space") { browser.stepSpace(-1) }
                    .shortcut(.previousSpace)
                    .disabled(browser.turnOrder.count < 2 || browser.blank)
                Divider()
                Menu(browser.several ? "Move Tabs to Space" : "Move Tab to Space") {
                    ForEach(Array(browser.turnOrder.enumerated()), id: \.element.id) { entry in
                        NumberedMenuButton(title: entry.element.name,
                                           action: Shortcut.numbered("sendSpace", entry.offset + 1)) {
                            browser.moveTabs(browser.chosen, to: entry.element.id)
                        }
                        // From a Blank Window, its own space too: out of the window into it.
                        .disabled((entry.element.id == browser.spaceID && !browser.blank) || entry.element.id == Space.mailID || !canMove)
                    }
                }
                .disabled(!canMove)
                Divider()
                Button("New Space…") { SpaceTray.open(browser) }
            }
            Button("Manage Spaces…") { SettingsWindow.shared.show(.spaces, for: browser) }
        }
    }

    private var canMove: Bool {
        browser.chosen.contains { browser.sendable($0) && $0.everywhere == nil }
    }
}

private struct SpaceMenuButton: View {
    @ObservedObject var browser: Browser
    let space: Space
    let number: Int

    @ViewBuilder var body: some View {
        if let action = Shortcut.numbered("space", number) {
            toggle.shortcut(action)
        } else {
            toggle
        }
    }

    private var toggle: some View {
        Toggle(space.name, isOn: Binding(
            get: { browser.spaceID == space.id },
            set: { if $0 { browser.switchSpace(to: space.id) } }
        ))
    }
}

extension Browser {
    /// The same bounded, typed diagnostics attached to Send Feedback.
    /// No page contents, addresses or arbitrary logs enter the clipboard.
    func copyMenuDiagnostics() {
        Task { @MainActor [weak self] in
            let stalls = await Task.detached(priority: .utility) { Watchdog.recent() ?? "" }.value
            guard let text = FeedbackDiagnostics.shared.snapshots(stallLog: stalls).first else {
                self?.announce("Couldn’t collect diagnostics", mark: "exclamationmark.triangle")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.announce("Diagnostics copied", mark: "doc.on.doc")
        }
    }
}
