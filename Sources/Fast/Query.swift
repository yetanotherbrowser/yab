import AppKit
import Foundation
import SwiftUI

/// What the address field is saying while it is typed into: the letters, the
/// rows under them, the gray ending, the row walked to.
///
/// Its own object rather than more of the browser's, because it changes on
/// every keystroke and the browser is what the whole window watches. Held
/// there, each letter re-read the strip, the column, the page and every
/// overlay to decide nothing had changed; held here, it redraws the field
/// and its list.
@MainActor
final class Query: ObservableObject {
    var pasteStyleTarget = PasteStyleTarget()
    @Published var typed = "" {
        didSet { if typed != oldValue { unpick() } }
    }
    /// A selection command's answer is what the field shows (FieldAnswer),
    /// the field itself taking a follow-up.
    @Published var answering = false
    /// ⌘K's list is the models to answer again on (⇧⌘R over an answer),
    /// not the answer's actions.
    @Published var choosingModel = false
    /// ⌘K's list is what a place's list is narrowed to, dropped from the
    /// field's end: Files' folders, kinds, sites (Browser.chooseFilter).
    @Published var choosingFilter = false
    /// ⌘K's list is Yab's own About menu, risen from the button at the
    /// foot's left (⇧⌘K), not the row's actions.
    @Published var choosingAbout = false
    /// Turned as the answer's state changes, so the foot says what Return
    /// does now (Stop, Replace Selection…): the foot watches the query, not
    /// the commands, whose every word would redraw the whole box.
    @Published var answerTurn = 0
    /// The foot's pill's width while an answer shows: the field, moved
    /// down beside it to take a follow-up, keeps clear of it.
    @Published var footPill: CGFloat = 0
    /// What the field is offering, best first.
    @Published var offers: [Suggestion] = []
    /// The rest of the best match, drawn after the caret. Tab takes it.
    @Published var ending: String?
    /// Which row the arrow keys have walked to, if any. The field shows its
    /// address.
    @Published var picked: Int?
    /// Which row the pointer moved onto, if any. Chosen as surely as a row
    /// walked to, but the field keeps what was typed: a hand passing over
    /// the list should not be rewriting the address.
    @Published var pointed: Int?
    /// Where the pointer was when the list last changed. A list that comes
    /// up under a resting pointer isn't a choice; the pointer has to move.
    var restingAt: CGPoint?
    /// The question the list last answered: the words and where they were
    /// asked. The same question answered again, as suggestions, history or
    /// a reading of the words come in late, keeps the row walked to
    /// (Browser.answer).
    var answered: Asked?
    struct Asked: Equatable {
        var typed: String
        var place: FieldPlace?
        var scope: Scope?
        var actions: Bool
    }
    /// The one row that is chosen, pointed at, walked to, or else the one
    /// the field proposes. It is the row that looks chosen, and the row
    /// Return takes: never two different rows.
    var current: Int? { pointed ?? picked ?? lead }

    /// The row Return takes when none has been walked to: the place the
    /// ending finishes, a thing to do the words clearly name, or the search.
    /// Marked, so Return is never a guess.
    @Published var lead: Int?
    /// Whether the list last grew, so it can grow at the pace things arrive
    /// and shrink at the quicker pace things leave.
    var grew = true
    /// Bumped whenever the cursor should go back into the field.
    @Published var focusRequest = 0
    /// The page ⌘L raised the field over. While the field still says its
    /// address, untouched, the field is that page's and not a question:
    /// no list under it, its site's mark where the glass was.
    var here: URL?
    /// The site the field is searching, after Tab took its name (see
    /// Scopes). Its words go to that site, not the engine.
    @Published var scope: Scope?
    /// The site Tab would search, for what is typed now: said on its row.
    @Published var offering: Scope?
    /// ⇥ put the search above the agent's row, for words read as this (Ask,
    /// the task): words read otherwise have their own row on top again.
    var searchOver: Suggestion.Kind?
    /// What was typed when Tab made the field a site's, given back by ⌫.
    var before = ""
    /// The last site's color, light and dark, worked out once on Tab
    /// rather than on every key, and kept after it so the box's tint
    /// fades out in it.
    var tints: (light: Color, dark: Color) = (.clear, .clear)

    func lastTint(dark: Bool) -> Color { dark ? tints.dark : tints.light }

    /// The field's own place it is in, after Tab took its name: Clipboard
    /// History or Emoji. What is typed then looks only there.
    @Published var place: FieldPlace? {
        didSet { if place != oldValue { placeFromField = false; unpick() } }
    }
    /// Only a destination entered in the new-tab field belongs to its next
    /// opening. A place's own key, menu or link starts a separate request.
    var placeFromField = false
    /// Destination and category only: never keep a page target, secret,
    /// search, selection or in-progress edit after the field closes.
    var returnPlace: (place: FieldPlace, filter: Int)?

    /// The empty field's "Set up Yab" row taken: getting started's rows in
    /// its place, until Escape or the field goes.
    var settingUp = false
    /// Tab in the compact card's empty field, as in Arc's: what can be done
    /// here, found by name, its keys on its row. Escape, or ⌫ in its empty
    /// field, goes back.
    @Published var actionsPage = false
    /// Which row of the place is chosen: a clip, or an emoji in the grid.
    @Published var spot = 0 {
        didSet {
            guard spot != oldValue else { return }
            if revealed != nil { revealed = nil }
            if !shown.isEmpty { shown = [:] }
        }
    }
    /// Rows of a place picked together, by their ids, for one act on all of
    /// them (PlacePicks.swift): ⌘-click, ⇧-click, ⇧↑ and ⇧↓. Empty, or
    /// one, is the plain list with its one chosen row.
    @Published var picks: Set<String> = []
    /// Where ⇧-click and ⇧↑/⇧↓ stretch the picks from.
    var pickAnchor: Int?

    func unpick() {
        if !picks.isEmpty { picks = [] }
        pickAnchor = nil
    }

    /// Which kinds of clip the history shows.
    @Published var clipFilter: Clips.Filter = .all
    /// ⌘K's list of what can be done to the chosen row, and which of its
    /// rows is chosen; nil while it is down. The keyboard is in the list's
    /// own search while it is up (FieldActionsPanel).
    @Published var acting: Int? {
        didSet {
            // Up, a click anywhere but on it or its button puts it away.
            if (acting == nil) != (oldValue == nil) { away.watch(acting != nil) }
            // Put away, the keyboard goes back to the field from the
            // list's own search.
            if acting == nil, oldValue != nil {
                actionWords = ""
                if choosingModel { choosingModel = false }
                if choosingFilter { choosingFilter = false }
                if choosingAbout { choosingAbout = false }
                // A turn later, and only if no list came back up meanwhile:
                // ⌘K's Again with Another Model puts the models' own list up
                // as its own goes, and its search keeps the keyboard.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.acting == nil else { return }
                    self.focusRequest += 1
                }
            }
        }
    }
    /// ⌘K's list and the buttons that raise it, where a click leaves it up.
    lazy var away = ClickAway { [weak self] in self?.acting = nil }
    /// Which of a place's filters its list is narrowed to (FieldPlace.filters).
    @Published var placeFilter = 0 {
        didSet { if placeFilter != oldValue { unpick() } }
    }
    /// What a place read as it opened (Places.swift).
    @Published var stock = PlaceStock()
    /// Only the latest History search needs to run while keys arrive.
    var historySearchWork: DispatchWorkItem?
    /// A password or a card number shown, after Touch ID, in the chosen
    /// row's preview only; gone when the row or the place changes.
    @Published var revealed: (id: String, text: String)?
    /// Secrets copied after Touch ID, by what they are ("number.<card>",
    /// "code.<card>", "password.<login>"): they stay in view, to be read
    /// out, while the row stays chosen.
    @Published var shown: [String: String] = [:]
    /// The chosen row being written, its lines fields in the preview
    /// (PlaceEdit.swift); nil while nothing is.
    @Published var edit: PlaceEdit? {
        didSet {
            if oldValue?.passwordEditor !== edit?.passwordEditor {
                oldValue?.passwordEditor?.cancel(nil)
            }
        }
    }
    /// The box on the page the caret was in as the field came up.
    var form: PageForm?
    /// What is typed in ⌘K's list's own search: the actions it keeps.
    @Published var actionWords = ""
    /// Whether the caret was in a box on the page as the field came up:
    /// what the field puts in goes there.
    var pageTyping = false
}

