import AppKit
import AVFoundation
import Combine
import CoreLocation
import SwiftUI
import WebKit

// What a page asks: alert(), confirm(), prompt(), the camera, the microphone,
// where you are, and to open another app.
//
// One card, in one of two places. What holds the page still, alert,
// confirm, prompt, stands in the middle of the page over a light dimming,
// since the page can do nothing until it is answered and the dimming says so.
// Another app's link stands there too, without the dimming: it is a
// question about leaving the page, not one about the site, and it is met
// where the eye is when a click or a sign-in hands off to an app. What only
// asks leave, the camera, the microphone, a location, hangs from the tab
// that asked and leaves the page to be read. A tab behind that asks keeps its
// question until you go back: a bubble where its mark was, as a put-off
// password is a key. A small window's page has no tab to hang from, and
// every question stands in its middle or at its top (LinkWindow.swift).
//
// Return answers yes, Escape no, and the buttons say so while those keys
// would reach them. What would be a third button, never here, always, stop
// this page, is a box to tick beside the two, as on Dia's.
//
// The icon's well is quiet: a wash of ink and a hairline, the mark the
// extensions' arrival wears. The only color on the card is someone's own,
// the site asking, the app it wants to open. The first time a site's
// question is also macOS's question about yab, the card stays up through
// it: a run goes round the well while the macOS window is up and the words
// say what to press there. A yes goes at once, as a no does: the page and
// the dot on its tab say it's on, and a tick would only say it again. A no
// from macOS stays, saying where to change it.
//
// These come often, so the motion is plain (family-values-motion P10): in
// and out on the one curve, the words replaced in place. It is all Core
// Animation's, on the render server (AskView), so a busy Mac never holds the
// window for a card coming or going.

/// One question a page is waiting on.
struct PageAsk: Identifiable, Equatable {
    enum Kind: Equatable {
        case alert, confirm, prompt
        case capture(PageCapture)
        case location
        /// A link for another app, with the app that would open it.
        case app(URL, URL)
        /// Asked for something macOS has told yab it may not have.
        case barred(Barred)
        /// A site behind a name and a password, HTTP's own sign-in, with
        /// the realm it names.
        case signIn(String)
        /// yab's own question, not the page's: a server on this Mac, whose
        /// pages may be being made, in Developer Mode? (DevMode.swift)
        case devMode
        /// What to show the page: a tab, a window, a screen (Share.swift).
        case share(SharePicker)
        /// yab's own: the page stopped answering out of sight while holding
        /// something typed (Stuck.swift).
        case stuck
        /// yab's own: a change of its own wants the page loaded again while
        /// it holds something typed, with why in `message` (ReloadAsk.swift).
        case reload
        /// To show notifications on this Mac (SiteNotices.swift).
        case notifications
        /// To reach apps on this Mac (true) or devices on the network
        /// (LocalNetwork.swift).
        case localNetwork(Bool)
        /// To send a file nobody asked for (SiteDownloads.swift), with its
        /// name in `message`.
        case download
        /// To send more files than the one a click asked for, as
        /// Arc asks (SiteDownloads.swift), with their names in `message`.
        case downloads
        /// The page's beforeunload: leaving it, closed or taken elsewhere,
        /// may lose what was typed in it (LeavePage.swift).
        case leave
        /// Something else a Chromium page asks for (SitePermissions.swift).
        case site(SitePermission)
    }

    enum Barred: Equatable { case camera, microphone, location, notifications }

    enum Stage: Equatable {
        case asking
        /// Allowed here, and macOS is asking about yab.
        case waiting
    }

    let id = UUID()
    var kind: Kind
    /// The site asking, the frame's, which for an embedded page is not the
    /// tab's.
    let host: String
    var message = ""
    /// The site the tab was on when it was asked: leaving it takes the
    /// question, a frame's own address changing doesn't.
    var place = ""
    /// What a prompt() is answered with, as it is typed; the name, for a
    /// sign-in.
    var text = ""
    /// A sign-in's password, as it is typed.
    var secret = ""
    /// A sign-in asked again: the last name and password didn't work.
    var failed = false
    /// A sign-in filled from Passwords, so there's nothing to keep.
    var kept = false
    /// A sign-in over plain http, where the password goes as it is typed.
    var clear = false
    var stage = Stage.asking
    /// The box beside the buttons: remember for this site, always open, or
    /// don't let this page ask again.
    var ticked = false
    /// The page's second question or later: the box to make it stop is
    /// offered.
    var persistent = false
    /// Asked by a tab behind, or left there: a bubble on the tab.
    var parked = false
    /// A long message, opened out.
    var opened = false
    /// Bumped on every change, so a timer only takes down what it was set for.
    var beat = 0

    var fromPage: Bool { kind == .alert || kind == .confirm || kind == .prompt }

    /// One site decision, shared by all pending device requests. Allow is
    /// remembered across tabs and launches; dismissal and denial keep nothing.
    static func capture(_ type: PageCapture, host: String) -> PageAsk {
        PageAsk(kind: .capture(type), host: host)
    }

    var signingIn: Bool {
        if case .signIn = kind { return true }
        return false
    }

    /// The page can do nothing until it is answered: the dimming says so.
    var holds: Bool { fromPage || signingIn }

    /// With a field of its own, which keeps Return and Escape.
    var typed: Bool { kind == .prompt || signingIn }

    /// What to show a page, in ⌘T's box (Share.swift).
    var sharing: Bool {
        if case .share = kind { return true }
        return false
    }

    /// In the middle of the page rather than hanging from the tab.
    var centered: Bool {
        if case .app = kind { return true }
        return holds || sharing || kind == .stuck || kind == .reload || kind == .leave
    }

    /// The words of the box beside the buttons, if it has one.
    var box: String? {
        switch kind {
        case .alert, .confirm, .prompt: return persistent ? "Don’t show more from this page" : nil
        case .location: return "Remember for this site"
        case .app: return "Always from this site"
        case .capture, .barred, .devMode, .share, .stuck, .reload, .leave, .notifications, .localNetwork, .download, .downloads, .site: return nil
        case .signIn: return kept ? nil : "Keep in Passwords"
        }
    }

    static func == (a: PageAsk, b: PageAsk) -> Bool {
        a.id == b.id && a.kind == b.kind && a.stage == b.stage && a.text == b.text && a.secret == b.secret && a.ticked == b.ticked
            && a.persistent == b.persistent && a.parked == b.parked && a.opened == b.opened && a.beat == b.beat
    }
}

extension PageAsk.Kind {
    /// A yes that leaves the card up: macOS may ask next.
    var stays: Bool {
        switch self {
        case .capture, .location, .notifications: return true
        default: return false
        }
    }
}

/// How a question was answered.
enum AskReply {
    /// OK, Allow, Open, with what a prompt was answered.
    case yes(String?)
    /// Cancel, Don't allow.
    case no
}

/// The answers still owed, by question. WebKit holds the page until each is
/// called, and treats one never called as a crash.
@MainActor
enum Asks {
    static var owed: [UUID: (AskReply, PageAsk) -> Void] = [:]
    /// What to do if the card is canceled while macOS is asking.
    static var waiting: [UUID: (Bool) -> Void] = [:]
    static var captures: [UUID: CaptureQuestion] = [:]
}

/// Device callbacks belong to one page and origin, not to separate cards.
/// Membership lasts until the person answers, without a coalescing timer.
@MainActor
final class CaptureQuestion {
    let page: NSView
    let site: String
    var requests: [UUID: (PageCapture, (PagePermission) -> Void)] = [:]
    init(page: NSView, site: String) { self.page = page; self.site = site }
    var type: PageCapture {
        let types = requests.values.map { $0.0 }
        return types.allSatisfy { $0 == .camera } ? .camera
            : types.allSatisfy { $0 == .microphone } ? .microphone : .cameraAndMicrophone
    }
    func finish(_ permission: PagePermission) {
        let pending = requests.values.map { $0.1 }
        requests.removeAll()
        for reply in pending { reply(permission) }
    }
}

// MARK: - asking and answering

extension Browser {
    /// A page's question, on the page if its tab is in front, waiting on the
    /// tab if not. One at a time per tab; the rest queue behind it.
    func ask(_ question: PageAsk, on tab: Tab, reply: @escaping (AskReply, PageAsk) -> Void) {
        var question = question
        if question.fromPage {
            // Told to stop: answered at once, the way nobody pressing
            // anything would, OK for an alert, no for the rest.
            if tab.hushed == question.host {
                reply(question.kind == .alert ? .yes(nil) : .no, question)
                return
            }
            // From a page's second question on, the box to
            // make it stop: until the tab shows another document.
            question.persistent = tab.pageDialogs > 0
            tab.pageDialogs += 1
        }
        // A small window's page is always the one in front of its window.
        // The half beside the tab in front is on screen too: its question
        // comes down over it.
        question.parked = !onScreen(tab.id) && !outside.contains { $0 === tab }
        question.place = Self.site(Self.shownHost(tab) ?? question.host)
        Asks.owed[question.id] = reply
        // The card comes in on the render server (AskView); a bubble on a
        // tab behind is the only thing SwiftUI moves for it.
        if question.parked {
            withAnimation(Motion.reshape) { tab.asks.append(question) }
        } else {
            Self.atOnce { tab.asks.append(question) }
        }
    }

    /// The question on the tab, answered. What follows a yes to the camera,
    /// macOS asked, is the asker's to show.
    /// `remember`: kept for the site (true) or for this time only (false),
    /// as the button pressed says; nil is the box's say, and for the camera
    /// and the microphone Return keeps Allow for the site; Escape keeps nothing.
    func answer(_ tab: Tab, _ reply: AskReply, remember: Bool? = nil) {
        guard let question = tab.asks.first else { return }
        switch question.stage {
        case .asking:
            var question = question
            if let remember { question.ticked = remember }
            else if case .capture = question.kind, case .yes = reply { question.ticked = true }
            if case .barred(let what) = question.kind, case .yes = reply { Self.openPrivacy(what) }
            if question.fromPage, question.persistent, question.ticked { tab.hushed = question.host }
            // A site's notifications and downloads are remembered whatever
            // is pressed, with no box: only a card taken away by leaving
            // says nothing.
            if question.kind == .notifications || question.kind == .download || question.kind == .downloads { question.ticked = true }
            if case .site = question.kind { question.ticked = true }
            let paid = settle(question, reply)
            if case .yes = reply, paid, question.kind.stays { return }
            dismissAsk(tab)
        case .waiting:
            // Canceled while macOS asks: the site hears no, whatever macOS says.
            Asks.waiting.removeValue(forKey: question.id)?(false)
            dismissAsk(tab)
        }
    }

