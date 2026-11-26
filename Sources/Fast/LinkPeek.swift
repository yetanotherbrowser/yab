import AppKit
import Combine
import SwiftUI
import WebKit

// A look at a link, Arc's way: shift-click it, or follow a link to another
// site from a pin or a kept tab, and its page comes up over the one you are reading,
// which stays where it was underneath, dimmed. Escape, ⌘W, a click on the
// dimmed page, the cross or a pinch in puts it away;
// ⌘O, the other button or a pinch out keeps it, as a tab beside yours,
// loaded as it is. A pinch moves the panel with the fingers, a few percent,
// and lets go past a sixth either way, or springs back (PeekView.pinched).
//
// The page is a tab like a small window's (LinkWindow), only not in the row
// (Browser.outside): signed in wherever you are, private from a private
// tab, and keeping it moves that very page into the row, nothing loaded
// twice.
//
// It belongs to the tab it was opened over: another tab picked, it is put
// by with that tab's page, in the same frame, and it is back at once when
// the tab is, asleep with it and closed with it. The tab's mark wears the
// peeked site's icon meanwhile (PeekMark), so what is waiting where shows.
//
// Made the way the small window is: in AppKit, moved by Core Animation on the
// render server, and nothing in SwiftUI drawn again for it. The page is laid
// out once, at the panel's size, before it loads; it shows once it has drawn,
// so a dark window never flashes white; and kept, a picture of it grows from
// the panel to the stage while the page itself is moved and made the stage's
// size under it, where WebKit's pause for the new size is never seen.
//
// It grows out of what was clicked, a word or a card (PeekOrigin), and goes
// back into it when put away, if that is still there to be seen: only the
// holder's layers move, the page inside laid out once all the same. Landed,
// the link itself bumps once, so where the page went shows.
//
// A Force Click on a link, pressed on past the click, peeks at it too: the
// Mac's own look at the link is held back, and the click that ends the
// press never reaches the page underneath. The page dims as the press
// firms up on a link, before the peek comes (Browser.pressPeek).
//
// There is no switch for it, as Arc has none: a ⌘-click still opens a tab.
//
// An agent's tab of mail's space comes up the same way from its task's row
// in the column (MailTaskRows), only live: the very tab, never loaded
// again, its dock at the foot while the agent works. Put away, it goes on
// working where it was; kept, it is the tab in front, Back to Mail over it.

/// The requested click modifier, independent of keyboard commands and
/// the field's Option-Return. Shift stays the default.
enum PeekClick: String, Sendable {
    case shift, option
    static let key = "peek.click-modifier"

    nonisolated var flags: NSEvent.ModifierFlags { self == .option ? .option : .shift }

    nonisolated static func read(in store: UserDefaults) -> Self {
        store.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .shift
    }

    nonisolated func save(in store: UserDefaults) { store.set(rawValue, forKey: Self.key) }
}

extension Browser {
    /// Whether a link was clicked with the middle button, from the
    /// `buttonNumber` WebKit gives its navigation action. On the Mac that is
    /// a mask of the buttons, as `NSEvent.pressedMouseButtons` is: 1 the
    /// left, 2 the right, 4 the middle. It is not the number
    /// `NSEvent.buttonNumber` gives the same button, which is 2: asked for
    /// that, a middle click was never seen, and its link opened in the tab
    /// itself (feedback #79). Measured by evals/middle-click/webkit_probe.swift.
    nonisolated static func middleClick(_ buttonNumber: Int) -> Bool { buttonNumber & 4 != 0 }

    /// Whether `url` is an OAuth, SSO, or sign-in flow whose `sessionStorage`
    /// state lives in the tab that started it. Opening it in a fresh Peek tab
    /// strands that state across the redirect back to the site.
    static func isOAuthOrSignIn(_ url: URL) -> Bool {
        if Diary.isSignIn(url) { return true }
        let path = url.path().lowercased()
        if path.hasPrefix("/__/auth/") { return true }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let names = Set(items.map { $0.name.lowercased() })
        if names.contains("samlrequest") { return true }
        return names.contains("client_id") && (names.contains("redirect_uri") || names.contains("response_type"))
    }

    /// A plain link from a pin or a kept tab previews another site; links within its site
    /// keep navigating there. OAuth and sign-in flows stay in the tab so `sessionStorage`
    /// survives the redirect back. Shift-click previews from any tab. A middle
    /// click never previews: it opens a tab, as a ⌘-click does.
    static func shouldPeek(_ destination: URL, from address: URL?, pinned: Bool,
                           flags: NSEvent.ModifierFlags, button: Int, peekClick: PeekClick = .shift) -> Bool {
        guard !middleClick(button) else { return false }
        if flags == peekClick.flags { return true }
        guard flags.isEmpty, pinned, let address,
              ["http", "https"].contains(address.scheme?.lowercased() ?? ""),
              let from = address.host(), let to = destination.host() else { return false }
        guard Vault.registrable(from) != Vault.registrable(to) else { return false }
        return !isOAuthOrSignIn(destination)
    }

    /// Shift-click on a link in a tab of yours.
    func peek(_ url: URL, from source: Tab) {
        // A meeting is never a peek, one Escape from hanging up: a tab of
        // its own, or the one it already has.
        if CallLink.isCall(url) {
            if !openCall(url) { open(url, foreground: true, from: source) }
            return
        }
        dropPeek(of: source)
        Teach.shared.used(.peek)
        let inFront = source.id == activeID
        let preview = inFront ? peekView.map { linkCard.take(url, from: source, over: $0) } : nil
        // An agent's published page: Yab's copy, in a view with no cookies (ArtifactPages).
        let page = preview?.page ?? (ArtifactPages.isPage(url)
            ? Tab(shy: source.shy, configuration: ArtifactPages.configuration())
            : source.shy
            ? Tab(shy: true, configuration: Web.configuration(shy: true, store: source.store))
            : takeSpareForPeek(url) ?? blankTab())
        page.from = source.id
        linkBack(page, to: source)
        prepare(page)
        outside.append(page)
        source.peek = page
        // An agent may click in a tab of yours behind the current one.
        // Keep its peek with that tab; followPeek presents it when selected.
        // Neither the current page nor its own peek belongs to that click.
        guard inFront else {
            page.go(to: url)
            return
        }
        guard let view = peekView, view.window != nil else {
            // Nowhere to show it: a tab of its own, as a ⌘-click.
            source.peek = nil
            outside.removeAll { $0.id == page.id }
            page.close()
            open(url, foreground: true, from: source)
            return
        }
        peeking = page
        peekFrom = source.id
        source.peek = page
        view.present(page, shy: source.shy, from: source.builtPage, origin: preview?.origin)
        if preview?.page == nil { page.go(to: url) }
        else if preview?.finished == true {
            // Its hover finished outside Browser. Only the deliberate
            // click now gives it the usual icon, history and page hooks.
            if let web = page.webKitOnly("WebKit peek transition", build: false) { webView(web, didFinish: nil) }
        }
    }

    /// A Force Click in a tab of yours, `point` in its page's view: a peek
    /// at the link under it, when there is one.
    func forcePeek(on source: Tab, at point: CGPoint) {
        guard !source.bench, tabs.contains(where: { $0 === source }),
              let web = source.builtPage, web.magnification == 1 else { return }
        let js = "window.__yabPeekForce && __yabPeekForce(\(point.x), \(point.y), \(web.bounds.width))"
        let input = web as? ChromiumPage
        let press = input?.beginForceClick()
        web.run(js, in: .yab) { [weak self, weak source, weak input] result in
            var handled = false
            defer { if let press { input?.finishForceClick(press, handled: handled) } }
            guard let self, let source, case .success(let value) = result,
                  let href = value as? String, let url = URL(string: href) else {
                self?.peekView?.press(0)
                return
            }
            handled = true
            peek(url, from: source)
        }
    }

    /// A press on a link firming up towards a Force Click: the page dims
    /// with it, so the peek is felt coming before it comes, as Radian does.
    /// Only past half way, so an ordinary click never flickers, and only on
    /// a link: the page is asked once a press, as it passes half way,
    /// whether it went down on one (PeekOrigin's script keeps the link a
    /// press went down on; the pointer's hover isn't asked, which a
    /// pointer that never moved doesn't have).
    func pressPeek(on source: Tab, _ amount: CGFloat) {
        guard let view = peekView else { return }
        guard amount > 0 else {
            view.pressLink = nil
            view.pressAmount = 0
            view.press(0)
            return
        }
        guard source.id == activeID, peeking == nil, !source.bench, let web = source.builtPage, web.magnification == 1 else { return }
        view.pressAmount = amount
        switch view.pressLink {
        case true?:
            view.press((amount - 0.5) / 0.5)
        case false?:
            return
        case nil:
            guard amount > 0.5 else { return }
            // Asked: not a link until the page says it is.
            view.pressLink = false
            web.run("window.__yabPeekFrom && __yabPeekFrom(true)", in: .yab) { [weak view] result in
                guard let view, case .success(let value) = result, value is [NSNumber], view.pressAmount > 0 else { return }
                view.pressLink = true
                view.press((view.pressAmount - 0.5) / 0.5)
            }
        }
    }

    /// One of the row's own tabs over the page in front: an agent's, from
    /// its task in mail's column. Closing it never closes the tab.
    func peekLive(_ tab: Tab) {
        guard tabs.contains(where: { $0 === tab }), activeID != tab.id, let source = active,
              let view = peekView, view.window != nil else { return select(tab) }
        dropPeek(of: source)
        if let shown = peeking, shown !== tab, isLive(shown) { settleLive(shown) }
        _ = tab.wake()
        peeking = tab
        peekFrom = source.id
        view.present(tab, shy: source.shy, live: true)
        // In sight now: what it left unread is read, a beat later.
        DispatchQueue.main.async { AgentFeed.shared.lookAround() }
    }

    /// A peek of one of the row's own tabs (peekLive), not a page of its own.
    func isLive(_ page: Tab) -> Bool { tabs.contains { $0 === page } }

