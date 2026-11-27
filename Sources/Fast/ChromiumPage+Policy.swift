import AppKit
import YabCoreClient

/// A tab's own navigation, put to the same delegate question as WebKit's: the
/// helper holds the request (shield.inc) until it is answered, so what Browser
/// decides of a link holds, and what it arms for the next document is there
/// before the document is.
extension ChromiumPage {
    private enum Transition {
        static let link = 0, form = 7, reload = 8
        static let source = 0xFF, backForward = 0x0100_0000
    }

    func receiveAction(_ p: [String: JSONValue]) {
        guard let token = p["request"]?.string else { return }
        let remote = remoteID
        guard let url = p["url"]?.string.flatMap(URL.init(string:)), let events else {
            answerAction(token, remote: remote, allow: true, armed: false); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = p["method"]?.string ?? "GET"
        let transition = Int(p["transition"]?.number ?? 0)
        let gesture = p["gesture"] == .bool(true), redirect = p["redirect"] == .bool(true)
        let kind: PageAction.Kind = transition & Transition.backForward != 0 ? .backForward
            : transition & Transition.source == Transition.reload ? .reload
            : transition & Transition.source == Transition.form ? .formSubmitted
            : transition & Transition.source == Transition.link && gesture && !redirect ? .linkActivated : .other
        let popupSource = popupBackSource
        let requestedForeground = popupRequestedForeground
        popupRequestedForeground = nil
        confirmPopupSource(kind)
        // A plain click's flags are none; these reach Browser only for a
        // press a moment ago, and the link it is following. An adopted
        // popup carries the fresh press captured at creation, even if its
        // initial navigation was held for longer.
        let press = lastPress.flatMap { popupSource != nil || ProcessInfo.processInfo.systemUptime - $0.at < 1 ? $0 : nil }
        if popupSource != nil { lastPress = nil }
        let source = self.url.map { PageAction.Source(isMainFrame: true, scheme: $0.scheme ?? "", host: $0.host() ?? "", port: $0.port ?? 0) }
        var action = PageAction(request: request, kind: kind, targetIsMainFrame: true, source: source,
                                modifierFlags: kind == .linkActivated ? press?.flags ?? [] : [],
                                buttonNumber: kind == .linkActivated ? press?.button ?? 0 : 0,
                                shouldPerformDownload: false, userInitiated: gesture)
        let navigation = TopRewrite.Navigation(url: url, method: request.httpMethod, kind: kind, redirect: redirect,
                                               byPerson: gesture, inPlace: true)
        if let popupSource, let tab = navigationTab, popupSource.peek === tab {
            // Already placed from the native creation receipt, even when
            // this is a script or redirect navigation. Do not route it again
            // through the source tab's ordinary link policy.
            continueHeld(navigation, request, token: token, remote: remote)
            return
        }
        if kind == .linkActivated, requestedForeground != false, let popupSource, let tab = navigationTab,
           let browser = tab.delegate as? Browser,
           browser.peekAdoptedLink(tab, from: popupSource, action: action) {
            // Keep the original native destination and let its held load
            // continue inside Peek. Reopening the URL loses its opener.
            popupForegroundFrom = nil
            continueHeld(navigation, request, token: token, remote: remote)
            return
        }
        resolvePopupForeground()
        if popupSource != nil {
            // Chromium has already created and placed this destination. Its
            // inherited press was only for Peek placement above; replaying
            // Command/middle-click through Browser's navigation policy would
            // open another tab and cancel the original document's load.
            action = PageAction(request: action.request, kind: action.kind, targetIsMainFrame: action.targetIsMainFrame,
                                source: action.source, modifierFlags: [], buttonNumber: 0,
                                shouldPerformDownload: action.shouldPerformDownload, userInitiated: action.userInitiated)
        }
        var answered = false
        let queued = queueTail
        events.page(self, decide: action) { [weak self] policy in
            guard !answered, let self else { return }
            answered = true
            switch policy {
            case .allow:
                if let skipped = self.rewrites.next(navigation, Self.redirect).instead {
                    // The helper sends the request there instead, and that address is asked about in turn.
                    self.acceptNavigation(URLRequest(url: skipped))
                    self.answerAction(token, remote: remote, allow: true, armed: false, to: skipped)
                    return
                }
                self.acceptNavigation(request)
                self.answerAction(token, remote: remote, allow: true, armed: self.queueTail != queued)
            case .cancel: self.answerAction(token, remote: remote, allow: false, armed: false)
            case .download:
                self.answerAction(token, remote: remote, allow: false, armed: false)
                self.startDownload(url)
            }
        }
    }

    /// Run only after the first action has had the chance to place a Peek.
    /// A selection made by the person while that action was pending wins.
    func resolvePopupForeground() {
        guard let previous = popupForegroundFrom else { return }
        popupForegroundFrom = nil
        guard let tab = navigationTab, let browser = tab.delegate as? Browser,
              browser.activeID == previous, browser.tabs.contains(where: { $0 === tab }) else { return }
        browser.activeID = tab.id
        browser.editing = false
    }

    /// Consume only the adopted popup's first native action. Script windows,
    /// later clicks inside them and extension-created pages cannot gain this.
    func confirmPopupSource(_ kind: PageAction.Kind) {
        guard let source = popupBackSource else { return }
        popupBackSource = nil
        guard kind == .linkActivated, let tab = navigationTab,
              let browser = tab.delegate as? Browser else { return }
        browser.linkBack(tab, to: source)
    }

    /// Scripts the answer armed go in before the document starts, in the order
    /// this page's commands run. Never for long: DevTools holds what it is sent
    /// while a page changes renderers, so a command waiting on it waits for the
    /// very navigation being held here. Whatever is late reaches the next agent.
    /// Where a top document goes instead (Shield.redirect), at most
    /// TopRewrite.cap times in a row; Chromium's own limit of redirects
    /// would end a circle as a failure.
    private static func redirect(_ url: URL, cleaning: Bool) -> URL? {
        Shield.shared.redirect(url, persistent: nil, cleaning: cleaning)
    }

    /// An adopted popup or a Peek: its held load goes on, rewritten in place,
    /// which keeps its opener.
    private func continueHeld(_ navigation: TopRewrite.Navigation, _ request: URLRequest, token: String, remote: String?) {
        let instead = rewrites.next(navigation, Self.redirect).instead
        acceptNavigation(instead.map { URLRequest(url: $0) } ?? request)
        answerAction(token, remote: remote, allow: true, armed: true, to: instead)
    }

    private func answerAction(_ token: String, remote: String?, allow: Bool, armed: Bool, to skipped: URL? = nil) {
        var sent = false
        let send: @MainActor () -> Void = {
            guard !sent else { return }
            sent = true
            guard let remote, let core = ChromiumProcess.shared.connectedClient else { return }
            var params: [String: JSONValue] = ["tab": .string(remote), "request": .string(token), "allow": .bool(allow)]
            if let skipped { params["url"] = .string(skipped.absoluteString) }
            Task { _ = try? await core.request("page.actionReply", params: params) }
        }
        guard armed else { return send() }
        afterAcceptedInput(send)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { MainActor.assumeIsolated { send() } }
    }

    /// A link the page's renderer would open elsewhere: a ⌘- or middle-click.
    /// Yab's route for those is the same question with its flags.
    func receiveOpenLink(_ p: [String: JSONValue]) {
        guard let url = p["url"]?.string.flatMap(URL.init(string:)), let events else { return }
        let press = lastPress.flatMap { ProcessInfo.processInfo.systemUptime - $0.at < 2 ? $0 : nil }
        var flags = press?.flags ?? [.command]
        // CEF's disposition describes a window/tab, not a physical Shift
        // key. In particular target=_blank in a frame can arrive here as
        // foreground after an Option press that our main-frame hit test
        // could not resolve. Adding Shift turns Option into Option+Shift,
        // so neither the chosen Peek modifier nor Split accepts it.
        // A recent native press already has the user's exact modifiers.
        if press == nil, p["foreground"] == .bool(true) { flags.insert(.shift) }
        let action = PageAction(request: URLRequest(url: url), kind: .linkActivated, targetIsMainFrame: true,
                                source: self.url.map { PageAction.Source(isMainFrame: true, scheme: $0.scheme ?? "", host: $0.host() ?? "", port: $0.port ?? 0) },
                                modifierFlags: flags, buttonNumber: press?.button ?? 0, shouldPerformDownload: false, userInitiated: p["gesture"] == .bool(true))
        events.page(self, decide: action) { [weak self] policy in
            if policy == .allow { self?.navigationTab?.go(to: url) }
        }
    }

    /// ⇧-click and ⌥-click on a link are Yab's (a peek, a split): Chrome would
    /// open a window and save the file. The press never reaches the page; the
    /// release is the click, as it is everywhere.
    func takesModifiedLink(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .shift || flags == .option, event.clickCount == 1,
              let tab = navigationTab, modifiedDown == nil else { return false }
        let source = tab.id, turn = inputMethodTurn
        // Keep CEF's existing route for embedded/native links that the main
        // document cannot inspect. A URL at the actual press wins over it.
        let fallback: URL?
        if let pointed = LinkStatus.shared.pointed, pointed.tab == source,
           ["http", "https"].contains(pointed.url.scheme?.lowercased() ?? "") { fallback = pointed.url }
        else { fallback = nil }
        // Status messages are asynchronous and can still name the previous
        // link, or be absent when clicking without moving. Resolve this press
        // in the same isolated world that records its Peek origin.
        let point = convert(event.locationInWindow, from: nil)
        let y = isFlipped ? point.y : bounds.height - point.y
        modifiedDown = event
        modifiedUp = nil
        run("window.__yabPeekLinkAt && __yabPeekLinkAt(\(point.x),\(y),\(bounds.width),\(flags.contains(.shift)))", in: .yab) { [weak self] result in
            guard let self, self.modifiedDown === event else { return }
            let up = self.modifiedUp
            self.modifiedDown = nil
            self.modifiedUp = nil
            guard !self.retired, self.navigationTab?.id == source, self.inputMethodTurn == turn else { return }
            var resolved: URL?
            var selecting = false
            var embedded = false
            if case .success(let value) = result {
                embedded = (value as? [String: Any])?["embedded"] as? Bool == true
                selecting = (value as? Bool) == false
                if let href = value as? String, let url = URL(string: href),
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") { resolved = url }
            }
            // An inspected non-link must not revive stale hover status.
            let destination: URL? = selecting ? nil : (resolved ?? (embedded ? fallback : nil))
            if let url = destination {
                self.modifiedLink = url
                self.modifiedLinkDown = event
                if let up { _ = self.finishModifiedLink(up) }
            } else {
                // Text selection and other non-link presses remain Chrome's.
                self.dragState.pressed = event
                self.pointer("mouseDown", event)
                if let up { self.forwardMouseUp(up) }
            }
        }
        return true
    }

    func takeModifiedDown() -> NSEvent? {
        guard let down = modifiedDown ?? modifiedLinkDown else { return nil }
        modifiedDown = nil
        modifiedLinkDown = nil
        modifiedUp = nil
        modifiedLink = nil
        return down
    }

    func beginForceClick() -> Int {
        // Force Click owns this press, including one begun with a modifier.
        _ = takeModifiedDown()
        return forceInput.begin()
    }

    func finishForceClick(_ press: Int, handled: Bool) {
        if let up = forceInput.finish(press, handled: handled) { forwardMouseUp(up) }
    }

    func finishModifiedLink(_ event: NSEvent) -> Bool {
        if modifiedDown != nil { modifiedUp = event; return true }
        guard let url = modifiedLink else { return false }
        modifiedLink = nil
        modifiedLinkDown = nil
        guard let events else { return true }
        let action = PageAction(request: URLRequest(url: url), kind: .linkActivated, targetIsMainFrame: true,
                                source: self.url.map { PageAction.Source(isMainFrame: true, scheme: $0.scheme ?? "", host: $0.host() ?? "", port: $0.port ?? 0) },
                                modifierFlags: event.modifierFlags.intersection([.command, .shift, .option, .control]),
                                buttonNumber: 0, shouldPerformDownload: false, userInitiated: true)
        events.page(self, decide: action) { [weak self] policy in
            // Nobody wanted it another way: the link is followed here.
            if policy == .allow { self?.navigationTab?.go(to: url) }
        }
        return true
    }
}