    /// The page's own alert, confirm or prompt on the tab, answered from
    /// elsewhere (an extension's Page.handleJavaScriptDialog,
    /// ExtensionDebugger.swift) wherever it stands in the queue: a question
    /// of Yab's own may be in front of it.
    @discardableResult
    func answerPageDialog(_ tab: Tab, _ reply: AskReply) -> Bool {
        guard let index = tab.asks.firstIndex(where: { $0.fromPage }) else { return false }
        if index == 0 {
            answer(tab, reply)
            return true
        }
        let question = tab.asks[index]
        settle(question, reply)
        Self.atOnce { _ = tab.asks.remove(at: index) }
        return true
    }

    /// Return and Escape, OK or Allow, and Cancel or Not now, from the
    /// page, for the browser's window and a small one alike. What stands in
    /// the middle of the page can have them even with the caret in a field
    /// there: an alert holds the page still, and another app's link is
    /// asked the moment the page tries to leave for it. A question about the
    /// camera waits for the caret to leave, as the password does. A prompt's
    /// own box keeps its keys.
    func askKey(_ event: NSEvent, on tab: Tab) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              [36, 76, 53].contains(event.keyCode),
              let ask = tab.asks.first, !ask.parked, !ask.typed || ask.stage != .asking,
              let web = tab.builtPage, (event.window?.firstResponder as? NSView)?.isDescendant(of: web) == true,
              ask.centered || !tab.typing, !selectionHolds(tab)
        else { return false }
        let escape = event.keyCode == 53
        // Stopped answering, or holding something typed: Reload is ⌘R's,
        // not Return's.
        if !escape, ask.kind == .stuck || ask.kind == .reload { return false }
        // While macOS asks only Cancel is left.
        guard ask.stage == .asking || escape else { return false }
        answer(tab, escape ? .no : .yes(ask.text))
        return true
    }

    /// A command's result over the tab's selected words, its Return and
    /// Escape on its pill: the card hanging from the tab waits, so a
    /// Return meant for the words never answers the page's question.
    func selectionHolds(_ tab: Tab) -> Bool {
        selectionCommands.stage != .closed && selectionCommands.activeTab === tab
    }

    func typeAsk(_ tab: Tab, _ text: String) {
        guard !tab.asks.isEmpty else { return }
        tab.asks[0].text = text
    }

    func typeSecret(_ tab: Tab, _ text: String) {
        guard !tab.asks.isEmpty else { return }
        tab.asks[0].secret = text
    }

    func tickAsk(_ tab: Tab, _ on: Bool) {
        guard !tab.asks.isEmpty else { return }
        tab.asks[0].ticked = on
    }

    func openAsk(_ tab: Tab) { changeAsk(tab.asks.first?.id, on: tab) { $0.opened = true } }

    /// The one in front taken down; the next, if any, takes its place.
    func dismissAsk(_ tab: Tab) {
        guard let question = tab.asks.first else { return }
        settle(question, question.kind == .alert ? .yes(nil) : .no)
        Asks.waiting.removeValue(forKey: question.id)?(false)
        Self.atOnce { _ = tab.asks.removeFirst() }
    }

    /// A native callback ended. Remove only its own card, including a parked
    /// one, and settle its continuation once without dismissing another ask.
    func withdrawAsk(_ id: UUID, on tab: Tab) {
        guard let index = tab.asks.firstIndex(where: { $0.id == id }) else { return }
        let question = tab.asks[index]
        Self.atOnce { tab.asks.remove(at: index) }
        _ = settle(question, .no)
        Asks.waiting.removeValue(forKey: id)?(false)
    }

    /// A change to what the tab is asking, with nothing in SwiftUI animated
    /// by it: the card comes and goes on the render server (AskView).
    /// Animated here, the change reached every view that watches the tab,
    /// and each frame of it waited on the window server: on a busy Mac an
    /// answer held the window for up to half a second, card and all.
    static func atOnce(_ change: () -> Void) {
        var now = Transaction(animation: nil)
        now.disablesAnimations = true
        withTransaction(now, change)
    }

    /// Everything the tab is waiting on, answered no: it closed, or went to
    /// another site, and nobody is there to ask any more.
    func dropAsks(_ tab: Tab) {
        guard !tab.asks.isEmpty else { return }
        for question in tab.asks {
            settle(question, question.kind == .alert ? .yes(nil) : .no)
            Asks.waiting.removeValue(forKey: question.id)?(false)
        }
        Self.atOnce { tab.asks = [] }
    }

    /// Only a committed page at another site takes the questions away.
    /// An address update can name a provisional redirect, a download, or
    /// another app's link while the asking page is still there. Even the
    /// history list may have no current item then (#1459).
    func asksMoved(_ tab: Tab, to url: URL, committed: Bool = false) {
        guard committed else { return }
        let site = url.host().map(Self.site)
        if let hushed = tab.hushed, Self.site(hushed) != site { tab.hushed = nil }
        guard let question = tab.asks.first else { return }
        if let site, question.place == site { return }
        dropAsks(tab)
    }

    /// The host of the page the tab shows: its document, not an address
    /// the view is still only trying.
    static func shownHost(_ tab: Tab) -> String? {
        if let shown = tab.builtPage?.committedURL?.host(), !shown.isEmpty { return shown }
        return tab.address?.host()
    }

    /// Going to another tab leaves its question waiting on it; coming back
    /// brings it down again.
    func asksFollow(left: Tab?, to front: Tab?) {
        if let left, !onScreen(left.id), !left.asks.isEmpty, left.asks[0].parked == false {
            left.asks[0].parked = true
        }
        if let front, !front.asks.isEmpty, front.asks[0].parked {
            withAnimation(Motion.arrive) { front.asks[0].parked = false }
        }
    }

    // MARK: plumbing

    /// Pays what is owed, once. False if it was paid already.
    @discardableResult
    private func settle(_ question: PageAsk, _ reply: AskReply) -> Bool {
        guard let owed = Asks.owed.removeValue(forKey: question.id) else { return false }
        owed(reply, question)
        return true
    }

    /// The question with this id, changed wherever it is in the queue.
    func changeAsk(_ id: UUID?, on tab: Tab, _ edit: (inout PageAsk) -> Void) {
        guard let index = tab.asks.firstIndex(where: { $0.id == id }) else { return }
        var question = tab.asks[index]
        edit(&question)
        question.beat += 1
        Self.atOnce { tab.asks[index] = question }
    }

    /// On: the card goes, as it would for a no. The page and the dot on
    /// its tab say it's on.
    private func allowed(_ id: UUID, on tab: Tab) {
        guard tab.asks.first?.id == id else { return }
        dismissAsk(tab)
    }

    /// macOS said no after all: the card says so and where to change it,
    /// and owes nobody anything any more.
    private func refused(_ id: UUID, _ what: PageAsk.Barred, on tab: Tab) {
        changeAsk(id, on: tab) {
            $0.kind = .barred(what)
            $0.stage = .asking
        }
        Asks.owed[id] = { _, _ in }
    }

    private static func openPrivacy(_ what: PageAsk.Barred) {
        let pane: String
        switch what {
        case .camera: pane = "Privacy_Camera"
        case .microphone: pane = "Privacy_Microphone"
        case .location: pane = "Privacy_LocationServices"
        case .notifications: return MailNotify.shared.center.openSettings()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: the camera and the microphone

    /// Without this WebKit refuses every request out of hand, and a page that
    /// asks for the camera simply never gets an answer.
    func page(_ page: any PageHandle, capture type: PageCapture, origin: PageOrigin,
              reply: @escaping @MainActor (PagePermission) -> Void) {
        askCapture(page, origin, type, reply)
    }

    func askCapture(_ webView: NSView, _ origin: PageOrigin, _ type: PageCapture,
                    _ decisionHandler: @escaping @MainActor (PagePermission) -> Void) {
        let nativeLifetime = (webView as? ChromiumPage)?.questionRequests.presentingPermission
        guard nativeLifetime?.isActive != false else { decisionHandler(.deny); return }
        let owner = (webView as? any PageHandle).flatMap({ self.tab(owning: $0) })
        let host = origin.host.isEmpty ? (owner?.address?.host() ?? "This page") : origin.host
        let site = origin.host.isEmpty
            ? Self.origin(of: owner?.address)
            : Self.origin(scheme: origin.scheme, host: origin.host, port: origin.port)
        let key = Self.captureKey(site ?? host, type)
        // Remembered for the site when the box was ticked, or allowed on
        // this visit: a call asks again for its microphone alone, its camera
        // alone, at every join and device change, and each was a new card.
        if let remembered = Self.remembered(key, host: host, type) ?? Self.covered(site ?? host, host: host, type)
            ?? owner.flatMap({ Self.allowedThisVisit($0, site ?? host, type) }) {
            decisionHandler(remembered ? .grant : .deny)
            return
        }
        guard let tab = owner else {
            decisionHandler(.deny)
            return
        }
        let media: [AVMediaType] = type == .camera ? [.video] : type == .microphone ? [.audio] : [.video, .audio]
        // macOS said no to yab itself: the site's question can't be kept.
        if let refused = media.first(where: { [.denied, .restricted].contains(Self.macSaid($0)) }) {
            decisionHandler(.deny)
            ask(PageAsk(kind: .barred(refused == .video ? .camera : .microphone), host: host), on: tab) { _, _ in }
            return
        }
        let requestID = UUID()
        let existing = tab.asks.first { question in
            question.stage == .asking && Asks.captures[question.id].map {
                $0.page === webView && $0.site == (site ?? host)
            } == true
        }
        let question = existing ?? PageAsk.capture(type, host: host)
        let group = Asks.captures[question.id] ?? CaptureQuestion(page: webView, site: site ?? host)
        group.requests[requestID] = (type, decisionHandler)
        Asks.captures[question.id] = group
        nativeLifetime?.whenCancelled { [weak self, weak tab, weak group] in
            guard let self, let tab, let group,
                  let request = group.requests.removeValue(forKey: requestID) else { return }
            request.1(.deny)
            if group.requests.isEmpty {
                self.withdrawAsk(question.id, on: tab)
            } else if tab.asks.first(where: { $0.id == question.id })?.stage == .asking {
                self.changeAsk(question.id, on: tab) { $0.kind = .capture(group.type) }
            }
        }
        if existing != nil {
            changeAsk(question.id, on: tab) { $0.kind = .capture(group.type) }
            return
        }
        ask(question, on: tab) { [weak self, weak tab] reply, question in
            guard case .yes = reply, let self, let tab, !group.requests.isEmpty else {
                Asks.captures[question.id] = nil
                group.finish(.deny)
                return
            }
            let type = group.type
            let media: [AVMediaType] = type == .camera ? [.video] : type == .microphone ? [.audio] : [.video, .audio]
            let asking = media.filter { Self.macSaid($0) == .notDetermined }
            let complete: (Bool) -> Void = { granted in
                Asks.captures[question.id] = nil
                guard !group.requests.isEmpty else { return }
                if granted {
                    // Persist each device, so both engines and new tabs read
                    // the same site answer, including separately asked devices.
                    let kept = group.type
                    for device in media where kept == .cameraAndMicrophone || (device == .video ? kept == .camera : kept == .microphone) {
                        Store.settings.set(true, forKey: Self.captureKey(site ?? host, device == .video ? .camera : .microphone))
                    }
                    group.finish(.grant)
                    self.allowed(question.id, on: tab)
                } else {
                    group.finish(.deny)
                    let no = media.first { Self.macSaid($0) != .authorized } ?? .video
                    self.refused(question.id, no == .video ? .camera : .microphone, on: tab)
                }
            }
            guard !asking.isEmpty else { complete(true); return }
            self.changeAsk(question.id, on: tab) { $0.stage = .waiting }
            let once = OnceBool { granted in complete(granted) }
            Asks.waiting[question.id] = { _ in
                Asks.captures[question.id] = nil
                group.finish(.deny)
                once(false)
            }
            Self.request(asking) { granted in
                guard !once.done else { return }
                Asks.waiting[question.id] = nil
                once(granted)
            }
        }
    }

    /// A site as the camera and the microphone are remembered for it: its
    /// scheme, host and port, so http and https on one name, or two servers
    /// on two ports of localhost, are each asked for themselves.
    static func origin(scheme: String, host: String, port: Int) -> String {
        let scheme = scheme.lowercased()
        let port = port > 0 ? port : scheme == "http" ? 80 : scheme == "https" ? 443 : 0
        return "\(scheme)://\(host.lowercased()):\(port)"
    }

    static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme, let host = url.host(), !host.isEmpty else { return nil }
        return origin(scheme: scheme, host: host, port: url.port ?? 0)
    }

    /// What macOS said about Yab and this device. A test world on a Mac with
    /// nobody at it can be told macOS said yes, so a card's Allow reaches the
    /// page instead of a macOS window nobody will answer (Store.macSaysYes).
    static func macSaid(_ media: AVMediaType) -> AVAuthorizationStatus {
        Store.macSaysYes ? .authorized : AVCaptureDevice.authorizationStatus(for: media)
    }

    static func captureKey(_ site: String, _ type: PageCapture) -> String {
        "capture.\(site)|\(type.rawValue)"
    }

    /// What was said for the site. Said before the scheme and the port
    /// counted, it was kept under the bare host, and is read as https's on
    /// its usual port, where nearly every page that asks lives, and moved
    /// there the first time it is asked for.
    static func remembered(_ key: String, host: String, _ type: PageCapture) -> Bool? {
        if let said = Store.settings.object(forKey: key) as? Bool { return said }
        let old = captureKey(host, type)
        guard key == captureKey(origin(scheme: "https", host: host, port: 443), type),
              let said = Store.settings.object(forKey: old) as? Bool
        else { return nil }
        Store.settings.set(said, forKey: key)
        Store.settings.removeObject(forKey: old)
        return said
    }

    /// A yes kept for the camera and the microphone answers either alone,
    /// and a yes for each answers both: Meet asks for them together, then
    /// one at a time. A no is only ever the question's own.
    static func covered(_ site: String, host: String, _ type: PageCapture) -> Bool? {
        func yes(_ other: PageCapture) -> Bool { remembered(captureKey(site, other), host: host, other) == true }
        switch type {
        case .camera, .microphone: return yes(.cameraAndMicrophone) ? true : nil
        case .cameraAndMicrophone: return yes(.camera) && yes(.microphone) ? true : nil
        }
    }

    /// An Allow with the box unticked holds for the tab while it stays on
    /// the site, as Chromium's "Allow this time": closing the tab or leaving
    /// the site asks again.
    private struct Visit { weak var tab: Tab?; var site: String; var types: Set<PageCapture> }
    private static var visits: [Tab.ID: Visit] = [:]

    static func allowThisVisit(_ tab: Tab, _ site: String, _ type: PageCapture) {
        visits = visits.filter { $0.value.tab.map { !$0.gone } ?? false }
        var visit = visits[tab.id].flatMap { $0.site == site ? $0 : nil } ?? Visit(tab: tab, site: site, types: [])
        visit.types.insert(type)
        visits[tab.id] = visit
        ChromiumPermissions.changed()
    }

    /// What Chromium holds of each live visit's yes, for the pages of one of
    /// its profiles: Chrome keeps "Allow this time" in its own settings while
    /// it lasts, and its media code reads only those. Without it a call's
    /// page that was given the microphone was still, to Chromium, a site
    /// without it: enumerateDevices listed no speaker, and a speaker picked
    /// with setSinkId or an AudioContext's sinkId was refused (register 2319).
    static func visitGrants(profile: String) -> [(site: String, types: Set<PageCapture>)] {
        visits.values.compactMap { visit in
            guard let tab = visit.tab, !tab.gone, !tab.shy, tab.engineKind == .chromium,
                  origin(of: tab.address) == visit.site,
                  ((tab.builtPage as? ChromiumPage)?.profile ?? tab.chromiumProfile) == profile else { return nil }
            return (visit.site, visit.types)
        }
    }

    /// The tab closed or left the site: its visit's yes is over, here and in
    /// Chromium, where a one-time grant ends the same way.
    static func visitMoved(_ tab: Tab) {
        guard let visit = visits[tab.id], tab.gone || origin(of: tab.address) != visit.site else { return }
        visits[tab.id] = nil
        ChromiumPermissions.changed()
    }

    static func allowedThisVisit(_ tab: Tab, _ site: String, _ type: PageCapture) -> Bool? {
        guard let visit = visits[tab.id] else { return nil }
        // Gone to another site since: that yes is over.
        if let now = origin(of: tab.address), now != site {
            visits[tab.id] = nil
            return nil
        }
        guard visit.site == site else { return nil }
        let types = visit.types
        let covered = types.contains(type) || types.contains(.cameraAndMicrophone)
            || (type == .cameraAndMicrophone && types.contains(.camera) && types.contains(.microphone))
        return covered ? true : nil
    }

    static func locationKey(_ site: String) -> String { "location.\(site)" }

    /// A Chromium page's Allow with the box unticked holds for the tab while
    /// it stays on the site, as the camera's does and as Chromium's "Allow this
    /// time": Chromium asks again for every connection a page opens (a
    /// watchPosition after a getCurrentPosition was a second card nobody
    /// expected, and the page timed out). WebKit asks once a document.
    private static var locationVisits: [Tab.ID: Visit] = [:]

    static func allowLocationThisVisit(_ tab: Tab, _ site: String) {
        locationVisits = locationVisits.filter { $0.value.tab.map { !$0.gone } ?? false }
        locationVisits[tab.id] = Visit(tab: tab, site: site, types: [])
    }

    static func allowedLocationThisVisit(_ tab: Tab, _ site: String) -> Bool {
        guard let visit = locationVisits[tab.id] else { return false }
        if let now = origin(of: tab.address), now != site {
            locationVisits[tab.id] = nil
            return false
        }
        return visit.site == site
    }

    /// What was said for the site. Said before the scheme and the port
    /// counted, it was kept under the bare host: read as https's on its
    /// usual port, as the camera's is, and moved there.
    static func locationSaid(_ site: String, host: String) -> Bool? {
        let key = locationKey(site)
        if let said = Store.settings.object(forKey: key) as? Bool { return said }
        let old = locationKey(host)
        guard site == origin(scheme: "https", host: host, port: 443), let said = Store.settings.object(forKey: old) as? Bool else { return nil }
        Store.settings.set(said, forKey: key)
        Store.settings.removeObject(forKey: old)
        return said
    }

    private static func request(_ media: [AVMediaType], then done: @escaping @MainActor (Bool) -> Void) {
        guard let first = media.first else {
            done(true)
            return
        }
        AVCaptureDevice.requestAccess(for: first) { granted in
            DispatchQueue.main.async {
                guard granted else { return done(false) }
                request(Array(media.dropFirst()), then: done)
            }
        }
    }

    // MARK: where you are

    func page(_ page: any PageHandle, locate origin: PageOrigin,
              reply: @escaping @MainActor (PagePermission) -> Void) {
        askLocation(page, origin, reply)
    }

    /// The card, then macOS's own window the first time, then the page has
    /// where you are. WebKit asks macOS nothing and reads no location for
    /// an app that isn't Safari (Whereabouts.swift): a grant alone left the
    /// page waiting for ever with no macOS window (feedback #142).
    func askLocation(_ webView: NSView, _ origin: PageOrigin, _ decisionHandler: @escaping @MainActor (PagePermission) -> Void) {
        let nativeLifetime = (webView as? ChromiumPage)?.questionRequests.presentingPermission
        Whereabouts.shared.whenKnown { [weak self, weak webView] in
            guard let self, let webView, nativeLifetime?.isActive != false else { return decisionHandler(.deny) }
            self.decideLocation(webView, origin, nativeLifetime: nativeLifetime, decisionHandler)
        }
    }

    private func decideLocation(_ webView: NSView, _ origin: PageOrigin, nativeLifetime: PageFileRequest?,
                                _ decisionHandler: @escaping @MainActor (PagePermission) -> Void) {
        guard nativeLifetime?.isActive != false else { decisionHandler(.deny); return }
        let owner = (webView as? any PageHandle).flatMap({ self.tab(owning: $0) })
        let host = origin.host.isEmpty ? (owner?.address?.host() ?? "This page") : origin.host
        let site = origin.host.isEmpty ? Self.origin(of: owner?.address) : Self.origin(scheme: origin.scheme, host: origin.host, port: origin.port)
        let key = Self.locationKey(site ?? host)
        let place = Whereabouts.shared
        let remembered = Self.locationSaid(site ?? host, host: host)
        if remembered == false {
            decisionHandler(.deny)
            return
        }
        let tab = owner
        // macOS said no to Yab, or Location Services is off: the site's
        // question can't be kept, and the card says where to change it.
        if place.refused {
            decisionHandler(.deny)
            if let tab { ask(PageAsk(kind: .barred(.location), host: host), on: tab) { _, _ in } }
            return
        }
        // Allowed for the site before: macOS is asked about Yab, if it
        // never was, as that yes said it would be.
        let thisVisit = nativeLifetime != nil && tab.map { Self.allowedLocationThisVisit($0, site ?? host) } == true
        if remembered == true || thisVisit {
            place.authorize { [weak self, weak tab] yes in
                guard nativeLifetime?.isActive != false else { decisionHandler(.deny); return }
                guard yes else {
                    decisionHandler(.deny)
                    if let self, let tab { self.ask(PageAsk(kind: .barred(.location), host: host), on: tab) { _, _ in } }
                    return
                }
                place.install()
                decisionHandler(.grant)
            }
            return
        }
        guard let tab else {
            decisionHandler(.deny)
            return
        }
        let question = PageAsk(kind: .location, host: host)
        nativeLifetime?.whenCancelled { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.withdrawAsk(question.id, on: tab)
        }
        ask(question, on: tab) { [weak self, weak tab] reply, question in
            guard nativeLifetime?.isActive != false else { decisionHandler(.deny); return }
            guard case .yes = reply else {
                if question.ticked { Store.settings.set(false, forKey: key) }
                decisionHandler(.deny)
                return
            }
            guard let self, let tab else {
                decisionHandler(.deny)
                return
            }
            guard place.status == .notDetermined else {
                if question.ticked { Store.settings.set(true, forKey: key) }
                else if nativeLifetime != nil { Self.allowLocationThisVisit(tab, site ?? host) }
                place.install()
                decisionHandler(.grant)
                self.allowed(question.id, on: tab)
                return
            }
            // macOS asks about Yab now, in its own window, while the card
            // says what to press there.
            self.changeAsk(question.id, on: tab) { $0.stage = .waiting }
            let once = Once(decisionHandler)
            Asks.waiting[question.id] = { yes in once(yes ? .grant : .deny) }
            place.authorize { yes in
                guard !once.done else { return }
                Asks.waiting[question.id] = nil
                guard nativeLifetime?.isActive != false else { once(.deny); return }
                if yes {
                    if question.ticked { Store.settings.set(true, forKey: key) }
                    else if nativeLifetime != nil { Self.allowLocationThisVisit(tab, site ?? host) }
                    place.install()
                    once(.grant)
                    self.allowed(question.id, on: tab)
                } else {
                    once(.deny)
                    self.refused(question.id, .location, on: tab)
                }
            }
        }
    }

    // MARK: notifications

    func page(_ page: any PageHandle, notify origin: PageOrigin,
              reply: @escaping @MainActor (Bool) -> Void) {
        askNotifications(page, origin, reply)
    }

    func askNotifications(_ webView: NSView, _ origin: PageOrigin,
                          _ decisionHandler: @escaping @MainActor (Bool) -> Void) {
        let nativeLifetime = (webView as? ChromiumPage)?.questionRequests.presentingPermission
        guard nativeLifetime?.isActive != false else { decisionHandler(false); return }
        let site = Self.origin(scheme: origin.scheme, host: origin.host, port: origin.port)
        if let said = SiteNotices.said(site) {
            decisionHandler(said)
            return
        }
        guard SiteNotices.working, !origin.host.isEmpty, let tab = (webView as? any PageHandle).flatMap({ self.tab(owning: $0) }) else {
            decisionHandler(false)
            return
        }
        let host = origin.host
        let once = OnceBool(decisionHandler)
        Task { [weak self, weak tab] in
            // What macOS says now, read, never asked: that waits for Allow.
            await MailNotify.shared.refresh()
            guard let self, let tab, nativeLifetime?.isActive != false else { return once(false) }
            if MailNotify.shared.permission == .denied {
                once(false)
                self.ask(PageAsk(kind: .barred(.notifications), host: host), on: tab) { _, _ in }
                return
            }
            let question = PageAsk(kind: .notifications, host: host)
            nativeLifetime?.whenCancelled { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.withdrawAsk(question.id, on: tab)
            }
            self.ask(question, on: tab) { [weak self, weak tab] reply, question in
                guard nativeLifetime?.isActive != false else { once(false); return }
                guard case .yes = reply else {
                    if question.ticked { SiteNotices.remember(site, false) }
                    once(false)
                    return
                }
                guard let self, let tab else { return once(false) }
                guard MailNotify.shared.permission == .unasked else {
                    SiteNotices.remember(site, true)
                    once(true)
                    self.allowed(question.id, on: tab)
                    return
                }
                self.changeAsk(question.id, on: tab) { $0.stage = .waiting }
                // Canceled while macOS asks: the site hears no, and nothing
                // is remembered.
                Asks.waiting[question.id] = { yes in once(yes) }
                Task { @MainActor [weak self, weak tab] in
                    let granted = await SiteNotices.askMac()
                    guard !once.done else { return }
                    Asks.waiting[question.id] = nil
                    guard let self, let tab, nativeLifetime?.isActive != false else { return once(false) }
                    if granted {
                        SiteNotices.remember(site, true)
                        once(true)
                        self.allowed(question.id, on: tab)
                    } else {
                        once(false)
                        self.refused(question.id, .notifications, on: tab)
                    }
                }
            }
        }
    }

    // MARK: another app

    /// A frame below the page going to another app's link, not clicked:
    /// the page's own doing when the frame that asked is the page or of
    /// its site (a hidden frame it made to start an app, as Slack's
    /// redirect page does), or the person had just pressed in it. Another
    /// site's frame asking on its own, an advertisement, a frame with no
    /// origin of its own (sandboxed) is not; Chrome and Arc draw the line
    /// in the same place.
    static func pageAsks(_ source: PageAction.Source?, page: URL?, gesture: Bool) -> Bool {
        guard let source else { return gesture }
        return pageAsks(sourceIsPage: source.isMainFrame, sourceHost: source.host,
                        pageHost: page?.host(), gesture: gesture)
    }

    static func pageAsks(sourceIsPage: Bool, sourceHost: String, pageHost: String?, gesture: Bool) -> Bool {
        if gesture || sourceIsPage { return true }
        let source = sourceHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !source.isEmpty, let page = pageHost?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              !page.isEmpty else { return false }
        return source == page || Vault.registrable(source) == Vault.registrable(page)
    }

    /// A link for another app. Opened only once you say so, or at once, for
    /// a site you told to always, since otherwise any page could start any
    /// app it names. One with no app to open it goes nowhere. A mail or
    /// phone link you just clicked on is exactly what it says, and opens.
    func openElsewhere(_ url: URL, from page: any PageHandle, clicked: Bool = false) {
        // A mail link you clicked: a new mail over the page, Yab's own
        // (MailtoPeek.swift), with an account to send it from.
        if clicked, url.scheme?.lowercased() == "mailto", let tab = tab(owning: page), mailto(url, from: tab) { return }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        if clicked, ["mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
            return
        }
        guard let tab = tab(owning: page) else {
            NSWorkspace.shared.open(url)
            return
        }
        let host = tab.address?.host() ?? "This page"
        let key = "open.\(Self.site(host))|\(url.scheme ?? "")"
        if Store.settings.bool(forKey: key) {
            NSWorkspace.shared.open(url)
            return
        }
        // A page repeating the same link while the question is up asks once.
        if tab.asks.contains(where: { $0.kind == .app(url, app) }) { return }
        // Its name and icon, for the card, looked up while it comes in.
        FinderLooks.find(app.path) { _ in }
        ask(PageAsk(kind: .app(url, app), host: host), on: tab) { reply, question in
            guard case .yes = reply else { return }
            if question.ticked { Store.settings.set(true, forKey: key) }
            NSWorkspace.shared.open(url)
        }
    }
}