    /// Out of the peek and back to how a tab not in front is: its page out of
    /// any window until the stage takes it, whole, as a peek's flight out
    /// left it faded.
    private func settleLive(_ page: Tab) {
        guard let web = page.builtPage else { return }
        web.autoresizingMask = []
        if web.superview?.window != nil, !stages.contains(page.id) { web.removeFromSuperview() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        web.alphaValue = 1
        web.layer?.opacity = 1
        CATransaction.commit()
    }

    /// The tab the peek on screen was opened from.
    var peekSource: Tab? { peekFrom.flatMap { id in tabs.first { $0.id == id } } }
    /// Opened over mail's page, from a link in a mail.
    var peekFromMail: Bool { MailPage.isMail(peekSource?.address) }

    /// Put away: back into the link it came from, or faded where the link
    /// is gone, and the page goes once it has.
    func closePeek() {
        guard let page = peeking else { return }
        let source = peekSource
        peeking = nil
        peekFrom = nil
        if isLive(page) {
            // It goes on where it was; out of sight, so a beat's read is cut short.
            let done = { [weak self] in
                self?.settleLive(page)
                AgentFeed.shared.lookAround()
            }
            guard let view = peekView else { return done() }
            return view.dismiss(done)
        }
        source?.peek = nil
        guard let view = peekView else { return letGo(outside: page) }
        view.dismiss(to: source?.builtPage) { [weak self] in self?.letGo(outside: page) }
    }

    /// Put by with its tab: off the screen in the same frame the page is,
    /// the page kept, its tab's mark still wearing it.
    func hidePeek() {
        guard let page = peeking else { return }
        peeking = nil
        peekFrom = nil
        // One of the row's own: nothing to come back to, it is a tab.
        if isLive(page) {
            peekView?.drop()
            return settleLive(page)
        }
        peekView?.hide(page)
    }

    /// The tab in front changed: the one left keeps its peek, and the one
    /// arrived at has its own back at once, as its page is, with no second
    /// coming. Switching tabs is too common a thing to move anything for.
    func followPeek() {
        // A mail over the page left behind: put away, kept when it is yours.
        closeMailto()
        hidePeek()
        guard let source = active, let page = source.peek, let view = peekView, view.window != nil else { return }
        let woke = page.wake()
        peeking = page
        peekFrom = source.id
        view.present(page, shy: source.shy, instant: !woke)
    }

    /// A tab going, and its peek with it, shown or waiting.
    func dropPeek(of tab: Tab) {
        if mailtoFrom == tab.id || threadPeek?.from == tab.id { closeMailto() }
        // Itself up live (peekLive), going: the panel with it.
        if peeking === tab, isLive(tab) {
            peeking = nil
            peekFrom = nil
            peekView?.drop()
            settleLive(tab)
        }
        guard let page = tab.peek else { return }
        tab.peek = nil
        peekView?.forget(page.id)
        if peeking === page {
            peeking = nil
            peekFrom = nil
            peekView?.drop()
        }
        letGo(outside: page)
    }

    /// Beside the page it was opened over, in split view: the picture flies
    /// to the half it will take, and the two come together under it. From a
    /// pin, a kept tab or one in a folder of yours, where most peeks come
    /// from, a copy of that page takes the other half as split() carries
    /// one, as Arc does. A page that can't have another beside it, one of a
    /// pair already, mail's, an agent's, is kept as a tab instead.
    func splitPeek() {
        // No room for two halves: the peek stays as it is.
        guard splitFits else { return }
        guard let page = peeking, !isLive(page), let source = peekSource,
              !source.bench, !MailPage.isMail(source.address), pair(of: source.id) == nil, !Folders.shared.theirs(source)
        else { return keepPeek() }
        // The mark goes as the picture flies: the new tab says where it went.
        // The peek is down from the press on, as keepPeek's is.
        source.peek = nil
        peeking = nil
        peekFrom = nil
        let done = { [weak self] in
            guard let self else { return }
            page.page.autoresizingMask = []
            outside.removeAll { $0.id == page.id }
            var row = tabs
            let at = (row.firstIndex { $0.id == source.id } ?? row.count - 1) + 1
            row.insert(page, at: at)
            lay(row)
            split(page, with: source)
            // Refused after all: the page in front as a tab, never left
            // behind the one it was opened over as if nothing happened.
            if pair(of: page.id) == nil { select(page) }
        }
        guard let view = peekView else { return done() }
        view.keep(page, half: true, landed: done)
    }

    /// How tall an address bar a page kept from a peek will stand under, as
    /// `barShown` will have it once the page is in front: a half always has one.
    func barOver(kept tab: Tab, half: Bool, carded: Bool) -> CGFloat {
        let shown = half || (!tab.isBlank && !tab.showsMail && (prefs.addressBar || tab.isDev))
        return shown ? AddressBar.height(sidebar: prefs.sidebar, carded: carded) : 0
    }

    /// Kept: the page, as a picture, grows from the panel to the stage, and
    /// arrives there as a tab beside the one it was opened from.
    func keepPeek() {
        guard let page = peeking else { return }
        // One of the row's own: in front, from the panel, where it is already.
        if isLive(page) {
            openedTasks.insert(page.id)
            guard let view = peekView else {
                peeking = nil
                peekFrom = nil
                return select(page)
            }
            return view.keep(page) { [weak self] in
                guard let self else { return }
                peeking = nil
                peekFrom = nil
                page.page.autoresizingMask = []
                select(page)
            }
        }
        // A site a rule keeps in another space opens there, as Arc's Peek
        // opens by its Air Traffic Control (LinkRoutes); the peek goes.
        if let url = page.address ?? page.pending, let source = peekSource,
           LinkRoutes.shared.pageLinkSpace(for: url, from: source, in: self) != nil {
            closePeek()
            routePageLink(url, from: source, foreground: true)
            return
        }
        // Down from the press on, as Chromium's tab strip takes a WebContents
        // the moment it is moved: the picture's flight only shows it. A peek
        // still up while that picture was coming took a second press, an
        // Escape or a new peek for its own, and the flight's end then put a
        // page let go meanwhile in the row, a blank tab (register 2538).
        peekSource?.peek = nil
        peeking = nil
        peekFrom = nil
        guard let view = peekView else { return takeIn(page) }
        view.keep(page) { [weak self] in
            page.page.autoresizingMask = []
            self?.takeIn(page)
        }
    }
}

/// ⌘F's bar over a peek's page (PeekView.showFind): the tab's FindBar, as
/// big as it is drawn, taken down the moment the bar is put away, by its
/// cross, Escape or anything else (#389).
final class PeekFindHost: NSView {
    private let host: NSHostingView<FindBar>
    private var watch: AnyCancellable?

    init(finder: Finder) {
        host = NSHostingView(rootView: FindBar(finder: finder) { finder.close() })
        let size = host.fittingSize
        host.sizingOptions = []
        super.init(frame: CGRect(origin: .zero, size: size.width > 0 && size.height > 0 ? size : CGSize(width: FindBar.width, height: 36)))
        wantsLayer = true
        host.frame = bounds
        addSubview(host)
        watch = finder.$shown.dropFirst().filter { !$0 }.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.removeFromSuperview() }
        }
    }

    required init?(coder: NSCoder) { nil }
}

/// Where the corner's notices stand while a peek is up: inside the peek's
/// own top right corner, so "Link copied" comes out of the page it is
/// about, from under the panel's top edge. The room from the page's top
/// right to the panel's, or nil with no peek. Apart from Browser, which
/// doesn't publish the peek: only the corner is drawn again for it.
final class PeekCorner: ObservableObject {
    @Published private(set) var inset: CGSize?

    func set(_ inset: CGSize?) {
        if self.inset != inset { self.inset = inset }
    }
}

/// The navigation doors observe the peek without redrawing the browser.
@MainActor
final class PeekFront: ObservableObject {
    @Published private(set) var page: Tab?

    func set(_ page: Tab?) {
        if self.page !== page { self.page = page }
    }
}

/// The corner's notices moved into a peek's (PeekCorner).
struct PeekCornerShift<Content: View>: View {
    @ObservedObject var corner: PeekCorner
    /// The page's address bar the corner hangs under, which the panel
    /// covers: under a peek the notice comes out of the panel's top edge,
    /// not from a line where the bar's foot would be, half way down it.
    var bar: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.top, corner.inset.map { $0.height - bar } ?? 0)
            .padding(.trailing, corner.inset?.width ?? 0)
    }
}

final class PeekView: NSView {
    weak var browser: Browser?
    let depth = PeekDepth()
    private var turns = 0
    /// The page dimmed round the panel, a layer and nothing more. Cut on
    /// the card's own outline (`Reshape.outline`), the curve the page's
    /// stage cuts it on, never a Core Animation corner radius, which is a
    /// slightly different curve (docs/page-corners.md).
    private let dim = CAShapeLayer()
    /// The panel: its shadow, the page's holder, and its two buttons.
    private var panel: NSView?
    /// The page's (PageHolder), or a mail's card (present(mail:)).
    private var holder: NSView?
    /// A new mail over the page (Browser.mailto) rather than a page: the
    /// card's view, and how tall it says it is.
    private var mail: NSView? {
        didSet { if mail == nil { mailOwner = nil } }
    }
    /// What draws the card (its hosting controller), kept while it is up.
    private var mailOwner: AnyObject?
    private var mailTall: CGFloat = 0
    private var corner: CGFloat = 0
    private var flatTop = false
    /// Showing, or on its way out: clicks are the peek's only while it is up.
    private var up = false {
        didSet {
            guard up != oldValue else { return }
            shareCorner()
            if !up { loading.bind(nil) }
        }
    }
    /// The peeked page taking its time (LoadBar), in the room over the
    /// panel: bare on the window's ground the card has drawn back from,
    /// on a plate only where the dimmed page, any site's, is under it.
    private let loading = LoadBar(frame: CGRect(origin: .zero, size: LoadBar.size))
    /// The panel's top as far from the window's top as the page's in its
    /// usual place: the card's margin above it counts, and only what it
    /// lacks is left over the panel inside the card. With the card in
    /// from the window's edge that is nothing, where the panel stood a
    /// second inset below the page's top.
    private var top: CGFloat { max(0, Backdrop.inset - depth.padding[1]) }
    /// The room over the panel up to the window's edge or the band above
    /// the card, its own and the card's margin: the load bar's.
    private var room: CGFloat { top + depth.padding[1] }
    /// Kept pages whose picture is still coming for their flight.
    private var keeping = 0
    /// The dim a firm press on a link has brought (press), for the peek to
    /// come on from rather than from nothing.
    private var pressed: Float = 0
    /// The press now under way (Browser.pressPeek): whether it went down
    /// on a link, nil until asked, and how firm it is.
    var pressLink: Bool?
    var pressAmount: CGFloat = 0
    /// A pinch over the panel under way: how far it has gone, and its last
    /// step, for a quick one to count as much as a long one.
    private var pinch: (sum: CGFloat, last: CGFloat)?
    /// The panel's scale while fingers hold it, 1 at rest: a flight out
    /// starts from where they left it.
    private var pinchScale: CGFloat = 1
    /// Let go by a pinch: the fingers did part of the way, the rest is quicker.
    private var brisk = false
    private var pinchWatch: Any?
    /// The panel of the peek last put by with its tab, hidden rather than
    /// taken down: picking that tab again shows it as it was, where building
    /// it anew, its buttons' SwiftUI host and all, held the main thread
    /// some 10 ms on each return.
    private var kept: (page: Tab.ID, panel: NSView, holder: PageHolder)?

