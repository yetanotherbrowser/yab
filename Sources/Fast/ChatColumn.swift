import AppKit
import Combine
import SwiftUI
import SyncKit
import UniformTypeIdentifiers

// A chat in full, in a column on the right of the window: the chat of the
// tab in front, or the one pinned there. The ⌘J field stays for the
// quick; Expand hands its chat over here, and a task's is here too. The
// column is the window's, as the sidebar is, and comes and goes the way
// the errors sheet does (DevRoom): the page held, the column and the
// page's new outline moved on one curve, WebKit given the width the page
// shows along the way.

enum ChatLook {
    /// As Messages (iOS 26, measured 2026-10-11): the bubbles near the
    /// column's edge, 12 in, their tails hanging under their corners; the
    /// field and what stands over it (the choices, a page's ideas) deeper,
    /// 20 in, as Messages' field stands in from its bubbles.
    static let turnsInset: CGFloat = 12
    static let fieldInset: CGFloat = 20
    /// The column's width now: the window's, as dragged (Browser.chatWidth),
    /// less in a room too narrow for it (fit).
    @MainActor static var width: CGFloat { fit(dragged) }
    /// As dragged, whatever the room.
    @MainActor static var dragged: CGFloat = stored
    /// The most the room leaves it, the page keeping 400 as it does beside
    /// the developer tools (DevLook.pageBeside); measured as the window
    /// lays the room out (ContentView).
    @MainActor static var widest: CGFloat = .infinity
    static let normal: CGFloat = 380
    static let least: CGFloat = 320
    static let most: CGFloat = 620

    /// `width` in this room: never wider than it leaves, nor under 320.
    @MainActor static func fit(_ width: CGFloat) -> CGFloat { max(least, min(width, widest)) }

    /// The width it was last left at, or the usual one.
    static var stored: CGFloat {
        let kept = Store.settings.double(forKey: "chat.width")
        return kept > 0 ? min(most, max(least, kept)) : normal
    }
}

extension Browser {
    /// The chat's column is on the window's left: the tabs' column is on
    /// the right, and the two stand on either side of the page.
    var chatLeads: Bool { flank == .right }

    /// A question about what is on screen belongs to Peek while it is up.
    var chatPage: Tab? { peekFront.page ?? active }

    /// Peek pages are alive outside the tab row until kept or closed.
    func chatTab(_ id: Tab.ID) -> Tab? {
        tabs.first { $0.id == id } ?? outside.first { $0.id == id }
    }
}

/// The page, and the column when it is out, in from the card's edges, the
/// page taking what is left.
struct ChatRoom: Layout {
    var open: Bool
    var rim: DevRoom.Rim
    var width: CGFloat
    /// The column on the left of the page (Browser.chatLeads).
    var leading = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let page = subviews.first else { return }
        guard subviews.count > 1 else {
            page.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let pageRect = pageFrame(in: bounds)
        let column = CGRect(x: leading ? bounds.minX + rim.inset : bounds.maxX - rim.inset - width, y: bounds.minY + rim.inset,
                            width: width, height: bounds.height - 2 * rim.inset)
        page.place(at: pageRect.origin, proposal: ProposedViewSize(pageRect.size))
        subviews[1].place(at: column.origin, proposal: ProposedViewSize(column.size))
    }

    func pageFrame(in bounds: CGRect) -> CGRect {
        var pageRect = bounds
        if open {
            pageRect.size.width = max(240, bounds.width - ChatRoom.room(rim, width: width))
            if leading { pageRect.origin.x = bounds.maxX - pageRect.width }
        }
        return pageRect
    }

    /// What the column takes from the page.
    static func room(_ rim: DevRoom.Rim, width: CGFloat) -> CGFloat { width + rim.gap + rim.inset }
}

// MARK: - its edge

/// The column's edge, in the air between it and the page: nothing drawn at
/// rest, under the pointer the resize cursor and a short grip, as a split's
/// divider (SplitDivider). Dragged, the page is held and takes its new width
/// once, when the edge is let go; a double click puts it back at 380.
struct ChatEdge: View {
    let browser: Browser
    @State private var hovering = false
    @State private var held = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(Palette.ink.opacity(held ? 0.5 : 0.28))
                .frame(width: 3, height: 28)
                .opacity(hovering || held ? 1 : 0)
                .animation(Motion.quick, value: hovering || held)
            EdgeHandle(
                changed: { travel in
                    if !held {
                        held = true
                        browser.chatGrabbed = ChatLook.width
                        browser.chatSizing = true
                    }
                    let wanted = (browser.chatGrabbed ?? browser.chatWidth) + (browser.chatLeads ? travel : -travel)
                    // Within what the room allows, so what is kept is
                    // what was seen.
                    browser.chatWidth = ChatLook.fit(min(ChatLook.most, wanted.rounded()))
                },
                ended: { _, _ in
                    held = false
                    browser.settleChatWidth()
                },
                doubled: {
                    browser.chatWidth = ChatLook.normal
                    browser.settleChatWidth()
                },
                hover: { hovering = $0 }
            )
        }
        .frame(width: Backdrop.inset)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - the window's column

extension Browser {
    /// The chat the column shows: the pinned one, the tab in front's, or
    /// the last one handed over.
    var chatID: String? { chatID(using: .shared) }

    /// The same selection for the column and its manual Delete dispatch.
    /// An isolated agent collection can exercise that route in a fixture.
    func chatID(using agents: Agents) -> String? {
        if chatFresh { return nil }
        return chatPinned ?? chatOfTab(active, agents: agents) ?? chatShown
    }

    /// The edge let go: the width kept, and the page given it, a frame on.
    func settleChatWidth() {
        chatGrabbed = nil
        Store.settings.set(Double(chatWidth), forKey: "chat.width")
        DispatchQueue.main.async { [self] in
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { chatSizing = false }
        }
    }

    /// The field at the foot, empty, for a chat of its own.
    func newChat() {
        panelExtension = nil
        chatPinned = nil
        // Fresh before the list goes, as keepChat does: the column trades
        // the list for the new chat, not for the one before it.
        chatFresh = true
        // On its own, unless New Chat was asked in a project (newChat(in:)).
        chatNewProject = nil
        chatHistory = false
        chatFocus += 1
    }

    /// A project of chats in the column, in the list's place.
    func openProject(_ id: String?) {
        guard id == nil || chatProjects.project(id) != nil else { return }
        chatProjectInfo = false
        chatProject = id
        if !chatHistory { chatHistory = true }
        moveChat(open: true)
    }

    /// The field for a new chat in a project, its pill on it.
    func newChat(in project: String) {
        guard let chosen = chatProjects.project(project), chosen.archived != true else { return }
        newChat()
        chatNewProject = chosen.id
        moveChat(open: true)
    }

    /// A chat begun or picked here: the column keeps it.
    func keepChat(_ id: String) {
        chatFresh = false
        // The chat first, the list away after: the column trades screens
        // as the list goes, and with this order it trades for this chat,
        // not the one before for a few frames and this one after.
        chatShown = id
        chatPinned = id
        // Back from it is its project, if it is in one, else the chats.
        let project = Projects.shared.project(Chats.shared.chat(id)?.project ?? Agents.shared.session(id)?.project)?.id
        if chatProject != project { chatProject = project }
        chatProjectInfo = false
        chatHistory = false
    }

    /// The existing manual Delete actions share one dispatch. Only a
    /// window showing this conversation closes; lists, panels and another
    /// chat keep their current target. Never stop or evict its task.
    @discardableResult
    func deleteChat(_ id: String, chats: Chats? = nil, agents: Agents? = nil,
                    windows: [Browser]? = nil) -> Bool {
        let agents = agents ?? .shared
        // Confirmation is asynchronous: a formerly finished task may now
        // be working again. The same stop-first rule still applies.
        guard agents.session(id)?.state.live != true else { return false }
        var seen = Set<ObjectIdentifier>()
        for browser in windows ?? ([self] + BrowserWindows.shared.browsers) {
            guard seen.insert(ObjectIdentifier(browser)).inserted else { continue }
            // Nothing of its field is kept once it has gone.
            browser.chatAttach.forget(id)
            guard browser.panelExtension == nil, !browser.chatHistory,
                  browser.chatOpen || browser.chatMovement.target == true,
                  browser.chatID(using: agents) == id else { continue }
            let followsTab = browser.chatOfTab(browser.active, agents: agents) == id
            browser.hideChat()
            if browser.chatPinned == id { browser.chatPinned = nil }
            if browser.chatShown == id { browser.chatShown = nil }
            // Otherwise the active tab's retained, completed session would
            // select the deleted conversation again when the column opens.
            if followsTab { browser.chatFresh = true }
        }
        (chats ?? .shared).remove(id)
        return true
    }

    /// The chat a tab belongs to: the task it works for, or whose answer it is.
    func chatOfTab(_ tab: Tab?, agents: Agents? = nil) -> String? {
        guard let tab, let id = tab.worker ?? tab.answering ?? tab.began else { return nil }
        let agents = agents ?? .shared
        let root = agents.root(of: id)
        return agents.hasChat(root) ? root : nil
    }

    /// The agent a new chat here goes to: the one picked in the column
    /// (ChatModelLine), else the Tasks default's, as ChatComposer sends it.
    var chatChoice: ModelChoice {
        if let chatNext { return chatNext }
        let pick = ModelDefaults.shared.pickNow(.chats)
        return ModelChoice(cli: pick.cli, model: pick.model, effort: pick.effort)
    }
    var chatAgent: String { chatChoice.cli ?? Agents.preferred }
    /// Its plan, as words about a new chat say it: "Remix with ChatGPT".
    var chatName: String { AgentSetupModel.name(chatAgent) }

    /// Asking about a page in the column (⌘J, Settings › AI › Agents): the
    /// page's own chat if it has one, the field ready for what comes next;
    /// else a new chat about it, whatever the column showed, the page given,
    /// with what was selected, or all the task line held and its words.
    func askInChat(about tab: Tab, selection: String? = nil, words: String = "", context: [TaskContext] = []) {
        guard AIUse.offers else { return }
        PageWords.warm(tab)
        if selection == nil, context.isEmpty, words.isEmpty, let own = chatOfTab(tab),
           (Agents.shared.session(own)?.cli ?? Chats.shared.chat(own)?.cli) == chatAgent {
            showChat(own)
            chatFocus += 1
            return
        }
        // A private tab gives nothing of its own: not the page, not what is
        // selected on it (ChatComposer.page).
        let given = context.isEmpty
            ? (tab.shy ? [] : [TaskContext.page(tab)] + (selection.map { [TaskContext.selection($0)] } ?? []))
            : context.filter { item in item.tab.map { id in chatTab(id)?.shy != true } ?? true }
        for item in given { if let tab = item.tab.flatMap(chatTab) { PageWords.warm(tab) } }
        // The new chat first: the words below are its draft (chatDraft).
        newChat()
        chatAttach.set(given.compactMap { item -> ChatAttachment? in
            switch item.kind {
            case .page, .tab: return item.tab.map(ChatAttachment.tab)
            case .selection: return item.text.map(ChatAttachment.quote)
            case .file: return item.url.map(ChatAttachment.file)
            case .mail: return item.mail.map(ChatAttachment.mail)
            case .item: return item.text.map(ChatAttachment.quote)
            }
        })
        if !words.isEmpty { chatDraft = words }
        moveChat(open: true)
    }

    /// Chat with Folder, a folder's right-click: a new chat about every tab
    /// in it, as Dia's Chat with Group.
    func chatWith(_ nest: Nest) {
        ChatAttachment.warm(nest, in: self)
        newChat()
        chatAttach.set([.folder(nest.id)])
        moveChat(open: true)
        chatFocus += 1
    }

    /// ⌘J pressed again: the column goes away when the keys are in its
    /// field, where ⌘J leaves them, or while it is still coming out.
    var askClosesChat: Bool {
        guard chatMovement.target ?? chatOpen else { return false }
        return chatAttach.typing || (chatMoving && chatMovement.target == true)
    }

    /// The menu command or column controls put the chat out or away.
    func toggleChat() {
        if chatMovement.target ?? chatOpen { hideChat() }
        // AI off, or no agent and no chat yet: nothing for the column to show.
        else if AIUse.chats || panelExtension != nil { moveChat(open: true) }
    }