/// The things the app can do, found by name in the field, so "private",
/// "history" or "settings" is a place to go like any other.
enum Command: String, CaseIterable {
    case newWindow, newTab, privateTab, reopen
    /// A window whose tabs are its own, in no space (BlankWindow.swift).
    case blankWindow
    case history, downloads, bookmarks, passwords, autofill, settings
    /// Autofill's Bring In, from the field, for cards and addresses kept
    /// in another browser.
    case bringCards
    case importYabPasswords
    case bookmarkPage, reader, find, print, capture, duplicate, copyAddress, copyMarkdownLink, pasteAndMatchStyle, floatVideo, hide, closeTab
    /// The site in front kept light, or dark again (DarkPages.swift).
    case darkPage
    case reload, hardReload, clearCookies, zoomIn, zoomOut, actualSize, pinTab, unpinTab, closeOthers, closeBefore, closeAfter, hidden, inspector, console
    case extensions, welcome, boostStore, addExtension, importExtensions
    /// A boost for the site in front, from the agent; Arc's boosts brought
    /// over while Arc has some not here yet (ArcBoosts, register #447).
    case newBoost, arcBoosts
    case customizeSite, customizationOn, customizationOff
    /// Mail's space, and back to your tabs from it (MailSpace, ⇧⌘I).
    case mail
    /// The space's look, in a card over the window it paints (LookCard).
    case look
    /// A folder of yours among the kept tabs, empty, to put tabs in (Kept.swift).
    case newFolder
    /// The picked tabs, or the one in front, in a folder of yours (⌃⌘N).
    case folderWithTabs
    /// ⌘T's field, its tab going into the folder the tab in front is in (⌥⌘T).
    case newTabInFolder
    /// A live folder of your pull requests, kept up to date (LiveFolders.swift).
    case pullRequestsFolder
    /// What the Help menu and About have: a word to yab, a look for a new
    /// version or the restart one waits for, and the links it could take.
    case manual, feedback, invite, wrapped, checkUpdates, restartUpdate, makeDefault
    /// Two tabs side by side (Split.swift), and apart again.
    case splitView, separate
    /// How the window is laid out: the address bar, the column put away or
    /// brought back, the strip the same with the tabs across the top, and
    /// the tabs across the top (San Francisco, as the welcome calls it) or
    /// down the side (New York). Each is offered only in the state it
    /// changes, under the name of what it would do.
    case showBar, hideBar, showShelf, hideShelf, showSidebar, hideSidebar, showStrip, hideStrip, newYork, sanFrancisco
    /// Developer Mode for a local page's server, offered in the state it
    /// changes (DevMode.swift).
    case devModeOn, devModeOff
    /// A page that came as JSON, as text or as a tree, copied, saved and
    /// opened all the way (JSONView.swift); the setting from any page.
    case jsonText, jsonTree, copyJSON, saveJSON, expandJSON, jsonSetting
    /// A PDF's form filled, words put anywhere, signed (PDFDesk.swift).
    case fillSign
    /// Yab's buttons in a site's own rows, off here or back (SiteItems.swift).
    case hideSiteButtons, showSiteButtons
    /// AI in Yab (AIUse, Settings › AI), each offered where it changes
    /// something; and the Ask and Task rows under the words put away or
    /// back, the switch left as it is.
    case aiOff, aiOn, aiWhenAsked, hideAIRows, showAIRows

    /// Existing menu actions share their metadata and routes in MenuCommands.
    case sharePage
    case back, forward, stopLoading, closeWindow, pasteAndGo, findNext, findPrevious
    case nextTab, previousTab, moveTabLeft, moveTabRight, renameTab, pickAllTabs, moveTabToWindow
    case moveToWindow, copyTabToWindow, keepTab, releaseTab, sleepTabs, keepSiteAwake, allowSiteSleep
    case muteTab, unmuteTab, muteSite, unmuteSite, resetPinnedTab, replacePinnedURL, editPinnedURL
    case clearToday, tidyTabs, newSpace, manageSpaces, switchSpace, nextSpace, previousSpace
    case moveToSpace, renameSpace, changeSpaceIcon, deleteSpace, moveToFolder, moveOutOfFolder, openFolder
    case closeFolder, renameFolder, customizeFolder, newFolderInside, moveFolder, ungroupFolder, newLiveFolder
    case keepSearchAsFolder, followSiteInFolder, updateLiveFolder, stopLiveFolder, translatePage, fillForm, copyPageMarkdown
    case savePageMarkdown, captureFullPage, capturePortrait, keepPeek, splitPeek, closePeek, smallWindow
    case fullScreen, undoBrowserAction, showChat, hideChat, takeOverAgent, handBackAgent, stopAgent
    case muteCall, unmuteCall, joinMeeting, openMeetingThread, inspectElement, errorsAndNetwork, measurePage
    case focusOtherHalf, swapHalves, splitSideBySide, splitStacked, developerPanel, showFullURL, showSiteURL, lightTheme, darkTheme
    case systemTheme, shortcuts, importBrowser, copyDiagnostics, tab1, tab2, tab3
    case tab4, tab5, tab6, tab7, tab8, lastTab
    case openFoldersInside, closeFoldersInside, showOriginalPage, stopTranslation, hideRulers, exitFullScreen, reopenWindow
    case newChatProject, openChatProject, askInChatProject, moveChatToProject, removeChatFromProject
    case inspectChatProject, pinChatProject, unpinChatProject, archiveChatProject, unarchiveChatProject
    case renameChatProject, deleteChatProject, showProjectFiles, addProjectFiles, newProjectRoutine
    case enableProjectMemory, disableProjectMemory