    private static let buttons = PeekButtons.side
    /// The buttons' column, as tall as it is drawn: its size is set, never
    /// asked of SwiftUI while the panel moves. Two knobs or three, as
    /// PeekButtons shows them (no split for a look from a mail, or with no
    /// room for one): no room under the last takes a click (feedback #211).
    private var buttonsTall: CGFloat {
        let count: CGFloat = browser.map { $0.splitFits && !$0.peekFromMail } == true ? 3 : 2
        return count * PeekButtons.side + (count - 1) * PeekButtons.gap
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        dim.fillColor = NSColor.black.withAlphaComponent(0.16).cgColor
        dim.opacity = 0
        dim.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull(), "path": NSNull()]
        layer?.addSublayer(dim)
        addSubview(loading)
        depth.moved = { [weak self] in self?.plateLoading() }
    }

    /// The bar on a plate where its foot reaches down over the card: with
    /// no room over the card and the card not drawn back (Reduce Motion).
    /// Over the window's ground it is bare, as over a tab's card.
    private func plateLoading() {
        let foot = top - room / 2 + LoadBar.thick / 2
        loading.plated = foot > depth.topInset
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let pinchWatch { NSEvent.removeMonitor(pinchWatch) }
    }

    /// A pinch over the panel is the peek's, never the page's zoom: seen
    /// before WebKit's own recognizer can claim it, while this view is in
    /// a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, pinchWatch == nil {
            pinchWatch = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                MainActor.assumeIsolated { self?.pinched(event) == true ? nil : event }
            }
        } else if window == nil, let watch = pinchWatch {
            NSEvent.removeMonitor(watch)
            pinchWatch = nil
        }
    }

    /// Fingers on the panel: it scales with them, damped, and the dim
    /// thins as it shrinks. Let go past a sixth out it is kept, past a
    /// sixth in it goes home into its link, a quick flick past half that
    /// as well; short of that it springs back. Whether the event was the
    /// peek's.
    private func pinched(_ event: NSEvent) -> Bool {
        if pinch == nil {
            guard event.phase == .began, event.window === window, let panel,
                  panel.frame.contains(convert(event.locationInWindow, from: nil)), pinchStarts() else { return false }
        }
        switch event.phase {
        case .began, .changed: pinchStep(event.magnification)
        case .ended, .cancelled: pinchEnd(lifted: event.phase == .ended)
        default: break
        }
        return true
    }

    /// Whether a pinch may take the panel now: a page's, up and still.
    private func pinchStarts() -> Bool {
        guard up, keeping == 0, mail == nil, panel != nil else { return false }
        pinch = (0, 0)
        return true
    }

    private func pinchStep(_ step: CGFloat) {
        guard var now = pinch else { return }
        now.sum += step
        if step != 0 { now.last = step }
        pinch = now
        follow(now.sum)
    }

    /// `lifted`: the fingers came up, rather than the gesture called off.
    private func pinchEnd(lifted: Bool) {
        guard let now = pinch else { return }
        pinch = nil
        let ended = lifted && up && panel != nil
        if ended, now.sum > 0.15 || (now.sum > 0.06 && now.last > 0.02) {
            brisk = true
            browser?.keepPeek()
        } else if ended, now.sum < -0.15 || (now.sum < -0.06 && now.last < -0.02) {
            brisk = true
            browser?.closePeek()
        } else {
            springBack()
        }
    }

    /// For the bench: a pinch of `steps` even steps adding up to `sum`, a
    /// frame apart, then lifted, as the trackpad sends one. Whether it
    /// took, and the scale the panel was held at furthest from rest.
    func benchPinch(_ sum: CGFloat, steps: Int = 12, done: @escaping (Bool, CGFloat) -> Void) {
        guard pinchStarts() else { return done(false, 1) }
        var furthest: CGFloat = 1
        func next(_ i: Int) {
            guard pinch != nil else { return done(false, furthest) }
            guard i < steps else { pinchEnd(lifted: true); return done(true, furthest) }
            pinchStep(sum / CGFloat(max(1, steps)))
            if abs(pinchScale - 1) > abs(furthest - 1) { furthest = pinchScale }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { next(i + 1) }
        }
        next(0)
    }

    /// The dim as set now, for the bench: 1 is a peek's whole dim.
    var dimShown: Float { dim.opacity }

    /// The panel at the fingers' scale about its middle, the dim with it.
    private func follow(_ sum: CGFloat) {
        guard let layer = panel?.layer, up else { return }
        let scale = min(1.1, max(0.82, 1 + sum * 0.35))
        pinchScale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "peek.transform")
        layer.transform = PeekView.held(layer.bounds.size, scale, rise: 0)
        dim.removeAllAnimations()
        dim.opacity = Float(1 - max(0, 1 - scale) * 2)
        CATransaction.commit()
    }

    /// Not far enough either way: back to rest.
    private func springBack() {
        defer { pinchScale = 1 }
        guard let layer = panel?.layer, pinchScale != 1 else { return }
        let from = layer.transform
        let dimmed = dim.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        dim.opacity = 1
        run(layer, "transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: CATransform3DIdentity), 0.22, PeekView.curve)
        run(dim, "opacity", from: dimmed, to: 1, 0.22, PeekView.curve)
        CATransaction.commit()
    }

    /// A firm press on a link, 0 to 1 of the way to a Force Click: the page
    /// dims up to half of a peek's dim with it, and back when it lets go.
    func press(_ amount: CGFloat) {
        guard !up, keeping == 0 else { return }
        let to = Float(min(1, max(0, amount)) * 0.5)
        guard to != pressed else { return }
        let from = pressed
        pressed = to
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.removeAllAnimations()
        dim.opacity = to
        if to == 0 { run(dim, "opacity", from: from, to: 0, 0.14, PeekView.back) }
        CATransaction.commit()
    }

    /// The shade belongs to the receding card too. Keeping it in Peek's
    /// unscaled layer would leave a stationary outline around the card.
    func bindSurface(_ surface: NSView, shade: NSView) {
        depth.bind(surface: surface)
        dim.removeFromSuperlayer()
        shade.layer?.addSublayer(dim)
    }

    func shape(corner: CGFloat, flatTop: Bool) {
        guard corner != self.corner || flatTop != self.flatTop else { return }
        self.corner = corner
        self.flatTop = flatTop
        outlineDim()
    }

    private func outlineDim() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // This view's y runs up: the top is the max-Y edge.
        dim.path = Reshape.outline(dim.bounds, corner: corner, square: flatTop ? .maxYEdge : nil)
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        up ? super.hitTest(point) : nil
    }

    /// A click anywhere off the page and its knobs puts it away, as in Arc:
    /// on the dimmed page, and in the panel's margin under the knobs or
    /// between them and the page, which the panel spans but shows nothing
    /// in (feedback #211).
    override func mouseDown(with event: NSEvent) {
        guard up, let panel else { return }
        let point = panel.convert(event.locationInWindow, from: nil)
        if let holder, holder.frame.contains(point) { return }
        if panel.subviews.contains(where: { $0 is NSHostingView<PeekButtons> && $0.frame.contains(point) }) { return }
        if mail != nil { browser?.closeMailto() } else { browser?.closePeek() }
    }

    /// Where the page lies: in from the sides by a share of the width, the
    /// buttons in the right margin so the page is centered.
    private var pageRect: CGRect {
        if mail != nil { return mailRect }
        let side = max(32, bounds.width * 0.08)
        // Hung near the top, as the page is in the window, the room under
        // it for the dim to read as a page beneath.
        return CGRect(x: side, y: 24, width: max(200, bounds.width - 2 * side), height: max(200, bounds.height - 24 - top))
    }

    /// A mail's card: a letter's width, as tall as it is written, hung a
    /// little way down, the page round it dimmed.
    private var mailRect: CGRect {
        let width = min(MailtoPeek.width, max(280, bounds.width - 64))
        let room = max(160, bounds.height - top - 48)
        let tall = min(room, max(120, mailTall))
        let down = max(top + 48, (bounds.height - tall) * 0.24)
        return CGRect(x: (bounds.width - width) / 2, y: max(24, bounds.height - down - tall), width: width, height: tall)
    }

    private var panelRect: CGRect {
        if mail != nil { return pageRect }
        let page = pageRect
        return CGRect(x: page.minX, y: page.minY, width: page.width + 10 + PeekView.buttons, height: page.height)
    }

    override func layout() {
        super.layout()
        depth.refresh()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.frame = bounds
        dim.contentsScale = window?.backingScaleFactor ?? dim.contentsScale
        CATransaction.commit()
        outlineDim()
        let page = pageRect
        // In the middle of the room over the panel, the card's margin
        // above it too, on a rim no taller than that room.
        loading.rim = CGSize(width: 5, height: (room - LoadBar.thick) / 2)
        loading.frame = CGRect(x: page.midX - LoadBar.size.width / 2, y: page.maxY + room / 2 - LoadBar.size.height / 2,
                               width: LoadBar.size.width, height: LoadBar.size.height)
        guard let panel, up else { return }
        panel.frame = panelRect
        lay(panel)
        shareCorner()
    }

    /// How far down from the window's top the card and the panel stand,
    /// for bench peek: the panel's as far as the card's page, no further.
    var placement: [String: CGFloat] {
        guard let window, let content = window.contentView else { return [:] }
        let card = convert(bounds, to: nil)
        var found = ["card": content.bounds.height - card.maxY, "top": top]
        if let panel, up { found["panel"] = content.bounds.height - convert(panel.frame, to: nil).maxY }
        // The knobs down its side (PeekButtons), from the window's top left,
        // for a probe to press them as the mouse would.
        if let panel, up, let buttons = panel.subviews.first(where: { $0 is NSHostingView<PeekButtons> }) {
            let frame = buttons.convert(buttons.bounds, to: nil)
            found["knobsX"] = frame.minX
            found["knobsY"] = content.bounds.height - frame.maxY
            found["knobsW"] = frame.width
            found["knobsH"] = frame.height
        }
        // The address band (PeekBand), and how far down the page starts.
        if up, let holder = holder as? PageHolder {
            found["band"] = bandTall
            found["pageTop"] = content.bounds.height - holder.convert(holder.pageFrame, to: nil).maxY
            if let band = holder.band {
                let frame = band.convert(band.bounds, to: nil)
                found["bandTop"] = content.bounds.height - frame.maxY
                found["bandBottom"] = content.bounds.height - frame.minY
                found["bandSafeTop"] = band.safeAreaInsets.top
                // The site's native click zone follows the SwiftUI caption.
                // Its host can have the right frame while that content is
                // displaced by an inherited titlebar safe area.
                func caption(in view: NSView) -> NSView? {
                    if view is ClickZone.Zone { return view }
                    return view.subviews.lazy.compactMap { caption(in: $0) }.first
                }
                if let caption = caption(in: band) {
                    found["bandCaptionMiddle"] = content.bounds.height - caption.convert(caption.bounds, to: nil).midY
                }
            }
            if let page = browser?.peeking?.builtPage, page.superview === holder {
                found["viewportTop"] = content.bounds.height - page.convert(page.bounds, to: nil).maxY
            }
            found["noticeTop"] = found["card"].map { $0 + (browser?.peekCorner.inset?.height ?? 0) }
        }
        return found
    }

    /// Its panels for the bench: "shown" or "hidden" each, the load bar aside.
    var panelsSaid: [String] {
        subviews.filter { !($0 is LoadBar) }.map { $0.isHidden ? "hidden" : $0 === panel ? "shown" : "stray" }
    }

    /// Where every notice comes out while it is up: the peek's top right
    /// corner rather than the page's (PeekCorner).
    private func shareCorner() {
        browser?.peekCorner.set(up ? CGSize(width: pageRect.minX, height: top + bandTall) : nil)
    }

    /// The peek's address along its page's top (PeekBand), or nothing.
    private var bandTall: CGFloat { (holder as? PageHolder)?.band?.frame.height ?? 0 }

    private func lay(_ panel: NSView) {
        let page = CGRect(origin: .zero, size: pageRect.size)
        holder?.frame = page
        if let mail { mail.frame = CGRect(origin: .zero, size: page.size) }
        // Over the page itself, under the address band when there is one.
        let band = bandTall
        panel.subviews.first { $0 is PageSuggestionsHost }?.frame = CGRect(x: page.minX, y: page.minY,
                                                                         width: page.width, height: page.height - band)
        if let shade = panel.layer?.sublayers?.first(where: { $0.name == "shade" }) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shade.frame = page
            shade.shadowPath = Reshape.outline(CGRect(origin: .zero, size: page.size), corner: Radius.surface)
            CATransaction.commit()
        }
        if let buttons = panel.subviews.first(where: { $0 is NSHostingView<PeekButtons> }) {
            buttons.frame = CGRect(x: page.maxX + 10, y: page.maxY - buttonsTall,
                                   width: PeekView.buttons, height: buttonsTall)
        }
        // ⌘F's bar in the page's top right corner, the rim in from both
        // edges, as a tab's stands on the stage.
        if let bar = panel.subviews.first(where: { $0 is PeekFindHost }) {
            bar.setFrameOrigin(CGPoint(x: page.maxX - bar.frame.width - Metrics.rim,
                                       y: page.maxY - band - bar.frame.height - Metrics.rim))
        }
    }

    // MARK: - looking for something on the page

    /// ⌘F over the peek (Browser.openFind): the page's own find bar, over
    /// it in its corner, made when first asked for and gone with the bar.
    func showFind(_ tab: Tab) {
        guard up, mail == nil, let panel, tab.finder.shown else { return }
        guard !panel.subviews.contains(where: { $0 is PeekFindHost }) else { return }
        let bar = PeekFindHost(finder: tab.finder)
        // Over the page and its suggestions, under nothing.
        panel.addSubview(bar)
        lay(panel)
        guard let layer = bar.layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        CATransaction.begin()
        run(layer, "opacity", from: 0, to: 1, 0.14, CAMediaTimingFunction(name: .easeOut))
        CATransaction.commit()
    }

    /// The bar, out of a panel going home or growing into a tab: it isn't
    /// carried with the page's picture.
    private func dropFind(_ panel: NSView) {
        panel.subviews.filter { $0 is PeekFindHost }.forEach { $0.removeFromSuperview() }
    }

    /// Whether the find bar stands over the peek, for the bench.
    var findShown: Bool { panel?.subviews.contains { $0 is PeekFindHost } == true }

    // MARK: - coming

    /// `instant`: back with its tab, drawn already, and shown as it stands.
    /// `from`: the page shift-clicked in, asked where the link was.
    func present(_ tab: Tab, shy: Bool, instant: Bool = false, from source: (any PageHandle)? = nil, live: Bool = false,
                 origin: PeekOrigin? = nil) {
        drop(restoring: false)
        mail = nil
        guard let browser else { return }
        if let kept, kept.page == tab.id {
            self.kept = nil
            if instant, tab.builtPage?.superview === kept.holder {
                up = true
                panel = kept.panel
                holder = kept.holder
                kept.panel.frame = panelRect
                lay(kept.panel)
                loading.bind(tab)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                kept.panel.isHidden = false
                dim.removeAllAnimations()
                dim.opacity = 1
                CATransaction.commit()
                pressed = 0
                depth.set(true, animated: false)
                window?.makeFirstResponder(tab.page)
                return
            }
            kept.panel.removeFromSuperview()
        }
        up = true
        let panel = NSView(frame: panelRect)
        panel.wantsLayer = true
        // The shadow, drawn from a path: never worked out from the page's
        // pixels, which change every time the page draws.
        let shade = CALayer()
        shade.name = "shade"
        shade.shadowColor = NSColor.black.cgColor
        shade.shadowOpacity = 0.14
        shade.shadowRadius = 24
        shade.shadowOffset = CGSize(width: 0, height: -8)
        panel.layer?.addSublayer(shade)
        // Laid out at its final size before it loads: WebKit lays a page out
        // once for the panel, never again while it grows into view.
        let holder = PageHolder(tab: tab)
        holder.layer?.backgroundColor = (shy ? NSColor(white: 0.085, alpha: 1) : Palette.NS.ground).cgColor
        holder.layer?.borderWidth = 1
        holder.layer?.borderColor = Palette.NS.ink.withAlphaComponent(0.08).cgColor
        // Its address along the top, asked for in Settings › Tabs: part of
        // the holder, so it grows, goes home and flies with the page.
        if browser.prefs.peekAddress {
            let band = NSHostingView(rootView: PeekBand(browser: browser, tab: tab))
            band.sizingOptions = []
            // PageHolder reserves the band's entire height. Applying the
            // window's titlebar safe area again pushes its fixed-height
            // SwiftUI content below that room, over the page's first row.
            band.safeAreaRegions = []
            band.frame = CGRect(x: 0, y: 0, width: pageRect.width, height: PeekBand.height)
            holder.band = band
        }
        panel.addSubview(holder)
        let suggestions = PageSuggestionsHost(browser: browser, tab: tab)
        panel.addSubview(suggestions)
        let buttons = NSHostingView(rootView: PeekButtons(browser: browser, under: browser.peekSource))
        buttons.sizingOptions = []
        panel.addSubview(buttons)
        // An agent's tab, live: its dock at the page's foot, as on the tab.
        if live { PeekView.dock(tab, in: holder) }
        addSubview(panel)
        self.panel = panel
        self.holder = holder
        lay(panel)
        // The notices' corner under the band, now that there is a holder.
        shareCorner()
        loading.bind(tab)
        // Back with its tab, its bar still up: the bar with it.
        if tab.finder.shown { showFind(tab) }
        if instant {
            tab.page.alphaValue = 1
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dim.removeAllAnimations()
            dim.opacity = 1
            panel.layer?.opacity = 1
            CATransaction.commit()
            pressed = 0
            depth.set(true, animated: false)
            window?.makeFirstResponder(tab.page)
            return
        }
        // Unseen until it has drawn: the holder's own ground shows meanwhile.
        tab.page.alphaValue = 0
        reveal(tab.page)
        window?.makeFirstResponder(tab.page)

        if let origin, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return grow(panel, from: origin) }
        guard let source, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return arrive(panel) }
        // Held unseen while the page it came from says where the link is,
        // a few milliseconds; one that doesn't say in time, as it always came.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.layer?.opacity = 0
        CATransaction.commit()
        var settled = false
        PeekOrigin.find(in: source, over: self, picture: true) { [weak self] origin in
            guard !settled, let self else { return }
            settled = true
            guard self.panel === panel else { return }
            if let origin { grow(panel, from: origin) } else { arrive(panel) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + PeekOrigin.patience) { [weak self] in
            guard !settled, let self else { return }
            settled = true
            if self.panel === panel { arrive(panel) }
        }
    }

    /// A new mail over the page (Browser.mailto): its card, `card`, in the
    /// panel's place, grown out of the link clicked as a page is, and back
    /// into it when it goes. No buttons down its side: the card's own foot
    /// has Close, Open in Mail and Send.
    func present(mail card: NSView, owner: AnyObject, tall: CGFloat, from source: (any PageHandle)?) {
        drop(restoring: false)
        mail = card
        mailOwner = owner
        mailTall = tall
        up = true
        let panel = NSView(frame: panelRect)
        panel.wantsLayer = true
        let shade = CALayer()
        shade.name = "shade"
        shade.shadowColor = NSColor.black.cgColor
        shade.shadowOpacity = 0.14
        shade.shadowRadius = 24
        shade.shadowOffset = CGSize(width: 0, height: -8)
        panel.layer?.addSublayer(shade)
        let holder = NSView()
        holder.wantsLayer = true
        holder.layer?.masksToBounds = true
        holder.layer?.cornerCurve = .continuous
        holder.layer?.cornerRadius = Radius.surface
        holder.layer?.backgroundColor = Palette.NS.ground.cgColor
        holder.addSubview(card)
        panel.addSubview(holder)
        addSubview(panel)
        self.panel = panel
        self.holder = holder
        lay(panel)
        guard let source, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return arrive(panel) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.layer?.opacity = 0
        CATransaction.commit()
        var settled = false
        PeekOrigin.find(in: source, over: self, picture: true) { [weak self] origin in
            guard !settled, let self else { return }
            settled = true
            guard self.panel === panel else { return }
            if let origin { grow(panel, from: origin) } else { arrive(panel) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + PeekOrigin.patience) { [weak self] in
            guard !settled, let self else { return }
            settled = true
            if self.panel === panel { arrive(panel) }
        }
    }

    /// The mail's words grew or shrank: the card with them, at once.
    func mail(tall: CGFloat) {
        guard mail != nil, up, abs(tall - mailTall) > 0.5 else { return }
        mailTall = tall
        guard let panel else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.frame = panelRect
        lay(panel)
        CATransaction.commit()
    }

    /// The agent's dock over a live peek's page, at its foot, only as big as
    /// it is drawn so the page round it still takes clicks.
    private static func dock(_ tab: Tab, in holder: PageHolder) {
        AgentDockHost.mount(tab, in: holder)
    }

    /// In, on the render server, the way a card over a page comes: the dim,
    /// and the panel up from a little lower and smaller about its middle.
    /// It is most of the window, so it starts further in than a small card
    /// does, or the growth would be too little to see.
    private func arrive(_ panel: NSView) {
        depth.set(true, animated: true)
        let size = panel.frame.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.opacity = 1
        run(dim, "opacity", from: pressed, to: 1, PeekView.coming, PeekView.curve)
        pressed = 0
        if let layer = panel.layer {
            layer.opacity = 1
            run(layer, "opacity", from: 0, to: 1, PeekView.coming * 0.7, PeekView.curve)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                run(layer, "transform", from: NSValue(caTransform3D: PeekView.held(size, 0.94, rise: -12)),
                    to: NSValue(caTransform3D: CATransform3DIdentity), PeekView.coming, PeekView.curve)
            }
        }
        CATransaction.commit()
    }

    /// Out of the link: the holder, at its final place and size all along,
    /// shown clipped to the link's rect and let out to its own, the page in
    /// it scaled to the width it has; a picture of the link rides on top and
    /// is gone within the first third, so a word never shows as a squashed
    /// page. One commit; the render server does the rest.
    private func grow(_ panel: NSView, from origin: PeekOrigin) {
        guard let holder, let shade = panel.layer?.sublayers?.first(where: { $0.name == "shade" }) else { return arrive(panel) }
        depth.set(true, animated: true)
        let page = holder.frame
        let from = panel.convert(origin.rect, from: self)
        let ghost = CALayer()
        ghost.name = "ghost"
        ghost.contents = origin.picture
        // A card stretches with the holder, one thing growing; a word would
        // stretch into letters a hand high, so it stays its own size in the
        // middle as it goes.
        let word = origin.rect.height < 36
        ghost.contentsGravity = word ? .center : .resize
        if let picture = origin.picture, origin.rect.width > 0 {
            ghost.contentsScale = CGFloat(picture.width) / origin.rect.width
        }
        ghost.masksToBounds = true
        ghost.cornerCurve = .continuous
        ghost.zPosition = 10
        let pace = PeekView.growing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.frame = page
        ghost.cornerRadius = Radius.surface
        ghost.opacity = 0
        panel.layer?.addSublayer(ghost)
        panel.layer?.opacity = 1
        dim.opacity = 1
        run(dim, "opacity", from: pressed, to: 1, pace * 0.8, PeekView.curve)
        pressed = 0
        PeekView.morph(holder, shade, ghost: ghost, from: (from, origin.corner), to: (page, Radius.surface), page: page.size,
                       opening: true, pace, PeekView.travel)
        PeekView.run(ghost, "opacity", from: 1, to: 0, pace * (word ? 0.2 : 0.3), CAMediaTimingFunction(name: .easeOut))
        if let buttons = panel.subviews.first(where: { $0 is NSHostingView<PeekButtons> })?.layer {
            PeekView.run(buttons, "opacity", from: 0, to: 1, pace * 0.4, PeekView.curve, after: pace * 0.6)
        }
        CATransaction.commit()
    }

    /// The page, faded in once it has something drawn, or after a moment
    /// regardless for a page that never says.
    private func reveal(_ web: any PageHandle) {
        var shown = false
        let show = { [weak web] in
            guard !shown, let web else { return }
            shown = true
            guard web.alphaValue == 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            web.alphaValue = 1
            if let layer = web.layer {
                layer.opacity = 1
                PeekView.run(layer, "opacity", from: 0, to: 1, 0.14, CAMediaTimingFunction(name: .easeOut))
            }
            CATransaction.commit()
        }
        func look(_ tries: Int) {
            guard !shown, let holder = self.holder, web.superview === holder else { return }
            if !web.isLoading || web.estimatedProgress > 0.5 {
                web.snapshot(PageShot(width: 1, afterUpdates: true)) { _, _ in show() }
            } else if tries < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { look(tries + 1) }
            }
        }
        if let page = web as? ChromiumPage {
            // Chromium says when the page has drawn. Its progress is only
            // ever 0.5 or 1, so the reading above waited for the whole load,
            // the card standing empty all that while.
            page.afterFirstPaint { _ in show() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { look(0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { show() }
    }

    // MARK: - going

    /// Back into the link it came from, when the page it was opened over
    /// still shows it; faded out where it stands otherwise. Either on the
    /// render server, and the page is let go once it has.
    func dismiss(to source: (any PageHandle)? = nil, _ done: @escaping () -> Void) {
        guard let panel else { return done() }
        dropFind(panel)
        let turn = turns
        depth.set(false, animated: true)
        let holder = holder
        let brisk = self.brisk
        self.brisk = false
        pinch = nil
        pinchScale = 1
        up = false
        self.panel = nil
        self.holder = nil
        // A mail's card is drawn by its controller until it is gone.
        let owner = mailOwner
        mail = nil
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            withExtendedLifetime(owner) {}
            panel.removeFromSuperview()
            done()
        }
        guard let source, let holder, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return depart(panel, finish)
        }
        var settled = false
        PeekOrigin.find(in: source, over: self, picture: false) { [weak self, weak source] origin in
            guard !settled, let self else { return }
            settled = true
            guard self.turns == turn else { return finish() }
            guard let origin else { return depart(panel, finish) }
            var landed = false
            shrink(panel, holder, to: origin, brisk: brisk) {
                finish()
                // Landed: the link itself pops a little and settles, so
                // where the page went shows. Once: shrink's end is told twice.
                guard !landed, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                landed = true
                source?.run("window.__yabPeekBump && __yabPeekBump(\(PeekView.bumping * 1000))", in: .yab) { _ in }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + PeekOrigin.patience) { [weak self] in
            guard !settled else { return }
            settled = true
            guard self?.turns == turn else { return finish() }
            self?.depart(panel, finish) ?? finish()
        }
    }

    /// Home: the morph the other way, quicker, the page fading from the
    /// holder as it nears the link and the link's picture back at the end,
    /// landing on the link itself. `brisk`: let go by a pinch, from where
    /// the fingers left it, the rest of the way quicker.
    private func shrink(_ panel: NSView, _ holder: NSView, to origin: PeekOrigin, brisk: Bool, _ finish: @escaping () -> Void) {
        guard let shade = panel.layer?.sublayers?.first(where: { $0.name == "shade" }), let h = holder.layer else {
            return depart(panel, finish)
        }
        let page = holder.frame
        let to = panel.convert(origin.rect, from: self)
        let ghost = panel.layer?.sublayers?.first(where: { $0.name == "ghost" })
        let pace = brisk ? PeekView.shrinking * 0.65 : PeekView.shrinking
        let dimmed = dim.presentation()?.opacity ?? dim.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
        // Held by fingers: back to its own scale on the way, so it lands
        // on the link exactly.
        if let layer = panel.layer, !CATransform3DIsIdentity(layer.transform) {
            let held = layer.transform
            layer.transform = CATransform3DIdentity
            run(layer, "transform", from: NSValue(caTransform3D: held), to: NSValue(caTransform3D: CATransform3DIdentity), pace, PeekView.back)
        }
        // The model where it ends: at the link, its picture showing.
        h.bounds = CGRect(origin: .zero, size: to.size)
        h.position = PeekView.spot(to, h)
        h.sublayerTransform = PeekView.hung(to, page.size)
        h.cornerRadius = origin.corner
        shade.shadowOpacity = 0
        shade.shadowPath = Reshape.outline(to, corner: origin.corner)
        if let ghost {
            ghost.frame = to
            ghost.cornerRadius = origin.corner
            ghost.opacity = 1
        }
        dim.opacity = 0
        run(dim, "opacity", from: dimmed, to: 0, pace, PeekView.back)
        PeekView.morph(holder, shade, ghost: ghost, from: (page, Radius.surface), to: (to, origin.corner), page: page.size,
                       opening: false, pace, PeekView.back)
        if let ghost { PeekView.run(ghost, "opacity", from: 0, to: 1, pace * 0.35, PeekView.back, after: pace * 0.55) }
        if let web = holder.subviews.first?.layer {
            web.opacity = 0
            PeekView.run(web, "opacity", from: 1, to: 0, pace * 0.4, CAMediaTimingFunction(name: .easeIn), after: pace * 0.25)
        }
        if let buttons = panel.subviews.first(where: { $0 is NSHostingView<PeekButtons> })?.layer {
            buttons.opacity = 0
            PeekView.run(buttons, "opacity", from: 1, to: 0, pace * 0.3, PeekView.back)
        }
        CATransaction.commit()
        // The completion can wait on a busy render server; the page doesn't.
        DispatchQueue.main.asyncAfter(deadline: .now() + pace + 0.14) { finish() }
    }

    /// Out a touch smaller as it fades, quicker than it came.
    private func depart(_ panel: NSView, _ finish: @escaping () -> Void) {
        let pace = Reshape.Pace.depart
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
        dim.opacity = 0
        run(dim, "opacity", from: 1, to: 0, 0.16, pace.timing)
        if let layer = panel.layer {
            let away = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? CATransform3DIdentity : PeekView.held(panel.frame.size, 0.97, rise: 0)
            let shown = layer.presentation() ?? layer
            let opacity = shown.opacity
            let transform = shown.transform
            layer.opacity = 0
            layer.transform = away
            run(layer, "opacity", from: opacity, to: 0, 0.16, pace.timing)
            run(layer, "transform", from: NSValue(caTransform3D: transform), to: NSValue(caTransform3D: away), 0.16, pace.timing)
        }
        CATransaction.commit()
        // The completion can wait on a busy render server; the page doesn't.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish() }
    }

    /// Gone at once, for a new peek in the old one's place.
    /// Put by with its tab: hidden in the same frame, kept for its return.
    /// One is kept, the latest; one kept before it for another tab is taken
    /// down, and built again if that tab is picked.
    func hide(_ page: Tab) {
        guard let panel, let holder = holder as? PageHolder, up else { return drop() }
        turns += 1
        depth.set(false, animated: false)
        kept?.panel.removeFromSuperview()
        up = false
        self.panel = nil
        self.holder = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.isHidden = true
        dim.removeAllAnimations()
        dim.opacity = 0
        CATransaction.commit()
        kept = (page.id, panel, holder)
    }

    /// A page gone for good: its kept panel with it.
    func forget(_ page: Tab.ID) {
        guard let kept, kept.page == page else { return }
        kept.panel.removeFromSuperview()
        self.kept = nil
    }

    func drop(restoring: Bool = true) {
        turns += 1
        mail = nil
        pinch = nil
        pinchScale = 1
        brisk = false
        // A new peek comes on from the press's dim, never from none.
        if restoring { pressed = 0 }
        if restoring { depth.set(false, animated: false) }
        up = false
        panel?.removeFromSuperview()
        panel = nil
        holder = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.removeAllAnimations()
        dim.opacity = pressed
        CATransaction.commit()
    }

    /// The page as it is, grown from the panel to the whole stage on the
    /// render server; `landed` moves the page under the picture as it starts
    /// flying, so WebKit can draw at the new size during the flight.
    func keep(_ tab: Tab, half: Bool = false, landed: @escaping () -> Void) {
        guard let panel, let holder, let window, let content = window.contentView else { return landed() }
        dropFind(panel)
        keeping += 1
        turns += 1
        let turn = turns
        depth.set(false, animated: true)
        up = false
        self.panel = nil
        self.holder = nil
        // Let go by a pinch: from the scale the fingers left it at, quicker.
        let held = pinchScale
        let brisk = self.brisk
        pinch = nil
        pinchScale = 1
        self.brisk = false
        let fly: @MainActor (NSImage?) -> Void = { [weak self] image in
            guard let self else { return landed() }
            self.keeping -= 1
            // A peek come up since has the dim: this one's flight leaves it be.
            let current = self.turns == turn
            // With no picture, transfer directly rather than flying an
            // empty card and exposing the old page when it disappears.
            guard let image else {
                panel.removeFromSuperview()
                if current { self.dim.opacity = 0 }
                landed()
                return
            }
            // A layer of its own over the whole window, so the stage and the
            // row can change under it as the page arrives.
            // Beside SwiftUI's host: views added inside the hosting view
            // do not get their layers into the window's rendering tree.
            let frame = content.superview ?? content
            let sky = PeekFlightSky(frame: frame === content ? content.bounds : content.frame)
            sky.identifier = NSUserInterfaceItemIdentifier("peek-flight")
            sky.autoresizingMask = [.width, .height]
            frame.addSubview(sky, positioned: .above, relativeTo: frame === content ? nil : content)
            // The page alone, under its address band if it has one: the
            // picture is of the page, and the band stays with the panel.
            var from = sky.convert((holder as? PageHolder)?.pageFrame ?? holder.bounds, from: holder)
            if held != 1 {
                // The panel scales about its middle (held(_:_:rise:)).
                let mid = sky.convert(CGPoint(x: panel.bounds.midX, y: panel.bounds.midY), from: panel)
                from = CGRect(x: mid.x + (from.minX - mid.x) * held, y: mid.y + (from.minY - mid.y) * held,
                              width: from.width * held, height: from.height * held)
            }
            // The whole stage, or the half the page will take beside the one
            // it was opened over.
            // This view covers the page's address bar as well: the page lands
            // under the bar it will have, not over it and then a bar lower.
            let whole = sky.convert(bounds, from: self)
            let tall = whole.height - (self.browser?.barOver(kept: tab, half: half, carded: self.corner > 0) ?? 0)
            let to = half ? CGRect(x: whole.midX + 4, y: whole.minY, width: whole.width / 2 - 4, height: tall)
                : CGRect(x: whole.minX, y: whole.minY, width: whole.width, height: tall)
            StageView.mark("peek.flight", ["top": Double(content.bounds.height - sky.convert(to, to: nil).maxY), "height": Double(to.height)])
            let card = CALayer()
            card.masksToBounds = true
            card.cornerCurve = .continuous
            card.cornerRadius = Radius.surface
            card.backgroundColor = StageView.fill(under: tab.webKitOnly("WebKit peek transition", build: false)?.underPageBackgroundColor ?? tab.page.themeColor, shade: tab.shade, tone: tab.tone).cgColor
            let picture = CALayer()
            picture.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let shape = image.size.width > 0 ? image.size.height / image.size.width : 1
            // Hung from the top, as wide as the card: the page keeps its
            // proportions and the card's edge cuts what it has no room for.
            func place(_ rect: CGRect) -> CGRect {
                CGRect(x: 0, y: rect.height - rect.width * shape, width: rect.width, height: rect.width * shape)
            }
            card.addSublayer(picture)
            let pace = (duration: Reshape.Pace.arrive.duration * (brisk ? 0.7 : 1), timing: Reshape.Pace.arrive.timing)
            let due = CACurrentMediaTime() + pace.duration
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            card.frame = to
            card.cornerRadius = self.corner
            picture.frame = place(CGRect(origin: .zero, size: to.size))
            sky.layer?.addSublayer(card)
            PeekView.run(card, "bounds", from: NSValue(rect: CGRect(origin: .zero, size: from.size)), to: NSValue(rect: CGRect(origin: .zero, size: to.size)), pace.duration, pace.timing)
            PeekView.run(card, "position", from: NSValue(point: CGPoint(x: from.midX, y: from.midY)), to: NSValue(point: CGPoint(x: to.midX, y: to.midY)), pace.duration, pace.timing)
            PeekView.run(card, "cornerRadius", from: Radius.surface, to: self.corner, pace.duration, pace.timing)
            PeekView.run(picture, "bounds", from: NSValue(rect: CGRect(origin: .zero, size: place(CGRect(origin: .zero, size: from.size)).size)),
                         to: NSValue(rect: picture.bounds), pace.duration, pace.timing)
            let fromPlace = place(CGRect(origin: .zero, size: from.size))
            PeekView.run(picture, "position", from: NSValue(point: CGPoint(x: fromPlace.midX, y: fromPlace.midY)),
                         to: NSValue(point: picture.position), pace.duration, pace.timing)
            // The panel goes where the card now is; the dim with the flight.
            panel.layer?.opacity = 0
            if current {
                self.dim.opacity = 0
                PeekView.run(self.dim, "opacity", from: 1, to: 0, pace.duration, pace.timing)
            }
            CATransaction.commit()
            CATransaction.flush()

            panel.removeFromSuperview()
            landed()
            PeekView.uncover(sky, card: card, page: tab.page, owner: tab.id, window: window, due: due) { [weak browser = self.browser, weak tab] in
                guard let browser, let tab else { return true }
                return tab.gone || !browser.stages.contains(tab.id)
            }
        }
        // No document of its own committed yet, its server still to answer:
        // nothing of the page to picture, and none is waited for. A Chromium
        // page's picture waits for its document, so the press did nothing
        // until the server had answered (register 2538).
        guard tab.builtPage?.committedURL != nil else { return fly(nil) }
        tab.page.snapshot(PageShot(afterUpdates: false)) { image, _ in fly(image) }
    }

    /// SwiftUI attaches the page on a later pass. A snapshot requested in
    /// `landed` still sees the peek's holder, even afterScreenUpdates, and
    /// would let the picture go over the old page. Wait for the destination
    /// stage first, then its next drawing and the end of the flight.
    static func uncover(_ sky: NSView, card: CALayer, page: NSView, owner: Tab.ID,
                        window: NSWindow, due: CFTimeInterval, cancelled: @escaping () -> Bool) {
        StageView.afterHandoff(page, owner: owner, window: { window },
                               cancelled: { sky.superview == nil || cancelled() }, attached: { _ in }) { presented in
            guard presented, !cancelled() else { sky.removeFromSuperview(); return }
            var releasing = false
            func settle() {
                guard sky.superview != nil else { return }
                guard !cancelled(), window.isVisible else { sky.removeFromSuperview(); return }
                let wait = due - CACurrentMediaTime()
                if wait > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + max(1.0 / 60, wait), execute: settle)
                } else {
                    // The real page and this picture now share a viewport.
                    // A crossfade between two layouts doubles their text.
                    sky.removeFromSuperview()
                }
            }
            func release() {
                guard !releasing else { return }
                releasing = true
                settle()
            }
            PagePictures.snapshot(page, shot: PageShot(afterUpdates: true)) { image, _ in
                guard !releasing, sky.superview != nil, !cancelled() else { return release() }
                if let image, let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                   let picture = card.sublayers?.first {
                    // WebKit reflows at the receiving stage's size. Replace
                    // the old, scaled viewport while the card is still flying,
                    // then keep the new pixels at their real size till landing.
                    let shown = card.presentation()?.bounds ?? card.bounds
                    let target = card.bounds.size
                    let from = CGPoint(x: shown.midX, y: shown.maxY - target.height / 2)
                    let remaining = max(0, due - CACurrentMediaTime())
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    picture.removeAllAnimations()
                    picture.contents = pixels
                    picture.frame = CGRect(origin: .zero, size: target)
                    if remaining > 0 {
                        PeekView.run(picture, "position", from: NSValue(point: from), to: NSValue(point: picture.position),
                                     remaining, Reshape.Pace.arrive.timing)
                    }
                    CATransaction.commit()
                    StageView.mark("peek.handoff", ["snapshotWidth": Double(image.size.width),
                                                     "snapshotHeight": Double(image.size.height)])
                }
                release()
            }
            // A WebContent process that stops answering cannot keep the
            // picture over the window forever. The painted page is ready.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: release)
        }
    }

    // MARK: - motion

    /// How long it takes to come in, and on what curve: Motion.arrive's,
    /// a little longer for the size of it.
    private static let coming: CFTimeInterval = 0.26
    private static let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    /// The panel at `scale` about its middle, `rise` points up (this view's
    /// y runs up): a view's layer hangs from its corner, so the scale is
    /// carried by a step towards the middle.
    private static func held(_ size: CGSize, _ scale: CGFloat, rise: CGFloat) -> CATransform3D {
        CATransform3DConcat(
            CATransform3DMakeScale(scale, scale, 1),
            CATransform3DMakeTranslation(size.width * (1 - scale) / 2, size.height * (1 - scale) / 2 + rise, 0)
        )
    }

    /// Out of a link and back into it: longer out, the one thing becoming
    /// another has to be seen, quicker home, where the page is done with.
    private static let growing: CFTimeInterval = 0.34
    private static let shrinking: CFTimeInterval = 0.26
    /// The link's pop as the page lands in it, out and back.
    private static let bumping: CFTimeInterval = 0.14
    private static let travel = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
    private static let back = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)

    /// Where a layer sits to cover `rect`, whatever its anchor.
    private static func spot(_ rect: CGRect, _ layer: CALayer) -> CGPoint {
        CGPoint(x: rect.minX + layer.anchorPoint.x * rect.width, y: rect.minY + layer.anchorPoint.y * rect.height)
    }

    /// The page, laid out at `page`, shown in `rect`: as wide as it is, hung
    /// from its top (this view's y runs up), what is lower cut off.
    private static func hung(_ rect: CGRect, _ page: CGSize) -> CATransform3D {
        let scale = page.width > 0 ? rect.width / page.width : 1
        return CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
                                   CATransform3DMakeTranslation(0, rect.height - scale * page.height, 0))
    }

    /// The holder, its shadow and the link's picture carried from one rect
    /// and corner to another, together. Only animations are added: the
    /// caller has the model where it ends.
    private static func morph(_ holder: NSView, _ shade: CALayer, ghost: CALayer?, from a: (CGRect, CGFloat), to b: (CGRect, CGFloat),
                              page: CGSize, opening: Bool, _ duration: CFTimeInterval, _ timing: CAMediaTimingFunction) {
        guard let h = holder.layer else { return }
        let (ra, ca) = a, (rb, cb) = b
        run(h, "bounds", from: NSValue(rect: CGRect(origin: .zero, size: ra.size)), to: NSValue(rect: CGRect(origin: .zero, size: rb.size)), duration, timing)
        run(h, "position", from: NSValue(point: spot(ra, h)), to: NSValue(point: spot(rb, h)), duration, timing)
        run(h, "cornerRadius", from: ca, to: cb, duration, timing)
        run(h, "sublayerTransform", from: NSValue(caTransform3D: hung(ra, page)), to: NSValue(caTransform3D: hung(rb, page)), duration, timing)
        run(shade, "shadowPath", from: Reshape.outline(ra, corner: ca), to: Reshape.outline(rb, corner: cb), duration, timing)
        run(shade, "shadowOpacity", from: opening ? 0 : 0.14, to: opening ? 0.14 : 0, duration, timing)
        guard let ghost else { return }
        run(ghost, "bounds", from: NSValue(rect: CGRect(origin: .zero, size: ra.size)), to: NSValue(rect: CGRect(origin: .zero, size: rb.size)), duration, timing)
        run(ghost, "position", from: NSValue(point: CGPoint(x: ra.midX, y: ra.midY)), to: NSValue(point: CGPoint(x: rb.midX, y: rb.midY)), duration, timing)
        run(ghost, "cornerRadius", from: ca, to: cb, duration, timing)
    }

    private func run(_ layer: CALayer, _ key: String, from: Any, to: Any, _ duration: CFTimeInterval, _ timing: CAMediaTimingFunction) {
        PeekView.run(layer, key, from: from, to: to, duration, timing)
    }

    /// `after`: seconds from now it starts, showing `from` till then.
    private static func run(_ layer: CALayer, _ key: String, from: Any, to: Any, _ duration: CFTimeInterval, _ timing: CAMediaTimingFunction,
                            after: CFTimeInterval = 0) {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        if after > 0 {
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + after
            animation.fillMode = .backwards
        }
        layer.add(animation, forKey: "peek." + key)
    }
}