    /// Hide Chat, its key and the menu's: the column away, whatever it
    /// shows. An extension's panel in it is closed too, once the column
    /// has gone, so it slides out with the panel in it, not the chat.
    func hideChat() {
        guard chatOpen else {
            // The model can already be closed while its presentation remains.
            // Keep that attempted close in the same trace as the × button.
            moveChat(open: false)
            return
        }
        let panel = panelExtension.map { ($0, panelTabID, panelContextID) }
        moveChat(open: false)
        guard let (id, tabID, contextID) = panel else { return }
        let generation = chatMovement.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.chatOpen, self.chatMovement.generation == generation else { return }
            for owner in Extensions.all where owner.panelPages(in: self).contains(where: { $0.contextID == contextID }) {
                owner.closePanel(id, in: self, tabID: tabID, contextID: contextID)
            }
            ChromiumSidePanel.shared.closePanel(contextID: contextID)
        }
    }

    /// A chat into the column, the column out if it isn't.
    func showChat(_ id: String?) {
        panelExtension = nil
        if id != nil { chatFresh = false; chatHistory = false }
        if let id {
            let root = Agents.shared.root(of: id)
            chatShown = root
            // The tab in front with a chat of its own would win over the
            // one asked for (chatID): held, as a chat picked from the list
            // is, until you go to a tab with a chat of its own.
            if let own = chatOfTab(active), own != root { chatPinned = root }
            else if chatPinned != nil, chatPinned != root { chatPinned = nil }
        }
        moveChat(open: true)
    }

    /// As ⌘S moves the tabs' column: the page held first, in a pass of
    /// its own, the column built there, unseen; then the window laid out
    /// once, where everything ends up, with no animation round it, and the
    /// page's outline and the column drawn there from where they were by
    /// Core Animation on one curve (Reshape, ChatColumnView); WebKit follows
    /// the width shown along the way and is let go after they arrive.
    /// Open requests reach this coordinator even while a queued close
    /// still has the model open; it owns the latest intent, not that frame.
    func moveChat(open: Bool) {
        if !open { FeedbackDiagnostics.shared.chatClose(.intent, open: chatOpen, moving: chatMoving) }
        let move: Int
        switch chatMovement.request(open: open, current: chatOpen, moving: chatMoving) {
        case .unchanged:
            if !open { chatColumnView?.slide(shown: false) }
            if !open, !chatOpen, chatRestoration != nil || chatAttach.typing { restoreAfterChat() }
            if !open { FeedbackDiagnostics.shared.chatClose(.skipped, open: chatOpen, moving: chatMoving) }
            return
        case .cancelled:
            chatColumnView?.slide(shown: open)
            chatMoving = false
            if open {
                // The superseded opening completion can no longer give
                // the field its keys. Finish that handoff on the reversal.
                chatFocus += 1
            } else {
                if chatAttach.typing { restoreAfterChat() }
                else { chatRestoration = nil }
            }
            Reshape.pace = .reshape
            if !open { FeedbackDiagnostics.shared.chatClose(.completed, open: chatOpen, moving: chatMoving) }
            return
        case .move(let generation):
            move = generation
        }
        if open, chatRestoration == nil {
            chatRestoration = ChatRestoration(in: chatColumnView?.window ?? BrowserWindows.shared.window(for: self),
                                              page: chatPage?.id, field: fieldShowing)
        }
        let pace: Reshape.Pace = open ? .arrive : .depart
        chatMoving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [self] in
            guard chatMovement.isCurrent(move) else { return }
            Reshape.pace = pace
            let asked = CACurrentMediaTime()
            StageView.mark("chat-change", ["open": open])
            // Like Split's model writes, this must reach Observation
            // outside an explicit transaction. SwiftUI can lay out from
            // willSet inside one, reading the old chatOpen and retaining
            // its old page width while the native host slides to the new
            // state. Core Animation owns the motion, not this write.
            chatOpen = open
            chatColumnView?.slide(shown: open)
            if !open {
                chatAttach.menu = false
                chatAttach.typing = false
                chatAttach.finishableChatID = nil
            }
            if !open { FeedbackDiagnostics.shared.chatClose(.applied, open: chatOpen, moving: chatMoving) }
            // Counted from when Core Animation was handed the curves, in
            // the pass this lays out, not from now: on a busy Mac, or with
            // the window's glass, that pass came a fifth of a second later,
            // past the curve's own length, and the page was let go before
            // it, at its new width in one frame (feedback #89). So until
            // that pass has come it is waited for (Reshape.landed).
            DispatchQueue.main.async { [self] in
                guard chatMovement.isCurrent(move) else { return }
                if !open { restoreAfterChat() }
                Reshape.landed(after: asked, pace: pace) { [self] in
                    guard chatMovement.isCurrent(move), chatMoving else {
                        if !open { FeedbackDiagnostics.shared.chatClose(.superseded, open: chatOpen, moving: chatMoving) }
                        return
                    }
                    StageView.mark("chat-arrived")
                    chatMovement.complete(move)
                    chatMoving = false
                    if !open { FeedbackDiagnostics.shared.chatClose(.completed, open: chatOpen, moving: chatMoving) }
                    Reshape.pace = .reshape
                    // Out: the cursor in its field, to say something at once.
                    if open { chatFocus += 1 }
                }
            }
        }
    }

    private func restoreAfterChat() {
        let saved = chatRestoration
        let borrowed = saved != nil || chatAttach.typing
        chatRestoration = nil
        chatAttach.menu = false
        chatAttach.typing = false
        chatAttach.finishableChatID = nil
        guard borrowed else { return }
        let window = chatColumnView?.window ?? BrowserWindows.shared.window(for: self)
        if let current = window?.firstResponder as? NSView, let column = chatColumnView {
            let control = (current as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : nil } ?? current
            if control.window === window, !control.isDescendant(of: column) { return }
        }
        if saved?.restore(in: window, page: chatPage?.id, field: fieldShowing) == true { return }
        if fieldShowing { askFocus() }
        else if editingTab == nil, !finding, let page = chatPage?.builtPage, let window = page.window {
            window.makeFirstResponder(page)
        }
    }
}

// MARK: - moved by Core Animation

/// The column in a hosting view of its own, laid out once where it ends
/// up and brought in or taken away by Core Animation, as the tabs' column
/// is (ColumnView). Faded and slid by SwiftUI, every frame of the motion
/// laid the window out again on the main thread, the page's room with it,
/// 4 to 7 ms a frame on a 120 Hz screen, and any frame's commit could wait
/// on the window server. Now the motion is one commit, and the render
/// server draws it.
///
/// Wider than the column by the air on its left, where its edge is
/// dragged (ChatEdge).
struct ChatColumnHost: NSViewRepresentable {
    let browser: Browser
    /// Out, or on its way away: see `ChatColumnView.slide`.
    let shown: Bool
    let corner: CGFloat
    let width: CGFloat
    /// On the window's left (Browser.chatLeads). Read off the browser in
    /// update, a change of side alone left the column dressed for the old
    /// one, its air on the wrong side, as nothing told SwiftUI to update it.
    let leading: Bool

    func makeNSView(context: Context) -> ChatColumnView {
        ChatColumnView(browser: browser, corner: corner, width: width)
    }

    /// As big as it is placed: asked of AppKit, the hosting view inside
    /// would measure the whole column in every pass of the window's.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatColumnView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ view: ChatColumnView, context: Context) {
        view.dress(corner: corner, width: width, leading: leading)
        // An update queued before a close must not reopen the native host.
        view.slide(shown: browser.chatOpen)
    }

    static func dismantleNSView(_ view: ChatColumnView, coordinator: ()) {
        if view.browser?.chatColumnView === view { view.browser?.chatColumnView = nil }
        view.feed.leave()
        // Let go of a turn later: its hosting view's teardown, in the pass
        // that also gives the page its new width, made one long one.
        DispatchQueue.main.async { withExtendedLifetime(view) {} }
    }
}

/// What the column's own hosting view is told by the window's.
@MainActor
final class ChatColumnLook: ObservableObject {
    @Published var corner: CGFloat
    @Published var width: CGFloat
    /// On the window's left (Browser.chatLeads).
    @Published var leading: Bool

    init(corner: CGFloat, width: CGFloat, leading: Bool) {
        self.corner = corner
        self.width = width
        self.leading = leading
    }
}

private struct ChatColumnRoot: View {
    let browser: Browser
    @ObservedObject var look: ChatColumnLook
    let feed: ChatFeed
    @ObservedObject private var here = ExtensionsHere.shared
    @ObservedObject private var chromiumPanels = ChromiumSidePanel.shared

    var body: some View {
        ZStack {
            ChatColumn(browser: browser, corner: look.corner, width: look.width, feed: feed)
                .modifier(ChatColumnScheme(browser: browser))
                .opacity(browser.panelExtension == nil ? 1 : 0)
                .allowsHitTesting(browser.panelExtension == nil)
            // Every sign-in's panels in this window: one stays open as the
            // window goes to a space of another (ExtensionSignIns).
            ForEach(Extensions.all.flatMap { $0.panelPages(in: browser) }, id: \.contextID) { page in
                ExtensionSidePanelColumn(browser: browser, page: page, corner: look.corner, width: look.width)
                    .opacity(browser.panelExtension == page.id && browser.panelContextID == page.contextID ? 1 : 0)
                    .allowsHitTesting(browser.panelExtension == page.id && browser.panelContextID == page.contextID)
            }
            if #available(macOS 15.4, *) {
                ForEach(chromiumPanels.panels(in: browser)) { panel in
                    ChromiumSidePanelColumn(browser: browser, panel: panel, width: look.width)
                        .opacity(browser.panelExtension == panel.extensionID && browser.panelContextID == panel.contextID ? 1 : 0)
                        .allowsHitTesting(browser.panelExtension == panel.extensionID && browser.panelContextID == panel.contextID)
                }
            }
        }
            .padding(look.leading ? .trailing : .leading, Backdrop.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: look.leading ? .leading : .trailing)
            // A hosting view of its own is told the title bar's height as
            // safe area: with the tabs in the sidebar the column's top is
            // under the title bar, and it came down from the page's top.
            .ignoresSafeArea()
    }
}

final class ChatColumnView: NSView {
    weak var browser: Browser?
    let feed: ChatFeed
    private let look: ChatColumnLook
    private let host: Host
    /// For `bench pace`: how often the column's hosting view was laid
    /// out, and how long its first layout, the column built, took.
    static var layouts = 0
    static var built: Double = 0

    private final class Host: NSHostingView<ChatColumnRoot> {
        private var first = true
        override func layout() {
            ChatColumnView.layouts += 1
            guard first, window != nil else { return super.layout() }
            first = false
            let start = CACurrentMediaTime()
            super.layout()
            ChatColumnView.built = (CACurrentMediaTime() - start) * 1000
        }
    }
    /// Out, as last told; nil before the first telling.
    private var out: Bool?

    /// The native host can still be drawn while the model says closed.
    var shown: Bool {
        out == true || (host.layer?.presentation()?.opacity ?? host.layer?.opacity ?? 0) > 0
    }

    init(browser: Browser, corner: CGFloat, width: CGFloat) {
        self.browser = browser
        // Its chat before its first drawing: told only on appearing, it
        // was drawn first with none, a new chat's ideas asked for and
        // thrown away, and its field changed shape as the chat came.
        let feed = ChatFeed()
        feed.follow(browser.chatID)
        self.feed = feed
        look = ChatColumnLook(corner: corner, width: width, leading: browser.chatLeads)
        host = Host(rootView: ChatColumnRoot(browser: browser, look: look, feed: feed))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        host.autoresizingMask = [.width, .height]
        // Its size is the one it is given, never one it works out.
        host.sizingOptions = []
        addSubview(host)
        browser.chatColumnView = self
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    /// Only while it is out: on its way away the page's clicks go through.
    /// Slid with the page under the band with the lights (Reshape.slide).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Reshape.carriers.add(self) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        out == true ? super.hitTest(point) : nil
    }

    func dress(corner: CGFloat, width: CGFloat, leading: Bool) {
        if look.corner != corner { look.corner = corner }
        if look.width != width { look.width = width }
        if look.leading != leading { look.leading = leading }
    }

    /// In from past the window's edge and away past it again, as the tabs'
    /// column comes and goes (ColumnView.slide), on the page's arriving
    /// curve and the leaving one. Faded in from nothing, a little way, it
    /// came too suddenly. The model is where it ends up; the first telling
    /// stands as told. Told again on the way, it turns back from wherever
    /// it has got to.
    func slide(shown now: Bool) {
        guard let layer = host.layer else { return }
        guard now != out else {
            // A closed column must stay closed if the render server drops
            // its animations on wake or when this host is reattached.
            if !now {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.opacity = 0
                CATransaction.commit()
            }
            return
        }
        let was = out
        out = now
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let seen = layer.presentation()
        let fromOpacity = seen?.opacity ?? layer.opacity
        let moving = layer.animation(forKey: "chat.slide") != nil
        StageView.mark("chat-slide", ["out": now, "was": was.map { $0 ? 1 : 0 } ?? -1])
        let fromX = (seen?.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? 0
        let travel = (look.width + Backdrop.inset + ChatColumnView.beyond) * (look.leading ? -1 : 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "chat.slide")
        layer.removeAnimation(forKey: "chat.fade")
        // Hidden in the model when closed. A departing column stays drawn
        // only for its curve, never by a retained animation alone: losing
        // that animation used to reveal an inert column (705, 710).
        layer.opacity = now ? 1 : 0
        CATransaction.commit()
        guard let was else { return }
        let pace: Reshape.Pace = now ? .arrive : .depart
        guard !still else {
            // With less motion it fades, where it is.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = now ? 1 : 0
            fade.duration = pace.duration
            fade.timingFunction = pace.timing
            layer.add(fade, forKey: "chat.fade")
            return
        }
        if !now {
            let visible = CABasicAnimation(keyPath: "opacity")
            visible.fromValue = fromOpacity
            visible.toValue = fromOpacity
            visible.duration = pace.duration
            layer.add(visible, forKey: "chat.fade")
        }
        // Added to wherever AppKit puts it, so it holds however the pass
        // lays the column out; away, it stays where the motion leaves it
        // until it is taken out.
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.isAdditive = true
        // Not yet out, nor on its way: it comes from past the edge.
        move.fromValue = now && !was && !moving ? travel : fromX
        move.toValue = now ? 0 : travel
        move.duration = pace.duration
        move.timingFunction = pace.timing
        if !now {
            move.fillMode = .forwards
            move.isRemovedOnCompletion = false
        }
        layer.add(move, forKey: "chat.slide")
    }

    /// How far past the window's edge it starts and ends, its shadow too.
    static let beyond: CGFloat = 40
}

// MARK: - what it shows

/// The chat in the column, kept current: a live session looked at ten
/// times a second while it works (its words come a token at a time, and
/// nothing redraws for each), a kept one as the store has it. Published
/// only when something changed.
@MainActor
final class ChatFeed: ObservableObject {
    /// How many times the column's body was worked out, for `bench pace`.
    static var bodies = 0
    @Published private(set) var chat: Chat?
    @Published private(set) var live = false
    /// What the chat asks of itself, its mail (Agents.askChat): in the
    /// field's place while the column shows it.
    @Published private(set) var permit: AgentPermit?
    private(set) var id: String?
    private var timer: Timer?
    private var watching: AnyCancellable?
    private var mark = ""

    init() {
        // Something noted, a step, a state: looked at once, a beat later.
        watching = Agents.shared.objectWillChange.merge(with: Chats.shared.objectWillChange)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.look() } }
    }

    func follow(_ id: String?) {
        guard id != self.id else { return }
        self.id = id
        mark = ""
        look()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The column went away: what its chat asks goes back to the page.
    func leave() {
        stop()
        id = nil
        if Agents.shared.columnChat != nil { Agents.shared.columnChat = nil }
    }

    func look() {
        let session = Agents.shared.session(id)
        let isLive = session?.state.live == true
        if live != isLive { live = isLive }
        if permit != session?.permit { permit = session?.permit }
        if isLive, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.look() }
            }
        } else if !isLive {
            stop()
        }
        let now: String
        if let session {
            // Your words sent and not yet heard back count too: they stand in the chat at once.
            now = "\(session.id)|\(session.state.rawValue)|\(session.itemsRevision)|\(session.saying.count)|\(session.title ?? "")|\(Agents.shared.tabs(of: session).count)|\(session.project ?? "")"
        } else {
            let kept = Chats.shared.chat(id)
            // Its project too: a move into one changes nothing else, and
            // the head's "Lisbon Trip · model" and face badge wait on it.
            now = "\(id ?? "")|kept|\(kept?.updated.timeIntervalSince1970 ?? 0)|\(kept?.pinned == true)|\(kept?.project ?? "")"
        }
        guard now != mark else { return }
        mark = now
        chat = session.map { Agents.shared.chat(of: $0) } ?? Chats.shared.chat(id)
    }
}