    var title: String {
        switch self {
        case .newWindow: return "New Window"
        case .newTab: return "New Tab"
        case .mail: return "Open Mail"
        case .privateTab: return "New Private Window"
        case .blankWindow: return "Blank Window"
        case .reopen: return "Reopen Closed Tab"
        case .history: return "History"
        case .downloads: return "Downloads"
        case .bookmarks: return "Bookmarks"
        case .passwords: return "Passwords"
        case .importYabPasswords: return "Import Yab Passwords…"
        case .autofill: return "Cards and Addresses"
        case .bringCards: return "Bring In Cards and Addresses"
        case .settings: return "Settings"
        case .manual: return "Yab Manual"
        case .bookmarkPage: return "Bookmark This Page"
        case .reader: return "Reading Mode"
        case .darkPage: return "Dark Page"
        case .find: return "Find on Page"
        case .print: return "Print"
        case .capture: return "Capture Part of the Page"
        case .duplicate: return "Duplicate Tab"
        case .copyAddress: return "Copy URL"
        case .copyMarkdownLink: return "Copy Markdown Link"
        case .pasteAndMatchStyle: return "Paste and Match Style"
        case .floatVideo: return "Float Video"
        case .hide: return "Hide Elements"
        case .closeTab: return "Close Tab"
        case .reload: return "Reload Page"
        case .hardReload: return "Reload Without Cache"
        case .clearCookies: return "Clear Cookies and Refresh"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .actualSize: return "Actual Size"
        case .pinTab: return "Pin Tab"
        case .unpinTab: return "Unpin Tab"
        case .newFolder: return "New Folder"
        case .folderWithTabs: return "New Folder with Tabs"
        case .newTabInFolder: return "New Tab in Folder"
        case .pullRequestsFolder: return "Pull Requests Folder"
        case .closeOthers: return "Close Other Tabs"
        case .closeBefore: return Shortcut.titles[.closeBefore]!
        case .closeAfter: return Shortcut.titles[.closeAfter]!
        case .hidden: return "Hidden Here"
        case .inspector: return "Developer Tools"
        case .console: return "JavaScript Console"
        case .boostStore: return "Store"
        case .newBoost: return "New Boost…"
        case .customizeSite: return "Customize Site…"
        case .customizationOn: return "Turn On Customization"
        case .customizationOff: return "Turn Off Customization"
        case .arcBoosts: return "Bring Boosts from Arc"
        case .extensions: return "Site Controls"
        case .welcome: return "Welcome"
        case .look: return "Edit Look"
        case .feedback: return "Send Feedback"
        case .invite: return "Invite a Friend…"
        case .wrapped: return "Yab Wrapped"
        case .checkUpdates: return "Check for Updates"
        case .restartUpdate: return "Restart to Update"
        case .makeDefault: return "Make Yab the Default Browser"
        case .splitView: return "Split View"
        case .separate: return "Separate Split View"
        case .showBar: return "Show Address Bar"
        case .devModeOn: return "Turn On Developer Mode"
        case .devModeOff: return "Turn Off Developer Mode"
        case .hideSiteButtons: return "Hide Agent Buttons on This Site"
        case .showSiteButtons: return "Show Agent Buttons on This Site"
        case .aiOff: return "Turn Off AI"
        case .aiOn: return "Turn On AI"
        case .aiWhenAsked: return "AI Only When Asked"
        case .hideAIRows: return "Hide AI Rows in Field"
        case .showAIRows: return "Show AI Rows in Field"
        case .jsonText: return "Show JSON as Text"
        case .jsonTree: return "Show JSON as Tree"
        case .copyJSON: return "Copy JSON"
        case .saveJSON: return "Save JSON\u{2026}"
        case .fillSign: return "Fill & Sign"
        case .expandJSON: return "Expand All"
        case .jsonSetting: return "Show JSON as"
        case .hideBar: return "Hide Address Bar"
        case .showShelf: return "Show Bookmarks Bar"
        case .hideShelf: return "Hide Bookmarks Bar"
        case .showSidebar: return "Show Sidebar"
        case .hideSidebar: return "Hide Sidebar"
        case .showStrip: return "Show Tab Bar"
        case .hideStrip: return "Hide Tab Bar"
        case .newYork: return "New York: Tabs Down the Side"
        case .sanFrancisco: return "San Francisco: Tabs Across the Top"
        default: return MenuCommands.entries[self]!.title
        }
    }

    /// A window keeps the layout it is already using even after another
    /// window changes the shared preference. Palette labels follow that
    /// window, while the global title still supplies catalog search words.
    @MainActor
    func title(in browser: Browser) -> String {
        if MenuCommands.everyone.contains(self) || browser.prefs.menuCommands, let words = MenuCommands.contextTitle(self, in: browser) { return words }
        switch self {
        case .closeBefore: return Shortcut.titles(sidebar: browser.prefs.sidebar)[.closeBefore]!
        case .closeAfter: return Shortcut.titles(sidebar: browser.prefs.sidebar)[.closeAfter]!
        case .mail: return browser.inMail ? "Back to Your Tabs" : "Open Mail"
        // As the picked tabs' menu says it.
        case .folderWithTabs:
            let count = browser.chosen.filter(\.keepable).count
            return count == 1 ? "New Folder with Tab" : "New Folder with \(count) Tabs"
        // The folder it goes into, by name.
        case .newTabInFolder:
            guard let name = browser.folderHere?.name, !name.isEmpty else { return title }
            return "New Tab in \(name)"
        default: return title
        }
    }

    /// Changes how the window looks, and nothing else: harmless to do by
    /// mistake and undone the same way. Return may take one, but only
    /// when the words begin its name or one of `phrases`, never on a word
    /// that merely appears in it, so "bar" or "top" and Return still search.
    var arranges: Bool {
        switch self {
        case .showBar, .hideBar, .showShelf, .hideShelf, .showSidebar, .hideSidebar, .showStrip, .hideStrip, .newYork, .sanFrancisco: return true
        default: return false
        }
    }

    /// What people call it when they go looking for it, in other browsers'
    /// words and by the layouts' names. Typing the start of
    /// any of these names it as surely as its title does.
    private var phrases: [String] {
        switch self {
        case .customizeSite: return ["customize", "customize site", "customize…", "site appearance", "edit site look", "boost editor"]
        case .customizationOn: return ["enable customization", "turn on customization", "customization", "site customization"]
        case .customizationOff: return ["disable customization", "turn off customization", "customization", "site customization"]
        case .pasteAndMatchStyle: return ["paste without formatting", "paste plain text", "plain paste", "match style"]
        case .aiOff: return ["disable ai", "ai off", "no ai", "turn ai off", "hide ai", "turn off apple intelligence"]
        case .aiOn: return ["enable ai", "ai on", "turn ai on"]
        case .aiWhenAsked: return ["ai when asked", "when asked", "ai only when i ask"]
        case .hideAIRows: return ["hide ai rows", "hide ask and task", "hide ask rows", "remove ask and task"]
        case .showAIRows: return ["show ai rows", "show ask and task", "show ask rows"]
        case .importYabPasswords: return ["import passwords", "import Yab passwords", "import to Apple Passwords", "importpasswords"]
        case .closeBefore:
            return ["close tabs to the left", "close tabs above", "close before", "close left", "close above"]
        case .closeAfter:
            return ["close tabs to the right", "close tabs below", "close after", "close right", "close below"]
        case .showBar:
            return ["address bar", "url bar", "location bar", "top bar", "toolbar", "show url", "show bar", "show top bar", "show toolbar"]
        case .hideBar:
            return ["address bar", "url bar", "location bar", "top bar", "toolbar", "hide url", "hide bar", "hide top bar", "hide toolbar", "remove address bar", "no address bar"]
        case .showShelf:
            return ["bookmarks bar", "favorites bar", "show bookmarks bar", "show favorites"]
        case .hideShelf:
            return ["bookmarks bar", "favorites bar", "hide bookmarks bar", "hide favorites"]
        case .showSidebar:
            return ["sidebar", "side bar", "open sidebar", "show tabs", "expand sidebar"]
        case .hideSidebar:
            return ["sidebar", "side bar", "close sidebar", "collapse sidebar", "hide tabs"]
        case .showStrip:
            return ["tab bar", "tab strip", "show tab bar", "show tabs"]
        case .hideStrip:
            return ["tab bar", "tab strip", "hide tab bar", "hide tabs", "auto-hide tabs"]
        case .newYork:
            return ["new york", "ny", "nyc", "vertical tabs", "tabs down the side", "tabs on the side", "tabs on the left", "side tabs", "tabs in a sidebar", "sidebar", "side bar", "layout"]
        case .sanFrancisco:
            return ["san francisco", "sf", "horizontal tabs", "tabs across the top", "tabs on top", "tabs at the top", "tab bar", "tabs in a row", "layout"]
        default:
            return []
        }
    }