/// A picture above the content, leaving the window's clicks to its views.
private final class PeekFlightSky: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Where a peeked link is on its page, for the peek to grow out of and go
/// back into. A script in yab's world of every main frame keeps the link
/// under a press, plain or with ⇧/⌥ (nothing for ⌘ or ⌃), and gives
/// its box when asked, a few milliseconds' round trip; the page sees none
/// of it. A Force Click finds its link by where the press is, and, `force`,
/// the Mac's look at a link is held back for the peek: an <a> (in a shadow
/// root too) or an address written out in text and no link, which the
/// Mac's data detectors find on their own (x.com's chat bubbles and bios,
/// where its look came up logged out). A link in another site's frame isn't known, and the peek comes
/// as it always has.
struct PeekOrigin {
    /// In the peek view's coordinates.
    let rect: CGRect
    let corner: CGFloat
    /// The link as drawn, when asked for.
    let picture: CGImage?

    /// How long a peek waits to hear, coming or going, before it moves the
    /// plain way.
    static let patience: TimeInterval = 0.08

    static func script(force: Bool) -> String { """
    (() => {
      let from = null, at = 0, forced = false, px = -1, py = -1;
      const keep = el => { from = el ? new WeakRef(el) : null; at = Date.now(); };
      // Up from a node to the link it is in, across shadow roots, as
      // WebKit's own look at a link finds it: an <a> or <area> with an
      // href, an SVG link too.
      const xlink = "http://www.w3.org/1999/xlink";
      const up = n => n.parentNode instanceof ShadowRoot ? n.parentNode.host : n.parentNode;
      const anchor = n => {
        for (; n; n = up(n)) {
          if (!(n instanceof Element)) continue;
          if ((n.localName === "a" || n.localName === "area") && (n.hasAttribute("href") || n.hasAttributeNS(xlink, "href"))) return n;
        }
        return null;
      };
      const address = a => {
        const raw = typeof a.href === "string" ? a.href : (a.href && a.href.baseVal) || a.getAttributeNS(xlink, "href");
        try { const u = new URL(raw, document.baseURI); return /^https?:$/.test(u.protocol) ? u.href : null; } catch (e) { return null; }
      };
      // An address written out in the text under the point and not a link,
      // "x.com/rmondello" in a chat's bubble: the Mac's data detectors find
      // it and show their own look at it, so a peek finds it too.
      const word = /(?<![\\w@.\\/-])(?:https?:\\/\\/[^\\s<>"'`]+|(?:www\\.)?(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+([a-z]{2,24})(?![\\w@-])(?:[\\/?#][^\\s<>"'`]*)?)/gi;
      const usual = /^(com|net|org|io|dev|app|co|ai|me|so|gg|tv|fm|ly|sh|to|xyz|info|biz|edu|gov|ru|uk|de|fr|jp|us|ca|eu|au|in|nl|es|it|link|page|site|news|blog|tech|social|club|art|design|studio|tools|chat)$/i;
      const written = (x, y) => {
        const r = document.caretRangeFromPoint && document.caretRangeFromPoint(x, y);
        const node = r && r.startContainer;
        if (!node || node.nodeType !== 3 || !node.data.trim() || !node.parentElement) return null;
        if (node.parentElement.closest("input, textarea, [contenteditable]")) return null;
        // The caret nearest the point, which may be past the text's end: the
        // point must be over a letter of it.
        const letter = document.createRange();
        const i = Math.min(r.startOffset, node.data.length - 1);
        let over = false;
        for (const j of [i, i - 1]) {
          if (j < 0) continue;
          letter.setStart(node, j); letter.setEnd(node, j + 1);
          for (const b of letter.getClientRects())
            if (x >= b.left - 2 && x <= b.right + 2 && y >= b.top - 2 && y <= b.bottom + 2) over = true;
        }
        if (!over) return null;
        // The text of the line's block, as an address is often split over
        // spans ("https://" hidden, the rest shown).
        let box = node.parentElement;
        for (let k = 0; k < 6 && box.parentElement && /^inline/.test(getComputedStyle(box).display); k++) box = box.parentElement;
        const before = document.createRange();
        before.setStart(box, 0); before.setEnd(node, r.startOffset);
        const pos = before.toString().length;
        const whole = document.createRange();
        whole.selectNodeContents(box);
        const text = whole.toString();
        for (const m of text.matchAll(word)) {
          let found = m[0].replace(/[.,;:!?'"»…]+$/, "");
          if (found.endsWith(")") && !found.includes("(")) found = found.slice(0, -1);
          if (pos < m.index || pos > m.index + found.length) continue;
          const plain = !/^https?:\\/\\//i.test(found);
          if (plain && !/^www\\./i.test(found) && !/[\\/?#]/.test(found) && !usual.test(m[1] || "")) return null;
          try {
            const u = new URL(plain ? "https://" + found : found);
            return /^https?:$/.test(u.protocol) && u.hostname.includes(".") ? { el: node.parentElement, url: u.href } : null;
          } catch (e) { return null; }
        }
        return null;
      };
      // The element under a point, inside open shadow roots too.
      const under = (x, y) => {
        let el = document.elementFromPoint(x, y);
        while (el && el.shadowRoot) {
          const inner = el.shadowRoot.elementFromPoint(x, y);
          if (!inner || inner === el) break;
          el = inner;
        }
        return el;
      };
      // What a Force Click at a point looks at: a link, or an address
      // written out.
      const target = (el, x, y) => {
        const a = anchor(el);
        if (a) return address(a) ? { el: a, url: address(a) } : null;
        return written(x, y);
      };
      // ⇧-click on a link ends a selection there (feedback #204): WebKit itself drops the selection on a press on a link, and
      // the click would peek. A selection already made, or a caret a click
      // put in the last minute, is where it starts; the click is the
      // selection's, so the link isn't followed and nothing peeks.
      let caretAt = 0, extend = null;
      const plainText = n => !(n && (n.nodeType === 1 ? n : n.parentElement)?.closest("input, textarea, [contenteditable]"));
      // A plain press too: a pin or a kept tab peeks at another site's link
      // without ⇧ (Browser.shouldPeek), and a new window's link from one.
      addEventListener("pointerdown", e => {
        forced = false;
        px = e.clientX; py = e.clientY;
        extend = null;
        if (e.button !== 0 || e.metaKey || e.ctrlKey) return;
        const a = anchor(e.composedPath()[0]);
        keep(a);
        // Option may be the chosen Peek click. Keep its origin without
        // changing Shift's text-selection behavior below.
        if (e.altKey) return;
        if (!e.shiftKey) { caretAt = Date.now(); return; }
        const s = getSelection();
        if (a && s && s.rangeCount && s.anchorNode && !a.contains(s.anchorNode) && plainText(s.anchorNode)
            && (s.type === "Range" || (s.type === "Caret" && s.anchorNode.nodeType === 3 && Date.now() - caretAt < 60000)))
          extend = { node: s.anchorNode, offset: s.anchorOffset };
      }, true);
      addEventListener("click", e => {
        const from = extend;
        extend = null;
        if (!from || !e.shiftKey || !from.node.isConnected) return;
        const to = document.caretRangeFromPoint(e.clientX, e.clientY);
        if (!to) return;
        getSelection().setBaseAndExtent(from.node, from.offset, to.startContainer, to.startOffset);
        e.preventDefault();
        e.stopImmediatePropagation();
      }, true);
      // Where the pointer is, for the Force Click's look ahead of it: its
      // own event may come without one.
      addEventListener("pointermove", e => { px = e.clientX; py = e.clientY; }, { capture: true, passive: true });
      if (\(force)) addEventListener("webkitmouseforcewillbegin", e => {
        const has = e.clientX || e.clientY, x = has ? e.clientX : px, y = has ? e.clientY : py;
        const el = e.composedPath()[0];
        if (anchor(el) || target(el, x, y)) e.preventDefault();
      }, true);
      // The click a Force Click ends in: the peek took it.
      addEventListener("click", e => {
        if (!forced) return;
        forced = false;
        e.preventDefault();
        e.stopImmediatePropagation();
      }, true);
      // Resolve a native modified press even if no hover status arrived.
      window.__yabPeekLinkAt = (x, y, width, shift) => {
        const unit = innerWidth / width;
        const hit = under(x * unit, y * unit), el = anchor(hit);
        const url = el && address(el);
        if (!url) {
          keep(null);
          return hit && /^(iframe|frame|embed|object)$/.test(hit.localName) ? { embedded: true } : null;
        }
        const s = getSelection();
        if (shift && s && s.rangeCount && s.anchorNode && !el.contains(s.anchorNode) && plainText(s.anchorNode)
            && (s.type === "Range" || (s.type === "Caret" && s.anchorNode.nodeType === 3 && Date.now() - caretAt < 60000)))
          return false; // The page's Shift-selection handler owns this press.
        keep(el);
        return url;
      };
      window.__yabPeekForce = (x, y, width) => {
        const unit = innerWidth / width;
        const found = target(under(x * unit, y * unit), x * unit, y * unit);
        if (!found) return null;
        keep(found.el);
        forced = true;
        return found.url;
      };
      window.__yabPeekMark = s => keep(document.querySelector(s));
      // A peek gone home into its link: the link pops a little and settles.
      // Added to whatever transform it has; a word in a line, which takes
      // none, stays as it is.
      window.__yabPeekBump = ms => {
        const el = from && from.deref();
        if (!el || !el.isConnected || !el.animate) return;
        el.animate([{ transform: "scale(1)" }, { transform: "scale(1.06)", offset: 0.4 }, { transform: "scale(1)" }],
                   { duration: ms, easing: "ease-out", composite: "add" });
      };
      const round = el => parseFloat(getComputedStyle(el).borderTopLeftRadius) || 0;
      window.__yabPeekFrom = fresh => {
        const el = from && from.deref();
        if (!el || !el.isConnected || (fresh && Date.now() - at > 2000)) return null;
        const box = el.getBoundingClientRect();
        if (box.width < 1 || box.height < 1) return null;
        let corner = round(el);
        const only = el.children.length === 1 ? el.firstElementChild : null;
        if (!corner && only) {
          const b = only.getBoundingClientRect();
          if (Math.abs(b.width - box.width) < 3 && Math.abs(b.height - box.height) < 3) corner = round(only);
        }
        return [box.left, box.top, box.width, box.height, corner, innerWidth];
      };
    })();
    """ }