// MARK: - the column

/// A screen of the column on its way in or out (ChatColumn.haze): blurred,
/// scaled a little toward or away from you, faded.
private struct Haze: ViewModifier {
    var depth: CGFloat = 1
    var blur: CGFloat = 0
    var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .scaleEffect(depth)
            .opacity(opacity)
    }
}

/// The column as the chat apps have it: its name and agent at the head,
/// the turns under it, and at the foot, always, the field, with what the
/// agent asks standing over it. With no chat yet, what the page in front
/// suggests stands over the field (ChatSuggestions). The chats kept are
/// drawn here; the chat itself in its own hosting view (ChatPane, on a
/// ChatZoomStage), so it can fly out of its card and back as one picture.
struct ChatColumn: View {
    let browser: Browser
    let corner: CGFloat
    /// Its width, as dragged by its edge.
    var width: CGFloat = ChatLook.normal
    /// Kept by the view it is hosted in (ChatColumnView), which lets it
    /// go when the column goes.
    @ObservedObject var feed: ChatFeed
    @ObservedObject private var chats = Chats.shared
    @ObservedObject private var agents = Agents.shared
    @ObservedObject private var projects = Projects.shared
    @ObservedObject private var banners = ChatBanners.shared
    /// The project shown in the list's place (Browser.chatProject).
    @State private var projectShown: String?
    /// New Project's sheet is up (Browser.chatProjectSheet).
    @State private var sheet = false
    /// The circles that morph from the list or the form into a project.
    @Namespace private var morph
    /// The chats kept, in the turns' place: the browser's, looked at here,
    /// as the column watches nothing else of it.
    @State private var history: Bool
    @State private var archive = false
    @State private var unreadOnly = false
    @State private var dropping = false
    @State private var dropShown = false
    @State private var tabOver = false
    /// No veil under the field, for weighing what the veil costs (evals/runway).
    static let plainFoot = ProcessInfo.processInfo.environment["YAB_PLAIN_FOOT"] == "1"
    /// The plain fade the chats and a chat traded places with before haze,
    /// for filming the two side by side (evals/chat-switch).
    static let oldTrade = ProcessInfo.processInfo.environment["YAB_CHAT_FADE"] == "1"
    /// The ⋯ menu over the head (ChatMoreMenu).
    @StateObject private var more = ChatMore()
    /// Which of the list and the chat is up, and a chat on its way between.
    @StateObject private var zoom: ChatZoom
    @Environment(\.accessibilityReduceMotion) private var still

    init(browser: Browser, corner: CGFloat, width: CGFloat = ChatLook.normal, feed: ChatFeed) {
        self.browser = browser
        self.corner = corner
        self.width = width
        _feed = ObservedObject(wrappedValue: feed)
        _history = State(initialValue: browser.chatHistory)
        _projectShown = State(initialValue: browser.chatProject)
        _zoom = StateObject(wrappedValue: ChatZoom(browser: browser, feed: feed, list: browser.chatHistory, width: width))
    }