/// A decision handler that is called once, however many answers arrive.
@MainActor
/// A yes or no WebKit is owed, given once.
private final class OnceBool {
    private let handler: (Bool) -> Void
    private(set) var done = false
    init(_ handler: @escaping (Bool) -> Void) { self.handler = handler }
    func callAsFunction(_ yes: Bool) {
        guard !done else { return }
        done = true
        handler(yes)
    }
}

private final class Once {
    private let handler: (PagePermission) -> Void
    private(set) var done = false
    init(_ handler: @escaping (PagePermission) -> Void) { self.handler = handler }
    func callAsFunction(_ decision: PagePermission) {
        guard !done else { return }
        done = true
        handler(decision)
    }
}

// MARK: - where the card stands

/// Over the whole window: the card in the middle of the page for what holds
/// the page, hanging from its tab for what only asks. A small window's is
/// over that window, for its one page, with no password pill.
struct AskLayer: View {
    @ObservedObject var browser: Browser
    /// A small window's page; the browser's tab in front otherwise.
    var page: Tab? = nil

    var body: some View {
        GeometryReader { proxy in
            if let tab = page ?? browser.active {
                Placed(browser: browser, tab: tab, sky: browser.keySky, offers: page == nil,
                       origin: proxy.frame(in: .global).origin, window: proxy.size)
            }
            // The other half on screen asks over itself; a password to keep
            // is the half in front's alone.
            // Return and Esc go to the half in front's question alone: two
            // cards taking the same keys answered both at once.
            if page == nil, browser.splitShown, let pair = browser.stagePair, let id = browser.activeID,
               let other = browser.tabs.first(where: { $0.id == pair.other(than: id) }) {
                Placed(browser: browser, tab: other, sky: browser.keySky, offers: false,
                       origin: proxy.frame(in: .global).origin, window: proxy.size, keyed: false)
            }
        }
    }

