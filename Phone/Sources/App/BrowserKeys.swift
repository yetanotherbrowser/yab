import UIKit
import os

let keysLog = Logger(subsystem: "dev.serafim.fast.iphone", category: "keys")

/// The browser's keys with a hardware keyboard (row 1029): tabs, the field,
/// going back and forward, Find. They live in the main menu, so holding ⌘ on
/// an iPad lists them, and ⌘W is the tab's: the system's Close Window, which
/// closes a single-window app outright, is taken out of the menu.
enum BrowserKey: Hashable, Sendable {
    case newTab, newPrivateTab, openLocation, closeTab, reopenTab
    case reload, back, forward, find
    case nextTab, previousTab, toggleSidebar, settings
    /// The Mac's ⇧⌘S: tabs in the sidebar or across the top; Safari's ⇧⌘\ for All Tabs.
    case toggleTabsInSidebar, allTabs
    /// The Mac's View and File keys for the page.
    case zoomIn, zoomOut, actualSize, stop, reader, copyLink, print
    /// ⌘1 to ⌘8 the tab at that place, ⌘9 the last one.
    case tab(Int)

    static let all: [BrowserKey] = [.newTab, .newPrivateTab, .openLocation, .closeTab, .reopenTab,
                                    .reload, .back, .forward, .find, .nextTab, .previousTab, .toggleSidebar, .settings,
                                    .toggleTabsInSidebar, .allTabs,
                                    .zoomIn, .zoomOut, .actualSize, .stop, .reader, .copyLink, .print]
        + (1...9).map { .tab($0) }

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .newPrivateTab: "New Private Tab"
        case .settings: "Settings…"
        case .toggleTabsInSidebar: "Show Tabs in Sidebar"
        case .allTabs: "Show All Tabs"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .actualSize: "Actual Size"
        case .stop: "Stop Loading"
        case .reader: "Show Reader"
        case .copyLink: "Copy Link"
        case .print: "Print…"
        case .openLocation: "Open Location"
        case .closeTab: "Close Tab"
        case .reopenTab: "Reopen Closed Tab"
        case .reload: "Reload Page"
        case .back: "Back"
        case .forward: "Forward"
        case .find: "Find on Page"
        case .nextTab: "Show Next Tab"
        case .previousTab: "Show Previous Tab"
        case .toggleSidebar: "Show or Hide Sidebar"
        case .tab(9): "Last Tab"
        case let .tab(n): "Tab \(n)"
        }
    }

    var input: String {
        switch self {
        case .newTab, .reopenTab: "t"
        case .openLocation: "l"
        case .newPrivateTab: "n"
        case .settings: ","
        case .toggleTabsInSidebar: "s"
        case .allTabs: "\\"
        // ⌘= is ⌘+ on the keyboard, as Safari's Zoom In.
        case .zoomIn: "="
        case .zoomOut: "-"
        case .actualSize: "0"
        case .stop: "."
        case .reader: "r"
        case .copyLink: "c"
        case .print: "p"
        case .closeTab: "w"
        case .reload: "r"
        case .back: "["
        case .forward: "]"
        case .find: "f"
        case .toggleSidebar: "s"
        case .nextTab, .previousTab: "\t"
        case let .tab(n): String(n)
        }
    }

    var modifiers: UIKeyModifierFlags {
        switch self {
        case .reopenTab, .newPrivateTab, .toggleTabsInSidebar, .allTabs, .reader, .copyLink: [.command, .shift]
        case .nextTab: .control
        case .previousTab: [.control, .shift]
        default: .command
        }
    }

    /// What the menu command carries back to the responder that runs it.
    var token: String {
        switch self {
        case let .tab(n): "tab.\(n)"
        default: "\(self)"
        }
    }

    init?(token: Any?) {
        guard let token = token as? String, let key = Self.all.first(where: { $0.token == token }) else { return nil }
        self = key
    }

    @MainActor
    var command: UIKeyCommand {
        let command = UIKeyCommand(title: title, action: #selector(RootController.browserKey(_:)),
                                   input: input, modifierFlags: modifiers, propertyList: token)
        // Ahead of what a page or the system would make of the same keys.
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    // MARK: - the menu

    static let filesMenu = UIMenu.Identifier("dev.serafim.fast.iphone.keys.tabs")
    static let findMenu = UIMenu.Identifier("dev.serafim.fast.iphone.keys.find")
    static let viewMenu = UIMenu.Identifier("dev.serafim.fast.iphone.keys.view")
    static let historyMenu = UIMenu.Identifier("dev.serafim.fast.iphone.keys.history")
    static let tabsMenu = UIMenu.Identifier("dev.serafim.fast.iphone.keys.switch")
    static let settingsMenu = UIMenu.Identifier("dev.serafim.fast.iphone.keys.settings")
    static let pageMenu = UIMenu.Identifier("dev.serafim.fast.iphone.keys.page")
    static let printMenu = UIMenu.Identifier("dev.serafim.fast.iphone.keys.print")
    static let copyMenu = UIMenu.Identifier("dev.serafim.fast.iphone.keys.copy")

    /// File holds the tabs, View Reload, History Back and Forward, Window
    /// the tab switching, Edit Find on Page: where Safari keeps them.
    @MainActor
    static func build(_ builder: UIMenuBuilder) {
        guard builder.system == .main else { return }
        let closing = builder.menu(for: .close)?.children.map(\.title) ?? []
        keysLog.info("menu: file \(builder.menu(for: .file) != nil) view \(builder.menu(for: .view) != nil) window \(builder.menu(for: .window) != nil) close \(closing, privacy: .public)")
        func inline(_ id: UIMenu.Identifier, _ keys: [BrowserKey]) -> UIMenu {
            UIMenu(title: "", identifier: id, options: .displayInline, children: keys.map(\.command))
        }
        // Close Window (⌘W) and New Window go: one window, and ⌘W is a tab's.
        builder.remove(menu: .close)
        builder.remove(menu: .newItem)
        // The system's Find would reach only a focused web view, not the tab in front.
        builder.remove(menu: .find)

        // Settings where the Mac keeps it, in the app's own menu under About.
        let settings = inline(settingsMenu, [.settings])
        if builder.menu(for: .preferences) != nil { builder.replace(menu: .preferences, with: settings) }
        else if builder.menu(for: .about) != nil { builder.insertSibling(settings, afterMenu: .about) }
        else if builder.menu(for: .application) != nil { builder.insertChild(settings, atStartOfMenu: .application) }

        let tabs = inline(filesMenu, [.newTab, .newPrivateTab, .openLocation, .closeTab, .reopenTab])
        if builder.menu(for: .file) != nil { builder.insertChild(tabs, atStartOfMenu: .file) }
        else { builder.insertSibling(UIMenu(title: "File", children: [tabs]), afterMenu: .application) }

        let printing = inline(printMenu, [.print])
        if builder.menu(for: .file) != nil { builder.insertChild(printing, atEndOfMenu: .file) }

        let find = inline(findMenu, [.find])
        if builder.menu(for: .edit) != nil {
            builder.insertChild(inline(copyMenu, [.copyLink]), atEndOfMenu: .edit)
            builder.insertChild(find, atEndOfMenu: .edit)
        }
        else { builder.insertSibling(UIMenu(title: "Edit", children: [find]), afterMenu: .file) }

        let reload = inline(viewMenu, [.reload, .stop, .toggleSidebar, .toggleTabsInSidebar, .allTabs])
        if builder.menu(for: .view) != nil {
            builder.insertChild(reload, atStartOfMenu: .view)
            builder.insertChild(inline(pageMenu, [.reader, .zoomIn, .zoomOut, .actualSize]), atEndOfMenu: .view)
        }

        var history: [BrowserKey] = [.back, .forward]
        if builder.menu(for: .view) == nil { history.insert(contentsOf: [.reload, .toggleSidebar, .toggleTabsInSidebar, .allTabs], at: 0) }
        let historyTop = UIMenu(title: "History", identifier: historyMenu, children: history.map(\.command))
        let after: UIMenu.Identifier = builder.menu(for: .view) != nil ? .view : .edit
        builder.insertSibling(historyTop, afterMenu: after)

        let switching = inline(tabsMenu, [.nextTab, .previousTab] + (1...9).map { .tab($0) })
        if builder.menu(for: .window) != nil { builder.insertChild(switching, atStartOfMenu: .window) }
        else { builder.insertSibling(UIMenu(title: "Window", children: [switching]), afterMenu: historyMenu) }
    }
}