    /// The turns and the chat's own screen trading places: what goes is
    /// gone at once, before what comes is there, so the two are never
    /// read through each other; what comes rises a little as it does.
    static let trade = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .offset(y: 12)).animation(Motion.chatIn.delay(0.08)),
        removal: .opacity.animation(Motion.leave)
    )

    /// The chats kept and a chat's turns trading places, as screens
    /// should: what goes is washed out in a strong blur within a few frames, so
    /// only what comes reads sharp. The chats sit behind (they go back a
    /// little as they go), the chat in front (it comes from a little nearer).
    /// What the browser says about the sheet and the open project, both at
    /// once, on the chat's own spring.
    private func settleProjects() {
        DispatchQueue.main.async {
            let sheetNow = browser.chatProjectSheet, now = browser.chatProject
            guard sheetNow != sheet || now != projectShown else { return }
            more.open = false
            withAnimation(still ? nil : Motion.chatIn) {
                sheet = sheetNow
                projectShown = now
            }
        }
    }

    static func haze(depth: CGFloat) -> AnyTransition {
        if oldTrade { return .opacity.combined(with: .offset(y: depth < 1 ? -6 : 6)) }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: Haze(depth: depth, blur: 8, opacity: 0), identity: Haze())
                .animation(Motion.chatIn.delay(0.05)),
            removal: .modifier(active: Haze(depth: depth, blur: 12, opacity: 0), identity: Haze())
                .animation(Motion.chatQuick)
        )
    }

    /// Archive asks first; once it is put away the column goes to the
    /// chats, where it no longer is. Unarchive needs no asking.
    static func putAway(_ chat: Chat, browser: Browser) {
        guard (Chats.shared.chat(chat.id) ?? chat).archived != true else {
            Chats.shared.archive(chat.id, false)
            return
        }
        ChatQuestions.archive(chat) {
            if browser.chatPinned == chat.id { browser.chatPinned = nil }
            Chats.shared.archive(chat.id, true)
            browser.chatHistory = true
        }
    }

    /// Files dropped go with the next message; a link to a tab that is open, that tab;
    /// a picture dragged off a page or out of Photos, kept as a file.
    static func take(_ providers: [NSItemProvider], chat: Chat?, browser: Browser) {
        for provider in providers {
            if !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let kind = [UTType.png, .jpeg, .heic, .gif, .webP, .tiff].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                _ = provider.loadDataRepresentation(for: kind) { data, _ in
                    guard let data, let url = ChatAttachment.keep(data, kind.preferredFilenameExtension ?? "png") else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            browser.chatAttach.add(files: [url], chat: chat, browser: browser)
                            browser.chatFocus += 1
                        }
                    }
                }
                continue
            }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let attach = browser.chatAttach
                        if url.isFileURL {
                            attach.add(files: [url], chat: chat, browser: browser)
                        } else if let tab = browser.tabs.first(where: { $0.address == url && !$0.shy }) {
                            attach.add(.tab(tab.id), chat: chat, browser: browser)
                        }
                        browser.chatFocus += 1
                    }
                }
            }
        }
    }

    /// To the list or to the chat, as the browser has it now.
    private func settleHistory() {
        let on = browser.chatHistory
        guard on != history else { return }
        more.open = false
        // The chat coming in is the one picked from its first frame: the
        // feed otherwise follows a run-loop turn later (relay.any below).
        if !on { feed.follow(browser.chatID) }
        history = on
        zoom.trade(toList: on)
    }

    var body: some View {
        let _ = ChatFeed.bodies += 1
        ZStack(alignment: .top) {
            if zoom.listShown {
                // The chats kept, under a chat: a chat picked flies out of
                // its card over them, and back into it.
                ZStack(alignment: .top) {
                    if let project = projects.project(projectShown) {
                        // A project of chats in the list's place, as a
                        // group chat in Messages (ChatProjectScreen).
                        ChatProjectScreen(browser: browser, project: project)
                            .transition(ChatColumn.haze(depth: 1.03))
                    } else {
                        ZStack(alignment: .top) {
                            // The whole height: the cards scroll up under the search
                            // and the head, into a veil (ChatHistory).
                            ChatHistory(browser: browser, archive: archive, unreadOnly: unreadOnly) { browser.chatHistory = false }
                            ChatHead(browser: browser, chat: nil, history: true, archive: archive, unreadOnly: unreadOnly, width: width, more: more)
                        }
                        .transition(ChatColumn.haze(depth: 0.97))
                    }
                }
                .zIndex(0)
            }
            if zoom.paneShown {
                ChatZoomStageView(browser: browser, feed: feed, zoom: zoom, more: more)
                    .zIndex(1)
            }
        }
        .coordinateSpace(.named(ChatCards.space))
        .environment(\.projectMorph, morph)
        // New Project, a screen of its own over the column, out of its
        // button as a new chat is out of the pencil; made, it turns into
        // the project where it stands (its circle morphs, ProjectMorph).
        .overlay {
            if sheet {
                ChatNewProjectSheet(browser: browser)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(still ? .opacity : .asymmetric(
                        insertion: .scale(scale: 0.12, anchor: UnitPoint(x: 0.8, y: 0.04)).combined(with: .opacity),
                        removal: .scale(scale: 0.94, anchor: UnitPoint(x: 0.8, y: 0.04)).combined(with: .opacity)))
                    .zIndex(3)
            }
        }
        // A routine's news, in at the top (ChatRoutineBanner).
        .overlay(alignment: .top) {
            if let banner = banners.shown {
                ChatRoutineBanner(browser: browser, banner: banner)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(4)
            }
        }
        // The ⋯ menu, under its button.
        .overlay(alignment: .topTrailing) {
            if more.open {
                ChatMoreMenu(browser: browser, chat: history ? nil : feed.chat, live: feed.live, more: more, width: width,
                             list: history, archive: archive, unreadOnly: unreadOnly, putAway: { ChatColumn.putAway($0, browser: browser) })
                    // design: under the button that opened it, a gap between
                    .padding(.top, (history ? ChatHead.listHeight / 2 : ChatHead.top + ChatHead.face / 2) + ChatHead.button.height / 2 + 6)
                    .padding(.trailing, 8)
                    .transition(.opacity.combined(with: .offset(y: -4)).combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
            }
        }
        .animation(still ? nil : Motion.chatQuick, value: more.open)
        // A file or a tab over any of it: the whole column takes it.
        .overlay {
            if tabOver {
                ChatDropZone(detail: "The tab's page, for the chat to read")
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            } else if dropping || zoom.dropping || dropShown {
                ChatDropZone()
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            }
        }
        .animation(Motion.chatQuick, value: dropping || zoom.dropping)
        .animation(Motion.chatQuick, value: tabOver)
        .onDrop(of: [.fileURL, .url, .image], isTargeted: $dropping) { providers in
            ChatColumn.take(providers, chat: history ? nil : feed.chat, browser: browser)
            return true
        }
        .foregroundStyle(Palette.ink)
        .frame(width: width, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
        .background { ChatColumnGround(browser: browser) }
        // Its edge, in the air between it and the page: dragged as a split's.
        .overlay(alignment: browser.chatLeads ? .trailing : .leading) {
            ChatEdge(browser: browser)
                .offset(x: browser.chatLeads ? Backdrop.inset : -Backdrop.inset)
        }
        .onAppear {
            feed.follow(browser.chatID)
            ChatColumn.asks(for: browser)
            if zoom.look.width != width { zoom.look.width = width }
        }
        .onChange(of: width) { _, now in zoom.look.width = now }
        .onDisappear { feed.leave() }
        // Told in the browser's willSet, before it holds the value, and
        // told the old value again whenever SwiftUI makes the subscription
        // afresh while that willSet runs: a turn later, the browser's own
        // value is what counts.
        .onReceive(browser.changes(\.chatHistory)) { _ in
            DispatchQueue.main.async { settleHistory() }
        }
        // Another chat comes in at its turns, not its screen (ChatPane).
        .onChange(of: feed.chat?.id) { _, _ in more.open = false }
        .onReceive(browser.changes(\.chatArchive)) { archive = $0 }
        // The sheet and the project change in one move, so a project made
        // is the form turning into it, not one leaving and one arriving.
        .onReceive(browser.changes(\.chatProjectSheet)) { _ in settleProjects() }
        .onReceive(browser.changes(\.chatProject)) { _ in settleProjects() }
        .onReceive(browser.changes(\.chatUnread)) { unreadOnly = $0 }
        // A chat picked from the chats kept stays until you go to a tab
        // with a chat of its own: the column follows the tab in front again.
        .onReceive(browser.changes(\.activeID).dropFirst()) { _ in
            DispatchQueue.main.async {
                if let pinned = browser.chatPinned, let own = browser.chatOfTab(browser.active), own != pinned {
                    browser.chatPinned = nil
                }
            }
        }
        .onReceive(browser.changes(\.chatDropShown)) { dropShown = $0 }
        .onReceive(browser.changes(\.chatTabOver)) { tabOver = $0 }
        .onReceive(browser.relay.any) { _ in
            DispatchQueue.main.async {
                // Not while a press builds another chat under the list.
                guard zoom.warm == nil else { return }
                feed.follow(browser.chatID)
                ChatColumn.asks(for: browser)
            }
        }
    }

    /// Whose questions the column holds: its chat's, while it is out with
    /// that chat and not the list of chats. Worked out from the browser,
    /// not from what the column last followed: a follow queued as the
    /// column went away would keep a question off the page (AgentDock).
    static func asks(for browser: Browser) {
        AssistantApprovals.shared.seen(in: browser)
        let id = browser.chatOpen && !browser.chatHistory ? browser.chatID : nil
        if Agents.shared.columnChat != id { Agents.shared.columnChat = id }
    }

    /// A tab of the chat's, or of one of its subagents', waiting on you.
    static func asking(_ chat: Chat, browser: Browser) -> Tab? {
        let family = Set([chat.id] + chat.subagents.map(\.id))
        // A yes still sending keeps its card in the field (Tab.sending).
        return browser.tabs.first { tab in
            if let pay = Payments.shared.flow(tab) { return family.contains(pay.session) }
            return (tab.handoff != nil || tab.sending != nil)
                && (tab.askedBy ?? tab.sending?.permit.session).map(family.contains) == true
        }
    }
}

// MARK: the chat

/// The chat's own part of the column, in a hosting view of its own
/// (ChatZoomStage): the turns and, floating over their foot, the field,
/// what the agent asks over it, the head floating over their top, and the
/// chat's own screen grown out of its face. Made once and told nothing
/// after: it watches what it shows itself.
struct ChatPane: View {
    let browser: Browser
    @ObservedObject var feed: ChatFeed
    @ObservedObject var look: ChatPaneLook
    let zoom: ChatZoom
    let more: ChatMore
    /// A payment's sheet outlives its question (PayFlow): watched here so
    /// it stays in the field's place until the site has said.
    @ObservedObject private var payments = Payments.shared
    /// The chat's own screen, grown out of its face (ChatInfo).
    @State private var info = false
    /// The turns scrolled away from their top: the face shrinks.
    @State private var away = false
    /// How tall the field stands, with what stands over it, floating over
    /// the turns' foot (ChatTranscript.foot).
    @State private var foot: CGFloat = 0
    /// A question's choices over the field: which is lit, picked, put away.
    @ObservedObject private var choices = ChatChoosing.shared
    @Environment(\.accessibilityReduceMotion) private var still

    /// The chat's own space: where its head's name is measured (ChatZoom.heads).
    nonisolated static let space = "chat.pane"

    /// Into the chat's own screen, or back to its turns: the face grows
    /// out of the head into the middle, the turns go down and out.
    private func toggleInfo() {
        more.open = false
        // On the column's own curve: a spring's long tail drew the screen
        // coming in for twice as many frames.
        withAnimation(still ? nil : Motion.chatIn) { info.toggle() }
    }

    var body: some View {
        let width = look.width
        ZStack(alignment: .top) {
            // The turns and the field stay while the chat's own
            // screen is up, only hidden: coming back builds nothing
            // again, the field, its words and the scroll as they were.
            let hidden = info && feed.chat != nil
            // The field floats over the turns' foot, as the head does
            // over their top: they scroll on under it and fade there.
            ZStack(alignment: .bottom) {
                Group {
                    if let chat = feed.chat {
                        ChatTranscript(browser: browser, chat: chat, live: feed.live, away: $away, foot: foot)
                    } else {
                        ChatSuggestions(browser: browser)
                            .padding(.top, ChatHead.height)
                            .padding(.bottom, foot)
                    }
                }
                .frame(maxHeight: .infinity)
                .transition(.opacity.combined(with: .offset(y: 6)))
                VStack(spacing: 0) {
                    let asking = feed.chat.flatMap { ChatColumn.asking($0, browser: browser) }
                    // What it asks of the whole chat, when no tab asks.
                    let chatAsk = asking == nil && feed.chat != nil ? feed.permit : nil
                    // Choices grow up out of the field's top; any other
                    // question takes the field's place, grown out of it.
                    let choosing = asking.map { !$0.choices.isEmpty } ?? false
                    let plaque = (asking != nil && !choosing) || chatAsk != nil
                    if let asking, choosing, choices.away != asking.id {
                        ChatAsk(tab: asking)
                            .padding(.horizontal, ChatLook.fieldInset)
                            .padding(.bottom, 6)
                            .transition(ChatAsk.grow(from: 0))
                    }
                    ZStack(alignment: .bottom) {
                        ChatComposer(browser: browser, chat: feed.chat, live: feed.live, asking: asking, attach: browser.chatAttach)
                            .disabled(hidden || plaque)
                            .opacity(plaque ? 0 : 1)
                            .animation(still ? nil : plaque ? Motion.chatQuick : Motion.chatQuick.delay(0.12), value: plaque)
                            .transition(.opacity)
                        if let asking, plaque {
                            ChatAsk(tab: asking)
                                .padding(.horizontal, ChatLook.fieldInset)
                                .padding(.bottom, ChatAsk.fieldFoot)
                                .transition(ChatAsk.grow(from: ChatAsk.fieldHeight))
                        } else if let chatAsk, let chat = feed.chat {
                            ChatPermitCard(permit: chatAsk, chat: chat.id, browser: browser)
                                .padding(.horizontal, ChatLook.fieldInset)
                                .padding(.bottom, ChatAsk.fieldFoot)
                                .transition(ChatAsk.grow(from: ChatAsk.fieldHeight))
                        }
                    }
                }
                .background(alignment: .bottom) {
                    ChatHead.veil(from: .bottom, to: .top)
                        .padding(.top, -24) // design: the veil reaches over the field, as the head's does under it
                        .opacity(feed.chat == nil || ChatColumn.plainFoot ? 0 : 1)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { foot = $0 }
            }
            // Gone at once, with no motion: a fade of the whole of
            // the turns redrew all of them for every frame of it.
            // Back in a short fade once the screen has gone, so the
            // two are never read through each other.
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .animation(still || hidden ? nil : Motion.leave.delay(0.1), value: hidden)
            if info, let chat = feed.chat {
                ChatInfo(browser: browser, chat: chat, live: feed.live, back: toggleInfo,
                         putAway: { ChatColumn.putAway($0, browser: browser) })
                    .transition(ChatColumn.trade)
            }
            ChatHead(browser: browser, chat: feed.chat, history: false,
                     live: feed.live, asking: feed.chat.flatMap { ChatColumn.asking($0, browser: browser) },
                     asks: feed.chat != nil && feed.permit != nil, width: width,
                     info: info && feed.chat != nil, away: away && feed.chat != nil && !info, more: more, openInfo: toggleInfo)
                .animation(still ? nil : Motion.chatIn, value: away)
        }
        .coordinateSpace(.named(Self.space))
        .foregroundStyle(Palette.ink)
        .frame(width: width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        // Its own hosting view: no title bar's safe area (ChatZoomStage).
        .ignoresSafeArea()
        // Its own hosting view takes a drop over the chat; the column shows where it lands.
        .onDrop(of: [.fileURL, .url, .image], isTargeted: Binding(get: { zoom.dropping }, set: { zoom.dropping = $0 })) { providers in
            ChatColumn.take(providers, chat: feed.chat, browser: browser)
            return true
        }
        // Another chat comes in at its turns, not its screen.
        .onChange(of: feed.chat?.id) { _, _ in
            info = false
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { away = false }
        }
        // Back to the list: it goes as its turns, its screen put away.
        .onReceive(browser.changes(\.chatHistory)) { on in
            guard on, info else { return }
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { info = false }
        }
    }
}

// MARK: the head

/// As a messages app heads a conversation: who you talk to in the middle,
/// the agent's face (the one its tabs wear, AgentFace), and under it,
/// the chat's name and one line: the model to pick while nothing is
/// asked yet, what the agent is doing while it works, and the model that
/// answers otherwise. The turns fade out as they go up under it. The chats kept on the left; a new chat and away
/// on the right. Over the list of chats, the list's own head, its name on
/// the left.
struct ChatHead: View {
    let browser: Browser
    let chat: Chat?
    let history: Bool
    var archive = false
    var unreadOnly = false
    var live = false
    /// A tab of the chat's waiting on you.
    var asking: Tab? = nil
    /// The chat itself waiting on you (Agents.askChat).
    var asks = false
    /// The column's, for the name to keep clear of the buttons at its sides.
    var width: CGFloat = ChatLook.normal
    /// The chat's own screen is out: the face grown into its middle, the
    /// name gone into it, and the way back on the left.
    var info = false
    /// The turns scrolled up under the head: the face small, the name and
    /// the buttons up with it. Only scaled and moved, never laid out again.
    var away = false
    var more: ChatMore? = nil
    var openInfo: () -> Void = {}
    /// The way to the kept chats on its left.
    var chats = true
    @ObservedObject private var keptChats = Chats.shared

    /// New answers in the other chats, as the iPhone counts them.
    private var unread: Int {
        keptChats.all.lazy.filter { $0.unread == true && $0.archived != true && $0.id != chat?.id }.count
    }

    var body: some View {
        // Its two faces trade places as the screens under them do.
        ZStack(alignment: .top) {
            if history {
                list.transition(ChatColumn.haze(depth: 0.97))
            } else {
                conversation.transition(ChatColumn.haze(depth: 1.03))
            }
        }
        // No veil of its own: what scrolls under it fades into the
        // column's glass by its own mask (ChatTranscript, ChatHistory).
    }

    /// The scrolling words disappear softly
    /// beneath the floating controls, without a hard edge. Under the field
    /// from the foot.
    static func veil(from start: UnitPoint, to end: UnitPoint) -> some View {
        Rectangle()
            .fill(.thinMaterial)
            .overlay(Palette.ground.opacity(0.72))
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.85), location: 0.2),
                    .init(color: .black.opacity(0.5), location: 0.45),
                    .init(color: .black.opacity(0.18), location: 0.7),
                    .init(color: .black.opacity(0.04), location: 0.88),
                    .init(color: .clear, location: 1)
                ], startPoint: start, endPoint: end)
            }
            .allowsHitTesting(false)
    }

    /// As wide as the name may be: short of the buttons on both sides by a
    /// gap, the two on the right (more and ×) counted on both.
    private var room: CGFloat {
        min(ChatName.most, width - 2 * (12 + 2 * Self.button.height + 6 + 8))
    }

    /// The project the chat is in, or a new one begins in: its circle on
    /// the face, its name under the chat's, and the way back goes to it.
    private var project: Project? {
        Projects.shared.project(chat?.project ?? (chat == nil ? browser.chatNewProject : nil))
    }

    private var conversation: some View {
        let project = self.project
        return ZStack(alignment: .top) {
            HStack(spacing: 0) {
                // The chats kept, by their own mark; on the chat's own
                // screen, the way back to its turns.
                if chats || info {
                    // A round button with the chats' clock, as the Mac's
                    // column has it; a dot on it for new answers in the
                    // others. Not the iPhone's ‹ with a count: here it is a
                    // place of its own, not the screen before.
                    let fresh = !info && unread > 0 && project == nil
                    Button {
                        if info { openInfo() } else if let project { browser.openProject(project.id) } else { browser.chatHistory = true }
                    } label: { Symbol(info || project != nil ? "chevron.left" : "clock", size: 15) }
                        .buttonStyle(.yab(.glass, Self.button, icon: .round))
                        // A click, not Tab: the chat came in with this the
                        // first key view of its own hosting view, and the
                        // system's focus ring stood around it.
                        .focusable(false)
                        .overlay(alignment: .topTrailing) {
                            if fresh {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 7, height: 7)
                                    .padding(3) // design: the 7pt dot sits on the 36pt button's outer curve
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel(info ? "Back to the Chat" : project.map { "Back to " + $0.name } ?? "Your Chats")
                        .accessibilityValue(fresh ? "Unread messages" : "")
                        .keyTip(info ? "Back to the Chat" : project?.name ?? "Your Chats")
                }
                Spacer(minLength: 0)
                // Everything else the head did, and more, in one menu.
                if let more {
                    Button { more.open.toggle() } label: { Symbol("ellipsis", size: 15) }
                        .buttonStyle(.yab(.glass, Self.button, icon: .round))
                        .focusable(false)
                        .background(ClickZone(away: more.away))
                        .keyTip("More")
                }
                // Away with the column, as Hide Chat in the menu.
                Button { browser.moveChat(open: false) } label: { Symbol("xmark", size: 15) }
                    .buttonStyle(.yab(.glass, Self.button, icon: .round))
                    .focusable(false)
                    .padding(.leading, 6)
                    .accessibilityLabel("Hide Chat")
                    .keyTip("Hide Chat", keys: Keymap.shared.keys(.closeChat)?.text)
            }
            .padding(.horizontal, 12)
            // design: the buttons stand level with the face's middle at rest
            .padding(.top, Self.top + (Self.face - Self.button.height) / 2)
            // and stay there as the face shrinks under them: only the face
            // and the name go up with the turns.
            // Who you talk to: a click on the face or the name opens the
            // chat's own screen, the face growing out of the head into it.
            VStack(spacing: 0) {
                // Laid out once, the screen's size, and only scaled: growing
                // into the screen lays nothing out again for each frame.
                ChatFace(chat: chat, live: live, asking: asking != nil || asks, project: project)
                    .scaleEffect(info ? 1 : (away ? Self.faceAway : Self.face) / Self.faceInfo, anchor: .top)
                    .frame(height: Self.face - Self.overlap, alignment: .top)
                    .zIndex(1)
                ChatName(browser: browser, chat: chat, live: live, asking: asking != nil || asks, most: room)
                    .offset(y: away ? -Self.lift : 0)
                    .opacity(info ? 0 : 1)
                    .allowsHitTesting(!info)
            }
            .contentShape(Rectangle())
            .onTapGesture { if chat != nil, !info { openInfo() } }
            // On its own screen the face stands under the buttons, not between them.
            .padding(.top, Self.top + (info ? Self.drop : 0))
        }
        .frame(height: Self.height, alignment: .top)
    }

    private var list: some View {
        HStack(spacing: 4) {
            Text(archive ? "Archived Chats" : unreadOnly ? "Unread Chats" : "Chats")
                .font(.system(size: 20, weight: .semibold)) // as mail's heading and a chat's own screen
                .lineLimit(1)
            Spacer(minLength: 8)
            // A new chat (mail's new letter) and the list's commands on one
            // glass, as a pair; away on its own. The ×'s glass, untinted, so
            // the three read as one row.
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    // design: full ink, as the glass button beside them has
                    Button { browser.newChat() } label: { Symbol("square.and.pencil", size: 15) }
                        .buttonStyle(.yab(.quiet, Self.button, tint: Palette.ink, icon: .round))
                        .focusable(false)
                        .keyTip("New Chat")
                        // A new chat comes out of it, and goes back into it,
                        // when New Chat's row is out of sight (ChatZoom).
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatCards.space)) } action: { frame in
                            ChatCards.frames[ChatCards.pencil] = frame
                        }
                    // A project of chats, as Messages' New Group.
                    Button { ChatMoves.newProject(with: [], browser: browser) } label: { Symbol("folder.badge.plus", size: 15) }
                        .buttonStyle(.yab(.quiet, Self.button, tint: Palette.ink, icon: .round))
                        .focusable(false)
                        .keyTip("New Project")
                    if let more {
                        Button { more.open.toggle() } label: { Symbol("command", size: 15) }
                            .buttonStyle(.yab(.quiet, Self.button, tint: Palette.ink, icon: .round))
                            .focusable(false)
                            .background(ClickZone(away: more.away))
                            .keyTip("Commands")
                    }
                }
                .background {
                    if #available(macOS 26.0, *), PullView.glassy {
                        Color.clear.glassEffect(.regular, in: .capsule)
                    } else {
                        Capsule().fill(Palette.ink.opacity(0.07)) // design: the glass button's own wash
                    }
                }
                // In the chats there is no way "back": a chat picked, or a new one, is the way out.
                Button { browser.moveChat(open: false) } label: { Symbol("xmark", size: 14) }
                    .buttonStyle(.yab(.glass, Self.button, icon: .round))
                    .focusable(false)
                    .keyTip("Hide Chat", shortcut: "Hide Chat")
            }
        }
        .padding(.leading, 16) // design: the title lines up with the rows' words
        .padding(.trailing, 12)
        .frame(height: Self.listHeight)
    }

    /// Liquid Glass in `shape`, or the material where there is none.
    @ViewBuilder
    static func glass(_ shape: some Shape, plain: Bool) -> some View {
        if #available(macOS 26.0, *), !plain, PullView.glassy {
            // Tinted with the column's ground, deeper than the omnibox's
            // glass: the turns scrolling under it stay out of the name's
            // way.
            Color.clear.glassEffect(.regular.tint(Palette.ground.opacity(Self.tint)), in: shape)
        } else {
            shape.fill(.regularMaterial)
        }
    }

    static let top: CGFloat = 16
    /// How much of the column's ground the head's glass carries.
    static let tint: CGFloat = 0.7
    /// The head's round buttons, back, ⋯, and the chats' own.
    static let button = ButtonSize.large
    static let face: CGFloat = 44
    /// The face on the chat's own screen, and how far it comes down there.
    static let faceInfo: CGFloat = 88
    static let drop: CGFloat = 40
    /// The face scrolled away from, and how far the name comes up after it.
    static let faceAway: CGFloat = 28
    static let lift: CGFloat = face - faceAway
    /// The face's foot stands over the name's glass.
    static let overlap: CGFloat = 6
    static let name: CGFloat = 44
    static let bottom: CGFloat = 8
    static let height: CGFloat = top + face - overlap + name + bottom
    static let listHeight: CGFloat = 60
    static let contentGap: CGFloat = 6
}

