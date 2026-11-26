import AppKit
import SwiftUI

/// One definition for the command's words, keys, availability and handler.
/// Search and Actions consume this same catalog; handlers call the existing
/// menu actions rather than emulating their keys.
struct MenuCommand {
    let title: String
    var aliases: [String] = []
    var symbol = "command"
    var shortcut: Shortcut.Action?
    var opens = false
    var available: @MainActor (Browser) -> Bool = { _ in true }
    let run: @MainActor (Browser) -> Void
}

enum MenuCommands {
    static let key = "experimental.menuCommands"
    static let entries: [Command: MenuCommand] = make()

    /// The half of the catalog everyone finds in ⌘T and can give a key. The
    /// rest (keys they already have, folder and project chores, developer
    /// odds and ends) waits behind More Commands in the Field.
    static let everyone: Set<Command> = [
        .sharePage, .back, .forward, .nextTab, .previousTab, .renameTab, .pickAllTabs, .keepTab, .releaseTab,
        .sleepTabs, .muteTab, .unmuteTab, .editPinnedURL, .clearToday, .tidyTabs,
        .moveTabToWindow, .smallWindow, .reopenWindow, .fullScreen, .exitFullScreen, .undoBrowserAction,
        .newSpace, .switchSpace, .moveToSpace, .renameSpace, .deleteSpace,
        .moveToFolder, .moveOutOfFolder, .renameFolder, .newFolderInside, .ungroupFolder, .newLiveFolder,
        .pasteAndGo, .muteSite, .unmuteSite, .translatePage, .showOriginalPage, .fillForm,
        .copyPageMarkdown, .savePageMarkdown, .captureFullPage, .keepPeek, .splitPeek,
        .showChat, .hideChat, .takeOverAgent, .stopAgent, .muteCall, .unmuteCall, .joinMeeting,
        .inspectElement, .measurePage, .hideRulers,
        .lightTheme, .darkTheme, .systemTheme, .shortcuts, .addExtension, .importExtensions,
        .newChatProject, .openChatProject, .moveChatToProject,
    ]

