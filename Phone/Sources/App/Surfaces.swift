import Foundation
import Observation

/// Which surfaces stand over the page, and the calls that summon them. The
/// chrome, the field and the chats call these; each layer
/// (FieldLayer, ChatsLayer, SettingsLayer) reads its own part
/// and draws itself. One place says what is open, so two surfaces never
/// fight over the screen.
@MainActor
@Observable
final class Surfaces {
    // MARK: - the field

    enum FieldMode: Sendable, Equatable {
        /// The plate's field: about this page, the address selected (⌘L).
        case address
        /// New Tab: Now, Recent Tabs, Frequent (⌘T).
        case newTab
    }

    /// The field over the keyboard, and what it is for; nil when closed.
    var field: FieldMode? {
        didSet { if oldValue != nil, field == nil { fieldDidClose?() } }
    }
    /// Where the field grows from, in screen points: the plate, +. Nil grows
    /// it from the plate.
    var fieldOrigin: CGRect?

    func openField(_ mode: FieldMode, from origin: CGRect? = nil, keepingMenu: Bool = false) {
        // The page menu morphing into the field stays until it has (PageMenuModel).
        if !keepingMenu { menu = nil }
        fieldOrigin = origin
        fieldWillOpen?(mode)
        fieldOpenings &+= 1
        field = mode
    }
    /// Counts the field's openings, so a choice made in one opening is
    /// told apart from a later one (FieldActions.afterFieldCloses).
    private(set) var fieldOpenings = 0

    func closeField() { field = nil }

    /// Told before the field opens, inside the same change: the field branch
    /// sets its words and draft (Field/FieldModel) before anything is drawn.
    @ObservationIgnored var fieldWillOpen: ((FieldMode) -> Void)?
    /// Told as the field goes, by whatever took the screen from it.
    @ObservationIgnored var fieldDidClose: (() -> Void)?
    /// The field, closed, still flying back onto the plate: the plate waits
    /// under it until it lands.
    var fieldLanding = false

    // MARK: - answers and chats

    enum ChatRoute: Sendable, Equatable {
        /// An answer to words typed in the field, about this page or not.
        case answer(question: String, aboutPage: Bool)
        /// A chat, open at full height.
        case chat(Chat.ID)
        /// A task's chat: its steps, its tabs, its result.
        case task(TaskRun.ID)
        /// A new chat, ideas for the page in front over its field.
        case newChat
    }

    /// The chat sheet and what it shows; nil when it is down.
    var chat: ChatRoute?
    /// Where it grows from: the Now line, the island, a row, ✎.
    var chatOrigin: CGRect?

    func openChat(_ route: ChatRoute, from origin: CGRect? = nil) {
        field = nil
        menu = nil
        chatOrigin = origin
        chatPage = nil
        chat = route
    }

    func closeChat() { chat = nil }

    /// The page an answer is about when it isn't the tab in front: a page
    /// asked about before it is a tab. Nil: the tab in front.
    var chatPage: Tab?

    /// An answer or a chat about a page that isn't a tab 
    func openChat(_ route: ChatRoute, from origin: CGRect? = nil, about page: Tab?) {
        openChat(route, from: origin)
        chatPage = page
    }

    /// The chats layer draws the Now line while it holds a hidden answer or
    /// chat (the sheet folds into it, a flick lets it go); the chrome's own
    /// line steps aside for it.
    var parkedLineLent = false

    // MARK: - settings

    var settings = false

    /// Settings, a plain sheet from below, whatever opened it (the spaces'
    /// gear, the word in the field): nothing grows out of `origin`, which is
    /// kept for callers that still pass one.
    /// `keepingField`: Settings over the spaces it was opened from, which are
    /// there again when it closes.
    func openSettings(from origin: CGRect? = nil, keepingField: Bool = false) {
        if !keepingField { field = nil }
        menu = nil
        settings = true
    }

    func closeSettings() { settings = false }

    // MARK: - joining a Mac

    /// The join sheet (Settings/SettingsLayer, JoinSheet, with sync's
    /// Join/JoinContent in it): from the welcome's Join Your Mac and
    /// Settings' Sync row (AppModel.openJoin), or sync itself while this
    /// iPhone has no key (SyncBridge.showsJoin is this). Where it grows from,
    /// in screen points.
    var join = false
    var joinOrigin: CGRect?