/// The chat's agent as its tabs wear it (AgentFace), on glass: its eyes on
/// what it does while it works and thinking in between, the hand while it
/// waits on you, looking down when it failed, and otherwise looking about.
/// Drawn at the size of the chat's own screen and scaled down in the head,
/// so it grows into that screen sharp.
private struct ChatFace: View {
    let chat: Chat?
    let live: Bool
    let asking: Bool
    /// Its project's circle on its shoulder, as a group's in Messages.
    var project: Project? = nil
    @ObservedObject private var feed = AgentFeed.shared
    /// Bumped when a step has shown its time, so the face is worked out
    /// again then, rather than polled.
    @State private var clock = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let _ = clock
        let act = latest
        Face(pose: pose(act, at: Date()), size: Self.ink, tint: Palette.ink)
            .frame(width: ChatHead.faceInfo, height: ChatHead.faceInfo)
            .background { ChatHead.glass(Circle(), plain: reduceTransparency) }
            // Drawn at the screen's size as the face is, and scaled with it:
            // 22 on the 44 of the head, out over its top right.
            .overlay(alignment: .topTrailing) {
                if let project {
                    ProjectCircle(project: project, size: Self.badge)
                        .padding(4) // design: a ring of the column's ground round the badge, as the concept's 2 pt at half size
                        .background(Palette.ground, in: Circle())
                        .offset(x: 18, y: -10) // design: the concept's badge, out past the face's top right, at twice its size
                        .accessibilityLabel("In " + project.name)
                }
            }
            // A step shows for 2.2 seconds, as on a tab; then thinking.
            .task(id: act?.count) {
                guard let act else { return }
                let left = 2.2 - Date().timeIntervalSince(act.at)
                guard left > 0 else { return }
                try? await Task.sleep(for: .seconds(left + 0.05))
                if !Task.isCancelled { clock += 1 }
            }
    }

    /// The face itself on the chat's screen, in from the glass's edge as
    /// in the head (28 in 44).
    static let ink: CGFloat = 56
    /// The project's circle on it, at the screen's size (22 in the head).
    static let badge: CGFloat = 44

    /// The newest step in any of the chat's tabs.
    private var latest: AgentFeed.Act? {
        guard live, let session = chat.flatMap({ Agents.shared.session($0.id) }) else { return nil }
        return Agents.shared.tabs(of: session).compactMap { feed.last[$0.id] }.max { $0.count < $1.count }
    }

    private func pose(_ act: AgentFeed.Act?, at now: Date) -> FacePose {
        if asking { return .hand }
        guard let chat else { return .watch }
        if live {
            if let act, now.timeIntervalSince(act.at) < 2.2 { return act.pose }
            return .think
        }
        // Done, it is only itself again: the tick is the tab's, not a face to keep.
        return chat.state == "failed" ? .stuck : .watch
    }
}

/// The chat's name and one line under it, on glass at every title length.
private struct ChatName: View {
    let browser: Browser
    let chat: Chat?
    let live: Bool
    /// A tab of the chat's waits on you: what it asks stands over the field.
    let asking: Bool
    /// Its widest (ChatHead.room).
    let most: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if let chat {
            plate(chat)
                .task(id: chat.id) { ChatTitles.shorten(chat) }
        } else {
            VStack(spacing: 1) {
                Text("New chat")
                    .font(.system(size: ChatZoomStage.headType, weight: .semibold))
                    .modifier(ChatZoomVeiled(card: nil))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatPane.space)) } action: { frame in
                        ChatZoom.heads[ChatCards.newChat] = frame
                    }
                ChatModelLine(browser: browser, chat: nil)
            }
            .padding(.horizontal, 16)
            .frame(minWidth: min(Self.least, most), minHeight: ChatHead.name)
            .background { ChatHead.glass(Capsule(), plain: reduceTransparency) }
        }
    }

    /// The name sets the width, never the line under it, which is cut to
    /// fit: the glass keeps still while the steps' words come and go.
    private func plate(_ chat: Chat) -> some View {
        let title = chat.title.isEmpty ? "Chat" : chat.title
        let titleWidth = (title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        ]).width
        // The title, its chevron and side insets set the plate's width;
        // at rest, "Lisbon Trip · model" under it too, so the project's
        // name is never the part cut short.
        var naturalWidth = ceil(titleWidth) + 9 + 4 + 32
        if !live, let project = Projects.shared.project(chat.project) {
            let words = project.name + " \u{00B7} " + Self.modelName(chat)
            let wordsWidth = (words as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
            naturalWidth = max(naturalWidth, ceil(wordsWidth) + 10 + 4 * 3 + 32)
        }
        let plateWidth = min(most, max(Self.least, naturalWidth))
        return VStack(spacing: 1) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: ChatZoomStage.headType, weight: .semibold))
                    .lineLimit(1)
                    .modifier(ChatZoomVeiled(card: nil))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatPane.space)) } action: { frame in
                        ChatZoom.heads[chat.id] = frame
                    }
                Symbol("chevron.right", size: 9, weight: .semibold)
                    .foregroundStyle(Palette.muted)
            }
            Color.clear.frame(height: Self.line)
        }
        .frame(width: max(0, plateWidth - 32))
        .overlay(alignment: .bottom) {
            ChatName.status(chat, live: live, asking: asking)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(height: Self.line)
        }
        .padding(.horizontal, 16)
        .frame(height: ChatHead.name)
        .background {
            ChatHead.glass(Capsule(), plain: reduceTransparency)
        }
        .contentShape(Capsule())
    }

    /// At work, the live line's words; otherwise the model answering.
    @ViewBuilder
    static func status(_ chat: Chat, live: Bool, asking: Bool) -> some View {
        // Waiting on you it says nothing of it: what it asks stands in the
        // turns, and the face raises its hand.
        if live, !asking, Agents.shared.session(chat.id) != nil {
            // The turn's live line's words, held as it holds them (ChatLive),
            // so the two never say different things. Words alone: no marks.
            ChatLiveWords(turn: chat.turns.last ?? [])
                .foregroundStyle(Palette.muted)
        } else if !asking {
            HStack(spacing: 4) {
                // "Lisbon Trip · Opus": its project first, a click going there.
                if let project = Projects.shared.project(chat.project), let browser = Links.browser {
                    Button { browser.openProject(project.id) } label: { Text(project.name).lineLimit(1) }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .pointerTip("Open " + project.name)
                    Text("\u{00B7}")
                }
                model(chat)
            }
            .foregroundStyle(Palette.muted)
        }
    }

    /// The agent's mark and the model it answers with.
    static func model(_ chat: Chat) -> some View {
        HStack(spacing: 4) {
            Symbol(FieldAnswer.mark(chat.cli), size: 10)
            Text(modelName(chat))
        }
    }

    static func modelName(_ chat: Chat) -> String {
        AgentModels.find(chat.cli, Agents.shared.session(chat.id)?.model ?? chat.model)?.name ?? AgentModels.agentName(chat.cli)
    }

    /// The line under the name.
    static let line: CGFloat = 15
    /// The glass's least and most width, whatever the name.
    static let least: CGFloat = 160
    static let most: CGFloat = 260
}

// MARK: asked first

/// What a chat's head and rows ask before doing, in the app's own card
/// over the page, as every other question is (Question). "This chat", not
/// its name: a name is often a question of its own.
@MainActor
enum ChatQuestions {
    static func archive(_ chat: Chat, then: @escaping () -> Void) {
        let question = Question(title: "Archive this chat?",
                                detail: "It leaves your chats and stays in Archived Chats.",
                                glyph: "archivebox", yes: "Archive")
        Task { @MainActor in
            guard await Questions.shared.ask(question) else { return }
            then()
        }
    }

    /// Every chat under a row at once, as Mail's Archive Below.
    static func archive(below count: Int, then: @escaping () -> Void) {
        let question = Question(title: count == 1 ? "Archive the chat below?" : "Archive \(count) chats below?",
                                detail: "They leave your chats and stay in Archived Chats. Pinned and working chats stay.",
                                glyph: "archivebox", yes: "Archive")
        Task { @MainActor in
            guard await Questions.shared.ask(question) else { return }
            then()
        }
    }

    static func delete(_ chat: Chat, then: @escaping () -> Void) {
        let question = Question(title: "Delete this chat?",
                                detail: "Its turns are deleted from this Mac.",
                                glyph: "trash", yes: "Delete", danger: true)
        Task { @MainActor in
            guard await Questions.shared.ask(question) else { return }
            then()
        }
    }

    /// Its name, in a line to type into, the old one picked to be typed over.
    static func rename(_ chat: Chat) {
        let field = Question.Field(chat.title, prompt: "Name")
        let question = Question(title: "Rename this chat", glyph: "pencil", yes: "Rename", field: field)
        Task { @MainActor in
            guard await Questions.shared.ask(question), !field.trimmed.isEmpty, field.trimmed != chat.title else { return }
            // Its own now: the model on this Mac won't name it again (ChatTitles).
                if let session = Agents.shared.session(chat.id) { session.title = field.trimmed }
                Chats.shared.rename(chat.id, field.trimmed)
            Agents.shared.objectWillChange.send()
        }
    }
}

// MARK: the ⋯ menu

/// The ⋯ menu is out; a click anywhere but on it or on ⋯ puts it away.
@MainActor
final class ChatMore: ObservableObject {
    @Published var open = false { didSet { if open != oldValue { away.watch(open) } } }
    lazy var away = ClickAway { [weak self] in self?.open = false }
}

/// What can be done from the head, as ⌘K's actions and the + menu are
/// drawn: on glass, a caption over each part, the chosen row inked, its
/// keys on plates, and a search at its foot that takes the keyboard. This
/// chat's own things first, then the chats'.
struct ChatMoreMenu: View {
    let browser: Browser
    let chat: Chat?
    let live: Bool
    @ObservedObject var more: ChatMore
    let width: CGFloat
    /// Over the list of chats: the list's own commands.
    var list = false
    var archive = false
    var unreadOnly = false
    /// Archive, with your yes first (ChatColumn.putAway).
    var putAway: (Chat) -> Void = { _ in }
    @State private var search = ""
    @State private var chosen = 0

    private struct Item: Identifiable {
        let id: String
        let symbol: String
        let title: String
        var keys = ""
        var danger = false
        let run: () -> Void
    }

