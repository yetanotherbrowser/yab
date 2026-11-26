import Foundation

/// What the field runs by name (Words.commandRows): a key of the menu, or a
/// menu action that has no key, as the Mac's field finds both.
enum FieldCommand: Hashable, Sendable {
    case key(BrowserKey)
    case savePDF, duplicateTab, splitView, download, showDownloads

    static let all: [FieldCommand] = BrowserKey.all.filter(\.commandable).map { .key($0) }
        + [.savePDF, .duplicateTab, .splitView, .download, .showDownloads]

    /// What a row carries: spelled out, so renaming a case changes no row.
    var token: String {
        switch self {
        case let .key(key): key.token
        case .savePDF: "savePDF"
        case .duplicateTab: "duplicateTab"
        case .splitView: "splitView"
        case .download: "download"
        case .showDownloads: "showDownloads"
        }
    }

    init?(token: String) {
        guard let command = Self.all.first(where: { $0.token == token }) else { return nil }
        self = command
    }

    var title: String {
        switch self {
        case let .key(key): key.title
        case .savePDF: "Save as PDF"
        case .duplicateTab: "Duplicate Tab"
        case .splitView: "Split View"
        case .download: "Download"
        case .showDownloads: "Show Downloads"
        }
    }

    var aliases: [String] {
        switch self {
        case let .key(key): key.aliases
        case .savePDF: ["pdf", "export pdf"]
        case .duplicateTab: ["copy tab", "clone tab"]
        case .splitView: ["open in split view", "side by side"]
        case .download: ["save file", "download file"]
        case .showDownloads: ["downloads", "downloaded files"]
        }
    }

    var shortcut: String {
        if case let .key(key) = self { return key.shortcut }
        return ""
    }

    var candidate: CommandCandidate {
        CommandCandidate(token: token, title: title, aliases: aliases, shortcut: shortcut)
    }
}

extension AppModel {
    /// The menu actions the field offers now (Words.commandRows).
    var commandCandidates: [CommandCandidate] {
        let isPrivate = field.place.isPrivate
        return FieldCommand.all.filter { offers($0) && (!isPrivate || runsInPrivate($0)) }.map(\.candidate)
    }

    func offers(_ command: FieldCommand) -> Bool {
        let tab = browser.tab
        switch command {
        case let .key(key): return offers(key)
        case .savePDF: return pageCanBeDrawn
        case .duplicateTab: return tab.map { !$0.isMail && $0.navigationURL != nil } ?? false
        case .splitView: return workspace.canSplit && tab.map { !$0.isMail } == true && !pageIsPrivate
        case .download: return pageDownloadable
        case .showDownloads: return downloadsInReach
        }
    }

    /// A downloads list to open: on iPad a downloads button on screen (the
    /// sidebar's foot, or the toolbar's while it has something to show); on
    /// iPhone the plate's Downloads page, which needs a page. The sidebar is
    /// the one the window lays out: a narrow one hides it while its switch
    /// stays on.
    var downloadsInReach: Bool {
        guard workspace.tabletControls else { return browser.tab != nil }
        return tabletGeometry(in: workspace.windowSize).sidebarWidth > 0 || showsToolbarDownloads(sidebarShown: false)
    }

    /// A private field runs nothing that leaves Private or shows what it
    /// keeps out (history, the other tabs, Split View), and acts on a page
    /// only when that page is private: with the eyes shut over an ordinary
    /// tab, that tab is not the field's.
    func runsInPrivate(_ command: FieldCommand) -> Bool {
        let page = browser.tab?.isPrivate == true
        switch command {
        // Show Downloads: Private's own list, over a private page.
        case .savePDF, .duplicateTab, .download, .showDownloads: return page
        case .splitView: return false
        case let .key(key):
            switch key {
            case .newPrivateTab, .toggleSidebar: return true
            case .newTab, .reopenTab, .allTabs, .settings, .openLocation, .nextTab, .previousTab, .tab: return false
            case .closeTab, .reload, .back, .forward, .find, .stop, .zoomIn, .zoomOut, .actualSize,
                 .reader, .copyLink, .print: return page
            }
        }
    }

    /// Whether a command chosen in the field may run now that the field is
    /// gone: still offered, still Private's when it was chosen in Private
    /// (the page in front may have changed since), and nothing over the
    /// browser, a lock or a cover.
    func mayRun(_ command: FieldCommand, privately: Bool) -> Bool {
        if privately, !runsInPrivate(command) { return false }
        if case let .key(key) = command { return mayUse(key) }
        return !privateContentBlocked && !privateLock.presentsPrompt && !surfaces.settings && !surfaces.join
            && surfaces.chat == nil && !surfaces.coversChrome && offers(command)
    }

    /// A command chosen in the field, once the field is gone.
    func run(_ command: FieldCommand, privately: Bool) {
        guard mayRun(command, privately: privately) else { return }
        switch command {
        case let .key(key): use(key)
        case .savePDF: savePageAsPDF()
        case .duplicateTab: if let tab = browser.tab { duplicate(tab) }
        case .splitView: newTabBeside()
        case .download: downloadPage()
        case .showDownloads: showDownloads()
        }
    }

    /// The iPad's button on screen opens its list (TabletDownloadsButton);
    /// the iPhone's plate opens on its Downloads page.
    func showDownloads() {
        if workspace.tabletControls { workspace.downloadsShown += 1 } else { openDownloadsFromPlate() }
    }
}