    /// The link's box in `view`, clipped to what shows of the page, or nil
    /// when it is gone, hidden or scrolled out of sight. `picture`: drawn
    /// as well, by the page's own process.
    @MainActor
    static func find(in web: any PageHandle, over view: NSView, picture: Bool, _ done: @escaping (PeekOrigin?) -> Void) {
        guard web.window != nil, web.window === view.window, web.magnification == 1 else { return done(nil) }
        web.run("window.__yabPeekFrom && __yabPeekFrom(\(picture))", in: .yab) { result in
            guard case .success(let value?) = result, let box = (value as? [NSNumber])?.map({ CGFloat($0.doubleValue) }),
                  box.count == 6, box[5] > 0 else { return done(nil) }
            // CSS pixels from the viewport's top left, to the view's points.
            let unit = web.bounds.width / box[5]
            var rect = CGRect(x: box[0] * unit, y: box[1] * unit, width: box[2] * unit, height: box[3] * unit)
            if !web.isFlipped { rect.origin.y = web.bounds.height - rect.maxY }
            let seen = rect.intersection(web.bounds)
            guard !seen.isNull, seen.width * seen.height >= rect.width * rect.height * 0.25 else { return done(nil) }
            var corner = box[4] * unit
            var inView = view.convert(seen, from: web)
            // A word: a little room round it, and a corner to grow from.
            if inView.height < 30 {
                inView = inView.insetBy(dx: -3, dy: -2)
                corner = max(corner, 5)
            }
            corner = min(corner, inView.height / 2, inView.width / 2)
            guard picture else { return done(PeekOrigin(rect: inView, corner: corner, picture: nil)) }
            web.snapshot(PageShot(rect: web.convert(inView, from: view), width: nil, afterUpdates: false)) { image, _ in
                // The picture the engine drew, as it is: asked of the image
                // rather than its one representation, AppKit drew the
                // half-float bitmap again into a new one, some milliseconds
                // of the main thread per card.
                let drawn = image?.representations.first?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                done(PeekOrigin(rect: inView, corner: corner, picture: drawn))
            }
        }
    }