    private var parts: [(String, [Item])] {
        var out: [(String, [Item])] = []
        if let chat {
            // Read as it is now, not as the head was drawn.
            let kept = Chats.shared.chat(chat.id) ?? chat
            var own: [Item] = []
            if !chat.answer.isEmpty {
                own.append(Item(id: "copy", symbol: "doc.on.doc", title: chat.copyTitle) { [browser] in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(chat.copiedAnswer, forType: .string)
                    // The menu is gone: the corner says it.
                    browser.announce("Copied", mark: "checkmark", feedback: .success)
                })
            }
            own.append(Item(id: "keep", symbol: kept.pinned ? "pin.slash" : "pin",
                            title: kept.pinned ? "Unpin Chat" : "Pin Chat") {
                Chats.shared.pin(chat.id, !kept.pinned)
            })
            own.append(Item(id: "rename", symbol: "pencil", title: "Rename Chat\u{2026}") {
                ChatQuestions.rename(kept)
            })
            own.append(Item(id: "archive", symbol: "archivebox", title: kept.archived == true ? "Unarchive" : "Archive\u{2026}") { [putAway] in
                putAway(kept)
            })
            if live {
                own.append(Item(id: "stop", symbol: "stop", title: "Stop") { _ = Agents.shared.stop(chat.id) })
            } else {
                own.append(Item(id: "delete", symbol: "trash", title: "Delete Chat\u{2026}", danger: true) { [browser] in
                    ChatQuestions.delete(kept) {
                        browser.deleteChat(chat.id)
                    }
                })
            }
            out.append(("This chat", own))
        }
        var all: [Item] = []
        // A new chat's model, the only place it is chosen, as the line under its name does.
        if chat == nil, !list {
            all.append(Item(id: "model", symbol: FieldAnswer.mark(browser.chatAgent), title: "Change Model\u{2026}") { [browser] in
                ChatModelLine.choose(browser: browser, chat: nil)
            })
        }
        if chat != nil || list {
            all.append(Item(id: "new", symbol: "square.and.pencil", title: "New Chat", keys: Keymap.shared.keys(.newWindow)?.text ?? "") { [browser] in browser.newChat() })
        }
        if list {
            if !archive {
                all.append(Item(id: "unread", symbol: "envelope", title: unreadOnly ? "All Chats" : "Unread Only") { [browser] in
                    browser.chatUnread.toggle()
                })
            }
            all.append(Item(id: "archived", symbol: "tray.and.arrow.down", title: archive ? "All Chats" : "Archived Chats") { [browser] in
                if !browser.chatArchive { browser.chatUnread = false }
                browser.chatArchive.toggle()
            })
            all.append(Item(id: "settings", symbol: "gearshape", title: "Chat Settings\u{2026}") { [browser] in
                browser.openSettings(.agents)
            })
        } else {
            all.append(Item(id: "chats", symbol: "clock", title: "Your Chats") { [browser] in browser.chatHistory = true })
        }
        all.append(Item(id: "hide", symbol: "xmark", title: "Hide Chat", keys: Keymap.shared.keys(.closeChat)?.text ?? "") { [browser] in
            browser.moveChat(open: false)
        })
        out.append(("Chats", all))
        // Typing looks through all of it, by the rows' words.
        let words = search.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return out }
        return out.compactMap { part in
            let found = part.1.filter { item in words.allSatisfy { item.title.lowercased().contains($0) } }
            return found.isEmpty ? nil : (part.0, found)
        }
    }

    var body: some View {
        let parts = self.parts
        let items = parts.flatMap(\.1)
        VStack(alignment: .leading, spacing: 0) {
            // At its top, where it opens down from its button: as ⌘K's own
            // search, it takes the keyboard as the menu comes up, and gives
            // it back to the field when the menu goes.
            ChatMenuSearch(text: $search,
                           move: { step in chosen = max(0, min(items.count - 1, chosen + step)) },
                           pick: { if items.indices.contains(chosen) { run(items[chosen]) } },
                           close: {
                               more.open = false
                               browser.chatFocus += 1
                           },
                           placeholder: "Search actions\u{2026}")
                .frame(height: 20)
                .padding(.horizontal, 16)
                .frame(height: 48)
                .onChange(of: search) { _, _ in chosen = 0 }
            Rectangle()
                .fill(Omnibox.seam)
                .frame(height: 1)
            if items.isEmpty {
                Text("Nothing matches \u{201C}\(search)\u{201D}")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: FieldActionsPanel.row + 8, alignment: .leading)
                    .padding(.top, 4)
            }
            ForEach(Array(parts.enumerated()), id: \.element.0) { number, part in
                if number > 0 {
                    Rectangle().fill(Omnibox.seam).frame(height: 1)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                }
                Text(part.0)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                VStack(spacing: 0) {
                    ForEach(part.1) { item in
                        row(item, index: items.firstIndex { $0.id == item.id } ?? 0)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.bottom, 8)
        .frame(width: min(FieldActionsPanel.width, width - 16))
        .background { FieldGlass(shape: RoundedRectangle(cornerRadius: Radius.floating, style: .continuous), lifted: true) }
        .background(ClickZone(away: more.away))
        .transaction { $0.animation = nil }
    }

    private func row(_ item: Item, index: Int) -> some View {
        let ink = item.danger ? ButtonCSS.danger : Palette.ink
        return HStack(spacing: 12) {
            Symbol(item.symbol, size: 12)
                .foregroundStyle(ink)
                .frame(width: 16)
            Text(item.title)
                .font(.system(size: 13.5))
                .foregroundStyle(ink)
                .lineLimit(1)
            Spacer(minLength: 16)
            // One thing at the end, as ⌘K's rows: what Return does on the
            // chosen row, else the row's own keys.
            if index == chosen {
                KeyGlyphs(keys: "\u{21A9}", size: 13.5)
            } else if !item.keys.isEmpty {
                KeyGlyphs(keys: item.keys, size: 13.5)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: FieldActionsPanel.row)
        .background {
            if index == chosen {
                RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Omnibox.chosenFill)
            }
        }
        .contentShape(Rectangle())
        .onHover { if $0 { chosen = index } }
        .onTapGesture { run(item) }
    }

    private func run(_ item: Item) {
        more.open = false
        item.run()
    }
}

// MARK: the chat's own screen

/// Grown out of the head's face, as a messages app shows who you talk to:
/// the face big in the middle (drawn by the head), the chat's name and who
/// answers under it, its own things as round buttons, and the tabs it
/// worked in, a click away. Back by the arrow on the head's left.
struct ChatInfo: View {
    let browser: Browser
    let chat: Chat
    let live: Bool
    let back: () -> Void
    let putAway: (Chat) -> Void
    @State private var copied = false

    var body: some View {
        // Read as it is now, not as the column was drawn.
        let kept = Chats.shared.chat(chat.id) ?? chat
        // A scroll view only for more tabs than the column shows: it is an
        // NSScrollView to make, a third of what the screen cost to open.
        if pages.count > Self.fit {
            ThreadScrollView(.vertical) { content(kept) }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            content(kept)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// The tabs the screen holds without scrolling, in the shortest column.
    static let fit = 6

    private func content(_ kept: Chat) -> some View {
            VStack(spacing: 0) {
                Text(chat.title.isEmpty ? "Chat" : chat.title)
                    .font(.system(size: 20, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    ChatName.model(chat)
                    Text("\u{00B7}")
                    Text("Started " + Self.when(chat.started))
                }
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .padding(.top, 4)
                HStack(alignment: .top, spacing: 24) {
                    button(kept.pinned ? "Unpin" : "Pin", symbol: kept.pinned ? "pin.fill" : "pin", holding: "Unpin") {
                        Chats.shared.pin(chat.id, !kept.pinned)
                    }
                    if !chat.answer.isEmpty {
                        // Said done where it was pressed, a moment, its width kept.
                        button(copied ? "Copied" : chat.copyTitle, symbol: copied ? "checkmark" : "doc.on.doc", holding: chat.copyTitle) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(chat.copiedAnswer, forType: .string)
                            copied = true
                        }
                        .task(id: copied) {
                            guard copied else { return }
                            try? await Task.sleep(for: .seconds(1.6))
                            if !Task.isCancelled { copied = false }
                        }
                    }
                    if live {
                        button("Stop", symbol: "stop") { _ = Agents.shared.stop(chat.id) }
                    } else {
                        button(kept.archived == true ? "Unarchive" : "Archive", symbol: "archivebox", holding: "Unarchive") {
                            putAway(kept)
                        }
                    }
                }
                .padding(.top, 20)
                let pages = self.pages
                if !pages.isEmpty {
                    // Every page it read, a click going to one still open.
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Pages it read")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 8)
                            .padding(.top, 4)
                            .padding(.bottom, 2)
                        ForEach(pages) { page in row(page) }
                        if !chat.tabs.isEmpty {
                            Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
                                .padding(.vertical, 4)
                            Button("Close Its Tabs", mark: "yab.tabs.x") {
                                for ref in chat.tabs {
                                    if let tab = browser.tabs.first(where: { $0.id.uuidString == ref.id }) { browser.close(tab) }
                                }
                            }
                            .buttonStyle(.yab(.quiet, .small))
                            .focusable(false)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .padding(.top, 24)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, ChatHead.top + ChatHead.drop + ChatHead.faceInfo + 12)
            .padding(.bottom, 16)
    }

    /// A page it read: a tab of its own, one of yours it looked at, or one
    /// you gave it with your words.
    private struct Page: Identifiable {
        let id: String
        let title: String
        let host: String
        let tab: Tab?
    }

    /// Its own tabs, then yours in the order it came to them; each once.
    private var pages: [Page] {
        var out: [Page] = []
        func add(_ title: String, _ host: String, _ tab: Tab?) {
            // A blank tab was nothing to read.
            guard !host.isEmpty else { return }
            let id = tab?.id.uuidString ?? host + "|" + title
            guard !out.contains(where: { $0.id == id || (tab == nil && $0.host == host && $0.title == title) }) else { return }
            out.append(Page(id: id, title: title.isEmpty ? host : title, host: StepWords.bare(host), tab: tab))
        }
        for ref in chat.tabs {
            let tab = browser.tabs.first { $0.id.uuidString == ref.id }
            add(tab?.title ?? ref.title, URL(string: ref.url)?.host() ?? ref.url, tab)
        }
        for item in chat.items {
            if item.kind == .tool, let tab = ChatStepMark.tab(item.detail) {
                add(tab.title, tab.address?.host() ?? "", tab)
            } else if item.kind == .asked {
                // What went with your words: "t:host|title".
                for line in item.detail.split(separator: "\n") where line.hasPrefix("t:") {
                    let parts = line.dropFirst(2).split(separator: "|", maxSplits: 1).map(String.init)
                    let host = parts.first ?? "", title = parts.count > 1 ? parts[1] : ""
                    let tab = browser.tabs.first { $0.address?.host() == host && $0.title == title }
                    add(title, host, tab)
                }
            }
        }
        return out
    }

    private func row(_ page: Page) -> some View {
        Button {
            if let tab = page.tab {
                browser.select(tab)
                back()
            }
        } label: {
            HStack(spacing: 8) {
                Group {
                    if let icon = page.tab?.icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        SiteMark(host: page.host, size: 16)
                    }
                }
                .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(page.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(page.host)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChatMenuRow())
        .disabled(page.tab == nil)
    }

    /// A round glass button with its word under it, as wide as the
    /// longest word it says, so saying another moves nothing.
    private func button(_ title: String, symbol: String, holding: String = "", action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) { Symbol(symbol, size: 17) }
                .buttonStyle(.yab(.glass, .hero, icon: .round))
                .focusable(false)
            ZStack {
                Text(holding).hidden()
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.ink)
        }
        .frame(minWidth: ButtonSize.hero.height)
    }

    /// "today at 15:45", "Monday", "Sep 12".
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let format = AppDates.formatter()
        if calendar.isDateInToday(date) {
            format.dateFormat = "HH:mm"
            return "today at " + format.string(from: date)
        }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            format.dateFormat = "EEEE"
        } else {
            format.dateFormat = "MMM d"
        }
        return format.string(from: date)
    }
}

// MARK: its model

/// Under the head's title, as the ⌘J answer has it: the agent's mark and
/// the model, which a click changes for what is asked next, in the model
/// picker (ModelPicker), each plan there saying how much of it is used.
/// A chat keeps its agent (its conversation lives there); a new one can go
/// to either.
struct ChatModelLine: View {
    let browser: Browser
    let chat: Chat?
    @ObservedObject private var defaults = ModelDefaults.shared

    private var cli: String { chat?.cli ?? browser.chatAgent }
    private var model: String? { chat.map { Agents.shared.session($0.id)?.model ?? $0.model } ?? browser.chatChoice.model }
    private var effort: String? { chat.map { Agents.shared.session($0.id)?.effort } ?? browser.chatChoice.effort }

    var body: some View {
        Button { Self.choose(browser: browser, chat: chat) } label: {
            HStack(spacing: 4) {
                Symbol(FieldAnswer.mark(cli), size: 10)
                Text(AgentModels.find(cli, model)?.name ?? AgentModels.agentName(cli))
                    .lineLimit(1)
                Symbol("chevron.up.chevron.down", size: 8, weight: .semibold) // design: MenuCell's own
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .keyTip("Model for what you ask next")
    }

    /// The model picker for what is asked next, from here or the ⋯ menu.
    static func choose(browser: Browser, chat: Chat?, query: String = "", retry: (() -> Void)? = nil) {
        let line = ChatModelLine(browser: browser, chat: chat)
        withAnimation(Motion.chatQuick) {
            browser.modelPicker = ModelPickerRequest(
                title: retry == nil ? "Model" : "Try Again With", clis: chat == nil ? AgentPlan.clis.filter(AgentModels.here) : [line.cli],
                choice: ModelChoice(cli: line.cli, model: line.model, effort: line.effort), query: query
            ) { picked in
                line.pick(picked)
                retry?()
            }
        }
    }

    private func pick(_ picked: ModelChoice) {
        guard let chat else {
            ModelDefaults.shared[.chats] = picked
            browser.chatNext = nil
            return
        }
        // The next turn resumes the same conversation on this model.
        let session = Agents.shared.session(chat.id) ?? Agents.shared.revive(chat.id)
        session?.model = picked.model
        session?.effort = picked.effort
        if let session { Chats.shared.keep(Agents.shared.chat(of: session)) }
        Agents.shared.objectWillChange.send()
    }
}

// MARK: the chats kept

/// Every chat kept, those kept for good first, then by day; found by their words.
/// One goes into the column and stays there until you pick another, start
/// a new one, or go to a tab with a chat of its own.
/// Where the cards of the chats kept lay last, in the column's space, so a
/// chat zooms out of its card and back into it as the iPhone's Chats page
/// has it (ChatColumn.zoom): read from the list while it is up, kept while
/// a chat is, with where the list was scrolled, so the cards come back
/// where they were. Plain statics: the frames change nothing drawn.
@MainActor enum ChatCards {
    static var frames: [String: CGRect] = [:]
    /// Each card's title, the words that fly to the chat's head.
    static var titles: [String: CGRect] = [:]
    /// The column's width the frames were taken at.
    static var width: CGFloat = 0
    /// The list's top and foot in the column: a card scrolled out of them
    /// has nowhere to zoom from.
    static var shown: ClosedRange<CGFloat> = 0...0
    static var offset: CGFloat = 0
    /// The groups opened under Chats.
    static var open: Set<Group> = []
    /// New Chat's row, which a new chat zooms out of.
    static let newChat = "chat.cards.new"
    /// The pencil in the list's head, which it zooms out of with the row out of sight.
    static let pencil = "chat.cards.pencil"

    /// The card `id` lay in, if the column is still as wide and it showed.
    static func card(_ id: String, width now: CGFloat) -> CGRect? {
        guard abs(width - now) < 0.5, let frame = frames[id],
              frame.minY >= shown.lowerBound - 1, frame.maxY <= shown.upperBound + 1 else { return nil }
        return frame
    }

    /// Why `card` found none, for the bench's marks.
    static func why(_ id: String, width now: CGFloat) -> [String: Any] {
        ["id": id, "width": Double(width), "now": Double(now), "frame": frames[id].map { "\($0)" } ?? "none",
         "shown": "\(shown)"]
    }

    /// Who began the chats under one heading, as the iPhone's Chats page
    /// splits them: the person's own, the tasks an agent or a command
    /// began, and each routine's latest run.
    enum Group: String, Hashable, CaseIterable {
        case yours, tasks, routines

        var title: String {
            switch self {
            case .yours: "Chats"
            case .tasks: "Tasks"
            case .routines: "Routines"
            }
        }

        /// Empty groups but the person's own are left out.
        static func split(_ chats: [Chat]) -> [(Group, [Chat])] {
            var yours: [Chat] = [], tasks: [Chat] = [], routines: [Chat] = []
            var seen = Set<String>()
            for chat in chats {
                if let routine = chat.routine ?? (chat.source == "routine" ? chat.title : nil) {
                    // Listed newest first: the first of a routine is its latest run.
                    if seen.insert(routine).inserted { routines.append(chat) }
                } else if chat.source == nil || chat.pinned {
                    yours.append(chat)
                } else {
                    tasks.append(chat)
                }
            }
            return [(.yours, yours), (.tasks, tasks), (.routines, routines)].filter { $0.0 == .yours || !$0.1.isEmpty }
        }
    }

    nonisolated static let space = "chat.column"
    /// The iPhone's card, at the Mac's sizes.
    static let gap: CGFloat = 10
    static let step: CGFloat = 6
    static let height: CGFloat = 136
    static let favicon: CGFloat = 16
    static let icon: CGFloat = 32
}

/// The chats kept, as the iPhone's Chats page lays them: New Chat's row,
/// then cards two a row (the agent's sites or tabs, the title in two
/// lines, the answer's start, when), the tasks and routines folded under
/// their own headings.
private struct ChatHistory: View {
    let browser: Browser
    /// The chats put away instead of the rest.
    let archive: Bool
    /// Only those with an answer not yet seen.
    var unreadOnly = false
    let done: () -> Void
    @ObservedObject private var chats = Chats.shared
    @ObservedObject private var projects = Projects.shared
    @State private var words = ""
    @State private var open = ChatCards.open
    @State private var place = ScrollPosition(point: CGPoint(x: 0, y: ChatCards.offset))
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var found: [Chat] {
        let terms = words.lowercased().split(separator: " ").map(String.init)
        let shelf = chats.all.filter { ($0.archived == true) == archive && (!unreadOnly || $0.unread == true) }
        // Kept for good first, as the iPhone lists them; the rest newest first.
        let kept = shelf.filter(\.pinned) + shelf.filter { !$0.pinned }
        // A chat in a project is in it, not among the rest, until searched for.
        guard !terms.isEmpty else { return archive || unreadOnly ? kept : kept.filter { projects.project($0.project) == nil } }
        return kept.filter { chat in
            let text = (chat.title + " " + chat.answer + " " + chat.items.filter { $0.kind == .asked }.map(\.text).joined(separator: " ")).lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
    }

    /// The projects among the chats: those not pinned, or, searched for,
    /// any whose name says it; each with its latest chat.
    private var projectRows: [(Project, Chat?)] {
        guard !unreadOnly else { return [] }
        let terms = words.lowercased().split(separator: " ").map(String.init)
        // Put away, a project stands among the chats put away.
        if archive {
            return projects.archived.filter { project in terms.allSatisfy { project.name.lowercased().contains($0) } }
                .map { project in (project, chats.all.filter { $0.project == project.id }.max { $0.updated < $1.updated }) }
        }
        let shown = terms.isEmpty ? projects.listed.filter { !$0.pinned }
            : projects.listed.filter { project in terms.allSatisfy { project.name.lowercased().contains($0) } }
        return shown.map { project in (project, chats.of(project: project.id).max { $0.updated < $1.updated }) }
    }

    /// What stands over the cards: the head and the search.
    private static let under: CGFloat = ChatHead.listHeight + 32 + 4
    /// Where the cards start, a little under the search.
    private static let top: CGFloat = under + 6
    /// How far the cards have gone under the head and the search (ColumnEnds).
    @State private var ends = ColumnEnds()

    var body: some View {
        let all = found
        let rows = projectRows
        let groups = words.isEmpty && !archive && !unreadOnly ? ChatCards.Group.split(all) : [(ChatCards.Group.yours, all)]
        // As Settings' sidebar: the cards run the whole height and go up
        // under the search and the head as they scroll, into a veil that
        // thickens toward the top, not cut at the search's foot.
        ZStack(alignment: .top) {
            ThreadScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The pinned projects, big circles over the rest.
                    if words.isEmpty, !archive, !unreadOnly, !projects.pinned.isEmpty {
                        ChatPinnedProjects(browser: browser, projects: projects.pinned)
                    }
                    ForEach(groups, id: \.0) { entry in
                        let (group, list) = entry
                        if group != .yours {
                            ChatGroupHead(group: group, count: list.count, open: open.contains(group)) {
                                withAnimation(Motion.chatQuick) {
                                    if open.contains(group) { open.remove(group) } else { open.insert(group) }
                                }
                                ChatCards.open = open
                            }
                        }
                        if group == .yours || open.contains(group) {
                            // Cards two a row, as before; the projects among
                            // them by their latest chat.
                            let entries = group == .yours ? ChatListEntry.merge(list, projects: rows) : list.map(ChatListEntry.chat)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ChatCards.gap, alignment: .top), count: 2),
                                      spacing: ChatCards.gap + ChatCards.step * 2) {
                                ForEach(entries) { item in
                                    switch item {
                                    case .chat(let chat):
                                        ChatHistoryCard(browser: browser, chat: chat, below: Self.below(chat, in: list), done: done,
                                                        badge: projects.project(chat.project))
                                    case .project(let project, let latest):
                                        ProjectListCard(browser: browser, project: project, latest: latest)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, ChatCards.step * 2)
                            .padding(.bottom, 6)
                        }
                    }
                    if all.isEmpty, rows.isEmpty, !words.isEmpty || archive || unreadOnly || projects.pinned.isEmpty {
                        Text(!words.isEmpty ? "No chat says that" : archive ? "Chats you archive come here and stay." : unreadOnly ? "No new answers." : "Your chats with agents come here. Untouched ones go to Archived Chats after a while; pinned ones stay.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    }
                }
                // Rows reach the column's sides, as Messages' do.
                .padding(.bottom, 12)
            }
            .scrollPosition($place)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in ChatCards.offset = y }
            .contentMargins(.top, Self.top, for: .scrollContent)
            .contentMargins(.top, Self.top - 6, for: .scrollIndicators)
            // Going up under the search and the head the cards show through
            // a little, dimmed and blurred, and come clear a little past
            // them, as the tabs' column has its rows (ColumnFade, ColumnBlur).
            .modifier(OwnScrollEdges())
            .modifier(ColumnScrolled(ends: ends))
            // Under the list's name and buttons too, as Settings' pages go
            // under its titlebar over the search.
            .mask { ColumnFade(ends: ends, top: Self.under, foot: false) }
            .overlay { ColumnBlur(ends: ends, top: Self.under, foot: false, grain: 0) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatCards.space)) } action: { frame in
                // A card under the search has nowhere to zoom from.
                ChatCards.shown = (frame.minY + Self.under)...max(frame.minY + Self.under, frame.maxY)
                ChatCards.width = frame.width
            }
            // Settings' search: a capsule of glass, its mark, the words and a clear.
            HStack(spacing: 6) {
                Symbol("magnifyingglass", size: 12)
                    .foregroundStyle(.secondary)
                TextField("Search chats\u{2026}", text: $words)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onExitCommand { words = "" }
                if !words.isEmpty {
                    Button { words = "" } label: {
                        Symbol("xmark.circle.fill", size: 12)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                if #available(macOS 26.0, *), !reduceTransparency {
                    Color.clear.glassEffect(.regular, in: .capsule)
                } else {
                    Capsule().fill(.regularMaterial)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .padding(.top, ChatHead.listHeight)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { ChatSwipe.shared.watch() }
        .onDisappear { ChatSwipe.shared.unwatch() }
    }

    /// The rows drawn under it in its group, for Archive Below.
    private static func below(_ chat: Chat, in list: [Chat]) -> ArraySlice<Chat> {
        guard let at = list.firstIndex(where: { $0.id == chat.id }) else { return [] }
        return list[(at + 1)...]
    }
}

/// On a space's look the column takes the light or dark of the color it
/// stands on, as the tabs' column does (Tone): a dark space in a light
/// window had dark words on the page's white veiled over the color, a gray
/// slab beside a dark column of white words (#374). Only the light or dark,
/// not the tone itself: on the site's color a switch of tabs draws the
/// column again only when the site's light or dark changes (#186).
private struct ChatColumnScheme: ViewModifier {
    let browser: Browser
    @Environment(\.colorScheme) private var window

    func body(content: Content) -> some View {
        content.environment(\.colorScheme, scheme ?? window)
    }

    private var scheme: ColorScheme? {
        let prefs = browser.prefs
        guard prefs.backdrop != .none else { return nil }
        let dark = window == .dark
        let swatch = Tone(prefs.swatch.color(dark: dark, custom: prefs.backdropColor), lifted: true, glass: prefs.wearsGlass)
        guard prefs.backdrop == .site, !prefs.wearsGlass else { return swatch.scheme }
        let site = browser.worn.color.map { Tone($0, lifted: true) }
        return (Worn<EmptyView>.worn(site, mode: .site, dark: dark) ? site : swatch)?.scheme
    }
}

/// The column's ground. On a space's look it lets the look through, its
/// color, grain and drawings, under a veil of the page's ground deep enough
/// for the words: on the page's own plate it was a gray slab beside a
/// column in the space's colors. With no look it is the page's plate.
private struct ChatColumnGround: View {
    let browser: Browser
    /// How much of the page's ground lies over the look.
    static let veil: CGFloat = 0.55

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
        if browser.prefs.backdrop != .none {
            shape.fill(Palette.ground.opacity(Self.veil))
                .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1)) // design: the column is a see-through surface on the look, not a card
        } else {
            HUD.plate(Radius.surface, surface: .page)
        }
    }
}

/// A folded group's heading: its name, how many, a chevron.
private struct ChatGroupHead: View {
    let group: ChatCards.Group
    let count: Int
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(group.title)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 12))
                Spacer(minLength: 0)
                Symbol(open ? "chevron.down" : "chevron.right", size: 11)
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "open" : "folded")
    }
}