    func openJoin(from origin: CGRect? = nil) {
        joinOrigin = origin
        join = true
    }

    func closeJoin() { join = false }

    // MARK: - menus

    enum Menu: Sendable, Equatable {
        /// Holding the plate.
        case plate
        /// Holding a chat row, or ⋯ in a chat.
        case chat(Chat.ID)
    }

    var menu: Menu?

    func openMenu(_ menu: Menu) { self.menu = menu }
    func closeMenu() { menu = nil }

    // MARK: - the toast

    struct Toast: Equatable, Sendable {
        /// Under the status bar, or at the bottom over the plate (the page
        /// menu's Copy Link, where the finger just was).
        enum Place: Equatable, Sendable { case top, bottom }
        var id = UUID()
        var text: String
        var glyph: GlyphName
        var place: Place = .top
        /// It offers Undo (a closed tab back): the plate takes that one touch.
        var undoable = false
    }

    /// The one corner plate, said only when nothing on screen answers.
    private(set) var toast: Toast?
    /// Frozen states keep their toast for the screenshot.
    var toastsStay = false
    private var toastTimer: Task<Void, Never>?
    /// What the toast's Undo does, while that toast is up.
    @ObservationIgnored private var toastUndo: (() -> Void)?

    func showToast(_ text: String, glyph: GlyphName, place: Toast.Place = .top, shows: TimeInterval = Metrics.Toast.shows,
                   undo: (() -> Void)? = nil) {
        let toast = Toast(text: text, glyph: glyph, place: place, undoable: undo != nil)
        self.toast = toast
        toastUndo = undo
        toastTimer?.cancel()
        guard !toastsStay else { return }
        toastTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(shows))
            guard !Task.isCancelled, let self, self.toast?.id == toast.id else { return }
            self.toastUndo = nil
            Motion.toastOut.run { self.toast = nil }
        }
    }

    /// The toast's Undo, once: what it offered happens and the toast goes.
    func undoToast(_ id: UUID) {
        guard toast?.id == id, let undo = toastUndo else { return }
        toastUndo = nil
        toastTimer?.cancel()
        Motion.toastOut.run { self.toast = nil }
        undo()
    }

    func hideToast() { toast = nil; toastUndo = nil }

    // MARK: - paging tabs on the plate

    /// Whoever pages tabs with a swipe across the plate (the tabs branch, M2).
    @ObservationIgnored weak var paging: PlatePaging?
    /// The swipe in progress: how far the pages have gone and who is beside
    /// the tab (Paging/PageSwipe); the page, its neighbors and the plate's
    /// label follow it. Nil when nothing pages.
    var pageSwipe: PageSwipe? { didSet { syncPageSwipeFlags() } }
    /// Whether a swipe is in progress, and whether it is the one past the last
    /// tab. Views that only ask this read these, not `pageSwipe`: its offset
    /// changes every frame, and whoever reads it is drawn again every frame.
    private(set) var pageSwiping = false
    private(set) var pageSwipePastLast = false

    private func syncPageSwipeFlags() {
        let on = pageSwipe != nil, last = pageSwipe?.newTab == true
        if pageSwiping != on { pageSwiping = on }
        if pageSwipePastLast != last { pageSwipePastLast = last }
    }

    // MARK: - the page behind

    /// How far the page steps back behind a sheet, 0 to 1: smaller, its
    /// corners round, darker. The chat sheet sets it as it moves.
    var recede: CGFloat = 0
    /// The scrim's darkness over the page.
    var scrim: Double = 0

    /// The chrome's opacity while a sheet rises over it.
    var chromeOpacity: Double = 1

    /// The field takes the plate's place: the chrome and the Now line give way.
    var coversChrome: Bool { (field != nil && !fieldBeside) || fieldLanding }
    /// An unfolded Duo's spaces stand in a column beside the page: the page
    /// keeps its Back, its plate and its stack.
    var fieldBeside = false

    /// A surface over the whole screen (the welcome) says how the status
    /// bar's words go over it: light (true) or dark; nil follows the page.
    var statusBarLight: Bool?
}