    func namedExactly(_ words: String) -> Bool {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ([title] + phrases).contains { $0.lowercased() == text }
    }

    /// Other names for it, the ones other browsers taught people, which
    /// name it as surely as its title does, so
    /// "incognito" and Return is a private tab.
    private var names: String {
        switch self {
        case .newWindow: return "normal window regular window"
        case .privateTab: return "incognito"
        case .blankWindow: return "new blank window"
        case .bookmarks: return "favorites"
        case .passwords: return "keychain"
        case .mail: return "inbox gmail email open mail"
        case .autofill: return "autofill wallet"
        case .bringCards: return "import cards import addresses"
        case .settings: return "preferences prefs"
        case .manual: return "manual help guide documentation"
        case .reader: return "reader"
        case .floatVideo: return "pip"
        case .capture: return "screenshot"
        case .reload: return "refresh"
        case .hardReload: return "hard refresh"
        case .clearCookies: return "clear cookies"
        case .actualSize: return "reset zoom"
        case .hidden: return "unhide what you hid here restore"
        case .inspector: return "devtools web inspector"
        case .devModeOn, .devModeOff: return "dev mode site localhost developer"
        case .hideSiteButtons, .showSiteButtons: return "button buttons claude chatgpt agent reply do it handle annoying off stop offering never"
        case .aiOff, .aiOn, .aiWhenAsked: return "ai apple intelligence claude chatgpt model disable enable switch"
        case .hideAIRows, .showAIRows: return "ai ask task rows fallback field"
        case .console: return "devtools"
        case .boostStore: return "store boosts plugins customize websites"
        case .newBoost: return "boost create make customize css style restyle"
        case .customizeSite: return "customize site boost editor css color font appearance"
        case .customizationOn: return "enable site customization boost colors fonts"
        case .customizationOff: return "disable site customization original boost colors fonts"
        case .arcBoosts: return "arc boosts import"
        case .extensions: return "extensions add-ons addons"
        case .makeDefault: return "default browser"
        case .splitView: return "side by side"
        case .separate: return "unsplit"
        default: return MenuCommands.entries[self]?.aliases.joined(separator: " ") ?? ""
        }
    }

    /// Words that only point at it: enough to list it, under the places,
    /// but never enough for Return to take it over a search.
    private var words: String {
        switch self {
        case .newWindow: return "normal regular browsing open"
        case .newTab: return "blank open empty"
        case .mail: return "messages letters gmail inbox"
        case .privateTab: return "shy secret window"
        case .blankWindow: return "empty window apart tabs of its own"
        case .reopen: return "undo closed restore back"
        case .history: return "visited recent past pages"
        case .downloads: return "files saved"
        case .bookmarks: return "saved"
        case .passwords: return "logins sign-ins passkeys"
        case .autofill: return "credit debit payment shipping billing"
        case .bringCards: return "chrome arc dia safari brave edge wallet"
        case .settings: return "options"
        case .manual: return "features how to use product learn tutorial"
        case .bookmarkPage: return "add save favorite star"
        case .reader: return "article read"
        case .darkPage: return "dark night theme invert black"
        case .find: return "search text page"
        case .print: return "pdf paper"
        case .capture: return "snapshot picture image frame portrait"
        case .duplicate: return "copy tab clone"
        case .copyAddress: return "url link"
        case .copyMarkdownLink: return "url link title md"
        case .pasteAndMatchStyle: return "clipboard text formatting plain paste"
        case .floatVideo: return "picture in picture video"
        case .hide: return "block element remove"
        case .closeTab: return "shut"
        case .reload: return "again page"
        case .hardReload: return "cache refresh reload force"
        case .clearCookies: return "cookies site data sign out"
        case .zoomIn: return "bigger larger text size magnify"
        case .zoomOut: return "smaller text size"
        case .actualSize: return "zoom normal size 100"
        case .pinTab: return "keep stick"
        case .unpinTab: return "loose"
        case .newFolder: return "group tabs kept"
        case .folderWithTabs: return "group selected picked tabs selection kept"
        case .newTabInFolder: return "inside folder add open blank"
        case .pullRequestsFolder: return "github pr prs live folder review"
        case .closeOthers: return "tabs rest all tidy"
        case .closeBefore: return "tabs before left above tidy"
        case .closeAfter: return "tabs after right below tidy"
        case .hidden: return "hide elements removed blocked show"
        case .inspector: return "inspect develop html css"
        case .console: return "js log errors develop"
        case .boostStore: return "boosts and plugins for your sites"
        case .newBoost: return "boost make create change how a site looks works css javascript style zap"
        case .arcBoosts: return "boosts import bring arc move switch"
        case .extensions: return "plugins puzzle site settings permissions"
        case .welcome: return "intro introduction onboarding tour start again"
        case .look: return "color colour theme gradient grain transparency drawings doodles pattern wallpaper backdrop appearance space"
        case .feedback: return "bug report problem idea contact write support suggest suggestion broken"
        case .invite: return "invite friend friends share gift send link best friend charm"
        case .wrapped: return "wrapped recap stats time saved arcade high score"
        case .checkUpdates: return "update version new release upgrade"
        case .restartUpdate: return "update relaunch new version install"
        case .makeDefault: return "links open default"
        case .splitView: return "two tabs panes pane columns half halves"
        case .separate: return "split two tabs panes close half"
        case .showBar: return "address bar url toolbar top site domain link back forward show"
        case .devModeOn, .devModeOff: return "site server port errors network console measure"
        case .hideSiteButtons, .showSiteButtons: return "beside messages and threads, in the site's own row"
        case .aiOff, .aiOn, .aiWhenAsked: return "settings off on background tidy summaries"
        case .hideAIRows, .showAIRows: return "turn off on tab asks commands"
        case .jsonText, .jsonTree, .jsonSetting: return "json tree text pretty print formatter viewer api response"
        case .copyJSON: return "json copy clipboard"
        case .saveJSON: return "json save download file"
        case .fillSign: return "pdf sign signature fill form contract document initials date"
        case .expandJSON: return "json expand unfold open tree"
        case .hideBar: return "address bar url toolbar top site domain link back forward hide"
        case .showShelf: return "bookmarks bar favorites row top show"
        case .hideShelf: return "bookmarks bar favorites row top hide"
        case .showSidebar: return "sidebar column tabs panel show"
        case .hideSidebar: return "sidebar column tabs panel hide"
        case .showStrip: return "tab bar strip tabs top row show"
        case .hideStrip: return "tab bar strip tabs top row hide"
        case .newYork: return "layout tabs sidebar vertical side left york"
        case .sanFrancisco: return "layout tabs horizontal top row francisco"
        default: return ""
        }
    }