/// A chat's card in Liquid Glass, a little of the space's own color in it,
/// as the column's glass wears it (Look); its ground and a wash of the ink
/// where there is no glass.
private struct ChatCardGround<Card: Shape>: View {
    let browser: Browser
    let shape: Card
    let over: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if #available(macOS 26.0, *), LiquidGlass.wanted {
            let space = Color(nsColor: browser.prefs.swatch.color(dark: scheme == .dark, custom: browser.prefs.backdropColor))
            Color.clear
                .glassEffect(.regular.tint(space.opacity(scheme == .dark ? 0.22 : 0.14)).interactive(), in: shape)
                .overlay(shape.fill(Palette.ink.opacity(over ? 0.04 : 0)))
        } else {
            shape.fill(Palette.ink.opacity(over ? 0.08 : 0.05))
                .background(Palette.ground, in: shape)
        }
    }
}

/// A chat's card, as the iPhone's: the sites its agent went to (or the
/// tabs it opened) and how many, else its agent's mark; the title in two
/// lines; the answer's start in three; when, at its foot. A chat that went
/// to sites lies on a stack: one sheet behind for one, two for three and
/// more. A chat in a project wears its circle on the mark.
private struct ChatHistoryCard: View {
    let browser: Browser
    let chat: Chat
    /// The cards drawn under it, for Archive Below.
    let below: ArraySlice<Chat>
    let done: () -> Void
    /// Its project, where it shows outside it.
    var badge: Project?
    @State private var over = false

    /// The sites the chat's agent worked on, in the order it came to them,
    /// worked out once for each length of the chat.
    @MainActor private static var sitesKept: [String: (count: Int, hosts: [String])] = [:]

    private var marks: (hosts: [String], words: String)? {
        if !chat.tabs.isEmpty {
            let hosts = chat.tabs.compactMap { URL(string: $0.url)?.host().map(StepWords.bare) }
            return (hosts, chat.tabs.count == 1 ? "1 tab" : "\(chat.tabs.count) tabs")
        }
        let hosts: [String]
        if let kept = Self.sitesKept[chat.id], kept.count == chat.items.count {
            hosts = kept.hosts
        } else {
            hosts = ChatSteps.hosts(chat.items)
            Self.sitesKept[chat.id] = (chat.items.count, hosts)
        }
        guard !hosts.isEmpty else { return nil }
        return (hosts, hosts.count == 1 ? "1 site" : "\(hosts.count) sites")
    }

    var body: some View {
        let card = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        let marks = self.marks
        Button {
            browser.keepChat(chat.id)
            done()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    if let marks {
                        ForEach(Array(marks.hosts.prefix(3).enumerated()), id: \.offset) { _, host in
                            SiteMark(host: host, size: ChatCards.favicon)
                        }
                        Text(marks.words)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .padding(.leading, 2)
                    } else {
                        // A routine's chat wears its clock; any other, its agent's mark.
                        Symbol(Routines.shared.all.contains { $0.chat == chat.id } ? SettingsPage.agentRoutines.icon : FieldAnswer.mark(chat.cli), size: 15)
                            .foregroundStyle(Palette.muted)
                            .frame(width: ChatCards.icon, height: ChatCards.icon)
                            .background(Palette.ink.opacity(0.08), in: Circle())
                    }
                    Spacer(minLength: 0)
                    if let badge {
                        ProjectCircle(project: badge, size: 18)
                            .accessibilityLabel("In " + badge.name)
                    }
                }
                .frame(height: ChatCards.icon, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(chat.title)
                        .font(.system(size: ChatZoomStage.cardType, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        // It flies to the chat's head and back (ChatZoom).
                        .modifier(ChatZoomVeiled(card: chat.id))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatCards.space)) } action: { frame in
                            ChatCards.titles[chat.id] = frame
                        }
                    if chat.pinned {
                        Symbol("pin.fill", size: 9)
                            .foregroundStyle(Palette.muted)
                    }
                    if chat.unread == true {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                            .accessibilityLabel("New")
                    }
                }
                let gist = chat.preview
                if !gist.isEmpty {
                    Text(gist)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                let working = Agents.shared.session(chat.id)?.state.live == true
                Text(ChatListRows.when(chat.updated, working: working))
                    .font(.system(size: 11.5))
                    .foregroundStyle(working ? ChatListRows.workingInk : Palette.faint)
            }
            .padding(CardFrame.inset)
            .frame(maxWidth: .infinity, minHeight: ChatCards.height, alignment: .topLeading)
            .background { ChatCardGround(browser: browser, shape: card, over: over) }
            .background(alignment: .top) { stack(marks?.hosts.count ?? 0) }
            .contentShape(card)
            // Where the chat zooms out of, and back into.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatCards.space)) } action: { frame in
                ChatCards.frames[chat.id] = frame
            }
        }
        .buttonStyle(ChatCardPress(browser: browser, id: chat.id))
        .onHover { over = $0 }
        // Dragged onto a project's circle, it goes in (ChatMoves.drop).
        .onDrag { ChatMoves.dragged(chat) }
        .steadyMenu(actions: true) { ChatHistoryRow.menu(chat, below: below, browser: browser, done: done) }
    }

    /// The sheets showing above the card: one for a site, two for three and more.
    private func stack(_ sites: Int) -> some View {
        let count = sites == 0 ? 0 : sites >= 3 ? 2 : 1
        let step = ChatCards.step
        return ZStack(alignment: .top) {
            ForEach((0..<count).reversed(), id: \.self) { i in
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.ink.opacity(i == 0 ? 0.08 : 0.05))
                    .frame(height: 40)
                    .padding(.horizontal, CGFloat(count - i) * 0 + CGFloat(i + 1) * 8)
                    .offset(y: -step * CGFloat(i + 1))
            }
        }
        .allowsHitTesting(false)
    }
}