    private struct Placed: View {
        @ObservedObject var browser: Browser
        @ObservedObject var tab: Tab
        /// Watched for the tab moving under its question (KeySky.moved).
        @ObservedObject var sky: KeySky
        let offers: Bool
        let origin: CGPoint
        let window: CGSize
        /// Its question may take Return and Esc: not the half behind's.
        var keyed = true
        /// Told where the card stands, for the corner's notice: the main
        /// window's half in front alone, not a small window's.
        private var room: AskRoom? { keyed && offers ? browser.askRoom : nil }
        /// A command's result is up over selected words (Browser.selectionHolds):
        /// watched as up or not, never at each word the answer brings.
        @State private var holding = false

        var body: some View {
            let question = tab.asks.first.flatMap { $0.parked ? nil : $0 }
            // A password to keep waits behind anything the page itself is
            // asking; see Keep.swift.
            let offer = question == nil && offers ? tab.offer.flatMap { $0.parked ? nil : $0 } : nil
            // A card or an address to keep waits behind both (WalletKeep).
            let pay = question == nil && offer == nil && offers ? tab.payOffer.flatMap { $0.parked ? nil : $0 } : nil
            let page = pageFrame
            let covered = browser.fieldShowing && (offers || !keyed)
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                if let offer {
                    // The page is live behind this one: a click on it is
                    // Not now, and the card folds away to its key.
                    Color.black.opacity(0.12)
                        .frame(width: page.width, height: page.height)
                        .clipShape(RoundedRectangle(cornerRadius: Backdrop.corner, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { browser.parkOffer(tab) }
                        .offset(x: page.minX, y: page.minY)
                        // Folding to its key, the card is still on its way
                        // out and the dimming goes with it; otherwise both go
                        // at once, as ⌘L's veil does.
                        .transition(offer.folding ? .opacity.animation(Motion.quick) : Self.veil)
                    KeepCard(browser: browser, tab: tab, offer: offer)
                        .position(x: page.midX, y: page.midY)
                        .transition(offer.folding ? Self.fold : offer.fromKey ? Self.unfold : Self.appear)
                        .id(offer.id)
                }
                if let pay {
                    // A click on the page behind is Not now, as with a password.
                    Color.black.opacity(0.12)
                        .frame(width: page.width, height: page.height)
                        .clipShape(RoundedRectangle(cornerRadius: Backdrop.corner, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { browser.parkPay(tab) }
                        .offset(x: page.minX, y: page.minY)
                        .transition(Self.payVeil)
                    PayCard(browser: browser, tab: tab, offer: pay)
                        .position(x: page.midX, y: page.midY)
                        .transition(Self.payCard)
                        .id(pay.id)
                }
                // Words pasted again and again, offered as a snippet
                // (SnippetOffers), behind anything else asked here.
                if question == nil, offer == nil, pay == nil, offers {
                    SnippetOfferLayer(tab: tab.id, page: page)
                }
                // The page's question, and the dimming under one that holds
                // the page, drawn and moved in AppKit: see AskView. Out of
                // sight while the field is up, which it would cover and take
                // the clicks of; back as it was once the field goes. The
                // browser's own field: a small window's page has none over it.
                AskHost(browser: browser, tab: tab, question: question, place: question.map { place($0, page) }, keys: keys(question),
                        covered: covered, room: room, origin: origin)
                    .frame(width: window.width, height: window.height)
                    // Over the whole window, where SwiftUI's accessibility
                    // hit test stops (as at HoardSky): kept out of it until
                    // there is a question on it to read, and while the field
                    // stands over it with the question out of sight.
                    .accessibilityHidden(question == nil || covered)
            }
            // Gone with its tab's layer: no card of its stands over the corner.
            .onDisappear { room?.card = nil }
            // The half in front's card, when it hangs from its tab; one in
            // the middle of the page hangs from nothing.
            .onChange(of: question?.id, initial: true) { _, id in
                guard keyed else { return }
                sky.watched = id != nil && question?.centered == false ? tab.id : nil
            }
            .frame(width: window.width, height: window.height, alignment: .topLeading)
            .onReceive(browser.selectionCommands.$stage.map { $0 != .closed }.removeDuplicates()) { holding = $0 }
        }

        /// The password card comes as ⌘L's field does: in from a touch
        /// smaller, out of its own middle, and gone at once when answered.
        private static let appear = AnyTransition.asymmetric(
            insertion: .scale(scale: 0.97).combined(with: .opacity).animation(Motion.arrive),
            removal: .identity
        )
        /// The dimming under it, in the same beat and gone with it.
        private static let veil = AnyTransition.asymmetric(
            insertion: .opacity.animation(Motion.arrive),
            removal: .identity
        )
        /// Into its mark, which is already on its way to the tab.
        private static let fold = AnyTransition.scale(scale: 0.92)
            .combined(with: .opacity)
            .animation(.timingCurve(0.4, 0, 0.8, 0.4, duration: 0.2))
        /// A card's or an address's question goes the one way whatever
        /// answered it, into its mark, which is on its way to the tab: fixed,
        /// not chosen by a flag set a moment before, which SwiftUI can take
        /// in the same update as the going and never draw.
        private static let payCard = AnyTransition.asymmetric(
            insertion: .scale(scale: 0.97).combined(with: .opacity).animation(Motion.arrive),
            removal: fold
        )
        private static let payVeil = AnyTransition.asymmetric(
            insertion: .opacity.animation(Motion.arrive),
            removal: .opacity.animation(Motion.quick)
        )
        /// Out of the mark that has just come down from the tab.
        private static let unfold = AnyTransition.asymmetric(
            insertion: .scale(scale: 0.92).combined(with: .opacity).animation(Motion.arrive),
            removal: .identity
        )

        /// The page, in the window's own space.
        private var pageFrame: CGRect {
            // A page out in the call's window is in another window: its rect
            // there put the share box from that window's Share off the
            // middle of this one (Meet, 0.46.10). The whole window then.
            guard let web = tab.builtPage, let content = web.window?.contentView,
                  web.window === BrowserWindows.shared.window(for: browser) else {
                return CGRect(origin: .zero, size: window)
            }
            let rect = web.convert(web.bounds, to: nil)
            return CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }

        /// Where a card hanging from the tab stands, and the point it grows
        /// out of and goes back into.
        private struct Spot {
            let x: CGFloat
            let y: CGFloat
            let growth: CGPoint
        }

        /// Return and Escape reach the card while nothing else of the
        /// window's has them. A page held by its own alert can't be typing
        /// into anything, and one that tries to open an app takes the keys
        /// from its field; see `Browser.askKey`.
        private func keys(_ question: PageAsk?) -> Bool {
            guard let question, keyed else { return false }
            let free = !browser.fieldShowing && !browser.finding && browser.editingTab == nil
                && !browser.welcoming && !(holding && browser.selectionHolds(tab))
            return free && (question.centered || !tab.typing)
        }

        /// In the middle of the page for what stands there, at its tab for
        /// the rest.
        private func place(_ question: PageAsk, _ page: CGRect) -> AskPlace {
            let width = AskCard.width(question)
            if question.centered {
                return AskPlace(centered: true, veiled: question.holds || question.sharing, x: page.midX - width / 2, y: page.midY,
                                width: width, growth: CGPoint(x: page.midX, y: page.midY), page: page)
            }
            let spot = anchor(page, width: width)
            return AskPlace(centered: false, veiled: false, x: spot.x, y: spot.y, width: width, growth: spot.growth, page: page)
        }

        /// Under its tab, lined up with it, with the tabs along the top;
        /// beside it at the page's edge, its well on the tab's line, with
        /// them down the side; at the top
        /// of the page when the tab can't be seen. It grows from the middle
        /// of the tab's own edge that faces it: its top edge under a tab in
        /// the row, however far the window's edge has pushed it along; its
        /// left edge, level with the tab, beside the column.
        private func anchor(_ page: CGRect, width given: CGFloat? = nil) -> Spot {
            let width = given ?? AskCard.width(tab.asks.first)
            let margin: CGFloat = 12
            func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
            guard let frame = sky.place(tab.id), frame.width > 0 else {
                let x = page.midX - width / 2, y = page.minY + margin
                return Spot(x: x, y: y, growth: at(page.midX, y))
            }
            let local = frame.offsetBy(dx: -origin.x, dy: -origin.y)
            if local.maxX <= page.minX + 1 {
                // The well on the tab's line: the eye goes from the tab to
                // the question's mark and on.
                let x = page.minX + margin
                let y = max(page.minY + margin, local.midY - CardFrame.inset - CardFrame.well / 2)
                return Spot(x: x, y: y, growth: at(x, local.midY))
            }
            let x = min(max(margin, local.minX), window.width - width - margin)
            let y = max(local.maxY + 8, page.minY + 8)
            return Spot(x: x, y: y, growth: at(min(max(local.midX, x), x + width), y))
        }
    }
}

// MARK: - the card, moved on the render server

/// Where the card stands, in the window's space from its top left: its
/// left edge and width, its top for one at the tab and its middle for one
/// in the middle of the page, the point it grows from and goes back into,
/// and the page, dimmed under a card that holds it.
struct AskPlace: Equatable {
    var centered: Bool
    var veiled: Bool
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var growth: CGPoint
    var page: CGRect
}

/// Where the page in front's card stands when it hangs from its tab, in
/// the window's SwiftUI space: the corner's notice ("Claude couldn't
/// finish") comes out under it rather than behind it (CornerNotices). A
/// card in the middle of the page is nowhere near the corner.
@MainActor
final class AskRoom: ObservableObject {
    @Published var card: CGRect?
}

/// Laid over the window, where the page's question comes up. With nothing
/// asked it is a view that takes no clicks and draws nothing.
struct AskHost: NSViewRepresentable {
    let browser: Browser
    let tab: Tab
    let question: PageAsk?
    let place: AskPlace?
    let keys: Bool
    /// ⌘T's or ⌘L's field is up over the page.
    var covered = false
    /// Told where the card stands, the window's half in front's alone.
    var room: AskRoom? = nil
    /// The layer's top left in the window's SwiftUI space.
    var origin: CGPoint = .zero

    func makeNSView(context: Context) -> AskView { AskView() }

    func updateNSView(_ view: AskView, context: Context) {
        let origin = origin
        view.placed = { [weak room] local in
            guard let room else { return }
            let card = local.map { $0.offsetBy(dx: origin.x, dy: origin.y) }
            // A turn later: told while SwiftUI updates this view, a change
            // would be one made during that update.
            DispatchQueue.main.async { if room.card != card { room.card = card } }
        }
        view.show(question, place: place, keys: keys, browser: browser, tab: tab)
        view.cover(covered)
    }
}

/// The card in a view of its own, the way the peek's panel is (LinkPeek):
/// SwiftUI draws what is on it, and its coming and going, the dimming
/// under it included, is handed to the render server in one commit, so no
/// frame of it waits on the main thread. Moved by SwiftUI, every frame was
/// a commit of the main thread's, and on a busy Mac each could wait on the
/// window server for half a second.
///
/// What hangs from a tab grows out of that tab and goes back into it the
/// same way (family-values-motion P3), from 0.6 of its size about the point
/// under the tab. What stands in the middle of the page comes as ⌘L's field
/// does, from a touch smaller, and is gone at once when answered, the
/// dimming with it.
final class AskView: NSView {
    private final class Card: NSView {
        let id: UUID
        let host: Host
        var place: AskPlace

        init(id: UUID, face: AskFace, place: AskPlace) {
            self.id = id
            self.place = place
            host = Host(rootView: face)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = false
            host.sizingOptions = [.intrinsicContentSize]
            // Up by the tabs across the top the card's room reaches into
            // the title bar, whose safe area would push the card down by its
            // height and it would stand that much below its tab.
            host.safeAreaRegions = []
            addSubview(host)
        }

        required init?(coder: NSCoder) { nil }
    }

    /// Says when what it shows wants another size: a message opened out,
    /// the words for macOS's own question.
    private final class Host: NSHostingView<AskFace> {
        var resized: (() -> Void)?
        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak self] in self?.resized?() }
        }
    }