    /// All from the app's own set (see Glyphs), so every mark in the list
    /// is the same line at the same size.
    /// The color of a command that opens a feature, the one Settings gives
    /// that feature's page; nil for the rest, which sit in the gray well.
    var tint: NSColor? {
        switch self {
        case .history: return SettingsPage.history.tint
        // Downloads' own color, kept from when it had a page in Settings.
        case .downloads: return .systemTeal
        case .passwords: return SettingsPage.passwords.tint
        case .autofill, .bringCards: return SettingsPage.autofill.tint
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .newWindow: return "yab.window.plus"
        case .newTab: return "yab.tab.plus"
        case .mail: return "yab.mail"
        case .privateTab: return "incognito"
        case .blankWindow: return "yab.window"
        case .reopen: return "yab.tab.undo"
        case .history: return "yab.clock"
        case .downloads: return "yab.download"
        case .bookmarks: return "bookmark"
        case .bookmarkPage: return "yab.bookmark.plus"
        case .passwords: return "key"
        case .importYabPasswords: return "key"
        case .autofill: return "yab.card"
        case .bringCards: return "yab.card.dl"
        case .settings: return "yab.gear"
        case .manual: return "yab.book"
        case .reader: return "yab.bookopen"
        case .darkPage: return "moon"
        case .find: return "yab.page.search"
        case .print: return "yab.printer"
        case .capture: return "camera"
        case .duplicate: return "yab.tabs.plus"
        case .copyAddress: return "link"
        case .copyMarkdownLink: return "markdown"
        case .pasteAndMatchStyle: return "doc.on.clipboard"
        case .floatVideo: return "pip"
        case .hide: return "rectangle.dashed"
        case .closeTab: return "yab.tab.x"
        case .reload: return "yab.reload"
        case .hardReload: return "yab.reload.bolt"
        case .restartUpdate: return "yab.reload.up"
        case .clearCookies: return "cookie"
        case .zoomIn: return "yab.zoomin"
        case .zoomOut: return "yab.zoomout"
        case .actualSize: return "magnifyingglass"
        case .pinTab: return "pin"
        case .unpinTab: return "pin.slash"
        case .newFolder: return "yab.folder.plus"
        case .folderWithTabs, .pullRequestsFolder: return "folder.badge.plus"
        case .newTabInFolder: return "plus.tab"
        case .closeOthers: return "yab.tabs.x"
        case .closeBefore: return "arrow.left"
        case .closeAfter: return "yab.tabs.down"
        case .hidden: return "yab.element.slash"
        case .inspector: return "yab.code"
        case .console: return "yab.terminal"
        case .boostStore: return "storefront"
        case .newBoost, .arcBoosts: return "wand.and.stars"
        case .customizeSite, .customizationOn, .customizationOff: return "paintbrush"
        case .extensions: return "slider.horizontal.2.square"
        case .welcome: return "yab.spark"
        case .look: return "paintpalette"
        case .feedback: return "yab.heartchat"
        case .invite: return "brand.blobplus"
        case .wrapped: return "yab.game"
        case .checkUpdates: return "clock.arrow.circlepath"
        case .makeDefault: return "yab.globe.check"
        case .splitView: return "yab.split.plus"
        case .separate: return "yab.split.slash"
        case .showBar, .hideBar: return "address.bar"
        case .devModeOn, .devModeOff: return "chevron.left.forwardslash.chevron.right"
        case .hideSiteButtons, .showSiteButtons: return "sparkles"
        case .aiOff: return "yab.sparkles.slash"
        case .hideAIRows: return "yab.sparkles.minus"
        case .aiOn, .aiWhenAsked, .showAIRows: return "sparkles"
        case .jsonText, .jsonTree, .expandJSON, .jsonSetting: return "curlybraces"
        case .copyJSON: return "yab.copyframe.code"
        case .saveJSON: return "yab.doc.dl"
        case .fillSign: return "signature"
        case .showShelf, .hideShelf: return "bookmark"
        case .showSidebar, .hideSidebar: return "yab.sidebar"
        case .newYork: return "sidebar.left"
        case .showStrip, .hideStrip, .sanFrancisco: return "rectangle.split.3x1"
        default: return MenuCommands.entries[self]!.symbol
        }
    }

    /// The shortcut, so the field teaches it while it does it: as it is now,
    /// if App Shortcuts gave its menu item other keys (Hotkeys).
    var keys: String {
        MainActor.assumeIsolated {
            if let action = MenuCommands.entries[self]?.shortcut { return Keymap.shared.text(action) }
            if let action = MenuCommands.legacyKeys[self] { return Keymap.shared.text(action) }
            if let action = FieldPlace.of(self)?.shortcut { return Keymap.shared.text(action) }
            if shortcutAction == nil { return Keymap.shared.keys(for: self)?.text ?? "" }
            switch self {
            case .newWindow: return Keymap.shared.text(.newWindow)
            case .pasteAndMatchStyle:
                guard let key = Keymap.shared.keys(.pasteAndMatchStyle), PasteStyleMenuOrder.permits(key, in: NSApp.mainMenu) else { return "" }
                return key.text
            case .closeBefore: return Keymap.shared.keys(.closeBefore)?.text ?? ""
            case .closeAfter: return Keymap.shared.keys(.closeAfter)?.text ?? ""
            case .mail: return Keymap.shared.keys(.mail)?.text ?? ""
            case .folderWithTabs: return Keymap.shared.keys(.folderWithTabs)?.text ?? ""
            case .blankWindow: return Keymap.shared.keys(.blankWindow)?.text ?? ""
            case .newTabInFolder: return Keymap.shared.keys(.newTabInFolder)?.text ?? ""
            case .devModeOn, .devModeOff: return Keymap.shared.keys(.devMode)?.text ?? ""
            case .bookmarkPage: return Keymap.shared.keys(.bookmark)?.text ?? ""
            case .feedback: return Keymap.shared.keys(.sendFeedback)?.text ?? ""
            default: return Hotkeys.shared.keys(default: defaultKeys)
            }
        }
    }