    /// The element `selector` finds taken as the one shift-pressed, for the
    /// bench to peek from without a pointer.
    @MainActor
    static func mark(_ selector: String, in web: any PageHandle, _ then: @escaping () -> Void) {
        let quoted = (try? JSONSerialization.data(withJSONObject: [selector])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        web.run("window.__yabPeekMark && __yabPeekMark(\(quoted)[0])", in: .yab) { _ in then() }
    }
}

/// Close, keep and split, round, down the margin beside the panel's top
/// corner, each with a tip that names its keys as they are now (Hotkeys).
/// They stand over the dimmed page they were peeked from: light glass over
/// a dark one, dark otherwise (HUD.surface(over:)). Always dark, they were
/// lost on X or YouTube.
struct PeekButtons: View {
    let browser: Browser
    /// The page under them.
    var under: Tab?
    static let side: CGFloat = 36
    static let gap: CGFloat = 10

    var body: some View {
        if let under {
            Under(tab: under) { knobs(HUD.surface(over: $0)) }
        } else {
            knobs(.dark)
        }
    }

    private func knobs(_ surface: HUD.Surface) -> some View {
        VStack(spacing: PeekButtons.gap) {
            knob("xmark", "Close", shortcut: "Close Peek", surface) { browser.closePeek() }
            knob("arrow.up.left.and.arrow.down.right", "Open as Tab", shortcut: "Open Peek as Tab", surface) { browser.keepPeek() }
            // Mail's page has no half to share: a look from a mail is closed
            // or kept, as a tab of mail's space.
            if browser.splitFits, !browser.peekFromMail {
                knob("rectangle.split.2x1", "Open in Split View", shortcut: "Open Peek in Split View", surface) { browser.splitPeek() }
            }
        }
    }

