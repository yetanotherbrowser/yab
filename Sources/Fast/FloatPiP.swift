import AppKit
import WebKit

// A site's own Picture-in-Picture button, X's for one, and ⇧⌘P: only the
// video goes out, into Yab's floating window, and the page stays in its tab,
// running, to scroll on.
//
// A WKWebView on macOS has WebKit's Picture-in-Picture off (the private
// preference `_allowsPictureInPictureMediaPlayback`) while still telling
// pages `document.pictureInPictureEnabled`, so a site drew its button and
// every press failed with NotSupportedError, which X shows as "The media could
// not be played." In 0.0.17 the press lifted the whole page into Yab's
// window, since one page can't be in two places, and the tab was left black
// with the placard where the feed was (2026-10-08). WebKit's own takes only
// the video out, as a view of its own, and the page hears the standard
// API's events by itself (evals/pip-native). From 2026-10-08 to 10-13 that
// view went to the system's window, Safari's; now WebKit's handing it to
// PIP.framework is taken over and the view comes to Yab's window, with its
// corners, tuck, speed and subtitles (evals/pip-own).
enum SitePiP {
    /// On for a tab's pages; WebKit reads it as a page starts.
    static func allow(_ preferences: WKPreferences) {
        guard preferences.responds(to: NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")) else { return }
        preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        Hand.install()
    }

    /// WebKit's video, out of its page, on its way to a window. `taken` once
    /// Yab's window shows it; `gone` is said when WebKit takes it back.
    final class Picture {
        let view: NSView
        let native: ChromiumVideoPiP?
        /// The window and the place in it the video left.
        let window: NSWindow?
        let rect: CGRect
        /// The video's width over its height, nil when WebKit didn't say.
        let shape: CGSize?
        private(set) weak var controller: NSViewController?
        var gone: (() -> Void)?
        var rejectedAutomaticDeparture = false

        fileprivate init(view: NSView, window: NSWindow?, rect: CGRect, shape: CGSize?, controller: NSViewController?, native: ChromiumVideoPiP? = nil) {
            self.view = view
            self.native = native
            self.window = window
            self.rect = rect
            self.shape = shape
            self.controller = controller
        }
    }

    @MainActor static func nativePicture(_ native: ChromiumVideoPiP, in window: NSWindow?, rect: CGRect) -> Picture {
        Picture(view: native.surface, window: window, rect: rect, shape: native.state.natural, controller: nil, native: native)
    }

    /// Synthetic native-take boundary only; no PIP.framework swizzle or
    /// private controller is invoked by this test picture. The picture only
    /// holds its controller weakly, so the caller keeps `controller` alive.
    @MainActor static func benchPicture(view: NSView, window: NSWindow, rect: CGRect, controller: NSViewController) -> Picture? {
        guard Store.testing else { return nil }
        return Picture(view: view, window: window, rect: rect, shape: CGSize(width: 640, height: 360), controller: controller)
    }

    @MainActor private static func rejects(_ picture: Picture) -> Bool {
        takers.allObjects.contains { browser in
            guard let tab = browser.tab(for: picture) else { return false }
            if case .rejected = browser.automaticPiPReceipt(for: picture, tab: tab) { return true }
            return false
        }
    }

    /// Shared with the actual native turn below: an explicitly rejected
    /// automatic request uses the existing close path, never system fallback.
    @MainActor static func declined(_ picture: Picture, cancel: () -> Void, system: () -> Void) {
        if picture.rejectedAutomaticDeparture || rejects(picture) { cancel() }
        else { system() }
    }

    /// A native close belongs to one presentation and one delegate. Reopening
    /// the controller cancels the old queued notification; duplicate closes
    /// coalesce. Weak references let teardown win before the next run-loop turn.
    @MainActor final class CloseDelivery {
        private var tickets: [ObjectIdentifier: UUID] = [:]
        private let closed = NSHashTable<NSViewController>.weakObjects()

        func opened(_ controller: NSViewController) {
            tickets[ObjectIdentifier(controller)] = nil
            closed.remove(controller)
        }

        func isPending(_ controller: NSViewController) -> Bool {
            tickets[ObjectIdentifier(controller)] != nil
        }

        func handles(_ controller: NSViewController) -> Bool {
            isPending(controller) || closed.contains(controller)
        }

        func schedule(_ controller: NSViewController) {
            guard !handles(controller) else { return }
            let id = ObjectIdentifier(controller), ticket = UUID()
            tickets[id] = ticket
            let delegate = controller.value(forKey: "delegate") as AnyObject?
            DispatchQueue.main.async { [weak self, weak controller, weak delegate] in
                guard let self, self.tickets[id] == ticket else { return }
                // Keep the receipt while WebKit completes: that completion
                // may itself synchronously request another dismissal.
                defer {
                    if self.tickets[id] == ticket { self.tickets[id] = nil }
                }
                guard let controller, let delegate,
                      controller.value(forKey: "delegate") as AnyObject? === delegate else { return }
                // A late duplicate dismiss must not fall through to the
                // system controller and complete WebKit's one-shot callback
                // again. Only a new presentation relinquishes this receipt.
                self.closed.add(controller)
                let closed = NSSelectorFromString("pipDidClose:")
                if delegate.responds(to: closed) { _ = delegate.perform(closed, with: controller) }
            }
        }
    }

    /// Every browser, asked in turn for a video WebKit puts out: true when
    /// its window took it. Nobody taking it leaves it to the system's
    /// window (a call's window is up).
    @MainActor static let takers = NSHashTable<Browser>.weakObjects()
    @MainActor private static func taker(for picture: Picture) -> Browser? {
        takers.allObjects.first { $0.tab(for: picture) != nil && $0.canTake }
    }

    /// PIP.framework's PIPViewController is what WebKit presents the video's
    /// view controller with (WebVideoPresentationInterfaceMacObjC): its
    /// presenting is taken over for Yab's window, and its dismissing, for a
    /// video Yab's window holds, hands the view back and tells WebKit's side
    /// the window closed (`pipDidClose:`), as the system's would.
    private enum Hand {
        nonisolated(unsafe) static var installed = false
        nonisolated(unsafe) static var held: [ObjectIdentifier: Picture] = [:]
        @MainActor static let closing = CloseDelivery()
        /// Where the video stood as WebKit set it up to go out, the window
        /// and the frame in it: PIPViewController has neither until the
        /// way back.
        nonisolated(unsafe) static var leaving: (window: NSWindow?, rect: CGRect)?

        typealias Object = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        typealias Flag = @convention(c) (AnyObject, Selector, Bool) -> Void
        typealias SetUp = @convention(c) (AnyObject, Selector, AnyObject?, CGRect, AnyObject?) -> Void

        static func install() {
            guard !installed else { return }
            installed = true
            guard dlopen("/System/Library/PrivateFrameworks/PIP.framework/PIP", RTLD_NOW) != nil,
                  let pip = NSClassFromString("PIPViewController") else { return }
            if let webkit = NSClassFromString("WebVideoPresentationInterfaceMacObjC") {
                replace(webkit, "setUpPIPForVideoView:withFrame:inWindow:") { old in
                    { (me: AnyObject, view: AnyObject?, frame: CGRect, window: AnyObject?) in
                        leaving = (window as? NSWindow, frame)
                        unsafeBitCast(old, to: SetUp.self)(me, NSSelectorFromString("setUpPIPForVideoView:withFrame:inWindow:"), view, frame, window)
                    } as @convention(block) (AnyObject, AnyObject?, CGRect, AnyObject?) -> Void
                }
            }
            replace(pip, "presentViewControllerAsPictureInPicture:") { old in
                { (me: NSViewController, content: NSViewController?) in
                    AppKitMainThread.sync {
                        let system = {
                            unsafeBitCast(old, to: Object.self)(me, NSSelectorFromString("presentViewControllerAsPictureInPicture:"), content)
                        }
                        guard let content else { return system() }
                        // Any new presentation, including system fallback,
                        // invalidates a close queued for the previous one.
                        closing.opened(me)
                        if !present(me, content, otherwise: system) { system() }
                    }
                } as @convention(block) (NSViewController, NSViewController?) -> Void
            }
            replace(pip, "dismissViewController:") { old in
                { (me: NSViewController, content: NSViewController?) in
                    AppKitMainThread.sync {
                        if dismiss(me) { return }
                        unsafeBitCast(old, to: Object.self)(me, NSSelectorFromString("dismissViewController:"), content)
                    }
                } as @convention(block) (NSViewController, NSViewController?) -> Void
            }
            replace(pip, "dismissViewControllerWithFlyback:") { old in
                { (me: NSViewController, flyback: Bool) in
                    AppKitMainThread.sync {
                        if dismiss(me) { return }
                        unsafeBitCast(old, to: Flag.self)(me, NSSelectorFromString("dismissViewControllerWithFlyback:"), flyback)
                    }
                } as @convention(block) (NSViewController, Bool) -> Void
            }
        }

        /// In a test run, each step of a video going out and coming back,
        /// for a round that waits on one that never came.
        @MainActor static func trace(_ what: String) {
            guard Store.testing else { return }
            FileHandle.standardError.write(Data("YAB_SITE_PIP \(String(format: "%.3f", CACurrentMediaTime())) \(what)\n".utf8))
        }

        /// On the class itself, added there when only inherited
        /// (`dismissViewController:` is NSViewController's).
        private static func replace(_ cls: AnyClass, _ name: String, _ make: (IMP) -> Any) {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(cls, selector) else { return }
            let new = imp_implementationWithBlock(make(method_getImplementation(method)))
            if !class_addMethod(cls, selector, new, method_getTypeEncoding(method)) {
                method_setImplementation(method, new)
            }
        }

        /// Taken when a browser can: into its window on the next turn, as
        /// the system's window takes it a moment later. WebKit notes it is
        /// entering once this returns, and hears the view arrive only after
        /// (evals/pip-own: moved at once, the page's request never settled).
        @MainActor private static func present(_ controller: NSViewController, _ content: NSViewController,
                                               otherwise system: @escaping () -> Void) -> Bool {
            let ratio = (controller.value(forKey: "aspectRatio") as? NSValue)?.sizeValue
            let from = leaving
            leaving = nil
            let picture = Picture(
                view: content.view,
                window: from?.window,
                rect: from?.rect ?? .zero,
                shape: ratio.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil },
                controller: controller
            )
            guard taker(for: picture) != nil || rejects(picture) else {
                trace("present: no taker, the system's (window \(from?.window?.windowNumber ?? -1))")
                return false
            }
            trace("present: taken (window \(from?.window?.windowNumber ?? -1))")
            held[ObjectIdentifier(controller)] = picture
            DispatchQueue.main.async {
                // Gone meanwhile, or nobody able any more: the system's.
                guard held[ObjectIdentifier(controller)] === picture else { return trace("present: gone before its turn") }
                if let browser = taker(for: picture), browser.take(picture) {
                    entered(controller, picture)
                    return
                }
                SitePiP.declined(picture, cancel: {
                    trace("present: rejected stale automatic request")
                    // WebKit is still EnteringPIP. Closing before its entry
                    // acknowledgement leaves requestPictureInPicture pending:
                    // exitPIP only accepts InPIP. Complete that native protocol
                    // before returning it, without ever showing a window.
                    acknowledgeEntry(controller, picture)
                    _ = dismiss(controller)
                }, system: {
                    held[ObjectIdentifier(controller)] = nil
                    trace("present: not taken on its turn, the system's")
                    system()
                })
            }
            return true
        }

        /// WebKit hears the video has arrived from its container's bounds
        /// changing while it enters (`boundsDidChangeForVideoViewContainer:`
        /// moves it from entering to in, and tells the page), which the
        /// system's window causes as it sizes the view, and Yab's need not.
        /// Said once the view is in Yab's window, which takes it once it is
        /// on screen; said again it changes nothing.
        @MainActor private static func entered(_ controller: NSViewController, _ picture: Picture, tries: Int = 20) {
            guard held[ObjectIdentifier(controller)] === picture else { return trace("entered: gone") }
            // In Yab's window, not still in the page's, where WebKit keeps
            // it until the floating window is on screen and takes it.
            guard let window = picture.view.window, window !== picture.window else {
                guard tries > 0 else { return trace("entered: gave up, the view in window \(picture.view.window?.windowNumber ?? -1)") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { entered(controller, picture, tries: tries - 1) }
                return
            }
            acknowledgeEntry(controller, picture)
        }

        @MainActor private static func acknowledgeEntry(_ controller: NSViewController, _ picture: Picture) {
            let said = NSSelectorFromString("boundsDidChangeForVideoViewContainer:")
            if let delegate = controller.value(forKey: "delegate") as AnyObject?, delegate.responds(to: said) {
                _ = delegate.perform(said, with: picture.view)
                trace("entered: told")
            } else {
                trace("entered: no delegate to tell")
            }
        }

        /// WebKit taking its video back, from the page's exit, ⇧⌘P or the
        /// tab going: out of Yab's window, and WebKit told it closed.
        @MainActor private static func dismiss(_ controller: NSViewController) -> Bool {
            guard let picture = held.removeValue(forKey: ObjectIdentifier(controller)) else {
                // A reentrant/duplicate dismiss still belongs to our pending
                // close; forwarding it would also invoke the system close.
                return closing.handles(controller)
            }
            trace("dismiss")
            // Mark it before `gone` can synchronously ask to close it again.
            closing.schedule(controller)
            let gone = picture.gone
            picture.gone = nil
            gone?()
            if picture.view.window != nil { picture.view.removeFromSuperview() }
            // The queued notification runs after WebKit's own dismissing
            // has returned, as the system's window says it a moment later.
            return true
        }
    }
}

extension Browser {
    /// WebKit's word that a page's video went out of its page, or came
    /// back (WKUIDelegatePrivate). One picture at a time: a video out in
    /// Yab's own window goes home for one in the system's; a call's stays.
    @objc(_webView:hasVideoInPictureInPictureDidChange:)
    func webView(_ webView: WKWebView, hasVideoInPictureInPictureDidChange has: Bool) {
        guard let tab = tab(for: webView) else { return }
        if has, rejectsPendingVideoRequest(for: tab) {
            webView.closeAllMediaPresentations(completionHandler: {})
            return
        }
        if !has { endedPendingVideoRequest(for: tab) }
        let departure: FullscreenPiPDeparture.Context?
        switch fullscreenDeparture.receipt(for: tab, in: self) {
        case .rejected where has:
            webView.closeAllMediaPresentations(completionHandler: {})
            return
        case .automatic(let context): departure = context
        case .ordinary where has:
            supersedeFullscreenDeparture(with: tab)
            departure = nil
        default: departure = nil
        }
        tab.pictureInPicture = has
        if has, floating != nil, floating != tab.id, floater.kind == .video { land(preserving: departure) }
        if has, picturing != nil, floating == tab.id { holdPicture(tab) }
    }