    private var defaultKeys: String {
        switch self {
        case .newWindow: return "⌘N"
        case .newTab: return "⌘T"
        case .mail: return "⇧⌘I"
        case .privateTab: return "⇧⌘N"
        case .reopen: return "⇧⌘T"
        case .history: return "⌘Y"
        case .downloads: return "⇧⌘J"
        case .bookmarks: return "⌥⌘B"
        case .passwords: return "⌥⌘L"
        case .settings: return "⌘,"
        case .bookmarkPage: return ""
        case .reader: return "⌥⌘R"
        case .darkPage: return "⌥⇧D"
        case .find: return "⌘F"
        case .print: return "⌘P"
        case .capture: return "⇧⌘2"
        case .duplicate: return ""
        case .copyAddress: return "⇧⌘C"
        case .copyMarkdownLink: return "⌥⇧⌘C"
        case .pasteAndMatchStyle: return "⌥⇧⌘V"
        case .floatVideo: return "⇧⌘P"
        case .hide: return "⇧⌘H"
        case .closeTab: return "⌘W"
        case .reload: return "⌘R"
        case .hardReload: return "⇧⌘R"
        case .clearCookies: return ""
        case .zoomIn: return "⌘+"
        case .zoomOut: return "⌘-"
        case .actualSize: return "⌘0"
        case .hidden: return ""
        case .inspector: return "⌥⌘I"
        case .console: return "⌥⌘J"
        case .boostStore, .newBoost, .arcBoosts: return ""
        case .extensions: return "⌘E"
        case .pinTab, .unpinTab: return ""
        case .closeOthers: return "⌥⌘W"
        case .folderWithTabs: return "⌃⌘N"
        case .newTabInFolder: return "⌥⌘T"
        case .closeBefore, .closeAfter: return ""
        case .splitView, .separate: return "⌃⌘\\"
        case .showBar, .hideBar: return "⇧⌘D"
        case .manual, .feedback, .invite, .wrapped, .autofill, .bringCards, .welcome, .look, .newFolder, .pullRequestsFolder,
             .checkUpdates, .restartUpdate, .makeDefault: return ""
        case .showShelf, .hideShelf: return "⇧⌘B"
        case .devModeOn, .devModeOff: return "⌃D"
        case .hideSiteButtons, .showSiteButtons: return ""
        case .aiOff, .aiOn, .aiWhenAsked, .hideAIRows, .showAIRows: return ""
        case .jsonText, .jsonTree, .copyJSON, .jsonSetting: return ""
        case .saveJSON: return "⌘S"
        case .fillSign: return ""
        case .expandJSON: return "⌥→"
        case .showSidebar, .hideSidebar, .showStrip, .hideStrip: return "⌘S"
        case .newYork, .sanFrancisco: return "⇧⌘S"
        default: return ""
        }
    }

    /// Whether Return may do this when the words name it. Only what opens
    /// something, a tab, a panel, and nothing that acts on the page: "pr"
    /// and Return should never print it, or close it, or copy from it.
    var opens: Bool {
        switch self {
        case .customizeSite, .boostStore, .newBoost, .arcBoosts, .newWindow, .newTab, .privateTab, .blankWindow, .reopen, .history, .downloads, .bookmarks, .passwords, .autofill, .bringCards, .settings, .manual, .feedback, .invite, .wrapped, .splitView, .mail, .jsonSetting:
            return true
        // Only its picking starts: nothing is taken until a click, and esc
        // leaves it.
        case .capture:
            return true
        case _ where arranges:
            return true
        default:
            return MenuCommands.entries[self]?.opens ?? false
        }
    }

    @MainActor func opens(in browser: Browser) -> Bool {
        opens || (browser.prefs.menuCommands && (self == .devModeOn || self == .devModeOff))
    }

    /// Only what makes sense from here: nothing that acts on a page while
    /// there is no page under the field.
    @MainActor
    func available(in browser: Browser) -> Bool {
        if let entry = MenuCommands.entries[self] {
            guard MenuCommands.everyone.contains(self) || browser.prefs.menuCommands else { return false }
            // These routes belong to the browser window. A field raised by a
            // small window must not silently act on the main window's page.
            guard browser.fieldGuest == nil || MenuCommands.global.contains(self) else { return false }
            return entry.available(browser)
        }
        let page = browser.active.map { !$0.isBlank } ?? false
        switch self {
        case .pasteAndMatchStyle: return browser.query.pasteStyleTarget.canPaste(restoring: true)
        case .importYabPasswords: return browser.passwordImportRoute.available
        case .customizeSite: return browser.fieldGuest == nil && browser.active.map { !$0.shy && BoostEditorLook.host($0.address) != nil } == true
        case .customizationOn, .customizationOff:
            guard browser.fieldGuest == nil, let tab = browser.active, !tab.shy, let host = BoostEditorLook.host(tab.address) else { return false }
            let look = BoostEditorLooks.shared.look(host: host, profile: AddonProfiles.of(tab))
            return look.changed && (self == .customizationOff ? look.enabled : !look.enabled)
        case .duplicate, .copyAddress, .copyMarkdownLink:
            return (browser.fieldGuest ?? browser.active).map { !$0.isBlank } ?? false
        case .bookmarkPage, .reader, .find, .print, .capture, .floatVideo, .hide,
             .reload, .hardReload, .clearCookies, .zoomIn, .zoomOut, .actualSize, .inspector, .console:
            return page
        case .closeTab:
            // The same Close Tab action closes an empty normal/private window.
            return browser.fieldGuest == nil && (page || browser.closesWindowOnCloseTab)
        case .hidden: return page && !browser.hereVeils.isEmpty
        case .darkPage: return browser.darkPageReady() != nil
        case .mail: return browser.prefs.usesMail && (MailCenter.shared.connected || browser.inMail)
        case .pinTab:
            if let pair = browser.pair(of: browser.activeID) { return browser.canPinPair(pair) }
            return page && browser.active?.pin == nil
        case .unpinTab: return browser.active?.pin != nil
        case .folderWithTabs: return browser.chosen.contains(where: \.keepable)
        case .newTabInFolder: return browser.folderHere != nil
        case .closeOthers: return browser.tabs.count > 1
        case .closeBefore: return !browser.sideCloseTargets(browser.chosen, before: true).isEmpty
        case .closeAfter: return !browser.sideCloseTargets(browser.chosen, before: false).isEmpty
        // Offered only where there is a feed to look in, and only while
        // nothing is on its way; once a new one is in, the restart it waits for.
        case .checkUpdates:
            guard Updater.enabled, !Updater.shared.checking else { return false }
            if case .none = Updater.shared.stage { return true }
            return false
        case .restartUpdate:
            if case .ready = Updater.shared.stage { return true }
            return false
        case .makeDefault: return !Links.isDefault
        // Only while a moment is due (the 100th day, the year), not at will.
        case .wrapped: return Wrapped.shared.due != nil
        case .newTab:
            guard browser.fieldGuest == nil else { return false }
            if browser.tabs.isEmpty { return true }
            // Offered over a page, including a private page. New Tab keeps
            // the window's privacy; New Window opens normal browsing.
            guard let tab = browser.active else { return false }
            // ⌘T's own field is already that.
            return (!tab.isBlank && !browser.fresh) || tab.shy
        case .showBar: return !browser.prefs.addressBar
        case .devModeOn: return browser.canToggleDevMode && browser.active?.isDev != true
        case .devModeOff: return browser.active?.isDev == true
        case .hideSiteButtons: return SiteItems.shared.showing(on: browser.active) == true
        case .showSiteButtons: return SiteItems.shared.showing(on: browser.active) == false
        case .aiOff: return browser.prefs.aiUse != .off
        case .aiOn: return browser.prefs.aiUse != .on
        case .aiWhenAsked: return browser.prefs.aiUse != .asked
        // Only where the rows would show: AI on (When Asked and Off have none).
        case .hideAIRows: return browser.prefs.aiUse == .on && !browser.prefs.aiRowsHidden
        case .showAIRows: return browser.prefs.aiRowsHidden
        // Only on a JSON page; the setting from anywhere.
        case .jsonText: return browser.jsonFront?.json?.shown == .tree
        case .jsonTree: return browser.jsonFront.map { $0.json?.shown != .tree && $0.json?.ndjson == false } ?? false
        case .copyJSON, .saveJSON: return browser.jsonFront != nil
        case .fillSign: return browser.active?.paper.pdf == true && browser.active?.paper.desk == nil
        case .expandJSON: return browser.jsonFront?.json?.shown == .tree && browser.jsonFront?.json?.ndjson == false
        case .hideBar: return browser.prefs.addressBar
        case .showShelf: return browser.prefs.bookmarkBar != .always
        case .hideShelf: return browser.prefs.bookmarkBar == .always
        // In full screen the column is only ever out for a while over the
        // page: it can be brought out, never put away.
        case .showSidebar: return browser.prefs.sidebar && browser.prefs.sideShut
        case .hideSidebar: return browser.prefs.sidebar && !browser.prefs.sideShut
        case .showStrip: return browser.stripAway
        case .hideStrip: return !browser.prefs.sidebar && !browser.prefs.stripShut
        case .newYork: return !browser.prefs.sidebar
        case .sanFrancisco: return browser.prefs.sidebar
        // From a new tab, beside the page it was opened from; from a page,
        // a new tab beside it. Never a third.
        case .splitView:
            guard let tab = browser.active, browser.pair(of: tab.id) == nil, browser.splitFits else { return false }
            return !tab.isBlank || browser.splitNeighbor != nil
        case .separate: return browser.pair(of: browser.activeID) != nil
        case .arcBoosts: return ArcBoosts.available
        default:
            return true
        }
    }