    private static func make() -> [Command: MenuCommand] {
        var out: [Command: MenuCommand] = [:]
        func add(_ command: Command, _ title: String, _ aliases: [String] = [],
                 symbol: String = "command", key: Shortcut.Action? = nil, opens: Bool = false,
                 when: @escaping @MainActor (Browser) -> Bool = { _ in true },
                 run: @escaping @MainActor (Browser) -> Void) {
            out[command] = MenuCommand(title: title, aliases: aliases, symbol: symbol,
                                      shortcut: key, opens: opens, available: when, run: run)
        }
        add(.addExtension, "Add Extension", ["Add", "add an extension", "install extension", "custom extension", "unpacked extension", "load unpacked", "A Folder on This Mac"],
            symbol: "puzzlepiece.extension", opens: true,
            when: { _ in if #available(macOS 15.4, *) { return true }; return false }) { browser in
                if #available(macOS 15.4, *) {
                    browser.openSettings(.extensions)
                    SettingsWindow.shared.showExtension(ExtensionAdd.Step.arrival.rawValue, for: browser)
                }
            }
        add(.importExtensions, "Import Extensions", ["Import", "Import Yab Extensions", "import WebKit extensions"],
            symbol: "puzzlepiece.extension", opens: true, when: { browser in
                guard PageEngineFactory.chromiumEnabled else { return false }
                if #available(macOS 15.4, *) {
                    let native = ChromiumExtensions.of(browser)
                    return !native.busy && native.canImportWebKitList(browser)
                }
                return false
            }) { browser in
                if #available(macOS 15.4, *) {
                    browser.openSettings(.extensions)
                    ChromiumExtensions.of(browser).importWebKitList(browser)
                }
            }
        let page: @MainActor (Browser) -> Bool = { $0.active.map { !$0.isBlank } ?? false }
        let web: @MainActor (Browser) -> Bool = { ["http", "https"].contains($0.active?.address?.scheme ?? "") }
        let folder: @MainActor (Browser) -> Bool = { $0.folderHere != nil }
        let spaces: @MainActor (Browser) -> Bool = { $0.spacesShown && !$0.privateBrowsing }

        add(.back, "Go Back", ["back", "go back in history"], symbol: "yab.back", key: .back,
            when: { $0.menuBack }) { $0.back(byKey: true) }
        add(.forward, "Go Forward", ["forward", "go forward in history"], symbol: "yab.forward", key: .forward,
            when: { $0.menuForward }) { $0.forward(byKey: true) }
        add(.stopLoading, "Stop Loading", symbol: "xmark", key: .stopLoading, when: { $0.active?.loading == true }) { if let tab = $0.active { $0.stop(tab) } }
        add(.closeWindow, "Close Window", symbol: "xmark.rectangle", key: .closeWindow,
            when: { window($0) != nil }) { window($0)?.performClose(nil) }
        add(.sharePage, "Share Page…", ["share page", "share this page", "share link"],
            symbol: "square.and.arrow.up", key: .sharePage, opens: true,
            when: { $0.active?.address.map { Bookmark.keepable($0) } == true }) { _ = $0.sharePage() }
        add(.pasteAndGo, "Paste and Go", symbol: "yab.clipboard.right", key: .pasteAndGo) { $0.pasteAndGo() }
        add(.findNext, "Find Next", symbol: "arrow.down", key: .findNext,
            when: { $0.finding }) { $0.look(forward: true) }
        add(.findPrevious, "Find Previous", symbol: "arrow.up", key: .findPrevious,
            when: { $0.finding }) { $0.look(forward: false) }
        add(.nextTab, "Next Tab", ["select next tab"], symbol: "yab.tab.right", key: .nextTab,
            opens: true, when: { $0.tabs.count > 1 }) { $0.step(1) }
        add(.previousTab, "Previous Tab", ["select previous tab"], symbol: "yab.tab.left", key: .previousTab,
            opens: true, when: { $0.tabs.count > 1 }) { $0.step(-1) }
        add(.moveTabLeft, "Move Tab Left", symbol: "arrow.left", key: .moveLeft, when: page) { $0.nudge(-1) }
        add(.moveTabRight, "Move Tab Right", symbol: "arrow.right", key: .moveRight, when: page) { $0.nudge(1) }
        add(.renameTab, "Rename Tab…", ["rename current tab", "rename tab"], symbol: "pencil", key: .rename,
            opens: true, when: { page($0) && $0.active?.pin == nil }) {
            if let tab = $0.active { $0.beginTabEdit(tab) }
        }
        add(.pickAllTabs, "Select All Tabs", ["pick all tabs"], symbol: "yab.tabs.check", key: .pickAll,
            when: { $0.tabs.count > 1 }) { $0.pickAll() }
        add(.moveTabToWindow, "Move Tab to New Window", symbol: "macwindow.badge.plus", key: .moveToWindow,
            when: { canMoveWindow($0) }) {
            if let tab = $0.active { _ = BrowserWindows.shared.moveToNewWindow(tab, from: $0) }
        }
        add(.moveToWindow, "Move Tab to Window…", ["move tab to window"], symbol: "rectangle.on.rectangle",
            opens: true, when: { hasTargets(.moveToWindow, in: $0) }) { choose(.moveToWindow, in: $0) }
        add(.copyTabToWindow, "Open Copy in New Window", symbol: "rectangle.on.rectangle",
            opens: true, when: page) {
            if let url = $0.active?.address { BrowserWindows.shared.newWindow(from: $0).arrive(url) }
        }
        add(.keepTab, "Keep Tab", ["keep tabs"], symbol: "anchor", key: .keepTab,
            when: { $0.chosen.contains { $0.keepable && !$0.kept } }) { $0.keepTabs($0.chosen) }
        add(.releaseTab, "Don’t Keep Tab", ["don't keep tab", "unkeep tab", "don't keep tabs", "unkeep tabs"], symbol: "yab.anchor.slash", key: .keepTab,
            when: { $0.chosen.contains(where: \.kept) }) { $0.releaseTabs($0.chosen) }
        add(.sleepTabs, "Put Tab to Sleep", ["sleep tab", "suspend tab", "put tabs to sleep"], symbol: "yab.sleepa",
            when: { $0.canSleep($0.chosen, byHand: true) }) { $0.sleep($0.chosen, byHand: true) }
        add(.keepSiteAwake, "Always Keep This Site Awake", ["keep site awake", "never sleep this site"],
            symbol: "sun.max", when: { web($0) && !AwakeSites.shared.keeps($0.active?.address) }) {
            AwakeSites.shared.toggle($0.active?.address)
        }
        add(.allowSiteSleep, "Let This Site Sleep", ["allow site sleep"], symbol: "moon",
            when: { web($0) && AwakeSites.shared.keeps($0.active?.address) }) {
            AwakeSites.shared.toggle($0.active?.address)
        }
        add(.muteTab, "Mute Tab", ["mute tabs"], symbol: "speaker.slash", key: .mute,
            when: { AudioWatch.canMute && $0.chosen.contains { $0.noisy && !$0.muted } }) { $0.chosen.forEach { $0.mute(true) } }
        add(.unmuteTab, "Unmute Tab", ["unmute tabs"], symbol: "speaker.wave.2", key: .mute,
            when: { AudioWatch.canMute && $0.chosen.contains(where: \.muted) }) { $0.chosen.forEach { $0.mute(false) } }
        add(.muteSite, "Mute This Site", ["mute site"], symbol: "yab.speakeroff",
            when: { browser in web(browser) && AudioWatch.canMute && browser.active.map { !browser.siteMuted($0) } == true }) {
            if let tab = $0.active { $0.toggleSiteMute(tab) }
        }
        add(.unmuteSite, "Unmute This Site", ["unmute site"], symbol: "yab.speaker",
            when: { browser in web(browser) && AudioWatch.canMute && browser.active.map { browser.siteMuted($0) } == true }) {
            if let tab = $0.active { $0.toggleSiteMute(tab) }
        }
        add(.resetPinnedTab, "Reset Pinned Tab", ["reset tab", "back to pinned url", "reset kept tab"],
            symbol: "arrow.uturn.backward", when: { $0.active?.awayFromHome == true }) {
            if let tab = $0.active { $0.goHome(tab) }
        }
        add(.replacePinnedURL, "Replace Pinned URL with Current Page",
            ["replace pin with current page", "replace pinned address with current", "replace kept url with current page", "replace kept address with current"],
            symbol: "link", when: { $0.active?.awayFromHome == true }) {
            if let tab = $0.active { $0.makeHome(tab) }
        }
        add(.editPinnedURL, "Edit Pinned URL…", ["edit pinned page", "edit kept page", "edit kept address", "edit kept url"], symbol: "yab.globe.pen",
            opens: true, when: { $0.active.map { $0.pin != nil || $0.kept } == true }) {
            if let tab = $0.active { $0.beginHomeEdit(tab) }
        }
        add(.clearToday, "Clear Today’s Tabs", ["clear today", "clear today tabs", "archive today"], symbol: "broom",
            when: { !$0.privateBrowsing && $0.canTidyNow }) { $0.tidyNow() }
        add(.tidyTabs, "Organize Today’s Tabs", ["tidy", "tidy tabs", "organize today tabs"], symbol: "yab.folder.bolt",
            when: { !$0.privateBrowsing && $0.canTidyTabs }) { $0.tidyTabs() }

        add(.newSpace, "New Space…", ["create space", "new space"], symbol: "plus.rectangle.on.rectangle",
            opens: true, when: spaces) { SpaceTray.open($0) }
        add(.manageSpaces, "Manage Spaces…", ["manage spaces"], symbol: "square.2.layers.3d",
            opens: true, when: { !$0.privateBrowsing }) { $0.openSettings(.spaces) }
        add(.switchSpace, "Switch Space…", ["focus on space", "switch space"], symbol: "yab.chevupdown",
            opens: true, when: { spaces($0) && $0.turnOrder.count > 1 }) { choose(.switchSpace, in: $0) }
        add(.nextSpace, "Next Space", ["select next space"], symbol: "arrow.right", key: .nextSpace,
            opens: true, when: { spaces($0) && $0.turnOrder.count > 1 }) { $0.stepSpace(1) }
        add(.previousSpace, "Previous Space", ["select previous space"], symbol: "arrow.left", key: .previousSpace,
            opens: true, when: { spaces($0) && $0.turnOrder.count > 1 }) { $0.stepSpace(-1) }
        add(.moveToSpace, "Move Tab to Space…", ["move tabs to space", "move tab to space"], symbol: "square.2.layers.3d",
            opens: true, when: { hasTargets(.moveToSpace, in: $0) }) { choose(.moveToSpace, in: $0) }
        add(.renameSpace, "Rename Space…", ["rename space"], symbol: "pencil", opens: true,
            when: { spaces($0) && $0.spaceID != Space.mailID }) { browser in
            guard let space = browser.spaces.first(where: { $0.id == browser.spaceID }) else { return }
            SpaceAsk.name(space, browser: browser) { browser.renameSpace(space.id, to: $0) }
        }
        add(.changeSpaceIcon, "Change Space Icon…", ["change space icon"], symbol: "face.smiling",
            opens: true, when: spaces) { browser in
            if let space = browser.spaces.first(where: { $0.id == browser.spaceID }) {
                SpaceTray.changeEmoji(of: space, browser: browser)
            }
        }
        add(.deleteSpace, "Delete Space…", ["delete space"], symbol: "trash",
            when: { spaces($0) && $0.canDeleteSpace($0.spaceID) && $0.spaceID != Space.mailID }) { browser in
            if let space = browser.spaces.first(where: { $0.id == browser.spaceID }) {
                SpaceTray.confirmDelete(space, browser: browser)
            }
        }
        add(.moveToFolder, "Move Tab to Folder…", ["move tabs to folder", "pin to folder", "move tab to folder"],
            symbol: "yab.folder.down", opens: true, when: { hasTargets(.moveToFolder, in: $0) }) { choose(.moveToFolder, in: $0) }
        add(.moveOutOfFolder, "Move Tab Out of Folder", ["remove tab from folder"], symbol: "yab.folder.up",
            when: folder) { browser in browser.chosen.forEach { browser.unfile($0) } }
        add(.openFolder, "Open Folder…", ["open folder"], symbol: "folder", opens: true,
            when: { hasTargets(.openFolder, in: $0) }) { choose(.openFolder, in: $0) }
        add(.closeFolder, "Close Folder…", ["close folder"], symbol: "folder", opens: true, when: { hasTargets(.closeFolder, in: $0) }) {
            choose(.closeFolder, in: $0)
        }
        add(.renameFolder, "Rename Folder…", ["rename folder"], symbol: "pencil", opens: true,
            when: { hasTargets(.renameFolder, in: $0) }) { choose(.renameFolder, in: $0) }
        add(.customizeFolder, "Customize Folder…", ["change folder icon", "change folder color", "customize folder"],
            symbol: "slider.horizontal.3", opens: true, when: { hasTargets(.customizeFolder, in: $0) }) { choose(.customizeFolder, in: $0) }
        add(.newFolderInside, "New Folder Inside…", ["new folder inside", "nested folder"], symbol: "folder.badge.plus",
            opens: true, when: { hasTargets(.newFolderInside, in: $0) }) { choose(.newFolderInside, in: $0) }
        add(.openFoldersInside, "Open All Folders Inside", ["expand all folders"], symbol: "folder",
            opens: true, when: folder) {
            if let nest = $0.folderHere { $0.folderBook.openAll(nest, true) }
        }
        add(.closeFoldersInside, "Close All Folders Inside", ["collapse all folders"], symbol: "folder",
            when: folder) { if let nest = $0.folderHere { $0.folderBook.openAll(nest, false) } }
        add(.moveFolder, "Move Folder…", ["move folder"], symbol: "folder", opens: true,
            when: { hasTargets(.moveFolder, in: $0) }) { choose(.moveFolder, in: $0) }
        add(.ungroupFolder, "Remove Folder, Keep Tabs", ["ungroup folder", "ungroup", "remove folder keep tabs"],
            symbol: "yab.folder.minus", opens: true, when: { hasTargets(.ungroupFolder, in: $0) }) {
            choose(.ungroupFolder, in: $0)
        }
        add(.newLiveFolder, "New Live Folder…", ["create live folder", "new live folder"], symbol: "yab.folder.refresh",
            opens: true, when: { !$0.privateBrowsing }) { choose(.newLiveFolder, in: $0) }
        add(.keepSearchAsFolder, "Keep This Search as a Folder", ["keep search as folder"], symbol: "folder",
            when: { !$0.privateBrowsing && $0.active.map { LiveIssues.search(in: $0.address) != nil && $0.address.flatMap(LiveGitHub.host(of:)) != nil } == true }) {
            if let tab = $0.active { LiveFolders.shared.keepSearch(tab, in: $0) }
        }
        add(.followSiteInFolder, "Follow This Site in a Folder", ["follow site in folder"], symbol: "folder",
            when: { !$0.privateBrowsing && web($0) }) { if let tab = $0.active { LiveFolders.shared.follow(tab, in: $0) } }
        add(.updateLiveFolder, "Update Live Folder…", ["update live folder", "refresh live folder"], symbol: "arrow.clockwise", opens: true,
            when: { hasTargets(.updateLiveFolder, in: $0) }) { choose(.updateLiveFolder, in: $0) }
        add(.stopLiveFolder, "Stop Updating Live Folder…", ["stop updating live folder"], symbol: "pause", opens: true,
            when: { hasTargets(.stopLiveFolder, in: $0) }) { choose(.stopLiveFolder, in: $0) }

        add(.translatePage, "Translate Page", ["translate", "translate page"], symbol: "yab.translate",
            key: .translatePage, when: { browser in
                guard let tab = browser.active, browser.pageTranslation.canTranslate(tab) else { return false }
                switch browser.pageTranslation.phase(for: tab) { case .original, .failed: return true; default: return false }
            }) { _ = $0.toggleTranslation() }
        add(.showOriginalPage, "Show Original Page", ["show original", "original page"], symbol: "translate",
            key: .translatePage, when: { browser in browser.active.map { browser.pageTranslation.phase(for: $0) == .translated } == true }) {
            _ = $0.toggleTranslation()
        }
        add(.stopTranslation, "Stop Translating", ["stop translation"], symbol: "character.bubble",
            key: .translatePage, when: { browser in browser.active.map {
                let phase = browser.pageTranslation.phase(for: $0)
                return phase == .preparing || phase == .translating
            } == true }) { _ = $0.toggleTranslation() }
        add(.hideRulers, "Hide Rulers", ["measure", "rulers", "stop measuring"], symbol: "yab.ruler", key: .measure,
            when: { $0.active?.measuring == true }) { $0.toggleMeasure() }
        add(.exitFullScreen, "Exit Full Screen", ["full screen"], symbol: "arrow.down.right.and.arrow.up.left",
            when: { window($0)?.styleMask.contains(.fullScreen) == true }) { window($0)?.toggleFullScreen(nil) }
        add(.fillForm, "Fill Form", ["autofill form", "fill this form"], symbol: "yab.page.pen",
            key: .fillForm, when: web) { $0.fillForm() }
        add(.copyPageMarkdown, "Copy Page as Markdown", ["copy page markdown", "copy page text"], symbol: "yab.copyframe.doc", when: page) {
            $0.copyWholePageForCommand(save: false)
        }
        add(.savePageMarkdown, "Save Page as Markdown", ["save page", "save page as", "export page markdown"],
            symbol: "yab.doc.dl", when: { page($0) && !$0.privateBrowsing }) { $0.copyWholePageForCommand(save: true) }
        add(.captureFullPage, "Capture Full Page", ["full page screenshot", "capture whole page"], symbol: "capture.screen", when: page) {
            $0.captureForCommand(whole: true)
        }
        add(.capturePortrait, "Capture in Portrait Mode", ["portrait screenshot", "capture portrait"], symbol: "camera", when: page) {
            $0.captureForCommand(whole: false, portrait: true)
        }
        add(.keepPeek, "Open Peek as Tab", ["keep peek", "open peek as tab"], symbol: "square.arrow.out", key: .peekTab,
            opens: true, when: { $0.peeking != nil }) { $0.keepPeek() }
        add(.splitPeek, "Open Peek in Split View", ["split peek"], symbol: "rectangle.split.2x1", key: .peekSplit,
            opens: true, when: { $0.peeking != nil }) { $0.splitPeek() }
        add(.closePeek, "Close Peek", symbol: "xmark", key: .peekClose, when: { $0.peeking != nil }) { $0.closePeek() }
        add(.smallWindow, "New Small Window", ["little arc", "little window", "small window"], symbol: "macwindow",
            key: .newSmallWindow, opens: true) { _ in LinkWindow.blank() }
        add(.fullScreen, "Enter Full Screen", ["full screen"], symbol: "arrow.up.left.and.arrow.down.right",
            when: { window($0).map { !$0.styleMask.contains(.fullScreen) } == true }) { window($0)?.toggleFullScreen(nil) }
        add(.undoBrowserAction, "Undo Last Browser Action", ["undo", "undo last action"], symbol: "yab.undo",
            when: { $0.canUndoClose(nativeEditor: false) }) { _ = $0.undoWindow() }
        add(.showChat, "Show Chat", ["open chat"], symbol: "yab.chat", key: .closeChat, opens: true,
            when: { !$0.chatOpen && AIUse.chats }) { $0.moveChat(open: true) }
        add(.hideChat, "Hide Chat", symbol: "yab.chat.x", key: .closeChat, when: { $0.chatOpen }) { $0.hideChat() }
        add(.takeOverAgent, "Take Over from Agent", ["take over", "take over from agent"], symbol: "hand.raised", key: .agentTakeWheel,
            when: { canTakeOver($0) }) { if let tab = $0.active { AgentFeed.shared.drive(tab) } }
        add(.handBackAgent, "Hand Back to Agent", symbol: "arrow.uturn.backward", key: .agentHandBack,
            when: { $0.active.map { AgentFeed.shared.driving.contains($0.id) } == true }) {
            if let tab = $0.active { AgentFeed.shared.handBack(tab) }
        }
        add(.stopAgent, "Stop Agent", symbol: "stop", key: .agentStop,
            when: { Agents.shared.session($0.active?.worker)?.state.live == true }) {
            if let tab = $0.active { _ = Agents.shared.stop(on: tab) }
        }
        add(.muteCall, "Mute Call", ["mute microphone"], symbol: "yab.mic.slash", key: .muteCall,
            when: { $0.call.map { $0.microphone != .none && $0.mic != .muted } == true }) { $0.toggleCallMic() }
        add(.unmuteCall, "Unmute Call", ["unmute microphone"], symbol: "mic", key: .muteCall,
            when: { $0.call.map { $0.microphone != .none && $0.mic == .muted } == true }) { $0.toggleCallMic() }
        add(.joinMeeting, "Join Next Meeting", ["join call", "join meeting"], symbol: "video", key: .joinMeeting,
            opens: true, when: { _ in Meetings.shared.next() != nil }) { $0.joinNextMeeting() }
        add(.openMeetingThread, "Open Meeting Thread", symbol: "bubble", key: .openMeetingThread,
            opens: true, when: { _ in Meetings.shared.next() != nil }) { _ = $0.openMeetingThread() }

        add(.inspectElement, "Inspect Element", ["inspect an element"], symbol: "square.cursor", key: .inspectElement,
            opens: true, when: page) { $0.inspectElement() }
        add(.errorsAndNetwork, "Errors and Network", ["show errors and network"], symbol: "network", key: .devSheet,
            opens: true, when: page) { $0.toggleDevSheet() }
        add(.measurePage, "Measure Page", ["measure", "rulers", "show rulers"], symbol: "ruler", key: .measure,
            when: { $0.active?.isDev == true && $0.active?.measuring != true }) { $0.toggleMeasure() }
        add(.focusOtherHalf, "Focus Other Half", ["focus other pane", "next split pane"], symbol: "rectangle.split.2x1",
            opens: true, when: { $0.splitShown }) { browser in
            if let active = browser.active, let other = browser.partner(of: active) {
                browser.focus(other)
                if let web = other.builtPage { window(browser)?.makeFirstResponder(web) }
            }
        }
        add(.swapHalves, "Swap Halves", ["swap split panes"], symbol: "arrow.left.arrow.right",
            when: { $0.splitShown && $0.stagePair?.count == 2 }) { if let pair = $0.stagePair { $0.swapHalves(pair) } }
        for (command, title, aliases, symbol, arrangement) in [
            (Command.splitSideBySide, "Split View Side by Side", ["arrange split side by side", "split columns"], "rectangle.split.2x1", Pair.Arrangement.across),
            (.splitStacked, "Split View Stacked", ["arrange split stacked", "split rows", "split vertically"], "rectangle.split.1x2", .stacked),
        ] {
            add(command, title, aliases, symbol: symbol,
                when: { browser in browser.splitShown && browser.stagePair.map { browser.canArrange($0, arrangement) } == true }) { browser in
                if let pair = browser.stagePair { browser.arrange(pair, arrangement) }
            }
        }
        add(.developerPanel, "Open Developer Panel…", ["developer panels"], symbol: "hammer", opens: true,
            when: page) { choose(.developerPanel, in: $0) }
        add(.showFullURL, "Show Full URL", ["full url"], symbol: "link",
            when: { $0.prefs.addressBar && !$0.prefs.fullURL }) { $0.prefs.fullURL = true }
        add(.showSiteURL, "Show Site Name Only", ["hide full url", "short url"], symbol: "link",
            when: { $0.prefs.addressBar && $0.prefs.fullURL }) { $0.prefs.fullURL = false }
        add(.lightTheme, "Switch to Light Mode", ["light mode", "light theme", "toggle light and dark mode"], symbol: "yab.sun", opens: true,
            when: { $0.prefs.look != .light }) { $0.prefs.look = .light }
        add(.darkTheme, "Switch to Dark Mode", ["dark mode", "dark theme", "toggle dark mode", "toggle light and dark mode"], symbol: "moon", opens: true,
            when: { $0.prefs.look != .dark }) { $0.prefs.look = .dark }
        add(.systemTheme, "Use System Appearance", ["system theme", "system appearance", "automatic theme"],
            symbol: "circle.lefthalf", opens: true, when: { $0.prefs.look != .system }) { $0.prefs.look = .system }
        add(.shortcuts, "Keyboard Shortcuts", ["shortcuts", "common shortcuts", "open shortcuts"],
            symbol: "keyboard", opens: true) { $0.openSettings(.shortcuts) }
        add(.importBrowser, "Import from Another Browser…", ["import browser", "import from another browser"],
            symbol: "square.and.arrow.down", opens: true) { $0.openSettings(.bringIn) }
        add(.copyDiagnostics, "Copy Diagnostics", symbol: "doc.on.doc") { $0.copyMenuDiagnostics() }
        add(.reopenWindow, "Reopen Closed Window", ["restore closed window"], symbol: "yab.window.undo",
            opens: true, when: { _ in BrowserWindows.shared.canReopen }) { _ in BrowserWindows.shared.reopenClosedWindow() }
        for (index, command) in numberedTabs.enumerated() {
            let number = index + 1
            add(command, number == 9 ? "Go to Last Tab" : "Go to Tab \(number)",
                [number == 9 ? "last tab" : "tab \(number)"], symbol: "rectangle",
                key: Shortcut.numbered("tab", number), opens: true,
                when: { $0.numberable().count >= (number == 9 ? 1 : number) }) {
                $0.select(index: number == 9 ? $0.tabs.count - 1 : number - 1)
            }
        }
        add(.newChatProject, "New Project…", ["new project", "create project", "chat projects", "projects", "проекты"],
              symbol: "yab.suitcase.plus", opens: true) { ChatMoves.newProject(with: [], browser: $0) }
        add(.openChatProject, "Open Project…", ["open project"], symbol: "yab.suitcase", opens: true,
              when: { !$0.chatProjects.listed.isEmpty }) { MenuCommands.choose(.openChatProject, in: $0) }
        add(.askInChatProject, "Ask in Project…", ["new chat in project"], opens: true,
              when: { !$0.chatProjects.listed.isEmpty }) { MenuCommands.choose(.askInChatProject, in: $0) }
        add(.moveChatToProject, "Move to Project…", ["move to project", "move chat to project"], symbol: "yab.chat.right", key: .moveToProject,
              opens: true, when: { $0.chatOpen && !$0.chatHistory && Chats.shared.chat($0.chatID) != nil }) { ChatMoves.ask(in: $0) }
        add(.removeChatFromProject, "Remove Chat from Project", ["remove from project"],
              when: { !$0.chatHistory && Projects.shared.project(Chats.shared.chat($0.chatID)?.project) != nil }) {
            if let id = $0.chatID { ChatMoves.move([id], to: nil) }
        }
        add(.inspectChatProject, "About Project", ["project info", "project instructions"], opens: true,
              when: { ChatProjectCommands.current(in: $0) != nil }) {
            if let project = ChatProjectCommands.current(in: $0) { $0.openProject(project.id); $0.chatProjectInfo = true }
        }
        add(.pinChatProject, "Pin Project", ["pin chat project"], symbol: "pin",
              when: { ChatProjectCommands.current(in: $0).map { !$0.pinned && $0.archived != true } == true }) {
            if let project = ChatProjectCommands.current(in: $0) { $0.chatProjects.pin(project.id, true) }
        }
        add(.unpinChatProject, "Unpin Project", ["unpin chat project"], symbol: "pin.slash",
              when: { ChatProjectCommands.current(in: $0)?.pinned == true }) {
            if let project = ChatProjectCommands.current(in: $0) { $0.chatProjects.pin(project.id, false) }
        }
        add(.archiveChatProject, "Archive Project", symbol: "archivebox",
              when: { ChatProjectCommands.current(in: $0).map { $0.archived != true } == true }) {
            if let project = ChatProjectCommands.current(in: $0) { $0.chatProjects.archive(project.id, true); $0.openProject(nil) }
        }
        add(.unarchiveChatProject, "Unarchive Project", symbol: "archivebox",
              when: { ChatProjectCommands.current(in: $0)?.archived == true }) {
            if let project = ChatProjectCommands.current(in: $0) { $0.chatProjects.archive(project.id, false) }
        }
        add(.renameChatProject, "Rename Project…", symbol: "pencil", opens: true,
              when: { ChatProjectCommands.current(in: $0) != nil }) {
            if let project = ChatProjectCommands.current(in: $0) { ChatProjectCommands.rename(project) }
        }
        add(.deleteChatProject, "Delete Project…", symbol: "trash",
              when: { ChatProjectCommands.current(in: $0) != nil }) {
            if let project = ChatProjectCommands.current(in: $0) { ChatProjectCommands.delete(project, in: $0) }
        }
        add(.showProjectFiles, "Show Project Files", ["project files", "open project files"], opens: true,
              when: { ChatProjectCommands.current(in: $0) != nil }) {
            if let project = ChatProjectCommands.current(in: $0) {
                try? FileManager.default.createDirectory(at: project.files, withIntermediateDirectories: true)
                NSWorkspace.shared.open(project.files)
            }
        }
        add(.addProjectFiles, "Add Files to Project…", ["add project files"], symbol: "paperclip", opens: true,
              when: { ChatProjectCommands.current(in: $0) != nil }) {
            if let project = ChatProjectCommands.current(in: $0) { ChatProjectCommands.addFiles(project) }
        }
        add(.newProjectRoutine, "New Routine in Project", ["project routine"], symbol: "clock.arrow.circlepath", opens: true,
              when: { ChatProjectCommands.current(in: $0).map { $0.archived != true } == true }) {
            if let project = ChatProjectCommands.current(in: $0) { $0.newChat(in: project.id); $0.chatDraft = "Every morning at 8, " }
        }
        add(.enableProjectMemory, "Turn On Project Memory", ["project memory", "remember from these chats"], symbol: "brain",
            when: { ChatProjectCommands.current(in: $0)?.memoryOn == false }) {
            if var project = ChatProjectCommands.current(in: $0) { project.memoryOn = true; $0.chatProjects.update(project) }
        }
        add(.disableProjectMemory, "Turn Off Project Memory", ["project memory", "remember from these chats"], symbol: "brain",
            when: { ChatProjectCommands.current(in: $0)?.memoryOn == true }) {
            if var project = ChatProjectCommands.current(in: $0) { project.memoryOn = false; $0.chatProjects.update(project) }
        }
        return out
    }

    static let numberedTabs: [Command] = [.tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .lastTab]
    static let global: Set<Command> = [.smallWindow, .shortcuts, .importBrowser, .copyDiagnostics,
                                       .lightTheme, .darkTheme, .systemTheme, .manageSpaces]

    /// Old catalog entries also teach the user's current keys, not defaults.
    static let legacyKeys: [Command: Shortcut.Action] = [
        .newWindow: .newWindow, .newTab: .newTab, .privateTab: .privateTab, .reopen: .reopen,
        .history: .history, .downloads: .downloads, .bookmarks: .bookmarks, .passwords: .passwords,
        .settings: .settings, .bookmarkPage: .bookmark, .reader: .reader, .darkPage: .darkPage,
        .find: .find, .print: .print, .capture: .capture, .duplicate: .duplicate,
        .copyAddress: .copyAddress, .copyMarkdownLink: .copyMarkdownLink, .floatVideo: .float,
        .hide: .hide, .closeTab: .closeTab, .reload: .reload, .hardReload: .hardReload,
        .zoomIn: .zoomIn, .zoomOut: .zoomOut, .actualSize: .actualSize,
        .inspector: .inspector, .console: .console, .extensions: .extensions,
        .pinTab: .pin, .unpinTab: .pin, .closeOthers: .closeOthers, .closeBefore: .closeBefore,
        .closeAfter: .closeAfter, .folderWithTabs: .folderWithTabs, .newTabInFolder: .newTabInFolder,
        .blankWindow: .blankWindow,
        .splitView: .split, .separate: .split, .showBar: .addressBar, .hideBar: .addressBar,
        .showShelf: .bookmarksBar, .hideShelf: .bookmarksBar, .mail: .mail,
        .devModeOn: .devMode, .devModeOff: .devMode, .feedback: .sendFeedback,
        .showSidebar: .column, .hideSidebar: .column, .showStrip: .column, .hideStrip: .column,
        .newYork: .sidebarTabs, .sanFrancisco: .sidebarTabs, .jsonText: .jsonView, .jsonTree: .jsonView,
    ]


    @MainActor static func contextTitle(_ command: Command, in browser: Browser) -> String? {
        switch command {
        case .sleepTabs where browser.several: return "Put \(browser.chosenCount) Tabs to Sleep"
        case .keepTab where browser.several: return "Keep \(browser.chosenCount) Tabs"
        case .releaseTab where browser.several: return "Don’t Keep \(browser.chosenCount) Tabs"
        case .muteTab where browser.several: return "Mute \(browser.chosenCount) Tabs"
        case .unmuteTab where browser.several: return "Unmute \(browser.chosenCount) Tabs"
        case .moveToFolder where browser.several: return "Move Tabs to Folder…"
        case .moveToSpace where browser.several: return "Move Tabs to Space…"
        case .resetPinnedTab where browser.active?.pin == nil: return "Reset Kept Tab"
        case .replacePinnedURL where browser.active?.pin == nil: return "Replace Kept URL with Current Page"
        case .editPinnedURL where browser.active?.pin == nil: return "Edit Kept URL…"
        default: return nil
        }
    }

    static func symbol(forTargetID id: String) -> String {
        guard let word = id.split(separator: ":").first, let command = Command(rawValue: String(word)) else { return "command" }
        return entries[command]?.symbol ?? "command"
    }

    @MainActor static func window(_ browser: Browser) -> NSWindow? { BrowserWindows.shared.window(for: browser) }
    @MainActor static func canMoveWindow(_ browser: Browser) -> Bool {
        guard let tab = browser.active else { return false }
        return !tab.isBlank && !tab.shy && !tab.onCall && tab.everywhere == nil && browser.partner(of: tab) == nil
    }
    @MainActor static func canTakeOver(_ browser: Browser) -> Bool {
        guard let tab = browser.active, let session = Agents.shared.session(tab.worker) else { return false }
        return session.state.live && !session.script && !AgentFeed.shared.driving.contains(tab.id) && tab.handoff == nil
    }
}