    /// Room round the card for its shadow, which SwiftUI draws only inside
    /// its own view.
    static let margin: CGFloat = 40
    private static let grown: CGFloat = 0.6
    private static let near: CGFloat = 0.97

    private var card: Card?
    /// The page dimmed under a card that holds it, a layer and nothing more.
    private let dim = CALayer()
    private var dimmed: CGRect?

    /// Every one there is, for the bench: how many cards are in sight.
    static let all = NSHashTable<AskView>.weakObjects()
    /// Told where a card that hangs from its tab stands, in the layer's
    /// space from its top left, or nil with none or while it is covered:
    /// see AskRoom.
    var placed: ((CGRect?) -> Void)?
    /// Where the card last stood, told again as it comes back from under
    /// the field.
    private var stood: CGRect?
    private func report(_ card: CGRect?) {
        stood = card
        placed?(covered ? nil : card)
    }
    var showing: Bool { card != nil && !covered && window != nil }

    /// For the bench: the card on the screen without its shadow's room, its
    /// window, and what has the keys there.
    var probe: [String: Any]? {
        guard let card, let window else { return nil }
        let inner = window.convertToScreen(convert(card.frame.insetBy(dx: Self.margin, dy: Self.margin), to: nil))
        return ["screen": [inner.minX, inner.minY, inner.width, inner.height],
                "window": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
                "class": "\(type(of: window))", "key": window.isKeyWindow, "covered": covered,
                "responder": window.firstResponder.map { "\(type(of: $0))" } ?? "none"]
    }