extension AppModel {
    /// Whether a key does anything now. Nothing reaches the tabs from under
    /// a lock, Settings, Join or a chat; with the field up only ⌘W, which
    /// puts it away.
    func mayUse(_ key: BrowserKey) -> Bool {
        if privateContentBlocked || privateLock.presentsPrompt { return false }
        // Always ours, Settings up or not: a ⌘, we turn down goes to the
        // system's own Settings item, which leaves Yab for the Settings app.
        if key == .settings { return true }
        if surfaces.settings || surfaces.join || surfaces.chat != nil { return false }
        if surfaces.coversChrome { return key == .closeTab && surfaces.field != nil }
        return offers(key)
    }

    /// Whether the key has something to do for the browser as it is, with
    /// nothing over it: the field asks this of the commands it offers.
    func offers(_ key: BrowserKey) -> Bool {
        let tab = browser.tab
        switch key {
        case .newTab, .newPrivateTab, .settings: return true
        case .toggleSidebar, .toggleTabsInSidebar: return workspace.tabletControls
        case .allTabs, .zoomIn, .zoomOut, .actualSize, .copyLink: return tab != nil
        case .print: return pageCanBeDrawn
        case .stop: return tab != nil && currentPageState.isLoading
        case .reader: return tab != nil && (currentPageState.readerAvailable || currentPageState.readerEnabled)
        case .openLocation, .reload, .find: return tab != nil
        case .closeTab: return tab != nil
        case .reopenTab: return backStack.closed != nil
        case .back: return backStack.route(for: tab) != .nowhere
        case .forward: return tab != nil && currentPageState.canGoForward
        case .nextTab, .previousTab: return tab != nil && browser.pagingOrder.count > 1
        case let .tab(n): return browser.pagingOrder.count >= (n == 9 ? 1 : n)
        }
    }