    private func knob(_ icon: String, _ title: String, shortcut: String, _ surface: HUD.Surface, action: @escaping () -> Void) -> some View {
        Knob(icon: icon, surface: surface, action: action)
            .keyTip(title, shortcut: shortcut, side: .left, surface: surface)
    }

    private struct Knob: View {
        let icon: String
        let surface: HUD.Surface
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            let ink = HUD.ink(on: surface)
            Button(action: action) {
                Symbol(icon, size: 14)
                    .foregroundStyle(ink)
                    .frame(width: PeekButtons.side, height: PeekButtons.side)
                    .background { HUD.plate(in: Circle(), surface: surface) }
                    .overlay(Circle().fill(ink.opacity(hovering ? 0.06 : 0)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle(scale: 0.94))
            .focusable(false)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: surface)
        }
    }
}

// MARK: - the mark on its tab

/// A page peeked from a tab, on the corner of the tab's own mark: the site's
/// icon on a small round plate. It is a layer in a view of its own and comes
/// and goes on the render server, one commit each way, so a busy window
/// server never holds the row for it, and the tab's row draws nothing anew
/// while it moves.
struct PeekMark: NSViewRepresentable {
    let page: Tab?
    let since: Date

    func makeNSView(context: Context) -> PeekMarkView { PeekMarkView() }
    func updateNSView(_ view: PeekMarkView, context: Context) { view.wear(page, since: since) }
}

final class PeekMarkView: NSView {
    private let badge = CALayer()
    private let plate = CALayer()
    private let picture = CALayer()
    private weak var page: Tab?
    private var watch: AnyCancellable?