    /// The system window's button back to the page, while its tab is out of
    /// sight: that tab, in front.
    @objc(_webViewFullscreenMayReturnToInline:)
    func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        // Its tab may wait in another space (BrowserWindows.reveal).
        guard let tab = everyTab.first(where: { $0.webKitOnly("WebKit PiP lifetime", build: false) === webView }) else { return }
        BrowserWindows.shared.reveal(tab.id)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A rejected owned request needs an exact current native source,
    /// beyond tab(for:)'s legacy active-tab fallback. Ambiguous geometry
    /// remains non-owned; never cancel another page from a window guess.
    func automaticPiPReceipt(for picture: SitePiP.Picture, tab: Tab) -> FullscreenPiPDeparture.Receipt {
        if rejectsPendingVideoRequest(for: tab) { return .rejected }
        if picture.native != nil { return .ordinary }
        guard let window = picture.window else { return .ordinary }
        let center = CGPoint(x: picture.rect.midX, y: picture.rect.midY)
        let exact = tabs.filter { candidate in
            guard let web = candidate.built, web.window === window else { return false }
            return web.convert(web.bounds, to: nil).contains(center)
        }
        guard exact.count == 1, exact.first === tab else { return .ordinary }
        return fullscreenDeparture.receipt(for: tab, in: self, origin: window)
    }

    /// The tab whose page a video left, where it stood in the window. Nil
    /// for another browser's.
    func tab(for picture: SitePiP.Picture) -> Tab? {
        if let native = picture.native {
            return everyTab.first { $0 === native.tab && $0.delegate === self && native.current }
        }
        guard let window = picture.window else { return nil }
        let center = CGPoint(x: picture.rect.midX, y: picture.rect.midY)
        let shown = tabs.filter { $0.webKitOnly("WebKit PiP lifetime", build: false)?.window === window }
        return shown.first { tab in
            guard let web = tab.webKitOnly("WebKit PiP lifetime", build: false) else { return false }
            return web.convert(web.bounds, to: nil).contains(center)
        } ?? shown.first { $0.id == activeID } ?? shown.first
    }
}