    @MainActor
    func run(in browser: Browser) {
        guard available(in: browser) else { return }
        switch self {
        case .pasteAndMatchStyle: browser.query.pasteStyleTarget.perform(restoring: true)
        case .newWindow: browser.newWindow()
        case .newTab:
            if browser.tabs.isEmpty { browser.pressNewTab() } else { browser.newTab() }
        case .mail: browser.toggleMail()
        case .privateTab: browser.newPrivateWindow()
        case .blankWindow: browser.newBlankWindow()
        case .reopen: browser.reopen()
        // The box's own places, gone into where the command was typed.
        case .history: browser.openPlace(.history)
        case .downloads: browser.openPlace(.downloads)
        case .bookmarks: browser.showBookmarks()
        case .passwords: browser.openPlace(.passwords)
        case .importYabPasswords: browser.passwordImportRoute.run()
        case .autofill: browser.openPlace(.autofill)
        // After the field has gone, as History's recall is: the place
        // comes up in a field of its own.
        case .bringCards:
            DispatchQueue.main.async {
                browser.openPlace(.autofill)
                browser.bringMore()
            }
        case .settings: browser.tuning = true
        case .manual: browser.open(Guide.manualURL, foreground: true)
        case .bookmarkPage: browser.bookmarkCurrent()
        case .reader: browser.toggleReader()
        case .darkPage: browser.toggleDarkPage()
        case .find: browser.openFind()
        case .print: browser.printPage()
        // After the field has gone, so the page is what is picked from.
        case .capture: DispatchQueue.main.async { browser.capture.start() }
        case .duplicate: browser.several ? browser.duplicate(browser.chosen) : browser.duplicate()
        case .copyAddress: browser.copyAddress()
        case .copyMarkdownLink: browser.copyMarkdownLink()
        case .floatVideo: browser.toggleFloat()
        case .hide: browser.toggleHiding()
        case .closeTab:
            if browser.closesWindowOnCloseTab { browser.shut([]) }
            else if let tab = browser.active { browser.shut(tab) }
        case .reload: browser.reload()
        case .hardReload: browser.hardReload()
        case .clearCookies: browser.clearCookiesAndRefresh()
        case .zoomIn: browser.zoom(by: 1.1)
        case .zoomOut: browser.zoom(by: 1 / 1.1)
        case .actualSize: browser.resetZoom()
        case .pinTab: browser.pinActive()
        case .unpinTab: browser.unpinActive()
        case .newFolder: browser.newEmptyFolder()
        case .folderWithTabs: browser.newFolder(picked: browser.chosen)
        case .newTabInFolder: browser.newTab(in: browser.folderHere)
        case .pullRequestsFolder: LiveFolders.shared.make("github.pulls", in: browser)
        case .closeOthers: if let tab = browser.active { browser.closeOthers(but: [tab]) }
        case .closeBefore: browser.closeBefore()
        case .closeAfter: browser.closeAfter()
        case .hidden:
            SiteControlsState.shared.hiddenOpen = true
            browser.toggleExtensions()
        case .inspector: browser.developerTools()
        case .console: browser.showConsole()
        case .boostStore: browser.openPlace(.store)
        case .newBoost: browser.newBoost()
        case .customizeSite: BoostEditor.shared.show(browser)
        case .customizationOn, .customizationOff:
            if available(in: browser) { BoostEditor.shared.toggle(in: browser) }
        case .arcBoosts: ArcBoosts.offer(in: browser)
        case .extensions: browser.toggleExtensions()
        case .welcome:
            browser.welcoming = true
            LaunchArrival.shared.replay(browser)
        case .look: LookCard.shared.show(browser)
        case .feedback: Links.writeFeedback()
        case .invite: browser.openSettings(.inviteFriends)
        case .wrapped: Wrapped.shared.show(in: browser)
        // Up to date is said, since nothing else on screen would; a new one
        // is the note written in by the Update button once it is in (UpdateDoodle).
        case .checkUpdates:
            Updater.shared.check { found in
                if found == nil { browser.announce("Yab is up to date", mark: "checkmark.circle") }
            }
        case .restartUpdate: Updater.shared.relaunch()
        case .makeDefault: Links.becomeDefault { _ in }
        case .splitView: browser.splitView()
        case .separate: browser.separate()
        case .showBar: browser.prefs.addressBar = true
        case .devModeOn, .devModeOff: browser.toggleDevMode()
        case .hideSiteButtons, .showSiteButtons: SiteItems.shared.toggle(on: browser.active, from: browser)
        case .aiOff, .aiOn, .aiWhenAsked: browser.useAI(self == .aiOff ? .off : self == .aiOn ? .on : .asked)
        case .hideAIRows, .showAIRows: browser.hideAIRows(self == .hideAIRows)
        case .jsonText: browser.showJSON(.text)
        case .jsonTree: browser.showJSON(.tree)
        case .copyJSON: browser.copyJSON()
        case .saveJSON: browser.saveJSON()
        case .fillSign: browser.fillSign()
        case .expandJSON: browser.expandJSON()
        case .jsonSetting: browser.openSettings(.developers)
        case .hideBar: browser.prefs.addressBar = false
        case .showShelf, .hideShelf: browser.toggleBookmarkBar()
        case .showSidebar, .hideSidebar: browser.toggleColumn()
        case .showStrip, .hideStrip: browser.toggleStrip()
        case .newYork, .sanFrancisco: browser.toggleSidebar()
        default: MenuCommands.entries[self]?.run(browser)
        }
    }