    /// Every mark there is, for the bench.
    static var all = NSHashTable<PeekMarkView>.weakObjects()
    var state: String {
        let shown = badge.presentation()?.opacity ?? -1
        return "page=\(page != nil) window=\(window != nil) opacity=\(badge.opacity) shown=\(shown) anims=\(badge.animationKeys() ?? []) frame=\(frame)"
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        PeekMarkView.all.add(self)
        wantsLayer = true
        badge.opacity = 0
        plate.shadowColor = NSColor.black.cgColor
        plate.shadowOpacity = 0.18
        plate.shadowRadius = 1.5
        plate.shadowOffset = CGSize(width: 0, height: -0.5)
        plate.borderWidth = 0.5
        picture.masksToBounds = true
        badge.addSublayer(plate)
        badge.addSublayer(picture)
        layer?.addSublayer(badge)
        paint()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.bounds = box
        badge.position = CGPoint(x: bounds.midX, y: bounds.midY)
        plate.frame = box
        plate.cornerRadius = side / 2
        plate.shadowPath = CGPath(ellipseIn: box, transform: nil)
        let inner = box.insetBy(dx: 1, dy: 1)
        picture.frame = inner
        picture.cornerRadius = inner.width / 2
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
        if let page { show(page.icon, fade: false) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let page { show(page.icon, fade: false) }
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            plate.backgroundColor = Palette.NS.ground.cgColor
            plate.borderColor = Palette.NS.ink.withAlphaComponent(0.08).cgColor
            CATransaction.commit()
        }
    }

    /// The page it shows, or nil as it goes. A peek just opened pops in a
    /// beat after its panel starts coming, so the eye meets the page first.
    func wear(_ page: Tab?, since: Date) {
        guard page !== self.page else { return }
        let first = self.page == nil
        self.page = page
        guard let page else {
            watch = nil
            return go()
        }
        var initial = true
        watch = page.changes(\.icon).sink { [weak self] icon in
            self?.show(icon, fade: !initial || !first)
        }
        initial = false
        if first {
            // A view not yet in a window has no render tree to run it in:
            // the pop waits until the view is in one.
            coming = Date().timeIntervalSince(since) < 0.4
            if window != nil { come() }
        }
    }

    private var coming: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, coming != nil { come() }
    }

    private func show(_ icon: NSImage?, fade: Bool) {
        let scale = window?.backingScaleFactor ?? 2
        let image = icon ?? Glyphs.image("globe", size: 5, color: Palette.NS.ink.withAlphaComponent(0.5))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if fade {
            let swap = CATransition()
            swap.type = .fade
            swap.duration = 0.15
            picture.add(swap, forKey: "contents")
        }
        picture.contentsScale = scale
        picture.contentsGravity = icon == nil ? .center : .resizeAspectFill
        picture.contents = image?.layerContents(forContentsScale: scale)
        CATransaction.commit()
    }

    private func come() {
        guard let pop = coming else { return }
        coming = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.removeAllAnimations()
        badge.opacity = 1
        badge.transform = CATransform3DIdentity
        if pop {
            let pace = Reshape.Pace.arrive
            let start = badge.convertTime(CACurrentMediaTime(), from: nil) + 0.12
            for (key, from) in [("opacity", 0.0), ("transform.scale", 0.5)] {
                let move = CABasicAnimation(keyPath: key)
                move.fromValue = from
                move.toValue = 1.0
                move.duration = pace.duration
                move.timingFunction = pace.timing
                move.beginTime = start
                move.fillMode = .backwards
                badge.add(move, forKey: key)
            }
        }
        CATransaction.commit()
    }

    private func go() {
        let pace = Reshape.Pace.depart
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.removeAllAnimations()
        badge.opacity = 0
        badge.transform = CATransform3DMakeScale(0.6, 0.6, 1)
        for (key, from, to) in [("opacity", 1.0, 0.0), ("transform.scale", 1.0, 0.6)] {
            let move = CABasicAnimation(keyPath: key)
            move.fromValue = from
            move.toValue = to
            move.duration = pace.duration
            move.timingFunction = pace.timing
            badge.add(move, forKey: key)
        }
        CATransaction.commit()
    }
}