    func use(_ key: BrowserKey) {
        guard mayUse(key) else { return }
        switch key {
        case .newTab: openNewTab()
        case .newPrivateTab: openNewTab(privately: true)
        case .settings:
            // Taken but idle while something covers the browser (mayUse).
            guard !surfaces.settings, !surfaces.join, surfaces.chat == nil, !surfaces.coversChrome else { return }
            openSettingsFromSpaces(at: nil)
        case .toggleSidebar: workspace.sidebarShown.toggle()
        case .toggleTabsInSidebar: workspace.preferences.tabsInSidebar.toggle()
        case .allTabs: TabStack.of(self).openGallery()
        case .zoomIn: pageMenuZoom(1)
        case .zoomOut: pageMenuZoom(-1)
        case .actualSize: pageMenuZoom(0)
        case .stop: if let id = browser.tab?.id { pages.stop(id) }
        case .reader: pageMenuReader()
        case .copyLink: if let tab = browser.tab { copyLink(of: tab) }
        case .print: printPage()
        case .openLocation: Motion.fieldOpen.run { surfaces.openField(.address) }
        case .closeTab:
            if surfaces.field != nil { field.close(); return }
            closeTabFromKeyboard()
        case .reopenTab:
            if let closed = backStack.closed { backStack.undo(closed.id) }
        case .reload:
            if let id = browser.tab?.id { _ = pages.reload(id) }
        case .back: goBack()
        case .forward: pageMenuForward()
        case .find: findOnPage()
        case .nextTab: browser.page(by: 1)
        case .previousTab: browser.page(by: -1)
        case let .tab(n):
            let order = browser.pagingOrder
            let tab: Tab? = n == 9 ? order.last : order[n - 1]
            if let tab { browser.select(tab.id) }
        }
    }

    /// The menu's Close Page, kept for ⇧⌘T as a close in the column is.
    private func closeTabFromKeyboard() {
        guard let id = browser.tab?.id else { return }
        let closed = backStack.remember(id)
        Haptics.play(.light, reason: Haptics.Reason.closed)
        closeWorkspacePage()
        guard browser.tab(id) == nil else { return }
        if let closed { backStack.offer(closed) }
    }
}

extension BrowserKey {
    /// Kept out of the field: a tab by place, the field itself, Find (the
    /// field's own On This Page row) and Settings (its own row).
    var commandable: Bool {
        switch self {
        case .tab, .nextTab, .previousTab, .openLocation, .find, .settings: false
        default: true
        }
    }

    /// Other words the field knows a command by.
    var aliases: [String] {
        switch self {
        case .newPrivateTab: ["private", "incognito"]
        case .reopenTab: ["reopen", "undo close"]
        case .reload: ["refresh"]
        case .zoomIn: ["bigger", "larger"]
        case .zoomOut: ["smaller"]
        case .actualSize: ["reset zoom", "100%"]
        case .reader: ["reader", "reading mode"]
        case .copyLink: ["copy address", "copy url"]
        case .toggleSidebar: ["sidebar", "hide sidebar"]
        case .toggleTabsInSidebar: ["tab bar", "vertical tabs"]
        case .allTabs: ["tabs", "tab overview"]
        default: []
        }
    }

    /// The keys as the menu writes them: ⇧⌘R.
    var shortcut: String {
        var marks = ""
        if modifiers.contains(.control) { marks += "⌃" }
        if modifiers.contains(.alternate) { marks += "⌥" }
        if modifiers.contains(.shift) { marks += "⇧" }
        if modifiers.contains(.command) { marks += "⌘" }
        let key = switch input { case "\t": "⇥"; case "=": "+"; default: input.uppercased() }
        return marks + key
    }
}