/// A project among the cards: its circle where a chat has its mark, its
/// name, what its latest chat said, when it moved.
private struct ProjectListCard: View {
    let browser: Browser
    let project: Project
    let latest: Chat?
    @ObservedObject private var chats = Chats.shared
    @State private var over = false
    @State private var dropping = false

    var body: some View {
        let card = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        let mine = chats.of(project: project.id)
        let working = mine.contains { Agents.shared.session($0.id)?.state.live == true }
        let unread = mine.contains { $0.unread == true }
        Button {
            browser.openProject(project.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ProjectCircle(project: project, size: ChatCards.icon)
                    .frame(height: ChatCards.icon, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(project.name)
                        .font(.system(size: ChatZoomStage.cardType, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if unread {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                            .accessibilityLabel("New")
                    }
                }
                Text(ProjectListRow.preview(latest))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text(ChatListRows.when(max(project.updated, latest?.updated ?? project.updated), working: working))
                    .font(.system(size: 11.5))
                    .foregroundStyle(working ? ChatListRows.workingInk : Palette.faint)
            }
            .padding(CardFrame.inset)
            .frame(maxWidth: .infinity, minHeight: ChatCards.height, alignment: .topLeading)
            .background { ChatCardGround(browser: browser, shape: card, over: over || dropping) }
            .contentShape(card)
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
        .takesChats(into: project.id, over: $dropping)
        .accessibilityLabel("Project " + project.name)
    }
}

/// A chat's row, as Messages has one: its face (the first site its agent
/// went to, else its agent's mark), its name and when, two lines of its
/// answer, a blue dot when it has an answer not yet seen.
struct ChatHistoryRow: View {
    let browser: Browser
    let chat: Chat
    /// The rows drawn under it, for Archive Below.
    let below: ArraySlice<Chat>
    let done: () -> Void
    /// Its project's circle on its face, where it shows outside it.
    var badge = false
    @State private var over = false
    @ObservedObject private var swipe = ChatSwipe.shared
    /// Its own view, for the fingers across it (ChatSwipe).
    @State private var anchor = ChatViewAnchor()

    var body: some View {
        // Slid by two fingers: Project, Pin and Archive under it (ChatSwipe).
        let slid = swipe.id == chat.id ? swipe.offset : 0
        ZStack(alignment: .trailing) {
            if slid < 0 { ChatSwipeActions(browser: browser, chat: chat, shown: -slid) }
            row.offset(x: slid)
        }
        .clipped()
        .background(ChatProjectAnchorView(box: anchor))
        .onAppear { ChatSwipe.shared.rows[chat.id] = anchor }
        .onDisappear { if ChatSwipe.shared.rows[chat.id] === anchor { ChatSwipe.shared.rows[chat.id] = nil } }
    }

    private var row: some View {
        Button {
            if ChatSwipe.shared.id != nil { ChatSwipe.shared.shut(); return }
            browser.keepChat(chat.id)
            done()
        } label: {
            let working = Agents.shared.session(chat.id)?.state.live == true
            ChatListRowBody(title: chat.title, when: ChatListRows.when(chat.updated, working: working), working: working,
                            preview: chat.preview, unread: chat.unread == true, pinned: chat.pinned, zoom: chat.id) {
                ChatAvatar(chat: chat, size: ChatListRows.face, badge: badge)
            }
            .background(Palette.ink.opacity(over ? 0.05 : 0))
            // Where the chat zooms out of, and back into.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatCards.space)) } action: { frame in
                ChatCards.frames[chat.id] = frame
            }
        }
        .buttonStyle(ChatCardPress(browser: browser, id: chat.id))
        .onHover { over = $0 }
        // Dragged onto a project's circle or row, it goes in (ChatMoves.drop).
        .onDrag { ChatMoves.dragged(chat) }
        .steadyMenu(actions: true) { Self.menu(chat, below: below, browser: browser, done: done) }
    }

    /// As ⌘T's Chats offers them: open, copy, keep, stop, delete.
    @ViewBuilder
    static func menu(_ chat: Chat, below: ArraySlice<Chat>, browser: Browser, done: @escaping () -> Void) -> some View {
        let live = Agents.shared.session(chat.id)?.state.live == true
        Button("Open Chat", mark: "yab.chat") {
            browser.keepChat(chat.id)
            done()
        }
        if !chat.answer.isEmpty {
            Button(chat.copyTitle, mark: "yab.copyframe.text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chat.copiedAnswer, forType: .string)
            }
        }
        Divider()
        // Read as it is now, not as the row was drawn.
        Button(chat.pinned ? "Unpin Chat" : "Pin Chat", mark: chat.pinned ? "pin.slash" : "pin") {
            let kept = Chats.shared.chat(chat.id)?.pinned ?? chat.pinned
            Chats.shared.pin(chat.id, !kept)
        }
        if !live, !chat.answer.isEmpty {
            Button("Save as Tool…", mark: "yab.cmd.plus") {
                browser.keepChat(chat.id); done()
                Agents.shared.followUp(chat.id, BoostLearning.prompt)
            }
        }
        ChatMoveMenu(browser: browser, chat: Chats.shared.chat(chat.id) ?? chat)
        Button("Rename Chat\u{2026}", mark: "pencil") { ChatQuestions.rename(chat) }
        if chat.archived == true {
            Button("Unarchive", mark: "yab.archive.up") { Chats.shared.archive(chat.id, false) }
        } else {
            Button("Archive\u{2026}", mark: "yab.archive") {
                ChatQuestions.archive(chat) {
                    if browser.chatPinned == chat.id { browser.chatPinned = nil }
                    Chats.shared.archive(chat.id, true)
                }
            }
            if below.contains(where: ChatHistoryRow.archivable) {
                Button("Archive Below\u{2026}", mark: "yab.archive.down") {
                    let under = below.compactMap { Chats.shared.chat($0.id) }.filter(ChatHistoryRow.archivable)
                    guard !under.isEmpty else { return }
                    ChatQuestions.archive(below: under.count) {
                        for chat in under {
                            if browser.chatPinned == chat.id { browser.chatPinned = nil }
                            Chats.shared.archive(chat.id, true)
                        }
                    }
                }
            }
        }
        if live {
            Button("Stop", mark: "stop") { _ = Agents.shared.stop(chat.id) }
        }
        Divider()
        Button("Delete Chat\u{2026}", mark: "trash", role: .destructive) {
            ChatQuestions.delete(chat) {
                browser.deleteChat(chat.id)
            }
        }
        .disabled(live)
    }

    /// What Archive Below puts away: not one kept for good, nor one still working.
    static func archivable(_ chat: Chat) -> Bool {
        !chat.pinned && chat.archived != true && Agents.shared.session(chat.id)?.state.live != true
    }

}

/// A row of a small list: the control's tint under the pointer.
struct ChatMenuRow: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var over = false

        var body: some View {
            configuration.label
                .background(Palette.ink.opacity(configuration.isPressed ? 0.08 : over ? 0.05 : 0),
                            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .onHover { over = $0 }
        }
    }
}

// MARK: - carrying on

extension Agents {
    /// A queued message taken back before it was sent, and its words with it
    /// (the last of `saying` are the queue's, in order).
    func unqueue(_ id: String, at index: Int) {
        guard let session = session(id), session.queue.indices.contains(index) else { return }
        let words = session.saying.count - session.queue.count + index
        if session.saying.indices.contains(words) { session.saying.remove(at: words) }
        session.queue.remove(at: index)
        objectWillChange.send()
    }

    /// Your words for a chat from its column: into the turn going on, or,
    /// once it is over, a turn of their own, the way the chat began.
    func followUp(_ id: String, _ words: String, about tab: Tab? = nil, with attached: [ChatAttachment] = [], queue later: Bool = false) {
        guard followUpProblem(id) == nil else { return }
        // What it was pointed at: said in the message, the words shown alone.
        var tabs = browser.map { ChatAttachment.tabs(attached, in: $0) } ?? []
        if let tab, !tabs.contains(where: { $0.id == tab.id }) { tabs.insert(tab, at: 0) }
        let quotes = attached.compactMap(\.quote)
        let mail = attached.compactMap(\.mail).map(MailChat.filled)
        let folders = attached.compactMap(\.folder).compactMap { id in browser?.nests.first { $0.id == id } }
        let given = ChatAttachment.said(tabs: tabs, files: attached.compactMap(\.file), quotes: quotes, mail: mail, folders: folders, in: browser)
        let message = given + (words.isEmpty ? ChatAttachment.noWords : words)
        let carried = ChatAttachment.labels(tabs: tabs, files: attached.compactMap(\.file), quotes: quotes, mail: mail, folders: folders, in: browser)
        let sent = tabs.map { ChatAttachment.tab($0.id) } + attached.filter { if case .tab = $0 { return false } else { return true } }
        // Asleep, its page loads while the agent starts: read by a tool
        // before it had, it was empty.
        for tab in tabs where tab.asleep { tab.wake() }
        if let root = session(root(of: id)) { MailChat.took(mail, by: root) }
        // The tabs it went with are what this message is about: the chat's
        // target from now on (native_context's taskTargets), and its to
        // work in without a "use this tab?" first, as a new chat's are.
        // Left on the page the chat began on, the agent went back there.
        if let first = tabs.first, let target = session(id) ?? revive(id) {
            for tab in tabs {
                tab.allowed.insert(target.id)
                if let top = root(of: id) { tab.allowed.insert(top) }
            }
            target.nativeOriginTab = first.id
            session(root(of: id))?.nativeOriginTab = first.id
        }
        if let session = session(id), session.state.live {
            // The queue's words are the last of `saying`: a message sent now
            // is heard back before them, so it goes ahead of them. Cursor
            // queues a steer too, after the rest.
            let waiting = later || session.cursor != nil ? 0 : session.queue.count
            session.saying.insert(words, at: max(0, session.saying.count - waiting))
            session.carrying.insert(carried, at: max(0, session.carrying.count - waiting))
            session.attaching.insert(sent, at: max(0, session.attaching.count - waiting))
            if later { queue(id, message) } else { _ = steer(id, message) }
            return
        }
        let session = session(id) ?? revive(id)
        guard let session else { return }
        if session.task {
            // Your words alone in the quote; what went with them, after it.
            refine(session, words.isEmpty ? ChatAttachment.noWords : words, given: given, about: tabs)
            // Its chat shows your words, not the tab said around them.
            if !session.saying.isEmpty { session.saying[session.saying.count - 1] = words }
            session.carrying.append(carried)
            session.attaching.append(sent)
            return
        }
        session.saying.append(words)
        session.carrying.append(carried)
        session.attaching.append(sent)
        _ = run(prompt: message, cli: session.cli, model: session.model, effort: session.effort,
                access: session.textOnly ? "text" : session.full ? "full" : "browser",
                quiet: session.quiet, name: session.quiet ? session.name : nil, resume: session.id)
    }

    /// One of your earlier messages said again in other words: the chat
    /// is cut where it stood, and the words go as a new turn from there.
    /// Neither agent can take back what its own conversation was told
    /// after that point (Codex can't rewind a thread; Claude Code only
    /// forks one whole), so the turn starts a new conversation, told the
    /// turns before it in words (conversation), as a chat carried on by
    /// the other agent is. What the message went with stays behind.
    func edit(_ id: String, from item: String, to words: String) {
        guard followUpProblem(id) == nil, let session = session(id) ?? revive(id), !session.state.live,
              let at = session.items.firstIndex(where: { $0.id == item && $0.kind == .asked }) else { return }
        let before = Array(session.items[..<at])
        let earlier = Agents.conversation(before, by: AgentModels.agentName(session.cli))
        session.items = before
        session.asked = before.filter { $0.kind == .asked }.map(\.text)
        session.result = before.last { $0.kind == .message && !$0.isAside && !$0.isNote }?.text ?? ""
        session.earlier = ""
        session.saying = []
        session.carrying = []
        session.attaching = []
        session.queue = []
        session.thread = nil
        session.read = false
        // The first message of a task in tabs of its own: that task asked anew.
        let fresh = session.task && session.origin == .newTabs
            ? Agents.newTabsPrompt(words, seen: browser.map(Agents.spaceLine) ?? "", pointed: false,
                                 bypass: browser?.prefs.agentsAsking == .bypass) : words
        let message = earlier.isEmpty ? fresh : """
        The person edited one of their messages in this chat, so it goes on from there. What came before it:

        \(earlier)

        Their message now, in their own words: «\(words)»
        """
        if session.task {
            session.progress = "Updating"
            session.asked.append(words)
        }
        session.saying.append(words)
        session.carrying.append([])
        session.attaching.append([])
        Chats.shared.keep(chat(of: session))
        _ = run(prompt: message, cli: session.cli, model: session.model, effort: session.effort,
                access: session.textOnly ? "text" : session.full ? "full" : "browser",
                quiet: session.quiet, name: session.quiet ? session.name : nil, resume: session.id)
        objectWillChange.send()
    }

    /// The composer checks before taking its draft, and other callers before
    /// adding a turn that the read-only task cannot receive.
    func followUpProblem(_ id: String) -> String? {
        remoteTaskOrigin(id) == nil ? nil : "This iPhone task cannot take follow-ups. Start a new chat with these words."
    }
}