    /// Full feature names outrank web results without treating a partial
    /// action name as permission to run it on Return.
    static func normalizedName(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    var searchNames: [String] {
        var aliases = MenuCommands.entries[self]?.aliases ?? []
        switch self {
        case .devModeOn: aliases += ["developer mode", "dev mode", "turn on dev mode", "enable developer mode"]
        case .devModeOff: aliases += ["developer mode", "dev mode", "turn off dev mode", "disable developer mode"]
        case .reload: aliases += ["refresh"]
        case .hardReload: aliases += ["hard refresh", "force refresh"]
        case .newTab: aliases += ["newtab"]
        case .closeTab: aliases += ["archive tab", "closetab"]
        case .reader: aliases += ["reader"]
        case .floatVideo: aliases += ["picture in picture", "pip"]
        case .extensions: aliases += ["extensions", "manage extensions"]
        case .inspector: aliases += ["devtools", "web inspector", "elements", "open elements panel"]
        case .console: aliases += ["console", "open console panel"]
        case .capture: aliases += ["screenshot", "capture page", "capture"]
        case .makeDefault: aliases += ["make yab default browser"]
        case .downloads: aliases += ["search downloads"]
        case .history: aliases += ["search history"]
        case .bookmarks: aliases += ["show bookmarks"]
        case .newYork: aliases += ["show tabs in sidebar"]
        case .pullRequestsFolder: aliases += ["new github pull requests folder", "github pull requests", "github pull requests folder", "new pull requests folder"]
        default: break
        }
        return [title] + aliases + phrases
    }

    func matchesExactly(_ text: String) -> Bool {
        let typed = Self.normalizedName(text)
        return !typed.isEmpty && Self.exactNames[self]?.contains(typed) == true
    }

    @MainActor func matchesExactly(_ text: String, in browser: Browser) -> Bool {
        guard expanded(in: browser) || [.customizeSite, .customizationOn, .customizationOff, .importYabPasswords,
                                        .aiOff, .aiOn, .aiWhenAsked, .hideAIRows, .showAIRows].contains(self) else { return false }
        if matchesExactly(text) { return true }
        switch self {
        case .sleepTabs, .keepTab, .releaseTab, .muteTab, .unmuteTab, .moveToFolder, .moveToSpace,
             .resetPinnedTab, .replacePinnedURL, .editPinnedURL, .folderWithTabs, .newTabInFolder, .mail,
             .closeBefore, .closeAfter:
            return Self.normalizedName(title(in: browser)) == Self.normalizedName(text)
        default: return false
        }
    }

    @MainActor func score(_ text: String, in browser: Browser) -> Double? {
        if matchesExactly(text, in: browser) { return 4 }
        return score(text, expanded: expanded(in: browser))
    }

    /// Exact names and the fuller wording: the half everyone has, and the
    /// whole catalog once the experiment is on.
    @MainActor private func expanded(in browser: Browser) -> Bool {
        browser.prefs.menuCommands || MenuCommands.everyone.contains(self) || ChatProjectCommands.commands.contains(self)
    }

    private static let exactNames: [Command: Set<String>] = Dictionary(uniqueKeysWithValues:
        allCases.map { ($0, Set($0.searchNames.map(normalizedName))) })

    /// How well the words typed name this: 3 when they begin its title,
    /// 2.5 when every one begins a word of the title or another name for it,
    /// 1 when they only reach it through a word that points at it.
    func score(_ needle: String, expanded: Bool = true) -> Double? {
        let typed = needle.trimmingCharacters(in: .whitespaces).lowercased()
        if expanded, matchesExactly(needle) { return 4 }
        // Begun far enough to be meant: five letters, or the whole of a
        // short one, "sf", "ny". "top" is the start of "top bar", and of a
        // great many searches.
        func begun(_ name: String) -> Bool {
            name.hasPrefix(typed) && typed.count >= min(5, name.count)
        }
        if arranges, typed.count >= 2, phrases.contains(where: begun) || begun(title.lowercased()) { return 3 }
        // Asked for in so many words, "report bug": into its second word
        // it is meant, though "bug" alone still searches.
        if typed.contains(" "), asks.contains(where: { $0.hasPrefix(typed) }) { return 3 }
        // Anything less only lists it, under the places, where Return
        // won't take it, and only through its own words, not any word of
        // its name: "new tab" is not New York.
        return (expanded ? Self.prepared[self] : Self.legacyPrepared[self])?.score(needle)
    }

    /// Whole asks that name it outright once typed into their second word,
    /// where each word alone only points at it.
    private var asks: [String] {
        switch self {
        case .feedback:
            return ["report bug", "report a bug", "report a problem", "report problem", "report an issue", "report issue",
                    "bug report", "file a bug", "send a bug", "contact support"]
        default:
            return []
        }
    }

    /// Each command's name and words, lowercased and split once: the field
    /// scores every command at every key, and splitting each one's words
    /// again then was most of what a key cost it (docs/main-thread-budget.md).
    private static let prepared: [Command: Wording.Prepared] = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.prepare()) })
    private static let legacyPrepared: [Command: Wording.Prepared] = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.prepare(expanded: false)) })

    private func prepare(expanded: Bool = true) -> Wording.Prepared {
        let titles = expanded ? searchNames.joined(separator: " ") + " " + names : title + " " + names + " " + phrases.joined(separator: " ")
        return arranges ? Wording.Prepared(title: "", words: words) : Wording.Prepared(title: titles, words: words)
    }

    /// The same, worked out from the words each time, for tests.
    func scoreUnprepared(_ needle: String) -> Double? {
        let typed = needle.trimmingCharacters(in: .whitespaces).lowercased()
        if matchesExactly(needle) { return 4 }
        func begun(_ name: String) -> Bool {
            name.hasPrefix(typed) && typed.count >= min(5, name.count)
        }
        if arranges, typed.count >= 2, phrases.contains(where: begun) || begun(title.lowercased()) { return 3 }
        // Asked for in so many words, "report bug": into its second word
        // it is meant, though "bug" alone still searches.
        if typed.contains(" "), asks.contains(where: { $0.hasPrefix(typed) }) { return 3 }
        if arranges { return Wording.score(needle, title: "", words: words) }
        return Wording.score(needle, title: searchNames.joined(separator: " ") + " " + names, words: words)
    }
}

/// Matching by the starts of words, which is how a name is typed: "priv"
/// finds New Private Tab, "tab" finds all of them, and "a" finds nothing,
/// because a letter inside a word is not something anybody types to mean it.
enum Wording {
    static func score(_ needle: String, title: String, words: String) -> Double? {
        Prepared(title: title, words: words).score(needle)
    }

    static func split(_ text: String) -> [Substring] {
        text.split { !$0.isLetter && !$0.isNumber }
    }

    /// A title and its words as `score` reads them, split once.
    struct Prepared {
        let name: String
        let named: [Substring]
        let all: [Substring]

        init(title: String, words: String) {
            name = title.lowercased()
            named = Wording.split(name)
            all = named + Wording.split(words.lowercased())
        }

        /// 3 when the words begin the title, 2.5 when each begins a word of
        /// it, 1 when each begins a word of the title or the other words.
        func score(_ needle: String) -> Double? {
            let needle = needle.trimmingCharacters(in: .whitespaces).lowercased()
            guard needle.count >= 2 else { return nil }
            if name.hasPrefix(needle) { return 3 }
            let tokens = needle.split(whereSeparator: \.isWhitespace)
            if tokens.allSatisfy({ t in named.contains { $0.hasPrefix(t) } }) { return 2.5 }
            if tokens.allSatisfy({ t in all.contains { $0.hasPrefix(t) } }) { return 1 }
            return nil
        }
    }
}