    init() {
        super.init(frame: .zero)
        AskView.all.add(self)
        wantsLayer = true
        layer?.masksToBounds = false
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        dim.cornerRadius = Backdrop.corner
        dim.cornerCurve = .continuous
        dim.opacity = 0
        dim.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(dim)
    }

    required init?(coder: NSCoder) { nil }

    /// Only the card takes clicks, and the dimmed page, which a held page
    /// can't have.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if covered { return nil }
        let local = convert(point, from: superview)
        if let card, card.frame.insetBy(dx: Self.margin, dy: Self.margin).contains(local) {
            return card.hitTest(local)
        }
        if let dimmed, dimmed.contains(local) { return self }
        return nil
    }

    override func mouseDown(with event: NSEvent) {}

    /// While ⌘T's or ⌘L's field is up the card and its dimming step aside,
    /// as the field's keys are already its own: drawn over the field, a
    /// card hanging from a tab low in the column hid the field's rows and
    /// its foot. Gone at once as the field comes, so it is never seen over
    /// the field on its way in (a fade left it there for a tenth of a
    /// second); back with a fade as the field goes, where it was, still
    /// asking.
    private(set) var covered = false

    func cover(_ on: Bool) {
        guard on != covered, let layer else { return }
        covered = on
        // The corner's notice stands under no card while it is covered.
        placed?(on ? nil : stood)
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "ask.opacity")
        layer.opacity = on ? 0 : 1
        CATransaction.commit()
        if !on { Self.run(layer, "opacity", from: from, to: layer.opacity, .arrive) }
    }

    func show(_ question: PageAsk?, place: AskPlace?, keys: Bool, browser: Browser, tab: Tab) {
        if let card, card.id != question?.id || place == nil {
            self.card = nil
            leave(card)
        }
        guard let question, let place else { report(nil); return shade(nil) }
        let face = AskFace(browser: browser, tab: tab, question: question, keys: keys)
        if let card {
            card.host.rootView = face
            card.place = place
            lay(card)
        } else {
            let card = Card(id: question.id, face: face, place: place)
            card.host.resized = { [weak self, weak card] in
                guard let self, let card, card === self.card else { return }
                self.lay(card)
            }
            addSubview(card)
            self.card = card
            lay(card)
            arrive(card)
        }
        shade(place.veiled ? place.page : nil)
    }

    // MARK: where

    /// A rect from the window's top left, in this view's own space, whose
    /// y runs up.
    private func up(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func lay(_ card: Card) {
        let size = card.host.intrinsicContentSize
        let m = Self.margin
        let place = card.place
        let top = place.centered ? place.y - size.height / 2 : place.y - m
        let frame = up(CGRect(x: place.x - m, y: top, width: size.width, height: size.height)).integral
        // The card itself, inside the room round it for its shadow.
        report(place.centered ? nil : CGRect(x: place.x, y: top + m, width: size.width - 2 * m, height: size.height - 2 * m))
        guard card.frame != frame else { return }
        card.frame = frame
        card.host.frame = card.bounds
    }

    override func layout() {
        super.layout()
        if let card { lay(card) }
    }

    /// The point a card grows about, in its own layer's space: a view's
    /// layer hangs from its corner, so the scale is carried by a step
    /// towards that point.
    private func scaled(_ card: Card, _ scale: CGFloat) -> CATransform3D {
        let point: CGPoint
        if card.place.centered {
            point = CGPoint(x: card.bounds.midX, y: card.bounds.midY)
        } else {
            let growth = card.place.growth
            point = card.convert(CGPoint(x: growth.x, y: bounds.height - growth.y), from: self)
        }
        return CATransform3DConcat(
            CATransform3DMakeScale(scale, scale, 1),
            CATransform3DMakeTranslation((1 - scale) * point.x, (1 - scale) * point.y, 0)
        )
    }

    // MARK: coming and going

    private func arrive(_ card: Card) {
        guard let layer = card.layer else { return }
        let pace = Reshape.Pace.arrive
        let from = scaled(card, card.place.centered ? Self.near : Self.grown)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        Self.run(layer, "opacity", from: 0, to: 1, pace)
        Self.run(layer, "transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: CATransform3DIdentity), pace)
        CATransaction.commit()
    }

    /// Back into its tab, or gone at once from the middle of the page. It
    /// takes no clicks on its way.
    private func leave(_ card: Card) {
        guard !card.place.centered, let layer = card.layer, window != nil else { return card.removeFromSuperview() }
        let pace = Reshape.Pace.depart
        let to = scaled(card, Self.grown)
        var gone = false
        let finish = {
            guard !gone else { return }
            gone = true
            card.removeFromSuperview()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
        layer.opacity = 0
        layer.transform = to
        Self.run(layer, "opacity", from: 1, to: 0, pace)
        Self.run(layer, "transform", from: NSValue(caTransform3D: CATransform3DIdentity), to: NSValue(caTransform3D: to), pace)
        CATransaction.commit()
        // The completion can wait on a busy render server; the page doesn't.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish() }
    }

    /// In with the card, in the same beat; gone at once, with it.
    private func shade(_ page: CGRect?) {
        let rect = page.map(up)
        guard rect != dimmed else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let rect {
            dim.frame = rect
            if dimmed == nil {
                dim.opacity = 1
                Self.run(dim, "opacity", from: 0, to: 1, .arrive)
            }
        } else {
            dim.removeAllAnimations()
            dim.opacity = 0
        }
        CATransaction.commit()
        dimmed = rect
    }

    private static func run(_ layer: CALayer, _ key: String, from: Any, to: Any, _ pace: Reshape.Pace) {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = pace.duration
        animation.timingFunction = pace.timing
        layer.add(animation, forKey: "ask." + key)
    }
}

/// What the card's own view shows: the card, with room round it for its
/// shadow.
struct AskFace: View {
    let browser: Browser
    let tab: Tab
    let question: PageAsk
    let keys: Bool

    var body: some View {
        AskCard(browser: browser, tab: tab, question: question, keys: keys)
            .frame(width: AskCard.width(question))
            .padding(AskView.margin)
    }
}

// MARK: - the card

/// Drawn in a view of its own (AskView), and so it watches nothing: the
/// question, and whether Return and Escape would reach it, are handed to it
/// after they have changed. A card that watched the tab had its window's
/// SwiftUI work out the page's question again while the tab was still
/// changing, from what it had been, and a question could fail to show.
struct AskCard: View {
    let browser: Browser
    let tab: Tab
    let question: PageAsk
    /// Return and Escape would reach the card: see `Browser.askKey`.
    let keys: Bool
    @FocusState private var typing: Bool
    @FocusState private var typingSecret: Bool

    /// 440 with a box to tick, so the box and both buttons share one line
    /// whatever the buttons say; 380 without, a little wider for a prompt or
    /// a long message. Kept through a question's stages, so the card never
    /// changes width under the eye.
    static func width(_ question: PageAsk?) -> CGFloat {
        guard let question else { return 440 }
        if case .share = question.kind { return ShareBox.width }
        if question.box != nil || question.kind.stays || question.signingIn { return 440 }
        if question.fromPage, question.kind == .prompt || question.message.count > 90 { return 420 }
        return 380
    }

    /// Long messages stop here until opened.
    private static let lines = 6

    var body: some View {
        if case .share(let picker) = question.kind {
            // ⌘T's box in the middle of the page, not a card (Share.swift).
            ShareBox(browser: browser, tab: tab, picker: picker)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The well in the card's corner, as far in as it sits down, so
            // it rounds off on the card's own curve; the words start level
            // with its top, however many lines they run to.
            HStack(alignment: .top, spacing: CardFrame.wellGap) {
                well
                VStack(alignment: .leading, spacing: 2) {
                    if question.holds {
                        Text(question.typed ? "\(IDN.shown(question.host)) asks" : "\(IDN.shown(question.host)) says")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    Text(title)
                        .font(CardFrame.title)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(question.fromPage && !question.opened ? Self.lines : nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .id(title)
                        .transition(.opacity.animation(Motion.morph))
                    if !detail.isEmpty {
                        Text(detail)
                            .font(CardFrame.detail)
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 1)
                            .id(detail)
                            .transition(.opacity.animation(Motion.morph))
                    }
                    if question.fromPage, !question.opened, Self.long(question.message) {
                        Button("Show All") { browser.openAsk(tab) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A prompt's answer, the card's whole width under the words.
            if question.kind == .prompt { field.padding(.top, 12) }
            if question.signingIn { signIn.padding(.top, 12) }
            foot.padding(.top, CardFrame.buttonGap)
        }
        .cardFrame(glass: true)
        .onAppear {
            guard question.typed else { return }
            // A kept name is left to be answered with Return; the password
            // is what a second go needs.
            DispatchQueue.main.async {
                if question.signingIn, !question.text.isEmpty { typingSecret = true } else { typing = true }
            }
        }
    }

    // MARK: the well

    private static let side = CardFrame.well
    private static let corner = Radius.control

    private var well: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        return Group {
            switch question.kind {
            case .app(_, let app):
                FinderIcon(path: app.path)
                    .frame(width: Self.side + 4, height: Self.side + 4)
                    .frame(width: Self.side, height: Self.side)
            case .alert, .confirm, .prompt, .signIn, .share, .stuck, .reload, .leave:
                siteMark(size: Self.side)
            case .devMode:
                // The tape the tab will wear, round the well (DevTape).
                shape.fill(Palette.ink.opacity(0.05))
                    .overlay(DevTape())
                    .overlay { Symbol(Self.glyph(question.kind), size: 16).foregroundStyle(Palette.ink) }
                    .frame(width: Self.side, height: Self.side)
            default:
                shape.fill(Palette.ink.opacity(0.05))
                    .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
                    .overlay { Symbol(Self.glyph(question.kind), size: 16).foregroundStyle(Palette.ink) }
                    .frame(width: Self.side, height: Self.side)
            }
        }
        .overlay {
            if question.kind.stays {
                Seam(size: Self.side, corner: Self.corner, working: question.stage == .waiting, ticked: false)
            }
        }
        // The badge in a hole cut out of the well and its seam, not on a
        // plate of the card's color (Design.swift's `notched`).
        .notched(question.kind.stays, side: 15, radius: 4, offset: 5)
        .overlay(alignment: .bottomTrailing) { badge.offset(x: 5, y: 5) }
    }

    /// Who is asking, at the well's corner.
    @ViewBuilder
    private var badge: some View {
        if question.kind.stays {
            siteMark(size: 15)
                .transition(.opacity)
        }
    }

    private func siteMark(size: CGFloat) -> some View {
        let site = Browser.site(question.host)
        let here = Browser.site(tab.address?.host() ?? "") == site ? tab.icon : nil
        return Mark(icon: Favicons.shared.cached(question.host) ?? Favicons.shared.cached(site) ?? here,
                    letter: site.first.map { String($0).uppercased() } ?? "•", size: size)
    }

    private static func glyph(_ kind: PageAsk.Kind) -> String {
        switch kind {
        case .capture(let type): return type == .microphone ? "mic" : "video"
        case .location: return "location"
        case .notifications: return "bell"
        case .devMode: return "chevron.left.forwardslash.chevron.right"
        case .localNetwork: return "devices"
        case .site(let kind): return kind.symbol
        case .download, .downloads: return "arrow.down.to.line"
        case .barred(let what):
            switch what {
            case .camera: return "video.slash"
            case .microphone: return "mic.slash"
            case .location: return "location"
            case .notifications: return "bell"
            }
        default: return "globe"
        }
    }

    // MARK: the words

    private var title: String {
        let host = IDN.shown(question.host)
        switch (question.kind, question.stage) {
        case (.alert, _), (.confirm, _), (.prompt, _):
            return question.message.isEmpty ? (question.kind == .alert ? "This page has something to say." : "Continue?") : question.message
        case (.signIn(let realm), _):
            return realm.isEmpty ? "Sign in to \(host)" : "Sign in to “\(realm)”"
        case (.capture, .waiting), (.location, .waiting), (.notifications, .waiting): return "Choose “Allow” in the macOS window"
        case (.capture(let type), _): return "\(host) wants \(Self.wants(type))"
        case (.location, _): return "\(host) wants to know where you are"
        case (.notifications, _): return "\(host) wants to send notifications"
        case (.app(_, let app), _): return "\(host) wants to open \(Self.name(of: app))"
        case (.devMode, _): return "Turn on Developer Mode for \(host)?"
        case (.localNetwork(let here), _): return here ? "\(host) wants to connect to apps on this Mac" : "\(host) wants to connect to devices on your network"
        case (.site(let kind), _): return "\(host) wants to \(kind.words)"
        case (.download, _): return "\(host) wants to download a file"
        case (.downloads, _): return "\(host) wants to download multiple files"
        case (.stuck, _): return "This page stopped answering"
        case (.reload, _): return "Reload this page?"
        case (.leave, _): return "Leave this page?"
        case (.share, _): return "Choose what to share with \(host)"
        case (.barred(let what), _):
            switch what {
            case .camera: return "macOS didn’t let Yab use the camera"
            case .microphone: return "macOS didn’t let Yab use the microphone"
            case .location: return "macOS didn’t let Yab know where you are"
            case .notifications: return "macOS doesn’t let Yab show notifications"
            }
        }
    }

    private var detail: String {
        let host = IDN.shown(question.host)
        switch (question.kind, question.stage) {
        case (.capture, .waiting), (.location, .waiting), (.notifications, .waiting): return "Then Yab hands it to \(host)."
        case (.notifications, _):
            return MailNotify.shared.permission == .unasked ? "macOS will ask about Yab once, next." : ""
        case (.capture(let type), _):
            return Self.macOSAsks(type) ? "macOS will ask about Yab once, next." : ""
        case (.location, _):
            // Only a Whereabouts a site's question made: drawing a card starts no CoreLocation.
            return !Whereabouts.made || Whereabouts.shared.status == .notDetermined ? "macOS will ask about Yab once, next." : ""
        case (.barred(let what), _):
            switch what {
            case .camera: return "It’s in System Settings › Privacy › Camera."
            case .microphone: return "It’s in System Settings › Privacy › Microphone."
            case .location: return "It’s in System Settings › Privacy › Location Services."
            case .notifications: return "It’s in System Settings › Notifications › Yab."
            }
        case (.devMode, _): return "Its whole address, what it logs and its requests, over the page."
        case (.download, _), (.downloads, _): return question.message
        // What reloading costs, said by whoever asks (Stuck.swift): a draft
        // lost, other tabs reloaded with it, or nothing to say.
        case (.stuck, _), (.reload, _): return question.message
        case (.leave, _): return "Changes you made may not be saved."
        case (.signIn, _):
            if question.failed { return "That name and password didn’t work." }
            return question.clear ? "Over plain http: anyone on this network could read the password." : ""
        default: return ""
        }
    }

    private static func wants(_ type: PageCapture) -> String {
        switch type {
        case .camera: return "your camera"
        case .microphone: return "your microphone"
        default: return "your camera and microphone"
        }
    }

    private static func macOSAsks(_ type: PageCapture) -> Bool {
        let media: [AVMediaType] = type == .camera ? [.video] : type == .microphone ? [.audio] : [.video, .audio]
        return media.contains { Browser.macSaid($0) == .notDetermined }
    }

    /// The Finder's name for the app, found off the main thread when the
    /// question was asked (openElsewhere); its file name until then.
    static func name(of app: URL) -> String {
        FinderLooks.name(app.path)
    }

    // MARK: the field

    /// A wash of ink in the buttons' shape, no box drawn round it; a hairline
    /// comes up round it while it has the keys.
    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return TextField("", text: Binding(get: { question.text }, set: { browser.typeAsk(tab, $0) }))
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .foregroundStyle(Palette.ink)
            .focused($typing)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(shape.fill(Palette.ink.opacity(typing ? 0.035 : 0.06)))
            .overlay(shape.strokeBorder(Palette.ink.opacity(typing ? 0.22 : 0), lineWidth: 1))
            .animation(Motion.quick, value: typing)
            .onSubmit { browser.answer(tab, .yes(tab.asks.first?.text ?? "")) }
            .onExitCommand { browser.answer(tab, .no) }
    }

    /// A name and a password, the card's whole width, in the prompt's
    /// wash. Return in the name goes on to the password, or signs in once
    /// both are there; in the password it signs in.
    private var signIn: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        let name = Binding(get: { question.text }, set: { browser.typeAsk(tab, $0) })
        let secret = Binding(get: { question.secret }, set: { browser.typeSecret(tab, $0) })
        func dressed(_ field: some View, _ on: Bool) -> some View {
            field
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(shape.fill(Palette.ink.opacity(on ? 0.035 : 0.06)))
                .overlay(shape.strokeBorder(Palette.ink.opacity(on ? 0.22 : 0), lineWidth: 1))
                .animation(Motion.quick, value: on)
                .onExitCommand { browser.answer(tab, .no) }
        }
        return VStack(spacing: 6) {
            dressed(TextField("", text: name, prompt: Text("Name").foregroundStyle(Palette.muted)).focused($typing).onSubmit {
                if secret.wrappedValue.isEmpty { typingSecret = true } else { browser.answer(tab, .yes(name.wrappedValue)) }
            }, typing)
            dressed(SecureField("", text: secret, prompt: Text("Password").foregroundStyle(Palette.muted)).focused($typingSecret).onSubmit {
                browser.answer(tab, .yes(name.wrappedValue))
            }, typingSecret)
        }
    }

    // MARK: the foot

    /// One line: the box on the left, the buttons on the right.
    private var foot: some View {
        HStack(spacing: 6) {
            tick
            Spacer(minLength: 8)
            buttons
        }
    }

    @ViewBuilder
    private var tick: some View {
        if question.stage == .asking, let box = question.box {
            Toggle(isOn: Binding(get: { question.ticked }, set: { browser.tickAsk(tab, $0) })) {
                Text(box).font(.system(size: CardFrame.words)).foregroundStyle(Palette.muted)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .fixedSize()
            .padding(.leading, CardFrame.checkInset)
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            ForEach(choices) { choice in button(choice, wide: false) }
        }
    }

    @ViewBuilder
    private func button(_ choice: Choice, wide: Bool) -> some View {
        let pressed = Button(action: choice.act) {
            HStack(spacing: 6) {
                Text(choice.title)
                if let key = shown(choice) {
                    KeyGlyphs(keys: key, size: CardFrame.words, tint: nil, rest: 0.9)
                        .transaction { $0.animation = nil }
                }
            }
            .frame(maxWidth: wide ? .infinity : nil)
        }
        .buttonStyle(.yab(choice.kind, CardFrame.button))
        if wide { pressed.fixedSize(horizontal: false, vertical: true) } else { pressed.fixedSize() }
    }

    private struct Choice: Identifiable {
        let id: String
        let title: String
        var kind: ButtonKind = .secondary
        var key: String? = nil
        let act: () -> Void
    }

    private var choices: [Choice] {
        let yes = { browser.answer(tab, .yes(tab.asks.first?.text)) }
        let no = { browser.answer(tab, .no) }
        if question.stage == .waiting {
            return [Choice(id: "no", title: "Cancel", kind: .quiet, key: "esc", act: no)]
        }
        switch question.kind {
        case .alert:
            return [Choice(id: "yes", title: "OK", kind: .primary, key: "⏎", act: yes)]
        case .confirm, .prompt:
            return [Choice(id: "no", title: "Cancel", key: "esc", act: no),
                    Choice(id: "yes", title: "OK", kind: .primary, key: "⏎", act: yes)]
        case .capture, .location, .notifications, .localNetwork, .site, .download, .downloads:
            return [Choice(id: "no", title: "Don’t Allow", key: "esc", act: no),
                    Choice(id: "yes", title: "Allow", kind: .primary, key: "⏎", act: yes)]
        case .app(_, let app):
            return [Choice(id: "no", title: "Cancel", key: "esc", act: no),
                    Choice(id: "yes", title: "Open \(Self.name(of: app))", kind: .primary, key: "⏎", act: yes)]
        case .barred:
            return [Choice(id: "no", title: "Close", kind: .quiet, key: "esc", act: no),
                    Choice(id: "yes", title: "Open Settings", kind: .primary, key: "⏎", act: yes)]
        case .signIn:
            return [Choice(id: "no", title: "Cancel", key: "esc", act: no),
                    Choice(id: "yes", title: "Sign In", kind: .primary, key: "⏎", act: yes)]
        case .devMode:
            return [Choice(id: "no", title: "Not Now", key: "esc", act: no),
                    Choice(id: "yes", title: "Turn On", kind: .primary, key: "⏎", act: yes)]
        case .stuck:
            // ⌘R, what a frozen page is pressed with anyway (Browser.reload
            // ends it, `unstick`), not Return, which a hand on the page's
            // own field might press without meaning to lose what it holds.
            return [Choice(id: "no", title: "Wait", key: "esc", act: no),
                    Choice(id: "yes", title: "Reload", kind: .primary, key: "⌘R", act: yes)]
        case .reload:
            // ⌘R as for a stuck page: Return is the page's own field's.
            return [Choice(id: "no", title: "Later", key: "esc", act: no),
                    Choice(id: "yes", title: "Reload", kind: .primary, key: "⌘R", act: yes)]
        case .share:
            return [Choice(id: "no", title: "Cancel", key: "esc", act: no),
                    Choice(id: "yes", title: "Share", kind: .primary, key: "⏎", act: yes)]
        case .leave:
            return [Choice(id: "no", title: "Stay", key: "esc", act: no),
                    Choice(id: "yes", title: "Leave", kind: .primary, key: "⏎", act: yes)]
        }
    }

    /// The key in the button only while that key would reach the card.
    private func shown(_ choice: Choice) -> String? {
        guard let key = choice.key else { return nil }
        // A menu's key reaches it wherever the caret is.
        if key.hasPrefix("⌘") { return key }
        if question.typed { return typing || typingSecret ? key : nil }
        return keys ? key : nil
    }

    private static func long(_ message: String) -> Bool {
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        let box = (message as NSString).boundingRect(
            with: NSSize(width: 420 - CardFrame.inset * 2 - side - CardFrame.wellGap, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: [.font: font]
        )
        return box.height > font.boundingRectForFont.height * CGFloat(lines) + 2
    }
}

// MARK: - the camera and the microphone, from the tab's mark

extension Tab {
    /// Through the call's own switch where there is one (Meet, Zoom), so the page
    /// and everyone on the call see it too; else WebKit's.
    func muteMicrophone(_ on: Bool) {
        if let page = builtPage as? ChromiumPage, page.routeNativeCallSwitch("toggleMicrophone", muted: on) { return }
        if let muted = pageMic {
            if microphone == .muted, !on { builtPage?.setMicrophoneCapture(.active) }
            if muted != on { pressCall("mic") }
            return
        }
        builtPage?.setMicrophoneCapture(on ? .muted : .active)
    }

    func turnCamera(_ on: Bool) {
        if let page = builtPage as? ChromiumPage, page.routeNativeCallSwitch("toggleCamera", muted: !on) { return }
        if let off = pageCamera {
            if camera == .muted, on { builtPage?.setCameraCapture(.active) }
            if off == on { pressCall("camera") }
            return
        }
        builtPage?.setCameraCapture(on ? .active : .muted)
    }

    private func pressCall(_ which: String) {
        builtPage?.run("window.__yabCall && window.__yabCall.press('\(which)')", in: .yab) { _ in }
    }

    /// Off, and asked again next time.
    func forgetCapture() {
        if let page = builtPage as? ChromiumPage {
            page.stopNativeUserMedia()
        } else {
            builtPage?.setCameraCapture(.none)
            builtPage?.setMicrophoneCapture(.none)
        }
        guard let host = address?.host() else { return }
        let site = Browser.origin(of: address)
        for type in [PageCapture.camera, .microphone, .cameraAndMicrophone] {
            if let site { Store.settings.removeObject(forKey: Browser.captureKey(site, type)) }
            // And what was kept under the bare host, before the port counted.
            Store.settings.removeObject(forKey: Browser.captureKey(host, type))
        }
    }
}

/// A page with the camera or the microphone: a dot on its tab's mark that
/// says whether you are heard. Filled red, the microphone is on; a red ring,
/// it is muted; only the camera, filled red too; all of it muted, a gray ring.
/// A click mutes the microphone or turns it back on (the camera, on a page
/// with no microphone); the rest is on a right-click.
///
/// Read off WebKit, never off what was pressed: a page that mutes itself
/// from its own button shows here at once.
struct CaptureDot: View {
    @ObservedObject var tab: Tab

    /// The dot, and the ring it is when muted. Its center is the mark's
    /// corner (TabMark): half on the mark, so the cut takes the mark's
    /// corner and never the letter or picture in it, a W's included.
    static let size: CGFloat = 6
    /// The gap round it, cut out of the mark it sits over.
    static let gap: CGFloat = 1.5
    static var hole: CGFloat { size + 2 * gap }
    /// The muted ring's stroke: a 3-point hole in a 6-point ring.
    static let ring: CGFloat = 1.5
    /// The square a click lands in, the dot at its center. A frame round
    /// the circle, never beside it: the dot is always its middle.
    static let reach: CGFloat = 16

    var body: some View {
        let camera = tab.cam, microphone = tab.mic
        if camera != .none || microphone != .none {
            let look = Self.look(camera, microphone)
            Button {
                if microphone != .none {
                    tab.muteMicrophone(microphone != .muted)
                } else {
                    tab.turnCamera(camera == .muted)
                }
            } label: {
                let ink = look.red ? Color.red : Palette.muted
                // Filled, you are heard; a ring, with a stroke heavy enough
                // to tell from the dot across the room, you are not.
                Circle()
                    .strokeBorder(ink, lineWidth: look.filled ? Self.size / 2 : Self.ring)
                    .frame(width: Self.size, height: Self.size)
                    .frame(width: Self.reach, height: Self.reach)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if microphone != .none {
                    Button(microphone == .muted ? "Unmute Microphone" : "Mute Microphone", mark: "yab.mic.slash") {
                        tab.muteMicrophone(microphone != .muted)
                    }
                }
                if camera != .none {
                    Button(camera == .muted ? "Turn Camera On" : "Turn Camera Off", mark: "yab.video.slash") {
                        tab.turnCamera(camera == .muted)
                    }
                }
                if tab.presentingScreen {
                    Button("Stop Sharing Screen", mark: "yab.screen") { tab.stopSharing() }
                }
                CallDeviceMenus(tab: tab)
                Divider()
                Button("Stop, and Ask Next Time") { tab.forgetCapture() }
            }
            .fixedSize()
            .keyTip(Self.help(camera, microphone))
            .accessibilityLabel(Self.help(camera, microphone))
            .transition(.scale(scale: 0.4).combined(with: .opacity).animation(Motion.quick))
        }
    }

    /// Filled while you are heard, or seen with no microphone to hear you;
    /// red while anything is live.
    static func look(_ camera: PageMediaState, _ microphone: PageMediaState) -> (filled: Bool, red: Bool) {
        let filled = microphone == .active || (microphone == .none && camera == .active)
        // Gray only when everything the page has is muted, the camera too.
        let red = microphone == .active || camera == .active || (microphone == .muted && camera == .none)
        return (filled, red)
    }

    static func help(_ camera: PageMediaState, _ microphone: PageMediaState) -> String {
        switch microphone {
        case .active: return "Microphone on, click to mute"
        case .muted: return "Muted, click to unmute"
        default: return camera == .muted ? "Camera off, click to turn on" : "Camera on, click to turn off"
        }
    }
}
